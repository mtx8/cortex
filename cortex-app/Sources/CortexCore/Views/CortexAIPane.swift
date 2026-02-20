import SwiftUI

/// Contextual AI overlay pane that slides in from the right.
/// Shows chat interface with context-aware quick prompts.
public struct CortexAIPane: View {
    @Bindable var store: ChatStore
    let currentTab: AppTab
    let currentSection: String
    @Binding var isFullscreen: Bool
    let onClose: () -> Void

    public init(
        store: ChatStore,
        currentTab: AppTab,
        currentSection: String,
        isFullscreen: Binding<Bool>,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.currentTab = currentTab
        self.currentSection = currentSection
        self._isFullscreen = isFullscreen
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            aiHeader

            Divider()
                .overlay(Color(white: 0.12))

            // Messages
            aiMessageList

            Divider()
                .overlay(Color(white: 0.12))

            // Quick prompts
            quickPromptsRow

            Divider()
                .overlay(Color(white: 0.12))

            // Input area
            aiInputArea
        }
        .background(
            Color(nsColor: NSColor(
                red: 0.08, green: 0.08, blue: 0.12, alpha: 0.95
            ))
        )
    }

    // MARK: - Header

    private var aiHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.cyan)

            Text("Cortex AI")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)

            // Context badge
            HStack(spacing: 4) {
                Text(currentTab.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.cyan)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color(white: 0.4))
                Text(currentSection)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(white: 0.5))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.cyan.opacity(0.08))
            )

            Spacer()

            // Fullscreen toggle
            Button(action: { isFullscreen.toggle() }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(white: 0.5))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Toggle fullscreen")

            // Close button
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(white: 0.5))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close AI pane")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Message List

    private var aiMessageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.messages) { message in
                        AIMessageBubble(message: message)
                            .id(message.id)
                    }

                    if store.isProcessing && store.currentStreamingMessageId == nil {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Thinking...")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .id("typing")
                    }
                }
                .padding(14)
            }
            .onChange(of: store.messages.count) { _, _ in
                withAnimation {
                    proxy.scrollTo(store.messages.last?.id ?? "typing", anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Quick Prompts

    private var quickPromptsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(quickPromptsForTab, id: \.self) { prompt in
                    Button(action: {
                        store.inputText = prompt
                        store.sendMessage()
                    }) {
                        Text(prompt)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.cyan)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color.cyan.opacity(0.1))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(Color.cyan.opacity(0.2), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isProcessing)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private var quickPromptsForTab: [String] {
        switch currentTab {
        case .warRoom:
            return ["Risk summary", "Squadron health", "Market thesis"]
        case .scanner:
            return ["Explain top signal", "Short candidates?", "Sector rotation?"]
        case .financials:
            return ["Analyze this stock", "SEC filing summary", "Buy or short?"]
        case .markets:
            return ["Technical analysis", "Key levels", "Volume analysis"]
        default:
            return ["Portfolio summary", "Top opportunities", "Risk assessment"]
        }
    }

    // MARK: - Input Area

    private var aiInputArea: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 13))
                .foregroundStyle(Color(white: 0.4))

            TextField("Ask Cortex AI...", text: $store.inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { store.sendMessage() }

            Button(action: { store.sendMessage() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(store.inputText.isEmpty ? Color(white: 0.3) : .cyan)
            }
            .buttonStyle(.plain)
            .disabled(store.inputText.isEmpty || store.isProcessing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - AI Message Bubble

struct AIMessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .assistant {
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                    .foregroundStyle(.cyan)
                    .frame(width: 22, height: 22)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if let action = message.actionType {
                    aiBadge(action)
                }

                Text(LocalizedStringKey(message.content))
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(message.role == .user
                                  ? Color.blue.opacity(0.2)
                                  : Color(white: 0.10))
                    )

                Text(message.timestamp, style: .time)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)

            if message.role == .user {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.blue)
                    .frame(width: 22, height: 22)
            }
        }
    }

    @ViewBuilder
    private func aiBadge(_ action: ChatMessage.ActionType) -> some View {
        let (text, color): (String, Color) = switch action {
        case .buySignal: ("BUY SIGNAL", .green)
        case .sellSignal: ("SELL SIGNAL", .red)
        case .watchAlert: ("WATCH", .yellow)
        case .riskWarning: ("RISK", .orange)
        case .analysis: ("ANALYSIS", .blue)
        }

        Text(text)
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
