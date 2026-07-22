// Wire-protocol mirror of the Rust contract crate (cx-core).
// Source of truth: engine/crates/cx-core/src/events.rs + command.rs.
// Property names intentionally stay snake_case so JSON maps 1:1 with zero
// key-conversion drift. Do not "swiftify" these names.

import Foundation

// MARK: - Enums (serde snake_case raw values)

enum Side: String, Codable { case buy, sell }

// NEW OPTIONAL raw values `stop` / `stop_limit` are additive — old clients
// keep decoding market/limit. Case names equal the serde snake_case wire
// values verbatim (so `stop_limit`, never a swiftified `stopLimit`).
enum OrderType: String, Codable { case market, limit, stop, stop_limit }

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

/// The execution venue the engine is wired to. `paper` is the internal
/// simulator (no external broker, no real money). `ibkr_paper`/`ibkr_live`
/// mean the IBKR adapter is configured for a paper or a live account.
/// Case names equal the serde snake_case wire values verbatim.
enum BrokerMode: String, Codable, Equatable {
    case paper, ibkr_paper, ibkr_live

    /// Safety default: an unknown / future / garbled wire value decodes to
    /// `.paper`. The app must NEVER upgrade itself into a live-money posture
    /// off a string it does not explicitly recognize — only the exact literal
    /// "ibkr_live" can ever mean real money.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BrokerMode(rawValue: raw) ?? .paper
    }
}

/// The broker execution mode the operator SETS via SETTINGS — distinct from
/// the richer status `BrokerMode` the engine reports back. Two values only,
/// matching the engine `[broker].mode` contract: the internal paper simulator
/// or the IBKR adapter. Whether an IBKR session is paper or live is decided by
/// the port + `allow_live` gates, not by this field. Case names equal the
/// serde snake_case wire values verbatim.
enum BrokerConfigMode: String, Codable, CaseIterable, Identifiable, Equatable {
    case paper, ibkr
    var id: String { rawValue }
    var label: String {
        switch self {
        case .paper: "Paper"
        case .ibkr: "IBKR"
        }
    }
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

// MARK: - Level 2: order-book depth (ladder) + time & sales (tape)

/// One price level in the order book: the resting price, the aggregate size at
/// that level, the order count (`count == 0` when the venue does not report
/// one), and the market-maker / ECN route `mm` (DAS-style) when the venue
/// attributes it — present for IBKR `reqMktDepth` L2 on equities, `nil` for
/// anonymous/aggregated books (Coinbase level2) and delayed L1, never fabricated.
/// Mirror of the engine `BookLevel` contract type (serde snake_case).
struct BookLevel: Codable, Equatable {
    var px: Double
    var sz: Double
    /// Number of orders resting at this level; 0 when the venue omits it.
    var count: UInt32
    /// Market-maker / venue route id ("NSDQ", "ARCA", …) when the book is
    /// route-attributed; nil for anonymous/aggregated or delayed books.
    var mm: String?

    init(px: Double, sz: Double, count: UInt32, mm: String? = nil) {
        self.px = px
        self.sz = sz
        self.count = count
        self.mm = mm
    }
}

extension BookLevel {
    enum CodingKeys: String, CodingKey { case px, sz, count, mm }

    // Defensive decode: a lean/garbled level must never fail the whole depth
    // frame (Depth is a NON-critical, droppable event). Absent px/sz decode to
    // 0 (the ladder drops non-finite / non-positive prices), an absent count
    // to 0 (venue omitted it), an absent/blank mm to nil (anonymous book — the
    // montage then shows no route badge). Memberwise init preserved above so
    // construction/tests stay ergonomic; `encode(to:)` stays synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        px = try c.decodeIfPresent(Double.self, forKey: .px) ?? 0
        sz = try c.decodeIfPresent(Double.self, forKey: .sz) ?? 0
        count = try c.decodeIfPresent(UInt32.self, forKey: .count) ?? 0
        // Trim on the SAME whitespace set as the Rust producer (str::trim strips
        // all Unicode whitespace incl. newlines) so "\n"-padded ids collapse to
        // nil in both, never a garbage badge.
        let route = try c.decodeIfPresent(String.self, forKey: .mm)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        mm = (route?.isEmpty ?? true) ? nil : route
    }
}

