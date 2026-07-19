//! Equity feed: CBOE delayed quotes (keyless, ~15 min delayed) polled on a
//! slow cadence, plus Yahoo chart backfill. Intraday (H1/M5) backfill asks
//! for extended-hours bars (`includePrePost=true`) so pre/post-market
//! action lands in the store — bars carry their real timestamps, nothing
//! is re-marked or filtered as RTH-only. Delayed data is honest data: the
//! feed advertises itself as Degraded (never Live) so downstream consumers
//! and the operator can see exactly what they are trading on.
//!
//! LEVEL 2 depth for equities: there is NO real order book here. Equities
//! carry only CBOE ~15-min-DELAYED top-of-book (L1) today. For the actively-
//! viewed equity symbol this feed therefore publishes a MINIMAL, honest
//! [`BookDepth`] with `is_live = false` and `source = "cboe delayed L1 (no
//! depth)"` — a single delayed level per side so the UI shows something true
//! rather than pretending crypto-style live L2. Real equity L1/L2 (and a real
//! tape) arrives via the IBKR adapter (`reqMktData` / `reqMktDepth`) once the
//! operator connects IB Gateway with their market-data subscriptions; see the
//! clearly-marked integration point [`publish_ibkr_depth`] / [`publish_ibkr_tape`]
//! at the bottom of this file. This poller NEVER fabricates real-time equity
//! depth or aggressor-tagged prints.

use std::sync::Arc;
use std::time::Duration;

use cx_core::egress::Egress;
use cx_core::events::{
    Bar, BookDepth, BookLevel, BookTop, EngineEvent, FeedHealth, FeedStatus, TapePrint, Tick,
};
use cx_core::store::BarStore;
use cx_core::time::now_ms;
use cx_core::types::{Interval, Venue};
use cx_core::Bus;
use tokio::sync::watch;

const POLL_SECS: u64 = 20;
const FEED_NAME: &str = "cboe-equities";
/// Honest provenance label carried on every equity [`BookDepth`]: delayed L1
/// with no real order-book depth.
const EQUITY_DEPTH_SOURCE: &str = "cboe delayed L1 (no depth)";

fn quote_url(symbol: &str) -> String {
    format!("https://cdn.cboe.com/api/global/delayed_quotes/quotes/{symbol}.json")
}

/// Yahoo v8 chart backfill URL. Intraday requests (`pre_post`) include
/// extended-hours bars — the daily range never asks (D1 rows are official
/// RTH sessions; the flag is meaningless there).
fn chart_url(symbol: &str, range: &str, gran: &str, pre_post: bool) -> String {
    let extra = if pre_post { "&includePrePost=true" } else { "" };
    format!(
        "https://query1.finance.yahoo.com/v8/finance/chart/{symbol}?range={range}&interval={gran}{extra}"
    )
}

/// Parsed subset of the CBOE quote payload.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct EquityQuote {
    pub price: f64,
    pub bid: f64,
    pub ask: f64,
    pub bid_size: f64,
    pub ask_size: f64,
    pub volume: f64,
    pub last_trade_time: String,
}

pub(crate) fn parse_quote(raw: &str) -> Option<EquityQuote> {
    let v: serde_json::Value = serde_json::from_str(raw).ok()?;
    let d = v.get("data")?;
    let f = |k: &str| d.get(k).and_then(|x| x.as_f64()).unwrap_or(f64::NAN);
    let q = EquityQuote {
        price: f("current_price"),
        bid: f("bid"),
        ask: f("ask"),
        bid_size: f("bid_size"),
        ask_size: f("ask_size"),
        volume: f("volume"),
        last_trade_time: d
            .get("last_trade_time")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string(),
    };
    (q.price.is_finite() && q.price > 0.0).then_some(q)
}

