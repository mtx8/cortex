// Broker-mode visibility: the pure TopBar badge mapping (paper / ibkr-paper /
// ibkr-live), the additive-optional wire decode (broker_status frame + the
// snapshot `broker` field, including absence), and the AppModel rules that
// drive the badge. The cardinal safety invariant under test: the app reads as
// LIVE only for an explicit ibkr_live mode that is also connected — never off
// an unknown string, an absent field, or a dropped connection.

import SwiftUI
import XCTest
@testable import CortexX

@MainActor
final class BrokerStatusTests: XCTestCase {
    private let nowMs: Int64 = 1_760_000_000_000

    // MARK: - Badge text/color mapping (pure helper)

    func testBadgeDefaultsToPaperWhenNoPosture() {
        let s = BrokerBadge.style(for: nil)
        XCTAssertEqual(s.text, "PAPER")
        XCTAssertEqual(s.textColor, Theme.dim)
        XCTAssertEqual(s.dotColor, Theme.dim)
        XCTAssertFalse(s.isLive)
    }

    func testBadgePaperMode() {
        let s = BrokerBadge.style(for: BrokerStatus(mode: .paper, connected: false))
        XCTAssertEqual(s.text, "PAPER")
        XCTAssertEqual(s.textColor, Theme.dim)
        XCTAssertFalse(s.isLive)
    }

    func testBadgeIbkrPaperIsEmberAndNotLive() {
        let connected = BrokerBadge.style(
            for: BrokerStatus(mode: .ibkr_paper, connected: true))
        XCTAssertEqual(connected.text, "IBKR PAPER")
        XCTAssertEqual(connected.textColor, Theme.ember)
        XCTAssertEqual(connected.dotColor, Theme.up) // link up
        XCTAssertFalse(connected.isLive)

        let down = BrokerBadge.style(
            for: BrokerStatus(mode: .ibkr_paper, connected: false))
        XCTAssertEqual(down.text, "IBKR PAPER")
        XCTAssertEqual(down.textColor, Theme.ember)
        XCTAssertEqual(down.dotColor, Theme.dim) // link down
        XCTAssertFalse(down.isLive)
    }

    func testBadgeIbkrLiveConnectedIsLoudLive() {
        let s = BrokerBadge.style(
            for: BrokerStatus(mode: .ibkr_live, connected: true, account_masked: "U1***9"))
        XCTAssertEqual(s.text, "IBKR LIVE")
        XCTAssertEqual(s.textColor, Theme.ember)
        XCTAssertEqual(s.dotColor, Theme.ember)
        XCTAssertTrue(s.isLive)
        XCTAssertTrue(s.help.contains("U1***9")) // masked account surfaced
        XCTAssertTrue(s.help.uppercased().contains("REAL MONEY"))
    }

    func testBadgeIbkrLiveDisconnectedNeverRendersLive() {
        // Live is configured but the broker link is down — no order can flow,
        // so the badge must NOT read as LIVE.
        let s = BrokerBadge.style(
            for: BrokerStatus(mode: .ibkr_live, connected: false))
        XCTAssertFalse(s.isLive)
        XCTAssertFalse(s.text.contains("LIVE"))
        XCTAssertEqual(s.text, "IBKR")
    }

    // MARK: - Explicit BROKER label + connection-dot semantics

    func testBadgeAlwaysCarriesBrokerLabel() {
        // Every posture reads as the BROKER link, PAPER included, so the
        // indicator is never an anonymous dot.
        let postures: [BrokerStatus?] = [
            nil,
            BrokerStatus(mode: .paper, connected: false),
            BrokerStatus(mode: .ibkr_paper, connected: true),
            BrokerStatus(mode: .ibkr_paper, connected: false),
            BrokerStatus(mode: .ibkr_live, connected: true),
            BrokerStatus(mode: .ibkr_live, connected: false),
        ]
        for p in postures {
            XCTAssertEqual(BrokerBadge.style(for: p).label, "BROKER")
        }
    }

    func testBadgeConnectionDotVisibility() {
        // Paper is the internal simulator with no broker session → no link dot.
        XCTAssertFalse(BrokerBadge.style(for: nil).showDot)
        XCTAssertFalse(BrokerBadge.style(for: BrokerStatus(mode: .paper, connected: false)).showDot)
        // Every IBKR posture shows a link dot whose color tracks the session.
        XCTAssertTrue(BrokerBadge.style(for: BrokerStatus(mode: .ibkr_paper, connected: true)).showDot)
        XCTAssertTrue(BrokerBadge.style(for: BrokerStatus(mode: .ibkr_paper, connected: false)).showDot)
        XCTAssertTrue(BrokerBadge.style(for: BrokerStatus(mode: .ibkr_live, connected: true)).showDot)
        XCTAssertTrue(BrokerBadge.style(for: BrokerStatus(mode: .ibkr_live, connected: false)).showDot)
    }

    func testBadgeHelpAlwaysNamesTheBrokerLinkAndPaperIsSimulated() {
        // The tooltip must always frame the control as the broker link, and
        // every non-live posture must say the money is simulated.
        for p: BrokerStatus? in [nil, BrokerStatus(mode: .paper, connected: false)] {
            let s = BrokerBadge.style(for: p)
            XCTAssertTrue(s.help.lowercased().contains("broker link"))
            XCTAssertTrue(s.help.lowercased().contains("simulated"))
        }
        let paperLink = BrokerBadge.style(for: BrokerStatus(mode: .ibkr_paper, connected: true))
        XCTAssertTrue(paperLink.help.lowercased().contains("broker link"))
        XCTAssertTrue(paperLink.help.lowercased().contains("no real money"))
    }

