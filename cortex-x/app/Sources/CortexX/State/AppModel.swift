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

/// An `error` frame from the engine: it refused the last command, or could not
/// parse it. Kept so the UI can say so — a rejected command used to be dropped
/// on the floor, which made an out-of-date engine look like a broken control.
struct EngineErrorNote: Equatable {
    let detail: String
    let at: Date
}

/// A command the app could not put on the wire. Surfaced, never swallowed: on a
/// trading desk an undelivered `flatten_all` or kill switch that looks delivered
/// is the most dangerous failure the client can have.
struct UndeliveredCommand: Equatable {
    /// Operator-facing name of the action, not the wire tag.
    let label: String
    let reason: String
    let at: Date
}

/// The identity of one outstanding `get_filings` request.
///
/// The engine echoes only `query` back in its `FilingsReport`, which is not
/// enough to tell the FILINGS desk's bare `onAppear` pull for AAPL apart from the
/// operator's keyword search for the SAME entity. `text` is therefore part of the
/// identity: it decides WHICH EDGAR endpoint answers (full-text vs submissions),
/// and so which `source` the report carries back.
struct FilingsRequestID: Equatable {
    let seq: Int
    let query: String
    let formFilter: String
    let text: String
    /// A keyword request is answered by EDGAR full-text search; a bare one by
    /// the submissions list.
    var wantsFullText: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }
}

@MainActor
@Observable
final class AppModel {
    // MARK: Connection
    private(set) var connection: ConnectionState = .disconnected
    private(set) var protocolVersion = 0
    /// Features the connected engine declared in its `hello` (see
    /// `EngineCapability`). Empty until a hello lands — and empty AFTER one from
    /// an engine too old to declare any.
    private(set) var engineCapabilities: Set<String> = []
    /// The connected engine's crate version, for the out-of-date banner.
    private(set) var engineVersion = ""
    /// Capabilities this app build needs that the connected engine lacks.
    ///
    /// This is the difference between a diagnosable problem and a mystery. The
    /// engine outlives app builds by design, so a fresh app regularly meets a
    /// cortexd from a previous build. That engine accepts new commands (serde
    /// ignores unknown fields) and answers them wrongly but plausibly, so the
    /// symptom is a feature that silently does nothing. Non-empty here means the
    /// operator sees a banner naming the problem instead.
    var missingEngineCapabilities: [String] {
        // The socket reaches `.connected` BEFORE the hello frame arrives, and
        // capabilities are empty until it does. Judging in that window would
        // flash "engine out of date" on every single connect — so nothing is
        // claimed until the engine has actually introduced itself.
        guard case .connected = connection, helloReceived else { return [] }
        return EngineCapability.required.filter { !engineCapabilities.contains($0) }
    }
    /// Whether a `hello` has been seen on the CURRENT connection. Cleared on
    /// every disconnect so a reconnect re-earns its verdict.
    private(set) var helloReceived = false
    /// True when the connected engine cannot serve this app build correctly.
    var engineOutdated: Bool { !missingEngineCapabilities.isEmpty }
    /// Last error frame the engine sent (rejected command, unparseable frame).
    /// Surfaced rather than swallowed: an `error` frame is the engine saying it
    /// refused what the app asked for, which is exactly the signal an operator
    /// needs when a control appears to do nothing.
    private(set) var lastEngineError: EngineErrorNote?

    // MARK: Market
    private(set) var symbols: [String] = []
    var selectedSymbol: String = "BTC-USD"
    var selectedInterval: Interval = .m1
    /// symbol -> interval -> bars (forming bar is always last, capped)
    private(set) var bars: [String: [Interval: [Bar]]] = [:]
    private(set) var lastTick: [String: Tick] = [:]
    private(set) var bookTop: [String: BookTop] = [:]
    /// LAST-RESORT reference for % change: the first real session anchor seen
    /// for a symbol on the current UTC day. Only consulted when the D1 series
    /// cannot supply a true reference (see `sessionChangePct`) — it is a rolling
    /// approximation, never the preferred answer.
    private(set) var sessionOpen: [String: Double] = [:]
    /// The UTC day each `sessionOpen` entry was captured on, so the reference
    /// ROLLS OVER.
    ///
    /// This used to be written only when the slot was nil, with no day logic
    /// anywhere despite the doc comment claiming "per symbol/day". An app left
    /// open for three days therefore reported the change since LAUNCH (e.g.
    /// "+31.40%") styled exactly like a real session gap. Keying by day means a
    /// stale reference is replaced the moment the first price of a new day
    /// lands, instead of being kept for the life of the process.
    private var sessionOpenDay: [String: Int] = [:]

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
    /// True when the engine has told us it DROPPED events (a `gap` frame) and
    /// the rebuilding snapshot has not landed yet.
    ///
    /// `Position` and `Account` are not in the engine's critical set, so under
    /// client lag they are dropped and counted instead of queued. A position
    /// closed by a fill publishes its qty→0 event EXACTLY ONCE (the periodic
    /// republish only re-emits symbols marked dirty by fresh marks), so a single
    /// dropped frame leaves the pre-close quantity in `positions` — a phantom
    /// open position with wrong gross/net exposure that the operator might try
    /// to "flatten". The portfolio panes disclose this flag (ember dot + bone
    /// text) for the seconds until the resync snapshot rebuilds state, so the
    /// numbers are never silently wrong. Cleared by `applySnapshot`.
    private(set) var staleAfterGap = false
    /// Events the engine reported dropping since the last rebuilding snapshot.
    /// Diagnostic: it says HOW much was lost, not merely that something was.
    private(set) var droppedEventCount = 0

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
    enum CenterMode: String, CaseIterable { case chart, scanner, heatmap, news, company, options, foundry, regimes, meridian, settings }
    var centerMode: CenterMode = .chart
    private(set) var optionsChain: OptionsChain?
    private(set) var chainLoading = false
    /// Why the last chain request produced nothing, for an honest empty state
    /// instead of a spinner that stops with no explanation.
    private(set) var chainError: String?
    private var chainRequestSeq = 0
    private var simRequestSeq = 0
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
    /// Every filings request sent and not yet accounted for, in send order.
    ///
    /// Acceptance and timeout used to disagree about WHICH request was current:
    /// the watchdog keyed on `filingsRequestSeq` while the response guard
    /// compared only the echoed query string. Two pulls for the same entity —
    /// the desk's `onAppear` (no keywords) and the operator's keyword submit —
    /// therefore both passed the guard, so the slower unfiltered submissions
    /// answer silently replaced the keyword results the operator was reading,
    /// with the spinner already down. This list gives both paths ONE identity.
    private var outstandingFilings: [FilingsRequestID] = []

