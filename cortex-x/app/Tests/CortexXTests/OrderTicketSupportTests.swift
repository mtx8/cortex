// Order-ticket math tests: dollar/percent sizing (whole-share vs fractional),
// notional & equity concentration, price-tick banding + grid-snapped stepping,
// risk-per-share and reward:risk by side, and the flatten/reverse intent
// construction. Everything here is pure and NaN-safe — garbage in yields nil,
// never a bogus number the ticket would render as truth.

import XCTest
@testable import CortexX

final class OrderTicketSupportTests: XCTestCase {
    // MARK: - Dollar -> shares

    func testDollarSharesEquityFloorsToWhole() {
        // $1,000 of a $190 stock = 5.26… → 5 whole shares.
        XCTAssertEqual(OrderSizing.shares(dollars: 1_000, price: 190, whole: true), 5)
        // Exact multiple stays exact.
        XCTAssertEqual(OrderSizing.shares(dollars: 950, price: 190, whole: true), 5)
    }

    func testDollarSharesCryptoKeepsFraction() {
        // $1,000 of a $40,000 coin = 0.025 units, unfloored.
        let s = try? XCTUnwrap(OrderSizing.shares(dollars: 1_000, price: 40_000, whole: false))
        XCTAssertEqual(s ?? .nan, 0.025, accuracy: 1e-12)
    }

    func testDollarSharesNilWhenNothingAffordable() {
        // Can't afford a single whole share → nil, never 0.
        XCTAssertNil(OrderSizing.shares(dollars: 100, price: 190, whole: true))
    }

    func testDollarSharesNaNAndNonPositiveSafe() {
        XCTAssertNil(OrderSizing.shares(dollars: .nan, price: 190, whole: true))
        XCTAssertNil(OrderSizing.shares(dollars: 1_000, price: .nan, whole: true))
        XCTAssertNil(OrderSizing.shares(dollars: 1_000, price: 0, whole: true))
        XCTAssertNil(OrderSizing.shares(dollars: 0, price: 190, whole: true))
        XCTAssertNil(OrderSizing.shares(dollars: -1_000, price: 190, whole: true))
    }

    // MARK: - % of buying power

    func testPercentOfBuyingPowerSizes() {
        // 50% of $10,000 buying power at $100 = $5,000 → 50 shares.
        XCTAssertEqual(
            OrderSizing.sharesFromBuyingPower(
                fraction: 0.5, buyingPower: 10_000, price: 100, whole: true
            ), 50
        )
        // 100% chip.
        XCTAssertEqual(
            OrderSizing.sharesFromBuyingPower(
                fraction: 1.0, buyingPower: 10_000, price: 100, whole: true
            ), 100
        )
    }

    func testPercentOfBuyingPowerNaNAndEmptySafe() {
        XCTAssertNil(OrderSizing.sharesFromBuyingPower(
            fraction: 0.5, buyingPower: 0, price: 100, whole: true))
        XCTAssertNil(OrderSizing.sharesFromBuyingPower(
            fraction: .nan, buyingPower: 10_000, price: 100, whole: true))
        XCTAssertNil(OrderSizing.sharesFromBuyingPower(
            fraction: 0.5, buyingPower: 10_000, price: 0, whole: true))
    }

    // MARK: - Notional & concentration

    func testNotionalAndEquityFraction() {
        XCTAssertEqual(OrderSizing.notional(qty: 100, price: 25), 2_500)
        // Short (negative qty) still yields a positive notional.
        XCTAssertEqual(OrderSizing.notional(qty: -100, price: 25), 2_500)
        XCTAssertNil(OrderSizing.notional(qty: .nan, price: 25))

        XCTAssertEqual(OrderSizing.fractionOfEquity(notional: 2_500, equity: 10_000), 0.25)
        XCTAssertNil(OrderSizing.fractionOfEquity(notional: 2_500, equity: 0))
        XCTAssertNil(OrderSizing.fractionOfEquity(notional: .nan, equity: 10_000))
    }

    func testDefaultIncrementByAssetClass() {
        XCTAssertEqual(OrderSizing.defaultIncrement(whole: true), 100)   // equities
        XCTAssertEqual(OrderSizing.defaultIncrement(whole: false), 1)    // crypto
    }

    // MARK: - Price ticks

    func testTickSizeBands() {
        XCTAssertEqual(PriceTick.size(for: 43_000), 1)
        XCTAssertEqual(PriceTick.size(for: 1_500), 0.5)
        XCTAssertEqual(PriceTick.size(for: 190), 0.05)
        XCTAssertEqual(PriceTick.size(for: 5), 0.01)
        XCTAssertEqual(PriceTick.size(for: 0.4), 0.001)
        XCTAssertEqual(PriceTick.size(for: .nan), 0.01)
        XCTAssertEqual(PriceTick.size(for: 0), 0.01)
    }

