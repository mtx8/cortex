//! SCANNER: cross-sectional relative-value screen over the scan universe.
//! Every metric is a percentile rank (0-100) against the other symbols on
//! the SAME cycle — relative strength, not absolute magic numbers — blended
//! into one composite. Event flags mark discrete setups. Raw readings ride
//! along so the operator can always see what drove a score.
//!
//! Raw readings (per symbol, complete D1 bars only, NaN-firewalled):
//! - momentum: mean of vol-adjusted returns over 5/21/63-bar windows, each
//!   `total_return / (realized daily vol * sqrt(days))`; windows without
//!   enough bars or with zero vol (constant price) are skipped.
//! - trend: `kalman_tstat` from [`cx_ta::compute_features`]; falls back to
//!   the EMA9/21/50 alignment score `(e9-e21)/e21 + (e21-e50)/e50`.
//! - breakout: `0.7 * -(drawdown from the trailing <=252-bar high) +
//!   0.3 * (close/Donchian(20) upper - 1)` — closer to the highs = higher.
//! - meanrev: |zscore_20| only when RSI(14) < 40 (oversold side) — this is
//!   a LONG bounce-setup score; stretched-overbought names deliberately
//!   read 0.0 so they rank at the bottom of the dimension, not the top.
//! - vol_state: mid-rank percentile of the latest 20d realized vol within
//!   the symbol's OWN trailing 252-value rolling-vol history (expansion vs
//!   its norm), already 0-100 before the cross-sectional rank.
//!
//! Ranking policy: per dimension, symbols WITH a finite raw reading are
//! mid-ranked `rank / (n-1) * 100` (ties get the average rank); a single
//! reading scores 50; symbols missing the reading get the median 50 so a
//! data gap never fabricates strength or weakness.

use std::sync::Arc;

use cx_core::config::Config;
use cx_core::events::{Bar, EngineEvent, RegimeState, ScanBoard, ScanRow};
use cx_core::store::BarStore;
use cx_core::time::now_ms;
use cx_core::types::Interval;
use cx_core::Bus;

use crate::regimes;

/// Composite weights (documented honesty: a heuristic blend, not alpha).
pub const W_TREND: f64 = 0.30;
pub const W_MOMENTUM: f64 = 0.30;
pub const W_BREAKOUT: f64 = 0.15;
pub const W_VOL_STATE: f64 = 0.15;
pub const W_MEANREV: f64 = 0.10;

/// D1 bars requested from the store per symbol.
const HISTORY: usize = 600;
/// Minimum complete D1 bars to scan a symbol at all.
const MIN_BARS: usize = 60;
/// Trailing window for the "252d"/52-week high and the vol-state history.
const LOOKBACK: usize = 252;
/// Momentum windows: ~1w / ~1m / ~3m of D1 bars.
const MOM_WINDOWS: [usize; 3] = [5, 21, 63];
/// Rolling realized-vol window (bars of daily returns).
const RV_WINDOW: usize = 20;
/// Volume-surge baseline: average volume over this many prior bars.
const VOL_AVG_WINDOW: usize = 20;
/// Donchian channel period for the breakout-proximity blend.
const DONCHIAN_WINDOW: usize = 20;
/// Weight of the Donchian proximity inside breakout_raw.
const DONCHIAN_BLEND: f64 = 0.30;
/// A golden cross counts as "recent" within this many bars.
const GOLDEN_CROSS_BARS: usize = 10;
/// RSI below this reads as the oversold side for the meanrev setup.
const MEANREV_RSI: f64 = 40.0;
/// "volume spike" flag threshold on vol_surge.
const VOLUME_SPIKE_X: f64 = 2.5;
/// "breakout setup": within this fraction of the 252d high...
const BREAKOUT_NEAR_HIGH: f64 = 0.02;
/// ...with at least this much volume vs the 20d average.
const BREAKOUT_VOL_X: f64 = 1.3;
/// "oversold bounce": RSI below this AND the last return positive.
const OVERSOLD_RSI: f64 = 32.0;
/// "vol expansion": own-history vol percentile at or above this.
const VOL_EXPANSION_PCT: f64 = 90.0;