/// A depth snapshot for one symbol: `bids` and `asks` each SORTED BEST-FIRST
/// (bids high→low, asks low→high), the requested `depth`, the `source` feed
/// label, an honest real/delayed flag, and the timestamp. Mirror of the engine
/// `BookDepth` contract type (serde snake_case). NON-critical / droppable.
struct BookDepth: Codable, Equatable {
    var symbol: String
    var bids: [BookLevel]
    var asks: [BookLevel]
    var depth: UInt32
    var source: String
    /// True ONLY for genuine real-time depth (e.g. IBKR L2). `false` = a
    /// delayed / synthetic L1 stand-in — the montage must never style it as
    /// live (it shows an honest "delayed" banner instead).
    var is_live: Bool
    var ts_ms: Int64
}

extension BookDepth {
    enum CodingKeys: String, CodingKey {
        case symbol, bids, asks, depth, source, is_live, ts_ms
    }

    // Defensive decode so a leaner engine payload still renders rather than
    // failing the frame. Cardinal honesty rule: an absent `is_live` defaults to
    // `false` — a missing flag can only ever be SAFER (delayed), never claim
    // live. Memberwise init preserved via the extension.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? ""
        bids = try c.decodeIfPresent([BookLevel].self, forKey: .bids) ?? []
        asks = try c.decodeIfPresent([BookLevel].self, forKey: .asks) ?? []
        depth = try c.decodeIfPresent(UInt32.self, forKey: .depth) ?? 0
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        is_live = try c.decodeIfPresent(Bool.self, forKey: .is_live) ?? false
        ts_ms = try c.decodeIfPresent(Int64.self, forKey: .ts_ms) ?? 0
    }
}

/// One time & sales print: trade `px` and `sz`, the `aggressor` side when the
/// venue reports it (buy = lifted the ask, sell = hit the bid, nil = unknown),
/// the timestamp, and an honest real/delayed flag. Mirror of the engine
/// `TapePrint` contract type (serde snake_case). NON-critical / droppable.
struct TapePrint: Codable, Equatable {
    var symbol: String
    var px: Double
    var sz: Double
    /// buy = lifted the ask (up), sell = hit the bid (down), nil = unknown.
    var aggressor: Side?
    var ts_ms: Int64
    /// True only for real-time prints; `false` = delayed. Never styled as live.
    var is_live: Bool
}

extension TapePrint {
    enum CodingKeys: String, CodingKey {
        case symbol, px, sz, aggressor, ts_ms, is_live
    }

    // Defensive decode: an absent aggressor decodes nil (unknown → dim), an
    // absent is_live defaults to `false` (never claim live). Memberwise init
    // preserved via the extension; `encode(to:)` stays synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? ""
        px = try c.decodeIfPresent(Double.self, forKey: .px) ?? 0
        sz = try c.decodeIfPresent(Double.self, forKey: .sz) ?? 0
        aggressor = try c.decodeIfPresent(Side.self, forKey: .aggressor)
        ts_ms = try c.decodeIfPresent(Int64.self, forKey: .ts_ms) ?? 0
        is_live = try c.decodeIfPresent(Bool.self, forKey: .is_live) ?? false
    }
}

/// The AI order-flow read for one symbol: a depth-weighted order-book
/// `imbalance` (-1…1, buyers positive), session `cum_delta` (cumulative
/// aggressor volume, signed), `delta_rate` (recent up/down-delta velocity),
/// a plain `pressure` verdict ("buyers"/"sellers"/"balanced"), active
/// order-flow `flags` (e.g. "absorption:ask", "sweep:buy", "delta_divergence",
/// "squeeze_dynamics", "exhaustion"), a desk `note`, an honest real/delayed
/// flag, and the feed `source`. Mirror of the engine `FlowRead` contract type
/// (serde snake_case). NON-critical / droppable — decodes defensively so a
/// lean payload still renders, and — the honesty rule — an absent `is_live`
/// can only ever be SAFER (delayed), never claim live.
struct FlowRead: Codable, Equatable {
    var symbol: String
    /// Depth-weighted order-book imbalance in -1…1 (buyers positive, sellers
    /// negative). Non-finite is treated as 0 by the metrics helpers.
    var imbalance: Double
    /// Session cumulative aggressor volume, signed (buys − sells).
    var cum_delta: Double
    /// Recent up/down-delta velocity (the rate the delta is moving).
    var delta_rate: Double
    /// The plain-English verdict: "buyers", "sellers", or "balanced". Absent /
    /// unknown decodes to "balanced" — the neutral, non-committal default.
    var pressure: String
    /// Active order-flow flags (venue/engine codes; the UI maps each to a
    /// plain-English label + meaning).
    var flags: [String]
    /// The desk's latest narrative for this read; may be "".
    var note: String
    /// True ONLY for genuine real-time order flow. `false` = a delayed /
    /// synthetic stand-in — the panel must never style it as live.
    var is_live: Bool
    /// The feed source label ("IBKR", "synthetic", …); may be "".
    var source: String
    var ts_ms: Int64
}

