import Foundation
import XCTest
@testable import CodexBarIOS

@MainActor
final class ClaudePlanProfileTests: XCTestCase {
    // Synthetic compatibility values, not captured Ultra profile responses.
    func testExplicitProfilePlansAndMaxMultipliers() throws {
        for (type, tier, name) in [
            ("claude_pro", "default_claude_pro", "Pro"),
            ("claude_ultra", "default_claude_max_20x", "Ultra"),
            ("claude_max", "default_claude_max_5x", "Max"),
            ("claude_max", "default_claude_max_20x", "Ultra"),
            ("claude_max", "future_tier", "Max"),
            ("claude_team", "team_standard", "Team"),
            ("claude_enterprise", "enterprise", "Enterprise"),
            ("claude_enterprise", "default_claude_max_5x", "Enterprise"),
            ("claude_team", "default_claude_max_20x", "Team"),
        ] {
            let data = try JSONSerialization.data(withJSONObject: ["organization": ["organization_type": type, "rate_limit_tier": tier]])
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(ClaudeProfilePlanParser.parse(root)?.accessibilityLabel, name)
        }
    }

    func testUnknownConflictingAndMalformedMetadataDoesNotGuess() throws {
        for json in [
            #"{}"#,
            #"{"organization":{"organization_type":"claude_ultra","rate_limit_tier":"max_5x"}}"#,
            #"{"organization":{"organization_type":"claude_ultra"},"account":{"has_claude_pro":true}}"#,
            #"{"organization":{"organization_type":"claude_ultra","rate_limit_tier":7}}"#,
            #"{"organization":{"organization_type":"future_plan","rate_limit_tier":"default_claude_max_20x"}}"#,
            #"{"organization":{"organization_type":"claude_pro","rate_limit_tier":"default_claude_max_20x"}}"#,
            #"{"organization":{"organization_type":"claude_max","rate_limit_tier":"default_claude_pro"}}"#,
            #"{"account":{"has_claude_max":true,"has_claude_pro":true}}"#,
            #"{"organization":{"organization_type":"claude_max"},"account":{"has_claude_max":true,"has_claude_pro":true}}"#,
            #"{"account":{"has_claude_max":1,"has_claude_pro":0}}"#,
            #"{"account":{"has_claude_pro":true,"has_claude_max":1}}"#,
            #"{"account":{"has_claude_max":true,"has_claude_pro":"false"}}"#,
            #"{"organization":false,"account":{"has_claude_pro":true}}"#,
            #"{"organization":{"organization_type":"claude_pro"},"account":[]}"#,
            #"{"organization":{"organization_type":7},"account":{"has_claude_pro":true}}"#,
            #"{"organization":{"organization_type":"claude_max"},"account":{"has_claude_max":false}}"#,
            #"{"organization":{"organization_type":"claude_max"},"account":{"has_claude_pro":true}}"#,
        ] {
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertNil(ClaudeProfilePlanParser.parse(root), json)
        }
        XCTAssertEqual(ClaudeProfilePlanParser.parse([
            "organization": ["organization_type": "claude_ultra"],
        ])?.accessibilityLabel, "Ultra")
        let flags = Data(#"{"account":{"has_claude_pro":true,"has_claude_max":false}}"#.utf8)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: flags) as? [String: Any])
        XCTAssertEqual(ClaudeProfilePlanParser.parse(root)?.accessibilityLabel, "Pro")
    }

    func testProviderResolvesMissingLoginMetadataAndUsesReadOnlyProfile() async throws {
        let harness = ProfileHarness()
        PlanProfileProtocol.configure(profile: Self.max20)
        let result = try await harness.provider.fetchUsage(for: harness.account)
        XCTAssertEqual(result.plan?.accessibilityLabel, "Ultra")
        XCTAssertFalse(result.bars.isEmpty)
        XCTAssertNil(result.failureMessage)
        let request = try XCTUnwrap(PlanProfileProtocol.requests.first { $0.url?.path == "/api/oauth/profile" })
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "CodexBarIOS")
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(PlanProfileProtocol.requests.count, 2)
    }

