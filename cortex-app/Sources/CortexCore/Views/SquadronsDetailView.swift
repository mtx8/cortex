import SwiftUI

/// Detailed squadron management view showing all 6 squadrons and their agents
/// with collapsible sections, status badges, and real-time metrics.
public struct SquadronsDetailView: View {
    let squadrons: SquadronStore

    public init(squadrons: SquadronStore) {
        self.squadrons = squadrons
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
    ]

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            Divider().overlay(Color(white: 0.15))

            if squadrons.agents.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 2) {
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
        }
        .background(Color(nsColor: NSColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1.0)))
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Image(systemName: "person.3.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.cyan)
            Text("SQUADRONS")
                .font(.system(size: 14, weight: .black, design: .monospaced))
                .foregroundStyle(.white)

            Spacer()

            HStack(spacing: 12) {
                statusPill(
                    count: squadrons.agents.filter { $0.status == "active" }.count,
                    label: "Active",
                    color: .green
                )
                statusPill(
                    count: squadrons.agents.filter { $0.status == "idle" }.count,
                    label: "Idle",
                    color: .yellow
                )
                statusPill(
                    count: squadrons.agents.filter { $0.status == "error" }.count,
                    label: "Error",
                    color: .red
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
                .foregroundStyle(Color(white: 0.6))
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            ProgressView()
                .controlSize(.small)
                .tint(.cyan)

            Text("Waiting for agent data...")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            Text("Agent status will appear when the Python backend is connected.")
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.4))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

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
                    .foregroundStyle(Color(white: 0.35))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                    ForEach(agents) { agent in
                        AgentRow(agent: agent)
                    }

                    if agents.isEmpty {
                        Text("No agents registered")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color(white: 0.3))
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
                        .foregroundStyle(Color(white: 0.45))

                    Spacer()

                    Text("\(agents.count) agents")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(white: 0.4))
                }
                .padding(.vertical, 4)
            }
            .tint(Color(white: 0.4))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(white: 0.12), lineWidth: 1)
                )
        )
        .padding(.vertical, 3)
    }
}

// MARK: - Agent Row

private struct AgentRow: View {
    let agent: AgentState

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
                .foregroundStyle(agent.signalCount > 0 ? .cyan : Color(white: 0.35))
                .frame(width: 80, alignment: .trailing)

            // Error count
            Text("\(agent.errorCount)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(agent.errorCount > 0 ? .red : Color(white: 0.35))
                .frame(width: 70, alignment: .trailing)

            // Last update
            Text(lastUpdateText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(white: 0.45))
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.06))
        )
    }
}
