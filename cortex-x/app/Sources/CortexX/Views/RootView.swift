// Root layout shell — icon rail | watchlist | center section + deck | intelligence.
// Panels are implemented in Views/*; this file owns only arrangement, the
// section rail, panel visibility, and keyboard navigation.

import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showWatchlist") private var showWatchlist = true
    @AppStorage("showIntelligence") private var showIntelligence = true
    @AppStorage("showDeck") private var showDeck = true
    // User-resizable panel sizes, persisted. Read through ResizablePanel so the
    // dividers, storage keys, defaults, and clamps stay a single source of truth.
    @AppStorage(ResizablePanel.watchlist.storageKey)
    private var watchlistWidth = ResizablePanel.watchlist.defaultSize
    @AppStorage(ResizablePanel.intelligence.storageKey)
    private var intelligenceWidth = ResizablePanel.intelligence.defaultSize
    @AppStorage(ResizablePanel.deck.storageKey)
    private var deckHeight = ResizablePanel.deck.defaultSize

    private static let ease = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.2)

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
                .zIndex(1) // so the global symbol-search dropdown floats over the content below
            Divider().overlay(Theme.line)
            HStack(spacing: 0) {
                IconRail()
                Divider().overlay(Theme.line)
                if showWatchlist {
                    Watchlist()
                        .frame(width: CGFloat(ResizablePanel.watchlist.clamp(watchlistWidth)))
                    ResizeDivider(
                        axis: .horizontal, panel: .watchlist,
                        size: $watchlistWidth, direction: 1
                    )
                } else {
                    ReopenHandle(panel: .watchlist, visible: $showWatchlist)
                }
                VStack(spacing: 0) {
                    Group {
                        switch model.centerMode {
                        case .chart: ChartWorkspace()
                        case .scanner: ScannerView()
                        case .news: NewsView()
                        case .company: CompanyView()
                        case .options: OptionsChainView()
                        case .foundry: FoundryView()
                        case .regimes: RegimesView()
                        case .meridian: MeridianView()
                        case .settings: SettingsView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showDeck {
                        ResizeDivider(
                            axis: .vertical, panel: .deck,
                            size: $deckHeight, direction: -1
                        )
                        DashboardPanel()
                            .frame(height: CGFloat(ResizablePanel.deck.clamp(deckHeight)))
                    } else {
                        ReopenHandle(panel: .deck, visible: $showDeck)
                    }
                }
                .frame(maxWidth: .infinity)
                if showIntelligence {
                    ResizeDivider(
                        axis: .horizontal, panel: .intelligence,
                        size: $intelligenceWidth, direction: -1
                    )
                    IntelligencePanel()
                        .frame(width: CGFloat(ResizablePanel.intelligence.clamp(intelligenceWidth)))
                } else {
                    ReopenHandle(panel: .intelligence, visible: $showIntelligence)
                }
            }
        }
        .background(Theme.ink)
        .animation(Self.ease, value: showWatchlist)
        .animation(Self.ease, value: showIntelligence)
        .animation(Self.ease, value: showDeck)
    }
}

// MARK: - Shell panels

/// The three collapsible shell panels. Single source of truth for the
/// @AppStorage visibility key, the header collapse icon, the re-open chevron,
/// the .help name, and the cmd-shift shortcut — so the collapse buttons (at
/// the panels) and the re-open handles (here) can never drift apart.
enum ShellPanel: CaseIterable {
    case watchlist, intelligence, deck

    /// UserDefaults key backing visibility; RootView owns the same keys.
    var storageKey: String {
        switch self {
        case .watchlist: "showWatchlist"
        case .intelligence: "showIntelligence"
        case .deck: "showDeck"
        }
    }

    /// SF Symbol on the collapse affordance in the panel's own header.
    var collapseIcon: String {
        switch self {
        case .watchlist: "sidebar.left"
        case .intelligence: "sidebar.right"
        case .deck: "rectangle.bottomthird.inset.filled"
        }
    }

