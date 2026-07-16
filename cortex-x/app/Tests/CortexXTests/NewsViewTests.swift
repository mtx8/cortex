// NEWS: wire-decode tests for the news frame and the snapshot "news" key
// (literal JSON as cortexd emits it), the earnings-imminence helper, the
// AI BRIEF prompt builders, and the AppModel newsBoard / brief-tracking
// state rules.

import XCTest
@testable import CortexX

final class NewsViewTests: XCTestCase {
    // MARK: - Frame decoding

    func testDecodeNewsFrame() throws {
        let json = #"""
        {"type":"news","items":[{"symbol":"NVDA","title":"Blackwell demand outruns supply","source_domain":"example.com","url":"https://example.com/a","tone":-1.5,"ts_ms":1752290000000},{"symbol":null,"title":"Central bank holds rates","source_domain":"example.org","url":"https://example.org/b","tone":1.2,"ts_ms":1752295000000}],"earnings":[{"symbol":"NVDA","last_report":"2026-05-28","next_estimate":"2026-08-27","basis":"estimated from filing cadence (not confirmed)"}],"source":"gdelt 2.0 + sec edgar submissions","ts_ms":1752300000000}
        """#
        guard case .news(let board) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected news frame")
        }
        XCTAssertEqual(board.items.count, 2)
        XCTAssertEqual(board.items[0].symbol, "NVDA")
        XCTAssertEqual(board.items[0].tone, -1.5)
        XCTAssertNil(board.items[1].symbol)
        XCTAssertEqual(board.items[1].source_domain, "example.org")
        XCTAssertEqual(board.earnings.count, 1)
        XCTAssertEqual(board.earnings[0].last_report, "2026-05-28")
        XCTAssertEqual(board.earnings[0].next_estimate, "2026-08-27")
        XCTAssertEqual(board.earnings[0].basis, "estimated from filing cadence (not confirmed)")
        XCTAssertEqual(board.source, "gdelt 2.0 + sec edgar submissions")
        XCTAssertEqual(board.ts_ms, 1_752_300_000_000)
    }

    func testDecodeSnapshotNewsKey() throws {
        let json = #"""
        {"type":"snapshot","data":{"symbols":["BTC-USD"],"bars":{},"positions":[],"thoughts":[],"orders":[],"news":{"items":[],"earnings":[{"symbol":"AAPL","last_report":"2026-05-01","next_estimate":"2026-07-31","basis":"estimated from filing cadence (not confirmed)"}],"source":"gdelt 2.0 + sec edgar submissions","ts_ms":1752300000000}}}
        """#
        guard case .snapshot(let snap) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected snapshot frame")
        }
        let news = try XCTUnwrap(snap.news)
        XCTAssertTrue(news.items.isEmpty)
        XCTAssertEqual(news.earnings.first?.symbol, "AAPL")
    }

    // MARK: - Earnings imminence (within-14-days flag)

    /// Fixed "now": 2026-07-16 13:00 UTC — mid-day, so the helper's
    /// start-of-day normalization is actually exercised.
    private let now = NewsSupport.parseDay("2026-07-16")!.addingTimeInterval(13 * 3_600)

    func testDaysUntil() {
        XCTAssertEqual(NewsSupport.daysUntil("2026-07-16", now: now), 0)
        XCTAssertEqual(NewsSupport.daysUntil("2026-07-17", now: now), 1)
        XCTAssertEqual(NewsSupport.daysUntil("2026-07-30", now: now), 14)
        XCTAssertEqual(NewsSupport.daysUntil("2026-07-31", now: now), 15)
        XCTAssertEqual(NewsSupport.daysUntil("2026-07-15", now: now), -1)
        XCTAssertNil(NewsSupport.daysUntil("not-a-date", now: now))
        XCTAssertNil(NewsSupport.daysUntil("", now: now))
    }

    func testIsImminentWindowBoundaries() {
        XCTAssertTrue(NewsSupport.isImminent("2026-07-16", now: now)) // today
        XCTAssertTrue(NewsSupport.isImminent("2026-07-30", now: now)) // day 14
        XCTAssertFalse(NewsSupport.isImminent("2026-07-31", now: now)) // day 15
        XCTAssertFalse(NewsSupport.isImminent("2026-07-15", now: now)) // passed
        XCTAssertFalse(NewsSupport.isImminent("garbage", now: now)) // malformed
    }

    // MARK: - Earnings ordering

    private func earnings(_ symbol: String, next: String) -> EarningsRow {
        EarningsRow(
            symbol: symbol, last_report: "2026-05-01", next_estimate: next,
            basis: "estimated from filing cadence (not confirmed)"
        )
    }

    func testOrderedEarningsSoonestFirstTiesOnSymbol() {
        let rows = [
            earnings("MSFT", next: "2026-10-01"),
            earnings("NVDA", next: "2026-08-27"),
            earnings("AAPL", next: "2026-08-27"),
        ]
        XCTAssertEqual(
            NewsSupport.orderedEarnings(rows).map(\.symbol),
            ["AAPL", "NVDA", "MSFT"]
        )
    }

    // MARK: - Brief prompt builders

    func testMarketBriefPrompt() {
        let p = NewsSupport.marketBriefPrompt()
        XCTAssertTrue(p.contains("market news"))
        XCTAssertTrue(p.contains("MERIDIAN"))
        XCTAssertTrue(p.contains("DESKS"))
        XCTAssertTrue(p.contains("explicit confidence"))
        XCTAssertTrue(p.contains("what would change your mind"))
    }

    func testSymbolBriefPrompt() {
        let p = NewsSupport.symbolBriefPrompt("NVDA")
        XCTAssertTrue(p.contains("news for NVDA"))
        XCTAssertTrue(p.contains("MERIDIAN"))
        XCTAssertTrue(p.contains("DESKS"))
        XCTAssertTrue(p.contains("explicit confidence"))
        XCTAssertTrue(p.contains("what would change your mind"))
    }
}

// MARK: - AppModel state

@MainActor
final class NewsStateTests: XCTestCase {
    private func board(tsMs: Int64 = 1) -> NewsBoard {
        NewsBoard(
            items: [NewsItem(
                symbol: nil, title: "Central bank holds rates",
                source_domain: "example.com", url: "https://example.com/b",
                tone: 1.2, ts_ms: tsMs
            )],
            earnings: [],
            source: "gdelt 2.0 + sec edgar submissions", ts_ms: tsMs
        )
    }

    func testNewsFrameSetsBoard() {
        let model = AppModel()
        XCTAssertNil(model.newsBoard)
        model.apply(.news(board(tsMs: 7)))
        XCTAssertEqual(model.newsBoard?.ts_ms, 7)
    }

    func testSnapshotNewsPopulatesBoardAndAbsenceKeepsIt() {
        let model = AppModel()
        model.apply(.snapshot(EngineSnapshot(
            symbols: ["BTC-USD"], bars: [:], positions: [], account: nil,
            risk: nil, thoughts: [], orders: [], macro: nil, feeds: nil,
            regimes: nil, geo: nil, scan: nil, news: board(tsMs: 9),
            search_universe: nil
        )))
        XCTAssertEqual(model.newsBoard?.ts_ms, 9)
        // A re-sync snapshot without news must not wipe the board.
        model.apply(.snapshot(EngineSnapshot(
            symbols: ["BTC-USD"], bars: [:], positions: [], account: nil,
            risk: nil, thoughts: [], orders: [], macro: nil, feeds: nil,
            regimes: nil, geo: nil, scan: nil, news: nil, search_universe: nil
        )))
        XCTAssertEqual(model.newsBoard?.ts_ms, 9)
    }

    /// The brief panel tracks its answer by the id askCopilot returns —
    /// the same id must be the pending ask and resolve on the ai_answer.
    func testAskCopilotReturnsTrackedRequestId() {
        let model = AppModel()
        let id = model.askCopilot(NewsSupport.marketBriefPrompt())
        XCTAssertEqual(model.pendingAsk, id)
        let message = model.copilot.last
        XCTAssertEqual(message?.id, id)
        XCTAssertEqual(message?.role, .cortex)
        XCTAssertTrue(message?.pending ?? false)

        model.apply(.aiAnswer(AiAnswer(
            request_id: id, question: "q", answer: "hold; confidence 0.6",
            model: "test-model", ts_ms: 1
        )))
        let answered = model.copilot.first { $0.id == id }
        XCTAssertEqual(answered?.text, "hold; confidence 0.6")
        XCTAssertEqual(answered?.pending, false)
        XCTAssertNil(model.pendingAsk)
    }
}
