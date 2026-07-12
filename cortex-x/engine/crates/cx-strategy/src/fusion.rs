//! Signal fusion. Listens to every `EngineEvent::Signal` on the bus except
//! "fusion" itself (so the LLM strategist and any future squadron feed in),
//! keeps the latest opinion per (strategy, symbol), and on each complete M1
//! bar publishes ONE fused opinion per symbol — the only signal the trade
//! pipeline acts on.
//!
//! Weighting: conviction * exp(-age_minutes / 5) * strategy weight. The
//! per-strategy weight is learned ONLINE via Hedge (multiplicative weights):
//! on every completed M1 bar, each strategy with an active signal on that
//! bar's symbol is scored against the bar-to-bar vol-normalized return
//! (w <- w * exp(eta * direction * r_hat), eta = 0.15, r_hat clamped to
//! +/-3), then all known weights are renormalized to mean 1.0 and clamped
//! into [0.15, 3.0] — a bad strategy decays toward the floor, a hot one
//! compounds toward the cap, none ever dies or dominates. Initial weights
//! keep the old static prior: built-ins 1.0, "llm-strategist" 0.6, unknown
//! sources 0.4. The vol normalizer is an internal per-symbol EWMA variance
//! of bar-to-bar returns (lambda = 0.94, RiskMetrics-style), seeded with the
//! first squared return. Live weights are surfaced in every fused signal's
//! `features` map as `w_<strategy>`.
//!
//! Fused conviction is the weighted mean conviction scaled by an agreement
//! factor (1.0 all signs agree -> 0.4 full disagreement). Contributors older
//! than 30 minutes drop out entirely.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;

use cx_core::bus::BusEvent;
use cx_core::events::{AgentThought, Bar, EngineEvent, StrategySignal};
use cx_core::time::now_ms;
use cx_core::types::{Interval, Severity};
use cx_core::{Bus, Config};
use tokio::sync::broadcast::error::RecvError;
use tokio::sync::broadcast::Receiver;

use crate::{sgn, Shared, BUILT_INS};

/// Contributors older than this are expired from the book.
const MAX_AGE_MS: i64 = 30 * 60_000;
/// e-folding time of the recency decay, in minutes.
const DECAY_MINUTES: f64 = 5.0;
/// Republish only when fused direction or conviction moved more than this.
const REPUBLISH_DELTA: f64 = 0.1;
/// Agreement factor floor under full sign disagreement.
const MIN_AGREEMENT: f64 = 0.4;
/// Hard cap on tracked (strategy, symbol) entries — bounded memory even if
/// the bus carries arbitrarily many exotic strategy names.
const MAX_ENTRIES: usize = 512;
/// Hedge learning rate.
const HEDGE_ETA: f64 = 0.15;
/// Vol-normalized returns are clamped to +/- this before the Hedge update.
const HEDGE_RET_CLAMP: f64 = 3.0;
/// No strategy weight ever decays below this (nothing dies) ...
const WEIGHT_FLOOR: f64 = 0.15;
/// ... or compounds above this (nothing dominates).
const WEIGHT_CAP: f64 = 3.0;
/// EWMA decay of the per-symbol return-variance estimate (RiskMetrics).
const VOL_LAMBDA: f64 = 0.94;

/// One remembered contributor opinion (already validated finite).
#[derive(Debug, Clone)]
struct Contribution {
    direction: f64,
    conviction: f64,
    ts_ms: i64,
}

/// Per-symbol EWMA state backing the Hedge vol normalizer.
#[derive(Debug, Clone, Copy)]
struct VolState {
    last_close: f64,
    /// EWMA of squared bar-to-bar returns; NaN until the first return.
    ewma_var: f64,
}

/// The fusion book: latest signal per (strategy, symbol), the last published
/// fused opinion per symbol (the no-spam baseline), the learned Hedge weight
/// per strategy, and per-symbol vol state for return normalization.
#[derive(Debug, Default)]
pub(crate) struct FusionBook {
    latest: HashMap<(String, String), Contribution>,
    last_pub: HashMap<String, (f64, f64)>,
    /// Learned Hedge weight per strategy; seeded from [`initial_weight`] on
    /// first sight, bounded to [`MAX_ENTRIES`] names.
    weights: HashMap<String, f64>,
    /// Per-symbol return/vol state; keyed only by configured symbols (the
    /// bar path filters), so bounded.
    vol: HashMap<String, VolState>,
}

