//! Shared, thread-safe bar history. Market data writes; strategies, agents
//! and the server read. Pure data structure — no IO, no bus.

use std::collections::HashMap;
use std::sync::RwLock;

use crate::events::Bar;
use crate::types::{Interval, Venue};

const MAX_BARS: usize = 3_000;

#[derive(Default)]
pub struct BarStore {
    inner: RwLock<HashMap<(String, Interval), Vec<Bar>>>,
    last_price: RwLock<HashMap<String, f64>>,
    /// Which venue produced each symbol's CURRENT mark, when the feed that set
    /// it declared one.
    ///
    /// Exists so the order path can tell a real print from a fabricated one. The
    /// synthetic GBM fallback writes marks into this same store as real quotes,
    /// and nothing downstream could distinguish them — so a failed market-data
    /// websocket could size and route orders off invented prices. Provenance is
    /// recorded here rather than replacing `set_last_price`, whose signature is
    /// used by ~50 call sites.
    mark_venue: RwLock<HashMap<String, Venue>>,
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

    /// Set the mark with UNDECLARED provenance.
    ///
    /// Any previously recorded venue is cleared: a stale "synthetic" label
    /// outliving the mark it described would keep gating orders after real prices
    /// returned. Prefer [`set_last_price_from`] in feed code.
    pub fn set_last_price(&self, symbol: &str, px: f64) {
        if px.is_finite() && px > 0.0 {
            self.last_price
                .write()
                .unwrap_or_else(|p| p.into_inner())
                .insert(symbol.to_string(), px);
            self.mark_venue
                .write()
                .unwrap_or_else(|p| p.into_inner())
                .remove(symbol);
        }
    }

    /// Set the mark AND record which venue produced it. Feed code should use
    /// this so downstream gates can tell a real print from a fabricated one.
    /// A real print overwrites a synthetic label, so recovery clears itself.
    pub fn set_last_price_from(&self, symbol: &str, px: f64, venue: Venue) {
        if px.is_finite() && px > 0.0 {
            self.last_price
                .write()
                .unwrap_or_else(|p| p.into_inner())
                .insert(symbol.to_string(), px);
            self.mark_venue
                .write()
                .unwrap_or_else(|p| p.into_inner())
                .insert(symbol.to_string(), venue);
        }
    }

    /// The venue behind this symbol's current mark, or `None` when the writer
    /// did not declare one.
    pub fn mark_venue(&self, symbol: &str) -> Option<Venue> {
        self.mark_venue
            .read()
            .unwrap_or_else(|p| p.into_inner())
            .get(symbol)
            .copied()
    }

    /// True only when this symbol's mark is KNOWN to be fabricated by the
    /// synthetic fallback.
    ///
    /// Deliberately false for an undeclared mark rather than defaulting to
    /// "unsafe": the gate this feeds must never halt trading on a symbol merely
    /// because its feed does not report provenance. It is a strict improvement
    /// on the previous state, where nothing in the order path could tell.
    pub fn mark_is_synthetic(&self, symbol: &str) -> bool {
        self.mark_venue(symbol) == Some(Venue::Synthetic)
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
