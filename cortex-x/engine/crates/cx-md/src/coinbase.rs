//! Live Coinbase Exchange websocket connector.
//!
//! Invariants:
//! - Host is pinned to the public feed; no credentials, no signed channels.
//!   The LEVEL 2 depth channel used is `level2_batch`, the KEYLESS public book
//!   feed — the invariant "no credentials, no signed channels" holds.
//! - Every parsed value is validated (finite, positive) before it can reach
//!   the bus or the store — malformed venue data never propagates.
//! - Coinbase `side` is the MAKER side; the tick/tape aggressor is its
//!   opposite (Buy = lifted the ask, Sell = hit the bid).
//! - LEVEL 2 depth streams for at most ONE actively-viewed symbol at a time
//!   (driven by a watch channel from cortexd) to bound bandwidth; the book is
//!   bounded to the top N levels each side; a fresh venue snapshot re-syncs it
//!   on every (re)subscribe and every reconnect.
//! - Reconnect backoff is exponential 1s..60s with jitter. After 3
//!   consecutive failed connects (never having seen data) the connector
//!   falls back to the synthetic feed — and stays synthetic until restart.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use cx_core::events::{BookDepth, BookLevel, BookTop, EngineEvent, FeedHealth, FeedStatus, Tick, TapePrint};
use cx_core::store::BarStore;
use cx_core::time::now_ms;
use cx_core::types::{Side, Venue};
use cx_core::{Bus, Config};
use futures_util::{SinkExt, StreamExt};
use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};
use serde::Deserialize;
use tokio::sync::{mpsc, watch};
use tokio_tungstenite::tungstenite::Message;

use crate::synthetic;

const WS_URL: &str = "wss://ws-feed.exchange.coinbase.com";
const FEED_NAME: &str = "coinbase";
/// The KEYLESS public LEVEL 2 channel (batched ~50ms). `level2` proper now
/// requires authentication; `level2_batch` does not, so it keeps the
/// no-credentials invariant while still delivering `snapshot` + `l2update`.
const L2_CHANNEL: &str = "level2_batch";
/// Honest provenance label carried on every crypto [`BookDepth`].
const L2_SOURCE: &str = "coinbase l2";
/// Levels retained and published per side. The book is bounded to this depth
/// (memory bound); deeper levels are dropped.
const DEPTH_LEVELS: usize = 20;
/// Minimum interval between depth publishes — throttles a busy book to at most
/// ~10 updates/s. Every update is still applied to the maintained book; only
/// the render cadence is bounded.
const DEPTH_MIN_INTERVAL: Duration = Duration::from_millis(100);
/// No message for this long means the feed is dead — force a reconnect.
const IDLE_TIMEOUT: Duration = Duration::from_secs(45);
const MAX_CONSECUTIVE_FAILURES: u32 = 3;

pub(crate) async fn run(
    bus: Arc<Bus>,
    store: Arc<BarStore>,
    cfg: Config,
    tick_tx: mpsc::Sender<Tick>,
    mut depth_rx: watch::Receiver<Option<String>>,
) {
    let mut rng = StdRng::from_entropy();
    let mut failures = 0u32;
    let mut attempt = 0u32;
    loop {
        match session(&bus, &store, &cfg.symbols, &tick_tx, &mut depth_rx).await {
            SessionEnd::ChannelClosed => return,
            SessionEnd::Dropped { saw_data, detail } => {
                if saw_data {
                    failures = 0;
                    attempt = 0;
                } else {
                    failures += 1;
                }
                feed_status(
                    &bus,
                    FeedHealth::Down,
                    format!("{detail} (consecutive failures: {failures})"),
                );
            }
        }

        if failures >= MAX_CONSECUTIVE_FAILURES && cfg.feed.synthetic_fallback {
            feed_status(
                &bus,
                FeedHealth::SyntheticFallback,
                format!("live connect failed {failures}x; synthetic until restart"),
            );
            synthetic::run(bus, store, cfg.symbols.clone(), tick_tx).await;
            return;
        }

        attempt += 1;
        let wait = backoff_ms(attempt, &mut rng);
        feed_status(
            &bus,
            FeedHealth::Degraded,
            format!("reconnecting in {wait}ms (attempt {attempt})"),
        );
        tokio::time::sleep(Duration::from_millis(wait)).await;
    }
}

