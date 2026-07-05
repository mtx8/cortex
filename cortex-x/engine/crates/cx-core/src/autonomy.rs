//! The autonomy dial — how far the machine may act without a human.
//! CRITICAL safety actions (kill switch, flatten-on-breach) always bypass
//! the dial; it gates only NEW risk-taking.

use std::sync::atomic::{AtomicU8, Ordering};

use crate::types::AutonomyLevel;

#[derive(Debug)]
pub struct AutonomyDial {
    level: AtomicU8,
}

impl AutonomyDial {
    pub fn new(level: AutonomyLevel) -> Self {
        Self {
            level: AtomicU8::new(Self::encode(level)),
        }
    }

    fn encode(l: AutonomyLevel) -> u8 {
        match l {
            AutonomyLevel::Manual => 0,
            AutonomyLevel::SuggestOnly => 1,
            AutonomyLevel::SemiAuto => 2,
            AutonomyLevel::FullAuto => 3,
        }
    }

    fn decode(v: u8) -> AutonomyLevel {
        match v {
            0 => AutonomyLevel::Manual,
            1 => AutonomyLevel::SuggestOnly,
            2 => AutonomyLevel::SemiAuto,
            _ => AutonomyLevel::FullAuto,
        }
    }

    pub fn get(&self) -> AutonomyLevel {
        Self::decode(self.level.load(Ordering::SeqCst))
    }

    pub fn set(&self, level: AutonomyLevel) {
        self.level.store(Self::encode(level), Ordering::SeqCst);
    }

    /// May the engine autonomously open NEW risk of this notional?
    /// SemiAuto allows small autonomous orders; FullAuto allows all
    /// (risk checks still apply downstream, always).
    pub fn allows_auto_entry(&self, notional: f64, semi_auto_cap: f64) -> bool {
        match self.get() {
            AutonomyLevel::Manual | AutonomyLevel::SuggestOnly => false,
            AutonomyLevel::SemiAuto => notional <= semi_auto_cap,
            AutonomyLevel::FullAuto => true,
        }
    }
}

impl Default for AutonomyDial {
    fn default() -> Self {
        Self::new(AutonomyLevel::FullAuto)
    }
}
