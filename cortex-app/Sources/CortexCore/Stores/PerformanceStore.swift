import Foundation

public struct EquityPoint: Identifiable {
    public let id = UUID()
    public let date: Date
    public let value: Double
    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

public struct DailyPnLPoint: Identifiable {
    public let id = UUID()
    public let date: Date
    public let pnl: Double
    public var isPositive: Bool { pnl >= 0 }
    public init(date: Date, pnl: Double) {
        self.date = date
        self.pnl = pnl
    }
}

@MainActor
@Observable
public final class PerformanceStore {
    public var equityCurve: [EquityPoint] = []
    public var dailyPnL: [DailyPnLPoint] = []
    public var totalTrades: Int = 0
    public var winningTrades: Int = 0
    public var losingTrades: Int = 0
    public var bestDay: Double = 0.0
    public var worstDay: Double = 0.0
    public var currentStreak: Int = 0
    public var maxDrawdownPct: Double = 0.0

    public init() {}

    public var winRate: Double {
        guard totalTrades > 0 else { return 0 }
        return Double(winningTrades) / Double(totalTrades)
    }

    public var averageDailyPnL: Double {
        guard !dailyPnL.isEmpty else { return 0 }
        return dailyPnL.reduce(0) { $0 + $1.pnl } / Double(dailyPnL.count)
    }

    public func addEquityPoint(value: Double, date: Date = Date()) {
        equityCurve.append(EquityPoint(date: date, value: value))
    }

    public func addDailyPnL(pnl: Double, date: Date = Date()) {
        dailyPnL.append(DailyPnLPoint(date: date, pnl: pnl))
        if pnl > bestDay { bestDay = pnl }
        if pnl < worstDay { worstDay = pnl }
    }
}