enum SessionEnd {
    /// The aggregator's channel closed: squadron shutdown, do not reconnect.
    ChannelClosed,
    /// Connection failed or dropped; `saw_data` distinguishes a live session
    /// that died from a connect that never produced market data.
    Dropped { saw_data: bool, detail: String },
}

async fn session(
    bus: &Arc<Bus>,
    store: &Arc<BarStore>,
    symbols: &[String],
    tick_tx: &mpsc::Sender<Tick>,
    depth_rx: &mut watch::Receiver<Option<String>>,
) -> SessionEnd {
    let (mut ws, _) = match tokio_tungstenite::connect_async(WS_URL).await {
        Ok(ok) => ok,
        Err(e) => {
            return SessionEnd::Dropped {
                saw_data: false,
                detail: format!("connect failed: {e}"),
            }
        }
    };

    let subscribe = serde_json::json!({
        "type": "subscribe",
        "product_ids": symbols,
        "channels": ["matches", "ticker"],
    });
    if let Err(e) = ws.send(Message::Text(subscribe.to_string())).await {
        return SessionEnd::Dropped {
            saw_data: false,
            detail: format!("subscribe failed: {e}"),
        };
    }
    feed_status(
        bus,
        FeedHealth::Live,
        format!("connected; subscribed {} products", symbols.len()),
    );

    // LEVEL 2 depth: at most ONE actively-viewed symbol, re-derived from the
    // watch on every (re)connect so a switch made while disconnected — or the
    // active symbol itself — is honoured on reconnect. Only crypto products
    // this session actually feeds are eligible.
    let mut l2_symbol: Option<String> = depth_rx
        .borrow_and_update()
        .clone()
        .filter(|s| symbols.iter().any(|c| c == s));
    let mut book: Option<DepthBook> = None;
    let mut last_depth_pub = Instant::now()
        .checked_sub(DEPTH_MIN_INTERVAL)
        .unwrap_or_else(Instant::now);
    if let Some(sym) = &l2_symbol {
        if ws.send(l2_sub_msg(sym)).await.is_err() {
            return SessionEnd::Dropped {
                saw_data: false,
                detail: "level2 subscribe send failed".into(),
            };
        }
        book = Some(DepthBook::new(sym.clone()));
    }

    let mut saw_data = false;
    loop {
        let msg = tokio::select! {
            // React to a change in the actively-viewed depth symbol: unsubscribe
            // the previous level2 product (bandwidth bound) and subscribe the new
            // one, resetting the book so a fresh venue snapshot re-syncs it.
            changed = depth_rx.changed() => {
                if changed.is_err() {
                    // The command side is gone: squadron shutdown.
                    return SessionEnd::ChannelClosed;
                }
                let next = depth_rx
                    .borrow_and_update()
                    .clone()
                    .filter(|s| symbols.iter().any(|c| c == s));
                if next != l2_symbol {
                    if let Some(prev) = &l2_symbol {
                        // Best-effort unsubscribe; a send error surfaces on the
                        // next ws poll and reconnects.
                        let _ = ws.send(l2_unsub_msg(prev)).await;
                    }
                    book = None;
                    if let Some(sym) = &next {
                        if ws.send(l2_sub_msg(sym)).await.is_err() {
                            return SessionEnd::Dropped {
                                saw_data,
                                detail: "level2 subscribe send failed".into(),
                            };
                        }
                        book = Some(DepthBook::new(sym.clone()));
                    }
                    l2_symbol = next;
                }
                continue;
            }
            msg = tokio::time::timeout(IDLE_TIMEOUT, ws.next()) => match msg {
                Err(_) => {
                    return SessionEnd::Dropped {
                        saw_data,
                        detail: "idle timeout: no data for 45s".into(),
                    }
                }
                Ok(None) => {
                    return SessionEnd::Dropped {
                        saw_data,
                        detail: "stream ended".into(),
                    }
                }
                Ok(Some(Err(e))) => {
                    return SessionEnd::Dropped {
                        saw_data,
                        detail: format!("stream error: {e}"),
                    }
                }
                Ok(Some(Ok(m))) => m,
            },
        };

        match msg {
            Message::Text(text) => match parse_msg(&text) {
                Some(Parsed::Tick(tick)) => {
                    saw_data = true;
                    store.set_last_price(&tick.symbol, tick.price);
                    // Every Coinbase match is a real fill — feed the tape.
                    bus.publish(EngineEvent::Tape(tape_of(&tick)));
                    bus.publish(EngineEvent::Tick(tick.clone()));
                    if tick_tx.send(tick).await.is_err() {
                        return SessionEnd::ChannelClosed;
                    }
                }
                Some(Parsed::Top { top, last_px }) => {
                    saw_data = true;
                    if let Some(px) = last_px {
                        store.set_last_price(&top.symbol, px);
                    }
                    bus.publish(EngineEvent::BookTop(top));
                }
                Some(Parsed::Snapshot { symbol, bids, asks }) => {
                    saw_data = true;
                    if l2_symbol.as_deref() == Some(symbol.as_str()) {
                        let b = book.get_or_insert_with(|| DepthBook::new(symbol.clone()));
                        b.apply_snapshot(&bids, &asks);
                        // Publish the initial book immediately so the ladder
                        // renders the moment a symbol is opened.
                        bus.publish(EngineEvent::Depth(b.to_depth(now_ms())));
                        last_depth_pub = Instant::now();
                    }
                }
                Some(Parsed::L2Update { symbol, changes, ts_ms }) => {
                    saw_data = true;
                    if l2_symbol.as_deref() == Some(symbol.as_str()) {
                        if let Some(b) = book.as_mut() {
                            for (side, px, sz) in changes {
                                b.apply_change(side, px, sz);
                            }
                            // Every update is applied; only the render cadence
                            // is throttled (<= ~10/s).
                            if last_depth_pub.elapsed() >= DEPTH_MIN_INTERVAL {
                                bus.publish(EngineEvent::Depth(b.to_depth(ts_ms)));
                                last_depth_pub = Instant::now();
                            }
                        }
                    }
                }
                Some(Parsed::VenueError(detail)) => {
                    tracing::warn!(target: "cx_md::coinbase", %detail, "venue error message");
                }
                None => {}
            },
            Message::Ping(payload) => {
                if ws.send(Message::Pong(payload)).await.is_err() {
                    return SessionEnd::Dropped {
                        saw_data,
                        detail: "pong send failed".into(),
                    };
                }
            }
            Message::Close(frame) => {
                return SessionEnd::Dropped {
                    saw_data,
                    detail: format!("closed by venue: {frame:?}"),
                }
            }
            _ => {}
        }
    }
}

