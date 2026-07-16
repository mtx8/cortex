// SCANNER — cross-sectional relative-value screen over the scan universe.
// Bloomberg-EQS-class: preset screens, a dense sortable percentile table,
// and event-flag chips. Every score is a 0-100 rank against the rest of the
// universe on the same cycle; raw readings ride along so the operator can
// always see what drove a score. Semantic color lives only in the return
// columns (design law) — ember marks selection, sort, and setups.

import SwiftUI

// MARK: - Pure helpers (internal for tests)

/// Preset screens over the scan board. Each preset is filter + intrinsic
/// ordering; explicit column sorting (ScanSort) applies afterwards.
/// Codable (raw string) so saved screens can persist the active preset.
enum ScanPreset: String, CaseIterable, Codable {
    case all, topMomentum, breakoutWatch, oversold, volMovers, equities, crypto

    var title: String {
        switch self {
        case .all: "all"
        case .topMomentum: "top momentum"
        case .breakoutWatch: "breakout watch"
        case .oversold: "oversold"
        case .volMovers: "vol movers"
        case .equities: "equities"
        case .crypto: "crypto"
        }
    }

    func apply(_ rows: [ScanRow]) -> [ScanRow] {
        switch self {
        case .all:
            return rows.sorted { $0.composite > $1.composite }
        case .topMomentum:
            return rows.sorted { $0.momentum > $1.momentum }
        case .breakoutWatch:
            return rows
                .filter { Self.hasFlag($0, "breakout setup") || Self.hasFlag($0, "new 52w high") }
                .sorted { $0.breakout > $1.breakout }
        case .oversold:
            return rows
                .filter { Self.hasFlag($0, "oversold bounce") || ($0.rsi_14.map { $0 < 35 } ?? false) }
                .sorted { $0.meanrev > $1.meanrev }
        case .volMovers:
            return rows
                .filter { Self.hasFlag($0, "volume spike") || Self.hasFlag($0, "vol expansion") }
                .sorted { $0.vol_state > $1.vol_state }
        case .equities:
            // Bare ticker = equity, dashed pair = crypto — the same rule as
            // AppModel.isEquity (inlined; this enum stays pure for tests).
            return rows.filter { !$0.symbol.contains("-") }.sorted { $0.composite > $1.composite }
        case .crypto:
            return rows.filter { $0.symbol.contains("-") }.sorted { $0.composite > $1.composite }
        }
    }

    static func hasFlag(_ row: ScanRow, _ flag: String) -> Bool {
        row.flags.contains { $0.caseInsensitiveCompare(flag) == .orderedSame }
    }
}

/// Table columns in display order. Codable (raw string) so filters and
/// saved screens can persist column references.
enum ScanColumn: String, CaseIterable, Codable {
    case symbol, composite, momentum, trend, breakout, meanrev, volState,
         rsi, zscore, ret1w, ret1m, ret3m, dist52wHi, volSurge, regime, flags

    var title: String {
        switch self {
        case .symbol: "sym"
        case .composite: "composite"
        case .momentum: "mom"
        case .trend: "trend"
        case .breakout: "brkout"
        case .meanrev: "mrev"
        case .volState: "vol"
        case .rsi: "rsi"
        case .zscore: "z"
        case .ret1w: "1w%"
        case .ret1m: "1m%"
        case .ret3m: "3m%"
        case .dist52wHi: "Δ52w-hi"
        case .volSurge: "v/avg"
        case .regime: "regime"
        case .flags: "flags"
        }
    }

    var sortable: Bool { self != .flags }
}

/// One sort order over the scan table. nil readings sort last in BOTH
/// directions — absent data never floats to the top of a screen.
struct ScanSort: Equatable, Codable {
    var column: ScanColumn
    var ascending: Bool

    /// Numeric sort key for value columns; nil for string columns / flags.
    static func key(_ row: ScanRow, _ column: ScanColumn) -> Double? {
        switch column {
        case .composite: row.composite
        case .momentum: row.momentum
        case .trend: row.trend
        case .breakout: row.breakout
        case .meanrev: row.meanrev
        case .volState: row.vol_state
        case .rsi: row.rsi_14
        case .zscore: row.zscore_20
        case .ret1w: row.ret_1w
        case .ret1m: row.ret_1m
        case .ret3m: row.ret_3m
        case .dist52wHi: row.dist_52w_high
        case .volSurge: row.vol_surge
        case .symbol, .regime, .flags: nil
        }
    }

