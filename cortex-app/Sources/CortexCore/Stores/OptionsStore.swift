import Foundation

// MARK: - Models

public struct OptionContract: Identifiable, Sendable {
    public let id: String
    public var strike: Double
    public var expiration: Date
    public var optionType: OptionType  // call or put
    public var bid: Double
    public var ask: Double
    public var last: Double
    public var volume: Int
    public var openInterest: Int
    public var impliedVolatility: Double
    public var delta: Double
    public var gamma: Double
    public var theta: Double
    public var vega: Double

    public enum OptionType: String, Sendable, CaseIterable {
        case call = "Call"
        case put = "Put"
    }

    public init(
        id: String = UUID().uuidString,
        strike: Double,
        expiration: Date = Date(),
        optionType: OptionType,
        bid: Double = 0,
        ask: Double = 0,
        last: Double = 0,
        volume: Int = 0,
        openInterest: Int = 0,
        impliedVolatility: Double = 0,
        delta: Double = 0,
        gamma: Double = 0,
        theta: Double = 0,
        vega: Double = 0
    ) {
        self.id = id
        self.strike = strike
        self.expiration = expiration
        self.optionType = optionType
        self.bid = bid
        self.ask = ask
        self.last = last
        self.volume = volume
        self.openInterest = openInterest
        self.impliedVolatility = impliedVolatility
        self.delta = delta
        self.gamma = gamma
        self.theta = theta
        self.vega = vega
    }
}

public struct OptionLeg: Identifiable, Sendable {
    public let id: String
    public var contract: OptionContract
    public var side: LegSide  // buy or sell
    public var quantity: Int

    public enum LegSide: String, Sendable, CaseIterable {
        case buy = "Buy"
        case sell = "Sell"
    }

    public init(
        id: String = UUID().uuidString,
        contract: OptionContract,
        side: LegSide,
        quantity: Int = 1
    ) {
        self.id = id
        self.contract = contract
        self.side = side
        self.quantity = quantity
    }
}

public struct ProfitPoint: Identifiable, Sendable {
    public let id = UUID()
    public var price: Double
    public var profit: Double

    public init(price: Double, profit: Double) {
        self.price = price
        self.profit = profit
    }
}

// MARK: - Store

@MainActor
@Observable
public final class OptionsStore {
    public var activeSymbol: String = ""
    public var selectedExpiration: Date?
    public var expirations: [Date] = []
    public var calls: [OptionContract] = []
    public var puts: [OptionContract] = []
    public var selectedLegs: [OptionLeg] = []
    public var profitCurve: [ProfitPoint] = []
    public var maxProfit: Double?
    public var maxLoss: Double?
    public var breakevens: [Double] = []
    public var isLoading: Bool = false
    public var underlyingPrice: Double = 0
    public var webSocket: WebSocketClient?

    public init() {}

    // MARK: - Actions

    public func requestChain(symbol: String, expiration: Date? = nil) {
        activeSymbol = symbol.uppercased()
        isLoading = true
        var payload: [String: Any] = ["symbol": activeSymbol]
        if let exp = expiration {
            let formatter = ISO8601DateFormatter()
            payload["expiration"] = formatter.string(from: exp)
        }
        let msg: [String: Any] = ["type": "cmd_option_chain", "payload": payload]
        Task { @MainActor in
            try? await webSocket?.send(msg)
        }
    }

    public func addLeg(_ contract: OptionContract, side: OptionLeg.LegSide, quantity: Int = 1) {
        selectedLegs.append(OptionLeg(contract: contract, side: side, quantity: quantity))
        requestProfitCalculation()
    }

    public func removeLeg(id: String) {
        selectedLegs.removeAll { $0.id == id }
        if selectedLegs.isEmpty {
            profitCurve = []
            maxProfit = nil
            maxLoss = nil
            breakevens = []
        } else {
            requestProfitCalculation()
        }
    }

    public func clearLegs() {
        selectedLegs = []
        profitCurve = []
        maxProfit = nil
        maxLoss = nil
        breakevens = []
    }

    private func requestProfitCalculation() {
        guard !selectedLegs.isEmpty else { return }
        let legs: [[String: Any]] = selectedLegs.map { leg in
            [
                "strike": leg.contract.strike,
                "type": leg.contract.optionType.rawValue.lowercased(),
                "side": leg.side.rawValue.lowercased(),
                "quantity": leg.quantity,
                "premium": leg.side == .buy ? leg.contract.ask : leg.contract.bid,
            ]
        }
        let msg: [String: Any] = [
            "type": "cmd_profit_calc",
            "payload": [
                "symbol": activeSymbol,
                "underlying_price": underlyingPrice,
                "legs": legs,
            ] as [String: Any],
        ]
        Task { @MainActor in
            try? await webSocket?.send(msg)
        }
    }

    // MARK: - Apply (called by MessageRouter)

    public func applyOptionChain(_ data: [String: Any]) {
        isLoading = false
        activeSymbol = data["symbol"] as? String ?? activeSymbol
        underlyingPrice = data["underlying_price"] as? Double ?? underlyingPrice

        if let expStrings = data["expirations"] as? [String] {
            let formatter = ISO8601DateFormatter()
            expirations = expStrings.compactMap { formatter.date(from: $0) }
            if selectedExpiration == nil, let first = expirations.first {
                selectedExpiration = first
            }
        }

        if let callData = data["calls"] as? [[String: Any]] {
            calls = callData.map { parseContract($0, type: .call) }
        }
        if let putData = data["puts"] as? [[String: Any]] {
            puts = putData.map { parseContract($0, type: .put) }
        }
    }

    public func applyProfitCalculation(_ data: [String: Any]) {
        if let curveData = data["curve"] as? [[String: Any]] {
            profitCurve = curveData.map {
                ProfitPoint(
                    price: $0["price"] as? Double ?? 0,
                    profit: $0["profit"] as? Double ?? 0
                )
            }
        }
        maxProfit = data["max_profit"] as? Double
        maxLoss = data["max_loss"] as? Double
        if let bkevens = data["breakevens"] as? [Double] {
            breakevens = bkevens
        }
    }

    // MARK: - Helpers

    private func parseContract(_ data: [String: Any], type: OptionContract.OptionType) -> OptionContract {
        let expStr = data["expiration"] as? String ?? ""
        let exp = ISO8601DateFormatter().date(from: expStr) ?? Date()

        return OptionContract(
            id: data["id"] as? String ?? UUID().uuidString,
            strike: data["strike"] as? Double ?? 0,
            expiration: exp,
            optionType: type,
            bid: data["bid"] as? Double ?? 0,
            ask: data["ask"] as? Double ?? 0,
            last: data["last"] as? Double ?? 0,
            volume: data["volume"] as? Int ?? 0,
            openInterest: data["open_interest"] as? Int ?? 0,
            impliedVolatility: data["iv"] as? Double ?? 0,
            delta: data["delta"] as? Double ?? 0,
            gamma: data["gamma"] as? Double ?? 0,
            theta: data["theta"] as? Double ?? 0,
            vega: data["vega"] as? Double ?? 0
        )
    }

    /// Unique strikes across calls and puts, sorted ascending.
    public var strikes: [Double] {
        let allStrikes = Set(calls.map(\.strike) + puts.map(\.strike))
        return allStrikes.sorted()
    }

    /// Get the call contract for a given strike.
    public func call(at strike: Double) -> OptionContract? {
        calls.first { $0.strike == strike }
    }

    /// Get the put contract for a given strike.
    public func put(at strike: Double) -> OptionContract? {
        puts.first { $0.strike == strike }
    }
}
