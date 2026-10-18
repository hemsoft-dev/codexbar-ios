import Foundation
import XCTest
@testable import CodexBarIOS

final class ClaudeUsageResetFlowTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testAccountInventoryAndBindingValidationPreventConsumption() async throws {
        for mode in ["disabled", "wrongAccount", "wrongBinding", "wrongGrant", "expired", "failed", "unbound"] {
            let harness = makeHarness(mode: mode)
            defer { harness.clear() }
            do {
                _ = try await harness.service.consumeClaudeReset(
                    for: harness.account, grantID: mode == "wrongGrant" ? "other" : "fixture_grant", confirmedGrant: harness.confirmedGrant,
                    credentialBinding: mode == "wrongBinding" ? "replacement" : "binding"
                )
                XCTFail("Invalid confirmation must not reach provider: \(mode)")
            } catch {
                XCTAssertEqual(error as? ClaudeUsageResetError, .unavailable, mode)
            }
            let calls = await harness.provider.consumptionCount()
            XCTAssertEqual(calls, 0, mode)
        }
    }

    @MainActor
    func testEveryOutcomeRefreshesAuthoritativeUsage() async throws {
        for outcome in [ClaudeUsageResetOutcome.reset, .alreadyRedeemed, .nothingToReset, .noCredit, .stateChanged] {
            for refreshMode in ["valid", "failed", "rebound"] {
                let harness = makeHarness(outcome: outcome, refreshMode: refreshMode)
                defer { harness.clear() }
                let feedback = await harness.orchestrator.consumeClaudeReset(
                    for: harness.account, grantID: "fixture_grant", confirmedGrant: harness.confirmedGrant, credentialBinding: "binding"
                )
                let calls = await harness.provider.consumptionCount()
                let fetches = await harness.provider.fetchCount()
                XCTAssertEqual(calls, 1)
                XCTAssertEqual(fetches, 1)
                let refreshed = try XCTUnwrap(harness.service.results.first)
                if refreshMode == "failed" {
                    XCTAssertNotNil(refreshed.failureMessage)
                    XCTAssertNil(refreshed.claudeUsageResetInventory)
                    if outcome == .reset || outcome == .alreadyRedeemed {
                        XCTAssertTrue(feedback.message.contains("could not be refreshed"))
                    }
                } else {
                    XCTAssertEqual(refreshed.bars.first?.used, 17)
                    XCTAssertEqual(refreshed.claudeUsageResetInventory?.availableCount(at: Date()), 1)
                }
                XCTAssertEqual(feedback.isSuccess, refreshMode != "rebound" && (outcome == .reset || outcome == .alreadyRedeemed))
                if refreshMode == "rebound" { XCTAssertTrue(feedback.message.contains("authorization changed")) }
            }
        }
    }

    @MainActor
    func testFailedOrAmbiguousConsumptionStillRefreshesWithoutReplay() async throws {
        for error in [ClaudeUsageResetError.indeterminate, .credentialChanged, .storageUnavailable] {
            let harness = makeHarness(error: error)
            defer { harness.clear() }
            let feedback = await harness.orchestrator.consumeClaudeReset(
                for: harness.account, grantID: "fixture_grant", confirmedGrant: harness.confirmedGrant, credentialBinding: "binding"
            )
            XCTAssertFalse(feedback.isSuccess)
            let calls = await harness.provider.consumptionCount()
            let fetches = await harness.provider.fetchCount()
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(fetches, 1)
            XCTAssertEqual(harness.service.results.first?.bars.first?.used, 17)
        }
    }

    @MainActor
    func testConcurrentConfirmationsForwardExactlyOneConsumption() async throws {
        let harness = makeHarness(paused: true)
        defer { harness.clear() }
        let first = Task { @MainActor in
            try await harness.service.consumeClaudeReset(
                for: harness.account, grantID: "fixture_grant", confirmedGrant: harness.confirmedGrant, credentialBinding: "binding"
            )
        }
        let started = await harness.provider.waitUntilConsuming()
        guard started else {
            first.cancel()
            await harness.provider.release()
            XCTFail("Consumption did not start within the fixture deadline")
            return
        }
        do {
            _ = try await harness.service.consumeClaudeReset(
                for: harness.account, grantID: "fixture_grant", confirmedGrant: harness.confirmedGrant, credentialBinding: "binding"
            )
            XCTFail("Duplicate confirmation must be rejected")
        } catch { XCTAssertEqual(error as? ClaudeUsageResetError, .inProgress) }
        await harness.provider.release()
        let completed = try await first.value
        XCTAssertEqual(completed, .reset)
        let calls = await harness.provider.consumptionCount()
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testCredentialInvalidationDiscardsPendingCompletion() async throws {
        for mode in ["service", "saveSecret", "removeSecret", "removeAccount", "disable"] {
            let harness = makeHarness(paused: true)
            defer { harness.clear() }
            let first = Task { @MainActor in
                try await harness.service.consumeClaudeReset(
                    for: harness.account, grantID: "fixture_grant", confirmedGrant: harness.confirmedGrant, credentialBinding: "binding"
                )
            }
            let started = await harness.provider.waitUntilConsuming()
            guard started else {
                first.cancel()
                await harness.provider.release()
                XCTFail("Consumption did not start within the fixture deadline")
                return
            }
            switch mode {
            case "saveSecret": XCTAssertTrue(harness.store.saveSecret("replacement-token", for: harness.account))
            case "removeSecret": XCTAssertTrue(harness.store.saveSecret("", for: harness.account))
            case "removeAccount": XCTAssertTrue(harness.store.removeAccount(harness.account))
            case "disable":
                var disabled = harness.account
                disabled.isEnabled = false
                XCTAssertTrue(harness.store.update(disabled))
            default: harness.service.invalidateCredentials(accountID: harness.account.id)
            }
            await harness.provider.release()
            do {
                _ = try await first.value
                XCTFail("Stale completion must be rejected: \(mode)")
            } catch { XCTAssertEqual(error as? ClaudeUsageResetError, .credentialChanged, mode) }
            let calls = await harness.provider.consumptionCount()
            XCTAssertEqual(calls, 1, mode)
            if mode != "disable" { XCTAssertTrue(harness.service.results.isEmpty, mode) }
        }
    }

    @MainActor
    private func makeHarness(
        mode: String = "valid", outcome: ClaudeUsageResetOutcome = .reset,
        error: ClaudeUsageResetError? = nil, paused: Bool = false, refreshMode: String = "valid"
    ) -> Harness {
        let suite = "ClaudeResetFlow.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults, secretStore: FlowSecrets(), widgetSnapshotDefaults: defaults)
        guard var account = store.addAccount(for: .claude) else {
            preconditionFailure("The explicit Pro fixture must accept an account.")
        }
        account.isEnabled = mode != "disabled"
        XCTAssertTrue(store.update(account))
        let provider = FlowProvider(outcome: outcome, error: error, paused: paused, refreshMode: refreshMode)
        let resultAccount = mode == "wrongAccount"
            ? ProviderAccountConfiguration(id: "other-account", providerID: .claude, authMethod: .cliToken) : account
        let initial = FlowProvider.result(account: resultAccount, count: 2, used: 64, mode: mode)
        let service = UsageRefreshService(providers: [provider], initialResults: [initial])
        let orchestrator = DashboardOrchestrator(
            refreshService: service, configurationStore: store, historyStore: UsageHistoryStore(defaults: defaults),
            usageAlertNotifier: FlowNotifier(), appReviewPromptPolicy: AppReviewPromptPolicy(defaults: defaults),
            widgetSnapshotCoordinator: WidgetSnapshotCoordinator(refreshService: service, configurationStore: store,
                                                                 publishSnapshot: { _, _ in }, publishSettings: { _ in }),
            watchSnapshotCoordinator: WatchSnapshotCoordinator(refreshService: service, configurationStore: store,
                                                               sender: FlowWatchSender(), publishSnapshot: { _, _, _ in })
        )
        return Harness(account: account, service: service, provider: provider, orchestrator: orchestrator,
                       store: store, defaults: defaults, suite: suite, confirmedGrant: initial.claudeUsageResetInventory?.grants.first
                       ?? FlowProvider.result(account: account, count: 2, used: 64).claudeUsageResetInventory!.grants[0])
    }

    @MainActor
    private struct Harness {
        let account: ProviderAccountConfiguration
        let service: UsageRefreshService
        let provider: FlowProvider
        let orchestrator: DashboardOrchestrator
        let store: ProviderConfigurationStore
        let defaults: UserDefaults
        let suite: String
        let confirmedGrant: ClaudeUsageResetGrant
        func clear() { defaults.removePersistentDomain(forName: suite) }
    }
}

