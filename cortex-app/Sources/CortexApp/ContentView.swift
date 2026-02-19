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
        .keyboardShortcut(for: .toggleSidebar) {
            isSidebarExpanded.toggle()
        }
    }

    @ViewBuilder
    private func contentForTab(_ tab: AppTab) -> some View {
        switch tab {
        case .warRoom:
            WarRoomView(environment: environment)
        case .charts:
            ChartView()
        case .scanner:
            ScannerView()
        case .squadrons:
            SquadronsDetailView()
        case .watchlist:
            WatchlistView(store: environment.watchlist)
        case .chat:
            ChatView(store: environment.chat)
        case .performance:
            PerformanceDashboardView(store: environment.performance)
        case .settings:
            SettingsView(settings: environment.settings)
        }
    }
}

// MARK: - Keyboard Shortcut Helpers

private enum CortexShortcut {
    case toggleSidebar
}

private extension View {
    func keyboardShortcut(for shortcut: CortexShortcut, action: @escaping () -> Void) -> some View {
        switch shortcut {
        case .toggleSidebar:
            return self.background(
                Button("") { action() }
                    .keyboardShortcut("b", modifiers: .command)
                    .hidden()
            )
        }
    }
}
