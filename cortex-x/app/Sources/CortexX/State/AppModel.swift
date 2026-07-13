// The single observable source of truth for the UI. EngineClient frames are
// applied here; views read state and send Commands back through `send`.

import Foundation
import Observation

struct CopilotMessage: Identifiable, Equatable {
    enum Role { case user, cortex }
    let id: String
    let role: Role
    var text: String
    var model: String?
    var pending = false
    let ts = Date()
}

@MainActor
@Observable
final class AppModel {
    // MARK: Connection
    private(set) var connection: ConnectionState = .disconnected
    private(set) var protocolVersion = 0

    // MARK: Market
    private(set) var symbols: [String] = []
    var selectedSymbol: String = "BTC-USD"
    var selectedInterval: Interval = .m1
    /// symbol -> interval -> bars (forming bar is always last, capped)
    private(set) var bars: [String: [Interval: [Bar]]] = [:]
    private(set) var lastTick: [String: Tick] = [:]
    private(set) var bookTop: [String: BookTop] = [:]
    /// Rolling 24h-style reference for % change: first close seen per symbol/day.
    private(set) var sessionOpen: [String: Double] = [:]

    // MARK: Portfolio
    private(set) var positions: [String: Position] = [:]
    private(set) var account: AccountSnapshot = .empty
    private(set) var orders: [OrderUpdate] = []
    private(set) var fills: [Fill] = []

    // MARK: Risk & agents
    private(set) var risk: RiskStatus = .empty
    private(set) var thoughts: [AgentThought] = []
    private(set) var signals: [StrategySignal] = []
    private(set) var macro: MacroSnapshot?
    private(set) var feeds: [String: FeedStatus] = [:]

    // MARK: Center sections
    enum CenterMode: String, CaseIterable { case chart, scanner, company, options, foundry, regimes, meridian }
    var centerMode: CenterMode = .chart
    private(set) var optionsChain: OptionsChain?
    private(set) var chainLoading = false
    private(set) var simReport: SimReport?
    private(set) var simRunning = false

    // MARK: Intel (COMPANY / REGIMES / MERIDIAN)
    /// The company being inspected. Independent of `selectedSymbol` so
    /// supplier/customer graph walking (TSM from NVDA) works even for
    /// tickers outside the configured watchlist.
    var companySymbol: String = ""
    private(set) var company: CompanyProfile?
    private(set) var companyLoading = false
    private var companyRequestSeq = 0
    private var pendingCompany: String?
    private(set) var regimeBoard: RegimeBoard?
    private(set) var geoPulse: GeoPulse?
    private(set) var scanBoard: ScanBoard?
    /// Universe symbols beyond the watchlist — searchable, D1-chartable.
    private(set) var searchUniverse: [String] = []

    // MARK: Copilot
    private(set) var copilot: [CopilotMessage] = []
    private(set) var pendingAsk: String?

    private let client: EngineClient
    private let maxBars = 3_000

    init(client: EngineClient = EngineClient()) {
        self.client = client
        client.onFrame = { [weak self] frame in self?.apply(frame) }
        client.onStateChange = { [weak self] s in self?.connection = s }
    }

    func start() { client.start() }
    func stop() { client.stop() }
    func send(_ command: Command) { client.send(command) }

    // MARK: Derived

    func bars(_ symbol: String, _ interval: Interval) -> [Bar] {
        bars[symbol]?[interval] ?? []
    }

    func lastPrice(_ symbol: String) -> Double? {
        if let t = lastTick[symbol] { return t.price }
        // Universe symbols carry D1-only history — fall through to it.
        return bars[symbol]?[.m1]?.last?.close ?? bars[symbol]?[.d1]?.last?.close
    }

    func sessionChangePct(_ symbol: String) -> Double? {
        guard let last = lastPrice(symbol), let open = sessionOpen[symbol], open > 0 else { return nil }
        return (last - open) / open * 100
    }

    var totalUnrealized: Double {
        positions.values.reduce(0) { $0 + $1.unrealized_pnl }
    }

    /// True for bare-ticker (equity) symbols, which have listed options.
    static func isEquity(_ symbol: String) -> Bool { !symbol.contains("-") }

    func requestOptionsChain(underlying: String, expiry: String? = nil) {
        guard Self.isEquity(underlying) else { return }
        chainLoading = true
        send(.getOptionsChain(underlying: underlying, expiry: expiry))
    }

    func runSimulation() {
        simRunning = true
        send(.runSimulation)
    }

    /// Load the COMPANY intelligence card and switch to the company section.
    func openCompany(_ symbol: String) {
        companySymbol = symbol.uppercased()
        centerMode = .company
        requestCompany(companySymbol)
    }

    /// Select a symbol for the chart/watchlist context. If the current
    /// interval has almost no bars for it (equities barely tick M1), jump to
    /// the densest interval so the chart never opens near-empty.
    func selectSymbol(_ symbol: String) {
        selectedSymbol = symbol
        if bars(symbol, selectedInterval).count < 30 {
            let densest = Interval.allCases
                .map { ($0, bars(symbol, $0).count) }
                .max { $0.1 < $1.1 }
            if let (interval, count) = densest, count >= 30 {
                selectedInterval = interval
            }
        }
    }

