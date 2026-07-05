// Risk HUD: kill switch (dominant), autonomy segments, caution and throttle
// gauges, active breaches, and a two-step flatten-all.

import SwiftUI

struct RiskHUD: View {
    @Environment(AppModel.self) private var model
    @State private var flattenArmed = false

    var body: some View {
        let risk = model.risk
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "risk")
            killControl(risk)
            autonomyControl(risk)
            cautionRow(risk)
            throttleRow(risk)
            if !risk.breaches.isEmpty {
                breachList(risk)
            }
            flattenControl
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    // MARK: Kill switch

    @ViewBuilder
    private func killControl(_ risk: RiskStatus) -> some View {
        if risk.kill_switch {
            VStack(alignment: .leading, spacing: 6) {
                Text("KILL SWITCH ENGAGED")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Theme.down)
                if let reason = risk.kill_reason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.down.opacity(0.85))
                        .lineLimit(2)
                }
                Button("Disengage") {
                    model.send(.setKillSwitch(engaged: false, reason: "operator reset"))
                }
                .buttonStyle(DeckMiniButtonStyle())
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.down.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(Theme.down.opacity(0.5), lineWidth: Theme.hairline)
            )
        } else {
            Button {
                model.send(.setKillSwitch(engaged: true, reason: "operator kill"))
            } label: {
                Text("Engage Kill Switch")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DeckTintedButtonStyle(tint: Theme.down, border: Theme.line))
        }
    }

    // MARK: Autonomy

    private func autonomyControl(_ risk: RiskStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("autonomy")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.dim)
            HStack(spacing: 4) {
                ForEach(AutonomyLevel.allCases) { level in
                    DeckSegment(title: shortLabel(level), isOn: risk.autonomy == level) {
                        if risk.autonomy != level {
                            model.send(.setAutonomy(level: level))
                        }
                    }
                }
            }
        }
    }

    private func shortLabel(_ level: AutonomyLevel) -> String {
        switch level {
        case .manual: "Manual"
        case .suggest_only: "Suggest"
        case .semi_auto: "Semi"
        case .full_auto: "Full"
        }
    }

    // MARK: Gauges

    private func cautionRow(_ risk: RiskStatus) -> some View {
        let caution = risk.caution.isFinite ? min(max(risk.caution, 0), 1) : 0
        return HStack(spacing: 8) {
            Text("caution")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.dim)
                .frame(width: 48, alignment: .leading)
            DeckGaugeBar(
                fraction: caution,
                style: AnyShapeStyle(LinearGradient(
                    colors: [Theme.ember, Theme.down],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
            )
            Text(String(format: "%.2f", caution))
                .numeric(size: 10)
                .foregroundStyle(Theme.dim)
                .frame(width: 34, alignment: .trailing)
        }
        .help(risk.caution_reasons.isEmpty
            ? "no caution flags"
            : risk.caution_reasons.joined(separator: "\n"))
    }

    private func throttleRow(_ risk: RiskStatus) -> some View {
        let throttle = risk.throttle.isFinite ? min(max(risk.throttle, 0), 1) : 1
        return HStack(spacing: 8) {
            Text("throttle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.dim)
                .frame(width: 48, alignment: .leading)
            DeckGaugeBar(fraction: 1 - throttle, color: Theme.warn)
            Text(String(format: "%.2f", throttle))
                .numeric(size: 10)
                .foregroundStyle(Theme.dim)
                .frame(width: 34, alignment: .trailing)
        }
        .help("size throttle — the bar fills as risk shrinks orders")
    }

    // MARK: Breaches

    private func breachList(_ risk: RiskStatus) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("breaches")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.dim)
            ForEach(risk.breaches, id: \.self) { breach in
                Text(breach)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.down)
                    .lineLimit(2)
            }
        }
    }

    // MARK: Flatten all (two-step confirm)

    private var flattenControl: some View {
        Button {
            if flattenArmed {
                model.send(.flattenAll(reason: "operator flatten"))
                flattenArmed = false
            } else {
                flattenArmed = true
            }
        } label: {
            Text(flattenArmed ? "Confirm Flatten" : "Flatten All")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(DeckTintedButtonStyle(
            tint: flattenArmed ? Theme.down : Theme.bone,
            border: Theme.line
        ))
        .task(id: flattenArmed) {
            // Arm window: auto-disarm after 3s without the confirming click.
            guard flattenArmed else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            flattenArmed = false
        }
    }
}