    /// Whether a report came from EDGAR full-text search rather than the
    /// submissions list. The engine's two source strings are the only
    /// discriminator on the wire (`FilingsReport` carries no request id).
    static func isFullTextReport(_ source: String) -> Bool {
        source.contains("full-text")
    }

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

    /// (symbol|interval) pairs whose on-demand history came back empty (dead
    /// ticker, failed backfill, or an interval with no REST source like 1s).
    /// Keyed per-interval so a 1s miss never blocks a D1/5m request for the same
    /// symbol. Without this, the ensure* paths re-fire a fresh engine request —
    /// and a fresh Yahoo egress — on every switch.
    private(set) var historyMisses: Set<String> = []

    /// When each miss was recorded, so misses EXPIRE.
    ///
    /// A miss used to be permanent for the life of the connection: the only code
    /// that cleared it was the arrival of a non-empty slice for the same key, and
    /// the only code that could ask for one was gated on the miss itself. So a
    /// single transient failure — an upstream hiccup, a symbol requested before
    /// its listing, a weekend fetch that came back empty — locked that series out
    /// until the app reconnected. Now the block is a cooldown, not a life
    /// sentence.
    private var historyMissMs: [String: Int64] = [:]

    /// How long a miss suppresses re-requests. Long enough to stop the switch-
    /// spam the miss set exists to prevent, short enough that a series which
    /// starts working is picked up within the same session.
    static let historyMissTtlMs: Int64 = 10 * 60_000

    /// Whether a recorded miss still blocks a re-request. An expired miss is
    /// dropped here so the state cannot accumulate stale keys forever.
    private func historyMissBlocks(_ key: String, nowMs: Int64) -> Bool {
        guard historyMisses.contains(key) else { return false }
        guard let at = historyMissMs[key], nowMs - at < Self.historyMissTtlMs else {
            historyMisses.remove(key)
            historyMissMs[key] = nil
            return false
        }
        return true
    }

    /// Miss-set / cooldown key: one entry per (symbol, interval).
    static func historyMissKey(_ symbol: String, _ interval: Interval) -> String {
        "\(symbol)|\(interval.rawValue)"
    }

    /// In-flight `getHistory` requests: key -> when it was sent.
    ///
    /// Requests used to be fire-and-forget, and `.history` frames were filed
    /// under whatever interval ARRIVED. Nothing connected an answer back to the
    /// question, so an engine that answered a 5-minute request with daily bars
    /// resolved the daily series, recorded no miss for 5-minute, and left the
    /// chart on "waiting for market data" behind a 30s cooldown — forever, with
    /// no error anywhere. Tracking the question makes a wrong or absent answer a
    /// reportable event instead of silence.
    private var pendingHistory: [String: Int64] = [:]

    /// Why a (symbol, interval) series cannot be shown, when the reason is known.
    /// Drives the chart's empty state so it states the cause instead of implying
    /// data is still on its way.
    private(set) var historyUnavailable: [String: String] = [:]

    /// How long to wait for a `getHistory` answer before calling it unanswered.
    /// Comfortably longer than a cold Yahoo backfill (a few seconds).
    static let historyTimeoutSec: UInt64 = 20

    /// The reason this series is unavailable, or nil while it may still arrive.
    func historyReason(_ symbol: String, _ interval: Interval) -> String? {
        historyUnavailable[Self.historyMissKey(symbol.uppercased(), interval)]
    }

    /// True while a request for this series is still outstanding — the chart may
    /// legitimately show a loading state.
    func historyPending(_ symbol: String, _ interval: Interval) -> Bool {
        pendingHistory[Self.historyMissKey(symbol.uppercased(), interval)] != nil
    }

