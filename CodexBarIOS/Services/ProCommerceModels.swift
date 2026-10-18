import Foundation

enum ProIntroEligibility: Equatable, Sendable { case unknown, eligible, ineligible }
enum ProCatalogProductType: Equatable, Sendable { case subscription, nonConsumable }
enum ProPeriodUnit: Equatable, Sendable { case day, week, month, year }

struct ProSubscriptionPeriod: Equatable, Sendable {
    let value: Int
    let unit: ProPeriodUnit
}

struct ProIntroductoryOffer: Equatable, Sendable {
    let isFreeTrial: Bool
    let period: ProSubscriptionPeriod
    let numberOfPeriods: Int

    var isSevenDayFreeTrial: Bool {
        guard isFreeTrial, numberOfPeriods > 0 else { return false }
        switch period.unit {
        case .day: return period.value == 7 && numberOfPeriods == 1 || period.value == 1 && numberOfPeriods == 7
        case .week: return period.value == 1 && numberOfPeriods == 1
        case .month, .year: return false
        }
    }
}

struct ProCatalogProduct: Equatable, Identifiable, Sendable {
    let id: ProProductID
    let displayName: String
    let displayPrice: String
    let type: ProCatalogProductType
    let period: ProSubscriptionPeriod?
    let subscriptionGroupID: String?
    let introductoryOffer: ProIntroductoryOffer?
    let introEligibility: ProIntroEligibility
    let storefrontID: String

    var hasExpectedShape: Bool {
        switch id {
        case .monthly: return type == .subscription && period == ProSubscriptionPeriod(value: 1, unit: .month)
        case .yearly: return type == .subscription && period == ProSubscriptionPeriod(value: 1, unit: .year)
        case .lifetime: return type == .nonConsumable && period == nil
        }
    }

    var offersSevenDayTrial: Bool {
        id == .yearly && hasExpectedShape && introEligibility == .eligible && introductoryOffer?.isSevenDayFreeTrial == true
    }

    var periodDescription: String {
        switch id {
        case .monthly: "per month"
        case .yearly: "per year"
        case .lifetime: "once"
        }
    }
}

struct ProCatalog: Equatable, Sendable {
    let products: [ProProductID: ProCatalogProduct]
    let storefrontID: String

    var subscriptionGroupID: String? {
        let groups = Set(products.values.compactMap(\.subscriptionGroupID))
        return groups.count == 1 ? groups.first : nil
    }
}

enum ProCatalogState: Equatable, Sendable {
    case idle
    case loading
    case loaded(ProCatalog)
    case failed(String)

    var loadedCatalog: ProCatalog? {
        if case let .loaded(catalog) = self { return catalog }
        return nil
    }
}

enum ProCommerceCommand: Equatable, Sendable { case purchase(ProProductID), restore }
enum ProPurchaseContext: Equatable, Sendable { case standard, settingsLifetime }
enum ProPurchaseResult: Equatable, Sendable { case purchased, pending, cancelled }
public enum ProRestoreResult: Equatable, Sendable { case restored, noPurchases }
enum ProLifetimeAction: Equatable, Sendable { case available, manageSubscription, unavailable, alreadyPermanent }
enum ProPlanDateKind: Equatable, Sendable { case renews, expires, trialEnds }

enum ProCommerceError: LocalizedError, Equatable {
    case busy, checkingPurchases, alreadyHasPro, productUnavailable, catalogUnavailable
    case termsChanged, renewalUnknown, autoRenewEnabled, notCommitted

    var errorDescription: String? {
        switch self {
        case .busy: "Another purchase or Restore is in progress. Please wait."
        case .checkingPurchases: "Your purchases are still being checked. Try again shortly."
        case .alreadyHasPro: "You already have CodexBar Pro."
        case .productUnavailable: "This plan is unavailable from the App Store. Try again later."
        case .catalogUnavailable: "App Store prices could not be loaded. Try again."
        case .termsChanged: "The App Store terms have changed. Review the updated price and try again."
        case .renewalUnknown: "Renewal status is unavailable. Refresh or manage your subscription before buying lifetime."
        case .autoRenewEnabled: "Turn off subscription auto-renew in Apple’s subscription settings before buying lifetime."
        case .notCommitted: "The purchase could not be verified and saved. Try Restore Purchases."
        }
    }
}
