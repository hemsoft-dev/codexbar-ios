import Foundation

enum ProVerification<Value: Sendable>: Sendable {
    case verified(Value)
    case unverified
    case unavailable
}

struct ProAppPurchase: Sendable {
    let originalVersion: String
    let originalPurchaseDate: Date
    let environment: ProStoreEnvironment
    let revoked: Bool
    var signedAt: Date?
    var isProduction: Bool { environment == .production }
}

/// Transaction identifiers stay in memory to order updates. They are never cached or logged.
struct ProPurchaseEvidence: Equatable, Sendable {
    let product: ProProductID
    let transactionID: UInt64
    let purchasedAt: Date
    let signedAt: Date
    var expiresAt: Date?
    var revoked = false
    var upgraded = false
    var isFreeTrial = false
    var environment: ProStoreEnvironment = .production

    func isNewer(than other: Self) -> Bool {
        if purchasedAt != other.purchasedAt { return purchasedAt > other.purchasedAt }
        return signedAt > other.signedAt
    }
}

enum ProRenewalState: Sendable {
    case subscribed, expired, billingRetry, grace, revoked
}

struct ProSubscriptionEvidence: Sendable {
    var purchase: ProPurchaseEvidence
    let signedAt: Date
    let state: ProRenewalState
    let renewalVerified: Bool
    let willAutoRenew: Bool?
    let isInBillingRetry: Bool
    let graceEndsAt: Date?
    var nextRenewalProduct: ProProductID?
    var renewalPrice: Decimal?
    var renewalCurrency: String?

    func deniesAccess(at date: Date) -> Bool {
        if purchase.revoked || purchase.upgraded { return true }
        guard renewalVerified else { return false }
        if state == .revoked { return true }
        if let graceEndsAt, graceEndsAt > date { return false }
        if state == .expired { return true }
        if state == .billingRetry || isInBillingRetry {
            // A previously verified grace record aging out offline is not a new denial from Apple.
            if let graceEndsAt, signedAt < graceEndsAt { return false }
            return true
        }
        return state == .grace && graceEndsAt == nil
    }
}

struct ProUnverifiedPurchase: Hashable, Sendable {
    let product: ProProductID
    let environment: ProStoreEnvironment
}

/// Created only from the verified response to an explicit AppTransaction.refresh request.
struct ProFreshClockEvidence: Sendable {
    let signedAt: Date
    let environment: ProStoreEnvironment
}

struct ProStoreSnapshot: Sendable {
    var appPurchase: ProVerification<ProAppPurchase> = .unavailable
    var appVerificationEnvironment: ProStoreEnvironment?
    var purchases: [ProPurchaseEvidence] = []
    var unverifiedPurchases: Set<ProUnverifiedPurchase> = []
    var subscriptions: [ProSubscriptionEvidence] = []
    var subscriptionStatusAvailable = false
    /// The current complete group inventory, separate from historical latest transactions.
    var subscriptionStatusProducts: Set<ProProductID>?
    var freshClockEvidence: ProFreshClockEvidence?
    var unverifiedProducts: Set<ProProductID> { Set(unverifiedPurchases.map(\.product)) }

    /// Call only with a StoreKit-verified AppTransaction and its signed JSON payload.
    mutating func appendVerifiedAppPurchase(
        originalVersion: String, originalPurchaseDate: Date, environment: ProStoreEnvironment,
        signedAt: Date, jsonRepresentation: Data
    ) {
        appVerificationEnvironment = environment
        do {
            // AppTransaction.revocationDate is absent from the release SDK. Decode its signed field instead.
            let payload = try JSONDecoder().decode(ProAppTransactionPayload.self, from: jsonRepresentation)
            appPurchase = .verified(ProAppPurchase(
                originalVersion: originalVersion, originalPurchaseDate: originalPurchaseDate,
                environment: environment, revoked: payload.appRevocationDate != nil, signedAt: signedAt
            ))
        } catch {
            // Invalid signed data must deny a cached grant, unlike a temporarily unavailable AppTransaction.
            appPurchase = .unverified
        }
    }

    var latestSignedAt: Date? {
        var dates = purchases.map(\.signedAt)
        dates += subscriptions.filter(\.renewalVerified).map(\.signedAt)
        if case let .verified(app) = appPurchase, let signedAt = app.signedAt { dates.append(signedAt) }
        if let freshClockEvidence { dates.append(freshClockEvidence.signedAt) }
        return dates.filter { $0.timeIntervalSinceReferenceDate.isFinite }.max()
    }
}

private struct ProAppTransactionPayload: Decodable {
    let appRevocationDate: Int64?
}

enum ProSubscriptionUpdate: Sendable {
    case verified(ProSubscriptionEvidence)
    case unverified(product: ProProductID, environment: ProStoreEnvironment)
}

@MainActor
struct ProTransactionDelivery {
    let product: ProProductID
    let evidence: ProVerification<ProPurchaseEvidence>
    var environment: ProStoreEnvironment?
    let finish: @MainActor () async -> Void
}

enum ProPurchaseOutcome {
    case purchased(ProTransactionDelivery)
    case pending
    case cancelled
}

@MainActor
protocol ProStoreSource: AnyObject {
    func snapshot() async -> ProStoreSnapshot
    func transactionUpdates() -> AsyncStream<ProTransactionDelivery>
    func subscriptionUpdates() -> AsyncStream<ProSubscriptionUpdate>
    func purchase(_ product: ProProductID) async throws -> ProPurchaseOutcome
    func catalog() async throws -> ProCatalog
    func storefrontUpdates() -> AsyncStream<String>
    func purchase(
        _ product: ProProductID, expectedProduct: ProCatalogProduct,
        authorize: @MainActor () throws -> Void
    ) async throws -> ProPurchaseOutcome
    func restore(refreshAppTransaction: Bool) async throws
}

extension ProStoreSource {
    func catalog() async throws -> ProCatalog { throw ProCommerceError.catalogUnavailable }
    func storefrontUpdates() -> AsyncStream<String> { AsyncStream { $0.finish() } }
    func purchase(
        _ product: ProProductID, expectedProduct: ProCatalogProduct,
        authorize: @MainActor () throws -> Void
    ) async throws -> ProPurchaseOutcome {
        try Task.checkCancellation()
        try authorize()
        return try await purchase(product)
    }
}
