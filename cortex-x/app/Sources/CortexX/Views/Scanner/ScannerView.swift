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
    case all, topMomentum, breakoutWatch, oversold, volMovers, premarketMovers, equities, crypto

    var title: String {
        switch self {
        case .all: "all"
        case .topMomentum: "top momentum"
        case .breakoutWatch: "breakout watch"
        case .oversold: "oversold"
        case .volMovers: "vol movers"
        case .premarketMovers: "premarket movers"
        case .equities: "equities"
        case .crypto: "crypto"
        }
    }

    /// Chip tooltip — spells out the delayed-quote basis where it matters.
    var help: String? {
        self == .premarketMovers
            ? "equities gapping ±\(Int(Self.premarketGapMin * 100))%+ between the "
                + "latest price (delayed ~15m) and the prior session D1 close, biggest gap first"
            : nil
    }

    /// `lastPrice` feeds the presets that need a price beyond the row (the
    /// premarket-movers gap); it defaults to "unknown" so every other
    /// preset — and existing callers — stays pure over rows alone.
    func apply(
        _ rows: [ScanRow], lastPrice: (String) -> Double? = { _ in nil }
    ) -> [ScanRow] {
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
        case .premarketMovers:
            // Equities whose latest (delayed) price gaps >= 2% off the prior
            // session's D1 close (`last_close` is the newest COMPLETE daily
            // close), biggest absolute gap first. Rows without a usable
            // price or close never sneak in.
            return rows
                .compactMap { row -> (row: ScanRow, gap: Double)? in
                    guard !row.symbol.contains("-"),
                        let gap = Self.gapFraction(
                            lastPrice: lastPrice(row.symbol), priorClose: row.last_close
                        ), abs(gap) >= Self.premarketGapMin else { return nil }
                    return (row, gap)
                }
                .sorted { abs($0.gap) > abs($1.gap) }
                .map(\.row)
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

    /// Minimum absolute gap fraction for the premarket-movers screen (2%).
    static let premarketGapMin = 0.02

    /// Fractional gap between the latest price and the prior D1 close.
    /// nil whenever either side is absent, non-finite, or non-positive —
    /// absent data never fabricates a gap.
    static func gapFraction(lastPrice: Double?, priorClose: Double) -> Double? {
        guard let lastPrice, lastPrice.isFinite, lastPrice > 0,
            priorClose.isFinite, priorClose > 0 else { return nil }
        return (lastPrice - priorClose) / priorClose
    }
}

/// Table columns in display order. Codable (raw string) so filters and
/// saved screens can persist column references.
enum ScanColumn: String, CaseIterable, Codable {
    case symbol, price, change, composite, momentum, trend, breakout, meanrev, volState,
         rsi, zscore, ret1w, ret1m, ret3m, dist52wHi, volSurge,
         sector, marketCap, floatUsd, shortFloat, news, regime, flags

    var title: String {
        switch self {
        case .symbol: "sym"
        case .price: "last"
        case .change: "chg%"
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
        case .sector: "sector"
        case .marketCap: "mktcap"
        case .floatUsd: "float$"
        case .shortFloat: "short%flt"
        case .news: "news"
        case .regime: "regime"
        case .flags: "flags"
        }
    }

    /// Which headers the operator may click to sort. CHG% has no row field, but
    /// the details table injects the live session change exactly as the summary
    /// table does (see `ScanSort.apply`) — leaving it unsortable here made the
    /// SAME header behave differently in the two table modes.
    var sortable: Bool {
        switch self {
        case .flags, .news, .sector, .shortFloat, .floatUsd, .marketCap: false
        default: true
        }
    }

    /// Whether the filter builder may offer this column. Exactly the columns
    /// `ScanSort.key` answers with a number: a field whose key is nil makes
    /// `ScanFilter.matches` false for EVERY row, so picking it blanks the whole
    /// board and the operator reads "no rows match this screen" instead of
    /// "this filter is structurally incapable of matching". Six fields (chg% /
    /// sector / mktcap / float$ / short%flt / news) used to be offered that way.
    /// MUST stay in lockstep with `ScanSort.key` — ScannerRepairTests asserts a
    /// non-nil key for every filterable column, so a new dead field fails tests
    /// instead of silently emptying a screen.
    var filterable: Bool {
        switch self {
        // Identity, categorical strings, the boolean news glyph, the live
        // injected change, and the price-derived cells (mktcap / float$ /
        // short%flt) have no static row key today.
        case .symbol, .change, .sector, .marketCap, .floatUsd, .shortFloat, .news, .regime, .flags:
            false
        default:
            true
        }
    }

    /// The unit the operator types a filter threshold in, when it isn't the bare
    /// reading. The return + Δ52w columns STORE simple-return fractions but
    /// DISPLAY percent (`ScanFormat.pct` multiplies by 100), so a threshold typed
    /// as "5" for 5% must not be compared against `ret_1m == 0.05` — that screens
    /// for +500% and quietly empties the board. Rendered beside the value field
    /// and in the collapsed filter summary so the convention is visible.
    var filterUnit: String? {
        switch self {
        case .ret1w, .ret1m, .ret3m, .dist52wHi: "%"
        default: nil
        }
    }

    /// A raw row reading expressed in the unit the CELL renders, so a filter
    /// compares against the number the operator can actually see.
    /// - Returns: percent for the fraction-valued return columns (0.052 → 5.2).
    ///   Δ52w-hi arrives from the engine as a non-negative drawdown but the cell
    ///   renders it as a signed distance ("-3.2%"), so the filter reading is
    ///   negated too — "Δ52w-hi >= -5%" then means "within 5% of the high",
    ///   which is what the column shows.
    func filterReading(_ raw: Double) -> Double {
        switch self {
        case .ret1w, .ret1m, .ret3m: raw * 100
        case .dist52wHi: -abs(raw) * 100
        default: raw
        }
    }
}

