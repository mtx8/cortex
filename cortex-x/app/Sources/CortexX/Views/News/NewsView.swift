// NEWS — the wire desk: deduped market/company headlines on the left, the
// filing-cadence earnings calendar on the right rail, and AI BRIEF buttons
// that route structured prompts through the copilot. Every row traces to a
// disclosed source; estimates are always labeled as estimates.

import SwiftUI

// MARK: - Pure helpers (internal for tests)

enum NewsSupport {
    /// The imminence window: earnings estimated inside the next N days get
    /// the ember calendar flag.
    static let imminentDays = 14

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }()

    /// Strict "YYYY-MM-DD" at UTC midnight; anything else is nil.
    static func parseDay(_ s: String) -> Date? {
        dayFormatter.date(from: s)
    }

    /// "YYYY-MM-DD" -> whole days from `now` (UTC calendar); nil when
    /// malformed. Negative = the date already passed.
    static func daysUntil(_ day: String, now: Date) -> Int? {
        guard let date = parseDay(day) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return cal.dateComponents([.day], from: cal.startOfDay(for: now), to: date).day
    }

    /// True when the estimate lands inside the next `imminentDays` days.
    /// Today counts; past or unparseable dates never flag.
    static func isImminent(_ day: String, now: Date) -> Bool {
        guard let d = daysUntil(day, now: now) else { return false }
        return (0...imminentDays).contains(d)
    }

    /// Calendar rows sorted soonest-estimate-first; ties break on symbol so
    /// the ordering is stable across republishes.
    static func orderedEarnings(_ rows: [EarningsRow]) -> [EarningsRow] {
        rows.sorted {
            $0.next_estimate == $1.next_estimate
                ? $0.symbol < $1.symbol
                : $0.next_estimate < $1.next_estimate
        }
    }

    /// Structured copilot prompt for the whole tape.
    static func marketBriefPrompt() -> String {
        "Summarize the latest market news in the current MERIDIAN geopolitical "
            + "context and DESKS readings; give a recommendation with explicit "
            + "confidence and what would change your mind."
    }

    /// Structured copilot prompt for one equity.
    static func symbolBriefPrompt(_ symbol: String) -> String {
        "Summarize the latest news for \(symbol) in the current MERIDIAN "
            + "geopolitical context and DESKS readings; give a recommendation "
            + "with explicit confidence and what would change your mind."
    }
}

// MARK: - View

