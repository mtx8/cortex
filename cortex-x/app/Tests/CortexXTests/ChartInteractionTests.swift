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
}
