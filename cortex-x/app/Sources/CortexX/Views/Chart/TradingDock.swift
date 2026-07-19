// The chart TRADING DOCK: a configurable right-side rail of market-microstructure
// panels stacked BESIDE the multi-chart grid so the operator can watch Level 1,
// the DAS depth-of-market ladder, the time & sales tape, and the AI order-flow
// read while trading — each panel individually toggleable. A compact feature
// picker (in the chart toolbar) chooses which panels show; a single collapse
// hides the whole dock behind a slim re-open handle. The market panels (DOM /
// T&S / FLOW) share ONE book/tape/flow subscription for the selected symbol,
// driven by ChartWorkspace; L1 reads top-of-book, which streams independently.
//
// Pure layout logic (which panels are enabled, whether the dock takes space,
// whether the shared depth subscription is needed) lives in DockPanel/DockState
// below and is unit-tested independent of SwiftUI.

import SwiftUI

// MARK: - Dock panels (pure)

/// One toggleable dock panel. Raw values / storage keys are the @AppStorage
/// wire format — never rename.
enum DockPanel: String, CaseIterable, Identifiable {
    case l1, dom, tape, flow
    var id: String { rawValue }

    /// @AppStorage key backing this panel's on/off state.
    var storageKey: String {
        switch self {
        case .l1: "chartDockL1"
        case .dom: "chartDockDom"
        case .tape: "chartDockTape"
        case .flow: "chartDockFlow"
        }
    }

    /// The uppercase chip / header label.
    var title: String {
        switch self {
        case .l1: "L1"
        case .dom: "DOM"
        case .tape: "T&S"
        case .flow: "FLOW"
        }
    }

    /// Sensible default: DOM + T&S on (a trading feel), L1 / FLOW off. All
    /// persist across launches.
    var defaultOn: Bool {
        switch self {
        case .dom, .tape: true
        case .l1, .flow: false
        }
    }

    /// Whether this panel rides the shared one-symbol depth/tape/flow
    /// subscription. The market panels (DOM / T&S / FLOW) do; the L1 quote strip
    /// reads top-of-book, which streams independently, so it needs no depth.
    var needsDepth: Bool { self != .l1 }

    var help: String {
        switch self {
        case .l1: "level 1 quote"
        case .dom: "depth of market"
        case .tape: "time & sales"
        case .flow: "order flow"
        }
    }
}

/// The four panel toggles as a value, with the pure layout rules the dock and
/// workspace read. Decoupled from @AppStorage/SwiftUI so the enabled-panels,
/// dock-visibility, and depth-needed logic stays unit-tested.
struct DockState: Equatable {
    var l1: Bool
    var dom: Bool
    var tape: Bool
    var flow: Bool

    func isOn(_ panel: DockPanel) -> Bool {
        switch panel {
        case .l1: l1
        case .dom: dom
        case .tape: tape
        case .flow: flow
        }
    }

    /// Enabled panels in fixed top-to-bottom dock order (L1, DOM, T&S, FLOW).
    var enabledPanels: [DockPanel] { DockPanel.allCases.filter(isOn) }

    /// At least one panel enabled — the dock takes chart space only then.
    var anyEnabled: Bool { l1 || dom || tape || flow }

    /// The shared depth/tape/flow subscription is needed when any MARKET panel
    /// (DOM / T&S / FLOW) is enabled. L1 reads top-of-book and never triggers it,
    /// so a dock showing only L1 streams no book.
    var depthNeeded: Bool { dom || tape || flow }

    /// The persisted default posture: DOM + T&S on, L1 + FLOW off.
    static let defaults = DockState(
        l1: DockPanel.l1.defaultOn, dom: DockPanel.dom.defaultOn,
        tape: DockPanel.tape.defaultOn, flow: DockPanel.flow.defaultOn
    )

    /// Whether the dock occupies chart space: at least one panel enabled AND the
    /// whole-dock collapse is not engaged. Pure so the layout rule is tested.
    static func dockVisible(anyEnabled: Bool, hidden: Bool) -> Bool {
        anyEnabled && !hidden
    }
}

