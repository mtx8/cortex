// Depth-subscription resync tests: the pure should-send decision that guarantees
// a dropped subscribe (send() no-ops off `.connected`) is re-delivered once the
// link is live, plus model-level checks that a crypto book is restored after
// connect and reconnect. Regression cover for the DOM/FLOW "waiting for depth"
// hang — the initial subscribe fired from the chart workspace's .onAppear while
// the socket was still opening, so it was lost while depthSymbol stayed set and
// the guarded re-subscribe no-oped forever.

import XCTest
@testable import CortexX

@MainActor
final class DepthResyncTests: XCTestCase {

    // MARK: - Pure should-send decision

    func testShouldResyncOnlyWhenConnectedAndNeeded() {
        // Disconnected: never send, whatever else is true.
        XCTAssertFalse(AppModel.shouldResyncDepth(
            connected: false, depthNeeded: true, depthSymbol: "ETH-USD", everDelivered: false
        ))
        // Connected but the dock needs no book (e.g. only the L1 strip is on):
        // never send.
        XCTAssertFalse(AppModel.shouldResyncDepth(
            connected: true, depthNeeded: false, depthSymbol: "ETH-USD", everDelivered: false
        ))
    }

    func testShouldResyncWhenSubscribeWasDropped() {
        // Connected, a book is needed, a symbol is targeted, but no frame ever
        // landed — the initial subscribe was dropped while disconnected. Re-send.
        XCTAssertTrue(AppModel.shouldResyncDepth(
            connected: true, depthNeeded: true, depthSymbol: "ETH-USD", everDelivered: false
        ))
    }

    func testShouldResyncFreshWhenNothingTargeted() {
        // A reconnect cleared depthSymbol — a fresh subscribe is still owed.
        XCTAssertTrue(AppModel.shouldResyncDepth(
            connected: true, depthNeeded: true, depthSymbol: nil, everDelivered: false
        ))
    }

    func testNoResyncWhenAlreadyDelivering() {
        // Frames already flowing for the targeted symbol — a resend would only
        // thrash the engine.
        XCTAssertFalse(AppModel.shouldResyncDepth(
            connected: true, depthNeeded: true, depthSymbol: "ETH-USD", everDelivered: true
        ))
    }

    // MARK: - Model-level restoration (the reported hang)

    func testResyncRestoresDepthWhenSubscribeSurvivesConnect() {
        // Reproduce the pinpointed race: the chart workspace subscribes from
        // .onAppear while the socket is still opening (.connecting), so the
        // command is dropped BUT depthSymbol is set. The old guarded re-subscribe
        // then no-oped on connect (symbol unchanged) and the book never populated.
        let model = AppModel()
        model.selectedSymbol = "ETH-USD"
        model.handleStateChange(.connecting)
        model.subscribeDepth(model.selectedSymbol)       // send dropped, symbol set
        XCTAssertEqual(model.depthSymbol, "ETH-USD")
        XCTAssertFalse(model.depthDelivered)

        // Socket goes live; the workspace's connect handler force-resyncs.
        model.handleStateChange(.connected)
        model.resyncDepth(depthNeeded: true)
        XCTAssertEqual(model.depthSymbol, "ETH-USD")

        // The engine now streams the book; the late-frame guard admits it and the
        // delivered flag flips, so no further resend is owed.
        model.apply(.depth(depth(symbol: "ETH-USD")))
        XCTAssertEqual(model.bookDepth?.symbol, "ETH-USD")
        XCTAssertTrue(model.depthDelivered)
        XCTAssertFalse(AppModel.shouldResyncDepth(
            connected: true, depthNeeded: true,
            depthSymbol: model.depthSymbol, everDelivered: model.depthDelivered
        ))
    }

    func testResyncFreshSubscribesForSelectedSymbolAfterReconnect() {
        // A live, delivering book drops with the connection: depthSymbol is
        // cleared. On reconnect resyncDepth must re-target the selected symbol.
        let model = AppModel()
        model.selectedSymbol = "ETH-USD"
        model.handleStateChange(.connected)
        model.subscribeDepth("ETH-USD")
        model.apply(.depth(depth(symbol: "ETH-USD")))
        XCTAssertTrue(model.depthDelivered)

        model.handleStateChange(.disconnected)
        XCTAssertNil(model.depthSymbol)
        XCTAssertFalse(model.depthDelivered)

        model.handleStateChange(.connected)
        model.resyncDepth(depthNeeded: true)
        XCTAssertEqual(model.depthSymbol, "ETH-USD")
        model.apply(.depth(depth(symbol: "ETH-USD")))
        XCTAssertEqual(model.bookDepth?.symbol, "ETH-USD")
    }

    func testResyncNoOpWhenDepthNotNeeded() {
        // Dock shows only L1 (or nothing): connecting must not open a book.
        let model = AppModel()
        model.selectedSymbol = "ETH-USD"
        model.handleStateChange(.connected)
        model.resyncDepth(depthNeeded: false)
        XCTAssertNil(model.depthSymbol)
        XCTAssertNil(model.bookDepth)
    }

    func testResyncNoOpWhileDisconnected() {
        // A resync attempt before the link is live must not fabricate state.
        let model = AppModel()
        model.selectedSymbol = "ETH-USD"
        model.resyncDepth(depthNeeded: true)
        XCTAssertNil(model.depthSymbol)
        XCTAssertNil(model.bookDepth)
    }

    // MARK: - Fixtures

    private func depth(symbol: String) -> BookDepth {
        BookDepth(
            symbol: symbol,
            bids: [BookLevel(px: 100, sz: 1, count: 0)],
            asks: [BookLevel(px: 101, sz: 1, count: 0)],
            depth: 1, source: "test", is_live: true, ts_ms: 1
        )
    }
}
