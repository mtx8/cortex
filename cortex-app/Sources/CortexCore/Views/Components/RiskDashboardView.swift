import SwiftUI

/// Risk Dashboard panel showing drawdown gauge, Value at Risk, and kill switch status.
/// Designed for the War Room right column in the 3-column layout.
@MainActor
public struct RiskDashboardView: View {
    let portfolio: PortfolioStore
    let killSwitch: KillSwitchStore
    let settings: SettingsStore

    public init(portfolio: PortfolioStore, killSwitch: KillSwitchStore, settings: SettingsStore) {
        self.portfolio = portfolio
        self.killSwitch = killSwitch
        self.settings = settings
    }

    /// Current drawdown percentage based on daily P&L vs max drawdown threshold.
    private var drawdownPct: Double {
        guard settings.maxDrawdownPct > 0 else { return 0 }
        let currentDrawdown = portfolio.dailyPnL < 0 ? abs(portfolio.dailyPnL / portfolio.nav) * 100 : 0
        return min(currentDrawdown / settings.maxDrawdownPct, 1.0)
    }

    /// Display value for current drawdown.
    private var currentDrawdownDisplay: Double {
        portfolio.dailyPnL < 0 ? abs(portfolio.dailyPnL / max(portfolio.nav, 1)) * 100 : 0
    }

    /// Simulated Value at Risk (in production, calculated by risk engine).
    private var valueAtRisk: Double {
        portfolio.nav * 0.018
    }

    /// Drawdown gauge color based on severity.
    private var drawdownColor: Color {
        if drawdownPct > 0.75 { return .red }
        if drawdownPct > 0.50 { return .orange }
        if drawdownPct > 0.25 { return .yellow }
        return .green
    }

    public var body: some View {
        VStack(spacing: 12) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(CortexDesign.accentPrimary)
                Text("RISK DASHBOARD")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.5))
                Spacer()
            }

            // Drawdown circular gauge
            drawdownGauge

            Divider()
                .overlay(Color(white: 0.10))

            // VaR display
            varDisplay

            Divider()
                .overlay(Color(white: 0.10))

            // Risk limit metrics
            riskLimitsSection

            Divider()
                .overlay(Color(white: 0.10))

            // Kill switch status
            killSwitchStatus

            Spacer(minLength: 0)
        }
        .padding(CortexDesign.cardPadding)
        .background(CortexDesign.cardBackground())
    }

    // MARK: - Drawdown Gauge

    @ViewBuilder
    private var drawdownGauge: some View {
        VStack(spacing: 8) {
            ZStack {
                // Background track
                Circle()
                    .stroke(Color(white: 0.12), lineWidth: 8)
                    .frame(width: 90, height: 90)

                // Progress arc
                Circle()
                    .trim(from: 0, to: drawdownPct)
                    .stroke(
                        AngularGradient(
                            colors: [drawdownColor.opacity(0.4), drawdownColor],
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360 * drawdownPct)
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 90, height: 90)
                    .animation(.easeInOut(duration: 0.5), value: drawdownPct)

                // Center text
                VStack(spacing: 2) {
                    Text(String(format: "%.1f%%", currentDrawdownDisplay))
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(drawdownColor)
                        .contentTransition(.numericText())

                    Text("DRAWDOWN")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(white: 0.35))
                }
            }

            // Max drawdown threshold label
            HStack(spacing: 4) {
                Text("Limit:")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(white: 0.35))
                Text(String(format: "%.1f%%", settings.maxDrawdownPct))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.5))
            }
        }
    }

    // MARK: - Value at Risk Display

    @ViewBuilder
    private var varDisplay: some View {
        VStack(spacing: 6) {
            HStack {
                Text("VALUE AT RISK (1D)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.4))
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "$%.0f", valueAtRisk))
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(.orange)
                    .contentTransition(.numericText())

                Text("95% CI")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(white: 0.35))

                Spacer()
            }

            // VaR as percentage of NAV
            HStack {
                Text(String(format: "%.2f%% of NAV", portfolio.nav > 0 ? (valueAtRisk / portfolio.nav) * 100 : 0))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(white: 0.4))
                Spacer()
            }
        }
    }

    // MARK: - Risk Limits Section

    @ViewBuilder
    private var riskLimitsSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("RISK LIMITS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.4))
                Spacer()
            }

            riskLimitRow(
                label: "Max Daily Loss",
                current: abs(min(portfolio.dailyPnL, 0)),
                limit: settings.maxDailyLoss,
                color: .orange
            )

            riskLimitRow(
                label: "Max Notional",
                current: portfolio.nav - portfolio.buyingPower,
                limit: settings.maxNotional,
                color: .yellow
            )

            riskLimitRow(
                label: "Position Count",
                current: Double(portfolio.openPositionCount),
                limit: 20,
                color: .cyan
            )
        }
    }

    @ViewBuilder
    private func riskLimitRow(label: String, current: Double, limit: Double, color: Color) -> some View {
        let utilization = limit > 0 ? min(current / limit, 1.0) : 0

        VStack(spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(white: 0.45))
                Spacer()
                Text(String(format: "%.0f%%", utilization * 100))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(utilization > 0.8 ? .red : utilization > 0.5 ? .orange : color)
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(white: 0.10))
                        .frame(height: 3)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(utilization > 0.8 ? Color.red : utilization > 0.5 ? Color.orange : color)
                        .frame(width: geo.size.width * utilization, height: 3)
                        .animation(.easeInOut(duration: 0.4), value: utilization)
                }
            }
            .frame(height: 3)
        }
    }

    // MARK: - Kill Switch Status

    @ViewBuilder
    private var killSwitchStatus: some View {
        HStack(spacing: 8) {
            // Animated pulsing status dot
            KillSwitchPulse(isActive: killSwitch.isActive)

            VStack(alignment: .leading, spacing: 2) {
                Text("KILL SWITCH")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.4))

                Text(killSwitch.isActive ? "ENGAGED" : "STANDBY")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(killSwitch.isActive ? .red : .green)
            }

            Spacer()

            // Autonomy level badge
            Text(settings.autonomyLevel.label.uppercased())
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(autonomyColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(autonomyColor.opacity(0.12))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(autonomyColor.opacity(0.3), lineWidth: 1)
                )
        }
    }

    private var autonomyColor: Color {
        switch settings.autonomyLevel {
        case .fullManual: return .cyan
        case .suggestOnly: return .blue
        case .semiAuto: return .orange
        case .fullAuto: return .red
        }
    }
}

// MARK: - Kill Switch Pulsing Indicator

/// Animated pulsing dot that indicates kill switch status.
/// Green pulsing glow when standby, red rapid pulse when engaged.
private struct KillSwitchPulse: View {
    let isActive: Bool
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.6

    var body: some View {
        ZStack {
            // Outer pulse ring
            Circle()
                .fill(isActive ? Color.red : Color.green)
                .frame(width: 20, height: 20)
                .opacity(pulseOpacity * 0.3)
                .scaleEffect(pulseScale)

            // Inner solid dot
            Circle()
                .fill(isActive ? Color.red : Color.green)
                .frame(width: 10, height: 10)
                .shadow(color: (isActive ? Color.red : Color.green).opacity(0.5), radius: 4)
        }
        .onAppear {
            let duration = isActive ? 0.6 : 2.0
            withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
                pulseScale = 1.4
                pulseOpacity = 0.15
            }
        }
        .onChange(of: isActive) {
            pulseScale = 1.0
            pulseOpacity = 0.6
            let duration = isActive ? 0.6 : 2.0
            withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
                pulseScale = 1.4
                pulseOpacity = 0.15
            }
        }
    }
}
