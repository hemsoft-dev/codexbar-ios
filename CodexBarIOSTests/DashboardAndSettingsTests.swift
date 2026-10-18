import XCTest
@testable import CodexBarIOS

final class DashboardAndSettingsTests: XCTestCase {
    @MainActor
    func testProviderSettingsRowAccessibilityDescribesStatusAndGroupOnce() {
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)

        XCTAssertEqual(
            ProviderSettingsRow.accessibilityValue(
                configuration: configuration,
                isConfigured: true,
                groupName: "Work"
            ),
            "Claude configured, Work group"
        )
        XCTAssertEqual(
            ProviderSettingsRow.accessibilityValue(
                configuration: configuration,
                isConfigured: false,
                groupName: nil
            ),
            "Claude needs setup"
        )

        configuration.isEnabled = false
        XCTAssertEqual(
            ProviderSettingsRow.accessibilityValue(
                configuration: configuration,
                isConfigured: true,
                groupName: "Work"
            ),
            "Disabled, Work group"
        )
    }

    func testSettingsDismissalConsumesCredentialRefreshExactlyOnce() {
        var state = SettingsDismissalRefreshState()

        XCTAssertEqual(state.finishDismissal(), .allAccounts)

        state.credentialsChanged(accountID: "openRouter.personal")
        XCTAssertEqual(state.finishDismissal(), .none)
        XCTAssertEqual(state.finishDismissal(), .allAccounts)

        state.credentialsChanged(accountID: "openRouter.personal")
        state.refreshInputsChanged(accountID: "openRouter.personal")
        XCTAssertEqual(state.finishDismissal(), .accounts(["openRouter.personal"]))

        state.refreshInputsChanged(accountID: "codex.work")
        state.credentialsChanged(accountID: "openRouter.personal")
        XCTAssertEqual(state.finishDismissal(), .accounts(["codex.work"]))

        var navigation = DashboardAccountConfigurationNavigationState()
        navigation.present(accountID: "openRouter.work")
        navigation.credentialsChanged()
        navigation.refreshInputsChanged()
        XCTAssertEqual(navigation.finishDismissal(), "openRouter.work")

        var addAccountState = AddAccountRefreshState()
        addAccountState.accountCreated("openCodeZen.team")
        XCTAssertEqual(addAccountState.credentialsChanged(), "openCodeZen.team")
        addAccountState.refreshInputsChanged()
        XCTAssertEqual(addAccountState.finishDismissal(), "openCodeZen.team")
    }

    func testGoogleSetupDismissalWaitsForChangedRefreshInputs() {
        var navigation = DashboardAccountConfigurationNavigationState()
        let accountID = "dashboard.setup.antigravity"

        navigation.present(accountID: accountID, refreshOnDismiss: false)
        // A repeated sheet binding write must not arm an unrequested refresh.
        navigation.present(accountID: accountID)
        navigation.clearPresentation()
        XCTAssertNil(navigation.finishDismissal())

        navigation.present(accountID: accountID, refreshOnDismiss: false)
        navigation.refreshInputsChanged()
        XCTAssertEqual(navigation.finishDismissal(), accountID)
        XCTAssertNil(navigation.finishDismissal())

        navigation.present(accountID: accountID, refreshOnDismiss: false)
        navigation.refreshInputsChanged()
        navigation.credentialsChanged()
        XCTAssertNil(navigation.finishDismissal())

        navigation.present(accountID: "configured.account")
        XCTAssertEqual(navigation.finishDismissal(), "configured.account")
    }

    @MainActor
    func testAccountSettingsReportsOnlyProviderRefreshInputChanges() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        let configuration = try XCTUnwrap(store.addAccount(for: .openCodeZen))
        var refreshInputChangeCount = 0
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            onRefreshInputsChanged: { refreshInputChangeCount += 1 }
        )

        viewModel.binding(for: \.accountLabel).wrappedValue = "Team Zen"
        XCTAssertEqual(refreshInputChangeCount, 0)

        viewModel.binding(for: \.openCodeWorkspaceId).wrappedValue = "wrk_changed"
        XCTAssertEqual(refreshInputChangeCount, 1)
    }

    func testSettingsDoneToolbarPolicyKeepsDoneVisibleAcrossCompactNavigation() {
        XCTAssertTrue(
            SettingsDoneToolbarPolicy.showsDone(
                in: .sidebar,
                horizontalSizeClass: .compact
            )
        )
        XCTAssertTrue(
            SettingsDoneToolbarPolicy.showsDone(
                in: .detail,
                horizontalSizeClass: .compact
            )
        )
    }

    func testSettingsDoneToolbarPolicyAvoidsDuplicateDoneButtonsInRegularLayouts() {
        XCTAssertFalse(
            SettingsDoneToolbarPolicy.showsDone(
                in: .sidebar,
                horizontalSizeClass: .regular
            )
        )
        XCTAssertTrue(
            SettingsDoneToolbarPolicy.showsDone(
                in: .detail,
                horizontalSizeClass: .regular
            )
        )
    }

    func testSettingsDoneActionCommitsBeforeDismissing() {
        var events: [String] = []

        XCTAssertTrue(
            SettingsNavigationGuard.perform(
                commitPendingChanges: {
                    events.append("commit")
                    return true
                },
                navigate: {
                    events.append("dismiss")
                }
            )
        )
        XCTAssertEqual(events, ["commit", "dismiss"])
    }

    func testSettingsDoneActionKeepsSettingsOpenAfterInvalidEdit() {
        var didDismiss = false

        XCTAssertFalse(
            SettingsNavigationGuard.perform(
                commitPendingChanges: { false },
                navigate: { didDismiss = true }
            )
        )
        XCTAssertFalse(didDismiss)
    }

    @MainActor
    func testDemoRefreshReturnsEveryProviderResult() async {
        let service = UsageRefreshService.demo()

        await service.refresh()

        XCTAssertEqual(
            Set(service.results.map(\.providerID)),
            Set(ProviderID.allCases.filter { $0 != .antigravity })
        )
        XCTAssertFalse(service.isRefreshing)
        XCTAssertNil(service.lastRefreshError)
    }

    func testDashboardCardItemsRepresentConfiguredAccountsBeforeResultsArrive() {
        var codex = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        codex.accountLabel = "Personal Codex"
        var claude = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        claude.accountLabel = "Work Claude"

        let items = DashboardProviderCardItem.items(
            configurations: [codex, claude],
            results: [],
            refreshingAccountIDs: [codex.id, claude.id],
            errorsByAccountID: [:],
            orderingMode: .manual,
            manualOrder: [claude.id, codex.id]
        )

        XCTAssertEqual(items.map(\.id), [claude.id, codex.id])
        XCTAssertEqual(items.map(\.configuration.displayName), ["Work Claude", "Personal Codex"])
        XCTAssertTrue(items.allSatisfy { $0.result == nil && $0.isRefreshing })
    }

    func testDashboardCardItemsAreEmptyWhenNoProvidersAreConfigured() {
        let staleResult = makeHistoryResult(
            accountID: "removed.account",
            fetchedAt: Date(),
            used: 10
        )

        let items = DashboardProviderCardItem.items(
            configurations: [],
            results: [staleResult],
            refreshingAccountIDs: [],
            errorsByAccountID: [:],
            orderingMode: .manual,
            manualOrder: []
        )

        XCTAssertTrue(items.isEmpty)
    }

    @MainActor
    func testUnconfiguredClaudeAccountRemainsAvailableForDashboardSignIn() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        let claude = try XCTUnwrap(store.addAccount(for: .claude))
        let openRouter = try XCTUnwrap(store.addAccount(for: .openRouter))

        XCTAssertTrue(store.shouldDisplayOnDashboard(claude))
        XCTAssertFalse(store.shouldDisplayOnDashboard(openRouter))
    }

    func testDashboardCardItemsKeepLoadedAndFailedAccountsVisible() {
        let codex = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let claude = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        let codexResult = makeHistoryResult(
            accountID: codex.id,
            providerID: .codex,
            fetchedAt: Date(),
            used: 25
        )

        let items = DashboardProviderCardItem.items(
            configurations: [codex, claude],
            results: [codexResult],
            refreshingAccountIDs: [codex.id],
            errorsByAccountID: [claude.id: "Session expired"],
            orderingMode: .manual,
            manualOrder: []
        )

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].result, codexResult)
        XCTAssertTrue(items[0].isRefreshing)
        XCTAssertNil(items[1].result)
        XCTAssertEqual(items[1].errorMessage, "Session expired")
    }

    func testDashboardCardItemsUseTypedRecoveryActionFromProviderResult() {
        let claude = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        let rejected = ProviderUsageResult(
            accountID: claude.id,
            providerID: .claude,
            title: claude.displayName,
            subtitle: "Claude credential was rejected. Sign in again.",
            bars: [],
            failureMessage: "Claude credential was rejected. Sign in again.",
            recoveryAction: .reauthenticate,
            fetchedAt: Date()
        )

        let item = DashboardProviderCardItem.items(
            configurations: [claude],
            results: [rejected],
            refreshingAccountIDs: [],
            errorsByAccountID: [claude.id: rejected.subtitle],
            orderingMode: .manual,
            manualOrder: []
        ).first

        XCTAssertEqual(item?.recoveryAction, .reauthenticate)
    }

    func testDashboardAuthenticationRecoveryRoutesNonClaudeProvidersToSettings() {
        XCTAssertEqual(
            DashboardRecoveryRoute.resolve(action: .signIn, providerID: .greptile),
            .accountSettings
        )
        XCTAssertEqual(
            DashboardRecoveryRoute.resolve(action: .reauthenticate, providerID: .greptile),
            .accountSettings
        )
        XCTAssertEqual(
            DashboardRecoveryRoute.resolve(action: .reauthenticate, providerID: .claude),
            .claudeSignIn
        )
        XCTAssertEqual(
            DashboardRecoveryRoute.resolve(action: .retryRefresh, providerID: .greptile),
            .retryRefresh
        )
    }

    @MainActor
    func testDashboardClaudeSignInReplacesAndRefreshesOnlyInitiatingAccount() async throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let secretStore = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        var first = try XCTUnwrap(store.addAccount(for: .claude))
        first.accountLabel = "Work Claude"
        first.showsHistory = false
        XCTAssertTrue(store.update(first))
        var second = try XCTUnwrap(store.addAccount(for: .claude))
        second.accountLabel = "Personal Claude"
        XCTAssertTrue(store.update(second))
        XCTAssertTrue(store.saveSecret("first-old-credential", for: first))
        XCTAssertTrue(store.saveSecret("second-old-credential", for: second))

        var refreshedAccountIDs: [String] = []
        let replacement = ClaudeCredentials(
            subscriptionType: "pro",
            accessToken: "first-new-token",
            refreshToken: "first-new-refresh"
        )
        let controller = DashboardClaudeAuthenticationController(
            configurationStore: store,
            authenticate: { _, reportStage, _ in
                reportStage("Waiting for Claude to return to the app...")
                return ClaudeWebAuthResult(credentials: replacement)
            },
            refreshAccount: { configuration in
                refreshedAccountIDs.append(configuration.id)
                return ProviderUsageResult(
                    accountID: configuration.id,
                    providerID: .claude,
                    title: configuration.displayName,
                    subtitle: "Claude usage",
                    bars: [],
                    fetchedAt: Date()
                )
            }
        )

        XCTAssertTrue(controller.startSignIn(for: first))
        XCTAssertFalse(controller.startSignIn(for: second))
        await controller.waitForAuthenticationToFinish()

        let savedFirst = try XCTUnwrap(store.configuration(accountID: first.id))
        let savedSecond = try XCTUnwrap(store.configuration(accountID: second.id))
        XCTAssertEqual(savedFirst.accountLabel, "Work Claude")
        XCTAssertFalse(savedFirst.showsHistory)
        XCTAssertEqual(savedSecond.accountLabel, "Personal Claude")
        XCTAssertEqual(refreshedAccountIDs, [first.id])
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: savedFirst)),
            ClaudeCredentialsParser.storedCredential(from: replacement)
        )
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: savedSecond)),
            "second-old-credential"
        )
        XCTAssertEqual(
            controller.state(for: first.id),
            DashboardClaudeAuthenticationState(
                isSigningIn: false,
                statusMessage: "Claude sign-in complete.",
                errorMessage: nil
            )
        )
    }

    @MainActor
    func testDashboardClaudeSignInFailurePreservesExistingCredential() async throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let secretStore = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let claude = try XCTUnwrap(store.addAccount(for: .claude))
        XCTAssertTrue(store.saveSecret("existing-credential", for: claude))
        var refreshCount = 0
        let controller = DashboardClaudeAuthenticationController(
            configurationStore: store,
            authenticate: { _, _, _ in
                throw URLError(.notConnectedToInternet)
            },
            refreshAccount: { _ in
                refreshCount += 1
                return nil
            }
        )

        XCTAssertTrue(controller.startSignIn(for: claude))
        await controller.waitForAuthenticationToFinish()

        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: claude)),
            "existing-credential"
        )
        XCTAssertEqual(refreshCount, 0)
        XCTAssertFalse(controller.state(for: claude.id).isSigningIn)
        XCTAssertNotNil(controller.state(for: claude.id).errorMessage)
    }

    @MainActor
    func testDashboardClaudeCredentialSaveFailurePreservesExistingCredential() async throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let secretStore = FailingSaveSecretStore(secret: "existing-credential")
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let claude = try XCTUnwrap(store.addAccount(for: .claude))
        var refreshCount = 0
        let controller = DashboardClaudeAuthenticationController(
            configurationStore: store,
            authenticate: { _, _, _ in
                ClaudeWebAuthResult(
                    credentials: ClaudeCredentials(accessToken: "replacement-token")
                )
            },
            refreshAccount: { _ in
                refreshCount += 1
                return nil
            }
        )

        XCTAssertTrue(controller.startSignIn(for: claude))
        await controller.waitForAuthenticationToFinish()

        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: claude)),
            "existing-credential"
        )
        XCTAssertEqual(refreshCount, 0)
        XCTAssertFalse(controller.state(for: claude.id).isSigningIn)
        XCTAssertNotNil(controller.state(for: claude.id).errorMessage)
    }

    @MainActor
    func testDashboardClaudeSignInCancellationPreservesExistingCredential() async throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let secretStore = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let claude = try XCTUnwrap(store.addAccount(for: .claude))
        XCTAssertTrue(store.saveSecret("existing-credential", for: claude))
        let controller = DashboardClaudeAuthenticationController(
            configurationStore: store,
            authenticate: { presentAuthorizationURL, _, _ in
                presentAuthorizationURL(URL(string: "https://claude.ai/oauth")!)
                try await Task.sleep(for: .seconds(30))
                return ClaudeWebAuthResult(credentials: ClaudeCredentials(accessToken: "unused"))
            },
            refreshAccount: { _ in
                XCTFail("Canceled sign-in must not refresh.")
                return nil
            }
        )

        XCTAssertTrue(controller.startSignIn(for: claude))
        await Task.yield()
        controller.cancelAuthentication()
        await controller.waitForAuthenticationToFinish()

        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: claude)),
            "existing-credential"
        )
        XCTAssertEqual(
            controller.state(for: claude.id).errorMessage,
            "Claude sign-in canceled. The existing credential was not changed."
        )
    }

    @MainActor
    func testDashboardClaudeSheetDismissalAfterCallbackKeepsTokenExchangeAlive() async throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let secretStore = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let claude = try XCTUnwrap(store.addAccount(for: .claude))
        XCTAssertTrue(store.saveSecret("existing-credential", for: claude))
        let exchangeGate = UsageProviderGate()
        var refreshCount = 0
        let controller = DashboardClaudeAuthenticationController(
            configurationStore: store,
            authenticate: { presentAuthorizationURL, reportStage, didReceiveCallback in
                presentAuthorizationURL(URL(string: "https://claude.ai/oauth")!)
                reportStage("Waiting for Claude to return to the app...")
                didReceiveCallback()
                await exchangeGate.wait()
                return ClaudeWebAuthResult(
                    credentials: ClaudeCredentials(accessToken: "replacement-token")
                )
            },
            refreshAccount: { _ in
                refreshCount += 1
                return nil
            }
        )

        XCTAssertTrue(controller.startSignIn(for: claude))
        await exchangeGate.waitUntilBlocked()
        XCTAssertNil(controller.authURL)

        controller.cancelAuthentication()
        XCTAssertTrue(controller.state(for: claude.id).isSigningIn)

        await exchangeGate.release()
        await controller.waitForAuthenticationToFinish()

        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: claude)),
            ClaudeCredentialsParser.storedCredential(
                from: ClaudeCredentials(accessToken: "replacement-token")
            )
        )
        XCTAssertEqual(refreshCount, 1)
        XCTAssertNil(controller.state(for: claude.id).errorMessage)
    }

    @MainActor
    func testRefreshPublishesAccountsAsEachFetchCompletes() async {
        let gate = UsageProviderGate()
        let slow = ProviderAccountConfiguration(
            id: "codex.slow",
            providerID: .codex,
            accountLabel: "A Slow Codex",
            authMethod: .browserSession
        )
        let fast = ProviderAccountConfiguration(
            id: "codex.fast",
            providerID: .codex,
            accountLabel: "Z Fast Codex",
            authMethod: .browserSession
        )
        let service = UsageRefreshService(providers: [
            GatedUsageProvider(providerID: .codex, blockedAccountID: slow.id, gate: gate),
        ])

        let refreshTask = Task {
            await service.refresh(configurations: [slow, fast])
        }
        await gate.waitUntilBlocked()
        for _ in 0..<100 where service.results.first(where: { $0.accountID == fast.id }) == nil {
            await Task.yield()
        }

        XCTAssertEqual(service.results.map(\.accountID), [fast.id])
        XCTAssertEqual(service.refreshingAccountIDs, [slow.id])
        XCTAssertEqual(service.incompleteRefreshAccountIDs, [slow.id])
        XCTAssertTrue(service.isRefreshing)

        await gate.release()
        await refreshTask.value

        XCTAssertEqual(service.results.map(\.accountID), [fast.id, slow.id])
        XCTAssertTrue(service.refreshingAccountIDs.isEmpty)
        XCTAssertFalse(service.isRefreshing)
        XCTAssertNil(service.lastRefreshError)
    }

    @MainActor
    func testRefreshPreservesCachedResultWhileAccountIsLoading() async {
        let gate = UsageProviderGate()
        let configuration = ProviderAccountConfiguration(
            id: "codex.cached",
            providerID: .codex,
            accountLabel: "Cached Codex",
            authMethod: .browserSession
        )
        let cachedResult = makeHistoryResult(
            accountID: configuration.id,
            providerID: .codex,
            fetchedAt: Date().addingTimeInterval(-300),
            used: 15
        )
        let service = UsageRefreshService(
            providers: [
                GatedUsageProvider(
                    providerID: .codex,
                    blockedAccountID: configuration.id,
                    gate: gate
                ),
            ],
            initialResults: [cachedResult]
        )

        let refreshTask = Task {
            await service.refresh(configurations: [configuration])
        }
        await gate.waitUntilBlocked()

        XCTAssertEqual(service.results, [cachedResult])
        XCTAssertEqual(service.refreshingAccountIDs, [configuration.id])

        await gate.release()
        await refreshTask.value

        XCTAssertEqual(service.results.first?.accountID, configuration.id)
        XCTAssertNotEqual(service.results.first, cachedResult)
        XCTAssertTrue(service.refreshingAccountIDs.isEmpty)
    }

    @MainActor
    func testExplicitAccountRefreshQueuesBehindInFlightStartupRefresh() async {
        let gate = UsageProviderGate()
        let startupConfiguration = ProviderAccountConfiguration(
            id: "codex.queued",
            providerID: .codex,
            accountLabel: "Original Codex",
            authMethod: .browserSession
        )
        var updatedConfiguration = startupConfiguration
        updatedConfiguration.accountLabel = "Updated Codex"
        let service = UsageRefreshService(providers: [
            GatedUsageProvider(
                providerID: .codex,
                blockedAccountID: startupConfiguration.id,
                gate: gate
            ),
        ])

        let startupRefresh = Task {
            await service.refresh(configurations: [startupConfiguration])
        }
        await gate.waitUntilBlocked()
        service.updateCurrentConfigurations([updatedConfiguration])
        let explicitRefresh = Task {
            await service.refresh(configuration: updatedConfiguration)
        }
        await Task.yield()

        XCTAssertEqual(service.refreshingAccountIDs, [startupConfiguration.id])

        await gate.release()
        await startupRefresh.value
        let updatedResult = await explicitRefresh.value

        XCTAssertEqual(updatedResult?.title, "Updated Codex")
        XCTAssertEqual(service.results.first?.title, "Updated Codex")
        XCTAssertTrue(service.refreshingAccountIDs.isEmpty)
    }

    @MainActor
    func testMetricDiscoveryReusesInFlightAccountRefresh() async {
        let gate = UsageProviderGate()
        let recorder = UsageProviderRecorder()
        let configuration = ProviderAccountConfiguration(
            id: "codex.metrics",
            providerID: .codex,
            accountLabel: "Codex Metrics",
            authMethod: .browserSession
        )
        let service = UsageRefreshService(providers: [
            GatedUsageProvider(
                providerID: .codex,
                blockedAccountID: configuration.id,
                gate: gate,
                recorder: recorder
            ),
        ])

        let dashboardRefresh = Task {
            await service.refresh(configurations: [configuration])
        }
        await gate.waitUntilBlocked()
        let metricDiscovery = Task {
            await service.resultAfterCurrentRefresh(configuration: configuration)
        }

        await gate.release()
        await dashboardRefresh.value
        let result = await metricDiscovery.value
        let recordedLabels = await recorder.recordedLabels()

        XCTAssertEqual(result?.accountID, configuration.id)
        XCTAssertEqual(recordedLabels, ["Codex Metrics"])
    }

    @MainActor
    func testExplicitRefreshDoesNotReregisterObsoleteConfiguration() async {
        let recorder = UsageProviderRecorder()
        let configuration = ProviderAccountConfiguration(
            id: "codex.removed-explicit",
            providerID: .codex,
            accountLabel: "Removed Codex",
            authMethod: .browserSession
        )
        let service = UsageRefreshService(providers: [
            GatedUsageProvider(
                providerID: .codex,
                blockedAccountID: "not-blocked",
                gate: UsageProviderGate(),
                recorder: recorder
            ),
        ])
        service.updateCurrentConfigurations([configuration])
        var updatedConfiguration = configuration
        updatedConfiguration.accountLabel = "Updated Codex"
        service.updateCurrentConfigurations([updatedConfiguration])

        let replacedResult = await service.refresh(configuration: configuration)
        let labelsAfterReplacement = await recorder.recordedLabels()

        XCTAssertNil(replacedResult)
        XCTAssertTrue(labelsAfterReplacement.isEmpty)
        XCTAssertEqual(service.trackedRefreshGenerationCount, 1)

        service.updateCurrentConfigurations([])

        let removedResult = await service.refresh(configuration: configuration)
        let recordedLabels = await recorder.recordedLabels()

        XCTAssertNil(removedResult)
        XCTAssertTrue(recordedLabels.isEmpty)
        XCTAssertEqual(service.trackedRefreshGenerationCount, 0)
    }

    @MainActor
    func testBatchRefreshRechecksAccountsAfterWaitingForInFlightRefresh() async {
        let firstGate = UsageProviderGate()
        let secondGate = UsageProviderGate()
        let recorder = UsageProviderRecorder()
        let first = ProviderAccountConfiguration(
            id: "codex.first-explicit",
            providerID: .codex,
            accountLabel: "First Codex",
            authMethod: .browserSession
        )
        let second = ProviderAccountConfiguration(
            id: "codex.second-explicit",
            providerID: .codex,
            accountLabel: "Second Codex",
            authMethod: .browserSession
        )
        let service = UsageRefreshService(providers: [
            AccountGatedUsageProvider(
                providerID: .codex,
                gates: [first.id: firstGate, second.id: secondGate],
                recorder: recorder
            ),
        ])

        let secondRefresh = Task {
            await service.refresh(configuration: second)
        }
        await secondGate.waitUntilBlocked()
        let batchRefresh = Task {
            await service.refresh(configurations: [first, second])
        }
        while service.refreshWaiterCount(for: second.id) < 1 {
            await Task.yield()
        }
        let firstRefresh = Task {
            await service.refresh(configuration: first)
        }
        await firstGate.waitUntilBlocked()

        await secondGate.release()
        _ = await secondRefresh.value
        while service.refreshWaiterCount(for: first.id) < 1 {
            await Task.yield()
        }

        let labelsBeforeFirstRelease = await recorder.recordedLabels()
        XCTAssertEqual(labelsBeforeFirstRelease.filter { $0 == first.accountLabel }.count, 1)
        XCTAssertEqual(service.refreshingAccountIDs, [first.id])

        await firstGate.release()
        _ = await firstRefresh.value
        await batchRefresh.value

        let completedLabels = await recorder.recordedLabels()
        XCTAssertEqual(completedLabels.filter { $0 == first.accountLabel }.count, 2)
        XCTAssertEqual(completedLabels.filter { $0 == second.accountLabel }.count, 2)
        XCTAssertTrue(service.refreshingAccountIDs.isEmpty)
    }

    @MainActor
    func testConcurrentBatchRefreshQueuesOneFollowUpRun() async {
        let gate = UsageProviderGate()
        let recorder = UsageProviderRecorder()
        let firstConfiguration = ProviderAccountConfiguration(
            id: "codex.coalesced",
            providerID: .codex,
            accountLabel: "Original Codex",
            authMethod: .browserSession
        )
        var pendingConfiguration = firstConfiguration
        pendingConfiguration.accountLabel = "Intermediate Codex"
        var latestConfiguration = firstConfiguration
        latestConfiguration.accountLabel = "Updated Codex"
        let service = UsageRefreshService(providers: [
            GatedUsageProvider(
                providerID: .codex,
                blockedAccountID: firstConfiguration.id,
                gate: gate,
                recorder: recorder
            ),
        ])
        let pendingRefreshCompleted = AsyncFlag()
        let latestRefreshCompleted = AsyncFlag()

        let firstRefresh = Task {
            await service.refresh(configurations: [firstConfiguration])
        }
        await gate.waitUntilBlocked()
        let pendingRefresh = Task {
            await service.refresh(configurations: [pendingConfiguration])
            await pendingRefreshCompleted.set()
        }
        while service.queuedBatchRefreshCount < 1 {
            await Task.yield()
        }

        let completedBeforeRelease = await pendingRefreshCompleted.currentValue()
        XCTAssertFalse(completedBeforeRelease)
        let latestRefresh = Task {
            await service.refresh(configurations: [latestConfiguration])
            await latestRefreshCompleted.set()
        }
        while service.queuedBatchRefreshCount < 2 {
            await Task.yield()
        }
        let latestCompletedBeforeRelease = await latestRefreshCompleted.currentValue()
        XCTAssertFalse(latestCompletedBeforeRelease)

        await gate.release()
        await firstRefresh.value
        await pendingRefresh.value
        await latestRefresh.value

        let completedAfterRelease = await pendingRefreshCompleted.currentValue()
        XCTAssertTrue(completedAfterRelease)
        let latestCompletedAfterRelease = await latestRefreshCompleted.currentValue()
        XCTAssertTrue(latestCompletedAfterRelease)
        let recordedLabels = await recorder.recordedLabels()
        XCTAssertEqual(recordedLabels, ["Original Codex", "Updated Codex"])
        XCTAssertEqual(service.results.map(\.accountID), [latestConfiguration.id])
        XCTAssertEqual(service.results.first?.title, "Updated Codex")
        XCTAssertTrue(service.refreshingAccountIDs.isEmpty)
    }

    @MainActor
    func testRemovedAndDisabledAccountsDiscardSuspendedSuccessfulRefreshes() async {
        for mutation in StaleRefreshConfigurationMutation.allCases {
            await assertStaleCompletionIsDiscarded(
                fails: false,
                mutation: mutation
            )
        }
    }

    @MainActor
    func testRemovedAndDisabledAccountsDiscardSuspendedFailedRefreshes() async {
        for mutation in StaleRefreshConfigurationMutation.allCases {
            await assertStaleCompletionIsDiscarded(
                fails: true,
                mutation: mutation
            )
        }
    }

    @MainActor
    func testRemovedAndDisabledAccountsDoNotRefreshAfterSuspendedReset() async {
        for mutation in StaleRefreshConfigurationMutation.allCases {
            await assertSuspendedResetDoesNotReregisterConfiguration(mutation)
        }
    }

    @MainActor
    func testPresentationOnlyChangesUseCurrentConfigurationAfterSuspendedReset() async throws {
        let gate = UsageProviderGate()
        let provider = ResetConsumptionTestProvider(
            outcome: .reset,
            fetchFails: false,
            fetchedUsed: 95,
            consumeGate: gate
        )
        let harness = makeStaleRefreshHarness(providers: [provider], cachedUsed: 15)
        defer { harness.removeDefaults() }

        let consumption = Task { @MainActor in
            await harness.orchestrator.consumeCodexBankedReset(
                for: harness.configuration,
                creditID: "presentation-edit"
            )
        }
        await gate.waitUntilBlocked()

        let group = try XCTUnwrap(harness.configurationStore.addGroup(named: "Work"))
        var updatedConfiguration = harness.configuration
        updatedConfiguration.accountLabel = "Renamed Codex"
        updatedConfiguration.groupID = group.id
        updatedConfiguration.showsHistory = false
        XCTAssertTrue(harness.configurationStore.update(updatedConfiguration))

        await gate.release()
        let feedback = await consumption.value
        let fetchCount = await provider.recordedFetchCount()

        XCTAssertTrue(feedback.isSuccess)
        XCTAssertEqual(feedback.message, "Reset used. Current usage limits are refreshed.")
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(harness.refreshService.results.first?.title, "Renamed Codex")
        XCTAssertEqual(harness.refreshService.results.first?.subtitle, "Fresh usage")
        XCTAssertFalse(harness.historyStore.snapshots.isEmpty)
        XCTAssertFalse(harness.configurationStore.usageAlertActiveIDs.isEmpty)
        XCTAssertFalse(harness.notifier.deliveredNotifications.isEmpty)
        XCTAssertNotNil(harness.orchestrator.currentUsageAlertsByAccountID[harness.configuration.id])
    }

    @MainActor
    func testRefreshInputChangesDoNotUseCurrentConfigurationAfterSuspendedReset() async {
        let gate = UsageProviderGate()
        let provider = ResetConsumptionTestProvider(
            outcome: .reset,
            fetchFails: false,
            consumeGate: gate
        )
        let harness = makeStaleRefreshHarness(providers: [provider])
        defer { harness.removeDefaults() }

        let consumption = Task { @MainActor in
            await harness.orchestrator.consumeCodexBankedReset(
                for: harness.configuration,
                creditID: "refresh-input-edit"
            )
        }
        await gate.waitUntilBlocked()

        var updatedConfiguration = harness.configuration
        updatedConfiguration.oauthClientID = "updated-client"
        XCTAssertTrue(harness.configurationStore.update(updatedConfiguration))

        await gate.release()
        let feedback = await consumption.value
        let fetchCount = await provider.recordedFetchCount()

        XCTAssertTrue(feedback.isSuccess)
        XCTAssertTrue(feedback.message.contains("could not be refreshed"))
        XCTAssertEqual(fetchCount, 0)
        XCTAssertTrue(harness.refreshService.results.isEmpty)
        XCTAssertTrue(harness.historyStore.snapshots.isEmpty)
        XCTAssertTrue(harness.configurationStore.usageAlertActiveIDs.isEmpty)
        XCTAssertTrue(harness.notifier.deliveredNotifications.isEmpty)
    }

    @MainActor
    func testChangedAccountDiscardsCachedStateDuringSuspendedBatchRefresh() async {
        let gate = UsageProviderGate()
        let harness = makeStaleRefreshHarness(
            providers: [
                StaleCompletionTestUsageProvider(
                    providerID: .codex,
                    gate: gate,
                    fails: false
                ),
            ]
        )
        defer { harness.removeDefaults() }

        let refresh = Task { @MainActor in
            await harness.orchestrator.refreshNow()
        }
        await gate.waitUntilBlocked()

        var updatedConfiguration = harness.configuration
        updatedConfiguration.oauthClientID = "updated-client"
        XCTAssertTrue(harness.configurationStore.update(updatedConfiguration))
        XCTAssertTrue(harness.refreshService.results.isEmpty)

        await gate.release()
        _ = await refresh.value

        XCTAssertTrue(harness.refreshService.results.isEmpty)
        XCTAssertTrue(harness.refreshService.refreshErrorsByAccountID.isEmpty)
        XCTAssertNil(harness.refreshService.lastRefreshError)
        XCTAssertTrue(harness.refreshService.refreshingAccountIDs.isEmpty)
        XCTAssertTrue(harness.historyStore.snapshots.isEmpty)
        XCTAssertTrue(harness.configurationStore.usageAlertActiveIDs.isEmpty)
        XCTAssertTrue(harness.notifier.deliveredNotifications.isEmpty)
        XCTAssertTrue(harness.orchestrator.currentUsageAlertsByAccountID.isEmpty)
    }

    @MainActor
    func testPresentationOnlyAccountChangesPreserveCachedState() async {
        let configuration = ProviderAccountConfiguration(
            id: "codex.presentation-only",
            providerID: .codex,
            accountLabel: "Original Codex",
            authMethod: .browserSession
        )
        let cachedResult = makeHistoryResult(
            accountID: configuration.id,
            providerID: .codex,
            fetchedAt: Date().addingTimeInterval(-300),
            used: 15
        )
        let service = UsageRefreshService(
            providers: [
                SelectivelyFailingUsageProvider(
                    providerID: .codex,
                    failedAccountID: configuration.id
                ),
            ],
            initialResults: [cachedResult]
        )
        await service.refresh(configurations: [configuration])
        let resultAfterFailure = service.results
        let cachedError = service.refreshErrorsByAccountID[configuration.id]
        XCTAssertFalse(resultAfterFailure.isEmpty)
        XCTAssertNotNil(cachedError)

        var updatedConfiguration = configuration
        updatedConfiguration.accountLabel = "Renamed Codex"
        updatedConfiguration.groupID = "work"
        updatedConfiguration.showsHistory = false
        service.updateCurrentConfigurations([updatedConfiguration])

        XCTAssertEqual(service.results, resultAfterFailure)
        XCTAssertEqual(service.refreshErrorsByAccountID[configuration.id], cachedError)
        XCTAssertEqual(service.lastRefreshError, cachedError)
    }

    @MainActor
    func testPresentationOnlyChangesAcceptSuspendedBatchRefreshCompletion() async throws {
        let gate = UsageProviderGate()
        let harness = makeStaleRefreshHarness(
            providers: [
                StaleCompletionTestUsageProvider(
                    providerID: .codex,
                    gate: gate,
                    fails: false
                ),
            ],
            cachedUsed: 15
        )
        defer { harness.removeDefaults() }
        let cachedResult = try XCTUnwrap(harness.refreshService.results.first)

        let refresh = Task { @MainActor in
            await harness.orchestrator.refreshNow()
        }
        await gate.waitUntilBlocked()

        let group = try XCTUnwrap(harness.configurationStore.addGroup(named: "Work"))
        var updatedConfiguration = harness.configuration
        updatedConfiguration.accountLabel = "Renamed Codex"
        updatedConfiguration.groupID = group.id
        XCTAssertTrue(harness.configurationStore.update(updatedConfiguration))
        XCTAssertEqual(harness.refreshService.results, [cachedResult])

        await gate.release()
        _ = await refresh.value

        XCTAssertEqual(harness.refreshService.results.first?.subtitle, "Fresh usage")
        XCTAssertFalse(harness.historyStore.snapshots.isEmpty)
        XCTAssertFalse(harness.configurationStore.usageAlertActiveIDs.isEmpty)
        XCTAssertFalse(harness.notifier.deliveredNotifications.isEmpty)
        XCTAssertNotNil(harness.orchestrator.currentUsageAlertsByAccountID[harness.configuration.id])
    }

    @MainActor
    private func assertSuspendedResetDoesNotReregisterConfiguration(
        _ mutation: StaleRefreshConfigurationMutation
    ) async {
        let gate = UsageProviderGate()
        let provider = ResetConsumptionTestProvider(
            outcome: .reset,
            fetchFails: false,
            consumeGate: gate
        )
        let harness = makeStaleRefreshHarness(providers: [provider])
        defer { harness.removeDefaults() }

        let consumption = Task { @MainActor in
            await harness.orchestrator.consumeCodexBankedReset(
                for: harness.configuration,
                creditID: "stale-credit"
            )
        }
        await gate.waitUntilBlocked()

        switch mutation {
        case .remove:
            XCTAssertTrue(harness.configurationStore.removeAccount(harness.configuration))
        case .disable:
            var disabledConfiguration = harness.configuration
            disabledConfiguration.isEnabled = false
            XCTAssertTrue(harness.configurationStore.update(disabledConfiguration))
        }
        XCTAssertTrue(harness.refreshService.results.isEmpty, mutation.rawValue)

        await gate.release()
        let feedback = await consumption.value
        let fetchCount = await provider.recordedFetchCount()

        XCTAssertTrue(feedback.isSuccess, mutation.rawValue)
        XCTAssertTrue(feedback.message.contains("could not be refreshed"), mutation.rawValue)
        XCTAssertEqual(fetchCount, 0, mutation.rawValue)
        XCTAssertTrue(harness.refreshService.results.isEmpty, mutation.rawValue)
        XCTAssertTrue(harness.refreshService.refreshErrorsByAccountID.isEmpty, mutation.rawValue)
        XCTAssertTrue(harness.historyStore.snapshots.isEmpty, mutation.rawValue)
        XCTAssertTrue(harness.configurationStore.usageAlertActiveIDs.isEmpty, mutation.rawValue)
        XCTAssertTrue(harness.notifier.deliveredNotifications.isEmpty, mutation.rawValue)
    }

    @MainActor
    private func assertStaleCompletionIsDiscarded(
        fails: Bool,
        mutation: StaleRefreshConfigurationMutation
    ) async {
        let gate = UsageProviderGate()
        let harness = makeStaleRefreshHarness(
            providers: [
                StaleCompletionTestUsageProvider(
                    providerID: .codex,
                    gate: gate,
                    fails: fails
                ),
            ]
        )
        defer { harness.removeDefaults() }

        let accountRefresh = Task { @MainActor in
            await harness.orchestrator.refreshAccount(harness.configuration)
        }
        await gate.waitUntilBlocked()

        switch mutation {
        case .remove:
            XCTAssertTrue(harness.configurationStore.removeAccount(harness.configuration))
        case .disable:
            var disabledConfiguration = harness.configuration
            disabledConfiguration.isEnabled = false
            XCTAssertTrue(harness.configurationStore.update(disabledConfiguration))
        }
        XCTAssertTrue(harness.refreshService.results.isEmpty, mutation.rawValue)
        _ = await harness.orchestrator.refreshNow()

        await gate.release()
        let result = await accountRefresh.value

        XCTAssertNil(result, mutation.rawValue)
        XCTAssertTrue(harness.refreshService.results.isEmpty, mutation.rawValue)
        XCTAssertTrue(harness.refreshService.refreshErrorsByAccountID.isEmpty, mutation.rawValue)
        XCTAssertNil(harness.refreshService.lastRefreshError, mutation.rawValue)
        XCTAssertTrue(harness.refreshService.refreshingAccountIDs.isEmpty, mutation.rawValue)
        XCTAssertEqual(harness.refreshService.trackedRefreshGenerationCount, 0, mutation.rawValue)
        XCTAssertTrue(harness.historyStore.snapshots.isEmpty, mutation.rawValue)
        XCTAssertTrue(harness.configurationStore.usageAlertActiveIDs.isEmpty, mutation.rawValue)
        XCTAssertTrue(harness.notifier.deliveredNotifications.isEmpty, mutation.rawValue)
        XCTAssertTrue(harness.orchestrator.currentUsageAlertsByAccountID.isEmpty, mutation.rawValue)
    }

    @MainActor
    private func makeStaleRefreshHarness(
        providers: [any UsageProvider],
        cachedUsed: Double = 95
    ) -> StaleRefreshHarness {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let configurationStore = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: EmptySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        guard let configuration = configurationStore.addAccount(for: .codex) else {
            preconditionFailure("The explicit Pro fixture must accept an account.")
        }
        configurationStore.updateUsageAlertsEnabled(true)
        let cachedResult = makeHistoryResult(
            accountID: configuration.id,
            providerID: .codex,
            fetchedAt: Date().addingTimeInterval(-300),
            used: cachedUsed
        )
        let refreshService = UsageRefreshService(
            providers: providers,
            initialResults: [cachedResult]
        )
        let historyStore = UsageHistoryStore(defaults: defaults)
        let notifier = RecordingUsageAlertNotifier()
        let orchestrator = DashboardOrchestrator(
            refreshService: refreshService,
            configurationStore: configurationStore,
            historyStore: historyStore,
            usageAlertNotifier: notifier,
            appReviewPromptPolicy: AppReviewPromptPolicy(defaults: defaults),
            widgetSnapshotCoordinator: WidgetSnapshotCoordinator(
                refreshService: refreshService,
                configurationStore: configurationStore,
                publishSnapshot: { _, _ in },
                publishSettings: { _ in }
            ),
            watchSnapshotCoordinator: WatchSnapshotCoordinator(
                refreshService: refreshService,
                configurationStore: configurationStore,
                publishSnapshot: { _, _, _ in }
            )
        )
        return StaleRefreshHarness(
            suiteName: suiteName,
            defaults: defaults,
            configurationStore: configurationStore,
            configuration: configuration,
            refreshService: refreshService,
            historyStore: historyStore,
            notifier: notifier,
            orchestrator: orchestrator
        )
    }

    @MainActor
    func testRefreshTracksFailuresPerAccountWithoutDiscardingSuccessfulResults() async {
        let failed = ProviderAccountConfiguration(
            id: "codex.failed",
            providerID: .codex,
            accountLabel: "Failed Codex",
            authMethod: .browserSession
        )
        let successful = ProviderAccountConfiguration(
            id: "codex.successful",
            providerID: .codex,
            accountLabel: "Successful Codex",
            authMethod: .browserSession
        )
        let cachedFailedResult = ProviderUsageResult(
            accountID: failed.id,
            providerID: .codex,
            title: failed.displayName,
            plan: ProviderPlanDescriptor(
                identifier: "codex.pro",
                displayLabel: "PRO",
                accessibilityLabel: "Pro"
            ),
            subtitle: "Cached usage",
            bars: [UsageBar(label: "Usage", used: 75, limit: 100)],
            codexBankedRateLimitResets: CodexBankedRateLimitResets(
                availableCount: 2,
                canConsume: true
            ),
            fetchedAt: Date().addingTimeInterval(-300)
        )
        let service = UsageRefreshService(
            providers: [
                SelectivelyFailingUsageProvider(providerID: .codex, failedAccountID: failed.id),
            ],
            initialResults: [cachedFailedResult]
        )

        await service.refresh(configurations: [failed, successful])

        XCTAssertEqual(Set(service.results.map(\.accountID)), [failed.id, successful.id])
        let preservedFailure = service.results.first { $0.accountID == failed.id }
        XCTAssertEqual(preservedFailure?.bars, cachedFailedResult.bars)
        XCTAssertEqual(preservedFailure?.plan, cachedFailedResult.plan)
        XCTAssertEqual(preservedFailure?.codexBankedRateLimitResets, cachedFailedResult.codexBankedRateLimitResets)
        XCTAssertEqual(preservedFailure?.fetchedAt, cachedFailedResult.fetchedAt)
        XCTAssertEqual(preservedFailure?.failureMessage, "Refresh failed")
        XCTAssertEqual(preservedFailure?.hasSuccessfulRefreshHistory, true)
        XCTAssertEqual(
            preservedFailure?.subtitle,
            "Refresh failed Showing last known data."
        )
        XCTAssertEqual(service.successfulRefreshResults.map(\.accountID), [successful.id])
        XCTAssertEqual(service.refreshErrorsByAccountID[failed.id], "Refresh failed")
        XCTAssertEqual(service.incompleteRefreshAccountIDs, [failed.id])
        XCTAssertNil(service.refreshErrorsByAccountID[successful.id])
        XCTAssertTrue(service.refreshingAccountIDs.isEmpty)
        XCTAssertNotNil(service.lastRefreshError)

        let explicitFailure = await service.refresh(configuration: failed)

        XCTAssertEqual(explicitFailure?.accountID, failed.id)
        XCTAssertEqual(explicitFailure?.failureMessage, "Refresh failed")
        XCTAssertEqual(explicitFailure?.subtitle, "Refresh failed")
        XCTAssertEqual(
            service.results.first { $0.accountID == failed.id }?.bars,
            cachedFailedResult.bars
        )
    }

    @MainActor
    func testThrownRefreshFailureCreatesResultWithoutCachedUsage() async {
        let configuration = ProviderAccountConfiguration(
            id: "codex.first-failure",
            providerID: .codex,
            accountLabel: "First Failure",
            authMethod: .browserSession
        )
        let service = UsageRefreshService(providers: [
            SelectivelyFailingUsageProvider(
                providerID: .codex,
                failedAccountID: configuration.id
            ),
        ])

        await service.refresh(configurations: [configuration])

        XCTAssertEqual(service.results.first?.accountID, configuration.id)
        XCTAssertEqual(service.results.first?.title, "First Failure")
        XCTAssertEqual(service.results.first?.subtitle, "Refresh failed")
        XCTAssertEqual(service.results.first?.failureMessage, "Refresh failed")
        XCTAssertTrue(service.results.first?.bars.isEmpty == true)
        XCTAssertEqual(service.results.first?.hasSuccessfulRefreshHistory, false)
        XCTAssertEqual(service.refreshErrorsByAccountID[configuration.id], "Refresh failed")
    }

    @MainActor
    func testRefreshTreatsReturnedFailureResultAsFailureAndPreservesCache() async {
        let configuration = ProviderAccountConfiguration(
            id: "codex.returned-failure",
            providerID: .codex,
            accountLabel: "Cached Codex",
            authMethod: .browserSession
        )
        let cachedResult = makeHistoryResult(
            accountID: configuration.id,
            providerID: .codex,
            fetchedAt: Date().addingTimeInterval(-300),
            used: 75
        )
        let service = UsageRefreshService(
            providers: [ReturningFailureUsageProvider(providerID: .codex)],
            initialResults: [cachedResult]
        )

        await service.refresh(configurations: [configuration])

        XCTAssertEqual(service.results.first?.bars, cachedResult.bars)
        XCTAssertEqual(
            service.results.first?.subtitle,
            "Credential expired Showing last known data."
        )
        XCTAssertEqual(service.results.first?.failureMessage, "Credential expired")
        XCTAssertEqual(service.results.first?.fetchedAt, cachedResult.fetchedAt)
        XCTAssertEqual(service.refreshErrorsByAccountID[configuration.id], "Credential expired")
        XCTAssertTrue(service.successfulRefreshResults.isEmpty)
        XCTAssertEqual(service.incompleteRefreshAccountIDs, [configuration.id])
        XCTAssertEqual(service.lastRefreshError, "Credential expired")

        let explicitResult = await service.refresh(configuration: configuration)

        XCTAssertEqual(explicitResult?.failureMessage, "Credential expired")
        XCTAssertEqual(explicitResult?.subtitle, "Credential expired")
        XCTAssertEqual(service.results.first?.bars, cachedResult.bars)
        XCTAssertEqual(service.results.first?.failureMessage, "Credential expired")
        XCTAssertEqual(service.refreshErrorsByAccountID[configuration.id], "Credential expired")
    }

    @MainActor
    func testPartialFailureWithoutPlanPreservesCachedVerifiedPlan() async {
        let configuration = ProviderAccountConfiguration(
            id: "codex.partial-failure",
            providerID: .codex,
            accountLabel: "Cached Codex",
            authMethod: .browserSession
        )
        let cachedPlan = ProviderPlanDescriptor(
            identifier: "codex.pro",
            displayLabel: "PRO",
            accessibilityLabel: "Pro"
        )
        let cachedResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: configuration.displayName,
            plan: cachedPlan,
            subtitle: "Cached usage",
            bars: [UsageBar(label: "Cached usage", used: 75, limit: 100)],
            fetchedAt: Date().addingTimeInterval(-300)
        )
        let service = UsageRefreshService(
            providers: [ReturningPartialFailureUsageProvider(providerID: .codex)],
            initialResults: [cachedResult]
        )

        await service.refresh(configurations: [configuration])

        XCTAssertEqual(service.results.first?.plan, cachedPlan)
        XCTAssertEqual(service.results.first?.bars.first?.label, "Latest usage")
        XCTAssertEqual(service.results.first?.failureMessage, "Partial refresh failed")
    }

    @MainActor
    func testLiveRefreshIncludesOpenRouterProvider() async throws {
        let secretStore = MemorySecretStore()
        var openRouter = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)
        openRouter.accountLabel = "OpenRouter API"
        try secretStore.saveSecret("sk-or-test", account: ProviderConfigurationStore.keychainAccount(for: openRouter))

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [DashboardAndSettingsMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = UsageRefreshService(providers: [
            OpenRouterUsageProvider(secretStore: secretStore, session: session)
        ])

        DashboardAndSettingsMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/credits")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"data":{"total_credits":10,"total_usage":2.5}}"#.utf8)
            )
        }
        defer {
            DashboardAndSettingsMockURLProtocol.handler = nil
        }

        await service.refresh(configurations: [openRouter])

        let result = try XCTUnwrap(service.results.first)
        XCTAssertEqual(result.providerID, .openRouter)
        XCTAssertEqual(result.title, "OpenRouter API")
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 7.5, accuracy: 0.0001)
    }

    @MainActor
    func testSingleAccountRefreshUpdatesOnlyRequestedProvider() async throws {
        let secretStore = MemorySecretStore()
        var openCode = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        openCode.accountLabel = "OpenCode ZEN"
        openCode.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret(
            "opencode-dashboard-token",
            account: ProviderConfigurationStore.keychainAccount(for: openCode)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [DashboardAndSettingsMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = UsageRefreshService(providers: [
            OpenCodeZenUsageProvider(secretStore: secretStore, session: session),
            HangingUsageProvider(providerID: .openRouter),
        ])

        DashboardAndSettingsMockURLProtocol.handler = { request in
            XCTAssertTrue(["/workspace/wrk_test/billing", "/workspace/wrk_test/go"].contains(request.url?.path))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=opencode-dashboard-token")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )!,
                request.url?.path.hasSuffix("/go") == true
                    ? Data(#"<html><div data-slot="promo-description">Subscribe to Go</div></html>"#.utf8)
                    : Data(#"<html>balance:1225000000</html>"#.utf8)
            )
        }
        defer {
            DashboardAndSettingsMockURLProtocol.handler = nil
        }

        let refreshedResult = await service.refresh(configuration: openCode)
        let result = try XCTUnwrap(refreshedResult)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.title, "OpenCode Zen")
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 12.25, accuracy: 0.0001)
        XCTAssertEqual(service.results.map(\.accountID), [openCode.id])
    }

    @MainActor
    func testWidgetSnapshotCoordinatorPublishesStoreAndRefreshChangesReactively() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: EmptySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .codex))
        let service = UsageRefreshService(providers: [
            GatedUsageProvider(
                providerID: .codex,
                blockedAccountID: "never",
                gate: UsageProviderGate()
            ),
        ])
        var publishedAccountIDs: [[String]] = []
        var settingsPublishCount = 0
        let coordinator = WidgetSnapshotCoordinator(
            refreshService: service,
            configurationStore: store,
            publishSnapshot: { results, _ in
                publishedAccountIDs.append(results.map(\.accountID))
            },
            publishSettings: { _ in
                settingsPublishCount += 1
            }
        )

        await service.refresh(configurations: [configuration])
        await Task.yield()
        XCTAssertEqual(publishedAccountIDs.last, [configuration.id])

        let snapshotCount = publishedAccountIDs.count
        store.updateDashboardCardOrder([configuration.id])
        await Task.yield()
        XCTAssertEqual(publishedAccountIDs.count, snapshotCount + 1)

        let thresholdSnapshotCount = publishedAccountIDs.count
        store.updateUsageAlertWarningThreshold(0.65)
        await Task.yield()
        XCTAssertEqual(publishedAccountIDs.count, thresholdSnapshotCount + 1)

        store.updateWidgetRefreshInterval(.oneHour)
        await Task.yield()
        XCTAssertEqual(settingsPublishCount, 1)
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testWatchSnapshotContainsPresentationOnlyMetricsAndEveryStyle() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: MemorySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .codex))
        XCTAssertTrue(store.saveSecret("watch-must-never-see-this-secret", for: configuration))
        store.updateAutoRefreshInterval(.fiveMinutes)

        let bars = MetricVisualizationStyle.allCases.enumerated().map { index, style in
            let bar = UsageBar(
                stableKey: "metric-\(index)",
                label: style.displayName,
                used: Double(index + 1),
                limit: 10,
                resetDescription: "Resets later"
            )
            store.updateVisualizationStyle(
                style,
                accountID: configuration.id,
                metricID: bar.metricIdentifier(providerID: .codex, index: index)
            )
            return bar
        }
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: "Codex",
            plan: ProviderPlanDescriptor(
                identifier: "codex.pro",
                displayLabel: "PRO",
                accessibilityLabel: "Pro"
            ),
            subtitle: "Pro",
            bars: bars,
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let snapshot = WatchSnapshotPublisher.makeSnapshot(
            results: [result],
            configurationStore: store,
            now: result.fetchedAt
        )

        XCTAssertEqual(snapshot.refreshIntervalSeconds, 300)
        XCTAssertEqual(
            snapshot.accounts.map(\.id),
            [
                WatchSnapshotPublisher.snapshotAccountID(
                    providerID: .codex,
                    configurationID: configuration.id
                ),
            ]
        )
        XCTAssertEqual(snapshot.accounts[0].providerName, ProviderID.codex.displayName)
        XCTAssertEqual(snapshot.accounts[0].accountLabel, configuration.accountLabel)
        XCTAssertEqual(snapshot.accounts[0].planIdentifier, "codex.pro")
        XCTAssertEqual(snapshot.accounts[0].planDisplayLabel, "PRO")
        XCTAssertEqual(snapshot.accounts[0].planAccessibilityLabel, "Pro")
        XCTAssertNotEqual(snapshot.accounts[0].providerName, snapshot.accounts[0].accountLabel)
        XCTAssertEqual(
            snapshot.accounts[0].metrics.map(\.visualizationStyle),
            WatchMetricVisualizationStyle.allCases.filter { $0 != .statusText }
        )
        XCTAssertEqual(snapshot.accounts[0].metrics.map(\.usedFraction), [0.1, 0.2, 0.3, 0.4, 0.5, 0.6])
        let encodedText = try XCTUnwrap(String(data: snapshot.encoded(), encoding: .utf8))
        XCTAssertFalse(encodedText.contains("watch-must-never-see-this-secret"))
        XCTAssertFalse(encodedText.contains(configuration.id))
        XCTAssertFalse(encodedText.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(encodedText.localizedCaseInsensitiveContains("cookie"))

        XCTAssertTrue(store.removeAccount(configuration))
        let afterRemoval = WatchSnapshotPublisher.makeSnapshot(
            results: [result],
            configurationStore: store,
            now: result.fetchedAt
        )
        XCTAssertTrue(afterRemoval.accounts.isEmpty)
    }

    @MainActor
    func testWatchSnapshotPublishesZeroLimitBarsAsFractionlessValues() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: MemorySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .copilot))
        XCTAssertTrue(store.saveSecret("secret", for: configuration))
        let fetchedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .copilot,
            title: "GitHub Copilot",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    stableKey: "ai-credits",
                    label: "AI credits used (1,500)",
                    used: 1_500,
                    limit: 0,
                    fractionlessUsageText: "1,500"
                ),
                UsageBar(
                    stableKey: "premium-interactions",
                    label: "Premium interactions - unlimited",
                    used: 0,
                    limit: 0,
                    fractionlessUsageText: "Unlimited"
                ),
            ],
            fetchedAt: fetchedAt
        )

        let metrics = try XCTUnwrap(
            WatchSnapshotPublisher.makeSnapshot(
                results: [result],
                configurationStore: store,
                now: fetchedAt
            ).accounts.first?.metrics
        )

        XCTAssertEqual(metrics.map(\.exactValue), ["1,500", "Unlimited"])
        XCTAssertEqual(metrics.map(\.usedFraction), [nil, nil])
        XCTAssertEqual(metrics.map(\.remainingFraction), [nil, nil])
    }

    @MainActor
    func testWatchSnapshotAccountIDsRemainStableAcrossDashboardReordering() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: MemorySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        let first = try XCTUnwrap(store.addAccount(for: .codex))
        let second = try XCTUnwrap(store.addAccount(for: .codex))
        XCTAssertTrue(store.saveSecret("first-token", for: first))
        XCTAssertTrue(store.saveSecret("second-token", for: second))
        store.updateDashboardOrderingMode(.manual)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let results = [first, second].enumerated().map { index, configuration in
            ProviderUsageResult(
                accountID: configuration.id,
                providerID: .codex,
                title: "Codex",
                subtitle: "Pro",
                bars: [
                    UsageBar(
                        stableKey: "window",
                        label: "Usage",
                        used: Double(index + 1),
                        limit: 10
                    ),
                ],
                fetchedAt: now
            )
        }
        let firstID = WatchSnapshotPublisher.snapshotAccountID(
            providerID: .codex,
            configurationID: first.id
        )
        let secondID = WatchSnapshotPublisher.snapshotAccountID(
            providerID: .codex,
            configurationID: second.id
        )

        store.updateDashboardCardOrder([first.id, second.id])
        let original = WatchSnapshotPublisher.makeSnapshot(
            results: results,
            configurationStore: store,
            now: now
        )
        store.updateDashboardCardOrder([second.id, first.id])
        let reordered = WatchSnapshotPublisher.makeSnapshot(
            results: results,
            configurationStore: store,
            now: now
        )

        XCTAssertEqual(original.accounts.map(\.id), [firstID, secondID])
        XCTAssertEqual(reordered.accounts.map(\.id), [secondID, firstID])
        let encodedText = try XCTUnwrap(String(data: original.encoded(), encoding: .utf8))
        XCTAssertFalse(encodedText.contains(first.id))
        XCTAssertFalse(encodedText.contains(second.id))
    }

    @MainActor
    func testDiscoveredCodexMetricsPreserveCustomizationWhenOfferedSetChanges() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let initialPayload = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 10,
              "reset_at": 1893456000,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 20,
              "reset_at": 1894060800,
              "limit_window_seconds": 604800
            }
          },
          "additional_rate_limits": [{
            "metered_feature": "codex_bengalfox",
            "limit_name": "GPT-5.3-Codex-Spark",
            "rate_limit": {
              "primary_window": {
                "used_percent": 30,
                "reset_at": 1893456000,
                "limit_window_seconds": 18000
              },
              "secondary_window": {
                "used_percent": 40,
                "reset_at": 1894060800,
                "limit_window_seconds": 604800
              }
            }
          }]
        }
        """
        let updatedPayload = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 21,
              "reset_at": 1894060800,
              "limit_window_seconds": 604800
            }
          },
          "additional_rate_limits": [
            {
              "metered_feature": "codex_future",
              "limit_name": "Future model",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 5,
                  "reset_at": 1893456000,
                  "limit_window_seconds": 7200
                }
              }
            },
            {
              "metered_feature": "codex_bengalfox",
              "limit_name": "GPT-5.3-Codex-Spark",
              "rate_limit": {
                "secondary_window": {
                  "used_percent": 41,
                  "reset_at": 1894060800,
                  "limit_window_seconds": 604800
                },
                "primary_window": {
                  "used_percent": 31,
                  "reset_at": 1893456000,
                  "limit_window_seconds": 18000
                }
              }
            }
          ]
        }
        """
        let initial = try XCTUnwrap(CodexUsageParser.parse(Data(initialPayload.utf8)))
        let updated = try XCTUnwrap(CodexUsageParser.parse(Data(updatedPayload.utf8)))
        let initialMetricIDs = initial.availableMetrics.map(\.id)
        let updatedMetricIDs = updated.availableMetrics.map(\.id)
        let accountID = "codex.dynamic"
        let generalFiveHourID = "codex.window-18000"
        let generalWeeklyID = "codex.window-604800"
        let sparkFiveHourID = "codex.bucket-codex_5Fbengalfox.window-18000"
        let sparkWeeklyID = "codex.bucket-codex_5Fbengalfox.window-604800"
        let futureID = "codex.bucket-codex_5Ffuture.window-7200"
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: EmptySecretStore()
        )

        XCTAssertEqual(
            initialMetricIDs,
            [generalFiveHourID, generalWeeklyID, sparkFiveHourID, sparkWeeklyID]
        )
        _ = store.reconcileMetricLayout(
            accountID: accountID,
            availableMetricIDs: initialMetricIDs
        )
        store.updateMetricOrder(
            [sparkWeeklyID, generalFiveHourID, sparkFiveHourID, generalWeeklyID],
            accountID: accountID
        )
        store.updateMetricVisibility(false, accountID: accountID, metricID: sparkFiveHourID)

        _ = store.reconcileMetricLayout(
            accountID: accountID,
            availableMetricIDs: updatedMetricIDs
        )

        XCTAssertEqual(
            store.metricOrder(accountID: accountID, availableMetricIDs: updatedMetricIDs),
            [sparkWeeklyID, generalFiveHourID, sparkFiveHourID, generalWeeklyID, futureID]
        )
        XCTAssertFalse(store.isMetricVisible(accountID: accountID, metricID: sparkFiveHourID))
        XCTAssertTrue(store.isMetricVisible(accountID: accountID, metricID: futureID))
        XCTAssertTrue(
            try XCTUnwrap(store.metricLayouts[accountID]?.preferences[futureID])
                .isNewlyDiscovered
        )

        let reloaded = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: EmptySecretStore()
        )
        XCTAssertFalse(reloaded.isMetricVisible(accountID: accountID, metricID: sparkFiveHourID))
        XCTAssertEqual(
            reloaded.metricOrder(accountID: accountID, availableMetricIDs: updatedMetricIDs),
            [sparkWeeklyID, generalFiveHourID, sparkFiveHourID, generalWeeklyID, futureID]
        )
    }

    @MainActor
    func testWatchSnapshotFiltersHiddenMetricsAndRestoresThemWithSavedStyles() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer {
            defaults.removePersistentDomain(forName: #function)
        }
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: MemorySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .claude))
        let session = UsageBar(
            stableKey: "session",
            label: "Current session",
            used: 25,
            limit: 100
        )
        let weekly = UsageBar(
            stableKey: "weekly",
            label: "Weekly",
            used: 50,
            limit: 100
        )
        let spent = ProviderMonetaryMetric(
            kind: .spent,
            label: "Usage credits spent",
            minorUnits: 1_250,
            currencyCode: "USD",
            decimalPlaces: 2
        )
        let sessionID = session.metricIdentifier(providerID: .claude, index: 0)
        let spentID = spent.metricIdentifier(providerID: .claude)
        store.updateVisualizationStyle(
            .circularRing,
            accountID: configuration.id,
            metricID: sessionID
        )
        store.updateMetricVisibility(false, accountID: configuration.id, metricID: sessionID)
        store.updateMetricVisibility(false, accountID: configuration.id, metricID: spentID)
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .claude,
            title: "Claude",
            subtitle: "Pro",
            bars: [session, weekly],
            creditsRemaining: 42,
            monetaryMetrics: [spent],
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let hiddenSnapshot = WatchSnapshotPublisher.makeSnapshot(
            results: [result],
            configurationStore: store,
            now: result.fetchedAt
        )
        XCTAssertEqual(
            hiddenSnapshot.accounts[0].metrics.map(\.id),
            ["claude.weekly", "claude.credits-remaining"]
        )

        store.updateMetricVisibility(true, accountID: configuration.id, metricID: sessionID)
        let restoredSnapshot = WatchSnapshotPublisher.makeSnapshot(
            results: [result],
            configurationStore: store,
            now: result.fetchedAt
        )
        XCTAssertEqual(
            restoredSnapshot.accounts[0].metrics.map(\.id),
            [sessionID, "claude.weekly", "claude.credits-remaining"]
        )
        XCTAssertEqual(restoredSnapshot.accounts[0].metrics[0].visualizationStyle, .circularRing)

        store.updateMetricVisibility(true, accountID: configuration.id, metricID: spentID)
        let allVisibleSnapshot = WatchSnapshotPublisher.makeSnapshot(
            results: [result],
            configurationStore: store,
            now: result.fetchedAt
        )
        XCTAssertEqual(
            allVisibleSnapshot.accounts[0].metrics.map(\.id),
            [sessionID, "claude.weekly", "claude.credits-remaining", spentID]
        )
    }

    @MainActor
    func testWatchSnapshotUsesSavedIPhoneOrderAndTriStateVisibilityWithoutTileWidths() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer {
            defaults.removePersistentDomain(forName: #function)
        }
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: MemorySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .claude))
        let session = UsageBar(
            stableKey: "session",
            label: "Current session",
            used: 25,
            limit: 100
        )
        let weekly = UsageBar(
            stableKey: "weekly",
            label: "Weekly",
            used: 50,
            limit: 100
        )
        let spent = ProviderMonetaryMetric(
            kind: .spent,
            label: "Usage credits spent",
            minorUnits: 1_250,
            currencyCode: "USD",
            decimalPlaces: 2
        )
        let sessionID = session.metricIdentifier(providerID: .claude, index: 0)
        let weeklyID = weekly.metricIdentifier(providerID: .claude, index: 1)
        let spentID = spent.metricIdentifier(providerID: .claude)
        let creditsID = "claude.credits-remaining"
        _ = store.reconcileMetricLayout(
            accountID: configuration.id,
            availableMetricIDs: [sessionID, weeklyID, creditsID, spentID]
        )
        store.updateMetricOrder(
            [spentID, weeklyID, sessionID, creditsID],
            accountID: configuration.id
        )
        store.updateMetricWidth(.half, accountID: configuration.id, metricID: sessionID)
        store.updateMetricWidth(.full, accountID: configuration.id, metricID: creditsID)
        store.updateMetricVisibility(false, accountID: configuration.id, metricID: spentID)
        store.updateMetricVisibility(false, accountID: configuration.id, metricID: sessionID)
        store.updateWatchMetricVisibility(.hide, accountID: configuration.id, metricID: weeklyID)
        store.updateWatchMetricVisibility(.show, accountID: configuration.id, metricID: sessionID)

        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .claude,
            title: "Claude",
            subtitle: "Pro",
            bars: [session, weekly],
            creditsRemaining: 42,
            monetaryMetrics: [spent],
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let snapshot = WatchSnapshotPublisher.makeSnapshot(
            results: [result],
            configurationStore: store,
            now: result.fetchedAt
        )

        XCTAssertEqual(snapshot.accounts[0].metrics.map(\.id), [sessionID, creditsID])
        XCTAssertEqual(
            store.watchVisibilityPolicy(accountID: configuration.id, metricID: spentID),
            .inherit
        )
        XCTAssertEqual(
            store.watchVisibilityPolicy(accountID: configuration.id, metricID: sessionID),
            .show
        )
    }

    @MainActor
    func testWatchSnapshotOmitsUnsupportedProviderPlanMetadata() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer {
            defaults.removePersistentDomain(forName: #function)
        }
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: MemorySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .openRouter))
        XCTAssertTrue(store.saveSecret("openrouter-test-key", for: configuration))
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openRouter,
            title: "OpenRouter",
            plan: ProviderPlanDescriptor(
                identifier: "openrouter.business",
                displayLabel: "BUSINESS",
                accessibilityLabel: "Business"
            ),
            subtitle: "Balance",
            bars: [UsageBar(label: "Usage", used: 1, limit: 4)],
            fetchedAt: Date()
        )

        let snapshot = WatchSnapshotPublisher.makeSnapshot(
            results: [result],
            configurationStore: store,
            now: result.fetchedAt
        )

        XCTAssertNil(snapshot.accounts.first?.planIdentifier)
        XCTAssertNil(snapshot.accounts.first?.planDisplayLabel)
        XCTAssertNil(snapshot.accounts.first?.planAccessibilityLabel)
    }

    func testWatchSnapshotDeduplicatorIgnoresGenerationTimeAndSupportsForcedReassertion() throws {
        let first = WatchDashboardSnapshot(
            generatedAt: Date(timeIntervalSince1970: 2_000_000_000),
            refreshIntervalSeconds: 300,
            accounts: []
        )
        let sameSemanticState = WatchDashboardSnapshot(
            generatedAt: first.generatedAt.addingTimeInterval(60),
            refreshIntervalSeconds: 300,
            accounts: []
        )
        var deduplicator = WatchSnapshotDeduplicator()

        XCTAssertTrue(try deduplicator.shouldSend(first, force: false))
        try deduplicator.recordSent(first)
        XCTAssertFalse(try deduplicator.shouldSend(sameSemanticState, force: false))
        XCTAssertTrue(try deduplicator.shouldSend(sameSemanticState, force: true))

        let changed = WatchDashboardSnapshot(
            generatedAt: sameSemanticState.generatedAt,
            refreshIntervalSeconds: 60,
            accounts: []
        )
        XCTAssertTrue(try deduplicator.shouldSend(changed, force: false))
    }

    @MainActor
    func testWatchSnapshotUsesPreservedBarsFetchTimeForFreshness() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: MemorySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .claude))
        XCTAssertTrue(store.saveSecret("secret", for: configuration))
        let barsFetchedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let refreshedAt = barsFetchedAt.addingTimeInterval(30 * 60)
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .claude,
            title: "Claude",
            subtitle: "Fresh balance with preserved usage",
            bars: [UsageBar(stableKey: "window", label: "Usage", used: 4, limit: 10)],
            barsFetchedAt: barsFetchedAt,
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .balance,
                    label: "Balance",
                    minorUnits: 2_000,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
            ],
            fetchedAt: refreshedAt
        )

        let snapshot = WatchSnapshotPublisher.makeSnapshot(
            results: [result],
            configurationStore: store,
            now: refreshedAt
        )

        let account = try XCTUnwrap(snapshot.accounts.first)
        XCTAssertEqual(account.fetchedAt, barsFetchedAt)
        XCTAssertEqual(
            try XCTUnwrap(account.metrics.first { $0.label == "Usage" }).fetchedAt,
            barsFetchedAt
        )
        XCTAssertEqual(
            try XCTUnwrap(account.metrics.first { $0.label == "Balance" }).fetchedAt,
            refreshedAt
        )
    }

    @MainActor
    func testWatchSnapshotIncludesIdleSessionDescription() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: MemorySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .claude))
        XCTAssertTrue(store.saveSecret("secret", for: configuration))
        let fetchedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .claude,
            title: "Claude",
            subtitle: "Pro",
            bars: [
                UsageBar(
                    stableKey: "session",
                    label: "Current session",
                    used: 0,
                    limit: 100,
                    projectionDescriptionOverride: "Starts when a message is sent"
                ),
            ],
            fetchedAt: fetchedAt
        )

        let snapshot = WatchSnapshotPublisher.makeSnapshot(
            results: [result],
            configurationStore: store,
            now: fetchedAt
        )

        XCTAssertEqual(
            try XCTUnwrap(snapshot.accounts.first?.metrics.first).resetText,
            "Starts when a message is sent"
        )

        let resetResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .claude,
            title: "Claude",
            subtitle: "Pro",
            bars: [
                UsageBar(
                    stableKey: "session",
                    label: "Current session",
                    used: 13,
                    limit: 100,
                    resetsAt: fetchedAt.addingTimeInterval(60 * 60),
                    resetDisplayStyle: .relativeWithLocalTime,
                    projectionDescriptionOverride: "Projected text"
                ),
            ],
            fetchedAt: fetchedAt
        )
        let resetSnapshot = WatchSnapshotPublisher.makeSnapshot(
            results: [resetResult],
            configurationStore: store,
            now: fetchedAt
        )
        let resetMetric = try XCTUnwrap(resetSnapshot.accounts.first?.metrics.first)
        let resetText = try XCTUnwrap(resetMetric.resetText)
        XCTAssertNotEqual(resetText, "Projected text")
        XCTAssertEqual(resetMetric.resetsAt, fetchedAt.addingTimeInterval(60 * 60))
        XCTAssertEqual(resetMetric.resetDisplayStyle, .relativeWithLocalTime)
        XCTAssertEqual(resetMetric.fetchedAt, fetchedAt)

        let staleResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .claude,
            title: "Claude",
            subtitle: "Pro",
            bars: [
                UsageBar(
                    stableKey: "session",
                    label: "Current session",
                    used: 0,
                    limit: 100,
                    projectionDescriptionOverride: "Stale projected text"
                ),
            ],
            barsFetchedAt: fetchedAt.addingTimeInterval(-60),
            fetchedAt: fetchedAt
        )
        let staleSnapshot = WatchSnapshotPublisher.makeSnapshot(
            results: [staleResult],
            configurationStore: store,
            now: fetchedAt
        )
        XCTAssertNil(staleSnapshot.accounts.first?.metrics.first?.resetText)
    }

    @MainActor
    func testWatchSnapshotOmitsCachedCreditsFromPartialRefresh() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: MemorySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .openCodeZen))
        XCTAssertTrue(store.saveSecret("secret", for: configuration))
        let fetchedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: "OpenCode Go",
            subtitle: "Fresh Go usage with cached Zen balance",
            bars: [UsageBar(stableKey: "go.weekly", label: "Weekly usage limit", used: 40, limit: 100)],
            creditsRemaining: 3,
            creditsFetchedAt: fetchedAt.addingTimeInterval(-60),
            fetchedAt: fetchedAt
        )

        let snapshot = WatchSnapshotPublisher.makeSnapshot(
            results: [result],
            configurationStore: store,
            now: fetchedAt
        )

        let account = try XCTUnwrap(snapshot.accounts.first)
        XCTAssertEqual(account.providerName, "OpenCode Go")
        XCTAssertEqual(account.accountLabel, "Fresh Go usage with cached Zen balance")
        let metrics = account.metrics
        XCTAssertEqual(metrics.map(\.id), ["openCodeZen.go.weekly"])
        XCTAssertEqual(metrics.map(\.exactValue), ["40%"])
    }

    @MainActor
    func testWatchSnapshotCoordinatorActivatesAndCoalescesRapidChanges() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: MemorySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .codex))
        XCTAssertTrue(store.saveSecret("secret", for: configuration))
        let bar = UsageBar(stableKey: "window", label: "Usage", used: 4, limit: 10)
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: "Codex",
            subtitle: "Pro",
            bars: [bar],
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let service = UsageRefreshService(providers: [], initialResults: [result])
        let sender = RecordingWatchSnapshotSender()
        let coordinator = WatchSnapshotCoordinator(
            refreshService: service,
            configurationStore: store,
            sender: sender,
            coalescingDelay: .milliseconds(5)
        )

        XCTAssertEqual(sender.activationCount, 0)
        coordinator.start()
        coordinator.start()
        XCTAssertEqual(sender.activationCount, 1)
        sender.completeActivation()
        XCTAssertEqual(sender.publishedForces, [true])

        let snapshotPublished = expectation(description: "Coalesced Watch snapshot published")
        sender.onPublish = {
            snapshotPublished.fulfill()
        }
        let metricID = bar.metricIdentifier(providerID: .codex, index: 0)
        store.updateVisualizationStyle(.segmentedBar, accountID: configuration.id, metricID: metricID)
        store.updateVisualizationStyle(.circularRing, accountID: configuration.id, metricID: metricID)
        store.updateVisualizationStyle(.largeNumeric, accountID: configuration.id, metricID: metricID)
        await fulfillment(of: [snapshotPublished], timeout: 1)

        XCTAssertEqual(sender.publishedForces, [true, false])
        XCTAssertEqual(
            sender.snapshots.last?.accounts[0].metrics[0].visualizationStyle,
            .largeNumeric
        )

        let thresholdsPublished = expectation(description: "Watch thresholds republished")
        sender.onPublish = {
            thresholdsPublished.fulfill()
        }
        store.updateUsageAlertWarningThreshold(0.65)
        await fulfillment(of: [thresholdsPublished], timeout: 1)

        XCTAssertEqual(sender.publishedForces, [true, false, false])
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testTransientWatchSnapshotCoordinatorDoesNotReplaceRetainedCallback() {
        let retainedDefaults = UserDefaults(suiteName: "\(#function).retained")!
        retainedDefaults.removePersistentDomain(forName: "\(#function).retained")
        let retainedStore = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: retainedDefaults,
            secretStore: MemorySecretStore(),
            widgetSnapshotDefaults: retainedDefaults
        )
        let retainedService = UsageRefreshService(providers: [], initialResults: [])
        let sender = RecordingWatchSnapshotSender()
        let retainedCoordinator = WatchSnapshotCoordinator(
            refreshService: retainedService,
            configurationStore: retainedStore,
            sender: sender
        )
        retainedCoordinator.start()

        let transientDefaults = UserDefaults(suiteName: "\(#function).transient")!
        transientDefaults.removePersistentDomain(forName: "\(#function).transient")
        let transientStore = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: transientDefaults,
            secretStore: MemorySecretStore(),
            widgetSnapshotDefaults: transientDefaults
        )
        let transientService = UsageRefreshService(providers: [], initialResults: [])
        do {
            let transientCoordinator = WatchSnapshotCoordinator(
                refreshService: transientService,
                configurationStore: transientStore,
                sender: sender
            )
            withExtendedLifetime(transientCoordinator) {}
        }

        XCTAssertEqual(sender.activationCount, 1)
        sender.completeActivation()
        XCTAssertEqual(sender.publishedForces, [true])
        withExtendedLifetime(retainedCoordinator) {}
    }

    @MainActor
    func testWatchSnapshotCoordinatorPreservesLastWatchDataWhileInitialRefreshIsPending() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: MemorySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .codex))
        XCTAssertTrue(store.saveSecret("secret", for: configuration))
        let service = UsageRefreshService(providers: [], initialResults: [])
        let sender = RecordingWatchSnapshotSender()
        let coordinator = WatchSnapshotCoordinator(
            refreshService: service,
            configurationStore: store,
            sender: sender,
            coalescingDelay: .milliseconds(5)
        )

        coordinator.start()
        sender.completeActivation()
        XCTAssertTrue(sender.snapshots.isEmpty)

        let snapshotPublished = expectation(description: "Empty Watch snapshot published")
        sender.onPublish = {
            snapshotPublished.fulfill()
        }
        XCTAssertTrue(store.removeAccount(configuration))
        await fulfillment(of: [snapshotPublished], timeout: 1)
        XCTAssertEqual(sender.snapshots.count, 1)
        XCTAssertTrue(sender.snapshots[0].accounts.isEmpty)
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testPhoneWatchConnectivityCoordinatorHandlesSnapshotRequestsAndWatchStateChanges() throws {
        let sender = PhoneWatchConnectivityCoordinator(session: nil)
        var snapshotNeededCount = 0
        sender.activate { _ in
            snapshotNeededCount += 1
        }

        XCTAssertFalse(sender.handleMessage(["unrelated": true]))
        XCTAssertEqual(snapshotNeededCount, 0)

        XCTAssertFalse(
            sender.handleMessage([
                WatchDashboardSnapshot.snapshotRequestKey: "not-a-boolean",
            ])
        )
        XCTAssertEqual(snapshotNeededCount, 0)

        XCTAssertTrue(sender.handleMessage(WatchDashboardSnapshot.snapshotRequestMessage))
        XCTAssertEqual(snapshotNeededCount, 1)

        var unavailableResponse: WatchDashboardSnapshotResponse?
        XCTAssertTrue(
            sender.handleMessage(
                WatchDashboardSnapshot.snapshotRequestMessage,
                replyHandler: {
                    unavailableResponse = WatchDashboardSnapshotResponse($0)
                }
            )
        )
        XCTAssertEqual(unavailableResponse, .unavailable)
        XCTAssertEqual(snapshotNeededCount, 2)

        let snapshot = WatchDashboardSnapshot(
            generatedAt: Date(timeIntervalSince1970: 2_000_000_000),
            refreshIntervalSeconds: 300,
            accounts: []
        )
        XCTAssertFalse(sender.publish(snapshot, force: true))
        var response: WatchDashboardSnapshotResponse?
        XCTAssertTrue(
            sender.handleMessage(
                WatchDashboardSnapshot.snapshotRequestMessage,
                replyHandler: {
                    response = WatchDashboardSnapshotResponse($0)
                }
            )
        )
        XCTAssertEqual(try XCTUnwrap(response).decode(), snapshot)
        XCTAssertEqual(snapshotNeededCount, 3)

        XCTAssertFalse(sender.handleUserInfo(["unrelated": true]))
        XCTAssertTrue(
            sender.handleUserInfo(WatchDashboardSnapshot.snapshotRequestMessage)
        )
        XCTAssertEqual(snapshotNeededCount, 4)

        sender.watchStateDidChange()
        XCTAssertEqual(snapshotNeededCount, 4)
    }

    @MainActor
    func testProviderSettingsViewModelDebouncesTextChangesAndFlushesOnDismissal() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        let configuration = try XCTUnwrap(store.addAccount(for: .openRouter))
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id
        )

        viewModel.binding(for: \.accountLabel, persistence: .debounced).wrappedValue = "Team Router"
        viewModel.binding(for: \.showsHistory).wrappedValue = false

        XCTAssertEqual(viewModel.configuration.accountLabel, "Team Router")
        XCTAssertFalse(viewModel.configuration.showsHistory)
        XCTAssertEqual(store.configuration(accountID: configuration.id)?.accountLabel, "Team Router")
        XCTAssertEqual(store.configuration(accountID: configuration.id)?.showsHistory, false)

        viewModel.binding(for: \.accountLabel, persistence: .debounced).wrappedValue = "Final Router"
        XCTAssertEqual(store.configuration(accountID: configuration.id)?.accountLabel, "Team Router")
        viewModel.flushPendingChanges()

        XCTAssertEqual(viewModel.configuration.accountLabel, "Final Router")
        XCTAssertEqual(store.configuration(accountID: configuration.id)?.accountLabel, "Final Router")
    }

    @MainActor
    func testAccountSettingsToggleThreeCodexMetricsIndependentlyAndPersist() async throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: EmptySecretStore()
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .codex))
        let otherConfiguration = try XCTUnwrap(store.addAccount(for: .codex))
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: "Codex",
            subtitle: "Pro",
            bars: [
                UsageBar(
                    stableKey: "window-604800",
                    label: "Weekly limit",
                    used: 20,
                    limit: 100
                ),
                UsageBar(
                    stableKey: "bucket-spark.window-18000",
                    label: "GPT-5.3-Codex-Spark · 5-hour limit",
                    used: 30,
                    limit: 100
                ),
                UsageBar(
                    stableKey: "bucket-spark.window-604800",
                    label: "GPT-5.3-Codex-Spark · Weekly limit",
                    used: 40,
                    limit: 100
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let metricIDs = result.availableMetrics.map(\.id)
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            initialUsageResult: result
        )

        await viewModel.prepare()

        XCTAssertEqual(
            viewModel.availableMetrics.map(\.label),
            [
                "Weekly limit",
                "GPT-5.3-Codex-Spark · 5-hour limit",
                "GPT-5.3-Codex-Spark · Weekly limit",
                "Credits pool",
            ]
        )
        XCTAssertFalse(viewModel.isMetricVisible("codex.credits-pool"))
        for metricID in metricIDs {
            viewModel.setMetricVisibility(false, metricID: metricID)
            XCTAssertFalse(viewModel.isMetricVisible(metricID))
            XCTAssertTrue(
                metricIDs.filter { $0 != metricID }.allSatisfy(viewModel.isMetricVisible)
            )
            viewModel.setMetricVisibility(true, metricID: metricID)
        }

        viewModel.setMetricVisibility(false, metricID: metricIDs[1])
        _ = store.reconcileMetricLayout(
            accountID: otherConfiguration.id,
            availableMetricIDs: metricIDs
        )
        XCTAssertTrue(
            metricIDs.allSatisfy {
                store.isMetricVisible(accountID: otherConfiguration.id, metricID: $0)
            }
        )

        let reloadedStore = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: EmptySecretStore()
        )
        let reloadedViewModel = ProviderSettingsViewModel(
            configurationStore: reloadedStore,
            accountID: configuration.id,
            initialUsageResult: result
        )
        await reloadedViewModel.prepare()

        XCTAssertTrue(reloadedViewModel.isMetricVisible(metricIDs[0]))
        XCTAssertFalse(reloadedViewModel.isMetricVisible(metricIDs[1]))
        XCTAssertTrue(reloadedViewModel.isMetricVisible(metricIDs[2]))

        let synchronizedResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: "Codex",
            subtitle: "Updated metrics",
            bars: [result.bars[2]],
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_100)
        )
        reloadedViewModel.synchronizeUsageResult(synchronizedResult)
        XCTAssertEqual(reloadedViewModel.availableMetrics.map(\.label), ["GPT-5.3-Codex-Spark · Weekly limit", "Credits pool"])

        reloadedViewModel.synchronizeUsageResult(nil)
        XCTAssertEqual(reloadedViewModel.availableMetrics.map(\.label), ["Credits pool"])
        XCTAssertFalse(reloadedViewModel.isMetricVisible("codex.credits-pool"))
    }

    @MainActor
    func testCursorModelBucketPreferencesPersistIndependentlyThroughTemporaryAbsence() async throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        let configuration = try XCTUnwrap(store.addAccount(for: .cursor))
        let otherConfiguration = try XCTUnwrap(store.addAccount(for: .cursor))
        let cursorModelsID = CursorUsageIdentity.cursorModelsMetricID
        let otherModelsID = CursorUsageIdentity.otherModelsMetricID
        let grokBotID = "cursor.grok-bot-weekly"
        let fullResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Cursor plan usage",
            bars: [
                UsageBar(
                    stableKey: CursorUsageIdentity.cursorModelsStableKey,
                    label: "Cursor Models",
                    used: 20,
                    limit: 100
                ),
                UsageBar(
                    stableKey: CursorUsageIdentity.otherModelsStableKey,
                    label: "Other Models",
                    used: 40,
                    limit: 100
                ),
                UsageBar(
                    stableKey: "grok-bot-weekly",
                    label: "Grok Bot weekly",
                    used: 10,
                    limit: 100
                ),
            ],
            fetchedAt: Date()
        )
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            initialUsageResult: fullResult
        )

        await viewModel.prepare()

        XCTAssertEqual(
            viewModel.availableMetrics.map(\.id),
            [cursorModelsID, otherModelsID, grokBotID, "cursor.on-demand"]
        )
        XCTAssertEqual(
            viewModel.availableMetrics.map(\.label),
            ["Cursor Models", "Other Models", "Grok Bot weekly", "On-demand spending"]
        )
        XCTAssertTrue(viewModel.isMetricVisible(cursorModelsID))
        XCTAssertTrue(viewModel.isMetricVisible(otherModelsID))

        viewModel.setMetricVisibility(false, metricID: cursorModelsID)
        store.updateVisualizationStyle(.circularRing, accountID: configuration.id, metricID: otherModelsID)
        store.updateWatchMetricVisibility(.show, accountID: configuration.id, metricID: otherModelsID)
        _ = store.reconcileMetricLayout(
            accountID: otherConfiguration.id,
            availableMetricIDs: [cursorModelsID, otherModelsID]
        )

        XCTAssertFalse(viewModel.isMetricVisible(cursorModelsID))
        XCTAssertTrue(viewModel.isMetricVisible(otherModelsID))
        XCTAssertTrue(store.isMetricVisible(accountID: otherConfiguration.id, metricID: cursorModelsID))

        let partialResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Cursor plan usage",
            bars: [fullResult.bars[0], fullResult.bars[2]],
            fetchedAt: Date().addingTimeInterval(60)
        )
        viewModel.synchronizeUsageResult(partialResult)

        XCTAssertEqual(viewModel.availableMetrics.map(\.id), [
            cursorModelsID, otherModelsID, grokBotID, "cursor.on-demand",
        ])
        XCTAssertEqual(
            store.visualizationStyle(accountID: configuration.id, metricID: otherModelsID),
            .circularRing
        )
        XCTAssertEqual(
            store.watchVisibilityPolicy(accountID: configuration.id, metricID: otherModelsID),
            .show
        )

        let reloadedStore = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        let reloadedViewModel = ProviderSettingsViewModel(
            configurationStore: reloadedStore,
            accountID: configuration.id,
            initialUsageResult: fullResult
        )
        await reloadedViewModel.prepare()

        XCTAssertFalse(reloadedViewModel.isMetricVisible(cursorModelsID))
        XCTAssertTrue(reloadedViewModel.isMetricVisible(otherModelsID))
        XCTAssertEqual(
            reloadedStore.visualizationStyle(accountID: configuration.id, metricID: otherModelsID),
            .circularRing
        )
        XCTAssertEqual(
            reloadedStore.watchVisibilityPolicy(accountID: configuration.id, metricID: otherModelsID),
            .show
        )
    }

    @MainActor
    func testCursorGrokBotMetricDefaultsVisibleAndCanBeHidden() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        let configuration = try XCTUnwrap(store.addAccount(for: .cursor))
        let metricID = "cursor.grok-bot-weekly"
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Cursor plan usage",
            bars: [
                UsageBar(
                    stableKey: "grok-bot-weekly",
                    label: "Grok Bot weekly",
                    used: 38,
                    limit: 100
                ),
            ],
            fetchedAt: Date()
        )
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            initialUsageResult: result
        )

        XCTAssertEqual(viewModel.availableMetrics.map(\.id), [
            CursorUsageIdentity.cursorModelsMetricID, CursorUsageIdentity.otherModelsMetricID,
            metricID, "cursor.on-demand",
        ])
        XCTAssertTrue(viewModel.isMetricVisible(metricID))

        viewModel.setMetricVisibility(false, metricID: metricID)

        XCTAssertFalse(viewModel.isMetricVisible(metricID))
        let reloadedStore = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertFalse(reloadedStore.isMetricVisible(accountID: configuration.id, metricID: metricID))
    }

    @MainActor
    func testAccountSettingsLoadMetricsAfterFirstCredentialSave() async throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        let configuration = try XCTUnwrap(store.addAccount(for: .openRouter))
        let refreshedResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Management API key",
            bars: [],
            creditsRemaining: 42,
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        var refreshCount = 0
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            onAccountRefresh: { _ in
                refreshCount += 1
                return refreshedResult
            }
        )

        await viewModel.prepare()
        XCTAssertTrue(viewModel.availableMetrics.isEmpty)
        XCTAssertEqual(refreshCount, 0)

        viewModel.secret = "new-management-key"
        viewModel.saveGenericCredential()
        for _ in 0..<100 where viewModel.availableMetrics.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(viewModel.availableMetrics.map(\.label), ["Credit balance"])
    }

    @MainActor
    func testGreptileCredentialSaveReportsStoredThenValidated() async throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: MemorySecretStore()
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .greptile))
        let validatedResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .greptile,
            title: "Greptile",
            subtitle: "All available review history",
            bars: [],
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let gate = UsageProviderGate()
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            onCredentialRefresh: { _ in
                await gate.wait()
                return validatedResult
            }
        )
        viewModel.secret = "greptile-key"

        viewModel.saveGenericCredential()
        try await withTestWatchdog(
            timeout: .seconds(5),
            failureMessage: "Greptile credential validation did not block within five seconds.",
            onTimeout: {
                Task { await gate.release() }
            },
            operation: {
                await gate.waitUntilBlocked()
            }
        )

        XCTAssertEqual(
            viewModel.credentialMessage,
            "API key saved in Keychain. Validating with Greptile..."
        )
        XCTAssertEqual(viewModel.credentialMessageSystemImage, "clock")
        XCTAssertNil(viewModel.credentialError)

        await gate.release()
        for _ in 0..<100 where viewModel.credentialMessage?.contains("validated") != true {
            await Task.yield()
        }

        XCTAssertEqual(
            viewModel.credentialMessage,
            "API key saved in Keychain and validated by Greptile."
        )
        XCTAssertEqual(viewModel.credentialMessageSystemImage, "checkmark.circle")
        XCTAssertNil(viewModel.credentialError)
    }

    @MainActor
    func testGreptileCredentialSavedWhileDisabledValidatesWhenEnabled() async throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        var configuration = try XCTUnwrap(store.addAccount(for: .greptile))
        configuration.isEnabled = false
        XCTAssertTrue(store.update(configuration))
        let validatedResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .greptile,
            title: "Greptile",
            subtitle: "All available review history",
            bars: [],
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        var credentialRefreshCount = 0
        var dismissalRefreshState = SettingsDismissalRefreshState()
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            onCredentialsChanged: {
                dismissalRefreshState.credentialsChanged(accountID: configuration.id)
            },
            onRefreshInputsChanged: {
                dismissalRefreshState.refreshInputsChanged(accountID: configuration.id)
            },
            onCredentialRefresh: { _ in
                credentialRefreshCount += 1
                return validatedResult
            }
        )
        viewModel.secret = "greptile-key"

        viewModel.saveGenericCredential()
        for _ in 0..<100 {
            await Task.yield()
        }
        XCTAssertEqual(credentialRefreshCount, 0)
        XCTAssertEqual(
            viewModel.credentialMessage,
            "API key saved in Keychain. Enable this account to validate it with Greptile."
        )

        viewModel.binding(for: \.isEnabled).wrappedValue = true
        for _ in 0..<100 where viewModel.credentialMessage?.contains("validated") != true {
            await Task.yield()
        }

        XCTAssertEqual(credentialRefreshCount, 1)
        XCTAssertEqual(viewModel.credentialMessage, "API key saved in Keychain and validated by Greptile.")
        XCTAssertNil(viewModel.credentialError)
        XCTAssertEqual(dismissalRefreshState.finishDismissal(), .none)
    }

    @MainActor
    func testGreptileCredentialSaveReportsValidationFailureAndManualRetrySuccess() async throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: MemorySecretStore()
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .greptile))
        let rejectedResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .greptile,
            title: "Greptile",
            subtitle: "Greptile rejected this organization API key.",
            bars: [],
            failureMessage: "Greptile rejected this organization API key.",
            recoveryAction: .reauthenticate,
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let validatedResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .greptile,
            title: "Greptile",
            subtitle: "All available review history",
            bars: [],
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_001)
        )
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            onAccountRefresh: { _ in validatedResult },
            onCredentialRefresh: { _ in rejectedResult }
        )
        viewModel.secret = "expired-greptile-key"

        viewModel.saveGenericCredential()
        for _ in 0..<100 where viewModel.credentialError == nil {
            await Task.yield()
        }

        XCTAssertNil(viewModel.credentialMessage)
        XCTAssertEqual(
            viewModel.credentialError,
            "API key saved in Keychain, but Greptile validation failed. "
                + "Greptile rejected this organization API key."
        )
        XCTAssertTrue(store.hasSecret(for: configuration))

        await viewModel.refreshMetrics()

        XCTAssertEqual(
            viewModel.credentialMessage,
            "API key saved in Keychain and validated by Greptile."
        )
        XCTAssertNil(viewModel.credentialError)
    }

    @MainActor
    func testGreptileTransientFailureDoesNotRejectOrUndoValidatedCredential() async throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        let configuration = try XCTUnwrap(store.addAccount(for: .greptile))
        let transientFailure = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .greptile,
            title: "Greptile",
            subtitle: "Greptile rate limit reached. Wait before refreshing again.",
            bars: [],
            failureMessage: "Greptile rate limit reached. Wait before refreshing again.",
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let validatedResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .greptile,
            title: "Greptile",
            subtitle: "All available review history",
            bars: [],
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_001)
        )
        var manualRefreshCount = 0
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            onAccountRefresh: { _ in
                manualRefreshCount += 1
                return manualRefreshCount == 1 ? validatedResult : transientFailure
            },
            onCredentialRefresh: { _ in transientFailure }
        )
        viewModel.secret = "greptile-key"

        viewModel.saveGenericCredential()
        for _ in 0..<100 where viewModel.credentialMessage?.contains("could not validate") != true {
            await Task.yield()
        }
        XCTAssertNil(viewModel.credentialError)
        XCTAssertTrue(viewModel.credentialMessage?.contains("could not validate it right now") == true)
        XCTAssertEqual(viewModel.credentialMessageSystemImage, "clock")

        await viewModel.refreshMetrics()
        XCTAssertEqual(viewModel.credentialMessage, "API key saved in Keychain and validated by Greptile.")
        XCTAssertNil(viewModel.credentialError)

        await viewModel.refreshMetrics()
        XCTAssertEqual(viewModel.credentialMessage, "API key saved in Keychain and validated by Greptile.")
        XCTAssertNil(viewModel.credentialError)

        viewModel.removeSavedCredential()
        for _ in 0..<100 {
            await Task.yield()
        }
        XCTAssertNil(viewModel.credentialMessage)
        XCTAssertNil(viewModel.credentialError)
    }

    @MainActor
    func testGreptileCredentialRemovalWithoutRefreshResultDoesNotClaimKeyWasSaved() async throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        let configuration = try XCTUnwrap(store.addAccount(for: .greptile))
        XCTAssertTrue(store.saveSecret("greptile-key", for: configuration))
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            onCredentialRefresh: { _ in nil }
        )

        viewModel.removeSavedCredential()
        for _ in 0..<100 {
            await Task.yield()
        }

        XCTAssertNil(viewModel.credentialMessage)
        XCTAssertNil(viewModel.credentialError)
        XCTAssertFalse(store.hasSecret(for: configuration))
    }

    @MainActor
    func testAccountSettingsReplaceCachedMetricsAfterCredentialChange() async throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        let configuration = try XCTUnwrap(store.addAccount(for: .openRouter))
        XCTAssertTrue(store.saveSecret("old-key", for: configuration))
        let oldResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Old key",
            bars: [],
            creditsRemaining: 10,
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let refreshedResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Replacement key",
            bars: [],
            creditsRemaining: 42,
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_100)
        )
        var discoveryRefreshCount = 0
        var credentialRefreshCount = 0
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            initialUsageResult: oldResult,
            onAccountRefresh: { _ in
                discoveryRefreshCount += 1
                return oldResult
            },
            onCredentialRefresh: { _ in
                credentialRefreshCount += 1
                return refreshedResult
            }
        )

        await viewModel.prepare()
        XCTAssertEqual(viewModel.usageResult?.creditsRemaining, 10)

        viewModel.secret = "replacement-key"
        viewModel.saveGenericCredential()
        for _ in 0..<100 where viewModel.usageResult?.creditsRemaining != 42 {
            await Task.yield()
        }

        XCTAssertEqual(discoveryRefreshCount, 0)
        XCTAssertEqual(credentialRefreshCount, 1)
        XCTAssertEqual(viewModel.usageResult?.creditsRemaining, 42)
    }

    @MainActor
    func testAccountSettingsQueuesCredentialRefreshBehindInFlightMetricLoad() async throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: MemorySecretStore()
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .openRouter))
        XCTAssertTrue(store.saveSecret("old-key", for: configuration))
        let gate = UsageProviderGate()
        var refreshCount = 0
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            onAccountRefresh: { configuration in
                refreshCount += 1
                if refreshCount == 1 {
                    await gate.wait()
                }
                return ProviderUsageResult(
                    accountID: configuration.id,
                    providerID: .openRouter,
                    title: "OpenRouter",
                    subtitle: refreshCount == 1 ? "Old key" : "Replacement key",
                    bars: [],
                    creditsRemaining: refreshCount == 1 ? 10 : 42,
                    fetchedAt: Date(timeIntervalSince1970: 2_000_000_000 + Double(refreshCount))
                )
            }
        )

        let prepareTask = Task { await viewModel.prepare() }
        await gate.waitUntilBlocked()
        XCTAssertTrue(viewModel.isLoadingMetrics)

        viewModel.secret = "replacement-key"
        viewModel.saveGenericCredential()
        viewModel.synchronizeUsageResult(
            ProviderUsageResult(
                accountID: configuration.id,
                providerID: .openRouter,
                title: "OpenRouter",
                subtitle: "Stale parent result",
                bars: [],
                creditsRemaining: 10,
                fetchedAt: Date(timeIntervalSince1970: 2_000_000_001)
            )
        )
        XCTAssertNil(viewModel.usageResult)
        await gate.release()
        await prepareTask.value

        XCTAssertEqual(refreshCount, 2)
        XCTAssertEqual(viewModel.usageResult?.creditsRemaining, 42)
        XCTAssertEqual(viewModel.usageResult?.subtitle, "Replacement key")
    }

    @MainActor
    func testAccountSettingsKeepsSyncBlockedAcrossQueuedCredentialRefreshes() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        let configuration = try XCTUnwrap(store.addAccount(for: .openRouter))
        let firstGate = UsageProviderGate()
        let secondGate = UsageProviderGate()
        var refreshCount = 0
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            onCredentialRefresh: { configuration in
                refreshCount += 1
                if refreshCount == 1 {
                    await firstGate.wait()
                } else {
                    await secondGate.wait()
                }
                return ProviderUsageResult(
                    accountID: configuration.id,
                    providerID: .openRouter,
                    title: "OpenRouter",
                    subtitle: refreshCount == 1 ? "First key" : "Second key",
                    bars: [],
                    creditsRemaining: refreshCount == 1 ? 10 : 42,
                    fetchedAt: Date(timeIntervalSince1970: 2_000_000_000 + Double(refreshCount))
                )
            }
        )

        viewModel.secret = "first-key"
        viewModel.saveGenericCredential()
        try await withTestWatchdog(
            timeout: .seconds(5),
            failureMessage: "The first credential refresh did not block within five seconds.",
            onTimeout: {
                Task { await firstGate.release() }
            },
            operation: {
                await firstGate.waitUntilBlocked()
            }
        )
        viewModel.secret = "second-key"
        viewModel.saveGenericCredential()
        await firstGate.release()
        try await withTestWatchdog(
            timeout: .seconds(5),
            failureMessage: "The queued credential refresh did not block within five seconds.",
            onTimeout: {
                Task { await secondGate.release() }
            },
            operation: {
                await secondGate.waitUntilBlocked()
            }
        )

        viewModel.synchronizeUsageResult(
            ProviderUsageResult(
                accountID: configuration.id,
                providerID: .openRouter,
                title: "OpenRouter",
                subtitle: "First key",
                bars: [],
                creditsRemaining: 10,
                fetchedAt: Date(timeIntervalSince1970: 2_000_000_001)
            )
        )
        XCTAssertNil(viewModel.usageResult)

        await secondGate.release()
        for _ in 0..<100 where viewModel.usageResult?.subtitle != "Second key" {
            await Task.yield()
        }
        XCTAssertEqual(refreshCount, 2)
        XCTAssertEqual(viewModel.usageResult?.subtitle, "Second key")
        XCTAssertEqual(viewModel.usageResult?.creditsRemaining, 42)
    }

    @MainActor
    func testAccountSettingsDoNotOfferMetricRefreshWhileAccountIsDisabled() async throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: MemorySecretStore()
        )
        var configuration = try XCTUnwrap(store.addAccount(for: .openRouter))
        XCTAssertTrue(store.saveSecret("management-key", for: configuration))
        configuration.isEnabled = false
        XCTAssertTrue(store.update(configuration))
        var refreshCount = 0
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            onAccountRefresh: { _ in
                refreshCount += 1
                return nil
            }
        )

        await viewModel.prepare()

        XCTAssertFalse(viewModel.canRefreshMetrics)
        XCTAssertEqual(
            viewModel.metricsEmptyStateMessage,
            "Enable this account to discover its dashboard metrics."
        )
        XCTAssertEqual(refreshCount, 0)

        viewModel.secret = "replacement-key"
        viewModel.saveGenericCredential()
        for _ in 0..<100 {
            await Task.yield()
        }
        XCTAssertEqual(refreshCount, 0)
    }

    @MainActor
    func testOpenRouterSettingsExplainManagementKeyRequirementsAndStorage() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer {
            defaults.removePersistentDomain(forName: #function)
        }
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        let configuration = try XCTUnwrap(store.addAccount(for: .openRouter))
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id
        )

        let presentation = viewModel.credentialPresentation

        XCTAssertEqual(presentation.sectionTitle, "OpenRouter Management API Key")
        XCTAssertEqual(presentation.unsavedPlaceholder, "Paste OpenRouter Management API Key")
        XCTAssertEqual(presentation.saveButtonTitle, "Save Management API Key")
        XCTAssertEqual(
            presentation.setupMessage,
            "OpenRouter credit balances require a Management API Key, not a regular inference key."
        )
        XCTAssertEqual(
            presentation.setupURL?.absoluteString,
            "https://openrouter.ai/settings/management-keys"
        )
        XCTAssertTrue(presentation.securityMessage?.contains("more sensitive than inference keys") == true)
        XCTAssertTrue(presentation.securityMessage?.contains("only in Keychain") == true)
    }

    @MainActor
    func testProviderSettingsViewModelRegistersDefaultAccountBeforeSavingCredential() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let secretStore = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: ProviderID.openRouter.rawValue
        )
        viewModel.secret = "sk-or-test"

        viewModel.saveGenericCredential()

        let savedConfiguration = store.configuration(accountID: ProviderID.openRouter.rawValue)
        XCTAssertNotNil(savedConfiguration)
        XCTAssertEqual(viewModel.secret, "")
        XCTAssertTrue(savedConfiguration.map { store.hasSecret(for: $0) } ?? false)
    }

    @MainActor
    func testProviderSettingsViewModelCancelsPendingEditsBeforeCursorSignOut() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let secretStore = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let cursor = try XCTUnwrap(store.addAccount(for: .cursor))
        let connected = try XCTUnwrap(
            store.connectCursorAccount(cursor, credential: "cursor-token")
        )
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: connected.id
        )

        viewModel.binding(for: \.accountLabel, persistence: .debounced).wrappedValue = "stale@example.com"
        viewModel.signOutOfCursor()
        viewModel.flushPendingChanges()

        XCTAssertEqual(store.configuration(accountID: connected.id)?.accountLabel, "")
        XCTAssertFalse(store.hasSecret(for: connected))
    }

    @MainActor
    func testProviderSettingsViewModelCancelsPendingEditsWhenSavingOpenCodeCredential() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        let openCode = try XCTUnwrap(store.addAccount(for: .openCodeZen))
        var discoveryRefreshCount = 0
        var credentialRefreshCount = 0
        var credentialsChangedCount = 0
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: openCode.id,
            onCredentialsChanged: { credentialsChangedCount += 1 },
            onAccountRefresh: { _ in
                discoveryRefreshCount += 1
                return nil
            },
            onCredentialRefresh: { _ in
                credentialRefreshCount += 1
                return nil
            }
        )
        viewModel.binding(for: \.accountLabel, persistence: .debounced).wrappedValue = "Team ZEN"
        viewModel.secret = "opencode-token"

        viewModel.saveOpenCodeCredential()
        var externallyUpdated = store.configuration(accountID: openCode.id)!
        externallyUpdated.showsHistory = false
        XCTAssertTrue(store.update(externallyUpdated))
        viewModel.flushPendingChanges()
        for _ in 0..<100 where credentialRefreshCount == 0 {
            await Task.yield()
        }

        XCTAssertEqual(store.configuration(accountID: openCode.id)?.accountLabel, "Team ZEN")
        XCTAssertEqual(store.configuration(accountID: openCode.id)?.showsHistory, false)
        XCTAssertEqual(credentialsChangedCount, 1)
        XCTAssertEqual(discoveryRefreshCount, 0)
        XCTAssertEqual(credentialRefreshCount, 1)
    }

    @MainActor
    func testOpenCodeRefreshRejectsResultAfterCredentialRemoval() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        let openCode = try XCTUnwrap(store.addAccount(for: .openCodeZen))
        XCTAssertTrue(store.saveSecret("old-token", for: openCode))
        let gate = UsageProviderGate()
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: openCode.id,
            onAccountRefresh: { configuration in
                await gate.wait()
                return ProviderUsageResult(
                    accountID: configuration.id,
                    providerID: .openCodeZen,
                    title: "OpenCode",
                    subtitle: "Stale credential",
                    bars: [UsageBar(label: "Stale metric", used: 1, limit: 10)],
                    fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
                )
            },
            onCredentialRefresh: { configuration in
                ProviderUsageResult(
                    accountID: configuration.id,
                    providerID: .openCodeZen,
                    title: "OpenCode",
                    subtitle: "Credential removed",
                    bars: [],
                    fetchedAt: Date(timeIntervalSince1970: 2_000_000_001)
                )
            }
        )

        let staleRefresh = Task { await viewModel.refreshOpenCode() }
        await gate.waitUntilBlocked()
        viewModel.removeSavedCredential(message: "Credential removed")
        for _ in 0..<100 where viewModel.usageResult?.subtitle != "Credential removed" {
            await Task.yield()
        }

        XCTAssertEqual(viewModel.usageResult?.subtitle, "Credential removed")
        await gate.release()
        await staleRefresh.value
        XCTAssertEqual(viewModel.usageResult?.subtitle, "Credential removed")
        XCTAssertTrue(viewModel.availableMetrics.isEmpty)
    }

    @MainActor
    func testCredentialRemovalFlushesPendingRefreshInputsBeforeRefreshing() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        let openCode = try XCTUnwrap(store.addAccount(for: .openCodeZen))
        XCTAssertTrue(store.saveSecret("old-token", for: openCode))
        var storedWorkspaceDuringRefresh: String?
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: openCode.id,
            onCredentialRefresh: { configuration in
                storedWorkspaceDuringRefresh = store.configuration(accountID: configuration.id)?.openCodeWorkspaceId
                return nil
            }
        )
        viewModel.binding(
            for: \.openCodeWorkspaceId,
            persistence: .debounced
        ).wrappedValue = "wrk_updated"

        viewModel.removeSavedCredential()
        for _ in 0..<100 where storedWorkspaceDuringRefresh == nil {
            await Task.yield()
        }

        XCTAssertEqual(storedWorkspaceDuringRefresh, "wrk_updated")
        XCTAssertEqual(store.configuration(accountID: openCode.id)?.openCodeWorkspaceId, "wrk_updated")
        XCTAssertFalse(store.hasSecret(for: openCode))
    }

    @MainActor
    func testProviderSettingsViewModelFlushesPendingWorkspaceBeforeRefresh() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        let openCode = try XCTUnwrap(store.addAccount(for: .openCodeZen))
        var refreshedConfiguration: ProviderAccountConfiguration?
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: openCode.id,
            onAccountRefresh: { configuration in
                refreshedConfiguration = configuration
                return nil
            }
        )
        viewModel.binding(
            for: \.openCodeWorkspaceId,
            persistence: .debounced
        ).wrappedValue = "wrk_pending"

        await viewModel.refreshOpenCode()

        XCTAssertEqual(store.configuration(accountID: openCode.id)?.openCodeWorkspaceId, "wrk_pending")
        XCTAssertEqual(refreshedConfiguration?.openCodeWorkspaceId, "wrk_pending")
    }

    @MainActor
    func testProviderSettingsViewModelPreservesGoStatusWhenBalanceRefreshes() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        let openCode = try XCTUnwrap(store.addAccount(for: .openCodeZen))
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: openCode.id,
            onAccountRefresh: { configuration in
                ProviderUsageResult(
                    accountID: configuration.id,
                    providerID: .openCodeZen,
                    title: configuration.displayName,
                    subtitle: "Zen credit balance - Go not subscribed",
                    bars: [],
                    creditsRemaining: 12.25,
                    usageMessages: ["This workspace is not subscribed to OpenCode Go."],
                    fetchedAt: Date()
                )
            }
        )

        await viewModel.refreshOpenCode()

        XCTAssertEqual(
            viewModel.openCodeCredentialMessage,
            "OpenCode Zen balance refreshed: $12.25 This workspace is not subscribed to OpenCode Go."
        )
    }

    @MainActor
    func testProviderSettingsViewModelReportsBalanceFailureAfterGoRefresh() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        let openCode = try XCTUnwrap(store.addAccount(for: .openCodeZen))
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: openCode.id,
            onAccountRefresh: { configuration in
                ProviderUsageResult(
                    accountID: configuration.id,
                    providerID: .openCodeZen,
                    title: configuration.displayName,
                    subtitle: "OpenCode Go usage",
                    bars: [UsageBar(stableKey: "go.weekly", label: "Weekly usage limit", used: 20, limit: 100)],
                    usageMessages: ["Zen balance unavailable: Could not parse OpenCode Zen balance."],
                    fetchedAt: Date()
                )
            }
        )

        await viewModel.refreshOpenCode()

        XCTAssertEqual(
            viewModel.openCodeCredentialMessage,
            "OpenCode Go usage refreshed. Zen balance unavailable: Could not parse OpenCode Zen balance."
        )
    }

    @MainActor
    func testProviderSettingsViewModelReportsCredentialSaveFailureWithoutCompleting() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: FailingSaveSecretStore(secret: "existing-token")
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .openRouter))
        var credentialsChangedCount = 0
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            onCredentialsChanged: { credentialsChangedCount += 1 }
        )
        viewModel.secret = "replacement-token"

        viewModel.saveGenericCredential()

        XCTAssertNotNil(viewModel.credentialError)
        XCTAssertEqual(viewModel.secret, "replacement-token")
        XCTAssertEqual(credentialsChangedCount, 0)
    }

    @MainActor
    func testPastedCopilotReplacementFailurePreservesPersistedIdentityAndCredential() async throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = FailingSaveSecretStore(secret: "existing-token")
        let sessionFixture = IsolatedTestURLSession { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token replacement-token")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"login":"replacement-user"}"#.utf8)
            )
        }
        defer {
            sessionFixture.invalidate()
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        var configuration = try XCTUnwrap(store.addAccount(for: .copilot))
        configuration.accountLabel = "existing-user"
        configuration.authMethod = .browserSession
        XCTAssertTrue(store.update(configuration))
        var credentialsChangedCount = 0
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            onCredentialsChanged: { credentialsChangedCount += 1 },
            copilotUsageProvider: makeCopilotUsageProvider(session: sessionFixture.session)
        )
        viewModel.secret = "replacement-token"
        viewModel.binding(for: \.showsHistory, persistence: .debounced).wrappedValue = false

        await viewModel.saveCopilotCredential()

        XCTAssertNotNil(viewModel.copilotAuthError)
        XCTAssertEqual(viewModel.secret, "replacement-token")
        XCTAssertEqual(credentialsChangedCount, 0)
        let reloadedStore = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let reloaded = try XCTUnwrap(reloadedStore.configuration(accountID: configuration.id))
        XCTAssertEqual(reloaded.accountLabel, "existing-user")
        XCTAssertEqual(reloaded.authMethod, .browserSession)
        XCTAssertFalse(reloaded.showsHistory)
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: reloaded)),
            "existing-token"
        )
    }

    @MainActor
    func testSuccessfulPastedCopilotReplacementUpdatesPersistedIdentityAndCredential() async throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        let sessionFixture = IsolatedTestURLSession { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token replacement-token")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"login":"replacement-user"}"#.utf8)
            )
        }
        defer {
            sessionFixture.invalidate()
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        var configuration = try XCTUnwrap(store.addAccount(for: .copilot))
        configuration.accountLabel = "existing-user"
        configuration.authMethod = .browserSession
        XCTAssertTrue(store.update(configuration))
        XCTAssertTrue(store.saveSecret("existing-token", for: configuration))
        var credentialsChangedCount = 0
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            onCredentialsChanged: { credentialsChangedCount += 1 },
            copilotUsageProvider: makeCopilotUsageProvider(session: sessionFixture.session)
        )
        viewModel.secret = "replacement-token"

        await viewModel.saveCopilotCredential()

        XCTAssertNil(viewModel.copilotAuthError)
        XCTAssertEqual(viewModel.secret, "")
        XCTAssertEqual(credentialsChangedCount, 1)
        let reloadedStore = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let reloaded = try XCTUnwrap(reloadedStore.configuration(accountID: configuration.id))
        XCTAssertEqual(reloaded.accountLabel, "replacement-user")
        XCTAssertEqual(reloaded.authMethod, .cliToken)
        let savedCredential = try XCTUnwrap(
            secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: reloaded))
        )
        XCTAssertEqual(
            CopilotCredentialsParser.parse(savedCredential),
            CopilotCredentials(accessToken: "replacement-token", username: "replacement-user")
        )
    }

    @MainActor
    func testDelayedBrowserCopilotReplacementFailurePreservesPersistedIdentityAndCredential() async throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = FailingSaveSecretStore(secret: "existing-token")
        let sessionFixture = makeCopilotBrowserReplacementSession()
        let authService = DelayedStubCopilotAuthService(result: .success(replacementCopilotAuthResult))
        defer {
            sessionFixture.invalidate()
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        var configuration = try XCTUnwrap(store.addAccount(for: .copilot))
        configuration.accountLabel = "existing-user"
        configuration.authMethod = .cliToken
        XCTAssertTrue(store.update(configuration))
        var credentialsChangedCount = 0
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            onCredentialsChanged: { credentialsChangedCount += 1 },
            copilotAuthService: authService,
            copilotUsageProvider: makeCopilotUsageProvider(session: sessionFixture.session)
        )

        let signInTask = Task {
            await viewModel.signInWithCopilot()
        }
        defer {
            signInTask.cancel()
            authService.completeCallback()
        }
        try await authService.waitUntilCallbackScheduled()
        XCTAssertTrue(viewModel.isSigningInWithCopilot)
        XCTAssertNotNil(viewModel.authURL)
        await Task.yield()
        authService.completeCallback()
        await signInTask.value

        XCTAssertNotNil(viewModel.copilotAuthError)
        XCTAssertEqual(credentialsChangedCount, 0)
        let reloadedStore = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let reloaded = try XCTUnwrap(reloadedStore.configuration(accountID: configuration.id))
        XCTAssertEqual(reloaded.accountLabel, "existing-user")
        XCTAssertEqual(reloaded.authMethod, .cliToken)
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: reloaded)),
            "existing-token"
        )
    }

    @MainActor
    func testSuccessfulBrowserCopilotReplacementUpdatesPersistedIdentityAndCredential() async throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        let sessionFixture = makeCopilotBrowserReplacementSession()
        let authService = DelayedStubCopilotAuthService(result: .success(replacementCopilotAuthResult))
        defer {
            sessionFixture.invalidate()
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        var configuration = try XCTUnwrap(store.addAccount(for: .copilot))
        configuration.accountLabel = "existing-user"
        configuration.authMethod = .cliToken
        XCTAssertTrue(store.update(configuration))
        XCTAssertTrue(store.saveSecret("existing-token", for: configuration))
        var credentialsChangedCount = 0
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            onCredentialsChanged: { credentialsChangedCount += 1 },
            copilotAuthService: authService,
            copilotUsageProvider: makeCopilotUsageProvider(session: sessionFixture.session)
        )

        let signInTask = Task {
            await viewModel.signInWithCopilot()
        }
        defer {
            signInTask.cancel()
            authService.completeCallback()
        }
        try await authService.waitUntilCallbackScheduled()
        authService.completeCallback()
        await signInTask.value

        XCTAssertNil(viewModel.copilotAuthError)
        XCTAssertEqual(credentialsChangedCount, 1)
        let reloadedStore = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let reloaded = try XCTUnwrap(reloadedStore.configuration(accountID: configuration.id))
        XCTAssertEqual(reloaded.accountLabel, "replacement-user")
        XCTAssertEqual(reloaded.authMethod, .browserSession)
        let savedCredential = try XCTUnwrap(
            secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: reloaded))
        )
        XCTAssertEqual(
            CopilotCredentialsParser.parse(savedCredential),
            CopilotCredentials(
                accessToken: "replacement-token",
                username: "replacement-user",
                refreshToken: "replacement-refresh-token",
                expiresAt: nil,
                refreshTokenExpiresAt: nil
            )
        )
    }

    @MainActor
    func testProviderSettingsViewModelReportsCredentialRemovalFailureWithoutCompleting() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: FailingDeleteSecretStore()
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .openRouter))
        var credentialsChangedCount = 0
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            onCredentialsChanged: { credentialsChangedCount += 1 }
        )

        viewModel.removeSavedCredential()

        XCTAssertNotNil(viewModel.credentialError)
        XCTAssertEqual(credentialsChangedCount, 0)
    }

    private func makeCopilotUsageProvider(session: URLSession) -> CopilotUsageProvider {
        CopilotUsageProvider(
            secretStore: EmptySecretStore(),
            session: session,
            usageEndpoint: URL(string: "https://example.test/copilot-usage")!
        )
    }

    private var replacementCopilotAuthResult: CopilotWebAuthResult {
        CopilotWebAuthResult(
            accessToken: "replacement-token",
            refreshToken: "replacement-refresh-token",
            expiresAt: nil,
            refreshTokenExpiresAt: nil
        )
    }

    private func makeCopilotBrowserReplacementSession() -> IsolatedTestURLSession {
        IsolatedTestURLSession { request in
            switch request.url?.path {
            case "/copilot-usage":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token replacement-token")
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data(#"{"login":"replacement-user"}"#.utf8)
                )
            default:
                throw URLError(.badURL)
            }
        }
    }

    @MainActor
    func testProviderSettingsViewModelClearsCredentialErrorWhenRetryingCodexSignIn() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: FailingDeleteSecretStore()
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .codex))
        let presenter = StubCodexBrowserPresenter()
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            codexAuthService: CodexWebAuthService(preferredCallbackPorts: [0]),
            codexAuthPresenter: presenter
        )
        viewModel.removeSavedCredential()
        XCTAssertNotNil(viewModel.credentialError)

        await viewModel.signInWithCodex(mode: .existingSession)
        XCTAssertNil(viewModel.credentialError)
        XCTAssertNotNil(viewModel.codexAuthError)
        await viewModel.signInWithCodex(mode: .privateSession)
        XCTAssertEqual(presenter.prefersEphemeralSessions, [false, true])
        XCTAssertFalse(viewModel.isSigningInWithCodex)
    }

    @MainActor
    func testCodexSignInConnectsDistinctAccountsWithIsolatedCredentials() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let secretStore = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let first = try XCTUnwrap(store.addAccount(for: .codex))
        let second = try XCTUnwrap(store.addAccount(for: .codex))
        let firstPayload = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"chatgpt-first"}}"#
            .base64URLEncodedForTest()
        let firstToken = "header.\(firstPayload).signature"
        XCTAssertTrue(
            store.saveSecret(
                CodexCredentialsParser.storedCredential(from: CodexCredentials(accessToken: firstToken)),
                for: first
            )
        )
        var credentialsChangedCount = 0
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: second.id,
            onCredentialsChanged: { credentialsChangedCount += 1 },
            codexAuthService: StubCodexAuthService(
                result: .success(
                    CodexWebAuthResult(
                        accessToken: "second-token",
                        refreshToken: "second-refresh",
                        idToken: nil,
                        accountID: "chatgpt-second",
                        expiresAt: 2_000_000_000
                    )
                )
            )
        )

        await viewModel.signInWithCodex()

        let firstCredentials = try XCTUnwrap(
            CodexCredentialsParser.parse(
                try XCTUnwrap(
                    secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: first))
                )
            )
        )
        let secondCredentials = try XCTUnwrap(
            CodexCredentialsParser.parse(
                try XCTUnwrap(
                    secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: second))
                )
            )
        )
        XCTAssertEqual(firstCredentials.accountID, "chatgpt-first")
        XCTAssertEqual(firstCredentials.accessToken, firstToken)
        XCTAssertEqual(secondCredentials.accountID, "chatgpt-second")
        XCTAssertEqual(secondCredentials.accessToken, "second-token")
        XCTAssertNil(viewModel.codexAuthError)
        XCTAssertEqual(credentialsChangedCount, 1)
    }

    @MainActor
    func testSingleCodexAccountStillAcceptsCredentialWithoutIdentityClaim() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let secretStore = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let configuration = try XCTUnwrap(store.addAccount(for: .codex))
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            codexAuthService: StubCodexAuthService(
                result: .success(
                    CodexWebAuthResult(
                        accessToken: "legacy-compatible-token",
                        refreshToken: nil,
                        idToken: nil,
                        accountID: nil,
                        expiresAt: nil
                    )
                )
            )
        )

        await viewModel.signInWithCodex()

        let savedCredential = try XCTUnwrap(
            secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: configuration)
            )
        )
        XCTAssertEqual(
            CodexCredentialsParser.parse(savedCredential)?.accessToken,
            "legacy-compatible-token"
        )
        XCTAssertNil(viewModel.codexAuthError)
    }

    @MainActor
    func testCodexDuplicateIdentityLeavesBothSavedAccountsUnchanged() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let secretStore = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        var first = try XCTUnwrap(store.addAccount(for: .codex))
        first.accountLabel = "Personal Codex"
        XCTAssertTrue(store.update(first))
        let second = try XCTUnwrap(store.addAccount(for: .codex))
        let firstPayload = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"private-provider-id"}}"#
            .base64URLEncodedForTest()
        let firstToken = "header.\(firstPayload).signature"
        let firstCredential = CodexCredentialsParser.storedCredential(
            from: CodexCredentials(accessToken: firstToken)
        )
        let secondCredential = CodexCredentialsParser.storedCredential(
            from: CodexCredentials(accessToken: "second-token", accountID: "second-provider-id")
        )
        XCTAssertTrue(store.saveSecret(firstCredential, for: first))
        XCTAssertTrue(store.saveSecret(secondCredential, for: second))
        var credentialsChangedCount = 0
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: second.id,
            onCredentialsChanged: { credentialsChangedCount += 1 },
            codexAuthService: StubCodexAuthService(
                result: .success(
                    CodexWebAuthResult(
                        accessToken: "replacement-token",
                        refreshToken: nil,
                        idToken: nil,
                        accountID: "private-provider-id",
                        expiresAt: nil
                    )
                )
            )
        )

        await viewModel.signInWithCodex()

        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: first)),
            firstCredential
        )
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: second)),
            secondCredential
        )
        XCTAssertTrue(viewModel.codexAuthError?.contains("already connected as “Personal Codex”") == true)
        XCTAssertFalse(viewModel.codexAuthError?.contains("private-provider-id") == true)
        XCTAssertEqual(credentialsChangedCount, 0)
    }

    @MainActor
    func testCodexCanceledSignInPreservesExistingCredential() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let secretStore = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let configuration = try XCTUnwrap(store.addAccount(for: .codex))
        let originalCredential = CodexCredentialsParser.storedCredential(
            from: CodexCredentials(accessToken: "original-token", accountID: "original-account")
        )
        XCTAssertTrue(store.saveSecret(originalCredential, for: configuration))
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            codexAuthService: StubCodexAuthService(result: .failure(CancellationError()))
        )

        await viewModel.signInWithCodex()

        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration)),
            originalCredential
        )
        XCTAssertEqual(
            viewModel.codexAuthError,
            "ChatGPT sign-in canceled. Saved accounts were not changed."
        )
    }

    @MainActor
    func testRemovingOneCodexAccountKeepsTheOtherAccountAndCredential() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let secretStore = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let first = try XCTUnwrap(store.addAccount(for: .codex))
        let second = try XCTUnwrap(store.addAccount(for: .codex))
        XCTAssertTrue(store.saveSecret("first-credential", for: first))
        XCTAssertTrue(store.saveSecret("second-credential", for: second))

        XCTAssertTrue(store.removeAccount(first))

        XCTAssertNil(store.configuration(accountID: first.id))
        XCTAssertNotNil(store.configuration(accountID: second.id))
        XCTAssertNil(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: first))
        )
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: second)),
            "second-credential"
        )
    }

    @MainActor
    func testProviderSettingsViewModelCompletesSuccessfulSaveDespiteUnrelatedReadFailure() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let secretStore = SelectiveReadFailureSecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let unreadable = try XCTUnwrap(store.addAccount(for: .openRouter))
        let target = try XCTUnwrap(store.addAccount(for: .moonshot))
        secretStore.failingAccount = ProviderConfigurationStore.keychainAccount(for: unreadable)
        var credentialsChangedCount = 0
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: target.id,
            onCredentialsChanged: { credentialsChangedCount += 1 }
        )
        viewModel.secret = "moonshot-token"

        viewModel.saveGenericCredential()

        XCTAssertNil(viewModel.credentialError)
        XCTAssertEqual(viewModel.secret, "")
        XCTAssertEqual(credentialsChangedCount, 1)
        XCTAssertNotNil(store.lastError)
    }

    @MainActor
    func testRetryableResetFailurePinsRetryToOriginalCredit() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        let configuration = try XCTUnwrap(store.addAccount(for: .codex))
        let provider = ResetConsumptionTestProvider(
            outcome: .reset,
            fetchFails: false,
            consumeErrorCode: .timedOut
        )
        let service = UsageRefreshService(providers: [provider])
        let orchestrator = DashboardOrchestrator(
            refreshService: service,
            configurationStore: store,
            historyStore: UsageHistoryStore(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier(),
            appReviewPromptPolicy: AppReviewPromptPolicy(defaults: defaults),
            widgetSnapshotCoordinator: WidgetSnapshotCoordinator(
                refreshService: service,
                configurationStore: store,
                publishSnapshot: { _, _ in },
                publishSettings: { _ in }
            )
        )

        let feedback = await orchestrator.consumeCodexBankedReset(
            for: configuration,
            creditID: "credit-original"
        )

        XCTAssertFalse(feedback.isSuccess)
        XCTAssertTrue(feedback.requiresSameResetForRetry)
        XCTAssertTrue(service.hasRetainedCodexResetAttempt(for: configuration.id))
        XCTAssertEqual(
            service.retainedCodexResetAttempt(for: configuration.id),
            CodexRetainedResetAttempt(creditID: "credit-original")
        )

        let retryFeedback = await orchestrator.consumeCodexBankedReset(
            for: configuration,
            creditID: "credit-different"
        )
        let consumedKeys = await provider.recordedConsumedKeys()
        let consumedCreditIDs = await provider.recordedConsumedCreditIDs()

        XCTAssertFalse(retryFeedback.isSuccess)
        XCTAssertEqual(consumedCreditIDs, ["credit-original", "credit-original"])
        XCTAssertEqual(consumedKeys.count, 2)
        XCTAssertEqual(consumedKeys[0], consumedKeys[1])
    }

    @MainActor
    func testResetConsumptionRefreshesAuthoritativeInventoryAfterSuccess() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        let configuration = try XCTUnwrap(store.addAccount(for: .codex))
        let cachedResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: configuration.displayName,
            subtitle: "Live ChatGPT usage",
            bars: [UsageBar(label: "Usage", used: 100, limit: 100)],
            codexBankedRateLimitResets: CodexBankedRateLimitResets(
                availableCount: 2,
                credits: [
                    CodexBankedRateLimitReset(id: "credit-first"),
                    CodexBankedRateLimitReset(id: "credit-second"),
                ],
                canConsume: true
            ),
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let provider = ResetConsumptionTestProvider(outcome: .reset, fetchFails: false)
        let service = UsageRefreshService(providers: [provider], initialResults: [cachedResult])
        let orchestrator = DashboardOrchestrator(
            refreshService: service,
            configurationStore: store,
            historyStore: UsageHistoryStore(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier(),
            appReviewPromptPolicy: AppReviewPromptPolicy(defaults: defaults),
            widgetSnapshotCoordinator: WidgetSnapshotCoordinator(
                refreshService: service,
                configurationStore: store,
                publishSnapshot: { _, _ in },
                publishSettings: { _ in }
            )
        )

        let feedback = await orchestrator.consumeCodexBankedReset(
            for: configuration,
            creditID: "credit-second"
        )

        XCTAssertTrue(feedback.isSuccess)
        XCTAssertNil(service.results.first?.codexBankedRateLimitResets)
        let fetchCount = await provider.recordedFetchCount()
        XCTAssertEqual(fetchCount, 1)
    }

    @MainActor
    func testResetConsumptionRefetchesAndPreservesVerifiedAvailabilityWhenRefreshFails() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        let configuration = try XCTUnwrap(store.addAccount(for: .codex))
        let cachedResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: configuration.displayName,
            subtitle: "Live ChatGPT usage",
            bars: [UsageBar(label: "Usage", used: 100, limit: 100)],
            codexBankedRateLimitResets: CodexBankedRateLimitResets(
                availableCount: 1,
                canConsume: true
            ),
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let provider = ResetConsumptionTestProvider(outcome: .reset, fetchFails: true)
        let service = UsageRefreshService(providers: [provider], initialResults: [cachedResult])
        let historyStore = UsageHistoryStore(defaults: defaults)
        let widgetCoordinator = WidgetSnapshotCoordinator(
            refreshService: service,
            configurationStore: store,
            publishSnapshot: { _, _ in },
            publishSettings: { _ in }
        )
        let orchestrator = DashboardOrchestrator(
            refreshService: service,
            configurationStore: store,
            historyStore: historyStore,
            usageAlertNotifier: StubUsageAlertNotifier(),
            appReviewPromptPolicy: AppReviewPromptPolicy(defaults: defaults),
            widgetSnapshotCoordinator: widgetCoordinator
        )

        let feedback = await orchestrator.consumeCodexBankedReset(
            for: configuration,
            creditID: nil
        )

        XCTAssertTrue(feedback.isSuccess)
        XCTAssertTrue(feedback.message.contains("could not be refreshed"))
        let fetchCount = await provider.recordedFetchCount()
        let consumedKeys = await provider.recordedConsumedKeys()
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(consumedKeys.count, 1)
        XCTAssertEqual(service.results.first?.codexBankedRateLimitResets, cachedResult.codexBankedRateLimitResets)
        XCTAssertEqual(service.refreshErrorsByAccountID[configuration.id], "Refresh failed")
    }

    @MainActor
    func testNoCreditHidesPreservedResetActionWhenAuthoritativeRefreshFails() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        let configuration = try XCTUnwrap(store.addAccount(for: .codex))
        let cachedResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: configuration.displayName,
            subtitle: "Live ChatGPT usage",
            bars: [UsageBar(label: "Usage", used: 100, limit: 100)],
            codexBankedRateLimitResets: CodexBankedRateLimitResets(
                availableCount: 1,
                canConsume: true
            ),
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let provider = ResetConsumptionTestProvider(outcome: .noCredit, fetchFails: true)
        let service = UsageRefreshService(providers: [provider], initialResults: [cachedResult])
        let orchestrator = DashboardOrchestrator(
            refreshService: service,
            configurationStore: store,
            historyStore: UsageHistoryStore(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier(),
            appReviewPromptPolicy: AppReviewPromptPolicy(defaults: defaults),
            widgetSnapshotCoordinator: WidgetSnapshotCoordinator(
                refreshService: service,
                configurationStore: store,
                publishSnapshot: { _, _ in },
                publishSettings: { _ in }
            )
        )

        let feedback = await orchestrator.consumeCodexBankedReset(
            for: configuration,
            creditID: "stale-credit"
        )

        XCTAssertFalse(feedback.isSuccess)
        XCTAssertTrue(feedback.hidesAction)
        XCTAssertEqual(feedback.message, "No banked reset remains for this account.")
        XCTAssertEqual(service.results.first?.codexBankedRateLimitResets, cachedResult.codexBankedRateLimitResets)
        XCTAssertEqual(service.refreshErrorsByAccountID[configuration.id], "Refresh failed")
    }

}

