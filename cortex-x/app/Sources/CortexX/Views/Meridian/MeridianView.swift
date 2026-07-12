// MERIDIAN — the Dalio section: Five Forces gauges, fired causal chains,
// and the geopolitical signal feed. The lines that connect the world.
// forces | the machine | signal feed. Everything rendered traces to a feed.

import AppKit
import SwiftUI

// MARK: - Pure helpers (internal for tests)

/// '12s', '4m', '2h', '3d' — clamped at zero for clock skew.
/// Shared by the intel sections (REGIMES / MERIDIAN).
enum IntelTime {
    static func relative(_ tsMs: Int64, now: Date) -> String {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let secs = max(0, (nowMs - tsMs) / 1000)
        if secs < 60 { return "\(secs)s" }
        if secs < 3_600 { return "\(secs / 60)m" }
        if secs < 86_400 { return "\(secs / 3_600)h" }
        return "\(secs / 86_400)d"
    }
}

enum MeridianSupport {
    /// Preferred Dalio ordering: debt & money, internal order, external order,
    /// nature, technology. Unknown forces keep arrival order at the end —
    /// render whatever arrives, never drop a gauge.
    static func rank(_ force: String) -> Int {
        let f = force.lowercased()
        if f.contains("debt") || f.contains("money") { return 0 }
        if f.contains("internal") { return 1 }
        if f.contains("external") { return 2 }
        if f.contains("nature") || f.contains("natur") { return 3 }
        if f.contains("tech") { return 4 }
        return 5
    }

    static func orderedForces(_ forces: [ForceGauge]) -> [ForceGauge] {
        forces.enumerated()
            .sorted { a, b in
                let (ra, rb) = (rank(a.element.force), rank(b.element.force))
                return ra == rb ? a.offset < b.offset : ra < rb
            }
            .map(\.element)
    }
}

// MARK: - View

struct MeridianView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let pulse = model.geoPulse {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(spacing: 0) {
                        header(pulse, now: context.date)
                        Divider().overlay(Theme.line)
                        HStack(alignment: .top, spacing: 0) {
                            forcesPane(pulse)
                                .frame(width: 200)
                            Divider().overlay(Theme.line)
                            machinePane(pulse, now: context.date)
                                .frame(maxWidth: .infinity)
                            Divider().overlay(Theme.line)
                            feedPane(pulse, now: context.date)
                                .frame(width: 280)
                        }
                    }
                }
            } else {
                listeningState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
    }

    private var listeningState: some View {
        VStack(spacing: 8) {
            SectionLabel(text: "meridian")
            Text("listening to the world…")
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
            Text("forces, transmission chains, and the signal feed assemble on the first pulse")
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(_ pulse: GeoPulse, now: Date) -> some View {
        HStack(spacing: 10) {
            SectionLabel(text: "meridian")
            Text("connect the dots")
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
            Spacer()
            Text(pulse.source)
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
            Text(IntelTime.relative(pulse.ts_ms, now: now))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Forces

    private func forcesPane(_ pulse: GeoPulse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "five forces")
                .padding(.horizontal, 12)
                .padding(.top, 12)
            if pulse.forces.isEmpty {
                Text("no gauges yet")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 12)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(MeridianSupport.orderedForces(pulse.forces)) { gauge in
                            ForceGaugeRow(gauge: gauge)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: The machine

    private func machinePane(_ pulse: GeoPulse, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "the machine")
                .padding(.horizontal, 12)
                .padding(.top, 12)
            if pulse.chains.isEmpty {
                VStack(spacing: 6) {
                    Text("no elevated transmissions — the machine is quiet.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                    Text("MERIDIAN watches global theme intensity; a chain fires when a theme runs hot against its 30-day baseline.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(pulse.chains.sorted { $0.intensity > $1.intensity }) { chain in
                            CausalChainCard(chain: chain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Signal feed

    private func feedPane(_ pulse: GeoPulse, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "signal feed")
                .padding(.horizontal, 12)
                .padding(.top, 12)
            if pulse.events.isEmpty {
                Text("no signals in the buffer")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(pulse.events) { event in
                            GeoEventRow(event: event, now: now)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Force gauge

private struct ForceGaugeRow: View {
    let gauge: ForceGauge

    private var trend: (text: String, color: Color) {
        if gauge.trend_7d > 0 {
            return (String(format: "▲ %.1f", gauge.trend_7d), Theme.up)
        }
        if gauge.trend_7d < 0 {
            return (String(format: "▼ %.1f", abs(gauge.trend_7d)), Theme.down)
        }
        return ("—", Theme.dim)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(gauge.force.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(trend.text)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(trend.color)
            }
            Text(String(format: "%.0f", min(max(gauge.value, 0), 100)))
                .numeric(size: 15, weight: .medium)
                .foregroundStyle(Theme.bone)
            DeckGaugeBar(fraction: gauge.value / 100, color: Theme.ember)
            Text(gauge.proxy)
                .font(.system(size: 9))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
        }
    }
}

// MARK: - Causal chain card

private struct CausalChainCard: View {
    let chain: CausalChain
    @State private var showEvidence = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Text(chain.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.bone)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text(String(format: "z %.1f", chain.intensity))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.ember)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.emberTint)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
            }

            stepsChain

            if !chain.assets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chain.assets) { impact in
                            AssetImpactChip(impact: impact)
                        }
                    }
                }
            }

            if !chain.evidence.isEmpty {
                evidenceSection
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var stepsChain: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(chain.steps.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.ember.opacity(0.6))
                        .frame(width: 1, height: 10)
                        .padding(.leading, 14)
                }
                Text(step)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.bone)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Theme.panelHi)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.chipRadius)
                            .strokeBorder(Theme.line, lineWidth: Theme.hairline)
                    )
            }
        }
    }

    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(DeckMotion.ease()) { showEvidence.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.dim)
                        .rotationEffect(.degrees(showEvidence ? 90 : 0))
                    Text("evidence (\(min(chain.evidence.count, 3)))")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.dim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showEvidence {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(chain.evidence.prefix(3)) { event in
                        EvidenceLink(event: event)
                    }
                }
                .padding(.leading, 13)
            }
        }
    }
}