extension FlowRead {
    enum CodingKeys: String, CodingKey {
        case symbol, imbalance, cum_delta, delta_rate, pressure
        case flags, note, is_live, source, ts_ms
    }

    // Defensive decode so a leaner engine payload still renders rather than
    // failing the (droppable) frame. Cardinal honesty rule: an absent
    // `is_live` defaults to `false` — a missing flag can only ever be SAFER
    // (delayed), never claim live. An absent `pressure` defaults to the
    // neutral "balanced". Numeric fields default to 0; the metrics helpers are
    // NaN-safe so a garbage value never renders as truth. Memberwise init
    // preserved via the extension; `encode(to:)` stays synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? ""
        imbalance = try c.decodeIfPresent(Double.self, forKey: .imbalance) ?? 0
        cum_delta = try c.decodeIfPresent(Double.self, forKey: .cum_delta) ?? 0
        delta_rate = try c.decodeIfPresent(Double.self, forKey: .delta_rate) ?? 0
        pressure = try c.decodeIfPresent(String.self, forKey: .pressure) ?? "balanced"
        flags = try c.decodeIfPresent([String].self, forKey: .flags) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        is_live = try c.decodeIfPresent(Bool.self, forKey: .is_live) ?? false
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        ts_ms = try c.decodeIfPresent(Int64.self, forKey: .ts_ms) ?? 0
    }
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
    /// NEW OPTIONAL wire field — the stop/trigger price for stop &
    /// stop-limit orders (absent → nil for market/limit and older engines).
    /// The synthesized decoder treats an optional as decodeIfPresent, so a
    /// payload without the key decodes nil rather than failing the frame; the
    /// `= nil` default keeps the memberwise initializer callable without it.
    var stop_px: Double? = nil
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

/// Broker-link posture, so the operator always knows whether real money is at
/// play: the execution `mode`, whether the broker session is `connected`, and
/// a display-only masked account id. Additive/optional on the wire — older
/// engines never send it, so the app defaults to the safe `paper` posture.
/// Mirror of the engine `BrokerStatus` contract type (serde snake_case).
struct BrokerStatus: Codable, Equatable {
    var mode: BrokerMode
    var connected: Bool
    /// Masked broker account id ("U12****89") — display-only; may be absent.
    var account_masked: String? = nil
}

extension BrokerStatus {
    enum CodingKeys: String, CodingKey { case mode, connected, account_masked }

    // Defensive decode: a partial payload must never fail the frame and must
    // never imply live — an absent `mode` defaults to `.paper` and an absent
    // `connected` to `false`, so a missing field can only ever be SAFER, never
    // more permissive. Memberwise init preserved via the extension; `encode`
    // stays synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(BrokerMode.self, forKey: .mode) ?? .paper
        connected = try c.decodeIfPresent(Bool.self, forKey: .connected) ?? false
        account_masked = try c.decodeIfPresent(String.self, forKey: .account_masked)
    }
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

struct SimTrade: Codable, Equatable, Identifiable {
    var strategy: String
    var symbol: String
    var side: Side
    var entry_ts: Int64
    var exit_ts: Int64
    var entry_px: Double
    var exit_px: Double
    var ret: Double
    var id: String { "\(strategy)-\(symbol)-\(entry_ts)" }
    var key: String { "\(strategy)/\(symbol)" }
}

