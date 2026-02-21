import SwiftUI

public struct ChatView: View {
    @Bindable var store: ChatStore
    var opportunities: OpportunityStore?

    public init(store: ChatStore, opportunities: OpportunityStore? = nil) {
        self.store = store
        self.opportunities = opportunities
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header bar
            chatHeader

            Divider()
                .overlay(CortexDesign.bgElevated)

            // Quick prompt buttons
            quickPromptsBar

            Divider()
                .overlay(CortexDesign.bgElevated)

            // Main area: Chat + Opportunity side panel
            HSplitView {
                // Chat messages
                chatMessagesArea
                    .frame(minWidth: 400)

                // Opportunity side panel
                if let opps = opportunities {
                    opportunitySidePanel(opps)
                        .frame(width: 250)
                }
            }

            Divider()
                .overlay(CortexDesign.bgElevated)

            // Input area
            chatInputArea
        }
        .background(CortexDesign.bgDeepest)
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 18))
                .foregroundStyle(.purple)

            Text("CORTEX Intelligence")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)

            Spacer()

            // Connection indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(store.webSocket?.isConnected == true ? CortexDesign.profit : CortexDesign.warning)
                    .frame(width: 6, height: 6)
                Text(store.webSocket?.isConnected == true ? "Live" : "Local")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text("\(store.messages.count - 1) messages")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(CortexDesign.bgCard)
    }

    // MARK: - Quick Prompts

    private var quickPromptsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ChatStore.quickPrompts, id: \.label) { prompt in
                    Button(action: {
                        store.inputText = prompt.prompt
                        store.sendMessage()
                    }) {
                        Text(prompt.label)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color.purple.opacity(0.15))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(Color.purple.opacity(0.3), lineWidth: 1)
                            )
                            .foregroundStyle(.purple)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isProcessing)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(CortexDesign.bgCard)
    }

    // MARK: - Chat Messages Area

    private var chatMessagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.messages) { message in
                        ChatBubble(message: message)
                            .id(message.id)
                    }

                    if store.isProcessing && store.currentStreamingMessageId == nil {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Analyzing...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                        .id("typing")
                    }
                }
                .padding(16)
            }
            .onChange(of: store.messages.count) { _, _ in
                withAnimation {
                    proxy.scrollTo(store.messages.last?.id ?? "typing", anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Opportunity Side Panel

    @MainActor
    private func opportunitySidePanel(_ opps: OpportunityStore) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TOP OPPORTUNITIES")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(opps.top5) { opp in
                        OpportunitySidePanelCard(opportunity: opp)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .background(CortexDesign.bgCard)
    }

    // MARK: - Input Area

    private var chatInputArea: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            TextField("Ask about trades, signals, portfolio...", text: $store.inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { store.sendMessage() }

            Button(action: { store.sendMessage() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(store.inputText.isEmpty ? CortexDesign.neutral : CortexDesign.accentSecondary)
            }
            .buttonStyle(.plain)
            .disabled(store.inputText.isEmpty || store.isProcessing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(CortexDesign.bgCard)
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .assistant {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 16))
                    .foregroundStyle(.purple)
                    .frame(width: 24, height: 24)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if let action = message.actionType {
                    actionBadge(action)
                }

                Text(LocalizedStringKey(message.content))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(message.role == .user
                                  ? CortexDesign.accentSecondary.opacity(0.2)
                                  : CortexDesign.bgHover)
                    )

                if let symbol = message.symbol {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 9))
                        Text(symbol)
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                }

                Text(message.timestamp, style: .time)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 600, alignment: message.role == .user ? .trailing : .leading)

            if message.role == .user {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)
                    .frame(width: 24, height: 24)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    @ViewBuilder
    func actionBadge(_ action: ChatMessage.ActionType) -> some View {
        let (text, color): (String, Color) = switch action {
        case .buySignal: ("BUY SIGNAL", CortexDesign.profit)
        case .sellSignal: ("SELL SIGNAL", CortexDesign.loss)
        case .watchAlert: ("WATCH", .yellow)
        case .riskWarning: ("RISK", CortexDesign.warning)
        case .analysis: ("ANALYSIS", CortexDesign.accentSecondary)
        }

        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Opportunity Side Panel Card

struct OpportunitySidePanelCard: View {
    let opportunity: Opportunity

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(opportunity.ticker)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)

                Spacer()

                Text(opportunity.type.rawValue)
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(badgeColor.opacity(0.2))
                    .foregroundStyle(badgeColor)
                    .clipShape(Capsule())
            }

            // Score bar
            HStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(CortexDesign.bgElevated)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(scoreColor)
                            .frame(width: max(0, geo.size.width * opportunity.compositeScore / 100))
                    }
                }
                .frame(height: 4)

                Text(String(format: "%.0f", opportunity.compositeScore))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(scoreColor)
                    .frame(width: 24, alignment: .trailing)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(CortexDesign.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(CortexDesign.border, lineWidth: 1)
        )
    }

    private var badgeColor: Color {
        switch opportunity.type {
        case .momentum: return .blue
        case .volume: return .purple
        case .catalyst: return .orange
        case .breakout: return .green
        case .reversal: return .yellow
        case .flow: return .cyan
        case .earnings: return .mint
        case .sector: return .indigo
        }
    }

    private var scoreColor: Color {
        if opportunity.compositeScore >= 80 { return .green }
        if opportunity.compositeScore >= 60 { return .yellow }
        return .orange
    }
}
