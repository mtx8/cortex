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

/// One NEWS AI-BRIEF ask: the request id plus the exact question posed. The
/// answer is looked up live from `copilot` by id (so a brief that resolves
/// later still renders), and this lives on the model so the AI-BRIEF history
/// survives leaving and re-entering the NEWS section.
struct NewsBriefRef: Identifiable, Equatable {
    let requestId: String
    let question: String
    var id: String { requestId }
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

    // MARK: Level 2 (depth ladder + time & sales)
    /// The order-book depth for the actively-subscribed symbol. nil until the
    /// first depth frame lands (or while unsubscribed) — the montage shows an
    /// honest "waiting for depth" state, never a stale book from another symbol.
    private(set) var bookDepth: BookDepth?
    /// The AI order-flow read for the actively-subscribed symbol. nil until the
    /// first flow frame lands (or while unsubscribed) — the FLOW panel shows an
    /// honest "waiting on order flow" state, never a stale read from another
    /// symbol. Rides the same subscription + lifecycle as `bookDepth`.
    private(set) var flowRead: FlowRead?
    /// Time & sales prints for the subscribed symbol, NEWEST-FIRST, ring-capped.
    private(set) var tape: [TapePrint] = []
    /// Tape ring cap — bounded so a fast tape never grows without limit.
    static let tapeCap = 200
    /// The symbol the engine is streaming depth + tape for (nil = none). Exactly
    /// one at a time (bounded bandwidth): subscribing a new symbol unsubscribes
    /// the previous. Late frames from a just-unsubscribed symbol are dropped by
    /// matching against this.
    private(set) var depthSymbol: String?
    /// Whether at least one depth frame has actually landed for the current
    /// `depthSymbol`. False the instant a (re)subscribe goes out and until the
    /// engine answers. The resync path reads it: a subscribe whose command was
    /// dropped while the socket was down (send() no-ops off `.connected`) leaves
    /// depthSymbol set but nothing delivered — the honest signal to force-resend
    /// on connect. A book already delivering needs no resend (no engine thrash).
    private(set) var depthDelivered = false
    /// A price the operator clicked in the depth ladder, offered to the order
    /// ticket's price-set path (the integration seam — the ticket seats it into
    /// its limit field, then clears it). nil once consumed. NaN-safe: only a
    /// finite, positive click ever lands here.
    private(set) var pendingTicketPrice: Double?

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
    /// Broker-link posture. nil = the engine has not vouched for a broker, so
    /// the UI shows the safe `paper` default. Cleared on any disconnect so a
    /// stale "IBKR LIVE" can never linger while the engine is unreachable —
    /// LIVE must be current and connected or it must not read as live at all.
    private(set) var broker: BrokerStatus?
    /// The operator's persisted broker preferences (SETTINGS ▸ BROKER). Loaded
    /// at launch, mutated only through `applyBrokerConfig` so the persisted copy
    /// and the last-sent command never drift. Convenience only: it is NEVER
    /// auto-pushed to the engine — the engine owns its own `[broker]` config,
    /// and applying this is an explicit operator action.
    private(set) var brokerSettings: BrokerSettings

    // MARK: Center sections
    enum CenterMode: String, CaseIterable { case chart, scanner, news, company, options, foundry, regimes, meridian, settings }
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
    /// SCANNER flag-transition alert feed, accumulated newest-first across
    /// board publishes (capped; republished alerts never duplicate).
    private(set) var scanAlerts: [ScanAlert] = []
    private(set) var newsBoard: NewsBoard?
    /// Universe symbols beyond the watchlist — searchable, D1-chartable.
    private(set) var searchUniverse: [String] = []

    // MARK: Filings (SEC EDGAR — dedicated FILINGS section)
    /// The most recent filings pull, answered on demand (like COMPANY) and
    /// never part of the snapshot.
    private(set) var filingsReport: FilingsReport?
    private(set) var filingsLoading = false
    /// The last query submitted — so the FILINGS search field can reflect the
    /// active symbol when arriving via `openFilings`.
    private(set) var filingsQuery: String = ""
    private var filingsRequestSeq = 0
    /// One-shot hint for NewsView: which tab to open on its next appear. Set by
    /// `openFilings` so the COMPANY board's "all filings" affordance lands on
    /// NEWS ▸ filings (filings now live as a tab inside the NEWS desk). NewsView
    /// consumes it on appear, then clears it back to nil.
    var newsInitialTab: NewsTab?

