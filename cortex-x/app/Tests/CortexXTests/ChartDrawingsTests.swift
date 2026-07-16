// Drawing-layer tests: model JSON roundtrip, fib level interpolation in
// both directions, measure readout math, screen-space hit testing with
// tolerance, and DrawingStore add / remove / move / persistence against an
// isolated UserDefaults suite.

import XCTest
@testable import CortexX

final class ChartDrawingsTests: XCTestCase {

    // MARK: - Model roundtrip

    func testDrawingJSONRoundtrip() throws {
        let original = Drawing(
            kind: .trendline,
            points: [
                DrawingPoint(ts_ms: 1_700_000_000_000, price: 123.45),
                DrawingPoint(ts_ms: 1_700_000_600_000, price: 130.5),
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Drawing.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.kind, .trendline)
        XCTAssertEqual(decoded.points.count, 2)
    }

    func testDrawingKindRawValuesAreStable() {
        // Persisted JSON depends on these strings — never rename.
        XCTAssertEqual(DrawingKind.trendline.rawValue, "trendline")
        XCTAssertEqual(DrawingKind.hline.rawValue, "hline")
        XCTAssertEqual(DrawingKind.fib.rawValue, "fib")
        XCTAssertEqual(DrawingKind.rect.rawValue, "rect")
        XCTAssertEqual(DrawingKind.vline.rawValue, "vline")
        XCTAssertEqual(DrawingKind.measure.rawValue, "measure")
    }

    func testNewDrawingKindsJSONRoundtrip() throws {
        let two = [
            DrawingPoint(ts_ms: 1_700_000_000_000, price: 100),
            DrawingPoint(ts_ms: 1_700_000_600_000, price: 110),
        ]
        for kind in [DrawingKind.rect, .measure] {
            let original = Drawing(kind: kind, points: two)
            let data = try JSONEncoder().encode(original)
            XCTAssertEqual(try JSONDecoder().decode(Drawing.self, from: data), original)
        }
        let vline = Drawing(kind: .vline, points: [two[0]])
        let data = try JSONEncoder().encode(vline)
        XCTAssertEqual(try JSONDecoder().decode(Drawing.self, from: data), vline)
    }

    // MARK: - Fib levels

    func testFibLevelsAscending() {
        let levels = DrawingMath.fibLevels(a: 100, b: 200)
        XCTAssertEqual(levels.count, 7)
        XCTAssertEqual(levels.map(\.ratio), [0, 0.236, 0.382, 0.5, 0.618, 0.786, 1])
        XCTAssertEqual(levels[0].price, 100, accuracy: 1e-12)
        XCTAssertEqual(levels[1].price, 123.6, accuracy: 1e-9)
        XCTAssertEqual(levels[3].price, 150, accuracy: 1e-12)
        XCTAssertEqual(levels[4].price, 161.8, accuracy: 1e-9)
        XCTAssertEqual(levels[6].price, 200, accuracy: 1e-12)
    }

    func testFibLevelsDescending() {
        // a is always the 0-line: retracement direction follows the anchors.
        let levels = DrawingMath.fibLevels(a: 200, b: 100)
        XCTAssertEqual(levels[0].price, 200, accuracy: 1e-12)
        XCTAssertEqual(levels[1].price, 176.4, accuracy: 1e-9)
        XCTAssertEqual(levels[4].price, 138.2, accuracy: 1e-9)
        XCTAssertEqual(levels[6].price, 100, accuracy: 1e-12)
    }

    func testFibLevelsNonFiniteInputIsEmpty() {
        XCTAssertTrue(DrawingMath.fibLevels(a: .nan, b: 100).isEmpty)
        XCTAssertTrue(DrawingMath.fibLevels(a: 100, b: .infinity).isEmpty)
    }

    // MARK: - Measure stats

    func testMeasureStatsSignedPercentAndBars() {
        let span: Int64 = 60_000
        let a = DrawingPoint(ts_ms: 0, price: 100)
        let b = DrawingPoint(ts_ms: 10 * span, price: 125)
        let up = DrawingMath.measureStats(a: a, b: b, barSpanMs: span)
        XCTAssertEqual(up?.pct ?? .nan, 25, accuracy: 1e-9)
        XCTAssertEqual(up?.bars, 10)
        // Reversed anchors: both readouts flip sign.
        let down = DrawingMath.measureStats(a: b, b: a, barSpanMs: span)
        XCTAssertEqual(down?.pct ?? .nan, -20, accuracy: 1e-9)
        XCTAssertEqual(down?.bars, -10)
    }

    func testMeasureStatsRoundsBarCount() {
        let a = DrawingPoint(ts_ms: 0, price: 100)
        let flat = { (ts: Int64) in DrawingPoint(ts_ms: ts, price: 100) }
        XCTAssertEqual(
            DrawingMath.measureStats(a: a, b: flat(540_000), barSpanMs: 100_000)?.bars, 5
        )
        XCTAssertEqual(
            DrawingMath.measureStats(a: a, b: flat(560_000), barSpanMs: 100_000)?.bars, 6
        )
    }

    func testMeasureStatsRejectsDegenerateInput() {
        let a = DrawingPoint(ts_ms: 0, price: 100)
        let b = DrawingPoint(ts_ms: 60_000, price: 110)
        XCTAssertNil(
            DrawingMath.measureStats(
                a: DrawingPoint(ts_ms: 0, price: .nan), b: b, barSpanMs: 60_000
            )
        )
        XCTAssertNil(
            DrawingMath.measureStats(
                a: a, b: DrawingPoint(ts_ms: 60_000, price: .infinity), barSpanMs: 60_000
            )
        )
        // Zero start price would divide away the percent.
        XCTAssertNil(
            DrawingMath.measureStats(
                a: DrawingPoint(ts_ms: 0, price: 0), b: b, barSpanMs: 60_000
            )
        )
        XCTAssertNil(DrawingMath.measureStats(a: a, b: b, barSpanMs: 0))
    }

    // MARK: - Hit testing

    // Mapping: ts -> x directly; price p -> 200 - p (y grows downward).
    private let rect = CGRect(x: 0, y: 0, width: 400, height: 200)
    private func xForTs(_ ts: Int64) -> CGFloat { CGFloat(ts) }
    private func yForPrice(_ p: Double) -> CGFloat { CGFloat(200 - p) }

    private func hit(_ d: Drawing, _ p: CGPoint) -> Bool {
        DrawingMath.hitTest(d, at: p, xForTs: xForTs, yForPrice: yForPrice, in: rect)
    }

    func testTrendlineHitOnLineAndTwentyPointsAway() {
        // Anchors (0,0) and (100,100) on screen: the diagonal y = x.
        let d = Drawing(kind: .trendline, points: [
            DrawingPoint(ts_ms: 0, price: 200),
            DrawingPoint(ts_ms: 100, price: 100),
        ])
        XCTAssertTrue(hit(d, CGPoint(x: 50, y: 50)))
        // 20pt vertical offset = ~14.1pt perpendicular, past the 6pt tolerance.
        XCTAssertFalse(hit(d, CGPoint(x: 50, y: 70)))
    }

    func testTrendlineIsARayNotASegment() {
        let d = Drawing(kind: .trendline, points: [
            DrawingPoint(ts_ms: 0, price: 200),
            DrawingPoint(ts_ms: 100, price: 100),
        ])
        // Beyond the second anchor: still on the extended ray.
        XCTAssertTrue(hit(d, CGPoint(x: 150, y: 150)))
        // Behind the first anchor: no backwards extension.
        XCTAssertFalse(hit(d, CGPoint(x: -20, y: -20)))
    }

    func testHLineHitTolerance() {
        // price 120 -> y 80.
        let d = Drawing(kind: .hline, points: [DrawingPoint(ts_ms: 5, price: 120)])
        XCTAssertTrue(hit(d, CGPoint(x: 10, y: 83)))
        XCTAssertTrue(hit(d, CGPoint(x: 390, y: 80)))
        XCTAssertFalse(hit(d, CGPoint(x: 10, y: 100))) // 20pt away
        XCTAssertFalse(hit(d, CGPoint(x: 420, y: 80))) // past the pane
    }

    func testFibHitOnLevelLineOnly() {
        // Anchors (100, y 200) and (300, y 100): levels at prices
        // 0 / 23.6 / 38.2 / 50 / 61.8 / 78.6 / 100.
        let d = Drawing(kind: .fib, points: [
            DrawingPoint(ts_ms: 100, price: 0),
            DrawingPoint(ts_ms: 300, price: 100),
        ])
        XCTAssertTrue(hit(d, CGPoint(x: 200, y: 152))) // 2pt from the 0.5 level
        XCTAssertFalse(hit(d, CGPoint(x: 200, y: 130))) // between levels
        XCTAssertFalse(hit(d, CGPoint(x: 350, y: 150))) // outside the anchor span
    }

    func testRectHitOnEdgesOnly() {
        // Corners (100, y 50) and (300, y 150) on screen.
        let d = Drawing(kind: .rect, points: [
            DrawingPoint(ts_ms: 100, price: 150),
            DrawingPoint(ts_ms: 300, price: 50),
        ])
        XCTAssertTrue(hit(d, CGPoint(x: 100, y: 100))) // left edge
        XCTAssertTrue(hit(d, CGPoint(x: 200, y: 53))) // 3pt off the top edge
        XCTAssertTrue(hit(d, CGPoint(x: 300, y: 150))) // corner
        XCTAssertFalse(hit(d, CGPoint(x: 200, y: 100))) // interior stays click-through
        XCTAssertFalse(hit(d, CGPoint(x: 320, y: 100))) // outside
    }

    func testVLineHitNearXOnly() {
        // ts 150 -> x 150.
        let d = Drawing(kind: .vline, points: [DrawingPoint(ts_ms: 150, price: 60)])
        XCTAssertTrue(hit(d, CGPoint(x: 153, y: 10)))
        XCTAssertTrue(hit(d, CGPoint(x: 150, y: 195)))
        XCTAssertFalse(hit(d, CGPoint(x: 170, y: 100))) // 20pt away in x
        XCTAssertFalse(hit(d, CGPoint(x: 150, y: 220))) // below the pane
    }

    func testMeasureHitIsASegmentNotARay() {
        // Anchors (0,0) and (100,100) on screen: the diagonal y = x.
        let d = Drawing(kind: .measure, points: [
            DrawingPoint(ts_ms: 0, price: 200),
            DrawingPoint(ts_ms: 100, price: 100),
        ])
        XCTAssertTrue(hit(d, CGPoint(x: 50, y: 50)))
        XCTAssertTrue(hit(d, CGPoint(x: 100, y: 100))) // endpoint
        XCTAssertFalse(hit(d, CGPoint(x: 150, y: 150))) // no extension past the anchor
        XCTAssertFalse(hit(d, CGPoint(x: 50, y: 70))) // off the line
    }

    func testHitTestRejectsNonFinitePoint() {
        let d = Drawing(kind: .hline, points: [DrawingPoint(ts_ms: 5, price: 120)])
        XCTAssertFalse(hit(d, CGPoint(x: CGFloat.nan, y: 80)))
        let v = Drawing(kind: .vline, points: [DrawingPoint(ts_ms: 5, price: 120)])
        XCTAssertFalse(hit(v, CGPoint(x: 5, y: CGFloat.nan)))
    }
}

// MARK: - Store

@MainActor
final class DrawingStoreTests: XCTestCase {

