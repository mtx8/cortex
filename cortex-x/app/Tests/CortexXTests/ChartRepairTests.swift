// Regression tests for two chart-layer repairs:
//
//  * the last-price "EXT" (extended-hours) marker used to latch ON for every
//    equity DAILY and WEEKLY chart forever, because those bar-opens are
//    UTC-midnight stamped (= 19:00/20:00 ET, outside RTH) and the marker
//    classified the bar-open with no interval gate;
//  * the time axis carried no year, so gridlines on the 5y / all presets
//    ("05 Jan · 04 May · 01 Sep …") could not be placed in a year at all.
//
// Kept separate from ChartMathTests so the pre-existing suite stays untouched.

import XCTest
@testable import CortexX

final class ChartRepairTests: XCTestCase {

    /// Epoch ms for an ISO-8601 UTC instant — fixtures stay readable.
    private func ts(_ iso: String) throws -> Int64 {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: iso), "bad ISO fixture")
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    /// The formatters are shared statics whose zone is set per call, so every
    /// label assertion pins the zone rather than inheriting the device's.
    private let utc = TimeZone(secondsFromGMT: 0)!

    // MARK: - Extended-hours marker gate

    func testExtMarkerOffForEquityDailyAndWeekly() throws {
        // Equity D1 opens are bucketed to UTC midnight and weekly opens to
        // Monday 00:00 UTC — both read as "after hours" in ET. Neither is an
        // extended-hours print, so the marker must stay off regardless.
        let utcMidnight = try ts("2026-07-15T00:00:00Z")
        XCTAssertTrue(ChartMath.isExtendedHours(utcMidnight), "fixture must be outside RTH")

        XCTAssertFalse(ChartMath.showsExtendedHoursMarker(
            symbol: "AAPL", interval: .d1, weekly: false, lastBarTsMs: utcMidnight
        ))
        XCTAssertFalse(ChartMath.showsExtendedHoursMarker(
            symbol: "AAPL", interval: .d1, weekly: true, lastBarTsMs: utcMidnight
        ))
        // The weekly view rides .d1, but guard the flag independently anyway.
        XCTAssertFalse(ChartMath.showsExtendedHoursMarker(
            symbol: "AAPL", interval: .h1, weekly: true, lastBarTsMs: utcMidnight
        ))
    }

    func testExtMarkerOnlyForEquityIntradayOutsideRTH() throws {
        // 08:00 ET pre-market on a 5-minute AAPL chart — the one case the
        // ember "EXT" tag is actually for.
        let premarket = try ts("2026-07-15T12:00:00Z")
        XCTAssertTrue(ChartMath.showsExtendedHoursMarker(
            symbol: "AAPL", interval: .m5, weekly: false, lastBarTsMs: premarket
        ))
        // 11:00 ET, regular session wide open — no marker.
        let midSession = try ts("2026-07-15T15:00:00Z")
        XCTAssertFalse(ChartMath.showsExtendedHoursMarker(
            symbol: "AAPL", interval: .m5, weekly: false, lastBarTsMs: midSession
        ))
    }

    func testExtMarkerOffForCryptoAndEmptySeries() throws {
        // Crypto trades 24/7: an overnight bar is a normal bar, never "EXT".
        let overnight = try ts("2026-07-15T03:00:00Z")
        for iv in [Interval.m1, .m5, .h1, .d1] {
            XCTAssertFalse(ChartMath.showsExtendedHoursMarker(
                symbol: "BTC-USD", interval: iv, weekly: false, lastBarTsMs: overnight
            ), "\(iv) on a crypto pair must never be marked EXT")
        }
        // No bars at all -> nothing to classify (the chart draws no tag).
        XCTAssertFalse(ChartMath.showsExtendedHoursMarker(
            symbol: "AAPL", interval: .m5, weekly: false, lastBarTsMs: nil
        ))
    }

    // MARK: - Axis year label

    func testTimeLabelAppendsYearToDateLabels() throws {
        let t = try ts("2026-07-15T00:00:00Z")
        // Daily bars already take the date formatter; showYear widens it.
        XCTAssertEqual(
            ChartMath.timeLabel(t, interval: .d1, tz: utc), "15 Jul"
        )
        XCTAssertEqual(
            ChartMath.timeLabel(t, interval: .d1, tz: utc, showYear: true), "15 Jul 26"
        )
        // Intraday at a day boundary shows a date, so it can carry a year too.
        XCTAssertEqual(
            ChartMath.timeLabel(t, interval: .m5, tz: utc, showDate: true, showYear: true),
            "15 Jul 26"
        )
    }

    func testShowYearNeverPromotesAClockLabelToADate() throws {
        // An intraday gridline that is NOT a session boundary must stay a
        // clock — the year switch must not silently turn the axis into dates.
        let t = try ts("2026-07-15T15:05:00Z")
        XCTAssertEqual(
            ChartMath.timeLabel(t, interval: .m5, tz: utc, showDate: false, showYear: true),
            "15:05"
        )
        // And the default (no year) behaviour is unchanged.
        XCTAssertEqual(ChartMath.timeLabel(t, interval: .m5, tz: utc), "15:05")
    }

    func testYearKeyUsesTheExchangeZoneNotUTC() throws {
        // 02:00 UTC on New Year's Day is still 21:00 ET on 31 Dec — the axis
        // must call that gridline the OLD year, matching the date it prints.
        let t = try ts("2026-01-01T02:00:00Z")
        let eastern = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        XCTAssertEqual(ChartMath.yearKey(t, tz: utc), 2026)
        XCTAssertEqual(ChartMath.yearKey(t, tz: eastern), 2025)
        // yearKey is the year half of the same key the date switch uses.
        XCTAssertEqual(ChartMath.yearKey(t, tz: eastern), ChartMath.dayKey(t, tz: eastern) / 10_000)
    }

    func testYearKeyDetectsAMultiYearWindow() throws {
        // The grid decides to print years by comparing the first and last
        // visible bar's year; a 5y weekly window always differs, a window
        // inside one calendar year never does.
        let a = try ts("2021-03-01T00:00:00Z")
        let b = try ts("2026-03-01T00:00:00Z")
        XCTAssertNotEqual(ChartMath.yearKey(a, tz: utc), ChartMath.yearKey(b, tz: utc))
        let c = try ts("2026-11-30T00:00:00Z")
        XCTAssertEqual(ChartMath.yearKey(b, tz: utc), ChartMath.yearKey(c, tz: utc))
    }
}
