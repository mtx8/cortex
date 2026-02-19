import SwiftUI

/// Horizontal strip displaying 8 key portfolio metrics.
/// Uses monospaced digits and green/red coloring for P&L values.
@MainActor
public struct KPIBar: View {
    let portfolio: PortfolioStore

    public init(portfolio: PortfolioStore) {
        self.portfolio = portfolio
    }

    public var body: some View {
        HStack(spacing: 0) {
            kpiItem(label: "NAV", value: formatCurrency(portfolio.nav))
            kpiDivider

            kpiItem(
                label: "Daily P&L",
                value: formatSignedCurrency(portfolio.dailyPnL),
                color: pnlColor(portfolio.dailyPnL)
            )
            kpiDivider

            kpiItem(
                label: "Weekly P&L",
                value: formatSignedCurrency(weeklyPnL),
                color: pnlColor(weeklyPnL)
            )
            kpiDivider

            kpiItem(
                label: "Monthly P&L",
                value: formatSignedCurrency(monthlyPnL),
                color: pnlColor(monthlyPnL)
            )
            kpiDivider

            kpiItem(label: "Buying Power", value: formatCurrency(portfolio.buyingPower))
            kpiDivider

            kpiItem(
                label: "Margin %",
                value: String(format: "%.1f%%", marginPercent),
                color: marginPercent > 80 ? .red : marginPercent > 60 ? .orange : .primary
            )
            kpiDivider

            kpiItem(
                label: "Daily Return",
                value: String(format: "%@%.2f%%", dailyReturnPct >= 0 ? "+" : "", dailyReturnPct),
                color: pnlColor(dailyReturnPct)
            )
            kpiDivider

            kpiItem(
                label: "Win Rate",
                value: String(format: "%.1f%%", portfolio.winRate * 100),
                color: portfolio.winRate >= 0.6 ? .green : portfolio.winRate >= 0.4 ? .primary : .red
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)))
    }

    // MARK: - KPI Item

    private func kpiItem(label: String, value: String, color: Color = .primary) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var kpiDivider: some View {
        Divider()
            .frame(height: 28)
            .overlay(Color(white: 0.2))
    }

    // MARK: - Computed Values

    /// Simulated weekly P&L (in production, comes from backend).
    private var weeklyPnL: Double {
        portfolio.dailyPnL * 3.2
    }

    /// Simulated monthly P&L.
    private var monthlyPnL: Double {
        portfolio.totalPnL
    }

    /// Margin usage percentage.
    private var marginPercent: Double {
        guard portfolio.nav > 0 else { return 0 }
        return ((portfolio.nav - portfolio.buyingPower) / portfolio.nav) * 100
    }

    /// Daily return percentage.
    private var dailyReturnPct: Double {
        guard portfolio.nav > 0 else { return 0 }
        return (portfolio.dailyPnL / portfolio.nav) * 100
    }

    // MARK: - Formatting

    private func pnlColor(_ value: Double) -> Color {
        value > 0 ? .green : value < 0 ? .red : .primary
    }

    private func formatCurrency(_ value: Double) -> String {
        if abs(value) >= 1_000_000 {
            return String(format: "$%.1fM", value / 1_000_000)
        }
        if abs(value) >= 1_000 {
            return String(format: "$%.0fK", value / 1_000)
        }
        return String(format: "$%.0f", value)
    }

    private func formatSignedCurrency(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : ""
        if abs(value) >= 1_000_000 {
            return String(format: "%@$%.1fM", sign, abs(value) / 1_000_000)
        }
        if abs(value) >= 1_000 {
            return String(format: "%@$%.1fK", sign, abs(value) / 1_000)
        }
        return String(format: "%@$%.0f", sign, abs(value))
    }
}
