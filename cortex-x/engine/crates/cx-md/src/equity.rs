//! Equity feed: CBOE delayed quotes (keyless, ~15 min delayed) polled on a
//! slow cadence, plus Stooq daily-history backfill. Delayed data is honest
//! data: the feed advertises itself as Degraded (never Live) so downstream
//! consumers and the operator can see exactly what they are trading on.

use std::sync::Arc;
use std::time::Duration;

use cx_core::egress::Egress;
use cx_core::events::{Bar, BookTop, EngineEvent, FeedHealth, FeedStatus, Tick};
use cx_core::store::BarStore;
use cx_core::time::now_ms;
use cx_core::types::{Interval, Venue};
use cx_core::Bus;

const POLL_SECS: u64 = 20;
const FEED_NAME: &str = "cboe-equities";

fn quote_url(symbol: &str) -> String {
    format!("https://cdn.cboe.com/api/global/delayed_quotes/quotes/{symbol}.json")
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
        bars.push(Bar {
            symbol: symbol.to_string(),
            interval,
            ts_open_ms: cx_core::time::bucket_start(t * 1000, interval.ms()),
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
) {
    if symbols.is_empty() {
        return;
    }
    let egress = Egress::new();

    // History first, so charts and analytics have context immediately:
    // a year of dailies, a month of hourlies, five days of 5-minute bars.
    const RANGES: [(Interval, &str, &str); 3] = [
        (Interval::D1, "2y", "1d"),
        (Interval::H1, "3mo", "1h"),
        (Interval::M5, "5d", "5m"),
    ];
    for symbol in &symbols {
        for (interval, range, gran) in RANGES {
            let url = format!(
                "https://query1.finance.yahoo.com/v8/finance/chart/{symbol}?range={range}&interval={gran}"
            );
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
        tokio::time::sleep(Duration::from_secs(POLL_SECS)).await;
    }
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
}
