import CoreFoundation
import Foundation

/// Cursor's authenticated Stripe portal contract. Usage windows and invoices are never renewal evidence.
enum CursorSubscriptionBilling {
    struct Owner {
        let subject: String
        let canonicalID: String
        let cookie: String

        init?(_ credential: CursorSessionCredential) {
            let pieces = credential.accessToken.split(separator: ".", omittingEmptySubsequences: false)
            guard pieces.count == 3, pieces[1].count < 16_384 else { return nil }
            let payload = pieces[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let padded = payload + String(repeating: "=", count: (4 - payload.count % 4) % 4)
            guard let data = Data(base64Encoded: padded), let root = SubscriptionBillingParser.object(data),
                  let subject = root["sub"] as? String,
                  subject.range(of: "^[A-Za-z0-9_-]+[|][A-Za-z0-9_-]+$", options: .regularExpression) != nil,
                  let canonical = subject.split(separator: "|").last else { return nil }
            // This unsigned claim only routes the cookie. /api/auth/me must authenticate this exact owner.
            if let saved = credential.authID, saved != subject, saved != String(canonical) { return nil }
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            guard let value = "\(subject)::\(credential.accessToken)".addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            self.subject = subject
            canonicalID = String(canonical)
            cookie = "WorkosCursorSessionToken=\(value)"
        }
    }

    struct Profile: Equatable {
        let customerID: String
        let membership: String
        let yearly: Bool
        let status: String
        let pendingCancellation: String?
        let paymentFailed: Bool
        let hasRecovery: Bool