// MARK: - Chart workspace (grid + dock + subscription lifecycle)

/// The CHART section: the multi-chart grid (flexes to fill) beside the trading
/// dock (fixed width, present only when a panel is enabled and not collapsed).
/// Owns the shared depth subscription lifecycle so it survives the dock being
/// collapsed and is torn down when the chart section is left.
struct ChartWorkspace: View {
    @Environment(AppModel.self) private var model
    @AppStorage(DockPanel.l1.storageKey) private var l1On = DockPanel.l1.defaultOn
    @AppStorage(DockPanel.dom.storageKey) private var domOn = DockPanel.dom.defaultOn
    @AppStorage(DockPanel.tape.storageKey) private var tapeOn = DockPanel.tape.defaultOn
    @AppStorage(DockPanel.flow.storageKey) private var flowOn = DockPanel.flow.defaultOn
    @AppStorage("chartDockHidden") private var dockHidden = false

    private static let dockWidth: CGFloat = 320
    private static let ease = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.2)

    private var state: DockState {
        DockState(l1: l1On, dom: domOn, tape: tapeOn, flow: flowOn)
    }
    private var depthNeeded: Bool { state.depthNeeded }
    private var dockVisible: Bool {
        DockState.dockVisible(anyEnabled: state.anyEnabled, hidden: dockHidden)
    }

    var body: some View {
        HStack(spacing: 0) {
            ChartGrid()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if dockVisible {
                Rectangle().fill(Theme.line).frame(width: Theme.hairline)
                TradingDock()
                    .frame(width: Self.dockWidth)
            } else if state.anyEnabled {
                // Enabled but collapsed: a slim re-open handle pinned to the edge
                // (mirrors the shell ReopenHandle pattern).
                DockReopenHandle()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Self.ease, value: dockVisible)
        .animation(Self.ease, value: state.anyEnabled)
        // Depth subscription is driven by the dock: the market panels share ONE
        // book/tape/flow subscription for the selected symbol. Subscribe when any
        // is on, re-subscribe on symbol change and on reconnect (a dropped link
        // cleared the old subscription), free the bandwidth when all are off or
        // the chart section is left. Bounded to one active depth symbol.
        .onAppear { syncDepth() }
        .onDisappear { model.unsubscribeDepth() }
        .onChange(of: depthNeeded) { _, _ in syncDepth() }
        .onChange(of: model.selectedSymbol) { _, _ in syncDepth() }
        .onChange(of: model.connection) { _, c in
            if c == .connected, depthNeeded { model.subscribeDepth(model.selectedSymbol) }
        }
    }

    /// Reconcile the shared subscription with the enabled market panels: stream
    /// the selected symbol when any of DOM/T&S/FLOW is on, else free bandwidth.
    /// `subscribeDepth` is idempotent, so redundant calls never thrash the engine.
    private func syncDepth() {
        if depthNeeded {
            model.subscribeDepth(model.selectedSymbol)
        } else {
            model.unsubscribeDepth()
        }
    }
}

// MARK: - The dock (stack of enabled panels)

/// The vertical stack of enabled panels for the selected symbol. Reads the
/// persisted toggles; each panel carries a collapse affordance that turns its
/// own toggle off. Fixed width is set by ChartWorkspace.
struct TradingDock: View {
    @Environment(AppModel.self) private var model
    @AppStorage(DockPanel.l1.storageKey) private var l1On = DockPanel.l1.defaultOn
    @AppStorage(DockPanel.dom.storageKey) private var domOn = DockPanel.dom.defaultOn
    @AppStorage(DockPanel.tape.storageKey) private var tapeOn = DockPanel.tape.defaultOn
    @AppStorage(DockPanel.flow.storageKey) private var flowOn = DockPanel.flow.defaultOn

