// Scanner repair tests — the four confirmed defects in the filter builder and
// the two sort paths:
//
//  1. the builder offered six fields whose `ScanSort.key` is nil, so picking one
//     made every row fail `matches` and blanked the board behind a "no rows
//     match this screen" message (a broken filter reading as "no setups");
//  2. the return / Δ52w filters compared a typed threshold against the RAW
//     fraction while the columns display percent, so "1m% >= 5" screened for
//     +500%;
//  3. the details grid sorted LAST on the stale `last_close` while the cell
//     rendered the live quote, so a descending column was visibly not
//     descending;
//  4. both sorts evaluated their model-backed key inside the comparator —
//     O(n log n) AppModel reads per sort instead of one per row.

import XCTest
@testable import CortexX

final class ScannerRepairTests: XCTestCase {
    // MARK: - Fixtures

    /// A row with EVERY optional populated — so a nil `ScanSort.key` can only
    /// mean "this column has no key", never "this fixture lacks the data".
    private func fullRow(
        _ symbol: String,
        ret1m: Double? = 0.052,
        dist52w: Double? = 0.032,
        rsi: Double? = 28,
        lastClose: Double = 100
    ) -> ScanRow {
        ScanRow(
            symbol: symbol, asset_class: symbol.contains("-") ? "crypto" : "equity",
            composite: 60, momentum: 61, trend: 62, breakout: 63,
            meanrev: 64, vol_state: 65, rsi_14: rsi, zscore_20: -1.4,
            kalman_tstat: 2.1, ret_1w: 0.011, ret_1m: ret1m, ret_3m: 0.21,
            dist_52w_high: dist52w, vol_surge: 1.9, regime: .bull,
            flags: ["volume spike"], last_close: lastClose,
            sector: "Technology", shares_outstanding: 1_000_000,
            public_float_usd: 50_000_000, short_interest: 40_000
        )
    }

    // MARK: - 1. No filter field may be structurally dead

    func testEveryOfferedFilterFieldHasANonNilSortKey() {
        // The invariant the old hand-written exclusion list broke. A field whose
        // key is nil culls EVERY row, which is not a strict screen — it is a
        // dead control that empties the board with no explanation.
        let row = fullRow("NVDA")
        XCTAssertFalse(ScanFilter.fields.isEmpty)
        for column in ScanFilter.fields {
            XCTAssertNotNil(
                ScanSort.key(row, column),
                "filter field \(column.rawValue) has no ScanSort.key — it would match nothing"
            )
        }
    }

    func testFilterableColumnsAndSortKeysAgreeAcrossTheWholeCatalog() {
        // Lockstep in BOTH directions: no filterable column without a key, and
        // no keyed column silently missing from the builder.
        let row = fullRow("NVDA")
        for column in ScanColumn.allCases {
            XCTAssertEqual(
                column.filterable, ScanSort.key(row, column) != nil,
                "filterable/key mismatch on \(column.rawValue)"
            )
            XCTAssertEqual(ScanFilter.fields.contains(column), column.filterable)
        }
    }

    func testThePreviouslyDeadFieldsAreNoLongerOffered() {
        for dead: ScanColumn in [.change, .sector, .marketCap, .floatUsd, .shortFloat, .news] {
            XCTAssertFalse(
                ScanFilter.fields.contains(dead),
                "\(dead.rawValue) has no row key — offering it blanks the board"
            )
        }
        // The real numeric screens are still there.
        for live: ScanColumn in [.composite, .rsi, .volSurge, .ret1m, .dist52wHi, .price] {
            XCTAssertTrue(ScanFilter.fields.contains(live))
        }
    }

