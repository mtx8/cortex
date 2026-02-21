import SwiftUI

/// War Room -- the main command dashboard for CORTEX.
/// Shows KPI strip, kill switch banner, squadron command grid,
/// top opportunities bar chart, live signal feed, and activity log.
@MainActor
public struct WarRoomView: View {
    let environment: AppEnvironment
    @Environment(\.cortexSelectedSection) private var selectedSection

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        VStack(spacing: 0) {
            // KPI Strip across the top (8 animated metric cards)
            KPIBar(portfolio: environment.portfolio)

            // Kill switch banner (contextual green/red)
            KillSwitchBanner(killSwitch: environment.killSwitch)

            switch selectedSection {
            case "Squadron Status":
                squadronStatusFullView
            case "Activity Feed":
                activityFeedFullView
            case "Risk Alerts":
                riskAlertsView
            default: // "Overview"
                overviewLayout
            }
        }
        .background(CortexDesign.bgDeepest)
    }

    // MARK: - Overview (3-column layout)

    @ViewBuilder
    private var overviewLayout: some View {
        VStack(spacing: 0) {
            // 3-Column main content area
            HSplitView {
                // Left column: Squadron Status + Top Opportunities
                ScrollView {
                    VStack(spacing: 12) {
                        SquadronStatusGrid(squadrons: environment.squadrons)

                        ScannerPreview(opportunities: environment.opportunities)
                    }
                    .padding(.bottom, 12)
                }
                .frame(minWidth: 280, idealWidth: 380)

                // Center column: Live Signal Feed
                LiveSignalFeed(signalFeed: environment.signalFeed)
                    .frame(minWidth: 260, idealWidth: 340)

                // Right column: Risk Dashboard
                ScrollView {
                    RiskDashboardView(
                        portfolio: environment.portfolio,
                        killSwitch: environment.killSwitch,
                        settings: environment.settings
                    )
                    .padding(8)
                }
                .frame(minWidth: 220, idealWidth: 260)
            }

            // Activity Feed (compact, bottom strip, max 200px)
            WarRoomActivityFeedView(activity: environment.activity)
                .frame(maxHeight: 200)
        }
    }

    // MARK: - Squadron Status (full view)

    @ViewBuilder
    private var squadronStatusFullView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("SQUADRON STATUS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                SquadronStatusGrid(squadrons: environment.squadrons)
                    .padding(.bottom, 12)
            }
        }
    }

    // MARK: - Activity Feed (full view)

    @ViewBuilder
    private var activityFeedFullView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("ACTIVITY LOG")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)

                Text("\(environment.activity.events.count) events")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(CortexDesign.bgHover)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(environment.activity.recentEvents.prefix(50)) { event in
                        ActivityEventRow(event: event)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }

    // MARK: - Risk Alerts

    @ViewBuilder
    private var riskAlertsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("RISK ALERTS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                // Risk metrics cards
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    riskMetricCard(
                        title: "DAILY P&L",
                        value: String(format: "$%.2f", environment.portfolio.dailyPnL),
                        color: environment.portfolio.dailyPnL >= 0 ? CortexDesign.profit : CortexDesign.loss,
                        icon: "chart.line.uptrend.xyaxis"
                    )

                    riskMetricCard(
                        title: "MAX DRAWDOWN",
                        value: String(format: "%.1f%%", environment.settings.maxDrawdownPct),
                        color: environment.settings.maxDrawdownPct > 5 ? CortexDesign.warning : CortexDesign.profit,
                        icon: "arrow.down.right"
                    )

                    riskMetricCard(
                        title: "OPEN POSITIONS",
                        value: "\(environment.portfolio.openPositionCount)",
                        color: CortexDesign.accentPrimary,
                        icon: "briefcase.fill"
                    )

                    riskMetricCard(
                        title: "BUYING POWER",
                        value: String(format: "$%.0f", environment.portfolio.buyingPower),
                        color: CortexDesign.accentSecondary,
                        icon: "banknote"
                    )

                    riskMetricCard(
                        title: "MAX DAILY LOSS",
                        value: String(format: "$%.0f", environment.settings.maxDailyLoss),
                        color: CortexDesign.warning,
                        icon: "exclamationmark.shield"
                    )

                    riskMetricCard(
                        title: "MAX NOTIONAL",
                        value: String(format: "$%.0f", environment.settings.maxNotional),
                        color: .yellow,
                        icon: "dollarsign.circle"
                    )
                }
                .padding(.horizontal, 16)

                // Risk events (warning + critical only)
                let riskEvents = environment.activity.recentEvents.filter { $0.severity == .warning || $0.severity == .critical }

                HStack(spacing: 8) {
                    Text("RISK EVENTS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(CortexDesign.neutral)

                    Text("\(riskEvents.count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(riskEvents.isEmpty ? CortexDesign.neutral : CortexDesign.warning)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(CortexDesign.bgHover)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Spacer()
                }
                .padding(.horizontal, 16)

                if riskEvents.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(CortexDesign.border)

                        Text("No Risk Alerts")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(CortexDesign.neutral)

                        Text("All systems operating within risk parameters")
                            .font(.system(size: 12))
                            .foregroundStyle(CortexDesign.neutral)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    LazyVStack(spacing: 1) {
                        ForEach(riskEvents.prefix(50)) { event in
                            ActivityEventRow(event: event)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private func riskMetricCard(title: String, value: String, color: Color, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(color.opacity(0.7))

            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(color)

            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(CortexDesign.neutral)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(CortexDesign.bgDeepest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(CortexDesign.bgHover, lineWidth: 1)
        )
    }
}

// MARK: - Kill Switch Banner

@MainActor
struct KillSwitchBanner: View {
    let killSwitch: KillSwitchStore
    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        HStack(spacing: 10) {
            // Pulsing status dot
            Circle()
                .fill(killSwitch.isActive ? CortexDesign.loss : CortexDesign.profit)
                .frame(width: 7, height: 7)
                .opacity(pulseOpacity)
                .onAppear {
                    withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                        pulseOpacity = 0.3
                    }
                }

            Text(killSwitch.isActive ? "KILL SWITCH ENGAGED" : "ALL SYSTEMS NOMINAL")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(killSwitch.isActive ? .white : .green)

            if killSwitch.isEngaging {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            }

            Spacer()

            KillSwitchButton(store: killSwitch)
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(
            Group {
                if killSwitch.isActive {
                    LinearGradient(
                        colors: [CortexDesign.loss.opacity(0.15), CortexDesign.loss.opacity(0.08)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                } else {
                    LinearGradient(
                        colors: [CortexDesign.profit.opacity(0.06), CortexDesign.profit.opacity(0.02)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
            }
        )
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(CortexDesign.bgHover),
            alignment: .bottom
        )
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(CortexDesign.bgHover),
            alignment: .top
        )
    }
}

// MARK: - Kill Switch Button

struct KillSwitchButton: View {
    let store: KillSwitchStore

    var body: some View {
        Button(action: {
            if store.isActive {
                store.disengage()
            } else {
                store.engage()
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: store.isActive ? "exclamationmark.octagon.fill" : "shield.checkmark")
                    .font(.system(size: 10))
                Text(store.isActive ? "DISARM" : "ARMED")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(store.isActive ? CortexDesign.loss : Color.clear)
            )
            .overlay(
                Capsule()
                    .strokeBorder(store.isActive ? CortexDesign.loss : CortexDesign.profit.opacity(0.4), lineWidth: 1)
            )
            .foregroundStyle(store.isActive ? .white : CortexDesign.profit)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Live Signal Feed

@MainActor
struct LiveSignalFeed: View {
    let signalFeed: SignalFeedStore
    @State private var liveDotOpacity: Double = 1.0

    private var hasRecentSignals: Bool {
        guard let first = signalFeed.recentSignals.first else { return false }
        return first.timestamp.timeIntervalSinceNow > -30
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack(spacing: 6) {
                if hasRecentSignals {
                    Circle()
                        .fill(CortexDesign.loss)
                        .frame(width: 6, height: 6)
                        .opacity(liveDotOpacity)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                                liveDotOpacity = 0.2
                            }
                        }
                }

                Text("LIVE SIGNALS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)

                Spacer()

                Text("\(signalFeed.recentSignals.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(CortexDesign.bgHover)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if signalFeed.recentSignals.isEmpty {
                // Empty state
                VStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                        .symbolEffect(.pulse)

                    Text("Waiting for market signals...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(signalFeed.recentSignals) { signal in
                            SignalRow(signal: signal)
                        }
                    }
                    .padding(8)
                }
                .animation(.default, value: signalFeed.recentSignals.count)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(CortexDesign.bgDeepest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(CortexDesign.bgHover, lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }
}

// MARK: - Signal Row

struct SignalRow: View {
    let signal: SignalEvent

    /// Determine direction from signal type name.
    private var direction: String? {
        let lowerType = signal.signalType.lowercased()
        if lowerType.contains("entry") || lowerType.contains("buy") || lowerType.contains("breakout") || lowerType.contains("gap") {
            return "LONG"
        }
        if lowerType.contains("short") || lowerType.contains("sell") {
            return "SHORT"
        }
        return nil
    }

    /// Extract a confidence-like value from payload or signal type.
    private var confidenceLabel: String? {
        if let conf = signal.payload["confidence"] {
            return conf
        }
        return nil
    }

    /// Relative time string.
    private var relativeTime: String {
        let elapsed = -signal.timestamp.timeIntervalSinceNow
        if elapsed < 10 { return "Just now" }
        if elapsed < 60 { return "\(Int(elapsed))s ago" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        return "\(Int(elapsed / 86400))d ago"
    }

    var body: some View {
        HStack(spacing: 6) {
            // Direction arrow
            if let dir = direction {
                Text(dir == "LONG" ? "\u{25B2}" : "\u{25BC}")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(dir == "LONG" ? CortexDesign.profit : CortexDesign.loss)
                    .frame(width: 14)
            } else {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(CortexDesign.accentPrimary)
                    .frame(width: 14)
            }

            // Ticker
            if !signal.symbol.isEmpty {
                Text(signal.symbol)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(CortexDesign.accentPrimary)
                    .frame(minWidth: 40, alignment: .leading)
            }

            // Signal type (shortened)
            Text(shortSignalType(signal.signalType))
                .font(.system(size: 10))
                .foregroundStyle(CortexDesign.neutral)
                .lineLimit(1)

            Spacer()

            // Confidence badge (if available)
            if let conf = confidenceLabel {
                Text(conf)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(CortexDesign.profit.opacity(0.12))
                    .foregroundStyle(CortexDesign.profit)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            // Squadron
            Text(signal.sourceSquadron.uppercased())
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(CortexDesign.neutral)
                .frame(width: 48, alignment: .trailing)

            // Timestamp
            Text(relativeTime)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(CortexDesign.neutral)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(CortexDesign.bgCard)
        )
    }

    /// Shorten signal type for display (e.g. "alpha.entry_signal" -> "Entry Signal").
    private func shortSignalType(_ type: String) -> String {
        let parts = type.split(separator: ".")
        let last = parts.last.map(String.init) ?? type
        return last
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

// MARK: - Activity Feed (War Room version)

@MainActor
struct WarRoomActivityFeedView: View {
    let activity: ActivityStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header with event count badge
            HStack(spacing: 6) {
                Text("ACTIVITY")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)

                Text("\(activity.events.count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(CortexDesign.bgHover)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(activity.recentEvents.prefix(25)) { event in
                        ActivityEventRow(event: event)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(CortexDesign.bgDeepest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(CortexDesign.bgHover, lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}

// MARK: - Activity Event Row

struct ActivityEventRow: View {
    let event: ActivityEvent

    /// Relative time string.
    private var relativeTime: String {
        let elapsed = -event.timestamp.timeIntervalSinceNow
        if elapsed < 10 { return "Just now" }
        if elapsed < 60 { return "\(Int(elapsed))s ago" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        return "\(Int(elapsed / 86400))d ago"
    }

    var body: some View {
        HStack(spacing: 0) {
            // Severity left border
            Rectangle()
                .fill(severityBorderColor)
                .frame(width: 2)

            HStack(spacing: 8) {
                // Severity icon
                Image(systemName: severityIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(severityColor)
                    .frame(width: 14)

                // Message
                Text(event.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)

                Spacer()

                // Relative timestamp
                Text(relativeTime)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(event.severity == .critical ? CortexDesign.loss.opacity(0.04) : CortexDesign.bgCard)
        )
    }

    private var severityIcon: String {
        switch event.severity {
        case .info: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }

    private var severityColor: Color {
        switch event.severity {
        case .info: return CortexDesign.accentPrimary
        case .warning: return CortexDesign.warning
        case .critical: return CortexDesign.loss
        }
    }

    private var severityBorderColor: Color {
        switch event.severity {
        case .info: return .clear
        case .warning: return CortexDesign.warning.opacity(0.5)
        case .critical: return CortexDesign.loss.opacity(0.7)
        }
    }
}
