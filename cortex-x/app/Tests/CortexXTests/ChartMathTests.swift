// Hand-computed correctness tests for the chart's pure math layer:
// EMA / RSI / Bollinger, visible-window arithmetic, nice-tick axis stepping
// and adaptive price formatting.

import XCTest
@testable import CortexX

final class ChartMathTests: XCTestCase {

    // MARK: - EMA

    func testEMAHandComputed() throws {
        // period 3, k = 0.5; seed = SMA(1,2,3) = 2
        // idx3: (4-2)*0.5+2 = 3 ; idx4: (5-3)*0.5+3 = 4
        let e = ChartMath.ema([1, 2, 3, 4, 5], period: 3)
        XCTAssertEqual(e.count, 5)
        XCTAssertNil(e[0])
        XCTAssertNil(e[1])
        XCTAssertEqual(try XCTUnwrap(e[2]), 2.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(e[3]), 3.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(e[4]), 4.0, accuracy: 1e-12)
    }

    func testEMATooShortIsAllNil() {
        let e = ChartMath.ema([1, 2], period: 3)
        XCTAssertEqual(e.count, 2)
        XCTAssertTrue(e.allSatisfy { $0 == nil })
    }

    func testEMAPeriodOneTracksInput() throws {
        let e = ChartMath.ema([3, 7, 5], period: 1)
        XCTAssertEqual(try XCTUnwrap(e[0]), 3, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(e[1]), 7, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(e[2]), 5, accuracy: 1e-12)
    }

    // MARK: - RSI (Wilder)

    func testRSIHandComputed() throws {
        // period 3 over [1,2,3,4,3,4]; deltas +1,+1,+1,-1,+1
        // idx3: avgGain=1, avgLoss=0            -> 100
        // idx4: avgGain=2/3, avgLoss=1/3, RS=2  -> 66.666...
        // idx5: avgGain=7/9, avgLoss=2/9, RS=3.5 -> 77.777...
        let r = ChartMath.rsi([1, 2, 3, 4, 3, 4], period: 3)
        XCTAssertEqual(r.count, 6)
        XCTAssertNil(r[0])
        XCTAssertNil(r[1])
        XCTAssertNil(r[2])
        XCTAssertEqual(try XCTUnwrap(r[3]), 100.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(r[4]), 100.0 * 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(r[5]), 100.0 - 100.0 / 4.5, accuracy: 1e-9)
    }

    func testRSIFlatSeriesReadsFifty() throws {
        let r = ChartMath.rsi([5, 5, 5, 5, 5], period: 3)
        XCTAssertEqual(try XCTUnwrap(r[3]), 50.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(r[4]), 50.0, accuracy: 1e-12)
    }

    func testRSITooShortIsAllNil() {
        let r = ChartMath.rsi([1, 2, 3], period: 3) // needs count > period
        XCTAssertTrue(r.allSatisfy { $0 == nil })
    }

    // MARK: - Bollinger

    func testBollingerHandComputed() throws {
        // [1..5], period 5: mean 3, population var 2, sd = sqrt(2)
        let b = ChartMath.bollinger([1, 2, 3, 4, 5], period: 5, k: 2)
        XCTAssertEqual(b.count, 5)
        for i in 0..<4 { XCTAssertNil(b[i]) }
        let p = try XCTUnwrap(b[4])
        let sd = 2.0.squareRoot()
        XCTAssertEqual(p.mid, 3.0, accuracy: 1e-12)
        XCTAssertEqual(p.upper, 3.0 + 2 * sd, accuracy: 1e-12)
        XCTAssertEqual(p.lower, 3.0 - 2 * sd, accuracy: 1e-12)
    }

    func testBollingerSlidesWindow() throws {
        let b = ChartMath.bollinger([1, 2, 3, 4, 5, 6], period: 5, k: 2)
        let p = try XCTUnwrap(b[5]) // window 2...6: mean 4, same sd
        XCTAssertEqual(p.mid, 4.0, accuracy: 1e-12)
        XCTAssertEqual(p.upper, 4.0 + 2 * 2.0.squareRoot(), accuracy: 1e-12)
    }

    // MARK: - Visible window

    func testVisibleRangeLiveFollow() {
        XCTAssertEqual(
            ChartMath.visibleRange(total: 1000, barsVisible: 120, rightOffset: 0),
            880..<1000
        )
    }

    func testVisibleRangePannedBack() {
        XCTAssertEqual(
            ChartMath.visibleRange(total: 1000, barsVisible: 120, rightOffset: 10),
            870..<990
        )
    }

    func testVisibleRangeFractionalOffsetIncludesEdgeBars() {
        XCTAssertEqual(
            ChartMath.visibleRange(total: 1000, barsVisible: 120, rightOffset: 0.5),
            879..<1000
        )
    }

    func testVisibleRangeFewerBarsThanWindow() {
        XCTAssertEqual(
            ChartMath.visibleRange(total: 50, barsVisible: 120, rightOffset: 0),
            0..<50
        )
    }

    func testVisibleRangeEmpty() {
        XCTAssertTrue(ChartMath.visibleRange(total: 0, barsVisible: 120, rightOffset: 0).isEmpty)
    }

    func testClampOffset() {
        XCTAssertEqual(ChartMath.clampOffset(500, total: 200, barsVisible: 120), 80, accuracy: 1e-12)
        XCTAssertEqual(ChartMath.clampOffset(-3, total: 200, barsVisible: 120), 0, accuracy: 1e-12)
        XCTAssertEqual(ChartMath.clampOffset(40, total: 200, barsVisible: 120), 40, accuracy: 1e-12)
        // window wider than history -> pinned at 0
        XCTAssertEqual(ChartMath.clampOffset(10, total: 50, barsVisible: 120), 0, accuracy: 1e-12)
    }

