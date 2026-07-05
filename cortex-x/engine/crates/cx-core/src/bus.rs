//! The signal bus — the sole nervous system of the engine.
//!
//! One broadcast channel of `Arc<EngineEvent>`. Squadron crates publish and
//! subscribe here and NEVER call each other directly. Slow subscribers lag
//! and drop (tokio broadcast semantics) rather than back-pressuring the
//! market-data hot path; drop counts are tracked so starvation is visible.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use tokio::sync::broadcast;

use crate::events::EngineEvent;

pub type BusEvent = Arc<EngineEvent>;

#[derive(Debug)]
pub struct Bus {
    tx: broadcast::Sender<BusEvent>,
    published: AtomicU64,
    critical_published: AtomicU64,
}

impl Bus {
    pub fn new(capacity: usize) -> Arc<Self> {
        let (tx, _) = broadcast::channel(capacity.max(64));
        Arc::new(Self {
            tx,
            published: AtomicU64::new(0),
            critical_published: AtomicU64::new(0),
        })
    }

    /// Publish an event to every live subscriber. Never blocks, never fails:
    /// with zero subscribers the event is dropped by design.
    pub fn publish(&self, event: EngineEvent) {
        self.published.fetch_add(1, Ordering::Relaxed);
        if event.is_critical() {
            self.critical_published.fetch_add(1, Ordering::Relaxed);
        }
        let _ = self.tx.send(Arc::new(event));
    }

    pub fn subscribe(&self) -> broadcast::Receiver<BusEvent> {
        self.tx.subscribe()
    }

    pub fn subscriber_count(&self) -> usize {
        self.tx.receiver_count()
    }

    pub fn published_count(&self) -> u64 {
        self.published.load(Ordering::Relaxed)
    }

    pub fn critical_count(&self) -> u64 {
        self.critical_published.load(Ordering::Relaxed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::events::{FeedHealth, FeedStatus};

    #[tokio::test]
    async fn publish_reaches_all_subscribers() {
        let bus = Bus::new(128);
        let mut a = bus.subscribe();
        let mut b = bus.subscribe();
        bus.publish(EngineEvent::FeedStatus(FeedStatus {
            feed: "test".into(),
            health: FeedHealth::Live,
            detail: String::new(),
            ts_ms: 0,
        }));
        assert_eq!(a.recv().await.unwrap().kind(), "feed_status");
        assert_eq!(b.recv().await.unwrap().kind(), "feed_status");
        assert_eq!(bus.published_count(), 1);
    }
}
