// SETTINGS support: the set_broker_config command encode (fields + snake_case +
// number types), the BrokerSettings UserDefaults persistence roundtrip, and the
// allow-live safety gating. The cardinal invariant under test: the app can
// never mark a live config savable without an explicit real-money
// acknowledgement, and a live port with allow-live off is flagged as an
// engine-refused config — never a silent live reach.

import XCTest
@testable import CortexX

final class SettingsSupportTests: XCTestCase {
    // MARK: - Command.setBrokerConfig encode

    func testSetBrokerConfigEncodesAllFieldsSnakeCase() throws {
        let data = try Command.setBrokerConfig(
            mode: .ibkr, ibkrHost: "127.0.0.1", ibkrPort: 7497, ibkrClientId: 11,
            ibkrAccount: "DU1234567", ibkrRoute: "SMART", allowLive: false,
            maxLiveOrderNotional: 2_000, maxLivePositionNotional: 5_000,
            maxLiveDailyLoss: 500
        ).encoded()
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["cmd"] as? String, "set_broker_config")
        XCTAssertEqual(obj["mode"] as? String, "ibkr")
        XCTAssertEqual(obj["ibkr_host"] as? String, "127.0.0.1")
        XCTAssertEqual(obj["ibkr_port"] as? Int, 7497)
        XCTAssertEqual(obj["ibkr_client_id"] as? Int, 11)
        XCTAssertEqual(obj["ibkr_account"] as? String, "DU1234567")
        XCTAssertEqual(obj["ibkr_route"] as? String, "SMART")
        XCTAssertEqual(obj["allow_live"] as? Bool, false)
        XCTAssertEqual(obj["max_live_order_notional"] as? Double, 2_000)
        XCTAssertEqual(obj["max_live_position_notional"] as? Double, 5_000)
        XCTAssertEqual(obj["max_live_daily_loss"] as? Double, 500)

