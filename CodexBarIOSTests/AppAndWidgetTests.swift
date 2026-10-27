import UIKit
import XCTest
@testable import CodexBarIOS

final class AppAndWidgetTests: XCTestCase {
    func testBuiltAppDisablesMultipleScenesWhileDashboardLifecycleIsSceneOwned() throws {
        let sceneManifest = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest")
                as? [String: Any]
        )

        XCTAssertEqual(
            sceneManifest["UIApplicationSupportsMultipleScenes"] as? Bool,
            false
        )
    }

    func testBuiltAppAndWidgetContainRequiredPrivacyManifests() throws {
        XCTAssertEqual(
            try privacyReasons(in: Bundle.main),
            ["CA92.1", "1C8F.1"]
        )

        let plugInsURL = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let widgetBundle = try XCTUnwrap(
            Bundle(url: plugInsURL.appendingPathComponent("CodexBarIOSWidget.appex"))
        )
        XCTAssertEqual(try privacyReasons(in: widgetBundle), ["1C8F.1"])
    }

    private func privacyReasons(in bundle: Bundle) throws -> Set<String> {
        let manifestURL = try XCTUnwrap(
            bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "Missing PrivacyInfo.xcprivacy in \(bundle.bundleURL.lastPathComponent)"
        )
        let data = try Data(contentsOf: manifestURL)
        let manifest = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual(manifest["NSPrivacyTrackingDomains"] as? [String], [])
        XCTAssertTrue((manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])?.isEmpty == true)

        let accessedAPITypes = try XCTUnwrap(
            manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
        )
        let userDefaultsEntry = try XCTUnwrap(
            accessedAPITypes.first {
                $0["NSPrivacyAccessedAPIType"] as? String
                    == "NSPrivacyAccessedAPICategoryUserDefaults"
            }
        )
        return Set(try XCTUnwrap(userDefaultsEntry["NSPrivacyAccessedAPITypeReasons"] as? [String]))
    }

    func testProviderDeepLinkRoundTripsAccountID() throws {
        let accountID = "claude.work + personal/primary?"
        let url = try XCTUnwrap(CodexBarDeepLink.providerURL(accountID: accountID))

        XCTAssertEqual(url.scheme, "codexbar")
        XCTAssertEqual(url.host, "provider")
        XCTAssertEqual(CodexBarDeepLink.providerAccountID(from: url), accountID)
    }

    func testProviderDeepLinkRejectsUnsupportedOrAmbiguousRoutes() throws {
        XCTAssertNil(CodexBarDeepLink.providerURL(accountID: ""))
        XCTAssertNil(CodexBarDeepLink.providerAccountID(from: URL(string: "https://provider?account=codex")!))
        XCTAssertNil(CodexBarDeepLink.providerAccountID(from: URL(string: "codexbar://settings?account=codex")!))
        XCTAssertNil(CodexBarDeepLink.providerAccountID(from: URL(string: "codexbar://provider/details?account=codex")!))
        XCTAssertNil(CodexBarDeepLink.providerAccountID(from: URL(string: "codexbar://provider")!))
        XCTAssertNil(
            CodexBarDeepLink.providerAccountID(
                from: URL(string: "codexbar://provider?account=codex&account=claude")!
            )
        )
    }

    func testDashboardDeepLinkNavigationKeepsTargetUntilRefreshReorderSettles() {
        var navigation = DashboardDeepLinkNavigationState()
        navigation.begin(accountID: "claude.work", waitsForRefresh: true)

        XCTAssertEqual(navigation.accountID, "claude.work")
        XCTAssertFalse(navigation.shouldFinishAfterInitialScroll)

        navigation.finish(accountID: "another-account")
        XCTAssertEqual(navigation.accountID, "claude.work")

        navigation.finish(accountID: "claude.work")
        XCTAssertNil(navigation.accountID)
        XCTAssertFalse(navigation.waitsForRefresh)
    }

    func testDashboardDeepLinkNavigationFinishesWarmLaunchAfterInitialScroll() {
        var navigation = DashboardDeepLinkNavigationState()
        navigation.begin(accountID: "codex", waitsForRefresh: false)

        XCTAssertTrue(navigation.shouldFinishAfterInitialScroll)

        navigation.finish(accountID: "codex")
        XCTAssertNil(navigation.accountID)
    }

    func testDashboardAccountConfigurationTargetsExactAccountAcrossSameProvider() {
        var navigation = DashboardAccountConfigurationNavigationState()

        navigation.present(accountID: "claude.personal")
        XCTAssertEqual(navigation.presentation?.accountID, "claude.personal")
        XCTAssertEqual(navigation.presentation?.id, "claude.personal")

        navigation.present(accountID: "claude.work")
        XCTAssertEqual(navigation.presentation?.accountID, "claude.work")
        XCTAssertEqual(navigation.presentation?.id, "claude.work")
    }

    func testDashboardAccountConfigurationDismissalRefreshesOnlyPresentedAccount() {
        var navigation = DashboardAccountConfigurationNavigationState()
        navigation.present(accountID: "openRouter.personal")
        navigation.present(accountID: "openRouter.work")

        navigation.clearPresentation()
        XCTAssertNil(navigation.presentation)

        XCTAssertEqual(navigation.finishDismissal(), "openRouter.work")
        XCTAssertNil(navigation.presentation)
        XCTAssertNil(navigation.finishDismissal())

        navigation.present(accountID: "openRouter.work")
        navigation.credentialsChanged()
        XCTAssertNil(navigation.finishDismissal())
    }

    func testDashboardFirstAccountStateWaitsForInitialRefreshAndKeepsOtherStatesDistinct() {
        XCTAssertEqual(
            DashboardEmptyState.resolve(
                hasAccounts: false,
                hasEnabledAccounts: false,
                needsSetupAccountID: nil,
                cardsAreEmpty: true,
                hasCompletedInitialRefresh: false,
                performsLifecycleWork: true,
                isPersistenceRecoveryRequired: false
            ),
            .loading
        )
        XCTAssertEqual(
            DashboardEmptyState.resolve(
                hasAccounts: false,
                hasEnabledAccounts: false,
                needsSetupAccountID: nil,
                cardsAreEmpty: true,
                hasCompletedInitialRefresh: false,
                performsLifecycleWork: false,
                isPersistenceRecoveryRequired: false
            ),
            .firstAccount
        )
        XCTAssertEqual(
            DashboardEmptyState.resolve(
                hasAccounts: false,
                hasEnabledAccounts: false,
                needsSetupAccountID: nil,
                cardsAreEmpty: true,
                hasCompletedInitialRefresh: true,
                performsLifecycleWork: true,
                isPersistenceRecoveryRequired: false
            ),
            .firstAccount
        )
        XCTAssertEqual(
            DashboardEmptyState.resolve(
                hasAccounts: false,
                hasEnabledAccounts: false,
                needsSetupAccountID: nil,
                cardsAreEmpty: true,
                hasCompletedInitialRefresh: true,
                performsLifecycleWork: true,
                isPersistenceRecoveryRequired: true
            ),
            .recovery
        )
        XCTAssertEqual(
            DashboardEmptyState.resolve(
                hasAccounts: false,
                hasEnabledAccounts: false,
                needsSetupAccountID: nil,
                cardsAreEmpty: true,
                hasCompletedInitialRefresh: true,
                performsLifecycleWork: true,
                isPersistenceRecoveryRequired: false,
                hasIncompleteAccountReset: true
            ),
            .accountResetRecovery
        )
        XCTAssertEqual(
            DashboardEmptyState.resolve(
                hasAccounts: true,
                hasEnabledAccounts: true,
                needsSetupAccountID: "openRouter.personal",
                cardsAreEmpty: true,
                hasCompletedInitialRefresh: true,
                performsLifecycleWork: true,
                isPersistenceRecoveryRequired: false
            ),
            .needsSetup(accountID: "openRouter.personal")
        )
        XCTAssertEqual(
            DashboardEmptyState.resolve(
                hasAccounts: true,
                hasEnabledAccounts: false,
                needsSetupAccountID: nil,
                cardsAreEmpty: true,
                hasCompletedInitialRefresh: true,
                performsLifecycleWork: true,
                isPersistenceRecoveryRequired: false
            ),
            .accountsDisabled
        )
        XCTAssertEqual(
            DashboardEmptyState.resolve(
                hasAccounts: true,
                hasEnabledAccounts: true,
                needsSetupAccountID: nil,
                cardsAreEmpty: true,
                hasCompletedInitialRefresh: true,
                performsLifecycleWork: true,
                isPersistenceRecoveryRequired: false
            ),
            .noUsageData
        )
        XCTAssertEqual(
            DashboardEmptyState.resolve(
                hasAccounts: true,
                hasEnabledAccounts: true,
                needsSetupAccountID: nil,
                cardsAreEmpty: false,
                hasCompletedInitialRefresh: true,
                performsLifecycleWork: true,
                isPersistenceRecoveryRequired: false
            ),
            .hidden
        )
    }

    @MainActor
    func testAddAccountFlowCreatesOnceAndRoutesToExactAccount() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: MemorySecretStore()
        )
        var flow = AddAccountFlowState()

        let selectedAccountID = try XCTUnwrap(
            flow.select(.openRouter, configurationStore: store)
        )
        let repeatedSelectionID = flow.select(.claude, configurationStore: store)

        XCTAssertEqual(flow.accountID, selectedAccountID)
        XCTAssertEqual(repeatedSelectionID, selectedAccountID)
        XCTAssertEqual(store.configurations.count, 1)
        XCTAssertEqual(
            store.configuration(accountID: selectedAccountID)?.providerID,
            .openRouter
        )
    }

    func testAddAccountChooserContainsEveryProviderExactlyOnce() {
        let options = AddAccountFlowState.providerOptions

        XCTAssertEqual(options.count, Set(options).count)
        XCTAssertEqual(Set(options), Set(ProviderID.allCases.filter { $0 != .antigravity && $0.isAvailableOnIPhone }))
        XCTAssertTrue(options.allSatisfy { !$0.displayName.isEmpty })
        XCTAssertTrue(options.allSatisfy { !$0.addAccountIconName.isEmpty })
    }

    func testSettingsAccountsRowsPutOneAddActionBeforeEmptyAndConfiguredStates() {
        XCTAssertEqual(
            SettingsAccountsSectionRow.rows(accountIDs: []),
            [.addAccount, .emptyState]
        )
        XCTAssertEqual(
            SettingsAccountsSectionRow.rows(accountIDs: ["codex.personal"]),
            [.addAccount, .account("codex.personal")]
        )
        XCTAssertEqual(
            SettingsAccountsSectionRow.rows(
                accountIDs: ["codex.personal", "claude.work"]
            ),
            [
                .addAccount,
                .account("codex.personal"),
                .account("claude.work"),
            ]
        )
    }

    func testSettingsHierarchyUsesSixDistinctDestinationsWithAccountsFirst() {
        XCTAssertEqual(
            SettingsDestination.allCases,
            [
                .accountsAndGroups,
                .dashboard,
                .alerts,
                .widgets,
                .helpAndAbout,
                .dataAndRecovery,
            ]
        )
        XCTAssertEqual(SettingsInitialRoute.accounts.destination, .accountsAndGroups)
        XCTAssertEqual(
            Set(SettingsDestination.allCases.map(\.title)).count,
            SettingsDestination.allCases.count
        )
        XCTAssertTrue(SettingsDestination.allCases.allSatisfy { !$0.systemImage.isEmpty })
    }

    func testSettingsHomeRoutesAttentionToRecoveryWithoutDuplicatingDestination() {
        let routineLayout = SettingsHomeLayout(requiresAttention: false)
        XCTAssertNil(routineLayout.attentionDestination)
        XCTAssertEqual(routineLayout.routineDestinations, SettingsDestination.allCases)

        let attentionLayout = SettingsHomeLayout(requiresAttention: true)
        XCTAssertEqual(attentionLayout.attentionDestination, .dataAndRecovery)
        XCTAssertFalse(attentionLayout.routineDestinations.contains(.dataAndRecovery))
        XCTAssertEqual(
            attentionLayout.routineDestinations.count + 1,
            SettingsDestination.allCases.count
        )
    }

    func testSettingsGroupValidationStateSurfacesAndClearsFailures() {
        var state = SettingsGroupValidationState()
        XCTAssertNil(state.message)

        state.recordFailure(
            storeError: "Group names must be unique.",
            target: .existingGroup("work")
        )
        XCTAssertEqual(state.message, "Group names must be unique.")
        XCTAssertEqual(state.target, .existingGroup("work"))

        state.clear()
        XCTAssertNil(state.message)
        XCTAssertNil(state.target)

        state.recordFailure(storeError: nil, target: .newGroup)
        XCTAssertEqual(state.message, "Could not save the group name.")
        XCTAssertEqual(state.target, .newGroup)
    }

    func testSettingsPendingGroupChangesCommitDraftsAndNewGroupWithoutDiscardingInput() {
        var attemptedGroupIDs: [String] = []
        var newGroupCommitCount = 0
        var changes = SettingsPendingGroupChanges(
            draftGroupIDs: ["first", "second", "third"],
            newGroupName: "New Team"
        )
        XCTAssertTrue(changes.hasChanges)
        XCTAssertFalse(
            changes.commitAll(
                commitDraft: { groupID in
                    attemptedGroupIDs.append(groupID)
                    return groupID != "second"
                },
                commitNewGroup: {
                    newGroupCommitCount += 1
                    return true
                }
            )
        )
        XCTAssertEqual(attemptedGroupIDs, ["first", "second"])
        XCTAssertEqual(newGroupCommitCount, 0)

        attemptedGroupIDs = []
        changes = SettingsPendingGroupChanges(
            draftGroupIDs: ["first", "second"],
            newGroupName: " New Team "
        )
        XCTAssertTrue(
            changes.commitAll(
                commitDraft: { groupID in
                    attemptedGroupIDs.append(groupID)
                    return true
                },
                commitNewGroup: {
                    newGroupCommitCount += 1
                    return true
                }
            )
        )
        XCTAssertEqual(attemptedGroupIDs, ["first", "second"])
        XCTAssertEqual(newGroupCommitCount, 1)

        changes = SettingsPendingGroupChanges(
            draftGroupIDs: [],
            newGroupName: "Duplicate"
        )
        XCTAssertFalse(
            changes.commitAll(
                commitDraft: { _ in true },
                commitNewGroup: {
                    newGroupCommitCount += 1
                    return false
                }
            )
        )
        XCTAssertEqual(newGroupCommitCount, 2)

        changes = SettingsPendingGroupChanges(
            draftGroupIDs: [],
            newGroupName: "   "
        )
        XCTAssertFalse(changes.hasChanges)
    }

    func testSettingsPendingGroupChangesExcludeRevertedAndMissingDrafts() {
        let changedDraftGroupIDs = SettingsPendingGroupChanges.changedDraftGroupIDs(
            draftNames: [
                "changed": "Renamed",
                "missing": "Removed",
                "reverted": "  Original  ",
            ],
            persistedName: { groupID in
                [
                    "changed": "Original",
                    "reverted": "Original",
                ][groupID]
            }
        )

        XCTAssertEqual(changedDraftGroupIDs, ["changed"])
        XCTAssertFalse(
            SettingsPendingGroupChanges(
                draftGroupIDs: SettingsPendingGroupChanges.changedDraftGroupIDs(
                    draftNames: ["reverted": "Original"],
                    persistedName: { _ in "Original" }
                ),
                newGroupName: ""
            ).hasChanges
        )
    }

    func testSettingsNavigationGuardBlocksAccountDetailUntilPendingChangesCommit() {
        var navigationCount = 0

        XCTAssertFalse(
            SettingsNavigationGuard.perform(
                commitPendingChanges: { false },
                navigate: { navigationCount += 1 }
            )
        )
        XCTAssertEqual(navigationCount, 0)

        XCTAssertTrue(
            SettingsNavigationGuard.perform(
                commitPendingChanges: { true },
                navigate: { navigationCount += 1 }
            )
        )
        XCTAssertEqual(navigationCount, 1)
    }

    func testSettingsNavigationGuardClearsAccountDetailOnlyAfterCategoryChangeCommits() {
        var commitCount = 0
        var clearNestedRouteCount = 0

        XCTAssertFalse(
            SettingsNavigationGuard.performCategoryChange(
                from: .accountsAndGroups,
                to: .dashboard,
                commitPendingChanges: {
                    commitCount += 1
                    return false
                },
                clearNestedRoute: {
                    clearNestedRouteCount += 1
                }
            )
        )
        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(clearNestedRouteCount, 0)

        XCTAssertTrue(
            SettingsNavigationGuard.performCategoryChange(
                from: .accountsAndGroups,
                to: .dashboard,
                commitPendingChanges: {
                    commitCount += 1
                    return true
                },
                clearNestedRoute: {
                    clearNestedRouteCount += 1
                }
            )
        )
        XCTAssertEqual(commitCount, 2)
        XCTAssertEqual(clearNestedRouteCount, 1)

        XCTAssertTrue(
            SettingsNavigationGuard.performCategoryChange(
                from: .dashboard,
                to: .alerts,
                commitPendingChanges: {
                    XCTFail("Non-account category changes should not commit group drafts.")
                    return false
                },
                clearNestedRoute: {
                    clearNestedRouteCount += 1
                }
            )
        )
        XCTAssertEqual(clearNestedRouteCount, 2)
    }

    func testSettingsCategorySummariesExposeStateWithoutAccountIdentifiers() {
        XCTAssertEqual(
            SettingsCategorySummary.accounts(accountCount: 1, groupCount: 2),
            "1 account · 2 groups"
        )
        XCTAssertEqual(
            SettingsCategorySummary.accounts(accountCount: 0, groupCount: 1),
            "0 accounts · 1 group"
        )
        XCTAssertEqual(
            SettingsCategorySummary.dashboard(
                appearance: .dark,
                ordering: .smart,
                refreshInterval: .fifteenMinutes,
                historySamplingInterval: .twoHours
            ),
            "Dark · Smart · 15 min refresh · 2 hours history"
        )
        XCTAssertEqual(
            SettingsCategorySummary.alerts(
                isEnabled: true,
                warningThreshold: 0.75,
                criticalThreshold: 0.90
            ),
            "On · Warning 75% · Critical 90%"
        )
        XCTAssertEqual(
            SettingsCategorySummary.alerts(
                isEnabled: false,
                warningThreshold: 0.75,
                criticalThreshold: 0.90
            ),
            "Off"
        )
        XCTAssertEqual(
            SettingsCategorySummary.help(
                installedVersion: "Version 1.2",
                availableVersion: "1.3"
            ),
            "Version 1.3 available"
        )
        XCTAssertEqual(
            SettingsCategorySummary.help(
                installedVersion: "Version 1.2",
                availableVersion: nil
            ),
            "Version 1.2"
        )
    }

    func testSettingsRecoveryStateKeepsDestructiveSafeguardsAndProminentRouting() {
        let emptyState = SettingsRecoveryState(
            hasError: false,
            isPersistenceRecoveryRequired: false,
            accountCount: 0,
            hasIncompleteAccountReset: false
        )
        XCTAssertFalse(emptyState.requiresAttention)
        XCTAssertTrue(emptyState.resetAccountsDisabled)
        XCTAssertEqual(emptyState.summary, "No account data")

        let recoveryState = SettingsRecoveryState(
            hasError: true,
            isPersistenceRecoveryRequired: true,
            accountCount: 2,
            hasIncompleteAccountReset: true
        )
        XCTAssertTrue(recoveryState.requiresAttention)
        XCTAssertTrue(recoveryState.resetAccountsDisabled)
        XCTAssertEqual(recoveryState.summary, "Action required")

        let incompleteResetState = SettingsRecoveryState(
            hasError: false,
            isPersistenceRecoveryRequired: false,
            accountCount: 0,
            hasIncompleteAccountReset: true
        )
        XCTAssertTrue(incompleteResetState.requiresAttention)
        XCTAssertFalse(incompleteResetState.resetAccountsDisabled)
        XCTAssertEqual(incompleteResetState.summary, "Action required")

        let errorState = SettingsRecoveryState(
            hasError: true,
            isPersistenceRecoveryRequired: false,
            accountCount: 0,
            hasIncompleteAccountReset: false
        )
        XCTAssertTrue(errorState.requiresAttention)
        XCTAssertEqual(errorState.summary, "Review settings error")

        let populatedState = SettingsRecoveryState(
            hasError: false,
            isPersistenceRecoveryRequired: false,
            accountCount: 2,
            hasIncompleteAccountReset: false
        )
        XCTAssertFalse(populatedState.requiresAttention)
        XCTAssertFalse(populatedState.resetAccountsDisabled)
        XCTAssertEqual(populatedState.summary, "Reset and recovery options")
    }

    @MainActor
    func testRepeatedCodexSelectionCreatesExactlyOneAdditionalAccount() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: MemorySecretStore()
        )
        let existingAccount = try XCTUnwrap(store.addAccount(for: .codex))
        var flow = AddAccountFlowState()

        let addedAccountID = try XCTUnwrap(
            flow.select(.codex, configurationStore: store)
        )
        let repeatedSelectionID = flow.select(.codex, configurationStore: store)

        XCTAssertNotEqual(addedAccountID, existingAccount.id)
        XCTAssertEqual(repeatedSelectionID, addedAccountID)
        XCTAssertEqual(store.configurations(for: .codex).count, 2)
    }

    func testAddAccountRefreshStateKeepsExactTargetForLaterCredentialChanges() {
        var state = AddAccountRefreshState()

        XCTAssertNil(state.credentialsChanged())
        XCTAssertNil(state.finishDismissal())

        state.accountCreated("claude.personal")
        XCTAssertEqual(state.credentialsChanged(), "claude.personal")
        XCTAssertEqual(state.credentialsChanged(), "claude.personal")
        XCTAssertNil(state.finishDismissal())
        XCTAssertNil(state.accountID)

        state.accountCreated("openRouter.work")
        XCTAssertEqual(state.finishDismissal(), "openRouter.work")
        XCTAssertNil(state.finishDismissal())
    }

    func testDashboardCardMenuKeepsAccountConfigurationOnBalanceOnlyCards() {
        let balanceOnlyResult = ProviderUsageResult(
            accountID: "moonshot.balance",
            providerID: .moonshot,
            title: "Kimi",
            subtitle: "Credit balance",
            bars: [],
            creditsRemaining: 12.50,
            fetchedAt: Date()
        )
        let meteredResult = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "ChatGPT",
            subtitle: "Usage limits",
            bars: [UsageBar(label: "Weekly", used: 10, limit: 100)],
            fetchedAt: Date()
        )
        let multiMetricBalanceResult = ProviderUsageResult(
            accountID: "claude.personal",
            providerID: .claude,
            title: "Claude",
            subtitle: "Usage credits",
            bars: [],
            creditsRemaining: 12.50,
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .spendLimit,
                    label: "Monthly spend limit",
                    minorUnits: 2_000,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
            ],
            fetchedAt: Date()
        )
        let resultWithInformation = ProviderUsageResult(
            accountID: "claude.information",
            providerID: .claude,
            title: "Claude",
            subtitle: "Live Claude usage",
            bars: [],
            cardInformationSections: [
                ProviderCardInformationSection(
                    id: "claude.account-details",
                    title: "Account details",
                    items: [
                        ProviderCardInformationItem(
                            id: "claude.auto-reload",
                            label: "Auto-reload",
                            detail: "Off"
                        ),
                    ]
                ),
            ],
            fetchedAt: Date()
        )

        XCTAssertEqual(
            ProviderUsageCard.menuActions(for: balanceOnlyResult),
            [.configureAccount, .customizeMetrics]
        )
        XCTAssertEqual(
            ProviderUsageCard.menuActions(
                for: balanceOnlyResult,
                isMetricVisible: { _ in false }
            ),
            [.configureAccount, .customizeMetrics]
        )
        XCTAssertTrue(
            ProviderUsageCard.showsMetricVisibilityControls(
                for: balanceOnlyResult,
                isMetricVisible: { _ in false }
            )
        )
        XCTAssertFalse(
            ProviderUsageCard.showsMetricVisibilityControls(
                for: balanceOnlyResult,
                isMetricVisible: { _ in true }
            )
        )
        XCTAssertEqual(
            ProviderUsageCard.menuActions(for: meteredResult),
            [.moreInformation, .configureAccount, .customizeMetrics]
        )
        XCTAssertEqual(
            ProviderUsageCard.menuActions(for: multiMetricBalanceResult),
            [.moreInformation, .configureAccount, .customizeMetrics]
        )
        XCTAssertEqual(
            ProviderUsageCard.menuActions(for: resultWithInformation),
            [.moreInformation, .configureAccount]
        )
        XCTAssertEqual(
            ProviderUsageCard.informationSections(for: resultWithInformation).filter { $0.id != "subscription-renewal" },
            resultWithInformation.cardInformationSections
        )
        XCTAssertTrue(
            ProviderUsageCard.reconciledMoreInformationPresentation(
                currentlyPresented: true,
                sections: resultWithInformation.cardInformationSections
            )
        )
        XCTAssertFalse(
            ProviderUsageCard.reconciledMoreInformationPresentation(
                currentlyPresented: true,
                sections: []
            )
        )
        XCTAssertFalse(
            ProviderUsageCard.reconciledMoreInformationPresentation(
                currentlyPresented: false,
                sections: resultWithInformation.cardInformationSections
            )
        )
        XCTAssertEqual(
            ProviderUsageCard.metricVisibilityAccessibilityValue(isVisible: true),
            "Shown"
        )
        XCTAssertEqual(
            ProviderUsageCard.metricVisibilityAccessibilityValue(isVisible: false),
            "Hidden"
        )
    }

    func testUsageSeverityThresholds() {
        XCTAssertEqual(UsageSeverity(fractionUsed: 0.74), .normal)
        XCTAssertEqual(UsageSeverity(fractionUsed: 0.75), .warning)
        XCTAssertEqual(UsageSeverity(fractionUsed: 0.90), .critical)
    }

    func testProviderConfigurationDefaults() {
        XCTAssertEqual(
            ProviderAccountConfiguration.defaultConfiguration(for: .openRouter).authMethod,
            .apiKey
        )
        XCTAssertEqual(
            ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen).authMethod,
            .apiKey
        )
        XCTAssertEqual(
            ProviderAccountConfiguration.defaultConfiguration(for: .moonshot).authMethod,
            .apiKey
        )
        XCTAssertEqual(
            ProviderAccountConfiguration.defaultConfiguration(for: .copilot).authMethod,
            .browserSession
        )
        XCTAssertEqual(
            ProviderAccountConfiguration.defaultConfiguration(for: .codex).authMethod,
            .browserSession
        )
        XCTAssertEqual(
            ProviderAccountConfiguration.defaultConfiguration(for: .claude).authMethod,
            .browserSession
        )
        XCTAssertEqual(
            ProviderAccountConfiguration.defaultConfiguration(for: .cursor).authMethod,
            .browserSession
        )
    }

    func testAppStoreScreenshotConfigurationParsesSceneAndAppearance() {
        XCTAssertNil(AppStoreScreenshotConfiguration.parse(arguments: []))

        let configuration = AppStoreScreenshotConfiguration.parse(
            arguments: [
                "CodexBarIOS",
                "--app-store-screenshots",
                "--app-store-scene",
                "history",
                "--app-store-appearance",
                "dark",
                "--app-store-settle-seconds",
                "3.5",
            ]
        )

        XCTAssertEqual(configuration?.scene, .history)
        XCTAssertEqual(configuration?.appearance, .dark)
        XCTAssertEqual(configuration?.settleDelay, 3.5)

        let fallback = AppStoreScreenshotConfiguration.parse(
            arguments: ["CodexBarIOS"],
            environment: ["CODEXBAR_APP_STORE_SCREENSHOTS": "1"]
        )
        XCTAssertEqual(fallback?.scene, .dashboardOverview)
        XCTAssertEqual(fallback?.appearance, .light)
        XCTAssertEqual(fallback?.settleDelay, 2)
    }

    func testDashboardCardGridLayoutUsesContainerWidthAndAccessibilityFallbacks() {
        XCTAssertEqual(
            DashboardCardGridLayout.columnCount(
                containerWidth: 768,
                idiom: .pad,
                dynamicTypeSize: .large
            ),
            2
        )
        XCTAssertEqual(
            DashboardCardGridLayout.columnCount(
                containerWidth: 768,
                idiom: .pad,
                dynamicTypeSize: .large,
                hasCollapsedCard: true
            ),
            1,
            "A collapsed card must leave row-based grid sizing so it reclaims height."
        )
        XCTAssertEqual(
            DashboardCardGridLayout.columnCount(
                containerWidth: 700,
                idiom: .pad,
                dynamicTypeSize: .large
            ),
            1
        )
        XCTAssertEqual(
            DashboardCardGridLayout.columnCount(
                containerWidth: 1_366,
                idiom: .phone,
                dynamicTypeSize: .large
            ),
            1
        )
        XCTAssertEqual(
            DashboardCardGridLayout.columnCount(
                containerWidth: 1_366,
                idiom: .pad,
                dynamicTypeSize: .accessibility1
            ),
            1
        )
    }

    @MainActor
    func testAppStoreScreenshotFixturesCoverEveryProviderAndSeedHistory() {
        let configurationStore = ProviderConfigurationStore.appStoreScreenshotDemo()
        let results = AppStoreScreenshotFixtures.results(for: configurationStore)

        XCTAssertEqual(Set(results.map(\.providerID)), Set(ProviderID.allCases.filter { $0 != .antigravity && $0.isAvailableOnIPhone }))
        XCTAssertTrue(results.allSatisfy { $0.accountID.hasPrefix("app-store-screenshots.") })
        XCTAssertGreaterThanOrEqual(
            configurationStore.configurations.filter {
                $0.groupID == AppStoreScreenshotFixtureID.usageGroup
            }.count,
            2,
            "The deterministic iPad dashboard fixture should exercise a complete two-card row."
        )
        XCTAssertEqual(Set(results.map(\.fetchedAt)).count, 1)
        let claudeResult = results.first(where: { $0.providerID == .claude })
        XCTAssertEqual(claudeResult?.monetaryMetrics.count, 2)
        XCTAssertFalse(claudeResult?.usageMessages.isEmpty ?? true)
        XCTAssertFalse(
            claudeResult?.dashboardUsageMessages.contains("Usage credits are enabled.") ?? true
        )
        XCTAssertEqual(
            claudeResult?.cardInformationSections.first {
                $0.id == "claude.limit-details"
            }?.items.map(\.label),
            ["Fable weekly limit"]
        )
        XCTAssertEqual(
            claudeResult?.cardInformationSections.first {
                $0.id == "claude.account-details"
            }?.items.map(\.label),
            ["Usage credits", "Auto-reload"]
        )
        let openCodeResult = results.first(where: { $0.providerID == .openCodeZen })
        XCTAssertEqual(openCodeResult?.title, "OpenCode Go + Zen")
        XCTAssertFalse(openCodeResult?.bars.isEmpty ?? true)
        XCTAssertNotNil(openCodeResult?.creditsRemaining)
        let cursorResult = results.first(where: { $0.providerID == .cursor })
        XCTAssertEqual(cursorResult?.subtitle, "Cursor plan usage")
        XCTAssertEqual(
            cursorResult?.cardInformationSections.first?.items.map(\.label),
            ["Cursor Models", "Other Models"]
        )
        for providerID in [ProviderID.cursor, .openCodeZen, .copilot] {
            let safeProjection = results
                .first(where: { $0.providerID == providerID })?
                .bars
                .first(where: { $0.projectionDescription() != nil })
            XCTAssertEqual(
                safeProjection?.projectionDescription(),
                "Projected to stay under limit",
                "Expected deterministic safe projection detail for \(providerID.rawValue)"
            )
            XCTAssertNil(
                safeProjection?.dashboardProjectionDescription(),
                "Safe projection copy should be absent from the \(providerID.rawValue) dashboard card"
            )
        }

        let historyStore = AppStoreScreenshotFixtures.historyStore(for: results)
        guard let codexResult = results.first(where: { $0.providerID == .codex }) else {
            return XCTFail("Expected a Codex screenshot fixture")
        }
        let series = historyStore.historySeries(for: codexResult)
        XCTAssertEqual(series.points.count, 8)
        XCTAssertEqual(series.direction, .up)
    }

    func testInstalledAppVersionDisplaysOnlyMarketingVersion() {
        let version = InstalledAppVersion(marketingVersion: "1.1", buildNumber: "2")

        XCTAssertEqual(version.displayText, "Version 1.1")
    }

    func testAppVersionComparesDottedComponentsNumerically() throws {
        XCTAssertLessThan(try XCTUnwrap(AppVersion("1.9")), try XCTUnwrap(AppVersion("1.10")))
        XCTAssertEqual(try XCTUnwrap(AppVersion("1.2")), try XCTUnwrap(AppVersion("1.2.0")))
        XCTAssertGreaterThan(try XCTUnwrap(AppVersion("2.0")), try XCTUnwrap(AppVersion("1.99.99")))
        XCTAssertNil(AppVersion("1.2-beta"))
        XCTAssertNil(AppVersion("1..2"))
        XCTAssertNil(AppVersion(""))
    }

    func testAppStoreReleaseLookupDecodesReturnedURLAndUsesFallback() throws {
        let returnedURL = "https://apps.apple.com/de/app/codexbar/id6787769891?uo=4"
        let returnedRelease = try AppStoreReleaseService.decodeRelease(
            from: Data(
                """
                {"resultCount":1,"results":[{"version":"1.2","trackViewUrl":"\(returnedURL)"}]}
                """.utf8
            )
        )
        XCTAssertEqual(returnedRelease.version, "1.2")
        XCTAssertEqual(returnedRelease.productURL.absoluteString, returnedURL)

        let fallbackRelease = try AppStoreReleaseService.decodeRelease(
            from: Data(#"{"resultCount":1,"results":[{"version":"1.2","trackViewUrl":"invalid"}]}"#.utf8)
        )
        XCTAssertEqual(fallbackRelease.productURL, AppStoreReleaseService.fallbackProductURL)

        XCTAssertThrowsError(
            try AppStoreReleaseService.decodeRelease(
                from: Data(#"{"resultCount":0,"results":[]}"#.utf8)
            )
        ) { error in
            XCTAssertEqual(error as? AppStoreReleaseError, .missingRelease)
        }

        XCTAssertThrowsError(
            try AppStoreReleaseService.decodeRelease(from: Data("not-json".utf8))
        ) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testAppStoreReleaseServiceUsesIDLookupAndRejectsHTTPFailure() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppAndWidgetMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = AppStoreReleaseService(session: session)

        AppAndWidgetMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "itunes.apple.com")
            XCTAssertEqual(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                    .queryItemValue(named: "id"),
                "6787769891"
            )
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(
                    #"{"resultCount":1,"results":[{"version":"1.2","trackViewUrl":"https://apps.apple.com/us/app/id6787769891"}]}"#.utf8
                )
            )
        }
        defer {
            AppAndWidgetMockURLProtocol.handler = nil
        }

        let fetchedRelease = try await service.fetchRelease()
        XCTAssertEqual(fetchedRelease.version, "1.2")

        AppAndWidgetMockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }

        do {
            _ = try await service.fetchRelease()
            XCTFail("Expected an HTTP status error")
        } catch {
            XCTAssertEqual(error as? AppStoreReleaseError, .httpStatus(503))
        }
    }

    func testAppUpdateComparisonNeverOffersCurrentReleaseOrDowngrade() {
        let productURL = AppStoreReleaseService.fallbackProductURL

        XCTAssertNil(
            AppUpdateController.newerRelease(
                AppStoreRelease(version: "1.1", productURL: productURL),
                than: "1.1"
            )
        )
        XCTAssertNil(
            AppUpdateController.newerRelease(
                AppStoreRelease(version: "1.0", productURL: productURL),
                than: "1.1"
            )
        )
        XCTAssertEqual(
            AppUpdateController.newerRelease(
                AppStoreRelease(version: "1.10", productURL: productURL),
                than: "1.9"
            )?.version,
            "1.10"
        )
    }

    @MainActor
    func testAppUpdateControllerCachesAndRateLimitsSuccessfulChecks() async {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let release = AppStoreRelease(version: "1.2", productURL: AppStoreReleaseService.fallbackProductURL)
        let fetcher = StubAppStoreReleaseFetcher(result: .success(release))
        let installedVersion = InstalledAppVersion(marketingVersion: "1.1", buildNumber: "2")
        let checkInterval: TimeInterval = 2 * 60 * 60
        let controller = AppUpdateController(
            installedVersion: installedVersion,
            defaults: defaults,
            releaseFetcher: fetcher,
            checkInterval: checkInterval
        )

        await controller.checkForUpdates(at: now)

        XCTAssertEqual(controller.availableRelease, release)
        let initialFetchCount = await fetcher.currentFetchCount()
        XCTAssertEqual(initialFetchCount, 1)

        let reloadedController = AppUpdateController(
            installedVersion: installedVersion,
            defaults: defaults,
            releaseFetcher: fetcher,
            checkInterval: checkInterval
        )
        XCTAssertEqual(reloadedController.availableRelease, release)

        await reloadedController.checkForUpdates(at: now.addingTimeInterval(60 * 60))
        let rateLimitedFetchCount = await fetcher.currentFetchCount()
        XCTAssertEqual(rateLimitedFetchCount, 1)

        await reloadedController.checkForUpdates(force: true, at: now.addingTimeInterval(60 * 60))
        let forcedFetchCount = await fetcher.currentFetchCount()
        XCTAssertEqual(forcedFetchCount, 2)
    }

    @MainActor
    func testAppUpdateControllerFailsQuietlyAndDismissesOnlyDetectedVersion() async {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let firstRelease = AppStoreRelease(
            version: "1.2",
            productURL: AppStoreReleaseService.fallbackProductURL
        )
        let fetcher = StubAppStoreReleaseFetcher(result: .success(firstRelease))
        let controller = AppUpdateController(
            installedVersion: InstalledAppVersion(marketingVersion: "1.1", buildNumber: "2"),
            defaults: defaults,
            releaseFetcher: fetcher
        )

        await controller.checkForUpdates(at: now)
        controller.dismissDashboardNotice()

        XCTAssertEqual(controller.availableRelease, firstRelease)
        XCTAssertNil(controller.dashboardRelease)

        let reloadedController = AppUpdateController(
            installedVersion: InstalledAppVersion(marketingVersion: "1.1", buildNumber: "2"),
            defaults: defaults,
            releaseFetcher: fetcher
        )
        XCTAssertEqual(reloadedController.availableRelease, firstRelease)
        XCTAssertNil(reloadedController.dashboardRelease)

        await fetcher.setResult(.failure(.invalidResponse))
        await controller.checkForUpdates(force: true, at: now.addingTimeInterval(1))
        XCTAssertEqual(controller.availableRelease, firstRelease)
        XCTAssertNil(controller.dashboardRelease)

        let nextRelease = AppStoreRelease(
            version: "1.3",
            productURL: AppStoreReleaseService.fallbackProductURL
        )
        await fetcher.setResult(.success(nextRelease))
        await controller.checkForUpdates(force: true, at: now.addingTimeInterval(2))

        XCTAssertEqual(controller.availableRelease, nextRelease)
        XCTAssertEqual(controller.dashboardRelease, nextRelease)
    }

    func testAppReviewLinksTargetProductionListingAndSupport() {
        XCTAssertEqual(AppReviewLinks.writeReviewURL.host, "apps.apple.com")
        XCTAssertTrue(AppReviewLinks.writeReviewURL.path.hasSuffix("/id6787769891"))
        XCTAssertEqual(
            URLComponents(url: AppReviewLinks.writeReviewURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "action" })?.value,
            "write-review"
        )
        XCTAssertEqual(
            AppReviewLinks.supportURL.absoluteString,
            "https://github.com/hemsoft-dev/codexbar-ios/blob/main/SUPPORT.md"
        )
    }

    func testFeedbackSupportDestinationsIncludeEveryUserAction() {
        XCTAssertEqual(
            FeedbackSupportDestination.allCases,
            [
                .reportProblem,
                .suggestImprovement,
                .publicBugReport,
                .publicImprovement,
                .knownIssues,
                .supportGuide,
                .rateCodexBar,
            ]
        )
        XCTAssertEqual(
            Set(FeedbackSupportDestination.allCases.map(\.title)),
            [
                "Report a Problem",
                "Suggest an Improvement",
                "Public GitHub Bug Form",
                "Public GitHub Improvement Form",
                "View Known Issues",
                "Support Guide",
                "Rate CodexBar",
            ]
        )
        XCTAssertEqual(
            FeedbackSupportDestination.allCases.map(\.presentation),
            [
                .diagnosticPreview,
                .emailDetails,
                .external,
                .external,
                .external,
                .external,
                .external,
            ]
        )
    }

    func testFeedbackSupportURLsTargetEmailAndPublicGitHubForms() throws {
        let context = FeedbackSupportContext(
            appVersion: "1.2+beta",
            buildNumber: "42+7",
            operatingSystemName: "iPadOS",
            operatingSystemVersion: "26.1 (23B 12)",
            deviceCategory: "iPad"
        )

        let problemURL = FeedbackSupportDestination.reportProblem.url(context: context)
        let problemComponents = try XCTUnwrap(
            URLComponents(url: problemURL, resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(problemComponents.scheme, "mailto")
        XCTAssertEqual(problemComponents.path, FeedbackEmailDraft.recipient)
        XCTAssertEqual(
            problemComponents.queryItems?.first(where: { $0.name == "subject" })?.value,
            "[CodexBar Feedback] Problem Report"
        )
        XCTAssertTrue(
            try XCTUnwrap(
                problemComponents.queryItems?.first(where: { $0.name == "body" })?.value
            ).contains("Privacy-safe diagnostic:")
        )

        let improvementURL = FeedbackSupportDestination.suggestImprovement.url(context: context)
        let improvementComponents = try XCTUnwrap(
            URLComponents(url: improvementURL, resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(improvementComponents.scheme, "mailto")
        XCTAssertEqual(improvementComponents.path, FeedbackEmailDraft.recipient)
        XCTAssertEqual(
            improvementComponents.queryItems?.first(where: { $0.name == "subject" })?.value,
            "[CodexBar Feedback] Improvement Suggestion"
        )
        XCTAssertTrue(
            try XCTUnwrap(
                improvementComponents.queryItems?.first(where: { $0.name == "body" })?.value
            ).contains(context.systemDetails)
        )

        let publicProblemURL = FeedbackSupportDestination.publicBugReport.url(context: context)
        let publicProblemComponents = try XCTUnwrap(
            URLComponents(url: publicProblemURL, resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(publicProblemComponents.host, "github.com")
        XCTAssertEqual(publicProblemComponents.path, "/hemsoft-dev/codexbar-ios/issues/new")
        XCTAssertEqual(
            publicProblemComponents.queryItems?.first(where: { $0.name == "template" })?.value,
            "bug_report.yml"
        )
        XCTAssertEqual(
            publicProblemComponents.queryItems?
                .first(where: { $0.name == "system-details" })?.value,
            "CodexBar 1.2+beta (42+7), iPadOS 26.1 (23B 12), iPad"
        )
        XCTAssertTrue(
            try XCTUnwrap(publicProblemComponents.percentEncodedQuery).contains("%2B")
        )
        XCTAssertFalse(
            try XCTUnwrap(publicProblemComponents.percentEncodedQuery).contains("+")
        )

        let publicImprovementURL = FeedbackSupportDestination.publicImprovement.url(
            context: context
        )
        let publicImprovementComponents = try XCTUnwrap(
            URLComponents(url: publicImprovementURL, resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(publicImprovementComponents.host, "github.com")
        XCTAssertEqual(
            publicImprovementComponents.path,
            "/hemsoft-dev/codexbar-ios/issues/new"
        )
        XCTAssertEqual(
            publicImprovementComponents.queryItems?
                .first(where: { $0.name == "template" })?.value,
            "feature_request.yml"
        )
        XCTAssertEqual(
            publicImprovementComponents.queryItems?
                .first(where: { $0.name == "system-details" })?.value,
            context.systemDetails
        )
        XCTAssertTrue(
            try XCTUnwrap(publicImprovementComponents.percentEncodedQuery).contains("%2B")
        )

        let knownIssuesURL = FeedbackSupportDestination.knownIssues.url(context: context)
        let knownIssuesComponents = try XCTUnwrap(
            URLComponents(url: knownIssuesURL, resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(knownIssuesComponents.path, "/hemsoft-dev/codexbar-ios/issues")
        XCTAssertEqual(
            knownIssuesComponents.queryItems?.first(where: { $0.name == "q" })?.value,
            "is:issue is:open"
        )
        XCTAssertEqual(
            FeedbackSupportDestination.supportGuide.url(context: context),
            AppReviewLinks.supportURL
        )
        XCTAssertEqual(
            FeedbackSupportDestination.rateCodexBar.url(context: context),
            AppReviewLinks.writeReviewURL
        )
    }

    func testFeedbackEmailDraftsUseStableSubjectsAndStructuredEditableBodies() throws {
        let system = FeedbackSupportContext(
            appVersion: "1.2",
            buildNumber: "42",
            operatingSystemName: "iOS",
            operatingSystemVersion: "26.0",
            deviceCategory: "iPhone"
        )
        let diagnostic = PrivacySafeDiagnosticContext(
            system: system,
            surface: .authentication,
            providerID: .claude,
            technicalDetails: DiagnosticTechnicalDetails(
                authenticationMethod: .browserSession,
                isConfigured: true,
                isSecretPresent: true,
                failureCategory: .authentication,
                httpStatusCode: 401
            )
        )
        let problemDraft = FeedbackEmailDraft.problemReport(
            context: diagnostic,
            includeTechnicalDetails: true
        )
        let problemWithoutOptionalDetails = FeedbackEmailDraft.problemReport(
            context: diagnostic,
            includeTechnicalDetails: false
        )
        let improvementDraft = FeedbackEmailDraft.improvementSuggestion(context: system)

        XCTAssertEqual(FeedbackEmailDraft.recipient, "fphemmer@gmail.com")
        XCTAssertEqual(
            FeedbackEmailKind.allCases.map(\.subject),
            [
                "[CodexBar Feedback] Problem Report",
                "[CodexBar Feedback] Improvement Suggestion",
            ]
        )
        XCTAssertTrue(FeedbackEmailKind.allCases.allSatisfy {
            $0.subject.hasPrefix("[CodexBar Feedback]")
        })
        XCTAssertTrue(problemDraft.body.contains("What happened?"))
        XCTAssertTrue(problemDraft.body.contains("What did you expect?"))
        XCTAssertTrue(problemDraft.body.contains("Steps to reproduce:"))
        XCTAssertTrue(problemDraft.body.contains("Authentication method: Browser session"))
        XCTAssertTrue(problemDraft.body.contains("HTTP status: 401"))
        XCTAssertFalse(problemWithoutOptionalDetails.body.contains("Technical details:"))
        XCTAssertTrue(improvementDraft.body.contains("What would you like CodexBar to improve?"))
        XCTAssertTrue(improvementDraft.body.contains("How would this help?"))
        XCTAssertTrue(improvementDraft.body.contains(system.systemDetails))
        let privacyFooter = "CodexBar does not include credentials, tokens, cookies, account labels, account identifiers, "
            + "balances, usage history, raw provider responses or errors, widget selections, Apple Watch snapshots, "
            + "logs, or screenshots."
        XCTAssertTrue(problemDraft.body.hasSuffix(privacyFooter))
        XCTAssertTrue(improvementDraft.body.hasSuffix(privacyFooter))
        XCTAssertEqual(
            problemDraft.copyableFields.map(\.kind),
            [.recipient, .subject, .message]
        )
        XCTAssertEqual(
            problemDraft.copyableFields.map(\.value),
            [FeedbackEmailDraft.recipient, problemDraft.subject, problemDraft.body]
        )
        XCTAssertEqual(
            improvementDraft.copyableFields.map(\.value),
            [FeedbackEmailDraft.recipient, improvementDraft.subject, improvementDraft.body]
        )
        XCTAssertEqual(
            FeedbackEmailDraft.externalComposerPrivacyNotice,
            "Your mail app may display and use its currently selected sending account. Copy the fields below to avoid opening the mail app."
        )

        for draft in [problemDraft, improvementDraft] {
            XCTAssertTrue(draft.body.contains("opening the email composer does not send it"))
            let components = try XCTUnwrap(
                URLComponents(url: draft.url, resolvingAgainstBaseURL: false)
            )
            XCTAssertEqual(components.scheme, "mailto")
            XCTAssertEqual(components.path, FeedbackEmailDraft.recipient)
            XCTAssertNil(components.user)
            XCTAssertNil(components.password)
            XCTAssertNil(components.host)
            XCTAssertNil(components.port)
            XCTAssertNil(components.fragment)
            XCTAssertEqual(
                components.queryItems?.map(\.name),
                ["subject", "body"],
                "mailto query fields must match the exact privacy allowlist"
            )
            XCTAssertEqual(
                components.queryItems?.first(where: { $0.name == "subject" })?.value,
                draft.subject
            )
            XCTAssertEqual(
                components.queryItems?.first(where: { $0.name == "body" })?.value,
                draft.body
            )
            let forbiddenQueryFields = ["cc", "bcc", "from", "sender", "sender-account"]
            let generatedQueryFields = Set(
                components.queryItems?.map { $0.name.lowercased() } ?? []
            )
            XCTAssertTrue(generatedQueryFields.isDisjoint(with: forbiddenQueryFields))
            XCTAssertFalse(
                components.queryItems?
                    .compactMap(\.value)
                    .contains { $0.contains("selected-sender@example.invalid") }
                    ?? false
            )
        }
    }

    func testFeedbackEmailDraftsExcludeSensitiveDataAndRawProviderState() {
        let configuration = ProviderAccountConfiguration(
            id: "account-identifier",
            providerID: .copilot,
            accountLabel: "Personal Account selected-sender@example.invalid",
            authMethod: .browserSession,
            oauthClientID: "oauth-client-id",
            githubOrganization: "private-org"
        )
        let diagnostic = PrivacySafeDiagnosticContext(
            system: FeedbackSupportContext(
                appVersion: "1.2",
                buildNumber: "42",
                operatingSystemName: "iOS",
                operatingSystemVersion: "26.0",
                deviceCategory: "iPhone"
            ),
            surface: .dashboard,
            providerID: configuration.providerID,
            technicalDetails: DiagnosticTechnicalDetails.providerRefreshFailure(
                configuration: configuration,
                isConfigured: true,
                isSecretPresent: true,
                userVisibleMessage: "HTTP 401 bearer-token raw-provider-response",
                result: nil
            )
        )
        let draft = FeedbackEmailDraft.problemReport(
            context: diagnostic,
            includeTechnicalDetails: true
        )
        let sensitiveValues = [
            configuration.id,
            configuration.accountLabel,
            configuration.oauthClientID!,
            configuration.githubOrganization,
            "selected-sender@example.invalid",
            "bearer-token",
            "raw-provider-response",
        ]

        XCTAssertTrue(draft.body.contains("Failure category: Authentication"))
        XCTAssertTrue(draft.body.contains("HTTP status: 401"))
        for sensitiveValue in sensitiveValues {
            XCTAssertFalse(draft.body.contains(sensitiveValue))
            XCTAssertFalse(draft.url.absoluteString.contains(sensitiveValue))
        }
    }

    func testProblemReportProviderValuesMatchEveryIssueFormDropdownOption() {
        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues: ProviderID.allCases.map {
                    ($0, $0.problemReportFormValue)
                }
            ),
            [
                .codex: "ChatGPT / Codex",
                .claude: "Claude", .grok: "Grok", .xSubscription: "X Subscription",
                .cursor: "Cursor",
                .copilot: "GitHub Copilot", .githubBilling: "GitHub Billing",
                .openRouter: "OpenRouter",
                .openCodeZen: "OpenCode Go / Zen",
                .moonshot: "Moonshot (Kimi)",
                .greptile: "Greptile",
                .gemini: "Google Gemini",
                .antigravity: "Antigravity", .museCode: "Muse Code",
            ]
        )
    }

    func testFeedbackSupportURLsCannotIncludeAccountConfigurationOrSecrets() {
        let context = FeedbackSupportContext(
            appVersion: "1.2",
            buildNumber: "42",
            operatingSystemName: "iOS",
            operatingSystemVersion: "26.0",
            deviceCategory: "iPhone"
        )
        let seededSensitiveValues = [
            "sk-secret-api-key",
            "bearer-token",
            "selected-sender@example.invalid",
            "Personal Claude Account",
            "account-123",
        ]

        for destination in FeedbackSupportDestination.allCases {
            let url = destination.url(context: context).absoluteString
            for sensitiveValue in seededSensitiveValues {
                XCTAssertFalse(url.contains(sensitiveValue))
            }
        }
    }

    func testPrivacySafeDiagnosticBuilderIncludesEveryAllowlistedFieldDeterministically() {
        let context = PrivacySafeDiagnosticContext(
            system: FeedbackSupportContext(
                appVersion: "1.2+beta",
                buildNumber: "42+7",
                operatingSystemName: "iPadOS",
                operatingSystemVersion: "26.1 (23B12)",
                deviceCategory: "iPad"
            ),
            surface: .dashboard,
            providerID: .claude,
            technicalDetails: DiagnosticTechnicalDetails(
                authenticationMethod: .browserSession,
                isConfigured: true,
                isSecretPresent: false,
                failureCategory: .rateLimited,
                httpStatusCode: 429,
                refreshKind: .automatic,
                freshness: .stale,
                widgetState: .current,
                watchState: .phoneUnavailable
            )
        )

        XCTAssertEqual(
            PrivacySafeDiagnosticBuilder.summary(context: context),
            """
            CodexBar privacy-safe diagnostic
            App: 1.2+beta (42+7)
            Operating system: iPadOS 26.1 (23B12)
            Device: iPad
            Affected surface: Dashboard
            Provider: Claude
            Technical details:
            - Authentication method: Browser session
            - Configured: Yes
            - Secret present: No
            - Failure category: Rate limited
            - HTTP status: 429
            - Refresh: Automatic
            - Freshness: Stale
            - Widget state: Current
            - Apple Watch state: iPhone unavailable
            """
        )

        XCTAssertEqual(
            PrivacySafeDiagnosticBuilder.summary(
                context: context,
                includeTechnicalDetails: false
            ),
            """
            CodexBar privacy-safe diagnostic
            App: 1.2+beta (42+7)
            Operating system: iPadOS 26.1 (23B12)
            Device: iPad
            Affected surface: Dashboard
            Provider: Claude
            """
        )
    }

    func testPrivacySafeDiagnosticNeverEmitsSensitiveSurroundingStateOrRawErrors() throws {
        let configuration = ProviderAccountConfiguration(
            id: "persistent-account-123",
            providerID: .copilot,
            accountLabel: "Personal selected-sender@example.invalid",
            authMethod: .browserSession,
            oauthClientID: "oauth-client-secret",
            githubOrganization: "private-organization-456"
        )
        let rawError = """
        HTTP 401 Authorization: Bearer access-token refresh_token=refresh-secret
        https://provider.example/callback?code=oauth-code Cookie=session-cookie
        {"account_id":"account-123","balance":"$99.95","usage":87}
        """
        let sensitiveValues = [
            configuration.id,
            configuration.accountLabel,
            configuration.oauthClientID!,
            configuration.githubOrganization,
            "access-token",
            "refresh-secret",
            "oauth-code",
            "session-cookie",
            "provider.example",
            "account-123",
            "$99.95",
            "\"usage\":87",
        ]
        let statusCode = DiagnosticFailureCategory.safeHTTPStatusCode(
            userVisibleMessage: rawError
        )
        let context = PrivacySafeDiagnosticContext(
            system: FeedbackSupportContext(
                appVersion: "1.2",
                buildNumber: "42",
                operatingSystemName: "iOS",
                operatingSystemVersion: "26.0",
                deviceCategory: "iPhone"
            ),
            surface: .authentication,
            providerID: configuration.providerID,
            technicalDetails: DiagnosticTechnicalDetails(
                authenticationMethod: DiagnosticAuthenticationMethod(configuration.authMethod),
                isConfigured: true,
                isSecretPresent: true,
                failureCategory: DiagnosticFailureCategory.normalized(
                    httpStatusCode: try XCTUnwrap(statusCode)
                ),
                httpStatusCode: statusCode,
                refreshKind: .manual,
                freshness: .noSuccessfulRefresh
            )
        )

        let summary = PrivacySafeDiagnosticBuilder.summary(context: context)
        let launch = FeedbackSupportDestination.problemReportLaunch(
            context: context,
            includeTechnicalDetails: true
        )
        guard case .url(let url) = launch else {
            return XCTFail("Expected the bounded diagnostic to fit the issue-form URL.")
        }

        XCTAssertTrue(summary.contains("HTTP status: 401"))
        XCTAssertTrue(summary.contains("Failure category: Authentication"))
        for sensitiveValue in sensitiveValues {
            XCTAssertFalse(summary.contains(sensitiveValue))
            XCTAssertFalse(url.absoluteString.contains(sensitiveValue))
        }
        let components = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "affected-surface" })?.value,
            "Authentication"
        )
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "affected-provider" })?.value,
            "GitHub Copilot"
        )
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "privacy-safe-diagnostics" })?.value,
            summary
        )
        XCTAssertLessThanOrEqual(
            url.absoluteString.utf8.count,
            FeedbackSupportDestination.maximumPrefilledURLLength
        )
    }

    func testPrivacySafeDiagnosticNormalizesFailuresWithoutPassingRawText() throws {
        XCTAssertEqual(
            DiagnosticFailureCategory.normalized(error: URLError(.timedOut)),
            .timeout
        )
        XCTAssertEqual(
            DiagnosticFailureCategory.normalized(error: URLError(.notConnectedToInternet)),
            .connectivity
        )
        XCTAssertEqual(
            DiagnosticFailureCategory.normalized(error: URLError(.cancelled)),
            .cancelled
        )
        XCTAssertEqual(DiagnosticFailureCategory.normalized(httpStatusCode: 403), .authorization)
        XCTAssertEqual(DiagnosticFailureCategory.normalized(httpStatusCode: 429), .rateLimited)
        XCTAssertEqual(DiagnosticFailureCategory.normalized(httpStatusCode: 503), .server)
        XCTAssertEqual(
            DiagnosticFailureCategory.normalized(
                userVisibleMessage: "Keychain failed: password=must-not-leak"
            ),
            .localStorage
        )
        XCTAssertEqual(
            DiagnosticFailureCategory.safeHTTPStatusCode(
                userVisibleMessage: "Provider returned HTTP 503: raw body must-not-leak"
            ),
            503
        )
        XCTAssertNil(
            DiagnosticFailureCategory.safeHTTPStatusCode(
                userVisibleMessage: "https://example.test/path/503"
            )
        )
        XCTAssertNil(
            DiagnosticFailureCategory.safeHTTPStatusCode(
                userVisibleMessage: "Provider returned HTTP 5030"
            )
        )
        XCTAssertEqual(
            ProviderAuthMethod.allCases.map(DiagnosticAuthenticationMethod.init),
            [.apiKey, .browserSession, .cliToken]
        )

        do {
            _ = try JSONDecoder().decode(Int.self, from: Data(#""not-an-int""#.utf8))
            XCTFail("Expected decoding to fail.")
        } catch {
            XCTAssertEqual(DiagnosticFailureCategory.normalized(error: error), .invalidResponse)
        }
    }

    func testProviderRefreshFailureDiagnosticsUseReadinessAndMarkRetainedResultsStale() {
        let enabledButNotReady = ProviderAccountConfiguration(
            providerID: .claude,
            isEnabled: true,
            authMethod: .browserSession
        )
        let staleDetails = DiagnosticTechnicalDetails.providerRefreshFailure(
            configuration: enabledButNotReady,
            isConfigured: false,
            isSecretPresent: false,
            userVisibleMessage: "Provider returned HTTP 401: raw body must-not-leak",
            result: ProviderUsageResult(
                providerID: .claude,
                title: "Claude",
                subtitle: "Showing last known data",
                bars: [UsageBar(label: "Weekly", used: 1, limit: 10)],
                barsFetchedAt: Date(timeIntervalSince1970: 1_699_999_000),
                failureMessage: "Provider returned HTTP 401",
                hasSuccessfulRefreshHistory: true,
                fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        XCTAssertTrue(enabledButNotReady.isEnabled)
        XCTAssertEqual(staleDetails.isConfigured, false)
        XCTAssertEqual(staleDetails.isSecretPresent, false)
        XCTAssertEqual(staleDetails.failureCategory, .authentication)
        XCTAssertEqual(staleDetails.httpStatusCode, 401)
        XCTAssertEqual(staleDetails.freshness, .stale)

        let noResultDetails = DiagnosticTechnicalDetails.providerRefreshFailure(
            configuration: enabledButNotReady,
            isConfigured: false,
            isSecretPresent: false,
            userVisibleMessage: "Network connection failed",
            result: ProviderUsageResult(
                providerID: .claude,
                title: "Claude",
                subtitle: "Network connection failed",
                bars: [],
                failureMessage: "Network connection failed",
                fetchedAt: .distantPast
            )
        )
        XCTAssertEqual(noResultDetails.failureCategory, .connectivity)
        XCTAssertEqual(noResultDetails.freshness, .noSuccessfulRefresh)

        let partialFetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let currentPartialDetails = DiagnosticTechnicalDetails.providerRefreshFailure(
            configuration: enabledButNotReady,
            isConfigured: false,
            isSecretPresent: false,
            userVisibleMessage: "OpenCode Go usage could not be refreshed",
            result: ProviderUsageResult(
                providerID: .openCodeZen,
                title: "OpenCode Zen",
                subtitle: "Zen credit balance",
                bars: [],
                creditsRemaining: 5,
                failureMessage: "OpenCode Go usage could not be refreshed",
                preserveCachedBarsOnFailure: true,
                fetchedAt: partialFetchedAt
            )
        )
        XCTAssertEqual(currentPartialDetails.freshness, .current)

        let priorEmptySuccessDetails = DiagnosticTechnicalDetails.providerRefreshFailure(
            configuration: enabledButNotReady,
            isConfigured: false,
            isSecretPresent: false,
            userVisibleMessage: "Network connection failed",
            result: ProviderUsageResult(
                providerID: .claude,
                title: "Claude",
                subtitle: "Network connection failed. Showing last known data.",
                bars: [],
                failureMessage: "Network connection failed",
                hasSuccessfulRefreshHistory: true,
                fetchedAt: .distantPast
            )
        )
        XCTAssertEqual(priorEmptySuccessDetails.freshness, .stale)
    }

    func testPrivacySafeDiagnosticURLFallsBackToCopyWithoutExternalNavigation() {
        let context = PrivacySafeDiagnosticContext(
            system: FeedbackSupportContext(
                appVersion: "1.2",
                buildNumber: "42",
                operatingSystemName: "iOS",
                operatingSystemVersion: "26.0",
                deviceCategory: "iPhone"
            ),
            surface: .widget,
            providerID: nil,
            technicalDetails: DiagnosticTechnicalDetails(widgetState: .noData)
        )
        let expected = PrivacySafeDiagnosticBuilder.summary(context: context)

        XCTAssertEqual(
            FeedbackSupportDestination.problemReportLaunch(
                context: context,
                includeTechnicalDetails: true,
                maximumURLLength: 1
            ),
            .copyOnly(expected)
        )
        XCTAssertTrue(expected.contains("Affected surface: Widget"))
        XCTAssertTrue(expected.contains("Widget state: No data"))

        let watchContext = PrivacySafeDiagnosticContext(
            system: context.system,
            surface: .appleWatch,
            providerID: nil,
            technicalDetails: DiagnosticTechnicalDetails(watchState: .stale)
        )
        XCTAssertTrue(
            PrivacySafeDiagnosticBuilder.summary(context: watchContext)
                .contains("Apple Watch state: Stale")
        )
    }

    func testAppReviewPromptPolicyRequiresSustainedSuccessfulRefreshes() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let start = Date(timeIntervalSince1970: 1_788_475_200)
        let policy = AppReviewPromptPolicy(defaults: defaults, appVersion: "1.1")

        XCTAssertFalse(policy.registerSuccessfulRefresh(at: start))
        XCTAssertFalse(policy.registerSuccessfulRefresh(at: start.addingTimeInterval(24 * 60 * 60)))
        XCTAssertFalse(policy.registerSuccessfulRefresh(at: start.addingTimeInterval(3 * 24 * 60 * 60)))
        XCTAssertFalse(policy.registerSuccessfulRefresh(at: start.addingTimeInterval(6 * 24 * 60 * 60)))
        XCTAssertTrue(policy.registerSuccessfulRefresh(at: start.addingTimeInterval(7 * 24 * 60 * 60)))

        let reloadedPolicy = AppReviewPromptPolicy(defaults: defaults, appVersion: "1.1")
        XCTAssertFalse(reloadedPolicy.registerSuccessfulRefresh(at: start.addingTimeInterval(365 * 24 * 60 * 60)))
    }

    func testAppReviewPromptPolicyPersistsCooldownAcrossVersions() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let start = Date(timeIntervalSince1970: 1_788_475_200)
        let firstVersion = AppReviewPromptPolicy(
            defaults: defaults,
            appVersion: "1.1",
            minimumSuccessfulRefreshes: 1,
            minimumEngagementDuration: 0
        )
        XCTAssertTrue(firstVersion.registerSuccessfulRefresh(at: start))

        let nextVersion = AppReviewPromptPolicy(
            defaults: defaults,
            appVersion: "1.2",
            minimumSuccessfulRefreshes: 1,
            minimumEngagementDuration: 0
        )
        XCTAssertFalse(nextVersion.registerSuccessfulRefresh(at: start.addingTimeInterval(119 * 24 * 60 * 60)))
        XCTAssertTrue(nextVersion.registerSuccessfulRefresh(at: start.addingTimeInterval(120 * 24 * 60 * 60)))
    }

    func testAppReviewPromptEligibilityRequiresSuccessfulRefreshWithUsableData() {
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let emptyResult = ProviderUsageResult(
            providerID: .codex,
            title: "Codex",
            subtitle: "Usage",
            bars: [],
            fetchedAt: fetchedAt
        )
        let barsResult = ProviderUsageResult(
            providerID: .codex,
            title: "Codex",
            subtitle: "Usage",
            bars: [UsageBar(label: "Weekly", used: 1, limit: 10)],
            fetchedAt: fetchedAt
        )
        let creditsResult = ProviderUsageResult(
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Balance",
            bars: [],
            creditsRemaining: 5,
            fetchedAt: fetchedAt
        )
        let monetaryResult = ProviderUsageResult(
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Balance",
            bars: [],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .balance,
                    label: "Balance",
                    minorUnits: 500,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
            ],
            fetchedAt: fetchedAt
        )

        XCTAssertFalse(
            AppReviewPromptEligibility.hasSuccessfulUsage(lastRefreshError: "Offline", results: [barsResult])
        )
        XCTAssertFalse(AppReviewPromptEligibility.hasSuccessfulUsage(lastRefreshError: nil, results: []))
        XCTAssertFalse(AppReviewPromptEligibility.hasSuccessfulUsage(lastRefreshError: nil, results: [emptyResult]))
        XCTAssertTrue(AppReviewPromptEligibility.hasSuccessfulUsage(lastRefreshError: nil, results: [barsResult]))
        XCTAssertTrue(AppReviewPromptEligibility.hasSuccessfulUsage(lastRefreshError: nil, results: [creditsResult]))
        XCTAssertTrue(AppReviewPromptEligibility.hasSuccessfulUsage(lastRefreshError: nil, results: [monetaryResult]))
    }

    @MainActor
    func testAutoRefreshIntervalDefaultsToOffAndPersists() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: EmptySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        XCTAssertEqual(store.autoRefreshInterval, .off)

        store.updateAutoRefreshInterval(.fiveMinutes)

        let reloadedStore = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: EmptySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        XCTAssertEqual(reloadedStore.autoRefreshInterval, .fiveMinutes)
    }

    @MainActor
    func testHistorySamplingIntervalDefaultsToTwoHoursAndPersists() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: EmptySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        XCTAssertEqual(store.historySamplingInterval, .twoHours)

        store.updateHistorySamplingInterval(.fourHours)

        let reloadedStore = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: EmptySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        XCTAssertEqual(reloadedStore.historySamplingInterval, .fourHours)
    }

    @MainActor
    func testWidgetRefreshIntervalDefaultsToThirtyMinutesAndPersists() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: EmptySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        XCTAssertEqual(store.widgetRefreshInterval, .thirtyMinutes)

        store.updateWidgetRefreshInterval(.oneHour)

        let reloadedStore = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: EmptySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        XCTAssertEqual(reloadedStore.widgetRefreshInterval, .oneHour)
    }

    func testWidgetSnapshotStoreRoundTripsSnapshotAndRefreshInterval() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let generatedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let snapshot = CodexBarWidgetSnapshot(
            generatedAt: generatedAt,
            results: [
                CodexBarWidgetProviderSnapshot(
                    accountID: "openCodeZen",
                    providerID: "openCodeZen",
                    title: "OpenCode Zen",
                    subtitle: "Balance",
                    groupID: "work",
                    groupName: "Work",
                    bars: [
                        CodexBarWidgetUsageBarSnapshot(
                            id: "codex.personal.0.five-hour",
                            label: "5 hour usage limit",
                            fractionUsed: 0.25,
                            usageText: "25%",
                            resetDescription: "Resets 4h",
                            severity: .normal,
                            projectedFraction: 1,
                            projectionDescription: "Projected 100% at current pace - Limit hit Wed 11:00 PM local time - 1h early",
                            projectedSeverity: .critical
                        ),
                    ],
                    creditsRemaining: 42.25,
                    barsFetchedAt: generatedAt.addingTimeInterval(-120),
                    creditsFetchedAt: generatedAt.addingTimeInterval(-60),
                    fetchedAt: generatedAt,
                    severity: .critical
                ),
            ]
        )

        WidgetSnapshotStore.saveSnapshot(snapshot, defaults: defaults)
        WidgetSnapshotStore.saveRefreshInterval(.threeHours, defaults: defaults)

        let loadedSnapshot = WidgetSnapshotStore.loadSnapshot(defaults: defaults)
        XCTAssertEqual(loadedSnapshot, snapshot)
        XCTAssertNil(loadedSnapshot.results.first?.planIdentifier)
        XCTAssertEqual(
            loadedSnapshot.results.first?.barsFetchedAt,
            generatedAt.addingTimeInterval(-120)
        )
        XCTAssertEqual(
            loadedSnapshot.results.first?.creditsFetchedAt,
            generatedAt.addingTimeInterval(-60)
        )
        XCTAssertEqual(WidgetSnapshotStore.loadRefreshInterval(defaults: defaults), .threeHours)
    }

    func testWidgetSnapshotStoreUsesPreviewFixtureForWidgetGallery() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let storedSnapshot = CodexBarWidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_788_475_200),
            results: []
        )
        let storedBuilderConfiguration = CodexBarWidgetBuilderConfiguration(
            layout: .oneTile,
            selectedTileIDs: ["provider.real-account"]
        )
        WidgetSnapshotStore.saveSnapshot(storedSnapshot, defaults: defaults)
        WidgetSnapshotStore.saveBuilderConfiguration(storedBuilderConfiguration, defaults: defaults)

        XCTAssertEqual(
            WidgetSnapshotStore.loadSnapshot(forPreview: false, defaults: defaults),
            storedSnapshot
        )
        XCTAssertEqual(
            WidgetSnapshotStore.loadSnapshot(forPreview: true, defaults: defaults),
            .preview
        )
        XCTAssertEqual(
            WidgetSnapshotStore.loadBuilderConfiguration(forPreview: false, defaults: defaults),
            storedBuilderConfiguration
        )
        XCTAssertEqual(
            WidgetSnapshotStore.loadBuilderConfiguration(forPreview: true, defaults: defaults),
            .default
        )
        XCTAssertEqual(
            CodexBarWidgetSnapshot.preview.results.map(\.providerID),
            ["codex", "copilot", "claude", "cursor", "moonshot", "openCodeZen", "openRouter"]
        )
        let projectedPreviewBar = try? XCTUnwrap(
            CodexBarWidgetSnapshot.preview.results.first?.bars.first
        )
        XCTAssertEqual(projectedPreviewBar?.usageText, "27%")
        XCTAssertEqual(projectedPreviewBar?.projectedFraction, 1)
    }

    func testSharedWidgetRenderingMapsEveryProviderLogo() {
        XCTAssertEqual(CodexBarProviderLogo.assetName(for: "codex"), "CodexLogo")
        XCTAssertEqual(CodexBarProviderLogo.assetName(for: "copilot"), "CopilotLogo")
        XCTAssertEqual(CodexBarProviderLogo.assetName(for: "claude"), "ClaudeLogo")
        XCTAssertEqual(CodexBarProviderLogo.assetName(for: "cursor"), "CursorLogo")
        XCTAssertEqual(CodexBarProviderLogo.assetName(for: "moonshot"), "MoonshotLogo")
        XCTAssertEqual(CodexBarProviderLogo.assetName(for: "openCodeZen"), "OpenCodeZenLogo")
        XCTAssertEqual(CodexBarProviderLogo.assetName(for: "openRouter"), "OpenRouterLogo")
        XCTAssertNil(CodexBarProviderLogo.assetName(for: "unknown"))
    }

    func testWidgetSnapshotStoreRoundTripsBuilderConfiguration() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let configuration = CodexBarWidgetBuilderConfiguration(
            layout: .fourTiles,
            selectedTileIDs: [
                "bar.codex.personal.0.five-hour",
                "bar.codex.personal.1.weekly",
                nil,
                "provider.openRouter.work",
            ],
            displayModes: [.fullBar, .compactPercent, .automatic, .balanceOnly]
        )

        WidgetSnapshotStore.saveBuilderConfiguration(configuration, defaults: defaults)

        XCTAssertEqual(WidgetSnapshotStore.loadBuilderConfiguration(defaults: defaults), configuration)
    }

    func testWidgetBuilderConfigurationTreatsLayoutAndDisplayAsCustomizations() {
        XCTAssertFalse(CodexBarWidgetBuilderConfiguration.default.hasCustomizations)

        XCTAssertTrue(
            CodexBarWidgetBuilderConfiguration(layout: .twoTiles).hasCustomizations
        )
        XCTAssertTrue(
            CodexBarWidgetBuilderConfiguration(displayModes: [.fullBar]).hasCustomizations
        )
        XCTAssertTrue(
            CodexBarWidgetBuilderConfiguration(selectedTileIDs: [nil, "bar.codex.personal.0.five-hour"])
                .hasCustomizations
        )
    }

    func testWidgetSnapshotBuilderTilesIncludeProviderSummaryAndGranularBars() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let snapshot = CodexBarWidgetSnapshot(
            generatedAt: generatedAt,
            results: [
                CodexBarWidgetProviderSnapshot(
                    accountID: "codex.personal",
                    providerID: "codex",
                    title: "ChatGPT / Codex",
                    subtitle: "Personal",
                    bars: [
                        CodexBarWidgetUsageBarSnapshot(
                            id: "codex.personal.0.five-hour",
                            label: "5-hour",
                            fractionUsed: 0.42,
                            usageText: "42%",
                            resetDescription: "Resets 2h",
                            severity: .normal
                        ),
                        CodexBarWidgetUsageBarSnapshot(
                            id: "codex.personal.1.weekly",
                            label: "Weekly",
                            fractionUsed: 0.81,
                            usageText: "81%",
                            resetDescription: "Resets Sun",
                            severity: .warning
                        ),
                    ],
                    creditsRemaining: nil,
                    fetchedAt: generatedAt,
                    severity: .warning
                ),
                CodexBarWidgetProviderSnapshot(
                    accountID: "openRouter.work",
                    providerID: "openRouter",
                    title: "OpenRouter",
                    subtitle: "API Key",
                    bars: [],
                    creditsRemaining: 9.75,
                    fetchedAt: generatedAt,
                    severity: .normal
                ),
            ]
        )

        let tiles = snapshot.builderTiles

        XCTAssertEqual(
            tiles.map(\.id),
            [
                "provider.codex.personal",
                "bar.codex.personal.0.five-hour",
                "bar.codex.personal.1.weekly",
                "provider.openRouter.work",
            ]
        )
        XCTAssertEqual(try XCTUnwrap(tiles.first { $0.id == "provider.codex.personal" }).value, "81%")
        XCTAssertEqual(try XCTUnwrap(tiles.first { $0.id == "provider.openRouter.work" }).value, "$9.75")
    }

    func testWidgetSnapshotBuilderIncludesCurrencyAwareMonetaryTiles() throws {
        let snapshot = CodexBarWidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_788_475_200),
            results: [
                CodexBarWidgetProviderSnapshot(
                    accountID: "claude.personal",
                    providerID: "claude",
                    title: "Claude",
                    subtitle: "Live Claude usage",
                    bars: [],
                    creditsRemaining: nil,
                    monetaryMetrics: [
                        CodexBarWidgetMonetaryMetricSnapshot(
                            kind: ProviderMonetaryMetricKind.spent.rawValue,
                            label: "Usage credits spent",
                            minorUnits: 1250,
                            currencyCode: "EUR",
                            decimalPlaces: 2,
                            detail: "Month to date"
                        ),
                        CodexBarWidgetMonetaryMetricSnapshot(
                            kind: ProviderMonetaryMetricKind.remainingHeadroom.rawValue,
                            label: "Remaining spend headroom",
                            minorUnits: 0,
                            currencyCode: "EUR",
                            decimalPlaces: 2,
                            detail: "Not a prepaid balance"
                        ),
                    ],
                    fetchedAt: Date(timeIntervalSince1970: 1_788_475_200),
                    severity: .critical
                ),
            ]
        )

        let tile = try XCTUnwrap(snapshot.builderTiles.first { $0.id == "provider.claude.personal" })

        XCTAssertEqual(tile.title, "Usage credits spent")
        XCTAssertEqual(tile.subtitle, "Month to date")
        XCTAssertTrue(tile.value.contains("12"))
        XCTAssertTrue(tile.value.contains("50"))
        XCTAssertEqual(snapshot.results.first?.summaryMonetaryMetric?.label, "Usage credits spent")
        XCTAssertEqual(snapshot.results.first?.standaloneMonetaryMetrics.count, 1)
        XCTAssertEqual(snapshot.builderTiles.count, 2)
        XCTAssertEqual(snapshot.builderTiles.last?.severity, .critical)

        let malformedMetric = CodexBarWidgetMonetaryMetricSnapshot(
            kind: "spent",
            label: "Malformed persisted metric",
            minorUnits: 10,
            currencyCode: "USD",
            decimalPlaces: -1,
            detail: nil
        )
        XCTAssertFalse(malformedMetric.formattedAmount.isEmpty)
    }

    @MainActor
    func testWidgetSnapshotPublisherPropagatesProviderGroup() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let generatedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        let group = try XCTUnwrap(store.addGroup(named: "Work"))
        var configuration = try XCTUnwrap(store.addAccount(for: .openCodeZen))
        configuration.groupID = group.id
        configuration.openCodeWorkspaceId = "workspace"
        XCTAssertTrue(store.update(configuration))
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: "OpenCode Go + Zen",
            plan: ProviderPlanDescriptor(
                identifier: "test.business",
                displayLabel: "BUSINESS",
                accessibilityLabel: "Business"
            ),
            subtitle: "Balance",
            bars: [
                UsageBar(label: "Balance", used: 1, limit: 4),
            ],
            creditsRemaining: 12.25,
            fetchedAt: generatedAt
        )

        WidgetSnapshotPublisher.publish(
            results: [result],
            configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil)
        )

        let provider = try XCTUnwrap(WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first)
        XCTAssertEqual(provider.groupID, group.id)
        XCTAssertEqual(provider.groupName, "Work")
        XCTAssertNil(provider.planIdentifier)
        XCTAssertNil(provider.planDisplayLabel)
        XCTAssertNil(provider.planAccessibilityLabel)
    }

    @MainActor
    func testWidgetSnapshotPublisherUsesSmartDashboardOrdering() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let secretStore = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        var highBalanceConfiguration = try XCTUnwrap(store.addAccount(for: .openRouter))
        highBalanceConfiguration.accountLabel = "High Balance"
        XCTAssertTrue(store.update(highBalanceConfiguration))
        store.saveSecret("openrouter-high", for: highBalanceConfiguration)

        var lowBalanceConfiguration = try XCTUnwrap(store.addAccount(for: .openRouter))
        lowBalanceConfiguration.accountLabel = "Low Balance"
        XCTAssertTrue(store.update(lowBalanceConfiguration))
        store.saveSecret("openrouter-low", for: lowBalanceConfiguration)
        store.updateDashboardOrderingMode(.smart)

        let highBalance = ProviderUsageResult(
            accountID: highBalanceConfiguration.id,
            providerID: .openRouter,
            title: highBalanceConfiguration.displayName,
            subtitle: "Balance",
            bars: [],
            creditsRemaining: 50,
            fetchedAt: fetchedAt
        )
        let lowBalance = ProviderUsageResult(
            accountID: lowBalanceConfiguration.id,
            providerID: .openRouter,
            title: lowBalanceConfiguration.displayName,
            subtitle: "Balance",
            bars: [],
            creditsRemaining: 2,
            fetchedAt: fetchedAt
        )

        WidgetSnapshotPublisher.publish(
            results: [highBalance, lowBalance],
            configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil)
        )

        let snapshot = WidgetSnapshotStore.loadSnapshot(defaults: defaults)
        XCTAssertEqual(snapshot.results.map(\.accountID), [lowBalanceConfiguration.id, highBalanceConfiguration.id])
    }

    @MainActor
    func testWidgetSnapshotPublisherUsesConfigurationOrderWhenManualOrderIsEmpty() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let claude = try XCTUnwrap(store.addAccount(for: .claude))
        let openRouter = try XCTUnwrap(store.addAccount(for: .openRouter))
        store.saveSecret("claude-token", for: claude)
        store.saveSecret("openrouter-key", for: openRouter)
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let claudeResult = ProviderUsageResult(
            accountID: claude.id,
            providerID: .claude,
            title: claude.displayName,
            subtitle: "Fresh usage",
            bars: [],
            fetchedAt: fetchedAt
        )
        let openRouterResult = ProviderUsageResult(
            accountID: openRouter.id,
            providerID: .openRouter,
            title: openRouter.displayName,
            subtitle: "Fresh usage",
            bars: [],
            fetchedAt: fetchedAt
        )

        WidgetSnapshotPublisher.publish(
            results: [openRouterResult, claudeResult],
            configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil)
        )

        let snapshot = WidgetSnapshotStore.loadSnapshot(defaults: defaults)
        XCTAssertEqual(snapshot.results.map(\.accountID), [claude.id, openRouter.id])
    }

    @MainActor
    func testWidgetSnapshotPublisherNeutralizesStaleBarSeverityAndProjection() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let secretStore = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let configuration = try XCTUnwrap(store.addAccount(for: .claude))
        store.saveSecret("claude-token", for: configuration)
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .claude,
            title: configuration.displayName,
            subtitle: "Fresh monetary usage with cached rate limits",
            bars: [
                UsageBar(
                    label: "Weekly",
                    used: 95,
                    limit: 100,
                    projectionCurrent: 100,
                    projectionLimit: 100,
                    projectionPeriodStart: fetchedAt.addingTimeInterval(-60 * 60),
                    projectionPeriodEnd: fetchedAt.addingTimeInterval(60 * 60)
                ),
            ],
            barsFetchedAt: fetchedAt.addingTimeInterval(-60),
            fetchedAt: fetchedAt
        )

        WidgetSnapshotPublisher.publish(
            results: [result],
            configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil),
            now: fetchedAt
        )

        let provider = try XCTUnwrap(WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first)
        let bar = try XCTUnwrap(provider.bars.first)
        XCTAssertEqual(provider.severity, .normal)
        XCTAssertEqual(bar.severity, .normal)
        XCTAssertNil(bar.projectedFraction)
        XCTAssertNil(bar.projectedSeverity)
        XCTAssertEqual(provider.barsFetchedAt, fetchedAt.addingTimeInterval(-60))
        XCTAssertEqual(provider.fetchedAt, fetchedAt)
    }

    @MainActor
    func testOpenCodeGoProjectionSurvivesWidgetSerializationAndIsNeutralizedWhenStale() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let fetchedAt = Date(timeIntervalSince1970: 1_784_980_800)
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: MemorySecretStore()
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .openCodeZen))
        store.saveSecret("secret", for: configuration)
        let projectionBar = UsageBar(
            stableKey: "go.weekly",
            label: "Weekly usage limit",
            used: 40,
            limit: 100,
            resetsAt: fetchedAt.addingTimeInterval(129_600),
            projectionCurrent: 0.4,
            projectionLimit: 1,
            projectionPeriodStart: fetchedAt.addingTimeInterval(-475_200),
            projectionPeriodEnd: fetchedAt.addingTimeInterval(129_600),
            showProjectionOnCurrentBar: true
        )
        let freshResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: "OpenCode Go",
            subtitle: "OpenCode Go usage",
            bars: [projectionBar],
            fetchedAt: fetchedAt
        )

        WidgetSnapshotPublisher.publish(
            results: [freshResult],
            configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil),
            now: fetchedAt
        )

        let freshProvider = try XCTUnwrap(
            WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first
        )
        let freshBar = try XCTUnwrap(freshProvider.bars.first)
        XCTAssertEqual(try XCTUnwrap(freshBar.projectedFraction), 0.509_090, accuracy: 0.000_001)
        XCTAssertEqual(freshBar.projectionDescription, "Projected to stay under limit")
        XCTAssertNotNil(freshBar.projectedSeverity)

        let staleResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: "OpenCode Go",
            subtitle: "Showing cached Go usage",
            bars: [projectionBar],
            barsFetchedAt: fetchedAt.addingTimeInterval(-60),
            fetchedAt: fetchedAt
        )
        WidgetSnapshotPublisher.publish(
            results: [staleResult],
            configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil),
            now: fetchedAt
        )

        let staleProvider = try XCTUnwrap(
            WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first
        )
        let staleBar = try XCTUnwrap(staleProvider.bars.first)
        XCTAssertNil(staleBar.projectedFraction)
        XCTAssertNil(staleBar.projectionDescription)
        XCTAssertNil(staleBar.projectedSeverity)
    }

    @MainActor
    func testWidgetSnapshotPublisherOmitsCachedCreditsFromPartialRefresh() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        let configuration = try XCTUnwrap(store.addAccount(for: .openCodeZen))
        store.saveSecret("secret", for: configuration)
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: configuration.displayName,
            subtitle: "Fresh Go usage with cached Zen balance",
            bars: [UsageBar(stableKey: "go.weekly", label: "Weekly usage limit", used: 40, limit: 100)],
            creditsRemaining: 3,
            creditsFetchedAt: fetchedAt.addingTimeInterval(-60),
            fetchedAt: fetchedAt
        )

        WidgetSnapshotPublisher.publish(
            results: [result],
            configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil),
            now: fetchedAt
        )

        let provider = try XCTUnwrap(WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first)
        XCTAssertNil(provider.creditsRemaining)
        XCTAssertNil(provider.creditsFetchedAt)
        XCTAssertEqual(provider.barsFetchedAt, fetchedAt)
        XCTAssertEqual(provider.bars.map(\.usageText), ["40%"])
    }

    func testProviderAccountConfigurationDecodesLegacyAccountWithoutGroup() throws {
        let json = """
        {
          "id": "codex.personal",
          "providerID": "codex",
          "isEnabled": true,
          "accountLabel": "Personal",
          "authMethod": "browserSession"
        }
        """

        let configuration = try JSONDecoder().decode(
            ProviderAccountConfiguration.self,
            from: Data(json.utf8)
        )

        XCTAssertNil(configuration.groupID)
        XCTAssertTrue(configuration.showsHistory)
    }

    @MainActor
    func testProviderHistoryVisibilityPersistsIndependentlyAcrossAccounts() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        let group = try XCTUnwrap(store.addGroup(named: "Personal"))
        var codex = try XCTUnwrap(store.addAccount(for: .codex))
        let claude = try XCTUnwrap(store.addAccount(for: .claude))

        XCTAssertTrue(codex.showsHistory)
        XCTAssertTrue(claude.showsHistory)

        codex.showsHistory = false
        codex.accountLabel = "Primary Codex"
        codex.groupID = group.id
        XCTAssertTrue(store.update(codex))

        let reloadedStore = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        let reloadedCodex = try XCTUnwrap(reloadedStore.configuration(accountID: codex.id))
        let reloadedClaude = try XCTUnwrap(reloadedStore.configuration(accountID: claude.id))

        XCTAssertFalse(reloadedCodex.showsHistory)
        XCTAssertEqual(reloadedCodex.accountLabel, "Primary Codex")
        XCTAssertEqual(reloadedCodex.groupID, group.id)
        XCTAssertTrue(reloadedClaude.showsHistory)
    }

    func testWidgetSnapshotStoreDecodesLegacyUsageBarsWithoutProjectionFields() throws {
        let json = """
        {
          "generatedAt": 1788475200,
          "results": [
            {
              "accountID": "codex.personal",
              "providerID": "codex",
              "title": "Codex",
              "subtitle": "Pro",
              "bars": [
                {
                  "id": "codex.personal.0.five-hour",
                  "label": "5 hour usage limit",
                  "fractionUsed": 0.25,
                  "usageText": "25%",
                  "resetDescription": "Resets 4h",
                  "severity": "normal"
                }
              ],
              "creditsRemaining": null,
              "fetchedAt": 1788475200,
              "severity": "normal"
            }
          ]
        }
        """

        let snapshot = try JSONDecoder().decode(CodexBarWidgetSnapshot.self, from: Data(json.utf8))
        let bar = try XCTUnwrap(snapshot.results.first?.bars.first)

        XCTAssertNil(bar.projectedFraction)
        XCTAssertNil(bar.projectionDescription)
        XCTAssertNil(bar.projectedSeverity)
        XCTAssertEqual(bar.effectiveSeverity, .normal)
        XCTAssertEqual(bar.effectiveFractionUsed, 0.25)
        XCTAssertNil(snapshot.results.first?.monetaryMetrics)
        XCTAssertNil(snapshot.results.first?.usageMessages)
        XCTAssertNil(snapshot.results.first?.barsFetchedAt)
        XCTAssertNil(snapshot.results.first?.creditsFetchedAt)
        XCTAssertNil(snapshot.results.first?.monetaryMetricsFetchedAt)
    }

    @MainActor
    func testAppAppearanceDefaultsToSystemAndPersists() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(store.appAppearance, .system)

        store.updateAppAppearance(.dark)

        let reloadedStore = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(reloadedStore.appAppearance, .dark)
    }

    @MainActor
    func testDashboardCardOrderPersistsAndRemovesDuplicates() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        store.updateDashboardCardOrder(["claude", "codex", "claude", "copilot"])

        XCTAssertEqual(store.dashboardCardOrder, ["claude", "codex", "copilot"])

        let reloadedStore = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(reloadedStore.dashboardCardOrder, ["claude", "codex", "copilot"])
    }

    @MainActor
    func testDashboardOrderingModeDefaultsToManualAndPersists() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(store.dashboardOrderingMode, .manual)

        store.updateDashboardOrderingMode(.smart)

        let reloadedStore = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(reloadedStore.dashboardOrderingMode, .smart)
    }

    func testDashboardUsageSorterOrdersSmartResultsByUrgency() {
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let periodStart = now.addingTimeInterval(-2 * 60 * 60)
        let periodEnd = now.addingTimeInterval(3 * 60 * 60)
        let criticalProjection = makeHistoryResult(
            accountID: "critical.projection",
            providerID: .codex,
            fetchedAt: now,
            bars: [
                UsageBar(
                    label: "Weekly",
                    used: 20,
                    limit: 100,
                    projectionCurrent: 80,
                    projectionLimit: 100,
                    projectionPeriodStart: periodStart,
                    projectionPeriodEnd: periodEnd
                ),
            ]
        )
        let warningUsage = makeHistoryResult(
            accountID: "warning.usage",
            providerID: .codex,
            fetchedAt: now,
            used: 80
        )
        let lowBalance = makeHistoryResult(
            accountID: "balance.low",
            providerID: .openRouter,
            fetchedAt: now,
            creditsRemaining: 2
        )
        let highBalance = makeHistoryResult(
            accountID: "balance.high",
            providerID: .openRouter,
            fetchedAt: now,
            creditsRemaining: 20
        )
        let manualSecond = makeHistoryResult(
            accountID: "manual.second",
            providerID: .claude,
            fetchedAt: now,
            used: 20
        )
        let manualFirst = makeHistoryResult(
            accountID: "manual.first",
            providerID: .cursor,
            fetchedAt: now,
            used: 20
        )

        let ordered = DashboardUsageSorter.orderedResults(
            [manualSecond, highBalance, warningUsage, manualFirst, lowBalance, criticalProjection],
            mode: .smart,
            manualOrder: ["manual.first", "manual.second"],
            now: now
        )

        XCTAssertEqual(
            ordered.map(\.accountID),
            ["critical.projection", "warning.usage", "balance.low", "balance.high", "manual.first", "manual.second"]
        )
    }

    func testDashboardUsageSorterUsesConfiguredSeverityThresholds() {
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let lowBalanceAtSeventyPercent = makeHistoryResult(
            accountID: "low-balance.seventy-percent",
            providerID: .openRouter,
            fetchedAt: now,
            used: 70,
            creditsRemaining: 2
        )
        let highBalanceAtEightyPercent = makeHistoryResult(
            accountID: "high-balance.eighty-percent",
            providerID: .openRouter,
            fetchedAt: now,
            used: 80,
            creditsRemaining: 20
        )
        let results = [
            lowBalanceAtSeventyPercent,
            highBalanceAtEightyPercent,
        ]

        XCTAssertEqual(
            DashboardUsageSorter.orderedResults(
                results,
                mode: .smart,
                manualOrder: [],
                now: now
            ).map(\.accountID),
            [
                "high-balance.eighty-percent",
                "low-balance.seventy-percent",
            ]
        )
        XCTAssertEqual(
            DashboardUsageSorter.orderedResults(
                results,
                mode: .smart,
                manualOrder: [],
                now: now,
                severityThresholds: UsageSeverityThresholds(
                    warning: 0.65,
                    critical: 0.90
                )
            ).map(\.accountID),
            [
                "low-balance.seventy-percent",
                "high-balance.eighty-percent",
            ]
        )
    }

    func testDashboardUsageSorterIgnoresStaleBarUrgency() {
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let staleCritical = ProviderUsageResult(
            accountID: "stale.critical",
            providerID: .claude,
            title: "Claude",
            subtitle: "Cached rate limits",
            bars: [UsageBar(label: "Weekly", used: 95, limit: 100)],
            barsFetchedAt: now.addingTimeInterval(-60),
            fetchedAt: now
        )
        let freshWarning = makeHistoryResult(
            accountID: "fresh.warning",
            providerID: .codex,
            fetchedAt: now,
            used: 80
        )

        XCTAssertEqual(staleCritical.highestSeverity(at: now), .normal)
        let ordered = DashboardUsageSorter.orderedResults(
            [staleCritical, freshWarning],
            mode: .smart,
            manualOrder: [],
            now: now
        )
        XCTAssertEqual(ordered.map(\.accountID), ["fresh.warning", "stale.critical"])
    }

    func testDashboardUsageSorterKeepsManualOrderingWhenManualModeIsSelected() {
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let critical = makeHistoryResult(
            accountID: "critical",
            providerID: .codex,
            fetchedAt: now,
            used: 95
        )
        let normal = makeHistoryResult(
            accountID: "normal",
            providerID: .cursor,
            fetchedAt: now,
            used: 10
        )

        let ordered = DashboardUsageSorter.orderedResults(
            [critical, normal],
            mode: .manual,
            manualOrder: ["normal", "critical"],
            now: now
        )

        XCTAssertEqual(ordered.map(\.accountID), ["normal", "critical"])
    }

    func testDashboardUsageSorterKeepsExhaustedProjectionsAheadOfFutureHits() {
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let periodStart = now.addingTimeInterval(-60 * 60)
        let periodEnd = now.addingTimeInterval(4 * 60 * 60)
        let exhausted = makeHistoryResult(
            accountID: "projection.exhausted",
            providerID: .codex,
            fetchedAt: now,
            bars: [
                UsageBar(
                    label: "Weekly",
                    used: 100,
                    limit: 100,
                    projectionCurrent: 120,
                    projectionLimit: 100,
                    projectionPeriodStart: periodStart,
                    projectionPeriodEnd: periodEnd
                ),
            ]
        )
        let futureHit = makeHistoryResult(
            accountID: "projection.future",
            providerID: .codex,
            fetchedAt: now,
            bars: [
                UsageBar(
                    label: "Weekly",
                    used: 95,
                    limit: 100,
                    projectionCurrent: 80,
                    projectionLimit: 100,
                    projectionPeriodStart: periodStart,
                    projectionPeriodEnd: periodEnd
                ),
            ]
        )

        let ordered = DashboardUsageSorter.orderedResults(
            [futureHit, exhausted],
            mode: .smart,
            manualOrder: [],
            now: now
        )

        XCTAssertEqual(ordered.map(\.accountID), ["projection.exhausted", "projection.future"])
    }

    func testDashboardUsageSorterPrioritizesProjectionHittingExactlyAtPeriodEnd() {
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let periodStart = now.addingTimeInterval(-2 * 60 * 60)
        let periodEnd = now.addingTimeInterval(2 * 60 * 60)
        let noProjection = makeHistoryResult(
            accountID: "projection.none",
            fetchedAt: now,
            used: 100
        )
        let boundaryHit = makeHistoryResult(
            accountID: "projection.boundary",
            fetchedAt: now,
            bars: [
                UsageBar(
                    label: "Weekly",
                    used: 100,
                    limit: 100,
                    projectionCurrent: 50,
                    projectionLimit: 100,
                    projectionPeriodStart: periodStart,
                    projectionPeriodEnd: periodEnd
                ),
            ]
        )

        let orderedFromMissingProjection = DashboardUsageSorter.orderedResults(
            [noProjection, boundaryHit],
            mode: .smart,
            manualOrder: [],
            now: now
        )
        let orderedFromBoundaryProjection = DashboardUsageSorter.orderedResults(
            [boundaryHit, noProjection],
            mode: .smart,
            manualOrder: [],
            now: now
        )

        XCTAssertEqual(
            orderedFromMissingProjection.map(\.accountID),
            ["projection.boundary", "projection.none"]
        )
        XCTAssertEqual(
            orderedFromBoundaryProjection.map(\.accountID),
            ["projection.boundary", "projection.none"]
        )
    }

    func testDashboardUsageSorterOrdersProjectedFractionsWhenLimitsAreNotReached() {
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let periodStart = now.addingTimeInterval(-60 * 60)
        let periodEnd = now.addingTimeInterval(60 * 60)
        let lowerProjection = makeHistoryResult(
            accountID: "projection.lower",
            fetchedAt: now,
            bars: [
                UsageBar(
                    label: "Weekly",
                    used: 10,
                    limit: 100,
                    projectionCurrent: 20,
                    projectionLimit: 100,
                    projectionPeriodStart: periodStart,
                    projectionPeriodEnd: periodEnd
                ),
            ]
        )
        let higherProjection = makeHistoryResult(
            accountID: "projection.higher",
            fetchedAt: now,
            bars: [
                UsageBar(
                    label: "Weekly",
                    used: 10,
                    limit: 100,
                    projectionCurrent: 30,
                    projectionLimit: 100,
                    projectionPeriodStart: periodStart,
                    projectionPeriodEnd: periodEnd
                ),
            ]
        )

        let ordered = DashboardUsageSorter.orderedResults(
            [lowerProjection, higherProjection],
            mode: .smart,
            manualOrder: [],
            now: now
        )

        XCTAssertEqual(ordered.map(\.accountID), ["projection.higher", "projection.lower"])
    }

    func testDashboardUsageSorterPreservesEqualScoresAndIgnoresInvalidProjections() {
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let plain = makeHistoryResult(accountID: "plain", fetchedAt: now, used: 20)
        let zeroLimit = makeHistoryResult(
            accountID: "projection.zero-limit",
            fetchedAt: now,
            bars: [
                UsageBar(
                    label: "Weekly",
                    used: 20,
                    limit: 100,
                    projectionCurrent: 20,
                    projectionLimit: 0,
                    projectionPeriodStart: now.addingTimeInterval(-60 * 60),
                    projectionPeriodEnd: now.addingTimeInterval(60 * 60)
                ),
            ]
        )
        let zeroElapsed = makeHistoryResult(
            accountID: "projection.zero-elapsed",
            fetchedAt: now,
            bars: [
                UsageBar(
                    label: "Weekly",
                    used: 20,
                    limit: 100,
                    projectionCurrent: 20,
                    projectionLimit: 100,
                    projectionPeriodStart: now,
                    projectionPeriodEnd: now.addingTimeInterval(60 * 60)
                ),
            ]
        )

        let ordered = DashboardUsageSorter.orderedResults(
            [plain, zeroLimit, zeroElapsed],
            mode: .smart,
            manualOrder: [],
            now: now
        )

        XCTAssertEqual(
            ordered.map(\.accountID),
            ["plain", "projection.zero-limit", "projection.zero-elapsed"]
        )
    }

    func testDashboardUsageSorterUsesElapsedRateToOrderLimitHits() {
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let periodEnd = now.addingTimeInterval(8 * 60 * 60)
        let longerElapsed = makeHistoryResult(
            accountID: "projection.longer-elapsed",
            fetchedAt: now,
            bars: [
                UsageBar(
                    label: "Weekly",
                    used: 100,
                    limit: 100,
                    projectionCurrent: 50,
                    projectionLimit: 100,
                    projectionPeriodStart: now.addingTimeInterval(-4 * 60 * 60),
                    projectionPeriodEnd: periodEnd
                ),
            ]
        )
        let shorterElapsed = makeHistoryResult(
            accountID: "projection.shorter-elapsed",
            fetchedAt: now,
            bars: [
                UsageBar(
                    label: "Weekly",
                    used: 100,
                    limit: 100,
                    projectionCurrent: 25,
                    projectionLimit: 100,
                    projectionPeriodStart: now.addingTimeInterval(-60 * 60),
                    projectionPeriodEnd: periodEnd
                ),
            ]
        )

        let ordered = DashboardUsageSorter.orderedResults(
            [longerElapsed, shorterElapsed],
            mode: .smart,
            manualOrder: [],
            now: now
        )

        XCTAssertEqual(
            ordered.map(\.accountID),
            ["projection.shorter-elapsed", "projection.longer-elapsed"]
        )
    }

    @MainActor
    func testProviderGroupsPersistAndAssignAccounts() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        let group = store.addGroup(named: " Work ")
        var account = try XCTUnwrap(store.addAccount(for: .codex))
        account.groupID = group?.id

        XCTAssertTrue(store.update(account))

        let reloadedStore = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(reloadedStore.groups.map(\.name), ["Work"])
        XCTAssertEqual(reloadedStore.configuration(accountID: account.id)?.groupID, group?.id)
    }

    @MainActor
    func testRemovingProviderGroupUngroupsAssignedAccounts() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        let group = try XCTUnwrap(store.addGroup(named: "Relias"))
        var account = try XCTUnwrap(store.addAccount(for: .copilot))
        account.groupID = group.id
        XCTAssertTrue(store.update(account))

        store.removeGroup(group)

        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertNil(store.configuration(accountID: account.id)?.groupID)

        let reloadedStore = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertNil(reloadedStore.configuration(accountID: account.id)?.groupID)
    }

    @MainActor
    func testProviderGroupNamesMustBeUnique() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())

        XCTAssertNotNil(store.addGroup(named: "Engineering"))
        XCTAssertNil(store.addGroup(named: " engineering "))
        XCTAssertEqual(store.lastError, "Group names must be unique.")

        store.clearLastError(ifMatching: "A different error")
        XCTAssertEqual(store.lastError, "Group names must be unique.")

        store.clearLastError(ifMatching: "Group names must be unique.")
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testProviderConfigurationsSortByGroupName() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        let beta = try XCTUnwrap(store.addGroup(named: "Beta"))
        let alpha = try XCTUnwrap(store.addGroup(named: "Alpha"))
        let ungrouped = try XCTUnwrap(store.addAccount(for: .openRouter))
        var betaAccount = try XCTUnwrap(store.addAccount(for: .codex))
        var alphaAccount = try XCTUnwrap(store.addAccount(for: .claude))
        betaAccount.groupID = beta.id
        alphaAccount.groupID = alpha.id

        XCTAssertTrue(store.update(betaAccount))
        XCTAssertTrue(store.update(alphaAccount))

        XCTAssertEqual(
            store.configurations.map(\.id),
            [ungrouped.id, alphaAccount.id, betaAccount.id]
        )

        var renamedBeta = beta
        renamedBeta.name = "Aardvark"
        XCTAssertTrue(store.updateGroup(renamedBeta))

        XCTAssertEqual(
            store.configurations.map(\.id),
            [ungrouped.id, betaAccount.id, alphaAccount.id]
        )
    }

    func testMetricVisualizationStyleDecodesUnknownFutureValuesAsAutomatic() throws {
        let decoded = try JSONDecoder().decode(
            MetricVisualizationStyle.self,
            from: Data("\"future-hologram\"".utf8)
        )

        XCTAssertEqual(decoded, .automatic)
        XCTAssertEqual(
            MetricVisualizationStyle.allCases.map(\.displayName),
            [
                "Automatic",
                "Linear bar",
                "Segmented bar",
                "Circular ring",
                "Semicircular dial",
                "Large numeric",
            ]
        )
        XCTAssertEqual(MetricVisualizationStyle.automatic.resolvedForWidget(allowsGauge: true), .linearBar)
        XCTAssertEqual(MetricVisualizationStyle.circularRing.resolvedForWidget(allowsGauge: false), .linearBar)
        XCTAssertEqual(MetricVisualizationStyle.semicircularDial.resolvedForWidget(allowsGauge: false), .linearBar)
        XCTAssertEqual(MetricVisualizationStyle.segmentedBar.resolvedForWidget(allowsGauge: false), .segmentedBar)
        XCTAssertEqual(MetricVisualizationStyle.largeNumeric.resolvedForWidget(allowsGauge: true), .largeNumeric)
    }

    func testMetricTileWidthResolutionHonorsDefaultsOverridesAndAccessibilityCollapse() {
        XCTAssertEqual(
            ProviderMetricTileGridResolver.resolvedWidth(
                preference: .automatic,
                kind: .usageBar(index: 0),
                visualizationStyle: .linearBar,
                usesRegularHorizontalSizeClass: false,
                collapsesToSingleColumn: false
            ),
            .full
        )
        XCTAssertEqual(
            ProviderMetricTileGridResolver.resolvedWidth(
                preference: .automatic,
                kind: .usageBar(index: 0),
                visualizationStyle: .circularRing,
                usesRegularHorizontalSizeClass: false,
                collapsesToSingleColumn: false
            ),
            .half
        )
        XCTAssertEqual(
            ProviderMetricTileGridResolver.resolvedWidth(
                preference: .automatic,
                kind: .usageBar(index: 0),
                visualizationStyle: .automatic,
                usesRegularHorizontalSizeClass: true,
                collapsesToSingleColumn: false
            ),
            .half
        )
        XCTAssertEqual(
            ProviderMetricTileGridResolver.resolvedWidth(
                preference: .automatic,
                kind: .creditsRemaining,
                visualizationStyle: .automatic,
                usesRegularHorizontalSizeClass: false,
                collapsesToSingleColumn: false
            ),
            .half
        )
        XCTAssertEqual(
            ProviderMetricTileGridResolver.resolvedWidth(
                preference: .full,
                kind: .monetary(index: 0),
                visualizationStyle: .automatic,
                usesRegularHorizontalSizeClass: false,
                collapsesToSingleColumn: false
            ),
            .full
        )
        XCTAssertEqual(
            ProviderMetricTileGridResolver.resolvedWidth(
                preference: .half,
                kind: .usageBar(index: 0),
                visualizationStyle: .linearBar,
                usesRegularHorizontalSizeClass: false,
                collapsesToSingleColumn: false
            ),
            .half
        )
        XCTAssertEqual(
            ProviderMetricTileGridResolver.resolvedWidth(
                preference: .half,
                kind: .usageBar(index: 0),
                visualizationStyle: .linearBar,
                usesRegularHorizontalSizeClass: false,
                collapsesToSingleColumn: true
            ),
            .full
        )
    }

    func testSemicircularMetricTilesShowOneValueAndKeepOneAccessibilitySummary() {
        XCTAssertFalse(MetricVisualizationStyle.semicircularDial.showsStandaloneMetricTileValue)
        XCTAssertTrue(
            MetricVisualizationStyle.allCases
                .filter { $0 != .semicircularDial }
                .allSatisfy(\.showsStandaloneMetricTileValue)
        )

        let bar = UsageBar(
            stableKey: "session",
            label: "Current session",
            used: 42,
            limit: 100
        )
        let result = ProviderUsageResult(
            accountID: "claude.work",
            providerID: .claude,
            title: "Claude",
            subtitle: "Claude usage",
            bars: [bar],
            fetchedAt: Date()
        )
        let accessibilityLabel = ProviderUsageCard.usageMetricAccessibilityLabel(bar, in: result)
        XCTAssertEqual(
            accessibilityLabel.components(separatedBy: bar.usageText).count - 1,
            1
        )
        XCTAssertTrue(accessibilityLabel.hasPrefix("Current session, 42%"))
    }

    func testMetricTileAccessibilityOmitsBenignProjectionButKeepsWarning() {
        let now = Date()
        let start = now.addingTimeInterval(-24 * 60 * 60)
        let end = now.addingTimeInterval(6 * 24 * 60 * 60)
        let safeBar = UsageBar(
            label: "API",
            used: 5,
            limit: 100,
            projectionCurrent: 0.05,
            projectionLimit: 1,
            projectionPeriodStart: start,
            projectionPeriodEnd: end,
            showProjectionOnCurrentBar: true
        )
        let warningBar = UsageBar(
            label: "Total",
            used: 80,
            limit: 100,
            projectionCurrent: 0.8,
            projectionLimit: 1,
            projectionPeriodStart: start,
            projectionPeriodEnd: end,
            showProjectionOnCurrentBar: true
        )
        let result = ProviderUsageResult(
            accountID: "cursor.accessibility",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Cursor plan usage",
            bars: [safeBar, warningBar],
            fetchedAt: now
        )

        let safeLabel = ProviderUsageCard.usageMetricAccessibilityLabel(safeBar, in: result)
        let warningLabel = ProviderUsageCard.usageMetricAccessibilityLabel(warningBar, in: result)

        XCTAssertFalse(safeLabel.contains("Projected to stay under limit"))
        XCTAssertTrue(warningLabel.contains("Projected 100% at current pace"))
    }

    func testSemicircularMetricTilesPairAtCompactWidthsAndCollapseForAccessibilitySizes() {
        XCTAssertEqual(
            ProviderMetricTileGridResolver.resolvedWidth(
                preference: .automatic,
                kind: .usageBar(index: 0),
                visualizationStyle: .semicircularDial,
                usesRegularHorizontalSizeClass: false,
                collapsesToSingleColumn: false
            ),
            .half
        )
        XCTAssertEqual(
            ProviderMetricTileGridResolver.resolvedWidth(
                preference: .automatic,
                kind: .usageBar(index: 0),
                visualizationStyle: .semicircularDial,
                usesRegularHorizontalSizeClass: false,
                collapsesToSingleColumn: true
            ),
            .full
        )
    }

    func testSemicircularDialContentFrameCentersFixedDialAcrossTileWidths() {
        for tileWidth: CGFloat in [154, 318] {
            let tileBounds = CGRect(x: 12, y: 8, width: tileWidth, height: 58)
            let frame = SemicircularUsageDialLayout.contentFrame(
                contentSize: SemicircularUsageDialLayout.contentSize,
                in: tileBounds
            )

            XCTAssertEqual(
                frame.midX,
                tileBounds.midX,
                accuracy: 0.001
            )
            XCTAssertEqual(frame.minY, tileBounds.minY)
            XCTAssertGreaterThanOrEqual(frame.minX, tileBounds.minX)
            XCTAssertLessThanOrEqual(frame.maxX, tileBounds.maxX)
        }
    }

    func testSemicircularDialValuesFitAtNormalAndAccessibilityTextSizes() {
        let valueTexts = ["0%", "42%", "100%"]
        let contentSizeCategories: [UIContentSizeCategory] = [
            .extraSmall,
            .large,
            .extraExtraExtraLarge,
            .accessibilityMedium,
            .accessibilityExtraExtraExtraLarge,
        ]

        for category in contentSizeCategories {
            let traits = UITraitCollection(preferredContentSizeCategory: category)
            let preferredCaptionFont = UIFont.preferredFont(
                forTextStyle: .caption1,
                compatibleWith: traits
            )
            let dialFont = UIFont.systemFont(
                ofSize: preferredCaptionFont.pointSize,
                weight: .semibold
            )

            for valueText in valueTexts {
                let unscaledWidth = (valueText as NSString).size(
                    withAttributes: [.font: dialFont]
                ).width
                XCTAssertLessThanOrEqual(
                    unscaledWidth * SemicircularUsageDialLayout.valueMinimumScaleFactor,
                    SemicircularUsageDialLayout.valueMaxWidth,
                    "\(valueText) should fit at \(category.rawValue) after the dial's minimum scale"
                )
            }
        }
    }

    func testMetricTileRowsPackInSavedOrderWithoutAvoidableHoles() {
        let metrics = [
            ProviderUsageMetric(id: "a", label: "A", kind: .usageBar(index: 0)),
            ProviderUsageMetric(id: "b", label: "B", kind: .creditsRemaining),
            ProviderUsageMetric(id: "c", label: "C", kind: .monetary(index: 0)),
            ProviderUsageMetric(id: "d", label: "D", kind: .usageBar(index: 1)),
            ProviderUsageMetric(id: "e", label: "E", kind: .monetary(index: 1)),
        ]
        let preferences: [String: MetricTileWidthPreference] = [
            "a": .half,
            "b": .half,
            "c": .full,
            "d": .half,
            "e": .half,
        ]

        let rows = ProviderMetricTileGridResolver.rows(
            metrics: metrics,
            orderedMetricIDs: ["d", "c", "b", "a", "unknown"],
            widthForMetric: { preferences[$0] ?? .automatic },
            visualizationStyleForMetric: { _ in .linearBar },
            usesRegularHorizontalSizeClass: false,
            collapsesToSingleColumn: false
        )

        XCTAssertEqual(rows.map(\.leading.id), ["d", "c", "b", "e"])
        XCTAssertEqual(rows.map { $0.trailing?.id }, [nil, nil, "a", nil])
        XCTAssertEqual(
            rows.flatMap { [$0.leading.id, $0.trailing?.id].compactMap { $0 } },
            ["d", "c", "b", "a", "e"]
        )
    }

    func testMetricTileRowsBecomeSingleColumnWithoutChangingRequestedWidths() {
        let metrics = [
            ProviderUsageMetric(id: "credits", label: "Credits", kind: .creditsRemaining),
            ProviderUsageMetric(id: "money", label: "Balance", kind: .monetary(index: 0)),
        ]

        let rows = ProviderMetricTileGridResolver.rows(
            metrics: metrics,
            orderedMetricIDs: [],
            widthForMetric: { _ in .half },
            visualizationStyleForMetric: { _ in .largeNumeric },
            usesRegularHorizontalSizeClass: false,
            collapsesToSingleColumn: true
        )

        XCTAssertEqual(rows.map(\.leading.id), ["credits", "money"])
        XCTAssertTrue(rows.allSatisfy { $0.leading.width == .full && $0.trailing == nil })
    }

    func testMetricTileDragOrderingSupportsAdjacentAndFinalDownwardPlacement() {
        XCTAssertEqual(
            ProviderMetricTileOrderResolver.moving(
                "a",
                toward: "b",
                in: ["a", "b", "c"]
            ),
            ["b", "a", "c"]
        )
        XCTAssertEqual(
            ProviderMetricTileOrderResolver.moving(
                "a",
                toward: "c",
                in: ["a", "b", "c"]
            ),
            ["b", "c", "a"]
        )
        XCTAssertEqual(
            ProviderMetricTileOrderResolver.moving(
                "c",
                toward: "a",
                in: ["a", "b", "c"]
            ),
            ["c", "a", "b"]
        )
        XCTAssertNil(
            ProviderMetricTileOrderResolver.moving(
                "b",
                toward: "b",
                in: ["a", "b", "c"]
            )
        )
    }

    func testMetricTileHistoryIsBuiltLazilyAndFailedMoneyIsLastKnown() throws {
        let monetaryMetric = ProviderMonetaryMetric(
            kind: .balance,
            label: "Usage credit balance",
            minorUnits: 1_250,
            currencyCode: "USD",
            decimalPlaces: 2
        )
        let result = ProviderUsageResult(
            accountID: "claude.cached",
            providerID: .claude,
            title: "Claude",
            subtitle: "Refresh failed. Showing last known data.",
            bars: [],
            monetaryMetrics: [monetaryMetric],
            failureMessage: "Refresh failed",
            fetchedAt: Date()
        )
        let series = UsageHistorySeries(
            accountID: result.accountID,
            points: [],
            isBalance: true,
            currencyCode: "USD"
        )
        var historyBuildCount = 0
        let card = ProviderUsageCard(
            result: result,
            statusText: result.subtitle,
            history: series,
            historySeriesOptions: {
                historyBuildCount += 1
                return [
                    UsageHistorySeriesOption(
                        id: "money.\(monetaryMetric.id)",
                        label: monetaryMetric.label,
                        series: series
                    ),
                ]
            }
        )

        XCTAssertEqual(historyBuildCount, 0)
        XCTAssertEqual(card.monetaryFreshnessDescription, "Last known value")
        XCTAssertEqual(
            card.metricDetailHistorySeries(for: try XCTUnwrap(result.availableMetrics.first)),
            series
        )
        XCTAssertEqual(historyBuildCount, 1)
    }

    func testMetricTileDetailsHonorHistorySettingAndOmitAggregateUsageHistory() throws {
        let usageBar = UsageBar(
            label: "5-hour limit",
            used: 25,
            limit: 100
        )
        let result = ProviderUsageResult(
            accountID: "codex.history",
            providerID: .codex,
            title: "Codex",
            subtitle: "Current",
            bars: [usageBar],
            fetchedAt: Date()
        )
        let series = UsageHistorySeries(
            accountID: result.accountID,
            points: [],
            isBalance: false
        )
        var historyBuildCount = 0
        let balanceResult = ProviderUsageResult(
            accountID: "openrouter.history",
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Current",
            bars: [],
            creditsRemaining: 12.50,
            fetchedAt: Date()
        )
        let disabledCard = ProviderUsageCard(
            result: balanceResult,
            statusText: balanceResult.subtitle,
            history: series,
            isHistoryEnabled: false,
            historySeriesOptions: {
                historyBuildCount += 1
                return [UsageHistorySeriesOption(id: "balance", label: "Balance", series: series)]
            }
        )

        XCTAssertNil(
            disabledCard.metricDetailHistorySeries(
                for: try XCTUnwrap(balanceResult.availableMetrics.first)
            )
        )
        XCTAssertEqual(historyBuildCount, 0)

        let enabledCard = ProviderUsageCard(
            result: result,
            statusText: result.subtitle,
            history: series,
            historySeriesOptions: {
                historyBuildCount += 1
                return [UsageHistorySeriesOption(id: "usage", label: "Usage", series: series)]
            }
        )
        let usageMetric = try XCTUnwrap(result.availableMetrics.first)
        XCTAssertNil(enabledCard.metricDetailHistorySeries(for: usageMetric))
        XCTAssertEqual(historyBuildCount, 0)
    }

    func testCursorMetricTileUsesItsStableHistorySeries() throws {
        let result = ProviderUsageResult(
            accountID: "cursor.history",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Current",
            bars: [UsageBar(stableKey: "total", label: "Total", used: 38, limit: 100)],
            fetchedAt: Date()
        )
        let series = UsageHistorySeries(
            accountID: result.accountID,
            points: [],
            isBalance: false
        )
        let card = ProviderUsageCard(
            result: result,
            statusText: result.subtitle,
            history: series,
            historySeriesOptions: {
                [UsageHistorySeriesOption(id: "usage.total", label: "Total", series: series)]
            }
        )

        XCTAssertEqual(
            card.metricDetailHistorySeries(for: try XCTUnwrap(result.availableMetrics.first)),
            series
        )

        let aggregateOnlyCard = ProviderUsageCard(
            result: result,
            statusText: result.subtitle,
            history: series,
            historySeriesOptions: {
                [UsageHistorySeriesOption(id: "usage", label: "Usage", series: series)]
            }
        )
        XCTAssertNil(
            aggregateOnlyCard.metricDetailHistorySeries(
                for: try XCTUnwrap(result.availableMetrics.first)
            )
        )
    }

    func testFailedCachedMetricComponentsAreLastKnownDespiteMatchingTimestamps() {
        let fetchedAt = Date(timeIntervalSince1970: 1_785_000_000)
        let successfulResult = ProviderUsageResult(
            accountID: "codex.cached",
            providerID: .codex,
            title: "Codex",
            subtitle: "Current",
            bars: [UsageBar(label: "Weekly", used: 20, limit: 100)],
            creditsRemaining: 5,
            fetchedAt: fetchedAt
        )
        let failedCachedResult = ProviderUsageResult(
            accountID: successfulResult.accountID,
            providerID: successfulResult.providerID,
            title: successfulResult.title,
            subtitle: "Refresh failed. Showing last known data.",
            bars: successfulResult.bars,
            barsFetchedAt: fetchedAt,
            creditsRemaining: successfulResult.creditsRemaining,
            creditsFetchedAt: fetchedAt,
            failureMessage: "Refresh failed",
            fetchedAt: fetchedAt
        )

        XCTAssertTrue(successfulResult.hasCurrentBars)
        XCTAssertTrue(successfulResult.hasCurrentCredits)
        XCTAssertTrue(failedCachedResult.hasFreshBars)
        XCTAssertTrue(failedCachedResult.hasFreshCredits)
        XCTAssertFalse(failedCachedResult.hasCurrentBars)
        XCTAssertFalse(failedCachedResult.hasCurrentCredits)
    }

    func testPartialFailureKeepsSuccessfulComponentCurrent() {
        let fetchedAt = Date(timeIntervalSince1970: 1_785_000_100)
        let barsPreserved = ProviderUsageResult(
            accountID: "opencode.partial-bars",
            providerID: .openCodeZen,
            title: "OpenCode",
            subtitle: "Zen refreshed",
            bars: [UsageBar(label: "Weekly", used: 20, limit: 100)],
            creditsRemaining: 8,
            failureMessage: "Go refresh failed",
            preserveCachedBarsOnFailure: true,
            fetchedAt: fetchedAt
        )
        let creditsPreserved = ProviderUsageResult(
            accountID: "opencode.partial-credits",
            providerID: .openCodeZen,
            title: "OpenCode",
            subtitle: "Go refreshed",
            bars: [UsageBar(label: "Weekly", used: 20, limit: 100)],
            creditsRemaining: 8,
            failureMessage: "Zen refresh failed",
            preserveCachedCreditsOnFailure: true,
            fetchedAt: fetchedAt
        )

        XCTAssertFalse(barsPreserved.hasCurrentBars)
        XCTAssertTrue(barsPreserved.hasCurrentCredits)
        XCTAssertTrue(creditsPreserved.hasCurrentBars)
        XCTAssertFalse(creditsPreserved.hasCurrentCredits)
    }

    func testSpendLimitSeverityAppliesOnlyToSpentMetric() {
        let balance = ProviderMonetaryMetric(
            kind: .balance,
            label: "Current balance",
            minorUnits: 5_000,
            currencyCode: "USD",
            decimalPlaces: 2
        )
        let spent = ProviderMonetaryMetric(
            kind: .spent,
            label: "Spent this month",
            minorUnits: 10_000,
            currencyCode: "USD",
            decimalPlaces: 2
        )
        let limit = ProviderMonetaryMetric(
            kind: .spendLimit,
            label: "Monthly limit",
            minorUnits: 10_000,
            currencyCode: "USD",
            decimalPlaces: 2
        )
        let result = ProviderUsageResult(
            accountID: "claude.spend-limit",
            providerID: .claude,
            title: "Claude",
            subtitle: "Current",
            bars: [],
            monetaryMetrics: [balance, spent, limit],
            fetchedAt: Date()
        )

        XCTAssertTrue(result.hasReachedSpendLimit)
        XCTAssertFalse(ProviderUsageCard.isCritical(balance, in: result))
        XCTAssertTrue(ProviderUsageCard.isCritical(spent, in: result))
        XCTAssertFalse(ProviderUsageCard.isCritical(limit, in: result))
    }

    func testMetricTileAccessibilityHintPromisesOnlyAvailableContent() {
        XCTAssertEqual(
            ProviderUsageCard.metricDetailAccessibilityHint,
            "Shows complete metric details."
        )
        XCTAssertFalse(
            ProviderUsageCard.metricDetailAccessibilityHint.localizedCaseInsensitiveContains(
                "history"
            )
        )
    }

    func testMetricDetailResolvesCurrentKindByStableIDAfterRefresh() throws {
        let selectedBar = UsageBar(
            stableKey: "window-18000",
            label: "5-hour limit",
            used: 20,
            limit: 100
        )
        let otherBar = UsageBar(
            stableKey: "window-604800",
            label: "Weekly limit",
            used: 40,
            limit: 100
        )
        let initialResult = ProviderUsageResult(
            accountID: "codex.reordered",
            providerID: .codex,
            title: "Codex",
            subtitle: "Current",
            bars: [selectedBar, otherBar],
            fetchedAt: Date()
        )
        let reorderedResult = ProviderUsageResult(
            accountID: initialResult.accountID,
            providerID: initialResult.providerID,
            title: initialResult.title,
            subtitle: initialResult.subtitle,
            bars: [otherBar, selectedBar],
            fetchedAt: Date()
        )
        let selectedMetricID = try XCTUnwrap(initialResult.availableMetrics.first?.id)

        let resolvedMetric = try XCTUnwrap(
            ProviderUsageCard.metric(withID: selectedMetricID, in: reorderedResult)
        )
        XCTAssertEqual(resolvedMetric.label, selectedBar.label)
        XCTAssertEqual(resolvedMetric.kind, .usageBar(index: 1))

        let removedResult = ProviderUsageResult(
            accountID: initialResult.accountID,
            providerID: initialResult.providerID,
            title: initialResult.title,
            subtitle: initialResult.subtitle,
            bars: [otherBar],
            fetchedAt: Date()
        )
        XCTAssertNil(ProviderUsageCard.metric(withID: selectedMetricID, in: removedResult))
    }

    @MainActor
    func testMetricVisualizationPreferencesPersistPerAccountAndStableMetric() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        let firstAccount = try XCTUnwrap(store.addAccount(for: .codex))
        let secondAccount = try XCTUnwrap(store.addAccount(for: .codex))
        let firstMetric = UsageBar(
            stableKey: "window-18000",
            label: "Localized label A",
            used: 30,
            limit: 100
        )
        let renamedMetric = UsageBar(
            stableKey: "window-18000",
            label: "Localized label B",
            used: 40,
            limit: 100
        )
        let metricID = firstMetric.metricIdentifier(providerID: .codex, index: 0)

        XCTAssertEqual(store.visualizationStyle(accountID: firstAccount.id, metricID: metricID), .linearBar)
        XCTAssertEqual(
            metricID,
            renamedMetric.metricIdentifier(providerID: .codex, index: 4)
        )

        store.updateVisualizationStyle(.circularRing, accountID: firstAccount.id, metricID: metricID)
        store.applyVisualizationStyle(
            .segmentedBar,
            accountID: firstAccount.id,
            metricIDs: [metricID, "codex.window-604800"]
        )

        let reloaded = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(reloaded.visualizationStyle(accountID: firstAccount.id, metricID: metricID), .segmentedBar)
        XCTAssertEqual(
            reloaded.visualizationStyle(accountID: firstAccount.id, metricID: "codex.window-604800"),
            .segmentedBar
        )
        XCTAssertEqual(reloaded.visualizationStyle(accountID: secondAccount.id, metricID: metricID), .linearBar)

        reloaded.resetVisualizationStyles(
            accountID: firstAccount.id,
            metricIDs: [metricID, "codex.window-604800"]
        )
        XCTAssertEqual(reloaded.visualizationStyle(accountID: firstAccount.id, metricID: metricID), .linearBar)
    }

    @MainActor
    func testMetricCustomizationMigratesStylesAndPersistsVisibilityPerAccount() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let firstAccountID = "codex.personal"
        let secondAccountID = "codex.work"
        let metricID = "codex.window-18000"
        let legacyStyles = [
            firstAccountID: [metricID: MetricVisualizationStyle.circularRing],
        ]
        defaults.set(
            try JSONEncoder().encode(legacyStyles),
            forKey: "metricVisualizationPreferences"
        )

        let migrated = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: EmptySecretStore()
        )
        XCTAssertEqual(
            migrated.visualizationStyle(accountID: firstAccountID, metricID: metricID),
            .circularRing
        )
        XCTAssertEqual(migrated.metricWidth(accountID: firstAccountID, metricID: metricID), .full)
        XCTAssertFalse(
            try XCTUnwrap(migrated.metricLayouts[firstAccountID]?.preferences[metricID])
                .isNewlyDiscovered
        )
        XCTAssertTrue(migrated.isMetricVisible(accountID: firstAccountID, metricID: metricID))
        XCTAssertTrue(migrated.isMetricVisible(accountID: firstAccountID, metricID: "codex.new"))

        migrated.updateMetricVisibility(false, accountID: firstAccountID, metricID: metricID)
        migrated.updateVisualizationStyle(
            .segmentedBar,
            accountID: firstAccountID,
            metricID: metricID
        )

        let reloaded = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: EmptySecretStore()
        )
        XCTAssertFalse(reloaded.isMetricVisible(accountID: firstAccountID, metricID: metricID))
        XCTAssertEqual(
            reloaded.visualizationStyle(accountID: firstAccountID, metricID: metricID),
            .segmentedBar
        )
        XCTAssertTrue(reloaded.isMetricVisible(accountID: secondAccountID, metricID: metricID))

        reloaded.updateMetricVisibility(true, accountID: firstAccountID, metricID: metricID)
        XCTAssertTrue(reloaded.isMetricVisible(accountID: firstAccountID, metricID: metricID))
        XCTAssertEqual(
            reloaded.visualizationStyle(accountID: firstAccountID, metricID: metricID),
            .segmentedBar
        )
    }

    @MainActor
    func testCurrentDictionaryMetricPreferencesMigrateLosslessly() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let accountID = "claude.work"
        let metricID = "claude.session"
        let dictionaryPreferences = [
            accountID: [
                metricID: MetricCustomizationPreference(
                    visualizationStyle: .semicircularDial,
                    isVisible: false
                ),
            ],
        ]
        defaults.set(
            try JSONEncoder().encode(dictionaryPreferences),
            forKey: "metricVisualizationPreferences"
        )

        let migrated = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: EmptySecretStore()
        )

        XCTAssertFalse(migrated.isMetricVisible(accountID: accountID, metricID: metricID))
        XCTAssertEqual(
            migrated.visualizationStyle(accountID: accountID, metricID: metricID),
            .semicircularDial
        )
        XCTAssertEqual(migrated.metricWidth(accountID: accountID, metricID: metricID), .full)
        XCTAssertFalse(
            try XCTUnwrap(migrated.metricLayouts[accountID]?.preferences[metricID])
                .isNewlyDiscovered
        )

        let existingUncustomizedMetricID = "claude.weekly"
        migrated.updateVisualizationStyle(
            .largeNumeric,
            accountID: accountID,
            metricID: existingUncustomizedMetricID
        )
        XCTAssertEqual(
            migrated.metricOrder(
                accountID: accountID,
                availableMetricIDs: [existingUncustomizedMetricID, metricID]
            ),
            [existingUncustomizedMetricID, metricID]
        )
        XCTAssertEqual(
            migrated.metricWidth(
                accountID: accountID,
                metricID: existingUncustomizedMetricID
            ),
            .full
        )
        XCTAssertEqual(
            migrated.visualizationStyle(
                accountID: accountID,
                metricID: existingUncustomizedMetricID
            ),
            .largeNumeric
        )
        XCTAssertFalse(
            try XCTUnwrap(
                migrated.metricLayouts[accountID]?.preferences[existingUncustomizedMetricID]
            ).isNewlyDiscovered
        )

        let newlyAddedMetricID = "claude.monthly"
        _ = migrated.reconcileMetricLayout(
            accountID: accountID,
            availableMetricIDs: [existingUncustomizedMetricID, metricID, newlyAddedMetricID]
        )
        XCTAssertEqual(
            migrated.metricWidth(accountID: accountID, metricID: newlyAddedMetricID),
            .automatic
        )
        XCTAssertTrue(
            try XCTUnwrap(migrated.metricLayouts[accountID]?.preferences[newlyAddedMetricID])
                .isNewlyDiscovered
        )

        let persistedData = try XCTUnwrap(
            defaults.data(forKey: "metricVisualizationPreferences")
        )
        let persistedLayouts = try JSONDecoder().decode(
            [String: AccountMetricLayout].self,
            from: persistedData
        )
        XCTAssertEqual(persistedLayouts, migrated.metricLayouts)
    }

    @MainActor
    func testMetricLayoutsPersistOrderWidthAndDiscoveryAcrossStoreRecreation() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let accountID = "codex.personal"
        let sessionID = "codex.session"
        let missingID = "codex.temporarily-missing"
        let weeklyID = "codex.weekly"
        let newID = "codex.monthly"
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())

        XCTAssertEqual(
            store.metricOrder(
                accountID: accountID,
                availableMetricIDs: [sessionID, missingID, weeklyID]
            ),
            [sessionID, missingID, weeklyID]
        )
        XCTAssertTrue(
            try XCTUnwrap(store.metricLayouts[accountID]?.preferences[sessionID])
                .isNewlyDiscovered
        )

        store.updateMetricOrder([weeklyID, sessionID, missingID], accountID: accountID)
        store.updateMetricWidth(.half, accountID: accountID, metricID: weeklyID)
        store.updateMetricVisibility(false, accountID: accountID, metricID: missingID)
        store.updateWatchMetricVisibility(.show, accountID: accountID, metricID: missingID)
        store.updateVisualizationStyle(.circularRing, accountID: accountID, metricID: missingID)

        let reloaded = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: EmptySecretStore()
        )
        XCTAssertEqual(reloaded.metricWidth(accountID: accountID, metricID: weeklyID), .half)
        XCTAssertFalse(reloaded.isMetricVisible(accountID: accountID, metricID: missingID))
        XCTAssertTrue(reloaded.isMetricVisibleOnWatch(accountID: accountID, metricID: missingID))
        XCTAssertEqual(
            reloaded.watchVisibilityPolicy(accountID: accountID, metricID: missingID),
            .show
        )
        XCTAssertEqual(
            reloaded.visualizationStyle(accountID: accountID, metricID: missingID),
            .circularRing
        )
        XCTAssertEqual(
            reloaded.metricOrder(
                accountID: accountID,
                availableMetricIDs: [sessionID, weeklyID, newID]
            ),
            [weeklyID, sessionID, missingID, newID]
        )
        XCTAssertEqual(
            reloaded.metricLayouts[accountID]?.preferences[missingID]?.width,
            .automatic
        )
        XCTAssertFalse(
            try XCTUnwrap(reloaded.metricLayouts[accountID]?.preferences[missingID])
                .isNewlyDiscovered
        )
        XCTAssertTrue(
            try XCTUnwrap(reloaded.metricLayouts[accountID]?.preferences[newID])
                .isNewlyDiscovered
        )

        reloaded.markMetricsSeen([newID], accountID: accountID)
        let seenReloaded = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: EmptySecretStore()
        )
        XCTAssertFalse(
            try XCTUnwrap(seenReloaded.metricLayouts[accountID]?.preferences[newID])
                .isNewlyDiscovered
        )
    }

    func testMetricLayoutUnknownEnumValuesFallBackSafely() throws {
        let data = Data(
            """
            {
              "version": 99,
              "orderedMetricIDs": ["codex.session"],
              "preferences": {
                "codex.session": {
                  "isVisible": false,
                  "visualizationStyle": "future-hologram",
                  "width": "quarter",
                  "watchVisibility": "future-watch-policy",
                  "isNewlyDiscovered": true
                }
              }
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(AccountMetricLayout.self, from: data)
        let preference = try XCTUnwrap(decoded.preferences["codex.session"])

        XCTAssertFalse(preference.isVisible)
        XCTAssertEqual(preference.visualizationStyle, .automatic)
        XCTAssertEqual(preference.width, .automatic)
        XCTAssertEqual(preference.watchVisibility, .inherit)
        XCTAssertTrue(preference.isNewlyDiscovered)
    }

    @MainActor
    func testVersionOneMetricLayoutMigratesWatchVisibilityAndGroupsGitHubActionsMetrics() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let accountID = "githubBilling.personal"
        let minutesID = "githubBilling.actions-allowance-minutes"
        let storageID = "githubBilling.actions-storage"
        let lfsStorageID = "githubBilling.lfs-storage"
        defaults.set(
            Data(
                """
                {
                  "\(accountID)": {
                    "version": 1,
                    "orderedMetricIDs": ["\(storageID)", "\(lfsStorageID)"],
                    "preferences": {
                      "\(storageID)": {
                        "isVisible": false,
                        "width": "half",
                        "isNewlyDiscovered": false
                      }
                    }
                  }
                }
                """.utf8
            ),
            forKey: "metricVisualizationPreferences"
        )

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        let order = store.metricOrder(
            accountID: accountID,
            availableMetricIDs: [minutesID, storageID, lfsStorageID]
        )

        XCTAssertEqual(store.metricLayouts[accountID]?.version, AccountMetricLayout.currentVersion)
        XCTAssertEqual(order, [minutesID, storageID, lfsStorageID])
        XCTAssertTrue(try XCTUnwrap(store.metricLayouts[accountID]).hasAppliedGitHubActionsMetricGrouping)
        XCTAssertEqual(store.watchVisibilityPolicy(accountID: accountID, metricID: storageID), .inherit)
        XCTAssertFalse(store.isMetricVisibleOnWatch(accountID: accountID, metricID: storageID))
    }

    @MainActor
    func testMetricLayoutUndoAndResetRestoreCompletePersistedSnapshots() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let accountID = "codex.editor"
        let firstID = "codex.session"
        let secondID = "codex.weekly"
        let temporarilyMissingID = "codex.temporarily-missing"
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        _ = store.reconcileMetricLayout(
            accountID: accountID,
            availableMetricIDs: [firstID, secondID, temporarilyMissingID]
        )
        let original = try XCTUnwrap(store.metricLayouts[accountID])
        var undoHistory = MetricLayoutUndoHistory()

        XCTAssertFalse(undoHistory.record(original, ifChangedTo: original))
        XCTAssertFalse(undoHistory.canUndo)

        store.updateMetricOrder([secondID, firstID], accountID: accountID)
        store.updateMetricWidth(.half, accountID: accountID, metricID: secondID)
        store.updateMetricVisibility(false, accountID: accountID, metricID: firstID)
        XCTAssertTrue(
            undoHistory.record(
                original,
                ifChangedTo: try XCTUnwrap(store.metricLayouts[accountID])
            )
        )
        XCTAssertTrue(undoHistory.canUndo)

        store.replaceMetricLayout(try XCTUnwrap(undoHistory.undo()), accountID: accountID)
        XCTAssertEqual(store.metricLayouts[accountID], original)
        XCTAssertFalse(undoHistory.canUndo)

        store.updateMetricWidth(.full, accountID: accountID, metricID: firstID)
        store.updateVisualizationStyle(.circularRing, accountID: accountID, metricID: firstID)
        store.resetMetricLayout(
            accountID: accountID,
            availableMetricIDs: [firstID, secondID]
        )

        let reset = try XCTUnwrap(store.metricLayouts[accountID])
        XCTAssertEqual(reset.orderedMetricIDs, [firstID, secondID, temporarilyMissingID])
        XCTAssertTrue(reset.preferences.values.allSatisfy(\.isVisible))
        XCTAssertTrue(reset.preferences.values.allSatisfy { $0.visualizationStyle == nil })
        XCTAssertTrue(reset.preferences.values.allSatisfy { $0.width == .automatic })
        XCTAssertTrue(reset.preferences.values.allSatisfy { $0.watchVisibility == .inherit })
        XCTAssertTrue(reset.preferences.values.allSatisfy { !$0.isNewlyDiscovered })

        let reloaded = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(reloaded.metricLayouts[accountID], reset)
    }

    @MainActor
    func testCopyMetricLayoutCopiesMatchingIDsAndPreservesDestinationOnlyMetrics() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let sourceAccountID = "claude.source"
        let destinationAccountID = "claude.destination"
        let sharedID = "claude.weekly"
        let sourceOnlyID = "claude.session"
        let destinationOnlyID = "claude.monthly"
        let temporarilyMissingSharedID = "claude.shared-temporarily-missing"
        let temporarilyMissingDestinationID = "claude.temporarily-missing"
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        _ = store.reconcileMetricLayout(
            accountID: sourceAccountID,
            availableMetricIDs: [sourceOnlyID, sharedID, temporarilyMissingSharedID]
        )
        store.updateMetricOrder(
            [temporarilyMissingSharedID, sharedID, sourceOnlyID],
            accountID: sourceAccountID
        )
        store.updateMetricVisibility(false, accountID: sourceAccountID, metricID: sharedID)
        store.updateMetricWidth(.half, accountID: sourceAccountID, metricID: sharedID)
        store.updateVisualizationStyle(.semicircularDial, accountID: sourceAccountID, metricID: sharedID)
        store.updateMetricWidth(
            .half,
            accountID: sourceAccountID,
            metricID: temporarilyMissingSharedID
        )

        _ = store.reconcileMetricLayout(
            accountID: destinationAccountID,
            availableMetricIDs: [
                destinationOnlyID,
                sharedID,
                temporarilyMissingSharedID,
                temporarilyMissingDestinationID,
            ]
        )
        store.updateMetricWidth(
            .full,
            accountID: destinationAccountID,
            metricID: destinationOnlyID
        )

        store.copyMetricLayout(
            from: sourceAccountID,
            to: destinationAccountID,
            destinationAvailableMetricIDs: [destinationOnlyID, sharedID]
        )

        let copied = try XCTUnwrap(store.metricLayouts[destinationAccountID])
        XCTAssertEqual(
            copied.orderedMetricIDs,
            [
                temporarilyMissingSharedID,
                sharedID,
                destinationOnlyID,
                temporarilyMissingDestinationID,
            ]
        )
        XCTAssertFalse(store.isMetricVisible(accountID: destinationAccountID, metricID: sharedID))
        XCTAssertEqual(store.metricWidth(accountID: destinationAccountID, metricID: sharedID), .half)
        XCTAssertEqual(
            store.visualizationStyle(accountID: destinationAccountID, metricID: sharedID),
            .semicircularDial
        )
        XCTAssertEqual(
            store.metricWidth(accountID: destinationAccountID, metricID: destinationOnlyID),
            .full
        )
        XCTAssertTrue(
            store.isMetricVisible(accountID: destinationAccountID, metricID: destinationOnlyID)
        )
        XCTAssertEqual(
            store.metricWidth(
                accountID: destinationAccountID,
                metricID: temporarilyMissingSharedID
            ),
            .half
        )
        XCTAssertNotNil(copied.preferences[temporarilyMissingDestinationID])
        XCTAssertNil(copied.preferences[sourceOnlyID])
        XCTAssertFalse(try XCTUnwrap(copied.preferences[sharedID]).isNewlyDiscovered)
    }

    @MainActor
    func testCustomLayoutDetectionIgnoresNewMarkersButFindsUserEdits() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let accountID = "codex.copy-target"
        let metricIDs = ["codex.session", "codex.weekly"]
        let temporarilyMissingID = "codex.temporarily-missing"
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        _ = store.reconcileMetricLayout(
            accountID: accountID,
            availableMetricIDs: metricIDs + [temporarilyMissingID]
        )

        XCTAssertFalse(
            store.isMetricLayoutCustomized(
                accountID: accountID,
                availableMetricIDs: metricIDs
            )
        )

        store.updateMetricOrder(
            [temporarilyMissingID] + metricIDs,
            accountID: accountID
        )
        XCTAssertTrue(
            store.isMetricLayoutCustomized(
                accountID: accountID,
                availableMetricIDs: metricIDs
            )
        )

        store.resetMetricLayout(
            accountID: accountID,
            availableMetricIDs: metricIDs + [temporarilyMissingID]
        )
        store.updateMetricWidth(.half, accountID: accountID, metricID: metricIDs[0])
        XCTAssertTrue(
            store.isMetricLayoutCustomized(
                accountID: accountID,
                availableMetricIDs: metricIDs
            )
        )

        store.resetMetricLayout(
            accountID: accountID,
            availableMetricIDs: metricIDs + [temporarilyMissingID]
        )
        store.updateMetricVisibility(
            false,
            accountID: accountID,
            metricID: temporarilyMissingID
        )
        XCTAssertTrue(
            store.isMetricLayoutCustomized(
                accountID: accountID,
                availableMetricIDs: metricIDs
            )
        )
    }

    @MainActor
    func testAccountInsertedThroughUpdateKeepsNewMetricDefaultsAfterReload() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        var imported = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        imported.openCodeWorkspaceId = "workspace"
        XCTAssertTrue(store.update(imported))

        let reloaded = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: EmptySecretStore()
        )
        let metricID = "openCodeZen.go-weekly"
        _ = reloaded.reconcileMetricLayout(
            accountID: imported.id,
            availableMetricIDs: [metricID]
        )

        XCTAssertEqual(reloaded.metricWidth(accountID: imported.id, metricID: metricID), .automatic)
        XCTAssertTrue(
            try XCTUnwrap(reloaded.metricLayouts[imported.id]?.preferences[metricID])
                .isNewlyDiscovered
        )
    }

    @MainActor
    func testAccountInsertedThroughCredentialReplacementKeepsNewMetricDefaultsAfterReload() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        XCTAssertTrue(store.replaceCredential("token", for: configuration))

        let reloaded = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: EmptySecretStore()
        )
        let metricID = "codex.session"
        _ = reloaded.reconcileMetricLayout(
            accountID: configuration.id,
            availableMetricIDs: [metricID]
        )

        XCTAssertEqual(
            reloaded.metricWidth(accountID: configuration.id, metricID: metricID),
            .automatic
        )
        XCTAssertTrue(
            try XCTUnwrap(reloaded.metricLayouts[configuration.id]?.preferences[metricID])
                .isNewlyDiscovered
        )
    }

    @MainActor
    func testExistingAccountWithoutMetricPreferencesMigratesAtFullWidth() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let original = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: EmptySecretStore()
        )
        let existingAccount = try XCTUnwrap(original.addAccount(for: .codex))
        defaults.removeObject(forKey: "metricVisualizationPreferences")

        let migrated = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: EmptySecretStore()
        )
        let metricID = "codex.session"
        XCTAssertEqual(
            migrated.metricWidth(accountID: existingAccount.id, metricID: metricID),
            .full
        )
        _ = migrated.reconcileMetricLayout(
            accountID: existingAccount.id,
            availableMetricIDs: [metricID]
        )

        XCTAssertEqual(
            migrated.metricWidth(accountID: existingAccount.id, metricID: metricID),
            .full
        )
        XCTAssertFalse(
            try XCTUnwrap(migrated.metricLayouts[existingAccount.id]?.preferences[metricID])
                .isNewlyDiscovered
        )
    }

    @MainActor
    func testUndecodableFutureMetricLayoutIsPreservedWhenKnownLayoutsSave() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let futureAccountID = "codex.future"
        defaults.set(
            Data(
                """
                {
                  "\(futureAccountID)": {
                    "version": 99,
                    "orderedMetricIDs": ["codex.session"],
                    "preferences": {"codex.session": ["future", "shape"]},
                    "futureField": {"keep": "me"}
                  }
                }
                """.utf8
            ),
            forKey: "metricVisualizationPreferences"
        )

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        _ = store.addAccount(for: .claude)

        let persistedData = try XCTUnwrap(
            defaults.data(forKey: "metricVisualizationPreferences")
        )
        let persistedRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: persistedData) as? [String: Any]
        )
        let futureLayout = try XCTUnwrap(persistedRoot[futureAccountID] as? [String: Any])
        let futureField = try XCTUnwrap(futureLayout["futureField"] as? [String: String])
        let futurePreferences = try XCTUnwrap(
            futureLayout["preferences"] as? [String: [String]]
        )

        XCTAssertEqual((futureLayout["version"] as? NSNumber)?.intValue, 99)
        XCTAssertEqual(futureField, ["keep": "me"])
        XCTAssertEqual(futurePreferences["codex.session"], ["future", "shape"])

        store.updateMetricWidth(
            .half,
            accountID: futureAccountID,
            metricID: "codex.session"
        )
        let rewrittenData = try XCTUnwrap(
            defaults.data(forKey: "metricVisualizationPreferences")
        )
        let rewrittenRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: rewrittenData) as? [String: Any]
        )
        let rewrittenLayout = try XCTUnwrap(
            rewrittenRoot[futureAccountID] as? [String: Any]
        )
        let rewrittenPreferences = try XCTUnwrap(
            rewrittenLayout["preferences"] as? [String: [String: Any]]
        )

        XCTAssertEqual(
            (rewrittenLayout["version"] as? NSNumber)?.intValue,
            AccountMetricLayout.currentVersion
        )
        XCTAssertNil(rewrittenLayout["futureField"])
        XCTAssertEqual(rewrittenPreferences["codex.session"]?["width"] as? String, "half")
    }

    @MainActor
    func testOpaqueMetricLayoutStorageSurvivesUntilExplicitCustomization() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let originalStore = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: EmptySecretStore()
        )
        let existingAccount = try XCTUnwrap(originalStore.addAccount(for: .codex))
        let opaqueData = Data(
            #"{"futureEnvelope":{"schema":2,"accounts":[]}}"#.utf8
        )
        defaults.set(opaqueData, forKey: "metricVisualizationPreferences")

        let preservingStore = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: EmptySecretStore()
        )
        XCTAssertEqual(
            defaults.data(forKey: "metricVisualizationPreferences"),
            opaqueData
        )

        _ = preservingStore.addAccount(for: .claude)
        XCTAssertEqual(
            defaults.data(forKey: "metricVisualizationPreferences"),
            opaqueData
        )

        preservingStore.updateMetricWidth(
            .half,
            accountID: existingAccount.id,
            metricID: "codex.session"
        )
        let rewrittenData = try XCTUnwrap(
            defaults.data(forKey: "metricVisualizationPreferences")
        )
        let rewrittenLayouts = try JSONDecoder().decode(
            [String: AccountMetricLayout].self,
            from: rewrittenData
        )

        XCTAssertEqual(
            rewrittenLayouts[existingAccount.id]?.preferences["codex.session"]?.width,
            .half
        )
    }

    @MainActor
    func testResetVisualizationStylesReplacesOpaqueMetricLayoutStorage() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let originalStore = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: EmptySecretStore()
        )
        let existingAccount = try XCTUnwrap(originalStore.addAccount(for: .codex))
        defaults.set(
            Data(#"{"futureEnvelope":{"schema":2,"accounts":[]}}"#.utf8),
            forKey: "metricVisualizationPreferences"
        )

        let preservingStore = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: EmptySecretStore()
        )
        preservingStore.resetVisualizationStyles(
            accountID: existingAccount.id,
            metricIDs: ["codex.session"]
        )

        let rewrittenData = try XCTUnwrap(
            defaults.data(forKey: "metricVisualizationPreferences")
        )
        let rewrittenLayouts = try JSONDecoder().decode(
            [String: AccountMetricLayout].self,
            from: rewrittenData
        )
        let rewrittenLayout = try XCTUnwrap(rewrittenLayouts[existingAccount.id])

        XCTAssertEqual(rewrittenLayout.version, AccountMetricLayout.currentVersion)
        XCTAssertTrue(rewrittenLayout.preferences.isEmpty)
    }

    func testAvailableMetricIdentifiersCoverEveryMetricTypeWithoutUsingLabels() {
        let firstResult = ProviderUsageResult(
            accountID: "claude.personal",
            providerID: .claude,
            title: "Claude",
            subtitle: "Pro",
            bars: [
                UsageBar(
                    stableKey: "session",
                    label: "Current session",
                    used: 30,
                    limit: 100
                ),
            ],
            creditsRemaining: 5,
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .spent,
                    label: "Usage credits spent",
                    minorUnits: 750,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
            ],
            fetchedAt: Date()
        )
        let renamedMoney = ProviderMonetaryMetric(
            kind: .spent,
            label: "Renamed amount",
            minorUnits: 900,
            currencyCode: "usd",
            decimalPlaces: 2
        )

        XCTAssertEqual(
            firstResult.availableMetrics.map(\.id),
            [
                "claude.session",
                "claude.credits-remaining",
                "claude.monetary.spent.usd",
            ]
        )
        XCTAssertEqual(
            firstResult.monetaryMetrics[0].metricIdentifier(providerID: .claude),
            renamedMoney.metricIdentifier(providerID: .claude)
        )
    }

    @MainActor
    func testDashboardVisibilityDoesNotRemoveMetricsFromWidgetSnapshot() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: MemorySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .codex))
        XCTAssertTrue(store.saveSecret("widget-test-secret", for: configuration))
        let bars = [
            UsageBar(stableKey: "session", label: "Session", used: 20, limit: 100),
            UsageBar(stableKey: "weekly", label: "Weekly", used: 40, limit: 100),
        ]
        store.updateMetricVisibility(
            false,
            accountID: configuration.id,
            metricID: bars[0].metricIdentifier(providerID: .codex, index: 0)
        )
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: "Codex",
            subtitle: "Pro",
            bars: bars,
            fetchedAt: Date()
        )

        WidgetSnapshotPublisher.publish(
            results: [result],
            configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil)
        )

        let published = try XCTUnwrap(
            WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first
        )
        XCTAssertEqual(published.bars.map(\.label), ["Session", "Weekly"])
    }

    @MainActor
    func testRemovingAndResettingAccountsCleanUpMetricLayouts() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        let account = try XCTUnwrap(store.addAccount(for: .codex))
        store.updateVisualizationStyle(
            .largeNumeric,
            accountID: account.id,
            metricID: "codex.window-18000"
        )

        XCTAssertTrue(store.removeAccount(account))
        XCTAssertNil(store.metricVisualizationPreferences[account.id])
        XCTAssertNil(store.metricLayouts[account.id])

        let resetAccount = try XCTUnwrap(store.addAccount(for: .claude))
        store.updateMetricWidth(
            .half,
            accountID: resetAccount.id,
            metricID: "claude.session"
        )
        XCTAssertTrue(store.resetAccounts())
        XCTAssertTrue(store.metricLayouts.isEmpty)
        XCTAssertNil(defaults.data(forKey: "metricVisualizationPreferences"))
    }

    @MainActor
    func testWidgetSnapshotPublishesEveryMetricVisualizationStyle() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        var configuration = try XCTUnwrap(store.addAccount(for: .openCodeZen))
        configuration.openCodeWorkspaceId = "workspace"
        XCTAssertTrue(store.update(configuration))

        let bars = MetricVisualizationStyle.allCases.enumerated().map { index, style in
            let stableKey = "metric-\(index)"
            store.updateVisualizationStyle(
                style,
                accountID: configuration.id,
                metricID: "openCodeZen.\(stableKey)"
            )
            return UsageBar(
                stableKey: stableKey,
                label: "Metric \(index)",
                used: Double(index + 1),
                limit: 10
            )
        }
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: "OpenCode Go",
            subtitle: "Live usage",
            bars: bars,
            fetchedAt: Date(timeIntervalSince1970: 1_788_475_200)
        )

        WidgetSnapshotPublisher.publish(
            results: [result],
            configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil)
        )

        let publishedBars = try XCTUnwrap(
            WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first
        ).bars
        XCTAssertEqual(publishedBars.compactMap(\.visualizationStyle), MetricVisualizationStyle.allCases)
        XCTAssertEqual(
            publishedBars.compactMap(\.metricID),
            bars.enumerated().map {
                $0.element.metricIdentifier(providerID: .openCodeZen, index: $0.offset)
            }
        )
    }

}

extension AppAndWidgetTests {
    func testAppReviewPromptPolicyStillRequiresRefreshCountAfterEngagementWindow() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let start = Date(timeIntervalSince1970: 1_788_475_200)
        let policy = AppReviewPromptPolicy(
            defaults: defaults,
            appVersion: "1.1",
            minimumSuccessfulRefreshes: 5,
            minimumEngagementDuration: 24 * 60 * 60
        )

        XCTAssertFalse(policy.registerSuccessfulRefresh(at: start))
        XCTAssertFalse(policy.registerSuccessfulRefresh(at: start.addingTimeInterval(2 * 24 * 60 * 60)))
    }

    func testAppReviewPromptPolicyDefaultEngagementDurationIsSevenDays() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let start = Date(timeIntervalSince1970: 1_788_475_200)
        let policy = AppReviewPromptPolicy(defaults: defaults, appVersion: "1.1")

        for refreshOffset in 0..<5 {
            XCTAssertFalse(policy.registerSuccessfulRefresh(at: start.addingTimeInterval(Double(refreshOffset))))
        }
        XCTAssertFalse(policy.registerSuccessfulRefresh(at: start.addingTimeInterval(6 * 24 * 60 * 60)))
        XCTAssertTrue(policy.registerSuccessfulRefresh(at: start.addingTimeInterval(7 * 24 * 60 * 60)))
    }

    func testAppReviewPromptPolicyHonorsEngagementWindowBeyondExactBoundary() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let start = Date(timeIntervalSince1970: 1_788_475_200)
        let policy = AppReviewPromptPolicy(
            defaults: defaults,
            appVersion: "1.1",
            minimumSuccessfulRefreshes: 1,
            minimumEngagementDuration: 7 * 24 * 60 * 60
        )

        XCTAssertFalse(policy.registerSuccessfulRefresh(at: start))
        XCTAssertFalse(policy.registerSuccessfulRefresh(at: start.addingTimeInterval(6 * 24 * 60 * 60)))
        XCTAssertTrue(policy.registerSuccessfulRefresh(at: start.addingTimeInterval(8 * 24 * 60 * 60)))
    }

    func testAppReviewPromptPolicyRejectsSameVersionAfterEligibilityRecurs() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let start = Date(timeIntervalSince1970: 1_788_475_200)
        let initialPolicy = AppReviewPromptPolicy(
            defaults: defaults,
            appVersion: "1.1",
            minimumSuccessfulRefreshes: 1,
            minimumEngagementDuration: 0,
            minimumPromptInterval: 0
        )
        XCTAssertTrue(initialPolicy.registerSuccessfulRefresh(at: start))

        let sameVersionPolicy = AppReviewPromptPolicy(
            defaults: defaults,
            appVersion: "1.1",
            minimumSuccessfulRefreshes: 1,
            minimumEngagementDuration: 0,
            minimumPromptInterval: 0
        )
        XCTAssertFalse(sameVersionPolicy.registerSuccessfulRefresh(at: start.addingTimeInterval(1)))
    }
}

final class ProviderMetricTileGridTests: XCTestCase {
    func testUnavailableUsageTilePreservesAutomaticRingWidth() {
        XCTAssertEqual(ProviderMetricTileGridResolver.resolvedWidth(
            preference: .automatic, kind: .unavailableUsage("Unavailable"),
            visualizationStyle: .circularRing, usesRegularHorizontalSizeClass: false,
            collapsesToSingleColumn: false
        ), .half)
    }
}
