// Canvas renderer for the flagship chart: candlesticks, EMA / Bollinger
// overlays, volume + RSI subpanes, crosshair readout, pan/zoom and the AI
// annotation layer (signal markers, agent-thought dots).

import SwiftUI

enum ChartColors {
    static let ema9 = Color(hex: 0x7B9EC7)
    static let ema21 = Color(hex: 0x9B7BC7)
    static let ema50 = Color(hex: 0x6E6E78)
    static let rsi = Color(hex: 0x5E82AD)
    static let bbEdge = Theme.bone.opacity(0.22)
    static let bbFill = Theme.bone.opacity(0.06)
}

struct CandleChart: View {
    let bars: [Bar]
    let interval: Interval
    let signals: [StrategySignal]
    let thoughts: [AgentThought]
    let feeds: [FeedStatus]
    let interaction: ChartInteraction

    var body: some View {
        GeometryReader { geo in
            if bars.isEmpty {
                emptyState
            } else {
                chartBody(
                    ChartFrame(
                        bars: bars, interval: interval, signals: signals,
                        thoughts: thoughts, size: geo.size, interaction: interaction
                    )
                )
            }
        }
        .background(Theme.ink)
    }

    // MARK: - Chart composition

    private func chartBody(_ frame: ChartFrame?) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas(opaque: true, rendersAsynchronously: false) { ctx, canvasSize in
                if let frame {
                    frame.draw(in: ctx)
                } else {
                    ctx.fill(
                        Path(CGRect(origin: .zero, size: canvasSize)),
                        with: .color(Theme.ink)
                    )
                }
            }
            ScrollWheelCatcher { deltaY, location in
                guard let frame else { return }
                interaction.zoom(
                    scrollDeltaY: deltaY,
                    anchorFraction: Double(location.x / max(frame.plotWidth, 1)),
                    total: bars.count
                )
            }
            if let frame {
                overlays(frame)
            }
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(frame))
        .onTapGesture(count: 2) { interaction.resetToLive() }
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): interaction.hover = p
            case .ended: interaction.hover = nil
            }
        }
    }

    private func dragGesture(_ frame: ChartFrame?) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard let frame else { return }
                interaction.dragChanged(
                    translationX: value.translation.width,
                    slotWidth: frame.slot,
                    total: bars.count
                )
            }
            .onEnded { _ in interaction.dragEnded() }
    }

    // MARK: - SwiftUI overlays

    @ViewBuilder
    private func overlays(_ frame: ChartFrame) -> some View {
        legend(frame)
            .padding(8)
        if !interaction.isFollowing {
            liveChip(frame)
        }
        if !interaction.isDragging,
            let hover = interaction.hover,
            let info = frame.crosshair(at: hover) {
            crosshairChips(frame, info)
        }
    }

    private func legend(_ frame: ChartFrame) -> some View {
        let i = frame.legendIndex()
        return HStack(spacing: 4) {
            LegendChip(
                label: "ema 9", value: frame.indicatorText(frame.ema9, at: i),
                color: ChartColors.ema9, isOn: interaction.showEMA9
            ) { interaction.showEMA9.toggle() }
            LegendChip(
                label: "ema 21", value: frame.indicatorText(frame.ema21, at: i),
                color: ChartColors.ema21, isOn: interaction.showEMA21
            ) { interaction.showEMA21.toggle() }
            LegendChip(
                label: "ema 50", value: frame.indicatorText(frame.ema50, at: i),
                color: ChartColors.ema50, isOn: interaction.showEMA50
            ) { interaction.showEMA50.toggle() }
            LegendChip(
                label: "bb 20", value: frame.bollingerText(at: i),
                color: Theme.bone.opacity(0.55), isOn: interaction.showBollinger
            ) { interaction.showBollinger.toggle() }
            LegendChip(
                label: "rsi 14", value: frame.rsiText(at: i),
                color: ChartColors.rsi, isOn: interaction.showRSI
            ) { interaction.showRSI.toggle() }
        }
    }

    private func liveChip(_ frame: ChartFrame) -> some View {
        Button {
            interaction.resetToLive()
        } label: {
            Text("Live")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.ember)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.chipRadius)
                        .strokeBorder(Theme.line, lineWidth: Theme.hairline)
                )
        }
        .buttonStyle(.plain)
        .position(x: frame.mainRect.maxX - 34, y: frame.mainRect.maxY - 16)
    }

    private func crosshairChips(_ frame: ChartFrame, _ info: ChartFrame.CrosshairInfo) -> some View {
        let chipW: CGFloat = 172
        var x = info.snapX + 14
        if x + chipW > frame.plotWidth - 4 { x = max(4, info.snapX - chipW - 14) }
        let y = min(max(info.y + 12, 8), max(8, frame.paneBottom - 170))
        return VStack(alignment: .leading, spacing: 6) {
            ReadoutChip(bar: info.bar, prevClose: info.prevClose, interval: interval)
            if !info.signals.isEmpty { SignalChip(signals: info.signals) }
            if !info.topThoughts.isEmpty { ThoughtChip(thoughts: info.topThoughts) }
        }
        .frame(width: chipW, alignment: .leading)
        .offset(x: x, y: y)
        .allowsHitTesting(false)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("waiting for market data")
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
            if feeds.isEmpty {
                Text("no feeds reporting")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim.opacity(0.7))
            } else {
                VStack(spacing: 4) {
                    ForEach(feeds, id: \.feed) { f in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(healthColor(f.health))
                                .frame(width: 5, height: 5)
                            Text("\(f.feed) \(f.health.rawValue.replacingOccurrences(of: "_", with: " "))")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.dim.opacity(0.8))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func healthColor(_ health: FeedHealth) -> Color {
        switch health {
        case .live: Theme.up
        case .degraded, .synthetic_fallback: Theme.warn
        case .down: Theme.down
        }
    }
}

// MARK: - Legend chip

private struct LegendChip: View {
    let label: String
    let value: String?
    let color: Color
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Circle()
                    .fill(isOn ? color : Theme.dim.opacity(0.35))
                    .frame(width: 5, height: 5)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isOn ? Theme.dim : Theme.dim.opacity(0.5))
                if isOn, let value {
                    Text(value)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(color)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Theme.panel.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.chipRadius)
                    .strokeBorder(Theme.line, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Crosshair chips

private struct ChipBackground: ViewModifier {
    var border: Color = Theme.line
    func body(content: Content) -> some View {
        content
            .padding(8)
            .background(Theme.panel.opacity(0.96))
            .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.chipRadius)
                    .strokeBorder(border, lineWidth: 1)
            )
    }
}

