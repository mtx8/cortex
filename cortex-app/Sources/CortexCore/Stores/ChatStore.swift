import Foundation

public struct ChatMessage: Identifiable, Sendable {
    public let id: String
    public let role: Role
    public var content: String
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
    public var webSocket: WebSocketClient?
    public var currentStreamingMessageId: String?
    public var currentTab: String = ""
    public var currentSection: String = ""
    public var selectedSymbol: String = ""

    public init() {
        // Add welcome message
        messages.append(ChatMessage(
            role: .assistant,
            content: "CORTEX Intelligence online. I have full context on your portfolio, market signals, and risk parameters. Ask me about trade opportunities, market analysis, or portfolio strategy."
        ))
    }

    /// Quick prompt presets for the chat interface.
    public static let quickPrompts: [(label: String, prompt: String)] = [
        ("Biggest risk?", "What is the biggest risk in my portfolio right now?"),
        ("Top opportunity", "Show me the top trading opportunity right now"),
        ("Market thesis", "What is your current market thesis?"),
        ("Watch overnight", "What should I watch overnight?"),
        ("Sector rotation", "What sector rotation trends are you seeing?"),
    ]

    public func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        messages.append(ChatMessage(role: .user, content: text))
        inputText = ""
        isProcessing = true

        // Try to send via WebSocket first
        if let ws = webSocket, ws.isConnected {
            var context: [String: Any] = [
                "current_tab": currentTab,
                "current_section": currentSection,
            ]
            if !selectedSymbol.isEmpty {
                context["selected_symbol"] = selectedSymbol
            }
            let payload: [String: Any] = [
                "type": "cmd_chat_message",
                "payload": [
                    "message": text,
                    "conversation_id": "default",
                    "context": context,
                ] as [String: Any]
            ]
            // Create a placeholder streaming message
            let streamId = UUID().uuidString
            currentStreamingMessageId = streamId
            messages.append(ChatMessage(id: streamId, role: .assistant, content: ""))

            Task { @MainActor in
                do {
                    try await ws.send(payload)
                } catch {
                    // If WebSocket send fails, fall back to mock
                    currentStreamingMessageId = nil
                    if let idx = messages.firstIndex(where: { $0.id == streamId }) {
                        messages.remove(at: idx)
                    }
                    fallbackMockResponse(for: text)
                }
            }

            // Streaming timeout safety net: auto-recover if stuck
            let capturedStreamId = streamId
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(90))
                guard isProcessing, currentStreamingMessageId == capturedStreamId else { return }
                if let idx = messages.firstIndex(where: { $0.id == capturedStreamId }) {
                    if messages[idx].content.isEmpty {
                        messages[idx].content = "Response timed out. Please try again."
                    }
                }
                finishStreaming()
            }
        } else {
            // Fallback: simulate AI response when WebSocket is not connected
            fallbackMockResponse(for: text)
        }
    }

    /// Append a chunk of streamed text to the current streaming message.
    public func appendChunk(_ chunk: String) {
        // Skip internal status markers
        guard !chunk.hasPrefix("__STATUS__:") else { return }
        guard let streamId = currentStreamingMessageId,
              let idx = messages.firstIndex(where: { $0.id == streamId }) else { return }
        messages[idx].content += chunk
    }

    /// Finish the streaming response.
    public func finishStreaming() {
        currentStreamingMessageId = nil
        isProcessing = false
    }

    // MARK: - Mock Response Fallback

    private func fallbackMockResponse(for query: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            let response = generateMockResponse(for: query)
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
        } else if q.contains("risk") || q.contains("biggest risk") {
            return ChatMessage(
                role: .assistant,
                content: """
                **Portfolio Risk Assessment:**

                Top 3 risks right now:

                1. **Concentration Risk** -- 60% exposure to tech sector. NVDA and META are correlated.
                2. **Earnings Risk** -- AAPL reports in 12 days. Consider hedging or reducing size.
                3. **Macro Risk** -- Fed speakers this week could move rates. SPY at key resistance.

                **Recommendation:** Consider trimming NVDA by 30% to reduce sector concentration. \
                Add a SPY put spread as portfolio hedge.
                """,
                actionType: .riskWarning
            )
        } else if q.contains("opportunit") || q.contains("trade") || q.contains("signal") || q.contains("top") {
            return ChatMessage(
                role: .assistant,
                content: """
                **Active Opportunities (filtered by ALPHA squadron):**

                **NVDA** -- Breakout above $890 resistance, RSI 62, Volume 1.8x avg
                - Entry: $892 | Stop: $875 | Target: $920 | R:R 1.6:1

                **META** -- RSI bounce from oversold, AD line improving
                - Entry: $502 | Stop: $490 | Target: $530 | R:R 2.3:1

                **AMD** -- Unusual call volume 2.5x, AI chip demand narrative
                - Watching for break above $180 with volume confirmation

                *Risk note: Daily drawdown at 2.1%, well within 7% limit.*
                """,
                actionType: .buySignal
            )
        } else if q.contains("thesis") || q.contains("market") {
            return ChatMessage(
                role: .assistant,
                content: """
                **Current Market Thesis:**

                **Bullish bias** with caution near resistance levels.

                - SPY holding above 20-day MA, breadth improving
                - Tech leading but extended -- selective entries only
                - AI narrative still driving NVDA/AMD/META momentum
                - Rates stable; no imminent Fed hawkishness
                - VIX at 14.2 -- complacency suggests hedges are cheap

                **Strategy:** Continue buying dips in quality names. \
                Keep position sizes moderate. Trail stops tighter on extended moves.
                """,
                actionType: .analysis
            )
        } else if q.contains("overnight") || q.contains("watch") {
            return ChatMessage(
                role: .assistant,
                content: """
                **Overnight Watch List:**

                - **NVDA** -- After-hours movement on AI conference news. Watch $895 level.
                - **TSLA** -- Oversold bounce possible. Gap fill target at $178.
                - **BTC-USD** -- Testing $68K resistance. Breakout could trigger altcoin rally.
                - **Futures** -- ES at 5,125. Watch Asian session for directional bias.

                **Key Events Tomorrow:**
                - 8:30 AM -- CPI data release
                - 10:00 AM -- Consumer sentiment
                - Multiple Fed speakers throughout the day
                """,
                actionType: .watchAlert
            )
        } else if q.contains("sector") || q.contains("rotation") {
            return ChatMessage(
                role: .assistant,
                content: """
                **Sector Rotation Analysis:**

                **Inflows:** Technology (+2.3%), Communication Services (+1.8%), Consumer Discretionary (+1.1%)
                **Outflows:** Utilities (-1.5%), Real Estate (-1.2%), Staples (-0.8%)

                **Key Observations:**
                - Growth > Value rotation accelerating
                - Small caps (IWM) lagging -- risk-off signal for breadth
                - Energy flat despite oil recovery -- watch for catch-up trade
                - Financials strengthening on yield curve steepening

                **Action:** Overweight tech/comms, underweight defensives. Watch for IWM breakout as breadth confirmation.
                """,
                actionType: .analysis
            )
        } else {
            return ChatMessage(
                role: .assistant,
                content: """
                I'm currently in **offline mode** -- the Python backend is not connected, so I can't access live AI.

                While offline, try these keywords for cached analysis:
                - **"AAPL"** or **"Apple"** -- Ticker analysis
                - **"risk"** -- Portfolio risk assessment
                - **"opportunity"** or **"trade"** or **"signal"** -- Active opportunities
                - **"thesis"** or **"market"** -- Market thesis
                - **"overnight"** or **"watch"** -- Overnight watch list
                - **"sector"** or **"rotation"** -- Sector rotation analysis

                Start the Python backend (`python -m cortex.main`) for full AI-powered analysis.
                """
            )
        }
    }
}
