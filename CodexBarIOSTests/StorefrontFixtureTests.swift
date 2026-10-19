import XCTest
@testable import CodexBarIOS

final class StorefrontFixtureTests: XCTestCase {
    @MainActor
    func testStorefrontFreeSceneResolvesOneAccountAndSevenDayHistory() async throws {
        let scene = try XCTUnwrap(AppStoreScreenshotConfiguration.parse(arguments: [
            "CodexBarIOS", "--app-store-screenshots", "--app-store-scene", "free-overview",
        ])).scene
        let fixture = PlanAccessFixture(hasProAccess: scene.hasProAccess)
        let store = ProviderConfigurationStore.appStoreScreenshotDemo(singleAccount: !scene.hasProAccess)
        let results = AppStoreScreenshotFixtures.results(for: store)
        let history = AppStoreScreenshotFixtures.historyStore(for: results, extendedRange: true)
        let refresh = UsageRefreshService(providers: DemoUsageProvider.samples, initialResults: results)
        let coordinator = PlanAccessCoordinator(entitlement: fixture.entitlement, configurationStore: store,
                                               refreshService: refresh, historyStore: history)
        await fixture.entitlement.refresh()
        withExtendedLifetime(coordinator) {
            XCTAssertTrue(fixture.entitlement.isResolved)
            XCTAssertFalse(fixture.entitlement.hasAccess)
            XCTAssertEqual(store.visibleConfigurations.count, 1)
            XCTAssertTrue(store.accountAccess.isResolved)
            XCTAssertFalse(store.accountAccess.hasProAccess)
            XCTAssertEqual(history.accessPolicy, .free)
            XCTAssertFalse(history.accessPolicy.allows(range: .threeMonths))
            XCTAssertLessThanOrEqual(history.historySeries(for: results[0]).points.count, 8)
        }
    }

    @MainActor
    func testStorefrontProSceneResolvesMultipleAccountsAndNinetyDayHistory() async throws {
        let fixture = PlanAccessFixture(hasProAccess: AppStoreScreenshotScene.history.hasProAccess)
        let store = ProviderConfigurationStore.appStoreScreenshotDemo()
        let results = AppStoreScreenshotFixtures.results(for: store)
        let codex = try XCTUnwrap(results.first { $0.providerID == .codex })
        let history = AppStoreScreenshotFixtures.historyStore(for: results, extendedRange: true)
        let refresh = UsageRefreshService(providers: DemoUsageProvider.samples, initialResults: results)
        let coordinator = PlanAccessCoordinator(entitlement: fixture.entitlement, configurationStore: store,
                                               refreshService: refresh, historyStore: history)
        await fixture.entitlement.refresh()
        withExtendedLifetime(coordinator) {
            XCTAssertTrue(fixture.entitlement.isResolved)
            XCTAssertTrue(fixture.entitlement.hasAccess)
            XCTAssertGreaterThan(store.visibleConfigurations.count, 1)
            XCTAssertEqual(history.accessPolicy, .pro)
            XCTAssertTrue(history.accessPolicy.allows(range: .threeMonths))
            XCTAssertEqual(history.historySeries(for: codex).points.count, 90)
        }
    }
}

/// Fixture transports compiled into DEBUG builds must keep replaying the shapes the UI journeys depend on.
final class UITestFixtureTransportTests: XCTestCase {
    private struct Reply {
        let status: Int
        let contentType: String?
        let object: [String: Any]
    }

    private let scenarioKey = "CODEXBAR_UI_TEST_SCENARIO"