    func testAScreenSavedOnAKeylessFieldReloadsInertNotEmpty() {
        // A screen persisted while the builder still offered chg% / sector /
        // mktcap must not come back as a filter that matches nothing — that is
        // stale state, and it would blank the board with no way to see why.
        let rows = [fullRow("A"), fullRow("B")]
        for dead: ScanColumn in [.change, .sector, .marketCap, .floatUsd, .shortFloat, .news] {
            let stale = ScanFilter(column: dead, op: .gte, value: 5)
            XCTAssertEqual(
                ScanFilter.apply([stale], to: rows).map(\.symbol), ["A", "B"],
                "a stale \(dead.rawValue) filter culled the board"
            )
        }
        // …while a live filter alongside it still screens normally.
        let mixed = [
            ScanFilter(column: .sector, op: .gte, value: 5),
            ScanFilter(column: .rsi, op: .lte, value: 30),
        ]
        XCTAssertEqual(ScanFilter.apply(mixed, to: rows).map(\.symbol), ["A", "B"])
        XCTAssertTrue(
            ScanFilter.apply(
                [ScanFilter(column: .sector, op: .gte, value: 5),
                 ScanFilter(column: .rsi, op: .gte, value: 90)],
                to: rows
            ).isEmpty
        )
    }

    func testAFilterOnEveryOfferedFieldCanStillMatchARow() {
        // End-to-end on the real entry point: for each offered field, a filter
        // whose threshold is that row's own reading must keep the row.
        let row = fullRow("NVDA")
        for column in ScanFilter.fields {
            guard let reading = ScanSort.key(row, column) else {
                return XCTFail("no key for offered field \(column.rawValue)")
            }
            let filter = ScanFilter(column: column, op: .gte,
                                    value: column.filterReading(reading))
            XCTAssertEqual(
                ScanFilter.apply([filter], to: [row]).map(\.symbol), ["NVDA"],
                "\(column.rawValue) >= its own reading culled the row"
            )
        }
    }

    // MARK: - 2. Filter thresholds are typed in the column's displayed unit

    func testReturnFilterThresholdIsPercentNotRawFraction() {
        // "1m% >= 5" must mean +5% (ret_1m 0.052), not the +500% the raw
        // fraction comparison used to screen for.
        let up = fullRow("UP", ret1m: 0.052)
        let flat = fullRow("FLAT", ret1m: 0.004)
        let rows = [up, flat]

        let fivePct = ScanFilter(column: .ret1m, op: .gte, value: 5)
        XCTAssertEqual(ScanFilter.apply([fivePct], to: rows).map(\.symbol), ["UP"])

        // And it is a real threshold, not "anything positive".
        let sixPct = ScanFilter(column: .ret1m, op: .gte, value: 6)
        XCTAssertTrue(ScanFilter.apply([sixPct], to: rows).isEmpty)

        // The lte side scales identically.
        let underOne = ScanFilter(column: .ret1m, op: .lte, value: 1)
        XCTAssertEqual(ScanFilter.apply([underOne], to: rows).map(\.symbol), ["FLAT"])
    }

    func testDistFromHighFilterUsesTheSignedPercentTheCellShows() {
        // dist_52w_high ships as a NON-NEGATIVE drawdown (0.032) but the cell
        // renders "-3.2%", so the filter reading is the signed percent: "within
        // 5% of the high" is `>= -5`.
        let near = fullRow("NEAR", dist52w: 0.032)
        let far = fullRow("FAR", dist52w: 0.315)
        XCTAssertEqual(ScanFormat.distFromHigh(near.dist_52w_high), "-3.2%")

        let within5 = ScanFilter(column: .dist52wHi, op: .gte, value: -5)
        XCTAssertEqual(
            ScanFilter.apply([within5], to: [near, far]).map(\.symbol), ["NEAR"]
        )
        // Deep-drawdown side: `<= -20%` keeps only the beaten-down name.
        let below20 = ScanFilter(column: .dist52wHi, op: .lte, value: -20)
        XCTAssertEqual(
            ScanFilter.apply([below20], to: [near, far]).map(\.symbol), ["FAR"]
        )
    }

    func testNonPercentColumnsKeepTheirBareUnits() {
        // The scale is per-column: percentiles, RSI and ratios must NOT be
        // rescaled, or the fix would break every working screen.
        let row = fullRow("NVDA", rsi: 28)
        XCTAssertEqual(
            ScanFilter.apply([ScanFilter(column: .rsi, op: .lte, value: 30)], to: [row])
                .map(\.symbol),
            ["NVDA"]
        )
        XCTAssertEqual(
            ScanFilter.apply([ScanFilter(column: .composite, op: .gte, value: 60)], to: [row])
                .map(\.symbol),
            ["NVDA"]
        )
        XCTAssertEqual(
            ScanFilter.apply([ScanFilter(column: .volSurge, op: .gte, value: 2)], to: [row])
                .map(\.symbol),
            []
        )
        XCTAssertNil(ScanColumn.rsi.filterUnit)
        XCTAssertNil(ScanColumn.composite.filterUnit)
        XCTAssertEqual(ScanColumn.ret1m.filterUnit, "%")
        XCTAssertEqual(ScanColumn.dist52wHi.filterUnit, "%")
    }

