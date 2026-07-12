//! REGIMES: secular bull/bear classification on daily bars + market breadth.
//! Scans configured symbols + the intel universe; publishes
//! `EngineEvent::RegimeMap` and a tighten-only breadth caution.
//!
//! Classifier inputs (all from D1 closes, NaN-firewalled):
//! - drawdown from the trailing 252-bar high, run-up from the 252-bar low
//! - SMA50 / SMA200 relation and cross recency (within 40 bars)
//! - 20-bar slope of the SMA200 ("secular trend rising")
//! - a plain 20-bar least-squares slope of closes stands in for the Kalman
//!   slope named in the spec (same sign semantics, zero dependencies)
//!
//! `days_in_state` counts DISTINCT D1 bars, not scans: the classifier walks
//! the bar series backwards re-classifying each prior endpoint until the
//! state differs, so a 30-minute scan cadence never inflates the count.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use cx_core::config::Config;
use cx_core::egress::Egress;
use cx_core::events::{Bar, Breadth, CautionUpdate, EngineEvent, RegimeBoard, RegimeRow, RegimeState};
use cx_core::store::BarStore;
use cx_core::time::{bucket_start, now_ms};
use cx_core::types::Interval;
use cx_core::Bus;

/// Minimum D1 bars to classify at all (SMA200 + a 10-bar slope shift).
const MIN_BARS: usize = 210;
/// Trailing window for the "252d" high/low.
const LOOKBACK: usize = 252;
/// A golden/death cross counts as "recent" within this many bars.
const CROSS_WINDOW: usize = 40;
/// Bars for both the SMA200 slope shift and the close-trend slope.
const SLOPE_BARS: usize = 20;
/// Yahoo D1 history request: 2 years covers LOOKBACK plus SMA warmup.
const YAHOO_RANGE: &str = "2y";
/// Spacing between Yahoo history fetches (public endpoint, per-IP limits).
const FETCH_GAP: Duration = Duration::from_millis(250);
/// Breadth caution: below this % above the 200d SMA, tighten globally.
const BREADTH_CAUTION_PCT: f64 = 30.0;
const BREADTH_CAUTION_VALUE: f64 = 0.2;
/// Minimum spacing between breadth caution emissions.
const CAUTION_GAP_MS: i64 = 6 * 3_600_000;

/// Spawn the periodic scanner task (cadence `intel.regime_scan_secs`).
/// Universe D1 history is fetched via Yahoo (already allowlisted) into the
/// shared store; classification itself is pure.
pub fn spawn_scanner(bus: Arc<Bus>, store: Arc<BarStore>, cfg: Config) {
    tokio::spawn(async move {
        let cadence = Duration::from_secs(cfg.intel.regime_scan_secs.max(300));
        let egress = Egress::new();
        let symbols = universe(&cfg);
        let mut prev: HashMap<String, RegimeRow> = HashMap::new();
        let mut last_caution_ms: i64 = 0;
        loop {
            ensure_d1_history(&egress, &store, &symbols).await;
            let board = scan_with_prev(&store, &symbols, &prev);
            if !board.rows.is_empty() {
                prev = board
                    .rows
                    .iter()
                    .map(|r| (r.symbol.clone(), r.clone()))
                    .collect();
                if let Some(pct) = board.breadth.pct_above_200d {
                    let now = now_ms();
                    if pct < BREADTH_CAUTION_PCT && now - last_caution_ms >= CAUTION_GAP_MS {
                        last_caution_ms = now;
                        bus.publish(EngineEvent::Caution(CautionUpdate {
                            scope: None,
                            value: BREADTH_CAUTION_VALUE,
                            reason: format!(
                                "breadth deterioration: {pct:.0}% above 200d"
                            ),
                            agent: "regimes".into(),
                            ts_ms: now,
                        }));
                    }
                }
                bus.publish(EngineEvent::RegimeMap(board));
            } else {
                tracing::warn!(target: "cx_intel::regimes", "no symbol had enough D1 history; board skipped");
            }
            tokio::time::sleep(cadence).await;
        }
    });
}

