// Intel views: wire-decode tests for the company / regime_map / geo frames
// (literal JSON as cortexd emits it) plus the pure view helpers — board
// partitioning, regime labels, and fundamentals formatting.

import XCTest
@testable import CortexX

final class IntelViewsTests: XCTestCase {
    // MARK: - Frame decoding

    func testDecodeCompanyFrame() throws {
        let json = #"""
        {"type":"company","symbol":"NVDA","name":"NVIDIA Corporation","sector":"Technology","industry":"Semiconductors","country":"US","description":"Designs GPUs and accelerated computing platforms.","segments":[{"name":"Data Center","note":"AI accelerators"},{"name":"Gaming","note":"GeForce GPUs"}],"suppliers":[{"symbol":"TSM","name":"TSMC","via":"leading-edge wafer fabrication"},{"symbol":null,"name":"SK hynix","via":"HBM memory"}],"customers":[{"symbol":"MSFT","name":"Microsoft","via":"Azure AI infrastructure"}],"competitors":["AMD","INTC"],"fundamentals":{"revenue":130500000000.0,"revenue_yoy":1.14,"gross_margin":0.75,"op_margin":0.62,"net_income":72880000000.0,"net_margin":0.558,"eps":2.94,"assets":111601000000.0,"liabilities":32274000000.0,"equity":79327000000.0,"ocf":64089000000.0,"cash":null,"period":"annual","fiscal_year":"2025"},"graph_source":"curated graph (MTX Labs, 2026-07)","fundamentals_source":"sec-edgar (10-K/10-Q)","ts_ms":1752300000000}
        """#
        guard case .company(let p) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected company frame")
        }
        XCTAssertEqual(p.symbol, "NVDA")
        XCTAssertEqual(p.segments.count, 2)
        XCTAssertEqual(p.suppliers.count, 2)
        XCTAssertEqual(p.suppliers[0].symbol, "TSM")
        XCTAssertNil(p.suppliers[1].symbol)
        XCTAssertEqual(p.customers.first?.via, "Azure AI infrastructure")
        XCTAssertEqual(p.competitors, ["AMD", "INTC"])
        let f = try XCTUnwrap(p.fundamentals)
        XCTAssertEqual(f.revenue, 130_500_000_000)
        XCTAssertNil(f.cash)
        XCTAssertEqual(f.fiscal_year, "2025")
        XCTAssertEqual(p.fundamentals_source, "sec-edgar (10-K/10-Q)")
    }

    func testDecodeRegimeMapFrame() throws {
        let json = #"""
        {"type":"regime_map","rows":[{"symbol":"AAPL","state":"bull","drawdown_pct":3.2,"runup_pct":41.0,"days_in_state":120,"dist_50_200_pct":6.4,"last_close":231.5},{"symbol":"NKE","state":"bear","drawdown_pct":31.5,"runup_pct":4.0,"days_in_state":88,"dist_50_200_pct":null,"last_close":61.2},{"symbol":"PYPL","state":"recovery","drawdown_pct":24.0,"runup_pct":18.5,"days_in_state":12,"dist_50_200_pct":-2.1,"last_close":74.8}],"breadth":{"pct_above_200d":62.5,"pct_above_50d":48.0,"bulls":18,"bears":6,"entering_bull":3,"entering_bear":2,"universe_size":40},"source":"yahoo d1 (delayed)","ts_ms":1752300000000}
        """#
        guard case .regimeMap(let board) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected regime_map frame")
        }
        XCTAssertEqual(board.rows.count, 3)
        XCTAssertEqual(board.rows[0].state, .bull)
        XCTAssertEqual(board.rows[2].state, .recovery)
        XCTAssertNil(board.rows[1].dist_50_200_pct)
        XCTAssertEqual(board.breadth.bulls, 18)
        XCTAssertEqual(board.breadth.universe_size, 40)
        XCTAssertEqual(board.source, "yahoo d1 (delayed)")
    }

    func testDecodeGeoFrame() throws {
        let json = #"""
        {"type":"geo","forces":[{"force":"external order","value":68.0,"trend_7d":4.2,"proxy":"GDELT tone EWMA"},{"force":"debt & money","value":41.0,"trend_7d":0.0,"proxy":"UST curve"}],"chains":[{"rule_id":"sanctions-ru-energy","title":"sanctions: RU energy","steps":["sanctions announced","supply restriction","crude repricing"],"assets":[{"target":"CL","direction":1,"note":"crude up"},{"target":"airlines","direction":-1,"note":"fuel cost"}],"intensity":2.3,"evidence":[{"title":"New sanctions package targets exports","source_domain":"example.org","url":"https://example.org/a","tone":-4.1,"theme":"sanctions","countries":["RU","EU"],"ts_ms":1752290000000}]}],"events":[{"title":"Central bank holds rates","source_domain":"example.com","url":"https://example.com/b","tone":1.2,"theme":"central banks","countries":["US"],"ts_ms":1752295000000}],"source":"gdelt 2.0 doc (15m poll)","ts_ms":1752300000000}
        """#
        guard case .geo(let pulse) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected geo frame")
        }
        XCTAssertEqual(pulse.forces.count, 2)
        XCTAssertEqual(pulse.forces[0].trend_7d, 4.2)
        XCTAssertEqual(pulse.chains.count, 1)
        XCTAssertEqual(pulse.chains[0].steps.count, 3)
        XCTAssertEqual(pulse.chains[0].assets[1].direction, -1)
        XCTAssertEqual(pulse.chains[0].evidence.first?.countries, ["RU", "EU"])
        XCTAssertEqual(pulse.events.first?.tone, 1.2)
        XCTAssertEqual(pulse.source, "gdelt 2.0 doc (15m poll)")
    }

    // MARK: - RegimeState labels

    func testRegimeStateLabels() {
        XCTAssertEqual(RegimeState.bull.label, "bull")
        XCTAssertEqual(RegimeState.entering_bull.label, "entering bull")
        XCTAssertEqual(RegimeState.correction.label, "correction")
        XCTAssertEqual(RegimeState.entering_bear.label, "entering bear")
        XCTAssertEqual(RegimeState.bear.label, "bear")
        XCTAssertEqual(RegimeState.recovery.label, "recovery")
    }

    // MARK: - Board partitioning

    private func row(_ symbol: String, _ state: RegimeState, drawdown: Double) -> RegimeRow {
        RegimeRow(
            symbol: symbol, state: state, drawdown_pct: drawdown, runup_pct: 10,
            days_in_state: 5, dist_50_200_pct: nil, last_close: 100
        )
    }

    func testPartitionMapsRecoveryIntoBearColumn() {
        let rows = [
            row("AAPL", .bull, drawdown: 2),
            row("NKE", .bear, drawdown: 31),
            row("PYPL", .recovery, drawdown: 24),
            row("MMM", .correction, drawdown: 12),
            row("XOM", .entering_bear, drawdown: 21),
            row("SHOP", .entering_bull, drawdown: 5),
        ]
        let partitioned = RegimeBoardLayout.partition(rows)
        XCTAssertEqual(partitioned[.bull]?.map(\.symbol), ["AAPL"])
        XCTAssertEqual(partitioned[.enteringBull]?.map(\.symbol), ["SHOP"])
        XCTAssertEqual(partitioned[.correction]?.map(\.symbol), ["MMM"])
        XCTAssertEqual(partitioned[.enteringBear]?.map(\.symbol), ["XOM"])
        // recovery lives inside the BEAR column, sorted by drawdown severity.
        XCTAssertEqual(partitioned[.bear]?.map(\.symbol), ["NKE", "PYPL"])
    }

    func testPartitionSortsByDrawdownSeverityDesc() {
        let rows = [
            row("A", .correction, drawdown: 11),
            row("B", .correction, drawdown: 19),
            row("C", .correction, drawdown: -15), // sign-agnostic
        ]
        XCTAssertEqual(
            RegimeBoardLayout.partition(rows)[.correction]?.map(\.symbol),
            ["B", "C", "A"]
        )
    }

    func testShowsRunupBySide() {
        XCTAssertTrue(RegimeBoardLayout.showsRunup(.bull))
        XCTAssertTrue(RegimeBoardLayout.showsRunup(.entering_bull))
        XCTAssertTrue(RegimeBoardLayout.showsRunup(.recovery))
        XCTAssertFalse(RegimeBoardLayout.showsRunup(.correction))
        XCTAssertFalse(RegimeBoardLayout.showsRunup(.entering_bear))
        XCTAssertFalse(RegimeBoardLayout.showsRunup(.bear))
    }

    func testBreadthGaugeFractionNormalizesPercentOrFraction() throws {
        // Contract: breadth is always 0..100 percent. 0.5 means 0.5%, not 50%.
        XCTAssertEqual(try XCTUnwrap(RegimeBoardLayout.gaugeFraction(62.5)), 0.625, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(RegimeBoardLayout.gaugeFraction(0.5)), 0.005, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(RegimeBoardLayout.gaugeFraction(1.0)), 0.01, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(RegimeBoardLayout.gaugeFraction(240)), 1.0, accuracy: 1e-9) // clamped
        XCTAssertNil(RegimeBoardLayout.gaugeFraction(nil))
        XCTAssertNil(RegimeBoardLayout.gaugeFraction(-4))
        XCTAssertNil(RegimeBoardLayout.gaugeFraction(.nan))
    }

    // MARK: - Fundamentals formatting

    func testAbbrevMoney() {
        XCTAssertEqual(CompanyFormat.abbrevMoney(nil), "—")
        XCTAssertEqual(CompanyFormat.abbrevMoney(.nan), "—")
        XCTAssertEqual(CompanyFormat.abbrevMoney(1.234e12), "$1.23T")
        XCTAssertEqual(CompanyFormat.abbrevMoney(2.5e10), "$25.0B")
        XCTAssertEqual(CompanyFormat.abbrevMoney(3.4e9), "$3.40B")
        XCTAssertEqual(CompanyFormat.abbrevMoney(8.9e8), "$890M")
        XCTAssertEqual(CompanyFormat.abbrevMoney(12_400), "$12.4K")
        XCTAssertEqual(CompanyFormat.abbrevMoney(950), "$950")
        XCTAssertEqual(CompanyFormat.abbrevMoney(-1.2e9), "-$1.20B")
    }

    func testPctFormatting() {
        XCTAssertEqual(CompanyFormat.pct(nil), "—")
        XCTAssertEqual(CompanyFormat.pct(0.564), "56.4%")
        XCTAssertEqual(CompanyFormat.pct(0.12, signed: true), "+12.0%")
        XCTAssertEqual(CompanyFormat.pct(-0.083, signed: true), "-8.3%")
    }

    func testPlainFormatting() {
        XCTAssertEqual(CompanyFormat.plain(nil), "—")
        XCTAssertEqual(CompanyFormat.plain(2.937), "2.94")
        XCTAssertEqual(CompanyFormat.plain(-0.5), "-0.50")
    }

    func testMinimalProfileDetection() {
        let minimal = CompanyProfile(
            symbol: "BTC-USD", name: "Bitcoin", sector: "", industry: "", country: "",
            description: "Decentralized digital asset.", segments: [], suppliers: [],
            customers: [], competitors: [], fundamentals: nil,
            graph_source: "none curated", fundamentals_source: "n/a", ts_ms: 0
        )
        XCTAssertTrue(CompanyFormat.isMinimal(minimal))

        var full = minimal
        full.segments = [Segment(name: "Data Center", note: "AI accelerators")]
        XCTAssertFalse(CompanyFormat.isMinimal(full))
    }

    // MARK: - Meridian force ordering

    func testOrderedForcesPreferredOrder() {
        let forces = [
            ForceGauge(force: "technology", value: 30, trend_7d: 0, proxy: "theme intensity"),
            ForceGauge(force: "nature", value: 20, trend_7d: 0, proxy: "disaster intensity"),
            ForceGauge(force: "external order", value: 68, trend_7d: 4.2, proxy: "GDELT tone EWMA"),
            ForceGauge(force: "debt & money", value: 41, trend_7d: -1, proxy: "UST curve"),
            ForceGauge(force: "internal order", value: 50, trend_7d: 0, proxy: "GDELT tone EWMA"),
        ]
        XCTAssertEqual(
            MeridianSupport.orderedForces(forces).map(\.force),
            ["debt & money", "internal order", "external order", "nature", "technology"]
        )
    }

    func testOrderedForcesKeepsUnknownForcesInArrivalOrder() {
        let forces = [
            ForceGauge(force: "mystery b", value: 1, trend_7d: 0, proxy: "x"),
            ForceGauge(force: "technology", value: 2, trend_7d: 0, proxy: "x"),
            ForceGauge(force: "mystery a", value: 3, trend_7d: 0, proxy: "x"),
        ]
        XCTAssertEqual(
            MeridianSupport.orderedForces(forces).map(\.force),
            ["technology", "mystery b", "mystery a"]
        )
    }
}
