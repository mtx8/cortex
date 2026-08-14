//! IbkrBroker — the Interactive Brokers routing sink (PAPER-FIRST, DMA-capable).
//!
//! Structure: everything safety-relevant is ALWAYS compiled and unit-tested
//! offline — the live-port gate, the reduce-only clamp, the [`LiveGuard`] hard
//! limits, the OrderIntent->IBKR translation, and the position/account caches.
//! Only the raw socket calls to the Gateway live behind the `ibkr` cargo
//! feature; without it those methods return [`BrokerError::NotCompiled`], which
//! the active-broker factory treats as a failed connection (loud fallback to
//! paper). The socket is a DIRECT localhost link to the operator's own
//! Gateway — deliberately NOT routed through the hardened HTTP egress (that
//! chokepoint is for public market/AI REST; a broker socket is a different
//! trust domain). See docs/IBKR.md.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;

use cx_core::bus::Bus;
use cx_core::config::{is_ibkr_live_port, BrokerConfig};
use cx_core::events::{
    mask_account, AccountSnapshot, AgentThought, BrokerMode, BrokerStatus, EngineEvent, OrderIntent,
    OrderStatus, OrderUpdate, Position,
};
use cx_core::time::now_ms;
use cx_core::types::asset_class_of;
use cx_core::types::{AssetClass, Severity};

use crate::guard::{LiveGuard, LiveLimits, LiveVerdict};
use crate::{Broker, BrokerError, BrokerOrderId};

const POS_EPS: f64 = 1e-12;

/// The Interactive Brokers adapter. Several fields (host/client_id/account/
/// route/order_map) are read only by the feature-gated wire layer; they carry
/// a scoped dead-code allowance so the default paper build stays warning-clean.
#[cfg_attr(not(feature = "ibkr"), allow(dead_code))]
pub struct IbkrBroker {
    bus: Arc<Bus>,
    host: String,
    port: u16,
    client_id: i32,
    /// The account id, exposed only at the wire boundary — never logged.
    account: String,
    route: String,
    allow_live: bool,
    /// Arc so background bridge tasks (feature `ibkr`) can share the latch.
    guard: Arc<LiveGuard>,
    /// Whether the Gateway socket session is up. Set by `connect_wire`, cleared
    /// on disconnect; read by `status()` for the broker badge and by the
    /// preflight sync gate. False in the always-compiled offline build (the
    /// wire is never connected there), so the sync gate never fires in tests.
    connected: Arc<AtomicBool>,
    /// Whether the FIRST full IBKR position snapshot has arrived (the
    /// `PositionEnd` marker). Until then the tracked position book is phantom-
    /// flat, so — while `connected` — the preflight HOLDS every order rather
    /// than size/clamp against an unreconciled book (CLAUDE.md rule 9).
    positions_synced: Arc<AtomicBool>,
    /// Last mark per symbol, fed from Tick events, used to size market-order
    /// notionals for the live guard when the order carries no limit price.
    last_px: Arc<Mutex<HashMap<String, f64>>>,
    /// Live positions tracked from IBKR position callbacks.
    positions: Arc<Mutex<HashMap<String, Position>>>,
    /// Latest account snapshot derived from IBKR account/PnL callbacks.
    account_snap: Arc<Mutex<Option<AccountSnapshot>>>,
    /// engine order id -> IBKR venue order id, so `cancel` can address it.
    order_map: Arc<Mutex<HashMap<u64, i32>>>,
    #[cfg(feature = "ibkr")]
    client: tokio::sync::Mutex<Option<Arc<ibapi::Client>>>,
}

impl IbkrBroker {
    pub fn new(cfg: &BrokerConfig, bus: Arc<Bus>) -> Arc<Self> {
        Arc::new(Self {
            bus,
            host: cfg.ibkr_host.clone(),
            port: cfg.ibkr_port,
            client_id: cfg.ibkr_client_id,
            account: cfg.ibkr_account.expose().to_string(),
            route: cfg.ibkr_route.clone(),
            allow_live: cfg.allow_live,
            guard: Arc::new(LiveGuard::new(LiveLimits::from_cfg(cfg), now_ms())),
            connected: Arc::new(AtomicBool::new(false)),
            positions_synced: Arc::new(AtomicBool::new(false)),
            last_px: Arc::new(Mutex::new(HashMap::new())),
            positions: Arc::new(Mutex::new(HashMap::new())),
            account_snap: Arc::new(Mutex::new(None)),
            order_map: Arc::new(Mutex::new(HashMap::new())),
            #[cfg(feature = "ibkr")]
            client: tokio::sync::Mutex::new(None),
        })
    }

