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

    // Transient live drag sizes — non-nil only WHILE a divider is being dragged.
    // The panel frames read `drag ?? persisted`, so a drag streams through cheap
    // in-memory @State and only the drag-end commit touches @AppStorage (no
    // per-frame UserDefaults write / observation storm → smooth resize).
    @State private var dragWatchlist: Double?
    @State private var dragIntelligence: Double?
    @State private var dragDeck: Double?
    /// Shared right-rail width: the chart trading dock (top) and the deck order-
    /// ticket column (bottom) render one continuous band; both dividers drive it.
    @State private var rail = RailLayout()

    private var liveWatchlistWidth: Double { ResizablePanel.watchlist.clamp(dragWatchlist ?? watchlistWidth) }
    private var liveIntelligenceWidth: Double { ResizablePanel.intelligence.clamp(dragIntelligence ?? intelligenceWidth) }
    private var liveDeckHeight: Double { ResizablePanel.deck.clamp(dragDeck ?? deckHeight) }

    private static let ease = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.2)

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
                .zIndex(1) // so the global symbol-search dropdown floats over the content below
            Divider().overlay(Theme.line)
            if model.engineOutdated {
                StaleEngineBanner()
                Divider().overlay(Theme.line)
            }
            if let undelivered = model.undeliveredCommand {
                UndeliveredCommandBanner(note: undelivered)
                Divider().overlay(Theme.line)
            }
            HStack(spacing: 0) {
                IconRail()
                    .zIndex(2) // the hover flyout overflows right into the watchlist;
                    // lift the rail above the later siblings so the callout is never
                    // occluded by a highlighted watchlist card.
                Divider().overlay(Theme.line)
                if showWatchlist {
                    Watchlist()
                        .frame(width: CGFloat(liveWatchlistWidth))
                    ResizeDivider(
                        axis: .horizontal, panel: .watchlist,
                        base: watchlistWidth,
                        onChange: { dragWatchlist = $0 },
                        onEnd: { watchlistWidth = $0; dragWatchlist = nil },
                        direction: 1
                    )
                } else {
                    ReopenHandle(panel: .watchlist, visible: $showWatchlist)
                }
                VStack(spacing: 0) {
                    Group {
                        switch model.centerMode {
                        case .chart: ChartWorkspace()
                        case .scanner: ScannerView()
                        case .heatmap: HeatmapView()
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
                            base: deckHeight,
                            onChange: { dragDeck = $0 },
                            onEnd: { deckHeight = $0; dragDeck = nil },
                            direction: -1
                        )
                        DashboardPanel()
                            .frame(height: CGFloat(liveDeckHeight))
                    } else {
                        ReopenHandle(panel: .deck, visible: $showDeck)
                    }
                }
                .frame(maxWidth: .infinity)
                if showIntelligence {
                    ResizeDivider(
                        axis: .horizontal, panel: .intelligence,
                        base: intelligenceWidth,
                        onChange: { dragIntelligence = $0 },
                        onEnd: { intelligenceWidth = $0; dragIntelligence = nil },
                        direction: -1
                    )
                    IntelligencePanel()
                        .frame(width: CGFloat(liveIntelligenceWidth))
                } else {
                    ReopenHandle(panel: .intelligence, visible: $showIntelligence)
                }
            }
        }
        .background(Theme.ink)
        .animation(Self.ease, value: showWatchlist)
        .animation(Self.ease, value: showIntelligence)
        .animation(Self.ease, value: showDeck)
        .environment(rail) // the chart dock + deck ticket column share this width
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
/// Out-of-date-engine notice, pinned under the top bar.
///
/// The engine is deliberately left running when the window quits, so a freshly
/// installed app build routinely connects to a cortexd from a previous build.
/// That engine still ACCEPTS newer commands — serde ignores fields it does not
/// know — and answers them wrongly but plausibly, so the only symptom is a
/// feature that quietly does nothing (an intraday chart that never fills).
/// Nothing in the UI used to say so. This does, and offers the one-step fix.
///
/// Ember dot + bone text, per the warning convention — no coloured alert block.
private struct StaleEngineBanner: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.ember)
                .frame(width: 5, height: 5)
            Text("ENGINE OUT OF DATE")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(Theme.bone)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
            Spacer(minLength: 8)
            if confirming {
                Text("restart engine? trading and monitoring stop until it is back")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
                actionButton("cancel", destructive: false) { confirming = false }
                actionButton("restart", destructive: true) {
                    confirming = false
                    model.restartEngine()
                }
            } else {
                actionButton("restart engine…", destructive: false) { confirming = true }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
    }

    /// Names the missing capability rather than a version number: the engine's
    /// crate version is not bumped per build, so it cannot identify a build.
    private var detail: String {
        let missing = model.missingEngineCapabilities.joined(separator: ", ")
        let version = model.engineVersion.isEmpty ? "unknown build" : "v\(model.engineVersion)"
        return "running engine (\(version)) lacks: \(missing) — intraday chart history cannot be served"
    }

    private func actionButton(
        _ label: String, destructive: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.bone)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.panelHi)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Theme.line, lineWidth: Theme.hairline)
                )
        }
        .buttonStyle(.plain)
        .pointingHandCursor(destructive: destructive)
    }
}

