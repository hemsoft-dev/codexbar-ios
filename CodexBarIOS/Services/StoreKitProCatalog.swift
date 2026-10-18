import Foundation
import StoreKit

/// Products never leave the adapter. A catalog is tied to the storefront that supplied its terms.
@MainActor
final class StoreKitProCatalog {
    private var products: [ProProductID: Product] = [:]
    private var presented: ProCatalog?
    private var generation = 0

    func load() async throws -> ProCatalog {
        generation += 1
        let request = generation
        guard let storefront = await Storefront.current else { throw ProCommerceError.catalogUnavailable }
        let fetched = try await Product.products(for: ProProductID.allCases.map(\.rawValue))
        // Some runtimes report a failed lookup by returning no products instead of throwing.
        guard !fetched.isEmpty else { throw ProCommerceError.catalogUnavailable }
        var models: [ProProductID: ProCatalogProduct] = [:]
        var retained: [ProProductID: Product] = [:]
        for product in fetched {
            guard let identifier = ProProductID(rawValue: product.id) else { continue }
            let model = await Self.model(product, identifier: identifier, storefront: storefront.id)
            guard let model, model.hasExpectedShape else { continue }
            models[identifier] = model
            retained[identifier] = product
        }
        let currentStorefront = await Storefront.current
        try Task.checkCancellation()
        guard request == generation, currentStorefront?.id == storefront.id else { throw ProCommerceError.termsChanged }
        let catalog = ProCatalog(products: models, storefrontID: storefront.id)
        products = retained
        presented = catalog
        return catalog
    }

    func product(for identifier: ProProductID, matching expected: ProCatalogProduct) async throws -> Product {
        let request = generation
        let storefront = await Storefront.current
        try Task.checkCancellation()
        guard request == generation, storefront?.id == expected.storefrontID,
              presented?.products[identifier] == expected, let product = products[identifier] else {
            throw ProCommerceError.termsChanged
        }
        return product
    }

    func storefrontUpdates() -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                for await storefront in Storefront.updates {
                    guard !Task.isCancelled, let self else { break }
                    self.generation += 1
                    self.presented = nil
                    self.products.removeAll()
                    continuation.yield(storefront.id)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func model(_ product: Product, identifier: ProProductID, storefront: String) async -> ProCatalogProduct? {
        let type: ProCatalogProductType
        switch product.type {
        case .autoRenewable: type = .subscription
        case .nonConsumable: type = .nonConsumable
        default: return nil
        }
        let subscription = product.subscription
        let eligible = await subscription?.isEligibleForIntroOffer
        return ProCatalogProduct(
            id: identifier, displayName: product.displayName, displayPrice: product.displayPrice, type: type,
            period: subscription.flatMap { period($0.subscriptionPeriod) },
            subscriptionGroupID: subscription?.subscriptionGroupID,
            introductoryOffer: subscription?.introductoryOffer.flatMap(offer),
            introEligibility: eligible.map { $0 ? .eligible : .ineligible } ?? .unknown, storefrontID: storefront
        )
    }

    private static func offer(_ offer: Product.SubscriptionOffer) -> ProIntroductoryOffer? {
        guard let period = period(offer.period) else { return nil }
        return ProIntroductoryOffer(isFreeTrial: offer.paymentMode == .freeTrial, period: period, numberOfPeriods: offer.periodCount)
    }

    private static func period(_ period: Product.SubscriptionPeriod) -> ProSubscriptionPeriod? {
        let unit: ProPeriodUnit
        switch period.unit {
        case .day: unit = .day
        case .week: unit = .week
        case .month: unit = .month
        case .year: unit = .year
        @unknown default: return nil
        }
        return ProSubscriptionPeriod(value: period.value, unit: unit)
    }
}
