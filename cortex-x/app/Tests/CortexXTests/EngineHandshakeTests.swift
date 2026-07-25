// Engine capability handshake + history request/answer correlation.
//
// Regression cover for the class of bug where the app waits forever on data
// that will never arrive. The engine is deliberately long-lived (it keeps
// trading after the window closes), so a freshly-built app routinely connects
// to a cortexd from an older build. That engine ACCEPTS newer commands — serde
// ignores fields it does not know — and answers them wrongly but plausibly: a
// `get_history` for a 5-minute interval came back as DAILY bars, the app filed
// them under `d1`, the 5-minute series stayed empty, no miss was recorded, and
// the chart showed "waiting for market data" behind a 30s cooldown forever.
//
// Two independent guards are tested here:
//   1. the app knows what the engine can do (capabilities in `hello`), and
//   2. every history answer is matched back to the request it answers.

import XCTest
@testable import CortexX

@MainActor
final class EngineHandshakeTests: XCTestCase {
    private let nowMs: Int64 = 1_760_000_000_000

    /// A current engine: connected, and declaring the interval-aware history
    /// capability.
    private func currentEngine() -> AppModel {
        let model = AppModel()
        model.handleStateChange(.connected)
        model.apply(.hello(
            protocolVersion: 2,
            capabilities: [EngineCapability.historyInterval, EngineCapability.shutdown],
            engineVersion: "0.1.0"
        ))
        return model
    }

    /// An engine from before 2026-07-24: connected, protocol 1, no capability
    /// list at all — exactly what the wire decoder produces for such a build.
    private func staleEngine() -> AppModel {
        let model = AppModel()
        model.handleStateChange(.connected)
        model.apply(.hello(protocolVersion: 1, capabilities: [], engineVersion: ""))
        return model
    }

    // MARK: - Capability detection

    func testCurrentEngineIsNotFlaggedOutdated() {
        let model = currentEngine()
        XCTAssertFalse(model.engineOutdated)
        XCTAssertTrue(model.missingEngineCapabilities.isEmpty)
    }

    func testEngineWithoutIntervalHistoryIsFlaggedOutdated() {
        let model = staleEngine()
        XCTAssertTrue(model.engineOutdated)
        XCTAssertEqual(model.missingEngineCapabilities, [EngineCapability.historyInterval])
    }

    func testOutdatedIsNotClaimedBeforeTheHelloArrives() {
        // The socket reaches `.connected` before the hello frame does. Judging in
        // that window would flash the banner on every connect.
        let model = AppModel()
        model.handleStateChange(.connected)
        XCTAssertFalse(model.engineOutdated, "no verdict before the engine introduces itself")
        model.apply(.hello(protocolVersion: 1, capabilities: [], engineVersion: ""))
        XCTAssertTrue(model.engineOutdated)
    }

    func testDisconnectForgetsTheEnginesCapabilities() {
        // The next connection may be a different engine — the restart path makes
        // that the expected case — so nothing may be inherited across it.
        let model = currentEngine()
        model.handleStateChange(.disconnected)
        XCTAssertTrue(model.engineCapabilities.isEmpty)
        XCTAssertFalse(model.helloReceived)
        model.handleStateChange(.connected)
        XCTAssertFalse(model.engineOutdated, "no stale verdict carried into the new connection")
    }

    func testOutdatedIsNotClaimedWhileDisconnected() {
        // Nothing is known about an engine we cannot reach, so the banner must
        // not appear on a dropped connection.
        let model = staleEngine()
        XCTAssertTrue(model.engineOutdated)
        model.handleStateChange(.disconnected)
        XCTAssertFalse(model.engineOutdated)
    }

    // MARK: - The reported bug

