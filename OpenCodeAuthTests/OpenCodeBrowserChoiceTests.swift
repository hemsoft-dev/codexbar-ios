import Foundation
import XCTest
@testable import CodexBarIOS

final class OpenCodeBrowserChoiceTests: XCTestCase {
    func testBrowserChoiceOnlySharesCookiesWhenExplicitlySelected() {
        XCTAssertFalse(OpenCodeBrowserMode.existingSession.prefersEphemeralSession)
        XCTAssertTrue(OpenCodeBrowserMode.privateSession.prefersEphemeralSession)
    }

    #if canImport(UIKit)
    @MainActor
    func testNativeBrowserFactoryPreservesPrivateDefaultAndAllowsExplicitSharing() {
        let url = URL(string: "https://opencode.ai/console/device")!
        let defaultSession = PrivateWebAuthenticationPresenter.makeSession(url: url) { _ in }
        XCTAssertTrue(defaultSession.prefersEphemeralWebBrowserSession)
        let browserSession = PrivateWebAuthenticationPresenter.makeSession(
            url: url, prefersEphemeralSession: OpenCodeBrowserMode.existingSession.prefersEphemeralSession
        ) { _ in }
        XCTAssertFalse(browserSession.prefersEphemeralWebBrowserSession)
        let privateSession = PrivateWebAuthenticationPresenter.makeSession(
            url: url, prefersEphemeralSession: OpenCodeBrowserMode.privateSession.prefersEphemeralSession
        ) { _ in }
        XCTAssertTrue(privateSession.prefersEphemeralWebBrowserSession)
    }
    #endif

    func testReconnectPreservesUserAndWorkspaceButAllowsTokenRenewal() throws {
        let saved = try credential().encoded()
        let renewed = try credential(accessToken: "renewed").encoded()
        XCTAssertTrue(canReconnect(renewed, saved: saved))
        XCTAssertFalse(canReconnect(try credential(user: "other").encoded(), saved: saved))
        XCTAssertFalse(canReconnect(try credential(workspace: "wrk_other").encoded(), saved: saved))
        XCTAssertFalse(canReconnect("invalid", saved: saved))
        XCTAssertTrue(canReconnect(renewed, saved: nil))
        XCTAssertTrue(canReconnect(renewed, saved: "legacy-dashboard-credential"))
        XCTAssertFalse(OpenCodeSessionValidator.canReconnect(
            workspaceID: "wrk_one", configuredWorkspace: "wrk_other", credential: renewed, savedCredential: saved
        ))
    }

    @MainActor
    func testReconnectRechecksSavedIdentityAndAccountExistence() throws {
        let suite = "OpenCodeAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = OpenCodeTestSecrets()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        var account = try XCTUnwrap(store.addAccount(for: .openCodeZen))
        account.openCodeWorkspaceId = "wrk_one"
        let original = try credential().encoded()
        XCTAssertTrue(store.canReconnectOpenCodeSession(original, workspaceID: "wrk_one", accountID: account.id))
        XCTAssertTrue(store.replaceCredential(original, for: account))
        XCTAssertTrue(store.canReconnectOpenCodeSession(original, workspaceID: "wrk_one", accountID: account.id))
        XCTAssertFalse(store.canReconnectOpenCodeSession("invalid", workspaceID: "wrk_one", accountID: account.id))
        XCTAssertFalse(store.canReconnectOpenCodeSession(original, workspaceID: "wrk_other", accountID: account.id))
        let otherUser = try credential(user: "other").encoded()
        XCTAssertTrue(store.replaceCredential(otherUser, for: account))
        XCTAssertFalse(store.canReconnectOpenCodeSession(original, workspaceID: "wrk_one", accountID: account.id))
        XCTAssertEqual(try secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: account)), otherUser)
        XCTAssertTrue(store.removeAccount(account))
        XCTAssertFalse(store.canReconnectOpenCodeSession(original, workspaceID: "wrk_one", accountID: account.id))
        let cursor = try XCTUnwrap(store.addAccount(for: .cursor))
        XCTAssertFalse(store.canReconnectOpenCodeSession(original, workspaceID: "wrk_one", accountID: cursor.id))
    }

    @MainActor
    func testUnreadableSavedCredentialCannotAuthorizeAnIdentityReplacement() throws {
        let suite = "OpenCodeAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults, secretStore: UnreadableSecrets(), widgetSnapshotDefaults: defaults)
        let account = try XCTUnwrap(store.addAccount(for: .openCodeZen))
        XCTAssertFalse(store.canReconnectOpenCodeSession(
            try credential().encoded(), workspaceID: "wrk_one", accountID: account.id
        ))
    }

    private func canReconnect(_ candidate: String, saved: String?) -> Bool {
        OpenCodeSessionValidator.canReconnect(
            workspaceID: "wrk_one", configuredWorkspace: "wrk_one", credential: candidate, savedCredential: saved
        )
    }

    private func credential(
        workspace: String = "wrk_one", user: String = "user_one", accessToken: String = "synthetic-access"
    ) -> OpenCodeConsoleCredential {
        OpenCodeConsoleCredential(
            kind: "opencode-console-v1", accessToken: accessToken, refreshToken: "synthetic-refresh",
            expiresAt: .distantFuture, workspaceID: workspace, userID: user
        )
    }
}

private struct UnreadableSecrets: SecretStore {
    func readSecret(account: String) throws -> String? { throw OpenCodeSignInError.validationFailed }
    func saveSecret(_ secret: String, account: String) throws { throw OpenCodeSignInError.validationFailed }
    func deleteSecret(account: String) throws { throw OpenCodeSignInError.validationFailed }
}
