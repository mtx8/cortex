// Drawing-layer tests: model JSON roundtrip, fib level interpolation in
// both directions, screen-space hit testing with tolerance, and
// DrawingStore add / remove / move / persistence against an isolated
// UserDefaults suite.

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

    func testHitTestRejectsNonFinitePoint() {
        let d = Drawing(kind: .hline, points: [DrawingPoint(ts_ms: 5, price: 120)])
        XCTAssertFalse(hit(d, CGPoint(x: CGFloat.nan, y: 80)))
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
