#if DEBUG
import Foundation

/// Simulator-only transport exercises the real billing client and owner checks without a live account.
final class UITestSubscriptionBillingProtocol: URLProtocol, @unchecked Sendable {
    static let claudeOwner = "11111111-1111-4111-8111-111111111111"
    static let claudeOrganization = "22222222-2222-4222-8222-222222222222"

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UITestSubscriptionBillingProtocol.self]
        return URLSession(configuration: configuration)
    }

    // URLProtocol requires overridable class methods.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // URLProtocol requires overridable class methods.
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let wrong = request.value(forHTTPHeaderField: "Cookie")?.contains("=wrong") == true
        let date = ISO8601DateFormatter().string(from: Date().addingTimeInterval(259_200))
        let body: String
        switch url.path {
        case "/api/oauth/profile":
            body = "{\"account\":{\"uuid\":\"\(Self.claudeOwner)\"},\"organization\":{\"uuid\":\"\(Self.claudeOrganization)\",\"organization_type\":\"claude_max\"}}"
        case "/api/account":
            body = "{\"uuid\":\"\(wrong ? "other-account" : Self.claudeOwner)\",\"memberships\":[{\"organization\":{\"uuid\":\"\(Self.claudeOrganization)\"}}]}"
        case "/rest/subscriptions":
            body = "{\"subscriptions\":[{\"xaiUserId\":\"\(wrong ? "other-account" : "synthetic-user")\",\"tier\":\"SUBSCRIPTION_TIER_GROK_PRO\",\"status\":\"SUBSCRIPTION_STATUS_ACTIVE\",\"stripe\":{\"currentPeriodEnd\":\"\(date)\",\"cancelAtPeriodEnd\":false}}]}"
        default:
            guard url.path == "/api/organizations/\(Self.claudeOrganization)/subscription_details" else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            body = "{\"status\":\"active\",\"next_charge_at\":\"\(date)\",\"plan_ending_at\":null}"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
