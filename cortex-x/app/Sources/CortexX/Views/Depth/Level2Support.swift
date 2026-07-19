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
        return DepthBanner(
            kind: .delayed, source: source,
            note: "delayed L1 — real-time depth requires IBKR market-data (Settings)"
        )
    }
}
