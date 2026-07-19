//! cx-md — the market data squadron.
//!
//! One supervisor task owns three concerns:
//! - a connector (live Coinbase websocket or synthetic GBM generator) that
//!   publishes [`cx_core::events::Tick`] / [`cx_core::events::BookTop`] to the
//!   bus, mirrors last prices into the [`BarStore`], and feeds every tick into
//!   an internal ordered mpsc;
//! - a bar aggregator consuming that mpsc (never the bus — ordering is
//!   preserved end to end) that maintains forming bars for every
//!   [`cx_core::types::Interval`] and publishes rollovers exactly once;
//! - a one-shot REST backfill that seeds the [`BarStore`] with recent history
//!   (store only — history is served via snapshot, never replayed on the bus).
//!
//! Fallback policy: after 3 consecutive failed live connects (when
//! `feed.synthetic_fallback` is set) the squadron switches to the synthetic
//! feed and STAYS synthetic until process restart — no live/synthetic
//! interleaving mid-run.

mod agg;
mod backfill;
mod coinbase;
mod equity;
pub mod options;
mod synthetic;

/// The IBKR market-data integration point: once the IBKR adapter (cx-broker,
/// `ibkr` feature) is connected with the operator's market-data subscriptions,
/// it publishes REAL equity LEVEL 1/2 depth (`reqMktDepth`) and trade prints
/// (`reqMktData`) through these — the only sanctioned source of `is_live=true`
/// equity depth/tape. The CBOE poller never emits live equity depth. See
/// [`equity`] for the full note.
pub use equity::{publish_ibkr_depth, publish_ibkr_tape};

use std::sync::Arc;

use cx_core::egress::Egress;
use cx_core::store::BarStore;
use cx_core::{Bus, Config};
use tokio::sync::watch;

/// Handle to the running market-data squadron. Owns the supervisor task and
/// the LEVEL 2 depth control channel: cortexd sets the single actively-viewed
/// depth symbol here, and the connectors (Coinbase level2, CBOE delayed L1)
/// pick it up over a broadcast [`watch`] so at most ONE symbol streams depth
/// at a time — bandwidth bounded by construction.
pub struct MarketData {
    depth_tx: watch::Sender<Option<String>>,
    task: tokio::task::JoinHandle<()>,
}

impl MarketData {
    /// Spawn all internal tasks and return the squadron handle. [`MarketData::abort`]
    /// tears the squadron down.
    pub fn start(bus: Arc<Bus>, store: Arc<BarStore>, cfg: Config) -> MarketData {
        // The actively-viewed depth symbol (None = stream no depth). A watch so
        // both connectors always see the latest value, rapid switches coalesce,
        // and the value survives connector reconnects.
        let (depth_tx, depth_rx) = watch::channel::<Option<String>>(None);
        let task = tokio::spawn(async move {
            let (tick_tx, tick_rx) = tokio::sync::mpsc::channel(8_192);
            let aggregator = tokio::spawn(agg::run(tick_rx, bus.clone(), store.clone()));

            // Symbol-class routing: dashed products are Coinbase crypto,
            // bare tickers are CBOE-delayed equities.
            let crypto: Vec<String> = cfg
                .symbols
                .iter()
                .filter(|s| s.contains('-'))
                .cloned()
                .collect();
            let equities: Vec<String> = cfg
                .symbols
                .iter()
                .filter(|s| !s.contains('-'))
                .cloned()
                .collect();

            let synthetic_primary = cfg.feed.primary == "synthetic";
            if !synthetic_primary && !crypto.is_empty() {
                // Backfill runs concurrently with the live connect; the store
                // merges out-of-order history behind live bars.
                let egress = Egress::new();
                let store = store.clone();
                let symbols = crypto.clone();
                let max_bars = cfg.feed.backfill_bars;
                tokio::spawn(async move {
                    backfill::run(&egress, &store, &symbols, max_bars).await;
                });
            }
            if !synthetic_primary && !equities.is_empty() {
                tokio::spawn(equity::run(
                    bus.clone(),
                    store.clone(),
                    equities,
                    tick_tx.clone(),
                    cfg.feed.backfill_bars,
                    depth_rx.clone(),
                ));
            }

            if synthetic_primary {
                // Synthetic mode has no real book: it never publishes depth
                // (honest — there is nothing real to show).
                synthetic::run(bus, store, cfg.symbols.clone(), tick_tx).await;
            } else {
                let mut cfg = cfg;
                cfg.symbols = crypto;
                if cfg.symbols.is_empty() {
                    // Equities-only setup: hold the tick channel open for the
                    // poller; nothing else to run here.
                    std::future::pending::<()>().await;
                } else {
                    coinbase::run(bus, store, cfg, tick_tx, depth_rx).await;
                }
            }
            // Connectors only return when the tick channel is gone; drain the
            // aggregator so a supervised shutdown is complete.
            let _ = aggregator.await;
        });
        MarketData { depth_tx, task }
    }

    /// Set the single actively-viewed depth symbol (None = stream no depth).
    /// The engine streams LEVEL 2 depth for at most this one symbol to bound
    /// bandwidth; setting a new symbol implicitly unsubscribes the previous.
    /// Cheap and non-blocking; safe to call from the command loop.
    pub fn set_active_depth(&self, symbol: Option<String>) {
        // `send` fails only if every receiver is gone (squadron torn down);
        // then there is nothing to stream and dropping the request is correct.
        let _ = self.depth_tx.send(symbol);
    }

    /// Tear the squadron down (aborts the supervisor task).
    pub fn abort(&self) {
        self.task.abort();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cx_core::events::EngineEvent;
    use cx_core::types::Interval;

    /// End-to-end wiring: synthetic primary must flow ticks, tops, forming
    /// bars and a feed status through the bus and populate the store.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn synthetic_primary_flows_events_and_fills_store() {
        let bus = Bus::new(4_096);
        let store = Arc::new(BarStore::new());
        let cfg = Config {
            symbols: vec!["BTC-USD".into()],
            feed: cx_core::config::FeedConfig {
                primary: "synthetic".into(),
                ..Default::default()
            },
            ..Default::default()
        };

        let mut rx = bus.subscribe();
        let handle = MarketData::start(bus.clone(), store.clone(), cfg);

        let (mut saw_tick, mut saw_top, mut saw_bar, mut saw_status) = (false, false, false, false);
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
        while !(saw_tick && saw_top && saw_bar && saw_status) {
            let ev = tokio::time::timeout_at(deadline, rx.recv())
                .await
                .expect("timed out waiting for events")
                .expect("bus closed");
            match ev.as_ref() {
                EngineEvent::Tick(t) => {
                    assert!(t.price.is_finite() && t.price > 0.0);
                    saw_tick = true;
                }
                EngineEvent::BookTop(t) => {
                    assert!(t.bid_px < t.ask_px);
                    saw_top = true;
                }
                EngineEvent::Bar(b) => {
                    assert_eq!(b.symbol, "BTC-USD");
                    saw_bar = true;
                }
                EngineEvent::FeedStatus(_) => saw_status = true,
                _ => {}
            }
        }
        assert!(store.last_price("BTC-USD").is_some());
        assert!(!store.recent("BTC-USD", Interval::S1, 5).is_empty());
        handle.abort();
    }
}
