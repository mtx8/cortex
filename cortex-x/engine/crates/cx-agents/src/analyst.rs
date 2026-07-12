//! "market_analyst" (squadron "analysis") — per-symbol technical readout,
//! once per minute. Invariant: it speaks ONLY on notable state changes
//! (regime shift, RSI 30/70 crossings, Bollinger squeeze onset, vol-EWMA
//! doubling) — never a per-cycle heartbeat. Confidence is the regime
//! confidence from `cx_ta::detect_regime`.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::Arc;
use std::time::Duration;

use cx_core::events::{EngineEvent, RegimeBoard, RegimeState};
use cx_core::store::BarStore;
use cx_core::types::{Interval, Severity};
use cx_core::Bus;
use cx_ta::{compute_features, detect_regime_with, Regime};

use crate::ledger::{fin, regime_label, regime_state_label};
use crate::publish_thought;

const AGENT: &str = "market_analyst";
const SQUADRON: &str = "analysis";
const CYCLE: Duration = Duration::from_secs(60);
const LOOKBACK: usize = 120;
/// Below this many M1 bars the features are too cold to speak about.
const MIN_BARS: usize = 25;
/// Bollinger-width history per symbol (one sample per cycle).
const WIDTH_HISTORY: usize = 100;
const MIN_WIDTH_HISTORY: usize = 20;
const VOL_SPIKE_FACTOR: f64 = 2.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RsiZone {
    Oversold,
    Neutral,
    Overbought,
}

fn rsi_zone(rsi: f64) -> RsiZone {
    if rsi < 30.0 {
        RsiZone::Oversold
    } else if rsi > 70.0 {
        RsiZone::Overbought
    } else {
        RsiZone::Neutral
    }
}

#[derive(Default)]
struct SymbolMemory {
    regime: Option<Regime>,
    zone: Option<RsiZone>,
    widths: VecDeque<f64>,
    squeeze: bool,
    prev_vol: Option<f64>,
    /// Last seen REGIMES-board secular state (bus `RegimeMap`); a thought
    /// fires only when this changes, so repeats are throttled by design.
    board_state: Option<RegimeState>,
}

/// Change-detection state; pure so it is directly testable.
pub(crate) struct AnalystState {
    per: HashMap<String, SymbolMemory>,
}

impl AnalystState {
    pub fn new() -> Self {
        Self {
            per: HashMap::new(),
        }
    }

    /// Fold one observation; returns the notable-change notes (empty when
    /// nothing changed — the agent stays silent).
    pub fn observe(
        &mut self,
        symbol: &str,
        feats: &BTreeMap<String, f64>,
        regime: Regime,
    ) -> Vec<String> {
        let mem = self.per.entry(symbol.to_string()).or_default();
        let mut notes = Vec::new();

        match mem.regime {
            Some(prev) if prev == regime => {}
            Some(prev) => notes.push(format!(
                "regime shift {} -> {}",
                regime_label(prev),
                regime_label(regime)
            )),
            None => notes.push(format!("initial regime read: {}", regime_label(regime))),
        }
        mem.regime = Some(regime);

        if let Some(&rsi) = feats.get("rsi_14") {
            if rsi.is_finite() {
                let zone = rsi_zone(rsi);
                if let Some(prev) = mem.zone {
                    if prev != zone {
                        notes.push(match zone {
                            RsiZone::Oversold => {
                                format!("rsi_14 crossed below 30 ({rsi:.1}) — oversold")
                            }
                            RsiZone::Overbought => {
                                format!("rsi_14 crossed above 70 ({rsi:.1}) — overbought")
                            }
                            RsiZone::Neutral => format!("rsi_14 back to neutral ({rsi:.1})"),
                        });
                    }
                }
                mem.zone = Some(zone);
            }
        }

        if let Some(&w) = feats.get("bb_width") {
            if w.is_finite() && w >= 0.0 {
                mem.widths.push_back(w);
                if mem.widths.len() > WIDTH_HISTORY {
                    mem.widths.pop_front();
                }
                if mem.widths.len() >= MIN_WIDTH_HISTORY {
                    let mut sorted: Vec<f64> = mem.widths.iter().copied().collect();
                    sorted.sort_unstable_by(f64::total_cmp);
                    let p25 = percentile(&sorted, 0.25);
                    let p50 = percentile(&sorted, 0.50);
                    if !mem.squeeze && w < p25 {
                        mem.squeeze = true;
                        notes.push(format!(
                            "bollinger squeeze: width {w:.5} below 25th percentile ({p25:.5})"
                        ));
                    } else if mem.squeeze && w >= p50 {
                        mem.squeeze = false; // release re-arms silently
                    }
                }
            }
        }

        if let Some(&v) = feats.get("vol_ewma") {
            if v.is_finite() && v >= 0.0 {
                if let Some(prev) = mem.prev_vol {
                    if prev > 0.0 && v >= VOL_SPIKE_FACTOR * prev {
                        notes.push(format!("volatility spike: vol_ewma {prev:.3e} -> {v:.3e}"));
                    }
                }
                mem.prev_vol = Some(v);
            }
        }

        notes
    }

