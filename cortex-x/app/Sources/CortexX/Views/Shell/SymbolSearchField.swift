// Global symbol search — the always-visible way to load ANY stock or crypto
// onto the chart from anywhere in the app. The watchlist sidebar (the only other
// search) can be collapsed, and the chart header's symbol only opens COMPANY, so
// without this there is no discoverable "search a ticker" affordance. Lives in
// the TopBar, top-left (Bloomberg / TradingView convention). Type to filter the
// watchlist + scan universe, ↑/↓ to move the highlight, ⏎ loads the highlighted
// hit onto the chart; an unknown-but-valid ticker loads on-demand history AND
// opens COMPANY (EDGAR resolves any US filer, so a lookup is never a dead end).
// ⌘K focuses it from anywhere. Selecting always switches to the chart so the
// operator sees the symbol they searched for.

import SwiftUI

struct SymbolSearchField: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    /// A resolved search hit: the symbol plus a small provenance tag.
    struct Hit: Identifiable, Equatable {
        let symbol: String
        let kind: Kind
        var id: String { symbol }
        enum Kind: String { case crypto = "CRYPTO", stock = "STOCK", lookup = "LOOKUP" }
    }

    private var query: String { text.trimmingCharacters(in: .whitespaces).uppercased() }

    /// Watchlist matches first (already streaming), then the scan universe, then
    /// — if nothing matches but the text is a plausible ticker — an on-demand
    /// lookup. Deduped, capped so the dropdown stays compact.
    private var hits: [Hit] {
        guard !query.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [Hit] = []
        func add(_ s: String) {
            let u = s.uppercased()
            guard !seen.contains(u) else { return }
            seen.insert(u)
            out.append(Hit(symbol: u, kind: AppModel.isEquity(u) ? .stock : .crypto))
        }
        for s in model.symbols where s.uppercased().contains(query) { add(s) }
        for s in model.searchUniverse where s.uppercased().contains(query) { add(s) }
        if out.isEmpty, Self.isValidTicker(query) {
            out.append(Hit(symbol: query, kind: .lookup))
        }
        return Array(out.prefix(8))
    }

    var body: some View {
        field
            .frame(width: 240)
            .overlay(alignment: .topLeading) {
                if focused, !hits.isEmpty { dropdown.offset(y: 30) }
            }
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(focused ? Theme.ember : Theme.dim)
            TextField("search symbol", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.bone)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: text) { _, _ in highlighted = 0 }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { clear(); return .handled }
            if text.isEmpty {
                Text("⌘K")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.dim.opacity(0.7))
            } else {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.dim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(focused ? Theme.ember.opacity(0.55) : Theme.line, lineWidth: Theme.hairline)
        )
        // ⌘K focuses the field from anywhere (a near-invisible shortcut carrier).
        .background(
            Button(action: { focused = true }) { Color.clear }
                .keyboardShortcut("k", modifiers: .command)
                .frame(width: 1, height: 1)
                .opacity(0.01)
        )
    }

    // MARK: Dropdown

    private var dropdown: some View {
        VStack(spacing: 0) {
            ForEach(Array(hits.enumerated()), id: \.element.id) { i, hit in
                Button { load(hit) } label: {
                    HStack(spacing: 8) {
                        Text(hit.symbol)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.bone)
                        Spacer(minLength: 0)
                        Text(hit.kind.rawValue)
                            .font(.system(size: 8, weight: .semibold))
                            .tracking(1)
                            .foregroundStyle(hit.kind == .lookup ? Theme.ember : Theme.dim)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(i == highlighted ? Theme.panelHi : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 240)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(Theme.line, lineWidth: Theme.hairline)
        )
        .zIndex(10)
    }

    // MARK: Actions

    private func move(_ delta: Int) {
        let n = hits.count
        guard n > 0 else { return }
        highlighted = (highlighted + delta + n) % n
    }

    private func commit() {
        let list = hits
        guard !list.isEmpty else {
            if Self.isValidTicker(query) { load(Hit(symbol: query, kind: .lookup)) }
            return
        }
        load(list[min(highlighted, list.count - 1)])
    }

    private func load(_ hit: Hit) {
        model.selectSymbol(hit.symbol)          // loads the chart (history fetch included)
        if hit.kind == .lookup { model.openCompany(hit.symbol) }
        model.centerMode = .chart               // show the symbol they searched for
        clear()
    }

    private func clear() {
        text = ""
        highlighted = 0
        focused = false
    }

    /// A plausible ticker (A–Z / 0–9 / . / -, 1–10 chars) is loadable even when
    /// absent from the watchlist + universe — on-demand history + COMPANY resolve it.
    static func isValidTicker(_ symbol: String) -> Bool {
        symbol.range(of: "^[A-Z0-9.\\-]{1,10}$", options: .regularExpression) != nil
    }
}
