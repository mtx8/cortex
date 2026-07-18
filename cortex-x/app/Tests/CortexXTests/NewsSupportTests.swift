// NEWS v2 support tests: the NewsFilter dimensions (source / symbol / keyword
// / tone / time-window) each in isolation and combined, NaN-safety, the
// newest-first bounded render, saved-preset UserDefaults roundtrip, the
// source-badge extraction, the tab default, the new optional source_name wire
// field, and the AppModel AI-brief history.

import XCTest
@testable import CortexX

final class NewsSupportTests: XCTestCase {
    /// Fixed "now" so window fixtures stay pure math.
    private let nowMs: Int64 = 1_760_000_000_000
    private let hourMs: Int64 = 3_600_000

    // MARK: - Item factory

    private func item(
        _ symbol: String?,
        title: String = "headline",
        domain: String = "example.com",
        sourceName: String? = nil,
        tone: Double = 0,
        tsMs: Int64? = nil
    ) -> NewsItem {
        NewsItem(
            symbol: symbol, title: title, source_domain: domain,
            url: "https://\(domain)/a", tone: tone, ts_ms: tsMs ?? nowMs,
            source_name: sourceName
        )
    }

    // MARK: - Tab default

    func testTabDefaultIsFeed() {
        XCTAssertEqual(NewsTab.default, .feed)
        // The segmented order the tab bar renders — FILINGS sits between
        // EARNINGS and AI BRIEF.
        XCTAssertEqual(NewsTab.allCases, [.feed, .earnings, .filings, .brief])
        XCTAssertEqual(NewsTab.filings.title, "filings")
        XCTAssertEqual(NewsTab.brief.title, "ai brief")
    }

    func testFilingsTabSitsBetweenEarningsAndBrief() throws {
        let order = NewsTab.allCases
        let earnings = try XCTUnwrap(order.firstIndex(of: .earnings))
        let filings = try XCTUnwrap(order.firstIndex(of: .filings))
        let brief = try XCTUnwrap(order.firstIndex(of: .brief))
        XCTAssertLessThan(earnings, filings)
        XCTAssertLessThan(filings, brief)
    }

    // MARK: - NewsFilter: empty = identity (except newest-first + cap)

    func testEmptyFilterKeepsEverythingNewestFirst() {
        let items = [
            item("NVDA", tsMs: nowMs - 2 * hourMs),
            item(nil, tsMs: nowMs),
            item("AAPL", tsMs: nowMs - hourMs),
        ]
        let out = NewsFilter().apply(items, nowMs: nowMs)
        XCTAssertEqual(out.count, 3)
        // Newest-first regardless of input order.
        XCTAssertEqual(out.map(\.ts_ms), [nowMs, nowMs - hourMs, nowMs - 2 * hourMs])
    }

    // MARK: - NewsFilter: tone dimension

    func testToneDimension() {
        let items = [
            item("A", tone: 1.5),
            item("B", tone: -2.0),
            item("C", tone: 0),
        ]
        XCTAssertEqual(
            NewsFilter(tone: .positive).apply(items, nowMs: nowMs).map(\.symbol),
            ["A"]
        )
        XCTAssertEqual(
            NewsFilter(tone: .negative).apply(items, nowMs: nowMs).map(\.symbol),
            ["B"]
        )
        XCTAssertEqual(NewsFilter(tone: .all).apply(items, nowMs: nowMs).count, 3)
    }

    func testToneIsNaNSafe() {
        // A non-finite tone is neither positive nor negative.
        let items = [item("NAN", tone: .nan), item("POS", tone: 1)]
        XCTAssertEqual(
            NewsFilter(tone: .positive).apply(items, nowMs: nowMs).map(\.symbol), ["POS"]
        )
        XCTAssertEqual(
            NewsFilter(tone: .negative).apply(items, nowMs: nowMs).map(\.symbol), []
        )
    }

    // MARK: - NewsFilter: time-window dimension

