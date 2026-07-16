// Scanner verdict + summary tests: the plain-language ScanVerdict labeler
// across a crafted row for every label (including Neutral and the noise
// band), the default vs. details column sets, the summary column sort, and
// the persisted-toggle key contract.

import SwiftUI
import XCTest
@testable import CortexX

final class ScannerVerdictTests: XCTestCase {
    // MARK: - Row factory (covers every field the labeler reads)

    private func row(
        _ symbol: String = "X",
        composite: Double = 50,
        momentum: Double = 50,
        trend: Double = 50,
        breakout: Double = 50,
        meanrev: Double = 50,
        vol: Double = 50,
        rsi: Double? = 50,
        zscore: Double? = nil,
        dist: Double? = nil,
        ret1m: Double? = nil,
        ret3m: Double? = nil,
        flags: [String] = [],
        regime: RegimeState? = nil
    ) -> ScanRow {
        ScanRow(
            symbol: symbol, asset_class: symbol.contains("-") ? "crypto" : "equity",
            composite: composite, momentum: momentum, trend: trend, breakout: breakout,
            meanrev: meanrev, vol_state: vol, rsi_14: rsi, zscore_20: zscore,
            kalman_tstat: nil, ret_1w: nil, ret_1m: ret1m, ret_3m: ret3m,
            dist_52w_high: dist, vol_surge: nil, regime: regime, flags: flags,
            last_close: 100
        )
    }

    private func classify(_ r: ScanRow) -> ScanVerdict { ScanVerdict.classify(r) }

    // MARK: - Verdict: one crafted row per label

    func testOversoldBounceFromFlag() {
        // The NKE fixture: beaten down, high mean-revert, oversold flag.
        let v = classify(row(
            "NKE", composite: 18, momentum: 9, trend: 12, breakout: 8, meanrev: 93,
            vol: 40, rsi: 28.4, zscore: -2.31, flags: ["oversold bounce"], regime: .bear
        ))
        XCTAssertEqual(v.label, "Oversold bounce")
        XCTAssertEqual(v.lead, .meanRev)
        XCTAssertEqual(v.tone, .up)
    }

    func testOversoldBounceFromDeepRSI() {
        // No flag, but a deeply oversold RSI alone qualifies.
        let v = classify(row(meanrev: 50, rsi: 28))
        XCTAssertEqual(v.label, "Oversold bounce")
    }

    func testOversoldBounceFromScoresOnly() {
        // No flag, RSI mid — strong mean-revert under a weak trend qualifies.
        let v = classify(row(momentum: 35, trend: 25, meanrev: 75, rsi: 55))
        XCTAssertEqual(v.label, "Oversold bounce")
    }

    func testBreakoutFromFlag() {
        // The NVDA fixture: new highs, breakout flag — Breakout beats the
        // strong-uptrend / overheated reads.
        let v = classify(row(
            "NVDA", composite: 91.4, momentum: 96, trend: 88, breakout: 94, meanrev: 22,
            vol: 81, rsi: 71.2, zscore: 1.84, dist: 0.012,
            flags: ["new 52w high", "volume spike", "breakout setup"], regime: .bull
        ))
        XCTAssertEqual(v.label, "Breakout")
        XCTAssertEqual(v.lead, .breakout)
        XCTAssertEqual(v.tone, .up)
    }

    func testBreakoutFromScoreNearHigh() {
        // No flag: a strong breakout score pressing the 52w high qualifies.
        let v = classify(row(breakout: 80, rsi: 60, dist: 0.02))
        XCTAssertEqual(v.label, "Breakout")
    }

    func testBreakoutScoreWithoutNearHighDoesNotFire() {
        // Strong breakout score but no distance context → NOT a breakout.
        let v = classify(row(breakout: 80, rsi: 60, dist: nil))
        XCTAssertNotEqual(v.label, "Breakout")
    }

