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
