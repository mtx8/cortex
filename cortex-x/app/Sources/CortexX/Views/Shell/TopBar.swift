// Top status bar: brand, account vitals, risk posture, connection.

import SwiftUI

struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 20) {
            brand
            Divider().frame(height: 16).overlay(Theme.line)
            vital("equity", Fmt.money(model.account.equity), Theme.bone)
            vital("day p&l", Fmt.signedMoney(model.account.realized_pnl_day + model.account.unrealized_pnl),
                  Theme.pnlColor(model.account.realized_pnl_day + model.account.unrealized_pnl))
            vital("exposure", Fmt.money(model.account.gross_exposure), Theme.bone)
            Spacer()
            if model.risk.kill_switch {
                HStack(spacing: 6) {
                    Circle().fill(Theme.down).frame(width: 7, height: 7)
                    Text("KILL SWITCH")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.down)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.down.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
                .help(model.risk.kill_reason ?? "engaged")
            }
            vital("autonomy", model.risk.autonomy.label, Theme.bone)
            if model.risk.caution > 0.01 {
                vital("caution", model.risk.caution.formatted(.number.precision(.fractionLength(2))), Theme.warn)
            }
            connection
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var brand: some View {
        HStack(spacing: 2) {
            Text("CORTEX")
                .font(.system(size: 13, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(Theme.bone)
            Text("X")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.ember)
        }
    }

    private func vital(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.dim)
            Text(value)
                .numeric(size: 12, weight: .medium)
                .foregroundStyle(color)
        }
    }

    private var connection: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.connection == .connected ? Theme.up : Theme.dim)
                .frame(width: 7, height: 7)
            Text(model.connection.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(model.connection == .connected ? Theme.up : Theme.dim)
        }
    }
}
