import Foundation
@testable import CodexBarIOS

func commerceTestCatalog(storefront: String = "USA", yearlyPrice: String = "$14.99", eligibility: ProIntroEligibility = .eligible) -> ProCatalog {
    let products = ProProductID.allCases.map { product in
        let period: ProSubscriptionPeriod?
        let price: String
        switch product {
        case .monthly: period = ProSubscriptionPeriod(value: 1, unit: .month); price = "$1.99"
        case .yearly: period = ProSubscriptionPeriod(value: 1, unit: .year); price = yearlyPrice
        case .lifetime: period = nil; price = "$29.99"
        }
        return ProCatalogProduct(
            id: product, displayName: product.rawValue, displayPrice: price,
            type: product == .lifetime ? .nonConsumable : .subscription, period: period,
            subscriptionGroupID: product == .lifetime ? nil : "commerce-tests",
            introductoryOffer: product == .yearly ? ProIntroductoryOffer(
                isFreeTrial: true, period: ProSubscriptionPeriod(value: 1, unit: .week), numberOfPeriods: 1
            ) : nil,
            introEligibility: eligibility, storefrontID: storefront
        )
    }
    return ProCatalog(products: Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) }), storefrontID: storefront)
}

@MainActor
final class ProCommerceTestSource: ProStoreSource {
    var next = ProStoreSnapshot(subscriptionStatusAvailable: true)
    var catalogValue = commerceTestCatalog()
    var catalogError: Error?
    var purchaseError: Error?
    var restoreError: Error?
    var beforeCatalog: (() async -> Void)?
    var beforeSnapshot: (() async -> Void)?
    var beforePurchaseAuthorization: (() async -> Void)?
    var beforeRestore: (() async -> Void)?
    var purchaseOutcome: ProPurchaseOutcome = .cancelled
    var purchaseCalls: [ProProductID] = []
    var restoreCalls: [Bool] = []
    var catalogCalls = 0
    let transactions = AsyncStream<ProTransactionDelivery>.makeStream()
    let statuses = AsyncStream<ProSubscriptionUpdate>.makeStream()
    let storefronts = AsyncStream<String>.makeStream()

    func snapshot() async -> ProStoreSnapshot {
        await beforeSnapshot?()
        return next
    }
    func transactionUpdates() -> AsyncStream<ProTransactionDelivery> { transactions.stream }
    func subscriptionUpdates() -> AsyncStream<ProSubscriptionUpdate> { statuses.stream }
    func storefrontUpdates() -> AsyncStream<String> { storefronts.stream }
    func catalog() async throws -> ProCatalog {
        catalogCalls += 1
        let response = catalogValue
        await beforeCatalog?()
        if let catalogError { throw catalogError }
        return response
    }
    func purchase(_ product: ProProductID) async throws -> ProPurchaseOutcome {
        purchaseCalls.append(product)
        if let purchaseError { throw purchaseError }
        return purchaseOutcome
    }
    func purchase(
        _ product: ProProductID, expectedProduct: ProCatalogProduct,
        authorize: @MainActor () throws -> Void
    ) async throws -> ProPurchaseOutcome {
        await beforePurchaseAuthorization?()
        try authorize()
        return try await purchase(product)
    }
    func restore(refreshAppTransaction: Bool) async throws {
        restoreCalls.append(refreshAppTransaction)
        await beforeRestore?()
        if let restoreError { throw restoreError }
    }
}

func commerceTestStatus(
    _ product: ProProductID = .yearly, now: Date, renews: Bool? = true, state: ProRenewalState = .subscribed,
    verified: Bool = true, trial: Bool = false, offset: TimeInterval = 3600
) -> ProSubscriptionEvidence {
    ProSubscriptionEvidence(
        purchase: ProPurchaseEvidence(
            product: product, transactionID: product == .monthly ? 1 : 2, purchasedAt: now.addingTimeInterval(-3600),
            signedAt: now, expiresAt: now.addingTimeInterval(offset), isFreeTrial: trial
        ),
        signedAt: now, state: state, renewalVerified: verified, willAutoRenew: renews,
        isInBillingRetry: state == .billingRetry || state == .grace,
        graceEndsAt: state == .grace ? now.addingTimeInterval(7200) : nil,
        nextRenewalProduct: product
    )
}