/// A command that never reached the engine.
///
/// The client used to drop every command silently when the socket was down —
/// including `set_kill_switch` and `flatten_all`. The button gave no feedback,
/// so the operator could believe trading was halted when the engine never heard
/// it. This states plainly that the action did not go out.
private struct UndeliveredCommandBanner: View {
    @Environment(AppModel.self) private var model
    let note: UndeliveredCommand

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.ember)
                .frame(width: 5, height: 5)
            Text("NOT SENT")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(Theme.bone)
            Text("\(note.label) — \(note.reason)")
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                model.clearUndeliveredCommand()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.dim)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
    }
}

/// Hinomaru red on hover for a destructive action, ember for everything else —
/// the only place red is permitted.
private extension View {
    func pointingHandCursor(destructive: Bool) -> some View {
        modifier(HoverTint(destructive: destructive))
    }
}

private struct HoverTint: ViewModifier {
    let destructive: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .brightness(hovering ? 0.06 : 0)
            .overlay {
                if hovering {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(
                            destructive ? Theme.down : Theme.ember,
                            lineWidth: Theme.hairline
                        )
                }
            }
            .onHover { hovering = $0 }
            .animation(DeckMotion.ease(), value: hovering)
    }
}

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
        (.heatmap, "rectangle.grid.3x2.fill", "heatmap"),
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
        case .chartDock: 280
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
/// correct resize cursor.
///
/// SMOOTH RESIZE: the divider does NOT hold a persisted @AppStorage binding.
/// It takes the current persisted size as a stable `base`, streams the live size
/// through `onChange` during the drag (the caller drives a transient in-memory
/// @State from it — no per-frame UserDefaults write, no @AppStorage observation
/// storm), and reports the final size ONCE through `onEnd` where the caller
/// persists it. This keeps the drag hot path off disk and out of the global
/// observation graph. `direction` is +1 when dragging along the natural axis
/// enlarges the panel (watchlist, divider on its right edge) and -1 when it
/// shrinks it (intelligence + chart-dock left edges, deck top edge). Resizes only
/// the VISIBLE panel; a hidden panel shows a ReopenHandle instead and no divider.
struct ResizeDivider: View {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    let panel: ResizablePanel
    /// The current persisted size — the stable drag origin (never mutated mid-drag).
    let base: Double
    /// Live clamped size, fired every drag frame → drive transient @State.
    let onChange: (Double) -> Void
    /// Final clamped size at drag end → persist ONCE here.
    let onEnd: (Double) -> Void
    var direction: Double = 1

    @State private var hovering = false
    @State private var dragOrigin: Double?

    /// Grab strip thickness — wider than the hairline so the divider is easy to
    /// seize without a visible slab.
    private static let grab: CGFloat = 5

    private var isHorizontal: Bool { axis == .horizontal }

    private func resolved(_ value: DragGesture.Value) -> Double {
        let origin = dragOrigin ?? base
        let delta = Double(isHorizontal ? value.translation.width : value.translation.height)
        return panel.clamp(origin + direction * delta)
    }

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
                    if dragOrigin == nil { dragOrigin = base }
                    onChange(resolved(value))
                }
                .onEnded { value in
                    onEnd(resolved(value))
                    dragOrigin = nil
                }
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
