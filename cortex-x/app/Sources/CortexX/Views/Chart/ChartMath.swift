// Pure chart math — indicators, axis stepping, visible-window arithmetic and
// adaptive number formatting. Foundation-only; unit-tested in isolation.

import Foundation

enum ChartMath {

    // MARK: - Visible window

    static let minVisibleBars: Double = 20
    static let maxVisibleBars: Double = 1_500
    static let defaultVisibleBars: Double = 160

    /// Largest right-edge offset (bars back from the latest bar) that still
    /// keeps the window against the oldest data.
    static func maxRightOffset(total: Int, barsVisible: Double) -> Double {
        max(0, Double(total) - barsVisible)
    }

    static func clampOffset(_ offset: Double, total: Int, barsVisible: Double) -> Double {
        min(max(0, offset), maxRightOffset(total: total, barsVisible: barsVisible))
    }

    /// Indices of bars intersecting the visible window. `rightOffset` is the
    /// (possibly fractional) number of bars the right edge sits behind the
    /// latest bar; 0 means live-following.
    static func visibleRange(total: Int, barsVisible: Double, rightOffset: Double) -> Range<Int> {
        guard total > 0, barsVisible >= 1 else { return 0..<0 }
        let right = Double(total - 1) - rightOffset
        let left = right - (barsVisible - 1)
        let lo = max(0, Int(left.rounded(.down)))
        let hi = min(total - 1, Int(right.rounded(.up)))
        guard lo <= hi else { return 0..<0 }
        return lo..<(hi + 1)
    }

    /// Rescale the window by `factor` (> 1 zooms out) about `anchor`
    /// (0 = left edge, 1 = right edge): the bar under the anchor keeps its
    /// on-screen fraction. Clamped to 20...1500 bars and available history.
    static func zoom(
        barsVisible: Double, rightOffset: Double, factor: Double, anchor: Double, total: Int
    ) -> (barsVisible: Double, rightOffset: Double) {
        let newCount = min(max(barsVisible * factor, minVisibleBars), maxVisibleBars)
        guard total > 0 else { return (newCount, 0) }
        let f = min(max(anchor, 0), 1)
        let right = Double(total - 1) - rightOffset
        let anchorIdx = right - (1 - f) * (barsVisible - 1)
        let newRight = anchorIdx + (1 - f) * (newCount - 1)
        let newOffset = clampOffset(Double(total - 1) - newRight, total: total, barsVisible: newCount)
        return (newCount, newOffset)
    }

    // MARK: - Indicators

    /// Exponential moving average seeded with the SMA of the first `period`
    /// values; indices before `period - 1` are nil (warm-up).
    static func ema(_ values: [Double], period: Int) -> [Double?] {
        guard period > 0, values.count >= period else {
            return [Double?](repeating: nil, count: values.count)
        }
        var out = [Double?](repeating: nil, count: values.count)
        let k = 2.0 / (Double(period) + 1.0)
        var acc = values[0..<period].reduce(0, +) / Double(period)
        out[period - 1] = acc
        for i in period..<values.count {
            acc = (values[i] - acc) * k + acc
            out[i] = acc
        }
        return out
    }

    /// Wilder's RSI. First defined value at index `period`. A flat series
    /// (no gains, no losses) reads 50.
    static func rsi(_ values: [Double], period: Int = 14) -> [Double?] {
        guard period > 0, values.count > period else {
            return [Double?](repeating: nil, count: values.count)
        }
        var out = [Double?](repeating: nil, count: values.count)
        var gain = 0.0
        var loss = 0.0
        for i in 1...period {
            let d = values[i] - values[i - 1]
            if d >= 0 { gain += d } else { loss -= d }
        }
        var avgGain = gain / Double(period)
        var avgLoss = loss / Double(period)
        out[period] = rsiValue(avgGain, avgLoss)
        for i in (period + 1)..<values.count {
            let d = values[i] - values[i - 1]
            avgGain = (avgGain * Double(period - 1) + max(d, 0)) / Double(period)
            avgLoss = (avgLoss * Double(period - 1) + max(-d, 0)) / Double(period)
            out[i] = rsiValue(avgGain, avgLoss)
        }
        return out
    }

    private static func rsiValue(_ avgGain: Double, _ avgLoss: Double) -> Double {
        if avgLoss == 0 { return avgGain == 0 ? 50 : 100 }
        return 100 - 100 / (1 + avgGain / avgLoss)
    }

