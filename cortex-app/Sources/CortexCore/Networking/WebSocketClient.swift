import Foundation
import Logging

@MainActor
@Observable
public final class WebSocketClient {
    public let url: String
    public private(set) var isConnected: Bool = false
    public private(set) var lastError: String?
    public private(set) var messagesReceived: Int = 0

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var reconnectTask: Task<Void, Never>?
    private let logger = Logger(label: "cortex.websocket")
    private var shouldReconnect: Bool = true
    private let maxReconnectDelay: Double = 30.0
    private var reconnectAttempt: Int = 0

    public var onMessage: (@MainActor @Sendable ([String: Any]) -> Void)?

    public init(url: String = "ws://127.0.0.1:8765/ws") {
        self.url = url
    }

    public func connect() {
        guard let wsURL = URL(string: url) else {
            lastError = "Invalid URL: \(url)"
            return
        }
        shouldReconnect = true
        session?.invalidateAndCancel()
        let newSession = URLSession(configuration: .default)
        session = newSession
        webSocketTask = newSession.webSocketTask(with: wsURL)
        webSocketTask?.resume()
        lastError = nil
        receiveMessages()
    }

    public func disconnect() {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
    }

    public func send(_ data: [String: Any]) async throws {
        guard let task = webSocketTask else {
            throw URLError(.notConnectedToInternet)
        }
        let jsonData = try JSONSerialization.data(withJSONObject: data)
        try await task.send(.data(jsonData))
    }

    private func receiveMessages() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                switch result {
                case .success(let message):
                    if !self.isConnected {
                        self.isConnected = true
                        self.reconnectAttempt = 0
                    }
                    self.messagesReceived += 1
                    self.handleMessage(message)
                    self.receiveMessages() // Continue listening
                case .failure(let error):
                    self.logger.error("WebSocket error: \(error.localizedDescription)")
                    self.lastError = error.localizedDescription
                    self.isConnected = false
                    if self.shouldReconnect {
                        self.scheduleReconnect()
                    }
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                onMessage?(dict)
            }
        case .string(let text):
            if let data = text.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                onMessage?(dict)
            }
        @unknown default:
            break
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let delay = min(pow(2.0, Double(reconnectAttempt)), maxReconnectDelay)
        reconnectAttempt += 1
        reconnectTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, self.shouldReconnect else { return }
            self.connect()
        }
    }
}
