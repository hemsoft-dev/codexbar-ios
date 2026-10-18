import XCTest
@testable import CodexBarIOS
import CryptoKit
import Darwin
#if canImport(AuthenticationServices) && canImport(UIKit)
import AuthenticationServices
#endif

final class ConfigurationAndAuthTests: XCTestCase {
    private enum RandomGeneratorTestError: Error {
        case failed
    }

    func testProviderAuthMethodMigratesLegacyValuesToBrowserSession() throws {
        let decoder = JSONDecoder()

        for legacyValue in ["codexAuthJSON", "oauth"] {
            let data = Data("\"\(legacyValue)\"".utf8)
            XCTAssertEqual(try decoder.decode(ProviderAuthMethod.self, from: data), .browserSession)
        }
    }

    @MainActor
    func testProviderConfigurationStoreLoadsAccountsWithLegacyAuthMethods() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(
            Data(
                #"""
                [
                  {"id":"codex.legacy","providerID":"codex","authMethod":"codexAuthJSON"},
                  {"id":"claude.legacy","providerID":"claude","authMethod":"oauth"}
                ]
                """#.utf8
            ),
            forKey: "providerConfigurations"
        )

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())

        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: store.configurations.map { ($0.id, $0.authMethod) }),
            [
                "codex.legacy": .browserSession,
                "claude.legacy": .browserSession,
            ]
        )
    }

    func testKeychainSecretDecoderRejectsNonUTF8Data() {
        XCTAssertThrowsError(try KeychainService.decodeSecret(Data([0xFF]))) { error in
            XCTAssertEqual(error as? KeychainError, .invalidSecretData)
            XCTAssertEqual(error.localizedDescription, "The saved credential contains invalid data.")
        }
    }

    @MainActor
    func testProviderConfigurationStoreStartsWithoutAccounts() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())

        XCTAssertTrue(store.configurations.isEmpty)
        XCTAssertFalse(store.isConfigurationRecoveryRequired)
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testProviderConfigurationStoreTreatsMissingGroupDataAsEmpty() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        var savedAccount = ProviderAccountConfiguration(providerID: .openRouter, authMethod: .apiKey)
        savedAccount.groupID = "missing-group"
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(try JSONEncoder().encode([savedAccount]), forKey: "providerConfigurations")

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())

        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertNil(store.configuration(accountID: savedAccount.id)?.groupID)
        XCTAssertFalse(store.isGroupRecoveryRequired)
        XCTAssertFalse(store.isPersistenceRecoveryRequired)
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testProviderConfigurationStorePreservesMalformedGroupDataAndAccountGrouping() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let malformedGroupData = Data(#"{"groups":"not-an-array"}"#.utf8)
        var savedAccount = ProviderAccountConfiguration(providerID: .openRouter, authMethod: .apiKey)
        savedAccount.groupID = "preserved-group"
        let configurationData = try JSONEncoder().encode([savedAccount])
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(malformedGroupData, forKey: "providerAccountGroups")
        defaults.set(configurationData, forKey: "providerConfigurations")

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())

        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertEqual(store.configuration(accountID: savedAccount.id)?.groupID, "preserved-group")
        XCTAssertTrue(store.isGroupRecoveryRequired)
        XCTAssertTrue(store.isPersistenceRecoveryRequired)
        XCTAssertEqual(
            store.lastError,
            "Saved group data couldn't be read. Replace the damaged group list in Settings to resume saving accounts and groups."
        )
        XCTAssertEqual(defaults.data(forKey: "providerAccountGroups"), malformedGroupData)
        XCTAssertEqual(defaults.data(forKey: "providerConfigurations"), configurationData)

        XCTAssertNil(store.addGroup(named: "Blocked Group"))
        var attemptedUpdate = savedAccount
        attemptedUpdate.accountLabel = "Blocked Rename"
        XCTAssertFalse(store.update(attemptedUpdate))
        XCTAssertEqual(store.configuration(accountID: savedAccount.id), savedAccount)
        XCTAssertEqual(defaults.data(forKey: "providerAccountGroups"), malformedGroupData)
        XCTAssertEqual(defaults.data(forKey: "providerConfigurations"), configurationData)
    }

    @MainActor
    func testProviderConfigurationStoreRestoresGroupRecoveryErrorAfterCredentialReadRecovers() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        var savedAccount = ProviderAccountConfiguration(providerID: .openRouter, authMethod: .apiKey)
        savedAccount.groupID = "preserved-group"
        let secretStore = SelectiveReadFailureSecretStore()
        let keychainAccount = ProviderConfigurationStore.keychainAccount(for: savedAccount)
        secretStore.failingAccount = keychainAccount
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(Data("not-json".utf8), forKey: "providerAccountGroups")
        defaults.set(try JSONEncoder().encode([savedAccount]), forKey: "providerConfigurations")

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)

        XCTAssertTrue(store.isGroupRecoveryRequired)
        XCTAssertEqual(
            store.lastError,
            "Could not read the saved credential for \(savedAccount.displayName): Keychain operation failed with status -25308."
        )

        secretStore.failingAccount = nil
        store.refreshSecretAvailability()

        XCTAssertTrue(store.isGroupRecoveryRequired)
        XCTAssertEqual(
            store.lastError,
            "Saved group data couldn't be read. Replace the damaged group list in Settings to resume saving accounts and groups."
        )
    }

    @MainActor
    func testProviderConfigurationStoreReplacesMalformedGroupsThenSavesNormally() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        var savedAccount = ProviderAccountConfiguration(providerID: .openRouter, authMethod: .apiKey)
        savedAccount.groupID = "damaged-group"
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(Data("not-json".utf8), forKey: "providerAccountGroups")
        defaults.set(try JSONEncoder().encode([savedAccount]), forKey: "providerConfigurations")
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())

        XCTAssertTrue(store.replaceCorruptedGroups())

        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertNil(store.configuration(accountID: savedAccount.id)?.groupID)
        XCTAssertFalse(store.isGroupRecoveryRequired)
        XCTAssertFalse(store.isPersistenceRecoveryRequired)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(
            try JSONDecoder().decode(
                [ProviderAccountGroup].self,
                from: try XCTUnwrap(defaults.data(forKey: "providerAccountGroups"))
            ),
            []
        )

        let replacementGroup = try XCTUnwrap(store.addGroup(named: "Recovered Group"))
        var regroupedAccount = try XCTUnwrap(store.configuration(accountID: savedAccount.id))
        regroupedAccount.groupID = replacementGroup.id
        XCTAssertTrue(store.update(regroupedAccount))

        let reloadedStore = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: EmptySecretStore()
        )

        XCTAssertEqual(reloadedStore.groups, [replacementGroup])
        XCTAssertEqual(reloadedStore.configuration(accountID: savedAccount.id)?.groupID, replacementGroup.id)
        XCTAssertFalse(reloadedStore.isPersistenceRecoveryRequired)
        XCTAssertNil(reloadedStore.lastError)
    }

    @MainActor
    func testProviderConfigurationStorePreservesMalformedDataAndSurfacesRecoveryState() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        let malformedData = Data(#"{"accounts":"not-an-array"}"#.utf8)
        let savedAccount = ProviderAccountConfiguration(providerID: .openRouter, authMethod: .apiKey)
        let savedGroup = ProviderAccountGroup(id: "saved-group", name: "Saved Group")
        let keychainAccount = ProviderConfigurationStore.keychainAccount(for: savedAccount)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(malformedData, forKey: "providerConfigurations")
        defaults.set(try JSONEncoder().encode([savedGroup]), forKey: "providerAccountGroups")
        try secretStore.saveSecret("preserved-secret", account: keychainAccount)

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)

        XCTAssertTrue(store.configurations.isEmpty)
        XCTAssertEqual(store.groups, [savedGroup])
        XCTAssertTrue(store.isConfigurationRecoveryRequired)
        XCTAssertEqual(
            store.lastError,
            "Saved account data couldn't be read. Replace the damaged account list in Settings to resume saving configurations."
        )
        XCTAssertEqual(defaults.data(forKey: "providerConfigurations"), malformedData)
        XCTAssertEqual(try secretStore.readSecret(account: keychainAccount), "preserved-secret")

        let attemptedAccount = store.addAccount(for: .codex)
        var attemptedUpdate = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        attemptedUpdate.accountLabel = "Imported OpenCode"
        var attemptedGroupUpdate = savedGroup
        attemptedGroupUpdate.name = "Blocked Rename"

        XCTAssertFalse(store.update(attemptedUpdate))
        XCTAssertFalse(store.updateGroup(attemptedGroupUpdate))
        XCTAssertTrue(store.configurations.isEmpty)
        XCTAssertEqual(store.groups, [savedGroup])
        XCTAssertNil(attemptedAccount)
        XCTAssertEqual(defaults.data(forKey: "providerConfigurations"), malformedData)
        XCTAssertTrue(store.isConfigurationRecoveryRequired)
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(try secretStore.readSecret(account: keychainAccount), "preserved-secret")
    }

    @MainActor
    func testProviderConfigurationStoreRequiresRecoveryForIdenticalDuplicateAccountIDs() throws {
        for isEnabled in [true, false] {
            let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer {
                defaults.removePersistentDomain(forName: suiteName)
            }
            let configuration = ProviderAccountConfiguration(
                id: "openRouter.duplicate",
                providerID: .openRouter,
                isEnabled: isEnabled,
                accountLabel: "Saved OpenRouter",
                authMethod: .apiKey
            )
            let damagedData = try JSONEncoder().encode([configuration, configuration])
            defaults.set(damagedData, forKey: "providerConfigurations")

            let store = ProviderConfigurationStore(
                initialPlanAccess: .unrestricted,
                defaults: defaults,
                secretStore: EmptySecretStore()
            )

            XCTAssertTrue(store.configurations.isEmpty)
            XCTAssertTrue(store.isConfigurationRecoveryRequired)
            XCTAssertEqual(
                store.lastError,
                "Saved account data couldn't be read. Replace the damaged account list in Settings to resume saving configurations."
            )
            XCTAssertEqual(defaults.data(forKey: "providerConfigurations"), damagedData)
        }
    }

    @MainActor
    func testConflictingDuplicateAccountIDsRemainPreservedUntilExplicitReplacement() async throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        let savedGroup = ProviderAccountGroup(id: "saved-group", name: "Saved Group")
        let first = ProviderAccountConfiguration(
            id: "duplicate.account",
            providerID: .openRouter,
            accountLabel: "Primary",
            groupID: savedGroup.id,
            authMethod: .apiKey
        )
        let conflicting = ProviderAccountConfiguration(
            id: first.id,
            providerID: .moonshot,
            isEnabled: false,
            accountLabel: "Conflicting",
            authMethod: .apiKey
        )
        let damagedData = try JSONEncoder().encode([first, conflicting])
        let keychainAccount = ProviderConfigurationStore.keychainAccount(for: first)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(damagedData, forKey: "providerConfigurations")
        defaults.set(try JSONEncoder().encode([savedGroup]), forKey: "providerAccountGroups")
        try secretStore.saveSecret("preserved-secret", account: keychainAccount)

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let refreshService = UsageRefreshService(providers: [])
        let orchestrator = DashboardOrchestrator(
            refreshService: refreshService,
            configurationStore: store,
            historyStore: UsageHistoryStore(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier(),
            appReviewPromptPolicy: AppReviewPromptPolicy(defaults: defaults),
            widgetSnapshotCoordinator: WidgetSnapshotCoordinator(
                refreshService: refreshService,
                configurationStore: store,
                publishSnapshot: { _, _ in },
                publishSettings: { _ in }
            ),
            watchSnapshotCoordinator: WatchSnapshotCoordinator(
                refreshService: refreshService,
                configurationStore: store,
                publishSnapshot: { _, _, _ in }
            )
        )

        XCTAssertTrue(orchestrator.dashboardSections.isEmpty)
        _ = await orchestrator.refreshNow()
        XCTAssertTrue(refreshService.results.isEmpty)
        XCTAssertNil(store.addGroup(named: "Blocked Group"))
        XCTAssertFalse(store.update(first))
        XCTAssertFalse(store.saveSecret("replacement-secret", for: first))
        XCTAssertFalse(store.resetAccounts())
        XCTAssertTrue(store.configurations.isEmpty)
        XCTAssertEqual(store.groups, [savedGroup])
        XCTAssertEqual(defaults.data(forKey: "providerConfigurations"), damagedData)
        XCTAssertEqual(try secretStore.readSecret(account: keychainAccount), "preserved-secret")

        XCTAssertTrue(store.replaceCorruptedConfigurations())
        XCTAssertFalse(store.isConfigurationRecoveryRequired)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(
            try JSONDecoder().decode(
                [ProviderAccountConfiguration].self,
                from: try XCTUnwrap(defaults.data(forKey: "providerConfigurations"))
            ),
            []
        )
        XCTAssertEqual(try secretStore.readSecret(account: keychainAccount), "preserved-secret")

        let replacement = try XCTUnwrap(store.addAccount(for: .claude))
        XCTAssertTrue(store.saveSecret("recovered-secret", for: replacement))
        let reloadedStore = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)

        XCTAssertEqual(reloadedStore.configurations, [replacement])
        XCTAssertTrue(reloadedStore.hasSecret(for: replacement))
        XCTAssertFalse(reloadedStore.isConfigurationRecoveryRequired)
        XCTAssertNil(reloadedStore.lastError)
    }

    @MainActor
    func testProviderConfigurationStoreLoadsUniqueAccountIDsNormally() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let savedGroup = ProviderAccountGroup(id: "saved-group", name: "Saved Group")
        let grouped = ProviderAccountConfiguration(
            id: "openRouter.grouped",
            providerID: .openRouter,
            groupID: savedGroup.id,
            authMethod: .apiKey
        )
        let ungrouped = ProviderAccountConfiguration(
            id: "moonshot.ungrouped",
            providerID: .moonshot,
            groupID: "missing-group",
            authMethod: .apiKey
        )
        let savedData = try JSONEncoder().encode([grouped, ungrouped])
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(savedData, forKey: "providerConfigurations")
        defaults.set(try JSONEncoder().encode([savedGroup]), forKey: "providerAccountGroups")

        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: EmptySecretStore()
        )

        XCTAssertEqual(Set(store.configurations.map(\.id)), [grouped.id, ungrouped.id])
        XCTAssertEqual(store.configuration(accountID: grouped.id)?.groupID, savedGroup.id)
        XCTAssertNil(store.configuration(accountID: ungrouped.id)?.groupID)
        XCTAssertFalse(store.isConfigurationRecoveryRequired)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(defaults.data(forKey: "providerConfigurations"), savedData)
    }

    @MainActor
    func testProviderConfigurationStoreReplacesMalformedDataThenSavesNormally() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        let malformedData = Data("not-json".utf8)
        let savedAccount = ProviderAccountConfiguration(providerID: .openRouter, authMethod: .apiKey)
        let keychainAccount = ProviderConfigurationStore.keychainAccount(for: savedAccount)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(malformedData, forKey: "providerConfigurations")
        try secretStore.saveSecret("preserved-secret", account: keychainAccount)
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)

        XCTAssertTrue(store.replaceCorruptedConfigurations())

        XCTAssertFalse(store.isConfigurationRecoveryRequired)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(
            try JSONDecoder().decode(
                [ProviderAccountConfiguration].self,
                from: try XCTUnwrap(defaults.data(forKey: "providerConfigurations"))
            ),
            []
        )
        XCTAssertEqual(try secretStore.readSecret(account: keychainAccount), "preserved-secret")

        let replacement = try XCTUnwrap(store.addAccount(for: .claude))
        let reloadedStore = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)

        XCTAssertEqual(reloadedStore.configurations, [replacement])
        XCTAssertFalse(reloadedStore.isConfigurationRecoveryRequired)
        XCTAssertNil(reloadedStore.lastError)
        XCTAssertEqual(try secretStore.readSecret(account: keychainAccount), "preserved-secret")
    }

    @MainActor
    func testProviderConfigurationStorePreservesCopilotBrowserSession() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let oldCopilotConfiguration = ProviderAccountConfiguration(
            providerID: .copilot,
            authMethod: .browserSession
        )
        let data = try JSONEncoder().encode([oldCopilotConfiguration])
        defaults.set(data, forKey: "providerConfigurations")

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())

        XCTAssertEqual(store.configuration(for: .copilot).authMethod, .browserSession)
    }

    @MainActor
    func testProviderConfigurationStoreSupportsMultipleAccountsForProvider() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let original = try XCTUnwrap(store.addAccount(for: .copilot))
        let added = try XCTUnwrap(store.addAccount(for: .copilot))

        XCTAssertEqual(store.configurations(for: .copilot).count, 2)
        XCTAssertNotEqual(original.id, added.id)
        XCTAssertEqual(
            ProviderConfigurationStore.keychainAccount(for: original).hasPrefix("providerAccount.copilot."),
            true
        )
        XCTAssertTrue(
            ProviderConfigurationStore.keychainAccount(for: added)
                .hasPrefix("providerAccount.copilot.")
        )
    }

    @MainActor
    func testCursorIdentityChangeRemovesStaleEmailButPreservesCustomLabel() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        var cursor = try XCTUnwrap(store.addAccount(for: .cursor))
        cursor.accountLabel = "franz_hemmer@hotmail.com"
        XCTAssertTrue(store.update(cursor))

        XCTAssertEqual(store.cursorAccountLabelAfterIdentityChange(for: cursor), "")

        cursor.accountLabel = "Work Cursor"
        XCTAssertEqual(store.cursorAccountLabelAfterIdentityChange(for: cursor), "Work Cursor")

        cursor.accountLabel = "team@acme"
        XCTAssertEqual(store.cursorAccountLabelAfterIdentityChange(for: cursor), "team@acme")
    }

    @MainActor
    func testConnectingCursorAccountPersistsCredentialAndClearsStaleEmail() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        var cursor = try XCTUnwrap(store.addAccount(for: .cursor))
        cursor.accountLabel = "old@example.com"
        XCTAssertTrue(store.update(cursor))

        let connected = try XCTUnwrap(
            store.connectCursorAccount(cursor, credential: "replacement-token")
        )

        XCTAssertEqual(connected.accountLabel, "")
        XCTAssertEqual(connected.displayName, "Cursor")
        XCTAssertEqual(store.configuration(accountID: cursor.id), connected)
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: cursor)),
            "replacement-token"
        )
        XCTAssertTrue(store.hasSecret(for: cursor))
    }

    @MainActor
    func testDisconnectingCursorAccountPreservesOtherCursorCredential() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        var first = try XCTUnwrap(store.addAccount(for: .cursor))
        first.accountLabel = "first@example.com"
        XCTAssertTrue(store.update(first))
        let second = try XCTUnwrap(store.addAccount(for: .cursor))
        store.saveSecret("first-token", for: first)
        store.saveSecret("second-token", for: second)

        let disconnected = try XCTUnwrap(store.disconnectCursorAccount(first))

        XCTAssertFalse(store.hasSecret(for: first))
        XCTAssertEqual(disconnected.accountLabel, "")
        XCTAssertEqual(disconnected.displayName, "Cursor")
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: second)),
            "second-token"
        )
        XCTAssertTrue(store.hasSecret(for: second))
    }

    @MainActor
    func testFailedCursorCredentialReplacementPreservesExistingIdentity() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = FailingSaveSecretStore(secret: "existing-token")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        var cursor = try XCTUnwrap(store.addAccount(for: .cursor))
        cursor.accountLabel = "existing@example.com"
        XCTAssertTrue(store.update(cursor))

        XCTAssertNil(store.connectCursorAccount(cursor, credential: "replacement-token"))
        XCTAssertEqual(store.configuration(accountID: cursor.id)?.accountLabel, "existing@example.com")
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: cursor)),
            "existing-token"
        )
    }

    @MainActor
    func testProviderConfigurationStoreSurfacesSecretReadFailures() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: FailingReadSecretStore()
        )
        let claude = try XCTUnwrap(store.addAccount(for: .claude))

        XCTAssertFalse(store.hasSecret(for: claude))
        XCTAssertEqual(
            store.lastError,
            "Could not read the saved credential for Claude 1: Keychain unavailable"
        )
    }

    @MainActor
    func testProviderConfigurationStoreRequiresClaudeSecretForBrowserSession() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let claude = try XCTUnwrap(store.addAccount(for: .claude))

        XCTAssertFalse(store.isConfigured(claude))
        XCTAssertEqual(store.statusText(for: claude), "Not configured - sign in with Claude")

        store.saveSecret("claude-token", for: claude)

        XCTAssertTrue(store.isConfigured(claude))
        XCTAssertEqual(store.statusText(for: claude), "Claude 1 - live usage enabled")
    }

    @MainActor
    func testProviderConfigurationStoreRequestsOpenRouterManagementAPIKey() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        let openRouter = try XCTUnwrap(store.addAccount(for: .openRouter))

        XCTAssertFalse(store.isConfigured(openRouter))
        XCTAssertEqual(
            store.statusText(for: openRouter),
            "Not configured - enter OpenRouter Management API Key"
        )
    }

    @MainActor
    func testOpenCodeZenDisplaysOnDashboardWhenKeyIsSavedBeforeWorkspace() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let openCodeZen = try XCTUnwrap(store.addAccount(for: .openCodeZen))

        XCTAssertEqual(openCodeZen.accountLabel, "OpenCode Go + Zen 1")
        XCTAssertFalse(openCodeZen.hasCustomAccountLabel)
        XCTAssertEqual(
            openCodeZen.openCodeDisplayName(
                hasGoUsage: false,
                hasZenBalance: true
            ),
            "OpenCode Zen"
        )
        XCTAssertFalse(store.isConfigured(openCodeZen))
        XCTAssertFalse(store.shouldDisplayOnDashboard(openCodeZen))

        store.saveSecret("oczen-test-key", for: openCodeZen)

        XCTAssertFalse(store.isConfigured(openCodeZen))
        XCTAssertTrue(store.shouldDisplayOnDashboard(openCodeZen))
        XCTAssertEqual(store.statusText(for: openCodeZen), "Not configured - sign in with OpenCode to choose a workspace")
    }

    @MainActor
    func testProviderConfigurationStoreRejectsDuplicateAccountNames() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        var first = try XCTUnwrap(store.addAccount(for: .copilot))
        first.accountLabel = "Work"
        store.update(first)

        var second = try XCTUnwrap(store.addAccount(for: .codex))
        second.accountLabel = "work"
        store.update(second)

        XCTAssertEqual(store.lastError, "Account names must be unique.")
        XCTAssertNotEqual(store.configuration(accountID: second.id)?.accountLabel, "work")
    }

    @MainActor
    func testProviderConfigurationStoreRejectsDuplicateFallbackDisplayNames() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        var first = try XCTUnwrap(store.addAccount(for: .copilot))
        first.accountLabel = "Work Copilot"
        store.update(first)
        var second = try XCTUnwrap(store.addAccount(for: .copilot))
        second.accountLabel = "work copilot"

        XCTAssertFalse(store.update(second))
        XCTAssertEqual(store.lastError, "Account names must be unique.")
        XCTAssertNotEqual(store.configuration(accountID: second.id)?.displayName, "work copilot")
    }

    @MainActor
    func testProviderConfigurationStoreResetRemovesAccountsAndSecrets() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let account = try XCTUnwrap(store.addAccount(for: .claude))
        store.saveSecret("token", for: account)
        XCTAssertTrue(store.hasSecret(for: account))

        store.resetAccounts()

        XCTAssertTrue(store.configurations.isEmpty)
        XCTAssertFalse(store.hasSecret(for: account))
        XCTAssertNil(try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: account)))
    }

    @MainActor
    func testAccountRemovalKeepsAccountAndStateWhenCredentialDeletionFailsThenAllowsRetry() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = RetriableDeleteSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let account = try XCTUnwrap(store.addAccount(for: .openRouter))
        let alertID = "balance.\(account.id)"
        store.updateDashboardCardOrder([account.id])
        store.updateUsageAlertActiveIDs([alertID])
        XCTAssertTrue(store.saveSecret("existing-token", for: account))

        XCTAssertFalse(store.removeAccount(account))

        XCTAssertEqual(store.configuration(accountID: account.id), account)
        XCTAssertEqual(store.dashboardCardOrder, [account.id])
        XCTAssertEqual(store.usageAlertActiveIDs, [alertID])
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: account)),
            "existing-token"
        )
        XCTAssertNotNil(store.lastError)

        let reloadedStore = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        XCTAssertEqual(reloadedStore.configuration(accountID: account.id), account)
        XCTAssertEqual(reloadedStore.dashboardCardOrder, [account.id])
        XCTAssertEqual(reloadedStore.usageAlertActiveIDs, [alertID])

        secretStore.shouldFailDelete = false
        XCTAssertTrue(store.removeAccount(account))

        XCTAssertNil(store.configuration(accountID: account.id))
        XCTAssertNil(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: account))
        )
        XCTAssertNil(store.lastError)
        XCTAssertTrue(store.dashboardCardOrder.isEmpty)
        XCTAssertTrue(store.usageAlertActiveIDs.isEmpty)

        let storeAfterRemoval = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        XCTAssertNil(storeAfterRemoval.configuration(accountID: account.id))
        XCTAssertTrue(storeAfterRemoval.dashboardCardOrder.isEmpty)
        XCTAssertTrue(storeAfterRemoval.usageAlertActiveIDs.isEmpty)
    }

    @MainActor
    func testBulkAccountRemovalPreservesFailureWhenLaterAccountSucceeds() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = RetriableDeleteSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let failedAccount = try XCTUnwrap(store.addAccount(for: .openRouter))
        let removedAccount = try XCTUnwrap(store.addAccount(for: .moonshot))
        XCTAssertTrue(store.saveSecret("failed-token", for: failedAccount))
        XCTAssertTrue(store.saveSecret("removed-token", for: removedAccount))
        secretStore.shouldFailDelete = false
        secretStore.failingAccount = ProviderConfigurationStore.keychainAccount(for: failedAccount)

        XCTAssertTrue(store.removeAccounts([failedAccount, removedAccount]))

        XCTAssertEqual(store.configuration(accountID: failedAccount.id), failedAccount)
        XCTAssertNil(store.configuration(accountID: removedAccount.id))
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: failedAccount)),
            "failed-token"
        )
        XCTAssertNil(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: removedAccount))
        )
        XCTAssertNotNil(store.lastError)
    }

    @MainActor
    func testResetAccountsFailurePreservesAccountsAndDependentState() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: FailingDeleteSecretStore()
        )
        let account = try XCTUnwrap(store.addAccount(for: .openRouter))
        let alertID = "balance.\(account.id)"
        store.updateDashboardCardOrder([account.id])
        store.updateUsageAlertActiveIDs([alertID])

        XCTAssertFalse(store.resetAccounts())

        XCTAssertEqual(store.configuration(accountID: account.id), account)
        XCTAssertEqual(store.dashboardCardOrder, [account.id])
        XCTAssertEqual(store.usageAlertActiveIDs, [alertID])
        XCTAssertNotNil(store.lastError)
    }

    @MainActor
    func testResetAccountsCommitsSuccessfulCredentialDeletionsAndRetriesFailures() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = RetriableDeleteSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let removedAccount = try XCTUnwrap(store.addAccount(for: .claude))
        let failedAccount = try XCTUnwrap(store.addAccount(for: .openRouter))
        let removedAlertID = "usage.\(removedAccount.id).window"
        let failedAlertID = "balance.\(failedAccount.id)"
        store.updateDashboardCardOrder([removedAccount.id, failedAccount.id])
        store.updateUsageAlertActiveIDs([removedAlertID, failedAlertID])
        store.updateVisualizationStyle(.circularRing, accountID: removedAccount.id, metricID: "usage")
        store.updateVisualizationStyle(.semicircularDial, accountID: failedAccount.id, metricID: "balance")
        // Credential setup also clears Claude's billing session; inject deletion failure only for reset.
        secretStore.shouldFailDelete = false
        XCTAssertTrue(store.saveSecret("removed-token", for: removedAccount))
        XCTAssertTrue(store.saveSecret("failed-token", for: failedAccount))
        secretStore.failingAccount = ProviderConfigurationStore.keychainAccount(for: failedAccount)

        XCTAssertFalse(store.resetAccounts())

        XCTAssertNil(store.configuration(accountID: removedAccount.id))
        XCTAssertEqual(store.configuration(accountID: failedAccount.id), failedAccount)
        XCTAssertNil(
            try secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: removedAccount)
            )
        )
        XCTAssertEqual(
            try secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: failedAccount)
            ),
            "failed-token"
        )
        XCTAssertEqual(store.dashboardCardOrder, [failedAccount.id])
        XCTAssertEqual(store.usageAlertActiveIDs, [failedAlertID])
        XCTAssertNil(store.metricVisualizationPreferences[removedAccount.id])
        XCTAssertEqual(
            store.visualizationStyle(accountID: failedAccount.id, metricID: "balance"),
            .semicircularDial
        )
        XCTAssertTrue(store.hasIncompleteAccountReset)
        XCTAssertNotNil(store.lastError)

        let reloadedStore = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        XCTAssertNil(reloadedStore.configuration(accountID: removedAccount.id))
        XCTAssertEqual(reloadedStore.configuration(accountID: failedAccount.id), failedAccount)
        XCTAssertEqual(reloadedStore.dashboardCardOrder, [failedAccount.id])
        XCTAssertEqual(reloadedStore.usageAlertActiveIDs, [failedAlertID])
        XCTAssertNil(reloadedStore.metricVisualizationPreferences[removedAccount.id])
        XCTAssertEqual(
            reloadedStore.visualizationStyle(accountID: failedAccount.id, metricID: "balance"),
            .semicircularDial
        )
        XCTAssertTrue(reloadedStore.hasIncompleteAccountReset)

        secretStore.failingAccount = nil
        XCTAssertTrue(store.resetAccounts())

        XCTAssertTrue(store.configurations.isEmpty)
        XCTAssertTrue(store.dashboardCardOrder.isEmpty)
        XCTAssertTrue(store.usageAlertActiveIDs.isEmpty)
        XCTAssertTrue(store.metricVisualizationPreferences.isEmpty)
        XCTAssertFalse(store.hasIncompleteAccountReset)
        XCTAssertNil(
            try secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: failedAccount)
            )
        )
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testResetAccountsKeepsLegacyCredentialFailureRetryableWithoutConfigurations() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = RetriableDeleteSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let legacyAccount = ProviderConfigurationStore.keychainAccount(for: ProviderID.claude)
        try secretStore.saveSecret("legacy-token", account: legacyAccount)
        secretStore.shouldFailDelete = false
        secretStore.failingAccount = legacyAccount
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)

        XCTAssertFalse(store.resetAccounts())

        XCTAssertTrue(store.configurations.isEmpty)
        XCTAssertTrue(store.hasIncompleteAccountReset)
        XCTAssertTrue(store.isAccountCreationBlocked)
        var addAccountFlow = AddAccountFlowState()
        XCTAssertNil(addAccountFlow.select(.openRouter, configurationStore: store))
        XCTAssertTrue(store.configurations.isEmpty)
        XCTAssertEqual(try secretStore.readSecret(account: legacyAccount), "legacy-token")
        XCTAssertNotNil(store.lastError)

        let reloadedStore = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        XCTAssertTrue(reloadedStore.configurations.isEmpty)
        XCTAssertTrue(reloadedStore.hasIncompleteAccountReset)

        secretStore.failingAccount = nil
        XCTAssertTrue(reloadedStore.resetAccounts())

        XCTAssertFalse(reloadedStore.hasIncompleteAccountReset)
        XCTAssertFalse(reloadedStore.isAccountCreationBlocked)
        XCTAssertNil(try secretStore.readSecret(account: legacyAccount))
        XCTAssertNil(reloadedStore.lastError)
    }

    func testLoopbackOAuthCallbackServerAcceptsRequestsSplitAcrossWrites() async throws {
        let request = Data((
            "GET /callback?code=authorization-code&state=expected-state HTTP/1.1\r\n" +
                "Host: 127.0.0.1\r\nUser-Agent: CodexBarIOSTests\r\n\r\n"
        ).utf8)
        let splitOffsets = [1, 37, request.count - 1]

        for splitOffset in splitOffsets {
            let server = try await makeLoopbackCallbackServer(preferredPorts: [0])
            defer { server.cancel() }
            let callbackTask = Task {
                try await server.waitForCallback(timeoutNanoseconds: 2_000_000_000)
            }

            let response = try await sendRawHTTPRequest(
                port: server.port,
                chunks: [Data(request[..<splitOffset]), Data(request[splitOffset...])]
            )
            let callbackURL = try await callbackTask.value

            XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK"))
            XCTAssertEqual(callbackURL.path, "/callback")
            XCTAssertEqual(
                URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                    .queryItemValue(named: "code"),
                "authorization-code"
            )
        }
    }

    func testLoopbackOAuthCallbackServersAllocateDistinctEphemeralPorts() async throws {
        async let firstServer = makeLoopbackCallbackServer(preferredPorts: [0])
        async let secondServer = makeLoopbackCallbackServer(preferredPorts: [0])
        let (first, second) = try await (firstServer, secondServer)
        defer {
            first.cancel()
            second.cancel()
        }

        XCTAssertNotEqual(first.port, 0)
        XCTAssertNotEqual(second.port, 0)
        XCTAssertNotEqual(first.port, second.port)
    }

    func testLoopbackOAuthCallbackWaitFinishesImmediatelyWhenCanceled() async throws {
        let server = try await makeLoopbackCallbackServer(preferredPorts: [0])
        defer { server.cancel() }
        let callbackTask = Task {
            try await server.waitForCallback(timeoutNanoseconds: 30_000_000_000)
        }
        await Task.yield()

        callbackTask.cancel()

        do {
            _ = try await callbackTask.value
            XCTFail("Expected the callback wait to be canceled.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testLoopbackOAuthCallbackServerRejectsOversizedRequest() async throws {
        let server = try await makeLoopbackCallbackServer(
            preferredPorts: [0],
            maximumRequestLength: 64
        )
        defer { server.cancel() }

        let response = try await sendRawHTTPRequest(
            port: server.port,
            chunks: [Data(("GET /callback?" + String(repeating: "x", count: 128)).utf8)]
        )

        XCTAssertTrue(response.hasPrefix("HTTP/1.1 413 Payload Too Large"))
    }

    func testLoopbackOAuthCallbackServerRejectsPrematurelyClosedRequest() async throws {
        let server = try await makeLoopbackCallbackServer(preferredPorts: [0])
        defer { server.cancel() }

        let response = try await sendRawHTTPRequest(
            port: server.port,
            chunks: [Data("GET /callback?code=authorization-code".utf8)],
            finishWriting: true
        )

        XCTAssertTrue(response.hasPrefix("HTTP/1.1 400 Bad Request"))
    }

    func testCodexAuthURLUsesBrowserLoginFlow() throws {
        let url = CodexWebAuthService.authorizationURL(
            redirectURI: "http://localhost:1455/auth/callback",
            state: "state",
            codeChallenge: "challenge"
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "auth.openai.com")
        XCTAssertEqual(components.path, "/oauth/authorize")
        XCTAssertEqual(components.queryItemValue(named: "response_type"), "code")
        XCTAssertEqual(components.queryItemValue(named: "redirect_uri"), "http://localhost:1455/auth/callback")
        XCTAssertEqual(components.queryItemValue(named: "code_challenge_method"), "S256")
        XCTAssertEqual(components.queryItemValue(named: "originator"), "codex_cli_rs")
        XCTAssertEqual(components.queryItemValue(named: "codex_cli_simplified_flow"), "true")
    }

    func testInjectedRandomBytesPreserveBase64URLAndPKCEBehavior() throws {
        let bytes = Data(repeating: 0xFB, count: 64)
        let expectedVerifier = bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let digest = SHA256.hash(data: Data(expectedVerifier.utf8))
        let expectedChallenge = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let generator: OAuthRandomness.Generator = { byteCount in
            Data(repeating: 0xFB, count: byteCount)
        }

        let codex = try CodexWebAuthService.makePKCEPair(randomBytes: generator)
        let claude = try ClaudeWebAuthService.makePKCEPair(randomBytes: generator)
        let copilot = try CopilotWebAuthService.makePKCEPair(randomBytes: generator)
        let cursor = try CursorWebAuthService.makePKCEPair(randomBytes: generator)

        XCTAssertEqual(codex.codeVerifier, expectedVerifier)
        XCTAssertEqual(codex.codeChallenge, expectedChallenge)
        XCTAssertEqual(claude.codeVerifier, expectedVerifier)
        XCTAssertEqual(claude.codeChallenge, expectedChallenge)
        XCTAssertEqual(copilot.codeVerifier, expectedVerifier)
        XCTAssertEqual(copilot.codeChallenge, expectedChallenge)
        XCTAssertEqual(cursor.codeVerifier, expectedVerifier)
        XCTAssertEqual(cursor.codeChallenge, expectedChallenge)
    }

    @MainActor
    func testCodexSignInStopsBeforeBrowserWhenStateRandomnessFails() async {
        let service = CodexWebAuthService(randomBytes: { _ in
            throw RandomGeneratorTestError.failed
        })
        var didPresentBrowser = false

        do {
            _ = try await service.signIn { _ in
                didPresentBrowser = true
                return true
            }
            XCTFail("Expected ChatGPT sign-in to fail closed.")
        } catch {
            XCTAssertEqual(error as? CodexWebAuthService.AuthError, .secureRandomUnavailable)
            XCTAssertEqual(error.localizedDescription, "ChatGPT sign-in could not start securely. Try again.")
        }
        XCTAssertFalse(didPresentBrowser)
    }

    @MainActor
    func testCodexBrowserSignInUsesLocalhostRedirectAndTimesOut() async throws {
        let service = CodexWebAuthService(
            callbackTimeoutNanoseconds: 10_000_000,
            preferredCallbackPorts: [0]
        )
        var presentedURL: URL?

        do {
            _ = try await service.signIn {
                presentedURL = $0
                return true
            }
            XCTFail("Expected ChatGPT browser sign-in to time out without a callback.")
        } catch {
            XCTAssertEqual(error as? CodexWebAuthService.AuthError, .callbackTimedOut)
        }

        let authorizationComponents = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(presentedURL), resolvingAgainstBaseURL: false)
        )
        let redirectURI = try XCTUnwrap(authorizationComponents.queryItemValue(named: "redirect_uri"))
        XCTAssertEqual(URL(string: redirectURI)?.host, "localhost")
    }

    @MainActor
    func testCodexBrowserSignInStopsWhenPrivateBrowserCannotStart() async {
        let service = CodexWebAuthService(
            callbackTimeoutNanoseconds: 30_000_000_000,
            preferredCallbackPorts: [0]
        )

        do {
            _ = try await service.signIn { _ in false }
            XCTFail("Expected ChatGPT sign-in to reject a failed browser session.")
        } catch {
            XCTAssertEqual(error as? CodexWebAuthService.AuthError, .couldNotStartBrowserSession)
        }
    }

    @MainActor
    func testCodexBrowserSignInCancellationStopsCallbackWait() async throws {
        let service = CodexWebAuthService(
            callbackTimeoutNanoseconds: 30_000_000_000,
            preferredCallbackPorts: [0]
        )
        let authorizationPresented = expectation(description: "ChatGPT authorization URL presented")
        let signInTask = Task {
            try await service.signIn { _ in
                authorizationPresented.fulfill()
                return true
            }
        }
        await fulfillment(of: [authorizationPresented], timeout: 30)

        signInTask.cancel()

        do {
            _ = try await signInTask.value
            XCTFail("Expected ChatGPT browser sign-in cancellation.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCodexTokenRequestBodyUsesPKCECodeExchange() {
        let body = String(
            data: CodexWebAuthService.makeTokenRequestBody(
                code: "code value",
                redirectURI: "http://localhost:1455/auth/callback",
                codeVerifier: "verifier value"
            ),
            encoding: .utf8
        )

        XCTAssertEqual(
            body,
            "grant_type=authorization_code&code=code%20value&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&client_id=app_EMoamEEZ73f0CkXaXp7hrann&code_verifier=verifier%20value"
        )
    }

    func testCodexRefreshTokenRequestBodyUsesRefreshGrant() {
        let body = String(
            data: CodexWebAuthService.makeRefreshTokenRequestBody(refreshToken: "refresh value"),
            encoding: .utf8
        )

        XCTAssertEqual(
            body,
            "grant_type=refresh_token&refresh_token=refresh%20value&client_id=app_EMoamEEZ73f0CkXaXp7hrann"
        )
    }

    func testCodexAuthExtractsChatGPTAccountID() {
        let header = #"{"alg":"none"}"#.base64URLEncodedForTest()
        let payload = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"account-id"}}"#
            .base64URLEncodedForTest()
        let token = "\(header).\(payload).signature"

        XCTAssertEqual(CodexWebAuthService.accountID(from: token), "account-id")
    }

    func testCodexCredentialsParserReadsCliAuthJson() {
        let credentials = CodexCredentialsParser.parse("""
        {
          "tokens": {
            "access_token": "access-token",
            "account_id": "account-id"
          }
        }
        """)

        XCTAssertEqual(credentials, CodexCredentials(accessToken: "access-token", accountID: "account-id"))
    }

    func testCodexCredentialsParserReadsAccountIDFromAccessJWT() throws {
        let header = #"{"alg":"none"}"#.base64URLEncodedForTest()
        let payload = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"access-account"}}"#
            .base64URLEncodedForTest()
        let accessToken = "\(header).\(payload).signature"

        let credentials = try XCTUnwrap(CodexCredentialsParser.parse("""
        {"tokens":{"access_token":"\(accessToken)"}}
        """))

        XCTAssertEqual(credentials.accountID, "access-account")
    }

    func testCodexCredentialsParserRetainsOAuthLifecycleFieldsAndLegacyTokens() throws {
        let credentials = try XCTUnwrap(CodexCredentialsParser.parse("""
        {
          "tokens": {
            "access_token": "access-token",
            "refresh_token": "refresh-token",
            "id_token": "id-token",
            "account_id": "account-id",
            "expires_at": 2000000000000
          }
        }
        """))

        XCTAssertEqual(credentials.accessToken, "access-token")
        XCTAssertEqual(credentials.refreshToken, "refresh-token")
        XCTAssertEqual(credentials.idToken, "id-token")
        XCTAssertEqual(credentials.accountID, "account-id")
        XCTAssertEqual(credentials.expiresAt, 2_000_000_000)
        XCTAssertEqual(
            CodexCredentialsParser.parse("legacy-access-token"),
            CodexCredentials(accessToken: "legacy-access-token")
        )

        let roundTripped = try XCTUnwrap(
            CodexCredentialsParser.parse(CodexCredentialsParser.storedCredential(from: credentials))
        )
        XCTAssertEqual(roundTripped, credentials)

        let accessOnly = CodexCredentialsParser.storedCredential(from: CodexCredentials(accessToken: "access-only"))
        let accessOnlyData = try XCTUnwrap(accessOnly.data(using: .utf8))
        let accessOnlyRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: accessOnlyData) as? [String: Any]
        )
        let accessOnlyTokens = try XCTUnwrap(accessOnlyRoot["tokens"] as? [String: Any])
        XCTAssertEqual(accessOnlyTokens.count, 1)
        XCTAssertEqual(accessOnlyTokens["access_token"] as? String, "access-only")
    }

    func testCopilotAuthURLUsesGitHubBrowserCallbackFlow() throws {
        let url = CopilotWebAuthService.authorizationURL(
            clientID: "client id",
            redirectURI: "http://127.0.0.1:1456/callback",
            state: "state",
            codeChallenge: "challenge"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "github.com")
        XCTAssertEqual(components.path, "/login/oauth/authorize")
        XCTAssertEqual(components.queryItemValue(named: "response_type"), "code")
        XCTAssertEqual(components.queryItemValue(named: "client_id"), "client id")
        XCTAssertEqual(components.queryItemValue(named: "redirect_uri"), "http://127.0.0.1:1456/callback")
        XCTAssertEqual(components.queryItemValue(named: "scope"), "repo read:org gist")
        XCTAssertEqual(components.queryItemValue(named: "state"), "state")
        XCTAssertEqual(components.queryItemValue(named: "code_challenge"), "challenge")
        XCTAssertEqual(components.queryItemValue(named: "code_challenge_method"), "S256")
        XCTAssertEqual(components.queryItemValue(named: "prompt"), "select_account")
    }

    @MainActor
    func testCopilotSignInStopsBeforeBrowserWhenStateRandomnessFails() async {
        let service = CopilotWebAuthService(randomBytes: { _ in
            throw RandomGeneratorTestError.failed
        })
        let configuration = CopilotOAuthConfiguration(clientID: "client-id", clientSecret: "client-secret")
        var didPresentBrowser = false

        do {
            _ = try await service.signIn(configuration: configuration) { _ in
                didPresentBrowser = true
            }
            XCTFail("Expected GitHub sign-in to fail closed.")
        } catch {
            XCTAssertEqual(error as? CopilotWebAuthService.AuthError, .secureRandomUnavailable)
            XCTAssertEqual(error.localizedDescription, "GitHub sign-in could not start securely. Try again.")
        }
        XCTAssertFalse(didPresentBrowser)
    }

    @MainActor
    func testCopilotBrowserSignInUsesRegisteredLoopbackRedirectAndTimesOut() async throws {
        let service = CopilotWebAuthService(
            callbackTimeoutNanoseconds: 10_000_000,
            preferredCallbackPorts: [0]
        )
        let configuration = CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret")
        var presentedURL: URL?

        do {
            _ = try await service.signIn(configuration: configuration) { presentedURL = $0 }
            XCTFail("Expected GitHub browser sign-in to time out without a callback.")
        } catch {
            XCTAssertEqual(error as? CopilotWebAuthService.AuthError, .callbackTimedOut)
        }

        let authorizationComponents = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(presentedURL), resolvingAgainstBaseURL: false)
        )
        let redirectURI = try XCTUnwrap(authorizationComponents.queryItemValue(named: "redirect_uri"))
        XCTAssertEqual(URL(string: redirectURI)?.host, "127.0.0.1")
    }

    @MainActor
    func testCopilotBrowserSignInExchangesSuccessfulCallbackForTokens() async throws {
        let sessionFixture = IsolatedTestURLSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://github.com/login/oauth/access_token")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Type"),
                "application/x-www-form-urlencoded"
            )
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(
                    #"{"access_token":"access","refresh_token":"refresh","expires_in":3600,"refresh_token_expires_in":7200}"#.utf8
                )
            )
        }
        defer { sessionFixture.invalidate() }
        let service = CopilotWebAuthService(
            session: sessionFixture.session,
            callbackTimeoutNanoseconds: 30_000_000_000,
            preferredCallbackPorts: [0]
        )
        let configuration = CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret")
        let startedAt = Int64(Date().timeIntervalSince1970)
        let authorizationPresented = expectation(description: "Copilot authorization URL presented")
        var presentedURL: URL?

        let signInTask = Task {
            try await service.signIn(configuration: configuration) { authorizationURL in
                presentedURL = authorizationURL
                authorizationPresented.fulfill()
            }
        }
        defer { signInTask.cancel() }
        await fulfillment(of: [authorizationPresented], timeout: 30)
        let authorizationComponents = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(presentedURL), resolvingAgainstBaseURL: false)
        )
        let redirectURI = try XCTUnwrap(authorizationComponents.queryItemValue(named: "redirect_uri"))
        let state = try XCTUnwrap(authorizationComponents.queryItemValue(named: "state"))
        var callbackComponents = try XCTUnwrap(URLComponents(string: redirectURI))
        callbackComponents.queryItems = [
            URLQueryItem(name: "code", value: "authorization-code"),
            URLQueryItem(name: "state", value: state),
        ]
        let callbackURL = try XCTUnwrap(callbackComponents.url)
        try await LoopbackBrowser.deliver(callbackURL)
        let result = try await signInTask.value
        let completedAt = Int64(Date().timeIntervalSince1970)

        XCTAssertEqual(result.accessToken, "access")
        XCTAssertEqual(result.refreshToken, "refresh")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(result.expiresAt), startedAt + 3_600)
        XCTAssertLessThanOrEqual(try XCTUnwrap(result.expiresAt), completedAt + 3_600)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(result.refreshTokenExpiresAt), startedAt + 7_200)
        XCTAssertLessThanOrEqual(try XCTUnwrap(result.refreshTokenExpiresAt), completedAt + 7_200)
    }

    func testCopilotTokenRequestBodyUsesAuthorizationCodeExchange() {
        let body = String(
            data: CopilotWebAuthService.makeTokenRequestBody(
                clientID: "client",
                clientSecret: "secret",
                code: "code value",
                redirectURI: "http://127.0.0.1:1456/callback",
                codeVerifier: "verifier value"
            ),
            encoding: .utf8
        )

        XCTAssertEqual(
            body,
            "client_id=client&client_secret=secret&code=code%20value&redirect_uri=http%3A%2F%2F127.0.0.1%3A1456%2Fcallback&code_verifier=verifier%20value"
        )
    }

    func testCopilotRefreshTokenRequestBodyUsesRefreshGrant() {
        let body = String(
            data: CopilotWebAuthService.makeRefreshTokenRequestBody(
                clientID: "client",
                clientSecret: "secret",
                refreshToken: "refresh value"
            ),
            encoding: .utf8
        )

        XCTAssertEqual(
            body,
            "client_id=client&client_secret=secret&grant_type=refresh_token&refresh_token=refresh%20value"
        )
    }

    @MainActor
    func testCopilotBrowserSignInSanitizesSuccessfulTokenErrorResponse() async throws {
        let sessionFixture = IsolatedTestURLSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://github.com/login/oauth/access_token")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(
                    #"{"error":"invalid_grant","error_description":"code=secret-code client_id=secret-client"}"#.utf8
                )
            )
        }
        defer { sessionFixture.invalidate() }
        let service = CopilotWebAuthService(
            session: sessionFixture.session,
            callbackTimeoutNanoseconds: 30_000_000_000,
            preferredCallbackPorts: [0]
        )
        let configuration = CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret")

        do {
            _ = try await service.signIn(configuration: configuration) { authorizationURL in
                guard
                    let authorizationComponents = URLComponents(
                        url: authorizationURL,
                        resolvingAgainstBaseURL: false
                    ),
                    let redirectURI = authorizationComponents.queryItemValue(named: "redirect_uri"),
                    let state = authorizationComponents.queryItemValue(named: "state"),
                    var callbackComponents = URLComponents(string: redirectURI)
                else {
                    XCTFail("Expected a valid GitHub authorization callback URL.")
                    return
                }
                callbackComponents.queryItems = [
                    URLQueryItem(name: "code", value: "authorization-code"),
                    URLQueryItem(name: "state", value: state),
                ]
                guard let callbackURL = callbackComponents.url else {
                    XCTFail("Expected a valid GitHub callback URL.")
                    return
                }
                Task.detached {
                    try? await LoopbackBrowser.deliver(callbackURL)
                }
            }
            XCTFail("Expected GitHub sign-in to fail.")
        } catch {
            XCTAssertEqual(
                error as? CopilotWebAuthService.AuthError,
                .tokenExchangeFailed("invalid_grant")
            )
            XCTAssertFalse(error.localizedDescription.contains("secret-code"))
            XCTAssertFalse(error.localizedDescription.contains("secret-client"))
        }
    }

    func testClaudeAuthURLUsesBrowserCallbackFlow() throws {
        let url = ClaudeWebAuthService.authorizationURL(
            redirectURI: "http://localhost:1461/callback",
            state: "state",
            codeChallenge: "challenge"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "claude.com")
        XCTAssertEqual(components.path, "/cai/oauth/authorize")
        XCTAssertEqual(components.queryItemValue(named: "code"), "true")
        XCTAssertEqual(components.queryItemValue(named: "client_id"), "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        XCTAssertEqual(components.queryItemValue(named: "response_type"), "code")
        XCTAssertEqual(components.queryItemValue(named: "redirect_uri"), "http://localhost:1461/callback")
        XCTAssertEqual(components.queryItemValue(named: "scope"), "org:create_api_key user:profile user:inference user:sessions:claude_code")
        XCTAssertEqual(components.queryItemValue(named: "code_challenge"), "challenge")
        XCTAssertEqual(components.queryItemValue(named: "code_challenge_method"), "S256")
        XCTAssertEqual(components.queryItemValue(named: "state"), "state")
    }

    @MainActor
    func testClaudeSignInStopsBeforeBrowserWhenPKCERandomnessFails() async {
        let service = ClaudeWebAuthService(randomBytes: { byteCount in
            guard byteCount == 32 else {
                throw RandomGeneratorTestError.failed
            }
            return Data(repeating: 0xAB, count: byteCount)
        })
        var didPresentBrowser = false

        do {
            _ = try await service.signIn { _ in
                didPresentBrowser = true
            }
            XCTFail("Expected Claude sign-in to fail closed.")
        } catch {
            XCTAssertEqual(error as? ClaudeWebAuthService.AuthError, .secureRandomUnavailable)
            XCTAssertEqual(error.localizedDescription, "Claude sign-in could not start securely. Try again.")
        }
        XCTAssertFalse(didPresentBrowser)
    }

    @MainActor
    func testClaudeBrowserSignInUsesLocalhostRedirectAndTimesOut() async throws {
        let service = ClaudeWebAuthService(
            callbackTimeoutNanoseconds: 10_000_000,
            preferredCallbackPorts: [0]
        )
        var presentedURL: URL?

        do {
            _ = try await service.signIn { presentedURL = $0 }
            XCTFail("Expected Claude browser sign-in to time out without a callback.")
        } catch {
            XCTAssertEqual(error as? ClaudeWebAuthService.AuthError, .callbackTimedOut)
        }

        let authorizationComponents = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(presentedURL), resolvingAgainstBaseURL: false)
        )
        let redirectURI = try XCTUnwrap(authorizationComponents.queryItemValue(named: "redirect_uri"))
        XCTAssertEqual(URL(string: redirectURI)?.host, "localhost")
    }

    @MainActor
    func testClaudeBrowserSignInCancellationThrowsCancellationError() async throws {
        let service = ClaudeWebAuthService(
            callbackTimeoutNanoseconds: 30_000_000_000,
            preferredCallbackPorts: [0]
        )
        var presentedURL: URL?
        var signInTask: Task<ClaudeWebAuthResult, Error>?
        signInTask = Task {
            try await service.signIn {
                presentedURL = $0
                // Queue cancellation after sign-in yields to its callback wait.
                Task { @MainActor in
                    signInTask?.cancel()
                }
            }
        }

        do {
            _ = try await XCTUnwrap(signInTask).value
            XCTFail("Expected Claude browser sign-in cancellation.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(presentedURL), resolvingAgainstBaseURL: false))
        let redirectURI = try XCTUnwrap(components.queryItemValue(named: "redirect_uri"))
        XCTAssertEqual(URL(string: redirectURI)?.host, "localhost")
    }

    func testClaudeTokenRequestBodyUsesAuthorizationCodeExchange() throws {
        let data = ClaudeWebAuthService.makeTokenRequestBody(
            code: "code value",
            redirectURI: "http://localhost:1461/callback",
            state: "state value",
            codeVerifier: "verifier value"
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])

        XCTAssertEqual(body["grant_type"], "authorization_code")
        XCTAssertEqual(body["code"], "code value")
        XCTAssertEqual(body["redirect_uri"], "http://localhost:1461/callback")
        XCTAssertEqual(body["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        XCTAssertEqual(body["code_verifier"], "verifier value")
        XCTAssertEqual(body["state"], "state value")
    }

    func testTokenEndpointErrorFormatterOnlySurfacesSafeOAuthErrorCode() {
        let body = Data(#"{"error":"invalid_grant","error_description":"authorization code=secret-code client_id=secret-client"}"#.utf8)

        let message = TokenEndpointErrorFormatter.message(statusCode: 400, body: body)

        XCTAssertEqual(message, "HTTP 400 (invalid_grant)")
        XCTAssertFalse(message.contains("secret-code"))
        XCTAssertFalse(message.contains("secret-client"))
    }

    func testTokenEndpointErrorFormatterDropsUntrustedResponseContent() {
        let rawBody = Data("<html>authorization: Bearer secret-token</html>".utf8)
        let unsafeJSON = Data(#"{"error":"invalid grant code=secret-code"}"#.utf8)
        let nonASCIIJSON = Data(#"{"error":"invalid_grant_🔑"}"#.utf8)

        XCTAssertEqual(
            TokenEndpointErrorFormatter.message(statusCode: 502, body: rawBody),
            "HTTP 502"
        )
        XCTAssertEqual(
            TokenEndpointErrorFormatter.message(statusCode: 400, body: unsafeJSON),
            "HTTP 400"
        )
        XCTAssertEqual(
            TokenEndpointErrorFormatter.message(statusCode: 400, body: nonASCIIJSON),
            "HTTP 400"
        )
        XCTAssertEqual(
            TokenEndpointErrorFormatter.message(errorCode: String(repeating: "x", count: 65)),
            "Token endpoint rejected the request."
        )
    }

    @MainActor
    func testClaudeBrowserSignInSanitizesTokenExchangeFailure() async throws {
        let sessionFixture = IsolatedTestURLSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://platform.claude.com/v1/oauth/token")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 400,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"error":"invalid_grant","error_description":"code=secret-code client_id=secret-client"}"#.utf8)
            )
        }
        defer { sessionFixture.invalidate() }
        let service = ClaudeWebAuthService(
            session: sessionFixture.session,
            callbackTimeoutNanoseconds: 30_000_000_000,
            preferredCallbackPorts: [0]
        )

        do {
            _ = try await service.signIn { authorizationURL in
                guard
                    let authorizationComponents = URLComponents(
                        url: authorizationURL,
                        resolvingAgainstBaseURL: false
                    ),
                    let redirectURI = authorizationComponents.queryItemValue(named: "redirect_uri"),
                    let state = authorizationComponents.queryItemValue(named: "state"),
                    var callbackComponents = URLComponents(string: redirectURI)
                else {
                    XCTFail("Expected a valid Claude authorization callback URL.")
                    return
                }
                callbackComponents.queryItems = [
                    URLQueryItem(name: "code", value: "authorization-code"),
                    URLQueryItem(name: "state", value: state),
                ]
                guard let callbackURL = callbackComponents.url else {
                    XCTFail("Expected a valid Claude callback URL.")
                    return
                }
                Task.detached {
                    try? await LoopbackBrowser.deliver(callbackURL)
                }
            }
            XCTFail("Expected Claude sign-in to fail.")
        } catch {
            XCTAssertEqual(
                error as? ClaudeWebAuthService.AuthError,
                .tokenExchangeFailed("HTTP 400 (invalid_grant)")
            )
            XCTAssertFalse(error.localizedDescription.contains("secret-code"))
            XCTAssertFalse(error.localizedDescription.contains("secret-client"))
        }
    }

    func testClaudeCredentialsParserReadsClaudeCodeOAuthShape() {
        let credentials = ClaudeCredentialsParser.parse("""
        {
          "claudeAiOauth": {
            "subscriptionType": "pro",
            "rateLimitTier": "standard",
            "expiresAt": 1893456000000,
            "accessToken": "access-token",
            "refreshToken": "refresh-token"
          }
        }
        """)

        XCTAssertEqual(
            credentials,
            ClaudeCredentials(
                subscriptionType: "pro",
                rateLimitTier: "standard",
                expiresAt: 1_893_456_000_000,
                accessToken: "access-token",
                refreshToken: "refresh-token"
            )
        )
    }

    func testCursorAuthURLUsesBrowserPollingFlow() throws {
        let url = CursorWebAuthService.authorizationURL(
            uuid: "request-id",
            codeChallenge: "challenge"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "cursor.com")
        XCTAssertEqual(components.path, "/loginDeepControl")
        XCTAssertEqual(components.queryItemValue(named: "challenge"), "challenge")
        XCTAssertEqual(components.queryItemValue(named: "uuid"), "request-id")
        XCTAssertEqual(components.queryItemValue(named: "mode"), "login")
        XCTAssertEqual(components.queryItemValue(named: "redirectTarget"), "cli")
    }

    func testCursorPollRequestUsesPKCEVerifier() throws {
        let request = CursorWebAuthService.pollRequest(uuid: "request-id", codeVerifier: "verifier")
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "api2.cursor.sh")
        XCTAssertEqual(components.path, "/auth/poll")
        XCTAssertEqual(components.queryItemValue(named: "uuid"), "request-id")
        XCTAssertEqual(components.queryItemValue(named: "verifier"), "verifier")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    @MainActor
    func testCursorSignInStopsBeforeBrowserAndPollingWhenPKCERandomnessFails() async {
        let sessionFixture = IsolatedTestURLSession { _ in
            XCTFail("Token polling must not start without a secure PKCE verifier.")
            throw URLError(.badServerResponse)
        }
        defer { sessionFixture.invalidate() }
        let service = CursorWebAuthService(
            session: sessionFixture.session,
            pollIntervalNanoseconds: 1,
            maxPollAttempts: 1,
            randomBytes: { _ in throw RandomGeneratorTestError.failed }
        )
        var didPresentBrowser = false

        do {
            _ = try await service.signIn { _ in
                didPresentBrowser = true
                return true
            }
            XCTFail("Expected Cursor sign-in to fail closed.")
        } catch {
            XCTAssertEqual(error as? CursorWebAuthService.AuthError, .secureRandomUnavailable)
            XCTAssertEqual(error.localizedDescription, "Cursor sign-in could not start securely. Try again.")
        }
        XCTAssertFalse(didPresentBrowser)
    }

    @MainActor
    func testCursorBrowserSignInPollsAndStoresSessionShape() async throws {
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ConfigurationAndAuthMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = CursorWebAuthService(
            session: session,
            pollIntervalNanoseconds: 1,
            maxPollAttempts: 1
        )

        ConfigurationAndAuthMockURLProtocol.handler = { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.host, "api2.cursor.sh")
            XCTAssertEqual(components.path, "/auth/poll")
            XCTAssertNotNil(components.queryItemValue(named: "uuid"))
            XCTAssertNotNil(components.queryItemValue(named: "verifier"))
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"accessToken":"cursor-access","refreshToken":"cursor-refresh","authId":"auth0|user-id"}"#.utf8)
            )
        }
        defer {
            ConfigurationAndAuthMockURLProtocol.handler = nil
        }

        var presentedURL: URL?
        let result = try await service.signIn { url in
            presentedURL = url
            return true
        }
        let authURL = try XCTUnwrap(presentedURL)
        let authComponents = try XCTUnwrap(URLComponents(url: authURL, resolvingAgainstBaseURL: false))

        XCTAssertEqual(authComponents.host, "cursor.com")
        XCTAssertEqual(result.accessToken, "cursor-access")
        XCTAssertEqual(result.refreshToken, "cursor-refresh")
        XCTAssertTrue(result.storedCredential.contains(#""accessToken": "cursor-access""#))
    }

    @MainActor
    func testCursorBrowserSignInSanitizesTokenPollFailure() async throws {
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ConfigurationAndAuthMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = CursorWebAuthService(
            session: session,
            pollIntervalNanoseconds: 1,
            maxPollAttempts: 1
        )

        ConfigurationAndAuthMockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 400,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"error":"invalid_grant","error_description":"code=secret-code"}"#.utf8)
            )
        }
        defer {
            ConfigurationAndAuthMockURLProtocol.handler = nil
        }

        do {
            _ = try await service.signIn { _ in true }
            XCTFail("Expected Cursor sign-in to fail.")
        } catch {
            XCTAssertEqual(error as? CursorWebAuthService.AuthError, .tokenPollFailed("HTTP 400 (invalid_grant)"))
            XCTAssertFalse(error.localizedDescription.contains("secret-code"))
        }
    }

#if canImport(AuthenticationServices) && canImport(UIKit)
    @MainActor
    func testCursorBrowserSessionUsesEphemeralStorage() {
        let session = PrivateWebAuthenticationPresenter.makeSession(
            url: URL(string: "https://cursor.com/loginDeepControl")!
        ) { _ in }

        XCTAssertTrue(session.prefersEphemeralWebBrowserSession)
    }
#endif

    func testCursorBrowserSessionIgnoresStaleCompletionAfterRetry() {
        var generation = WebAuthenticationSessionGeneration()
        let firstSessionID = generation.start()
        let retrySessionID = generation.start()

        XCTAssertFalse(generation.complete(firstSessionID))
        XCTAssertTrue(generation.complete(retrySessionID))
        XCTAssertFalse(generation.complete(retrySessionID))
    }

    @MainActor
    func testCursorSignInStopsWhenPrivateBrowserCannotStart() async {
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ConfigurationAndAuthMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = CursorWebAuthService(
            session: session,
            pollIntervalNanoseconds: 1,
            maxPollAttempts: 1
        )
        ConfigurationAndAuthMockURLProtocol.handler = { _ in
            XCTFail("Token polling should not start when the browser session cannot start.")
            throw URLError(.badServerResponse)
        }
        defer {
            ConfigurationAndAuthMockURLProtocol.handler = nil
        }

        do {
            _ = try await service.signIn { _ in false }
            XCTFail("Expected Cursor sign-in to reject a failed browser session.")
        } catch {
            XCTAssertEqual(error as? CursorWebAuthService.AuthError, .couldNotStartBrowserSession)
        }
    }

    func testCopilotCredentialsParserReadsStoredJSONAndRawToken() {
        XCTAssertEqual(
            CopilotCredentialsParser.parse(#"{"accessToken":"token","username":"octocat"}"#),
            CopilotCredentials(accessToken: "token", username: "octocat")
        )
        XCTAssertEqual(
            CopilotCredentialsParser.parse("gho_raw_token"),
            CopilotCredentials(accessToken: "gho_raw_token")
        )
    }

    func testCopilotCredentialsParserRetainsRefreshAndExpiryFields() throws {
        let credentials = CopilotCredentials(
            accessToken: "access-token",
            username: "octocat",
            refreshToken: "refresh-token",
            expiresAt: 2_000_000_000,
            refreshTokenExpiresAt: 2_100_000_000
        )

        let stored = CopilotCredentialsParser.storedCredential(from: credentials)
        XCTAssertEqual(try XCTUnwrap(CopilotCredentialsParser.parse(stored)), credentials)
        XCTAssertEqual(
            CopilotCredentialsParser.parse("legacy-token"),
            CopilotCredentials(accessToken: "legacy-token")
        )
    }

    func testCopilotUsageRequestMatchesWindowsCopilotHeaders() {
        let provider = CopilotUsageProvider(
            secretStore: EmptySecretStore(),
            usageEndpoint: URL(string: "https://api.github.com/copilot_internal/user")!
        )

        let request = provider.makeUsageRequest(accessToken: "github-token")

        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/copilot_internal/user")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token github-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "GitHubCopilotChat/0.26.7")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Editor-Version"), "vscode/1.96.2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Editor-Plugin-Version"), "copilot-chat/0.26.7")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Github-Api-Version"), "2025-04-01")
    }

    func testCopilotOrganizationBillingRequestSupportsStandaloneOrganization() throws {
        let provider = CopilotUsageProvider(
            secretStore: EmptySecretStore(),
            githubAPIBaseURL: URL(string: "https://api.github.com")!
        )
        let date = Date(timeIntervalSince1970: 1_782_882_000)
        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            authMethod: .browserSession,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering"
        )

        let request = try XCTUnwrap(provider.makeOrganizationBillingRequest(
            accessToken: "github-token",
            configuration: configuration,
            date: date
        ))
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.path, "/organizations/Relias-Engineering/settings/billing/ai_credit/usage")
        XCTAssertEqual(components.queryItemValue(named: "year"), "2026")
        XCTAssertEqual(components.queryItemValue(named: "month"), "7")
        XCTAssertEqual(components.queryItemValue(named: "product"), "Copilot")
        XCTAssertNil(components.queryItemValue(named: "organization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer github-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
    }

    func testCopilotOrganizationBillingRequestSupportsEnterpriseOrganization() throws {
        let provider = CopilotUsageProvider(
            secretStore: EmptySecretStore(),
            githubAPIBaseURL: URL(string: "https://api.github.com")!
        )
        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            authMethod: .browserSession,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering",
            githubEnterprise: "bertelsmann"
        )

        let request = try XCTUnwrap(provider.makeOrganizationBillingRequest(
            accessToken: "github-token",
            configuration: configuration,
            date: Date(timeIntervalSince1970: 1_782_882_000)
        ))
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.path, "/enterprises/bertelsmann/settings/billing/ai_credit/usage")
        XCTAssertEqual(components.queryItemValue(named: "organization"), "Relias-Engineering")
    }

    func testCopilotOrganizationSeatCountRequestUsesOrgBillingEndpoint() throws {
        let provider = CopilotUsageProvider(
            secretStore: EmptySecretStore(),
            githubAPIBaseURL: URL(string: "https://api.github.com")!
        )
        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            authMethod: .browserSession,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering"
        )

        let request = try XCTUnwrap(provider.makeOrganizationSeatCountRequest(
            accessToken: "github-token",
            configuration: configuration
        ))

        XCTAssertEqual(request.url?.path, "/orgs/Relias-Engineering/copilot/billing")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer github-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
    }

    func testCopilotOrganizationCreditsPerSeatMatchesWindowsPromotionalWindow() {
        XCTAssertEqual(CopilotUsageProvider.creditsPerSeat(year: 2026, month: 6), 7_000)
        XCTAssertEqual(CopilotUsageProvider.creditsPerSeat(year: 2026, month: 7), 7_000)
        XCTAssertEqual(CopilotUsageProvider.creditsPerSeat(year: 2026, month: 8), 7_000)
        XCTAssertEqual(CopilotUsageProvider.creditsPerSeat(year: 2026, month: 9), 3_900)
    }

    func testCopilotUsageParserReadsQuotaSnapshots() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let payload = """
        {
          "login": "octocat",
          "copilot_plan": "individual_pro",
          "quota_reset_date_utc": "2030-01-03T00:00:00Z",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 2000,
              "remaining": 500,
              "unlimited": false
            },
            "chat": {
              "entitlement": 100,
              "remaining": 12,
              "unlimited": false
            }
          }
        }
        """

        let result = try XCTUnwrap(CopilotUsageParser.parse(Data(payload.utf8), fetchedAt: fetchedAt))

        XCTAssertEqual(result.providerID, .copilot)
        XCTAssertEqual(result.title, "GitHub Copilot (octocat)")
        XCTAssertEqual(
            result.plan,
            ProviderPlanDescriptor(
                identifier: "copilot.pro",
                displayLabel: "PRO",
                accessibilityLabel: "Pro"
            )
        )
        XCTAssertEqual(result.bars.map(\.label), ["Premium interactions (1,500 / 2,000)", "Chat (88 / 100)"])
        XCTAssertEqual(result.bars.map(\.usageText), ["75%", "88%"])
        XCTAssertEqual(
            result.bars.map(\.resetDisplayStyle),
            [.relativeWithLocalTime, .relativeWithLocalTime]
        )
        XCTAssertEqual(result.subtitle, "Resets in 3d")
        XCTAssertEqual(result.bars.first?.projectionCurrent, 1500)
        XCTAssertEqual(result.bars.first?.projectionLimit, 2000)
        XCTAssertEqual(result.bars.first?.projectionPeriodStart, Date(timeIntervalSince1970: 1_890_950_400))
        XCTAssertEqual(result.bars.first?.projectionPeriodEnd, Date(timeIntervalSince1970: 1_893_628_800))
        XCTAssertEqual(result.bars.first?.showProjectionOnCurrentBar, true)
    }

    func testCopilotUsageParserResetCountdownRecomputesAfterSnapshotTime() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let payload = """
        {
          "quota_reset_date_utc": "2030-01-03T00:00:00Z",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 2000,
              "remaining": 500,
              "unlimited": false
            }
          }
        }
        """
        let bar = try XCTUnwrap(
            CopilotUsageParser.parse(Data(payload.utf8), fetchedAt: fetchedAt)?.bars.first
        )
        let initial = try XCTUnwrap(bar.localizedResetDescription(at: fetchedAt))
        let later = try XCTUnwrap(
            bar.localizedResetDescription(at: fetchedAt.addingTimeInterval(24 * 60 * 60))
        )

        XCTAssertEqual(bar.resetDisplayStyle, .relativeWithLocalTime)
        XCTAssertNotEqual(initial, later)
    }

    func testCopilotUsageParserNormalizesOnlyObservedPlanValues() throws {
        let mappings: [(rawValue: String, identifier: String?, label: String?)] = [
            ("individual_pro", "copilot.pro", "PRO"),
            ("business", "copilot.business", "BUSINESS"),
            ("enterprise", "copilot.enterprise", "ENTERPRISE"),
            ("free", nil, nil),
            ("student", nil, nil),
            ("individual_pro_plus", nil, nil),
            ("max", nil, nil),
            ("unknown_value", nil, nil),
            ("", nil, nil),
        ]

        for mapping in mappings {
            let payload = """
            {
              "login": "octocat",
              "copilot_plan": "\(mapping.rawValue)",
              "quota_snapshots": {}
            }
            """
            let result = try XCTUnwrap(CopilotUsageParser.parse(Data(payload.utf8)))
            XCTAssertEqual(result.plan?.identifier, mapping.identifier, mapping.rawValue)
            XCTAssertEqual(result.plan?.displayLabel, mapping.label, mapping.rawValue)
        }
    }

    func testCopilotAccountMetadataPreservesAllUsageDetails() {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let monetaryMetric = ProviderMonetaryMetric(
            kind: .balance,
            label: "Available balance",
            minorUnits: 1_250,
            currencyCode: "USD",
            decimalPlaces: 2,
            detail: "Provider-reported balance"
        )
        let parsedResult = ProviderUsageResult(
            accountID: "parsed-account",
            providerID: .copilot,
            title: "Parsed Copilot account",
            plan: ProviderPlanDescriptor(
                identifier: "copilot.business",
                displayLabel: "BUSINESS",
                accessibilityLabel: "Business"
            ),
            subtitle: "Live GitHub Copilot usage",
            bars: [],
            creditsRemaining: 42.5,
            monetaryMetrics: [monetaryMetric],
            usageMessages: ["Provider-reported message"],
            fetchedAt: fetchedAt
        )
        let configuration = ProviderAccountConfiguration(
            id: "copilot.work",
            providerID: .copilot,
            accountLabel: "Work Copilot",
            authMethod: .browserSession
        )
        let provider = CopilotUsageProvider(secretStore: EmptySecretStore())

        let result = provider.applyAccountMetadata(to: parsedResult, configuration: configuration)

        XCTAssertEqual(result.accountID, "copilot.work")
        XCTAssertEqual(result.title, "Work Copilot")
        XCTAssertEqual(result.plan, parsedResult.plan)
        XCTAssertEqual(result.creditsRemaining, parsedResult.creditsRemaining)
        XCTAssertEqual(result.monetaryMetrics, parsedResult.monetaryMetrics)
        XCTAssertEqual(result.usageMessages, parsedResult.usageMessages)
        XCTAssertEqual(result.fetchedAt, fetchedAt)
    }

    func testCopilotUsageParserOmitsUnlimitedChatQuota() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let payload = """
        {
          "login": "fphemmer",
          "copilot_plan": "business",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 2000,
              "remaining": 500,
              "unlimited": false
            },
            "chat": {
              "entitlement": 0,
              "remaining": 0,
              "unlimited": true
            }
          }
        }
        """

        let result = try XCTUnwrap(CopilotUsageParser.parse(Data(payload.utf8), fetchedAt: fetchedAt))

        XCTAssertEqual(result.bars.map(\.label), ["Premium interactions (1,500 / 2,000)"])
    }

    func testCopilotUsageParserPreservesUnlimitedPremiumValue() throws {
        let payload = """
        {
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 0,
              "remaining": 0,
              "unlimited": true
            }
          }
        }
        """

        let bar = try XCTUnwrap(CopilotUsageParser.parse(Data(payload.utf8))?.bars.first)

        XCTAssertEqual(bar.label, "Premium interactions - unlimited")
        XCTAssertEqual(bar.fractionlessUsageText, "Unlimited")
    }

    func testCopilotUsageParserInfersMonthlyProjectionWhenResetIsMissing() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let payload = """
        {
          "login": "octocat",
          "copilot_plan": "individual_pro",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 2000,
              "remaining": 500,
              "unlimited": false
            }
          }
        }
        """

        let result = try XCTUnwrap(CopilotUsageParser.parse(Data(payload.utf8), fetchedAt: fetchedAt))

        XCTAssertEqual(result.subtitle, "Live GitHub Copilot usage")
        XCTAssertEqual(result.bars.first?.resetDescription, "Resets in 21d 16h")
        XCTAssertEqual(result.bars.first?.projectionPeriodStart, Date(timeIntervalSince1970: 1_782_864_000))
        XCTAssertEqual(result.bars.first?.projectionPeriodEnd, Date(timeIntervalSince1970: 1_785_542_400))
        XCTAssertEqual(result.bars.first?.showProjectionOnCurrentBar, true)
    }

    func testCopilotBillingUsageParserReadsOrganizationUsage() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let payload = """
        {
          "timePeriod": { "year": 2026, "month": 7 },
          "organization": "Relias-Engineering",
          "usageItems": [
            { "product": "Copilot", "sku": "Copilot AI Credits", "grossQuantity": 1200 },
            { "product": "Actions", "sku": "Actions Linux", "grossQuantity": 99 },
            { "sku": "Copilot AI Credits", "grossQuantity": 300 }
          ]
        }
        """
        let configuration = ProviderAccountConfiguration(
            id: "copilot.org",
            providerID: .copilot,
            accountLabel: "Relias Engineering",
            authMethod: .browserSession,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering",
            copilotTotalAllotment: 350000
        )

        let result = try XCTUnwrap(CopilotBillingUsageParser.parse(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.accountID, "copilot.org")
        XCTAssertEqual(result.title, "Relias Engineering")
        XCTAssertEqual(result.subtitle, "Live GitHub Copilot usage for Relias-Engineering")
        XCTAssertEqual(result.bars.map(\.label), [
            "Current AI credits (1,500 / 350,000)",
        ])
        XCTAssertEqual(result.bars.map(\.usageText), ["0%"])
        XCTAssertEqual(result.bars.first?.resetDisplayStyle, .relativeWithLocalTime)
        XCTAssertEqual(result.bars.first?.projectionCurrent, 1500)
        XCTAssertEqual(result.bars.first?.projectionLimit, 350000)
        XCTAssertEqual(result.bars.first?.projectionPeriodStart, Date(timeIntervalSince1970: 1_782_864_000))
        XCTAssertEqual(result.bars.first?.projectionPeriodEnd, Date(timeIntervalSince1970: 1_785_542_400))
        XCTAssertEqual(result.bars.first?.showProjectionOnCurrentBar, true)
    }

    func testCopilotBillingUsageParserProjectsOrganizationUsageWithoutAllotment() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let payload = """
        {
          "timePeriod": { "year": 2026, "month": 7 },
          "usageItems": [
            { "product": "Copilot", "sku": "Copilot AI Credits", "grossQuantity": 1500 }
          ]
        }
        """
        let configuration = ProviderAccountConfiguration(
            id: "copilot.org",
            providerID: .copilot,
            accountLabel: "Relias Engineering",
            authMethod: .browserSession,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering"
        )

        let result = try XCTUnwrap(CopilotBillingUsageParser.parse(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.bars.map(\.label), ["AI credits used (1,500)"])
        XCTAssertEqual(result.bars.first?.fractionlessUsageText, "1,500")
        XCTAssertEqual(
            result.bars.first?.projectionDescription(at: fetchedAt),
            "Projected month end at current pace - 5,000 AI credits"
        )
    }

    func testCopilotBillingUsageParserUsesResolvedOrganizationPoolAllotment() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let payload = """
        {
          "timePeriod": { "year": 2026, "month": 7 },
          "usageItems": [
            { "product": "Copilot", "sku": "Copilot AI Credits", "grossQuantity": 1500 }
          ]
        }
        """
        let configuration = ProviderAccountConfiguration(
            id: "copilot.org",
            providerID: .copilot,
            accountLabel: "Relias Engineering",
            authMethod: .browserSession,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering"
        )

        let result = try XCTUnwrap(CopilotBillingUsageParser.parse(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt,
            totalAllotment: 50 * 7_000
        ))

        XCTAssertEqual(result.bars.map(\.label), ["Current AI credits (1,500 / 350,000)"])
        XCTAssertEqual(result.bars.first?.usageText, "0%")
        XCTAssertEqual(result.bars.first?.projectionCurrent, 1500)
        XCTAssertEqual(result.bars.first?.projectionLimit, 350000)
        XCTAssertEqual(result.bars.first?.showProjectionOnCurrentBar, true)
    }

    func testCopilotOrganizationAllotmentResolvesFromSeatCount() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConfigurationAndAuthMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let provider = CopilotUsageProvider(
            secretStore: EmptySecretStore(),
            session: session,
            githubAPIBaseURL: URL(string: "https://api.github.com")!
        )
        let accountConfiguration = ProviderAccountConfiguration(
            providerID: .copilot,
            authMethod: .browserSession,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering"
        )
        ConfigurationAndAuthMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/orgs/Relias-Engineering/copilot/billing")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"seat_breakdown":{"total":50}}"#.utf8)
            )
        }
        defer {
            ConfigurationAndAuthMockURLProtocol.handler = nil
        }

        let total = try await provider.resolveOrganizationAllotment(
            configuration: accountConfiguration,
            accessToken: "github-token",
            date: Date(timeIntervalSince1970: 1_783_667_520)
        )

        XCTAssertEqual(total, 350000)
    }

    private func makeLoopbackCallbackServer(
        preferredPorts: [UInt16],
        maximumRequestLength: Int = 8_192
    ) async throws -> LoopbackOAuthCallbackServer<ClaudeWebAuthService.AuthError> {
        try await LoopbackOAuthCallbackServer<ClaudeWebAuthService.AuthError>.start(
            preferredPorts: preferredPorts,
            expectedState: "expected-state",
            callbackPath: "/callback",
            bindHost: .ipv4,
            queueLabel: "com.hemsoft.CodexBarIOSTests.loopbackOAuth.\(UUID().uuidString)",
            couldNotStartError: .couldNotStartCallbackServer,
            missingCodeError: .missingAuthorizationCode,
            stateMismatchError: .stateMismatch,
            timeoutError: .callbackTimedOut,
            successHeading: "Sign-in complete",
            failureHeading: "Sign-in failed",
            maximumRequestLength: maximumRequestLength
        )
    }

    private func sendRawHTTPRequest(
        port: UInt16,
        chunks: [Data],
        finishWriting: Bool = false
    ) async throws -> String {
        try await Task.detached {
            let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard socketDescriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { Darwin.close(socketDescriptor) }

            var receiveTimeout = timeval(tv_sec: 2, tv_usec: 0)
            guard setsockopt(
                socketDescriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                &receiveTimeout,
                socklen_t(MemoryLayout<timeval>.size)
            ) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let connectionResult = withUnsafePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.connect(
                        socketDescriptor,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
            guard connectionResult == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            for (index, chunk) in chunks.enumerated() {
                try chunk.withUnsafeBytes { bytes in
                    var sentByteCount = 0
                    while sentByteCount < bytes.count {
                        let result = Darwin.send(
                            socketDescriptor,
                            bytes.baseAddress?.advanced(by: sentByteCount),
                            bytes.count - sentByteCount,
                            0
                        )
                        guard result > 0 else {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        sentByteCount += result
                    }
                }
                if index < chunks.count - 1 {
                    usleep(50_000)
                }
            }

            if finishWriting {
                guard Darwin.shutdown(socketDescriptor, SHUT_WR) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }

            var response = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let receivedByteCount = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.recv(socketDescriptor, bytes.baseAddress, bytes.count, 0)
                }
                if receivedByteCount > 0 {
                    response.append(contentsOf: buffer.prefix(receivedByteCount))
                } else if receivedByteCount == 0 {
                    break
                } else if errno == ECONNRESET, !response.isEmpty {
                    break
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            // The loopback test server deliberately preserves replacement
            // characters so malformed requests can still be diagnosed.
            // swiftlint:disable:next optional_data_string_conversion
            return String(decoding: response, as: UTF8.self)
        }.value
    }

    @MainActor
    func testDashboardCardCollapseStateDefaultsExpandedAndPersistsPerAccount() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        let collapsedAccount = try XCTUnwrap(store.addAccount(for: .codex))
        let expandedAccount = try XCTUnwrap(store.addAccount(for: .claude))

        XCTAssertFalse(store.isDashboardCardCollapsed(accountID: collapsedAccount.id))
        XCTAssertFalse(store.isDashboardCardCollapsed(accountID: expandedAccount.id))

        store.updateDashboardCardCollapsed(true, accountID: collapsedAccount.id)

        let reloadedStore = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: EmptySecretStore()
        )
        XCTAssertTrue(reloadedStore.isDashboardCardCollapsed(accountID: collapsedAccount.id))
        XCTAssertFalse(reloadedStore.isDashboardCardCollapsed(accountID: expandedAccount.id))

        reloadedStore.updateDashboardCardCollapsed(false, accountID: collapsedAccount.id)
        XCTAssertFalse(reloadedStore.isDashboardCardCollapsed(accountID: collapsedAccount.id))
    }

    @MainActor
    func testRemovingAndResettingAccountsCleanUpDashboardCardCollapseState() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        let removedAccount = try XCTUnwrap(store.addAccount(for: .codex))
        store.updateDashboardCardCollapsed(true, accountID: removedAccount.id)

        XCTAssertTrue(store.removeAccount(removedAccount))
        XCTAssertFalse(store.isDashboardCardCollapsed(accountID: removedAccount.id))

        let resetAccount = try XCTUnwrap(store.addAccount(for: .claude))
        store.updateDashboardCardCollapsed(true, accountID: resetAccount.id)
        XCTAssertTrue(store.resetAccounts())
        XCTAssertTrue(store.collapsedDashboardAccountIDs.isEmpty)
        XCTAssertNil(defaults.stringArray(forKey: "collapsedDashboardAccountIDs"))
    }

    @MainActor
    func testProviderConfigurationStorePrunesOrphanedCollapsedDashboardAccountIDs() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        let account = try XCTUnwrap(store.addAccount(for: .codex))
        defaults.set(
            [account.id, "codex.orphaned-account"].sorted(),
            forKey: "collapsedDashboardAccountIDs"
        )

        let reloadedStore = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: EmptySecretStore()
        )

        XCTAssertEqual(reloadedStore.collapsedDashboardAccountIDs, [account.id])
        XCTAssertEqual(
            defaults.stringArray(forKey: "collapsedDashboardAccountIDs"),
            [account.id]
        )
    }
}
