// Left rail: live watchlist + feed health footer.

import SwiftUI

struct Watchlist: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""

    private var query: String {
        searchText.trimmingCharacters(in: .whitespaces).uppercased()
    }

    private func matches(_ symbol: String) -> Bool {
        query.isEmpty || symbol.uppercased().contains(query)
    }

    // Asset-class groups (order within each group preserved from the engine).
    private var cryptoSymbols: [String] {
        model.symbols.filter { !AppModel.isEquity($0) && matches($0) }
    }
    private var equitySymbols: [String] {
        model.symbols.filter { AppModel.isEquity($0) && matches($0) }
    }
    /// Search hits from the scan universe (D1-chartable), watchlist excluded.
    private var universeMatches: [String] {
        guard !query.isEmpty else { return [] }
        return model.searchUniverse.filter { $0.uppercased().contains(query) }.prefix(12).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "watchlist")
                .padding(.horizontal, 4)
            searchField
            if !cryptoSymbols.isEmpty {
                symbolGroup(label: "crypto", symbols: cryptoSymbols)
            }
            if !equitySymbols.isEmpty {
                symbolGroup(label: "equities", symbols: equitySymbols)
            }
            if !universeMatches.isEmpty {
                symbolGroup(label: "universe", symbols: universeMatches)
            }
            if !query.isEmpty, cryptoSymbols.isEmpty, equitySymbols.isEmpty, universeMatches.isEmpty {
                Text("no match — return opens \(query) in COMPANY")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 4)
            }
            if model.symbols.isEmpty {
                Text("waiting for engine")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 4)
            }
            Spacer()
            FeedFooter()
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Search across the watchlist + scan universe. Return selects the first
    /// visible match; an unknown ticker opens the COMPANY board (EDGAR
    /// resolves any US filer, so lookups are never a dead end).
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.dim)
            TextField("search symbols", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.bone)
                .onSubmit {
                    guard !query.isEmpty else { return }
                    if let hit = (cryptoSymbols + equitySymbols + universeMatches).first {
                        model.selectSymbol(hit)
                    } else {
                        model.openCompany(query)
                    }
                    searchText = ""
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.dim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
    }

    private func symbolGroup(label: String, symbols: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: label)
                .padding(.horizontal, 4)
            ForEach(symbols, id: \.self) { symbol in
                WatchlistRow(symbol: symbol)
            }
        }
    }
}

private struct WatchlistRow: View {
    @Environment(AppModel.self) private var model
    let symbol: String
    @State private var hovering = false

    private var isSelected: Bool { model.selectedSymbol == symbol }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                model.selectSymbol(symbol)
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(symbol)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(Theme.bone)
                        if let pos = model.positions[symbol], abs(pos.qty) > 1e-12 {
                            Text(pos.qty > 0 ? "Long \(Fmt.qty(abs(pos.qty)))" : "Short \(Fmt.qty(abs(pos.qty)))")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(pos.qty > 0 ? Theme.up : Theme.down)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(model.lastPrice(symbol).map(Fmt.price) ?? "—")
                            .numeric(size: 12, weight: .medium)
                            .foregroundStyle(Theme.bone)
                        if let pct = model.sessionChangePct(symbol) {
                            Text(Fmt.signedPct(pct))
                                .numeric(size: 10)
                                .foregroundStyle(Theme.pnlColor(pct))
                        }
                    }
                }
                .padding(.leading, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Fixed trailing slot so price columns stay aligned across rows;
            // equities get the COMPANY affordance in it on hover.
            Group {
                if AppModel.isEquity(symbol) {
                    CompanyGlyphButton(symbol: symbol)
                        .opacity(hovering ? 1 : 0)
                } else {
                    Color.clear
                }
            }
            .frame(width: 20, height: 20)
            .padding(.trailing, 4)
        }
        .background(isSelected || hovering ? Theme.panelHi : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .onHover { hovering = $0 }
    }
}

/// Small building.2 affordance on equity rows: opens the COMPANY board.
private struct CompanyGlyphButton: View {
    @Environment(AppModel.self) private var model
    let symbol: String
    @State private var hovering = false

    var body: some View {
        Button {
            model.openCompany(symbol)
        } label: {
            Image(systemName: "building.2")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? Theme.ember : Theme.dim)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("company")
    }
}

private struct FeedFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "feeds")
            ForEach(model.feeds.values.sorted { $0.feed < $1.feed }, id: \.feed) { feed in
                HStack(spacing: 6) {
                    Circle()
                        .fill(color(feed.health))
                        .frame(width: 6, height: 6)
                    Text(feed.feed)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.bone)
                    Spacer()
                    Text(label(feed.health))
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.dim)
                }
                .help(feed.detail)
            }
            if model.feeds.isEmpty {
                Text("no feeds yet")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func color(_ h: FeedHealth) -> Color {
        switch h {
        case .live: Theme.up
        case .degraded: Theme.warn
        case .synthetic_fallback: Theme.warn
        case .down: Theme.down
        }
    }

    private func label(_ h: FeedHealth) -> String {
        switch h {
        case .live: "live"
        case .degraded: "degraded"
        case .synthetic_fallback: "synthetic"
        case .down: "down"
        }
    }
}

/// Shared number formatting for the shell (panels may keep their own).
enum Fmt {
    static func price(_ v: Double) -> String {
        let a = abs(v)
        let dp = a >= 100 ? 2 : (a >= 1 ? 4 : 6)
        return v.formatted(.number.precision(.fractionLength(dp)).grouping(.automatic))
    }
    static func qty(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...6)))
    }
    static func signedPct(_ v: Double) -> String {
        (v >= 0 ? "+" : "") + v.formatted(.number.precision(.fractionLength(2))) + "%"
    }
    static func money(_ v: Double) -> String {
        (v < 0 ? "-$" : "$") + abs(v).formatted(.number.precision(.fractionLength(2)).grouping(.automatic))
    }
    static func signedMoney(_ v: Double) -> String {
        (v >= 0 ? "+$" : "-$") + abs(v).formatted(.number.precision(.fractionLength(2)).grouping(.automatic))
    }
}
