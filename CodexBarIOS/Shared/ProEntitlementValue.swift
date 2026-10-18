import Foundation

public enum ProStoreEnvironment: String, Codable, Sendable {
    case production, sandbox, xcode
}

public enum ProProductID: String, CaseIterable, Codable, Sendable {
    case monthly = "com.hemsoft.CodexBarIOS.pro.monthly"
    case yearly = "com.hemsoft.CodexBarIOS.pro.yearly"
    case lifetime = "com.hemsoft.CodexBarIOS.pro.lifetime"
}

public enum ProEntitlementReason: String, Codable, Sendable {
    case originalPurchaser, lifetime, yearly, monthly, trial, billingGrace, none

    public var isPermanent: Bool {
        self == .originalPurchaser || self == .lifetime
    }
}

/// Only this decision and local timing evidence cross the App Group boundary.
public struct ProEntitlementValue: Codable, Equatable, Sendable {
    public let reason: ProEntitlementReason
    public let expiresAt: Date?
    public let proAccessEndsAt: Date?
    public let verifiedAt: Date?
    public let subscriptionProduct: ProProductID?
    public let environment: ProStoreEnvironment
    public let purchasedAt: Date?
    public let clockAnchor: ProEntitlementClockAnchor?

    public static let free = ProEntitlementValue(
        reason: .none, expiresAt: nil, proAccessEndsAt: nil, verifiedAt: nil
    )
    public static let offlineAllowance: TimeInterval = 3 * 24 * 60 * 60

    public init(
        reason: ProEntitlementReason, expiresAt: Date?, proAccessEndsAt: Date?, verifiedAt: Date?,
        subscriptionProduct: ProProductID? = nil, environment: ProStoreEnvironment = .production,
        purchasedAt: Date? = nil, clockAnchor: ProEntitlementClockAnchor? = nil
    ) {
        self.reason = reason
        self.expiresAt = expiresAt
        self.proAccessEndsAt = proAccessEndsAt
        self.verifiedAt = verifiedAt
        self.subscriptionProduct = subscriptionProduct ?? Self.product(for: reason)
        self.environment = environment
        self.purchasedAt = purchasedAt
        self.clockAnchor = clockAnchor
    }

    public func hasAccess(at date: Date) -> Bool {
        hasAccess(at: ProEntitlementSystemClock.sample(at: date))
    }

    public func hasAccess(at sample: ProEntitlementClockSample) -> Bool {
        guard reason != .none, isValidCacheValue else { return false }
        if reason.isPermanent { return true }
        guard let date = clockAnchor?.effectiveDate(at: sample), let verifiedAt, verifiedAt <= date else { return false }
        return proAccessEndsAt.map { date < $0 } == true
    }

    func withClockAnchor(_ anchor: ProEntitlementClockAnchor?) -> Self {
        Self(
            reason: reason, expiresAt: expiresAt, proAccessEndsAt: proAccessEndsAt, verifiedAt: verifiedAt,
            subscriptionProduct: subscriptionProduct, environment: environment, purchasedAt: purchasedAt, clockAnchor: anchor
        )
    }

    func withoutAccess(at sample: ProEntitlementClockSample) -> Self {
        let anchor: ProEntitlementClockAnchor?
        if let existing = clockAnchor, let date = existing.effectiveDate(at: sample) {
            anchor = ProEntitlementClockAnchor(
                anchorDate: date, continuousSeconds: sample.continuousSeconds,
                continuityID: existing.continuityID, latestSignedAt: existing.latestSignedAt
            )
        } else { anchor = clockAnchor }
        return Self(
            reason: .none, expiresAt: nil, proAccessEndsAt: nil, verifiedAt: verifiedAt,
            environment: environment, clockAnchor: anchor
        )
    }

    var isValidCacheValue: Bool {
        guard clockAnchor?.isValid != false else { return false }
        if reason == .none { return expiresAt == nil && proAccessEndsAt == nil && subscriptionProduct == nil }
        guard let verifiedAt, verifiedAt.timeIntervalSince1970.isFinite else { return false }
        if reason.isPermanent { return expiresAt == nil && proAccessEndsAt == nil && subscriptionProduct == nil }
        guard subscriptionProduct == .monthly || subscriptionProduct == .yearly else { return false }
        if reason != .billingGrace, subscriptionProduct != Self.product(for: reason) { return false }
        guard let expiresAt, let proAccessEndsAt,
              expiresAt.timeIntervalSince1970.isFinite, proAccessEndsAt.timeIntervalSince1970.isFinite else { return false }
        return proAccessEndsAt == expiresAt.addingTimeInterval(Self.offlineAllowance)
    }

    private static func product(for reason: ProEntitlementReason) -> ProProductID? {
        switch reason {
        case .monthly: .monthly
        case .yearly, .trial: .yearly
        default: nil
        }
    }
}
