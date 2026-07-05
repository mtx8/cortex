//! "risk_officer" (squadron "risk") — bus-driven guardrails commentary plus
//! tighten-only caution requests. Invariants:
//! - Every caution it publishes can only SHRINK sizing downstream (the risk
//!   engine's CautionBook enforces the tighten-only rule).
//! - Each alert fires once per transition: drawdown warnings re-arm only
//!   after the drawdown recedes; synthetic-fallback caution fires only when
//!   a feed ENTERS SyntheticFallback; high-vol caution is throttled to once
//!   per 10 minutes per symbol.

use std::collections::HashMap;
use std::sync::Arc;

use cx_core::events::{
    AccountSnapshot, AgentThought, CautionUpdate, EngineEvent, FeedHealth, FeedStatus,
};
use cx_core::store::BarStore;
use cx_core::time::now_ms;
use cx_core::types::{Interval, Severity};
use cx_core::Bus;
use cx_ta::{detect_regime, Regime};

const AGENT: &str = "risk_officer";
const SQUADRON: &str = "risk";
const SYNTHETIC_CAUTION: f64 = 0.30;
const HIGH_VOL_CAUTION: f64 = 0.25;
const HIGH_VOL_THROTTLE_MS: i64 = 600_000;
const LOOKBACK: usize = 120;
const MIN_BARS: usize = 30;

/// Pure transition logic; the async task is a thin bus shim around it.
pub(crate) struct RiskOfficerState {
    /// Warn when day drawdown exceeds half the configured daily limit.
    dd_warn_at: f64,
    dd_alerted: bool,
    feed_health: HashMap<String, FeedHealth>,
    regimes: HashMap<String, Regime>,
    last_highvol_ms: HashMap<String, i64>,
}

impl RiskOfficerState {
    pub fn new(max_daily_drawdown: f64) -> Self {
        let limit = if max_daily_drawdown.is_finite() && max_daily_drawdown > 0.0 {
            max_daily_drawdown
        } else {
            0.03
        };
        Self {
            dd_warn_at: limit * 0.5,
            dd_alerted: false,
            feed_health: HashMap::new(),
            regimes: HashMap::new(),
            last_highvol_ms: HashMap::new(),
        }
    }

    /// Day-drawdown watch: one warning per crossing, re-armed on recovery.
    pub fn on_account(&mut self, a: &AccountSnapshot) -> Vec<EngineEvent> {
        let dd = if a.drawdown_day.is_finite() {
            a.drawdown_day
        } else {
            0.0
        };
        let mut out = Vec::new();
        if dd > self.dd_warn_at {
            if !self.dd_alerted {
                self.dd_alerted = true;
                out.push(thought(
                    Severity::Warning,
                    None,
                    format!(
                        "day drawdown {:.2}% has crossed half the daily limit ({:.2}%) — new risk will throttle",
                        dd * 100.0,
                        self.dd_warn_at * 100.0
                    ),
                ));
            }
        } else {
            self.dd_alerted = false;
        }
        out
    }

    /// Synthetic-fallback watch: caution 0.30 once per transition INTO
    /// SyntheticFallback, per feed.
    pub fn on_feed(&mut self, fs: &FeedStatus) -> Vec<EngineEvent> {
        let prev = self.feed_health.insert(fs.feed.clone(), fs.health.clone());
        let mut out = Vec::new();
        if fs.health == FeedHealth::SyntheticFallback
            && prev != Some(FeedHealth::SyntheticFallback)
        {
            out.push(EngineEvent::Caution(CautionUpdate {
                scope: None,
                value: SYNTHETIC_CAUTION,
                reason: "market data degraded to synthetic".into(),
                agent: AGENT.into(),
                ts_ms: now_ms(),
            }));
            out.push(thought(
                Severity::Warning,
                None,
                format!(
                    "feed '{}' degraded to synthetic fallback — requested global caution {:.2}",
                    fs.feed, SYNTHETIC_CAUTION
                ),
            ));
        }
        out
    }

    /// High-vol regime watch: caution 0.25 when a symbol FLIPS into HighVol,
    /// throttled to once per 10 minutes per symbol.
    pub fn on_regime(&mut self, symbol: &str, regime: Regime, now: i64) -> Vec<EngineEvent> {
        let prev = self.regimes.insert(symbol.to_string(), regime);
        let mut out = Vec::new();
        if regime == Regime::HighVol && prev != Some(Regime::HighVol) {
            let last = self
                .last_highvol_ms
                .get(symbol)
                .copied()
                .unwrap_or(i64::MIN);
            if now.saturating_sub(last) >= HIGH_VOL_THROTTLE_MS {
                self.last_highvol_ms.insert(symbol.to_string(), now);
                out.push(EngineEvent::Caution(CautionUpdate {
                    scope: Some(symbol.to_string()),
                    value: HIGH_VOL_CAUTION,
                    reason: "high-volatility regime".into(),
                    agent: AGENT.into(),
                    ts_ms: now,
                }));
                out.push(thought(
                    Severity::Warning,
                    Some(symbol.to_string()),
                    format!(
                        "{symbol} flipped into high-volatility regime — requested caution {HIGH_VOL_CAUTION:.2} on the symbol"
                    ),
                ));
            }
        }
        out
    }
}

