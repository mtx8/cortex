// Wire-protocol decode tests against literal JSON as cortexd emits it.

import XCTest
@testable import CortexX

final class ProtocolTests: XCTestCase {
    func testDecodeTick() throws {
        let json = #"{"type":"tick","symbol":"BTC-USD","ts_ms":1,"price":50000.5,"size":0.1,"aggressor":"buy","venue":"coinbase"}"#
        guard case .tick(let t) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected tick")
        }
        XCTAssertEqual(t.price, 50000.5)
        XCTAssertEqual(t.aggressor, .buy)
    }

    func testDecodeOrderStatusTagged() throws {
        let json = #"{"type":"order_update","order_id":7,"intent":{"id":7,"symbol":"ETH-USD","side":"sell","qty":1.5,"order_type":"market","limit_px":null,"tif":"ioc","reduce_only":false,"source":{"kind":"strategy","name":"momentum"},"rationale":"test","ts_ms":2},"status":{"state":"rejected_by_risk","reason":"kill switch engaged"},"filled_qty":0.0,"avg_fill_px":0.0,"ts_ms":3}"#
        guard case .orderUpdate(let u) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected order_update")
        }
        XCTAssertEqual(u.status, .rejectedByRisk(reason: "kill switch engaged"))
        XCTAssertEqual(u.intent.source, .strategy("momentum"))
    }

    func testEncodePlaceOrderCommand() throws {
        let data = try Command.placeOrder(
            symbol: "BTC-USD", side: .buy, qty: 0.5, orderType: .limit,
            limitPx: 49000, stopPx: nil
        ).encoded()
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["cmd"] as? String, "place_order")
        XCTAssertEqual(obj["order_type"] as? String, "limit")
        XCTAssertEqual(obj["limit_px"] as? Double, 49000)
        // A limit order carries no stop price on the wire.
        XCTAssertNil(obj["stop_px"])
    }

    // MARK: - Stop orders (additive + optional wire contract)

    func testOrderTypeRawValuesMatchSerde() {
        // Swift raw values must equal the serde snake_case strings verbatim.
        XCTAssertEqual(OrderType.market.rawValue, "market")
        XCTAssertEqual(OrderType.limit.rawValue, "limit")
        XCTAssertEqual(OrderType.stop.rawValue, "stop")
        XCTAssertEqual(OrderType.stop_limit.rawValue, "stop_limit")
    }

    func testEncodeStopMarketCommand() throws {
        // A stop (trigger only) ships stop_px, no limit_px.
        let data = try Command.placeOrder(
            symbol: "AAPL", side: .sell, qty: 10, orderType: .stop,
            limitPx: nil, stopPx: 185.5
        ).encoded()
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["order_type"] as? String, "stop")
        XCTAssertEqual(obj["stop_px"] as? Double, 185.5)
        XCTAssertNil(obj["limit_px"])
    }

    func testEncodeStopLimitCommandCarriesBothPrices() throws {
        let data = try Command.placeOrder(
            symbol: "AAPL", side: .buy, qty: 5, orderType: .stop_limit,
            limitPx: 190.25, stopPx: 189.0
        ).encoded()
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["order_type"] as? String, "stop_limit")
        XCTAssertEqual(obj["limit_px"] as? Double, 190.25)
        XCTAssertEqual(obj["stop_px"] as? Double, 189.0)
    }

    func testDecodeOrderUpdateWithStopLimit() throws {
        let json = #"{"type":"order_update","order_id":9,"intent":{"id":9,"symbol":"AAPL","side":"buy","qty":5,"order_type":"stop_limit","limit_px":190.25,"stop_px":189.0,"tif":"day","reduce_only":false,"source":{"kind":"manual"},"rationale":"","ts_ms":1},"status":{"state":"working"},"filled_qty":0.0,"avg_fill_px":0.0,"ts_ms":2}"#
        guard case .orderUpdate(let u) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected order_update")
        }
        XCTAssertEqual(u.intent.order_type, .stop_limit)
        XCTAssertEqual(u.intent.stop_px, 189.0)
        XCTAssertEqual(u.intent.limit_px, 190.25)
    }

    func testDecodeLegacyOrderIntentWithoutStopPx() throws {
        // Older engines omit stop_px entirely — it must decode nil, not fail.
        let json = #"{"type":"order_intent","id":3,"symbol":"ETH-USD","side":"buy","qty":1.0,"order_type":"market","limit_px":null,"tif":"ioc","reduce_only":false,"source":{"kind":"manual"},"rationale":"","ts_ms":1}"#
        guard case .orderIntent(let i) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected order_intent")
        }
        XCTAssertEqual(i.order_type, .market)
        XCTAssertNil(i.stop_px)
    }
}