        init?(_ data: Data) {
            guard let root = SubscriptionBillingParser.object(data), boolean(root["isTeamMember"]) == false,
                  let membership = root["membershipType"] as? String, ["pro", "pro_plus", "ultra"].contains(membership),
                  let customer = root["paymentId"] as? String, matches(customer, "^cus_[A-Za-z0-9]+$"),
                  let yearly = boolean(root["isYearlyPlan"]), let failed = boolean(root["lastPaymentFailed"]),
                  let status = root["subscriptionStatus"] as? String, ["active", "canceled"].contains(status),
                  absent(root["pendingCancellationDate"]) || root["pendingCancellationDate"] is String else { return nil }
            customerID = customer
            self.membership = membership
            self.yearly = yearly
            self.status = status
            pendingCancellation = (root["pendingCancellationDate"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            paymentFailed = failed
            hasRecovery = !absent(root["paymentRecoveryAction"])
        }
    }

    struct Portal {
        let sessionID: String
        let key: String
        let merchant: String
        let version: String

        init?(_ data: Data) {
            guard let html = String(data: data, encoding: .utf8),
                  let range = html.range(of: #"<script\b[^>]*\bid=["']preloaded_json["'][^>]*>([\s\S]*?)</script>"#,
                                         options: [.regularExpression, .caseInsensitive]) else { return nil }
            let script = String(html[range])
            guard let start = script.firstIndex(of: ">"), let end = script.range(of: "</script>", options: .caseInsensitive)?.lowerBound else { return nil }
            var json = String(script[script.index(after: start)..<end])
            for (entity, value) in [("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
                json = json.replacingOccurrences(of: entity, with: value)
            }
            guard let root = SubscriptionBillingParser.object(Data(json.utf8)), boolean(root["livemode"]) == true,
                  boolean(root["portal_session_expired"]) == false,
                  let session = root["portal_session_id"] as? String, matches(session, "^bps_[A-Za-z0-9]+$"),
                  let key = root["session_api_key"] as? String, matches(key, "^[A-Za-z0-9_]{10,1024}$"),
                  let merchant = (root["merchant"] as? [String: Any])?["id"] as? String, matches(merchant, "^acct_[A-Za-z0-9]+$"),
                  let version = root["current_version"] as? String, matches(version, "^[A-Za-z0-9.;=_ -]{1,256}$") else { return nil }
            sessionID = session
            self.key = key
            self.merchant = merchant
            self.version = version
        }

        func owns(_ data: Data, customer: String) -> Bool {
            guard let root = SubscriptionBillingParser.object(data) else { return false }
            return root["id"] as? String == sessionID && root["customer"] as? String == customer && boolean(root["livemode"]) == true
        }
    }

    static func portalURL(_ data: Data) -> URL? {
        let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        let object = value as? [String: Any]
        guard let text = value as? String ?? object?["portalUrl"] as? String ?? object?["url"] as? String,
              let url = URL(string: text), url.scheme == "https", url.host == "billing.stripe.com",
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              url.path.hasPrefix("/p/session/") else { return nil }
        return url
    }

    static func observation(_ data: Data, profile: Profile, configuration: ProviderAccountConfiguration, at now: Date) -> SubscriptionRenewal? {
        guard configuration.providerID == .cursor, let root = SubscriptionBillingParser.object(data),
              root["object"] as? String == "list", boolean(root["has_more"]) == false,
              let subscriptions = root["data"] as? [[String: Any]] else { return nil }
        let candidates = subscriptions.filter { subscription in
            guard let items = subscription["items"] as? [[String: Any]] else { return false }
            return items.contains { item in
                let price = item["price_details"] as? [String: Any]
                return ((price?["product"] as? [String: Any])?["name"] as? String)?.hasPrefix("Cursor ") == true
            }
        }
        guard candidates.count == 1, let subscription = candidates.first,
              validItem(subscription, profile: profile), let end = timestamp(subscription["current_period_end"]),
              let canceled = boolean(subscription["cancel_at_period_end"]), absent(subscription["ended_at"]),
              let status = subscription["status"] as? String, ["active", "canceled"].contains(status) else { return nil }
        let cancelDate = timestamp(subscription["cancel_at"])
        if !absent(subscription["cancel_at"]), cancelDate == nil { return nil }
        if canceled || cancelDate != nil {
            // A stop scheduled after another charge does not establish the next access-end date.
            guard cancelDate.map({ $0 <= end }) ?? true else { return nil }
            return SubscriptionRenewal(accountID: configuration.id, providerID: .cursor, state: .nonRenewing,
                                       date: min(end, cancelDate ?? end), observedAt: now)
        }
        guard status == "active", profile.status == "active", profile.pendingCancellation == nil,
              !profile.paymentFailed, !profile.hasRecovery,
              absent(subscription["pause_collection"]), absent(subscription["pending_update"]),
              absent(subscription["trial_end"]), boolean(subscription["has_update_scheduled"]) == false,
              boolean(subscription["is_mixed_interval"]) == false else { return nil }
        return SubscriptionRenewal(accountID: configuration.id, providerID: .cursor, state: .renewing, date: end, observedAt: now)
    }

    private static func validItem(_ subscription: [String: Any], profile: Profile) -> Bool {
        guard let items = subscription["items"] as? [[String: Any]], items.count == 1, let item = items.first,
              let price = item["price_details"] as? [String: Any], price["type"] as? String == "recurring",
              let product = price["product"] as? [String: Any], let name = product["name"] as? String,
              let recurring = price["recurring"] as? [String: Any],
              recurring["interval"] as? String == (profile.yearly ? "year" : "month"),
              let count = recurring["interval_count"] as? NSNumber, CFGetTypeID(count) != CFBooleanGetTypeID(), count == 1,
              let end = timestamp(subscription["current_period_end"]), timestamp(item["current_period_end"]) == end else { return false }
        let names = ["pro": ["Cursor Pro"], "pro_plus": ["Cursor Pro+", "Cursor Pro Plus"], "ultra": ["Cursor Ultra"]]
        return names[profile.membership]?.contains(name) == true
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
    private static func absent(_ value: Any?) -> Bool { value == nil || value is NSNull }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func timestamp(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let seconds = number.doubleValue
        guard seconds.isFinite, (1_577_836_800..<4_102_444_800).contains(seconds) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
