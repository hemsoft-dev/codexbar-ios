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

/// Signed denial ordering survives relaunch without retaining transaction identifiers.
public struct ProPurchaseDenial: Codable, Equatable, Sendable {
    public let product: ProProductID
    public let purchasedAt: Date
    public let signedAt: Date

    var isValid: Bool {
        purchasedAt.timeIntervalSinceReferenceDate.isFinite && signedAt.timeIntervalSinceReferenceDate.isFinite
    }

    func allows(purchasedAt: Date, signedAt: Date) -> Bool {
        purchasedAt > self.purchasedAt || (purchasedAt == self.purchasedAt && signedAt > self.signedAt)
    }
}

/// Verification uncertainty blocks another purchase without granting feature access.
public struct ProPurchaseVerificationUncertainty: Codable, Equatable, Sendable {
    public let products: Set<ProProductID>
    public let appPurchase: Bool
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
    public let purchaseDenials: [ProPurchaseDenial]
    public let appPurchaseDeniedAt: Date?
    public let verificationUncertainty: ProPurchaseVerificationUncertainty?

    public static let free = ProEntitlementValue(
        reason: .none, expiresAt: nil, proAccessEndsAt: nil, verifiedAt: nil
    )
    public static let offlineAllowance: TimeInterval = 3 * 24 * 60 * 60

    public init(
        reason: ProEntitlementReason, expiresAt: Date?, proAccessEndsAt: Date?, verifiedAt: Date?,
        subscriptionProduct: ProProductID? = nil, environment: ProStoreEnvironment = .production,
        purchasedAt: Date? = nil, clockAnchor: ProEntitlementClockAnchor? = nil,
        purchaseDenials: [ProPurchaseDenial] = [], appPurchaseDeniedAt: Date? = nil,
        verificationUncertainty: ProPurchaseVerificationUncertainty? = nil
    ) {
        self.reason = reason
        self.expiresAt = expiresAt
        self.proAccessEndsAt = proAccessEndsAt
        self.verifiedAt = verifiedAt
        self.subscriptionProduct = subscriptionProduct ?? Self.product(for: reason)
        self.environment = environment
        self.purchasedAt = purchasedAt
        self.clockAnchor = clockAnchor
        self.purchaseDenials = purchaseDenials
        self.appPurchaseDeniedAt = appPurchaseDeniedAt
        self.verificationUncertainty = verificationUncertainty
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
            subscriptionProduct: subscriptionProduct, environment: environment, purchasedAt: purchasedAt, clockAnchor: anchor,
            purchaseDenials: purchaseDenials, appPurchaseDeniedAt: appPurchaseDeniedAt,
            verificationUncertainty: verificationUncertainty
        )
    }

    func withPurchaseDenials(_ denials: [ProPurchaseDenial], appPurchaseDeniedAt: Date?) -> Self {
        Self(
            reason: reason, expiresAt: expiresAt, proAccessEndsAt: proAccessEndsAt, verifiedAt: verifiedAt,
            subscriptionProduct: subscriptionProduct, environment: environment, purchasedAt: purchasedAt,
            clockAnchor: clockAnchor, purchaseDenials: denials, appPurchaseDeniedAt: appPurchaseDeniedAt,
            verificationUncertainty: verificationUncertainty
        )
    }

    func withVerificationUncertainty(products: Set<ProProductID>, appPurchase: Bool) -> Self {
        let uncertainty = products.isEmpty && !appPurchase ? nil : ProPurchaseVerificationUncertainty(
            products: products, appPurchase: appPurchase
        )
        return Self(
            reason: reason, expiresAt: expiresAt, proAccessEndsAt: proAccessEndsAt, verifiedAt: verifiedAt,
            subscriptionProduct: subscriptionProduct, environment: environment, purchasedAt: purchasedAt,
            clockAnchor: clockAnchor, purchaseDenials: purchaseDenials, appPurchaseDeniedAt: appPurchaseDeniedAt,
            verificationUncertainty: uncertainty
        )
    }

    func withoutAccess(at sample: ProEntitlementClockSample) -> Self {
        return Self(
            reason: .none, expiresAt: nil, proAccessEndsAt: nil, verifiedAt: verifiedAt,
            environment: environment, clockAnchor: clockAnchor?.checkpoint(at: sample), purchaseDenials: purchaseDenials,
            appPurchaseDeniedAt: appPurchaseDeniedAt, verificationUncertainty: verificationUncertainty
        )
    }

    var isValidCacheValue: Bool {
        guard clockAnchor?.isValid != false, appPurchaseDeniedAt?.timeIntervalSinceReferenceDate.isFinite != false,
              purchaseDenials.allSatisfy(\.isValid),
              Set(purchaseDenials.map(\.product)).count == purchaseDenials.count else { return false }
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