/// One sort order over the scan table. nil readings sort last in BOTH
/// directions — absent data never floats to the top of a screen.
struct ScanSort: Equatable, Codable {
    var column: ScanColumn
    var ascending: Bool

    /// Numeric sort key for value columns; nil for string columns / flags.
    /// STATIC — row fields only, no model reads — because `ScanFilter.matches`
    /// evaluates a persisted screen through it. The live readings the cells
    /// render are injected into `apply` instead.
    static func key(_ row: ScanRow, _ column: ScanColumn) -> Double? {
        switch column {
        // The stable daily basis. `apply` prefers the injected live quote (the
        // number the LAST cell actually shows); this is the fallback + the value
        // a pure row-only filter screens on.
        case .price: row.last_close
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
        // Categorical / boolean / client-injected → no static key.
        case .symbol, .change, .sector, .marketCap, .floatUsd, .shortFloat, .news, .regime, .flags: nil
        }
    }

    /// Sort the rows for the details grid. `price` / `change` inject the LIVE
    /// readings the cells actually render (`model.lastPrice` /
    /// `model.sessionChangePct`). Without them LAST sorted on the stale
    /// `last_close` while the cell showed the live quote, so a descending LAST
    /// column was visibly not descending — a $99.20 close now trading $104.10
    /// sank below a $101.00 close now trading $100.40. Both default to "unknown"
    /// so row-only callers stay pure: LAST then falls back to `last_close`, and
    /// CHG% (which has no row field at all) sorts as all-absent.
    func apply(
        _ rows: [ScanRow],
        price: (ScanRow) -> Double? = { _ in nil },
        change: (ScanRow) -> Double? = { _ in nil }
    ) -> [ScanRow] {
        switch column {
        case .symbol:
            // Stored field, never absent — a plain compare, no decoration needed.
            return rows.sorted { ascending ? $0.symbol < $1.symbol : $0.symbol > $1.symbol }
        case .regime:
            return Self.ordered(rows, ascending: ascending) { $0.regime?.label }
        case .flags:
            return rows
        case .price:
            // Same preference the LAST cell renders: the live quote, falling back
            // to the daily close only when there is no usable tick yet.
            return Self.ordered(rows, ascending: ascending) {
                Self.finite(price($0)) ?? Self.finite($0.last_close)
            }
        case .change:
            return Self.ordered(rows, ascending: ascending) { Self.finite(change($0)) }
        default:
            return Self.ordered(rows, ascending: ascending) { Self.finite(Self.key($0, column)) }
        }
    }

    /// A non-finite reading is no reading: NaN/±inf sink with nil rather than
    /// poisoning the comparator (every NaN comparison is false, which makes the
    /// ordering depend on the sort's internal pivot choices).
    private static func finite(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return v
    }

