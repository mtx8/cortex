import SwiftUI

public struct WatchlistView: View {
    let store: WatchlistStore

    public init(store: WatchlistStore) {
        self.store = store
    }

    public var body: some View {
        HSplitView {
            // Left: Watchlist
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "eye.fill")
                        .foregroundStyle(.blue)
                    Text("Watchlist")
                        .font(.headline)
                    Spacer()
                    Text("\(store.items.count) symbols")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()

                Divider()

                // Column headers
                HStack {
                    Text("Symbol").frame(width: 80, alignment: .leading)
                    Text("Price").frame(width: 80, alignment: .trailing)
                    Text("Change").frame(width: 90, alignment: .trailing)
                    Text("Volume").frame(width: 80, alignment: .trailing)
                    Text("RSI").frame(width: 50, alignment: .trailing)
                    Text("Signal").frame(width: 70, alignment: .center)
                }
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color(.controlBackgroundColor))

                List(store.items) { item in
                    WatchlistRow(item: item, isSelected: store.selectedSymbol == item.symbol)
                        .contentShape(Rectangle())
                        .onTapGesture { store.selectedSymbol = item.symbol }
                }
                .listStyle(.plain)
            }
            .frame(minWidth: 500)

            // Right: Positions
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "briefcase.fill")
                        .foregroundStyle(.green)
                    Text("Open Positions")
                        .font(.headline)
                    Spacer()
                    let pnl = store.totalUnrealizedPnL
                    Text(String(format: "%@$%.2f", pnl >= 0 ? "+" : "", pnl))
                        .font(.headline)
                        .foregroundStyle(pnl >= 0 ? .green : .red)
                }
                .padding()

                Divider()

                if store.positions.isEmpty {
                    ContentUnavailableView("No Open Positions", systemImage: "tray",
                        description: Text("Positions will appear here when trades are executed."))
                } else {
                    List(store.positions) { position in
                        PositionRow(position: position)
                    }
                    .listStyle(.plain)
                }
            }
            .frame(minWidth: 350)
        }
    }
}

struct WatchlistRow: View {
    let item: WatchlistItem
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.symbol)
                    .font(.body.bold())
                if let signal = item.signal {
                    signalDot(signal)
                }
            }
            .frame(width: 80, alignment: .leading)

            Text(formatPrice(item.price))
                .font(.body.monospacedDigit())
                .frame(width: 80, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%@%.2f", item.change >= 0 ? "+" : "", item.change))
                    .font(.caption.monospacedDigit())
                Text(String(format: "%@%.2f%%", item.changePercent >= 0 ? "+" : "", item.changePercent))
                    .font(.caption2.monospacedDigit())
            }
            .foregroundStyle(item.change >= 0 ? .green : .red)
            .frame(width: 90, alignment: .trailing)

            Text(formatVolume(item.volume))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            if let rsi = item.rsi {
                Text(String(format: "%.1f", rsi))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(rsi > 70 ? .red : rsi < 30 ? .green : .primary)
                    .frame(width: 50, alignment: .trailing)
            } else {
                Text("--")
                    .frame(width: 50, alignment: .trailing)
            }

            if let signal = item.signal {
                Text(signal.uppercased())
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(signalColor(signal).opacity(0.2))
                    .foregroundStyle(signalColor(signal))
                    .clipShape(Capsule())
                    .frame(width: 70, alignment: .center)
            }
        }
        .padding(.vertical, 4)
        .background(isSelected ? Color.blue.opacity(0.1) : .clear)
        .cornerRadius(6)
    }

    func signalDot(_ signal: String) -> some View {
        Circle()
            .fill(signalColor(signal))
            .frame(width: 6, height: 6)
    }

    func signalColor(_ signal: String) -> Color {
        switch signal {
        case "buy": return .green
        case "sell": return .red
        default: return .gray
        }
    }

    func formatPrice(_ price: Double) -> String {
        if price >= 1000 { return String(format: "$%.0f", price) }
        return String(format: "$%.2f", price)
    }

    func formatVolume(_ vol: Double) -> String {
        if vol >= 1_000_000_000 { return String(format: "%.1fB", vol / 1_000_000_000) }
        if vol >= 1_000_000 { return String(format: "%.1fM", vol / 1_000_000) }
        if vol >= 1_000 { return String(format: "%.1fK", vol / 1_000) }
        return String(format: "%.0f", vol)
    }
}

struct PositionRow: View {
    let position: Position

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(position.symbol)
                    .font(.body.bold())
                Text(position.side.uppercased())
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(position.side == "long" ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                    .foregroundStyle(position.side == "long" ? .green : .red)
                    .clipShape(Capsule())
                Spacer()
                Text(String(format: "%@$%.2f", position.unrealizedPnL >= 0 ? "+" : "", position.unrealizedPnL))
                    .font(.body.bold().monospacedDigit())
                    .foregroundStyle(position.unrealizedPnL >= 0 ? .green : .red)
            }

            HStack {
                Label("\(position.quantity) shares", systemImage: "number")
                Spacer()
                Text(String(format: "Entry: $%.2f", position.entryPrice))
                Spacer()
                Text(String(format: "Current: $%.2f", position.currentPrice))
                Spacer()
                Text(String(format: "Stop: $%.2f", position.stopLoss))
                    .foregroundStyle(.red)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
