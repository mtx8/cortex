// ChartInteraction contract tests: the zoom-to-default reset used by manual
// interval / weekly picks, and the extended-hours toggle default + its
// survival across a series reset (a mode, not a tool).

import XCTest
@testable import CortexX

final class ChartInteractionTests: XCTestCase {

    // MARK: - Zoom reset (manual interval / weekly switch)

    func testResetZoomToDefaultRestoresDefaultWidth() {
        let interaction = ChartInteraction()
        interaction.barsVisible = 900 // a wide 5y-style window
        interaction.resetZoomToDefault()
        XCTAssertEqual(interaction.barsVisible, ChartMath.defaultVisibleBars, accuracy: 1e-12)
    }

    func testResetZoomToDefaultLeavesFollowAndTogglesAlone() {
        let interaction = ChartInteraction()
        interaction.barsVisible = 40
        interaction.rightOffset = 12
        interaction.showRSI = false
        interaction.resetZoomToDefault()
        XCTAssertEqual(interaction.barsVisible, ChartMath.defaultVisibleBars, accuracy: 1e-12)
        // Only the window width changes — panning + overlay state are untouched.
        XCTAssertEqual(interaction.rightOffset, 12, accuracy: 1e-12)
        XCTAssertFalse(interaction.showRSI)
    }

    func testResetForNewSeriesKeepsBarsVisible() {
        // Range presets set barsVisible via applyRange, then a symbol/interval
        // change funnels through resetForNewSeries — which must NOT clobber the
        // framed window, or 5y / all views would snap back to the default zoom.
        let interaction = ChartInteraction()
        interaction.barsVisible = 720
        interaction.resetForNewSeries()
        XCTAssertEqual(interaction.barsVisible, 720, accuracy: 1e-12)
        XCTAssertTrue(interaction.isFollowing) // but the live edge is re-pinned
    }

    // MARK: - Extended-hours toggle

    func testShowExtendedHoursDefaultsOn() {
        XCTAssertTrue(ChartInteraction().showExtendedHours)
    }

    func testShowExtendedHoursSurvivesSeriesReset() {
        // A mode like the overlay toggles / magnet: switching symbol or
        // interval must not silently re-enable the wash the user turned off.
        let interaction = ChartInteraction()
        interaction.showExtendedHours = false
        interaction.resetForNewSeries()
        XCTAssertFalse(interaction.showExtendedHours)
    }

    // MARK: - Axis timezone + day-boundary labels

    func testExchangeTimeZoneByAssetClass() {
        // Equities read on Eastern exchange time; crypto on UTC (24/7 reference).
        // (macOS reports UTC as the equivalent "GMT" — check the offset, not the id.)
        XCTAssertEqual(ChartMath.exchangeTimeZone(for: "AAPL").identifier, "America/New_York")
        XCTAssertEqual(ChartMath.exchangeTimeZone(for: "SPY").identifier, "America/New_York")
        XCTAssertEqual(ChartMath.exchangeTimeZone(for: "BTC-USD").secondsFromGMT(), 0)
        XCTAssertEqual(ChartMath.exchangeTimeZone(for: "ETH-USD").secondsFromGMT(), 0)
    }

    func testDayKeyDetectsSessionBoundary() {
        let et = ChartMath.exchangeTimeZone(for: "AAPL")
        let base: Int64 = 1_784_985_000_000 // a fixed epoch (ms)
        // Same instant → same key; a full day later → a different, greater key
        // (YYYYMMDD is monotone across month/year rolls too), which is exactly the
        // signal the axis uses to switch to a DATE label at a session boundary.
        XCTAssertEqual(ChartMath.dayKey(base, tz: et), ChartMath.dayKey(base, tz: et))
        XCTAssertNotEqual(ChartMath.dayKey(base, tz: et), ChartMath.dayKey(base + 86_400_000, tz: et))
        XCTAssertLessThan(ChartMath.dayKey(base, tz: et), ChartMath.dayKey(base + 86_400_000, tz: et))
        // The zone is respected: a UTC-vs-ET read of the same instant can differ,
        // and both are valid YYYYMMDD keys.
        XCTAssertGreaterThan(ChartMath.dayKey(base, tz: TimeZone(identifier: "UTC")!), 0)
    }
}