/// A `subscribe` frame for the keyless LEVEL 2 book of one product.
fn l2_sub_msg(symbol: &str) -> Message {
    Message::Text(
        serde_json::json!({
            "type": "subscribe",
            "product_ids": [symbol],
            "channels": [L2_CHANNEL],
        })
        .to_string(),
    )
}

/// An `unsubscribe` frame that stops the LEVEL 2 book of one product — how the
/// engine bounds bandwidth to a single actively-viewed symbol.
fn l2_unsub_msg(symbol: &str) -> Message {
    Message::Text(
        serde_json::json!({
            "type": "unsubscribe",
            "product_ids": [symbol],
            "channels": [L2_CHANNEL],
        })
        .to_string(),
    )
}

/// A real trade print for the Time & Sales tape, derived from a match tick.
/// The aggressor is the taker side the tick already carries (Coinbase reports
/// the MAKER side, which `parse_msg` flips): Buy = lifted the ask, Sell = hit
/// the bid. Live by construction — every Coinbase match is a real fill.
fn tape_of(tick: &Tick) -> TapePrint {
    TapePrint {
        symbol: tick.symbol.clone(),
        px: tick.price,
        sz: tick.size,
        aggressor: tick.aggressor,
        ts_ms: tick.ts_ms,
        is_live: true,
    }
}