    func testOverheatedFromStretchedRawsAndMomentum() {
        let v = classify(row(
            momentum: 88, trend: 65, breakout: 50, meanrev: 8, rsi: 84, zscore: 2.8
        ))
        XCTAssertEqual(v.label, "Overheated")
        XCTAssertEqual(v.lead, .momentum)
        XCTAssertEqual(v.tone, .down)
    }

    func testOverheatedFromExtremeMomentumNoRaws() {
        // RSI / z absent — extreme momentum with no mean-revert pull left is
        // still overheated.
        let v = classify(row(momentum: 90, trend: 60, breakout: 40, meanrev: 10, rsi: nil))
        XCTAssertEqual(v.label, "Overheated")
    }

    func testStrongUptrendFromScores() {
        let v = classify(row(
            momentum: 74, trend: 82, breakout: 55, meanrev: 30, rsi: 62, zscore: 1.2,
            regime: .bull
        ))
        XCTAssertEqual(v.label, "Strong uptrend")
        XCTAssertEqual(v.lead, .trend)
        XCTAssertEqual(v.tone, .up)
    }

    func testStrongUptrendRegimeLowersTheTrendBar() {
        // trend 64 alone is below the 70 bar; a trending-up regime qualifies it.
        let up = classify(row(momentum: 58, trend: 64, breakout: 50, meanrev: 40,
                              rsi: 60, regime: .entering_bull))
        XCTAssertEqual(up.label, "Strong uptrend")
        // Same scores, no regime → NOT a strong uptrend (falls to Neutral).
        let none = classify(row(momentum: 58, trend: 64, breakout: 50, meanrev: 40, rsi: 60))
        XCTAssertEqual(none.label, "Neutral")
    }

    func testCoolingOffTrendHighMomentumFaded() {
        let v = classify(row(momentum: 30, trend: 75, breakout: 40, meanrev: 45, rsi: 45))
        XCTAssertEqual(v.label, "Cooling off")
        XCTAssertEqual(v.lead, .momentum)
        XCTAssertEqual(v.tone, .down)
    }

    func testMeanRevertSetup() {
        // High mean-revert that is NOT an oversold bounce (trend not weak).
        let v = classify(row(momentum: 55, trend: 50, breakout: 40, meanrev: 78,
                             rsi: 52, zscore: 0.5))
        XCTAssertEqual(v.label, "Mean-revert setup")
        XCTAssertEqual(v.lead, .meanRev)
        XCTAssertEqual(v.tone, .bone)
    }

    func testVolExpansionFromScore() {
        let v = classify(row(momentum: 55, trend: 52, breakout: 45, meanrev: 50, vol: 88, rsi: 55))
        XCTAssertEqual(v.label, "Vol expansion")
        XCTAssertEqual(v.lead, .vol)
        XCTAssertEqual(v.tone, .bone)
    }

    func testVolExpansionFromFlag() {
        let v = classify(row(momentum: 55, trend: 52, breakout: 45, meanrev: 50, vol: 50,
                             rsi: 55, flags: ["vol expansion"]))
        XCTAssertEqual(v.label, "Vol expansion")
    }

    func testNeutralAllMidBand() {
        // The BTC fixture: everything in / near the noise band.
        let v = classify(row(
            "BTC-USD", composite: 48, momentum: 51, trend: 44, breakout: 39, meanrev: 55,
            vol: 62, rsi: nil
        ))
        XCTAssertEqual(v.label, "Neutral")
        XCTAssertEqual(v.lead, .none)
        XCTAssertEqual(v.tone, .neutral)
    }

    func testNeutralNoiseBandExplicit() {
        let v = classify(row(momentum: 55, trend: 45, breakout: 58, meanrev: 42, vol: 60, rsi: 50))
        XCTAssertEqual(v.label, "Neutral")
    }

