//! The IBKR incremental order-book builder — PURE, synchronous, offline.
//!
//! IBKR does not send book snapshots. `reqMktDepth` streams ROW EDITS against a
//! **positional list per side**: `(position, operation, side, price, size)` and,
//! for L2, a `marketMaker`. `position` is a 0-based row index where 0 is the
//! best row; an insert at `p` shifts rows `p..` DOWN, a delete at `p` shifts
//! rows `p+1..` UP. That is the single most-often-botched detail in a depth
//! adapter: implement it as a price-keyed map and the ladder silently desyncs
//! from the venue's indices, after which every later positional edit lands on
//! the wrong level and the book quietly becomes fiction. Here it is a `Vec` per
//! side, edited exactly as the venue describes.
//!
//! ## Why this lives in cx-broker and imports NO `ibapi`
//! The socket layer is behind the `ibkr` cargo feature and cannot be exercised
//! without a running Gateway. The *logic* — the part that can be wrong — has no
//! business being un-testable, so this module is always compiled and always
//! tested in the DEFAULT paper build. The feature-gated wire layer only maps
//! `ibapi`'s `MarketDepth` / `MarketDepthL2` onto [`DepthUpdate`] and forwards.
//!
//! ## Wire conventions (from the IBKR contract — mirrored exactly)
//!   * `operation`: 0 = insert, 1 = update in place, 2 = delete
//!   * `side`: **0 = ASK, 1 = BID** — inverted, this reads as a permanently
//!     crossed market. [`SIDE_ASK`] / [`SIDE_BID`] name it, and a test pins it.
//!   * `position`:  0-based row index, 0 = top of book.
//!
//! ## Hostile input policy
//! Nothing reachable from a socket may panic (release builds are
//! `panic = "abort"` — one bad quote would take the whole trading process
//! down). Every malformed edit is REJECTED and counted, never applied and never
//! papered over: a dropped edit degrades one level until the venue re-sends it,
//! whereas a guessed edit corrupts the ladder permanently.
//!
//! ## The `size == 0` decision (documented once, applied everywhere)
//! IBKR uses size 0 on an insert/update to mean "this level is gone". We
//! deliberately **do NOT** treat it as a delete: the venue's own list still
//! holds that row, so removing it would shift our indices out of alignment with
//! the venue's and misapply every subsequent positional edit. Instead the row is
//! RETAINED in the ladder (index alignment preserved) and SUPPRESSED from the
//! emitted [`BookDepth`] (a zero-size level is not a level). The venue's
//! explicit `operation = 2` is the only thing that removes a row.

use cx_core::events::{BookDepth, BookLevel};

/// IBKR `operation`: insert a new row at `position`, shifting the rest down.
pub const OP_INSERT: i32 = 0;
/// IBKR `operation`: update the row already at `position`, in place.
pub const OP_UPDATE: i32 = 1;
/// IBKR `operation`: delete the row at `position`, shifting the rest up.
pub const OP_DELETE: i32 = 2;

/// IBKR `side`: **0 is the ASK side.** Yes, it is the reverse of the intuitive
/// ordering; getting it backwards inverts the book.
pub const SIDE_ASK: i32 = 0;
/// IBKR `side`: **1 is the BID side.**
pub const SIDE_BID: i32 = 1;

/// Hard ceiling on rows retained per side regardless of what is requested —
/// the ladder is fed by a remote process we do not control, so its memory must
/// be bounded by us, not by it. IBKR's own practical L2 depth is far below it.
const MAX_ROWS_HARD_CAP: usize = 200;

// Rejection reasons. `&'static str` so the caller can log/count them without
// allocating on a hot path fed by a socket.
/// `side` was neither [`SIDE_ASK`] nor [`SIDE_BID`].
pub const REJ_SIDE: &str = "unknown_side";
/// `operation` was none of insert/update/delete.
pub const REJ_OPERATION: &str = "unknown_operation";
/// `position` was negative.
pub const REJ_POSITION_NEGATIVE: &str = "negative_position";
/// `position` was at or beyond the requested depth — outside the book we asked
/// for, so we never held that row.
pub const REJ_POSITION_BEYOND_DEPTH: &str = "position_beyond_depth";
/// An insert whose `position` is past the end of the side. Accepting it would
/// require padding phantom rows, which fabricates levels; a gap means a prior
/// edit was missed and the ladder is already suspect.
pub const REJ_GAP: &str = "insert_leaves_gap";
/// An update or delete addressing a row this side does not have (includes every
/// edit against an empty side).
pub const REJ_OUT_OF_RANGE: &str = "position_out_of_range";
/// Price was non-finite (NaN / ±inf) or non-positive.
pub const REJ_PRICE: &str = "bad_price";
/// Size was non-finite (NaN / ±inf) or negative.
pub const REJ_SIZE: &str = "bad_size";

