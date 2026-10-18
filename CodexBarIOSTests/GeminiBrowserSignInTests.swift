import XCTest
import WebKit
import Combine
@testable import CodexBarIOS

#if CODEXBAR_LOCAL_AUTH_TESTS
/// Explicit local-only coverage. Automatic CI does not enable this compilation condition.
final class GreptileBrowserCookieRegressionTests: XCTestCase {
    @MainActor
    func testSameTokenExpiryExtensionWhileVerifyingIsSaved() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConfigurationAndAuthMockURLProtocol.self]
        let client = GreptileDashboardClient(session: URLSession(configuration: configuration))
        ConfigurationAndAuthMockURLProtocol.handler = { request in
            if request.url?.path == "/api/auth/session" { Thread.sleep(forTimeInterval: 0.5) }
            let body = request.url?.path == "/api/auth/session"
                ? #"{"user":{"greptileId":"synthetic-user","greptileToken":"synthetic-token","organizations":[{"tenantExternalId":"synthetic-org","name":"Synthetic organization"}]}}"#
                : #"[{"result":{"data":{"json":{"kind":"free"}}}}]"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        defer { ConfigurationAndAuthMockURLProtocol.handler = nil }
        let updatedExpiry = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 7_200)
        let completed = expectation(description: "Extended expiry is saved")
        let session = GreptileBrowserSignInSession(client: client) { result in
            defer { completed.fulfill() }
            guard case .success(let credential) = result else { XCTFail("Connection failed"); return }
            XCTAssertEqual(credential.cookies.first?.expiresAt, updatedExpiry)
        }
        defer { session.invalidate() }
        let verifying = expectation(description: "Initial identity verification starts")
        let chooser = expectation(description: "Verified chooser appears")
        var started = false
        var appeared = false
        let verificationObserver = session.$isVerifying.sink { value in
            if value && !started { started = true; verifying.fulfill() }
        }
        let chooserObserver = session.$organizations.sink { organizations in
            if !organizations.isEmpty && !appeared { appeared = true; chooser.fulfill() }
        }
        defer { verificationObserver.cancel(); chooserObserver.cancel() }
        let store = session.webView.configuration.websiteDataStore.httpCookieStore
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: "__Secure-authjs.session-token", .value: "same-synthetic-cookie",
            .domain: "app.greptile.com", .path: "/", .secure: "TRUE",
            .expires: Date().addingTimeInterval(600),
        ]
        await store.setCookie(try XCTUnwrap(HTTPCookie(properties: properties)))
        session.webView.loadHTMLString("<html><body>Synthetic dashboard</body></html>",
                                      baseURL: URL(string: "https://app.greptile.com/"))
        await fulfillment(of: [verifying], timeout: 10)
        properties[.expires] = updatedExpiry
        await store.setCookie(try XCTUnwrap(HTTPCookie(properties: properties)))
        session.cookiesDidChange(in: store)
        await fulfillment(of: [chooser], timeout: 10)
        session.connect(try XCTUnwrap(session.organizations.first))
        await fulfillment(of: [completed], timeout: 10)
    }

    @MainActor
    func testUnrelatedCookieChangesKeepChooserStableAndConnectionCompletes() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConfigurationAndAuthMockURLProtocol.self]
        let client = GreptileDashboardClient(session: URLSession(configuration: configuration))
        ConfigurationAndAuthMockURLProtocol.handler = { request in
            let body = request.url?.path == "/api/auth/session"
                ? #"{"user":{"greptileId":"synthetic-user","greptileToken":"synthetic-token","organizations":[{"tenantExternalId":"synthetic-org","name":"Synthetic organization"}]}}"#
                : #"[{"result":{"data":{"json":{"kind":"free"}}}}]"#
            let response = request.value(forHTTPHeaderField: "Cookie")?.contains("expired-synthetic-cookie") == true
                ? #"{"user":null}"# : body
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(response.utf8))
        }
        defer { ConfigurationAndAuthMockURLProtocol.handler = nil }
        let completed = expectation(description: "Verified sign-in completes")
        let session = GreptileBrowserSignInSession(client: client) { result in
            if case .failure = result { XCTFail("Synthetic verified sign-in should succeed.") }
            if case .success(let credential) = result {
                XCTAssertEqual(credential.cookies.first?.value, "rotated-synthetic-cookie")
            }
            completed.fulfill()
        }
        defer { session.invalidate() }
        let ready = expectation(description: "Organization chooser appears")
        var appeared = false
        var resets = 0
        var expectingRotation = false
        let rotated = expectation(description: "Changed authentication session is reverified")
        let rejected = expectation(description: "Expired session clears the chooser")
        let recovered = expectation(description: "Fresh session restores the chooser")
        var expectingExpiry = false
        var expectingRecovery = false
        let observer = session.$organizations.sink { organizations in
            if !organizations.isEmpty, !appeared { appeared = true; ready.fulfill() }
            if appeared && organizations.isEmpty { resets += 1 }
            if !organizations.isEmpty, expectingRotation { expectingRotation = false; rotated.fulfill() }
            if organizations.isEmpty, expectingExpiry { expectingExpiry = false; rejected.fulfill() }
            if !organizations.isEmpty, expectingRecovery { expectingRecovery = false; recovered.fulfill() }
        }
        defer { observer.cancel() }
        let store = session.webView.configuration.websiteDataStore.httpCookieStore
        let auth = try XCTUnwrap(HTTPCookie(properties: [
            .name: "__Secure-authjs.session-token", .value: "synthetic-cookie",
            .domain: "app.greptile.com", .path: "/", .secure: "TRUE",
        ]))
        await store.setCookie(auth)
        session.webView.loadHTMLString("<html><body>Synthetic Greptile dashboard</body></html>",
                                      baseURL: URL(string: "https://app.greptile.com/"))
        await fulfillment(of: [ready], timeout: 10)
        let organization = try XCTUnwrap(session.organizations.first)
        for index in 0..<20 {
            let unrelated = try XCTUnwrap(HTTPCookie(properties: [
                .name: "synthetic-analytics", .value: String(index),
                .domain: "app.greptile.com", .path: "/", .secure: "TRUE",
            ]))
            await store.setCookie(unrelated)
            session.cookiesDidChange(in: store)
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(resets, 0, "Unrelated cookies must not flicker between browser and organization chooser.")
        XCTAssertEqual(session.organizations, [organization])
        var properties = try XCTUnwrap(auth.properties)
        properties[.value] = "rotated-synthetic-cookie"
        expectingRotation = true
        await store.setCookie(try XCTUnwrap(HTTPCookie(properties: properties)))
        session.cookiesDidChange(in: store)
        await fulfillment(of: [rotated], timeout: 10)
        XCTAssertEqual(resets, 0, "Same-account session rotation must reverify without hiding the chooser.")
        properties[.value] = "expired-synthetic-cookie"
        expectingExpiry = true
        await store.setCookie(try XCTUnwrap(HTTPCookie(properties: properties)))
        session.cookiesDidChange(in: store)
        await fulfillment(of: [rejected], timeout: 10)
        XCTAssertTrue(session.organizations.isEmpty, "An invalid identity must hide the prior organization.")
        properties[.value] = "rotated-synthetic-cookie"
        expectingRecovery = true
        await store.setCookie(try XCTUnwrap(HTTPCookie(properties: properties)))
        session.cookiesDidChange(in: store)
        await fulfillment(of: [recovered], timeout: 10)
        session.connect(organization)
        await fulfillment(of: [completed], timeout: 10)
    }
}
#endif

