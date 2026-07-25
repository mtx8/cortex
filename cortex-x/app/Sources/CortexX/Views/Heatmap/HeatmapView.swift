// MARKET HEATMAP — the scan universe as sector-grouped tiles, colored by session
// change (money direction) or composite strength (ember). Reuses the scanner's
// board + the curated sector on each row + live session change; clicking a tile
// loads it on the chart. Flat-matte: green/red only for the money-direction
// change map, ember for the strength map — never both.

import SwiftUI

struct HeatmapView: View {
    @Environment(AppModel.self) private var model
    @State private var mode: HeatMode = .change
    /// One-slot memo for the sector grouping. `board.rows` only changes when the
    /// engine republishes the scan board (~5 min), but the body is invalidated at
    /// display rate by ticks, and re-grouping + re-sorting the whole universe on
    /// every one of those passes was pure waste. Plain reference type so mutating
    /// it inside a view update never schedules another update — same pattern as
    /// CandleChart's IndicatorCache.
    @State private var groupCache = HeatSectorCache()

    enum HeatMode: String, CaseIterable, Identifiable {
        case change, strength
        var id: String { rawValue }
        var title: String { self == .change ? "session %" : "strength" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.line)
            if let board = model.scanBoard, !board.rows.isEmpty {
                grid(board)
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
    }

    private var header: some View {
        HStack(spacing: 12) {
            SectionLabel(text: "market heatmap")
            Text("grouped by sector · click a tile to chart it")
                .font(.system(size: 10)).foregroundStyle(Theme.dim).lineLimit(1)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                ForEach(HeatMode.allCases) { m in
                    DeckSegment(title: m.title, isOn: mode == m) {
                        withAnimation(DeckMotion.ease()) { mode = m }
                    }
                    .fixedSize()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func grid(_ board: ScanBoard) -> some View {
        // Grouping + per-sector sorting are invariant between board publishes, so
        // they ride a memo keyed on the board identity instead of being rebuilt on
        // every tick-driven invalidation of this body.
        let groups = groupCache.groups(
            for: HeatSectorKey(ts: board.ts_ms, count: board.rows.count)
        ) { HeatmapView.sectorGroups(board.rows) }
        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(groups, id: \.sector) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            SectionLabel(text: group.sector)
                            Text("\(group.rows.count)").numeric(size: 10).foregroundStyle(Theme.dim)
                        }
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 100), spacing: 6)],
                            alignment: .leading, spacing: 6
                        ) {
                            ForEach(group.rows) { HeatTile(row: $0, mode: mode) }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    /// Group by curated sector; uncurated → "Other", pinned last. Rows sorted by
    /// symbol inside each sector. Pure + static so it can be memoized and tested.
    static func sectorGroups(_ rows: [ScanRow]) -> [HeatSectorGroup] {
        Dictionary(grouping: rows) { $0.sector ?? "Other" }
            .sorted { a, b in
                if a.key == "Other" { return false }
                if b.key == "Other" { return true }
                return a.key < b.key
            }
            .map { HeatSectorGroup(sector: $0.key, rows: $0.value.sorted { $0.symbol < $1.symbol }) }
    }

    /// Visual intensity (0...1) driving a tile's ember/green/red opacity.
    ///
    /// CHANGE is a SIGNED metric whose sign is carried by Theme.up / Theme.down,
    /// so only its magnitude drives opacity (capped at ±3%).
    ///
    /// STRENGTH has NO signed colour channel — it is ember-only — so it must be a
    /// monotonic ramp over the raw 0...100 composite. Centring on 50 and taking
    /// abs() (what this used to do) painted composite 10 exactly as brightly as
    /// composite 90: the weakest names in the universe glowed like the strongest,
    /// which inverts the encoding across the whole bottom half of the distribution.
    static func intensity(mode: HeatMode, metric: Double) -> Double {
        switch mode {
        case .change: return min(abs(metric) / 3.0, 1.0)
        case .strength: return min(max(metric, 0) / 100.0, 1.0)
        }
    }

    /// Tile background + value tone. CHANGE map = money-direction green/red at
    /// opacity scaled by magnitude; STRENGTH map = ember accent (composite is a
    /// percentile, NOT money direction) — never green/red.
    static func tileColor(mode: HeatMode, metric: Double?) -> (bg: Color, tone: Color) {
        guard let m = metric, m.isFinite else { return (Theme.panel, Theme.dim) }
        if mode == .change {
            // Exactly flat is not a direction: no tint, no green/red.
            guard m != 0 else { return (Theme.panel, Theme.dim) }
            let i = intensity(mode: .change, metric: m)
            let base = m > 0 ? Theme.up : Theme.down
            return (base.opacity(0.10 + 0.22 * i), base)
        }
        let i = intensity(mode: .strength, metric: m)
        return (Theme.ember.opacity(0.06 + 0.20 * i), Theme.ember)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("no scan universe yet")
                .font(.system(size: 12)).foregroundStyle(Theme.dim)
            Text("the heatmap fills from the scanner board")
                .font(.system(size: 10)).foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Tile (leaf)

/// One heatmap tile. It reads the live session change ITSELF, and only in the
/// CHANGE mode: if the parent body touched `lastTick`/`bars` the whole grid would
/// be invalidated at feed-flush rate (~12 Hz) — including in STRENGTH mode, where
/// nothing on screen can change until the next scan board arrives (~5 min).
private struct HeatTile: View {
    @Environment(AppModel.self) private var model
    let row: ScanRow
    let mode: HeatmapView.HeatMode

    var body: some View {
        let change = mode == .change ? model.sessionChangePct(row.symbol) : nil
        // STRENGTH feeds the RAW composite (0...100), never composite−50: the ember
        // ramp is unsigned, so a centred metric has no channel to carry its sign.
        let metric: Double? = mode == .change ? change : row.composite
        let colors = HeatmapView.tileColor(mode: mode, metric: metric)
        Button {
            model.selectSymbol(row.symbol)
            model.centerMode = .chart
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.symbol)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.bone)
                    .lineLimit(1)
                Text(mode == .change
                    ? (change.flatMap { $0.isFinite ? Fmt.signedPct($0) : nil } ?? "—")
                    : ScanFormat.score(row.composite))
                    .numeric(size: 10)
                    .foregroundStyle(colors.tone)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .topLeading)
            .padding(8)
            .background(colors.bg)
            .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(Theme.line, lineWidth: Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(row.symbol) — click to chart")
    }
}

// MARK: - Sector grouping memo

/// One sector's tiles, symbol-sorted.
struct HeatSectorGroup: Identifiable {
    var sector: String
    var rows: [ScanRow]
    var id: String { sector }
}

/// Identity of the board the grouping was computed from. The scan board is
/// replaced wholesale on each publish, so its timestamp + row count is enough to
/// turn the memo over exactly once per publish.
struct HeatSectorKey: Equatable {
    var ts: Int64
    var count: Int
}

/// One-slot memo for the sector grouping. A plain (non-observed) reference type so
/// mutating it inside a view update never schedules another update — the standard
/// SwiftUI memoization pattern, same as CandleChart's IndicatorCache.
final class HeatSectorCache {
    private var key: HeatSectorKey?
    private var cached: [HeatSectorGroup]?

    func groups(for key: HeatSectorKey, build: () -> [HeatSectorGroup]) -> [HeatSectorGroup] {
        if key == self.key, let cached { return cached }
        let fresh = build()
        self.key = key
        self.cached = fresh
        return fresh
    }
}
