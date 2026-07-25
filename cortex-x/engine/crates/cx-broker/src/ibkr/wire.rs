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

use ibapi::accounts::types::{AccountGroup, AccountId};
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

/// One UTC day in milliseconds — the day-drawdown clock's roll boundary, the
/// same one the paper OMS uses so both modes read identically.
const DAY_MS: i64 = 86_400_000;

/// The ONLY account-summary tags the engine consumes. Requesting
/// `AccountSummaryTags::ALL` would stream dozens of rows per refresh for values
/// nothing reads; these three are the balances the deck and the order ticket
/// are built on (equity, buying power, exposure).
const ACCOUNT_SUMMARY_TAGS: &[&str] = &[
    AccountSummaryTags::NET_LIQUIDATION,
    AccountSummaryTags::TOTAL_CASH_VALUE,
    AccountSummaryTags::GROSS_POSITION_VALUE,
];

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
        // Balances (equity / cash / gross). WITHOUT this the published account
        // snapshot only ever carried PnL, so the deck read a confident
        // EQUITY $0.00 / CASH $0.00 / GROSS $0.00 with both drawdown gauges
        // frozen at 0.0% while real money moved.
        self.spawn_account_summary_bridge(Arc::clone(&client));
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

    /// Stream the account-summary BALANCES into the same account snapshot the
    /// PnL bridge feeds, then republish it.
    ///
    /// This is the other half of the account snapshot. The PnL subscription
    /// carries only realized/unrealized P&L, so before this bridge existed the
    /// published `AccountSnapshot` was `empty_account_snapshot()` with two
    /// numbers filled in: the deck showed EQUITY/CASH/GROSS as a confident
    /// $0.00, both DD gauges sat frozen at 0.0% of their limits no matter how
    /// much was lost, and the ticket's `buyingPower = cash = 0` made every
    /// %-of-buying-power chip resolve to nothing — its only size-sanity check
    /// was permanently blank with real money at risk.
    fn spawn_account_summary_bridge(&self, client: Arc<Client>) {
        if self.account.is_empty() {
            // Normally unreachable (config requires an account when
            // mode == "ibkr"). The PnL bridge already publishes the loud
            // critical thought for this case; do not double-scream, just skip —
            // without an account id we cannot tell whose rows are whose.
            tracing::error!("IBKR: no account id configured — account balances unavailable");
            return;
        }
        let account = self.account.clone();
        let account_snap = Arc::clone(&self.account_snap);
        let bus = Arc::clone(&self.bus);
        tokio::spawn(async move {
            // "All" is the group a non-advisor account requests; rows are
            // filtered to OUR account below, since a Gateway serving several
            // accounts interleaves them on one subscription.
            let group = AccountGroup("All".to_string());
            let sub = match client.account_summary(&group, ACCOUNT_SUMMARY_TAGS).await {
                Ok(s) => s,
                Err(e) => {
                    // A panic in a spawned task kills this subsystem forever, so
                    // this fails LOUD but soft: balances stay unpopulated rather
                    // than being invented.
                    tracing::error!("IBKR account summary subscription failed: {e}");
                    return;
                }
            };
            // Session-scoped peaks: IBKR reports balances, never drawdown, so
            // the high-water marks are ours to keep. They start at the first
            // equity we see (so the first reading is 0% drawdown, not a
            // fabricated one) exactly like the paper OMS seeds its peaks from
            // starting cash. They reset on reconnect — a reconnect is a new
            // session, and inventing a peak we did not observe would be worse.
            let mut peaks = EquityPeaks::new();
            let mut data = sub.filter_data();
            while let Some(item) = data.next().await {
                let row = match item {
                    Ok(r) => r,
                    Err(e) => {
                        tracing::warn!("IBKR account summary stream error: {e}");
                        continue;
                    }
                };
                // The `End` marker closes a batch and carries no values.
                let AccountSummaryResult::Summary(summary) = row else {
                    continue;
                };
                if summary.account != account {
                    continue;
                }
                let snap = {
                    let mut slot = account_snap.lock().unwrap_or_else(|e| e.into_inner());
                    let mut snap: AccountSnapshot =
                        slot.clone().unwrap_or_else(empty_account_snapshot);
                    // An untracked tag or an unparseable value changes nothing —
                    // never republish a snapshot we did not actually update.
                    if !apply_account_tag(&mut snap, &summary.tag, &summary.value) {
                        continue;
                    }
                    let ts = now_ms();
                    let (dd_day, dd_total) = peaks.observe(snap.equity, ts);
                    snap.drawdown_day = dd_day;
                    snap.drawdown_total = dd_total;
                    snap.ts_ms = ts;
                    *slot = Some(snap.clone());
                    snap
                };
                bus.publish(EngineEvent::Account(snap));
            }
        });
    }
}