    /// Fold one REGIMES board; returns at most one note per CONFIGURED
    /// symbol whose secular state CHANGED (bear-side transitions are
    /// Warnings, bull-side Insights). First sight of a symbol baselines
    /// silently; an unchanged state re-published by the scanner is silent —
    /// that is the once-per-state-change throttle.
    pub fn observe_board(
        &mut self,
        board: &RegimeBoard,
        symbols: &[String],
    ) -> Vec<(String, Severity, String)> {
        let mut out = Vec::new();
        for row in &board.rows {
            if !symbols.contains(&row.symbol) {
                continue;
            }
            let mem = self.per.entry(row.symbol.clone()).or_default();
            match mem.board_state {
                Some(prev) if prev == row.state => {}
                Some(prev) => {
                    let severity = if bear_side(row.state) {
                        Severity::Warning
                    } else {
                        Severity::Insight
                    };
                    out.push((
                        row.symbol.clone(),
                        severity,
                        format!(
                            "regime board shift: {} -> {} (drawdown {:.1}%, {} days in prior state)",
                            regime_state_label(prev),
                            regime_state_label(row.state),
                            fin(row.drawdown_pct) * 100.0,
                            row.days_in_state,
                        ),
                    ));
                }
                None => {} // baseline silently; only CHANGES are notable
            }
            mem.board_state = Some(row.state);
        }
        out
    }
}

/// Bear-side secular states: transitions INTO these warrant a Warning.
fn bear_side(s: RegimeState) -> bool {
    matches!(
        s,
        RegimeState::Correction | RegimeState::EnteringBear | RegimeState::Bear
    )
}

/// Nearest-rank percentile of a sorted finite slice; 0.0 when empty.
fn percentile(sorted: &[f64], q: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let idx = ((sorted.len() - 1) as f64 * q.clamp(0.0, 1.0)).round() as usize;
    sorted[idx.min(sorted.len() - 1)]
}

