import Combine
import XCTest
@testable import CodexBarIOS

final class AccountPlanAccessTests: XCTestCase {
    @MainActor
    func testEveryInsertionPathRefusesBeforeSavingConfigurationOrCredentials() throws {
        let fixture = try AccountPlanFixture(plan: .free)
        defer { fixture.cleanUp() }
        let first = try XCTUnwrap(fixture.store.addAccount(for: .codex))
        let saved = fixture.defaults.data(forKey: "providerConfigurations")

        XCTAssertNil(fixture.store.addAccount(for: .claude))
        XCTAssertTrue(fixture.store.requestedProPresentation)
        fixture.store.dismissProPresentation()
        XCTAssertNil(fixture.store.addAccount(for: .copilot, copilotScope: .organization))
        XCTAssertTrue(fixture.store.requestedProPresentation)
        fixture.store.dismissProPresentation()
        let imported = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)
        XCTAssertFalse(fixture.store.update(imported))
        XCTAssertTrue(fixture.store.requestedProPresentation)
        fixture.store.dismissProPresentation()
        XCTAssertFalse(fixture.store.replaceCredential("must-not-save", for: imported))
        XCTAssertTrue(fixture.store.requestedProPresentation)
        XCTAssertNil(try fixture.secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: imported)))
        XCTAssertEqual(fixture.store.configurations, [first])
        XCTAssertEqual(fixture.defaults.data(forKey: "providerConfigurations"), saved)
    }

    @MainActor
    func testCursorConnectRefusesUnsavedAccountBeforeWritingCredential() throws {
        let fixture = try AccountPlanFixture(plan: .free)
        defer { fixture.cleanUp() }
        let first = try XCTUnwrap(fixture.store.addAccount(for: .codex))
        let cursor = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)
        let keychainAccount = ProviderConfigurationStore.keychainAccount(for: cursor)
        let saved = fixture.defaults.data(forKey: "providerConfigurations")

        XCTAssertNil(fixture.store.connectCursorAccount(cursor, credential: "must-not-save"))

        XCTAssertTrue(fixture.store.requestedProPresentation)
        XCTAssertNil(try fixture.secrets.readSecret(account: keychainAccount))
        XCTAssertEqual(fixture.store.configurations, [first])
        XCTAssertEqual(fixture.defaults.data(forKey: "providerConfigurations"), saved)
        try fixture.secrets.saveSecret("preserved-orphan", account: keychainAccount)
        XCTAssertNil(fixture.store.connectCursorAccount(cursor, credential: "must-not-replace"))
        XCTAssertEqual(try fixture.secrets.readSecret(account: keychainAccount), "preserved-orphan")
    }

    @MainActor
    func testCursorDisconnectPreservesRefusedAccountSecretAndStillDisconnectsSavedAccounts() throws {
        let fixture = try AccountPlanFixture(plan: .free)
        defer { fixture.cleanUp() }
        let saved = try XCTUnwrap(fixture.store.addAccount(for: .cursor))
        XCTAssertTrue(fixture.store.saveSecret("saved-account-secret", for: saved))
        let unsaved = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)
        let orphanKey = ProviderConfigurationStore.keychainAccount(for: unsaved)
        try fixture.secrets.saveSecret("preserved-orphan", account: orphanKey)

        XCTAssertNil(fixture.store.disconnectCursorAccount(unsaved))

        XCTAssertTrue(fixture.store.requestedProPresentation)
        XCTAssertEqual(try fixture.secrets.readSecret(account: orphanKey), "preserved-orphan")
        XCTAssertEqual(fixture.store.configurations, [saved])
        XCTAssertTrue(fixture.store.hasSecret(for: saved))
        fixture.store.dismissProPresentation()
        let disconnected = try XCTUnwrap(fixture.store.disconnectCursorAccount(saved))
        XCTAssertEqual(disconnected.id, saved.id)
        XCTAssertEqual(disconnected.isEnabled, saved.isEnabled)
        XCTAssertFalse(fixture.store.hasSecret(for: saved))
        XCTAssertEqual(fixture.store.configurations.count, 1)
        XCTAssertEqual(try fixture.secrets.readSecret(account: orphanKey), "preserved-orphan")
        XCTAssertFalse(fixture.store.requestedProPresentation)
    }

    @MainActor
    func testOpenCodeBootstrapImporterCannotBypassLimitOrSaveOrphanSecret() throws {
        let fixture = try AccountPlanFixture(plan: .free)
        defer { fixture.cleanUp() }
        let first = try XCTUnwrap(fixture.store.addAccount(for: .codex))
        let payload = "OPENCODE_ZEN_AUTH_COOKIE=fixture-cookie\nOPENCODE_ZEN_WORKSPACE_ID=wrk_fixture"
        let imported = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)

        XCTAssertFalse(OpenCodeZenBootstrapImporter.importPayload(payload, configurationStore: fixture.store))
        XCTAssertEqual(fixture.store.configurations, [first])
        XCTAssertNil(try fixture.secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: imported)))
        XCTAssertTrue(fixture.store.requestedProPresentation)

        fixture.store.applyPlanAccess(hasProAccess: true, isResolved: true)
        XCTAssertTrue(OpenCodeZenBootstrapImporter.importPayload(payload, configurationStore: fixture.store))
        XCTAssertEqual(fixture.store.configurations.count, 2)
        XCTAssertTrue(fixture.store.hasSecret(for: imported))
    }

    @MainActor
    func testAutomaticBootstrapWaitsAtLimitWithoutOpeningPro() throws {
        let fixture = try AccountPlanFixture(plan: .free)
        defer { fixture.cleanUp() }
        _ = try XCTUnwrap(fixture.store.addAccount(for: .codex))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let importURL = directory.appendingPathComponent(OpenCodeZenBootstrapImporter.importFileName)
        try Data("OPENCODE_ZEN_AUTH_COOKIE=fixture\nOPENCODE_ZEN_WORKSPACE_ID=wrk_fixture".utf8).write(to: importURL)

        OpenCodeZenBootstrapImporter.importIfNeeded(configurationStore: fixture.store, importDirectory: directory)

        XCTAssertFalse(fixture.store.requestedProPresentation)
        XCTAssertTrue(fixture.store.configurations(for: .openCodeZen).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: importURL.path))
    }

    @MainActor
    func testHiddenAntigravityAccountsDoNotConsumeOrBypassVisibleAccountLimit() throws {
        let fixture = try AccountPlanFixture(plan: .free)
        defer { fixture.cleanUp() }
        let hidden = try XCTUnwrap(fixture.store.addAccount(for: .antigravity))
        XCTAssertTrue(fixture.store.canAddAccount(for: .gemini))
        let gemini = try XCTUnwrap(fixture.store.addAccount(for: .gemini))
        let secondHidden = ProviderAccountConfiguration.defaultConfiguration(for: .antigravity)
        XCTAssertTrue(fixture.store.update(secondHidden))
        XCTAssertTrue(fixture.store.linkGeminiCodingAccount(hidden, to: gemini, confirmedSameAccount: true))
        XCTAssertEqual(fixture.store.activeAccountCandidates, [gemini])
        XCTAssertEqual(fixture.store.accountAccess.activeAccountID, gemini.id)
        XCTAssertTrue(fixture.store.accountAccess.pausedAccountIDs.isEmpty)
        XCTAssertFalse(fixture.store.accountAccess.permitsRefresh(hidden))
        XCTAssertFalse(fixture.store.canAddAccount(for: .claude))
        XCTAssertNil(fixture.store.addAccount(for: .claude))
    }

    @MainActor
    func testDowngradeAndUpgradePreserveEnabledChoicesCredentialsLayoutsOrderAndAlertSettings() throws {
        let fixture = try AccountPlanFixture()
        defer { fixture.cleanUp() }
        let first = try XCTUnwrap(fixture.store.addAccount(for: .codex))
        let second = try XCTUnwrap(fixture.store.addAccount(for: .claude))
        var disabled = try XCTUnwrap(fixture.store.addAccount(for: .openRouter))
        disabled.isEnabled = false
        XCTAssertTrue(fixture.store.update(disabled))
        XCTAssertTrue(fixture.store.saveSecret("retained-secret", for: second))
        fixture.store.updateDashboardCardOrder([second.id, first.id, disabled.id])
        _ = fixture.store.reconcileMetricLayout(accountID: second.id, availableMetricIDs: ["claude.weekly"])
        fixture.store.updateMetricVisibility(false, accountID: second.id, metricID: "claude.weekly")
        fixture.store.updateUsageAlertsEnabled(true)
        let configurations = fixture.store.configurations
        let encodedConfigurations = fixture.defaults.data(forKey: "providerConfigurations")
        let layouts = fixture.store.metricLayouts
        let order = fixture.store.dashboardCardOrder
        let alertSettings = fixture.store.usageAlertSettings

        fixture.store.applyPlanAccess(hasProAccess: false, isResolved: true)
        XCTAssertEqual(fixture.store.accountAccess.activeAccountID, second.id)
        XCTAssertEqual(fixture.store.accountAccess.pausedAccountIDs, [first.id])
        XCTAssertTrue(fixture.store.accountAccess.needsActiveAccountChoice)
        XCTAssertFalse(fixture.store.accountAccess.permitsRefresh(first))
        XCTAssertTrue(fixture.store.accountAccess.permitsRefresh(second))
        XCTAssertFalse(fixture.store.accountAccess.permitsRefresh(disabled))

        fixture.store.applyPlanAccess(hasProAccess: true, isResolved: true)
        XCTAssertTrue(fixture.store.accountAccess.pausedAccountIDs.isEmpty)
        XCTAssertTrue(fixture.store.accountAccess.permitsRefresh(first))
        XCTAssertTrue(fixture.store.accountAccess.permitsRefresh(second))
        XCTAssertFalse(fixture.store.accountAccess.permitsRefresh(disabled))
        XCTAssertEqual(fixture.store.configurations, configurations)
        XCTAssertEqual(fixture.defaults.data(forKey: "providerConfigurations"), encodedConfigurations)
        XCTAssertEqual(fixture.store.metricLayouts, layouts)
        XCTAssertEqual(fixture.store.dashboardCardOrder, order)
        XCTAssertEqual(fixture.store.usageAlertSettings, alertSettings)
        XCTAssertEqual(try fixture.secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: second)), "retained-secret")
    }

    @MainActor
    func testChoicePersistsAndOnlyPromptsOncePerDowngrade() throws {
        let fixture = try AccountPlanFixture()
        defer { fixture.cleanUp() }
        let accounts = try addThreeAccounts(to: fixture.store)
        fixture.store.applyPlanAccess(hasProAccess: false, isResolved: true, dashboardOrder: accounts.reversed().map(\.id))
        XCTAssertEqual(fixture.store.accountAccess.activeAccountID, accounts[2].id)
        let awaitingChoice = ProviderConfigurationStore(
            initialPlanAccess: .free, defaults: fixture.defaults, secretStore: fixture.secrets, widgetSnapshotDefaults: nil
        )
        XCTAssertTrue(awaitingChoice.accountAccess.needsActiveAccountChoice)
        XCTAssertTrue(fixture.store.chooseActiveAccount(accounts[1].id))
        XCTAssertEqual(fixture.defaults.string(forKey: "freeActiveAccountID"), accounts[1].id)
        fixture.store.updateAccountAccessOrder(accounts.map(\.id))
        XCTAssertEqual(fixture.store.accountAccess.activeAccountID, accounts[1].id)
        XCTAssertFalse(fixture.store.accountAccess.needsActiveAccountChoice)

        let reopened = ProviderConfigurationStore(defaults: fixture.defaults, secretStore: fixture.secrets, widgetSnapshotDefaults: nil)
        XCTAssertFalse(reopened.accountAccess.needsActiveAccountChoice)
        reopened.applyPlanAccess(hasProAccess: false, isResolved: true)
        XCTAssertEqual(reopened.accountAccess.activeAccountID, accounts[1].id)
        XCTAssertFalse(reopened.accountAccess.needsActiveAccountChoice)
        reopened.applyPlanAccess(hasProAccess: false, isResolved: true)
        XCTAssertFalse(reopened.accountAccess.needsActiveAccountChoice)
        reopened.applyPlanAccess(hasProAccess: true, isResolved: true)
        reopened.applyPlanAccess(hasProAccess: false, isResolved: true)
        XCTAssertTrue(reopened.accountAccess.needsActiveAccountChoice)
        reopened.dismissActiveAccountChoice()
        XCTAssertFalse(reopened.accountAccess.needsActiveAccountChoice)
        reopened.requestActiveAccountChoice()
        XCTAssertTrue(reopened.accountAccess.needsActiveAccountChoice)
    }

    @MainActor
    func testRevalidationAfterRemovalDisablingAndReenablingUsesRemainingCandidates() throws {
        let fixture = try AccountPlanFixture()
        defer { fixture.cleanUp() }
        let accounts = try addThreeAccounts(to: fixture.store)
        fixture.store.applyPlanAccess(hasProAccess: false, isResolved: true, dashboardOrder: accounts.map(\.id))
        XCTAssertTrue(fixture.store.chooseActiveAccount(accounts[0].id))
        XCTAssertTrue(fixture.store.removeAccount(accounts[0]))
        XCTAssertEqual(fixture.store.accountAccess.activeAccountID, accounts[1].id)
        XCTAssertTrue(fixture.store.accountAccess.needsActiveAccountChoice)
        var disabled = accounts[1]
        disabled.isEnabled = false
        XCTAssertTrue(fixture.store.update(disabled))
        XCTAssertEqual(fixture.store.accountAccess.activeAccountID, accounts[2].id)
        XCTAssertFalse(fixture.store.accountAccess.needsActiveAccountChoice)
        XCTAssertFalse(fixture.store.chooseActiveAccount(disabled.id))
        XCTAssertFalse(fixture.store.chooseActiveAccount("missing-account"))
        XCTAssertTrue(fixture.store.removeAccount(accounts[2]))
        XCTAssertNil(fixture.store.freeActiveAccountID)
        XCTAssertNil(fixture.store.accountAccess.activeAccountID)
        XCTAssertFalse(fixture.store.accountAccess.permitsRefresh(disabled))
        XCTAssertTrue(fixture.store.canAddAccount(for: .copilot))
        let newAccount = try XCTUnwrap(fixture.store.addAccount(for: .copilot))
        XCTAssertEqual(fixture.store.accountAccess.activeAccountID, newAccount.id)
        disabled.isEnabled = true
        XCTAssertTrue(fixture.store.update(disabled))
        XCTAssertEqual(fixture.store.accountAccess.activeAccountID, newAccount.id)
        XCTAssertEqual(fixture.store.accountAccess.pausedAccountIDs, [disabled.id])
    }

    @MainActor
    func testResetRevalidatesCompleteAndPartialDeletion() throws {
        let fixture = try AccountPlanFixture()
        defer { fixture.cleanUp() }
        let accounts = try addThreeAccounts(to: fixture.store)
        let failingSecrets = AccountPlanFailingDeletes(
            accounts: Set(accounts.dropFirst().map { ProviderConfigurationStore.keychainAccount(for: $0) })
        )
        let store = ProviderConfigurationStore(
            initialPlanAccess: .free, defaults: fixture.defaults, secretStore: failingSecrets, widgetSnapshotDefaults: nil
        )
        XCTAssertTrue(store.chooseActiveAccount(accounts[0].id))
        XCTAssertFalse(store.resetAccounts())
        XCTAssertEqual(Set(store.configurations.map(\.id)), Set(accounts.dropFirst().map(\.id)))
        XCTAssertEqual(store.accountAccess.activeAccountID, accounts[1].id)
        XCTAssertTrue(store.accountAccess.needsActiveAccountChoice)
        XCTAssertTrue(store.configurations.allSatisfy(\.isEnabled))

        let retry = ProviderConfigurationStore(
            initialPlanAccess: .free, defaults: fixture.defaults, secretStore: fixture.secrets, widgetSnapshotDefaults: nil
        )
        XCTAssertTrue(retry.resetAccounts())
        XCTAssertNil(retry.freeActiveAccountID)
        XCTAssertNil(retry.accountAccess.activeAccountID)
        XCTAssertFalse(retry.accountAccess.needsActiveAccountChoice)
        XCTAssertTrue(retry.canAddAccount(for: .codex))
    }

    @MainActor
    func testPartialResetWithOneRemainingAccountSelectsItAutomatically() throws {
        let fixture = try AccountPlanFixture()
        defer { fixture.cleanUp() }
        let accounts = try addThreeAccounts(to: fixture.store)
        let secrets = AccountPlanFailingDeletes(accounts: [ProviderConfigurationStore.keychainAccount(for: accounts[2])])
        let store = ProviderConfigurationStore(
            initialPlanAccess: .free, defaults: fixture.defaults, secretStore: secrets, widgetSnapshotDefaults: nil
        )
        XCTAssertTrue(store.chooseActiveAccount(accounts[0].id))

        XCTAssertFalse(store.resetAccounts())

        XCTAssertEqual(store.configurations, [accounts[2]])
        XCTAssertEqual(store.freeActiveAccountID, accounts[2].id)
        XCTAssertTrue(store.accountAccess.permitsRefresh(accounts[2]))
        XCTAssertFalse(store.accountAccess.needsActiveAccountChoice)
    }

    @MainActor
    func testUnresolvedLaunchDoesNotRecordDowngradeAndCachedProStillRefreshes() throws {
        let fixture = try AccountPlanFixture()
        defer { fixture.cleanUp() }
        let accounts = try addThreeAccounts(to: fixture.store)
        let store = ProviderConfigurationStore(defaults: fixture.defaults, secretStore: fixture.secrets, widgetSnapshotDefaults: nil)
        XCTAssertFalse(store.accountAccess.isResolved)
        XCTAssertFalse(store.accountAccess.needsActiveAccountChoice)
        XCTAssertFalse(store.accountAccess.permitsRefresh(accounts[0]))
        XCTAssertEqual(fixture.defaults.object(forKey: "lastResolvedPlanHadProAccess") as? Bool, true)
        store.applyPlanAccess(hasProAccess: true, isResolved: false)
        XCTAssertTrue(store.accountAccess.permitsRefresh(accounts[0]))
        XCTAssertTrue(store.accountAccess.permitsRefresh(accounts[1]))
        XCTAssertFalse(store.accountAccess.needsActiveAccountChoice)
        store.applyPlanAccess(hasProAccess: false, isResolved: true)
        XCTAssertTrue(store.accountAccess.needsActiveAccountChoice)
    }

    @MainActor
    func testPublishedAccessUsesAlreadyCommittedConfigurationValues() throws {
        let fixture = try AccountPlanFixture()
        defer { fixture.cleanUp() }
        let accounts = try addThreeAccounts(to: fixture.store)
        fixture.store.applyPlanAccess(hasProAccess: false, isResolved: true, dashboardOrder: accounts.map(\.id))
        XCTAssertTrue(fixture.store.chooseActiveAccount(accounts[0].id))
        var observedConfiguration: ProviderAccountConfiguration?
        var observedAccess: AccountPlanAccess?
        let subscription = fixture.store.$accountAccess.dropFirst().sink { access in
            observedConfiguration = fixture.store.configuration(accountID: accounts[0].id)
            observedAccess = access
        }
        defer { subscription.cancel() }
        var disabled = accounts[0]
        disabled.isEnabled = false
        XCTAssertTrue(fixture.store.update(disabled))
        XCTAssertEqual(observedConfiguration, disabled)
        XCTAssertEqual(observedAccess?.activeAccountID, accounts[1].id)
        XCTAssertEqual(observedAccess?.pausedAccountIDs, [accounts[2].id])
    }

    @MainActor
    func testSavedFreeChoiceIsRevalidatedDuringProWithoutShowingChooser() throws {
        let fixture = try AccountPlanFixture()
        defer { fixture.cleanUp() }
        let accounts = try addThreeAccounts(to: fixture.store)
        fixture.store.applyPlanAccess(hasProAccess: false, isResolved: true)
        XCTAssertTrue(fixture.store.chooseActiveAccount(accounts[0].id))
        fixture.store.applyPlanAccess(hasProAccess: true, isResolved: true)

        XCTAssertTrue(fixture.store.removeAccount(accounts[0]))

        XCTAssertEqual(fixture.store.freeActiveAccountID, accounts[1].id)
        XCTAssertFalse(fixture.store.accountAccess.needsActiveAccountChoice)
        XCTAssertTrue(fixture.store.resetAccounts())
        XCTAssertNil(fixture.store.freeActiveAccountID)
    }

    @MainActor
    func testExplicitChooserWorksForSingleAndDisabledAccounts() throws {
        let fixture = try AccountPlanFixture(plan: .free)
        defer { fixture.cleanUp() }
        var account = try XCTUnwrap(fixture.store.addAccount(for: .codex))
        XCTAssertFalse(fixture.store.accountAccess.needsActiveAccountChoice)
        fixture.store.requestActiveAccountChoice()
        XCTAssertTrue(fixture.store.accountAccess.needsActiveAccountChoice)
        fixture.store.dismissActiveAccountChoice()
        account.isEnabled = false
        XCTAssertTrue(fixture.store.update(account))
        fixture.store.requestActiveAccountChoice()
        XCTAssertTrue(fixture.store.accountAccess.needsActiveAccountChoice)
        XCTAssertFalse(fixture.store.chooseActiveAccount(account.id))
        XCTAssertNil(fixture.store.accountAccess.activeAccountID)
    }

    @MainActor
    private func addThreeAccounts(to store: ProviderConfigurationStore) throws -> [ProviderAccountConfiguration] {
        try [ProviderID.codex, .claude, .openRouter].map { try XCTUnwrap(store.addAccount(for: $0)) }
    }
}

@MainActor
private struct AccountPlanFixture {
    let suite = "AccountPlanAccessTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let secrets = MemorySecretStore()
    let store: ProviderConfigurationStore

    init(plan: AccountPlanAccess = .unrestricted) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        store = ProviderConfigurationStore(
            initialPlanAccess: plan, defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: nil
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }
}

private struct AccountPlanFailingDeletes: SecretStore {
    let accounts: Set<String>

    func readSecret(account: String) throws -> String? { nil }
    func saveSecret(_ secret: String, account: String) throws {}
    func deleteSecret(account: String) throws {
        if accounts.contains(account) { throw KeychainError.unhandledStatus(-25308) }
    }
}
