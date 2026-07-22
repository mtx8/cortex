// Flagship chart panel: header (symbol, live price, session change, spread,
// interval picker, feed health) over the Canvas candle chart. Renders as
// the classic global-selection chart, or as one fixed pane of the
// multi-chart grid (see ChartGrid) with its own symbol and interval.

import SwiftUI

struct ChartPanel: View {
    @Environment(AppModel.self) private var model
    /// Fixed pane context from ChartGrid. nil (the default) — and a pane
    /// whose symbol is nil — follow the global selection exactly as the
    /// classic single chart does; a set pane symbol makes this panel
    /// independent of it.
    var pane: Binding<ChartPaneState>? = nil
    /// Drawing persistence. ChartGrid injects ONE shared store into every
    /// pane — private stores would let two panes on the same symbol clobber
    /// each other's persisted drawings (commits rewrite the whole list from
    /// a stale cache). The default instance covers standalone use.
    var drawingStore = DrawingStore()
    // Interaction state is per-instance @State, so every grid pane pans,
    // zooms, and draws on its own.
    @State private var interaction = ChartInteraction()
    /// View-level weekly bars: aggregates the 1d series on the fly. Not a
    /// wire interval, so AppModel stays untouched.
    @State private var weeklyMode = false
    /// Active range preset; cleared when an interval is picked manually.
    @State private var selectedRange: ChartRange?
    @State private var symbolHovering = false

