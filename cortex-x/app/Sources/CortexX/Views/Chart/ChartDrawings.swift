// Manual drawing layer for the chart: trendlines, horizontal / vertical
// lines, rectangles, fib retracements and measures. Model + per-symbol
// UserDefaults persistence (DrawingStore) and the pure screen-space geometry
// helpers (DrawingMath) — rendering lives in CandleChart, tool state in
// ChartInteraction.

import CoreGraphics
import Foundation
import Observation

enum DrawingKind: String, Codable {
    case trendline, hline, fib, rect, vline, measure
}

/// A drawing anchor in data space — timestamps and prices, never pixels, so
/// drawings survive pans, zooms, resizes and the log-scale toggle.
struct DrawingPoint: Codable, Equatable {
    var ts_ms: Int64
    var price: Double
}

/// One user drawing. trendline / fib / rect / measure carry 2 anchor
/// points, hline / vline carry 1.
struct Drawing: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: DrawingKind
    var points: [DrawingPoint]

    init(id: UUID = UUID(), kind: DrawingKind, points: [DrawingPoint]) {
        self.id = id
        self.kind = kind
        self.points = points
    }
}

// MARK: - Store

/// Per-symbol drawing collections, persisted as JSON under
/// `drawings.<symbol>` in UserDefaults. Loads lazily, saves on mutation.
@MainActor
@Observable
final class DrawingStore {
    /// Bumped on every mutation — the only observed property, so lazy cache
    /// fills during view evaluation never mutate observable state mid-body.
    private(set) var version = 0
    @ObservationIgnored private var cache: [String: [Drawing]] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func drawings(for symbol: String) -> [Drawing] {
        _ = version // register observation
        if let cached = cache[symbol] { return cached }
        let loaded = load(symbol)
        cache[symbol] = loaded
        return loaded
    }

    /// Appends a drawing; silently rejects malformed ones (wrong anchor
    /// count for the kind, coincident two-point anchors, or any non-finite
    /// price).
    func add(_ drawing: Drawing, for symbol: String) {
        guard Self.isValid(drawing) else { return }
        var list = drawings(for: symbol)
        list.append(drawing)
        commit(list, for: symbol)
    }

    func remove(id: UUID, for symbol: String) {
        var list = drawings(for: symbol)
        let before = list.count
        list.removeAll { $0.id == id }
        guard list.count != before else { return }
        commit(list, for: symbol)
    }

    /// Replaces the anchor points of an existing drawing (same finiteness
    /// and count rules as `add`).
    func move(id: UUID, to points: [DrawingPoint], for symbol: String) {
        var list = drawings(for: symbol)
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        var updated = list[i]
        updated.points = points
        guard Self.isValid(updated) else { return }
        list[i] = updated
        commit(list, for: symbol)
    }

    func removeAll(for symbol: String) {
        cache[symbol] = []
        defaults.removeObject(forKey: Self.key(symbol))
        version += 1
    }

    /// Per-symbol persistence cap; commits beyond it drop the oldest.
    static let maxDrawingsPerSymbol = 100

    private func commit(_ list: [Drawing], for symbol: String) {
        var list = list
        if list.count > Self.maxDrawingsPerSymbol {
            list.removeFirst(list.count - Self.maxDrawingsPerSymbol)
        }
        cache[symbol] = list
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Self.key(symbol))
        }
        version += 1
    }

    private func load(_ symbol: String) -> [Drawing] {
        guard let data = defaults.data(forKey: Self.key(symbol)),
            let decoded = try? JSONDecoder().decode([Drawing].self, from: data) else {
            return []
        }
        return decoded.filter(Self.isValid)
    }

    private static func key(_ symbol: String) -> String { "drawings.\(symbol)" }

    private static func isValid(_ d: Drawing) -> Bool {
        let expected = d.kind == .hline || d.kind == .vline ? 1 : 2
        guard d.points.count == expected, d.points.allSatisfy({ $0.price.isFinite }) else {
            return false
        }
        // Coincident two-point anchors would render invisible yet stay
        // hit-testable — reject them.
        if expected == 2, d.points[0] == d.points[1] { return false }
        return true
    }
}

// MARK: - Pure geometry

enum DrawingMath {

    static let fibRatios: [Double] = [0, 0.236, 0.382, 0.5, 0.618, 0.786, 1]

    /// Retracement levels between two anchor prices; `a` is the 0-line and
    /// `b` the 1-line, so direction follows the anchors. Empty on non-finite
    /// input.
    static func fibLevels(a: Double, b: Double) -> [(ratio: Double, price: Double)] {
        guard a.isFinite, b.isFinite else { return [] }
        return fibRatios.map { (ratio: $0, price: a + (b - a) * $0) }
    }

    /// Compact axis label for a fib ratio ("0", "0.236", "1").
    static func ratioLabel(_ ratio: Double) -> String {
        String(format: "%g", ratio)
    }