/// Fold ONE IBKR account-summary row into the engine's account snapshot.
/// Returns whether the row actually changed anything, so the caller only
/// republishes on a real update.
///
/// Values arrive as strings off the wire: a non-numeric or non-finite value is
/// DROPPED rather than coerced (a `parse` failure must never land as a 0.0
/// equity, which is precisely the confident-zero this bridge exists to kill).
/// `net_exposure` is deliberately left alone — IBKR publishes no net-position
/// tag, and a guessed net is worse than an unpopulated one.
fn apply_account_tag(snap: &mut AccountSnapshot, tag: &str, value: &str) -> bool {
    let Ok(v) = value.trim().parse::<f64>() else {
        return false;
    };
    if !v.is_finite() {
        return false;
    }
    if tag == AccountSummaryTags::NET_LIQUIDATION {
        snap.equity = v;
        true
    } else if tag == AccountSummaryTags::TOTAL_CASH_VALUE {
        snap.cash = v;
        true
    } else if tag == AccountSummaryTags::GROSS_POSITION_VALUE {
        snap.gross_exposure = v;
        true
    } else {
        false
    }
}

/// Peak-equity tracker behind the LIVE drawdown gauges: a session-total peak
/// plus a day peak that rolls on the UTC day change. Mirrors the paper OMS's
/// drawdown semantics (`(peak - equity) / peak`, clamped to [0, 1]) so the two
/// modes read the same way on the same gauge.
#[derive(Debug, Clone, Copy)]
struct EquityPeaks {
    day_peak: f64,
    total_peak: f64,
    /// UTC day index of `day_peak`; `None` until the first observation.
    utc_day: Option<i64>,
}

impl EquityPeaks {
    fn new() -> Self {
        Self {
            day_peak: 0.0,
            total_peak: 0.0,
            utc_day: None,
        }
    }