    /// nil-last decorate-sort-undecorate. The key is computed ONCE per row: an
    /// injected key is an AppModel read (sessionChangePct walks the D1 series
    /// doing calendar day-key math), and evaluating it inside the comparator
    /// costs ~2·n·log₂n reads per sort instead of n. nil readings sort last in
    /// BOTH directions — absent data never floats to the top of a screen.
    private static func ordered<K: Comparable>(
        _ rows: [ScanRow], ascending: Bool, key: (ScanRow) -> K?
    ) -> [ScanRow] {
        rows.map { (row: $0, k: key($0)) }
            .sorted { a, b in
                switch (a.k, b.k) {
                case let (x?, y?): x == y ? false : (ascending ? x < y : x > y)
                case (_?, nil): true
                default: false
                }
            }
            .map(\.row)
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

/// The operator's DETAILS-table column configuration — which columns show and in
/// what order — persisted as one @AppStorage value (JSON). Columns can be added,
/// removed, and drag-reordered; a new catalog column is appended by `reconciled`
/// so it never silently vanishes for an existing user.
struct ScanColumnLayout: RawRepresentable, Equatable {
    var order: [ScanColumn]
    var visible: Set<ScanColumn>

    init(order: [ScanColumn], visible: Set<ScanColumn>) {
        self.order = order
        self.visible = visible
    }

    // Explicit memberwise equality. RawRepresentable would otherwise supply an
    // == that compares rawValue (a JSON string), which is order-sensitive and
    // therefore unstable for the Set — two value-equal layouts would compare
    // unequal whenever the set serialized in a different order.
    static func == (lhs: ScanColumnLayout, rhs: ScanColumnLayout) -> Bool {
        lhs.order == rhs.order && lhs.visible == rhs.visible
    }

    /// The shown columns in order.
    var shown: [ScanColumn] { order.filter(visible.contains) }

    /// Forward-compat: append any catalog column missing from a persisted order.
    func reconciled() -> ScanColumnLayout {
        var o = order
        for c in ScanColumn.allCases where !o.contains(c) { o.append(c) }
        return ScanColumnLayout(order: o, visible: visible)
    }

    func moving(_ col: ScanColumn, before target: ScanColumn) -> ScanColumnLayout {
        guard col != target, let from = order.firstIndex(of: col) else { return self }
        var o = order
        o.remove(at: from)
        let to = o.firstIndex(of: target) ?? o.count
        o.insert(col, at: to)
        return ScanColumnLayout(order: o, visible: visible)
    }

    func toggling(_ col: ScanColumn) -> ScanColumnLayout {
        var v = visible
        if v.contains(col) { v.remove(col) } else { v.insert(col) }
        // symbol is the anchor — never hide it.
        v.insert(.symbol)
        return ScanColumnLayout(order: order, visible: v)
    }

    // @AppStorage RawRepresentable bridge (JSON string). NOTE: the type is
    // deliberately NOT Codable — a RawRepresentable<String> that also conforms
    // to Codable inherits the stdlib's default encode(to:), which re-encodes
    // self.rawValue and recurses through JSONEncoder forever (stack overflow).
    // We bridge through a plain Codable payload instead.
    private struct Payload: Codable {
        var order: [ScanColumn]
        var visible: [ScanColumn]
    }
    var rawValue: String {
        // Full determinism so persistence never thrashes: sort the visible SET
        // into a stable array AND set .sortedKeys (JSONEncoder otherwise emits
        // the object's top-level keys in a per-process hash order). Without both,
        // rawValue varies between encodes of an unchanged layout, causing
        // needless @AppStorage writes + SwiftUI change-detection churn.
        let payload = Payload(order: order, visible: visible.sorted { $0.rawValue < $1.rawValue })
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        self.init(order: p.order, visible: Set(p.visible))
    }

    /// The default DETAILS layout: identity + live price/change + the headline
    /// analytics + sector, with the deeper score grid available but off.
    static let detailsDefault = ScanColumnLayout(
        order: ScanColumn.allCases,
        visible: [.symbol, .price, .change, .composite, .rsi, .ret1m, .ret3m,
                  .volSurge, .sector, .news, .regime, .flags]
    )
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

    /// Adaptive last price: big numbers lose the cents, small keep 2dp.
    static func priceFmt(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        if abs(v) >= 1000 { return String(format: "%.0f", v) }
        if abs(v) >= 1 { return String(format: "%.2f", v) }
        return String(format: "%.4f", v)
    }

    /// First `max` flags shown as chips, the rest collapse to "+n".
    static func flagsDisplay(_ flags: [String], max: Int = 2) -> (shown: [String], overflow: Int) {
        guard flags.count > max else { return (flags, 0) }
        return (Array(flags.prefix(max)), flags.count - max)
    }
}

/// Discriminates the scanner's two empty states. A genuinely empty board (no
/// scan yet) shows the first-scan-pending copy; a board WITH rows whose active
/// preset + filters + search matched none shows a "no rows match this screen"
/// message naming the screen — never a blank void. Pure so both the branch and
/// the copy are testable.
enum ScanEmptyState {
    /// True only when the board has rows but the visible (post preset / filter
    /// / search) set is empty — the screen filtered everything out.
    static func isScreenedEmpty(boardRowCount: Int, visibleRowCount: Int) -> Bool {
        boardRowCount > 0 && visibleRowCount == 0
    }

    /// One quiet line naming the active screen so the operator knows what to
    /// relax: the preset, plus any filter count and (trimmed) symbol query.
    static func detail(preset: String, filterCount: Int, query: String) -> String {
        var parts = ["'\(preset)'"]
        if filterCount > 0 {
            parts.append("\(filterCount) filter\(filterCount == 1 ? "" : "s")")
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { parts.append("symbol '\(q)'") }
        return "nothing passes " + parts.joined(separator: " + ")
            + " right now — relax the screen or clear filters"
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
    static let gap: CGFloat = 8
    /// The single trailing row-action affordance (hover/selected ellipsis).
    static let trailing: CGFloat = 24

    static let price: CGFloat = 62
    static let change: CGFloat = 56
    static let sector: CGFloat = 96
    static let mktcap: CGFloat = 74
    static let floatUsd: CGFloat = 70
    static let shortFloat: CGFloat = 66
    static let news: CGFloat = 38

    static func width(_ column: ScanColumn) -> CGFloat {
        switch column {
        case .symbol: sym
        case .price: price
        case .change: change
        case .composite: composite
        case .momentum, .trend, .breakout, .meanrev, .volState: score
        case .rsi: rsi
        case .zscore: z
        case .ret1w, .ret1m, .ret3m: ret
        case .dist52wHi: dist
        case .volSurge: ratio
        case .sector: sector
        case .marketCap: mktcap
        case .floatUsd: floatUsd
        case .shortFloat: shortFloat
        case .news: news
        case .regime: regime
        case .flags: flags
        }
    }

    static func alignment(_ column: ScanColumn) -> Alignment {
        switch column {
        case .symbol, .composite, .sector, .news, .regime, .flags: .leading
        default: .trailing
        }
    }

    /// Total content width: columns + gaps + the trailing affordances.
    static var minWidth: CGFloat { shownWidth(ScanColumn.allCases) }

    /// Content width for a specific set of shown columns (drives the h-scroll floor).
    static func shownWidth(_ columns: [ScanColumn]) -> CGFloat {
        let cols = columns.map(width).reduce(0, +)
        return cols + gap * CGFloat(columns.count) + trailing + 24
    }
}

// MARK: - View

struct ScannerView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var preset: ScanPreset = .all
    // Column sort: `sort` for the details grid, `summarySort` for the default
    // six-column table. Each mode keeps its own so switching never surprises.
    @State private var sort: ScanSort?
    @State private var summarySort: ScanSummary.Sort?
    // Filter builder + saved screens.
    @State private var filters: [ScanFilter] = []
    @State private var filtersOpen = false
    @State private var screens = ScreenStore()
    @State private var screenName = ""
    // Alert stream.
    @State private var lastSeenAlertID: String?
    // Copilot request id whose answer renders inline; nil = dismissed.
    @State private var aiRequestId: String?
    // Persisted view posture. The calm defaults hold: the summary table,
    // no alert strip, no AI-picks action — the operator opts each in.
    @AppStorage(ScanPrefs.details) private var showDetails = false
    @AppStorage(ScanPrefs.showAlerts) private var showAlerts = false
    @AppStorage(ScanPrefs.showAIPicks) private var showAIPicks = false
    // Configurable, drag-reorderable DETAILS columns (persisted).
    @AppStorage(ScanPrefs.columns) private var columnLayout = ScanColumnLayout.detailsDefault

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            legend
            Divider().overlay(Theme.line)
            presetRow
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
                        if showDetails { detailsTable(board) } else { summaryTable(board) }
                    } else {
                        emptyState
                    }
                }
                // topLeading so a table shorter/narrower than the pane hugs the
                // corner and grows from there — never floats dead-center in a
                // void. The tables themselves fill; this pins whatever doesn't.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if showAlerts {
                    Divider().overlay(Theme.line)
                    alertStrip
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
    }

