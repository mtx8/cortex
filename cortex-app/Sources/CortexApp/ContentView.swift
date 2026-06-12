import SwiftUI
import CortexCore

/// Main navigation shell using a top tab bar + left context pane + content area + AI overlay.
struct ContentView: View {
    let environment: AppEnvironment
    @State private var selectedTab: AppTab = .warRoom
    @State private var selectedSection: String = "Overview"
    @State private var contextPaneMode: ContextPaneMode = .full
    @State private var isAIPaneVisible: Bool = false
    @State private var isAIPaneFullscreen: Bool = false
    @State private var isHoveringDivider: Bool = false
    @State private var showCommandPalette: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Top tab bar (44px)
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
                // Left context pane (220px / 52px / 0px)
                if contextPaneMode != .hidden {
                    ContextPaneView(
                        tab: selectedTab,
                        selectedSection: $selectedSection,
                        mode: $contextPaneMode
                    )
                    .transition(.move(edge: .leading))
                }

                // Hover-reveal pane divider
                ZStack {
                    Rectangle()
                        .fill(Color(white: 0.12))
                        .frame(width: 1)

                    if isHoveringDivider {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if contextPaneMode == .hidden {
                                    contextPaneMode = .full
                                } else if contextPaneMode == .full {
                                    contextPaneMode = .iconOnly
                                } else {
                                    contextPaneMode = .full
                                }
                            }
                        }) {
                            Image(systemName: contextPaneMode == .iconOnly || contextPaneMode == .hidden
                                  ? "chevron.right" : "chevron.left")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                                .padding(5)
                                .background(Circle().fill(Color(white: 0.15)))
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .scale))
                    }
                }
                .frame(width: 12)
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) { isHoveringDivider = hovering }
                }

                // Main content (fills remaining space)
                contentForTab(selectedTab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(\.cortexSelectedSection, selectedSection)

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
            .animation(.easeInOut(duration: 0.25), value: contextPaneMode)
            .animation(.easeInOut(duration: 0.25), value: isAIPaneVisible)
        }
        .background(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)))
        // Disable global ⌘ shortcuts (incl. the ⌘K kill switch and ⌘1-9 tab jumps)
        // while the command palette is capturing keystrokes.
        .background { keyboardShortcuts.disabled(showCommandPalette) }
        .overlay {
            if showCommandPalette {
                CommandPalette(isPresented: $showCommandPalette) { tab in selectedTab = tab }
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            selectedSection = newTab.defaultSection
            // Clear selected symbol when leaving stock-specific tabs
            if newTab != .markets && newTab != .financials {
                environment.chat.selectedSymbol = ""
            }
        }
    }

    // MARK: - Content Router

    @ViewBuilder
    private func contentForTab(_ tab: AppTab) -> some View {
        switch tab {
        case .warRoom:
            WarRoomView(environment: environment)
        case .markets:
            ChartView(chatStore: environment.chat)
        case .scanner:
            ScannerView(opportunities: environment.opportunities, scannerFilter: environment.scannerFilter, webSocket: environment.webSocket, onAnalyzeWithAI: { prompt in
                environment.chat.inputText = prompt
                environment.chat.sendMessage()
                withAnimation(.easeInOut(duration: 0.25)) { isAIPaneVisible = true }
            })
        case .trade:
            TradeView(environment: environment)
        case .financials:
            FinancialsView(store: environment.financials, chatStore: environment.chat, optionsStore: environment.options)
        case .watchlist:
            WatchlistView(store: environment.watchlist, alertStore: environment.alerts)
        case .squadrons:
            SquadronsDetailView(squadrons: environment.squadrons, webSocket: environment.webSocket)
        case .performance:
            PerformanceDashboardView(store: environment.performance)
        case .geoIntelligence:
            GeoIntelligenceView(store: environment.geoIntelligence, rates: environment.macroRates)
        case .settings:
            SettingsView(settings: environment.settings)
        }
    }

    // MARK: - Keyboard Shortcuts

    @ViewBuilder
    private var keyboardShortcuts: some View {
        // Cmd+B: Cycle context pane mode (full -> iconOnly -> hidden -> full)
        Button("") {
            withAnimation(.easeInOut(duration: 0.25)) {
                contextPaneMode = contextPaneMode.next
            }
        }
        .keyboardShortcut("b", modifiers: .command)
        .hidden()

        // Cmd+[: Also cycles context pane mode
        Button("") {
            withAnimation(.easeInOut(duration: 0.25)) {
                contextPaneMode = contextPaneMode.next
            }
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

        // Cmd+Shift+P: Command palette (Bloomberg-style mnemonic line; ⌘K is the
        // kill switch, so the palette uses ⌘⇧P).
        Button("") { showCommandPalette = true }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .hidden()

        // Cmd+1 through Cmd+9: Switch tabs
        ForEach(AppTab.allCases) { tab in
            if let shortcut = tab.shortcut {
                Button("") { selectedTab = tab }
                    .keyboardShortcut(shortcut, modifiers: .command)
                    .hidden()
            }
        }
    }
}

