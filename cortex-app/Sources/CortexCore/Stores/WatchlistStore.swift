import Foundation

public struct WatchlistItem: Identifiable, Sendable {
    public let id: String
    public let symbol: String
    public var price: Double
    public var change: Double
    public var changePercent: Double
    public var volume: Double
    public var rsi: Double?
    public var signal: String? // "buy", "sell", "neutral"
    public var lastUpdate: Date

    public init(symbol: String, price: Double, change: Double = 0, changePercent: Double = 0,
                volume: Double = 0, rsi: Double? = nil, signal: String? = nil) {
        self.id = symbol
        self.symbol = symbol
        self.price = price
        self.change = change
        self.changePercent = changePercent
        self.volume = volume
        self.rsi = rsi
        self.signal = signal
        self.lastUpdate = Date()
    }
}

public struct Position: Identifiable, Sendable {
    public let id: String
    public let symbol: String
    public let side: String // "long" or "short"
    public let quantity: Int
    public let entryPrice: Double
    public var currentPrice: Double
    public let stopLoss: Double
    public var unrealizedPnL: Double { Double(quantity) * (currentPrice - entryPrice) * (side == "long" ? 1 : -1) }
    public var pnlPercent: Double { (currentPrice - entryPrice) / entryPrice * 100 * (side == "long" ? 1 : -1) }

    public init(symbol: String, side: String, quantity: Int, entryPrice: Double,
                currentPrice: Double, stopLoss: Double) {
        self.id = "\(symbol)-\(side)"
        self.symbol = symbol
        self.side = side
        self.quantity = quantity
        self.entryPrice = entryPrice
        self.currentPrice = currentPrice
        self.stopLoss = stopLoss
    }
}

@MainActor
@Observable
public final class WatchlistStore {
    public var items: [WatchlistItem] = []
    public var positions: [Position] = []
    public var selectedSymbol: String?

    public init() {
        // Pre-populate with mock data so the app isn't empty
        items = [
            WatchlistItem(symbol: "AAPL", price: 188.52, change: 2.34, changePercent: 1.26, volume: 48_500_000, rsi: 58.3, signal: "buy"),
            WatchlistItem(symbol: "NVDA", price: 892.45, change: 15.67, changePercent: 1.79, volume: 52_300_000, rsi: 62.1, signal: "buy"),
            WatchlistItem(symbol: "MSFT", price: 415.20, change: -1.80, changePercent: -0.43, volume: 22_100_000, rsi: 51.7, signal: "neutral"),
            WatchlistItem(symbol: "TSLA", price: 172.30, change: -5.45, changePercent: -3.07, volume: 95_200_000, rsi: 38.2, signal: "sell"),
            WatchlistItem(symbol: "META", price: 502.15, change: 8.90, changePercent: 1.80, volume: 18_700_000, rsi: 64.5, signal: "buy"),
            WatchlistItem(symbol: "AMZN", price: 178.90, change: 0.45, changePercent: 0.25, volume: 35_600_000, rsi: 49.8, signal: "neutral"),
            WatchlistItem(symbol: "GOOG", price: 147.85, change: 1.20, changePercent: 0.82, volume: 24_300_000, rsi: 55.2, signal: "neutral"),
            WatchlistItem(symbol: "SPY", price: 512.30, change: 3.15, changePercent: 0.62, volume: 78_900_000, rsi: 56.8, signal: "neutral"),
            WatchlistItem(symbol: "QQQ", price: 445.67, change: 5.23, changePercent: 1.19, volume: 42_100_000, rsi: 59.4, signal: "buy"),
            WatchlistItem(symbol: "BTC-USD", price: 67_245.00, change: 1_234.00, changePercent: 1.87, volume: 28_500_000_000, rsi: 61.0, signal: "buy"),
        ]

        positions = [
            Position(symbol: "AAPL", side: "long", quantity: 3, entryPrice: 185.00, currentPrice: 188.52, stopLoss: 181.00),
            Position(symbol: "NVDA", side: "long", quantity: 1, entryPrice: 880.00, currentPrice: 892.45, stopLoss: 870.00),
            Position(symbol: "SPY", side: "long", quantity: 1, entryPrice: 510.00, currentPrice: 512.30, stopLoss: 505.00),
        ]
    }

    public func updatePrice(symbol: String, price: Double, change: Double, changePercent: Double) {
        if let idx = items.firstIndex(where: { $0.symbol == symbol }) {
            items[idx].price = price
            items[idx].change = change
            items[idx].changePercent = changePercent
            items[idx].lastUpdate = Date()
        }
    }

    public var totalUnrealizedPnL: Double {
        positions.reduce(0) { $0 + $1.unrealizedPnL }
    }
}
