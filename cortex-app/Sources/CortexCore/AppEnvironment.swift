import Foundation

@MainActor
@Observable
public final class AppEnvironment {
    public let portfolio = PortfolioStore()
    public let squadrons = SquadronStore()
    public let killSwitch = KillSwitchStore()

    public init() {}
}
