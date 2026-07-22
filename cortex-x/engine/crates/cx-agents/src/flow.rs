//! The FLOW desk ("desk-flow") — a single bus-driven task (same shape as
//! [`crate::analyst`] / [`crate::desks`]) that turns Level-2 depth
//! ([`BookDepth`]) + the Time&Sales tape ([`TapePrint`]) + recent bars into a
//! live order-flow read:
//! - It maintains rolling depth/tape/sample state PER the actively-subscribed
//!   depth symbol (depth is bandwidth-bounded to one symbol; the newest
//!   [`EngineEvent::Depth`] defines the active symbol and a switch resets the
//!   rolling state). Tape prints for any other symbol are ignored.
//! - On each depth/tape update it recomputes a [`FlowRead`] (throttled to
//!   ~2/s) using the pure math in [`crate::flow_calc`] and publishes
//!   [`EngineEvent::Flow`]. Memory is bounded (tape/sample/ask-depth rings).
//! - It emits THROTTLED [`AgentThought`]s (squadron "desk-flow") only on
//!   notable TRANSITIONS — pressure flip, absorption onset, a sweep, an
//!   exhaustion/divergence, squeeze dynamics — never a per-recompute heartbeat.
//! - It emits at most ADVISORY [`StrategySignal`]s (strategy "desk-flow",
//!   conviction <= 0.4), only on the transition ENTRY. On delayed/equity data
//!   (`is_live == false`) the read is labelled not-live and convictions are
//!   further halved.
//!
//! HONESTY: these are probabilistic microstructure edges — "elevated reversal
//! risk", never "crash coming". "squeeze_dynamics" is squeeze BEHAVIOR in the
//! tape (thinning offers + accelerating up-delta + rising price), NOT a
//! short-interest prediction; short interest is not present in Level-2 data.

use std::collections::VecDeque;
use std::sync::Arc;

use cx_core::events::{
    AgentThought, Bar, BookDepth, EngineEvent, FlowRead, StrategySignal, TapePrint,
};
use cx_core::store::BarStore;
use cx_core::time::now_ms;
use cx_core::types::{Interval, Severity, Side};
use cx_core::Bus;
use cx_ta::detect_regime;

use crate::flow_calc::{
    classify_pressure, delta_rate, detect_absorption, detect_divergence, detect_squeeze_dynamics,
    detect_sweep, gross_rate, order_book_imbalance, signed_size, sum_top_sizes, window_delta,
    BookSide, DeltaSample, Divergence, Pressure,
};
use crate::ledger::{fmt_px, regime_label, snip};

const DESK: &str = "desk-flow";

/// Publish cadence: at most one [`FlowRead`] per this interval (~2/s).
const RECOMPUTE_MIN_MS: i64 = 500;
const DAY_MS: i64 = 86_400_000;
/// Recent M1 bars pulled for the narrative regime context.
const LOOKBACK: usize = 120;
const MIN_BARS: usize = 25;

// --- book / imbalance --------------------------------------------------------
/// Top-N levels per side that feed the depth-weighted OBI + squeeze ask-depth.
const OBI_TOP_N: usize = 10;
/// OBI neutral zone for the pressure classifier.
const OBI_BAND: f64 = 0.15;

// --- tape windows ------------------------------------------------------------
/// Hard cap on retained prints (bounded memory).
const MAX_TAPE: usize = 800;
/// Tape older than this (vs the newest print) is dropped.
const TAPE_KEEP_MS: i64 = 60_000;
/// Delta-velocity / pressure window.
const RATE_WINDOW_MS: i64 = 3_000;
/// |delta_rate| must exceed this FRACTION of the gross traded rate to vote
/// directionally — a symbol-agnostic epsilon.
const RATE_EPS_FRAC: f64 = 0.15;

// --- absorption --------------------------------------------------------------
const ABSORB_WINDOW_MS: i64 = 10_000;
/// |price move| over the window must stay within this for "flat".
const ABSORB_FLAT_PCT: f64 = 0.0008;
const ABSORB_DOMINANCE: f64 = 0.70;
const ABSORB_MIN_PRINTS: usize = 8;