/// Yahoo v8 chart JSON -> complete bars. Null slots (halts, partial rows)
/// are skipped; a malformed payload yields an empty vec, never a panic.
pub(crate) fn parse_yahoo_chart(symbol: &str, interval: Interval, raw: &str, max: usize) -> Vec<Bar> {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(raw) else {
        return Vec::new();
    };
    let Some(result) = v
        .get("chart")
        .and_then(|c| c.get("result"))
        .and_then(|r| r.get(0))
    else {
        return Vec::new();
    };
    let Some(ts) = result.get("timestamp").and_then(|t| t.as_array()) else {
        return Vec::new();
    };
    let Some(quote) = result
        .get("indicators")
        .and_then(|i| i.get("quote"))
        .and_then(|q| q.get(0))
    else {
        return Vec::new();
    };
    let series = |k: &str| quote.get(k).and_then(|a| a.as_array());
    let (Some(open), Some(high), Some(low), Some(close), Some(volume)) = (
        series("open"),
        series("high"),
        series("low"),
        series("close"),
        series("volume"),
    ) else {
        return Vec::new();
    };

    let mut bars: Vec<Bar> = Vec::new();
    for i in 0..ts.len() {
        let (Some(t), Some(o), Some(h), Some(l), Some(c)) = (
            ts.get(i).and_then(|x| x.as_i64()),
            open.get(i).and_then(|x| x.as_f64()),
            high.get(i).and_then(|x| x.as_f64()),
            low.get(i).and_then(|x| x.as_f64()),
            close.get(i).and_then(|x| x.as_f64()),
        ) else {
            continue;
        };
        if ![o, h, l, c].iter().all(|x| x.is_finite() && *x > 0.0) || h < l {
            continue;
        }
        // D1 rows stay UTC-midnight-bucketed (utcDayKey + the live
        // aggregator's daily dedupe key on them). Intraday bars keep
        // Yahoo's true opens: RTH hourlies are 09:30-anchored, so flooring
        // would alias the 09:30 RTH bar into the 09:00 pre-market bucket —
        // destroying the pre-market bar in the store and mis-shading the
        // first regular hour as extended on every equity H1 chart.
        bars.push(Bar {
            symbol: symbol.to_string(),
            interval,
            ts_open_ms: if interval == Interval::D1 {
                cx_core::time::bucket_start(t * 1000, interval.ms())
            } else {
                t * 1000
            },
            open: o,
            high: h,
            low: l,
            close: c,
            volume: volume.get(i).and_then(|x| x.as_f64()).unwrap_or(0.0),
            trade_count: 0,
            vwap: c,
            complete: true,
        });
    }
    let start = bars.len().saturating_sub(max);
    bars.split_off(start)
}

