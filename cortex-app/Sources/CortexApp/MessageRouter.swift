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
        // Wire WebSocket reference into FinancialsStore for sending
        environment.financials.webSocket = environment.webSocket
        // Wire WebSocket references into new stores
        environment.trade.webSocket = environment.webSocket
        environment.options.webSocket = environment.webSocket
        environment.simulation.webSocket = environment.webSocket
        environment.alerts.webSocket = environment.webSocket
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
            // Geo physical-alpha signals (india.geo_*) also feed the globe panel.
            if let st = payload["signal_type"] as? String, st.hasPrefix("india.geo") {
                environment.geoIntelligence.applyBusSignal(type: st, payload)
            }

        // MARK: - Geo-Intelligence (maritime AIS + seismic)

        case "geo_position":
            environment.geoIntelligence.applyVessels(payload)

        case "geo_signal":
            environment.geoIntelligence.applyEvents(payload)

        case "macro_rates":
            environment.macroRates.apply(payload)

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

        // Handle error responses from chat (prevents stuck UI)
        case "chat_response":
            if let error = payload["error"] as? String {
                environment.chat.appendChunk(error)
                environment.chat.finishStreaming()
            }

        // MARK: - Market Data

        case "market_quote":
            let symbol = payload["ticker"] as? String ?? payload["symbol"] as? String ?? ""
            let price = payload["price"] as? Double ?? 0
            let change = payload["change"] as? Double ?? 0
            let changePct = payload["change_pct"] as? Double ?? 0
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

        // MARK: - Financials

        case "financials_profile":
            environment.financials.applyProfile(payload)

        case "financials_news":
            if let items = payload["items"] as? [[String: Any]] {
                environment.financials.applyNews(items)
            }

        case "financials_filings":
            if let items = payload["items"] as? [[String: Any]] {
                environment.financials.applyFilings(items)
            }

        case "financials_sentiment":
            environment.financials.applySentiment(payload)

        case "financials_ai_analysis":
            environment.financials.applyAIAnalysis(payload)

        case "financials_error":
            let error = payload["error"] as? String ?? "Unknown error"
            environment.financials.applyError(error)

        // MARK: - Level 2 / Time & Sales

        case "l2_update":
            environment.level2.applyL2Update(payload)

        case "time_sales":
            environment.level2.applyTimeSales(payload)

        // MARK: - Trade / Positions / Orders

        case "position_update":
            environment.trade.applyPositionUpdate(payload)

        case "order_status":
            environment.trade.applyOrderStatus(payload)

        // MARK: - Options

        case "option_chain_data":
            environment.options.applyOptionChain(payload)

        case "profit_calculation":
            environment.options.applyProfitCalculation(payload)

        // MARK: - Simulation

        case "simulation_update":
            environment.simulation.applySimulationUpdate(payload)

        case "learning_insight":
            environment.simulation.applyLearningInsight(payload)

        // MARK: - Alerts

        case "alert_triggered":
            environment.alerts.applyTriggered(payload)

        // MARK: - Scanner Results

        case "scanner_result":
            // Scanner results can update both signal feed and opportunity store
            if let ticker = payload["ticker"] as? String,
               let score = payload["composite_score"] as? Double {
                let dirStr = payload["direction"] as? String ?? "LONG"
                let dir: OpportunityDirection = dirStr.uppercased() == "SHORT" ? .short : .long
                let opp = Opportunity(
                    id: payload["id"] as? String ?? UUID().uuidString,
                    ticker: ticker,
                    compositeScore: score,
                    type: Opportunity.OpportunityType(rawValue: payload["type"] as? String ?? "Momentum") ?? .momentum,
                    thesis: payload["thesis"] as? String ?? "",
                    riskReward: payload["risk_reward"] as? Double ?? 0,
                    timestamp: Date(),
                    direction: dir,
                    sector: payload["sector"] as? String,
                    market: payload["market"] as? String,
                    marketCap: payload["market_cap"] as? String,
                    shortInterest: payload["short_interest"] as? Double,
                    aiInsight: payload["ai_insight"] as? String
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
