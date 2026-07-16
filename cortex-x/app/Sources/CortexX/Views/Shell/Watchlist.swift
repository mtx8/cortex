// Left rail: live watchlist (named lists, stars, notes) + feed health
// footer. List membership, stars and notes persist through WatchlistStore;
// the "main" list is the engine's symbol view.

import SwiftUI

struct Watchlist: View {
    @Environment(AppModel.self) private var model
    @State private var store = WatchlistStore()
    @State private var searchText = ""
    @State private var creatingList = false
    @State private var newListName = ""
    @State private var renamingList = false
    @State private var renameText = ""
    @State private var confirmingDelete = false

    private var query: String {
        searchText.trimmingCharacters(in: .whitespaces).uppercased()
    }

    private func matches(_ symbol: String) -> Bool {
        query.isEmpty || symbol.uppercased().contains(query)
    }

    /// Type-to-add accepts free text — gate it to plausible ticker shapes
    /// (e.g. NVDA, BRK.B, BTC-USD) so garbage like "FOO BAR" never enters a
    /// list and triggers on-demand engine fetches on every appearance.
    static func isValidTickerInput(_ symbol: String) -> Bool {
        symbol.range(of: "^[A-Z0-9.\\-]{1,10}$", options: .regularExpression) != nil
    }

    // Asset-class groups (order within each group preserved from the
    // engine; starred rows pin first, the star filter applies).
    private var cryptoSymbols: [String] {
        store.displayOrder(model.symbols.filter { !AppModel.isEquity($0) && matches($0) })
    }
    private var equitySymbols: [String] {
        store.displayOrder(model.symbols.filter { AppModel.isEquity($0) && matches($0) })
    }
    /// Search hits from the scan universe (D1-chartable), watchlist
    /// excluded. Raw hits — the star filter never hides search results.
    private var universeMatches: [String] {
        guard !query.isEmpty else { return [] }
        return model.searchUniverse.filter { $0.uppercased().contains(query) }.prefix(12).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                listMenu
                Spacer(minLength: 0)
                starFilterChip
                PanelCollapseButton(.watchlist)
            }
            .padding(.horizontal, 4)
            searchField
            if let list = store.selectedList {
                customListGroup(list)
            } else {
                mainGroups
            }
            Spacer()
            FeedFooter()
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { ensureListData() }
        .onChange(of: store.selectedListID) { _, _ in ensureListData() }
        .alert("new list", isPresented: $creatingList) {
            TextField("name", text: $newListName)
            Button("create") { store.createList(named: newListName) }
            Button("cancel", role: .cancel) {}
        }
        .alert("rename list", isPresented: $renamingList) {
            TextField("name", text: $renameText)
            Button("rename") {
                if let id = store.selectedListID { store.renameList(id: id, to: renameText) }
            }
            Button("cancel", role: .cancel) {}
        }
        .alert("delete \(store.selectedList?.name ?? "list")?", isPresented: $confirmingDelete) {
            Button("delete", role: .destructive) {
                if let id = store.selectedListID { store.deleteList(id: id) }
            }
            Button("cancel", role: .cancel) {}
        }
    }

    // MARK: - Header (list picker + star filter)

    /// List picker replacing the plain section label: main (engine symbols)
    /// plus every custom list, with create / rename / delete management.
    private var listMenu: some View {
        Menu {
            Button("main") { store.select(nil) }
            ForEach(store.lists) { list in
                Button(list.name) { store.select(list.id) }
            }
            Divider()
            Button {
                newListName = ""
                creatingList = true
            } label: {
                Label("new list", systemImage: "plus.circle")
            }
            if let list = store.selectedList {
                Button {
                    renameText = list.name
                    renamingList = true
                } label: {
                    Label("rename list", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    // Confirmation-gated like create/rename: a single
                    // misclick must never wipe a list irreversibly.
                    confirmingDelete = true
                } label: {
                    Label("delete list", systemImage: "trash")
                }
            }
        } label: {
            HStack(spacing: 4) {
                SectionLabel(text: store.selectedList?.name ?? "watchlist")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.dim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("watchlists")
    }

    private var starFilterChip: some View {
        Button {
            store.toggleStarredOnly()
        } label: {
            Image(systemName: "star.fill")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(store.starredOnly ? Theme.ember : Theme.dim)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("starred only")
    }

    // MARK: - Groups

    @ViewBuilder
    private var mainGroups: some View {
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
    }

    /// A custom list shows its own symbols (search-filtered, starred rows
    /// pinned). Off-watchlist tickers ride the existing on-demand D1 path.
    @ViewBuilder
    private func customListGroup(_ list: UserWatchlist) -> some View {
        let visible = store.displayOrder(list.symbols.filter(matches))
        if !visible.isEmpty {
            symbolGroup(label: "symbols", symbols: visible)
        } else {
            Text(emptyListHint(list))
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
                .padding(.horizontal, 4)
        }
    }

    private func emptyListHint(_ list: UserWatchlist) -> String {
        if !query.isEmpty { return "return adds \(query) to \(list.name)" }
        if list.symbols.isEmpty { return "empty list — search + return adds symbols" }
        return "no starred symbols"
    }

    /// Custom-list rows beyond the engine watchlist carry no streamed bars —
    /// pull on-demand D1 history for any symbol with none at all (no-op
    /// otherwise, so selection changes stay cheap).
    private func ensureListData() {
        guard let list = store.selectedList else { return }
        for symbol in list.symbols { model.ensureSymbolData(symbol) }
    }

    /// Search across the watchlist + scan universe. Return selects the first
    /// visible match; an unknown ticker opens the COMPANY board (EDGAR
    /// resolves any US filer, so lookups are never a dead end). While a
    /// custom list is active, return instead adds the symbol to the list
    /// (dedup'd) and selects it — the type-to-add flow.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.dim)
            TextField(store.selectedList == nil ? "search symbols" : "search / add symbols",
                      text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.bone)
                .onSubmit {
                    guard !query.isEmpty else { return }
                    if let list = store.selectedList {
                        // selectSymbol covers the history fetch for tickers
                        // with no bars, so new list members chart on D1.
                        guard Self.isValidTickerInput(query) else { return }
                        store.addSymbol(query, to: list.id)
                        model.selectSymbol(query)
                    } else if let hit = (cryptoSymbols + equitySymbols + universeMatches).first {
                        model.selectSymbol(hit)
                    } else {
                        // Unknown ticker: chart via on-demand D1 history AND
                        // open the COMPANY board (EDGAR resolves any filer).
                        model.selectSymbol(query)
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
                WatchlistRow(symbol: symbol, store: store)
            }
        }
    }
}

private struct WatchlistRow: View {
    @Environment(AppModel.self) private var model
    let symbol: String
    let store: WatchlistStore
    @State private var hovering = false

    private var isSelected: Bool { model.selectedSymbol == symbol }

    var body: some View {
        HStack(spacing: 0) {
            // Fixed leading slot so symbol columns stay aligned: star.fill
            // in ember when starred; a dim outline appears on row hover.
            StarGlyphButton(symbol: symbol, store: store, rowHovering: hovering)
                .frame(width: 18, height: 20)
                .padding(.leading, 2)

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
                .padding(.leading, 4)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Fixed trailing slots so price columns stay aligned across
            // rows: the note editor on hover (always once a note exists),
            // then the COMPANY affordance for equities.
            Group {
                if hovering || !store.note(for: symbol).isEmpty {
                    NoteGlyphButton(symbol: symbol, store: store)
                } else {
                    Color.clear
                }
            }
            .frame(width: 20, height: 20)
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
        .contextMenu { rowMenu }
    }

    /// Star + list membership without leaving the rail. Stars and notes are
    /// symbol-scoped (shared across lists); membership is per list.
    @ViewBuilder
    private var rowMenu: some View {
        Button(store.isStarred(symbol) ? "unstar" : "star") { store.toggleStar(symbol) }
        let addable = store.lists.filter { !$0.symbols.contains(symbol) }
        if !addable.isEmpty {
            Menu("add to list") {
                ForEach(addable) { list in
                    Button(list.name) { store.addSymbol(symbol, to: list.id) }
                }
            }
        }
        if let list = store.selectedList, list.symbols.contains(symbol) {
            Button("remove from \(list.name)") { store.removeSymbol(symbol, from: list.id) }
        }
    }
}

/// Leading star slot: ember star.fill when starred; a dim outline fades in
/// on row hover to toggle. Sits outside the row button so a star click
/// never changes the selection.
private struct StarGlyphButton: View {
    let symbol: String
    let store: WatchlistStore
    let rowHovering: Bool

    var body: some View {
        let starred = store.isStarred(symbol)
        Button {
            store.toggleStar(symbol)
        } label: {
            Image(systemName: starred ? "star.fill" : "star")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(starred ? Theme.ember : Theme.dim)
                .opacity(starred || rowHovering ? 1 : 0)
                .frame(width: 18, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(starred ? "unstar" : "star")
    }
}

/// note.text affordance: opens a popover editor whose text persists through
/// WatchlistStore on every keystroke (an emptied note deletes the entry).
private struct NoteGlyphButton: View {
    let symbol: String
    let store: WatchlistStore
    @State private var showing = false
    @State private var hovering = false
    @State private var draft = ""

    var body: some View {
        Button {
            draft = store.note(for: symbol)
            showing = true
        } label: {
            Image(systemName: "note.text")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? Theme.ember : Theme.dim)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(store.note(for: symbol).isEmpty ? "add note" : "note")
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "\(symbol) note")
                TextEditor(text: $draft)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.bone)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(width: 200, height: 90)
                    .background(Theme.ink)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.chipRadius)
                            .strokeBorder(Theme.line, lineWidth: Theme.hairline)
                    )
            }
            .padding(10)
            .background(Theme.panel)
            .onChange(of: draft) { _, text in store.setNote(text, for: symbol) }
        }
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