    /// Record an outgoing history request and arm its watchdog. Every
    /// `getHistory` send goes through here so no request can be lost silently.
    private func trackHistoryRequest(
        _ symbol: String, _ interval: Interval,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        let key = Self.historyMissKey(symbol, interval)
        pendingHistory[key] = nowMs
        historyUnavailable[key] = nil
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.historyTimeoutSec))
            guard let self else { return }
            // Still pending means this exact request was never answered. A newer
            // request for the same series overwrites `pendingHistory[key]` with a
            // later timestamp, so compare before declaring a timeout.
            guard self.pendingHistory[key] == nowMs else { return }
            self.pendingHistory[key] = nil
            self.historyUnavailable[key] = self.engineOutdated
                ? "engine is out of date — it cannot serve \(interval.label) bars"
                : "engine did not answer the \(interval.label) history request"
        }
    }

    /// Resolve the request an arriving `.history` frame answers, and diagnose the
    /// case where the engine answered a DIFFERENT interval than any that was
    /// asked for. An engine without `history_interval` answers every request with
    /// daily bars; the requested intraday series would otherwise stay pending
    /// until the watchdog fired, with the cooldown re-arming the same dead loop.
    private func resolveHistoryRequest(_ slice: HistorySlice) {
        let symbol = slice.symbol.uppercased()
        let answered = Self.historyMissKey(symbol, slice.interval)
        if pendingHistory.removeValue(forKey: answered) != nil {
            historyUnavailable[answered] = nil
            return // the answer matches the question — nothing to diagnose
        }
        // Unrequested interval: the engine substituted its own. Fail every
        // outstanding request for this symbol now, naming the real cause, rather
        // than letting each one time out separately.
        let stranded = pendingHistory.keys.filter { $0.hasPrefix("\(symbol)|") }
        guard !stranded.isEmpty else { return }
        for key in stranded {
            pendingHistory[key] = nil
            historyUnavailable[key] = engineOutdated
                ? "engine is out of date — it answered with \(slice.interval.label) bars"
                : "engine has no bars at this interval (answered \(slice.interval.label))"
        }
    }

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

    /// Display-rate coalescer for the high-frequency market frames (tick /
    /// book_top / depth / flow / tape / forming bar). It buffers the LATEST of
    /// each instead of flipping observable state at feed rate; a bounded flush
    /// commits the batch. `@ObservationIgnored` so buffering never itself
    /// triggers a SwiftUI pass. See `receive`.
    @ObservationIgnored private var coalescer = MarketCoalescer()
    /// One pending flush at a time — a buffered frame arms the timer, further
    /// frames in the same window just add to the buffer.
    @ObservationIgnored private var flushScheduled = false
    /// Display-rate flush interval (ms). ~12 Hz: caps market-driven re-renders
    /// at ~12/s instead of the ~40/s feed rate, with no perceptible lag.
    static let flushMs = 80

    init(client: EngineClient = EngineClient()) {
        self.client = client
        self.brokerSettings = BrokerSettingsStore.load()
        // Frames land in `receive`, which coalesces the high-frequency ones to
        // display rate before they reach `apply` (the single source of truth
        // for HOW a frame mutates state).
        client.onFrame = { [weak self] frame in self?.receive(frame) }
        client.onStateChange = { [weak self] s in self?.handleStateChange(s) }
        client.onSendFailure = { [weak self] cmd, why in self?.noteSendFailure(cmd, why) }
    }

    func handleStateChange(_ s: ConnectionState) {
        connection = s
        // A dropped connection orphans any in-flight ask: the engine answers
        // by exact request id only, and a fresh connection knows nothing
        // about it — without this every ASK surface stays disabled forever.
        if s != .connected {
            // Nothing is known about an engine we cannot reach: the next
            // connection may well be a DIFFERENT engine (that is exactly what
            // the restart path does), so its capabilities must be re-learned
            // rather than inherited.
            helloReceived = false
            engineCapabilities = []
            engineVersion = ""
            // In-flight requests die with the socket. Their spinners must not
            // outlive them: `simRunning` disables the FOUNDRY Run button and
            // `chainLoading` hides the OPTIONS empty state, so a latched flag is
            // a permanently dead section.
            if chainLoading {
                chainLoading = false
                chainError = "connection lost before the chain arrived"
            }
            simRunning = false
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
            // Drop any buffered market frames from the dead connection so a
            // stale tick/book/print can never flush across the reconnect
            // (the fresh snapshot + live stream repopulate from scratch).
            coalescer.clear()
        }
    }

    func start() { client.start() }
    func stop() { client.stop() }
    /// The single command exit. Returns whether the command reached the engine so
    /// safety-critical callers can react instead of assuming success.
    @discardableResult
    func send(_ command: Command) -> Bool { client.send(command) }

    /// A command that never reached the engine. Held so the UI can say so —
    /// an operator who clicks "Engage Kill Switch" on a dropped link must not be
    /// left believing trading is halted when the engine never heard it.
    private(set) var undeliveredCommand: UndeliveredCommand?

    /// True while commands can actually be delivered. Safety controls read this
    /// so they never present themselves as armed when they are inert.
    var engineReachable: Bool {
        if case .connected = connection { return true }
        return false
    }

    func clearUndeliveredCommand() { undeliveredCommand = nil }

    /// Record a command the transport refused. Called from the client callback.
    private func noteSendFailure(_ command: Command, _ reason: String) {
        undeliveredCommand = UndeliveredCommand(
            label: command.operatorLabel, reason: reason, at: Date()
        )
    }

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
    /// from whatever tick this process saw first. 24/7 instruments (crypto)
    /// read against the prior UTC day's D1 close, the reference every venue
    /// quotes a 24h change against. Only when the D1 series can supply
    /// neither does the rolling `sessionOpen` approximation apply.
    /// `nowMs` is injected for tests.
    func sessionChangePct(
        _ symbol: String,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> Double? {
        guard let last = lastPrice(symbol) else { return nil }
        if let ref = Self.sessionReference(symbol, d1: bars(symbol, .d1), nowMs: nowMs) {
            return (last - ref) / ref * 100
        }
        guard let open = sessionOpen[symbol], open > 0 else { return nil }
        return (last - open) / open * 100
    }

    /// The true reference close for a symbol, from its D1 series, or nil when
    /// the series cannot supply one. Equities key their session day off
    /// US/Eastern (the RTH calendar); 24/7 instruments off UTC, which is where
    /// their daily bars bucket and where the conventional 24h change is
    /// measured from. Pure; the caller falls back when this is nil.
    static func sessionReference(_ symbol: String, d1: [Bar], nowMs: Int64) -> Double? {
        isEquity(symbol)
            ? priorSessionClose(d1: d1, nowMs: nowMs)
            : priorUtcDayClose(d1: d1, nowMs: nowMs)
    }

    /// The 24h reference for a continuously-traded instrument: the close of the
    /// newest COMPLETE D1 bar belonging to a UTC day strictly before the current
    /// one. Crypto has no session break, so "yesterday's UTC close" is the only
    /// reference that means anything — and unlike the rolling `sessionOpen` it
    /// does not depend on when this process happened to start. Skipping today's
    /// row keeps a same-day D1 bar from collapsing the change to ~0%; requiring
    /// `complete` keeps the still-forming daily bar out. Pure.
    static func priorUtcDayClose(d1: [Bar], nowMs: Int64) -> Double? {
        let today = ChartMath.utcDayKey(nowMs)
        for bar in d1.reversed()
        where ChartMath.utcDayKey(bar.ts_open_ms) < today
            && bar.complete && bar.close.isFinite && bar.close > 0 {
            return bar.close
        }
        return nil
    }

    /// A `sessionOpen` seed from a bar series: the OPEN of the oldest bar
    /// belonging to the current UTC day (that day's own anchor), else the newest
    /// close from a PRIOR day (yesterday's close). Never the newest close of
    /// today's data — that is simply the current price, and seeding from it is
    /// exactly why a freshly connected app reported "+0.00%" for every crypto
    /// symbol no matter how far it had actually moved. Expects `series` sorted
    /// oldest-first (both call sites sort). Pure.
    static func sessionReferenceSeed(_ series: [Bar], nowMs: Int64) -> Double? {
        let today = ChartMath.utcDayKey(nowMs)
        for bar in series where ChartMath.utcDayKey(bar.ts_open_ms) == today {
            if bar.open.isFinite, bar.open > 0 { return bar.open }
        }
        for bar in series.reversed() where ChartMath.utcDayKey(bar.ts_open_ms) < today {
            if bar.close.isFinite, bar.close > 0 { return bar.close }
        }
        return nil
    }

    /// Record the rolling reference for `symbol`, keyed by UTC day so it cannot
    /// outlive the day it describes. Writes when there is no reference yet OR
    /// when the recorded one belongs to an earlier day; ignores non-finite and
    /// non-positive prices (a zero reference would divide the change by zero).
    private func noteSessionOpen(
        _ symbol: String, _ price: Double?, nowMs: Int64
    ) {
        guard let price, price.isFinite, price > 0 else { return }
        let day = ChartMath.utcDayKey(nowMs)
        if sessionOpen[symbol] != nil, sessionOpenDay[symbol] == day { return }
        sessionOpen[symbol] = price
        sessionOpenDay[symbol] = day
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

    /// How long a request may stay outstanding before its spinner is resolved as
    /// a failure. Matches the company / filings watchdogs already in this file.
    static let requestTimeoutSec: UInt64 = 20

    /// Load an option chain.
    ///
    /// The spinner used to be set unconditionally and cleared ONLY by a matching
    /// `optionsChain` frame. The engine answers a failed fetch with a warning
    /// Thought and no chain, and an undelivered command produces nothing at all —
    /// so OPTIONS spun forever with no way back. Now the flag is only raised if
    /// the command actually went out, and a watchdog resolves it either way.
    func requestOptionsChain(underlying: String, expiry: String? = nil) {
        guard Self.isEquity(underlying) else { return }
        requestedChainUnderlying = underlying
        guard send(.getOptionsChain(underlying: underlying, expiry: expiry)) else {
            chainLoading = false // never claim a load that was never requested
            return
        }
        chainLoading = true
        chainRequestSeq += 1
        let seq = chainRequestSeq
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.requestTimeoutSec))
            guard let self, self.chainRequestSeq == seq, self.chainLoading else { return }
            self.chainLoading = false
            self.chainError = "no option chain for \(underlying) — the engine did not answer"
        }
    }

    /// Run the simulation. Same latch as the chain: `simRunning` disables the Run
    /// button, so a dropped command or a silent engine bricked FOUNDRY for the
    /// rest of the session.
    func runSimulation() {
        guard send(.runSimulation) else {
            simRunning = false
            return
        }
        simRunning = true
        simRequestSeq += 1
        let seq = simRequestSeq
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.requestTimeoutSec))
            guard let self, self.simRequestSeq == seq, self.simRunning else { return }
            self.simRunning = false
        }
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
        // Record the FULL identity, not just the seq: the response guard needs
        // the same one, or a superseded answer can overwrite a newer one.
        outstandingFilings.append(FilingsRequestID(
            seq: seq, query: q, formFilter: formFilter, text: text
        ))
        send(.getFilings(query: q, formFilter: formFilter, text: text))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self else { return }
            // Drop this request's identity whether or not it was the latest, so
            // an answer that arrives after its own timeout can never be
            // attributed to a later request — and the list stays bounded by the
            // requests issued inside one timeout window.
            self.outstandingFilings.removeAll { $0.seq == seq }
            guard self.filingsRequestSeq == seq, self.filingsLoading else { return }
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
                // No data on any interval — land on D1 explicitly (the deep
                // backfill target) so the arriving slice renders in place. The
                // .history handler no longer auto-switches, so the intended
                // interval must be set here, not inferred from what arrives.
                selectedInterval = .d1
                sendHistoryRequest(symbol, .d1)
            }
        }
    }

    /// Request history for the interval the operator switched to when the client
    /// holds too few bars for it. This is what lets EQUITY intraday charts
    /// (1m/5m/15m/1h) fill from Yahoo when no live feed produces them. Per-
    /// (symbol, interval) miss + cooldown tracking stops re-requesting an
    /// interval the engine cannot fill (e.g. 1s) or spamming on rapid switches.
    @discardableResult
    func ensureIntervalData(
        _ symbol: String, _ interval: Interval,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> Bool {
        let symbol = symbol.uppercased()
        guard bars(symbol, interval).count < 30 else { return false }
        let key = Self.historyMissKey(symbol, interval)
        // An engine without `history_interval` answers ANY interval with daily
        // bars, so asking is worse than useless: it burns an upstream fetch and
        // then reads as a chart that never loads. Diagnose it immediately.
        if interval != .d1, engineOutdated {
            historyUnavailable[key] =
                "engine is out of date — it cannot serve \(interval.label) bars"
            return false
        }
        guard !historyMissBlocks(key, nowMs: nowMs),
              nowMs - (lastHistoryMs[key] ?? 0) >= Self.resyncCooldownMs else { return false }
        lastHistoryMs[key] = nowMs
        sendHistoryRequest(symbol, interval)
        return true
    }

    /// Send a `getHistory` and register it as in-flight. The ONLY way this
    /// command leaves the app, so every request has a watchdog and every answer
    /// can be matched back to its question.
    private func sendHistoryRequest(_ symbol: String, _ interval: Interval) {
        trackHistoryRequest(symbol, interval)
        send(.getHistory(symbol: symbol, interval: interval))
    }

    // MARK: Engine lifecycle

    /// Ask the engine to exit so the app's own bundled (newer) engine takes over.
    ///
    /// Explicit operator action only, from the out-of-date-engine banner. This is
    /// NOT the kill switch: it stops trading, monitoring AND position
    /// reconciliation until the replacement engine is up. The reconnect logic in
    /// EngineClient does the rest — it retries, finds nothing listening, and
    /// EngineBootstrap launches the bundled engine.
    func restartEngine(reason: String = "operator restarted an out-of-date engine") {
        send(.shutdown(reason: reason))
        EngineBootstrap.prepareForRelaunch()
    }

    /// Pane-local history path for the multi-chart grid: request on-demand
    /// history for a symbol with no bars on any interval, WITHOUT touching
    /// `selectedSymbol` or `selectedInterval` — fixed panes must never move
    /// the global selection. Returns whether a request actually went out.
    @discardableResult
    func ensureSymbolData(
        _ symbol: String,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> Bool {
        let symbol = symbol.uppercased()
        let hasBars = bars[symbol]?.values.contains { !$0.isEmpty } ?? false
        let key = Self.historyMissKey(symbol, .d1)
        guard !hasBars, !historyMissBlocks(key, nowMs: nowMs) else { return false }
        sendHistoryRequest(symbol, .d1)
        return true
    }

    // MARK: Historical depth

    /// The connect snapshot often lands before the engine finishes its 5y
    /// daily backfill, and equity D1 bars never stream live — so charts stay
    /// short forever without a follow-up. One deep re-sync ~20s after each
    /// hello closes the gap. The token guards reconnects: each hello bumps
    /// it, so only the latest connection's task fires. applySnapshot MERGES the
    /// bar store (only the series the snapshot carries are replaced, so this
    /// automatic follow-up cannot destroy an on-demand intraday series), never
    /// touches optionsChain/copilot/company state, and keeps the selected symbol
    /// whenever it is still listed.
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
            sendHistoryRequest(symbol, .d1)
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

    // MARK: Display-rate coalescing

    /// Every engine frame enters here. The high-frequency market frames (tick /
    /// book_top / depth / flow / tape and the FORMING bar) drown the UI in
    /// re-renders at ~40 Hz, so they are buffered in the coalescer and committed
    /// together on a ~12 Hz flush — the view repaints from market data at most
    /// ~12/s. Everything else (completed bars, orders, fills, positions, risk,
    /// account, thoughts, snapshots, answers, …) is low-frequency and/or
    /// interaction-critical and applies immediately. `apply` stays the single
    /// source of truth for HOW a frame mutates state; this only governs HOW
    /// OFTEN, never WHAT — the subscription guards, ring caps and session math
    /// all still run in `apply` exactly as before.
    func receive(_ frame: ServerFrame) {
        if coalescer.ingest(frame) {
            scheduleFlush()
        } else {
            apply(frame)
        }
    }

    /// Arm the display-rate flush if one is not already pending. The first
    /// buffered frame in a window schedules the commit; later frames in the same
    /// window fall into the same buffer and ride the same flush.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.flushMs))
            guard let self else { return }
            self.flushScheduled = false
            self.flushMarket()
        }
    }

    /// Commit the buffered market frames in ONE synchronous pass, so the many
    /// mutations coalesce into a single SwiftUI update. Each drained frame runs
    /// through `apply`, so a flushed tick/book/depth/flow/tape/forming-bar is
    /// applied by the very same code path (and guards) as an immediate frame.
    /// Called by the flush timer; exposed for tests to drive deterministically.
    func flushMarket() {
        for frame in coalescer.drain() { apply(frame) }
    }

    // MARK: Frame application

    /// `nowMs` is injected so the time-based state a frame writes (currently the
    /// history-miss expiry stamp) shares ONE clock with the `ensure*` paths that
    /// read it. Stamping with the wall clock while those paths are given a test
    /// clock silently disables the expiry.
    func apply(
        _ frame: ServerFrame,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        switch frame {
        case .hello(let v, let capabilities, let version):
            protocolVersion = v
            engineCapabilities = capabilities
            engineVersion = version
            helloReceived = true
            // A reconnect can land on a DIFFERENT engine than the one that
            // stranded these requests (that is the whole point of the restart
            // path), so clear the diagnoses and let the fresh engine be asked
            // again rather than inheriting the old one's verdicts.
            pendingHistory.removeAll()
            historyUnavailable.removeAll()
            historyMisses.removeAll()
            historyMissMs.removeAll()
            scheduleFollowUpSync()
        case .snapshot(let snap):
            applySnapshot(snap, nowMs: nowMs)
        case .tick(let t):
            lastTick[t.symbol] = t
            // Last-resort reference only (the D1 series wins when it can answer),
            // and day-keyed so it rolls over instead of reporting the change
            // since this process started.
            noteSessionOpen(t.symbol, t.price, nowMs: nowMs)
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
                chainError = nil
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
            applyFilings(report)
        case .history(let slice):
            // Match the answer to the question BEFORE looking at its contents:
            // a non-empty slice for an interval nobody asked for still leaves the
            // requested series unresolved, and that is precisely the failure this
            // diagnoses.
            resolveHistoryRequest(slice)
            guard !slice.bars.isEmpty else {
                // The engine answered "no data" (unresolvable ticker, failed
                // backfill, or an interval with no REST source). Remember the
                // miss PER interval so the on-demand path stops re-requesting —
                // and re-hitting Yahoo — while other intervals stay eligible.
                // Time-stamped so the block EXPIRES (see historyMissTtlMs): a
                // transient empty answer must not brick the series for the whole
                // session.
                let key = Self.historyMissKey(slice.symbol, slice.interval)
                historyMisses.insert(key)
                historyMissMs[key] = nowMs
                break
            }
            let key = Self.historyMissKey(slice.symbol, slice.interval)
            historyMisses.remove(key)
            historyMissMs[key] = nil
            let sorted = slice.bars.sorted { $0.ts_open_ms < $1.ts_open_ms }
            bars[slice.symbol, default: [:]][slice.interval] = sorted
            // No auto-switch: the requester (selectSymbol / setInterval) already
            // set selectedInterval to the interval it is waiting on, so the
            // merge above renders in place. Adopting whatever arrives would yank
            // the operator off their current pick when an earlier-requested
            // interval's response lands late (rapid interval switches), and let a
            // fixed grid pane's fetch flip the global interval.
            // Seed the last-resort reference from a REAL anchor (today's open,
            // else the prior day's close) — never from the newest close, which
            // is just the current price.
            noteSessionOpen(
                slice.symbol, Self.sessionReferenceSeed(sorted, nowMs: nowMs), nowMs: nowMs
            )
        case .gap(let dropped):
            // Under client lag the engine drops non-critical events and sends a
            // gap frame instead. Two things are lost, and BOTH must be handled:
            //
            //  1. An in-flight ask can never resolve — AiAnswer is non-critical,
            //     so its answer may be exactly what was dropped. Fail it now.
            //  2. Position and Account are non-critical too, so the portfolio
            //     view is now UNTRUSTED. See `staleAfterGap`: a dropped qty→0
            //     Position frame is never republished, so the app would have kept
            //     showing a phantom open position until the next reconnect. The
            //     engine explicitly told us data was lost — resync rather than
            //     keep rendering numbers we know may be wrong.
            failPendingAsk("answer lost — ask again")
            noteGap(dropped: dropped, nowMs: nowMs)
        case .error(let detail):
            // The engine REFUSED a command (or could not parse it). This used to
            // be folded into the gap case and discarded, so a rejected command
            // was indistinguishable from a dead control. Keep it visible.
            lastEngineError = EngineErrorNote(detail: detail, at: Date())
            failPendingAsk("engine rejected the request — \(detail)")
        case .unknown:
            break
        }
    }

    /// `nowMs` rides in from `apply` so the session-reference seeding below
    /// shares ONE clock with everything else a frame writes.
    private func applySnapshot(_ snap: EngineSnapshot, nowMs: Int64) {
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
        // MERGE the bar store, never replace it. The snapshot is NOT a superset
        // of what the client holds: it ships universe symbols D1-only and omits
        // ad-hoc LOOKUP tickers entirely, even though `get_history` already
        // wrote them into the engine's shared BarStore. Replacing wholesale
        // therefore destroyed every on-demand series — an operator's 5m AAPL
        // chart went empty the instant ANY later sync landed (the automatic
        // hello follow-up ~20s in, or a range-preset `ensureDepth` on a
        // completely different symbol), with no request in flight and the 30s
        // `lastHistoryMs` cooldown blocking a refetch. Only the (symbol,
        // interval) pairs the snapshot actually SUPPLIES are replaced. Empty
        // series are skipped for the same reason a lean snapshot must not wipe a
        // live broker posture: "absent from this payload" is not "gone".
        for (symbol, byInterval) in rebuilt {
            for (interval, series) in byInterval where !series.isEmpty {
                bars[symbol, default: [:]][interval] = series
            }
        }
        // Rebuild positions WHOLESALE (like orders/thoughts): a position closed
        // while we were disconnected is absent from the reconnect snapshot and
        // must vanish — merging would leave phantom exposure that could drive a
        // wrong manual flatten.
        positions = Dictionary(uniqueKeysWithValues: snap.positions.map { ($0.symbol, $0) })
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
        // Seed the last-resort reference from a real anchor, coarsest interval
        // first: a D1 series answers with today's OPEN (or yesterday's close),
        // which is what a change % actually means. Seeding from the newest
        // intraday close — what this did before — anchored the reference to
        // whatever price happened to be current at connect, so every crypto row
        // read "+0.00%" on a fresh connect and then drifted for days.
        for (symbol, byInterval) in rebuilt {
            var seed: Double?
            for interval in [Interval.d1, .h1, .m1] {
                seed = Self.sessionReferenceSeed(byInterval[interval] ?? [], nowMs: nowMs)
                if seed != nil { break }
            }
            noteSessionOpen(symbol, seed, nowMs: nowMs)
        }
        // This snapshot IS the rebuild a gap frame asked for: positions, account,
        // orders and risk were just replaced wholesale, so the portfolio view is
        // trustworthy again and the panels stop disclosing staleness.
        staleAfterGap = false
        droppedEventCount = 0
    }

    /// The engine dropped events under backpressure. Mark the portfolio view
    /// untrusted and rebuild it from a fresh snapshot.
    ///
    /// Rate-limited on the same `lastResyncMs` cooldown as every other deep
    /// sync: a lagging client receives gap frames in BURSTS, and answering each
    /// one with a full snapshot request would deepen the very backpressure that
    /// caused them. `lastResyncMs` is only stamped when the command actually
    /// reached the engine, so a sync lost on a dying socket does not silence the
    /// next gap. The flag stays raised either way — data was lost regardless of
    /// whether we managed to ask for a rebuild.
    private func noteGap(dropped: Int, nowMs: Int64) {
        staleAfterGap = true
        droppedEventCount += max(dropped, 0)
        guard nowMs - lastResyncMs >= Self.resyncCooldownMs else { return }
        guard send(.sync(barsPerSymbol: maxBars)) else { return }
        lastResyncMs = nowMs
    }

    /// File a `filings` answer against the request it actually answers.
    ///
    /// The engine spawns one task per `get_filings` with no ordering guarantee
    /// and echoes back only the query string, so query equality alone cannot
    /// distinguish the desk's bare `onAppear` pull for AAPL from the operator's
    /// keyword search for the SAME entity. It used to accept both, which meant a
    /// slow 200-row unfiltered submissions answer silently replaced the keyword
    /// results being read — spinner already down, no signal at all. A report is
    /// now attributed to the newest outstanding request it could plausibly have
    /// come from, and accepted ONLY when that is the latest request — the same
    /// identity the watchdog uses.
    private func applyFilings(_ report: FilingsReport) {
        // `source` says which EDGAR endpoint answered, which is decided by
        // whether the request carried keywords — so prefer a candidate whose
        // expectation matches it. The fallback pass is what allows a keyword
        // request that DEGRADED to the submissions list (efts unreachable, or an
        // unresolvable entity — the engine discloses both in `note`) to still be
        // accepted, while a same-query bare request outstanding at the same time
        // wins the attribution and correctly rejects the stale answer.
        let fullText = Self.isFullTextReport(report.source)
        let candidates = outstandingFilings.filter { $0.query == report.query }
        // Nothing outstanding can explain this report (its request already timed
        // out, or it arrived unsolicited): leave every piece of state alone.
        guard let matched = candidates.last(where: { $0.wantsFullText == fullText })
            ?? candidates.last else { return }
        guard matched.seq == filingsRequestSeq else {
            // Superseded: drop the identity so it can never shadow the
            // attribution of a later answer, and leave the spinner up for the
            // request still in flight.
            outstandingFilings.removeAll { $0.seq == matched.seq }
            return
        }
        // Every older request is now unreachable — its answer could only
        // overwrite this newer one.
        outstandingFilings.removeAll { $0.seq <= matched.seq }
        filingsReport = report
        filingsLoading = false
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

// MARK: - Market frame coalescer (pure)

/// Buffers the high-frequency market frames so the UI commits them at display
/// rate instead of feed rate. It keeps the LATEST tick/book_top per symbol, the
/// latest depth/flow, the latest FORMING bar per (symbol, interval), and the
/// batch of tape prints in arrival order; `drain` hands the whole batch back as
/// an ordered apply list. Completed bars and every low-frequency frame are NOT
/// buffered — `ingest` reports them as pass-through so the caller applies them
/// at once. Value type, Foundation-only, no observation — unit-tested in
/// isolation. Correctness rule: draining and applying the batch produces the
/// same state the un-buffered path would, only less often.
struct MarketCoalescer {
    /// Identity of a bar series — a forming bar coalesces within its own series.
    struct FormingKey: Hashable {
        var symbol: String
        var interval: Interval
    }

    private var ticks: [String: Tick] = [:]
    private var bookTops: [String: BookTop] = [:]
    /// Latest depth / flow keyed BY SYMBOL (not a single slot): the engine
    /// streams one book at a time, but a late in-flight frame from a just-
    /// unsubscribed symbol can briefly overlap the subscribed one in a window.
    /// Keying by symbol means such a straggler can never displace the valid
    /// book — `apply`'s subscription guard then keeps only the subscribed one,
    /// exactly as the un-buffered path did.
    private var depths: [String: BookDepth] = [:]
    private var flows: [String: FlowRead] = [:]
    private var tapeBatch: [TapePrint] = []
    private var formingBars: [FormingKey: Bar] = [:]
    /// Mark-to-market snapshots the engine can emit at feed rate (~40 Hz): the
    /// latest account (single slot) and the latest position per symbol. Buffering
    /// them caps TopBar / AccountStrip / PositionsTable re-layout at the display
    /// rate instead of raw feed rate. Discrete events (.fill / .orderUpdate) are
    /// NOT buffered — they must apply immediately and can never be coalesced away.
    private var accountSnap: AccountSnapshot?
    private var positionSnaps: [String: Position] = [:]

    /// Whether anything is buffered — lets the flush skip an empty drain.
    var hasPending: Bool {
        !ticks.isEmpty || !bookTops.isEmpty || !depths.isEmpty || !flows.isEmpty
            || !tapeBatch.isEmpty || !formingBars.isEmpty
            || accountSnap != nil || !positionSnaps.isEmpty
    }

    /// Buffer `frame` for the display-rate flush, returning whether it was
    /// buffered. High-frequency market frames buffer (true); a COMPLETED bar
    /// and every other (low-frequency / interaction-critical) frame return
    /// false so the caller applies them immediately. A completed bar also drops
    /// any superseded forming bar for its series (open at or before it) so a
    /// stale forming frame can never flush over the just-closed bar.
    mutating func ingest(_ frame: ServerFrame) -> Bool {
        switch frame {
        case .tick(let t):
            ticks[t.symbol] = t
            return true
        case .bookTop(let b):
            bookTops[b.symbol] = b
            return true
        case .depth(let d):
            depths[d.symbol] = d
            return true
        case .flow(let f):
            flows[f.symbol] = f
            return true
        case .tape(let p):
            tapeBatch.append(p)
            return true
        case .bar(let bar):
            let key = FormingKey(symbol: bar.symbol, interval: bar.interval)
            if bar.complete {
                if let buffered = formingBars[key], buffered.ts_open_ms <= bar.ts_open_ms {
                    formingBars[key] = nil
                }
                return false
            }
            formingBars[key] = bar
            return true
        case .account(let a):
            accountSnap = a
            return true
        case .position(let p):
            positionSnaps[p.symbol] = p
            return true
        default:
            return false
        }
    }

    /// The buffered frames as an ordered apply list, then reset. Order is
    /// irrelevant to correctness (the categories are independent, and superseded
    /// forming bars were already dropped at ingest): forming bars lead, and the
    /// tape trails in ARRIVAL order so the newest-first insertion in `apply`
    /// still yields a chronological tape.
    mutating func drain() -> [ServerFrame] {
        guard hasPending else { return [] }
        var frames: [ServerFrame] = []
        frames.reserveCapacity(
            formingBars.count + ticks.count + bookTops.count
                + depths.count + flows.count + tapeBatch.count
                + positionSnaps.count + (accountSnap == nil ? 0 : 1)
        )
        for bar in formingBars.values { frames.append(.bar(bar)) }
        for t in ticks.values { frames.append(.tick(t)) }
        for b in bookTops.values { frames.append(.bookTop(b)) }
        for d in depths.values { frames.append(.depth(d)) }
        for f in flows.values { frames.append(.flow(f)) }
        for p in tapeBatch { frames.append(.tape(p)) }
        for p in positionSnaps.values { frames.append(.position(p)) }
        // Account last so it reflects the freshest marks in the same flush.
        if let a = accountSnap { frames.append(.account(a)) }
        clear()
        return frames
    }

    /// Discard every buffered frame (e.g. on disconnect) without applying.
    mutating func clear() {
        ticks.removeAll(keepingCapacity: true)
        bookTops.removeAll(keepingCapacity: true)
        depths.removeAll(keepingCapacity: true)
        flows.removeAll(keepingCapacity: true)
        tapeBatch.removeAll(keepingCapacity: true)
        formingBars.removeAll(keepingCapacity: true)
        accountSnap = nil
        positionSnaps.removeAll(keepingCapacity: true)
    }
}
