import Foundation

/// Live Treasury rate structure from the macro feed (MACRO_RATES message).
@MainActor
@Observable
public final class MacroRatesStore {
    public var date: String = ""
    public var rates: [(name: String, pct: Double)] = []   // sorted desc
    public var shortPct: Double?
    public var longPct: Double?
    public var spreadBps: Double?
    public var lastUpdate: Date?

    public init() {}

    public var inverted: Bool { (spreadBps ?? 0) < 0 }

    public func apply(_ payload: [String: Any]) {
        date = payload["date"] as? String ?? date
        if let r = payload["rates"] as? [String: Any] {
            rates = r.compactMap { (k, v) -> (String, Double)? in
                guard let d = GeoIntelligenceStore.double(v) else { return nil }
                return (k, d)
            }.sorted { $0.1 > $1.1 }
        }
        shortPct = GeoIntelligenceStore.double(payload["short_pct"])
        longPct = GeoIntelligenceStore.double(payload["long_pct"])
        spreadBps = GeoIntelligenceStore.double(payload["spread_bps"])
        lastUpdate = Date()
    }
}
