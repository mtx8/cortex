// MARKET HEATMAP — the scan universe as sector-grouped tiles, colored by session
// change (money direction) or composite strength (ember). Reuses the scanner's
// board + the curated sector on each row + live session change; clicking a tile
// loads it on the chart. Flat-matte: green/red only for the money-direction
// change map, ember for the strength map — never both.

import SwiftUI

struct HeatmapView: View {
    @Environment(AppModel.self) private var model
    @State private var mode: HeatMode = .change

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
                grid(board.rows)
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

    private func grid(_ rows: [ScanRow]) -> some View {
        // Group by curated sector; uncurated → "Other", pinned last.
        let groups = Dictionary(grouping: rows) { $0.sector ?? "Other" }
            .sorted { a, b in
                if a.key == "Other" { return false }
                if b.key == "Other" { return true }
                return a.key < b.key
            }
        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(groups, id: \.key) { sector, secRows in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            SectionLabel(text: sector)
                            Text("\(secRows.count)").numeric(size: 10).foregroundStyle(Theme.dim)
                        }
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 100), spacing: 6)],
                            alignment: .leading, spacing: 6
                        ) {
                            ForEach(secRows.sorted { $0.symbol < $1.symbol }) { tile($0) }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func tile(_ row: ScanRow) -> some View {
        let change = model.sessionChangePct(row.symbol)
        let metric: Double? = mode == .change ? change : (row.composite - 50)
        let colors = tileColor(metric)
        return Button {
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

    /// Tile background + value tone. CHANGE map = money-direction green/red at
    /// opacity scaled by magnitude (capped ~3%); STRENGTH map = ember accent
    /// (composite is a percentile, NOT money direction) — never green/red.
    private func tileColor(_ metric: Double?) -> (bg: Color, tone: Color) {
        guard let m = metric, m.isFinite, m != 0 else { return (Theme.panel, Theme.dim) }
        let cap = mode == .change ? 3.0 : 40.0
        let intensity = min(abs(m) / cap, 1.0)
        if mode == .change {
            let base = m > 0 ? Theme.up : Theme.down
            return (base.opacity(0.10 + 0.22 * intensity), base)
        }
        return (Theme.ember.opacity(0.06 + 0.20 * intensity), Theme.ember)
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
