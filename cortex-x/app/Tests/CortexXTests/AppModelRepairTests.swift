// Regressions for four AppModel data-integrity defects:
//
//  - a backpressure `gap` frame was ignored, so a dropped qty→0 `position`
//    frame left a PHANTOM position on screen until the next reconnect;
//  - `applySnapshot` replaced the bar store wholesale, destroying every
//    on-demand series the snapshot does not carry (universe symbols ship
//    D1-only, LOOKUP tickers are not shipped at all);
//  - crypto change % was anchored to whatever price happened to be current at
//    connect and never rolled over to a real session reference;
//  - FILINGS accepted responses by query string but timed them out by seq, so a
//    stale unfiltered pull could overwrite a newer keyword search.

import XCTest
@testable import CortexX

@MainActor
final class AppModelRepairTests: XCTestCase {
    /// Fixed "now" so every fixture stays pure math.
    private let nowMs: Int64 = 1_760_000_000_000
    private let dayMs: Int64 = 86_400_000

    // MARK: - Backpressure gap: resync instead of trusting a lossy view

    func testGapResyncsAndDisclosesThatThePortfolioIsUntrusted() {
        // The engine says "I dropped N non-critical events". Position is one of
        // them, and a closing qty→0 Position is published exactly once — so the
        // app must rebuild rather than keep rendering a view it knows is lossy.
        let (model, link) = deliveringModel()
        model.apply(.position(position("AAPL", qty: 100)))
        XCTAssertEqual(model.positions.count, 1)

        model.apply(.gap(dropped: 7), nowMs: nowMs)

        XCTAssertTrue(model.staleAfterGap, "the panes must disclose the loss")
        XCTAssertEqual(model.droppedEventCount, 7)
        XCTAssertEqual(link.syncCount, 1, "a gap must trigger exactly one resync")
    }

    func testGapBurstIssuesOneResyncPerCooldown() {
        // A lagging client receives gap frames in bursts; a snapshot request per
        // frame would deepen the very backpressure that caused them.
        let (model, link) = deliveringModel()
        model.apply(.gap(dropped: 1), nowMs: nowMs)
        model.apply(.gap(dropped: 2), nowMs: nowMs + 1_000)
        model.apply(.gap(dropped: 3), nowMs: nowMs + 5_000)
        XCTAssertEqual(link.syncCount, 1)
        XCTAssertEqual(model.droppedEventCount, 6, "every drop is still counted")
        // Cooldown elapsed: the next gap earns a fresh rebuild.
        model.apply(.gap(dropped: 1), nowMs: nowMs + AppModel.resyncCooldownMs)
        XCTAssertEqual(link.syncCount, 2)
    }

    func testAnUndeliveredGapResyncIsRetriedByTheNextGap() {
        // The cooldown is stamped only when the sync actually reached the
        // engine, so a sync lost on a dying socket cannot silence the next gap.
        let (model, link) = deliveringModel()
        link.deliver = false
        model.apply(.gap(dropped: 1), nowMs: nowMs)
        XCTAssertTrue(model.staleAfterGap, "data was lost either way")
        XCTAssertEqual(link.syncCount, 1)
        link.deliver = true
        model.apply(.gap(dropped: 1), nowMs: nowMs + 1_000)
        XCTAssertEqual(link.syncCount, 2, "the failed attempt never armed the cooldown")
    }

    func testSnapshotAfterAGapClearsStalenessAndTheClosedPositionVanishes() {
        // The rebuilding snapshot is the whole point of the resync: positions
        // are replaced wholesale, so the phantom disappears with it.
        let (model, _) = deliveringModel()
        model.apply(.position(position("AAPL", qty: 100)))
        model.apply(.gap(dropped: 4), nowMs: nowMs)
        XCTAssertTrue(model.staleAfterGap)

        model.apply(.snapshot(snapshot(symbols: ["AAPL"])), nowMs: nowMs + 100)

        XCTAssertFalse(model.staleAfterGap)
        XCTAssertEqual(model.droppedEventCount, 0)
        XCTAssertTrue(model.positions.isEmpty, "no phantom survives the rebuild")
    }

    func testGapWithoutADropCountStillFlagsStaleness() {
        // Defensive: a gap frame reporting 0 (or a negative, from a malformed
        // payload) still means something was lost.
        let (model, _) = deliveringModel()
        model.apply(.gap(dropped: -3), nowMs: nowMs)
        XCTAssertTrue(model.staleAfterGap)
        XCTAssertEqual(model.droppedEventCount, 0, "a bogus count never goes negative")
    }

