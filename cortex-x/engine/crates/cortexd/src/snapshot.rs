//! Snapshot assembly for newly connected clients: recent bars, portfolio,
//! risk posture, and the recent thought/order/signal rings that cortexd
//! maintains off the bus.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use cx_core::autonomy::AutonomyDial;
use std::collections::HashMap;

use cx_core::events::{
    AgentThought, BookDepth, EngineEvent, FeedStatus, GeoPulse, MacroSnapshot, NewsBoard,
    OrderUpdate, RegimeBoard, ScanBoard,
};
use cx_broker::Broker;
use cx_core::store::BarStore;
use cx_core::types::Interval;
use cx_core::Bus;
use cx_oms::Oms;
use cx_risk::RiskEngine;
use cx_server::SnapshotSource;

const THOUGHT_RING: usize = 100;
const ORDER_RING: usize = 100;

pub struct SnapshotSrc {
    symbols: Vec<String>,
    /// Scan-universe symbols beyond the configured set: D1-only history in
    /// snapshots so any of them can chart + be searched client-side.
    universe: Vec<String>,
    store: Arc<BarStore>,
    oms: Arc<Oms>,
    risk: Arc<RiskEngine>,
    dial: Arc<AutonomyDial>,
    /// The ACTIVE order sink, so the connect-time snapshot carries the true
    /// broker posture (paper / ibkr_paper / ibkr_live + connected + masked
    /// account) instead of leaving the app to default the badge to PAPER.
    broker: Arc<dyn Broker>,
    thoughts: Mutex<VecDeque<AgentThought>>,
    orders: Mutex<VecDeque<OrderUpdate>>,
    macro_last: Mutex<Option<MacroSnapshot>>,
    feeds: Mutex<HashMap<String, FeedStatus>>,
    regimes_last: Mutex<Option<RegimeBoard>>,
    geo_last: Mutex<Option<GeoPulse>>,
    scan_last: Mutex<Option<ScanBoard>>,
    news_last: Mutex<Option<NewsBoard>>,
    /// The latest LEVEL 2 depth published for the actively-viewed symbol, so a
    /// reconnecting client sees the current ladder without waiting for the next
    /// venue update. Only one symbol streams depth at a time, so a single
    /// slot is enough (and inherently bounded).
    depth_last: Mutex<Option<BookDepth>>,
}

impl SnapshotSrc {
    pub fn new(
        symbols: Vec<String>,
        universe: Vec<String>,
        store: Arc<BarStore>,
        oms: Arc<Oms>,
        risk: Arc<RiskEngine>,
        dial: Arc<AutonomyDial>,
        broker: Arc<dyn Broker>,
    ) -> Arc<Self> {
        let universe: Vec<String> = universe
            .into_iter()
            .filter(|u| !symbols.contains(u))
            .collect();
        Arc::new(Self {
            symbols,
            universe,
            store,
            oms,
            risk,
            dial,
            broker,
            thoughts: Mutex::new(VecDeque::new()),
            orders: Mutex::new(VecDeque::new()),
            macro_last: Mutex::new(None),
            feeds: Mutex::new(HashMap::new()),
            regimes_last: Mutex::new(None),
            geo_last: Mutex::new(None),
            scan_last: Mutex::new(None),
            news_last: Mutex::new(None),
            depth_last: Mutex::new(None),
        })
    }

    /// Continuous risk-free rate from the latest macro snapshot's 3m bill
    /// yield; a sane constant when macro data has not arrived yet.
    pub fn risk_free_rate(&self) -> f64 {
        self.macro_last
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .as_ref()
            .and_then(|m| m.yields.get("3m").copied())
            .map(|pct| pct / 100.0)
            .filter(|r| r.is_finite() && (0.0..0.20).contains(r))
            .unwrap_or(0.04)
    }