    /// Whether this adapter is configured for a real-money session.
    pub fn is_live(&self) -> bool {
        is_ibkr_live_port(self.port) && self.allow_live
    }

    /// Record a mark for `symbol` — used by the guard to price market orders.
    pub fn note_price(&self, symbol: &str, px: f64) {
        if px.is_finite() && px > 0.0 {
            self.lock_px().insert(symbol.to_string(), px);
        }
    }

    fn last_price(&self, symbol: &str) -> Option<f64> {
        self.lock_px().get(symbol).copied()
    }

    fn live_pos_qty(&self, symbol: &str) -> f64 {
        self.lock_pos()
            .get(symbol)
            .map(|p| p.qty)
            .filter(|q| q.is_finite())
            .unwrap_or(0.0)
    }

    /// The live-port gate. Refuses a real-money port unless the operator set
    /// `allow_live`. Always compiled — the first thing `connect` checks.
    fn refuse_if_live_locked(&self) -> Result<(), BrokerError> {
        if is_ibkr_live_port(self.port) && !self.allow_live {
            tracing::error!(
                port = self.port,
                "REFUSING IBKR connection: {} is a LIVE (real-money) port but allow_live is \
                 false. Set broker.allow_live = true to trade live, or use a PAPER port.",
                self.port
            );
            return Err(BrokerError::RefusedLive { port: self.port });
        }
        Ok(())
    }

    /// Publish a bus OrderUpdate marking an order canceled with `reason` — how
    /// a guard rejection becomes visible to the UI/agents, mirroring the OMS.
    fn publish_canceled(&self, intent: &OrderIntent, reason: String) {
        self.bus.publish(EngineEvent::OrderUpdate(OrderUpdate {
            order_id: intent.id,
            intent: intent.clone(),
            status: OrderStatus::Canceled { reason },
            filled_qty: 0.0,
            avg_fill_px: 0.0,
            ts_ms: now_ms(),
        }));
    }

