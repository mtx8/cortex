//! The built-in strategy runtime. One task, bar-driven, no per-bar spam:
//! every strategy forms an opinion on each COMPLETE M1 bar but publishes a
//! `Signal` only when that opinion changes materially.

use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;

use cx_core::bus::BusEvent;
use cx_core::events::{AgentThought, Bar, EngineEvent, StrategySignal};
use cx_core::store::BarStore;
use cx_core::time::now_ms;
use cx_core::types::{Interval, Severity};
use cx_core::{Bus, Config};
use cx_ta::{compute_features, detect_regime, Regime};
use tokio::sync::broadcast::error::RecvError;
use tokio::sync::broadcast::Receiver;

use crate::{sgn, Shared, BUILT_INS};

/// Rolling per-symbol window cap (complete bars only).
const WINDOW_CAP: usize = 600;
/// Bars requested from the store at startup to warm each strategy.
const WARMUP_BARS: usize = 300;
/// A strategy republishes when conviction moves more than this (or on a
/// direction sign change).
const CONVICTION_DELTA: f64 = 0.15;
/// Conviction carried by a flat (no-edge) opinion.
const FLAT_CONVICTION: f64 = 0.3;
/// meanrev_z opens a fade at this |zscore_20| ...
const MEANREV_ENTRY_Z: f64 = 2.0;
/// ... and returns to flat once |zscore_20| decays back inside this band.
const MEANREV_EXIT_Z: f64 = 0.5;
/// breakout_d requires bar range >= this fraction of ATR to confirm.
const BREAKOUT_RANGE_ATR: f64 = 0.8;
/// breakout_d decays to flat after this many bars without a new breakout.
const BREAKOUT_DECAY_BARS: u32 = 30;

/// A strategy's opinion for one symbol on one bar.
#[derive(Debug, Clone)]
struct Opinion {
    /// Direction in [-1, 1]; 0 is flat.
    direction: f64,
    /// Conviction in [0, 1].
    conviction: f64,
    rationale: String,
    /// The inputs that drove the call (finite by cx-ta invariant).
    features: BTreeMap<String, f64>,
}

impl Opinion {
    fn flat(reason: &str) -> Self {
        Self {
            direction: 0.0,
            conviction: FLAT_CONVICTION,
            rationale: reason.to_string(),
            features: BTreeMap::new(),
        }
    }
}

/// breakout_d per-symbol state: the active side and how stale it is.
#[derive(Debug, Default)]
struct BreakoutState {
    /// +1 long breakout, -1 short, 0 flat.
    active: i8,
    /// Conviction locked in at the breakout bar.
    conviction: f64,
    /// Bars elapsed since the last fresh breakout.
    bars_since: u32,
}

/// All rolling state for one symbol.
struct SymState {
    /// Complete M1 bars only, capped at [`WINDOW_CAP`].
    window: Vec<Bar>,
    /// Features of the window as of the PREVIOUS bar — breakout_d compares
    /// the live close against this donchian channel.
    prev_feats: Option<BTreeMap<String, f64>>,
    /// meanrev_z open fade side: +1 long, -1 short, 0 flat.
    meanrev_open: i8,
    breakout: BreakoutState,
    /// Last PUBLISHED (direction, conviction) per built-in, indexed like
    /// [`BUILT_INS`]. None = never published / reset by a disable.
    last_pub: [Option<(f64, f64)>; 3],
}

impl SymState {
    fn new() -> Self {
        Self {
            window: Vec::new(),
            prev_feats: None,
            meanrev_open: 0,
            breakout: BreakoutState::default(),
            last_pub: [None, None, None],
        }
    }
}

