// SCANNER v2 support: the pure, testable models behind the filter builder
// (ScanFilter), saved screens (SavedScreen + ScreenStore in UserDefaults),
// the flag-transition alert feed merge (ScanAlertFeed), the news-glyph
// matcher (ScanNews), the copilot prompt builders (ScanAI), plus the small
// shared scanner chrome (flag chip, pulse dot, inline AI answer card).

import SwiftUI

// MARK: - Filter builder model

/// One numeric filter row: column op value, AND-combined with the active
/// preset. nil / non-finite readings never match — absent data never
/// sneaks through a screen — and a non-finite threshold matches nothing.
struct ScanFilter: Codable, Equatable, Identifiable {
    enum Op: String, Codable, CaseIterable {
        case lte, gte
        var title: String {
            switch self {
            case .lte: "<="
            case .gte: ">="
            }
        }
    }

    var id: UUID
    var column: ScanColumn
    var op: Op
    var value: Double
    /// A freshly ADDED filter starts disabled so it can't silently drop half the
    /// board before it's configured; quick-filter chips create it enabled.
    var enabled: Bool

    init(id: UUID = UUID(), column: ScanColumn = .composite, op: Op = .gte,
         value: Double = 50, enabled: Bool = true) {
        self.id = id
        self.column = column
        self.op = op
        self.value = value
        self.enabled = enabled
    }

    // Custom decode so screens saved before `enabled` existed still load (a
    // missing key defaults to enabled rather than throwing away the whole blob).
    enum CodingKeys: String, CodingKey { case id, column, op, value, enabled }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        column = try c.decode(ScanColumn.self, forKey: .column)
        op = try c.decode(Op.self, forKey: .op)
        value = try c.decode(Double.self, forKey: .value)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// The columns the builder may pick. Derived from the column's OWN
    /// capability instead of a hand-written exclusion list: the old list still
    /// offered chg% / sector / mktcap / float$ / short%flt / news, none of which
    /// `ScanSort.key` answers, so picking one made `matches` false for every row
    /// and blanked the board behind a "no rows match this screen" message.
    static let fields: [ScanColumn] = ScanColumn.allCases.filter(\.filterable)

    /// The collapsed one-line rendering, in the column's own unit — "1m% >= 5.0%"
    /// rather than the bare "1m% >= 5.0" that invited reading the threshold as a
    /// raw fraction.
    var summaryText: String {
        "\(column.title) \(op.title) \(ScanFormat.raw(value, decimals: 1))\(column.filterUnit ?? "")"
    }

    func matches(_ row: ScanRow) -> Bool {
        guard value.isFinite,
            let raw = ScanSort.key(row, column), raw.isFinite else { return false }
        // Compare in the unit the COLUMN DISPLAYS. The return / Δ52w columns
        // store simple-return fractions but render percent, so a threshold typed
        // as "5" against `ret_1m == 0.052` screened for +500% and matched nothing
        // — the operator read that as "no setups", not "broken filter".
        let reading = column.filterReading(raw)
        switch op {
        case .lte: return reading <= value
        case .gte: return reading >= value
        }
    }

    /// AND-combination: a row survives only when every ENABLED filter matches.
    /// No enabled filters = identity (a disabled/draft row never culls rows).
    ///
    /// A filter on a NON-filterable column is inert too, not fatal: screens saved
    /// (or JSON decoded) while the builder still offered the keyless fields would
    /// otherwise reload as a filter that matches no row at all, blanking the
    /// board. Stale state must not read as "nothing qualifies".
    static func apply(_ filters: [ScanFilter], to rows: [ScanRow]) -> [ScanRow] {
        let active = filters.filter { $0.enabled && $0.column.filterable }
        guard !active.isEmpty else { return rows }
        return rows.filter { row in active.allSatisfy { $0.matches(row) } }
    }
}

// MARK: - Saved screens

/// One saved screen: a name plus the whole table posture — preset, filter
/// rows, and the explicit column sort (nil = the preset's own ordering).
struct SavedScreen: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var preset: ScanPreset
    var filters: [ScanFilter]
    var sort: ScanSort?
    /// The summary-table sort (nil = the preset's own ordering). Optional, so
    /// screens saved before this field existed decode with summarySort = nil.
    var summarySort: ScanSummary.Sort?

    init(
        id: UUID = UUID(), name: String, preset: ScanPreset,
        filters: [ScanFilter], sort: ScanSort?, summarySort: ScanSummary.Sort? = nil
    ) {
        self.id = id
        self.name = name
        self.preset = preset
        self.filters = filters
        self.sort = sort
        self.summarySort = summarySort
    }
}

