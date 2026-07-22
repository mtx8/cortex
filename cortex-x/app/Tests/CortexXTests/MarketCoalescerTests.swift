// Display-rate coalescing: the pure MarketCoalescer (buffers the latest
// high-frequency market frame, batches tape, passes completed bars straight
// through), the AppModel receive→flush routing (market frames buffer until the
// ~12 Hz flush; completed bars and low-frequency frames apply immediately), and
// the indicator-memo cache key (equal across pan/zoom, turns over as data
// changes) that keeps ChartFrame from recomputing EMA/BB/RSI/MACD every draw.

import XCTest
@testable import CortexX

// MARK: - Pure coalescer

final class MarketCoalescerTests: XCTestCase {

    // MARK: Buffering the latest

    func testBuffersLatestTickPerSymbol() {
        var c = MarketCoalescer()
        XCTAssertTrue(c.ingest(.tick(tick("BTC-USD", 100))))
        XCTAssertTrue(c.ingest(.tick(tick("BTC-USD", 105))))
        // Only the newest survives the window.
        let ticks = drainTicks(&c)
        XCTAssertEqual(ticks.count, 1)
        XCTAssertEqual(ticks["BTC-USD"], 105)
    }

    func testKeepsLatestPerSymbolIndependently() {
        var c = MarketCoalescer()
        _ = c.ingest(.tick(tick("BTC-USD", 100)))
        _ = c.ingest(.tick(tick("ETH-USD", 20)))
        _ = c.ingest(.tick(tick("BTC-USD", 101)))
        let ticks = drainTicks(&c)
        XCTAssertEqual(ticks, ["BTC-USD": 101, "ETH-USD": 20])
    }

    func testBuffersLatestBookTopDepthFlow() {
        var c = MarketCoalescer()
        XCTAssertTrue(c.ingest(.bookTop(bookTop("AAPL", bid: 10))))
        XCTAssertTrue(c.ingest(.bookTop(bookTop("AAPL", bid: 11))))
        XCTAssertTrue(c.ingest(.depth(depth("AAPL"))))
        XCTAssertTrue(c.ingest(.flow(flow("AAPL"))))
        let frames = c.drain()
        // One book_top (latest), one depth, one flow.
        XCTAssertEqual(frames.compactMap { if case .bookTop(let b) = $0 { return b.bid_px } else { return nil } }, [11])
        XCTAssertEqual(frames.filter { if case .depth = $0 { return true } else { return false } }.count, 1)
        XCTAssertEqual(frames.filter { if case .flow = $0 { return true } else { return false } }.count, 1)
    }

    // MARK: Tape batching

    func testTapeBatchedInArrivalOrder() {
        var c = MarketCoalescer()
        for i in 0..<3 { _ = c.ingest(.tape(print("BTC-USD", ts: Int64(i)))) }
        let ts = c.drain().compactMap { if case .tape(let p) = $0 { return p.ts_ms } else { return nil } }
        // Preserved chronological order — apply() prepends each, so newest ends
        // up first in the model's tape.
        XCTAssertEqual(ts, [0, 1, 2])
    }

    // MARK: Completed vs forming bars

    func testCompletedBarIsPassThroughNotBuffered() {
        var c = MarketCoalescer()
        // A completed bar reports false (caller applies immediately) and leaves
        // nothing buffered.
        XCTAssertFalse(c.ingest(.bar(bar("BTC-USD", ts: 60_000, close: 100, complete: true))))
        XCTAssertFalse(c.hasPending)
        XCTAssertTrue(c.drain().isEmpty)
    }

    func testFormingBarIsBuffered() {
        var c = MarketCoalescer()
        XCTAssertTrue(c.ingest(.bar(bar("BTC-USD", ts: 60_000, close: 100, complete: false))))
        XCTAssertTrue(c.hasPending)
        let bars = c.drain().compactMap { if case .bar(let b) = $0 { return b } else { return nil } }
        XCTAssertEqual(bars.count, 1)
        XCTAssertEqual(bars.first?.close, 100)
    }