    /// Chevron on the slim re-open handle, pointing where the panel returns.
    var reopenIcon: String {
        switch self {
        case .watchlist: "chevron.right"
        case .intelligence: "chevron.left"
        case .deck: "chevron.up"
        }
    }

    /// Lowercase name for .help copy ("hide watchlist" / "show watchlist").
    var displayName: String {
        switch self {
        case .watchlist: "watchlist"
        case .intelligence: "intelligence"
        case .deck: "bottom deck"
        }
    }

    /// cmd-shift key shared by the collapse button and the re-open handle
    /// (they are never in the hierarchy at the same time).
    var shortcutKey: Character {
        switch self {
        case .watchlist: "l"
        case .intelligence: "r"
        case .deck: "b"
        }
    }
}

/// 13pt collapse affordance in a panel's own header: dim, ember on hover.
/// Reads the same @AppStorage key RootView arranges by, so no bindings need
/// to thread through the panels.
struct PanelCollapseButton: View {
    let panel: ShellPanel
    @AppStorage private var visible: Bool
    @State private var hovering = false

    init(_ panel: ShellPanel) {
        self.panel = panel
        _visible = AppStorage(wrappedValue: true, panel.storageKey)
    }

    var body: some View {
        Button {
            visible.toggle()
        } label: {
            Image(systemName: panel.collapseIcon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Theme.ember : Theme.dim)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(panel.shortcutKey), modifiers: [.command, .shift])
        .onHover { hovering = $0 }
        .help("hide \(panel.displayName)")
    }
}

/// Slim re-open strip pinned to a hidden panel's edge: 16pt of ink with a
/// hairline on the inner edge and a centered chevron (dim, ember on hover).
/// Carries the panel's cmd-shift shortcut while its collapse button is gone.
private struct ReopenHandle: View {
    let panel: ShellPanel
    @Binding var visible: Bool
    @State private var hovering = false

    private var isBottom: Bool { panel == .deck }

    private var innerEdge: Alignment {
        switch panel {
        case .watchlist: .trailing
        case .intelligence: .leading
        case .deck: .top
        }
    }

    var body: some View {
        Button {
            visible = true
        } label: {
            Image(systemName: panel.reopenIcon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? Theme.ember : Theme.dim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(panel.shortcutKey), modifiers: [.command, .shift])
        .onHover { hovering = $0 }
        .help("show \(panel.displayName)")
        .frame(width: isBottom ? nil : 16, height: isBottom ? 16 : nil)
        .frame(
            maxWidth: isBottom ? .infinity : nil,
            maxHeight: isBottom ? nil : .infinity
        )
        .background(Theme.ink)
        .overlay(alignment: innerEdge) {
            Rectangle()
                .fill(Theme.line)
                .frame(
                    width: isBottom ? nil : Theme.hairline,
                    height: isBottom ? Theme.hairline : nil
                )
        }
        .animation(DeckMotion.ease(), value: hovering)
    }
}

// MARK: - Icon rail

/// Far-left section rail: SF Symbol section buttons on top, connection dot
/// pinned at the bottom. GINEXUS style: clean, small, quiet — no labels.
/// Panel visibility toggles live at their panels (PanelCollapseButton).
private struct IconRail: View {
    @Environment(AppModel.self) private var model
    @State private var hovered: AppModel.CenterMode?