private enum StaleRefreshConfigurationMutation: String, CaseIterable {
    case remove
    case disable
}

@MainActor
private struct StaleRefreshHarness {
    let suiteName: String
    let defaults: UserDefaults
    let configurationStore: ProviderConfigurationStore
    let configuration: ProviderAccountConfiguration
    let refreshService: UsageRefreshService
    let historyStore: UsageHistoryStore
    let notifier: RecordingUsageAlertNotifier
    let orchestrator: DashboardOrchestrator

    func removeDefaults() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private final class StubCodexBrowserPresenter: CodexBrowserPresenting {
    private(set) var prefersEphemeralSessions: [Bool] = []

    func present(url: URL, prefersEphemeralSession: Bool, onCancel: @escaping () -> Void) -> Bool {
        prefersEphemeralSessions.append(prefersEphemeralSession)
        return false
    }

    func finish() {}
}

@MainActor
private final class StubCodexAuthService: CodexWebAuthenticating {
    let result: Result<CodexWebAuthResult, Error>

    init(result: Result<CodexWebAuthResult, Error>) {
        self.result = result
    }

    func signIn(
        presentAuthorizationURL: @escaping @MainActor (URL) -> Bool
    ) async throws -> CodexWebAuthResult {
        try result.get()
    }
}

@MainActor
private final class DelayedStubCopilotAuthService: CopilotWebAuthenticating {
    private let result: Result<CopilotWebAuthResult, Error>
    private let callbackScheduled = TestSignal()
    private let callbackRelease = TestSignal()

