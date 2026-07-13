//! cx-sim — Foundry's backtest engine. Replays the platform's strategy RULES
//! over real stored history (crypto M1, equities D1) with fees and slippage,
//! measures what actually worked, and projects forward by Monte Carlo from
//! the measured trade statistics. Pure and synchronous: statistics, not
//! promises — small samples are labeled, never hidden.

use std::collections::BTreeMap;

use cx_core::events::{SimProjection, SimReport, SimTrade, StrategyStats};
use cx_core::types::Side;
use cx_core::store::BarStore;
use cx_core::time::now_ms;
use cx_core::types::{asset_class_of, AssetClass, Interval};
use cx_ta::quant;

/// Strategy-keyed tunable overrides, the same shape as
/// `cx_core::config::Config::strategy_params` and the AUTORESEARCH grid:
/// strategy name -> { key -> value } (e.g. "meanrev_z" -> { "z_entry": 1.75 }).
pub type ParamMap = BTreeMap<String, BTreeMap<String, f64>>;

/// Round-trip cost applied to every trade (fees + slippage), as a fraction.
const COST_PER_TRADE: f64 = 0.001;
/// Fraction of equity allocated per trade for the equity-multiple readout.
const ALLOC: f64 = 0.10;
const WARMUP: usize = 60;
const STRATEGIES: [&str; 4] = ["momentum_x", "meanrev_z", "breakout_d", "kalman_trend"];
/// Walk-forward split: the first 70% of bars are "train", trades whose ENTRY
/// falls in the last 30% are the out-of-sample (OOS) set.
const OOS_SPLIT: f64 = 0.7;
/// OOS expectancy drives `best` only with at least this many OOS trades.
const OOS_MIN_TRADES: u32 = 10;

/// The tunable rule parameters, with the SAME hard bounds and defaults as
/// the live strategy runtime (cx-strategy strat.rs `PARAM_BOUNDS` — bus-only
/// crates cannot import each other; keep the tables in sync). Experiments
/// replay the SAME rules under variant values; missing/unknown/non-finite
/// keys fall back to the defaults, everything else is clamped.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RuleParams {
    /// meanrev_z entry threshold on |zscore_20|; hard bounds [1.5, 3.0].
    pub meanrev_z_entry: f64,
    /// kalman_trend entry threshold on |kalman_tstat|; hard bounds [1.5, 3.5].
    pub kalman_t_entry: f64,
    /// breakout_d range confirmation (bar range >= this * ATR14); hard
    /// bounds [0.5, 1.5].
    pub breakout_min_range_atr: f64,
}

impl Default for RuleParams {
    fn default() -> Self {
        Self {
            meanrev_z_entry: 2.0,
            kalman_t_entry: 2.0,
            breakout_min_range_atr: 0.8,
        }
    }
}

impl RuleParams {
    /// Resolve a params map: known keys clamped to the hard bounds, unknown
    /// keys ignored, missing or non-finite values default.
    pub fn from_map(params: &ParamMap) -> Self {
        let get = |strategy: &str, key: &str| {
            params
                .get(strategy)
                .and_then(|m| m.get(key))
                .copied()
                .filter(|v| v.is_finite())
        };
        let mut rp = Self::default();
        if let Some(v) = get("meanrev_z", "z_entry") {
            rp.meanrev_z_entry = v.clamp(1.5, 3.0);
        }
        if let Some(v) = get("kalman_trend", "t_entry") {
            rp.kalman_t_entry = v.clamp(1.5, 3.5);
        }
        if let Some(v) = get("breakout_d", "min_range_atr") {
            rp.breakout_min_range_atr = v.clamp(0.5, 1.5);
        }
        rp
    }
}

pub fn empty_report(note: &str) -> SimReport {
    SimReport {
        stats: vec![],
        trades: vec![],
        projections: vec![],
        best: None,
        note: note.into(),
        ts_ms: now_ms(),
    }
}

/// Per-(strategy, symbol) out-of-sample sample: trades whose entry fell in
/// the last 30% of bars.
///
/// NOTE (wire constraint): `cx_core::events::StrategyStats` has no OOS field
/// yet and cx-core is frozen for this change, so OOS expectancy cannot ride
/// on the stats rows. It is encoded in the report `note` (summarily) and
/// drives `best` selection below; the proper wire field can come later.
struct OosStat {
    key: String,
    trades: u32,
    expectancy: f64,
}

