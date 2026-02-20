import Foundation

// MARK: - Models

public struct SimulationEquityPoint: Identifiable, Sendable {
    public let id = UUID()
    public var date: Date
    public var equity: Double

    public init(date: Date = Date(), equity: Double) {
        self.date = date
        self.equity = equity
    }
}

public struct SimulationTrade: Identifiable, Sendable {
    public let id: String
    public var symbol: String
    public var side: String
    public var quantity: Int
    public var entryPrice: Double
    public var exitPrice: Double?
    public var pnl: Double?
    public var entryTime: Date
    public var exitTime: Date?

    public init(
        id: String = UUID().uuidString,
        symbol: String,
        side: String,
        quantity: Int,
        entryPrice: Double,
        exitPrice: Double? = nil,
        pnl: Double? = nil,
        entryTime: Date = Date(),
        exitTime: Date? = nil
    ) {
        self.id = id
        self.symbol = symbol
        self.side = side
        self.quantity = quantity
        self.entryPrice = entryPrice
        self.exitPrice = exitPrice
        self.pnl = pnl
        self.entryTime = entryTime
        self.exitTime = exitTime
    }
}

public struct LearningInsight: Identifiable, Sendable {
    public let id: String
    public var category: String      // "pattern", "risk", "timing", "strategy"
    public var title: String
    public var description: String
    public var confidence: Double     // 0.0 to 1.0
    public var timestamp: Date

    public init(
        id: String = UUID().uuidString,
        category: String = "pattern",
        title: String,
        description: String,
        confidence: Double = 0.5,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.description = description
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

// MARK: - Store

@MainActor
@Observable
public final class SimulationStore {
    public var isRunning: Bool = false
    public var startingCapital: Double = 100_000
    public var currentEquity: Double = 100_000
    public var equityCurve: [SimulationEquityPoint] = []
    public var trades: [SimulationTrade] = []
    public var insights: [LearningInsight] = []
    public var speed: SimulationSpeed = .normal
    public var webSocket: WebSocketClient?

    // MARK: - Stats

    public var totalTrades: Int { trades.count }
    public var winningTrades: Int { trades.filter { ($0.pnl ?? 0) > 0 }.count }
    public var losingTrades: Int { trades.filter { ($0.pnl ?? 0) < 0 }.count }
    public var winRate: Double { totalTrades > 0 ? Double(winningTrades) / Double(totalTrades) * 100 : 0 }
    public var totalPnL: Double { trades.compactMap(\.pnl).reduce(0, +) }
    public var returnPercent: Double {
        startingCapital > 0 ? ((currentEquity - startingCapital) / startingCapital) * 100 : 0
    }
    public var maxDrawdown: Double {
        guard !equityCurve.isEmpty else { return 0 }
        var peak = equityCurve[0].equity
        var maxDD = 0.0
        for point in equityCurve {
            peak = max(peak, point.equity)
            let dd = (peak - point.equity) / peak * 100
            maxDD = max(maxDD, dd)
        }
        return maxDD
    }
    public var sharpeRatio: Double {
        guard trades.count > 1 else { return 0 }
        let returns = trades.compactMap(\.pnl)
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(returns.count - 1)
        let stdDev = sqrt(variance)
        return stdDev > 0 ? (mean / stdDev) * sqrt(252) : 0
    }

    public enum SimulationSpeed: String, CaseIterable, Sendable {
        case slow = "0.5x"
        case normal = "1x"
        case fast = "2x"
        case turbo = "5x"
    }

    public init() {}

    // MARK: - Actions

    public func start() {
        isRunning = true
        let msg: [String: Any] = [
            "type": "cmd_simulation_start",
            "payload": [
                "starting_capital": startingCapital,
                "speed": speed.rawValue,
            ] as [String: Any],
        ]
        Task { @MainActor in
            try? await webSocket?.send(msg)
        }
    }

    public func stop() {
        isRunning = false
        let msg: [String: Any] = ["type": "cmd_simulation_stop", "payload": [:] as [String: Any]]
        Task { @MainActor in
            try? await webSocket?.send(msg)
        }
    }

    public func reset() {
        isRunning = false
        currentEquity = startingCapital
        equityCurve = []
        trades = []
        insights = []
    }

    public func setSpeed(_ newSpeed: SimulationSpeed) {
        speed = newSpeed
        if isRunning {
            let msg: [String: Any] = [
                "type": "cmd_simulation_speed",
                "payload": ["speed": newSpeed.rawValue],
            ]
            Task { @MainActor in
                try? await webSocket?.send(msg)
            }
        }
    }

    // MARK: - Apply (called by MessageRouter)

    public func applySimulationUpdate(_ data: [String: Any]) {
        if let equity = data["equity"] as? Double {
            currentEquity = equity
            equityCurve.append(SimulationEquityPoint(equity: equity))
        }

        if let running = data["is_running"] as? Bool {
            isRunning = running
        }

        if let tradeData = data["trade"] as? [String: Any] {
            let trade = SimulationTrade(
                id: tradeData["id"] as? String ?? UUID().uuidString,
                symbol: tradeData["symbol"] as? String ?? "",
                side: tradeData["side"] as? String ?? "BUY",
                quantity: tradeData["quantity"] as? Int ?? 0,
                entryPrice: tradeData["entry_price"] as? Double ?? 0,
                exitPrice: tradeData["exit_price"] as? Double,
                pnl: tradeData["pnl"] as? Double
            )
            if let idx = trades.firstIndex(where: { $0.id == trade.id }) {
                trades[idx] = trade
            } else {
                trades.append(trade)
            }
        }
    }

    public func applyLearningInsight(_ data: [String: Any]) {
        let insight = LearningInsight(
            id: data["id"] as? String ?? UUID().uuidString,
            category: data["category"] as? String ?? "pattern",
            title: data["title"] as? String ?? "",
            description: data["description"] as? String ?? "",
            confidence: data["confidence"] as? Double ?? 0.5
        )
        // Avoid duplicates
        if !insights.contains(where: { $0.id == insight.id }) {
            insights.insert(insight, at: 0)
            if insights.count > 50 {
                insights = Array(insights.prefix(50))
            }
        }
    }
}