    func testFormingBarCoalescesToLatestPerSeries() {
        var c = MarketCoalescer()
        _ = c.ingest(.bar(bar("BTC-USD", ts: 60_000, close: 100, complete: false)))
        _ = c.ingest(.bar(bar("BTC-USD", ts: 60_000, close: 103, complete: false)))
        let bars = c.drain().compactMap { if case .bar(let b) = $0 { return b } else { return nil } }
        XCTAssertEqual(bars.count, 1)
        XCTAssertEqual(bars.first?.close, 103) // only the latest forming state
    }

    func testFormingBarsSeparateAcrossIntervals() {
        var c = MarketCoalescer()
        _ = c.ingest(.bar(bar("BTC-USD", ts: 60_000, close: 100, complete: false, interval: .m1)))
        _ = c.ingest(.bar(bar("BTC-USD", ts: 60_000, close: 100, complete: false, interval: .m5)))
        let bars = c.drain().compactMap { if case .bar(let b) = $0 { return b } else { return nil } }
        // Distinct series — both survive.
        XCTAssertEqual(Set(bars.map(\.interval)), [.m1, .m5])
    }

    func testCompletedBarDropsSupersededFormingBar() {
        var c = MarketCoalescer()
        // Forming bar for the closing period is buffered…
        _ = c.ingest(.bar(bar("BTC-USD", ts: 60_000, close: 100, complete: false)))
        // …then the completed bar for the SAME period lands (pass-through). The
        // stale forming frame must be dropped so it can never flush over the
        // just-closed bar.
        XCTAssertFalse(c.ingest(.bar(bar("BTC-USD", ts: 60_000, close: 101, complete: true))))
        XCTAssertFalse(c.hasPending)
        XCTAssertTrue(c.drain().isEmpty)
    }

    func testCompletedBarKeepsNewerFormingBar() {
        var c = MarketCoalescer()
        // The next period is already forming when the prior period's completed
        // bar lands — the newer forming bar must be kept.
        _ = c.ingest(.bar(bar("BTC-USD", ts: 120_000, close: 105, complete: false)))
        _ = c.ingest(.bar(bar("BTC-USD", ts: 60_000, close: 101, complete: true)))
        let bars = c.drain().compactMap { if case .bar(let b) = $0 { return b } else { return nil } }
        XCTAssertEqual(bars.map(\.ts_open_ms), [120_000])
    }

    // MARK: Low-frequency frames are never buffered

    func testLowFrequencyFramesArePassThrough() {
        var c = MarketCoalescer()
        // Config / discrete frames still bypass the buffer and apply immediately.
        XCTAssertFalse(c.ingest(.risk(.empty)))
        XCTAssertFalse(c.hasPending)
    }

    func testAccountAndPositionAreCoalesced() {
        var c = MarketCoalescer()
        // Mark-to-market snapshots (emitted up to feed rate) buffer latest-wins
        // and flush at the display rate — they must NOT re-render at raw feed rate.
        XCTAssertTrue(c.ingest(.account(.empty)))
        XCTAssertTrue(c.ingest(.position(position("BTC-USD", qty: 1))))
        XCTAssertTrue(c.hasPending)
        let frames = c.drain()
        XCTAssertTrue(frames.contains { if case .position = $0 { return true } else { return false } })
        // account is emitted LAST so the flush carries the freshest marks.
        if case .account = frames.last {} else { XCTFail("account should flush last") }
        XCTAssertFalse(c.hasPending) // drain reset
    }

    // MARK: Drain resets

    func testDrainResetsBuffer() {
        var c = MarketCoalescer()
        _ = c.ingest(.tick(tick("BTC-USD", 100)))
        XCTAssertTrue(c.hasPending)
        _ = c.drain()
        XCTAssertFalse(c.hasPending)
        XCTAssertTrue(c.drain().isEmpty)
    }

    func testClearDiscardsBuffer() {
        var c = MarketCoalescer()
        _ = c.ingest(.tick(tick("BTC-USD", 100)))
        _ = c.ingest(.tape(print("BTC-USD", ts: 1)))
        c.clear()
        XCTAssertFalse(c.hasPending)
        XCTAssertTrue(c.drain().isEmpty)
    }