    private static let sections: [(mode: AppModel.CenterMode, icon: String, name: String)] = [
        (.chart, "chart.xyaxis.line", "terminal"),
        (.scanner, "scope", "scanner"),
        (.news, "newspaper", "news"),
        (.company, "building.2", "company"),
        (.options, "square.grid.3x3", "options"),
        (.foundry, "hammer", "foundry"),
        (.regimes, "waveform.path.ecg", "regimes"),
        (.meridian, "globe", "meridian"),
    ]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(Self.sections.enumerated()), id: \.element.icon) { index, section in
                sectionButton(section, digit: index + 1)
            }
            Spacer(minLength: 8)
            // Settings sits at the foot of the rail, above the connection dot —
            // separate from the numbered section list (it opens the .settings
            // center mode; ⌘, is the standard macOS Settings shortcut).
            settingsButton
            connectionDot
                .padding(.top, 6)
        }
        .padding(.vertical, 10)
        .frame(width: 48)
        .frame(maxHeight: .infinity)
        .background(Theme.ink)
    }

    private func sectionButton(
        _ section: (mode: AppModel.CenterMode, icon: String, name: String),
        digit: Int
    ) -> some View {
        let active = model.centerMode == section.mode
        let isHovered = hovered == section.mode
        return Button {
            model.centerMode = section.mode
        } label: {
            Image(systemName: section.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active || isHovered ? Theme.ember : Theme.dim)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(active ? Theme.emberTint : (isHovered ? Theme.panelHi : .clear))
                )
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character("\(digit)")), modifiers: .command)
        .help(section.name)
        .onHover { hovered = $0 ? section.mode : (hovered == section.mode ? nil : hovered) }
        .overlay(alignment: .leading) {
            if isHovered { railFlyout(section.name) }
        }
        .zIndex(isHovered ? 1 : 0)
        .animation(DeckMotion.ease(), value: isHovered)
    }

    /// Foot-of-rail gear opening the SETTINGS center mode. Same visual language
    /// as the section buttons (ember tint when active/hovered, hover flyout) but
    /// off the numbered list — it carries ⌘, instead of a digit.
    private var settingsButton: some View {
        let active = model.centerMode == .settings
        let isHovered = hovered == .settings
        return Button {
            model.centerMode = .settings
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active || isHovered ? Theme.ember : Theme.dim)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(active ? Theme.emberTint : (isHovered ? Theme.panelHi : .clear))
                )
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(",", modifiers: .command)
        .help("settings")
        .onHover { hovered = $0 ? .settings : (hovered == .settings ? nil : hovered) }
        .overlay(alignment: .leading) {
            if isHovered { railFlyout("settings") }
        }
        .zIndex(isHovered ? 1 : 0)
        .animation(DeckMotion.ease(), value: isHovered)
    }

    /// Instant on-brand title flyout to the right of a rail icon (the native
    /// .help tooltip is slow and easy to miss). Non-interactive; drawn above
    /// siblings so it never gets clipped by the next row.
    private func railFlyout(_ name: String) -> some View {
        Text(name.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.bone)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.line, lineWidth: Theme.hairline)
            )
            .offset(x: 46)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private var connectionDot: some View {
        Circle()
            .fill(connectionColor)
            .frame(width: 7, height: 7)
            .help(model.connection.label)
    }

    private var connectionColor: Color {
        switch model.connection {
        case .connected: Theme.up
        case .connecting: Theme.warn
        case .disconnected: Theme.down
        }
    }
}

// MARK: - Resizable panels

/// The four user-resizable panels. Each carries its @AppStorage key, min/max
/// clamps, and default size, so the drag dividers, the persisted store, and the
/// tests read ONE source of truth. Sizes persist as Double (the @AppStorage wire
/// type); `frame` takes CGFloat, identical to Double on 64-bit macOS.
enum ResizablePanel: CaseIterable {
    case watchlist, intelligence, deck, chartDock

    /// @AppStorage key backing this panel's persisted size — never rename.
    /// Distinct from the visibility keys (showWatchlist / showDeck / …), so
    /// resize and collapse never fight over storage.
    var storageKey: String {
        switch self {
        case .watchlist: "watchlistWidth"
        case .intelligence: "intelligenceWidth"
        case .deck: "deckHeight"
        case .chartDock: "chartDockWidth"
        }
    }

    var minSize: Double {
        switch self {
        case .watchlist: 160
        case .intelligence: 260
        case .deck: 120
        case .chartDock: 240
        }
    }

    var maxSize: Double {
        switch self {
        case .watchlist: 360
        case .intelligence: 520
        case .deck: 460
        case .chartDock: 560
        }
    }