    /// Measure readout between two anchors: percent change from the first
    /// anchor's price and whole bars spanned (rounded), both signed by the
    /// anchor order. Nil on non-finite input, a zero start price or a
    /// non-positive bar span.
    static func measureStats(
        a: DrawingPoint, b: DrawingPoint, barSpanMs: Int64
    ) -> (pct: Double, bars: Int)? {
        guard a.price.isFinite, b.price.isFinite, a.price != 0, barSpanMs > 0 else {
            return nil
        }
        let pct = (b.price - a.price) / abs(a.price) * 100
        guard pct.isFinite else { return nil }
        let bars = (Double(b.ts_ms - a.ts_ms) / Double(barSpanMs)).rounded()
        return (pct: pct, bars: Int(bars))
    }

    /// Endpoint of the trendline ray: `b` pushed along the a->b direction
    /// far enough to leave `rect` from anywhere inside it. Degenerate
    /// (zero-length / non-finite) anchors return `b` unchanged.
    static func rayEnd(from a: CGPoint, through b: CGPoint, in rect: CGRect) -> CGPoint {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0, len.isFinite else { return b }
        let reach = 2 * (rect.width + rect.height)
        return CGPoint(x: b.x + dx / len * reach, y: b.y + dy / len * reach)
    }

    /// True when `point` (screen space) lies within `tolerance` of the
    /// drawing rendered through the given ts->x / price->y frame mapping.
    /// Trendlines test against the full ray, fibs against every level line
    /// between the two anchor timestamps, rects against their edges only,
    /// vlines near their x and measures against the anchor segment.
    static func hitTest(
        _ drawing: Drawing,
        at point: CGPoint,
        xForTs: (Int64) -> CGFloat,
        yForPrice: (Double) -> CGFloat,
        in rect: CGRect,
        tolerance: CGFloat = 6
    ) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return false }
        switch drawing.kind {
        case .hline:
            guard let p = drawing.points.first, p.price.isFinite else { return false }
            let y = yForPrice(p.price)
            guard y.isFinite else { return false }
            return abs(point.y - y) <= tolerance
                && point.x >= rect.minX - tolerance
                && point.x <= rect.maxX + tolerance
        case .trendline:
            guard drawing.points.count >= 2,
                let a = screenPoint(drawing.points[0], xForTs, yForPrice),
                let b = screenPoint(drawing.points[1], xForTs, yForPrice) else {
                return false
            }
            let end = rayEnd(from: a, through: b, in: rect)
            return distanceToSegment(point, a, end) <= tolerance
        case .fib:
            guard drawing.points.count >= 2,
                let a = screenPoint(drawing.points[0], xForTs, yForPrice),
                let b = screenPoint(drawing.points[1], xForTs, yForPrice) else {
                return false
            }
            guard point.x >= min(a.x, b.x) - tolerance,
                point.x <= max(a.x, b.x) + tolerance else {
                return false
            }
            for level in fibLevels(a: drawing.points[0].price, b: drawing.points[1].price) {
                let y = yForPrice(level.price)
                if y.isFinite, abs(point.y - y) <= tolerance { return true }
            }
            return false
        case .rect:
            guard drawing.points.count >= 2,
                let a = screenPoint(drawing.points[0], xForTs, yForPrice),
                let b = screenPoint(drawing.points[1], xForTs, yForPrice) else {
                return false
            }
            let r = CGRect(
                x: min(a.x, b.x), y: min(a.y, b.y),
                width: abs(b.x - a.x), height: abs(b.y - a.y)
            )
            // Edges only: inside the outer band but not the shrunk interior
            // (which goes null — and contains nothing — for thin rects).
            let inner = r.insetBy(dx: tolerance, dy: tolerance)
            if inner.contains(point) { return false }
            return r.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .vline:
            guard let p = drawing.points.first else { return false }
            let x = xForTs(p.ts_ms)
            guard x.isFinite else { return false }
            return abs(point.x - x) <= tolerance
                && point.y >= rect.minY - tolerance
                && point.y <= rect.maxY + tolerance
        case .measure:
            guard drawing.points.count >= 2,
                let a = screenPoint(drawing.points[0], xForTs, yForPrice),
                let b = screenPoint(drawing.points[1], xForTs, yForPrice) else {
                return false
            }
            return distanceToSegment(point, a, b) <= tolerance
        }
    }

    private static func screenPoint(
        _ p: DrawingPoint,
        _ xForTs: (Int64) -> CGFloat,
        _ yForPrice: (Double) -> CGFloat
    ) -> CGPoint? {
        guard p.price.isFinite else { return nil }
        let pt = CGPoint(x: xForTs(p.ts_ms), y: yForPrice(p.price))
        guard pt.x.isFinite, pt.y.isFinite else { return nil }
        return pt
    }

    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x
        let aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        guard len2 > 0 else {
            return ((p.x - a.x) * (p.x - a.x) + (p.y - a.y) * (p.y - a.y)).squareRoot()
        }
        let t = min(max(((p.x - a.x) * abx + (p.y - a.y) * aby) / len2, 0), 1)
        let dx = p.x - (a.x + t * abx)
        let dy = p.y - (a.y + t * aby)
        return (dx * dx + dy * dy).squareRoot()
    }
}