    func requestCompany(_ symbol: String) {
        // Re-request on every navigation: stale cards must never masquerade
        // as current. A watchdog clears the spinner if the engine never
        // answers (e.g. it is an older build without COMPANY support).
        if companyLoading && pendingCompany == symbol { return }
        pendingCompany = symbol
        companyLoading = true
        companyRequestSeq += 1
        let seq = companyRequestSeq
        send(.getCompany(symbol: symbol))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, self.companyRequestSeq == seq, self.companyLoading else { return }
            self.companyLoading = false
            self.pendingCompany = nil
        }
    }

    func askCopilot(_ question: String) {
        let id = "ask-\(Int(Date().timeIntervalSince1970 * 1000))"
        copilot.append(CopilotMessage(id: "\(id)-q", role: .user, text: question))
        copilot.append(CopilotMessage(id: id, role: .cortex, text: "", pending: true))
        pendingAsk = id
        send(.askAi(requestId: id, question: question))
    }

    // MARK: Frame application

    func apply(_ frame: ServerFrame) {
        switch frame {
        case .hello(let v):
            protocolVersion = v
        case .snapshot(let snap):
            applySnapshot(snap)
        case .tick(let t):
            lastTick[t.symbol] = t
            if sessionOpen[t.symbol] == nil { sessionOpen[t.symbol] = t.price }
        case .bar(let bar):
            applyBar(bar)
        case .bookTop(let top):
            bookTop[top.symbol] = top
        case .orderIntent:
            break // intents surface via order updates
        case .orderUpdate(let u):
            if let idx = orders.firstIndex(where: { $0.order_id == u.order_id }) {
                orders[idx] = u
            } else {
                orders.insert(u, at: 0)
                if orders.count > 300 { orders.removeLast(orders.count - 300) }
            }
        case .fill(let f):
            fills.insert(f, at: 0)
            if fills.count > 300 { fills.removeLast(fills.count - 300) }
        case .position(let p):
            if abs(p.qty) < 1e-12 && abs(p.realized_pnl) < 1e-12 {
                positions.removeValue(forKey: p.symbol)
            } else {
                positions[p.symbol] = p
            }
        case .account(let a):
            account = a
        case .risk(let r):
            risk = r
        case .thought(let t):
            thoughts.insert(t, at: 0)
            if thoughts.count > 400 { thoughts.removeLast(thoughts.count - 400) }
        case .signal(let s):
            signals.insert(s, at: 0)
            if signals.count > 200 { signals.removeLast(signals.count - 200) }
        case .macro(let m):
            macro = m
        case .feedStatus(let f):
            feeds[f.feed] = f
        case .caution(let c):
            // Surface caution requests in the agent feed as warning thoughts.
            thoughts.insert(AgentThought(
                agent: c.agent, squadron: "risk", severity: .warning,
                text: "caution \(c.value.formatted(.number.precision(.fractionLength(2)))) on \(c.scope ?? "all"): \(c.reason)",
                tags: ["caution"], confidence: 1.0, symbol: c.scope, ts_ms: c.ts_ms
            ), at: 0)
        case .optionsChain(let chain):
            optionsChain = chain
            chainLoading = false
        case .sim(let report):
            simReport = report
            simRunning = false
        case .aiAnswer(let a):
            if let idx = copilot.firstIndex(where: { $0.id == a.request_id }) {
                copilot[idx].text = a.answer
                copilot[idx].model = a.model
                copilot[idx].pending = false
            } else {
                copilot.append(CopilotMessage(id: a.request_id, role: .cortex, text: a.answer, model: a.model))
            }
            if pendingAsk == a.request_id { pendingAsk = nil }
        case .company(let profile):
            company = profile
            if profile.symbol == companySymbol || pendingCompany == profile.symbol {
                companyLoading = false
                pendingCompany = nil
            }
        case .regimeMap(let board):
            regimeBoard = board
        case .geo(let pulse):
            geoPulse = pulse
        case .scan(let board):
            scanBoard = board
        case .gap, .error, .unknown:
            break
        }
    }

    private func applySnapshot(_ snap: EngineSnapshot) {
        symbols = snap.symbols
        if !symbols.contains(selectedSymbol), let first = symbols.first {
            selectedSymbol = first
        }
        var rebuilt: [String: [Interval: [Bar]]] = [:]
        for (symbol, byInterval) in snap.bars {
            var m: [Interval: [Bar]] = [:]
            for (key, list) in byInterval {
                guard let interval = Interval(rawValue: key) else { continue }
                m[interval] = list.sorted { $0.ts_open_ms < $1.ts_open_ms }
            }
            rebuilt[symbol] = m
        }
        bars = rebuilt
        for p in snap.positions { positions[p.symbol] = p }
        if let a = snap.account { account = a }
        if let r = snap.risk { risk = r }
        thoughts = snap.thoughts.sorted { $0.ts_ms > $1.ts_ms }
        orders = snap.orders.sorted { $0.ts_ms > $1.ts_ms }
        if let m = snap.macro { macro = m }
        for f in snap.feeds ?? [] { feeds[f.feed] = f }
        if let r = snap.regimes { regimeBoard = r }
        if let g = snap.geo { geoPulse = g }
        if let s = snap.scan { scanBoard = s }
        if let u = snap.search_universe { searchUniverse = u }
        for (symbol, byInterval) in rebuilt {
            if sessionOpen[symbol] == nil {
                sessionOpen[symbol] = byInterval[.m1]?.last?.close ?? byInterval[.h1]?.last?.close
            }
        }
    }

    private func applyBar(_ bar: Bar) {
        var series = bars[bar.symbol]?[bar.interval] ?? []
        if let last = series.last, last.ts_open_ms == bar.ts_open_ms {
            series[series.count - 1] = bar
        } else if let last = series.last, last.ts_open_ms > bar.ts_open_ms {
            // Late bar: ignore rather than corrupt ordering.
        } else {
            series.append(bar)
            if series.count > maxBars { series.removeFirst(series.count - maxBars) }
        }
        bars[bar.symbol, default: [:]][bar.interval] = series
    }
}