    func testPlanChangeRefreshesAfterFiveMinutesWithoutRelogin() async throws {
        let harness = ProfileHarness()
        PlanProfileProtocol.configure(profile: Self.max5)
        let first = try await harness.provider.fetchUsage(for: harness.account)
        XCTAssertEqual(first.plan?.accessibilityLabel, "Max")
        PlanProfileProtocol.setProfile(Self.max20)
        harness.clock.advance(299)
        let cached = try await harness.provider.fetchUsage(for: harness.account)
        XCTAssertEqual(cached.plan?.accessibilityLabel, "Max")
        XCTAssertEqual(PlanProfileProtocol.profileCount, 1)
        harness.clock.advance(2)
        let updated = try await harness.provider.fetchUsage(for: harness.account)
        XCTAssertEqual(updated.plan?.accessibilityLabel, "Ultra")
        XCTAssertEqual(PlanProfileProtocol.profileCount, 2)
    }

    func testProfileErrorsAndMalformedDataPreserveUsageAndBoundRequests() async throws {
        for (status, body) in [(401, ""), (403, ""), (404, ""), (429, ""), (503, ""), (200, "not json"), (200, "{}") ] {
            let harness = ProfileHarness()
            PlanProfileProtocol.configure(profile: body, status: status)
            let result = try await harness.provider.fetchUsage(for: harness.account)
            XCTAssertFalse(result.bars.isEmpty, "status \(status)")
            XCTAssertNil(result.failureMessage)
            XCTAssertNil(result.plan)
            _ = try await harness.provider.fetchUsage(for: harness.account)
            XCTAssertEqual(PlanProfileProtocol.profileCount, 1)
        }
    }

    func testLastKnownPlanSurvivesTransientFailureButUnknownSuccessClearsIt() async throws {
        let harness = ProfileHarness()
        PlanProfileProtocol.configure(profile: Self.max5)
        _ = try await harness.provider.fetchUsage(for: harness.account)
        harness.clock.advance(301)
        PlanProfileProtocol.setProfile("", status: 503)
        let failed = try await harness.provider.fetchUsage(for: harness.account)
        XCTAssertEqual(failed.plan?.accessibilityLabel, "Max")
        harness.clock.advance(301)
        PlanProfileProtocol.setProfile("{}")
        let unknown = try await harness.provider.fetchUsage(for: harness.account)
        XCTAssertNil(unknown.plan)
        XCTAssertNil(unknown.failureMessage)
    }

    func testRetryAfterAndCredentialReplacementResetProfileThrottle() async throws {
        let harness = ProfileHarness()
        PlanProfileProtocol.configure(profile: "", status: 429, retry: "1200")
        _ = try await harness.provider.fetchUsage(for: harness.account)
        harness.clock.advance(301)
        _ = try await harness.provider.fetchUsage(for: harness.account)
        XCTAssertEqual(PlanProfileProtocol.profileCount, 1)
        harness.clock.advance(900)
        PlanProfileProtocol.setProfile(Self.max20)
        let afterRetry = try await harness.provider.fetchUsage(for: harness.account)
        XCTAssertEqual(afterRetry.plan?.accessibilityLabel, "Ultra")
        XCTAssertEqual(PlanProfileProtocol.profileCount, 2)
        harness.secrets.token = "replacement-token"
        PlanProfileProtocol.setProfile(Self.pro)
        let replacement = try await harness.provider.fetchUsage(for: harness.account)
        XCTAssertEqual(replacement.plan?.accessibilityLabel, "Pro")
        XCTAssertEqual(PlanProfileProtocol.profileCount, 3)
    }

    func testOldUsageResponseCannotPublishAfterAccountReplacement() async throws {
        let harness = ProfileHarness()
        PlanProfileProtocol.configure(profile: Self.max5, holdUsage: "fixture-token")
        let pending = Task { try await harness.provider.fetchUsage(for: harness.account) }
        try await waitForHeldRequest()
        harness.secrets.token = "replacement-token"
        PlanProfileProtocol.setProfile(Self.pro)
        let replacement = try await harness.provider.fetchUsage(for: harness.account)
        XCTAssertEqual(replacement.plan?.accessibilityLabel, "Pro")
        PlanProfileProtocol.releaseHeld()
        let old = try await pending.value
        XCTAssertTrue(old.bars.isEmpty)
        XCTAssertNil(old.plan)
        XCTAssertNotNil(old.failureMessage)
        let stable = try await harness.provider.fetchUsage(for: harness.account)
        XCTAssertEqual(stable.plan?.accessibilityLabel, "Pro")
    }

