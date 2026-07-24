// Stale-history depth logic: short-series detection against an injected
// clock, and the ensureDepth re-sync rate limit (the engine's 5y daily
// backfill often lands after the connect snapshot, so range presets must
// be able to ask again — but never spam).

import XCTest
@testable import CortexX

@MainActor
final class HistoryDepthTests: XCTestCase {
    /// Fixed "now" so every check runs as pure math.
    private let nowMs: Int64 = 1_760_000_000_000
    private let dayMs: Int64 = 86_400_000
    private let fiveYearsMs: Int64 = 1_826 * 86_400_000

    // MARK: - Short-series detection

    func testEmptySeriesIsShort() {
        XCTAssertTrue(AppModel.isShortSeries([], spanMs: fiveYearsMs, nowMs: nowMs))
    }

    func testSeriesYoungerThanSpanIsShort() {
        // Oldest bar one year back cannot cover a 5y window.
        let series = [d1Bar(tsOpenMs: nowMs - 365 * dayMs)]
        XCTAssertTrue(AppModel.isShortSeries(series, spanMs: fiveYearsMs, nowMs: nowMs))
    }

    func testSeriesCoveringSpanIsNotShort() {
        let series = [d1Bar(tsOpenMs: nowMs - fiveYearsMs - dayMs)]
        XCTAssertFalse(AppModel.isShortSeries(series, spanMs: fiveYearsMs, nowMs: nowMs))
    }

    func testSeriesExactlyAtCutoffIsNotShort() {
        let series = [d1Bar(tsOpenMs: nowMs - fiveYearsMs)]
        XCTAssertFalse(AppModel.isShortSeries(series, spanMs: fiveYearsMs, nowMs: nowMs))
    }

    // MARK: - ensureDepth

    func testEnsureDepthResyncsShortSeries() {
        let model = seededModel(oldestBarMs: nowMs - 200 * dayMs)
        XCTAssertTrue(model.ensureDepth(symbol: "AAPL", spanMs: fiveYearsMs, nowMs: nowMs))
    }

    func testEnsureDepthSkipsDeepSeries() {
        let model = seededModel(oldestBarMs: nowMs - fiveYearsMs - dayMs)
        XCTAssertFalse(model.ensureDepth(symbol: "AAPL", spanMs: fiveYearsMs, nowMs: nowMs))
    }

    func testEnsureDepthRateLimitsWithinCooldown() {
        let model = seededModel(oldestBarMs: nowMs - 200 * dayMs)
        XCTAssertTrue(model.ensureDepth(symbol: "AAPL", spanMs: fiveYearsMs, nowMs: nowMs))
        // Still short ten seconds later — but inside the cooldown nothing
        // more goes out.
        XCTAssertFalse(model.ensureDepth(
            symbol: "AAPL", spanMs: fiveYearsMs, nowMs: nowMs + 10_000
        ))
        // Cooldown elapsed: the re-sync fires again.
        XCTAssertTrue(model.ensureDepth(
            symbol: "AAPL", spanMs: fiveYearsMs,
            nowMs: nowMs + AppModel.resyncCooldownMs
        ))
    }

    func testEnsureDepthSharesSyncCooldownAcrossWatchlistSymbols() {
        let model = watchlistModel(symbols: ["AAPL", "MSFT"], oldestBarMs: nowMs - 200 * dayMs)
        XCTAssertTrue(model.ensureDepth(symbol: "AAPL", spanMs: fiveYearsMs, nowMs: nowMs))
        // A sync refreshes every WATCHLIST symbol, so a second watchlist
        // symbol inside the cooldown rides the first request.
        XCTAssertFalse(model.ensureDepth(
            symbol: "MSFT", spanMs: fiveYearsMs, nowMs: nowMs + 1_000
        ))
    }

    func testEnsureDepthDeepensOffWatchlistSymbolInsideSyncCooldown() {
        let model = watchlistModel(symbols: ["AAPL"], oldestBarMs: nowMs - 200 * dayMs)
        XCTAssertTrue(model.ensureDepth(symbol: "AAPL", spanMs: fiveYearsMs, nowMs: nowMs))
        // The watchlist sync never carries off-watchlist tickers, so their
        // direct getHistory must not be starved by the shared sync cooldown.
        XCTAssertTrue(model.ensureDepth(
            symbol: "TSM", spanMs: fiveYearsMs, nowMs: nowMs + 1_000
        ))
    }

    func testEnsureDepthRateLimitsOffWatchlistHistoryPerSymbol() {
        let model = AppModel() // empty watchlist: everything is off-watchlist
        XCTAssertTrue(model.ensureDepth(symbol: "TSM", spanMs: fiveYearsMs, nowMs: nowMs))
        // Same symbol inside its own cooldown: nothing more goes out.
        XCTAssertFalse(model.ensureDepth(
            symbol: "TSM", spanMs: fiveYearsMs, nowMs: nowMs + 10_000
        ))
        // A DIFFERENT off-watchlist symbol is never blocked by TSM's cooldown.
        XCTAssertTrue(model.ensureDepth(
            symbol: "NVDA", spanMs: fiveYearsMs, nowMs: nowMs + 10_000
        ))
        // TSM's own cooldown elapsed: the fetch fires again.
        XCTAssertTrue(model.ensureDepth(
            symbol: "TSM", spanMs: fiveYearsMs,
            nowMs: nowMs + AppModel.resyncCooldownMs
        ))
    }