struct SimReport: Codable, Equatable {
    var stats: [StrategyStats]
    var trades: [SimTrade]
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

// MARK: - Intel: COMPANY (supply chain + fundamentals)

struct Segment: Codable, Equatable, Identifiable {
    var name: String
    var note: String
    var id: String { name }
}

struct Relation: Codable, Equatable, Identifiable {
    var symbol: String?
    var name: String
    var via: String
    var id: String { name }
}

struct Fundamentals: Codable, Equatable {
    var revenue: Double?
    var revenue_yoy: Double?
    var gross_margin: Double?
    var op_margin: Double?
    var net_income: Double?
    var net_margin: Double?
    var eps: Double?
    var assets: Double?
    var liabilities: Double?
    var equity: Double?
    var ocf: Double?
    var cash: Double?
    /// NEW OPTIONAL wire field — the diluted/basic share COUNT (not money).
    /// Older engines omit it (decodes nil); the STATISTICS block shows "—".
    var shares_outstanding: Double? = nil
    /// NEW OPTIONAL wire field — aggregate public float in USD, as reported on
    /// the 10-K cover page. A DOLLAR value, never a share count. Absent → nil.
    var public_float_usd: Double? = nil
    var period: String
    var fiscal_year: String
}

/// One SEC EDGAR filing reference: the form type, the filed date, and the
/// primary document URL. Mirror of the engine `Filing` contract type.
struct Filing: Codable, Equatable, Identifiable {
    /// The form type — "10-K", "10-Q", "8-K", "S-1", …
    var form: String
    /// Filed date, "YYYY-MM-DD".
    var filed: String
    /// Direct link to the primary document (opened through the http(s) guard).
    var primary_doc_url: String
    var id: String { "\(form)-\(filed)-\(primary_doc_url)" }
}

struct CompanyProfile: Codable, Equatable {
    var symbol: String
    var name: String
    var sector: String
    var industry: String
    var country: String
    var description: String
    var segments: [Segment]
    var suppliers: [Relation]
    var customers: [Relation]
    var competitors: [String]
    var fundamentals: Fundamentals?
    /// NEW OPTIONAL wire field — recent SEC EDGAR filings, newest-first. Older
    /// engines omit the key entirely, so it defaults to [] (a custom decoder
    /// tolerates the absence) rather than failing the whole frame.
    var filings: [Filing] = []
    var graph_source: String
    var fundamentals_source: String
    var ts_ms: Int64
}

extension CompanyProfile {
    enum CodingKeys: String, CodingKey {
        case symbol, name, sector, industry, country, description
        case segments, suppliers, customers, competitors
        case fundamentals, filings, graph_source, fundamentals_source, ts_ms
    }

    // Custom decode so `filings` defaults to [] when the key is absent (older
    // engines). Every other field decodes exactly as the synthesized memberwise
    // path would; `encode(to:)` stays synthesized. Declared in an extension so
    // the memberwise initializer is preserved for construction/tests.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try c.decode(String.self, forKey: .symbol)
        name = try c.decode(String.self, forKey: .name)
        sector = try c.decode(String.self, forKey: .sector)
        industry = try c.decode(String.self, forKey: .industry)
        country = try c.decode(String.self, forKey: .country)
        description = try c.decode(String.self, forKey: .description)
        segments = try c.decode([Segment].self, forKey: .segments)
        suppliers = try c.decode([Relation].self, forKey: .suppliers)
        customers = try c.decode([Relation].self, forKey: .customers)
        competitors = try c.decode([String].self, forKey: .competitors)
        fundamentals = try c.decodeIfPresent(Fundamentals.self, forKey: .fundamentals)
        filings = try c.decodeIfPresent([Filing].self, forKey: .filings) ?? []
        graph_source = try c.decode(String.self, forKey: .graph_source)
        fundamentals_source = try c.decode(String.self, forKey: .fundamentals_source)
        ts_ms = try c.decode(Int64.self, forKey: .ts_ms)
    }
}

// MARK: - Intel: REGIMES (bull/bear board)

enum RegimeState: String, Codable, CaseIterable {
    case bull, entering_bull, correction, entering_bear, bear, recovery
    var label: String {
        switch self {
        case .bull: "bull"
        case .entering_bull: "entering bull"
        case .correction: "correction"
        case .entering_bear: "entering bear"
        case .bear: "bear"
        case .recovery: "recovery"
        }
    }
}