    func testSubscriptionBillingReplaysOwnerScopedClaudeAndGrokBodies() async throws {
        let session = UITestSubscriptionBillingProtocol.session()
        defer { session.invalidateAndCancel() }
        let owner = UITestSubscriptionBillingProtocol.claudeOwner
        let organization = UITestSubscriptionBillingProtocol.claudeOrganization

        let profile = try await fetch(session, "https://api.anthropic.com/api/oauth/profile")
        XCTAssertEqual(profile.status, 200)
        XCTAssertEqual(profile.contentType, "application/json")
        XCTAssertEqual((profile.object["account"] as? [String: Any])?["uuid"] as? String, owner)
        let profileOrganization = try XCTUnwrap(profile.object["organization"] as? [String: Any])
        XCTAssertEqual(profileOrganization["uuid"] as? String, organization)
        XCTAssertEqual(profileOrganization["organization_type"] as? String, "claude_max")

        let account = try await fetch(session, "https://claude.ai/api/account", cookie: "sessionKey=synthetic")
        XCTAssertEqual(account.object["uuid"] as? String, owner)
        let membership = try XCTUnwrap((account.object["memberships"] as? [[String: Any]])?.first)
        XCTAssertEqual((membership["organization"] as? [String: Any])?["uuid"] as? String, organization)
        let otherAccount = try await fetch(session, "https://claude.ai/api/account", cookie: "sessionKey=wrong")
        XCTAssertEqual(otherAccount.object["uuid"] as? String, "other-account")

        let details = try await fetch(session, "https://claude.ai/api/organizations/\(organization)/subscription_details")
        XCTAssertEqual(details.status, 200)
        XCTAssertEqual(details.object["status"] as? String, "active")
        XCTAssertTrue(details.object["plan_ending_at"] is NSNull)
        try assertRoughlyThreeDaysAhead(details.object["next_charge_at"])

        let subscriptions = try await fetch(session, "https://grok.com/rest/subscriptions")
        let subscription = try XCTUnwrap((subscriptions.object["subscriptions"] as? [[String: Any]])?.first)
        XCTAssertEqual(subscription["xaiUserId"] as? String, "synthetic-user")
        XCTAssertEqual(subscription["tier"] as? String, "SUBSCRIPTION_TIER_GROK_PRO")
        XCTAssertEqual(subscription["status"] as? String, "SUBSCRIPTION_STATUS_ACTIVE")
        let stripe = try XCTUnwrap(subscription["stripe"] as? [String: Any])
        XCTAssertEqual(stripe["cancelAtPeriodEnd"] as? Bool, false)
        try assertRoughlyThreeDaysAhead(stripe["currentPeriodEnd"])
        let otherSubscriptions = try await fetch(session, "https://grok.com/rest/subscriptions", cookie: "sso=wrong")
        let otherSubscription = try XCTUnwrap((otherSubscriptions.object["subscriptions"] as? [[String: Any]])?.first)
        XCTAssertEqual(otherSubscription["xaiUserId"] as? String, "other-account")
    }

    func testSubscriptionBillingRejectsUnknownPathsAndForeignOrganizations() async throws {
        let session = UITestSubscriptionBillingProtocol.session()
        defer { session.invalidateAndCancel() }
        for address in [
            "https://claude.ai/api/unknown",
            "https://claude.ai/api/organizations/33333333-3333-4333-8333-333333333333/subscription_details",
        ] {
            do {
                _ = try await session.data(from: try XCTUnwrap(URL(string: address)))
                XCTFail("Expected \(address) to fail")
            } catch let error as URLError {
                XCTAssertEqual(error.code, .unsupportedURL, address)
            }
        }
    }

