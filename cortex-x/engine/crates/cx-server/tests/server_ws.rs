//! End-to-end websocket protocol test against a real `serve_on` instance.

use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{connect_async, MaybeTlsStream, WebSocketStream};

use cx_core::events::{EngineEvent, FeedHealth, FeedStatus};
use cx_core::{Bus, Command};
use cx_server::{client_count, serve_on, SnapshotSource};

struct EchoSnap;

impl SnapshotSource for EchoSnap {
    fn snapshot(&self, bars_per_symbol: u32) -> serde_json::Value {
        serde_json::json!({ "bars_per_symbol": bars_per_symbol })
    }
}

type Client = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

/// Next JSON text frame, skipping control frames, bounded by a timeout.
async fn next_json(ws: &mut Client) -> serde_json::Value {
    loop {
        let msg = tokio::time::timeout(Duration::from_secs(5), ws.next())
            .await
            .expect("frame within timeout")
            .expect("stream open")
            .expect("frame ok");
        if let Message::Text(text) = msg {
            return serde_json::from_str(&text).expect("frame is json");
        }
    }
}

#[tokio::test]
async fn websocket_gateway_full_protocol() {
    let bus = Bus::new(1024);
    let (cmd_tx, mut cmd_rx) = mpsc::channel::<Command>(64);
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let addr = listener.local_addr().expect("addr");
    let server = tokio::spawn(serve_on(
        listener,
        bus.clone(),
        cmd_tx,
        Arc::new(EchoSnap),
    ));

    let (mut ws, _) = connect_async(format!("ws://{addr}/"))
        .await
        .expect("connect");

    // 1. hello then the connect snapshot, in that order. The automatic connect
    //    requests the DEEP-but-slim default depth (CONNECT_SNAPSHOT_BARS ≈ 1300
    //    → ~5y of D1); the source slims intraday itself.
    let hello = next_json(&mut ws).await;
    assert_eq!(hello["type"], "hello");
    assert_eq!(hello["app"], "cortex-x");
    assert_eq!(hello["protocol"], cx_server::PROTOCOL_VERSION);
    assert!(hello["ts_ms"].as_i64().expect("ts_ms") > 0);

    // The engine declares what it understands. This is load-bearing, not
    // decoration: cortexd outlives app builds (it keeps trading after the
    // window closes), so a new app regularly meets an old engine that ACCEPTS
    // its commands — serde ignores unknown fields — and answers them wrongly
    // but plausibly. `history_interval` is the name that told the app an
    // intraday chart request would be answered with daily bars.
    let caps: Vec<&str> = hello["capabilities"]
        .as_array()
        .expect("capabilities present")
        .iter()
        .map(|c| c.as_str().expect("capability is a string"))
        .collect();
    for required in ["history_interval", "shutdown"] {
        assert!(
            caps.contains(&required),
            "hello must declare `{required}`; the app checks for it by this exact name"
        );
    }
    assert_eq!(hello["engine_version"], env!("CARGO_PKG_VERSION"));

    let snapshot = next_json(&mut ws).await;
    assert_eq!(snapshot["type"], "snapshot");
    assert_eq!(snapshot["data"]["bars_per_symbol"], 1_300);

    assert_eq!(client_count(), 1);

    // 2. Bus events stream through as their serde JSON.
    bus.publish(EngineEvent::FeedStatus(FeedStatus {
        feed: "coinbase".into(),
        health: FeedHealth::Live,
        detail: "ok".into(),
        ts_ms: 42,
    }));
    let event = next_json(&mut ws).await;
    assert_eq!(event["type"], "feed_status");
    assert_eq!(event["feed"], "coinbase");
    assert_eq!(event["ts_ms"], 42);

    // 3. A command frame lands in cmd_rx.
    ws.send(Message::Text(
        r#"{"cmd":"set_kill_switch","engaged":true,"reason":"test"}"#.into(),
    ))
    .await
    .expect("send command");
    let cmd = tokio::time::timeout(Duration::from_secs(5), cmd_rx.recv())
        .await
        .expect("command within timeout")
        .expect("channel open");
    assert_eq!(
        cmd,
        Command::SetKillSwitch {
            engaged: true,
            reason: "test".into()
        }
    );

    // 4. Garbage gets an error frame and does NOT kill the connection.
    ws.send(Message::Text("this is not json".into()))
        .await
        .expect("send garbage");
    let err = next_json(&mut ws).await;
    assert_eq!(err["type"], "error");
    assert_eq!(err["detail"], "bad command");

    // 5. Still alive: Sync is answered by the server itself with a fresh
    //    snapshot at the requested depth.
    ws.send(Message::Text(r#"{"cmd":"sync","bars_per_symbol":42}"#.into()))
        .await
        .expect("send sync");
    let resync = next_json(&mut ws).await;
    assert_eq!(resync["type"], "snapshot");
    assert_eq!(resync["data"]["bars_per_symbol"], 42);

    // 6. Clean disconnect: client count returns to zero.
    ws.close(None).await.expect("close");
    for _ in 0..50 {
        if client_count() == 0 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert_eq!(client_count(), 0);

    server.abort();
}
