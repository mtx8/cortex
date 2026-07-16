// Multi-chart grid state: pane-state defaults, the layout persistence wire
// format (@AppStorage raw values), and the pane-local ensureSymbolData
// history path — which must never move the global selection.

import XCTest
@testable import CortexX

@MainActor
final class ChartGridTests: XCTestCase {
    /// Fixed "now" so fixtures stay pure math.
    private let nowMs: Int64 = 1_760_000_000_000
    private let dayMs: Int64 = 86_400_000

    // MARK: - Pane state defaults

    func testPaneStateDefaultFollowsGlobalSelection() {
        // nil symbol = classic single-chart behavior; nil interval rides
        // the global picker until the pane overrides it.
        let state = ChartPaneState()
        XCTAssertNil(state.symbol)
        XCTAssertNil(state.interval)
    }

    // MARK: - Layout persistence

    func testLayoutRawValuesAreTheStorageWireFormat() {
        // @AppStorage("chartLayout") persists these — never rename cases.
        XCTAssertEqual(ChartLayout.allCases, [.single, .dual, .quad])
        XCTAssertEqual(
            ChartLayout.allCases.map(\.rawValue), ["single", "dual", "quad"]
        )
        XCTAssertEqual(ChartLayout.allCases.map(\.paneCount), [1, 2, 4])
    }

    func testUnknownLayoutRawValueHasNoCase() {
        // ChartGrid falls back to .single when the stored value is stale.
        XCTAssertNil(ChartLayout(rawValue: "hex"))
    }

    func testLayoutChipSymbols() {
        XCTAssertEqual(
            ChartLayout.allCases.map(\.symbolName),
            ["square", "rectangle.split.2x1", "square.grid.2x2"]
        )
    }

    // MARK: - Pane-symbol stickiness

    func testIntervalOnlyWriteDoesNotPinUnsetPane() {
        // The pane binding's getter always hands out the RESOLVED symbol,
        // so an interval click echoes it back through the setter — that
        // echo must not permanently pin an unset pane.
        XCTAssertFalse(
            ChartGrid.shouldPersistPaneSymbol("ETH-USD", resolvedDefault: "ETH-USD")
        )
    }

    func testGenuineSymbolChangePersists() {
        XCTAssertTrue(
            ChartGrid.shouldPersistPaneSymbol("TSM", resolvedDefault: "ETH-USD")
        )
    }

    func testNilOrEmptySymbolNeverPersists() {
        XCTAssertFalse(ChartGrid.shouldPersistPaneSymbol(nil, resolvedDefault: "ETH-USD"))
        XCTAssertFalse(ChartGrid.shouldPersistPaneSymbol("", resolvedDefault: "ETH-USD"))
    }

    // MARK: - ensureSymbolData

    func testEnsureSymbolDataRequestsHistoryForUnknownSymbol() {
        let model = AppModel()
        XCTAssertTrue(model.ensureSymbolData("TSM"))
    }

    func testEnsureSymbolDataIsNoOpWhenAnyIntervalHasBars() {
        let model = seededModel(symbol: "TSM")
        XCTAssertFalse(model.ensureSymbolData("TSM"))
    }

    func testEnsureSymbolDataUppercasesBeforeLookup() {
        // Pane symbols land uppercased; a lowercase caller must still hit
        // the existing series instead of re-fetching.
        let model = seededModel(symbol: "TSM")
        XCTAssertFalse(model.ensureSymbolData("tsm"))
    }

    func testEnsureSymbolDataNeverTouchesGlobalSelection() {
        let model = AppModel()
        let symbol = model.selectedSymbol
        let interval = model.selectedInterval
        model.ensureSymbolData("NVDA")
        XCTAssertEqual(model.selectedSymbol, symbol)
        XCTAssertEqual(model.selectedInterval, interval)
    }

    // MARK: - Fixtures

    /// A model whose symbol carries a two-bar D1 series, seeded through a
    /// history frame — exactly how on-demand pane backfills land.
    private func seededModel(symbol: String) -> AppModel {
        let model = AppModel()
        model.apply(.history(HistorySlice(
            symbol: symbol, interval: .d1,
            bars: [
                d1Bar(symbol: symbol, tsOpenMs: nowMs - 2 * dayMs),
                d1Bar(symbol: symbol, tsOpenMs: nowMs - dayMs),
            ],
            source: "test", ts_ms: nowMs
        )))
        return model
    }

    private func d1Bar(symbol: String, tsOpenMs: Int64) -> Bar {
        Bar(
            symbol: symbol, interval: .d1, ts_open_ms: tsOpenMs,
            open: 100, high: 101, low: 99, close: 100,
            volume: 1_000, trade_count: 10, vwap: 100, complete: true
        )
    }
}
