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
        // Wire WebSocket reference into ChatStore for sending
        environment.chat.webSocket = environment.webSocket
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

        case "activity", "activity_event":
            let event = ActivityEvent(
                id: payload["id"] as? String ?? UUID().uuidString,
                eventType: payload["event_type"] as? String ?? "unknown",
                message: payload["message"] as? String ?? "",
                symbol: payload["symbol"] as? String ?? "",
                timestamp: Date(),
                severity: parseSeverity(payload["severity"] as? String)
            )
            environment.activity.append(event)

        // MARK: - Chat Streaming

        case "chat_chunk":
            let chunk = payload["chunk"] as? String ?? ""
            let done = payload["done"] as? Bool ?? false
            if !done {
                environment.chat.appendChunk(chunk)
            } else {
                environment.chat.finishStreaming()
            }

        // MARK: - Market Data

        case "market_quote":
            let symbol = payload["symbol"] as? String ?? ""
            let price = payload["price"] as? Double ?? 0
            let change = payload["change"] as? Double ?? 0
            let changePct = payload["change_percent"] as? Double ?? 0
            environment.watchlist.updatePrice(
                symbol: symbol,
                price: price,
                change: change,
                changePercent: changePct
            )

        // MARK: - Opportunities

        case "opportunity":
            environment.opportunities.apply(payload)

        // MARK: - Ticker Search Results

        case "ticker_search_results":
            if let results = payload["results"] as? [[String: String]] {
                let items = results.map { item in
                    (ticker: item["ticker"] ?? "", name: item["name"] ?? "")
                }
                environment.search.applyRemoteResults(items)
            }

        // MARK: - Scanner Results

        case "scanner_result":
            // Scanner results can update both signal feed and opportunity store
            if let ticker = payload["ticker"] as? String,
               let score = payload["composite_score"] as? Double {
                let opp = Opportunity(
                    id: payload["id"] as? String ?? UUID().uuidString,
                    ticker: ticker,
                    compositeScore: score,
                    type: Opportunity.OpportunityType(rawValue: payload["type"] as? String ?? "Momentum") ?? .momentum,
                    thesis: payload["thesis"] as? String ?? "",
                    riskReward: payload["risk_reward"] as? Double ?? 0,
                    timestamp: Date()
                )
                environment.opportunities.append(opp)
            }

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