/// Best-pick with walk-forward honesty: rank by OOS expectancy across rows
/// with >= [`OOS_MIN_TRADES`] OOS trades AND positive expectancy — a
/// "least-bad loser" is never a recommendation. With no positive-OOS
/// candidate, fall back to full-sample expectancy among rows with >= 10
/// trades, again requiring expectancy > 0. All-negative everywhere returns
/// None: "best: none" is more honest than crowning a proven loser.
fn pick_best(stats: &[StrategyStats], oos: &[OosStat]) -> Option<String> {
    let qualified = oos
        .iter()
        .filter(|o| o.trades >= OOS_MIN_TRADES && o.expectancy > 0.0);
    if let Some(winner) = qualified.max_by(|a, b| a.expectancy.total_cmp(&b.expectancy)) {
        return Some(winner.key.clone());
    }
    stats
        .iter()
        .filter(|s| s.trades >= 10 && s.expectancy.is_some_and(|e| e > 0.0))
        .max_by(|a, b| {
            a.expectancy
                .unwrap_or(f64::MIN)
                .total_cmp(&b.expectancy.unwrap_or(f64::MIN))
        })
        .map(|s| format!("{}/{}", s.strategy, s.symbol))
}

/// Run the full sweep: every strategy x every symbol with enough history,
/// under the default rule parameters (the live strategies' defaults).
pub fn run(store: &BarStore, symbols: &[String]) -> SimReport {
    run_with_params(store, symbols, &ParamMap::new())
}

/// [`run`] under a variant recipe: the SAME rules, data, costs and
/// walk-forward split, with the tunable entry thresholds overridden (clamped
/// to the live hard bounds). An empty map reproduces `run` exactly — this is
/// the AUTORESEARCH experiment surface.
pub fn run_with_params(store: &BarStore, symbols: &[String], params: &ParamMap) -> SimReport {
    let rp = RuleParams::from_map(params);
    let mut stats: Vec<StrategyStats> = Vec::new();
    let mut all_trades: Vec<(String, Vec<f64>)> = Vec::new();
    let mut trade_log: Vec<SimTrade> = Vec::new();
    let mut oos_stats: Vec<OosStat> = Vec::new();

    for symbol in symbols {
        let interval = match asset_class_of(symbol) {
            AssetClass::Crypto => Interval::M1,
            _ => Interval::D1,
        };
        let bars = store.recent(symbol, interval, 1_200);
        let closes: Vec<f64> = bars.iter().map(|b| b.close).collect();
        if closes.len() < WARMUP + 20 {
            continue;
        }
        // Walk-forward boundary: entries at/after this timestamp are OOS.
        let split_idx = ((bars.len() as f64 * OOS_SPLIT) as usize).min(bars.len() - 1);
        let split_ts = bars[split_idx].ts_open_ms;
        for strat in STRATEGIES {
            let recs = backtest_with(strat, symbol, &bars, rp);
            let rets: Vec<f64> = recs.iter().map(|t| t.ret).collect();
            let oos: Vec<f64> = recs
                .iter()
                .filter(|t| t.entry_ts >= split_ts)
                .map(|t| t.ret)
                .collect();
            let key = format!("{strat}/{symbol}");
            if !oos.is_empty() {
                oos_stats.push(OosStat {
                    key: key.clone(),
                    trades: oos.len() as u32,
                    expectancy: oos.iter().sum::<f64>() / oos.len() as f64,
                });
            }
            stats.push(stat_row(strat, symbol, interval, bars.len() as u32, &rets));
            trade_log.extend(recs);
            if rets.len() >= 5 {
                all_trades.push((key, rets));
            }
        }
    }

    let best = pick_best(&stats, &oos_stats);

    // Projections for EVERY row with a usable sample, so any leaderboard
    // row can be inspected — not just the winner.
    let projections: Vec<SimProjection> = all_trades
        .iter()
        .flat_map(|(key, trades)| project(key, trades))
        .collect();

    // Cap the shipped audit log; newest kept per stable order.
    if trade_log.len() > 600 {
        let excess = trade_log.len() - 600;
        trade_log.drain(..excess);
    }

    // OOS summary rides in the note until StrategyStats grows a wire field
    // (cx-core is frozen for this change).
    let oos_note = if oos_stats.is_empty() {
        "no out-of-sample trades".to_string()
    } else {
        let rows: Vec<String> = oos_stats
            .iter()
            .map(|o| {
                format!(
                    "{} {:+.1}bps ({} trades{})",
                    o.key,
                    o.expectancy * 10_000.0,
                    o.trades,
                    if o.trades < OOS_MIN_TRADES { ", small sample" } else { "" }
                )
            })
            .collect();
        rows.join(", ")
    };

    SimReport {
        stats,
        trades: trade_log,
        projections,
        best,
        note: format!(
            "strategy rules replayed over stored history; {:.1}bps round-trip cost; \
             {}% of equity per trade; projections are Monte Carlo from measured \
             trade stats, not guarantees; walk-forward 70/30 OOS expectancy \
             (drives best-pick at >= {OOS_MIN_TRADES} OOS trades): {oos_note}",
            COST_PER_TRADE * 10_000.0,
            (ALLOC * 100.0) as u32
        ),
        ts_ms: now_ms(),
    }
}