/// Spawn the periodic scanner (cadence `intel.scanner_secs`). Reuses the
/// D1 history the REGIMES scanner maintains in the shared store.
pub fn spawn_scanner(bus: Arc<Bus>, store: Arc<BarStore>, cfg: Config) {
    tokio::spawn(async move {
        let cadence = std::time::Duration::from_secs(cfg.intel.scanner_secs.max(60));
        let symbols = regimes::universe(&cfg);
        loop {
            let board = scan(&store, &symbols);
            if !board.rows.is_empty() {
                bus.publish(EngineEvent::Scan(board));
            }
            tokio::time::sleep(cadence).await;
        }
    });
}

/// One scan cycle: per-symbol raw readings -> cross-sectional percentile
/// ranks -> composite + flags. Pure over the store.
pub fn scan(store: &BarStore, symbols: &[String]) -> ScanBoard {
    let reads: Vec<Reading> = symbols
        .iter()
        .filter_map(|s| read_symbol(store, s))
        .collect();

    let collect = |f: &dyn Fn(&Reading) -> Option<f64>| -> Vec<Option<f64>> {
        reads.iter().map(f).collect()
    };
    let momentum = pct_ranks(&collect(&|r| r.momentum_raw));
    let trend = pct_ranks(&collect(&|r| r.trend_raw));
    let breakout = pct_ranks(&collect(&|r| r.breakout_raw));
    let meanrev = pct_ranks(&collect(&|r| r.meanrev_raw));
    let vol_state = pct_ranks(&collect(&|r| r.vol_state_raw));

    let mut rows: Vec<ScanRow> = reads
        .into_iter()
        .enumerate()
        .map(|(i, r)| {
            let composite = W_TREND * trend[i]
                + W_MOMENTUM * momentum[i]
                + W_BREAKOUT * breakout[i]
                + W_VOL_STATE * vol_state[i]
                + W_MEANREV * meanrev[i];
            ScanRow {
                asset_class: if r.symbol.contains('-') {
                    "crypto".into()
                } else {
                    "equity".into()
                },
                symbol: r.symbol,
                composite,
                momentum: momentum[i],
                trend: trend[i],
                breakout: breakout[i],
                meanrev: meanrev[i],
                vol_state: vol_state[i],
                rsi_14: r.rsi_14,
                zscore_20: r.zscore_20,
                kalman_tstat: r.kalman_tstat,
                ret_1w: r.ret_1w,
                ret_1m: r.ret_1m,
                ret_3m: r.ret_3m,
                dist_52w_high: r.dist_52w_high,
                vol_surge: r.vol_surge,
                regime: r.regime,
                flags: r.flags,
                last_close: r.last_close,
            }
        })
        .collect();
    rows.sort_by(|a, b| {
        b.composite
            .total_cmp(&a.composite)
            .then_with(|| a.symbol.cmp(&b.symbol))
    });

    ScanBoard {
        rows,
        source: "cortex scan (D1 + live bars, delayed equities)".into(),
        ts_ms: now_ms(),
    }
}

/// Per-symbol raw readings before cross-sectional ranking.
struct Reading {
    symbol: String,
    momentum_raw: Option<f64>,
    trend_raw: Option<f64>,
    breakout_raw: Option<f64>,
    meanrev_raw: Option<f64>,
    vol_state_raw: Option<f64>,
    rsi_14: Option<f64>,
    zscore_20: Option<f64>,
    kalman_tstat: Option<f64>,
    ret_1w: Option<f64>,
    ret_1m: Option<f64>,
    ret_3m: Option<f64>,
    dist_52w_high: Option<f64>,
    vol_surge: Option<f64>,
    regime: Option<RegimeState>,
    flags: Vec<String>,
    last_close: f64,
}

