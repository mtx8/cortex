//! cx-server — the websocket gateway between the engine and native clients.
//!
//! One connection per client; all frames are JSON text. Protocol invariants:
//! - On connect the client receives a `hello` frame, then a full `snapshot`,
//!   then a live stream of every bus event (its serde JSON, `type`-tagged).
//! - Inbound frames are [`cx_core::Command`] JSON. `Command::Sync` is answered
//!   locally with a fresh snapshot; everything else forwards to the engine.
//!   Unparseable frames get an `error` frame and never kill the connection.
//! - Backpressure is per-client and bounded: non-critical events drop when the
//!   client falls behind (a `gap` frame reports the count once the burst ends);
//!   critical events ([`EngineEvent::is_critical`]) are never dropped.
//! - Client tasks shut down cleanly on disconnect: no leaked tasks, no panics
//!   on send-after-close.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use futures_util::stream::SplitSink;
use futures_util::{SinkExt, StreamExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::broadcast;
use tokio::sync::mpsc;
use tokio::sync::mpsc::error::TrySendError;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{accept_async, WebSocketStream};

use cx_core::bus::BusEvent;
use cx_core::time::now_ms;
use cx_core::{Bus, Command};

/// Per-client outbound queue depth. Beyond this the client is behind and
/// non-critical events start dropping.
const OUT_QUEUE: usize = 1024;

/// History depth requested for the automatic connect-time snapshot.
///
/// This is the ceiling for the DEEP interval (D1): ≈1300 daily bars covers ~5y
/// of trading days for both configured and universe symbols. It is NOT the
/// intraday depth — the snapshot source (`SnapshotSource::snapshot`) applies its
/// own slim per-interval profile, capping intraday to a modest window so a
/// normal connect ships on the order of 1–2 MB instead of ~8 MB.
///
/// A client-driven `Command::Sync` forwards its OWN `bars_per_symbol` unchanged
/// (see the reader loop below): a range preset asking for the full store depth
/// (up to 3000) still works, while the default connect stays on the slim
/// profile. Keep this consistent with the source's D1 cap in `cortexd`.
const CONNECT_SNAPSHOT_BARS: u32 = 1_300;

/// Provider of the connect/sync state snapshot. Implementations must be cheap
/// and non-blocking: this is called inline on client tasks.
pub trait SnapshotSource: Send + Sync + 'static {
    fn snapshot(&self, bars_per_symbol: u32) -> serde_json::Value;
}

static CLIENT_COUNT: AtomicUsize = AtomicUsize::new(0);

/// Live websocket clients (post-handshake). For tests and cortexd health.
pub fn client_count() -> usize {
    CLIENT_COUNT.load(Ordering::SeqCst)
}

/// RAII client-count guard: the count stays correct on every exit path.
struct ClientGuard;

impl ClientGuard {
    fn new() -> Self {
        CLIENT_COUNT.fetch_add(1, Ordering::SeqCst);
        ClientGuard
    }
}