    struct BollingerPoint: Equatable {
        var mid: Double
        var upper: Double
        var lower: Double
    }

    /// Bollinger bands: SMA(period) +/- k * population standard deviation.
    static func bollinger(_ values: [Double], period: Int = 20, k: Double = 2) -> [BollingerPoint?] {
        guard period > 0, values.count >= period else {
            return [BollingerPoint?](repeating: nil, count: values.count)
        }
        var out = [BollingerPoint?](repeating: nil, count: values.count)
        let n = Double(period)
        for i in (period - 1)..<values.count {
            let window = values[(i - period + 1)...i]
            let mean = window.reduce(0, +) / n
            let variance = window.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
            let sd = variance.squareRoot()
            out[i] = BollingerPoint(mid: mean, upper: mean + k * sd, lower: mean - k * sd)
        }
        return out
    }

    /// MACD(12, 26, 9): macd = EMA12 - EMA26, signal = EMA9 of the macd line,
    /// hist = macd - signal. Each series stays nil until its inputs are warm
    /// (macd from index 25, signal and hist from index 33).
    static func macdSeries(closes: [Double]) -> (macd: [Double?], signal: [Double?], hist: [Double?]) {
        let count = closes.count
        let fast = ema(closes, period: 12)
        let slow = ema(closes, period: 26)
        var macd = [Double?](repeating: nil, count: count)
        for i in 0..<count {
            if let f = fast[i], let s = slow[i] { macd[i] = f - s }
        }
        var signal = [Double?](repeating: nil, count: count)
        var hist = [Double?](repeating: nil, count: count)
        if let start = macd.firstIndex(where: { $0 != nil }) {
            // macd is contiguous once defined, so the ?? never substitutes.
            let defined = macd[start...].map { $0 ?? 0 }
            let sig = ema(defined, period: 9)
            for (j, s) in sig.enumerated() {
                guard let s else { continue }
                signal[start + j] = s
                if let m = macd[start + j] { hist[start + j] = m - s }
            }
        }
        return (macd, signal, hist)
    }

    // MARK: - Axis

    /// A "nice" step (1 / 2 / 2.5 / 5 x 10^n) — the smallest nice value that
    /// yields at most `target` divisions over `range`.
    static func niceStep(range: Double, target: Int) -> Double {
        guard range > 0, target > 0 else { return 1 }
        let raw = range / Double(target)
        let mag = pow(10, floor(log10(raw)))
        let norm = raw / mag
        let nice: Double
        if norm <= 1 { nice = 1 } else if norm <= 2 { nice = 2 } else if norm <= 2.5 {
            nice = 2.5
        } else if norm <= 5 { nice = 5 } else { nice = 10 }
        return nice * mag
    }

    /// Tick values inside [lo, hi] on multiples of the nice step.
    static func axisTicks(min lo: Double, max hi: Double, target: Int = 6) -> [Double] {
        guard hi > lo else { return [] }
        let step = niceStep(range: hi - lo, target: target)
        var t = (lo / step).rounded(.up) * step
        var out: [Double] = []
        while t <= hi + step * 1e-9 {
            out.append(t)
            t += step
        }
        return out
    }

    /// Mantissa ladders for log-axis ticks, densest first. Each entry
    /// subdivides a decade; a ladder qualifies when its tightest adjacent
    /// pair (in log10 units, including the wrap up to the next decade) still
    /// clears the minimum on-screen gap.
    private static let logMantissaLadders: [[Double]] = [
        [1, 1.2, 1.4, 1.6, 1.8, 2, 2.5, 3, 3.5, 4, 5, 6, 7, 8, 9],
        [1, 1.5, 2, 3, 4, 5, 7],
        [1, 2, 5],
    ]

    private static func tightestLogGap(_ mantissas: [Double]) -> Double {
        guard let last = mantissas.last, let first = mantissas.first else { return 1 }
        var g = 1 + log10(first) - log10(last) // wrap to the next decade
        for i in 1..<mantissas.count {
            g = min(g, log10(mantissas[i] / mantissas[i - 1]))
        }
        return g
    }