// --- sweep -------------------------------------------------------------------
const SWEEP_WINDOW_MS: i64 = 1_500;
const SWEEP_MIN_LEVELS: usize = 4;
const SWEEP_MIN_PRINTS: usize = 4;
const SWEEP_DOMINANCE: f64 = 0.80;

// --- divergence --------------------------------------------------------------
/// A new price extreme must clear the prior one by at least this fraction.
const DIVERGENCE_FRAC: f64 = 0.0015;
const MAX_SAMPLES: usize = 120;

// --- squeeze dynamics --------------------------------------------------------
/// Offers "thinning" when top-N ask size falls below this fraction of its
/// recent median.
const SQUEEZE_THIN_FRAC: f64 = 0.6;
const MAX_ASK_HIST: usize = 120;
const MIN_ASK_HIST: usize = 10;

// --- advisory signals (all <= 0.4; halved when the feed is not live) --------
const CONV_SQUEEZE: f64 = 0.35;
const CONV_DIVERGENCE: f64 = 0.30;
const CONV_SWEEP: f64 = 0.28;
const CONV_ABSORPTION: f64 = 0.22;
const CONV_CAP: f64 = 0.40;

const MAX_FLAGS: usize = 6;

fn thought(severity: Severity, symbol: String, confidence: f64, text: String) -> EngineEvent {
    EngineEvent::Thought(AgentThought {
        agent: DESK.into(),
        squadron: DESK.into(),
        severity,
        text,
        tags: vec![DESK.into()],
        confidence: if confidence.is_finite() {
            confidence.clamp(0.0, 1.0)
        } else {
            0.5
        },
        symbol: Some(symbol),
        ts_ms: now_ms(),
    })
}

fn advisory(symbol: String, direction: f64, conviction: f64, rationale: String) -> EngineEvent {
    EngineEvent::Signal(StrategySignal {
        strategy: DESK.into(),
        symbol,
        direction: direction.clamp(-1.0, 1.0),
        conviction: conviction.clamp(0.0, CONV_CAP),
        rationale,
        features: Default::default(),
        ts_ms: now_ms(),
    })
}

fn side_word(s: Side) -> &'static str {
    match s {
        Side::Buy => "buy",
        Side::Sell => "sell",
    }
}

/// Median of a slice (nearest-rank on the sorted copy); 0.0 when empty.
fn median(xs: &[f64]) -> f64 {
    let mut v: Vec<f64> = xs.iter().copied().filter(|x| x.is_finite()).collect();
    if v.is_empty() {
        return 0.0;
    }
    v.sort_by(f64::total_cmp);
    v[v.len() / 2]
}

/// The FLOW desk's change-detection state; pure so it is directly testable (a
/// [`BarStore`] is plain in-memory state, and `recompute` takes a bar slice).
pub(crate) struct FlowDesk {
    /// The actively-subscribed depth symbol (set by the newest Depth event).
    active: Option<String>,
    depth: Option<BookDepth>,
    tape: VecDeque<TapePrint>,
    /// Session cumulative volume delta (reset on UTC-day roll / symbol switch).
    cum_delta: f64,
    session_day: i64,
    /// (price, cum_delta) ring for the divergence detector.
    samples: VecDeque<DeltaSample>,
    /// Top-N ask-size ring for the squeeze "thinning offers" reference.
    ask_hist: VecDeque<f64>,
    prev_delta_rate: Option<f64>,
    prev_px: Option<f64>,
    last_publish_ms: Option<i64>,
    // transition latches — a thought/signal fires on ENTRY, re-arms on exit.
    last_pressure: Option<Pressure>,
    absorption_latch: Option<BookSide>,
    sweep_latch: bool,
    divergence_latch: bool,
    squeeze_latch: bool,
}

impl FlowDesk {
    pub fn new() -> Self {
        Self {
            active: None,
            depth: None,
            tape: VecDeque::new(),
            cum_delta: 0.0,
            session_day: i64::MIN,
            samples: VecDeque::new(),
            ask_hist: VecDeque::new(),
            prev_delta_rate: None,
            prev_px: None,
            last_publish_ms: None,
            last_pressure: None,
            absorption_latch: None,
            sweep_latch: false,
            divergence_latch: false,
            squeeze_latch: false,
        }
    }

