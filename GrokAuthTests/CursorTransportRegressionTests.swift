import Foundation
import XCTest
@testable import CodexBarIOS

final class CursorTransportRegressionTests: XCTestCase, @unchecked Sendable {
    func testOptionalFailureNeverErasesPrimarySpendingOrTheFourChoices() async throws {
        for reply in [(0, ""), (403, "{}"), (200, "{malformed")] {
            let result = try await fetch(optionalReply: reply)
            XCTAssertNil(result.failureMessage)
            XCTAssertEqual(result.bars.map(\.stableKey), ["cursor-models", "other-models", "on-demand"])
            XCTAssertEqual(result.bars.last?.used, 2003)
            XCTAssertEqual(result.configurableMetrics.count, 4)
            XCTAssertNotNil(result.unavailableUsageMetrics["cursor.grok-bot-weekly"])
            XCTAssertFalse(result.bars.contains { $0.stableKey == "grok-bot-weekly" })
        }
    }

    func testAccountCredentialsEndpointsAndWeeklyResetRemainIsolated() async throws {
        let weekly = #"""
            {"hasNonZeroIncludedLimit":true,"usagePercent":100,
            "nextResetTimestampUtc":"2026-10-02T00:00:00Z"}
            """#
        for identity in ["alpha", "beta"] {
            let result = try await fetch(optionalReply: (200, weekly), identity: identity)
            XCTAssertEqual(result.accountID, "cursor-fixture-\(identity)")
            XCTAssertEqual(Set(result.bars.compactMap(\.stableKey)), [
                "cursor-models", "other-models", "grok-bot-weekly", "on-demand",
            ])
            XCTAssertEqual(result.bars.first { $0.stableKey == "grok-bot-weekly" }?.used, 100)
            XCTAssertEqual(result.bars.first { $0.stableKey == "grok-bot-weekly" }?.resetsAt,
                           ISO8601DateFormatter().date(from: "2026-10-02T00:00:00Z"))
            let requests = CursorReplayProtocol.state.requests
            XCTAssertEqual(requests.count, 3)
            XCTAssertEqual(Set(requests.compactMap { $0.url?.host }), ["api2.cursor.sh"])
            XCTAssertEqual(Set(requests.compactMap { $0.url?.lastPathComponent }), [
                "GetCurrentPeriodUsage", "GetSandUsageStatus", "full_stripe_profile",
            ])
            XCTAssertTrue(requests.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-\(identity)"
                    && $0.value(forHTTPHeaderField: "Cookie") == nil
            })
        }
    }

    private func fetch(optionalReply: (Int, String), identity: String = "alpha") async throws -> ProviderUsageResult {
        CursorReplayProtocol.state.reset(optionalReply)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CursorReplayProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let account = ProviderAccountConfiguration(
            id: "cursor-fixture-\(identity)", providerID: .cursor,
            accountLabel: "Synthetic Cursor \(identity)", authMethod: .browserSession
        )
        let secrets = GrokTestSecrets()
        try secrets.saveSecret("fixture-\(identity)", account: ProviderConfigurationStore.keychainAccount(for: account))
        return try await CursorUsageProvider(secretStore: secrets, session: session).fetchUsage(for: account)
    }
}

private final class CursorReplayProtocol: URLProtocol, @unchecked Sendable {
    static let state = CursorReplayState()
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let reply = Self.state.reply(to: request)
        if reply.0 == 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class CursorReplayState: @unchecked Sendable {
    private let lock = NSLock()
    private var optionalReply = (200, "{}")
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }

    func reset(_ reply: (Int, String)) {
        lock.withLock { optionalReply = reply; recorded = [] }
    }

    func reply(to request: URLRequest) -> (Int, String) {
        lock.withLock {
            recorded.append(request)
            guard request.url?.lastPathComponent == "GetCurrentPeriodUsage" else { return optionalReply }
            return (200, #"""
                {"planUsage":{"autoPercentUsed":0,"apiPercentUsed":0},
                "spendLimitUsage":{"individualLimit":2000,"individualUsed":2003}}
                """#)
        }
    }
}