    // MARK: Copilot
    private(set) var copilot: [CopilotMessage] = []
    private(set) var pendingAsk: String?
    /// NEWS AI-BRIEF ask history, newest-first, capped. Each entry's answer is
    /// resolved from `copilot` by request id at render time.
    private(set) var newsBriefHistory: [NewsBriefRef] = []
    static let newsBriefHistoryCap = 20
    /// Monotonic ask counter: millisecond wall-clock alone can collide when
    /// two asks dispatch in the same run-loop drain (double-click before
    /// `.disabled` re-renders), corrupting id-keyed answer routing.
    private var askSeq = 0

    /// Symbols whose on-demand history came back empty (dead ticker or
    /// failed backfill). Without this, ensureSymbolData re-fires a fresh
    /// engine request — and a fresh Yahoo egress — on every list switch.
    private(set) var historyMisses: Set<String> = []

    private let client: EngineClient
    private let maxBars = 3_000
    /// Minimum spacing between depth-driven re-syncs.
    static let resyncCooldownMs: Int64 = 30_000
    /// Reconnect guard: only the latest connection's follow-up sync fires.
    private var connectionToken = 0
    /// When the last deep re-sync went out (0 = never).
    private var lastResyncMs: Int64 = 0
    /// Per-symbol timestamps of the last depth-driven getHistory (0 = never).
    /// Separate from `lastResyncMs`: a watchlist sync never deepens an
    /// off-watchlist ticker, so those requests get their own cooldown.
    private var lastHistoryMs: [String: Int64] = [:]
    /// The underlying of the most recent explicit chain request. The engine
    /// republishes chains for ALL equities periodically — only the requested
    /// one may replace what the operator is viewing.
    private var requestedChainUnderlying: String?

    init(client: EngineClient = EngineClient()) {
        self.client = client
        self.brokerSettings = BrokerSettingsStore.load()
        client.onFrame = { [weak self] frame in self?.apply(frame) }
        client.onStateChange = { [weak self] s in self?.handleStateChange(s) }
    }

    func handleStateChange(_ s: ConnectionState) {
        connection = s
        // A dropped connection orphans any in-flight ask: the engine answers
        // by exact request id only, and a fresh connection knows nothing
        // about it — without this every ASK surface stays disabled forever.
        if s != .connected {
            failPendingAsk("connection lost — ask again")
            // Drop the broker posture too: while the engine is unreachable we
            // cannot claim a live+connected broker, so fall back to the safe
            // paper default until the next snapshot re-vouches for it.
            broker = nil
            // A dropped connection orphans the depth subscription: the engine
            // knows nothing of it after a fresh connect. Clear the book, tape,
            // and subscribed symbol so a stale ladder never lingers and the
            // montage re-subscribes cleanly once the link is back. Reset the
            // delivered flag too, so the reconnect resync re-sends the subscribe.
            bookDepth = nil
            flowRead = nil
            tape = []
            depthSymbol = nil
            depthDelivered = false
        }
    }

    func start() { client.start() }
    func stop() { client.stop() }
    func send(_ command: Command) { client.send(command) }

    // MARK: Order placement

    /// Buying power for sizing (paper: cash). One accessor so the ticket's
    /// %-of-buying-power chips read a single, named source.
    var buyingPower: Double { account.cash }

    /// The one order-placement path. Wraps `send(.placeOrder(...))` so every
    /// ticket action (manual entry, flatten, reverse) funnels through the same
    /// bus command with the stop price threaded through. Paper only.
    func placeOrder(
        symbol: String, side: Side, qty: Double, type: OrderType,
        limitPx: Double?, stopPx: Double?
    ) {
        send(.placeOrder(
            symbol: symbol, side: side, qty: qty, orderType: type,
            limitPx: limitPx, stopPx: stopPx
        ))
    }

    // MARK: Level 2 (depth + tape) subscription