/// The strategy runtime task. Warms from the store, then reacts to complete
/// M1 bars for configured symbols until the bus closes.
pub(crate) async fn run(
    bus: Arc<Bus>,
    store: Arc<BarStore>,
    cfg: Config,
    shared: Arc<Shared>,
    mut rx: Receiver<BusEvent>,
) {
    let mut states: HashMap<String, SymState> = HashMap::new();
    for sym in &cfg.symbols {
        let mut st = SymState::new();
        st.window = store
            .recent(sym, Interval::M1, WARMUP_BARS)
            .into_iter()
            .filter(|b| b.complete)
            .collect();
        if !st.window.is_empty() {
            // Baseline the donchian channel so the first live bar can be
            // judged against the warmed window, not against nothing.
            st.prev_feats = Some(compute_features(&st.window));
        }
        tracing::debug!(symbol = %sym, warm_bars = st.window.len(), "strategy warmup");
        states.insert(sym.clone(), st);
    }

    loop {
        match rx.recv().await {
            Ok(ev) => {
                if let EngineEvent::Bar(bar) = ev.as_ref() {
                    if bar.complete && bar.interval == Interval::M1 {
                        if let Some(st) = states.get_mut(&bar.symbol) {
                            on_bar(&bus, &shared, st, bar);
                        }
                    }
                }
            }
            Err(RecvError::Lagged(n)) => {
                tracing::warn!(lagged = n, "strategy runtime lagged on bus");
            }
            Err(RecvError::Closed) => break,
        }
    }
}

/// Ingest one complete M1 bar and re-evaluate every enabled built-in.
fn on_bar(bus: &Bus, shared: &Shared, st: &mut SymState, bar: &Bar) {
    // NaN-safety: a bar with non-finite prices never enters the window.
    if !(bar.open.is_finite()
        && bar.high.is_finite()
        && bar.low.is_finite()
        && bar.close.is_finite())
    {
        tracing::warn!(symbol = %bar.symbol, "dropping non-finite bar");
        return;
    }
    match st.window.last_mut() {
        // Same bucket re-emitted (idempotent rollup): replace.
        Some(last) if last.ts_open_ms == bar.ts_open_ms => *last = bar.clone(),
        // Stale replay out of order: ignore rather than corrupt the series.
        Some(last) if last.ts_open_ms > bar.ts_open_ms => return,
        _ => st.window.push(bar.clone()),
    }
    if st.window.len() > WINDOW_CAP {
        let excess = st.window.len() - WINDOW_CAP;
        st.window.drain(..excess);
    }

    let feats = compute_features(&st.window);
    let (regime, regime_conf) = detect_regime(&st.window);

    let opinions = [
        eval_momentum(&feats, regime, regime_conf),
        eval_meanrev(&feats, regime, &mut st.meanrev_open),
        eval_breakout(bar, st.prev_feats.as_ref(), &feats, &mut st.breakout),
    ];
    for (idx, opinion) in opinions.into_iter().enumerate() {
        if !shared.is_enabled(idx) {
            // Disabled: emit nothing; forget the last publication so a
            // re-enable re-baselines against flat; reset internal state.
            st.last_pub[idx] = None;
            match idx {
                1 => st.meanrev_open = 0,
                2 => st.breakout = BreakoutState::default(),
                _ => {}
            }
            continue;
        }
        publish_if_material(bus, idx, &bar.symbol, opinion, &mut st.last_pub[idx]);
    }
    st.prev_feats = Some(feats);
}

