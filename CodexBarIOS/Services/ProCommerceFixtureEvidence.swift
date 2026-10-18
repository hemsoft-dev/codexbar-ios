#if DEBUG
import Foundation

/// Synthetic presentation evidence is deliberately separate from native StoreKit test transactions.
@MainActor
enum ProCommerceFixtureEvidence {
    static func snapshot(scenario: String) -> ProStoreSnapshot {
        if scenario == "commerce-cached" { return ProStoreSnapshot() }
        let original = scenario == "commerce-original" || scenario == "commerce-overlap-original"
        let environment: ProStoreEnvironment = original ? .production : .xcode
        var snapshot = ProStoreSnapshot(
            appPurchase: .verified(ProAppPurchase(
                originalVersion: original ? "4" : "5",
                originalPurchaseDate: ProOriginalPurchaserPolicy.cutover.addingTimeInterval(original ? -86_400 : 86_400),
                environment: environment, revoked: false, signedAt: ProCommerceFixture.instant
            )), subscriptionStatusAvailable: true
        )
        let permanent = scenario == "commerce-lifetime" || scenario == "commerce-overlap-lifetime" || scenario == "commerce-lifetime-billing"
        if permanent || scenario == "commerce-revoked" {
            snapshot.purchases.append(purchase(product: .lifetime, environment: environment, revoked: scenario == "commerce-revoked"))
        }
        let trial = scenario.hasPrefix("commerce-trial")
        let monthly = scenario.hasPrefix("commerce-monthly")
        let yearly = scenario.hasPrefix("commerce-yearly")
        let overlap = scenario.hasPrefix("commerce-overlap")
        let billing = ["commerce-grace", "commerce-retry", "commerce-lifetime-billing"].contains(scenario)
        let expired = scenario == "commerce-expired"
        guard trial || monthly || yearly || overlap || billing || expired else { return snapshot }
        let product: ProProductID = trial || yearly ? .yearly : .monthly
        let end = ProCommerceFixture.instant.addingTimeInterval((billing || expired ? -1 : trial ? 7 : 30) * 86_400)
        let purchase = purchase(product: product, environment: environment, expiresAt: end, trial: trial)
        let unknown = scenario.hasSuffix("unknown")
        let state: ProRenewalState = expired ? .expired : scenario == "commerce-grace" ? .grace : billing ? .billingRetry : .subscribed
        let nextProduct: ProProductID = scenario == "commerce-trial-monthly" ? .monthly : product
        let renewal = ProSubscriptionEvidence(
            purchase: purchase, signedAt: ProCommerceFixture.instant, state: state,
            renewalVerified: !unknown, willAutoRenew: unknown ? nil : !scenario.hasSuffix("off"),
            isInBillingRetry: billing,
            graceEndsAt: scenario == "commerce-grace" ? ProCommerceFixture.instant.addingTimeInterval(3 * 86_400) : nil,
            nextRenewalProduct: unknown ? nil : nextProduct,
            renewalPrice: unknown || scenario == "commerce-trial-no-price" ? nil : Decimal(string: nextProduct == .monthly ? "1.49" : "9.99"),
            renewalCurrency: unknown || scenario == "commerce-trial-no-price" ? nil : "USD"
        )
        snapshot.purchases.append(purchase)
        snapshot.subscriptions.append(renewal)
        return snapshot
    }

    static func status(purchase: ProPurchaseEvidence, renews: Bool) -> ProSubscriptionEvidence {
        ProSubscriptionEvidence(
            purchase: purchase, signedAt: purchase.signedAt, state: .subscribed,
            renewalVerified: true, willAutoRenew: renews, isInBillingRetry: false, graceEndsAt: nil,
            nextRenewalProduct: purchase.product, renewalPrice: price(for: purchase.product), renewalCurrency: "USD"
        )
    }

    static func price(for product: ProProductID) -> Decimal {
        switch product {
        case .monthly: Decimal(string: "1.99")!
        case .yearly: Decimal(string: "14.99")!
        case .lifetime: Decimal(string: "29.99")!
        }
    }

    static func title(for product: ProProductID) -> String {
        switch product {
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        case .lifetime: "Lifetime"
        }
    }

    private static func purchase(
        product: ProProductID, environment: ProStoreEnvironment, expiresAt: Date? = nil, revoked: Bool = false, trial: Bool = false
    ) -> ProPurchaseEvidence {
        ProPurchaseEvidence(
            product: product, transactionID: product == .lifetime ? 1 : 2,
            purchasedAt: ProCommerceFixture.instant.addingTimeInterval(-86_400), signedAt: ProCommerceFixture.instant,
            expiresAt: expiresAt, revoked: revoked, isFreeTrial: trial, environment: environment
        )
    }
}
#endif
