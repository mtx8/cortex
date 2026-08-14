//! # cx-broker — the live-trading routing layer (PAPER-FIRST)
//!
//! A single [`Broker`] trait with two implementations sitting DOWNSTREAM of
//! the risk gate. The pipeline hands a RISK-APPROVED [`OrderIntent`] to
//! `broker.place()`; the broker is only ever a SINK, never a bypass.
//!
//! ## Safety invariants (this is the real-money path)
//! 1. **Paper is the default.** With no `[broker]` config (or `mode = "paper"`)
//!    the active broker is [`PaperBroker`], a thin wrapper over the existing
//!    [`cx_oms::Oms`] — behaviour is byte-for-byte today's paper engine, and
//!    there is ZERO live reach unless `mode = "ibkr"` is explicitly set.
//! 2. **Risk first, always.** Every order still passes the existing single
//!    path: fusion/command -> `RiskEngine::evaluate` -> kill switch ->
//!    reduce-only clamp -> THEN this broker. The IBKR adapter adds its own
//!    [`LiveGuard`] on TOP; it never relaxes a risk decision.
//! 3. **Two gates for live.** Reaching a real-money account requires BOTH
//!    `mode = "ibkr"` AND a live port WITH `allow_live = true`. A live port
//!    without `allow_live` is refused loudly ([`BrokerError::RefusedLive`]).
//! 4. **Kill reaches IBKR.** `flatten_all` cancels every working order then
//!    flattens every position; the synchronous Phase-1 kill still blocks new
//!    orders instantly upstream.
//! 5. **Live hard limits.** [`LiveGuard`] enforces `max_live_order_notional`,
//!    `max_live_position_notional`, and `max_live_daily_loss` (halt + flatten)
//!    inside `place()`.
//! 6. **Secrets never logged.** The IBKR socket is a direct localhost link to
//!    the operator's own Gateway — NOT through the hardened HTTP egress, and
//!    that is fine (documented in `docs/IBKR.md`). Account ids stay in
//!    [`cx_core::config::Secret`] and never appear in logs.
//!
//! The `ibkr` cargo feature compiles the real `ibapi` socket layer. Without
//! it, the safe abstraction — trait, paper broker, translation, guard, config
//! gating, fallback — still compiles and is fully unit-tested offline; the
//! IBKR wire methods return [`BrokerError::NotCompiled`], which triggers the
//! same loud fallback-to-paper as a failed connection.

mod guard;
mod ibkr;
mod paper;
mod translate;

use std::sync::Arc;

use async_trait::async_trait;

use cx_core::bus::Bus;
use cx_core::config::BrokerConfig;
use cx_core::events::{
    AccountSnapshot, AgentThought, BrokerStatus, EngineEvent, OrderIntent, Position,
};
use cx_core::time::now_ms;
use cx_core::types::Severity;
use cx_oms::Oms;

pub use guard::{eval_live_order, LiveGuard, LiveLimits, LiveVerdict};
pub use ibkr::book::{
    ApplyOutcome, DepthBook, DepthUpdate, OP_DELETE, OP_INSERT, OP_UPDATE, SIDE_ASK, SIDE_BID,
};
pub use ibkr::IbkrBroker;
// The LIVE equity depth/tape feed. Feature-gated exactly like the socket layer:
// the default paper build has no market-data reach at all. It publishes through
// caller-supplied sinks (cortexd wires them to cx-md's `publish_ibkr_*`), which
// is how cx-broker emits market data WITHOUT depending on the connectors.
#[cfg(feature = "ibkr")]
pub use ibkr::marketdata::{
    run_market_data, spawn_market_data, MarketDataConfig, MarketDataSink, DEPTH_ROWS,
};
pub use paper::PaperBroker;
pub use translate::{translate, IbkrContract, IbkrOrder};

/// The id of a placed order. `engine_id` is our monotonic [`OrderIntent::id`]
/// — the key the OMS, UI and `cancel` all use. `venue_id` is the broker's own
/// id (IBKR order id) when live, `None` for paper.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BrokerOrderId {
    pub engine_id: u64,
    pub venue_id: Option<i64>,
}

impl BrokerOrderId {
    pub fn paper(engine_id: u64) -> Self {
        Self {
            engine_id,
            venue_id: None,
        }
    }
    pub fn ibkr(engine_id: u64, venue_id: i64) -> Self {
        Self {
            engine_id,
            venue_id: Some(venue_id),
        }
    }
}