    // MARK: - Snapshot merges the bar store instead of clobbering it

    func testSnapshotKeepsOnDemandIntradaySeriesItDoesNotCarry() {
        // Operator picks a UNIVERSE equity and switches to 5m; ensureIntervalData
        // fetches it. The snapshot ships universe symbols D1-ONLY, so replacing
        // wholesale emptied the chart the instant ANY later sync landed.
        let model = AppModel()
        let m5 = (0..<40).map { m5Bar("AAPL", tsOpenMs: nowMs - Int64(39 - $0) * 300_000) }
        model.apply(.history(HistorySlice(
            symbol: "AAPL", interval: .m5, bars: m5, source: "test", ts_ms: nowMs
        )))
        XCTAssertEqual(model.bars("AAPL", .m5).count, 40)

        model.apply(.snapshot(snapshot(
            symbols: ["BTC-USD"], universe: ["AAPL"],
            bars: ["AAPL": ["d1": [d1Bar("AAPL", tsOpenMs: nowMs - dayMs)]]]
        )))

        XCTAssertEqual(model.bars("AAPL", .m5).count, 40, "the 5m series survives")
        XCTAssertEqual(model.bars("AAPL", .d1).count, 1, "and the snapshot's D1 lands")
    }

    func testSnapshotKeepsLookupTickerBarsItOmitsEntirely() {
        // A pure LOOKUP ticker sits in neither the watchlist nor the universe,
        // so the snapshot never mentions it — it used to lose its bars with
        // nothing left to refetch them.
        let model = AppModel()
        model.apply(.history(HistorySlice(
            symbol: "IONQ", interval: .d1,
            bars: [d1Bar("IONQ", tsOpenMs: nowMs - dayMs)], source: "test", ts_ms: nowMs
        )))
        model.apply(.snapshot(snapshot(symbols: ["BTC-USD"])))
        XCTAssertEqual(model.bars("IONQ", .d1).count, 1)
    }

    func testSnapshotEmptySeriesNeverBlanksALoadedOne() {
        // "Absent from this payload" is not "gone" — the same rule the broker
        // posture already follows.
        let model = AppModel()
        let m5 = (0..<40).map { m5Bar("AAPL", tsOpenMs: nowMs - Int64(39 - $0) * 300_000) }
        model.apply(.history(HistorySlice(
            symbol: "AAPL", interval: .m5, bars: m5, source: "test", ts_ms: nowMs
        )))
        model.apply(.snapshot(snapshot(symbols: ["AAPL"], bars: ["AAPL": ["m5": []]])))
        XCTAssertEqual(model.bars("AAPL", .m5).count, 40)
    }

    func testSnapshotStillReplacesTheIntervalsItActuallySupplies() {
        // The merge must not become append-only: a series the snapshot DOES
        // carry is the authority for that (symbol, interval).
        let model = AppModel()
        model.apply(.history(HistorySlice(
            symbol: "AAPL", interval: .d1,
            bars: [
                d1Bar("AAPL", tsOpenMs: nowMs - 2 * dayMs),
                d1Bar("AAPL", tsOpenMs: nowMs - dayMs),
            ],
            source: "test", ts_ms: nowMs
        )))
        XCTAssertEqual(model.bars("AAPL", .d1).count, 2)
        model.apply(.snapshot(snapshot(
            symbols: ["AAPL"],
            bars: ["AAPL": ["d1": [d1Bar("AAPL", tsOpenMs: nowMs - dayMs, close: 42)]]]
        )))
        XCTAssertEqual(model.bars("AAPL", .d1).count, 1)
        XCTAssertEqual(model.bars("AAPL", .d1).last?.close, 42)
    }

    // MARK: - Crypto change % reads a real reference, and rolls over

    func testPriorUtcDayCloseSkipsTodayIncompleteAndNaN() throws {
        let now = try ts("2026-07-15T12:00:00Z")
        let bars = [
            d1Bar("BTC-USD", tsOpenMs: try ts("2026-07-12T00:00:00Z"), close: 88),
            d1Bar("BTC-USD", tsOpenMs: try ts("2026-07-13T00:00:00Z"), close: .nan),
            d1Bar(
                "BTC-USD", tsOpenMs: try ts("2026-07-14T00:00:00Z"),
                close: 100, complete: false
            ),
            d1Bar("BTC-USD", tsOpenMs: try ts("2026-07-15T00:00:00Z"), close: 130),
        ]
        XCTAssertEqual(AppModel.priorUtcDayClose(d1: bars, nowMs: now), 88)
        XCTAssertNil(AppModel.priorUtcDayClose(d1: [], nowMs: now))
    }