    // MARK: - BrokerMode defensive decode (safety)

    func testBrokerModeKnownValuesDecode() throws {
        XCTAssertEqual(try decodeMode("\"paper\""), .paper)
        XCTAssertEqual(try decodeMode("\"ibkr_paper\""), .ibkr_paper)
        XCTAssertEqual(try decodeMode("\"ibkr_live\""), .ibkr_live)
    }

    func testUnknownBrokerModeDecodesToPaperNeverLive() throws {
        // A future / garbled mode must degrade to the safe paper posture — the
        // app can never upgrade itself to live off an unrecognized string.
        XCTAssertEqual(try decodeMode("\"ibkr_live_v2\""), .paper)
        XCTAssertEqual(try decodeMode("\"live\""), .paper)
        XCTAssertEqual(try decodeMode("\"\""), .paper)
    }

    // MARK: - broker_status frame decode (additive/optional)

    func testDecodeBrokerStatusFrame() throws {
        let json = #"{"type":"broker_status","mode":"ibkr_live","connected":true,"account_masked":"U12****89"}"#
        guard case .brokerStatus(let b) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected broker_status")
        }
        XCTAssertEqual(b.mode, .ibkr_live)
        XCTAssertTrue(b.connected)
        XCTAssertEqual(b.account_masked, "U12****89")
    }

    func testDecodeBrokerStatusPartialPayloadDefaultsSafe() throws {
        // A lean payload (no connected, no account) must decode — never fail
        // the frame — and default to the SAFER not-connected state.
        let json = #"{"type":"broker_status","mode":"ibkr_paper"}"#
        guard case .brokerStatus(let b) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected broker_status")
        }
        XCTAssertEqual(b.mode, .ibkr_paper)
        XCTAssertFalse(b.connected)
        XCTAssertNil(b.account_masked)
    }

    func testDecodeBrokerStatusEmptyPayloadIsPaper() throws {
        // Absolutely nothing but the tag → paper + disconnected, i.e. safe.
        let json = #"{"type":"broker_status"}"#
        guard case .brokerStatus(let b) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected broker_status")
        }
        XCTAssertEqual(b.mode, .paper)
        XCTAssertFalse(b.connected)
    }

    // MARK: - Snapshot broker field (additive/optional, incl. absence)

    func testSnapshotDecodesBrokerWhenPresent() throws {
        let json = #"{"type":"snapshot","data":{"symbols":["BTC-USD"],"bars":{},"positions":[],"thoughts":[],"orders":[],"broker":{"mode":"ibkr_live","connected":true}}}"#
        guard case .snapshot(let snap) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected snapshot")
        }
        XCTAssertEqual(snap.broker?.mode, .ibkr_live)
        XCTAssertEqual(snap.broker?.connected, true)
    }

    func testSnapshotWithoutBrokerDecodesNil() throws {
        // Older engines omit the key entirely — the snapshot must still decode,
        // with broker nil (the app then shows PAPER).
        let json = #"{"type":"snapshot","data":{"symbols":["BTC-USD"],"bars":{},"positions":[],"thoughts":[],"orders":[]}}"#
        guard case .snapshot(let snap) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected snapshot")
        }
        XCTAssertNil(snap.broker)
    }

    // MARK: - AppModel drive

    func testBrokerStatusFrameDrivesModel() {
        let model = AppModel()
        XCTAssertNil(model.broker) // defaults to PAPER via nil
        model.apply(.brokerStatus(BrokerStatus(mode: .ibkr_live, connected: true)))
        XCTAssertEqual(model.broker?.mode, .ibkr_live)
        XCTAssertTrue(BrokerBadge.style(for: model.broker).isLive)
    }

    func testSnapshotBrokerPopulatesAndAbsenceKeepsIt() {
        let model = AppModel()
        model.apply(.snapshot(snapshot(broker:
            BrokerStatus(mode: .ibkr_live, connected: true))))
        XCTAssertEqual(model.broker?.mode, .ibkr_live)
        // A lean re-sync snapshot without a broker field must not wipe it.
        model.apply(.snapshot(snapshot(broker: nil)))
        XCTAssertEqual(model.broker?.mode, .ibkr_live)
    }

    func testDisconnectClearsBrokerToSafeDefault() {
        // A dropped engine link cannot vouch for a live+connected broker, so
        // the posture must fall back to the PAPER default until re-vouched.
        let model = AppModel()
        model.handleStateChange(.connected)
        model.apply(.brokerStatus(BrokerStatus(mode: .ibkr_live, connected: true)))
        XCTAssertNotNil(model.broker)
        model.handleStateChange(.disconnected)
        XCTAssertNil(model.broker)
        XCTAssertFalse(BrokerBadge.style(for: model.broker).isLive)
    }

    // MARK: - Fixtures

    private func decodeMode(_ raw: String) throws -> BrokerMode {
        try JSONDecoder().decode(BrokerMode.self, from: Data(raw.utf8))
    }

    private func snapshot(broker: BrokerStatus?) -> EngineSnapshot {
        EngineSnapshot(
            symbols: ["BTC-USD"], bars: [:], positions: [], account: nil,
            risk: nil, thoughts: [], orders: [], macro: nil, feeds: nil,
            regimes: nil, geo: nil, scan: nil, news: nil, search_universe: nil,
            broker: broker
        )
    }
}