struct NewsView: View {
    @Environment(AppModel.self) private var model
    /// Copilot request id whose answer renders inline; nil = dismissed.
    @State private var briefRequestId: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 0) {
                header(now: context.date)
                Divider().overlay(Theme.line)
                briefStrip
                Divider().overlay(Theme.line)
                if let board = model.newsBoard {
                    // The feed flexes; the earnings rail holds ~280pt like
                    // MERIDIAN's signal-feed flank.
                    HStack(alignment: .top, spacing: 0) {
                        headlinesPane(board, now: context.date)
                            .frame(minWidth: 300, maxWidth: .infinity)
                        Divider().overlay(Theme.line)
                        earningsPane(board, now: context.date)
                            .frame(minWidth: 200, idealWidth: 280, maxWidth: 280)
                    }
                } else {
                    listeningState
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
    }

    private var listeningState: some View {
        VStack(spacing: 8) {
            Text("waiting for the first wire…")
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
            Text("headlines and the earnings calendar assemble on the first news pulse")
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(now: Date) -> some View {
        HStack(spacing: 10) {
            SectionLabel(text: "news")
            Text("the tape, sourced")
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
            Spacer()
            if let board = model.newsBoard {
                Text(board.source)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                Text(IntelTime.relative(board.ts_ms, now: now))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: AI brief strip

    private var briefDisabled: Bool {
        model.pendingAsk != nil || model.connection != .connected
    }

    /// The cortex message answering OUR request — the same thread the
    /// copilot panel shows, observed here by request id.
    private var briefMessage: CopilotMessage? {
        guard let briefRequestId else { return nil }
        return model.copilot.first { $0.id == briefRequestId && $0.role == .cortex }
    }

    private var briefStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SectionLabel(text: "ai brief")
                briefChip("brief: market", prompt: NewsSupport.marketBriefPrompt())
                if AppModel.isEquity(model.selectedSymbol) {
                    briefChip(
                        "brief: \(model.selectedSymbol)",
                        prompt: NewsSupport.symbolBriefPrompt(model.selectedSymbol)
                    )
                }
                Spacer()
            }
            if let message = briefMessage {
                BriefPanel(message: message) { briefRequestId = nil }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func briefChip(_ title: String, prompt: String) -> some View {
        Button {
            briefRequestId = model.askCopilot(prompt)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkle")
                    .font(.system(size: 8, weight: .semibold))
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .lineLimit(1)
            }
            .foregroundStyle(briefDisabled ? Theme.dim : Theme.ember)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.chipRadius)
                    .strokeBorder(
                        briefDisabled ? Theme.line : Theme.ember.opacity(0.5),
                        lineWidth: Theme.hairline
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(briefDisabled)
        .help("ask cortex for a structured brief — the answer also lands in the copilot thread")
    }

    // MARK: Headline feed

    private func headlinesPane(_ board: NewsBoard, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "headlines")
                .padding(.horizontal, 12)
                .padding(.top, 12)
            if board.items.isEmpty {
                Text("no headlines in the buffer")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(board.items) { item in
                            NewsItemRow(item: item, now: now)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Earnings rail

    private func earningsPane(_ board: NewsBoard, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "earnings")
                .padding(.horizontal, 12)
                .padding(.top, 12)
            if board.earnings.isEmpty {
                Text("no calendar rows yet")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(NewsSupport.orderedEarnings(board.earnings)) { row in
                            EarningsRowView(row: row, now: now)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Inline brief panel

/// The copilot's answer to a brief, rendered inline where it was asked.
/// Ember left bar marks AI presence (the CopilotBubble grammar); dismiss
/// clears only this panel — the thread keeps the exchange.
private struct BriefPanel: View {
    let message: CopilotMessage
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SectionLabel(text: "brief")
                if let modelName = message.model {
                    Text(modelName)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.dim)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("dismiss brief")
            }
            if message.pending {
                BriefPendingDots()
            } else {
                MarkdownText(message.text)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Theme.ember)
                .frame(width: 2)
        }
    }
}

/// Copilot pending grammar: three pulsing dim dots.
private struct BriefPendingDots: View {
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Theme.dim)
                    .frame(width: 4, height: 4)
                    .opacity(pulsing ? 1 : 0.25)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.16),
                        value: pulsing
                    )
            }
        }
        .padding(.vertical, 5)
        .onAppear { pulsing = true }
    }
}

// MARK: - Headline row

/// MERIDIAN signal-feed grammar: tone-colored number, title, domain, and a
/// symbol tag when a company query surfaced the item. Click opens the URL
/// through the shared http(s) guard (openGeoURL) — feed URLs are untrusted.
private struct NewsItemRow: View {
    let item: NewsItem
    let now: Date
    @State private var hovering = false

    private var toneColor: Color {
        guard item.tone.isFinite else { return Theme.dim }
        if item.tone > 0 { return Theme.up }
        if item.tone < 0 { return Theme.down }
        return Theme.dim
    }

    private var toneText: String {
        item.tone.isFinite ? String(format: "%+.1f", item.tone) : "—"
    }

    var body: some View {
        Button {
            openGeoURL(item.url)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let symbol = item.symbol {
                        Text(symbol)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.bone)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.chipRadius)
                                    .strokeBorder(Theme.line, lineWidth: Theme.hairline)
                            )
                    }
                    Text(toneText)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(toneColor)
                    Spacer(minLength: 4)
                    Text(IntelTime.relative(item.ts_ms, now: now))
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(Theme.dim)
                }
                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.bone)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.source_domain)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(hovering ? Theme.panelHi : .clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DeckMotion.ease(), value: hovering)
    }
}

// MARK: - Earnings row

/// symbol · last report · next estimate, with the dim basis disclosure.
/// Estimates inside the 14-day window carry the ember calendar glyph.
private struct EarningsRowView: View {
    let row: EarningsRow
    let now: Date

    private var imminent: Bool {
        NewsSupport.isImminent(row.next_estimate, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(row.symbol)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.bone)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if imminent {
                    Image(systemName: "calendar")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.ember)
                        .help("estimated report inside \(NewsSupport.imminentDays) days")
                }
            }
            HStack(spacing: 6) {
                Text("last")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.dim)
                Text(row.last_report)
                    .numeric(size: 10)
                    .foregroundStyle(Theme.bone)
                Spacer(minLength: 4)
                Text("next")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.dim)
                Text(row.next_estimate)
                    .numeric(size: 10, weight: imminent ? .semibold : .regular)
                    .foregroundStyle(imminent ? Theme.ember : Theme.bone)
            }
            Text(row.basis)
                .font(.system(size: 9))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
