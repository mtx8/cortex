// Regression tests for the intel-surface repairs: the heatmap's STRENGTH ramp,
// the COMPANY / FILINGS terminal-failure panes, the per-share money formatter,
// the flat-signal glyph, and MERIDIAN's tone/trend palette. Each test pins a
// defect that was invisible on screen but obvious in a pure function.

import SwiftUI
import XCTest
@testable import CortexX

final class IntelRepairTests: XCTestCase {
    // MARK: - Heatmap STRENGTH ramp (finding 16)

    /// STRENGTH used |composite − 50|, so composite 10 (bottom of the universe)
    /// rendered exactly as brightly as composite 90 (top). The ramp must be
    /// monotonic: weakest faintest, strongest brightest.
    func testStrengthIntensityIsMonotonicNotCentered() {
        let weak = HeatmapView.intensity(mode: .strength, metric: 10)
        let mid = HeatmapView.intensity(mode: .strength, metric: 50)
        let strong = HeatmapView.intensity(mode: .strength, metric: 90)
        XCTAssertLessThan(weak, mid)
        XCTAssertLessThan(mid, strong)
        XCTAssertEqual(weak, 0.10, accuracy: 1e-9)
        XCTAssertEqual(strong, 0.90, accuracy: 1e-9)
        // The old centered form collapsed these two onto the same intensity.
        XCTAssertNotEqual(weak, strong)
    }

