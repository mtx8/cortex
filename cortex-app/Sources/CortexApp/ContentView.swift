import SwiftUI
import CortexCore

/// Main navigation shell using a top tab bar + left context pane + content area + AI overlay.
struct ContentView: View {
    let environment: AppEnvironment
    @State private var selectedTab: AppTab = .warRoom
    @State private var selectedSection: String = "Overview"
    @State private var isContextPaneVisible: Bool = true
    @State private var isAIPaneVisible: Bool = false
    @State private var isAIPaneFullscreen: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Top tab bar (~52px)
            TabBarView(
                selectedTab: $selectedTab,
                onSparklesTapped: { withAnimation(.easeInOut(duration: 0.25)) { isAIPaneVisible.toggle() } },
                isAIPaneVisible: isAIPaneVisible,
                dailyPnL: environment.portfolio.dailyPnL,
                isConnected: environment.webSocket.isConnected
            )

            Divider()
                .overlay(Color(white: 0.12))

            // Main content area
            HStack(spacing: 0) {
                // Left context pane (220px, collapsible)
                if isContextPaneVisible {
                    ContextPaneView(tab: selectedTab, selectedSection: $selectedSection)
                        .transition(.move(edge: .leading))

                    Divider()
                        .overlay(Color(white: 0.12))
                }

                // Main content (fills remaining space)
                contentForTab(selectedTab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Right AI pane (420px or fullscreen)
                if isAIPaneVisible {
                    Divider()
                        .overlay(Color(white: 0.12))

                    CortexAIPane(
                        store: environment.chat,
                        currentTab: selectedTab,
                        currentSection: selectedSection,
                        isFullscreen: $isAIPaneFullscreen,
                        onClose: { withAnimation(.easeInOut(duration: 0.25)) { isAIPaneVisible = false } }
                    )
                    .frame(width: isAIPaneFullscreen ? nil : 420)
                    .frame(maxWidth: isAIPaneFullscreen ? .infinity : nil)
                    .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isContextPaneVisible)
            .animation(.easeInOut(duration: 0.25), value: isAIPaneVisible)
        }
        .background(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)))
        .background { keyboardShortcuts }
        .onChange(of: selectedTab) { _, newTab in
            selectedSection = newTab.defaultSection
        }
    }

    // MARK: - Content Router

    @ViewBuilder
    private func contentForTab(_ tab: AppTab) -> some View {
        switch tab {
        case .warRoom:
            WarRoomView(environment: environment)
        case .markets:
            ChartView()
        case .scanner:
            ScannerView(opportunities: environment.opportunities, scannerFilter: environment.scannerFilter, onAnalyzeWithAI: { prompt in
                environment.chat.inputText = prompt
                environment.chat.sendMessage()
                withAnimation(.easeInOut(duration: 0.25)) { isAIPaneVisible = true }
            })
        case .financials:
            FinancialsView(store: environment.financials)
        case .watchlist:
            WatchlistView(store: environment.watchlist)
        case .squadrons:
            SquadronsDetailView(squadrons: environment.squadrons)
        case .performance:
            PerformanceDashboardView(store: environment.performance)
        case .settings:
            SettingsView(settings: environment.settings)
        }
    }

    // MARK: - Keyboard Shortcuts

    @ViewBuilder
    private var keyboardShortcuts: some View {
        // Cmd+B or Cmd+[: Toggle context pane
        Button("") {
            withAnimation(.easeInOut(duration: 0.25)) { isContextPaneVisible.toggle() }
        }
        .keyboardShortcut("b", modifiers: .command)
        .hidden()

        Button("") {
            withAnimation(.easeInOut(duration: 0.25)) { isContextPaneVisible.toggle() }
        }
        .keyboardShortcut("[", modifiers: .command)
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

        // Cmd+Shift+A: Toggle AI pane
        Button("") {
            withAnimation(.easeInOut(duration: 0.25)) { isAIPaneVisible.toggle() }
        }
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .hidden()

        // Cmd+/: Open AI pane
        Button("") {
            withAnimation(.easeInOut(duration: 0.25)) { isAIPaneVisible = true }
        }
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
