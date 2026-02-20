import Foundation

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

    public init() {
        // Stores populate from WebSocket when backend is connected.
        // No mock data — real data only.
        // WebSocket wiring is done in MessageRouter.setupRouting()
        // to keep all wiring in one place.
        settings.webSocket = webSocket
        search.webSocket = webSocket
    }
}
