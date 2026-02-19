import Foundation

public struct ChatMessage: Identifiable, Sendable {
    public let id: String
    public let role: Role
    public let content: String
    public let timestamp: Date
    public var symbol: String?
    public var actionType: ActionType?

    public enum Role: String, Sendable {
        case user
        case assistant
        case system
    }

    public enum ActionType: String, Sendable {
        case buySignal
        case sellSignal
        case watchAlert
        case riskWarning
        case analysis
    }

    public init(
        id: String = UUID().uuidString,
        role: Role,
        content: String,
        timestamp: Date = Date(),
        symbol: String? = nil,
        actionType: ActionType? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.symbol = symbol
        self.actionType = actionType
    }
}

@MainActor
@Observable
public final class ChatStore {
    public var messages: [ChatMessage] = []
    public var inputText: String = ""
    public var isProcessing: Bool = false

    public init() {
        // Add welcome message
        messages.append(ChatMessage(
            role: .assistant,
            content: "CORTEX Intelligence online. I have full context on your portfolio, market signals, and risk parameters. Ask me about trade opportunities, market analysis, or portfolio strategy."
        ))
    }

    public func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        messages.append(ChatMessage(role: .user, content: text))
        inputText = ""
        isProcessing = true

        // Simulate AI response (in production, this goes to the Python backend)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            let response = generateMockResponse(for: text)
            messages.append(response)
            isProcessing = false
        }
    }

    private func generateMockResponse(for query: String) -> ChatMessage {
        let q = query.lowercased()

        if q.contains("aapl") || q.contains("apple") {
            return ChatMessage(
                role: .assistant,
                content: """
                **AAPL Analysis:**

                Current RSI(14): 58.3 -- neutral momentum, approaching overbought.

                MACD showing bullish crossover on the daily. Volume 1.2x average.

                **Signal:** Moderate BUY bias. Entry zone: $185-188, Stop: $181, Target: $195.

                Warning: Earnings in 12 days -- position size should account for vol expansion.
                """,
                symbol: "AAPL",
                actionType: .analysis
            )
        } else if q.contains("opportunit") || q.contains("trade") || q.contains("signal") {
            return ChatMessage(
                role: .assistant,
                content: """
                **Active Opportunities (filtered by ALPHA squadron):**

                **NVDA** -- Breakout above $890 resistance, RSI 62, Volume 1.8x avg
                - Entry: $892 | Stop: $875 | Target: $920 | R:R 1.6:1

                **MSFT** -- Consolidating at $415 support, MACD turning bullish
                - Watching for break above $420 with volume confirmation

                **TSLA** -- Below all moving averages, RSI 38, negative flow
                - Avoid longs. Short setup if breaks $170

                *Risk note: Daily drawdown at 2.1%, well within 7% limit.*
                """,
                actionType: .buySignal
            )
        } else if q.contains("portfolio") || q.contains("position") || q.contains("risk") {
            return ChatMessage(
                role: .assistant,
                content: """
                **Portfolio Status:**

                - NAV: $50,000 | Daily P&L: +$234.50 (+0.47%)
                - Open Positions: 3 | Win Rate: 67%
                - Daily Drawdown: 1.2% (limit: 7%)
                - Notional Exposure: $1,200 (cap: $500/trade)

                **Risk Assessment:** LOW -- All systems nominal. DrawdownShield green across all 3 clocks.

                Autonomy Level: SUGGEST_ONLY -- I'll flag opportunities but you approve trades.
                """,
                actionType: .analysis
            )
        } else if q.contains("kill") || q.contains("halt") || q.contains("stop") {
            return ChatMessage(
                role: .assistant,
                content: """
                **Kill Switch Status:** INACTIVE

                All trading systems operational. To engage the kill switch, use the button \
                in the War Room or say "engage kill switch."

                Warning: The kill switch is synchronous and in-memory -- zero network dependency. \
                It will halt ALL trading immediately across all squadrons.
                """,
                actionType: .riskWarning
            )
        } else {
            return ChatMessage(
                role: .assistant,
                content: """
                I can help with:

                - **Market Analysis** -- "Analyze AAPL" or "What's the setup on NVDA?"
                - **Trade Opportunities** -- "Show me trade signals" or "Any opportunities?"
                - **Portfolio Review** -- "How's my portfolio?" or "Risk status"
                - **Strategy** -- "Should I be more aggressive?" or "Sector rotation?"
                - **Risk Management** -- "Kill switch status" or "Drawdown levels"

                I have full context on all 44 agents across 6 squadrons.
                """
            )
        }
    }
}
