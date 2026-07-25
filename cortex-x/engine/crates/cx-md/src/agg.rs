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
//! - Live bars and REST-backfilled bars share ONE [`BarStore`] series per
//!   (symbol, interval), so they MUST agree on the bucket grid. [`bar_bucket`]
//!   is the single definition of that grid for both sides (cx-md's Yahoo
//!   parser calls it too).
//! - The aggregator never silently destroys a venue's own bar. A backfill row
//!   or exchange candle for the bucket being formed is folded in (its true
//!   open, running high/low and real volume), and a bucket the venue already
//!   reported COMPLETE and wall-clock has left behind is left untouched.
//!   Venue-written bars are recognised by `trade_count == 0` — both cx-md
//!   backfill parsers stamp it, and every aggregator-built bar starts at 1.
//! - `trade_count` counts ticks folded, which for a quote-polled feed (CBOE
//!   equities) means quote updates, not exchange prints. It is not a print
//!   count and nothing renders it as one.

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

/// Minutes into the US/Eastern day at which regular trading opens (09:30) and
/// closes (16:00). The 09:30 offset is why [`bar_bucket`] cannot simply floor
/// equity hourlies to the UTC hour.
const RTH_OPEN_MIN: i64 = 570;
const RTH_CLOSE_MIN: i64 = 960;

/// How long after opening a bucket the aggregator keeps watching the store for
/// a venue bar landing in it. The crypto REST backfill runs CONCURRENTLY with
/// the websocket connect, so its candle for the bucket live aggregation just
/// opened can arrive seconds later — and our next push would replace it. One
/// minute after the bucket opened the one-shot backfill is long finished.
const VENUE_RACE_MS: i64 = 60_000;

/// How far back from the tail to look for a venue bar occupying a bucket. The
/// ~15-minute-delayed equity feed forms buckets that sit BEHIND the newest
/// backfilled row, so the tail alone is not enough.
const VENUE_LOOKBACK: usize = 16;

