//! Market-maker-attributed LEVEL 2 order book assembler (DAS-style routes).
//!
//! IBKR's `reqMktDepth` (non-smart, per-exchange) streams the book as a series
//! of row updates — `updateMktDepthL2(position, marketMaker, operation, side,
//! price, size)` — where each ROW is one market maker's quote at a price, so the
//! same price can appear on several rows (NSDQ, ARCA, EDGX …). That per-maker
//! attribution is exactly what a DAS Trader Level 2 montage shows.
//!
//! [`L2Book`] maintains those rows by position index per side and renders an
//! honest [`BookDepth`] whose every level carries its `mm` route. It is pure and
//! fully unit-tested so the (feature-gated, gateway-dependent) IBKR adapter only
//! has to forward callbacks into it. The book is emitted with `is_live = true`
//! ONLY because this type is fed exclusively by a genuine live `reqMktDepth`
//! subscription — the delayed CBOE path in `equity.rs` never touches it.
//!
//! IBKR wire conventions (mirrored here):
//!   * `operation`: 0 = insert, 1 = update, 2 = delete
//!   * `side`:      0 = ask, 1 = bid
//!   * `position`:  0-based row index, 0 = top (best)

use cx_core::events::{BookDepth, BookLevel};

/// One attributed row: a single market maker's quote at a price.
#[derive(Debug, Clone, PartialEq)]
struct Row {
    mm: String,
    px: f64,
    sz: f64,
}

/// A live, market-maker-attributed L2 book for one symbol, assembled from IBKR
/// `reqMktDepth` row updates. Rows are held per side in position order (0 = best)
/// exactly as the venue sends them.
#[derive(Debug, Clone)]
pub struct L2Book {
    symbol: String,
    source: String,
    /// side 1 — bids, in venue position order (0 = best/highest).
    bids: Vec<Row>,
    /// side 0 — asks, in venue position order (0 = best/lowest).
    asks: Vec<Row>,
}

impl L2Book {
    /// A fresh empty book. `source` is the honest provenance label carried on
    /// every emitted [`BookDepth`] (e.g. "ibkr L2 (NASDAQ TotalView)").
    pub fn new(symbol: impl Into<String>, source: impl Into<String>) -> Self {
        Self {
            symbol: symbol.into(),
            source: source.into(),
            bids: Vec::new(),
            asks: Vec::new(),
        }
    }

    fn side_mut(&mut self, side: u8) -> &mut Vec<Row> {
        // IBKR: side 1 = bid, 0 = ask.
        if side == 1 { &mut self.bids } else { &mut self.asks }
    }

    /// Apply one `updateMktDepthL2` row update. Out-of-range positions and
    /// non-finite prices/sizes are ignored rather than corrupting the book (a
    /// dropped update is safe — the next snapshot re-lands the level).
    pub fn apply(&mut self, position: i32, mm: &str, operation: i32, side: u8, px: f64, sz: f64) {
        if position < 0 {
            return;
        }
        let pos = position as usize;
        let rows = self.side_mut(side);
        match operation {
            // insert at position (shifts the rest down)
            0 => {
                if !px.is_finite() || px <= 0.0 || !sz.is_finite() || sz < 0.0 {
                    return;
                }
                let row = Row { mm: mm.trim().to_string(), px, sz };
                if pos > rows.len() {
                    return; // a gap would mean a missed prior update; drop, don't pad
                }
                rows.insert(pos, row);
            }
            // update in place
            1 => {
                if !px.is_finite() || px <= 0.0 || !sz.is_finite() || sz < 0.0 {
                    return;
                }
                if let Some(r) = rows.get_mut(pos) {
                    r.mm = mm.trim().to_string();
                    r.px = px;
                    r.sz = sz;
                }
            }
            // delete at position (shifts the rest up)
            2 => {
                if pos < rows.len() {
                    rows.remove(pos);
                }
            }
            _ => {}
        }
    }

    /// Clear both sides — used on a fresh subscription / reconnect so a stale
    /// book can never bleed across a resubscribe.
    pub fn reset(&mut self) {
        self.bids.clear();
        self.asks.clear();
    }

