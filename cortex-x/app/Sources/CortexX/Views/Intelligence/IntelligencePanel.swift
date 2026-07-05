// IntelligencePanel — the right rail: the machine mind made visible.
// copilot thread | agent feed | signals | macro strip. See docs/DESIGN.md.
// One file on purpose: the shared formatting helpers stay file-private.

import SwiftUI

// MARK: - Panel

struct IntelligencePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let macroHeight: CGFloat = 64
            let flexible = max(geo.size.height - macroHeight, 0)
            VStack(spacing: 0) {
                CopilotSection()
                    .frame(height: flexible * 0.5)
                Divider().overlay(Theme.line)
                AgentFeedSection()
                    .frame(height: flexible / 3)
                Divider().overlay(Theme.line)
                SignalsSection()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(Theme.line)
                MacroStrip()
                    .frame(height: macroHeight)
            }
        }
        .frame(width: 340)
        .background(Theme.ink)
    }
}

// MARK: - Copilot

private struct CopilotSection: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private static let suggestions = [
        "market read?",
        "why did risk tighten?",
        "what are the agents seeing?",
    ]

    private var sendDisabled: Bool {
        model.pendingAsk != nil || model.connection != .connected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "copilot")
                .padding(.horizontal, 12)
                .padding(.top, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.copilot.isEmpty {
                            suggestionChips
                        } else {
                            ForEach(model.copilot) { message in
                                CopilotBubble(message: message)
                                    .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.copilot) {
                    guard let last = model.copilot.last else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            inputRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var suggestionChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.suggestions, id: \.self) { suggestion in
                Button {
                    model.askCopilot(suggestion)
                } label: {
                    Text(suggestion)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.bone)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.chipRadius)
                                .strokeBorder(Theme.line, lineWidth: Theme.hairline)
                        )
                }
                .buttonStyle(.plain)
                .disabled(sendDisabled)
                .opacity(sendDisabled ? 0.4 : 1)
            }
        }
        .padding(.top, 4)
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("ask cortex", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.bone)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .strokeBorder(
                            inputFocused ? Theme.emberDown : Theme.line,
                            lineWidth: Theme.hairline
                        )
                )
                .focused($inputFocused)
                .onSubmit(submit)

            Button("send", action: submit)
                .buttonStyle(EmberButtonStyle())
                .disabled(sendDisabled)
                .opacity(sendDisabled ? 0.35 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func submit() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !sendDisabled else { return }
        model.askCopilot(question)
        draft = ""
    }
}

private struct CopilotBubble: View {
    let message: CopilotMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.bone)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Theme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cornerRadius)
                            .strokeBorder(Theme.line, lineWidth: Theme.hairline)
                    )
            }
        case .cortex:
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    if message.pending {
                        PendingDots()
                    } else {
                        Text(message.text)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.bone)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if let model = message.model {
                        Text(model)
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.dim)
                    }
                }
                .padding(.leading, 10)
                .padding(.vertical, 2)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Theme.ember)
                        .frame(width: 2)
                }
                Spacer(minLength: 24)
            }
        }
    }
}

private struct PendingDots: View {
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Theme.dim)
                    .frame(width: 4, height: 4)
                    .opacity(pulsing ? 1 : 0.25)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.16),
                        value: pulsing
                    )
            }
        }
        .padding(.vertical, 5)
        .onAppear { pulsing = true }
    }
}

// MARK: - Agent feed

private struct AgentFeedSection: View {
    @Environment(AppModel.self) private var model
    @State private var squadronFilter: String?

    private var squadrons: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for thought in model.thoughts where seen.insert(thought.squadron).inserted {
            out.append(thought.squadron)
        }
        return out.sorted()
    }

    private var visible: [AgentThought] {
        let base: [AgentThought]
        if let squadronFilter {
            base = model.thoughts.filter { $0.squadron == squadronFilter }
        } else {
            base = model.thoughts
        }
        return Array(base.prefix(60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "agent feed")
                .padding(.horizontal, 12)
                .padding(.top, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    FilterChip(label: "all", active: squadronFilter == nil) {
                        squadronFilter = nil
                    }
                    ForEach(squadrons, id: \.self) { squadron in
                        FilterChip(label: squadron, active: squadronFilter == squadron) {
                            squadronFilter = squadronFilter == squadron ? nil : squadron
                        }
                    }
                }
                .padding(.horizontal, 12)
            }

            if visible.isEmpty {
                Text("no agent activity")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(visible) { thought in
                                ThoughtRow(thought: thought, now: context.date)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ThoughtRow: View {
    let thought: AgentThought
    let now: Date
    @State private var hovering = false

    private var edgeColor: Color {
        switch thought.severity {
        case .info: Theme.line
        case .insight: Theme.ember
        case .warning: Theme.warn
        case .critical: Theme.down
        }
    }

    private var rowBackground: Color {
        if thought.severity == .critical {
            return Theme.down.opacity(hovering ? 0.10 : 0.06)
        }
        return hovering ? Theme.panelHi : .clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(thought.agent)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.bone)
                    .lineLimit(1)
                Text(thought.squadron)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(relativeTime(thought.ts_ms, now: now))
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(Theme.dim)
            }
            Text(thought.text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.bone)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            ConfidenceBar(value: thought.confidence)
                .padding(.top, 1)
        }
        .padding(.vertical, 6)
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(edgeColor)
                .frame(width: 3)
                .padding(.vertical, 6)
        }
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct ConfidenceBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule()
                    .fill(Theme.ember)
                    .frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 2)
    }
}