    func testFilterSummaryTextCarriesTheUnitSoItCannotBeMisread() {
        XCTAssertEqual(
            ScanFilter(column: .ret1m, op: .gte, value: 5).summaryText,
            "1m% >= 5.0%"
        )
        XCTAssertEqual(
            ScanFilter(column: .dist52wHi, op: .gte, value: -5).summaryText,
            "Δ52w-hi >= -5.0%"
        )
        // No suffix invented for the bare-unit columns.
        XCTAssertEqual(
            ScanFilter(column: .composite, op: .gte, value: 80).summaryText,
            "composite >= 80.0"
        )
    }

    func testNonFiniteReadingsAndThresholdsStillMatchNothing() {
        // Preserved behaviour: absent/garbage data never sneaks through a screen,
        // and a NaN threshold is not a wildcard.
        let noReturn = fullRow("NONE", ret1m: nil)
        XCTAssertTrue(
            ScanFilter.apply([ScanFilter(column: .ret1m, op: .gte, value: 0)], to: [noReturn])
                .isEmpty
        )
        let nanRow = fullRow("NAN", ret1m: .nan)
        XCTAssertTrue(
            ScanFilter.apply([ScanFilter(column: .ret1m, op: .gte, value: 0)], to: [nanRow])
                .isEmpty
        )
        XCTAssertTrue(
            ScanFilter.apply([ScanFilter(column: .composite, op: .gte, value: .nan)],
                             to: [fullRow("OK")]).isEmpty
        )
    }

    // MARK: - 3. Details grid LAST/CHG% sort on the live reading

    func testDetailsPriceSortUsesTheLiveQuoteNotTheStaleClose() {
        // The reported inversion: a 99.20 close now trading 104.10 must sort
        // ABOVE a 101.00 close now trading 100.40 on LAST descending.
        let up = fullRow("UP", lastClose: 99.20)
        let down = fullRow("DOWN", lastClose: 101.00)
        let live = ["UP": 104.10, "DOWN": 100.40]
        let sort = ScanSort(column: .price, ascending: false)

        XCTAssertEqual(
            sort.apply([down, up], price: { live[$0.symbol] }).map(\.symbol),
            ["UP", "DOWN"]
        )
        XCTAssertEqual(
            ScanSort(column: .price, ascending: true)
                .apply([down, up], price: { live[$0.symbol] }).map(\.symbol),
            ["DOWN", "UP"]
        )
        // No live quote for a symbol → the daily close is the honest fallback,
        // exactly as the LAST cell renders it.
        XCTAssertEqual(
            sort.apply([up, down], price: { _ in nil }).map(\.symbol),
            ["DOWN", "UP"]
        )
    }

    func testDetailsChangeColumnIsSortableOnTheInjectedSessionChange() {
        // CHG% was clickable in the summary table and inert in the details grid —
        // the same header behaving differently in the two modes.
        XCTAssertTrue(ScanColumn.change.sortable)
        let rows = [fullRow("A"), fullRow("B"), fullRow("C")]
        let change = ["A": -1.2, "B": 3.4] // C absent
        XCTAssertEqual(
            ScanSort(column: .change, ascending: false)
                .apply(rows, change: { change[$0.symbol] }).map(\.symbol),
            ["B", "A", "C"]
        )
        // nil readings sink in BOTH directions — absent data never floats up.
        XCTAssertEqual(
            ScanSort(column: .change, ascending: true)
                .apply(rows, change: { change[$0.symbol] }).map(\.symbol),
            ["A", "B", "C"]
        )
    }