    func apply(_ rows: [ScanRow]) -> [ScanRow] {
        switch column {
        case .symbol:
            return rows.sorted { ascending ? $0.symbol < $1.symbol : $0.symbol > $1.symbol }
        case .regime:
            return rows.sorted { a, b in
                switch (a.regime?.label, b.regime?.label) {
                case let (x?, y?): x == y ? false : (ascending ? x < y : x > y)
                case (_?, nil): true
                default: false
                }
            }
        case .flags:
            return rows
        default:
            return rows.sorted { a, b in
                switch (Self.key(a, column), Self.key(b, column)) {
                case let (x?, y?): x == y ? false : (ascending ? x < y : x > y)
                case (_?, nil): true
                default: false
                }
            }
        }
    }

    /// Repeat click flips direction; first click on a column starts with the
    /// useful direction (numbers big-first, names A-first).
    static func toggling(_ current: ScanSort?, column: ScanColumn) -> ScanSort {
        if let current, current.column == column {
            return ScanSort(column: column, ascending: !current.ascending)
        }
        return ScanSort(column: column, ascending: column == .symbol || column == .regime)
    }
}

/// Scanner-local number formatting. Scores are percentiles (0-100), returns
/// are simple-return fractions, vol surge is a ratio vs the 20d average.
enum ScanFormat {
    /// Percentile score, integer.
    static func score(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        return String(format: "%.0f", v)
    }

    /// 40-60 is the cross-sectional noise band — nothing to see there.
    static func isNoise(_ score: Double) -> Bool {
        score >= 40 && score <= 60
    }

    /// Simple-return fraction as signed percent: 0.052 → "+5.2%".
    static func pct(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%+.1f%%", v * 100)
    }

    /// Raw reading with fixed decimals (RSI 0dp, z-score signed 2dp).
    static func raw(_ v: Double?, decimals: Int, signed: Bool = false) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: signed ? "%+.\(decimals)f" : "%.\(decimals)f", v)
    }

    /// Fraction below the 252d high rendered as a distance: 0.032 → "-3.2%",
    /// at the high → "0.0%".
    static func distFromHigh(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        let d = abs(v) * 100
        return d < 0.05 ? "0.0%" : String(format: "-%.1f%%", d)
    }

    /// Volume ratio: 1.82 → "1.8x".
    static func ratio(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%.1fx", v)
    }

    /// First `max` flags shown as chips, the rest collapse to "+n".
    static func flagsDisplay(_ flags: [String], max: Int = 2) -> (shown: [String], overflow: Int) {
        guard flags.count > max else { return (flags, 0) }
        return (Array(flags.prefix(max)), flags.count - max)
    }
}

// MARK: - Column layout (fixed widths so header and rows stay aligned)

private enum ScanCol {
    static let sym: CGFloat = 64
    static let composite: CGFloat = 104
    static let score: CGFloat = 46
    static let rsi: CGFloat = 40
    static let z: CGFloat = 52
    static let ret: CGFloat = 54
    static let dist: CGFloat = 60
    static let ratio: CGFloat = 48
    static let regime: CGFloat = 92
    static let flags: CGFloat = 200
    static let news: CGFloat = 16
    static let ai: CGFloat = 18
    static let company: CGFloat = 18
    static let gap: CGFloat = 8
    /// Trailing affordance cluster: news glyph + AI explain + company.
    static let trailing: CGFloat = news + ai + company + gap * 2

    static func width(_ column: ScanColumn) -> CGFloat {
        switch column {
        case .symbol: sym
        case .composite: composite
        case .momentum, .trend, .breakout, .meanrev, .volState: score
        case .rsi: rsi
        case .zscore: z
        case .ret1w, .ret1m, .ret3m: ret
        case .dist52wHi: dist
        case .volSurge: ratio
        case .regime: regime
        case .flags: flags
        }
    }

    static func alignment(_ column: ScanColumn) -> Alignment {
        switch column {
        case .symbol, .composite, .regime, .flags: .leading
        default: .trailing
        }
    }

