// Level 2 / time & sales HONESTY rules.
//
// The equity truth these pin, measured against the running engine: the keyless
// CBOE feed publishes NO order book (one synthetic level per side, refreshed
// every couple of minutes, carrying a quote stamped ~15 minutes behind the
// clock) and NO time & sales at all. So the DOM must never read as an order
// book and the tape must never promise prints that cannot come — while the
// crypto path (a real Coinbase book AND a real tape) must be left exactly as it
// was. Everything below is the pure selection those two panes render from.

import XCTest
@testable import CortexX

final class DepthHonestyTests: XCTestCase {

    /// A fixed "now" and a quote stamped 15m 25s earlier — the realistic
    /// delayed-equity fixture.
    private let nowMs: Int64 = 1_760_000_000_000
    private var delayedTs: Int64 { nowMs - (15 * 60 + 25) * 1_000 }

    // MARK: - Feed state (subscription + the frame's own is_live)

    func testStateUnsubscribedWhenNothingWasEverAskedFor() {
        XCTAssertEqual(
            DepthHonesty.state(facts(equity: true, subscribed: false, depth: false)),
            .unsubscribed
        )
        XCTAssertEqual(
            DepthHonesty.state(facts(equity: false, subscribed: false, depth: false)),
            .unsubscribed
        )
    }

    func testStateWaitingOnlyWhileSubscribedWithNoFrame() {
        XCTAssertEqual(
            DepthHonesty.state(facts(equity: true, subscribed: true, depth: false)),
            .waiting
        )
        XCTAssertEqual(
            DepthHonesty.state(facts(equity: false, subscribed: true, depth: false)),
            .waiting
        )
    }

    func testStateReadsTheFramesOwnLiveFlag() {
        // Crypto real-time book.
        XCTAssertEqual(
            DepthHonesty.state(facts(equity: false, depth: true, live: true, bids: 12, asks: 12)),
            .live
        )
        // Equity delayed L1 stand-in.
        XCTAssertEqual(
            DepthHonesty.state(facts(equity: true, depth: true, live: false, bids: 1, asks: 1)),
            .delayed
        )
        // A LIVE equity book (IB Gateway) is live — the rule keys off the flag,
        // never off the symbol's kind.
        XCTAssertEqual(
            DepthHonesty.state(facts(equity: true, depth: true, live: true, bids: 10, asks: 10)),
            .live
        )
        // Crypto that is NOT vouched for is not live either.
        XCTAssertEqual(
            DepthHonesty.state(facts(equity: false, depth: true, live: false, bids: 5, asks: 5)),
            .delayed
        )
    }

    func testALandedFrameOutranksAStaleSubscriptionFlag() {
        // hasDepth wins: a frame in hand is never reported as "waiting".
        XCTAssertEqual(
            DepthHonesty.state(
                facts(equity: true, subscribed: false, depth: true, live: false, bids: 1, asks: 1)
            ),
            .delayed
        )
    }

    // MARK: - Depth pane: every combination

    func testLiveCryptoBookRendersPlainAndUntouched() {
        // THE WORKING PATH. A real multi-level real-time book gets no notice at
        // all — this pane must look exactly as it did before the honesty work.
        let pane = DepthHonesty.depthPane(
            facts(equity: false, depth: true, live: true, source: "coinbase", bids: 25, asks: 25)
        )
        XCTAssertEqual(pane, .book)
    }

    func testLiveEquityBookFromIbGatewayAlsoRendersPlain() {
        let pane = DepthHonesty.depthPane(
            facts(equity: true, depth: true, live: true, source: "IBKR", bids: 10, asks: 10)
        )
        XCTAssertEqual(pane, .book)
    }

    func testDelayedEquityL1DrawsItsLevelsAndSaysWhatTheyAre() {
        let pane = DepthHonesty.depthPane(
            facts(equity: true, depth: true, live: false, bids: 1, asks: 1, ts: delayedTs)
        )
        guard case .bookWithNotice(let notice) = pane else {
            return XCTFail("a delayed equity frame must still draw its level AND explain it")
        }
        // Unmistakably not an order book.
        XCTAssertTrue(notice.headline.contains("NOT AN ORDER BOOK"))
        XCTAssertTrue(notice.detail.contains("single top-of-book level per side"))
        XCTAssertTrue(notice.detail.contains("IB Gateway"))
        // The source is quoted from the frame, never invented.
        XCTAssertTrue(notice.detail.contains("cboe delayed L1 (no depth)"))
        // Terminal: nothing better is coming on this feed.
        XCTAssertTrue(notice.isTerminal)
        // And it carries the stamp so the view can age it.
        XCTAssertEqual(notice.quoteTsMs, delayedTs)
    }