    /// One quiet line that demystifies every score in the table.
    private var legend: some View {
        Text("scores are 0-100 percentile ranks vs the universe today · higher = stronger")
            .font(.system(size: 10))
            .foregroundStyle(Theme.dim)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
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
                // The composite weights ride behind a quiet "i" — hover to
                // read them, never a standing chip.
                if let weights = ScanWeights.summary(board.weights_used) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.dim)
                        .help(weights)
                }
            }
            Spacer()
            if showAIPicks, let board = model.scanBoard, !board.rows.isEmpty {
                aiPicksChip(board)
            }
            searchField
            detailsToggle
            // Column configuration is NOT here — it lives in the grid's header
            // row, next to the last column header (see `columnsMenu`).
            aiToggle
            alertsToggle
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// Swap the calm six-column summary for the full percentile grid.
    private var detailsToggle: some View {
        Button {
            showDetails.toggle()
        } label: {
            Image(systemName: "tablecells")
                .font(.system(size: 11))
                .foregroundStyle(showDetails ? Theme.ember : Theme.dim)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(showDetails ? "show the summary table" : "show the full percentile grid")
        .animation(DeckMotion.ease(), value: showDetails)
    }

    /// Reveal the header AI-PICKS action (off by default).
    private var aiToggle: some View {
        Button {
            showAIPicks.toggle()
        } label: {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 11))
                .foregroundStyle(showAIPicks ? Theme.ember : Theme.dim)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(showAIPicks ? "hide AI picks" : "show AI picks")
        .animation(DeckMotion.ease(), value: showAIPicks)
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
            showAlerts.toggle()
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 11))
                .foregroundStyle(showAlerts ? Theme.ember : Theme.dim)
                .overlay(alignment: .topTrailing) {
                    if !showAlerts && hasUnseenAlerts {
                        Circle()
                            .fill(Theme.ember)
                            .frame(width: 4, height: 4)
                            .offset(x: 3, y: -3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(showAlerts ? "hide alert stream" : "show alert stream")
        .animation(DeckMotion.ease(), value: showAlerts)
    }

    private var alertStrip: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    SectionLabel(text: "alerts")
                    if hasUnseenAlerts {
                        // Quiet static ember dot — the same unseen marker the
                        // toggle uses; no standing animation (design law).
                        Circle()
                            .fill(Theme.ember)
                            .frame(width: 4, height: 4)
                    }
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

    /// One-tap threshold screens (the requested "RSI ≤ 30" among them). Each is a
    /// real ScanFilter toggled on/off; active = ember. Honest numeric screens.
    private static let quickFilters: [(label: String, filter: ScanFilter)] = [
        ("RSI ≤ 30", ScanFilter(column: .rsi, op: .lte, value: 30)),
        ("RSI ≥ 70", ScanFilter(column: .rsi, op: .gte, value: 70)),
        ("RVOL ≥ 2×", ScanFilter(column: .volSurge, op: .gte, value: 2)),
        // Percent, like the 1M% column shows — the threshold is not a fraction.
        ("1M ≥ 0%", ScanFilter(column: .ret1m, op: .gte, value: 0)),
        ("COMP ≥ 80", ScanFilter(column: .composite, op: .gte, value: 80)),
    ]

    private func quickActive(_ f: ScanFilter) -> Bool {
        filters.contains { $0.column == f.column && $0.op == f.op && $0.value == f.value }
    }

    private func toggleQuick(_ f: ScanFilter) {
        if let i = filters.firstIndex(where: { $0.column == f.column && $0.op == f.op && $0.value == f.value }) {
            filters.remove(at: i)
        } else {
            filters.append(ScanFilter(column: f.column, op: f.op, value: f.value))
        }
    }

    private var quickFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("QUICK")
                    .font(.system(size: 9, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(Theme.dim)
                ForEach(Self.quickFilters.indices, id: \.self) { i in
                    let q = Self.quickFilters[i]
                    let on = quickActive(q.filter)
                    Button { withAnimation(DeckMotion.ease()) { toggleQuick(q.filter) } } label: {
                        Text(q.label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(on ? Theme.ember : Theme.dim)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(on ? Theme.emberTint : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
                            .overlay(RoundedRectangle(cornerRadius: Theme.chipRadius)
                                .strokeBorder(on ? Theme.ember.opacity(0.5) : Theme.line, lineWidth: Theme.hairline))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

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
                    // Rendered through the filter's own unit-aware summary so the
                    // collapsed line can't read as a bare unscaled number
                    // ("1m% >= 5.0" invited the fraction/percent misreading).
                    Text(filters.map(\.summaryText).joined(separator: " · "))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
                Spacer()
                screensMenu
            }
            quickFilterChips
            if filtersOpen {
                ForEach($filters) { $filter in
                    ScanFilterRowView(filter: $filter) {
                        filters.removeAll { $0.id == filter.id }
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        // Starts DISABLED — configuring/enabling it activates it,
                        // so adding a row never surprise-culls half the board.
                        filters.append(ScanFilter(enabled: false))
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
        guard screens.save(name: screenName, preset: preset, filters: filters,
                           sort: sort, summarySort: summarySort) != nil
        else { return }
        screenName = ""
    }

    private func load(_ screen: SavedScreen) {
        preset = screen.preset
        filters = screen.filters
        sort = screen.sort
        summarySort = screen.summarySort
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
            sort = nil // fall back to the preset's own ordering…
            summarySort = nil // …in BOTH table modes, symmetrically
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
        .help(p.help ?? p.title)
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

    /// Preset + filters + search, WITHOUT a column sort — the shared base for
    /// both modes. Each table then applies its own sort.
    private func baseRows(_ board: ScanBoard) -> [ScanRow] {
        var rows = preset.apply(board.rows, lastPrice: { model.lastPrice($0) })
        rows = ScanFilter.apply(filters, to: rows)
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            rows = rows.filter { $0.symbol.localizedCaseInsensitiveContains(query) }
        }
        return rows
    }

    /// The rows the operator actually sees, in the active mode's order — the
    /// basis for the row count and the AI-picks prompt.
    private func displayRows(_ board: ScanBoard) -> [ScanRow] {
        let rows = baseRows(board)
        if showDetails {
            guard let sort else { return rows }
            // The live readings the LAST / CHG% cells render, injected so the
            // sorted order matches what the operator sees in the column.
            return sort.apply(
                rows,
                price: { model.lastPrice($0.symbol) },
                change: { model.sessionChangePct($0.symbol) }
            )
        }
        return ScanSummary.sorted(
            rows, by: summarySort,
            price: { model.lastPrice($0.symbol) },
            change: { model.sessionChangePct($0.symbol) }
        )
    }

    private func openChart(_ row: ScanRow) {
        model.selectSymbol(row.symbol)
        model.centerMode = .chart
    }

    private var headlines: [String: String] {
        ScanNews.latestHeadlines(
            model.newsBoard?.items ?? [],
            nowMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    // MARK: Summary table (the calm default — six readable columns)

    @ViewBuilder
    private func summaryTable(_ board: ScanBoard) -> some View {
        let rows = displayRows(board)
        if ScanEmptyState.isScreenedEmpty(boardRowCount: board.rows.count, visibleRowCount: rows.count) {
            noRowsForScreen
        } else {
            let news = headlines
            // Vertical-only scroll: the six calm columns fit any standard pane,
            // so rows and header span its full width (one column flexes) rather
            // than riding a narrow, horizontally scrolling island. The dense
            // 16-column details grid keeps its two-axis scroll — it earns it.
            ScrollView(.vertical) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(rows) { row in
                            ScanSummaryRowView(
                                row: row,
                                verdict: ScanVerdict.classify(row),
                                price: model.lastPrice(row.symbol),
                                change: model.sessionChangePct(row.symbol),
                                headline: news[row.symbol],
                                aiDisabled: aiDisabled,
                                selected: model.selectedSymbol == row.symbol,
                                openChart: { openChart(row) },
                                openCompany: { model.openCompany(row.symbol) },
                                openNews: { model.centerMode = .news },
                                explain: {
                                    aiRequestId = model.askCopilot(
                                        ScanAI.explainPrompt(
                                            row: row,
                                            rank: (rows.firstIndex(of: row) ?? 0) + 1,
                                            of: rows.count
                                        )
                                    )
                                }
                            )
                        }
                    } header: {
                        summaryHeaderRow
                    }
                }
            }
        }
    }

    private var summaryHeaderRow: some View {
        HStack(spacing: ScanSummaryCol.gap) {
            ForEach(ScanSummary.columns, id: \.self) { col in
                summaryHeaderCell(col)
            }
            // A fixed reservation for the per-row action glyph — NOT a flexible
            // Spacer, which would fight the flag column for the leftover width.
            Color.clear.frame(width: ScanSummaryCol.action, height: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ink)
        .deckRowRule(1)
    }

    private func summaryHeaderCell(_ col: ScanSummary.Column) -> some View {
        let active = summarySort?.column == col
        return Button {
            summarySort = ScanSummary.Sort.toggling(summarySort, column: col)
        } label: {
            HStack(spacing: 3) {
                if col.alignment == .trailing { Spacer(minLength: 0) }
                Text(col.title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(active ? Theme.ember : Theme.dim)
                    .lineLimit(1)
                if active, let summarySort {
                    Image(systemName: summarySort.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.ember)
                }
                if col.alignment == .leading { Spacer(minLength: 0) }
            }
            // The one flexing column grows from its fixed width to the leftover
            // pane width; every other column is pinned. Row cells mirror this so
            // header and body stay column-aligned.
            .frame(
                minWidth: ScanSummaryCol.width(col),
                maxWidth: col.fillsWidth ? .infinity : ScanSummaryCol.width(col)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!col.sortable)
        .animation(DeckMotion.ease(), value: active)
    }

    /// The board HAS rows, but the active preset + filters + search matched
    /// none. Named so the operator knows WHICH screen to relax — centered in
    /// the pane, one dim voice, never a blank void.
    private var noRowsForScreen: some View {
        VStack(spacing: 8) {
            Text("no rows match this screen")
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
            Text(ScanEmptyState.detail(preset: preset.title, filterCount: filters.count, query: search))
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Details table (the opt-in full percentile grid)

    @ViewBuilder
    private func detailsTable(_ board: ScanBoard) -> some View {
        let rows = displayRows(board)
        if ScanEmptyState.isScreenedEmpty(boardRowCount: board.rows.count, visibleRowCount: rows.count) {
            noRowsForScreen
        } else {
            let news = headlines
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            ScanRowView(
                                row: row,
                                columns: columnLayout.shown,
                                price: model.lastPrice(row.symbol),
                                change: model.sessionChangePct(row.symbol),
                                headline: news[row.symbol],
                                aiDisabled: aiDisabled,
                                selected: model.selectedSymbol == row.symbol,
                                openChart: { openChart(row) },
                                openCompany: { model.openCompany(row.symbol) },
                                openNews: { model.centerMode = .news },
                                explain: {
                                    aiRequestId = model.askCopilot(
                                        ScanAI.explainPrompt(row: row, rank: index + 1, of: rows.count)
                                    )
                                }
                            )
                        }
                    } header: {
                        headerRow
                    }
                }
                .frame(minWidth: ScanCol.shownWidth(columnLayout.shown), alignment: .leading)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: ScanCol.gap) {
            ForEach(columnLayout.shown, id: \.self) { col in
                headerCell(col)
            }
            // Sits directly after the LAST column header, on the table it acts
            // on. `ScanCol.shownWidth` already reserves this slot (its trailing
            // `+ 24`), so the header rule still spans the full row width and the
            // button is never clipped.
            columnsMenu
            // Reserve the trailing slot the row's actions menu occupies so the
            // header rule lines up with the rows beneath it.
            Spacer(minLength: ScanCol.trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.ink)
        .deckRowRule(1)
    }

    /// A header cell that sorts its column on tap. Reordering lives in the
    /// columns menu (move left/right) — a plain tap NEVER competes with a drag
    /// gesture, which on macOS turned every sort click into a stray drag-start.
    private func headerCell(_ col: ScanColumn) -> some View {
        let active = sort?.column == col
        return Button {
            if col.sortable { sort = ScanSort.toggling(sort, column: col) }
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

    /// Add / remove / reorder columns. Sits in the grid's header row, directly
    /// after the last column header, so the control is on the table it acts on.
    /// Each shown column reorders via move left/right (reliable — no drag
    /// gesture to fight the sort tap) and can be hidden; hidden columns add
    /// from a submenu.
    private var columnsMenu: some View {
        Menu {
            ForEach(columnLayout.shown, id: \.self) { col in
                Menu(col.title) {
                    Button("move left") { moveColumn(col, by: -1) }
                        .disabled(!canMoveColumn(col, by: -1))
                    Button("move right") { moveColumn(col, by: 1) }
                        .disabled(!canMoveColumn(col, by: 1))
                    if col != .symbol {
                        Divider()
                        Button("hide", role: .destructive) {
                            columnLayout = columnLayout.toggling(col).reconciled()
                        }
                    }
                }
            }
            let hidden = ScanColumn.allCases.filter { !columnLayout.visible.contains($0) }
            if !hidden.isEmpty {
                Divider()
                Menu("add column") {
                    ForEach(hidden, id: \.self) { col in
                        Button(col.title) {
                            columnLayout = columnLayout.toggling(col).reconciled()
                        }
                    }
                }
            }
            Divider()
            Button("reset columns") { columnLayout = .detailsDefault }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.dim)
                .frame(width: 20, height: 16)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("add / remove / reorder columns")
    }

    /// Whether `col` can shift one slot `by` (-1 left / +1 right) among the
    /// SHOWN columns without falling off either end.
    private func canMoveColumn(_ col: ScanColumn, by delta: Int) -> Bool {
        let shown = columnLayout.shown
        guard let i = shown.firstIndex(of: col) else { return false }
        let j = i + delta
        return j >= 0 && j < shown.count
    }

    /// Swap `col` with its adjacent SHOWN neighbor in that direction (hidden
    /// columns keep their slots; only the two visible ones exchange order).
    private func moveColumn(_ col: ScanColumn, by delta: Int) {
        let shown = columnLayout.shown
        guard let i = shown.firstIndex(of: col) else { return }
        let j = i + delta
        guard j >= 0, j < shown.count else { return }
        let neighbor = shown[j]
        var order = columnLayout.order
        guard let a = order.firstIndex(of: col), let b = order.firstIndex(of: neighbor) else { return }
        order.swapAt(a, b)
        withAnimation(DeckMotion.ease()) {
            columnLayout = ScanColumnLayout(order: order, visible: columnLayout.visible).reconciled()
        }
    }
}

extension ScanColumn: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.rawValue, importing: { ScanColumn(rawValue: $0) ?? .symbol })
    }
}

// MARK: - Row

private struct ScanRowView: View {
    let row: ScanRow
    /// The shown columns, in the operator's order (drives the cell layout).
    let columns: [ScanColumn]
    /// Live client-injected values (nil → the cell renders "—" / a proxy).
    let price: Double?
    let change: Double?
    /// Latest in-window headline title for this symbol; nil = no news action.
    let headline: String?
    let aiDisabled: Bool
    let selected: Bool
    let openChart: () -> Void
    let openCompany: () -> Void
    let openNews: () -> Void
    let explain: () -> Void
    @State private var hovering = false

    var body: some View {
        // The row-select tap is a SIBLING gesture on the container, NOT an outer
        // Button — an outer Button would swallow clicks meant for the nested
        // ScanRowActionsMenu (a Menu inside a Button never opens on macOS).
        HStack(spacing: ScanCol.gap) {
            ForEach(columns, id: \.self) { col in cell(col) }
            ScanRowActionsMenu(
                symbol: row.symbol, headline: headline, aiDisabled: aiDisabled,
                visible: hovering || selected,
                openChart: openChart, explain: explain,
                openCompany: openCompany, openNews: openNews
            )
        }
        .padding(.horizontal, 12)
        .frame(height: 25)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(hovering || selected ? Theme.panelHi : .clear)
        .deckRowRule()
        .onTapGesture(perform: openChart)
        .onHover { hovering = $0 }
        .animation(DeckMotion.ease(), value: hovering)
    }

    /// Each column's cell — self-framed to ScanCol.width so header + body stay
    /// aligned regardless of order.
    @ViewBuilder
    private func cell(_ col: ScanColumn) -> some View {
        switch col {
        case .symbol: symbolCell
        case .price: priceCell
        case .change: changeCell
        case .composite: compositeCell
        case .momentum: scoreCell(row.momentum)
        case .trend: scoreCell(row.trend)
        case .breakout: scoreCell(row.breakout)
        case .meanrev: scoreCell(row.meanrev)
        case .volState: scoreCell(row.vol_state)
        case .rsi: rsiCell
        case .zscore: rawCell(ScanFormat.raw(row.zscore_20, decimals: 2, signed: true), present: row.zscore_20 != nil, width: ScanCol.z)
        case .ret1w: returnCell(row.ret_1w)
        case .ret1m: returnCell(row.ret_1m)
        case .ret3m: returnCell(row.ret_3m)
        case .dist52wHi: rawCell(ScanFormat.distFromHigh(row.dist_52w_high), present: row.dist_52w_high != nil, width: ScanCol.dist)
        case .volSurge: rawCell(ScanFormat.ratio(row.vol_surge), present: row.vol_surge != nil, width: ScanCol.ratio)
        case .sector: sectorCell
        case .marketCap: marketCapCell
        case .floatUsd: rawCell(CompanyFormat.abbrevMoney(row.public_float_usd), present: row.public_float_usd != nil, width: ScanCol.floatUsd)
        case .shortFloat: shortFloatCell
        case .news: newsCell
        case .regime: regimeCell
        case .flags: flagsCell
        }
    }

    private var priceCell: some View {
        let p = price ?? (row.last_close.isFinite ? row.last_close : nil)
        return Text(ScanFormat.priceFmt(p))
            .numeric(size: 10)
            .foregroundStyle(p != nil ? Theme.bone : Theme.dim)
            .frame(width: ScanCol.price, alignment: .trailing)
    }

    private var changeCell: some View {
        // sessionChangePct is already a PERCENT (×100) — use Fmt.signedPct like the
        // summary table, NOT ScanFormat.pct (which would ×100 a second time).
        Text(change.flatMap { $0.isFinite ? Fmt.signedPct($0) : nil } ?? "—")
            .numeric(size: 10)
            .foregroundStyle(change.flatMap { $0.isFinite ? Theme.pnlColor($0) : nil } ?? Theme.dim)
            .frame(width: ScanCol.change, alignment: .trailing)
    }

    private var sectorCell: some View {
        Text(row.sector ?? "—")
            .font(.system(size: 10))
            .foregroundStyle(row.sector == nil ? Theme.dim : Theme.bone)
            .lineLimit(1)
            .frame(width: ScanCol.sector, alignment: .leading)
    }

    private var marketCapCell: some View {
        let p = price ?? (row.last_close.isFinite ? row.last_close : nil)
        let cap: Double? = {
            guard let s = row.shares_outstanding, s.isFinite, s > 0,
                  let px = p, px > 0 else { return nil }
            let c = s * px
            return c.isFinite ? c : nil
        }()
        return rawCell(CompanyFormat.abbrevMoney(cap), present: cap != nil, width: ScanCol.mktcap)
    }

    private var shortFloatCell: some View {
        // Real FINRA short interest (bi-monthly, keyless) ÷ the derived float-share
        // estimate (float$ ÷ price), gated by the SAME honesty check the company
        // view uses. Renders "—" until scan rows also carry EDGAR float; never
        // fabricated. Once float reaches the rows this lights up with no change.
        let p = price ?? (row.last_close.isFinite ? row.last_close : nil)
        let fShares = CompanyStats.floatShares(floatUSD: row.public_float_usd, lastPrice: p)
        let fPct = CompanyStats.floatPct(floatShares: fShares, sharesOutstanding: row.shares_outstanding)
        let derivedOK = (fPct ?? 0) <= 1.02
        let pct = derivedOK
            ? CompanyStats.shortPctFloat(shortInterest: row.short_interest, floatShares: fShares)
            : nil
        // ≈ — the float denominator is the estimated float-share count, same
        // honesty marker the company view uses.
        return rawCell(pct != nil ? "≈" + CompanyFormat.pct(pct) : "—",
                       present: pct != nil, width: ScanCol.shortFloat)
    }

    /// News flag: an ember newspaper glyph when a headline landed this window.
    private var newsCell: some View {
        Image(systemName: "newspaper")
            .font(.system(size: 9))
            .foregroundStyle(headline != nil ? Theme.ember : Theme.dim.opacity(0.35))
            .frame(width: ScanCol.news, alignment: .leading)
            .help(headline ?? "no recent headline")
    }

    /// RSI with an ember oversold marker at ≤ 30 (the requested threshold cue).
    private var rsiCell: some View {
        HStack(spacing: 3) {
            Spacer(minLength: 0)
            if let rsi = row.rsi_14, rsi <= 30 {
                Circle().fill(Theme.ember).frame(width: 4, height: 4)
            }
            Text(ScanFormat.raw(row.rsi_14, decimals: 0))
                .numeric(size: 10)
                .foregroundStyle(row.rsi_14 != nil ? Theme.bone : Theme.dim)
        }
        .frame(width: ScanCol.rsi, alignment: .trailing)
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
}

// MARK: - Summary row (the calm default table)

/// One row of the six-column summary: symbol · price · session change ·
/// composite strength bar · plain-language setup · top flag. A single quiet
/// ellipsis action rides in on hover / selection.
private struct ScanSummaryRowView: View {
    let row: ScanRow
    let verdict: ScanVerdict
    let price: Double?
    let change: Double?
    let headline: String?
    let aiDisabled: Bool
    let selected: Bool
    let openChart: () -> Void
    let openCompany: () -> Void
    let openNews: () -> Void
    let explain: () -> Void
    @State private var hovering = false

    var body: some View {
        // Row-select tap is a SIBLING gesture, not an outer Button, so the
        // nested ScanRowActionsMenu actually opens (a Menu inside a Button is
        // dead on macOS).
        HStack(spacing: ScanSummaryCol.gap) {
            Text(row.symbol)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.bone)
                .lineLimit(1)
                .frame(width: ScanSummaryCol.symbol, alignment: .leading)
            Text(price.flatMap { $0.isFinite ? Fmt.price($0) : nil } ?? "—")
                .numeric(size: 11)
                .foregroundStyle(price.flatMap { $0.isFinite ? Theme.bone : nil } ?? Theme.dim)
                .lineLimit(1)
                .frame(width: ScanSummaryCol.price, alignment: .trailing)
            Text(change.flatMap { $0.isFinite ? Fmt.signedPct($0) : nil } ?? "—")
                .numeric(size: 11)
                .foregroundStyle(change.flatMap { $0.isFinite ? Theme.pnlColor($0) : nil } ?? Theme.dim)
                .lineLimit(1)
                .frame(width: ScanSummaryCol.change, alignment: .trailing)
            ScanCompositeCell(composite: row.composite)
                .frame(width: ScanSummaryCol.composite, alignment: .trailing)
            ScanVerdictLabel(verdict: verdict)
                .frame(width: ScanSummaryCol.setup, alignment: .leading)
            flagCell
            ScanRowActionsMenu(
                symbol: row.symbol, headline: headline, aiDisabled: aiDisabled,
                visible: hovering || selected,
                openChart: openChart, explain: explain,
                openCompany: openCompany, openNews: openNews
            )
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(hovering || selected ? Theme.panelHi : .clear)
        .deckRowRule()
        .onTapGesture(perform: openChart)
        .onHover { hovering = $0 }
        .animation(DeckMotion.ease(), value: hovering)
    }

    /// The single most relevant flag (with a quiet "+n" when more exist).
    private var flagCell: some View {
        HStack(spacing: 4) {
            if let flag = row.flags.first {
                ScanFlagChip(text: flag)
                if row.flags.count > 1 {
                    Text("+\(row.flags.count - 1)")
                        .font(.system(size: 8, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.dim)
                }
            }
            Spacer(minLength: 0)
        }
        // FLAG is the flexing column: it grows from its fixed floor to the
        // pane's leftover width, spanning the row left-to-right and pushing the
        // trailing action to the right edge. The header cell mirrors this.
        .frame(minWidth: ScanSummaryCol.flag, maxWidth: .infinity, alignment: .leading)
        .help(row.flags.isEmpty ? "no flags" : row.flags.joined(separator: " · "))
    }
}

// MARK: - Summary column layout (fixed widths keep header + rows aligned)

private enum ScanSummaryCol {
    static let symbol: CGFloat = 64
    static let price: CGFloat = 84
    static let change: CGFloat = 72
    static let composite: CGFloat = 104
    static let setup: CGFloat = 148
    static let flag: CGFloat = 150
    static let action: CGFloat = 24
    static let gap: CGFloat = 12

    static func width(_ column: ScanSummary.Column) -> CGFloat {
        switch column {
        case .symbol: symbol
        case .price: price
        case .change: change
        case .composite: composite
        case .setup: setup
        case .flag: flag
        }
    }
}

// MARK: - Filter row

/// One filter-builder row: field menu, op menu, numeric value field, remove.
private struct ScanFilterRowView: View {
    @Binding var filter: ScanFilter
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // Enable toggle: an active filter culls rows; a draft one doesn't.
            Button { filter.enabled.toggle() } label: {
                Image(systemName: filter.enabled ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11))
                    .foregroundStyle(filter.enabled ? Theme.ember : Theme.dim)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(enableHelp)
            Menu {
                ForEach(ScanFilter.fields, id: \.self) { column in
                    Button(column.title) { filter.column = column; filter.enabled = true }
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
                    Button(op.title) { filter.op = op; filter.enabled = true }
                }
            } label: {
                chipLabel(filter.op.title, width: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("operator")
            HStack(spacing: 3) {
                TextField("value", value: $filter.value, format: .number)
                    .onChange(of: filter.value) { _, _ in filter.enabled = true }
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
                // The unit, on screen. Without it the operator cannot tell that
                // "1m% >= 5" means +5% and not the raw 5.0 fraction (+500%),
                // which is exactly how this filter used to silently match nothing.
                if let unit = filter.column.filterUnit {
                    Text(unit)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
            }
            .help(unitHelp)
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
        // Dim a paused row (opacity keeps the enable toggle clickable). A row
        // restored from a screen saved on a keyless column is inert too, so it
        // reads as paused rather than looking like it is culling the board.
        .opacity(filter.enabled && filter.column.filterable ? 1 : 0.55)
    }

    /// Spells out the threshold's unit for the columns that have one, so the
    /// percent convention is discoverable and not just implied by the suffix.
    private var unitHelp: String {
        filter.column.filterUnit == nil
            ? "threshold"
            : "threshold in percent — the same unit the \(filter.column.title) column shows"
    }

    private var enableHelp: String {
        guard filter.column.filterable else {
            return "\(filter.column.title) has no numeric reading to screen on — "
                + "this row is ignored; pick another field"
        }
        return filter.enabled ? "filter active — click to pause" : "filter paused — click to apply"
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
