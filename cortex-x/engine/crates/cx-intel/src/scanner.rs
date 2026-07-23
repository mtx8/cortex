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
//!
//! REGIME-CONDITIONAL weights: the composite blend is regime-aware. The
//! scan task subscribes to `RegimeMap` and feeds the latest breadth
//! (`pct_above_200d`) into [`scan_with`]: below [`RISK_OFF_BREADTH_PCT`]
//! (risk-off) the blend shifts toward meanrev + vol_state; at or above
//! [`RISK_ON_BREADTH_PCT`] (risk-on) toward trend + momentum — documented
//! multipliers ([`REGIME_BOOST`]/[`REGIME_FADE`]), hard-clamped to
//! [`WEIGHT_MIN`]..[`WEIGHT_MAX`] and renormalized to sum 1 so the
//! composite always stays a 0-100 blend. The weights actually used are
//! surfaced on every board as `weights_used`.
//!
//! SELF-IMPROVING weights: the AUTORESEARCH loop (cortexd) grades weight
//! variants with [`evaluate_weight_variant`] and, on adoption, publishes
//! `ParamUpdate { strategy: "scanner" }`. The scan task applies those over
//! the SAME clamped route as every strategy tunable: unknown keys and
//! non-finite values are ignored, everything else clamps to the compiled-in
//! hard bounds here — a bus event can suggest a weight, never force an
//! out-of-bounds one.

use std::collections::BTreeMap;
use std::sync::Arc;

use cx_core::config::Config;
use cx_core::events::{Bar, EngineEvent, RegimeState, ScanAlert, ScanBoard, ScanRow};
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

/// The `ParamUpdate.strategy` tag scanner-weight adoptions ride under
/// (mirrored in cx-agents' autoresearch tunable table — bus-only crates
/// cannot import each other; keep in sync).
pub const SCANNER_STRATEGY: &str = "scanner";
/// Hard bounds every applied composite weight clamps to — compiled in HERE,
/// so no bus event can push a weight outside them. Mirrors cx-agents'
/// `SCANNER_WEIGHT_MIN/MAX`; the clamp on application makes even a drifted
/// mirror harmless.
pub const WEIGHT_MIN: f64 = 0.05;
pub const WEIGHT_MAX: f64 = 0.50;
/// Breadth (% of the equity universe above its 200d SMA) below this reads
/// risk-off: the blend shifts toward meanrev + vol_state ...
pub const RISK_OFF_BREADTH_PCT: f64 = 40.0;
/// ... and at/above this, risk-on: toward trend + momentum. Between the two
/// the base weights stand (neutral band, no flapping at one threshold).
pub const RISK_ON_BREADTH_PCT: f64 = 60.0;
/// Regime multipliers, documented and bounded: the favored dimensions scale
/// by [`REGIME_BOOST`], the faded ones by [`REGIME_FADE`], then the whole
/// blend is hard-clamped and renormalized.
pub const REGIME_BOOST: f64 = 1.5;
pub const REGIME_FADE: f64 = 0.75;

/// D1 bars requested from the store per symbol (pub: the AUTORESEARCH
/// runner freezes exactly this window per symbol before grading variants).
pub const HISTORY: usize = 600;
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
/// Alert bound per board: rows are composite-sorted, so when a violent
/// cycle trips more transitions than this the strongest names keep theirs.
const MAX_ALERTS: usize = 48;
/// Weight-variant evaluator: forward-return horizon per evaluation point...
pub const EVAL_FWD_BARS: usize = 21;
/// ... number of evaluation points walked back from the window's end ...
pub const EVAL_POINTS: usize = 6;
/// ... and the D1 spacing between them.
pub const EVAL_STEP: usize = 21;
/// Total D1 span one evaluation covers (oldest eval point + its forward
/// window). The AUTORESEARCH cooldown runs on this: re-grading a weight
/// before the data has advanced past it would re-fit the same window.
pub const EVAL_SPAN_BARS: usize = EVAL_FWD_BARS + (EVAL_POINTS - 1) * EVAL_STEP;
/// Minimum symbols with readings at an eval point for a decile spread.
const EVAL_MIN_SYMBOLS: usize = 4;

/// The five composite weights as one value. NOT necessarily normalized —
/// [`Self::clamped_normalized`] is applied at every use site (scan +
/// evaluator), so the composite is always a 0-100 blend whatever raw
/// recipe rides in.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ScanWeights {
    pub trend: f64,
    pub momentum: f64,
    pub breakout: f64,
    pub meanrev: f64,
    pub vol_state: f64,
}

/// The compiled-in base recipe (the documented W_* blend).
pub const BASE_WEIGHTS: ScanWeights = ScanWeights {
    trend: W_TREND,
    momentum: W_MOMENTUM,
    breakout: W_BREAKOUT,
    meanrev: W_MEANREV,
    vol_state: W_VOL_STATE,
};