    func testStepAddsAndSubtractsOnTheGrid() {
        XCTAssertEqual(PriceTick.step(price: 190.00, ticks: 1, tickSize: 0.05), 190.05, accuracy: 1e-9)
        XCTAssertEqual(PriceTick.step(price: 190.05, ticks: -1, tickSize: 0.05), 190.00, accuracy: 1e-9)
        // Off-grid input snaps to the nearest tick as it steps.
        XCTAssertEqual(PriceTick.step(price: 190.023, ticks: 1, tickSize: 0.05), 190.05, accuracy: 1e-9)
    }

    func testStepClampsAtZeroAndSurvivesNaN() {
        XCTAssertEqual(PriceTick.step(price: 0.02, ticks: -10, tickSize: 0.01), 0, accuracy: 1e-9)
        // Non-finite price falls back to a single tick from zero.
        XCTAssertEqual(PriceTick.step(price: .nan, ticks: 1, tickSize: 0.05), 0.05, accuracy: 1e-9)
        // A non-positive tick never divides-by-zero; returns the clamped price.
        XCTAssertEqual(PriceTick.step(price: 5, ticks: 1, tickSize: 0), 5, accuracy: 1e-9)
    }

    // MARK: - Risk per share

    func testRiskPerShareLongAndShort() {
        // Long from 100, stop 95 → 5/share at risk (stop below = protective).
        XCTAssertEqual(OrderRisk.riskPerShare(side: .buy, entry: 100, stop: 95), 5)
        // Short from 100, stop 105 → 5/share (stop above = protective).
        XCTAssertEqual(OrderRisk.riskPerShare(side: .sell, entry: 100, stop: 105), 5)
    }

    func testRiskPerShareWrongSideGoesNonPositive() {
        // Long with the stop ABOVE entry is not protective → <= 0.
        XCTAssertEqual(OrderRisk.riskPerShare(side: .buy, entry: 100, stop: 105), -5)
        XCTAssertNil(OrderRisk.riskPerShare(side: .buy, entry: .nan, stop: 95))
        XCTAssertNil(OrderRisk.riskPerShare(side: .sell, entry: 100, stop: .infinity))
    }

    // MARK: - Reward : risk

    func testRewardRiskLong() throws {
        // Entry 100, stop 95 (risk 5), target 110 (reward 10) → 2:1.
        let rr = try XCTUnwrap(OrderRisk.rr(side: .buy, entry: 100, stop: 95, target: 110))
        XCTAssertEqual(rr, 2, accuracy: 1e-9)
    }

    func testRewardRiskShort() throws {
        // Short entry 100, stop 105 (risk 5), target 90 (reward 10) → 2:1.
        let rr = try XCTUnwrap(OrderRisk.rr(side: .sell, entry: 100, stop: 105, target: 90))
        XCTAssertEqual(rr, 2, accuracy: 1e-9)
    }

    func testRewardRiskNilWithoutRealRisk() {
        // Stop on the wrong side (risk <= 0) → nil, no ratio.
        XCTAssertNil(OrderRisk.rr(side: .buy, entry: 100, stop: 105, target: 110))
        XCTAssertNil(OrderRisk.rr(side: .buy, entry: 100, stop: 95, target: .nan))
        // Target below entry for a long is a negative (unfavorable) ratio.
        let bad = try? XCTUnwrap(OrderRisk.rr(side: .buy, entry: 100, stop: 95, target: 98))
        XCTAssertLessThan(bad ?? .nan, 0)
    }

    // MARK: - Flatten / reverse intent construction

    func testFlattenLongSellsWholeSize() {
        XCTAssertEqual(
            PositionAction.flatten(positionQty: 100),
            OrderAction(side: .sell, qty: 100)
        )
    }

    func testFlattenShortBuysWholeSize() {
        XCTAssertEqual(
            PositionAction.flatten(positionQty: -50),
            OrderAction(side: .buy, qty: 50)
        )
    }

    func testReverseDoublesTheSize() {
        // Long 100 → sell 200 (close 100 + open short 100).
        XCTAssertEqual(
            PositionAction.reverse(positionQty: 100),
            OrderAction(side: .sell, qty: 200)
        )
        // Short 50 → buy 100.
        XCTAssertEqual(
            PositionAction.reverse(positionQty: -50),
            OrderAction(side: .buy, qty: 100)
        )
    }

    func testFlattenAndReverseNilWhenFlat() {
        XCTAssertNil(PositionAction.flatten(positionQty: 0))
        XCTAssertNil(PositionAction.reverse(positionQty: 0))
        XCTAssertNil(PositionAction.flatten(positionQty: .nan))
        XCTAssertNil(PositionAction.reverse(positionQty: 1e-13)) // below epsilon
    }
}
