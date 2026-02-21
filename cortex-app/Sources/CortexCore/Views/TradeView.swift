import SwiftUI

/// Trade View -- IBKR-style trading interface with chart, Level 2, order entry,
/// time & sales, positions, and simulation.
public struct TradeView: View {
    let environment: AppEnvironment
    @Environment(\.cortexSelectedSection) private var selectedSection
    @State private var activeTab: TradeTab = .chartL2

    public enum TradeTab: String, CaseIterable {
        case chartL2 = "Chart & L2"
        case positions = "Positions"
        case orders = "Orders"
        case simulation = "Simulation"
    }

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        VStack(spacing: 0) {
            switch activeTab {
            case .chartL2:
                chartAndL2View
            case .positions:
                positionsView
            case .orders:
                ordersView
            case .simulation:
                SimulationView(store: environment.simulation)
            }
        }
        .background(CortexDesign.bgDeepest)
        .onChange(of: selectedSection) { _, newSection in
            switch newSection {
            case "Chart & L2":
                activeTab = .chartL2
            case "Positions":
                activeTab = .positions
            case "Orders":
                activeTab = .orders
            case "Simulation":
                activeTab = .simulation
            default:
                break
            }
        }
    }

    // MARK: - Chart & L2 (main trading view)

    private var chartAndL2View: some View {
        HSplitView {
            // Left: Chart + Order panel at bottom
            VSplitView {
                ChartView(chatStore: environment.chat)
                    .frame(minHeight: 300)

                OrderPanelView(store: environment.trade)
                    .frame(minHeight: 200, idealHeight: 280)
            }
            .frame(minWidth: 500)

            // Right: Level 2 + Time & Sales
            VSplitView {
                Level2View(store: environment.level2)
                    .frame(minHeight: 200)

                TimeSalesView(store: environment.level2)
                    .frame(minHeight: 150)
            }
            .frame(minWidth: 240, idealWidth: 300, maxWidth: 400)
        }
    }

    // MARK: - Positions

    private var positionsView: some View {
        VStack(spacing: 0) {
            positionsHeader

            Divider().overlay(CortexDesign.border)

            if environment.trade.positions.isEmpty {
                emptyState(
                    icon: "briefcase",
                    title: "No Open Positions",
                    subtitle: "Positions from IBKR will appear here when connected."
                )
            } else {
                positionsTable
            }
        }
    }

    private var positionsHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "briefcase.fill")
                .font(.system(size: 14))
                .foregroundStyle(CortexDesign.accentPrimary)

            Text("Open Positions")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)

            Spacer()

            let pnl = environment.trade.totalUnrealizedPnL
            VStack(alignment: .trailing, spacing: 2) {
                Text("Unrealized P&L")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(CortexDesign.pnlString(pnl))
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(CortexDesign.pnlColor(pnl))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(CortexDesign.bgCard)
    }

    private var positionsTable: some View {
        VStack(spacing: 0) {
            // Column headers
            HStack(spacing: 0) {
                Text("Symbol").frame(width: 80, alignment: .leading)
                Text("Qty").frame(width: 60, alignment: .trailing)
                Text("Avg Price").frame(width: 90, alignment: .trailing)
                Text("Current").frame(width: 90, alignment: .trailing)
                Text("P&L").frame(width: 100, alignment: .trailing)
                Text("P&L %").frame(width: 80, alignment: .trailing)
                Spacer()
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(CortexDesign.bgCard)

            Divider().overlay(CortexDesign.border)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(environment.trade.positions) { position in
                        tradePositionRow(position)
                        Divider().overlay(CortexDesign.bgCard)
                    }
                }
            }
        }
    }

    private func tradePositionRow(_ position: TradePosition) -> some View {
        HStack(spacing: 0) {
            Text(position.symbol)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 80, alignment: .leading)

            Text("\(position.quantity)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 60, alignment: .trailing)

            Text(String(format: "$%.2f", position.avgPrice))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)

            Text(String(format: "$%.2f", position.currentPrice))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 90, alignment: .trailing)

            Text(CortexDesign.pnlString(position.unrealizedPnL))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(CortexDesign.pnlColor(position.unrealizedPnL))
                .frame(width: 100, alignment: .trailing)

            Text(CortexDesign.pctString(position.pnlPercent))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(CortexDesign.pnlColor(position.pnlPercent))
                .frame(width: 80, alignment: .trailing)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Orders

    private var ordersView: some View {
        VStack(spacing: 0) {
            ordersHeader

            Divider().overlay(CortexDesign.border)

            if environment.trade.orders.isEmpty {
                emptyState(
                    icon: "clock.arrow.circlepath",
                    title: "No Orders",
                    subtitle: "Submitted orders will appear here."
                )
            } else {
                ordersTable
            }
        }
    }

    private var ordersHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 14))
                .foregroundStyle(CortexDesign.accentPrimary)

            Text("Order History")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)

            Spacer()

            HStack(spacing: 12) {
                statBadge("Pending", count: environment.trade.pendingOrders.count, color: CortexDesign.warning)
                statBadge("Filled", count: environment.trade.filledOrders.count, color: CortexDesign.profit)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(CortexDesign.bgCard)
    }

    private func statBadge(_ label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    private var ordersTable: some View {
        VStack(spacing: 0) {
            // Column headers
            HStack(spacing: 0) {
                Text("Symbol").frame(width: 80, alignment: .leading)
                Text("Side").frame(width: 50, alignment: .center)
                Text("Qty").frame(width: 60, alignment: .trailing)
                Text("Type").frame(width: 70, alignment: .center)
                Text("Price").frame(width: 80, alignment: .trailing)
                Text("Status").frame(width: 80, alignment: .center)
                Spacer()
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(CortexDesign.bgCard)

            Divider().overlay(CortexDesign.border)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(environment.trade.orders.reversed()) { order in
                        orderRow(order)
                        Divider().overlay(CortexDesign.bgCard)
                    }
                }
            }
        }
    }

    private func orderRow(_ order: TradeOrder) -> some View {
        HStack(spacing: 0) {
            Text(order.symbol)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 80, alignment: .leading)

            Text(order.side)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(order.side == "BUY" ? CortexDesign.profit : CortexDesign.loss)
                .frame(width: 50, alignment: .center)

            Text("\(order.quantity)")
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 60, alignment: .trailing)
                .foregroundStyle(.white)

            Text(order.orderType)
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 70, alignment: .center)
                .foregroundStyle(.secondary)

            Group {
                if let price = order.limitPrice {
                    Text(String(format: "$%.2f", price))
                } else {
                    Text("MKT")
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .frame(width: 80, alignment: .trailing)
            .foregroundStyle(.secondary)

            statusBadge(order.status)
                .frame(width: 80, alignment: .center)

            Spacer()

            if order.status == "pending" {
                Button(action: { environment.trade.cancelOrder(orderId: order.id) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(CortexDesign.loss.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func statusBadge(_ status: String) -> some View {
        let color: Color = switch status {
        case "filled": CortexDesign.profit
        case "cancelled": CortexDesign.loss
        case "pending": CortexDesign.warning
        default: CortexDesign.neutral
        }

        return Text(status.capitalized)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.15))
            )
            .foregroundStyle(color)
    }

    // MARK: - Empty State

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(CortexDesign.border)

            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(CortexDesign.neutral)

            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(CortexDesign.neutral)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
