// NEWS — the wire desk, tabbed. FEED is the sourced tape with a live filter
// bar (source, symbol, keyword, tone, time window) over saved presets;
// EARNINGS is the filing-cadence calendar with imminence flags; AI BRIEF
// routes structured prompts through the copilot and keeps an answer history.
// Every row traces to a disclosed source; estimates are always labeled as
// estimates. The pure, testable models live in NewsSupport.swift.

import SwiftUI

// MARK: - View

struct NewsView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: NewsTab = .default
    // Feed filter posture + its saved presets.
    @State private var filter = NewsFilter()
    @State private var presets = NewsPresetStore()
    @State private var presetName = ""

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 0) {
                header(now: context.date)
                Divider().overlay(Theme.line)
                tabBar
                Divider().overlay(Theme.line)
                Group {
                    switch tab {
                    case .feed: feedTab(now: context.date)
                    case .earnings: earningsTab(now: context.date)
                    case .brief: briefTab(now: context.date)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
    }

    // MARK: Header

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

    // MARK: Tab bar (Deck-style segmented control)

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(NewsTab.allCases) { t in
                DeckSegment(title: t.title, isOn: tab == t) { tab = t }
            }
        }
        .padding(3)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .strokeBorder(Theme.line, lineWidth: Theme.hairline)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - FEED tab

    private func feedTab(now: Date) -> some View {
        VStack(spacing: 0) {
            feedFilterBar
            Divider().overlay(Theme.line)
            if let board = model.newsBoard {
                feedList(board, now: now)
            } else {
                listeningState
            }
        }
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

    private func feedList(_ board: NewsBoard, now: Date) -> some View {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let items = filter.apply(board.items, nowMs: nowMs)
        return Group {
            if board.items.isEmpty {
                feedEmpty("no headlines in the buffer")
            } else if items.isEmpty {
                feedEmpty("no headlines match the filter")
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { item in
                            NewsItemRow(item: item, now: now)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func feedEmpty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.dim)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Feed filter bar

    private var sourcesPresent: [(domain: String, label: String)] {
        NewsSourceBadge.present(model.newsBoard?.items ?? [])
    }

    private var feedFilterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                toneSegment
                windowSegment
                sourcesMenu
                Spacer(minLength: 8)
                if let count = filteredCount {
                    Text(count)
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
                presetsMenu
            }
            HStack(spacing: 8) {
                queryField(
                    placeholder: "symbol", text: $filter.symbol,
                    help: "filter by symbol tag", width: 120
                )
                queryField(
                    placeholder: "keyword", text: $filter.keyword,
                    help: "filter titles by keyword", width: 160
                )
                if filter.isActive {
                    Button {
                        filter = NewsFilter()
                    } label: {
                        Text("CLEAR")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(Theme.dim)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("clear every filter")
                }
                Spacer(minLength: 8)
                savePresetField
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// "N of M" once a board is present — the visible-vs-total count.
    private var filteredCount: String? {
        guard let board = model.newsBoard, !board.items.isEmpty else { return nil }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let shown = filter.apply(board.items, nowMs: nowMs).count
        return "\(shown) of \(board.items.count)"
    }

    private var toneSegment: some View {
        NewsSegment(
            options: NewsFilter.Tone.allCases.map { ($0, $0.title) },
            selection: filter.tone
        ) { filter.tone = $0 }
        .help("tone gate: positive, negative, or all")
    }

    private var windowSegment: some View {
        NewsSegment(
            options: NewsFilter.Window.allCases.map { ($0, $0.title) },
            selection: filter.window
        ) { filter.window = $0 }
        .help("only headlines inside the trailing window")
    }

    private var sourcesMenu: some View {
        let present = sourcesPresent
        return Menu {
            Button("all sources") { filter.sources.removeAll() }
            if !present.isEmpty {
                Divider()
                ForEach(present, id: \.domain) { src in
                    Toggle(isOn: Binding(
                        get: { filter.sources.contains(src.domain) },
                        set: { on in
                            if on { filter.sources.insert(src.domain) }
                            else { filter.sources.remove(src.domain) }
                        }
                    )) {
                        Text("\(src.label) · \(src.domain)")
                    }
                }
            }
        } label: {
            filterChipLabel(
                icon: "antenna.radiowaves.left.and.right", text: "sources",
                count: filter.sources.isEmpty ? nil : filter.sources.count
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(present.isEmpty)
        .help("filter by source — multi-select from the sources present")
    }

    private var presetsMenu: some View {
        Menu {
            if presets.presets.isEmpty {
                Button("no saved presets") {}.disabled(true)
            }
            ForEach(presets.presets) { preset in
                Menu(preset.name) {
                    Button("load") { filter = preset.filter }
                    Button("delete", role: .destructive) { presets.delete(id: preset.id) }
                }
            }
        } label: {
            filterChipLabel(
                icon: "square.stack", text: "presets",
                count: presets.presets.isEmpty ? nil : presets.presets.count
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("saved filter presets: load or delete")
    }

    private var savePresetField: some View {
        HStack(spacing: 6) {
            TextField("preset name", text: $presetName)
                .textFieldStyle(.plain)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.bone)
                .frame(width: 120)
                .onSubmit(savePreset)
            Button(action: savePreset) {
                Text("SAVE")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(saveDisabled ? Theme.dim : Theme.ember)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(saveDisabled)
            .help("save the current filter as a preset")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(Theme.line, lineWidth: Theme.hairline)
        )
    }

    private var saveDisabled: Bool {
        presetName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func savePreset() {
        guard presets.save(name: presetName, filter: filter) != nil else { return }
        presetName = ""
    }

    private func queryField(
        placeholder: String, text: Binding<String>, help: String, width: CGFloat
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.bone)
            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.dim)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: width)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(Theme.line, lineWidth: Theme.hairline)
        )
        .help(help)
    }

    private func filterChipLabel(icon: String, text: String, count: Int?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
            if let count {
                Text("\(count)")
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ember)
            }
        }
        .foregroundStyle(count == nil ? Theme.dim : Theme.bone)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(Theme.line, lineWidth: Theme.hairline)
        )
    }

    // MARK: - EARNINGS tab

    private func earningsTab(now: Date) -> some View {
        Group {
            if let board = model.newsBoard, !board.earnings.isEmpty {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(NewsSupport.orderedEarnings(board.earnings)) { row in
                            EarningsRowView(row: row, now: now)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else if model.newsBoard != nil {
                Text("no calendar rows yet")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                listeningState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - AI BRIEF tab

    private var briefDisabled: Bool {
        model.pendingAsk != nil || model.connection != .connected
    }

    private func briefTab(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            briefStrip
            Divider().overlay(Theme.line)
            if model.newsBriefHistory.isEmpty {
                VStack(spacing: 8) {
                    Text("no briefs yet")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                    Text("ask cortex for a market or symbol brief — answers land here and in the copilot thread")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.newsBriefHistory) { ref in
                            BriefHistoryCard(
                                entry: ref,
                                message: model.copilot.first {
                                    $0.id == ref.requestId && $0.role == .cortex
                                },
                                now: now
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var briefStrip: some View {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func briefChip(_ title: String, prompt: String) -> some View {
        Button {
            model.askNewsBrief(prompt)
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
}

// MARK: - Compact filter segment (content-sized; the Deck-style trough)

/// A small content-sized segmented control for the feed filter dimensions —
/// the Deck segment grammar (raised selection, brighter text) without the
/// full-width stretch, so tone/window sit inline in the filter bar.
private struct NewsSegment<T: Hashable>: View {
    let options: [(value: T, label: String)]
    let selection: T
    let select: (T) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button {
                    select(option.value)
                } label: {
                    Text(option.label)
                        .font(.system(size: 10, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.bone : Theme.dim)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(on ? Theme.panelHi : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(DeckMotion.ease(), value: on)
            }
        }
        .padding(2)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(Theme.line, lineWidth: Theme.hairline)
        )
    }
}

// MARK: - Brief history card

/// One past NEWS brief: the question posed over the copilot's answer (or the
/// pending dots while it resolves). The BriefPanel grammar — ember left bar =
/// AI presence, MarkdownText body.
private struct BriefHistoryCard: View {
    let entry: NewsBriefRef
    /// The cortex message answering this request; nil until it arrives.
    let message: CopilotMessage?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SectionLabel(text: "brief")
                if let modelName = message?.model {
                    Text(modelName)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
                Spacer()
                if let message {
                    Text(IntelTime.relative(Int64(message.ts.timeIntervalSince1970 * 1000), now: now))
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(Theme.dim)
                }
            }
            Text(entry.question)
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(entry.question)
            if let message, !message.pending {
                MarkdownText(message.text)
            } else {
                NewsPendingDots()
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

// MARK: - Headline row

/// MERIDIAN signal-feed grammar: tone-colored number, title, source badge +
/// domain, and a symbol tag when a company query surfaced the item. Click
/// opens the URL through the shared http(s) guard (openGeoURL) — feed URLs
/// are untrusted.
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
                HStack(spacing: 6) {
                    NewsSourceChip(label: NewsSourceBadge.label(item))
                    Text(item.source_domain)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
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

/// symbol · last report · next estimate, with the dim basis disclosure and a
/// countdown. Estimates inside the 14-day window carry the ember calendar
/// glyph and an ember countdown; the basis always discloses the estimate.
private struct EarningsRowView: View {
    let row: EarningsRow
    let now: Date

    private var imminent: Bool {
        NewsSupport.isImminent(row.next_estimate, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(row.symbol)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.bone)
                    .lineLimit(1)
                if imminent {
                    Image(systemName: "calendar")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.ember)
                        .help("estimated report inside \(NewsSupport.imminentDays) days")
                }
                Spacer(minLength: 8)
                if let countdown = NewsSupport.countdown(row.next_estimate, now: now) {
                    Text(countdown)
                        .font(.system(size: 10, weight: imminent ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(imminent ? Theme.ember : Theme.dim)
                }
            }
            HStack(spacing: 8) {
                labeledDate("last", row.last_report, emphasized: false)
                Text("·")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
                labeledDate("next", row.next_estimate, emphasized: imminent)
                Spacer(minLength: 4)
            }
            Text(row.basis)
                .font(.system(size: 9))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deckRowRule()
    }

    private func labeledDate(_ label: String, _ date: String, emphasized: Bool) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Theme.dim)
            Text(date)
                .numeric(size: 11, weight: emphasized ? .semibold : .regular)
                .foregroundStyle(emphasized ? Theme.ember : Theme.bone)
        }
    }
}