    /// Total content width: columns + gaps + the trailing affordances.
    static var minWidth: CGFloat {
        let cols = ScanColumn.allCases.map(width).reduce(0, +)
        return cols + gap * CGFloat(ScanColumn.allCases.count) + trailing + 24
    }
}

// MARK: - View

struct ScannerView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var preset: ScanPreset = .all
    @State private var sort: ScanSort?
    // Filter builder + saved screens.
    @State private var filters: [ScanFilter] = []
    @State private var filtersOpen = false
    @State private var screens = ScreenStore()
    @State private var screenName = ""
    // Alert stream.
    @State private var alertsOpen = true
    @State private var lastSeenAlertID: String?
    // Copilot request id whose answer renders inline; nil = dismissed.
    @State private var aiRequestId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.line)
            presetRow
            Divider().overlay(Theme.line)
            filterBar
            Divider().overlay(Theme.line)
            if let message = aiMessage {
                ScanAnswerCard(message: message) { aiRequestId = nil }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Divider().overlay(Theme.line)
            }
            HStack(alignment: .top, spacing: 0) {
                Group {
                    if let board = model.scanBoard, !board.rows.isEmpty {
                        table(board)
                    } else {
                        emptyState
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if alertsOpen {
                    Divider().overlay(Theme.line)
                    alertStrip
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            SectionLabel(text: "scanner")
            if let board = model.scanBoard {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("\(board.source) · \(IntelTime.relative(board.ts_ms, now: context.date))")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
                if let weights = ScanWeights.summary(board.weights_used) {
                    Text("weights")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.dim)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.chipRadius)
                                .strokeBorder(Theme.line, lineWidth: Theme.hairline)
                        )
                        .help(weights)
                }
            }
            Spacer()
            if let board = model.scanBoard, !board.rows.isEmpty {
                aiPicksChip(board)
            }
            searchField
            alertsToggle
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: AI (copilot) affordances

    private var aiDisabled: Bool {
        model.pendingAsk != nil || model.connection != .connected
    }

    /// The cortex message answering OUR request — the same thread the
    /// copilot panel shows, observed here by request id.
    private var aiMessage: CopilotMessage? {
        guard let aiRequestId else { return nil }
        return model.copilot.first { $0.id == aiRequestId && $0.role == .cortex }
    }

    private func aiPicksChip(_ board: ScanBoard) -> some View {
        Button {
            aiRequestId = model.askCopilot(ScanAI.picksPrompt(rows: displayRows(board)))
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 8, weight: .semibold))
                Text("AI PICKS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .lineLimit(1)
            }
            .foregroundStyle(aiDisabled ? Theme.dim : Theme.ember)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.chipRadius)
                    .strokeBorder(
                        aiDisabled ? Theme.line : Theme.ember.opacity(0.5),
                        lineWidth: Theme.hairline
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(aiDisabled)
        .help("ask cortex for 2-3 picks from the top rows — the answer also lands in the copilot thread")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
            TextField("filter symbol", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.bone)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.dim)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("clear filter")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: 180)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(Theme.line, lineWidth: Theme.hairline)
        )
    }

    // MARK: Alert stream

    private var hasUnseenAlerts: Bool {
        guard let first = model.scanAlerts.first else { return false }
        return first.id != lastSeenAlertID
    }

    /// Strip toggle; while collapsed it carries the unseen-alert ember dot.
    private var alertsToggle: some View {
        Button {
            alertsOpen.toggle()
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 11))
                .foregroundStyle(alertsOpen ? Theme.ember : Theme.dim)
                .overlay(alignment: .topTrailing) {
                    if !alertsOpen && hasUnseenAlerts {
                        Circle()
                            .fill(Theme.ember)
                            .frame(width: 4, height: 4)
                            .offset(x: 3, y: -3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(alertsOpen ? "hide alert stream" : "show alert stream")
        .animation(DeckMotion.ease(), value: alertsOpen)
    }

    private var alertStrip: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    SectionLabel(text: "alerts")
                    if hasUnseenAlerts { ScanPulseDot() }
                    Spacer()
                    if !model.scanAlerts.isEmpty {
                        Text("\(model.scanAlerts.count)")
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(Theme.dim)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider().overlay(Theme.line)
                if model.scanAlerts.isEmpty {
                    VStack(spacing: 6) {
                        Text("no alerts yet")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.dim)
                        Text("flag transitions land here when a scan cycle raises a new flag on a symbol")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.dim)
                            .multilineTextAlignment(.center)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(model.scanAlerts) { alert in
                                ScanAlertRow(alert: alert, now: context.date) {
                                    model.selectSymbol(alert.symbol)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 240)
        .task(id: model.scanAlerts.first?.id) {
            // The pulse rides a few seconds while the strip is visible,
            // then the newest alert counts as seen.
            try? await Task.sleep(for: .seconds(4))
            lastSeenAlertID = model.scanAlerts.first?.id
        }
    }

    // MARK: Filter builder & saved screens

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    filtersOpen.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .bold))
                            .rotationEffect(.degrees(filtersOpen ? 90 : 0))
                        Text("FILTERS")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.8)
                        if !filters.isEmpty {
                            Text("\(filters.count)")
                                .font(.system(size: 9, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.ember)
                        }
                    }
                    .foregroundStyle(filters.isEmpty ? Theme.dim : Theme.bone)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("numeric filters, AND-combined with the active preset")
                .animation(DeckMotion.ease(), value: filtersOpen)
                if !filtersOpen && !filters.isEmpty {
                    Text(filters.map { "\($0.column.title) \($0.op.title) \(ScanFormat.raw($0.value, decimals: 1))" }
                        .joined(separator: " · "))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
                Spacer()
                screensMenu
            }
            if filtersOpen {
                ForEach($filters) { $filter in
                    ScanFilterRowView(filter: $filter) {
                        filters.removeAll { $0.id == filter.id }
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        filters.append(ScanFilter())
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 8, weight: .semibold))
                            Text("ADD FILTER")
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(0.8)
                        }
                        .foregroundStyle(Theme.dim)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("add a filter row")
                    Spacer()
                    saveScreenField
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Load/delete menu over the saved screens.
    private var screensMenu: some View {
        Menu {
            if screens.screens.isEmpty {
                Button("no saved screens") {}.disabled(true)
            }
            ForEach(screens.screens) { screen in
                Menu(screen.name) {
                    Button("load") { load(screen) }
                    Button("delete", role: .destructive) { screens.delete(id: screen.id) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.stack")
                    .font(.system(size: 8, weight: .semibold))
                Text("SCREENS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                if !screens.screens.isEmpty {
                    Text("\(screens.screens.count)")
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(Theme.dim)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("saved screens: load or delete")
    }

    private var saveScreenField: some View {
        HStack(spacing: 6) {
            TextField("screen name", text: $screenName)
                .textFieldStyle(.plain)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.bone)
                .frame(width: 120)
                .onSubmit(saveScreen)
            Button {
                saveScreen()
            } label: {
                Text("SAVE")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(saveDisabled ? Theme.dim : Theme.ember)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(saveDisabled)
            .help("save the current preset + filters + sort as a screen")
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
        screenName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func saveScreen() {
        guard screens.save(name: screenName, preset: preset, filters: filters, sort: sort) != nil
        else { return }
        screenName = ""
    }

    private func load(_ screen: SavedScreen) {
        preset = screen.preset
        filters = screen.filters
        sort = screen.sort
        if !screen.filters.isEmpty { filtersOpen = true }
    }

    // MARK: Presets

    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(ScanPreset.allCases, id: \.self) { p in
                presetChip(p)
            }
            Spacer()
            if let board = model.scanBoard, !board.rows.isEmpty {
                Text("\(displayRows(board).count) rows")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func presetChip(_ p: ScanPreset) -> some View {
        let active = preset == p
        return Button {
            preset = p
            sort = nil // fall back to the preset's own ordering
        } label: {
            Text(p.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(active ? Theme.ember : Theme.dim)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(active ? Theme.emberTint : Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.chipRadius)
                        .strokeBorder(active ? Theme.ember.opacity(0.5) : Theme.line,
                                      lineWidth: Theme.hairline)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(DeckMotion.ease(), value: active)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("first scan pending…")
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
            Text("scans run every 5 minutes over the universe — the board fills once D1 history lands")
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Table

    private func displayRows(_ board: ScanBoard) -> [ScanRow] {
        var rows = preset.apply(board.rows)
        rows = ScanFilter.apply(filters, to: rows)
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            rows = rows.filter { $0.symbol.localizedCaseInsensitiveContains(query) }
        }
        if let sort {
            rows = sort.apply(rows)
        }
        return rows
    }

    private func table(_ board: ScanBoard) -> some View {
        let rows = displayRows(board)
        let headlines = ScanNews.latestHeadlines(
            model.newsBoard?.items ?? [],
            nowMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        return ScrollView([.horizontal, .vertical]) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    if rows.isEmpty {
                        Text("no rows match")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.dim)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            ScanRowView(
                                row: row,
                                headline: headlines[row.symbol],
                                aiDisabled: aiDisabled,
                                openChart: {
                                    model.selectSymbol(row.symbol)
                                    model.centerMode = .chart
                                },
                                openCompany: {
                                    model.openCompany(row.symbol)
                                },
                                openNews: {
                                    model.centerMode = .news
                                },
                                explain: {
                                    aiRequestId = model.askCopilot(
                                        ScanAI.explainPrompt(row: row, rank: index + 1, of: rows.count)
                                    )
                                }
                            )
                        }
                    }
                } header: {
                    headerRow
                }
            }
            .frame(minWidth: ScanCol.minWidth, alignment: .leading)
        }
    }

    private var headerRow: some View {
        HStack(spacing: ScanCol.gap) {
            ForEach(ScanColumn.allCases, id: \.self) { col in
                headerCell(col)
            }
            Spacer(minLength: ScanCol.trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.ink)
        .deckRowRule(1)
    }

    private func headerCell(_ col: ScanColumn) -> some View {
        let active = sort?.column == col
        return Button {
            sort = ScanSort.toggling(sort, column: col)
        } label: {
            HStack(spacing: 3) {
                if ScanCol.alignment(col) == .trailing { Spacer(minLength: 0) }
                Text(col.title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(active ? Theme.ember : Theme.dim)
                    .lineLimit(1)
                if active, let sort {
                    Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.ember)
                }
                if ScanCol.alignment(col) == .leading { Spacer(minLength: 0) }
            }
            .frame(width: ScanCol.width(col))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!col.sortable)
        .animation(DeckMotion.ease(), value: active)
    }
}

// MARK: - Row

private struct ScanRowView: View {
    let row: ScanRow
    /// Latest in-window headline title for this symbol; nil = no news glyph.
    let headline: String?
    let aiDisabled: Bool
    let openChart: () -> Void
    let openCompany: () -> Void
    let openNews: () -> Void
    let explain: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: openChart) {
            HStack(spacing: ScanCol.gap) {
                symbolCell
                compositeCell
                scoreCell(row.momentum)
                scoreCell(row.trend)
                scoreCell(row.breakout)
                scoreCell(row.meanrev)
                scoreCell(row.vol_state)
                rawCell(ScanFormat.raw(row.rsi_14, decimals: 0), present: row.rsi_14 != nil, width: ScanCol.rsi)
                rawCell(ScanFormat.raw(row.zscore_20, decimals: 2, signed: true), present: row.zscore_20 != nil, width: ScanCol.z)
                returnCell(row.ret_1w)
                returnCell(row.ret_1m)
                returnCell(row.ret_3m)
                rawCell(ScanFormat.distFromHigh(row.dist_52w_high), present: row.dist_52w_high != nil, width: ScanCol.dist)
                rawCell(ScanFormat.ratio(row.vol_surge), present: row.vol_surge != nil, width: ScanCol.ratio)
                regimeCell
                flagsCell
                newsCell
                aiCell
                companyCell
            }
            .padding(.horizontal, 12)
            .frame(height: 25)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(hovering ? Theme.panelHi : .clear)
            .deckRowRule()
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DeckMotion.ease(), value: hovering)
    }

    private var symbolCell: some View {
        Text(row.symbol)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.bone)
            .lineLimit(1)
            .frame(width: ScanCol.sym, alignment: .leading)
    }

    private var compositeCell: some View {
        HStack(spacing: 6) {
            DeckGaugeBar(fraction: row.composite / 100, color: Theme.ember)
                .frame(width: 40)
            Text(ScanFormat.score(row.composite))
                .numeric(size: 11, weight: .semibold)
                .foregroundStyle(Theme.bone)
        }
        .frame(width: ScanCol.composite, alignment: .leading)
    }

    /// Percentile cell: mono bone, dimmed inside the 40-60 noise band.
    private func scoreCell(_ v: Double) -> some View {
        Text(ScanFormat.score(v))
            .numeric(size: 10)
            .foregroundStyle(ScanFormat.isNoise(v) ? Theme.dim : Theme.bone)
            .frame(width: ScanCol.score, alignment: .trailing)
    }

    private func rawCell(_ text: String, present: Bool, width: CGFloat) -> some View {
        Text(text)
            .numeric(size: 10)
            .foregroundStyle(present ? Theme.bone : Theme.dim)
            .frame(width: width, alignment: .trailing)
    }

    /// Return cell: up/down are money-direction colors (design law).
    private func returnCell(_ v: Double?) -> some View {
        Text(ScanFormat.pct(v))
            .numeric(size: 10)
            .foregroundStyle(v.map(Theme.pnlColor) ?? Theme.dim)
            .frame(width: ScanCol.ret, alignment: .trailing)
    }

    private var regimeCell: some View {
        Text(row.regime?.label ?? "—")
            .font(.system(size: 10))
            .foregroundStyle(Theme.dim)
            .lineLimit(1)
            .frame(width: ScanCol.regime, alignment: .leading)
    }

    private var flagsCell: some View {
        let display = ScanFormat.flagsDisplay(row.flags)
        return HStack(spacing: 4) {
            ForEach(display.shown, id: \.self) { flag in
                ScanFlagChip(text: flag)
            }
            if display.overflow > 0 {
                Text("+\(display.overflow)")
                    .font(.system(size: 8, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.dim)
            }
        }
        .frame(width: ScanCol.flags, alignment: .leading)
        .help(row.flags.isEmpty ? "no flags" : row.flags.joined(separator: " · "))
    }

    /// News-aware marker: shown whenever the symbol has a headline in the
    /// trailing 24h. Tooltip = the latest title; click jumps to NEWS.
    /// Always visible (it signals data, not an action). Fixed width.
    private var newsCell: some View {
        Group {
            if let headline {
                Button(action: openNews) {
                    Image(systemName: "newspaper")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.dim)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(headline)
            } else {
                Color.clear
            }
        }
        .frame(width: ScanCol.news, height: 12)
    }

    /// Hover affordance: ask cortex to explain this row's rank inline.
    private var aiCell: some View {
        Button(action: explain) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 9))
                .foregroundStyle(aiDisabled ? Theme.dim : Theme.ember)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(aiDisabled)
        .help("ask cortex why this ranks here")
        .opacity(hovering ? 1 : 0)
        .frame(width: ScanCol.ai, height: 12)
    }

    /// Hover affordance into COMPANY intelligence — equities only, matching
    /// the REGIMES row affordance. Fixed width so columns never shift.
    private var companyCell: some View {
        Group {
            if AppModel.isEquity(row.symbol) {
                Button(action: openCompany) {
                    Image(systemName: "building.2")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.ember)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("open company intelligence")
                .opacity(hovering ? 1 : 0)
            } else {
                Color.clear
            }
        }
        .frame(width: ScanCol.company, height: 12)
    }
}

// MARK: - Filter row

/// One filter-builder row: field menu, op menu, numeric value field, remove.
private struct ScanFilterRowView: View {
    @Binding var filter: ScanFilter
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(ScanFilter.fields, id: \.self) { column in
                    Button(column.title) { filter.column = column }
                }
            } label: {
                chipLabel(filter.column.title, width: 72)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("field")
            Menu {
                ForEach(ScanFilter.Op.allCases, id: \.self) { op in
                    Button(op.title) { filter.op = op }
                }
            } label: {
                chipLabel(filter.op.title, width: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("operator")
            TextField("value", value: $filter.value, format: .number)
                .textFieldStyle(.plain)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.bone)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.chipRadius)
                        .strokeBorder(Theme.line, lineWidth: Theme.hairline)
                )
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.dim)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("remove filter")
            Spacer()
        }
    }

    private func chipLabel(_ text: String, width: CGFloat) -> some View {
        HStack(spacing: 3) {
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.bone)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 6, weight: .bold))
                .foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minWidth: width, alignment: .leading)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(Theme.line, lineWidth: Theme.hairline)
        )
    }
}
