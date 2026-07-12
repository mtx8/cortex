// REGIMES — market-wide bull/bear state board with breadth gauges.
// Five columns: entering bull · bull · correction · entering bear · bear
// (recovery rows live inside BEAR with an ember chip). Semantic color lives
// only in the numbers — no colored card fills (design law).

import SwiftUI

// MARK: - Pure helpers (internal for tests)

enum RegimeColumnKind: String, CaseIterable {
    case enteringBull, bull, correction, enteringBear, bear

    var title: String {
        switch self {
        case .enteringBull: "entering bull"
        case .bull: "bull"
        case .correction: "correction"
        case .enteringBear: "entering bear"
        case .bear: "bear"
        }
    }
}

enum RegimeBoardLayout {
    /// recovery rows render inside the BEAR column (with a recovery chip).
    static func column(for state: RegimeState) -> RegimeColumnKind {
        switch state {
        case .entering_bull: .enteringBull
        case .bull: .bull
        case .correction: .correction
        case .entering_bear: .enteringBear
        case .bear, .recovery: .bear
        }
    }

    /// Rows partitioned into board columns, each sorted by drawdown severity.
    static func partition(_ rows: [RegimeRow]) -> [RegimeColumnKind: [RegimeRow]] {
        var out: [RegimeColumnKind: [RegimeRow]] = [:]
        for row in rows {
            out[column(for: row.state), default: []].append(row)
        }
        for key in out.keys {
            out[key]?.sort { abs($0.drawdown_pct) > abs($1.drawdown_pct) }
        }
        return out
    }

    /// Bull-side states lead with run-up; bear-side states lead with drawdown.
    static func showsRunup(_ state: RegimeState) -> Bool {
        switch state {
        case .bull, .entering_bull, .recovery: true
        case .correction, .entering_bear, .bear: false
        }
    }

    /// Breadth percentages may arrive as 0..1 fractions or 0..100 percents;
    /// normalize to a 0..1 gauge fraction without inventing data.
    static func gaugeFraction(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        let fraction = value > 1 ? value / 100 : value
        return min(fraction, 1)
    }
}

// MARK: - View

struct RegimesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let board = model.regimeBoard, !board.rows.isEmpty {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 0) {
                        breadthStrip(board, now: context.date)
                        Divider().overlay(Theme.line)
                        boardColumns(board)
                    }
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            SectionLabel(text: "regimes")
            Text("scanning the universe…")
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
            Text("the first scan needs daily history backfill — the board fills as bars land")
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Breadth strip

    private func breadthStrip(_ board: RegimeBoard, now: Date) -> some View {
        HStack(alignment: .top, spacing: 10) {
            breadthGauge("% above 200d", board.breadth.pct_above_200d)
            breadthGauge("% above 50d", board.breadth.pct_above_50d)
            countsCard(board.breadth)
            sourceCard(board, now: now)
        }
        .padding(12)
    }

    private func breadthGauge(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
            if let fraction = RegimeBoardLayout.gaugeFraction(value) {
                Text(String(format: "%.0f%%", fraction * 100))
                    .numeric(size: 15, weight: .medium)
                    .foregroundStyle(Theme.bone)
                DeckGaugeBar(fraction: fraction, color: Theme.ember)
            } else {
                Text("—")
                    .numeric(size: 15)
                    .foregroundStyle(Theme.dim)
                DeckGaugeBar(fraction: 0, color: Theme.ember)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func countsCard(_ breadth: Breadth) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("COUNTS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(Theme.dim)
            HStack(spacing: 14) {
                countCell("bulls", breadth.bulls)
                countCell("bears", breadth.bears)
                countCell("ent. bull", breadth.entering_bull)
                countCell("ent. bear", breadth.entering_bear)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func countCell(_ label: String, _ count: UInt32) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)")
                .numeric(size: 14, weight: .medium)
                .foregroundStyle(Theme.bone)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
        }
    }

    private func sourceCard(_ board: RegimeBoard, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("UNIVERSE")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(Theme.dim)
            Text("\(board.breadth.universe_size)")
                .numeric(size: 14, weight: .medium)
                .foregroundStyle(Theme.bone)
            Text("\(board.source) · \(IntelTime.relative(board.ts_ms, now: now))")
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    // MARK: Board

    private func boardColumns(_ board: RegimeBoard) -> some View {
        let partitioned = RegimeBoardLayout.partition(board.rows)
        return HStack(alignment: .top, spacing: 10) {
            ForEach(RegimeColumnKind.allCases, id: \.self) { column in
                boardColumn(column, rows: partitioned[column] ?? [])
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
    }

    private func boardColumn(_ column: RegimeColumnKind, rows: [RegimeRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SectionLabel(text: column.title)
                Text("\(rows.count)")
                    .numeric(size: 10)
                    .foregroundStyle(Theme.dim)
            }
            if rows.isEmpty {
                Text("none")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
                    .padding(.top, 2)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(rows) { row in
                            RegimeRowCard(
                                row: row,
                                openChart: {
                                    model.selectedSymbol = row.symbol
                                    model.centerMode = .chart
                                },
                                openCompany: {
                                    model.openCompany(row.symbol)
                                }
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Row card

private struct RegimeRowCard: View {
    let row: RegimeRow
    let openChart: () -> Void
    let openCompany: () -> Void
    @State private var hovering = false

    private var leadMetric: (text: String, color: Color) {
        if RegimeBoardLayout.showsRunup(row.state) {
            return (String(format: "%+.1f%%", abs(row.runup_pct)), Theme.up)
        }
        return (String(format: "%.1f%%", -abs(row.drawdown_pct)), Theme.down)
    }

    private var factsLine: String {
        var parts = ["\(row.days_in_state)d in state"]
        if let dist = row.dist_50_200_pct, dist.isFinite {
            parts.append(String(format: "50/200 %+.1f%%", dist))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: openChart) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.symbol)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.bone)
                        .lineLimit(1)
                    if row.state == .recovery {
                        DeckChip(text: "recovery", color: Theme.ember)
                    }
                    Spacer(minLength: 4)
                    Text(leadMetric.text)
                        .numeric(size: 12, weight: .medium)
                        .foregroundStyle(leadMetric.color)
                }
                HStack(spacing: 6) {
                    Text(factsLine)
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                    Spacer(minLength: 0)
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
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .panel(highlighted: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DeckMotion.ease(), value: hovering)
    }
}
