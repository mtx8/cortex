// Scanner v2 support tests: ScanFilter matching + AND-combination + JSON
// serialization, saved-screen UserDefaults roundtrip, flag-transition alert
// accumulation (order / dedupe / cap, plus the AppModel wire path), the
// news-glyph matcher window, and the new optional scan wire fields.

import XCTest
@testable import CortexX

@MainActor
final class ScannerSupportTests: XCTestCase {
    /// Fixed "now" so fixtures stay pure math.
    private let nowMs: Int64 = 1_760_000_000_000
    private let hourMs: Int64 = 3_600_000

    // MARK: - Row factory (the ScannerViewTests pattern)

    private func row(
        _ symbol: String,
        composite: Double = 50,
        momentum: Double = 50,
        rsi: Double? = 50,
        ret1w: Double? = nil,
        flags: [String] = [],
        regime: RegimeState? = nil
    ) -> ScanRow {
        ScanRow(
            symbol: symbol, asset_class: symbol.contains("-") ? "crypto" : "equity",
            composite: composite, momentum: momentum, trend: 50, breakout: 50,
            meanrev: 50, vol_state: 50, rsi_14: rsi, zscore_20: nil,
            kalman_tstat: nil, ret_1w: ret1w, ret_1m: nil, ret_3m: nil,
            dist_52w_high: nil, vol_surge: nil, regime: regime, flags: flags,
            last_close: 100
        )
    }

    private func alert(_ symbol: String, _ flag: String, _ tsMs: Int64) -> ScanAlert {
        ScanAlert(symbol: symbol, flag: flag, ts_ms: tsMs)
    }

    // MARK: - ScanFilter matching

    func testFilterGteAndLteAreInclusive() {
        let filter = ScanFilter(column: .composite, op: .gte, value: 50)
        XCTAssertTrue(filter.matches(row("AT", composite: 50)))
        XCTAssertTrue(filter.matches(row("HI", composite: 51)))
        XCTAssertFalse(filter.matches(row("LO", composite: 49.9)))

        let lte = ScanFilter(column: .composite, op: .lte, value: 50)
        XCTAssertTrue(lte.matches(row("AT", composite: 50)))
        XCTAssertTrue(lte.matches(row("LO", composite: 10)))
        XCTAssertFalse(lte.matches(row("HI", composite: 50.1)))
    }

    func testFilterNilReadingNeverMatches() {
        // Absent data never sneaks through a screen — in either direction.
        let gte = ScanFilter(column: .rsi, op: .gte, value: 0)
        let lte = ScanFilter(column: .rsi, op: .lte, value: 100)
        XCTAssertFalse(gte.matches(row("NIL", rsi: nil)))
        XCTAssertFalse(lte.matches(row("NIL", rsi: nil)))
        XCTAssertTrue(gte.matches(row("OK", rsi: 50)))
    }

    func testFilterIsNaNSafe() {
        // NaN threshold matches nothing; NaN reading matches nothing.
        let nanValue = ScanFilter(column: .composite, op: .gte, value: .nan)
        XCTAssertFalse(nanValue.matches(row("A", composite: 90)))
        let filter = ScanFilter(column: .rsi, op: .lte, value: 100)
        XCTAssertFalse(filter.matches(row("NAN", rsi: .nan)))
    }

    func testFilterApplyAndCombines() {
        let rows = [
            row("BOTH", composite: 80, momentum: 90),
            row("ONE", composite: 80, momentum: 10),
            row("NONE", composite: 10, momentum: 10),
        ]
        let filters = [
            ScanFilter(column: .composite, op: .gte, value: 70),
            ScanFilter(column: .momentum, op: .gte, value: 70),
        ]
        XCTAssertEqual(ScanFilter.apply(filters, to: rows).map(\.symbol), ["BOTH"])
        // No filters = identity, order preserved.
        XCTAssertEqual(ScanFilter.apply([], to: rows).map(\.symbol), ["BOTH", "ONE", "NONE"])
    }

    func testFilterFieldsAreNumericColumnsOnly() {
        XCTAssertFalse(ScanFilter.fields.contains(.symbol))
        XCTAssertFalse(ScanFilter.fields.contains(.regime))
        XCTAssertFalse(ScanFilter.fields.contains(.flags))
        XCTAssertTrue(ScanFilter.fields.contains(.composite))
        XCTAssertTrue(ScanFilter.fields.contains(.rsi))
        XCTAssertEqual(ScanFilter.fields.count, ScanColumn.allCases.count - 3)
    }

