import SwiftUI

/// Contextual AI overlay pane that slides in from the right.
/// Shows chat interface with context-aware quick prompts.
public struct CortexAIPane: View {
    @Bindable var store: ChatStore
    let currentTab: AppTab
    let currentSection: String
    @Binding var isFullscreen: Bool
    let onClose: () -> Void

    @FocusState private var isInputFocused: Bool

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
                .overlay(CortexDesign.border)

            // Messages
            aiMessageList

            Divider()
                .overlay(CortexDesign.border)

            // Quick prompts
            quickPromptsRow

            // Input area
            aiInputArea
        }
        .background(CortexDesign.bgCard)
    }

    // MARK: - Header

    private var aiHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(CortexDesign.accentPrimary)

            Text("Cortex AI")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)

            // Context badge
            HStack(spacing: 4) {
                Text(currentTab.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CortexDesign.accentPrimary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(CortexDesign.neutral)
                Text(currentSection)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CortexDesign.neutral)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(CortexDesign.accentPrimary.opacity(0.08))
            )

            Spacer()

            // Fullscreen toggle
            Button(action: { isFullscreen.toggle() }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CortexDesign.neutral)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Toggle fullscreen")

            // Close button
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CortexDesign.neutral)
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
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity
                            ))
                    }

                    if store.isProcessing && store.currentStreamingMessageId == nil {
                        TypingIndicator()
                            .id("typing")
                    }
                }
                .padding(14)
            }
            .onChange(of: store.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) {
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
                    QuickPromptPill(label: prompt) {
                        store.currentTab = currentTab.rawValue
                        store.currentSection = currentSection
                        store.inputText = prompt
                        store.sendMessage()
                    }
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
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 14)
                .fill(CortexDesign.bgHover)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(
                            isInputFocused ? CortexDesign.accentPrimary.opacity(0.3) : CortexDesign.bgElevated,
                            lineWidth: 1
                        )
                )
                .overlay(
                    HStack(spacing: 10) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 13))
                            .foregroundStyle(CortexDesign.neutral)

                        TextField("Ask Cortex AI anything...", text: $store.inputText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                            .focused($isInputFocused)
                            .onSubmit {
                                store.currentTab = currentTab.rawValue
                                store.currentSection = currentSection
                                store.sendMessage()
                            }

                        Button(action: {
                            store.currentTab = currentTab.rawValue
                            store.currentSection = currentSection
                            store.sendMessage()
                        }) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(store.inputText.isEmpty ? CortexDesign.neutral : CortexDesign.accentPrimary)
                                .animation(.easeInOut(duration: 0.2), value: store.inputText.isEmpty)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.inputText.isEmpty || store.isProcessing)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                )
                .frame(height: 48)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        }
        .padding(16)
    }
}

// MARK: - Quick Prompt Pill

private struct QuickPromptPill: View {
    let label: String
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(CortexDesign.accentPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(isHovered ? CortexDesign.accentPrimary.opacity(0.1) : CortexDesign.bgCard)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isHovered ? CortexDesign.accentPrimary.opacity(0.3) : CortexDesign.bgElevated,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Typing Indicator

private struct TypingIndicator: View {
    @State private var dotPhase: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13))
                .foregroundStyle(CortexDesign.accentPrimary)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 6) {
                Text("Cortex AI is thinking...")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CortexDesign.neutral)

                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(CortexDesign.accentPrimary.opacity(0.6))
                            .frame(width: 6, height: 6)
                            .offset(y: dotPhase ? -4 : 0)
                            .animation(
                                .easeInOut(duration: 0.6)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.2),
                                value: dotPhase
                            )
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(CortexDesign.bgCard)
            )
        }
        .onAppear {
            dotPhase = true
        }
    }
}

// MARK: - AI Message Bubble

