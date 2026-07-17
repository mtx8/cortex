// Shell state tests: center-section order (must match the icon rail) and
// the COMPANY navigation entry point.

import XCTest
@testable import CortexX

@MainActor
final class ShellTests: XCTestCase {
    func testCenterModeHasNineCasesInRailOrder() {
        // FILINGS sits right after NEWS — the icon rail derives its cmd-number
        // shortcuts from this order, so the two must stay in lockstep.
        XCTAssertEqual(
            AppModel.CenterMode.allCases,
            [.chart, .scanner, .news, .filings, .company, .options, .foundry, .regimes, .meridian]
        )
    }

    func testOpenCompanySwitchesModeAndMarksLoading() {
        let model = AppModel()
        XCTAssertEqual(model.centerMode, .chart)

        model.openCompany("NVDA")

        XCTAssertEqual(model.centerMode, .company)
        XCTAssertTrue(model.companyLoading)
    }

    // Panel toggles live at their panels; ShellPanel is the shared identity
    // that keeps the collapse buttons, the re-open handles, and RootView's
    // @AppStorage visibility keys in sync.
    func testShellPanelStorageKeysMatchRootView() {
        XCTAssertEqual(ShellPanel.allCases, [.watchlist, .intelligence, .deck])
        XCTAssertEqual(
            ShellPanel.allCases.map(\.storageKey),
            ["showWatchlist", "showIntelligence", "showDeck"]
        )
    }

    func testShellPanelShortcutKeysAreDistinct() {
        XCTAssertEqual(ShellPanel.allCases.map(\.shortcutKey), ["l", "r", "b"])
        XCTAssertEqual(Set(ShellPanel.allCases.map(\.shortcutKey)).count, 3)
    }

    // Re-open chevrons must point back toward where the panel returns.
    func testShellPanelIcons() {
        XCTAssertEqual(ShellPanel.watchlist.collapseIcon, "sidebar.left")
        XCTAssertEqual(ShellPanel.intelligence.collapseIcon, "sidebar.right")
        XCTAssertEqual(ShellPanel.deck.collapseIcon, "rectangle.bottomthird.inset.filled")
        XCTAssertEqual(ShellPanel.watchlist.reopenIcon, "chevron.right")
        XCTAssertEqual(ShellPanel.intelligence.reopenIcon, "chevron.left")
        XCTAssertEqual(ShellPanel.deck.reopenIcon, "chevron.up")
    }
}
