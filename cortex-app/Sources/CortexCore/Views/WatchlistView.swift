import SwiftUI

public struct WatchlistView: View {
    let store: WatchlistStore
    let alertStore: AlertStore
    @Environment(\.cortexSelectedSection) private var selectedSection
    @State private var newSymbolText: String = ""
    @State private var showCreateAlert: Bool = false
    @State private var alertSymbol: String = ""
    @State private var alertTypeSelection: PriceAlert.AlertType = .priceAbove
    @State private var alertThreshold: String = ""

    public init(store: WatchlistStore, alertStore: AlertStore) {
        self.store = store
        self.alertStore = alertStore
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
                    .foregroundStyle(CortexDesign.profit)
                Text("Open Positions")
                    .font(.headline)
                Spacer()
                let pnl = store.totalUnrealizedPnL
                Text(String(format: "%@$%.2f", pnl >= 0 ? "+" : "", pnl))
                    .font(.headline)
                    .foregroundStyle(pnl >= 0 ? CortexDesign.profit : CortexDesign.loss)
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

    // MARK: - Alerts View

    @ViewBuilder
    private var alertsPlaceholder: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(CortexDesign.accentPrimary)
                Text("Price Alerts")
                    .font(.headline)
                Spacer()
                Text("\(alertStore.activeAlerts.count) active")
                    .font(CortexDesign.labelFont)
                    .foregroundStyle(.secondary)

                Button(action: { showCreateAlert.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12))
                        Text("New Alert")
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
            }
            .padding()

            Divider()

            // Create Alert Form
            if showCreateAlert {
                createAlertForm
                Divider()
            }

            // Triggered Alerts Section
            if !alertStore.triggeredAlerts.isEmpty {
                triggeredAlertsSection
                Divider()
            }

