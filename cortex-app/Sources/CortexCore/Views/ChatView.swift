import SwiftUI

public struct ChatView: View {
    @Bindable var store: ChatStore

    public init(store: ChatStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Chat header
            HStack {
                Image(systemName: "brain.head.profile")
                    .font(.title2)
                    .foregroundStyle(.purple)
                Text("CORTEX Intelligence")
                    .font(.title3.bold())
                Spacer()
                Text("\(store.messages.count - 1) messages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.bar)

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(store.messages) { message in
                            ChatBubble(message: message)
                                .id(message.id)
                        }

                        if store.isProcessing {
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
                    .padding()
                }
                .onChange(of: store.messages.count) { _, _ in
                    withAnimation {
                        proxy.scrollTo(store.messages.last?.id ?? "typing", anchor: .bottom)
                    }
                }
            }

            Divider()

            // Input area
            HStack(spacing: 12) {
                TextField("Ask about trades, signals, portfolio...", text: $store.inputText)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .onSubmit { store.sendMessage() }

                Button(action: { store.sendMessage() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(store.inputText.isEmpty ? .gray : .blue)
                }
                .buttonStyle(.plain)
                .disabled(store.inputText.isEmpty || store.isProcessing)
            }
            .padding()
            .background(.bar)
        }
    }
}

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .assistant {
                Image(systemName: "brain.head.profile")
                    .font(.title3)
                    .foregroundStyle(.purple)
                    .frame(width: 28, height: 28)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if let action = message.actionType {
                    actionBadge(action)
                }

                Text(LocalizedStringKey(message.content))
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(message.role == .user
                                  ? Color.blue.opacity(0.2)
                                  : Color(.controlBackgroundColor))
                    )

                if let symbol = message.symbol {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.caption2)
                        Text(symbol)
                            .font(.caption2.bold())
                    }
                    .foregroundStyle(.secondary)
                }

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 600, alignment: message.role == .user ? .trailing : .leading)

            if message.role == .user {
                Image(systemName: "person.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .frame(width: 28, height: 28)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    @ViewBuilder
    func actionBadge(_ action: ChatMessage.ActionType) -> some View {
        let (text, color): (String, Color) = switch action {
        case .buySignal: ("BUY SIGNAL", .green)
        case .sellSignal: ("SELL SIGNAL", .red)
        case .watchAlert: ("WATCH", .yellow)
        case .riskWarning: ("RISK", .orange)
        case .analysis: ("ANALYSIS", .blue)
        }

        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