impl FusionBook {
    /// Drop every symbol's latest signal for `strategy` (disable path). The
    /// learned Hedge weight intentionally survives — while disabled the
    /// strategy has no active signals, so its weight cannot drift, and a
    /// re-enable resumes from what was learned.
    pub(crate) fn remove_strategy(&mut self, strategy: &str) {
        self.latest.retain(|(s, _), _| s != strategy);
    }

    /// The current blend weight for a strategy: learned if known, otherwise
    /// the static prior.
    fn weight_of(&self, name: &str) -> f64 {
        self.weights
            .get(name)
            .copied()
            .unwrap_or_else(|| initial_weight(name))
    }
}

/// Initial (prior) weight per source — the same starting point the old
/// static blend used. Built-ins are trusted 1.0; the LLM strategist advises
/// at 0.6; anything unknown on the bus starts at 0.4. Hedge takes it from
/// there.
fn initial_weight(name: &str) -> f64 {
    if BUILT_INS.contains(&name) {
        1.0
    } else if name == "llm-strategist" {
        0.6
    } else {
        0.4
    }
}

/// The fusion task: signals update the book, complete M1 bars trigger a
/// fuse for that bar's symbol. Runs until the bus closes.
pub(crate) async fn run(bus: Arc<Bus>, cfg: Config, shared: Arc<Shared>, mut rx: Receiver<BusEvent>) {
    let symbols: HashSet<String> = cfg.symbols.iter().cloned().collect();
    loop {
        match rx.recv().await {
            Ok(ev) => match ev.as_ref() {
                EngineEvent::Signal(sig) if sig.strategy != "fusion" => on_signal(&shared, sig),
                EngineEvent::Bar(bar)
                    if bar.complete
                        && bar.interval == Interval::M1
                        && symbols.contains(&bar.symbol) =>
                {
                    hedge_on_bar(&shared, bar);
                    fuse_and_publish(&bus, &shared, &bar.symbol);
                }
                _ => {}
            },
            Err(RecvError::Lagged(n)) => {
                tracing::warn!(lagged = n, "fusion lagged on bus");
            }
            Err(RecvError::Closed) => break,
        }
    }
}

/// Record the latest signal per (strategy, symbol). Non-finite payloads are
/// dropped; signals from a disabled built-in never (re-)enter the book, so
/// an in-flight signal cannot race past a disable purge.
fn on_signal(shared: &Shared, sig: &StrategySignal) {
    if !(sig.direction.is_finite() && sig.conviction.is_finite()) {
        tracing::warn!(strategy = %sig.strategy, symbol = %sig.symbol, "dropping non-finite signal");
        return;
    }
    if let Some(idx) = BUILT_INS.iter().position(|n| *n == sig.strategy) {
        if !shared.is_enabled(idx) {
            return;
        }
    }
    let key = (sig.strategy.clone(), sig.symbol.clone());
    let mut book = shared.lock_fusion();
    if book.latest.len() >= MAX_ENTRIES && !book.latest.contains_key(&key) {
        // Bounded memory: evict the stalest entry to admit the new one.
        if let Some(oldest) = book
            .latest
            .iter()
            .min_by_key(|(_, c)| c.ts_ms)
            .map(|(k, _)| k.clone())
        {
            book.latest.remove(&oldest);
        }
    }
    // Seed the Hedge weight on first sight so renormalization spans every
    // known strategy; same bound as the signal book.
    if !book.weights.contains_key(&sig.strategy) && book.weights.len() < MAX_ENTRIES {
        book.weights
            .insert(sig.strategy.clone(), initial_weight(&sig.strategy));
    }
    book.latest.insert(
        key,
        Contribution {
            direction: sig.direction.clamp(-1.0, 1.0),
            conviction: sig.conviction.clamp(0.0, 1.0),
            ts_ms: sig.ts_ms,
        },
    );
}

