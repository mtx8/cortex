// FLOW — the AI order-flow read that sits beside the Level 2 montage. A calm,
// honest panel: a headline PRESSURE verdict (BUYERS / SELLERS / balanced, with
// a small up/down money-direction cue only), a metrics row (a centered
// −100…+100 order-book-imbalance bar, signed cumulative delta, delta rate),
// the active order-flow flags as ember-outlined chips with plain-English
// meaning on hover, the desk's latest AI narrative (MarkdownText), and an
// honest real/delayed + source label. Every reading traces to a FlowRead the
// engine vouched for; delayed data is NEVER styled as live, and the copy stays
// probabilistic ("elevated reversal risk", never "crash coming"). All math
// lives in the pure helpers below (FlowMetrics / FlowPressure / FlowFlag /
// FlowBanner / FlowNarrative); the view is arrangement only.

import SwiftUI

// MARK: - Pressure verdict (pure)

/// The plain-English order-flow verdict, parsed from FlowRead.pressure. The
/// headline text stays bone; only the small direction cue carries up/down
/// color (design law: green/red mean money and direction, nothing else).
enum FlowPressure: Equatable {
    case buyers, sellers, balanced

    /// Absent / unknown pressure decodes to the neutral `balanced` — the panel
    /// never invents a directional verdict it was not given.
    static func parse(_ raw: String) -> FlowPressure {
        switch raw.lowercased() {
        case "buyers", "buyer", "buy": .buyers
        case "sellers", "seller", "sell": .sellers
        default: .balanced
        }
    }

    /// The bone headline copy.
    var headline: String {
        switch self {
        case .buyers: "BUYERS in control"
        case .sellers: "SELLERS in control"
        case .balanced: "balanced"
        }
    }

    /// The money-direction cue: up for buyers, down for sellers, neutral (no
    /// glyph) when balanced. Reuses the montage's AggressorTone so the up/down
    /// token mapping stays in one place.
    var tone: AggressorTone {
        switch self {
        case .buyers: .up
        case .sellers: .down
        case .balanced: .neutral
        }
    }
}

// MARK: - Imbalance bar math (pure, NaN-safe)

enum FlowMetrics {
    /// The signed −1…1 fill fraction for the centered imbalance bar. NaN-safe:
    /// a non-finite value yields 0 (dead center); anything past ±1 clamps.
    static func imbalanceFraction(_ imbalance: Double) -> Double {
        guard imbalance.isFinite else { return 0 }
        return min(max(imbalance, -1), 1)
    }

    /// The −100…+100 display score for the imbalance (the bar's numeric read).
    /// NaN-safe via `imbalanceFraction`.
    static func imbalanceScore(_ imbalance: Double) -> Int {
        Int((imbalanceFraction(imbalance) * 100).rounded())
    }
}

// MARK: - Order-flow flags (pure)

/// One order-flow flag's plain-English label + honest meaning. The engine
/// sends terse codes ("absorption:ask", "sweep:buy", "delta_divergence"); the
/// panel renders a readable label with a probabilistic meaning on hover.
/// Unknown codes degrade gracefully (colons/underscores humanized) so a new
/// engine flag still renders rather than showing a raw token.
struct FlowFlag: Equatable {
    let label: String
    let meaning: String

    static func describe(_ code: String) -> FlowFlag {
        switch code.lowercased() {
        case "absorption:ask":
            return FlowFlag(
                label: "absorption (ask)",
                meaning: "aggressive buying is being absorbed at the ask — a large resting seller is capping upside for now")
        case "absorption:bid":
            return FlowFlag(
                label: "absorption (bid)",
                meaning: "aggressive selling is being absorbed at the bid — a large resting buyer is supporting price for now")
        case "sweep:buy":
            return FlowFlag(
                label: "buy sweep",
                meaning: "an aggressive buyer lifted several ask levels at once — urgent demand")
        case "sweep:sell":
            return FlowFlag(
                label: "sell sweep",
                meaning: "an aggressive seller hit several bid levels at once — urgent supply")
        case "delta_divergence":
            return FlowFlag(
                label: "delta divergence — reversal risk",
                meaning: "price and cumulative order-flow delta disagree — elevated reversal risk, not a certainty")
        case "squeeze_dynamics":
            return FlowFlag(
                label: "squeeze dynamics",
                meaning: "squeeze BEHAVIOR in the tape — thinning offers + accelerating up-delta + rising price. NOT a short-interest / short-squeeze call; short interest isn't in Level-2 data")
        case "exhaustion":
            return FlowFlag(
                label: "exhaustion",
                meaning: "aggressor flow is fading into the move — the current push may be tiring")
        default:
            return FlowFlag(label: humanize(code), meaning: "order-flow flag: \(code)")
        }
    }

