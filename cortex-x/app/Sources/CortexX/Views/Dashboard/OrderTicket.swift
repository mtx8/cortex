// DAS-class order ticket: a live bid/ask/last quote row (click to price),
// MKT/LMT/STOP/STOP-LMT types with tick-stepped price fields, three sizing
// modes (shares · dollars · % of buying power), a live risk readout
// (notional, % of equity, risk/share + R:R once a stop is set), prominent
// buy/sell plus flatten/reverse, and DAS-style hotkeys. All math lives in the
// pure helpers (OrderTicketSupport); everything routes through
// model.placeOrder(...). Paper only. Kill switch replaces buy/sell entirely.

import SwiftUI

struct OrderTicket: View {
    @Environment(AppModel.self) private var model

    /// Non-nil once the operator picks a symbol by hand; nil = follow the chart.
    @State private var symbolOverride: String?
    @State private var side: Side = .buy
    @State private var orderType: OrderType = .market
    @State private var sizingMode: SizingMode = .shares
    @State private var qtyText = ""
    @State private var dollarText = ""
    @State private var pctSelected: Double?
    @State private var limitText = ""
    @State private var stopText = ""
    @State private var showHelp = false
    /// Non-nil while a real-money action is awaiting its explicit confirmation —
    /// an entry (BUY/SELL) OR a position unwind (FLATTEN/REVERSE). Every path to
    /// a live broker funnels through here so no real-money order fires unconfirmed.
    @State private var pendingLive: PendingLiveOrder?
    @FocusState private var focus: TicketFocus?

    /// A real-money action staged for one explicit confirmation before it fires
    /// at a connected LIVE broker. Paper / IBKR-paper never stages — it dispatches
    /// immediately, so the common path is untouched.
    private enum PendingLiveOrder: Equatable {
        case entry(Side)
        case flatten
        case reverse
        var label: String {
            switch self {
            case .entry(let s): "Send \(s == .buy ? "BUY" : "SELL") — real money"
            case .flatten: "FLATTEN position — real money"
            case .reverse: "REVERSE position — real money"
            }
        }
    }

    /// SETTINGS ▸ PREFERENCES: require an explicit confirmation before any order
    /// that would route to a LIVE broker account. On by default — a real-money
    /// backstop the operator can lower deliberately.
    @AppStorage("ticket.confirmBeforeLiveOrder") private var confirmBeforeLiveOrder = true

    /// SHARES = raw count · DOLLARS = $ ÷ price · PERCENT = chip of buying power.
    enum SizingMode: String, CaseIterable, Identifiable {
        case shares, dollars, percent
        var id: String { rawValue }
        var title: String {
            switch self {
            case .shares: "Shares"
            case .dollars: "$"
            case .percent: "%"
            }
        }
    }

    /// One focus target at a time: the area (hotkeys live) or a specific field.
    enum TicketFocus: Hashable { case area, qty, dollars, limit, stop }

    private static let dollarIncrement: Double = 100

    // MARK: Derived

    private var symbol: String { symbolOverride ?? model.selectedSymbol }

    private var symbolChoices: [String] {
        var list = model.symbols
        if list.isEmpty { list = [model.selectedSymbol] }
        if let s = symbolOverride, !list.contains(s) { list.append(s) }
        return list
    }

    private var whole: Bool { AppModel.isEquity(symbol) }
    private var increment: Double { OrderSizing.defaultIncrement(whole: whole) }

    /// The non-market half of the ticket — typed text, armed side, order type,
    /// sizing mode — bundled into one value so the live-data leaf views can do
    /// the whole size/risk computation themselves. This is what keeps live quote
    /// and account reads OUT of this view's body (see the note on `body`).
    private var form: TicketForm {
        TicketForm(
            symbol: symbol,
            side: side,
            orderType: orderType,
            sizingMode: sizingMode,
            qtyText: qtyText,
            dollarText: dollarText,
            pctSelected: pctSelected,
            limitText: limitText,
            stopText: stopText
        )
    }

    private var usesLimit: Bool { form.usesLimit }
    private var usesStop: Bool { form.usesStop }

    private var limitPx: Double? { form.limitPx }
    private var stopPx: Double? { form.stopPx }

    // MARK: Live market reads — ACTION PATHS ONLY
    //
    // `lastTick`, `bookTop` and `account` are single stored properties on the
    // @Observable AppModel and are republished on every ~12 Hz coalescer flush,
    // for ANY symbol. Reading one inside this view's body (or any property the
    // body composes) therefore re-lays-out the ENTIRE ticket twelve times a
    // second — text fields, hotkey handler and all. These accessors are read
    // only from actions (clicks, key presses, seeding), which run outside the
    // body's observation-tracking scope; the views that DISPLAY live data read
    // it themselves in their own small bodies.