private extension View {
    func hoverChip(border: Color = Theme.line) -> some View {
        modifier(ChipBackground(border: border))
    }
}

private struct ReadoutChip: View {
    let bar: Bar
    let prevClose: Double
    let interval: Interval

    var body: some View {
        let delta = bar.close - prevClose
        let pct = prevClose != 0 ? delta / prevClose * 100 : 0
        VStack(alignment: .leading, spacing: 3) {
            Text(ChartMath.readoutTimeLabel(bar.ts_open_ms, interval: interval))
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.bone)
            row("o", ChartMath.formatPrice(bar.open))
            row("h", ChartMath.formatPrice(bar.high))
            row("l", ChartMath.formatPrice(bar.low))
            row("c", ChartMath.formatPrice(bar.close))
            row("v", ChartMath.formatVolume(bar.volume))
            row(
                "chg",
                "\(ChartMath.formatSigned(delta)) (\(String(format: "%+.2f", pct))%)",
                color: Theme.pnlColor(delta)
            )
        }
        .hoverChip()
    }

    private func row(_ label: String, _ value: String, color: Color = Theme.bone) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }
}

private struct SignalChip: View {
    let signals: [StrategySignal]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(signals.prefix(3)) { s in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(s.strategy)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.ember)
                        Text(s.direction > 0 ? "long" : "short")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(s.direction > 0 ? Theme.up : Theme.down)
                        Text(String(format: "%.0f%%", s.conviction * 100))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(Theme.dim)
                    }
                    if !s.rationale.isEmpty {
                        Text(s.rationale)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.dim)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .hoverChip(border: Theme.ember.opacity(0.4))
    }
}

