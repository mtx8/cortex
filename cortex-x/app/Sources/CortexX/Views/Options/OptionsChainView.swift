// Full option chain: calls | strike | puts around the money, expiry chips,
// venue + Black-Scholes-backfilled greeks. Delayed data is labeled as such.

import SwiftUI

struct OptionsChainView: View {
    @Environment(AppModel.self) private var model

    private var underlying: String {
        AppModel.isEquity(model.selectedSymbol) ? model.selectedSymbol : firstEquity
    }
    private var firstEquity: String {
        model.symbols.first(where: AppModel.isEquity) ?? "SPY"
    }
    private var chain: OptionsChain? {
        guard let c = model.optionsChain, c.underlying == underlying else { return nil }
        return c
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.line)
            if let chain {
                expiryStrip(chain)
                Divider().overlay(Theme.line)
                chainTable(chain)
            } else {
                VStack(spacing: 8) {
                    if model.chainLoading {
                        ProgressView().controlSize(.small).tint(Theme.ember)
                        Text("loading chain for \(underlying)")
                            .font(.system(size: 12)).foregroundStyle(Theme.dim)
                    } else {
                        Text("no chain loaded")
                            .font(.system(size: 12)).foregroundStyle(Theme.dim)
                        Button("load \(underlying) chain") {
                            model.requestOptionsChain(underlying: underlying)
                        }
                        .buttonStyle(EmberButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.ink)
        .task(id: underlying) {
            if chain == nil { model.requestOptionsChain(underlying: underlying) }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            SectionLabel(text: "options")
            Text(underlying)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.bone)
            if let chain {
                Text(Fmt.price(chain.underlying_px))
                    .numeric(size: 13, weight: .medium)
                    .foregroundStyle(Theme.bone)
                Text(chain.source)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.warn)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.warn.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
            }
            Spacer()
            Button("refresh") {
                model.requestOptionsChain(underlying: underlying, expiry: chain?.expiry)
            }
            .buttonStyle(QuietButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func expiryStrip(_ chain: OptionsChain) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chain.expirations, id: \.self) { exp in
                    let active = exp == chain.expiry
                    Button {
                        model.requestOptionsChain(underlying: underlying, expiry: exp)
                    } label: {
                        Text(exp)
                            .font(.system(size: 10, weight: active ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(active ? Theme.ember : Theme.dim)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(active ? Theme.emberTint : Theme.panel)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.chipRadius)
                                    .strokeBorder(active ? Theme.emberDown.opacity(0.5) : Theme.line, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    private func chainTable(_ chain: OptionsChain) -> some View {
        let rows = strikeRows(chain)
        return VStack(spacing: 0) {
            chainHeader
            Divider().overlay(Theme.line)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            StrikeRow(row: row, spot: chain.underlying_px)
                                .id(row.strike)
                        }
                    }
                }
                .onAppear {
                    if let atm = rows.min(by: {
                        abs($0.strike - chain.underlying_px) < abs($1.strike - chain.underlying_px)
                    }) {
                        proxy.scrollTo(atm.strike, anchor: .center)
                    }
                }
            }
        }
    }

    private var chainHeader: some View {
        HStack(spacing: 0) {
            ForEach(["bid", "ask", "iv", "delta", "vol", "oi"], id: \.self) { h in
                cell(h.uppercased(), width: callPutColWidth, style: Theme.dim)
            }
            cell("STRIKE", width: strikeColWidth, style: Theme.dim, weight: .semibold)
            ForEach(["bid", "ask", "iv", "delta", "vol", "oi"], id: \.self) { h in
                cell(h.uppercased(), width: callPutColWidth, style: Theme.dim)
            }
        }
        .font(.system(size: 9, weight: .semibold))
        .padding(.vertical, 5)
        .background(Theme.panel)
    }

    private func strikeRows(_ chain: OptionsChain) -> [ChainRow] {
        var by: [Double: ChainRow] = [:]
        for c in chain.contracts {
            var row = by[c.strike] ?? ChainRow(strike: c.strike, call: nil, put: nil)
            if c.right == .call { row.call = c } else { row.put = c }
            by[c.strike] = row
        }
        return by.values.sorted { $0.strike < $1.strike }
    }
}

private let callPutColWidth: CGFloat = 62
private let strikeColWidth: CGFloat = 78

private struct ChainRow: Identifiable {
    let strike: Double
    var call: OptionContract?
    var put: OptionContract?
    var id: Double { strike }
}

private struct StrikeRow: View {
    let row: ChainRow
    let spot: Double
    @State private var hovering = false

    private var isNearMoney: Bool { abs(row.strike - spot) / max(spot, 1) < 0.005 }

    var body: some View {
        HStack(spacing: 0) {
            sideCells(row.call, itm: row.strike < spot)
            cell(Fmt.price(row.strike), width: strikeColWidth,
                 style: isNearMoney ? Theme.ember : Theme.bone,
                 weight: isNearMoney ? .bold : .medium)
                .background(Theme.panel.opacity(0.6))
            sideCells(row.put, itm: row.strike > spot)
        }
        .font(.system(size: 10))
        .padding(.vertical, 3)
        .background(hovering ? Theme.panelHi : (isNearMoney ? Theme.emberTint : .clear))
        .onHover { hovering = $0 }
        .help(helpText)
    }

    private func sideCells(_ c: OptionContract?, itm: Bool) -> some View {
        let base: Color = itm ? Theme.bone : Theme.dim
        return HStack(spacing: 0) {
            cell(c.map { Fmt.price($0.bid) } ?? "—", width: callPutColWidth, style: base)
            cell(c.map { Fmt.price($0.ask) } ?? "—", width: callPutColWidth, style: base)
            cell(c?.iv.map { String(format: "%.0f%%", $0 * 100) } ?? "—", width: callPutColWidth,
                 style: Theme.warn.opacity(0.9))
            cell(c?.delta.map { String(format: "%+.2f", $0) } ?? "—", width: callPutColWidth,
                 style: base)
            cell(c.map { Fmt.qty($0.volume) } ?? "—", width: callPutColWidth, style: base)
            cell(c.map { Fmt.qty($0.open_interest) } ?? "—", width: callPutColWidth, style: base)
        }
    }

    private var helpText: String {
        var parts: [String] = []
        if let c = row.call {
            parts.append("call " + greeksLine(c))
        }
        if let p = row.put {
            parts.append("put " + greeksLine(p))
        }
        return parts.joined(separator: "\n")
    }

    private func greeksLine(_ c: OptionContract) -> String {
        let g = String(
            format: "gamma %.4f theta %.3f vega %.3f",
            c.gamma ?? .nan, c.theta ?? .nan, c.vega ?? .nan
        )
        return "\(g) [\(c.greeks_source)]"
    }
}

private func cell(_ text: String, width: CGFloat, style: Color, weight: Font.Weight = .regular) -> some View {
    Text(text)
        .font(.system(size: 10, weight: weight))
        .monospacedDigit()
        .foregroundStyle(style)
        .frame(width: width, alignment: .center)
        .lineLimit(1)
}
