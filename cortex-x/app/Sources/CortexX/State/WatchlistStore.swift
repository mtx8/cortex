// Named watchlists + per-symbol star / note metadata for the left rail,
// persisted as one JSON blob in UserDefaults. The "main" view is the
// engine's symbol list and is never stored; custom lists carry their own
// symbol arrays. Stars and notes are keyed by symbol only, so they apply
// across every list.

import Foundation
import Observation

/// One user-defined watchlist. The engine "main" view is not a UserWatchlist
/// — a nil selection in the store means "show the engine symbols".
struct UserWatchlist: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var symbols: [String]

    init(id: UUID = UUID(), name: String, symbols: [String] = []) {
        self.id = id
        self.name = name
        self.symbols = symbols
    }
}

/// Watchlist state: custom lists, the active selection, per-symbol stars and
/// notes, and the starred-only filter. Loads once at init, saves on every
/// mutation. Symbols are normalized uppercase throughout.
@MainActor
@Observable
final class WatchlistStore {
    private(set) var lists: [UserWatchlist] = []
    /// Selected custom list id; nil = the "main" engine symbols view.
    private(set) var selectedListID: UUID?
    /// Star filter chip: show starred rows only.
    private(set) var starredOnly = false
    private(set) var stars: Set<String> = []
    private(set) var notes: [String: String] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "watchlists.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.key),
            let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        lists = p.lists
        stars = Set(p.stars)
        notes = p.notes
        starredOnly = p.starredOnly
        // A selection pointing at a deleted list falls back to main.
        if let id = p.selectedListID, lists.contains(where: { $0.id == id }) {
            selectedListID = id
        }
    }

    // MARK: - Lists

    var selectedList: UserWatchlist? {
        selectedListID.flatMap { id in lists.first { $0.id == id } }
    }

    /// nil selects the main (engine symbols) view; unknown ids are ignored.
    func select(_ id: UUID?) {
        if let id { guard lists.contains(where: { $0.id == id }) else { return } }
        selectedListID = id
        save()
    }

    /// Creates and selects a new empty list. Blank names are rejected.
    @discardableResult
    func createList(named name: String) -> UUID? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let list = UserWatchlist(name: name)
        lists.append(list)
        selectedListID = list.id
        save()
        return list.id
    }

    func renameList(id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let i = lists.firstIndex(where: { $0.id == id }) else { return }
        lists[i].name = name
        save()
    }

    /// Deletes a list; a deleted selection falls back to the main view.
    /// Stars and notes are symbol-scoped, so they survive.
    func deleteList(id: UUID) {
        let before = lists.count
        lists.removeAll { $0.id == id }
        guard lists.count != before else { return }
        if selectedListID == id { selectedListID = nil }
        save()
    }

    // MARK: - Membership

    func addSymbol(_ symbol: String, to id: UUID) {
        let symbol = Self.norm(symbol)
        guard !symbol.isEmpty, let i = lists.firstIndex(where: { $0.id == id }),
            !lists[i].symbols.contains(symbol) else { return }
        lists[i].symbols.append(symbol)
        save()
    }

    func removeSymbol(_ symbol: String, from id: UUID) {
        let symbol = Self.norm(symbol)
        guard let i = lists.firstIndex(where: { $0.id == id }) else { return }
        let before = lists[i].symbols.count
        lists[i].symbols.removeAll { $0 == symbol }
        guard lists[i].symbols.count != before else { return }
        save()
    }

    // MARK: - Stars & notes (per-symbol, shared across lists)

    func isStarred(_ symbol: String) -> Bool {
        stars.contains(Self.norm(symbol))
    }

    func toggleStar(_ symbol: String) {
        let symbol = Self.norm(symbol)
        guard !symbol.isEmpty else { return }
        if stars.contains(symbol) { stars.remove(symbol) } else { stars.insert(symbol) }
        save()
    }

    func note(for symbol: String) -> String {
        notes[Self.norm(symbol)] ?? ""
    }

    /// Persists a note; an empty (whitespace-only) note removes the entry.
    func setNote(_ text: String, for symbol: String) {
        let symbol = Self.norm(symbol)
        guard !symbol.isEmpty else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard notes.removeValue(forKey: symbol) != nil else { return }
        } else {
            notes[symbol] = text
        }
        save()
    }

    func toggleStarredOnly() {
        starredOnly.toggle()
        save()
    }

    // MARK: - Display

    /// Row order for one rail group: the starred-only filter applied when
    /// engaged, then starred rows pinned first — both partitions keep their
    /// incoming (engine / list) order.
    func displayOrder(_ symbols: [String]) -> [String] {
        let base = starredOnly ? symbols.filter { isStarred($0) } : symbols
        return base.filter { isStarred($0) } + base.filter { !isStarred($0) }
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var lists: [UserWatchlist]
        var stars: [String]
        var notes: [String: String]
        var selectedListID: UUID?
        var starredOnly: Bool
    }

    private func save() {
        let p = Persisted(
            lists: lists, stars: stars.sorted(), notes: notes,
            selectedListID: selectedListID, starredOnly: starredOnly
        )
        if let data = try? JSONEncoder().encode(p) {
            defaults.set(data, forKey: Self.key)
        }
    }

    private static func norm(_ symbol: String) -> String {
        symbol.trimmingCharacters(in: .whitespaces).uppercased()
    }
}