/// Saved-screen persistence: one JSON blob in UserDefaults (the
/// WatchlistStore pattern). Loads once at init, saves on every mutation.
@MainActor
@Observable
final class ScreenStore {
    private(set) var screens: [SavedScreen] = []

    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "scanner.screens.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.key),
            let list = try? JSONDecoder().decode([SavedScreen].self, from: data) else { return }
        screens = list
    }

    /// Saves the current posture under `name` (trimmed; blank rejected).
    /// An existing screen with the same name (case-insensitive) is replaced
    /// in place — names stay unique.
    @discardableResult
    func save(name: String, preset: ScanPreset, filters: [ScanFilter], sort: ScanSort?,
              summarySort: ScanSummary.Sort? = nil) -> SavedScreen? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if let i = screens.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            screens[i].name = name
            screens[i].preset = preset
            screens[i].filters = filters
            screens[i].sort = sort
            screens[i].summarySort = summarySort
            persist()
            return screens[i]
        }
        let screen = SavedScreen(name: name, preset: preset, filters: filters,
                                 sort: sort, summarySort: summarySort)
        screens.append(screen)
        persist()
        return screen
    }

    func delete(id: UUID) {
        let before = screens.count
        screens.removeAll { $0.id == id }
        guard screens.count != before else { return }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(screens) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

// MARK: - Alert feed merge

/// Pure merge of one board's flag-transition alerts into the accumulated
/// feed. Newest-first, duplicate ids (board republishes) never re-enter,
/// and the feed caps at `cap` — the oldest rows fall off the end.
enum ScanAlertFeed {
    static let cap = 100

    static func accumulate(
        _ feed: [ScanAlert], incoming: [ScanAlert], cap: Int = cap
    ) -> [ScanAlert] {
        guard !incoming.isEmpty else { return feed }
        var seen = Set(feed.map(\.id))
        var fresh: [ScanAlert] = []
        for alert in incoming.sorted(by: { $0.ts_ms > $1.ts_ms })
        where seen.insert(alert.id).inserted {
            fresh.append(alert)
        }
        guard !fresh.isEmpty else { return feed }
        var merged = fresh + feed
        if merged.count > cap { merged.removeLast(merged.count - cap) }
        return merged
    }
}

// MARK: - News awareness

/// Matches scan rows against the NEWS board: which symbols have a company
/// headline inside the trailing 24h window, and what the latest title is.
enum ScanNews {
    static let windowMs: Int64 = 86_400_000

    /// symbol (uppercased) -> the latest in-window headline title.
    /// Market-wide items (symbol nil) never mark a row.
    static func latestHeadlines(_ items: [NewsItem], nowMs: Int64) -> [String: String] {
        var latest: [String: (ts: Int64, title: String)] = [:]
        for item in items {
            guard let symbol = item.symbol, item.ts_ms >= nowMs - windowMs else { continue }
            let key = symbol.uppercased()
            if let held = latest[key], held.ts >= item.ts_ms { continue }
            latest[key] = (item.ts_ms, item.title)
        }
        return latest.mapValues(\.title)
    }
}

// MARK: - Copilot prompts

/// Structured copilot prompts for the scanner's AI affordances. Pure string
/// builders so the exact ask is testable; ScanFormat keeps every reading
/// NaN-safe ("—" never a garbage number).
enum ScanAI {
    /// Per-row explain: why does this symbol rank where it does.
    static func explainPrompt(row: ScanRow, rank: Int, of total: Int) -> String {
        "Explain why \(row.symbol) ranks \(rank) of \(total) on the scanner "
            + "with composite \(ScanFormat.score(row.composite)) given features "
            + "{\(featureLine(row))}; is this actionable in the current regime?"
    }

    /// Header AI PICKS: the top rows serialized, asking for 2-3 picks.
    static func picksPrompt(rows: [ScanRow], top: Int = 10) -> String {
        let lines = rows.prefix(top).enumerated().map { i, row in
            "\(i + 1). \(row.symbol) composite \(ScanFormat.score(row.composite)) {\(featureLine(row))}"
        }
        return "Top \(lines.count) rows of the CORTEX scanner "
            + "(cross-sectional 0-100 percentile scores):\n"
            + lines.joined(separator: "\n")
            + "\nPick the 2-3 most actionable setups right now; for each give "
            + "direction, a confidence (low/medium/high), and the main risks "
            + "in the current regime."
    }

    /// One row's readings as "name value" pairs; absent readings are
    /// omitted rather than serialized as placeholders.
    static func featureLine(_ row: ScanRow) -> String {
        var parts = [
            "momentum \(ScanFormat.score(row.momentum))",
            "trend \(ScanFormat.score(row.trend))",
            "breakout \(ScanFormat.score(row.breakout))",
            "meanrev \(ScanFormat.score(row.meanrev))",
            "vol \(ScanFormat.score(row.vol_state))",
        ]
        if let v = row.rsi_14, v.isFinite { parts.append("rsi \(ScanFormat.raw(v, decimals: 0))") }
        if let v = row.zscore_20, v.isFinite {
            parts.append("z \(ScanFormat.raw(v, decimals: 2, signed: true))")
        }
        if let v = row.ret_1w, v.isFinite { parts.append("1w \(ScanFormat.pct(v))") }
        if let v = row.ret_1m, v.isFinite { parts.append("1m \(ScanFormat.pct(v))") }
        if let v = row.ret_3m, v.isFinite { parts.append("3m \(ScanFormat.pct(v))") }
        if let v = row.dist_52w_high, v.isFinite {
            parts.append("from-52w-high \(ScanFormat.distFromHigh(v))")
        }
        if let v = row.vol_surge, v.isFinite { parts.append("vol-surge \(ScanFormat.ratio(v))") }
        if let regime = row.regime { parts.append("regime \(regime.label)") }
        if !row.flags.isEmpty { parts.append("flags: \(row.flags.joined(separator: ", "))") }
        return parts.joined(separator: ", ")
    }
}

/// Composite factor weights (the optional `weights_used` wire field)
/// rendered as a disclosure line, heaviest first.
enum ScanWeights {
    static func summary(_ weights: [String: Double]?) -> String? {
        guard let weights, !weights.isEmpty else { return nil }
        let parts = weights
            .filter { $0.value.isFinite }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "\($0.key) \(String(format: "%.2f", $0.value))" }
        return parts.isEmpty ? nil : "composite weights: " + parts.joined(separator: " · ")
    }
}

