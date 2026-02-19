import Foundation

public struct PortfolioUpdate {
    public let nav: Double
    public let dailyPnL: Double
    public let totalPnL: Double
    public let winRate: Double
    public let openPositions: Int

    public init(nav: Double = 0, dailyPnL: Double = 0, totalPnL: Double = 0, winRate: Double = 0, openPositions: Int = 0) {
        self.nav = nav
        self.dailyPnL = dailyPnL
        self.totalPnL = totalPnL
        self.winRate = winRate
        self.openPositions = openPositions
    }
}

public final class MessageDecoder {
    public init() {}

    public func decodePortfolioUpdate(_ payload: [String: Any]) -> PortfolioUpdate {
        PortfolioUpdate(
            nav: payload["nav"] as? Double ?? 0,
            dailyPnL: payload["daily_pnl"] as? Double ?? 0,
            totalPnL: payload["total_pnl"] as? Double ?? 0,
            winRate: payload["win_rate"] as? Double ?? 0,
            openPositions: payload["open_positions"] as? Int ?? 0
        )
    }

    public func decodeAgentUpdate(_ payload: [String: Any]) -> [String: Any] {
        return payload
    }
}
