// Flagship chart panel: header (symbol, live price, session change, spread,
// interval picker, feed health) over the Canvas candle chart.

import SwiftUI

struct ChartPanel: View {
    @Environment(AppModel.self) private var model
    @State private var interaction = ChartInteraction()
    @State private var drawingStore = DrawingStore()
    /// View-level weekly bars: aggregates the 1d series on the fly. Not a
    /// wire interval, so AppModel stays untouched.
    @State private var weeklyMode = false
    @State private var flashDirection = 0
    @State private var flashToken = 0
    @State private var flashSymbol = ""
    @State private var symbolHovering = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            Rectangle()
                .fill(Theme.line)
                .frame(height: Theme.hairline)
            CandleChart(
                symbol: model.selectedSymbol,
                bars: chartBars,
                interval: weeklyMode ? .d1 : model.selectedInterval,
                barSpanMs: weeklyMode ? ChartMath.weekMs : model.selectedInterval.ms,
                signals: model.signals.filter { $0.symbol == model.selectedSymbol },
                thoughts: model.thoughts.filter {
                    $0.symbol == model.selectedSymbol && $0.severity >= .warning
                },
                feeds: model.feeds.values.sorted { $0.feed < $1.feed },
                interaction: interaction,
                drawingStore: drawingStore
            )
        }
        .panel()
        .onChange(of: model.selectedSymbol) { _, _ in
            interaction.resetForNewSeries()
            flashToken += 1
            flashDirection = 0
        }
        .onChange(of: model.selectedInterval) { _, _ in
            interaction.resetForNewSeries()
        }
        .onChange(of: weeklyMode) { _, _ in
            interaction.resetForNewSeries()
        }
        .onChange(of: model.lastPrice(model.selectedSymbol)) { old, new in
            handleTick(old, new)
        }
    }

    private var chartBars: [Bar] {
        weeklyMode
            ? ChartMath.aggregateWeekly(model.bars(model.selectedSymbol, .d1))
            : model.bars(model.selectedSymbol, model.selectedInterval)
    }

    // MARK: - Header

    private var header: some View {
        @Bindable var model = model
        let symbol = model.selectedSymbol
        let price = model.lastPrice(symbol)
        let changePct = model.sessionChangePct(symbol)
        let top = model.bookTop[symbol]

        return HStack(spacing: 12) {
            if AppModel.isEquity(symbol) {
                Button {
                    model.openCompany(symbol)
                } label: {
                    Text(symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(symbolHovering ? Theme.ember : Theme.bone)
                }
                .buttonStyle(.plain)
                .onHover { symbolHovering = $0 }
                .help("company")
            } else {
                Text(symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.bone)
            }

            Text(price.map { ChartMath.formatPrice($0, grouped: true) } ?? "—")
                .font(.system(size: 21, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(priceColor)
                .animation(.easeOut(duration: 0.2), value: flashDirection)

            if let changePct {
                Text(String(format: "%+.2f%%", changePct))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.pnlColor(changePct))
            }

            if let top { spreadChip(top) }

            Spacer(minLength: 8)

            intervalPicker($model.selectedInterval)

            feedDot
        }
    }

    private var priceColor: Color {
        if flashDirection > 0 { return Theme.up }
        if flashDirection < 0 { return Theme.down }
        return Theme.bone
    }

    /// Flash the price toward up/down on tick direction change, then settle
    /// back to bone. Token guards against overlapping fades; the symbol guard
    /// suppresses the spurious flash when the selection switches instruments.
    private func handleTick(_ old: Double?, _ new: Double?) {
        let symbol = model.selectedSymbol
        guard symbol == flashSymbol else {
            flashSymbol = symbol
            return
        }
        guard let o = old, let n = new, n != o else { return }
        flashDirection = n > o ? 1 : -1
        flashToken += 1
        let token = flashToken
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard token == flashToken else { return }
            flashDirection = 0
        }
    }

    private func spreadChip(_ top: BookTop) -> some View {
        HStack(spacing: 5) {
            Text(ChartMath.formatPrice(top.bid_px))
                .foregroundStyle(Theme.up)
            Text("/")
                .foregroundStyle(Theme.dim.opacity(0.6))
            Text(ChartMath.formatPrice(top.ask_px))
                .foregroundStyle(Theme.down)
            Text(ChartMath.formatPrice(max(0, top.ask_px - top.bid_px)))
                .foregroundStyle(Theme.dim)
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Theme.ink)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(Theme.line, lineWidth: Theme.hairline)
        )
        .help("bid / ask / spread")
    }

    private func intervalPicker(_ selection: Binding<Interval>) -> some View {
        HStack(spacing: 2) {
            ForEach(Interval.allCases) { iv in
                intervalChip(iv.label, isOn: !weeklyMode && selection.wrappedValue == iv) {
                    weeklyMode = false
                    selection.wrappedValue = iv
                }
            }
            // Weekly rides on the 1d feed; the 1d chip deselects while on.
            intervalChip("1w", isOn: weeklyMode) {
                selection.wrappedValue = .d1
                weeklyMode = true
            }
        }
        .padding(2)
        .background(Theme.ink)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(Theme.line, lineWidth: Theme.hairline)
        )
    }

    private func intervalChip(
        _ label: String, isOn: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isOn ? Theme.bone : Theme.dim)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(isOn ? Theme.panelHi : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Feed health

    private var feedDot: some View {
        Circle()
            .fill(feedColor)
            .frame(width: 7, height: 7)
            .help(feedTooltip)
    }

    private var feedColor: Color {
        let healths = model.feeds.values.map(\.health)
        if healths.isEmpty { return Theme.dim.opacity(0.5) }
        if healths.contains(.down) { return Theme.down }
        if healths.contains(.synthetic_fallback) || healths.contains(.degraded) {
            return Theme.warn
        }
        return Theme.up
    }

    private var feedTooltip: String {
        guard !model.feeds.isEmpty else { return "no feeds reporting" }
        return model.feeds.values
            .sorted { $0.feed < $1.feed }
            .map { f in
                let health = f.health.rawValue.replacingOccurrences(of: "_", with: " ")
                return f.detail.isEmpty ? "\(f.feed): \(health)" : "\(f.feed): \(health) — \(f.detail)"
            }
            .joined(separator: "\n")
    }
}
