// Pure chart math — indicators, axis stepping, visible-window arithmetic and
// adaptive number formatting. Foundation-only; unit-tested in isolation.

import Foundation

enum ChartMath {

    // MARK: - Visible window

    static let minVisibleBars: Double = 20
    static let maxVisibleBars: Double = 500
    static let defaultVisibleBars: Double = 120

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
    /// on-screen fraction. Clamped to 20...500 bars and available history.
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

    // MARK: - Time & buckets

    /// Floor a timestamp to its bar-open for the interval.
    static func bucket(_ tsMs: Int64, _ interval: Interval) -> Int64 {
        tsMs - tsMs % interval.ms
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
