import SwiftUI

/// War Room — the main dashboard view for CORTEX.
/// Shows real-time P&L, agent status grid, and signal feed.
@MainActor
public struct WarRoomView: View {
    let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        HSplitView {
            // Left: Portfolio + Agent Grid
            VStack(spacing: 0) {
                PortfolioHeader(portfolio: environment.portfolio, killSwitch: environment.killSwitch)
                Divider()
                AgentGridView(squadrons: environment.squadrons)
            }
            .frame(minWidth: 400)

            // Right: Signal Feed + Activity
            VStack(spacing: 0) {
                SignalFeedView(feed: environment.signalFeed)
                Divider()
                ActivityFeedView(activity: environment.activity)
            }
            .frame(minWidth: 300)
        }
    }
}

// MARK: - Portfolio Header

@MainActor
struct PortfolioHeader: View {
    let portfolio: PortfolioStore
    let killSwitch: KillSwitchStore

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("CORTEX")
                    .font(.system(size: 24, weight: .black, design: .monospaced))
                Spacer()
                KillSwitchButton(store: killSwitch)
            }

            HStack(spacing: 24) {
                MetricView(label: "NAV", value: formatCurrency(portfolio.nav))
                MetricView(label: "Daily P&L", value: formatCurrency(portfolio.dailyPnL),
                          isPositive: portfolio.dailyPnL >= 0)
                MetricView(label: "Total P&L", value: formatCurrency(portfolio.totalPnL),
                          isPositive: portfolio.totalPnL >= 0)
                MetricView(label: "Win Rate", value: String(format: "%.1f%%", portfolio.winRate * 100))
                MetricView(label: "Positions", value: "\(portfolio.openPositionCount)")
            }
        }
        .padding()
    }

    func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "$0"
    }
}

struct MetricView: View {
    let label: String
    let value: String
    var isPositive: Bool? = nil

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .monospaced, weight: .semibold))
                .foregroundStyle(textColor)
        }
    }

    var textColor: Color {
        guard let isPositive else { return .primary }
        return isPositive ? .green : .red
    }
}

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
                Text(store.isActive ? "DISARM" : "ARMED")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(store.isActive ? Color.red : Color.green.opacity(0.2))
            .foregroundStyle(store.isActive ? .white : .green)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Agent Grid

@MainActor
struct AgentGridView: View {
    let squadrons: SquadronStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                let grouped = Dictionary(grouping: squadrons.agents) { $0.squadron }
                ForEach(squadronOrder, id: \.self) { squadron in
                    if let agents = grouped[squadron] {
                        SquadronSection(name: squadron.uppercased(), agents: agents)
                    }
                }
            }
            .padding()
        }
    }

    var squadronOrder: [String] {
        ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]
    }
}

struct SquadronSection: View {
    let name: String
    let agents: [AgentState]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.system(.headline, design: .monospaced))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 6) {
                ForEach(agents) { agent in
                    AgentCard(agent: agent)
                }
            }
        }
    }
}

struct AgentCard: View {
    let agent: AgentState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.id.replacingOccurrences(of: "_", with: " "))
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Text("\(agent.signalCount) signals")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if agent.errorCount > 0 {
                Text("\(agent.errorCount)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    var statusColor: Color {
        switch agent.status {
        case "active": return .green
        case "error": return .red
        case "idle": return .gray
        default: return .yellow
        }
    }
}

// MARK: - Signal Feed

@MainActor
struct SignalFeedView: View {
    let feed: SignalFeedStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SIGNAL FEED")
                .font(.system(.headline, design: .monospaced))
                .padding(.horizontal)
                .padding(.top, 8)

            List(feed.recentSignals) { signal in
                HStack {
                    Text(signal.signalType)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(signalColor(signal.signalType))
                    if !signal.symbol.isEmpty {
                        Text(signal.symbol)
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                    }
                    Spacer()
                    Text(signal.sourceAgent)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
        }
    }

    func signalColor(_ type: String) -> Color {
        if type.contains("kill") || type.contains("risk") { return .red }
        if type.contains("entry") { return .green }
        if type.contains("exit") { return .orange }
        return .blue
    }
}

// MARK: - Activity Feed

@MainActor
struct ActivityFeedView: View {
    let activity: ActivityStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ACTIVITY")
                .font(.system(.headline, design: .monospaced))
                .padding(.horizontal)
                .padding(.top, 8)

            List(activity.recentEvents) { event in
                HStack {
                    Image(systemName: severityIcon(event.severity))
                        .foregroundStyle(severityColor(event.severity))
                        .font(.caption)
                    Text(event.message)
                        .font(.system(.caption))
                        .lineLimit(2)
                    Spacer()
                }
            }
            .listStyle(.plain)
        }
    }

    func severityIcon(_ severity: ActivityEvent.Severity) -> String {
        switch severity {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    func severityColor(_ severity: ActivityEvent.Severity) -> Color {
        switch severity {
        case .info: return .blue
        case .warning: return .orange
        case .critical: return .red
        }
    }
}
