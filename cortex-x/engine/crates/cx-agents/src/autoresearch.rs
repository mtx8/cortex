//! AUTORESEARCH — the Karpathy-style recipe-optimization loop (pure half).
//!
//! The engine autonomously runs bounded experiments on its own strategy
//! recipe and adopts improvements. This module is the GRID DEFINITION +
//! ADOPTION RULE + BRIEF FORMATTER — pure and unit-tested here; it runs no
//! experiments itself. cx-agents is bus-only (cx-core + cx-ta), so the
//! experiment RUNNER lives in cortexd, the only crate allowed to import
//! cx-sim: cortexd takes [`param_grid`], replays each variant through
//! `cx_sim::evaluate_strategy_params` (spawn_blocking, paper-only, off the
//! hot path), then [`select_adoption`] decides and [`format_brief`]
//! narrates. An adoption publishes `EngineEvent::ParamUpdate` (clamped
//! again by the strategy runtime on application) plus a Thought (squadron
//! "research") carrying the brief — which the palace records verbatim, so
//! every adoption is auditable end to end.
//!
//! The hard bounds below MIRROR cx-strategy's `PARAM_BOUNDS` (strat.rs) and
//! cx-sim's `RuleParams` clamps — bus-only crates cannot import each other;
//! keep the three tables in sync. The strategy runtime clamps once more on
//! application, so even a drifted mirror can never move a live parameter
//! out of bounds.

use std::collections::BTreeMap;

/// Strategy-keyed tunables, the same shape as `Config::strategy_params` and
/// `cx_sim::ParamMap`: strategy -> { key -> value }.
pub type ParamMap = BTreeMap<String, BTreeMap<String, f64>>;

/// One tunable: where it lives, its hard bounds, default, and grid step.
#[derive(Debug, Clone, Copy)]
pub struct Tunable {
    pub strategy: &'static str,
    pub key: &'static str,
    pub min: f64,
    pub max: f64,
    pub default: f64,
    pub step: f64,
}

/// The v1 tunable surface. Momentum's conviction weights are deliberately
/// left alone.
pub const TUNABLES: [Tunable; 3] = [
    Tunable {
        strategy: "meanrev_z",
        key: "z_entry",
        min: 1.5,
        max: 3.0,
        default: 2.0,
        step: 0.25,
    },
    Tunable {
        strategy: "kalman_trend",
        key: "t_entry",
        min: 1.5,
        max: 3.5,
        default: 2.0,
        step: 0.25,
    },
    Tunable {
        strategy: "breakout_d",
        key: "min_range_atr",
        min: 0.5,
        max: 1.5,
        default: 0.8,
        step: 0.1,
    },
];

/// A variant never adopts below this out-of-sample trade depth (on BOTH the
/// variant and its incumbent) ...
pub const MIN_OOS_TRADES: u32 = 10;
/// ... or below this relative OOS-expectancy edge over the incumbent.
pub const MIN_RELATIVE_EDGE: f64 = 0.20;

/// The replay depth the runner feeds cx-sim (bars per symbol) ...
pub const REPLAY_BARS: usize = 1_200;
/// ... and the OOS share of that window — the mirror of cx-sim's 70/30
/// walk-forward split (bus-only crates cannot import cx-sim; keep in sync).
pub const OOS_FRACTION: f64 = 0.30;

/// Milliseconds one OOS window spans at a given bar interval: the last
/// ~30% of the [`REPLAY_BARS`]-bar replay.
pub fn oos_span_ms(interval_ms: i64) -> i64 {
    ((REPLAY_BARS as f64 * OOS_FRACTION) as i64).saturating_mul(interval_ms.max(0))
}

