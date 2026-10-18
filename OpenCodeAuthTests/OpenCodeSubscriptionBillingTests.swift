import Foundation
import XCTest
@testable import CodexBarIOS

final class OpenCodeSubscriptionBillingTests: XCTestCase, @unchecked Sendable {
    private let now = ISO8601DateFormatter().date(from: "2026-10-10T00:00:00Z")!

    func testVerifiedProductsDowngradeAndCancellationPrecedence() throws {
        for product in ["go", "go-plus"] {
            let result = parse(try fixture(["product": product]))
            XCTAssertEqual(result?.state, .renewing)
            XCTAssertEqual(result?.date, ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
            XCTAssertEqual(result?.accountID, "selected")
        }
        let canceled = parse(try fixture(["cancelAtPeriodEnd": true, "renewalPending": true,
                                         "renewalStopReason": "cancelled_by_user", "renewalRetryAt": "garbage",
        ],
                                        access: ["cancelAtPeriodEnd": true]))
        XCTAssertEqual(canceled?.state, .nonRenewing)
        XCTAssertNil(canceled?.compactLabel(at: now))
        XCTAssertEqual(canceled?.information(at: now)?.items.first?.label, "Does not renew")
    }

    func testUnknownPaymentAndUnsupportedStatesFailClosed() throws {
        let updates: [[String: Any]] = [
            ["subscriberUserId": "another"], ["product": "apple"], ["renewalProduct": "unknown"],
            ["product": "free"], ["product": "zen"], ["cancelAtPeriodEnd": NSNull()], ["cancelAtPeriodEnd": 0],
            ["cancelAtPeriodEnd": "false"], ["renewalPending": true], ["renewalPending": 0],
            ["renewalPending": NSNull()], ["resumability": NSNull()], ["resumability": "unknown"],
            ["resumability": "resumable"], ["resumability": "needs-payment-method"], ["resumability": "access-ended"],
            ["renewalStopReason": "failed"], ["renewalAuthorizationRequired": true], ["renewalAuthorizationRequired": 0],
            ["renewalRetryAt": "2026-10-11T00:00:00Z"], ["renewalPaymentAttemptId": "synthetic"], ["access": NSNull()],
        ]
        for update in updates { XCTAssertNil(parse(try fixture(update)), "\(update)") }
        for raw in ["null", "[]", "[{},{}]", "{}", "not JSON"] { XCTAssertNil(parse(Data(raw.utf8))) }
        for key in ["cancelAtPeriodEnd", "resumability", "renewalPending"] {
            var root = try object()
            root.removeValue(forKey: key)
            XCTAssertNil(parse(try JSONSerialization.data(withJSONObject: root)), key)
        }
    }

    func testIntervalsAndExplicitAccessCancellationAreRequired() throws {
        for date in [NSNull(), "garbage", "2026-11-01", "2026-11-01T00:00:00", "2026-09-01T00:00:00Z",
                     "2026-02-30T00:00:00Z", "2026-11-01T25:00:00Z",
        ] as [Any] {
            XCTAssertNil(parse(try fixture(access: ["endsAt": date])), "\(date)")
        }
        for date in [NSNull(), "garbage", "2026-12-01T00:00:00Z"] as [Any] {
            XCTAssertNil(parse(try fixture(access: ["startsAt": date])))
        }
        for cancel in [NSNull(), 0, "false", true] as [Any] {
            XCTAssertNil(parse(try fixture(access: ["cancelAtPeriodEnd": cancel])))
        }
        XCTAssertNotNil(parse(try fixture(access: ["endsAt": "2026-11-01T02:00:00.123+02:00"])))
        var different = configuration()
        different.openCodeWorkspaceId = "org_other"
        XCTAssertNil(OpenCodeSubscriptionBilling.observation(try fixture(), credential: credential(), configuration: different, at: now))
    }

    func testProductionReadsBindIdentityAndPreserveUsageOnOptionalFailures() async throws {
        for scenario in [
            "renewing", "canceled", "pending", "denied", "owner-before", "workspace-after",
            "owner-after", "denied-after", "read-failure", "replaced", "removed",
        ] {
            let config = configuration()
            let credentials = credential()
            let secrets = OpenCodeTestSecrets()
            let key = ProviderConfigurationStore.keychainAccount(for: config)
            try secrets.saveSecret(credentials.encoded(), account: key)
            let data = try fixture(scenario == "pending" ? ["renewalPending": true]
                : scenario == "canceled" ? ["cancelAtPeriodEnd": true] : [:],
                access: scenario == "canceled" ? ["cancelAtPeriodEnd": true] : [:])
            BillingReplay.state.reset { request, count in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertNil(request.httpBody)
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
                XCTAssertFalse(request.httpShouldHandleCookies)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-access")
                let path = request.url!.path
                XCTAssertTrue(["/console/auth/session", "/console/api/go/status", "/console/api/billing/status"].contains(path))
                if path == "/console/auth/session" {
                    XCTAssertEqual(request.timeoutInterval, 3)
                    XCTAssertNil(request.value(forHTTPHeaderField: "x-org-id"))
                    let user = scenario == "owner-before" || scenario == "owner-after" && count == 2 ? "other" : "user_synthetic"
                    let workspace = scenario == "workspace-after" && count == 2 ? "org_other" : "org_synthetic"
                    if scenario == "replaced" && count == 2 { try? secrets.saveSecret("replacement", account: key) }
                    if scenario == "removed" && count == 2 { try? secrets.deleteSecret(account: key) }
                    if scenario == "read-failure" && count == 2 { secrets.setReadFailure(true) }
                    return (scenario == "denied" || scenario == "denied-after" && count == 2 ? 403 : 200,
                            Data("{\"user\":{\"id\":\"\(user)\"},\"org_id\":\"\(workspace)\",\"expires\":\"metadata\"}".utf8))
                }
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-org-id"), "org_synthetic")
                return (200, path.contains("/billing/") ? Data(#"{"balanceMicroCents":"2500000000"}"#.utf8) : data)
            }
            let result = await OpenCodeConsoleUsageProvider(secretStore: secrets, makeSession: Self.session)
                .fetchUsage(credential: credentials, configuration: config)
            XCTAssertNil(result.failureMessage, scenario)
            XCTAssertEqual(result.creditsRemaining, 25, scenario)
            XCTAssertEqual(result.bars.count, 3, scenario)
            XCTAssertEqual(result.subscriptionRenewal?.state, scenario == "renewing" ? .renewing : scenario == "canceled" ? .nonRenewing : nil, scenario)
            XCTAssertEqual(BillingReplay.state.requests.filter { $0.url?.path == "/console/api/go/status" }.count, 1)
        }
    }

    @MainActor
    func testZenFailureKeepsFreshGoBillingThroughRefreshWithoutReusingOldBilling() async throws {
        for state in ["renewing", "canceled", "pending"] {
            let config = configuration()
            let credentials = credential()
            let secrets = OpenCodeTestSecrets()
            try secrets.saveSecret(credentials.encoded(), account: ProviderConfigurationStore.keychainAccount(for: config))
            let data = try fixture(state == "pending" ? ["renewalPending": true]
                : state == "canceled" ? ["cancelAtPeriodEnd": true] : [:],
                access: state == "canceled" ? ["cancelAtPeriodEnd": true] : [:])
            BillingReplay.state.reset { request, _ in
                if request.url?.path == "/console/auth/session" {
                    return (200, Data(#"{"user":{"id":"user_synthetic"},"org_id":"org_synthetic"}"#.utf8))
                }
                return request.url!.path.contains("/billing/") ? (503, Data()) : (200, data)
            }
            let result = await OpenCodeConsoleUsageProvider(secretStore: secrets, makeSession: Self.session)
                .fetchUsage(credential: credentials, configuration: config)
            XCTAssertNotNil(result.failureMessage)
            XCTAssertNil(result.creditsRemaining)
            XCTAssertEqual(result.bars.count, 3)
            let expected: SubscriptionRenewal.State? = state == "pending" ? nil : state == "canceled" ? .nonRenewing : .renewing
            XCTAssertEqual(result.boundSubscriptionRenewal?.state, expected)
            let old = ProviderUsageResult(accountID: config.id, providerID: .openCodeZen, title: "OpenCode", subtitle: "Old observation",
                                          bars: [], subscriptionRenewal: try parse(fixture()), fetchedAt: now)
            let refresh = UsageRefreshService(providers: [BillingResultProvider(result: result)], initialResults: [old])
            await refresh.refresh(configuration: config)
            let displayed = try XCTUnwrap(refresh.results.first)
            XCTAssertNotNil(displayed.failureMessage)
            XCTAssertEqual(displayed.boundSubscriptionRenewal?.state, expected)
            XCTAssertEqual(displayed.subscriptionBillingInformation(at: Date())?.items.first?.label,
                           state == "pending" ? "Renewal date unavailable" : state == "canceled" ? "Does not renew" : "Next subscription renewal")
        }
    }

    func testSessionIdentityUsesNativeOptionalWorkspaceAndRejectsMalformedScope() {
        for raw in [#"{"user":{"id":"user_synthetic"}}"#, #"{"user":{"id":"user_synthetic"},"org_id":null}"#] {
            XCTAssertTrue(OpenCodeSubscriptionBilling.matchesIdentity(Data(raw.utf8), credential: credential()))
        }
        for raw in [#"{"user":{"id":"other"}}"#, #"{"user":{"id":"user_synthetic"},"org_id":42}"#, "[]", "{}"] {
            XCTAssertFalse(OpenCodeSubscriptionBilling.matchesIdentity(Data(raw.utf8), credential: credential()))
        }
    }

    func testProductionSessionHasNoSharedCredentialCookieOrCacheStores() {
        let session = OpenCodeDeviceAuthService.makeSession()
        defer { session.invalidateAndCancel() }
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertNil(session.configuration.urlCredentialStorage)
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        XCTAssertNotNil(session.delegate)
    }

    func testRedirectDelegateRejectsForeignAndSameOriginRedirects() {
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://opencode.ai/console/api/go/status")!
        let task = session.dataTask(with: original)
        let delegate = session.delegate as? URLSessionTaskDelegate
        for destination in ["https://foreign.invalid/steal", "https://opencode.ai/console/checkout"] {
            let rejected = expectation(description: "Redirect rejected")
            delegate?.urlSession?(session, task: task,
                                  willPerformHTTPRedirection: HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil)!,
                                  newRequest: URLRequest(url: URL(string: destination)!), completionHandler: { redirected in
                XCTAssertNil(redirected)
                rejected.fulfill()
            })
            wait(for: [rejected], timeout: 1)
        }
    }

    func testCancellationAfterGoReadRetainsSuccessfulUsageWithoutBillingDate() async throws {
        let config = configuration()
        let credentials = credential()
        let secrets = OpenCodeTestSecrets()
        try secrets.saveSecret(credentials.encoded(), account: ProviderConfigurationStore.keychainAccount(for: config))
        let data = try fixture()
        let after = expectation(description: "After-read identity request")
        BillingReplay.state.reset { request, count in
            if request.url?.path == "/console/auth/session" {
                if count == 2 { after.fulfill(); return (299, Data()) }
                return (200, Data(#"{"user":{"id":"user_synthetic"},"org_id":"org_synthetic"}"#.utf8))
            }
            return (200, request.url!.path.contains("/billing/") ? Data(#"{"balanceMicroCents":"2500000000"}"#.utf8) : data)
        }
        let task = Task {
            await OpenCodeConsoleUsageProvider(secretStore: secrets, makeSession: Self.session)
                .fetchUsage(credential: credentials, configuration: config)
        }
        await fulfillment(of: [after], timeout: 3)
        task.cancel()
        let result = await task.value
        XCTAssertNil(result.subscriptionRenewal)
        XCTAssertEqual(result.creditsRemaining, 25)
        XCTAssertEqual(result.bars.count, 3)
        XCTAssertNil(result.failureMessage)
    }

    @MainActor
    func testCredentialMutationsInvalidateCachedBillingOnlyForTheirAccount() throws {
        for operation in ["save", "disconnect", "replace", "remove", "reset"] {
            let suite = "OpenCodeBilling.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let secrets = OpenCodeTestSecrets()
            let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
            let first = configuration()
            var second = ProviderAccountConfiguration(id: "second", providerID: .openCodeZen,
                                                      accountLabel: "Second account", authMethod: .browserSession)
            second.openCodeWorkspaceId = first.openCodeWorkspaceId
            XCTAssertTrue(store.replaceCredential(try credential().encoded(), for: first))
            XCTAssertTrue(store.replaceCredential(try credential().encoded(), for: second))
            let renewal = try XCTUnwrap(parse(fixture()))
            let cached = ProviderUsageResult(accountID: first.id, providerID: .openCodeZen, title: "OpenCode", subtitle: "Synthetic billing",
                                             bars: [], subscriptionRenewal: renewal, fetchedAt: now)
            let other = ProviderUsageResult(accountID: second.id, providerID: .openCodeZen, title: "OpenCode", subtitle: "Synthetic billing",
                                            bars: [], subscriptionRenewal: SubscriptionRenewal(accountID: second.id, providerID: .openCodeZen,
                                                                                             state: .renewing, date: renewal.date, observedAt: now),
                                            fetchedAt: now)
            let refresh = UsageRefreshService(providers: [], initialResults: [cached, other])
            let subscription = store.credentialChanges.sink { refresh.invalidateCredentials(accountID: $0) }
            defer { subscription.cancel() }
            secrets.setFailure(true)
            XCTAssertFalse(store.saveSecret("rejected replacement", for: first))
            XCTAssertNotNil(refresh.results.first { $0.accountID == first.id }?.subscriptionRenewal)
            secrets.setFailure(false)
            switch operation {
            case "save": XCTAssertTrue(store.saveSecret("replacement", for: first))
            case "disconnect": XCTAssertTrue(store.saveSecret("", for: first))
            case "replace": XCTAssertTrue(store.replaceCredential("replacement", for: first))
            case "remove": XCTAssertTrue(store.removeAccount(first))
            default: XCTAssertTrue(store.resetAccounts())
            }
            XCTAssertNil(refresh.results.first { $0.accountID == first.id }, operation)
            XCTAssertEqual(refresh.results.contains { $0.accountID == second.id }, operation != "reset", operation)
        }
    }

    private func parse(_ data: Data) -> SubscriptionRenewal? {
        OpenCodeSubscriptionBilling.observation(data, credential: credential(), configuration: configuration(), at: now)
    }

    private func credential() -> OpenCodeConsoleCredential {
        OpenCodeConsoleCredential(kind: "opencode-console-v1", accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
                                  expiresAt: Date().addingTimeInterval(3600), workspaceID: "org_synthetic", userID: "user_synthetic")
    }

    private func configuration() -> ProviderAccountConfiguration {
        var config = ProviderAccountConfiguration(id: "selected", providerID: .openCodeZen, authMethod: .browserSession)
        config.openCodeWorkspaceId = "org_synthetic"
        return config
    }

    private func object() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"""
        {"subscriberUserId":"user_synthetic","product":"go","renewalProduct":"go","cancelAtPeriodEnd":false,
         "resumability":"renewing","renewalPending":false,"renewalAuthorizationRequired":false,
         "access":{"startsAt":"2026-10-01T00:00:00Z","endsAt":"2026-11-01T00:00:00Z","cancelAtPeriodEnd":false,"meters":{
          "fiveHour":{"usedMicroCents":"25","limitMicroCents":"100","startsAt":"2026-10-10T00:00:00Z","resetsAt":"2033-01-01T00:00:00Z"},
          "week":{"usedMicroCents":"50","limitMicroCents":"100","resetsAt":"2033-01-01T00:00:00Z"},
          "month":{"usedMicroCents":"75","limitMicroCents":"100"}}}}
        """#.utf8)) as? [String: Any])
    }

    private func fixture(_ updates: [String: Any] = [:], access: [String: Any] = [:]) throws -> Data {
        var root = try object()
        var period = try XCTUnwrap(root["access"] as? [String: Any])
        period.merge(access) { _, new in new }
        root["access"] = period
        root.merge(updates) { _, new in new }
        return try JSONSerialization.data(withJSONObject: root)
    }

    private static func session() -> URLSession { OpenCodeDeviceAuthService.makeSession(protocolClasses: [BillingReplay.self]) }
}

private final class BillingReplay: URLProtocol, @unchecked Sendable {
    static let state = BillingReplayState()
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let (status, data) = Self.state.reply(request)
        // The after-read cancellation fixture remains in flight until the task cancels it.
        if status == 299 { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class BillingReplayState: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var handler: (@Sendable (URLRequest, Int) -> (Int, Data))?
    var requests: [URLRequest] { lock.withLock { recorded } }
    func reset(_ handler: @escaping @Sendable (URLRequest, Int) -> (Int, Data)) {
        lock.withLock { recorded = []; self.handler = handler }
    }
    func reply(_ request: URLRequest) -> (Int, Data) {
        lock.withLock {
            recorded.append(request)
            let count = recorded.filter { $0.url?.path == request.url?.path }.count
            return handler?(request, count) ?? (500, Data())
        }
    }
}

private struct BillingResultProvider: UsageProvider {
    let providerID = ProviderID.openCodeZen
    let result: ProviderUsageResult
    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult { result }
}