    /// Ingest a depth snapshot. A book for a NEW symbol switches the active
    /// symbol and resets every rolling ring (depth is one-symbol-at-a-time).
    pub fn on_depth(&mut self, depth: BookDepth) {
        if self.active.as_deref() != Some(depth.symbol.as_str()) {
            self.reset_for(&depth);
        }
        self.depth = Some(depth);
    }

    /// Ingest one tape print. Only the active symbol's tape moves the desk;
    /// the running cumulative delta resets on the UTC-day boundary.
    pub fn on_tape(&mut self, print: TapePrint) {
        if self.active.as_deref() != Some(print.symbol.as_str()) {
            return;
        }
        let day = print.ts_ms.div_euclid(DAY_MS);
        if self.session_day != day {
            self.session_day = day;
            self.cum_delta = 0.0;
            self.samples.clear();
        }
        self.cum_delta += signed_size(&print);
        self.tape.push_back(print);
        self.trim_tape();
    }

    fn reset_for(&mut self, depth: &BookDepth) {
        self.active = Some(depth.symbol.clone());
        self.tape.clear();
        self.cum_delta = 0.0;
        self.session_day = depth.ts_ms.div_euclid(DAY_MS);
        self.samples.clear();
        self.ask_hist.clear();
        self.prev_delta_rate = None;
        self.prev_px = None;
        self.last_pressure = None;
        self.absorption_latch = None;
        self.sweep_latch = false;
        self.divergence_latch = false;
        self.squeeze_latch = false;
    }

    fn trim_tape(&mut self) {
        while self.tape.len() > MAX_TAPE {
            self.tape.pop_front();
        }
        let newest = match self.tape.back() {
            Some(p) => p.ts_ms,
            None => return,
        };
        let cutoff = newest - TAPE_KEEP_MS;
        while let Some(front) = self.tape.front() {
            if front.ts_ms < cutoff {
                self.tape.pop_front();
            } else {
                break;
            }
        }
    }

