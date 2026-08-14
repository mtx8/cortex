// The TradingView-style bar-close countdown shown in the chart's right price
// axis, under the live-price tag.
//
// Two things must never go wrong here. First, the countdown has to be derived
// from the DATA — `bars.last.ts_open_ms + barSpanMs` — because the engine
// anchors equity HOURLY bars to 09:30 ET, not to the epoch hour grid; a
// client-side re-bucketing would be exactly 30 minutes wrong on every equity 1h
// chart. Second, it must appear ONLY while the newest bar is genuinely the
// current one: equity quotes arrive ~15 minutes delayed, so that bar has usually
// already closed, and a countdown there would be meaningless or negative.

import XCTest
@testable import CortexX

final class BarCountdownTests: XCTestCase {
    private let minuteMs: Int64 = 60_000
    private let hourMs: Int64 = 3_600_000
    private let dayMs: Int64 = 86_400_000

    // MARK: - Is the bar current?

    func testMidBar() {
        // 30 s into a 1-minute bar.
        XCTAssertEqual(
            ChartMath.secondsUntilBarClose(
                barOpenMs: 1_760_000_000_000, barSpanMs: minuteMs,
                nowMs: 1_760_000_000_000 + 30_000
            ),
            30
        )
        XCTAssertEqual(
            ChartMath.barCountdownText(
                symbol: "BTC-USD", interval: .m1, weekly: false,
                barOpenMs: 1_760_000_000_000, barSpanMs: minuteMs,
                nowMs: 1_760_000_000_000 + 30_000
            ),
            "00:30"
        )
    }

    func testFinalSecond() {
        let open: Int64 = 1_760_000_000_000
        // One millisecond of life left still reads a full second — the display
        // must never sit at 00:00 for a bar that has not closed.
        XCTAssertEqual(
            ChartMath.barCountdownText(
                symbol: "BTC-USD", interval: .m1, weekly: false,
                barOpenMs: open, barSpanMs: minuteMs, nowMs: open + minuteMs - 1
            ),
            "00:01"
        )
        XCTAssertEqual(
            ChartMath.barCountdownText(
                symbol: "BTC-USD", interval: .m1, weekly: false,
                barOpenMs: open, barSpanMs: minuteMs, nowMs: open + minuteMs - 1_000
            ),
            "00:01"
        )
    }

    func testExactCloseBoundaryEndsTheCountdown() {
        let open: Int64 = 1_760_000_000_000
        // The window is half-open: at the close instant the bar is no longer
        // current, so there is nothing to count down.
        XCTAssertNil(
            ChartMath.secondsUntilBarClose(
                barOpenMs: open, barSpanMs: minuteMs, nowMs: open + minuteMs
            )
        )
        XCTAssertNotNil(
            ChartMath.secondsUntilBarClose(
                barOpenMs: open, barSpanMs: minuteMs, nowMs: open + minuteMs - 1
            )
        )
    }

    func testDelayedEquityBarShowsNothing() {
        // The realistic equity case: the CBOE snapshot is ~15 minutes behind, so
        // the newest 5-minute bar closed a quarter of an hour ago. Showing a
        // countdown (or a zero) there would imply live data that isn't arriving.
        let open: Int64 = 1_760_000_000_000
        let now = open + 15 * minuteMs
        XCTAssertNil(
            ChartMath.secondsUntilBarClose(barOpenMs: open, barSpanMs: 5 * minuteMs, nowMs: now)
        )
        XCTAssertNil(
            ChartMath.barCountdownText(
                symbol: "BTC-USD", interval: .m1, weekly: false,
                barOpenMs: open, barSpanMs: 5 * minuteMs, nowMs: now)
        )
        // A whole session old, likewise.
        XCTAssertNil(
            ChartMath.secondsUntilBarClose(barOpenMs: open, barSpanMs: dayMs, nowMs: open + 9 * dayMs)
        )
    }

