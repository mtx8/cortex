//! Signal fusion. Listens to every `EngineEvent::Signal` on the bus except
//! "fusion" itself (so the LLM strategist and any future squadron feed in),
//! keeps the latest opinion per (strategy, symbol), and on each complete M1
//! bar publishes ONE fused opinion per symbol — the only signal the trade
//! pipeline acts on.
//!
//! Weighting: conviction * exp(-age_minutes / 5) * strategy weight
//! (built-ins 1.0, "llm-strategist" 0.6, unknown sources 0.4). Fused
//! conviction is the weighted mean conviction scaled by an agreement factor
//! (1.0 all signs agree -> 0.4 full disagreement). Contributors older than
//! 30 minutes drop out entirely.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;

use cx_core::bus::BusEvent;
use cx_core::events::{AgentThought, EngineEvent, StrategySignal};
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

/// One remembered contributor opinion (already validated finite).
#[derive(Debug, Clone)]
struct Contribution {
    direction: f64,
    conviction: f64,
    ts_ms: i64,
}

/// The fusion book: latest signal per (strategy, symbol) plus the last
/// published fused opinion per symbol (the no-spam baseline).
#[derive(Debug, Default)]
pub(crate) struct FusionBook {
    latest: HashMap<(String, String), Contribution>,
    last_pub: HashMap<String, (f64, f64)>,
}

impl FusionBook {
    /// Drop every symbol's latest signal for `strategy` (disable path).
    pub(crate) fn remove_strategy(&mut self, strategy: &str) {
        self.latest.retain(|(s, _), _| s != strategy);
    }
}

/// Blend weight per source. Built-ins are trusted 1.0; the LLM strategist
/// advises at 0.6; anything unknown on the bus counts at 0.4.
fn strategy_weight(name: &str) -> f64 {
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
    book.latest.insert(
        key,
        Contribution {
            direction: sig.direction.clamp(-1.0, 1.0),
            conviction: sig.conviction.clamp(0.0, 1.0),
            ts_ms: sig.ts_ms,
        },
    );
}

/// Fuse the live contributors for one symbol and publish if the opinion
/// moved materially. With zero contributors the fused opinion is flat
/// (0, 0), so an emptied book decays the published fusion to flat once.
fn fuse_and_publish(bus: &Bus, shared: &Shared, symbol: &str) {
    let now = now_ms();
    let mut book = shared.lock_fusion();
    book.latest
        .retain(|_, c| now.saturating_sub(c.ts_ms) <= MAX_AGE_MS);

    // (strategy, direction, conviction, weight), name-sorted for a
    // deterministic rationale.
    let mut contribs: Vec<(String, f64, f64, f64)> = book
        .latest
        .iter()
        .filter(|((_, sym), _)| sym == symbol)
        .filter_map(|((strat, _), c)| {
            let age_min = (now - c.ts_ms).max(0) as f64 / 60_000.0;
            let w = c.conviction * (-age_min / DECAY_MINUTES).exp() * strategy_weight(strat);
            (w.is_finite() && w > 0.0).then(|| (strat.clone(), c.direction, c.conviction, w))
        })
        .collect();
    contribs.sort_by(|a, b| a.0.cmp(&b.0));

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

    #[test]
    fn weights_by_source() {
        assert_eq!(strategy_weight("momentum_x"), 1.0);
        assert_eq!(strategy_weight("meanrev_z"), 1.0);
        assert_eq!(strategy_weight("breakout_d"), 1.0);
        assert_eq!(strategy_weight("llm-strategist"), 0.6);
        assert_eq!(strategy_weight("mystery_alpha"), 0.4);
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
