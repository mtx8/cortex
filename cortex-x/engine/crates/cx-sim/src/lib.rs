//! cx-sim — Foundry's backtest engine. Replays the platform's strategy RULES
//! over real stored history (crypto M1, equities D1) with fees and slippage,
//! measures what actually worked, and projects forward by Monte Carlo from
//! the measured trade statistics. Pure and synchronous: statistics, not
//! promises — small samples are labeled, never hidden.

use cx_core::events::{SimProjection, SimReport, SimTrade, StrategyStats};
use cx_core::types::Side;
use cx_core::store::BarStore;
use cx_core::time::now_ms;
use cx_core::types::{asset_class_of, AssetClass, Interval};
use cx_ta::quant;

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
/// with >= [`OOS_MIN_TRADES`] OOS trades; if no row qualifies, fall back to
/// full-sample expectancy among rows with >= 10 trades (the old behavior).
fn pick_best(stats: &[StrategyStats], oos: &[OosStat]) -> Option<String> {
    let qualified = oos.iter().filter(|o| o.trades >= OOS_MIN_TRADES);
    if let Some(winner) = qualified.max_by(|a, b| a.expectancy.total_cmp(&b.expectancy)) {
        return Some(winner.key.clone());
    }
    stats
        .iter()
        .filter(|s| s.trades >= 10)
        .max_by(|a, b| {
            a.expectancy
                .unwrap_or(f64::MIN)
                .total_cmp(&b.expectancy.unwrap_or(f64::MIN))
        })
        .map(|s| format!("{}/{}", s.strategy, s.symbol))
}

