import Combine
import XCTest
@testable import CodexBarIOS

final class PlanRefreshAndAlertsTests: XCTestCase {
    @MainActor
    func testFreeBatchAndIndividualRefreshOnlyActiveAndDoNotRecordPausedCache() async throws {
        let harness = try makeHarness(hasProAccess: false)
        defer { harness.removeDefaults() }
        let active = harness.accounts[0]
        let paused = harness.accounts[1]
        let pausedCache = try XCTUnwrap(harness.refreshService.results.first { $0.accountID == paused.id })
        let previousObservation = planResult(for: paused, at: pausedCache.fetchedAt.addingTimeInterval(-3_600), used: 20)
        harness.historyStore.record(results: [previousObservation])
        let originalConfigurations = harness.configurationStore.configurations

        _ = await harness.orchestrator.refreshNow()
        let pausedIndividualResult = await harness.refreshService.refresh(configuration: paused)
        let pausedOrchestratedResult = await harness.orchestrator.refreshAccount(paused)
        let pausedMetricsResult = await harness.orchestrator.loadAccountMetrics(paused)
        let activeIndividualResult = await harness.orchestrator.refreshAccount(active)

        XCTAssertNil(pausedIndividualResult)
        XCTAssertNil(pausedOrchestratedResult)
        XCTAssertNil(pausedMetricsResult)
        XCTAssertNotNil(activeIndividualResult)
        let fetches = await harness.provider.recordedAccountIDs()
        XCTAssertEqual(fetches, [active.id, active.id])
        XCTAssertEqual(harness.refreshService.results.first { $0.accountID == paused.id }, pausedCache)
        XCTAssertEqual(harness.refreshService.successfulRefreshResults.map(\.accountID), [active.id])
        XCTAssertEqual(
            harness.historyStore.snapshots.filter { $0.accountID == paused.id }.map(\.capturedAt),
            [previousObservation.fetchedAt]
        )
        XCTAssertEqual(harness.configurationStore.configurations, originalConfigurations)
        XCTAssertTrue(harness.configurationStore.configurations.allSatisfy(\.isEnabled))
    }

    @MainActor
    func testSuspendedSuccessfulCompletionsStayInvalidAfterAccountBecomesActiveAgain() async throws {
        for usesBatch in [false, true] {
            for restoresPro in [false, true] {
                try await assertSuspendedCompletionDiscarded(usesBatch: usesBatch, restoresPro: restoresPro, fails: false)
            }
        }
    }

    @MainActor
    func testSuspendedFailedCompletionsStayInvalidAfterAccountBecomesActiveAgain() async throws {
        for usesBatch in [false, true] {
            for restoresPro in [false, true] {
                try await assertSuspendedCompletionDiscarded(usesBatch: usesBatch, restoresPro: restoresPro, fails: true)
            }
        }
    }

    @MainActor
    func testQueuedBatchRefreshUsesLatestActiveAccountAfterSuspendedRequest() async throws {
        let accounts = makeAccounts()
        let entered = expectation(description: "Original active account refresh is suspended")
        let gate = PlanTestGate { entered.fulfill() }
        let provider = PlanControlledProvider()
        await provider.setGate(gate, for: accounts[1].id)
        let originalPaused = planResult(for: accounts[1], at: Date().addingTimeInterval(-3_600), used: 25)
        let service = UsageRefreshService(providers: [provider], initialResults: [originalPaused])
        service.updateCurrentConfigurations(accounts)
        service.updateAccountAccess(freeAccess(active: accounts[1], paused: accounts[0]))
        let originalRefresh = Task { await service.refresh(configurations: accounts) }
        await fulfillment(of: [entered], timeout: 3)
        service.updateAccountAccess(freeAccess(active: accounts[0], paused: accounts[1]))
        let queued = expectation(description: "New active account refresh is queued")
        let queuedRefresh = Task {
            queued.fulfill()
            await service.refresh(configurations: accounts)
        }
        await fulfillment(of: [queued], timeout: 3)
        XCTAssertEqual(service.queuedBatchRefreshCount, 1)

        await gate.release()
        await originalRefresh.value
        await queuedRefresh.value

        let fetches = await provider.recordedAccountIDs()
        XCTAssertEqual(fetches, [accounts[1].id, accounts[0].id])
        XCTAssertEqual(service.results.first { $0.accountID == accounts[1].id }, originalPaused)
        XCTAssertEqual(service.successfulRefreshResults.map(\.accountID), [accounts[0].id])
        XCTAssertEqual(service.queuedBatchRefreshCount, 0)
        XCTAssertFalse(service.isRefreshing)
    }

