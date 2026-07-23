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

    func testDecodeCompanyWithSharesFloatAndFilings() throws {
        // Newer engine: fundamentals carry a share count + public float (USD),
        // and the profile carries a filings array (deliberately NOT in filed
        // order, to exercise the defensive client-side sort).
        let json = #"""
        {"type":"company","symbol":"NVDA","name":"NVIDIA Corporation","sector":"Technology","industry":"Semiconductors","country":"US","description":"GPUs.","segments":[],"suppliers":[],"customers":[],"competitors":["AMD"],"fundamentals":{"revenue":130500000000.0,"revenue_yoy":1.14,"gross_margin":0.75,"op_margin":0.62,"net_income":72880000000.0,"net_margin":0.558,"eps":2.94,"assets":111601000000.0,"liabilities":32274000000.0,"equity":79327000000.0,"ocf":64089000000.0,"cash":8589000000.0,"shares_outstanding":24600000000.0,"public_float_usd":3200000000000.0,"period":"annual","fiscal_year":"2025"},"filings":[{"form":"10-K","filed":"2025-02-26","primary_doc_url":"https://www.sec.gov/nvda-10k.htm"},{"form":"8-K","filed":"2025-05-28","primary_doc_url":"https://www.sec.gov/nvda-8k.htm"}],"graph_source":"curated","fundamentals_source":"sec-edgar (10-K/10-Q)","ts_ms":1752300000000}
        """#
        guard case .company(let p) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected company frame")
        }
        let f = try XCTUnwrap(p.fundamentals)
        XCTAssertEqual(f.shares_outstanding, 24_600_000_000)
        XCTAssertEqual(f.public_float_usd, 3_200_000_000_000)
        XCTAssertEqual(p.filings.count, 2)
        XCTAssertEqual(p.filings[0].form, "10-K")
        XCTAssertEqual(p.filings[0].filed, "2025-02-26")
        XCTAssertEqual(p.filings[1].primary_doc_url, "https://www.sec.gov/nvda-8k.htm")
    }

    func testDecodeCompanyDefaultsStatsAndFilingsWhenAbsent() throws {
        // Older engine: no shares_outstanding / public_float_usd keys and no
        // filings key at all. The optional stats decode nil, and filings must
        // default to [] rather than failing the whole frame.
        let json = #"""
        {"type":"company","symbol":"NVDA","name":"NVIDIA Corporation","sector":"Technology","industry":"Semiconductors","country":"US","description":"GPUs.","segments":[],"suppliers":[],"customers":[],"competitors":[],"fundamentals":{"revenue":130500000000.0,"revenue_yoy":1.14,"gross_margin":0.75,"op_margin":0.62,"net_income":72880000000.0,"net_margin":0.558,"eps":2.94,"assets":111601000000.0,"liabilities":32274000000.0,"equity":79327000000.0,"ocf":64089000000.0,"cash":null,"period":"annual","fiscal_year":"2025"},"graph_source":"curated","fundamentals_source":"sec-edgar (10-K/10-Q)","ts_ms":1752300000000}
        """#
        guard case .company(let p) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected company frame")
        }
        let f = try XCTUnwrap(p.fundamentals)
        XCTAssertNil(f.shares_outstanding)
        XCTAssertNil(f.public_float_usd)
        XCTAssertEqual(p.filings, [])
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

    // MARK: - Asset-class split

    func testAssetClassSplitSeparatesEquitiesFromCrypto() {
        let rows = [
            row("AAPL", .bull, drawdown: 2),
            row("BTC-USD", .bull, drawdown: 8),
            row("NKE", .bear, drawdown: 31),
            row("ETH-USD", .correction, drawdown: 14),
            row("SHOP", .entering_bull, drawdown: 5),
        ]
        let split = RegimeBoardLayout.assetClassSplit(rows)
        // Bare tickers are equities; dashed pairs are crypto. Arrival order
        // is preserved within each group.
        XCTAssertEqual(split.equities.map(\.symbol), ["AAPL", "NKE", "SHOP"])
        XCTAssertEqual(split.crypto.map(\.symbol), ["BTC-USD", "ETH-USD"])
    }

    func testAssetClassSplitWithNoCrypto() {
        let rows = [
            row("AAPL", .bull, drawdown: 2),
            row("MMM", .correction, drawdown: 12),
        ]
        let split = RegimeBoardLayout.assetClassSplit(rows)
        XCTAssertEqual(split.equities.map(\.symbol), ["AAPL", "MMM"])
        XCTAssertTrue(split.crypto.isEmpty)
    }

    func testAssetClassSplitEmptyInput() {
        let split = RegimeBoardLayout.assetClassSplit([])
        XCTAssertTrue(split.equities.isEmpty)
        XCTAssertTrue(split.crypto.isEmpty)
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

    // MARK: - Statistics: client-side market cap (shares × price, nil-safe)

    func testMarketCapComputation() {
        // Happy path: 24.6B shares × $170 = $4.182T.
        let cap = try? XCTUnwrap(CompanyStats.marketCap(shares: 24.6e9, lastPrice: 170))
        XCTAssertEqual(try XCTUnwrap(cap), 4.182e12, accuracy: 1)
    }

    func testMarketCapIsNilSafe() {
        XCTAssertNil(CompanyStats.marketCap(shares: nil, lastPrice: 170))
        XCTAssertNil(CompanyStats.marketCap(shares: 24.6e9, lastPrice: nil))
        XCTAssertNil(CompanyStats.marketCap(shares: nil, lastPrice: nil))
        // Non-positive and non-finite inputs never fabricate a figure.
        XCTAssertNil(CompanyStats.marketCap(shares: 0, lastPrice: 170))
        XCTAssertNil(CompanyStats.marketCap(shares: -1e9, lastPrice: 170))
        XCTAssertNil(CompanyStats.marketCap(shares: 24.6e9, lastPrice: 0))
        XCTAssertNil(CompanyStats.marketCap(shares: .nan, lastPrice: 170))
        XCTAssertNil(CompanyStats.marketCap(shares: 24.6e9, lastPrice: .infinity))
    }

    func testAbbrevCountFormatsShareCountsWithoutDollar() {
        XCTAssertEqual(CompanyStats.abbrevCount(nil), "—")
        XCTAssertEqual(CompanyStats.abbrevCount(.nan), "—")
        XCTAssertEqual(CompanyStats.abbrevCount(24.6e9), "24.6B")
        XCTAssertEqual(CompanyStats.abbrevCount(8.9e8), "890M")
        XCTAssertEqual(CompanyStats.abbrevCount(1.5e6), "1.50M")
        XCTAssertEqual(CompanyStats.abbrevCount(12_500), "12.5K")
        XCTAssertEqual(CompanyStats.abbrevCount(950), "950")
        // A share COUNT is never money — no dollar sign, ever.
        XCTAssertFalse(CompanyStats.abbrevCount(24.6e9).contains("$"))
    }

    func testFloatLabelsSeparateDollarFromShareAxis() {
        // Float on the SHARE axis (count / %) reads as float, NOT dollars; the
        // demoted $ float cell is the only one carrying a dollar sign.
        XCTAssertTrue(CompanyStats.floatSharesLabel.lowercased().contains("float"))
        XCTAssertFalse(CompanyStats.floatSharesLabel.contains("$"))
        XCTAssertTrue(CompanyStats.floatPctLabel.lowercased().contains("float"))
        XCTAssertTrue(CompanyStats.floatUsdLabel.contains("$"))
        // The share-count stat is the one that says "share".
        XCTAssertTrue(CompanyStats.sharesLabel.lowercased().contains("share"))
    }

    func testFloatSharesDerivationIsNilSafe() {
        // ≈ dollar float ÷ last price. $2.6T / $220 ≈ 11.8B shares.
        let fs = try? XCTUnwrap(CompanyStats.floatShares(floatUSD: 2.6e12, lastPrice: 220))
        XCTAssertEqual(fs ?? .nan, 2.6e12 / 220, accuracy: 1)
        XCTAssertNil(CompanyStats.floatShares(floatUSD: nil, lastPrice: 220))
        XCTAssertNil(CompanyStats.floatShares(floatUSD: 2.6e12, lastPrice: nil))
        XCTAssertNil(CompanyStats.floatShares(floatUSD: 0, lastPrice: 220))
        XCTAssertNil(CompanyStats.floatShares(floatUSD: -1, lastPrice: 220))
        XCTAssertNil(CompanyStats.floatShares(floatUSD: .nan, lastPrice: 220))
        XCTAssertNil(CompanyStats.floatShares(floatUSD: 2.6e12, lastPrice: 0))
    }

    func testFlowColumnWalkableFirstOrdering() {
        // Walkable rows (with a ticker → can pivot the board) lead, then alpha.
        let rels = [
            Relation(symbol: nil, name: "Zeta Private", via: "x"),
            Relation(symbol: "AMD", name: "Advanced Micro", via: "y"),
            Relation(symbol: nil, name: "Acme Private", via: "z"),
            Relation(symbol: "TSM", name: "TSMC", via: "w"),
        ]
        let ordered = FlowColumn.walkableFirst(rels)
        XCTAssertEqual(ordered.map(\.name), ["Advanced Micro", "TSMC", "Acme Private", "Zeta Private"])
        // Walkable block first, non-walkable block second; each block alphabetical.
        XCTAssertNotNil(ordered[0].symbol)
        XCTAssertNotNil(ordered[1].symbol)
        XCTAssertNil(ordered[2].symbol)
        XCTAssertNil(ordered[3].symbol)
    }

    func testValuationRatiosDerivedHonestlyNilSafe() {
        // P/E = price ÷ EPS; nil for zero/negative EPS (never a fabricated ratio).
        XCTAssertEqual(try XCTUnwrap(CompanyStats.peRatio(lastPrice: 200, eps: 8)), 25, accuracy: 1e-9)
        XCTAssertNil(CompanyStats.peRatio(lastPrice: 200, eps: 0))
        XCTAssertNil(CompanyStats.peRatio(lastPrice: 200, eps: -3))
        XCTAssertNil(CompanyStats.peRatio(lastPrice: nil, eps: 8))
        // cap ratios (P/S over revenue, P/B over equity).
        XCTAssertEqual(try XCTUnwrap(CompanyStats.capRatio(4.0e12, over: 4.0e11)), 10, accuracy: 1e-9)
        XCTAssertNil(CompanyStats.capRatio(4.0e12, over: 0))
        XCTAssertNil(CompanyStats.capRatio(nil, over: 4.0e11))
        // book value / share = equity ÷ shares.
        XCTAssertEqual(try XCTUnwrap(CompanyStats.bookValuePerShare(equity: 7.0e10, shares: 1.4e10)), 5, accuracy: 1e-9)
        XCTAssertNil(CompanyStats.bookValuePerShare(equity: 7.0e10, shares: 0))
        // ratio label formats with a × and dims on nil.
        XCTAssertEqual(CompanyStats.ratioLabel(28.4), "28.4×")
        XCTAssertEqual(CompanyStats.ratioLabel(nil), "—")
    }

    func testFloatPctIsBoundedAndNilSafe() {
        // Float shares 11.8B of 15.1B outstanding ≈ 78% — always < 1 for a real
        // company (float is a subset of outstanding).
        let pct = try? XCTUnwrap(CompanyStats.floatPct(floatShares: 1.18e10, sharesOutstanding: 1.51e10))
        XCTAssertEqual(pct ?? .nan, 0.781, accuracy: 0.01)
        XCTAssertLessThan(pct ?? 2, 1.0)
        XCTAssertNil(CompanyStats.floatPct(floatShares: nil, sharesOutstanding: 1.51e10))
        XCTAssertNil(CompanyStats.floatPct(floatShares: 1.18e10, sharesOutstanding: 0))
        XCTAssertNil(CompanyStats.floatPct(floatShares: .nan, sharesOutstanding: 1.51e10))
    }

    // MARK: - Filings ordering (newest-first, defensive)

    func testFilingsOrderedNewestFirst() {
        let filings = [
            Filing(form: "10-K", filed: "2025-02-26", primary_doc_url: "https://x/a"),
            Filing(form: "8-K", filed: "2025-05-28", primary_doc_url: "https://x/b"),
            Filing(form: "10-Q", filed: "2025-05-28", primary_doc_url: "https://x/c"),
        ]
        let ordered = CompanyFilings.ordered(filings)
        // Newest date first; the same-date pair breaks the tie on form
        // ("10-Q" < "8-K" lexically), keeping the order stable.
        XCTAssertEqual(ordered.map(\.form), ["10-Q", "8-K", "10-K"])
    }

    func testFilingsOrderingEmpty() {
        XCTAssertTrue(CompanyFilings.ordered([]).isEmpty)
    }

    // MARK: - Company news filter (symbol + name match, capped)

    private func news(_ symbol: String?, _ title: String, ts: Int64) -> NewsItem {
        NewsItem(
            symbol: symbol, title: title, source_domain: "reuters.com",
            url: "https://reuters.com/x", tone: 0, ts_ms: ts
        )
    }

    func testCompanyNewsFilterMatchesSymbolAndName() {
        let items = [
            news("NVDA", "chip demand rises", ts: 300),          // symbol
            news(nil, "NVIDIA unveils new GPU", ts: 400),        // name (core)
            news("AMD", "AMD launches accelerator", ts: 500),    // no match
            news("nvda", "earnings beat", ts: 200),              // symbol, case-insensitive
            news(nil, "broad market selloff", ts: 600),          // no match
        ]
        let out = CompanyNews.filter(items, symbol: "NVDA", name: "NVIDIA Corporation")
        // Newest-first among the three matches; AMD + generic markets excluded.
        XCTAssertEqual(out.map(\.title), [
            "NVIDIA unveils new GPU", "chip demand rises", "earnings beat",
        ])
    }

    func testCompanyNewsFilterCaps() {
        let items = (0..<20).map { news("NVDA", "headline \($0)", ts: Int64($0)) }
        XCTAssertEqual(CompanyNews.filter(items, symbol: "NVDA", name: "NVIDIA", cap: 8).count, 8)
    }

    func testCompanyNewsFilterEmptyWhenNothingMatches() {
        let items = [news("AMD", "AMD news", ts: 1), news(nil, "market note", ts: 2)]
        XCTAssertTrue(CompanyNews.filter(items, symbol: "NVDA", name: "NVIDIA Corporation").isEmpty)
    }

    func testCompanyNewsCoreNameStripsCorporateSuffixes() {
        XCTAssertEqual(CompanyNews.coreName("NVIDIA Corporation"), "NVIDIA")
        XCTAssertEqual(CompanyNews.coreName("Apple Inc."), "Apple")
        XCTAssertEqual(CompanyNews.coreName("The Coca-Cola Company"), "Coca-Cola")
        // Nothing to strip — the full name passes through.
        XCTAssertEqual(CompanyNews.coreName("Tesla"), "Tesla")
    }

    func testCompanyNewsNameMatchIsWordBoundaryNotSubstring() {
        // Short/common core names must NOT substring-match inside a larger word:
        // "PHP" contains "HP", "advisable"/"revisable" contain "visa",
        // "blockchain"/"roadblock" contain "block" — none should surface.
        let items = [
            news(nil, "PHP 8.4 released", ts: 10),
            news(nil, "advisable to revisable positions", ts: 20),
            news(nil, "blockchain roadblock ahead", ts: 30),
        ]
        XCTAssertTrue(CompanyNews.filter(items, symbol: "HPQ", name: "HP Inc.").isEmpty)
        XCTAssertTrue(CompanyNews.filter(items, symbol: "V", name: "Visa Inc.").isEmpty)
        XCTAssertTrue(CompanyNews.filter(items, symbol: "XYZ", name: "Block, Inc.").isEmpty)
    }

    func testCompanyNewsNameMatchStillHitsRealMentions() {
        // Genuine whole-word mentions (including a hyphenated core) still match.
        let items = [
            news(nil, "HP Inc. raises guidance", ts: 10),        // full name
            news(nil, "Visa beats estimates", ts: 20),           // core, on boundary
            news(nil, "Coca-Cola lifts dividend", ts: 30),       // hyphenated core
        ]
        XCTAssertEqual(
            CompanyNews.filter(items, symbol: "HPQ", name: "HP Inc.").map(\.title),
            ["HP Inc. raises guidance"]
        )
        XCTAssertEqual(
            CompanyNews.filter(items, symbol: "V", name: "Visa Inc.").map(\.title),
            ["Visa beats estimates"]
        )
        XCTAssertEqual(
            CompanyNews.filter(items, symbol: "KO", name: "The Coca-Cola Company").map(\.title),
            ["Coca-Cola lifts dividend"]
        )
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
