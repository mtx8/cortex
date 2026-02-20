import Foundation

// MARK: - Filter Enums

public enum Direction: String, CaseIterable, Identifiable, Sendable {
    case both = "Both"
    case long = "Long Only"
    case short = "Short Only"

    public var id: String { rawValue }
}

public enum Market: String, CaseIterable, Identifiable, Sendable {
    case all = "All Markets"
    case usStocks = "US Stocks"
    case crypto = "Crypto"

    public var id: String { rawValue }
}

public enum Sector: String, CaseIterable, Identifiable, Sendable {
    case all = "All Sectors"
    case technology = "Technology"
    case healthcare = "Healthcare"
    case financials = "Financials"
    case energy = "Energy"
    case consumerDiscretionary = "Consumer Disc."
    case consumerStaples = "Consumer Staples"
    case industrials = "Industrials"
    case materials = "Materials"
    case utilities = "Utilities"
    case realEstate = "Real Estate"
    case communication = "Communication"

    public var id: String { rawValue }
}

public enum CapSize: String, CaseIterable, Identifiable, Sendable {
    case all = "All Caps"
    case mega = "Mega"
    case large = "Large"
    case mid = "Mid"
    case small = "Small"
    case micro = "Micro"

    public var id: String { rawValue }
}

public enum SortField: String, CaseIterable, Identifiable, Sendable {
    case score = "Score"
    case ticker = "Ticker"
    case rr = "R:R"

    public var id: String { rawValue }
}

// MARK: - Scanner Filter Store

@MainActor
@Observable
public final class ScannerFilterStore {
    public var direction: Direction = .both
    public var market: Market = .all
    public var sector: Sector = .all
    public var capSize: CapSize = .all
    public var minScore: Double = 0
    public var sortBy: SortField = .score
    public var sortAscending: Bool = false

    public init() {}

    public func filtered(_ opportunities: [Opportunity]) -> [Opportunity] {
        var result = opportunities

        // Filter by direction
        switch direction {
        case .long:
            result = result.filter { $0.direction == .long }
        case .short:
            result = result.filter { $0.direction == .short }
        case .both:
            break
        }

        // Filter by market
        switch market {
        case .usStocks:
            result = result.filter { $0.market == "US Stocks" || $0.market == nil }
        case .crypto:
            result = result.filter { $0.market == "Crypto" }
        case .all:
            break
        }

        // Filter by sector
        if sector != .all {
            result = result.filter { $0.sector == sector.rawValue }
        }

        // Filter by cap size
        if capSize != .all {
            result = result.filter { $0.marketCap == capSize.rawValue }
        }

        // Filter by minimum score
        if minScore > 0 {
            result = result.filter { $0.compositeScore >= minScore }
        }

        // Sort
        switch sortBy {
        case .score:
            result.sort { sortAscending ? $0.compositeScore < $1.compositeScore : $0.compositeScore > $1.compositeScore }
        case .ticker:
            result.sort { sortAscending ? $0.ticker < $1.ticker : $0.ticker > $1.ticker }
        case .rr:
            result.sort { sortAscending ? $0.riskReward < $1.riskReward : $0.riskReward > $1.riskReward }
        }

        return result
    }

    public func resetFilters() {
        direction = .both
        market = .all
        sector = .all
        capSize = .all
        minScore = 0
        sortBy = .score
        sortAscending = false
    }

    public var activeFilterCount: Int {
        var count = 0
        if direction != .both { count += 1 }
        if market != .all { count += 1 }
        if sector != .all { count += 1 }
        if capSize != .all { count += 1 }
        if minScore > 0 { count += 1 }
        return count
    }
}
