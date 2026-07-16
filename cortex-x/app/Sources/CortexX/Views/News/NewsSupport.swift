// NEWS v2 support: the pure, testable models behind the tabbed wire desk —
// the section tabs (NewsTab), the feed filter model (NewsFilter) and its
// saved presets (NewsPreset + NewsPresetStore, UserDefaults), the source-
// badge extraction (NewsSourceBadge), plus the small shared chrome (source
// chip, pending dots) and the earnings/brief helpers (NewsSupport).
//
// Everything here is scoped to the news desk (News*). Every helper is
// NaN-safe: a non-finite tone or threshold never sneaks a row through a
// filter, and absent data is always disclosed rather than fabricated.

import SwiftUI

// MARK: - Section tabs

/// The three faces of the news desk. Raw string so the default and ordering
/// are testable; the tape opens first (FEED) — the point of the view.
enum NewsTab: String, CaseIterable, Identifiable {
    case feed, earnings, brief

    var id: String { rawValue }

    var title: String {
        switch self {
        case .feed: "feed"
        case .earnings: "earnings"
        case .brief: "ai brief"
        }
    }

    /// The desk opens on the tape.
    static let `default`: NewsTab = .feed
}

// MARK: - Source badge

/// The human-readable outlet label for a headline: the engine-provided
/// `source_name` when present, otherwise a name derived from the domain.
enum NewsSourceBadge {
    /// Prefer the resolved outlet name; fall back to the domain-derived label.
    static func label(_ item: NewsItem) -> String {
        if let name = item.source_name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name
        }
        return fromDomain(item.source_domain)
    }

    /// "www.reuters.com" -> "reuters"; "news.example.co.uk" -> "example";
    /// a bare word passes through. Empty stays empty.
    static func fromDomain(_ domain: String) -> String {
        var host = domain.lowercased().trimmingCharacters(in: .whitespaces)
        while host.hasPrefix("www.") { host.removeFirst(4) }
        let parts = host.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return host }
        // Drop the TLD (and a common second-level TLD like ".co.uk"); the
        // registrable label is the piece just before it.
        if parts.count >= 3, Self.secondLevelTLDs.contains(parts[parts.count - 2]) {
            return parts[parts.count - 3]
        }
        if parts.count >= 2 { return parts[parts.count - 2] }
        return parts[0]
    }

    private static let secondLevelTLDs: Set<String> = ["co", "com", "org", "net", "gov", "ac"]

    /// The distinct sources present in a headline set, each with its display
    /// label, sorted by label (ties break on domain) — the multi-select menu
    /// source list. Keyed on `source_domain` (always present, stable).
    static func present(_ items: [NewsItem]) -> [(domain: String, label: String)] {
        var byDomain: [String: String] = [:]
        for item in items where !item.source_domain.isEmpty {
            if byDomain[item.source_domain] == nil {
                byDomain[item.source_domain] = label(item)
            }
        }
        return byDomain
            .map { (domain: $0.key, label: $0.value) }
            .sorted {
                $0.label.caseInsensitiveCompare($1.label) == .orderedSame
                    ? $0.domain < $1.domain
                    : $0.label.caseInsensitiveCompare($1.label) == .orderedAscending
            }
    }
}

// MARK: - Feed filter model