    /// Maintain the rings by listening to the bus.
    pub fn spawn_collector(self: &Arc<Self>, bus: Arc<Bus>) -> tokio::task::JoinHandle<()> {
        let this = Arc::clone(self);
        tokio::spawn(async move {
            let mut rx = bus.subscribe();
            loop {
                match rx.recv().await {
                    Ok(ev) => match ev.as_ref() {
                        EngineEvent::Thought(t) => {
                            let mut ring = this.thoughts.lock().unwrap_or_else(|p| p.into_inner());
                            ring.push_front(t.clone());
                            ring.truncate(THOUGHT_RING);
                        }
                        EngineEvent::OrderUpdate(o) => {
                            let mut ring = this.orders.lock().unwrap_or_else(|p| p.into_inner());
                            if let Some(existing) =
                                ring.iter_mut().find(|e| e.order_id == o.order_id)
                            {
                                *existing = o.clone();
                            } else {
                                ring.push_front(o.clone());
                                ring.truncate(ORDER_RING);
                            }
                        }
                        EngineEvent::Macro(m) => {
                            *this.macro_last.lock().unwrap_or_else(|p| p.into_inner()) =
                                Some(m.clone());
                        }
                        EngineEvent::FeedStatus(f) => {
                            this.feeds
                                .lock()
                                .unwrap_or_else(|p| p.into_inner())
                                .insert(f.feed.clone(), f.clone());
                        }
                        EngineEvent::RegimeMap(r) => {
                            *this.regimes_last.lock().unwrap_or_else(|p| p.into_inner()) =
                                Some(r.clone());
                        }
                        EngineEvent::Geo(g) => {
                            *this.geo_last.lock().unwrap_or_else(|p| p.into_inner()) =
                                Some(g.clone());
                        }
                        EngineEvent::Scan(s) => {
                            *this.scan_last.lock().unwrap_or_else(|p| p.into_inner()) =
                                Some(s.clone());
                        }
                        EngineEvent::News(n) => {
                            *this.news_last.lock().unwrap_or_else(|p| p.into_inner()) =
                                Some(n.clone());
                        }
                        EngineEvent::Depth(d) => {
                            // Keep only the latest depth (one active symbol at a
                            // time); a connecting client gets the current ladder.
                            *this.depth_last.lock().unwrap_or_else(|p| p.into_inner()) =
                                Some(d.clone());
                        }
                        _ => {}
                    },
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(_) => break,
                }
            }
        })
    }
}

/// Shape the latest single-symbol depth for the snapshot wire as a
/// symbol-keyed map, matching the app's `depth: [String: BookDepth]?` contract
/// and its `snap.depth?[symbol]` lookup. Emitting a bare `BookDepth` here would
/// decode as a `typeMismatch` in Swift and sink the ENTIRE `EngineSnapshot`
/// (bars, positions, account, orders, feeds, broker posture — all silently
/// dropped). Absent (serialized as JSON `null`) when no symbol streams depth.
fn depth_snapshot_map(depth_last: Option<BookDepth>) -> Option<HashMap<String, BookDepth>> {
    depth_last.map(|d| HashMap::from([(d.symbol.clone(), d)]))
}

