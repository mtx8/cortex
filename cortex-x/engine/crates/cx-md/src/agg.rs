//! Tick -> bar aggregation for every [`Interval`] per symbol.
//!
//! Invariants:
//! - Input arrives on one ordered mpsc; stale ticks (older bucket than the
//!   forming bar) are dropped, never folded backwards.
//! - The forming bar is written to the [`BarStore`] on every tick; it is
//!   published on the bus at most once per second per (symbol, interval).
//! - A completed bar is stored and published exactly once, at rollover,
//!   before the new forming bar of the next bucket.
//! - vwap = sum(px*sz)/sum(sz), falling back to close while volume is zero.
//! - Equity (bare-ticker) D1 bars are official-session bars: extended-hours
//!   prints never fold into the daily OHLC, so the close stays the last RTH
//!   print (the prior-session reference and gap math read it). A print from
//!   a newer UTC day still completes the prior forming daily bar.

use std::collections::HashMap;
use std::sync::Arc;

use cx_core::events::{Bar, EngineEvent, Tick};
use cx_core::store::BarStore;
use cx_core::time::{bucket_start, now_ms};
use cx_core::types::Interval;
use cx_core::Bus;
use tokio::sync::mpsc;

/// Minimum wall-clock gap between two forming-bar publishes of one series.
const FORMING_PUBLISH_MS: i64 = 1_000;

pub(crate) async fn run(mut rx: mpsc::Receiver<Tick>, bus: Arc<Bus>, store: Arc<BarStore>) {
    let mut agg = Aggregator::new();
    while let Some(tick) = rx.recv().await {
        let out = agg.on_tick(&tick, now_ms());
        for bar in out.store {
            store.push(bar);
        }
        for bar in out.publish {
            bus.publish(EngineEvent::Bar(bar));
        }
    }
}

#[derive(Debug, Default)]
pub(crate) struct AggOutput {
    /// Bars to write to the store (forming replaces tail, completed rolls up).
    pub store: Vec<Bar>,
    /// Bars to publish on the bus (completed always; forming throttled).
    pub publish: Vec<Bar>,
}

struct Forming {
    bar: Bar,
    /// Running sum of px*sz for vwap.
    notional: f64,
}

pub(crate) struct Aggregator {
    forming: HashMap<(String, Interval), Forming>,
    last_pub_ms: HashMap<(String, Interval), i64>,
}

impl Aggregator {
    pub(crate) fn new() -> Self {
        Self {
            forming: HashMap::new(),
            last_pub_ms: HashMap::new(),
        }
    }

    pub(crate) fn on_tick(&mut self, tick: &Tick, now: i64) -> AggOutput {
        let mut out = AggOutput::default();
        if !(tick.price.is_finite() && tick.price > 0.0) {
            return out;
        }
        let size = if tick.size.is_finite() && tick.size > 0.0 {
            tick.size
        } else {
            0.0
        };

        for interval in Interval::ALL {
            let bucket = bucket_start(tick.ts_ms, interval.ms());
            let key = (tick.symbol.clone(), interval);
            // Equity daily bars track the official session only: a
            // pre-market or after-hours print neither opens nor updates the
            // D1 OHLC (the close must stay the last RTH print), but a print
            // from a NEWER UTC day still completes yesterday's forming bar
            // — otherwise it would sit forming until the next open.
            if interval == Interval::D1 && is_equity(&tick.symbol) && !us_rth(tick.ts_ms) {
                if let Some(f) = self.forming.get(&key) {
                    if bucket > f.bar.ts_open_ms {
                        let mut completed = f.bar.clone();
                        completed.complete = true;
                        out.store.push(completed.clone());
                        out.publish.push(completed);
                        self.forming.remove(&key);
                    }
                }
                continue;
            }
            match self.forming.get_mut(&key) {
                None => {
                    let f = new_forming(tick, interval, bucket, size);
                    out.store.push(f.bar.clone());
                    self.forming.insert(key.clone(), f);
                }
                Some(f) if bucket == f.bar.ts_open_ms => {
                    f.bar.high = f.bar.high.max(tick.price);
                    f.bar.low = f.bar.low.min(tick.price);
                    f.bar.close = tick.price;
                    f.bar.volume += size;
                    f.notional += tick.price * size;
                    f.bar.trade_count += 1;
                    f.bar.vwap = if f.bar.volume > 0.0 {
                        f.notional / f.bar.volume
                    } else {
                        f.bar.close
                    };
                    out.store.push(f.bar.clone());
                }
                Some(f) if bucket > f.bar.ts_open_ms => {
                    let mut completed = f.bar.clone();
                    completed.complete = true;
                    out.store.push(completed.clone());
                    out.publish.push(completed);
                    let nf = new_forming(tick, interval, bucket, size);
                    out.store.push(nf.bar.clone());
                    *f = nf;
                }
                Some(_) => {
                    // Stale tick from an already-closed bucket: drop.
                    continue;
                }
            }

            let last = self.last_pub_ms.get(&key).copied().unwrap_or(i64::MIN);
            if now.saturating_sub(last) >= FORMING_PUBLISH_MS {
                if let Some(f) = self.forming.get(&key) {
                    out.publish.push(f.bar.clone());
                    self.last_pub_ms.insert(key, now);
                }
            }
        }
        out
    }
}

