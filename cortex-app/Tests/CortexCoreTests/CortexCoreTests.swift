import Testing
@testable import CortexCore

@Test func testPortfolioStoreDefaults() async throws {
    await MainActor.run {
        let store = PortfolioStore()
        #expect(store.nav == 0.0)
        #expect(store.dailyPnL == 0.0)
        #expect(store.openPositionCount == 0)
    }
}

@Test func testKillSwitchDefaults() async throws {
    await MainActor.run {
        let store = KillSwitchStore()
        #expect(store.isActive == false)
        #expect(store.reason == nil)
    }
}

@Test func testKillSwitchEngage() async throws {
    await MainActor.run {
        let store = KillSwitchStore()
        store.confirmEngaged(reason: "drawdown")
        #expect(store.isActive == true)
        #expect(store.reason == "drawdown")
    }
}

@Test func testSquadronStoreAddAgent() async throws {
    await MainActor.run {
        let store = SquadronStore()
        store.update(agentId: "signal_hunter", data: [
            "squadron": "alpha",
            "status": "active",
            "signal_count": 42,
            "error_count": 0
        ])
        #expect(store.agents.count == 1)
        #expect(store.activeCount == 1)
    }
}

@Test func testSignalFeedAppend() async throws {
    await MainActor.run {
        let store = SignalFeedStore()
        store.append(SignalEvent(
            id: "sig_001",
            signalType: "alpha.entry_signal",
            sourceAgent: "signal_hunter",
            sourceSquadron: "alpha",
            symbol: "AAPL"
        ))
        #expect(store.signals.count == 1)
        #expect(store.recentSignals.first?.symbol == "AAPL")
    }
}

@Test func testSignalFeedMaxLimit() async throws {
    await MainActor.run {
        let store = SignalFeedStore()
        store.maxSignals = 5
        for i in 0..<10 {
            store.append(SignalEvent(
                id: "sig_\(i)",
                signalType: "test",
                sourceAgent: "test",
                sourceSquadron: "test"
            ))
        }
        #expect(store.signals.count == 5)
    }
}

@Test func testActivityStoreAppend() async throws {
    await MainActor.run {
        let store = ActivityStore()
        store.append(ActivityEvent(
            id: "evt_001",
            eventType: "order_filled",
            message: "AAPL buy 10 @ 150.00",
            symbol: "AAPL",
            severity: .info
        ))
        #expect(store.events.count == 1)
        #expect(store.criticalEvents.count == 0)
    }
}

@Test func testActivityCriticalFilter() async throws {
    await MainActor.run {
        let store = ActivityStore()
        store.append(ActivityEvent(
            id: "evt_001", eventType: "kill_switch",
            message: "Kill switch engaged", severity: .critical
        ))
        store.append(ActivityEvent(
            id: "evt_002", eventType: "order_filled",
            message: "Normal fill", severity: .info
        ))
        #expect(store.criticalEvents.count == 1)
        #expect(store.events.count == 2)
    }
}

@Test func testAppEnvironmentStores() async throws {
    await MainActor.run {
        let env = AppEnvironment()
        #expect(env.portfolio.nav == 0.0)
        #expect(env.squadrons.agents.isEmpty)
        #expect(env.killSwitch.isActive == false)
        #expect(env.signalFeed.signals.isEmpty)
        #expect(env.activity.events.isEmpty)
    }
}

@Test func testMessageDecoderPortfolio() async throws {
    let decoder = MessageDecoder()
    let payload: [String: Any] = ["nav": 100000.0, "daily_pnl": 500.0]
    let decoded = decoder.decodePortfolioUpdate(payload)
    #expect(decoded.nav == 100000.0)
    #expect(decoded.dailyPnL == 500.0)
}

@Test func testMessageDecoderAgentUpdate() async throws {
    let decoder = MessageDecoder()
    let payload: [String: Any] = [
        "agent_id": "signal_hunter",
        "squadron": "alpha",
        "status": "active",
        "signal_count": 42,
        "error_count": 0,
    ]
    let decoded = decoder.decodeAgentUpdate(payload)
    #expect(decoded["agent_id"] as? String == "signal_hunter")
}

@Test func testWebSocketClientDefaults() async throws {
    await MainActor.run {
        let client = WebSocketClient()
        #expect(client.isConnected == false)
        #expect(client.url == "ws://127.0.0.1:8765/ws")
    }
}

@Test func testWebSocketClientCustomURL() async throws {
    await MainActor.run {
        let client = WebSocketClient(url: "ws://localhost:9999/ws")
        #expect(client.url == "ws://localhost:9999/ws")
    }
}

@Test func testSettingsStoreDefaults() async throws {
    await MainActor.run {
        let store = SettingsStore()
        #expect(store.autonomyLevel == .suggestOnly)
        #expect(store.maxNotional == 500.0)
        #expect(store.serverURL == "ws://127.0.0.1:8765/ws")
    }
}

@Test func testAutonomyLevelLabels() async throws {
    #expect(AutonomyLevel.fullManual.label == "Full Manual")
    #expect(AutonomyLevel.fullAuto.label == "Full Auto")
}

@Test func testPerformanceStoreDefaults() async throws {
    await MainActor.run {
        let store = PerformanceStore()
        #expect(store.totalTrades == 0)
        #expect(store.winRate == 0)
        #expect(store.equityCurve.isEmpty)
    }
}

@Test func testPerformanceStoreAddEquity() async throws {
    await MainActor.run {
        let store = PerformanceStore()
        store.addEquityPoint(value: 50000)
        store.addEquityPoint(value: 51000)
        #expect(store.equityCurve.count == 2)
    }
}

@Test func testPerformanceStorePnL() async throws {
    await MainActor.run {
        let store = PerformanceStore()
        store.addDailyPnL(pnl: 500)
        store.addDailyPnL(pnl: -200)
        #expect(store.bestDay == 500)
        #expect(store.worstDay == -200)
        #expect(store.averageDailyPnL == 150)
    }
}

@Test func testAppEnvironmentHasNewStores() async throws {
    await MainActor.run {
        let env = AppEnvironment()
        #expect(env.settings.maxNotional == 500.0)
        #expect(env.performance.totalTrades == 0)
        #expect(env.webSocket.isConnected == false)
    }
}
