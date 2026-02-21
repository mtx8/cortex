import SwiftUI
import Charts

public struct PerformanceDashboardView: View {
    let store: PerformanceStore
    @Environment(\.cortexSelectedSection) private var selectedSection

    public init(store: PerformanceStore) {
        self.store = store
    }

    public var body: some View {
        switch selectedSection {
        case "Equity Curve":
            equityCurveFullView
        case "Trade Log":
            tradeLogPlaceholder
        case "Tax Report":
            taxReportPlaceholder
        default: // "Dashboard"
            dashboardView
        }
    }

    // MARK: - Dashboard (default full view)

    @ViewBuilder
    private var dashboardView: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Stats grid
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 16) {
                    StatCard(title: "Win Rate", value: String(format: "%.1f%%", store.winRate * 100))
                    StatCard(title: "Total Trades", value: "\(store.totalTrades)")
                    StatCard(title: "Best Day", value: String(format: "$%.2f", store.bestDay))
                    StatCard(title: "Worst Day", value: String(format: "$%.2f", store.worstDay))
                    StatCard(title: "Avg Daily P&L", value: String(format: "$%.2f", store.averageDailyPnL))
                    StatCard(title: "Max Drawdown", value: String(format: "%.1f%%", store.maxDrawdownPct))
                    StatCard(title: "Streak", value: "\(store.currentStreak)")
                    StatCard(title: "W/L", value: "\(store.winningTrades)/\(store.losingTrades)")
                }
                .padding(.horizontal)

                // Equity curve
                if !store.equityCurve.isEmpty {
                    GroupBox("Equity Curve") {
                        Chart(store.equityCurve) { point in
                            LineMark(x: .value("Date", point.date), y: .value("Value", point.value))
                                .foregroundStyle(.blue)
                        }
                        .frame(height: 200)
                    }
                    .padding(.horizontal)
                }

                // Daily P&L bar chart
                if !store.dailyPnL.isEmpty {
                    GroupBox("Daily P&L") {
                        Chart(store.dailyPnL) { point in
                            BarMark(x: .value("Date", point.date), y: .value("P&L", point.pnl))
                                .foregroundStyle(point.isPositive ? CortexDesign.profit : CortexDesign.loss)
                        }
                        .frame(height: 200)
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
    }

    // MARK: - Equity Curve (expanded)

    @ViewBuilder
    private var equityCurveFullView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("EQUITY CURVE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)

                Spacer()

                if !store.equityCurve.isEmpty {
                    Text("\(store.equityCurve.count) data points")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(CortexDesign.neutral)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if store.equityCurve.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 40))
                        .foregroundStyle(CortexDesign.border)

                    Text("No Equity Data")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(CortexDesign.neutral)

                    Text("Equity curve will populate as trades are executed")
                        .font(.system(size: 12))
                        .foregroundStyle(CortexDesign.neutral)
                }
                Spacer()
            } else {
                Chart(store.equityCurve) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Value", point.value))
                        .foregroundStyle(.blue)
                    AreaMark(x: .value("Date", point.date), y: .value("Value", point.value))
                        .foregroundStyle(.blue.opacity(0.1))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .background(CortexDesign.bgDeepest)
    }

    // MARK: - Trade Log Placeholder

    @ViewBuilder
    private var tradeLogPlaceholder: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "list.number")
                .font(.system(size: 40))
                .foregroundStyle(CortexDesign.border)

            Text("Trade Log")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(CortexDesign.neutral)

            Text("Trade history will appear here when trades are executed.\nAll entries, exits, and partial fills are recorded.")
                .font(.system(size: 12))
                .foregroundStyle(CortexDesign.neutral)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CortexDesign.bgDeepest)
    }

    // MARK: - Tax Report Placeholder

    @ViewBuilder
    private var taxReportPlaceholder: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundStyle(CortexDesign.border)

            Text("Tax Report")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(CortexDesign.neutral)

            Text("Tax-optimized trade reporting coming soon.\nTracks wash sales, short/long term capital gains,\nand generates IRS-ready reports.")
                .font(.system(size: 12))
                .foregroundStyle(CortexDesign.neutral)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CortexDesign.bgDeepest)
    }
}

struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.quaternary)
        .cornerRadius(8)
    }
}
