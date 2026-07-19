// TradingView-style multi-chart grid: one, two, or four ChartPanel panes.
// Pane 0 always follows the global selection; the other panes carry their
// own persisted symbol and a per-pane interval override. Clicking a pane
// makes it the ACTIVE pane (ember hairline) and pushes its symbol into the
// global context so the order ticket / intelligence panel follow.

import SwiftUI

/// Fixed pane context handed to a ChartPanel inside the grid. A nil symbol
/// means the pane follows `model.selectedSymbol` (the classic single-chart
/// behavior); a set symbol makes the pane independent, with its own
/// interval override (nil rides the global interval until overridden).
struct ChartPaneState: Equatable {
    var symbol: String?
    var interval: Interval?
}

/// Multi-chart arrangements. Raw values are the @AppStorage("chartLayout")
/// wire format — never rename cases.
enum ChartLayout: String, CaseIterable, Identifiable {
    case single, dual, quad
    var id: String { rawValue }

    var paneCount: Int {
        switch self {
        case .single: 1
        case .dual: 2
        case .quad: 4
        }
    }

    var symbolName: String {
        switch self {
        case .single: "square"
        case .dual: "rectangle.split.2x1"
        case .quad: "square.grid.2x2"
        }
    }

    var help: String {
        switch self {
        case .single: "single chart"
        case .dual: "two charts"
        case .quad: "four charts"
        }
    }
}

struct ChartGrid: View {
    @Environment(AppModel.self) private var model
    @AppStorage("chartLayout") private var layoutRaw = ChartLayout.single.rawValue
    // Fixed-pane symbols persist across launches; "" = unset, which
    // resolves to the nth watchlist symbol once the snapshot lands.
    @AppStorage("chartPane.1.symbol") private var pane1Symbol = ""
    @AppStorage("chartPane.2.symbol") private var pane2Symbol = ""
    @AppStorage("chartPane.3.symbol") private var pane3Symbol = ""
    /// Session-scoped interval overrides for the fixed panes (1...3).
    @State private var paneIntervals: [Interval?] = [nil, nil, nil]
    @State private var activePane = 0
    /// ONE drawing store shared by every pane: DrawingStore commits rewrite
    /// a symbol's whole persisted list from its cache, so two panes on the
    /// same symbol with private stores would clobber each other's drawings.
    @State private var drawingStore = DrawingStore()

    private static let gap: CGFloat = 6