/// Pull D1 history and compute every raw reading for one symbol. None when
/// the symbol has fewer than [`MIN_BARS`] complete, finite-close bars.
fn read_symbol(store: &BarStore, symbol: &str) -> Option<Reading> {
    let bars = store.recent(symbol, Interval::D1, HISTORY);
    // Complete sessions with a sane close only. NaN volumes/highs may still
    // ride along in `clean`; every consumer below guards its own inputs.
    let clean: Vec<Bar> = bars
        .iter()
        .filter(|b| b.complete && b.close.is_finite() && b.close > 0.0)
        .cloned()
        .collect();
    let n = clean.len();
    if n < MIN_BARS {
        return None;
    }
    let closes: Vec<f64> = clean.iter().map(|b| b.close).collect();
    let last = closes[n - 1];
    let rets: Vec<f64> = closes.windows(2).map(|w| w[1] / w[0] - 1.0).collect();
    let feats = cx_ta::compute_features(&clean);

    // momentum: mean of vol-adjusted window returns (see module doc).
    let mut mom_scores: Vec<f64> = Vec::new();
    for w in MOM_WINDOWS {
        if n < w + 1 {
            continue; // window without enough bars: skipped
        }
        let total = last / closes[n - 1 - w] - 1.0;
        let vol = stdev(&rets[rets.len() - w..]);
        if vol > 1e-12 {
            mom_scores.push(total / (vol * (w as f64).sqrt()));
        }
    }
    let momentum_raw = (!mom_scores.is_empty())
        .then(|| mom_scores.iter().sum::<f64>() / mom_scores.len() as f64);

    // trend: kalman t-stat, else EMA9/21/50 alignment.
    let trend_raw = feats
        .get("kalman_tstat")
        .copied()
        .or_else(|| ema_alignment(&feats));

    // breakout: -(drawdown from the trailing <=252 high) blended with the
    // Donchian(20) upper proximity. The drawdown window shrinks to the
    // available history below 252 bars (relative measure, documented);
    // the WIRE field dist_52w_high stays honest and only reports with the
    // full 252-bar window.
    let look = n.min(LOOKBACK);
    let hi = closes[n - look..]
        .iter()
        .copied()
        .fold(f64::NEG_INFINITY, f64::max);
    let dd = ((hi - last) / hi).max(0.0);
    let don_hi = clean[n - DONCHIAN_WINDOW..]
        .iter()
        .map(|b| {
            if b.high.is_finite() && b.high >= b.close {
                b.high
            } else {
                b.close // NaN/garbage high: the close is the honest bound
            }
        })
        .fold(f64::NEG_INFINITY, f64::max);
    let breakout_raw =
        Some((1.0 - DONCHIAN_BLEND) * (-dd) + DONCHIAN_BLEND * (last / don_hi - 1.0));
    let dist_52w_high = (n >= LOOKBACK).then_some(dd);

    // meanrev: long bounce setup — oversold-side stretch only (module doc).
    let rsi_14 = feats.get("rsi_14").copied();
    let zscore_20 = feats.get("zscore_20").copied();
    let meanrev_raw = match (rsi_14, zscore_20) {
        (Some(r), Some(z)) => Some(if r < MEANREV_RSI { z.abs() } else { 0.0 }),
        _ => None,
    };

    // vol_state: latest 20d realized vol percentile within own history.
    let mut rv: Vec<f64> = Vec::new();
    if rets.len() >= RV_WINDOW {
        for j in RV_WINDOW..=rets.len() {
            rv.push(stdev(&rets[j - RV_WINDOW..j]));
        }
    }
    let hist = &rv[rv.len().saturating_sub(LOOKBACK)..];
    let vol_state_raw = (hist.len() >= 2).then(|| pct_rank_within(hist, hist[hist.len() - 1]));

    // vol_surge: last complete bar volume vs the 20 prior bars' average.
    // None when the last volume is not finite, there are not enough prior
    // bars, or the (finite-only) average is zero.
    let last_vol = clean[n - 1].volume;
    let vol_surge = if n >= VOL_AVG_WINDOW + 1 && last_vol.is_finite() && last_vol >= 0.0 {
        let prior: Vec<f64> = clean[n - 1 - VOL_AVG_WINDOW..n - 1]
            .iter()
            .map(|b| b.volume)
            .filter(|v| v.is_finite() && *v >= 0.0)
            .collect();
        if prior.is_empty() {
            None
        } else {
            let avg = prior.iter().sum::<f64>() / prior.len() as f64;
            (avg > 0.0).then(|| last_vol / avg)
        }
    } else {
        None
    };

    let ret = |w: usize| (n > w).then(|| last / closes[n - 1 - w] - 1.0);

    // Event flags — exact strings from the events.rs contract.
    let mut flags: Vec<String> = Vec::new();
    if n >= LOOKBACK + 1 {
        let prior_hi = closes[n - 1 - LOOKBACK..n - 1]
            .iter()
            .copied()
            .fold(f64::NEG_INFINITY, f64::max);
        if last >= prior_hi {
            flags.push("new 52w high".into());
        }
    }
    if golden_cross_recent(&closes) {
        flags.push("golden cross".into());
    }
    if vol_surge.is_some_and(|v| v >= VOLUME_SPIKE_X) {
        flags.push("volume spike".into());
    }
    if dist_52w_high.is_some_and(|d| d <= BREAKOUT_NEAR_HIGH)
        && vol_surge.is_some_and(|v| v >= BREAKOUT_VOL_X)
    {
        flags.push("breakout setup".into());
    }
    if rsi_14.is_some_and(|r| r < OVERSOLD_RSI) && rets.last().is_some_and(|r| *r > 0.0) {
        flags.push("oversold bounce".into());
    }
    if vol_state_raw.is_some_and(|p| p >= VOL_EXPANSION_PCT) {
        flags.push("vol expansion".into());
    }

    Some(Reading {
        symbol: symbol.to_string(),
        momentum_raw,
        trend_raw,
        breakout_raw,
        meanrev_raw,
        vol_state_raw,
        rsi_14,
        zscore_20,
        kalman_tstat: feats.get("kalman_tstat").copied(),
        ret_1w: ret(5),
        ret_1m: ret(21),
        ret_3m: ret(63),
        dist_52w_high,
        vol_surge,
        regime: regimes::classify(symbol, &bars, None).map(|r| r.state),
        flags,
        last_close: last,
    })
}

