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

            PerformanceDashboardView(store: environment.performance)
                .tabItem {
                    Label("Performance", systemImage: "chart.line.uptrend.xyaxis")
                }

            SettingsView(settings: environment.settings)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
    }
}
