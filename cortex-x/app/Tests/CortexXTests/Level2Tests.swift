// LEVEL 2 montage tests: depth/tape frame decode (incl. lean/legacy payloads),
// subscribe/unsubscribe command encode, the pure ladder helpers (best-first
// sort, shared size-bar fraction, mid/spread), the aggressor→tone mapping, the
// honest real/delayed banner, and the model's depth/tape application (the
// subscription guard, the tape ring cap, and the ticket-price hook).

import XCTest
@testable import CortexX

// MARK: - Wire protocol + pure helpers (no actor isolation needed)

final class Level2Tests: XCTestCase {

    // MARK: Frame decode

    func testDecodeDepthFrame() throws {
        let json = #"{"type":"depth","symbol":"AAPL","bids":[{"px":190.10,"sz":300,"count":4},{"px":190.05,"sz":150,"count":2}],"asks":[{"px":190.15,"sz":200,"count":3}],"depth":10,"source":"IBKR","is_live":true,"ts_ms":123}"#
        guard case .depth(let d) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected depth")
        }
        XCTAssertEqual(d.symbol, "AAPL")
        XCTAssertEqual(d.bids.count, 2)
        XCTAssertEqual(d.bids.first?.px, 190.10)
        XCTAssertEqual(d.bids.first?.count, 4)
        XCTAssertEqual(d.asks.first?.px, 190.15)
        XCTAssertEqual(d.depth, 10)
        XCTAssertEqual(d.source, "IBKR")
        XCTAssertTrue(d.is_live)
    }

    func testDecodeTapeFrameAggressorBuy() throws {
        let json = #"{"type":"tape","symbol":"AAPL","px":190.12,"sz":100,"aggressor":"buy","ts_ms":5,"is_live":true}"#
        guard case .tape(let p) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected tape")
        }
        XCTAssertEqual(p.px, 190.12)
        XCTAssertEqual(p.sz, 100)
        XCTAssertEqual(p.aggressor, .buy)
        XCTAssertTrue(p.is_live)
    }

    func testDecodeTapeFrameAggressorSell() throws {
        let json = #"{"type":"tape","symbol":"AAPL","px":190.00,"sz":50,"aggressor":"sell","ts_ms":6,"is_live":false}"#
        guard case .tape(let p) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected tape")
        }
        XCTAssertEqual(p.aggressor, .sell)
        XCTAssertFalse(p.is_live)
    }

    func testDecodeLeanDepthDefaults() throws {
        // A minimal payload must decode (Depth is droppable) with empty sides,
        // zero depth, empty source, and — the honesty rule — is_live == false.
        let json = #"{"type":"depth","symbol":"AAPL","ts_ms":1}"#
        guard case .depth(let d) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected depth")
        }
        XCTAssertTrue(d.bids.isEmpty)
        XCTAssertTrue(d.asks.isEmpty)
        XCTAssertEqual(d.depth, 0)
        XCTAssertEqual(d.source, "")
        XCTAssertFalse(d.is_live)
    }

    func testDecodeLevelWithoutCountDefaultsZero() throws {
        // A venue that omits the order count → count == 0 (the UI hides it).
        let json = #"{"type":"depth","symbol":"AAPL","bids":[{"px":190.1,"sz":300}],"asks":[],"depth":1,"source":"x","is_live":false,"ts_ms":1}"#
        guard case .depth(let d) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected depth")
        }
        XCTAssertEqual(d.bids.first?.count, 0)
    }

    func testDecodeLegacyTapeWithoutAggressorOrIsLive() throws {
        // Older engines omit aggressor + is_live: aggressor → nil (unknown),
        // is_live → false (never claim live).
        let json = #"{"type":"tape","symbol":"AAPL","px":10,"sz":1,"ts_ms":1}"#
        guard case .tape(let p) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected tape")
        }
        XCTAssertNil(p.aggressor)
        XCTAssertFalse(p.is_live)
    }

    // MARK: Command encode

    func testEncodeSubscribeDepthCommand() throws {
        let data = try Command.subscribeDepth(symbol: "AAPL").encoded()
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["cmd"] as? String, "subscribe_depth")
        XCTAssertEqual(obj["symbol"] as? String, "AAPL")
    }

    func testEncodeUnsubscribeDepthCommand() throws {
        let data = try Command.unsubscribeDepth(symbol: "BTC-USD").encoded()
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["cmd"] as? String, "unsubscribe_depth")
        XCTAssertEqual(obj["symbol"] as? String, "BTC-USD")
    }

    // MARK: Ladder sort (best-first) + drops invalid prices

    func testSortedBidsBestFirstDropsInvalid() {
        let levels = [
            level(190.00, 1), level(190.10, 2), level(190.05, 3),
            level(0, 9), level(.nan, 9),
        ]
        XCTAssertEqual(DepthLadder.sortedBids(levels).map(\.px), [190.10, 190.05, 190.00])
    }

    func testSortedAsksBestFirstDropsInvalid() {
        let levels = [level(190.20, 1), level(190.15, 2), level(190.25, 3), level(-1, 9)]
        XCTAssertEqual(DepthLadder.sortedAsks(levels).map(\.px), [190.15, 190.20, 190.25])
    }

    // MARK: Size-bar fraction (shared scale, NaN-safe)

    func testMaxSizeAcrossBothSides() {
        let bids = [level(1, 1), level(2, 5)]
        let asks = [level(3, 3), level(4, .nan)]
        XCTAssertEqual(DepthLadder.maxSize(bids: bids, asks: asks), 5)
    }

    func testBarFractionClampsAndIsNaNSafe() {
        XCTAssertEqual(DepthLadder.barFraction(size: 50, maxSize: 100), 0.5, accuracy: 1e-9)
        XCTAssertEqual(DepthLadder.barFraction(size: 200, maxSize: 100), 1, accuracy: 1e-9)
        XCTAssertEqual(DepthLadder.barFraction(size: .nan, maxSize: 100), 0)
        XCTAssertEqual(DepthLadder.barFraction(size: 50, maxSize: 0), 0)
        XCTAssertEqual(DepthLadder.barFraction(size: 50, maxSize: .nan), 0)
        XCTAssertEqual(DepthLadder.barFraction(size: -5, maxSize: 100), 0)
    }

    // MARK: Mid / spread

    func testMidAndSpread() {
        XCTAssertEqual(DepthLadder.mid(bestBid: 100, bestAsk: 102), 101)
        XCTAssertEqual(DepthLadder.spread(bestBid: 100, bestAsk: 102), 2)
        // One-sided book: no honest mid or spread.
        XCTAssertNil(DepthLadder.mid(bestBid: 100, bestAsk: nil))
        XCTAssertNil(DepthLadder.spread(bestBid: nil, bestAsk: 102))
        // Crossed book: mid is still numerically defined, spread is not.
        XCTAssertEqual(DepthLadder.mid(bestBid: 103, bestAsk: 100), 101.5)
        XCTAssertNil(DepthLadder.spread(bestBid: 103, bestAsk: 100))
    }

    // MARK: Aggressor tone

    func testAggressorToneMapping() {
        XCTAssertEqual(AggressorTone.tone(for: .buy), .up)
        XCTAssertEqual(AggressorTone.tone(for: .sell), .down)
        XCTAssertEqual(AggressorTone.tone(for: nil), .neutral)
    }

    // MARK: Real / delayed banner (honesty)

    func testBannerWaitingWhenNoDepth() {
        let b = DepthBanner.make(for: nil)
        XCTAssertEqual(b.kind, .waiting)
        XCTAssertFalse(b.isLive)
    }

    func testBannerLiveOnlyWhenIsLive() {
        let b = DepthBanner.make(for: depth(isLive: true, source: "IBKR"))
        XCTAssertEqual(b.kind, .live)
        XCTAssertTrue(b.isLive)
        XCTAssertEqual(b.source, "IBKR")
    }

    func testBannerDelayedNeverStyledLive() {
        let b = DepthBanner.make(for: depth(isLive: false, source: "synthetic L1"))
        XCTAssertEqual(b.kind, .delayed)
        XCTAssertFalse(b.isLive)
        XCTAssertTrue(b.note.contains("delayed"))
    }

    // MARK: Fixtures

    private func level(_ px: Double, _ sz: Double, count: UInt32 = 0) -> BookLevel {
        BookLevel(px: px, sz: sz, count: count)
    }

    private func depth(isLive: Bool, source: String) -> BookDepth {
        BookDepth(
            symbol: "AAPL", bids: [level(100, 1)], asks: [level(101, 1)],
            depth: 1, source: source, is_live: isLive, ts_ms: 1
        )
    }
}

