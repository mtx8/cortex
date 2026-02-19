import Foundation

@MainActor
@Observable
public final class KillSwitchStore {
    public var isActive: Bool = false
    public var isEngaging: Bool = false
    public var engagedAt: Date? = nil
    public var reason: String? = nil

    public init() {}

    public func engage() {
        isEngaging = true
        // Backend will confirm via WebSocket, which calls confirmEngaged
    }

    public func confirmEngaged(reason: String) {
        isEngaging = false
        isActive = true
        engagedAt = Date()
        self.reason = reason
    }

    public func disengage() {
        isActive = false
        isEngaging = false
        engagedAt = nil
        reason = nil
    }
}