/// The online Hedge update, run on every completed M1 bar BEFORE the fuse.
///
/// The bar closes the "next bar" for the signals already in the book, so
/// each strategy holding an active (non-expired) opinion on this symbol is
/// scored: w <- w * exp(eta * direction * r_hat). r_hat is the bar-to-bar
/// return divided by the symbol's EWMA vol (sqrt of the lambda=0.94 EWMA of
/// squared returns, seeded with the first squared return) and clamped to
/// +/-3; flat opinions score exp(0) = 1 and are untouched. After the
/// updates, all known weights renormalize to mean 1.0 and clamp into
/// [0.15, 3.0]. NaN-safe: a non-finite close, return, or normalizer skips
/// the entire update, leaving weights unchanged.
fn hedge_on_bar(shared: &Shared, bar: &Bar) {
    let mut book = shared.lock_fusion();

    // --- return + EWMA vol update -------------------------------------
    if !(bar.close.is_finite() && bar.close > 0.0) {
        return; // never let a bad close poison last_close or the weights
    }
    let prev = book.vol.get(&bar.symbol).copied();
    let mut r_hat: Option<f64> = None;
    let next_state = match prev {
        Some(v) if v.last_close > 0.0 => {
            let r = bar.close / v.last_close - 1.0;
            if r.is_finite() {
                let var = if v.ewma_var.is_finite() {
                    VOL_LAMBDA * v.ewma_var + (1.0 - VOL_LAMBDA) * r * r
                } else {
                    r * r // seed on the first observed return
                };
                let vol = var.sqrt();
                if vol > 0.0 {
                    let z = (r / vol).clamp(-HEDGE_RET_CLAMP, HEDGE_RET_CLAMP);
                    if z.is_finite() {
                        r_hat = Some(z);
                    }
                }
                VolState {
                    last_close: bar.close,
                    ewma_var: var,
                }
            } else {
                VolState {
                    last_close: bar.close,
                    ewma_var: v.ewma_var,
                }
            }
        }
        _ => VolState {
            last_close: bar.close,
            ewma_var: f64::NAN,
        },
    };
    book.vol.insert(bar.symbol.clone(), next_state);
    let Some(r_hat) = r_hat else {
        return; // no scorable return this bar; weights unchanged
    };

    // --- multiplicative update for active contributors ----------------
    let now = now_ms();
    let scored: Vec<(String, f64)> = book
        .latest
        .iter()
        .filter(|((_, sym), c)| {
            sym == &bar.symbol && now.saturating_sub(c.ts_ms) <= MAX_AGE_MS
        })
        .map(|((strat, _), c)| (strat.clone(), c.direction))
        .collect();
    if scored.is_empty() {
        return;
    }
    for (strat, direction) in scored {
        let factor = (HEDGE_ETA * direction * r_hat).exp();
        let w = book.weight_of(&strat) * factor;
        if !w.is_finite() {
            continue;
        }
        if book.weights.contains_key(&strat) || book.weights.len() < MAX_ENTRIES {
            book.weights.insert(strat, w);
        }
    }

    // --- renormalize to mean 1.0, then floor/cap ----------------------
    let n = book.weights.len();
    if n > 0 {
        let sum: f64 = book.weights.values().sum();
        if sum.is_finite() && sum > 0.0 {
            let scale = n as f64 / sum;
            for w in book.weights.values_mut() {
                *w = (*w * scale).clamp(WEIGHT_FLOOR, WEIGHT_CAP);
            }
        }
    }
}