private struct ThoughtChip: View {
    let thoughts: [AgentThought]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(thoughts.prefix(3)) { t in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(t.agent)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.ember)
                        Text(t.severity.rawValue)
                            .font(.system(size: 10))
                            .foregroundStyle(t.severity == .critical ? Theme.down : Theme.warn)
                    }
                    Text(t.text)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .hoverChip(border: Theme.ember.opacity(0.4))
    }
}

// MARK: - Frame (per-draw precomputed geometry + renderer)

private struct ChartFrame {
    // Inputs
    let bars: [Bar]
    let interval: Interval
    let size: CGSize
    let showBB: Bool
    let hoverPoint: CGPoint?

    // Layout
    let plotWidth: CGFloat
    let axisX: CGFloat
    let mainRect: CGRect
    let volRect: CGRect
    let rsiRect: CGRect?
    let paneBottom: CGFloat
    let timeAxisHeight: CGFloat

    // Window
    let slot: CGFloat
    let rightIdx: Double
    let range: Range<Int>

    // Scales
    let minP: Double
    let maxP: Double
    let maxVol: Double

    // Indicators (empty when toggled off; else aligned with `bars` indices)
    let ema9: [Double?]
    let ema21: [Double?]
    let ema50: [Double?]
    let bb: [ChartMath.BollingerPoint?]
    let rsi: [Double?]

    // AI layer, bucketed onto visible bar indices
    let visibleSignals: [(index: Int, signals: [StrategySignal])]
    let visibleThoughts: [(index: Int, thoughts: [AgentThought])]

    init?(
        bars: [Bar], interval: Interval, signals: [StrategySignal],
        thoughts: [AgentThought], size: CGSize, interaction: ChartInteraction
    ) {
        guard !bars.isEmpty, size.width > 140, size.height > 140 else { return nil }
        self.bars = bars
        self.interval = interval
        self.size = size
        self.showBB = interaction.showBollinger
        self.hoverPoint = interaction.isDragging ? nil : interaction.hover

        // Layout
        let axisWidth: CGFloat = 56
        let taH: CGFloat = 20
        timeAxisHeight = taH
        plotWidth = size.width - axisWidth
        axisX = size.width - axisWidth
        let paneH = size.height - taH
        let rsiH: CGFloat = interaction.showRSI ? (paneH * 0.18).rounded() : 0
        let volH: CGFloat = (paneH * 0.14).rounded()
        let mainH = paneH - volH - rsiH
        mainRect = CGRect(x: 0, y: 0, width: plotWidth, height: mainH)
        volRect = CGRect(x: 0, y: mainH, width: plotWidth, height: volH)
        rsiRect = rsiH > 0 ? CGRect(x: 0, y: mainH + volH, width: plotWidth, height: rsiH) : nil
        paneBottom = mainH + volH + rsiH

        // Window
        let total = bars.count
        let visible = min(max(interaction.barsVisible, ChartMath.minVisibleBars), ChartMath.maxVisibleBars)
        slot = plotWidth / CGFloat(visible)
        let offset = ChartMath.clampOffset(interaction.rightOffset, total: total, barsVisible: visible)
        rightIdx = Double(total - 1) - offset
        range = ChartMath.visibleRange(total: total, barsVisible: visible, rightOffset: offset)

        // Indicators over the full series (windowed slices would distort warm-up)
        let closes = bars.map(\.close)
        ema9 = interaction.showEMA9 ? ChartMath.ema(closes, period: 9) : []
        ema21 = interaction.showEMA21 ? ChartMath.ema(closes, period: 21) : []
        ema50 = interaction.showEMA50 ? ChartMath.ema(closes, period: 50) : []
        bb = interaction.showBollinger ? ChartMath.bollinger(closes, period: 20, k: 2) : []
        rsi = interaction.showRSI ? ChartMath.rsi(closes, period: 14) : []

        // Price scale over visible bars + enabled overlay values
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        var mv = 0.0
        for i in range {
            lo = min(lo, bars[i].low)
            hi = max(hi, bars[i].high)
            mv = max(mv, bars[i].volume)
        }
        for i in range {
            if bb.count == total, let b = bb[i] {
                lo = min(lo, b.lower)
                hi = max(hi, b.upper)
            }
            if ema9.count == total, let v = ema9[i] { lo = min(lo, v); hi = max(hi, v) }
            if ema21.count == total, let v = ema21[i] { lo = min(lo, v); hi = max(hi, v) }
            if ema50.count == total, let v = ema50[i] { lo = min(lo, v); hi = max(hi, v) }
        }
        if lo > hi { lo = 0; hi = 1 }
        var pad = (hi - lo) * 0.05
        if pad <= 0 { pad = max(abs(hi) * 0.001, 1e-9) }
        minP = lo - pad
        maxP = hi + pad
        maxVol = max(mv, 1e-12)

        // AI buckets -> visible bar indices
        var indexByTs = [Int64: Int](minimumCapacity: range.count)
        for i in range { indexByTs[bars[i].ts_open_ms] = i }
        var sigMap: [Int: [StrategySignal]] = [:]
        for s in signals {
            if let i = indexByTs[ChartMath.bucket(s.ts_ms, interval)] {
                sigMap[i, default: []].append(s)
            }
        }
        visibleSignals = sigMap.map { (index: $0.key, signals: $0.value) }
        var thoughtMap: [Int: [AgentThought]] = [:]
        for t in thoughts {
            if let i = indexByTs[ChartMath.bucket(t.ts_ms, interval)] {
                thoughtMap[i, default: []].append(t)
            }
        }
        visibleThoughts = thoughtMap.map { (index: $0.key, thoughts: $0.value) }
    }

