// Print-age formatting for the chart's DELAYED chip.
//
// Equity quotes here come from the keyless CBOE delayed snapshot: the upstream
// itself only refreshes every few minutes and carries a trade time ~15 minutes
// behind the wall clock. Bars are stamped with that true trade time, so a
// CORRECT equity chart shows its newest candle a quarter of an hour in the past
// and repaints only a few times an hour — which was reported as "the charts
// don't work". The chip exists to make the data's real age legible, so this
// pins the one thing that must never lie: the number it prints.

import XCTest
@testable import CortexX

final class PrintAgeTests: XCTestCase {
    func testSecondsBelowAMinute() {
        XCTAssertEqual(ChartMath.compactAge(0), "0s")
        XCTAssertEqual(ChartMath.compactAge(1.9), "1s")
        XCTAssertEqual(ChartMath.compactAge(59.9), "59s")
    }

    func testMinutes() {
        XCTAssertEqual(ChartMath.compactAge(60), "1m")
        // The realistic case: a ~15-minute-delayed CBOE print.
        XCTAssertEqual(ChartMath.compactAge(15 * 60 + 25), "15m")
        XCTAssertEqual(ChartMath.compactAge(59 * 60 + 59), "59m")
    }

    func testHours() {
        XCTAssertEqual(ChartMath.compactAge(3_600), "1h 00m")
        XCTAssertEqual(ChartMath.compactAge(2 * 3_600 + 5 * 60), "2h 05m")
        // A weekend-old print on a Monday morning must still read sensibly.
        XCTAssertEqual(ChartMath.compactAge(62 * 3_600 + 30 * 60), "62h 30m")
    }

    func testNeverOverstatesFreshness() {
        // Rounding DOWN is the safety property: the age displayed must never be
        // younger than the data really is, or the chip would make stale data
        // look fresher than it is — the exact failure it exists to prevent.
        for seconds in stride(from: 0.0, through: 7_200.0, by: 7.3) {
            let shown = ChartMath.compactAge(seconds)
            let impliedSec: Int
            if shown.hasSuffix("s") {
                impliedSec = Int(shown.dropLast())!
            } else if shown.hasSuffix("m") && !shown.contains("h") {
                impliedSec = Int(shown.dropLast())! * 60
            } else {
                let parts = shown.split(separator: " ")
                impliedSec = Int(parts[0].dropLast())! * 3_600 + Int(parts[1].dropLast())! * 60
            }
            XCTAssertLessThanOrEqual(
                Double(impliedSec), seconds + 0.001,
                "compactAge(\(seconds)) = \(shown) claims the print is fresher than it is"
            )
        }
    }

    func testNegativeClockSkewIsClamped() {
        // A quote stamped slightly in the future (clock skew) must not render a
        // negative age.
        XCTAssertEqual(ChartMath.compactAge(-5), "0s")
    }
}
