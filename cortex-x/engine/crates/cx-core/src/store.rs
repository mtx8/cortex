//! Shared, thread-safe bar history. Market data writes; strategies, agents
//! and the server read. Pure data structure — no IO, no bus.

use std::collections::HashMap;
use std::sync::RwLock;

use crate::events::Bar;
use crate::types::Interval;

const MAX_BARS: usize = 1_200;

#[derive(Default)]
pub struct BarStore {
    inner: RwLock<HashMap<(String, Interval), Vec<Bar>>>,
    last_price: RwLock<HashMap<String, f64>>,
}

impl BarStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// Insert or replace the forming bar. A bar with the same ts_open_ms as
    /// the tail replaces it (forming -> complete rollup); newer appends.
    pub fn push(&self, bar: Bar) {
        let mut map = self.inner.write().unwrap_or_else(|p| p.into_inner());
        let series = map
            .entry((bar.symbol.clone(), bar.interval))
            .or_insert_with(|| Vec::with_capacity(256));
        match series.last_mut() {
            Some(last) if last.ts_open_ms == bar.ts_open_ms => *last = bar,
            Some(last) if last.ts_open_ms > bar.ts_open_ms => {
                // Out-of-order (backfill after live start): insert sorted.
                let idx = series.partition_point(|b| b.ts_open_ms < bar.ts_open_ms);
                if series.get(idx).map(|b| b.ts_open_ms) == Some(bar.ts_open_ms) {
                    series[idx] = bar;
                } else {
                    series.insert(idx, bar);
                }
            }
            _ => series.push(bar),
        }
        if series.len() > MAX_BARS {
            let excess = series.len() - MAX_BARS;
            series.drain(..excess);
        }
    }

    pub fn set_last_price(&self, symbol: &str, px: f64) {
        if px.is_finite() && px > 0.0 {
            self.last_price
                .write()
                .unwrap_or_else(|p| p.into_inner())
                .insert(symbol.to_string(), px);
        }
    }

    pub fn last_price(&self, symbol: &str) -> Option<f64> {
        self.last_price
            .read()
            .unwrap_or_else(|p| p.into_inner())
            .get(symbol)
            .copied()
    }

    pub fn recent(&self, symbol: &str, interval: Interval, n: usize) -> Vec<Bar> {
        let map = self.inner.read().unwrap_or_else(|p| p.into_inner());
        match map.get(&(symbol.to_string(), interval)) {
            Some(series) => {
                let start = series.len().saturating_sub(n);
                series[start..].to_vec()
            }
            None => Vec::new(),
        }
    }

    pub fn symbols(&self) -> Vec<String> {
        let map = self.last_price.read().unwrap_or_else(|p| p.into_inner());
        map.keys().cloned().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bar(ts: i64, close: f64) -> Bar {
        Bar {
            symbol: "BTC-USD".into(),
            interval: Interval::M1,
            ts_open_ms: ts,
            open: close,
            high: close,
            low: close,
            close,
            volume: 1.0,
            trade_count: 1,
            vwap: close,
            complete: false,
        }
    }

    #[test]
    fn forming_bar_replaces_tail() {
        let store = BarStore::new();
        store.push(bar(60_000, 100.0));
        store.push(bar(60_000, 101.0));
        store.push(bar(120_000, 102.0));
        let recent = store.recent("BTC-USD", Interval::M1, 10);
        assert_eq!(recent.len(), 2);
        assert_eq!(recent[0].close, 101.0);
        assert_eq!(recent[1].close, 102.0);
    }

    #[test]
    fn out_of_order_backfill_inserts_sorted() {
        let store = BarStore::new();
        store.push(bar(180_000, 3.0));
        store.push(bar(60_000, 1.0));
        store.push(bar(120_000, 2.0));
        let recent = store.recent("BTC-USD", Interval::M1, 10);
        let ts: Vec<i64> = recent.iter().map(|b| b.ts_open_ms).collect();
        assert_eq!(ts, vec![60_000, 120_000, 180_000]);
    }
}
