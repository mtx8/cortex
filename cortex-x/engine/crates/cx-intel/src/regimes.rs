//! REGIMES: secular bull/bear classification on daily bars + market breadth.
//! Scans configured symbols + the intel universe; publishes
//! `EngineEvent::RegimeMap` and a tighten-only breadth caution.

use std::sync::Arc;

use cx_core::config::Config;
use cx_core::events::{Bar, Breadth, EngineEvent, RegimeBoard, RegimeRow};
use cx_core::store::BarStore;
use cx_core::time::now_ms;
use cx_core::Bus;

/// Spawn the periodic scanner task (cadence `intel.regime_scan_secs`).
/// Universe D1 history is fetched via Yahoo (already allowlisted) into the
/// shared store; classification itself is pure.
pub fn spawn_scanner(bus: Arc<Bus>, store: Arc<BarStore>, cfg: Config) {
    tokio::spawn(async move {
        let cadence = std::time::Duration::from_secs(cfg.intel.regime_scan_secs.max(300));
        loop {
            // Implemented by the regimes build task (agent D): ensure D1
            // backfill for universe symbols, then classify + publish.
            let board = scan(&store, &universe(&cfg));
            if !board.rows.is_empty() {
                bus.publish(EngineEvent::RegimeMap(board));
            }
            tokio::time::sleep(cadence).await;
        }
    });
}

/// Deduped scan list: configured symbols first, then the intel universe.
pub fn universe(cfg: &Config) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for s in cfg.symbols.iter().chain(cfg.intel.universe.iter()) {
        let s = s.trim().to_uppercase();
        if !s.is_empty() && !out.contains(&s) {
            out.push(s);
        }
    }
    out
}

/// Classify every symbol with enough D1 history; compute breadth.
pub fn scan(store: &BarStore, symbols: &[String]) -> RegimeBoard {
    // Implemented by the regimes build task (agent D).
    let _ = (store, symbols);
    RegimeBoard {
        rows: Vec::new(),
        breadth: Breadth {
            pct_above_200d: None,
            pct_above_50d: None,
            bulls: 0,
            bears: 0,
            entering_bull: 0,
            entering_bear: 0,
            universe_size: 0,
        },
        source: "cboe/yahoo D1 (delayed)".into(),
        ts_ms: now_ms(),
    }
}

/// Pure per-symbol classifier (D1 bars, oldest -> newest). `prev` carries the
/// prior row for day-counting/hysteresis. None when history is insufficient.
pub fn classify(symbol: &str, bars_d1: &[Bar], prev: Option<&RegimeRow>) -> Option<RegimeRow> {
    // Implemented by the regimes build task (agent D).
    let _ = (symbol, bars_d1, prev);
    None
}