    func testFilterJSONRoundtrip() throws {
        let filters = [
            ScanFilter(column: .rsi, op: .lte, value: 30),
            ScanFilter(column: .ret1m, op: .gte, value: 0.05),
        ]
        let data = try JSONEncoder().encode(filters)
        let back = try JSONDecoder().decode([ScanFilter].self, from: data)
        XCTAssertEqual(back, filters)
    }

    func testDisabledFilterNeverCullsRows() {
        // The reported bug: ADD FILTER inserted a live composite>=50 row that
        // dropped half the board before configuration. A disabled filter must
        // be inert — identity, exactly like having no filters.
        let rows = [
            row("HI", composite: 80, momentum: 90),
            row("LO", composite: 10, momentum: 10),
        ]
        let draft = ScanFilter(column: .composite, op: .gte, value: 50, enabled: false)
        XCTAssertEqual(ScanFilter.apply([draft], to: rows).map(\.symbol), ["HI", "LO"])
        // Once enabled it culls; a disabled filter mixed with an enabled one
        // contributes nothing.
        let live = ScanFilter(column: .composite, op: .gte, value: 50, enabled: true)
        XCTAssertEqual(ScanFilter.apply([live, draft], to: rows).map(\.symbol), ["HI"])
    }

    func testFilterDecodesLegacyJSONWithoutEnabledAsEnabled() throws {
        // Screens saved before `enabled` existed must still load — a missing key
        // defaults to enabled, not a decode failure that drops the whole blob.
        let legacy = #"{"id":"\#(UUID().uuidString)","column":"rsi","op":"lte","value":30}"#
        let f = try JSONDecoder().decode(ScanFilter.self, from: Data(legacy.utf8))
        XCTAssertTrue(f.enabled)
        XCTAssertEqual(f.column, .rsi)
        XCTAssertEqual(f.value, 30)
    }

