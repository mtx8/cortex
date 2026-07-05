//! Drawdown clocks: day and all-time equity peaks feeding a linear throttle.
//! The throttle begins at half the configured limit, halts new risk at the
//! limit, and past 1.25x the limit engages the kill switch — the ONLY
//! autonomous kill trigger in the engine.

use cx_core::config::RiskConfig;
use cx_core::KillSwitch;

const DAY_MS: i64 = 86_400_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DdState {
    Normal,
    Throttling,
    Halted,
    Killed,
}

#[derive(Debug)]
pub(crate) struct DrawdownClocks {
    initialized: bool,
    utc_day: i64,
    day_peak: f64,
    total_peak: f64,
    equity: f64,
    state: DdState,
}

impl DrawdownClocks {
    pub(crate) fn new() -> Self {
        Self {
            initialized: false,
            utc_day: 0,
            day_peak: 0.0,
            total_peak: 0.0,
            equity: 0.0,
            state: DdState::Normal,
        }
    }

    /// Feed one equity mark. Non-finite / non-positive equity is ignored
    /// (equity is derived from marks, which are network data). Returns a
    /// description on state transitions: throttle began, halt, kill.
    pub(crate) fn on_equity(
        &mut self,
        equity: f64,
        ts_ms: i64,
        cfg: &RiskConfig,
        kill: &KillSwitch,
    ) -> Option<String> {
        if !equity.is_finite() || equity <= 0.0 {
            return None;
        }
        let day = ts_ms.div_euclid(DAY_MS);
        if !self.initialized {
            self.initialized = true;
            self.utc_day = day;
            self.day_peak = equity;
            self.total_peak = equity;
        } else if day != self.utc_day {
            // UTC day rollover: the day clock restarts at today's equity.
            self.utc_day = day;
            self.day_peak = equity;
        }
        self.day_peak = self.day_peak.max(equity);
        self.total_peak = self.total_peak.max(equity);
        self.equity = equity;

        let day_dd = self.day_dd();
        let total_dd = self.total_dd();
        let hard_breach = day_dd > cfg.max_daily_drawdown * 1.25
            || total_dd > cfg.max_total_drawdown * 1.25;
        let t = self.throttle(cfg);
        let next = if hard_breach {
            DdState::Killed
        } else if t <= 0.0 {
            DdState::Halted
        } else if t < 1.0 {
            DdState::Throttling
        } else {
            DdState::Normal
        };
        let prev = std::mem::replace(&mut self.state, next);
        if next == prev {
            return None;
        }
        match next {
            DdState::Killed => {
                let reason = format!(
                    "drawdown hard breach: day {:.2}% / total {:.2}% (limits {:.2}% / {:.2}%)",
                    day_dd * 100.0,
                    total_dd * 100.0,
                    cfg.max_daily_drawdown * 100.0,
                    cfg.max_total_drawdown * 100.0,
                );
                tracing::warn!(target: "cx_risk", %reason, "engaging kill switch");
                kill.engage(reason.clone());
                Some(reason)
            }
            DdState::Halted => Some(format!(
                "drawdown halt: day {:.2}% / total {:.2}% — new risk blocked",
                day_dd * 100.0,
                total_dd * 100.0,
            )),
            DdState::Throttling => Some(format!(
                "drawdown throttle began: day {:.2}% / total {:.2}% (throttle {:.2})",
                day_dd * 100.0,
                total_dd * 100.0,
                t,
            )),
            DdState::Normal => None,
        }
    }

    /// 1 = unthrottled, 0 = halted. Tighter of the day / total clocks;
    /// 1 before the first equity mark.
    pub(crate) fn throttle(&self, cfg: &RiskConfig) -> f64 {
        if !self.initialized {
            return 1.0;
        }
        band_throttle(self.day_dd(), cfg.max_daily_drawdown)
            .min(band_throttle(self.total_dd(), cfg.max_total_drawdown))
    }

    pub(crate) fn breaches(&self, cfg: &RiskConfig) -> Vec<String> {
        let mut out = Vec::new();
        if !self.initialized {
            return out;
        }
        for (label, dd, limit) in [
            ("daily", self.day_dd(), cfg.max_daily_drawdown),
            ("total", self.total_dd(), cfg.max_total_drawdown),
        ] {
            if !(dd > 0.0 && limit.is_finite() && limit > 0.0) {
                continue;
            }
            if dd >= limit {
                out.push(format!(
                    "{label} drawdown {:.2}% breached limit {:.2}%",
                    dd * 100.0,
                    limit * 100.0
                ));
            } else if dd >= limit * 0.5 {
                out.push(format!(
                    "{label} drawdown {:.2}% in throttle band (limit {:.2}%)",
                    dd * 100.0,
                    limit * 100.0
                ));
            }
        }
        out
    }

    fn day_dd(&self) -> f64 {
        drawdown(self.equity, self.day_peak)
    }

    fn total_dd(&self) -> f64 {
        drawdown(self.equity, self.total_peak)
    }
}

fn drawdown(equity: f64, peak: f64) -> f64 {
    if !(equity.is_finite() && peak.is_finite()) || peak <= 0.0 {
        return 0.0;
    }
    (1.0 - equity / peak).clamp(0.0, 1.0)
}

/// Linear band: 1.0 up to limit/2, down to 0.0 at limit.
fn band_throttle(dd: f64, limit: f64) -> f64 {
    if !dd.is_finite() || dd <= 0.0 {
        return 1.0;
    }
    if !limit.is_finite() || limit <= 0.0 {
        return 0.0;
    }
    let half = limit * 0.5;
    if dd <= half {
        1.0
    } else if dd >= limit {
        0.0
    } else {
        ((limit - dd) / half).clamp(0.0, 1.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn band_edges_are_exact() {
        assert_eq!(band_throttle(0.0, 0.03), 1.0);
        assert_eq!(band_throttle(0.015, 0.03), 1.0);
        assert!((band_throttle(0.0225, 0.03) - 0.5).abs() < 1e-12);
        assert_eq!(band_throttle(0.03, 0.03), 0.0);
        assert_eq!(band_throttle(0.05, 0.03), 0.0);
        // NaN / degenerate limits fail tight.
        assert_eq!(band_throttle(f64::NAN, 0.03), 1.0);
        assert_eq!(band_throttle(0.01, f64::NAN), 0.0);
        assert_eq!(band_throttle(0.01, 0.0), 0.0);
    }

    #[test]
    fn drawdown_is_nan_safe_and_clamped() {
        assert_eq!(drawdown(90.0, 100.0), 0.09999999999999998);
        assert_eq!(drawdown(110.0, 100.0), 0.0);
        assert_eq!(drawdown(f64::NAN, 100.0), 0.0);
        assert_eq!(drawdown(90.0, 0.0), 0.0);
    }
}