/// Fuse the live contributors for one symbol and publish if the opinion
/// moved materially. With zero contributors the fused opinion is flat
/// (0, 0), so an emptied book decays the published fusion to flat once.
fn fuse_and_publish(bus: &Bus, shared: &Shared, symbol: &str) {
    let now = now_ms();
    let mut book = shared.lock_fusion();
    book.latest
        .retain(|_, c| now.saturating_sub(c.ts_ms) <= MAX_AGE_MS);

    // (strategy, direction, conviction, blend weight), name-sorted for a
    // deterministic rationale. The blend weight folds in the LIVE Hedge
    // weight for the source strategy.
    let mut contribs: Vec<(String, f64, f64, f64)> = book
        .latest
        .iter()
        .filter(|((_, sym), _)| sym == symbol)
        .filter_map(|((strat, _), c)| {
            let age_min = (now - c.ts_ms).max(0) as f64 / 60_000.0;
            let w = c.conviction * (-age_min / DECAY_MINUTES).exp() * book.weight_of(strat);
            (w.is_finite() && w > 0.0).then(|| (strat.clone(), c.direction, c.conviction, w))
        })
        .collect();
    contribs.sort_by(|a, b| a.0.cmp(&b.0));
    // Live per-strategy Hedge weights for the features map (`w_<strategy>`).
    let live_weights: Vec<(String, f64)> = contribs
        .iter()
        .map(|(name, ..)| (name.clone(), book.weight_of(name)))
        .collect();

    let (direction, conviction) = if contribs.is_empty() {
        (0.0, 0.0)
    } else {
        let wsum: f64 = contribs.iter().map(|c| c.3).sum();
        let dir = contribs.iter().map(|c| c.1 * c.3).sum::<f64>() / wsum;
        let mean_conv = contribs.iter().map(|c| c.2 * c.3).sum::<f64>() / wsum;
        // Agreement over contributors with a live sign; all-flat books read
        // as agreeing on flat.
        let signed: Vec<&(String, f64, f64, f64)> =
            contribs.iter().filter(|c| sgn(c.1) != 0).collect();
        let agreement = if signed.is_empty() {
            1.0
        } else {
            let sw: f64 = signed.iter().map(|c| c.3).sum();
            let m = signed.iter().map(|c| f64::from(sgn(c.1)) * c.3).sum::<f64>() / sw;
            MIN_AGREEMENT + (1.0 - MIN_AGREEMENT) * m.abs()
        };
        (
            dir.clamp(-1.0, 1.0),
            (mean_conv * agreement).clamp(0.0, 1.0),
        )
    };

    let (last_dir, last_conv) = book.last_pub.get(symbol).copied().unwrap_or((0.0, 0.0));
    if (direction - last_dir).abs() <= REPUBLISH_DELTA
        && (conviction - last_conv).abs() <= REPUBLISH_DELTA
    {
        return;
    }
    book.last_pub
        .insert(symbol.to_string(), (direction, conviction));
    drop(book);

    let rationale = if contribs.is_empty() {
        "no live contributors; flat".to_string()
    } else {
        contribs
            .iter()
            .map(|(name, d, c, _)| format!("{name} {:+.2}", d * c))
            .collect::<Vec<_>>()
            .join(", ")
    };
    let mut features = BTreeMap::new();
    for (name, d, c, _) in &contribs {
        features.insert(name.clone(), d * c);
    }
    for (name, w) in &live_weights {
        features.insert(format!("w_{name}"), *w);
    }
    let ts = now_ms();
    tracing::debug!(symbol, direction, conviction, %rationale, "fusion");
    bus.publish(EngineEvent::Signal(StrategySignal {
        strategy: "fusion".to_string(),
        symbol: symbol.to_string(),
        direction,
        conviction,
        rationale: rationale.clone(),
        features,
        ts_ms: ts,
    }));
    bus.publish(EngineEvent::Thought(AgentThought {
        agent: "fusion".to_string(),
        squadron: "strategy".to_string(),
        severity: Severity::Insight,
        text: format!("{symbol}: fused {direction:+.2} @ conviction {conviction:.2} — {rationale}"),
        tags: vec!["strategy".to_string(), "fusion".to_string()],
        confidence: conviction,
        symbol: Some(symbol.to_string()),
        ts_ms: ts,
    }));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shared() -> Shared {
        Shared::new()
    }

    fn sig(strategy: &str, symbol: &str, direction: f64, conviction: f64, ts_ms: i64) -> StrategySignal {
        StrategySignal {
            strategy: strategy.into(),
            symbol: symbol.into(),
            direction,
            conviction,
            rationale: "test".into(),
            features: BTreeMap::new(),
            ts_ms,
        }
    }

    fn fused_signal(rx: &mut Receiver<BusEvent>) -> Option<StrategySignal> {
        while let Ok(ev) = rx.try_recv() {
            if let EngineEvent::Signal(s) = ev.as_ref() {
                if s.strategy == "fusion" {
                    return Some(s.clone());
                }
            }
        }
        None
    }

    fn m1_bar(i: i64, close: f64) -> cx_core::events::Bar {
        cx_core::events::Bar {
            symbol: "TST".into(),
            interval: Interval::M1,
            ts_open_ms: i * 60_000,
            open: close,
            high: close,
            low: close,
            close,
            volume: 1.0,
            trade_count: 1,
            vwap: close,
            complete: true,
        }
    }

    #[test]
    fn initial_weights_by_source() {
        assert_eq!(initial_weight("momentum_x"), 1.0);
        assert_eq!(initial_weight("meanrev_z"), 1.0);
        assert_eq!(initial_weight("breakout_d"), 1.0);
        assert_eq!(initial_weight("kalman_trend"), 1.0);
        assert_eq!(initial_weight("llm-strategist"), 0.6);
        assert_eq!(initial_weight("mystery_alpha"), 0.4);
    }

    #[test]
    fn hedge_rewards_the_right_strategy_and_decays_the_wrong_one() {
        // A is always long, B always short, and the price only rises:
        // A must compound toward the cap, B must decay to the floor.
        let sh = shared();
        let mut close = 100.0;
        for i in 0..120_i64 {
            let now = now_ms();
            on_signal(&sh, &sig("a", "TST", 1.0, 0.8, now));
            on_signal(&sh, &sig("b", "TST", -1.0, 0.8, now));
            hedge_on_bar(&sh, &m1_bar(i, close));
            close *= 1.001; // deterministic +10bps per bar
        }
        let book = sh.lock_fusion();
        let wa = book.weights["a"];
        let wb = book.weights["b"];
        assert!(wa > 1.5, "right strategy must rise toward the cap: {wa}");
        assert!(
            (wb - WEIGHT_FLOOR).abs() < 1e-9,
            "wrong strategy must sit at the floor: {wb}"
        );
        for w in book.weights.values() {
            assert!((WEIGHT_FLOOR..=WEIGHT_CAP).contains(w), "out of bounds: {w}");
        }
    }

    #[test]
    fn hedge_renormalizes_to_mean_one_when_unclamped() {
        let sh = shared();
        let mut close = 100.0;
        for i in 0..4_i64 {
            let now = now_ms();
            on_signal(&sh, &sig("a", "TST", 1.0, 0.8, now));
            on_signal(&sh, &sig("b", "TST", -1.0, 0.8, now));
            hedge_on_bar(&sh, &m1_bar(i, close));
            close *= 1.001;
        }
        let book = sh.lock_fusion();
        let mean: f64 =
            book.weights.values().sum::<f64>() / book.weights.len() as f64;
        assert!((mean - 1.0).abs() < 1e-9, "mean must be 1.0: {mean}");
        for w in book.weights.values() {
            assert!((WEIGHT_FLOOR..=WEIGHT_CAP).contains(w));
        }
    }

    #[test]
    fn hedge_ignores_non_finite_bars() {
        let sh = shared();
        let mut close = 100.0;
        for i in 0..5_i64 {
            on_signal(&sh, &sig("a", "TST", 1.0, 0.8, now_ms()));
            // A flat contributor keeps the renorm from pinning "a" at 1.0.
            on_signal(&sh, &sig("b", "TST", 0.0, 0.3, now_ms()));
            hedge_on_bar(&sh, &m1_bar(i, close));
            close *= 1.001;
        }
        let before = sh.lock_fusion().weights.clone();
        assert!(!before.is_empty());
        hedge_on_bar(&sh, &m1_bar(5, f64::NAN));
        hedge_on_bar(&sh, &m1_bar(6, f64::INFINITY));
        hedge_on_bar(&sh, &m1_bar(7, -1.0));
        let after = sh.lock_fusion().weights.clone();
        assert_eq!(before, after, "bad bars must leave weights unchanged");
        // And the poisoned closes never entered the vol state: the next
        // good bar still scores against the last good close.
        hedge_on_bar(&sh, &m1_bar(8, close));
        assert!(sh.lock_fusion().weights["a"] > after["a"]);
    }

    #[test]
    fn fused_signal_surfaces_live_weights_as_features() {
        let now = now_ms();
        let bus = Bus::new(64);
        let mut rx = bus.subscribe();
        let sh = shared();
        on_signal(&sh, &sig("momentum_x", "TST", 1.0, 0.8, now));
        on_signal(&sh, &sig("llm-strategist", "TST", 1.0, 0.6, now));
        fuse_and_publish(&bus, &sh, "TST");
        let out = fused_signal(&mut rx).expect("fusion");
        assert!((out.features["w_momentum_x"] - 1.0).abs() < 1e-9);
        assert!((out.features["w_llm-strategist"] - 0.6).abs() < 1e-9);
    }

    #[test]
    fn agreement_raises_and_disagreement_lowers_conviction() {
        let now = now_ms();
        let bus = Bus::new(64);
        let mut rx = bus.subscribe();

        let sh = shared();
        on_signal(&sh, &sig("a", "TST", 1.0, 0.8, now));
        on_signal(&sh, &sig("b", "TST", 1.0, 0.8, now));
        fuse_and_publish(&bus, &sh, "TST");
        let agree = fused_signal(&mut rx).expect("agreement fusion");

        let sh = shared();
        on_signal(&sh, &sig("a", "TST", 1.0, 0.8, now));
        on_signal(&sh, &sig("b", "TST", -1.0, 0.8, now));
        fuse_and_publish(&bus, &sh, "TST");
        let disagree = fused_signal(&mut rx).expect("disagreement fusion");

        assert!(agree.direction > 0.9);
        assert!((agree.conviction - 0.8).abs() < 1e-6);
        assert!(disagree.direction.abs() < 1e-9);
        assert!((disagree.conviction - 0.8 * MIN_AGREEMENT).abs() < 1e-6);
        assert!(agree.conviction > disagree.conviction);
    }

    #[test]
    fn llm_outweighs_unknown_sources() {
        let now = now_ms();
        let bus = Bus::new(64);
        let mut rx = bus.subscribe();
        let sh = shared();
        on_signal(&sh, &sig("llm-strategist", "TST", 1.0, 0.8, now));
        on_signal(&sh, &sig("mystery_alpha", "TST", -1.0, 0.8, now));
        fuse_and_publish(&bus, &sh, "TST");
        let out = fused_signal(&mut rx).expect("fusion");
        // (0.48 - 0.32) / 0.80 = +0.20
        assert!((out.direction - 0.2).abs() < 1e-6);
    }

    #[test]
    fn expired_contributors_drop_out() {
        let now = now_ms();
        let bus = Bus::new(64);
        let mut rx = bus.subscribe();
        let sh = shared();
        on_signal(&sh, &sig("stale_src", "TST", -1.0, 0.9, now - MAX_AGE_MS - 60_000));
        on_signal(&sh, &sig("fresh_src", "TST", 1.0, 0.5, now));
        fuse_and_publish(&bus, &sh, "TST");
        let out = fused_signal(&mut rx).expect("fusion");
        assert!(out.direction > 0.9, "stale short must not drag: {out:?}");
        assert!(out.rationale.contains("fresh_src"));
        assert!(!out.rationale.contains("stale_src"));
    }

    #[test]
    fn no_republish_without_material_change_and_flat_decay_publishes_once() {
        let now = now_ms();
        let bus = Bus::new(64);
        let mut rx = bus.subscribe();
        let sh = shared();
        on_signal(&sh, &sig("a", "TST", 1.0, 0.7, now));
        fuse_and_publish(&bus, &sh, "TST");
        assert!(fused_signal(&mut rx).is_some());
        // Same book, next bar: no material change -> silence.
        fuse_and_publish(&bus, &sh, "TST");
        assert!(fused_signal(&mut rx).is_none());
        // Book emptied (e.g. disable purge) -> one flat publish, then quiet.
        sh.lock_fusion().remove_strategy("a");
        fuse_and_publish(&bus, &sh, "TST");
        let flat = fused_signal(&mut rx).expect("flat decay");
        assert_eq!(flat.direction, 0.0);
        assert_eq!(flat.conviction, 0.0);
        fuse_and_publish(&bus, &sh, "TST");
        assert!(fused_signal(&mut rx).is_none());
    }

    #[test]
    fn non_finite_signals_never_enter_the_book() {
        let sh = shared();
        on_signal(&sh, &sig("a", "TST", f64::NAN, 0.7, now_ms()));
        on_signal(&sh, &sig("b", "TST", 1.0, f64::INFINITY, now_ms()));
        assert!(sh.lock_fusion().latest.is_empty());
    }

    #[test]
    fn disabled_built_in_cannot_reenter_book() {
        let sh = shared();
        sh.enabled[0].store(false, std::sync::atomic::Ordering::Relaxed);
        on_signal(&sh, &sig("momentum_x", "TST", 1.0, 0.9, now_ms()));
        assert!(sh.lock_fusion().latest.is_empty());
    }

    #[test]
    fn book_is_bounded() {
        let now = now_ms();
        let sh = shared();
        for i in 0..(MAX_ENTRIES + 50) {
            on_signal(&sh, &sig(&format!("s{i}"), "TST", 1.0, 0.5, now + i as i64));
        }
        assert!(sh.lock_fusion().latest.len() <= MAX_ENTRIES);
    }
}
