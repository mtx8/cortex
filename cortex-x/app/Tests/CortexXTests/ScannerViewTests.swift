// Scanner view tests: wire-decode of the scan frame (literal JSON as cortexd
// emits it) plus the pure helpers — preset screens, column sorting, and the
// scanner number formatting.

import XCTest
@testable import CortexX

final class ScannerViewTests: XCTestCase {
    // MARK: - Frame decoding

    func testDecodeScanFrame() throws {
        let json = #"""
        {"type":"scan","rows":[{"symbol":"NVDA","asset_class":"equity","composite":91.4,"momentum":96.0,"trend":88.0,"breakout":94.0,"meanrev":22.0,"vol_state":81.0,"rsi_14":71.2,"zscore_20":1.84,"kalman_tstat":2.6,"ret_1w":0.052,"ret_1m":0.118,"ret_3m":0.31,"dist_52w_high":0.012,"vol_surge":1.8,"regime":"bull","flags":["new 52w high","volume spike","breakout setup"],"last_close":181.4},{"symbol":"BTC-USD","asset_class":"crypto","composite":48.0,"momentum":51.0,"trend":44.0,"breakout":39.0,"meanrev":55.0,"vol_state":62.0,"rsi_14":null,"zscore_20":null,"kalman_tstat":null,"ret_1w":null,"ret_1m":null,"ret_3m":null,"dist_52w_high":null,"vol_surge":null,"regime":null,"flags":[],"last_close":97250.0},{"symbol":"NKE","asset_class":"equity","composite":18.0,"momentum":9.0,"trend":12.0,"breakout":8.0,"meanrev":93.0,"vol_state":40.0,"rsi_14":28.4,"zscore_20":-2.31,"kalman_tstat":-1.9,"ret_1w":-0.034,"ret_1m":-0.09,"ret_3m":-0.21,"dist_52w_high":0.315,"vol_surge":0.9,"regime":"bear","flags":["oversold bounce"],"last_close":61.2}],"source":"cortex scan (D1 + live bars, delayed equities)","ts_ms":1752300000000}
        """#
        guard case .scan(let board) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected scan frame")
        }
        XCTAssertEqual(board.rows.count, 3)
        XCTAssertEqual(board.source, "cortex scan (D1 + live bars, delayed equities)")
        XCTAssertEqual(board.ts_ms, 1_752_300_000_000)

        let nvda = board.rows[0]
        XCTAssertEqual(nvda.symbol, "NVDA")
        XCTAssertEqual(nvda.asset_class, "equity")
        XCTAssertEqual(nvda.composite, 91.4)
        XCTAssertEqual(nvda.rsi_14, 71.2)
        XCTAssertEqual(nvda.ret_1w, 0.052)
        XCTAssertEqual(nvda.regime, .bull)
        XCTAssertEqual(nvda.flags, ["new 52w high", "volume spike", "breakout setup"])

        // Null optionals decode to nil — never a fake zero.
        let btc = board.rows[1]
        XCTAssertNil(btc.rsi_14)
        XCTAssertNil(btc.zscore_20)
        XCTAssertNil(btc.ret_3m)
        XCTAssertNil(btc.dist_52w_high)
        XCTAssertNil(btc.vol_surge)
        XCTAssertNil(btc.regime)
        XCTAssertTrue(btc.flags.isEmpty)

        XCTAssertEqual(board.rows[2].zscore_20, -2.31)
        XCTAssertEqual(board.rows[2].regime, .bear)
    }

    // MARK: - Row factory

    private func row(
        _ symbol: String,
        composite: Double = 50,
        momentum: Double = 50,
        breakout: Double = 50,
        meanrev: Double = 50,
        volState: Double = 50,
        rsi: Double? = 50,
        flags: [String] = [],
        regime: RegimeState? = nil,
        lastClose: Double = 100
    ) -> ScanRow {
        ScanRow(
            symbol: symbol, asset_class: symbol.contains("-") ? "crypto" : "equity",
            composite: composite, momentum: momentum, trend: 50, breakout: breakout,
            meanrev: meanrev, vol_state: volState, rsi_14: rsi, zscore_20: nil,
            kalman_tstat: nil, ret_1w: nil, ret_1m: nil, ret_3m: nil,
            dist_52w_high: nil, vol_surge: nil, regime: regime, flags: flags,
            last_close: lastClose
        )
    }

    // MARK: - Presets

    func testPresetAllKeepsEverythingCompositeDesc() {
        let rows = [
            row("A", composite: 10),
            row("B", composite: 90),
            row("C-USD", composite: 50),
        ]
        XCTAssertEqual(ScanPreset.all.apply(rows).map(\.symbol), ["B", "C-USD", "A"])
    }

    func testTopMomentumSortsMomentumDesc() {
        let rows = [
            row("A", momentum: 20),
            row("B", momentum: 95),
            row("C", momentum: 60),
        ]
        XCTAssertEqual(ScanPreset.topMomentum.apply(rows).map(\.symbol), ["B", "C", "A"])
    }

    func testBreakoutPresetKeepsFlaggedRowsOnly() {
        let rows = [
            row("A", breakout: 70, flags: ["breakout setup"]),
            row("B", breakout: 99, flags: ["golden cross"]), // high score, wrong flag
            row("C", breakout: 90, flags: ["new 52w high", "volume spike"]),
            row("D", breakout: 95, flags: []),
        ]
        // Only the breakout flags qualify, sorted breakout desc.
        XCTAssertEqual(ScanPreset.breakoutWatch.apply(rows).map(\.symbol), ["C", "A"])
    }

    func testOversoldPresetFlagOrLowRsi() {
        let rows = [
            row("FLAG", meanrev: 60, rsi: 55, flags: ["oversold bounce"]), // flag, rsi high
            row("RSI", meanrev: 90, rsi: 28),                             // rsi < 35, no flag
            row("EDGE", meanrev: 40, rsi: 35),                            // rsi == 35 → out
            row("NILRSI", meanrev: 99, rsi: nil),                         // no rsi, no flag → out
        ]
        XCTAssertEqual(ScanPreset.oversold.apply(rows).map(\.symbol), ["RSI", "FLAG"])
    }

    func testVolMoversPresetMatchesEitherVolFlag() {
        let rows = [
            row("A", volState: 40, flags: ["volume spike"]),
            row("B", volState: 90, flags: ["vol expansion"]),
            row("C", volState: 99, flags: ["breakout setup"]), // wrong flag → out
        ]
        XCTAssertEqual(ScanPreset.volMovers.apply(rows).map(\.symbol), ["B", "A"])
    }

    func testEquityCryptoPresetsSplitOnDash() {
        let rows = [
            row("AAPL", composite: 10),
            row("BTC-USD", composite: 80),
            row("NKE", composite: 60),
            row("ETH-USD", composite: 20),
        ]
        XCTAssertEqual(ScanPreset.equities.apply(rows).map(\.symbol), ["NKE", "AAPL"])
        XCTAssertEqual(ScanPreset.crypto.apply(rows).map(\.symbol), ["BTC-USD", "ETH-USD"])
    }

    func testPresetFlagMatchIsCaseInsensitive() {
        let rows = [row("A", flags: ["Breakout Setup"])]
        XCTAssertEqual(ScanPreset.breakoutWatch.apply(rows).map(\.symbol), ["A"])
    }

    func testPremarketMoversGapScreen() {
        let rows = [
            row("GAPUP", lastClose: 100),   // +5% -> in
            row("GAPDN", lastClose: 200),   // -3% -> in (|gap|)
            row("FLAT", lastClose: 100),    // +1% -> out
            row("EDGE", lastClose: 100),    // exactly +2% -> in
            row("BTC-USD", lastClose: 100), // crypto -> out even with a gap
            row("NOPX", lastClose: 100),    // no latest price -> out
            row("BADPX", lastClose: 100),   // NaN latest price -> out
            row("BADCL", lastClose: 0),     // unusable prior close -> out
        ]
        let px: [String: Double] = [
            "GAPUP": 105, "GAPDN": 194, "FLAT": 101, "EDGE": 102,
            "BTC-USD": 150, "BADPX": .nan, "BADCL": 50,
        ]
        // Sorted by |gap| desc: 5%, 3%, 2%.
        XCTAssertEqual(
            ScanPreset.premarketMovers.apply(rows, lastPrice: { px[$0] }).map(\.symbol),
            ["GAPUP", "GAPDN", "EDGE"]
        )
        // No price context (the default): the screen is empty, never wrong.
        XCTAssertTrue(ScanPreset.premarketMovers.apply(rows).isEmpty)
    }

    func testGapFractionNaNSafe() throws {
        let gap = try XCTUnwrap(ScanPreset.gapFraction(lastPrice: 105, priorClose: 100))
        XCTAssertEqual(gap, 0.05, accuracy: 1e-12)
        XCTAssertNil(ScanPreset.gapFraction(lastPrice: nil, priorClose: 100))
        XCTAssertNil(ScanPreset.gapFraction(lastPrice: .nan, priorClose: 100))
        XCTAssertNil(ScanPreset.gapFraction(lastPrice: 0, priorClose: 100))
        XCTAssertNil(ScanPreset.gapFraction(lastPrice: 105, priorClose: 0))
        XCTAssertNil(ScanPreset.gapFraction(lastPrice: 105, priorClose: .nan))
        XCTAssertNil(ScanPreset.gapFraction(lastPrice: 105, priorClose: -1))
    }

    // MARK: - Sorting

    func testSortNumericColumnBothDirections() {
        let rows = [
            row("A", momentum: 30),
            row("B", momentum: 90),
            row("C", momentum: 60),
        ]
        XCTAssertEqual(
            ScanSort(column: .momentum, ascending: false).apply(rows).map(\.symbol),
            ["B", "C", "A"]
        )
        XCTAssertEqual(
            ScanSort(column: .momentum, ascending: true).apply(rows).map(\.symbol),
            ["A", "C", "B"]
        )
    }

    func testSortNilReadingsSortLastInBothDirections() {
        let rows = [
            row("NIL", rsi: nil),
            row("HI", rsi: 80),
            row("LO", rsi: 20),
        ]
        XCTAssertEqual(
            ScanSort(column: .rsi, ascending: false).apply(rows).map(\.symbol),
            ["HI", "LO", "NIL"]
        )
        XCTAssertEqual(
            ScanSort(column: .rsi, ascending: true).apply(rows).map(\.symbol),
            ["LO", "HI", "NIL"]
        )
    }

    func testSortSymbolAlphabetical() {
        let rows = [row("NKE"), row("AAPL"), row("MSFT")]
        XCTAssertEqual(
            ScanSort(column: .symbol, ascending: true).apply(rows).map(\.symbol),
            ["AAPL", "MSFT", "NKE"]
        )
        XCTAssertEqual(
            ScanSort(column: .symbol, ascending: false).apply(rows).map(\.symbol),
            ["NKE", "MSFT", "AAPL"]
        )
    }

    func testSortRegimeNilLast() {
        let rows = [
            row("NONE", regime: nil),
            row("BULL", regime: .bull),
            row("BEAR", regime: .bear),
        ]
        XCTAssertEqual(
            ScanSort(column: .regime, ascending: true).apply(rows).map(\.symbol),
            ["BEAR", "BULL", "NONE"]
        )
        XCTAssertEqual(
            ScanSort(column: .regime, ascending: false).apply(rows).map(\.symbol),
            ["BULL", "BEAR", "NONE"]
        )
    }

    func testTogglingStartsUsefulThenFlips() {
        // Numeric columns start big-first.
        let first = ScanSort.toggling(nil, column: .composite)
        XCTAssertEqual(first, ScanSort(column: .composite, ascending: false))
        // Repeat click flips direction.
        let second = ScanSort.toggling(first, column: .composite)
        XCTAssertEqual(second, ScanSort(column: .composite, ascending: true))
        // A different column resets to its own default.
        let third = ScanSort.toggling(second, column: .symbol)
        XCTAssertEqual(third, ScanSort(column: .symbol, ascending: true))
    }

    func testFlagsColumnIsNotSortable() {
        XCTAssertFalse(ScanColumn.flags.sortable)
        let rows = [row("B"), row("A")]
        // Applying a flags sort is a no-op — order preserved.
        XCTAssertEqual(
            ScanSort(column: .flags, ascending: true).apply(rows).map(\.symbol),
            ["B", "A"]
        )
    }

    // MARK: - Formatting

    func testScoreFormatting() {
        XCTAssertEqual(ScanFormat.score(91.4), "91")
        XCTAssertEqual(ScanFormat.score(0), "0")
        XCTAssertEqual(ScanFormat.score(.nan), "—")
    }

    func testNoiseBandIsInclusive40To60() {
        XCTAssertTrue(ScanFormat.isNoise(40))
        XCTAssertTrue(ScanFormat.isNoise(50))
        XCTAssertTrue(ScanFormat.isNoise(60))
        XCTAssertFalse(ScanFormat.isNoise(39.9))
        XCTAssertFalse(ScanFormat.isNoise(60.1))
    }

    func testPctFormatsFractionsSigned() {
        XCTAssertEqual(ScanFormat.pct(0.052), "+5.2%")
        XCTAssertEqual(ScanFormat.pct(-0.034), "-3.4%")
        XCTAssertEqual(ScanFormat.pct(nil), "—")
        XCTAssertEqual(ScanFormat.pct(.nan), "—")
    }

    func testRawFormatting() {
        XCTAssertEqual(ScanFormat.raw(71.2, decimals: 0), "71")
        XCTAssertEqual(ScanFormat.raw(1.842, decimals: 2, signed: true), "+1.84")
        XCTAssertEqual(ScanFormat.raw(-2.31, decimals: 2, signed: true), "-2.31")
        XCTAssertEqual(ScanFormat.raw(nil, decimals: 2), "—")
    }

    func testDistFromHighRendersAsNegativeDistance() {
        XCTAssertEqual(ScanFormat.distFromHigh(0.032), "-3.2%")
        XCTAssertEqual(ScanFormat.distFromHigh(0.0), "0.0%") // at the high, no "-0.0%"
        XCTAssertEqual(ScanFormat.distFromHigh(nil), "—")
    }

    func testRatioFormatting() {
        XCTAssertEqual(ScanFormat.ratio(1.82), "1.8x")
        XCTAssertEqual(ScanFormat.ratio(0.9), "0.9x")
        XCTAssertEqual(ScanFormat.ratio(nil), "—")
    }

    func testFlagsDisplayOverflow() {
        let none = ScanFormat.flagsDisplay([])
        XCTAssertTrue(none.shown.isEmpty)
        XCTAssertEqual(none.overflow, 0)

        let two = ScanFormat.flagsDisplay(["a", "b"])
        XCTAssertEqual(two.shown, ["a", "b"])
        XCTAssertEqual(two.overflow, 0)

        let four = ScanFormat.flagsDisplay(["a", "b", "c", "d"])
        XCTAssertEqual(four.shown, ["a", "b"])
        XCTAssertEqual(four.overflow, 2)
    }

    // MARK: - Empty-preset state (board non-empty, screen filtered to nothing)

    func testScreenedEmptyOnlyWhenBoardHasRowsButNoneVisible() {
        // A board WITH rows whose screen matched none — the "no rows match this
        // screen" case.
        XCTAssertTrue(ScanEmptyState.isScreenedEmpty(boardRowCount: 40, visibleRowCount: 0))
        // Some rows survive the screen — not empty.
        XCTAssertFalse(ScanEmptyState.isScreenedEmpty(boardRowCount: 40, visibleRowCount: 2))
        // A genuinely empty board is the first-scan-pending state, NOT this one.
        XCTAssertFalse(ScanEmptyState.isScreenedEmpty(boardRowCount: 0, visibleRowCount: 0))
    }

    func testScreenEmptyDetailNamesPresetOnly() {
        XCTAssertEqual(
            ScanEmptyState.detail(preset: "top momentum", filterCount: 0, query: ""),
            "nothing passes 'top momentum' right now — relax the screen or clear filters"
        )
    }

    func testScreenEmptyDetailPluralizesFiltersAndAddsQuery() {
        XCTAssertEqual(
            ScanEmptyState.detail(preset: "all", filterCount: 1, query: ""),
            "nothing passes 'all' + 1 filter right now — relax the screen or clear filters"
        )
        // Filters pluralize; a trimmed query is named too.
        XCTAssertEqual(
            ScanEmptyState.detail(preset: "oversold", filterCount: 3, query: "  nvda "),
            "nothing passes 'oversold' + 3 filters + symbol 'nvda' right now — relax the screen or clear filters"
        )
        // A whitespace-only query is dropped.
        XCTAssertEqual(
            ScanEmptyState.detail(preset: "crypto", filterCount: 0, query: "   "),
            "nothing passes 'crypto' right now — relax the screen or clear filters"
        )
    }
}