    @MainActor
    func testRapidActiveAccountChoicesDoNotCancelTheQueuedAutomaticRefresh() async throws {
        let harness = try makeHarness(hasProAccess: false)
        defer { harness.removeDefaults() }
        let finalActive = harness.accounts[0]
        let temporarilyActive = harness.accounts[1]
        let originalActive = try XCTUnwrap(harness.refreshService.results.first { $0.accountID == finalActive.id })
        let originalPaused = try XCTUnwrap(harness.refreshService.results.first { $0.accountID == temporarilyActive.id })
        let originalConfigurations = harness.configurationStore.configurations
        let entered = expectation(description: "First chooser-triggered automatic refresh is suspended")
        let gate = PlanTestGate { entered.fulfill() }
        await harness.provider.setGate(gate, for: temporarilyActive.id)
        await harness.provider.enableCancellationChecks()

        XCTAssertTrue(harness.configurationStore.chooseActiveAccount(temporarilyActive.id))
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(harness.configurationStore.chooseActiveAccount(finalActive.id))
        let queued = await waitForState { harness.refreshService.queuedBatchRefreshCount == 1 }
        XCTAssertTrue(queued, "The second chooser-triggered refresh must queue behind the suspended batch")
        await gate.release()
        let drained = await waitForState {
            harness.refreshService.queuedBatchRefreshCount == 0 && !harness.refreshService.isRefreshing
        }
        XCTAssertTrue(drained, "Both automatic refresh tasks must finish")

        let fetches = await harness.provider.recordedAccountIDs()
        let canceled = await harness.provider.recordedCanceledAccountIDs()
        XCTAssertEqual(fetches, [temporarilyActive.id, finalActive.id])
        XCTAssertTrue(canceled.isEmpty, "A generation change must not cancel the batch that owns queued work")
        let latest = try XCTUnwrap(harness.refreshService.results.first { $0.accountID == finalActive.id })
        XCTAssertGreaterThan(latest.fetchedAt, originalActive.fetchedAt)
        XCTAssertEqual(harness.refreshService.results.first { $0.accountID == temporarilyActive.id }, originalPaused)
        XCTAssertEqual(harness.configurationStore.accountAccess.activeAccountID, finalActive.id)
        XCTAssertEqual(harness.configurationStore.configurations, originalConfigurations)
        XCTAssertTrue(harness.notifier.attempted.isEmpty)
    }

    @MainActor
    func testSuspendedBatchDoesNotResurrectPausedAccountError() async throws {
        let accounts = makeAccounts()
        let provider = PlanControlledProvider()
        await provider.setFailure(for: accounts[1].id, enabled: true)
        let service = UsageRefreshService(providers: [provider], initialResults: accounts.map {
            planResult(for: $0, at: Date().addingTimeInterval(-3_600), used: 25)
        })
        service.updateCurrentConfigurations(accounts)
        service.updateAccountAccess(.unrestricted)
        await service.refresh(configurations: accounts)
        let retainedError = try XCTUnwrap(service.refreshErrorsByAccountID[accounts[1].id])
        XCTAssertEqual(service.lastRefreshError, retainedError)
        let entered = expectation(description: "Second batch awaits the account that will pause")
        let gate = PlanTestGate { entered.fulfill() }
        await provider.setGate(gate, for: accounts[1].id)
        let refresh = Task { await service.refresh(configurations: accounts) }
        await fulfillment(of: [entered], timeout: 3)

        service.updateAccountAccess(freeAccess(active: accounts[0], paused: accounts[1]))
        XCTAssertNil(service.lastRefreshError)
        await gate.release()
        await refresh.value

        XCTAssertNil(service.lastRefreshError)
        XCTAssertEqual(service.refreshErrorsByAccountID[accounts[1].id], retainedError)
        XCTAssertFalse(service.isRefreshing)
    }