    private var price: Double? { model.lastPrice(symbol) }
    private var book: BookTop? { model.bookTop[symbol] }

    /// The share count the current sizing mode resolves to, at the working
    /// price. nil when the mode's inputs are incomplete or price is missing.
    private var effectiveQty: Double? {
        form.qty(price: price, buyingPower: model.buyingPower)
    }

    /// The open position on this symbol (nil when flat) — flatten/reverse gate.
    private var position: Position? {
        guard let p = model.positions[symbol],
            abs(p.qty) > PositionAction.flatEpsilon else { return nil }
        return p
    }

    private var canSubmit: Bool {
        form.canSubmit(
            price: price,
            buyingPower: model.buyingPower,
            connected: model.connection == .connected,
            killSwitch: model.risk.kill_switch
        )
    }

    // MARK: Body

    var body: some View {
        // Densified so the full ticket — quote, order type, sizing, buy/sell,
        // flatten/reverse — is visible at a glance inside the 280pt deck with
        // no scrolling. The symbol picker rides in the header; the quote and
        // the size/risk readout are each a single compact line; price fields
        // stay hidden for MKT.
        //
        // PERF INVARIANT: this body reads NO live market or account state. The
        // ticket is mounted whenever the bottom deck is open, so when it read
        // `lastPrice` / `bookTop` / `account` directly, every ~12 Hz flush — for
        // any symbol, in any workspace — re-laid-out all nine sections, fought
        // with typing in the limit field and reinstalled the key handler. The
        // four sections that need live data own their reads in their own leaf
        // views instead, the same split as `LivePriceText` in the chart header
        // and `AccountVitals` in the top bar: a tick invalidates only the leaf.
        VStack(alignment: .leading, spacing: 6) {
            header
            TicketQuoteRow(
                symbol: symbol,
                onBid: { aggress(side: .sell, at: $0) },
                onAsk: { aggress(side: .buy, at: $0) }
            )
            typeSegment
            priceFields
            sizeModeRow
            sizingInput
            TicketReadoutLine(form: form)
            TicketSubmitControls(form: form, onSubmit: submit)
            TicketPositionActions(
                symbol: symbol,
                onFlatten: flatten,
                onReverse: reverse
            )
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .strokeBorder(
                    focus == .area ? Theme.ember.opacity(0.55) : Color.clear,
                    lineWidth: Theme.hairline
                )
        )
        .focusable()
        .focused($focus, equals: .area)
        .onKeyPress(.return) { submitArmed(); return .handled }
        .onKeyPress(.escape) { clearSize(); return .handled }
        .onKeyPress(characters: Self.hotkeyChars) { handleChar($0) }
        .animation(DeckMotion.ease(), value: focus)
        .onChange(of: orderType) { _, _ in seedPricesIfNeeded() }
        .onChange(of: model.selectedSymbol) { _, _ in
            // New instrument → drop the previous symbol's literal limit/stop
            // prices BEFORE reseeding, so a $190 equity's stop can never be
            // submitted against a $43k crypto.
            if symbolOverride == nil { resetPricesForNewSymbol() }
        }
        // The LEVEL 2 depth-ladder click seam: a price the operator clicked in
        // the montage lands in `model.pendingTicketPrice`; seat it into the
        // limit field here, then release it. `onChange` covers a click made
        // while the deck is open; `onAppear` drains a price parked while the
        // deck was collapsed (onChange never fires for a value set pre-mount).
        .onChange(of: model.pendingTicketPrice) { _, px in seatLadderPrice(px) }
        .onAppear { seatLadderPrice(model.pendingTicketPrice) }
        .confirmationDialog(
            "Place a LIVE order?",
            isPresented: Binding(
                get: { pendingLive != nil },
                set: { if !$0 { pendingLive = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingLive
        ) { action in
            Button(action.label, role: .destructive) {
                switch action {
                case .entry(let s): dispatch(s)
                case .flatten: performFlatten()
                case .reverse: performReverse()
                }
                pendingLive = nil
            }
            Button("Cancel", role: .cancel) { pendingLive = nil }
        } message: { _ in
            Text("This routes to your live broker account. Real money — orders execute at your broker.")
        }
    }

    // MARK: Header

    // Header carries the section stamp, the symbol picker (moved up from its
    // own row to save vertical space), and the hotkey help.
    private var header: some View {
        HStack(spacing: 8) {
            SectionLabel(text: "ticket")
            symbolMenu
            helpButton
        }
        .contentShape(Rectangle())
        .onTapGesture { focus = .area }
    }

    private var helpButton: some View {
        Button { showHelp.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(focus == .area ? Theme.ember : Theme.dim)
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("keyboard shortcuts")
        .popover(isPresented: $showHelp, arrowEdge: .bottom) { hotkeyLegend }
    }

    private var hotkeyLegend: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "hotkeys")
            legendRow("B", "arm & focus buy")
            legendRow("S", "arm & focus sell")
            legendRow("return", "submit armed side")
            legendRow("esc", "clear size")
            legendRow("+ / −", "adjust size")
            Rectangle().fill(Theme.line).frame(height: Theme.hairline).padding(.vertical, 2)
            legendRow("click bid", "sell the bid (limit)")
            legendRow("click ask", "buy the ask (limit)")
            Text("keys fire while the ticket is focused (ember ring)")
                .font(.system(size: 9))
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: 220, alignment: .leading)
                .padding(.top, 2)
        }
        .padding(12)
        .background(Theme.panel)
    }

