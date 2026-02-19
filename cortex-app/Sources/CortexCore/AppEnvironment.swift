import Foundation

@MainActor
@Observable
public final class AppEnvironment {
    public let portfolio = PortfolioStore()
    public let squadrons = SquadronStore()
    public let killSwitch = KillSwitchStore()
    public let signalFeed = SignalFeedStore()
    public let activity = ActivityStore()

    public init() {}
}