    /// The shared, always-compiled pre-flight for `place`: position-sync gate,
    /// reduce-only clamp, no-flip clamp against the tracked live position, then
    /// the LIVE hard-limit guard. On rejection it publishes a Canceled update
    /// and returns the error; on success it returns the (possibly clamped)
    /// intent ready for the wire.
    fn preflight(&self, mut intent: OrderIntent) -> Result<OrderIntent, BrokerError> {
        // Position-reconciliation gate (CLAUDE.md rule 9): while the socket is
        // up but the first IBKR position snapshot has NOT arrived, the tracked
        // book is phantom-flat — sizing and the reduce-only/no-flip clamps
        // below would evaluate against zero. HOLD every order until the book is
        // reconciled rather than clamp against nothing. Never fires offline
        // (connected is false in the unit-test build).
        if self.connected.load(Ordering::Acquire) && !self.positions_synced.load(Ordering::Acquire)
        {
            let reason =
                "IBKR position book not yet reconciled; holding order until positions sync".to_string();
            self.publish_canceled(&intent, reason.clone());
            return Err(BrokerError::LiveLimit(reason));
        }

        // v1 routes US equities only; crypto stays on the paper/Coinbase path.
        if asset_class_of(&intent.symbol) != AssetClass::Equity {
            let reason = format!(
                "IBKR adapter routes US equities only in v1; {} not routed live",
                intent.symbol
            );
            self.publish_canceled(&intent, reason.clone());
            return Err(BrokerError::LiveLimit(reason));
        }

        let live = self.live_pos_qty(&intent.symbol);
        // Reduce-only clamp: an exit can never exceed the live position, and a
        // reduce-only order with nothing to reduce is refused (mirrors the OMS
        // fill-time clamp, enforced again here on the tracked live book).
        if intent.reduce_only {
            if live.abs() <= POS_EPS || (live > 0.0) == (intent.side.sign() > 0.0) {
                let reason = "reduce-only: nothing to reduce".to_string();
                self.publish_canceled(&intent, reason.clone());
                return Err(BrokerError::LiveLimit(reason));
            }
            if intent.qty > live.abs() {
                intent.qty = live.abs();
            }
        } else if live.abs() > POS_EPS {
            // No-flip backstop. The upstream RiskEngine sizes reduce-only vs
            // new-risk against the PAPER OMS book, which stays flat in live
            // mode (IBKR fills never reach the OMS) — so a signal reversal can
            // arrive here as a full-size, NON-reduce-only order that would
            // cross zero and FLIP the real position. Reconciled against the
            // tracked LIVE book (IBKR position callbacks), an order that
            // opposes an open position may at most FLATTEN it: clamp to |live|
            // and treat it as a reduce-only exit. Reversing direction takes two
            // explicit orders (flatten, then open) — never one silent flip.
            let opposes = (live > 0.0) != (intent.side.sign() > 0.0);
            if opposes && intent.qty > live.abs() + POS_EPS {
                let clamped = live.abs();
                tracing::warn!(
                    order = intent.id,
                    from = intent.qty,
                    to = clamped,
                    "live no-flip clamp: order would flip the live position; clamping to flat"
                );
                self.bus.publish(EngineEvent::Thought(AgentThought {
                    agent: "broker".into(),
                    squadron: "execution".into(),
                    severity: Severity::Warning,
                    text: format!(
                        "no-flip clamp on {}: {:.6} would flip the live position; clamped to \
                         {:.6} (flatten only). A reversal must be a separate order.",
                        intent.symbol, intent.qty, clamped
                    ),
                    tags: vec!["broker".into(), "ibkr".into(), "no-flip".into()],
                    confidence: 1.0,
                    symbol: Some(intent.symbol.clone()),
                    ts_ms: now_ms(),
                }));
                intent.qty = clamped;
                intent.reduce_only = true;
            }
        }

        // Price the guard off the limit price, else the last mark.
        let price = intent
            .limit_px
            .filter(|p| p.is_finite() && *p > 0.0)
            .or_else(|| self.last_price(&intent.symbol))
            .unwrap_or(f64::NAN);
        match self.guard.check(price, &intent, live) {
            LiveVerdict::Allow => Ok(intent),
            LiveVerdict::Reject(reason) => {
                tracing::warn!(order = intent.id, "live guard rejected order: {reason}");
                self.publish_canceled(&intent, format!("live guard: {reason}"));
                Err(BrokerError::LiveLimit(reason))
            }
        }
    }

    fn lock_px(&self) -> std::sync::MutexGuard<'_, HashMap<String, f64>> {
        self.last_px.lock().unwrap_or_else(|p| p.into_inner())
    }
    fn lock_pos(&self) -> std::sync::MutexGuard<'_, HashMap<String, Position>> {
        self.positions.lock().unwrap_or_else(|p| p.into_inner())
    }
    #[cfg_attr(not(feature = "ibkr"), allow(dead_code))]
    fn lock_map(&self) -> std::sync::MutexGuard<'_, HashMap<u64, i32>> {
        self.order_map.lock().unwrap_or_else(|p| p.into_inner())
    }
}

