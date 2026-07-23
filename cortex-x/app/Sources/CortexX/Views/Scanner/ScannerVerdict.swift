// SCANNER verdict + summary model — the calm layer over the dense percentile
// grid. `ScanVerdict.classify` turns the abstract 0-100 driver percentiles
// (plus flags and regime) into ONE plain-language setup label so the operator
// reads meaning, not math. `ScanSummary` is the six-column default table.
// Everything here is pure and testable; the view only renders it.

import SwiftUI

// MARK: - Verdict

/// Which driver most justifies a row's verdict — the "why" behind the label.
enum ScanDriver: String, Equatable, Codable {
    case momentum, trend, breakout, meanRev, vol, none

    var title: String {
        switch self {
        case .momentum: "momentum"
        case .trend: "trend"
        case .breakout: "breakout"
        case .meanRev: "mean-rev"
        case .vol: "volatility"
        case .none: ""
        }
    }
}

/// A plain-language read of one scan row: a short label, the driver that
/// leads it, and a directional tone. The tone is honest metadata (which way
/// the setup leans / where the risk skews) — under design law the label TEXT
/// only ever renders bone (a real setup) or dim (the noise-band Neutral);
/// up/down never colors the label (green/red is reserved for money). The raw
/// tone rides along for a genuinely directional cell that wants it.
struct ScanVerdict: Equatable {
    enum Tone: Equatable {
        case up      // bullish lean (uptrend, breakout, bounce)
        case down    // bearish lean / reversion risk (overheated, cooling)
        case bone    // real setup, direction not asserted (vol / mean-rev)
        case neutral // nothing to see — the 40-60 noise band

        /// Verdict-label color under design law: the noise-band read is dim,
        /// every real setup is bone. up/down are deliberately NOT mapped here.
        var labelColor: Color {
            self == .neutral ? Theme.dim : Theme.bone
        }
    }

    let label: String
    let lead: ScanDriver
    let tone: Tone

    // MARK: Thresholds (percentiles are 0-100 ranks vs the universe this cycle)

    /// A driver reads "strong" at or above this percentile.
    static let strong: Double = 70
    /// A driver reads "extreme" at or above this percentile.
    static let extreme: Double = 85
    /// A driver reads "weak" at or below this percentile.
    static let weak: Double = 30
    /// RSI at or below this is deeply oversold.
    static let oversoldRSI: Double = 30
    /// RSI at or above this is overbought (a stretch signal).
    static let overboughtRSI: Double = 78
    /// A 20d z-score at or above this is stretched from the mean.
    static let stretchedZ: Double = 2.0
    /// Within this fraction of the 52w high counts as "near the high".
    static let nearHighFrac: Double = 0.03
    /// Trend must lead a faded momentum by this many percentile points to
    /// read as "cooling off" rather than simply mixed.
    static let coolingGap: Double = 25

    private static let regimeUp: Set<RegimeState> = [.bull, .entering_bull, .recovery]

    /// Classify one row. Rules are checked most-specific-first; the first
    /// match wins, and "Neutral" is a fine, common, honest answer.
    static func classify(_ row: ScanRow) -> ScanVerdict {
        func flag(_ needle: String) -> Bool {
            row.flags.contains { $0.lowercased().contains(needle) }
        }
        let breakoutFlag = flag("breakout") || flag("52w high")
        let oversoldFlag = flag("oversold")
        let volFlag = flag("vol expansion") || flag("volume")

        let nearHigh = row.dist_52w_high.map { abs($0) <= nearHighFrac } ?? false
        let deeplyOversold = row.rsi_14.map { $0 <= oversoldRSI } ?? false
        let stretched =
            (row.zscore_20.map { $0 >= stretchedZ } ?? false)
            || (row.rsi_14.map { $0 >= overboughtRSI } ?? false)
            || (row.meanrev <= 15 && row.momentum >= extreme)
        let regimeIsUp = row.regime.map(regimeUp.contains) ?? false

        // Absolute-direction sanity check. Every driver above is a purely
        // cross-sectional PERCENTILE rank — a top-ranked name in a falling
        // market still ranks high. Before an up-toned label promises a
        // direction, consult the row's own medium-horizon return (1m, else
        // 3m). When neither is present we don't veto (rank-only, as before);
        // only a *known* wrong-way return blocks the directional claim.
        let mediumReturn = row.ret_1m ?? row.ret_3m
        // "price is advancing" labels (Breakout, Strong uptrend) must not
        // fire on a name known to be falling over the medium horizon.
        let notFalling = (mediumReturn ?? 0) >= 0
        // the contrarian "Oversold bounce" up-lean asserts a beaten-down
        // name, so it must not fire on one that is actually rallying.
        let notRising = (mediumReturn ?? 0) <= 0

        // 1. Oversold bounce — beaten down and turning: an oversold flag, a
        //    deeply oversold RSI, or a strong mean-revert pull under a weak
        //    trend that isn't actually rallying. A contrarian long lean.
        if oversoldFlag || deeplyOversold
            || (row.meanrev >= strong && row.trend <= weak && row.momentum <= 40 && notRising) {
            return ScanVerdict(label: "Oversold bounce", lead: .meanRev, tone: .up)
        }
        // 2. Breakout — a fresh structural high: a breakout / new-52w-high
        //    flag, or a strong breakout score pressing the 52w high — and not
        //    a name that's actually falling over the medium horizon.
        if (breakoutFlag || (row.breakout >= strong && nearHigh)) && notFalling {
            return ScanVerdict(label: "Breakout", lead: .breakout, tone: .up)
        }
        // 3. Overheated — strong momentum stretched far from the mean (high
        //    z / RSI, or extreme momentum with no mean-revert pull left).
        //    The easy upside is spent; risk skews to a reversion.
        if row.momentum >= strong && stretched {
            return ScanVerdict(label: "Overheated", lead: .momentum, tone: .down)
        }
        // 4. Strong uptrend — trend and momentum both up (a trending-up
        //    regime lowers the trend bar), and the medium-horizon return
        //    isn't actually falling. The clean long.
        if (row.trend >= strong || (row.trend >= 60 && regimeIsUp))
            && row.momentum >= 55 && notFalling {
            return ScanVerdict(label: "Strong uptrend", lead: .trend, tone: .up)
        }
        // 5. Cooling off — still structurally up, but momentum has faded well
        //    below trend. A rolling-over lean.
        if row.trend >= 55 && row.momentum <= 45 && (row.trend - row.momentum) >= coolingGap {
            return ScanVerdict(label: "Cooling off", lead: .momentum, tone: .down)
        }
        // 6. Mean-revert setup — a strong mean-revert score that isn't an
        //    oversold bounce (caught above). Direction depends on the side.
        if row.meanrev >= strong {
            return ScanVerdict(label: "Mean-revert setup", lead: .meanRev, tone: .bone)
        }
        // 7. Vol expansion — volatility widening (a high vol_state or a vol /
        //    volume flag) with nothing directional above. Directionless.
        if row.vol_state >= strong || volFlag {
            return ScanVerdict(label: "Vol expansion", lead: .vol, tone: .bone)
        }
        // 8. Neutral — everything sits in the noise band. Nothing to see.
        return ScanVerdict(label: "Neutral", lead: .none, tone: .neutral)
    }
}

