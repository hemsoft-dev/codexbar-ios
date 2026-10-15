import Foundation
import XCTest
@testable import CodexBarIOS

final class CursorSubscriptionBillingTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)
    private var account: ProviderAccountConfiguration {
        ProviderAccountConfiguration(id: "cursor-billing", providerID: .cursor, accountLabel: "Synthetic Cursor", authMethod: .browserSession)
    }

    func testMonthlyAndAnnualUseActualStripePeriodAndExplicitRenewalState() throws {
        for yearly in [false, true] {
            let profile = try XCTUnwrap(CursorSubscriptionBilling.Profile(Data(UITestCursorBillingFixture.profile(yearly: yearly).utf8)))
            let end = now.addingTimeInterval(yearly ? 31_536_000 : 259_200)
            let result = CursorSubscriptionBilling.observation(
                Data(UITestCursorBillingFixture.subscriptions(end: end.timeIntervalSince1970, yearly: yearly).utf8),
                profile: profile, configuration: account, at: now
            )
            XCTAssertEqual(result?.state, .renewing)
            XCTAssertEqual(result?.date, end)
            XCTAssertEqual(result?.accountID, account.id)
            XCTAssertEqual(result?.providerID, .cursor)
        }
    }

    func testCancellationTakesPrecedenceAndPastDatesNeverRollForward() throws {
        let profile = try XCTUnwrap(CursorSubscriptionBilling.Profile(Data(UITestCursorBillingFixture.profile().utf8)))
        for offset in [-60.0, 259_200] {
            let end = now.addingTimeInterval(offset)
            let data = Data(UITestCursorBillingFixture.subscriptions(end: end.timeIntervalSince1970, canceled: true).utf8)
            let result = CursorSubscriptionBilling.observation(data, profile: profile, configuration: account, at: now)
            XCTAssertEqual(result?.state, .nonRenewing)
            XCTAssertEqual(result?.date, end)
            XCTAssertNil(result?.compactLabel(at: now))
        }
    }

    func testCancellationBeyondCurrentPaidPeriodDoesNotInventAccessEnd() throws {
        let profile = try XCTUnwrap(CursorSubscriptionBilling.Profile(Data(UITestCursorBillingFixture.profile().utf8)))
        let end = now.addingTimeInterval(259_200).timeIntervalSince1970
        for canceled in [false, true] {
            let base = UITestCursorBillingFixture.subscriptions(end: end, canceled: canceled)
            let futureStop = base.replacingOccurrences(of: "\"cancel_at\":null", with: "\"cancel_at\":\(end + 259_200)")
            XCTAssertNil(CursorSubscriptionBilling.observation(Data(futureStop.utf8), profile: profile, configuration: account, at: now))
            let currentStop = base.replacingOccurrences(of: "\"cancel_at\":null", with: "\"cancel_at\":\(end)")
            XCTAssertEqual(CursorSubscriptionBilling.observation(Data(currentStop.utf8), profile: profile,
                                                               configuration: account, at: now)?.state, .nonRenewing)
        }
    }

    func testMissingMalformedRecoveryTrialScheduleAndAmbiguousSubscriptionsAreRejected() throws {
        let profile = try XCTUnwrap(CursorSubscriptionBilling.Profile(Data(UITestCursorBillingFixture.profile().utf8)))
        let base = UITestCursorBillingFixture.subscriptions(end: now.addingTimeInterval(259_200).timeIntervalSince1970)
        let mutations = [
            ("\"cancel_at_period_end\":false", "\"cancel_at_period_end\":null"),
            ("\"cancel_at_period_end\":false", "\"cancel_at_period_end\":0"),
            ("\"has_more\":false", "\"has_more\":true"), ("\"status\":\"active\"", "\"status\":\"past_due\""),
            ("\"pause_collection\":null", "\"pause_collection\":{}"), ("\"pending_update\":null", "\"pending_update\":{}"),
            ("\"trial_end\":null", "\"trial_end\":1900000000"), ("\"has_update_scheduled\":false", "\"has_update_scheduled\":true"),
            ("\"is_mixed_interval\":false", "\"is_mixed_interval\":true"), ("Cursor Pro", "Cursor Business"),
            ("\"interval_count\":1", "\"interval_count\":true"), ("\"interval\":\"month\"", "\"interval\":\"year\""),
            ("\"cancel_at\":null", "\"cancel_at\":\"malformed\""),
        ]
        for (source, replacement) in mutations {
            XCTAssertNil(CursorSubscriptionBilling.observation(Data(base.replacingOccurrences(of: source, with: replacement).utf8),
                                                               profile: profile, configuration: account, at: now), replacement)
        }
        var root = try XCTUnwrap(SubscriptionBillingParser.object(Data(base.utf8)))
        let subscription = try XCTUnwrap((root["data"] as? [[String: Any]])?.first)
        root["data"] = [subscription, subscription]
        XCTAssertNil(CursorSubscriptionBilling.observation(try JSONSerialization.data(withJSONObject: root), profile: profile,
                                                           configuration: account, at: now))
        for change in [("\"lastPaymentFailed\":false", "\"lastPaymentFailed\":true"),
                       ("\"paymentRecoveryAction\":null", "\"paymentRecoveryAction\":{}"),
                       ("\"pendingCancellationDate\":\"\"", "\"pendingCancellationDate\":\"2026-12-01\""),
        ] {
            let recovery = try XCTUnwrap(CursorSubscriptionBilling.Profile(Data(UITestCursorBillingFixture.profile()
                .replacingOccurrences(of: change.0, with: change.1).utf8)))
            XCTAssertNil(CursorSubscriptionBilling.observation(Data(base.utf8), profile: recovery, configuration: account, at: now))
        }
    }

    func testFreeTeamUnknownAndNonStripeProfilesDoNotCreatePortalSessions() async throws {
        for mutation in [("\"membershipType\":\"pro\"", "\"membershipType\":\"free\""),
                         ("\"membershipType\":\"pro\"", "\"membershipType\":\"unknown\""),
                         ("\"isTeamMember\":false", "\"isTeamMember\":true"),
                         ("\"paymentId\":\"cus_synthetic\"", "\"paymentId\":\"apple_synthetic\""),
        ] {
            let profile = UITestCursorBillingFixture.profile().replacingOccurrences(of: mutation.0, with: mutation.1)
            let result = try await fetch(overrides: ["/api/auth/stripe": (200, profile)])
            XCTAssertNil(result.subscriptionRenewal)
            XCTAssertNil(result.failureMessage)
            XCTAssertFalse(CursorBillingReplayProtocol.state.requests.contains { $0.url?.path == "/api/stripeSession" })
        }
    }

    func testFullProductionTransportScopesCredentialsAndPreservesUsage() async throws {
        let result = try await fetch()
        XCTAssertEqual(result.subscriptionRenewal?.state, .renewing)
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(result.plan?.identifier, "cursor.pro")
        XCTAssertFalse(result.bars.isEmpty)
        let requests = CursorBillingReplayProtocol.state.requests
        XCTAssertEqual(requests.filter { $0.url?.path == "/api/auth/me" }.count, 2)
        for request in requests {
            let host = request.url?.host
            if host == "api2.cursor.sh" {
                XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer e30.") == true)
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            } else if host == "cursor.com" {
                XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.hasPrefix("WorkosCursorSessionToken=fixture%7Csynthetic-owner%3A%3A") == true)
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertTrue(["GET", "POST"].contains(request.httpMethod ?? ""))
                if request.httpMethod == "POST" { XCTAssertEqual(request.url?.path, "/api/stripeSession") }
            } else if host == "api.stripe.com" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic_scoped_portal_key")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Stripe-Account"), "acct_synthetic")
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                XCTAssertEqual(request.httpMethod, "GET")
            } else {
                XCTAssertEqual(host, "billing.stripe.com")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            }
        }
    }

    func testOwnerCustomerPortalAndOptionalTransportFailuresNeverContaminateUsage() async throws {
        let cases: [[String: (Int, String)]] = [
            ["/api/auth/me": (200, #"{"sub":"other-owner"}"#)],
            ["/v1/billing_portal/sessions/bps_synthetic": (200, #"{"id":"bps_synthetic","customer":"cus_other","livemode":true}"#)],
            ["/api/stripeSession": (401, "{}")], ["/api/stripeSession": (429, "{}")],
            ["/api/stripeSession": (200, #""https://attacker.invalid/p/session/synthetic""#)],
            ["/p/session/synthetic": (200, "<html>Unknown portal</html>")],
            ["/api/auth/stripe": (0, "")], ["/api/auth/stripe": (200, "{malformed")],
            ["/api/auth/stripe": (302, "{}")],
        ]
        for overrides in cases {
            let result = try await fetch(overrides: overrides)
            XCTAssertNil(result.subscriptionRenewal)
            XCTAssertNil(result.failureMessage)
            XCTAssertFalse(result.bars.isEmpty)
            XCTAssertFalse(CursorBillingReplayProtocol.state.requests.contains { $0.url?.host == "attacker.invalid" })
        }
    }

    func testCredentialReplacementAndRemovalDuringBillingDiscardObservation() async throws {
        for replacement in [String?.none, "replacement"] {
            let secrets = GrokTestSecrets()
            let key = ProviderConfigurationStore.keychainAccount(for: account)
            let result = try await fetch(secrets: secrets, onSubscriptions: {
                if let replacement { try? secrets.saveSecret(replacement, account: key) } else { try? secrets.deleteSecret(account: key) }
            })
            XCTAssertNil(result.subscriptionRenewal)
            XCTAssertNotNil(result.failureMessage)
        }
    }

    func testCancellationAfterSuccessfulUsageNeverPublishesBilling() async throws {
        let cancellation = CursorBillingCancellation()
        let task = Task { try await self.fetch(onSubscriptions: { cancellation.cancel() }) }
        cancellation.install { task.cancel() }
        let result = try await task.value
        XCTAssertNil(result.subscriptionRenewal)
        XCTAssertEqual(result.failureMessage, "Cursor refresh canceled.")
    }

    func testUnsafePortalURLsAndExpiredOrMalformedShellsAreRejected() throws {
        for url in ["http://billing.stripe.com/p/session/x", "https://billing.stripe.com:443/p/session/x",
                    "https://user@billing.stripe.com/p/session/x", "https://billing.stripe.com/p/session/x#fragment",
                    "https://billing.stripe.com/other", "https://billing.stripe.com.evil.invalid/p/session/x",
        ] {
            XCTAssertNil(CursorSubscriptionBilling.portalURL(try JSONEncoder().encode(url)))
        }
        XCTAssertNotNil(CursorSubscriptionBilling.Portal(Data(UITestCursorBillingFixture.shell.utf8)))
        XCTAssertNil(CursorSubscriptionBilling.Portal(Data(UITestCursorBillingFixture.shell
            .replacingOccurrences(of: "expired&quot;:false", with: "expired&quot;:true").utf8)))
    }

    private func fetch(overrides: [String: (Int, String)] = [:], secrets: GrokTestSecrets = GrokTestSecrets(),
                       onSubscriptions: (@Sendable () -> Void)? = nil) async throws -> ProviderUsageResult {
        CursorBillingReplayProtocol.state.reset(overrides: overrides, onSubscriptions: onSubscriptions)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CursorBillingReplayProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        try secrets.saveSecret(UITestCursorBillingFixture.credential, account: ProviderConfigurationStore.keychainAccount(for: account))
        return try await CursorUsageProvider(secretStore: secrets, session: session).fetchUsage(for: account)
    }
}

private final class CursorBillingCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var canceled = false
    func install(_ action: @escaping @Sendable () -> Void) {
        let run = lock.withLock { self.action = action; return canceled }
        if run { action() }
    }
    func cancel() {
        let action = lock.withLock { canceled = true; return self.action }
        action?()
    }
}

private final class CursorBillingReplayProtocol: URLProtocol, @unchecked Sendable {
    static let state = CursorBillingReplayState()
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let reply = Self.state.reply(request)
        if reply.0 == 0 { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class CursorBillingReplayState: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var overrides: [String: (Int, String)] = [:]
    private var onSubscriptions: (@Sendable () -> Void)?
    var requests: [URLRequest] { lock.withLock { recorded } }
    func reset(overrides: [String: (Int, String)], onSubscriptions: (@Sendable () -> Void)?) {
        lock.withLock { self.overrides = overrides; self.onSubscriptions = onSubscriptions; recorded = [] }
    }
    func reply(_ request: URLRequest) -> (Int, String) {
        let state = lock.withLock { () -> ((Int, String)?, (@Sendable () -> Void)?) in
            recorded.append(request)
            return (overrides[request.url?.path ?? ""], onSubscriptions)
        }
        if request.url?.path.hasSuffix("/subscriptions") == true { state.1?() }
        return state.0 ?? UITestCursorBillingFixture.reply(request, scenario: "subscription-renewals")
    }
}