    func testEnsureDepthTreatsUnknownSymbolAsShort() {
        // No bars at all (ad-hoc searched ticker) counts as short history.
        let model = AppModel()
        XCTAssertTrue(model.ensureDepth(symbol: "NVDA", spanMs: fiveYearsMs, nowMs: nowMs))
    }

    // MARK: - Fixtures

    /// A model with an engine watchlist, whose AAPL D1 series starts at
    /// `oldestBarMs` — exactly how the connect snapshot lands.
    private func watchlistModel(symbols: [String], oldestBarMs: Int64) -> AppModel {
        let model = AppModel()
        model.apply(.snapshot(EngineSnapshot(
            symbols: symbols,
            bars: ["AAPL": ["d1": [d1Bar(tsOpenMs: oldestBarMs), d1Bar(tsOpenMs: nowMs - dayMs)]]],
            positions: [], account: nil, risk: nil, thoughts: [], orders: [],
            macro: nil, feeds: nil, regimes: nil, geo: nil, scan: nil,
            news: nil, search_universe: nil
        )))
        return model
    }

    /// A model whose AAPL D1 series starts at `oldestBarMs`, seeded through
    /// a history frame — exactly how on-demand backfills land.
    // MARK: - ensureIntervalData (intraday backfill request)

    func testEnsureIntervalDataRequestsThinInterval() {
        // Equity intraday opens empty (no live feed) → a request must go out.
        let model = AppModel()
        XCTAssertTrue(model.ensureIntervalData("TSLA", .m5, nowMs: nowMs))
    }

    func testEnsureIntervalDataSkipsWhenPopulated() {
        let model = AppModel()
        let bars = (0..<40).map { mBar(interval: .m5, tsOpenMs: nowMs - Int64($0) * 300_000) }
        model.apply(.history(HistorySlice(
            symbol: "TSLA", interval: .m5, bars: bars, source: "t", ts_ms: nowMs
        )))
        XCTAssertFalse(model.ensureIntervalData("TSLA", .m5, nowMs: nowMs))
    }

    func testEnsureIntervalDataStopsAfterAMissButIsPerInterval() {
        let model = AppModel()
        // Engine answered empty for TSLA m5 → that (symbol,interval) is missed.
        model.apply(.history(HistorySlice(
            symbol: "TSLA", interval: .m5, bars: [], source: "t", ts_ms: nowMs
        )))
        XCTAssertFalse(model.ensureIntervalData("TSLA", .m5, nowMs: nowMs))
        // A DIFFERENT interval for the same symbol is still eligible — a 1s miss
        // must never block 5m/15m.
        XCTAssertTrue(model.ensureIntervalData("TSLA", .m15, nowMs: nowMs))
    }

    func testEnsureIntervalDataRateLimits() {
        let model = AppModel()
        XCTAssertTrue(model.ensureIntervalData("TSLA", .m5, nowMs: nowMs))
        // Inside the cooldown, a second switch to the same interval is a no-op.
        XCTAssertFalse(model.ensureIntervalData("TSLA", .m5, nowMs: nowMs + 10_000))
        // Cooldown elapsed: eligible again.
        XCTAssertTrue(model.ensureIntervalData("TSLA", .m5, nowMs: nowMs + 40_000))
    }

    func testSelectSymbolWithNoDataLandsOnD1() {
        let model = AppModel()
        model.selectedInterval = .m5 // operator was on an intraday interval
        model.selectSymbol("ZZZZ")   // unknown ticker, no bars on any interval
        XCTAssertEqual(model.selectedSymbol, "ZZZZ")
        // The view lands on D1 explicitly (the deep-backfill target), not left
        // stranded on an empty intraday interval.
        XCTAssertEqual(model.selectedInterval, .d1)
    }

    func testLateHistoryForAnotherIntervalDoesNotYankSelection() {
        let model = AppModel()
        model.selectSymbol("TSLA")     // no data → lands on d1
        model.selectedInterval = .m15  // operator then switches to 15m
        // A late 5m response (an earlier request) arrives populated.
        let m5 = (0..<40).map { mBar(interval: .m5, tsOpenMs: nowMs - Int64($0) * 300_000) }
        model.apply(.history(HistorySlice(
            symbol: "TSLA", interval: .m5, bars: m5, source: "t", ts_ms: nowMs
        )))
        // Not yanked to 5m — the operator's explicit 15m pick stands.
        XCTAssertEqual(model.selectedInterval, .m15)
        // …and the 5m data is still merged (available when they switch back).
        XCTAssertEqual(model.bars("TSLA", .m5).count, 40)
    }

    private func mBar(interval: Interval, tsOpenMs: Int64) -> Bar {
        Bar(
            symbol: "TSLA", interval: interval, ts_open_ms: tsOpenMs,
            open: 378, high: 380, low: 377, close: 379,
            volume: 10_000, trade_count: 50, vwap: 379, complete: true
        )
    }

    private func seededModel(oldestBarMs: Int64) -> AppModel {
        let model = AppModel()
        model.apply(.history(HistorySlice(
            symbol: "AAPL", interval: .d1,
            bars: [d1Bar(tsOpenMs: oldestBarMs), d1Bar(tsOpenMs: nowMs - dayMs)],
            source: "test", ts_ms: nowMs
        )))
        return model
    }

    private func d1Bar(tsOpenMs: Int64) -> Bar {
        Bar(
            symbol: "AAPL", interval: .d1, ts_open_ms: tsOpenMs,
            open: 100, high: 101, low: 99, close: 100,
            volume: 1_000, trade_count: 10, vwap: 100, complete: true
        )
    }
}