/// Publish the opinion only on a material change: direction sign flip or
/// conviction moving more than [`CONVICTION_DELTA`]. A never-published
/// strategy baselines against the flat opinion, so startup flat opinions
/// stay silent. Flips additionally narrate a Thought.
fn publish_if_material(
    bus: &Bus,
    idx: usize,
    symbol: &str,
    op: Opinion,
    last: &mut Option<(f64, f64)>,
) {
    let (last_dir, last_conv) = last.unwrap_or((0.0, FLAT_CONVICTION));
    let flipped = sgn(op.direction) != sgn(last_dir);
    let moved = (op.conviction - last_conv).abs() > CONVICTION_DELTA;
    if !flipped && !moved {
        return;
    }
    *last = Some((op.direction, op.conviction));

    let name = BUILT_INS[idx];
    let ts = now_ms();
    tracing::debug!(strategy = name, symbol, direction = op.direction, conviction = op.conviction, "signal");
    bus.publish(EngineEvent::Signal(StrategySignal {
        strategy: name.to_string(),
        symbol: symbol.to_string(),
        direction: op.direction,
        conviction: op.conviction,
        rationale: op.rationale.clone(),
        features: op.features,
        ts_ms: ts,
    }));
    if flipped {
        bus.publish(EngineEvent::Thought(AgentThought {
            agent: name.to_string(),
            squadron: "strategy".to_string(),
            severity: Severity::Insight,
            text: format!("{symbol}: {}", op.rationale),
            tags: vec!["strategy".to_string(), name.to_string()],
            confidence: op.conviction,
            symbol: Some(symbol.to_string()),
            ts_ms: ts,
        }));
    }
}

/// "momentum_x": trend-following. Requires a trending regime AND agreement
/// between trend_score, the ema_9/ema_21 stack, and macd_hist; conviction
/// blends |trend_score| with regime confidence into [0.3, 0.95].
fn eval_momentum(feats: &BTreeMap<String, f64>, regime: Regime, regime_conf: f64) -> Opinion {
    if !matches!(regime, Regime::TrendingUp | Regime::TrendingDown) {
        return Opinion::flat("momentum: regime not trending");
    }
    let (Some(&trend), Some(&e9), Some(&e21), Some(&hist)) = (
        feats.get("trend_score"),
        feats.get("ema_9"),
        feats.get("ema_21"),
        feats.get("macd_hist"),
    ) else {
        return Opinion::flat("momentum: features not warm");
    };
    let dir = sgn(trend);
    if dir == 0 || sgn(e9 - e21) != dir || sgn(hist) != dir {
        return Opinion::flat("momentum: trend/ema/macd disagree");
    }
    let conviction = (0.5 * trend.abs() + 0.5 * regime_conf.clamp(0.0, 1.0)).clamp(0.3, 0.95);
    let mut features = BTreeMap::new();
    features.insert("trend_score".to_string(), trend);
    features.insert("ema_9".to_string(), e9);
    features.insert("ema_21".to_string(), e21);
    features.insert("macd_hist".to_string(), hist);
    features.insert("regime_confidence".to_string(), regime_conf);
    if let Some(&rsi) = feats.get("rsi_14") {
        features.insert("rsi_14".to_string(), rsi);
    }
    Opinion {
        direction: dir as f64,
        conviction,
        rationale: format!(
            "momentum: {} trend (score {trend:+.2}, regime conf {regime_conf:.2}), ema9/ema21 and macd_hist {hist:+.4} confirm",
            if dir > 0 { "up" } else { "down" },
        ),
        features,
    }
}

/// "meanrev_z": range fade. Only in Ranging regimes; opens against
/// |zscore_20| >= 2.0, flips if the extreme reverses, and exits once
/// |zscore_20| <= 0.5. Conviction maps |z| in [2, 3.5] to [0.35, 0.8].
fn eval_meanrev(feats: &BTreeMap<String, f64>, regime: Regime, open: &mut i8) -> Opinion {
    if regime != Regime::Ranging {
        *open = 0;
        return Opinion::flat("meanrev: regime not ranging");
    }
    let Some(&z) = feats.get("zscore_20") else {
        *open = 0;
        return Opinion::flat("meanrev: zscore not warm");
    };
    if z.abs() >= MEANREV_ENTRY_Z {
        *open = -sgn(z); // fade the extreme (flips if the extreme reverses)
    } else if z.abs() <= MEANREV_EXIT_Z {
        *open = 0;
    }
    if *open == 0 {
        return Opinion::flat("meanrev: z inside band, no fade open");
    }
    let conviction = (0.35 + (z.abs() - MEANREV_ENTRY_Z) / 1.5 * 0.45).clamp(0.35, 0.8);
    let mut features = BTreeMap::new();
    features.insert("zscore_20".to_string(), z);
    for key in ["rsi_14", "bb_width"] {
        if let Some(&v) = feats.get(key) {
            features.insert(key.to_string(), v);
        }
    }
    Opinion {
        direction: *open as f64,
        conviction,
        rationale: format!(
            "meanrev: fading z {z:+.2} in ranging regime ({})",
            if *open > 0 { "long" } else { "short" },
        ),
        features,
    }
}