fn thought(severity: Severity, symbol: Option<String>, text: String) -> EngineEvent {
    EngineEvent::Thought(AgentThought {
        agent: AGENT.into(),
        squadron: SQUADRON.into(),
        severity,
        text,
        tags: vec![AGENT.into()],
        confidence: 0.9,
        symbol,
        ts_ms: now_ms(),
    })
}

pub(crate) fn spawn(bus: Arc<Bus>, store: Arc<BarStore>, max_daily_drawdown: f64) {
    let mut rx = bus.subscribe();
    tokio::spawn(async move {
        let mut state = RiskOfficerState::new(max_daily_drawdown);
        loop {
            match rx.recv().await {
                Ok(ev) => {
                    let outs = match &*ev {
                        EngineEvent::Account(a) => state.on_account(a),
                        EngineEvent::FeedStatus(fs) => state.on_feed(fs),
                        EngineEvent::Bar(b) if b.complete && b.interval == Interval::M1 => {
                            let bars = store.recent(&b.symbol, Interval::M1, LOOKBACK);
                            if bars.len() >= MIN_BARS {
                                let (regime, _) = detect_regime(&bars);
                                state.on_regime(&b.symbol, regime, now_ms())
                            } else {
                                Vec::new()
                            }
                        }
                        _ => Vec::new(),
                    };
                    for e in outs {
                        bus.publish(e);
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(_) => break,
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed(health: FeedHealth) -> FeedStatus {
        FeedStatus {
            feed: "coinbase".into(),
            health,
            detail: String::new(),
            ts_ms: 0,
        }
    }

    fn caution_count(evs: &[EngineEvent]) -> usize {
        evs.iter()
            .filter(|e| matches!(e, EngineEvent::Caution(_)))
            .count()
    }

    #[test]
    fn synthetic_fallback_caution_fires_once_per_transition() {
        let mut st = RiskOfficerState::new(0.03);
        // Live -> nothing.
        assert!(st.on_feed(&feed(FeedHealth::Live)).is_empty());
        // Enter fallback -> caution + warning thought.
        let out = st.on_feed(&feed(FeedHealth::SyntheticFallback));
        assert_eq!(caution_count(&out), 1);
        match &out[0] {
            EngineEvent::Caution(c) => {
                assert_eq!(c.scope, None);
                assert!((c.value - 0.30).abs() < 1e-12);
                assert_eq!(c.reason, "market data degraded to synthetic");
                assert_eq!(c.agent, "risk_officer");
            }
            other => panic!("expected caution first, got {other:?}"),
        }
        // Still in fallback -> silence.
        assert!(st.on_feed(&feed(FeedHealth::SyntheticFallback)).is_empty());
        // Recover, then degrade again -> caution again (new transition).
        assert!(st.on_feed(&feed(FeedHealth::Live)).is_empty());
        let again = st.on_feed(&feed(FeedHealth::SyntheticFallback));
        assert_eq!(caution_count(&again), 1);
    }

    #[test]
    fn drawdown_warning_once_per_crossing() {
        let mut st = RiskOfficerState::new(0.03);
        let acct = |dd: f64| AccountSnapshot {
            equity: 100_000.0,
            cash: 100_000.0,
            gross_exposure: 0.0,
            net_exposure: 0.0,
            unrealized_pnl: 0.0,
            realized_pnl_day: 0.0,
            fees_paid: 0.0,
            open_orders: 0,
            daily_trades: 0,
            drawdown_day: dd,
            drawdown_total: dd,
            ts_ms: 0,
        };
        assert!(st.on_account(&acct(0.010)).is_empty());
        assert_eq!(st.on_account(&acct(0.016)).len(), 1); // crossed 1.5%
        assert!(st.on_account(&acct(0.020)).is_empty()); // still above: silent
        assert!(st.on_account(&acct(0.010)).is_empty()); // recovered: re-armed
        assert_eq!(st.on_account(&acct(0.018)).len(), 1); // crossed again
        assert!(st.on_account(&acct(f64::NAN)).is_empty()); // NaN-safe
    }

    #[test]
    fn high_vol_caution_throttled_to_ten_minutes() {
        let mut st = RiskOfficerState::new(0.03);
        // First flip fires.
        let out = st.on_regime("BTC-USD", Regime::HighVol, 0);
        assert_eq!(caution_count(&out), 1);
        match &out[0] {
            EngineEvent::Caution(c) => {
                assert_eq!(c.scope.as_deref(), Some("BTC-USD"));
                assert!((c.value - 0.25).abs() < 1e-12);
            }
            other => panic!("expected caution, got {other:?}"),
        }
        // Stays HighVol -> no re-fire.
        assert!(st.on_regime("BTC-USD", Regime::HighVol, 1_000).is_empty());
        // Flips out and back within 10 min -> throttled.
        assert!(st.on_regime("BTC-USD", Regime::Ranging, 2_000).is_empty());
        assert!(st.on_regime("BTC-USD", Regime::HighVol, 3_000).is_empty());
        // Flips out and back after 10 min -> fires again.
        assert!(st.on_regime("BTC-USD", Regime::Ranging, 650_000).is_empty());
        let again = st.on_regime("BTC-USD", Regime::HighVol, 700_000);
        assert_eq!(caution_count(&again), 1);
        // Independent symbol throttles independently.
        let eth = st.on_regime("ETH-USD", Regime::HighVol, 700_500);
        assert_eq!(caution_count(&eth), 1);
    }
}
