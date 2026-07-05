// Wire-protocol mirror of the Rust contract crate (cx-core).
// Source of truth: engine/crates/cx-core/src/events.rs + command.rs.
// Property names intentionally stay snake_case so JSON maps 1:1 with zero
// key-conversion drift. Do not "swiftify" these names.

import Foundation

// MARK: - Enums (serde snake_case raw values)

enum Side: String, Codable { case buy, sell }

enum OrderType: String, Codable { case market, limit }

enum Tif: String, Codable { case gtc, ioc, day }

enum Venue: String, Codable { case paper, coinbase, binance, cboe, synthetic }

enum Liquidity: String, Codable { case maker, taker }

enum Interval: String, Codable, CaseIterable, Identifiable {
    case s1, m1, m5, m15, h1, d1
    var id: String { rawValue }
    var label: String {
        switch self {
        case .s1: "1s"
        case .m1: "1m"
        case .m5: "5m"
        case .m15: "15m"
        case .h1: "1h"
        case .d1: "1d"
        }
    }
    var ms: Int64 {
        switch self {
        case .s1: 1_000
        case .m1: 60_000
        case .m5: 300_000
        case .m15: 900_000
        case .h1: 3_600_000
        case .d1: 86_400_000
        }
    }
}

enum AutonomyLevel: String, Codable, CaseIterable, Identifiable {
    case manual, suggest_only, semi_auto, full_auto
    var id: String { rawValue }
    var label: String {
        switch self {
        case .manual: "Manual"
        case .suggest_only: "Suggest"
        case .semi_auto: "Semi-Auto"
        case .full_auto: "Full Auto"
        }
    }
}

enum Severity: String, Codable, Comparable {
    case info, insight, warning, critical
    private var rank: Int {
        switch self {
        case .info: 0
        case .insight: 1
        case .warning: 2
        case .critical: 3
        }
    }
    static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
}

enum FeedHealth: String, Codable {
    case live, degraded, synthetic_fallback, down
}

// MARK: - Payloads

struct Tick: Codable, Equatable {
    var symbol: String
    var ts_ms: Int64
    var price: Double
    var size: Double
    var aggressor: Side?
    var venue: Venue
}

struct Bar: Codable, Equatable, Identifiable {
    var symbol: String
    var interval: Interval
    var ts_open_ms: Int64
    var open: Double
    var high: Double
    var low: Double
    var close: Double
    var volume: Double
    var trade_count: UInt64
    var vwap: Double
    var complete: Bool
    var id: Int64 { ts_open_ms }
}

struct BookTop: Codable, Equatable {
    var symbol: String
    var ts_ms: Int64
    var bid_px: Double
    var bid_sz: Double
    var ask_px: Double
    var ask_sz: Double
    var mid: Double { (bid_px + ask_px) / 2 }
}

/// serde: #[serde(tag = "kind", content = "name")]
enum OrderSource: Codable, Equatable {
    case strategy(String)
    case agent(String)
    case manual
    case riskFlatten

    private enum CodingKeys: String, CodingKey { case kind, name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "strategy": self = .strategy(try c.decode(String.self, forKey: .name))
        case "agent": self = .agent(try c.decode(String.self, forKey: .name))
        case "risk_flatten": self = .riskFlatten
        default: self = .manual
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .strategy(let n):
            try c.encode("strategy", forKey: .kind)
            try c.encode(n, forKey: .name)
        case .agent(let n):
            try c.encode("agent", forKey: .kind)
            try c.encode(n, forKey: .name)
        case .manual:
            try c.encode("manual", forKey: .kind)
        case .riskFlatten:
            try c.encode("risk_flatten", forKey: .kind)
        }
    }

    var label: String {
        switch self {
        case .strategy(let n): "strategy:\(n)"
        case .agent(let n): "agent:\(n)"
        case .manual: "manual"
        case .riskFlatten: "risk-flatten"
        }
    }
}

struct OrderIntent: Codable, Equatable {
    var id: UInt64
    var symbol: String
    var side: Side
    var qty: Double
    var order_type: OrderType
    var limit_px: Double?
    var tif: Tif
    var reduce_only: Bool
    var source: OrderSource
    var rationale: String
    var ts_ms: Int64
}

