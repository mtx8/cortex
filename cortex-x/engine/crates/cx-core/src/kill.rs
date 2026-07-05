//! Two-phase kill switch.
//!
//! Phase 1 is a synchronous, in-memory atomic checked inline by every order
//! path — no async, no locks on the read path, no network dependency, ever.
//! Phase 2 (flatten, notify, persist) is orchestrated elsewhere off the bus.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

#[derive(Debug, Default)]
pub struct KillSwitch {
    engaged: AtomicBool,
    reason: Mutex<Option<String>>,
}

impl KillSwitch {
    pub fn new() -> Self {
        Self::default()
    }

    /// Phase-1 check: lock-free, safe to call on the hottest path.
    #[inline(always)]
    pub fn is_engaged(&self) -> bool {
        self.engaged.load(Ordering::SeqCst)
    }

    /// Engage instantly. The atomic is set BEFORE the reason is recorded so
    /// no order can slip through while we hold the reason lock.
    pub fn engage(&self, reason: impl Into<String>) {
        self.engaged.store(true, Ordering::SeqCst);
        let mut guard = self.reason.lock().unwrap_or_else(|p| p.into_inner());
        *guard = Some(reason.into());
    }

    /// Disengaging is deliberate: requires a reason, returns whether the
    /// state actually changed so callers can audit-log the transition.
    pub fn disengage(&self, reason: impl Into<String>) -> bool {
        let was = self.engaged.swap(false, Ordering::SeqCst);
        let mut guard = self.reason.lock().unwrap_or_else(|p| p.into_inner());
        *guard = Some(format!("disengaged: {}", reason.into()));
        was
    }

    pub fn reason(&self) -> Option<String> {
        self.reason
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engage_is_instant_and_reasoned() {
        let ks = KillSwitch::new();
        assert!(!ks.is_engaged());
        ks.engage("drawdown breach");
        assert!(ks.is_engaged());
        assert_eq!(ks.reason().unwrap(), "drawdown breach");
        assert!(ks.disengage("operator reset"));
        assert!(!ks.is_engaged());
    }
}