    private var symbol: String { model.selectedSymbol }
    private var state: DockState {
        DockState(l1: l1On, dom: domOn, tape: tapeOn, flow: flowOn)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(state.enabledPanels.enumerated()), id: \.element.id) { index, panel in
                if index > 0 {
                    Rectangle().fill(Theme.line).frame(height: Theme.hairline)
                }
                section(panel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.ink)
    }

    @ViewBuilder
    private func section(_ panel: DockPanel) -> some View {
        switch panel {
        case .l1:
            // Compact strip — intrinsic height, sits at the top of its slot.
            DockSection(panel: .l1, symbol: symbol, onHide: { l1On = false }) {
                L1QuoteStrip(symbol: symbol)
            }
        case .dom:
            let banner = DepthBanner.make(for: model.bookDepth)
            DockSection(
                panel: .dom, symbol: symbol,
                trailing: AnyView(DepthSourceTag(banner: banner)),
                onHide: { domOn = false }
            ) {
                VStack(spacing: 0) {
                    if banner.kind == .delayed { delayedNote(banner.note) }
                    DomLadder()
                }
            }
            .frame(maxHeight: .infinity)
        case .tape:
            DockSection(panel: .tape, symbol: symbol, onHide: { tapeOn = false }) {
                TimeSalesPane()
            }
            .frame(maxHeight: .infinity)
        case .flow:
            // FlowPanel carries its own header + source banner; the onHide adds
            // the collapse affordance to keep every dock panel toggleable.
            FlowPanel(onHide: { flowOn = false })
                .frame(maxHeight: .infinity)
        }
    }

    /// A calm honest note when depth is delayed L1, so the operator can never
    /// mistake the ladder for real-time book (ember dot + dim text, never a loud
    /// warning color).
    private func delayedNote(_ note: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.ember).frame(width: 5, height: 5)
            Text(note)
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Theme.panel)
    }
}

// MARK: - Dock section chrome

/// Uniform chrome for a dock panel: a labeled header (title · symbol · optional
/// trailing accessory · collapse) over the panel body. The collapse button
/// turns the panel off via `onHide`.
struct DockSection<Content: View>: View {
    let panel: DockPanel
    var symbol: String? = nil
    var trailing: AnyView? = nil
    let onHide: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.line)
            content()
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            SectionLabel(text: panel.title)
            if let symbol {
                Text(symbol)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.bone)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let trailing { trailing }
            DockCollapseButton(panel: panel, action: onHide)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

/// The per-panel collapse affordance: a small xmark, dim → ember on hover, that
/// hides the panel. Mirrors the shell PanelCollapseButton grammar.
struct DockCollapseButton: View {
    let panel: DockPanel
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? Theme.ember : Theme.dim)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("hide \(panel.title)")
        .animation(DeckMotion.ease(), value: hovering)
    }
}

/// Compact real/delayed source posture for the DOM header. Good data stays quiet
/// (dim "REAL-TIME"); delayed depth draws an ember dot and reads "DELAYED L1" —
/// never live styling on delayed book. Reuses the pure DepthBanner honesty rule.
private struct DepthSourceTag: View {
    let banner: DepthBanner

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(banner.kind == .delayed ? Theme.ember : Theme.dim)
                .frame(width: 5, height: 5)
            Text(banner.isLive ? "REAL-TIME" : (banner.kind == .delayed ? "DELAYED L1" : "WAITING"))
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(banner.kind == .delayed ? Theme.ember : Theme.dim)
                .lineLimit(1)
        }
        .help(banner.note)
        .accessibilityLabel("depth feed \(banner.isLive ? "real time" : "delayed") \(banner.source)")
    }
}

// MARK: - L1 quote strip

/// The compact Level 1 quote strip: best bid / ask / last / spread / mid for the
/// symbol. Bid carries up, ask carries down (the only place direction color
/// applies); last / spread / mid stay bone / dim. NaN-safe — a missing or
/// garbage quote reads "—", never a fabricated number. Reads top-of-book
/// (`bookTop`) + the last tick, both of which stream independently of the depth
/// subscription, so this panel needs no book.
struct L1QuoteStrip: View {
    @Environment(AppModel.self) private var model
    let symbol: String

