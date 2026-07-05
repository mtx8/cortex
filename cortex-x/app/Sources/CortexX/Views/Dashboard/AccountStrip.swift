// Account strip: equity, day p&l, unrealized, cash, fees, gross exposure,
// trade count, and the two drawdown gauges (day vs 3%, total vs 10%).

import SwiftUI

struct AccountStrip: View {
    @Environment(AppModel.self) private var model

    /// Risk limits the drawdown bars fill against (fractions of equity).
    private static let dayLimit = 0.03
    private static let totalLimit = 0.10

    var body: some View {
        let a = model.account
        HStack(alignment: .center, spacing: 16) {
            DeckMetric(
                label: "equity",
                value: DashFormat.money(a.equity),
                size: 17, weight: .semibold
            )
            DeckMetric(
                label: "day p&l",
                value: DashFormat.money(a.realized_pnl_day, signed: true),
                color: Theme.pnlColor(a.realized_pnl_day)
            )
            DeckMetric(
                label: "unrealized",
                value: DashFormat.money(a.unrealized_pnl, signed: true),
                color: Theme.pnlColor(a.unrealized_pnl)
            )
            DeckMetric(label: "cash", value: DashFormat.money(a.cash))
            DeckMetric(label: "fees", value: DashFormat.money(a.fees_paid))
            DeckMetric(label: "gross", value: DashFormat.money(a.gross_exposure))
            DeckMetric(label: "trades", value: "\(a.daily_trades)")
            Spacer(minLength: 12)
            DeckDrawdownBar(label: "dd day", value: a.drawdown_day, limit: Self.dayLimit)
            DeckDrawdownBar(label: "dd total", value: a.drawdown_total, limit: Self.totalLimit)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .panel()
    }
}

/// Terse dim label over a mono value.
struct DeckMetric: View {
    let label: String
    let value: String
    var color: Color = Theme.bone
    var size: CGFloat = 12
    var weight: Font.Weight = .medium

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
            Text(value)
                .numeric(size: size, weight: weight)
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}

/// 4px drawdown gauge that shifts bone -> warn -> down as it approaches the limit.
struct DeckDrawdownBar: View {
    let label: String
    let value: Double
    let limit: Double

    private var fraction: Double {
        guard value.isFinite, limit > 0 else { return 0 }
        return min(max(value / limit, 0), 1)
    }

    private var color: Color {
        if fraction >= 0.85 { return Theme.down }
        if fraction >= 0.5 { return Theme.warn }
        return Theme.bone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(DashFormat.pct(value))
                    .numeric(size: 9)
                    .foregroundStyle(Theme.dim)
            }
            DeckGaugeBar(fraction: fraction, color: color)
        }
        .frame(width: 96)
        .help("\(label): \(DashFormat.pct(value)) of \(DashFormat.pct(limit)) limit")
    }
}