    /// Recompute the read from the current depth + tape + `bars`. Returns the
    /// [`EngineEvent::Flow`] plus any notable-transition thoughts and at most
    /// one advisory signal. Empty when there is nothing to read yet or the
    /// ~2/s throttle has not elapsed.
    pub fn recompute(&mut self, now_ms: i64, bars: &[Bar]) -> Vec<EngineEvent> {
        let (Some(symbol), Some(depth)) = (self.active.clone(), self.depth.clone()) else {
            return Vec::new();
        };
        if self.tape.is_empty() {
            return Vec::new();
        }
        if let Some(last) = self.last_publish_ms {
            if now_ms - last < RECOMPUTE_MIN_MS {
                return Vec::new();
            }
        }

        // Latest finite tape price anchors every price-relative read.
        let tape: Vec<TapePrint> = self.tape.iter().cloned().collect();
        let last_px = match tape
            .iter()
            .rev()
            .find_map(|p| (p.px.is_finite() && p.px > 0.0).then_some(p.px))
        {
            Some(p) => p,
            None => return Vec::new(),
        };
        self.last_publish_ms = Some(now_ms);

        let is_live = depth.is_live;
        let source = depth.source.clone();
        // Delayed feeds window against their OWN clock (the newest print's ts),
        // so a 15-min-stale equity tape still produces a coherent read.
        let tape_ref = self.tape.back().map(|p| p.ts_ms).unwrap_or(now_ms);

        // --- imbalance + pressure ---
        let imbalance = order_book_imbalance(&depth.bids, &depth.asks, OBI_TOP_N);
        let dr = delta_rate(&tape, tape_ref, RATE_WINDOW_MS);
        let gr = gross_rate(&tape, tape_ref, RATE_WINDOW_MS);
        let rate_eps = (RATE_EPS_FRAC * gr).max(0.0);
        let pressure = classify_pressure(imbalance, dr, OBI_BAND, rate_eps);

        // --- absorption ---
        let absorb_window: Vec<TapePrint> = tape
            .iter()
            .filter(|p| p.ts_ms >= tape_ref - ABSORB_WINDOW_MS)
            .cloned()
            .collect();
        let absorption =
            detect_absorption(&absorb_window, ABSORB_FLAT_PCT, ABSORB_DOMINANCE, ABSORB_MIN_PRINTS);

        // --- sweep ---
        let burst: Vec<TapePrint> = tape
            .iter()
            .filter(|p| p.ts_ms >= tape_ref - SWEEP_WINDOW_MS)
            .cloned()
            .collect();
        let sweep = detect_sweep(
            &burst,
            SWEEP_MIN_LEVELS,
            SWEEP_MIN_PRINTS,
            SWEEP_WINDOW_MS,
            SWEEP_DOMINANCE,
        );

        // --- divergence (against the sample ring, then record this sample) ---
        let cur_sample = DeltaSample {
            px: last_px,
            cum_delta: self.cum_delta,
        };
        let hist: Vec<DeltaSample> = self.samples.iter().copied().collect();
        let divergence = detect_divergence(&hist, cur_sample, DIVERGENCE_FRAC);
        self.samples.push_back(cur_sample);
        while self.samples.len() > MAX_SAMPLES {
            self.samples.pop_front();
        }

        // --- squeeze dynamics (uses the PRIOR recompute's rate/price refs) ---
        let ask_now = sum_top_sizes(&depth.asks, OBI_TOP_N);
        let ask_ref = median(&self.ask_hist.iter().copied().collect::<Vec<_>>());
        let prev_rate = self.prev_delta_rate.unwrap_or(0.0);
        let prev_px = self.prev_px.unwrap_or(last_px);
        let squeeze = self.ask_hist.len() >= MIN_ASK_HIST
            && detect_squeeze_dynamics(
                ask_now,
                ask_ref,
                dr,
                prev_rate,
                last_px,
                prev_px,
                SQUEEZE_THIN_FRAC,
            );
        self.ask_hist.push_back(ask_now);
        while self.ask_hist.len() > MAX_ASK_HIST {
            self.ask_hist.pop_front();
        }
        self.prev_delta_rate = Some(dr);
        self.prev_px = Some(last_px);

        // --- flags (stable order, bounded) ---
        let mut flags: Vec<String> = Vec::new();
        if squeeze {
            flags.push("squeeze_dynamics".into());
        }
        if let Some(sw) = sweep {
            flags.push(format!("sweep:{}", side_word(sw.aggressor)));
        }
        if let Some(ab) = absorption {
            flags.push(format!("absorption:{}", ab.side.label()));
        }
        if let Some(dv) = divergence {
            flags.push("delta_divergence".into());
            let confirmed = match dv {
                Divergence::BearishExhaustion => pressure == Pressure::Sellers,
                Divergence::BullishExhaustion => pressure == Pressure::Buyers,
            };
            if confirmed {
                flags.push("exhaustion".into());
            }
        }
        flags.truncate(MAX_FLAGS);

        // --- narrative note ---
        let regime_ctx = (bars.len() >= MIN_BARS).then(|| regime_label(detect_regime(bars).0));
        // Net signed delta over the retained window (~60s), distinct from the
        // session cumulative delta — recent-flow color for the note.
        let window_net = window_delta(&tape);
        let mut note = format!(
            "{} pressing — OBI {:+.2}, Δrate {:+.2}/s, cumΔ {:+.1} (recent netΔ {:+.1})",
            pressure.label(),
            imbalance,
            dr,
            self.cum_delta,
            window_net,
        );
        if let Some(sw) = sweep {
            note.push_str(&format!(
                "; {} sweep cleared {} levels",
                side_word(sw.aggressor),
                sw.levels
            ));
        }
        if let Some(ab) = absorption {
            note.push_str(&format!(
                "; {}-side absorbing aggressive {}s at {}",
                ab.side.label(),
                side_word(ab.aggressor),
                fmt_px(last_px),
            ));
        }
        if let Some(dv) = divergence {
            note.push_str(match dv {
                Divergence::BearishExhaustion => "; new high on fading delta — elevated reversal risk",
                Divergence::BullishExhaustion => "; new low on fading delta — elevated reversal risk",
            });
        }
        if squeeze {
            note.push_str("; squeeze BEHAVIOR in the tape (not a short-interest call)");
        }
        if let Some(r) = &regime_ctx {
            note.push_str(&format!("; bar regime {r}"));
        }
        if !is_live {
            note.push_str(" [delayed feed — not a live book]");
        }
        let note = snip(&note, 240);

        let mut out = Vec::new();
        out.push(EngineEvent::Flow(FlowRead {
            symbol: symbol.clone(),
            imbalance,
            cum_delta: self.cum_delta,
            delta_rate: dr,
            pressure: pressure.label().into(),
            flags: flags.clone(),
            note,
            is_live,
            source,
            ts_ms: now_ms,
        }));

        // --- transitions -> throttled thoughts (fire on ENTRY only) ---
        let live_tag = if is_live { "" } else { " (delayed feed)" };

        let pressure_flipped = match self.last_pressure {
            Some(prev) if prev != pressure => true,
            _ => false,
        };
        if pressure_flipped {
            let prev = self.last_pressure.unwrap();
            out.push(thought(
                Severity::Insight,
                symbol.clone(),
                0.6,
                format!(
                    "order-flow pressure flipped {} -> {} (OBI {:+.2}, Δrate {:+.2}/s){live_tag}",
                    prev.label(),
                    pressure.label(),
                    imbalance,
                    dr,
                ),
            ));
        }
        self.last_pressure = Some(pressure);

        let absorb_side = absorption.map(|a| a.side);
        let absorb_entered = matches!(absorb_side, Some(s) if self.absorption_latch != Some(s));
        if absorb_entered {
            let ab = absorption.unwrap();
            out.push(thought(
                Severity::Warning,
                symbol.clone(),
                0.7,
                format!(
                    "absorption at the {}: heavy aggressive {}s met by resting size, price held near {} — reversal risk{live_tag}",
                    ab.side.label(),
                    side_word(ab.aggressor),
                    fmt_px(last_px),
                ),
            ));
        }
        self.absorption_latch = absorb_side;

        let sweep_entered = sweep.is_some() && !self.sweep_latch;
        if sweep_entered {
            let sw = sweep.unwrap();
            out.push(thought(
                Severity::Insight,
                symbol.clone(),
                0.65,
                format!(
                    "{} sweep: a burst cleared {} levels in {}ms — aggressive one-sided taking{live_tag}",
                    side_word(sw.aggressor),
                    sw.levels,
                    sw.span_ms,
                ),
            ));
        }
        self.sweep_latch = sweep.is_some();

        let div_entered = divergence.is_some() && !self.divergence_latch;
        if div_entered {
            let dv = divergence.unwrap();
            let (dir_word, risk_word) = match dv {
                Divergence::BearishExhaustion => ("high", "downside"),
                Divergence::BullishExhaustion => ("low", "upside"),
            };
            out.push(thought(
                Severity::Warning,
                symbol.clone(),
                0.65,
                format!(
                    "delta divergence: price made a new {dir_word} but cumulative delta did not confirm — elevated {risk_word} reversal risk (probabilistic, not a call){live_tag}",
                ),
            ));
        }
        self.divergence_latch = divergence.is_some();

        let squeeze_entered = squeeze && !self.squeeze_latch;
        if squeeze_entered {
            out.push(thought(
                Severity::Insight,
                symbol.clone(),
                0.6,
                format!(
                    "squeeze dynamics: offers thinning while up-delta accelerates and price rises — this is squeeze BEHAVIOR in the tape, NOT a short-interest prediction{live_tag}",
                ),
            ));
        }
        self.squeeze_latch = squeeze;

        // --- at most ONE advisory signal, on the strongest new entry ---
        let live_scale = if is_live { 1.0 } else { 0.5 };
        let sig = if squeeze_entered {
            Some((0.5, CONV_SQUEEZE, "squeeze dynamics in the tape (behavior, not short-interest)"))
        } else if div_entered {
            match divergence.unwrap() {
                Divergence::BearishExhaustion => {
                    Some((-0.5, CONV_DIVERGENCE, "bearish delta divergence — elevated reversal risk"))
                }
                Divergence::BullishExhaustion => {
                    Some((0.5, CONV_DIVERGENCE, "bullish delta divergence — elevated reversal risk"))
                }
            }
        } else if sweep_entered {
            match sweep.unwrap().aggressor {
                Side::Buy if pressure == Pressure::Buyers => {
                    Some((0.5, CONV_SWEEP, "buy sweep with buyers in control"))
                }
                Side::Sell if pressure == Pressure::Sellers => {
                    Some((-0.5, CONV_SWEEP, "sell sweep with sellers in control"))
                }
                _ => None,
            }
        } else if absorb_entered {
            match absorption.unwrap().side {
                // Ask absorbing buys => failed push up => faint short.
                BookSide::Ask => Some((-0.5, CONV_ABSORPTION, "ask absorbing aggressive buys")),
                // Bid absorbing sells => failed push down => faint long.
                BookSide::Bid => Some((0.5, CONV_ABSORPTION, "bid absorbing aggressive sells")),
            }
        } else {
            None
        };
        if let Some((dir, base_conv, why)) = sig {
            let conv = (base_conv * live_scale).min(CONV_CAP);
            let rationale = if is_live {
                format!("advisory flow read: {why}")
            } else {
                format!("advisory flow read (delayed feed, reduced conviction): {why}")
            };
            out.push(advisory(symbol, dir, conv, rationale));
        }

        out
    }
}

