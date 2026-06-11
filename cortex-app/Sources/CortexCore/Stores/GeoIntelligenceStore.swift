import Foundation

// MARK: - Models

public struct GeoVessel: Identifiable, Sendable {
    public let id: Int          // MMSI
    public var lat: Double
    public var lon: Double
    public var speedKnots: Double
    public var isTanker: Bool
    public var category: String
    public var chokepoint: String?
}

public struct GeoSeismicEvent: Identifiable, Sendable {
    public let id: String
    public var lat: Double
    public var lon: Double
    public var magnitude: Double
    public var label: String
}

public struct ChokepointCongestion: Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var vesselCount: Int
    public var tankerCount: Int
    public var avgSpeedKnots: Double
    public var congestionScore: Double
}

public struct GeoTicker: Sendable, Hashable {
    public var symbol: String
    public var direction: String   // "long" | "short"
}

public struct GeoAlphaSignal: Identifiable, Sendable {
    public let id: String
    public var kind: String        // floating_storage | chokepoint_congestion | seismic_proximity
    public var score: Double
    public var tickers: [GeoTicker]
    public var detail: String
    public var timestamp: Date
}

// MARK: - Store

/// Live geospatial physical-alpha state, populated from the geo feed
/// (GEO_POSITION / GEO_SIGNAL) and INDIA-squadron bus signals (india.geo_*).
@MainActor
@Observable
public final class GeoIntelligenceStore {
    public var vessels: [GeoVessel] = []
    public var events: [GeoSeismicEvent] = []
    public var congestion: [ChokepointCongestion] = []
    public var alpha: [GeoAlphaSignal] = []
    public var floatingStorageScore: Double = 0
    public var lastUpdate: Date?
    public var maxRenderVessels: Int = 2500
    public var maxAlpha: Int = 50

    public init() {}

    public var tankerCount: Int { vessels.reduce(0) { $0 + ($1.isTanker ? 1 : 0) } }
    public var inChokepointCount: Int { vessels.reduce(0) { $0 + ($1.chokepoint != nil ? 1 : 0) } }

    // MARK: Ingestion

    public func applyVessels(_ payload: [String: Any]) {
        guard let raw = payload["vessels"] as? [[String: Any]] else { return }
        var out: [GeoVessel] = []
        out.reserveCapacity(min(raw.count, maxRenderVessels))
        for v in raw.prefix(maxRenderVessels) {
            guard let lat = Self.double(v["lat"]), let lon = Self.double(v["lon"]) else { continue }
            out.append(GeoVessel(
                id: Self.int(v["mmsi"]) ?? 0,
                lat: lat, lon: lon,
                speedKnots: Self.double(v["speed_knots"]) ?? 0,
                isTanker: (v["is_tanker"] as? Bool) ?? false,
                category: v["category"] as? String ?? "unknown",
                chokepoint: v["chokepoint"] as? String
            ))
        }
        vessels = out
        lastUpdate = Date()
    }

    public func applyEvents(_ payload: [String: Any]) {
        guard let raw = payload["events"] as? [[String: Any]] else { return }
        events = raw.compactMap { e in
            guard let lat = Self.double(e["lat"]), let lon = Self.double(e["lon"]) else { return nil }
            return GeoSeismicEvent(
                id: e["id"] as? String ?? UUID().uuidString,
                lat: lat, lon: lon,
                magnitude: Self.double(e["magnitude"]) ?? 0,
                label: e["label"] as? String ?? ""
            )
        }
        lastUpdate = Date()
    }

    /// Route an INDIA-squadron bus signal (delivered as `signal_fired`) by type.
    public func applyBusSignal(type: String, _ payload: [String: Any]) {
        switch type {
        case "india.geo_chokepoint_congestion":
            upsertCongestion(payload)
        case "india.geo_floating_storage":
            floatingStorageScore = Self.double(payload["index_score"]) ?? floatingStorageScore
        case "india.geo_physical_alpha":
            appendAlpha(kind: payload["signal"] as? String ?? "physical_alpha", payload)
        case "india.geo_seismic_proximity":
            appendAlpha(kind: "seismic_proximity", payload)
        default:
            break
        }
        lastUpdate = Date()
    }

    private func upsertCongestion(_ p: [String: Any]) {
        guard let name = p["name"] as? String else { return }
        let row = ChokepointCongestion(
            name: name,
            vesselCount: Self.int(p["vessel_count"]) ?? 0,
            tankerCount: Self.int(p["tanker_count"]) ?? 0,
            avgSpeedKnots: Self.double(p["avg_speed_knots"]) ?? 0,
            congestionScore: Self.double(p["congestion_score"]) ?? 0
        )
        if let i = congestion.firstIndex(where: { $0.name == name }) {
            congestion[i] = row
        } else {
            congestion.append(row)
        }
        congestion.sort { $0.congestionScore > $1.congestionScore }
    }

    private func appendAlpha(kind: String, _ p: [String: Any]) {
        var tickers: [GeoTicker] = []
        if let arr = p["tickers"] as? [[String: Any]] {
            tickers = arr.map { GeoTicker(symbol: $0["symbol"] as? String ?? "",
                                          direction: $0["direction"] as? String ?? "long") }
        }
        let detail = (p["chokepoint"] as? String) ?? (p["asset"] as? String) ?? kind
        let score = Self.double(p["score"]) ?? Self.double(p["severity"]).map { $0 * 100 } ?? 0
        alpha.insert(GeoAlphaSignal(id: UUID().uuidString, kind: kind, score: score,
                                    tickers: tickers, detail: detail, timestamp: Date()), at: 0)
        if alpha.count > maxAlpha { alpha.removeLast(alpha.count - maxAlpha) }
    }

    // MARK: Globe payload

    /// Compact JSON for the WKWebView globe: vessels [lat,lon,tankerFlag],
    /// events [lat,lon,mag]. Kept small for fast evaluateJavaScript pushes.
    public func globePayloadJSON() -> String {
        let v = vessels.prefix(maxRenderVessels).map { [$0.lat, $0.lon, $0.isTanker ? 1.0 : 0.0] }
        let e = events.map { [$0.lat, $0.lon, $0.magnitude] }
        let obj: [String: Any] = ["vessels": v, "events": e]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{\"vessels\":[],\"events\":[]}" }
        return s
    }

    // MARK: Coercion helpers (orjson sends ints/doubles/bools)

    static func double(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }
    static func int(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}