    private var top: BookTop? { model.bookTop[symbol] }

    var body: some View {
        HStack(spacing: 0) {
            quote("bid", finite(top?.bid_px), Theme.up)
            quote("ask", finite(top?.ask_px), Theme.down)
            quote("last", finite(model.lastPrice(symbol)), Theme.bone)
            quote("spread", spread, Theme.dim)
            quote("mid", mid, Theme.bone)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
    }

    /// Honest spread from top-of-book: nil unless both sides are finite/positive
    /// and uncrossed (DepthLadder.spread enforces the rule).
    private var spread: Double? {
        guard let t = top else { return nil }
        return DepthLadder.spread(bestBid: t.bid_px, bestAsk: t.ask_px)
    }

    private var mid: Double? {
        guard let t = top else { return nil }
        return DepthLadder.mid(bestBid: t.bid_px, bestAsk: t.ask_px)
    }

    /// A price is shown only when finite and positive — never a 0/NaN quote.
    private func finite(_ v: Double?) -> Double? {
        guard let v, v.isFinite, v > 0 else { return nil }
        return v
    }

    private func quote(_ label: String, _ value: Double?, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(Theme.dim)
            Text(value.map { DashFormat.price($0) } ?? "—")
                .numeric(size: 11, weight: .medium)
                .foregroundStyle(value == nil ? Theme.dim : color)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Feature picker (chart toolbar)

/// The compact dock feature picker, seated in the chart toolbar: toggle chips
/// for L1 · DOM · T&S · FLOW, then a single collapse for the whole dock. Reads /
/// writes the persisted @AppStorage toggles directly (no state threading), so it
/// stays in lockstep with the dock and workspace that read the same keys.
struct ChartDockPicker: View {
    @AppStorage(DockPanel.l1.storageKey) private var l1On = DockPanel.l1.defaultOn
    @AppStorage(DockPanel.dom.storageKey) private var domOn = DockPanel.dom.defaultOn
    @AppStorage(DockPanel.tape.storageKey) private var tapeOn = DockPanel.tape.defaultOn
    @AppStorage(DockPanel.flow.storageKey) private var flowOn = DockPanel.flow.defaultOn
    @AppStorage("chartDockHidden") private var dockHidden = false

    private var anyEnabled: Bool { l1On || domOn || tapeOn || flowOn }

    var body: some View {
        HStack(spacing: 2) {
            chip(.l1, $l1On)
            chip(.dom, $domOn)
            chip(.tape, $tapeOn)
            chip(.flow, $flowOn)
            if anyEnabled {
                Rectangle()
                    .fill(Theme.line)
                    .frame(width: Theme.hairline, height: 14)
                    .padding(.horizontal, 2)
                hideButton
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

    private func chip(_ panel: DockPanel, _ isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(panel.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isOn.wrappedValue ? Theme.bone : Theme.dim)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(isOn.wrappedValue ? Theme.panelHi : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(isOn.wrappedValue ? "hide" : "show") \(panel.help)")
    }

    /// Collapse / reveal the whole dock (a temporary hide of an otherwise-enabled
    /// dock; the panel toggles themselves are untouched).
    private var hideButton: some View {
        Button {
            dockHidden.toggle()
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(dockHidden ? Theme.ember : Theme.dim)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(dockHidden ? "show dock" : "hide dock")
    }
}

/// The slim re-open strip pinned to the collapsed dock's edge: 16pt of ink with
/// an inner hairline and a centered chevron (dim → ember on hover). Mirrors the
/// shell ReopenHandle; reveals the dock.
private struct DockReopenHandle: View {
    @AppStorage("chartDockHidden") private var dockHidden = false
    @State private var hovering = false

    var body: some View {
        Button {
            dockHidden = false
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? Theme.ember : Theme.dim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("show dock")
        .frame(width: 16)
        .frame(maxHeight: .infinity)
        .background(Theme.ink)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.line).frame(width: Theme.hairline)
        }
        .animation(DeckMotion.ease(), value: hovering)
    }
}