struct AIMessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if !isUser {
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                    .foregroundStyle(CortexDesign.accentPrimary)
                    .frame(width: 22, height: 22)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                // Role label
                if !isUser {
                    HStack(spacing: 4) {
                        Text("Cortex AI")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CortexDesign.neutral)
                        Image(systemName: "sparkles")
                            .font(.system(size: 10))
                            .foregroundStyle(.cyan.opacity(0.6))
                    }
                }

                if let action = message.actionType {
                    aiBadge(action)
                }

                // Message content
                MarkdownMessageView(
                    content: message.content,
                    isUser: isUser
                )
                .textSelection(.enabled)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(isUser
                              ? CortexDesign.accentSecondary.opacity(0.15)
                              : CortexDesign.bgCard)
                )
                .frame(
                    maxWidth: isUser ? 340 : 378,
                    alignment: isUser ? .trailing : .leading
                )

                // Timestamp
                Text(message.timestamp, style: .time)
                    .font(.system(size: 10))
                    .foregroundStyle(CortexDesign.neutral)
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)

            if isUser {
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

// MARK: - Markdown Message View

struct MarkdownMessageView: View {
    let content: String
    let isUser: Bool

    private var defaultTextColor: Color {
        isUser ? .white : .white.opacity(0.85)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let blocks = parseBlocks(content)
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
    }

    // MARK: - Block Types

    private enum MarkdownBlock {
        case header(level: Int, text: String)
        case bullet(text: String)
        case numbered(number: String, text: String)
        case codeBlock(language: String?, lines: [String])
        case blockquote(text: String)
        case paragraph(text: String)
    }

    // MARK: - Block Parser

    private func parseBlocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Empty line -- skip
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Code block (triple backtick)
            if trimmed.hasPrefix("```") {
                let langPart = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let language: String? = langPart.isEmpty ? nil : langPart
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let codeLine = lines[i]
                    if codeLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(codeLine)
                    i += 1
                }
                blocks.append(.codeBlock(language: language, lines: codeLines))
                continue
            }

            // Headers
            if trimmed.hasPrefix("### ") {
                blocks.append(.header(level: 3, text: String(trimmed.dropFirst(4))))
                i += 1
                continue
            }
            if trimmed.hasPrefix("## ") {
                blocks.append(.header(level: 2, text: String(trimmed.dropFirst(3))))
                i += 1
                continue
            }
            if trimmed.hasPrefix("# ") {
                blocks.append(.header(level: 1, text: String(trimmed.dropFirst(2))))
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix("> ") {
                blocks.append(.blockquote(text: String(trimmed.dropFirst(2))))
                i += 1
                continue
            }

            // Bullet list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                blocks.append(.bullet(text: String(trimmed.dropFirst(2))))
                i += 1
                continue
            }

            // Numbered list
            if let match = trimmed.range(of: #"^(\d+)\.\s+"#, options: .regularExpression) {
                let prefix = trimmed[match]
                let numberPart = prefix.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: ".", with: "")
                    .trimmingCharacters(in: .whitespaces)
                let rest = String(trimmed[match.upperBound...])
                blocks.append(.numbered(number: numberPart, text: rest))
                i += 1
                continue
            }

            // Regular paragraph
            blocks.append(.paragraph(text: trimmed))
            i += 1
        }

        return blocks
    }

    // MARK: - Block Rendering

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .header(let level, let text):
            renderInlineMarkdown(text)
                .font(.system(
                    size: level == 1 ? 16 : (level == 2 ? 14 : 13),
                    weight: .bold
                ))
                .foregroundStyle(defaultTextColor)

        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(CortexDesign.accentPrimary)
                    .frame(width: 6, height: 6)
                renderInlineMarkdown(text)
                    .font(.system(size: 13))
                    .foregroundStyle(defaultTextColor)
            }
            .padding(.leading, 8)

        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CortexDesign.accentPrimary)
                    .frame(minWidth: 16, alignment: .trailing)
                renderInlineMarkdown(text)
                    .font(.system(size: 13))
                    .foregroundStyle(defaultTextColor)
            }
            .padding(.leading, 8)

        case .codeBlock(let language, let lines):
            CodeBlockView(language: language, lines: lines)

        case .blockquote(let text):
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(CortexDesign.accentPrimary)
                    .frame(width: 3)
                renderInlineMarkdown(text)
                    .font(.system(size: 13))
                    .italic()
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.leading, 10)
                    .padding(.vertical, 8)
            }
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(CortexDesign.accentPrimary.opacity(0.05))
            )

        case .paragraph(let text):
            renderInlineMarkdown(text)
                .font(.system(size: 13))
                .foregroundStyle(defaultTextColor)
                .lineSpacing(4)
        }
    }

    // MARK: - Inline Markdown Rendering

    /// Parses inline markdown (bold, italic, inline code) and returns concatenated Text.
    private func renderInlineMarkdown(_ input: String) -> Text {
        let segments = parseInlineSegments(input)
        var result = Text("")
        for segment in segments {
            switch segment {
            case .plain(let str):
                result = result + Text(str)
            case .bold(let str):
                result = result + Text(str).bold()
            case .italic(let str):
                result = result + Text(str).italic()
            case .boldItalic(let str):
                result = result + Text(str).bold().italic()
            case .code(let str):
                result = result + Text(str)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(CortexDesign.accentPrimary.opacity(0.9))
            }
        }
        return result
    }

    private enum InlineSegment {
        case plain(String)
        case bold(String)
        case italic(String)
        case boldItalic(String)
        case code(String)
    }

    private func parseInlineSegments(_ input: String) -> [InlineSegment] {
        var segments: [InlineSegment] = []
        var remaining = input[input.startIndex...]

        while !remaining.isEmpty {
            // Inline code: `...`
            if remaining.hasPrefix("`") {
                let afterTick = remaining.index(after: remaining.startIndex)
                if let endTick = remaining[afterTick...].firstIndex(of: "`") {
                    let codeContent = String(remaining[afterTick..<endTick])
                    segments.append(.code(codeContent))
                    remaining = remaining[remaining.index(after: endTick)...]
                    continue
                }
            }

            // Bold+Italic: ***...***
            if remaining.hasPrefix("***") {
                let afterMarker = remaining.index(remaining.startIndex, offsetBy: 3)
                if let endRange = remaining[afterMarker...].range(of: "***") {
                    let content = String(remaining[afterMarker..<endRange.lowerBound])
                    segments.append(.boldItalic(content))
                    remaining = remaining[endRange.upperBound...]
                    continue
                }
            }

            // Bold: **...**
            if remaining.hasPrefix("**") {
                let afterMarker = remaining.index(remaining.startIndex, offsetBy: 2)
                if let endRange = remaining[afterMarker...].range(of: "**") {
                    let content = String(remaining[afterMarker..<endRange.lowerBound])
                    segments.append(.bold(content))
                    remaining = remaining[endRange.upperBound...]
                    continue
                }
            }

            // Italic: *...*
            if remaining.hasPrefix("*") {
                let afterMarker = remaining.index(after: remaining.startIndex)
                if let endIdx = remaining[afterMarker...].firstIndex(of: "*") {
                    let content = String(remaining[afterMarker..<endIdx])
                    // Avoid matching empty or obviously wrong spans
                    if !content.isEmpty && !content.hasPrefix(" ") {
                        segments.append(.italic(content))
                        remaining = remaining[remaining.index(after: endIdx)...]
                        continue
                    }
                }
            }

            // Plain text: consume characters until the next special marker
            var endPlain = remaining.startIndex
            var foundSpecial = false
            var cursor = remaining.startIndex
            while cursor < remaining.endIndex {
                let ch = remaining[cursor]
                if cursor > remaining.startIndex && (ch == "`" || ch == "*") {
                    endPlain = cursor
                    foundSpecial = true
                    break
                }
                cursor = remaining.index(after: cursor)
            }

            if !foundSpecial {
                segments.append(.plain(String(remaining)))
                break
            } else {
                segments.append(.plain(String(remaining[remaining.startIndex..<endPlain])))
                remaining = remaining[endPlain...]
            }
        }

        return segments
    }
}

// MARK: - Code Block View

private struct CodeBlockView: View {
    let language: String?
    let lines: [String]

    @State private var copied: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row with language label and copy button
            if language != nil || true {
                HStack {
                    if let lang = language {
                        Text(lang)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(CortexDesign.neutral)
                    }
                    Spacer()
                    Button(action: copyCode) {
                        HStack(spacing: 3) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 9))
                            Text(copied ? "Copied" : "Copy")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(copied ? CortexDesign.profit : CortexDesign.neutral)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }

            // Code content
            Text(lines.joined(separator: "\n"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .padding(.top, language == nil ? 4 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(CortexDesign.bgDeepest)
        )
    }

    private func copyCode() {
        let code = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }
}
