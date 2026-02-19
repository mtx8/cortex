import Foundation
import CortexCore

/// Routes incoming WebSocket JSON messages to the appropriate stores
/// based on the "type" key in each message payload.
@MainActor
public final class MessageRouter {
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
        setupRouting()
    }

    /// Wire the WebSocket onMessage callback to route messages to stores.
    private func setupRouting() {
        environment.webSocket.onMessage = { [weak self] message in
            guard let self else { return }
            self.route(message)
        }
    }

    /// Begin the WebSocket connection.
    public func start() {
        environment.webSocket.connect()
    }

    /// Stop the WebSocket connection.
    public func stop() {
        environment.webSocket.disconnect()
    }

    // MARK: - Routing

    private func route(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }

        let payload = message["payload"] as? [String: Any] ?? message

        switch type {
        case "portfolio_update":
            environment.portfolio.apply(payload)

        case "agent_update":
            if let agentId = payload["agent_id"] as? String {
                environment.squadrons.update(agentId: agentId, data: payload)
            }

        case "signal_fired":
            let signal = SignalEvent(
                id: payload["id"] as? String ?? UUID().uuidString,
                signalType: payload["signal_type"] as? String ?? "unknown",
                sourceAgent: payload["source_agent"] as? String ?? "unknown",
                sourceSquadron: payload["source_squadron"] as? String ?? "unknown",
                symbol: payload["symbol"] as? String ?? "",
                timestamp: Date(),
                payload: payload["meta"] as? [String: String] ?? [:]
            )
            environment.signalFeed.append(signal)

        case "kill_switch_status":
            let active = payload["active"] as? Bool ?? false
            if active {
                let reason = payload["reason"] as? String ?? "unknown"
                environment.killSwitch.confirmEngaged(reason: reason)
            } else {
                environment.killSwitch.disengage()
            }

        case "activity":
            let event = ActivityEvent(
                id: payload["id"] as? String ?? UUID().uuidString,
                eventType: payload["event_type"] as? String ?? "unknown",
                message: payload["message"] as? String ?? "",
                symbol: payload["symbol"] as? String ?? "",
                timestamp: Date(),
                severity: parseSeverity(payload["severity"] as? String)
            )
            environment.activity.append(event)

        default:
            break
        }
    }

    // MARK: - Helpers

    private func parseSeverity(_ raw: String?) -> ActivityEvent.Severity {
        switch raw {
        case "warning": return .warning
        case "critical": return .critical
        default: return .info
        }
    }
}