    func testCryptoDayBoundaryIsUtcNotEastern() throws {
        // 01:00 UTC July 16 is 21:00 ET July 15. A 24/7 instrument has already
        // rolled into a new day; an equity is still inside the July 15 session.
        let bars = [
            d1Bar("BTC-USD", tsOpenMs: try ts("2026-07-14T00:00:00Z"), close: 100),
            d1Bar("BTC-USD", tsOpenMs: try ts("2026-07-15T00:00:00Z"), close: 110),
        ]
        let now = try ts("2026-07-16T01:00:00Z")
        XCTAssertEqual(AppModel.priorUtcDayClose(d1: bars, nowMs: now), 110)
        XCTAssertEqual(AppModel.priorSessionClose(d1: bars, nowMs: now), 100)
    }

    func testCryptoChangeReadsPriorUtcCloseNotTheConnectPrice() throws {
        // The exact "+0.00% on every fresh connect" bug: the snapshot's newest
        // m1 close IS the current price, so anchoring to it reported no move at
        // all no matter how far BTC had run.
        let model = AppModel()
        let now = try ts("2026-07-15T12:00:00Z")
        model.apply(.snapshot(snapshot(
            symbols: ["BTC-USD"],
            bars: ["BTC-USD": [
                "d1": [
                    d1Bar("BTC-USD", tsOpenMs: try ts("2026-07-14T00:00:00Z"), close: 100),
                    d1Bar(
                        "BTC-USD", tsOpenMs: try ts("2026-07-15T00:00:00Z"),
                        close: 130, complete: false
                    ),
                ],
                "m1": [m1Bar("BTC-USD", tsOpenMs: now - 60_000, close: 130)],
            ]]
        )), nowMs: now)
        model.apply(.tick(tick("BTC-USD", price: 130)), nowMs: now)
        let pct = try XCTUnwrap(model.sessionChangePct("BTC-USD", nowMs: now))
        XCTAssertEqual(pct, 30.0, accuracy: 1e-9)
    }

    func testCryptoFallbackSeedsFromTheDayOpenNotTheNewestClose() throws {
        // No D1 series yet (a fresh engine that has only aggregated intraday
        // bars): the rolling reference must still be an ANCHOR — the open of the
        // oldest bar belonging to the current UTC day — not the latest close.
        let model = AppModel()
        let now = try ts("2026-07-15T12:01:00Z")
        model.apply(.snapshot(snapshot(
            symbols: ["BTC-USD"],
            bars: ["BTC-USD": ["m1": [
                m1Bar(
                    "BTC-USD", tsOpenMs: try ts("2026-07-15T00:00:00Z"),
                    open: 100, close: 101
                ),
                m1Bar("BTC-USD", tsOpenMs: try ts("2026-07-15T12:00:00Z"), close: 130),
            ]]]
        )), nowMs: now)
        model.apply(.tick(tick("BTC-USD", price: 130)), nowMs: now)
        let pct = try XCTUnwrap(model.sessionChangePct("BTC-USD", nowMs: now))
        XCTAssertEqual(pct, 30.0, accuracy: 1e-9)
    }

    func testRollingReferenceRollsOverAtUtcMidnight() throws {
        // With no D1 series the reference is a rolling one — but it must belong
        // to TODAY. It used to be written once and kept for the life of the
        // process, so a three-day-old app reported the change since launch.
        let model = AppModel()
        let evening = try ts("2026-07-15T23:00:00Z")
        let nextDay = try ts("2026-07-16T01:00:00Z")
        model.apply(.tick(tick("BTC-USD", price: 100)), nowMs: evening)
        model.apply(.tick(tick("BTC-USD", price: 120)), nowMs: evening)
        XCTAssertEqual(
            try XCTUnwrap(model.sessionChangePct("BTC-USD", nowMs: evening)),
            20.0, accuracy: 1e-9
        )
        // New UTC day: the reference re-anchors to the first price of that day.
        model.apply(.tick(tick("BTC-USD", price: 120)), nowMs: nextDay)
        XCTAssertEqual(
            try XCTUnwrap(model.sessionChangePct("BTC-USD", nowMs: nextDay)),
            0.0, accuracy: 1e-9
        )
        model.apply(.tick(tick("BTC-USD", price: 132)), nowMs: nextDay)
        XCTAssertEqual(
            try XCTUnwrap(model.sessionChangePct("BTC-USD", nowMs: nextDay)),
            10.0, accuracy: 1e-9
        )
    }