    // MARK: Helpers

    /// Drain and collect the latest tick price per symbol from the batch.
    private func drainTicks(_ c: inout MarketCoalescer) -> [String: Double] {
        var out: [String: Double] = [:]
        for f in c.drain() { if case .tick(let t) = f { out[t.symbol] = t.price } }
        return out
    }

    private func tick(_ symbol: String, _ px: Double, ts: Int64 = 0) -> Tick {
        Tick(symbol: symbol, ts_ms: ts, price: px, size: 0, aggressor: nil, venue: .cboe)
    }

    private func bar(
        _ symbol: String, ts: Int64, close: Double, complete: Bool, interval: Interval = .m1
    ) -> Bar {
        Bar(
            symbol: symbol, interval: interval, ts_open_ms: ts,
            open: close, high: close, low: close, close: close,
            volume: 1, trade_count: 1, vwap: close, complete: complete
        )
    }

    private func bookTop(_ symbol: String, bid: Double) -> BookTop {
        BookTop(symbol: symbol, ts_ms: 1, bid_px: bid, bid_sz: 1, ask_px: bid + 1, ask_sz: 1)
    }

    private func position(_ symbol: String, qty: Double) -> Position {
        Position(
            symbol: symbol, qty: qty, avg_px: 100, mark_px: 100,
            unrealized_pnl: 0, realized_pnl: 0, ts_ms: 1
        )
    }

    private func depth(_ symbol: String) -> BookDepth {
        BookDepth(
            symbol: symbol, bids: [BookLevel(px: 100, sz: 1, count: 1)],
            asks: [BookLevel(px: 101, sz: 1, count: 1)],
            depth: 1, source: "test", is_live: true, ts_ms: 1
        )
    }

    private func flow(_ symbol: String) -> FlowRead {
        FlowRead(
            symbol: symbol, imbalance: 0.2, cum_delta: 100, delta_rate: 5,
            pressure: "buyers", flags: [], note: "", is_live: true, source: "test", ts_ms: 1
        )
    }

    private func print(_ symbol: String, ts: Int64) -> TapePrint {
        TapePrint(symbol: symbol, px: 100, sz: 1, aggressor: .buy, ts_ms: ts, is_live: true)
    }
}

// MARK: - AppModel receive → flush routing

@MainActor
final class CoalescedReceiveTests: XCTestCase {

    func testTickBuffersUntilFlush() {
        let model = AppModel()
        model.receive(.tick(tick("BTC-USD", 100)))
        // Buffered — not yet committed to observable state.
        XCTAssertNil(model.lastTick["BTC-USD"])
        model.flushMarket()
        XCTAssertEqual(model.lastTick["BTC-USD"]?.price, 100)
    }

    func testFlushCommitsLatestTickOnly() {
        let model = AppModel()
        model.receive(.tick(tick("BTC-USD", 100)))
        model.receive(.tick(tick("BTC-USD", 107)))
        model.flushMarket()
        XCTAssertEqual(model.lastTick["BTC-USD"]?.price, 107)
    }

    func testCompletedBarAppliesImmediately() {
        let model = AppModel()
        // A completed bar bypasses the buffer entirely — visible without a flush.
        model.receive(.bar(bar("BTC-USD", ts: 60_000, close: 100, complete: true)))
        XCTAssertEqual(model.bars("BTC-USD", .m1).last?.close, 100)
    }

    func testFormingBarWaitsForFlush() {
        let model = AppModel()
        model.receive(.bar(bar("BTC-USD", ts: 60_000, close: 100, complete: false)))
        XCTAssertTrue(model.bars("BTC-USD", .m1).isEmpty) // buffered
        model.flushMarket()
        XCTAssertEqual(model.bars("BTC-USD", .m1).last?.close, 100)
    }

