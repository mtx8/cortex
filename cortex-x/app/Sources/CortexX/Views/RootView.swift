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
                IconRail(
                    showWatchlist: $showWatchlist,
                    showIntelligence: $showIntelligence,
                    showDeck: $showDeck
                )
                Divider().overlay(Theme.line)
                if showWatchlist {
                    Watchlist()
                        .frame(width: 220)
                    Divider().overlay(Theme.line)
                }
                VStack(spacing: 0) {
                    Group {
                        switch model.centerMode {
                        case .chart: ChartPanel()
                        case .scanner: ScannerView()
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
                    }
                }
                .frame(maxWidth: .infinity)
                if showIntelligence {
                    Divider().overlay(Theme.line)
                    IntelligencePanel()
                        .frame(width: 340)
                }
            }
        }
        .background(Theme.ink)
        .animation(Self.ease, value: showWatchlist)
        .animation(Self.ease, value: showIntelligence)
        .animation(Self.ease, value: showDeck)
    }
}

// MARK: - Icon rail

/// Far-left section rail: six SF Symbol section buttons on top, panel
/// visibility toggles + connection dot pinned at the bottom. GINEXUS style:
/// clean, small, quiet — no labels.
private struct IconRail: View {
    @Environment(AppModel.self) private var model
    @Binding var showWatchlist: Bool
    @Binding var showIntelligence: Bool
    @Binding var showDeck: Bool

    private static let sections: [(mode: AppModel.CenterMode, icon: String, name: String)] = [
        (.chart, "chart.xyaxis.line", "terminal"),
        (.scanner, "scope", "scanner"),
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
            panelToggle("sidebar.left", isOn: $showWatchlist, name: "watchlist", key: "l")
            panelToggle("sidebar.right", isOn: $showIntelligence, name: "intelligence", key: "r")
            panelToggle("rectangle.bottomthird.inset.filled", isOn: $showDeck, name: "bottom deck", key: "b")
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
        return Button {
            model.centerMode = section.mode
        } label: {
            Image(systemName: section.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active ? Theme.ember : Theme.dim)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(active ? Theme.emberTint : .clear)
                )
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character("\(digit)")), modifiers: .command)
        .help(section.name)
    }

    private func panelToggle(
        _ icon: String, isOn: Binding<Bool>, name: String, key: Character
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn.wrappedValue ? Theme.bone : Theme.dim)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(key), modifiers: [.command, .shift])
        .help(isOn.wrappedValue ? "hide \(name)" : "show \(name)")
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
