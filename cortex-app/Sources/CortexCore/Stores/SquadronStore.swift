import Foundation

public struct AgentState: Identifiable, Sendable {
    public let id: String
    public var squadron: String
    public var status: String
    public var signalCount: Int
    public var errorCount: Int
    public var lastSignalTs: Double?

    public init(
        id: String,
        squadron: String,
        status: String = "idle",
        signalCount: Int = 0,
        errorCount: Int = 0,
        lastSignalTs: Double? = nil
    ) {
        self.id = id
        self.squadron = squadron
        self.status = status
        self.signalCount = signalCount
        self.errorCount = errorCount
        self.lastSignalTs = lastSignalTs
    }
}

@MainActor
@Observable
public final class SquadronStore {
    public var agents: [AgentState] = []
    public var activeCount: Int { agents.filter { $0.status == "active" }.count }

    public init() {}

    public func loadMockData() {
        let agentData: [(String, String, String, Int, Int)] = [
            ("signal_hunter", "alpha", "active", 142, 2),
            ("volume_profiler", "alpha", "active", 89, 0),
            ("gap_scanner", "alpha", "active", 56, 1),
            ("order_sniper", "bravo", "active", 78, 0),
            ("spread_optimizer", "bravo", "active", 34, 0),
            ("greeks_engine", "charlie", "active", 67, 1),
            ("flow_intelligence", "charlie", "active", 45, 0),
            ("news_catalyst", "delta", "active", 203, 3),
            ("risk_guardian", "echo", "active", 312, 0),
            ("kill_switch", "echo", "active", 5, 0),
            ("position_sizer", "echo", "active", 156, 0),
            ("drawdown_shield", "echo", "active", 89, 0),
            ("wash_sale_guard", "foxtrot", "active", 23, 0),
            ("harvest_bot", "foxtrot", "idle", 0, 0),
        ]
        for (id, squad, status, signals, errors) in agentData {
            update(agentId: id, data: [
                "squadron": squad, "status": status,
                "signal_count": signals, "error_count": errors
            ])
        }
    }

    public func update(agentId: String, data: [String: Any]) {
        if let idx = agents.firstIndex(where: { $0.id == agentId }) {
            if let status = data["status"] as? String { agents[idx].status = status }
            if let sc = data["signal_count"] as? Int { agents[idx].signalCount = sc }
            if let ec = data["error_count"] as? Int { agents[idx].errorCount = ec }
        } else {
            agents.append(AgentState(
                id: agentId,
                squadron: data["squadron"] as? String ?? "unknown",
                status: data["status"] as? String ?? "idle",
                signalCount: data["signal_count"] as? Int ?? 0,
                errorCount: data["error_count"] as? Int ?? 0
            ))
        }
    }
}
