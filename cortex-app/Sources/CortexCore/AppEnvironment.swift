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

    public init() {}
}
