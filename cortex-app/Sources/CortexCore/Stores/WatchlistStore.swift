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

    /// Default watchlist symbols — prices populate from the backend via WebSocket.
    private static let defaultSymbols = ["AAPL", "NVDA", "MSFT", "TSLA", "META", "AMZN", "GOOG", "SPY", "QQQ"]

    public init() {
        // Pre-populate with default symbols (prices = 0 until backend connects)
        items = Self.defaultSymbols.map { WatchlistItem(symbol: $0, price: 0) }
        // Positions populate from broker connection — empty until then
    }

    public func updatePrice(symbol: String, price: Double, change: Double, changePercent: Double) {
        if let idx = items.firstIndex(where: { $0.symbol == symbol }) {
            items[idx].price = price
            items[idx].change = change
            items[idx].changePercent = changePercent
            items[idx].lastUpdate = Date()
        } else {
            // New symbol from backend — add it to the watchlist
            items.append(WatchlistItem(symbol: symbol, price: price, change: change, changePercent: changePercent))
        }
    }

    public var totalUnrealizedPnL: Double {
        positions.reduce(0) { $0 + $1.unrealizedPnL }
    }
}