    private static let suiteName = "cortexx.tests.drawings"

    /// Fresh store over a wiped, isolated UserDefaults suite.
    private func makeStore() -> (defaults: UserDefaults, store: DrawingStore) {
        let defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        return (defaults, DrawingStore(defaults: defaults))
    }

    private func hline(_ price: Double) -> Drawing {
        Drawing(kind: .hline, points: [DrawingPoint(ts_ms: 1_700_000_000_000, price: price)])
    }

    func testAddPersistsAndReloads() {
        let (defaults, store) = makeStore()
        let d = hline(42)
        store.add(d, for: "NVDA")
        XCTAssertEqual(store.drawings(for: "NVDA"), [d])
        XCTAssertNotNil(defaults.data(forKey: "drawings.NVDA"))
        // A fresh store over the same suite lazily reloads from disk.
        let reloaded = DrawingStore(defaults: defaults)
        XCTAssertEqual(reloaded.drawings(for: "NVDA"), [d])
    }

    func testRemoveDeletesAndPersists() {
        let (defaults, store) = makeStore()
        let keep = hline(10)
        let drop = hline(20)
        store.add(keep, for: "NVDA")
        store.add(drop, for: "NVDA")
        store.remove(id: drop.id, for: "NVDA")
        XCTAssertEqual(store.drawings(for: "NVDA"), [keep])
        XCTAssertEqual(DrawingStore(defaults: defaults).drawings(for: "NVDA"), [keep])
    }