        // No swiftified keys leaked onto the wire.
        XCTAssertNil(obj["ibkrPort"])
        XCTAssertNil(obj["allowLive"])
        XCTAssertNil(obj["maxLiveOrderNotional"])
    }

    func testSetBrokerConfigPaperModeEncodes() throws {
        let data = try Command.setBrokerConfig(
            mode: .paper, ibkrHost: "127.0.0.1", ibkrPort: 7497, ibkrClientId: 11,
            ibkrAccount: "", ibkrRoute: "SMART", allowLive: false,
            maxLiveOrderNotional: 2_000, maxLivePositionNotional: 5_000,
            maxLiveDailyLoss: 500
        ).encoded()
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["mode"] as? String, "paper")
        XCTAssertEqual(obj["ibkr_account"] as? String, "")
    }

    func testBrokerConfigModeRawValuesMatchSerde() {
        XCTAssertEqual(BrokerConfigMode.paper.rawValue, "paper")
        XCTAssertEqual(BrokerConfigMode.ibkr.rawValue, "ibkr")
    }

    // MARK: - Persistence roundtrip

    func testBrokerSettingsPersistenceRoundtrip() throws {
        let suiteName = "cortex.test.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        // A fresh suite has nothing stored → the safe default.
        XCTAssertEqual(BrokerSettingsStore.load(suite), .default)

        var settings = BrokerSettings.default
        settings.mode = .ibkr
        settings.ibkrHost = "10.0.0.5"
        settings.ibkrPort = 4002
        settings.ibkrClientId = 42
        settings.ibkrAccount = "DU9999999"
        settings.ibkrRoute = "ARCA"
        settings.allowLive = false
        settings.maxLiveOrderNotional = 1_234.5
        settings.maxLivePositionNotional = 6_789
        settings.maxLiveDailyLoss = 250

        BrokerSettingsStore.save(settings, to: suite)
        XCTAssertEqual(BrokerSettingsStore.load(suite), settings)
    }

    func testBrokerSettingsLoadIsSafeDefaultOnCorruptRecord() throws {
        let suiteName = "cortex.test.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set(Data("not json".utf8), forKey: BrokerSettingsStore.key)
        // Corrupt record must decode to the safe paper default, never throw.
        XCTAssertEqual(BrokerSettingsStore.load(suite), .default)
        XCTAssertEqual(BrokerSettingsStore.load(suite).mode, .paper)
    }

    @MainActor
    func testApplyBrokerConfigPersistsAndUpdatesModel() {
        let model = AppModel()
        var settings = BrokerSettings.default
        settings.mode = .ibkr
        settings.ibkrAccount = "DU1"
        model.applyBrokerConfig(settings)
        XCTAssertEqual(model.brokerSettings, settings)
        // And it persisted to standard defaults for the next launch.
        XCTAssertEqual(BrokerSettingsStore.load(), settings)
        BrokerSettingsStore.save(.default) // restore
    }

    // MARK: - Port classification

    func testLivePortClassificationMatchesEngine() {
        XCTAssertTrue(BrokerLivePorts.isLivePort(7496))
        XCTAssertTrue(BrokerLivePorts.isLivePort(4001))
        XCTAssertFalse(BrokerLivePorts.isLivePort(7497))
        XCTAssertFalse(BrokerLivePorts.isLivePort(4002))
        XCTAssertFalse(BrokerLivePorts.isLivePort(1234))
    }

    // MARK: - Allow-live gating (the safety core)

    func testPaperDefaultIsSafelyApplicable() {
        let gate = BrokerConfigCheck.gate(.default, confirmedLive: false)
        XCTAssertFalse(gate.isLiveConfig)
        XCTAssertFalse(gate.refusedByEngine)
        XCTAssertFalse(gate.invalidLimits)
        XCTAssertFalse(gate.needsLiveConfirm)
        XCTAssertTrue(gate.canApply)
    }

    func testLivePortWithAllowLiveOffIsFlaggedRefusedNotLive() {
        var s = BrokerSettings.default
        s.mode = .ibkr
        s.ibkrPort = 7496 // LIVE port
        s.allowLive = false
        let gate = BrokerConfigCheck.gate(s, confirmedLive: false)
        XCTAssertTrue(gate.refusedByEngine)   // the engine will refuse it
        XCTAssertFalse(gate.isLiveConfig)     // and it never reads as live
        // It is not blocked client-side — the engine is the single source of
        // truth on refusal (it stays on the previous safe broker).
        XCTAssertTrue(gate.canApply)
    }

    func testAllowLiveCannotBeSavedWithoutConfirmation() {
        var s = BrokerSettings.default
        s.mode = .ibkr
        s.ibkrPort = 7496
        s.allowLive = true
        // Armed but NOT acknowledged → live config, but apply is blocked.
        let unconfirmed = BrokerConfigCheck.gate(s, confirmedLive: false)
        XCTAssertTrue(unconfirmed.isLiveConfig)
        XCTAssertTrue(unconfirmed.needsLiveConfirm)
        XCTAssertFalse(unconfirmed.canApply)

        // Acknowledged → the same config becomes savable.
        let confirmed = BrokerConfigCheck.gate(s, confirmedLive: true)
        XCTAssertFalse(confirmed.needsLiveConfirm)
        XCTAssertTrue(confirmed.canApply)
        XCTAssertTrue(confirmed.isLiveConfig)
    }

    func testAllowLiveOnPaperPortStillDemandsConfirmation() {
        // allow_live is a real-money arm regardless of the port; turning it on
        // always demands acknowledgement before it can be saved.
        var s = BrokerSettings.default
        s.mode = .ibkr
        s.ibkrPort = 7497 // paper port
        s.allowLive = true
        XCTAssertTrue(BrokerConfigCheck.gate(s, confirmedLive: false).needsLiveConfirm)
        XCTAssertFalse(BrokerConfigCheck.gate(s, confirmedLive: false).canApply)
    }

    func testInvalidLimitsBlockApplyEvenInPaper() {
        for bad in [0.0, -1.0, Double.nan, Double.infinity] {
            var s = BrokerSettings.default
            s.maxLiveOrderNotional = bad
            let gate = BrokerConfigCheck.gate(s, confirmedLive: false)
            XCTAssertTrue(gate.invalidLimits, "cap \(bad) must be invalid")
            XCTAssertFalse(gate.canApply, "cap \(bad) must block apply")
        }
        // Each of the three caps is guarded independently.
        var s = BrokerSettings.default
        s.maxLiveDailyLoss = 0
        XCTAssertTrue(BrokerConfigCheck.gate(s, confirmedLive: false).invalidLimits)
        s = .default
        s.maxLivePositionNotional = -5
        XCTAssertTrue(BrokerConfigCheck.gate(s, confirmedLive: false).invalidLimits)
    }
}