    /// Fold a fresh equity mark in; returns `(drawdown_day, drawdown_total)` as
    /// fractions in [0, 1].
    ///
    /// A non-finite or non-positive equity (a wire glitch, or the pre-first-row
    /// zero) leaves the peaks untouched and reports NO drawdown: a bad reading
    /// must never manufacture a 100% drawdown, which would throttle risk and
    /// light up the deck for nothing.
    fn observe(&mut self, equity: f64, ts_ms: i64) -> (f64, f64) {
        if !equity.is_finite() || equity <= 0.0 {
            return (0.0, 0.0);
        }
        let day = ts_ms.div_euclid(DAY_MS);
        if self.utc_day != Some(day) {
            self.utc_day = Some(day);
            self.day_peak = equity;
        }
        self.day_peak = self.day_peak.max(equity);
        self.total_peak = self.total_peak.max(equity);
        let dd = |peak: f64| {
            if peak > 0.0 {
                ((peak - equity) / peak).clamp(0.0, 1.0)
            } else {
                0.0
            }
        };
        (dd(self.day_peak), dd(self.total_peak))
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

#[cfg(test)]
mod tests {
    use super::*;

    /// The three balance tags the deck is built on must actually land in the
    /// snapshot. Before this bridge existed they stayed at
    /// `empty_account_snapshot()`'s zeros, so AccountStrip showed a confident
    /// EQUITY/CASH/GROSS $0.00 and the ticket's buying power was 0 (every %
    /// size chip resolved to nothing) while trading a real account.
    #[test]
    fn balance_tags_populate_equity_cash_and_gross() {
        let mut snap = empty_account_snapshot();
        assert!(apply_account_tag(
            &mut snap,
            AccountSummaryTags::NET_LIQUIDATION,
            "254321.75"
        ));
        assert!(apply_account_tag(
            &mut snap,
            AccountSummaryTags::TOTAL_CASH_VALUE,
            "155000.00"
        ));
        assert!(apply_account_tag(
            &mut snap,
            AccountSummaryTags::GROSS_POSITION_VALUE,
            "99321.75"
        ));
        assert!((snap.equity - 254_321.75).abs() < 1e-6);
        assert!((snap.cash - 155_000.0).abs() < 1e-6);
        assert!((snap.gross_exposure - 99_321.75).abs() < 1e-6);
        // PnL stays the PnL bridge's business; this bridge never touches it.
        assert_eq!(snap.realized_pnl_day, 0.0);
        assert_eq!(snap.unrealized_pnl, 0.0);
    }

    /// A tag we don't track, or a value that isn't a finite number, must change
    /// NOTHING — a `parse` failure coerced to 0.0 would recreate exactly the
    /// confident-zero equity this bridge exists to eliminate.
    #[test]
    fn untracked_or_unparseable_rows_change_nothing() {
        let mut snap = empty_account_snapshot();
        snap.equity = 250_000.0;
        snap.cash = 155_000.0;

        assert!(!apply_account_tag(&mut snap, "AccountType", "MARGIN"));
        assert!(!apply_account_tag(&mut snap, "Cushion", "0.87"));
        assert!(!apply_account_tag(
            &mut snap,
            AccountSummaryTags::NET_LIQUIDATION,
            ""
        ));
        assert!(!apply_account_tag(
            &mut snap,
            AccountSummaryTags::TOTAL_CASH_VALUE,
            "n/a"
        ));
        assert!(!apply_account_tag(
            &mut snap,
            AccountSummaryTags::NET_LIQUIDATION,
            "NaN"
        ));
        assert!((snap.equity - 250_000.0).abs() < 1e-9, "equity untouched");
        assert!((snap.cash - 155_000.0).abs() < 1e-9, "cash untouched");
    }

    /// Whitespace-padded numerics (the wire is text) still parse.
    #[test]
    fn padded_values_parse() {
        let mut snap = empty_account_snapshot();
        assert!(apply_account_tag(
            &mut snap,
            AccountSummaryTags::NET_LIQUIDATION,
            " 100000 "
        ));
        assert!((snap.equity - 100_000.0).abs() < 1e-9);
    }

    /// The drawdown gauges must MOVE. First reading seeds the peaks (0%), a
    /// decline reports the real fraction, and a recovery does not lower the peak.
    #[test]
    fn drawdown_tracks_the_equity_peak() {
        let mut peaks = EquityPeaks::new();
        let t0 = 1_700_000_000_000i64;
        assert_eq!(peaks.observe(100_000.0, t0), (0.0, 0.0), "first mark is the peak");

        let (day, total) = peaks.observe(97_000.0, t0 + 60_000);
        assert!((day - 0.03).abs() < 1e-9, "3% day drawdown, got {day}");
        assert!((total - 0.03).abs() < 1e-9);

        // Recovery: peaks never fall, so the drawdown returns to 0 only at a new
        // high — it does not re-baseline to the trough.
        let (day, _) = peaks.observe(99_000.0, t0 + 120_000);
        assert!((day - 0.01).abs() < 1e-9, "1% off the 100k peak, got {day}");
    }

    /// The DAY clock rolls on the UTC day change (matching the paper OMS), so a
    /// new session day starts from that day's own equity while the TOTAL peak
    /// survives.
    #[test]
    fn day_drawdown_resets_on_the_utc_day_change_total_does_not() {
        let mut peaks = EquityPeaks::new();
        let day1 = 1_700_000_000_000i64.div_euclid(DAY_MS) * DAY_MS;
        peaks.observe(100_000.0, day1);
        peaks.observe(90_000.0, day1 + 3_600_000);

        // Next UTC day, still at 90k: flat for the day, 10% off the total peak.
        let (day, total) = peaks.observe(90_000.0, day1 + DAY_MS + 1_000);
        assert!((day - 0.0).abs() < 1e-9, "new day starts flat, got {day}");
        assert!((total - 0.10).abs() < 1e-9, "total peak survives, got {total}");
    }

    /// A wire glitch (0, negative, NaN) must never manufacture a 100% drawdown:
    /// that would throttle risk and light the deck up over nothing.
    #[test]
    fn bad_equity_readings_report_no_drawdown_and_leave_the_peak_alone() {
        let mut peaks = EquityPeaks::new();
        let t0 = 1_700_000_000_000i64;
        peaks.observe(100_000.0, t0);
        for bad in [0.0, -5.0, f64::NAN, f64::INFINITY] {
            assert_eq!(
                peaks.observe(bad, t0 + 1_000),
                (0.0, 0.0),
                "bad equity {bad} must report no drawdown"
            );
        }
        // The real peak is intact, so the next good reading is still correct.
        let (_, total) = peaks.observe(95_000.0, t0 + 2_000);
        assert!((total - 0.05).abs() < 1e-9, "peak preserved, got {total}");
    }

    /// Drawdown is a FRACTION in [0, 1] — the app multiplies it against a 3%/10%
    /// limit, so an out-of-range value would blow the gauge out.
    #[test]
    fn drawdown_is_a_clamped_fraction() {
        let mut peaks = EquityPeaks::new();
        let t0 = 1_700_000_000_000i64;
        peaks.observe(1_000_000.0, t0);
        let (day, total) = peaks.observe(1.0, t0 + 1_000);
        assert!((0.0..=1.0).contains(&day), "day {day}");
        assert!((0.0..=1.0).contains(&total), "total {total}");
        assert!(day > 0.999);
    }
}
