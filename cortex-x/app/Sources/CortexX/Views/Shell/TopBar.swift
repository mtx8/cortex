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
            brokerBadge
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

    // Broker-link posture — the operator must always know whether real money
    // is at play. Calm for PAPER / IBKR PAPER; unmissable (ember chip + LIVE)
    // only when the engine says live AND the broker session is connected. All
    // the text/color decisions live in the pure `BrokerBadge` helper.
    private var brokerBadge: some View {
        let s = BrokerBadge.style(for: model.broker)
        return HStack(spacing: 6) {
            Circle()
                .fill(s.dotColor)
                .frame(width: 7, height: 7)
            Text(s.text)
                .font(.system(size: 10, weight: s.isLive ? .bold : .semibold))
                .tracking(1.2)
                .foregroundStyle(s.textColor)
        }
        .padding(.horizontal, s.isLive ? 10 : 0)
        .padding(.vertical, s.isLive ? 4 : 0)
        .background(s.isLive ? Theme.ember.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(
                    s.isLive ? Theme.ember.opacity(0.55) : Color.clear,
                    lineWidth: Theme.hairline
                )
        )
        .help(s.help)
        .accessibilityLabel("Broker \(s.text)")
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

/// Pure map from a broker posture to the TopBar badge's text + colors, kept
/// separate from the view so the paper / ibkr-paper / ibkr-live mapping is
/// unit-testable. The cardinal rule: `isLive` (and the word "LIVE") appears
/// only for an explicit `ibkr_live` mode that is also `connected` — anything
/// unknown, absent, or disconnected reads as a calmer, non-live posture.
enum BrokerBadge {
    struct Style: Equatable {
        var text: String
        var textColor: Color
        var dotColor: Color
        /// Real money is at play — drives the loud ember-chip emphasis.
        var isLive: Bool
        var help: String
    }

    static func style(for status: BrokerStatus?) -> Style {
        // No posture yet → the safe internal paper simulator.
        guard let status else { return paper }
        let acct = status.account_masked.map { " · \($0)" } ?? ""
        switch status.mode {
        case .paper:
            return paper
        case .ibkr_paper:
            return Style(
                text: "IBKR PAPER",
                textColor: Theme.ember,
                dotColor: status.connected ? Theme.up : Theme.dim,
                isLive: false,
                help: "IBKR paper account\(acct) — "
                    + (status.connected ? "connected" : "link down")
                    + ". Simulated fills, no real money."
            )
        case .ibkr_live:
            if status.connected {
                return Style(
                    text: "IBKR LIVE",
                    textColor: Theme.ember,
                    dotColor: Theme.ember,
                    isLive: true,
                    help: "IBKR LIVE account\(acct) — connected. "
                        + "REAL MONEY: orders execute at your broker."
                )
            }
            // Live is configured but the broker link is down: no real order can
            // flow, so never scream LIVE. Show a calm, honest IBKR badge.
            return Style(
                text: "IBKR",
                textColor: Theme.ember,
                dotColor: Theme.dim,
                isLive: false,
                help: "IBKR live account\(acct) configured — link DOWN. "
                    + "No orders can execute until the broker reconnects."
            )
        }
    }

    private static let paper = Style(
        text: "PAPER",
        textColor: Theme.dim,
        dotColor: Theme.dim,
        isLive: false,
        help: "Paper simulator — no broker linked. No real money."
    )
}