/// Run the full sweep: every strategy x every symbol with enough history.
pub fn run(store: &BarStore, symbols: &[String]) -> SimReport {
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
            let recs = backtest(strat, symbol, &bars);
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

/// Replay one strategy's rules; returns the full per-trade audit log (net of
/// cost). Signals evaluate on bar N's features and fill at bar N+1's open —
/// every timestamp and price below exists in stored market history.
pub(crate) fn backtest(
    strategy: &str,
    symbol: &str,
    bars: &[cx_core::events::Bar],
) -> Vec<SimTrade> {
    let mut trades: Vec<SimTrade> = Vec::new();
    let mut pos: i8 = 0; // -1 short, 0 flat, 1 long
    let mut entry_px = 0.0_f64;
    let mut entry_ts = 0_i64;

    let mut close_at = |pos: i8, entry_px: f64, entry_ts: i64, px: f64, ts: i64,
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
        let (want, exit_now) = decide(strategy, &feats, window, pos);

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
/// Returns (desired position, exit-now flag).
fn decide(
    strategy: &str,
    feats: &std::collections::BTreeMap<String, f64>,
    window: &[cx_core::events::Bar],
    pos: i8,
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
            let want = if z <= -2.0 {
                1
            } else if z >= 2.0 {
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
            let close = window.last().map(|b| b.close).unwrap_or(f64::NAN);
            let mid = g("bb_mid");
            if !(hi.is_finite() && lo.is_finite() && close.is_finite()) {
                return (0, pos != 0);
            }
            let want = if close > hi {
                1
            } else if close < lo {
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
            // Same pure rule as cx-strategy's kalman_trend: enter when
            // |t-stat| >= 2 with no CUSUM change-point in the last 10 bars,
            // direction = sign(slope); exit on a t-stat sign flip against
            // the held side or a fresh change-point (<= 2 bars ago). The
            // estimators are computed locally (below) on the close window.
            let closes: Vec<f64> = window.iter().map(|b| b.close).collect();
            let Some((slope, tstat, brk)) = kalman_cusum(&closes) else {
                return (0, pos != 0);
            };
            let want = if tstat.abs() >= 2.0 && brk > 10.0 {
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

/// Local Kalman(level+trend) + two-sided CUSUM over a close window, for the
/// kalman_trend backtest replication. cx-ta grows equivalent quant2
/// estimators in a parallel change; this tiny pure re-implementation keeps
/// cx-sim compile-independent of that work while replicating the same RULE.
///
/// Filter: g-h (steady-state Kalman) with level gain G=0.3, slope gain
/// H=0.05; innovation variance tracked by EWMA (lambda=0.94). The slope
/// t-stat is slope / (sigma_innov / sqrt(2/H)) — the g-h slope effectively
/// averages ~2/H bars, so that is its standard error under noise.
/// CUSUM: two-sided on vol-normalized returns (EWMA vol, lambda=0.94) with
/// drift allowance k=0.5 and threshold h=5; returns bars since last break,
/// capped at 250 (a never-broken window reads as long-quiet).
///
/// Returns (slope, tstat, bars_since_break); None below 30 bars. NaN-safe:
/// non-finite closes are skipped, outputs are finite or None.
fn kalman_cusum(closes: &[f64]) -> Option<(f64, f64, f64)> {
    const G: f64 = 0.3;
    const H: f64 = 0.05;
    const LAMBDA: f64 = 0.94;
    const CUSUM_K: f64 = 0.5;
    const CUSUM_H: f64 = 5.0;
    const BREAK_CAP: f64 = 250.0;
    if closes.len() < 30 || !closes[0].is_finite() {
        return None;
    }
    let mut level = closes[0];
    let mut slope = 0.0_f64;
    let mut innov_var = f64::NAN;
    let mut ret_var = f64::NAN;
    let mut cusum_pos = 0.0_f64;
    let mut cusum_neg = 0.0_f64;
    let mut since_break = BREAK_CAP;
    let mut prev = closes[0];
    for &x in &closes[1..] {
        if !x.is_finite() {
            continue;
        }
        let pred = level + slope;
        let innov = x - pred;
        level = pred + G * innov;
        slope += H * innov;
        innov_var = if innov_var.is_finite() {
            LAMBDA * innov_var + (1.0 - LAMBDA) * innov * innov
        } else {
            innov * innov
        };
        if prev > 0.0 {
            let r = x / prev - 1.0;
            if r.is_finite() {
                // Score against the PRIOR vol so a genuine shock reads at
                // full size before the EWMA absorbs it.
                if ret_var.is_finite() {
                    let vol = ret_var.sqrt();
                    if vol > 0.0 {
                        let z = r / vol;
                        cusum_pos = (cusum_pos + z - CUSUM_K).max(0.0);
                        cusum_neg = (cusum_neg - z - CUSUM_K).max(0.0);
                        since_break = (since_break + 1.0).min(BREAK_CAP);
                        if cusum_pos > CUSUM_H || cusum_neg > CUSUM_H {
                            cusum_pos = 0.0;
                            cusum_neg = 0.0;
                            since_break = 0.0;
                        }
                    }
                }
                ret_var = if ret_var.is_finite() {
                    LAMBDA * ret_var + (1.0 - LAMBDA) * r * r
                } else {
                    r * r
                };
            }
        }
        prev = x;
    }
    if !(slope.is_finite() && innov_var.is_finite()) {
        return None;
    }
    let sigma = innov_var.sqrt();
    let tstat = if sigma > 0.0 {
        slope * (2.0 / H).sqrt() / sigma
    } else {
        0.0 // zero measured noise: no significance claim without a scale
    };
    tstat.is_finite().then_some((slope, tstat, since_break))
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
    fn kalman_cusum_reads_a_noisy_ramp_as_significant_and_quiet() {
        // Persistent drift under deterministic pseudo-noise: strong positive
        // slope, |t| >= 2, and a long-quiet CUSUM (drift < 0.5 sigma/bar).
        let closes: Vec<f64> = (0..200)
            .map(|i| 100.0 + 0.08 * i as f64 + 0.3 * ((i as f64) * 0.9).sin())
            .collect();
        let (slope, tstat, brk) = kalman_cusum(&closes).expect("warm");
        assert!(slope > 0.0, "slope must be positive: {slope}");
        assert!(tstat >= 2.0, "trend must be significant: t = {tstat}");
        assert!(brk > 10.0, "steady drift must not fire CUSUM: brk = {brk}");
    }

    #[test]
    fn kalman_cusum_fires_on_an_injected_shift() {
        // Calm range, then a hard level break: bars-since-break must read
        // fresh at the end of the window.
        let mut closes: Vec<f64> = (0..150)
            .map(|i| 100.0 + 0.3 * ((i as f64) * 0.9).sin())
            .collect();
        for i in 0..5 {
            closes.push(97.0 - 0.4 * i as f64); // -3% gap, then a slide
        }
        let (_, _, brk) = kalman_cusum(&closes).expect("warm");
        assert!(brk <= 5.0, "shift must register as a fresh break: {brk}");
    }

    #[test]
    fn kalman_cusum_is_nan_safe_and_needs_warmup() {
        assert!(kalman_cusum(&[100.0; 10]).is_none(), "short window");
        // Non-finite closes are skipped, output stays finite.
        let mut closes: Vec<f64> = (0..100)
            .map(|i| 100.0 + 0.05 * i as f64 + 0.2 * ((i as f64) * 1.3).sin())
            .collect();
        closes[40] = f64::NAN;
        let (slope, tstat, brk) = kalman_cusum(&closes).expect("warm");
        assert!(slope.is_finite() && tstat.is_finite() && brk.is_finite());
    }

    #[test]
    fn kalman_trend_profits_on_a_noisy_persistent_trend() {
        // Chop, then a persistent drift smaller than the bar noise (so the
        // CUSUM stays quiet) — the kalman rule must ride it net positive.
        let closes: Vec<f64> = (0..350)
            .map(|i| {
                let base = if i < 100 {
                    100.0
                } else {
                    100.0 + 0.08 * (i - 100) as f64
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
}
