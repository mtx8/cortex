import Foundation

// MARK: - Models

public struct Level2Row: Identifiable, Sendable {
    public let id = UUID()
    public var price: Double
    public var size: Int
    public var orders: Int

    public init(price: Double, size: Int, orders: Int = 0) {
        self.price = price
        self.size = size
        self.orders = orders
    }
}

public struct TimeSalesTick: Identifiable, Sendable {
    public let id = UUID()
    public var price: Double
    public var size: Int
    public var time: Date
    public var side: String  // "buy", "sell"

    public init(price: Double, size: Int, time: Date = Date(), side: String = "buy") {
        self.price = price
        self.size = size
        self.time = time
        self.side = side
    }
}

// MARK: - Store

@MainActor
@Observable
public final class Level2Store {
    public var bids: [Level2Row] = []
    public var asks: [Level2Row] = []
    public var timeSales: [TimeSalesTick] = []
    public var activeSymbol: String = ""

    /// Maximum depth shown in the book
    public var maxSize: Int {
        max(
            bids.map(\.size).max() ?? 1,
            asks.map(\.size).max() ?? 1
        )
    }

    public init() {}

    // MARK: - Apply (called by MessageRouter)

    public func applyL2Update(_ data: [String: Any]) {
        activeSymbol = data["symbol"] as? String ?? activeSymbol

        if let bidData = data["bids"] as? [[String: Any]] {
            bids = bidData.map {
                Level2Row(
                    price: $0["price"] as? Double ?? 0,
                    size: $0["size"] as? Int ?? 0,
                    orders: $0["orders"] as? Int ?? 0
                )
            }
        }
        if let askData = data["asks"] as? [[String: Any]] {
            asks = askData.map {
                Level2Row(
                    price: $0["price"] as? Double ?? 0,
                    size: $0["size"] as? Int ?? 0,
                    orders: $0["orders"] as? Int ?? 0
                )
            }
        }
    }

    public func applyTimeSales(_ data: [String: Any]) {
        if let ticks = data["ticks"] as? [[String: Any]] {
            let newTicks = ticks.map { t in
                TimeSalesTick(
                    price: t["price"] as? Double ?? 0,
                    size: t["size"] as? Int ?? 0,
                    side: t["side"] as? String ?? "buy"
                )
            }
            timeSales.insert(contentsOf: newTicks, at: 0)
            if timeSales.count > 200 {
                timeSales = Array(timeSales.prefix(200))
            }
        }
    }
}
