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

mod fusion;
mod strat;

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
        }
    }

    pub(crate) fn is_enabled(&self, idx: usize) -> bool {
        self.enabled[idx].load(Ordering::Relaxed)
    }

    /// Poison-proof lock (matches cx-core's lock discipline).
    pub(crate) fn lock_fusion(&self) -> MutexGuard<'_, fusion::FusionBook> {
        self.fusion.lock().unwrap_or_else(|p| p.into_inner())
    }
}

/// Cheap shared-state handle over the strategy runtime. Owned by cortexd's
/// command loop; dropping it does NOT stop the tasks (the bus does).
pub struct StrategyHandle {
    shared: Arc<Shared>,
}

impl StrategyHandle {
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
}
