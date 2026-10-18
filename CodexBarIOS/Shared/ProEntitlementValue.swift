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

/// Only this identifier-free decision crosses the App Group boundary.
public struct ProEntitlementValue: Codable, Equatable, Sendable {
    public let reason: ProEntitlementReason
    public let expiresAt: Date?
    public let proAccessEndsAt: Date?
    public let verifiedAt: Date?
    public let subscriptionProduct: ProProductID?
    public let environment: ProStoreEnvironment
    public let purchasedAt: Date?

    public static let free = ProEntitlementValue(
        reason: .none, expiresAt: nil, proAccessEndsAt: nil, verifiedAt: nil
    )
    public static let offlineAllowance: TimeInterval = 3 * 24 * 60 * 60

    public init(
        reason: ProEntitlementReason, expiresAt: Date?, proAccessEndsAt: Date?, verifiedAt: Date?,
        subscriptionProduct: ProProductID? = nil, environment: ProStoreEnvironment = .production,
        purchasedAt: Date? = nil
    ) {
        self.reason = reason
        self.expiresAt = expiresAt
        self.proAccessEndsAt = proAccessEndsAt
        self.verifiedAt = verifiedAt
        self.subscriptionProduct = subscriptionProduct ?? Self.product(for: reason)
        self.environment = environment
        self.purchasedAt = purchasedAt
    }

    public func hasAccess(at date: Date) -> Bool {
        guard reason != .none, isValidCacheValue, let verifiedAt, verifiedAt <= date else { return false }
        return reason.isPermanent || proAccessEndsAt.map { date < $0 } == true
    }

    var isValidCacheValue: Bool {
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