/// EMA9/21/50 alignment fallback for trend: stacked-and-rising EMAs score
/// positive, inverted stacks negative.
fn ema_alignment(feats: &std::collections::BTreeMap<String, f64>) -> Option<f64> {
    let e9 = *feats.get("ema_9")?;
    let e21 = *feats.get("ema_21")?;
    let e50 = *feats.get("ema_50")?;
    (e21 > 0.0 && e50 > 0.0).then(|| (e9 - e21) / e21 + (e21 - e50) / e50)
}

/// SMA50 crossed above SMA200 within the last [`GOLDEN_CROSS_BARS`] bars.
fn golden_cross_recent(closes: &[f64]) -> bool {
    let n = closes.len();
    if n < 201 {
        return false;
    }
    let mut ps = vec![0.0f64; n + 1];
    for (i, c) in closes.iter().enumerate() {
        ps[i + 1] = ps[i] + c;
    }
    let sma = |i: usize, w: usize| (ps[i + 1] - ps[i + 1 - w]) / w as f64;
    let start = n.saturating_sub(GOLDEN_CROSS_BARS).max(200);
    for j in start..n {
        let (a0, b0) = (sma(j - 1, 50), sma(j - 1, 200));
        let (a1, b1) = (sma(j, 50), sma(j, 200));
        if a0 <= b0 && a1 > b1 {
            return true;
        }
    }
    false
}

/// Population standard deviation; 0.0 below two samples.
fn stdev(xs: &[f64]) -> f64 {
    let n = xs.len() as f64;
    if n < 2.0 {
        return 0.0;
    }
    let mean = xs.iter().sum::<f64>() / n;
    (xs.iter().map(|x| (x - mean) * (x - mean)).sum::<f64>() / n).sqrt()
}