    func testStrengthIntensityClampsToUnitRange() {
        XCTAssertEqual(HeatmapView.intensity(mode: .strength, metric: 0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(HeatmapView.intensity(mode: .strength, metric: 100), 1.0, accuracy: 1e-9)
        // Out-of-range composites (never expected, but the engine owns the number).
        XCTAssertEqual(HeatmapView.intensity(mode: .strength, metric: 140), 1.0, accuracy: 1e-9)
        XCTAssertEqual(HeatmapView.intensity(mode: .strength, metric: -20), 0.0, accuracy: 1e-9)
    }

    /// CHANGE keeps abs(): its sign is carried by Theme.up / Theme.down, so only
    /// the magnitude may drive opacity there.
    func testChangeIntensityStillUsesMagnitudeAndCaps() {
        XCTAssertEqual(HeatmapView.intensity(mode: .change, metric: -1.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(HeatmapView.intensity(mode: .change, metric: 1.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(HeatmapView.intensity(mode: .change, metric: 9.0), 1.0, accuracy: 1e-9)
    }

    /// STRENGTH is ember-only (composite is a percentile, not money direction);
    /// CHANGE carries direction in the money palette.
    func testTileToneKeepsPalettesSeparate() {
        XCTAssertEqual(HeatmapView.tileColor(mode: .strength, metric: 90).tone, Theme.ember)
        XCTAssertEqual(HeatmapView.tileColor(mode: .strength, metric: 10).tone, Theme.ember)
        XCTAssertEqual(HeatmapView.tileColor(mode: .change, metric: 2).tone, Theme.up)
        XCTAssertEqual(HeatmapView.tileColor(mode: .change, metric: -2).tone, Theme.down)
        // Flat / unknown change is not a direction.
        XCTAssertEqual(HeatmapView.tileColor(mode: .change, metric: 0).tone, Theme.dim)
        XCTAssertEqual(HeatmapView.tileColor(mode: .change, metric: nil).tone, Theme.dim)
        XCTAssertEqual(HeatmapView.tileColor(mode: .strength, metric: Double.nan).tone, Theme.dim)
    }

    // MARK: - Heatmap sector grouping (finding 21)

    /// The grouping is memoized on the board identity now, so it has to be a pure
    /// function of the rows: sectors alphabetical with "Other" pinned last, rows
    /// symbol-sorted inside each sector.
    func testSectorGroupsAreDeterministicWithOtherLast() {
        let rows = [
            scanRow("MSFT", sector: "Technology"),
            scanRow("XOM", sector: "Energy"),
            scanRow("BTC-USD", sector: nil),
            scanRow("AAPL", sector: "Technology"),
        ]
        let groups = HeatmapView.sectorGroups(rows)
        XCTAssertEqual(groups.map(\.sector), ["Energy", "Technology", "Other"])
        XCTAssertEqual(groups[1].rows.map(\.symbol), ["AAPL", "MSFT"])
        XCTAssertEqual(groups[2].rows.map(\.symbol), ["BTC-USD"])
    }

    /// The memo must turn over exactly once per board publish and never serve a
    /// stale grouping for a different board.
    func testSectorCacheServesMemoUntilBoardIdentityChanges() {
        let cache = HeatSectorCache()
        var builds = 0
        let key = HeatSectorKey(ts: 1, count: 1)
        for _ in 0..<3 {
            _ = cache.groups(for: key) {
                builds += 1
                return HeatmapView.sectorGroups([scanRow("AAPL", sector: "Technology")])
            }
        }
        XCTAssertEqual(builds, 1)
        let next = cache.groups(for: HeatSectorKey(ts: 2, count: 1)) {
            builds += 1
            return HeatmapView.sectorGroups([scanRow("XOM", sector: "Energy")])
        }
        XCTAssertEqual(builds, 2)
        XCTAssertEqual(next.map(\.sector), ["Energy"])
    }

    // MARK: - COMPANY pane resolution (finding 5)

    /// The watchdog clears `companyLoading` but leaves the PREVIOUS company's
    /// profile in `company`. The old `companyLoading || company != nil` branch
    /// therefore showed "assembling intelligence…" forever. A stale profile is not
    /// a loading state — it is a failure to disclose.
    func testCompanyPaneReportsUnansweredInsteadOfEternalSpinner() {
        XCTAssertEqual(
            CompanyPane.resolve(
                hasProfileForSymbol: false, loading: false,
                requestedSymbol: "TSM", symbol: "TSM"
            ),
            .unanswered
        )
    }

    func testCompanyPaneBoardAndLoadingUnchanged() {
        XCTAssertEqual(
            CompanyPane.resolve(
                hasProfileForSymbol: true, loading: false, requestedSymbol: "AAPL", symbol: "AAPL"
            ),
            .board
        )
        XCTAssertEqual(
            CompanyPane.resolve(
                hasProfileForSymbol: false, loading: true, requestedSymbol: "TSM", symbol: "TSM"
            ),
            .loading
        )
        // Symbol just changed: the request is dispatched on the next pass, so this
        // is a load — never a failure claim, never the "select a symbol" prompt.
        XCTAssertEqual(
            CompanyPane.resolve(
                hasProfileForSymbol: false, loading: false, requestedSymbol: "AAPL", symbol: "TSM"
            ),
            .loading
        )
        // Nothing selected yet.
        XCTAssertEqual(
            CompanyPane.resolve(
                hasProfileForSymbol: false, loading: false, requestedSymbol: nil, symbol: ""
            ),
            .prompt
        )
    }

    // MARK: - Per-share money (finding 29)

    /// abbrevMoney's sub-$1,000 fallthrough is "%.0f", so routing a per-share
    /// figure through it rendered $4.32 as "$4" and $0.87 as "$1".
    func testPerShareMoneyKeepsCents() {
        XCTAssertEqual(CompanyFormat.perShareMoney(4.32), "$4.32")
        XCTAssertEqual(CompanyFormat.perShareMoney(0.87), "$0.87")
        XCTAssertEqual(CompanyFormat.perShareMoney(23.6), "$23.60")
        XCTAssertEqual(CompanyFormat.perShareMoney(-2.5), "-$2.50")
        // The old formatter's output, pinned so the regression is unmistakable.
        XCTAssertEqual(CompanyFormat.abbrevMoney(4.32), "$4")
    }

    func testPerShareMoneyAbbreviatesOnlyAboveAThousand() {
        // BRK.A-scale book value still fits its cell.
        XCTAssertEqual(CompanyFormat.perShareMoney(425_000), "$425K")
        XCTAssertEqual(CompanyFormat.perShareMoney(nil), "—")
        XCTAssertEqual(CompanyFormat.perShareMoney(Double.nan), "—")
    }

    // MARK: - Flat strategy signal (finding 30)

    /// Fusion can publish direction == 0.0 with a real conviction (two opposing
    /// strategies of equal blend weight cancel). That is flat, not long — the glyph
    /// must agree with the neutral colour the row already used.
    func testFlatSignalDrawsNeitherTriangle() {
        XCTAssertEqual(SignalGlyph.direction(0), "minus")
        XCTAssertEqual(SignalGlyph.direction(0.4), "arrowtriangle.up.fill")
        XCTAssertEqual(SignalGlyph.direction(-0.4), "arrowtriangle.down.fill")
        XCTAssertEqual(SignalGlyph.direction(Double.nan), "minus")
    }

    // MARK: - MERIDIAN tone / trend palette (finding 31)

    /// Sentiment and a geopolitical intensity delta are NOT money direction, so
    /// green/red must never appear on them — the same rule NEWS and COMPANY already
    /// apply to the identical `tone` field.
    func testMeridianToneNeverUsesTheMoneyPalette() {
        for tone in [-8.4, -0.1, 0.1, 6.2] {
            let color = MeridianSupport.toneColor(tone)
            XCTAssertEqual(color, Theme.bone)
            XCTAssertNotEqual(color, Theme.up)
            XCTAssertNotEqual(color, Theme.down)
        }
        XCTAssertEqual(MeridianSupport.toneColor(0), Theme.dim)
        XCTAssertEqual(MeridianSupport.toneColor(Double.nan), Theme.dim)
    }

    func testMeridianToneTextCarriesTheSign() {
        XCTAssertEqual(MeridianSupport.toneText(3.24), "+3.2")
        XCTAssertEqual(MeridianSupport.toneText(-1.75), "-1.8")
        XCTAssertEqual(MeridianSupport.toneText(Double.nan), "—")
    }

    func testForceTrendKeepsGlyphDropsGreenRed() {
        XCTAssertEqual(MeridianSupport.trendText(0.42), "▲ 0.4")
        XCTAssertEqual(MeridianSupport.trendText(-0.42), "▼ 0.4")
        XCTAssertEqual(MeridianSupport.trendText(0), "—")
        XCTAssertEqual(MeridianSupport.trendText(Double.infinity), "—")
        XCTAssertEqual(MeridianSupport.toneColor(0.42), Theme.bone)
        XCTAssertEqual(MeridianSupport.toneColor(-0.42), Theme.bone)
    }

    // MARK: - FILINGS pane resolution (finding 24)

    /// A pull that failed used to resolve to the never-searched prompt ("search a
    /// ticker …") while the operator's query was still in the field.
    func testFilingsPaneSeparatesFailureFromNeverSearched() {
        XCTAssertEqual(
            FilingsPane.resolve(hasReport: false, loading: false, requestedQuery: "AAPL"),
            .unanswered
        )
        XCTAssertEqual(
            FilingsPane.resolve(hasReport: false, loading: false, requestedQuery: nil),
            .prompt
        )
        XCTAssertEqual(
            FilingsPane.resolve(hasReport: false, loading: true, requestedQuery: "AAPL"),
            .loading
        )
        XCTAssertEqual(
            FilingsPane.resolve(hasReport: true, loading: false, requestedQuery: "AAPL"),
            .board
        )
    }

    // MARK: - Fixtures

    private func scanRow(_ symbol: String, sector: String?) -> ScanRow {
        ScanRow(
            symbol: symbol, asset_class: symbol.contains("-") ? "crypto" : "equity",
            composite: 50, momentum: 50, trend: 50, breakout: 50, meanrev: 50,
            vol_state: 50, rsi_14: nil, zscore_20: nil, kalman_tstat: nil,
            ret_1w: nil, ret_1m: nil, ret_3m: nil, dist_52w_high: nil,
            vol_surge: nil, regime: nil, flags: [], last_close: 100, sector: sector
        )
    }
}
