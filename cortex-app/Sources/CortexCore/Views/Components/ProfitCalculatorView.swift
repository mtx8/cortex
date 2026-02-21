import SwiftUI

/// Options profit/loss calculator with P&L chart, strategy legs,
/// and max profit/loss/breakeven display.
public struct ProfitCalculatorView: View {
    let store: OptionsStore

    public init(store: OptionsStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(CortexDesign.border)

            if store.selectedLegs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        statsBar
                        profitChart
                        legsList
                    }
                    .padding(16)
                }
            }
        }
        .background(CortexDesign.bgDeepest)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "function")
                .font(.system(size: 12))
                .foregroundStyle(CortexDesign.accentPrimary)

            Text("P&L CALCULATOR")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            if !store.selectedLegs.isEmpty {
                Button(action: { store.clearLegs() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                        Text("Clear")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(CortexDesign.loss.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(CortexDesign.loss.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(CortexDesign.bgCard)
    }

    // MARK: - Stats Bar

    private var statsBar: some View {
        HStack(spacing: 12) {
            statCard(
                label: "MAX PROFIT",
                value: store.maxProfit.map { CortexDesign.pnlString($0) } ?? "--",
                color: store.maxProfit.map { CortexDesign.pnlColor($0) } ?? CortexDesign.neutral
            )

            statCard(
                label: "MAX LOSS",
                value: store.maxLoss.map { CortexDesign.pnlString($0) } ?? "--",
                color: store.maxLoss.map { CortexDesign.pnlColor($0) } ?? CortexDesign.neutral
            )

            statCard(
                label: "BREAKEVEN",
                value: store.breakevens.isEmpty ? "--" : store.breakevens.map {
                    String(format: "$%.2f", $0)
                }.joined(separator: " / "),
                color: .white
            )
        }
    }

    private func statCard(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(label)
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

    // MARK: - Profit Chart

    private var profitChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROFIT / LOSS AT EXPIRATION")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            if store.profitCurve.isEmpty {
                // Placeholder
                RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                    .fill(CortexDesign.bgCard)
                    .frame(height: 200)
                    .overlay(
                        Text("Awaiting calculation...")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    )
            } else {
                profitCurveChart
            }
        }
    }

    private var profitCurveChart: some View {
        let points = store.profitCurve
        let minProfit = points.map(\.profit).min() ?? 0
        let maxProfit = points.map(\.profit).max() ?? 0
        let minPrice = points.map(\.price).min() ?? 0
        let maxPrice = points.map(\.price).max() ?? 0
        let priceRange = maxPrice - minPrice
        let profitRange = maxProfit - minProfit

        return GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            ZStack {
                // Background
                RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                    .fill(CortexDesign.bgCard)

                // Grid lines
                Path { path in
                    // Zero line
                    if profitRange > 0 {
                        let zeroY = height - ((0 - minProfit) / profitRange) * height
                        path.move(to: CGPoint(x: 0, y: zeroY))
                        path.addLine(to: CGPoint(x: width, y: zeroY))
                    }
                }
                .stroke(CortexDesign.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                // Profit fill (green above zero, red below)
                if priceRange > 0 && profitRange > 0 {
                    let zeroY = height - ((0 - minProfit) / profitRange) * height

                    // Profit line
                    Path { path in
                        for (i, point) in points.enumerated() {
                            let x = ((point.price - minPrice) / priceRange) * width
                            let y = height - ((point.profit - minProfit) / profitRange) * height
                            if i == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(
                        LinearGradient(
                            colors: [CortexDesign.loss, CortexDesign.profit],
                            startPoint: .bottom,
                            endPoint: .top
                        ),
                        lineWidth: 2
                    )

                    // Zero line label
                    Text("$0")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .position(x: width - 16, y: zeroY - 8)
                }

                // Breakeven markers
                if priceRange > 0 {
                    ForEach(store.breakevens, id: \.self) { be in
                        let x = ((be - minPrice) / priceRange) * width
                        Rectangle()
                            .fill(CortexDesign.accentPrimary.opacity(0.5))
                            .frame(width: 1)
                            .position(x: x, y: height / 2)

                        Text(String(format: "BE\n$%.0f", be))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(CortexDesign.accentPrimary)
                            .multilineTextAlignment(.center)
                            .position(x: x, y: 16)
                    }
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

    // MARK: - Legs List

    private var legsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STRATEGY LEGS")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            ForEach(store.selectedLegs) { leg in
                legRow(leg)
            }
        }
    }

    private func legRow(_ leg: OptionLeg) -> some View {
        HStack(spacing: 8) {
            // Side badge
            Text(leg.side.rawValue.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(leg.side == .buy ? CortexDesign.profit.opacity(0.15) : CortexDesign.loss.opacity(0.15))
                )
                .foregroundStyle(leg.side == .buy ? CortexDesign.profit : CortexDesign.loss)

            // Type badge
            Text(leg.contract.optionType.rawValue.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(leg.contract.optionType == .call ? Color.blue.opacity(0.15) : Color.orange.opacity(0.15))
                )
                .foregroundStyle(leg.contract.optionType == .call ? .blue : .orange)

            Text(String(format: "$%.1f", leg.contract.strike))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)

            Text("x\(leg.quantity)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            Text(String(format: "$%.2f", leg.side == .buy ? leg.contract.ask : leg.contract.bid))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            Button(action: { store.removeLeg(id: leg.id) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(CortexDesign.loss.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                .fill(CortexDesign.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                .strokeBorder(CortexDesign.border, lineWidth: 1)
        )
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "function")
                .font(.system(size: 36))
                .foregroundStyle(CortexDesign.border)
            Text("No Legs Selected")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(CortexDesign.neutral)
            Text("Click on calls or puts in the option chain to add legs.\nThe P&L graph will update automatically.")
                .font(.system(size: 12))
                .foregroundStyle(CortexDesign.neutral)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
