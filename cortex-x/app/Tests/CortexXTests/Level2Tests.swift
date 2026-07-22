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

    func testDecodeDepthFrameCarriesMarketMakerRoutes() throws {
        // IBKR-style attributed L2: each level carries an mm route; a blank/absent
        // route decodes to nil (never an empty badge).
        let json = #"{"type":"depth","symbol":"AAPL","bids":[{"px":190.10,"sz":300,"count":0,"mm":"NSDQ"},{"px":190.10,"sz":150,"count":0,"mm":"ARCA"},{"px":190.05,"sz":90,"count":0,"mm":"  "}],"asks":[{"px":190.15,"sz":200,"count":0,"mm":"EDGX"}],"depth":10,"source":"ibkr L2","is_live":true,"ts_ms":1}"#
        guard case .depth(let d) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected depth")
        }
        XCTAssertEqual(d.bids.count, 3)
        XCTAssertEqual(d.bids[0].mm, "NSDQ")
        XCTAssertEqual(d.bids[1].mm, "ARCA")           // same price, different maker — kept separate
        XCTAssertEqual(d.bids[1].px, d.bids[0].px)
        XCTAssertNil(d.bids[2].mm, "blank route id must decode to nil")
        XCTAssertEqual(d.asks[0].mm, "EDGX")
    }

    func testDecodeAnonymousDepthHasNilRoutes() throws {
        // Coinbase-style aggregated book: no mm key at all -> nil routes.
        let json = #"{"type":"depth","symbol":"BTC-USD","bids":[{"px":64000,"sz":1.2,"count":0}],"asks":[{"px":64001,"sz":0.8,"count":0}],"depth":20,"source":"coinbase l2","is_live":true,"ts_ms":1}"#
        guard case .depth(let d) = try ServerFrame.decode(Data(json.utf8)) else {
            return XCTFail("expected depth")
        }
        XCTAssertNil(d.bids.first?.mm)
        XCTAssertNil(d.asks.first?.mm)
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

    // MARK: Centered-ladder visible slices (ask-above / bid-below ordering)

    func testVisibleAskRowsHighestToBestNearestSpread() {
        // Asks arrive best-first (lowest price first). The visible slice is the
        // `count` nearest the inside market, ordered top→bottom: HIGHEST shown
        // ask first, BEST ask last (directly above the spread row).
        let asks = DepthLadder.sortedAsks([level(190.25, 1), level(190.15, 2), level(190.20, 3)])
        let rows = DepthLadder.visibleAskRows(asks, count: 2)
        XCTAssertEqual(rows.map(\.px), [190.20, 190.15])
        XCTAssertEqual(rows.last?.px, 190.15, "best ask sits last, nearest the spread")
        XCTAssertEqual(rows.first?.px, 190.20, "higher ask sits at the top")
    }

    func testVisibleBidRowsBestToLowest() {
        // Bids best-first (highest first): top→bottom is BEST bid first (nearest
        // the spread), lower bids beneath.
        let bids = DepthLadder.sortedBids([level(190.00, 1), level(190.10, 2), level(190.05, 3)])
        let rows = DepthLadder.visibleBidRows(bids, count: 2)
        XCTAssertEqual(rows.map(\.px), [190.10, 190.05])
        XCTAssertEqual(rows.first?.px, 190.10, "best bid sits first, nearest the spread")
    }

    func testVisibleRowsClampCountAndFloorAtZero() {
        let asks = [level(1, 1), level(2, 1), level(3, 1)]
        // An over-long count returns all available (no crash / over-read).
        XCTAssertEqual(DepthLadder.visibleAskRows(asks, count: 99).count, 3)
        XCTAssertEqual(DepthLadder.visibleBidRows(asks, count: 99).count, 3)
        // Non-positive counts show nothing.
        XCTAssertTrue(DepthLadder.visibleAskRows(asks, count: 0).isEmpty)
        XCTAssertTrue(DepthLadder.visibleBidRows(asks, count: -4).isEmpty)
    }

    // MARK: Centered-ladder fill math (inside market centered; fewer / overflow)

    func testLadderFillCentersInsideMarketWithDeepBook() {
        // A deep book on both sides: rows pack to the per-side capacity and the
        // spread row lands dead-center (equal height above and below it).
        let l = LadderLayout.fit(
            height: 440, rowHeight: 22, spreadHeight: 26, askCount: 20, bidCount: 20
        )
        let sideHeight = (440.0 - 26.0) / 2  // 207
        XCTAssertEqual(l.perSideCapacity, 9)          // floor(207/22)
        XCTAssertEqual(l.visibleAsks, 9)
        XCTAssertEqual(l.visibleBids, 9)
        XCTAssertEqual(l.topPad, 9, accuracy: 1e-9)   // 207 - 9*22
        XCTAssertEqual(l.bottomPad, 9, accuracy: 1e-9)
        // The inside market is centered: height above the spread == below it.
        XCTAssertEqual(l.topPad + Double(l.visibleAsks) * 22, sideHeight, accuracy: 1e-9)
        XCTAssertEqual(l.bottomPad + Double(l.visibleBids) * 22, sideHeight, accuracy: 1e-9)
    }

    func testLadderFillFewerLevelsStayCenteredNoVoid() {
        // Far fewer levels than fit: the spread row stays centered, the levels
        // hug it, and the leftover height pads the OUTER edges (never a void
        // above with the rows bottom-anchored).
        let l = LadderLayout.fit(
            height: 440, rowHeight: 22, spreadHeight: 26, askCount: 2, bidCount: 1
        )
        let sideHeight = (440.0 - 26.0) / 2  // 207
        XCTAssertEqual(l.visibleAsks, 2)
        XCTAssertEqual(l.visibleBids, 1)
        XCTAssertEqual(l.topPad, 207 - 44, accuracy: 1e-9)
        XCTAssertEqual(l.bottomPad, 207 - 22, accuracy: 1e-9)
        // Still centered despite the asymmetric, shallow book.
        XCTAssertEqual(l.topPad + Double(l.visibleAsks) * 22, sideHeight, accuracy: 1e-9)
        XCTAssertEqual(l.bottomPad + Double(l.visibleBids) * 22, sideHeight, accuracy: 1e-9)
    }

    func testLadderFillOverflowClampsToCapacityBestFirst() {
        // A short pane with a deep book: each side clamps to the per-side
        // capacity (the nearest-the-spread levels win), spread still centered.
        let l = LadderLayout.fit(
            height: 200, rowHeight: 22, spreadHeight: 26, askCount: 10, bidCount: 10
        )
        let sideHeight = (200.0 - 26.0) / 2  // 87
        XCTAssertEqual(l.perSideCapacity, 3)          // floor(87/22)
        XCTAssertEqual(l.visibleAsks, 3)
        XCTAssertEqual(l.visibleBids, 3)
        XCTAssertEqual(l.topPad + Double(l.visibleAsks) * 22, sideHeight, accuracy: 1e-9)
    }

    func testLadderFillDegenerateAndNaNSafe() {
        // A pane too short for even one level: only the (centered) spread row.
        let tiny = LadderLayout.fit(
            height: 20, rowHeight: 22, spreadHeight: 26, askCount: 5, bidCount: 5
        )
        XCTAssertEqual(tiny, LadderLayout(
            visibleAsks: 0, visibleBids: 0, topPad: 0, bottomPad: 0, perSideCapacity: 0
        ))
        // Non-finite / non-positive geometry and negative counts yield an empty
        // layout (renders nothing rather than a bogus fill).
        let empty = LadderLayout(
            visibleAsks: 0, visibleBids: 0, topPad: 0, bottomPad: 0, perSideCapacity: 0
        )
        XCTAssertEqual(LadderLayout.fit(height: .nan, rowHeight: 22, spreadHeight: 26, askCount: 5, bidCount: 5), empty)
        XCTAssertEqual(LadderLayout.fit(height: 440, rowHeight: 0, spreadHeight: 26, askCount: 5, bidCount: 5), empty)
        XCTAssertEqual(LadderLayout.fit(height: -10, rowHeight: 22, spreadHeight: 26, askCount: 5, bidCount: 5), empty)
        let negCounts = LadderLayout.fit(height: 440, rowHeight: 22, spreadHeight: 26, askCount: -3, bidCount: -1)
        XCTAssertEqual(negCounts.visibleAsks, 0)
        XCTAssertEqual(negCounts.visibleBids, 0)
    }

    // MARK: Canvas ladder row geometry (draw + hit-test share one source)

    func testLadderRowsStackAsksAboveSpreadAboveBids() {
        // A fitted layout with 2 asks above, the centered spread band, 2 bids
        // below. Asks arrive in DISPLAY order (highest→best), bids best→lowest.
        let layout = LadderLayout(
            visibleAsks: 2, visibleBids: 2, topPad: 10, bottomPad: 10, perSideCapacity: 5
        )
        let asks = [level(190.20, 3), level(190.15, 7)]
        let bids = [level(190.10, 5), level(190.05, 2)]
        let rows = LadderGeometry.rows(
            layout: layout, asks: asks, bids: bids, rowHeight: 22, spreadHeight: 26
        )
        XCTAssertEqual(rows.count, 5)
        // Asks first, top→bottom from topPad; best ask is the LAST ask (nearest
        // the spread band).
        XCTAssertEqual(rows[0].kind, .ask)
        XCTAssertEqual(rows[0].minY, 10, accuracy: 1e-9)
        XCTAssertEqual(rows[0].level?.px, 190.20)
        XCTAssertFalse(rows[0].isBest)
        XCTAssertEqual(rows[1].kind, .ask)
        XCTAssertEqual(rows[1].minY, 32, accuracy: 1e-9)
        XCTAssertEqual(rows[1].level?.px, 190.15)
        XCTAssertTrue(rows[1].isBest, "best ask is the last ask, nearest the spread")
        // Spread band centered between the two sides, no level.
        XCTAssertEqual(rows[2].kind, .spread)
        XCTAssertEqual(rows[2].minY, 54, accuracy: 1e-9)
        XCTAssertEqual(rows[2].height, 26, accuracy: 1e-9)
        XCTAssertNil(rows[2].level)
        // Bids below the spread, best (first) nearest it.
        XCTAssertEqual(rows[3].kind, .bid)
        XCTAssertEqual(rows[3].minY, 80, accuracy: 1e-9)
        XCTAssertEqual(rows[3].level?.px, 190.10)
        XCTAssertTrue(rows[3].isBest, "best bid is the first bid, nearest the spread")
        XCTAssertEqual(rows[4].kind, .bid)
        XCTAssertEqual(rows[4].minY, 102, accuracy: 1e-9)
        XCTAssertFalse(rows[4].isBest)
    }

    func testLadderHitTestMapsClickYToLevel() {
        let layout = LadderLayout(
            visibleAsks: 2, visibleBids: 2, topPad: 10, bottomPad: 10, perSideCapacity: 5
        )
        let asks = [level(190.20, 3), level(190.15, 7)]
        let bids = [level(190.10, 5), level(190.05, 2)]
        let rows = LadderGeometry.rows(
            layout: layout, asks: asks, bids: bids, rowHeight: 22, spreadHeight: 26
        )
        // A click inside the top ask row [10,32) → that ask.
        XCTAssertEqual(LadderGeometry.level(atY: 20, rows: rows)?.px, 190.20)
        // The best ask row [32,54).
        XCTAssertEqual(LadderGeometry.level(atY: 53, rows: rows)?.px, 190.15)
        // The spread band [54,80) → no tradeable level.
        XCTAssertNil(LadderGeometry.level(atY: 60, rows: rows))
        // The best bid row [80,102) and the lower bid row [102,124).
        XCTAssertEqual(LadderGeometry.level(atY: 90, rows: rows)?.px, 190.10)
        XCTAssertEqual(LadderGeometry.level(atY: 110, rows: rows)?.px, 190.05)
        // The outer top pad (above every row) and the outer bottom pad → nil.
        XCTAssertNil(LadderGeometry.level(atY: 5, rows: rows))
        XCTAssertNil(LadderGeometry.level(atY: 200, rows: rows))
    }

    func testLadderRowBoundariesAreHalfOpen() {
        // ask [0,20), spread [20,30), bid [30,50) — adjacent rows never both
        // claim a boundary pixel.
        let layout = LadderLayout(
            visibleAsks: 1, visibleBids: 1, topPad: 0, bottomPad: 0, perSideCapacity: 1
        )
        let rows = LadderGeometry.rows(
            layout: layout, asks: [level(2, 1)], bids: [level(1, 1)],
            rowHeight: 20, spreadHeight: 10
        )
        XCTAssertEqual(LadderGeometry.level(atY: 0, rows: rows)?.px, 2)   // ask top edge inclusive
        XCTAssertNil(LadderGeometry.level(atY: 20, rows: rows))          // spread top edge → spread (nil)
        XCTAssertEqual(LadderGeometry.level(atY: 30, rows: rows)?.px, 1) // bid top edge inclusive
        XCTAssertNil(LadderGeometry.level(atY: 50, rows: rows))          // past the last bid
    }

    func testLadderRowsEmptySidesYieldOnlySpread() {
        // A one-sided/empty book still lands a centered spread band and nothing
        // else — a click anywhere maps to no level.
        let layout = LadderLayout(
            visibleAsks: 0, visibleBids: 0, topPad: 100, bottomPad: 100, perSideCapacity: 0
        )
        let rows = LadderGeometry.rows(
            layout: layout, asks: [], bids: [], rowHeight: 22, spreadHeight: 26
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].kind, .spread)
        XCTAssertEqual(rows[0].minY, 100, accuracy: 1e-9)
        XCTAssertNil(LadderGeometry.level(atY: 100, rows: rows))
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

    // MARK: Side-by-side montage geometry (DepthMontage)

    func testMontageRowCapacityFloorsAndIsNaNSafe() {
        XCTAssertEqual(DepthMontage.rowCapacity(height: 100, rowHeight: 22), 4) // 100/22 = 4.5 -> 4
        XCTAssertEqual(DepthMontage.rowCapacity(height: 22, rowHeight: 22), 1)
        XCTAssertEqual(DepthMontage.rowCapacity(height: 10, rowHeight: 22), 0)  // shorter than one row
        XCTAssertEqual(DepthMontage.rowCapacity(height: .nan, rowHeight: 22), 0)
        XCTAssertEqual(DepthMontage.rowCapacity(height: 100, rowHeight: 0), 0)
        XCTAssertEqual(DepthMontage.rowCapacity(height: -5, rowHeight: 22), 0)
    }

    func testMontageColumnBuildsRankedRowsBestFirstCappedToCapacity() {
        let bids = DepthLadder.sortedBids([level(190.00, 1), level(190.10, 2), level(190.05, 3)])
        let rows = DepthMontage.column(bids, rowHeight: 20, capacity: 2, topY: 0)
        XCTAssertEqual(rows.count, 2)                          // capped to capacity
        XCTAssertEqual(rows.map(\.level.px), [190.10, 190.05]) // best-first
        XCTAssertEqual(rows.map(\.rank), [0, 1])               // 0 = inside market
        XCTAssertTrue(rows[0].isBest)
        XCTAssertFalse(rows[1].isBest)
        XCTAssertEqual(rows[0].minY, 0)
        XCTAssertEqual(rows[1].minY, 20)                       // stacked by rowHeight
        XCTAssertEqual(rows[1].maxY, 40)
    }

    func testMontageColumnEmptyOnZeroCapacityOrRowHeight() {
        let asks = DepthLadder.sortedAsks([level(101, 1)])
        XCTAssertTrue(DepthMontage.column(asks, rowHeight: 20, capacity: 0, topY: 0).isEmpty)
        XCTAssertTrue(DepthMontage.column(asks, rowHeight: 0, capacity: 5, topY: 0).isEmpty)
    }

    func testMontageLevelHitTestIsHalfOpenAndBoundedByRows() {
        let bids = DepthLadder.sortedBids([level(190.10, 2), level(190.05, 3)])
        let rows = DepthMontage.column(bids, rowHeight: 20, capacity: 5, topY: 0)
        XCTAssertEqual(DepthMontage.level(atY: 0, rows: rows)?.px, 190.10)   // top of row 0
        XCTAssertEqual(DepthMontage.level(atY: 19.9, rows: rows)?.px, 190.10)
        XCTAssertEqual(DepthMontage.level(atY: 20, rows: rows)?.px, 190.05)  // half-open: boundary -> next row
        XCTAssertEqual(DepthMontage.level(atY: 39.9, rows: rows)?.px, 190.05)
        XCTAssertNil(DepthMontage.level(atY: 40, rows: rows))                // past the last row
        XCTAssertNil(DepthMontage.level(atY: -1, rows: rows))
    }

    func testMontageCumulativeSizeSkipsInvalid() {
        let levels = [level(1, 10), level(2, 5), level(3, .nan), level(4, -2)]
        XCTAssertEqual(DepthMontage.cumulativeSize(levels), 15, accuracy: 1e-9)
        XCTAssertEqual(DepthMontage.cumulativeSize([]), 0)
    }

    func testMontageImbalanceSignedClampedAndEmptySafe() {
        XCTAssertEqual(DepthMontage.imbalance(bidTotal: 75, askTotal: 25), 0.5, accuracy: 1e-9)  // bid-heavy
        XCTAssertEqual(DepthMontage.imbalance(bidTotal: 25, askTotal: 75), -0.5, accuracy: 1e-9) // ask-heavy
        XCTAssertEqual(DepthMontage.imbalance(bidTotal: 50, askTotal: 50), 0, accuracy: 1e-9)
        XCTAssertEqual(DepthMontage.imbalance(bidTotal: 0, askTotal: 0), 0)   // empty book, no divide-by-zero
        XCTAssertEqual(DepthMontage.imbalance(bidTotal: 10, askTotal: 0), 1)  // one-sided clamps to ±1
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