/// Poll loop for all configured equity symbols. Publishes ticks/tops on real
/// quote changes only (a closed market produces silence, not fake prints).
pub(crate) async fn run(
    bus: Arc<Bus>,
    store: Arc<BarStore>,
    symbols: Vec<String>,
    tick_tx: tokio::sync::mpsc::Sender<Tick>,
    backfill_bars: u32,
    mut depth_rx: watch::Receiver<Option<String>>,
) {
    if symbols.is_empty() {
        return;
    }
    let egress = Egress::new();

    // History first, so charts and analytics have context immediately:
    // five years of dailies, three months of hourlies, five days of
    // 5-minute bars. Intraday ranges include extended-hours bars.
    const RANGES: [(Interval, &str, &str, bool); 3] = [
        (Interval::D1, "5y", "1d", false),
        (Interval::H1, "3mo", "1h", true),
        (Interval::M5, "5d", "5m", true),
    ];
    for symbol in &symbols {
        for (interval, range, gran, pre_post) in RANGES {
            let url = chart_url(symbol, range, gran, pre_post);
            match egress.get_text(&url).await {
                Ok(raw) => {
                    let bars = parse_yahoo_chart(symbol, interval, &raw, backfill_bars as usize);
                    let n = bars.len();
                    for bar in bars {
                        store.push(bar);
                    }
                    tracing::info!(symbol = %symbol, interval = interval.label(), bars = n, "equity backfill");
                }
                Err(e) => {
                    tracing::warn!(symbol = %symbol, interval = interval.label(), error = %e, "equity backfill failed")
                }
            }
            tokio::time::sleep(Duration::from_millis(400)).await;
        }
    }

    bus.publish(EngineEvent::FeedStatus(FeedStatus {
        feed: FEED_NAME.into(),
        health: FeedHealth::Degraded,
        detail: "cboe delayed quotes (~15m), polled".into(),
        ts_ms: now_ms(),
    }));

    let mut last_seen: std::collections::HashMap<String, EquityQuote> =
        std::collections::HashMap::new();
    let mut consecutive_failures = 0u32;
    loop {
        for symbol in &symbols {
            match egress.get_text(&quote_url(symbol)).await {
                Ok(raw) => {
                    consecutive_failures = 0;
                    let Some(q) = parse_quote(&raw) else { continue };
                    let changed = last_seen.get(symbol) != Some(&q);
                    if !changed {
                        continue;
                    }
                    last_seen.insert(symbol.clone(), q.clone());
                    let ts = now_ms();
                    store.set_last_price(symbol, q.price);
                    let tick = Tick {
                        symbol: symbol.clone(),
                        ts_ms: ts,
                        price: q.price,
                        size: 0.0,
                        aggressor: None,
                        venue: Venue::Cboe,
                    };
                    bus.publish(EngineEvent::Tick(tick.clone()));
                    let _ = tick_tx.send(tick).await;
                    if q.bid.is_finite() && q.ask.is_finite() && q.bid > 0.0 && q.ask >= q.bid {
                        bus.publish(EngineEvent::BookTop(BookTop {
                            symbol: symbol.clone(),
                            ts_ms: ts,
                            bid_px: q.bid,
                            bid_sz: q.bid_size.max(0.0),
                            ask_px: q.ask,
                            ask_sz: q.ask_size.max(0.0),
                        }));
                    }
                    // Honest DELAYED L1 "depth" for the actively-viewed symbol
                    // only (bandwidth bound): a single delayed level per side,
                    // is_live=false. Never fabricated as live L2.
                    if depth_rx.borrow().as_deref() == Some(symbol.as_str()) {
                        bus.publish(EngineEvent::Depth(equity_depth(symbol, &q)));
                    }
                }
                Err(e) => {
                    consecutive_failures += 1;
                    if consecutive_failures == 3 {
                        bus.publish(EngineEvent::FeedStatus(FeedStatus {
                            feed: FEED_NAME.into(),
                            health: FeedHealth::Down,
                            detail: format!("quote polling failing: {e}"),
                            ts_ms: now_ms(),
                        }));
                    }
                }
            }
            tokio::time::sleep(Duration::from_millis(300)).await;
        }
        // Sleep between poll cycles, but wake early when the actively-viewed
        // depth symbol changes so the ladder shows the last-known delayed
        // top-of-book immediately on open (rather than up to a poll away).
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_secs(POLL_SECS)) => {}
            changed = depth_rx.changed() => {
                if changed.is_err() {
                    return; // command side gone: squadron shutdown
                }
                let active = depth_rx.borrow_and_update().clone();
                if let Some(sym) = active {
                    if let Some(q) = last_seen.get(&sym) {
                        bus.publish(EngineEvent::Depth(equity_depth(&sym, q)));
                    }
                }
            }
        }
    }
}

/// Build the honest single-level DELAYED depth for an equity from its latest
/// CBOE top-of-book. `is_live = false` and `source` disclose that this is
/// delayed L1 with NO real order-book depth — the UI shows something truthful
/// without pretending crypto-style live L2. A side is present only when its
/// price is finite and positive (and the ask is not crossed); nothing is
/// fabricated. `count` is 0 (no order count in an L1 quote). Real, live equity
/// depth comes ONLY from the IBKR integration point below, never from here.
pub(crate) fn equity_depth(symbol: &str, q: &EquityQuote) -> BookDepth {
    let mut bids = Vec::new();
    let mut asks = Vec::new();
    if q.bid.is_finite() && q.bid > 0.0 {
        bids.push(BookLevel {
            px: q.bid,
            sz: q.bid_size.max(0.0),
            count: 0,
        });
    }
    if q.ask.is_finite() && q.ask > 0.0 && q.ask >= q.bid {
        asks.push(BookLevel {
            px: q.ask,
            sz: q.ask_size.max(0.0),
            count: 0,
        });
    }
    BookDepth {
        symbol: symbol.to_string(),
        bids,
        asks,
        depth: 1,
        source: EQUITY_DEPTH_SOURCE.into(),
        is_live: false,
        ts_ms: now_ms(),
    }
}

