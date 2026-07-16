// AppModel frame-application rules: options-chain frame filtering (the
// engine republishes chains for ALL equities — only the requested
// underlying may replace what the operator is viewing) and snapshot
// selection keeping (mid-session re-syncs must never yank a universe or
// ad-hoc selection away).

import XCTest
@testable import CortexX

@MainActor
final class AppModelStateTests: XCTestCase {
    /// Fixed "now" so fixtures stay pure math.
    private let nowMs: Int64 = 1_760_000_000_000
    private let dayMs: Int64 = 86_400_000

    // MARK: - Options-chain frame filtering

    func testRequestedChainLandsAndClearsLoading() {
        let model = AppModel()
        model.requestOptionsChain(underlying: "AAPL")
        XCTAssertTrue(model.chainLoading)
        model.apply(.optionsChain(chain("AAPL")))
        XCTAssertEqual(model.optionsChain?.underlying, "AAPL")
        XCTAssertFalse(model.chainLoading)
    }

    func testBroadcastChainNeverClobbersViewedChain() {
        let model = AppModel()
        model.requestOptionsChain(underlying: "AAPL")
        model.apply(.optionsChain(chain("AAPL")))
        // Periodic engine republish for another equity: ignored.
        model.apply(.optionsChain(chain("MSFT")))
        XCTAssertEqual(model.optionsChain?.underlying, "AAPL")
    }

    func testBroadcastChainFillsEmptySlot() {
        // Nothing requested, nothing loaded — an unsolicited chain is
        // better than an empty pane.
        let model = AppModel()
        model.apply(.optionsChain(chain("MSFT")))
        XCTAssertEqual(model.optionsChain?.underlying, "MSFT")
    }

    func testStaleChainNeitherClearsLoadingNorPreemptsNewRequest() {
        let model = AppModel()
        model.requestOptionsChain(underlying: "AAPL")
        model.apply(.optionsChain(chain("AAPL")))
        model.requestOptionsChain(underlying: "MSFT")
        XCTAssertTrue(model.chainLoading)
        // A stale AAPL rebroadcast while MSFT is in flight: ignored.
        model.apply(.optionsChain(chain("AAPL")))
        XCTAssertTrue(model.chainLoading)
        XCTAssertEqual(model.optionsChain?.underlying, "AAPL")
        model.apply(.optionsChain(chain("MSFT")))
        XCTAssertEqual(model.optionsChain?.underlying, "MSFT")
        XCTAssertFalse(model.chainLoading)
    }

    // MARK: - Snapshot selection keeping

    func testSnapshotResetsSelectionWhenModelHasNothing() {
        let model = AppModel()
        model.selectedSymbol = "XYZ"
        model.apply(.snapshot(snapshot(symbols: ["BTC-USD", "AAPL"])))
        XCTAssertEqual(model.selectedSymbol, "BTC-USD")
    }

    func testSnapshotKeepsWatchlistedSelection() {
        let model = AppModel()
        model.selectedSymbol = "AAPL"
        model.apply(.snapshot(snapshot(symbols: ["BTC-USD", "AAPL"])))
        XCTAssertEqual(model.selectedSymbol, "AAPL")
    }

    func testSnapshotKeepsUniverseSelection() {
        // Universe symbols never sit in `symbols` — the snapshot's own
        // search_universe must vouch for them.
        let model = AppModel()
        model.selectedSymbol = "TSM"
        model.apply(.snapshot(snapshot(symbols: ["BTC-USD"], universe: ["TSM"])))
        XCTAssertEqual(model.selectedSymbol, "TSM")
    }

    func testResyncSnapshotKeepsAdHocSelectionWithBars() {
        // Ad-hoc searched ticker: D1 history landed on demand, then a
        // mid-session re-sync snapshot (hello+20s / ensureDepth) arrives
        // without it — the selection must not be yanked away.
        let model = AppModel()
        model.apply(.history(HistorySlice(
            symbol: "IONQ", interval: .d1,
            bars: [d1Bar(symbol: "IONQ", tsOpenMs: nowMs - dayMs)],
            source: "test", ts_ms: nowMs
        )))
        model.selectedSymbol = "IONQ"
        model.apply(.snapshot(snapshot(symbols: ["BTC-USD"])))
        XCTAssertEqual(model.selectedSymbol, "IONQ")
    }

    // MARK: - Copilot ask lifecycle

    func testGapFrameFailsPendingAskSoAskSurfacesRearm() {
        // AiAnswer is not in the engine's critical set: under backpressure
        // it is dropped and a gap frame arrives instead. The pending ask
        // must fail, not disable every ASK surface for the session.
        let model = AppModel()
        let id = model.askCopilot("what changed?")
        XCTAssertEqual(model.pendingAsk, id)
        model.apply(.gap(dropped: 3))
        XCTAssertNil(model.pendingAsk)
        let bubble = model.copilot.first { $0.id == id }
        XCTAssertEqual(bubble?.pending, false)
        XCTAssertEqual(bubble?.text, "answer lost — ask again")
    }