    func testClassifyIsNaNSafe() {
        // A NaN-riddled row never crashes and reads Neutral (no rule matches).
        let v = classify(row(composite: .nan, momentum: .nan, trend: .nan,
                             breakout: .nan, meanrev: .nan, vol: .nan, rsi: .nan))
        XCTAssertEqual(v.label, "Neutral")
    }

    // MARK: - Priority ordering (the tricky collisions)

    func testBreakoutBeatsOverheatedOnFreshHighs() {
        // High momentum + overbought RSI would read "Overheated" — but a
        // fresh breakout flag wins (the more actionable read).
        let v = classify(row(momentum: 90, trend: 80, breakout: 92, rsi: 82, zscore: 2.4,
                             dist: 0.005, flags: ["breakout setup"]))
        XCTAssertEqual(v.label, "Breakout")
    }

    func testOverheatedBeatsStrongUptrend() {
        // Strong trend + momentum, but stretched with no fresh breakout →
        // Overheated, the useful warning, not "Strong uptrend".
        let v = classify(row(momentum: 88, trend: 80, breakout: 55, rsi: 85, zscore: 2.6))
        XCTAssertEqual(v.label, "Overheated")
    }

    // MARK: - Absolute-direction sanity (percentile ranks ≠ direction)

    func testStrongUptrendVetoedWhenMediumReturnFalling() {
        // The core bug: a top-ranked trend/momentum name that is actually
        // falling on 1m in a bear regime must NOT read "Strong uptrend".
        let v = classify(row(momentum: 56, trend: 72, rsi: 60, ret1m: -0.08, regime: .bear))
        XCTAssertNotEqual(v.label, "Strong uptrend")
        XCTAssertEqual(v.label, "Neutral")
    }

    func testStrongUptrendSurvivesWhenMediumReturnRising() {
        // Same ranks, but the 1m return confirms the advance → the label
        // stands (the gate only vetoes known wrong-way returns).
        let v = classify(row(momentum: 56, trend: 72, rsi: 60, ret1m: 0.05, regime: .bear))
        XCTAssertEqual(v.label, "Strong uptrend")
        XCTAssertEqual(v.tone, .up)
    }

    func testStrongUptrendUnchangedWhenReturnsAbsent() {
        // Neither 1m nor 3m present → rank-only, as before (no over-veto).
        let v = classify(row(momentum: 56, trend: 72, rsi: 60, regime: .bear))
        XCTAssertEqual(v.label, "Strong uptrend")
    }

    func testBreakoutVetoedWhenMediumReturnFalling() {
        // A breakout flag on a name down over the month is contradictory →
        // don't promise the up-toned Breakout.
        let v = classify(row(rsi: 60, ret1m: -0.05, flags: ["breakout setup"]))
        XCTAssertNotEqual(v.label, "Breakout")
    }

    func testBreakoutFallsBackToRet3mWhenNo1m() {
        // No 1m; a falling 3m still vetoes the breakout claim.
        let v = classify(row(rsi: 60, ret3m: -0.10, flags: ["breakout setup"]))
        XCTAssertNotEqual(v.label, "Breakout")
        // A rising 3m lets it through.
        let up = classify(row(rsi: 60, ret3m: 0.10, flags: ["breakout setup"]))
        XCTAssertEqual(up.label, "Breakout")
    }

    func testOversoldBounceVetoedWhenRankOnlyButRallying() {
        // The rank-only oversold path must not claim a contrarian bounce on a
        // name that is actually rallying (+10% 1m) → honest Mean-revert setup.
        let v = classify(row(momentum: 35, trend: 25, meanrev: 75, rsi: 55, ret1m: 0.10))
        XCTAssertNotEqual(v.label, "Oversold bounce")
        XCTAssertEqual(v.label, "Mean-revert setup")
        XCTAssertEqual(v.tone, .bone)
    }

