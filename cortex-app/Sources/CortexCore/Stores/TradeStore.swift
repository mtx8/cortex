import Foundation

// MARK: - Models

public struct TradePosition: Identifiable, Sendable {
    public let id: String
    public var symbol: String
    public var quantity: Int
    public var avgPrice: Double
    public var currentPrice: Double
    public var unrealizedPnL: Double { Double(quantity) * (currentPrice - avgPrice) }
    public var pnlPercent: Double { avgPrice > 0 ? ((currentPrice - avgPrice) / avgPrice) * 100 : 0 }

    public init(
        id: String = UUID().uuidString,
        symbol: String,
        quantity: Int,
        avgPrice: Double,
        currentPrice: Double = 0
    ) {
        self.id = id
        self.symbol = symbol
        self.quantity = quantity
        self.avgPrice = avgPrice
        self.currentPrice = currentPrice
    }
}

public struct TradeOrder: Identifiable, Sendable {
    public let id: String
    public var symbol: String
    public var side: String          // "BUY", "SELL"
    public var quantity: Int
    public var orderType: String     // "MARKET", "LIMIT", "STOP"
    public var limitPrice: Double?
    public var status: String        // "pending", "filled", "cancelled"
    public var filledAt: Date?

    public init(
        id: String = UUID().uuidString,
        symbol: String,
        side: String,
        quantity: Int,
        orderType: String,
        limitPrice: Double? = nil,
        status: String = "pending"
    ) {
        self.id = id
        self.symbol = symbol
        self.side = side
        self.quantity = quantity
        self.orderType = orderType
        self.limitPrice = limitPrice
        self.status = status
    }
}

// MARK: - Store

@MainActor
@Observable
public final class TradeStore {
    public var positions: [TradePosition] = []
    public var orders: [TradeOrder] = []
    public var tradingMode: TradingMode = .manual
    public var activeSymbol: String = "AAPL"
    public var webSocket: WebSocketClient?

    public enum TradingMode: String, CaseIterable, Sendable {
        case manual = "Manual"
        case semiAuto = "Semi-Auto"
        case fullAuto = "Full Auto"
    }

    public init() {}

    // MARK: - Actions

    public func submitOrder(symbol: String, side: String, quantity: Int, type: String, price: Double?) {
        var payload: [String: Any] = [
            "symbol": symbol,
            "side": side,
            "quantity": quantity,
            "order_type": type,
        ]
        if let price { payload["price"] = price }

        let msg: [String: Any] = ["type": "cmd_submit_order", "payload": payload]
        Task { @MainActor in
            try? await webSocket?.send(msg)
        }
        orders.append(TradeOrder(
            symbol: symbol, side: side, quantity: quantity,
            orderType: type, limitPrice: price
        ))
    }

    public func cancelOrder(orderId: String) {
        let msg: [String: Any] = [
            "type": "cmd_cancel_order",
            "payload": ["order_id": orderId],
        ]
        Task { @MainActor in
            try? await webSocket?.send(msg)
        }
        if let idx = orders.firstIndex(where: { $0.id == orderId }) {
            orders[idx].status = "cancelled"
        }
    }

    public func setTradingMode(_ mode: TradingMode) {
        tradingMode = mode
        let msg: [String: Any] = [
            "type": "cmd_set_trading_mode",
            "payload": ["mode": mode.rawValue],
        ]
        Task { @MainActor in
            try? await webSocket?.send(msg)
        }
    }

    // MARK: - Apply (called by MessageRouter)

    public func applyPositionUpdate(_ data: [String: Any]) {
        guard let symbol = data["symbol"] as? String else { return }
        let qty = data["quantity"] as? Int ?? 0
        let avg = data["avg_price"] as? Double ?? 0
        let cur = data["current_price"] as? Double ?? 0

        if let idx = positions.firstIndex(where: { $0.symbol == symbol }) {
            positions[idx].quantity = qty
            positions[idx].avgPrice = avg
            positions[idx].currentPrice = cur
        } else if qty > 0 {
            positions.append(TradePosition(
                symbol: symbol, quantity: qty,
                avgPrice: avg, currentPrice: cur
            ))
        }
    }

    public func applyOrderStatus(_ data: [String: Any]) {
        guard let orderId = data["order_id"] as? String,
              let status = data["status"] as? String else { return }
        if let idx = orders.firstIndex(where: { $0.id == orderId }) {
            orders[idx].status = status
            if status == "filled" {
                orders[idx].filledAt = Date()
            }
        }
    }

    // MARK: - Computed

    public var totalUnrealizedPnL: Double {
        positions.reduce(0) { $0 + $1.unrealizedPnL }
    }

    public var pendingOrders: [TradeOrder] {
        orders.filter { $0.status == "pending" }
    }

    public var filledOrders: [TradeOrder] {
        orders.filter { $0.status == "filled" }
    }
}
