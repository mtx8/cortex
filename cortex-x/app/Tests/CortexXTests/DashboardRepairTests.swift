// Dashboard deck repairs:
//
// 1. Terminal order statuses (OrdersTable) — a broker/OMS refusal arrives as
//    `canceled(reason:)`, exactly like the operator's own cancel. The table used
//    to drop the reason and paint both dim, so a blocked real-money order was
//    indistinguishable from a cancel the operator asked for.
// 2. The positions-table Close gate (PositionsTable) — a one-click real-money
//    market liquidation now goes through the ticket's live-confirmation rule and
//    is inert when the engine cannot be reached.
// 3. TicketForm (OrderTicket) — the ticket's size/risk math extracted into a
//    pure value so the parent view no longer reads ~12 Hz quote/account state in
//    its body. These tests pin the extracted math to the numbers the inline
//    version produced.

import SwiftUI
import XCTest
@testable import CortexX

@MainActor
final class DashboardRepairTests: XCTestCase {
    // MARK: - Terminal status presentation

    func testRiskRejectionStillReadsAsARejectionWithItsReason() {
        let s = OrderStatus.rejectedByRisk(reason: "notional 76000.00 over cap")
        XCTAssertTrue(OrderStatusPresentation.isRefusal(s))
        XCTAssertEqual(OrderStatusPresentation.label(s), "rejected")
        XCTAssertEqual(OrderStatusPresentation.detailText(s), "notional 76000.00 over cap")
    }

    func testLiveGuardBlockIsNotPresentedAsAnOperatorCancel() {
        // cx-broker/src/ibkr.rs publishes guard rejections as Canceled + reason.
        let s = OrderStatus.canceled(
            reason: "live guard: live order notional 76000.00 exceeds max_live_order_notional 25000.00"
        )
        XCTAssertTrue(OrderStatusPresentation.isRefusal(s))
        XCTAssertEqual(OrderStatusPresentation.label(s), "blocked")
        XCTAssertEqual(
            OrderStatusPresentation.detailText(s),
            "live guard: live order notional 76000.00 exceeds max_live_order_notional 25000.00"
        )
    }

    func testEveryEngineRefusalReasonClassifiesAsARefusal() {
        // The exact strings the engine emits on the refusal paths.
        let refusals = [
            "IBKR position book not yet reconciled; holding order until positions sync",
            "IBKR adapter routes US equities only in v1; BTC-USD not routed live",
            "reduce-only: nothing to reduce",
            "no market",
            "limit order requires a limit price",
            "stop order requires a stop price",
            "invalid order",
            "ioc not marketable",
        ]
        for reason in refusals {
            let s = OrderStatus.canceled(reason: reason)
            XCTAssertTrue(OrderStatusPresentation.isRefusal(s), "\(reason) should read as blocked")
            XCTAssertEqual(OrderStatusPresentation.label(s), "blocked", reason)
            XCTAssertEqual(OrderStatusPresentation.detailText(s), reason)
        }
    }

    func testRequestedCancelsStayDimAndUnlabelled() {
        // The row's own Cancel button (cx-broker/src/paper.rs) and a reasonless
        // cancel must keep reading as an ordinary cancel with no extra line.
        for reason in ["broker cancel", "operator", "", "   "] {
            let s = OrderStatus.canceled(reason: reason)
            XCTAssertFalse(OrderStatusPresentation.isRefusal(s), "\(reason) is a requested cancel")
            XCTAssertEqual(OrderStatusPresentation.label(s), "canceled", reason)
            XCTAssertNil(OrderStatusPresentation.detailText(s), reason)
        }
    }

    func testHaltCancelsKeepTheirReasonButAreNotRefusals() {
        // A kill switch closing the operator's working order is not a refusal of
        // that order — but the operator still needs to see WHY it went away.
        for reason in ["kill switch", "drawdown kill switch", "operator flatten"] {
            let s = OrderStatus.canceled(reason: reason)
            XCTAssertFalse(OrderStatusPresentation.isRefusal(s), reason)
            XCTAssertEqual(OrderStatusPresentation.label(s), "canceled", reason)
            XCTAssertEqual(OrderStatusPresentation.detailText(s), reason)
        }
    }

    func testClassificationIgnoresCaseAndSurroundingWhitespace() {
        let s = OrderStatus.canceled(reason: "  Broker Cancel  ")
        XCTAssertFalse(OrderStatusPresentation.isRefusal(s))
        XCTAssertNil(OrderStatusPresentation.detailText(s))
    }