    func testFutureStampedBarClampsAndNeverGoesNegative() {
        // Routine engine/client clock skew stamps the bar a hair ahead of the
        // local clock. Within tolerance, clamp to the bar's own open — a full
        // span — rather than blinking the countdown out or counting up past one
        // span. BEYOND tolerance the bar is refused instead of clamped: holding a
        // full span for the length of the skew would freeze the chip, and a
        // countdown that does not count down is worse than none (see
        // testLargeClockSkewShowsNothingRatherThanFreezing).
        let now: Int64 = 1_760_000_000_000
        XCTAssertEqual(
            ChartMath.secondsUntilBarClose(barOpenMs: now + 1_000, barSpanMs: minuteMs, nowMs: now),
            60
        )
        XCTAssertEqual(
            ChartMath.barCountdownText(
                symbol: "BTC-USD", interval: .m1, weekly: false,
                barOpenMs: now + 1_000, barSpanMs: minuteMs, nowMs: now
            ),
            "01:00"
        )
        for skewMs in stride(from: Int64(1), through: ChartMath.maxCountdownSkewMs, by: 97) {
            let s = ChartMath.secondsUntilBarClose(
                barOpenMs: now + skewMs, barSpanMs: minuteMs, nowMs: now
            )
            XCTAssertEqual(s, 60, "skew \(skewMs) is within tolerance and must clamp to one span")
        }
        for skewMs in stride(
            from: ChartMath.maxCountdownSkewMs + 1, through: 5 * minuteMs, by: 997
        ) {
            XCTAssertNil(
                ChartMath.secondsUntilBarClose(
                    barOpenMs: now + skewMs, barSpanMs: minuteMs, nowMs: now
                ),
                "skew \(skewMs) exceeds tolerance and must not freeze the chip"
            )
        }
    }

    func testNonPositiveSpanIsNotCountable() {
        XCTAssertNil(
            ChartMath.secondsUntilBarClose(barOpenMs: 1_760_000_000_000, barSpanMs: 0, nowMs: 1)
        )
        XCTAssertNil(
            ChartMath.secondsUntilBarClose(barOpenMs: 1_760_000_000_000, barSpanMs: -1, nowMs: 1)
        )
    }

    // MARK: - The 09:30 ET anchor (why the bar's OWN open is the input)

    func testEquityHourlyBarUsesItsOwnOpenNotAnEpochBucket() {
        // The engine anchors equity hourly bars to 09:30 ET through the regular
        // session, so a session bar-open sits half an hour off the epoch-hour
        // grid that `ChartMath.bucket` walks.
        let epochHour = ChartMath.bucket(1_753_368_123_456, spanMs: hourMs)
        let sessionOpen = epochHour + 30 * minuteMs
        let now = sessionOpen + 10 * minuteMs

        XCTAssertEqual(
            ChartMath.barCountdownText(
                symbol: "BTC-USD", interval: .h1, weekly: false,
                barOpenMs: sessionOpen, barSpanMs: hourMs, nowMs: now
            ),
            "50:00"
        )
        // What a client-side re-bucketing of `now` would have produced: exactly
        // 30 minutes wrong. This is the bug the API shape exists to prevent.
        let recomputed = ChartMath.bucket(now, spanMs: hourMs)
        XCTAssertNotEqual(recomputed, sessionOpen)
        XCTAssertEqual(
            ChartMath.barCountdownText(
                symbol: "BTC-USD", interval: .h1, weekly: false,
                barOpenMs: recomputed, barSpanMs: hourMs, nowMs: now
            ),
            "20:00"
        )
    }

    // MARK: - Long spans

    func testDailySpan() {
        let open: Int64 = 1_760_000_000_000
        XCTAssertEqual(
            ChartMath.barCountdownText(
                symbol: "BTC-USD", interval: .d1, weekly: false,
                barOpenMs: open, barSpanMs: dayMs, nowMs: open
            ),
            "24:00:00"
        )
        XCTAssertEqual(
            ChartMath.barCountdownText(
                symbol: "BTC-USD", interval: .d1, weekly: false,
                barOpenMs: open, barSpanMs: dayMs, nowMs: open + dayMs - 3_600_000
            ),
            "1:00:00"
        )
    }

    func testWeeklySpan() {
        let open = ChartMath.weekFloor(1_760_000_000_000)
        XCTAssertEqual(
            ChartMath.secondsUntilBarClose(
                barOpenMs: open, barSpanMs: ChartMath.weekMs, nowMs: open + 1_000
            ),
            604_799
        )
        // Hours are neither padded nor wrapped at 24 — a weekly bar is honest
        // about being days away rather than pretending to be a clock.
        XCTAssertEqual(
            ChartMath.barCountdownText(
                symbol: "BTC-USD", interval: .d1, weekly: true,
                barOpenMs: open, barSpanMs: ChartMath.weekMs, nowMs: open + 1_000
            ),
            "167:59:59"
        )
        XCTAssertNil(
            ChartMath.barCountdownText(
                symbol: "BTC-USD", interval: .d1, weekly: true,
                barOpenMs: open, barSpanMs: ChartMath.weekMs, nowMs: open + ChartMath.weekMs
            )
        )
    }