/// Anti-ratchet cooldown: after an adoption, that tunable sits out until
/// the newest stored bar has advanced past `adopted_newest_ts` (the newest
/// bar ts recorded at adoption time) by at least one full OOS span — until
/// then, successive cycles would re-grade the tunable on a mostly
/// overlapping window (~70% shared data on a 6h cadence over M1 bars) and
/// ratchet its value toward one window's noise. The runner in cortexd keeps
/// the per-tunable bookkeeping; this predicate is the pure rule.
pub fn cooldown_over(adopted_newest_ts: i64, newest_ts: i64, interval_ms: i64) -> bool {
    newest_ts.saturating_sub(adopted_newest_ts) >= oos_span_ms(interval_ms)
}

/// The default recipe: every tunable at its compiled-in default.
pub fn default_params() -> ParamMap {
    let mut out = ParamMap::new();
    for t in TUNABLES {
        out.entry(t.strategy.to_string())
            .or_default()
            .insert(t.key.to_string(), t.default);
    }
    out
}

/// The defaults overlaid with the KNOWN keys of `cfg.strategy_params`,
/// clamped to the hard bounds; unknown keys and non-finite values are
/// ignored. This is the incumbent recipe cortexd starts the loop from.
pub fn seeded_params(cfg: &ParamMap) -> ParamMap {
    let mut out = default_params();
    for t in TUNABLES {
        let seeded = cfg
            .get(t.strategy)
            .and_then(|m| m.get(t.key))
            .copied()
            .filter(|v| v.is_finite());
        if let Some(v) = seeded {
            out.entry(t.strategy.to_string())
                .or_default()
                .insert(t.key.to_string(), v.clamp(t.min, t.max));
        }
    }
    out
}

/// The current (clamped) value of one tunable in a recipe.
fn value_of(params: &ParamMap, t: &Tunable) -> f64 {
    params
        .get(t.strategy)
        .and_then(|m| m.get(t.key))
        .copied()
        .filter(|v| v.is_finite())
        .map(|v| v.clamp(t.min, t.max))
        .unwrap_or(t.default)
}

/// One candidate recipe: a single param perturbed off the incumbent.
#[derive(Debug, Clone, PartialEq)]
pub struct Variant {
    pub strategy: String,
    pub key: String,
    pub value: f64,
    /// The FULL recipe: the incumbent params with this one perturbation —
    /// experiments always replay the whole current recipe plus one change.
    pub params: ParamMap,
}

/// The bounded grid: one param varied at a time, +/- one step around the
/// current value, clamped to the hard bounds; candidates that clamp back
/// onto the current value are skipped. At most 2 x TUNABLES.len() = 6
/// variants — with the (<= 3) per-strategy incumbent measurements the sim
/// budget stays <= 9 runs per cycle.
pub fn param_grid(current: &ParamMap) -> Vec<Variant> {
    let mut out = Vec::new();
    for t in &TUNABLES {
        let cur = value_of(current, t);
        for cand in [cur - t.step, cur + t.step] {
            let v = cand.clamp(t.min, t.max);
            if !v.is_finite() || (v - cur).abs() < 1e-9 {
                continue;
            }
            let mut params = current.clone();
            params
                .entry(t.strategy.to_string())
                .or_default()
                .insert(t.key.to_string(), v);
            out.push(Variant {
                strategy: t.strategy.to_string(),
                key: t.key.to_string(),
                value: v,
                params,
            });
        }
    }
    out
}

/// One measured experiment: a variant scored against ITS OWN strategy's
/// incumbent on the same data, same rules and same walk-forward split.
#[derive(Debug, Clone, PartialEq)]
pub struct Outcome {
    pub variant: Variant,
    pub oos_trades: u32,
    pub oos_expectancy: f64,
    pub incumbent_trades: u32,
    pub incumbent_expectancy: f64,
}