/// A maintained LEVEL 2 order book for ONE product, bounded to the top
/// [`DEPTH_LEVELS`] levels per side. Prices key the maps by their IEEE-754 bit
/// pattern (`f64::to_bits`), which is monotonic for the always-positive,
/// finite prices we admit — so BTreeMap iteration IS price order without an
/// f64 `Ord` wrapper. Sizes are the venue's aggregated size at each price; a
/// zero-size update removes the level. Deeper levels are dropped to bound
/// memory: a removed top level cannot promote a previously-dropped deeper one,
/// but Coinbase sends a fresh `snapshot` on every (re)subscribe and reconnect
/// which re-syncs the book — acceptable for a bandwidth-bounded display feed
/// (not an execution book).
struct DepthBook {
    symbol: String,
    /// price.to_bits() -> aggregated size.
    bids: BTreeMap<u64, f64>,
    asks: BTreeMap<u64, f64>,
}

impl DepthBook {
    fn new(symbol: String) -> Self {
        Self {
            symbol,
            bids: BTreeMap::new(),
            asks: BTreeMap::new(),
        }
    }

    /// Replace the whole book from a venue `snapshot`.
    fn apply_snapshot(&mut self, bids: &[(f64, f64)], asks: &[(f64, f64)]) {
        self.bids.clear();
        self.asks.clear();
        for &(px, sz) in bids {
            self.apply_change(Side::Buy, px, sz);
        }
        for &(px, sz) in asks {
            self.apply_change(Side::Sell, px, sz);
        }
    }

    /// Apply one `l2update` change. `sz == 0` removes the level; otherwise the
    /// level is set. Hostile / non-finite / non-positive prices are ignored.
    /// After an insert the side is trimmed to [`DEPTH_LEVELS`] by dropping the
    /// worst level (lowest bid / highest ask). Keeping the running best-N as
    /// every level streams by yields exactly the global best-N.
    fn apply_change(&mut self, side: Side, px: f64, sz: f64) {
        if !(px.is_finite() && px > 0.0) || !sz.is_finite() || sz < 0.0 {
            return;
        }
        let key = px.to_bits();
        match side {
            Side::Buy => {
                if sz == 0.0 {
                    self.bids.remove(&key);
                } else {
                    self.bids.insert(key, sz);
                    if self.bids.len() > DEPTH_LEVELS {
                        if let Some((&lo, _)) = self.bids.iter().next() {
                            self.bids.remove(&lo); // drop the lowest bid
                        }
                    }
                }
            }
            Side::Sell => {
                if sz == 0.0 {
                    self.asks.remove(&key);
                } else {
                    self.asks.insert(key, sz);
                    if self.asks.len() > DEPTH_LEVELS {
                        if let Some((&hi, _)) = self.asks.iter().next_back() {
                            self.asks.remove(&hi); // drop the highest ask
                        }
                    }
                }
            }
        }
    }

    /// The current top-N book as a wire [`BookDepth`], sorted best-first
    /// (bids high→low, asks low→high). `count` is 0 — Coinbase level2
    /// aggregates size and omits the per-level order count.
    fn to_depth(&self, ts_ms: i64) -> BookDepth {
        let bids: Vec<BookLevel> = self
            .bids
            .iter()
            .rev()
            .take(DEPTH_LEVELS)
            .map(|(&k, &sz)| BookLevel {
                px: f64::from_bits(k),
                sz,
                count: 0,
            })
            .collect();
        let asks: Vec<BookLevel> = self
            .asks
            .iter()
            .take(DEPTH_LEVELS)
            .map(|(&k, &sz)| BookLevel {
                px: f64::from_bits(k),
                sz,
                count: 0,
            })
            .collect();
        BookDepth {
            symbol: self.symbol.clone(),
            bids,
            asks,
            depth: DEPTH_LEVELS as u32,
            source: L2_SOURCE.into(),
            is_live: true,
            ts_ms,
        }
    }
}