pub(crate) fn spawn(bus: Arc<Bus>, store: Arc<BarStore>, symbols: Vec<String>) {
    // Subscribe synchronously (same rule as the ledger): no RegimeMap
    // published after `start` returns can be missed by racing the spawn.
    let mut rx = bus.subscribe();
    tokio::spawn(async move {
        let mut state = AnalystState::new();
        let mut iv = tokio::time::interval(CYCLE);
        iv.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                _ = iv.tick() => {
                    for sym in &symbols {
                        let bars = store.recent(sym, Interval::M1, LOOKBACK);
                        if bars.len() < MIN_BARS {
                            continue;
                        }
                        // Single indicator pass: regime reuses the features.
                        let feats = compute_features(&bars);
                        let (regime, conf) = detect_regime_with(&feats, &bars);
                        for note in state.observe(sym, &feats, regime) {
                            publish_thought(
                                &bus,
                                AGENT,
                                SQUADRON,
                                Severity::Insight,
                                Some(sym.clone()),
                                conf,
                                note,
                            );
                        }
                    }
                }
                ev = rx.recv() => match ev {
                    Ok(ev) => {
                        if let EngineEvent::RegimeMap(board) = ev.as_ref() {
                            for (sym, severity, note) in state.observe_board(board, &symbols) {
                                publish_thought(
                                    &bus,
                                    AGENT,
                                    SQUADRON,
                                    severity,
                                    Some(sym),
                                    0.8,
                                    note,
                                );
                            }
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                },
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feats(pairs: &[(&str, f64)]) -> BTreeMap<String, f64> {
        pairs.iter().map(|(k, v)| (k.to_string(), *v)).collect()
    }

    #[test]
    fn regime_change_notes_once() {
        let mut st = AnalystState::new();
        let empty = feats(&[]);
        let first = st.observe("BTC-USD", &empty, Regime::Ranging);
        assert_eq!(first.len(), 1);
        assert!(first[0].contains("initial regime"));
        assert!(st.observe("BTC-USD", &empty, Regime::Ranging).is_empty());
        let shift = st.observe("BTC-USD", &empty, Regime::TrendingUp);
        assert_eq!(shift.len(), 1);
        assert!(shift[0].contains("ranging -> trending_up"));
    }

    #[test]
    fn rsi_zone_crossings_note_on_transition_only() {
        let mut st = AnalystState::new();
        st.observe("X", &feats(&[("rsi_14", 50.0)]), Regime::Ranging); // initial regime note
        let n = st.observe("X", &feats(&[("rsi_14", 25.0)]), Regime::Ranging);
        assert!(n.iter().any(|s| s.contains("below 30")));
        assert!(st
            .observe("X", &feats(&[("rsi_14", 28.0)]), Regime::Ranging)
            .is_empty());
        let n = st.observe("X", &feats(&[("rsi_14", 55.0)]), Regime::Ranging);
        assert!(n.iter().any(|s| s.contains("back to neutral")));
        let n = st.observe("X", &feats(&[("rsi_14", 75.0)]), Regime::Ranging);
        assert!(n.iter().any(|s| s.contains("above 70")));
    }

    #[test]
    fn squeeze_fires_once_until_released() {
        let mut st = AnalystState::new();
        st.observe("X", &feats(&[("bb_width", 1.0)]), Regime::Ranging); // initial note
        for _ in 0..24 {
            assert!(st
                .observe("X", &feats(&[("bb_width", 1.0)]), Regime::Ranging)
                .is_empty());
        }
        let n = st.observe("X", &feats(&[("bb_width", 0.4)]), Regime::Ranging);
        assert!(n.iter().any(|s| s.contains("squeeze")), "got {n:?}");
        // Still squeezed: silent.
        assert!(st
            .observe("X", &feats(&[("bb_width", 0.4)]), Regime::Ranging)
            .is_empty());
    }

    fn board(rows: &[(&str, RegimeState, f64)]) -> RegimeBoard {
        use cx_core::events::{Breadth, RegimeRow};
        RegimeBoard {
            rows: rows
                .iter()
                .map(|(sym, state, dd)| RegimeRow {
                    symbol: sym.to_string(),
                    state: *state,
                    drawdown_pct: *dd,
                    runup_pct: 0.0,
                    days_in_state: 3,
                    dist_50_200_pct: None,
                    last_close: 100.0,
                })
                .collect(),
            breadth: Breadth {
                pct_above_200d: Some(50.0),
                pct_above_50d: Some(50.0),
                bulls: 1,
                bears: 1,
                entering_bull: 0,
                entering_bear: 0,
                universe_size: 2,
            },
            source: "test".into(),
            ts_ms: 0,
        }
    }

    #[test]
    fn board_transition_fires_once_and_throttles() {
        let mut st = AnalystState::new();
        let syms = vec!["BTC-USD".to_string()];
        // First sight baselines silently.
        let b = board(&[("BTC-USD", RegimeState::Correction, 0.11)]);
        assert!(st.observe_board(&b, &syms).is_empty());
        // Bear-side transition -> exactly one Warning.
        let b = board(&[("BTC-USD", RegimeState::EnteringBear, 0.21)]);
        let notes = st.observe_board(&b, &syms);
        assert_eq!(notes.len(), 1);
        assert_eq!(notes[0].0, "BTC-USD");
        assert_eq!(notes[0].1, Severity::Warning);
        assert!(
            notes[0].2.contains("correction -> entering_bear"),
            "got {}",
            notes[0].2
        );
        assert!(notes[0].2.contains("21.0%"), "got {}", notes[0].2);
        // Same state re-published by the scanner: throttled, silent.
        assert!(st.observe_board(&b, &syms).is_empty());
        assert!(st.observe_board(&b, &syms).is_empty());
        // Bull-side transition -> Insight.
        let b = board(&[("BTC-USD", RegimeState::Recovery, 0.15)]);
        let notes = st.observe_board(&b, &syms);
        assert_eq!(notes.len(), 1);
        assert_eq!(notes[0].1, Severity::Insight);
        assert!(
            notes[0].2.contains("entering_bear -> recovery"),
            "got {}",
            notes[0].2
        );
    }

    #[test]
    fn board_ignores_unconfigured_symbols() {
        let mut st = AnalystState::new();
        let syms = vec!["BTC-USD".to_string()];
        let b = board(&[("DOGE-USD", RegimeState::Bull, 0.0)]);
        assert!(st.observe_board(&b, &syms).is_empty());
        let b = board(&[("DOGE-USD", RegimeState::Bear, 0.5)]);
        assert!(
            st.observe_board(&b, &syms).is_empty(),
            "unconfigured symbol must never note"
        );
    }

    #[test]
    fn vol_spike_on_doubling() {
        let mut st = AnalystState::new();
        st.observe("X", &feats(&[("vol_ewma", 1e-6)]), Regime::Ranging); // initial note
        assert!(st
            .observe("X", &feats(&[("vol_ewma", 1.5e-6)]), Regime::Ranging)
            .is_empty());
        let n = st.observe("X", &feats(&[("vol_ewma", 3.2e-6)]), Regime::Ranging);
        assert!(n.iter().any(|s| s.contains("volatility spike")), "got {n:?}");
    }
}
