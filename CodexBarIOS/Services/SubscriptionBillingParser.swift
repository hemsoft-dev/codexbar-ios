import CoreFoundation
import Foundation

/// Parses provider billing contracts only, never quota-window timestamps.
enum SubscriptionBillingParser {
    static func claude(_ data: Data, configuration: ProviderAccountConfiguration, at now: Date) -> SubscriptionRenewal? {
        guard let root = object(data), let status = root["status"] as? String,
              ["active", "trialing", "canceled"].contains(status) else { return nil }
        let keys = ["next_charge_at", "next_charge_date", "plan_ending_at", "plan_ending_before"]
        // The first-party client treats timestamp and legacy calendar fields as alternatives.
        guard keys.contains(where: { root[$0] != nil }),
              keys.allSatisfy({ root[$0] == nil || root[$0] is NSNull || (root[$0] as? String).flatMap(date) != nil }),
              root["payment_paused_until"] == nil || root["payment_paused_until"] is NSNull else { return nil }
        let ending = (root["plan_ending_at"] as? String).flatMap(date) ?? (root["plan_ending_before"] as? String).flatMap(date)
        let next = (root["next_charge_at"] as? String).flatMap(date) ?? (root["next_charge_date"] as? String).flatMap(date)
        let isRenewing = ending == nil && status != "canceled"
        guard !isRenewing || next != nil else { return nil }
        let value = isRenewing ? next : ending
        return SubscriptionRenewal(accountID: configuration.id, providerID: .claude,
                                   state: isRenewing ? .renewing : .nonRenewing,
                                   date: value?.value, isDateOnly: value?.isDateOnly ?? false, observedAt: now)
    }

    static func grokOwner(_ data: Data, expectedOwner: String) throws -> [[String: Any]] {
        guard let rows = object(data)?["subscriptions"] as? [[String: Any]], !rows.isEmpty else { throw SubscriptionBillingError.unavailable }
        guard rows.allSatisfy({ $0["xaiUserId"] as? String == expectedOwner }) else { throw SubscriptionBillingError.accountMismatch }
        return rows
    }

    static func grok(_ data: Data, configuration: ProviderAccountConfiguration, owner: String, at now: Date) -> SubscriptionRenewal? {
        guard let rows = try? grokOwner(data, expectedOwner: owner) else { return nil }
        let tiers = ["SUBSCRIPTION_TIER_SUPER_GROK_LITE", "SUBSCRIPTION_TIER_GROK_PRO",
                     "SUBSCRIPTION_TIER_SUPER_GROK_PLUS", "SUBSCRIPTION_TIER_SUPER_GROK_PRO",
        ]
        let active = rows.filter { row in
            row["status"] as? String == "SUBSCRIPTION_STATUS_ACTIVE" && ["stripe", "apple", "google"].contains { row[$0] is [String: Any] }
        }
        guard active.count == 1, let row = active.first, tiers.contains(row["tier"] as? String ?? ""),
              row["lapsedPaymentInfo"] == nil || row["lapsedPaymentInfo"] is NSNull else { return nil }
        // Personal purchases only. X-derived access and team/API/complimentary grants are separate products.
        let sources = ["stripe", "apple", "google"].filter { row[$0] is [String: Any] }
        guard sources.count == 1,
              ["x", "enterprise", "eapi", "adhoc"].allSatisfy({ row[$0] == nil || row[$0] is NSNull }) else { return nil }
        let flag: Bool?
        let rawDate: String?
        if let stripe = row["stripe"] as? [String: Any] {
            flag = boolean(stripe["cancelAtPeriodEnd"]).map { !$0 }
            rawDate = stripe["currentPeriodEnd"] as? String
        } else if let google = row["google"] as? [String: Any] {
            flag = boolean(google["autoRenewEnabled"])
            rawDate = google["expiryTime"] as? String
        } else if let apple = row["apple"] as? [String: Any] {
            flag = boolean(apple["autoRenewOn"])
            rawDate = row["billingPeriodEnd"] as? String
        } else { return nil }
        guard let renews = flag, let rawDate, let value = date(rawDate), !value.isDateOnly else { return nil }
        if let rawCancel = row["cancelAtPeriodEnd"], !(rawCancel is NSNull) {
            guard let cancel = boolean(rawCancel), cancel != renews else { return nil }
        }
        return SubscriptionRenewal(accountID: configuration.id, providerID: .grok, state: renews ? .renewing : .nonRenewing,
                                   date: value.value, observedAt: now)
    }

    static func object(_ data: Data) -> [String: Any]? {
        guard data.count <= 65_536 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    private struct BillingDate {
        let value: Date
        let isDateOnly: Bool
    }

    private static func date(_ text: String) -> BillingDate? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: text)
        formatter.formatOptions = [.withInternetDateTime]
        if let value = fractional ?? formatter.date(from: text) { return BillingDate(value: value, isDateOnly: false) }
        let civil = DateFormatter()
        civil.locale = Locale(identifier: "en_US_POSIX")
        civil.calendar = Calendar(identifier: .gregorian)
        civil.timeZone = TimeZone(secondsFromGMT: 0)
        civil.dateFormat = "yyyy-MM-dd"
        civil.isLenient = false
        guard text.count == 10, let value = civil.date(from: text), civil.string(from: value) == text else { return nil }
        return BillingDate(value: value, isDateOnly: true)
    }
}
