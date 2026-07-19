//! ActiveBroker — a hot-swappable holder for the engine's order sink.
//!
//! The [`TradePipeline`](crate::pipeline::TradePipeline) and the connect-time
//! snapshot both hold ONE `Arc<ActiveBroker>` (coerced to `Arc<dyn Broker>`).
//! Every trait call resolves to the CURRENT inner broker under a short lock, so
//! a runtime `set_broker_config` can replace the sink (paper <-> IBKR) WITHOUT
//! rebuilding the pipeline and without ever dropping the kill-switch / risk /
//! flatten path: those calls always reach whatever broker is live at the
//! instant they run. The pipeline's broker slot never changes identity — only
//! what it delegates to does — so an in-flight kill/flatten can never race a
//! reassignment.
//!
//! Safety: this holder NEVER makes a broker; it only stores one someone else
//! built and validated. The replacement is produced by
//! [`cx_broker::build_active_broker`] from an ALREADY-VALIDATED `BrokerConfig`
//! (same live-port refusal + fallback-to-paper + critical thought as startup),
//! so swapping can never bypass a gate or silently go live. The lock is a plain
//! `std::sync::Mutex` and is NEVER held across an `.await` — the current inner
//! `Arc` is cloned out under the lock, then the awaited trait call runs on the
//! clone.

use std::sync::{Arc, Mutex};

use async_trait::async_trait;

use cx_broker::{Broker, BrokerError, BrokerOrderId};
use cx_core::events::{AccountSnapshot, BrokerStatus, OrderIntent, Position};

/// A stable `Broker` whose inner delegate can be atomically replaced at runtime.
pub struct ActiveBroker {
    inner: Mutex<Arc<dyn Broker>>,
}

impl ActiveBroker {
    /// Wrap the initial sink. Returned as an `Arc` so the same instance can be
    /// shared (as `Arc<dyn Broker>`) with the pipeline and the snapshot while a
    /// separate `Arc<ActiveBroker>` handle drives [`swap`](Self::swap).
    pub fn new(inner: Arc<dyn Broker>) -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(inner),
        })
    }

    /// The broker currently routing orders. Cloned out under the lock so the
    /// lock is released before the caller awaits the trait method on it.
    pub fn current(&self) -> Arc<dyn Broker> {
        Arc::clone(&self.inner.lock().unwrap_or_else(|p| p.into_inner()))
    }

    /// Replace the routing sink, returning the PREVIOUS one so the caller can
    /// gracefully `disconnect()` it after the swap (the new sink is already in
    /// place, so routing is never interrupted). The swap itself is a single
    /// mutex-guarded pointer replace — it cannot fail or panic.
    pub fn swap(&self, next: Arc<dyn Broker>) -> Arc<dyn Broker> {
        let mut guard = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        std::mem::replace(&mut *guard, next)
    }
}

#[async_trait]
impl Broker for ActiveBroker {
    fn name(&self) -> &'static str {
        self.current().name()
    }

    async fn connect(&self) -> Result<(), BrokerError> {
        self.current().connect().await
    }

    async fn disconnect(&self) {
        self.current().disconnect().await;
    }

    async fn place(&self, intent: OrderIntent) -> Result<BrokerOrderId, BrokerError> {
        self.current().place(intent).await
    }

    async fn cancel(&self, order_id: u64) -> bool {
        self.current().cancel(order_id).await
    }

    async fn cancel_all(&self, reason: &str) {
        self.current().cancel_all(reason).await;
    }

    async fn flatten_all(&self, reason: &str) -> Vec<u64> {
        self.current().flatten_all(reason).await
    }

    fn positions(&self) -> Vec<Position> {
        self.current().positions()
    }

    fn account(&self) -> AccountSnapshot {
        self.current().account()
    }

    fn status(&self) -> BrokerStatus {
        self.current().status()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cx_core::events::{BrokerMode, OrderSource};
    use cx_core::time::now_ms;
    use cx_core::types::{OrderType, Side, Tif};

    /// A broker that records how many times each method was hit, so a test can
    /// prove which delegate a call landed on across a swap.
    struct CountingBroker {
        tag: &'static str,
        places: std::sync::atomic::AtomicUsize,
        flattens: std::sync::atomic::AtomicUsize,
    }

    impl CountingBroker {
        fn new(tag: &'static str) -> Arc<Self> {
            Arc::new(Self {
                tag,
                places: std::sync::atomic::AtomicUsize::new(0),
                flattens: std::sync::atomic::AtomicUsize::new(0),
            })
        }
        fn places(&self) -> usize {
            self.places.load(std::sync::atomic::Ordering::SeqCst)
        }
        fn flattens(&self) -> usize {
            self.flattens.load(std::sync::atomic::Ordering::SeqCst)
        }
    }

    #[async_trait]
    impl Broker for CountingBroker {
        fn name(&self) -> &'static str {
            self.tag
        }
        async fn connect(&self) -> Result<(), BrokerError> {
            Ok(())
        }
        async fn disconnect(&self) {}
        async fn place(&self, intent: OrderIntent) -> Result<BrokerOrderId, BrokerError> {
            self.places.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Ok(BrokerOrderId::paper(intent.id))
        }
        async fn cancel(&self, _order_id: u64) -> bool {
            true
        }
        async fn cancel_all(&self, _reason: &str) {}
        async fn flatten_all(&self, _reason: &str) -> Vec<u64> {
            self.flattens.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            vec![1]
        }
        fn positions(&self) -> Vec<Position> {
            Vec::new()
        }
        fn account(&self) -> AccountSnapshot {
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
        fn status(&self) -> BrokerStatus {
            BrokerStatus {
                mode: BrokerMode::Paper,
                connected: true,
                account_masked: None,
            }
        }
    }

    fn market(id: u64) -> OrderIntent {
        OrderIntent {
            id,
            symbol: "AAPL".into(),
            side: Side::Buy,
            qty: 1.0,
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
    async fn calls_route_to_the_current_delegate_across_a_swap() {
        let first = CountingBroker::new("first");
        let active = ActiveBroker::new(Arc::clone(&first) as Arc<dyn Broker>);

        // Before the swap every call lands on `first`.
        active.place(market(1)).await.unwrap();
        assert_eq!(active.name(), "first");
        assert_eq!(first.places(), 1);

        // Swap in `second`; the returned previous is `first`.
        let second = CountingBroker::new("second");
        let prev = active.swap(Arc::clone(&second) as Arc<dyn Broker>);
        assert_eq!(prev.name(), "first");

        // Now place + flatten land on `second`, and `first` is untouched.
        active.place(market(2)).await.unwrap();
        let flat = active.flatten_all("kill").await;
        assert_eq!(flat, vec![1]);
        assert_eq!(active.name(), "second");
        assert_eq!(first.places(), 1, "post-swap calls must not reach the old broker");
        assert_eq!(second.places(), 1);
        assert_eq!(second.flattens(), 1);
    }

    #[test]
    fn status_reflects_the_currently_installed_broker() {
        let a = ActiveBroker::new(CountingBroker::new("first") as Arc<dyn Broker>);
        assert_eq!(a.status().mode, BrokerMode::Paper);
        assert!(a.status().connected);
    }
}
