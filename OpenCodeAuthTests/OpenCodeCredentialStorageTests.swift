import Foundation
import XCTest
@testable import CodexBarIOS

final class OpenCodeCredentialStorageTests: XCTestCase {
    @MainActor
    func testRemovalKeepsAccountPreferencesAndOtherCredentials() throws {
        let suite = "OpenCodeAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = OpenCodeTestSecrets()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        var first = try XCTUnwrap(store.addAccount(for: .openCodeZen))
        first.openCodeWorkspaceId = "wrk_first"
        first.authMethod = .browserSession
        first.showsHistory = false
        XCTAssertTrue(store.replaceCredential("first", for: first))
        let second = try XCTUnwrap(store.addAccount(for: .openCodeZen))
        XCTAssertTrue(store.saveSecret("second", for: second))
        let layout = store.metricLayouts[first.id]
        XCTAssertTrue(store.saveSecret("", for: first))
        XCTAssertFalse(store.hasSecret(for: first))
        XCTAssertEqual(store.configuration(accountID: first.id), first)
        XCTAssertEqual(store.metricLayouts[first.id], layout)
        XCTAssertEqual(try secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: second)), "second")
        XCTAssertTrue(store.replaceCredential("renewed", for: first))
        XCTAssertTrue(store.isConfigured(first))
    }

    @MainActor
    func testFailedKeychainWriteDoesNotClaimConnectionOrReplaceWorkspace() throws {
        let suite = "OpenCodeAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = OpenCodeTestSecrets()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        let account = try XCTUnwrap(store.addAccount(for: .openCodeZen))
        var selected = account
        selected.openCodeWorkspaceId = "wrk_selected"
        selected.authMethod = .browserSession
        secrets.setFailure(true)
        XCTAssertFalse(store.replaceCredential("candidate", for: selected))
        XCTAssertFalse(store.hasSecret(for: account))
        XCTAssertEqual(store.configuration(accountID: account.id), account)
    }
}

final class OpenCodeTestSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var fails = false
    private var readFails = false

    func setFailure(_ value: Bool) { lock.withLock { fails = value } }
    func setReadFailure(_ value: Bool) { lock.withLock { readFails = value } }
    func readSecret(account: String) throws -> String? {
        try lock.withLock {
            if readFails { throw OpenCodeSignInError.validationFailed }
            return values[account]
        }
    }
    func saveSecret(_ secret: String, account: String) throws {
        try lock.withLock {
            if fails { throw OpenCodeSignInError.validationFailed }
            values[account] = secret
        }
    }
    func deleteSecret(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}
