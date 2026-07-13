// Hand-computed correctness tests for the chart's pure math layer:
// EMA / RSI / Bollinger / MACD, visible-window arithmetic, nice-tick axis
// stepping, log price mapping, weekly aggregation and adaptive price
// formatting.

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

    // MARK: - MACD

    func testMACDWarmupNils() {
        // EMA26 seeds at index 25; EMA9 over the macd line adds 8 -> 33.
        let closes = (0..<40).map(Double.init)
        let m = ChartMath.macdSeries(closes: closes)
        XCTAssertEqual(m.macd.count, 40)
        XCTAssertEqual(m.signal.count, 40)
        XCTAssertEqual(m.hist.count, 40)
        for i in 0..<25 { XCTAssertNil(m.macd[i]) }
        XCTAssertNotNil(m.macd[25])
        for i in 0..<33 {
            XCTAssertNil(m.signal[i])
            XCTAssertNil(m.hist[i])
        }
        XCTAssertNotNil(m.signal[33])
        XCTAssertNotNil(m.hist[33])
    }

    func testMACDTooShortIsAllNil() {
        let m = ChartMath.macdSeries(closes: [1, 2, 3])
        XCTAssertEqual(m.macd.count, 3)
        XCTAssertTrue(m.macd.allSatisfy { $0 == nil })
        XCTAssertTrue(m.signal.allSatisfy { $0 == nil })
        XCTAssertTrue(m.hist.allSatisfy { $0 == nil })
    }

    func testMACDMatchesEMADifferenceAndHistRelation() throws {
        // On a rising ramp the fast EMA leads: EMA12 > EMA26 -> macd > 0.
        let closes = (1...60).map(Double.init)
        let m = ChartMath.macdSeries(closes: closes)
        let e12 = ChartMath.ema(closes, period: 12)
        let e26 = ChartMath.ema(closes, period: 26)
        for i in 25..<60 {
            let macd = try XCTUnwrap(m.macd[i])
            let fast = try XCTUnwrap(e12[i])
            let slow = try XCTUnwrap(e26[i])
            XCTAssertEqual(macd, fast - slow, accuracy: 1e-12)
            XCTAssertGreaterThan(macd, 0)
        }
        // hist = macd - signal wherever all three are defined.
        for i in 33..<60 {
            let macd = try XCTUnwrap(m.macd[i])
            let signal = try XCTUnwrap(m.signal[i])
            XCTAssertEqual(try XCTUnwrap(m.hist[i]), macd - signal, accuracy: 1e-12)
        }
    }

    func testMACDFallingRampIsNegative() throws {
        let closes = (1...40).map { 100.0 - Double($0) }
        let m = ChartMath.macdSeries(closes: closes)
        XCTAssertLessThan(try XCTUnwrap(m.macd[39]), 0)
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

    // MARK: - Log-axis ticks

    func testLogAxisTicksDecadeSpanProducesOneTwoFive() {
        // Two decades over 300px: 150px per decade, so the 1/2/5 ladder's
        // tightest gap (log10(2) ≈ 0.301 decade ≈ 45px) clears 44px.
        XCTAssertEqual(
            ChartMath.logAxisTicks(min: 1, max: 100, heightPx: 300),
            [1, 2, 5, 10, 20, 50, 100]
        )
    }

    func testLogAxisTicksThinToBareDecadesWhenTight() {
        // 50px per decade: the 1/2/5 ladder (~15px gaps) is too dense but
        // whole decades still fit.
        XCTAssertEqual(
            ChartMath.logAxisTicks(min: 1, max: 1_000, heightPx: 150),
            [1, 10, 100, 1_000]
        )
    }

    func testLogAxisTicksSubdivideOnSubDecadeRange() {
        // Under half a decade with plenty of pixels: a denser mantissa
        // ladder kicks in so the axis never starves.
        let ticks = ChartMath.logAxisTicks(min: 101, max: 178, heightPx: 400)
        XCTAssertEqual(ticks.count, 3)
        for (t, expected) in zip(ticks, [120.0, 140.0, 160.0]) {
            XCTAssertEqual(t, expected, accuracy: 1e-9)
        }
    }

    func testLogAxisTicksUnsupportedOrDegenerateAxisIsEmpty() {
        XCTAssertTrue(ChartMath.logAxisTicks(min: 0, max: 10, heightPx: 300).isEmpty)
        XCTAssertTrue(ChartMath.logAxisTicks(min: -5, max: 10, heightPx: 300).isEmpty)
        XCTAssertTrue(ChartMath.logAxisTicks(min: 5, max: 5, heightPx: 300).isEmpty)
    }

    // MARK: - Price-axis mapping (linear / log)

    func testPriceFractionLogMonotonicWithKnownMidpoint() {
        // log10 axis over [1, 100]: 10 sits exactly halfway.
        XCTAssertEqual(ChartMath.priceFraction(1, lo: 1, hi: 100, log: true), 0, accuracy: 1e-12)
        XCTAssertEqual(ChartMath.priceFraction(10, lo: 1, hi: 100, log: true), 0.5, accuracy: 1e-12)
        XCTAssertEqual(ChartMath.priceFraction(100, lo: 1, hi: 100, log: true), 1, accuracy: 1e-12)
        var prev = -Double.infinity
        for p in [1.0, 2, 5, 10, 50, 99] {
            let f = ChartMath.priceFraction(p, lo: 1, hi: 100, log: true)
            XCTAssertGreaterThan(f, prev)
            prev = f
        }
    }

    func testPriceFractionLogFallsBackToLinearAtOrBelowZero() {
        // lo <= 0 cannot support a log axis -> linear mapping.
        XCTAssertEqual(ChartMath.priceFraction(5, lo: 0, hi: 10, log: true), 0.5, accuracy: 1e-12)
        XCTAssertEqual(
            ChartMath.priceFraction(-5, lo: -10, hi: 10, log: true), 0.25, accuracy: 1e-12
        )
    }

    func testPriceFractionDegenerateRangeIsZero() {
        XCTAssertEqual(ChartMath.priceFraction(5, lo: 5, hi: 5, log: true), 0, accuracy: 1e-12)
        XCTAssertEqual(ChartMath.priceFraction(5, lo: 5, hi: 5, log: false), 0, accuracy: 1e-12)
    }

    func testPriceAtFractionRoundtrips() {
        for p in [1.5, 12.0, 87.3] {
            let logF = ChartMath.priceFraction(p, lo: 1, hi: 100, log: true)
            XCTAssertEqual(
                ChartMath.priceAtFraction(logF, lo: 1, hi: 100, log: true), p, accuracy: 1e-9
            )
            let linF = ChartMath.priceFraction(p, lo: 1, hi: 100, log: false)
            XCTAssertEqual(
                ChartMath.priceAtFraction(linF, lo: 1, hi: 100, log: false), p, accuracy: 1e-9
            )
        }
    }

    // MARK: - Buckets

    func testBucketFloorsToBarOpen() {
        XCTAssertEqual(ChartMath.bucket(61_500, .m1), 60_000)
        XCTAssertEqual(ChartMath.bucket(59_999, .s1), 59_000)
        XCTAssertEqual(ChartMath.bucket(899_999_999, .m15), 899_100_000)
        XCTAssertEqual(ChartMath.bucket(60_000, .m1), 60_000) // exact open unchanged
    }

    func testWeekFloorIsMondayAnchored() {
        // The epoch (day 0) is a Thursday, so day 4 (1970-01-05) is the
        // first Monday. A Wednesday (day 6) floors to that Monday; a Sunday
        // (day 10) still belongs to the PRIOR Monday's week; the next
        // Monday (day 11) opens a fresh one.
        XCTAssertEqual(ChartMath.weekFloor(4 * Self.dayMs), 4 * Self.dayMs)
        XCTAssertEqual(ChartMath.weekFloor(6 * Self.dayMs + 3_600_000), 4 * Self.dayMs)
        XCTAssertEqual(ChartMath.weekFloor(10 * Self.dayMs + 12 * 3_600_000), 4 * Self.dayMs)
        XCTAssertEqual(ChartMath.weekFloor(11 * Self.dayMs), 11 * Self.dayMs)
        // Modern timestamp: Wednesday 2026-07-08 floors to Monday
        // 2026-07-06 00:00 UTC (day 20640).
        let monday: Int64 = 20_640 * Self.dayMs
        XCTAssertEqual(ChartMath.weekFloor(monday + 2 * Self.dayMs + 1), monday)
        XCTAssertEqual(ChartMath.weekFloor(monday), monday)
    }

    func testSpanBucketWeeklyUsesMondayFloorElseEpoch() {
        // The weekly span routes through the Monday-anchored week floor…
        XCTAssertEqual(
            ChartMath.bucket(6 * Self.dayMs, spanMs: ChartMath.weekMs), 4 * Self.dayMs
        )
        // …every other span floors from the epoch, matching the interval form.
        XCTAssertEqual(ChartMath.bucket(61_500, spanMs: Interval.m1.ms), 60_000)
        XCTAssertEqual(
            ChartMath.bucket(90 * Self.dayMs + 5, spanMs: Interval.d1.ms), 90 * Self.dayMs
        )
    }

    // MARK: - Weekly aggregation

    private static let dayMs: Int64 = 86_400_000

    private func dayBar(
        day: Int64, o: Double, h: Double, l: Double, c: Double, v: Double,
        complete: Bool = true
    ) -> Bar {
        Bar(
            symbol: "TEST", interval: .d1, ts_open_ms: day * Self.dayMs,
            open: o, high: h, low: l, close: c, volume: v,
            trade_count: 1, vwap: (h + l) / 2, complete: complete
        )
    }

    func testAggregateWeeklyMergesOHLCV() {
        // Days 4..6 (Mon..Wed) share the Monday-anchored bucket at day 4.
        let w = ChartMath.aggregateWeekly([
            dayBar(day: 4, o: 10, h: 12, l: 9, c: 11, v: 100),
            dayBar(day: 5, o: 11, h: 15, l: 10, c: 14, v: 50),
            dayBar(day: 6, o: 14, h: 14.5, l: 8, c: 9, v: 25),
        ])
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(w[0].ts_open_ms, 4 * Self.dayMs)
        XCTAssertEqual(w[0].open, 10)      // first open
        XCTAssertEqual(w[0].high, 15)      // max high
        XCTAssertEqual(w[0].low, 8)        // min low
        XCTAssertEqual(w[0].close, 9)      // last close
        XCTAssertEqual(w[0].volume, 175)   // summed
        XCTAssertEqual(w[0].vwap, 9)       // vwap = close by contract
        XCTAssertEqual(w[0].trade_count, 3)
        XCTAssertTrue(w[0].complete)
        XCTAssertEqual(w[0].symbol, "TEST")
        XCTAssertEqual(w[0].interval, .d1)
    }

    func testAggregateWeeklyBucketAlignment() {
        // Monday-anchored buckets: days 5-7 (Tue-Thu) join the Monday at
        // day 4; day 10 (Sun) would close that week; days 13-14 (Wed-Thu)
        // fall under the next Monday at day 11.
        let w = ChartMath.aggregateWeekly([
            dayBar(day: 5, o: 1, h: 2, l: 1, c: 2, v: 10),
            dayBar(day: 6, o: 2, h: 3, l: 2, c: 3, v: 10),
            dayBar(day: 7, o: 3, h: 4, l: 3, c: 4, v: 10),
            dayBar(day: 13, o: 4, h: 5, l: 4, c: 5, v: 10),
            dayBar(day: 14, o: 5, h: 6, l: 5, c: 6, v: 10),
        ])
        XCTAssertEqual(w.map(\.ts_open_ms), [4 * Self.dayMs, 11 * Self.dayMs])
        XCTAssertEqual(w[0].open, 1)
        XCTAssertEqual(w[0].close, 4)
        XCTAssertEqual(w[0].volume, 30)
        XCTAssertEqual(w[1].open, 4)
        XCTAssertEqual(w[1].close, 6)
        XCTAssertEqual(w[1].volume, 20)
    }

    func testAggregateWeeklySundayJoinsPriorMondayBucket() {
        // A Sunday bar (day 10) merges into the prior Monday's bucket
        // (day 4), never a bucket of its own.
        let w = ChartMath.aggregateWeekly([
            dayBar(day: 6, o: 1, h: 2, l: 1, c: 2, v: 10),
            dayBar(day: 10, o: 2, h: 3, l: 2, c: 3, v: 10),
            dayBar(day: 11, o: 3, h: 4, l: 3, c: 4, v: 10),
        ])
        XCTAssertEqual(w.map(\.ts_open_ms), [4 * Self.dayMs, 11 * Self.dayMs])
        XCTAssertEqual(w[0].close, 3)
        XCTAssertEqual(w[0].volume, 20)
        XCTAssertEqual(w[1].open, 3)
    }

    func testAggregateWeeklyPartialLastBucketStaysForming() {
        // A forming daily bar leaves its (partial) weekly bucket forming too.
        let w = ChartMath.aggregateWeekly([
            dayBar(day: 7, o: 1, h: 2, l: 1, c: 2, v: 10),
            dayBar(day: 8, o: 2, h: 3, l: 2, c: 3, v: 10, complete: false),
        ])
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(w[0].ts_open_ms, 4 * Self.dayMs)
        XCTAssertFalse(w[0].complete)
    }

    func testAggregateWeeklyEmpty() {
        XCTAssertTrue(ChartMath.aggregateWeekly([]).isEmpty)
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
