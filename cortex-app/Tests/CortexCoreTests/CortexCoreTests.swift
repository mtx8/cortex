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