    @MainActor
    func testFreeUsageNotificationsBadgesAndAuthorizationAreOffWithoutChangingSettings() async throws {
        let harness = try makeHarness(hasProAccess: false)
        defer { harness.removeDefaults() }
        let originalSettings = harness.configurationStore.usageAlertSettings
        let originalConfigurations = harness.configurationStore.configurations
        let savedAlertIDs: Set<String> = ["severity.warning.\(harness.accounts[1].id)"]
        harness.configurationStore.updateUsageAlertActiveIDs(savedAlertIDs)
        XCTAssertTrue(originalSettings.isEnabled)
        XCTAssertTrue(harness.orchestrator.currentUsageAlertsByAccountID.isEmpty)

        _ = await harness.orchestrator.refreshNow()
        let authorization = await harness.orchestrator.requestAlertAuthorization()

        XCTAssertFalse(authorization)
        XCTAssertEqual(harness.notifier.authorizationRequests, 0)
        XCTAssertTrue(harness.notifier.attempted.isEmpty)
        XCTAssertTrue(harness.orchestrator.currentUsageAlertsByAccountID.isEmpty)
        XCTAssertEqual(harness.configurationStore.usageAlertSettings, originalSettings)
        XCTAssertEqual(harness.configurationStore.usageAlertActiveIDs, savedAlertIDs)
        XCTAssertEqual(harness.configurationStore.configurations, originalConfigurations)
    }

    @MainActor
    func testDowngradeDuringNotificationDeliveryStopsLaterUsageNotifications() async throws {
        let entered = expectation(description: "First usage notification is being delivered")
        let gate = PlanTestGate { entered.fulfill() }
        let notifier = PlanRecordingNotifier(gate: gate)
        let harness = try makeHarness(hasProAccess: true, notifier: notifier)
        defer { harness.removeDefaults() }
        let originalSettings = harness.configurationStore.usageAlertSettings
        let refresh = Task { await harness.orchestrator.refreshNow() }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertEqual(notifier.attempted.count, 1)
        XCTAssertFalse(harness.orchestrator.currentUsageAlertsByAccountID.isEmpty)

        harness.configurationStore.applyPlanAccess(hasProAccess: false, isResolved: true)
        await gate.release()
        _ = await refresh.value

        XCTAssertEqual(notifier.attempted.count, 1)
        XCTAssertEqual(notifier.delivered.count, 1)
        XCTAssertTrue(harness.orchestrator.currentUsageAlertsByAccountID.isEmpty)
        XCTAssertTrue(harness.configurationStore.usageAlertActiveIDs.isEmpty)
        XCTAssertEqual(harness.configurationStore.usageAlertSettings, originalSettings)
        XCTAssertTrue(harness.configurationStore.configurations.allSatisfy(\.isEnabled))
    }

