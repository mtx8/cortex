// Shell state tests: center-section order (must match the icon rail) and
// the COMPANY navigation entry point.

import XCTest
@testable import CortexX

@MainActor
final class ShellTests: XCTestCase {
    func testCenterModeRailOrderThenSettings() {
        // FILINGS moved into the NEWS desk as a tab — it is no longer a center
        // section. The icon rail derives its cmd-number shortcuts from the FIRST
        // EIGHT cases (index + 1); SETTINGS is a separate foot-of-rail entry
        // (gearshape, cmd-,) and must stay LAST so the numbered shortcuts remain
        // contiguous and the rail stays in lockstep with this list.
        XCTAssertEqual(
            AppModel.CenterMode.allCases,
            [.chart, .scanner, .news, .company, .options, .foundry, .regimes, .meridian, .settings]
        )
        // Settings sits off the numbered rail — always last.
        XCTAssertEqual(AppModel.CenterMode.allCases.last, .settings)
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
