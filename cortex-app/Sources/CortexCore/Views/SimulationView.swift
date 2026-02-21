import SwiftUI

/// Simulation View -- Paper trading simulation with equity curve, stats,
/// learning insights, and controls.
public struct SimulationView: View {
    let store: SimulationStore

    public init(store: SimulationStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider().overlay(CortexDesign.border)

            ScrollView {
                VStack(spacing: 16) {
                    statsGrid
                    equityCurveSection
                    tradeLogSection
                    insightsSection
                }
                .padding(16)
            }
        }
        .background(CortexDesign.bgDeepest)
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(store.isRunning ? CortexDesign.profit : CortexDesign.accentPrimary)

            Text("SIMULATION")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            if store.isRunning {
                HStack(spacing: 4) {
                    Circle()
                        .fill(CortexDesign.profit)
                        .frame(width: 6, height: 6)
                    Text("RUNNING")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(CortexDesign.profit)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(CortexDesign.profit.opacity(0.1))
                )
            }

            Spacer()

            // Speed selector
            HStack(spacing: 4) {
                Text("SPEED:")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                ForEach(SimulationStore.SimulationSpeed.allCases, id: \.self) { speed in
                    Button(action: { store.setSpeed(speed) }) {
                        Text(speed.rawValue)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(store.speed == speed
                                          ? CortexDesign.accentPrimary.opacity(0.15)
                                          : CortexDesign.bgHover)
                            )
                            .foregroundStyle(store.speed == speed ? CortexDesign.accentPrimary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Control buttons
            HStack(spacing: 6) {
                if store.isRunning {
                    Button(action: { store.stop() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10))
                            Text("Stop")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(CortexDesign.loss)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(CortexDesign.loss.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(CortexDesign.loss.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: { store.start() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                            Text("Start")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(CortexDesign.profit)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(CortexDesign.profit.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(CortexDesign.profit.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Button(action: { store.reset() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10))
                        Text("Reset")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(CortexDesign.bgHover)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(CortexDesign.bgElevated, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(CortexDesign.bgCard)
    }

    // MARK: - Stats Grid

    private var statsGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible()),
        ], spacing: 8) {
            simStatCard("Equity", String(format: "$%.0f", store.currentEquity), .white)
            simStatCard("Total P&L", CortexDesign.pnlString(store.totalPnL), CortexDesign.pnlColor(store.totalPnL))
            simStatCard("Return", CortexDesign.pctString(store.returnPercent), CortexDesign.pnlColor(store.returnPercent))
            simStatCard("Win Rate", String(format: "%.1f%%", store.winRate), winRateColor)
            simStatCard("Max DD", String(format: "%.1f%%", store.maxDrawdown), drawdownColor)
            simStatCard("Sharpe", String(format: "%.2f", store.sharpeRatio), sharpeColor)
        }
    }

    private func simStatCard(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                .fill(CortexDesign.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                .strokeBorder(CortexDesign.border, lineWidth: 1)
        )
    }

    // MARK: - Equity Curve

    private var equityCurveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 10))
                    .foregroundStyle(CortexDesign.accentPrimary)
                Text("EQUITY CURVE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                if !store.equityCurve.isEmpty {
                    Text("\(store.equityCurve.count) points")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            if store.equityCurve.isEmpty {
                RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                    .fill(CortexDesign.bgCard)
                    .frame(height: 200)
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 24))
                                .foregroundStyle(CortexDesign.border)
                            Text("Start a simulation to see the equity curve")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                            .strokeBorder(CortexDesign.border, lineWidth: 1)
                    )
            } else {
                equityCurveChart
            }
        }
    }

    private var equityCurveChart: some View {
        let points = store.equityCurve
        let minEq = points.map(\.equity).min() ?? 0
        let maxEq = points.map(\.equity).max() ?? 0
        let eqRange = max(maxEq - minEq, 1)

        return GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            ZStack {
                RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                    .fill(CortexDesign.bgCard)

                // Starting capital line
                if eqRange > 0 {
                    let startY = height - ((store.startingCapital - minEq) / eqRange) * height
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: startY))
                        path.addLine(to: CGPoint(x: width, y: startY))
                    }
                    .stroke(CortexDesign.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }

