// Level 2 montage math — pure, NaN-safe, testable. The DAS-style depth ladder
// and time & sales tape are thin views over these helpers: best-first sorting,
// the depth-histogram size-bar fraction, best bid/ask + mid/spread, the
// aggressor→tone mapping, and the honest real/delayed banner. Nothing here
// touches SwiftUI or the model — every function takes plain values so the math
// stays unit-tested and the view stays declarative. Design law: absent /
// garbage input yields nil or an empty result, never a number the UI would
// render as truth, and a feed is NEVER labeled live unless it truly is.

import Foundation

// MARK: - Depth ladder

/// Order-book ladder helpers. The engine already sends bids/asks best-first,
/// but these re-sort defensively (and drop non-finite / non-positive prices) so
/// a lean or scrambled payload still renders a correct ladder.
enum DepthLadder {
    /// Only levels with a real, positive price survive — a 0 / NaN price is
    /// never a tradeable level.
    private static func valid(_ levels: [BookLevel]) -> [BookLevel] {
        levels.filter { $0.px.isFinite && $0.px > 0 }
    }

    /// Bids best-first: highest price at the top.
    static func sortedBids(_ levels: [BookLevel]) -> [BookLevel] {
        valid(levels).sorted { $0.px > $1.px }
    }

    /// Asks best-first: lowest price at the top.
    static func sortedAsks(_ levels: [BookLevel]) -> [BookLevel] {
        valid(levels).sorted { $0.px < $1.px }
    }

    /// The largest finite, positive size across BOTH sides — the shared scale
    /// for the depth histogram so a bid bar and an ask bar of equal size read
    /// equal. 0 when no side has a usable size (every bar then renders empty).
    static func maxSize(bids: [BookLevel], asks: [BookLevel]) -> Double {
        (bids + asks)
            .map(\.sz)
            .filter { $0.isFinite && $0 > 0 }
            .max() ?? 0
    }

    /// The 0…1 fill fraction for a level's size bar against the shared scale.
    /// NaN-safe: a non-finite size, or a non-positive scale, yields 0; anything
    /// over the scale clamps to 1.
    static func barFraction(size: Double, maxSize: Double) -> Double {
        guard size.isFinite, size > 0, maxSize.isFinite, maxSize > 0 else { return 0 }
        return min(size / maxSize, 1)
    }

    /// Mid price from the best bid/ask. nil unless both are finite and positive
    /// — a one-sided book has no honest mid.
    static func mid(bestBid: Double?, bestAsk: Double?) -> Double? {
        guard let b = bestBid, let a = bestAsk,
            b.isFinite, a.isFinite, b > 0, a > 0 else { return nil }
        return (b + a) / 2
    }

    /// Bid/ask spread. nil unless both sides are finite, positive, and the ask
    /// is at or above the bid (a crossed book has no meaningful spread).
    static func spread(bestBid: Double?, bestAsk: Double?) -> Double? {
        guard let b = bestBid, let a = bestAsk,
            b.isFinite, a.isFinite, b > 0, a > 0, a >= b else { return nil }
        return a - b
    }

    // MARK: Centered-ladder visible slices (best-first, nearest the spread)

    /// The visible ASK rows in TOP→BOTTOM display order for the centered ladder:
    /// the `count` asks nearest the inside market (best-first) reversed, so the
    /// HIGHEST shown ask sits at the top and the BEST ask sits last — directly
    /// above the spread row. `count <= 0` yields none; an over-long count clamps.
    static func visibleAskRows(_ asksBestFirst: [BookLevel], count: Int) -> [BookLevel] {
        Array(asksBestFirst.prefix(max(0, count))).reversed()
    }

    /// The visible BID rows in TOP→BOTTOM display order: the BEST bid first
    /// (directly below the spread row), lower bids beneath it — the `count` bids
    /// nearest the inside market (best-first), unreversed.
    static func visibleBidRows(_ bidsBestFirst: [BookLevel], count: Int) -> [BookLevel] {
        Array(bidsBestFirst.prefix(max(0, count)))
    }
}

// MARK: - Centered depth-ladder layout (fill + center the inside market)