/// Bare tickers are equities; dashed products route to the crypto feed.
fn is_equity(symbol: &str) -> bool {
    !symbol.contains('-')
}

/// True when the instant falls inside US regular trading hours
/// (09:30 ..< 16:00 US/Eastern), DST-correct per the post-2007 US rules:
/// EDT from 2:00 the second Sunday of March through 2:00 the first Sunday
/// of November. Mirror of the app's `ChartMath.isExtendedHours`, negated.
fn us_rth(ts_ms: i64) -> bool {
    use chrono::{Datelike, TimeZone, Utc};
    let Some(dt) = Utc.timestamp_millis_opt(ts_ms).single() else {
        return false;
    };
    let (dst_start, dst_end) = dst_bounds_utc_ms(dt.year());
    let offset_hours: i64 = if ts_ms >= dst_start && ts_ms < dst_end { -4 } else { -5 };
    let et_minutes = (ts_ms + offset_hours * 3_600_000).rem_euclid(86_400_000) / 60_000;
    (570..960).contains(&et_minutes)
}

/// UTC-ms instants when US/Eastern enters and leaves daylight time:
/// 2:00 EST on the second Sunday of March (07:00 UTC) and 2:00 EDT on the
/// first Sunday of November (06:00 UTC).
fn dst_bounds_utc_ms(year: i32) -> (i64, i64) {
    use chrono::{Datelike, TimeZone, Utc, Weekday};
    let sunday_ms = |month: u32, days: std::ops::RangeInclusive<u32>, hour_utc: u32| {
        days.filter_map(|d| Utc.with_ymd_and_hms(year, month, d, hour_utc, 0, 0).single())
            .find(|d| d.weekday() == Weekday::Sun)
            .map(|d| d.timestamp_millis())
            .unwrap_or(i64::MAX) // unreachable: every 7-day window has a Sunday
    };
    (sunday_ms(3, 8..=14, 7), sunday_ms(11, 1..=7, 6))
}