final class GeminiBrowserSignInTests: XCTestCase {
    func testCookieSelectionRejectsWrongDomainsScopesExpiredAndInsecureValues() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let cookies = try [
            cookie("__Secure-1PSID", value: "good-primary"),
            cookie("__Secure-1PSIDTS", value: "good-rotating"),
            cookie("SID", value: "discard"),
            cookie("__Secure-1PSIDTS", value: "host-only", domain: "google.com"),
            cookie("__Secure-1PSID", value: "wrong-domain", domain: ".google.com.evil.example"),
            cookie("__Secure-1PSID", value: "subdomain", domain: "accounts.google.com"),
            cookie("__Secure-1PSIDTS", value: "wrong-path", path: "/accounts"),
            cookie("__Secure-1PSID", value: "insecure", secure: false),
            cookie("__Secure-1PSID", value: "expired", expires: now.addingTimeInterval(-1)),
        ]
        let stored = try XCTUnwrap(GeminiBrowserSessionPolicy.storedCredential(from: cookies, now: now))
        XCTAssertEqual(
            try GeminiSessionCredentialsParser.parse(stored),
            GeminiSessionCredentials(securePSID: "good-primary", securePSIDTS: "good-rotating")
        )
        XCTAssertNil(try GeminiBrowserSessionPolicy.storedCredential(from: [cookie("SID", value: "discard")]))
        XCTAssertThrowsError(try GeminiBrowserSessionPolicy.storedCredential(from: [
            cookie("__Secure-1PSID", value: "one"),
            cookie("__Secure-1PSID", value: "two"),
        ]))
    }

    func testNavigationAndReturnPolicyRejectsImpersonationAndWaitsForGoogleSignIn() {
        for url in ["https://accounts.google.com/signin", "https://myaccount.google.com/", "https://gemini.google.com/usage?pli=1"] {
            XCTAssertTrue(GeminiBrowserSessionPolicy.allowsNavigation(to: URL(string: url)))
        }
        for url in ["http://google.com", "https://google.com.evil.example", "https://evilgoogle.com", "https://google.com:8443", "https://user@google.com", "file:///tmp/test", "javascript:alert(1)"] {
            XCTAssertFalse(GeminiBrowserSessionPolicy.allowsNavigation(to: URL(string: url)))
        }
        XCTAssertFalse(GeminiBrowserSessionPolicy.canReturnToUsage(from: URL(string: "https://accounts.google.com/signin/challenge")))
        XCTAssertTrue(GeminiBrowserSessionPolicy.canReturnToUsage(from: URL(string: "https://myaccount.google.com/")))
        XCTAssertFalse(GeminiBrowserSessionPolicy.isUsagePage(URL(string: "https://myaccount.google.com/usage")))
        XCTAssertTrue(GeminiBrowserSessionPolicy.isUsagePage(GeminiBrowserSessionPolicy.usageURL))
    }

    func testRepeatedAccountLandingOnlyReturnsAutomaticallyForFreshCredentials() {
        var state = GeminiBrowserReturnState()
        XCTAssertTrue(state.shouldReturn(for: "first-session"))
        XCTAssertFalse(state.shouldReturn(for: "first-session"))
        XCTAssertTrue(state.shouldReturn(for: "refreshed-session"))
        XCTAssertFalse(state.shouldReturn(for: "refreshed-session"))
    }

    func testBlockedMainFrameAndPopupExplainFailureWithoutAlarmingForSubframes() {
        let external = URL(string: "https://external.example/signin")
        XCTAssertTrue(GeminiBrowserSessionPolicy.shouldExplainBlockedNavigation(isMainFrame: true, url: external))
        XCTAssertTrue(GeminiBrowserSessionPolicy.shouldExplainBlockedNavigation(isMainFrame: nil, url: external))
        XCTAssertFalse(GeminiBrowserSessionPolicy.shouldExplainBlockedNavigation(isMainFrame: false, url: external))
        XCTAssertFalse(GeminiBrowserSessionPolicy.shouldExplainBlockedNavigation(isMainFrame: nil, url: URL(string: "about:blank")))
    }

    @MainActor
    func testEveryAttemptHasAnIsolatedNonpersistentStoreAndCancellationCompletesOnce() {
        var completions = 0
        let first = GeminiBrowserSignInSession { _ in completions += 1 }
        let second = GeminiBrowserSignInSession { _ in completions += 1 }
        XCTAssertFalse(first.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(second.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(first.webView.configuration.websiteDataStore === second.webView.configuration.websiteDataStore)
        first.cancel()
        first.cancel()
        XCTAssertEqual(completions, 1)
        second.invalidate()
    }

    @MainActor
    func testLabelWithoutSavedSessionIsNotConfiguredAfterMigration() throws {
        let fixture = Fixture()
        var account = try XCTUnwrap(fixture.store.addAccount(for: .gemini))
        account.accountLabel = "Personal Gemini"
        account.authMethod = .apiKey
        XCTAssertTrue(fixture.store.update(account))
        let reloaded = try XCTUnwrap(fixture.store.configuration(accountID: account.id))
        XCTAssertEqual(reloaded.authMethod, .browserSession)
        XCTAssertFalse(fixture.store.isConfigured(reloaded))
        XCTAssertEqual(fixture.store.statusText(for: reloaded), "Not configured - sign in with Google")
    }

    @MainActor
    func testReconnectPreservesMetadataAndOtherAccountAndDisconnectIsScoped() async throws {
        let fixture = Fixture()
        var first = try XCTUnwrap(fixture.store.addAccount(for: .gemini))
        first.accountLabel = "Personal"
        first.groupID = try XCTUnwrap(fixture.store.addGroup(named: "Personal accounts")).id
        first.showsHistory = false
        first.authMethod = .apiKey
        XCTAssertTrue(fixture.store.update(first))
        let originalResult = validResult(for: first)
        let metricID = try XCTUnwrap(originalResult.availableMetrics.first?.id)
        fixture.store.reconcileMetricLayout(accountID: first.id, availableMetricIDs: originalResult.availableMetrics.map(\.id))
        fixture.store.updateMetricVisibility(false, accountID: first.id, metricID: metricID)
        fixture.store.updateDashboardCardCollapsed(true, accountID: first.id)
        let history = UsageHistoryStore(defaults: fixture.defaults)
        history.record(results: [originalResult], now: originalResult.fetchedAt)
        let originalHistory = history.snapshots(for: first.id)
        XCTAssertFalse(originalHistory.isEmpty)
        let second = try XCTUnwrap(fixture.store.addAccount(for: .gemini))
        XCTAssertTrue(fixture.store.saveSecret("__Secure-1PSID=old-first", for: first))
        XCTAssertTrue(fixture.store.saveSecret("__Secure-1PSID=second", for: second))
        let model = ProviderSettingsViewModel(configurationStore: fixture.store, accountID: first.id)
        model.geminiSessionValidator = StubValidator(result: validResult(for: first))
        model.startGeminiSignIn()
        model.geminiBrowserSession?.finish(.success("__Secure-1PSID=new-first"))
        await waitForSignIn(model)
        XCTAssertNil(model.credentialError)
        XCTAssertEqual(model.credentialMessageSystemImage, "checkmark.circle")
        let saved = try XCTUnwrap(fixture.store.configuration(accountID: first.id))
        XCTAssertEqual(saved.accountLabel, first.accountLabel)
        XCTAssertEqual(saved.showsHistory, first.showsHistory)
        XCTAssertEqual(saved.groupID, first.groupID)
        XCTAssertEqual(saved.id, first.id)
        XCTAssertEqual(saved.authMethod, .browserSession)
        XCTAssertTrue(try XCTUnwrap(fixture.secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: first))).contains("new-first"))
        let reloaded = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: fixture.defaults, secretStore: fixture.secrets)
        XCTAssertTrue(reloaded.hasSecret(for: saved))
        XCTAssertFalse(reloaded.isMetricVisible(accountID: first.id, metricID: metricID))
        XCTAssertTrue(reloaded.isDashboardCardCollapsed(accountID: first.id))
        XCTAssertEqual(reloaded.configuration(accountID: first.id)?.groupID, first.groupID)
        XCTAssertEqual(UsageHistoryStore(defaults: fixture.defaults).snapshots(for: first.id), originalHistory)
        model.removeSavedCredential()
        XCTAssertFalse(fixture.store.hasSecret(for: saved))
        XCTAssertEqual(try fixture.secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: second)), "__Secure-1PSID=second")
        XCTAssertFalse(String(describing: fixture.defaults.dictionaryRepresentation()).contains("new-first"))
    }

    @MainActor
    func testCanceledOrFailedBrowserSignInPreservesExistingCredentialAndAllowsRetry() async throws {
        let fixture = Fixture()
        let account = try XCTUnwrap(fixture.store.addAccount(for: .gemini))
        XCTAssertTrue(fixture.store.saveSecret("__Secure-1PSID=original", for: account))
        let model = ProviderSettingsViewModel(configurationStore: fixture.store, accountID: account.id)
        model.startGeminiSignIn()
        model.geminiBrowserSession?.cancel()
        XCTAssertFalse(model.isSigningInWithGemini)
        XCTAssertTrue(model.credentialError?.contains("canceled") == true)
        model.startGeminiSignIn()
        model.geminiBrowserSession?.finish(.failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "secret-cookie-value"])))
        XCTAssertFalse(model.isSigningInWithGemini)
        XCTAssertFalse(model.credentialError?.contains("secret-cookie-value") == true)
        XCTAssertEqual(try fixture.secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: account)), "__Secure-1PSID=original")
        model.startGeminiSignIn()
        XCTAssertTrue(model.isSigningInWithGemini)
        model.cancelAuthentication()
    }

    @MainActor
    func testMissingMetersResetOrWrongAccountNeverPersistsCredentials() async throws {
        let fixture = Fixture()
        let account = try XCTUnwrap(fixture.store.addAccount(for: .gemini))
        let model = ProviderSettingsViewModel(configurationStore: fixture.store, accountID: account.id)
        for result in [
            validResult(for: account, keys: []),
            validResult(for: account, keys: ["five-hour"]),
            validResult(for: account, reset: nil),
            validResult(for: ProviderAccountConfiguration(id: "other", providerID: .gemini, authMethod: .browserSession)),
        ] {
            model.geminiSessionValidator = StubValidator(result: result)
            model.startGeminiSignIn()
            model.geminiBrowserSession?.finish(.success("__Secure-1PSID=unverified"))
            await waitForSignIn(model)
            XCTAssertNotNil(model.credentialError)
            XCTAssertFalse(fixture.store.hasSecret(for: account))
        }
    }

    @MainActor
    func testCancelDuringValidationIgnoresLateSuccessAfterDisconnect() async throws {
        let fixture = Fixture()
        let account = try XCTUnwrap(fixture.store.addAccount(for: .gemini))
        let validator = SuspendedValidator(result: validResult(for: account))
        let model = ProviderSettingsViewModel(configurationStore: fixture.store, accountID: account.id)
        model.geminiSessionValidator = validator
        defer {
            model.cancelAuthentication()
            Task { await validator.finish() }
        }
        model.startGeminiSignIn()
        model.geminiBrowserSession?.finish(.success("__Secure-1PSID=late"))
        try await validator.waitUntilStarted()
        model.removeSavedCredential()
        await validator.finish()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(fixture.store.hasSecret(for: account))
        XCTAssertFalse(model.isSigningInWithGemini)
    }

    @MainActor
    func testKeychainFailureDoesNotReportSuccessOrReplaceAccount() async throws {
        let fixture = Fixture()
        let failingSecrets = GeminiFailingWriteSecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: fixture.defaults, secretStore: failingSecrets)
        let account = try XCTUnwrap(store.addAccount(for: .gemini))
        let model = ProviderSettingsViewModel(configurationStore: store, accountID: account.id)
        model.geminiSessionValidator = StubValidator(result: validResult(for: account))
        model.startGeminiSignIn()
        model.geminiBrowserSession?.finish(.success("__Secure-1PSID=unsaved"))
        await waitForSignIn(model)
        XCTAssertTrue(model.credentialError?.contains("could not be saved in Keychain") == true)
        XCTAssertNil(model.credentialMessage)
        XCTAssertFalse(store.hasSecret(for: account))
        XCTAssertEqual(store.configuration(accountID: account.id), account)
    }

    @MainActor
    func testCodingImportRequiresConfirmationAndTypedCredentialsAndInvalidatesRefresh() throws {
        let fixture = Fixture()
        let account = try XCTUnwrap(fixture.store.addAccount(for: .gemini))
        XCTAssertTrue(fixture.store.saveSecret("__Secure-1PSID=apps", for: account))
        var credentialChanges = 0
        let model = ProviderSettingsViewModel(
            configurationStore: fixture.store, accountID: account.id,
            onCredentialsChanged: { credentialChanges += 1 }
        )
        model.geminiCodingSecret = #"{"access_token":"coding","expiry":"2030-01-01T00:00:00Z"}"#
        model.saveGeminiCodingCredential(confirmedSameAccount: false)
        XCTAssertFalse(fixture.store.hasGeminiCodingSecret(for: account))
        XCTAssertEqual(credentialChanges, 0)
        XCTAssertFalse(model.geminiCodingSecret.isEmpty)
        model.geminiCodingSecret = "__Secure-1PSID=not-a-coding-token"
        model.saveGeminiCodingCredential(confirmedSameAccount: true)
        XCTAssertFalse(fixture.store.hasGeminiCodingSecret(for: account))
        model.geminiCodingSecret = #"{"access_token":"coding","expiry":"2030-01-01T00:00:00Z"}"#
        model.saveGeminiCodingCredential(confirmedSameAccount: true)
        XCTAssertTrue(fixture.store.hasGeminiCodingSecret(for: account))
        XCTAssertEqual(credentialChanges, 1)
        XCTAssertEqual(model.geminiCodingSecret, "")
        XCTAssertEqual(try fixture.secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: account)), "__Secure-1PSID=apps")
        model.disconnectGeminiCoding()
        XCTAssertFalse(fixture.store.hasGeminiCodingSecret(for: account))
        XCTAssertTrue(fixture.store.hasSecret(for: account))
        XCTAssertEqual(credentialChanges, 2)
    }

    @MainActor
    func testReconnectWithCodingRequiresSameAccountConfirmationAndPreservesBothSources() async throws {
        let fixture = Fixture()
        let account = try XCTUnwrap(fixture.store.addAccount(for: .gemini))
        XCTAssertTrue(fixture.store.saveSecret("__Secure-1PSID=original", for: account))
        XCTAssertTrue(fixture.store.saveGeminiCodingSecret(
            #"{"access_token":"coding","expiry":"2030-01-01T00:00:00Z"}"#,
            for: account, confirmedSameAccount: true
        ))
        let model = ProviderSettingsViewModel(configurationStore: fixture.store, accountID: account.id)
        model.geminiSessionValidator = StubValidator(result: validResult(for: account))
        model.startGeminiSignIn()
        XCTAssertTrue(model.isSigningInWithGemini)
        model.geminiBrowserSession?.finish(.success("__Secure-1PSID=not-confirmed"))
        XCTAssertTrue(model.needsGeminiAccountConfirmation)
        XCTAssertEqual(try fixture.secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: account)), "__Secure-1PSID=original")
        model.cancelGeminiSignIn()
        model.confirmGeminiAppsAccount()
        XCTAssertEqual(try fixture.secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: account)), "__Secure-1PSID=original")
        model.startGeminiSignIn()
        model.geminiBrowserSession?.finish(.success("__Secure-1PSID=reconnected"))
        XCTAssertTrue(model.needsGeminiAccountConfirmation)
        model.confirmGeminiAppsAccount()
        await waitForSignIn(model)
        XCTAssertNil(model.credentialError)
        XCTAssertTrue(fixture.store.hasGeminiCodingSecret(for: account))
        XCTAssertTrue(try XCTUnwrap(fixture.secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: account))).contains("reconnected"))
        model.removeSavedCredential()
        XCTAssertFalse(fixture.store.hasSecret(for: account))
        XCTAssertTrue(fixture.store.hasGeminiCodingSecret(for: account))
        model.startGeminiSignIn()
        XCTAssertTrue(model.isSigningInWithGemini)
        model.cancelGeminiSignIn()
    }

    @MainActor
    func testLegacyCodingLinkRequiresConfirmationAndRemovesStandaloneAccountChoice() throws {
        let fixture = Fixture()
        let gemini = try XCTUnwrap(fixture.store.addAccount(for: .gemini))
        let legacy = try XCTUnwrap(fixture.store.addAccount(for: .antigravity))
        XCTAssertTrue(fixture.store.saveSecret(
            #"{"access_token":"legacy-coding","expiry":"2030-01-01T00:00:00Z"}"#, for: legacy
        ))
        var credentialChanges = 0
        let model = ProviderSettingsViewModel(
            configurationStore: fixture.store, accountID: gemini.id,
            onCredentialsChanged: { credentialChanges += 1 }
        )
        model.linkGeminiCodingAccount(legacy, confirmedSameAccount: false)
        XCTAssertTrue(fixture.store.unlinkedGeminiCodingAccounts.contains { $0.id == legacy.id })
        XCTAssertFalse(fixture.store.hasGeminiCodingSecret(for: gemini))
        XCTAssertEqual(credentialChanges, 0)
        model.linkGeminiCodingAccount(legacy, confirmedSameAccount: true)
        XCTAssertTrue(fixture.store.hasGeminiCodingSecret(for: gemini))
        XCTAssertFalse(fixture.store.unlinkedGeminiCodingAccounts.contains { $0.id == legacy.id })
        XCTAssertEqual(credentialChanges, 1)
        XCTAssertEqual(fixture.store.visibleConfigurations.map(\.id), [gemini.id])
        XCTAssertFalse(AddAccountFlowState.providerOptions.contains(.antigravity))
        var flow = AddAccountFlowState()
        XCTAssertNil(flow.select(.antigravity, configurationStore: fixture.store))
    }

    @MainActor
    private func waitForSignIn(_ model: ProviderSettingsViewModel) async {
        for _ in 0..<200 where model.isSigningInWithGemini { await Task.yield() }
        XCTAssertFalse(model.isSigningInWithGemini)
    }

    private func validResult(
        for account: ProviderAccountConfiguration,
        keys: [String] = ["five-hour", "weekly"],
        reset: Date? = Date(timeIntervalSince1970: 2_000_000_000)
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: account.id, providerID: .gemini, title: "Gemini", subtitle: "Gemini Apps usage",
            bars: keys.map { UsageBar(stableKey: $0, label: $0, used: 1, limit: 100, resetsAt: reset) },
            fetchedAt: Date()
        )
    }

    private func cookie(
        _ name: String, value: String, domain: String = ".google.com", path: String = "/",
        secure: Bool = true, expires: Date? = nil
    ) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return try XCTUnwrap(HTTPCookie(properties: properties))
    }
}