/// One IBKR depth row edit, in CORTEX's own vocabulary.
///
/// Deliberately NOT an `ibapi` type: keeping the shape local is what lets this
/// whole module compile and test in the default paper build. The `ibkr`-gated
/// wire layer performs the mapping (see the crate docs for the exact table).
#[derive(Debug, Clone, PartialEq)]
pub struct DepthUpdate {
    /// 0-based row index within the side; 0 is the best row.
    pub position: i32,
    /// [`OP_INSERT`] / [`OP_UPDATE`] / [`OP_DELETE`].
    pub operation: i32,
    /// [`SIDE_ASK`] (0) or [`SIDE_BID`] (1).
    pub side: i32,
    pub price: f64,
    pub size: f64,
    /// The venue's attribution for this row — the MPID for a single-exchange
    /// book, the exchange for a SMART-aggregated one, and `None` for the
    /// unattributed L1-style `MarketDepth` message. NEVER synthesised.
    pub market_maker: Option<String>,
}

impl DepthUpdate {
    /// An UNATTRIBUTED row edit — the mapping for `ibapi`'s `MarketDepth`,
    /// which carries no market maker at all.
    pub fn unattributed(position: i32, operation: i32, side: i32, price: f64, size: f64) -> Self {
        Self { position, operation, side, price, size, market_maker: None }
    }

    /// An ATTRIBUTED row edit — the mapping for `ibapi`'s `MarketDepthL2`,
    /// whose `market_maker` is the exchange when `smart_depth` is set and the
    /// MPID otherwise. Blank/whitespace ids collapse to `None` on ingest so the
    /// UI never renders an empty route badge.
    pub fn attributed(
        position: i32,
        operation: i32,
        side: i32,
        price: f64,
        size: f64,
        market_maker: impl Into<String>,
    ) -> Self {
        Self {
            position,
            operation,
            side,
            price,
            size,
            market_maker: Some(market_maker.into()),
        }
    }
}

/// What [`DepthBook::apply`] did with an edit. Rejections carry a stable
/// `&'static str` reason so the wire layer can rate-limit-log and count them —
/// a silent drop is how a desynced book goes unnoticed for a whole session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApplyOutcome {
    Applied,
    Rejected(&'static str),
}

impl ApplyOutcome {
    pub fn is_applied(self) -> bool {
        matches!(self, Self::Applied)
    }
    /// The rejection reason, or `None` when the edit was applied.
    pub fn reject_reason(self) -> Option<&'static str> {
        match self {
            Self::Applied => None,
            Self::Rejected(r) => Some(r),
        }
    }
}

/// One row of the ladder, exactly as the venue indexes it.
#[derive(Debug, Clone, PartialEq)]
struct Row {
    px: f64,
    sz: f64,
    mm: Option<String>,
}

/// An incremental IBKR depth ladder for ONE symbol.
///
/// Pure and synchronous: no clock, no bus, no I/O, no locks — the timestamp is
/// supplied by the caller at render time. That is what makes the hostile-input
/// behaviour below testable offline instead of only observable in production.
#[derive(Debug, Clone)]
pub struct DepthBook {
    symbol: String,
    source: String,
    /// Rows requested per side (IBKR's `number_of_rows`), and therefore the
    /// ladder's own bound. Clamped to `1..=MAX_ROWS_HARD_CAP`.
    max_rows: usize,
    /// side 1 — bids, in venue position order (0 = best).
    bids: Vec<Row>,
    /// side 0 — asks, in venue position order (0 = best).
    asks: Vec<Row>,
    /// Lifetime count of rejected edits. Non-zero means the ladder may have
    /// drifted from the venue's; the wire layer surfaces it rather than hiding
    /// it, and a resubscribe (`reset`) is the honest repair.
    rejected: u64,
}

impl DepthBook {
    /// A fresh empty ladder. `source` is the honest provenance label stamped on
    /// every emitted [`BookDepth`] (e.g. `"ibkr L2 (NASDAQ TotalView)"`);
    /// `rows` is the depth actually requested from the venue.
    pub fn new(symbol: impl Into<String>, source: impl Into<String>, rows: usize) -> Self {
        Self {
            symbol: symbol.into(),
            source: source.into(),
            max_rows: rows.clamp(1, MAX_ROWS_HARD_CAP),
            bids: Vec::new(),
            asks: Vec::new(),
            rejected: 0,
        }
    }

    pub fn symbol(&self) -> &str {
        &self.symbol
    }

    pub fn source(&self) -> &str {
        &self.source
    }

    /// Rows retained per side as `(bids, asks)` — INCLUDING zero-size rows,
    /// which are held for index alignment but never emitted.
    pub fn row_counts(&self) -> (usize, usize) {
        (self.bids.len(), self.asks.len())
    }

    /// Lifetime rejected-edit count (see [`DepthBook::rejected`] rationale).
    pub fn rejected_total(&self) -> u64 {
        self.rejected
    }

    /// Clear both sides. MANDATORY on a fresh subscription / reconnect: IBKR
    /// re-sends the whole book by position from row 0, so a stale ladder left
    /// in place would be edited by indices that refer to a different book.
    pub fn reset(&mut self) {
        self.bids.clear();
        self.asks.clear();
    }

    /// Fold one venue edit into the ladder. Never panics, never partially
    /// applies: an edit is either fully valid and applied, or rejected whole.
    pub fn apply(&mut self, u: &DepthUpdate) -> ApplyOutcome {
        let out = self.apply_inner(u);
        if out.reject_reason().is_some() {
            self.rejected = self.rejected.saturating_add(1);
        }
        out
    }

