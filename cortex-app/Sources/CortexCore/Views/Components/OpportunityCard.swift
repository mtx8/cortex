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

                // Composite score bar
                ScoreBar(score: opportunity.compositeScore)

                Spacer()

                // Type badge
                Text(opportunity.type.rawValue)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badgeColor.opacity(0.2))
                    .foregroundStyle(badgeColor)
                    .clipShape(Capsule())
            }

            // Thesis text (2 lines max)
            Text(opportunity.thesis)
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.65))
                .lineLimit(2)

            // Bottom row: R:R ratio + score value
            HStack {
                Label(
                    String(format: "R:R %.1f:1", opportunity.riskReward),
                    systemImage: "arrow.left.arrow.right"
                )
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

                Spacer()

                Text(String(format: "%.0f", opportunity.compositeScore))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(scoreColor)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(white: 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(white: 0.15), lineWidth: 1)
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
        if opportunity.compositeScore >= 60 { return .yellow }
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
                    .fill(Color(white: 0.15))

                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor)
                    .frame(width: max(0, geo.size.width * score / 100))
            }
        }
        .frame(width: 60, height: 6)
    }

    private var barColor: Color {
        if score >= 80 { return .green }
        if score >= 60 { return .yellow }
        if score >= 40 { return .orange }
        return .red
    }
}

// MARK: - Opportunity Feed View

/// Scrollable list of all scanner opportunities.
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
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(opportunities.opportunities.count) active")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
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

// MARK: - Scanner Preview (Top 10 bar chart)

/// Compact bar chart preview of top scanner opportunities for the War Room.
@MainActor
public struct ScannerPreview: View {
    let opportunities: OpportunityStore

    public init(opportunities: OpportunityStore) {
        self.opportunities = opportunities
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SCANNER TOP 10")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)

            // Horizontal bar chart
            ForEach(opportunities.top10) { opp in
                HStack(spacing: 8) {
                    Text(opp.ticker)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .frame(width: 60, alignment: .leading)
                        .foregroundStyle(.white)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(white: 0.12))

                            RoundedRectangle(cornerRadius: 3)
                                .fill(barGradient(opp.compositeScore))
                                .frame(width: max(0, geo.size.width * opp.compositeScore / 100))
                        }
                    }
                    .frame(height: 14)

                    Text(String(format: "%.0f", opp.compositeScore))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(opp.compositeScore >= 80 ? .green : opp.compositeScore >= 60 ? .yellow : .orange)
                        .frame(width: 28, alignment: .trailing)
                }
                .frame(height: 16)
            }
        }
        .padding(12)
    }

    private func barGradient(_ score: Double) -> LinearGradient {
        let color: Color = score >= 80 ? .green : score >= 60 ? .yellow : .orange
        return LinearGradient(
            colors: [color.opacity(0.4), color.opacity(0.8)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