    func testDelayedNoticeNeverOverstatesHowManyLevelsArrived() {
        // A one-sided delayed frame (bid only) is still "one level per side"…
        let oneSided = DepthHonesty.delayedNotice(
            facts(equity: true, depth: true, bids: 1, asks: 0)
        )
        XCTAssertTrue(oneSided.detail.contains("single top-of-book level per side"))
        // …but a genuinely deeper delayed book says so rather than under-reporting.
        let deeper = DepthHonesty.delayedNotice(
            facts(equity: true, depth: true, bids: 4, asks: 3)
        )
        XCTAssertTrue(deeper.detail.contains("4 delayed levels per side"))
    }

    func testDelayedCryptoBookGetsItsOwnCopyNotTheEquityStory() {
        let notice = DepthHonesty.delayedNotice(
            facts(equity: false, depth: true, source: "coinbase", bids: 20, asks: 20)
        )
        XCTAssertTrue(notice.headline.contains("NOT REAL-TIME"))
        // The equity "there is no book, get IB Gateway" story does not apply.
        XCTAssertFalse(notice.detail.contains("IB Gateway"))
        XCTAssertFalse(notice.headline.contains("NOT AN ORDER BOOK"))
    }

    func testDelayedFrameWithNoDrawableLevelsIsNoticeOnly() {
        let pane = DepthHonesty.depthPane(
            facts(equity: true, depth: true, live: false, bids: 0, asks: 0, ts: delayedTs)
        )
        guard case .noticeOnly(let notice) = pane else {
            return XCTFail("nothing drawable — the notice is the pane")
        }
        XCTAssertTrue(notice.isTerminal)
        XCTAssertTrue(notice.detail.contains("IB Gateway"))
    }

    func testWaitingAndUnsubscribedReadDifferently() {
        // Subscribed, nothing yet: waiting is honest, and NOT terminal.
        guard case .noticeOnly(let waiting) =
            DepthHonesty.depthPane(facts(equity: true, subscribed: true, depth: false))
        else { return XCTFail("expected a notice") }
        XCTAssertEqual(waiting, DepthHonesty.waiting)
        XCTAssertFalse(waiting.isTerminal)

        // Nothing subscribed: no frame is in flight, so nothing is coming.
        guard case .noticeOnly(let idle) =
            DepthHonesty.depthPane(facts(equity: true, subscribed: false, depth: false))
        else { return XCTFail("expected a notice") }
        XCTAssertEqual(idle, DepthHonesty.unsubscribed)
        XCTAssertTrue(idle.isTerminal)

        // The two states must never render the same words.
        XCTAssertNotEqual(waiting.headline, idle.headline)
        XCTAssertNotEqual(waiting.detail, idle.detail)
    }

    func testWaitingVersusUnsubscribedHoldsForCryptoToo() {
        XCTAssertEqual(
            DepthHonesty.depthPane(facts(equity: false, subscribed: true, depth: false)),
            .noticeOnly(DepthHonesty.waiting)
        )
        XCTAssertEqual(
            DepthHonesty.depthPane(facts(equity: false, subscribed: false, depth: false)),
            .noticeOnly(DepthHonesty.unsubscribed)
        )
    }

    func testLiveButEmptyBookIsNotTerminal() {
        // A real venue with nothing resting right now may refill — that is the
        // one empty book the operator should keep watching.
        guard case .noticeOnly(let notice) = DepthHonesty.depthPane(
            facts(equity: false, depth: true, live: true, source: "coinbase", bids: 0, asks: 0)
        ) else { return XCTFail("expected a notice") }
        XCTAssertEqual(notice, DepthHonesty.emptyLiveBook)
        XCTAssertFalse(notice.isTerminal)
        XCTAssertNil(notice.quoteTsMs)
    }

    func testOneSidedBookStillDraws() {
        // Levels on either side count as drawable — a bid-only live book is not
        // "empty".
        XCTAssertEqual(
            DepthHonesty.depthPane(facts(equity: false, depth: true, live: true, bids: 3, asks: 0)),
            .book
        )
        XCTAssertEqual(
            DepthHonesty.depthPane(facts(equity: false, depth: true, live: true, bids: 0, asks: 3)),
            .book
        )
    }