    // MARK: Coordinates

    func x(_ i: Int) -> CGFloat { xD(Double(i)) }

    func xD(_ i: Double) -> CGFloat {
        plotWidth - CGFloat(rightIdx - i) * slot - slot / 2
    }

    func yPrice(_ p: Double) -> CGFloat {
        let f = (p - minP) / (maxP - minP)
        return mainRect.maxY - CGFloat(f) * mainRect.height
    }

    func priceAtY(_ y: CGFloat) -> Double {
        minP + Double((mainRect.maxY - y) / mainRect.height) * (maxP - minP)
    }

    func yRSI(_ v: Double, in rect: CGRect) -> CGFloat {
        rect.maxY - CGFloat(v / 100) * rect.height
    }

    func index(atX px: CGFloat) -> Int? {
        guard !range.isEmpty, slot > 0 else { return nil }
        let raw = rightIdx - Double((plotWidth - slot / 2 - px) / slot)
        let i = Int(raw.rounded())
        if range.contains(i) { return i }
        return i < range.lowerBound ? range.lowerBound : range.upperBound - 1
    }

    // MARK: Crosshair & legend lookups

    struct CrosshairInfo {
        let index: Int
        let bar: Bar
        let prevClose: Double
        let snapX: CGFloat
        let y: CGFloat
        let signals: [StrategySignal]
        let topThoughts: [AgentThought]
    }

    func crosshair(at p: CGPoint) -> CrosshairInfo? {
        guard p.x >= 0, p.x < plotWidth, p.y >= 0, p.y < paneBottom else { return nil }
        guard let i = index(atX: p.x) else { return nil }
        let bar = bars[i]
        let prev = i > 0 ? bars[i - 1].close : bar.open
        let sigs = visibleSignals.first(where: { $0.index == i })?.signals ?? []
        let nearTop = p.y < mainRect.minY + 16
        let th = nearTop ? (visibleThoughts.first(where: { $0.index == i })?.thoughts ?? []) : []
        return CrosshairInfo(
            index: i, bar: bar, prevClose: prev, snapX: x(i), y: p.y,
            signals: sigs, topThoughts: th
        )
    }

    func legendIndex() -> Int {
        if let hoverPoint, let info = crosshair(at: hoverPoint) { return info.index }
        return max(range.lowerBound, range.upperBound - 1)
    }

    func indicatorText(_ values: [Double?], at i: Int) -> String? {
        guard values.count == bars.count, i >= 0, i < values.count, let v = values[i] else {
            return nil
        }
        return ChartMath.formatPrice(v)
    }

