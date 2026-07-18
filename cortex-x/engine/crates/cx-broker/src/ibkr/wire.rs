//! The real IB Gateway / TWS socket layer — compiled ONLY under the `ibkr`
//! feature. It is a direct localhost TCP link to the operator's own Gateway
//! (NOT the hardened HTTP egress; a broker socket is a separate trust domain).
//!
//! This module never re-implements a safety check: the live-port gate,
//! reduce-only clamp and LIVE hard-limit guard all run in the always-compiled
//! [`super::IbkrBroker::preflight`] / `connect` before any function here is
//! reached. Its job is purely: translate -> send, and bridge IBKR callbacks
//! (positions, PnL) back onto the bus + into the daily-loss halt.
//!
//! It cannot be exercised end-to-end offline; it is compile-verified against
//! `ibapi` 3.3 and brought up against a live paper Gateway per docs/IBKR.md.

use std::sync::atomic::Ordering;
use std::sync::Arc;

use ibapi::accounts::types::AccountId;
use ibapi::prelude::*;

use cx_core::bus::Bus;
use cx_core::events::{
    AccountSnapshot, AgentThought, EngineEvent, OrderIntent, OrderSource, Position as CxPosition,
};
use cx_core::ids::next_order_id;
use cx_core::time::now_ms;
use cx_core::types::{OrderType, Severity, Side, Tif};

use super::{empty_account_snapshot, IbkrBroker, POS_EPS};
use crate::translate::translate;
use crate::{BrokerError, BrokerOrderId};

impl IbkrBroker {
    pub(super) async fn connect_wire(&self) -> Result<(), BrokerError> {
        let addr = format!("{}:{}", self.host, self.port);
        let client = Client::connect(&addr, self.client_id)
            .await
            .map_err(|e| BrokerError::Ibkr(e.to_string()))?;
        let client = Arc::new(client);
        *self.client.lock().await = Some(Arc::clone(&client));

        // A fresh session starts UNRECONCILED: the position book must re-sync
        // (first PositionEnd) before any order is sized/clamped against it. The
        // preflight sync gate holds orders until then (CLAUDE.md rule 9).
        self.positions_synced.store(false, Ordering::Release);

        // Bridge the Gateway's position + PnL callbacks onto the bus and into
        // the guard. Order/fill updates ride the position/account stream in
        // v1; a dedicated executions bridge is a documented follow-up.
        self.spawn_positions_bridge(Arc::clone(&client));
        self.spawn_pnl_bridge(Arc::clone(&client));
        // Feed the guard's last-mark cache from the engine's own tick stream so
        // it can size market-order notionals (a missing mark fails closed).
        self.spawn_price_bridge();

        // The socket is up: the broker badge now reports connected, and the
        // preflight sync gate holds orders only until the first PositionEnd.
        self.connected.store(true, Ordering::Release);
        Ok(())
    }