struct RegimeRow: Codable, Equatable, Identifiable {
    var symbol: String
    var state: RegimeState
    var drawdown_pct: Double
    var runup_pct: Double
    var days_in_state: UInt32
    var dist_50_200_pct: Double?
    var last_close: Double
    var id: String { symbol }
}

struct Breadth: Codable, Equatable {
    var pct_above_200d: Double?
    var pct_above_50d: Double?
    var bulls: UInt32
    var bears: UInt32
    var entering_bull: UInt32
    var entering_bear: UInt32
    var universe_size: UInt32
}

struct RegimeBoard: Codable, Equatable {
    var rows: [RegimeRow]
    var breadth: Breadth
    var source: String
    var ts_ms: Int64
}

// MARK: - Intel: MERIDIAN (Dalio cause-effect engine)

struct GeoEvent: Codable, Equatable, Identifiable {
    var title: String
    var source_domain: String
    var url: String
    var tone: Double
    var theme: String
    var countries: [String]
    var ts_ms: Int64
    var id: String { "\(theme)-\(ts_ms)-\(title.hashValue)" }
}

struct ForceGauge: Codable, Equatable, Identifiable {
    var force: String
    var value: Double
    var trend_7d: Double
    var proxy: String
    var id: String { force }
}

struct AssetImpact: Codable, Equatable, Identifiable {
    var target: String
    var direction: Int
    var note: String
    var id: String { target }
}

struct CausalChain: Codable, Equatable, Identifiable {
    var rule_id: String
    var title: String
    var steps: [String]
    var assets: [AssetImpact]
    var intensity: Double
    var evidence: [GeoEvent]
    var id: String { rule_id }
}

struct GeoPulse: Codable, Equatable {
    var forces: [ForceGauge]
    var chains: [CausalChain]
    var events: [GeoEvent]
    var source: String
    var ts_ms: Int64
}

// MARK: - Intel: SCANNER (cross-sectional relative-value screen)

struct ScanRow: Codable, Equatable, Identifiable {
    var symbol: String
    var asset_class: String
    var composite: Double
    var momentum: Double
    var trend: Double
    var breakout: Double
    var meanrev: Double
    var vol_state: Double
    var rsi_14: Double?
    var zscore_20: Double?
    var kalman_tstat: Double?
    var ret_1w: Double?
    var ret_1m: Double?
    var ret_3m: Double?
    var dist_52w_high: Double?
    var vol_surge: Double?
    var regime: RegimeState?
    var flags: [String]
    var last_close: Double
    var id: String { symbol }
}

/// One flag-transition alert: a flag newly raised on a symbol this scan
/// cycle (absent last cycle, present now).
struct ScanAlert: Codable, Equatable, Identifiable {
    var symbol: String
    var flag: String
    var ts_ms: Int64
    var id: String { "\(symbol)-\(flag)-\(ts_ms)" }
}

struct ScanBoard: Codable, Equatable {
    var rows: [ScanRow]
    var source: String
    var ts_ms: Int64
    /// NEW OPTIONAL wire fields — older engines omit them, so both decode
    /// to nil rather than failing the whole frame.
    var alerts: [ScanAlert]? = nil
    /// Factor weights the engine used to blend the composite this cycle.
    var weights_used: [String: Double]? = nil
}

// MARK: - Intel: NEWS (headlines + earnings-cadence estimates)

/// One market/company headline (GDELT DOC 2.0), deduped by title.
/// `symbol` names the configured equity whose company query surfaced it;
/// nil marks the general markets query.
struct NewsItem: Codable, Equatable, Identifiable {
    var symbol: String?
    var title: String
    var source_domain: String
    var url: String
    /// GDELT average tone: negative = grim, positive = calm.
    var tone: Double
    var ts_ms: Int64
    /// NEW OPTIONAL wire field — the human-readable outlet name ("Reuters")
    /// when the engine resolves one. Older engines omit it (decodes nil, and
    /// the feed falls back to a name derived from `source_domain`).
    var source_name: String? = nil
    var id: String { "\(symbol ?? "market")-\(ts_ms)-\(title.hashValue)" }
}

