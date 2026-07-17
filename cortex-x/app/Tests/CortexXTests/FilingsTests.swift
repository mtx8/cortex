// FILINGS tests: the wire-frame decode (full report + lean/absent-optional
// payloads, empty primary_doc, note, xbrl), the get_filings command encode,
// the form-type chip matching (10-K matches 10-K/A; 4 never folds 40-F; OTHER
// as the exact complement; 13D/G; 13F), the filed-date range gate (YTD/1Y/5Y/
// ALL, unparseable kept), the size abbreviator, the open-target resolver, the
// table sort, the visible() composition, and the AppModel request/apply flow.

import XCTest
@testable import CortexX

final class FilingsTests: XCTestCase {
    // MARK: - Fixtures

    /// A UTC "YYYY-MM-DD" instant for the date-range fixtures.
    private func day(_ s: String) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let p = s.split(separator: "-").map { Int($0)! }
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))!
    }

    private func entry(
        form: String = "10-K",
        filed: String = "2026-02-15",
        reportDate: String = "2025-12-28",
        accession: String = "0000320193-26-000005",
        primaryDoc: String = "aapl-20251228.htm",
        primaryDocURL: String = "https://www.sec.gov/Archives/edgar/data/320193/000032019326000005/aapl-20251228.htm",
        indexURL: String = "https://www.sec.gov/Archives/edgar/data/320193/000032019326000005/0000320193-26-000005-index.htm",
        description: String = "Annual report",
        items: String = "",
        size: UInt64 = 1_500_000,
        isXBRL: Bool = true
    ) -> FilingEntry {
        FilingEntry(
            form: form, filed: filed, report_date: reportDate, accession: accession,
            primary_doc: primaryDoc, primary_doc_url: primaryDocURL,
            filing_index_url: indexURL, description: description, items: items,
            size: size, is_xbrl: isXBRL
        )
    }

    // MARK: - Frame decode (full payload)

    func testDecodeFilingsFrame() throws {
        let json = #"""
        {"type":"filings","query":"AAPL","cik":"0000320193","name":"Apple Inc.","ticker":"AAPL","filings":[{"form":"10-K","filed":"2026-02-15","report_date":"2025-12-28","accession":"0000320193-26-000005","primary_doc":"aapl-20251228.htm","primary_doc_url":"https://www.sec.gov/Archives/edgar/data/320193/000032019326000005/aapl-20251228.htm","filing_index_url":"https://www.sec.gov/Archives/edgar/data/320193/000032019326000005/0000320193-26-000005-index.htm","description":"Annual report","items":"","size":1500000,"is_xbrl":true},{"form":"8-K","filed":"2026-01-30","report_date":"","accession":"0000320193-26-000004","primary_doc":"","primary_doc_url":"","filing_index_url":"https://www.sec.gov/Archives/edgar/data/320193/000032019326000004/0000320193-26-000004-index.htm","description":"","items":"2.02,9.01","size":0,"is_xbrl":false}],"source":"SEC EDGAR submissions (data.sec.gov)","note":"","ts_ms":1770000000000}
        """#
        guard case .filings(let r) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected filings frame")
        }
        XCTAssertEqual(r.query, "AAPL")
        XCTAssertEqual(r.cik, "0000320193")
        XCTAssertEqual(r.name, "Apple Inc.")
        XCTAssertEqual(r.ticker, "AAPL")
        XCTAssertEqual(r.source, "SEC EDGAR submissions (data.sec.gov)")
        XCTAssertEqual(r.note, "")
        XCTAssertEqual(r.ts_ms, 1_770_000_000_000)
        XCTAssertEqual(r.filings.count, 2)
        // First: full 10-K, XBRL, sized.
        let k = r.filings[0]
        XCTAssertEqual(k.form, "10-K")
        XCTAssertEqual(k.report_date, "2025-12-28")
        XCTAssertEqual(k.size, 1_500_000)
        XCTAssertTrue(k.is_xbrl)
        // Second: 8-K with empty primary_doc + item codes + size 0.
        let e = r.filings[1]
        XCTAssertEqual(e.form, "8-K")
        XCTAssertEqual(e.report_date, "")
        XCTAssertEqual(e.primary_doc, "")
        XCTAssertEqual(e.primary_doc_url, "")
        XCTAssertEqual(e.items, "2.02,9.01")
        XCTAssertEqual(e.size, 0)
        XCTAssertFalse(e.is_xbrl)
    }

    func testDecodeFilingsFrameWithNote() throws {
        // Unresolved entity: empty name/cik/ticker + an honest note.
        let json = #"""
        {"type":"filings","query":"ZZZZ","cik":"","name":"","ticker":"","filings":[],"source":"SEC EDGAR submissions (data.sec.gov)","note":"ticker not found in SEC map","ts_ms":1770000000000}
        """#
        guard case .filings(let r) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected filings frame")
        }
        XCTAssertTrue(r.name.isEmpty)
        XCTAssertTrue(r.filings.isEmpty)
        XCTAssertEqual(r.note, "ticker not found in SEC map")
    }

    // MARK: - Frame decode (absent optionals / lean payload)

    func testDecodeFilingsLeanEntryDefaultsAbsentFields() throws {
        // A lean entry carrying only form + filed; every other field is
        // absent and must decode to the natural empty/zero rather than failing.
        let json = #"""
        {"type":"filings","query":"AAPL","cik":"0000320193","name":"Apple Inc.","ticker":"AAPL","filings":[{"form":"4","filed":"2026-03-01"}],"source":"SEC EDGAR submissions (data.sec.gov)","note":"","ts_ms":1770000000000}
        """#
        guard case .filings(let r) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected filings frame")
        }
        let e = try XCTUnwrap(r.filings.first)
        XCTAssertEqual(e.form, "4")
        XCTAssertEqual(e.filed, "2026-03-01")
        XCTAssertEqual(e.report_date, "")
        XCTAssertEqual(e.accession, "")
        XCTAssertEqual(e.primary_doc, "")
        XCTAssertEqual(e.primary_doc_url, "")
        XCTAssertEqual(e.filing_index_url, "")
        XCTAssertEqual(e.description, "")
        XCTAssertEqual(e.items, "")
        XCTAssertEqual(e.size, 0)
        XCTAssertFalse(e.is_xbrl)
    }

    func testDecodeFilingsLeanReportDefaultsAbsentFields() throws {
        // Only the tag + query present: the report defaults everything else so
        // a partial engine payload still renders an honest empty state.
        let json = #"{"type":"filings","query":"AAPL"}"#
        guard case .filings(let r) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected filings frame")
        }
        XCTAssertEqual(r.query, "AAPL")
        XCTAssertEqual(r.cik, "")
        XCTAssertEqual(r.name, "")
        XCTAssertEqual(r.ticker, "")
        XCTAssertTrue(r.filings.isEmpty)
        XCTAssertEqual(r.source, "")
        XCTAssertEqual(r.note, "")
        XCTAssertEqual(r.ts_ms, 0)
    }

    // MARK: - Command encode

    func testEncodeGetFilingsCommand() throws {
        let data = try Command.getFilings(query: "AAPL", formFilter: "10-K", text: "supply chain").encoded()
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["cmd"] as? String, "get_filings")
        XCTAssertEqual(obj["query"] as? String, "AAPL")
        XCTAssertEqual(obj["form_filter"] as? String, "10-K")
        XCTAssertEqual(obj["text"] as? String, "supply chain")
    }

    func testEncodeGetFilingsAlwaysCarriesEmptyOptionalKeys() throws {
        // The empty form_filter / text keys are still present — the wire shape
        // matches the contract exactly even when unused.
        let data = try Command.getFilings(query: "NVDA", formFilter: "", text: "").encoded()
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["form_filter"] as? String, "")
        XCTAssertEqual(obj["text"] as? String, "")
    }

    // MARK: - Form-type chip matching

    func testFormFilterAllMatchesEverything() {
        for f in ["10-K", "8-K", "4", "424B5", "SC 13D/A", "13F-HR"] {
            XCTAssertTrue(FilingFormFilter.all.matches(f), "ALL should match \(f)")
        }
    }

    func testFormFilterMatchesAmendments() {
        XCTAssertTrue(FilingFormFilter.k10.matches("10-K"))
        XCTAssertTrue(FilingFormFilter.k10.matches("10-K/A"))
        XCTAssertFalse(FilingFormFilter.k10.matches("10-Q"))
        // A legacy variant is NOT a base match — falls to OTHER, not 10-K.
        XCTAssertFalse(FilingFormFilter.k10.matches("10-K405"))
        XCTAssertTrue(FilingFormFilter.q10.matches("10-Q/A"))
        XCTAssertTrue(FilingFormFilter.k8.matches("8-K"))
        XCTAssertTrue(FilingFormFilter.s1.matches("S-1/A"))
        XCTAssertTrue(FilingFormFilter.def14a.matches("DEF 14A"))
    }

    func testForm4NeverFolds40F() {
        XCTAssertTrue(FilingFormFilter.form4.matches("4"))
        XCTAssertTrue(FilingFormFilter.form4.matches("4/A"))
        // A raw prefix would have swept these in — the base match must not.
        XCTAssertFalse(FilingFormFilter.form4.matches("40-F"))
        XCTAssertFalse(FilingFormFilter.form4.matches("424B5"))
    }

    func testSched13AndForm13F() {
        XCTAssertTrue(FilingFormFilter.sched13.matches("SC 13D"))
        XCTAssertTrue(FilingFormFilter.sched13.matches("SC 13G/A"))
        XCTAssertFalse(FilingFormFilter.sched13.matches("13F-HR"))
        XCTAssertTrue(FilingFormFilter.form13f.matches("13F-HR"))
        XCTAssertTrue(FilingFormFilter.form13f.matches("13F-NT/A"))
        XCTAssertFalse(FilingFormFilter.form13f.matches("SC 13D"))
    }

    func testOtherIsExactComplementOfNamed() {
        // Named forms are never OTHER.
        for f in ["10-K", "10-Q/A", "8-K", "S-1", "DEF 14A", "4", "SC 13D", "13F-HR"] {
            XCTAssertFalse(FilingFormFilter.other.matches(f), "\(f) is named, not OTHER")
        }
        // Unnamed forms are OTHER.
        for f in ["424B5", "425", "40-F", "6-K", "10-K405"] {
            XCTAssertTrue(FilingFormFilter.other.matches(f), "\(f) should be OTHER")
        }
    }

    func testFormFilterIsCaseAndWhitespaceInsensitive() {
        XCTAssertTrue(FilingFormFilter.k10.matches("  10-k  "))
        XCTAssertTrue(FilingFormFilter.sched13.matches("sc 13d"))
    }

    // MARK: - Date range gate

    func testDateRangeAllKeepsEverything() {
        let now = day("2026-07-12")
        XCTAssertTrue(FilingsDateRange.all.contains("2001-01-01", now: now))
        XCTAssertTrue(FilingsDateRange.all.contains("", now: now))
    }

    func testDateRangeYTD() {
        let now = day("2026-07-12")
        XCTAssertTrue(FilingsDateRange.ytd.contains("2026-01-01", now: now))
        XCTAssertTrue(FilingsDateRange.ytd.contains("2026-07-12", now: now))
        XCTAssertFalse(FilingsDateRange.ytd.contains("2025-12-31", now: now))
    }

    func testDateRange1YAnd5Y() {
        let now = day("2026-07-12")
        XCTAssertTrue(FilingsDateRange.y1.contains("2025-07-12", now: now))
        XCTAssertFalse(FilingsDateRange.y1.contains("2025-07-11", now: now))
        XCTAssertTrue(FilingsDateRange.y5.contains("2021-07-12", now: now))
        XCTAssertFalse(FilingsDateRange.y5.contains("2021-07-11", now: now))
    }

    func testDateRangeKeepsUnparseableDate() {
        // A formatting quirk must never hide a real filing under a date gate.
        let now = day("2026-07-12")
        XCTAssertTrue(FilingsDateRange.ytd.contains("", now: now))
        XCTAssertTrue(FilingsDateRange.y1.contains("not-a-date", now: now))
    }

    // MARK: - Size abbreviator

    func testSizeAbbreviation() {
        XCTAssertEqual(FilingsSupport.size(0), "—")
        XCTAssertEqual(FilingsSupport.size(512), "512 B")
        XCTAssertEqual(FilingsSupport.size(999), "999 B")
        XCTAssertEqual(FilingsSupport.size(1_000), "1 KB")
        XCTAssertEqual(FilingsSupport.size(12_000), "12 KB")
        XCTAssertEqual(FilingsSupport.size(1_500_000), "1.5 MB")
        XCTAssertEqual(FilingsSupport.size(2_400_000_000), "2.4 GB")
    }

    // MARK: - Open-target resolver

    func testOpenTargetPrefersPrimaryDoc() {
        let e = entry(primaryDocURL: "https://sec.gov/primary.htm", indexURL: "https://sec.gov/index.htm")
        XCTAssertEqual(FilingsSupport.openTarget(e), "https://sec.gov/primary.htm")
    }

    func testOpenTargetFallsBackToIndexWhenPrimaryEmpty() {
        let e = entry(primaryDoc: "", primaryDocURL: "", indexURL: "https://sec.gov/index.htm")
        XCTAssertEqual(FilingsSupport.openTarget(e), "https://sec.gov/index.htm")
    }

    // MARK: - Sort

    func testDefaultSortIsNewestFiledFirst() {
        let rows = [
            entry(filed: "2024-05-01", accession: "a"),
            entry(filed: "2026-02-15", accession: "b"),
            entry(filed: "2025-08-20", accession: "c"),
        ]
        let out = FilingsSort.default.apply(rows)
        XCTAssertEqual(out.map(\.filed), ["2026-02-15", "2025-08-20", "2024-05-01"])
    }

    func testSortByFormAscendingThenToggle() {
        let rows = [
            entry(form: "8-K", filed: "2026-01-01", accession: "a"),
            entry(form: "10-K", filed: "2026-02-01", accession: "b"),
            entry(form: "4", filed: "2026-03-01", accession: "c"),
        ]
        // First click on FORM sorts A-first (ascending).
        let asc = FilingsSort.toggling(.default, column: .form)
        XCTAssertEqual(asc, FilingsSort(column: .form, ascending: true))
        XCTAssertEqual(asc.apply(rows).map(\.form), ["10-K", "4", "8-K"])
        // Toggling FORM again flips to descending.
        let desc = FilingsSort.toggling(asc, column: .form)
        XCTAssertFalse(desc.ascending)
        XCTAssertEqual(desc.apply(rows).map(\.form), ["8-K", "4", "10-K"])
    }

    func testTogglingFiledStartsNewestFirst() {
        // A first click on FILED opens on descending (newest first).
        let s = FilingsSort.toggling(FilingsSort(column: .form, ascending: true), column: .filed)
        XCTAssertEqual(s, FilingsSort(column: .filed, ascending: false))
    }

    // MARK: - visible() composition

    func testVisibleFiltersByFormThenSorts() {
        let now = day("2026-07-12")
        let rows = [
            entry(form: "10-K", filed: "2026-02-15", accession: "a"),
            entry(form: "10-K/A", filed: "2026-03-20", accession: "b"),
            entry(form: "8-K", filed: "2026-04-01", accession: "c"),
        ]
        let out = FilingsSupport.visible(rows, form: .k10, range: .all, sort: .default, now: now)
        // 10-K chip catches 10-K and 10-K/A but not 8-K; newest first.
        XCTAssertEqual(out.map(\.form), ["10-K/A", "10-K"])
    }

    func testVisibleAppliesDateGate() {
        let now = day("2026-07-12")
        let rows = [
            entry(form: "8-K", filed: "2026-06-01", accession: "a"),
            entry(form: "8-K", filed: "2020-06-01", accession: "b"),
        ]
        let out = FilingsSupport.visible(rows, form: .all, range: .ytd, sort: .default, now: now)
        XCTAssertEqual(out.map(\.filed), ["2026-06-01"])
    }

    // MARK: - AppModel flow

    @MainActor
    func testRequestFilingsSetsLoadingAndQuery() {
        let model = AppModel()
        model.requestFilings(query: "  aapl  ")
        XCTAssertTrue(model.filingsLoading)
        // Trimmed, preserved as submitted (uppercase left to the caller).
        XCTAssertEqual(model.filingsQuery, "aapl")
    }

    @MainActor
    func testRequestFilingsIgnoresBlankQuery() {
        let model = AppModel()
        model.requestFilings(query: "   ")
        XCTAssertFalse(model.filingsLoading)
        XCTAssertEqual(model.filingsQuery, "")
    }

    @MainActor
    func testApplyFilingsSetsReportAndClearsLoading() {
        let model = AppModel()
        model.requestFilings(query: "AAPL")
        XCTAssertTrue(model.filingsLoading)
        let report = FilingsReport(
            query: "AAPL", cik: "0000320193", name: "Apple Inc.", ticker: "AAPL",
            filings: [entry()], source: "SEC EDGAR submissions (data.sec.gov)",
            note: "", ts_ms: 1
        )
        model.apply(.filings(report))
        XCTAssertEqual(model.filingsReport?.name, "Apple Inc.")
        XCTAssertFalse(model.filingsLoading)
    }

    @MainActor
    func testStaleFilingsResponseNeitherClobbersNorClearsLoading() {
        // Two rapid searches: the engine spawns one task per request with no
        // ordering guarantee, so a slow pull for the FIRST query can land
        // after the operator has moved to a second. The superseded response
        // must be dropped — it may not overwrite the current entity nor clear
        // the spinner for the request still in flight.
        let model = AppModel()
        model.requestFilings(query: "AAPL")
        model.requestFilings(query: "NVDA")
        XCTAssertEqual(model.filingsQuery, "NVDA")
        XCTAssertTrue(model.filingsLoading)

        let stale = FilingsReport(
            query: "AAPL", cik: "0000320193", name: "Apple Inc.", ticker: "AAPL",
            filings: [entry()], source: "SEC EDGAR submissions (data.sec.gov)",
            note: "", ts_ms: 1
        )
        model.apply(.filings(stale))
        // Dropped: no report surfaced, spinner still up for NVDA.
        XCTAssertNil(model.filingsReport)
        XCTAssertTrue(model.filingsLoading)

        let fresh = FilingsReport(
            query: "NVDA", cik: "0001045810", name: "NVIDIA Corp", ticker: "NVDA",
            filings: [entry()], source: "SEC EDGAR submissions (data.sec.gov)",
            note: "", ts_ms: 2
        )
        model.apply(.filings(fresh))
        XCTAssertEqual(model.filingsReport?.name, "NVIDIA Corp")
        XCTAssertFalse(model.filingsLoading)
    }

    @MainActor
    func testOpenFilingsSwitchesModeAndRequests() {
        let model = AppModel()
        model.openFilings("nvda")
        XCTAssertEqual(model.centerMode, .filings)
        XCTAssertTrue(model.filingsLoading)
        XCTAssertEqual(model.filingsQuery, "NVDA")
    }
}