    /// Render the current book as an honest, attributed [`BookDepth`]: every
    /// level carries its market-maker route, bids are sorted best-first
    /// (highest), asks best-first (lowest), and `is_live = true` (this type is
    /// only ever fed by a genuine live `reqMktDepth` subscription). `depth` is
    /// the larger side's row count. Rows are kept per-maker (NOT aggregated by
    /// price), so a DAS-style montage shows each maker on its own line.
    pub fn to_depth(&self, ts_ms: i64) -> BookDepth {
        let mut bids: Vec<BookLevel> = self
            .bids
            .iter()
            .filter(|r| r.px.is_finite() && r.px > 0.0)
            .map(|r| BookLevel::routed(r.px, r.sz.max(0.0), 0, r.mm.clone()))
            .collect();
        // Best bid first (highest). Stable so same-price makers keep venue order.
        bids.sort_by(|a, b| b.px.partial_cmp(&a.px).unwrap_or(std::cmp::Ordering::Equal));

        let mut asks: Vec<BookLevel> = self
            .asks
            .iter()
            .filter(|r| r.px.is_finite() && r.px > 0.0)
            .map(|r| BookLevel::routed(r.px, r.sz.max(0.0), 0, r.mm.clone()))
            .collect();
        // Best ask first (lowest).
        asks.sort_by(|a, b| a.px.partial_cmp(&b.px).unwrap_or(std::cmp::Ordering::Equal));

        let depth = bids.len().max(asks.len()) as u32;
        BookDepth {
            symbol: self.symbol.clone(),
            bids,
            asks,
            depth,
            source: self.source.clone(),
            is_live: true,
            ts_ms,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn book() -> L2Book {
        L2Book::new("AAPL", "ibkr L2 (NASDAQ TotalView)")
    }

    #[test]
    fn insert_builds_attributed_rows_best_first() {
        let mut b = book();
        // bids (side 1): insert three makers at descending prices
        b.apply(0, "NSDQ", 0, 1, 308.44, 200.0);
        b.apply(1, "ARCA", 0, 1, 308.43, 100.0);
        b.apply(2, "EDGX", 0, 1, 308.42, 50.0);
        // asks (side 0)
        b.apply(0, "NSDQ", 0, 0, 308.47, 40.0);
        b.apply(1, "ARCA", 0, 0, 308.48, 80.0);

        let d = b.to_depth(123);
        assert!(d.is_live);
        assert_eq!(d.source, "ibkr L2 (NASDAQ TotalView)");
        assert_eq!(d.bids.len(), 3);
        // best bid first + market-maker attribution present
        assert_eq!(d.bids[0].px, 308.44);
        assert_eq!(d.bids[0].mm.as_deref(), Some("NSDQ"));
        assert_eq!(d.bids[2].mm.as_deref(), Some("EDGX"));
        assert_eq!(d.asks[0].px, 308.47);
        assert_eq!(d.asks[0].mm.as_deref(), Some("NSDQ"));
        assert_eq!(d.depth, 3);
    }

    #[test]
    fn multiple_makers_at_same_price_stay_separate_rows() {
        let mut b = book();
        b.apply(0, "NSDQ", 0, 1, 308.44, 200.0);
        b.apply(1, "ARCA", 0, 1, 308.44, 150.0); // same price, different maker
        let d = b.to_depth(1);
        assert_eq!(d.bids.len(), 2, "same-price makers must NOT be aggregated");
        assert_eq!(d.bids[0].px, d.bids[1].px);
        assert_eq!(d.bids[0].mm.as_deref(), Some("NSDQ"));
        assert_eq!(d.bids[1].mm.as_deref(), Some("ARCA"));
    }

    #[test]
    fn update_and_delete_mutate_in_place() {
        let mut b = book();
        b.apply(0, "NSDQ", 0, 1, 308.44, 200.0);
        b.apply(1, "ARCA", 0, 1, 308.43, 100.0);
        // update row 0's size
        b.apply(0, "NSDQ", 1, 1, 308.44, 350.0);
        assert_eq!(b.to_depth(1).bids[0].sz, 350.0);
        // delete row 0 -> ARCA shifts up to best
        b.apply(0, "", 2, 1, 0.0, 0.0);
        let d = b.to_depth(1);
        assert_eq!(d.bids.len(), 1);
        assert_eq!(d.bids[0].mm.as_deref(), Some("ARCA"));
    }

    #[test]
    fn garbage_and_out_of_range_updates_are_ignored() {
        let mut b = book();
        b.apply(0, "NSDQ", 0, 1, 308.44, 200.0);
        b.apply(5, "X", 1, 1, 1.0, 1.0); // update past end — no-op
        b.apply(2, "X", 0, 1, 1.0, 1.0); // insert leaving a gap — dropped
        b.apply(0, "X", 0, 1, f64::NAN, 1.0); // non-finite price — dropped
        b.apply(-1, "X", 0, 1, 1.0, 1.0); // negative position — dropped
        let d = b.to_depth(1);
        assert_eq!(d.bids.len(), 1);
        assert_eq!(d.bids[0].mm.as_deref(), Some("NSDQ"));
    }

    #[test]
    fn blank_market_maker_collapses_to_none() {
        let mut b = book();
        b.apply(0, "   ", 0, 1, 308.44, 200.0);
        assert_eq!(b.to_depth(1).bids[0].mm, None, "blank route id is None, never empty");
    }

    #[test]
    fn reset_clears_both_sides() {
        let mut b = book();
        b.apply(0, "NSDQ", 0, 1, 308.44, 200.0);
        b.apply(0, "NSDQ", 0, 0, 308.47, 40.0);
        b.reset();
        let d = b.to_depth(1);
        assert!(d.bids.is_empty() && d.asks.is_empty());
    }
}