impl SnapshotSource for SnapshotSrc {
    fn snapshot(&self, bars_per_symbol: u32) -> serde_json::Value {
        let n = bars_per_symbol.clamp(10, 3_000) as usize;
        let mut bars = serde_json::Map::new();
        for symbol in &self.symbols {
            let mut per_interval = serde_json::Map::new();
            for interval in Interval::ALL {
                let series = self.store.recent(symbol, interval, n);
                if !series.is_empty() {
                    // Interval serializes as its serde snake_case name ("m1").
                    let key = serde_json::to_value(interval)
                        .ok()
                        .and_then(|v| v.as_str().map(String::from))
                        .unwrap_or_else(|| interval.label().into());
                    per_interval.insert(key, serde_json::to_value(&series).unwrap_or_default());
                }
            }
            bars.insert(symbol.clone(), serde_json::Value::Object(per_interval));
        }
        // Universe symbols: D1 only (delayed research history, not live feeds).
        for symbol in &self.universe {
            let series = self.store.recent(symbol, Interval::D1, n);
            if !series.is_empty() {
                let mut per_interval = serde_json::Map::new();
                per_interval.insert("d1".into(), serde_json::to_value(&series).unwrap_or_default());
                bars.insert(symbol.clone(), serde_json::Value::Object(per_interval));
            }
        }
        let thoughts: Vec<AgentThought> = self
            .thoughts
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .iter()
            .cloned()
            .collect();
        let orders: Vec<OrderUpdate> = self
            .orders
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .iter()
            .cloned()
            .collect();
        let macro_last = self
            .macro_last
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .clone();

        let feeds: Vec<FeedStatus> = self
            .feeds
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .values()
            .cloned()
            .collect();

        let regimes_last = self
            .regimes_last
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .clone();
        let geo_last = self.geo_last.lock().unwrap_or_else(|p| p.into_inner()).clone();
        let scan_last = self.scan_last.lock().unwrap_or_else(|p| p.into_inner()).clone();
        let news_last = self.news_last.lock().unwrap_or_else(|p| p.into_inner()).clone();
        let depth_last = self
            .depth_last
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .clone();

        serde_json::json!({
            "symbols": self.symbols,
            "bars": bars,
            "positions": self.oms.positions(),
            "account": self.oms.account(),
            "risk": self.risk.status(self.dial.get()),
            "thoughts": thoughts,
            "orders": orders,
            "macro": macro_last,
            "feeds": feeds,
            "regimes": regimes_last,
            "geo": geo_last,
            "scan": scan_last,
            "news": news_last,
            // The latest LEVEL 2 depth for the actively-viewed symbol (honestly
            // labelled live/delayed), so a reconnecting client renders the
            // ladder immediately. Keyed BY SYMBOL to match the app's
            // `[String: BookDepth]?` contract; absent (null) when nothing
            // streams. Never a bare object — that sinks the whole snapshot.
            "depth": depth_snapshot_map(depth_last),
            "search_universe": self.universe,
            // The true broker posture at connect. The app reads LIVE only for
            // ibkr_live + connected, so a paper/fallback engine can never
            // mislabel — and an older app that ignores the field is unaffected.
            "broker": self.broker.status(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cx_core::events::BookLevel;

    fn sample_depth(symbol: &str) -> BookDepth {
        BookDepth {
            symbol: symbol.to_string(),
            bids: vec![BookLevel { px: 100.0, sz: 1.0, count: 1 }],
            asks: vec![BookLevel { px: 101.0, sz: 1.0, count: 1 }],
            depth: 1,
            source: "test".into(),
            is_live: true,
            ts_ms: 1,
        }
    }

    /// The connect/reconnect snapshot must key depth BY SYMBOL so the app's
    /// `depth: [String: BookDepth]?` decode succeeds and `snap.depth?[symbol]`
    /// resolves. A bare `BookDepth` (or a scalar under "depth") would
    /// type-mismatch in Swift and drop the ENTIRE `EngineSnapshot`.
    #[test]
    fn depth_serializes_as_symbol_keyed_map() {
        let v =
            serde_json::to_value(depth_snapshot_map(Some(sample_depth("BTC-USD")))).unwrap();
        let obj = v.as_object().expect("depth must be a JSON object keyed by symbol");
        // Exactly one symbol streams depth at a time.
        assert_eq!(obj.len(), 1);
        let entry = obj.get("BTC-USD").expect("keyed by the depth's own symbol");
        assert_eq!(entry["symbol"], "BTC-USD");
        assert_eq!(entry["is_live"], true);
        assert_eq!(entry["asks"][0]["px"], 101.0);
    }

    /// No active depth subscription → JSON `null` (Swift `decodeIfPresent` →
    /// nil), never an empty object or a stale bare book.
    #[test]
    fn depth_absent_serializes_as_null() {
        let v = serde_json::to_value(depth_snapshot_map(None)).unwrap();
        assert!(v.is_null());
    }
}