    func testMoveReplacesPoints() {
        let (_, store) = makeStore()
        let d = hline(10)
        store.add(d, for: "NVDA")
        let moved = [DrawingPoint(ts_ms: 1_700_000_060_000, price: 15)]
        store.move(id: d.id, to: moved, for: "NVDA")
        XCTAssertEqual(store.drawings(for: "NVDA").first?.points, moved)
        // Non-finite replacement is rejected wholesale.
        store.move(id: d.id, to: [DrawingPoint(ts_ms: 0, price: .nan)], for: "NVDA")
        XCTAssertEqual(store.drawings(for: "NVDA").first?.points, moved)
    }

    func testRemoveAllClearsOnlyThatSymbol() {
        let (defaults, store) = makeStore()
        store.add(hline(10), for: "NVDA")
        store.add(hline(20), for: "SPY")
        store.removeAll(for: "NVDA")
        XCTAssertTrue(store.drawings(for: "NVDA").isEmpty)
        XCTAssertNil(defaults.data(forKey: "drawings.NVDA"))
        XCTAssertEqual(store.drawings(for: "SPY").count, 1)
    }

    func testAddRejectsMalformedDrawings() {
        let (_, store) = makeStore()
        // Non-finite price.
        store.add(hline(.nan), for: "NVDA")
        // Wrong anchor count for the kind.
        store.add(
            Drawing(kind: .trendline, points: [DrawingPoint(ts_ms: 0, price: 1)]),
            for: "NVDA"
        )
        store.add(Drawing(kind: .hline, points: []), for: "NVDA")
        XCTAssertTrue(store.drawings(for: "NVDA").isEmpty)
    }