pub(crate) async fn run(mut rx: mpsc::Receiver<Tick>, bus: Arc<Bus>, store: Arc<BarStore>) {
    let mut agg = Aggregator::new();
    while let Some(tick) = rx.recv().await {
        // The store is read as well as written: a backfill row already sitting
        // in the bucket being formed must be folded in, not overwritten.
        let out = agg.on_tick(&tick, now_ms(), Some(store.as_ref()));
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
    /// Wall-clock deadline for watching the store for a venue bar that lands
    /// in this bucket after we opened it (see [`VENUE_RACE_MS`]). Set to
    /// `i64::MIN` once one has been absorbed — a bucket is folded in once.
    venue_watch_until_ms: i64,
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

    /// Fold one tick into every interval's forming bar.
    ///
    /// `now` is the wall clock (injected for tests) — it gates the forming-bar
    /// publish throttle and decides which buckets wall-clock has left behind.
    /// `store` is the SHARED bar store: read (never written) so a venue's own
    /// bar already occupying a bucket is folded in rather than overwritten by
    /// the caller's subsequent `push`. `None` disables that (tests).
    pub(crate) fn on_tick(
        &mut self,
        tick: &Tick,
        now: i64,
        store: Option<&BarStore>,
    ) -> AggOutput {
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
            let bucket = bar_bucket(&tick.symbol, interval, tick.ts_ms);
            let key = (tick.symbol.clone(), interval);
            // Equity daily bars track the official session only: a
            // pre-market or after-hours print neither opens nor updates the
            // D1 OHLC (the close must stay the last RTH print), but a print
            // from a NEWER UTC day still completes yesterday's forming bar
            // — otherwise it would sit forming until the next open.
            if interval == Interval::D1 && is_equity(&tick.symbol) && !us_rth(tick.ts_ms) {
                self.roll_up_older(&key, bucket, &mut out);
                continue;
            }
            // A bucket the VENUE already reported as a finished bar, and that
            // wall-clock has genuinely left behind, is authoritative. The CBOE
            // quote feed is ~15 minutes delayed, so it walks through buckets
            // the Yahoo backfill already delivered complete; re-forming one
            // would replace real OHLCV with a one-tick doji, because
            // `BarStore::push` replaces a same-timestamp row wholesale. Only
            // equities are checked — a real-time feed's current bucket has by
            // definition not ended, so this can never stall a live series.
            if is_equity(&tick.symbol) && bucket.saturating_add(interval.ms()) <= now {
                if let Some(v) = venue_bar(store, &tick.symbol, interval, bucket, VENUE_LOOKBACK) {
                    if v.complete && is_venue_bar(&v) {
                        self.roll_up_older(&key, bucket, &mut out);
                        continue;
                    }
                }
            }
            match self.forming.get_mut(&key) {
                None => {
                    let f = start_forming(tick, interval, bucket, size, now, store);
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
                    // The concurrent backfill can land the venue's partial bar
                    // for THIS bucket after we opened it (backfill task vs
                    // websocket connect is a race). Absorb it once, inside the
                    // startup window, so the venue's true open / high / low /
                    // volume survive our next push instead of being replaced.
                    if now <= f.venue_watch_until_ms {
                        if let Some(v) = venue_bar(store, &tick.symbol, interval, bucket, 1) {
                            if is_venue_bar(&v) {
                                absorb_venue_bar(f, &v);
                                f.venue_watch_until_ms = i64::MIN;
                            }
                        }
                    }
                    out.store.push(f.bar.clone());
                }
                Some(f) if bucket > f.bar.ts_open_ms => {
                    let mut completed = f.bar.clone();
                    completed.complete = true;
                    out.store.push(completed.clone());
                    out.publish.push(completed);
                    let nf = start_forming(tick, interval, bucket, size, now, store);
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

    /// Complete and emit the forming bar of `key` when `bucket` has moved past
    /// it. Used by every path that decides NOT to fold the tick into its own
    /// bucket (the equity D1 session gate, the venue-owned-bucket guard):
    /// without it the previous bucket's bar would sit forming forever.
    fn roll_up_older(&mut self, key: &(String, Interval), bucket: i64, out: &mut AggOutput) {
        let Some(f) = self.forming.get(key) else {
            return;
        };
        if bucket <= f.bar.ts_open_ms {
            return;
        }
        let mut completed = f.bar.clone();
        completed.complete = true;
        out.store.push(completed.clone());
        out.publish.push(completed);
        self.forming.remove(key);
    }
}

/// Bare tickers are equities; dashed products route to the crypto feed.
fn is_equity(symbol: &str) -> bool {
    !symbol.contains('-')
}

/// The bucket an instant belongs to for this (symbol, interval) — the ONE
/// definition of the bar grid, shared by live aggregation and the Yahoo
/// backfill parser (`equity::parse_yahoo_chart`), because both write the same
/// [`BarStore`] series and two grids in one series corrupts it.
///
/// Everything floors to the plain UTC grid EXCEPT equity hourlies. US regular
/// trading opens at 09:30 ET, and Yahoo anchors its RTH hourlies there
/// (09:30, 10:30 … 15:30, the last running the half hour to the 16:00 close)
/// while emitting pre/post-market hourlies on the ET hour. Flooring live
/// equity H1 ticks to the UTC hour instead produced two hourly grids 30
/// minutes out of phase inside one series, and filed the 09:30–10:00 opening
/// prints under a 09:00 bar the chart shades and tags as extended hours.
/// Sub-hour intervals need no special case: the 30-minute offset is a whole
/// multiple of 1s/1m/5m/15m, and the ET offset is a whole number of hours, so
/// 09:30 ET is already on their UTC grid. D1 stays UTC-midnight bucketed (the
/// backfill floors its daily rows the same way) with the RTH session gate in
/// [`Aggregator::on_tick`] deciding which prints belong to it.
pub(crate) fn bar_bucket(symbol: &str, interval: Interval, ts_ms: i64) -> i64 {
    if interval == Interval::H1 && is_equity(symbol) {
        return equity_hour_bucket(ts_ms);
    }
    bucket_start(ts_ms, interval.ms())
}

/// Equity hourly grid: 09:30-anchored inside regular hours, ET-hour aligned
/// outside them (which is UTC-hour aligned too — the ET offset is whole hours).
/// Monotonic in `ts_ms` across both boundaries, so the aggregator's
/// stale-bucket guard still holds: 09:29 -> 09:00, 09:30 -> 09:30,
/// 15:59 -> 15:30, 16:00 -> 16:00.
fn equity_hour_bucket(ts_ms: i64) -> i64 {
    const HOUR_MS: i64 = 3_600_000;
    let Some(off) = et_offset_ms(ts_ms) else {
        return bucket_start(ts_ms, HOUR_MS);
    };
    let et = ts_ms + off; // ET wall clock, expressed as if it were UTC
    let day = et - et.rem_euclid(86_400_000);
    let open = day + RTH_OPEN_MIN * 60_000;
    let close = day + RTH_CLOSE_MIN * 60_000;
    if et < open || et >= close {
        return bucket_start(ts_ms, HOUR_MS);
    }
    open + (et - open) / HOUR_MS * HOUR_MS - off
}

/// A bar written by a REST backfill / exchange candle rather than by this
/// aggregator. Both cx-md backfill parsers stamp `trade_count: 0`, and
/// [`new_forming`] starts every aggregator bar at 1, so the field separates
/// the two cleanly. Keep that invariant: the venue-bar handling below relies
/// on it to avoid re-absorbing its own output.
fn is_venue_bar(b: &Bar) -> bool {
    b.trade_count == 0
}

/// The bar already in the store for `bucket`, searched `depth` bars back from
/// the tail. Cheap by design: called when a bucket is opened, or during the
/// bounded startup race window.
fn venue_bar(
    store: Option<&BarStore>,
    symbol: &str,
    interval: Interval,
    bucket: i64,
    depth: usize,
) -> Option<Bar> {
    store?
        .recent(symbol, interval, depth)
        .into_iter()
        .rev()
        .find(|b| b.ts_open_ms == bucket)
}

/// Open a bucket, folding in the venue's own partial bar for it when the store
/// already holds one. Without this the first live tick of a bucket published a
/// bar whose open=high=low=close was that single tick — replacing the venue's
/// real row (true bucket open, running high/low, real volume) because
/// `BarStore::push` overwrites a same-timestamp tail. Operator-visible as the
/// newest candle collapsing to a doji at the current price with a stub volume
/// bar, and as today's daily candle opening at "the price when the engine
/// started" instead of the session open.
fn start_forming(
    tick: &Tick,
    interval: Interval,
    bucket: i64,
    size: f64,
    now: i64,
    store: Option<&BarStore>,
) -> Forming {
    let mut f = new_forming(tick, interval, bucket, size, now);
    if let Some(v) = venue_bar(store, &tick.symbol, interval, bucket, VENUE_LOOKBACK) {
        if is_venue_bar(&v) {
            absorb_venue_bar(&mut f, &v);
            f.venue_watch_until_ms = i64::MIN;
        }
    }
    f
}

/// Fold a venue bar occupying the same bucket into a forming bar. The venue
/// watched the whole bucket from its true open; our ticks only ever saw the
/// slice since the feed connected — so open, high, low and volume come from the
/// venue and only `close` (the freshest print) stays ours.
fn absorb_venue_bar(f: &mut Forming, v: &Bar) {
    if v.open.is_finite() && v.open > 0.0 {
        f.bar.open = v.open;
    }
    // NaN-safe by construction: f64::max/min return the non-NaN operand.
    f.bar.high = f.bar.high.max(v.high);
    f.bar.low = f.bar.low.min(v.low);
    if v.volume.is_finite() && v.volume > f.bar.volume {
        // The venue's volume already counts every print in this bucket,
        // including the ones our ticks represent — take it as the baseline
        // instead of adding, so overlapping prints are not double counted.
        let px = if v.vwap.is_finite() && v.vwap > 0.0 {
            v.vwap
        } else {
            v.close
        };
        f.notional = v.volume * px;
        f.bar.volume = v.volume;
    }
    f.bar.vwap = if f.bar.volume > 0.0 {
        f.notional / f.bar.volume
    } else {
        f.bar.close
    };
}

/// True when the instant falls inside US regular trading hours
/// (09:30 ..< 16:00 US/Eastern), DST-correct per the post-2007 US rules:
/// EDT from 2:00 the second Sunday of March through 2:00 the first Sunday
/// of November. Mirror of the app's `ChartMath.isExtendedHours`, negated.
fn us_rth(ts_ms: i64) -> bool {
    let Some(off) = et_offset_ms(ts_ms) else {
        return false;
    };
    let et_minutes = (ts_ms + off).rem_euclid(86_400_000) / 60_000;
    (RTH_OPEN_MIN..RTH_CLOSE_MIN).contains(&et_minutes)
}

/// True when `ts_ms` falls inside US daylight saving time (US/Eastern rules).
/// Exposed for the CBOE quote parser, which has to resolve a ZONELESS local
/// Eastern trade-time string back to an instant.
pub(crate) fn is_us_eastern_dst(ts_ms: i64) -> bool {
    use chrono::{Datelike, TimeZone, Utc};
    let Some(dt) = Utc.timestamp_millis_opt(ts_ms).single() else {
        return false;
    };
    let (dst_start, dst_end) = dst_bounds_utc_ms(dt.year());
    ts_ms >= dst_start && ts_ms < dst_end
}

/// US/Eastern UTC offset in ms for an instant, or `None` when the instant is
/// not a representable calendar date — a garbage timestamp off a feed must not
/// be able to overflow the arithmetic that follows.
fn et_offset_ms(ts_ms: i64) -> Option<i64> {
    use chrono::{TimeZone, Utc};
    Utc.timestamp_millis_opt(ts_ms).single()?;
    Some(if is_us_eastern_dst(ts_ms) {
        -4 * 3_600_000
    } else {
        -5 * 3_600_000
    })
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

fn new_forming(tick: &Tick, interval: Interval, bucket: i64, size: f64, now: i64) -> Forming {
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
            // Never 0: `is_venue_bar` uses trade_count == 0 to tell a backfill
            // row apart from an aggregator bar.
            trade_count: 1,
            vwap: tick.price,
            complete: false,
        },
        notional: tick.price * size,
        venue_watch_until_ms: now.saturating_add(VENUE_RACE_MS),
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
        agg.on_tick(&tick(59_100, 100.0, 1.0), 59_100, None);
        agg.on_tick(&tick(59_600, 102.0, 3.0), 59_600, None);
        agg.on_tick(&tick(59_900, 99.0, 1.0), 59_900, None);
        // Tick in the next minute bucket triggers the M1 rollover.
        let out = agg.on_tick(&tick(60_500, 105.0, 2.0), 60_500, None);

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
        let a = agg.on_tick(&tick(10, 100.0, 1.0), 10, None);
        assert!(a
            .publish
            .iter()
            .any(|b| b.interval == Interval::M1 && !b.complete));
        // 500ms later: same bucket, inside the throttle window -> no forming publish.
        let b = agg.on_tick(&tick(510, 101.0, 1.0), 510, None);
        assert!(!b.publish.iter().any(|x| x.interval == Interval::M1));
        // But the store still saw the updated forming bar.
        assert!(m1(&b.store).iter().any(|x| x.close == 101.0 && !x.complete));
        // 1.2s after the first publish the forming bar flows again.
        let c = agg.on_tick(&tick(1_300, 102.0, 1.0), 1_300, None);
        assert!(c
            .publish
            .iter()
            .any(|x| x.interval == Interval::M1 && !x.complete && x.close == 102.0));
    }

    #[test]
    fn stale_and_invalid_ticks_are_dropped() {
        let mut agg = Aggregator::new();
        agg.on_tick(&tick(120_000, 100.0, 1.0), 120_000, None);
        // Older bucket than the forming bar: dropped for every interval.
        let out = agg.on_tick(&tick(30_000, 999.0, 1.0), 120_100, None);
        assert!(m1(&out.store).is_empty());
        // NaN / non-positive prices never touch state.
        assert!(agg.on_tick(&tick(121_000, f64::NAN, 1.0), 121_000, None).store.is_empty());
        assert!(agg.on_tick(&tick(121_000, -5.0, 1.0), 121_000, None).store.is_empty());
    }

    #[test]
    fn zero_volume_vwap_falls_back_to_close() {
        let mut agg = Aggregator::new();
        let out = agg.on_tick(&tick(5, 250.0, 0.0), 5, None);
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
        let pre = agg.on_tick(&equity_tick(ts(2026, 7, 15, 12, 0), 99.0), 0, None);
        assert!(d1(&pre.store).is_empty());
        assert!(pre.store.iter().any(|b| b.interval == Interval::M1));

        // RTH prints open and update the daily bar.
        let open = agg.on_tick(&equity_tick(ts(2026, 7, 15, 13, 30), 100.0), 1, None);
        assert_eq!(d1(&open.store).len(), 1);
        assert_eq!(d1(&open.store)[0].open, 100.0);
        let rth = agg.on_tick(&equity_tick(ts(2026, 7, 15, 19, 59), 104.0), 2, None);
        assert_eq!(d1(&rth.store)[0].close, 104.0);

        // After-hours drift in the same UTC day: the daily bar must not move.
        let ah = agg.on_tick(&equity_tick(ts(2026, 7, 15, 21, 0), 90.0), 3, None);
        assert!(d1(&ah.store).is_empty());

        // First print past UTC midnight (20:30 ET, still after-hours)
        // completes yesterday's bar with the last RTH close — never the
        // after-hours print — and opens nothing new.
        let roll = agg.on_tick(&equity_tick(ts(2026, 7, 16, 0, 30), 91.0), 4, None);
        let completed = d1(&roll.publish);
        assert_eq!(completed.len(), 1);
        assert!(completed[0].complete);
        assert_eq!(completed[0].close, 104.0);
        assert_eq!(completed[0].ts_open_ms, ts(2026, 7, 15, 0, 0));
        assert!(d1(&roll.store).iter().all(|b| b.complete));

        // The next session's first RTH print opens a fresh daily bar.
        let next = agg.on_tick(&equity_tick(ts(2026, 7, 16, 13, 30), 102.0), 5, None);
        let formed = d1(&next.store);
        assert_eq!(formed.len(), 1);
        assert_eq!(formed[0].ts_open_ms, ts(2026, 7, 16, 0, 0));
        assert_eq!(formed[0].open, 102.0);
    }

    #[test]
    fn crypto_daily_bars_form_around_the_clock() {
        let mut agg = Aggregator::new();
        // 21:00 UTC is after-hours for equities; crypto trades 24/7.
        let out = agg.on_tick(&tick(ts(2026, 7, 15, 21, 0), 50_000.0, 1.0), 0, None);
        assert!(out.store.iter().any(|b| b.interval == Interval::D1));
    }

    /// A bar as a REST backfill / exchange candle writes it: `trade_count == 0`.
    #[allow(clippy::too_many_arguments)]
    fn venue(
        symbol: &str,
        interval: Interval,
        ts_open_ms: i64,
        o: f64,
        h: f64,
        l: f64,
        c: f64,
        volume: f64,
        complete: bool,
    ) -> Bar {
        Bar {
            symbol: symbol.into(),
            interval,
            ts_open_ms,
            open: o,
            high: h,
            low: l,
            close: c,
            volume,
            trade_count: 0,
            vwap: c,
            complete,
        }
    }

    /// Live equity hourlies must land on the SAME grid the Yahoo backfill uses
    /// (`equity::parse_yahoo_chart` keeps Yahoo's true opens): 09:30-anchored
    /// through regular hours, ET-hour aligned outside them. UTC-hour flooring
    /// interleaved two grids 30 minutes out of phase in one store series and
    /// filed the 09:30–10:00 opening prints under an "extended hours" 09:00 bar.
    #[test]
    fn equity_hourly_bars_land_on_the_session_grid() {
        // 2026-07-15 is EDT (UTC-4): 09:30 ET = 13:30 UTC.
        let rth_open = ts(2026, 7, 15, 13, 30);
        assert_eq!(
            bar_bucket("AAPL", Interval::H1, ts(2026, 7, 15, 13, 45)),
            rth_open
        );
        assert_eq!(
            bar_bucket("AAPL", Interval::H1, ts(2026, 7, 15, 14, 29)),
            rth_open
        );
        assert_eq!(
            bar_bucket("AAPL", Interval::H1, ts(2026, 7, 15, 14, 30)),
            ts(2026, 7, 15, 14, 30)
        );
        // The last regular hourly is the half hour to the 16:00 close.
        assert_eq!(
            bar_bucket("AAPL", Interval::H1, ts(2026, 7, 15, 19, 45)),
            ts(2026, 7, 15, 19, 30)
        );
        // Extended hours sit on the ET hour, which is the UTC hour too.
        assert_eq!(
            bar_bucket("AAPL", Interval::H1, ts(2026, 7, 15, 13, 15)),
            ts(2026, 7, 15, 13, 0)
        );
        assert_eq!(
            bar_bucket("AAPL", Interval::H1, ts(2026, 7, 15, 20, 10)),
            ts(2026, 7, 15, 20, 0)
        );
        // EST (UTC-5): 09:30 ET = 14:30 UTC.
        assert_eq!(
            bar_bucket("AAPL", Interval::H1, ts(2026, 1, 15, 15, 0)),
            ts(2026, 1, 15, 14, 30)
        );
        // Sub-hour grids already contain 09:30; crypto never shifts at all.
        assert_eq!(
            bar_bucket("AAPL", Interval::M15, ts(2026, 7, 15, 13, 44)),
            ts(2026, 7, 15, 13, 30)
        );
        assert_eq!(
            bar_bucket("AAPL", Interval::M5, ts(2026, 7, 15, 13, 34)),
            ts(2026, 7, 15, 13, 30)
        );
        assert_eq!(
            bar_bucket("BTC-USD", Interval::H1, ts(2026, 7, 15, 13, 45)),
            ts(2026, 7, 15, 13, 0)
        );

        // End to end: a 09:45 ET print forms the 09:30 hourly, and the next
        // hour rolls over cleanly (the grid is monotonic in ts).
        let mut agg = Aggregator::new();
        let h1 = |bars: &[Bar]| -> Vec<Bar> {
            bars.iter()
                .filter(|b| b.interval == Interval::H1)
                .cloned()
                .collect()
        };
        let out = agg.on_tick(&equity_tick(ts(2026, 7, 15, 13, 45), 100.0), 0, None);
        assert_eq!(h1(&out.store).len(), 1);
        assert_eq!(h1(&out.store)[0].ts_open_ms, rth_open);
        let next = agg.on_tick(&equity_tick(ts(2026, 7, 15, 14, 35), 101.0), 1, None);
        let done = h1(&next.publish);
        assert_eq!(done.len(), 1);
        assert!(done[0].complete);
        assert_eq!(done[0].ts_open_ms, rth_open);
    }

    /// The first live tick of a bucket must not replace the venue's own partial
    /// bar for it (`BarStore::push` overwrites a same-timestamp tail), which
    /// collapsed the newest candle to a doji at the current price with a stub
    /// volume bar and made today's daily open "the price when cortexd started".
    #[test]
    fn opening_a_bucket_folds_in_the_venue_partial_bar() {
        let store = BarStore::new();
        store.push(venue(
            "BTC-USD",
            Interval::M1,
            60_000,
            100.0,
            110.0,
            95.0,
            105.0,
            40.0,
            false,
        ));
        let mut agg = Aggregator::new();
        let out = agg.on_tick(&tick(60_500, 106.0, 2.0), 60_500, Some(&store));
        let bar = m1(&out.store)[0];
        assert_eq!(bar.open, 100.0, "the venue's real bucket open must survive");
        assert_eq!(bar.high, 110.0);
        assert_eq!(bar.low, 95.0);
        assert_eq!(bar.close, 106.0, "close is still the freshest print");
        assert_eq!(bar.volume, 40.0, "venue volume is the baseline, not a stub");
        assert!(!bar.complete);
        assert!(bar.vwap.is_finite() && bar.vwap > 0.0);

        // Later ticks extend the seeded bar instead of resetting it.
        let out2 = agg.on_tick(&tick(60_900, 120.0, 1.0), 60_900, Some(&store));
        let bar2 = m1(&out2.store)[0];
        assert_eq!(bar2.open, 100.0);
        assert_eq!(bar2.high, 120.0);
        assert!((bar2.volume - 41.0).abs() < 1e-12);
    }

    /// The crypto REST backfill runs CONCURRENTLY with the websocket connect,
    /// so its candle can land in a bucket live aggregation already opened. Fold
    /// it in once rather than overwriting it on the next push.
    #[test]
    fn venue_bar_landing_after_the_bucket_opened_is_folded_in_once() {
        let store = BarStore::new();
        let mut agg = Aggregator::new();
        let first = agg.on_tick(&tick(60_100, 106.0, 2.0), 60_100, Some(&store));
        for bar in first.store {
            store.push(bar);
        }
        // Backfill lands now, replacing our forming tail in the store.
        store.push(venue(
            "BTC-USD",
            Interval::M1,
            60_000,
            100.0,
            110.0,
            95.0,
            105.0,
            40.0,
            false,
        ));
        let out = agg.on_tick(&tick(60_500, 107.0, 1.0), 60_500, Some(&store));
        let bar = m1(&out.store)[0].clone();
        assert_eq!(bar.open, 100.0);
        assert_eq!(bar.high, 110.0);
        assert_eq!(bar.low, 95.0);
        assert_eq!(bar.close, 107.0);
        assert_eq!(bar.volume, 40.0);
        store.push(bar);

        // Absorbed exactly once: the third tick adds its own size on top.
        let out3 = agg.on_tick(&tick(60_700, 108.0, 3.0), 60_700, Some(&store));
        assert!((m1(&out3.store)[0].volume - 43.0).abs() < 1e-12);
    }

    /// The CBOE feed is ~15 minutes delayed, so it walks through buckets the
    /// Yahoo backfill already delivered COMPLETE. Those are authoritative: a
    /// delayed tick must not re-open one as a one-tick doji, but it must still
    /// roll up whatever bucket was forming before it.
    #[test]
    fn a_closed_venue_bucket_is_not_reformed_by_a_delayed_tick() {
        let store = BarStore::new();
        store.push(venue(
            "AAPL",
            Interval::M5,
            ts(2026, 7, 15, 13, 45),
            100.0,
            104.0,
            99.0,
            103.0,
            5_000.0,
            true,
        ));
        let m5 = |bars: &[Bar]| -> Vec<Bar> {
            bars.iter()
                .filter(|b| b.interval == Interval::M5)
                .cloned()
                .collect()
        };
        let mut agg = Aggregator::new();
        // 09:42 ET print seen at 09:57 wall clock: its 09:40 bucket has no
        // venue row, so it forms normally.
        let a = agg.on_tick(
            &equity_tick(ts(2026, 7, 15, 13, 42), 100.5),
            ts(2026, 7, 15, 13, 57),
            Some(&store),
        );
        assert_eq!(m5(&a.store).len(), 1);
        assert_eq!(m5(&a.store)[0].ts_open_ms, ts(2026, 7, 15, 13, 40));

        // 09:47 print seen at 10:02: the 09:45 bucket is the venue's finished
        // bar. Leave it alone, but complete the 09:40 bar we were forming.
        let b = agg.on_tick(
            &equity_tick(ts(2026, 7, 15, 13, 47), 101.0),
            ts(2026, 7, 15, 14, 2),
            Some(&store),
        );
        assert!(
            m5(&b.store).iter().all(|x| x.complete),
            "no forming 5m bar may be written into a bucket the venue closed"
        );
        let rolled = m5(&b.publish);
        assert_eq!(rolled.len(), 1);
        assert!(rolled[0].complete);
        assert_eq!(rolled[0].ts_open_ms, ts(2026, 7, 15, 13, 40));
        // Intervals whose bucket has NOT ended keep forming as usual.
        assert!(b.store.iter().any(|x| x.interval == Interval::H1));
        assert!(b.store.iter().any(|x| x.interval == Interval::D1));

        // And the series resumes on the next bucket the venue never sent.
        let c = agg.on_tick(
            &equity_tick(ts(2026, 7, 15, 13, 52), 102.0),
            ts(2026, 7, 15, 14, 7),
            Some(&store),
        );
        assert_eq!(m5(&c.store).len(), 1);
        assert_eq!(m5(&c.store)[0].ts_open_ms, ts(2026, 7, 15, 13, 50));
        assert!(!m5(&c.store)[0].complete);
    }
}
