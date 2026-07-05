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
const STRATEGIES: [&str; 3] = ["momentum_x", "meanrev_z", "breakout_d"];

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

/// Run the full sweep: every strategy x every symbol with enough history.
pub fn run(store: &BarStore, symbols: &[String]) -> SimReport {
    let mut stats: Vec<StrategyStats> = Vec::new();
    let mut all_trades: Vec<(String, Vec<f64>)> = Vec::new();
    let mut trade_log: Vec<SimTrade> = Vec::new();

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
        for strat in STRATEGIES {
            let recs = backtest(strat, symbol, &bars);
            let rets: Vec<f64> = recs.iter().map(|t| t.ret).collect();
            let key = format!("{strat}/{symbol}");
            stats.push(stat_row(strat, symbol, interval, bars.len() as u32, &rets));
            trade_log.extend(recs);
            if rets.len() >= 5 {
                all_trades.push((key, rets));
            }
        }
    }

    // Best = highest expectancy among samples with >= 10 trades.
    let best = stats
        .iter()
        .filter(|s| s.trades >= 10)
        .max_by(|a, b| {
            a.expectancy
                .unwrap_or(f64::MIN)
                .total_cmp(&b.expectancy.unwrap_or(f64::MIN))
        })
        .map(|s| format!("{}/{}", s.strategy, s.symbol));

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

    SimReport {
        stats,
        trades: trade_log,
        projections,
        best,
        note: format!(
            "strategy rules replayed over stored history; {:.1}bps round-trip cost; \
             {}% of equity per trade; projections are Monte Carlo from measured \
             trade stats, not guarantees",
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
    fn empty_history_yields_empty_report() {
        let store = BarStore::new();
        let report = run(&store, &["BTC-USD".into()]);
        assert!(report.stats.is_empty());
        assert!(report.best.is_none());
    }
}
