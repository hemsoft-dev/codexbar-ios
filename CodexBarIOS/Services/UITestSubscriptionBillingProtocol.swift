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

/// Sanitized shapes from the October 15 Cursor/Stripe read probe, never a live credential or date.
enum UITestCursorBillingFixture {
    static var credential: String {
        let payload = Data(#"{"sub":"fixture|synthetic-owner","exp":4102444800}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return CursorWebAuthResult(accessToken: "e30.\(payload).synthetic", refreshToken: nil, authID: "synthetic-owner", userID: nil).storedCredential
    }

    static func profile(yearly: Bool = false) -> String {
        """
        {"membershipType":"pro","paymentId":"cus_synthetic","subscriptionStatus":"active","isYearlyPlan":\(yearly),
        "isTeamMember":false,"lastPaymentFailed":false,"pendingCancellationDate":"","paymentRecoveryAction":null}
        """
    }

    static func subscriptions(end: Double, yearly: Bool = false, canceled: Bool = false) -> String {
        """
        {"object":"list","has_more":false,"data":[{"id":"sub_synthetic","object":"subscription","status":"active",
        "current_period_end":\(end),"cancel_at_period_end":\(canceled),"cancel_at":null,"ended_at":null,
        "pause_collection":null,"pending_update":null,"trial_end":null,"has_update_scheduled":false,"is_mixed_interval":false,
        "items":[{"current_period_end":\(end),"price_details":{"type":"recurring","product":{"name":"Cursor Pro"},
        "recurring":{"interval":"\(yearly ? "year" : "month")","interval_count":1}}}]}]}
        """
    }

    static let shell = """
        <html><script type="application/json" id="preloaded_json">{&quot;livemode&quot;:true,&quot;portal_session_expired&quot;:false,
        &quot;portal_session_id&quot;:&quot;bps_synthetic&quot;,&quot;session_api_key&quot;:&quot;synthetic_scoped_portal_key&quot;,
        &quot;merchant&quot;:{&quot;id&quot;:&quot;acct_synthetic&quot;},&quot;current_version&quot;:&quot;2025-04-30.basil&quot;}</script></html>
        """

    static func reply(_ request: URLRequest, scenario: String) -> (Int, String) {
        let yearly = scenario.contains("annual")
        let end = Date().addingTimeInterval(scenario.contains("past") ? -60 : yearly ? 31_536_000 : 259_200).timeIntervalSince1970
        switch request.url?.path {
        case "/aiserver.v1.DashboardService/GetCurrentPeriodUsage":
            return (200, #"{"planUsage":{"autoPercentUsed":12,"apiPercentUsed":8},"spendLimitUsage":{"individualLimit":2000,"individualUsed":24}}"#)
        case "/aiserver.v1.DashboardService/GetSandUsageStatus": return (200, #"{"hasNonZeroIncludedLimit":true,"usagePercent":12}"#)
        case "/auth/full_stripe_profile", "/api/auth/stripe": return (200, profile(yearly: yearly))
        case "/api/auth/me": return (200, #"{"sub":"synthetic-owner","id":123}"#)
        case "/api/stripeSession": return scenario.contains("unknown") ? (403, "{}") : (200, #""https://billing.stripe.com/p/session/synthetic""#)
        case "/p/session/synthetic": return (200, shell)
        case "/v1/billing_portal/sessions/bps_synthetic": return (200, #"{"id":"bps_synthetic","customer":"cus_synthetic","livemode":true}"#)
        case "/v1/billing_portal/sessions/bps_synthetic/subscriptions":
            return (200, subscriptions(end: end, yearly: yearly, canceled: scenario.contains("canceled")))
        default: return (404, "{}")
        }
    }
}

final class UITestCursorBillingProtocol: URLProtocol, @unchecked Sendable {
    static func session(scenario: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UITestCursorBillingProtocol.self]
        configuration.httpAdditionalHeaders = ["X-CodexBar-Test-Cursor-Scenario": scenario]
        return URLSession(configuration: configuration)
    }
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let reply = UITestCursorBillingFixture.reply(request, scenario: request.value(forHTTPHeaderField: "X-CodexBar-Test-Cursor-Scenario") ?? "")
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: reply.0, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