impl Outcome {
    /// The adoption bar: enough OOS depth on BOTH sides, finite numbers,
    /// positive variant expectancy, and more than [`MIN_RELATIVE_EDGE`]
    /// relative improvement (any positive expectancy beats a non-positive
    /// incumbent — the relative margin over a loser is unbounded).
    pub fn qualifies(&self) -> bool {
        self.oos_trades >= MIN_OOS_TRADES
            && self.incumbent_trades >= MIN_OOS_TRADES
            && self.oos_expectancy.is_finite()
            && self.incumbent_expectancy.is_finite()
            && self.oos_expectancy > 0.0
            && (self.incumbent_expectancy <= 0.0
                || self.oos_expectancy
                    > self.incumbent_expectancy * (1.0 + MIN_RELATIVE_EDGE))
    }
}

/// Rank by OOS expectancy among qualifying outcomes; None when nothing
/// clears the bar — the incumbent recipe stands. One adoption per cycle
/// (one change at a time keeps every experiment attributable).
pub fn select_adoption(outcomes: &[Outcome]) -> Option<&Outcome> {
    outcomes
        .iter()
        .filter(|o| o.qualifies())
        .max_by(|a, b| a.oos_expectancy.total_cmp(&b.oos_expectancy))
}

/// The written research brief: what was tested, the numbers, and what was
/// adopted or rejected. Rides the bus as a Thought (squadron "research"),
/// lands verbatim in the palace, and is the human-auditable record of the
/// cycle. Plain text, bounded, no secrets.
pub fn format_brief(outcomes: &[Outcome], adopted: Option<&Outcome>) -> String {
    if outcomes.is_empty() {
        return "autoresearch: no experiments this cycle — insufficient stored history for a \
                walk-forward replay; incumbent recipe stands"
            .to_string();
    }
    let bps = |x: f64| x * 10_000.0;
    let mut out = String::with_capacity(1024);
    out.push_str(
        "autoresearch cycle — bounded recipe experiments (paper replay of stored history, \
         70/30 walk-forward, ranked by OOS expectancy):\n",
    );
    for o in outcomes.iter().take(9) {
        out.push_str(&format!(
            "- {}.{} = {:.2}: OOS {:+.1}bps/trade ({} trades) vs incumbent {:+.1}bps ({} trades)\n",
            o.variant.strategy,
            o.variant.key,
            o.variant.value,
            bps(o.oos_expectancy),
            o.oos_trades,
            bps(o.incumbent_expectancy),
            o.incumbent_trades,
        ));
    }
    match adopted {
        Some(o) => out.push_str(&format!(
            "ADOPTED {}.{} = {:.2}: OOS {:+.1}bps beats incumbent {:+.1}bps by > {:.0}% relative \
             edge on {} OOS trades; ParamUpdate published (hard-clamped on application).",
            o.variant.strategy,
            o.variant.key,
            o.variant.value,
            bps(o.oos_expectancy),
            bps(o.incumbent_expectancy),
            MIN_RELATIVE_EDGE * 100.0,
            o.oos_trades,
        )),
        None => out.push_str(&format!(
            "REJECTED all variants: none cleared the adoption bar (>= {MIN_OOS_TRADES} OOS trades \
             both sides, positive OOS expectancy, > {:.0}% relative edge). Incumbent recipe stands.",
            MIN_RELATIVE_EDGE * 100.0,
        )),
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn outcome(
        strategy: &str,
        key: &str,
        value: f64,
        oos_trades: u32,
        oos_expectancy: f64,
        incumbent_trades: u32,
        incumbent_expectancy: f64,
    ) -> Outcome {
        Outcome {
            variant: Variant {
                strategy: strategy.into(),
                key: key.into(),
                value,
                params: default_params(),
            },
            oos_trades,
            oos_expectancy,
            incumbent_trades,
            incumbent_expectancy,
        }
    }

    #[test]
    fn tunables_mirror_the_strategy_bounds() {
        for t in TUNABLES {
            assert!((t.min..=t.max).contains(&t.default), "{}.{}", t.strategy, t.key);
            assert!(t.step > 0.0 && t.step.is_finite());
        }
        // The exact rails the task pinned down.
        let find = |s: &str, k: &str| TUNABLES.iter().find(|t| t.strategy == s && t.key == k).unwrap();
        let z = find("meanrev_z", "z_entry");
        assert_eq!((z.min, z.max, z.default), (1.5, 3.0, 2.0));
        let t = find("kalman_trend", "t_entry");
        assert_eq!((t.min, t.max, t.default), (1.5, 3.5, 2.0));
        let b = find("breakout_d", "min_range_atr");
        assert_eq!((b.min, b.max, b.default), (0.5, 1.5, 0.8));
    }

    #[test]
    fn grid_is_bounded_one_change_at_a_time_and_in_bounds() {
        let current = default_params();
        let grid = param_grid(&current);
        assert!(grid.len() <= 6, "grid too large: {}", grid.len());
        assert_eq!(grid.len(), 6, "all defaults sit strictly inside bounds: +/- both exist");
        for v in &grid {
            let t = TUNABLES
                .iter()
                .find(|t| t.strategy == v.strategy && t.key == v.key)
                .expect("variant names a known tunable");
            assert!((t.min..=t.max).contains(&v.value), "{v:?}");
            // Exactly ONE (strategy, key) differs from the incumbent.
            let mut diffs = 0;
            for tt in &TUNABLES {
                if (value_of(&v.params, tt) - value_of(&current, tt)).abs() > 1e-9 {
                    diffs += 1;
                }
            }
            assert_eq!(diffs, 1, "one param at a time: {v:?}");
        }
    }

    #[test]
    fn grid_skips_candidates_clamped_onto_the_boundary_value() {
        // Sit meanrev at its floor: the -step candidate clamps back onto
        // 1.5 and must be skipped; only +step survives for that tunable.
        let mut current = default_params();
        current
            .get_mut("meanrev_z")
            .unwrap()
            .insert("z_entry".into(), 1.5);
        let grid = param_grid(&current);
        let meanrev: Vec<&Variant> = grid.iter().filter(|v| v.strategy == "meanrev_z").collect();
        assert_eq!(meanrev.len(), 1, "{meanrev:?}");
        assert!((meanrev[0].value - 1.75).abs() < 1e-9);
        assert_eq!(grid.len(), 5);
    }

    #[test]
    fn seeded_params_clamp_and_ignore_junk() {
        let mut cfg = ParamMap::new();
        cfg.entry("meanrev_z".into())
            .or_default()
            .insert("z_entry".into(), 1.75);
        cfg.entry("kalman_trend".into())
            .or_default()
            .insert("t_entry".into(), 99.0); // clamped to the cap
        cfg.entry("breakout_d".into())
            .or_default()
            .insert("min_range_atr".into(), f64::NAN); // ignored
        cfg.entry("meanrev_z".into())
            .or_default()
            .insert("mystery".into(), 7.0); // unknown key ignored
        let seeded = seeded_params(&cfg);
        assert_eq!(seeded["meanrev_z"]["z_entry"], 1.75);
        assert_eq!(seeded["kalman_trend"]["t_entry"], 3.5);
        assert_eq!(seeded["breakout_d"]["min_range_atr"], 0.8);
        assert!(!seeded["meanrev_z"].contains_key("mystery"));
    }

    #[test]
    fn adoption_requires_depth_positivity_and_a_real_edge() {
        // +21% relative edge with depth on both sides: qualifies.
        assert!(outcome("meanrev_z", "z_entry", 1.75, 12, 0.00121, 15, 0.0010).qualifies());
        // +19%: below the bar.
        assert!(!outcome("meanrev_z", "z_entry", 1.75, 12, 0.00119, 15, 0.0010).qualifies());
        // Positive variant over a losing incumbent: qualifies outright.
        assert!(outcome("meanrev_z", "z_entry", 1.75, 12, 0.0002, 15, -0.0010).qualifies());
        // Negative variant never qualifies, however bad the incumbent.
        assert!(!outcome("meanrev_z", "z_entry", 1.75, 12, -0.0001, 15, -0.0100).qualifies());
        // Thin OOS samples never qualify — variant side or incumbent side.
        assert!(!outcome("meanrev_z", "z_entry", 1.75, 9, 0.0100, 15, 0.0010).qualifies());
        assert!(!outcome("meanrev_z", "z_entry", 1.75, 12, 0.0100, 9, 0.0010).qualifies());
        // Non-finite numbers never qualify.
        assert!(!outcome("meanrev_z", "z_entry", 1.75, 12, f64::NAN, 15, 0.0010).qualifies());
        assert!(!outcome("meanrev_z", "z_entry", 1.75, 12, 0.0100, 15, f64::NAN).qualifies());
    }

    #[test]
    fn select_adoption_picks_the_best_qualifier_or_none() {
        let a = outcome("meanrev_z", "z_entry", 1.75, 12, 0.0015, 15, 0.0010);
        let b = outcome("kalman_trend", "t_entry", 2.25, 14, 0.0030, 20, 0.0010);
        let c = outcome("breakout_d", "min_range_atr", 0.9, 8, 0.0400, 20, 0.0010); // thin
        let outcomes = [a.clone(), b.clone(), c];
        let picked = select_adoption(&outcomes).expect("b qualifies");
        assert_eq!(picked, &b, "highest qualifying OOS expectancy wins");
        // Nothing qualifies -> incumbent stands.
        let weak = outcome("meanrev_z", "z_entry", 1.75, 12, 0.0011, 15, 0.0010);
        assert!(select_adoption(&[weak]).is_none());
        assert!(select_adoption(&[]).is_none());
    }

    #[test]
    fn cooldown_blocks_retests_until_the_oos_window_no_longer_overlaps() {
        let m1 = 60_000i64;
        // 30% of 1200 bars = 360 bars of that interval.
        assert_eq!(oos_span_ms(m1), 360 * m1);
        let adopted_at = 1_000_000_000i64;
        // Same cycle / no data advance: still cooling.
        assert!(!cooldown_over(adopted_at, adopted_at, m1));
        // One bar short of a disjoint OOS window: still cooling.
        assert!(!cooldown_over(adopted_at, adopted_at + 359 * m1, m1));
        // A full OOS span later the windows are disjoint: eligible again.
        assert!(cooldown_over(adopted_at, adopted_at + 360 * m1, m1));
        // The span scales with the bar interval (D1 replays cool far longer).
        let d1 = 86_400_000i64;
        assert_eq!(oos_span_ms(d1), 360 * d1);
        assert!(!cooldown_over(0, 359 * d1, d1));
        assert!(cooldown_over(0, 360 * d1, d1));
        // Clocks running backwards (stale feed) never unlock early.
        assert!(!cooldown_over(adopted_at, adopted_at - m1, m1));
    }

    #[test]
    fn brief_narrates_numbers_and_the_verdict() {
        let a = outcome("meanrev_z", "z_entry", 1.75, 12, 0.0015, 15, 0.0010);
        let brief = format_brief(&[a.clone()], Some(&a));
        assert!(brief.contains("autoresearch cycle"), "{brief}");
        assert!(brief.contains("meanrev_z.z_entry = 1.75"), "{brief}");
        assert!(brief.contains("OOS +15.0bps/trade (12 trades)"), "{brief}");
        assert!(brief.contains("incumbent +10.0bps (15 trades)"), "{brief}");
        assert!(brief.contains("ADOPTED meanrev_z.z_entry = 1.75"), "{brief}");

        let brief = format_brief(&[a], None);
        assert!(brief.contains("REJECTED all variants"), "{brief}");
        assert!(brief.contains("Incumbent recipe stands"), "{brief}");

        let brief = format_brief(&[], None);
        assert!(brief.contains("no experiments this cycle"), "{brief}");
    }
}