impl Drop for ClientGuard {
    fn drop(&mut self) {
        CLIENT_COUNT.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Bind `host:port` and accept websocket clients forever. Returns only if the
/// bind itself fails.
pub async fn serve(
    bus: Arc<Bus>,
    host: String,
    port: u16,
    cmd_tx: mpsc::Sender<Command>,
    snap: Arc<dyn SnapshotSource>,
) -> anyhow::Result<()> {
    let listener = TcpListener::bind((host.as_str(), port)).await?;
    tracing::info!(host = %host, port, "cx-server listening");
    serve_on(listener, bus, cmd_tx, snap).await
}

/// Accept loop on an already-bound listener (lets tests bind port 0 and read
/// the ephemeral address first). Accept errors are transient: logged, never
/// fatal.
pub async fn serve_on(
    listener: TcpListener,
    bus: Arc<Bus>,
    cmd_tx: mpsc::Sender<Command>,
    snap: Arc<dyn SnapshotSource>,
) -> anyhow::Result<()> {
    // Serialize each bus event exactly ONCE for the wire, regardless of how
    // many clients are connected; client pumps share the encoded Arc<str>.
    let (wire_tx, _) = broadcast::channel::<(BusEvent, Arc<str>)>(8_192);
    {
        let mut bus_rx = bus.subscribe();
        let wire_tx = wire_tx.clone();
        tokio::spawn(async move {
            loop {
                match bus_rx.recv().await {
                    Ok(ev) => {
                        if let Ok(text) = serde_json::to_string(ev.as_ref()) {
                            let _ = wire_tx.send((ev, Arc::from(text.into_boxed_str())));
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        tracing::warn!(lagged = n, "wire serializer lagged the bus");
                    }
                    Err(broadcast::error::RecvError::Closed) => return,
                }
            }
        });
    }
    loop {
        match listener.accept().await {
            Ok((stream, peer)) => {
                tracing::debug!(%peer, "client connecting");
                tokio::spawn(handle_client(
                    stream,
                    wire_tx.subscribe(),
                    cmd_tx.clone(),
                    snap.clone(),
                ));
            }
            Err(e) => {
                tracing::warn!(error = %e, "accept failed");
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        }
    }
}

fn snapshot_frame(snap: &dyn SnapshotSource, bars_per_symbol: u32) -> String {
    serde_json::json!({
        "type": "snapshot",
        "data": snap.snapshot(bars_per_symbol),
    })
    .to_string()
}

fn error_frame(detail: &str) -> String {
    serde_json::json!({ "type": "error", "detail": detail }).to_string()
}

fn gap_frame(dropped: u64) -> Message {
    Message::Text(serde_json::json!({ "type": "gap", "dropped": dropped }).to_string())
}

/// One task per client: handshake, hello + snapshot, then reader loop here
/// while a writer task and a bus pump task run alongside. All three end when
/// any side of the connection dies.
async fn handle_client(
    stream: TcpStream,
    wire_rx: broadcast::Receiver<(BusEvent, Arc<str>)>,
    cmd_tx: mpsc::Sender<Command>,
    snap: Arc<dyn SnapshotSource>,
) {
    let mut ws = match accept_async(stream).await {
        Ok(ws) => ws,
        Err(e) => {
            tracing::debug!(error = %e, "websocket handshake failed");
            return;
        }
    };
    let _guard = ClientGuard::new();

    let hello = serde_json::json!({
        "type": "hello",
        "app": "cortex-x",
        "protocol": 1,
        "ts_ms": now_ms(),
    })
    .to_string();
    if ws.send(Message::Text(hello)).await.is_err() {
        return;
    }
    let frame = snapshot_frame(snap.as_ref(), CONNECT_SNAPSHOT_BARS);
    if ws.send(Message::Text(frame)).await.is_err() {
        return;
    }

    let (sink, mut reader) = ws.split();
    let (out_tx, out_rx) = mpsc::channel::<Message>(OUT_QUEUE);
    let mut writer = tokio::spawn(write_out(out_rx, sink));
    let pump = tokio::spawn(pump_bus(wire_rx, out_tx.clone()));

    // Reader loop: client -> engine.
    loop {
        let msg = match reader.next().await {
            Some(Ok(m)) => m,
            Some(Err(_)) | None => break,
        };
        match msg {
            Message::Text(text) => match serde_json::from_str::<Command>(&text) {
                Ok(Command::Sync { bars_per_symbol }) => {
                    let frame = snapshot_frame(snap.as_ref(), bars_per_symbol);
                    if out_tx.send(Message::Text(frame)).await.is_err() {
                        break;
                    }
                }
                Ok(cmd) => {
                    if cmd_tx.send(cmd).await.is_err() {
                        // Engine side is gone; tell the client, keep serving
                        // the event stream (which will end shortly anyway).
                        let frame = error_frame("engine unavailable");
                        let _ = out_tx.send(Message::Text(frame)).await;
                    }
                }
                Err(_) => {
                    let frame = error_frame("bad command");
                    if out_tx.send(Message::Text(frame)).await.is_err() {
                        break;
                    }
                }
            },
            Message::Binary(_) => {
                let frame = error_frame("bad command");
                if out_tx.send(Message::Text(frame)).await.is_err() {
                    break;
                }
            }
            Message::Ping(payload) => {
                if out_tx.send(Message::Pong(payload)).await.is_err() {
                    break;
                }
            }
            Message::Close(_) => break,
            _ => {}
        }
    }

    // Teardown: stop the pump, close the outbound channel, let the writer
    // drain and exit. The writer is bounded by a timeout in case the peer
    // stalls mid-write with a full socket buffer.
    pump.abort();
    let _ = pump.await;
    drop(out_tx);
    if tokio::time::timeout(Duration::from_secs(5), &mut writer)
        .await
        .is_err()
    {
        writer.abort();
    }
    tracing::debug!("client disconnected");
}

/// Writer task: sole owner of the websocket sink. Ends when the outbound
/// channel closes or the socket write fails; both are normal shutdown.
async fn write_out(
    mut out_rx: mpsc::Receiver<Message>,
    mut sink: SplitSink<WebSocketStream<TcpStream>, Message>,
) {
    while let Some(msg) = out_rx.recv().await {
        if sink.send(msg).await.is_err() {
            break;
        }
    }
    let _ = sink.close().await;
}

/// Bus pump: bus -> per-client queue with the backpressure contract.
/// Non-critical events drop when the queue is full (counted); critical events
/// use a blocking send and are never dropped here. Bus-side lag (broadcast
/// overflow) is folded into the same drop count. A `gap` frame reporting the
/// count is emitted once the burst ends.
async fn pump_bus(
    mut wire_rx: broadcast::Receiver<(BusEvent, Arc<str>)>,
    out_tx: mpsc::Sender<Message>,
) {
    let mut dropped: u64 = 0;
    loop {
        let (event, text) = match wire_rx.recv().await {
            Ok(pair) => pair,
            Err(broadcast::error::RecvError::Lagged(n)) => {
                dropped = dropped.saturating_add(n);
                continue;
            }
            Err(broadcast::error::RecvError::Closed) => return,
        };
        let text = text.to_string();
        if event.is_critical() {
            if dropped > 0 {
                if out_tx.send(gap_frame(dropped)).await.is_err() {
                    return;
                }
                dropped = 0;
            }
            if out_tx.send(Message::Text(text)).await.is_err() {
                return;
            }
        } else {
            if dropped > 0 {
                match out_tx.try_send(gap_frame(dropped)) {
                    Ok(()) => dropped = 0,
                    Err(TrySendError::Full(_)) => {
                        // Burst continues: this event drops too.
                        dropped = dropped.saturating_add(1);
                        continue;
                    }
                    Err(TrySendError::Closed(_)) => return,
                }
            }
            match out_tx.try_send(Message::Text(text)) {
                Ok(()) => {}
                Err(TrySendError::Full(_)) => dropped = dropped.saturating_add(1),
                Err(TrySendError::Closed(_)) => return,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cx_core::events::{EngineEvent, FeedHealth, FeedStatus, RiskStatus, Tick};
    use cx_core::types::{AutonomyLevel, Side, Venue};

    
    /// Test-side mirror of serve_on's wire serializer.
    fn wire_of(bus: &Bus) -> broadcast::Receiver<(BusEvent, Arc<str>)> {
        let (wire_tx, wire_rx) = broadcast::channel::<(BusEvent, Arc<str>)>(1_024);
        let mut bus_rx = bus.subscribe();
        tokio::spawn(async move {
            while let Ok(ev) = bus_rx.recv().await {
                if let Ok(text) = serde_json::to_string(ev.as_ref()) {
                    let _ = wire_tx.send((ev, Arc::from(text.into_boxed_str())));
                }
            }
        });
        wire_rx
    }

    /// Snapshot source that echoes the requested depth so we can assert which
    /// `bars_per_symbol` each call site forwards.
    struct EchoSource;
    impl SnapshotSource for EchoSource {
        fn snapshot(&self, bars_per_symbol: u32) -> serde_json::Value {
            serde_json::json!({ "requested_bars": bars_per_symbol })
        }
    }

    /// The automatic connect snapshot must request the DEEP-but-slim default
    /// (enough D1 for ~5y, ≈1300 bars, without maxing the 3000-bar store), and
    /// a client-driven `Sync` must forward its OWN count unchanged — so a range
    /// preset asking for the full 3000 still works while connect stays slim.
    #[test]
    fn connect_uses_deep_default_and_sync_forwards_requested_count() {
        // Connect path: snapshot_frame(&snap, CONNECT_SNAPSHOT_BARS).
        let connect: serde_json::Value =
            serde_json::from_str(&snapshot_frame(&EchoSource, CONNECT_SNAPSHOT_BARS)).unwrap();
        assert_eq!(connect["type"], "snapshot");
        assert_eq!(connect["data"]["requested_bars"], CONNECT_SNAPSHOT_BARS);
        // Deep enough for ~5y of daily bars, but never the store maximum.
        assert!((1_300..3_000).contains(&CONNECT_SNAPSHOT_BARS));

        // Sync path: snapshot_frame(&snap, bars_per_symbol) with the client's
        // own value — a full-depth range preset is forwarded verbatim.
        let sync: serde_json::Value =
            serde_json::from_str(&snapshot_frame(&EchoSource, 3_000)).unwrap();
        assert_eq!(sync["type"], "snapshot");
        assert_eq!(sync["data"]["requested_bars"], 3_000);
    }

    fn tick(n: i64) -> EngineEvent {
        EngineEvent::Tick(Tick {
            symbol: "BTC-USD".into(),
            ts_ms: n,
            price: 50_000.0,
            size: 0.1,
            aggressor: Some(Side::Buy),
            venue: Venue::Coinbase,
        })
    }

    fn risk() -> EngineEvent {
        EngineEvent::Risk(RiskStatus {
            kill_switch: false,
            kill_reason: None,
            autonomy: AutonomyLevel::FullAuto,
            caution: 0.0,
            caution_reasons: vec![],
            throttle: 1.0,
            breaches: vec![],
            ts_ms: 1,
        })
    }

    fn text_of(msg: Message) -> serde_json::Value {
        match msg {
            Message::Text(t) => serde_json::from_str(&t).expect("frame is json"),
            other => panic!("expected text frame, got {other:?}"),
        }
    }

    /// Bounded receive: a missing frame fails the test instead of hanging it.
    async fn next_frame(out_rx: &mut mpsc::Receiver<Message>) -> serde_json::Value {
        let msg = tokio::time::timeout(Duration::from_secs(5), out_rx.recv())
            .await
            .expect("frame within timeout")
            .expect("channel open");
        text_of(msg)
    }

    #[tokio::test]
    async fn pump_forwards_events_as_type_tagged_json() {
        let bus = Bus::new(64);
        let bus_rx = wire_of(&bus);
        let (out_tx, mut out_rx) = mpsc::channel(8);
        let pump = tokio::spawn(pump_bus(bus_rx, out_tx));

        bus.publish(EngineEvent::FeedStatus(FeedStatus {
            feed: "test".into(),
            health: FeedHealth::Live,
            detail: String::new(),
            ts_ms: 1,
        }));
        let frame = next_frame(&mut out_rx).await;
        assert_eq!(frame["type"], "feed_status");
        assert_eq!(frame["feed"], "test");
        pump.abort();
    }

    #[tokio::test]
    async fn full_queue_drops_noncritical_counts_them_and_reports_gap() {
        let bus = Bus::new(1024);
        let bus_rx = wire_of(&bus);
        // Capacity 1: the second undrained event must drop.
        let (out_tx, mut out_rx) = mpsc::channel(1);
        let pump = tokio::spawn(pump_bus(bus_rx, out_tx));

        bus.publish(tick(1)); // fills the queue
        bus.publish(tick(2)); // dropped
        bus.publish(tick(3)); // dropped
        tokio::time::sleep(Duration::from_millis(100)).await;

        // Critical event: blocking send, never dropped. It first flushes the
        // gap for the ended burst.
        bus.publish(risk());
        tokio::time::sleep(Duration::from_millis(50)).await;

        let first = next_frame(&mut out_rx).await;
        assert_eq!(first["type"], "tick");
        assert_eq!(first["ts_ms"], 1);

        let gap = next_frame(&mut out_rx).await;
        assert_eq!(gap["type"], "gap");
        assert_eq!(gap["dropped"], 2);

        let critical = next_frame(&mut out_rx).await;
        assert_eq!(critical["type"], "risk");
        pump.abort();
    }

    #[tokio::test]
    async fn gap_precedes_next_noncritical_after_burst() {
        let bus = Bus::new(1024);
        let bus_rx = wire_of(&bus);
        // Capacity 2: room for the gap frame AND the event that ends the
        // burst once the queue has been drained.
        let (out_tx, mut out_rx) = mpsc::channel(2);
        let pump = tokio::spawn(pump_bus(bus_rx, out_tx));

        bus.publish(tick(1));
        bus.publish(tick(2)); // fills the queue
        bus.publish(tick(3)); // dropped
        tokio::time::sleep(Duration::from_millis(100)).await;

        // Drain the queue, ending the burst; the next event flushes the gap.
        let first = next_frame(&mut out_rx).await;
        assert_eq!(first["ts_ms"], 1);
        let second = next_frame(&mut out_rx).await;
        assert_eq!(second["ts_ms"], 2);

        bus.publish(tick(4));
        let gap = next_frame(&mut out_rx).await;
        assert_eq!(gap["type"], "gap");
        assert_eq!(gap["dropped"], 1);
        let next = next_frame(&mut out_rx).await;
        assert_eq!(next["ts_ms"], 4);
        pump.abort();
    }

    #[tokio::test]
    async fn pump_exits_when_client_queue_closes() {
        let bus = Bus::new(64);
        let bus_rx = wire_of(&bus);
        let (out_tx, out_rx) = mpsc::channel(1);
        let pump = tokio::spawn(pump_bus(bus_rx, out_tx));
        drop(out_rx);
        bus.publish(tick(1));
        // Closed queue means the client is gone: the pump must return, not
        // panic and not spin.
        tokio::time::timeout(Duration::from_secs(2), pump)
            .await
            .expect("pump exits")
            .expect("no panic");
    }
}
