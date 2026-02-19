import SwiftUI

/// Full scanner view showing opportunities detected by the CORTEX agent system.
/// Displays a sortable, filterable table with composite scores, types, theses, and R:R ratios.
public struct ScannerView: View {
    let opportunities: OpportunityStore

    @State private var selectedFilter: String = "All"
    @State private var expandedId: String? = nil
    @State private var sortAscending: Bool = false

    private let filters = ["All", "Momentum", "Breakout", "Volume", "Catalyst", "Flow", "Earnings"]

    public init(opportunities: OpportunityStore) {
        self.opportunities = opportunities
    }

    private var filteredOpportunities: [Opportunity] {
        let sorted = opportunities.opportunities.sorted {
            sortAscending
                ? $0.compositeScore < $1.compositeScore
                : $0.compositeScore > $1.compositeScore
        }
        if selectedFilter == "All" { return sorted }
        return sorted.filter { $0.type.rawValue == selectedFilter }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            Divider().overlay(Color(white: 0.15))

            if opportunities.opportunities.isEmpty {
                emptyState
            } else {
                // Filter bar
                filterBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                Divider().overlay(Color(white: 0.12))

                // Column headers
                columnHeaders
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                Divider().overlay(Color(white: 0.12))

                // Results
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredOpportunities) { opp in
                            VStack(spacing: 0) {
                                opportunityRow(opp)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            expandedId = expandedId == opp.id ? nil : opp.id
                                        }
                                    }

                                if expandedId == opp.id {
                                    expandedDetail(opp)
                                }

                                Divider().overlay(Color(white: 0.1))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .background(Color(nsColor: NSColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1.0)))
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.cyan)
            Text("SCANNER")
                .font(.system(size: 14, weight: .black, design: .monospaced))
                .foregroundStyle(.white)

            Spacer()

            Text("\(filteredOpportunities.count) results")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            ProgressView()
                .controlSize(.small)
                .tint(.cyan)

            Text("Waiting for scanner data...")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            Text("Scanner results will appear when the Rust engine is connected.")
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.4))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(filters, id: \.self) { filter in
                Button(action: { selectedFilter = filter }) {
                    Text(filter)
                        .font(.system(size: 11, weight: selectedFilter == filter ? .bold : .medium))
                        .foregroundStyle(selectedFilter == filter ? .white : Color(white: 0.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selectedFilter == filter
                                    ? Color.cyan.opacity(0.2)
                                    : Color(white: 0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(selectedFilter == filter
                                    ? Color.cyan.opacity(0.4)
                                    : Color(white: 0.15), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: - Column Headers

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            Text("TICKER")
                .frame(width: 80, alignment: .leading)

            Button(action: { sortAscending.toggle() }) {
                HStack(spacing: 4) {
                    Text("SCORE")
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                }
            }
            .buttonStyle(.plain)
            .frame(width: 140, alignment: .leading)

            Text("TYPE")
                .frame(width: 100, alignment: .leading)

            Text("THESIS")
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("R:R")
                .frame(width: 60, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .foregroundStyle(Color(white: 0.45))
    }

    // MARK: - Opportunity Row

    private func opportunityRow(_ opp: Opportunity) -> some View {
        HStack(spacing: 0) {
            // Ticker
            Text(opp.ticker)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 80, alignment: .leading)

            // Composite Score with bar
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(white: 0.12))
                            .frame(height: 8)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(scoreColor(opp.compositeScore))
                            .frame(width: geo.size.width * min(opp.compositeScore / 100.0, 1.0), height: 8)
                    }
                }
                .frame(height: 8)
                .frame(width: 80)

                Text(String(format: "%.0f", opp.compositeScore))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(scoreColor(opp.compositeScore))
            }
            .frame(width: 140, alignment: .leading)

            // Type badge
            Text(opp.type.rawValue)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(typeColor(opp.type))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(typeColor(opp.type).opacity(0.12))
                )
                .frame(width: 100, alignment: .leading)

            // Thesis (truncated)
            Text(opp.thesis)
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.6))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            // R:R Ratio
            Text(String(format: "%.1f", opp.riskReward))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(opp.riskReward >= 2.0 ? .green : opp.riskReward >= 1.5 ? .yellow : .orange)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .background(
            expandedId == opp.id
                ? Color(white: 0.08)
                : Color.clear
        )
    }

    // MARK: - Expanded Detail

    private func expandedDetail(_ opp: Opportunity) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    detailLabel("Thesis")
                    Text(opp.thesis)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    detailRow("Composite Score", String(format: "%.1f / 100", opp.compositeScore))
                    detailRow("Risk : Reward", String(format: "%.1f : 1", opp.riskReward))
                    detailRow("Type", opp.type.rawValue)
                    detailRow("Detected", relativeTime(opp.timestamp))
                }
                .frame(width: 200)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(white: 0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(white: 0.12), lineWidth: 1)
                )
        )
        .padding(.vertical, 4)
    }

    private func detailLabel(_ label: String) -> some View {
        Text(label.uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(Color(white: 0.4))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.45))
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        }
    }

    // MARK: - Helpers

    private func scoreColor(_ score: Double) -> Color {
        if score >= 80 { return .green }
        if score >= 60 { return .yellow }
        if score >= 40 { return .orange }
        return .red
    }

    private func typeColor(_ type: Opportunity.OpportunityType) -> Color {
        switch type {
        case .momentum: return .cyan
        case .breakout: return .green
        case .volume: return .purple
        case .catalyst: return .orange
        case .flow: return .yellow
        case .earnings: return .blue
        case .reversal: return .red
        case .sector: return .mint
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}
