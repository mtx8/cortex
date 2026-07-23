// COMPANY — Bloomberg-SPLC-class company intelligence board.
// suppliers | the company (segments + fundamentals) | customers.
// Relation cards with known tickers walk the graph (openCompany).
// Sources are footnoted — honesty is a feature.

import SwiftUI

// MARK: - Pure helpers (internal for tests)

enum CompanyFormat {
    /// Abbreviated money: $1.23T / $25.0B / $890M / $12.5K. nil -> em dash, never 0.
    static func abbrevMoney(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        let a = abs(v)
        let sign = v < 0 ? "-" : ""
        func fmt(_ x: Double, _ suffix: String) -> String {
            let s: String
            if x >= 100 { s = String(format: "%.0f", x) }
            else if x >= 10 { s = String(format: "%.1f", x) }
            else { s = String(format: "%.2f", x) }
            return sign + "$" + s + suffix
        }
        if a >= 1e12 { return fmt(a / 1e12, "T") }
        if a >= 1e9 { return fmt(a / 1e9, "B") }
        if a >= 1e6 { return fmt(a / 1e6, "M") }
        if a >= 1e3 { return fmt(a / 1e3, "K") }
        return sign + "$" + String(format: "%.0f", a)
    }

    /// Fraction (0.564) -> "56.4%". nil -> em dash.
    static func pct(_ fraction: Double?, signed: Bool = false) -> String {
        guard let f = fraction, f.isFinite else { return "—" }
        return String(format: signed ? "%+.1f%%" : "%.1f%%", f * 100)
    }

    /// Plain decimal (EPS). nil -> em dash.
    static func plain(_ v: Double?, decimals: Int = 2) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%.\(decimals)f", v)
    }

    /// Crypto / uncurated profiles: no graph, no segments — fundamentals-only layout.
    static func isMinimal(_ p: CompanyProfile) -> Bool {
        p.suppliers.isEmpty && p.customers.isEmpty && p.segments.isEmpty
    }
}

// MARK: - View

struct CompanyView: View {
    @Environment(AppModel.self) private var model
    /// Active board tab. Falls back to overview when the current company lacks the
    /// selected tab (graph-walking to a company with less data). Reset on symbol.
    @State private var tab: CompanyTab = .default

    /// Stale-card guard: a profile only renders for the company being
    /// inspected (companySymbol — NOT the watchlist selection, so graph
    /// walking to off-watchlist tickers like TSM resolves correctly).
    private var profile: CompanyProfile? {
        guard let c = model.company, c.symbol == model.companySymbol else { return nil }
        return c
    }

