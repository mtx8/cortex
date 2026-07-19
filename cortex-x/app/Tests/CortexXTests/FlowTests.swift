// FLOW panel tests: FlowRead frame decode (incl. lean/legacy payloads), the
// pressure verdict + flag label/meaning mapping, the centered imbalance-bar
// fraction (clamped, NaN-safe), the honest real/delayed banner, the desk
// narrative resolution, and the model's flow application (the subscription
// guard, disconnect clearing, and snapshot adoption).

import XCTest
@testable import CortexX

// MARK: - Wire protocol + pure helpers (no actor isolation needed)

final class FlowTests: XCTestCase {

    // MARK: Frame decode

    func testDecodeFlowFrame() throws {
        let json = #"{"type":"flow","symbol":"AAPL","imbalance":0.42,"cum_delta":12500,"delta_rate":-30,"pressure":"buyers","flags":["sweep:buy","absorption:ask"],"note":"buyers pressing","is_live":true,"source":"IBKR","ts_ms":123}"#
        guard case .flow(let f) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected flow")
        }
        XCTAssertEqual(f.symbol, "AAPL")
        XCTAssertEqual(f.imbalance, 0.42, accuracy: 1e-9)
        XCTAssertEqual(f.cum_delta, 12500)
        XCTAssertEqual(f.delta_rate, -30)
        XCTAssertEqual(f.pressure, "buyers")
        XCTAssertEqual(f.flags, ["sweep:buy", "absorption:ask"])
        XCTAssertEqual(f.note, "buyers pressing")
        XCTAssertTrue(f.is_live)
        XCTAssertEqual(f.source, "IBKR")
        XCTAssertEqual(f.ts_ms, 123)
    }

    func testDecodeLeanFlowDefaults() throws {
        // A minimal payload must decode (Flow is droppable) with zeroed metrics,
        // empty flags, and — the honesty rule — is_live == false + pressure
        // defaulting to the neutral "balanced".
        let json = #"{"type":"flow","symbol":"AAPL","ts_ms":1}"#
        guard case .flow(let f) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected flow")
        }
        XCTAssertEqual(f.imbalance, 0)
        XCTAssertEqual(f.cum_delta, 0)
        XCTAssertEqual(f.delta_rate, 0)
        XCTAssertEqual(f.pressure, "balanced")
        XCTAssertTrue(f.flags.isEmpty)
        XCTAssertEqual(f.note, "")
        XCTAssertFalse(f.is_live)
        XCTAssertEqual(f.source, "")
    }

    // MARK: Pressure verdict mapping

    func testPressureParsingAndHeadline() {
        XCTAssertEqual(FlowPressure.parse("buyers"), .buyers)
        XCTAssertEqual(FlowPressure.parse("SELLERS"), .sellers)
        XCTAssertEqual(FlowPressure.parse("balanced"), .balanced)
        // Unknown / absent decodes to the neutral balanced — never invents one.
        XCTAssertEqual(FlowPressure.parse("wobbly"), .balanced)
        XCTAssertEqual(FlowPressure.buyers.headline, "BUYERS in control")
        XCTAssertEqual(FlowPressure.sellers.headline, "SELLERS in control")
        XCTAssertEqual(FlowPressure.balanced.headline, "balanced")
    }

    func testPressureToneIsMoneyDirection() {
        XCTAssertEqual(FlowPressure.buyers.tone, .up)
        XCTAssertEqual(FlowPressure.sellers.tone, .down)
        XCTAssertEqual(FlowPressure.balanced.tone, .neutral)
    }

    // MARK: Flag label + meaning mapping

    func testFlagLabelMapping() {
        XCTAssertEqual(FlowFlag.describe("absorption:ask").label, "absorption (ask)")
        XCTAssertEqual(FlowFlag.describe("sweep:buy").label, "buy sweep")
        XCTAssertEqual(FlowFlag.describe("delta_divergence").label, "delta divergence — reversal risk")
        XCTAssertEqual(FlowFlag.describe("squeeze_dynamics").label, "squeeze dynamics")
        XCTAssertEqual(FlowFlag.describe("exhaustion").label, "exhaustion")
    }

    func testFlagMeaningIsProbabilistic() {
        // Reversal risk is framed as elevated risk, never a certainty.
        let meaning = FlowFlag.describe("delta_divergence").meaning
        XCTAssertTrue(meaning.contains("elevated reversal risk"))
        XCTAssertFalse(meaning.lowercased().contains("crash"))
    }

    func testSqueezeFlagMeaningIsTapeBehaviorNotShortInterest() {
        // Honesty rule: the squeeze chip must describe TAPE BEHAVIOR and carry
        // the mandatory not-short-interest caveat every other layer carries — it
        // must never frame the flag as crowd/short POSITIONING or a squeeze-
        // forcing prediction the engine (no short interest in Level-2) disavows.
        let lower = FlowFlag.describe("squeeze_dynamics").meaning.lowercased()
        XCTAssertTrue(lower.contains("behavior"))
        XCTAssertTrue(lower.contains("not a short-interest"))
        XCTAssertFalse(lower.contains("positioning"))
        XCTAssertFalse(lower.contains("force a squeeze"))
    }

    func testUnknownFlagHumanized() {
        // A future engine code still renders readably rather than as a raw token.
        let flag = FlowFlag.describe("iceberg:bid")
        XCTAssertEqual(flag.label, "iceberg (bid)")
        let single = FlowFlag.describe("stopping_volume")
        XCTAssertEqual(single.label, "stopping volume")
    }

    // MARK: Imbalance bar fraction (centered, clamped, NaN-safe)

    func testImbalanceFractionClampsAndIsNaNSafe() {
        XCTAssertEqual(FlowMetrics.imbalanceFraction(0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(FlowMetrics.imbalanceFraction(-0.25), -0.25, accuracy: 1e-9)
        XCTAssertEqual(FlowMetrics.imbalanceFraction(2), 1, accuracy: 1e-9)
        XCTAssertEqual(FlowMetrics.imbalanceFraction(-3), -1, accuracy: 1e-9)
        XCTAssertEqual(FlowMetrics.imbalanceFraction(.nan), 0)
        XCTAssertEqual(FlowMetrics.imbalanceFraction(.infinity), 0)
    }

    func testImbalanceScore() {
        XCTAssertEqual(FlowMetrics.imbalanceScore(0.42), 42)
        XCTAssertEqual(FlowMetrics.imbalanceScore(-0.5), -50)
        XCTAssertEqual(FlowMetrics.imbalanceScore(5), 100)
        XCTAssertEqual(FlowMetrics.imbalanceScore(.nan), 0)
    }

    // MARK: Real / delayed banner (honesty)

    func testBannerWaitingWhenNoFlow() {
        let b = FlowBanner.make(for: nil)
        XCTAssertEqual(b.kind, .waiting)
        XCTAssertFalse(b.isLive)
    }

    func testBannerLiveOnlyWhenIsLive() {
        let b = FlowBanner.make(for: flow(isLive: true, source: "IBKR"))
        XCTAssertEqual(b.kind, .live)
        XCTAssertTrue(b.isLive)
        XCTAssertEqual(b.source, "IBKR")
    }

    func testBannerDelayedNeverStyledLiveAndPointsToIBKR() {
        let b = FlowBanner.make(for: flow(isLive: false, source: "synthetic"))
        XCTAssertEqual(b.kind, .delayed)
        XCTAssertFalse(b.isLive)
        XCTAssertTrue(b.note.contains("delayed"))
        XCTAssertTrue(b.note.contains("IBKR"))
    }

    // MARK: Desk narrative resolution

    func testNarrativePrefersDeskFlowThoughtForSymbol() {
        let thoughts = [
            thought(squadron: "desk-flow", symbol: "AAPL", text: "desk: buyers absorbing"),
            thought(squadron: "desk-equity", symbol: "AAPL", text: "unrelated desk"),
        ]
        let out = FlowNarrative.resolve(note: "fallback note", thoughts: thoughts, symbol: "AAPL")
        XCTAssertEqual(out, "desk: buyers absorbing")
    }

    func testNarrativeFallsBackToNoteWhenNoDeskThought() {
        let thoughts = [thought(squadron: "desk-flow", symbol: "MSFT", text: "other symbol")]
        let out = FlowNarrative.resolve(note: "  read note  ", thoughts: thoughts, symbol: "AAPL")
        XCTAssertEqual(out, "read note")
    }

    func testNarrativeNilWhenEmptyEverywhere() {
        XCTAssertNil(FlowNarrative.resolve(note: "   ", thoughts: [], symbol: "AAPL"))
    }

    // MARK: Fixtures

    private func flow(isLive: Bool, source: String) -> FlowRead {
        FlowRead(
            symbol: "AAPL", imbalance: 0.1, cum_delta: 1, delta_rate: 0,
            pressure: "buyers", flags: [], note: "", is_live: isLive,
            source: source, ts_ms: 1
        )
    }

    private func thought(squadron: String, symbol: String, text: String) -> AgentThought {
        AgentThought(
            agent: "flowbot", squadron: squadron, severity: .insight, text: text,
            tags: [], confidence: 0.6, symbol: symbol, ts_ms: 1
        )
    }
}

// MARK: - Model application (subscription guard, clearing, snapshot adoption)

@MainActor
final class FlowModelTests: XCTestCase {

    func testFlowFrameOnlyAcceptedForSubscribedSymbol() {
        let model = AppModel()
        model.subscribeDepth("AAPL")
        model.apply(.flow(flow("AAPL")))
        XCTAssertEqual(model.flowRead?.symbol, "AAPL")
        // A read for a symbol we are not subscribed to must never overwrite it.
        model.apply(.flow(flow("MSFT")))
        XCTAssertEqual(model.flowRead?.symbol, "AAPL")
    }

    func testSubscribeSwitchClearsStaleFlow() {
        let model = AppModel()
        model.subscribeDepth("AAPL")
        model.apply(.flow(flow("AAPL")))
        XCTAssertNotNil(model.flowRead)
        // Re-subscribing the SAME symbol is a no-op: the read survives.
        model.subscribeDepth("AAPL")
        XCTAssertNotNil(model.flowRead)
        // Switching symbol clears the stale read.
        model.subscribeDepth("MSFT")
        XCTAssertNil(model.flowRead)
    }

    func testUnsubscribeClearsFlow() {
        let model = AppModel()
        model.subscribeDepth("AAPL")
        model.apply(.flow(flow("AAPL")))
        model.unsubscribeDepth()
        XCTAssertNil(model.flowRead)
    }

    func testDisconnectClearsFlow() {
        let model = AppModel()
        model.handleStateChange(.connected)
        model.subscribeDepth("AAPL")
        model.apply(.flow(flow("AAPL")))
        model.handleStateChange(.disconnected)
        XCTAssertNil(model.flowRead)
    }

    func testSnapshotFlowAdoptedForSubscribedSymbolOnly() {
        let model = AppModel()
        model.subscribeDepth("AAPL")
        model.apply(.snapshot(snapshot(
            symbols: ["AAPL"],
            flow: ["AAPL": flow("AAPL"), "MSFT": flow("MSFT")]
        )))
        XCTAssertEqual(model.flowRead?.symbol, "AAPL")
    }

    // MARK: Fixtures

    private func flow(_ symbol: String) -> FlowRead {
        FlowRead(
            symbol: symbol, imbalance: 0.2, cum_delta: 100, delta_rate: 5,
            pressure: "buyers", flags: ["sweep:buy"], note: "note",
            is_live: true, source: "test", ts_ms: 1
        )
    }

    private func snapshot(symbols: [String], flow: [String: FlowRead]) -> EngineSnapshot {
        EngineSnapshot(
            symbols: symbols, bars: [:], positions: [], account: nil,
            risk: nil, thoughts: [], orders: [], macro: nil, feeds: nil,
            regimes: nil, geo: nil, scan: nil, news: nil, search_universe: nil,
            depth: nil, flow: flow
        )
    }
}