    /// Cache the latest mark per symbol from the engine's Tick stream, so the
    /// LIVE guard can price market orders that carry no limit price.
    fn spawn_price_bridge(&self) {
        let last_px = Arc::clone(&self.last_px);
        let mut rx = self.bus.subscribe();
        tokio::spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(ev) => {
                        if let EngineEvent::Tick(t) = ev.as_ref() {
                            if t.price.is_finite() && t.price > 0.0 {
                                last_px
                                    .lock()
                                    .unwrap_or_else(|e| e.into_inner())
                                    .insert(t.symbol.clone(), t.price);
                            }
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                }
            }
        });
    }

    pub(super) async fn disconnect_wire(&self) {
        // Down first: the badge must never read connected/LIVE while the socket
        // is torn down, and the sync gate re-arms for any future reconnect.
        self.connected.store(false, Ordering::Release);
        self.positions_synced.store(false, Ordering::Release);
        if let Some(client) = self.client.lock().await.take() {
            client.disconnect().await;
        }
    }

    pub(super) async fn place_wire(
        &self,
        intent: OrderIntent,
    ) -> Result<BrokerOrderId, BrokerError> {
        let client = self.client_arc().await?;
        let venue_id = submit_intent(&client, &intent, &self.route).await?;
        self.lock_map().insert(intent.id, venue_id);
        Ok(BrokerOrderId::ibkr(intent.id, venue_id as i64))
    }

    pub(super) async fn cancel_wire(&self, order_id: u64) -> bool {
        let venue_id = match self.lock_map().get(&order_id).copied() {
            Some(v) => v,
            None => return false,
        };
        let client = match self.client_arc().await {
            Ok(c) => c,
            Err(_) => return false,
        };
        match client.cancel_order(venue_id, "").await {
            Ok(_) => true,
            Err(e) => {
                tracing::warn!(order = order_id, "IBKR cancel failed: {e}");
                false
            }
        }
    }

    pub(super) async fn cancel_all_wire(&self, reason: &str) {
        if let Ok(client) = self.client_arc().await {
            if let Err(e) = client.global_cancel().await {
                tracing::error!("IBKR global cancel failed ({reason}): {e}");
            }
        }
    }

    pub(super) async fn flatten_all_wire(&self, reason: &str) -> Vec<u64> {
        let client = match self.client_arc().await {
            Ok(c) => c,
            Err(e) => {
                tracing::error!("IBKR flatten failed ({reason}): {e}");
                return Vec::new();
            }
        };
        let positions = self.nonzero_positions();
        wire_flatten(&client, &self.bus, positions, &self.route).await
    }

    async fn client_arc(&self) -> Result<Arc<Client>, BrokerError> {
        self.client
            .lock()
            .await
            .as_ref()
            .cloned()
            .ok_or(BrokerError::NotConnected)
    }

    fn nonzero_positions(&self) -> Vec<(String, f64)> {
        self.lock_pos()
            .values()
            .filter(|p| p.qty.abs() > POS_EPS)
            .map(|p| (p.symbol.clone(), p.qty))
            .collect()
    }

    /// Stream position updates -> cache + bus. The first `PositionEnd` marks
    /// the book reconciled and opens the preflight sync gate.
    fn spawn_positions_bridge(&self, client: Arc<Client>) {
        let positions = Arc::clone(&self.positions);
        let positions_synced = Arc::clone(&self.positions_synced);
        let bus = Arc::clone(&self.bus);
        tokio::spawn(async move {
            let sub = match client.positions().await {
                Ok(s) => s,
                Err(e) => {
                    tracing::error!("IBKR positions subscription failed: {e}");
                    return;
                }
            };
            let mut data = sub.filter_data();
            while let Some(item) = data.next().await {
                let update = match item {
                    Ok(u) => u,
                    Err(e) => {
                        tracing::warn!("IBKR position stream error: {e}");
                        continue;
                    }
                };
                match update {
                    PositionUpdate::Position(p) => {
                        let symbol = p.contract.symbol.to_string();
                        let ev = CxPosition {
                            symbol: symbol.clone(),
                            qty: p.position,
                            avg_px: p.average_cost,
                            mark_px: p.average_cost,
                            unrealized_pnl: 0.0,
                            realized_pnl: 0.0,
                            ts_ms: now_ms(),
                        };
                        positions
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .insert(symbol, ev.clone());
                        bus.publish(EngineEvent::Position(ev));
                    }
                    PositionUpdate::PositionEnd => {
                        // Full snapshot delivered: the tracked book is now
                        // reconciled, so the preflight sync gate opens. Order
                        // placement was HELD until exactly this point so every
                        // reduce-only / no-flip clamp sizes against a real book.
                        positions_synced.store(true, Ordering::Release);
                    }
                }
            }
        });
    }

    /// Stream PnL -> account snapshot + daily-loss halt (+ flatten on breach).
    fn spawn_pnl_bridge(&self, client: Arc<Client>) {
        if self.account.is_empty() {
            // With config now requiring an account whenever mode == "ibkr",
            // this is normally unreachable — but if it is ever hit, the
            // max_live_daily_loss circuit breaker is UNARMED, which the
            // operator must not be able to miss: a loud critical thought, not a
            // warn buried in logs.
            let text = "IBKR: no account id configured — the max_live_daily_loss circuit breaker \
                        is UNARMED (cannot subscribe to PnL). Set broker.ibkr_account."
                .to_string();
            tracing::error!("{text}");
            self.bus.publish(EngineEvent::Thought(AgentThought {
                agent: "broker".into(),
                squadron: "execution".into(),
                severity: Severity::Critical,
                text,
                tags: vec![
                    "broker".into(),
                    "ibkr".into(),
                    "halt".into(),
                    "unarmed".into(),
                ],
                confidence: 1.0,
                symbol: None,
                ts_ms: now_ms(),
            }));
            return;
        }
        let account = AccountId::from(self.account.as_str());
        let guard = Arc::clone(&self.guard);
        let account_snap = Arc::clone(&self.account_snap);
        let positions = Arc::clone(&self.positions);
        let bus = Arc::clone(&self.bus);
        let route = self.route.clone();
        tokio::spawn(async move {
            let sub = match client.pnl(&account, None).await {
                Ok(s) => s,
                Err(e) => {
                    tracing::error!("IBKR PnL subscription failed: {e}");
                    return;
                }
            };
            let mut data = sub.filter_data();
            while let Some(item) = data.next().await {
                let pnl = match item {
                    Ok(p) => p,
                    Err(e) => {
                        tracing::warn!("IBKR PnL stream error: {e}");
                        continue;
                    }
                };
                // Refresh the account snapshot the UI/risk view read.
                {
                    let mut slot = account_snap.lock().unwrap_or_else(|e| e.into_inner());
                    let mut snap: AccountSnapshot =
                        slot.clone().unwrap_or_else(empty_account_snapshot);
                    snap.realized_pnl_day = pnl.realized_pnl.unwrap_or(snap.realized_pnl_day);
                    snap.unrealized_pnl = pnl.unrealized_pnl.unwrap_or(snap.unrealized_pnl);
                    snap.ts_ms = now_ms();
                    *slot = Some(snap.clone());
                    bus.publish(EngineEvent::Account(snap));
                }
                // The daily-loss halt latch. `daily_pnl` is IBKR's running day
                // P&L; a fresh breach halts new orders (instantly, via the
                // guard) and flattens once.
                if guard.on_day_pnl(pnl.daily_pnl, now_ms()) {
                    let text = format!(
                        "LIVE daily-loss halt: day PnL {:.2} breached the limit — cancelling \
                         working orders and flattening. New orders are blocked for the session.",
                        pnl.daily_pnl
                    );
                    tracing::error!("{text}");
                    bus.publish(EngineEvent::Thought(AgentThought {
                        agent: "broker".into(),
                        squadron: "execution".into(),
                        severity: Severity::Critical,
                        text,
                        tags: vec!["broker".into(), "ibkr".into(), "halt".into()],
                        confidence: 1.0,
                        symbol: None,
                        ts_ms: now_ms(),
                    }));
                    let snapshot: Vec<(String, f64)> = positions
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .values()
                        .filter(|p| p.qty.abs() > POS_EPS)
                        .map(|p| (p.symbol.clone(), p.qty))
                        .collect();
                    wire_flatten(&client, &bus, snapshot, &route).await;
                }
            }
        });
    }
}

