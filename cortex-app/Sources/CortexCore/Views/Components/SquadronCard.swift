import SwiftUI

/// Rich squadron status card with health pulse, stats, error indicators,
/// and utilization bar for the War Room command grid.
@MainActor
public struct SquadronCard: View {
    let name: String
    let agents: [AgentState]

    @State private var isHovered = false
    @State private var pulseOpacity: Double = 1.0

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

    private var utilizationPercent: Double {
        guard !agents.isEmpty else { return 0 }
        return Double(activeCount) / Double(agents.count)
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

        var label: String {
            switch self {
            case .healthy: return "ACTIVE"
            case .warning: return "IDLE"
            case .critical: return "ERROR"
            }
        }
    }

    /// Squadron role descriptions.
    private var subtitle: String {
        switch name {
        case "ALPHA": return "Signal Detection & Scanning"
        case "BRAVO": return "Order Execution & Routing"
        case "CHARLIE": return "Options & Flow Analysis"
        case "DELTA": return "News & Catalyst Intelligence"
        case "ECHO": return "Risk Management & Protection"
        case "FOXTROT": return "Tax & Compliance"
        default: return "Autonomous Agents"
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row: health dot + name + status badge
            HStack(spacing: 8) {
                Circle()
                    .fill(health.color)
                    .frame(width: 8, height: 8)
                    .opacity(health == .healthy ? pulseOpacity : 1.0)
                    .onAppear {
                        if health == .healthy {
                            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                                pulseOpacity = 0.4
                            }
                        }
                    }

                Text(name)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)

                Spacer()

                // Status badge
                Text(health.label)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(health.color.opacity(0.15))
                    .foregroundStyle(health.color)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            // Subtitle description
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(CortexDesign.neutral)
                .lineLimit(1)

            // Stats row: agents + signals + errors
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Text("AGENTS:")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(CortexDesign.neutral)
                    Text("\(activeCount)/\(agents.count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }

                HStack(spacing: 4) {
                    Text("SIGNALS:")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(CortexDesign.neutral)
                    Text("\(totalSignals)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }

                Spacer()

                // Error badge (only if errors > 0)
                if totalErrors > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                        Text("\(totalErrors)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(CortexDesign.loss)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(CortexDesign.loss.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            // Utilization bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(CortexDesign.border)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            LinearGradient(
                                colors: [CortexDesign.accentPrimary, CortexDesign.profit],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, geo.size.width * utilizationPercent))
                }
            }
            .frame(height: 3)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(CortexDesign.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    health.color.opacity(isHovered ? 0.4 : 0.2),
                    lineWidth: 1
                )
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

/// 3-column grid of squadron status cards for the War Room.
@MainActor
public struct SquadronStatusGrid: View {
    let squadrons: SquadronStore

    public init(squadrons: SquadronStore) {
        self.squadrons = squadrons
    }

    private let squadronOrder = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SQUADRON COMMAND")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)
                Spacer()
                Text("\(squadrons.activeCount) agents active")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)
            }
            .padding(.horizontal, 4)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
            ], spacing: 10) {
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
