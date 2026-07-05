//! "execution_auditor" (squadron "execution") — per-fill slippage audit.
//! Slippage is signed adverse-positive by side: a buy above the last price
//! and a sell below it both read positive. Fills without a known last price
//! are skipped (never a made-up benchmark). Invariant: commentary only —
//! the auditor never touches orders.

use std::collections::HashMap;
use std::sync::Arc;

use cx_core::events::{EngineEvent, Fill};
use cx_core::types::Severity;
use cx_core::Bus;

use crate::ledger::{fmt_qty, ContextLedger};
use crate::publish_thought;

const AGENT: &str = "execution_auditor";
const SQUADRON: &str = "execution";
const WARN_BPS: f64 = 10.0;

struct SlipStat {
    count: u64,
    mean: f64,
}

/// Pure per-fill audit state; the async task is a thin bus shim around it.
pub(crate) struct AuditorState {
    stats: HashMap<String, SlipStat>,
}

impl AuditorState {
    pub fn new() -> Self {
        Self {
            stats: HashMap::new(),
        }
    }

    /// Audit one fill against the ledger's last price. Returns the note and
    /// its severity, or `None` when no sane benchmark exists.
    pub fn on_fill(&mut self, fill: &Fill, last_price: Option<f64>) -> Option<(String, Severity)> {
        let last = last_price?;
        if !(last.is_finite() && last > 0.0 && fill.px.is_finite() && fill.px > 0.0) {
            return None;
        }
        // Adverse-positive: raw move against the trade direction.
        let slip = 10_000.0 * (fill.px - last) / last * fill.side.sign();
        if !slip.is_finite() {
            return None;
        }
        let stat = self
            .stats
            .entry(fill.symbol.clone())
            .or_insert(SlipStat { count: 0, mean: 0.0 });
        stat.count += 1;
        stat.mean += (slip - stat.mean) / stat.count as f64;

        let severity = if slip > WARN_BPS {
            Severity::Warning
        } else {
            Severity::Info
        };
        let side = match fill.side {
            cx_core::types::Side::Buy => "buy",
            cx_core::types::Side::Sell => "sell",
        };
        let text = format!(
            "filled {side} {} {} @ {:.2}, slippage {slip:.1}bps, avg {:.1}bps",
            fmt_qty(fill.qty),
            fill.symbol,
            fill.px,
            stat.mean,
        );
        Some((text, severity))
    }
}

pub(crate) fn spawn(bus: Arc<Bus>, ledger: Arc<ContextLedger>) {
    let mut rx = bus.subscribe();
    tokio::spawn(async move {
        let mut state = AuditorState::new();
        loop {
            match rx.recv().await {
                Ok(ev) => {
                    if let EngineEvent::Fill(f) = &*ev {
                        if let Some((text, severity)) =
                            state.on_fill(f, ledger.last_price(&f.symbol))
                        {
                            publish_thought(
                                &bus,
                                AGENT,
                                SQUADRON,
                                severity,
                                Some(f.symbol.clone()),
                                0.9,
                                text,
                            );
                        }
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
    use cx_core::types::{Liquidity, Side, Venue};

    fn fill(side: Side, px: f64) -> Fill {
        Fill {
            order_id: 1,
            symbol: "BTC-USD".into(),
            side,
            qty: 0.5,
            px,
            fee: 0.0,
            liquidity: Liquidity::Taker,
            venue: Venue::Paper,
            ts_ms: 0,
        }
    }

    #[test]
    fn slippage_is_adverse_positive_by_side() {
        let mut st = AuditorState::new();
        // Buy 12bps above last: adverse, warning.
        let (text, sev) = st.on_fill(&fill(Side::Buy, 100.12), Some(100.0)).unwrap();
        assert_eq!(sev, Severity::Warning);
        assert!(text.contains("slippage 12.0bps"), "got: {text}");
        assert!(text.contains("filled buy 0.5 BTC-USD @ 100.12"), "got: {text}");
        // Sell 10bps below last: adverse-positive but not > 10 -> info.
        let (text, sev) = st.on_fill(&fill(Side::Sell, 99.90), Some(100.0)).unwrap();
        assert_eq!(sev, Severity::Info);
        assert!(text.contains("slippage 10.0bps"), "got: {text}");
        // Buy below last: favorable -> negative.
        let (text, sev) = st.on_fill(&fill(Side::Buy, 99.90), Some(100.0)).unwrap();
        assert_eq!(sev, Severity::Info);
        assert!(text.contains("slippage -10.0bps"), "got: {text}");
    }

    #[test]
    fn running_mean_tracks_per_symbol() {
        let mut st = AuditorState::new();
        let (t1, _) = st.on_fill(&fill(Side::Buy, 100.12), Some(100.0)).unwrap();
        assert!(t1.contains("avg 12.0bps"), "got: {t1}");
        let (t2, _) = st.on_fill(&fill(Side::Buy, 100.04), Some(100.0)).unwrap();
        assert!(t2.contains("avg 8.0bps"), "got: {t2}");
        // A different symbol starts its own mean.
        let mut other = fill(Side::Buy, 100.02);
        other.symbol = "ETH-USD".into();
        let (t3, _) = st.on_fill(&other, Some(100.0)).unwrap();
        assert!(t3.contains("avg 2.0bps"), "got: {t3}");
    }

    #[test]
    fn skips_without_a_sane_benchmark() {
        let mut st = AuditorState::new();
        assert!(st.on_fill(&fill(Side::Buy, 100.0), None).is_none());
        assert!(st.on_fill(&fill(Side::Buy, 100.0), Some(f64::NAN)).is_none());
        assert!(st.on_fill(&fill(Side::Buy, 100.0), Some(0.0)).is_none());
        assert!(st
            .on_fill(&fill(Side::Buy, f64::INFINITY), Some(100.0))
            .is_none());
    }
}