/// Errors from the live routing layer. Rejections carry a human-readable
/// reason; secrets/account ids never appear in any variant.
#[derive(Debug, thiserror::Error)]
pub enum BrokerError {
    /// A LIVE hard limit blocked the order (order/position notional or halt).
    #[error("live limit: {0}")]
    LiveLimit(String),
    /// A live port was configured without `allow_live` — refused to connect.
    #[error("refused: port {port} is a LIVE port but allow_live is false")]
    RefusedLive { port: u16 },
    /// The `ibkr` feature was not compiled in. The active-broker factory
    /// treats this exactly like a failed connection: loud fallback to paper.
    #[error("IBKR adapter not compiled (rebuild cortexd with --features ibkr-live)")]
    NotCompiled,
    /// The adapter is not connected to a Gateway.
    #[error("IBKR not connected")]
    NotConnected,
    /// A wire-level failure from the Gateway.
    #[error("IBKR error: {0}")]
    Ibkr(String),
}

/// The order-routing sink. One instance is the ACTIVE broker for the engine.
///
/// Fills/updates are streamed onto the [`Bus`] as ordinary [`EngineEvent`]s
/// (`OrderUpdate` / `Fill` / `Position` / `Account`): the paper broker's OMS
/// already publishes them; the IBKR adapter publishes them from a background
/// task fed by the Gateway's callbacks. The UI and agents see one uniform
/// event stream regardless of which broker is live.
#[async_trait]
pub trait Broker: Send + Sync {
    /// Short broker identity for logs/telemetry ("paper" | "ibkr").
    fn name(&self) -> &'static str;

    /// Establish the venue session. Paper is a no-op; IBKR opens the socket
    /// (and enforces the live-port gate first).
    async fn connect(&self) -> Result<(), BrokerError>;

    /// Tear down the venue session. Idempotent.
    async fn disconnect(&self);

    /// Route a RISK-APPROVED order to the venue. The IBKR adapter applies its
    /// LIVE hard limits here before the wire send.
    async fn place(&self, intent: OrderIntent) -> Result<BrokerOrderId, BrokerError>;

    /// Cancel one working order by its engine id. Returns whether a cancel was
    /// issued for a known working order.
    async fn cancel(&self, order_id: u64) -> bool;

    /// Cancel every working order at the venue.
    async fn cancel_all(&self, reason: &str);

    /// Emergency exit: cancel all working orders, then flatten every position
    /// (reduce-only). Returns the ids of the flattening orders.
    async fn flatten_all(&self, reason: &str) -> Vec<u64>;

    /// The venue's current positions.
    fn positions(&self) -> Vec<Position>;

    /// The venue's current account snapshot.
    fn account(&self) -> AccountSnapshot;

    /// The broker-link posture for the operator badge: which venue this sink
    /// is (`paper` / `ibkr_paper` / `ibkr_live`), whether its session is
    /// connected, and a masked account id. This is the single source of truth
    /// the engine publishes so the app can never mislabel real money as paper.
    fn status(&self) -> BrokerStatus;
}

/// Build the ACTIVE broker from config. PAPER-FIRST and fail-safe:
///
/// - `mode = "paper"` (the default) -> [`PaperBroker`] over the existing OMS.
/// - `mode = "ibkr"` -> attempt [`IbkrBroker::connect`]. On success the IBKR
///   adapter is returned; on ANY failure (refused live port, no Gateway,
///   feature not compiled) a loud **critical** thought is published and the
///   engine FALLS BACK to the paper broker. It never crashes and never
///   silently goes live.
pub async fn build_active_broker(
    cfg: &BrokerConfig,
    bus: Arc<Bus>,
    oms: Arc<Oms>,
) -> Arc<dyn Broker> {
    let paper: Arc<dyn Broker> = PaperBroker::new(Arc::clone(&oms));

    if cfg.mode != "ibkr" {
        tracing::info!("broker: paper exchange (default)");
        return paper;
    }

    let ibkr = IbkrBroker::new(cfg, Arc::clone(&bus));
    let live = cfg.is_live();
    match ibkr.connect().await {
        Ok(()) => {
            tracing::warn!(
                host = %cfg.ibkr_host,
                port = cfg.ibkr_port,
                live,
                route = %cfg.ibkr_route,
                "broker: IBKR connected ({})",
                if live { "LIVE / REAL MONEY" } else { "paper account" }
            );
            ibkr
        }
        Err(e) => {
            // Loud, critical, and NEVER live: fall back to the paper engine.
            let text = format!(
                "IBKR broker connect failed ({e}) — FALLING BACK TO PAPER. No live orders \
                 will be routed. Fix the Gateway/config and restart to go live."
            );
            tracing::error!("{text}");
            bus.publish(EngineEvent::Thought(AgentThought {
                agent: "broker".into(),
                squadron: "execution".into(),
                severity: Severity::Critical,
                text,
                tags: vec!["broker".into(), "ibkr".into(), "fallback".into()],
                confidence: 1.0,
                symbol: None,
                ts_ms: now_ms(),
            }));
            paper
        }
    }
}