    func testSavedScreenRoundTripsSummarySort() {
        let (defaults, store) = makeStore()
        let ss = ScanSummary.Sort(column: .change, ascending: false)
        store.save(name: "movers", preset: .all, filters: [], sort: nil, summarySort: ss)
        // Persists through a fresh store (reload from the same defaults).
        let reloaded = ScreenStore(defaults: defaults).screens
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded[0].summarySort, ss)
        // Legacy screens (no summarySort key) still decode with nil.
        XCTAssertNil(SavedScreen(name: "x", preset: .all, filters: [], sort: nil).summarySort)
    }

    // MARK: - Saved screens

    private static let suiteName = "cortexx.tests.scanner.screens"

    /// Fresh store over a wiped, isolated UserDefaults suite.
    private func makeStore() -> (defaults: UserDefaults, store: ScreenStore) {
        let defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        return (defaults, ScreenStore(defaults: defaults))
    }

    func testSavedScreenRoundtrip() {
        let (defaults, store) = makeStore()
        let filters = [ScanFilter(column: .momentum, op: .gte, value: 80)]
        let sort = ScanSort(column: .ret1w, ascending: false)
        let saved = store.save(
            name: "  hot momentum  ", preset: .topMomentum, filters: filters, sort: sort
        )
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.name, "hot momentum") // trimmed

        // A fresh store over the same suite reloads the whole posture.
        let reloaded = ScreenStore(defaults: defaults)
        XCTAssertEqual(reloaded.screens.count, 1)
        let screen = reloaded.screens[0]
        XCTAssertEqual(screen.id, saved?.id)
        XCTAssertEqual(screen.name, "hot momentum")
        XCTAssertEqual(screen.preset, .topMomentum)
        XCTAssertEqual(screen.filters, filters)
        XCTAssertEqual(screen.sort, sort)
    }

    func testSaveRejectsBlankNames() {
        let (_, store) = makeStore()
        XCTAssertNil(store.save(name: "", preset: .all, filters: [], sort: nil))
        XCTAssertNil(store.save(name: "   ", preset: .all, filters: [], sort: nil))
        XCTAssertTrue(store.screens.isEmpty)
    }

    func testSaveSameNameReplacesInPlace() {
        let (_, store) = makeStore()
        let first = store.save(name: "swing", preset: .all, filters: [], sort: nil)
        let second = store.save(
            name: "SWING", preset: .oversold,
            filters: [ScanFilter(column: .rsi, op: .lte, value: 30)], sort: nil
        )
        // Case-insensitive replace: still one screen, same id, new posture.
        XCTAssertEqual(store.screens.count, 1)
        XCTAssertEqual(second?.id, first?.id)
        XCTAssertEqual(store.screens[0].name, "SWING")
        XCTAssertEqual(store.screens[0].preset, .oversold)
        XCTAssertEqual(store.screens[0].filters.count, 1)
    }

    func testDeleteScreenPersists() {
        let (defaults, store) = makeStore()
        let a = store.save(name: "a", preset: .all, filters: [], sort: nil)!
        store.save(name: "b", preset: .crypto, filters: [], sort: nil)
        store.delete(id: a.id)
        XCTAssertEqual(store.screens.map(\.name), ["b"])
        XCTAssertEqual(ScreenStore(defaults: defaults).screens.map(\.name), ["b"])
    }

    // MARK: - Alert accumulation

    func testAccumulatePrependsNewestFirst() {
        let feed = [alert("OLD", "volume spike", nowMs - 2 * hourMs)]
        // Incoming arrives unsorted — the merge orders it newest-first.
        let incoming = [
            alert("A", "breakout setup", nowMs - hourMs),
            alert("B", "new 52w high", nowMs),
        ]
        let merged = ScanAlertFeed.accumulate(feed, incoming: incoming)
        XCTAssertEqual(merged.map(\.symbol), ["B", "A", "OLD"])
    }

    func testAccumulateDropsRepublishedDuplicates() {
        let first = ScanAlertFeed.accumulate([], incoming: [alert("A", "volume spike", nowMs)])
        // The engine republishes the same board: identical alerts, no dupes.
        let second = ScanAlertFeed.accumulate(first, incoming: [alert("A", "volume spike", nowMs)])
        XCTAssertEqual(second, first)
        XCTAssertEqual(second.count, 1)
    }

    func testAccumulateCapsDroppingOldest() {
        let feed = (0..<ScanAlertFeed.cap).map { i in
            alert("S\(i)", "flag", nowMs - Int64(i))
        }
        let merged = ScanAlertFeed.accumulate(feed, incoming: [alert("NEW", "flag", nowMs + 1)])
        XCTAssertEqual(merged.count, ScanAlertFeed.cap)
        XCTAssertEqual(merged.first?.symbol, "NEW")
        // The oldest row fell off the end.
        XCTAssertFalse(merged.contains { $0.symbol == "S\(ScanAlertFeed.cap - 1)" })
    }

    func testAppModelAccumulatesScanAlertsAcrossBoards() {
        let model = AppModel()
        model.apply(.scan(board(alerts: [alert("NVDA", "breakout setup", nowMs - hourMs)])))
        XCTAssertEqual(model.scanAlerts.map(\.symbol), ["NVDA"])
        // Republish of the same board: no duplicates.
        model.apply(.scan(board(alerts: [alert("NVDA", "breakout setup", nowMs - hourMs)])))
        XCTAssertEqual(model.scanAlerts.count, 1)
        // Next cycle raises a new flag: it lands newest-first.
        model.apply(.scan(board(alerts: [
            alert("NVDA", "breakout setup", nowMs - hourMs),
            alert("NKE", "oversold bounce", nowMs),
        ])))
        XCTAssertEqual(model.scanAlerts.map(\.symbol), ["NKE", "NVDA"])
        // A board without alerts leaves the accumulated feed intact.
        model.apply(.scan(board(alerts: nil)))
        XCTAssertEqual(model.scanAlerts.count, 2)
    }

    // MARK: - New optional wire fields

    func testDecodeScanFrameWithAlertsAndWeights() throws {
        let json = #"""
        {"type":"scan","rows":[],"source":"cortex scan","ts_ms":1752300000000,"alerts":[{"symbol":"NVDA","flag":"volume spike","ts_ms":1752299000000}],"weights_used":{"momentum":0.35,"trend":0.25}}
        """#
        guard case .scan(let board) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected scan frame")
        }
        XCTAssertEqual(board.alerts?.count, 1)
        XCTAssertEqual(board.alerts?.first?.symbol, "NVDA")
        XCTAssertEqual(board.alerts?.first?.flag, "volume spike")
        XCTAssertEqual(board.alerts?.first?.ts_ms, 1_752_299_000_000)
        XCTAssertEqual(board.weights_used?["momentum"], 0.35)
        XCTAssertEqual(board.weights_used?["trend"], 0.25)
    }

    func testDecodeLegacyScanFrameWithoutNewFields() throws {
        // Older engines omit both fields — they decode nil, never fail.
        let json = #"""
        {"type":"scan","rows":[],"source":"cortex scan","ts_ms":1752300000000}
        """#
        guard case .scan(let board) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected scan frame")
        }
        XCTAssertNil(board.alerts)
        XCTAssertNil(board.weights_used)
    }

    // MARK: - News-glyph matcher

    func testLatestHeadlinesPicksLatestInsideWindow() {
        let items = [
            news("NVDA", "older nvda story", nowMs - 3 * hourMs),
            news("NVDA", "latest nvda story", nowMs - hourMs),
            news("NKE", "nke story", nowMs - 23 * hourMs),
        ]
        let map = ScanNews.latestHeadlines(items, nowMs: nowMs)
        XCTAssertEqual(map["NVDA"], "latest nvda story")
        XCTAssertEqual(map["NKE"], "nke story")
    }

    func testLatestHeadlinesExcludesStaleAndMarketItems() {
        let items = [
            news("NVDA", "stale story", nowMs - ScanNews.windowMs - 1),
            news(nil, "market-wide story", nowMs), // symbol nil never marks a row
        ]
        let map = ScanNews.latestHeadlines(items, nowMs: nowMs)
        XCTAssertTrue(map.isEmpty)
    }

    func testLatestHeadlinesWindowEdgeAndCaseNormalization() {
        let items = [
            news("nvda", "exactly 24h old", nowMs - ScanNews.windowMs), // inclusive edge
        ]
        let map = ScanNews.latestHeadlines(items, nowMs: nowMs)
        XCTAssertEqual(map["NVDA"], "exactly 24h old")
        XCTAssertNil(map["nvda"]) // keys are uppercased for row matching
    }

    // MARK: - Copilot prompts

    func testExplainPromptCarriesRankCompositeAndRaws() {
        let prompt = ScanAI.explainPrompt(
            row: row("NVDA", composite: 91.4, momentum: 96, rsi: 71.2,
                     ret1w: 0.052, flags: ["new 52w high"], regime: .bull),
            rank: 3, of: 42
        )
        XCTAssertTrue(prompt.contains("NVDA ranks 3 of 42"))
        XCTAssertTrue(prompt.contains("composite 91"))
        XCTAssertTrue(prompt.contains("momentum 96"))
        XCTAssertTrue(prompt.contains("rsi 71"))
        XCTAssertTrue(prompt.contains("1w +5.2%"))
        XCTAssertTrue(prompt.contains("regime bull"))
        XCTAssertTrue(prompt.contains("flags: new 52w high"))
        XCTAssertTrue(prompt.contains("actionable in the current regime"))
        // Absent readings are omitted, never serialized as placeholders.
        XCTAssertFalse(prompt.contains("—"))
    }

    func testPicksPromptCapsAtTopTen() {
        let rows = (1...15).map { row("S\($0)", composite: Double(100 - $0)) }
        let prompt = ScanAI.picksPrompt(rows: rows)
        XCTAssertTrue(prompt.contains("Top 10 rows"))
        XCTAssertTrue(prompt.contains("10. S10"))
        XCTAssertFalse(prompt.contains("S11"))
        XCTAssertTrue(prompt.contains("2-3 most actionable"))
        XCTAssertTrue(prompt.contains("confidence"))
        XCTAssertTrue(prompt.contains("risks"))
    }

    // MARK: - Weights disclosure

    func testWeightsSummaryOrdersHeaviestFirstAndSkipsNonFinite() {
        let summary = ScanWeights.summary(["trend": 0.25, "momentum": 0.35, "bad": .nan])
        XCTAssertEqual(summary, "composite weights: momentum 0.35 · trend 0.25")
        XCTAssertNil(ScanWeights.summary(nil))
        XCTAssertNil(ScanWeights.summary([:]))
        XCTAssertNil(ScanWeights.summary(["bad": .infinity * 0])) // NaN-only
    }

    // MARK: - Fixtures

    private func board(alerts: [ScanAlert]?) -> ScanBoard {
        ScanBoard(rows: [], source: "test", ts_ms: nowMs, alerts: alerts, weights_used: nil)
    }

    private func news(_ symbol: String?, _ title: String, _ tsMs: Int64) -> NewsItem {
        NewsItem(
            symbol: symbol, title: title, source_domain: "example.com",
            url: "https://example.com", tone: 0, ts_ms: tsMs
        )
    }
}