/// Build an IBKR contract + order from an intent and submit it. Returns the
/// venue order id. Equities only (the caller's preflight guarantees it).
async fn submit_intent(
    client: &Client,
    intent: &OrderIntent,
    route: &str,
) -> Result<i32, BrokerError> {
    let (ir_contract, _ir_order) = translate(intent, route);
    let contract = Contract::stock(ir_contract.symbol.as_str())
        .on_exchange(ir_contract.exchange.as_str())
        .in_currency(ir_contract.currency.as_str())
        .build();

    let qty = intent.qty;
    let builder = client.order(&contract);
    let builder = match intent.side {
        Side::Buy => builder.buy(qty),
        Side::Sell => builder.sell(qty),
    };
    let builder = match intent.order_type {
        OrderType::Market => builder.market(),
        OrderType::Limit => builder.limit(intent.limit_px.unwrap_or(0.0)),
        OrderType::Stop => builder.stop(intent.stop_px.unwrap_or(0.0)),
        OrderType::StopLimit => {
            builder.stop_limit(intent.stop_px.unwrap_or(0.0), intent.limit_px.unwrap_or(0.0))
        }
    };
    let builder = match intent.tif {
        Tif::Gtc => builder.good_till_cancel(),
        Tif::Ioc => builder.immediate_or_cancel(),
        Tif::Day => builder.day_order(),
    };
    let order_id = builder
        .submit()
        .await
        .map_err(|e| BrokerError::Ibkr(e.to_string()))?;
    Ok(order_id.0)
}

/// Cancel all working orders, then submit a reduce-only market exit for each
/// nonzero position. Returns the engine ids of the flattening orders.
async fn wire_flatten(
    client: &Client,
    _bus: &Bus,
    positions: Vec<(String, f64)>,
    route: &str,
) -> Vec<u64> {
    if let Err(e) = client.global_cancel().await {
        tracing::error!("IBKR global cancel during flatten failed: {e}");
    }
    let mut ids = Vec::with_capacity(positions.len());
    for (symbol, qty) in positions {
        if qty.abs() <= POS_EPS {
            continue;
        }
        let intent = OrderIntent {
            id: next_order_id(),
            symbol: symbol.clone(),
            side: if qty > 0.0 { Side::Sell } else { Side::Buy },
            qty: qty.abs(),
            order_type: OrderType::Market,
            limit_px: None,
            stop_px: None,
            tif: Tif::Ioc,
            reduce_only: true,
            source: OrderSource::RiskFlatten,
            rationale: "ibkr flatten".into(),
            ts_ms: now_ms(),
        };
        match submit_intent(client, &intent, route).await {
            Ok(_) => ids.push(intent.id),
            // `symbol` is public reference data, safe to log; account ids are not.
            Err(e) => tracing::error!("IBKR flatten exit failed for {symbol}: {e}"),
        }
    }
    ids
}