private struct EvidenceLink: View {
    let event: GeoEvent
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = URL(string: event.url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 11))
                    .foregroundStyle(hovering ? Theme.bone : Theme.dim)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(event.source_domain)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.dim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DeckMotion.ease(), value: hovering)
    }
}

private struct AssetImpactChip: View {
    let impact: AssetImpact

    private var arrow: (text: String, color: Color) {
        if impact.direction > 0 { return ("▲", Theme.up) }
        if impact.direction < 0 { return ("▼", Theme.down) }
        return ("—", Theme.dim)
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(impact.target)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.bone)
                .lineLimit(1)
            Text(arrow.text)
                .font(.system(size: 9))
                .foregroundStyle(arrow.color)
            if !impact.note.isEmpty {
                Text(impact.note)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(Theme.line, lineWidth: Theme.hairline)
        )
        .help(impact.note)
    }
}

// MARK: - Signal feed row

private struct GeoEventRow: View {
    let event: GeoEvent
    let now: Date
    @State private var hovering = false

    private var toneColor: Color {
        if event.tone > 0 { return Theme.up }
        if event.tone < 0 { return Theme.down }
        return Theme.dim
    }

    var body: some View {
        Button {
            if let url = URL(string: event.url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(event.theme)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.chipRadius)
                                .strokeBorder(Theme.line, lineWidth: Theme.hairline)
                        )
                    Text(String(format: "%+.1f", event.tone))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(toneColor)
                    Spacer(minLength: 4)
                    Text(IntelTime.relative(event.ts_ms, now: now))
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(Theme.dim)
                }
                Text(event.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.bone)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text(event.source_domain)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                    ForEach(event.countries.prefix(4), id: \.self) { country in
                        Text(country)
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.dim)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(Theme.line, lineWidth: Theme.hairline)
                            )
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(hovering ? Theme.panelHi : .clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DeckMotion.ease(), value: hovering)
    }
}