    func testOversoldBounceFlagTrustedEvenWhenRallying() {
        // An explicit engine oversold flag is an absolute signal → trusted
        // regardless of the recent return.
        let v = classify(row(momentum: 35, trend: 25, meanrev: 75, rsi: 55,
                             ret1m: 0.10, flags: ["oversold"]))
        XCTAssertEqual(v.label, "Oversold bounce")
    }

    // MARK: - Tone → label color (design law)

    func testToneLabelColorObeysDesignLaw() {
        // Only the noise-band read dims; every real setup is bone — up/down
        // never colors the verdict text (green/red is money only).
        XCTAssertEqual(ScanVerdict.Tone.neutral.labelColor, Theme.dim)
        XCTAssertEqual(ScanVerdict.Tone.up.labelColor, Theme.bone)
        XCTAssertEqual(ScanVerdict.Tone.down.labelColor, Theme.bone)
        XCTAssertEqual(ScanVerdict.Tone.bone.labelColor, Theme.bone)
    }

    // MARK: - Column sets: default (summary) vs. details

    func testDefaultColumnSetIsSixReadableColumns() {
        XCTAssertEqual(
            ScanSummary.columns,
            [.symbol, .price, .change, .composite, .setup, .flag]
        )
        XCTAssertEqual(ScanSummary.columns.count, 6)
    }

    func testDetailsColumnSetIsTheFullPercentileGrid() {
        // The opt-in details view keeps the full 16-column grid.
        XCTAssertEqual(ScanColumn.allCases.count, 16)
    }

    func testSummarySortabilityMatchesDesign() {
        XCTAssertTrue(ScanSummary.Column.symbol.sortable)
        XCTAssertTrue(ScanSummary.Column.price.sortable)
        XCTAssertTrue(ScanSummary.Column.change.sortable)
        XCTAssertTrue(ScanSummary.Column.composite.sortable)
        XCTAssertFalse(ScanSummary.Column.setup.sortable)
        XCTAssertFalse(ScanSummary.Column.flag.sortable)
    }

    // MARK: - Summary sort

    private func priceMap(_ px: [String: Double]) -> (ScanRow) -> Double? { { px[$0.symbol] } }

    func testSummarySortSymbolBothDirections() {
        let rows = [row("NKE"), row("AAPL"), row("MSFT")]
        let asc = ScanSummary.sorted(rows, by: .init(column: .symbol, ascending: true),
                                     price: { _ in nil }, change: { _ in nil })
        XCTAssertEqual(asc.map(\.symbol), ["AAPL", "MSFT", "NKE"])
        let desc = ScanSummary.sorted(rows, by: .init(column: .symbol, ascending: false),
                                      price: { _ in nil }, change: { _ in nil })
        XCTAssertEqual(desc.map(\.symbol), ["NKE", "MSFT", "AAPL"])
    }

    func testSummarySortComposite() {
        let rows = [row("A", composite: 30), row("B", composite: 90), row("C", composite: 60)]
        let desc = ScanSummary.sorted(rows, by: .init(column: .composite, ascending: false),
                                      price: { _ in nil }, change: { _ in nil })
        XCTAssertEqual(desc.map(\.symbol), ["B", "C", "A"])
    }

    func testSummarySortPriceNilLastBothDirections() {
        let rows = [row("NIL"), row("HI"), row("LO")]
        let px: [String: Double] = ["HI": 200, "LO": 20] // NIL has no price
        let desc = ScanSummary.sorted(rows, by: .init(column: .price, ascending: false),
                                      price: priceMap(px), change: { _ in nil })
        XCTAssertEqual(desc.map(\.symbol), ["HI", "LO", "NIL"])
        let asc = ScanSummary.sorted(rows, by: .init(column: .price, ascending: true),
                                     price: priceMap(px), change: { _ in nil })
        XCTAssertEqual(asc.map(\.symbol), ["LO", "HI", "NIL"])
    }

