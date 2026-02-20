import Foundation
import SwiftUI

@MainActor
@Observable
public final class AppEnvironment {
    public let portfolio = PortfolioStore()
    public let squadrons = SquadronStore()
    public let killSwitch = KillSwitchStore()
    public let signalFeed = SignalFeedStore()
    public let activity = ActivityStore()
    public let settings = SettingsStore()
    public let performance = PerformanceStore()
    public let watchlist = WatchlistStore()
    public let chat = ChatStore()
    public let webSocket = WebSocketClient()
    public let search = SearchStore()
    public let opportunities = OpportunityStore()
    public let scannerFilter = ScannerFilterStore()
    public let financials = FinancialsStore()
    public let trade = TradeStore()
    public let level2 = Level2Store()
    public let options = OptionsStore()
    public let simulation = SimulationStore()
    public let alerts = AlertStore()

    public init() {
        // Stores populate from WebSocket when backend is connected.
        // No mock data — real data only.
        // WebSocket wiring is done in MessageRouter.setupRouting()
        // to keep all wiring in one place.
        settings.webSocket = webSocket
        search.webSocket = webSocket
    }
}

// MARK: - Selected Section Environment Key

public struct CortexSelectedSectionKey: EnvironmentKey {
    public static let defaultValue: String = "Overview"
}

public extension EnvironmentValues {
    var cortexSelectedSection: String {
        get { self[CortexSelectedSectionKey.self] }
        set { self[CortexSelectedSectionKey.self] = newValue }
    }
}