    var body: some View {
        // Evaluated once per body: the bars array plus the marker filters /
        // feed sort feed both CandleChart and the onChange observations, so
        // the quad layout never duplicates this work within one pass.
        let symbol = displaySymbol
        let bars = chartBars
        let signals = model.signals.filter { $0.symbol == symbol }
        let thoughts = model.thoughts.filter {
            $0.symbol == symbol && $0.severity >= .warning
        }
        let feeds = model.feeds.values.sorted { $0.feed < $1.feed }

        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            Rectangle()
                .fill(Theme.line)
                .frame(height: Theme.hairline)
            CandleChart(
                symbol: symbol,
                bars: bars,
                interval: weeklyMode ? .d1 : displayInterval,
                barSpanMs: weeklyMode ? ChartMath.weekMs : displayInterval.ms,
                weekly: weeklyMode,
                signals: signals,
                thoughts: thoughts,
                feeds: feeds,
                interaction: interaction,
                drawingStore: drawingStore
            )
        }
        .panel()
        .onChange(of: displaySymbol) { _, _ in
            interaction.resetForNewSeries()
            selectedRange = nil
        }
        .onChange(of: displayInterval) { _, _ in
            interaction.resetForNewSeries()
        }
        .onChange(of: weeklyMode) { _, _ in
            interaction.resetForNewSeries()
        }
        .onChange(of: bars.count) { _, _ in
            // Deeper history landing while a preset is active re-frames the
            // window. Framing math only — no re-sync — so bars cannot loop
            // it. Only while following: a user who panned back must not be
            // yanked to the live edge by a background bar landing.
            guard let range = selectedRange, interaction.isFollowing else { return }
            frameRange(range)
        }
        .onAppear { ensurePaneData() }
        .onChange(of: model.symbols) { _, _ in
            // The connect snapshot only carries watchlist bars — restored
            // fixed panes pointing at universe tickers fetch theirs here.
            ensurePaneData()
        }
    }

    // MARK: - Pane context

    /// The pane's own symbol when fixed; nil = follow the global selection.
    private var fixedSymbol: String? { pane?.wrappedValue.symbol }

    /// The symbol this panel charts.
    private var displaySymbol: String { fixedSymbol ?? model.selectedSymbol }

    /// The interval this panel charts. Fixed panes ride the global interval
    /// until they set their own override; setInterval keeps the override
    /// pane-local so grid panes never fight over the global picker.
    private var displayInterval: Interval {
        pane?.wrappedValue.interval ?? model.selectedInterval
    }

    private func setInterval(_ interval: Interval) {
        if fixedSymbol != nil {
            pane?.wrappedValue.interval = interval
        } else {
            model.selectedInterval = interval
        }
    }

    /// Restored fixed panes may point at symbols with no bars at all
    /// (universe tickers) — pull their history without touching the
    /// global selection. No-op when any interval already has data.
    private func ensurePaneData() {
        guard let symbol = fixedSymbol else { return }
        model.ensureSymbolData(symbol)
    }

    private var chartBars: [Bar] {
        weeklyMode
            ? ChartMath.aggregateWeekly(model.bars(displaySymbol, .d1))
            : model.bars(displaySymbol, displayInterval)
    }

    // MARK: - Header

    private var header: some View {
        let symbol = displaySymbol
        let changePct = model.sessionChangePct(symbol)
        let top = model.bookTop[symbol]

        return HStack(spacing: 12) {
            if fixedSymbol != nil {
                paneSymbolMenu(symbol)
            } else if AppModel.isEquity(symbol) {
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

            // Live price + tick flash live in their OWN subview, so a price
            // change re-renders only this small label — never the sibling
            // range / interval pickers, which read no market data and so
            // stay laid out across the 12-40 Hz tick storm.
            LivePriceText(symbol: symbol)

            if let changePct {
                Text(String(format: "%+.2f%%", changePct))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.pnlColor(changePct))
            }

            if let top { spreadChip(top) }

            Spacer(minLength: 6)

            // The range + interval pickers scroll horizontally when the pane is
            // narrow (guaranteed in a half/quarter-width multi-chart grid pane)
            // instead of clipping or shoving the identity off-line.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    RangePicker(selectedRange: $selectedRange, apply: applyRange)
                    IntervalPicker(
                        selectedInterval: displayInterval,
                        weeklyMode: weeklyMode,
                        pick: pickInterval,
                        pickWeekly: pickWeekly
                    )
                }
            }

            feedDot
        }
    }

    // MARK: - Pane symbol menu (fixed panes)

    /// Watchlist + scan-universe picker replacing the plain header symbol
    /// on fixed multi-chart panes; picking sets this pane's symbol only.
    private func paneSymbolMenu(_ current: String) -> some View {
        Menu {
            if !model.symbols.isEmpty {
                Section("watchlist") {
                    ForEach(model.symbols, id: \.self) { symbol in
                        Button(symbol) { pickPaneSymbol(symbol) }
                    }
                }
            }
            let universe = model.searchUniverse.filter { !model.symbols.contains($0) }
            if !universe.isEmpty {
                Section("universe") {
                    ForEach(universe, id: \.self) { symbol in
                        Button(symbol) { pickPaneSymbol(symbol) }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(current)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(symbolHovering ? Theme.ember : Theme.bone)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.dim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { symbolHovering = $0 }
        .help("pane symbol")
    }

    /// Fixed-pane symbol pick — the pane stays independent of the global
    /// selection. A sparse series at the pane's interval jumps to the
    /// densest one; symbols with no history at all (universe tickers) get
    /// an on-demand D1 fetch that never touches `model.selectedSymbol`.
    private func pickPaneSymbol(_ symbol: String) {
        guard let pane else { return }
        var state = pane.wrappedValue
        state.symbol = symbol
        if model.bars(symbol, state.interval ?? model.selectedInterval).count < 30 {
            let densest = Interval.allCases
                .map { ($0, model.bars(symbol, $0).count) }
                .max { $0.1 < $1.1 }
            if let (interval, count) = densest, count >= 30 {
                state.interval = interval
            } else {
                state.interval = .d1 // on-demand history lands daily
                model.ensureSymbolData(symbol)
            }
        }
        pane.wrappedValue = state
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

    /// 1y / 2y / 5y / all — sets the visible span (and a sane bar size:
    /// daily for 1-2y, weekly for 5y/all), pinned to the live edge.
    private func applyRange(_ range: ChartRange) {
        selectedRange = range
        setInterval(.d1)
        weeklyMode = range.weekly
        // The connect snapshot often beats the engine's 5y daily backfill,
        // leaving the D1 series short — ask for depth before framing
        // ("all" requests the full 5y backfill).
        model.ensureDepth(
            symbol: displaySymbol, spanMs: range.spanMs ?? 1_826 * 86_400_000
        )
        frameRange(range)
    }

    /// The framing math alone — safe to re-run as deeper bars land.
    private func frameRange(_ range: ChartRange) {
        let series = weeklyMode
            ? ChartMath.aggregateWeekly(model.bars(displaySymbol, .d1))
            : model.bars(displaySymbol, .d1)
        let count = ChartMath.barsWithin(
            spanMs: range.spanMs, bars: series,
            nowMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        // Series present: frame the window. Still backfilling: show what
        // arrives (the reset handlers keep the live edge pinned).
        interaction.applyRange(barCount: max(count, 20))
    }

    /// A manual interval pick drops any range preset's wide window back to the
    /// default zoom (the range flow sets its own width through applyRange, so
    /// it stays untouched). Order matches the old inline picker: state first,
    /// interval last.
    private func pickInterval(_ iv: Interval) {
        selectedRange = nil
        weeklyMode = false
        interaction.resetZoomToDefault()
        setInterval(iv)
    }

    /// Weekly rides on the 1d feed; the 1d chip deselects while on.
    private func pickWeekly() {
        selectedRange = nil
        interaction.resetZoomToDefault()
        setInterval(.d1)
        weeklyMode = true
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

// MARK: - Live price label (isolated tick target)

/// The flashing last-price readout. Owns its OWN flash state and is the only
/// header element that reads live market data, so a price tick re-renders
/// just this label — the range / interval pickers beside it read none of it
/// and are skipped by SwiftUI when the panel body re-evaluates on a tick.
private struct LivePriceText: View {
    @Environment(AppModel.self) private var model
    let symbol: String

    @State private var flashDirection = 0
    @State private var flashToken = 0
    @State private var flashSymbol = ""

    var body: some View {
        Text(model.lastPrice(symbol).map { ChartMath.formatPrice($0, grouped: true) } ?? "—")
            .font(.system(size: 21, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(priceColor)
            .animation(.easeOut(duration: 0.2), value: flashDirection)
            .onChange(of: model.lastPrice(symbol)) { old, new in handleTick(old, new) }
            .onChange(of: symbol) { _, _ in
                // New instrument: cancel any in-flight settle and clear the tint.
                flashToken += 1
                flashDirection = 0
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
}

// MARK: - Header toolbars (isolated from market data)

/// 1y / 2y / 5y / all range presets. Reads only `selectedRange`; the model
/// work happens in `apply`, so a price tick never re-lays-out these chips.
private struct RangePicker: View {
    @Binding var selectedRange: ChartRange?
    let apply: (ChartRange) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ChartRange.allCases) { range in
                IntervalChip(label: range.label, isOn: selectedRange == range) {
                    apply(range)
                }
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
}

/// Bar-size picker (plus the weekly aggregate chip). Reads only the selected
/// interval + weekly flag — never bars / price — so it holds its layout
/// across the tick storm.
private struct IntervalPicker: View {
    let selectedInterval: Interval
    let weeklyMode: Bool
    let pick: (Interval) -> Void
    let pickWeekly: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Interval.allCases) { iv in
                IntervalChip(label: iv.label, isOn: !weeklyMode && selectedInterval == iv) {
                    pick(iv)
                }
            }
            IntervalChip(label: "1w", isOn: weeklyMode) { pickWeekly() }
        }
        .padding(2)
        .background(Theme.ink)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(Theme.line, lineWidth: Theme.hairline)
        )
    }
}

/// One text chip shared by the range + interval pickers. Unchanged styling
/// from the former `intervalChip` helper.
private struct IntervalChip: View {
    let label: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
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
}
