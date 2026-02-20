import SwiftUI

/// Full scanner view with granular filters, short selling support, and AI integration.
public struct ScannerView: View {
    let opportunities: OpportunityStore
    let scannerFilter: ScannerFilterStore
    let onAnalyzeWithAI: (String) -> Void

    @State private var expandedId: String? = nil

    public init(
        opportunities: OpportunityStore,
        scannerFilter: ScannerFilterStore,
        onAnalyzeWithAI: @escaping (String) -> Void = { _ in }
    ) {
        self.opportunities = opportunities
        self.scannerFilter = scannerFilter
        self.onAnalyzeWithAI = onAnalyzeWithAI
    }

    private var filteredOpportunities: [Opportunity] {
        scannerFilter.filtered(opportunities.opportunities)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            Divider().overlay(Color(white: 0.12))

            // Filter bar
            ScannerFilterBar(filter: scannerFilter)

            Divider().overlay(Color(white: 0.12))

            if opportunities.opportunities.isEmpty {
                emptyStateNoData
            } else if filteredOpportunities.isEmpty {
                emptyStateNoMatch
            } else {
                // Column headers
                columnHeaders
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                Divider().overlay(Color(white: 0.10))

                // Results
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredOpportunities.enumerated()), id: \.element.id) { rank, opp in
                            VStack(spacing: 0) {
                                opportunityRow(opp, rank: rank + 1)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            expandedId = expandedId == opp.id ? nil : opp.id
                                        }
                                    }

                                if expandedId == opp.id {
                                    expandedDetail(opp)
                                }