/// How a centered price-ladder (DOM) packs into a fixed-height pane: asks stack
/// ABOVE a thin inside-market spread row, bids BELOW it, and the spread row sits
/// dead-center so the ladder fills top-to-bottom with the inside market in the
/// middle — never bottom-anchored, never a void above the rows. Pure + NaN-safe
/// so the fill/centre math is unit-tested independent of SwiftUI.
///
/// The pane is split into two equal side-heights around the centered spread row.
/// Each side shows the levels nearest the inside market that fit; leftover height
/// becomes padding at the OUTER edges (the thin top/bottom of the book), which
/// keeps the spread row centered whether the book is deep, shallow, or one-sided.
struct LadderLayout: Equatable {
    /// Ask rows shown above the spread (nearest the inside market first).
    var visibleAsks: Int
    /// Bid rows shown below the spread.
    var visibleBids: Int
    /// Empty height above the top-most (highest) shown ask — the top of book.
    var topPad: Double
    /// Empty height below the bottom-most (lowest) shown bid — the bottom of book.
    var bottomPad: Double
    /// Rows that fit on ONE side of the centered spread row (per-side capacity).
    var perSideCapacity: Int

    /// Fit the ladder into `height`, centring the spread row of `spreadHeight`.
    /// Non-finite / non-positive geometry yields an empty layout (renders nothing
    /// rather than a bogus fill); negative counts are treated as zero.
    static func fit(
        height: Double, rowHeight: Double, spreadHeight: Double,
        askCount: Int, bidCount: Int
    ) -> LadderLayout {
        guard height.isFinite, height > 0,
            rowHeight.isFinite, rowHeight > 0,
            spreadHeight.isFinite, spreadHeight >= 0
        else {
            return LadderLayout(
                visibleAsks: 0, visibleBids: 0,
                topPad: 0, bottomPad: 0, perSideCapacity: 0
            )
        }
        let asks = max(0, askCount)
        let bids = max(0, bidCount)
        // Height available on ONE side of the centered spread row.
        let sideHeight = max(0, (height - spreadHeight) / 2)
        let capacity = max(0, Int((sideHeight / rowHeight).rounded(.down)))
        let vAsks = min(asks, capacity)
        let vBids = min(bids, capacity)
        // Pad so the spread row is centered: each level block hugs the spread,
        // the remainder pushes to the outer edge. topPad + vAsks*row == sideHeight
        // == bottomPad + vBids*row, so the inside market lands at height/2.
        let topPad = max(0, sideHeight - Double(vAsks) * rowHeight)
        let bottomPad = max(0, sideHeight - Double(vBids) * rowHeight)
        return LadderLayout(
            visibleAsks: vAsks, visibleBids: vBids,
            topPad: topPad, bottomPad: bottomPad, perSideCapacity: capacity
        )
    }
}

// MARK: - Centered-ladder row geometry (draw + hit-test share one source)

/// One drawn ladder row's vertical span plus the model level it represents, in
/// TOP→BOTTOM display order. The Canvas ladder paints these rows and the click
/// hit-test maps a click y back to one, so the pixels the operator sees and the
/// price a click seats into the ticket can never drift apart. The centered
/// spread band carries no level.
struct LadderRowLayout: Equatable {
    enum Kind: Equatable { case ask, bid, spread }
    var kind: Kind
    /// Row top, in the ladder's local (Canvas) coordinate space.
    var minY: Double
    var height: Double
    /// The book level for an ask/bid row; nil for the centered spread band.
    var level: BookLevel?
    /// The inside-market row on its side (best ask / best bid) — drawn bold.
    var isBest: Bool

    var maxY: Double { minY + height }
}