    /// Tick values for a log10 price axis inside [lo, hi]: 1 / 2 / 5 x 10^n
    /// per decade, subdivided (or thinned to whole decades) so adjacent
    /// ticks map at least `minGapPx` apart over `heightPx`. Falls back to
    /// the linear ticks when the range is too tight for the log ladder to
    /// place two ticks. Empty when the axis cannot support log (lo <= 0).
    static func logAxisTicks(
        min lo: Double, max hi: Double, heightPx: Double, minGapPx: Double = 44
    ) -> [Double] {
        guard lo > 0, hi > lo, heightPx.isFinite, heightPx > 0, minGapPx > 0 else { return [] }
        let lLo = log10(lo)
        let lHi = log10(hi)
        let pxPerDecade = heightPx / (lHi - lLo)
        guard pxPerDecade.isFinite, pxPerDecade > 0 else { return [] }

        var mantissas: [Double] = [1]
        var decadeStride = 1
        if let dense = logMantissaLadders.first(
            where: { tightestLogGap($0) * pxPerDecade >= minGapPx }
        ) {
            mantissas = dense
        } else if pxPerDecade < minGapPx {
            // Even bare decades sit too close: stride whole decades apart.
            decadeStride = Int((minGapPx / pxPerDecade).rounded(.up))
        }

        var out: [Double] = []
        let d0 = Int(lLo.rounded(.down))
        let d1 = Int(lHi.rounded(.up))
        var d = decadeStride > 1
            ? Int((Double(d0) / Double(decadeStride)).rounded(.down)) * decadeStride
            : d0
        while d <= d1 {
            let base = pow(10, Double(d))
            for m in mantissas {
                let v = m * base
                if v >= lo * (1 - 1e-9), v <= hi * (1 + 1e-9) { out.append(v) }
            }
            d += decadeStride
        }
        // A sub-decade window can starve the ladder; linear ticks read
        // better than a single lonely label.
        if out.count < 2 {
            return axisTicks(min: lo, max: hi, target: max(3, Int(heightPx / minGapPx)))
        }
        return out
    }

    // MARK: - Price-axis mapping (linear / log)

    /// Fraction of `p` within [lo, hi] (0 = lo, 1 = hi) on the price axis.
    /// `log` maps through log10; it silently falls back to linear whenever
    /// the axis cannot support it (lo <= 0 or p <= 0), so callers never see
    /// NaN. Log-mode tick VALUES come from `logAxisTicks`.
    static func priceFraction(_ p: Double, lo: Double, hi: Double, log: Bool) -> Double {
        guard hi > lo else { return 0 }
        if log, lo > 0, p > 0 {
            return (log10(p) - log10(lo)) / (log10(hi) - log10(lo))
        }
        return (p - lo) / (hi - lo)
    }

    /// Inverse of `priceFraction` (crosshair y -> price readout). Same
    /// linear fallback when lo <= 0.
    static func priceAtFraction(_ f: Double, lo: Double, hi: Double, log: Bool) -> Double {
        guard hi > lo else { return lo }
        if log, lo > 0 {
            let l = log10(lo)
            return pow(10, l + f * (log10(hi) - l))
        }
        return lo + f * (hi - lo)
    }

    // MARK: - US equity sessions (extended hours)