/// The pure, testable feed filter. Every dimension is AND-combined; the
/// result is always newest-first and bounded. An all-default filter is the
/// identity (order preserved except for the newest-first sort + cap).
struct NewsFilter: Codable, Equatable {
    /// Tone gate. A non-finite tone never counts as positive or negative.
    enum Tone: String, Codable, CaseIterable, Identifiable {
        case all, positive, negative
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "all"
            case .positive: "positive"
            case .negative: "negative"
            }
        }
    }

    /// Trailing time window. `all` keeps everything (no age gate).
    enum Window: String, Codable, CaseIterable, Identifiable {
        case h1, h6, h24, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .h1: "1h"
            case .h6: "6h"
            case .h24: "24h"
            case .all: "all"
            }
        }
        /// Window length in ms; nil = no gate.
        var ms: Int64? {
            switch self {
            case .h1: 3_600_000
            case .h6: 21_600_000
            case .h24: 86_400_000
            case .all: nil
            }
        }
    }

    /// Selected source keys (`source_domain`). Empty = all sources.
    var sources: Set<String>
    /// Symbol-tag query (case-insensitive contains on `item.symbol`). When
    /// set, market-wide items (nil symbol) drop out.
    var symbol: String
    /// Keyword query (case-insensitive contains on the title).
    var keyword: String
    var tone: Tone
    var window: Window

    init(
        sources: Set<String> = [], symbol: String = "", keyword: String = "",
        tone: Tone = .all, window: Window = .all
    ) {
        self.sources = sources
        self.symbol = symbol
        self.keyword = keyword
        self.tone = tone
        self.window = window
    }

    /// The default render bound: the feed never draws more than this many rows.
    static let renderCap = 300

    /// True when any dimension narrows the tape — drives the clear affordance
    /// and the active styling.
    var isActive: Bool {
        !sources.isEmpty
            || !symbol.trimmingCharacters(in: .whitespaces).isEmpty
            || !keyword.trimmingCharacters(in: .whitespaces).isEmpty
            || tone != .all
            || window != .all
    }

    /// Filter, sort newest-first, and cap. `nowMs` is injected for tests.
    func apply(_ items: [NewsItem], nowMs: Int64, cap: Int = renderCap) -> [NewsItem] {
        var out = items.filter { item in
            matchesSource(item)
                && matchesSymbol(item)
                && matchesKeyword(item)
                && matchesTone(item)
                && matchesWindow(item, nowMs: nowMs)
        }
        out.sort { $0.ts_ms > $1.ts_ms }
        if cap >= 0, out.count > cap { out.removeLast(out.count - cap) }
        return out
    }

    // MARK: dimension matchers

    private func matchesSource(_ item: NewsItem) -> Bool {
        sources.isEmpty || sources.contains(item.source_domain)
    }

    private func matchesSymbol(_ item: NewsItem) -> Bool {
        let q = symbol.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        guard let s = item.symbol else { return false }
        return s.localizedCaseInsensitiveContains(q)
    }

    private func matchesKeyword(_ item: NewsItem) -> Bool {
        let q = keyword.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return item.title.localizedCaseInsensitiveContains(q)
    }

    private func matchesTone(_ item: NewsItem) -> Bool {
        switch tone {
        case .all: return true
        case .positive: return item.tone.isFinite && item.tone > 0
        case .negative: return item.tone.isFinite && item.tone < 0
        }
    }

    private func matchesWindow(_ item: NewsItem, nowMs: Int64) -> Bool {
        guard let ms = window.ms else { return true }
        return item.ts_ms >= nowMs - ms
    }
}

// MARK: - Saved presets

/// One saved feed filter: a name plus the whole NewsFilter posture.
struct NewsPreset: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var filter: NewsFilter

    init(id: UUID = UUID(), name: String, filter: NewsFilter) {
        self.id = id
        self.name = name
        self.filter = filter
    }
}

/// Saved-preset persistence: one JSON blob in UserDefaults (the ScreenStore
/// pattern). Loads once at init, saves on every mutation.
@MainActor
@Observable
final class NewsPresetStore {
    private(set) var presets: [NewsPreset] = []

    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "news.filterPresets.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.key),
            let list = try? JSONDecoder().decode([NewsPreset].self, from: data) else { return }
        presets = list
    }

    /// Saves `filter` under `name` (trimmed; blank rejected). An existing
    /// preset with the same name (case-insensitive) is replaced in place —
    /// names stay unique.
    @discardableResult
    func save(name: String, filter: NewsFilter) -> NewsPreset? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if let i = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            presets[i].name = name
            presets[i].filter = filter
            persist()
            return presets[i]
        }
        let preset = NewsPreset(name: name, filter: filter)
        presets.append(preset)
        persist()
        return preset
    }

    func delete(id: UUID) {
        let before = presets.count
        presets.removeAll { $0.id == id }
        guard presets.count != before else { return }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

// MARK: - Earnings / brief helpers

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

    /// A terse countdown for the estimate: "today", "in 1d", "in 14d", or
    /// "passed" once the date is behind us; nil when the date won't parse.
    static func countdown(_ day: String, now: Date) -> String? {
        guard let d = daysUntil(day, now: now) else { return nil }
        if d < 0 { return "passed" }
        if d == 0 { return "today" }
        return "in \(d)d"
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

// MARK: - Shared chrome

/// The outlet badge chip: bone label in the standard hairline outline (design
/// law reserves colored borders for nothing).
struct NewsSourceChip: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.bone)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.chipRadius)
                    .strokeBorder(Theme.line, lineWidth: Theme.hairline)
            )
    }
}

/// Copilot pending grammar: three pulsing dim dots. Shared by the brief cards.
struct NewsPendingDots: View {
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