impl ScanWeights {
    /// Each weight hard-clamped to [`WEIGHT_MIN`]..[`WEIGHT_MAX`]
    /// (non-finite slots reset to the base recipe's value first), then
    /// clamp + renormalize iterate to a FIXED POINT where BOTH invariants
    /// hold at once: every weight inside the hard bounds AND the sum is 1.
    /// A single renormalization is not enough — dividing by the sum can
    /// push a weight back out of bounds (a (0.50, 0.05 x4) recipe sums to
    /// 0.7, and 0.5/0.7 would hand one factor ~71% of the composite). The
    /// fixed point always exists (5 x WEIGHT_MIN = 0.25 <= 1 <= 5 x
    /// WEIGHT_MAX = 2.5, and the sum is always positive so no division by
    /// zero), and the residual at least halves per pass: in deficit at
    /// most ONE weight can pin at WEIGHT_MAX (two would already sum past
    /// 1), in surplus at most 4 x WEIGHT_MIN of mass pins at the floor —
    /// so the bounded loop converges below f64 resolution.
    pub fn clamped_normalized(self) -> Self {
        let clamp = |v: f64, base: f64| {
            (if v.is_finite() { v } else { base }).clamp(WEIGHT_MIN, WEIGHT_MAX)
        };
        let mut w = Self {
            trend: clamp(self.trend, BASE_WEIGHTS.trend),
            momentum: clamp(self.momentum, BASE_WEIGHTS.momentum),
            breakout: clamp(self.breakout, BASE_WEIGHTS.breakout),
            meanrev: clamp(self.meanrev, BASE_WEIGHTS.meanrev),
            vol_state: clamp(self.vol_state, BASE_WEIGHTS.vol_state),
        };
        for _ in 0..64 {
            let sum = w.trend + w.momentum + w.breakout + w.meanrev + w.vol_state;
            w = Self {
                trend: w.trend / sum,
                momentum: w.momentum / sum,
                breakout: w.breakout / sum,
                meanrev: w.meanrev / sum,
                vol_state: w.vol_state / sum,
            };
            let in_bounds = [w.trend, w.momentum, w.breakout, w.meanrev, w.vol_state]
                .iter()
                .all(|v| (WEIGHT_MIN..=WEIGHT_MAX).contains(v));
            if in_bounds {
                break; // sum is 1 (just divided) AND every weight bounded
            }
            w = Self {
                trend: w.trend.clamp(WEIGHT_MIN, WEIGHT_MAX),
                momentum: w.momentum.clamp(WEIGHT_MIN, WEIGHT_MAX),
                breakout: w.breakout.clamp(WEIGHT_MIN, WEIGHT_MAX),
                meanrev: w.meanrev.clamp(WEIGHT_MIN, WEIGHT_MAX),
                vol_state: w.vol_state.clamp(WEIGHT_MIN, WEIGHT_MAX),
            };
        }
        w
    }

    /// Apply a `ParamUpdate { strategy: "scanner" }` recipe over the SAME
    /// clamped route strategy tunables take: known keys clamp to the hard
    /// bounds, unknown keys and non-finite values are ignored with a warn.
    /// The result is the new (raw) base recipe — regime adjustment and
    /// normalization happen per scan cycle on top of it.
    pub fn with_params(self, params: &BTreeMap<String, f64>) -> Self {
        let mut out = self;
        for (key, &requested) in params {
            let slot = match key.as_str() {
                "w_trend" => &mut out.trend,
                "w_momentum" => &mut out.momentum,
                "w_breakout" => &mut out.breakout,
                "w_meanrev" => &mut out.meanrev,
                "w_vol_state" => &mut out.vol_state,
                _ => {
                    tracing::warn!(key, requested, "ignoring unknown scanner weight key");
                    continue;
                }
            };
            if !requested.is_finite() {
                tracing::warn!(key, "ignoring non-finite scanner weight");
                continue;
            }
            let applied = requested.clamp(WEIGHT_MIN, WEIGHT_MAX);
            *slot = applied;
            tracing::info!(key, requested, applied, "scanner weight applied");
        }
        out
    }