/// Pure geometry for the Canvas ladder: turn a fitted `LadderLayout` plus the
/// visible (display-ordered) ask/bid slices into the exact top→bottom row
/// rectangles the Canvas paints, and hit-test a click y back to the level whose
/// row spans it. No SwiftUI here so the row math + click mapping stay
/// unit-tested independent of the renderer.
enum LadderGeometry {
    /// Build the top→bottom row layout: asks stack from `topPad` down to the
    /// centered spread band, then bids stack below it. `asks` and `bids` are the
    /// already-sliced VISIBLE rows in DISPLAY order (asks highest→best, bids
    /// best→lowest), so the best ask is the LAST ask and the best bid is the
    /// FIRST bid — each landing against the spread band, matching the fill math.
    static func rows(
        layout: LadderLayout, asks: [BookLevel], bids: [BookLevel],
        rowHeight: Double, spreadHeight: Double
    ) -> [LadderRowLayout] {
        var out: [LadderRowLayout] = []
        out.reserveCapacity(asks.count + bids.count + 1)
        var y = layout.topPad
        for (i, level) in asks.enumerated() {
            out.append(LadderRowLayout(
                kind: .ask, minY: y, height: rowHeight,
                level: level, isBest: i == asks.count - 1
            ))
            y += rowHeight
        }
        out.append(LadderRowLayout(
            kind: .spread, minY: y, height: spreadHeight, level: nil, isBest: false
        ))
        y += spreadHeight
        for (i, level) in bids.enumerated() {
            out.append(LadderRowLayout(
                kind: .bid, minY: y, height: rowHeight,
                level: level, isBest: i == 0
            ))
            y += rowHeight
        }
        return out
    }

    /// The order-book level whose drawn row spans `y`, or nil when the click
    /// lands on the spread band or the outer padding (no tradeable level there).
    /// Rows are half-open `[minY, maxY)` so two adjacent rows never both claim a
    /// boundary pixel.
    static func level(atY y: Double, rows: [LadderRowLayout]) -> BookLevel? {
        for row in rows where row.kind != .spread {
            if y >= row.minY, y < row.maxY { return row.level }
        }
        return nil
    }
}

// MARK: - Two-column montage layout (modern side-by-side bid | ask)

/// One montage row: a single price level in one column, in top→bottom display
/// order — the inside market (best bid / best ask) at the TOP, deeper levels
/// below. The Canvas paints these rows and the click hit-test maps a click y
/// back to one, so the pixels the operator sees and the price a click seats into
/// the ticket can never drift apart.
struct MontageRow: Equatable {
    var minY: Double
    var height: Double
    var level: BookLevel
    /// 0 = inside market (best bid/ask), increasing away from the spread.
    var rank: Int
    var isBest: Bool { rank == 0 }
    var maxY: Double { minY + height }
}

/// Pure geometry for the side-by-side Level 2 montage: bids fill the LEFT column
/// best-first from the top, asks the RIGHT column best-first from the top. Both
/// columns share ONE row height and top origin, so the best bid and best ask sit
/// on the same top row, flanking the spread. NaN-safe; no SwiftUI here so the row
/// math + click mapping stay unit-tested independent of the renderer.
enum DepthMontage {
    /// How many level rows fit a column of `height` at `rowHeight`. Non-finite /
    /// non-positive geometry fits none.
    static func rowCapacity(height: Double, rowHeight: Double) -> Int {
        guard height.isFinite, height > 0, rowHeight.isFinite, rowHeight > 0 else { return 0 }
        return max(0, Int((height / rowHeight).rounded(.down)))
    }

    /// Build ONE column's top→bottom rows from best-first levels, capped to what
    /// fits. `topY` is where the first row starts; the best level is rank 0 at the
    /// top. A non-positive capacity / row height yields no rows.
    static func column(
        _ bestFirst: [BookLevel], rowHeight: Double, capacity: Int, topY: Double
    ) -> [MontageRow] {
        guard rowHeight.isFinite, rowHeight > 0, capacity > 0 else { return [] }
        var out: [MontageRow] = []
        var y = topY.isFinite ? topY : 0
        for (i, level) in bestFirst.prefix(capacity).enumerated() {
            out.append(MontageRow(minY: y, height: rowHeight, level: level, rank: i))
            y += rowHeight
        }
        return out
    }

    /// The level whose drawn row spans `y`, or nil past the last row. Rows are
    /// half-open `[minY, maxY)` so adjacent rows never both claim a boundary pixel.
    static func level(atY y: Double, rows: [MontageRow]) -> BookLevel? {
        for row in rows where y >= row.minY && y < row.maxY { return row.level }
        return nil
    }