    // MARK: - Formatting

    func testFormatSwitchesAtOneHour() {
        XCTAssertEqual(ChartMath.formatCountdown(0), "00:00")
        XCTAssertEqual(ChartMath.formatCountdown(9), "00:09")
        XCTAssertEqual(ChartMath.formatCountdown(59), "00:59")
        XCTAssertEqual(ChartMath.formatCountdown(60), "01:00")
        XCTAssertEqual(ChartMath.formatCountdown(3_599), "59:59")
        XCTAssertEqual(ChartMath.formatCountdown(3_600), "1:00:00")
        XCTAssertEqual(ChartMath.formatCountdown(3_661), "1:01:01")
    }

    func testFormatIsNeverNegative() {
        XCTAssertEqual(ChartMath.formatCountdown(-1), "00:00")
        XCTAssertEqual(ChartMath.formatCountdown(-9_999), "00:00")
    }

    func testCountdownAlwaysCountsDownWithinTheSpan() {
        // Sweep a 5-minute bar: the value is always in 1...300 (never 0, never
        // negative, never more than one span) and never increases as time runs on.
        let open: Int64 = 1_760_000_000_000
        let span = 5 * minuteMs
        var previous = Int.max
        for offset in stride(from: Int64(0), to: span, by: 337) {
            guard let s = ChartMath.secondsUntilBarClose(
                barOpenMs: open, barSpanMs: span, nowMs: open + offset
            ) else {
                return XCTFail("bar is current at offset \(offset) but read nil")
            }
            XCTAssertGreaterThanOrEqual(s, 1)
            XCTAssertLessThanOrEqual(s, 300)
            XCTAssertLessThanOrEqual(s, previous)
            // Rounding UP is the safe direction: the label may hold a second
            // longer than the bar has left, but must never claim it closes
            // sooner than it does.
            let trueRemaining = Double(span - offset) / 1_000
            XCTAssertGreaterThanOrEqual(Double(s), trueRemaining)
            previous = s
        }
    }

    // MARK: - Placement under the price tag

    func testCountdownSitsBelowThePriceTag() {
        XCTAssertEqual(ChartMath.countdownCenterY(priceTagY: 100, paneMaxY: 400), 114)
        // Exactly enough room below: stays below.
        XCTAssertEqual(ChartMath.countdownCenterY(priceTagY: 379, paneMaxY: 400), 393)
    }

    func testCountdownFlipsAboveTheTagAtThePaneFloor() {
        // No room under the tag — the chip flips above it rather than spilling
        // into the volume pane.
        XCTAssertEqual(ChartMath.countdownCenterY(priceTagY: 390, paneMaxY: 400), 376)
    }
}

// MARK: - Grid uniformity (the adversarial review's findings)
//
// `secondsUntilBarClose` inherits the engine's bar ANCHOR from the data but
// assumes a UNIFORM span. The engine's equity grid is not uniform, so these pin
// the cases where a naive `open + span` would tick down over a bar that has
// already closed — a clock that lies about when the operator's bar ends.

extension BarCountdownTests {
    /// Equity hourly: the engine anchors to 09:30 ET through the session and
    /// falls back to the ET hour outside it, so the 09:00 pre-market and 15:30
    /// closing buckets are each 30 minutes. On the 15:30 bar `open + 1h` claims
    /// 16:30 ET — half an hour after the market shut.
    func testEquityHourlyIsNotTrusted() {
        XCTAssertFalse(
            ChartMath.countdownGridIsUniform(symbol: "AAPL", interval: .h1, weekly: false)
        )
        // 15:30 ET Fri 2026-08-14 (EDT) = 19:30 UTC — a genuine engine bucket.
        let open: Int64 = 1_786_735_800_000
        // 16:10 ET: the bar closed 10 minutes ago at 16:00.
        let now: Int64 = 1_786_738_200_000
        XCTAssertNil(
            ChartMath.barCountdownText(
                symbol: "AAPL", interval: .h1, weekly: false,
                barOpenMs: open, barSpanMs: Interval.h1.ms, nowMs: now
            ),
            "would have read 20:00 on a bar that closed at 16:00 ET"
        )
    }