/// An all-flat account snapshot for before the first IBKR callback arrives.
fn empty_account_snapshot() -> AccountSnapshot {
    AccountSnapshot {
        equity: 0.0,
        cash: 0.0,
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

#[async_trait]
impl Broker for IbkrBroker {
    fn name(&self) -> &'static str {
        "ibkr"
    }

    async fn connect(&self) -> Result<(), BrokerError> {
        // Gate #1 (defense in depth with config.validate): never open a live
        // socket without an explicit allow_live.
        self.refuse_if_live_locked()?;
        self.connect_wire().await
    }

    async fn disconnect(&self) {
        self.disconnect_wire().await;
    }

    async fn place(&self, intent: OrderIntent) -> Result<BrokerOrderId, BrokerError> {
        let intent = self.preflight(intent)?;
        self.place_wire(intent).await
    }

    async fn cancel(&self, order_id: u64) -> bool {
        self.cancel_wire(order_id).await
    }

    async fn cancel_all(&self, reason: &str) {
        self.cancel_all_wire(reason).await;
    }

    async fn flatten_all(&self, reason: &str) -> Vec<u64> {
        self.flatten_all_wire(reason).await
    }

    fn positions(&self) -> Vec<Position> {
        let mut v: Vec<Position> = self.lock_pos().values().cloned().collect();
        v.sort_by(|a, b| a.symbol.cmp(&b.symbol));
        v
    }

    fn account(&self) -> AccountSnapshot {
        self.account_snap
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .clone()
            .unwrap_or_else(empty_account_snapshot)
    }

    fn status(&self) -> BrokerStatus {
        // Mode is the real-money posture: ibkr_live only when BOTH live gates
        // (live port + allow_live) are satisfied, else ibkr_paper. The app
        // renders LIVE only when this is ibkr_live AND connected is true, so a
        // dropped socket can never keep screaming LIVE.
        BrokerStatus {
            mode: if self.is_live() {
                BrokerMode::IbkrLive
            } else {
                BrokerMode::IbkrPaper
            },
            connected: self.connected.load(Ordering::Acquire),
            account_masked: mask_account(&self.account),
        }
    }
}

// ---------------------------------------------------------------------------
// Wire layer. Two implementations selected by the `ibkr` feature. Both honour
// the SAME `Broker` trait; the safe pre-flight above runs regardless.
// ---------------------------------------------------------------------------

#[cfg(not(feature = "ibkr"))]
impl IbkrBroker {
    async fn connect_wire(&self) -> Result<(), BrokerError> {
        // Passed the live-port gate but the socket layer is not compiled: the
        // factory treats this exactly like a failed connection -> paper.
        Err(BrokerError::NotCompiled)
    }
    async fn disconnect_wire(&self) {}
    async fn place_wire(&self, _intent: OrderIntent) -> Result<BrokerOrderId, BrokerError> {
        Err(BrokerError::NotCompiled)
    }
    async fn cancel_wire(&self, _order_id: u64) -> bool {
        false
    }
    async fn cancel_all_wire(&self, _reason: &str) {}
    async fn flatten_all_wire(&self, _reason: &str) -> Vec<u64> {
        Vec::new()
    }
}

// The incremental depth ladder. ALWAYS compiled — it imports no `ibapi` type,
// so the logic that can actually be wrong is unit-tested in the default paper
// build instead of only being observable against a live Gateway. The
// feature-gated wire layer merely maps `MarketDepth`/`MarketDepthL2` onto its
// input type.
pub mod book;

/// The LIVE equity market-data feed (reqMktDepth + tick-by-tick AllLast). It
/// runs BESIDE the order adapter on its own Gateway session and cannot touch
/// the order path; see the module docs for why the separation is deliberate.
#[cfg(feature = "ibkr")]
pub mod marketdata;

#[cfg(feature = "ibkr")]
mod wire;

#[cfg(test)]
mod tests {
    use super::*;
    use cx_core::events::OrderSource;
    use cx_core::types::{OrderType, Side, Tif};

    fn cfg(port: u16, allow_live: bool) -> BrokerConfig {
        BrokerConfig {
            mode: "ibkr".into(),
            ibkr_port: port,
            allow_live,
            max_live_order_notional: 2_000.0,
            max_live_position_notional: 5_000.0,
            max_live_daily_loss: 500.0,
            ..Default::default()
        }
    }

    fn broker(port: u16, allow_live: bool) -> Arc<IbkrBroker> {
        IbkrBroker::new(&cfg(port, allow_live), Bus::new(256))
    }

    fn market(symbol: &str, side: Side, qty: f64) -> OrderIntent {
        OrderIntent {
            id: 42,
            symbol: symbol.into(),
            side,
            qty,
            order_type: OrderType::Market,
            limit_px: None,
            stop_px: None,
            tif: Tif::Ioc,
            reduce_only: false,
            source: OrderSource::Strategy("fusion".into()),
            rationale: "test".into(),
            ts_ms: now_ms(),
        }
    }

    #[tokio::test]
    async fn connect_refuses_live_port_without_allow_live() {
        // 7496 (TWS live) and 4001 (Gateway live) both refuse.
        for port in [7496u16, 4001] {
            let b = broker(port, false);
            assert!(b.is_live() == false); // not live until allow_live
            match b.connect().await {
                Err(BrokerError::RefusedLive { port: p }) => assert_eq!(p, port),
                other => panic!("expected RefusedLive for {port}, got {other:?}"),
            }
        }
    }

    #[tokio::test]
    async fn connect_passes_gate_on_paper_port_then_reports_wire_state() {
        // A paper port passes the live gate; in the default (no-feature) build
        // the wire is not compiled, so connect reports NotCompiled — proving
        // the gate let it through rather than refusing.
        let b = broker(7497, false);
        match b.connect().await {
            #[cfg(not(feature = "ibkr"))]
            Err(BrokerError::NotCompiled) => {}
            #[cfg(feature = "ibkr")]
            _ => {} // with a real gateway this may connect or Ibkr-error; both fine
            #[cfg(not(feature = "ibkr"))]
            other => panic!("expected NotCompiled on paper port, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn live_guard_rejects_over_notional_before_the_wire() {
        let b = broker(7497, false);
        b.note_price("AAPL", 100.0);
        // 30 * 100 = 3000 > 2000 order cap -> LiveLimit, never reaches wire.
        match b.place(market("AAPL", Side::Buy, 30.0)).await {
            Err(BrokerError::LiveLimit(r)) => assert!(r.contains("max_live_order_notional"), "{r}"),
            other => panic!("expected LiveLimit rejection, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn within_limits_passes_guard_then_hits_the_wire() {
        let b = broker(7497, false);
        b.note_price("AAPL", 100.0);
        // 5 * 100 = 500 <= 2000: passes the guard, then the (uncompiled) wire.
        let res = b.place(market("AAPL", Side::Buy, 5.0)).await;
        #[cfg(not(feature = "ibkr"))]
        assert!(matches!(res, Err(BrokerError::NotCompiled)), "guard passed, wire stub");
        #[cfg(feature = "ibkr")]
        let _ = res; // depends on a live gateway
    }

    #[tokio::test]
    async fn crypto_is_not_routed_live_in_v1() {
        let b = broker(7497, false);
        b.note_price("BTC-USD", 50_000.0);
        match b.place(market("BTC-USD", Side::Buy, 0.001)).await {
            Err(BrokerError::LiveLimit(r)) => assert!(r.contains("equities only"), "{r}"),
            other => panic!("expected crypto to be refused live, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn reduce_only_with_no_position_is_refused() {
        let b = broker(7497, false);
        b.note_price("AAPL", 100.0);
        let mut exit = market("AAPL", Side::Sell, 1.0);
        exit.reduce_only = true;
        match b.place(exit).await {
            Err(BrokerError::LiveLimit(r)) => assert!(r.contains("nothing to reduce"), "{r}"),
            other => panic!("expected reduce-only refusal, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn account_and_positions_default_empty_before_callbacks() {
        let b = broker(7497, false);
        assert!(b.positions().is_empty());
        let a = b.account();
        assert_eq!(a.equity, 0.0);
        assert_eq!(a.open_orders, 0);
    }

    /// Seed a tracked live position, mirroring what the IBKR positions bridge
    /// would install from a Position callback.
    fn seed_position(b: &IbkrBroker, symbol: &str, qty: f64) {
        b.positions.lock().unwrap().insert(
            symbol.to_string(),
            Position {
                symbol: symbol.into(),
                qty,
                avg_px: 100.0,
                mark_px: 100.0,
                unrealized_pnl: 0.0,
                realized_pnl: 0.0,
                ts_ms: now_ms(),
            },
        );
    }

    #[test]
    fn no_flip_clamp_flattens_an_order_that_would_reverse_a_live_long() {
        // The RiskEngine sized this NON-reduce-only sell against a phantom-flat
        // paper book; against the real long-10 it would flip to short-5 and the
        // guard (order 1500<=2000, resulting 500<=5000) would WAVE IT THROUGH.
        // The no-flip clamp caps it to |live| and marks it a reduce-only exit.
        let b = broker(7497, false);
        b.note_price("AAPL", 100.0);
        seed_position(&b, "AAPL", 10.0);
        let out = b.preflight(market("AAPL", Side::Sell, 15.0)).expect("clamped, not rejected");
        assert!((out.qty - 10.0).abs() < 1e-9, "clamped to flat, got {}", out.qty);
        assert!(out.reduce_only, "a clamped flip becomes a reduce-only exit");
        assert_eq!(out.side, Side::Sell);
    }

    #[test]
    fn no_flip_clamp_flattens_an_order_that_would_reverse_a_live_short() {
        let b = broker(7497, false);
        b.note_price("AAPL", 100.0);
        seed_position(&b, "AAPL", -10.0);
        let out = b.preflight(market("AAPL", Side::Buy, 15.0)).expect("clamped, not rejected");
        assert!((out.qty - 10.0).abs() < 1e-9, "clamped to flat, got {}", out.qty);
        assert!(out.reduce_only);
        assert_eq!(out.side, Side::Buy);
    }

    #[test]
    fn opposing_order_within_the_position_is_not_clamped() {
        // A partial reducer that does NOT cross zero is left as-is (no flip).
        let b = broker(7497, false);
        b.note_price("AAPL", 100.0);
        seed_position(&b, "AAPL", 10.0);
        let out = b.preflight(market("AAPL", Side::Sell, 5.0)).expect("passes guard");
        assert!((out.qty - 5.0).abs() < 1e-9);
        assert!(!out.reduce_only, "a non-flip order keeps its provenance");
    }

    #[test]
    fn same_side_add_is_never_treated_as_a_flip() {
        let b = broker(7497, false);
        b.note_price("AAPL", 100.0);
        seed_position(&b, "AAPL", 10.0);
        // Buying MORE of a long can never cross zero; the position-notional
        // guard (15*100=1500<=5000) governs it, not the no-flip clamp.
        let out = b.preflight(market("AAPL", Side::Buy, 5.0)).expect("passes guard");
        assert!((out.qty - 5.0).abs() < 1e-9);
        assert!(!out.reduce_only);
    }

    #[test]
    fn preflight_holds_orders_until_the_position_book_is_reconciled() {
        // While the socket is up but the first IBKR position snapshot has not
        // arrived, every order is HELD — sizing against a phantom-flat book is
        // exactly what stacks on / mis-clamps against a real position.
        let b = broker(7497, false);
        b.note_price("AAPL", 100.0);
        b.connected.store(true, Ordering::Release);
        b.positions_synced.store(false, Ordering::Release);
        match b.preflight(market("AAPL", Side::Buy, 5.0)) {
            Err(BrokerError::LiveLimit(r)) => assert!(r.contains("reconciled"), "{r}"),
            other => panic!("expected a sync-gate hold, got {other:?}"),
        }
        // Once the book syncs, the same order flows through to the guard.
        b.positions_synced.store(true, Ordering::Release);
        let out = b.preflight(market("AAPL", Side::Buy, 5.0)).expect("passes once synced");
        assert!((out.qty - 5.0).abs() < 1e-9);
    }

    #[test]
    fn status_reports_paper_when_not_live_and_masks_the_account() {
        // A paper-port ibkr adapter is ibkr_paper, and its account id is masked.
        let mut c = cfg(7497, false);
        c.ibkr_account = cx_core::config::Secret("DU1234567".into());
        let b = IbkrBroker::new(&c, Bus::new(256));
        let s = b.status();
        assert_eq!(s.mode, BrokerMode::IbkrPaper);
        assert!(!s.connected, "no socket yet");
        assert_eq!(s.account_masked.as_deref(), Some("DU*****67"));
        assert!(!s.account_masked.unwrap().contains("12345"), "raw id must not leak");
    }

    #[test]
    fn status_reports_live_only_when_the_gates_are_satisfied() {
        // A live port WITH allow_live reads ibkr_live; connected still tracks
        // the socket (false until connect_wire), so the app cannot render LIVE.
        let mut c = cfg(7496, true);
        c.ibkr_account = cx_core::config::Secret("U7654321".into());
        let b = IbkrBroker::new(&c, Bus::new(256));
        let s = b.status();
        assert_eq!(s.mode, BrokerMode::IbkrLive);
        assert!(!s.connected);
    }
}