    func testSummarySortChangeUsesInjectedClosureNilLast() {
        let rows = [row("UP"), row("DN"), row("NIL")]
        let chg: [String: Double] = ["UP": 5.1, "DN": -3.2]
        let desc = ScanSummary.sorted(rows, by: .init(column: .change, ascending: false),
                                      price: { _ in nil }, change: { chg[$0.symbol] })
        XCTAssertEqual(desc.map(\.symbol), ["UP", "DN", "NIL"])
    }

    func testSummarySortNonFiniteSinksToBottom() {
        let rows = [row("NAN"), row("OK")]
        let px: [String: Double] = ["NAN": .nan, "OK": 100]
        let sorted = ScanSummary.sorted(rows, by: .init(column: .price, ascending: false),
                                        price: priceMap(px), change: { _ in nil })
        XCTAssertEqual(sorted.map(\.symbol), ["OK", "NAN"])
    }

    func testSummarySortSetupAndFlagAreNoOps() {
        let rows = [row("B"), row("A")]
        XCTAssertEqual(
            ScanSummary.sorted(rows, by: .init(column: .setup, ascending: true),
                               price: { _ in nil }, change: { _ in nil }).map(\.symbol),
            ["B", "A"]
        )
        XCTAssertEqual(
            ScanSummary.sorted(rows, by: .init(column: .flag, ascending: false),
                               price: { _ in nil }, change: { _ in nil }).map(\.symbol),
            ["B", "A"]
        )
    }

    func testSummarySortNilSortIsIdentity() {
        let rows = [row("B"), row("A"), row("C")]
        XCTAssertEqual(
            ScanSummary.sorted(rows, by: nil, price: { _ in nil }, change: { _ in nil }).map(\.symbol),
            ["B", "A", "C"]
        )
    }

    func testSummarySortTogglingStartsUsefulThenFlips() {
        // Numeric columns start big-first (descending).
        let first = ScanSummary.Sort.toggling(nil, column: .composite)
        XCTAssertEqual(first, .init(column: .composite, ascending: false))
        let second = ScanSummary.Sort.toggling(first, column: .composite)
        XCTAssertEqual(second, .init(column: .composite, ascending: true))
        // Symbol starts A-first (ascending).
        let symbol = ScanSummary.Sort.toggling(second, column: .symbol)
        XCTAssertEqual(symbol, .init(column: .symbol, ascending: true))
    }

    // MARK: - Persisted-toggle key contract

    func testScanPrefKeysAreStable() {
        // The raw @AppStorage keys the view binds to — stable so saved
        // posture survives across sessions.
        XCTAssertEqual(ScanPrefs.details, "scannerDetails")
        XCTAssertEqual(ScanPrefs.showAlerts, "scannerShowAlerts")
        XCTAssertEqual(ScanPrefs.showAIPicks, "scannerShowAIPicks")
    }

    func testScanPrefTogglesPersistUnderRawKeys() {
        let suite = "cortexx.tests.scanner.prefs"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        // Absent keys read as the calm defaults (@AppStorage treats a missing
        // bool as false).
        XCTAssertNil(defaults.object(forKey: ScanPrefs.details))
        XCTAssertNil(defaults.object(forKey: ScanPrefs.showAlerts))
        XCTAssertNil(defaults.object(forKey: ScanPrefs.showAIPicks))

        // Writing the raw keys round-trips true.
        defaults.set(true, forKey: ScanPrefs.details)
        defaults.set(true, forKey: ScanPrefs.showAlerts)
        defaults.set(true, forKey: ScanPrefs.showAIPicks)
        let reloaded = UserDefaults(suiteName: suite)!
        XCTAssertTrue(reloaded.bool(forKey: ScanPrefs.details))
        XCTAssertTrue(reloaded.bool(forKey: ScanPrefs.showAlerts))
        XCTAssertTrue(reloaded.bool(forKey: ScanPrefs.showAIPicks))
        defaults.removePersistentDomain(forName: suite)
    }
}
