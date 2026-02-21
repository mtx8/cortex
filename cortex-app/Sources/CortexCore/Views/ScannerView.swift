import SwiftUI

/// Professional Bloomberg-grade opportunity scanner with filtering, sorting, and expandable detail rows.
public struct ScannerView: View {
    let opportunities: OpportunityStore
    let scannerFilter: ScannerFilterStore
    let webSocket: WebSocketClient
    let onAnalyzeWithAI: (String) -> Void

    @Environment(\.cortexSelectedSection) private var selectedSection
    @State private var expandedId: String? = nil
    @State private var hoveredRowId: String? = nil
    @State private var lastScanTime: Date = Date()
    @State private var scanTimer: Timer? = nil
    @State private var secondsSinceLastScan: Int = 0

    public init(
        opportunities: OpportunityStore,
        scannerFilter: ScannerFilterStore,
        webSocket: WebSocketClient,
        onAnalyzeWithAI: @escaping (String) -> Void = { _ in }
    ) {
        self.opportunities = opportunities
        self.scannerFilter = scannerFilter
        self.webSocket = webSocket
        self.onAnalyzeWithAI = onAnalyzeWithAI
    }

    private var filteredOpportunities: [Opportunity] {
        scannerFilter.filtered(opportunities.opportunities)
    }

    /// Further filter by the selected left-pane section.
    private var sectionFilteredOpportunities: [Opportunity] {
        let baseFiltered = filteredOpportunities
        switch selectedSection {
        case "Momentum":
            return baseFiltered.filter { $0.type == .momentum }
        case "Volume Surges":
            return baseFiltered.filter { $0.type == .volume }
        case "Breakouts":
            return baseFiltered.filter { $0.type == .breakout }
        case "Short Candidates":
            return baseFiltered.filter { $0.direction == .short }
        case "Catalyst Events":
            return baseFiltered.filter { $0.type == .catalyst }
        case "Options Flow":
            return baseFiltered.filter { $0.type == .flow }
        default: // "All Opportunities"
            return baseFiltered
        }
    }