    /// Sum of a side's visible sizes — the cumulative depth for the imbalance
    /// readout. Non-finite / non-positive sizes are skipped.
    static func cumulativeSize(_ levels: [BookLevel]) -> Double {
        levels.reduce(0) { $0 + (($1.sz.isFinite && $1.sz > 0) ? $1.sz : 0) }
    }

    /// Book imbalance in −1…1: (bid − ask) / (bid + ask). 0 when both sides are
    /// empty. Positive = bid-heavy (resting buy pressure), negative = ask-heavy.
    static func imbalance(bidTotal: Double, askTotal: Double) -> Double {
        let sum = bidTotal + askTotal
        guard sum.isFinite, sum > 0 else { return 0 }
        let v = (bidTotal - askTotal) / sum
        return Swift.min(Swift.max(v, -1), 1)
    }
}

// MARK: - Tape aggressor tone

/// The direction a tape print pushed the market, decoupled from SwiftUI so the
/// mapping is unit-tested: buy = lifted the ask (up), sell = hit the bid
/// (down), unknown = neutral (dim). The view maps these three tones to the
/// design tokens (up / down / dim) — the only place green/red mean direction.
enum AggressorTone: Equatable {
    case up, down, neutral

    static func tone(for aggressor: Side?) -> AggressorTone {
        switch aggressor {
        case .buy: .up
        case .sell: .down
        case nil: .neutral
        }
    }
}

// MARK: - Real / delayed banner

/// The honest source banner state derived from a BookDepth's `is_live` flag.
/// The cardinal rule: `live` appears ONLY for depth the engine vouched for as
/// real-time — anything else (no book yet, or `is_live == false`) reads as
/// waiting or delayed, never live. Pure so the honesty rule is unit-tested.
struct DepthBanner: Equatable {
    enum Kind: Equatable { case waiting, live, delayed }

    var kind: Kind
    /// The feed source label ("IBKR", "synthetic L1", …); "—" while waiting.
    var source: String
    /// One honest line for the operator.
    var note: String

    /// Real-time depth the operator can trust as live.
    var isLive: Bool { kind == .live }

    static func make(for depth: BookDepth?) -> DepthBanner {
        guard let depth else {
            return DepthBanner(
                kind: .waiting, source: "—",
                note: "waiting for depth…"
            )
        }
        let source = depth.source.isEmpty ? "unknown" : depth.source
        if depth.is_live {
            return DepthBanner(kind: .live, source: source, note: "real-time depth")
        }
        // Terse on purpose: this is the dock's one-line posture. The pane itself
        // carries the full statement (source, level count, quote age) via
        // `DepthHonesty` — the two must complement, never compete.
        return DepthBanner(
            kind: .delayed, source: source,
            note: "delayed L1 — a top-of-book stand-in, not an order book; "
                + "real Level 2 comes with IB Gateway"
        )
    }
}

// MARK: - Depth & tape honesty (what the panes may truthfully say)

/// The posture of one symbol's Level 2 feed, decided ONLY from facts the engine
/// reports — the subscription state and the frame's own `is_live` — never
/// inferred from how much data happened to show up. A thin book is not the same
/// thing as a missing one, and neither may ever read as a live order book.
enum DepthFeedState: Equatable {
    /// No depth subscription targets this symbol. Nothing was ever asked for,
    /// so nothing is on its way — this is NOT a loading state.
    case unsubscribed
    /// Subscribed and genuinely waiting: the first frame has not landed yet.
    case waiting
    /// Real-time depth the engine vouched for (Coinbase crypto, IBKR L2).
    case live
    /// A frame arrived but the engine did NOT vouch for it as real-time. On the
    /// keyless equity feed this is one synthetic level per side, derived from a
    /// delayed top-of-book quote — a stand-in, not an order book.
    case delayed
}

/// Everything the depth / tape notices depend on, as plain values: no model, no
/// view state, no clock. Built once per render by the panes so the selection
/// below stays a pure function of facts and every combination is testable.
struct DepthFeedFacts: Equatable {
    /// `AppModel.isEquity(symbol)`. Equities run the keyless delayed feed (no
    /// book, no tape); crypto streams a real book and a real tape.
    var isEquity: Bool
    /// A depth subscription is targeting this symbol (`depthSymbol != nil`).
    var isSubscribed: Bool
    /// A depth frame has landed (the model's `bookDepth` is non-nil).
    var hasDepth: Bool
    /// The frame's own `is_live` flag. Meaningless when `hasDepth` is false.
    var isLive: Bool
    /// The frame's own `source` label ("cboe delayed L1 (no depth)", …).
    var source: String
    /// Drawable levels the frame carried on each side.
    var bidLevels: Int
    var askLevels: Int
    /// The frame's quote stamp, carried into the notice so the view can report
    /// how old the quote is on its own slow clock.
    var quoteTsMs: Int64?

