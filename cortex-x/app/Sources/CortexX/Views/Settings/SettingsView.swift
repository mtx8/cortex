// SETTINGS — a native-feeling macOS settings pane in flat-matte. A left mini-
// nav (BROKER · PREFERENCES) and a scrolling content column pinned top-left.
//
// BROKER is the reason this section exists: the current broker posture (from
// model.broker), a form to configure the paper simulator or the IBKR adapter,
// the LIVE hard-limits, and an ALLOW-LIVE opt-in that is OFF by default and
// demands an explicit real-money acknowledgement before it can be saved. All
// safety decisions live in the pure BrokerConfigCheck (SettingsSupport) so the
// "never arm live off anything but an explicit opt-in" rule is unit-tested.
// Applying pushes a set_broker_config command through model.applyBrokerConfig;
// the engine re-validates and re-publishes BrokerStatus, which this pane shows.
//
// PREFERENCES surfaces the real, wired app defaults — nothing decorative.

import SwiftUI

struct SettingsView: View {
    @State private var pane: SettingsPane = .broker

    var body: some View {
        HStack(spacing: 0) {
            nav
            Divider().overlay(Theme.line)
            ScrollView {
                Group {
                    switch pane {
                    case .broker: BrokerSettingsPane()
                    case .preferences: PreferencesPane()
                    }
                }
                .padding(24)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.ink)
    }

    private var nav: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SETTINGS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(2.5)
                .foregroundStyle(Theme.dim)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            ForEach(SettingsPane.allCases) { navRow($0) }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .frame(width: 180)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.ink)
    }

    private func navRow(_ p: SettingsPane) -> some View {
        let on = pane == p
        return Button { pane = p } label: {
            Text(p.title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(on ? Theme.ember : Theme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(on ? Theme.emberTint : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(DeckMotion.ease(), value: on)
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case broker, preferences
    var id: String { rawValue }
    var title: String {
        switch self {
        case .broker: "Broker"
        case .preferences: "Preferences"
        }
    }
}

// MARK: - BROKER pane

private struct BrokerSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var draft = BrokerSettings.default
    /// The "I understand — real money" acknowledgement. Reset every time the
    /// pane opens and whenever allow-live is turned off, so a live config can
    /// never be saved on a stale confirmation.
    @State private var liveConfirmed = false
    @State private var loaded = false

    private var gate: BrokerConfigGate {
        BrokerConfigCheck.gate(draft, confirmedLive: liveConfirmed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            statusCard
            modeCard
            if draft.mode == .ibkr {
                connectionCard
                limitsCard
                allowLiveCard
            } else {
                paperNote
            }
            applyRow
        }
        .onAppear {
            guard !loaded else { return }
            draft = model.brokerSettings
            liveConfirmed = false
            loaded = true
        }
        .onChange(of: draft.allowLive) { _, on in
            if !on { liveConfirmed = false }
        }
    }

    // MARK: Current status (the live engine posture, not the draft)

    private var statusCard: some View {
        let s = BrokerBadge.style(for: model.broker)
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "current")
            HStack(spacing: 8) {
                Text(s.text)
                    .font(.system(size: 14, weight: s.isLive ? .bold : .semibold))
                    .tracking(1.0)
                    .foregroundStyle(s.textColor)
                if s.showDot {
                    Circle().fill(s.dotColor).frame(width: 7, height: 7)
                }
                if let acct = model.broker?.account_masked, !acct.isEmpty {
                    Text(acct)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.dim)
                }
                Spacer(minLength: 0)
                connectionPill
            }
            Text(s.help)
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .strokeBorder(
                    s.isLive ? Theme.ember.opacity(0.55) : Color.clear,
                    lineWidth: Theme.hairline
                )
        )
    }

    private var connectionPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(model.connection == .connected ? Theme.up : Theme.dim)
                .frame(width: 6, height: 6)
            Text(model.connection.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(model.connection == .connected ? Theme.up : Theme.dim)
        }
    }

    // MARK: Mode

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "mode")
            HStack(spacing: 4) {
                DeckSegment(title: "PAPER", isOn: draft.mode == .paper) { setMode(.paper) }
                DeckSegment(title: "IBKR", isOn: draft.mode == .ibkr) { setMode(.ibkr) }
            }
            .padding(3)
            .background(Theme.ink)
            .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.chipRadius)
                    .strokeBorder(Theme.line, lineWidth: Theme.hairline)
            )
            .frame(maxWidth: 260)
        }
    }

    private var paperNote: some View {
        Text("The internal paper simulator — simulated fills, no broker connection, no real money. Choose IBKR to route to your own IB Gateway / TWS.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
    }

    // MARK: IBKR connection

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "ibkr connection")
            labeled("host") {
                TextField("127.0.0.1", text: $draft.ibkrHost)
                    .plainField()
            }
            labeled("port", note: BrokerLivePorts.note(for: draft.ibkrPort)) {
                HStack(spacing: 8) {
                    TextField("7497", value: $draft.ibkrPort, format: .number.grouping(.never))
                        .plainField()
                    Stepper("", value: $draft.ibkrPort, in: 1...65_535).labelsHidden()
                }
            }
            portPresets
            labeled("client id") {
                HStack(spacing: 8) {
                    TextField("11", value: $draft.ibkrClientId, format: .number.grouping(.never))
                        .plainField()
                    Stepper("", value: $draft.ibkrClientId, in: 0...999).labelsHidden()
                }
            }
            labeled("account", note: "optional · DU… paper / U… live — display only, never a password") {
                TextField("DU1234567", text: $draft.ibkrAccount)
                    .plainField()
            }
            labeled("route", note: "SMART, or a direct venue (ARCA · ISLAND · IEX · NYSE) for DMA") {
                TextField("SMART", text: $draft.ibkrRoute)
                    .plainField()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var portPresets: some View {
        HStack(spacing: 6) {
            ForEach([7497, 4002, 7496, 4001], id: \.self) { p in
                portChip(p)
            }
            Spacer(minLength: 0)
        }
    }

    private func portChip(_ p: Int) -> some View {
        let on = draft.ibkrPort == p
        let live = BrokerLivePorts.isLivePort(p)
        return Button { draft.ibkrPort = p } label: {
            Text("\(p)")
                .font(.system(size: 11, weight: on ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(on ? (live ? Theme.ember : Theme.bone) : Theme.dim)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(on ? Theme.panelHi : Theme.ink)
                .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.chipRadius)
                        .strokeBorder(Theme.line, lineWidth: Theme.hairline)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(BrokerLivePorts.note(for: p))
    }

    // MARK: LIVE hard limits

    private var limitsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "live hard limits")
            Text("The real-money backstop, on top of the risk engine. Each must be a positive number.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            moneyField("max order notional", $draft.maxLiveOrderNotional)
            moneyField("max position notional", $draft.maxLivePositionNotional)
            moneyField("max daily loss", $draft.maxLiveDailyLoss)
            if gate.invalidLimits {
                warnRow("each live limit must be a positive number — the engine rejects a zero, negative, or empty cap")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func moneyField(_ label: String, _ value: Binding<Double>) -> some View {
        labeled(label) {
            HStack(spacing: 6) {
                Text("$")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.dim)
                TextField("0", value: value, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.bone)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.ink)
            .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.chipRadius)
                    .strokeBorder(Theme.line, lineWidth: Theme.hairline)
            )
        }
    }

    // MARK: ALLOW LIVE (the real-money opt-in)

    private var allowLiveCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "real money")
            Toggle(isOn: $draft.allowLive) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ALLOW LIVE")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.bone)
                    Text("off keeps you paper-safe; on lets a live port reach a real account")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.dim)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.ember)

            // A live port with allow-live OFF is a config the engine refuses —
            // say so plainly rather than let it fail silently.
            if gate.refusedByEngine {
                warnRow("port \(draft.ibkrPort) is a LIVE (real-money) port — the engine will refuse this until ALLOW LIVE is on, or choose a paper port (7497 / 4002)")
            }

            // Arming allow-live demands an explicit acknowledgement before it
            // can be saved (see BrokerConfigCheck.needsLiveConfirm).
            if draft.allowLive {
                liveConfirmPanel
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .strokeBorder(
                    draft.allowLive ? Theme.ember.opacity(0.55) : Color.clear,
                    lineWidth: Theme.hairline
                )
        )
    }

    private var liveConfirmPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(Theme.ember).frame(width: 6, height: 6)
                Text("REAL MONEY")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.ember)
            }
            Text("Real money — orders execute at your broker. Live trading routes to your actual IBKR account.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.bone)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $liveConfirmed) {
                Text("I understand — arm real-money trading")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.bone)
            }
            .toggleStyle(.switch)
            .tint(Theme.ember)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ember.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(Theme.ember.opacity(0.45), lineWidth: Theme.hairline)
        )
    }

    // MARK: Apply

    private var applyRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button { model.applyBrokerConfig(draft) } label: {
                    Text("APPLY & CONNECT").tracking(0.6)
                }
                .buttonStyle(EmberButtonStyle())
                .disabled(!gate.canApply)
                .opacity(gate.canApply ? 1 : 0.5)

                if draft != model.brokerSettings {
                    Text("unsaved changes")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.dim)
                }
                Spacer(minLength: 0)
            }
            if gate.needsLiveConfirm {
                Text("acknowledge the real-money confirmation above to apply")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
            }
            if model.connection != .connected {
                Text("engine offline — reconnect to apply")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
            }
            Text("IBKR login happens in your IB Gateway / TWS — no password is stored here. See docs/IBKR.md.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Helpers

    private func setMode(_ m: BrokerConfigMode) {
        draft.mode = m
        // Paper never trades live — clear the arm so the gate stays honest and
        // the (now hidden) allow-live toggle can't silently block apply.
        if m == .paper {
            draft.allowLive = false
            liveConfirmed = false
        }
    }

    @ViewBuilder
    private func labeled(
        _ label: String, note: String? = nil, @ViewBuilder _ control: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.dim)
            control()
            if let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func warnRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(Theme.ember).frame(width: 5, height: 5).padding(.top, 4)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.bone)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - PREFERENCES pane

