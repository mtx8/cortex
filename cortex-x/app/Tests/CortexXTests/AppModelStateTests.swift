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
        // Connected: `requestOptionsChain` deliberately does NOT raise the
        // spinner when the command cannot be delivered (see
        // testChainSpinnerIsNotRaisedForAnUndeliveredRequest).
        let model = connectedModel()
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
        let model = connectedModel()
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

    func testChainSpinnerIsNotRaisedForAnUndeliveredRequest() {
        // OPTIONS used to spin forever: the flag was set unconditionally and
        // cleared only by a matching chain frame, so a command dropped on a dead
        // link left the section permanently "Loading chain for X".
        let model = AppModel() // disconnected
        model.requestOptionsChain(underlying: "AAPL")
        XCTAssertFalse(model.chainLoading, "no spinner for a request that never went out")
        XCTAssertEqual(model.undeliveredCommand?.label, "load AAPL option chain")
    }

    func testSimRunButtonIsNotLatchedByAnUndeliveredRequest() {
        // `simRunning` disables the FOUNDRY Run button, so latching it on a dead
        // link bricked the section for the rest of the session.
        let model = AppModel() // disconnected
        model.runSimulation()
        XCTAssertFalse(model.simRunning)
    }

    func testDisconnectResolvesInFlightSpinners() {
        let model = connectedModel()
        model.requestOptionsChain(underlying: "AAPL")
        XCTAssertTrue(model.chainLoading)
        model.handleStateChange(.disconnected)
        XCTAssertFalse(model.chainLoading)
        XCTAssertNotNil(model.chainError, "the stalled load states its cause")
    }

    /// A model whose engine link actually DELIVERS commands. `handleStateChange`
    /// alone is not enough — it only updates the model's view of the connection,
    /// while delivery is decided by the client's own socket state.
    private func connectedModel() -> AppModel {
        let client = EngineClient()
        client.sendInterceptor = { _ in true }
        let model = AppModel(client: client)
        model.handleStateChange(.connected)
        return model
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

    private func d1Bar(
        symbol: String, tsOpenMs: Int64, close: Double = 100, complete: Bool = true
    ) -> Bar {
        Bar(
            symbol: symbol, interval: .d1, ts_open_ms: tsOpenMs,
            open: 100, high: 101, low: 99, close: close,
            volume: 1_000, trade_count: 10, vwap: close, complete: complete
        )
    }

    private func tick(_ symbol: String, price: Double, tsMs: Int64 = 0) -> Tick {
        Tick(symbol: symbol, ts_ms: tsMs, price: price, size: 0, aggressor: nil, venue: .cboe)
    }

    /// Epoch ms for an ISO-8601 UTC instant — session fixtures stay readable.
    private func ts(_ iso: String) throws -> Int64 {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: iso), "bad ISO fixture")
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    // MARK: - Session-aware change % (equities)

    func testPriorSessionCloseSkipsTodayIncompleteAndNaN() throws {
        // "Now" is 08:00 ET premarket on July 15 (EDT).
        let now = try ts("2026-07-15T12:00:00Z")
        let bars = [
            d1Bar(symbol: "AAPL", tsOpenMs: try ts("2026-07-10T00:00:00Z"), close: 90),
            d1Bar(symbol: "AAPL", tsOpenMs: try ts("2026-07-13T00:00:00Z"), close: .nan),
            d1Bar(
                symbol: "AAPL", tsOpenMs: try ts("2026-07-14T00:00:00Z"),
                close: 100, complete: false
            ),
            d1Bar(symbol: "AAPL", tsOpenMs: try ts("2026-07-15T00:00:00Z"), close: 110),
        ]
        // Today's row never counts as "prior"; the NaN and incomplete rows
        // are skipped; the newest usable prior close wins.
        XCTAssertEqual(AppModel.priorSessionClose(d1: bars, nowMs: now), 90)
        XCTAssertNil(AppModel.priorSessionClose(d1: [], nowMs: now))
        XCTAssertNil(AppModel.priorSessionClose(
            d1: [d1Bar(symbol: "AAPL", tsOpenMs: try ts("2026-07-15T00:00:00Z"), close: 110)],
            nowMs: now
        ))
    }

    func testPriorSessionCloseEasternEveningSeam() throws {
        // 01:00 UTC July 16 = 21:00 ET July 15: after-hours still belongs
        // to the July 15 session, so its D1 row is "today", not prior.
        let bars = [
            d1Bar(symbol: "AAPL", tsOpenMs: try ts("2026-07-14T00:00:00Z"), close: 100),
            d1Bar(symbol: "AAPL", tsOpenMs: try ts("2026-07-15T00:00:00Z"), close: 110),
        ]
        XCTAssertEqual(
            AppModel.priorSessionClose(d1: bars, nowMs: try ts("2026-07-16T01:00:00Z")), 100
        )
        // Next morning's premarket rolls the reference to July 15's close.
        XCTAssertEqual(
            AppModel.priorSessionClose(d1: bars, nowMs: try ts("2026-07-16T12:00:00Z")), 110
        )
    }

    func testEquityPremarketChangeReadsPriorSessionClose() throws {
        let model = AppModel()
        let now = try ts("2026-07-15T12:00:00Z") // 08:00 ET premarket
        model.apply(.history(HistorySlice(
            symbol: "AAPL", interval: .d1,
            bars: [
                d1Bar(symbol: "AAPL", tsOpenMs: try ts("2026-07-13T00:00:00Z"), close: 95),
                d1Bar(symbol: "AAPL", tsOpenMs: try ts("2026-07-14T00:00:00Z"), close: 100),
            ],
            source: "test", ts_ms: now
        )))
        model.apply(.tick(tick("AAPL", price: 103, tsMs: now)))
        // +3% against the prior session's RTH close, not tick drift.
        let pct = try XCTUnwrap(model.sessionChangePct("AAPL", nowMs: now))
        XCTAssertEqual(pct, 3.0, accuracy: 1e-9)
    }

    func testEquityChangeIgnoresSameDayD1Row() throws {
        // Today's D1 row already landed (post-close backfill): reading
        // against it would collapse the change to ~0%. sessionOpen (set to
        // 110 by the slice) would too — the prior close must win.
        let model = AppModel()
        let now = try ts("2026-07-15T21:00:00Z") // 17:00 ET after-hours
        model.apply(.history(HistorySlice(
            symbol: "AAPL", interval: .d1,
            bars: [
                d1Bar(symbol: "AAPL", tsOpenMs: try ts("2026-07-14T00:00:00Z"), close: 100),
                d1Bar(symbol: "AAPL", tsOpenMs: try ts("2026-07-15T00:00:00Z"), close: 110),
            ],
            source: "test", ts_ms: now
        )))
        model.apply(.tick(tick("AAPL", price: 110, tsMs: now)))
        let pct = try XCTUnwrap(model.sessionChangePct("AAPL", nowMs: now))
        XCTAssertEqual(pct, 10.0, accuracy: 1e-9)
    }

    func testSessionChangeFallbackWithoutPriorClose() throws {
        // Crypto never reads the equity path; an equity with no D1 history
        // keeps the rolling sessionOpen reference.
        let model = AppModel()
        model.apply(.tick(tick("BTC-USD", price: 100)))
        model.apply(.tick(tick("BTC-USD", price: 105)))
        XCTAssertEqual(try XCTUnwrap(model.sessionChangePct("BTC-USD")), 5.0, accuracy: 1e-9)
        model.apply(.tick(tick("TSM", price: 200)))
        model.apply(.tick(tick("TSM", price: 202)))
        XCTAssertEqual(try XCTUnwrap(model.sessionChangePct("TSM")), 1.0, accuracy: 1e-9)
    }
}
