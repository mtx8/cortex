import SwiftUI

/// Compact card displaying a scanner opportunity with composite score,
/// type badge, thesis text, and risk/reward ratio.
public struct OpportunityCard: View {
    let opportunity: Opportunity

    public init(opportunity: Opportunity) {
        self.opportunity = opportunity
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top row: ticker + score + type badge
            HStack(spacing: 8) {
                Text(opportunity.ticker)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)

                // Direction badge
                Text(opportunity.direction.rawValue)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(opportunity.direction == .long ? CortexDesign.profit.opacity(0.15) : CortexDesign.loss.opacity(0.15))
                    .foregroundStyle(opportunity.direction == .long ? CortexDesign.profit : CortexDesign.loss)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Spacer()

                // Type badge
                Text(opportunity.type.rawValue.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badgeColor.opacity(0.15))
                    .foregroundStyle(badgeColor)
                    .clipShape(Capsule())

                // Score
                Text(String(format: "%.0f", opportunity.compositeScore))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(scoreColor)
            }

            // Thesis text (2 lines max)
            Text(opportunity.thesis)
                .font(.system(size: 11))
                .foregroundStyle(CortexDesign.neutral)
                .lineLimit(2)

            // Bottom row: R:R ratio
            HStack {
                Label(
                    String(format: "R:R %.1f:1", opportunity.riskReward),
                    systemImage: "arrow.left.arrow.right"
                )
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(CortexDesign.neutral)

                if let sector = opportunity.sector {
                    Text(sector)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(CortexDesign.neutral)
                        .padding(.leading, 6)
                }

                Spacer()

                // Score bar inline
                ScoreBar(score: opportunity.compositeScore)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(CortexDesign.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(CortexDesign.bgHover, lineWidth: 1)
        )
    }

    private var badgeColor: Color {
        switch opportunity.type {
        case .momentum: return .blue
        case .volume: return .purple
        case .catalyst: return .orange
        case .breakout: return .green
        case .reversal: return .yellow
        case .flow: return .cyan
        case .earnings: return .mint
        case .sector: return .indigo
        }
    }

    private var scoreColor: Color {
        if opportunity.compositeScore >= 80 { return .green }
        if opportunity.compositeScore >= 60 { return .cyan }
        return .orange
    }
}

// MARK: - Score Bar

/// Horizontal colored progress bar representing a 0-100 composite score.
struct ScoreBar: View {
    let score: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(CortexDesign.border)

                RoundedRectangle(cornerRadius: 2)
                    .fill(barGradient)
                    .frame(width: max(0, geo.size.width * score / 100))
            }
        }
        .frame(width: 60, height: 6)
    }

    private var barGradient: LinearGradient {
        let color: Color = score >= 80 ? .green : score >= 60 ? .cyan : score >= 40 ? .yellow : .orange
        return LinearGradient(
            colors: [color.opacity(0.5), color],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - Opportunity Feed View (scrollable card list)

/// Scrollable list of all scanner opportunities shown as cards.
@MainActor
public struct OpportunityFeedView: View {
    let opportunities: OpportunityStore

    public init(opportunities: OpportunityStore) {
        self.opportunities = opportunities
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("OPPORTUNITIES")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)
                Spacer()
                Text("\(opportunities.opportunities.count) active")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(opportunities.top10) { opp in
                        OpportunityCard(opportunity: opp)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }
}

// MARK: - Scanner Preview (Top Opportunities bar chart)

/// Horizontal bar chart preview of top scanner opportunities for the War Room.
/// Shows rank, ticker, type badge, direction badge, gradient score bar, and numeric score.
@MainActor
public struct ScannerPreview: View {
    let opportunities: OpportunityStore

    public init(opportunities: OpportunityStore) {
        self.opportunities = opportunities
    }

    private var top8: [Opportunity] {
        Array(opportunities.opportunities.sorted { $0.compositeScore > $1.compositeScore }.prefix(8))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("TOP OPPORTUNITIES")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)
                Spacer()
            }
            .padding(.horizontal, 4)

            // Bar chart rows
            VStack(spacing: 0) {
                ForEach(Array(top8.enumerated()), id: \.element.id) { index, opp in
                    HStack(spacing: 8) {
                        // Rank
                        Text("#\(index + 1)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(CortexDesign.neutral)
                            .frame(width: 22, alignment: .trailing)

                        // Ticker
                        Text(opp.ticker)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(width: 48, alignment: .leading)

                        // Type badge
                        Text(opp.type.rawValue.uppercased())
                            .font(.system(size: 7, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(typeBadgeColor(opp.type).opacity(0.15))
                            .foregroundStyle(typeBadgeColor(opp.type))
                            .clipShape(Capsule())
                            .frame(width: 68, alignment: .leading)

                        // Direction badge
                        Text(opp.direction.rawValue)
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(opp.direction == .long ? CortexDesign.profit.opacity(0.12) : CortexDesign.loss.opacity(0.12))
                            .foregroundStyle(opp.direction == .long ? CortexDesign.profit : CortexDesign.loss)
                            .clipShape(Capsule())
                            .frame(width: 42, alignment: .center)

                        // Score bar
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(CortexDesign.bgHover)

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(scoreGradient(opp.compositeScore))
                                    .frame(width: max(0, geo.size.width * opp.compositeScore / 100))
                            }
                        }
                        .frame(height: 14)

                        // Score number
                        Text(String(format: "%.0f", opp.compositeScore))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(scoreTextColor(opp.compositeScore))
                            .frame(width: 28, alignment: .trailing)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(index % 2 == 0 ? CortexDesign.bgDeepest : CortexDesign.bgCard)
                    )
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(CortexDesign.bgDeepest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(CortexDesign.bgHover, lineWidth: 1)
        )
    }

    private func typeBadgeColor(_ type: Opportunity.OpportunityType) -> Color {
        switch type {
        case .momentum: return .blue
        case .volume: return .purple
        case .catalyst: return .orange
        case .breakout: return .green
        case .reversal: return .yellow
        case .flow: return .cyan
        case .earnings: return .mint
        case .sector: return .indigo
        }
    }

    private func scoreGradient(_ score: Double) -> LinearGradient {
        let color: Color
        if score >= 80 {
            color = .green
        } else if score >= 60 {
            color = .cyan
        } else if score >= 40 {
            color = .yellow
        } else {
            color = .orange
        }
        return LinearGradient(
            colors: [color.opacity(0.4), color.opacity(0.85)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func scoreTextColor(_ score: Double) -> Color {
        if score >= 80 { return .green }
        if score >= 60 { return .cyan }
        if score >= 40 { return .yellow }
        return .orange
    }
}