private actor FlowProvider: UsageProvider, ClaudeUsageResetConsuming {
    nonisolated let providerID = ProviderID.claude
    private let outcome: ClaudeUsageResetOutcome
    private let error: ClaudeUsageResetError?
    private let paused: Bool
    private let refreshMode: String
    private var calls = 0
    private var fetches = 0
    private var continuation: CheckedContinuation<Void, Never>?
    init(outcome: ClaudeUsageResetOutcome, error: ClaudeUsageResetError?, paused: Bool, refreshMode: String) {
        self.outcome = outcome
        self.error = error
        self.paused = paused
        self.refreshMode = refreshMode
    }
    func consumeClaudeReset(
        for configuration: ProviderAccountConfiguration, grantID: String, confirmedGrant: ClaudeUsageResetGrant, credentialBinding: String
    ) async throws -> ClaudeUsageResetOutcome {
        calls += 1
        if paused { await withCheckedContinuation { continuation = $0 } }
        if let error { throw error }
        return outcome
    }
    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        fetches += 1
        return Self.result(account: configuration, count: 1, used: 17, mode: refreshMode)
    }
    func consumptionCount() -> Int { calls }
    func fetchCount() -> Int { fetches }
    func release() {
        continuation?.resume()
        continuation = nil
    }
    func waitUntilConsuming() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while calls == 0 && clock.now < deadline { await Task.yield() }
        return calls > 0
    }
    nonisolated static func result(
        account: ProviderAccountConfiguration, count: Int, used: Double, mode: String = "valid"
    ) -> ProviderUsageResult {
        let grant = ClaudeUsageResetGrant(id: "fixture_grant", title: "Fixture", remainingCount: count,
                                         startsAt: nil, expiresAt: Date().addingTimeInterval(mode == "expired" ? -60 : 3600),
                                         clears: ["five_hour", "seven_day"], isPaused: false, isUsableNow: true, requiresLimit: false)
        let binding = mode == "unbound" ? nil : mode == "rebound" ? "replacement" : "binding"
        let inventory = ClaudeUsageResetInventory(isEligible: true, grants: [grant], selectedGrantID: grant.id,
                                                  cooldownUntil: nil, credentialBinding: binding)
        return ProviderUsageResult(accountID: account.id, providerID: .claude, title: account.displayName, subtitle: "Synthetic",
                                   bars: [UsageBar(label: "Weekly", used: used, limit: 100)], claudeUsageResetInventory: inventory,
                                   failureMessage: mode == "failed" ? "Unavailable" : nil, fetchedAt: Date())
    }
}
private final class FlowSecrets: SecretStore, @unchecked Sendable {
    func readSecret(account: String) throws -> String? { "synthetic-flow-token" }
    func saveSecret(_ secret: String, account: String) throws {}
    func deleteSecret(account: String) throws {}
}
@MainActor private final class FlowNotifier: UsageAlertNotifying {
    func requestAuthorization() async -> Bool { false }
    func deliver(_ notification: UsageAlertNotification) async throws {}
}
@MainActor private final class FlowWatchSender: WatchSnapshotSending {
    func activate(onSnapshotNeeded: @escaping @MainActor (Bool) -> Void) {}
    func publish(_ snapshot: WatchDashboardSnapshot, force: Bool) -> Bool { true }
}