    func testAddRejectsDegenerateTwoPointDrawings() {
        let (_, store) = makeStore()
        // Coincident anchors render invisible yet stay hit-testable.
        let p = DrawingPoint(ts_ms: 1_700_000_000_000, price: 42)
        store.add(Drawing(kind: .trendline, points: [p, p]), for: "NVDA")
        store.add(Drawing(kind: .fib, points: [p, p]), for: "NVDA")
        XCTAssertTrue(store.drawings(for: "NVDA").isEmpty)
        // move cannot collapse an existing drawing onto itself either.
        let d = Drawing(
            kind: .trendline,
            points: [p, DrawingPoint(ts_ms: 1_700_000_060_000, price: 50)]
        )
        store.add(d, for: "NVDA")
        store.move(id: d.id, to: [p, p], for: "NVDA")
        XCTAssertEqual(store.drawings(for: "NVDA"), [d])
    }

    func testStoreValidatesNewKinds() {
        let (_, store) = makeStore()
        let p = DrawingPoint(ts_ms: 1_700_000_000_000, price: 42)
        let q = DrawingPoint(ts_ms: 1_700_000_600_000, price: 50)
        // Coincident two-point anchors rejected.
        store.add(Drawing(kind: .rect, points: [p, p]), for: "NVDA")
        store.add(Drawing(kind: .measure, points: [p, p]), for: "NVDA")
        // Wrong anchor count for the kind.
        store.add(Drawing(kind: .vline, points: [p, q]), for: "NVDA")
        store.add(Drawing(kind: .rect, points: [p]), for: "NVDA")
        store.add(Drawing(kind: .measure, points: []), for: "NVDA")
        XCTAssertTrue(store.drawings(for: "NVDA").isEmpty)
        // Well-formed ones land.
        store.add(Drawing(kind: .rect, points: [p, q]), for: "NVDA")
        store.add(Drawing(kind: .measure, points: [p, q]), for: "NVDA")
        store.add(Drawing(kind: .vline, points: [p]), for: "NVDA")
        XCTAssertEqual(store.drawings(for: "NVDA").count, 3)
    }

    func testCommitCapsPerSymbolDrawingsDroppingOldest() {
        let (defaults, store) = makeStore()
        let overflow = DrawingStore.maxDrawingsPerSymbol + 5
        for i in 0..<overflow { store.add(hline(Double(i)), for: "NVDA") }
        let kept = store.drawings(for: "NVDA")
        XCTAssertEqual(kept.count, DrawingStore.maxDrawingsPerSymbol)
        // The oldest five dropped; insertion order is preserved.
        XCTAssertEqual(kept.first?.points.first?.price, 5)
        XCTAssertEqual(kept.last?.points.first?.price, Double(overflow - 1))
        // The cap survives persistence too.
        XCTAssertEqual(
            DrawingStore(defaults: defaults).drawings(for: "NVDA").count,
            DrawingStore.maxDrawingsPerSymbol
        )
    }
}
