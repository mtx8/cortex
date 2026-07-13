//! cx-strategy — the strategy squadron: four built-in bar-driven strategies
//! plus bus-wide signal fusion.
//!
//! One runtime task reacts to COMPLETE M1 bars per configured symbol and
//! evaluates the built-ins ("momentum_x", "meanrev_z", "breakout_d",
//! "kalman_trend") over a rolling window via [`cx_ta`]. A second task fuses
//! every non-"fusion" signal on the bus — including the LLM strategist's —
//! into one `EngineEvent::Signal{strategy:"fusion"}` opinion per symbol.
//!
//! Invariants:
//! - Bus-only: this crate publishes and subscribes on [`cx_core::Bus`]; it
//!   never calls another squadron and performs no network IO.
//! - No per-bar spam: a strategy republishes only when its opinion changes
//!   materially (direction sign flip, or conviction moving > 0.15); fusion
//!   republishes only when the fused direction or conviction moves > 0.1.
//! - NaN-safe: every number that crossed the bus is validated before math;
//!   non-finite signals are dropped, never fused.
//! - Disabling a built-in silences it immediately and removes its latest
//!   signals from fusion state — disabling can only remove opinions from
//!   the fused view, never invent them.
//! - Tunable params are HARD-BOUNDED: `cfg.strategy_params` seeds and bus
//!   `ParamUpdate` events move the entry thresholds, but always clamped to
//!   the compiled-in bounds table in strat.rs — no event can push a live
//!   strategy outside its rails.

mod fusion;
mod strat;

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use cx_core::store::BarStore;
use cx_core::{Bus, Config};

/// The four built-in strategies, in evaluation order. Indices into
/// `Shared::enabled` and `SymState::last_pub` follow this array.
pub(crate) const BUILT_INS: [&str; 4] =
    ["momentum_x", "meanrev_z", "breakout_d", "kalman_trend"];

/// Sign with a dead-zone: NaN and near-zero both read 0, so a non-finite
/// direction can never fake a flip.
pub(crate) fn sgn(x: f64) -> i8 {
    if x > 1e-9 {
        1
    } else if x < -1e-9 {
        -1
    } else {
        0
    }
}

/// State shared between the runtime tasks and the [`StrategyHandle`].
pub(crate) struct Shared {
    /// Per-built-in enable flags, indexed like [`BUILT_INS`].
    pub(crate) enabled: [AtomicBool; 4],
    /// Fusion contributor book; the handle purges disabled built-ins here.
    pub(crate) fusion: Mutex<fusion::FusionBook>,
    /// Live tunable params (hard-bounded on every write; see strat.rs
    /// PARAM_BOUNDS). Same shared-state pattern as the enable flags.
    pub(crate) params: Mutex<strat::StratParams>,
}

impl Shared {
    pub(crate) fn new() -> Self {
        Self {
            enabled: [
                AtomicBool::new(true),
                AtomicBool::new(true),
                AtomicBool::new(true),
                AtomicBool::new(true),
            ],
            fusion: Mutex::new(fusion::FusionBook::default()),
            params: Mutex::new(strat::StratParams::default()),
        }
    }

    pub(crate) fn is_enabled(&self, idx: usize) -> bool {
        self.enabled[idx].load(Ordering::Relaxed)
    }

    /// Poison-proof lock (matches cx-core's lock discipline).
    pub(crate) fn lock_fusion(&self) -> MutexGuard<'_, fusion::FusionBook> {
        self.fusion.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Poison-proof lock over the live tunables.
    pub(crate) fn lock_params(&self) -> MutexGuard<'_, strat::StratParams> {
        self.params.lock().unwrap_or_else(|p| p.into_inner())
    }
}

/// Cheap shared-state handle over the strategy runtime. Owned by cortexd's
/// command loop (clones are cheap Arc copies — the AUTORESEARCH runner
/// holds one); dropping it does NOT stop the tasks (the bus does).
#[derive(Clone)]
pub struct StrategyHandle {
    shared: Arc<Shared>,
}

impl StrategyHandle {
    /// Apply one strategy's tunable params directly — the SAME clamping
    /// path bus `ParamUpdate` events take (strat.rs `PARAM_BOUNDS`):
    /// unknown keys and non-finite values are ignored with a warn,
    /// everything else is clamped to the compiled-in rails. cortexd calls
    /// this at AUTORESEARCH adoption time so an adopted recipe can never be
    /// lost to broadcast-bus lag; the published `ParamUpdate` remains on
    /// the bus purely as the audit/palace/UI record (re-applying it is
    /// idempotent).
    pub fn apply_params(&self, strategy: &str, params: &BTreeMap<String, f64>) {
        strat::apply_params(&self.shared, strategy, params, "direct");
    }

    /// Enable/disable a built-in strategy by name. Disabling silences it on
    /// the next bar and removes its latest signals from fusion state.
    /// Returns false for unknown names (only the four built-ins are known).
    pub fn set_enabled(&self, name: &str, enabled: bool) -> bool {
        let Some(idx) = BUILT_INS.iter().position(|n| *n == name) else {
            return false;
        };
        self.shared.enabled[idx].store(enabled, Ordering::Relaxed);
        if !enabled {
            self.shared.lock_fusion().remove_strategy(name);
        }
        tracing::info!(strategy = name, enabled, "strategy toggled");
        true
    }

    /// The four built-in strategy names, in evaluation order.
    pub fn names(&self) -> Vec<String> {
        BUILT_INS.iter().map(|n| n.to_string()).collect()
    }
}