    @MainActor
    func testUpgradeAutomaticallyRefreshesEveryAccountAndRestoresAlerts() async throws {
        let harness = try makeHarness(hasProAccess: false)
        defer { harness.removeDefaults() }
        _ = await harness.orchestrator.refreshNow()
        let originalConfigurations = harness.configurationStore.configurations
        let originalSettings = harness.configurationStore.usageAlertSettings
        let pausedID = harness.accounts[1].id
        let originalPausedDate = try XCTUnwrap(harness.refreshService.results.first { $0.accountID == pausedID }?.fetchedAt)
        let alertsRestored = expectation(description: "Automatic upgrade refresh processed both accounts' alerts")
        var didFulfill = false
        let subscription = harness.configurationStore.$usageAlertActiveIDs.sink { ids in
            guard !didFulfill, harness.accounts.allSatisfy({ ids.contains("severity.critical.\($0.id)") }) else { return }
            didFulfill = true
            alertsRestored.fulfill()
        }
        defer { subscription.cancel() }

        harness.configurationStore.applyPlanAccess(hasProAccess: true, isResolved: true)
        await fulfillment(of: [alertsRestored], timeout: 3)

        let fetches = await harness.provider.recordedAccountIDs()
        XCTAssertEqual(fetches.filter { $0 == harness.accounts[0].id }.count, 2)
        XCTAssertEqual(fetches.filter { $0 == pausedID }.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(harness.refreshService.results.first { $0.accountID == pausedID }?.fetchedAt), originalPausedDate)
        XCTAssertEqual(Set(harness.refreshService.successfulRefreshResults.map(\.accountID)), Set(harness.accounts.map(\.id)))
        XCTAssertEqual(Set(harness.historyStore.snapshots.map(\.accountID)), Set(harness.accounts.map(\.id)))
        XCTAssertEqual(Set(harness.orchestrator.currentUsageAlertsByAccountID.keys), Set(harness.accounts.map(\.id)))
        XCTAssertEqual(harness.notifier.delivered.count, 4)
        XCTAssertEqual(harness.configurationStore.configurations, originalConfigurations)
        XCTAssertEqual(harness.configurationStore.usageAlertSettings, originalSettings)
        XCTAssertTrue(harness.configurationStore.accountAccess.pausedAccountIDs.isEmpty)
    }

    @MainActor
    func testChoosingAnotherAccountAutomaticallyRefreshesCommittedSelection() async throws {
        let harness = try makeHarness(hasProAccess: false)
        defer { harness.removeDefaults() }
        _ = await harness.orchestrator.refreshNow()
        let previousActiveResult = try XCTUnwrap(harness.refreshService.results.first { $0.accountID == harness.accounts[0].id })
        let originalConfigurations = harness.configurationStore.configurations
        let selectedID = harness.accounts[1].id
        let selectedRecorded = expectation(description: "New active account was refreshed and recorded")
        var didFulfill = false
        let subscription = harness.historyStore.$snapshots.sink { snapshots in
            guard !didFulfill, snapshots.contains(where: { $0.accountID == selectedID }) else { return }
            didFulfill = true
            selectedRecorded.fulfill()
        }
        defer { subscription.cancel() }

        XCTAssertTrue(harness.configurationStore.chooseActiveAccount(selectedID))
        await fulfillment(of: [selectedRecorded], timeout: 3)

        let fetches = await harness.provider.recordedAccountIDs()
        XCTAssertEqual(fetches, harness.accounts.map(\.id))
        XCTAssertEqual(harness.configurationStore.accountAccess.activeAccountID, selectedID)
        XCTAssertEqual(harness.configurationStore.freeActiveAccountID, selectedID)
        XCTAssertEqual(harness.refreshService.results.first { $0.accountID == harness.accounts[0].id }, previousActiveResult)
        XCTAssertEqual(harness.refreshService.successfulRefreshResults.map(\.accountID), [selectedID])
        XCTAssertTrue(harness.notifier.attempted.isEmpty)
        XCTAssertEqual(harness.configurationStore.configurations, originalConfigurations)
    }

    @MainActor
    func testColdStartPausedCardReadsHistoryWithoutRefreshingOrRecordingIt() async throws {
        let harness = try makeHarness(hasProAccess: false, includesCachedResults: false)
        defer { harness.removeDefaults() }
        let paused = harness.accounts[1]
        let observation = planResult(for: paused, at: Date().addingTimeInterval(-10 * 86_400), used: 36)
        harness.historyStore.record(results: [observation])
        let storedSnapshots = harness.historyStore.snapshots
        let storedDailySnapshots = harness.historyStore.dailySnapshots

        let card = try XCTUnwrap(harness.orchestrator.dashboardCardItems.first { $0.id == paused.id })

        XCTAssertEqual(card.result?.fetchedAt, observation.fetchedAt)
        XCTAssertEqual(card.result?.bars.first?.used, 36)
        XCTAssertTrue(harness.refreshService.results.isEmpty)
        XCTAssertTrue(harness.refreshService.successfulRefreshResults.isEmpty)
        XCTAssertEqual(harness.historyStore.snapshots, storedSnapshots)
        XCTAssertEqual(harness.historyStore.dailySnapshots, storedDailySnapshots)
        let fetches = await harness.provider.recordedAccountIDs()
        XCTAssertTrue(fetches.isEmpty)
        XCTAssertTrue(harness.notifier.attempted.isEmpty)
    }

