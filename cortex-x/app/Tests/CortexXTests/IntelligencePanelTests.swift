// State-flow tests for the intelligence rail: copilot ask/answer lifecycle,
// agent-feed ordering, signal ingestion, and macro snapshot application.

import XCTest
@testable import CortexX

@MainActor
final class IntelligencePanelTests: XCTestCase {
    // MARK: Copilot

    func testAskCopilotAppendsUserAndPendingCortexMessage() {
        let model = AppModel()
        model.askCopilot("market read?")

        XCTAssertEqual(model.copilot.count, 2)
        XCTAssertEqual(model.copilot[0].role, .user)
        XCTAssertEqual(model.copilot[0].text, "market read?")
        XCTAssertEqual(model.copilot[1].role, .cortex)
        XCTAssertTrue(model.copilot[1].pending)
        XCTAssertEqual(model.pendingAsk, model.copilot[1].id)
    }

    func testAiAnswerResolvesPendingAsk() throws {
        let model = AppModel()
        model.askCopilot("why did risk tighten?")
        let requestId = try XCTUnwrap(model.pendingAsk)

        model.apply(.aiAnswer(AiAnswer(
            request_id: requestId,
            question: "why did risk tighten?",
            answer: "geo caution rose on the physical-alpha fusion.",
            model: "claude-fable-5",
            ts_ms: 1
        )))

        XCTAssertNil(model.pendingAsk)
        let answer = try XCTUnwrap(model.copilot.last)
        XCTAssertEqual(answer.role, .cortex)
        XCTAssertFalse(answer.pending)
        XCTAssertEqual(answer.text, "geo caution rose on the physical-alpha fusion.")
        XCTAssertEqual(answer.model, "claude-fable-5")
    }

    func testUnsolicitedAiAnswerStillLandsInThread() {
        let model = AppModel()
        model.apply(.aiAnswer(AiAnswer(
            request_id: "orphan-1", question: "q", answer: "a", model: "m", ts_ms: 1
        )))

        XCTAssertEqual(model.copilot.count, 1)
        XCTAssertNil(model.pendingAsk)
        XCTAssertEqual(model.copilot[0].text, "a")
    }

    // MARK: Agent feed

    func testThoughtsArriveNewestFirst() {
        let model = AppModel()
        model.apply(.thought(thought(agent: "sentinel", ts: 1_000)))
        model.apply(.thought(thought(agent: "hawk", ts: 2_000)))

        XCTAssertEqual(model.thoughts.map(\.agent), ["hawk", "sentinel"])
    }

    func testThoughtBufferIsCapped() {
        let model = AppModel()
        for i in 0..<450 {
            model.apply(.thought(thought(agent: "a\(i)", ts: Int64(i))))
        }
        XCTAssertEqual(model.thoughts.count, 400)
        XCTAssertEqual(model.thoughts.first?.ts_ms, 449)
    }

    // MARK: Signals

    func testSignalsArriveNewestFirst() {
        let model = AppModel()
        model.apply(.signal(signal(strategy: "momentum", ts: 1)))
        model.apply(.signal(signal(strategy: "meanrev", ts: 2)))

        XCTAssertEqual(model.signals.map(\.strategy), ["meanrev", "momentum"])
    }

    // MARK: Macro

    func testMacroSnapshotApplied() {
        let model = AppModel()
        XCTAssertNil(model.macro)

        model.apply(.macro(MacroSnapshot(
            yields: ["10y": 4.2],
            spread_2s10s_bps: -12.5,
            spread_3m10s_bps: 40.0,
            curve_regime: "inverted",
            fx: ["EURUSD": 1.0842, "USDJPY": 155.31],
            source: "treasury",
            ts_ms: 1
        )))

        XCTAssertEqual(model.macro?.spread_2s10s_bps, -12.5)
        XCTAssertEqual(model.macro?.curve_regime, "inverted")
        XCTAssertEqual(model.macro?.fx["EURUSD"], 1.0842)
    }

    // MARK: Fixtures

    private func thought(
        agent: String,
        squadron: String = "risk",
        severity: Severity = .info,
        ts: Int64
    ) -> AgentThought {
        AgentThought(
            agent: agent, squadron: squadron, severity: severity,
            text: "test thought", tags: [], confidence: 0.5, symbol: nil, ts_ms: ts
        )
    }

    private func signal(strategy: String, ts: Int64) -> StrategySignal {
        StrategySignal(
            strategy: strategy, symbol: "BTC-USD", direction: 1.0,
            conviction: 0.7, rationale: "test", features: [:], ts_ms: ts
        )
    }
}