#[derive(Debug, Deserialize)]
struct WsMsg {
    #[serde(rename = "type")]
    msg_type: String,
    product_id: Option<String>,
    time: Option<String>,
    price: Option<String>,
    size: Option<String>,
    side: Option<String>,
    best_bid: Option<String>,
    best_ask: Option<String>,
    best_bid_size: Option<String>,
    best_ask_size: Option<String>,
    message: Option<String>,
    reason: Option<String>,
    /// LEVEL 2 `snapshot`: `[["price","size"], ...]` per side (all strings).
    bids: Option<Vec<Vec<String>>>,
    asks: Option<Vec<Vec<String>>>,
    /// LEVEL 2 `l2update`: `[["side","price","size"], ...]`.
    changes: Option<Vec<Vec<String>>>,
}

#[derive(Debug)]
pub(crate) enum Parsed {
    Tick(Tick),
    Top {
        top: BookTop,
        last_px: Option<f64>,
    },
    /// LEVEL 2 full-book snapshot: `(price, size)` pairs per side, unsorted.
    Snapshot {
        symbol: String,
        bids: Vec<(f64, f64)>,
        asks: Vec<(f64, f64)>,
    },
    /// LEVEL 2 incremental changes: `(side, price, size)`; size 0 removes.
    L2Update {
        symbol: String,
        changes: Vec<(Side, f64, f64)>,
        ts_ms: i64,
    },
    VenueError(String),
}

/// Parse one websocket text frame. Returns None for unknown / malformed /
/// administrative messages — never panics on venue data.
pub(crate) fn parse_msg(text: &str) -> Option<Parsed> {
    let msg: WsMsg = serde_json::from_str(text).ok()?;
    match msg.msg_type.as_str() {
        "snapshot" => {
            let symbol = msg.product_id?;
            Some(Parsed::Snapshot {
                symbol,
                bids: parse_levels(msg.bids.as_ref()),
                asks: parse_levels(msg.asks.as_ref()),
            })
        }
        "l2update" => {
            let symbol = msg.product_id?;
            Some(Parsed::L2Update {
                symbol,
                changes: parse_changes(msg.changes.as_ref()),
                ts_ms: parse_time_ms(msg.time.as_deref()),
            })
        }
        "match" | "last_match" => {
            let symbol = msg.product_id?;
            let price = pos_f64(msg.price.as_deref())?;
            let size = pos_f64(msg.size.as_deref())?;
            // Coinbase side is the maker side -> aggressor is the opposite.
            let aggressor = match msg.side.as_deref() {
                Some("buy") => Some(Side::Sell),
                Some("sell") => Some(Side::Buy),
                _ => None,
            };
            Some(Parsed::Tick(Tick {
                symbol,
                ts_ms: parse_time_ms(msg.time.as_deref()),
                price,
                size,
                aggressor,
                venue: Venue::Coinbase,
            }))
        }
        "ticker" => {
            let symbol = msg.product_id?;
            let bid_px = pos_f64(msg.best_bid.as_deref())?;
            let ask_px = pos_f64(msg.best_ask.as_deref())?;
            let bid_sz = pos_f64(msg.best_bid_size.as_deref()).unwrap_or(0.0);
            let ask_sz = pos_f64(msg.best_ask_size.as_deref()).unwrap_or(0.0);
            let last_px = pos_f64(msg.price.as_deref());
            Some(Parsed::Top {
                top: BookTop {
                    symbol,
                    ts_ms: parse_time_ms(msg.time.as_deref()),
                    bid_px,
                    bid_sz,
                    ask_px,
                    ask_sz,
                },
                last_px,
            })
        }
        "error" => Some(Parsed::VenueError(
            msg.message
                .or(msg.reason)
                .unwrap_or_else(|| "unknown".into()),
        )),
        _ => None,
    }
}

/// Strict positive-finite parse of a venue decimal string.
fn pos_f64(s: Option<&str>) -> Option<f64> {
    let v: f64 = s?.parse().ok()?;
    (v.is_finite() && v > 0.0).then_some(v)
}