    #if DEBUG
    @MainActor
    func testPlanFixtureEvidenceDrivesDowngradeAndUpgradeThroughSharedCoordinator() async throws {
        let harness = try makeHarness(hasProAccess: true)
        defer { harness.removeDefaults() }
        let fixture = PlanAccessFixture(hasProAccess: true)
        await fixture.entitlement.start()
        let coordinator = PlanAccessCoordinator(
            entitlement: fixture.entitlement,
            configurationStore: harness.configurationStore,
            refreshService: harness.refreshService,
            historyStore: harness.historyStore
        )
        defer { withExtendedLifetime(coordinator) {} }
        let originalConfigurations = harness.configurationStore.configurations
        let originalSettings = harness.configurationStore.usageAlertSettings
        XCTAssertTrue(fixture.entitlement.isResolved)
        XCTAssertTrue(fixture.entitlement.hasAccess)
        XCTAssertTrue(harness.configurationStore.accountAccess.hasProAccess)
        XCTAssertEqual(harness.historyStore.accessPolicy, .pro)

        await fixture.setProAccess(false)

        XCTAssertFalse(fixture.entitlement.hasAccess)
        XCTAssertTrue(fixture.entitlement.isResolved)
        XCTAssertFalse(harness.configurationStore.accountAccess.hasProAccess)
        XCTAssertEqual(harness.historyStore.accessPolicy, .free)
        XCTAssertEqual(harness.accounts.filter(harness.refreshService.canRefresh).count, 1)
        let pausedID = try XCTUnwrap(harness.configurationStore.accountAccess.pausedAccountIDs.first)
        let previousDate = try XCTUnwrap(harness.refreshService.results.first { $0.accountID == pausedID }?.fetchedAt)

        await fixture.setProAccess(true)
        let restored = await waitForState {
            harness.refreshService.results.contains { $0.accountID == pausedID && $0.fetchedAt > previousDate }
                && !harness.refreshService.isRefreshing
        }

        XCTAssertTrue(restored)
        XCTAssertTrue(fixture.entitlement.hasAccess)
        XCTAssertTrue(harness.configurationStore.accountAccess.hasProAccess)
        XCTAssertEqual(harness.historyStore.accessPolicy, .pro)
        XCTAssertEqual(harness.accounts.filter(harness.refreshService.canRefresh), harness.accounts)
        XCTAssertEqual(harness.configurationStore.configurations, originalConfigurations)
        XCTAssertEqual(harness.configurationStore.usageAlertSettings, originalSettings)
    }

    @MainActor
    func testEntitlementAccessCallbacksObserveCommittedEvidenceAndResolution() async {
        let fixture = PlanAccessFixture(hasProAccess: true)
        let entitlement = fixture.entitlement
        var observed: [ProAccessState] = []
        let subscription = entitlement.accessChanges.sink { state in
            observed.append(state)
            XCTAssertEqual(state, entitlement.accessState)
            XCTAssertEqual(state.isResolved, entitlement.isResolved)
            XCTAssertEqual(state.hasAccess, entitlement.hasAccess)
        }
        defer { subscription.cancel() }

        await entitlement.refresh()
        await fixture.setProAccess(false)
        XCTAssertEqual(observed.last, ProAccessState(hasAccess: false, isResolved: true))
        await fixture.setProAccess(true)

        XCTAssertEqual(observed.last, ProAccessState(hasAccess: true, isResolved: true))
        XCTAssertTrue(observed.contains(ProAccessState(hasAccess: false, isResolved: true)))
        XCTAssertTrue(observed.contains(ProAccessState(hasAccess: true, isResolved: true)))
        XCTAssertGreaterThanOrEqual(observed.count, 3)
    }
    #endif