    private func legendRow(_ key: String, _ desc: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.bone)
                .frame(width: 56, alignment: .leading)
            Text(desc)
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
        }
    }

    private var symbolMenu: some View {
        Menu {
            ForEach(symbolChoices, id: \.self) { s in
                Button(s) { select(s) }
            }
        } label: {
            HStack(spacing: 5) {
                Text(symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.bone)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Theme.ink)
            .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.chipRadius)
                    .strokeBorder(Theme.line, lineWidth: Theme.hairline)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
    }

    // MARK: Order type

    private var typeSegment: some View {
        HStack(spacing: 4) {
            DeckSegment(title: "MKT", isOn: orderType == .market) { setType(.market) }
            DeckSegment(title: "LMT", isOn: orderType == .limit) { setType(.limit) }
            DeckSegment(title: "STOP", isOn: orderType == .stop) { setType(.stop) }
            DeckSegment(title: "STP LMT", isOn: orderType == .stop_limit) { setType(.stop_limit) }
        }
    }

    // MARK: Price fields

    @ViewBuilder
    private var priceFields: some View {
        if usesLimit {
            priceField("limit", text: $limitText, focusTag: .limit,
                       invalid: !limitText.isEmpty && limitPx == nil)
        }
        if usesStop {
            priceField("stop", text: $stopText, focusTag: .stop,
                       invalid: !stopText.isEmpty && stopPx == nil)
        }
    }

    private func priceField(
        _ label: String, text: Binding<String>, focusTag: TicketFocus, invalid: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.dim)
                .frame(width: 34, alignment: .leading)
            TextField("0", text: text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.bone)
                .focused($focus, equals: focusTag)
                .onSubmit { submitArmed() }
            stepButton(system: "minus") { stepPrice(text, ticks: -1) }
            stepButton(system: "plus") { stepPrice(text, ticks: 1) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.ink)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(invalid ? Theme.down.opacity(0.6) : Theme.line, lineWidth: Theme.hairline)
        )
    }

    private func stepButton(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.dim)
                .frame(width: 18, height: 18)
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Theme.line, lineWidth: Theme.hairline)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Sizing — mode segments and the active input on their own compact
    // lines; the resolved share count is folded into the readout line below.

    private var sizeModeRow: some View {
        HStack(spacing: 4) {
            ForEach(SizingMode.allCases) { mode in
                DeckSegment(title: mode.title, isOn: sizingMode == mode) {
                    sizingMode = mode
                }
            }
        }
    }

    @ViewBuilder
    private var sizingInput: some View {
        switch sizingMode {
        case .shares:
            HStack(spacing: 6) {
                Text("qty")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.dim)
                    .frame(width: 34, alignment: .leading)
                TextField("0", text: $qtyText)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(qtyInvalid ? Theme.down : Theme.bone)
                    .focused($focus, equals: .qty)
                    .onSubmit { submitArmed() }
                stepButton(system: "minus") { stepQty(-1) }
                stepButton(system: "plus") { stepQty(1) }
            }
            .fieldChrome(invalid: qtyInvalid)
        case .dollars:
            HStack(spacing: 6) {
                Text("$")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.dim)
                    .frame(width: 34, alignment: .leading)
                TextField("0", text: $dollarText)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.bone)
                    .focused($focus, equals: .dollars)
                    .onSubmit { submitArmed() }
                stepButton(system: "minus") { stepDollar(-1) }
                stepButton(system: "plus") { stepDollar(1) }
            }
            .fieldChrome(invalid: false)
        case .percent:
            HStack(spacing: 4) {
                ForEach(OrderSizing.percentChips, id: \.self) { f in
                    percentChip(f)
                }
            }
        }
    }

    private var qtyInvalid: Bool {
        sizingMode == .shares && !qtyText.isEmpty && Self.parse(qtyText) == nil
    }

    private func percentChip(_ fraction: Double) -> some View {
        let on = pctSelected == fraction
        return Button {
            pctSelected = fraction
            focus = .area
        } label: {
            Text("\(Int(fraction * 100))%")
                .font(.system(size: 11, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.bone : Theme.dim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(on ? Theme.panelHi : Theme.ink)
                .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.chipRadius)
                        .strokeBorder(Theme.line, lineWidth: Theme.hairline)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(Int(fraction * 100))% of buying power")
    }

    // MARK: Actions

    private func select(_ s: String) {
        // Picking a symbol in the ticket drives the GLOBAL selection, so the
        // chart (pane 0 in multi-chart view) and the rest of the workspace load
        // it too — the ticket and the chart stay on the same instrument. This is
        // the same path a watchlist tap takes (history fetch included). The local
        // override is cleared so the ticket simply follows the selection it set.
        symbolOverride = nil
        model.selectSymbol(s)
        resetPricesForNewSymbol()
    }

    /// Drop the previous instrument's literal limit/stop prices, then reseed from
    /// the new symbol's book — a stale price from a different instrument must
    /// never survive a symbol switch. Sizing ($/%) recomputes off the live price
    /// via `effectiveQty`, so it is left intact.
    private func resetPricesForNewSymbol() {
        limitText = ""
        stopText = ""
        seedPricesIfNeeded()
    }

    private func setType(_ t: OrderType) {
        orderType = t
        seedPricesIfNeeded()
    }

    /// Seed empty limit/stop fields from the book/last so the price appears the
    /// moment a price-bearing type is chosen (the operator then steps it).
    private func seedPricesIfNeeded() {
        if usesLimit, limitText.isEmpty {
            let seed = side == .buy ? (book?.ask_px ?? price) : (book?.bid_px ?? price)
            if let s = seed, s.isFinite, s > 0 { limitText = DashFormat.editable(s) }
        }
        if usesStop, stopText.isEmpty, let p = price {
            stopText = DashFormat.editable(p)
        }
    }

    /// "Buy the ask / sell the bid": arm the aggressive side, switch to a
    /// limit if not already price-bearing, and seat the limit at that level.
    private func aggress(side newSide: Side, at level: Double?) {
        guard let level, level.isFinite, level > 0 else { return }
        side = newSide
        if !usesLimit { orderType = .limit }
        limitText = DashFormat.editable(level)
        focus = .qty
    }

    /// Consume a price the operator clicked in the LEVEL 2 depth ladder (offered
    /// via `model.pendingTicketPrice`): make the limit field visible by
    /// switching to a price-bearing type if the ticket is on MKT, seat the
    /// price, focus the size field, then release the pending value so one click
    /// applies exactly once. The ladder gives no side, so — unlike `aggress` —
    /// the armed side is left as-is. nil / non-finite / non-positive is a no-op.
    private func seatLadderPrice(_ px: Double?) {
        guard let px, px.isFinite, px > 0 else { return }
        if !usesLimit { orderType = .limit }
        limitText = DashFormat.editable(px)
        focus = .qty
        model.clearTicketPrice()
    }

    private func stepQty(_ dir: Int) {
        let cur = Self.parse(qtyText) ?? 0
        let next = max(cur + Double(dir) * increment, 0)
        qtyText = next > 0 ? DashFormat.qty(next) : ""
    }

    private func stepDollar(_ dir: Int) {
        let cur = Self.parse(dollarText) ?? 0
        let next = max(cur + Double(dir) * Self.dollarIncrement, 0)
        dollarText = next > 0 ? String(format: "%.0f", next) : ""
    }

    private func stepPrice(_ text: Binding<String>, ticks: Int) {
        let current = Self.parse(text.wrappedValue) ?? price ?? 0
        let tick = PriceTick.size(for: current)
        let next = PriceTick.step(price: current, ticks: ticks, tickSize: tick)
        text.wrappedValue = DashFormat.editable(next)
    }

    /// The one +/- entry point — steps whichever sizing mode is active.
    private func bumpSize(_ dir: Int) {
        switch sizingMode {
        case .shares: stepQty(dir)
        case .dollars: stepDollar(dir)
        case .percent:
            let chips = OrderSizing.percentChips
            let idx = pctSelected.flatMap { chips.firstIndex(of: $0) } ?? -1
            let next = min(max(idx + dir, 0), chips.count - 1)
            pctSelected = chips[next]
        }
    }

    /// True when the ticket routes to a connected LIVE broker account. Reuses
    /// the shared BrokerBadge mapping so "live" here means exactly what the
    /// TopBar badge and venue tag mean — nothing decides "live" twice.
    private var isLiveVenue: Bool { TicketVenueTag.make(for: model.broker).isLive }

    private func submit(_ s: Side) {
        side = s
        guard canSubmit, effectiveQty != nil else { return }
        // A real-money venue gets one explicit confirmation before it fires
        // (unless the operator lowered that backstop in SETTINGS). Paper and
        // IBKR-paper dispatch immediately — the common path is untouched.
        if LiveOrderConfirm.required(isLiveVenue: isLiveVenue, confirmBeforeLive: confirmBeforeLiveOrder) {
            pendingLive = .entry(s)
            return
        }
        dispatch(s)
    }

    /// Whether a real-money action must be confirmed before it fires.
    private var mustConfirmLive: Bool {
        LiveOrderConfirm.required(isLiveVenue: isLiveVenue, confirmBeforeLive: confirmBeforeLiveOrder)
    }

    /// The final send — after any live confirmation. Re-checks the gate so a
    /// confirmation that lingered past a kill switch / disconnect can't fire.
    private func dispatch(_ s: Side) {
        guard canSubmit, let qty = effectiveQty else { return }
        model.placeOrder(
            symbol: symbol, side: s, qty: qty, type: orderType,
            limitPx: usesLimit ? limitPx : nil,
            stopPx: usesStop ? stopPx : nil
        )
        clearSize()
    }

    private func submitArmed() { submit(side) }

    /// FLATTEN: close the position at market. A live venue confirms first (a
    /// real-money order must never fire unconfirmed); closing is allowed even
    /// under a kill switch (reducing risk is always desirable).
    private func flatten() {
        guard position != nil else { return }
        if mustConfirmLive { pendingLive = .flatten; return }
        performFlatten()
    }

    private func performFlatten() {
        guard let p = position, let a = PositionAction.flatten(positionQty: p.qty) else { return }
        model.placeOrder(
            symbol: p.symbol, side: a.side, qty: a.qty, type: .market,
            limitPx: nil, stopPx: nil
        )
    }

    /// REVERSE: flip to a 2×|qty| opposite position at market. Blocked under a
    /// kill switch (it OPENS a larger position — the opposite of a halt) and
    /// confirmed first on a live venue.
    private func reverse() {
        guard position != nil, !model.risk.kill_switch else { return }
        if mustConfirmLive { pendingLive = .reverse; return }
        performReverse()
    }

    private func performReverse() {
        guard !model.risk.kill_switch,
            let p = position, let a = PositionAction.reverse(positionQty: p.qty) else { return }
        model.placeOrder(
            symbol: p.symbol, side: a.side, qty: a.qty, type: .market,
            limitPx: nil, stopPx: nil
        )
    }

    private func clearSize() {
        qtyText = ""
        dollarText = ""
        pctSelected = nil
        focus = .area
    }

    // MARK: Hotkeys

    private static let hotkeyChars = CharacterSet(charactersIn: "bBsS+=-_")

    private func handleChar(_ press: KeyPress) -> KeyPress.Result {
        switch press.characters.lowercased() {
        case "b": side = .buy; focus = .qty; return .handled
        case "s": side = .sell; focus = .qty; return .handled
        case "+", "=": bumpSize(1); return .handled
        case "-", "_": bumpSize(-1); return .handled
        default: return .ignored
        }
    }

    /// One parser for every numeric field — shared with the leaf views through
    /// `TicketForm` so the ticket and its readout can never disagree about what
    /// a typed string means.
    private static func parse(_ text: String) -> Double? { TicketForm.parse(text) }
}

// MARK: - Ticket form (the non-market half of the ticket)

/// Everything the ticket's size/risk math needs that is NOT live market data.
/// Held as one plain value so the live-reading leaf views below can compute the
/// numbers they display from `(form, price, buyingPower, equity)` themselves —
/// which is what keeps `lastPrice` / `bookTop` / `account` out of the parent's
/// body, where a single read costs a full ticket re-layout on every ~12 Hz
/// market flush. Pure, so every rule here is unit-tested without a live model.
///
/// @MainActor only because `whole` asks `AppModel.isEquity` (the single source of
/// truth for the equity-vs-crypto sizing rule) and AppModel is main-actor —
/// exactly the isolation this math already had while it lived inside the view.
@MainActor
struct TicketForm {
    var symbol: String
    var side: Side
    var orderType: OrderType
    var sizingMode: OrderTicket.SizingMode
    var qtyText: String
    var dollarText: String
    var pctSelected: Double?
    var limitText: String
    var stopText: String

    /// Equities size in whole shares; crypto stays fractional.
    var whole: Bool { AppModel.isEquity(symbol) }
    var usesLimit: Bool { orderType == .limit || orderType == .stop_limit }
    var usesStop: Bool { orderType == .stop || orderType == .stop_limit }
    var limitPx: Double? { TicketForm.parse(limitText) }
    var stopPx: Double? { TicketForm.parse(stopText) }

    /// The share count the active sizing mode resolves to at `price`. nil when
    /// the mode's inputs are incomplete or the price is missing.
    func qty(price: Double?, buyingPower: Double) -> Double? {
        switch sizingMode {
        case .shares:
            // Floor equities to whole shares (crypto stays fractional) — same
            // rule the $/% modes apply, so a typed "10.7" can't submit 10.7 AAPL.
            return OrderSizing.normalize(shares: TicketForm.parse(qtyText), whole: whole)
        case .dollars:
            guard let d = TicketForm.parse(dollarText), let p = price else { return nil }
            return OrderSizing.shares(dollars: d, price: p, whole: whole)
        case .percent:
            guard let f = pctSelected, let p = price else { return nil }
            return OrderSizing.sharesFromBuyingPower(
                fraction: f, buyingPower: buyingPower, price: p, whole: whole
            )
        }
    }

    /// The price the order works at — for notional and the fill reference.
    func workingPrice(_ price: Double?) -> Double? {
        if usesLimit, let l = limitPx { return l }
        if orderType == .stop, let s = stopPx { return s }
        return price
    }

    func notional(price: Double?, buyingPower: Double) -> Double? {
        guard let q = qty(price: price, buyingPower: buyingPower),
            let p = workingPrice(price) else { return nil }
        return OrderSizing.notional(qty: q, price: p)
    }

    func equityFraction(price: Double?, buyingPower: Double, equity: Double) -> Double? {
        guard let n = notional(price: price, buyingPower: buyingPower) else { return nil }
        return OrderSizing.fractionOfEquity(notional: n, equity: equity)
    }

    /// Signed loss/share from the current market to the protective stop.
    func riskPerShare(price: Double?) -> Double? {
        guard usesStop, let s = stopPx, let p = price else { return nil }
        return OrderRisk.riskPerShare(side: side, entry: p, stop: s)
    }

    func totalRisk(price: Double?, buyingPower: Double) -> Double? {
        guard let rps = riskPerShare(price: price),
            let q = qty(price: price, buyingPower: buyingPower) else { return nil }
        return abs(rps) * q
    }

    /// Reward:risk once a stop-limit sets both a stop and a target limit,
    /// measured from where the market is now.
    func rewardRisk(price: Double?) -> Double? {
        guard orderType == .stop_limit,
            let s = stopPx, let t = limitPx, let p = price else { return nil }
        return OrderRisk.rr(side: side, entry: p, stop: s, target: t)
    }

    func isValid(price: Double?, buyingPower: Double) -> Bool {
        guard let q = qty(price: price, buyingPower: buyingPower), q > 0 else { return false }
        if usesLimit && limitPx == nil { return false }
        if usesStop && stopPx == nil { return false }
        return true
    }

    /// The full submit gate: a resolvable size, a live link, and no halt.
    func canSubmit(
        price: Double?, buyingPower: Double, connected: Bool, killSwitch: Bool
    ) -> Bool {
        isValid(price: price, buyingPower: buyingPower) && connected && !killSwitch
    }

    /// Numeric field parser: strips grouping commas, rejects blanks, non-numbers,
    /// non-finite values and anything <= 0 (a price or size of zero is not an
    /// order). Shared by the ticket and every leaf so there is one meaning.
    static func parse(_ text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let v = Double(cleaned), v.isFinite, v > 0 else { return nil }
        return v
    }
}

// MARK: - Live-data leaves
//
// Each of these owns its OWN AppModel read of the ~12 Hz market/account state it
// displays, so a tick invalidates only that leaf instead of the whole ticket.
// Same technique as `LivePriceText` (Chart/ChartPanel.swift) and `AccountVitals`
// (Shell/TopBar.swift). Callbacks hand interaction back to the ticket, which
// owns the focus and text state.

/// One compact line: bid · last · ask · spread. Bid/ask stay click-to-price
/// ("sell the bid" / "buy the ask"); the level the operator clicked is handed up
/// so the ticket arms the aggressive side and seats the limit.
private struct TicketQuoteRow: View {
    @Environment(AppModel.self) private var model
    let symbol: String
    let onBid: (Double?) -> Void
    let onAsk: (Double?) -> Void

    var body: some View {
        let book = model.bookTop[symbol]
        let last = model.lastPrice(symbol)
        HStack(spacing: 5) {
            quoteCell(label: "bid", px: book?.bid_px, tint: Theme.up) { onBid(book?.bid_px) }
            quoteCell(label: "last", px: last, tint: Theme.bone, action: nil)
            quoteCell(label: "ask", px: book?.ask_px, tint: Theme.down) { onAsk(book?.ask_px) }
            spreadCell(book)
        }
    }

    private func quoteCell(
        label: String, px: Double?, tint: Color, action: (() -> Void)?
    ) -> some View {
        let content = VStack(spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 7, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.dim)
            Text(px.map { DashFormat.price($0) } ?? "—")
                .numeric(size: 11, weight: .semibold)
                .foregroundStyle(px == nil ? Theme.dim : tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(Theme.ink)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(Theme.line, lineWidth: Theme.hairline)
        )

        return Group {
            if let action {
                Button(action: action) { content.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .help(label == "bid" ? "sell the bid" : "buy the ask")
            } else {
                content
            }
        }
    }

    /// Crossed / non-finite / non-positive books show "—" rather than a
    /// nonsense negative spread.
    private func spread(_ book: BookTop?) -> Double? {
        guard let b = book, b.ask_px.isFinite, b.bid_px.isFinite,
            b.ask_px > 0, b.bid_px > 0, b.ask_px >= b.bid_px else { return nil }
        return b.ask_px - b.bid_px
    }

    private func spreadCell(_ book: BookTop?) -> some View {
        VStack(spacing: 1) {
            Text("SPR")
                .font(.system(size: 7, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.dim)
            Text(spread(book).map { DashFormat.price($0) } ?? "—")
                .numeric(size: 11)
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(width: 54)
        .padding(.vertical, 4)
        .help("bid/ask spread")
    }
}

/// Risk / size readout — one compact line: resolved shares, notional, % of
/// equity (ember dot when concentrated), and — once a stop is set — total risk
/// and reward:risk. Reads price + account itself; all formatting/gating stays in
/// the pure `TicketReadout` helper.
private struct TicketReadoutLine: View {
    @Environment(AppModel.self) private var model
    let form: TicketForm

    var body: some View {
        let price = model.lastPrice(form.symbol)
        let bp = model.buyingPower
        let qty = form.qty(price: price, buyingPower: bp)
        let r = TicketReadout.make(
            qty: qty,
            notional: form.notional(price: price, buyingPower: bp),
            equityFraction: form.equityFraction(
                price: price, buyingPower: bp, equity: model.account.equity
            ),
            totalRisk: form.totalRisk(price: price, buyingPower: bp),
            rewardRisk: form.rewardRisk(price: price)
        )
        HStack(spacing: 6) {
            readoutSeg("=", r.shares, qty == nil ? Theme.dim : Theme.bone)
            readoutSeg("notl", r.notional, Theme.dim)
            readoutSeg("eq", r.equityPct, r.concentrated ? Theme.bone : Theme.dim, warn: r.concentrated)
            if let risk = r.risk { readoutSeg("risk", risk, Theme.dim) }
            if let rr = r.rewardRisk { readoutSeg("r:r", rr, Theme.dim) }
            Spacer(minLength: 0)
        }
        .help(r.concentrated
            ? "size is large — over \(DashFormat.pct(OrderSizing.warnFractionOfEquity, decimals: 0)) of equity"
            : "size · notional · % of equity · risk to stop · reward:risk")
    }

    private func readoutSeg(
        _ label: String, _ value: String, _ color: Color, warn: Bool = false
    ) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.dim)
            if warn { Circle().fill(Theme.ember).frame(width: 4, height: 4) }
            Text(value)
                .numeric(size: 10, weight: .medium)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

/// Venue tag + BUY/SELL, or the kill-switch notice in their place. Owns the
/// submit-gate read (price / buying power / link / halt) so the enabled state
/// stays exact — a directional button that cannot fire must not look armed —
/// without that read costing the whole ticket a re-layout on every tick.
private struct TicketSubmitControls: View {
    @Environment(AppModel.self) private var model
    let form: TicketForm
    let onSubmit: (Side) -> Void

    /// The submit gate, resolved against live price / buying power / link / halt.
    private var canSubmit: Bool {
        form.canSubmit(
            price: model.lastPrice(form.symbol),
            buyingPower: model.buyingPower,
            connected: model.connection == .connected,
            killSwitch: model.risk.kill_switch
        )
    }

    var body: some View {
        if model.risk.kill_switch {
            Text("Kill switch engaged")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.down)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .strokeBorder(Theme.down.opacity(0.5), lineWidth: Theme.hairline)
                )
        } else {
            VStack(spacing: 6) {
                venueTag
                HStack(spacing: 8) {
                    Button { onSubmit(.buy) } label: {
                        Text("BUY").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BuySellButtonStyle(tint: Theme.up, armed: form.side == .buy))
                    .disabled(!canSubmit)

                    Button { onSubmit(.sell) } label: {
                        Text("SELL").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BuySellButtonStyle(tint: Theme.down, armed: form.side == .sell))
                    .disabled(!canSubmit)
                }
                .opacity(canSubmit ? 1 : 0.5)
            }
        }
    }

    /// Compact execution-venue tag pinned above BUY/SELL so the trader always
    /// knows where the order lands before clicking. Derives from the shared
    /// BrokerBadge mapping (single source of truth), so it can never disagree
    /// with the TopBar: calm inline text for PAPER / IBKR PAPER, a loud ember
    /// chip for a connected LIVE account.
    private var venueTag: some View {
        let tag = TicketVenueTag.make(for: model.broker)
        return HStack(spacing: 5) {
            Text("venue")
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(Theme.dim)
            Text(tag.text)
                .font(.system(size: 10, weight: tag.isLive ? .bold : .semibold))
                .tracking(1.0)
                .foregroundStyle(tag.color)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, tag.isLive ? 8 : 0)
        .padding(.vertical, tag.isLive ? 3 : 0)
        .background(tag.isLive ? Theme.ember.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(
                    tag.isLive ? Theme.ember.opacity(0.55) : Color.clear,
                    lineWidth: Theme.hairline
                )
        )
        .help(tag.isLive
            ? "REAL MONEY — orders execute at your live broker account"
            : "execution venue for this ticket")
        .accessibilityLabel("venue \(tag.text)")
    }
}

/// FLATTEN / REVERSE. Reads the position book itself — positions are marked on
/// the same ~12 Hz flush as ticks, so keeping this read out of the parent is
/// what stops a marked-to-market position from re-laying-out the whole ticket.
private struct TicketPositionActions: View {
    @Environment(AppModel.self) private var model
    let symbol: String
    let onFlatten: () -> Void
    let onReverse: () -> Void

    private var position: Position? {
        guard let p = model.positions[symbol],
            abs(p.qty) > PositionAction.flatEpsilon else { return nil }
        return p
    }

    var body: some View {
        // FLATTEN and REVERSE gate SEPARATELY: closing is allowed under a kill
        // switch, but reversing (which opens a LARGER opposite position) is not —
        // it must never be a way around a halt.
        let noPosition = position == nil || model.connection != .connected
        HStack(spacing: 8) {
            Button(action: onFlatten) {
                Text("FLATTEN").frame(maxWidth: .infinity)
            }
            .buttonStyle(DeckTintedButtonStyle(tint: Theme.bone, border: Theme.line))
            .disabled(noPosition)
            .opacity(noPosition ? 0.45 : 1)

            Button(action: onReverse) {
                Text("REVERSE").frame(maxWidth: .infinity)
            }
            .buttonStyle(DeckTintedButtonStyle(tint: Theme.bone, border: Theme.line))
            .disabled(noPosition || model.risk.kill_switch)
            .opacity(noPosition || model.risk.kill_switch ? 0.45 : 1)
        }
        .help(position == nil ? "no position on \(symbol)" : "market unwind of \(symbol)")
    }
}

// MARK: - Venue tag

/// The compact execution-venue tag shown beside BUY/SELL. Derives entirely from
/// the shared `BrokerBadge` mapping (the single source of truth for the
/// paper / ibkr-paper / ibkr-live posture), so the ticket can never disagree
/// with the TopBar about whether real money is at play. Kept as a small typed
/// value so the mapping is unit-tested.
struct TicketVenueTag: Equatable {
    /// "PAPER" / "IBKR PAPER" / "IBKR LIVE" / "IBKR".
    var text: String
    /// Real money at a connected live account — the ticket renders this loud.
    var isLive: Bool
    var color: Color

    static func make(for status: BrokerStatus?) -> TicketVenueTag {
        let s = BrokerBadge.style(for: status)
        return TicketVenueTag(text: s.text, isLive: s.isLive, color: s.textColor)
    }
}

// MARK: - Styles

/// Prominent directional entry button: a solid up/red fill with bold bone
/// type. The armed side (the one Return fires) carries a faint bone ring.
private struct BuySellButtonStyle: ButtonStyle {
    let tint: Color
    let armed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(Theme.bone)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(configuration.isPressed ? tint.opacity(0.75) : tint)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(Theme.bone.opacity(armed ? 0.55 : 0), lineWidth: Theme.hairline)
            )
    }
}

private extension View {
    /// The shared ink-inset field chrome (border reddens when invalid).
    func fieldChrome(invalid: Bool) -> some View {
        padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.ink)
            .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.chipRadius)
                    .strokeBorder(invalid ? Theme.down.opacity(0.6) : Theme.line, lineWidth: Theme.hairline)
            )
    }
}