    /// Description text for the current section filter.
    private var sectionDescription: String? {
        switch selectedSection {
        case "Momentum": return "Stocks showing strong directional momentum with RSI and MACD confirmation"
        case "Volume Surges": return "Unusual volume activity exceeding average thresholds"
        case "Breakouts": return "Stocks breaking key resistance levels with volume confirmation"
        case "Short Candidates": return "Bearish setups with elevated short interest or breakdown patterns"
        case "Catalyst Events": return "Event-driven opportunities from earnings, FDA, or regulatory catalysts"
        case "Options Flow": return "Unusual options activity indicating institutional positioning"
        default: return nil
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            scannerHeader

            // Section sub-header (when not "All Opportunities")
            if let desc = sectionDescription {
                sectionSubHeader(selectedSection.uppercased(), description: desc)
            }

            // Separator
            Rectangle()
                .fill(CortexDesign.bgHover)
                .frame(height: 1)

            // Filter bar
            ScannerFilterBar(filter: scannerFilter)

            // Separator
            Rectangle()
                .fill(CortexDesign.bgHover)
                .frame(height: 1)

            // Content area
            if opportunities.opportunities.isEmpty {
                emptyStateNoData
            } else if sectionFilteredOpportunities.isEmpty {
                emptyStateNoMatch
            } else {
                // Column headers
                columnHeaders

                Rectangle()
                    .fill(CortexDesign.bgHover)
                    .frame(height: 1)

                // Data table
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(sectionFilteredOpportunities.enumerated()), id: \.element.id) { rank, opp in
                            VStack(spacing: 0) {
                                opportunityRow(opp, rank: rank + 1)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            expandedId = expandedId == opp.id ? nil : opp.id
                                        }
                                    }
                                    .onHover { hovering in
                                        hoveredRowId = hovering ? opp.id : nil
                                    }

                                if expandedId == opp.id {
                                    expandedDetail(opp)
                                        .transition(.asymmetric(
                                            insertion: .opacity.combined(with: .move(edge: .top)),
                                            removal: .opacity
                                        ))
                                }
                            }
                        }
                    }
                }
            }
        }
        .background(CortexDesign.bgDeepest)
        .onAppear {
            lastScanTime = Date()
            startScanTimer()
        }
        .onDisappear {
            scanTimer?.invalidate()
        }
    }

    // MARK: - Section Sub-Header

    @ViewBuilder
    private func sectionSubHeader(_ title: String, description: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(CortexDesign.accentPrimary)

            Text("\u{2014}")
                .foregroundStyle(CortexDesign.border)

            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(CortexDesign.neutral)
                .lineLimit(1)

            Spacer()

            Text("\(sectionFilteredOpportunities.count) results")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(CortexDesign.neutral)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(CortexDesign.accentPrimary.opacity(0.03))
    }

    // MARK: - Scanner Header

    private var scannerHeader: some View {
        HStack(spacing: 12) {
            // Title
            Text("OPPORTUNITY SCANNER")
                .font(.system(size: 13, weight: .black, design: .monospaced))
                .foregroundStyle(CortexDesign.neutral)

            // Result count pill
            if !opportunities.opportunities.isEmpty {
                Text("\(sectionFilteredOpportunities.count) opportunities")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CortexDesign.accentPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(CortexDesign.accentPrimary.opacity(0.08))
                    )
            }

            Spacer()

            // Last scan timestamp
            Text("Last scan: \(scanTimeLabel)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(CortexDesign.neutral)

            // Refresh button
            Button(action: {
                lastScanTime = Date()
                secondsSinceLastScan = 0
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CortexDesign.neutral)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: CortexDesign.badgeRadius)
                            .fill(CortexDesign.bgCard)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CortexDesign.badgeRadius)
                            .strokeBorder(CortexDesign.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Refresh scanner")
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    private var scanTimeLabel: String {
        if secondsSinceLastScan < 5 { return "just now" }
        if secondsSinceLastScan < 60 { return "\(secondsSinceLastScan)s ago" }
        let minutes = secondsSinceLastScan / 60
        return "\(minutes)m ago"
    }

    private func startScanTimer() {
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                secondsSinceLastScan = Int(Date().timeIntervalSince(lastScanTime))
            }
        }
    }

    // MARK: - Empty States

    private var emptyStateNoData: some View {
        VStack(spacing: 16) {
            Spacer()

            if webSocket.isConnected {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(CortexDesign.border)
                    .symbolEffect(.pulse, options: .repeating)

                Text("Scanner is warming up...")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)

                Text("Opportunities will appear as squadrons analyze the market")
                    .font(.system(size: 12))
                    .foregroundStyle(CortexDesign.neutral)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 350)
            } else {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(CortexDesign.border)

                Text("Backend Not Connected")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)

                Text("Start the Python backend to receive scanner data.\npython -m cortex.main")
                    .font(.system(size: 12))
                    .foregroundStyle(CortexDesign.neutral)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 350)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateNoMatch: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(CortexDesign.border)

            Text("No opportunities match your filters")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(CortexDesign.neutral)

            Text("Try adjusting your filters or resetting them")
                .font(.system(size: 12))
                .foregroundStyle(CortexDesign.neutral)

            Button(action: { scannerFilter.resetFilters() }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11))
                    Text("Reset Filters")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(CortexDesign.accentPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                        .fill(CortexDesign.accentPrimary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                        .strokeBorder(CortexDesign.accentPrimary.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Column Headers (Sortable)

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            sortableHeader("#", field: nil, width: 30, alignment: .leading)

            sortableHeader("TICKER", field: .ticker, width: 70, alignment: .leading)

            sortableHeader("SCORE", field: .score, width: 80, alignment: .leading)

            sortableHeader("TYPE", field: .type, width: 85, alignment: .leading)

            sortableHeader("DIR", field: .direction, width: 55, alignment: .center)

            sortableHeader("SECTOR", field: .sector, width: 80, alignment: .leading)

            sortableHeader("R:R", field: .rr, width: 50, alignment: .trailing)

            // Thesis fills remaining
            Text("THESIS")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(CortexDesign.neutral)
                .textCase(.uppercase)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(CortexDesign.bgDeepest)
    }

    @ViewBuilder
    private func sortableHeader(_ label: String, field: SortField?, width: CGFloat, alignment: Alignment) -> some View {
        if let field = field {
            Button(action: {
                if scannerFilter.sortBy == field {
                    scannerFilter.sortAscending.toggle()
                } else {
                    scannerFilter.sortBy = field
                    scannerFilter.sortAscending = false
                }
            }) {
                HStack(spacing: 3) {
                    Text(label)
                    if scannerFilter.sortBy == field {
                        Image(systemName: scannerFilter.sortAscending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(CortexDesign.accentPrimary)
                    }
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(scannerFilter.sortBy == field ? CortexDesign.accentPrimary : CortexDesign.neutral)
                .textCase(.uppercase)
            }
            .buttonStyle(.plain)
            .frame(width: width, alignment: alignment)
        } else {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(CortexDesign.neutral)
                .textCase(.uppercase)
                .frame(width: width, alignment: alignment)
        }
    }

    // MARK: - Opportunity Row

    private func opportunityRow(_ opp: Opportunity, rank: Int) -> some View {
        let isExpanded = expandedId == opp.id
        let isHovered = hoveredRowId == opp.id

        return HStack(spacing: 0) {
            // Rank
            Text("\(rank)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(CortexDesign.neutral)
                .frame(width: 30, alignment: .leading)

            // Ticker
            Text(opp.ticker)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .underline(isHovered, color: .cyan.opacity(0.5))
                .frame(width: 70, alignment: .leading)

            // Score with bar
            HStack(spacing: 6) {
                // Score bar
                GeometryReader { _ in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(CortexDesign.bgHover)
                            .frame(height: 6)

                        RoundedRectangle(cornerRadius: 2)
                            .fill(scoreGradient(opp.compositeScore))
                            .frame(
                                width: 50 * min(opp.compositeScore / 100.0, 1.0),
                                height: 6
                            )
                    }
                }
                .frame(width: 50, height: 6)

                Text(String(format: "%.0f", opp.compositeScore))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(scoreColor(opp.compositeScore))
            }
            .frame(width: 80, alignment: .leading)

            // Type badge
            Text(opp.type.rawValue)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(typeColor(opp.type))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(typeColor(opp.type).opacity(0.12))
                )
                .frame(width: 85, alignment: .leading)

            // Direction badge
            Text(opp.direction.rawValue)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(opp.direction == .long ? CortexDesign.profit : CortexDesign.loss)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill((opp.direction == .long ? CortexDesign.profit : CortexDesign.loss).opacity(0.12))
                )
                .frame(width: 55, alignment: .center)

            // Sector
            Text(sectorDisplay(opp.sector))
                .font(.system(size: 11))
                .foregroundStyle(CortexDesign.neutral)
                .lineLimit(1)
                .frame(width: 80, alignment: .leading)

            // R:R Ratio
            Text(String(format: "%.1f", opp.riskReward))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(rrColor(opp.riskReward))
                .frame(width: 50, alignment: .trailing)

            // Thesis (truncated, fills remaining)
            Text(opp.thesis)
                .font(.system(size: 11))
                .foregroundStyle(CortexDesign.neutral)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(
            isExpanded
                ? CortexDesign.bgCard
                : isHovered
                    ? CortexDesign.bgCard
                    : (rank % 2 == 0 ? CortexDesign.bgDeepest : CortexDesign.bgDeepest)
        )
    }

    // MARK: - Expanded Detail Panel

    private func expandedDetail(_ opp: Opportunity) -> some View {
        HStack(alignment: .top, spacing: 20) {
            // Column 1: Thesis & AI Insight
            VStack(alignment: .leading, spacing: 10) {
                detailSectionLabel("THESIS")

                Text(opp.thesis)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)

                if let insight = opp.aiInsight, !insight.isEmpty {
                    detailSectionLabel("AI INSIGHT")

                    Text(insight)
                        .font(.system(size: 11))
                        .foregroundStyle(CortexDesign.accentPrimary.opacity(0.9))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: CortexDesign.badgeRadius)
                                .fill(CortexDesign.accentPrimary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CortexDesign.badgeRadius)
                                .strokeBorder(CortexDesign.accentPrimary.opacity(0.12), lineWidth: 1)
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Column 2: Key Metrics
            VStack(alignment: .leading, spacing: 6) {
                detailSectionLabel("KEY METRICS")

                metricRow("Score", value: String(format: "%.1f", opp.compositeScore),
                          color: scoreColor(opp.compositeScore))
                metricRow("Risk / Reward", value: String(format: "%.1f : 1", opp.riskReward),
                          color: rrColor(opp.riskReward))

                HStack {
                    Text("Direction")
                        .font(.system(size: 11))
                        .foregroundStyle(CortexDesign.neutral)
                    Spacer()
                    Text(opp.direction.rawValue)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(opp.direction == .long ? CortexDesign.profit : CortexDesign.loss)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill((opp.direction == .long ? CortexDesign.profit : CortexDesign.loss).opacity(0.12))
                        )
                }

                if let si = opp.shortInterest {
                    metricRow("Short Interest", value: String(format: "%.1f%%", si),
                              color: si >= 20 ? CortexDesign.loss : si >= 10 ? CortexDesign.warning : .yellow)
                }

                metricRow("Sector", value: sectorDisplay(opp.sector), color: .white.opacity(0.7))

                if let cap = opp.marketCap, !cap.isEmpty {
                    metricRow("Market Cap", value: cap, color: .white.opacity(0.7))
                }

                if let horizon = opp.timeHorizon {
                    metricRow("Time Horizon", value: horizon, color: .white.opacity(0.7))
                }

                metricRow("Detected", value: relativeTime(opp.timestamp), color: CortexDesign.neutral)
            }
            .frame(width: 180)

            // Column 3: Levels + Actions
            VStack(alignment: .leading, spacing: 6) {
                // Price Levels
                if opp.entryPrice != nil || opp.exitPrice != nil || opp.stopLoss != nil {
                    detailSectionLabel("PRICE LEVELS")

                    if let entry = opp.entryPrice {
                        metricRow("Entry", value: String(format: "$%.2f", entry), color: .white)
                    }
                    if let target = opp.exitPrice {
                        metricRow("Target", value: String(format: "$%.2f", target), color: CortexDesign.profit)
                    }
                    if let stop = opp.stopLoss {
                        metricRow("Stop Loss", value: String(format: "$%.2f", stop), color: CortexDesign.loss)
                    }
                } else {
                    detailSectionLabel("PRICE LEVELS")
                    Text("Pending analysis")
                        .font(.system(size: 11))
                        .foregroundStyle(CortexDesign.neutral)
                }

                Spacer().frame(height: 8)

                // Action buttons
                detailSectionLabel("ACTIONS")

                actionButton("Analyze with AI", icon: "sparkles", color: CortexDesign.accentPrimary, filled: true) {
                    onAnalyzeWithAI("Give me a detailed analysis of \(opp.ticker). Current thesis: \(opp.thesis)")
                }

                actionButton("Add to Watchlist", icon: "eye", color: .blue, filled: false) {
                    // Watchlist action placeholder
                }

                actionButton(
                    opp.direction == .long ? "Quick Trade" : "Quick Short",
                    icon: "bolt.fill",
                    color: opp.direction == .long ? CortexDesign.profit : CortexDesign.loss,
                    filled: false
                ) {
                    // Quick trade action placeholder
                }
            }
            .frame(width: 160)
        }
        .padding(16)
        .background(CortexDesign.bgDeepest)
        .overlay(
            VStack(spacing: 0) {
                Rectangle().fill(CortexDesign.bgHover).frame(height: 1)
                Spacer()
                Rectangle().fill(CortexDesign.bgHover).frame(height: 1)
            }
        )
    }

    // MARK: - Component Builders

    private func detailSectionLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(CortexDesign.neutral)
            .padding(.bottom, 2)
    }

    private func metricRow(_ label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(CortexDesign.neutral)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    private func actionButton(_ title: String, icon: String, color: Color, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(filled ? .white : color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(filled ? color : color.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(filled ? Color.clear : color.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Color Helpers

    private func scoreColor(_ score: Double) -> Color {
        if score >= 80 { return CortexDesign.profit }
        if score >= 60 { return CortexDesign.accentPrimary }
        if score >= 40 { return .yellow }
        return CortexDesign.loss
    }

    private func scoreGradient(_ score: Double) -> LinearGradient {
        let color: Color
        if score >= 80 { color = CortexDesign.profit }
        else if score >= 60 { color = CortexDesign.accentPrimary }
        else if score >= 40 { color = .yellow }
        else { color = CortexDesign.loss }
        return LinearGradient(
            colors: [color.opacity(0.7), color],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func typeColor(_ type: Opportunity.OpportunityType) -> Color {
        switch type {
        case .momentum: return CortexDesign.accentPrimary
        case .breakout: return CortexDesign.warning
        case .volume: return .purple
        case .catalyst: return .orange
        case .flow: return .yellow
        case .earnings: return .blue
        case .reversal: return .purple
        case .sector: return .mint
        }
    }

    private func rrColor(_ ratio: Double) -> Color {
        if ratio >= 2.0 { return CortexDesign.profit }
        if ratio >= 1.0 { return .yellow }
        return CortexDesign.loss
    }

    private func sectorDisplay(_ sector: String?) -> String {
        guard let sector = sector, !sector.isEmpty, sector != "Unknown" else {
            return "\u{2014}" // em dash
        }
        return sector
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

    @State private var showDirectionPopover = false
    @State private var showMarketPopover = false
    @State private var showSectorPopover = false
    @State private var showCapSizePopover = false
    @State private var showSortPopover = false
    @State private var resetHovered = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Direction filter chip
                filterChip(
                    label: "Direction",
                    value: filter.direction.rawValue,
                    isActive: filter.direction != .both,
                    isOpen: $showDirectionPopover
                ) {
                    ForEach(Direction.allCases) { dir in
                        filterOption(dir.rawValue, selected: filter.direction == dir) {
                            filter.direction = dir
                            showDirectionPopover = false
                        }
                    }
                }

                // Market filter chip
                filterChip(
                    label: "Market",
                    value: filter.market.rawValue,
                    isActive: filter.market != .all,
                    isOpen: $showMarketPopover
                ) {
                    ForEach(Market.allCases) { m in
                        filterOption(m.rawValue, selected: filter.market == m) {
                            filter.market = m
                            showMarketPopover = false
                        }
                    }
                }

                // Sector filter chip
                filterChip(
                    label: "Sector",
                    value: filter.sector.rawValue,
                    isActive: filter.sector != .all,
                    isOpen: $showSectorPopover
                ) {
                    ForEach(Sector.allCases) { s in
                        filterOption(s.rawValue, selected: filter.sector == s) {
                            filter.sector = s
                            showSectorPopover = false
                        }
                    }
                }

                // Cap Size filter chip
                filterChip(
                    label: "Cap Size",
                    value: filter.capSize.rawValue,
                    isActive: filter.capSize != .all,
                    isOpen: $showCapSizePopover
                ) {
                    ForEach(CapSize.allCases) { c in
                        filterOption(c.rawValue, selected: filter.capSize == c) {
                            filter.capSize = c
                            showCapSizePopover = false
                        }
                    }
                }

                // Score slider chip
                HStack(spacing: 6) {
                    Text("Score")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(filter.minScore > 0 ? CortexDesign.accentPrimary : CortexDesign.neutral)

                    Text("\u{2265} \(Int(filter.minScore))")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(filter.minScore > 0 ? CortexDesign.accentPrimary : CortexDesign.neutral)
                        .frame(width: 30, alignment: .trailing)

                    Slider(value: Binding(
                        get: { filter.minScore },
                        set: { filter.minScore = $0 }
                    ), in: 0...100, step: 5)
                    .frame(width: 80)
                    .tint(CortexDesign.accentPrimary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(filter.minScore > 0 ? CortexDesign.accentPrimary.opacity(0.06) : CortexDesign.bgCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(filter.minScore > 0 ? CortexDesign.accentPrimary.opacity(0.4) : CortexDesign.border, lineWidth: 1)
                )

                // Sort chip
                filterChip(
                    label: "Sort",
                    value: filter.sortBy.rawValue,
                    isActive: true,
                    isOpen: $showSortPopover
                ) {
                    ForEach(SortField.allCases) { s in
                        filterOption(s.rawValue, selected: filter.sortBy == s) {
                            filter.sortBy = s
                            showSortPopover = false
                        }
                    }
                }

                // Ascending/Descending toggle
                Button(action: {
                    filter.sortAscending.toggle()
                }) {
                    Image(systemName: filter.sortAscending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CortexDesign.accentPrimary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                                .fill(CortexDesign.accentPrimary.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                                .strokeBorder(CortexDesign.accentPrimary.opacity(0.4), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help(filter.sortAscending ? "Ascending" : "Descending")

                // Reset button (only visible when filters active)
                if filter.activeFilterCount > 0 {
                    Button(action: { filter.resetFilters() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 10))
                            Text("Reset (\(filter.activeFilterCount))")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(CortexDesign.neutral)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                                .fill(resetHovered ? CortexDesign.loss.opacity(0.1) : CortexDesign.bgCard)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                                .strokeBorder(resetHovered ? CortexDesign.loss.opacity(0.3) : CortexDesign.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        resetHovered = hovering
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Filter Chip with Popover

    @ViewBuilder
    private func filterChip<Content: View>(
        label: String,
        value: String,
        isActive: Bool,
        isOpen: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        Button(action: {
            isOpen.wrappedValue.toggle()
        }) {
            HStack(spacing: 4) {
                Text(value)
                    .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(isActive ? CortexDesign.accentPrimary : CortexDesign.neutral)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                    .fill(isActive ? CortexDesign.accentPrimary.opacity(0.06) : CortexDesign.bgCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                    .strokeBorder(isActive ? CortexDesign.accentPrimary.opacity(0.4) : CortexDesign.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                content()
            }
            .padding(.bottom, 6)
            .frame(minWidth: 160)
            .background(CortexDesign.bgHover)
        }
    }

    // MARK: - Filter Option Row

    private func filterOption(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? CortexDesign.accentPrimary : .white)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(CortexDesign.accentPrimary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(selected ? CortexDesign.accentPrimary.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