/// Pooled out-of-sample summary for ONE strategy across the given symbols
/// under a variant recipe — the AUTORESEARCH ranking metric. Same data, same
/// costs, same 70/30 walk-forward split and same rules as
/// [`run_with_params`]; expectancy is the mean net return of OOS trades
/// (0.0 when there are none — the trade count says whether it means much).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OosSummary {
    pub trades: u32,
    pub expectancy: f64,
}

pub fn evaluate_strategy_params(
    store: &BarStore,
    symbols: &[String],
    strategy: &str,
    params: &ParamMap,
) -> OosSummary {
    let rp = RuleParams::from_map(params);
    let mut oos: Vec<f64> = Vec::new();
    for symbol in symbols {
        let interval = match asset_class_of(symbol) {
            AssetClass::Crypto => Interval::M1,
            _ => Interval::D1,
        };
        let bars = store.recent(symbol, interval, 1_200);
        if bars.len() < WARMUP + 20 {
            continue;
        }
        let split_idx = ((bars.len() as f64 * OOS_SPLIT) as usize).min(bars.len() - 1);
        let split_ts = bars[split_idx].ts_open_ms;
        for t in backtest_with(strategy, symbol, &bars, rp) {
            if t.entry_ts >= split_ts && t.ret.is_finite() {
                oos.push(t.ret);
            }
        }
    }
    OosSummary {
        trades: oos.len() as u32,
        expectancy: if oos.is_empty() {
            0.0
        } else {
            oos.iter().sum::<f64>() / oos.len() as f64
        },
    }
}

/// Replay one strategy's rules under the default parameters.
#[cfg(test)]
pub(crate) fn backtest(
    strategy: &str,
    symbol: &str,
    bars: &[cx_core::events::Bar],
) -> Vec<SimTrade> {
    backtest_with(strategy, symbol, bars, RuleParams::default())
}

/// Replay one strategy's rules; returns the full per-trade audit log (net of
/// cost). Signals evaluate on bar N's features and fill at bar N+1's open —
/// every timestamp and price below exists in stored market history.
pub(crate) fn backtest_with(
    strategy: &str,
    symbol: &str,
    bars: &[cx_core::events::Bar],
    rp: RuleParams,
) -> Vec<SimTrade> {
    let mut trades: Vec<SimTrade> = Vec::new();
    let mut pos: i8 = 0; // -1 short, 0 flat, 1 long
    let mut entry_px = 0.0_f64;
    let mut entry_ts = 0_i64;

    let close_at = |pos: i8, entry_px: f64, entry_ts: i64, px: f64, ts: i64,
                        trades: &mut Vec<SimTrade>| {
        let raw = (px / entry_px - 1.0) * pos as f64;
        if raw.is_finite() && entry_px > 0.0 {
            trades.push(SimTrade {
                strategy: strategy.into(),
                symbol: symbol.into(),
                side: if pos > 0 { Side::Buy } else { Side::Sell },
                entry_ts,
                exit_ts: ts,
                entry_px,
                exit_px: px,
                ret: raw - COST_PER_TRADE,
            });
        }
    };

    for i in WARMUP..bars.len().saturating_sub(1) {
        let window = &bars[..=i];
        let feats = cx_ta::compute_features(window);
        let next = &bars[i + 1];
        if !(next.open.is_finite() && next.open > 0.0) {
            continue;
        }
        let (want, exit_now) = decide(strategy, &feats, window, pos, rp);

        if pos != 0 && (exit_now || (want != 0 && want != pos)) {
            close_at(pos, entry_px, entry_ts, next.open, next.ts_open_ms, &mut trades);
            pos = 0;
        }
        if pos == 0 && want != 0 {
            pos = want;
            entry_px = next.open;
            entry_ts = next.ts_open_ms;
        }
    }
    // Mark any open position at the last close.
    if pos != 0 {
        if let Some(last) = bars.last() {
            close_at(pos, entry_px, entry_ts, last.close, last.ts_open_ms, &mut trades);
        }
    }
    trades
}

