import SwiftUI
import CortexCore

/// Main navigation shell providing tabbed access to the three primary views.
struct ContentView: View {
    let environment: AppEnvironment

    var body: some View {
        TabView {
            WarRoomView(environment: environment)
                .tabItem {
                    Label("War Room", systemImage: "shield.fill")
                }

            ChartView(symbol: "AAPL")
                .tabItem {
                    Label("Charts", systemImage: "chart.xyaxis.line")
                }

            WatchlistView(store: environment.watchlist)
                .tabItem {
                    Label("Watchlist", systemImage: "list.bullet.rectangle")
                }

            PerformanceDashboardView(store: environment.performance)
                .tabItem {
                    Label("Performance", systemImage: "chart.line.uptrend.xyaxis")
                }

            ChatView(store: environment.chat)
                .tabItem {
                    Label("CORTEX AI", systemImage: "brain.head.profile")
                }

            SettingsView(settings: environment.settings)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
    }
}
