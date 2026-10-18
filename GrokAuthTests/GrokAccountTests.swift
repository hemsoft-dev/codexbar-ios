import Combine
import Foundation
import XCTest
@testable import CodexBarIOS

final class GrokAccountTests: XCTestCase {
    @MainActor
    func testConnectionRequiresSavedCredentialAndSubjectCannotBeReplaced() throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = GrokTestSecrets()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        let account = try XCTUnwrap(store.addAccount(for: .grok))
        var changed: [String] = []
        let subscription = store.credentialChanges.sink { changed.append($0) }
        var clearedHistory: [String] = []
        let historySubscription = store.grokHistoryInvalidations.sink { clearedHistory.append($0) }
        defer { subscription.cancel(); historySubscription.cancel() }
        XCTAssertFalse(store.isConfigured(account))
        let first = credential(subject: "first")
        let other = credential(subject: "other")
        XCTAssertTrue(store.canReconnectGrok(first, accountID: account.id))
        XCTAssertTrue(store.replaceCredential(try first.encoded(), for: account))
        XCTAssertEqual(changed, [account.id])
        XCTAssertTrue(store.isConfigured(account))
        XCTAssertTrue(store.canReconnectGrok(first, accountID: account.id))
        XCTAssertFalse(store.canReconnectGrok(other, accountID: account.id))
        XCTAssertTrue(store.replaceCredential(try first.encoded(), for: account))
        XCTAssertTrue(clearedHistory.isEmpty)
        XCTAssertTrue(store.saveSecret("", for: account))
        XCTAssertEqual(clearedHistory, [account.id])
        XCTAssertEqual(changed, [account.id, account.id, account.id])
        XCTAssertFalse(store.isConfigured(account))
        XCTAssertTrue(store.canReconnectGrok(other, accountID: account.id))
    }

    @MainActor
    func testChangingVerifiedSubjectInvalidatesHistory() throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults, secretStore: GrokTestSecrets(), widgetSnapshotDefaults: defaults
        )
        let account = try XCTUnwrap(store.addAccount(for: .grok))
        var clearedHistory: [String] = []
        let subscription = store.grokHistoryInvalidations.sink { clearedHistory.append($0) }
        defer { subscription.cancel() }
        XCTAssertTrue(store.replaceCredential(try credential(subject: "first").encoded(), for: account))
        XCTAssertTrue(clearedHistory.isEmpty)
        XCTAssertTrue(store.replaceCredential(try credential(subject: "other").encoded(), for: account))
        XCTAssertEqual(clearedHistory, [account.id])
    }

    @MainActor
    func testFailedPersistenceAndRemovalCannotClaimAConnection() throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = GrokTestSecrets()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        let account = try XCTUnwrap(store.addAccount(for: .grok))
        var changed: [String] = []
        let subscription = store.credentialChanges.sink { changed.append($0) }
        defer { subscription.cancel() }
        secrets.failWrites = true
        XCTAssertFalse(store.replaceCredential(try credential(subject: "one").encoded(), for: account))
        XCTAssertTrue(changed.isEmpty)
        XCTAssertFalse(store.isConfigured(account))
        secrets.failWrites = false
        XCTAssertTrue(store.replaceCredential(try credential(subject: "one").encoded(), for: account))
        XCTAssertTrue(store.removeAccount(account))
        XCTAssertEqual(changed, [account.id, account.id])
        XCTAssertFalse(store.canReconnectGrok(credential(subject: "one"), accountID: account.id))
        XCTAssertNil(try secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: account)))
    }

    @MainActor
    func testVerifiedPlanNamesRespectSubjectsCustomLabelsAndDuplicates() throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults, secretStore: GrokTestSecrets(), widgetSnapshotDefaults: defaults
        )
        let first = try XCTUnwrap(store.addAccount(for: .grok))
        let second = try XCTUnwrap(store.addAccount(for: .grok))
        XCTAssertTrue(store.replaceCredential(try credential(subject: "one").encoded(), for: first))
        XCTAssertTrue(store.replaceCredential(try credential(subject: "two").encoded(), for: second))
        var formerlyGenerated = first
        formerlyGenerated.accountLabel = "SuperGrok Lite"
        formerlyGenerated.grokGeneratedLabel = "SuperGrok Lite"
        XCTAssertTrue(store.update(formerlyGenerated))
        func result(_ account: ProviderAccountConfiguration, subject: String, plan: String?) throws -> ProviderUsageResult {
            try GrokUsageProvider.parseCredits(
                Data(#"{"config":{"isUnifiedBillingUser":true}}"#.utf8),
                configuration: account, subject: subject, now: Date(), verifiedPlanName: plan
            )
        }
        for plan in [nil, "SuperGrok Lite", "Unrecognized tier"] as [String?] {
            XCTAssertTrue(store.update(formerlyGenerated))
            XCTAssertFalse(store.applyVerifiedGrokPlan(try result(first, subject: "two", plan: plan)))
            XCTAssertEqual(store.configuration(accountID: first.id)?.accountLabel, "SuperGrok Lite")
            XCTAssertTrue(store.applyVerifiedGrokPlan(try result(first, subject: "one", plan: plan)))
            XCTAssertEqual(store.configuration(accountID: first.id)?.accountLabel, "Grok")
        }
        XCTAssertTrue(store.applyVerifiedGrokPlan(try result(second, subject: "two", plan: "SuperGrok Lite")))
        XCTAssertEqual(store.configuration(accountID: first.id)?.accountLabel, "Grok")
        XCTAssertEqual(store.configuration(accountID: second.id)?.accountLabel, "Grok 2")
        XCTAssertTrue(store.applyVerifiedGrokPlan(try result(first, subject: "one", plan: "SuperGrok Plus")))
        XCTAssertEqual(store.configuration(accountID: first.id)?.accountLabel, "Grok")
        var custom = try XCTUnwrap(store.configuration(accountID: first.id))
        custom.accountLabel = "My Grok"
        XCTAssertTrue(store.update(custom))
        for plan in [nil, "SuperGrok Heavy"] as [String?] {
            XCTAssertFalse(store.applyVerifiedGrokPlan(try result(first, subject: "one", plan: plan)))
        }
        XCTAssertEqual(store.configuration(accountID: first.id)?.accountLabel, "My Grok")
        XCTAssertTrue(store.applyVerifiedGrokPlan(try result(second, subject: "two", plan: nil)))
        XCTAssertEqual(store.configuration(accountID: second.id)?.accountLabel, "Grok 2")
    }

    @MainActor
    func testWidgetUsesCurrentGrokLabelEvenBeforeTheNextUsageFetch() throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults, secretStore: GrokTestSecrets(), widgetSnapshotDefaults: defaults
        )
        let account = try XCTUnwrap(store.addAccount(for: .grok))
        XCTAssertTrue(store.replaceCredential(try credential(subject: "one").encoded(), for: account))
        let result = try GrokUsageProvider.parseCredits(
            Data(#"{"config":{"isUnifiedBillingUser":true,"prepaidBalance":{"val":0}}}"#.utf8),
            configuration: account, subject: "one", now: Date(), verifiedPlanName: "SuperGrok Lite"
        )
        XCTAssertTrue(store.applyVerifiedGrokPlan(result))
        XCTAssertEqual(result.title, account.accountLabel)
        let refresh = UsageRefreshService(providers: [], initialResults: [result])
        refresh.updateGrokResultTitle("Grok", accountID: account.id)
        XCTAssertEqual(refresh.results.first?.title, "Grok")
        WidgetSnapshotPublisher.publish(results: [result], configurationStore: store, snapshotDefaults: defaults)
        XCTAssertEqual(WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first?.title, "Grok")
    }

    @MainActor
    func testSavedCreditsFirstGrokLayoutMigratesAndRetainsOtherPreferences() throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credits = "grok.monetary.balance.usd"
        let weekly = "grok.included-usage"
        let account = "grok.saved"
        let other = "cursor.saved"
        let secrets = GrokTestSecrets()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        _ = store.reconcileMetricLayout(accountID: account, availableMetricIDs: [credits])
        store.updateMetricVisibility(false, accountID: account, metricID: credits)
        store.updateMetricWidth(.half, accountID: account, metricID: credits)
        store.updateVisualizationStyle(.circularRing, accountID: account, metricID: credits)
        _ = store.reconcileMetricLayout(accountID: other, availableMetricIDs: ["cursor.models"])
        store.updateMetricVisibility(false, accountID: other, metricID: "cursor.models")
        let creditsPreference = store.metricLayouts[account]?.preferences[credits]
        let otherLayout = store.metricLayouts[other]

        XCTAssertEqual(store.metricOrder(accountID: account, availableMetricIDs: [weekly, credits]), [weekly, credits])
        var legacy = try XCTUnwrap(store.metricLayouts[account])
        legacy.orderedMetricIDs = [credits, weekly]
        store.replaceMetricLayout(legacy, accountID: account)
        let restored = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        XCTAssertEqual(restored.metricOrder(accountID: account, availableMetricIDs: [weekly, credits]), [weekly, credits])
        XCTAssertEqual(restored.metricLayouts[account]?.preferences[credits], creditsPreference)
        XCTAssertEqual(restored.metricLayouts[other], otherLayout)
        XCTAssertEqual(restored.metricOrder(accountID: account, availableMetricIDs: [credits]), [weekly, credits])
    }

    @MainActor
    func testExplicitGrokReorderSurvivesDiscoveryAndReload() throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credits = "grok.monetary.balance.usd"
        let weekly = "grok.included-usage"
        let account = "grok.saved"
        let secrets = GrokTestSecrets()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        _ = store.reconcileMetricLayout(accountID: account, availableMetricIDs: [weekly, credits])
        store.updateMetricOrder([credits, weekly], accountID: account)
        store.updateMetricWidth(.full, accountID: account, metricID: weekly)
        let restored = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        XCTAssertTrue(try XCTUnwrap(restored.metricLayouts[account]).hasCustomMetricOrder)
        XCTAssertEqual(restored.metricOrder(accountID: account, availableMetricIDs: [weekly, credits]), [credits, weekly])
        XCTAssertEqual(restored.metricWidth(accountID: account, metricID: weekly), .full)
    }

    @MainActor
    func testCopiedGrokOrderRemainsExplicitAfterReconciliation() throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let weekly = "grok.included-usage"
        let credits = "grok.monetary.balance.usd"
        let secrets = GrokTestSecrets()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        _ = store.reconcileMetricLayout(accountID: "grok.source", availableMetricIDs: [weekly, credits])
        store.updateMetricOrder([credits, weekly], accountID: "grok.source")
        store.copyMetricLayout(
            from: "grok.source", to: "grok.destination",
            destinationAvailableMetricIDs: [weekly, credits]
        )
        let restored = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        XCTAssertTrue(try XCTUnwrap(restored.metricLayouts["grok.destination"]).hasCustomMetricOrder)
        XCTAssertEqual(
            restored.metricOrder(accountID: "grok.destination", availableMetricIDs: [weekly, credits]),
            [credits, weekly]
        )
    }

    func testCustomOrderUsesNewSchemaAndOlderLayoutsDefaultToInheritedOrder() throws {
        let current = AccountMetricLayout(
            orderedMetricIDs: ["grok.monetary.balance.usd", "grok.included-usage"],
            hasCustomMetricOrder: true
        )
        XCTAssertEqual(current.version, 4)
        XCTAssertTrue(try JSONDecoder().decode(
            AccountMetricLayout.self, from: JSONEncoder().encode(current)
        ).hasCustomMetricOrder)
        let old = Data(#"{"version":3,"orderedMetricIDs":["grok.monetary.balance.usd","grok.included-usage"]}"#.utf8)
        let decoded = try JSONDecoder().decode(AccountMetricLayout.self, from: old)
        XCTAssertEqual(decoded.version, 3)
        XCTAssertFalse(decoded.hasCustomMetricOrder)
    }

    private func credential(subject: String) -> GrokCredential {
        GrokCredential(
            kind: "grok-oauth-v1", accessToken: "fixture-token", refreshToken: "fixture-refresh",
            expiresAt: Date().addingTimeInterval(3600), subject: subject, email: nil
        )
    }
}

final class GrokTestSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var shouldFail = false

    var failWrites: Bool {
        get { lock.withLock { shouldFail } }
        set { lock.withLock { shouldFail = newValue } }
    }

    func readSecret(account: String) throws -> String? { lock.withLock { values[account] } }
    func saveSecret(_ secret: String, account: String) throws {
        try lock.withLock {
            if shouldFail { throw GrokAuthError.invalidResponse }
            values[account] = secret
        }
    }
    func deleteSecret(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}
