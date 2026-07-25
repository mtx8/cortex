// Regressions for two protocol-layer repairs:
//
//   1. `ServerFrame.decode` used to parse every frame TWICE — once into a
//      throwaway `Probe` just to read the "type" tag, then again for the payload
//      — and `EngineClient` ran both parses on the main actor. On the multi-MB
//      deep-sync snapshot that froze the window for 0.3-0.6 s, kill switch
//      included. Decode is now single-pass and runs off the main actor, so these
//      tests pin the semantics that must survive the rewrite (tag handling, the
//      snapshot wrapper, legacy hello defaults, failure modes) and the Sendable
//      guarantee that lets a frame cross back to the main actor.
//
//   2. `set_broker_config` shipped a raw Swift `Int` for fields the engine
//      declares as `u16` / `i32`. Because `cx_core::Command` is internally
//      tagged, one out-of-range value made serde reject the WHOLE frame, so a
//      typo'd port silently discarded the entire broker reconfiguration while the
//      app showed it as applied. Encoding now refuses, with the value named.

import XCTest
@testable import CortexX

final class ProtocolRepairTests: XCTestCase {
    // MARK: - Single-pass frame decode

    func testSnapshotDecodesOutOfItsDataWrapper() throws {
        let json = #"""
        {"type":"snapshot","data":{"symbols":["BTC-USD"],"bars":{"BTC-USD":{"m1":[{"symbol":"BTC-USD","interval":"m1","ts_open_ms":1,"open":1,"high":2,"low":0.5,"close":1.5,"volume":10,"trade_count":3,"vwap":1.4,"complete":true}]}},"positions":[],"thoughts":[],"orders":[]}}
        """#
        guard case .snapshot(let snap) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected snapshot")
        }
        XCTAssertEqual(snap.symbols, ["BTC-USD"])
        XCTAssertEqual(snap.bars["BTC-USD"]?["m1"]?.first?.close, 1.5)
    }

    func testTagIsReadFromTheTopLevelObjectRegardlessOfKeyOrder() throws {
        // Guards the single-pass rewrite against the tempting shortcut of scanning
        // the bytes for `"type"`: here the tag comes AFTER the payload and the
        // payload itself contains a nested "type" key, so a substring probe would
        // decode this as a tick.
        let json = #"""
        {"data":{"type":"tick","symbols":["AAPL"],"bars":{},"positions":[],"thoughts":[],"orders":[]},"type":"snapshot"}
        """#
        guard case .snapshot(let snap) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected snapshot, not the nested tag")
        }
        XCTAssertEqual(snap.symbols, ["AAPL"])
    }

    func testModernHelloKeepsProtocolAndCapabilities() throws {
        let json = #"{"type":"hello","protocol":2,"capabilities":["history_interval","shutdown"],"engine_version":"0.1.0"}"#
        guard case .hello(let version, let caps, let engineVersion) =
                try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected hello")
        }
        XCTAssertEqual(version, 2)
        XCTAssertEqual(caps, ["history_interval", "shutdown"])
        XCTAssertEqual(engineVersion, "0.1.0")
    }

    func testLegacyHelloFallsBackToProtocolOneAndNoCapabilities() throws {
        // A pre-capabilities engine sends the tag alone. It must decode, not fail:
        // the ABSENCE of capabilities is how the app learns the engine is old.
        guard case .hello(let version, let caps, let engineVersion) =
                try ServerFrame.decode(Data(#"{"type":"hello"}"#.utf8)) else {
            return XCTFail("expected hello")
        }
        XCTAssertEqual(version, 1)
        XCTAssertTrue(caps.isEmpty)
        XCTAssertEqual(engineVersion, "")
    }

    func testScalarFramesStillCarryTheirOneField() throws {
        guard case .gap(let dropped) =
                try ServerFrame.decode(Data(#"{"type":"gap","dropped":42}"#.utf8)) else {
            return XCTFail("expected gap")
        }
        XCTAssertEqual(dropped, 42)

        guard case .error(let detail) =
                try ServerFrame.decode(Data(#"{"type":"error","detail":"bad command"}"#.utf8)) else {
            return XCTFail("expected error")
        }
        XCTAssertEqual(detail, "bad command")
    }

    func testUnrecognizedTypeIsSurfacedNotThrown() throws {
        // Forward compatibility: a newer engine's frame is reported by name so the
        // app can log it, never treated as a broken connection.
        guard case .unknown(let type) =
                try ServerFrame.decode(Data(#"{"type":"quantum_flux","x":1}"#.utf8)) else {
            return XCTFail("expected unknown")
        }
        XCTAssertEqual(type, "quantum_flux")
    }

    func testUntaggedAndMalformedFramesStillThrow() {
        // No tag at all: not a frame. (EngineClient turns the throw into "ignore
        // this message", which must stay a decision made on a real failure.)
        XCTAssertThrowsError(try ServerFrame.decode(Data(#"{"symbol":"BTC-USD"}"#.utf8)))
        // Tag present, payload wrong: `price` missing from a tick.
        XCTAssertThrowsError(try ServerFrame.decode(
            Data(#"{"type":"tick","symbol":"BTC-USD","ts_ms":1,"size":1,"venue":"coinbase"}"#.utf8)
        ))
        XCTAssertThrowsError(try ServerFrame.decode(Data("not json at all".utf8)))
    }

    // MARK: - Off-main-actor decode

    func testFrameDecodesAwayFromTheMainActorAndCrossesBack() async throws {
        let payload = Data(
            #"{"type":"tick","symbol":"BTC-USD","ts_ms":1,"price":50000.5,"size":0.1,"aggressor":"buy","venue":"coinbase"}"#.utf8
        )
        // Exactly what EngineClient now does: parse off the main actor, hand the
        // finished frame back. This compiles only while ServerFrame — and every
        // payload it carries — is Sendable, which is the real guarantee under
        // test: a frame parsed on the cooperative pool is copied to the main
        // actor, never shared with it.
        let frame = await Task.detached { try? ServerFrame.decode(payload) }.value
        guard case .tick(let tick) = frame else { return XCTFail("expected tick") }
        XCTAssertEqual(tick.price, 50000.5)
    }

    // MARK: - set_broker_config wire ranges

    func testInRangeBrokerConfigStillEncodesItsIntegers() throws {
        let data = try Command.setBrokerConfig(
            mode: .ibkr, ibkrHost: "127.0.0.1", ibkrPort: 7497, ibkrClientId: 11,
            ibkrAccount: "DU1234567", ibkrRoute: "SMART", allowLive: false,
            maxLiveOrderNotional: 2_000, maxLivePositionNotional: 5_000,
            maxLiveDailyLoss: 500
        ).encoded()
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["ibkr_port"] as? Int, 7497)
        XCTAssertEqual(obj["ibkr_client_id"] as? Int, 11)
    }

    func testPortBoundariesAreAccepted() throws {
        for port in [BrokerConfigLimits.portRange.lowerBound,
                     7496,
                     BrokerConfigLimits.portRange.upperBound] {
            let data = try brokerConfig(port: port).encoded()
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(obj["ibkr_port"] as? Int, port)
        }
    }

    func testOutOfRangePortIsRefusedInsteadOfShippingADoomedFrame() {
        // 70000 does not fit `u16`, so serde would reject the ENTIRE frame and the
        // whole broker reconfiguration would vanish behind a generic "bad
        // command". Refuse locally, naming the value the operator must fix.
        let expected = CommandEncodingError.fieldOutOfRange(
            field: "IBKR port", value: 70_000, allowed: BrokerConfigLimits.portRange
        )
        XCTAssertThrowsError(try brokerConfig(port: 70_000).encoded()) { error in
            XCTAssertEqual(error as? CommandEncodingError, expected)
            // The reason reaches the operator through onSendFailure, so it has to
            // name both the field and the offending number.
            XCTAssertTrue(error.localizedDescription.contains("IBKR port"))
            XCTAssertTrue(error.localizedDescription.contains("70000"))
        }
        // Port 0 deserializes into u16 happily but is not connectable.
        XCTAssertThrowsError(try brokerConfig(port: 0).encoded())
        XCTAssertThrowsError(try brokerConfig(port: -1).encoded())
    }

    func testOutOfRangeClientIdIsRefused() throws {
        // `ibkr_client_id` is i32 on the engine side, and IBKR client ids are
        // non-negative — same whole-frame failure mode as the port.
        XCTAssertThrowsError(try brokerConfig(port: 7497, clientId: -1).encoded())
        XCTAssertThrowsError(
            try brokerConfig(port: 7497, clientId: Int(Int32.max) + 1).encoded()
        )
        // The extremes that DO fit still go out.
        for clientId in [BrokerConfigLimits.clientIdRange.lowerBound,
                         BrokerConfigLimits.clientIdRange.upperBound] {
            let data = try brokerConfig(port: 7497, clientId: clientId).encoded()
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(obj["ibkr_client_id"] as? Int, clientId)
        }
    }

    /// A broker config that differs from the safe default only in the two fields
    /// whose Swift type is wider than the engine's.
    private func brokerConfig(port: Int, clientId: Int = 11) -> Command {
        .setBrokerConfig(
            mode: .ibkr, ibkrHost: "127.0.0.1", ibkrPort: port, ibkrClientId: clientId,
            ibkrAccount: "DU1234567", ibkrRoute: "SMART", allowLive: false,
            maxLiveOrderNotional: 2_000, maxLivePositionNotional: 5_000,
            maxLiveDailyLoss: 500
        )
    }
}