    func testEveryCombinationOfTheFourFlagsResolves() {
        // Exhaustive sweep: no combination may fall through to something that
        // implies a live order book when the feed did not vouch for one.
        for isEquity in [true, false] {
            for subscribed in [true, false] {
                for hasDepth in [true, false] {
                    for live in [true, false] {
                        for levels in [0, 1, 8] {
                            let f = facts(
                                equity: isEquity, subscribed: subscribed, depth: hasDepth,
                                live: live, bids: levels, asks: levels, ts: delayedTs
                            )
                            let pane = DepthHonesty.depthPane(f)
                            switch pane {
                            case .book:
                                // Silence is only ever earned by a real, live,
                                // non-empty book.
                                XCTAssertTrue(hasDepth && live && levels > 0)
                            case .bookWithNotice:
                                XCTAssertTrue(hasDepth && !live && levels > 0)
                            case .noticeOnly(let n):
                                XCTAssertTrue(!hasDepth || levels == 0)
                                XCTAssertFalse(n.headline.isEmpty)
                                XCTAssertFalse(n.detail.isEmpty)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Time & sales pane

    func testEquityTapeIsAPermanentStatementNotAnEmptyState() {
        // The bug: "waiting for prints…" on a feed that emits none.
        for subscribed in [true, false] {
            for hasDepth in [true, false] {
                let pane = DepthHonesty.tapePane(
                    facts(equity: true, subscribed: subscribed, depth: hasDepth),
                    hasPrints: false
                )
                guard case .notice(let notice) = pane else {
                    return XCTFail("an equity tape must state that no prints will come")
                }
                XCTAssertEqual(notice, DepthHonesty.noEquityTape)
                XCTAssertTrue(notice.isTerminal)
                XCTAssertTrue(notice.detail.contains("IB Gateway"))
                XCTAssertTrue(notice.detail.contains("no prints will arrive"))
            }
        }
    }

    func testEquityTapeShowsRealPrintsTheMomentAnyExist() {
        // IB Gateway connected: the notice must never hide a real tape.
        XCTAssertEqual(
            DepthHonesty.tapePane(facts(equity: true, depth: true, live: true), hasPrints: true),
            .prints
        )
    }

    func testCryptoTapePathIsUnchanged() {
        // THE WORKING PATH, byte for byte: crypto prints do arrive, so its quiet
        // state stays the quiet state it always was.
        XCTAssertEqual(
            DepthHonesty.tapePane(facts(equity: false, subscribed: true, depth: false), hasPrints: false),
            .empty("waiting for prints…")
        )
        XCTAssertEqual(
            DepthHonesty.tapePane(
                facts(equity: false, subscribed: true, depth: true, live: true, bids: 9, asks: 9),
                hasPrints: false
            ),
            .empty("no prints yet")
        )
        XCTAssertEqual(
            DepthHonesty.tapePane(
                facts(equity: false, depth: true, live: true, bids: 9, asks: 9),
                hasPrints: true
            ),
            .prints
        )
        XCTAssertEqual(DepthHonesty.cryptoTapeEmptyText(hasDepth: false), "waiting for prints…")
        XCTAssertEqual(DepthHonesty.cryptoTapeEmptyText(hasDepth: true), "no prints yet")
    }

    // MARK: - Quote age (the dangerous number)

    func testQuoteAgeIsSecondsBehindTheClock() {
        XCTAssertEqual(
            DepthHonesty.quoteAgeSec(tsMs: nowMs - 90_000, nowMs: nowMs) ?? -1,
            90,
            accuracy: 1e-9
        )
        XCTAssertEqual(DepthHonesty.quoteAgeSec(tsMs: nowMs, nowMs: nowMs) ?? -1, 0, accuracy: 1e-9)
    }

    func testQuoteAgeIsNeverGuessedAt() {
        // No stamp, a zero/negative stamp, or a stamp in the FUTURE (clock skew)
        // yields nil — the view then says so rather than printing a number.
        XCTAssertNil(DepthHonesty.quoteAgeSec(tsMs: nil, nowMs: nowMs))
        XCTAssertNil(DepthHonesty.quoteAgeSec(tsMs: 0, nowMs: nowMs))
        XCTAssertNil(DepthHonesty.quoteAgeSec(tsMs: -5, nowMs: nowMs))
        XCTAssertNil(DepthHonesty.quoteAgeSec(tsMs: nowMs + 1_000, nowMs: nowMs))
    }

    func testQuoteAgeLineReportsTheRealDelay() {
        // The realistic equity case: ~15 minutes behind, refreshed every couple
        // of minutes — this line is what stops it reading as a live book.
        XCTAssertEqual(
            DepthHonesty.quoteAgeLine(tsMs: delayedTs, nowMs: nowMs),
            "quote stamped 15m behind the clock"
        )
        XCTAssertEqual(
            DepthHonesty.quoteAgeLine(tsMs: nowMs - 45_000, nowMs: nowMs),
            "quote stamped 45s behind the clock"
        )
    }

    func testQuoteAgeLineAdmitsWhenItCannotTell() {
        XCTAssertEqual(DepthHonesty.quoteAgeLine(tsMs: nil, nowMs: nowMs), "quote time unknown")
        XCTAssertEqual(DepthHonesty.quoteAgeLine(tsMs: 0, nowMs: nowMs), "quote time unknown")
        XCTAssertEqual(
            DepthHonesty.quoteAgeLine(tsMs: nowMs + 60_000, nowMs: nowMs), "quote time unknown"
        )
    }

    func testQuoteAgeNeverReadsFresherThanItIs() {
        // Rounding DOWN through compactAge is the safety property; the sweep
        // pins that the age never *shrinks* as the quote gets older.
        var lastSeconds = -1.0
        for minutes in stride(from: 0.0, through: 30.0, by: 0.25) {
            let ts = nowMs - Int64(minutes * 60_000)
            let age = DepthHonesty.quoteAgeSec(tsMs: ts, nowMs: nowMs) ?? -1
            XCTAssertGreaterThanOrEqual(age, lastSeconds)
            XCTAssertLessThanOrEqual(age, minutes * 60 + 1e-6)
            lastSeconds = age
        }
    }

    // MARK: - Cross-cutting: a terminal notice must never look like loading

    func testTerminalNoticesNeverTrailOffIntoALoadingState() {
        let terminal = [
            DepthHonesty.noEquityTape,
            DepthHonesty.unsubscribed,
            DepthHonesty.delayedNotice(facts(equity: true, depth: true, bids: 1, asks: 1)),
            DepthHonesty.delayedNotice(facts(equity: false, depth: true, bids: 6, asks: 6)),
        ]
        for notice in terminal {
            XCTAssertTrue(notice.isTerminal)
            XCTAssertFalse(notice.detail.hasSuffix("…"), "\(notice.headline) reads as loading")
            XCTAssertFalse(notice.headline.contains("WAITING"))
            XCTAssertFalse(notice.detail.lowercased().contains("waiting"))
        }
    }

    func testTheSourceBannerStillCarriesTheDelayedTruth() {
        // The dock's existing real/delayed banner is the one place this posture
        // was already stated; it must keep saying "delayed" AND now name what
        // actually supplies a book.
        let delayed = DepthBanner.make(for: bookDepth(isLive: false, source: "cboe delayed L1"))
        XCTAssertEqual(delayed.kind, .delayed)
        XCTAssertFalse(delayed.isLive)
        XCTAssertTrue(delayed.note.contains("delayed"))
        XCTAssertTrue(delayed.note.contains("not an order book"))
        XCTAssertTrue(delayed.note.contains("IB Gateway"))

        // A real book stays quiet, exactly as before.
        let live = DepthBanner.make(for: bookDepth(isLive: true, source: "coinbase"))
        XCTAssertEqual(live.kind, .live)
        XCTAssertTrue(live.isLive)
        XCTAssertFalse(live.note.contains("IB Gateway"))
    }

    // MARK: - Fixtures

    private func facts(
        equity: Bool,
        subscribed: Bool = true,
        depth: Bool = false,
        live: Bool = false,
        source: String = "cboe delayed L1 (no depth)",
        bids: Int = 0,
        asks: Int = 0,
        ts: Int64? = nil
    ) -> DepthFeedFacts {
        DepthFeedFacts(
            isEquity: equity,
            isSubscribed: subscribed,
            hasDepth: depth,
            isLive: live,
            source: source,
            bidLevels: bids,
            askLevels: asks,
            quoteTsMs: ts
        )
    }

    private func bookDepth(isLive: Bool, source: String) -> BookDepth {
        BookDepth(
            symbol: "AAPL",
            bids: [BookLevel(px: 190.10, sz: 300, count: 1)],
            asks: [BookLevel(px: 190.15, sz: 200, count: 1)],
            depth: 1, source: source, is_live: isLive, ts_ms: delayedTs
        )
    }
}