    func testSignOutClearsCachedPlanAndUsage() async throws {
        let harness = ProfileHarness()
        PlanProfileProtocol.configure(profile: Self.max20)
        _ = try await harness.provider.fetchUsage(for: harness.account)
        harness.secrets.token = nil
        let signedOut = try await harness.provider.fetchUsage(for: harness.account)
        XCTAssertNil(signedOut.plan)
        XCTAssertTrue(signedOut.bars.isEmpty)
        harness.secrets.token = "replacement-token"
        PlanProfileProtocol.setProfile("{}")
        let fresh = try await harness.provider.fetchUsage(for: harness.account)
        XCTAssertNil(fresh.plan)
        XCTAssertFalse(fresh.bars.isEmpty)
    }

    func testConcurrentProfileLookupsShareOneRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlanProfileProtocol.self]
        let client = ClaudePlanProfileClient(session: URLSession(configuration: configuration))
        PlanProfileProtocol.configure(profile: Self.max20, holdProfile: true)
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let first = Task { await client.resolve(accountID: "one", accessToken: "fixture-token", at: date) }
        try await waitForHeldRequest()
        let second = Task { await client.resolve(accountID: "one", accessToken: "fixture-token", at: date) }
        await Task.yield()
        PlanProfileProtocol.releaseHeld()
        let plans = await [first.value, second.value]
        XCTAssertEqual(plans.map { $0.plan(fallback: nil)?.accessibilityLabel }, ["Ultra", "Ultra"])
        XCTAssertEqual(PlanProfileProtocol.profileCount, 1)
    }

    func testLateProfileCannotReplaceNewCredentialPlan() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlanProfileProtocol.self]
        let client = ClaudePlanProfileClient(session: URLSession(configuration: configuration))
        PlanProfileProtocol.configure(profile: Self.max20, holdProfile: true)
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let old = Task { await client.resolve(accountID: "one", accessToken: "old-token", at: date) }
        try await waitForHeldRequest()
        PlanProfileProtocol.allowNewProfileRequests()
        PlanProfileProtocol.setProfile(Self.pro)
        let replacement = await client.resolve(accountID: "one", accessToken: "new-token", at: date)
        PlanProfileProtocol.releaseHeld(profile: Self.max20)
        let obsolete = await old.value
        let current = await client.resolve(accountID: "one", accessToken: "new-token", at: date)
        XCTAssertNil(obsolete.plan(fallback: nil))
        XCTAssertEqual(replacement.plan(fallback: nil)?.accessibilityLabel, "Pro")
        XCTAssertEqual(current.plan(fallback: nil)?.accessibilityLabel, "Pro")
    }

    func testAuthorizationFailureClearsKnownPlanAndCredentialFallback() async throws {
        for status in [401, 403] {
            let harness = ProfileHarness()
            harness.secrets.subscriptionType = "pro"
            PlanProfileProtocol.configure(profile: Self.max20)
            _ = try await harness.provider.fetchUsage(for: harness.account)
            harness.clock.advance(301)
            PlanProfileProtocol.setProfile("", status: status)
            let denied = try await harness.provider.fetchUsage(for: harness.account)
            XCTAssertNil(denied.plan)
            XCTAssertFalse(denied.bars.isEmpty)
            XCTAssertNil(denied.failureMessage)
        }
    }

    func testHTTPDateRetryAfterBoundsRequests() async throws {
        let harness = ProfileHarness()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        PlanProfileProtocol.configure(profile: "", status: 429,
                                      retry: formatter.string(from: harness.clock.date.addingTimeInterval(1_200)))
        _ = try await harness.provider.fetchUsage(for: harness.account)
        harness.clock.advance(301)
        _ = try await harness.provider.fetchUsage(for: harness.account)
        XCTAssertEqual(PlanProfileProtocol.profileCount, 1)
        harness.clock.advance(900)
        PlanProfileProtocol.setProfile(Self.pro)
        let result = try await harness.provider.fetchUsage(for: harness.account)
        XCTAssertEqual(result.plan?.accessibilityLabel, "Pro")
        XCTAssertEqual(PlanProfileProtocol.profileCount, 2)
    }

    func testProfileCachesAreSeparateAcrossAccounts() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["Cookie": "synthetic-other-account", "X-Unrelated-Session": "synthetic"]
        configuration.protocolClasses = [PlanProfileProtocol.self]
        let client = ClaudePlanProfileClient(session: URLSession(configuration: configuration))
        PlanProfileProtocol.configure(profile: Self.max20)
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let first = await client.resolve(accountID: "one", accessToken: "token-one", at: date)
        PlanProfileProtocol.setProfile(Self.pro)
        let second = await client.resolve(accountID: "two", accessToken: "token-two", at: date)
        let cached = await client.resolve(accountID: "one", accessToken: "token-one", at: date)
        XCTAssertEqual(first.plan(fallback: nil)?.accessibilityLabel, "Ultra")
        XCTAssertEqual(second.plan(fallback: nil)?.accessibilityLabel, "Pro")
        XCTAssertEqual(cached.plan(fallback: nil)?.accessibilityLabel, "Ultra")
        XCTAssertEqual(PlanProfileProtocol.profileCount, 2)
        for request in PlanProfileProtocol.requests {
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Unrelated-Session"))
        }
    }

    private func waitForHeldRequest() async throws {
        for _ in 0..<100 {
            if PlanProfileProtocol.hasHeld { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected a suspended old-account response")
    }

    private static let max5 = #"{"organization":{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_5x"}}"#
    private static let max20 = #"{"organization":{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_20x"}}"#
    private static let pro = #"{"organization":{"organization_type":"claude_pro","rate_limit_tier":"default_claude_pro"}}"#
}

private struct ProfileHarness {
    let account = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
    let secrets = ProfileSecrets()
    let clock = ProfileClock()
    let provider: ClaudeUsageProvider
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlanProfileProtocol.self]
        let secrets = self.secrets
        let clock = self.clock
        provider = ClaudeUsageProvider(secretStore: secrets, session: URLSession(configuration: configuration), now: { clock.date })
    }
}

