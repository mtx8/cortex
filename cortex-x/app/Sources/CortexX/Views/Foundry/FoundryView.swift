// Foundry — the proving ground: strategy rules replayed over real stored
// history (fees included), a leaderboard of what actually worked, and
// Monte Carlo projections from measured trade stats. Statistics, not promises.

import SwiftUI

struct FoundryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.line)
            if let report = model.simReport {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        leaderboard(report)
                        if !report.projections.isEmpty {
                            projections(report)
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

    private func leaderboard(_ report: SimReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "leaderboard")
                .padding(.horizontal, 12)
            VStack(spacing: 0) {
                row(["strategy", "symbol", "tf", "trades", "win", "pf", "sharpe", "max dd", "expect", "equity x"],
                    header: true, highlight: false)
                Divider().overlay(Theme.line)
                ForEach(sorted(report.stats)) { s in
                    row([
                        s.strategy, s.symbol, s.interval.label, "\(s.trades)",
                        s.win_rate.map { Fmt.signedPct($0 * 100).replacingOccurrences(of: "+", with: "") } ?? "—",
                        s.profit_factor.map { String(format: "%.2f", $0) } ?? "—",
                        s.sharpe.map { String(format: "%.2f", $0) } ?? "—",
                        s.max_drawdown.map { String(format: "%.1f%%", $0 * 100) } ?? "—",
                        s.expectancy.map { String(format: "%+.3f%%", $0 * 100) } ?? "—",
                        s.equity_multiple.map { String(format: "%.3f", $0) } ?? "—",
                    ], header: false, highlight: report.best == "\(s.strategy)/\(s.symbol)",
                       tint: s.expectancy.map { Theme.pnlColor($0) })
                }
            }
            .panel()
            .padding(.horizontal, 12)
        }
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

    private func projections(_ report: SimReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "projections — \(report.projections.first?.basis ?? "")")
                .padding(.horizontal, 12)
            HStack(spacing: 12) {
                ForEach(report.projections) { p in
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