            // Active Alerts List
            if alertStore.activeAlerts.isEmpty && alertStore.triggeredAlerts.isEmpty {
                alertsEmptyState
            } else {
                activeAlertsSection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CortexDesign.bgDeepest)
    }

    @ViewBuilder
    private var createAlertForm: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                TextField("Symbol", text: $alertSymbol)
                    .textFieldStyle(.plain)
                    .font(CortexDesign.dataFont)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(width: 100)
                    .background(
                        RoundedRectangle(cornerRadius: CortexDesign.badgeRadius)
                            .fill(CortexDesign.bgElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CortexDesign.badgeRadius)
                            .strokeBorder(CortexDesign.border, lineWidth: 1)
                    )

                Picker("Type", selection: $alertTypeSelection) {
                    Text("Price Above").tag(PriceAlert.AlertType.priceAbove)
                    Text("Price Below").tag(PriceAlert.AlertType.priceBelow)
                    Text("% Change").tag(PriceAlert.AlertType.pctChange)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                TextField(alertTypeSelection == .pctChange ? "%" : "$", text: $alertThreshold)
                    .textFieldStyle(.plain)
                    .font(CortexDesign.dataFont)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(width: 100)
                    .background(
                        RoundedRectangle(cornerRadius: CortexDesign.badgeRadius)
                            .fill(CortexDesign.bgElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CortexDesign.badgeRadius)
                            .strokeBorder(CortexDesign.border, lineWidth: 1)
                    )

                Button(action: submitAlert) {
                    Text("Create")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CortexDesign.accentPrimary)
                        .padding(.horizontal, 16)
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
                .disabled(alertSymbol.isEmpty || alertThreshold.isEmpty)
            }
        }
        .padding()
        .background(CortexDesign.bgCard)
    }

    private func submitAlert() {
        let sym = alertSymbol.trimmingCharacters(in: .whitespaces)
        guard !sym.isEmpty, let thresh = Double(alertThreshold) else { return }
        alertStore.createAlert(symbol: sym, type: alertTypeSelection, threshold: thresh)
        alertSymbol = ""
        alertThreshold = ""
        showCreateAlert = false
    }

    @ViewBuilder
    private var triggeredAlertsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(CortexDesign.warning)
                Text("Triggered")
                    .font(CortexDesign.sectionFont)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 10)

            ForEach(alertStore.triggeredAlerts) { alert in
                AlertRow(alert: alert, isTriggered: true) {
                    alertStore.dismissAlert(id: alert.id)
                } onDelete: {
                    alertStore.deleteAlert(id: alert.id)
                }
            }
        }
    }

    @ViewBuilder
    private var activeAlertsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !alertStore.activeAlerts.isEmpty {
                HStack {
                    Image(systemName: "bell.fill")
                        .foregroundStyle(CortexDesign.accentPrimary)
                    Text("Active")
                        .font(CortexDesign.sectionFont)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 10)
            }

            List {
                ForEach(alertStore.activeAlerts) { alert in
                    AlertRow(alert: alert, isTriggered: false, onDismiss: nil) {
                        alertStore.deleteAlert(id: alert.id)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var alertsEmptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "bell.badge")
                .font(.system(size: 40))
                .foregroundStyle(CortexDesign.neutral)

            Text("No Active Alerts")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.secondary)

            Text("Create price alerts to get notified\nwhen symbols hit your target levels.")
                .font(.system(size: 12))
                .foregroundStyle(CortexDesign.neutral)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Order History Placeholder

    @ViewBuilder
    private var orderHistoryPlaceholder: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundStyle(CortexDesign.border)

            Text("Order History")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(CortexDesign.neutral)

            Text("Recent order executions will appear here.\nAll filled, cancelled, and pending orders are logged.")
                .font(.system(size: 12))
                .foregroundStyle(CortexDesign.neutral)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CortexDesign.bgDeepest)
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
            .foregroundStyle(item.change >= 0 ? CortexDesign.profit : CortexDesign.loss)
            .frame(width: 90, alignment: .trailing)

            Text(formatVolume(item.volume))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            if let rsi = item.rsi {
                Text(String(format: "%.1f", rsi))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(rsi > 70 ? CortexDesign.loss : rsi < 30 ? CortexDesign.profit : .primary)
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
        case "buy": return CortexDesign.profit
        case "sell": return CortexDesign.loss
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
                    .background(position.side == "long" ? CortexDesign.profit.opacity(0.2) : CortexDesign.loss.opacity(0.2))
                    .foregroundStyle(position.side == "long" ? CortexDesign.profit : CortexDesign.loss)
                    .clipShape(Capsule())
                Spacer()
                Text(String(format: "%@$%.2f", position.unrealizedPnL >= 0 ? "+" : "", position.unrealizedPnL))
                    .font(.body.bold().monospacedDigit())
                    .foregroundStyle(position.unrealizedPnL >= 0 ? CortexDesign.profit : CortexDesign.loss)
            }

            HStack {
                Label("\(position.quantity) shares", systemImage: "number")
                Spacer()
                Text(String(format: "Entry: $%.2f", position.entryPrice))
                Spacer()
                Text(String(format: "Current: $%.2f", position.currentPrice))
                Spacer()
                Text(String(format: "Stop: $%.2f", position.stopLoss))
                    .foregroundStyle(CortexDesign.loss)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct AlertRow: View {
    let alert: PriceAlert
    let isTriggered: Bool
    var onDismiss: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            // Alert type icon
            Image(systemName: isTriggered ? "bell.and.waves.left.and.right.fill" : "bell.fill")
                .font(.system(size: 14))
                .foregroundStyle(isTriggered ? CortexDesign.warning : CortexDesign.accentPrimary)
                .frame(width: 24)

            // Alert info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(alert.symbol)
                        .font(.body.bold())
                    Text(alertTypeLabel)
                        .font(CortexDesign.badgeFont)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(alertTypeBadgeColor.opacity(0.15))
                        .foregroundStyle(alertTypeBadgeColor)
                        .clipShape(Capsule())
                }

                if isTriggered && !alert.message.isEmpty {
                    Text(alert.message)
                        .font(.caption)
                        .foregroundStyle(CortexDesign.warning)
                } else {
                    Text(thresholdDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Actions
            if isTriggered {
                if let onDismiss {
                    Button(action: onDismiss) {
                        Text("Dismiss")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: CortexDesign.badgeRadius)
                                    .fill(CortexDesign.bgElevated)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(CortexDesign.loss.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(isTriggered ? CortexDesign.warning.opacity(0.05) : .clear)
    }

    private var alertTypeLabel: String {
        switch alert.alertType {
        case .priceAbove: return "ABOVE"
        case .priceBelow: return "BELOW"
        case .pctChange: return "% CHG"
        }
    }

    private var alertTypeBadgeColor: Color {
        switch alert.alertType {
        case .priceAbove: return CortexDesign.profit
        case .priceBelow: return CortexDesign.loss
        case .pctChange: return CortexDesign.accentPrimary
        }
    }

    private var thresholdDescription: String {
        switch alert.alertType {
        case .priceAbove:
            return "Trigger when price >= $\(String(format: "%.2f", alert.threshold))"
        case .priceBelow:
            return "Trigger when price <= $\(String(format: "%.2f", alert.threshold))"
        case .pctChange:
            return "Trigger when price moves \(String(format: "%.1f", alert.threshold))%"
        }
    }
}