    var body: some View {
        Group {
            if let profile {
                board(profile)
            } else if model.companyLoading || model.company != nil {
                loadingState
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
        .task(id: model.companySymbol) {
            if model.companySymbol.isEmpty {
                model.companySymbol = model.selectedSymbol
            } else if profile == nil {
                model.requestCompany(model.companySymbol)
            }
        }
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(Theme.ember)
            Text("assembling intelligence…")
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            SectionLabel(text: "company")
            Text("no company intelligence for \(model.companySymbol)")
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
            Text("select a symbol — the board assembles on demand")
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Board

    private func board(_ p: CompanyProfile) -> some View {
        let tabs = CompanyTab.available(for: p)
        // Clamp: walking the graph to a company without the active tab falls back
        // to overview rather than showing an empty pane.
        let active = tabs.contains(tab) ? tab : .overview
        return VStack(alignment: .leading, spacing: 0) {
            header(p)
            Divider().overlay(Theme.line)
            if tabs.count > 1 {
                tabBar(tabs, active: active)
                Divider().overlay(Theme.line)
            }
            tabContent(p, active)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider().overlay(Theme.line)
            footer(p)
        }
        .onChange(of: model.companySymbol) { _, _ in tab = .default }
    }

    // MARK: Tab bar + content router

    /// Bloomberg/Yahoo-style underline nav: uppercase letterspaced labels, bone
    /// when active over a 2px ember underline, dim otherwise — no pills, no fills.
    private func tabBar(_ tabs: [CompanyTab], active: CompanyTab) -> some View {
        HStack(spacing: 22) {
            ForEach(tabs) { t in
                CompanyTabButton(title: t.title, active: active == t) {
                    withAnimation(DeckMotion.ease()) { tab = t }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func tabContent(_ p: CompanyProfile, _ active: CompanyTab) -> some View {
        if active == .supplyChain {
            // Full-bleed: the supply-chain flow owns the whole board width + its
            // own scroll (a GeometryReader inside a vertical ScrollView collapses).
            supplyChainTab(p)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    switch active {
                    case .overview: overviewTab(p)
                    case .financials:
                        fundamentalsSection(p)
                        filingsSection(p)
                    case .statistics: statisticsSection(p)
                    case .supplyChain: EmptyView() // handled above
                    }
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(16)
            }
        }
    }

    // MARK: Overview tab

    @ViewBuilder
    private func overviewTab(_ p: CompanyProfile) -> some View {
        if !p.description.isEmpty {
            // Left-aligned lede on a reading measure — shares ONE leading edge
            // with the strip/segments below (no more screen-centered description).
            Text(p.description)
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
                .lineSpacing(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 720, alignment: .leading)
        }
        overviewStatStrip(p)
        segmentsSection(p.segments)
        newsSection(p)
    }

    /// A compact glance strip for the overview: market cap · revenue · rev yoy ·
    /// net margin. Reuses the shared metric cell; the fuller grids live under the
    /// FINANCIALS and STATISTICS tabs.
    @ViewBuilder
    private func overviewStatStrip(_ p: CompanyProfile) -> some View {
        let f = p.fundamentals
        let cap = CompanyStats.marketCap(shares: f?.shares_outstanding, lastPrice: model.lastPrice(p.symbol))
        if cap != nil || f != nil {
            HStack(alignment: .top, spacing: 24) {
                metric("market cap", CompanyFormat.abbrevMoney(cap))
                if let f {
                    metric("revenue", CompanyFormat.abbrevMoney(f.revenue))
                    metric("rev yoy", CompanyFormat.pct(f.revenue_yoy, signed: true),
                           tint: f.revenue_yoy.map { Theme.pnlColor($0) })
                    metric("net margin", CompanyFormat.pct(f.net_margin))
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .panel()
        }
    }

    // MARK: Supply-chain tab (suppliers / customers / competitors, collapsible)

    // MARK: Supply chain — full-width SUPPLIERS → HUB → CUSTOMERS flow

    @ViewBuilder
    private func supplyChainTab(_ p: CompanyProfile) -> some View {
        GeometryReader { geo in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    if geo.size.width >= 900 { flowRow(p) } else { stackedFlow(p) }
                    Rectangle().fill(Theme.line).frame(height: Theme.hairline)
                    competitorsRow(p)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minHeight: 320)
    }

    /// Wide: suppliers (flex) → gutter → HUB (fixed 300) → gutter → customers (flex).
    private func flowRow(_ p: CompanyProfile) -> some View {
        HStack(alignment: .top, spacing: 0) {
            FlowColumn(title: "suppliers", direction: "upstream · inputs",
                       count: p.suppliers.count, relations: p.suppliers) { model.openCompany($0) }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            flowGutter(.horizontal)
            companyHub(p).frame(width: 300)
            flowGutter(.horizontal)
            FlowColumn(title: "customers", direction: "downstream · demand",
                       count: p.customers.count, relations: p.customers) { model.openCompany($0) }
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// Narrow: the same flow rotated — suppliers ↓ hub ↓ customers.
    private func stackedFlow(_ p: CompanyProfile) -> some View {
        VStack(spacing: 0) {
            FlowColumn(title: "suppliers", direction: "upstream · inputs",
                       count: p.suppliers.count, relations: p.suppliers) { model.openCompany($0) }
            flowGutter(.vertical)
            companyHub(p).frame(maxWidth: .infinity)
            flowGutter(.vertical)
            FlowColumn(title: "customers", direction: "downstream · demand",
                       count: p.customers.count, relations: p.customers) { model.openCompany($0) }
        }
    }

    private enum FlowAxis { case horizontal, vertical }

    /// The directional connector: an ember arrow (the ONE accent, carrying the
    /// "flow" semantic) over a neutral hairline. Inputs read left→right / top→down.
    private func flowGutter(_ axis: FlowAxis) -> some View {
        Group {
            if axis == .horizontal {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.ember)
                        .padding(.top, 24)
                    Rectangle().fill(Theme.line).frame(width: Theme.hairline, height: 40)
                }
                .frame(width: 44)
            } else {
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ember)
                    .padding(.vertical, 10)
            }
        }
    }

    /// The center company node: relationship counts, key vitals, and what it
    /// makes — the pivot the two wings flow into.
    private func companyHub(_ p: CompanyProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                hubStat("\(p.suppliers.count)", "suppliers")
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.dim)
                hubStat("\(p.customers.count)", "customers")
                Spacer(minLength: 0)
                Text(p.symbol)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
            if let f = p.fundamentals {
                HStack(spacing: 16) {
                    if f.revenue != nil { metric("revenue", CompanyFormat.abbrevMoney(f.revenue)) }
                    metric("rev yoy", CompanyFormat.pct(f.revenue_yoy, signed: true),
                           tint: f.revenue_yoy.map { Theme.pnlColor($0) })
                    let cap = CompanyStats.marketCap(shares: f.shares_outstanding, lastPrice: model.lastPrice(p.symbol))
                    if cap != nil { metric("market cap", CompanyFormat.abbrevMoney(cap)) }
                }
            }
            Rectangle().fill(Theme.line).frame(height: Theme.hairline)
            SectionLabel(text: "what it makes")
            if p.segments.isEmpty {
                Text("no segments curated").font(.system(size: 10)).foregroundStyle(Theme.dim)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(p.segments) { seg in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(seg.name).font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.bone).lineLimit(1)
                            Text(seg.note).font(.system(size: 10)).foregroundStyle(Theme.dim)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Text("graph: \(p.graph_source)").font(.system(size: 9)).foregroundStyle(Theme.dim)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        // Neutral hairline — the accent stays on the flow arrows (one accent/element).
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius)
            .strokeBorder(Theme.line, lineWidth: Theme.hairline))
    }

    private func hubStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).numeric(size: 15, weight: .semibold).foregroundStyle(Theme.bone)
            Text(label.uppercased()).font(.system(size: 8, weight: .semibold))
                .tracking(1.0).foregroundStyle(Theme.dim)
        }
    }

    private func competitorsRow(_ p: CompanyProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                SectionLabel(text: "competitors")
                Text("\(p.competitors.count)").numeric(size: 10).foregroundStyle(Theme.dim)
                Spacer(minLength: 0)
            }
            competitorsGrid(p.competitors)
        }
    }

