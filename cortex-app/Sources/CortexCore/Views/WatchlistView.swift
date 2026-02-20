import SwiftUI

public struct WatchlistView: View {
    let store: WatchlistStore
    @Environment(\.cortexSelectedSection) private var selectedSection
    @State private var newSymbolText: String = ""

    public init(store: WatchlistStore) {
        self.store = store
    }

    public var body: some View {
        switch selectedSection {
        case "Active Positions":
            positionsFullView
        case "All Symbols":
            watchlistFullView
        case "Alerts":
            alertsPlaceholder
        case "Order History":
            orderHistoryPlaceholder
        default:
            defaultSplitView
        }
    }

    // MARK: - Default Split View

    @ViewBuilder
    private var defaultSplitView: some View {
        HSplitView {
            watchlistPanel
                .frame(minWidth: 500)

            positionsPanel
                .frame(minWidth: 350)
        }
    }

    // MARK: - Watchlist Panel (reusable)

    @ViewBuilder
    private var watchlistPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "eye.fill")
                    .foregroundStyle(CortexDesign.accentPrimary)
                Text("Watchlist")
                    .font(.headline)
                Spacer()
                Text("\(store.items.count) symbols")
                    .font(CortexDesign.labelFont)
                    .foregroundStyle(.secondary)
            }
            .padding()

            // Add-symbol bar
            HStack(spacing: 8) {
                TextField("Add symbol...", text: $newSymbolText)
                    .textFieldStyle(.plain)
                    .font(CortexDesign.dataFont)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: CortexDesign.badgeRadius)
                            .fill(CortexDesign.bgElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CortexDesign.badgeRadius)
                            .strokeBorder(CortexDesign.border, lineWidth: 1)
                    )
                    .onSubmit { addSymbolFromField() }

                Button(action: addSymbolFromField) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12))
                        Text("Add")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(CortexDesign.accentPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: CortexDesign.badgeRadius)
                            .fill(CortexDesign.accentPrimary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CortexDesign.badgeRadius)
                            .strokeBorder(CortexDesign.accentPrimary.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(newSymbolText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

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
            .background(CortexDesign.bgCard)

            List {
                ForEach(store.items) { item in
                    WatchlistRow(item: item, isSelected: store.selectedSymbol == item.symbol)
                        .contentShape(Rectangle())
                        .onTapGesture { store.selectedSymbol = item.symbol }
                        .contextMenu {
                            Button(role: .destructive) {
                                store.removeSymbol(item.symbol)
                            } label: {
                                Label("Remove \(item.symbol)", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                store.removeSymbol(item.symbol)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                }
            }
            .listStyle(.plain)
        }
    }

    private func addSymbolFromField() {
        let trimmed = newSymbolText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.addSymbol(trimmed)
        newSymbolText = ""
    }

    // MARK: - Positions Panel (reusable)

    @ViewBuilder
    private var positionsPanel: some View {
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
    }

    // MARK: - Full Width Views

    @ViewBuilder
    private var watchlistFullView: some View {
        watchlistPanel
    }

    @ViewBuilder
    private var positionsFullView: some View {
        positionsPanel
    }

    // MARK: - Alerts Placeholder

    @ViewBuilder
    private var alertsPlaceholder: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "bell.badge")
                .font(.system(size: 40))
                .foregroundStyle(Color(white: 0.2))

            Text("Price Alerts")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(white: 0.6))

            Text("Configure price alerts for your watchlist symbols.\nGet notified when prices hit your target levels.")
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.4))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)

            Button(action: {}) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12))
                    Text("Create Alert")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.cyan)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.cyan.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.cyan.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.05))
    }

    // MARK: - Order History Placeholder

    @ViewBuilder
    private var orderHistoryPlaceholder: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundStyle(Color(white: 0.2))

            Text("Order History")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(white: 0.6))

            Text("Recent order executions will appear here.\nAll filled, cancelled, and pending orders are logged.")
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.4))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.05))
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
        if price == 0 { return "--" }
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