    func testFlushedTapeIsNewestFirstAndRespectsGuard() {
        let model = AppModel()
        model.subscribeDepth("BTC-USD")
        model.receive(.tape(print("BTC-USD", ts: 1)))
        model.receive(.tape(print("BTC-USD", ts: 2)))
        model.receive(.tape(print("BTC-USD", ts: 3)))
        XCTAssertTrue(model.tape.isEmpty) // buffered
        model.flushMarket()
        // apply() prepends each in arrival order → newest print lands first.
        XCTAssertEqual(model.tape.map(\.ts_ms), [3, 2, 1])
    }

    func testFlushedDepthRespectsSubscriptionGuard() {
        let model = AppModel()
        model.subscribeDepth("AAPL")
        model.receive(.depth(depth("AAPL")))
        model.receive(.depth(depth("MSFT"))) // late frame for another symbol
        model.flushMarket()
        // The guard in apply() still drops the unsubscribed symbol's book.
        XCTAssertEqual(model.bookDepth?.symbol, "AAPL")
    }

    func testDisconnectDiscardsBufferedFrames() {
        let model = AppModel()
        model.handleStateChange(.connected)
        model.receive(.tick(tick("BTC-USD", 100)))
        model.handleStateChange(.disconnected)
        model.flushMarket()
        // The dead connection's buffered tick never reaches observable state.
        XCTAssertNil(model.lastTick["BTC-USD"])
    }

    func testRiskFrameAppliesImmediately() {
        let model = AppModel()
        // Risk (kill switch, autonomy) is interaction-critical — never buffered.
        var r = RiskStatus.empty
        r.kill_switch = true
        r.kill_reason = "test"
        model.receive(.risk(r))
        XCTAssertTrue(model.risk.kill_switch) // no flush needed
    }

    func testAccountFrameCoalescesUntilFlush() {
        let model = AppModel()
        let initial = model.account.equity
        model.receive(.account(AccountSnapshot(
            equity: 5, cash: 5, gross_exposure: 0, net_exposure: 0,
            unrealized_pnl: 0, realized_pnl_day: 0, fees_paid: 0,
            open_orders: 0, daily_trades: 0, drawdown_day: 0, drawdown_total: 0, ts_ms: 1
        )))
        XCTAssertEqual(model.account.equity, initial, "account buffers — not applied until flush")
        model.flushMarket()
        XCTAssertEqual(model.account.equity, 5)
    }

    // MARK: Fixtures

    private func tick(_ symbol: String, _ px: Double) -> Tick {
        Tick(symbol: symbol, ts_ms: 0, price: px, size: 0, aggressor: nil, venue: .cboe)
    }

    private func position(_ symbol: String, qty: Double) -> Position {
        Position(
            symbol: symbol, qty: qty, avg_px: 100, mark_px: 100,
            unrealized_pnl: 0, realized_pnl: 0, ts_ms: 1
        )
    }

    private func bar(_ symbol: String, ts: Int64, close: Double, complete: Bool) -> Bar {
        Bar(
            symbol: symbol, interval: .m1, ts_open_ms: ts,
            open: close, high: close, low: close, close: close,
            volume: 1, trade_count: 1, vwap: close, complete: complete
        )
    }

    private func depth(_ symbol: String) -> BookDepth {
        BookDepth(
            symbol: symbol, bids: [BookLevel(px: 100, sz: 1, count: 1)],
            asks: [BookLevel(px: 101, sz: 1, count: 1)],
            depth: 1, source: "test", is_live: true, ts_ms: 1
        )
    }

    private func print(_ symbol: String, ts: Int64) -> TapePrint {
        TapePrint(symbol: symbol, px: 100, sz: 1, aggressor: .buy, ts_ms: ts, is_live: true)
    }
}

// MARK: - Indicator memo cache key

final class IndicatorCacheKeyTests: XCTestCase {

    func testSameBarsAndTogglesProduceEqualKey() {
        let bars = series(count: 50)
        // The visible window is NOT part of the key — panning/zooming (same
        // bars) reuses the memoized series, which is the whole point.
        XCTAssertEqual(key(bars), key(bars))
    }