    /// Shift the blend for the current market regime (see module doc), then
    /// hard-clamp + renormalize. A missing or non-finite breadth reads
    /// neutral — no data never fabricates a regime tilt.
    pub fn regime_adjusted(self, breadth_pct_above_200d: Option<f64>) -> Self {
        let mut w = self;
        match breadth_pct_above_200d.filter(|b| b.is_finite()) {
            Some(b) if b < RISK_OFF_BREADTH_PCT => {
                w.meanrev *= REGIME_BOOST;
                w.vol_state *= REGIME_BOOST;
                w.trend *= REGIME_FADE;
                w.momentum *= REGIME_FADE;
            }
            Some(b) if b >= RISK_ON_BREADTH_PCT => {
                w.trend *= REGIME_BOOST;
                w.momentum *= REGIME_BOOST;
                w.meanrev *= REGIME_FADE;
                w.vol_state *= REGIME_FADE;
            }
            _ => {} // neutral band / no breadth: base weights stand
        }
        w.clamped_normalized()
    }

    /// Wire shape for `ScanBoard::weights_used` (and the ParamUpdate key
    /// vocabulary — one naming everywhere).
    pub fn to_map(self) -> BTreeMap<String, f64> {
        BTreeMap::from([
            ("w_trend".to_string(), self.trend),
            ("w_momentum".to_string(), self.momentum),
            ("w_breakout".to_string(), self.breakout),
            ("w_meanrev".to_string(), self.meanrev),
            ("w_vol_state".to_string(), self.vol_state),
        ])
    }
}

/// Spawn the periodic scanner (cadence `intel.scanner_secs`). Reuses the
/// D1 history the REGIMES scanner maintains in the shared store. Subscribes
/// to the bus (synchronously, same rule as the ledger/desks) for:
/// - `RegimeMap`: the latest breadth drives the regime-conditional weights;
/// - `ParamUpdate { strategy: "scanner" }`: AUTORESEARCH weight adoptions,
///   applied via the clamped route (hard bounds compiled in here).
/// Keeps the last flag set per symbol (bounded by the scanned universe) so
/// each board carries the flags that TRANSITIONED on that cycle as alerts.
pub fn spawn_scanner(
    bus: Arc<Bus>,
    store: Arc<BarStore>,
    cfg: Config,
    short_interest: Arc<crate::short_interest::ShortInterestStore>,
) {
    let mut rx = bus.subscribe();
    tokio::spawn(async move {
        let cadence = std::time::Duration::from_secs(cfg.intel.scanner_secs.max(60));
        let symbols = regimes::universe(&cfg);
        // Seed from config like the strategy runtime does (same clamped
        // path), so a restart keeps an operator-pinned recipe.
        let mut weights = match cfg.strategy_params.get(SCANNER_STRATEGY) {
            Some(params) => BASE_WEIGHTS.with_params(params),
            None => BASE_WEIGHTS,
        };
        let mut breadth: Option<f64> = None;
        // None until the first published board: the first cycle has no
        // previous flag set to diff against, so it never fires alerts.
        let mut prev_flags: Option<BTreeMap<String, Vec<String>>> = None;
        let mut iv = tokio::time::interval(cadence);
        iv.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                _ = iv.tick() => {
                    let mut board = scan_with(&store, &symbols, weights, breadth);
                    if board.rows.is_empty() {
                        continue;
                    }
                    enrich_short_interest(&mut board.rows, &short_interest);
                    if let Some(prev) = &prev_flags {
                        board.alerts = alert_transitions(prev, &board.rows, board.ts_ms);
                    }
                    prev_flags = Some(flag_sets(&board.rows));
                    bus.publish(EngineEvent::Scan(board));
                }
                ev = rx.recv() => match ev {
                    Ok(ev) => match ev.as_ref() {
                        EngineEvent::RegimeMap(b) => breadth = b.breadth.pct_above_200d,
                        EngineEvent::ParamUpdate(p) if p.strategy == SCANNER_STRATEGY => {
                            weights = weights.with_params(&p.params);
                        }
                        _ => {}
                    },
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                        // Lagged = the OLDEST buffered events were DROPPED,
                        // which can include a `ParamUpdate { "scanner" }`
                        // adoption — surface it (parity with the strategy
                        // runtime). Adoptions publish the FULL five-key
                        // recipe, so the next one self-heals any loss.
                        tracing::warn!(
                            lagged = n,
                            "scanner task lagged on bus; a ParamUpdate may have been dropped"
                        );
                        continue;
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                },
            }
        }
    });
}

/// Overlay FINRA short interest (shares) onto freshly scanned rows. Purely
/// additive: a symbol absent from the snapshot keeps `short_interest: None`
/// (the UI renders "—"). Short % of float is computed in the client from this
/// plus the float — it stays "—" here until EDGAR float also reaches the scan
/// rows, at which point it lights up with no further change.
fn enrich_short_interest(
    rows: &mut [ScanRow],
    short_interest: &crate::short_interest::ShortInterestStore,
) {
    for row in rows.iter_mut() {
        if let Some(reading) = short_interest.get(&row.symbol) {
            row.short_interest = Some(reading.current);
        }
    }
}