    /// The persisted default before the operator drags anything. The chart dock
    /// defaults WIDER (340) than the shell sidebars so the DOM ladder is usable
    /// out of the box; the deck defaults SHORTER (200) so an empty positions
    /// table never dominates the workspace.
    var defaultSize: Double {
        switch self {
        case .watchlist: 220
        case .intelligence: 340
        case .deck: 200
        case .chartDock: 340
        }
    }

    /// NaN-safe clamp of a candidate size to this panel's [min, max].
    func clamp(_ value: Double) -> Double {
        PanelResize.clamp(value, min: minSize, max: maxSize)
    }
}

enum PanelResize {
    /// Clamp `value` to [lo, hi]. NaN-safe: NaN (never expected from a drag, but
    /// cheap to guard) collapses to the minimum rather than persisting a garbage
    /// size; ±infinity fall to the finite bound they run into.
    static func clamp(_ value: Double, min lo: Double, max hi: Double) -> Double {
        guard !value.isNaN else { return lo }
        return Swift.min(Swift.max(value, lo), hi)
    }
}

/// A draggable divider that resizes an adjacent panel. Renders as a 1px hairline
/// inside a ~5pt grab strip; hovering brightens the line to ember and shows the
/// correct resize cursor. Dragging updates the bound @AppStorage `size`, clamped
/// live to the panel's [min, max]. `direction` is +1 when dragging along the
/// natural axis enlarges the panel (watchlist, whose divider is on its right
/// edge) and -1 when it shrinks it (intelligence + chart-dock left edges, deck
/// top edge). Sits alongside the existing collapse toggles: it resizes only the
/// VISIBLE panel; a hidden panel shows a ReopenHandle instead and no divider.
struct ResizeDivider: View {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    let panel: ResizablePanel
    @Binding var size: Double
    var direction: Double = 1

    @State private var hovering = false
    @State private var dragOrigin: Double?

    /// Grab strip thickness — wider than the hairline so the divider is easy to
    /// seize without a visible slab.
    private static let grab: CGFloat = 5

    private var isHorizontal: Bool { axis == .horizontal }

    var body: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(hovering ? Theme.ember.opacity(0.55) : Theme.line)
                .frame(
                    width: isHorizontal ? Theme.hairline : nil,
                    height: isHorizontal ? nil : Theme.hairline
                )
        }
        .frame(
            width: isHorizontal ? Self.grab : nil,
            height: isHorizontal ? nil : Self.grab
        )
        .frame(
            maxWidth: isHorizontal ? nil : .infinity,
            maxHeight: isHorizontal ? .infinity : nil
        )
        .contentShape(Rectangle())
        .background(ResizeCursor(axis: axis))
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let origin = dragOrigin ?? size
                    if dragOrigin == nil { dragOrigin = origin }
                    let delta = Double(
                        isHorizontal ? value.translation.width : value.translation.height
                    )
                    size = panel.clamp(origin + direction * delta)
                }
                .onEnded { _ in dragOrigin = nil }
        )
        .onHover { hovering = $0 }
        .animation(DeckMotion.ease(), value: hovering)
    }
}

/// AppKit resize cursor for a divider: sets the left-right / up-down cursor over
/// its bounds via a tracking area (steadier than SwiftUI hover across a live
/// drag) while passing mouse events straight through (hitTest → nil) so the
/// SwiftUI DragGesture underneath still drives the resize.
private struct ResizeCursor: NSViewRepresentable {
    let axis: ResizeDivider.Axis

    private var cursor: NSCursor {
        axis == .horizontal ? .resizeLeftRight : .resizeUpDown
    }

    func makeNSView(context: Context) -> NSView {
        let view = CursorNSView()
        view.cursor = cursor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CursorNSView)?.cursor = cursor
    }

    final class CursorNSView: NSView {
        var cursor: NSCursor = .arrow

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func cursorUpdate(with event: NSEvent) { cursor.set() }
        override func mouseEntered(with event: NSEvent) { cursor.set() }

        // Let clicks and drags fall through to the SwiftUI gesture beneath.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