private struct PreferencesPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showWatchlist") private var showWatchlist = true
    @AppStorage("showIntelligence") private var showIntelligence = true
    @AppStorage("showDeck") private var showDeck = true
    @AppStorage("ticket.confirmBeforeLiveOrder") private var confirmBeforeLiveOrder = true

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            layoutCard
            ticketCard
        }
    }

    private var layoutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "layout")
            prefToggle("show watchlist", $showWatchlist)
            Divider().overlay(Theme.line)
            prefToggle("show intelligence", $showIntelligence)
            Divider().overlay(Theme.line)
            prefToggle("show bottom deck", $showDeck)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var ticketCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "order ticket")
            prefToggle(
                "confirm before every live order", $confirmBeforeLiveOrder,
                note: "a real-money backstop — a connected LIVE venue asks once before it fires"
            )
            Divider().overlay(Theme.line)
            // Read-only: the ticket's +/- size step, surfaced from the real
            // OrderSizing defaults so this pane never claims more than it does.
            readonlyRow(
                "share size increment",
                "\(DashFormat.qty(OrderSizing.equityIncrement)) sh",
                note: "the equity +/- step in the order ticket"
            )
            Divider().overlay(Theme.line)
            readonlyRow(
                "crypto size increment",
                "\(DashFormat.qty(OrderSizing.cryptoIncrement)) unit",
                note: "the crypto +/- step in the order ticket"
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func prefToggle(_ label: String, _ isOn: Binding<Bool>, note: String? = nil) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.bone)
                if let note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
        .tint(Theme.ember)
    }

    private func readonlyRow(_ label: String, _ value: String, note: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.bone)
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
            }
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.dim)
        }
    }
}

// MARK: - Field chrome

private extension View {
    /// Ink-inset plain text field matching the order ticket's field chrome.
    func plainField() -> some View {
        textFieldStyle(.plain)
            .font(.system(size: 13).monospacedDigit())
            .foregroundStyle(Theme.bone)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.ink)
            .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.chipRadius)
                    .strokeBorder(Theme.line, lineWidth: Theme.hairline)
            )
    }
}
