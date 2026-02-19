import SwiftUI

/// Compact card displaying squadron status for the War Room grid.
/// Shows squadron name, active/total agent count, signals generated, and health indicator.
@MainActor
public struct SquadronCard: View {
    let name: String
    let agents: [AgentState]

    public init(name: String, agents: [AgentState]) {
        self.name = name
        self.agents = agents
    }

    private var activeCount: Int {
        agents.filter { $0.status == "active" }.count
    }

    private var totalSignals: Int {
        agents.reduce(0) { $0 + $1.signalCount }
    }

    private var totalErrors: Int {
        agents.reduce(0) { $0 + $1.errorCount }
    }

    private var health: HealthStatus {
        if agents.contains(where: { $0.status == "error" }) || totalErrors > 5 { return .critical }
        if agents.contains(where: { $0.status == "idle" }) || totalErrors > 0 { return .warning }
        return .healthy
    }

    private enum HealthStatus {
        case healthy, warning, critical

        var color: Color {
            switch self {
            case .healthy: return .green
            case .warning: return .yellow
            case .critical: return .red
            }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: name + health indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(health.color)
                    .frame(width: 8, height: 8)

                Text(name)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)

                Spacer()

                Text("\(activeCount)/\(agents.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Metrics row
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Signals")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("\(totalSignals)")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Errors")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("\(totalErrors)")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(totalErrors > 0 ? .red : Color(white: 0.5))
                }

                Spacer()
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(health.color.opacity(0.3), lineWidth: 1)
        )
    }
}

/// 3-column grid of squadron status cards.
@MainActor
public struct SquadronStatusGrid: View {
    let squadrons: SquadronStore

    public init(squadrons: SquadronStore) {
        self.squadrons = squadrons
    }

    private let squadronOrder = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SQUADRON STATUS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(squadrons.activeCount) agents active")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
            ], spacing: 8) {
                let grouped = Dictionary(grouping: squadrons.agents) { $0.squadron }
                ForEach(squadronOrder, id: \.self) { squadron in
                    SquadronCard(
                        name: squadron.uppercased(),
                        agents: grouped[squadron] ?? []
                    )
                }
            }
        }
        .padding(12)
    }
}