fn new_forming(tick: &Tick, interval: Interval, bucket: i64, size: f64) -> Forming {
    Forming {
        bar: Bar {
            symbol: tick.symbol.clone(),
            interval,
            ts_open_ms: bucket,
            open: tick.price,
            high: tick.price,
            low: tick.price,
            close: tick.price,
            volume: size,
            trade_count: 1,
            vwap: tick.price,
            complete: false,
        },
        notional: tick.price * size,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cx_core::types::{Side, Venue};

    fn tick(ts_ms: i64, price: f64, size: f64) -> Tick {
        Tick {
            symbol: "BTC-USD".into(),
            ts_ms,
            price,
            size,
            aggressor: Some(Side::Buy),
            venue: Venue::Synthetic,
        }
    }

    fn m1(bars: &[Bar]) -> Vec<&Bar> {
        bars.iter().filter(|b| b.interval == Interval::M1).collect()
    }

    #[test]
    fn minute_rollover_emits_complete_ohlcv() {
        let mut agg = Aggregator::new();
        agg.on_tick(&tick(59_100, 100.0, 1.0), 59_100);
        agg.on_tick(&tick(59_600, 102.0, 3.0), 59_600);
        agg.on_tick(&tick(59_900, 99.0, 1.0), 59_900);
        // Tick in the next minute bucket triggers the M1 rollover.
        let out = agg.on_tick(&tick(60_500, 105.0, 2.0), 60_500);

        let completed: Vec<&Bar> = out
            .publish
            .iter()
            .filter(|b| b.interval == Interval::M1 && b.complete)
            .collect();
        assert_eq!(completed.len(), 1);
        let bar = completed[0];
        assert_eq!(bar.ts_open_ms, 0);
        assert_eq!(bar.open, 100.0);
        assert_eq!(bar.high, 102.0);
        assert_eq!(bar.low, 99.0);
        assert_eq!(bar.close, 99.0);
        assert!((bar.volume - 5.0).abs() < 1e-12);
        assert_eq!(bar.trade_count, 3);
        // vwap = (100*1 + 102*3 + 99*1) / 5
        assert!((bar.vwap - 101.0).abs() < 1e-12);

        // The new forming M1 bar opens at the next bucket with the new tick.
        let forming = m1(&out.store)
            .into_iter()
            .find(|b| !b.complete)
            .expect("new forming bar");
        assert_eq!(forming.ts_open_ms, 60_000);
        assert_eq!(forming.open, 105.0);
        assert_eq!(forming.trade_count, 1);
    }

    #[test]
    fn forming_publish_is_throttled_per_second() {
        let mut agg = Aggregator::new();
        let a = agg.on_tick(&tick(10, 100.0, 1.0), 10);
        assert!(a
            .publish
            .iter()
            .any(|b| b.interval == Interval::M1 && !b.complete));
        // 500ms later: same bucket, inside the throttle window -> no forming publish.
        let b = agg.on_tick(&tick(510, 101.0, 1.0), 510);
        assert!(!b.publish.iter().any(|x| x.interval == Interval::M1));
        // But the store still saw the updated forming bar.
        assert!(m1(&b.store).iter().any(|x| x.close == 101.0 && !x.complete));
        // 1.2s after the first publish the forming bar flows again.
        let c = agg.on_tick(&tick(1_300, 102.0, 1.0), 1_300);
        assert!(c
            .publish
            .iter()
            .any(|x| x.interval == Interval::M1 && !x.complete && x.close == 102.0));
    }

    #[test]
    fn stale_and_invalid_ticks_are_dropped() {
        let mut agg = Aggregator::new();
        agg.on_tick(&tick(120_000, 100.0, 1.0), 120_000);
        // Older bucket than the forming bar: dropped for every interval.
        let out = agg.on_tick(&tick(30_000, 999.0, 1.0), 120_100);
        assert!(m1(&out.store).is_empty());
        // NaN / non-positive prices never touch state.
        assert!(agg.on_tick(&tick(121_000, f64::NAN, 1.0), 121_000).store.is_empty());
        assert!(agg.on_tick(&tick(121_000, -5.0, 1.0), 121_000).store.is_empty());
    }

    #[test]
    fn zero_volume_vwap_falls_back_to_close() {
        let mut agg = Aggregator::new();
        let out = agg.on_tick(&tick(5, 250.0, 0.0), 5);
        let bar = m1(&out.store)[0];
        assert_eq!(bar.vwap, 250.0);
        assert_eq!(bar.volume, 0.0);
    }

    fn ts(y: i32, mo: u32, d: u32, h: u32, mi: u32) -> i64 {
        use chrono::{TimeZone, Utc};
        Utc.with_ymd_and_hms(y, mo, d, h, mi, 0)
            .unwrap()
            .timestamp_millis()
    }

    fn equity_tick(ts_ms: i64, price: f64) -> Tick {
        Tick {
            symbol: "AAPL".into(),
            ts_ms,
            price,
            size: 0.0,
            aggressor: None,
            venue: Venue::Cboe,
        }
    }

    #[test]
    fn us_rth_is_dst_correct() {
        // January (EST, UTC-5): RTH = 14:30 ..< 21:00 UTC.
        assert!(!us_rth(ts(2026, 1, 15, 14, 29)));
        assert!(us_rth(ts(2026, 1, 15, 14, 30)));
        assert!(us_rth(ts(2026, 1, 15, 20, 59)));
        assert!(!us_rth(ts(2026, 1, 15, 21, 0)));
        // July (EDT, UTC-4): RTH = 13:30 ..< 20:00 UTC.
        assert!(!us_rth(ts(2026, 7, 15, 13, 29)));
        assert!(us_rth(ts(2026, 7, 15, 13, 30)));
        assert!(us_rth(ts(2026, 7, 15, 19, 59)));
        assert!(!us_rth(ts(2026, 7, 15, 20, 0)));
        // EDT begins 2026-03-08 (second Sunday of March): the Friday before
        // is still EST, the Monday after is EDT.
        assert!(us_rth(ts(2026, 3, 6, 14, 30)));
        assert!(!us_rth(ts(2026, 3, 6, 13, 30)));
        assert!(us_rth(ts(2026, 3, 9, 13, 30)));
        // EDT ends 2026-11-01 (first Sunday of November).
        assert!(us_rth(ts(2026, 10, 30, 13, 30)));
        assert!(!us_rth(ts(2026, 11, 2, 13, 30)));
        assert!(us_rth(ts(2026, 11, 2, 14, 30)));
    }

    #[test]
    fn equity_daily_bar_ignores_extended_hours_prints() {
        let mut agg = Aggregator::new();
        let d1 = |bars: &[Bar]| -> Vec<Bar> {
            bars.iter()
                .filter(|b| b.interval == Interval::D1)
                .cloned()
                .collect()
        };

        // Pre-market print (08:00 ET): no daily bar forms, M1 still does.
        let pre = agg.on_tick(&equity_tick(ts(2026, 7, 15, 12, 0), 99.0), 0);
        assert!(d1(&pre.store).is_empty());
        assert!(pre.store.iter().any(|b| b.interval == Interval::M1));

        // RTH prints open and update the daily bar.
        let open = agg.on_tick(&equity_tick(ts(2026, 7, 15, 13, 30), 100.0), 1);
        assert_eq!(d1(&open.store).len(), 1);
        assert_eq!(d1(&open.store)[0].open, 100.0);
        let rth = agg.on_tick(&equity_tick(ts(2026, 7, 15, 19, 59), 104.0), 2);
        assert_eq!(d1(&rth.store)[0].close, 104.0);

        // After-hours drift in the same UTC day: the daily bar must not move.
        let ah = agg.on_tick(&equity_tick(ts(2026, 7, 15, 21, 0), 90.0), 3);
        assert!(d1(&ah.store).is_empty());

        // First print past UTC midnight (20:30 ET, still after-hours)
        // completes yesterday's bar with the last RTH close — never the
        // after-hours print — and opens nothing new.
        let roll = agg.on_tick(&equity_tick(ts(2026, 7, 16, 0, 30), 91.0), 4);
        let completed = d1(&roll.publish);
        assert_eq!(completed.len(), 1);
        assert!(completed[0].complete);
        assert_eq!(completed[0].close, 104.0);
        assert_eq!(completed[0].ts_open_ms, ts(2026, 7, 15, 0, 0));
        assert!(d1(&roll.store).iter().all(|b| b.complete));

        // The next session's first RTH print opens a fresh daily bar.
        let next = agg.on_tick(&equity_tick(ts(2026, 7, 16, 13, 30), 102.0), 5);
        let formed = d1(&next.store);
        assert_eq!(formed.len(), 1);
        assert_eq!(formed[0].ts_open_ms, ts(2026, 7, 16, 0, 0));
        assert_eq!(formed[0].open, 102.0);
    }

    #[test]
    fn crypto_daily_bars_form_around_the_clock() {
        let mut agg = Aggregator::new();
        // 21:00 UTC is after-hours for equities; crypto trades 24/7.
        let out = agg.on_tick(&tick(ts(2026, 7, 15, 21, 0), 50_000.0, 1.0), 0);
        assert!(out.store.iter().any(|b| b.interval == Interval::D1));
    }
}