    func testErrorFrameFailsPendingAsk() {
        let model = AppModel()
        let id = model.askCopilot("what changed?")
        model.apply(.error(detail: "boom"))
        XCTAssertNil(model.pendingAsk)
        XCTAssertEqual(model.copilot.first { $0.id == id }?.pending, false)
    }

    func testGapWithoutPendingAskTouchesNothing() {
        let model = AppModel()
        let id = model.askCopilot("what changed?")
        model.apply(.aiAnswer(AiAnswer(
            request_id: id, question: "what changed?", answer: "answered",
            model: "m", ts_ms: nowMs
        )))
        model.apply(.gap(dropped: 1))
        XCTAssertEqual(model.copilot.first { $0.id == id }?.text, "answered")
    }

    func testDisconnectFailsPendingAsk() {
        // Reconnects never replay an in-flight ask — the id dies with the
        // connection, so the pending state must die with it too.
        let model = AppModel()
        model.handleStateChange(.connected)
        let id = model.askCopilot("what changed?")
        model.handleStateChange(.disconnected)
        XCTAssertNil(model.pendingAsk)
        XCTAssertEqual(model.copilot.first { $0.id == id }?.pending, false)
        XCTAssertEqual(model.connection, .disconnected)
    }

    func testBackToBackAskIdsNeverCollide() {
        // Millisecond wall-clock alone collides when two asks dispatch in
        // the same run-loop drain (double-click before .disabled lands).
        let model = AppModel()
        let a = model.askCopilot("one")
        let b = model.askCopilot("two")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(Set(model.copilot.map(\.id)).count, model.copilot.count)
    }

    // MARK: - History miss caching

    func testEmptyHistoryMissBlocksRerequestForever() {
        // Dead tickers ("NVDAA") answer with an empty slice. The first
        // request records the miss; every later ensureSymbolData (list
        // switches, rail re-appearance) must stay silent — each re-request
        // was a fresh Yahoo egress hit.
        let model = AppModel()
        XCTAssertTrue(model.ensureSymbolData("NVDAA"))
        model.apply(.history(HistorySlice(
            symbol: "NVDAA", interval: .d1, bars: [], source: "test", ts_ms: nowMs
        )))
        XCTAssertFalse(model.ensureSymbolData("NVDAA"))
    }

    func testHistoryMissClearsWhenDataLaterArrives() {
        let model = AppModel()
        model.apply(.history(HistorySlice(
            symbol: "IONQ", interval: .d1, bars: [], source: "test", ts_ms: nowMs
        )))
        XCTAssertFalse(model.ensureSymbolData("IONQ"))
        model.apply(.history(HistorySlice(
            symbol: "IONQ", interval: .d1,
            bars: [d1Bar(symbol: "IONQ", tsOpenMs: nowMs - dayMs)],
            source: "test", ts_ms: nowMs
        )))
        XCTAssertTrue(model.historyMisses.isEmpty)
    }

    func testMissForOneSymbolNeverBlocksAnother() {
        let model = AppModel()
        model.apply(.history(HistorySlice(
            symbol: "NVDAA", interval: .d1, bars: [], source: "test", ts_ms: nowMs
        )))
        XCTAssertTrue(model.ensureSymbolData("TSM"))
    }

    // MARK: - Type-to-add ticker validation

    func testTickerInputValidation() {
        XCTAssertTrue(Watchlist.isValidTickerInput("NVDA"))
        XCTAssertTrue(Watchlist.isValidTickerInput("BRK.B"))
        XCTAssertTrue(Watchlist.isValidTickerInput("BTC-USD"))
        XCTAssertFalse(Watchlist.isValidTickerInput("FOO BAR"))
        XCTAssertFalse(Watchlist.isValidTickerInput(""))
        XCTAssertFalse(Watchlist.isValidTickerInput("WAYTOOLONGTICKER"))
        XCTAssertFalse(Watchlist.isValidTickerInput("nvda"))
    }

    // MARK: - Fixtures

    private func chain(_ underlying: String) -> OptionsChain {
        OptionsChain(
            underlying: underlying, underlying_px: 100,
            expirations: ["2026-08-21"], expiry: "2026-08-21",
            contracts: [], source: "test", as_of: nil, ts_ms: nowMs
        )
    }

    private func snapshot(symbols: [String], universe: [String]? = nil) -> EngineSnapshot {
        EngineSnapshot(
            symbols: symbols, bars: [:], positions: [], account: nil,
            risk: nil, thoughts: [], orders: [], macro: nil, feeds: nil,
            regimes: nil, geo: nil, scan: nil, news: nil, search_universe: universe
        )
    }

    private func d1Bar(symbol: String, tsOpenMs: Int64) -> Bar {
        Bar(
            symbol: symbol, interval: .d1, ts_open_ms: tsOpenMs,
            open: 100, high: 101, low: 99, close: 100,
            volume: 1_000, trade_count: 10, vwap: 100, complete: true
        )
    }
}
