import SwiftUI

/// Detailed squadron management view showing all 6 squadrons and their agents
/// with collapsible sections, status badges, and real-time metrics.
public struct SquadronsDetailView: View {
    let squadrons: SquadronStore
    let webSocket: WebSocketClient
    @Environment(\.cortexSelectedSection) private var selectedSection

    public init(squadrons: SquadronStore, webSocket: WebSocketClient) {
        self.squadrons = squadrons
        self.webSocket = webSocket
    }

    struct SquadronInfo {
        let key: String
        let name: String
        let description: String
    }

    private let squadronDefs: [SquadronInfo] = [
        SquadronInfo(key: "alpha", name: "ALPHA", description: "Signal Intelligence"),
        SquadronInfo(key: "bravo", name: "BRAVO", description: "Order Execution"),
        SquadronInfo(key: "charlie", name: "CHARLIE", description: "Options Analysis"),
        SquadronInfo(key: "delta", name: "DELTA", description: "Market Intelligence"),
        SquadronInfo(key: "echo", name: "ECHO", description: "Risk Management"),
        SquadronInfo(key: "foxtrot", name: "FOXTROT", description: "Tax & Yield"),
        SquadronInfo(key: "golf", name: "GOLF", description: "Adaptive Learning"),
        SquadronInfo(key: "hotel", name: "HOTEL", description: "Market Microstructure"),
    ]

