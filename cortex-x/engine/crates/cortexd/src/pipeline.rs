//! TradePipeline — the single order path. Fusion signals, agent caution,
//! account equity and operator commands all converge here; every order that
//! reaches the OMS passed through RiskEngine::evaluate first. There is no
//! second door.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

use cx_core::autonomy::AutonomyDial;
use cx_core::events::{
    AgentThought, Bar, EngineEvent, OrderIntent, OrderSource, OrderStatus, OrderUpdate,
    StrategySignal,
};
use cx_core::store::BarStore;
use cx_core::time::now_ms;
use cx_core::types::{Interval, OrderType, Severity, Side, Tif};
use cx_core::{Bus, Command, Config, KillSwitch};
use cx_broker::Broker;
use cx_oms::Oms;
use cx_risk::{RiskDecision, RiskEngine};
use cx_ta::corr::EwmaCorr;
use cx_ta::ind::Atr;

/// Fusion direction magnitude below which a symbol is considered flat.
const EXIT_BAND: f64 = 0.15;
/// Fusion direction magnitude required to open/extend a position.
const ENTRY_BAND: f64 = 0.35;
/// Ignore rebalance deltas smaller than this notional.
const MIN_TICKET_NOTIONAL: f64 = 50.0;
/// ATR lookback for the trailing protective exit.
const TRAIL_ATR_PERIOD: usize = 14;

/// Trailing-exit watermark for one open position.
#[derive(Debug, Clone, Copy)]
struct TrailMark {
    /// Position sign at the last observation: +1 long, -1 short.
    sign: f64,
    /// Long: max completed-M1 close since entry; short: min.
    hwm: f64,
    /// Entry identity: the position's avg_px when the mark was seeded. A
    /// materially different live avg_px with an unchanged sign means the
    /// position closed and reopened between bars (flat Position event lost
    /// under bus lag) — the HWM is stale and the mark re-seeds.
    avg_px: f64,
}

pub struct TradePipeline {
    bus: Arc<Bus>,
    store: Arc<BarStore>,
    /// The paper OMS: the source of truth for the portfolio VIEW handed to
    /// risk, the marker, and the snapshot — in every mode. Orders are SUNK
    /// through `broker`, which in paper mode delegates straight back here.
    oms: Arc<Oms>,
    /// The active order sink (paper or IBKR), downstream of risk approval.
    broker: Arc<dyn Broker>,
    risk: Arc<RiskEngine>,
    dial: Arc<AutonomyDial>,
    kill: Arc<KillSwitch>,
    cfg: Config,
    /// EWMA return correlations across the traded set, fed from completed
    /// M1 bars — powers the correlation-aware (tighten-only) sizing scalar.
    corr: Mutex<EwmaCorr>,
    /// Configured symbol set: the ONLY symbols allowed into the correlation
    /// tracker. EwmaCorr has no internal cap, so an unfiltered feed would
    /// grow O(n^2) if a producer ever emitted unconfigured symbols.
    symbols: HashSet<String>,
    /// Previous completed-M1 close per configured symbol, so the tracker is
    /// fed close-to-close returns (completed-bar returns, like the rest of
    /// the system) instead of intra-bar close/open. Bounded by `symbols`.
    prev_close: Mutex<HashMap<String, f64>>,
    /// Streaming ATR(14) per configured symbol from completed M1 bars —
    /// powers the ATR trailing protective exit. Bounded by `symbols`.
    atr: Mutex<HashMap<String, Atr>>,
    /// Trailing-exit watermark per symbol; an entry exists only while a
    /// position is open and is cleared on close/flip so a fresh position
    /// never inherits a stale mark. Restored if risk rejects the exit, and
    /// self-validating via the seeded entry avg_px. Bounded by `symbols`.
    trail: Mutex<HashMap<String, TrailMark>>,
}

impl TradePipeline {
    pub fn new(
        bus: Arc<Bus>,
        store: Arc<BarStore>,
        oms: Arc<Oms>,
        broker: Arc<dyn Broker>,
        risk: Arc<RiskEngine>,
        dial: Arc<AutonomyDial>,
        kill: Arc<KillSwitch>,
        cfg: Config,
    ) -> Arc<Self> {
        let symbols: HashSet<String> = cfg.symbols.iter().cloned().collect();
        Arc::new(Self {
            bus,
            store,
            oms,
            broker,
            risk,
            dial,
            kill,
            cfg,
            corr: Mutex::new(EwmaCorr::new()),
            symbols,
            prev_close: Mutex::new(HashMap::new()),
            atr: Mutex::new(HashMap::new()),
            trail: Mutex::new(HashMap::new()),
        })
    }

