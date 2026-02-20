import SwiftUI

/// Option chain table showing strikes with calls and puts side by side.
/// Strike | Calls (Bid/Ask/Vol/OI/IV/Delta) | Puts (Bid/Ask/Vol/OI/IV/Delta)
public struct OptionChainView: View {
    let store: OptionsStore

    public init(store: OptionsStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(CortexDesign.border)

            if store.isLoading {
                loadingState
            } else if store.strikes.isEmpty {
                emptyState
            } else {
                chainTable
            }
        }
        .background(CortexDesign.bgDeepest)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "tablecells")
                .font(.system(size: 12))
                .foregroundStyle(CortexDesign.accentPrimary)

            Text("OPTION CHAIN")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            if !store.activeSymbol.isEmpty {
                Text(store.activeSymbol)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            }

            Spacer()

            if store.underlyingPrice > 0 {
                Text(String(format: "Underlying: $%.2f", store.underlyingPrice))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Expiration picker
            if !store.expirations.isEmpty {
                Menu {
                    ForEach(store.expirations, id: \.self) { exp in
                        Button(formatExpiration(exp)) {
                            store.selectedExpiration = exp
                            store.requestChain(symbol: store.activeSymbol, expiration: exp)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(store.selectedExpiration.map { formatExpiration($0) } ?? "Expiration")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(CortexDesign.bgElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(CortexDesign.border, lineWidth: 1)
                    )
                    .foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(CortexDesign.bgCard)
    }

    // MARK: - Chain Table

    private var chainTable: some View {
        VStack(spacing: 0) {
            // Column headers
            HStack(spacing: 0) {
                // Call side
                Group {
                    Text("Bid").frame(width: 60, alignment: .trailing)
                    Text("Ask").frame(width: 60, alignment: .trailing)
                    Text("Vol").frame(width: 50, alignment: .trailing)
                    Text("OI").frame(width: 55, alignment: .trailing)
                    Text("IV").frame(width: 50, alignment: .trailing)
                    Text("Delta").frame(width: 50, alignment: .trailing)
                }
                .foregroundStyle(CortexDesign.profit.opacity(0.7))

                // Strike
                Text("Strike")
                    .frame(width: 70, alignment: .center)
                    .foregroundStyle(.white)

                // Put side
                Group {
                    Text("Delta").frame(width: 50, alignment: .leading)
                    Text("IV").frame(width: 50, alignment: .leading)
                    Text("OI").frame(width: 55, alignment: .leading)
                    Text("Vol").frame(width: 50, alignment: .leading)
                    Text("Bid").frame(width: 60, alignment: .leading)
                    Text("Ask").frame(width: 60, alignment: .leading)
                }
                .foregroundStyle(CortexDesign.loss.opacity(0.7))
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(CortexDesign.bgCard)

            Divider().overlay(CortexDesign.border)

            // Data rows
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.strikes, id: \.self) { strike in
                        chainRow(strike: strike)
                        Divider().overlay(Color(white: 0.06))
                    }
                }
            }
        }
    }

    private func chainRow(strike: Double) -> some View {
        let call = store.call(at: strike)
        let put = store.put(at: strike)
        let isATM = abs(strike - store.underlyingPrice) < 2.5
        let isITMCall = strike < store.underlyingPrice
        let isITMPut = strike > store.underlyingPrice

        return HStack(spacing: 0) {
            // Call side
            Group {
                Text(call.map { String(format: "%.2f", $0.bid) } ?? "--")
                    .frame(width: 60, alignment: .trailing)
                Text(call.map { String(format: "%.2f", $0.ask) } ?? "--")
                    .frame(width: 60, alignment: .trailing)
                Text(call.map { formatInt($0.volume) } ?? "--")
                    .frame(width: 50, alignment: .trailing)
                Text(call.map { formatInt($0.openInterest) } ?? "--")
                    .frame(width: 55, alignment: .trailing)
                Text(call.map { String(format: "%.0f%%", $0.impliedVolatility * 100) } ?? "--")
                    .frame(width: 50, alignment: .trailing)
                Text(call.map { String(format: "%.2f", $0.delta) } ?? "--")
                    .frame(width: 50, alignment: .trailing)
            }
            .foregroundStyle(isITMCall ? CortexDesign.profit.opacity(0.8) : .secondary)
            .onTapGesture {
                if let c = call {
                    store.addLeg(c, side: .buy)
                }
            }

            // Strike
            Text(String(format: "%.1f", strike))
                .frame(width: 70, alignment: .center)
                .foregroundStyle(.white)
                .fontWeight(isATM ? .bold : .regular)

            // Put side
            Group {
                Text(put.map { String(format: "%.2f", $0.delta) } ?? "--")
                    .frame(width: 50, alignment: .leading)
                Text(put.map { String(format: "%.0f%%", $0.impliedVolatility * 100) } ?? "--")
                    .frame(width: 50, alignment: .leading)
                Text(put.map { formatInt($0.openInterest) } ?? "--")
                    .frame(width: 55, alignment: .leading)
                Text(put.map { formatInt($0.volume) } ?? "--")
                    .frame(width: 50, alignment: .leading)
                Text(put.map { String(format: "%.2f", $0.bid) } ?? "--")
                    .frame(width: 60, alignment: .leading)
                Text(put.map { String(format: "%.2f", $0.ask) } ?? "--")
                    .frame(width: 60, alignment: .leading)
            }
            .foregroundStyle(isITMPut ? CortexDesign.loss.opacity(0.8) : .secondary)
            .onTapGesture {
                if let p = put {
                    store.addLeg(p, side: .buy)
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isATM ? CortexDesign.accentPrimary.opacity(0.04) : Color.clear)
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView("Loading option chain...")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tablecells")
                .font(.system(size: 36))
                .foregroundStyle(Color(white: 0.2))
            Text("No Option Chain Data")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(white: 0.6))
            Text("Search a symbol in Financials to load its option chain.")
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.4))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Formatting

    private func formatExpiration(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, yyyy"
        return formatter.string(from: date)
    }

    private func formatInt(_ value: Int) -> String {
        if value >= 1000 {
            return String(format: "%.1fK", Double(value) / 1000)
        }
        return "\(value)"
    }
}