    /// Find a squadron definition by matching the section name to its key or name.
    private func squadronDef(for section: String) -> SquadronInfo? {
        squadronDefs.first { $0.name == section || $0.key == section.lowercased() }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            Divider().overlay(CortexDesign.bgElevated)

            if squadrons.agents.isEmpty {
                emptyState
            } else if selectedSection == "All Squadrons" || selectedSection == "Overview" {
                allSquadronsView
            } else if let info = squadronDef(for: selectedSection) {
                singleSquadronView(info: info)
            } else {
                allSquadronsView
            }
        }
        .background(CortexDesign.bgDeepest)
    }

    // MARK: - All Squadrons View

    @ViewBuilder
    private var allSquadronsView: some View {
        ScrollView {
            VStack(spacing: 2) {
                // Squadron performance summary strip
                squadronPerformanceSummary

                ForEach(squadronDefs, id: \.key) { info in
                    SquadronSection(
                        info: info,
                        agents: squadrons.agents.filter { $0.squadron == info.key }
                    )
                }
            }
            .padding(16)
        }
    }

    // MARK: - Performance Summary

    private var squadronPerformanceSummary: some View {
        let allAgents = squadrons.agents
        let totalAgents = allAgents.count
        let activeCount = allAgents.filter { $0.status == "active" }.count
        let totalSignals = allAgents.reduce(0) { $0 + $1.signalCount }
        let totalErrors = allAgents.reduce(0) { $0 + $1.errorCount }

        return HStack(spacing: 0) {
            summaryMetric(value: "\(totalAgents)", label: "TOTAL AGENTS", color: .white)
            Divider().frame(height: 28).overlay(CortexDesign.bgElevated)
            summaryMetric(value: "\(activeCount)", label: "ACTIVE", color: CortexDesign.profit)
            Divider().frame(height: 28).overlay(CortexDesign.bgElevated)
            summaryMetric(value: "\(totalSignals)", label: "SIGNALS", color: CortexDesign.accentPrimary)
            Divider().frame(height: 28).overlay(CortexDesign.bgElevated)
            summaryMetric(value: "\(totalErrors)", label: "ERRORS", color: totalErrors > 0 ? CortexDesign.loss : CortexDesign.neutral)
        }
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(CortexDesign.bgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(CortexDesign.border, lineWidth: 1)
                )
        )
        .padding(.bottom, 8)
    }

    private func summaryMetric(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(CortexDesign.neutral)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Single Squadron View

    @ViewBuilder
    private func singleSquadronView(info: SquadronInfo) -> some View {
        let agents = squadrons.agents.filter { $0.squadron == info.key }
        let activeCount = agents.filter { $0.status == "active" }.count
        let errorCount = agents.filter { $0.status == "error" }.count
        let totalSignals = agents.reduce(0) { $0 + $1.signalCount }

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Squadron header card
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(info.name)
                                .font(.system(size: 20, weight: .black, design: .monospaced))
                                .foregroundStyle(.white)

                            Text(info.description)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(CortexDesign.neutral)
                        }

                        Text("\(agents.count) agents registered")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(CortexDesign.neutral)
                    }

                    Spacer()

                    HStack(spacing: 16) {
                        singleSquadronStat("\(activeCount)", label: "Active", color: CortexDesign.profit)
                        singleSquadronStat("\(errorCount)", label: "Errors", color: errorCount > 0 ? CortexDesign.loss : CortexDesign.neutral)
                        singleSquadronStat("\(totalSignals)", label: "Signals", color: CortexDesign.accentPrimary)
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(CortexDesign.bgCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(CortexDesign.border, lineWidth: 1)
                )

                // Agent table header
                Text("AGENTS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)

                // Column headers
                HStack(spacing: 0) {
                    Text("AGENT")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("STATUS")
                        .frame(width: 90, alignment: .center)
                    Text("SIGNALS")
                        .frame(width: 80, alignment: .trailing)
                    Text("ERRORS")
                        .frame(width: 70, alignment: .trailing)
                    Text("LAST UPDATE")
                        .frame(width: 110, alignment: .trailing)
                }
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(CortexDesign.neutral)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                // Agent rows
                if agents.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.system(size: 40))
                            .foregroundStyle(CortexDesign.border)

                        Text("No agents registered")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(CortexDesign.neutral)

                        Text("Agents for \(info.name) squadron will appear when the backend starts")
                            .font(.system(size: 12))
                            .foregroundStyle(CortexDesign.neutral)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    VStack(spacing: 1) {
                        ForEach(agents) { agent in
                            AgentRow(agent: agent)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func singleSquadronStat(_ value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(CortexDesign.neutral)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Image(systemName: "person.3.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(CortexDesign.accentPrimary)
            Text("SQUADRONS")
                .font(.system(size: 14, weight: .black, design: .monospaced))
                .foregroundStyle(.white)

            Spacer()

            HStack(spacing: 12) {
                statusPill(
                    count: squadrons.agents.filter { $0.status == "active" }.count,
                    label: "Active",
                    color: CortexDesign.profit
                )
                statusPill(
                    count: squadrons.agents.filter { $0.status == "idle" }.count,
                    label: "Idle",
                    color: .yellow
                )
                statusPill(
                    count: squadrons.agents.filter { $0.status == "error" }.count,
                    label: "Error",
                    color: CortexDesign.loss
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func statusPill(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(count) \(label)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(CortexDesign.neutral)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            if webSocket.isConnected {
                ProgressView()
                    .controlSize(.small)
                    .tint(.cyan)

                Text("Waiting for agent data...")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text("Agent status updates are arriving shortly.")
                    .font(.system(size: 12))
                    .foregroundStyle(CortexDesign.neutral)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            } else {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(CortexDesign.neutral)

                Text("Backend Not Connected")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text("Start the Python backend to see agent status.\npython -m cortex.main")
                    .font(.system(size: 12))
                    .foregroundStyle(CortexDesign.neutral)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Squadron Section

private struct SquadronSection: View {
    let info: SquadronsDetailView.SquadronInfo
    let agents: [AgentState]
    @State private var isExpanded: Bool = true

    private var healthColor: Color {
        let errorCount = agents.filter { $0.status == "error" }.count
        if errorCount > 0 { return .red }
        let activeCount = agents.filter { $0.status == "active" }.count
        if activeCount == agents.count && !agents.isEmpty { return .green }
        return .yellow
    }

    var body: some View {
        VStack(spacing: 0) {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(spacing: 1) {
                    // Column headers
                    HStack(spacing: 0) {
                        Text("AGENT")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("STATUS")
                            .frame(width: 90, alignment: .center)
                        Text("SIGNALS")
                            .frame(width: 80, alignment: .trailing)
                        Text("ERRORS")
                            .frame(width: 70, alignment: .trailing)
                        Text("LAST UPDATE")
                            .frame(width: 110, alignment: .trailing)
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                    ForEach(agents) { agent in
                        AgentRow(agent: agent)
                    }

                    if agents.isEmpty {
                        Text("No agents registered")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(CortexDesign.neutral)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.bottom, 8)
            } label: {
                HStack(spacing: 10) {
                    // Health dot
                    Circle()
                        .fill(healthColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: healthColor.opacity(0.5), radius: 3)

                    Text(info.name)
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)

                    Text(info.description)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CortexDesign.neutral)

                    Spacer()

                    Text("\(agents.count) agents")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(CortexDesign.neutral)
                }
                .padding(.vertical, 4)
            }
            .tint(CortexDesign.neutral)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(CortexDesign.bgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(CortexDesign.border, lineWidth: 1)
                )
        )
        .padding(.vertical, 3)
    }
}

// MARK: - Agent Row

private struct AgentRow: View {
    let agent: AgentState
    @State private var isHovering: Bool = false

    private var statusColor: Color {
        switch agent.status {
        case "active": return .green
        case "idle": return .yellow
        case "error": return .red
        default: return .gray
        }
    }

    private var formattedName: String {
        agent.id.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var lastUpdateText: String {
        guard let ts = agent.lastSignalTs else { return "--" }
        let date = Date(timeIntervalSince1970: ts)
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    /// Approximate win rate from signal and error counts.
    private var winRate: String {
        let total = agent.signalCount + agent.errorCount
        guard total > 0 else { return "N/A" }
        let rate = Double(agent.signalCount) / Double(total) * 100.0
        return String(format: "%.1f%%", rate)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Agent name
            Text(formattedName)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Status badge
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(agent.status.capitalized)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(statusColor.opacity(0.1))
            )
            .frame(width: 90, alignment: .center)

            // Signal count
            Text("\(agent.signalCount)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(agent.signalCount > 0 ? CortexDesign.accentPrimary : CortexDesign.neutral)
                .frame(width: 80, alignment: .trailing)

            // Error count
            Text("\(agent.errorCount)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(agent.errorCount > 0 ? CortexDesign.loss : CortexDesign.neutral)
                .frame(width: 70, alignment: .trailing)

            // Last update
            Text(lastUpdateText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(CortexDesign.neutral)
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering ? CortexDesign.bgCard : CortexDesign.bgDeepest)
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .popover(isPresented: $isHovering, arrowEdge: .trailing) {
            agentTooltip
        }
    }

    // MARK: - Agent Tooltip

    private var agentTooltip: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Agent name and squadron
            VStack(alignment: .leading, spacing: 2) {
                Text(formattedName)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("Squadron: \(agent.squadron.uppercased())")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)
            }

            Divider().overlay(CortexDesign.border)

            // Status with colored dot
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusColor.opacity(0.6), radius: 3)
                Text("Status: \(agent.status.capitalized)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(statusColor)
            }

            // Signal and error counts
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Signals")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(CortexDesign.neutral)
                    Text("\(agent.signalCount)")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(CortexDesign.accentPrimary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Errors")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(CortexDesign.neutral)
                    Text("\(agent.errorCount)")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(agent.errorCount > 0 ? CortexDesign.loss : CortexDesign.neutral)
                }
            }

            // Last signal time
            HStack(spacing: 4) {
                Text("Last Signal:")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)
                Text(lastUpdateText)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)
            }

            // Win rate
            HStack(spacing: 4) {
                Text("Win Rate:")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)
                Text(winRate)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(CortexDesign.profit)
            }
        }
        .padding(12)
        .frame(width: 220)
        .background(CortexDesign.bgCard)
    }
}
