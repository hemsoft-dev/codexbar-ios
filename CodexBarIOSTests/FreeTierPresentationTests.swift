import SwiftUI
import XCTest
@testable import CodexBarIOS

@MainActor
final class FreeTierPresentationTests: XCTestCase {
    func testAddAccountFlowRefusesSecondAccountWithoutAdvancingToCredentialSetup() throws {
        let suiteName = "FreeTierPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProviderConfigurationStore(
            initialPlanAccess: .free,
            defaults: defaults,
            secretStore: EmptySecretStore(),
            widgetSnapshotDefaults: nil
        )
        var firstFlow = AddAccountFlowState()
        let firstID = try XCTUnwrap(firstFlow.select(.codex, configurationStore: store))
        var secondFlow = AddAccountFlowState()

        XCTAssertNil(secondFlow.select(.claude, configurationStore: store))
        XCTAssertNil(secondFlow.accountID)
        XCTAssertEqual(store.configurations.map(\.id), [firstID])
        XCTAssertTrue(store.requestedProPresentation)

        store.dismissProPresentation()
        XCTAssertEqual(firstFlow.select(.codex, configurationStore: store), firstID)
        XCTAssertEqual(store.configurations.count, 1)
        XCTAssertFalse(store.requestedProPresentation)
    }

    func testAddAccountFlowCanContinueAfterUpgradeWithoutReopeningSetup() throws {
        let suiteName = "FreeTierPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProviderConfigurationStore(
            initialPlanAccess: .free,
            defaults: defaults,
            secretStore: EmptySecretStore(),
            widgetSnapshotDefaults: nil
        )
        _ = try XCTUnwrap(store.addAccount(for: .codex))
        var flow = AddAccountFlowState()
        XCTAssertNil(flow.select(.claude, configurationStore: store))

        store.applyPlanAccess(hasProAccess: true, isResolved: true)
        store.dismissProPresentation()
        let accountID = try XCTUnwrap(flow.select(.claude, configurationStore: store))

        XCTAssertEqual(flow.accountID, accountID)
        XCTAssertEqual(store.configuration(accountID: accountID)?.providerID, .claude)
        XCTAssertEqual(store.configurations.count, 2)
        XCTAssertFalse(store.requestedProPresentation)
    }

    func testProRequestKeepsItsOriginUntilDismissedAndPreservesPendingAccountChoice() throws {
        let suiteName = "ProPresentationOriginTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults,
                                               secretStore: EmptySecretStore(), widgetSnapshotDefaults: nil)
        _ = try XCTUnwrap(store.addAccount(for: .codex))
        _ = try XCTUnwrap(store.addAccount(for: .claude))
        store.applyPlanAccess(hasProAccess: false, isResolved: true)
        XCTAssertTrue(store.accountAccess.needsActiveAccountChoice)

        store.requestProPresentation(origin: .settings)
        store.requestProPresentation()
        XCTAssertTrue(store.requestedProPresentation)
        XCTAssertEqual(store.requestedProPresentationOrigin, .settings)
        XCTAssertTrue(store.accountAccess.needsActiveAccountChoice)
        store.dismissProPresentation()
        XCTAssertTrue(store.accountAccess.needsActiveAccountChoice)

        store.requestProPresentation()
        XCTAssertEqual(store.requestedProPresentationOrigin, .limit)
        store.dismissProPresentation()
        XCTAssertFalse(store.requestedProPresentation)
        XCTAssertTrue(store.accountAccess.needsActiveAccountChoice)
    }

    func testPausedAccountSettingsAnnouncePlanStateWithoutCallingAccountDisabled() {
        let account = ProviderAccountConfiguration(id: "claude.saved", providerID: .claude, isEnabled: true, authMethod: .browserSession)
        let value = ProviderSettingsRow.accessibilityValue(
            configuration: account,
            isConfigured: true,
            isPausedByPlan: true,
            groupName: "Work"
        )

        XCTAssertEqual(value, "Paused: CodexBar Pro, Work group")
        XCTAssertTrue(account.isEnabled)
    }

    func testRenamingPausedAccountRetitlesCachedDashboardAndHistoryResultWithoutRefreshing() throws {
        try assertPausedRenameUsesCurrentLabel(useHistoryFallback: false)
    }

    func testRenamingPausedAccountRetitlesColdHistoryFallbackWithoutChangingObservation() throws {
        try assertPausedRenameUsesCurrentLabel(useHistoryFallback: true)
    }

    func testOpenCodeObservedTitleKeepsGoAndZenSemanticsAfterAccountLabelChanges() throws {
        var configuration = ProviderAccountConfiguration(
            id: "opencode.saved", providerID: .openCodeZen, authMethod: .apiKey
        )
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let usage = [UsageBar(stableKey: "go", label: "Go", used: 40, limit: 100)]
        for (bars, credits, expectedTitle) in [
            (usage, nil as Double?, "OpenCode Go"),
            ([], 8.0, "OpenCode Zen"),
            (usage, 8.0, "OpenCode Go + Zen"),
        ] {
            let observed = ProviderUsageResult(
                accountID: configuration.id, providerID: .openCodeZen, title: "Old custom name",
                subtitle: "Saved OpenCode usage", bars: bars, creditsRemaining: credits, fetchedAt: date
            )
            configuration.accountLabel = "OpenCode Go + Zen 2"
            var expected = observed
            expected.title = expectedTitle
            XCTAssertEqual(try displayedResult(configuration: configuration, observed: observed), expected)

            configuration.accountLabel = "Renamed workspace"
            expected.title = "Renamed workspace"
            XCTAssertEqual(try displayedResult(configuration: configuration, observed: observed), expected)
        }
    }

    func testGoogleSetupPlaceholderStillReplacesAnObservedResultAfterRename() throws {
        let configuration = ProviderAccountConfiguration(
            id: "gemini.saved", providerID: .gemini, accountLabel: "Renamed Gemini", authMethod: .browserSession
        )
        let observed = ProviderUsageResult(
            accountID: configuration.id, providerID: .gemini, title: "Old Gemini",
            subtitle: "Old observation", bars: [], fetchedAt: Date()
        )
        let result = try displayedResult(configuration: configuration, observed: observed, requiresSetup: true)

        XCTAssertEqual(result.title, "Renamed Gemini")
        XCTAssertEqual(result.recoveryAction, .signIn)
        XCTAssertEqual(result.fetchedAt, .distantPast)
        XCTAssertFalse(result.hasSuccessfulRefreshHistory)
    }

    func testDashboardInvitesFirstAccountWhenNoAccountsExist() throws {
        try withDashboard { probe in
            let addAccount = try XCTUnwrap(probe.element(identifier: "dashboard-add-account"), "\(probe.labels)")

            XCTAssertNotNil(probe.element(label: "Connect your first account"), "\(probe.labels)")
            XCTAssertTrue(
                probe.labels.contains("Add an AI provider to see usage, reset times, and balances in one place."), "\(probe.labels)"
            )
            XCTAssertEqual(addAccount.accessibilityLabel, "Add Account")
            XCTAssertEqual(addAccount.accessibilityHint, "Opens the list of supported AI providers.")
            Self.assertOnlyEmptyState("Connect your first account", in: probe)
        }
    }

    func testDashboardShowsLoadingUntilInitialRefreshCompletes() throws {
        try withDashboard(performsLifecycleWork: true, settles: false) { probe in
            XCTAssertEqual(
                probe.element(identifier: "dashboard-account-loading")?.accessibilityLabel, "Loading accounts…", "\(probe.labels)"
            )
            XCTAssertNil(probe.element(label: "Connect your first account"))

            XCTAssertTrue(probe.waitUntil { probe.element(label: "Connect your first account") != nil }, "\(probe.labels)")
            XCTAssertNil(probe.element(identifier: "dashboard-account-loading"))
        }
    }

    func testDashboardRoutesDamagedAccountDataToSettingsRecovery() throws {
        try withDashboard(prepareDefaults: { defaults in
            defaults.set(Data("not an account list".utf8), forKey: "providerConfigurations")
        }, inspect: { probe in
            XCTAssertTrue(probe.labels.contains("Open Settings to recover your saved account or group data."), "\(probe.labels)")
            XCTAssertEqual(probe.element(label: "Open Settings")?.accessibilityHint, "Opens account data recovery options.")
            Self.assertOnlyEmptyState("Account Data Needs Attention", in: probe)
        })
    }

    func testDashboardRoutesIncompleteAccountResetToSettingsRecovery() throws {
        try withDashboard(prepareDefaults: { defaults in
            defaults.set(true, forKey: "incompleteAccountReset")
        }, inspect: { probe in
            XCTAssertTrue(
                probe.labels.contains("Open Settings to retry credential cleanup before adding another account."), "\(probe.labels)"
            )
            XCTAssertEqual(probe.element(label: "Open Settings")?.accessibilityHint, "Opens account reset recovery options.")
            Self.assertOnlyEmptyState("Account Reset Needs Attention", in: probe)
        })
    }

    func testDashboardAsksToEnableAccountsWhenEverySavedAccountIsDisabled() throws {
        try withDashboard(prepareStore: { store in
            var account = try XCTUnwrap(store.addAccount(for: .openRouter))
            account.isEnabled = false
            XCTAssertTrue(store.update(account))
        }, inspect: { probe in
            XCTAssertTrue(probe.labels.contains("Enable an account in Settings to resume usage tracking."), "\(probe.labels)")
            XCTAssertEqual(probe.element(label: "Open Settings")?.accessibilityHint, "Opens Settings where accounts can be enabled.")
            Self.assertOnlyEmptyState("Accounts Are Disabled", in: probe)
        })
    }

    func testDashboardOffersSetupForEnabledAccountWithoutCredentials() throws {
        try withDashboard(prepareStore: { store in
            let account = try XCTUnwrap(store.addAccount(for: .openRouter))
            XCTAssertFalse(store.isConfigured(account))
        }, inspect: { probe in
            XCTAssertTrue(probe.labels.contains("Finish connecting your account to start seeing live usage."), "\(probe.labels)")
            XCTAssertEqual(
                probe.element(label: "Continue Setup")?.accessibilityHint, "Opens setup for the account that needs attention."
            )
            Self.assertOnlyEmptyState("Account Needs Setup", in: probe)
        })
    }

    func testProPurchaseOutcomesUpdateFeedbackAndEntitlement() throws {
        let saved = "Your purchase is saved and Pro access is available."
        let cases: [(scenario: String, product: ProProductID, feedback: String, reason: ProEntitlementReason)] = [
            ("commerce-free-trial", .monthly, "CodexBar Pro is ready, \(saved)", .monthly),
            ("commerce-free-trial", .lifetime, "Lifetime Pro is ready, \(saved)", .lifetime),
            ("commerce-pending", .monthly, "Waiting for approval, Pro will update automatically if this purchase is approved.", .none),
            ("commerce-cancelled", .monthly, "Purchase canceled, No purchase was completed.", .none),
            (
                "commerce-purchase-error", .monthly,
                "Purchase could not be completed, The purchase could not be completed. Please try again.", .none
            ),
        ]
        for testCase in cases {
            try withProPresentation(scenario: testCase.scenario) { probe, entitlement in
                XCTAssertFalse(entitlement.hasAccess, testCase.scenario)
                XCTAssertTrue(probe.activate(identifier: "pro-purchase-\(testCase.product.proIdentifier)"), "\(probe.labels)")
                XCTAssertTrue(
                    probe.waitUntil { probe.element(label: testCase.feedback) != nil },
                    "\(testCase.scenario) \(testCase.product): \(probe.labels)"
                )

                XCTAssertNil(entitlement.command)
                XCTAssertEqual(entitlement.value.reason, testCase.reason, testCase.scenario)
                XCTAssertEqual(entitlement.hasAccess, testCase.reason != .none, testCase.scenario)
            }
        }
    }

    func testSettingsLifetimeSwitchConfirmsBeforePurchasingLifetime() throws {
        try withProPresentation(scenario: "commerce-monthly-off", origin: .settings) { probe, entitlement in
            XCTAssertEqual(entitlement.value.reason, .monthly)
            XCTAssertEqual(
                probe.element(identifier: "pro-lifetime-gate")?.accessibilityLabel,
                "Auto-renew is off. Buying lifetime does not refund the remaining paid subscription period.",
                "\(probe.labels)"
            )
            XCTAssertTrue(probe.activate(identifier: "pro-switch-lifetime"), "\(probe.labels)")
            XCTAssertTrue(probe.waitUntil { probe.element(identifier: "pro-confirm-lifetime") != nil }, "\(probe.labels)")
            XCTAssertEqual(entitlement.value.reason, .monthly)

            XCTAssertTrue(probe.activate(identifier: "pro-confirm-lifetime"), "\(probe.labels)")
            XCTAssertTrue(probe.waitUntil {
                probe.element(label: "Lifetime Pro is ready, Your purchase is saved and Pro access is available.") != nil
            }, "\(probe.labels)")
            XCTAssertEqual(entitlement.value.reason, .lifetime)
            XCTAssertTrue(entitlement.hasAccess)
        }
    }

    private func withDashboard(
        performsLifecycleWork: Bool = false,
        settles: Bool = true,
        prepareDefaults: (UserDefaults) throws -> Void = { _ in },
        prepareStore: (ProviderConfigurationStore) throws -> Void = { _ in },
        inspect: (HostedViewProbe) throws -> Void
    ) throws {
        let suiteName = "FreeTierPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try prepareDefaults(defaults)
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults,
                                               secretStore: EmptySecretStore(), widgetSnapshotDefaults: nil)
        try prepareStore(store)
        let service = UsageRefreshService(providers: [])
        let statusPreferences = GitHubStatusPreferences(defaults: defaults)
        let probe = try HostedViewProbe(ContentView(
            refreshService: service,
            configurationStore: store,
            historyStore: UsageHistoryStore(defaults: defaults, accessPolicy: .pro),
            appUpdateController: AppUpdateController(defaults: defaults, releaseFetcher: PresentationOfflineNetwork()),
            githubStatusPreferences: statusPreferences,
            githubStatusMonitor: GitHubStatusMonitor(
                preferences: statusPreferences, fetcher: PresentationOfflineNetwork(), notifier: PresentationNoopGitHubNotifier()
            ),
            usageAlertNotifier: StubUsageAlertNotifier(),
            appReviewPromptPolicy: AppReviewPromptPolicy(defaults: defaults),
            performsLifecycleWork: performsLifecycleWork,
            widgetSnapshotCoordinator: WidgetSnapshotCoordinator(
                refreshService: service, configurationStore: store, publishSnapshot: { _, _ in }, publishSettings: { _ in }
            ),
            watchSnapshotCoordinator: WatchSnapshotCoordinator(
                refreshService: service, configurationStore: store,
                sender: PresentationNoopWatchSender(), publishSnapshot: { _, _, _ in }
            )
        ), settles: settles)
        defer { probe.close() }
        try inspect(probe)
    }

    private func withProPresentation(
        scenario: String,
        origin: ProPresentationOrigin = .limit,
        inspect: (HostedViewProbe, ProEntitlement) throws -> Void
    ) throws {
        let suiteName = "FreeTierPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = try XCTUnwrap(ProCommerceFixture(scenario: scenario, runID: UUID(), environment: [:]))
        let store = ProviderConfigurationStore(initialPlanAccess: .free, defaults: defaults,
                                               secretStore: EmptySecretStore(), widgetSnapshotDefaults: nil)
        let probe = try HostedViewProbe(
            ProPresentationView(configurationStore: store, origin: origin).environmentObject(fixture.entitlement)
        )
        defer { probe.close() }
        XCTAssertTrue(probe.waitUntil { probe.element(identifier: "pro-content-ready") != nil }, "\(scenario): \(probe.labels)")
        try inspect(probe, fixture.entitlement)
    }

    private static let emptyStateTitles = [
        "Account Data Needs Attention", "Account Reset Needs Attention", "Connect your first account",
        "Account Needs Setup", "Accounts Are Disabled", "No Usage Data",
    ]

    private static func assertOnlyEmptyState(_ title: String, in probe: HostedViewProbe, line: UInt = #line) {
        let labels = probe.labels
        XCTAssertEqual(emptyStateTitles.filter(labels.contains), [title], "\(labels)", line: line)
        XCTAssertNil(probe.element(identifier: "dashboard-account-loading"), line: line)
    }

    private func assertPausedRenameUsesCurrentLabel(useHistoryFallback: Bool) throws {
        let suiteName = "FreeTierPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults,
                                               secretStore: MemorySecretStore(), widgetSnapshotDefaults: nil)
        let active = ProviderAccountConfiguration(
            id: "rename.active", providerID: .openRouter, accountLabel: "Active", authMethod: .apiKey
        )
        var paused = ProviderAccountConfiguration(
            id: "rename.paused", providerID: .openRouter, accountLabel: "Old paused name", authMethod: .apiKey
        )
        for account in [active, paused] {
            XCTAssertTrue(store.update(account))
            XCTAssertTrue(store.saveSecret("isolated-rename-fixture", for: account))
        }
        store.applyPlanAccess(hasProAccess: false, isResolved: true, dashboardOrder: [active.id, paused.id])
        XCTAssertTrue(store.chooseActiveAccount(active.id))
        let observed = ProviderUsageResult(
            accountID: paused.id, providerID: paused.providerID, title: paused.displayName,
            plan: .make(providerPrefix: "openrouter", identifier: "api-credits", label: "API credits"),
            subtitle: "Preserved provider response", bars: [UsageBar(stableKey: "usage", label: "Usage", used: 36, limit: 100)],
            creditsRemaining: 12.5, usageMessages: ["Preserved usage detail"], cacheIdentity: "fixture-identity",
            fetchedAt: Date().addingTimeInterval(-3_600)
        )
        let service = UsageRefreshService(providers: [], initialResults: useHistoryFallback ? [] : [observed])
        let history = UsageHistoryStore(defaults: defaults, accessPolicy: .free)
        history.record(results: [observed])
        let storedSnapshots = history.snapshots
        let storedDailySnapshots = history.dailySnapshots
        let orchestrator = DashboardOrchestrator(
            refreshService: service, configurationStore: store, historyStore: history,
            usageAlertNotifier: StubUsageAlertNotifier(), appReviewPromptPolicy: AppReviewPromptPolicy(defaults: defaults),
            widgetSnapshotCoordinator: WidgetSnapshotCoordinator(
                refreshService: service, configurationStore: store, publishSnapshot: { _, _ in }, publishSettings: { _ in }
            ),
            watchSnapshotCoordinator: WatchSnapshotCoordinator(
                refreshService: service, configurationStore: store,
                sender: PresentationNoopWatchSender(), publishSnapshot: { _, _, _ in }
            )
        )
        XCTAssertTrue(store.accountAccess.isPaused(accountID: paused.id))
        XCTAssertEqual(orchestrator.dashboardCardItems.first { $0.id == paused.id }?.result?.title, "Old paused name")

        paused.accountLabel = "Renamed paused account"
        XCTAssertTrue(store.update(paused))
        let card = try XCTUnwrap(orchestrator.dashboardCardItems.first { $0.id == paused.id })
        // The card passes this same result to ProviderUsageHistoryDetailView.
        let displayed = try XCTUnwrap(card.result)
        var expected = observed
        expected.title = paused.displayName
        if useHistoryFallback {
            // Reconstructed bars receive fresh UUIDs; compare the preserved history values.
            XCTAssertEqual(UsageHistorySnapshot(result: displayed), UsageHistorySnapshot(result: expected))
            XCTAssertEqual(displayed.barsFetchedAt, expected.barsFetchedAt)
            XCTAssertEqual(displayed.creditsFetchedAt, expected.creditsFetchedAt)
        } else {
            XCTAssertEqual(displayed, expected)
        }
        XCTAssertEqual(displayed.title, "Renamed paused account")
        XCTAssertEqual(displayed.fetchedAt, observed.fetchedAt)
        XCTAssertEqual(displayed.creditsRemaining, observed.creditsRemaining)
        XCTAssertTrue(store.accountAccess.isPaused(accountID: paused.id))
        XCTAssertFalse(service.canRefresh(paused))
        XCTAssertFalse(service.isRefreshing)
        XCTAssertEqual(service.results, useHistoryFallback ? [] : [observed])
        XCTAssertTrue(service.successfulRefreshResults.isEmpty)
        XCTAssertEqual(history.snapshots, storedSnapshots)
        XCTAssertEqual(history.dailySnapshots, storedDailySnapshots)
    }

    private func displayedResult(
        configuration: ProviderAccountConfiguration,
        observed: ProviderUsageResult,
        requiresSetup: Bool = false
    ) throws -> ProviderUsageResult {
        try XCTUnwrap(DashboardProviderCardItem.items(
            configurations: [configuration], results: [observed], refreshingAccountIDs: [], errorsByAccountID: [:],
            orderingMode: .manual, manualOrder: [], setupRequiredAccountIDs: requiresSetup ? [configuration.id] : []
        ).first?.result)
    }
}

@MainActor
private final class PresentationNoopWatchSender: WatchSnapshotSending {
    func activate(onSnapshotNeeded: @escaping @MainActor (Bool) -> Void) {}
    func publish(_ snapshot: WatchDashboardSnapshot, force: Bool) -> Bool { true }
}

private struct PresentationOfflineNetwork: AppStoreReleaseFetching, GitHubStatusFetching {
    func fetchRelease() async throws -> AppStoreRelease { throw URLError(.notConnectedToInternet) }
    func fetchStatus(checkedAt: Date) async throws -> GitHubServiceStatusSnapshot { throw URLError(.notConnectedToInternet) }
}

private final class PresentationNoopGitHubNotifier: GitHubStatusNotifying {
    func deliverGitHubStatus(_ notification: GitHubStatusNotification) async throws {}
}