/// One configured equity's earnings-calendar row, ESTIMATED from its SEC
/// EDGAR filing cadence. `next_estimate` is arithmetic, not a confirmed
/// date — `basis` discloses that on every row.
struct EarningsRow: Codable, Equatable, Identifiable {
    var symbol: String
    /// Most recent periodic (10-Q/10-K) filing date, "YYYY-MM-DD".
    var last_report: String
    /// `last_report` + 91 days, "YYYY-MM-DD".
    var next_estimate: String
    /// e.g. "estimated from filing cadence (not confirmed)".
    var basis: String
    var id: String { symbol }
}

/// The NEWS board: deduped company/market headlines plus filing-cadence
/// earnings estimates. Sources are always disclosed.
struct NewsBoard: Codable, Equatable {
    var items: [NewsItem]
    var earnings: [EarningsRow]
    var source: String
    var ts_ms: Int64
}

/// On-demand history for a searched symbol: one interval, whole series.
struct HistorySlice: Codable, Equatable {
    var symbol: String
    var interval: Interval
    var bars: [Bar]
    var source: String
    var ts_ms: Int64
}

// MARK: - Intel: FILINGS (SEC EDGAR, on-demand)

/// One SEC EDGAR filing entry for the dedicated FILINGS section. A richer
/// sibling of `Filing` (which stays a slim COMPANY-card reference) — this
/// carries the fields the standalone filings table needs. Mirror of the engine
/// `FilingEntry` contract type, field-for-field (serde snake_case). All fields
/// decode defensively (absent → the natural empty/zero) so a leaner engine
/// payload never fails the whole frame.
struct FilingEntry: Codable, Equatable, Identifiable {
    /// The form type — "10-K", "10-Q", "8-K", "S-1", "DEF 14A", "4", …
    var form: String
    /// filingDate, "YYYY-MM-DD".
    var filed: String
    /// Period of report (reportDate), "YYYY-MM-DD"; may be "".
    var report_date: String
    /// Accession number "0000320193-26-000005".
    var accession: String
    /// primaryDocument filename "aapl-20251228.htm"; may be "".
    var primary_doc: String
    /// Direct link to the primary document (opened through the http(s) guard).
    var primary_doc_url: String
    /// The filing index page (fallback target when `primary_doc` is empty).
    var filing_index_url: String
    /// primaryDocDescription or a human form name; may be "".
    var description: String
    /// 8-K item codes as CSV; may be "".
    var items: String
    /// Primary-document size in bytes; 0 when unknown.
    var size: UInt64
    /// isXBRL == 1.
    var is_xbrl: Bool

    /// Accession is the natural unique key; fall back to a composite when a
    /// lean payload omitted it, so ForEach identity stays stable.
    var id: String {
        accession.isEmpty ? "\(form)-\(filed)-\(primary_doc_url)" : accession
    }
}

extension FilingEntry {
    enum CodingKeys: String, CodingKey {
        case form, filed, report_date, accession, primary_doc, primary_doc_url
        case filing_index_url, description, items, size, is_xbrl
    }

    // Every field decodes defensively so a leaner engine payload (or an
    // absent optional) yields the natural empty/zero rather than failing the
    // frame. Declared in an extension so the memberwise initializer survives
    // for construction/tests; `encode(to:)` stays synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        form = try c.decodeIfPresent(String.self, forKey: .form) ?? ""
        filed = try c.decodeIfPresent(String.self, forKey: .filed) ?? ""
        report_date = try c.decodeIfPresent(String.self, forKey: .report_date) ?? ""
        accession = try c.decodeIfPresent(String.self, forKey: .accession) ?? ""
        primary_doc = try c.decodeIfPresent(String.self, forKey: .primary_doc) ?? ""
        primary_doc_url = try c.decodeIfPresent(String.self, forKey: .primary_doc_url) ?? ""
        filing_index_url = try c.decodeIfPresent(String.self, forKey: .filing_index_url) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        items = try c.decodeIfPresent(String.self, forKey: .items) ?? ""
        size = try c.decodeIfPresent(UInt64.self, forKey: .size) ?? 0
        is_xbrl = try c.decodeIfPresent(Bool.self, forKey: .is_xbrl) ?? false
    }
}