    init(
        isEquity: Bool,
        isSubscribed: Bool,
        hasDepth: Bool,
        isLive: Bool = false,
        source: String = "",
        bidLevels: Int = 0,
        askLevels: Int = 0,
        quoteTsMs: Int64? = nil
    ) {
        self.isEquity = isEquity
        self.isSubscribed = isSubscribed
        self.hasDepth = hasDepth
        self.isLive = isLive
        self.source = source
        self.bidLevels = bidLevels
        self.askLevels = askLevels
        self.quoteTsMs = quoteTsMs
    }
}

/// One honest statement for a pane: an uppercase stamp headline, a
/// plain-language detail, and — when the truth depends on how stale the data is
/// — the quote stamp the view ages on its own clock. `isTerminal` marks the
/// notices where NOTHING further is coming, so the view renders them as a
/// statement of fact and never as a spinner.
struct FeedNotice: Equatable {
    var headline: String
    var detail: String
    var quoteTsMs: Int64?
    var isTerminal: Bool

    init(headline: String, detail: String, quoteTsMs: Int64? = nil, isTerminal: Bool) {
        self.headline = headline
        self.detail = detail
        self.quoteTsMs = quoteTsMs
        self.isTerminal = isTerminal
    }
}

/// What the depth pane renders.
enum DepthPaneState: Equatable {
    /// A real book: draw the montage and say nothing extra.
    case book
    /// Draw the levels that exist AND state what they actually are underneath —
    /// the delayed single-level case, which is otherwise indistinguishable from
    /// a nearly-empty order book.
    case bookWithNotice(FeedNotice)
    /// Nothing drawable: the notice IS the pane.
    case noticeOnly(FeedNotice)
}

/// What the time & sales pane renders.
enum TapePaneState: Equatable {
    /// Prints exist — render the tape.
    case prints
    /// A permanent statement: this feed will never produce a tape.
    case notice(FeedNotice)
    /// The real-time (crypto) tape's existing quiet state — prints are genuinely
    /// possible, none have arrived yet.
    case empty(String)
}

/// The honesty rules for the Level 2 panes. Pure: given the feed's facts it
/// returns exactly what may be said, so the cardinal rule (never imply data is
/// coming when it is not) is unit-tested rather than trusted to a view body.
///
/// The equity truth this encodes, from probing the running engine: the keyless
/// CBOE feed publishes NO order book — one synthetic level per side, refreshed
/// every couple of minutes, carrying a quote stamped ~15 minutes behind the
/// clock — and NO time & sales at all. Both arrive only with IB Gateway.
enum DepthHonesty {
    /// The feed posture. A landed frame decides it (its own `is_live` flag);
    /// with no frame, the subscription decides whether waiting is honest.
    static func state(_ f: DepthFeedFacts) -> DepthFeedState {
        guard f.hasDepth else { return f.isSubscribed ? .waiting : .unsubscribed }
        return f.isLive ? .live : .delayed
    }

    /// What the depth pane may render.
    static func depthPane(_ f: DepthFeedFacts) -> DepthPaneState {
        let hasLevels = f.bidLevels > 0 || f.askLevels > 0
        switch state(f) {
        case .live:
            // The working path (crypto / IBKR L2): a real book needs no notice.
            return hasLevels ? .book : .noticeOnly(Self.emptyLiveBook)
        case .delayed:
            let notice = delayedNotice(f)
            return hasLevels ? .bookWithNotice(notice) : .noticeOnly(notice)
        case .waiting:
            return .noticeOnly(Self.waiting)
        case .unsubscribed:
            return .noticeOnly(Self.unsubscribed)
        }
    }

