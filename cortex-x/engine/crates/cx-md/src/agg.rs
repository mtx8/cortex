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
}