    /// Subscribes to the bus and runs forever: signals in, orders out.
    pub fn spawn(self: &Arc<Self>) -> tokio::task::JoinHandle<()> {
        let this = Arc::clone(self);
        tokio::spawn(async move {
            let mut rx = this.bus.subscribe();
            let mut status_tick = tokio::time::interval(std::time::Duration::from_secs(2));
            loop {
                tokio::select! {
                    ev = rx.recv() => match ev {
                        Ok(ev) => this.on_event(&ev).await,
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                            tracing::warn!(lagged = n, "pipeline lagged on bus");
                        }
                        Err(_) => break,
                    },
                    _ = status_tick.tick() => this.publish_risk_status(),
                }
            }
        })
    }

    pub fn publish_risk_status(&self) {
        self.bus
            .publish(EngineEvent::Risk(self.risk.status(self.dial.get())));
    }

    async fn on_event(&self, ev: &EngineEvent) {
        match ev {
            EngineEvent::Signal(sig) if sig.strategy == "fusion" => {
                self.on_fusion_signal(sig).await;
            }
            // Completed M1 bars feed the cross-symbol correlation tracker
            // (EwmaCorr pairs asynchronous clocks internally). Gated on the
            // configured symbol set, and fed CLOSE-TO-CLOSE returns across
            // consecutive completed bars via a per-symbol prev-close map.
            EngineEvent::Bar(b) if b.complete && b.interval == Interval::M1 => {
                if self.symbols.contains(&b.symbol) && b.close.is_finite() {
                    let prev = self
                        .prev_close
                        .lock()
                        .ok()
                        .and_then(|mut m| m.insert(b.symbol.clone(), b.close));
                    if let Some(pc) = prev {
                        if pc.abs() > f64::EPSILON {
                            let r = b.close / pc - 1.0;
                            if r.is_finite() {
                                if let Ok(mut corr) = self.corr.lock() {
                                    corr.update(&b.symbol, r);
                                }
                            }
                        }
                    }
                    self.on_trail_bar(b).await;
                }
            }
            // Position lifecycle resets the trailing-exit watermark: a
            // closed or flipped position must never leave a stale HWM for
            // the next entry to inherit.
            EngineEvent::Position(p) => {
                if let Ok(mut trail) = self.trail.lock() {
                    if let Some(mark) = trail.get(&p.symbol) {
                        let flat = !p.qty.is_finite() || p.qty.abs() <= 1e-12;
                        if flat || p.qty.signum() != mark.sign {
                            trail.remove(&p.symbol);
                        }
                    }
                }
            }
            EngineEvent::Caution(c) => {
                self.risk.set_caution(c.scope.as_deref(), c.value, &c.reason);
                self.publish_risk_status();
            }
            EngineEvent::Account(a) => {
                if let Some(transition) = self.risk.on_equity(a.equity, a.ts_ms) {
                    self.thought(Severity::Critical, None, &format!("drawdown clock: {transition}"));
                    self.publish_risk_status();
                    if self.kill.is_engaged() {
                        // Kill reaches the ACTIVE broker: cancel every working
                        // order + flatten. For IBKR this cancels working IBKR
                        // orders and flattens the live account; the sync
                        // Phase-1 kill already blocks new orders instantly.
                        let ids = self.broker.flatten_all("drawdown kill switch").await;
                        self.thought(
                            Severity::Critical,
                            None,
                            &format!("kill engaged by drawdown clock; flattened {} positions", ids.len()),
                        );
                    }
                }
            }
            _ => {}
        }
    }

    /// Translate a fusion opinion into a position delta, gate it through
    /// autonomy + risk, and hand it to the OMS.
    async fn on_fusion_signal(&self, sig: &StrategySignal) {
        let Some(last_px) = self.store.last_price(&sig.symbol) else {
            return;
        };
        if !(last_px.is_finite() && last_px > 0.0) {
            return;
        }
        let view = self.oms.view();
        let equity = if view.equity.is_finite() && view.equity > 0.0 {
            view.equity
        } else {
            return;
        };
        let current_qty = view.position_qty(&sig.symbol);

        let magnitude = sig.direction.abs();
        let target_qty = if magnitude < EXIT_BAND {
            0.0
        } else if magnitude >= ENTRY_BAND {
            // Vol-targeted sizing: scale the base allocation so realized
            // volatility trends toward the target; clamped in [0.25, 1.5]
            // so a vol crush can never balloon size (quant::vol_target_scalar).
            let bars = self
                .store
                .recent(&sig.symbol, cx_core::types::Interval::M1, 240);
            let rets: Vec<f64> = bars
                .windows(2)
                .filter(|w| w[0].close > 0.0 && w[1].close > 0.0)
                .map(|w| (w[1].close / w[0].close).ln())
                .collect();
            // Annualize per-bar vol by the RIGHT number of M1 bars per year for
            // the asset class: crypto trades 24/7 (525,600 = 365×24×60), but
            // equities trade regular hours only (252 × 390 = 98,280). Using the
            // crypto constant for an equity overstates its annualized vol ~2.3×,
            // so vol-targeting undersizes equities ~2× (and pins high-vol names to
            // the 0.25 floor, where it stops adapting entirely).
            const CRYPTO_M1_BARS_PER_YEAR: f64 = 525_600.0;
            const EQUITY_M1_BARS_PER_YEAR: f64 = 98_280.0;
            let bars_per_year = match cx_core::types::asset_class_of(&sig.symbol) {
                cx_core::types::AssetClass::Equity => EQUITY_M1_BARS_PER_YEAR,
                // Crypto is 24/7; futures/FX are ~24h markets — all annualize on
                // the near-continuous constant. Only equities trade a short RTH.
                cx_core::types::AssetClass::Crypto
                | cx_core::types::AssetClass::Future
                | cx_core::types::AssetClass::Fx => CRYPTO_M1_BARS_PER_YEAR,
            };
            const TARGET_ANNUAL_VOL: f64 = 0.30;
            let vol_scalar = cx_ta::quant::ewma_vol(&rets, 0.94)
                .map(|per_bar| per_bar * bars_per_year.sqrt())
                .map(|ann| cx_ta::quant::vol_target_scalar(TARGET_ANNUAL_VOL, ann))
                .unwrap_or(1.0);
            // Correlation-aware diversification: shrink when the candidate
            // is crowded against the symbols already held. Tighten-only —
            // the scalar lives in [0.5, 1.0] and reads 1.0 with no data
            // (cx_ta::corr::diversification_scalar), so it can never grow
            // a position.
            let held: Vec<String> = view
                .positions
                .iter()
                .filter(|(s, (qty, _))| s.as_str() != sig.symbol && qty.abs() > 1e-12)
                .map(|(s, _)| s.clone())
                .collect();
            let corr_scalar = match self.corr.lock() {
                Ok(corr) => {
                    cx_ta::corr::diversification_scalar(corr.avg_corr(&sig.symbol, &held))
                }
                Err(_) => 1.0,
            };
            let target_notional = equity
                * self.cfg.risk.max_position_pct
                * vol_scalar
                * corr_scalar
                * sig.conviction.clamp(0.0, 1.0);
            sig.direction.signum() * target_notional / last_px
        } else {
            // Dead band: hold whatever we have.
            current_qty
        };

        let delta = target_qty - current_qty;
        let delta_notional = (delta * last_px).abs();
        if !delta.is_finite() || delta_notional < MIN_TICKET_NOTIONAL {
            return;
        }

        let reduces = target_qty.abs() < current_qty.abs() - 1e-12
            && (target_qty == 0.0 || target_qty.signum() == current_qty.signum());

        // Autonomy gates NEW risk only; reductions always allowed.
        let semi_cap = self.cfg.risk.max_order_notional * 0.2;
        if !reduces && !self.dial.allows_auto_entry(delta_notional, semi_cap) {
            self.thought(
                Severity::Insight,
                Some(&sig.symbol),
                &format!(
                    "suggest {} {:.6} {} (~${:.0}) — autonomy {:?} gates auto-entry. {}",
                    if delta > 0.0 { "buy" } else { "sell" },
                    delta.abs(),
                    sig.symbol,
                    delta_notional,
                    self.dial.get(),
                    sig.rationale
                ),
            );
            return;
        }

        let intent = OrderIntent {
            id: cx_core::ids::next_order_id(),
            symbol: sig.symbol.clone(),
            side: if delta > 0.0 { Side::Buy } else { Side::Sell },
            qty: delta.abs(),
            order_type: OrderType::Market,
            limit_px: None,
            stop_px: None,
            tif: Tif::Ioc,
            reduce_only: reduces,
            source: OrderSource::Strategy("fusion".into()),
            rationale: sig.rationale.clone(),
            ts_ms: now_ms(),
        };
        self.submit_through_risk(intent, last_px).await;
    }

    /// ATR trailing protective exit, evaluated on every completed M1 bar.
    /// Tracks a per-position high-water mark (long: max close since entry;
    /// short: min) and closes the FULL position once price retraces
    /// `trail_atr_mult` ATRs from it. Pure risk reduction: it never fires
    /// without a position, always submits reduce-only, and is never gated
    /// by the autonomy dial (reductions are always allowed).
    async fn on_trail_bar(&self, bar: &Bar) {
        // ATR warms on every completed bar, position or not, so the trail
        // is armed the moment a position opens. Caller guarantees a
        // configured symbol and a finite close; Atr rejects bad high/low.
        let atr = match self.atr.lock() {
            Ok(mut m) => m
                .entry(bar.symbol.clone())
                .or_insert_with(|| Atr::new(TRAIL_ATR_PERIOD))
                .update(bar.high, bar.low, bar.close),
            Err(_) => return,
        };
        if !self.cfg.risk.trail_enabled {
            return;
        }
        let close = bar.close;
        if !(close.is_finite() && close > 0.0) {
            return;
        }
        let (qty, avg_px) = self
            .oms
            .position(&bar.symbol)
            .map(|p| (p.qty, p.avg_px))
            .unwrap_or((0.0, 0.0));
        if !qty.is_finite() {
            return;
        }
        // Update the watermark and decide inside one lock scope — the
        // guard must drop before the submit await below.
        let fired = {
            let Ok(mut trail) = self.trail.lock() else {
                return;
            };
            if qty.abs() <= 1e-12 {
                trail.remove(&bar.symbol);
                return;
            }
            let sign = qty.signum();
            let mark = trail
                .entry(bar.symbol.clone())
                .or_insert(TrailMark { sign, hwm: close, avg_px });
            if mark.sign != sign {
                // Flipped between bars: restart the mark on the new side.
                *mark = TrailMark { sign, hwm: close, avg_px };
            } else {
                let scale = mark.avg_px.abs().max(avg_px.abs());
                let drift = (mark.avg_px - avg_px).abs();
                if drift.is_finite() && scale > 1e-12 && drift / scale > 1e-9 {
                    // Same sign, different entry: closed and reopened while
                    // the flat Position event was lost — HWM is stale.
                    *mark = TrailMark { sign, hwm: close, avg_px };
                }
            }
            mark.hwm = if sign > 0.0 {
                mark.hwm.max(close)
            } else {
                mark.hwm.min(close)
            };
            // ATR cold or degenerate -> the trail stays disarmed.
            let Some(atr) = atr.filter(|a| a.is_finite() && *a > 0.0) else {
                return;
            };
            let retrace = if sign > 0.0 {
                mark.hwm - close
            } else {
                close - mark.hwm
            };
            if retrace.is_finite() && retrace >= self.cfg.risk.trail_atr_mult * atr {
                // Clear the mark now so the exit fires once, not every bar
                // while the closing order works; it is restored below if
                // risk rejects the exit.
                let saved = *mark;
                trail.remove(&bar.symbol);
                Some((saved, retrace / atr))
            } else {
                None
            }
        };
        let Some((saved_mark, atr_mult)) = fired else {
            return;
        };

        let rationale = format!("ATR trail: retrace {atr_mult:.1}x ATR from HWM");
        self.bus.publish(EngineEvent::Thought(AgentThought {
            agent: "protector".into(),
            squadron: "execution".into(),
            severity: Severity::Insight,
            text: format!(
                "trail exit {}: {rationale} — closing {:.6}",
                bar.symbol,
                qty.abs()
            ),
            tags: vec!["trail".into(), "exit".into()],
            confidence: 1.0,
            symbol: Some(bar.symbol.clone()),
            ts_ms: now_ms(),
        }));

        let intent = OrderIntent {
            id: cx_core::ids::next_order_id(),
            symbol: bar.symbol.clone(),
            side: if qty > 0.0 { Side::Sell } else { Side::Buy },
            qty: qty.abs(),
            order_type: OrderType::Market,
            limit_px: None,
            stop_px: None,
            tif: Tif::Ioc,
            reduce_only: true,
            source: OrderSource::Agent("protector".into()),
            rationale,
            ts_ms: now_ms(),
        };
        let decision = self.submit_through_risk(intent, close).await;
        if !decision.is_approved() {
            // A rejected exit (e.g. kill switch engaged — the protector is
            // not kill-exempt) must not lose the protective stop: restore
            // the watermark so the next qualifying bar fires again.
            if let Ok(mut trail) = self.trail.lock() {
                trail.entry(bar.symbol.clone()).or_insert(saved_mark);
            }
        }
    }

    /// The ONLY entry point to the OMS, for every source including manual.
    /// Returns the risk decision so callers can react to a rejection (the
    /// ATR trail restores its watermark on one).
    pub async fn submit_through_risk(&self, mut intent: OrderIntent, last_px: f64) -> RiskDecision {
        let view = self.oms.view();
        // The real exit is the ATR trail — hand the risk gate the per-share stop
        // distance (trail_atr_mult × warm ATR) so its single-trade loss bound
        // sizes against the ACTUAL stop, not a fixed 2% that understates high-vol
        // names. None when the trail is off or the ATR hasn't warmed yet.
        let stop_distance = if self.cfg.risk.trail_enabled {
            self.atr
                .lock()
                .ok()
                .and_then(|m| m.get(&intent.symbol).and_then(|a| a.value()))
                .map(|atr| self.cfg.risk.trail_atr_mult * atr)
        } else {
            None
        };
        let decision = self.risk.evaluate(&intent, &view, last_px, stop_distance);
        match &decision {
            RiskDecision::Approved { qty, notes } => {
                if !notes.is_empty() {
                    self.thought(
                        Severity::Info,
                        Some(&intent.symbol),
                        &format!("risk shaped order {}: {}", intent.id, notes.join("; ")),
                    );
                }
                intent.qty = *qty;
                // The active broker is the SINK, downstream of this approval.
                // In paper mode this is byte-for-byte `oms.submit`; in live
                // mode it is the IBKR adapter (with its own LIVE hard limits).
                if let Err(e) = self.broker.place(intent.clone()).await {
                    // A broker-level rejection (e.g. a LIVE hard limit) is
                    // already surfaced on the bus by the adapter; log for the
                    // operator. The risk decision itself stands.
                    tracing::warn!(order = intent.id, "broker rejected order: {e}");
                }
            }
            RiskDecision::Rejected { reason } => {
                self.bus.publish(EngineEvent::OrderUpdate(OrderUpdate {
                    order_id: intent.id,
                    intent: intent.clone(),
                    status: OrderStatus::RejectedByRisk {
                        reason: reason.clone(),
                    },
                    filled_qty: 0.0,
                    avg_fill_px: 0.0,
                    ts_ms: now_ms(),
                }));
                self.thought(
                    Severity::Warning,
                    Some(&intent.symbol),
                    &format!("rejected {} {:?} {}: {}", intent.qty, intent.side, intent.symbol, reason),
                );
            }
        }
        decision
    }

    pub async fn handle_command(&self, cmd: Command) {
        match cmd {
            Command::PlaceOrder {
                symbol,
                side,
                qty,
                order_type,
                limit_px,
                stop_px,
            } => {
                let Some(last_px) = self.store.last_price(&symbol) else {
                    self.thought(Severity::Warning, Some(&symbol), "manual order: no market data");
                    return;
                };
                let current = self.oms.view().position_qty(&symbol);
                let reduces = qty <= current.abs() + 1e-12
                    && current.abs() > 1e-12
                    && side != if current > 0.0 { Side::Buy } else { Side::Sell };
                // Stops route through the SAME risk gate as every other order:
                // a protective reduce-only stop takes risk's permissive exit
                // path, a new-risk stop faces the full sizing checks. Order-type
                // validity (a stop needs a stop price) is enforced at the OMS.
                let intent = OrderIntent {
                    id: cx_core::ids::next_order_id(),
                    symbol,
                    side,
                    qty,
                    order_type,
                    limit_px,
                    stop_px,
                    tif: Tif::Gtc,
                    reduce_only: reduces,
                    source: OrderSource::Manual,
                    rationale: "operator order".into(),
                    ts_ms: now_ms(),
                };
                self.submit_through_risk(intent, last_px).await;
            }
            Command::CancelOrder { order_id } => {
                self.broker.cancel(order_id).await;
            }
            Command::SetKillSwitch { engaged, reason } => {
                if engaged {
                    self.kill.engage(reason.clone());
                    self.thought(Severity::Critical, None, &format!("kill switch engaged: {reason}"));
                    // The operator's emergency stop must REACH the venue, not
                    // merely block new orders: cancel every working order then
                    // flatten every position at the active broker (invariant #4
                    // in cx-broker). Without this a resting live GTC order can
                    // still fill after the switch is thrown. Mirrors the
                    // drawdown auto-kill path; on paper it is oms.flatten_all.
                    let ids = self.broker.flatten_all("kill switch").await;
                    self.thought(
                        Severity::Critical,
                        None,
                        &format!("kill switch: flattened {} positions at the broker", ids.len()),
                    );
                } else if self.kill.disengage(reason.clone()) {
                    self.thought(Severity::Critical, None, &format!("kill switch disengaged: {reason}"));
                }
                self.publish_risk_status();
            }
            Command::SetAutonomy { level } => {
                self.dial.set(level);
                self.thought(Severity::Insight, None, &format!("autonomy set to {level:?}"));
                self.publish_risk_status();
            }
            Command::FlattenAll { reason } => {
                // Operator flatten routes through the active broker: cancel all
                // working orders + flatten (reduce-only) at the live venue.
                let ids = self.broker.flatten_all(&reason).await;
                self.thought(
                    Severity::Warning,
                    None,
                    &format!("operator flatten: {} closing orders ({reason})", ids.len()),
                );
            }
            // SetStrategyEnabled / AskAi / Sync are routed elsewhere by main.
            _ => {}
        }
    }

    fn thought(&self, severity: Severity, symbol: Option<&str>, text: &str) {
        self.bus.publish(EngineEvent::Thought(AgentThought {
            agent: "pipeline".into(),
            squadron: "core".into(),
            severity,
            text: text.into(),
            tags: vec!["pipeline".into()],
            confidence: 1.0,
            symbol: symbol.map(String::from),
            ts_ms: now_ms(),
        }));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cx_core::bus::BusEvent;
    use cx_core::events::Position;
    use cx_core::types::AutonomyLevel;
    use tokio::sync::broadcast;

    fn test_cfg() -> Config {
        let mut cfg = Config::default();
        cfg.paper.latency_ms = 0;
        cfg.paper.slippage_bps = 0.0;
        cfg.paper.taker_fee_bps = 0.0;
        cfg
    }

    /// Dial parked at Manual on purpose: the trail must fire anyway,
    /// proving the autonomy dial never gates a risk reduction. The active
    /// broker is the paper broker, so every order path is byte-for-byte the
    /// existing paper engine (`broker.place` == `oms.submit`).
    fn setup(cfg: Config) -> (Arc<Bus>, Arc<BarStore>, Arc<Oms>, Arc<TradePipeline>) {
        let bus = Bus::new(1024);
        let store = Arc::new(BarStore::new());
        let oms = Oms::new(Arc::clone(&bus), Arc::clone(&store), cfg.paper.clone());
        let broker: Arc<dyn Broker> = cx_broker::PaperBroker::new(Arc::clone(&oms));
        let kill = Arc::new(KillSwitch::new());
        let risk = Arc::new(RiskEngine::new(cfg.risk.clone(), Arc::clone(&kill)));
        let dial = Arc::new(AutonomyDial::new(AutonomyLevel::Manual));
        let pipeline = TradePipeline::new(
            Arc::clone(&bus),
            Arc::clone(&store),
            Arc::clone(&oms),
            broker,
            risk,
            dial,
            kill,
            cfg,
        );
        (bus, store, oms, pipeline)
    }

    /// A broker that records every emergency-exit call routed through the
    /// trait, so a test can assert the kill/flatten path reaches the broker.
    struct RecordingBroker {
        flatten_calls: std::sync::Mutex<Vec<String>>,
        cancel_all_calls: std::sync::Mutex<Vec<String>>,
    }

    impl RecordingBroker {
        fn new() -> Arc<Self> {
            Arc::new(Self {
                flatten_calls: std::sync::Mutex::new(Vec::new()),
                cancel_all_calls: std::sync::Mutex::new(Vec::new()),
            })
        }
    }

    #[async_trait::async_trait]
    impl Broker for RecordingBroker {
        fn name(&self) -> &'static str {
            "recording"
        }
        async fn connect(&self) -> Result<(), cx_broker::BrokerError> {
            Ok(())
        }
        async fn disconnect(&self) {}
        async fn place(
            &self,
            intent: OrderIntent,
        ) -> Result<cx_broker::BrokerOrderId, cx_broker::BrokerError> {
            Ok(cx_broker::BrokerOrderId::paper(intent.id))
        }
        async fn cancel(&self, _order_id: u64) -> bool {
            true
        }
        async fn cancel_all(&self, reason: &str) {
            self.cancel_all_calls.lock().unwrap().push(reason.to_string());
        }
        async fn flatten_all(&self, reason: &str) -> Vec<u64> {
            self.flatten_calls.lock().unwrap().push(reason.to_string());
            vec![1]
        }
        fn positions(&self) -> Vec<cx_core::events::Position> {
            Vec::new()
        }
        fn account(&self) -> cx_core::events::AccountSnapshot {
            self.oms_snapshot()
        }
        fn status(&self) -> cx_core::events::BrokerStatus {
            cx_core::events::BrokerStatus {
                mode: cx_core::events::BrokerMode::Paper,
                connected: true,
                account_masked: None,
            }
        }
    }

    impl RecordingBroker {
        fn oms_snapshot(&self) -> cx_core::events::AccountSnapshot {
            cx_core::events::AccountSnapshot {
                equity: 100_000.0,
                cash: 100_000.0,
                gross_exposure: 0.0,
                net_exposure: 0.0,
                unrealized_pnl: 0.0,
                realized_pnl_day: 0.0,
                fees_paid: 0.0,
                open_orders: 0,
                daily_trades: 0,
                drawdown_day: 0.0,
                drawdown_total: 0.0,
                ts_ms: now_ms(),
            }
        }
    }

    fn setup_with_broker(
        cfg: Config,
        broker: Arc<dyn Broker>,
    ) -> (Arc<Bus>, Arc<BarStore>, Arc<Oms>, Arc<KillSwitch>, Arc<TradePipeline>) {
        let bus = Bus::new(1024);
        let store = Arc::new(BarStore::new());
        let oms = Oms::new(Arc::clone(&bus), Arc::clone(&store), cfg.paper.clone());
        let kill = Arc::new(KillSwitch::new());
        let risk = Arc::new(RiskEngine::new(cfg.risk.clone(), Arc::clone(&kill)));
        let dial = Arc::new(AutonomyDial::new(AutonomyLevel::FullAuto));
        let pipeline = TradePipeline::new(
            Arc::clone(&bus),
            Arc::clone(&store),
            Arc::clone(&oms),
            broker,
            risk,
            Arc::clone(&dial),
            Arc::clone(&kill),
            cfg,
        );
        (bus, store, oms, kill, pipeline)
    }

    #[tokio::test]
    async fn operator_flatten_routes_through_the_active_broker() {
        let rec = RecordingBroker::new();
        let (_bus, _store, _oms, _kill, pipeline) =
            setup_with_broker(test_cfg(), Arc::clone(&rec) as Arc<dyn Broker>);
        pipeline
            .handle_command(Command::FlattenAll {
                reason: "operator drill".into(),
            })
            .await;
        let calls = rec.flatten_calls.lock().unwrap();
        assert_eq!(calls.len(), 1, "flatten must reach the broker");
        assert_eq!(calls[0], "operator drill");
    }

    #[tokio::test]
    async fn drawdown_kill_flattens_through_the_broker() {
        let rec = RecordingBroker::new();
        let (bus, _store, _oms, kill, pipeline) =
            setup_with_broker(test_cfg(), Arc::clone(&rec) as Arc<dyn Broker>);
        // Engage the kill switch, then drive the drawdown clock past its hard
        // breach so the Account handler flattens through the broker.
        pipeline
            .on_event(&EngineEvent::Account(account(100_000.0, 0)))
            .await;
        pipeline
            .on_event(&EngineEvent::Account(account(90_000.0, 1)))
            .await;
        assert!(kill.is_engaged(), "hard drawdown breach must engage the kill");
        let calls = rec.flatten_calls.lock().unwrap();
        assert!(!calls.is_empty(), "kill must flatten through the broker");
        let _ = bus;
    }

    #[tokio::test]
    async fn manual_kill_switch_flattens_through_the_broker() {
        // The operator's emergency stop must cancel working orders + flatten at
        // the venue, not merely block new orders — otherwise a resting live GTC
        // order can still fill after the switch is thrown (invariant #4).
        let rec = RecordingBroker::new();
        let (_bus, _store, _oms, kill, pipeline) =
            setup_with_broker(test_cfg(), Arc::clone(&rec) as Arc<dyn Broker>);
        pipeline
            .handle_command(Command::SetKillSwitch {
                engaged: true,
                reason: "operator emergency stop".into(),
            })
            .await;
        assert!(kill.is_engaged(), "the switch must be engaged");
        let calls = rec.flatten_calls.lock().unwrap();
        assert_eq!(calls.len(), 1, "manual kill must flatten exactly once");
        assert_eq!(calls[0], "kill switch");
    }

    #[tokio::test]
    async fn disengaging_the_kill_switch_does_not_flatten() {
        // Standing down the kill is not an exit event — it must never issue a
        // flatten at the broker.
        let rec = RecordingBroker::new();
        let (_bus, _store, _oms, _kill, pipeline) =
            setup_with_broker(test_cfg(), Arc::clone(&rec) as Arc<dyn Broker>);
        pipeline
            .handle_command(Command::SetKillSwitch { engaged: true, reason: "stop".into() })
            .await;
        pipeline
            .handle_command(Command::SetKillSwitch { engaged: false, reason: "resume".into() })
            .await;
        // Exactly one flatten (from the engage), none from the disengage.
        assert_eq!(rec.flatten_calls.lock().unwrap().len(), 1);
    }

    fn account(equity: f64, ts_ms: i64) -> cx_core::events::AccountSnapshot {
        cx_core::events::AccountSnapshot {
            equity,
            cash: equity,
            gross_exposure: 0.0,
            net_exposure: 0.0,
            unrealized_pnl: 0.0,
            realized_pnl_day: 0.0,
            fees_paid: 0.0,
            open_orders: 0,
            daily_trades: 0,
            drawdown_day: 0.0,
            drawdown_total: 0.0,
            ts_ms,
        }
    }

    fn m1(symbol: &str, i: i64, high: f64, low: f64, close: f64) -> EngineEvent {
        EngineEvent::Bar(Bar {
            symbol: symbol.into(),
            interval: Interval::M1,
            ts_open_ms: i * 60_000,
            open: close,
            high,
            low,
            close,
            volume: 1.0,
            trade_count: 1,
            vwap: close,
            complete: true,
        })
    }

    /// 14 flat bars with a 1.0 range warm ATR(14) to exactly 1.0.
    async fn warm_atr(pipeline: &TradePipeline, symbol: &str) {
        for i in 0..14 {
            pipeline.on_event(&m1(symbol, i, 100.5, 99.5, 100.0)).await;
        }
    }

    async fn open_position(store: &BarStore, oms: &Oms, symbol: &str, side: Side, qty: f64, px: f64) {
        store.set_last_price(symbol, px);
        oms.submit(OrderIntent {
            id: 0,
            symbol: symbol.into(),
            side,
            qty,
            order_type: OrderType::Market,
            limit_px: None,
            stop_px: None,
            tif: Tif::Gtc,
            reduce_only: false,
            source: OrderSource::Manual,
            rationale: "test entry".into(),
            ts_ms: now_ms(),
        })
        .await;
    }

    fn order_updates(rx: &mut broadcast::Receiver<BusEvent>) -> Vec<OrderUpdate> {
        let mut out = Vec::new();
        while let Ok(ev) = rx.try_recv() {
            if let EngineEvent::OrderUpdate(u) = ev.as_ref() {
                out.push(u.clone());
            }
        }
        out
    }

    #[tokio::test]
    async fn trail_fires_on_long_retrace_reduce_only() {
        let (bus, store, oms, pipeline) = setup(test_cfg());
        warm_atr(&pipeline, "BTC-USD").await;
        open_position(&store, &oms, "BTC-USD", Side::Buy, 1.0, 100.0).await;

        let mut rx = bus.subscribe();
        // Run up, then a shallow dip: HWM 101, retrace 1.0 < 2.5 * ATR.
        pipeline.on_event(&m1("BTC-USD", 20, 101.5, 100.5, 101.0)).await;
        pipeline.on_event(&m1("BTC-USD", 21, 101.0, 99.5, 100.0)).await;
        assert!(order_updates(&mut rx).is_empty());
        assert!((oms.view().position_qty("BTC-USD") - 1.0).abs() < 1e-9);

        // Deep retrace: 101 -> 96 = 5.0 >= 2.5 * ATR (~1.31 after this bar).
        store.set_last_price("BTC-USD", 96.0);
        pipeline.on_event(&m1("BTC-USD", 22, 100.0, 95.5, 96.0)).await;

        let ups = order_updates(&mut rx);
        assert!(!ups.is_empty(), "trail exit should have fired");
        let intent = &ups[0].intent;
        assert!(intent.reduce_only);
        assert_eq!(intent.source, OrderSource::Agent("protector".into()));
        assert_eq!(intent.side, Side::Sell);
        assert!((intent.qty - 1.0).abs() < 1e-9);
        assert!(intent.rationale.starts_with("ATR trail: retrace"));
        assert!(oms.view().position_qty("BTC-USD").abs() < 1e-9);
    }

    #[tokio::test]
    async fn trail_fires_on_short_retrace() {
        let (bus, store, oms, pipeline) = setup(test_cfg());
        warm_atr(&pipeline, "ETH-USD").await;
        open_position(&store, &oms, "ETH-USD", Side::Sell, 2.0, 100.0).await;

        let mut rx = bus.subscribe();
        // New low: LWM parks at 98; retrace 0 -> hold.
        pipeline.on_event(&m1("ETH-USD", 20, 98.5, 97.5, 98.0)).await;
        assert!(order_updates(&mut rx).is_empty());

        // Bounce against the short: 98 -> 103 = 5.0 >= 2.5 * ATR.
        store.set_last_price("ETH-USD", 103.0);
        pipeline.on_event(&m1("ETH-USD", 21, 103.5, 102.5, 103.0)).await;

        let ups = order_updates(&mut rx);
        assert!(!ups.is_empty(), "trail exit should have fired");
        let intent = &ups[0].intent;
        assert!(intent.reduce_only);
        assert_eq!(intent.source, OrderSource::Agent("protector".into()));
        assert_eq!(intent.side, Side::Buy);
        assert!((intent.qty - 2.0).abs() < 1e-9);
        assert!(oms.view().position_qty("ETH-USD").abs() < 1e-9);
    }

    #[tokio::test]
    async fn trail_holds_while_atr_cold() {
        let (bus, store, oms, pipeline) = setup(test_cfg());
        // Only 5 samples reach ATR(14): far from warm.
        for i in 0..3 {
            pipeline.on_event(&m1("BTC-USD", i, 100.5, 99.5, 100.0)).await;
        }
        open_position(&store, &oms, "BTC-USD", Side::Buy, 1.0, 100.0).await;

        let mut rx = bus.subscribe();
        pipeline.on_event(&m1("BTC-USD", 10, 100.5, 99.5, 100.0)).await;
        store.set_last_price("BTC-USD", 80.0);
        pipeline.on_event(&m1("BTC-USD", 11, 100.0, 79.5, 80.0)).await;
        assert!(order_updates(&mut rx).is_empty());
        assert!((oms.view().position_qty("BTC-USD") - 1.0).abs() < 1e-9);
    }

    #[tokio::test]
    async fn trail_never_fires_without_a_position() {
        let (bus, _store, _oms, pipeline) = setup(test_cfg());
        warm_atr(&pipeline, "BTC-USD").await;

        let mut rx = bus.subscribe();
        pipeline.on_event(&m1("BTC-USD", 20, 110.5, 109.5, 110.0)).await;
        pipeline.on_event(&m1("BTC-USD", 21, 110.0, 89.5, 90.0)).await;
        assert!(order_updates(&mut rx).is_empty());
    }

    #[tokio::test]
    async fn trail_disabled_flag_suppresses_exit() {
        let mut cfg = test_cfg();
        cfg.risk.trail_enabled = false;
        let (bus, store, oms, pipeline) = setup(cfg);
        warm_atr(&pipeline, "BTC-USD").await;
        open_position(&store, &oms, "BTC-USD", Side::Buy, 1.0, 100.0).await;

        let mut rx = bus.subscribe();
        pipeline.on_event(&m1("BTC-USD", 20, 101.5, 100.5, 101.0)).await;
        store.set_last_price("BTC-USD", 90.0);
        pipeline.on_event(&m1("BTC-USD", 21, 101.0, 89.5, 90.0)).await;
        assert!(order_updates(&mut rx).is_empty());
        assert!((oms.view().position_qty("BTC-USD") - 1.0).abs() < 1e-9);
    }

    #[tokio::test]
    async fn rejected_trail_exit_keeps_the_watermark_until_it_can_fire() {
        let (bus, store, oms, pipeline) = setup(test_cfg());
        warm_atr(&pipeline, "BTC-USD").await;
        open_position(&store, &oms, "BTC-USD", Side::Buy, 1.0, 100.0).await;
        // HWM parks at 101.
        pipeline.on_event(&m1("BTC-USD", 20, 101.5, 100.5, 101.0)).await;

        // Engage the kill DIRECTLY (not via the command): the command path now
        // also flattens at the broker, which would close the very position this
        // test needs open to exercise the rejected-exit watermark restore.
        pipeline.kill.engage("test");

        let mut rx = bus.subscribe();
        // Deep retrace fires the trail, but Agent("protector") is not
        // kill-exempt: risk rejects and the position stays open.
        store.set_last_price("BTC-USD", 96.0);
        pipeline.on_event(&m1("BTC-USD", 21, 100.0, 95.5, 96.0)).await;
        let ups = order_updates(&mut rx);
        assert!(
            ups.iter()
                .any(|u| matches!(u.status, OrderStatus::RejectedByRisk { .. })),
            "trail exit should have been rejected under kill"
        );
        assert!(ups.iter().all(|u| !matches!(u.status, OrderStatus::Filled)));
        assert!((oms.view().position_qty("BTC-USD") - 1.0).abs() < 1e-9);
        // The protective stop survives the rejection.
        {
            let trail = pipeline.trail.lock().expect("trail lock");
            let mark = trail.get("BTC-USD").expect("mark restored after rejection");
            assert!((mark.hwm - 101.0).abs() < 1e-9);
        }

        pipeline
            .handle_command(Command::SetKillSwitch {
                engaged: false,
                reason: "test over".into(),
            })
            .await;

        // Next qualifying bar fires again and now closes the position.
        store.set_last_price("BTC-USD", 95.5);
        pipeline.on_event(&m1("BTC-USD", 22, 96.5, 95.0, 95.5)).await;
        let ups = order_updates(&mut rx);
        assert!(
            ups.iter().any(|u| matches!(u.status, OrderStatus::Filled)),
            "trail should fire again after kill disengages"
        );
        assert!(oms.view().position_qty("BTC-USD").abs() < 1e-9);
    }

    #[tokio::test]
    async fn stale_mark_reseeds_when_entry_identity_changes() {
        let (bus, store, oms, pipeline) = setup(test_cfg());
        warm_atr(&pipeline, "BTC-USD").await;
        open_position(&store, &oms, "BTC-USD", Side::Buy, 1.0, 100.0).await;
        // HWM parks at 105 with entry identity avg_px 100.
        pipeline.on_event(&m1("BTC-USD", 20, 105.5, 104.5, 105.0)).await;

        // Same-sign close-and-reopen between bars, with the flat Position
        // event dropped (bus lag): the pipeline never observes qty == 0.
        store.set_last_price("BTC-USD", 105.0);
        oms.submit(OrderIntent {
            id: 0,
            symbol: "BTC-USD".into(),
            side: Side::Sell,
            qty: 1.0,
            order_type: OrderType::Market,
            limit_px: None,
            stop_px: None,
            tif: Tif::Gtc,
            reduce_only: true,
            source: OrderSource::Manual,
            rationale: "test close".into(),
            ts_ms: now_ms(),
        })
        .await;
        open_position(&store, &oms, "BTC-USD", Side::Buy, 1.0, 96.0).await;

        let mut rx = bus.subscribe();
        // A stale HWM would read 105 -> 96 = 9 >= 2.5 * ATR and dump the
        // fresh position; the avg_px identity check re-seeds at 96 instead.
        pipeline.on_event(&m1("BTC-USD", 21, 96.5, 95.5, 96.0)).await;
        assert!(order_updates(&mut rx).is_empty());
        assert!((oms.view().position_qty("BTC-USD") - 1.0).abs() < 1e-9);
        {
            let trail = pipeline.trail.lock().expect("trail lock");
            let mark = trail.get("BTC-USD").expect("mark present");
            assert!((mark.hwm - 96.0).abs() < 1e-9, "mark re-seeded from close");
            assert!((mark.avg_px - 96.0).abs() < 1e-9, "entry identity refreshed");
        }

        // The re-seeded mark still protects: a deep retrace from 96 fires.
        store.set_last_price("BTC-USD", 89.0);
        pipeline.on_event(&m1("BTC-USD", 22, 96.0, 88.5, 89.0)).await;
        let ups = order_updates(&mut rx);
        assert!(!ups.is_empty(), "re-seeded trail should fire");
        let intent = &ups[0].intent;
        assert!(intent.reduce_only);
        assert_eq!(intent.source, OrderSource::Agent("protector".into()));
        assert!(oms.view().position_qty("BTC-USD").abs() < 1e-9);
    }

    #[tokio::test]
    async fn position_close_event_resets_the_watermark() {
        let (bus, store, oms, pipeline) = setup(test_cfg());
        warm_atr(&pipeline, "BTC-USD").await;
        open_position(&store, &oms, "BTC-USD", Side::Buy, 1.0, 105.0).await;
        // HWM parks at 105.
        pipeline.on_event(&m1("BTC-USD", 20, 105.5, 104.5, 105.0)).await;

        // Close/reopen between bars: the Position event must clear the mark.
        pipeline
            .on_event(&EngineEvent::Position(Position {
                symbol: "BTC-USD".into(),
                qty: 0.0,
                avg_px: 0.0,
                mark_px: 105.0,
                unrealized_pnl: 0.0,
                realized_pnl: 0.0,
                ts_ms: now_ms(),
            }))
            .await;

        let mut rx = bus.subscribe();
        // 105 -> 100 would trip a stale mark (5.0 >= 2.5 * ATR); a fresh
        // mark re-seeds at 100 and holds.
        store.set_last_price("BTC-USD", 100.0);
        pipeline.on_event(&m1("BTC-USD", 21, 105.0, 99.5, 100.0)).await;
        assert!(order_updates(&mut rx).is_empty());
        assert!((oms.view().position_qty("BTC-USD") - 1.0).abs() < 1e-9);
    }

    #[tokio::test]
    async fn place_order_protective_stop_routes_through_risk_and_rests() {
        // A manual protective sell-stop command must reach the OMS through the
        // SAME risk gate and rest as a Working stop (its trigger sits below the
        // last price). Reduce-only takes risk's permissive exit path, so this
        // never depends on the sizing caps. The dial is parked at Manual —
        // manual operator commands are not autonomy-gated.
        let (bus, store, oms, pipeline) = setup(test_cfg());
        store.set_last_price("BTC-USD", 100.0);
        // Open a 1.0 long directly (setup only).
        open_position(&store, &oms, "BTC-USD", Side::Buy, 1.0, 100.0).await;

        let mut rx = bus.subscribe();
        pipeline
            .handle_command(Command::PlaceOrder {
                symbol: "BTC-USD".into(),
                side: Side::Sell,
                qty: 1.0,
                order_type: OrderType::Stop,
                limit_px: None,
                stop_px: Some(95.0),
            })
            .await;

        let ups = order_updates(&mut rx);
        assert!(
            !ups.iter()
                .any(|u| matches!(u.status, OrderStatus::RejectedByRisk { .. })),
            "protective stop must pass the risk gate"
        );
        assert!(ups.iter().any(|u| matches!(u.status, OrderStatus::Working)));

        // It rests as a reduce-only Working stop carrying its trigger.
        let open = oms.open_orders();
        assert_eq!(open.len(), 1);
        assert!(matches!(open[0].status, OrderStatus::Working));
        assert_eq!(open[0].intent.order_type, OrderType::Stop);
        assert_eq!(open[0].intent.stop_px, Some(95.0));
        assert!(open[0].intent.reduce_only);
        assert!((oms.view().position_qty("BTC-USD") - 1.0).abs() < 1e-9); // still long
    }

    /// Build a pipeline whose broker slot is a hot-swappable [`ActiveBroker`]
    /// starting on a paper broker over the returned OMS, and hand back the
    /// wrapper handle so a test can swap the delegate mid-flight — exactly what
    /// the runtime `SetBrokerConfig` path does.
    fn setup_with_active(
        cfg: Config,
    ) -> (
        Arc<Bus>,
        Arc<BarStore>,
        Arc<Oms>,
        Arc<KillSwitch>,
        Arc<crate::active_broker::ActiveBroker>,
        Arc<TradePipeline>,
    ) {
        let bus = Bus::new(1024);
        let store = Arc::new(BarStore::new());
        let oms = Oms::new(Arc::clone(&bus), Arc::clone(&store), cfg.paper.clone());
        let kill = Arc::new(KillSwitch::new());
        let risk = Arc::new(RiskEngine::new(cfg.risk.clone(), Arc::clone(&kill)));
        let dial = Arc::new(AutonomyDial::new(AutonomyLevel::FullAuto));
        let paper: Arc<dyn Broker> = cx_broker::PaperBroker::new(Arc::clone(&oms));
        let active = crate::active_broker::ActiveBroker::new(paper);
        let pipeline = TradePipeline::new(
            Arc::clone(&bus),
            Arc::clone(&store),
            Arc::clone(&oms),
            Arc::clone(&active) as Arc<dyn Broker>,
            risk,
            dial,
            Arc::clone(&kill),
            cfg,
        );
        (bus, store, oms, kill, active, pipeline)
    }

    fn buy(symbol: &str, qty: f64) -> Command {
        Command::PlaceOrder {
            symbol: symbol.into(),
            side: Side::Buy,
            qty,
            order_type: OrderType::Market,
            limit_px: None,
            stop_px: None,
        }
    }

    #[tokio::test]
    async fn paper_to_paper_broker_swap_keeps_pipeline_routing() {
        // Swapping the sink (paper -> a fresh paper broker over the SAME book,
        // as `set_broker_config` would) must not break order routing: the
        // pipeline holds a stable ActiveBroker whose delegate simply changes.
        let (_bus, store, oms, _kill, active, pipeline) = setup_with_active(test_cfg());
        store.set_last_price("AAPL", 100.0);

        // Pre-swap: a manual buy routes through the initial paper broker.
        pipeline.handle_command(buy("AAPL", 2.0)).await;
        assert!((oms.view().position_qty("AAPL") - 2.0).abs() < 1e-9);

        // Hot-swap to a fresh paper broker over the SAME OMS book.
        let paper2: Arc<dyn Broker> = cx_broker::PaperBroker::new(Arc::clone(&oms));
        let previous = active.swap(Arc::clone(&paper2));
        assert!(Arc::ptr_eq(&active.current(), &paper2), "swap must take effect");
        assert_eq!(previous.name(), "paper");

        // Post-swap: routing continues — another buy still reaches the OMS.
        pipeline.handle_command(buy("AAPL", 3.0)).await;
        assert!(
            (oms.view().position_qty("AAPL") - 5.0).abs() < 1e-9,
            "post-swap order must still route to the book"
        );
        assert_eq!(pipeline.broker.name(), "paper");
    }

    #[tokio::test]
    async fn mock_broker_swap_preserves_kill_and_risk_path() {
        // After hot-swapping to a mock broker, the operator kill switch must
        // still engage the (synchronous, in-memory) kill AND route cancel +
        // flatten to the CURRENT broker — the risk/kill path survives the swap.
        let (_bus, _store, _oms, kill, active, pipeline) = setup_with_active(test_cfg());

        let rec = RecordingBroker::new();
        active.swap(Arc::clone(&rec) as Arc<dyn Broker>);

        pipeline
            .handle_command(Command::SetKillSwitch {
                engaged: true,
                reason: "kill switch".into(),
            })
            .await;

        assert!(kill.is_engaged(), "the synchronous kill must engage across the swap");
        let calls = rec.flatten_calls.lock().unwrap();
        assert_eq!(calls.len(), 1, "kill must flatten through the swapped-in broker");
        assert_eq!(calls[0], "kill switch");
    }
}