    func testCursorBillingReplyRoutesEveryProbeEndpoint() throws {
        let usage = try object(cursorReply("/aiserver.v1.DashboardService/GetCurrentPeriodUsage"), status: 200)
        XCTAssertEqual((usage["planUsage"] as? [String: Any])?["autoPercentUsed"] as? Int, 12)
        XCTAssertEqual((usage["spendLimitUsage"] as? [String: Any])?["individualLimit"] as? Int, 2000)
        let sand = try object(cursorReply("/aiserver.v1.DashboardService/GetSandUsageStatus"), status: 200)
        XCTAssertEqual(sand["hasNonZeroIncludedLimit"] as? Bool, true)
        XCTAssertEqual(sand["usagePercent"] as? Int, 12)
        for path in ["/auth/full_stripe_profile", "/api/auth/stripe"] {
            let profile = try object(cursorReply(path), status: 200)
            XCTAssertEqual(profile["membershipType"] as? String, "pro")
            XCTAssertEqual(profile["isYearlyPlan"] as? Bool, false)
        }
        let annualProfile = try object(cursorReply("/api/auth/stripe", scenario: "cursor-annual"), status: 200)
        XCTAssertEqual(annualProfile["isYearlyPlan"] as? Bool, true)
        XCTAssertEqual(try object(cursorReply("/api/auth/me"), status: 200)["sub"] as? String, "synthetic-owner")
        let portal = cursorReply("/api/stripeSession")
        XCTAssertEqual(portal.0, 200)
        XCTAssertEqual(portal.1, #""https://billing.stripe.com/p/session/synthetic""#)
        let shell = cursorReply("/p/session/synthetic")
        XCTAssertEqual(shell.0, 200)
        XCTAssertEqual(shell.1, UITestCursorBillingFixture.shell)
        XCTAssertTrue(shell.1.contains("synthetic_scoped_portal_key"))
        let portalSession = try object(cursorReply("/v1/billing_portal/sessions/bps_synthetic"), status: 200)
        XCTAssertEqual(portalSession["customer"] as? String, "cus_synthetic")
        XCTAssertEqual(portalSession["livemode"] as? Bool, true)
        let missing = cursorReply("/v1/unknown")
        XCTAssertEqual(missing.0, 404)
        XCTAssertEqual(missing.1, "{}")
    }

    func testCursorBillingReplyShapesSubscriptionsPerScenario() throws {
        let now = Date().timeIntervalSince1970
        let monthly = try cursorSubscription(scenario: "cursor-monthly")
        XCTAssertEqual(monthly.interval, "month")
        XCTAssertFalse(monthly.canceled)
        XCTAssertEqual(monthly.end, now + 259_200, accuracy: 60)
        let annual = try cursorSubscription(scenario: "cursor-annual")
        XCTAssertEqual(annual.interval, "year")
        XCTAssertEqual(annual.end, now + 31_536_000, accuracy: 60)
        let past = try cursorSubscription(scenario: "cursor-past")
        XCTAssertLessThan(past.end, Date().timeIntervalSince1970)
        XCTAssertEqual(past.end, now - 60, accuracy: 60)
        XCTAssertTrue(try cursorSubscription(scenario: "cursor-canceled").canceled)

        let unknown = cursorReply("/api/stripeSession", scenario: "cursor-unknown")
        XCTAssertEqual(unknown.0, 403)
        XCTAssertEqual(unknown.1, "{}")
    }

    func testCursorBillingProtocolForwardsScenarioReplies() async throws {
        let session = UITestCursorBillingProtocol.session(scenario: "cursor-unknown")
        defer { session.invalidateAndCancel() }
        let portalURL = try XCTUnwrap(URL(string: "https://cursor.com/api/stripeSession"))
        let (portalData, portalResponse) = try await session.data(from: portalURL)
        XCTAssertEqual((portalResponse as? HTTPURLResponse)?.statusCode, 403)
        XCTAssertEqual(String(data: portalData, encoding: .utf8), "{}")
        let meURL = try XCTUnwrap(URL(string: "https://cursor.com/api/auth/me"))
        let (meData, meResponse) = try await session.data(from: meURL)
        XCTAssertEqual((meResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: meData, encoding: .utf8), #"{"sub":"synthetic-owner","id":123}"#)
    }

    func testOpenCodeRenewalReplayReportsRenewingGoAndZenBalance() async throws {
        let result = try await openCodeRenewal(scenario: "opencode-renewal-renewing")
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 25, accuracy: 0.000_1)
        XCTAssertEqual(result.bars.count, 3)
        let renewal = try XCTUnwrap(result.subscriptionRenewal)
        XCTAssertEqual(renewal.state, .renewing)
        XCTAssertEqual(renewal.accountID, "ui-opencode-renewal")
        XCTAssertEqual(try XCTUnwrap(renewal.date).timeIntervalSinceNow, 259_200, accuracy: 60)
    }

    func testOpenCodeRenewalReplayReflectsBillingScenarios() async throws {
        let canceled = try await openCodeRenewal(scenario: "opencode-renewal-canceled")
        XCTAssertEqual(canceled.subscriptionRenewal?.state, .nonRenewing)
        XCTAssertEqual(canceled.bars.count, 3)

        let payment = try await openCodeRenewal(scenario: "opencode-renewal-payment")
        XCTAssertNil(payment.subscriptionRenewal)
        XCTAssertEqual(payment.bars.count, 3)
        XCTAssertEqual(try XCTUnwrap(payment.creditsRemaining), 25, accuracy: 0.000_1)

        let mismatch = try await openCodeRenewal(scenario: "opencode-renewal-mismatch")
        XCTAssertNil(mismatch.subscriptionRenewal)
        XCTAssertTrue(mismatch.bars.isEmpty)
        XCTAssertTrue(mismatch.usageMessages.contains("Another workspace member owns the OpenCode Go subscription."))

        let balanceFailure = try await openCodeRenewal(scenario: "opencode-renewal-balance-failure")
        XCTAssertNil(balanceFailure.creditsRemaining)
        XCTAssertEqual(balanceFailure.bars.count, 3)
        XCTAssertEqual(balanceFailure.subscriptionRenewal?.state, .renewing)
        XCTAssertTrue(balanceFailure.usageMessages.contains { $0.hasPrefix("Zen balance unavailable:") })
    }

    func testOpenCodeRenewalReplayRejectsUnexpectedAuthorization() async throws {
        let result = try await openCodeRenewal(scenario: "opencode-renewal-renewing", accessToken: "other-access")
        XCTAssertNotNil(result.failureMessage)
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertNil(result.subscriptionRenewal)
    }

    private func fetch(_ session: URLSession, _ address: String, cookie: String? = nil) async throws -> Reply {
        var request = URLRequest(url: try XCTUnwrap(URL(string: address)))
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Reply(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"), object: object)
    }

    private func assertRoughlyThreeDaysAhead(_ value: Any?, file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try XCTUnwrap(value as? String, file: file, line: line)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: text), file: file, line: line)
        XCTAssertEqual(date.timeIntervalSinceNow, 259_200, accuracy: 60, file: file, line: line)
    }