    fn apply_inner(&mut self, u: &DepthUpdate) -> ApplyOutcome {
        // Validate the side FIRST and explicitly. A defaulting `else` branch
        // here (`if side == 1 { bid } else { ask }`) would route a garbage side
        // onto the asks and quietly poison the book.
        let is_bid = match u.side {
            SIDE_BID => true,
            SIDE_ASK => false,
            _ => return ApplyOutcome::Rejected(REJ_SIDE),
        };
        if u.position < 0 {
            return ApplyOutcome::Rejected(REJ_POSITION_NEGATIVE);
        }
        let pos = u.position as usize;
        // Rows past the requested depth are outside the book we subscribed to.
        // Dropping them is index-SAFE: an insert or delete at a position below
        // our cap is unaffected by rows above it, so the top-N stays faithful.
        if pos >= self.max_rows {
            return ApplyOutcome::Rejected(REJ_POSITION_BEYOND_DEPTH);
        }
        let max_rows = self.max_rows; // copied out: `rows` borrows `self` below.

        match u.operation {
            OP_INSERT | OP_UPDATE => {
                // Delete carries no meaningful price/size (IBKR sends zeros), so
                // these checks belong to the value-bearing operations only.
                if !u.price.is_finite() || u.price <= 0.0 {
                    return ApplyOutcome::Rejected(REJ_PRICE);
                }
                // size 0 IS legal (see the module docs) — negative and
                // non-finite are not.
                if !u.size.is_finite() || u.size < 0.0 {
                    return ApplyOutcome::Rejected(REJ_SIZE);
                }
                let row = Row {
                    px: u.price,
                    sz: u.size,
                    mm: normalize_mm(u.market_maker.as_deref()),
                };
                let rows = if is_bid { &mut self.bids } else { &mut self.asks };
                if u.operation == OP_INSERT {
                    // `pos == len` is an append and perfectly ordinary; only a
                    // genuine GAP is refused.
                    if pos > rows.len() {
                        return ApplyOutcome::Rejected(REJ_GAP);
                    }
                    rows.insert(pos, row);
                    // The venue may push one row off the bottom of the window.
                    if rows.len() > max_rows {
                        rows.truncate(max_rows);
                    }
                } else {
                    match rows.get_mut(pos) {
                        // A full row replacement: IBKR's update carries the
                        // maker as well, so it may legitimately change hands.
                        Some(slot) => *slot = row,
                        None => return ApplyOutcome::Rejected(REJ_OUT_OF_RANGE),
                    }
                }
                ApplyOutcome::Applied
            }
            OP_DELETE => {
                let rows = if is_bid { &mut self.bids } else { &mut self.asks };
                if pos >= rows.len() {
                    // Covers the empty-side case too.
                    return ApplyOutcome::Rejected(REJ_OUT_OF_RANGE);
                }
                rows.remove(pos);
                ApplyOutcome::Applied
            }
            _ => ApplyOutcome::Rejected(REJ_OPERATION),
        }
    }

    /// The best (highest) EMITTABLE bid price, or `None` when that side has no
    /// live size. Derived from the same filter+sort as [`DepthBook::to_depth`]
    /// so what you check is what you publish.
    pub fn best_bid(&self) -> Option<f64> {
        // Scans rather than reading row 0: a venue that mis-orders its rows
        // must not be able to understate the touch, which would let a crossed
        // book slip past `is_crossed`. `emittable` has already excluded NaN.
        emittable(&self.bids).map(|r| r.px).reduce(f64::max)
    }

    /// The best (lowest) EMITTABLE ask price, or `None` when that side has no
    /// live size.
    pub fn best_ask(&self) -> Option<f64> {
        emittable(&self.asks).map(|r| r.px).reduce(f64::min)
    }

    /// Is the book CROSSED (best bid >= best ask)?
    ///
    /// On a SINGLE-VENUE book this cannot happen: one exchange never offers
    /// below its own bid, so a true cross means an edit was dropped or
    /// misapplied and the ladder is lying. We report it and do NOT "repair" it —
    /// reordering the levels would hide exactly the corruption the check exists
    /// to expose.
    ///
    /// Strictly `bid > ask`. A LOCKED book (`bid == ask`) is deliberately NOT
    /// counted here — see [`is_locked`]. Treating locked as corrupt was a real
    /// defect: the shipped default route is `SMART`, whose book is AGGREGATED
    /// across exchanges, and there a locked top (NSDQ bidding 232.50 while ARCA
    /// offers 232.50) is ordinary market structure, not a dropped update. The
    /// caller decides what to do with each condition, because the answer depends
    /// on whether the subscription is aggregated.
    pub fn is_crossed(&self) -> bool {
        match (self.best_bid(), self.best_ask()) {
            (Some(b), Some(a)) => b > a,
            // One side empty is thin, not corrupt.
            _ => false,
        }
    }

    /// Best bid exactly equals best ask. Normal on an aggregated (SMART) book
    /// across venues; on a single-venue book it suggests a stale row.
    pub fn is_locked(&self) -> bool {
        match (self.best_bid(), self.best_ask()) {
            (Some(b), Some(a)) => b == a,
            _ => false,
        }
    }

