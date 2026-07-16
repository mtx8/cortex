// MarkdownText — lightweight markdown rendering for copilot answers.
// The AI replies in markdown; plain Text showed the raw sigils. This view
// splits an answer into blocks (headers / lists / code fences / paragraphs)
// via the pure MarkdownBlocks.split, then renders each with flat-matte
// tokens: bone text, dim markers, mono code on panel. Inline bold/italic/
// code parse per block through AttributedString(markdown:) and fall back
// to the raw text when parsing fails — an answer never renders empty.

import AppKit
import SwiftUI

// MARK: - Block model

enum MarkdownBlock: Equatable {
    /// level is clamped to 1...3 (the three header sizes we render).
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(items: [MarkdownListItem])
    /// Fence contents verbatim (language tag dropped, inner lines untouched).
    case code(String)
}

struct MarkdownListItem: Equatable {
    /// "•" for bullet markers (- * +), "1." style for numbered items.
    let marker: String
    /// Nesting depth from leading whitespace (2 spaces = 1 level, capped).
    let indent: Int
    let text: String
}

// MARK: - Block splitter (pure — see MarkdownTextTests)

enum MarkdownBlocks {
    static func split(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var items: [MarkdownListItem] = []
        var codeLines: [String] = []
        var inFence = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }
        func flushList() {
            guard !items.isEmpty else { return }
            blocks.append(.list(items: items))
            items = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inFence {
                if trimmed.hasPrefix("```") {
                    inFence = false
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                } else {
                    codeLines.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushParagraph()
                flushList()
                inFence = true
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                flushList()
                continue
            }
            if let heading = headingLine(trimmed) {
                flushParagraph()
                flushList()
                blocks.append(heading)
                continue
            }
            if let item = listItem(line) {
                flushParagraph()
                items.append(item)
                continue
            }
            flushList()
            paragraph.append(trimmed)
        }

        // EOF: an unclosed fence still renders as code (drop if empty).
        if inFence, !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        flushList()
        return blocks
    }

    /// `# text` .. `###### text` — requires a space after the hashes;
    /// level clamps to 3 (sizes 14/13/12 are all we draw).
    private static func headingLine(_ trimmed: String) -> MarkdownBlock? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard hashes.count <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: min(hashes.count, 3), text: text)
    }

    /// `- x` / `* x` / `+ x` / `1. x` / `1) x`, optionally indented.
    private static func listItem(_ line: String) -> MarkdownListItem? {
        let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
        let indentWidth = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let indent = min(indentWidth / 2, 4)
        let rest = line.drop(while: { $0 == " " || $0 == "\t" })

        if let first = rest.first, first == "-" || first == "*" || first == "+" {
            let after = rest.dropFirst()
            guard after.first == " " else { return nil }
            let text = after.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return MarkdownListItem(marker: "•", indent: indent, text: text)
        }

        let digits = rest.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let afterDigits = rest.dropFirst(digits.count)
        guard afterDigits.first == "." || afterDigits.first == ")" else { return nil }
        let afterPunct = afterDigits.dropFirst()
        guard afterPunct.first == " " else { return nil }
        let text = afterPunct.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return MarkdownListItem(marker: "\(digits).", indent: indent, text: text)
    }
}

// MARK: - View

struct MarkdownText: View {
    private let text: String
    private let blocks: [MarkdownBlock]

    init(_ text: String) {
        self.text = text
        blocks = MarkdownBlocks.split(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks.indices, id: \.self) { index in
                blockView(blocks[index])
            }
        }
        .textSelection(.enabled)
        // Each block is its own Text and macOS selection cannot cross Text
        // views, so a drag can only ever grab one block. The context menu
        // restores the whole-answer copy the single-Text rendering had.
        .contextMenu {
            Button("Copy Answer") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(.system(size: headingSize(level), weight: .semibold))
                .foregroundStyle(Theme.bone)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

        case .paragraph(let text):
            bodyText(text)

        case .list(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    // Marker in its own column so wrapped lines hang past it.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.dim)
                        bodyText(item.text)
                    }
                    .padding(.leading, CGFloat(item.indent) * 12)
                }
            }

        case .code(let code):
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.bone)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel()
        }
    }

    private func bodyText(_ text: String) -> some View {
        Text(Self.inline(text))
            .font(.system(size: 12))
            .foregroundStyle(Theme.bone)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 14/13/12 for h1/h2/h3 (levels arrive pre-clamped from the splitter).
    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 14
        case 2: 13
        default: 12
        }
    }

    /// Inline bold/italic/code per block; the raw string on parse failure.
    /// Code spans get mono on a panelHi chip — panelHi (not panel) so the
    /// chip reads on both ink (copilot thread) and panel (answer cards).
    static func inline(_ text: String) -> AttributedString {
        var attributed: AttributedString
        do {
            attributed = try AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        } catch {
            attributed = AttributedString(text)
        }
        let codeRanges = attributed.runs.compactMap { run in
            run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil
        }
        for range in codeRanges {
            attributed[range].font = .system(size: 11, design: .monospaced)
            attributed[range].backgroundColor = Theme.panelHi
        }
        return attributed
    }
}