    func testStaleEngineIntradaySwitchDiagnosesInsteadOfWaitingForever() {
        // THE bug: switching to 5m on an equity showed "waiting for market
        // data" indefinitely. Asking a stale engine is worse than useless (it
        // answers d1 and burns an upstream fetch), so no request goes out and
        // the cause is recorded immediately for the chart to state.
        let model = staleEngine()
        XCTAssertFalse(model.ensureIntervalData("AAPL", .m5))
        let reason = model.historyReason("AAPL", .m5)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("out of date") == true, "got: \(reason ?? "nil")")
        XCTAssertFalse(model.historyPending("AAPL", .m5))
    }

    func testStaleEngineStillServesDailyHistory() {
        // Daily is the one interval an old engine answers correctly, so the D1
        // path must stay open — degrade, never block.
        let model = staleEngine()
        XCTAssertTrue(model.ensureIntervalData("AAPL", .d1))
        XCTAssertNil(model.historyReason("AAPL", .d1))
    }

    func testCurrentEngineIntradaySwitchIssuesRequestAndReportsPending() {
        let model = currentEngine()
        XCTAssertTrue(model.ensureIntervalData("AAPL", .m5))
        XCTAssertTrue(model.historyPending("AAPL", .m5))
        // Pending is not a failure: the chart must not claim a cause yet.
        XCTAssertNil(model.historyReason("AAPL", .m5))
    }

    // MARK: - Answer/request correlation

    func testMatchingAnswerResolvesTheRequest() {
        let model = currentEngine()
        model.ensureIntervalData("AAPL", .m5)
        model.apply(.history(HistorySlice(
            symbol: "AAPL", interval: .m5,
            bars: [bar(.m5, tsOpenMs: nowMs)], source: "test", ts_ms: nowMs
        )))
        XCTAssertFalse(model.historyPending("AAPL", .m5))
        XCTAssertNil(model.historyReason("AAPL", .m5))
        XCTAssertEqual(model.bars("AAPL", .m5).count, 1)
    }

    func testAnswerAtAnUnrequestedIntervalStrandsNothingSilently() {
        // The precise silent failure: a NON-EMPTY slice for an interval nobody
        // asked for. It used to satisfy the empty-check, skip the miss set, file
        // under d1, and leave 5m pending until nothing. Now it names the cause.
        let model = currentEngine()
        model.ensureIntervalData("AAPL", .m5)
        model.apply(.history(HistorySlice(
            symbol: "AAPL", interval: .d1,
            bars: [bar(.d1, tsOpenMs: nowMs)], source: "test", ts_ms: nowMs
        )))
        XCTAssertFalse(model.historyPending("AAPL", .m5))
        XCTAssertNotNil(model.historyReason("AAPL", .m5))
        // The daily bars it DID send are still real data — keep them.
        XCTAssertEqual(model.bars("AAPL", .d1).count, 1)
    }

    func testMismatchOnlyStrandsTheSameSymbol() {
        let model = currentEngine()
        model.ensureIntervalData("AAPL", .m5)
        model.ensureIntervalData("NVDA", .m5)
        model.apply(.history(HistorySlice(
            symbol: "AAPL", interval: .d1,
            bars: [bar(.d1, tsOpenMs: nowMs)], source: "test", ts_ms: nowMs
        )))
        XCTAssertNotNil(model.historyReason("AAPL", .m5))
        XCTAssertNil(model.historyReason("NVDA", .m5), "NVDA's request is untouched")
        XCTAssertTrue(model.historyPending("NVDA", .m5))
    }

    func testEmptyAnswerResolvesTheRequestAndRecordsTheMiss() {
        // A genuinely empty answer (dead ticker) is a resolved request, not a
        // stranded one — the existing miss set handles the re-request block.
        let model = currentEngine()
        model.ensureIntervalData("NVDAA", .m5)
        model.apply(.history(HistorySlice(
            symbol: "NVDAA", interval: .m5, bars: [], source: "test", ts_ms: nowMs
        )))
        XCTAssertFalse(model.historyPending("NVDAA", .m5))
        XCTAssertTrue(model.historyMisses.contains(AppModel.historyMissKey("NVDAA", .m5)))
    }

    func testReconnectClearsDiagnosesFromThePreviousEngine() {
        // The restart path replaces the engine, so verdicts earned against the
        // old one must not stick to the new one.
        let model = staleEngine()
        model.ensureIntervalData("AAPL", .m5)
        XCTAssertNotNil(model.historyReason("AAPL", .m5))
        model.apply(.hello(
            protocolVersion: 2,
            capabilities: [EngineCapability.historyInterval],
            engineVersion: "0.1.0"
        ))
        XCTAssertNil(model.historyReason("AAPL", .m5))
        XCTAssertFalse(model.engineOutdated)
        XCTAssertTrue(model.ensureIntervalData("AAPL", .m5), "the new engine gets asked")
    }

    // MARK: - Error frames

    func testEngineErrorFrameIsSurfacedNotSwallowed() {
        // A rejected command used to be folded into the `gap` case and dropped,
        // making an out-of-date engine look like a dead control.
        let model = currentEngine()
        XCTAssertNil(model.lastEngineError)
        model.apply(.error(detail: "bad command"))
        XCTAssertEqual(model.lastEngineError?.detail, "bad command")
    }

    func testGapFrameIsNotReportedAsAnEngineError() {
        // Backpressure is not a refusal; only `error` means the engine said no.
        let model = currentEngine()
        model.apply(.gap(dropped: 12))
        XCTAssertNil(model.lastEngineError)
    }

    // MARK: - Miss expiry

    func testAnEmptyAnswerBlocksRefetchOnlyForTheCooldown() {
        // A miss used to be permanent: the only code that cleared it needed a
        // non-empty answer, and the only code that could ask for one was gated on
        // the miss. One transient empty response bricked the series for the whole
        // session. It is now a cooldown.
        let model = currentEngine()
        model.apply(.history(HistorySlice(
            symbol: "IONQ", interval: .d1, bars: [], source: "test", ts_ms: nowMs
        )), nowMs: nowMs)
        XCTAssertTrue(model.historyMisses.contains(AppModel.historyMissKey("IONQ", .d1)))
        XCTAssertFalse(model.ensureSymbolData("IONQ", nowMs: nowMs), "blocked inside the cooldown")

        let afterTtl = nowMs + AppModel.historyMissTtlMs + 1
        XCTAssertTrue(
            model.ensureSymbolData("IONQ", nowMs: afterTtl),
            "the series is eligible again once the miss expires"
        )
        XCTAssertFalse(
            model.historyMisses.contains(AppModel.historyMissKey("IONQ", .d1)),
            "the expired key is dropped rather than accumulating forever"
        )
    }

    func testExpiredMissAlsoUnblocksTheIntervalPath() {
        let model = currentEngine()
        model.ensureIntervalData("AAPL", .m5, nowMs: nowMs)
        model.apply(.history(HistorySlice(
            symbol: "AAPL", interval: .m5, bars: [], source: "test", ts_ms: nowMs
        )), nowMs: nowMs)
        // Past BOTH the miss TTL and the per-key resync cooldown.
        let afterTtl = nowMs + AppModel.historyMissTtlMs + 1
        XCTAssertTrue(model.ensureIntervalData("AAPL", .m5, nowMs: afterTtl))
    }

    // MARK: - Undelivered commands

    func testCommandOnADeadLinkIsReportedNotSwallowed() {
        // A fresh model has no connection. `send` used to return Void and drop
        // the command silently — so "Engage Kill Switch" looked like it worked
        // while the engine never heard it. The single most dangerous silent
        // failure a trading client can have.
        let model = AppModel()
        XCTAssertFalse(model.engineReachable)
        XCTAssertFalse(model.send(.setKillSwitch(engaged: true, reason: "operator kill")))
        let note = model.undeliveredCommand
        XCTAssertNotNil(note)
        XCTAssertEqual(note?.label, "engage kill switch")
        XCTAssertEqual(note?.reason, "engine not connected")
    }

    func testUndeliveredFlattenNamesTheAction() {
        let model = AppModel()
        XCTAssertFalse(model.send(.flattenAll(reason: "operator")))
        XCTAssertEqual(model.undeliveredCommand?.label, "flatten all positions")
    }

    func testUndeliveredNoticeIsDismissable() {
        let model = AppModel()
        model.send(.flattenAll(reason: "operator"))
        XCTAssertNotNil(model.undeliveredCommand)
        model.clearUndeliveredCommand()
        XCTAssertNil(model.undeliveredCommand)
    }

    func testOperatorLabelsDescribeTheActionNotTheWireTag() {
        XCTAssertEqual(
            Command.placeOrder(
                symbol: "AAPL", side: .buy, qty: 12, orderType: .market,
                limitPx: nil, stopPx: nil
            ).operatorLabel,
            "buy 12 AAPL"
        )
        XCTAssertEqual(
            Command.setKillSwitch(engaged: false, reason: "reset").operatorLabel,
            "disengage kill switch"
        )
        XCTAssertEqual(
            Command.getHistory(symbol: "NVDA", interval: .m5).operatorLabel,
            "load NVDA 5m history"
        )
        XCTAssertEqual(Command.shutdown(reason: "stale").operatorLabel, "restart engine")
    }

    // MARK: - Wire shape

    func testShutdownCommandEncodesToTheEngineContract() throws {
        let data = try Command.shutdown(reason: "stale engine").encoded()
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(obj["cmd"] as? String, "shutdown")
        XCTAssertEqual(obj["reason"] as? String, "stale engine")
    }

    func testHelloDecodesCapabilitiesAndToleratesTheirAbsence() throws {
        let modern = Data(#"{"type":"hello","protocol":2,"capabilities":["history_interval"],"engine_version":"0.1.0"}"#.utf8)
        guard case let .hello(v, caps, version) = try ServerFrame.decode(modern) else {
            return XCTFail("expected hello")
        }
        XCTAssertEqual(v, 2)
        XCTAssertEqual(caps, ["history_interval"])
        XCTAssertEqual(version, "0.1.0")

        // A pre-capability engine must still decode, not fail the handshake.
        let legacy = Data(#"{"type":"hello","protocol":1}"#.utf8)
        guard case let .hello(lv, lcaps, lversion) = try ServerFrame.decode(legacy) else {
            return XCTFail("expected hello")
        }
        XCTAssertEqual(lv, 1)
        XCTAssertTrue(lcaps.isEmpty)
        XCTAssertEqual(lversion, "")
    }

    // MARK: - Fixtures

    private func bar(_ interval: Interval, tsOpenMs: Int64) -> Bar {
        Bar(
            symbol: "AAPL", interval: interval, ts_open_ms: tsOpenMs,
            open: 100, high: 101, low: 99, close: 100,
            volume: 1_000, trade_count: 10, vwap: 100, complete: true
        )
    }
}