    private var layout: ChartLayout { ChartLayout(rawValue: layoutRaw) ?? .single }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                // The trading-dock feature picker (L1 · DOM · T&S · FLOW + dock
                // collapse). Self-contained via @AppStorage, so the grid stays
                // stateless about the dock.
                ChartDockPicker()
                layoutSwitcher
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            grid
        }
        .onChange(of: layoutRaw) { _, _ in
            // A shrinking layout can strand the active pane off-grid.
            if activePane >= layout.paneCount { activePane = 0 }
        }
    }

    // MARK: - Grid

    @ViewBuilder
    private var grid: some View {
        switch layout {
        case .single:
            ChartPanel(drawingStore: drawingStore)
        case .dual:
            HStack(spacing: Self.gap) {
                paneView(0)
                paneView(1)
            }
        case .quad:
            // Explicit 2x2 cell sizing. A plain VStack-of-HStacks of greedy,
            // GeometryReader-backed panes (each CandleChart wraps one) does NOT
            // converge in SwiftUI's layout engine: the two flexible rows and
            // their flexible panes renegotiate ideal sizes every pass, pegging
            // a layout worker thread at ~100% CPU forever (single/dual don't
            // nest flexible stacks, so they settle). Handing each pane a fixed
            // half-minus-gap frame removes every free variable, so the solver
            // has nothing to iterate and the grid settles immediately.
            GeometryReader { geo in
                let cellW = max(0, (geo.size.width - Self.gap) / 2)
                let cellH = max(0, (geo.size.height - Self.gap) / 2)
                VStack(spacing: Self.gap) {
                    HStack(spacing: Self.gap) {
                        paneView(0).frame(width: cellW, height: cellH)
                        paneView(1).frame(width: cellW, height: cellH)
                    }
                    HStack(spacing: Self.gap) {
                        paneView(2).frame(width: cellW, height: cellH)
                        paneView(3).frame(width: cellW, height: cellH)
                    }
                }
            }
        }
    }

    /// One grid pane: pane 0 is the classic global-selection chart, the
    /// rest are fixed panes. The active pane wears an ember hairline over
    /// the panel's own line border; any click focuses the pane.
    private func paneView(_ index: Int) -> some View {
        Group {
            if index == 0 {
                ChartPanel(drawingStore: drawingStore)
            } else {
                ChartPanel(pane: paneBinding(index), drawingStore: drawingStore)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .strokeBorder(
                    activePane == index ? Theme.ember : Color.clear,
                    lineWidth: Theme.hairline
                )
        )
        .simultaneousGesture(TapGesture().onEnded { activate(index) })
    }

    /// Focus a pane and push its symbol into the global context so the
    /// order ticket / intelligence follow. Pane 0 already IS the global
    /// context, so it only takes focus. Sets `selectedSymbol` directly —
    /// `selectSymbol`'s sparse-series fallback would jump the GLOBAL
    /// interval, which a pane click must never do; symbols with no bars
    /// still get their on-demand history via ensureSymbolData.
    private func activate(_ index: Int) {
        activePane = index
        guard index > 0 else { return }
        let symbol = resolvedSymbol(index)
        guard symbol != model.selectedSymbol else { return }
        model.selectedSymbol = symbol
        model.ensureSymbolData(symbol)
    }

    // MARK: - Pane state plumbing

    private func paneBinding(_ index: Int) -> Binding<ChartPaneState> {
        Binding(
            get: {
                ChartPaneState(
                    symbol: resolvedSymbol(index),
                    interval: paneIntervals[index - 1]
                )
            },
            set: { state in
                if Self.shouldPersistPaneSymbol(
                    state.symbol, resolvedDefault: resolvedSymbol(index)
                ) {
                    storeSymbol(state.symbol ?? "", index)
                }
                paneIntervals[index - 1] = state.interval
            }
        )
    }

    /// Stickiness rule for the persisted pane symbol. The getter always
    /// hands out the RESOLVED symbol, so interval-only writes echo it back
    /// through the setter — persisting that echo would permanently pin an
    /// unset pane to whatever it happened to resolve to. Only a genuine
    /// symbol change is stored.
    static func shouldPersistPaneSymbol(
        _ symbol: String?, resolvedDefault: String
    ) -> Bool {
        guard let symbol, !symbol.isEmpty else { return false }
        return symbol != resolvedDefault
    }

    /// The pane's persisted symbol; unset panes default to the nth
    /// watchlist symbol (falling back to the global selection while the
    /// engine list is still loading).
    private func resolvedSymbol(_ index: Int) -> String {
        let stored = [pane1Symbol, pane2Symbol, pane3Symbol][index - 1]
        if !stored.isEmpty { return stored }
        return index < model.symbols.count ? model.symbols[index] : model.selectedSymbol
    }

    private func storeSymbol(_ symbol: String, _ index: Int) {
        switch index {
        case 1: pane1Symbol = symbol
        case 2: pane2Symbol = symbol
        default: pane3Symbol = symbol
        }
    }

    // MARK: - Layout switcher

    private var layoutSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(ChartLayout.allCases) { candidate in
                layoutChip(candidate)
            }
        }
        .padding(2)
        .background(Theme.ink)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(Theme.line, lineWidth: Theme.hairline)
        )
    }

    private func layoutChip(_ candidate: ChartLayout) -> some View {
        Button {
            layoutRaw = candidate.rawValue
        } label: {
            Image(systemName: candidate.symbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(layout == candidate ? Theme.bone : Theme.dim)
                .frame(width: 22, height: 18)
                .background(layout == candidate ? Theme.panelHi : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(candidate.help)
    }
}