    @MainActor
    private func assertSuspendedCompletionDiscarded(usesBatch: Bool, restoresPro: Bool, fails: Bool) async throws {
        let accounts = makeAccounts()
        let blocked = accounts[1]
        let entered = expectation(description: "Suspended completion batch=\(usesBatch) Pro=\(restoresPro) failure=\(fails)")
        let gate = PlanTestGate { entered.fulfill() }
        let provider = PlanControlledProvider()
        await provider.setGate(gate, for: blocked.id)
        await provider.setFailure(for: blocked.id, enabled: fails)
        let cached = accounts.map { planResult(for: $0, at: Date().addingTimeInterval(-3_600), used: 25) }
        let cachedBlocked = try XCTUnwrap(cached.first { $0.accountID == blocked.id })
        let service = UsageRefreshService(providers: [provider], initialResults: cached)
        service.updateCurrentConfigurations(accounts)
        let restoredAccess = restoresPro ? AccountPlanAccess.unrestricted : freeAccess(active: blocked, paused: accounts[0])
        service.updateAccountAccess(restoredAccess)
        let refresh = Task {
            if usesBatch {
                await service.refresh(configurations: accounts)
            } else {
                _ = await service.refresh(configuration: blocked)
            }
        }
        await fulfillment(of: [entered], timeout: 3)

        service.updateAccountAccess(freeAccess(active: accounts[0], paused: blocked))
        XCTAssertEqual(service.results.first { $0.accountID == blocked.id }, cachedBlocked)
        XCTAssertFalse(service.successfulRefreshResults.contains { $0.accountID == blocked.id })
        service.updateAccountAccess(restoredAccess)
        await gate.release()
        await refresh.value

        XCTAssertEqual(service.results.first { $0.accountID == blocked.id }, cachedBlocked)
        XCTAssertNil(service.refreshErrorsByAccountID[blocked.id])
        XCTAssertNil(service.lastRefreshError)
        XCTAssertFalse(service.isRefreshing)
    }

    @MainActor
    private func waitForState(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    @MainActor
    private func makeHarness(
        hasProAccess: Bool,
        includesCachedResults: Bool = true,
        notifier: PlanRecordingNotifier? = nil
    ) throws -> PlanRefreshHarness {
        let suiteName = "PlanRefreshAndAlertsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults,
                                               secretStore: MemorySecretStore(), widgetSnapshotDefaults: defaults)
        let accounts = makeAccounts()
        for account in accounts {
            XCTAssertTrue(store.update(account))
            XCTAssertTrue(store.saveSecret("isolated-plan-test", for: account))
        }
        store.updateUsageAlertsEnabled(true)
        store.updateUsageAlertWarningThreshold(0.7)
        store.updateUsageAlertCriticalThreshold(0.9)
        store.updateUsageAlertBalanceThreshold(10)
        store.applyPlanAccess(hasProAccess: hasProAccess, isResolved: true, dashboardOrder: accounts.map(\.id))
        let provider = PlanControlledProvider()
        let results = includesCachedResults ? accounts.map {
            planResult(for: $0, at: Date().addingTimeInterval(-3_600), used: 95)
        } : []
        let service = UsageRefreshService(providers: [provider], initialResults: results)
        let history = UsageHistoryStore(defaults: defaults, accessPolicy: HistoryAccessPolicy(hasProAccess: hasProAccess))
        let notifier = notifier ?? PlanRecordingNotifier()
        let orchestrator = DashboardOrchestrator(
            refreshService: service, configurationStore: store, historyStore: history,
            usageAlertNotifier: notifier, appReviewPromptPolicy: AppReviewPromptPolicy(defaults: defaults),
            widgetSnapshotCoordinator: WidgetSnapshotCoordinator(
                refreshService: service, configurationStore: store, publishSnapshot: { _, _ in }, publishSettings: { _ in }
            ),
            watchSnapshotCoordinator: WatchSnapshotCoordinator(
                refreshService: service, configurationStore: store, sender: PlanNoopWatchSender(), publishSnapshot: { _, _, _ in }
            )
        )
        return PlanRefreshHarness(suiteName: suiteName, defaults: defaults, accounts: accounts,
                                  configurationStore: store, provider: provider, refreshService: service,
                                  historyStore: history, notifier: notifier, orchestrator: orchestrator)
    }