    func testRowOnlySortsAreUnchangedWithoutInjectedReadings() {
        // Regression guard on the defaulted parameters: every existing row-key
        // column must sort exactly as before.
        let a = fullRow("A", rsi: 20)
        let b = fullRow("B", rsi: 80)
        let c = fullRow("C", rsi: nil)
        XCTAssertEqual(
            ScanSort(column: .rsi, ascending: false).apply([a, b, c]).map(\.symbol),
            ["B", "A", "C"]
        )
        XCTAssertEqual(
            ScanSort(column: .rsi, ascending: true).apply([a, b, c]).map(\.symbol),
            ["A", "B", "C"]
        )
        XCTAssertEqual(
            ScanSort(column: .symbol, ascending: true).apply([b, a]).map(\.symbol),
            ["A", "B"]
        )
        // flags stays a no-op.
        XCTAssertEqual(
            ScanSort(column: .flags, ascending: true).apply([b, a]).map(\.symbol),
            ["B", "A"]
        )
    }

    func testNonFiniteLivePriceSinksInsteadOfPoisoningTheOrder() {
        let good = fullRow("GOOD", lastClose: 50)
        let bad = fullRow("BAD", lastClose: 60)
        let live: [String: Double] = ["GOOD": 55, "BAD": .nan]
        // A NaN quote is no quote: BAD falls back to its 60.00 close rather than
        // making the comparator inconsistent.
        XCTAssertEqual(
            ScanSort(column: .price, ascending: false)
                .apply([good, bad], price: { live[$0.symbol] }).map(\.symbol),
            ["BAD", "GOOD"]
        )
    }

    // MARK: - 4. One model read per row per sort, not one per comparison

    /// Enough rows that a comparator-evaluated key is unmistakably more work
    /// than one read per row (8 rows ≈ 20+ comparisons ≈ 40+ reads).
    private var eightRows: [ScanRow] {
        (0..<8).map { fullRow(String(UnicodeScalar(UInt8(65 + $0))), lastClose: Double(100 - $0)) }
    }

    func testSummarySortReadsEachRowsKeyExactlyOnce() {
        let rows = eightRows
        var priceReads = 0
        let sorted = ScanSummary.sorted(
            rows, by: .init(column: .price, ascending: false),
            price: { row in priceReads += 1; return row.last_close },
            change: { _ in nil }
        )
        XCTAssertEqual(priceReads, rows.count)
        XCTAssertEqual(sorted.first?.symbol, "A")
        XCTAssertEqual(sorted.last?.symbol, "H")

        var changeReads = 0
        _ = ScanSummary.sorted(
            rows, by: .init(column: .change, ascending: true),
            price: { _ in nil },
            change: { row in changeReads += 1; return row.last_close }
        )
        XCTAssertEqual(changeReads, rows.count)
    }

    func testSummarySortStillSinksAbsentReadingsInBothDirections() {
        // The decorate-sort-undecorate rewrite must not change the ordering
        // contract: nil AND non-finite readings stay at the bottom.
        let rows = [fullRow("NIL"), fullRow("HI"), fullRow("NAN"), fullRow("LO")]
        let quote: [String: Double] = ["HI": 200, "LO": 10, "NAN": .nan]
        for ascending in [true, false] {
            let out = ScanSummary.sorted(
                rows, by: .init(column: .price, ascending: ascending),
                price: { quote[$0.symbol] }, change: { _ in nil }
            ).map(\.symbol)
            XCTAssertEqual(Set(out.suffix(2)), ["NIL", "NAN"], "ascending=\(ascending)")
            XCTAssertEqual(out.prefix(2).sorted(), ["HI", "LO"], "ascending=\(ascending)")
        }
    }

    func testDetailsSortReadsEachRowsKeyExactlyOnce() {
        let rows = eightRows
        var priceReads = 0
        let byPrice = ScanSort(column: .price, ascending: false)
            .apply(rows, price: { row in priceReads += 1; return row.last_close })
        XCTAssertEqual(priceReads, rows.count)
        XCTAssertEqual(byPrice.first?.symbol, "A")

        var changeReads = 0
        _ = ScanSort(column: .change, ascending: false)
            .apply(rows, change: { row in changeReads += 1; return row.last_close })
        XCTAssertEqual(changeReads, rows.count)
    }
}