/// Mid-rank percentile of `latest` within its own history (0-100). All-equal
/// histories read 50 — a constant-vol series is at its norm, not expanding.
fn pct_rank_within(hist: &[f64], latest: f64) -> f64 {
    let m = hist.len();
    debug_assert!(m >= 2);
    let less = hist.iter().filter(|v| **v < latest).count() as f64;
    let equal = hist.iter().filter(|v| **v == latest).count() as f64;
    (less + (equal - 1.0) / 2.0) / (m as f64 - 1.0) * 100.0
}

/// Cross-sectional percentile ranks (0-100) with the module-doc policy:
/// mid-rank over the finite readings, `rank / (n-1) * 100`; a single
/// reading — and every missing reading — gets the median 50.
fn pct_ranks(raws: &[Option<f64>]) -> Vec<f64> {
    let vals: Vec<(usize, f64)> = raws
        .iter()
        .enumerate()
        .filter_map(|(i, r)| match r {
            Some(v) if v.is_finite() => Some((i, *v)),
            _ => None,
        })
        .collect();
    let mut out = vec![50.0; raws.len()];
    let m = vals.len();
    if m <= 1 {
        return out;
    }
    for &(i, v) in &vals {
        let less = vals.iter().filter(|(_, o)| *o < v).count() as f64;
        let equal = vals.iter().filter(|(_, o)| *o == v).count() as f64;
        out[i] = (less + (equal - 1.0) / 2.0) / (m as f64 - 1.0) * 100.0;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const DAY_MS: i64 = 86_400_000;

    fn mk_bar(symbol: &str, i: i64, close: f64, volume: f64) -> Bar {
        Bar {
            symbol: symbol.into(),
            interval: Interval::D1,
            ts_open_ms: i * DAY_MS,
            open: close,
            high: close,
            low: close,
            close,
            volume,
            trade_count: 0,
            vwap: close,
            complete: true,
        }
    }

    fn push_series_vols(store: &BarStore, symbol: &str, closes: &[f64], vols: &[f64]) {
        for (i, (&c, &v)) in closes.iter().zip(vols.iter()).enumerate() {
            store.push(mk_bar(symbol, i as i64, c, v));
        }
    }

    fn push_series(store: &BarStore, symbol: &str, closes: &[f64]) {
        push_series_vols(store, symbol, closes, &vec![1000.0; closes.len()]);
    }

    fn ramp(from: f64, to: f64, n: usize) -> Vec<f64> {
        (0..n)
            .map(|i| from + (to - from) * i as f64 / (n.max(2) - 1) as f64)
            .collect()
    }

    /// Exponential growth with a fixed ±1% alternating wobble: every symbol
    /// built from this shares the same vol scale, so vol-adjusted momentum
    /// orders by the growth rate.
    fn wobble(g: f64, n: usize) -> Vec<f64> {
        (0..n)
            .map(|i| {
                let w = if i % 2 == 0 { 1.01 } else { 0.99 };
                100.0 * g.powi(i as i32) * w
            })
            .collect()
    }

    fn syms(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    fn row<'a>(board: &'a ScanBoard, symbol: &str) -> &'a ScanRow {
        board
            .rows
            .iter()
            .find(|r| r.symbol == symbol)
            .unwrap_or_else(|| panic!("row {symbol} missing"))
    }

    fn four_symbol_store() -> BarStore {
        let store = BarStore::new();
        push_series(&store, "STRONG", &wobble(1.02, 300));
        push_series(&store, "MILD", &wobble(1.005, 300));
        push_series(&store, "WEAK", &wobble(0.99, 300));
        push_series(&store, "FLAT", &vec![100.0; 300]);
        store
    }

    #[test]
    fn percentile_ranking_orders_momentum_and_medians_the_missing() {
        let store = four_symbol_store();
        let board = scan(&store, &syms(&["STRONG", "MILD", "WEAK", "FLAT"]));
        assert_eq!(board.rows.len(), 4);
        // Three finite momentum readings, known order -> exact 100/50/0.
        assert_eq!(row(&board, "STRONG").momentum, 100.0);
        assert_eq!(row(&board, "MILD").momentum, 50.0);
        assert_eq!(row(&board, "WEAK").momentum, 0.0);
        // FLAT's constant closes have zero-vol windows -> no momentum raw
        // -> documented median 50, never a fabricated extreme.
        assert_eq!(row(&board, "FLAT").momentum, 50.0);
    }

    #[test]
    fn single_symbol_scores_all_50() {
        let store = BarStore::new();
        push_series(&store, "ONLY", &wobble(1.01, 300));
        let board = scan(&store, &syms(&["ONLY"]));
        assert_eq!(board.rows.len(), 1);
        let r = &board.rows[0];
        for score in [r.momentum, r.trend, r.breakout, r.meanrev, r.vol_state] {
            assert_eq!(score, 50.0);
        }
        assert!((r.composite - 50.0).abs() < 1e-9);
    }

    #[test]
    fn composite_is_the_documented_weighted_blend() {
        assert!(
            (W_TREND + W_MOMENTUM + W_BREAKOUT + W_VOL_STATE + W_MEANREV - 1.0).abs() < 1e-12
        );
        let store = four_symbol_store();
        let board = scan(&store, &syms(&["STRONG", "MILD", "WEAK", "FLAT"]));
        for r in &board.rows {
            let expect = W_TREND * r.trend
                + W_MOMENTUM * r.momentum
                + W_BREAKOUT * r.breakout
                + W_VOL_STATE * r.vol_state
                + W_MEANREV * r.meanrev;
            assert!(
                (r.composite - expect).abs() < 1e-9,
                "{}: composite {} != blend {}",
                r.symbol,
                r.composite,
                expect
            );
        }
    }

    #[test]
    fn rows_sorted_by_composite_desc() {
        let store = four_symbol_store();
        let board = scan(&store, &syms(&["WEAK", "FLAT", "STRONG", "MILD"]));
        assert_eq!(board.rows.len(), 4);
        for pair in board.rows.windows(2) {
            assert!(
                pair[0].composite >= pair[1].composite,
                "{} ({}) sorted above {} ({})",
                pair[1].symbol,
                pair[1].composite,
                pair[0].symbol,
                pair[0].composite
            );
        }
    }

    #[test]
    fn insufficient_history_skipped_and_short_history_stays_honest() {
        let store = BarStore::new();
        push_series(&store, "GOOD", &wobble(1.005, 300));
        push_series(&store, "THIN", &ramp(100.0, 120.0, 59)); // < 60 -> skipped
        push_series(&store, "SHORT", &wobble(1.005, 60)); // scanned, sparse
        let board = scan(&store, &syms(&["GOOD", "THIN", "SHORT"]));
        assert_eq!(board.rows.len(), 2);
        assert!(board.rows.iter().all(|r| r.symbol != "THIN"));

        let short = row(&board, "SHORT");
        assert!(short.regime.is_none(), "no regime under 210 bars");
        assert!(short.dist_52w_high.is_none(), "no 52w distance under 252 bars");
        assert!(short.ret_3m.is_none(), "no 3m return with 60 bars");
        assert!(short.ret_1m.is_some());
        assert!(short.ret_1w.is_some());
        assert!(short.vol_surge.is_some());

        let good = row(&board, "GOOD");
        assert_eq!(good.regime, Some(RegimeState::Bull));
        assert!(good.dist_52w_high.is_some());
        assert!(good.rsi_14.is_some());
        assert!(good.zscore_20.is_some());
        assert!(good.kalman_tstat.is_some());
    }

    #[test]
    fn crypto_equity_classification_and_source() {
        let store = BarStore::new();
        push_series(&store, "BTC-USD", &wobble(1.01, 300));
        push_series(&store, "AAPL", &wobble(1.005, 300));
        let board = scan(&store, &syms(&["BTC-USD", "AAPL"]));
        assert_eq!(row(&board, "BTC-USD").asset_class, "crypto");
        assert_eq!(row(&board, "AAPL").asset_class, "equity");
        assert_eq!(board.source, "cortex scan (D1 + live bars, delayed equities)");
    }

    #[test]
    fn flag_new_52w_high_fires_and_stays_silent() {
        let store = BarStore::new();
        push_series(&store, "HI", &ramp(100.0, 200.0, 300));
        let mut below = ramp(100.0, 200.0, 300);
        below.push(190.0); // ends under the prior 252d high
        push_series(&store, "LO", &below);
        let board = scan(&store, &syms(&["HI", "LO"]));
        // The steady ramp trips exactly the one flag: constant volume kills
        // the volume flags, RSI is high, and its realized vol is contracting.
        assert_eq!(row(&board, "HI").flags, vec!["new 52w high".to_string()]);
        assert!(!row(&board, "LO").flags.iter().any(|f| f == "new 52w high"));
    }

    #[test]
    fn flag_golden_cross_fires_and_stays_silent() {
        let store = BarStore::new();
        // 260 flat sessions then an 8-bar rally: SMA50 pulls above SMA200
        // inside the last 10 bars.
        let mut closes = vec![100.0; 260];
        closes.extend((1..=8).map(|k| 100.0 + k as f64));
        push_series(&store, "CROSS", &closes);
        push_series(&store, "TREND", &ramp(100.0, 200.0, 300)); // long above, no recent cross
        let board = scan(&store, &syms(&["CROSS", "TREND"]));
        assert!(row(&board, "CROSS").flags.iter().any(|f| f == "golden cross"));
        assert!(!row(&board, "TREND").flags.iter().any(|f| f == "golden cross"));
    }

    #[test]
    fn flag_volume_spike_fires_and_stays_silent() {
        let store = BarStore::new();
        let closes = wobble(1.001, 300);
        let mut vols = vec![1000.0; 300];
        vols[299] = 3000.0;
        push_series_vols(&store, "SPIKE", &closes, &vols);
        push_series(&store, "CALM", &closes);
        let board = scan(&store, &syms(&["SPIKE", "CALM"]));
        let spike = row(&board, "SPIKE");
        assert!(spike.flags.iter().any(|f| f == "volume spike"));
        assert!((spike.vol_surge.unwrap() - 3.0).abs() < 1e-9);
        let calm = row(&board, "CALM");
        assert!(!calm.flags.iter().any(|f| f == "volume spike"));
        assert!((calm.vol_surge.unwrap() - 1.0).abs() < 1e-9);
    }

    #[test]
    fn flag_breakout_setup_fires_and_stays_silent() {
        // 1.5% under the 252d high on 1.5x volume: setup, but neither a new
        // high nor a 2.5x volume spike.
        let mut closes = ramp(100.0, 200.0, 290);
        closes.extend(std::iter::repeat(197.0).take(10));
        let mut vols = vec![1000.0; 300];
        vols[299] = 1500.0;
        let store = BarStore::new();
        push_series_vols(&store, "SETUP", &closes, &vols);
        push_series(&store, "NOVOL", &closes); // same tape, no volume push
        let board = scan(&store, &syms(&["SETUP", "NOVOL"]));
        let setup = row(&board, "SETUP");
        assert!(setup.flags.iter().any(|f| f == "breakout setup"));
        assert!(!setup.flags.iter().any(|f| f == "new 52w high"));
        assert!(!setup.flags.iter().any(|f| f == "volume spike"));
        assert!((setup.dist_52w_high.unwrap() - 0.015).abs() < 1e-9);
        assert!(!row(&board, "NOVOL").flags.iter().any(|f| f == "breakout setup"));
    }

    #[test]
    fn flag_oversold_bounce_fires_and_stays_silent() {
        let store = BarStore::new();
        let mut closes = ramp(200.0, 100.0, 299);
        closes.push(101.0); // uptick off the low, RSI still crushed
        push_series(&store, "BOUNCE", &closes);
        push_series(&store, "FALLING", &ramp(200.0, 100.0, 300)); // no up close
        let board = scan(&store, &syms(&["BOUNCE", "FALLING"]));
        let bounce = row(&board, "BOUNCE");
        assert!(bounce.flags.iter().any(|f| f == "oversold bounce"));
        assert!(bounce.rsi_14.unwrap() < OVERSOLD_RSI);
        assert!(!row(&board, "FALLING").flags.iter().any(|f| f == "oversold bounce"));
    }

    #[test]
    fn flag_vol_expansion_fires_and_stays_silent() {
        let store = BarStore::new();
        // 280 quiet sessions, then 20 violent ones: the latest 20d realized
        // vol tops the symbol's own history.
        let mut closes: Vec<f64> = (0..280)
            .map(|i| if i % 2 == 0 { 100.0 } else { 100.05 })
            .collect();
        let mut px = 100.0;
        for k in 0..20 {
            px *= if k % 2 == 0 { 1.05 } else { 0.95 };
            closes.push(px);
        }
        push_series(&store, "EXPAND", &closes);
        // Constant-magnitude chop: rolling vol history is all-equal, which
        // must read as percentile 50, never as expansion.
        let steady: Vec<f64> = (0..300)
            .map(|i| if i % 2 == 0 { 100.0 } else { 100.05 })
            .collect();
        push_series(&store, "STEADY", &steady);
        let board = scan(&store, &syms(&["EXPAND", "STEADY"]));
        assert!(row(&board, "EXPAND").flags.iter().any(|f| f == "vol expansion"));
        assert!(!row(&board, "STEADY").flags.iter().any(|f| f == "vol expansion"));
    }

    #[test]
    fn nan_bars_and_forming_bars_never_propagate() {
        let store = BarStore::new();
        let closes = wobble(1.005, 300);
        push_series(&store, "DIRTY", &closes);
        // Complete bar with a NaN close: dropped by the clean filter.
        store.push(Bar {
            close: f64::NAN,
            open: f64::NAN,
            high: f64::NAN,
            low: f64::NAN,
            vwap: f64::NAN,
            ..mk_bar("DIRTY", 300, 100.0, 1000.0)
        });
        // Complete bar with a finite close but NaN volume: kept for price
        // math, volume ignored (vol_surge must go None, not NaN).
        let last_clean = closes[299] * 1.001;
        store.push(mk_bar("DIRTY", 301, last_clean, f64::NAN));
        // Forming (incomplete) crash bar: filtered entirely.
        store.push(Bar {
            complete: false,
            ..mk_bar("DIRTY", 302, 1.0, 1000.0)
        });

        let board = scan(&store, &syms(&["DIRTY"]));
        assert_eq!(board.rows.len(), 1);
        let r = &board.rows[0];
        assert_eq!(r.last_close, last_clean, "forming/NaN bars must not be the close");
        assert!(r.composite.is_finite());
        for score in [r.momentum, r.trend, r.breakout, r.meanrev, r.vol_state] {
            assert!(score.is_finite());
        }
        assert!(r.vol_surge.is_none(), "NaN last volume must yield None");
        for opt in [
            r.rsi_14,
            r.zscore_20,
            r.kalman_tstat,
            r.ret_1w,
            r.ret_1m,
            r.ret_3m,
            r.dist_52w_high,
        ] {
            if let Some(v) = opt {
                assert!(v.is_finite(), "Option field carried a non-finite value");
            }
        }
    }

    #[test]
    fn empty_universe_and_unknown_symbols_yield_empty_board() {
        let store = BarStore::new();
        let board = scan(&store, &syms(&["GHOST"]));
        assert!(board.rows.is_empty());
        assert_eq!(board.source, "cortex scan (D1 + live bars, delayed equities)");
        let board = scan(&store, &[]);
        assert!(board.rows.is_empty());
    }
}