/// The FILINGS report: a resolved SEC entity plus its recent filings,
/// answered on demand (like COMPANY) — never part of the snapshot. Mirror of
/// the engine `FilingsReport` contract type. `note` carries an honest
/// explanation whenever the pull was partial or unresolved.
struct FilingsReport: Codable, Equatable {
    var query: String
    /// Zero-padded 10-digit CIK "0000320193" ("" if unresolved).
    var cik: String
    /// Resolved entity name "Apple Inc." ("" if unresolved).
    var name: String
    /// Resolved ticker or "".
    var ticker: String
    var filings: [FilingEntry]
    /// "SEC EDGAR submissions (data.sec.gov)" or
    /// "SEC EDGAR full-text (efts.sec.gov)".
    var source: String
    /// "" or an honest explanation ("ticker not found in SEC map",
    /// "fetch failed", …).
    var note: String
    var ts_ms: Int64
}

extension FilingsReport {
    enum CodingKeys: String, CodingKey {
        case query, cik, name, ticker, filings, source, note, ts_ms
    }

    // Defensive decode: absent string/array fields default to empty so a
    // partial engine payload still renders (with an honest empty state)
    // rather than failing the frame. Memberwise init preserved via extension.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        query = try c.decodeIfPresent(String.self, forKey: .query) ?? ""
        cik = try c.decodeIfPresent(String.self, forKey: .cik) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        ticker = try c.decodeIfPresent(String.self, forKey: .ticker) ?? ""
        filings = try c.decodeIfPresent([FilingEntry].self, forKey: .filings) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        ts_ms = try c.decodeIfPresent(Int64.self, forKey: .ts_ms) ?? 0
    }
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
    var regimes: RegimeBoard?
    var geo: GeoPulse?
    var scan: ScanBoard?
    var news: NewsBoard?
    /// Scan-universe symbols beyond the watchlist (D1 charts + search).
    var search_universe: [String]?
    /// NEW OPTIONAL wire field — the broker-link posture at connect. Older
    /// engines omit it entirely, so it decodes nil (the app then shows the
    /// safe `paper` default) rather than failing the snapshot.
    var broker: BrokerStatus? = nil
    /// NEW OPTIONAL wire field — the latest BookDepth per subscribed symbol
    /// (bounded: the engine only streams depth for the actively-viewed
    /// symbol). Older engines omit it entirely, so it decodes nil rather than
    /// failing the snapshot; the montage then waits for the first live frame.
    var depth: [String: BookDepth]? = nil
    /// NEW OPTIONAL wire field — the latest FlowRead per subscribed symbol
    /// (bounded like `depth`: the engine only reads flow for the actively-
    /// viewed symbol). Older engines omit it entirely, so it decodes nil rather
    /// than failing the snapshot; the panel then waits for the first read.
    var flow: [String: FlowRead]? = nil
}

// MARK: - Inbound frame (server -> client), tag field "type"