/// "breakout_d": donchian channel break. The live close must clear the
/// PRIOR bar's channel with range confirmation (bar range >= 0.8 * ATR).
/// Conviction maps breakout distance in ATRs into [0.35, 0.9]. The opinion
/// decays flat after 30 bars without a fresh breakout, or when the close
/// crosses back through the channel mid.
fn eval_breakout(
    bar: &Bar,
    prev: Option<&BTreeMap<String, f64>>,
    cur: &BTreeMap<String, f64>,
    st: &mut BreakoutState,
) -> Opinion {
    let atr = cur
        .get("atr_14")
        .copied()
        .filter(|a| a.is_finite() && *a > 0.0);
    let prior_hi = prev.and_then(|f| f.get("donchian_hi")).copied();
    let prior_lo = prev.and_then(|f| f.get("donchian_lo")).copied();

    let mut fresh = 0i8;
    if let (Some(atr), Some(hi), Some(lo)) = (atr, prior_hi, prior_lo) {
        let range = bar.high - bar.low;
        if range.is_finite() && range >= BREAKOUT_RANGE_ATR * atr {
            let (side, dist) = if bar.close > hi {
                (1, bar.close - hi)
            } else if bar.close < lo {
                (-1, lo - bar.close)
            } else {
                (0, 0.0)
            };
            if side != 0 {
                fresh = side;
                st.active = side;
                st.bars_since = 0;
                st.conviction = (0.35 + 0.55 * (dist / atr)).clamp(0.35, 0.9);
            }
        }
    }
    if fresh == 0 && st.active != 0 {
        st.bars_since = st.bars_since.saturating_add(1);
        let mid = match (cur.get("donchian_hi"), cur.get("donchian_lo")) {
            (Some(h), Some(l)) => Some(0.5 * (h + l)),
            _ => None,
        };
        let crossed_back = mid
            .map(|m| (st.active > 0 && bar.close < m) || (st.active < 0 && bar.close > m))
            .unwrap_or(false);
        if st.bars_since >= BREAKOUT_DECAY_BARS || crossed_back {
            *st = BreakoutState::default();
            return Opinion::flat(if crossed_back {
                "breakout: close crossed back through channel mid"
            } else {
                "breakout: decayed after 30 bars without a fresh break"
            });
        }
    }
    if st.active == 0 {
        return Opinion::flat("breakout: no active channel break");
    }
    let mut features = BTreeMap::new();
    features.insert("close".to_string(), bar.close);
    if let Some(a) = atr {
        features.insert("atr_14".to_string(), a);
    }
    if let Some(hi) = prior_hi {
        features.insert("donchian_hi".to_string(), hi);
    }
    if let Some(lo) = prior_lo {
        features.insert("donchian_lo".to_string(), lo);
    }
    Opinion {
        direction: st.active as f64,
        conviction: st.conviction,
        rationale: format!(
            "breakout: {} donchian break held for {} bars (close {:.4})",
            if st.active > 0 { "upside" } else { "downside" },
            st.bars_since,
            bar.close,
        ),
        features,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feats(pairs: &[(&str, f64)]) -> BTreeMap<String, f64> {
        pairs.iter().map(|(k, v)| (k.to_string(), *v)).collect()
    }

    fn bar(close: f64, high: f64, low: f64) -> Bar {
        Bar {
            symbol: "TST-USD".into(),
            interval: Interval::M1,
            ts_open_ms: 0,
            open: close,
            high,
            low,
            close,
            volume: 1.0,
            trade_count: 1,
            vwap: close,
            complete: true,
        }
    }

    #[test]
    fn momentum_flat_when_not_trending() {
        let f = feats(&[
            ("trend_score", 0.8),
            ("ema_9", 101.0),
            ("ema_21", 100.0),
            ("macd_hist", 0.5),
        ]);
        let op = eval_momentum(&f, Regime::Ranging, 0.9);
        assert_eq!(sgn(op.direction), 0);
        assert!((op.conviction - FLAT_CONVICTION).abs() < 1e-12);
    }

    #[test]
    fn momentum_requires_confirmation() {
        // macd_hist disagrees with the trend sign -> flat.
        let f = feats(&[
            ("trend_score", 0.8),
            ("ema_9", 101.0),
            ("ema_21", 100.0),
            ("macd_hist", -0.5),
        ]);
        let op = eval_momentum(&f, Regime::TrendingUp, 0.8);
        assert_eq!(sgn(op.direction), 0);

        // Full agreement -> long with blended conviction in bounds.
        let f = feats(&[
            ("trend_score", 0.8),
            ("ema_9", 101.0),
            ("ema_21", 100.0),
            ("macd_hist", 0.5),
        ]);
        let op = eval_momentum(&f, Regime::TrendingUp, 0.8);
        assert_eq!(sgn(op.direction), 1);
        assert!((op.conviction - 0.8).abs() < 1e-12);
        assert!((0.3..=0.95).contains(&op.conviction));
        assert!(op.features.contains_key("trend_score"));
    }

    #[test]
    fn meanrev_opens_fades_and_exits() {
        let mut open = 0i8;
        // Below entry threshold: stays flat.
        let op = eval_meanrev(&feats(&[("zscore_20", 1.5)]), Regime::Ranging, &mut open);
        assert_eq!(sgn(op.direction), 0);
        // Extreme high z -> fade short.
        let op = eval_meanrev(&feats(&[("zscore_20", 2.6)]), Regime::Ranging, &mut open);
        assert_eq!(sgn(op.direction), -1);
        assert!((0.35..=0.8).contains(&op.conviction));
        // Holding inside the band keeps the fade at floor conviction.
        let op = eval_meanrev(&feats(&[("zscore_20", 1.0)]), Regime::Ranging, &mut open);
        assert_eq!(sgn(op.direction), -1);
        assert!((op.conviction - 0.35).abs() < 1e-12);
        // Decay to |z| <= 0.5 closes the fade.
        let op = eval_meanrev(&feats(&[("zscore_20", 0.3)]), Regime::Ranging, &mut open);
        assert_eq!(sgn(op.direction), 0);
        // Non-ranging regime force-closes.
        open = 1;
        let op = eval_meanrev(&feats(&[("zscore_20", 3.0)]), Regime::TrendingUp, &mut open);
        assert_eq!(sgn(op.direction), 0);
        assert_eq!(open, 0);
    }

    #[test]
    fn meanrev_conviction_scales_with_z() {
        let mut open = 0i8;
        let low = eval_meanrev(&feats(&[("zscore_20", -2.0)]), Regime::Ranging, &mut open);
        open = 0;
        let high = eval_meanrev(&feats(&[("zscore_20", -3.5)]), Regime::Ranging, &mut open);
        assert!((low.conviction - 0.35).abs() < 1e-9);
        assert!((high.conviction - 0.8).abs() < 1e-9);
        assert_eq!(sgn(low.direction), 1); // fade a low extreme = buy
    }

    #[test]
    fn breakout_fires_holds_and_decays() {
        let mut st = BreakoutState::default();
        let prior = feats(&[("donchian_hi", 101.0), ("donchian_lo", 100.0)]);
        let cur = feats(&[
            ("atr_14", 1.0),
            ("donchian_hi", 102.5),
            ("donchian_lo", 100.0),
        ]);
        // Range-confirmed upside break: 102.5 clears prior hi by 1.5 ATR.
        let op = eval_breakout(&bar(102.5, 102.6, 100.9), Some(&prior), &cur, &mut st);
        assert_eq!(sgn(op.direction), 1);
        assert!((op.conviction - 0.9).abs() < 1e-12); // clamped at 0.9
        // Holds while the close stays above the current channel mid.
        let op = eval_breakout(&bar(102.0, 102.1, 101.9), Some(&prior), &cur, &mut st);
        assert_eq!(sgn(op.direction), 1);
        // Close back through mid (101.25) -> flat.
        let op = eval_breakout(&bar(100.5, 100.6, 100.4), Some(&prior), &cur, &mut st);
        assert_eq!(sgn(op.direction), 0);
        assert_eq!(st.active, 0);
    }

    #[test]
    fn breakout_requires_range_confirmation() {
        let mut st = BreakoutState::default();
        let prior = feats(&[("donchian_hi", 101.0), ("donchian_lo", 100.0)]);
        let cur = feats(&[("atr_14", 1.0)]);
        // Close clears the channel but the bar range is too small.
        let op = eval_breakout(&bar(101.5, 101.55, 101.45), Some(&prior), &cur, &mut st);
        assert_eq!(sgn(op.direction), 0);
    }

    #[test]
    fn breakout_decays_after_30_bars() {
        let mut st = BreakoutState {
            active: 1,
            conviction: 0.6,
            bars_since: 0,
        };
        let prior = feats(&[("donchian_hi", 101.0), ("donchian_lo", 100.0)]);
        // No donchian in cur -> no mid-cross exit; only the bar clock runs.
        let cur = feats(&[("atr_14", 1.0)]);
        let mut last_dir = 1;
        for _ in 0..BREAKOUT_DECAY_BARS {
            let op = eval_breakout(&bar(103.0, 103.05, 102.95), Some(&prior), &cur, &mut st);
            last_dir = sgn(op.direction);
        }
        assert_eq!(last_dir, 0);
    }

    #[test]
    fn no_spam_identical_opinions_do_not_republish() {
        let bus = Bus::new(64);
        let mut rx = bus.subscribe();
        let mut last = None;
        let op = || Opinion {
            direction: 1.0,
            conviction: 0.7,
            rationale: "test".into(),
            features: BTreeMap::new(),
        };
        publish_if_material(&bus, 0, "TST-USD", op(), &mut last);
        publish_if_material(&bus, 0, "TST-USD", op(), &mut last);
        publish_if_material(&bus, 0, "TST-USD", op(), &mut last);
        let mut signals = 0;
        while let Ok(ev) = rx.try_recv() {
            if matches!(ev.as_ref(), EngineEvent::Signal(_)) {
                signals += 1;
            }
        }
        assert_eq!(signals, 1, "identical opinions must publish exactly once");
    }

    #[test]
    fn startup_flat_opinion_is_silent_but_flip_narrates() {
        let bus = Bus::new(64);
        let mut rx = bus.subscribe();
        let mut last = None;
        publish_if_material(&bus, 0, "TST-USD", Opinion::flat("warmup"), &mut last);
        assert!(rx.try_recv().is_err(), "flat baseline must not publish");
        publish_if_material(
            &bus,
            0,
            "TST-USD",
            Opinion {
                direction: -1.0,
                conviction: 0.5,
                rationale: "short".into(),
                features: BTreeMap::new(),
            },
            &mut last,
        );
        let kinds: Vec<&'static str> = std::iter::from_fn(|| rx.try_recv().ok())
            .map(|ev| ev.kind())
            .collect();
        assert_eq!(kinds, vec!["signal", "thought"]);
    }
}