    /// US/Eastern calendar for session math. Fixed zone identifier, so DST
    /// transitions resolve correctly for any timestamp via Foundation.
    private static let easternCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")
            ?? TimeZone(secondsFromGMT: -5 * 3600)!
        return c
    }()

    /// Regular trading hours as minutes-since-midnight ET: 09:30 ..< 16:00.
    private static let rthMinutes: Range<Int> = 570..<960

    /// True when the US/Eastern time-of-day of `tsMs` falls outside regular
    /// trading hours (09:30-16:00 ET) — pre-market, after-hours, overnight.
    /// Classifies by the instant itself (charts pass the bar-open), and is
    /// DST-correct because the calendar resolves the ET offset per date.
    static func isExtendedHours(_ tsMs: Int64) -> Bool {
        let date = Date(timeIntervalSince1970: Double(tsMs) / 1000)
        let hm = easternCalendar.dateComponents([.hour, .minute], from: date)
        let minutes = (hm.hour ?? 0) * 60 + (hm.minute ?? 0)
        return !rthMinutes.contains(minutes)
    }

    /// Session-day key (yyyymmdd) of the US/Eastern calendar day containing
    /// `tsMs` — "which session is it now". DST-correct via the calendar.
    static func easternDayKey(_ tsMs: Int64) -> Int {
        dayKey(tsMs, calendar: easternCalendar)
    }

    /// Session-day key (yyyymmdd) of the UTC calendar day containing `tsMs`.
    /// Equity D1 bar-opens are UTC-midnight bucketed and their UTC date IS
    /// the US session date, so D1 bars key through this (an ET conversion
    /// of a UTC midnight would land on the prior evening).
    static func utcDayKey(_ tsMs: Int64) -> Int {
        dayKey(tsMs, calendar: utcCalendar)
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    private static func dayKey(_ tsMs: Int64, calendar: Calendar) -> Int {
        let date = Date(timeIntervalSince1970: Double(tsMs) / 1000)
        let ymd = calendar.dateComponents([.year, .month, .day], from: date)
        return (ymd.year ?? 0) * 10_000 + (ymd.month ?? 0) * 100 + (ymd.day ?? 0)
    }

    /// Extended-hours shading (and its ext toggle) apply only to an equity's
    /// intraday chart: a bare ticker (no "-" pair ⇒ equity, matching
    /// `AppModel.isEquity`), a sub-daily interval, and not the weekly view.
    /// D1 and weekly bars are whole RTH sessions with nothing to shade, and
    /// crypto ("-" pairs) trades round the clock. Drives the extended-hours
    /// toggle for every sub-daily equity interval; the narrower
    /// `showsNoIntradayDataNotice` gate decides when an empty series is a
    /// feed gap rather than a still-loading state.
    static func isEquityIntraday(symbol: String, interval: Interval, weekly: Bool) -> Bool {
        !weekly && interval != .d1 && !symbol.contains("-")
    }

    /// Gates the "no <interval> bars" notice. The delayed CBOE feed carries
    /// only D1 / H1 / M5, so an empty *sub-5-minute* equity series (s1 / m1)
    /// is a missing-feed state that must not read as a frozen chart. M5 / M15
    /// / H1 empties are still forming and fall back to the waiting state —
    /// naming them here would contradict the notice copy, which lists 5-min
    /// among the provided intervals.
    static func showsNoIntradayDataNotice(symbol: String, interval: Interval, weekly: Bool) -> Bool {
        isEquityIntraday(symbol: symbol, interval: interval, weekly: weekly)
            && interval.ms < Interval.m5.ms
    }

    // MARK: - Time & buckets

    /// One 7-day bar span in milliseconds — the view-level weekly bar width.
    static let weekMs: Int64 = 7 * 86_400_000

    /// The epoch (1970-01-01) is a Thursday; 1970-01-05 (epoch + 4 days) is
    /// the first Monday, so week floors anchor against that offset.
    private static let mondayEpochOffsetMs: Int64 = 4 * 86_400_000

    /// Floor a timestamp to its bar-open for the interval.
    static func bucket(_ tsMs: Int64, _ interval: Interval) -> Int64 {
        tsMs - tsMs % interval.ms
    }

    /// Floor a timestamp to its bar-open for an arbitrary bar span. The
    /// weekly span floors to Monday-anchored weeks (matching
    /// `aggregateWeekly`); every other span floors from the epoch.
    static func bucket(_ tsMs: Int64, spanMs: Int64) -> Int64 {
        guard spanMs > 0 else { return tsMs }
        if spanMs == weekMs { return weekFloor(tsMs) }
        return tsMs - tsMs % spanMs
    }

    /// Floor a timestamp to the Monday 00:00 UTC opening its trading week.
    /// Floored modulo, so pre-1970 timestamps still round downward.
    static func weekFloor(_ tsMs: Int64) -> Int64 {
        var r = (tsMs - mondayEpochOffsetMs) % weekMs
        if r < 0 { r += weekMs }
        return tsMs - r
    }

    /// Aggregate a daily series into Monday-anchored 7-day buckets
    /// (view-level weekly bars; there is no wire-protocol weekly interval,
    /// so the result keeps `.d1`). open = first open, high = max, low = min,
    /// close = last close, volume / trade_count = sums, vwap = close,
    /// complete only when every member bar is complete. Input is assumed
    /// ascending by ts_open_ms.
    static func aggregateWeekly(_ d1: [Bar]) -> [Bar] {
        var out: [Bar] = []
        out.reserveCapacity(d1.count / 5 + 1)
        for bar in d1 {
            let open = weekFloor(bar.ts_open_ms)
            if var acc = out.last, acc.ts_open_ms == open {
                acc.high = max(acc.high, bar.high)
                acc.low = min(acc.low, bar.low)
                acc.close = bar.close
                acc.volume += bar.volume
                acc.trade_count += bar.trade_count
                acc.vwap = bar.close
                acc.complete = acc.complete && bar.complete
                out[out.count - 1] = acc
            } else {
                var acc = bar
                acc.ts_open_ms = open
                acc.interval = .d1
                acc.vwap = bar.close
                out.append(acc)
            }
        }
        return out
    }

    /// Axis label: HH:mm intraday, dd MMM for daily bars.
    static func timeLabel(_ tsMs: Int64, interval: Interval) -> String {
        let date = Date(timeIntervalSince1970: Double(tsMs) / 1000)
        return interval == .d1 ? dayFormatter.string(from: date) : clockFormatter.string(from: date)
    }

    /// Crosshair readout timestamp — fuller than the axis label.
    static func readoutTimeLabel(_ tsMs: Int64, interval: Interval) -> String {
        let date = Date(timeIntervalSince1970: Double(tsMs) / 1000)
        return interval == .d1
            ? readoutDayFormatter.string(from: date)
            : readoutClockFormatter.string(from: date)
    }

    private static let clockFormatter = makeFormatter("HH:mm")
    private static let dayFormatter = makeFormatter("dd MMM")
    private static let readoutClockFormatter = makeFormatter("dd MMM HH:mm:ss")
    private static let readoutDayFormatter = makeFormatter("dd MMM yyyy")

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    // MARK: - Formatting

    /// Adaptive price format: >= 100 -> 2dp; >= 1 -> 2-4dp (trailing zeros
    /// trimmed to 2dp); < 1 -> 4 significant digits.
    static func formatPrice(_ v: Double, grouped: Bool = false) -> String {
        guard v.isFinite else { return "—" }
        let a = abs(v)
        if a >= 100 {
            if grouped, let s = groupedFormatter.string(from: NSNumber(value: v)) { return s }
            return String(format: "%.2f", v)
        }
        if a >= 1 {
            var s = String(format: "%.4f", v)
            while s.hasSuffix("0"), let dot = s.firstIndex(of: "."),
                s.distance(from: dot, to: s.endIndex) > 3 {
                s.removeLast()
            }
            return s
        }
        if a == 0 { return "0.00" }
        let decimals = min(10, 3 - Int(floor(log10(a))))
        return String(format: "%.\(decimals)f", v)
    }

    /// Signed variant for deltas ("+1.25" / "-0.4012").
    static func formatSigned(_ v: Double) -> String {
        (v >= 0 ? "+" : "") + formatPrice(v)
    }

    /// Compact volume: 1.23B / 4.56M / 12.3k.
    static func formatVolume(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        let a = abs(v)
        switch a {
        case 1_000_000_000...: return String(format: "%.2fB", v / 1_000_000_000)
        case 1_000_000...: return String(format: "%.2fM", v / 1_000_000)
        case 10_000...: return String(format: "%.1fk", v / 1_000)
        case 1_000...: return String(format: "%.2fk", v / 1_000)
        case 10...: return String(format: "%.0f", v)
        default: return String(format: "%.2f", v)
        }
    }

    private static let groupedFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()
}