/// serde: #[serde(tag = "state")] — internally tagged.
enum OrderStatus: Codable, Equatable {
    case pendingRisk
    case rejectedByRisk(reason: String)
    case accepted
    case working
    case partiallyFilled
    case filled
    case canceled(reason: String)

    private enum CodingKeys: String, CodingKey { case state, reason }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .state) {
        case "pending_risk": self = .pendingRisk
        case "rejected_by_risk":
            self = .rejectedByRisk(reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "")
        case "accepted": self = .accepted
        case "working": self = .working
        case "partially_filled": self = .partiallyFilled
        case "filled": self = .filled
        case "canceled":
            self = .canceled(reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "")
        default: self = .working
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pendingRisk: try c.encode("pending_risk", forKey: .state)
        case .rejectedByRisk(let r):
            try c.encode("rejected_by_risk", forKey: .state)
            try c.encode(r, forKey: .reason)
        case .accepted: try c.encode("accepted", forKey: .state)
        case .working: try c.encode("working", forKey: .state)
        case .partiallyFilled: try c.encode("partially_filled", forKey: .state)
        case .filled: try c.encode("filled", forKey: .state)
        case .canceled(let r):
            try c.encode("canceled", forKey: .state)
            try c.encode(r, forKey: .reason)
        }
    }

    var label: String {
        switch self {
        case .pendingRisk: "pending risk"
        case .rejectedByRisk: "rejected"
        case .accepted: "accepted"
        case .working: "working"
        case .partiallyFilled: "partial"
        case .filled: "filled"
        case .canceled: "canceled"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .filled, .canceled, .rejectedByRisk: true
        default: false
        }
    }
}

struct OrderUpdate: Codable, Equatable, Identifiable {
    var order_id: UInt64
    var intent: OrderIntent
    var status: OrderStatus
    var filled_qty: Double
    var avg_fill_px: Double
    var ts_ms: Int64
    var id: UInt64 { order_id }
}

struct Fill: Codable, Equatable, Identifiable {
    var order_id: UInt64
    var symbol: String
    var side: Side
    var qty: Double
    var px: Double
    var fee: Double
    var liquidity: Liquidity
    var venue: Venue
    var ts_ms: Int64
    var id: String { "\(order_id)-\(ts_ms)" }
}

struct Position: Codable, Equatable, Identifiable {
    var symbol: String
    var qty: Double
    var avg_px: Double
    var mark_px: Double
    var unrealized_pnl: Double
    var realized_pnl: Double
    var ts_ms: Int64
    var id: String { symbol }
    var notional: Double { abs(qty * mark_px) }
}

struct AccountSnapshot: Codable, Equatable {
    var equity: Double
    var cash: Double
    var gross_exposure: Double
    var net_exposure: Double
    var unrealized_pnl: Double
    var realized_pnl_day: Double
    var fees_paid: Double
    var open_orders: UInt32
    var daily_trades: UInt32
    var drawdown_day: Double
    var drawdown_total: Double
    var ts_ms: Int64

    static let empty = AccountSnapshot(
        equity: 0, cash: 0, gross_exposure: 0, net_exposure: 0,
        unrealized_pnl: 0, realized_pnl_day: 0, fees_paid: 0,
        open_orders: 0, daily_trades: 0, drawdown_day: 0, drawdown_total: 0, ts_ms: 0
    )
}

struct RiskStatus: Codable, Equatable {
    var kill_switch: Bool
    var kill_reason: String?
    var autonomy: AutonomyLevel
    var caution: Double
    var caution_reasons: [String]
    var throttle: Double
    var breaches: [String]
    var ts_ms: Int64

    static let empty = RiskStatus(
        kill_switch: false, kill_reason: nil, autonomy: .full_auto,
        caution: 0, caution_reasons: [], throttle: 1, breaches: [], ts_ms: 0
    )
}

struct AgentThought: Codable, Equatable, Identifiable {
    var agent: String
    var squadron: String
    var severity: Severity
    var text: String
    var tags: [String]
    var confidence: Double
    var symbol: String?
    var ts_ms: Int64
    var id: String { "\(agent)-\(ts_ms)-\(text.hashValue)" }
}