// MARK: - Model application (subscription guard, ring cap, ticket hook)

@MainActor
final class Level2ModelTests: XCTestCase {

    func testDepthFrameOnlyAcceptedForSubscribedSymbol() {
        let model = AppModel()
        model.subscribeDepth("AAPL")
        model.apply(.depth(depth("AAPL", isLive: true)))
        XCTAssertEqual(model.bookDepth?.symbol, "AAPL")
        // A frame for a symbol we are not subscribed to must never overwrite it.
        model.apply(.depth(depth("MSFT", isLive: true)))
        XCTAssertEqual(model.bookDepth?.symbol, "AAPL")
    }

    func testTapeRingCapKeepsNewestFirst() {
        let model = AppModel()
        model.subscribeDepth("BTC-USD")
        for i in 0..<(AppModel.tapeCap + 25) {
            model.apply(.tape(print("BTC-USD", px: Double(i), ts: Int64(i))))
        }
        XCTAssertEqual(model.tape.count, AppModel.tapeCap)
        // Newest print is inserted at the front.
        XCTAssertEqual(model.tape.first?.ts_ms, Int64(AppModel.tapeCap + 24))
    }

    func testTapeIgnoredForUnsubscribedSymbol() {
        let model = AppModel()
        model.subscribeDepth("AAPL")
        model.apply(.tape(print("MSFT", px: 1, ts: 1)))
        XCTAssertTrue(model.tape.isEmpty)
    }