    /// Stream Level 2 depth + tape for `symbol` — and ONLY `symbol`. The engine
    /// bounds bandwidth to one book at a time, so this unsubscribes the previous
    /// symbol first, clears the stale book + tape (a new symbol must never show
    /// another's ladder), then sends the subscribe command. Idempotent:
    /// re-subscribing the symbol already streaming is a no-op, so view
    /// re-appears never thrash the engine. Blank symbols are ignored.
    func subscribeDepth(_ symbol: String) {
        let symbol = symbol.uppercased()
        guard !symbol.isEmpty, symbol != depthSymbol else { return }
        if let prev = depthSymbol { send(.unsubscribeDepth(symbol: prev)) }
        depthSymbol = symbol
        bookDepth = nil
        flowRead = nil
        tape = []
        depthDelivered = false
        send(.subscribeDepth(symbol: symbol))
    }

    /// Stop streaming depth for the current symbol (montage left the screen).
    /// Clears the book + tape so nothing lingers, and tells the engine to free
    /// the bandwidth. A no-op when nothing is subscribed.
    func unsubscribeDepth() {
        guard let prev = depthSymbol else { return }
        send(.unsubscribeDepth(symbol: prev))
        depthSymbol = nil
        bookDepth = nil
        flowRead = nil
        tape = []
        depthDelivered = false
    }

    /// Force the depth stream (re)established now that the link is `.connected`.
    /// The initial `subscribeDepth` often fires from the chart workspace's
    /// `.onAppear` BEFORE the socket connects — and `send()` drops commands off
    /// `.connected`, so that first `subscribe_depth` is lost while `depthSymbol`
    /// is already set. The guarded `subscribeDepth` then no-ops (symbol unchanged)
    /// and the book never populates. This bypasses that guard: when a symbol is
    /// already targeted but no frame has landed, it re-sends the subscribe; when
    /// nothing is targeted (a reconnect cleared it), it starts a fresh one for the
    /// selected symbol. A stream already delivering is left alone (no thrash).
    /// The late-frame guard in `apply(.depth)` still protects against stale books.
    func resyncDepth(depthNeeded: Bool) {
        guard Self.shouldResyncDepth(
            connected: connection == .connected,
            depthNeeded: depthNeeded,
            depthSymbol: depthSymbol,
            everDelivered: depthDelivered
        ) else { return }
        if let sym = depthSymbol {
            // Same symbol, subscribe was dropped: re-deliver without churning
            // the (already-clear) book or unsubscribing a stream we still want.
            depthDelivered = false
            send(.subscribeDepth(symbol: sym))
        } else {
            // Nothing targeted (reconnect cleared it): fresh subscribe.
            subscribeDepth(selectedSymbol)
        }
    }

    /// Pure decision for `resyncDepth`: whether a depth subscribe must be
    /// (re)sent right now. True only when connected AND the dock still needs a
    /// book AND that book is not already delivering — either no symbol is
    /// targeted yet (subscribe fresh) or one is but no frame has ever landed
    /// (the subscribe was dropped while the socket was down; re-send). A stream
    /// already delivering frames for its symbol needs no resend.
    static func shouldResyncDepth(
        connected: Bool, depthNeeded: Bool, depthSymbol: String?, everDelivered: Bool
    ) -> Bool {
        guard connected, depthNeeded else { return false }
        if depthSymbol != nil, everDelivered { return false }
        return true
    }

    /// Offer a price the operator clicked in the depth ladder to the order
    /// ticket (the integration seam). NaN-safe by design law: a non-finite or
    /// non-positive click is ignored rather than seating garbage into a ticket.
    func setTicketPrice(_ px: Double) {
        guard px.isFinite, px > 0 else { return }
        pendingTicketPrice = px
    }

    /// The ticket calls this once it has consumed `pendingTicketPrice`.
    func clearTicketPrice() { pendingTicketPrice = nil }

    // MARK: Broker configuration