    /// Humanize an unknown code: "foo:bar_baz" -> "foo (bar baz)".
    private static func humanize(_ code: String) -> String {
        let parts = code.split(separator: ":", maxSplits: 1).map {
            $0.replacingOccurrences(of: "_", with: " ")
        }
        if parts.count == 2 { return "\(parts[0]) (\(parts[1]))" }
        return parts.first ?? code
    }
}

// MARK: - Real / delayed banner (honesty, pure)

/// The honest source banner for the FLOW read — same cardinal rule as the
/// depth banner: `live` appears ONLY for flow the engine vouched for as
/// real-time. Anything else (no read yet, or `is_live == false`) reads as
/// waiting or delayed, never live. Pure so the honesty rule is unit-tested.
struct FlowBanner: Equatable {
    enum Kind: Equatable { case waiting, live, delayed }

    var kind: Kind
    /// The feed source label ("IBKR", "synthetic", …); "—" while waiting.
    var source: String
    /// One honest line for the operator.
    var note: String

    var isLive: Bool { kind == .live }

    static func make(for flow: FlowRead?) -> FlowBanner {
        guard let flow else {
            return FlowBanner(kind: .waiting, source: "—", note: "waiting on order flow")
        }
        let source = flow.source.isEmpty ? "unknown" : flow.source
        if flow.is_live {
            return FlowBanner(kind: .live, source: source, note: "real-time order flow")
        }
        return FlowBanner(
            kind: .delayed, source: source,
            note: "reading delayed data — real-time via IBKR (Settings)"
        )
    }
}

// MARK: - Desk narrative (pure)

/// Resolves the desk's latest order-flow narrative for a symbol: prefer a live
/// `desk-flow` thought (the richer AI note the desk stream carries) when one
/// exists for this symbol, else fall back to the FlowRead's own `note`.
/// Empty/whitespace text is treated as absent so a blank card never renders.
/// `thoughts` arrive newest-first, so the first match is the latest.
enum FlowNarrative {
    static func resolve(note: String, thoughts: [AgentThought], symbol: String) -> String? {
        let sym = symbol.uppercased()
        if let desk = thoughts.first(where: {
            $0.squadron.hasPrefix("desk-flow")
                && $0.symbol?.uppercased() == sym
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return desk.text
        }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Panel

/// The FLOW read panel, stacked as one panel of the chart trading dock. Reads
/// the active-symbol `flowRead` + the desk thought stream from the model. An
/// optional `onHide` adds a collapse affordance to the header so the dock can
/// turn this panel off (nil = no affordance; behavior otherwise unchanged).
struct FlowPanel: View {
    @Environment(AppModel.self) private var model
    /// When set, the header shows a collapse button that hides this dock panel.
    var onHide: (() -> Void)? = nil

    private var flow: FlowRead? { model.flowRead }
    private var banner: FlowBanner { FlowBanner.make(for: flow) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if banner.kind == .delayed { delayedNote }
            Divider().overlay(Theme.line)
            content
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.ink)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            SectionLabel(text: "flow")
            if let flow {
                Text(flow.symbol)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.bone)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            sourceBanner
            if let onHide { DockCollapseButton(panel: .flow, action: onHide) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Honest real/delayed posture. Good data stays quiet (a calm dim
    /// "REAL-TIME"); a delayed feed draws an ember attention dot and reads
    /// "DELAYED" — never green/live styling on delayed flow.
    private var sourceBanner: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(banner.kind == .delayed ? Theme.ember : Theme.dim)
                .frame(width: 6, height: 6)
            Text(banner.isLive ? "REAL-TIME" : (banner.kind == .delayed ? "DELAYED" : "WAITING"))
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(banner.kind == .delayed ? Theme.ember : Theme.dim)
            if banner.kind != .waiting {
                Text("·")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.dim)
                Text(banner.source)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            }
        }
        .help(banner.note)
        .accessibilityLabel("order flow \(banner.isLive ? "real time" : "delayed") \(banner.source)")
    }

    /// Full-width honest note when the flow read is delayed, so the operator
    /// can never mistake it for real-time. Calm chrome (an ember dot + dim
    /// text), never a loud warning color.
    private var delayedNote: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.ember).frame(width: 5, height: 5)
            Text(banner.note)
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Theme.panel)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let flow {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    PressureHeadline(pressure: FlowPressure.parse(flow.pressure))
                    metrics(flow)
                    flags(flow)
                    narrative(flow)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            DeckEmpty(text: "waiting on order flow — open a symbol with live depth")
                .padding(.horizontal, 16)
        }
    }

    // MARK: Metrics

    private func metrics(_ flow: FlowRead) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            imbalanceMetric(flow.imbalance)
            HStack(alignment: .top, spacing: 12) {
                signedMetric("cum delta", flow.cum_delta)
                signedMetric("delta rate", flow.delta_rate)
            }
        }
    }

    private func imbalanceMetric(_ imbalance: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                metricLabel("order-book imbalance")
                Spacer(minLength: 0)
                Text(signedScore(FlowMetrics.imbalanceScore(imbalance)))
                    .numeric(size: 12, weight: .semibold)
                    .foregroundStyle(Theme.bone)
            }
            ImbalanceBar(fraction: FlowMetrics.imbalanceFraction(imbalance))
                .frame(height: 10)
            HStack(spacing: 0) {
                Text("sellers")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.dim)
                Spacer(minLength: 0)
                Text("buyers")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.dim)
            }
        }
    }

    /// A signed, money-direction metric: the value colored up/down/dim by sign
    /// (the only place green/red mean direction here), mono + tabular.
    private func signedMetric(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            metricLabel(label)
            Text(value.isFinite ? DashFormat.money(value, signed: true) : "—")
                .numeric(size: 14, weight: .medium)
                .foregroundStyle(value.isFinite ? Theme.pnlColor(value) : Theme.dim)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metricLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 8, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(Theme.dim)
            .lineLimit(1)
    }

    /// "+42" / "−42" / "0" — explicit sign so the imbalance direction reads
    /// at a glance without color.
    private func signedScore(_ score: Int) -> String {
        score > 0 ? "+\(score)" : "\(score)"
    }

    // MARK: Flags

    @ViewBuilder
    private func flags(_ flow: FlowRead) -> some View {
        if !flow.flags.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                metricLabel("flags")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(flow.flags.enumerated()), id: \.offset) { _, code in
                            FlowFlagChip(flag: FlowFlag.describe(code))
                        }
                    }
                }
            }
        }
    }

    // MARK: Narrative

    @ViewBuilder
    private func narrative(_ flow: FlowRead) -> some View {
        if let text = FlowNarrative.resolve(
            note: flow.note, thoughts: model.thoughts, symbol: flow.symbol
        ) {
            VStack(alignment: .leading, spacing: 6) {
                metricLabel("desk read")
                MarkdownText(text)
            }
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.ember)
                    .frame(width: 2)
            }
        }
    }
}

