//! One-shot REST candle backfill through the [`Egress`] chokepoint.
//!
//! Invariants: history lands in the [`BarStore`] only — never on the bus
//! (snapshots serve history). Backfill failures degrade to an empty history,
//! never to a crash. Rows with non-finite or non-positive prices are dropped.

use std::time::Duration;

use cx_core::egress::Egress;
use cx_core::events::Bar;
use cx_core::store::BarStore;
use cx_core::time::bucket_start;
use cx_core::types::Interval;

/// Coinbase candle granularities (seconds) and the intervals they seed.
const GRANULARITIES: [(u32, Interval); 4] = [
    (60, Interval::M1),
    (300, Interval::M5),
    (900, Interval::M15),
    (3_600, Interval::H1),
];

/// Spacing between REST calls; the public endpoint rate-limits per IP.
const REQUEST_GAP: Duration = Duration::from_millis(200);

pub(crate) async fn run(egress: &Egress, store: &BarStore, symbols: &[String], max_bars: u32) {
    for symbol in symbols {
        for (granularity, interval) in GRANULARITIES {
            let url = format!(
                "https://api.exchange.coinbase.com/products/{symbol}/candles?granularity={granularity}"
            );
            match egress.get_text(&url).await {
                Ok(body) => {
                    let bars = parse_candles(symbol, interval, &body, max_bars as usize);
                    let n = bars.len();
                    for bar in bars {
                        store.push(bar);
                    }
                    tracing::info!(
                        target: "cx_md::backfill",
                        symbol,
                        interval = interval.label(),
                        bars = n,
                        "backfilled"
                    );
                }
                Err(e) => {
                    tracing::warn!(
                        target: "cx_md::backfill",
                        symbol,
                        interval = interval.label(),
                        error = %e,
                        "backfill request failed; continuing"
                    );
                }
            }
            tokio::time::sleep(REQUEST_GAP).await;
        }
    }
}

/// Parse a Coinbase candles body: JSON rows of
/// `[ts_sec, low, high, open, close, volume]`, newest-first. Returns at most
/// `max` bars, ascending by open time, all marked complete.
pub(crate) fn parse_candles(symbol: &str, interval: Interval, body: &str, max: usize) -> Vec<Bar> {
    let rows: Vec<[f64; 6]> = match serde_json::from_str(body) {
        Ok(rows) => rows,
        Err(e) => {
            tracing::warn!(target: "cx_md::backfill", symbol, error = %e, "unparseable candles body");
            return Vec::new();
        }
    };
    let mut bars: Vec<Bar> = rows
        .into_iter()
        .take(max)
        .filter_map(|row| candle_to_bar(symbol, interval, row))
        .collect();
    bars.reverse();
    bars
}

fn candle_to_bar(symbol: &str, interval: Interval, row: [f64; 6]) -> Option<Bar> {
    let [ts_sec, low, high, open, close, volume] = row;
    if !(ts_sec.is_finite() && ts_sec > 0.0) {
        return None;
    }
    for px in [low, high, open, close] {
        if !(px.is_finite() && px > 0.0) {
            return None;
        }
    }
    let volume = if volume.is_finite() && volume > 0.0 {
        volume
    } else {
        0.0
    };
    Some(Bar {
        symbol: symbol.to_string(),
        interval,
        ts_open_ms: bucket_start(ts_sec as i64 * 1_000, interval.ms()),
        open,
        high,
        low,
        close,
        volume,
        trade_count: 0,
        vwap: close,
        complete: true,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Canned Coinbase response: newest-first `[ts, low, high, open, close, vol]`.
    const FIXTURE: &str = r#"[
        [1751716800, 107900.5, 108250.0, 108000.0, 108100.25, 42.5],
        [1751716740, 107800.0, 108050.0, 107950.5, 108000.0, 17.25],
        [1751716680, 107700.0, 107990.0, 107750.0, 107950.5, 8.0]
    ]"#;

    #[test]
    fn fixture_parses_ascending_complete_bars() {
        let bars = parse_candles("BTC-USD", Interval::M1, FIXTURE, 300);
        assert_eq!(bars.len(), 3);
        let ts: Vec<i64> = bars.iter().map(|b| b.ts_open_ms).collect();
        assert_eq!(ts, vec![1_751_716_680_000, 1_751_716_740_000, 1_751_716_800_000]);
        for bar in &bars {
            assert!(bar.complete);
            assert_eq!(bar.symbol, "BTC-USD");
            assert_eq!(bar.interval, Interval::M1);
            assert_eq!(bar.trade_count, 0);
            assert_eq!(bar.vwap, bar.close);
            assert!(bar.low <= bar.open && bar.low <= bar.close);
            assert!(bar.high >= bar.open && bar.high >= bar.close);
        }
        // Row order maps [ts, low, high, open, close, volume] correctly.
        let newest = &bars[2];
        assert_eq!(newest.low, 107_900.5);
        assert_eq!(newest.high, 108_250.0);
        assert_eq!(newest.open, 108_000.0);
        assert_eq!(newest.close, 108_100.25);
        assert_eq!(newest.volume, 42.5);
    }

    #[test]
    fn max_caps_to_newest_rows() {
        let bars = parse_candles("BTC-USD", Interval::M1, FIXTURE, 2);
        assert_eq!(bars.len(), 2);
        // Newest two rows survive, still ascending.
        assert_eq!(bars[0].ts_open_ms, 1_751_716_740_000);
        assert_eq!(bars[1].ts_open_ms, 1_751_716_800_000);
    }

    #[test]
    fn bad_rows_and_bodies_degrade_to_empty_or_skipped() {
        assert!(parse_candles("BTC-USD", Interval::M1, "surprise!", 10).is_empty());
        assert!(parse_candles("BTC-USD", Interval::M1, r#"{"error":"rate limit"}"#, 10).is_empty());
        // A row with a non-positive price is dropped; the good row survives.
        let mixed = r#"[
            [1751716800, -1.0, 108250.0, 108000.0, 108100.25, 42.5],
            [1751716740, 107800.0, 108050.0, 107950.5, 108000.0, 17.25]
        ]"#;
        let bars = parse_candles("BTC-USD", Interval::M1, mixed, 10);
        assert_eq!(bars.len(), 1);
        assert_eq!(bars[0].ts_open_ms, 1_751_716_740_000);
    }
}