// MARK: - Shared scanner chrome

/// The flag chip (the table's flag grammar, reused by the alert stream).
/// Ember text carries the accent; the outline is the standard #26262E
/// hairline (design law reserves colored borders for nothing).
struct ScanFlagChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(Theme.ember)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.chipRadius)
                    .strokeBorder(Theme.line, lineWidth: Theme.hairline)
            )
    }
}

/// A row's plain-language verdict. Under design law the label stays bone (a
/// real setup) or dim (the noise-band Neutral) — the tone's up/down never
/// colors the text.
struct ScanVerdictLabel: View {
    let verdict: ScanVerdict
    var size: CGFloat = 11

    var body: some View {
        Text(verdict.label)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(verdict.tone.labelColor)
            .lineLimit(1)
    }
}

/// The composite strength read: a 4px ember gauge with the 0-100 number
/// beside it. Shared by the summary table and anywhere composite is shown.
struct ScanCompositeCell: View {
    let composite: Double
    var barWidth: CGFloat = 40

    var body: some View {
        HStack(spacing: 6) {
            DeckGaugeBar(fraction: composite / 100, color: Theme.ember)
                .frame(width: barWidth)
            Text(ScanFormat.score(composite))
                .numeric(size: 11, weight: .semibold)
                .foregroundStyle(Theme.bone)
        }
    }
}

/// The single per-row action affordance — one quiet ellipsis menu that
/// replaces the old always-on news + AI + company glyph cluster. It rides in
/// only on the hovered OR selected row; the row's own click still selects +
/// charts. Menu items adapt to the row (company for equities, news when a
/// headline exists, explain-rank gated on the copilot's availability).
struct ScanRowActionsMenu: View {
    let symbol: String
    let headline: String?
    let aiDisabled: Bool
    let visible: Bool
    let openChart: () -> Void
    let explain: () -> Void
    let openCompany: () -> Void
    let openNews: () -> Void

    var body: some View {
        Menu {
            Button("open chart", action: openChart)
            Button("explain rank", action: explain).disabled(aiDisabled)
            if AppModel.isEquity(symbol) {
                Button("company", action: openCompany)
            }
            if headline != nil {
                Button("news", action: openNews)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.dim)
                .frame(width: 20, height: 16)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("row actions")
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
    }
}

/// One flag-transition alert row: time, symbol, flag chip. Click selects
/// the symbol (watchlist/chart context follows the operator).
struct ScanAlertRow: View {
    let alert: ScanAlert
    let now: Date
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(alert.symbol)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.bone)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(IntelTime.relative(alert.ts_ms, now: now))
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(Theme.dim)
                }
                ScanFlagChip(text: alert.flag)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(hovering ? Theme.panelHi : .clear)
            .deckRowRule()
        }
        .buttonStyle(.plain)
        .help("select \(alert.symbol)")
        .onHover { hovering = $0 }
        .animation(DeckMotion.ease(), value: hovering)
    }
}

/// The copilot's answer rendered inline where it was asked — the NewsView
/// BriefPanel grammar (ember left bar = AI presence; dismiss clears only
/// this card, the copilot thread keeps the exchange).
struct ScanAnswerCard: View {
    let message: CopilotMessage
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SectionLabel(text: "cortex")
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
                .help("dismiss answer")
            }
            if message.pending {
                ScanPendingDots()
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
private struct ScanPendingDots: View {
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
