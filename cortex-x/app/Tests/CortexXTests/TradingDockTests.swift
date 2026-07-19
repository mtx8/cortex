// Trading-dock layout tests: the pure DockPanel / DockState logic that drives
// which panels stack beside the chart, whether the dock takes space, and whether
// the shared depth subscription is needed. Also pins the @AppStorage wire keys,
// the sensible defaults (DOM + T&S on), and that LEVEL 2 is gone as a center mode
// (its content now lives in the dock).

import XCTest
@testable import CortexX

final class TradingDockTests: XCTestCase {

    // MARK: Panel identity + wire format

    func testPanelOrderIsFixedTopToBottom() {
        // The dock stacks panels in this order; enabledPanels preserves it.
        XCTAssertEqual(DockPanel.allCases, [.l1, .dom, .tape, .flow])
    }

    func testPanelStorageKeysAreTheWireFormat() {
        // @AppStorage persists these — never rename. Every reader (picker, dock,
        // workspace, collapse button) must use the same keys.
        XCTAssertEqual(
            DockPanel.allCases.map(\.storageKey),
            ["chartDockL1", "chartDockDom", "chartDockTape", "chartDockFlow"]
        )
    }

    func testPanelTitles() {
        XCTAssertEqual(DockPanel.allCases.map(\.title), ["L1", "DOM", "T&S", "FLOW"])
    }

    func testPanelDefaultsGiveATradingFeel() {
        // Sensible default: DOM + T&S on, L1 + FLOW off — but all persist.
        XCTAssertFalse(DockPanel.l1.defaultOn)
        XCTAssertTrue(DockPanel.dom.defaultOn)
        XCTAssertTrue(DockPanel.tape.defaultOn)
        XCTAssertFalse(DockPanel.flow.defaultOn)
    }

    func testOnlyL1SkipsTheDepthSubscription() {
        // The market panels ride the shared book/tape/flow subscription; L1 reads
        // top-of-book, which streams independently.
        XCTAssertFalse(DockPanel.l1.needsDepth)
        XCTAssertTrue(DockPanel.dom.needsDepth)
        XCTAssertTrue(DockPanel.tape.needsDepth)
        XCTAssertTrue(DockPanel.flow.needsDepth)
    }

    // MARK: Enabled panels (ordering + filtering)

    func testEnabledPanelsPreserveDockOrder() {
        // Toggled in any combination, the enabled list stays in L1→FLOW order.
        let s = DockState(l1: true, dom: false, tape: true, flow: true)
        XCTAssertEqual(s.enabledPanels, [.l1, .tape, .flow])
    }

    func testEnabledPanelsEmptyWhenAllOff() {
        let s = DockState(l1: false, dom: false, tape: false, flow: false)
        XCTAssertTrue(s.enabledPanels.isEmpty)
        XCTAssertFalse(s.anyEnabled)
    }

    func testEnabledPanelsAllWhenAllOn() {
        let s = DockState(l1: true, dom: true, tape: true, flow: true)
        XCTAssertEqual(s.enabledPanels, [.l1, .dom, .tape, .flow])
        XCTAssertTrue(s.anyEnabled)
    }

    // MARK: Depth-needed logic (any market panel on)

    func testDepthNeededWhenAnyMarketPanelOn() {
        XCTAssertTrue(DockState(l1: false, dom: true, tape: false, flow: false).depthNeeded)
        XCTAssertTrue(DockState(l1: false, dom: false, tape: true, flow: false).depthNeeded)
        XCTAssertTrue(DockState(l1: false, dom: false, tape: false, flow: true).depthNeeded)
    }

    func testDepthNotNeededWhenNoMarketPanelOn() {
        // No panels: nothing to stream.
        XCTAssertFalse(DockState(l1: false, dom: false, tape: false, flow: false).depthNeeded)
        // L1 alone reads top-of-book — it never triggers the depth subscription
        // even though the dock is visible.
        let l1Only = DockState(l1: true, dom: false, tape: false, flow: false)
        XCTAssertFalse(l1Only.depthNeeded)
        XCTAssertTrue(l1Only.anyEnabled)
    }

    // MARK: Dock visibility (any-on AND not collapsed)

    func testDockVisibleOnlyWhenEnabledAndNotHidden() {
        XCTAssertTrue(DockState.dockVisible(anyEnabled: true, hidden: false))
        // Enabled but collapsed → not visible (a re-open handle shows instead).
        XCTAssertFalse(DockState.dockVisible(anyEnabled: true, hidden: true))
        // No panels → never visible regardless of the collapse flag.
        XCTAssertFalse(DockState.dockVisible(anyEnabled: false, hidden: false))
        XCTAssertFalse(DockState.dockVisible(anyEnabled: false, hidden: true))
    }

    // MARK: Defaults value

    func testDefaultsMatchPerPanelDefaults() {
        XCTAssertEqual(
            DockState.defaults,
            DockState(l1: false, dom: true, tape: true, flow: false)
        )
        // The default posture shows a dock and needs a depth subscription.
        XCTAssertTrue(DockState.defaults.anyEnabled)
        XCTAssertTrue(DockState.defaults.depthNeeded)
        XCTAssertEqual(DockState.defaults.enabledPanels, [.dom, .tape])
    }

    // MARK: isOn accessor

    func testIsOnAccessorMatchesFields() {
        let s = DockState(l1: true, dom: false, tape: true, flow: false)
        XCTAssertTrue(s.isOn(.l1))
        XCTAssertFalse(s.isOn(.dom))
        XCTAssertTrue(s.isOn(.tape))
        XCTAssertFalse(s.isOn(.flow))
    }

    // MARK: LEVEL 2 removed as a center mode

    func testLevel2IsNoLongerACenterMode() {
        // The standalone LEVEL 2 rail section is gone — its DOM ladder + tape +
        // flow now live in the chart dock. No CenterMode raw value decodes to it.
        XCTAssertNil(AppModel.CenterMode(rawValue: "level2"))
    }
}
