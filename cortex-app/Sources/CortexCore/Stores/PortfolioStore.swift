import Foundation

@MainActor
@Observable
public final class PortfolioStore {
    public var totalPnL: Double = 0.0
    public var dailyPnL: Double = 0.0
    public var winRate: Double = 0.0
    public var sharpeRatio: Double = 0.0
    public var buyingPower: Double = 0.0
    public var openPositionCount: Int = 0
    public var nav: Double = 0.0

    public init() {}

    public func apply(_ update: [String: Any]) {
        if let nav = update["nav"] as? Double { self.nav = nav }
        if let pnl = update["total_pnl"] as? Double { self.totalPnL = pnl }
        if let daily = update["daily_pnl"] as? Double { self.dailyPnL = daily }
        if let wr = update["win_rate"] as? Double { self.winRate = wr }
        if let sr = update["sharpe_ratio"] as? Double { self.sharpeRatio = sr }
        if let bp = update["buying_power"] as? Double { self.buyingPower = bp }
        if let pos = update["position_count"] as? Int { self.openPositionCount = pos }
    }
}
