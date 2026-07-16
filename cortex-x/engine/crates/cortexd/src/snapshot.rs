//! Snapshot assembly for newly connected clients: recent bars, portfolio,
//! risk posture, and the recent thought/order/signal rings that cortexd
//! maintains off the bus.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use cx_core::autonomy::AutonomyDial;
use std::collections::HashMap;

use cx_core::events::{
    AgentThought, EngineEvent, FeedStatus, GeoPulse, MacroSnapshot, NewsBoard, OrderUpdate,
    RegimeBoard, ScanBoard,
};
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
    thoughts: Mutex<VecDeque<AgentThought>>,
    orders: Mutex<VecDeque<OrderUpdate>>,
    macro_last: Mutex<Option<MacroSnapshot>>,
    feeds: Mutex<HashMap<String, FeedStatus>>,
    regimes_last: Mutex<Option<RegimeBoard>>,
    geo_last: Mutex<Option<GeoPulse>>,
    scan_last: Mutex<Option<ScanBoard>>,
    news_last: Mutex<Option<NewsBoard>>,
}

impl SnapshotSrc {
    pub fn new(
        symbols: Vec<String>,
        universe: Vec<String>,
        store: Arc<BarStore>,
        oms: Arc<Oms>,
        risk: Arc<RiskEngine>,
        dial: Arc<AutonomyDial>,
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
            thoughts: Mutex::new(VecDeque::new()),
            orders: Mutex::new(VecDeque::new()),
            macro_last: Mutex::new(None),
            feeds: Mutex::new(HashMap::new()),
            regimes_last: Mutex::new(None),
            geo_last: Mutex::new(None),
            scan_last: Mutex::new(None),
            news_last: Mutex::new(None),
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
                        _ => {}
                    },
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(_) => break,
                }
            }
        })
    }
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
            "search_universe": self.universe,
        })
    }
}
