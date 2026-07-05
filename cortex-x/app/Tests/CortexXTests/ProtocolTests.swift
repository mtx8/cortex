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
        let data = try Command.placeOrder(symbol: "BTC-USD", side: .buy, qty: 0.5, orderType: .limit, limitPx: 49000).encoded()
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["cmd"] as? String, "place_order")
        XCTAssertEqual(obj["order_type"] as? String, "limit")
        XCTAssertEqual(obj["limit_px"] as? Double, 49000)
    }
}