    /// Render the ladder as a CORTEX [`BookDepth`], bids best-first (high→low)
    /// and asks best-first (low→high).
    ///
    /// The venue already sends rows in book order by position, but we SORT
    /// rather than trust: a single misapplied or out-of-order edit would
    /// otherwise reach the UI as a book whose "best" row is not the best price.
    /// Sorting is stable, so same-price rows keep venue (position) order, which
    /// is the time priority a montage is supposed to show.
    ///
    /// `count` is 0 on every level: IBKR depth carries no order count and a
    /// fabricated one would be a lie in a field traders read.
    ///
    /// `is_live` is `true` because this type is fed EXCLUSIVELY by a genuine
    /// live `reqMktDepth` subscription. Never feed it delayed or derived quotes
    /// — the delayed equity path builds its own `BookDepth` with
    /// `is_live = false`, and that boundary is the whole provenance contract.
    pub fn to_depth(&self, ts_ms: i64) -> BookDepth {
        let mut bids = levels(&self.bids);
        // Best bid first (highest price).
        bids.sort_by(|a, b| b.px.partial_cmp(&a.px).unwrap_or(std::cmp::Ordering::Equal));

        let mut asks = levels(&self.asks);
        // Best ask first (lowest price).
        asks.sort_by(|a, b| a.px.partial_cmp(&b.px).unwrap_or(std::cmp::Ordering::Equal));

        BookDepth {
            symbol: self.symbol.clone(),
            bids,
            asks,
            // The REQUESTED depth N, matching the Coinbase L2 publisher's
            // convention — it describes the subscription, not the row count.
            depth: self.max_rows as u32,
            source: self.source.clone(),
            is_live: true,
            ts_ms,
        }
    }
}

/// Rows that represent an actual resting level: zero-size rows are retained in
/// the ladder for index alignment (module docs) but are not levels.
fn emittable(rows: &[Row]) -> impl Iterator<Item = &Row> {
    rows.iter().filter(|r| r.px.is_finite() && r.px > 0.0 && r.sz > 0.0)
}

fn levels(rows: &[Row]) -> Vec<BookLevel> {
    emittable(rows)
        .map(|r| match &r.mm {
            // `routed` collapses a blank id to None on its own; ingest already
            // normalised, this is belt-and-braces.
            Some(mm) => BookLevel::routed(r.px, r.sz, 0, mm.clone()),
            // No attribution from the venue -> honestly anonymous.
            None => BookLevel::agg(r.px, r.sz, 0),
        })
        .collect()
}