/// Parse LEVEL 2 `[["price","size"], ...]` rows into `(price, size)` pairs.
/// Malformed rows and hostile values (non-finite / non-positive price /
/// negative size — "NaN" parses to a NaN that `is_finite` rejects) are dropped
/// silently, never fabricated. Size 0 is admitted (a snapshot rarely carries
/// it; the book treats it as "no level").
fn parse_levels(rows: Option<&Vec<Vec<String>>>) -> Vec<(f64, f64)> {
    let Some(rows) = rows else {
        return Vec::new();
    };
    rows.iter()
        .filter_map(|r| {
            let px: f64 = r.first()?.parse().ok()?;
            let sz: f64 = r.get(1)?.parse().ok()?;
            (px.is_finite() && px > 0.0 && sz.is_finite() && sz >= 0.0).then_some((px, sz))
        })
        .collect()
}

/// Parse LEVEL 2 `[["side","price","size"], ...]` change rows into
/// `(Side, price, size)`. An unknown side, a malformed number, or a hostile
/// value drops that row; size 0 is a removal.
fn parse_changes(rows: Option<&Vec<Vec<String>>>) -> Vec<(Side, f64, f64)> {
    let Some(rows) = rows else {
        return Vec::new();
    };
    rows.iter()
        .filter_map(|r| {
            let side = match r.first()?.as_str() {
                "buy" => Side::Buy,
                "sell" => Side::Sell,
                _ => return None,
            };
            let px: f64 = r.get(1)?.parse().ok()?;
            let sz: f64 = r.get(2)?.parse().ok()?;
            (px.is_finite() && px > 0.0 && sz.is_finite() && sz >= 0.0).then_some((side, px, sz))
        })
        .collect()
}

/// RFC3339 -> unix ms; wall clock when missing or malformed.
fn parse_time_ms(s: Option<&str>) -> i64 {
    s.and_then(|t| chrono::DateTime::parse_from_rfc3339(t).ok())
        .map(|d| d.timestamp_millis())
        .unwrap_or_else(now_ms)
}

fn feed_status(bus: &Arc<Bus>, health: FeedHealth, detail: String) {
    bus.publish(EngineEvent::FeedStatus(FeedStatus {
        feed: FEED_NAME.into(),
        health,
        detail,
        ts_ms: now_ms(),
    }));
}

