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

/// Per-interval history depth for the connect/reconnect snapshot — the SLIM
/// profile that keeps the default payload small without losing the deep D1 the
/// charts need.
///
/// Sizing rationale: the snapshot's cost is dominated by INTRADAY bars for the
/// handful of configured symbols. Live feeds fill each intraday series toward
/// the store's `MAX_BARS` (3000), so shipping every interval at full depth is
/// what pushed the connect blob to ~8 MB (`6 symbols × 5 intraday × 3000`).
///
/// The wire caps by interval class:
/// - **D1** is the DEEP interval: shipped up to `bars_per_symbol` (store max
///   3000). A normal connect asks for [`CONNECT_SNAPSHOT_BARS`](cx_server)
///   (≈1300 → ~5y of trading days) for BOTH configured and universe symbols; a
///   range-preset `Command::Sync` may lift it to the store maximum.
/// - **Intraday** (`s1`/`m1`/`m5`/`m15`/`h1`) is capped at
///   [`INTRADAY_SNAPSHOT_BARS`] and only for CONFIGURED symbols. A longer
///   intraday span is served by switching to a coarser interval, never by
///   shipping thousands of 1s/1m bars on every connect. A deep `Sync` lifts
///   D1 depth only; intraday stays capped at [`INTRADAY_SNAPSHOT_BARS`].
/// - **Universe** symbols carry D1 ONLY (research history; no live intraday) —
///   unchanged from before, restated here so the profile is one place.
///
/// A client requesting fewer than the cap still gets exactly what it asked for
/// (the cap is a ceiling, never a floor).
const INTRADAY_SNAPSHOT_BARS: usize = 400;

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

/// Interval's serde snake_case wire key ("m1", "d1", …), falling back to its
/// human label only if the (infallible in practice) serialization ever fails.
fn interval_key(interval: Interval) -> String {
    serde_json::to_value(interval)
        .ok()
        .and_then(|v| v.as_str().map(String::from))
        .unwrap_or_else(|| interval.label().into())
}

/// Assemble the per-symbol → per-interval bar map for the snapshot wire under
/// the SLIM history profile documented on [`INTRADAY_SNAPSHOT_BARS`]:
/// - **Configured** symbols get DEEP D1 (up to `bars_per_symbol`, store max
///   3000) plus a MODEST intraday window (each of s1/m1/m5/m15/h1 capped at
///   `INTRADAY_SNAPSHOT_BARS`).
/// - **Universe** symbols get DEEP D1 ONLY — never intraday.
///
/// Empty series are omitted so the app only sees intervals that actually hold
/// data. Configured symbols always get an entry (possibly an empty object);
/// universe symbols appear only when they have D1 — behaviour preserved from
/// the original inline builder. Nothing is fabricated: depth is whatever the
/// store honestly holds, bounded by the caps.
fn build_bars_map(
    store: &BarStore,
    symbols: &[String],
    universe: &[String],
    bars_per_symbol: u32,
) -> serde_json::Map<String, serde_json::Value> {
    // D1 is the deep interval: honour the requested depth up to the store max.
    let d1_n = bars_per_symbol.clamp(10, 3_000) as usize;
    // Intraday is held to the modest cap, but never more than was requested.
    let intraday_n = d1_n.min(INTRADAY_SNAPSHOT_BARS);

    let mut bars = serde_json::Map::new();
    for symbol in symbols {
        let mut per_interval = serde_json::Map::new();
        for interval in Interval::ALL {
            let cap = if interval == Interval::D1 { d1_n } else { intraday_n };
            let series = store.recent(symbol, interval, cap);
            if !series.is_empty() {
                per_interval
                    .insert(interval_key(interval), serde_json::to_value(&series).unwrap_or_default());
            }
        }
        bars.insert(symbol.clone(), serde_json::Value::Object(per_interval));
    }
    // Universe symbols: DEEP D1 only (delayed research history, not live feeds).
    for symbol in universe {
        let series = store.recent(symbol, Interval::D1, d1_n);
        if !series.is_empty() {
            let mut per_interval = serde_json::Map::new();
            per_interval.insert("d1".into(), serde_json::to_value(&series).unwrap_or_default());
            bars.insert(symbol.clone(), serde_json::Value::Object(per_interval));
        }
    }
    bars
}

