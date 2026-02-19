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
