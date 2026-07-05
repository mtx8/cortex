// Foundry — the proving ground: strategy rules replayed over real stored
// history (fees included), a leaderboard of what actually worked, and
// Monte Carlo projections from measured trade stats. Statistics, not promises.

import SwiftUI

struct FoundryView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.line)
            if let report = model.simReport {
                let key = selectedKey ?? report.best
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        leaderboard(report, selected: key)
                        if let key {
                            let proj = report.projections.filter { $0.basis == key }
                            if !proj.isEmpty { projections(proj, basis: key) }
                            tradeLog(report, key: key)
                        }
                        Text(report.note)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.dim)
                            .padding(.horizontal, 12)
                    }
                    .padding(.vertical, 12)
                }
            } else {
                emptyState
            }
        }
        .background(Theme.ink)
    }

    private var header: some View {
        HStack(spacing: 12) {
            SectionLabel(text: "foundry")
            if let best = model.simReport?.best {
                Text("Best: \(best)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ember)
            }
            Spacer()
            if model.simRunning {
                ProgressView().controlSize(.small).tint(Theme.ember)
            }
            Button("Run Simulation") { model.runSimulation() }
                .buttonStyle(EmberButtonStyle())
                .disabled(model.simRunning || model.connection != .connected)
                .opacity(model.simRunning ? 0.5 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No simulation yet")
                .font(.system(size: 12)).foregroundStyle(Theme.dim)
            Text("Replays every strategy over stored market history and projects outcomes.")
                .font(.system(size: 10)).foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func leaderboard(_ report: SimReport, selected: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "leaderboard")
                .padding(.horizontal, 12)
            VStack(spacing: 0) {
                row(["strategy", "symbol", "tf", "trades", "win", "pf", "sharpe", "max dd", "expect", "equity x"],
                    header: true, highlight: false)
                Divider().overlay(Theme.line)
                ForEach(sorted(report.stats)) { s in
                    leaderRow(s, selected: selected)
                }
            }
            .panel()
            .padding(.horizontal, 12)
        }
    }

    private func leaderRow(_ s: StrategyStats, selected: String?) -> some View {
        let key = "\(s.strategy)/\(s.symbol)"
        var cells: [String] = [s.strategy, s.symbol, s.interval.label, "\(s.trades)"]
        cells.append(s.win_rate.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
        cells.append(s.profit_factor.map { String(format: "%.2f", $0) } ?? "—")
        cells.append(s.sharpe.map { String(format: "%.2f", $0) } ?? "—")
        cells.append(s.max_drawdown.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
        cells.append(s.expectancy.map { String(format: "%+.3f%%", $0 * 100) } ?? "—")
        cells.append(s.equity_multiple.map { String(format: "%.3f", $0) } ?? "—")
        let tint: Color? = s.expectancy.map { Theme.pnlColor($0) }
        return row(cells, header: false, highlight: selected == key, tint: tint)
            .contentShape(Rectangle())
            .onTapGesture { selectedKey = key }
    }

    private func sorted(_ stats: [StrategyStats]) -> [StrategyStats] {
        stats.sorted { ($0.expectancy ?? -.infinity) > ($1.expectancy ?? -.infinity) }
    }

    private func row(_ cells: [String], header: Bool, highlight: Bool, tint: Color? = nil) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, c in
                Text(header ? c.uppercased() : c)
                    .font(.system(size: header ? 9 : 10, weight: header ? .semibold : (i == 0 ? .medium : .regular)))
                    .monospacedDigit()
                    .foregroundStyle(header ? Theme.dim : (i == 8 ? (tint ?? Theme.bone) : Theme.bone))
                    .frame(maxWidth: .infinity, alignment: i < 2 ? .leading : .trailing)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(highlight ? Theme.panelHi : .clear)
    }

    private func projections(_ projections: [SimProjection], basis: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "projections — \(basis)")
                .padding(.horizontal, 12)
            HStack(spacing: 12) {
                ForEach(projections) { p in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(p.horizon_trades) trades ahead")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.bone)
                        band("p95", p.p95, Theme.up)
                        band("median", p.p50, Theme.bone)
                        band("p05", p.p05, Theme.down)
                        HStack {
                            Text("Risk of losing half")
                                .font(.system(size: 9)).foregroundStyle(Theme.dim)
                            Spacer()
                            Text(String(format: "%.1f%%", p.risk_of_ruin * 100))
                                .numeric(size: 10, weight: .semibold)
                                .foregroundStyle(p.risk_of_ruin > 0.05 ? Theme.down : Theme.dim)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel()
                }
            }
            .padding(.horizontal, 12)
        }
    }

    /// The auditable grain: each row is a replayed trade whose timestamps
    /// and prices exist in the stored market history shown on the chart.
    private func tradeLog(_ report: SimReport, key: String) -> some View {
        let trades = report.trades.filter { $0.key == key }.sorted { $0.entry_ts > $1.entry_ts }
        return VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "trade log \u{2014} \(key) (\(trades.count))")
                .padding(.horizontal, 12)
            if trades.isEmpty {
                Text("No closed trades in the sample")
                    .font(.system(size: 10)).foregroundStyle(Theme.dim)
                    .padding(.horizontal, 12)
            } else {
                VStack(spacing: 0) {
                    row(["side", "entry", "exit", "entry px", "exit px", "hold", "return"],
                        header: true, highlight: false)
                    Divider().overlay(Theme.line)
                    ForEach(trades.prefix(60)) { t in
                        HStack(spacing: 0) {
                            Text(t.side == .buy ? "Long" : "Short")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(t.side == .buy ? Theme.up : Theme.down)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Self.ts(t.entry_ts)).frame(maxWidth: .infinity, alignment: .trailing)
                            Text(Self.ts(t.exit_ts)).frame(maxWidth: .infinity, alignment: .trailing)
                            Text(Fmt.price(t.entry_px)).frame(maxWidth: .infinity, alignment: .trailing)
                            Text(Fmt.price(t.exit_px)).frame(maxWidth: .infinity, alignment: .trailing)
                            Text(Self.hold(t.exit_ts - t.entry_ts)).frame(maxWidth: .infinity, alignment: .trailing)
                            Text(String(format: "%+.2f%%", t.ret * 100))
                                .foregroundStyle(Theme.pnlColor(t.ret))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.bone)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                    if trades.count > 60 {
                        Text("showing newest 60 of \(trades.count)")
                            .font(.system(size: 9)).foregroundStyle(Theme.dim)
                            .padding(6)
                    }
                }
                .panel()
                .padding(.horizontal, 12)
            }
        }
    }

    private static func ts(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = DateFormatter()
        let cal = Calendar.current
        f.dateFormat = cal.isDateInToday(d) ? "HH:mm" : "dd MMM HH:mm"
        return f.string(from: d)
    }

    private static func hold(_ ms: Int64) -> String {
        let mins = ms / 60_000
        if mins < 60 { return "\(mins)m" }
        if mins < 48 * 60 { return "\(mins / 60)h" }
        return "\(mins / 1440)d"
    }

    private func band(_ label: String, _ multiple: Double, _ color: Color) -> some View {
        HStack {
            Text(label).font(.system(size: 9)).foregroundStyle(Theme.dim)
            Spacer()
            Text(String(format: "%.2fx", multiple))
                .numeric(size: 11, weight: .medium)
                .foregroundStyle(color)
        }
    }
}