private final class ProfileClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Date(timeIntervalSince1970: 1_900_000_000)
    var date: Date { lock.withLock { stored } }
    func advance(_ seconds: TimeInterval) { lock.withLock { stored = stored.addingTimeInterval(seconds) } }
}

private final class ProfileSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String? = "fixture-token"
    var subscriptionType = "subscription"
    var token: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func readSecret(account: String) throws -> String? {
        token.map { ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(subscriptionType: subscriptionType, accessToken: $0)) }
    }
    func saveSecret(_ secret: String, account: String) throws { token = ClaudeCredentialsParser.parse(secret)?.accessToken }
    func deleteSecret(account: String) throws { token = nil }
}

private class PlanProfileProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var profile = "{}"
        var status = 200
        var retry: String?
        var holdUsage: String?
        var holdProfile = false
        var held: PlanProfileProtocol?
        var requests: [URLRequest] = []
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()
    static var requests: [URLRequest] { lock.withLock { state.requests } }
    static var profileCount: Int { requests.filter { $0.url?.path == "/api/oauth/profile" }.count }
    static var hasHeld: Bool { lock.withLock { state.held != nil } }
    static func configure(profile: String, status: Int = 200, retry: String? = nil, holdUsage: String? = nil, holdProfile: Bool = false) {
        lock.withLock { state = State(profile: profile, status: status, retry: retry, holdUsage: holdUsage, holdProfile: holdProfile) }
    }
    static func setProfile(_ profile: String, status: Int = 200) { lock.withLock { state.profile = profile; state.status = status } }
    static func allowNewProfileRequests() { lock.withLock { state.holdProfile = false } }
    static func releaseHeld(profile: String? = nil) {
        let snapshot = lock.withLock { let snapshot = state; state.held = nil; state.holdUsage = nil; state.holdProfile = false; return snapshot }
        snapshot.held?.respond(profile: profile ?? snapshot.profile, status: snapshot.status, retry: snapshot.retry)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let snapshot = Self.lock.withLock {
            Self.state.requests.append(request)
            if request.url?.path == "/api/oauth/usage",
               request.value(forHTTPHeaderField: "Authorization") == Self.state.holdUsage.map({ "Bearer \($0)" }) {
                Self.state.held = self
            }
            if request.url?.path == "/api/oauth/profile", Self.state.holdProfile { Self.state.held = self }
            return Self.state
        }
        if snapshot.held === self { return }
        respond(profile: snapshot.profile, status: snapshot.status, retry: snapshot.retry)
    }
    private func respond(profile: String, status: Int, retry: String?) {
        guard let url = request.url else { return }
        let isProfile = url.path == "/api/oauth/profile"
        var headers: [String: String] = [:]
        if let retry { headers["Retry-After"] = retry }
        if isProfile { headers["Set-Cookie"] = "claude-profile-session=synthetic; Path=/; Secure; HttpOnly" }
        let response = HTTPURLResponse(url: url, statusCode: isProfile ? status : 200, httpVersion: nil, headerFields: headers)!
        let body = isProfile ? profile : #"{"five_hour":{"utilization":42,"resets_at":"2030-01-01T06:00:00Z"}}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