    func testEquityChangeStillReadsThePriorSessionClose() throws {
        // The equity path must be untouched by the crypto reference work.
        let model = AppModel()
        let now = try ts("2026-07-15T12:00:00Z") // 08:00 ET premarket
        model.apply(.history(HistorySlice(
            symbol: "AAPL", interval: .d1,
            bars: [
                d1Bar("AAPL", tsOpenMs: try ts("2026-07-13T00:00:00Z"), close: 95),
                d1Bar("AAPL", tsOpenMs: try ts("2026-07-14T00:00:00Z"), close: 100),
            ],
            source: "test", ts_ms: now
        )), nowMs: now)
        model.apply(.tick(tick("AAPL", price: 103)), nowMs: now)
        XCTAssertEqual(
            try XCTUnwrap(model.sessionChangePct("AAPL", nowMs: now)), 3.0, accuracy: 1e-9
        )
    }

    // MARK: - FILINGS: one identity for acceptance and timeout

    func testKeywordResultSurvivesALateBareSubmissionsAnswer() {
        // The desk's onAppear pull (no keywords) and the operator's keyword
        // submit are separate engine tasks for the SAME query with no ordering
        // guarantee. Query equality alone accepted both, so the slow unfiltered
        // 200-row answer silently replaced the keyword results being read.
        let model = AppModel()
        model.requestFilings(query: "AAPL", text: "")
        model.requestFilings(query: "AAPL", text: "material weakness")

        model.apply(.filings(report("AAPL", name: "Apple full-text", fullText: true)))
        XCTAssertEqual(model.filingsReport?.name, "Apple full-text")
        XCTAssertFalse(model.filingsLoading)

        // The superseded submissions pull lands three seconds later.
        model.apply(.filings(report("AAPL", name: "Apple submissions", fullText: false)))
        XCTAssertEqual(
            model.filingsReport?.name, "Apple full-text",
            "the keyword result the operator is reading must stand"
        )
    }

    func testBareAnswerNeitherLandsNorClearsTheKeywordSpinner() {
        // Reverse arrival order: the stale bare answer must be dropped AND leave
        // the spinner up, because the keyword search is still in flight.
        let model = AppModel()
        model.requestFilings(query: "AAPL", text: "")
        model.requestFilings(query: "AAPL", text: "material weakness")

        model.apply(.filings(report("AAPL", name: "Apple submissions", fullText: false)))
        XCTAssertNil(model.filingsReport)
        XCTAssertTrue(model.filingsLoading)

        model.apply(.filings(report("AAPL", name: "Apple full-text", fullText: true)))
        XCTAssertEqual(model.filingsReport?.name, "Apple full-text")
        XCTAssertFalse(model.filingsLoading)
    }

    func testDegradedKeywordPullIsStillAccepted() {
        // The engine degrades a keyword search to the submissions list when efts
        // is unreachable (disclosed in `note`). With no competing bare request
        // outstanding, that answer is the only explanation — accept it, or
        // FILINGS would spin for 20s and show nothing.
        let model = AppModel()
        model.requestFilings(query: "NVDA", text: "supply agreement")
        model.apply(.filings(report(
            "NVDA", name: "NVIDIA Corp", fullText: false,
            note: "full-text search unavailable; showing recent filings"
        )))
        XCTAssertEqual(model.filingsReport?.name, "NVIDIA Corp")
        XCTAssertFalse(model.filingsLoading)
    }

    func testAnswerForAnEntityNobodyAskedAboutIsIgnored() {
        let model = AppModel()
        model.requestFilings(query: "NVDA")
        model.apply(.filings(report("AAPL", name: "Apple Inc.", fullText: false)))
        XCTAssertNil(model.filingsReport)
        XCTAssertTrue(model.filingsLoading, "the NVDA pull is still outstanding")
    }

    func testSupersededQueryAnswerNeitherClobbersNorClearsLoading() {
        // The pre-existing guarantee, kept: two DIFFERENT queries in flight.
        let model = AppModel()
        model.requestFilings(query: "AAPL")
        model.requestFilings(query: "NVDA")
        model.apply(.filings(report("AAPL", name: "Apple Inc.", fullText: false)))
        XCTAssertNil(model.filingsReport)
        XCTAssertTrue(model.filingsLoading)
        model.apply(.filings(report("NVDA", name: "NVIDIA Corp", fullText: false)))
        XCTAssertEqual(model.filingsReport?.name, "NVIDIA Corp")
        XCTAssertFalse(model.filingsLoading)
    }