/// Deduped scan list: configured symbols first, then the intel universe.
pub fn universe(cfg: &Config) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for s in cfg.symbols.iter().chain(cfg.intel.universe.iter()) {
        let s = s.trim().to_uppercase();
        if !s.is_empty() && !out.contains(&s) {
            out.push(s);
        }
    }
    out
}

/// Backfill D1 history for any symbol short of `MIN_BARS`, via the Yahoo v8
/// chart endpoint (same shape cx-md's equity backfill uses; query1 host is
/// allowlisted). Failures degrade to a skipped symbol, never a crash.
async fn ensure_d1_history(egress: &Egress, store: &BarStore, symbols: &[String]) {
    for symbol in symbols {
        if store.recent(symbol, Interval::D1, MIN_BARS + 50).len() >= MIN_BARS {
            continue;
        }
        let url = format!(
            "https://query1.finance.yahoo.com/v8/finance/chart/{symbol}?range={YAHOO_RANGE}&interval=1d"
        );
        match egress.get_text(&url).await {
            Ok(raw) => {
                let bars = parse_yahoo_d1(symbol, &raw, 600);
                let n = bars.len();
                for bar in bars {
                    store.push(bar);
                }
                tracing::info!(target: "cx_intel::regimes", symbol = %symbol, bars = n, "D1 history backfilled");
            }
            Err(e) => {
                tracing::warn!(target: "cx_intel::regimes", symbol = %symbol, error = %e, "D1 backfill failed; symbol skipped this cycle");
            }
        }
        tokio::time::sleep(FETCH_GAP).await;
    }
}

