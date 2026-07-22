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

    private func tabBar(_ tabs: [CompanyTab], active: CompanyTab) -> some View {
        HStack(spacing: 4) {
            ForEach(tabs) { t in
                DeckSegment(title: t.title, isOn: active == t) {
                    withAnimation(DeckMotion.ease()) { tab = t }
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .padding(.horizontal, 13)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func tabContent(_ p: CompanyProfile, _ active: CompanyTab) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                switch active {
                case .overview: overviewTab(p)
                case .financials:
                    fundamentalsSection(p)
                    filingsSection(p)
                case .statistics: statisticsSection(p)
                case .supplyChain: supplyChainTab(p)
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(16)
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

    @ViewBuilder
    private func supplyChainTab(_ p: CompanyProfile) -> some View {
        GeometryReader { geo in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    if geo.size.width >= 720 {
                        HStack(alignment: .top, spacing: 18) {
                            CollapsibleSection("suppliers", count: p.suppliers.count) {
                                relationList(p.suppliers)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            CollapsibleSection("customers", count: p.customers.count) {
                                relationList(p.customers)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    } else {
                        CollapsibleSection("suppliers", count: p.suppliers.count) {
                            relationList(p.suppliers)
                        }
                        CollapsibleSection("customers", count: p.customers.count) {
                            relationList(p.customers)
                        }
                    }
                    CollapsibleSection("competitors", count: p.competitors.count, startsExpanded: false) {
                        competitorsGrid(p.competitors)
                    }
                }
            }
        }
        .frame(minHeight: 320)
    }

    /// The relation card list (preserves the openCompany graph-walk).
    @ViewBuilder
    private func relationList(_ relations: [Relation]) -> some View {
        if relations.isEmpty {
            Text("none curated").font(.system(size: 10)).foregroundStyle(Theme.dim)
        } else {
            LazyVStack(spacing: 8) {
                ForEach(relations) { relation in
                    RelationCard(relation: relation) { symbol in model.openCompany(symbol) }
                }
            }
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

    @ViewBuilder
    private func fundamentalsSection(_ p: CompanyProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionLabel(text: "fundamentals")
                if let f = p.fundamentals {
                    Text("\(f.period) · FY\(f.fiscal_year)")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.dim)
                }
            }
            if let f = p.fundamentals {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .leading), count: 3),
                    alignment: .leading, spacing: 12
                ) {
                    metric("revenue", CompanyFormat.abbrevMoney(f.revenue))
                    metric("rev yoy", CompanyFormat.pct(f.revenue_yoy, signed: true),
                           tint: f.revenue_yoy.map { Theme.pnlColor($0) })
                    metric("gross margin", CompanyFormat.pct(f.gross_margin))
                    metric("op margin", CompanyFormat.pct(f.op_margin))
                    metric("net margin", CompanyFormat.pct(f.net_margin))
                    metric("eps", CompanyFormat.plain(f.eps))
                    metric("net income", CompanyFormat.abbrevMoney(f.net_income))
                    metric("op cash flow", CompanyFormat.abbrevMoney(f.ocf))
                    metric("cash", CompanyFormat.abbrevMoney(f.cash))
                    metric("assets", CompanyFormat.abbrevMoney(f.assets))
                    metric("liabilities", CompanyFormat.abbrevMoney(f.liabilities))
                    metric("equity", CompanyFormat.abbrevMoney(f.equity))
                }
                .padding(12)
                .panel()
            } else {
                Text("no fundamentals available")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
            }
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
        if f?.shares_outstanding != nil || f?.public_float_usd != nil {
            let px = model.lastPrice(p.symbol)
            let cap = CompanyStats.marketCap(shares: f?.shares_outstanding, lastPrice: px)
            // Float on the SHARE axis so it reads correctly BELOW shares out.
            let fShares = CompanyStats.floatShares(floatUSD: f?.public_float_usd, lastPrice: px)
            let fPct = CompanyStats.floatPct(floatShares: fShares, sharesOutstanding: f?.shares_outstanding)
            // Honesty gate: if the derived float exceeds ~102% of shares out, the
            // stale-price estimate has broken down — suppress the derived cells
            // (show —) and keep only the exact reported dollar figure.
            let derivedOK = (fPct ?? 0) <= 1.02
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "statistics")
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .leading), count: 3),
                    alignment: .leading, spacing: 12
                ) {
                    CompanyStatCell(
                        label: CompanyStats.marketCapLabel,
                        value: CompanyFormat.abbrevMoney(cap),
                        note: CompanyStats.marketCapNote
                    )
                    CompanyStatCell(
                        label: CompanyStats.sharesLabel,
                        value: CompanyStats.abbrevCount(f?.shares_outstanding),
                        note: CompanyStats.sharesNote
                    )
                    CompanyStatCell(
                        label: CompanyStats.floatSharesLabel,
                        value: derivedOK ? "≈ " + CompanyStats.abbrevCount(fShares) : "—",
                        note: CompanyStats.floatSharesNote
                    )
                    CompanyStatCell(
                        label: CompanyStats.floatPctLabel,
                        value: derivedOK ? CompanyFormat.pct(fPct) : "—",
                        note: CompanyStats.floatPctNote
                    )
                    CompanyStatCell(
                        label: CompanyStats.floatUsdLabel,
                        value: CompanyFormat.abbrevMoney(f?.public_float_usd),
                        note: CompanyStats.floatUsdNote
                    )
                }
                .padding(12)
                .panel()
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

// MARK: - Relation card

private struct RelationCard: View {
    let relation: Relation
    let open: (String) -> Void
    @State private var hovering = false

    var body: some View {
        if let symbol = relation.symbol {
            Button {
                open(symbol)
            } label: {
                content(clickable: true)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(DeckMotion.ease(), value: hovering)
        } else {
            content(clickable: false)
        }
    }

    private func content(clickable: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(relation.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.bone)
                    .lineLimit(1)
                Text(relation.via)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if clickable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hovering ? Theme.ember : Theme.dim)
                    .padding(.top, 3)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .panel(highlighted: clickable && hovering)
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
