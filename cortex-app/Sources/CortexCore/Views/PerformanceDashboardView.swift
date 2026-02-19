import SwiftUI
import Charts

public struct PerformanceDashboardView: View {
    let store: PerformanceStore

    public init(store: PerformanceStore) {
        self.store = store
    }

    public var body: some View {
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
                                .foregroundStyle(point.isPositive ? .green : .red)
                        }
                        .frame(height: 200)
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
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
