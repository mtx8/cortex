//! Live Coinbase Exchange websocket connector.
//!
//! Invariants:
//! - Host is pinned to the public feed; no credentials, no signed channels.
//! - Every parsed value is validated (finite, positive) before it can reach
//!   the bus or the store — malformed venue data never propagates.
//! - Coinbase `side` is the MAKER side; the tick aggressor is its opposite.
//! - Reconnect backoff is exponential 1s..60s with jitter. After 3
//!   consecutive failed connects (never having seen data) the connector
//!   falls back to the synthetic feed — and stays synthetic until restart.

use std::sync::Arc;
use std::time::Duration;

use cx_core::events::{BookTop, EngineEvent, FeedHealth, FeedStatus, Tick};
use cx_core::store::BarStore;
use cx_core::time::now_ms;
use cx_core::types::{Side, Venue};
use cx_core::{Bus, Config};
use futures_util::{SinkExt, StreamExt};
use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};
use serde::Deserialize;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

use crate::synthetic;

const WS_URL: &str = "wss://ws-feed.exchange.coinbase.com";
const FEED_NAME: &str = "coinbase";
/// No message for this long means the feed is dead — force a reconnect.
const IDLE_TIMEOUT: Duration = Duration::from_secs(45);
const MAX_CONSECUTIVE_FAILURES: u32 = 3;

pub(crate) async fn run(
    bus: Arc<Bus>,
    store: Arc<BarStore>,
    cfg: Config,
    tick_tx: mpsc::Sender<Tick>,
) {
    let mut rng = StdRng::from_entropy();
    let mut failures = 0u32;
    let mut attempt = 0u32;
    loop {
        match session(&bus, &store, &cfg.symbols, &tick_tx).await {
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

    let mut saw_data = false;
    loop {
        let msg = match tokio::time::timeout(IDLE_TIMEOUT, ws.next()).await {
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
        };

        match msg {
            Message::Text(text) => match parse_msg(&text) {
                Some(Parsed::Tick(tick)) => {
                    saw_data = true;
                    store.set_last_price(&tick.symbol, tick.price);
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
}

#[derive(Debug)]
pub(crate) enum Parsed {
    Tick(Tick),
    Top { top: BookTop, last_px: Option<f64> },
    VenueError(String),
}

/// Parse one websocket text frame. Returns None for unknown / malformed /
/// administrative messages — never panics on venue data.
pub(crate) fn parse_msg(text: &str) -> Option<Parsed> {
    let msg: WsMsg = serde_json::from_str(text).ok()?;
    match msg.msg_type.as_str() {
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
}
