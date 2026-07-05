//! TradePipeline — the single order path. Fusion signals, agent caution,
//! account equity and operator commands all converge here; every order that
//! reaches the OMS passed through RiskEngine::evaluate first. There is no
//! second door.

use std::sync::Arc;

use cx_core::autonomy::AutonomyDial;
use cx_core::events::{
    AgentThought, EngineEvent, OrderIntent, OrderSource, OrderStatus, OrderUpdate, StrategySignal,
};
use cx_core::store::BarStore;
use cx_core::time::now_ms;
use cx_core::types::{OrderType, Severity, Side, Tif};
use cx_core::{Bus, Command, Config, KillSwitch};
use cx_oms::Oms;
use cx_risk::{RiskDecision, RiskEngine};

/// Fusion direction magnitude below which a symbol is considered flat.
const EXIT_BAND: f64 = 0.15;
/// Fusion direction magnitude required to open/extend a position.
const ENTRY_BAND: f64 = 0.35;
/// Ignore rebalance deltas smaller than this notional.
const MIN_TICKET_NOTIONAL: f64 = 50.0;

pub struct TradePipeline {
    bus: Arc<Bus>,
    store: Arc<BarStore>,
    oms: Arc<Oms>,
    risk: Arc<RiskEngine>,
    dial: Arc<AutonomyDial>,
    kill: Arc<KillSwitch>,
    cfg: Config,
}

impl TradePipeline {
    pub fn new(
        bus: Arc<Bus>,
        store: Arc<BarStore>,
        oms: Arc<Oms>,
        risk: Arc<RiskEngine>,
        dial: Arc<AutonomyDial>,
        kill: Arc<KillSwitch>,
        cfg: Config,
    ) -> Arc<Self> {
        Arc::new(Self {
            bus,
            store,
            oms,
            risk,
            dial,
            kill,
            cfg,
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
            EngineEvent::Caution(c) => {
                self.risk.set_caution(c.scope.as_deref(), c.value, &c.reason);
                self.publish_risk_status();
            }
            EngineEvent::Account(a) => {
                if let Some(transition) = self.risk.on_equity(a.equity, a.ts_ms) {
                    self.thought(Severity::Critical, None, &format!("drawdown clock: {transition}"));
                    self.publish_risk_status();
                    if self.kill.is_engaged() {
                        let ids = self.oms.flatten_all("drawdown kill switch").await;
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
            const M1_BARS_PER_YEAR: f64 = 525_600.0;
            const TARGET_ANNUAL_VOL: f64 = 0.30;
            let vol_scalar = cx_ta::quant::ewma_vol(&rets, 0.94)
                .map(|per_bar| per_bar * M1_BARS_PER_YEAR.sqrt())
                .map(|ann| cx_ta::quant::vol_target_scalar(TARGET_ANNUAL_VOL, ann))
                .unwrap_or(1.0);
            let target_notional = equity
                * self.cfg.risk.max_position_pct
                * vol_scalar
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
            tif: Tif::Ioc,
            reduce_only: reduces,
            source: OrderSource::Strategy("fusion".into()),
            rationale: sig.rationale.clone(),
            ts_ms: now_ms(),
        };
        self.submit_through_risk(intent, last_px).await;
    }

    /// The ONLY entry point to the OMS, for every source including manual.
    pub async fn submit_through_risk(&self, mut intent: OrderIntent, last_px: f64) {
        let view = self.oms.view();
        match self.risk.evaluate(&intent, &view, last_px) {
            RiskDecision::Approved { qty, notes } => {
                if !notes.is_empty() {
                    self.thought(
                        Severity::Info,
                        Some(&intent.symbol),
                        &format!("risk shaped order {}: {}", intent.id, notes.join("; ")),
                    );
                }
                intent.qty = qty;
                self.oms.submit(intent).await;
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
    }

    pub async fn handle_command(&self, cmd: Command) {
        match cmd {
            Command::PlaceOrder {
                symbol,
                side,
                qty,
                order_type,
                limit_px,
            } => {
                let Some(last_px) = self.store.last_price(&symbol) else {
                    self.thought(Severity::Warning, Some(&symbol), "manual order: no market data");
                    return;
                };
                let current = self.oms.view().position_qty(&symbol);
                let reduces = qty <= current.abs() + 1e-12
                    && current.abs() > 1e-12
                    && side != if current > 0.0 { Side::Buy } else { Side::Sell };
                let intent = OrderIntent {
                    id: cx_core::ids::next_order_id(),
                    symbol,
                    side,
                    qty,
                    order_type,
                    limit_px,
                    tif: Tif::Gtc,
                    reduce_only: reduces,
                    source: OrderSource::Manual,
                    rationale: "operator order".into(),
                    ts_ms: now_ms(),
                };
                self.submit_through_risk(intent, last_px).await;
            }
            Command::CancelOrder { order_id } => {
                self.oms.cancel(order_id, "operator cancel").await;
            }
            Command::SetKillSwitch { engaged, reason } => {
                if engaged {
                    self.kill.engage(reason.clone());
                    self.thought(Severity::Critical, None, &format!("kill switch engaged: {reason}"));
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
                let ids = self.oms.flatten_all(&reason).await;
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