    // MARK: - Zoom

    func testZoomPinnedRightEdgeStaysLive() {
        let z = ChartMath.zoom(barsVisible: 100, rightOffset: 0, factor: 2, anchor: 1, total: 1000)
        XCTAssertEqual(z.barsVisible, 200, accuracy: 1e-9)
        XCTAssertEqual(z.rightOffset, 0, accuracy: 1e-9)
    }

    func testZoomAnchoredMidWindow() {
        // window 101 bars, right edge at 899 (offset 100), anchor mid (idx 849).
        // Halve to 51 bars: new right = 849 + 25 = 874 -> offset 125.
        let z = ChartMath.zoom(
            barsVisible: 101, rightOffset: 100, factor: 51.0 / 101.0, anchor: 0.5, total: 1000
        )
        XCTAssertEqual(z.barsVisible, 51, accuracy: 1e-9)
        XCTAssertEqual(z.rightOffset, 125, accuracy: 1e-9)
    }

    func testZoomClampsWindowBounds() {
        let zin = ChartMath.zoom(barsVisible: 100, rightOffset: 0, factor: 0.0001, anchor: 1, total: 1000)
        XCTAssertEqual(zin.barsVisible, ChartMath.minVisibleBars, accuracy: 1e-12)
        let zout = ChartMath.zoom(barsVisible: 100, rightOffset: 0, factor: 100, anchor: 1, total: 1000)
        XCTAssertEqual(zout.barsVisible, ChartMath.maxVisibleBars, accuracy: 1e-12)
        XCTAssertEqual(zout.rightOffset, 0, accuracy: 1e-9)
    }

    func testZoomOffsetClampedToHistory() {
        // Zooming out around the left edge cannot scroll past the oldest bar.
        let z = ChartMath.zoom(barsVisible: 100, rightOffset: 850, factor: 4, anchor: 0, total: 1000)
        XCTAssertLessThanOrEqual(
            z.rightOffset,
            ChartMath.maxRightOffset(total: 1000, barsVisible: z.barsVisible) + 1e-9
        )
        XCTAssertGreaterThanOrEqual(z.rightOffset, 0)
    }

    // MARK: - Axis stepping

    func testNiceStepLadder() {
        XCTAssertEqual(ChartMath.niceStep(range: 100, target: 5), 20, accuracy: 1e-12)
        XCTAssertEqual(ChartMath.niceStep(range: 7, target: 5), 2, accuracy: 1e-12)
        XCTAssertEqual(ChartMath.niceStep(range: 0.9, target: 4), 0.25, accuracy: 1e-12)
        XCTAssertEqual(ChartMath.niceStep(range: 36, target: 6), 10, accuracy: 1e-12)
    }

    func testAxisTicksInsideBoundsOnNiceMultiples() {
        let ticks = ChartMath.axisTicks(min: 0.37, max: 2.4, target: 5)
        XCTAssertEqual(ticks.count, 4)
        for (i, t) in ticks.enumerated() {
            XCTAssertEqual(t, 0.5 + Double(i) * 0.5, accuracy: 1e-9)
            XCTAssertGreaterThanOrEqual(t, 0.37)
            XCTAssertLessThanOrEqual(t, 2.4)
        }
    }

    func testAxisTicksDegenerateRange() {
        XCTAssertTrue(ChartMath.axisTicks(min: 5, max: 5, target: 5).isEmpty)
    }

    // MARK: - Buckets

    func testBucketFloorsToBarOpen() {
        XCTAssertEqual(ChartMath.bucket(61_500, .m1), 60_000)
        XCTAssertEqual(ChartMath.bucket(59_999, .s1), 59_000)
        XCTAssertEqual(ChartMath.bucket(899_999_999, .m15), 899_100_000)
        XCTAssertEqual(ChartMath.bucket(60_000, .m1), 60_000) // exact open unchanged
    }

    // MARK: - Price formatting

    func testFormatPriceAdaptive() {
        XCTAssertEqual(ChartMath.formatPrice(43_250.123), "43250.12")   // >= 100: 2dp
        XCTAssertEqual(ChartMath.formatPrice(1.5), "1.50")              // >= 1: min 2dp
        XCTAssertEqual(ChartMath.formatPrice(1.2345), "1.2345")         // >= 1: up to 4dp
        XCTAssertEqual(ChartMath.formatPrice(1.23), "1.23")             // trailing zeros trimmed
        XCTAssertEqual(ChartMath.formatPrice(0.5), "0.5000")            // < 1: 4 sig digits
        XCTAssertEqual(ChartMath.formatPrice(0.023456), "0.02346")
        XCTAssertEqual(ChartMath.formatPrice(0), "0.00")
        XCTAssertEqual(ChartMath.formatPrice(-0.5), "-0.5000")
        XCTAssertEqual(ChartMath.formatPrice(-250.4), "-250.40")
    }

    func testFormatSigned() {
        XCTAssertEqual(ChartMath.formatSigned(1.5), "+1.50")
        XCTAssertEqual(ChartMath.formatSigned(-1.5), "-1.50")
    }

    func testFormatVolumeCompact() {
        XCTAssertEqual(ChartMath.formatVolume(1_234_567), "1.23M")
        XCTAssertEqual(ChartMath.formatVolume(12_500), "12.5k")
        XCTAssertEqual(ChartMath.formatVolume(950), "950")
        XCTAssertEqual(ChartMath.formatVolume(2_500_000_000), "2.50B")
        XCTAssertEqual(ChartMath.formatVolume(0.5), "0.50")
    }
}