    func testWindowDimension() {
        let items = [
            item("NOW", tsMs: nowMs),
            item("H2", tsMs: nowMs - 2 * hourMs),
            item("H10", tsMs: nowMs - 10 * hourMs),
            item("D2", tsMs: nowMs - 48 * hourMs),
        ]
        XCTAssertEqual(
            NewsFilter(window: .h1).apply(items, nowMs: nowMs).map(\.symbol), ["NOW"]
        )
        XCTAssertEqual(
            NewsFilter(window: .h6).apply(items, nowMs: nowMs).map(\.symbol), ["NOW", "H2"]
        )
        XCTAssertEqual(
            NewsFilter(window: .h24).apply(items, nowMs: nowMs).map(\.symbol),
            ["NOW", "H2", "H10"]
        )
        XCTAssertEqual(NewsFilter(window: .all).apply(items, nowMs: nowMs).count, 4)
    }

    func testWindowLowerEdgeIsInclusive() {
        let items = [item("EDGE", tsMs: nowMs - hourMs)] // exactly 1h old
        XCTAssertEqual(
            NewsFilter(window: .h1).apply(items, nowMs: nowMs).map(\.symbol), ["EDGE"]
        )
    }

    // MARK: - NewsFilter: source dimension

    func testSourceDimensionMultiSelect() {
        let items = [
            item("A", domain: "reuters.com"),
            item("B", domain: "bloomberg.com"),
            item("C", domain: "wsj.com"),
        ]
        let filter = NewsFilter(sources: ["reuters.com", "wsj.com"])
        XCTAssertEqual(filter.apply(items, nowMs: nowMs).map(\.symbol), ["A", "C"])
        // Empty set = all sources.
        XCTAssertEqual(NewsFilter(sources: []).apply(items, nowMs: nowMs).count, 3)
    }

    // MARK: - NewsFilter: symbol dimension

    func testSymbolDimensionExcludesMarketItems() {
        let items = [
            item("NVDA"),
            item("NVDL"),
            item(nil), // market-wide
            item("AAPL"),
        ]
        // Case-insensitive contains; nil-symbol market items drop when a
        // symbol filter is set.
        XCTAssertEqual(
            NewsFilter(symbol: "nvd").apply(items, nowMs: nowMs).map(\.symbol),
            ["NVDA", "NVDL"]
        )
        XCTAssertEqual(NewsFilter(symbol: "  ").apply(items, nowMs: nowMs).count, 4)
    }

    // MARK: - NewsFilter: keyword dimension

    func testKeywordDimensionOverTitle() {
        let items = [
            item("A", title: "Blackwell demand outruns supply"),
            item("B", title: "Central bank holds rates"),
            item("C", title: "supply chain easing"),
        ]
        XCTAssertEqual(
            NewsFilter(keyword: "supply").apply(items, nowMs: nowMs).map(\.symbol),
            ["A", "C"]
        )
        XCTAssertEqual(NewsFilter(keyword: "").apply(items, nowMs: nowMs).count, 3)
    }

    // MARK: - NewsFilter: combined (every dimension AND-combined)