                // Equity curve fill
                if points.count > 1 {
                    let isProfit = store.currentEquity >= store.startingCapital

                    // Fill area
                    Path { path in
                        for (i, point) in points.enumerated() {
                            let x = (CGFloat(i) / CGFloat(points.count - 1)) * width
                            let y = height - ((point.equity - minEq) / eqRange) * height
                            if i == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                        path.addLine(to: CGPoint(x: width, y: height))
                        path.addLine(to: CGPoint(x: 0, y: height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [
                                (isProfit ? CortexDesign.profit : CortexDesign.loss).opacity(0.15),
                                Color.clear,
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    // Line
                    Path { path in
                        for (i, point) in points.enumerated() {
                            let x = (CGFloat(i) / CGFloat(points.count - 1)) * width
                            let y = height - ((point.equity - minEq) / eqRange) * height
                            if i == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(isProfit ? CortexDesign.profit : CortexDesign.loss, lineWidth: 2)
                }
            }
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: CortexDesign.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                .strokeBorder(CortexDesign.border, lineWidth: 1)
        )
    }

    // MARK: - Trade Log

    private var tradeLogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "list.number")
                    .font(.system(size: 10))
                    .foregroundStyle(CortexDesign.accentPrimary)
                Text("TRADE LOG")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                HStack(spacing: 12) {
                    Text("\(store.totalTrades) trades")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 4) {
                        Text("W: \(store.winningTrades)")
                            .foregroundStyle(CortexDesign.profit)
                        Text("L: \(store.losingTrades)")
                            .foregroundStyle(CortexDesign.loss)
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                }
            }

            if store.trades.isEmpty {
                RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                    .fill(CortexDesign.bgCard)
                    .frame(height: 80)
                    .overlay(
                        Text("No simulation trades yet")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                            .strokeBorder(CortexDesign.border, lineWidth: 1)
                    )
            } else {
                VStack(spacing: 0) {
                    // Headers
                    HStack(spacing: 0) {
                        Text("Symbol").frame(width: 70, alignment: .leading)
                        Text("Side").frame(width: 50, alignment: .center)
                        Text("Qty").frame(width: 50, alignment: .trailing)
                        Text("Entry").frame(width: 80, alignment: .trailing)
                        Text("Exit").frame(width: 80, alignment: .trailing)
                        Text("P&L").frame(width: 90, alignment: .trailing)
                        Spacer()
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(CortexDesign.bgCard)

                    ForEach(store.trades.suffix(20).reversed()) { trade in
                        tradeRow(trade)
                        Divider().overlay(CortexDesign.bgDeepest)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                        .fill(CortexDesign.bgCard)
                )
                .clipShape(RoundedRectangle(cornerRadius: CortexDesign.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                        .strokeBorder(CortexDesign.border, lineWidth: 1)
                )
            }
        }
    }

    private func tradeRow(_ trade: SimulationTrade) -> some View {
        HStack(spacing: 0) {
            Text(trade.symbol)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 70, alignment: .leading)

            Text(trade.side)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(trade.side == "BUY" ? CortexDesign.profit : CortexDesign.loss)
                .frame(width: 50, alignment: .center)

            Text("\(trade.quantity)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 50, alignment: .trailing)

            Text(String(format: "$%.2f", trade.entryPrice))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            Text(trade.exitPrice.map { String(format: "$%.2f", $0) } ?? "--")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            Group {
                if let pnl = trade.pnl {
                    Text(CortexDesign.pnlString(pnl))
                        .foregroundStyle(CortexDesign.pnlColor(pnl))
                } else {
                    Text("--")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .frame(width: 90, alignment: .trailing)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Learning Insights

    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
                Text("LEARNING INSIGHTS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(store.insights.count) insights")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if store.insights.isEmpty {
                RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                    .fill(CortexDesign.bgCard)
                    .frame(height: 80)
                    .overlay(
                        VStack(spacing: 4) {
                            Image(systemName: "lightbulb")
                                .font(.system(size: 16))
                                .foregroundStyle(CortexDesign.border)
                            Text("AI learning insights will appear as the simulation runs")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                            .strokeBorder(CortexDesign.border, lineWidth: 1)
                    )
            } else {
                ForEach(store.insights) { insight in
                    insightCard(insight)
                }
            }
        }
    }

    private func insightCard(_ insight: LearningInsight) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                categoryBadge(insight.category)

                Text(insight.title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()

                // Confidence indicator
                HStack(spacing: 4) {
                    Text("Conf:")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(String(format: "%.0f%%", insight.confidence * 100))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(confidenceColor(insight.confidence))
                }
            }

            Text(insight.description)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.75))
                .lineSpacing(3)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                .fill(CortexDesign.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                .strokeBorder(insightBorderColor(insight.category), lineWidth: 1)
        )
    }

    private func categoryBadge(_ category: String) -> some View {
        let (icon, color): (String, Color) = switch category {
        case "pattern": ("waveform.path.ecg", .blue)
        case "risk": ("exclamationmark.triangle.fill", .orange)
        case "timing": ("clock.fill", .cyan)
        case "strategy": ("lightbulb.fill", .yellow)
        default: ("circle.fill", .gray)
        }

        return HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(category.capitalized)
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(color.opacity(0.1))
        )
    }

    // MARK: - Color Helpers

    private var winRateColor: Color {
        if store.winRate >= 60 { return CortexDesign.profit }
        if store.winRate >= 40 { return CortexDesign.warning }
        return CortexDesign.loss
    }

    private var drawdownColor: Color {
        if store.maxDrawdown < 5 { return CortexDesign.profit }
        if store.maxDrawdown < 15 { return CortexDesign.warning }
        return CortexDesign.loss
    }

    private var sharpeColor: Color {
        if store.sharpeRatio >= 1.5 { return CortexDesign.profit }
        if store.sharpeRatio >= 0.5 { return CortexDesign.warning }
        return CortexDesign.loss
    }

    private func confidenceColor(_ value: Double) -> Color {
        if value >= 0.7 { return CortexDesign.profit }
        if value >= 0.4 { return CortexDesign.warning }
        return CortexDesign.loss
    }

    private func insightBorderColor(_ category: String) -> Color {
        switch category {
        case "pattern": return .blue.opacity(0.2)
        case "risk": return CortexDesign.warning.opacity(0.2)
        case "timing": return CortexDesign.accentPrimary.opacity(0.2)
        case "strategy": return .yellow.opacity(0.2)
        default: return CortexDesign.border
        }
    }
}
