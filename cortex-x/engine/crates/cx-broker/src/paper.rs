//! PaperBroker — the default broker. A thin delegation layer over the
//! existing [`cx_oms::Oms`] so that paper mode is byte-for-byte identical to
//! today's engine: `place` is exactly `oms.submit`, `flatten_all` is exactly
//! `oms.flatten_all`, and all bus publishing stays inside the OMS. This wrapper
//! adds no state and no behaviour of its own.

use std::sync::Arc;

use async_trait::async_trait;

use cx_core::events::{AccountSnapshot, BrokerMode, BrokerStatus, OrderIntent, Position};
use cx_oms::Oms;

use crate::{Broker, BrokerError, BrokerOrderId};

pub struct PaperBroker {
    oms: Arc<Oms>,
}

impl PaperBroker {
    pub fn new(oms: Arc<Oms>) -> Arc<Self> {
        Arc::new(Self { oms })
    }
}

#[async_trait]
impl Broker for PaperBroker {
    fn name(&self) -> &'static str {
        "paper"
    }

    async fn connect(&self) -> Result<(), BrokerError> {
        Ok(())
    }

    async fn disconnect(&self) {}

    async fn place(&self, intent: OrderIntent) -> Result<BrokerOrderId, BrokerError> {
        // Identical to today's `oms.submit(intent).await` on the paper path.
        let id = self.oms.submit(intent).await;
        Ok(BrokerOrderId::paper(id))
    }

    async fn cancel(&self, order_id: u64) -> bool {
        self.oms.cancel(order_id, "broker cancel").await
    }

    async fn cancel_all(&self, reason: &str) {
        // Cancel every still-open order; the OMS emits one Canceled per order.
        for o in self.oms.open_orders() {
            let _ = self.oms.cancel(o.order_id, reason).await;
        }
    }

    async fn flatten_all(&self, reason: &str) -> Vec<u64> {
        // `oms.flatten_all` already cancels all working orders THEN flattens
        // every position (reduce-only) — the exact semantics of
        // "cancel_all + flatten", unchanged from today.
        self.oms.flatten_all(reason).await
    }

    fn positions(&self) -> Vec<Position> {
        self.oms.positions()
    }

    fn account(&self) -> AccountSnapshot {
        self.oms.account()
    }

    fn status(&self) -> BrokerStatus {
        // The internal simulator: always "connected" (in-process), never a
        // real account. The app renders this as a calm PAPER badge.
        BrokerStatus {
            mode: BrokerMode::Paper,
            connected: true,
            account_masked: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cx_core::bus::Bus;
    use cx_core::config::PaperConfig;
    use cx_core::events::OrderSource;
    use cx_core::store::BarStore;
    use cx_core::time::now_ms;
    use cx_core::types::{OrderType, Side, Tif};

    fn setup() -> (Arc<BarStore>, Arc<Oms>, Arc<PaperBroker>) {
        let bus = Bus::new(1024);
        let store = Arc::new(BarStore::new());
        let cfg = PaperConfig {
            starting_cash: 100_000.0,
            maker_fee_bps: 0.0,
            taker_fee_bps: 0.0,
            latency_ms: 0,
            slippage_bps: 0.0,
        };
        let oms = Oms::new(Arc::clone(&bus), Arc::clone(&store), cfg);
        let broker = PaperBroker::new(Arc::clone(&oms));
        (store, oms, broker)
    }

    fn market(symbol: &str, side: Side, qty: f64) -> OrderIntent {
        OrderIntent {
            id: 0,
            symbol: symbol.into(),
            side,
            qty,
            order_type: OrderType::Market,
            limit_px: None,
            stop_px: None,
            tif: Tif::Ioc,
            reduce_only: false,
            source: OrderSource::Manual,
            rationale: "test".into(),
            ts_ms: now_ms(),
        }
    }

    #[tokio::test]
    async fn place_delegates_to_oms_and_fills_like_today() {
        let (store, oms, broker) = setup();
        store.set_last_price_untracked("AAPL", 100.0);
        let id = broker
            .place(market("AAPL", Side::Buy, 2.0))
            .await
            .expect("place");
        assert!(id.venue_id.is_none(), "paper carries no venue id");
        // The OMS filled exactly as it would from a direct submit.
        assert_eq!(broker.name(), "paper");
        let pos = broker.positions();
        assert_eq!(pos.len(), 1);
        assert!((pos[0].qty - 2.0).abs() < 1e-9);
        assert!((broker.account().cash - (100_000.0 - 200.0)).abs() < 1e-9);
        // positions()/account() read straight through the same OMS.
        assert_eq!(broker.positions()[0].symbol, oms.positions()[0].symbol);
    }

    #[tokio::test]
    async fn flatten_all_cancels_working_and_flattens_positions() {
        let (store, _oms, broker) = setup();
        store.set_last_price_untracked("AAPL", 100.0);
        store.set_last_price_untracked("MSFT", 50.0);
        broker.place(market("AAPL", Side::Buy, 2.0)).await.unwrap();
        broker.place(market("MSFT", Side::Sell, 4.0)).await.unwrap();
        // A resting limit that must not survive the flatten.
        let mut resting = market("AAPL", Side::Buy, 1.0);
        resting.order_type = OrderType::Limit;
        resting.limit_px = Some(90.0);
        resting.tif = Tif::Gtc;
        broker.place(resting).await.unwrap();

        let ids = broker.flatten_all("risk halt").await;
        assert_eq!(ids.len(), 2, "one flatten per open position");
        for p in broker.positions() {
            assert!(p.qty.abs() < 1e-12, "everything flat");
        }
        assert!(broker.account().open_orders == 0, "working order canceled");
    }

    #[tokio::test]
    async fn cancel_all_cancels_open_orders() {
        let (store, _oms, broker) = setup();
        store.set_last_price_untracked("AAPL", 100.0);
        let mut resting = market("AAPL", Side::Buy, 1.0);
        resting.order_type = OrderType::Limit;
        resting.limit_px = Some(90.0);
        resting.tif = Tif::Gtc;
        broker.place(resting).await.unwrap();
        assert_eq!(broker.account().open_orders, 1);
        broker.cancel_all("operator").await;
        assert_eq!(broker.account().open_orders, 0);
    }
}