                                Divider().overlay(Color(white: 0.08))
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
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.cyan)
            Text("SCANNER")
                .font(.system(size: 14, weight: .black, design: .monospaced))
                .foregroundStyle(.white)

            Spacer()

            if scannerFilter.activeFilterCount > 0 {
                Text("\(scannerFilter.activeFilterCount) filters active")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.cyan.opacity(0.1))
                    )
            }

            Text("\(filteredOpportunities.count) results")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Empty States

    private var emptyStateNoData: some View {
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

    private var emptyStateNoMatch: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "binoculars")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color(white: 0.3))

            Text("No opportunities match your filters")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(white: 0.6))

            Text("The market is currently in a consolidation phase. Consider broadening your search criteria or adjusting your minimum score threshold.")
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.4))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button(action: { scannerFilter.resetFilters() }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Reset All Filters")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.cyan)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.cyan.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.cyan.opacity(0.2), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Column Headers

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            Text("#")
                .frame(width: 30, alignment: .leading)

            Text("TICKER")
                .frame(width: 80, alignment: .leading)

            Button(action: {
                if scannerFilter.sortBy == .score {
                    scannerFilter.sortAscending.toggle()
                } else {
                    scannerFilter.sortBy = .score
                    scannerFilter.sortAscending = false
                }
            }) {
                HStack(spacing: 4) {
                    Text("SCORE")
                    if scannerFilter.sortBy == .score {
                        Image(systemName: scannerFilter.sortAscending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8))
                    }
                }
            }
            .buttonStyle(.plain)
            .frame(width: 130, alignment: .leading)

            Text("TYPE")
                .frame(width: 90, alignment: .leading)

            Text("DIR")
                .frame(width: 60, alignment: .center)

            Text("SECTOR")
                .frame(width: 100, alignment: .leading)

            Text("THESIS")
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: {
                if scannerFilter.sortBy == .rr {
                    scannerFilter.sortAscending.toggle()
                } else {
                    scannerFilter.sortBy = .rr
                    scannerFilter.sortAscending = false
                }
            }) {
                HStack(spacing: 4) {
                    Text("R:R")
                    if scannerFilter.sortBy == .rr {
                        Image(systemName: scannerFilter.sortAscending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8))
                    }
                }
            }
            .buttonStyle(.plain)
            .frame(width: 50, alignment: .trailing)

            Text("")
                .frame(width: 30)
        }
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .foregroundStyle(Color(white: 0.45))
    }

    // MARK: - Opportunity Row

    private func opportunityRow(_ opp: Opportunity, rank: Int) -> some View {
        HStack(spacing: 0) {
            // Rank
            Text("\(rank)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.4))
                .frame(width: 30, alignment: .leading)

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
                .frame(width: 70)

                Text(String(format: "%.0f", opp.compositeScore))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(scoreColor(opp.compositeScore))
            }
            .frame(width: 130, alignment: .leading)

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
                .frame(width: 90, alignment: .leading)

            // Direction badge
            Text(opp.direction.rawValue)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(opp.direction == .long ? .green : .red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill((opp.direction == .long ? Color.green : Color.red).opacity(0.12))
                )
                .frame(width: 60, alignment: .center)

            // Sector
            Text(opp.sector ?? "--")
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.5))
                .lineLimit(1)
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
                .frame(width: 50, alignment: .trailing)

            // AI Insight icon
            Button(action: {
                onAnalyzeWithAI("Analyze \(opp.ticker): \(opp.thesis)")
            }) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(.cyan.opacity(0.6))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Analyze with AI")
        }
        .padding(.vertical, 10)
        .background(
            expandedId == opp.id
                ? Color(white: 0.07)
                : Color.clear
        )
    }

    // MARK: - Expanded Detail

    private func expandedDetail(_ opp: Opportunity) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                // Left column: Full thesis
                VStack(alignment: .leading, spacing: 8) {
                    detailLabel("THESIS")
                    Text(opp.thesis)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.7))
                        .fixedSize(horizontal: false, vertical: true)

                    // Short interest badge (if applicable)
                    if let si = opp.shortInterest {
                        HStack(spacing: 6) {
                            Text("Short Interest:")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(white: 0.5))
                            Text(String(format: "%.1f%%", si))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(si >= 20 ? .red : si >= 10 ? .orange : .yellow)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill((si >= 20 ? Color.red : si >= 10 ? Color.orange : Color.yellow).opacity(0.12))
                                )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Center column: Key metrics
                VStack(alignment: .leading, spacing: 6) {
                    detailLabel("KEY METRICS")
                    detailRow("Composite Score", String(format: "%.1f / 100", opp.compositeScore))
                    detailRow("Risk : Reward", String(format: "%.1f : 1", opp.riskReward))
                    detailRow("Type", opp.type.rawValue)
                    detailRow("Direction", opp.direction.rawValue)
                    if let horizon = opp.timeHorizon {
                        detailRow("Time Horizon", horizon)
                    }
                    detailRow("Detected", relativeTime(opp.timestamp))
                }
                .frame(width: 200)

                // Right column: Entry/Exit
                VStack(alignment: .leading, spacing: 6) {
                    detailLabel("LEVELS")
                    if let entry = opp.entryPrice {
                        detailRow("Entry", String(format: "$%.2f", entry))
                    }
                    if let exit = opp.exitPrice {
                        detailRow("Target", String(format: "$%.2f", exit))
                    }
                    if let stop = opp.stopLoss {
                        detailRow("Stop Loss", String(format: "$%.2f", stop))
                    }
                    if opp.entryPrice == nil && opp.exitPrice == nil && opp.stopLoss == nil {
                        Text("Levels pending analysis")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(white: 0.35))
                    }
                }
                .frame(width: 160)
            }

            // Action buttons
            HStack(spacing: 12) {
                actionButton("Analyze with AI", icon: "sparkles", color: .cyan) {
                    onAnalyzeWithAI("Give me a detailed analysis of \(opp.ticker). Current thesis: \(opp.thesis)")
                }

                actionButton("Add to Watchlist", icon: "eye", color: .blue) {
                    // Watchlist action placeholder
                }

                actionButton("Quick Trade", icon: "bolt.fill", color: .green) {
                    // Quick trade action placeholder
                }

                Spacer()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(white: 0.10), lineWidth: 1)
                )
        )
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func detailLabel(_ label: String) -> some View {
        Text(label)
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

    private func actionButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(color.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(color.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

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

// MARK: - Scanner Filter Bar

struct ScannerFilterBar: View {
    let filter: ScannerFilterStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Direction
                filterMenu(
                    label: filter.direction.rawValue,
                    isActive: filter.direction != .both,
                    icon: "arrow.up.arrow.down"
                ) {
                    ForEach(Direction.allCases) { dir in
                        Button(action: { filter.direction = dir }) {
                            HStack {
                                Text(dir.rawValue)
                                if filter.direction == dir {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                // Market
                filterMenu(
                    label: filter.market.rawValue,
                    isActive: filter.market != .all,
                    icon: "globe"
                ) {
                    ForEach(Market.allCases) { m in
                        Button(action: { filter.market = m }) {
                            HStack {
                                Text(m.rawValue)
                                if filter.market == m {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                // Sector
                filterMenu(
                    label: filter.sector.rawValue,
                    isActive: filter.sector != .all,
                    icon: "building.2"
                ) {
                    ForEach(Sector.allCases) { s in
                        Button(action: { filter.sector = s }) {
                            HStack {
                                Text(s.rawValue)
                                if filter.sector == s {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                // Cap Size
                filterMenu(
                    label: filter.capSize.rawValue,
                    isActive: filter.capSize != .all,
                    icon: "chart.bar"
                ) {
                    ForEach(CapSize.allCases) { c in
                        Button(action: { filter.capSize = c }) {
                            HStack {
                                Text(c.rawValue)
                                if filter.capSize == c {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                // Min Score slider
                HStack(spacing: 6) {
                    Text("Min:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(white: 0.5))
                    Text(String(format: "%.0f", filter.minScore))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(filter.minScore > 0 ? .cyan : Color(white: 0.5))
                        .frame(width: 24)
                    Slider(value: Binding(
                        get: { filter.minScore },
                        set: { filter.minScore = $0 }
                    ), in: 0...100, step: 5)
                    .frame(width: 80)
                    .tint(.cyan)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(filter.minScore > 0 ? Color.cyan.opacity(0.08) : Color(white: 0.08))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(filter.minScore > 0 ? Color.cyan.opacity(0.25) : Color(white: 0.15), lineWidth: 1)
                )

                // Reset
                if filter.activeFilterCount > 0 {
                    Button(action: { filter.resetFilters() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 10))
                            Text("Reset")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color.orange.opacity(0.08))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func filterMenu<Content: View>(
        label: String,
        isActive: Bool,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 11, weight: isActive ? .bold : .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
            }
            .foregroundStyle(isActive ? .cyan : Color(white: 0.6))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isActive ? Color.cyan.opacity(0.1) : Color(white: 0.08))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isActive ? Color.cyan.opacity(0.3) : Color(white: 0.15), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