    func testNonTerminalAndFilledStatusesCarryNoReasonLine() {
        let statuses: [OrderStatus] = [
            .pendingRisk, .accepted, .working, .partiallyFilled, .filled,
        ]
        for s in statuses {
            XCTAssertFalse(OrderStatusPresentation.isRefusal(s))
            XCTAssertNil(OrderStatusPresentation.reason(s))
            XCTAssertNil(OrderStatusPresentation.detailText(s))
            XCTAssertEqual(OrderStatusPresentation.label(s), s.label)
        }
    }

    func testDecodedEngineFrameIsClassifiedFromItsWireReason() throws {
        // End to end from the wire: the decoder keeps the reason (Models.swift)
        // and the presentation turns it into a visible block.
        let json = #"{"state":"canceled","reason":"reduce-only: nothing to reduce"}"#
        let s = try JSONDecoder().decode(OrderStatus.self, from: Data(json.utf8))
        XCTAssertTrue(OrderStatusPresentation.isRefusal(s))
        XCTAssertEqual(OrderStatusPresentation.label(s), "blocked")
        XCTAssertEqual(OrderStatusPresentation.detailText(s), "reduce-only: nothing to reduce")
    }

    // MARK: - Positions-table Close gate

    func testCloseOnALiveVenueAsksBeforeItFires() {
        XCTAssertEqual(
            PositionCloseGate.decide(
                positionQty: 400, engineReachable: true,
                isLiveVenue: true, confirmBeforeLive: true
            ),
            .confirm
        )
    }

    func testCloseOnPaperStillFiresOnTheClick() {
        // The common path must be untouched: paper dispatches immediately.
        XCTAssertEqual(
            PositionCloseGate.decide(
                positionQty: -3, engineReachable: true,
                isLiveVenue: false, confirmBeforeLive: true
            ),
            .dispatch
        )
    }

    func testLoweredBackstopDispatchesOnALiveVenue() {
        // The operator may deliberately lower the confirmation in SETTINGS.
        XCTAssertEqual(
            PositionCloseGate.decide(
                positionQty: 400, engineReachable: true,
                isLiveVenue: true, confirmBeforeLive: false
            ),
            .dispatch
        )
    }

    func testCloseIsBlockedWithoutAnEngine() {
        // A control that cannot act must not look armed — and must not stage a
        // confirmation whose "yes" would go nowhere.
        XCTAssertEqual(
            PositionCloseGate.decide(
                positionQty: 400, engineReachable: false,
                isLiveVenue: true, confirmBeforeLive: true
            ),
            .blocked
        )
    }

    func testCloseIsBlockedOnAFlatOrNonsensePosition() {
        for qty in [0.0, 1e-13, -1e-13, Double.nan, Double.infinity] {
            XCTAssertEqual(
                PositionCloseGate.decide(
                    positionQty: qty, engineReachable: true,
                    isLiveVenue: false, confirmBeforeLive: true
                ),
                .blocked,
                "qty \(qty) is flat"
            )
        }
    }

    func testCloseUsesTheSharedFlattenBuilderSoTheTicketAndTableAgree() {
        // The table's close derives side/qty from PositionAction.flatten, the
        // same builder the ticket's FLATTEN uses — a long sells, a short buys.
        XCTAssertEqual(PositionAction.flatten(positionQty: 400)?.side, .sell)
        XCTAssertEqual(PositionAction.flatten(positionQty: 400)?.qty, 400)
        XCTAssertEqual(PositionAction.flatten(positionQty: -2.5)?.side, .buy)
        XCTAssertEqual(PositionAction.flatten(positionQty: -2.5)?.qty, 2.5)
    }

    // MARK: - TicketForm (extracted ticket math)

    private func form(
        symbol: String = "AAPL",
        side: Side = .buy,
        type: OrderType = .market,
        mode: OrderTicket.SizingMode = .shares,
        qty: String = "",
        dollars: String = "",
        pct: Double? = nil,
        limit: String = "",
        stop: String = ""
    ) -> TicketForm {
        TicketForm(
            symbol: symbol, side: side, orderType: type, sizingMode: mode,
            qtyText: qty, dollarText: dollars, pctSelected: pct,
            limitText: limit, stopText: stop
        )
    }

