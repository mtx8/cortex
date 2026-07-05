// Order ticket: symbol (follows chart selection until overridden), buy/sell,
// qty, market/limit + limit px, live notional, ember submit. Kill switch
// replaces the submit button entirely.

import SwiftUI

struct OrderTicket: View {
    @Environment(AppModel.self) private var model

    /// Non-nil once the operator picks a symbol by hand; nil = follow the chart.
    @State private var symbolOverride: String?
    @State private var side: Side = .buy
    @State private var qtyText = ""
    @State private var orderType: OrderType = .market
    @State private var limitText = ""

    private var symbol: String { symbolOverride ?? model.selectedSymbol }

    private var symbolChoices: [String] {
        var list = model.symbols
        if list.isEmpty { list = [model.selectedSymbol] }
        if let s = symbolOverride, !list.contains(s) { list.append(s) }
        return list
    }

    private var qty: Double? { Self.parse(qtyText) }
    private var limitPx: Double? { Self.parse(limitText) }

    private var isValid: Bool {
        qty != nil && (orderType == .market || limitPx != nil)
    }

    private var canSubmit: Bool {
        isValid && model.connection == .connected && !model.risk.kill_switch
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "ticket")
            HStack(spacing: 6) {
                symbolMenu
                sideSegment
            }
            HStack(spacing: 6) {
                ticketField("qty", text: $qtyText, invalid: !qtyText.isEmpty && qty == nil)
                typeSegment
            }
            if orderType == .limit {
                ticketField("px", text: $limitText, invalid: !limitText.isEmpty && limitPx == nil)
            }
            notionalRow
            submitControl
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .onChange(of: orderType) { _, t in
            if t == .limit, limitText.isEmpty { prefillLimit() }
        }
        .onChange(of: model.selectedSymbol) { _, _ in
            if symbolOverride == nil, orderType == .limit { prefillLimit() }
        }
    }

    // MARK: Controls

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

    private var sideSegment: some View {
        HStack(spacing: 4) {
            DeckSegment(title: "Buy", isOn: side == .buy, tint: Theme.up) { side = .buy }
            DeckSegment(title: "Sell", isOn: side == .sell, tint: Theme.down) { side = .sell }
        }
        .frame(width: 112)
    }

    private var typeSegment: some View {
        HStack(spacing: 4) {
            DeckSegment(title: "Market", isOn: orderType == .market) { orderType = .market }
            DeckSegment(title: "Limit", isOn: orderType == .limit) { orderType = .limit }
        }
        .frame(width: 128)
    }

    private func ticketField(_ label: String, text: Binding<String>, invalid: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.dim)
            TextField("0", text: text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.bone)
                .onSubmit { submit() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.ink)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(invalid ? Theme.down.opacity(0.6) : Theme.line, lineWidth: Theme.hairline)
        )
    }

    private var notionalRow: some View {
        HStack {
            Text("notional")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.dim)
            Spacer()
            Text(notionalText)
                .numeric(size: 11)
                .foregroundStyle(Theme.dim)
        }
    }

    private var notionalText: String {
        guard let q = qty, let p = model.lastPrice(symbol) else { return "—" }
        return DashFormat.money(q * p)
    }

    @ViewBuilder
    private var submitControl: some View {
        if model.risk.kill_switch {
            Text("Kill switch engaged")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.down)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .strokeBorder(Theme.down.opacity(0.5), lineWidth: Theme.hairline)
                )
        } else {
            Button {
                submit()
            } label: {
                Text("\(side.rawValue.capitalized) \(symbol)")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(EmberButtonStyle())
            .disabled(!canSubmit)
            .opacity(canSubmit ? 1 : 0.45)
        }
    }

    // MARK: Actions

    private func select(_ s: String) {
        symbolOverride = s == model.selectedSymbol ? nil : s
        if orderType == .limit { prefillLimit() }
    }

    private func prefillLimit() {
        if let p = model.lastPrice(symbol) {
            limitText = DashFormat.editable(p)
        }
    }

    private func submit() {
        guard canSubmit, let qty else { return }
        model.send(.placeOrder(
            symbol: symbol,
            side: side,
            qty: qty,
            orderType: orderType,
            limitPx: orderType == .limit ? limitPx : nil
        ))
        qtyText = ""
    }

    private static func parse(_ text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let v = Double(cleaned), v.isFinite, v > 0 else { return nil }
        return v
    }
}