// ---------------------------------------------------------------------------
// IBKR INTEGRATION POINT (not yet wired).
//
// Real equity LEVEL 1 / LEVEL 2 depth and a real trade tape become available
// once the operator connects IB Gateway / TWS and the IBKR adapter (cx-broker,
// behind the `ibkr` feature) requests them:
//   - `reqMktData`  -> live/frozen top-of-book (L1) and last-trade prints;
//   - `reqMktDepth` -> the aggregated LEVEL 2 order book (per-venue depth),
// both subject to the user's own IBKR market-data subscriptions.
//
// When that path is built, the adapter constructs honest `BookDepth` /
// `TapePrint` values (labelling `is_live`/`source` per the ACTUAL subscription
// — live vs delayed vs frozen) and publishes them through these two functions.
// They are the ONLY sanctioned way to emit real equity depth/tape; the CBOE
// poller above never emits `is_live = true`. Keeping them here (not in
// cx-broker) preserves the bus-only rule: cx-broker publishes market data via
// cx-md's vocabulary without depending on the connectors.
// ---------------------------------------------------------------------------

/// Publish a LEVEL 2 (or L1) equity depth book obtained from the IBKR adapter.
/// The caller MUST label `is_live` / `source` truthfully for the subscription
/// that produced it (live `reqMktDepth`, delayed L1, or frozen). No-op-safe:
/// with no subscribers the event is simply dropped by the bus.
pub fn publish_ibkr_depth(bus: &Bus, depth: BookDepth) {
    bus.publish(EngineEvent::Depth(depth));
}