    func bollingerText(at i: Int) -> String? {
        guard bb.count == bars.count, i >= 0, i < bb.count, let b = bb[i] else { return nil }
        return ChartMath.formatPrice(b.mid)
    }

    func rsiText(at i: Int) -> String? {
        guard rsi.count == bars.count, i >= 0, i < rsi.count, let v = rsi[i] else { return nil }
        return String(format: "%.1f", v)
    }

    // MARK: Drawing

    func draw(in ctx: GraphicsContext) {
        drawBackground(ctx)
        drawGrid(ctx)
        drawBollinger(ctx)
        drawCandles(ctx)
        drawEMAs(ctx)
        drawVolume(ctx)
        drawRSIPane(ctx)
        drawAI(ctx)
        drawLastPrice(ctx)
        drawCrosshair(ctx)
    }

    private func drawBackground(_ ctx: GraphicsContext) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.ink))
        // axis gutter separator
        var p = Path()
        p.move(to: CGPoint(x: axisX + 0.5, y: 0))
        p.addLine(to: CGPoint(x: axisX + 0.5, y: paneBottom))
        ctx.stroke(p, with: .color(Theme.line.opacity(0.8)), lineWidth: 1)
    }

    private func axisText(_ s: String) -> Text {
        Text(s)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.dim)
    }

    private func tinyText(_ s: String) -> Text {
        Text(s)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Theme.dim.opacity(0.7))
    }

    private func timeStep() -> Int {
        let minPx: CGFloat = 78
        let raw = Int((minPx / max(slot, 0.5)).rounded(.up))
        let nice = [1, 2, 3, 5, 10, 15, 30, 60, 120, 240, 480, 1440]
        return nice.first(where: { $0 >= raw }) ?? raw
    }

    private func drawGrid(_ ctx: GraphicsContext) {
        let gridColor = Theme.line.opacity(0.4)

        // Horizontal price gridlines + right-axis labels
        let target = max(3, Int(mainRect.height / 44))
        for tick in ChartMath.axisTicks(min: minP, max: maxP, target: target) {
            let y = yPrice(tick).rounded() + 0.5
            guard y > mainRect.minY + 5, y < mainRect.maxY - 3 else { continue }
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: plotWidth, y: y))
            ctx.stroke(p, with: .color(gridColor), lineWidth: 1)
            ctx.draw(
                axisText(ChartMath.formatPrice(tick)),
                at: CGPoint(x: axisX + 6, y: y), anchor: .leading
            )
        }

        // Vertical time gridlines + bottom labels, anchored to wall-clock buckets
        let step = Int64(timeStep())
        for i in range {
            guard (bars[i].ts_open_ms / interval.ms) % step == 0 else { continue }
            let xx = x(i).rounded() + 0.5
            guard xx > 2, xx < plotWidth - 2 else { continue }
            var p = Path()
            p.move(to: CGPoint(x: xx, y: 0))
            p.addLine(to: CGPoint(x: xx, y: paneBottom))
            ctx.stroke(p, with: .color(gridColor), lineWidth: 1)
            ctx.draw(
                axisText(ChartMath.timeLabel(bars[i].ts_open_ms, interval: interval)),
                at: CGPoint(x: xx, y: paneBottom + timeAxisHeight / 2), anchor: .center
            )
        }

        // Pane separators
        var separators = [volRect.minY, paneBottom]
        if let r = rsiRect { separators.append(r.minY) }
        for yy in separators {
            var p = Path()
            let y = yy.rounded() + 0.5
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(p, with: .color(Theme.line.opacity(0.8)), lineWidth: 1)
        }
    }

    private func drawBollinger(_ ctx: GraphicsContext) {
        guard showBB, bb.count == bars.count else { return }
        var upper: [CGPoint] = []
        var lower: [CGPoint] = []
        upper.reserveCapacity(range.count)
        lower.reserveCapacity(range.count)
        for i in range {
            guard let b = bb[i] else { continue }
            let px = x(i)
            upper.append(CGPoint(x: px, y: yPrice(b.upper)))
            lower.append(CGPoint(x: px, y: yPrice(b.lower)))
        }
        guard upper.count > 1 else { return }

        var clipped = ctx
        clipped.clip(to: Path(mainRect))

        var fill = Path()
        fill.move(to: upper[0])
        for pt in upper.dropFirst() { fill.addLine(to: pt) }
        for pt in lower.reversed() { fill.addLine(to: pt) }
        fill.closeSubpath()
        clipped.fill(fill, with: .color(ChartColors.bbFill))

        var upperPath = Path()
        upperPath.move(to: upper[0])
        for pt in upper.dropFirst() { upperPath.addLine(to: pt) }
        clipped.stroke(upperPath, with: .color(ChartColors.bbEdge), lineWidth: 1)

        var lowerPath = Path()
        lowerPath.move(to: lower[0])
        for pt in lower.dropFirst() { lowerPath.addLine(to: pt) }
        clipped.stroke(lowerPath, with: .color(ChartColors.bbEdge), lineWidth: 1)
    }

    private func drawCandles(_ ctx: GraphicsContext) {
        var upBodies = Path()
        var downBodies = Path()
        var upWicks = Path()
        var downWicks = Path()
        let bodyW = max(1, (slot * 0.7).rounded())
        let lastIndex = bars.count - 1

        for i in range {
            let b = bars[i]
            let forming = i == lastIndex && !b.complete
            if forming { continue } // rendered separately below
            let xC = x(i).rounded()
            let yH = yPrice(b.high).rounded()
            let yL = yPrice(b.low).rounded()
            let yO = yPrice(b.open).rounded()
            let yC = yPrice(b.close).rounded()
            let bodyRect = CGRect(
                x: xC - bodyW / 2, y: min(yO, yC), width: bodyW, height: max(1, abs(yO - yC))
            )
            let wickRect = CGRect(x: xC - 0.5, y: yH, width: 1, height: max(1, yL - yH))
            if b.close >= b.open {
                upBodies.addRect(bodyRect)
                upWicks.addRect(wickRect)
            } else {
                downBodies.addRect(bodyRect)
                downWicks.addRect(wickRect)
            }
        }
        ctx.fill(upWicks, with: .color(Theme.up))
        ctx.fill(downWicks, with: .color(Theme.down))
        ctx.fill(upBodies, with: .color(Theme.up))
        ctx.fill(downBodies, with: .color(Theme.down))

        // Forming bar: hollow-ish at reduced opacity, refreshed every second.
        if let b = bars.last, !b.complete, range.contains(lastIndex) {
            let color = b.close >= b.open ? Theme.up : Theme.down
            let xC = x(lastIndex).rounded()
            let yH = yPrice(b.high).rounded()
            let yL = yPrice(b.low).rounded()
            let yO = yPrice(b.open).rounded()
            let yC = yPrice(b.close).rounded()
            let bodyRect = CGRect(
                x: xC - bodyW / 2, y: min(yO, yC), width: bodyW, height: max(1, abs(yO - yC))
            )
            ctx.fill(
                Path(CGRect(x: xC - 0.5, y: yH, width: 1, height: max(1, yL - yH))),
                with: .color(color.opacity(0.6))
            )
            ctx.fill(Path(bodyRect), with: .color(color.opacity(0.3)))
            ctx.stroke(
                Path(bodyRect.insetBy(dx: 0.5, dy: 0.5)),
                with: .color(color.opacity(0.85)), lineWidth: 1
            )
        }
    }

    private func drawEMAs(_ ctx: GraphicsContext) {
        var clipped = ctx
        clipped.clip(to: Path(mainRect))
        strokeIndicator(clipped, values: ema9, color: ChartColors.ema9)
        strokeIndicator(clipped, values: ema21, color: ChartColors.ema21)
        strokeIndicator(clipped, values: ema50, color: ChartColors.ema50)
    }

    private func strokeIndicator(_ ctx: GraphicsContext, values: [Double?], color: Color) {
        guard values.count == bars.count else { return }
        var path = Path()
        var started = false
        for i in range {
            guard let v = values[i] else {
                started = false
                continue
            }
            let pt = CGPoint(x: x(i), y: yPrice(v))
            if started {
                path.addLine(to: pt)
            } else {
                path.move(to: pt)
                started = true
            }
        }
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
    }

    private func drawVolume(_ ctx: GraphicsContext) {
        let bodyW = max(1, (slot * 0.7).rounded())
        var upP = Path()
        var downP = Path()
        let usableH = max(volRect.height - 6, 2)
        for i in range {
            let b = bars[i]
            guard b.volume > 0 else { continue }
            let h = max(1, (CGFloat(b.volume / maxVol) * usableH).rounded())
            let xC = x(i).rounded()
            let r = CGRect(x: xC - bodyW / 2, y: volRect.maxY - h, width: bodyW, height: h)
            if b.close >= b.open { upP.addRect(r) } else { downP.addRect(r) }
        }
        ctx.fill(upP, with: .color(Theme.up.opacity(0.25)))
        ctx.fill(downP, with: .color(Theme.down.opacity(0.25)))
        ctx.draw(tinyText("vol"), at: CGPoint(x: 6, y: volRect.minY + 9), anchor: .leading)
        ctx.draw(
            axisText(ChartMath.formatVolume(maxVol)),
            at: CGPoint(x: axisX + 6, y: volRect.minY + 9), anchor: .leading
        )
    }

    private func drawRSIPane(_ ctx: GraphicsContext) {
        guard let rect = rsiRect, rsi.count == bars.count else { return }
        let y70 = yRSI(70, in: rect).rounded() + 0.5
        let y50 = yRSI(50, in: rect).rounded() + 0.5
        let y30 = yRSI(30, in: rect).rounded() + 0.5

        // Overbought / oversold zones
        ctx.fill(
            Path(CGRect(x: 0, y: rect.minY, width: plotWidth, height: max(0, y70 - rect.minY))),
            with: .color(Theme.dim.opacity(0.05))
        )
        ctx.fill(
            Path(CGRect(x: 0, y: y30, width: plotWidth, height: max(0, rect.maxY - y30))),
            with: .color(Theme.dim.opacity(0.05))
        )

        // Guides
        let dash = StrokeStyle(lineWidth: 1, dash: [3, 3])
        for gy in [y70, y30] {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: gy))
            p.addLine(to: CGPoint(x: plotWidth, y: gy))
            ctx.stroke(p, with: .color(Theme.dim.opacity(0.3)), style: dash)
        }
        var mid = Path()
        mid.move(to: CGPoint(x: 0, y: y50))
        mid.addLine(to: CGPoint(x: plotWidth, y: y50))
        ctx.stroke(mid, with: .color(Theme.line.opacity(0.8)), lineWidth: 1)

        ctx.draw(axisText("70"), at: CGPoint(x: axisX + 6, y: y70), anchor: .leading)
        ctx.draw(axisText("30"), at: CGPoint(x: axisX + 6, y: y30), anchor: .leading)

        // RSI line
        var clipped = ctx
        clipped.clip(to: Path(rect))
        var path = Path()
        var started = false
        for i in range {
            guard let v = rsi[i] else {
                started = false
                continue
            }
            let pt = CGPoint(x: x(i), y: yRSI(v, in: rect))
            if started {
                path.addLine(to: pt)
            } else {
                path.move(to: pt)
                started = true
            }
        }
        clipped.stroke(
            path, with: .color(ChartColors.rsi),
            style: StrokeStyle(lineWidth: 1, lineJoin: .round)
        )

        ctx.draw(tinyText("rsi 14"), at: CGPoint(x: 6, y: rect.minY + 9), anchor: .leading)
    }

    private func drawAI(_ ctx: GraphicsContext) {
        // Signal triangles: long under the bar, short above. 8pt, never on candles.
        for (i, sigs) in visibleSignals {
            let b = bars[i]
            let xC = x(i).rounded()
            if sigs.contains(where: { $0.direction > 0 }) {
                let yTip = min(yPrice(b.low) + 4, mainRect.maxY - 10)
                var t = Path()
                t.move(to: CGPoint(x: xC, y: yTip))
                t.addLine(to: CGPoint(x: xC - 4, y: yTip + 8))
                t.addLine(to: CGPoint(x: xC + 4, y: yTip + 8))
                t.closeSubpath()
                ctx.fill(t, with: .color(Theme.ember))
            }
            if sigs.contains(where: { $0.direction < 0 }) {
                let yTip = max(yPrice(b.high) - 4, mainRect.minY + 12)
                var t = Path()
                t.move(to: CGPoint(x: xC, y: yTip))
                t.addLine(to: CGPoint(x: xC - 4, y: yTip - 8))
                t.addLine(to: CGPoint(x: xC + 4, y: yTip - 8))
                t.closeSubpath()
                ctx.fill(t, with: .color(Theme.ember))
            }
        }

        // Agent-thought dots along the top edge
        for (i, _) in visibleThoughts {
            let xC = x(i).rounded()
            let dot = CGRect(x: xC - 2.5, y: mainRect.minY + 4, width: 5, height: 5)
            ctx.fill(Path(ellipseIn: dot), with: .color(Theme.ember.opacity(0.9)))
        }
    }

    private func drawLastPrice(_ ctx: GraphicsContext) {
        guard let last = bars.last else { return }
        let y = yPrice(last.close)
        guard y > mainRect.minY + 2, y < mainRect.maxY - 2 else { return }
        var p = Path()
        let yy = y.rounded() + 0.5
        p.move(to: CGPoint(x: 0, y: yy))
        p.addLine(to: CGPoint(x: plotWidth, y: yy))
        ctx.stroke(
            p, with: .color(Theme.dim.opacity(0.3)),
            style: StrokeStyle(lineWidth: 1, dash: [2, 3])
        )
        drawTag(
            ctx, text: ChartMath.formatPrice(last.close),
            center: CGPoint(x: axisX + (size.width - axisX) / 2, y: yy),
            background: Theme.panelHi
        )
    }

    private func drawCrosshair(_ ctx: GraphicsContext) {
        guard let hover = hoverPoint, let info = crosshair(at: hover) else { return }
        let dash = StrokeStyle(lineWidth: 1, dash: [3, 3])
        let color = Theme.dim.opacity(0.5)
        let xx = info.snapX.rounded() + 0.5

        var v = Path()
        v.move(to: CGPoint(x: xx, y: 0))
        v.addLine(to: CGPoint(x: xx, y: paneBottom))
        ctx.stroke(v, with: .color(color), style: dash)

        if let pane = paneRect(containing: hover.y) {
            let hy = hover.y.rounded() + 0.5
            var h = Path()
            h.move(to: CGPoint(x: 0, y: hy))
            h.addLine(to: CGPoint(x: plotWidth, y: hy))
            ctx.stroke(h, with: .color(color), style: dash)
            if pane == mainRect {
                drawTag(
                    ctx, text: ChartMath.formatPrice(priceAtY(hover.y)),
                    center: CGPoint(x: axisX + (size.width - axisX) / 2, y: hy),
                    background: Theme.panel
                )
            }
        }

        drawTag(
            ctx, text: ChartMath.readoutTimeLabel(info.bar.ts_open_ms, interval: interval),
            center: CGPoint(x: xx, y: paneBottom + timeAxisHeight / 2),
            background: Theme.panel
        )
    }

    private func paneRect(containing y: CGFloat) -> CGRect? {
        let probe = CGPoint(x: 1, y: y)
        if mainRect.contains(probe) { return mainRect }
        if volRect.contains(probe) { return volRect }
        if let r = rsiRect, r.contains(probe) { return r }
        return nil
    }

    private func drawTag(_ ctx: GraphicsContext, text: String, center: CGPoint, background: Color) {
        let resolved = ctx.resolve(
            Text(text)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.bone)
        )
        let ts = resolved.measure(in: CGSize(width: 220, height: 20))
        var rect = CGRect(
            x: center.x - ts.width / 2 - 4, y: center.y - 7,
            width: ts.width + 8, height: 14
        )
        rect.origin.x = min(max(0, rect.origin.x), size.width - rect.width)
        let path = Path(roundedRect: rect, cornerRadius: 3)
        ctx.fill(path, with: .color(background))
        ctx.stroke(path, with: .color(Theme.line), lineWidth: 1)
        ctx.draw(resolved, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
    }
}
