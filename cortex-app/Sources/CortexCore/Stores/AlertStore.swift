import Foundation

// MARK: - Model

public struct PriceAlert: Identifiable {
    public let id: String
    public let symbol: String
    public let alertType: AlertType
    public let threshold: Double
    public var status: AlertStatus
    public var message: String
    public var triggeredAt: Date?

    public enum AlertType: String {
        case priceAbove = "price_above"
        case priceBelow = "price_below"
        case pctChange = "pct_change"
    }

    public enum AlertStatus: String {
        case active
        case triggered
        case dismissed
    }

    public init(
        id: String,
        symbol: String,
        alertType: AlertType,
        threshold: Double,
        status: AlertStatus = .active,
        message: String = "",
        triggeredAt: Date? = nil
    ) {
        self.id = id
        self.symbol = symbol
        self.alertType = alertType
        self.threshold = threshold
        self.status = status
        self.message = message
        self.triggeredAt = triggeredAt
    }
}

// MARK: - Store

@MainActor
@Observable
public final class AlertStore {
    public var alerts: [PriceAlert] = []
    public var recentlyTriggered: [PriceAlert] = []
    public var webSocket: WebSocketClient?

    public init() {}

    // MARK: - Actions

    public func createAlert(symbol: String, type: PriceAlert.AlertType, threshold: Double) {
        let id = UUID().uuidString
        let alert = PriceAlert(
            id: id,
            symbol: symbol.uppercased(),
            alertType: type,
            threshold: threshold,
            status: .active,
            message: ""
        )
        alerts.append(alert)

        // Send to backend
        let msg: [String: Any] = [
            "type": "cmd_create_alert",
            "payload": [
                "id": id,
                "symbol": symbol.uppercased(),
                "alert_type": type.rawValue,
                "threshold": threshold,
            ] as [String: Any]
        ]
        Task { @MainActor in
            try? await webSocket?.send(msg)
        }
    }

    public func deleteAlert(id: String) {
        alerts.removeAll { $0.id == id }
        recentlyTriggered.removeAll { $0.id == id }
        let msg: [String: Any] = [
            "type": "cmd_delete_alert",
            "payload": ["id": id]
        ]
        Task { @MainActor in
            try? await webSocket?.send(msg)
        }
    }

    public func applyTriggered(_ payload: [String: Any]) {
        let id = payload["id"] as? String ?? ""
        let message = payload["message"] as? String ?? ""

        if let idx = alerts.firstIndex(where: { $0.id == id }) {
            alerts[idx].status = .triggered
            alerts[idx].message = message
            alerts[idx].triggeredAt = Date()
            recentlyTriggered.insert(alerts[idx], at: 0)
            if recentlyTriggered.count > 10 {
                recentlyTriggered.removeLast()
            }
        }
    }

    public func dismissAlert(id: String) {
        if let idx = alerts.firstIndex(where: { $0.id == id }) {
            alerts[idx].status = .dismissed
        }
        recentlyTriggered.removeAll { $0.id == id }
    }

    // MARK: - Computed

    public var activeAlerts: [PriceAlert] {
        alerts.filter { $0.status == .active }
    }

    public var triggeredAlerts: [PriceAlert] {
        alerts.filter { $0.status == .triggered }
    }
}
