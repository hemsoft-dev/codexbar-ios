import Foundation
import XCTest
@testable import CodexBarIOS

/// Pins what CodexBar tells Claude about itself (#589). Synthetic transport only; no live account.
final class ClaudeClientIdentityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_893_456_000)
    private let account = ProviderAccountConfiguration(id: "claude-identity", providerID: .claude, authMethod: .cliToken)
    private let windows = #"{"five_hour":{"utilization":42},"seven_day":{"utilization":64}}"#

    func testSignInAsksOnlyForNeededScopesThroughOneClient() throws {
        XCTAssertEqual(ClaudeClientIdentity.userAgent, "CodexBarIOS")
        XCTAssertEqual(ClaudeClientIdentity.requestedScope, "user:profile user:inference")
        let url = ClaudeWebAuthService.authorizationURL(redirectURI: "http://localhost:1461/callback", state: "state", codeChallenge: "challenge")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "scope" }?.value, "user:profile user:inference")
        XCTAssertEqual(query.first { $0.name == "client_id" }?.value, ClaudeClientIdentity.oauthClientID)
        let body = ClaudeWebAuthService.makeTokenRequestBody(code: "code", redirectURI: "http://localhost:1461/callback",
                                                             state: "state", codeVerifier: "verifier")
        let exchange = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        // Sign-in and renewal must name the same client, or saved refresh tokens stop working.
        XCTAssertEqual(exchange["client_id"], ClaudeClientIdentity.oauthClientID)
        XCTAssertNil(exchange["scope"])
    }

    func testRenewalUsageAndProfileRequestsAllNameCodexBar() async throws {
        let harness = makeHarness(expired: true)
        defer { harness.session.invalidateAndCancel() }
        IdentityProtocol.configure(token: (200, #"{"access_token":"renewed-token","expires_in":3600}"#), usage: (200, windows))
        let result = try await harness.provider.fetchUsage(for: account)
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(result.bars.first?.used, 42)

        let requests = IdentityProtocol.requests
        XCTAssertEqual(Set(requests.compactMap { $0.url?.path }), ["/v1/oauth/token", "/api/oauth/usage", "/api/oauth/profile"])
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "CodexBarIOS", request.url?.path ?? "")
        }
        // Nothing else on the wire names a client either: the exact header set is pinned.
        let usage = try XCTUnwrap(requests.first { $0.url?.path == "/api/oauth/usage" })
        XCTAssertEqual(Set((usage.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }),
                       ["authorization", "accept", "content-type", "anthropic-beta", "user-agent"])
        XCTAssertEqual(usage.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(usage.url?.query, "cedar_ember=1")
        let renewal = try XCTUnwrap(requests.first { $0.url?.path == "/v1/oauth/token" })
        // URLSession adds Content-Length to the POST itself.
        XCTAssertEqual(Set((renewal.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }).subtracting(["content-length"]),
                       ["accept", "content-type", "anthropic-version", "user-agent"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(renewal.httpBody)) as? [String: String])
        // The renewal body is unchanged for sign-ins made before this change: no scope is sent.
        let expected = ["grant_type": "refresh_token", "refresh_token": "saved-refresh", "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"]
        XCTAssertEqual(body, expected)
        XCTAssertEqual(ClaudeCredentialsParser.parse(try XCTUnwrap(harness.secrets.readSecret(account: "")))?.accessToken, "renewed-token")
    }

    func testRefusedRenewalOffersSignInOnlyWhenTheRefreshTokenIsRefused() async throws {
        let cases: [(token: (Int, String), message: String, action: ProviderUsageRecoveryAction)] = [
            ((400, #"{"error":"invalid_grant"}"#), "Claude did not renew this sign-in: HTTP 400 (invalid_grant). Sign in again.", .reauthenticate),
            ((400, #"{"error":{"type":"invalid_grant","message":"Refresh token not found"}}"#),
             "Claude did not renew this sign-in: HTTP 400. Sign in again.", .reauthenticate),
            ((403, #"{"error":"invalid_client"}"#),
             "Claude could not renew this sign-in right now: HTTP 403 (invalid_client). Your sign-in was not changed.", .retryRefresh),
            ((401, "{}"), "Claude could not renew this sign-in right now: HTTP 401. Your sign-in was not changed.", .retryRefresh),
            ((503, ""), "Claude could not renew this sign-in right now: HTTP 503. Your sign-in was not changed.", .retryRefresh),
            ((200, "{}"),
             "Claude could not renew this sign-in right now: HTTP 200 without a usable token. Your sign-in was not changed.", .retryRefresh),
        ]
        for testCase in cases {
            let harness = makeHarness(expired: true)
            defer { harness.session.invalidateAndCancel() }
            let saved = try harness.secrets.readSecret(account: "")
            IdentityProtocol.configure(token: testCase.token, usage: (401, ""))
            let result = try await harness.provider.fetchUsage(for: account)
            XCTAssertEqual(result.failureMessage, testCase.message)
            XCTAssertEqual(result.recoveryAction, testCase.action, testCase.message)
            // Nothing is re-sent under another identity, and the saved sign-in is never rewritten.
            XCTAssertEqual(IdentityProtocol.requests.filter { $0.url?.path == "/v1/oauth/token" }.count, 1, testCase.message)
            XCTAssertEqual(IdentityProtocol.requests.filter { $0.url?.path == "/api/oauth/usage" }.count, 1, testCase.message)
            XCTAssertEqual(try harness.secrets.readSecret(account: ""), saved, testCase.message)
        }
    }

    func testRefusedRenewalIsDroppedWhenTheSavedTokenStillReadsUsage() async throws {
        let harness = makeHarness(expired: true)
        defer { harness.session.invalidateAndCancel() }
        IdentityProtocol.configure(token: (403, #"{"error":"invalid_client"}"#), usage: (200, windows))
        let result = try await harness.provider.fetchUsage(for: account)
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(result.bars.first?.used, 42)
    }

    func testRenewedTokenThatClaudeStillRefusesIsNotASignInPrompt() async throws {
        let harness = makeHarness(expired: true)
        defer { harness.session.invalidateAndCancel() }
        IdentityProtocol.configure(token: (200, #"{"access_token":"renewed-token","expires_in":3600}"#), usage: (401, ""))
        let result = try await harness.provider.fetchUsage(for: account)
        let declined = "Claude declined CodexBar's usage request (HTTP 401). Your sign-in was not changed."
        XCTAssertEqual(result.failureMessage, declined)
        XCTAssertEqual(result.recoveryAction, .retryRefresh)
        XCTAssertEqual(IdentityProtocol.requests.filter { $0.url?.path == "/api/oauth/usage" }.count, 1)

        // The next refresh needs no renewal. The same answer must not turn into a sign-in prompt.
        IdentityProtocol.configure(token: (500, ""), usage: (401, ""))
        let retried = try await harness.provider.fetchUsage(for: account)
        XCTAssertEqual(retried.failureMessage, declined)
        XCTAssertEqual(retried.recoveryAction, .retryRefresh)
        XCTAssertTrue(IdentityProtocol.requests.allSatisfy { $0.url?.path != "/v1/oauth/token" })

        // Once the renewed token has read usage, a later 401 is an ordinary rejected sign-in again.
        IdentityProtocol.configure(token: (500, ""), usage: (200, windows))
        let recovered = try await harness.provider.fetchUsage(for: account)
        XCTAssertNil(recovered.failureMessage)
        IdentityProtocol.configure(token: (500, ""), usage: (401, ""))
        let rejected = try await harness.provider.fetchUsage(for: account)
        XCTAssertEqual(rejected.failureMessage, "Claude credential was rejected. Sign in again.")
        XCTAssertEqual(rejected.recoveryAction, .reauthenticate)
    }

    func testUsageRefusalsFollowClaudesStatedReason() async throws {
        // The scope wording is from a public report; the 403 pairing here is a synthetic fixture.
        let scope = #"{"error":{"message":"OAuth token does not meet scope requirement user:profile"}}"#
        let permission = "Claude says this sign-in does not include permission to read usage. Sign in again to grant it."
        let cases: [(usage: (Int, String), message: String, action: ProviderUsageRecoveryAction)] = [
            ((403, scope), permission, .reauthenticate),
            ((401, scope), permission, .reauthenticate),
            ((403, #"{"error":{"message":"Request not allowed"}}"#),
             "Claude declined CodexBar's usage request (HTTP 403). Your sign-in was not changed.", .retryRefresh),
            ((401, ""), "Claude credential was rejected. Sign in again.", .reauthenticate),
            ((400, ""), "Claude declined CodexBar's usage request (HTTP 400). Your sign-in was not changed.", .retryRefresh),
            ((402, "{}"), "Claude declined CodexBar's usage request (HTTP 402). Your sign-in was not changed.", .retryRefresh),
        ]
        for testCase in cases {
            let harness = makeHarness(expired: false)
            defer { harness.session.invalidateAndCancel() }
            let saved = try harness.secrets.readSecret(account: "")
            IdentityProtocol.configure(token: (500, ""), usage: testCase.usage)
            let result = try await harness.provider.fetchUsage(for: account)
            XCTAssertEqual(result.failureMessage, testCase.message)
            XCTAssertEqual(result.recoveryAction, testCase.action, testCase.message)
            let usage = IdentityProtocol.requests.filter { $0.url?.path == "/api/oauth/usage" }
            XCTAssertEqual(usage.count, 1, testCase.message)
            XCTAssertEqual(usage.first?.value(forHTTPHeaderField: "User-Agent"), "CodexBarIOS")
            XCTAssertTrue(IdentityProtocol.requests.allSatisfy { $0.url?.path != "/v1/oauth/token" })
            XCTAssertEqual(try harness.secrets.readSecret(account: ""), saved, testCase.message)
        }
    }

    func testDeclinedRequestKeepsLastKnownUsage() async throws {
        let harness = makeHarness(expired: false)
        defer { harness.session.invalidateAndCancel() }
        IdentityProtocol.configure(token: (500, ""), usage: (200, windows))
        let fresh = try await harness.provider.fetchUsage(for: account)
        IdentityProtocol.configure(token: (500, ""), usage: (403, ""))
        let declined = try await harness.provider.fetchUsage(for: account)
        XCTAssertEqual(declined.bars, fresh.bars)
        XCTAssertEqual(declined.failureMessage, "Claude declined CodexBar's usage request (HTTP 403). Your sign-in was not changed.")
        XCTAssertTrue(declined.subtitle.hasSuffix("Showing last known data."))
    }

    func testNoFileThatReachesClaudeNamesAnotherClientOrSetsItsOwnUserAgent() throws {
        let services = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CodexBarIOS/Services")
        // Chosen by content, not by name, so a new file that talks to Claude is covered without edits here.
        let hosts = ["anthropic.com", "claude.ai", "claude.com"]
        var sources: [String: String] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: services, includingPropertiesForKeys: nil)
        where file.pathExtension == "swift" && file.lastPathComponent != "UITestFixtures.swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            if hosts.contains(where: source.contains) { sources[file.lastPathComponent] = source }
        }
        let expected = [
            "ClaudeUsageProvider.swift", "ClaudeWebAuthService.swift", "ClaudePlanProfileClient.swift",
            "ClaudeUsageResetClient.swift", "SubscriptionBillingClient.swift",
        ]
        for required in expected {
            XCTAssertNotNil(sources[required], "\(required) was expected to reach a Claude host")
        }
        func count(_ needle: String, in source: String) -> Int { source.components(separatedBy: needle).count - 1 }
        for (name, source) in sources {
            for forbidden in ["claude-code", "claude-cli", "claude_code", "x-app"] {
                XCTAssertFalse(source.lowercased().contains(forbidden), "\(name) names another client: \(forbidden)")
            }
            let direct = count("forHTTPHeaderField: \"User-Agent\"", in: source)
            switch name {
            case "ClaudeWebAuthService.swift":
                XCTAssertEqual(direct, 1, "Only ClaudeClientIdentity sets the header here")
            case "SubscriptionBillingClient.swift":
                // Its request helper is shared with Grok, so it sets the header itself, from the same constant.
                XCTAssertEqual(direct, 1)
                XCTAssertEqual(count("ClaudeClientIdentity.userAgent, forHTTPHeaderField: \"User-Agent\"", in: source), 1)
            default:
                XCTAssertEqual(direct, 0, "\(name) must set its user agent through ClaudeClientIdentity")
            }
            if name.hasPrefix("Claude") {
                // Every request these files build carries the identity.
                XCTAssertEqual(count("URLRequest(", in: source), count("ClaudeClientIdentity.apply(to:", in: source), name)
            }
        }
    }

    private func makeHarness(expired: Bool) -> (provider: ClaudeUsageProvider, secrets: IdentitySecrets, session: URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IdentityProtocol.self]
        let session = URLSession(configuration: configuration)
        let expiry = now.addingTimeInterval(expired ? -60 : 3_600).timeIntervalSince1970 * 1_000
        let secrets = IdentitySecrets(ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            subscriptionType: "max", expiresAt: Int64(expiry), accessToken: "saved-token", refreshToken: "saved-refresh"
        )))
        let clock = now
        return (ClaudeUsageProvider(secretStore: secrets, session: session, now: { clock }), secrets, session)
    }
}

private final class IdentitySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secret: String
    init(_ secret: String) { self.secret = secret }
    func readSecret(account: String) throws -> String? { lock.withLock { secret } }
    func saveSecret(_ secret: String, account: String) throws { lock.withLock { self.secret = secret } }
    func deleteSecret(account: String) throws { lock.withLock { secret = "" } }
}

private class IdentityProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var token = (500, "")
    nonisolated(unsafe) private static var usage = (500, "")
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func configure(token: (Int, String), usage: (Int, String)) {
        lock.withLock { self.token = token; self.usage = usage; recorded = [] }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var recordedRequest = request
        if recordedRequest.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            recordedRequest.httpBody = data
        }
        let reply: (Int, String) = Self.lock.withLock {
            Self.recorded.append(recordedRequest)
            switch request.url?.path {
            case "/v1/oauth/token": return Self.token
            case "/api/oauth/usage": return Self.usage
            default: return (404, "")
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
