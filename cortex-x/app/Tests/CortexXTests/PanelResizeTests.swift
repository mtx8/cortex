// Resizable-panel sizing tests: the pure clamp + per-panel min/max/default/key
// contract that the shell dividers (watchlist, intelligence, deck) and the
// chart-dock divider all read. Pins the persistence keys (never rename — they
// back @AppStorage), the clamp bounds, the NaN guard, and the wider chart-dock
// default that keeps the DOM ladder usable out of the box.

import XCTest
@testable import CortexX

final class PanelResizeTests: XCTestCase {

    // MARK: - Pure clamp

    func testClampHoldsWithinBounds() {
        XCTAssertEqual(PanelResize.clamp(300, min: 160, max: 360), 300)
    }

    func testClampToMin() {
        XCTAssertEqual(PanelResize.clamp(10, min: 160, max: 360), 160)
    }

    func testClampToMax() {
        XCTAssertEqual(PanelResize.clamp(9_000, min: 160, max: 360), 360)
    }

    func testClampIsNaNSafe() {
        // A non-finite candidate collapses to the minimum, never persists NaN.
        XCTAssertEqual(PanelResize.clamp(.nan, min: 160, max: 360), 160)
        XCTAssertEqual(PanelResize.clamp(.infinity, min: 160, max: 360), 360)
        XCTAssertEqual(PanelResize.clamp(-.infinity, min: 160, max: 360), 160)
    }

    // MARK: - Persistence keys (the @AppStorage wire format)

    func testPersistenceKeysAreTheWireFormat() {
        XCTAssertEqual(ResizablePanel.watchlist.storageKey, "watchlistWidth")
        XCTAssertEqual(ResizablePanel.intelligence.storageKey, "intelligenceWidth")
        XCTAssertEqual(ResizablePanel.deck.storageKey, "deckHeight")
        XCTAssertEqual(ResizablePanel.chartDock.storageKey, "chartDockWidth")
    }

    func testPersistenceKeysAreUnique() {
        let keys = ResizablePanel.allCases.map(\.storageKey)
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testResizeKeysNeverCollideWithVisibilityKeys() {
        // Resize (ResizablePanel) and collapse (ShellPanel) persist side by side.
        let resize = Set(ResizablePanel.allCases.map(\.storageKey))
        let visibility = Set(ShellPanel.allCases.map(\.storageKey))
        XCTAssertTrue(resize.isDisjoint(with: visibility))
    }

    // MARK: - Bounds

    func testMinMaxBounds() {
        XCTAssertEqual(ResizablePanel.watchlist.minSize, 160)
        XCTAssertEqual(ResizablePanel.watchlist.maxSize, 360)
        XCTAssertEqual(ResizablePanel.intelligence.minSize, 260)
        XCTAssertEqual(ResizablePanel.intelligence.maxSize, 520)
        XCTAssertEqual(ResizablePanel.deck.minSize, 120)
        XCTAssertEqual(ResizablePanel.deck.maxSize, 460)
        XCTAssertEqual(ResizablePanel.chartDock.minSize, 280)
        XCTAssertEqual(ResizablePanel.chartDock.maxSize, 560)
    }

    // MARK: - Defaults

    func testDefaults() {
        XCTAssertEqual(ResizablePanel.watchlist.defaultSize, 220)
        XCTAssertEqual(ResizablePanel.intelligence.defaultSize, 340)
        XCTAssertEqual(ResizablePanel.deck.defaultSize, 200)
        XCTAssertEqual(ResizablePanel.chartDock.defaultSize, 340)
    }

    func testDockWidthDefaultIsWiderThanTheOldFixed320() {
        // The DOM ladder was crushed at the old fixed 320; the resizable dock
        // defaults wider so it's usable before the operator ever drags it.
        XCTAssertGreaterThan(ResizablePanel.chartDock.defaultSize, 320)
        XCTAssertEqual(ResizablePanel.chartDock.defaultSize, 340)
    }

    func testDeckDefaultShrankToReclaimTheWastedBand() {
        // The deck used to sit at a fixed 280 that a flat, empty positions table
        // dominated; the smaller default reclaims that band.
        XCTAssertLessThan(ResizablePanel.deck.defaultSize, 280)
        XCTAssertEqual(ResizablePanel.deck.defaultSize, 200)
    }

    func testEveryDefaultSitsWithinItsBounds() {
        for panel in ResizablePanel.allCases {
            XCTAssertGreaterThanOrEqual(panel.defaultSize, panel.minSize, "\(panel) default below min")
            XCTAssertLessThanOrEqual(panel.defaultSize, panel.maxSize, "\(panel) default above max")
            // The clamp is a no-op on an in-range default.
            XCTAssertEqual(panel.clamp(panel.defaultSize), panel.defaultSize)
        }
    }

    func testEveryPanelHasAStrictlyPositiveRange() {
        for panel in ResizablePanel.allCases {
            XCTAssertLessThan(panel.minSize, panel.maxSize, "\(panel) min not below max")
        }
    }

    // MARK: - Per-panel clamp method

    func testClampMethodUsesPanelBounds() {
        XCTAssertEqual(ResizablePanel.deck.clamp(50), 120)      // below min
        XCTAssertEqual(ResizablePanel.deck.clamp(9_000), 460)   // above max
        XCTAssertEqual(ResizablePanel.deck.clamp(300), 300)     // within
        XCTAssertEqual(ResizablePanel.chartDock.clamp(200), 280)
        XCTAssertEqual(ResizablePanel.chartDock.clamp(700), 560)
    }
}