/// One scan cycle with the base recipe and no regime context — the
/// backward-compatible entry point (and the neutral-band behavior).
pub fn scan(store: &BarStore, symbols: &[String]) -> ScanBoard {
    scan_with(store, symbols, BASE_WEIGHTS, None)
}

/// One scan cycle: per-symbol raw readings -> cross-sectional percentile
/// ranks -> composite + flags. Pure over the store. `base_weights` is the
/// (possibly adopted) raw recipe; `breadth_pct_above_200d` the latest
/// RegimeBoard breadth. The effective weights — regime-adjusted, clamped,
/// renormalized — ride on the board as `weights_used`. Alerts are the
/// CALLER's diff (spawn task owns the cross-cycle state); a pure scan
/// returns them empty.
pub fn scan_with(
    store: &BarStore,
    symbols: &[String],
    base_weights: ScanWeights,
    breadth_pct_above_200d: Option<f64>,
) -> ScanBoard {
    let w = base_weights.regime_adjusted(breadth_pct_above_200d);
    let reads: Vec<Reading> = symbols
        .iter()
        .filter_map(|s| read_symbol(store, s))
        .collect();
    let ranks = rank_dimensions(&reads);

    let mut rows: Vec<ScanRow> = reads
        .into_iter()
        .enumerate()
        .map(|(i, r)| {
            let composite = ranks.composite(i, &w);
            let (momentum, trend, breakout, meanrev, vol_state) = (
                ranks.momentum[i],
                ranks.trend[i],
                ranks.breakout[i],
                ranks.meanrev[i],
                ranks.vol_state[i],
            );
            // Sector from the curated universe (zero-network) — computed before
            // the literal moves `r.symbol`.
            let sector = crate::splc_data::curated(&r.symbol)
                .map(|c| c.sector)
                .filter(|s: &String| !s.is_empty());
            ScanRow {
                asset_class: if r.symbol.contains('-') {
                    "crypto".into()
                } else {
                    "equity".into()
                },
                symbol: r.symbol,
                composite,
                momentum,
                trend,
                breakout,
                meanrev,
                vol_state,
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
                // Sector real now; the rest warm from fundamentals / FINRA later
                // and stay None (the UI renders "—", never a fabricated number).
                sector,
                shares_outstanding: None,
                public_float_usd: None,
                short_interest: None,
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
        alerts: Vec::new(),
        weights_used: w.to_map(),
        source: "cortex scan (D1 + live bars, delayed equities)".into(),
        ts_ms: now_ms(),
    }
}

/// Per-symbol flag sets of a board's rows — the cross-cycle state the spawn
/// task carries (bounded by the scanned universe: symbols that drop out of
/// the board drop out of the map).
pub fn flag_sets(rows: &[ScanRow]) -> BTreeMap<String, Vec<String>> {
    rows.iter()
        .map(|r| (r.symbol.clone(), r.flags.clone()))
        .collect()
}

/// Flags that TRANSITIONED ON this cycle vs `prev` (fires once per
/// transition: a flag already set last cycle never re-alerts; one that
/// turned off alerts nothing). A symbol absent from `prev` — newly entering
/// the board — alerts its active flags: they did turn on for the operator.
/// Bounded to [`MAX_ALERTS`]; rows arrive composite-sorted, so the
/// strongest names keep their alerts under pressure.
pub fn alert_transitions(
    prev: &BTreeMap<String, Vec<String>>,
    rows: &[ScanRow],
    ts_ms: i64,
) -> Vec<ScanAlert> {
    let mut out = Vec::new();
    for row in rows {
        let old = prev.get(&row.symbol).map(Vec::as_slice).unwrap_or(&[]);
        for flag in &row.flags {
            if !old.contains(flag) {
                out.push(ScanAlert {
                    symbol: row.symbol.clone(),
                    flag: flag.clone(),
                    ts_ms,
                });
                if out.len() >= MAX_ALERTS {
                    return out;
                }
            }
        }
    }
    out
}

/// Grade one weight recipe on frozen history: forward top-vs-bottom-decile
/// composite return spread. At each of [`EVAL_POINTS`] evaluation points
/// (spaced [`EVAL_STEP`] D1 bars, walking back from the window's end) the
/// universe is ranked by the composite the weights produce using ONLY bars
/// up to that point, then the mean [`EVAL_FWD_BARS`]-bar forward return of
/// the top composite decile minus the bottom decile's is taken; the score
/// is the mean spread over all valid points. Pure over the store —
/// AUTORESEARCH passes a frozen snapshot so every variant grades against
/// identical bars. None when no point had [`EVAL_MIN_SYMBOLS`] readings —
/// thin data never fabricates a spread.
pub fn evaluate_weight_variant(
    store: &BarStore,
    symbols: &[String],
    weights: &ScanWeights,
) -> Option<f64> {
    let w = weights.clamped_normalized();
    // One fetch + clean per symbol; eval points slice this history so the
    // ranked window and the forward window stay index-aligned.
    let series: Vec<(String, Vec<Bar>)> = symbols
        .iter()
        .map(|s| {
            let clean: Vec<Bar> = store
                .recent(s, Interval::D1, HISTORY + EVAL_SPAN_BARS)
                .into_iter()
                .filter(|b| b.complete && b.close.is_finite() && b.close > 0.0)
                .collect();
            (s.clone(), clean)
        })
        .collect();

    let mut spreads: Vec<f64> = Vec::new();
    for k in 0..EVAL_POINTS {
        let off = EVAL_FWD_BARS + k * EVAL_STEP;
        // Readings on the truncated history + the realized forward return.
        let mut reads: Vec<Reading> = Vec::new();
        let mut fwd: Vec<f64> = Vec::new();
        for (sym, clean) in &series {
            let n = clean.len();
            if n < off + MIN_BARS {
                continue;
            }
            let Some(reading) = read_bars(sym, &clean[..n - off]) else {
                continue;
            };
            let entry = clean[n - off - 1].close;
            let exit = clean[n - off - 1 + EVAL_FWD_BARS].close;
            reads.push(reading);
            fwd.push(exit / entry - 1.0);
        }
        if reads.len() < EVAL_MIN_SYMBOLS {
            continue;
        }
        let ranks = rank_dimensions(&reads);
        let mut order: Vec<usize> = (0..reads.len()).collect();
        order.sort_by(|&a, &b| {
            ranks
                .composite(b, &w)
                .total_cmp(&ranks.composite(a, &w))
                .then_with(|| reads[a].symbol.cmp(&reads[b].symbol))
        });
        let decile = (order.len() / 10).max(1);
        let mean = |idx: &[usize]| {
            idx.iter().map(|&i| fwd[i]).sum::<f64>() / idx.len() as f64
        };
        spreads.push(mean(&order[..decile]) - mean(&order[order.len() - decile..]));
    }
    (!spreads.is_empty()).then(|| spreads.iter().sum::<f64>() / spreads.len() as f64)
}

/// The five cross-sectional percentile-rank vectors of one reading set.
struct Ranks {
    momentum: Vec<f64>,
    trend: Vec<f64>,
    breakout: Vec<f64>,
    meanrev: Vec<f64>,
    vol_state: Vec<f64>,
}

impl Ranks {
    /// The weighted composite of row `i` (weights are the EFFECTIVE —
    /// normalized — set, so this stays a 0-100 blend).
    fn composite(&self, i: usize, w: &ScanWeights) -> f64 {
        w.trend * self.trend[i]
            + w.momentum * self.momentum[i]
            + w.breakout * self.breakout[i]
            + w.vol_state * self.vol_state[i]
            + w.meanrev * self.meanrev[i]
    }
}

/// Rank every dimension cross-sectionally (the module-doc policy).
fn rank_dimensions(reads: &[Reading]) -> Ranks {
    let collect = |f: &dyn Fn(&Reading) -> Option<f64>| -> Vec<Option<f64>> {
        reads.iter().map(f).collect()
    };
    Ranks {
        momentum: pct_ranks(&collect(&|r| r.momentum_raw)),
        trend: pct_ranks(&collect(&|r| r.trend_raw)),
        breakout: pct_ranks(&collect(&|r| r.breakout_raw)),
        meanrev: pct_ranks(&collect(&|r| r.meanrev_raw)),
        vol_state: pct_ranks(&collect(&|r| r.vol_state_raw)),
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
    read_bars(symbol, &store.recent(symbol, Interval::D1, HISTORY))
}

/// [`read_symbol`]'s pure core over an explicit bar slice — the weight
/// evaluator replays truncated histories through the SAME reading path the
/// live scan uses, so a graded composite is the composite.
fn read_bars(symbol: &str, bars: &[Bar]) -> Option<Reading> {
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
        regime: regimes::classify(symbol, bars, None).map(|r| r.state),
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

    // ---- regime-conditional weights ----------------------------------------

    fn sum_of(w: ScanWeights) -> f64 {
        w.trend + w.momentum + w.breakout + w.meanrev + w.vol_state
    }

    fn assert_bounded_normalized(w: ScanWeights) {
        assert!((sum_of(w) - 1.0).abs() < 1e-12, "not renormalized: {w:?}");
        for v in [w.trend, w.momentum, w.breakout, w.meanrev, w.vol_state] {
            assert!(v.is_finite() && v > 0.0, "non-positive weight: {w:?}");
            assert!(
                (WEIGHT_MIN..=WEIGHT_MAX).contains(&v),
                "weight escaped the hard bounds: {w:?}"
            );
        }
    }

    #[test]
    fn regime_shift_moves_the_blend_and_stays_bounded_renormalized() {
        let neutral = BASE_WEIGHTS.regime_adjusted(Some(50.0));
        let risk_off = BASE_WEIGHTS.regime_adjusted(Some(30.0));
        let risk_on = BASE_WEIGHTS.regime_adjusted(Some(75.0));
        for w in [neutral, risk_off, risk_on] {
            assert_bounded_normalized(w);
        }
        // Neutral band: the documented base blend, untouched.
        assert_eq!(neutral, BASE_WEIGHTS.clamped_normalized());
        // Risk-off shifts toward meanrev + vol_state and away from
        // trend + momentum; risk-on the reverse.
        assert!(risk_off.meanrev > neutral.meanrev, "{risk_off:?}");
        assert!(risk_off.vol_state > neutral.vol_state, "{risk_off:?}");
        assert!(risk_off.trend < neutral.trend, "{risk_off:?}");
        assert!(risk_off.momentum < neutral.momentum, "{risk_off:?}");
        assert!(risk_on.trend > neutral.trend, "{risk_on:?}");
        assert!(risk_on.momentum > neutral.momentum, "{risk_on:?}");
        assert!(risk_on.meanrev < neutral.meanrev, "{risk_on:?}");
        assert!(risk_on.vol_state < neutral.vol_state, "{risk_on:?}");
        // Threshold edges: 40 is NOT risk-off (strict <); 60 IS risk-on.
        assert_eq!(
            BASE_WEIGHTS.regime_adjusted(Some(RISK_OFF_BREADTH_PCT)),
            neutral
        );
        assert_eq!(
            BASE_WEIGHTS.regime_adjusted(Some(RISK_ON_BREADTH_PCT)),
            risk_on
        );
        // No breadth / junk breadth: neutral, never a fabricated tilt.
        assert_eq!(BASE_WEIGHTS.regime_adjusted(None), neutral);
        assert_eq!(BASE_WEIGHTS.regime_adjusted(Some(f64::NAN)), neutral);
        // Even an extreme adopted recipe stays bounded + renormalized
        // through the shift (hard clamp holds under the multipliers).
        let extreme = ScanWeights {
            trend: WEIGHT_MAX,
            momentum: WEIGHT_MAX,
            breakout: WEIGHT_MIN,
            meanrev: WEIGHT_MIN,
            vol_state: WEIGHT_MIN,
        };
        assert_bounded_normalized(extreme.regime_adjusted(Some(10.0)));
        assert_bounded_normalized(extreme.regime_adjusted(Some(90.0)));
    }

    #[test]
    fn regime_shift_reorders_the_scan_composites() {
        // STRONG leads on trend/momentum; a risk-off board discounts those
        // dimensions, so its composite must come DOWN vs the neutral board.
        let store = four_symbol_store();
        let symbols = syms(&["STRONG", "MILD", "WEAK", "FLAT"]);
        let neutral = scan_with(&store, &symbols, BASE_WEIGHTS, Some(50.0));
        let risk_off = scan_with(&store, &symbols, BASE_WEIGHTS, Some(20.0));
        assert!(
            row(&risk_off, "STRONG").composite < row(&neutral, "STRONG").composite,
            "risk-off must discount the trend leader: {} vs {}",
            row(&risk_off, "STRONG").composite,
            row(&neutral, "STRONG").composite,
        );
        // The board discloses the weights actually used, renormalized.
        let used: f64 = risk_off.weights_used.values().sum();
        assert!((used - 1.0).abs() < 1e-12, "{:?}", risk_off.weights_used);
        assert!(
            risk_off.weights_used["w_meanrev"] > neutral.weights_used["w_meanrev"],
            "weights_used must reflect the risk-off shift"
        );
        for key in ["w_trend", "w_momentum", "w_breakout", "w_meanrev", "w_vol_state"] {
            assert!(neutral.weights_used.contains_key(key), "missing {key}");
        }
    }

    #[test]
    fn renormalization_cannot_push_a_weight_back_out_of_bounds() {
        // Regression: a bus-adoptable recipe of (0.50, 0.05 x4) sums to
        // 0.7 — a single renormalization would hand trend 0.5/0.7 ~ 71%
        // of the composite, escaping WEIGHT_MAX. The fixed point keeps
        // the cap and spreads the remaining mass across the floors.
        let deficit = ScanWeights {
            trend: WEIGHT_MAX,
            momentum: WEIGHT_MIN,
            breakout: WEIGHT_MIN,
            meanrev: WEIGHT_MIN,
            vol_state: WEIGHT_MIN,
        }
        .clamped_normalized();
        assert_bounded_normalized(deficit);
        assert!((deficit.trend - WEIGHT_MAX).abs() < 1e-9, "{deficit:?}");
        for v in [deficit.momentum, deficit.breakout, deficit.meanrev, deficit.vol_state] {
            assert!((v - 0.125).abs() < 1e-9, "{deficit:?}");
        }
        // Surplus side: (0.50, 0.50, 0.05 x3) sums to 1.15 — a single
        // renormalization would drop the floors to 0.05/1.15 ~ 0.043,
        // under WEIGHT_MIN. The fixed point keeps the floors and takes
        // the surplus out of the capped pair.
        let surplus = ScanWeights {
            trend: WEIGHT_MAX,
            momentum: WEIGHT_MAX,
            breakout: WEIGHT_MIN,
            meanrev: WEIGHT_MIN,
            vol_state: WEIGHT_MIN,
        }
        .clamped_normalized();
        assert_bounded_normalized(surplus);
        assert!((surplus.trend - 0.425).abs() < 1e-9, "{surplus:?}");
        assert!((surplus.momentum - 0.425).abs() < 1e-9, "{surplus:?}");
        for v in [surplus.breakout, surplus.meanrev, surplus.vol_state] {
            assert!((v - WEIGHT_MIN).abs() < 1e-9, "{surplus:?}");
        }
    }

    #[test]
    fn param_updates_apply_clamped_and_ignore_junk() {
        // The clamped bus route: known keys clamp to the compiled-in hard
        // bounds; unknown keys and non-finite values change nothing.
        let params = BTreeMap::from([
            ("w_trend".to_string(), 0.9),        // above the cap -> 0.5
            ("w_meanrev".to_string(), 0.001),    // below the floor -> 0.05
            ("w_momentum".to_string(), f64::NAN), // ignored
            ("w_mystery".to_string(), 0.4),      // unknown key ignored
        ]);
        let w = BASE_WEIGHTS.with_params(&params);
        assert_eq!(w.trend, WEIGHT_MAX);
        assert_eq!(w.meanrev, WEIGHT_MIN);
        assert_eq!(w.momentum, BASE_WEIGHTS.momentum, "NaN must not apply");
        assert_eq!(w.breakout, BASE_WEIGHTS.breakout);
        assert_eq!(w.vol_state, BASE_WEIGHTS.vol_state);
        // Whatever rode the bus, the effective scan weights renormalize.
        assert_bounded_normalized(w.regime_adjusted(None));
        // An empty update is a no-op.
        assert_eq!(BASE_WEIGHTS.with_params(&BTreeMap::new()), BASE_WEIGHTS);
    }

    // ---- alert transitions ---------------------------------------------------

    fn flagged_row(sym: &str, flags: &[&str]) -> ScanRow {
        ScanRow {
            symbol: sym.into(),
            asset_class: "equity".into(),
            composite: 50.0,
            momentum: 50.0,
            trend: 50.0,
            breakout: 50.0,
            meanrev: 50.0,
            vol_state: 50.0,
            rsi_14: None,
            zscore_20: None,
            kalman_tstat: None,
            ret_1w: None,
            ret_1m: None,
            ret_3m: None,
            dist_52w_high: None,
            vol_surge: None,
            regime: None,
            flags: flags.iter().map(|f| f.to_string()).collect(),
            last_close: 100.0,
            sector: None, shares_outstanding: None, public_float_usd: None, short_interest: None,
        }
    }

    #[test]
    fn alerts_fire_once_per_transition() {
        let cycle1 = vec![
            flagged_row("AAPL", &["volume spike"]),
            flagged_row("NVDA", &[]),
        ];
        let prev = flag_sets(&cycle1);
        // Next cycle: AAPL keeps its spike (no re-alert) and adds a
        // breakout; NVDA turns on golden cross; MSFT enters the board with
        // an active flag (alerts — it turned on for the operator).
        let cycle2 = vec![
            flagged_row("AAPL", &["volume spike", "breakout setup"]),
            flagged_row("NVDA", &["golden cross"]),
            flagged_row("MSFT", &["vol expansion"]),
        ];
        let alerts = alert_transitions(&prev, &cycle2, 42);
        let pairs: Vec<(&str, &str)> = alerts
            .iter()
            .map(|a| (a.symbol.as_str(), a.flag.as_str()))
            .collect();
        assert_eq!(
            pairs,
            vec![
                ("AAPL", "breakout setup"),
                ("NVDA", "golden cross"),
                ("MSFT", "vol expansion"),
            ]
        );
        assert!(alerts.iter().all(|a| a.ts_ms == 42));

        // Cycle 3 = identical flags: NOTHING transitions, nothing re-fires.
        let prev = flag_sets(&cycle2);
        assert!(alert_transitions(&prev, &cycle2, 43).is_empty());

        // A flag turning OFF alerts nothing either.
        let cycle3 = vec![flagged_row("AAPL", &["volume spike"])];
        assert!(alert_transitions(&prev, &cycle3, 44).is_empty());

        // ... and re-firing after off->on is a NEW transition (once each).
        let prev = flag_sets(&cycle3);
        let cycle4 = vec![flagged_row("AAPL", &["volume spike", "breakout setup"])];
        let again = alert_transitions(&prev, &cycle4, 45);
        assert_eq!(again.len(), 1);
        assert_eq!(again[0].flag, "breakout setup");
    }

    #[test]
    fn alerts_are_bounded() {
        let prev = BTreeMap::new();
        let rows: Vec<ScanRow> = (0..MAX_ALERTS + 20)
            .map(|i| flagged_row(&format!("S{i:03}"), &["vol expansion"]))
            .collect();
        let alerts = alert_transitions(&prev, &rows, 1);
        assert_eq!(alerts.len(), MAX_ALERTS);
        // Row order (composite-sorted upstream) decides who keeps alerts.
        assert_eq!(alerts[0].symbol, "S000");
    }

    // ---- weight-variant evaluator ---------------------------------------------

    /// Ten persistent-drift symbols: growth rates ordered G0 < ... < G9 with
    /// the shared wobble scale, long enough history for every eval point.
    /// The steep decliners run crushed RSIs (real meanrev readings), the
    /// gainers do not — so trend-tilted and meanrev-tilted blends rank
    /// genuinely different names on top.
    fn eval_fixture_store() -> (BarStore, Vec<String>) {
        let store = BarStore::new();
        let mut symbols = Vec::new();
        let rates = [
            0.988, 0.990, 0.992, 0.994, 0.996, 1.004, 1.008, 1.012, 1.016, 1.020,
        ];
        for (i, g) in rates.into_iter().enumerate() {
            let sym = format!("G{i}");
            push_series(&store, &sym, &wobble(g, 480));
            symbols.push(sym);
        }
        (store, symbols)
    }

    #[test]
    fn weight_evaluator_grades_persistent_trends_and_is_deterministic() {
        let (store, symbols) = eval_fixture_store();
        // Trend/momentum-tilted weights on persistent drifts: the top
        // composite decile keeps outperforming the bottom -> positive spread.
        let trendy = ScanWeights {
            trend: 0.40,
            momentum: 0.40,
            breakout: 0.10,
            meanrev: 0.05,
            vol_state: 0.05,
        };
        let spread = evaluate_weight_variant(&store, &symbols, &trendy)
            .expect("fixture has depth for every eval point");
        assert!(spread.is_finite());
        assert!(spread > 0.0, "persistent drift must grade positive: {spread}");
        // Deterministic: same frozen data, same weights, same spread.
        assert_eq!(
            evaluate_weight_variant(&store, &symbols, &trendy),
            Some(spread)
        );
        // A meanrev-dominated blend ranks the crushed-RSI decliners on top;
        // their forward returns keep falling -> strictly worse spread.
        let contrarian = ScanWeights {
            trend: 0.05,
            momentum: 0.05,
            breakout: 0.05,
            meanrev: 0.50,
            vol_state: 0.05,
        };
        let spread_c = evaluate_weight_variant(&store, &symbols, &contrarian)
            .expect("same fixture");
        assert!(
            spread_c < spread,
            "contrarian blend must grade below trend blend: {spread_c} vs {spread}"
        );
    }

    #[test]
    fn weight_evaluator_refuses_thin_fixtures() {
        // Too few symbols for a decile spread at any point: None.
        let store = BarStore::new();
        push_series(&store, "ONE", &wobble(1.002, 480));
        push_series(&store, "TWO", &wobble(0.999, 480));
        assert_eq!(
            evaluate_weight_variant(&store, &syms(&["ONE", "TWO"]), &BASE_WEIGHTS),
            None
        );
        // Enough symbols, but history too short to truncate at any eval
        // point (needs off + MIN_BARS): None, never a fabricated spread.
        let store = BarStore::new();
        let names = ["A", "B", "C", "D", "E"];
        for (i, s) in names.iter().enumerate() {
            push_series(&store, s, &wobble(1.0 + i as f64 / 1e4, EVAL_FWD_BARS + MIN_BARS - 1));
        }
        assert_eq!(
            evaluate_weight_variant(&store, &syms(&names), &BASE_WEIGHTS),
            None
        );
        // Empty store / empty universe: None.
        assert_eq!(evaluate_weight_variant(&BarStore::new(), &[], &BASE_WEIGHTS), None);
    }
}
