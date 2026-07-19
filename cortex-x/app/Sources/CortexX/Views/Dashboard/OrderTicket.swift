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
    @FocusState private var focus: TicketFocus?

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
    private var price: Double? { model.lastPrice(symbol) }
    private var book: BookTop? { model.bookTop[symbol] }
    private var increment: Double { OrderSizing.defaultIncrement(whole: whole) }

    private var usesLimit: Bool { orderType == .limit || orderType == .stop_limit }
    private var usesStop: Bool { orderType == .stop || orderType == .stop_limit }

    private var limitPx: Double? { Self.parse(limitText) }
    private var stopPx: Double? { Self.parse(stopText) }

    /// The share count the current sizing mode resolves to, at the working
    /// price. nil when the mode's inputs are incomplete or price is missing.
    private var effectiveQty: Double? {
        switch sizingMode {
        case .shares:
            return Self.parse(qtyText)
        case .dollars:
            guard let d = Self.parse(dollarText), let p = price else { return nil }
            return OrderSizing.shares(dollars: d, price: p, whole: whole)
        case .percent:
            guard let f = pctSelected, let p = price else { return nil }
            return OrderSizing.sharesFromBuyingPower(
                fraction: f, buyingPower: model.buyingPower, price: p, whole: whole
            )
        }
    }

    /// The price the order works at — for notional and the fill reference.
    private var workingPrice: Double? {
        if usesLimit, let l = limitPx { return l }
        if orderType == .stop, let s = stopPx { return s }
        return price
    }

    private var notional: Double? {
        guard let q = effectiveQty, let p = workingPrice else { return nil }
        return OrderSizing.notional(qty: q, price: p)
    }

    private var equityFraction: Double? {
        guard let n = notional else { return nil }
        return OrderSizing.fractionOfEquity(notional: n, equity: model.account.equity)
    }

    /// Signed loss/share from the current market to the protective stop.
    private var riskPerShare: Double? {
        guard usesStop, let s = stopPx, let p = price else { return nil }
        return OrderRisk.riskPerShare(side: side, entry: p, stop: s)
    }

    private var totalRisk: Double? {
        guard let rps = riskPerShare, let q = effectiveQty else { return nil }
        return abs(rps) * q
    }

    /// Reward:risk once a stop-limit sets both a stop and a target limit,
    /// measured from where the market is now.
    private var rewardRisk: Double? {
        guard orderType == .stop_limit,
            let s = stopPx, let t = limitPx, let p = price else { return nil }
        return OrderRisk.rr(side: side, entry: p, stop: s, target: t)
    }

    /// The open position on this symbol (nil when flat) — flatten/reverse gate.
    private var position: Position? {
        guard let p = model.positions[symbol],
            abs(p.qty) > PositionAction.flatEpsilon else { return nil }
        return p
    }

    private var isValid: Bool {
        guard let q = effectiveQty, q > 0 else { return false }
        if usesLimit && limitPx == nil { return false }
        if usesStop && stopPx == nil { return false }
        return true
    }

    private var canSubmit: Bool {
        isValid && model.connection == .connected && !model.risk.kill_switch
    }

    // MARK: Body

    var body: some View {
        // Densified so the full ticket — quote, order type, sizing, buy/sell,
        // flatten/reverse — is visible at a glance inside the 280pt deck with
        // no scrolling. The symbol picker rides in the header; the quote and
        // the size/risk readout are each a single compact line; price fields
        // stay hidden for MKT.
        VStack(alignment: .leading, spacing: 6) {
            header
            quoteRow
            typeSegment
            priceFields
            sizeModeRow
            sizingInput
            readoutLine
            submitControls
            flattenReverseRow
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
            if symbolOverride == nil { seedPricesIfNeeded() }
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

    // MARK: Quote row — one compact line: bid · last · ask · spread. Bid/ask
    // stay click-to-price; the size sub-line is dropped for deck density.

    private var quoteRow: some View {
        HStack(spacing: 5) {
            quoteCell(label: "bid", px: book?.bid_px, tint: Theme.up, action: clickBid)
            quoteCell(label: "last", px: price, tint: Theme.bone, action: nil)
            quoteCell(label: "ask", px: book?.ask_px, tint: Theme.down, action: clickAsk)
            spreadCell
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

    private var spread: Double? {
        guard let b = book, b.ask_px.isFinite, b.bid_px.isFinite,
            b.ask_px > 0, b.bid_px > 0, b.ask_px >= b.bid_px else { return nil }
        return b.ask_px - b.bid_px
    }

    private var spreadCell: some View {
        VStack(spacing: 1) {
            Text("SPR")
                .font(.system(size: 7, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.dim)
            Text(spread.map { DashFormat.price($0) } ?? "—")
                .numeric(size: 11)
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(width: 54)
        .padding(.vertical, 4)
        .help("bid/ask spread")
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

    // MARK: Risk / size readout — one compact line: resolved shares, notional,
    // % of equity (ember dot when concentrated), and — once a stop is set —
    // total risk and reward:risk. All formatting/gating lives in the pure
    // TicketReadout helper.

    private var readoutLine: some View {
        let r = TicketReadout.make(
            qty: effectiveQty,
            notional: notional,
            equityFraction: equityFraction,
            totalRisk: totalRisk,
            rewardRisk: rewardRisk
        )
        return HStack(spacing: 6) {
            readoutSeg("=", r.shares, effectiveQty == nil ? Theme.dim : Theme.bone)
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

    // MARK: Submit + position actions

    @ViewBuilder
    private var submitControls: some View {
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
            HStack(spacing: 8) {
                Button { submit(.buy) } label: {
                    Text("BUY").frame(maxWidth: .infinity)
                }
                .buttonStyle(BuySellButtonStyle(tint: Theme.up, armed: side == .buy))
                .disabled(!canSubmit)

                Button { submit(.sell) } label: {
                    Text("SELL").frame(maxWidth: .infinity)
                }
                .buttonStyle(BuySellButtonStyle(tint: Theme.down, armed: side == .sell))
                .disabled(!canSubmit)
            }
            .opacity(canSubmit ? 1 : 0.5)
        }
    }

    private var flattenReverseRow: some View {
        HStack(spacing: 8) {
            Button { flatten() } label: {
                Text("FLATTEN").frame(maxWidth: .infinity)
            }
            .buttonStyle(DeckTintedButtonStyle(tint: Theme.bone, border: Theme.line))

            Button { reverse() } label: {
                Text("REVERSE").frame(maxWidth: .infinity)
            }
            .buttonStyle(DeckTintedButtonStyle(tint: Theme.bone, border: Theme.line))
        }
        .disabled(position == nil || model.connection != .connected)
        .opacity(position == nil ? 0.45 : 1)
        .help(position == nil ? "no position on \(symbol)" : "market unwind of \(symbol)")
    }

    // MARK: Actions

    private func select(_ s: String) {
        symbolOverride = s == model.selectedSymbol ? nil : s
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

    private func clickBid() { aggress(side: .sell, at: book?.bid_px) }
    private func clickAsk() { aggress(side: .buy, at: book?.ask_px) }

    /// "Buy the ask / sell the bid": arm the aggressive side, switch to a
    /// limit if not already price-bearing, and seat the limit at that level.
    private func aggress(side newSide: Side, at level: Double?) {
        guard let level, level.isFinite, level > 0 else { return }
        side = newSide
        if !usesLimit { orderType = .limit }
        limitText = DashFormat.editable(level)
        focus = .qty
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

    private func submit(_ s: Side) {
        side = s
        guard canSubmit, let qty = effectiveQty else { return }
        model.placeOrder(
            symbol: symbol, side: s, qty: qty, type: orderType,
            limitPx: usesLimit ? limitPx : nil,
            stopPx: usesStop ? stopPx : nil
        )
        clearSize()
    }

    private func submitArmed() { submit(side) }

    private func flatten() {
        guard let p = position, let a = PositionAction.flatten(positionQty: p.qty) else { return }
        model.placeOrder(
            symbol: p.symbol, side: a.side, qty: a.qty, type: .market,
            limitPx: nil, stopPx: nil
        )
    }

    private func reverse() {
        guard let p = position, let a = PositionAction.reverse(positionQty: p.qty) else { return }
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

    private static func parse(_ text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let v = Double(cleaned), v.isFinite, v > 0 else { return nil }
        return v
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
