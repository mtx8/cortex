import Foundation

/// Direction of a trading opportunity.
public enum OpportunityDirection: String, Sendable, CaseIterable {
    case long = "LONG"
    case short = "SHORT"
}

/// A scanner opportunity detected by the CORTEX agent system.
public struct Opportunity: Identifiable, Sendable {
    public let id: String
    public let ticker: String
    public let compositeScore: Double  // 0-100
    public let type: OpportunityType
    public let thesis: String
    public let riskReward: Double
    public let timestamp: Date
    public let direction: OpportunityDirection
    public let sector: String?
    public let market: String?
    public let marketCap: String?
    public let shortInterest: Double?
    public let aiInsight: String?
    public let entryPrice: Double?
    public let exitPrice: Double?
    public let stopLoss: Double?
    public let timeHorizon: String?

    public enum OpportunityType: String, Sendable, CaseIterable {
        case momentum = "Momentum"
        case volume = "Volume"
        case catalyst = "Catalyst"
        case breakout = "Breakout"
        case reversal = "Reversal"
        case flow = "Flow"
        case earnings = "Earnings"
        case sector = "Sector"
    }

    public init(
        id: String = UUID().uuidString,
        ticker: String,
        compositeScore: Double,
        type: OpportunityType,
        thesis: String,
        riskReward: Double,
        timestamp: Date = Date(),
        direction: OpportunityDirection = .long,
        sector: String? = nil,
        market: String? = nil,
        marketCap: String? = nil,
        shortInterest: Double? = nil,
        aiInsight: String? = nil,
        entryPrice: Double? = nil,
        exitPrice: Double? = nil,
        stopLoss: Double? = nil,
        timeHorizon: String? = nil
    ) {
        self.id = id
        self.ticker = ticker
        self.compositeScore = compositeScore
        self.type = type
        self.thesis = thesis
        self.riskReward = riskReward
        self.timestamp = timestamp
        self.direction = direction
        self.sector = sector
        self.market = market
        self.marketCap = marketCap
        self.shortInterest = shortInterest
        self.aiInsight = aiInsight
        self.entryPrice = entryPrice
        self.exitPrice = exitPrice
        self.stopLoss = stopLoss
        self.timeHorizon = timeHorizon
    }
}

/// Store for scanner opportunities detected by the agent system.
@MainActor
@Observable
public final class OpportunityStore {
    public var opportunities: [Opportunity] = []

    public init() {}

    /// Top 10 opportunities sorted by composite score.
    public var top10: [Opportunity] {
        Array(opportunities.sorted { $0.compositeScore > $1.compositeScore }.prefix(10))
    }

    /// Top 5 opportunities sorted by composite score.
    public var top5: [Opportunity] {
        Array(opportunities.sorted { $0.compositeScore > $1.compositeScore }.prefix(5))
    }

    public func append(_ opportunity: Opportunity) {
        // Replace if same ticker already exists, otherwise insert
        if let idx = opportunities.firstIndex(where: { $0.ticker == opportunity.ticker }) {
            opportunities[idx] = opportunity
        } else {
            opportunities.append(opportunity)
        }
    }

    public func apply(_ data: [String: Any]) {
        let dirStr = data["direction"] as? String ?? "LONG"
        let dir: OpportunityDirection = dirStr.uppercased() == "SHORT" ? .short : .long
        let opp = Opportunity(
            id: data["id"] as? String ?? UUID().uuidString,
            ticker: data["ticker"] as? String ?? "???",
            compositeScore: data["composite_score"] as? Double ?? 0,
            type: Opportunity.OpportunityType(rawValue: data["type"] as? String ?? "Momentum") ?? .momentum,
            thesis: data["thesis"] as? String ?? "",
            riskReward: data["risk_reward"] as? Double ?? 0,
            timestamp: Date(),
            direction: dir,
            sector: data["sector"] as? String,
            market: data["market"] as? String,
            marketCap: data["market_cap"] as? String,
            shortInterest: data["short_interest"] as? Double,
            aiInsight: data["ai_insight"] as? String
        )
        append(opp)
    }

    public func loadMockData() {
        let mockOpps: [(String, Double, Opportunity.OpportunityType, String, Double, OpportunityDirection, String?, String?, Double?)] = [
            ("NVDA", 92, .breakout, "Breaking above $890 resistance with 1.8x volume. MACD crossover bullish. Institutional flow positive.", 2.1, .long, "Technology", "Mega", nil),
            ("META", 87, .momentum, "RSI bounce from oversold. AD line improving. Social media sector rotation underway.", 1.8, .long, "Communication", "Mega", nil),
            ("AAPL", 82, .catalyst, "iPhone sales data exceeding estimates. Services revenue acceleration. Buyback support.", 1.6, .long, "Technology", "Mega", nil),
            ("AMD", 79, .volume, "Unusual volume spike 2.5x average. Large call sweeps at $180 strike. AI chip demand narrative.", 1.9, .long, "Technology", "Large", nil),
            ("MSFT", 76, .earnings, "Pre-earnings consolidation at support. Azure growth accelerating per channel checks.", 1.5, .long, "Technology", "Mega", nil),
            ("COIN", 73, .flow, "Large institutional flow detected. Bitcoin correlation breakout. Regulatory clarity improving.", 2.3, .long, "Financials", "Large", nil),
            ("PLTR", 70, .momentum, "Government contract pipeline expanding. AI narrative tailwind. Breaking out of base.", 1.7, .long, "Technology", "Mid", nil),
            ("TSLA", 65, .reversal, "Oversold bounce setup. RSI 32, below lower Bollinger Band. Short interest elevated.", 1.4, .short, "Consumer Disc.", "Mega", 8.5),
            ("NFLX", 62, .sector, "Streaming sector rotation. Ad tier growth exceeding expectations. International expansion.", 1.3, .long, "Communication", "Large", nil),
            ("BA", 58, .catalyst, "FAA certification progress stalling. Order cancellations mounting. Cash burn accelerating.", 1.6, .short, "Industrials", "Large", 5.2),
            ("JPM", 55, .earnings, "Net interest income guidance raised. Trading desk revenue strong. Dividend yield attractive.", 1.2, .long, "Financials", "Mega", nil),
            ("SOFI", 52, .breakout, "Breaking above 200-day MA. Student loan tailwind. Fintech sector strength.", 2.0, .long, "Financials", "Mid", nil),
        ]

        for (i, (ticker, score, type, thesis, rr, dir, sector, cap, si)) in mockOpps.enumerated() {
            opportunities.append(Opportunity(
                id: "mock_opp_\(i)",
                ticker: ticker,
                compositeScore: score,
                type: type,
                thesis: thesis,
                riskReward: rr,
                timestamp: Date().addingTimeInterval(Double(-i * 300)),
                direction: dir,
                sector: sector,
                market: "US Stocks",
                marketCap: cap,
                shortInterest: si,
                aiInsight: "AI analysis available for \(ticker)"
            ))
        }
    }
}
