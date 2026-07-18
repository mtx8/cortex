// Root layout shell — icon rail | watchlist | center section + deck | intelligence.
// Panels are implemented in Views/*; this file owns only arrangement, the
// section rail, panel visibility, and keyboard navigation.

import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showWatchlist") private var showWatchlist = true
    @AppStorage("showIntelligence") private var showIntelligence = true
    @AppStorage("showDeck") private var showDeck = true

    private static let ease = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.2)

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Divider().overlay(Theme.line)
            HStack(spacing: 0) {
                IconRail()
                Divider().overlay(Theme.line)
                if showWatchlist {
                    Watchlist()
                        .frame(width: 220)
                    Divider().overlay(Theme.line)
                } else {
                    ReopenHandle(panel: .watchlist, visible: $showWatchlist)
                }
                VStack(spacing: 0) {
                    Group {
                        switch model.centerMode {
                        case .chart: ChartGrid()
                        case .scanner: ScannerView()
                        case .news: NewsView()
                        case .company: CompanyView()
                        case .options: OptionsChainView()
                        case .foundry: FoundryView()
                        case .regimes: RegimesView()
                        case .meridian: MeridianView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showDeck {
                        Divider().overlay(Theme.line)
                        DashboardPanel()
                            .frame(height: 280)
                    } else {
                        ReopenHandle(panel: .deck, visible: $showDeck)
                    }
                }
                .frame(maxWidth: .infinity)
                if showIntelligence {
                    Divider().overlay(Theme.line)
                    IntelligencePanel()
                        .frame(width: 340)
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
            connectionDot
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
        // Instant on-brand title flyout to the right of the icon (the native
        // .help tooltip is slow and easy to miss). Non-interactive; drawn
        // above siblings so it never gets clipped by the next row.
        .overlay(alignment: .leading) {
            if isHovered {
                Text(section.name.uppercased())
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
        }
        .zIndex(isHovered ? 1 : 0)
        .animation(DeckMotion.ease(), value: isHovered)
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