    func testCombinedDimensionsAreAndCombined() {
        let items = [
            item("NVDA", title: "chip supply tightens", domain: "reuters.com",
                 tone: -1.2, tsMs: nowMs - hourMs), // matches all
            item("NVDA", title: "chip supply tightens", domain: "wsj.com",
                 tone: -1.2, tsMs: nowMs - hourMs), // wrong source
            item("NVDA", title: "positive outlook", domain: "reuters.com",
                 tone: 1.0, tsMs: nowMs - hourMs), // wrong tone + keyword
            item("AAPL", title: "chip supply tightens", domain: "reuters.com",
                 tone: -1.2, tsMs: nowMs - hourMs), // wrong symbol
            item("NVDA", title: "chip supply tightens", domain: "reuters.com",
                 tone: -1.2, tsMs: nowMs - 48 * hourMs), // outside window
        ]
        let filter = NewsFilter(
            sources: ["reuters.com"], symbol: "NVDA", keyword: "supply",
            tone: .negative, window: .h6
        )
        let out = filter.apply(items, nowMs: nowMs)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.source_domain, "reuters.com")
    }

    // MARK: - NewsFilter: bounded render

    func testApplyBoundsAndSortsNewestFirst() {
        // 10 items, oldest-first input; cap 3 keeps the 3 newest, newest-first.
        let items = (0..<10).map { item("S\($0)", tsMs: nowMs - Int64(9 - $0) * hourMs) }
        let out = NewsFilter().apply(items, nowMs: nowMs, cap: 3)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.map(\.symbol), ["S9", "S8", "S7"])
    }

    // MARK: - isActive

    func testIsActiveReflectsAnyNarrowing() {
        XCTAssertFalse(NewsFilter().isActive)
        XCTAssertTrue(NewsFilter(sources: ["x.com"]).isActive)
        XCTAssertTrue(NewsFilter(symbol: "NVDA").isActive)
        XCTAssertTrue(NewsFilter(keyword: "rates").isActive)
        XCTAssertTrue(NewsFilter(tone: .positive).isActive)
        XCTAssertTrue(NewsFilter(window: .h24).isActive)
        // Whitespace-only text is not active.
        XCTAssertFalse(NewsFilter(symbol: "  ", keyword: " ").isActive)
    }

    // MARK: - Source-badge extraction

    func testSourceBadgePrefersSourceName() {
        XCTAssertEqual(
            NewsSourceBadge.label(item("A", domain: "reuters.com", sourceName: "Reuters")),
            "Reuters"
        )
        // Blank/whitespace source_name falls back to the domain.
        XCTAssertEqual(
            NewsSourceBadge.label(item("A", domain: "reuters.com", sourceName: "  ")),
            "reuters"
        )
    }

    func testSourceBadgeFromDomain() {
        XCTAssertEqual(NewsSourceBadge.fromDomain("www.reuters.com"), "reuters")
        XCTAssertEqual(NewsSourceBadge.fromDomain("Bloomberg.com"), "bloomberg")
        XCTAssertEqual(NewsSourceBadge.fromDomain("news.example.co.uk"), "example")
        XCTAssertEqual(NewsSourceBadge.fromDomain("localhost"), "localhost")
        XCTAssertEqual(NewsSourceBadge.fromDomain(""), "")
    }

    func testSourcesPresentDistinctSortedByLabel() {
        let items = [
            item("A", domain: "wsj.com", sourceName: "WSJ"),
            item("B", domain: "reuters.com", sourceName: "Reuters"),
            item("C", domain: "reuters.com", sourceName: "Reuters"), // dup domain
            item("D", domain: "apnews.com", sourceName: "AP"),
        ]
        let present = NewsSourceBadge.present(items)
        XCTAssertEqual(present.map(\.domain), ["apnews.com", "reuters.com", "wsj.com"])
        XCTAssertEqual(present.map(\.label), ["AP", "Reuters", "WSJ"])
    }

    // MARK: - source_name wire field (optional, forward-compatible)

    func testNewsItemDecodesSourceNameWhenPresent() throws {
        let json = #"""
        {"symbol":"NVDA","title":"t","source_domain":"reuters.com","url":"https://reuters.com/a","tone":-1.0,"ts_ms":1,"source_name":"Reuters"}
        """#
        let decoded = try JSONDecoder().decode(NewsItem.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.source_name, "Reuters")
    }

    func testNewsItemDecodesWithoutSourceName() throws {
        // Older engines omit source_name — it decodes nil, never fails.
        let json = #"""
        {"symbol":"NVDA","title":"t","source_domain":"reuters.com","url":"https://reuters.com/a","tone":-1.0,"ts_ms":1}
        """#
        let decoded = try JSONDecoder().decode(NewsItem.self, from: Data(json.utf8))
        XCTAssertNil(decoded.source_name)
    }

    // MARK: - Earnings countdown

    func testEarningsCountdown() {
        let now = NewsSupport.parseDay("2026-07-16")!.addingTimeInterval(13 * 3_600)
        XCTAssertEqual(NewsSupport.countdown("2026-07-16", now: now), "today")
        XCTAssertEqual(NewsSupport.countdown("2026-07-17", now: now), "in 1d")
        XCTAssertEqual(NewsSupport.countdown("2026-07-30", now: now), "in 14d")
        XCTAssertEqual(NewsSupport.countdown("2026-07-15", now: now), "passed")
        XCTAssertNil(NewsSupport.countdown("not-a-date", now: now))
    }

    // MARK: - Saved presets (UserDefaults roundtrip)

    private static let suiteName = "cortexx.tests.news.presets"

    @MainActor
    private func makeStore() -> (defaults: UserDefaults, store: NewsPresetStore) {
        let defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        return (defaults, NewsPresetStore(defaults: defaults))
    }

    @MainActor
    func testSavedPresetRoundtrip() {
        let (defaults, store) = makeStore()
        let filter = NewsFilter(
            sources: ["reuters.com", "wsj.com"], symbol: "NVDA",
            keyword: "supply", tone: .negative, window: .h6
        )
        let saved = store.save(name: "  chip risk  ", filter: filter)
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.name, "chip risk") // trimmed

        // A fresh store over the same suite reloads the whole posture.
        let reloaded = NewsPresetStore(defaults: defaults)
        XCTAssertEqual(reloaded.presets.count, 1)
        let preset = reloaded.presets[0]
        XCTAssertEqual(preset.id, saved?.id)
        XCTAssertEqual(preset.name, "chip risk")
        XCTAssertEqual(preset.filter, filter)
    }

    @MainActor
    func testSavePresetRejectsBlankNames() {
        let (_, store) = makeStore()
        XCTAssertNil(store.save(name: "", filter: NewsFilter()))
        XCTAssertNil(store.save(name: "   ", filter: NewsFilter()))
        XCTAssertTrue(store.presets.isEmpty)
    }

    @MainActor
    func testSavePresetSameNameReplacesInPlace() {
        let (_, store) = makeStore()
        let first = store.save(name: "swing", filter: NewsFilter())
        let second = store.save(name: "SWING", filter: NewsFilter(tone: .positive))
        XCTAssertEqual(store.presets.count, 1)
        XCTAssertEqual(second?.id, first?.id)
        XCTAssertEqual(store.presets[0].name, "SWING")
        XCTAssertEqual(store.presets[0].filter.tone, .positive)
    }

    @MainActor
    func testDeletePresetPersists() {
        let (defaults, store) = makeStore()
        let a = store.save(name: "a", filter: NewsFilter())!
        store.save(name: "b", filter: NewsFilter(window: .h24))
        store.delete(id: a.id)
        XCTAssertEqual(store.presets.map(\.name), ["b"])
        XCTAssertEqual(NewsPresetStore(defaults: defaults).presets.map(\.name), ["b"])
    }

    // MARK: - NewsFilter JSON roundtrip (backs the presets)

    func testNewsFilterJSONRoundtrip() throws {
        let filter = NewsFilter(
            sources: ["a.com", "b.com"], symbol: "NVDA", keyword: "supply",
            tone: .negative, window: .h6
        )
        let data = try JSONEncoder().encode(filter)
        let back = try JSONDecoder().decode(NewsFilter.self, from: data)
        XCTAssertEqual(back, filter)
    }
}

// MARK: - AppModel AI-brief history

@MainActor
final class NewsBriefHistoryTests: XCTestCase {
    func testAskNewsBriefRecordsNewestFirstAndResolves() {
        let model = AppModel()
        XCTAssertTrue(model.newsBriefHistory.isEmpty)

        let marketId = model.askNewsBrief(NewsSupport.marketBriefPrompt())
        let symbolId = model.askNewsBrief(NewsSupport.symbolBriefPrompt("NVDA"))

        // Newest-first: the symbol brief leads.
        XCTAssertEqual(model.newsBriefHistory.map(\.requestId), [symbolId, marketId])
        XCTAssertEqual(model.pendingAsk, symbolId)

        // The answer resolves via the shared copilot thread by request id.
        model.apply(.aiAnswer(AiAnswer(
            request_id: marketId, question: "q", answer: "hold; confidence 0.6",
            model: "test-model", ts_ms: 1
        )))
        let answered = model.copilot.first { $0.id == marketId }
        XCTAssertEqual(answered?.text, "hold; confidence 0.6")
        XCTAssertEqual(answered?.pending, false)
        // The history entry still references it.
        XCTAssertTrue(model.newsBriefHistory.contains { $0.requestId == marketId })
    }

    func testAskNewsBriefHistoryCapsAtTwenty() {
        let model = AppModel()
        var ids: [String] = []
        for i in 0..<(AppModel.newsBriefHistoryCap + 5) {
            ids.append(model.askNewsBrief("brief \(i)"))
        }
        XCTAssertEqual(model.newsBriefHistory.count, AppModel.newsBriefHistoryCap)
        // The newest survive; the oldest fell off the end.
        XCTAssertEqual(model.newsBriefHistory.first?.requestId, ids.last)
        XCTAssertFalse(model.newsBriefHistory.contains { $0.requestId == ids.first })
    }
}