    private func cursorReply(_ path: String, scenario: String = "") -> (Int, String) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "cursor.com"
        components.path = path
        return UITestCursorBillingFixture.reply(URLRequest(url: components.url ?? URL(fileURLWithPath: path)), scenario: scenario)
    }

    private func object(_ reply: (Int, String), status: Int, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        XCTAssertEqual(reply.0, status, file: file, line: line)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(reply.1.utf8)) as? [String: Any], file: file, line: line)
    }

    private func cursorSubscription(scenario: String) throws -> (end: Double, canceled: Bool, interval: String?) {
        let list = try object(cursorReply("/v1/billing_portal/sessions/bps_synthetic/subscriptions", scenario: scenario), status: 200)
        let subscription = try XCTUnwrap((list["data"] as? [[String: Any]])?.first)
        let end = try XCTUnwrap(subscription["current_period_end"] as? Double)
        let item = try XCTUnwrap((subscription["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["current_period_end"] as? Double, end)
        let recurring = (item["price_details"] as? [String: Any])?["recurring"] as? [String: Any]
        return (end, try XCTUnwrap(subscription["cancel_at_period_end"] as? Bool), recurring?["interval"] as? String)
    }

    /// The replay reads its scenario from the process environment, as the UI-test launch does.
    private func openCodeRenewal(scenario: String, accessToken: String = "synthetic-access") async throws -> ProviderUsageResult {
        var account = ProviderAccountConfiguration(id: "ui-opencode-renewal", providerID: .openCodeZen,
                                                   accountLabel: "OpenCode Go + Zen", authMethod: .browserSession)
        account.openCodeWorkspaceId = "org_synthetic"
        let credential = OpenCodeConsoleCredential(kind: "opencode-console-v1", accessToken: accessToken,
                                                  refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3600),
                                                  workspaceID: "org_synthetic", userID: "user_synthetic")
        let secrets = MemorySecretStore()
        try secrets.saveSecret(try credential.encoded(), account: ProviderConfigurationStore.keychainAccount(for: account))
        let previous = ProcessInfo.processInfo.environment[scenarioKey]
        setenv(scenarioKey, scenario, 1)
        defer {
            if let previous { setenv(scenarioKey, previous, 1) } else { unsetenv(scenarioKey) }
        }
        XCTAssertEqual(ProcessInfo.processInfo.environment[scenarioKey], scenario)
        return try await UITestOpenCodeRenewalProvider(secretStore: secrets).fetchUsage(for: account)
    }
}

@MainActor
final class ProCommerceFixtureSelectionTests: XCTestCase {
    func testNonCommerceScenariosDoNotCreateFixture() {
        for scenario in [nil, "", "plan-pills", "opencode-renewal-renewing", "Commerce-trial"] as [String?] {
            XCTAssertNil(ProCommerceFixture(scenario: scenario, runID: UUID(), environment: [:]), String(describing: scenario))
        }
    }

    func testEntryOriginFollowsLaunchEnvironment() throws {
        let cases: [(String?, ProPresentationOrigin?)] = [("settings", .settings), ("limit", .limit), ("dashboard", nil), (nil, nil)]
        for (value, expected) in cases {
            let environment = value.map { ["CODEXBAR_COMMERCE_ENTRY": $0] } ?? [:]
            let fixture = try XCTUnwrap(ProCommerceFixture(scenario: "commerce-free-trial", runID: UUID(), environment: environment))
            XCTAssertEqual(fixture.entry, expected, String(describing: value))
        }
    }

    func testSyntheticScenariosUseFixtureEvidence() async throws {
        let free = try XCTUnwrap(ProCommerceFixture(scenario: "commerce-free-trial", runID: UUID(), environment: [:]))
        XCTAssertTrue(free.isSynthetic)
        XCTAssertEqual(free.scenario, "commerce-free-trial")
        XCTAssertEqual(free.entitlement.value.reason, .none)
        await free.entitlement.refresh()
        XCTAssertTrue(free.entitlement.isResolved)
        XCTAssertFalse(free.entitlement.hasAccess)

        let lifetime = try XCTUnwrap(ProCommerceFixture(scenario: "commerce-lifetime", runID: UUID(), environment: [:]))
        XCTAssertTrue(lifetime.isSynthetic)
        await lifetime.entitlement.refresh()
        XCTAssertTrue(lifetime.entitlement.hasAccess)
        XCTAssertEqual(lifetime.entitlement.value.reason, .lifetime)

        let storage = try XCTUnwrap(ProCommerceFixture(scenario: "commerce-storage-error", runID: UUID(), environment: [:]))
        XCTAssertTrue(storage.isSynthetic)
        await storage.entitlement.refresh()
        XCTAssertTrue(storage.entitlement.isResolved)
        XCTAssertFalse(storage.entitlement.hasAccess)
    }

    func testCachedScenarioStartsFromSeededYearlyEntitlement() throws {
        let cached = try XCTUnwrap(ProCommerceFixture(scenario: "commerce-cached", runID: UUID(), environment: [:]))
        XCTAssertTrue(cached.isSynthetic)
        XCTAssertEqual(cached.entitlement.value.reason, .yearly)
        XCTAssertEqual(cached.entitlement.value.proAccessEndsAt, ProCommerceFixture.instant.addingTimeInterval(10 * 86_400))
        XCTAssertTrue(cached.entitlement.hasAccess)
    }

    func testNativeStoreKitScenarioUsesIsolatedRunCache() throws {
        let runID = UUID()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-commerce-\(runID.uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("marker")

        let native = try XCTUnwrap(ProCommerceFixture(scenario: "commerce-native-storekit", runID: runID, environment: [:]))
        XCTAssertFalse(native.isSynthetic)
        XCTAssertEqual(native.scenario, "commerce-native-storekit")
        XCTAssertEqual(native.entitlement.value.reason, .none)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        try Data("kept".utf8).write(to: marker)
        _ = try XCTUnwrap(ProCommerceFixture(scenario: "commerce-native-storekit", runID: runID, environment: [:]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        _ = try XCTUnwrap(ProCommerceFixture(scenario: "commerce-native-storekit", runID: runID,
                                             environment: ["CODEXBAR_UI_TEST_RESET": "1"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }
}