/// Yahoo v8 chart JSON -> complete D1 bars (local copy of the cx-md parse
/// approach; cx-intel deliberately does not depend on cx-md). Null slots are
/// skipped; malformed payloads yield an empty vec, never a panic.
pub(crate) fn parse_yahoo_d1(symbol: &str, raw: &str, max: usize) -> Vec<Bar> {
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
            interval: Interval::D1,
            ts_open_ms: bucket_start(t * 1000, Interval::D1.ms()),
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

/// Classify every symbol with enough D1 history; compute breadth.
pub fn scan(store: &BarStore, symbols: &[String]) -> RegimeBoard {
    scan_with_prev(store, symbols, &HashMap::new())
}

/// [`scan`] with the previous board's rows for day-count/hysteresis carry.
pub fn scan_with_prev(
    store: &BarStore,
    symbols: &[String],
    prev: &HashMap<String, RegimeRow>,
) -> RegimeBoard {
    let mut rows: Vec<RegimeRow> = Vec::new();
    let (mut above_200, mut with_200, mut above_50, mut with_50) = (0u32, 0u32, 0u32, 0u32);
    for symbol in symbols {
        let bars = store.recent(symbol, Interval::D1, 600);
        let Some(row) = classify(symbol, &bars, prev.get(symbol.as_str())) else {
            continue;
        };
        let closes: Vec<f64> = bars
            .iter()
            .map(|b| b.close)
            .filter(|c| c.is_finite() && *c > 0.0)
            .collect();
        if let Some(s200) = sma_last(&closes, 200) {
            with_200 += 1;
            if row.last_close > s200 {
                above_200 += 1;
            }
        }
        if let Some(s50) = sma_last(&closes, 50) {
            with_50 += 1;
            if row.last_close > s50 {
                above_50 += 1;
            }
        }
        rows.push(row);
    }
    let pct = |above: u32, with: u32| {
        (with > 0).then(|| f64::from(above) / f64::from(with) * 100.0)
    };
    let count = |s: RegimeState| rows.iter().filter(|r| r.state == s).count() as u32;
    RegimeBoard {
        breadth: Breadth {
            pct_above_200d: pct(above_200, with_200),
            pct_above_50d: pct(above_50, with_50),
            bulls: count(RegimeState::Bull),
            // Recovery is displayed inside the BEAR column; count it there.
            bears: count(RegimeState::Bear) + count(RegimeState::Recovery),
            entering_bull: count(RegimeState::EnteringBull),
            entering_bear: count(RegimeState::EnteringBear),
            universe_size: rows.len() as u32,
        },
        rows,
        source: "cboe/yahoo D1 (delayed)".into(),
        ts_ms: now_ms(),
    }
}

fn sma_last(closes: &[f64], w: usize) -> Option<f64> {
    (closes.len() >= w).then(|| closes[closes.len() - w..].iter().sum::<f64>() / w as f64)
}

/// Pure per-symbol classifier (D1 bars, oldest -> newest). `prev` carries the
/// prior row for day-counting/hysteresis. None when history is insufficient.
pub fn classify(symbol: &str, bars_d1: &[Bar], prev: Option<&RegimeRow>) -> Option<RegimeRow> {
    let closes: Vec<f64> = bars_d1
        .iter()
        .map(|b| b.close)
        .filter(|c| c.is_finite() && *c > 0.0)
        .collect();
    let n = closes.len();
    if n < MIN_BARS {
        return None;
    }
    let ctx = Ctx::build(&closes);
    let i = n - 1;
    let facts = ctx.facts(i);
    let state = state_at(&facts)
        .or_else(|| prev.map(|p| p.state))
        .unwrap_or_else(|| fallback_state(&facts));

    // Distinct-D1-bar day count: walk endpoints backwards while the
    // stateless classification stays in the same state. prev (same state)
    // can only raise the count — protects against store truncation.
    let mut days: u32 = 1;
    let mut j = i;
    while j > MIN_BARS - 1 {
        j -= 1;
        let f = ctx.facts(j);
        let s = state_at(&f).unwrap_or_else(|| fallback_state(&f));
        if s != state {
            break;
        }
        days += 1;
    }
    if let Some(p) = prev {
        if p.state == state {
            days = days.max(p.days_in_state);
        }
    }

    Some(RegimeRow {
        symbol: symbol.to_string(),
        state,
        drawdown_pct: facts.dd,
        runup_pct: facts.ru,
        days_in_state: days,
        dist_50_200_pct: facts.rel,
        last_close: closes[i],
    })
}

/// Precomputed per-endpoint context: rolling 252-extremes and SMAs.
struct Ctx {
    close: Vec<f64>,
    hi: Vec<f64>,
    lo: Vec<f64>,
    sma50: Vec<f64>,
    sma200: Vec<f64>,
}

/// Everything the state table looks at, for one endpoint.
struct Facts {
    dd: f64,
    ru: f64,
    /// (SMA50 - SMA200) / SMA200 when both exist.
    rel: Option<f64>,
    sma200_rising: bool,
    golden_recent: bool,
    death_recent: bool,
    /// Sign of the 20-bar least-squares close slope (Kalman stand-in).
    slope20: f64,
    /// Consecutive bars (ending here) with drawdown >= 20%.
    bars_in_dd20: usize,
}

impl Ctx {
    fn build(closes: &[f64]) -> Self {
        let n = closes.len();
        let mut ps = vec![0.0f64; n + 1];
        for (i, c) in closes.iter().enumerate() {
            ps[i + 1] = ps[i] + c;
        }
        let sma = |i: usize, w: usize| -> f64 {
            if i + 1 >= w {
                (ps[i + 1] - ps[i + 1 - w]) / w as f64
            } else {
                f64::NAN
            }
        };
        let mut sma50 = vec![f64::NAN; n];
        let mut sma200 = vec![f64::NAN; n];
        for i in 0..n {
            sma50[i] = sma(i, 50);
            sma200[i] = sma(i, 200);
        }
        // Sliding-window max/min (monotonic deques), window = LOOKBACK.
        let mut hi = vec![f64::NAN; n];
        let mut lo = vec![f64::NAN; n];
        let mut dq_max: std::collections::VecDeque<usize> = std::collections::VecDeque::new();
        let mut dq_min: std::collections::VecDeque<usize> = std::collections::VecDeque::new();
        for i in 0..n {
            while dq_max.back().is_some_and(|&b| closes[b] <= closes[i]) {
                dq_max.pop_back();
            }
            dq_max.push_back(i);
            while dq_max.front().is_some_and(|&f| i >= LOOKBACK && f + LOOKBACK <= i) {
                dq_max.pop_front();
            }
            hi[i] = closes[*dq_max.front().expect("non-empty deque")];

            while dq_min.back().is_some_and(|&b| closes[b] >= closes[i]) {
                dq_min.pop_back();
            }
            dq_min.push_back(i);
            while dq_min.front().is_some_and(|&f| i >= LOOKBACK && f + LOOKBACK <= i) {
                dq_min.pop_front();
            }
            lo[i] = closes[*dq_min.front().expect("non-empty deque")];
        }
        Self {
            close: closes.to_vec(),
            hi,
            lo,
            sma50,
            sma200,
        }
    }

    fn facts(&self, i: usize) -> Facts {
        let close = self.close[i];
        let hi = self.hi[i];
        let lo = self.lo[i];
        let dd = if hi > 0.0 { ((hi - close) / hi).max(0.0) } else { 0.0 };
        let ru = if lo > 0.0 { ((close - lo) / lo).max(0.0) } else { 0.0 };
        let rel = (self.sma50[i].is_finite() && self.sma200[i].is_finite() && self.sma200[i] > 0.0)
            .then(|| (self.sma50[i] - self.sma200[i]) / self.sma200[i]);

        // SMA200 slope over up to 20 bars (shorter shift right after warmup).
        let shift = SLOPE_BARS.min(i.saturating_sub(199));
        let sma200_rising = shift >= 1
            && self.sma200[i].is_finite()
            && self.sma200[i - shift].is_finite()
            && self.sma200[i] > self.sma200[i - shift];

        let cross = |up: bool| -> bool {
            let lo_j = i.saturating_sub(CROSS_WINDOW).max(200) + 1;
            for j in lo_j..=i {
                let (a0, b0, a1, b1) = (
                    self.sma50[j - 1],
                    self.sma200[j - 1],
                    self.sma50[j],
                    self.sma200[j],
                );
                if !(a0.is_finite() && b0.is_finite() && a1.is_finite() && b1.is_finite()) {
                    continue;
                }
                let crossed = if up {
                    a0 <= b0 && a1 > b1
                } else {
                    a0 >= b0 && a1 < b1
                };
                if crossed {
                    return true;
                }
            }
            false
        };

        // Plain least-squares slope over the last 20 closes, normalized by
        // the mean close (fraction per bar). Documented Kalman stand-in.
        let w = SLOPE_BARS.min(i + 1);
        let ys = &self.close[i + 1 - w..=i];
        let mean_x = (w as f64 - 1.0) / 2.0;
        let mean_y = ys.iter().sum::<f64>() / w as f64;
        let mut num = 0.0;
        let mut den = 0.0;
        for (k, y) in ys.iter().enumerate() {
            let dx = k as f64 - mean_x;
            num += dx * (y - mean_y);
            den += dx * dx;
        }
        let slope20 = if den > 0.0 && mean_y > 0.0 {
            num / den / mean_y
        } else {
            0.0
        };

        let mut bars_in_dd20 = 0usize;
        let mut k = i;
        loop {
            let h = self.hi[k];
            if h > 0.0 && (h - self.close[k]) / h >= 0.20 {
                bars_in_dd20 += 1;
            } else {
                break;
            }
            if k == 0 {
                break;
            }
            k -= 1;
        }

        Facts {
            dd,
            ru,
            rel,
            sma200_rising,
            golden_recent: cross(true),
            death_recent: cross(false),
            slope20,
            bars_in_dd20,
        }
    }
}

/// The spec's state table. None = no primary rule matched (rare, near-high
/// chop); the caller falls back to `prev` then [`fallback_state`].
fn state_at(f: &Facts) -> Option<RegimeState> {
    if f.dd >= 0.20 {
        // Bear-range drawdown: recovery beats bear beats entering_bear.
        if f.ru >= 0.15 && f.slope20 > 0.0 {
            return Some(RegimeState::Recovery);
        }
        if f.dd >= 0.25 || f.bars_in_dd20 > CROSS_WINDOW {
            return Some(RegimeState::Bear);
        }
        return Some(RegimeState::EnteringBear);
    }
    if f.death_recent && f.dd >= 0.15 {
        return Some(RegimeState::EnteringBear);
    }
    if f.dd <= 0.10 && f.rel.is_some_and(|r| r > 0.0) && f.sma200_rising {
        return Some(RegimeState::Bull);
    }
    if f.ru >= 0.20 && f.golden_recent {
        return Some(RegimeState::EnteringBull);
    }
    if f.dd >= 0.10 {
        return Some(RegimeState::Correction);
    }
    None
}

/// Deterministic tie-break when no primary rule matches and there is no
/// prior state: near the highs with positive MA structure reads bull,
/// otherwise the structure is still repairing -> entering_bull.
fn fallback_state(f: &Facts) -> RegimeState {
    if f.rel.is_some_and(|r| r > 0.0) {
        RegimeState::Bull
    } else {
        RegimeState::EnteringBull
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mk_bars(closes: &[f64]) -> Vec<Bar> {
        closes
            .iter()
            .enumerate()
            .map(|(i, &c)| Bar {
                symbol: "TEST".into(),
                interval: Interval::D1,
                ts_open_ms: i as i64 * 86_400_000,
                open: c,
                high: c,
                low: c,
                close: c,
                volume: 1.0,
                trade_count: 0,
                vwap: c,
                complete: true,
            })
            .collect()
    }

    fn ramp(from: f64, to: f64, n: usize) -> Vec<f64> {
        (0..n)
            .map(|i| from + (to - from) * i as f64 / (n.max(2) - 1) as f64)
            .collect()
    }

    fn state_of(closes: &[f64]) -> RegimeState {
        classify("TEST", &mk_bars(closes), None).expect("classifiable").state
    }

    #[test]
    fn insufficient_history_returns_none() {
        assert!(classify("TEST", &mk_bars(&ramp(100.0, 120.0, 209)), None).is_none());
        assert!(classify("TEST", &[], None).is_none());
    }

    #[test]
    fn nan_closes_are_filtered_not_fatal() {
        let mut closes = ramp(100.0, 200.0, 300);
        closes.push(f64::NAN);
        closes.push(-5.0);
        let row = classify("TEST", &mk_bars(&closes), None).unwrap();
        assert_eq!(row.state, RegimeState::Bull);
        assert!(row.last_close.is_finite() && row.last_close > 0.0);
    }

    #[test]
    fn steady_uptrend_is_bull() {
        let row = classify("TEST", &mk_bars(&ramp(100.0, 200.0, 300)), None).unwrap();
        assert_eq!(row.state, RegimeState::Bull);
        assert!(row.drawdown_pct < 0.01, "dd {}", row.drawdown_pct);
        assert!(row.dist_50_200_pct.unwrap() > 0.0);
        assert!(row.days_in_state > 1);
    }

    #[test]
    fn twelve_pct_drawdown_is_correction() {
        let mut closes = ramp(100.0, 200.0, 280);
        closes.extend(ramp(200.0, 176.0, 15)); // -12% off the high
        let row = classify("TEST", &mk_bars(&closes), None).unwrap();
        assert_eq!(row.state, RegimeState::Correction);
        assert!((row.drawdown_pct - 0.12).abs() < 0.01);
    }

    #[test]
    fn fresh_22_pct_drawdown_is_entering_bear() {
        let mut closes = ramp(100.0, 200.0, 280);
        closes.extend(ramp(200.0, 156.0, 20)); // -22%, crossed 20% just now
        assert_eq!(state_of(&closes), RegimeState::EnteringBear);
    }

    #[test]
    fn deep_drawdown_is_bear() {
        let mut closes = ramp(100.0, 200.0, 280);
        closes.extend(ramp(200.0, 140.0, 25)); // -30%
        assert_eq!(state_of(&closes), RegimeState::Bear);
    }

    #[test]
    fn sustained_22_pct_drawdown_becomes_bear() {
        let mut closes = ramp(100.0, 200.0, 260);
        closes.extend(ramp(200.0, 156.0, 10)); // -22%
        closes.extend(std::iter::repeat(156.0).take(60)); // held > 40 bars
        assert_eq!(state_of(&closes), RegimeState::Bear);
    }

    #[test]
    fn rally_off_the_low_inside_bear_range_is_recovery() {
        let mut closes = ramp(100.0, 200.0, 260);
        closes.extend(ramp(200.0, 130.0, 20)); // -35%
        closes.extend(ramp(130.0, 158.0, 15)); // +21% off low, dd still 21%
        let row = classify("TEST", &mk_bars(&closes), None).unwrap();
        assert_eq!(row.state, RegimeState::Recovery);
        assert!(row.drawdown_pct >= 0.20);
        assert!(row.runup_pct >= 0.15);
    }

    #[test]
    fn golden_cross_after_decline_is_entering_bull() {
        // Long decline, then a rally strong enough to golden-cross recently
        // while the 252d drawdown still exceeds 10% (so not yet bull).
        let mut closes = ramp(200.0, 100.0, 260);
        closes.extend(ramp(100.0, 150.0, 70));
        let row = classify("TEST", &mk_bars(&closes), None).unwrap();
        assert_eq!(row.state, RegimeState::EnteringBull);
        assert!(row.runup_pct >= 0.20, "runup {}", row.runup_pct);
    }

    #[test]
    fn correction_at_12_pct_does_not_flap_and_days_count_bars_not_scans() {
        let mut closes = ramp(100.0, 200.0, 280);
        closes.extend(ramp(200.0, 176.0, 15));
        let bars = mk_bars(&closes);
        let first = classify("TEST", &bars, None).unwrap();
        assert_eq!(first.state, RegimeState::Correction);

        // Re-scan on the SAME bars (30-min cadence): state and day count
        // are unchanged — scans do not inflate days_in_state.
        let rescan = classify("TEST", &bars, Some(&first)).unwrap();
        assert_eq!(rescan.state, RegimeState::Correction);
        assert_eq!(rescan.days_in_state, first.days_in_state);

        // One NEW bar at the same 12% drawdown: still correction, +1 day.
        let mut more = closes.clone();
        more.push(176.0);
        let next = classify("TEST", &mk_bars(&more), Some(&rescan)).unwrap();
        assert_eq!(next.state, RegimeState::Correction);
        assert_eq!(next.days_in_state, first.days_in_state + 1);
    }

    #[test]
    fn breadth_math_over_a_mixed_store() {
        let store = BarStore::new();
        for bar in mk_bars(&ramp(100.0, 200.0, 300)) {
            store.push(Bar {
                symbol: "UP".into(),
                ..bar
            });
        }
        let mut down = ramp(100.0, 200.0, 280);
        down.extend(ramp(200.0, 140.0, 25));
        for bar in mk_bars(&down) {
            store.push(Bar {
                symbol: "DN".into(),
                ..bar
            });
        }
        // A third symbol without enough history is skipped, not counted.
        for bar in mk_bars(&ramp(50.0, 60.0, 30)) {
            store.push(Bar {
                symbol: "THIN".into(),
                ..bar
            });
        }
        let board = scan(
            &store,
            &["UP".to_string(), "DN".to_string(), "THIN".to_string()],
        );
        assert_eq!(board.rows.len(), 2);
        assert_eq!(board.breadth.universe_size, 2);
        assert_eq!(board.breadth.bulls, 1);
        assert_eq!(board.breadth.bears, 1);
        assert_eq!(board.breadth.entering_bull, 0);
        assert_eq!(board.breadth.entering_bear, 0);
        assert!((board.breadth.pct_above_200d.unwrap() - 50.0).abs() < 1e-9);
        assert!((board.breadth.pct_above_50d.unwrap() - 50.0).abs() < 1e-9);
        assert_eq!(board.source, "cboe/yahoo D1 (delayed)");
    }

    #[test]
    fn yahoo_d1_parse_skips_nulls_and_rejects_garbage() {
        let raw = r#"{"chart":{"result":[{"timestamp":[1751500800,1751587200,1751673600],
            "indicators":{"quote":[{
                "open":[100.0,null,105.0],"high":[105.0,107.0,107.5],
                "low":[99.0,103.0,104.0],"close":[104.0,106.0,106.5],
                "volume":[1000,900,1100]}]}}]}}"#;
        let bars = parse_yahoo_d1("AAPL", raw, 10);
        assert_eq!(bars.len(), 2);
        assert!(bars[0].ts_open_ms < bars[1].ts_open_ms);
        assert!(bars.iter().all(|b| b.complete && b.interval == Interval::D1));
        assert!(parse_yahoo_d1("AAPL", "junk", 10).is_empty());
        assert!(parse_yahoo_d1("AAPL", "{}", 10).is_empty());
        assert!(parse_yahoo_d1("AAPL", r#"{"chart":{"result":null}}"#, 10).is_empty());
    }
}