/// Spawn the strategy runtime and fusion tasks; returns immediately.
///
/// Both bus subscriptions are taken BEFORE spawning so no event published
/// after `start` returns can be missed. Each strategy warms from
/// `store.recent(symbol, M1, 300)` at task startup.
pub fn start(bus: Arc<Bus>, store: Arc<BarStore>, cfg: Config) -> StrategyHandle {
    let shared = Arc::new(Shared::new());
    // Seed the tunables from the config hook (finally consumed): every
    // value is clamped to the compiled-in hard bounds, junk is ignored.
    for (strategy, kv) in &cfg.strategy_params {
        strat::apply_params(&shared, strategy, kv, "config");
    }
    let rx_strat = bus.subscribe();
    let rx_fusion = bus.subscribe();
    tokio::spawn(strat::run(
        Arc::clone(&bus),
        store,
        cfg.clone(),
        Arc::clone(&shared),
        rx_strat,
    ));
    tokio::spawn(fusion::run(bus, cfg, Arc::clone(&shared), rx_fusion));
    StrategyHandle { shared }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sgn_dead_zone_and_nan() {
        assert_eq!(sgn(1.0), 1);
        assert_eq!(sgn(-0.5), -1);
        assert_eq!(sgn(0.0), 0);
        assert_eq!(sgn(f64::NAN), 0);
        assert_eq!(sgn(1e-12), 0);
    }

    #[tokio::test]
    async fn handle_names_and_unknown_toggle() {
        let bus = Bus::new(64);
        let store = Arc::new(BarStore::new());
        let handle = start(bus, store, Config::default());
        assert_eq!(
            handle.names(),
            vec!["momentum_x", "meanrev_z", "breakout_d", "kalman_trend"]
        );
        assert!(handle.set_enabled("momentum_x", false));
        assert!(handle.set_enabled("momentum_x", true));
        assert!(!handle.set_enabled("no_such_strategy", true));
    }

    #[tokio::test]
    async fn config_strategy_params_seed_clamped() {
        let bus = Bus::new(64);
        let store = Arc::new(BarStore::new());
        let mut cfg = Config::default();
        cfg.strategy_params.insert(
            "meanrev_z".into(),
            [("z_entry".to_string(), 1.75)].into_iter().collect(),
        );
        cfg.strategy_params.insert(
            "kalman_trend".into(),
            // Out of bounds: must seed at the 3.5 cap, never raw.
            [("t_entry".to_string(), 99.0)].into_iter().collect(),
        );
        let handle = start(bus, store, cfg);
        let p = *handle.shared.lock_params();
        assert_eq!(p.meanrev_z_entry, 1.75);
        assert_eq!(p.kalman_t_entry, 3.5);
        assert_eq!(p.breakout_min_range_atr, 0.8, "untouched param keeps its default");
    }

    #[tokio::test]
    async fn apply_params_direct_path_applies_clamped_without_the_bus() {
        let bus = Bus::new(64);
        let store = Arc::new(BarStore::new());
        let handle = start(bus, store, Config::default());
        let kv = |v: f64| -> BTreeMap<String, f64> {
            [("z_entry".to_string(), v)].into_iter().collect()
        };
        // Direct = synchronous: applied before the call returns, no bus
        // round-trip to lose to lag.
        handle.apply_params("meanrev_z", &kv(1.6));
        assert_eq!(handle.shared.lock_params().meanrev_z_entry, 1.6);
        // Out-of-bounds clamps to the rail, exactly like the bus route.
        handle.apply_params("meanrev_z", &kv(99.0));
        assert_eq!(handle.shared.lock_params().meanrev_z_entry, 3.0);
        // Junk is ignored, never applied.
        handle.apply_params("meanrev_z", &kv(f64::NAN));
        assert_eq!(handle.shared.lock_params().meanrev_z_entry, 3.0);
        handle.apply_params("no_such_strategy", &kv(1.6));
        assert_eq!(handle.shared.lock_params().meanrev_z_entry, 3.0);
        // The handle clones cheaply and acts on the same shared state.
        let clone = handle.clone();
        clone.apply_params("meanrev_z", &kv(2.25));
        assert_eq!(handle.shared.lock_params().meanrev_z_entry, 2.25);
    }

    #[tokio::test]
    async fn param_update_on_the_bus_is_applied_clamped() {
        use cx_core::events::{EngineEvent, ParamUpdate};
        use std::time::Duration;

        let bus = Bus::new(256);
        let store = Arc::new(BarStore::new());
        let handle = start(Arc::clone(&bus), store, Config::default());
        assert_eq!(handle.shared.lock_params().meanrev_z_entry, 2.0);

        let update = |value: f64| {
            EngineEvent::ParamUpdate(ParamUpdate {
                strategy: "meanrev_z".into(),
                params: [("z_entry".to_string(), value)].into_iter().collect(),
                source: "autoresearch".into(),
                rationale: "test adoption".into(),
                ts_ms: 1,
            })
        };
        // In-bounds adoption applies exactly.
        bus.publish(update(1.6));
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        loop {
            if (handle.shared.lock_params().meanrev_z_entry - 1.6).abs() < 1e-12 {
                break;
            }
            assert!(
                tokio::time::Instant::now() < deadline,
                "ParamUpdate was never applied"
            );
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        // Out-of-bounds request is clamped to the hard cap, never applied raw.
        bus.publish(update(99.0));
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        loop {
            let v = handle.shared.lock_params().meanrev_z_entry;
            assert!(v <= 3.0, "out-of-bounds value leaked into a live strategy: {v}");
            if (v - 3.0).abs() < 1e-12 {
                break;
            }
            assert!(
                tokio::time::Instant::now() < deadline,
                "clamped ParamUpdate was never applied"
            );
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }
}