    func testSubscribeClearsPreviousBookAndIsIdempotent() {
        let model = AppModel()
        model.subscribeDepth("AAPL")
        model.apply(.depth(depth("AAPL", isLive: true)))
        XCTAssertNotNil(model.bookDepth)
        // Re-subscribing the SAME symbol is a no-op: the book survives.
        model.subscribeDepth("AAPL")
        XCTAssertNotNil(model.bookDepth)
        // Switching symbol clears the stale book + tape.
        model.subscribeDepth("MSFT")
        XCTAssertNil(model.bookDepth)
        XCTAssertTrue(model.tape.isEmpty)
        XCTAssertEqual(model.depthSymbol, "MSFT")
    }

    func testUnsubscribeClearsState() {
        let model = AppModel()
        model.subscribeDepth("AAPL")
        model.apply(.depth(depth("AAPL", isLive: true)))
        model.unsubscribeDepth()
        XCTAssertNil(model.depthSymbol)
        XCTAssertNil(model.bookDepth)
        XCTAssertTrue(model.tape.isEmpty)
    }

    func testDisconnectClearsDepthState() {
        let model = AppModel()
        model.handleStateChange(.connected)
        model.subscribeDepth("AAPL")
        model.apply(.depth(depth("AAPL", isLive: true)))
        model.apply(.tape(print("AAPL", px: 1, ts: 1)))
        model.handleStateChange(.disconnected)
        XCTAssertNil(model.bookDepth)
        XCTAssertTrue(model.tape.isEmpty)
        XCTAssertNil(model.depthSymbol)
    }

    func testSnapshotDepthAdoptedForSubscribedSymbolOnly() {
        let model = AppModel()
        model.subscribeDepth("AAPL")
        model.apply(.snapshot(snapshot(
            symbols: ["AAPL"],
            depth: ["AAPL": depth("AAPL", isLive: true), "MSFT": depth("MSFT", isLive: true)]
        )))
        XCTAssertEqual(model.bookDepth?.symbol, "AAPL")
    }

    func testSetTicketPriceIsNaNSafe() {
        let model = AppModel()
        model.setTicketPrice(.nan)
        XCTAssertNil(model.pendingTicketPrice)
        model.setTicketPrice(0)
        XCTAssertNil(model.pendingTicketPrice)
        model.setTicketPrice(-5)
        XCTAssertNil(model.pendingTicketPrice)
        model.setTicketPrice(190.25)
        XCTAssertEqual(model.pendingTicketPrice, 190.25)
        model.clearTicketPrice()
        XCTAssertNil(model.pendingTicketPrice)
    }

    // MARK: Fixtures

    private func depth(_ symbol: String, isLive: Bool) -> BookDepth {
        BookDepth(
            symbol: symbol,
            bids: [BookLevel(px: 100, sz: 1, count: 1)],
            asks: [BookLevel(px: 101, sz: 1, count: 1)],
            depth: 1, source: "test", is_live: isLive, ts_ms: 1
        )
    }

    private func print(_ symbol: String, px: Double, ts: Int64) -> TapePrint {
        TapePrint(symbol: symbol, px: px, sz: 1, aggressor: .buy, ts_ms: ts, is_live: true)
    }

    private func snapshot(symbols: [String], depth: [String: BookDepth]) -> EngineSnapshot {
        EngineSnapshot(
            symbols: symbols, bars: [:], positions: [], account: nil,
            risk: nil, thoughts: [], orders: [], macro: nil, feeds: nil,
            regimes: nil, geo: nil, scan: nil, news: nil, search_universe: nil,
            depth: depth
        )
    }
}