/// The strategy rules, mirroring cx-strategy's live logic in pure form.
/// Entry thresholds come from [`RuleParams`] (defaults = the live defaults,
/// variants clamped to the live hard bounds). Returns (desired position,
/// exit-now flag).
fn decide(
    strategy: &str,
    feats: &std::collections::BTreeMap<String, f64>,
    window: &[cx_core::events::Bar],
    pos: i8,
    rp: RuleParams,
) -> (i8, bool) {
    let g = |k: &str| feats.get(k).copied().unwrap_or(f64::NAN);
    match strategy {
        "momentum_x" => {
            let t = g("trend_score");
            let hist = g("macd_hist");
            if !t.is_finite() {
                return (0, pos != 0);
            }
            let want = if t > 0.4 && hist > 0.0 {
                1
            } else if t < -0.4 && hist < 0.0 {
                -1
            } else {
                0
            };
            (want, pos != 0 && t.abs() < 0.15)
        }
        "meanrev_z" => {
            let z = g("zscore_20");
            if !z.is_finite() {
                return (0, pos != 0);
            }
            let want = if z <= -rp.meanrev_z_entry {
                1
            } else if z >= rp.meanrev_z_entry {
                -1
            } else {
                0
            };
            (want, pos != 0 && z.abs() < 0.5)
        }
        "breakout_d" => {
            // Prior-window Donchian: features over bars[..len-1].
            if window.len() < 2 {
                return (0, false);
            }
            let prior = cx_ta::compute_features(&window[..window.len() - 1]);
            let hi = prior.get("donchian_hi").copied().unwrap_or(f64::NAN);
            let lo = prior.get("donchian_lo").copied().unwrap_or(f64::NAN);
            let last = &window[window.len() - 1];
            let close = last.close;
            let mid = g("bb_mid");
            if !(hi.is_finite() && lo.is_finite() && close.is_finite()) {
                return (0, pos != 0);
            }
            // Range confirmation, same as the live rule: the breakout bar's
            // range must be at least min_range_atr * ATR(14).
            let atr = g("atr_14");
            let range = last.high - last.low;
            let confirmed = atr.is_finite()
                && atr > 0.0
                && range.is_finite()
                && range >= rp.breakout_min_range_atr * atr;
            let want = if confirmed && close > hi {
                1
            } else if confirmed && close < lo {
                -1
            } else {
                0
            };
            let exit = pos != 0
                && mid.is_finite()
                && ((pos == 1 && close < mid) || (pos == -1 && close > mid));
            (want, exit)
        }
        "kalman_trend" => {
            // Same pure rule AND same estimators as cx-strategy's live
            // kalman_trend: kalman_slope / kalman_tstat / cusum_break come
            // from cx_ta::compute_features on the window — the identical
            // Kalman(level+trend) filter and mean-adjusted CUSUM the live
            // strategy consumes, so the backtest measures the rule that
            // actually trades. Enter when |t-stat| >= 2 with no CUSUM
            // change-point in the last 10 bars, direction = sign(slope);
            // exit on a t-stat sign flip against the held side or a fresh
            // change-point (cusum_break <= 2).
            let slope = g("kalman_slope");
            let tstat = g("kalman_tstat");
            let brk = g("cusum_break");
            if !(slope.is_finite() && tstat.is_finite() && brk.is_finite()) {
                return (0, pos != 0);
            }
            let want = if tstat.abs() >= rp.kalman_t_entry && brk > 10.0 {
                if slope > 0.0 {
                    1
                } else if slope < 0.0 {
                    -1
                } else {
                    0
                }
            } else {
                0
            };
            let flipped = (pos == 1 && tstat < 0.0) || (pos == -1 && tstat > 0.0);
            (want, pos != 0 && (flipped || brk <= 2.0))
        }
        _ => (0, true),
    }
}

fn stat_row(
    strategy: &str,
    symbol: &str,
    interval: Interval,
    bars: u32,
    trades: &[f64],
) -> StrategyStats {
    let equity_multiple = (!trades.is_empty()).then(|| {
        trades
            .iter()
            .fold(1.0_f64, |eq, r| eq * (1.0 + ALLOC * r))
    });
    let equity_curve: Vec<f64> = trades
        .iter()
        .scan(1.0_f64, |eq, r| {
            *eq *= 1.0 + ALLOC * r;
            Some(*eq)
        })
        .collect();
    StrategyStats {
        strategy: strategy.into(),
        symbol: symbol.into(),
        interval,
        bars,
        trades: trades.len() as u32,
        win_rate: quant::win_rate(trades),
        profit_factor: quant::profit_factor(trades),
        sharpe: quant::sharpe(trades, 252.0),
        max_drawdown: quant::max_drawdown(&equity_curve),
        expectancy: (!trades.is_empty())
            .then(|| trades.iter().sum::<f64>() / trades.len() as f64),
        equity_multiple,
    }
}

