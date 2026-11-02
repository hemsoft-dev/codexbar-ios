import Foundation
import XCTest
@testable import CodexBarIOS

@MainActor
final class ClaudeSubscriptionRenewalTests: XCTestCase {
    // Synthetic transport responses, never a captured account or live renewal.
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testPersonalPlanBillingReachesCountdownAndExactDate() async throws {
        for type in ["claude_pro", "claude_max", "claude_ultra"] {
            let fixture = try RenewalFixture(type: type)
            defer { fixture.session.invalidateAndCancel() }
            let result = try await ClaudeUsageProvider(secretStore: fixture.secrets, session: fixture.session,
                                                     now: { self.now }).fetchUsage(for: fixture.account)
            XCTAssertNil(result.failureMessage, type)
            XCTAssertFalse(result.bars.isEmpty, type)
            XCTAssertNil(result.subscriptionBillingProblem, type)
            let renewal = try XCTUnwrap(result.boundSubscriptionRenewal, type)
            XCTAssertEqual(renewal.date, now.addingTimeInterval(259_200), type)
            XCTAssertEqual(renewal.compactLabel(at: now), "Renews in 3d", type)
            XCTAssertEqual(result.subscriptionBillingInformation(at: now)?.items.first?.label, "Next subscription renewal", type)
            XCTAssertTrue(result.subscriptionBillingInformation(at: now)?.items.first?.detail.contains("2033") == true, type)
            XCTAssertEqual(RenewalProtocol.billingRequests, 1, type)
        }
    }
}

private struct RenewalFixture {
    let account = ProviderAccountConfiguration(id: "synthetic-claude", providerID: .claude, authMethod: .browserSession)
    let secrets = RenewalSecrets()
    let session: URLSession

    init(type: String) throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RenewalProtocol.self]
        session = URLSession(configuration: configuration)
        RenewalProtocol.configure(type: type)
        try secrets.saveSecret("synthetic-token", account: ProviderConfigurationStore.keychainAccount(for: account))
        let billing = SubscriptionBillingSession(providerID: .claude, ownerID: RenewalProtocol.owner,
                                                organizationID: RenewalProtocol.organization,
                                                cookies: [.init(name: "sessionKey", value: "synthetic", expiresAt: nil)])
        try secrets.saveSecret(billing.encoded(), account: SubscriptionBillingSession.keychainAccount(account))
    }
}

private final class RenewalSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func readSecret(account: String) throws -> String? { lock.withLock { values[account] } }
    func saveSecret(_ secret: String, account: String) throws { lock.withLock { values[account] = secret } }
    func deleteSecret(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

private class RenewalProtocol: URLProtocol, @unchecked Sendable {
    static let owner = "11111111-1111-4111-8111-111111111111"
    static let organization = "22222222-2222-4222-8222-222222222222"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var planType = "claude_max"
    nonisolated(unsafe) private static var billingCount = 0
    static var billingRequests: Int { lock.withLock { billingCount } }
    static func configure(type: String) { lock.withLock { planType = type; billingCount = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let type = Self.lock.withLock { Self.planType }
        let root: [String: Any]
        switch (url.host, url.path) {
        case ("api.anthropic.com", "/api/oauth/usage"):
            root = ["seven_day": ["utilization": 12, "resets_at": "2033-05-25T00:00:00Z"]]
        case ("api.anthropic.com", "/api/oauth/profile"):
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
            root = ["account": ["uuid": Self.owner],
                    "organization": ["uuid": Self.organization, "organization_type": type],
            ]
        case ("claude.ai", "/api/account"):
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sessionKey=synthetic")
            root = ["uuid": Self.owner, "memberships": [["organization": ["uuid": Self.organization]]]]
        case ("claude.ai", "/api/organizations/\(Self.organization)/subscription_details"):
            Self.lock.withLock { Self.billingCount += 1 }
            root = ["status": "active", "next_charge_at": "2033-05-21T03:33:20Z"]
        default:
            XCTFail("Unexpected request: \(url.host ?? "") \(url.path)")
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: root)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}