    func testSharesModeNeedsNoPriceAndFloorsEquities() {
        let f = form(qty: "10.7")
        XCTAssertEqual(f.qty(price: nil, buyingPower: 0), 10)
        XCTAssertEqual(f.qty(price: 190, buyingPower: 100_000), 10)
        // Crypto keeps the fraction.
        XCTAssertEqual(form(symbol: "BTC-USD", qty: "0.25").qty(price: nil, buyingPower: 0), 0.25)
    }

    func testDollarAndPercentModesResolveOffTheLivePrice() {
        XCTAssertEqual(form(mode: .dollars, dollars: "1000").qty(price: 190, buyingPower: 0), 5)
        XCTAssertNil(form(mode: .dollars, dollars: "1000").qty(price: nil, buyingPower: 0))
        XCTAssertEqual(form(mode: .percent, pct: 0.25).qty(price: 100, buyingPower: 40_000), 100)
        XCTAssertNil(form(mode: .percent, pct: 0.25).qty(price: 100, buyingPower: 0))
    }

    func testWorkingPricePrefersTheOrdersOwnPriceOverTheMark() {
        XCTAssertEqual(form(type: .limit, limit: "185.50").workingPrice(190), 185.50)
        XCTAssertEqual(form(type: .stop, stop: "180").workingPrice(190), 180)
        // A stop-limit works at its limit; a market works at the mark.
        XCTAssertEqual(form(type: .stop_limit, limit: "200", stop: "195").workingPrice(190), 200)
        XCTAssertEqual(form().workingPrice(190), 190)
        XCTAssertNil(form().workingPrice(nil))
    }

    func testNotionalEquityFractionAndRiskMatchTheInlineMath() {
        let f = form(type: .stop, qty: "100", stop: "180")
        XCTAssertEqual(f.notional(price: 190, buyingPower: 0), 18_000)
        XCTAssertEqual(
            f.equityFraction(price: 190, buyingPower: 0, equity: 100_000) ?? 0, 0.18,
            accuracy: 1e-9
        )
        // A stop order works AT the stop, so risk/share is measured from the
        // market to that stop: long 190 -> 180 = 10/share on 100 shares.
        XCTAssertEqual(f.riskPerShare(price: 190), 10)
        XCTAssertEqual(f.totalRisk(price: 190, buyingPower: 0), 1_000)
        XCTAssertNil(form(qty: "100").riskPerShare(price: 190)) // no stop set
        XCTAssertNil(f.equityFraction(price: 190, buyingPower: 0, equity: 0))
    }

    func testRewardRiskOnlyExistsForAStopLimitWithBothLevels() {
        let f = form(type: .stop_limit, qty: "10", limit: "200", stop: "185")
        XCTAssertEqual(f.rewardRisk(price: 190) ?? 0, 2.0, accuracy: 1e-9)
        XCTAssertNil(form(type: .limit, limit: "200").rewardRisk(price: 190))
        XCTAssertNil(f.rewardRisk(price: nil))
    }

    func testSubmitGateNeedsSizeLevelsLinkAndNoHalt() {
        let ok = form(qty: "100")
        XCTAssertTrue(ok.canSubmit(price: 190, buyingPower: 0, connected: true, killSwitch: false))
        XCTAssertFalse(ok.canSubmit(price: 190, buyingPower: 0, connected: false, killSwitch: false))
        XCTAssertFalse(ok.canSubmit(price: 190, buyingPower: 0, connected: true, killSwitch: true))
        // No size typed.
        XCTAssertFalse(form().canSubmit(price: 190, buyingPower: 0, connected: true, killSwitch: false))
        // A limit order with no limit price, and a stop order with no stop.
        XCTAssertFalse(
            form(type: .limit, qty: "100")
                .canSubmit(price: 190, buyingPower: 0, connected: true, killSwitch: false)
        )
        XCTAssertFalse(
            form(type: .stop, qty: "100")
                .canSubmit(price: 190, buyingPower: 0, connected: true, killSwitch: false)
        )
        // $-sizing with no market cannot resolve a share count, so it cannot arm.
        XCTAssertFalse(
            form(mode: .dollars, dollars: "1000")
                .canSubmit(price: nil, buyingPower: 0, connected: true, killSwitch: false)
        )
    }

    func testFieldParserRejectsEverythingThatIsNotATradeableNumber() {
        XCTAssertEqual(TicketForm.parse("1,250.5"), 1250.5)
        XCTAssertEqual(TicketForm.parse(" 42 "), 42)
        for bad in ["", "   ", "abc", "0", "-5", "nan", "inf"] {
            XCTAssertNil(TicketForm.parse(bad), bad)
        }
    }
}