// MARK: - Pressure headline

/// The headline PRESSURE verdict. The copy stays bone (design law); only the
/// small leading glyph carries up/down color for the money-direction, and
/// balanced shows no glyph at all.
private struct PressureHeadline: View {
    let pressure: FlowPressure

    private var cueColor: Color {
        switch pressure.tone {
        case .up: Theme.up
        case .down: Theme.down
        case .neutral: Theme.dim
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            switch pressure.tone {
            case .up:
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(cueColor)
            case .down:
                Image(systemName: "arrow.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(cueColor)
            case .neutral:
                EmptyView()
            }
            Text(pressure.headline)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(pressure == .balanced ? Theme.dim : Theme.bone)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityLabel("pressure \(pressure.headline)")
    }
}

// MARK: - Imbalance bar

/// A centered −100…+100 imbalance bar: an ember fill grows from the middle
/// toward buyers (right) or sellers (left) of a hairline track, past a 1px
/// center tick. Ember is the accent (attention); direction is read from which
/// side of center it fills — never from up/down color (that stays for money).
///
/// Drawn in a Canvas rather than a GeometryReader + ZStack: `fraction` re-lands
/// on every ~12 Hz flush, and a GeometryReader forces a fresh layout pass each
/// time (the meter was a per-flush layout-thrash source). The Canvas snaps to
/// each reading with zero layout cost and no implicit animation (a 0.25s ease
/// would never settle between updates, repainting at display rate forever).
private struct ImbalanceBar: View {
    /// Signed −1…1 fraction (already clamped + NaN-safe by FlowMetrics).
    let fraction: Double

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            let half = size.width / 2
            let cy = size.height / 2
            let trackH: CGFloat = 4
            let radius: CGFloat = 2
            // Track.
            ctx.fill(
                Path(roundedRect: CGRect(x: 0, y: cy - trackH / 2, width: size.width, height: trackH), cornerRadius: radius),
                with: .color(Theme.line)
            )
            // Ember fill, anchored at the center, extending to one side.
            let fillW = half * CGFloat(abs(fraction))
            if fillW > 0 {
                let x = fraction >= 0 ? half : half - fillW
                ctx.fill(
                    Path(roundedRect: CGRect(x: x, y: cy - trackH / 2, width: fillW, height: trackH), cornerRadius: radius),
                    with: .color(Theme.ember)
                )
            }
            // Center zero tick, taller than the track.
            ctx.fill(
                Path(CGRect(x: half - Theme.hairline / 2, y: cy - 5, width: Theme.hairline, height: 10)),
                with: .color(Theme.dim)
            )
        }
    }
}

// MARK: - Flag chip

/// One order-flow flag chip: ember text on a hairline outline (design law
/// reserves colored borders for nothing — the ember carries the accent). The
/// plain-English meaning shows on hover.
private struct FlowFlagChip: View {
    let flag: FlowFlag

    var body: some View {
        Text(flag.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.ember)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.chipRadius)
                    .strokeBorder(Theme.line, lineWidth: Theme.hairline)
            )
            .help(flag.meaning)
    }
}