    /// Equity daily is finalised at the 16:00 ET close (a non-RTH print rolls the
    /// bar up rather than extending it), but its span runs to UTC midnight —
    /// four hours of animation over a frozen bar.
    func testEquityDailyIsNotTrusted() {
        XCTAssertFalse(
            ChartMath.countdownGridIsUniform(symbol: "AAPL", interval: .d1, weekly: false)
        )
        XCTAssertNil(
            ChartMath.barCountdownText(
                symbol: "AAPL", interval: .d1, weekly: false,
                barOpenMs: 1_786_665_600_000, barSpanMs: Interval.d1.ms,
                nowMs: 1_786_738_200_000
            )
        )
    }

    /// Equity weekly rides a Monday-UTC weekFloor, but the trading week ends
    /// Friday 16:00 ET — otherwise the chip counts down all weekend.
    func testEquityWeeklyIsNotTrusted() {
        XCTAssertFalse(
            ChartMath.countdownGridIsUniform(symbol: "AAPL", interval: .d1, weekly: true)
        )
        XCTAssertNil(
            ChartMath.barCountdownText(
                symbol: "AAPL", interval: .d1, weekly: true,
                barOpenMs: ChartMath.weekFloor(1_786_738_200_000),
                barSpanMs: ChartMath.weekMs, nowMs: 1_786_738_200_000
            )
        )
    }

    /// Equity SUB-hourly buckets are plain UTC-floored and the 30-minute RTH
    /// offset is a whole multiple of each span, so those stay uniform and keep
    /// their countdown — the feature is not disabled for stocks wholesale.
    func testEquitySubHourlyStaysTrusted() {
        for interval in [Interval.s1, .m1, .m5, .m15] {
            XCTAssertTrue(
                ChartMath.countdownGridIsUniform(symbol: "AAPL", interval: interval, weekly: false),
                "\(interval) is uniform for equities and must keep its countdown"
            )
        }
        // A live 5-minute equity bar (as it would be on a real-time IBKR feed).
        let open: Int64 = 1_786_735_800_000
        XCTAssertEqual(
            ChartMath.barCountdownText(
                symbol: "AAPL", interval: .m5, weekly: false,
                barOpenMs: open, barSpanMs: Interval.m5.ms, nowMs: open + 120_000
            ),
            "03:00"
        )
    }

    /// Crypto is 24/7 on the plain UTC grid with no session and no anchor
    /// offset, so every interval — including daily and weekly — is uniform.
    func testCryptoIsTrustedAtEveryInterval() {
        for interval in Interval.allCases {
            XCTAssertTrue(
                ChartMath.countdownGridIsUniform(
                    symbol: "BTC-USD", interval: interval, weekly: false
                )
            )
        }
        XCTAssertTrue(
            ChartMath.countdownGridIsUniform(symbol: "BTC-USD", interval: .d1, weekly: true)
        )
        let open = ChartMath.weekFloor(1_786_738_200_000)
        XCTAssertNotNil(
            ChartMath.barCountdownText(
                symbol: "BTC-USD", interval: .d1, weekly: true,
                barOpenMs: open, barSpanMs: ChartMath.weekMs, nowMs: open + 3_600_000
            ),
            "crypto trades through the weekend, so its weekly countdown is real"
        )
    }
}

extension BarCountdownTests {
    /// Routine sub-second skew is clamped (the chip reads a full span rather
    /// than blinking out), but a bar stamped far ahead of the clock is refused:
    /// clamping it would pin the countdown at a full span for the whole skew,
    /// and a countdown that does not count down is worse than none.
    func testLargeClockSkewShowsNothingRatherThanFreezing() {
        let now: Int64 = 1_760_000_000_000
        let minute = Interval.m1.ms

        // Inside tolerance — clamped to a full span.
        XCTAssertEqual(
            ChartMath.barCountdownText(
                symbol: "BTC-USD", interval: .m1, weekly: false,
                barOpenMs: now + ChartMath.maxCountdownSkewMs, barSpanMs: minute, nowMs: now
            ),
            "01:00"
        )
        // Beyond tolerance — refused.
        XCTAssertNil(
            ChartMath.barCountdownText(
                symbol: "BTC-USD", interval: .m1, weekly: false,
                barOpenMs: now + ChartMath.maxCountdownSkewMs + 1, barSpanMs: minute, nowMs: now
            )
        )
        // The reviewer's case: 40 minutes ahead on a 1-minute chart would have
        // frozen at "01:00" for 40 minutes.
        XCTAssertNil(
            ChartMath.barCountdownText(
                symbol: "BTC-USD", interval: .m1, weekly: false,
                barOpenMs: now + 40 * minute, barSpanMs: minute, nowMs: now
            )
        )
    }
}