struct StrategySignal: Codable, Equatable, Identifiable {
    var strategy: String
    var symbol: String
    var direction: Double
    var conviction: Double
    var rationale: String
    var features: [String: Double]
    var ts_ms: Int64
    var id: String { "\(strategy)-\(symbol)-\(ts_ms)" }
}

struct MacroSnapshot: Codable, Equatable {
    var yields: [String: Double]
    var spread_2s10s_bps: Double?
    var spread_3m10s_bps: Double?
    var curve_regime: String
    var fx: [String: Double]
    var source: String
    var ts_ms: Int64
}

struct FeedStatus: Codable, Equatable {
    var feed: String
    var health: FeedHealth
    var detail: String
    var ts_ms: Int64
}

enum OptionRight: String, Codable { case call, put }

struct OptionContract: Codable, Equatable, Identifiable {
    var symbol: String
    var right: OptionRight
    var strike: Double
    var expiry: String
    var bid: Double
    var ask: Double
    var last: Double
    var volume: Double
    var open_interest: Double
    var iv: Double?
    var delta: Double?
    var gamma: Double?
    var theta: Double?
    var vega: Double?
    var greeks_source: String
    var id: String { symbol }
    var mid: Double? {
        if bid > 0, ask >= bid { return (bid + ask) / 2 }
        return last > 0 ? last : nil
    }
}

struct OptionsChain: Codable, Equatable {
    var underlying: String
    var underlying_px: Double
    var expirations: [String]
    var expiry: String
    var contracts: [OptionContract]
    var source: String
    var as_of: String?
    var ts_ms: Int64
}

struct StrategyStats: Codable, Equatable, Identifiable {
    var strategy: String
    var symbol: String
    var interval: Interval
    var bars: UInt32
    var trades: UInt32
    var win_rate: Double?
    var profit_factor: Double?
    var sharpe: Double?
    var max_drawdown: Double?
    var expectancy: Double?
    var equity_multiple: Double?
    var id: String { "\(strategy)/\(symbol)" }
}

struct SimProjection: Codable, Equatable, Identifiable {
    var basis: String
    var horizon_trades: UInt32
    var p05: Double
    var p50: Double
    var p95: Double
    var risk_of_ruin: Double
    var id: String { "\(basis)-\(horizon_trades)" }
}

struct SimReport: Codable, Equatable {
    var stats: [StrategyStats]
    var projections: [SimProjection]
    var best: String?
    var note: String
    var ts_ms: Int64
}

struct CautionUpdate: Codable, Equatable {
    var scope: String?
    var value: Double
    var reason: String
    var agent: String
    var ts_ms: Int64
}

struct AiAnswer: Codable, Equatable {
    var request_id: String
    var question: String
    var answer: String
    var model: String
    var ts_ms: Int64
}

// MARK: - Snapshot (initial state replay from cortexd)

struct EngineSnapshot: Codable {
    var symbols: [String]
    /// symbol -> interval raw value ("m1") -> bars
    var bars: [String: [String: [Bar]]]
    var positions: [Position]
    var account: AccountSnapshot?
    var risk: RiskStatus?
    var thoughts: [AgentThought]
    var orders: [OrderUpdate]
    var macro: MacroSnapshot?
    var feeds: [FeedStatus]?
}

// MARK: - Inbound frame (server -> client), tag field "type"

enum ServerFrame {
    case hello(protocolVersion: Int)
    case snapshot(EngineSnapshot)
    case tick(Tick)
    case bar(Bar)
    case bookTop(BookTop)
    case orderIntent(OrderIntent)
    case orderUpdate(OrderUpdate)
    case fill(Fill)
    case position(Position)
    case account(AccountSnapshot)
    case risk(RiskStatus)
    case thought(AgentThought)
    case signal(StrategySignal)
    case macro(MacroSnapshot)
    case feedStatus(FeedStatus)
    case caution(CautionUpdate)
    case optionsChain(OptionsChain)
    case sim(SimReport)
    case aiAnswer(AiAnswer)
    case gap(dropped: Int)
    case error(detail: String)
    case unknown(type: String)