    /// Persist the operator's broker preferences and push them to the engine as
    /// a `set_broker_config` command. The engine re-validates (live-port +
    /// allow_live, finite/>0 limits), reconfigures/reconnects the active broker,
    /// and publishes an updated BrokerStatus we render live; on any failure it
    /// stays on the previous safe broker and emits a critical thought. This only
    /// records intent and sends — it never optimistically mutates `broker`, so
    /// the badge/venue tag always reflect the engine's actual posture, never a
    /// hoped-for one.
    func applyBrokerConfig(_ settings: BrokerSettings) {
        brokerSettings = settings
        BrokerSettingsStore.save(settings)
        send(.setBrokerConfig(
            mode: settings.mode,
            ibkrHost: settings.ibkrHost,
            ibkrPort: settings.ibkrPort,
            ibkrClientId: settings.ibkrClientId,
            ibkrAccount: settings.ibkrAccount,
            ibkrRoute: settings.ibkrRoute,
            allowLive: settings.allowLive,
            maxLiveOrderNotional: settings.maxLiveOrderNotional,
            maxLivePositionNotional: settings.maxLivePositionNotional,
            maxLiveDailyLoss: settings.maxLiveDailyLoss
        ))
    }

    // MARK: Derived

    func bars(_ symbol: String, _ interval: Interval) -> [Bar] {
        bars[symbol]?[interval] ?? []
    }

    func lastPrice(_ symbol: String) -> Double? {
        if let t = lastTick[symbol] { return t.price }
        // Universe symbols carry D1-only history — fall through to it.
        return bars[symbol]?[.m1]?.last?.close ?? bars[symbol]?[.d1]?.last?.close
    }