    private func makeAccounts() -> [ProviderAccountConfiguration] {
        ["first", "second"].map {
            ProviderAccountConfiguration(id: "plan.\($0)", providerID: .openRouter, accountLabel: $0, authMethod: .apiKey)
        }
    }

    private func freeAccess(active: ProviderAccountConfiguration, paused: ProviderAccountConfiguration) -> AccountPlanAccess {
        AccountPlanAccess(hasProAccess: false, activeAccountID: active.id, pausedAccountIDs: [paused.id])
    }
}

private func planResult(for configuration: ProviderAccountConfiguration, at date: Date, used: Double) -> ProviderUsageResult {
    ProviderUsageResult(accountID: configuration.id, providerID: configuration.providerID, title: configuration.displayName,
                        subtitle: "Isolated saved usage", bars: [UsageBar(stableKey: "usage", label: "Usage", used: used, limit: 100)],
                        creditsRemaining: 2, fetchedAt: date)
}

private actor PlanControlledProvider: UsageProvider {
    nonisolated let providerID = ProviderID.openRouter
    private var gates: [String: PlanTestGate] = [:]
    private var failingAccounts: Set<String> = []
    private var requestedAccountIDs: [String] = []
    private var canceledAccountIDs: [String] = []
    private var checksCancellation = false

    func setGate(_ gate: PlanTestGate, for accountID: String) { gates[accountID] = gate }

    func setFailure(for accountID: String, enabled: Bool) {
        if enabled { failingAccounts.insert(accountID) } else { failingAccounts.remove(accountID) }
    }

    func recordedAccountIDs() -> [String] { requestedAccountIDs }
    func recordedCanceledAccountIDs() -> [String] { canceledAccountIDs }
    func enableCancellationChecks() { checksCancellation = true }

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        requestedAccountIDs.append(configuration.id)
        let fails = failingAccounts.contains(configuration.id)
        if let gate = gates[configuration.id] { await gate.wait() }
        if checksCancellation {
            do {
                try Task.checkCancellation()
            } catch {
                canceledAccountIDs.append(configuration.id)
                throw error
            }
        }
        if fails { throw TestUsageProviderError.failed }
        return planResult(for: configuration, at: Date(), used: 95)
    }
}

private actor PlanTestGate {
    private let onEntry: @Sendable () -> Void
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(onEntry: @escaping @Sendable () -> Void) { self.onEntry = onEntry }

    func wait() async {
        guard !released else { return }
        onEntry()
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class PlanRecordingNotifier: UsageAlertNotifying {
    private let gate: PlanTestGate?
    private(set) var attempted: [UsageAlertNotification] = []
    private(set) var delivered: [UsageAlertNotification] = []
    private(set) var authorizationRequests = 0

    init(gate: PlanTestGate? = nil) { self.gate = gate }

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        return true
    }

    func deliver(_ notification: UsageAlertNotification) async throws {
        attempted.append(notification)
        if let gate { await gate.wait() }
        delivered.append(notification)
    }
}

@MainActor
private final class PlanNoopWatchSender: WatchSnapshotSending {
    func activate(onSnapshotNeeded: @escaping @MainActor (Bool) -> Void) {}
    func publish(_ snapshot: WatchDashboardSnapshot, force: Bool) -> Bool { true }
}

@MainActor
private struct PlanRefreshHarness {
    let suiteName: String
    let defaults: UserDefaults
    let accounts: [ProviderAccountConfiguration]
    let configurationStore: ProviderConfigurationStore
    let provider: PlanControlledProvider
    let refreshService: UsageRefreshService
    let historyStore: UsageHistoryStore
    let notifier: PlanRecordingNotifier
    let orchestrator: DashboardOrchestrator

    func removeDefaults() { defaults.removePersistentDomain(forName: suiteName) }
}