enum ServerFrame {
    case hello(protocolVersion: Int)
    case snapshot(EngineSnapshot)
    case tick(Tick)
    case bar(Bar)
    case bookTop(BookTop)
    case depth(BookDepth)
    case tape(TapePrint)
    case flow(FlowRead)
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
    case brokerStatus(BrokerStatus)
    case caution(CautionUpdate)
    case optionsChain(OptionsChain)
    case sim(SimReport)
    case aiAnswer(AiAnswer)
    case company(CompanyProfile)
    case regimeMap(RegimeBoard)
    case geo(GeoPulse)
    case scan(ScanBoard)
    case news(NewsBoard)
    case history(HistorySlice)
    case filings(FilingsReport)
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
        case "depth": return .depth(try dec.decode(BookDepth.self, from: data))
        case "tape": return .tape(try dec.decode(TapePrint.self, from: data))
        case "flow": return .flow(try dec.decode(FlowRead.self, from: data))
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
        case "broker_status": return .brokerStatus(try dec.decode(BrokerStatus.self, from: data))
        case "caution": return .caution(try dec.decode(CautionUpdate.self, from: data))
        case "options_chain": return .optionsChain(try dec.decode(OptionsChain.self, from: data))
        case "sim": return .sim(try dec.decode(SimReport.self, from: data))
        case "ai_answer": return .aiAnswer(try dec.decode(AiAnswer.self, from: data))
        case "company": return .company(try dec.decode(CompanyProfile.self, from: data))
        case "regime_map": return .regimeMap(try dec.decode(RegimeBoard.self, from: data))
        case "geo": return .geo(try dec.decode(GeoPulse.self, from: data))
        case "scan": return .scan(try dec.decode(ScanBoard.self, from: data))
        case "news": return .news(try dec.decode(NewsBoard.self, from: data))
        case "history": return .history(try dec.decode(HistorySlice.self, from: data))
        case "filings": return .filings(try dec.decode(FilingsReport.self, from: data))
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
    case placeOrder(
        symbol: String, side: Side, qty: Double, orderType: OrderType,
        limitPx: Double?, stopPx: Double?
    )
    case cancelOrder(orderId: UInt64)
    case setKillSwitch(engaged: Bool, reason: String)
    case setAutonomy(level: AutonomyLevel)
    case setStrategyEnabled(strategy: String, enabled: Bool)
    case flattenAll(reason: String)
    case askAi(requestId: String, question: String)
    case sync(barsPerSymbol: Int)
    case getOptionsChain(underlying: String, expiry: String?)
    case runSimulation
    case getCompany(symbol: String)
    case getHistory(symbol: String)
    case getFilings(query: String, formFilter: String, text: String)
    /// Subscribe / unsubscribe Level 2 depth + tape for a symbol. The engine
    /// streams depth for ONE actively-viewed symbol at a time to bound
    /// bandwidth: subscribing a new symbol supersedes the previous. Additive —
    /// older engines simply ignore an unknown cmd.
    case subscribeDepth(symbol: String)
    case unsubscribeDepth(symbol: String)
    /// Reconfigure the live-trading broker link from SETTINGS. Additive: older
    /// engines simply ignore an unknown cmd. The engine re-runs the SAME
    /// `[broker]` validation + safety gates (live ports 7496/4001 require
    /// allow_live; every LIVE hard limit must be finite and > 0), reconfigures
    /// / reconnects the active broker, and publishes an updated BrokerStatus —
    /// on any failure it stays on the previous safe broker and emits a critical
    /// thought. This client only records intent and sends; it never assumes the
    /// change took.
    case setBrokerConfig(
        mode: BrokerConfigMode, ibkrHost: String, ibkrPort: Int, ibkrClientId: Int,
        ibkrAccount: String, ibkrRoute: String, allowLive: Bool,
        maxLiveOrderNotional: Double, maxLivePositionNotional: Double,
        maxLiveDailyLoss: Double
    )

    func encoded() throws -> Data {
        var obj: [String: Any]
        switch self {
        case let .placeOrder(symbol, side, qty, orderType, limitPx, stopPx):
            obj = [
                "cmd": "place_order", "symbol": symbol, "side": side.rawValue,
                "qty": qty, "order_type": orderType.rawValue,
            ]
            // Both prices are additive + optional: the key ships only when set,
            // so a market order's wire shape is unchanged from before.
            if let limitPx { obj["limit_px"] = limitPx }
            if let stopPx { obj["stop_px"] = stopPx }
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
        case let .getCompany(symbol):
            obj = ["cmd": "get_company", "symbol": symbol]
        case let .getHistory(symbol):
            obj = ["cmd": "get_history", "symbol": symbol]
        case let .getFilings(query, formFilter, text):
            // form_filter + text are always present (empty string when unused)
            // so the wire shape matches the contract exactly.
            obj = [
                "cmd": "get_filings", "query": query,
                "form_filter": formFilter, "text": text,
            ]
        case let .subscribeDepth(symbol):
            obj = ["cmd": "subscribe_depth", "symbol": symbol]
        case let .unsubscribeDepth(symbol):
            obj = ["cmd": "unsubscribe_depth", "symbol": symbol]
        case let .setBrokerConfig(
            mode, ibkrHost, ibkrPort, ibkrClientId, ibkrAccount, ibkrRoute,
            allowLive, maxOrder, maxPosition, maxDailyLoss
        ):
            // Every field is always present so the wire shape matches the
            // engine's `[broker]` contract exactly (serde snake_case, 1:1).
            obj = [
                "cmd": "set_broker_config",
                "mode": mode.rawValue,
                "ibkr_host": ibkrHost,
                "ibkr_port": ibkrPort,
                "ibkr_client_id": ibkrClientId,
                "ibkr_account": ibkrAccount,
                "ibkr_route": ibkrRoute,
                "allow_live": allowLive,
                "max_live_order_notional": maxOrder,
                "max_live_position_notional": maxPosition,
                "max_live_daily_loss": maxDailyLoss,
            ]
        }
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }
}