    /// Change % against the session reference. Equities read against the
    /// last RTH close of the PRIOR US/Eastern session when the D1 series
    /// carries one — so a pre-market print shows the real gap, not drift
    /// from whatever tick this process saw first. Everything else (crypto,
    /// equities with no D1 history yet) keeps the rolling `sessionOpen`
    /// reference. `nowMs` is injected for tests.
    func sessionChangePct(
        _ symbol: String,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> Double? {
        guard let last = lastPrice(symbol) else { return nil }
        if Self.isEquity(symbol),
            let ref = Self.priorSessionClose(d1: bars(symbol, .d1), nowMs: nowMs) {
            return (last - ref) / ref * 100
        }
        guard let open = sessionOpen[symbol], open > 0 else { return nil }
        return (last - open) / open * 100
    }

    /// The prior-session reference close: the newest D1 close whose session
    /// day sits STRICTLY before the current US/Eastern day. D1 closes are
    /// official RTH closes — the daily backfill never asks for extended
    /// hours, and the engine's live aggregator folds only RTH prints into
    /// equity daily bars (extended-hours prints are skipped), so a bar
    /// completed after an evening of after-hours drift still closes on the
    /// last 16:00 ET print. Skipping today's row keeps a same-day D1 bar —
    /// however it landed — from collapsing the change to ~0%. Pure; nil
    /// when the series has no usable prior bar (caller falls back).
    static func priorSessionClose(d1: [Bar], nowMs: Int64) -> Double? {
        let today = ChartMath.easternDayKey(nowMs)
        for bar in d1.reversed()
        where ChartMath.utcDayKey(bar.ts_open_ms) < today
            && bar.complete && bar.close.isFinite && bar.close > 0 {
            return bar.close
        }
        return nil
    }

    var totalUnrealized: Double {
        positions.values.reduce(0) { $0 + $1.unrealized_pnl }
    }

    /// True for bare-ticker (equity) symbols, which have listed options.
    static func isEquity(_ symbol: String) -> Bool { !symbol.contains("-") }

    func requestOptionsChain(underlying: String, expiry: String? = nil) {
        guard Self.isEquity(underlying) else { return }
        requestedChainUnderlying = underlying
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

    /// Open NEWS ▸ filings for a symbol and pull its EDGAR filings. Called from
    /// the COMPANY board's "all filings" affordance: filings now live as a tab
    /// inside the NEWS desk, so switch to NEWS, hint the filings tab (NewsView
    /// consumes the hint on appear), then request.
    func openFilings(_ symbol: String) {
        centerMode = .news
        newsInitialTab = .filings
        requestFilings(query: symbol.uppercased())
    }

    /// Ask the engine for a symbol/company's SEC EDGAR filings. `formFilter`
    /// and `text` are optional server-side narrowing (empty = none); the form-
    /// type chips filter the loaded result client-side. Re-request on every
    /// submit — stale reports must never masquerade as current. A watchdog
    /// clears the spinner if the engine never answers (e.g. an older build
    /// without FILINGS support). Blank queries are ignored.
    func requestFilings(query: String, formFilter: String = "", text: String = "") {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        filingsQuery = q
        filingsLoading = true
        filingsRequestSeq += 1
        let seq = filingsRequestSeq
        send(.getFilings(query: q, formFilter: formFilter, text: text))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, self.filingsRequestSeq == seq, self.filingsLoading else { return }
            self.filingsLoading = false
        }
    }

    /// Select a symbol for the chart/watchlist context. If the current
    /// interval has almost no bars for it (equities barely tick M1), jump to
    /// the densest interval so the chart never opens near-empty. Symbols
    /// with no history at all (ad-hoc searches) get an on-demand D1 fetch.
    func selectSymbol(_ symbol: String) {
        let symbol = symbol.uppercased()
        selectedSymbol = symbol
        if bars(symbol, selectedInterval).count < 30 {
            let densest = Interval.allCases
                .map { ($0, bars(symbol, $0).count) }
                .max { $0.1 < $1.1 }
            if let (interval, count) = densest, count >= 30 {
                selectedInterval = interval
            } else {
                send(.getHistory(symbol: symbol))
            }
        }
    }

    /// Pane-local history path for the multi-chart grid: request on-demand
    /// history for a symbol with no bars on any interval, WITHOUT touching
    /// `selectedSymbol` or `selectedInterval` — fixed panes must never move
    /// the global selection. Returns whether a request actually went out.
    @discardableResult
    func ensureSymbolData(_ symbol: String) -> Bool {
        let symbol = symbol.uppercased()
        let hasBars = bars[symbol]?.values.contains { !$0.isEmpty } ?? false
        guard !hasBars, !historyMisses.contains(symbol) else { return false }
        send(.getHistory(symbol: symbol))
        return true
    }

    // MARK: Historical depth

    /// The connect snapshot often lands before the engine finishes its 5y
    /// daily backfill, and equity D1 bars never stream live — so charts stay
    /// short forever without a follow-up. One deep re-sync ~20s after each
    /// hello closes the gap. The token guards reconnects: each hello bumps
    /// it, so only the latest connection's task fires. applySnapshot rebuilds
    /// bars wholesale but never touches optionsChain/copilot/company state,
    /// and it keeps the selected symbol whenever it is still listed.
    private func scheduleFollowUpSync() {
        connectionToken += 1
        let token = connectionToken
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, self.connectionToken == token else { return }
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            // A depth-driven re-sync (range preset right after connect) may
            // have just fired — inside the cooldown this one is redundant.
            guard nowMs - self.lastResyncMs >= Self.resyncCooldownMs else { return }
            self.lastResyncMs = nowMs
            self.send(.sync(barsPerSymbol: self.maxBars))
        }
    }

