import SwiftUI
import CortexCore

/// Main navigation shell using a collapsible sidebar instead of TabView.
struct ContentView: View {
    let environment: AppEnvironment
    @State var selectedTab: AppTab = .warRoom
    @State var isSidebarExpanded: Bool = true

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                selectedTab: $selectedTab,
                isExpanded: $isSidebarExpanded,
                dailyPnL: environment.portfolio.dailyPnL
            )

            Divider()
                .overlay(Color(white: 0.15))

            // Content area
            contentForTab(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: NSColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1.0)))
        .background { keyboardShortcuts }
    }

    @ViewBuilder
    private func contentForTab(_ tab: AppTab) -> some View {
        switch tab {
        case .warRoom:
            WarRoomView(environment: environment)
        case .charts:
            ChartView()
        case .scanner:
            ScannerView(opportunities: environment.opportunities)
        case .squadrons:
            SquadronsDetailView(squadrons: environment.squadrons)
        case .watchlist:
            WatchlistView(store: environment.watchlist)
        case .chat:
            ChatView(store: environment.chat, opportunities: environment.opportunities)
        case .performance:
            PerformanceDashboardView(store: environment.performance)
        case .settings:
            SettingsView(settings: environment.settings)
        }
    }

    // MARK: - Keyboard Shortcuts

    /// All keyboard shortcuts as hidden buttons rendered in the background.
    @ViewBuilder
    private var keyboardShortcuts: some View {
        // Cmd+B: Toggle sidebar
        Button("") { isSidebarExpanded.toggle() }
            .keyboardShortcut("b", modifiers: .command)
            .hidden()

        // Cmd+K: Toggle kill switch
        Button("") {
            if environment.killSwitch.isActive {
                environment.killSwitch.disengage()
            } else {
                environment.killSwitch.engage()
            }
        }
        .keyboardShortcut("k", modifiers: .command)
        .hidden()

        // Cmd+/: Switch to chat tab
        Button("") { selectedTab = .chat }
            .keyboardShortcut("/", modifiers: .command)
            .hidden()

        // Cmd+1 through Cmd+8: Switch tabs
        ForEach(AppTab.allCases) { tab in
            if let shortcut = tab.shortcut {
                Button("") { selectedTab = tab }
                    .keyboardShortcut(shortcut, modifiers: .command)
                    .hidden()
            }
        }
    }
}