    func testASecondCopyOfAnAcceptedAnswerCannotReapply() {
        // Each get_filings publishes exactly one event, but a duplicate must not
        // be able to resurrect an entry that was already consumed.
        let model = AppModel()
        model.requestFilings(query: "AAPL")
        model.apply(.filings(report("AAPL", name: "Apple Inc.", fullText: false)))
        model.apply(.filings(report("AAPL", name: "Impostor Inc.", fullText: false)))
        XCTAssertEqual(model.filingsReport?.name, "Apple Inc.")
    }

    // MARK: - Fixtures

    /// A model whose engine link actually delivers commands — `handleStateChange`
    /// alone is not enough, delivery is decided by the client's own socket state.
    private func deliveringModel() -> (AppModel, LinkLog) {
        let log = LinkLog()
        let client = EngineClient()
        client.sendInterceptor = { command in
            log.commands.append(command)
            return log.deliver
        }
        let model = AppModel(client: client)
        model.handleStateChange(.connected)
        return (model, log)
    }

    private func snapshot(
        symbols: [String], universe: [String]? = nil,
        bars: [String: [String: [Bar]]] = [:]
    ) -> EngineSnapshot {
        EngineSnapshot(
            symbols: symbols, bars: bars, positions: [], account: nil,
            risk: nil, thoughts: [], orders: [], macro: nil, feeds: nil,
            regimes: nil, geo: nil, scan: nil, news: nil, search_universe: universe
        )
    }

    private func d1Bar(
        _ symbol: String, tsOpenMs: Int64, close: Double = 100, complete: Bool = true
    ) -> Bar {
        Bar(
            symbol: symbol, interval: .d1, ts_open_ms: tsOpenMs,
            open: 100, high: 101, low: 99, close: close,
            volume: 1_000, trade_count: 10, vwap: close, complete: complete
        )
    }

    private func m1Bar(
        _ symbol: String, tsOpenMs: Int64, open: Double = 100, close: Double = 100
    ) -> Bar {
        Bar(
            symbol: symbol, interval: .m1, ts_open_ms: tsOpenMs,
            open: open, high: max(open, close), low: min(open, close), close: close,
            volume: 10, trade_count: 2, vwap: close, complete: true
        )
    }

    private func m5Bar(_ symbol: String, tsOpenMs: Int64) -> Bar {
        Bar(
            symbol: symbol, interval: .m5, ts_open_ms: tsOpenMs,
            open: 378, high: 380, low: 377, close: 379,
            volume: 10_000, trade_count: 50, vwap: 379, complete: true
        )
    }

    private func tick(_ symbol: String, price: Double) -> Tick {
        Tick(symbol: symbol, ts_ms: 0, price: price, size: 0, aggressor: nil, venue: .cboe)
    }

    private func position(_ symbol: String, qty: Double) -> Position {
        Position(
            symbol: symbol, qty: qty, avg_px: 100, mark_px: 101,
            unrealized_pnl: qty, realized_pnl: 0, ts_ms: 0
        )
    }

    /// A filings answer. `fullText` picks the engine's own source string, which
    /// is the only on-the-wire signal of WHICH endpoint answered.
    private func report(
        _ query: String, name: String, fullText: Bool, note: String = ""
    ) -> FilingsReport {
        FilingsReport(
            query: query, cik: "0000320193", name: name, ticker: query,
            filings: [],
            source: fullText
                ? "SEC EDGAR full-text (efts.sec.gov)"
                : "SEC EDGAR submissions (data.sec.gov)",
            note: note, ts_ms: 1
        )
    }

    /// Epoch ms for an ISO-8601 UTC instant — session fixtures stay readable.
    private func ts(_ iso: String) throws -> Int64 {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: iso), "bad ISO fixture")
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}

/// Records every command the model hands to a link that DELIVERS, and can be
/// flipped mid-test to refuse delivery. Only ever touched from the main actor
/// (the interceptor runs inside `EngineClient.send`), so it needs no isolation
/// of its own.
private final class LinkLog {
    var commands: [Command] = []
    var deliver = true
    var syncCount: Int {
        commands.filter { command in
            if case .sync = command { return true }
            return false
        }.count
    }
}