    /// What the time & sales pane may render. Prints win over every notice, so
    /// the moment a real tape exists (IB Gateway, or crypto) the pane just shows
    /// it — the notice can never hide real data.
    static func tapePane(_ f: DepthFeedFacts, hasPrints: Bool) -> TapePaneState {
        if hasPrints { return .prints }
        if f.isEquity { return .notice(Self.noEquityTape) }
        return .empty(cryptoTapeEmptyText(hasDepth: f.hasDepth))
    }

    /// The real-time tape's existing quiet text, unchanged: crypto prints DO
    /// arrive, so "waiting" is the truth there, not a broken promise.
    static func cryptoTapeEmptyText(hasDepth: Bool) -> String {
        hasDepth ? "no prints yet" : "waiting for prints…"
    }

    // MARK: The notices

    /// The delayed stand-in. For an equity this is the whole truth of the free
    /// feed; the level count and the source come from the frame itself so the
    /// copy can never overstate what arrived.
    static func delayedNotice(_ f: DepthFeedFacts) -> FeedNotice {
        let perSide = max(f.bidLevels, f.askLevels)
        let source = f.source.isEmpty ? "the delayed feed" : f.source
        guard f.isEquity else {
            // A non-live crypto/other book: still not real-time, but the equity
            // "there is no book" story does not apply.
            return FeedNotice(
                headline: "DELAYED BOOK — NOT REAL-TIME",
                detail: "\(source) is not publishing real-time depth, so these "
                    + "levels lag the market.",
                quoteTsMs: f.quoteTsMs,
                isTerminal: true
            )
        }
        let levels = perSide <= 1
            ? "a single top-of-book level per side"
            : "\(perSide) delayed levels per side"
        return FeedNotice(
            headline: "DELAYED L1 — NOT AN ORDER BOOK",
            detail: "\(source) publishes \(levels), refreshed every couple of "
                + "minutes. There is no equity order book on the free feed — "
                + "connect IB Gateway for real Level 2 depth.",
            quoteTsMs: f.quoteTsMs,
            isTerminal: true
        )
    }

    /// Equity time & sales: not "empty yet" — never coming on this feed.
    static let noEquityTape = FeedNotice(
        headline: "NO TAPE ON THE DELAYED FEED",
        detail: "the keyless equity feed carries delayed quotes only — it "
            + "publishes no time & sales, so no prints will arrive for this "
            + "symbol. A real tape comes with IB Gateway.",
        isTerminal: true
    )

    /// Subscribed, nothing yet — the one state where waiting IS honest.
    static let waiting = FeedNotice(
        headline: "WAITING FOR DEPTH",
        detail: "the subscription is open; no book frame has landed yet.",
        isTerminal: false
    )

    /// Nothing was ever asked for. Distinct from waiting: no frame is in flight.
    static let unsubscribed = FeedNotice(
        headline: "NO DEPTH SUBSCRIPTION",
        detail: "nothing is streaming for this symbol, so no book will arrive.",
        isTerminal: true
    )

    /// A live feed that answered with an empty book — real, and genuinely empty
    /// right now, so it may refill.
    static let emptyLiveBook = FeedNotice(
        headline: "EMPTY BOOK",
        detail: "the venue is live but has no resting levels right now.",
        isTerminal: false
    )

    // MARK: Quote age

    /// Seconds between a frame's quote stamp and now. nil when the stamp is
    /// absent / non-positive, or sits in the FUTURE — an age that cannot be
    /// vouched for is never guessed at.
    static func quoteAgeSec(tsMs: Int64?, nowMs: Int64) -> Double? {
        guard let tsMs, tsMs > 0, nowMs >= tsMs else { return nil }
        return Double(nowMs - tsMs) / 1000
    }

    /// The age line under a delayed notice. Rounds DOWN through
    /// `ChartMath.compactAge`, so the figure shown is never younger than the
    /// quote really is; an unusable stamp says so instead of printing a number.
    static func quoteAgeLine(tsMs: Int64?, nowMs: Int64) -> String {
        guard let age = quoteAgeSec(tsMs: tsMs, nowMs: nowMs) else {
            return "quote time unknown"
        }
        return "quote stamped \(ChartMath.compactAge(age)) behind the clock"
    }
}