    func testFormingBarCloseDoesNotChangeKey() {
        // The newest bar is still forming: its close twitches on every tick, but
        // the memo anchors on the last COMPLETED bar — so the key holds steady
        // and the indicator series is reused across the whole forming bar's life
        // (no display-rate recompute of EMA/BB/RSI/MACD over the full window).
        var bars = series(count: 50)
        bars[bars.count - 1].complete = false
        let a = key(bars)
        bars[bars.count - 1].close += 5
        XCTAssertEqual(a, key(bars))
    }

    func testFormingBarCompletionChangesKey() {
        // When the forming bar finalizes, the key turns over exactly once so the
        // completed bar folds into a single indicator recompute.
        var bars = series(count: 50)
        bars[bars.count - 1].complete = false
        bars[bars.count - 1].close = 142
        let forming = key(bars)
        bars[bars.count - 1].complete = true
        XCTAssertNotEqual(forming, key(bars))
    }

    func testCompletedBarCloseChangesKey() {
        // A correction to the last COMPLETED bar's close still invalidates the
        // memo (a settled value genuinely changed).
        var bars = series(count: 50) // all complete
        let a = key(bars)
        bars[bars.count - 1].close += 0.01
        XCTAssertNotEqual(a, key(bars))
    }

    func testAppendedBarChangesKey() {
        let bars = series(count: 50)
        let a = key(bars)
        XCTAssertNotEqual(a, key(series(count: 51)))
    }

    func testFormingBarAppendChangesKey() {
        // A new forming bar appending (the prior bar having just completed) turns
        // the key over so the just-completed bar folds into the indicators —
        // even though the appended bar is itself still forming.
        var bars = series(count: 50) // b0…b49 complete
        let before = key(bars)
        bars.append(Bar(
            symbol: "BTC-USD", interval: .m1, ts_open_ms: 50 * 60_000,
            open: 150, high: 151, low: 149, close: 150,
            volume: 1, trade_count: 1, vwap: 150, complete: false
        ))
        XCTAssertNotEqual(before, key(bars))
    }

    func testTogglingAnOverlayChangesKey() {
        let bars = series(count: 50)
        let on = IndicatorCacheKey.make(
            symbol: "BTC-USD", interval: .m1, bars: bars,
            ema9: true, ema21: true, ema50: true, bb: true, rsi: true, macd: false
        )
        let off = IndicatorCacheKey.make(
            symbol: "BTC-USD", interval: .m1, bars: bars,
            ema9: true, ema21: true, ema50: true, bb: true, rsi: true, macd: true
        )
        XCTAssertNotEqual(on, off)
    }

    func testDifferentSymbolChangesKey() {
        let bars = series(count: 50)
        let a = IndicatorCacheKey.make(
            symbol: "BTC-USD", interval: .m1, bars: bars,
            ema9: true, ema21: true, ema50: true, bb: true, rsi: true, macd: false
        )
        let b = IndicatorCacheKey.make(
            symbol: "ETH-USD", interval: .m1, bars: bars,
            ema9: true, ema21: true, ema50: true, bb: true, rsi: true, macd: false
        )
        XCTAssertNotEqual(a, b)
    }

    func testNaNCloseKeyIsStable() {
        var bars = series(count: 50)
        bars[bars.count - 1].close = .nan
        // Bit-pattern comparison keeps a NaN close comparing equal to itself, so
        // the memo still hits (a raw NaN == NaN would never match → recompute
        // every draw).
        XCTAssertEqual(key(bars), key(bars))
    }

    // MARK: Helpers

    private func key(_ bars: [Bar]) -> IndicatorCacheKey {
        IndicatorCacheKey.make(
            symbol: "BTC-USD", interval: .m1, bars: bars,
            ema9: true, ema21: true, ema50: true, bb: true, rsi: true, macd: false
        )
    }

    private func series(count: Int) -> [Bar] {
        (0..<count).map { i in
            Bar(
                symbol: "BTC-USD", interval: .m1, ts_open_ms: Int64(i) * 60_000,
                open: 100, high: 101, low: 99, close: 100 + Double(i),
                volume: 1, trade_count: 1, vwap: 100, complete: true
            )
        }
    }
}