/// Exponential 1s..60s, jittered into [base/2, base].
fn backoff_ms(attempt: u32, rng: &mut StdRng) -> u64 {
    let base = 1_000u64
        .saturating_mul(1u64 << attempt.saturating_sub(1).min(6))
        .min(60_000);
    base / 2 + rng.gen_range(0..=base / 2)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn match_parses_to_tick_with_flipped_aggressor() {
        let text = r#"{
            "type":"match","trade_id":1,"maker_order_id":"m","taker_order_id":"t",
            "side":"buy","size":"0.025","price":"64000.5","product_id":"BTC-USD",
            "sequence":10,"time":"2026-07-05T12:00:00.123456Z"
        }"#;
        match parse_msg(text) {
            Some(Parsed::Tick(t)) => {
                assert_eq!(t.symbol, "BTC-USD");
                assert_eq!(t.price, 64_000.5);
                assert_eq!(t.size, 0.025);
                // Maker bought => taker (aggressor) sold.
                assert_eq!(t.aggressor, Some(Side::Sell));
                assert_eq!(t.venue, Venue::Coinbase);
                assert_eq!(t.ts_ms, 1_783_252_800_123);
            }
            other => panic!("expected tick, got {other:?}"),
        }
    }

    #[test]
    fn ticker_parses_to_book_top() {
        let text = r#"{
            "type":"ticker","product_id":"ETH-USD","price":"3500.10",
            "best_bid":"3499.95","best_bid_size":"12.5",
            "best_ask":"3500.25","best_ask_size":"8.75",
            "time":"2026-07-05T12:00:01Z"
        }"#;
        match parse_msg(text) {
            Some(Parsed::Top { top, last_px }) => {
                assert_eq!(top.symbol, "ETH-USD");
                assert_eq!(top.bid_px, 3_499.95);
                assert_eq!(top.ask_px, 3_500.25);
                assert_eq!(top.bid_sz, 12.5);
                assert_eq!(top.ask_sz, 8.75);
                assert_eq!(last_px, Some(3_500.10));
                assert!(top.spread_bps() > 0.0);
            }
            other => panic!("expected book top, got {other:?}"),
        }
    }

    #[test]
    fn malformed_and_hostile_values_are_rejected() {
        // Negative / NaN-ish / missing prices never become events.
        assert!(parse_msg(r#"{"type":"match","product_id":"BTC-USD","price":"-1","size":"1","side":"buy"}"#).is_none());
        assert!(parse_msg(r#"{"type":"match","product_id":"BTC-USD","price":"NaN","size":"1","side":"buy"}"#).is_none());
        assert!(parse_msg(r#"{"type":"ticker","product_id":"BTC-USD","best_bid":"0","best_ask":"1"}"#).is_none());
        assert!(parse_msg("not json").is_none());
        assert!(parse_msg(r#"{"type":"subscriptions","channels":[]}"#).is_none());
    }

    #[test]
    fn backoff_stays_in_bounds() {
        let mut rng = StdRng::seed_from_u64(1);
        for attempt in 1..40 {
            let ms = backoff_ms(attempt, &mut rng);
            assert!((500..=60_000).contains(&ms), "attempt {attempt}: {ms}");
        }
    }

    #[test]
    fn match_maps_to_a_live_tape_print_with_the_taker_aggressor() {
        // The maker SOLD, so the taker (aggressor) BOUGHT: a Buy print that
        // lifted the ask. The tape mirrors the tick and is live by construction.
        let text = r#"{"type":"match","product_id":"BTC-USD","side":"sell",
            "size":"0.5","price":"64000.5","time":"2026-07-05T12:00:00Z"}"#;
        let Some(Parsed::Tick(tick)) = parse_msg(text) else {
            panic!("expected a tick from a match");
        };
        assert_eq!(tick.aggressor, Some(Side::Buy));
        let print = tape_of(&tick);
        assert_eq!(print.symbol, "BTC-USD");
        assert_eq!(print.px, 64_000.5);
        assert_eq!(print.sz, 0.5);
        assert_eq!(print.aggressor, Some(Side::Buy));
        assert!(print.is_live, "a real Coinbase fill is live");
        assert_eq!(print.ts_ms, tick.ts_ms);
    }

    #[test]
    fn level2_snapshot_then_update_maintains_a_sorted_top_n_book() {
        // Snapshot: bids/asks arrive UNSORTED to prove we re-sort, not trust
        // venue order.
        let snap = r#"{"type":"snapshot","product_id":"BTC-USD",
            "bids":[["63999.0","0.4"],["64000.5","1.2"],["63998.0","2.0"]],
            "asks":[["64002.0","0.3"],["64001.0","0.8"]]}"#;
        let Some(Parsed::Snapshot { symbol, bids, asks }) = parse_msg(snap) else {
            panic!("expected a snapshot");
        };
        assert_eq!(symbol, "BTC-USD");
        let mut book = DepthBook::new(symbol);
        book.apply_snapshot(&bids, &asks);

        let depth = book.to_depth(1_000);
        assert!(depth.is_live);
        assert_eq!(depth.source, "coinbase l2");
        assert_eq!(depth.depth, DEPTH_LEVELS as u32);
        // Bids high→low, asks low→high; count omitted (0).
        assert_eq!(depth.bids[0].px, 64_000.5);
        assert_eq!(depth.bids[0].sz, 1.2);
        assert_eq!(depth.bids[0].count, 0);
        assert!(depth.bids.windows(2).all(|w| w[0].px > w[1].px), "bids descending");
        assert_eq!(depth.asks[0].px, 64_001.0);
        assert!(depth.asks.windows(2).all(|w| w[0].px < w[1].px), "asks ascending");

        // l2update: resize the best bid, add a new best ask, and REMOVE a bid
        // (size 0).
        let upd = r#"{"type":"l2update","product_id":"BTC-USD",
            "time":"2026-07-05T12:00:02Z","changes":[
              ["buy","64000.5","3.0"],
              ["sell","64000.9","0.2"],
              ["buy","63998.0","0.0"]]}"#;
        let Some(Parsed::L2Update { changes, ts_ms, .. }) = parse_msg(upd) else {
            panic!("expected an l2update");
        };
        assert_eq!(ts_ms, 1_783_252_802_000);
        for (side, px, sz) in changes {
            book.apply_change(side, px, sz);
        }
        let depth = book.to_depth(ts_ms);
        assert_eq!(depth.bids[0].px, 64_000.5);
        assert_eq!(depth.bids[0].sz, 3.0, "best bid size updated in place");
        assert_eq!(depth.asks[0].px, 64_000.9, "new inside ask promoted to best");
        assert_eq!(depth.asks[0].sz, 0.2);
        // The removed bid is gone from the book entirely.
        assert!(depth.bids.iter().all(|l| l.px != 63_998.0), "size-0 removed the level");
    }

    #[test]
    fn level2_book_is_bounded_to_top_n_each_side() {
        // Feed far more than DEPTH_LEVELS levels; only the best N survive.
        let mut book = DepthBook::new("BTC-USD".into());
        for i in 0..(DEPTH_LEVELS as i64 + 25) {
            // Bids climb; asks climb further out. Insert in ascending price so
            // the running-best-N trim is exercised (worst dropped as better
            // ones arrive).
            book.apply_change(Side::Buy, 1_000.0 + i as f64, 1.0);
            book.apply_change(Side::Sell, 5_000.0 + i as f64, 1.0);
        }
        let depth = book.to_depth(1);
        assert_eq!(depth.bids.len(), DEPTH_LEVELS, "bids bounded to top-N");
        assert_eq!(depth.asks.len(), DEPTH_LEVELS, "asks bounded to top-N");
        // Best bid is the HIGHEST price seen; best ask is the LOWEST.
        assert_eq!(depth.bids[0].px, 1_000.0 + (DEPTH_LEVELS as f64 + 24.0));
        assert_eq!(depth.asks[0].px, 5_000.0);
    }

    #[test]
    fn level2_parsing_guards_nan_and_malformed_rows() {
        // Hostile / malformed rows are dropped; the good ones survive.
        let snap = r#"{"type":"snapshot","product_id":"BTC-USD",
            "bids":[["NaN","1.0"],["-5","1.0"],["64000.0","1.5"],["bad","x"],["100.0"]],
            "asks":[["64001.0","-1.0"],["64002.0","0.7"]]}"#;
        let Some(Parsed::Snapshot { bids, asks, .. }) = parse_msg(snap) else {
            panic!("expected a snapshot");
        };
        // Only the finite/positive-price, finite/non-negative-size rows pass.
        assert_eq!(bids, vec![(64_000.0, 1.5)]);
        assert_eq!(asks, vec![(64_002.0, 0.7)]);

        // An l2update with an unknown side and a NaN price drops those rows.
        let upd = r#"{"type":"l2update","product_id":"BTC-USD","changes":[
            ["hold","64000.0","1.0"],["buy","NaN","1.0"],["sell","64002.0","0.0"]]}"#;
        let Some(Parsed::L2Update { changes, .. }) = parse_msg(upd) else {
            panic!("expected an l2update");
        };
        assert_eq!(changes, vec![(Side::Sell, 64_002.0, 0.0)]);

        // A NaN price never corrupts the book (apply_change rejects it).
        let mut book = DepthBook::new("BTC-USD".into());
        book.apply_change(Side::Buy, f64::NAN, 1.0);
        book.apply_change(Side::Buy, -1.0, 1.0);
        assert!(book.to_depth(1).bids.is_empty(), "hostile prices never enter the book");
    }
}