private struct StubValidator: GeminiSessionValidating {
    let result: ProviderUsageResult
    func validate(credential: String, configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult { result }
}

private actor SuspendedValidator: GeminiSessionValidating {
    private let result: ProviderUsageResult
    private let started = TestSignal()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    init(result: ProviderUsageResult) { self.result = result }

    func validate(credential: String, configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        // The detached gate deliberately ignores the caller's cancellation so the
        // test exercises late success, while its own watchdog still bounds the wait.
        try await Task.detached { [self] in
            try await withTestWatchdog(
                timeout: .seconds(5),
                failureMessage: "Gemini validation was not released within five seconds.",
                onTimeout: { Task { await self.finish() } },
                operation: { await self.waitForRelease() }
            )
        }.value
        return result
    }

    func waitUntilStarted() async throws {
        try await withTestWatchdog(
            timeout: .seconds(5),
            failureMessage: "Gemini validation did not start within five seconds.",
            onTimeout: { Task { await self.finish() } },
            operation: { [started] in await started.wait() }
        )
    }

    private func waitForRelease() async {
        guard !isReleased else { return }
        await withCheckedContinuation {
            continuation = $0
            started.signal()
        }
    }

    func finish() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class Fixture {
    let suiteName = "CodexBarIOSTests.Gemini.\(UUID().uuidString)"
    let defaults: UserDefaults
    let secrets = MemorySecretStore()
    let store: ProviderConfigurationStore
    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
    }
    deinit { defaults.removePersistentDomain(forName: suiteName) }
}

private struct GeminiFailingWriteSecretStore: SecretStore {
    func readSecret(account: String) throws -> String? { nil }
    func saveSecret(_ secret: String, account: String) throws { throw GeminiSignInError.validationFailed }
    func deleteSecret(account: String) throws {}
}