private struct FilterChip: View {
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.ember : Theme.dim)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(active ? Theme.emberTint : Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.chipRadius)
                        .strokeBorder(
                            active ? Theme.ember.opacity(0.4) : Theme.line,
                            lineWidth: Theme.hairline
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Signals

private struct SignalsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "signals")
                .padding(.horizontal, 12)
                .padding(.top, 10)

            if model.signals.isEmpty {
                Text("no signals")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(model.signals.prefix(30))) { signal in
                                SignalRow(signal: signal, now: context.date)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SignalRow: View {
    let signal: StrategySignal
    let now: Date
    @State private var hovering = false

    private var directionColor: Color {
        if signal.direction > 0 { return Theme.up }
        if signal.direction < 0 { return Theme.down }
        return Theme.dim
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(signal.strategy)
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
            Text(signal.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.bone)
                .lineLimit(1)
            Image(systemName: signal.direction < 0
                ? "arrowtriangle.down.fill"
                : "arrowtriangle.up.fill")
                .font(.system(size: 7))
                .foregroundStyle(directionColor)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule()
                    .fill(Theme.ember)
                    .frame(width: 24 * min(max(signal.conviction, 0), 1))
            }
            .frame(width: 24, height: 3)
            Spacer(minLength: 4)
            Text(relativeTime(signal.ts_ms, now: now))
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(hovering ? Theme.panelHi : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .help(signal.rationale)
    }
}

// MARK: - Macro strip

private struct MacroStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "macro")
            if let macro = model.macro {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        SpreadChip(label: "2s10s", bps: macro.spread_2s10s_bps)
                        SpreadChip(label: "3m10s", bps: macro.spread_3m10s_bps)
                        MacroChip {
                            Text(macro.curve_regime.lowercased())
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.bone)
                        }
                        ForEach(fxPairs(macro), id: \.0) { pair in
                            MacroChip {
                                Text(pair.0)
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.dim)
                                Text(adaptivePrice(pair.1))
                                    .numeric(size: 10)
                                    .foregroundStyle(Theme.dim)
                            }
                        }
                    }
                }
            } else {
                Text("awaiting macro data")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SpreadChip: View {
    let label: String
    let bps: Double?

    var body: some View {
        MacroChip {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Theme.dim)
            if let bps {
                Text(String(format: "%+.1f", bps))
                    .numeric(size: 11, weight: .medium)
                    .foregroundStyle(bps < 0 ? Theme.down : Theme.bone)
            } else {
                Text("--")
                    .numeric(size: 11)
                    .foregroundStyle(Theme.dim)
            }
        }
    }
}

private struct MacroChip<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 5) {
            content
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(Theme.line, lineWidth: Theme.hairline)
        )
    }
}

// MARK: - Shared helpers (file-private: the panel owns its formatting)

/// '12s', '4m', '2h', '3d' — clamped at zero for clock skew.
private func relativeTime(_ tsMs: Int64, now: Date) -> String {
    let nowMs = Int64(now.timeIntervalSince1970 * 1000)
    let secs = max(0, (nowMs - tsMs) / 1000)
    if secs < 60 { return "\(secs)s" }
    if secs < 3_600 { return "\(secs / 60)m" }
    if secs < 86_400 { return "\(secs / 3_600)h" }
    return "\(secs / 86_400)d"
}

/// Adaptive price format: >= 100 -> 2dp; >= 1 -> 4dp; < 1 -> 4 significant digits.
private func adaptivePrice(_ value: Double) -> String {
    let magnitude = abs(value)
    if magnitude >= 100 { return String(format: "%.2f", value) }
    if magnitude >= 1 { return String(format: "%.4f", value) }
    if magnitude > 0 {
        let leadingZeros = -Int(floor(log10(magnitude)))
        return String(format: "%.\(min(leadingZeros + 3, 8))f", value)
    }
    return "0.00"
}

/// Preferred majors first, then alphabetical; capped at 3 for the strip.
private func fxPairs(_ macro: MacroSnapshot) -> [(String, Double)] {
    let preferred = ["EURUSD", "USDJPY", "GBPUSD"]
    var out: [(String, Double)] = []
    for key in preferred {
        if let value = macro.fx[key] { out.append((key, value)) }
    }
    for key in macro.fx.keys.sorted() where !preferred.contains(key) {
        if let value = macro.fx[key] { out.append((key, value)) }
    }
    return Array(out.prefix(3))
}