// MARK: - Summary (default) table columns

/// The calm default table: six readable columns. The full 16-column
/// percentile grid (`ScanColumn`) is the opt-in "details" view.
enum ScanSummary {
    enum Column: String, CaseIterable, Codable {
        case symbol, price, change, composite, setup, flag

        var title: String {
            switch self {
            case .symbol: "sym"
            case .price: "price"
            case .change: "chg%"
            case .composite: "composite"
            case .setup: "setup"
            case .flag: "flag"
            }
        }

        /// setup (a categorical label) and flag are not sortable.
        var sortable: Bool {
            switch self {
            case .setup, .flag: false
            default: true
            }
        }

        var alignment: Alignment {
            switch self {
            case .price, .change, .composite: .trailing
            default: .leading
            }
        }

        /// The one column that flexes to absorb the pane's remaining width so
        /// the calm summary table spans it left-to-right instead of floating at
        /// its natural width. FLAG is the last content column, so its growth
        /// pushes the trailing row action to the right edge. Every other column
        /// holds its fixed width; exactly one column fills.
        var fillsWidth: Bool {
            self == .flag
        }
    }

    /// The default column set, in display order.
    static let columns: [Column] = [.symbol, .price, .change, .composite, .setup, .flag]

    /// One sort order over the summary table.
    struct Sort: Equatable, Codable {
        var column: Column
        var ascending: Bool

        /// Repeat click flips; a fresh column starts useful (names A-first,
        /// numbers big-first).
        static func toggling(_ current: Sort?, column: Column) -> Sort {
            if let current, current.column == column {
                return Sort(column: column, ascending: !current.ascending)
            }
            return Sort(column: column, ascending: column == .symbol)
        }
    }

    /// Pure sort. Price and change come from the model via injected closures
    /// (they are not row fields), mirroring the premarket-gap pattern. nil
    /// readings sort last in BOTH directions — absent data never floats up.
    static func sorted(
        _ rows: [ScanRow], by sort: Sort?,
        price: (ScanRow) -> Double?, change: (ScanRow) -> Double?
    ) -> [ScanRow] {
        guard let sort, sort.column.sortable else { return rows }
        let asc = sort.ascending
        switch sort.column {
        case .symbol:
            return rows.sorted { asc ? $0.symbol < $1.symbol : $0.symbol > $1.symbol }
        case .composite:
            return numeric(rows, asc) { $0.composite }
        case .price:
            return numeric(rows, asc, key: price)
        case .change:
            return numeric(rows, asc, key: change)
        case .setup, .flag:
            return rows
        }
    }

    /// nil-last numeric sort shared by the value columns. nil AND non-finite
    /// readings both sink to the bottom in either direction.
    private static func numeric(
        _ rows: [ScanRow], _ ascending: Bool, key: (ScanRow) -> Double?
    ) -> [ScanRow] {
        func finite(_ row: ScanRow) -> Double? {
            guard let v = key(row), v.isFinite else { return nil }
            return v
        }
        return rows.sorted { a, b in
            switch (finite(a), finite(b)) {
            case let (x?, y?): return x == y ? false : (ascending ? x < y : x > y)
            case (_?, nil): return true
            default: return false
            }
        }
    }
}

// MARK: - Preference keys (the scanner's @AppStorage surface)

/// Raw @AppStorage keys for the scanner's persisted toggles. Exposed as
/// constants so the persistence contract is testable (and stable).
enum ScanPrefs {
    /// Swap the six-column summary for the full percentile grid. Default off.
    static let details = "scannerDetails"
    /// Show the right-side flag-transition alert strip. Default off.
    static let showAlerts = "scannerShowAlerts"
    /// Show the header AI-PICKS action. Default off.
    static let showAIPicks = "scannerShowAIPicks"
    /// The persisted DETAILS-table column layout (order + visibility), JSON.
    static let columns = "scannerColumns.v1"
}
