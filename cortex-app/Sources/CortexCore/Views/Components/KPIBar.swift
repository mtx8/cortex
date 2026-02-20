import SwiftUI

// MARK: - Mini Sparkline Shape

/// A lightweight line-chart shape drawn from an array of values.
/// Used behind KPI card values to show trend direction at a glance.
private struct Sparkline: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        guard values.count > 1 else { return Path() }
        var path = Path()
        let step = rect.width / CGFloat(values.count - 1)
        let minVal = values.min() ?? 0
        let maxVal = values.max() ?? 1
        let range = maxVal - minVal > 0 ? maxVal - minVal : 1

        for (i, val) in values.enumerated() {
            let x = CGFloat(i) * step
            let y = rect.height - ((CGFloat(val - minVal) / CGFloat(range)) * rect.height)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

// MARK: - Sample Sparkline Data

/// Static sample sparkline data for each KPI card.
/// In production these will be replaced with real 7-day time-series from the backend.
private enum SparklineData {
    static let nav: [Double]         = [48.2, 48.8, 49.1, 49.0, 49.6, 50.0, 50.2]
    static let dailyPnL: [Double]    = [120, 85, -40, 160, 210, 180, 234]
    static let weeklyPnL: [Double]   = [400, 520, 480, 610, 590, 720, 750]
    static let monthlyPnL: [Double]  = [1200, 1800, 2100, 2400, 2800, 3100, 3450]
    static let buyingPower: [Double] = [49.0, 48.5, 48.8, 49.2, 48.9, 48.7, 48.8]
    static let margin: [Double]      = [2.0, 2.5, 2.8, 3.0, 2.6, 2.4, 2.4]
    static let dailyReturn: [Double] = [0.24, 0.17, -0.08, 0.32, 0.42, 0.36, 0.47]
    static let winRate: [Double]     = [58, 60, 62, 64, 65, 66, 67]
}

/// Animated KPI strip displaying 8 key portfolio metrics as individual cards.
/// Uses monospaced digits, color-coded accent bars, numeric content transitions,
/// and faded mini sparkline charts showing 7-point trend data.
@MainActor
public struct KPIBar: View {
    let portfolio: PortfolioStore

    public init(portfolio: PortfolioStore) {
        self.portfolio = portfolio
    }

    public var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
            kpiCard(
                label: "NAV",
                value: formatCurrency(portfolio.nav),
                changeText: nil,
                accentColor: .cyan,
                valueColor: .white,
                sparklineValues: SparklineData.nav
            )
            kpiCard(
                label: "DAILY P&L",
                value: formatSignedCurrency(portfolio.dailyPnL),
                changeText: changePercent(portfolio.dailyPnL, base: portfolio.nav),
                accentColor: pnlColor(portfolio.dailyPnL),
                valueColor: pnlColor(portfolio.dailyPnL),
                sparklineValues: SparklineData.dailyPnL
            )
            kpiCard(
                label: "WEEKLY P&L",
                value: formatSignedCurrency(weeklyPnL),
                changeText: changePercent(weeklyPnL, base: portfolio.nav),
                accentColor: pnlColor(weeklyPnL),
                valueColor: pnlColor(weeklyPnL),
                sparklineValues: SparklineData.weeklyPnL
            )
            kpiCard(
                label: "MONTHLY P&L",
                value: formatSignedCurrency(monthlyPnL),
                changeText: changePercent(monthlyPnL, base: portfolio.nav),
                accentColor: pnlColor(monthlyPnL),
                valueColor: pnlColor(monthlyPnL),
                sparklineValues: SparklineData.monthlyPnL
            )
            kpiCard(
                label: "BUYING POWER",
                value: formatCurrency(portfolio.buyingPower),
                changeText: nil,
                accentColor: .cyan,
                valueColor: .white,
                sparklineValues: SparklineData.buyingPower
            )
            kpiCard(
                label: "MARGIN %",
                value: String(format: "%.1f%%", marginPercent),
                changeText: nil,
                accentColor: marginPercent > 80 ? .red : marginPercent > 60 ? .orange : .cyan,
                valueColor: marginPercent > 80 ? .red : marginPercent > 60 ? .orange : .white,
                sparklineValues: SparklineData.margin
            )
            kpiCard(
                label: "DAILY RETURN",
                value: String(format: "%@%.2f%%", dailyReturnPct >= 0 ? "+" : "", dailyReturnPct),
                changeText: nil,
                accentColor: pnlColor(dailyReturnPct),
                valueColor: pnlColor(dailyReturnPct),
                sparklineValues: SparklineData.dailyReturn
            )
            kpiCard(
                label: "WIN RATE",
                value: String(format: "%.1f%%", portfolio.winRate * 100),
                changeText: nil,
                accentColor: portfolio.winRate >= 0.6 ? .green : portfolio.winRate >= 0.4 ? .cyan : .red,
                valueColor: portfolio.winRate >= 0.6 ? .green : portfolio.winRate >= 0.4 ? .white : .red,
                sparklineValues: SparklineData.winRate
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - KPI Card

    private func kpiCard(
        label: String,
        value: String,
        changeText: String?,
        accentColor: Color,
        valueColor: Color,
        sparklineValues: [Double]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Accent bar at top
            Rectangle()
                .fill(accentColor)
                .frame(height: 2)
                .frame(maxWidth: .infinity)

            ZStack(alignment: .leading) {
                // Faded sparkline behind the value area
                Sparkline(values: sparklineValues)
                    .stroke(
                        LinearGradient(
                            colors: [accentColor.opacity(0.05), accentColor.opacity(0.2)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: 1.5
                    )
                    .padding(.horizontal, 4)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(white: 0.4))
                        .tracking(0.5)

                    Text(value)
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(valueColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.3), value: value)

                    if let changeText = changeText {
                        Text(changeText)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(changeText.hasPrefix("-") ? Color.red : Color.green)
                    } else {
                        // Spacer to maintain consistent height
                        Text(" ")
                            .font(.system(size: 10, weight: .medium))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
        }
        .frame(height: 72)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(white: 0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
        value > 0 ? .green : value < 0 ? .red : .white
    }

    private func changePercent(_ value: Double, base: Double) -> String {
        guard base > 0 else { return "+0.0%" }
        let pct = (value / base) * 100
        return String(format: "%@%.1f%%", pct >= 0 ? "+" : "", pct)
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