    init(result: Result<CopilotWebAuthResult, Error>) {
        self.result = result
    }

    func signIn(
        configuration: CopilotOAuthConfiguration,
        presentAuthorizationURL: @escaping @MainActor (URL) -> Void
    ) async throws -> CopilotWebAuthResult {
        presentAuthorizationURL(URL(string: "https://github.com/login/oauth/authorize")!)
        callbackScheduled.signal()
        try await withTestWatchdog(
            timeout: .seconds(5),
            failureMessage: "Copilot callback release did not arrive within the five-second test bound.",
            onTimeout: {},
            operation: { [callbackRelease] in
                await callbackRelease.wait()
            }
        )
        return try result.get()
    }

    func waitUntilCallbackScheduled() async throws {
        try await withTestWatchdog(
            timeout: .seconds(5),
            failureMessage: "Copilot callback was not scheduled within the five-second test bound.",
            onTimeout: {},
            operation: { [callbackScheduled] in
                await callbackScheduled.wait()
            }
        )
    }

    func completeCallback() {
        callbackRelease.signal()
    }
}

@MainActor
private final class RecordingWatchSnapshotSender: WatchSnapshotSending {
    private var activationHandler: (@MainActor (_ force: Bool) -> Void)?
    private(set) var activationCount = 0
    private(set) var snapshots: [WatchDashboardSnapshot] = []
    private(set) var publishedForces: [Bool] = []
    var onPublish: (() -> Void)?

    func activate(onSnapshotNeeded: @escaping @MainActor (_ force: Bool) -> Void) {
        activationCount += 1
        activationHandler = onSnapshotNeeded
    }

    func publish(_ snapshot: WatchDashboardSnapshot, force: Bool) -> Bool {
        snapshots.append(snapshot)
        publishedForces.append(force)
        onPublish?()
        return true
    }

    func completeActivation() {
        activationHandler?(true)
    }
}