    static func decode(_ data: Data) throws -> ServerFrame {
        struct Probe: Codable { var type: String }
        let dec = JSONDecoder()
        let type = try dec.decode(Probe.self, from: data).type
        switch type {
        case "hello":
            struct Hello: Codable { var `protocol`: Int? }
            let h = try dec.decode(Hello.self, from: data)
            return .hello(protocolVersion: h.protocol ?? 1)
        case "snapshot":
            struct Wrap: Codable { var data: EngineSnapshot }
            return .snapshot(try dec.decode(Wrap.self, from: data).data)
        case "tick": return .tick(try dec.decode(Tick.self, from: data))
        case "bar": return .bar(try dec.decode(Bar.self, from: data))
        case "book_top": return .bookTop(try dec.decode(BookTop.self, from: data))
        case "order_intent": return .orderIntent(try dec.decode(OrderIntent.self, from: data))
        case "order_update": return .orderUpdate(try dec.decode(OrderUpdate.self, from: data))
        case "fill": return .fill(try dec.decode(Fill.self, from: data))
        case "position": return .position(try dec.decode(Position.self, from: data))
        case "account": return .account(try dec.decode(AccountSnapshot.self, from: data))
        case "risk": return .risk(try dec.decode(RiskStatus.self, from: data))
        case "thought": return .thought(try dec.decode(AgentThought.self, from: data))
        case "signal": return .signal(try dec.decode(StrategySignal.self, from: data))
        case "macro": return .macro(try dec.decode(MacroSnapshot.self, from: data))
        case "feed_status": return .feedStatus(try dec.decode(FeedStatus.self, from: data))
        case "caution": return .caution(try dec.decode(CautionUpdate.self, from: data))
        case "options_chain": return .optionsChain(try dec.decode(OptionsChain.self, from: data))
        case "sim": return .sim(try dec.decode(SimReport.self, from: data))
        case "ai_answer": return .aiAnswer(try dec.decode(AiAnswer.self, from: data))
        case "gap":
            struct Gap: Codable { var dropped: Int }
            return .gap(dropped: try dec.decode(Gap.self, from: data).dropped)
        case "error":
            struct Err: Codable { var detail: String }
            return .error(detail: try dec.decode(Err.self, from: data).detail)
        default:
            return .unknown(type: type)
        }
    }
}

// MARK: - Outbound commands (client -> server), tag field "cmd"

enum Command {
    case placeOrder(symbol: String, side: Side, qty: Double, orderType: OrderType, limitPx: Double?)
    case cancelOrder(orderId: UInt64)
    case setKillSwitch(engaged: Bool, reason: String)
    case setAutonomy(level: AutonomyLevel)
    case setStrategyEnabled(strategy: String, enabled: Bool)
    case flattenAll(reason: String)
    case askAi(requestId: String, question: String)
    case sync(barsPerSymbol: Int)
    case getOptionsChain(underlying: String, expiry: String?)
    case runSimulation

    func encoded() throws -> Data {
        var obj: [String: Any]
        switch self {
        case let .placeOrder(symbol, side, qty, orderType, limitPx):
            obj = [
                "cmd": "place_order", "symbol": symbol, "side": side.rawValue,
                "qty": qty, "order_type": orderType.rawValue,
            ]
            if let limitPx { obj["limit_px"] = limitPx }
        case let .cancelOrder(orderId):
            obj = ["cmd": "cancel_order", "order_id": orderId]
        case let .setKillSwitch(engaged, reason):
            obj = ["cmd": "set_kill_switch", "engaged": engaged, "reason": reason]
        case let .setAutonomy(level):
            obj = ["cmd": "set_autonomy", "level": level.rawValue]
        case let .setStrategyEnabled(strategy, enabled):
            obj = ["cmd": "set_strategy_enabled", "strategy": strategy, "enabled": enabled]
        case let .flattenAll(reason):
            obj = ["cmd": "flatten_all", "reason": reason]
        case let .askAi(requestId, question):
            obj = ["cmd": "ask_ai", "request_id": requestId, "question": question]
        case let .sync(barsPerSymbol):
            obj = ["cmd": "sync", "bars_per_symbol": barsPerSymbol]
        case let .getOptionsChain(underlying, expiry):
            obj = ["cmd": "get_options_chain", "underlying": underlying]
            if let expiry { obj["expiry"] = expiry }
        case .runSimulation:
            obj = ["cmd": "run_simulation"]
        }
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }
}