/// Trim the venue's maker id; blank/whitespace-only becomes `None` so the UI
/// never shows an empty route badge and `mm` is never a fabricated value.
fn normalize_mm(mm: Option<&str>) -> Option<String> {
    match mm.map(str::trim) {
        Some(s) if !s.is_empty() => Some(s.to_string()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SRC: &str = "ibkr L2 (NASDAQ TotalView)";

    fn book() -> DepthBook {
        DepthBook::new("AAPL", SRC, 10)
    }

    /// insert an attributed row
    fn ins(b: &mut DepthBook, pos: i32, side: i32, px: f64, sz: f64, mm: &str) -> ApplyOutcome {
        b.apply(&DepthUpdate::attributed(pos, OP_INSERT, side, px, sz, mm))
    }
    fn upd(b: &mut DepthBook, pos: i32, side: i32, px: f64, sz: f64, mm: &str) -> ApplyOutcome {
        b.apply(&DepthUpdate::attributed(pos, OP_UPDATE, side, px, sz, mm))
    }
    /// IBKR sends zeros for price/size on a delete — mirror that in tests.
    fn del(b: &mut DepthBook, pos: i32, side: i32) -> ApplyOutcome {
        b.apply(&DepthUpdate::attributed(pos, OP_DELETE, side, 0.0, 0.0, ""))
    }

    /// A three-deep, uncrossed book: bids 308.44/.43/.42, asks 308.47/.48/.49.
    fn seeded() -> DepthBook {
        let mut b = book();
        ins(&mut b, 0, SIDE_BID, 308.44, 200.0, "NSDQ");
        ins(&mut b, 1, SIDE_BID, 308.43, 100.0, "ARCA");
        ins(&mut b, 2, SIDE_BID, 308.42, 50.0, "EDGX");
        ins(&mut b, 0, SIDE_ASK, 308.47, 40.0, "NSDQ");
        ins(&mut b, 1, SIDE_ASK, 308.48, 80.0, "ARCA");
        ins(&mut b, 2, SIDE_ASK, 308.49, 90.0, "BATS");
        b
    }

    // -----------------------------------------------------------------------
    // The side convention. This is the test that stops an inverted book.
    // -----------------------------------------------------------------------

    #[test]
    fn side_zero_is_ask_and_side_one_is_bid() {
        let mut b = book();
        // A bid BELOW an ask. If the side mapping were flipped, this exact
        // input would render as a crossed market.
        ins(&mut b, 0, SIDE_BID, 100.00, 5.0, "NSDQ");
        ins(&mut b, 0, SIDE_ASK, 100.05, 7.0, "ARCA");

        let d = b.to_depth(1);
        assert_eq!(d.bids.len(), 1);
        assert_eq!(d.asks.len(), 1);
        assert_eq!(d.bids[0].px, 100.00, "side 1 must land on the BID side");
        assert_eq!(d.asks[0].px, 100.05, "side 0 must land on the ASK side");
        assert_eq!(b.best_bid(), Some(100.00));
        assert_eq!(b.best_ask(), Some(100.05));
        assert!(!b.is_crossed());
    }

    // -----------------------------------------------------------------------
    // Rendering contract
    // -----------------------------------------------------------------------

    #[test]
    fn renders_sorted_attributed_book_with_honest_metadata() {
        let d = seeded().to_depth(1_700_000_000_123);

        assert_eq!(d.symbol, "AAPL");
        assert_eq!(d.source, SRC);
        assert!(d.is_live, "fed only by a real reqMktDepth subscription");
        assert_eq!(d.ts_ms, 1_700_000_000_123);
        assert_eq!(d.depth, 10, "depth is the REQUESTED N, not the row count");

        // bids high -> low
        assert_eq!(
            d.bids.iter().map(|l| l.px).collect::<Vec<_>>(),
            vec![308.44, 308.43, 308.42]
        );
        // asks low -> high
        assert_eq!(
            d.asks.iter().map(|l| l.px).collect::<Vec<_>>(),
            vec![308.47, 308.48, 308.49]
        );
        assert_eq!(d.bids[0].sz, 200.0);
        assert_eq!(d.bids[0].mm.as_deref(), Some("NSDQ"));
        assert_eq!(d.asks[2].mm.as_deref(), Some("BATS"));
        // IBKR depth carries no order count — never invent one.
        assert!(d.bids.iter().chain(d.asks.iter()).all(|l| l.count == 0));
    }

    #[test]
    fn unsorted_venue_rows_still_emit_best_first() {
        // A venue that violates position order must not produce a book whose
        // "best" row is not the best price. We sort rather than trust.
        let mut b = book();
        ins(&mut b, 0, SIDE_BID, 10.00, 1.0, "A");
        ins(&mut b, 1, SIDE_BID, 10.50, 2.0, "B"); // higher, but at row 1
        ins(&mut b, 0, SIDE_ASK, 11.00, 1.0, "C");
        ins(&mut b, 1, SIDE_ASK, 10.90, 2.0, "D"); // lower, but at row 1

        let d = b.to_depth(1);
        assert_eq!(d.bids[0].px, 10.50);
        assert_eq!(d.asks[0].px, 10.90);
        // The touch is scanned, not read off row 0 — otherwise a mis-ordering
        // venue could understate the spread and hide a cross.
        assert_eq!(b.best_bid(), Some(10.50));
        assert_eq!(b.best_ask(), Some(10.90));
        assert!(!b.is_crossed());
    }

    #[test]
    fn same_price_rows_keep_venue_order_and_are_not_aggregated() {
        let mut b = book();
        ins(&mut b, 0, SIDE_BID, 308.44, 200.0, "NSDQ");
        ins(&mut b, 1, SIDE_BID, 308.44, 150.0, "ARCA"); // same price, other maker

        let d = b.to_depth(1);
        assert_eq!(d.bids.len(), 2, "per-maker rows must not be merged");
        assert_eq!(d.bids[0].mm.as_deref(), Some("NSDQ"), "stable sort keeps time priority");
        assert_eq!(d.bids[1].mm.as_deref(), Some("ARCA"));
    }

    #[test]
    fn unattributed_rows_stay_anonymous_and_blank_makers_collapse() {
        let mut b = book();
        // ibapi's `MarketDepth` (no maker at all) maps to `unattributed`.
        b.apply(&DepthUpdate::unattributed(0, OP_INSERT, SIDE_BID, 5.0, 1.0));
        ins(&mut b, 1, SIDE_BID, 4.0, 1.0, "   "); // whitespace-only id

        let d = b.to_depth(1);
        assert_eq!(d.bids[0].mm, None, "never fabricate a route");
        assert_eq!(d.bids[1].mm, None, "blank id is None, never an empty badge");
    }

    // -----------------------------------------------------------------------
    // Positional semantics — the part that is usually implemented wrongly
    // -----------------------------------------------------------------------

    #[test]
    fn insert_in_the_middle_shifts_rows_down() {
        let mut b = seeded();
        // A new second-best bid arrives at row 1; .43 and .42 shift down.
        assert!(ins(&mut b, 1, SIDE_BID, 308.435, 75.0, "BATS").is_applied());

        let d = b.to_depth(1);
        assert_eq!(
            d.bids.iter().map(|l| l.px).collect::<Vec<_>>(),
            vec![308.44, 308.435, 308.43, 308.42]
        );
        assert_eq!(b.row_counts().0, 4);
    }

    #[test]
    fn delete_shifts_rows_up() {
        let mut b = seeded();
        assert!(del(&mut b, 0, SIDE_BID).is_applied());

        let d = b.to_depth(1);
        assert_eq!(
            d.bids.iter().map(|l| l.px).collect::<Vec<_>>(),
            vec![308.43, 308.42]
        );
        assert_eq!(d.bids[0].mm.as_deref(), Some("ARCA"), "row 1 became row 0");
        // The ask side is untouched by a bid-side delete.
        assert_eq!(d.asks.len(), 3);
    }

    #[test]
    fn update_replaces_only_the_addressed_row() {
        let mut b = seeded();
        assert!(upd(&mut b, 1, SIDE_BID, 308.431, 999.0, "EDGX").is_applied());

        let d = b.to_depth(1);
        assert_eq!(d.bids[1].px, 308.431);
        assert_eq!(d.bids[1].sz, 999.0);
        assert_eq!(d.bids[1].mm.as_deref(), Some("EDGX"), "an update may change hands");
        assert_eq!(d.bids[0].px, 308.44, "neighbours untouched");
        assert_eq!(d.bids[2].px, 308.42);
        assert_eq!(b.row_counts().0, 3, "update never changes the row count");
    }

    #[test]
    fn duplicate_insert_at_the_same_position_shifts_rather_than_replaces() {
        // Two inserts at row 0 in a row: the venue is prepending, not
        // overwriting. Replacing would silently lose a level.
        let mut b = book();
        ins(&mut b, 0, SIDE_BID, 10.00, 1.0, "A");
        ins(&mut b, 0, SIDE_BID, 10.10, 2.0, "B");

        let d = b.to_depth(1);
        assert_eq!(d.bids.len(), 2);
        assert_eq!(d.bids[0].mm.as_deref(), Some("B"));
        assert_eq!(d.bids[1].mm.as_deref(), Some("A"));
    }

    #[test]
    fn insert_at_end_is_an_append_not_a_gap() {
        let mut b = book();
        assert!(ins(&mut b, 0, SIDE_ASK, 10.0, 1.0, "A").is_applied());
        assert!(ins(&mut b, 1, SIDE_ASK, 11.0, 1.0, "B").is_applied(), "pos == len appends");
        assert_eq!(b.row_counts().1, 2);
    }

    // -----------------------------------------------------------------------
    // Hostile inputs: every one must be rejected, and the ladder must survive
    // -----------------------------------------------------------------------

    #[test]
    fn insert_leaving_a_gap_is_rejected() {
        let mut b = book();
        ins(&mut b, 0, SIDE_BID, 10.0, 1.0, "A");
        // Row 2 with no row 1: padding it would fabricate a level.
        assert_eq!(ins(&mut b, 2, SIDE_BID, 9.0, 1.0, "B"), ApplyOutcome::Rejected(REJ_GAP));
        assert_eq!(b.row_counts().0, 1);
        assert_eq!(b.rejected_total(), 1);
    }

    #[test]
    fn update_or_delete_past_the_end_is_rejected() {
        let mut b = book();
        ins(&mut b, 0, SIDE_BID, 10.0, 1.0, "A");
        assert_eq!(
            upd(&mut b, 5, SIDE_BID, 9.0, 1.0, "B"),
            ApplyOutcome::Rejected(REJ_OUT_OF_RANGE)
        );
        assert_eq!(del(&mut b, 5, SIDE_BID), ApplyOutcome::Rejected(REJ_OUT_OF_RANGE));
        assert_eq!(b.row_counts().0, 1, "ladder unchanged");
        assert_eq!(b.rejected_total(), 2);
    }

    #[test]
    fn delete_on_an_empty_side_is_rejected_not_a_panic() {
        let mut b = book();
        assert_eq!(del(&mut b, 0, SIDE_BID), ApplyOutcome::Rejected(REJ_OUT_OF_RANGE));
        assert_eq!(del(&mut b, 0, SIDE_ASK), ApplyOutcome::Rejected(REJ_OUT_OF_RANGE));
        assert_eq!(b.row_counts(), (0, 0));
    }

    #[test]
    fn negative_position_is_rejected() {
        let mut b = seeded();
        // `position as usize` on a negative i32 would wrap to ~1.8e19 — the
        // exact shape of bug that becomes an allocation or an index panic.
        for op in [OP_INSERT, OP_UPDATE, OP_DELETE] {
            let out = b.apply(&DepthUpdate::attributed(-1, op, SIDE_BID, 10.0, 1.0, "X"));
            assert_eq!(out, ApplyOutcome::Rejected(REJ_POSITION_NEGATIVE));
        }
        assert_eq!(b.row_counts().0, 3);
    }

    #[test]
    fn non_finite_price_or_size_is_rejected() {
        let mut b = seeded();
        for bad in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            assert_eq!(
                ins(&mut b, 0, SIDE_BID, bad, 1.0, "X"),
                ApplyOutcome::Rejected(REJ_PRICE)
            );
            assert_eq!(
                upd(&mut b, 0, SIDE_BID, bad, 1.0, "X"),
                ApplyOutcome::Rejected(REJ_PRICE)
            );
            assert_eq!(
                ins(&mut b, 0, SIDE_BID, 10.0, bad, "X"),
                ApplyOutcome::Rejected(REJ_SIZE)
            );
        }
        // Untouched, and — critically — no NaN ever entered the ladder, so the
        // sort comparators can never see one.
        let d = b.to_depth(1);
        assert_eq!(d.bids.len(), 3);
        assert!(d.bids.iter().all(|l| l.px.is_finite() && l.sz.is_finite()));
    }

    #[test]
    fn zero_or_negative_price_and_negative_size_are_rejected() {
        let mut b = seeded();
        assert_eq!(ins(&mut b, 0, SIDE_BID, 0.0, 1.0, "X"), ApplyOutcome::Rejected(REJ_PRICE));
        assert_eq!(ins(&mut b, 0, SIDE_BID, -1.0, 1.0, "X"), ApplyOutcome::Rejected(REJ_PRICE));
        assert_eq!(ins(&mut b, 0, SIDE_BID, 10.0, -1.0, "X"), ApplyOutcome::Rejected(REJ_SIZE));
        assert_eq!(b.row_counts().0, 3);
    }

    #[test]
    fn unknown_side_and_unknown_operation_are_rejected() {
        let mut b = seeded();
        assert_eq!(
            b.apply(&DepthUpdate::attributed(0, OP_INSERT, 7, 10.0, 1.0, "X")),
            ApplyOutcome::Rejected(REJ_SIDE),
            "a garbage side must NOT default onto a real side"
        );
        assert_eq!(
            b.apply(&DepthUpdate::attributed(0, 9, SIDE_BID, 10.0, 1.0, "X")),
            ApplyOutcome::Rejected(REJ_OPERATION)
        );
        assert_eq!(b.row_counts(), (3, 3));
    }

    // -----------------------------------------------------------------------
    // size == 0: retained for index alignment, suppressed from the output
    // -----------------------------------------------------------------------

    #[test]
    fn zero_size_row_is_retained_for_index_alignment_but_not_emitted() {
        let mut b = seeded();
        // The venue zeroes row 1 rather than deleting it.
        assert!(upd(&mut b, 1, SIDE_BID, 308.43, 0.0, "ARCA").is_applied());

        let d = b.to_depth(1);
        assert_eq!(
            d.bids.iter().map(|l| l.px).collect::<Vec<_>>(),
            vec![308.44, 308.42],
            "a zero-size level is not a level"
        );
        assert_eq!(b.row_counts().0, 3, "but the ROW stays, so indices still match the venue");

        // Proof that alignment held: the venue's next edit addresses row 2,
        // which is still 308.42. Had we removed the zeroed row, this would have
        // been out of range and 308.42 would have been left stale forever.
        assert!(upd(&mut b, 2, SIDE_BID, 308.41, 25.0, "EDGX").is_applied());
        let d = b.to_depth(1);
        assert_eq!(d.bids.iter().map(|l| l.px).collect::<Vec<_>>(), vec![308.44, 308.41]);

        // And it can come back to life in place.
        assert!(upd(&mut b, 1, SIDE_BID, 308.43, 60.0, "ARCA").is_applied());
        assert_eq!(b.to_depth(1).bids.len(), 3);
    }

    #[test]
    fn a_zeroed_best_row_does_not_become_the_best_quote() {
        let mut b = seeded();
        upd(&mut b, 0, SIDE_BID, 308.44, 0.0, "NSDQ");
        assert_eq!(b.best_bid(), Some(308.43), "best quote ignores zero-size rows");
    }

    // -----------------------------------------------------------------------
    // Bounds
    // -----------------------------------------------------------------------

    #[test]
    fn more_rows_than_requested_are_capped() {
        let mut b = DepthBook::new("AAPL", SRC, 3);
        for i in 0..3 {
            assert!(ins(&mut b, i, SIDE_ASK, 10.0 + i as f64, 1.0, "A").is_applied());
        }
        // Beyond the requested window: refused outright.
        assert_eq!(
            ins(&mut b, 3, SIDE_ASK, 13.0, 1.0, "A"),
            ApplyOutcome::Rejected(REJ_POSITION_BEYOND_DEPTH)
        );
        // An insert INSIDE the window pushes the worst row off the bottom
        // instead of growing the ladder.
        assert!(ins(&mut b, 0, SIDE_ASK, 9.0, 1.0, "B").is_applied());
        assert_eq!(b.row_counts().1, 3, "never grows past the requested depth");
        assert_eq!(
            b.to_depth(1).asks.iter().map(|l| l.px).collect::<Vec<_>>(),
            vec![9.0, 10.0, 11.0]
        );
    }

    #[test]
    fn requested_rows_are_clamped_to_a_sane_range() {
        assert_eq!(DepthBook::new("A", SRC, 0).to_depth(1).depth, 1);
        assert_eq!(
            DepthBook::new("A", SRC, usize::MAX).to_depth(1).depth,
            MAX_ROWS_HARD_CAP as u32
        );
    }

    // -----------------------------------------------------------------------
    // Crossed detection
    // -----------------------------------------------------------------------

    #[test]
    fn healthy_book_is_not_crossed() {
        let b = seeded();
        assert!(!b.is_crossed());
        assert_eq!(b.best_bid(), Some(308.44));
        assert_eq!(b.best_ask(), Some(308.47));
    }

    #[test]
    fn empty_or_one_sided_book_is_not_crossed() {
        let mut b = book();
        assert!(!b.is_crossed(), "empty is thin, not corrupt");
        ins(&mut b, 0, SIDE_BID, 10.0, 1.0, "A");
        assert!(!b.is_crossed());
        assert_eq!(b.best_ask(), None);
    }

    #[test]
    fn crossed_book_is_reported_and_never_silently_repaired() {
        let mut b = seeded();
        // A dropped edit leaves a stale bid above the offer.
        assert!(upd(&mut b, 0, SIDE_BID, 308.50, 100.0, "NSDQ").is_applied());
        assert!(b.is_crossed(), "308.50 bid vs 308.47 ask");

        // The garbage is rendered AS IS — each side still correctly sorted, the
        // cross plainly visible. Reordering here would hide the corruption from
        // the caller whose job is to refuse to publish it.
        let d = b.to_depth(1);
        assert_eq!(d.bids[0].px, 308.50);
        assert_eq!(d.asks[0].px, 308.47);
        assert!(d.bids[0].px > d.asks[0].px);
    }

    #[test]
    fn locked_book_is_locked_but_not_crossed() {
        // A LOCKED top (bid == ask) is ordinary market structure on an
        // AGGREGATED book — NSDQ bidding 10.00 while ARCA offers 10.00 — and the
        // shipped default route is SMART. Folding it into `is_crossed` froze a
        // ladder the app still badged LIVE, so the two conditions are reported
        // separately and the publisher decides per subscription type.
        let mut b = book();
        ins(&mut b, 0, SIDE_BID, 10.0, 1.0, "NSDQ");
        ins(&mut b, 0, SIDE_ASK, 10.0, 1.0, "ARCA");
        assert!(b.is_locked(), "bid == ask is locked");
        assert!(!b.is_crossed(), "locked is NOT crossed — a real aggregated book locks");
    }

    #[test]
    fn truly_crossed_book_is_reported() {
        // bid strictly ABOVE ask. On a single venue this cannot happen and means
        // an edit was dropped; the publisher holds the ladder and degrades the
        // feed rather than rendering a lie.
        let mut b = book();
        ins(&mut b, 0, SIDE_BID, 10.05, 1.0, "NSDQ");
        ins(&mut b, 0, SIDE_ASK, 10.00, 1.0, "NSDQ");
        assert!(b.is_crossed());
        assert!(!b.is_locked());
    }

    #[test]
    fn reset_clears_the_ladder_for_a_resubscribe() {
        let mut b = seeded();
        upd(&mut b, 0, SIDE_BID, 308.50, 100.0, "NSDQ");
        assert!(b.is_crossed());

        b.reset();
        assert_eq!(b.row_counts(), (0, 0));
        assert!(!b.is_crossed(), "a reconnect starts from a clean, honest book");
        let d = b.to_depth(1);
        assert!(d.bids.is_empty() && d.asks.is_empty());
        // Identity and provenance survive the reset — only the rows are dropped.
        assert_eq!(d.symbol, "AAPL");
        assert_eq!(d.source, SRC);
    }

    // -----------------------------------------------------------------------
    // Survival
    // -----------------------------------------------------------------------

    #[test]
    fn a_storm_of_hostile_edits_cannot_panic_or_corrupt_the_ladder() {
        // A cheap deterministic fuzz: every operation/side/position/price/size
        // combination including the illegal ones, interleaved. The assertions
        // are the invariants, not any particular resulting book.
        let mut b = DepthBook::new("AAPL", SRC, 5);
        let prices = [10.0, 0.0, -1.0, f64::NAN, f64::INFINITY, 10.5];
        let sizes = [1.0, 0.0, -3.0, f64::NAN, 7.0];
        let mut n: usize = 0;
        for op in [OP_INSERT, OP_UPDATE, OP_DELETE, 42, -1] {
            for side in [SIDE_ASK, SIDE_BID, 5, -2] {
                for pos in [-9_i32, -1, 0, 1, 4, 5, 99, i32::MAX, i32::MIN] {
                    let px = prices[n % prices.len()];
                    let sz = sizes[n % sizes.len()];
                    n += 1;
                    let mm = if n.is_multiple_of(3) { None } else { Some("NSDQ".to_string()) };
                    b.apply(&DepthUpdate {
                        position: pos,
                        operation: op,
                        side,
                        price: px,
                        size: sz,
                        market_maker: mm,
                    });

                    let (nb, na) = b.row_counts();
                    assert!(nb <= 5 && na <= 5, "ladder must stay bounded");
                    let d = b.to_depth(1);
                    assert!(
                        d.bids.iter().chain(d.asks.iter()).all(|l| l.px.is_finite()
                            && l.px > 0.0
                            && l.sz.is_finite()
                            && l.sz > 0.0),
                        "no garbage level may ever reach the wire"
                    );
                    // Emitted sides are always correctly ordered.
                    assert!(d.bids.windows(2).all(|w| w[0].px >= w[1].px));
                    assert!(d.asks.windows(2).all(|w| w[0].px <= w[1].px));
                }
            }
        }
        assert!(b.rejected_total() > 0, "the hostile edits were counted, not hidden");
    }
}