impl SnapshotSource for SnapshotSrc {
    fn snapshot(&self, bars_per_symbol: u32) -> serde_json::Value {
        // Slim history profile: deep D1 (configured + universe), capped intraday
        // for configured only, no intraday for universe. See build_bars_map /
        // INTRADAY_SNAPSHOT_BARS for the per-interval caps and rationale.
        let bars = build_bars_map(&self.store, &self.symbols, &self.universe, bars_per_symbol);
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
    use cx_core::events::{Bar, BookLevel};

    /// Seed `count` synthetic complete bars for one (symbol, interval) into the
    /// store. Timestamps are distinct + increasing (bucket-aligned by the
    /// interval's ms) so the store keeps them in order. Values are finite.
    fn seed(store: &BarStore, symbol: &str, interval: Interval, count: usize) {
        for i in 0..count {
            store.push(Bar {
                symbol: symbol.to_string(),
                interval,
                ts_open_ms: (i as i64 + 1) * interval.ms(),
                open: 100.0,
                high: 101.0,
                low: 99.0,
                close: 100.5,
                volume: 1.0,
                trade_count: 1,
                vwap: 100.2,
                complete: true,
            });
        }
    }

    /// Row count the wire carries for `symbol`/`key`; 0 when the interval is
    /// absent (the slim profile omits empty series entirely).
    fn rows(bars: &serde_json::Map<String, serde_json::Value>, symbol: &str, key: &str) -> usize {
        bars.get(symbol)
            .and_then(|s| s.get(key))
            .and_then(|v| v.as_array())
            .map(|a| a.len())
            .unwrap_or(0)
    }

    const INTRADAY_KEYS: [&str; 5] = ["s1", "m1", "m5", "m15", "h1"];

    /// Connect profile: configured symbols ship DEEP D1 but every intraday
    /// interval is capped at `INTRADAY_SNAPSHOT_BARS`, even though the store
    /// holds far more. The universe symbol ships D1 ONLY — no intraday key.
    #[test]
    fn slim_profile_deep_d1_capped_intraday_universe_d1_only() {
        let store = BarStore::new();
        // Configured symbol, every interval filled to the store maximum.
        for interval in Interval::ALL {
            seed(&store, "BTC-USD", interval, 3_000);
        }
        // Universe symbol: D1 history plus (deliberately) intraday that MUST be
        // dropped — universe carries daily research history only.
        seed(&store, "AAPL", Interval::D1, 3_000);
        seed(&store, "AAPL", Interval::M1, 3_000);

        let symbols = vec!["BTC-USD".to_string()];
        let universe = vec!["AAPL".to_string()];
        // The connect default depth (deep D1, ~5y).
        let bars = build_bars_map(&store, &symbols, &universe, 1_300);

        // Configured: deep D1, modest intraday.
        assert_eq!(rows(&bars, "BTC-USD", "d1"), 1_300, "D1 stays deep");
        for key in INTRADAY_KEYS {
            assert_eq!(
                rows(&bars, "BTC-USD", key),
                INTRADAY_SNAPSHOT_BARS,
                "intraday {key} capped"
            );
        }

        // Universe: D1 only, and NO intraday key present at all.
        assert_eq!(rows(&bars, "AAPL", "d1"), 1_300, "universe D1 stays deep");
        for key in INTRADAY_KEYS {
            assert!(
                bars["AAPL"].get(key).is_none(),
                "universe must never ship intraday ({key})"
            );
        }
    }

    /// A range-preset `Sync` may lift D1 to the store maximum; intraday stays
    /// capped regardless (a longer intraday span means a coarser interval).
    #[test]
    fn deep_sync_lifts_d1_but_intraday_stays_capped() {
        let store = BarStore::new();
        for interval in Interval::ALL {
            seed(&store, "BTC-USD", interval, 3_000);
        }
        seed(&store, "AAPL", Interval::D1, 3_000);

        let symbols = vec!["BTC-USD".to_string()];
        let universe = vec!["AAPL".to_string()];
        let bars = build_bars_map(&store, &symbols, &universe, 3_000);

        assert_eq!(rows(&bars, "BTC-USD", "d1"), 3_000, "D1 honours the deep ask");
        assert_eq!(rows(&bars, "AAPL", "d1"), 3_000, "universe D1 too");
        for key in INTRADAY_KEYS {
            assert_eq!(
                rows(&bars, "BTC-USD", key),
                INTRADAY_SNAPSHOT_BARS,
                "intraday {key} still capped at 3000-bar sync"
            );
        }
    }

    /// The cap is a CEILING, not a floor: a client asking for fewer than the
    /// intraday cap gets exactly what it asked for across all intervals, and
    /// the request is clamped to the store's own bounds (min 10, max 3000).
    #[test]
    fn small_request_scales_every_interval_and_clamps() {
        let store = BarStore::new();
        for interval in Interval::ALL {
            seed(&store, "BTC-USD", interval, 3_000);
        }
        let symbols = vec!["BTC-USD".to_string()];

        // Below the intraday cap: every interval returns the requested count.
        let bars = build_bars_map(&store, &symbols, &[], 50);
        assert_eq!(rows(&bars, "BTC-USD", "d1"), 50);
        for key in INTRADAY_KEYS {
            assert_eq!(rows(&bars, "BTC-USD", key), 50, "intraday {key} scales down");
        }

        // Below the store floor (10): clamped up, never zero.
        let clamped = build_bars_map(&store, &symbols, &[], 1);
        assert_eq!(rows(&clamped, "BTC-USD", "d1"), 10);

        // Above the store ceiling (3000): clamped down to what the store holds.
        let maxed = build_bars_map(&store, &symbols, &[], 9_999);
        assert_eq!(rows(&maxed, "BTC-USD", "d1"), 3_000);
    }

    /// Size sanity: with every interval maxed, the slim connect profile keeps
    /// TOTAL rows far below the old "all intervals at full depth" blob. Per
    /// configured symbol the profile is `D1(≤n) + 5×INTRADAY_SNAPSHOT_BARS`;
    /// per universe symbol it is `D1(≤n)` only.
    #[test]
    fn total_row_count_stays_within_caps() {
        let store = BarStore::new();
        for interval in Interval::ALL {
            seed(&store, "BTC-USD", interval, 3_000);
            seed(&store, "ETH-USD", interval, 3_000);
        }
        for sym in ["AAPL", "MSFT", "NVDA"] {
            seed(&store, sym, Interval::D1, 3_000);
            seed(&store, sym, Interval::M1, 3_000); // must be ignored
        }
        let symbols = vec!["BTC-USD".to_string(), "ETH-USD".to_string()];
        let universe = vec!["AAPL".to_string(), "MSFT".to_string(), "NVDA".to_string()];

        let bars = build_bars_map(&store, &symbols, &universe, 1_300);
        let total: usize = bars
            .values()
            .flat_map(|s| s.as_object().into_iter().flat_map(|o| o.values()))
            .filter_map(|v| v.as_array().map(|a| a.len()))
            .sum();

        // Old worst case for this fixture (every interval at full 3000):
        //   2 configured × 6 × 3000  +  3 universe × 1 × 3000 = 45,000 rows.
        // Slim profile:
        //   2 × (1300 + 5×400)  +  3 × 1300 = 6600 + 3900 = 10,500 rows.
        let per_configured = 1_300 + 5 * INTRADAY_SNAPSHOT_BARS;
        let expected = symbols.len() * per_configured + universe.len() * 1_300;
        assert_eq!(total, expected);
        assert_eq!(total, 10_500);
        assert!(total < 45_000, "slim profile must cut most of the payload");
    }

    fn sample_depth(symbol: &str) -> BookDepth {
        BookDepth {
            symbol: symbol.to_string(),
            bids: vec![BookLevel::agg(100.0, 1.0, 1)],
            asks: vec![BookLevel::agg(101.0, 1.0, 1)],
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