// MARK: - Range presets (1y / 2y / 5y / all)

/// Visible-span presets for the chart header. Intervals set bar SIZE; a
/// range sets how much history is in view (and picks a sane bar size).
enum ChartRange: String, CaseIterable, Identifiable {
    case y1, y2, y5, all
    var id: String { rawValue }

    var label: String {
        switch self {
        case .y1: "1y"
        case .y2: "2y"
        case .y5: "5y"
        case .all: "all"
        }
    }

    /// Calendar span in ms; nil = everything available.
    var spanMs: Int64? {
        switch self {
        case .y1: 365 * 86_400_000
        case .y2: 730 * 86_400_000
        case .y5: 1_826 * 86_400_000
        case .all: nil
        }
    }

    /// Long ranges read better on weekly candles; 1-2y stay daily.
    var weekly: Bool {
        switch self {
        case .y1, .y2: false
        case .y5, .all: true
        }
    }
}

extension ChartMath {
    /// Bars whose open falls inside the trailing `spanMs` window ending at
    /// `nowMs`. Bars are ascending; nil span means the whole series.
    static func barsWithin(spanMs: Int64?, bars: [Bar], nowMs: Int64) -> Int {
        guard let spanMs else { return bars.count }
        let cutoff = nowMs - spanMs
        // Binary search for the first bar at/after the cutoff.
        var lo = 0, hi = bars.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if bars[mid].ts_open_ms < cutoff { lo = mid + 1 } else { hi = mid }
        }
        return bars.count - lo
    }
}
