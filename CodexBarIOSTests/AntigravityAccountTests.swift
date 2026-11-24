import XCTest
@testable import CodexBarIOS

/// Account handling around the experimental Antigravity sign-in (#601). Nothing here opens a Google page.
@MainActor
final class AntigravityAccountTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        suite = "AntigravityAccountTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func store(secrets: SecretStore, hasPro: Bool = true) -> ProviderConfigurationStore {
        ProviderConfigurationStore(
            initialPlanAccess: AccountPlanAccess(hasProAccess: hasPro, isResolved: true), defaults: defaults,
            secretStore: secrets, widgetSnapshotDefaults: nil,
            antigravityWebsiteData: AntigravityFixtureWebsiteData(stores: [])
        )
    }

    private func signIn(storeID: UUID = UUID()) -> AntigravitySignInResult {
        let capture = AntigravityPageCapture(
            quotaBody: AntigravityFixtures.screenshotQuotaBody, profileBody: AntigravityFixtures.profileBody,
            pagePath: "/remote/settings"
        )
        return AntigravitySignInResult(
            marker: AntigravityWebSessionMarker(websiteDataStoreID: storeID, pagePath: capture.pagePath), capture: capture,
            readAt: AntigravityFixtures.now
        )
    }

    // MARK: Add Account

    func testAccountIsCreatedAndConfiguredOnlyByAFinishedSignIn() async throws {
        let secrets = AntigravityFixtureSecretStore()
        let store = store(secrets: secrets)
        var flow = AddAccountFlowState()
        XCTAssertTrue(flow.startsWithSignIn(.antigravityWeb))
        XCTAssertFalse(flow.startsWithSignIn(.claude))
        XCTAssertTrue(flow.canBeginSignIn(for: .antigravityWeb, configurationStore: store))
        XCTAssertFalse(flow.canBeginSignIn(for: .claude, configurationStore: store))
        XCTAssertTrue(store.configurations.isEmpty, "beginning sign-in creates nothing")

        let result = signIn()
        AntigravityPendingSignIns.begin(result.marker.websiteDataStoreID)
        let account = try await AntigravityAccountConnector.addAccount(for: result, flowState: &flow, in: store).get()

        XCTAssertEqual(store.configurations.map(\.id), [account.id])
        XCTAssertEqual(account.providerID, .antigravityWeb)
        XCTAssertTrue(store.isConfigured(account))
        XCTAssertEqual(flow.accountID, account.id)
        XCTAssertFalse(flow.startsWithSignIn(.antigravityWeb), "the flow now shows that account's settings")
        XCTAssertFalse(flow.canBeginSignIn(for: .antigravityWeb, configurationStore: store))
        XCTAssertEqual(store.antigravityWebSessionMarkers(), [result.marker])
        XCTAssertFalse(AntigravityPendingSignIns.storeIDs.contains(result.marker.websiteDataStoreID))

        // The first refresh uses the reading sign-in watched and opens no page.
        let reader = AntigravityFixtureReader([.failure(.pageFailed)])
        let usage = try await AntigravityUsageProvider(secretStore: secrets, reader: reader, now: { AntigravityFixtures.now })
            .fetchUsage(for: account)
        XCTAssertEqual(usage.bars.map(\.used), [3, 9, 0, 0])
        let reads = await reader.markers
        XCTAssertTrue(reads.isEmpty)
        await AntigravityReadCache.shared.forget(storeID: result.marker.websiteDataStoreID)
    }

    func testSignInThatCannotBeSavedLeavesNoAccount() async {
        let store = store(secrets: RefusingSecretStore())
        var flow = AddAccountFlowState()
        let result = signIn()
        AntigravityPendingSignIns.begin(result.marker.websiteDataStoreID)

        let outcome = await AntigravityAccountConnector.addAccount(for: result, flowState: &flow, in: store)

        guard case let .failure(error) = outcome else { return XCTFail("a refused save must not report an account") }
        XCTAssertFalse(error.message.isEmpty)
        XCTAssertTrue(store.configurations.isEmpty)
        XCTAssertNil(flow.accountID)
        XCTAssertFalse(AntigravityPendingSignIns.storeIDs.contains(result.marker.websiteDataStoreID))
    }

    func testFreePlanAtItsLimitOpensProInsteadOfSignIn() {
        let secrets = AntigravityFixtureSecretStore()
        let store = store(secrets: secrets, hasPro: false)
        XCTAssertNotNil(store.addAccount(for: .openRouter))
        XCTAssertFalse(AddAccountFlowState().canBeginSignIn(for: .antigravityWeb, configurationStore: store))
        XCTAssertTrue(store.requestedProPresentation)
        XCTAssertEqual(AntigravityAccountError(nil).message, AntigravitySignInError.storageFailed.localizedDescription)
    }

    // MARK: Sign in again

    func testFailedOrCanceledSignInAgainKeepsTheSavedSignIn() async throws {
        let secrets = AntigravityFixtureSecretStore()
        let store = store(secrets: secrets)
        var flow = AddAccountFlowState()
        let first = signIn()
        let account = try await AntigravityAccountConnector.addAccount(for: first, flowState: &flow, in: store).get()

        let canceled = await AntigravityAccountConnector.reconnect(.failure(.canceled), configuration: account, in: store)
        XCTAssertEqual(canceled?.message, "Google sign-in canceled. No account was changed.")
        XCTAssertEqual(store.antigravityWebSessionMarkers(), [first.marker])

        let second = signIn()
        let replaced = await AntigravityAccountConnector.reconnect(.success(second), configuration: account, in: store)
        XCTAssertNil(replaced)
        XCTAssertEqual(store.antigravityWebSessionMarkers(), [second.marker])
        XCTAssertEqual(Result<AntigravitySignInResult, AntigravitySignInError>.failure(.browserFailed).failureMessage,
                       AntigravitySignInError.browserFailed.localizedDescription)
        XCTAssertNil(Result<AntigravitySignInResult, AntigravitySignInError>.success(second).failureMessage)
        for id in [first, second].map(\.marker.websiteDataStoreID) { await AntigravityReadCache.shared.forget(storeID: id) }
    }

    // MARK: Sign-in session

    func testNothingStartsBeforeTheNoticeIsAcceptedAndCancelEndsOnce() {
        var outcomes: [Result<AntigravitySignInResult, AntigravitySignInError>] = []
        let session = AntigravitySignInSession(isSynthetic: true) { outcomes.append($0) }
        XCTAssertEqual(session.stage, .notice)
        XCTAssertNil(session.webView)
        XCTAssertTrue(AntigravityPendingSignIns.storeIDs.contains(session.storeID))
        session.completeSynthetic(with: UITestAntigravityFixture.signInCapture)
        XCTAssertTrue(outcomes.isEmpty, "usage reported before the notice is accepted is not a sign-in")

        session.cancel()
        session.cancel()
        session.acceptNotice()
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.failureMessage, AntigravitySignInError.canceled.localizedDescription)
        XCTAssertEqual(session.stage, .notice)
        XCTAssertFalse(AntigravityPendingSignIns.storeIDs.contains(session.storeID), "a canceled sign-in keeps no website data")
    }

    func testSyntheticSignInReportsTheMarkerForItsOwnWebsiteDataStore() throws {
        var outcomes: [Result<AntigravitySignInResult, AntigravitySignInError>] = []
        let session = AntigravitySignInSession(isSynthetic: true) { outcomes.append($0) }
        session.acceptNotice()
        XCTAssertEqual(session.stage, .browser)
        XCTAssertNil(session.webView, "a synthetic sign-in never opens a page")
        session.completeSynthetic(with: UITestAntigravityFixture.signInCapture)

        let result = try XCTUnwrap(outcomes.first).get()
        XCTAssertEqual(result.marker.websiteDataStoreID, session.storeID)
        XCTAssertEqual(result.marker.pagePath, "/remote/settings")
        XCTAssertEqual(result.capture.quotaBody, UITestAntigravityFixture.signInCapture.quotaBody)
        AntigravitySignInSession.discard(storeID: session.storeID)

        let failing = AntigravitySignInSession(isSynthetic: true) { outcomes.append($0) }
        failing.acceptNotice()
        failing.failSynthetic()
        XCTAssertEqual(outcomes.last?.failureMessage, AntigravitySignInError.browserFailed.localizedDescription)
    }

    func testPageResponsesFinishSignInOnceUsageIsReadable() async throws {
        var outcomes: [Result<AntigravitySignInResult, AntigravitySignInError>] = []
        let session = AntigravitySignInSession(isSynthetic: true) { outcomes.append($0) }
        session.acceptNotice()
        session.receive(.quota("<html>not usage</html>"), path: "/remote/settings")
        XCTAssertEqual(session.message, AntigravityReadError.unreadableResponse.localizedDescription)
        XCTAssertTrue(outcomes.isEmpty, "an unreadable response is not a sign-in")

        session.receive(.quota(AntigravityFixtures.screenshotQuotaBody), path: "/u/1/remote/settings")
        session.receive(.profile(AntigravityFixtures.profileBody), path: "/u/1/remote/settings")
        for _ in 0..<40 where outcomes.isEmpty { try await Task.sleep(for: .milliseconds(100)) }

        let result = try XCTUnwrap(outcomes.first).get()
        XCTAssertEqual(result.marker.pagePath, "/u/1/remote/settings", "later reads open the page that reported usage")
        XCTAssertEqual(result.capture.profileBody, AntigravityFixtures.profileBody)
        session.receive(.quota(AntigravityFixtures.screenshotQuotaBody), path: "/remote/settings")
        XCTAssertEqual(outcomes.count, 1, "a finished sign-in ignores later responses")
        AntigravitySignInSession.discard(storeID: session.storeID)
    }

    func testSignedInCustomerGetsUsageFromTheWidePageWithoutOpeningSettingsByHand() async throws {
        // On a phone-width page Google's Settings opens as a list and never asks for quota. The plan response says
        // the customer is signed in; the wide hidden page then reads usage with the same website data store.
        let capture = AntigravityPageCapture(quotaBody: AntigravityFixtures.liveQuotaBody, pagePath: "/u/1/remote")
        let reader = AntigravityFixtureReader([.failure(.noUsageReported), .success(capture)])
        var outcomes: [Result<AntigravitySignInResult, AntigravitySignInError>] = []
        let session = AntigravitySignInSession(isSynthetic: true, reader: reader) { outcomes.append($0) }
        session.acceptNotice()

        // The customer chose a second Google account, which Google's app serves under `/u/1`.
        session.receive(.profile(AntigravityFixtures.profileBody), path: "/u/1/remote")
        for _ in 0..<20 where await reader.markers.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(outcomes.isEmpty, "a wide page that reported nothing is not a sign-in")

        session.receive(.profile(AntigravityFixtures.profileBody), path: "/u/1/remote")
        for _ in 0..<40 where outcomes.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        let result = try XCTUnwrap(outcomes.first).get()
        XCTAssertEqual(result.marker.websiteDataStoreID, session.storeID)
        XCTAssertEqual(result.marker.pagePath, "/u/1/remote", "later refreshes read the same account")
        XCTAssertEqual(result.capture.quotaBody, AntigravityFixtures.liveQuotaBody)
        XCTAssertEqual(result.capture.profileBody, AntigravityFixtures.profileBody, "the plan the visible page reported is kept")
        let reads = await reader.markers
        XCTAssertEqual(reads.map(\.websiteDataStoreID), [session.storeID, session.storeID], "it reads with this sign-in's own store")
        XCTAssertEqual(reads.map(\.pagePath), ["/u/1/remote", "/u/1/remote"], "and the account the visible page is showing")
        XCTAssertEqual(
            AntigravityPagePolicy.pageURLs(pagePath: reads.first?.pagePath).first?.absoluteString,
            "https://antigravity.google.com/u/1/remote/settings?settingsScreen=Models"
        )
        AntigravitySignInSession.discard(storeID: session.storeID)
    }

    func testCanceledSignInIgnoresAWidePageThatAnswersLate() async throws {
        let reader = AntigravityFixtureReader([.success(AntigravityPageCapture(quotaBody: AntigravityFixtures.liveQuotaBody))])
        var outcomes: [Result<AntigravitySignInResult, AntigravitySignInError>] = []
        let session = AntigravitySignInSession(isSynthetic: true, reader: reader) { outcomes.append($0) }
        session.acceptNotice()
        session.receive(.profile(AntigravityFixtures.profileBody), path: "/remote")
        session.cancel()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.failureMessage, AntigravitySignInError.canceled.localizedDescription)
    }

    // MARK: Simulator fixtures

    func testStateFixturesGoThroughTheRealParserAndProvider() async throws {
        let secrets = AntigravityFixtureSecretStore()
        let store = store(secrets: secrets)
        XCTAssertNil(UITestAntigravityFixture.results(in: store, scenario: "empty"))
        UITestAntigravityFixture.seed(in: store, scenario: "empty")
        XCTAssertTrue(store.configurations.isEmpty)
        XCTAssertFalse(UITestAntigravityFixture.isScenario("empty"))

        UITestAntigravityFixture.seed(in: store, scenario: UITestAntigravityFixture.statesScenario)
        let results = try XCTUnwrap(UITestAntigravityFixture.results(in: store, scenario: UITestAntigravityFixture.statesScenario))
        XCTAssertEqual(results.count, 7)
        func result(_ state: String) throws -> ProviderUsageResult {
            try XCTUnwrap(results.first { $0.accountID == "ui-antigravity-\(state)" })
        }
        XCTAssertEqual(try result("measured").bars.map(\.used), [3, 9, 0, 0])
        XCTAssertEqual(try result("measured").bars.map { $0.resetsAt != nil }, [true, true, false, false],
                       "untouched pools carry a reset time in the fixture, as in Google's response, and show none")
        XCTAssertEqual(try result("weekly-limit").unavailableUsageMetrics["antigravityWeb.gemini-5h"], "Weekly limit reached")
        XCTAssertEqual(try result("partial").bars.map(\.stableKey), ["gemini-weekly", "3p-weekly"])
        XCTAssertEqual(try result("extra-pool").bars.last?.stableKey, "extra-gemini-argon-wtu-weekly")
        XCTAssertTrue(try result("needs-computer").bars.isEmpty)
        XCTAssertEqual(try result("sign-in-expired").recoveryAction, .reauthenticate)
        let stale = try result("stale")
        XCTAssertEqual(stale.bars.count, 4)
        XCTAssertFalse(stale.hasFreshBars, "a stale reading raises no alerts and adds no history")
        XCTAssertFalse(stale.hasCurrentBars)

        let service = UsageRefreshService(providers: [], initialResults: results)
        UITestAntigravityFixture.presentFailures(of: results, in: service, scenario: UITestAntigravityFixture.statesScenario)
        XCTAssertEqual(
            Set(service.refreshErrorsByAccountID.keys),
            ["ui-antigravity-needs-computer", "ui-antigravity-sign-in-expired", "ui-antigravity-stale"]
        )

        let kept = UITestAntigravityFixture.providers(overriding: [DemoUsageProvider.samples[0]], scenario: "empty", secretStore: secrets)
        XCTAssertEqual(kept.map(\.providerID), [DemoUsageProvider.samples[0].providerID])
        let providers = UITestAntigravityFixture.providers(
            overriding: [], scenario: UITestAntigravityFixture.statesScenario, secretStore: secrets
        )
        XCTAssertEqual(providers.map(\.providerID), [.antigravityWeb])
        for (state, expected) in [("extra-pool", 5), ("needs-computer", 0), ("sign-in-expired", 0), ("stale", 0)] {
            let account = try XCTUnwrap(store.configuration(accountID: "ui-antigravity-\(state)"))
            let refreshed = try await providers[0].fetchUsage(for: account)
            XCTAssertEqual(refreshed.bars.count, expected, state)
        }
        for marker in store.antigravityWebSessionMarkers() {
            await AntigravityReadCache.shared.forget(storeID: marker.websiteDataStoreID)
        }
    }

    func testAddFixtureShowsTheSignedInAccountAfterARelaunch() async throws {
        let secrets = AntigravityFixtureSecretStore()
        let store = store(secrets: secrets)
        let scenario = UITestAntigravityFixture.addScenario
        XCTAssertEqual(UITestAntigravityFixture.results(in: store, scenario: scenario)?.count, 0)
        var flow = AddAccountFlowState()
        let result = signIn()
        let account = try await AntigravityAccountConnector.addAccount(for: result, flowState: &flow, in: store).get()
        XCTAssertEqual(UITestAntigravityFixture.results(in: store, scenario: scenario)?.map(\.accountID), [account.id])

        // An account the fixture doesn't know reads the synthetic sign-in's page.
        await AntigravityReadCache.shared.forget(storeID: result.marker.websiteDataStoreID)
        let provider = UITestAntigravityFixture.providers(overriding: [], scenario: scenario, secretStore: secrets)[0]
        let refreshed = try await provider.fetchUsage(for: account)
        XCTAssertEqual(refreshed.bars.count, 4)
        await AntigravityReadCache.shared.forget(storeID: result.marker.websiteDataStoreID)
    }

    func testDevelopmentDiagnosticsRecordPlacesAndOutcomesOnly() throws {
        let caches = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let directory = caches.appendingPathComponent("AntigravityGate", isDirectory: true)
        let marker = "test-\(UUID().uuidString)"
        AntigravityGateDiagnostics.record(marker)
        AntigravityGateDiagnostics.record("\(marker)-second")
        AntigravityGateDiagnostics.recordQuotaResponse("[\"\(marker)\"]")

        let log = try String(contentsOf: directory.appendingPathComponent("events.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("\(marker)\n"))
        XCTAssertTrue(log.contains("\(marker)-second\n"), "a second event is appended, not written over the first")
        let response = try String(contentsOf: directory.appendingPathComponent("quota-response.json"), encoding: .utf8)
        XCTAssertEqual(response, "[\"\(marker)\"]")
        let url = URL(string: "https://accounts.google.com/v3/signin/identifier?Email=person@example.com")
        XCTAssertEqual(AntigravityGateDiagnostics.describe(url), "accounts.google.com/v3/signin/identifier")
        XCTAssertEqual(AntigravityGateDiagnostics.describe(nil), "none")
    }
}

private struct RefusingSecretStore: SecretStore {
    func readSecret(account: String) throws -> String? { nil }

    func saveSecret(_ secret: String, account: String) throws {
        throw KeychainError.invalidSecretData
    }

    func deleteSecret(account: String) throws {}
}