/// Publish a real equity trade print (Time & Sales) obtained from the IBKR
/// adapter's `reqMktData` last-trade stream. The caller labels `is_live`
/// truthfully and sets `aggressor` only when the venue actually discloses the
/// taker side (else `None` — never guessed).
pub fn publish_ibkr_tape(bus: &Bus, print: TapePrint) {
    bus.publish(EngineEvent::Tape(print));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quote_parses_and_rejects_garbage() {
        let raw = r#"{"data": {"symbol":"AAPL","current_price":308.45,"bid":308.44,"ask":308.47,"bid_size":200,"ask_size":40,"volume":75400626,"last_trade_time":"2026-07-02T16:00:00"}}"#;
        let q = parse_quote(raw).unwrap();
        assert_eq!(q.price, 308.45);
        assert_eq!(q.bid_size, 200.0);
        assert!(parse_quote("{}").is_none());
        assert!(parse_quote(r#"{"data":{"current_price":"NaN"}}"#).is_none());
    }

    #[test]
    fn equity_depth_is_honest_delayed_single_level() {
        // A live-looking CBOE quote still yields a DELAYED, is_live=false book
        // of a single level per side — never crypto-style live L2.
        let raw = r#"{"data":{"symbol":"AAPL","current_price":308.45,"bid":308.44,
            "ask":308.47,"bid_size":200,"ask_size":40,"volume":1,"last_trade_time":""}}"#;
        let q = parse_quote(raw).unwrap();
        let depth = equity_depth("AAPL", &q);
        assert!(!depth.is_live, "equity depth must never claim to be live");
        assert_eq!(depth.source, "cboe delayed L1 (no depth)");
        assert_eq!(depth.depth, 1);
        assert_eq!(depth.bids.len(), 1);
        assert_eq!(depth.asks.len(), 1);
        assert_eq!(depth.bids[0].px, 308.44);
        assert_eq!(depth.bids[0].sz, 200.0);
        assert_eq!(depth.bids[0].count, 0);
        assert_eq!(depth.asks[0].px, 308.47);
        assert_eq!(depth.asks[0].sz, 40.0);

        // A crossed / missing ask drops that side rather than fabricating one.
        let crossed = EquityQuote {
            price: 10.0,
            bid: 10.0,
            ask: 9.5, // crossed
            bid_size: 5.0,
            ask_size: 5.0,
            volume: 0.0,
            last_trade_time: String::new(),
        };
        let depth = equity_depth("XYZ", &crossed);
        assert_eq!(depth.bids.len(), 1);
        assert!(depth.asks.is_empty(), "a crossed ask is dropped, not shown");
        assert!(!depth.is_live);
    }

    #[test]
    fn chart_url_intraday_includes_pre_post_daily_does_not() {
        let m5 = chart_url("AAPL", "5d", "5m", true);
        assert_eq!(
            m5,
            "https://query1.finance.yahoo.com/v8/finance/chart/AAPL?range=5d&interval=5m&includePrePost=true"
        );
        let h1 = chart_url("AAPL", "3mo", "1h", true);
        assert!(h1.contains("&includePrePost=true"));
        let d1 = chart_url("AAPL", "5y", "1d", false);
        assert_eq!(
            d1,
            "https://query1.finance.yahoo.com/v8/finance/chart/AAPL?range=5y&interval=1d"
        );
        assert!(!d1.contains("includePrePost"));
    }

    #[test]
    fn yahoo_chart_parses_skips_nulls_and_caps() {
        let raw = r#"{"chart":{"result":[{"timestamp":[1751500800,1751587200,1751673600],
            "indicators":{"quote":[{
                "open":[100.0,null,105.0],"high":[105.0,107.0,107.5],
                "low":[99.0,103.0,104.0],"close":[104.0,106.0,106.5],
                "volume":[1000,900,1100]}]}}]}}"#;
        let bars = parse_yahoo_chart("AAPL", Interval::D1, raw, 10);
        // Middle row has a null open -> skipped.
        assert_eq!(bars.len(), 2);
        assert!(bars[0].ts_open_ms < bars[1].ts_open_ms);
        assert_eq!(bars[1].close, 106.5);
        assert!(bars.iter().all(|b| b.complete && b.interval == Interval::D1));
        // Capping keeps the newest.
        let capped = parse_yahoo_chart("AAPL", Interval::D1, raw, 1);
        assert_eq!(capped.len(), 1);
        assert_eq!(capped[0].close, 106.5);
        assert!(parse_yahoo_chart("AAPL", Interval::D1, "junk", 10).is_empty());
        assert!(parse_yahoo_chart("AAPL", Interval::D1, "{}", 10).is_empty());
    }

    /// Intraday bars keep Yahoo's true opens; D1 floors to UTC midnight.
    /// 2025-07-02 (EDT): 13:00 UTC = 09:00 ET pre-market hourly, 13:30 UTC
    /// = the 09:30-anchored RTH hourly. Flooring both to the 13:00 bucket
    /// used to collapse them into one bar (the store replaces same-ts tails)
    /// and shade the first regular hour as pre-market.
    #[test]
    fn intraday_keeps_true_opens_daily_floors() {
        let raw = r#"{"chart":{"result":[{"timestamp":[1751461200,1751463000],
            "indicators":{"quote":[{
                "open":[100.0,101.0],"high":[101.0,103.0],
                "low":[99.5,100.5],"close":[100.8,102.4],
                "volume":[500,9000]}]}}]}}"#;

        let h1 = parse_yahoo_chart("AAPL", Interval::H1, raw, 10);
        assert_eq!(h1.len(), 2, "pre-market and RTH bars must both survive");
        assert_eq!(h1[0].ts_open_ms, 1_751_461_200_000); // 09:00 ET, as sent
        assert_eq!(h1[1].ts_open_ms, 1_751_463_000_000); // 09:30 ET, not floored
        let m5 = parse_yahoo_chart("AAPL", Interval::M5, raw, 10);
        assert_eq!(m5[0].ts_open_ms, 1_751_461_200_000);

        let d1 = parse_yahoo_chart("AAPL", Interval::D1, raw, 10);
        // Both land in the same UTC day; the same-bucket tail replaces.
        assert!(d1.iter().all(|b| b.ts_open_ms == 1_751_414_400_000));
    }
}
