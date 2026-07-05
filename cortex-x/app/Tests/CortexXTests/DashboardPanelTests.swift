// Dashboard deck formatting tests: adaptive prices, grouped money with
// rounded-sign handling, quantity trimming, percents, and editable prices.

import XCTest
@testable import CortexX

final class DashboardPanelTests: XCTestCase {
    // Adaptive price: >= 100 -> grouped 2dp; >= 1 -> 2-4dp; < 1 -> 4 sig digits.
    func testAdaptivePriceFormatting() {
        XCTAssertEqual(DashFormat.price(43250.128), "43,250.13")
        XCTAssertEqual(DashFormat.price(102.5), "102.50")
        XCTAssertEqual(DashFormat.price(100), "100.00")
        XCTAssertEqual(DashFormat.price(1.5), "1.50")
        XCTAssertEqual(DashFormat.price(1.23456), "1.2346")
        XCTAssertEqual(DashFormat.price(99.9999), "99.9999")
        XCTAssertEqual(DashFormat.price(0.1234), "0.1234")
        XCTAssertEqual(DashFormat.price(0.01234), "0.01234")
        XCTAssertEqual(DashFormat.price(0.001), "0.001000")
        XCTAssertEqual(DashFormat.price(0), "0.00")
        XCTAssertEqual(DashFormat.price(-250.5), "-250.50")
        XCTAssertEqual(DashFormat.price(.nan), "—")
    }

    func testMoneyGroupingAndSign() {
        XCTAssertEqual(DashFormat.money(1234567.891), "1,234,567.89")
        XCTAssertEqual(DashFormat.money(-42.5), "-42.50")
        XCTAssertEqual(DashFormat.money(42.5, signed: true), "+42.50")
        XCTAssertEqual(DashFormat.money(0, signed: true), "0.00")
        // Values that round to zero must not keep a sign.
        XCTAssertEqual(DashFormat.money(-0.001, signed: true), "0.00")
        XCTAssertEqual(DashFormat.money(0.001, signed: true), "0.00")
    }

    func testQtyTrimming() {
        XCTAssertEqual(DashFormat.qty(0.5), "0.5")
        XCTAssertEqual(DashFormat.qty(12), "12")
        XCTAssertEqual(DashFormat.qty(0.00012345), "0.00012")  // adaptive: 5dp below 1
        XCTAssertEqual(DashFormat.qty(1234.5678), "1234.6")     // adaptive: 1dp above 1k
        XCTAssertEqual(DashFormat.signedQty(2), "+2")
        XCTAssertEqual(DashFormat.signedQty(-0.25), "-0.25")
        XCTAssertEqual(DashFormat.signedQty(0), "0")
    }

    func testPercent() {
        XCTAssertEqual(DashFormat.pct(0.012), "1.2%")
        XCTAssertEqual(DashFormat.pct(0.03), "3.0%")
        XCTAssertEqual(DashFormat.pct(0), "0.0%")
        XCTAssertEqual(DashFormat.pct(.infinity), "—")
    }

    // Editable prices must survive a round-trip through Double(...) — the
    // ticket parses them back, so no grouping separators allowed.
    func testEditablePriceParsesBack() {
        for v in [43250.128, 102.5, 1.23456, 0.01234, 0.5] {
            let text = DashFormat.editable(v)
            XCTAssertFalse(text.contains(","), "grouped separator leaked into editable text: \(text)")
            let parsed = Double(text)
            XCTAssertNotNil(parsed, "editable text did not parse: \(text)")
            XCTAssertEqual(parsed!, v, accuracy: max(v * 0.001, 0.005))
        }
    }
}
