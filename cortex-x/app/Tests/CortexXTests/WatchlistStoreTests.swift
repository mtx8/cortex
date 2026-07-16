// WatchlistStore tests: named-list create / rename / delete with selection
// fallback, symbol membership normalization, per-symbol star + note
// metadata shared across lists, display ordering (starred pinned first,
// starred-only filter) and JSON persistence against an isolated
// UserDefaults suite.

import XCTest
@testable import CortexX

@MainActor
final class WatchlistStoreTests: XCTestCase {

    private static let suiteName = "cortexx.tests.watchlists"

    /// Fresh store over a wiped, isolated UserDefaults suite.
    private func makeStore() -> (defaults: UserDefaults, store: WatchlistStore) {
        let defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        return (defaults, WatchlistStore(defaults: defaults))
    }

    // MARK: - Lists

    func testMainIsTheDefaultSelection() {
        let (_, store) = makeStore()
        XCTAssertNil(store.selectedListID)
        XCTAssertNil(store.selectedList)
        XCTAssertTrue(store.lists.isEmpty)
    }

    func testCreateListSelectsItAndPersists() {
        let (defaults, store) = makeStore()
        let id = store.createList(named: "  momentum  ")
        XCTAssertNotNil(id)
        XCTAssertEqual(store.selectedListID, id)
        XCTAssertEqual(store.selectedList?.name, "momentum") // trimmed
        // A fresh store over the same suite reloads list + selection.
        let reloaded = WatchlistStore(defaults: defaults)
        XCTAssertEqual(reloaded.lists.map(\.name), ["momentum"])
        XCTAssertEqual(reloaded.selectedListID, id)
    }

    func testCreateListRejectsBlankNames() {
        let (_, store) = makeStore()
        XCTAssertNil(store.createList(named: ""))
        XCTAssertNil(store.createList(named: "   "))
        XCTAssertTrue(store.lists.isEmpty)
        XCTAssertNil(store.selectedListID)
    }

    func testRenameListTrimsAndRejectsBlank() {
        let (_, store) = makeStore()
        let id = store.createList(named: "alpha")!
        store.renameList(id: id, to: "  beta  ")
        XCTAssertEqual(store.selectedList?.name, "beta")
        store.renameList(id: id, to: "   ")
        XCTAssertEqual(store.selectedList?.name, "beta") // unchanged
    }

    func testDeleteSelectedListFallsBackToMain() {
        let (defaults, store) = makeStore()
        let keep = store.createList(named: "keep")!
        let drop = store.createList(named: "drop")!
        XCTAssertEqual(store.selectedListID, drop)
        store.deleteList(id: drop)
        XCTAssertNil(store.selectedListID) // back on main
        XCTAssertEqual(store.lists.map(\.id), [keep])
        XCTAssertEqual(WatchlistStore(defaults: defaults).lists.map(\.id), [keep])
    }

    func testDeleteUnselectedListKeepsSelection() {
        let (_, store) = makeStore()
        let other = store.createList(named: "other")!
        let active = store.createList(named: "active")!
        store.deleteList(id: other)
        XCTAssertEqual(store.selectedListID, active)
    }

    func testSelectIgnoresUnknownIDs() {
        let (_, store) = makeStore()
        let id = store.createList(named: "alpha")!
        store.select(UUID())
        XCTAssertEqual(store.selectedListID, id) // unchanged
        store.select(nil)
        XCTAssertNil(store.selectedListID)
    }

    // MARK: - Membership

    func testAddSymbolNormalizesAndDedupes() {
        let (_, store) = makeStore()
        let id = store.createList(named: "alpha")!
        store.addSymbol(" nvda ", to: id)
        store.addSymbol("NVDA", to: id)
        store.addSymbol("  ", to: id)
        XCTAssertEqual(store.selectedList?.symbols, ["NVDA"])
    }

    func testRemoveSymbol() {
        let (defaults, store) = makeStore()
        let id = store.createList(named: "alpha")!
        store.addSymbol("NVDA", to: id)
        store.addSymbol("SPY", to: id)
        store.removeSymbol("nvda", from: id)
        XCTAssertEqual(store.selectedList?.symbols, ["SPY"])
        XCTAssertEqual(
            WatchlistStore(defaults: defaults).lists.first?.symbols, ["SPY"]
        )
    }

    // MARK: - Stars & notes (symbol-scoped, shared across lists)

    func testToggleStarAppliesAcrossListsAndPersists() {
        let (defaults, store) = makeStore()
        let a = store.createList(named: "a")!
        let b = store.createList(named: "b")!
        store.addSymbol("NVDA", to: a)
        store.addSymbol("NVDA", to: b)
        store.toggleStar("nvda")
        XCTAssertTrue(store.isStarred("NVDA")) // one flag, every list
        XCTAssertTrue(WatchlistStore(defaults: defaults).isStarred("NVDA"))
        store.toggleStar("NVDA")
        XCTAssertFalse(store.isStarred("NVDA"))
        XCTAssertFalse(WatchlistStore(defaults: defaults).isStarred("NVDA"))
    }

    func testNotePersistsAndEmptyClears() {
        let (defaults, store) = makeStore()
        store.setNote("watch the 200d", for: "nvda")
        XCTAssertEqual(store.note(for: "NVDA"), "watch the 200d")
        XCTAssertEqual(
            WatchlistStore(defaults: defaults).note(for: "NVDA"), "watch the 200d"
        )
        // Whitespace-only notes delete the entry.
        store.setNote("  \n ", for: "NVDA")
        XCTAssertEqual(store.note(for: "NVDA"), "")
        XCTAssertEqual(WatchlistStore(defaults: defaults).note(for: "NVDA"), "")
    }

    // MARK: - Display order

    func testDisplayOrderPinsStarredFirstStable() {
        let (_, store) = makeStore()
        store.toggleStar("SPY")
        store.toggleStar("QQQ")
        // Starred keep their relative order, then the rest keep theirs.
        XCTAssertEqual(
            store.displayOrder(["NVDA", "SPY", "AAPL", "QQQ"]),
            ["SPY", "QQQ", "NVDA", "AAPL"]
        )
    }

    func testStarredOnlyFilters() {
        let (defaults, store) = makeStore()
        store.toggleStar("SPY")
        store.toggleStarredOnly()
        XCTAssertTrue(store.starredOnly)
        XCTAssertEqual(store.displayOrder(["NVDA", "SPY", "AAPL"]), ["SPY"])
        // The filter chip state persists too.
        XCTAssertTrue(WatchlistStore(defaults: defaults).starredOnly)
        store.toggleStarredOnly()
        XCTAssertEqual(
            store.displayOrder(["NVDA", "SPY", "AAPL"]), ["SPY", "NVDA", "AAPL"]
        )
    }

    // MARK: - Persistence hygiene

    func testStaleSelectionInPersistedBlobFallsBackToMain() throws {
        let (defaults, store) = makeStore()
        store.createList(named: "alpha")
        // Corrupt the selection to a list that no longer exists.
        var blob = try XCTUnwrap(
            try? JSONSerialization.jsonObject(
                with: XCTUnwrap(defaults.data(forKey: "watchlists.v1"))
            ) as? [String: Any]
        )
        blob["selectedListID"] = UUID().uuidString
        defaults.set(try JSONSerialization.data(withJSONObject: blob), forKey: "watchlists.v1")
        let reloaded = WatchlistStore(defaults: defaults)
        XCTAssertEqual(reloaded.lists.map(\.name), ["alpha"]) // lists survive
        XCTAssertNil(reloaded.selectedListID) // selection dropped
    }
}