pub(crate) fn spawn(bus: Arc<Bus>, store: Arc<BarStore>) {
    // Subscribe synchronously (same rule as the ledger/desks): no Depth/Tape
    // published after `start` returns can be missed by racing the spawn.
    let mut rx = bus.subscribe();
    tokio::spawn(async move {
        let mut desk = FlowDesk::new();
        loop {
            match rx.recv().await {
                Ok(ev) => {
                    let recompute = match ev.as_ref() {
                        EngineEvent::Depth(d) => {
                            desk.on_depth(d.clone());
                            true
                        }
                        EngineEvent::Tape(t) => {
                            desk.on_tape(t.clone());
                            true
                        }
                        _ => false,
                    };
                    if recompute {
                        let bars = desk
                            .active
                            .as_ref()
                            .map(|s| store.recent(s, Interval::M1, LOOKBACK))
                            .unwrap_or_default();
                        for e in desk.recompute(now_ms(), &bars) {
                            bus.publish(e);
                        }
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn depth(symbol: &str, bid_sz: f64, ask_sz: f64, is_live: bool, source: &str) -> BookDepth {
        use cx_core::events::BookLevel;
        BookDepth {
            symbol: symbol.into(),
            bids: vec![BookLevel::agg(100.0, bid_sz, 0)],
            asks: vec![BookLevel::agg(100.1, ask_sz, 0)],
            depth: 20,
            source: source.into(),
            is_live,
            ts_ms: 0,
        }
    }

    fn print(symbol: &str, px: f64, sz: f64, aggressor: Option<Side>, ts_ms: i64) -> TapePrint {
        TapePrint {
            symbol: symbol.into(),
            px,
            sz,
            aggressor,
            ts_ms,
            is_live: true,
        }
    }

    fn flows(evs: &[EngineEvent]) -> Vec<&FlowRead> {
        evs.iter()
            .filter_map(|e| match e {
                EngineEvent::Flow(f) => Some(f),
                _ => None,
            })
            .collect()
    }

    fn thoughts(evs: &[EngineEvent]) -> Vec<&AgentThought> {
        evs.iter()
            .filter_map(|e| match e {
                EngineEvent::Thought(t) => Some(t),
                _ => None,
            })
            .collect()
    }

    fn signals(evs: &[EngineEvent]) -> Vec<&StrategySignal> {
        evs.iter()
            .filter_map(|e| match e {
                EngineEvent::Signal(s) => Some(s),
                _ => None,
            })
            .collect()
    }

    /// Feed a burst of buy prints so the desk has a live read to publish.
    fn feed_buy_burst(desk: &mut FlowDesk, symbol: &str, base_ts: i64) {
        for i in 0..8 {
            desk.on_tape(print(symbol, 100.0, 3.0, Some(Side::Buy), base_ts + i * 50));
        }
    }

    #[test]
    fn desk_publishes_a_flow_read_and_throttles() {
        let mut desk = FlowDesk::new();
        // Bid-heavy live book + heavy buying -> buyers pressure.
        desk.on_depth(depth("BTC-USD", 20.0, 4.0, true, "coinbase l2"));
        feed_buy_burst(&mut desk, "BTC-USD", 1_000);

        let out = desk.recompute(10_000, &[]);
        let fr = flows(&out);
        assert_eq!(fr.len(), 1, "exactly one flow read: {out:?}");
        assert_eq!(fr[0].symbol, "BTC-USD");
        assert_eq!(fr[0].pressure, "buyers");
        assert!(fr[0].imbalance > 0.0, "bid-heavy OBI: {}", fr[0].imbalance);
        assert!(fr[0].cum_delta > 0.0);
        assert!(fr[0].is_live);
        assert_eq!(fr[0].source, "coinbase l2");

        // A second recompute inside the ~2/s window is throttled to nothing.
        assert!(desk.recompute(10_200, &[]).is_empty(), "throttled");
        // After the interval elapses it publishes again.
        assert_eq!(flows(&desk.recompute(10_700, &[])).len(), 1);
    }

    #[test]
    fn nothing_publishes_without_depth_or_tape() {
        let mut desk = FlowDesk::new();
        // Tape but no book yet: nothing (no active symbol anchor).
        desk.on_tape(print("BTC-USD", 100.0, 1.0, Some(Side::Buy), 1_000));
        assert!(desk.recompute(10_000, &[]).is_empty());
        // Book but no tape: still nothing to read.
        desk.on_depth(depth("BTC-USD", 10.0, 10.0, true, "coinbase l2"));
        assert!(desk.recompute(11_000, &[]).is_empty());
    }

    #[test]
    fn symbol_switch_resets_rolling_state() {
        let mut desk = FlowDesk::new();
        desk.on_depth(depth("BTC-USD", 10.0, 10.0, true, "coinbase l2"));
        feed_buy_burst(&mut desk, "BTC-USD", 1_000);
        assert!(desk.cum_delta > 0.0);
        // A depth for a different symbol switches the active symbol + resets.
        desk.on_depth(depth("ETH-USD", 10.0, 10.0, true, "coinbase l2"));
        assert_eq!(desk.active.as_deref(), Some("ETH-USD"));
        assert_eq!(desk.cum_delta, 0.0);
        assert!(desk.tape.is_empty());
        // BTC tape is now ignored (only the active symbol moves the desk).
        desk.on_tape(print("BTC-USD", 100.0, 5.0, Some(Side::Buy), 2_000));
        assert!(desk.tape.is_empty());
        assert_eq!(desk.cum_delta, 0.0);
    }

    #[test]
    fn pressure_flip_emits_exactly_one_thought() {
        let mut desk = FlowDesk::new();
        desk.on_depth(depth("BTC-USD", 20.0, 4.0, true, "coinbase l2"));
        feed_buy_burst(&mut desk, "BTC-USD", 1_000);
        // First read baselines pressure silently (no flip thought).
        let out = desk.recompute(10_000, &[]);
        assert_eq!(flows(&out)[0].pressure, "buyers");
        assert!(
            !thoughts(&out).iter().any(|t| t.text.contains("pressure flipped")),
            "first read must not emit a flip: {out:?}"
        );
        // Flip the book ask-heavy and pour in selling -> sellers.
        desk.on_depth(depth("BTC-USD", 4.0, 20.0, true, "coinbase l2"));
        for i in 0..8 {
            desk.on_tape(print("BTC-USD", 100.0, 3.0, Some(Side::Sell), 20_000 + i * 50));
        }
        let out = desk.recompute(21_000, &[]);
        assert_eq!(flows(&out)[0].pressure, "sellers");
        let flip: Vec<_> = thoughts(&out)
            .into_iter()
            .filter(|t| t.text.contains("pressure flipped buyers -> sellers"))
            .collect();
        assert_eq!(flip.len(), 1, "one flip thought: {out:?}");
        assert_eq!(flip[0].squadron, DESK);
    }

    #[test]
    fn delayed_feed_is_labelled_not_live() {
        let mut desk = FlowDesk::new();
        // A delayed equity L1 book: is_live=false, honest source.
        desk.on_depth(depth("AAPL", 5.0, 5.0, false, "cboe delayed L1 (no depth)"));
        for i in 0..8 {
            desk.on_tape(print("AAPL", 100.0, 2.0, Some(Side::Sell), 1_000 + i * 50));
        }
        let out = desk.recompute(10_000, &[]);
        let fr = flows(&out);
        assert_eq!(fr.len(), 1);
        assert!(!fr[0].is_live, "delayed feed must not read as live");
        assert_eq!(fr[0].source, "cboe delayed L1 (no depth)");
        assert!(fr[0].note.contains("delayed feed"), "{}", fr[0].note);
        // Any advisory signal that fires is conviction-capped and reduced.
        for s in signals(&out) {
            assert!(s.conviction <= CONV_CAP);
        }
    }

    #[test]
    fn advisory_signals_are_bounded_and_capped() {
        // Whatever fires across a run, desk-flow signals are advisory only.
        let mut desk = FlowDesk::new();
        desk.on_depth(depth("BTC-USD", 20.0, 4.0, true, "coinbase l2"));
        // A multi-level buy sweep in a tight burst.
        for i in 0..6 {
            desk.on_tape(print("BTC-USD", 100.0 + i as f64 * 0.1, 3.0, Some(Side::Buy), 1_000 + i * 100));
        }
        let out = desk.recompute(10_000, &[]);
        for s in signals(&out) {
            assert_eq!(s.strategy, DESK);
            assert!(s.conviction <= CONV_CAP, "advisory cap: {}", s.conviction);
            assert!(s.direction.abs() <= 1.0);
        }
        // At most one advisory signal per recompute.
        assert!(signals(&out).len() <= 1, "one advisory at most: {out:?}");
    }

    #[test]
    fn tape_and_samples_stay_bounded() {
        let mut desk = FlowDesk::new();
        desk.on_depth(depth("BTC-USD", 10.0, 10.0, true, "coinbase l2"));
        // Far more prints than the cap, all within the age window.
        for i in 0..(MAX_TAPE + 200) {
            desk.on_tape(print("BTC-USD", 100.0, 1.0, Some(Side::Buy), 1_000 + i as i64));
        }
        assert!(desk.tape.len() <= MAX_TAPE, "tape bound: {}", desk.tape.len());
        // Drive many recomputes to fill the sample/ask rings past their caps.
        for k in 0..(MAX_SAMPLES + 50) {
            let t = 100_000 + k as i64 * RECOMPUTE_MIN_MS;
            desk.on_tape(print("BTC-USD", 100.0, 1.0, Some(Side::Buy), t));
            let _ = desk.recompute(t, &[]);
        }
        assert!(desk.samples.len() <= MAX_SAMPLES, "samples bound");
        assert!(desk.ask_hist.len() <= MAX_ASK_HIST, "ask_hist bound");
    }

    #[test]
    fn cum_delta_resets_on_utc_day_roll() {
        let mut desk = FlowDesk::new();
        desk.on_depth(depth("BTC-USD", 10.0, 10.0, true, "coinbase l2"));
        desk.on_tape(print("BTC-USD", 100.0, 5.0, Some(Side::Buy), 10_000));
        assert!((desk.cum_delta - 5.0).abs() < 1e-12);
        // A print on the next UTC day resets the session cumulative delta.
        desk.on_tape(print("BTC-USD", 100.0, 2.0, Some(Side::Sell), DAY_MS + 1_000));
        assert!((desk.cum_delta + 2.0).abs() < 1e-12, "reset then -2: {}", desk.cum_delta);
    }
}