    /// Ask the engine for deeper history when the D1 series cannot cover the
    /// requested span (range presets call this before framing). Rate-limited
    /// so preset clicks and re-frames never spam requests; `nowMs` is
    /// injected for tests. Watchlist symbols ride the shared sync cooldown;
    /// off-watchlist tickers ride outside that sync entirely (a sync for
    /// another symbol never deepens them), so their direct getHistory runs
    /// on its own per-symbol cooldown. Returns whether anything was issued.
    @discardableResult
    func ensureDepth(
        symbol: String, spanMs: Int64,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> Bool {
        guard Self.isShortSeries(bars(symbol, .d1), spanMs: spanMs, nowMs: nowMs) else {
            return false
        }
        var issued = false
        if nowMs - lastResyncMs >= Self.resyncCooldownMs {
            lastResyncMs = nowMs
            send(.sync(barsPerSymbol: maxBars))
            issued = true
        }
        if !symbols.contains(symbol),
            nowMs - (lastHistoryMs[symbol] ?? 0) >= Self.resyncCooldownMs {
            // Universe/searched symbols ride outside the watchlist sync —
            // fetch their D1 history directly.
            lastHistoryMs[symbol] = nowMs
            send(.getHistory(symbol: symbol))
            issued = true
        }
        return issued
    }

    /// True when the series cannot cover the trailing `spanMs` window — its
    /// oldest bar is younger than the cutoff (or there are no bars at all).
    static func isShortSeries(_ series: [Bar], spanMs: Int64, nowMs: Int64) -> Bool {
        guard let oldest = series.first else { return true }
        return oldest.ts_open_ms > nowMs - spanMs
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

    /// Fire a copilot question. Returns the request id so section-local
    /// surfaces (the NEWS brief panel) can track their own answer inline —
    /// the reply still lands in the shared copilot thread.
    @discardableResult
    func askCopilot(_ question: String) -> String {
        askSeq += 1
        let id = "ask-\(Int(Date().timeIntervalSince1970 * 1000))-\(askSeq)"
        copilot.append(CopilotMessage(id: "\(id)-q", role: .user, text: question))
        copilot.append(CopilotMessage(id: id, role: .cortex, text: "", pending: true))
        pendingAsk = id
        send(.askAi(requestId: id, question: question))
        return id
    }

    /// Fire a NEWS AI brief and record it in the section-local history so the
    /// AI-BRIEF tab can list past question/answer pairs. Delegates to
    /// `askCopilot` (the reply still lands in the shared thread) and returns
    /// its request id. Newest-first; the history caps at `newsBriefHistoryCap`.
    @discardableResult
    func askNewsBrief(_ question: String) -> String {
        let id = askCopilot(question)
        newsBriefHistory.insert(NewsBriefRef(requestId: id, question: question), at: 0)
        if newsBriefHistory.count > Self.newsBriefHistoryCap {
            newsBriefHistory.removeLast(newsBriefHistory.count - Self.newsBriefHistoryCap)
        }
        return id
    }

    /// A pending ask can never resolve once its answer is lost: AiAnswer is
    /// not in the engine's critical event set, so under backpressure it is
    /// dropped and a gap frame arrives instead. Fail the pending bubble and
    /// clear `pendingAsk` so ASK surfaces re-arm instead of locking up.
    private func failPendingAsk(_ reason: String) {
        guard let id = pendingAsk else { return }
        pendingAsk = nil
        if let idx = copilot.firstIndex(where: { $0.id == id }), copilot[idx].pending {
            copilot[idx].pending = false
            copilot[idx].text = reason
        }
    }

    // MARK: Frame application

    func apply(_ frame: ServerFrame) {
        switch frame {
        case .hello(let v):
            protocolVersion = v
            scheduleFollowUpSync()
        case .snapshot(let snap):
            applySnapshot(snap)
        case .tick(let t):
            lastTick[t.symbol] = t
            if sessionOpen[t.symbol] == nil { sessionOpen[t.symbol] = t.price }
        case .bar(let bar):
            applyBar(bar)
        case .bookTop(let top):
            bookTop[top.symbol] = top
        case .depth(let d):
            // Only accept the book for the symbol we are subscribed to — a late
            // frame from a just-unsubscribed symbol could still be in flight and
            // must never overwrite the current ladder. A landed frame proves the
            // subscribe took, so the resync path stops re-sending it.
            if d.symbol == depthSymbol {
                bookDepth = d
                depthDelivered = true
            }
        case .tape(let p):
            // Same subscription guard, then ring-cap newest-first.
            guard p.symbol == depthSymbol else { break }
            tape.insert(p, at: 0)
            if tape.count > Self.tapeCap { tape.removeLast(tape.count - Self.tapeCap) }
        case .flow(let f):
            // Same subscription guard as depth — a late read from a just-
            // unsubscribed symbol must never overwrite the current panel.
            if f.symbol == depthSymbol { flowRead = f }
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
        case .brokerStatus(let b):
            broker = b
        case .caution(let c):
            // Surface caution requests in the agent feed as warning thoughts.
            thoughts.insert(AgentThought(
                agent: c.agent, squadron: "risk", severity: .warning,
                text: "caution \(c.value.formatted(.number.precision(.fractionLength(2)))) on \(c.scope ?? "all"): \(c.reason)",
                tags: ["caution"], confidence: 1.0, symbol: c.scope, ts_ms: c.ts_ms
            ), at: 0)
        case .optionsChain(let chain):
            // The engine republishes chains for ALL equities periodically —
            // only the requested underlying may replace what the operator is
            // viewing. Unsolicited chains may still fill an empty slot.
            if chain.underlying == requestedChainUnderlying {
                optionsChain = chain
                chainLoading = false
            } else if optionsChain == nil {
                optionsChain = chain
            }
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
            applyScanBoard(board)
        case .news(let board):
            newsBoard = board
        case .filings(let report):
            // Answered on demand, one tokio task per request with no ordering
            // guarantee — a slow full-text pull for an earlier query can land
            // AFTER a fast submissions pull for a newer one. Guard by the
            // echoed query (the engine returns it verbatim; `filingsQuery`
            // holds the latest request) so a superseded response can never
            // overwrite the current entity or clear the spinner for a request
            // still in flight. The watchdog handles the never-answered case.
            guard report.query == filingsQuery else { break }
            filingsReport = report
            filingsLoading = false
        case .history(let slice):
            guard !slice.bars.isEmpty else {
                // The engine answered "no data" (unresolvable ticker or a
                // failed backfill). Remember the miss so the on-demand path
                // stops re-requesting — and re-hitting Yahoo — forever.
                historyMisses.insert(slice.symbol)
                break
            }
            historyMisses.remove(slice.symbol)
            bars[slice.symbol, default: [:]][slice.interval] =
                slice.bars.sorted { $0.ts_open_ms < $1.ts_open_ms }
            // If the operator is waiting on this exact chart, switch to the
            // interval the history arrived on.
            if selectedSymbol == slice.symbol, bars(slice.symbol, selectedInterval).count < 30 {
                selectedInterval = slice.interval
            }
            if sessionOpen[slice.symbol] == nil {
                sessionOpen[slice.symbol] = slice.bars.last?.close
            }
        case .gap, .error:
            // Under client lag the engine drops non-critical events (the
            // AiAnswer among them) and sends a gap frame instead — an
            // in-flight ask can therefore never resolve. Fail it now.
            failPendingAsk("answer lost — ask again")
        case .unknown:
            break
        }
    }

    private func applySnapshot(_ snap: EngineSnapshot) {
        symbols = snap.symbols
        if let u = snap.search_universe { searchUniverse = u }
        // Mid-session re-syncs (hello follow-up, ensureDepth) must never
        // yank a universe/ad-hoc selection away — only reset when the model
        // truly has nothing to show for it.
        if !symbols.contains(selectedSymbol),
            !searchUniverse.contains(selectedSymbol),
            bars[selectedSymbol] == nil,
            let first = symbols.first {
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
        // Only adopt a broker posture the snapshot actually carries — a lean
        // re-sync snapshot that omits it must not wipe a live posture a
        // standalone broker_status frame already established.
        if let b = snap.broker { broker = b }
        // A snapshot may carry the latest book per subscribed symbol — adopt it
        // only for the symbol we are actually streaming (never another's book).
        if let sym = depthSymbol, let d = snap.depth?[sym] {
            bookDepth = d
            depthDelivered = true
        }
        // Likewise the latest flow read — only for the streamed symbol.
        if let sym = depthSymbol, let f = snap.flow?[sym] { flowRead = f }
        if let r = snap.regimes { regimeBoard = r }
        if let g = snap.geo { geoPulse = g }
        if let s = snap.scan { applyScanBoard(s) }
        if let n = snap.news { newsBoard = n }
        for (symbol, byInterval) in rebuilt {
            if sessionOpen[symbol] == nil {
                sessionOpen[symbol] = byInterval[.m1]?.last?.close ?? byInterval[.h1]?.last?.close
            }
        }
    }

    /// Every scan-board arrival (frame or snapshot) replaces the board and
    /// folds its flag-transition alerts into the accumulated feed. The pure
    /// merge (order, dedupe, cap) lives in ScanAlertFeed for tests.
    private func applyScanBoard(_ board: ScanBoard) {
        scanBoard = board
        if let alerts = board.alerts, !alerts.isEmpty {
            scanAlerts = ScanAlertFeed.accumulate(scanAlerts, incoming: alerts)
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