    @ViewBuilder
    private func competitorsGrid(_ competitors: [String]) -> some View {
        if competitors.isEmpty {
            Text("none curated").font(.system(size: 10)).foregroundStyle(Theme.dim)
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 72), spacing: 6)],
                alignment: .leading, spacing: 6
            ) {
                ForEach(competitors, id: \.self) { competitor in
                    CompetitorChip(name: competitor) { model.openCompany(competitor) }
                }
            }
        }
    }

    private func header(_ p: CompanyProfile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(p.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.bone)
                    .lineLimit(1)
                Text(p.symbol)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                if let px = model.lastPrice(p.symbol) {
                    let change = model.sessionChangePct(p.symbol)
                    Text(Fmt.price(px))
                        .numeric(size: 13, weight: .medium)
                        .foregroundStyle(change.map { Theme.pnlColor($0) } ?? Theme.bone)
                    if let change {
                        Text(Fmt.signedPct(change))
                            .numeric(size: 11)
                            .foregroundStyle(Theme.pnlColor(change))
                    }
                }
                Spacer()
                if model.companyLoading {
                    ProgressView().controlSize(.mini).tint(Theme.ember)
                }
            }
            Text(metaLine(p))
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func metaLine(_ p: CompanyProfile) -> String {
        [p.sector, p.industry, p.country]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private func segmentsSection(_ segments: [Segment]) -> some View {
        if !segments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "what it makes")
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 170), spacing: 8)],
                    alignment: .leading, spacing: 8
                ) {
                    ForEach(segments) { segment in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(segment.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.bone)
                                .lineLimit(1)
                            Text(segment.note)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.dim)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
                        .panel()
                    }
                }
            }
        }
    }

    /// A labeled sub-group of stat cells in a 3-col panel — the professional
    /// terminal grammar (INCOME / MARGINS / BALANCE SHEET rather than one flat grid).
    private func statGroup<Content: View>(
        _ title: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: title)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .leading), count: 3),
                alignment: .leading, spacing: 14
            ) {
                content()
            }
            .padding(12)
            .panel()
        }
    }

    @ViewBuilder
    private func fundamentalsSection(_ p: CompanyProfile) -> some View {
        if let f = p.fundamentals {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    SectionLabel(text: "financials")
                    Text("\(f.period) · FY\(f.fiscal_year)")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.dim)
                    Spacer(minLength: 0)
                }
                statGroup("income statement") {
                    CompanyStatCell(label: "revenue", value: CompanyFormat.abbrevMoney(f.revenue), note: "reported")
                    CompanyStatCell(label: "rev yoy", value: CompanyFormat.pct(f.revenue_yoy, signed: true),
                                    note: "year over year", tint: f.revenue_yoy.map { Theme.pnlColor($0) })
                    CompanyStatCell(label: "net income", value: CompanyFormat.abbrevMoney(f.net_income), note: "bottom line")
                    CompanyStatCell(label: "eps", value: CompanyFormat.plain(f.eps), note: "per share")
                    CompanyStatCell(label: "op cash flow", value: CompanyFormat.abbrevMoney(f.ocf), note: "cash from ops")
                }
                statGroup("margins") {
                    CompanyStatCell(label: "gross margin", value: CompanyFormat.pct(f.gross_margin), note: "of revenue")
                    CompanyStatCell(label: "op margin", value: CompanyFormat.pct(f.op_margin), note: "of revenue")
                    CompanyStatCell(label: "net margin", value: CompanyFormat.pct(f.net_margin), note: "of revenue")
                }
                statGroup("balance sheet") {
                    CompanyStatCell(label: "assets", value: CompanyFormat.abbrevMoney(f.assets), note: "total")
                    CompanyStatCell(label: "liabilities", value: CompanyFormat.abbrevMoney(f.liabilities), note: "total")
                    CompanyStatCell(label: "equity", value: CompanyFormat.abbrevMoney(f.equity), note: "shareholder")
                    CompanyStatCell(label: "cash", value: CompanyFormat.abbrevMoney(f.cash), note: "& equivalents")
                }
            }
        } else {
            Text("no fundamentals available")
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
        }
    }

    private func metric(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
            Text(value)
                .numeric(size: 13, weight: .medium)
                .foregroundStyle(value == "—" ? Theme.dim : (tint ?? Theme.bone))
        }
    }

    // MARK: Statistics (client-side market cap + honest labels)

    /// Market cap (shares × last price, computed here), shares outstanding, and
    /// public float. Renders only when the engine supplied a share count or a
    /// float figure — older engines omit both, so the block simply disappears
    /// rather than showing an all-dash panel. Absent sub-values show "—".
    @ViewBuilder
    private func statisticsSection(_ p: CompanyProfile) -> some View {
        let f = p.fundamentals
        let px = model.lastPrice(p.symbol)
        let cap = CompanyStats.marketCap(shares: f?.shares_outstanding, lastPrice: px)
        // Float on the SHARE axis so it reads correctly BELOW shares out.
        let fShares = CompanyStats.floatShares(floatUSD: f?.public_float_usd, lastPrice: px)
        let fPct = CompanyStats.floatPct(floatShares: fShares, sharesOutstanding: f?.shares_outstanding)
        // Honesty gate: if the derived float exceeds ~102% of shares out, the
        // stale-price estimate has broken down — suppress the derived cells (—).
        let derivedOK = (fPct ?? 0) <= 1.02
        VStack(alignment: .leading, spacing: 16) {
            // Valuation — derived ONLY from price + reported fundamentals.
            if let f {
                statGroup("valuation") {
                    CompanyStatCell(label: CompanyStats.marketCapLabel,
                                    value: CompanyFormat.abbrevMoney(cap), note: CompanyStats.marketCapNote)
                    CompanyStatCell(label: "p/e", value: CompanyStats.ratioLabel(
                        CompanyStats.peRatio(lastPrice: px, eps: f.eps)), note: "price ÷ eps")
                    CompanyStatCell(label: "p/s", value: CompanyStats.ratioLabel(
                        CompanyStats.capRatio(cap, over: f.revenue)), note: "cap ÷ revenue")
                    CompanyStatCell(label: "p/b", value: CompanyStats.ratioLabel(
                        CompanyStats.capRatio(cap, over: f.equity)), note: "cap ÷ equity")
                    CompanyStatCell(label: "book / share", value: CompanyFormat.abbrevMoney(
                        CompanyStats.bookValuePerShare(equity: f.equity, shares: f.shares_outstanding)),
                                    note: "equity ÷ shares")
                }
            }
            // Short % of float reuses the derived float-share estimate, so it
            // inherits the float estimate's honesty gate; days-to-cover does not.
            let shortPct = derivedOK
                ? CompanyStats.shortPctFloat(shortInterest: f?.short_interest, floatShares: fShares) : nil
            let dtc = CompanyStats.daysToCover(shortInterest: f?.short_interest, avgVolume: f?.avg_daily_volume)
            statGroup("share statistics") {
                CompanyStatCell(label: CompanyStats.sharesLabel,
                                value: CompanyStats.abbrevCount(f?.shares_outstanding), note: CompanyStats.sharesNote)
                CompanyStatCell(label: CompanyStats.floatSharesLabel,
                                value: derivedOK ? "≈ " + CompanyStats.abbrevCount(fShares) : "—",
                                note: CompanyStats.floatSharesNote)
                CompanyStatCell(label: CompanyStats.floatPctLabel,
                                value: derivedOK ? CompanyFormat.pct(fPct) : "—", note: CompanyStats.floatPctNote)
                CompanyStatCell(label: CompanyStats.floatUsdLabel,
                                value: CompanyFormat.abbrevMoney(f?.public_float_usd), note: CompanyStats.floatUsdNote)
                // Short interest (FINRA, bi-monthly) — renders "—" honestly until
                // the FINRA short-interest fetch is wired.
                CompanyStatCell(label: CompanyStats.shortPctFloatLabel,
                                value: derivedOK ? CompanyFormat.pct(shortPct) : "—",
                                note: CompanyStats.shortAsOfNote(f?.short_interest_date))
                CompanyStatCell(label: CompanyStats.daysToCoverLabel,
                                value: CompanyStats.daysLabel(dtc),
                                note: f?.short_interest == nil
                                    ? CompanyStats.daysToCoverNote
                                    : CompanyStats.shortAsOfNote(f?.short_interest_date))
            }
        }
    }

    // MARK: Latest filings (SEC EDGAR)

    /// Recent EDGAR filings, sorted newest-first defensively. Shown for equities
    /// (where the honest empty state — "no filings from EDGAR" — is meaningful)
    /// or whenever any filing is present; skipped for crypto/uncurated assets.
    @ViewBuilder
    private func filingsSection(_ p: CompanyProfile) -> some View {
        if AppModel.isEquity(p.symbol) || !p.filings.isEmpty {
            let ordered = CompanyFilings.ordered(p.filings)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    SectionLabel(text: "latest filings")
                    if !ordered.isEmpty {
                        Text("\(ordered.count)")
                            .numeric(size: 10)
                            .foregroundStyle(Theme.dim)
                    }
                    Spacer(minLength: 8)
                    if AppModel.isEquity(p.symbol) {
                        AllFilingsButton { model.openFilings(p.symbol) }
                    }
                }
                if ordered.isEmpty {
                    Text("no filings from EDGAR")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.dim)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(ordered) { CompanyFilingRow(filing: $0) }
                    }
                }
            }
        }
    }

    // MARK: Company news

    /// Headlines filtered to this company (symbol tag or name mention), newest-
    /// first and capped, in the shared NEWS row grammar. Honest empty state.
    @ViewBuilder
    private func newsSection(_ p: CompanyProfile) -> some View {
        let items = CompanyNews.filter(
            model.newsBoard?.items ?? [], symbol: p.symbol, name: p.name
        )
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "news")
            if items.isEmpty {
                Text(model.newsBoard == nil
                    ? "waiting for the first wire"
                    : "no headlines tagged \(p.symbol)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { CompanyNewsRow(item: $0, now: context.date) }
                    }
                }
            }
        }
    }

    // MARK: Footer

    private func footer(_ p: CompanyProfile) -> some View {
        HStack(spacing: 10) {
            Text("graph: \(p.graph_source)")
            Text("·")
            Text("fundamentals: \(p.fundamentals_source)")
            Spacer()
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.dim)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - All-filings affordance

/// A quiet "all filings →" link in the LATEST FILINGS header: jumps to the
/// dedicated FILINGS section for this symbol (model.openFilings). Dim, ember on
/// hover — never a standing accent.
private struct AllFilingsButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("ALL FILINGS")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(hovering ? Theme.ember : Theme.dim)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DeckMotion.ease(), value: hovering)
        .help("open the dedicated EDGAR filings desk for this symbol")
    }
}

// MARK: - Competitor chip

private struct CompetitorChip: View {
    let name: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(hovering ? Theme.ember : Theme.bone)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(hovering ? Theme.emberTint : Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.chipRadius)
                        .strokeBorder(Theme.line, lineWidth: Theme.hairline)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DeckMotion.ease(), value: hovering)
    }
}
