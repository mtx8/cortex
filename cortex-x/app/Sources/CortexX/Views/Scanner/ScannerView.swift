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
enum ScanPreset: String, CaseIterable {
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

/// Table columns in display order.
enum ScanColumn: String, CaseIterable {
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
struct ScanSort: Equatable {
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
    static let company: CGFloat = 18
    static let gap: CGFloat = 8

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

    /// Total content width: columns + gaps + trailing company affordance.
    static var minWidth: CGFloat {
        let cols = ScanColumn.allCases.map(width).reduce(0, +)
        return cols + gap * CGFloat(ScanColumn.allCases.count) + company + 24
    }
}

// MARK: - View

struct ScannerView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var preset: ScanPreset = .all
    @State private var sort: ScanSort?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.line)
            presetRow
            Divider().overlay(Theme.line)
            if let board = model.scanBoard, !board.rows.isEmpty {
                table(board)
            } else {
                emptyState
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
            }
            Spacer()
            searchField
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                        ForEach(rows) { row in
                            ScanRowView(
                                row: row,
                                openChart: {
                                    model.selectSymbol(row.symbol)
                                    model.centerMode = .chart
                                },
                                openCompany: {
                                    model.openCompany(row.symbol)
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
            Spacer(minLength: ScanCol.company)
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
    let openChart: () -> Void
    let openCompany: () -> Void
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
                Text(flag)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.ember)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.chipRadius)
                            .strokeBorder(Theme.ember.opacity(0.45), lineWidth: Theme.hairline)
                    )
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
