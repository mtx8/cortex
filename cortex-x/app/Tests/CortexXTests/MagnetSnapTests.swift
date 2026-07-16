// Magnet-mode tests: pure O/H/L/C price snapping (nearest wins, ties keep
// O-H-L-C order, non-finite candidates skipped, non-finite input passes
// through) and the ChartInteraction mode contract (off by default, survives
// a series reset like the overlay toggles).

import XCTest
@testable import CortexX

final class MagnetSnapTests: XCTestCase {

    private func bar(o: Double, h: Double, l: Double, c: Double) -> Bar {
        Bar(
            symbol: "TEST", interval: .d1, ts_open_ms: 1_700_000_000_000,
            open: o, high: h, low: l, close: c,
            volume: 0, trade_count: 0, vwap: 0, complete: true
        )
    }

    func testSnapsToNearestOHLC() {
        let b = bar(o: 100, h: 110, l: 90, c: 104)
        XCTAssertEqual(MagnetMath.snapPrice(101, to: b), 100)
        XCTAssertEqual(MagnetMath.snapPrice(108.9, to: b), 110)
        XCTAssertEqual(MagnetMath.snapPrice(91.2, to: b), 90)
        XCTAssertEqual(MagnetMath.snapPrice(103.5, to: b), 104)
        // Way outside the bar still lands on the nearest extreme.
        XCTAssertEqual(MagnetMath.snapPrice(500, to: b), 110)
        XCTAssertEqual(MagnetMath.snapPrice(-500, to: b), 90)
    }

    func testExactLevelStays() {
        let b = bar(o: 100, h: 110, l: 90, c: 104)
        XCTAssertEqual(MagnetMath.snapPrice(110, to: b), 110)
    }

    func testTieResolvesInOHLCOrder() {
        // 105 sits exactly between open 100 and high 110 — open wins.
        let b = bar(o: 100, h: 110, l: 90, c: 120)
        XCTAssertEqual(MagnetMath.snapPrice(105, to: b), 100)
        // 97 between low 94 and open 100 — open comes first in O-H-L-C.
        let b2 = bar(o: 100, h: 110, l: 94, c: 120)
        XCTAssertEqual(MagnetMath.snapPrice(97, to: b2), 100)
    }

    func testSkipsNonFiniteCandidates() {
        let b = bar(o: .nan, h: 110, l: .infinity, c: 104)
        XCTAssertEqual(MagnetMath.snapPrice(105, to: b), 104)
    }

    func testAllNonFiniteCandidatesReturnPriceUnchanged() {
        let b = bar(o: .nan, h: .nan, l: -.infinity, c: .infinity)
        XCTAssertEqual(MagnetMath.snapPrice(105, to: b), 105)
    }

    func testNonFinitePricePassesThrough() {
        let b = bar(o: 100, h: 110, l: 90, c: 104)
        XCTAssertTrue(MagnetMath.snapPrice(.nan, to: b).isNaN)
        XCTAssertEqual(MagnetMath.snapPrice(.infinity, to: b), .infinity)
    }
}

final class MagnetModeTests: XCTestCase {

    func testMagnetModeDefaultsOff() {
        XCTAssertFalse(ChartInteraction().magnetMode)
    }

    func testMagnetModeSurvivesSeriesReset() {
        // A mode like the overlay toggles, not a tool — symbol / interval
        // switches must not silently disarm it.
        let interaction = ChartInteraction()
        interaction.magnetMode = true
        interaction.resetForNewSeries()
        XCTAssertTrue(interaction.magnetMode)
        XCTAssertEqual(interaction.activeTool, .cursor)
    }
}