/// Monte Carlo forward paths bootstrapped from measured trades: fixed
/// fractional allocation, resampled with replacement, seeded/deterministic.
pub(crate) fn project(basis: &str, trades: &[f64]) -> Vec<SimProjection> {
    const SIMS: usize = 10_000;
    let mut out = Vec::new();
    for horizon in [100_u32, 250] {
        let mut rng = quant::Prng::new(0x5EED ^ horizon as u64);
        let mut finals: Vec<f64> = Vec::with_capacity(SIMS);
        let mut ruined = 0usize;
        for _ in 0..SIMS {
            let mut eq = 1.0_f64;
            let mut hit_ruin = false;
            for _ in 0..horizon {
                let r = trades[(rng.uniform() * trades.len() as f64) as usize % trades.len()];
                eq *= 1.0 + ALLOC * r;
                if eq <= 0.5 {
                    hit_ruin = true;
                    break;
                }
            }
            if hit_ruin {
                ruined += 1;
            }
            finals.push(eq);
        }
        finals.sort_by(|a, b| a.total_cmp(b));
        let q = |p: f64| finals[((finals.len() - 1) as f64 * p) as usize];
        out.push(SimProjection {
            basis: basis.into(),
            horizon_trades: horizon,
            p05: q(0.05),
            p50: q(0.50),
            p95: q(0.95),
            risk_of_ruin: ruined as f64 / SIMS as f64,
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use cx_core::events::Bar;

    fn mk_bars(closes: &[f64]) -> Vec<Bar> {
        closes
            .iter()
            .enumerate()
            .map(|(i, &c)| Bar {
                symbol: "T".into(),
                interval: Interval::M1,
                ts_open_ms: i as i64 * 60_000,
                open: c,
                high: c * 1.001,
                low: c * 0.999,
                close: c,
                volume: 1.0,
                trade_count: 1,
                vwap: c,
                complete: true,
            })
            .collect()
    }

    #[test]
    fn momentum_profits_on_a_clean_trend() {
        // Chop, then a strong persistent trend: momentum must end net positive.
        let mut closes: Vec<f64> = (0..80).map(|i| 100.0 + ((i % 5) as f64) * 0.05).collect();
        let mut px = *closes.last().unwrap();
        for _ in 0..200 {
            px *= 1.004;
            closes.push(px);
        }
        let trades = backtest("momentum_x", "T", &mk_bars(&closes));
        assert!(!trades.is_empty(), "no trades on a strong trend");
        assert!(trades.iter().map(|t| t.ret).sum::<f64>() > 0.0, "trend trades net negative");
        let t = &trades[0];
        assert!(t.exit_ts > t.entry_ts && t.entry_px > 0.0 && t.exit_px > 0.0);
        assert_eq!(t.side, Side::Buy);
    }

    #[test]
    fn meanrev_profits_on_oscillation() {
        // Spike-and-revert: a pure sine can never reach |z| = 2 (peak/rms of
        // a sine is sqrt(2)), so use brief 4-point dislocations off a calm
        // base that revert — the textbook fade setup.
        let closes: Vec<f64> = (0..400)
            .map(|i| {
                let mut px = 100.0 + 0.2 * ((i as f64) * 0.7).sin();
                if i % 35 < 3 {
                    px += if (i / 35) % 2 == 0 { 4.0 } else { -4.0 };
                }
                px
            })
            .collect();
        let trades = backtest("meanrev_z", "T", &mk_bars(&closes));
        assert!(trades.len() >= 3, "too few fades: {}", trades.len());
        assert!(trades.iter().map(|t| t.ret).sum::<f64>() > 0.0, "fades net negative");
    }

    #[test]
    fn stats_and_projection_are_sane() {
        let trades = vec![0.02, -0.01, 0.03, -0.005, 0.015, -0.01, 0.02, 0.01, -0.02, 0.025];
        let row = stat_row("x", "T", Interval::M1, 500, &trades);
        assert_eq!(row.trades, 10);
        assert!(row.win_rate.unwrap() > 0.5);
        assert!(row.equity_multiple.unwrap() > 1.0);
        let proj = project("x/T", &trades);
        assert_eq!(proj.len(), 2);
        for p in &proj {
            assert!(p.p05 <= p.p50 && p.p50 <= p.p95);
            assert!((0.0..=1.0).contains(&p.risk_of_ruin));
        }
        // Positive-expectancy sample: median outcome grows with horizon.
        assert!(proj[1].p50 > proj[0].p50);
    }

    #[test]
    fn kalman_rule_fires_where_the_real_estimator_is_significant_and_quiet() {
        // Build a window where the REAL estimator (cx_ta::compute_features,
        // the same one the live strategy consumes) reads a significant
        // (|t| >= 2), CUSUM-quiet (brk > 10) uptrend — the exact entry
        // preconditions — then assert the backtest actually trades it long.
        let closes: Vec<f64> = (0..300)
            .map(|i| 100.0 + 0.5 * i as f64 + 0.2 * ((i as f64) * 0.9).sin())
            .collect();
        let bars = mk_bars(&closes);
        let feats = cx_ta::compute_features(&bars);
        assert!(
            feats["kalman_tstat"] >= 2.0,
            "fixture must be significant: t = {}",
            feats["kalman_tstat"]
        );
        assert!(
            feats["cusum_break"] > 10.0,
            "fixture must be CUSUM-quiet: brk = {}",
            feats["cusum_break"]
        );
        let trades = backtest("kalman_trend", "T", &bars);
        assert!(!trades.is_empty(), "entry rule did not fire");
        assert_eq!(trades[0].side, Side::Buy);
    }

    #[test]
    fn kalman_trend_profits_on_a_strong_persistent_trend() {
        // Chop, then a strong persistent drift comfortably above the bar
        // noise: through the real estimator (mean-adjusted CUSUM treats a
        // steady drift as baseline, not a perpetual break) the kalman rule
        // must enter and ride it net positive.
        let closes: Vec<f64> = (0..350)
            .map(|i| {
                let base = if i < 100 {
                    100.0
                } else {
                    100.0 + 0.4 * (i - 100) as f64
                };
                base + 0.3 * ((i as f64) * 0.9).sin()
            })
            .collect();
        let trades = backtest("kalman_trend", "T", &mk_bars(&closes));
        assert!(!trades.is_empty(), "no trades on a persistent trend");
        assert!(
            trades.iter().map(|t| t.ret).sum::<f64>() > 0.0,
            "kalman trend trades net negative"
        );
        assert_eq!(trades[0].side, Side::Buy);
    }

    #[test]
    fn kalman_trend_stays_flat_on_stationary_noise() {
        let closes: Vec<f64> = (0..300)
            .map(|i| 100.0 + 0.3 * ((i as f64) * 0.9).sin())
            .collect();
        let trades = backtest("kalman_trend", "T", &mk_bars(&closes));
        assert!(
            trades.is_empty(),
            "no significant trend, no trades: {} trades",
            trades.len()
        );
    }

    fn full_stat(strategy: &str, trades: u32, expectancy: f64) -> StrategyStats {
        StrategyStats {
            strategy: strategy.into(),
            symbol: "T".into(),
            interval: Interval::M1,
            bars: 500,
            trades,
            win_rate: None,
            profit_factor: None,
            sharpe: None,
            max_drawdown: None,
            expectancy: Some(expectancy),
            equity_multiple: None,
        }
    }

    #[test]
    fn best_pick_prefers_oos_expectancy_when_qualified() {
        // A looks best on the full sample but collapses out-of-sample;
        // B holds up. With >= 10 OOS trades each, B must win.
        let stats = vec![full_stat("a", 40, 0.010), full_stat("b", 40, 0.002)];
        let oos = vec![
            OosStat {
                key: "a/T".into(),
                trades: 12,
                expectancy: -0.001,
            },
            OosStat {
                key: "b/T".into(),
                trades: 11,
                expectancy: 0.003,
            },
        ];
        assert_eq!(pick_best(&stats, &oos), Some("b/T".to_string()));
    }

    #[test]
    fn best_pick_falls_back_to_full_sample_without_oos_depth() {
        // OOS samples too small (< 10 trades) -> full-sample expectancy
        // decides, exactly as before the walk-forward split.
        let stats = vec![full_stat("a", 40, 0.010), full_stat("b", 40, 0.002)];
        let oos = vec![OosStat {
            key: "b/T".into(),
            trades: 3,
            expectancy: 0.5,
        }];
        assert_eq!(pick_best(&stats, &oos), Some("a/T".to_string()));
        assert_eq!(pick_best(&stats, &[]), Some("a/T".to_string()));
    }

    #[test]
    fn best_pick_skips_all_negative_oos_and_falls_through() {
        // Every OOS-qualified row is a proven loser: none may be crowned.
        // The positive full-sample row wins via the fallback instead.
        let stats = vec![full_stat("a", 40, 0.010), full_stat("b", 40, -0.002)];
        let oos = vec![
            OosStat {
                key: "a/T".into(),
                trades: 12,
                expectancy: -0.001,
            },
            OosStat {
                key: "b/T".into(),
                trades: 15,
                expectancy: -0.004,
            },
        ];
        assert_eq!(pick_best(&stats, &oos), Some("a/T".to_string()));
    }

    #[test]
    fn best_pick_returns_none_when_everything_loses() {
        // Negative OOS and negative full-sample everywhere: "best: none"
        // beats recommending the least-bad loser.
        let stats = vec![full_stat("a", 40, -0.010), full_stat("b", 40, -0.002)];
        let oos = vec![OosStat {
            key: "b/T".into(),
            trades: 15,
            expectancy: -0.004,
        }];
        assert_eq!(pick_best(&stats, &oos), None);
        assert_eq!(pick_best(&stats, &[]), None);
    }

    #[test]
    fn report_note_carries_walk_forward_oos_summary() {
        // Alternating trend blocks spread trades across both splits so
        // full-sample counts qualify and OOS rows appear in the note.
        let mut closes: Vec<f64> = (0..80).map(|i| 100.0 + ((i % 5) as f64) * 0.05).collect();
        let mut px = *closes.last().unwrap();
        for block in 0..12 {
            let step = if block % 2 == 0 { 1.004 } else { 0.996 };
            for _ in 0..60 {
                px *= step;
                closes.push(px);
            }
        }
        let store = BarStore::new();
        for bar in mk_bars(&closes) {
            store.push(Bar {
                symbol: "BTC-USD".into(),
                ..bar
            });
        }
        let report = run(&store, &["BTC-USD".into()]);
        assert!(
            report.note.contains("walk-forward 70/30"),
            "note must document the OOS split: {}",
            report.note
        );
        let counts: Vec<(String, u32)> = report
            .stats
            .iter()
            .map(|s| (format!("{}/{}", s.strategy, s.symbol), s.trades))
            .collect();
        assert!(report.best.is_some(), "no best; trade counts: {counts:?}");
    }

    #[test]
    fn empty_history_yields_empty_report() {
        let store = BarStore::new();
        let report = run(&store, &["BTC-USD".into()]);
        assert!(report.stats.is_empty());
        assert!(report.best.is_none());
    }

    /// Calm two-tick chop, then one range-confirmed upside donchian break
    /// whose bar range is ~1.2 ATR — inside the (0.8, 1.5) tunable window,
    /// so the default gate admits it and the tightest gate rejects it.
    fn chop_then_confirmed_break() -> Vec<Bar> {
        let mut bars = Vec::with_capacity(120);
        let mk = |i: usize, open: f64, high: f64, low: f64, close: f64| Bar {
            symbol: "T".into(),
            interval: Interval::M1,
            ts_open_ms: i as i64 * 60_000,
            open,
            high,
            low,
            close,
            volume: 1.0,
            trade_count: 1,
            vwap: close,
            complete: true,
        };
        for i in 0..100 {
            let c = 100.0 + if i % 2 == 0 { 0.02 } else { -0.02 };
            bars.push(mk(i, c, c + 0.05, c - 0.05, c));
        }
        // The breakout bar: close 100.10 clears the prior channel high
        // (~100.07) with range 0.12 vs ATR ~0.10 -> ~1.2 ATR confirmation.
        bars.push(mk(100, 99.98, 100.10, 99.98, 100.10));
        for i in 101..120 {
            let c = 100.10 + if i % 2 == 0 { 0.02 } else { -0.02 };
            bars.push(mk(i, c, c + 0.05, c - 0.05, c));
        }
        bars
    }

    #[test]
    fn rule_params_from_map_clamps_and_ignores_junk() {
        let mut m = ParamMap::new();
        m.entry("meanrev_z".into())
            .or_default()
            .insert("z_entry".into(), 0.1); // below the floor
        m.entry("meanrev_z".into())
            .or_default()
            .insert("junk".into(), 9.0); // unknown key
        m.entry("kalman_trend".into())
            .or_default()
            .insert("t_entry".into(), f64::NAN); // non-finite
        m.entry("breakout_d".into())
            .or_default()
            .insert("min_range_atr".into(), 99.0); // above the cap
        let rp = RuleParams::from_map(&m);
        assert_eq!(rp.meanrev_z_entry, 1.5);
        assert_eq!(rp.kalman_t_entry, 2.0, "NaN must fall back to the default");
        assert_eq!(rp.breakout_min_range_atr, 1.5);
        assert_eq!(RuleParams::from_map(&ParamMap::new()), RuleParams::default());
    }

    #[test]
    fn entry_thresholds_come_from_params() {
        let bars = mk_bars(&[100.0, 100.0]);
        let z_feats: std::collections::BTreeMap<String, f64> =
            [("zscore_20".to_string(), 1.7)].into_iter().collect();
        assert_eq!(
            decide("meanrev_z", &z_feats, &bars, 0, RuleParams::default()).0,
            0,
            "z 1.7 must not enter at the 2.0 default"
        );
        let rp = RuleParams {
            meanrev_z_entry: 1.6,
            ..RuleParams::default()
        };
        assert_eq!(
            decide("meanrev_z", &z_feats, &bars, 0, rp).0,
            -1,
            "z 1.7 must fade short once z_entry drops to 1.6"
        );

        let k_feats: std::collections::BTreeMap<String, f64> = [
            ("kalman_slope".to_string(), 0.02),
            ("kalman_tstat".to_string(), 1.8),
            ("cusum_break".to_string(), 30.0),
        ]
        .into_iter()
        .collect();
        assert_eq!(decide("kalman_trend", &k_feats, &bars, 0, RuleParams::default()).0, 0);
        let rp = RuleParams {
            kalman_t_entry: 1.5,
            ..RuleParams::default()
        };
        assert_eq!(decide("kalman_trend", &k_feats, &bars, 0, rp).0, 1);
    }

    #[test]
    fn breakout_gate_param_changes_trade_count() {
        let bars = chop_then_confirmed_break();
        let default_trades = backtest_with("breakout_d", "T", &bars, RuleParams::default());
        assert!(
            !default_trades.is_empty(),
            "a ~1.2-ATR-range break must trade at the 0.8 default gate"
        );
        let tight = RuleParams {
            breakout_min_range_atr: 1.5,
            ..RuleParams::default()
        };
        let none = backtest_with("breakout_d", "T", &bars, tight);
        assert!(
            none.is_empty(),
            "the 1.5 gate must reject the same break: {} trades",
            none.len()
        );
    }

    #[test]
    fn run_with_params_variant_changes_trade_count() {
        let store = BarStore::new();
        for bar in chop_then_confirmed_break() {
            store.push(Bar {
                symbol: "BTC-USD".into(),
                ..bar
            });
        }
        let symbols = vec!["BTC-USD".to_string()];
        let count = |r: &SimReport| {
            r.stats
                .iter()
                .find(|s| s.strategy == "breakout_d")
                .map(|s| s.trades)
                .unwrap_or(0)
        };
        // Empty overrides reproduce run() exactly (same rules, same counts).
        let base = run(&store, &symbols);
        let same = run_with_params(&store, &symbols, &ParamMap::new());
        let rows = |r: &SimReport| {
            r.stats
                .iter()
                .map(|s| (s.strategy.clone(), s.symbol.clone(), s.trades))
                .collect::<Vec<_>>()
        };
        assert_eq!(rows(&base), rows(&same));
        assert!(count(&base) > 0);
        // A variant recipe replays the SAME rules with a different gate and
        // the trade count moves.
        let mut params = ParamMap::new();
        params
            .entry("breakout_d".into())
            .or_default()
            .insert("min_range_atr".into(), 1.5);
        let variant = run_with_params(&store, &symbols, &params);
        assert_eq!(count(&variant), 0, "tight gate must remove the breakout trades");
    }

    #[test]
    fn evaluate_strategy_params_pools_oos_trades() {
        let store = BarStore::new();
        for bar in chop_then_confirmed_break() {
            store.push(Bar {
                symbol: "BTC-USD".into(),
                ..bar
            });
        }
        let symbols = vec!["BTC-USD".to_string()];
        // The breakout entry lands in the last 30% of bars, so it is OOS.
        let base = evaluate_strategy_params(&store, &symbols, "breakout_d", &ParamMap::new());
        assert!(base.trades >= 1, "expected OOS breakout trades, got {}", base.trades);
        assert!(base.expectancy.is_finite());
        let mut params = ParamMap::new();
        params
            .entry("breakout_d".into())
            .or_default()
            .insert("min_range_atr".into(), 1.5);
        let tight = evaluate_strategy_params(&store, &symbols, "breakout_d", &params);
        assert_eq!(tight.trades, 0);
        assert_eq!(tight.expectancy, 0.0);
        // No history at all: a zeroed, finite summary — never NaN.
        let empty = BarStore::new();
        let none = evaluate_strategy_params(&empty, &symbols, "breakout_d", &ParamMap::new());
        assert_eq!(none, OosSummary { trades: 0, expectancy: 0.0 });
    }
}
