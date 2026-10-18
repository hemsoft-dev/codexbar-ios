import Foundation
import XCTest
@testable import CodexBarIOS

final class ProCommercePolicyTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    func testTrialRequiresYearlySevenDayOfferAndResolvedEligibility() throws {
        let product = try XCTUnwrap(commerceTestCatalog().products[.yearly])
        XCTAssertTrue(product.offersSevenDayTrial)
        for eligibility: ProIntroEligibility in [.unknown, .ineligible] {
            XCTAssertFalse(commerceTestCatalog(eligibility: eligibility).products[.yearly]?.offersSevenDayTrial ?? true)
        }
        for identifier: ProProductID in [.monthly, .lifetime] {
            XCTAssertFalse(commerceTestCatalog().products[identifier]?.offersSevenDayTrial ?? true)
        }
        let noOffer = ProCatalogProduct(
            id: .yearly, displayName: "Yearly", displayPrice: "€19.99", type: .subscription,
            period: product.period, subscriptionGroupID: "test", introductoryOffer: nil,
            introEligibility: .eligible, storefrontID: "DEU"
        )
        XCTAssertFalse(noOffer.offersSevenDayTrial, "Eligibility alone is not a configured free trial")
    }

    func testOtherOfferLengthsAndPaidIntroDoNotAdvertiseSevenDays() {
        let invalid: [ProIntroductoryOffer] = [
            ProIntroductoryOffer(isFreeTrial: true, period: ProSubscriptionPeriod(value: 1, unit: .week), numberOfPeriods: 2),
            ProIntroductoryOffer(isFreeTrial: false, period: ProSubscriptionPeriod(value: 1, unit: .week), numberOfPeriods: 1),
            ProIntroductoryOffer(isFreeTrial: true, period: ProSubscriptionPeriod(value: 1, unit: .month), numberOfPeriods: 1),
        ]
        XCTAssertTrue(invalid.allSatisfy { !$0.isSevenDayFreeTrial })
        XCTAssertTrue(ProIntroductoryOffer(
            isFreeTrial: true, period: ProSubscriptionPeriod(value: 7, unit: .day), numberOfPeriods: 1
        ).isSevenDayFreeTrial)
    }

    func testUnknownResolutionHidesEverySaleAndBlocksCommand() {
        let presentation = present(.free, resolved: false)
        XCTAssertFalse(presentation.showsPurchaseOptions)
        XCTAssertThrowsError(try ProCommercePolicy.authorize(.monthly, context: .standard, presentation: presentation, isResolved: false)) {
            XCTAssertEqual($0 as? ProCommerceError, .checkingPurchases)
        }
    }

    func testPermanentPlanHidesSalesAndHasNoBillingDate() {
        for reason: ProEntitlementReason in [.lifetime, .originalPurchaser] {
            let presentation = present(value(reason))
            XCTAssertEqual(presentation.planTitle, "Lifetime Pro")
            XCTAssertFalse(presentation.showsPurchaseOptions)
            XCTAssertNil(presentation.periodEnd)
            XCTAssertNil(presentation.nextRenewalProduct)
            XCTAssertEqual(presentation.lifetimeAction, .alreadyPermanent)
        }
    }

    func testEveryRelevantSubscriptionBlocksLifetimeRegardlessOfMaximumExpiry() {
        let yearly = commerceTestStatus(now: instant, renews: false, offset: 86400)
        let monthly = commerceTestStatus(.monthly, now: instant, renews: true, offset: 3600)
        let presentation = present(value(.yearly), statuses: [yearly, monthly])
        XCTAssertEqual(presentation.lifetimeAction, .manageSubscription)
        XCTAssertThrowsError(try ProCommercePolicy.authorize(.lifetime, context: .settingsLifetime, presentation: presentation, isResolved: true))
    }

    func testUnknownAndUnverifiedRenewalNeverEqualOff() {
        for status in [
            commerceTestStatus(now: instant, renews: nil),
            commerceTestStatus(now: instant, renews: false, verified: false),
            commerceTestStatus(now: instant, renews: nil, verified: false, offset: -3600),
        ] {
            XCTAssertEqual(present(value(.yearly), statuses: [status]).lifetimeAction, .unavailable)
        }
        let status = commerceTestStatus(now: instant, renews: false)
        XCTAssertEqual(present(value(.yearly), statuses: [status], available: false).lifetimeAction, .unavailable)
        XCTAssertEqual(present(value(.yearly), statuses: [status], unverified: [.yearly]).lifetimeAction, .unavailable)
    }

    func testObservedSubscriptionWithoutRenewalStatusIsUnknown() {
        let presentation = ProCommercePolicy.presentation(
            value: .free, hasAccess: false, isResolved: true, statuses: [], statusAvailable: true,
            currentStatusProducts: [.yearly], now: instant
        )
        XCTAssertTrue(presentation.hasSubscription)
        XCTAssertEqual(presentation.lifetimeAction, .unavailable)
        XCTAssertThrowsError(try ProCommercePolicy.authorize(.lifetime, context: .standard, presentation: presentation, isResolved: true))
    }

    func testVerifiedOffAllowsOnlySettingsLifetimeForCurrentSubscriber() {
        let presentation = present(value(.yearly), statuses: [commerceTestStatus(now: instant, renews: false)])
        XCTAssertEqual(presentation.lifetimeAction, .available)
        XCTAssertNoThrow(try ProCommercePolicy.authorize(.lifetime, context: .settingsLifetime, presentation: presentation, isResolved: true))
        XCTAssertThrowsError(try ProCommercePolicy.authorize(.lifetime, context: .standard, presentation: presentation, isResolved: true))
        XCTAssertThrowsError(try ProCommercePolicy.authorize(.monthly, context: .settingsLifetime, presentation: presentation, isResolved: true))
    }

    func testFreeBillingRetryStillRequiresAutoRenewOffForLifetime() {
        let status = commerceTestStatus(now: instant, renews: true, state: .billingRetry, offset: -3600)
        let presentation = present(.free, statuses: [status])
        XCTAssertTrue(presentation.showsPurchaseOptions)
        XCTAssertTrue(presentation.hasBillingIssue)
        XCTAssertEqual(presentation.lifetimeAction, .manageSubscription)
        XCTAssertEqual(presentation.subscriptionPeriodEnd, status.purchase.expiresAt)
        XCTAssertNil(presentation.periodEnd)
    }

    func testOverlapAndBillingRemainIndependentOfPermanentWinner() {
        for reason: ProEntitlementReason in [.lifetime, .originalPurchaser] {
            let status = commerceTestStatus(now: instant, renews: true, state: .billingRetry, offset: -3600)
            let presentation = present(value(reason), statuses: [status])
            XCTAssertTrue(presentation.hasRenewalOverlap)
            XCTAssertTrue(presentation.hasBillingIssue)
            XCTAssertNil(presentation.renewalPrice)
            XCTAssertFalse(present(value(reason), statuses: [commerceTestStatus(now: instant, renews: false)]).hasRenewalOverlap)
        }
    }

    func testHistoricalRevokedUpgradedAndExpiredStatusesDoNotWarnOverlap() {
        var revoked = commerceTestStatus(now: instant)
        revoked.purchase.revoked = true
        var upgraded = commerceTestStatus(now: instant)
        upgraded.purchase.upgraded = true
        let expired = commerceTestStatus(now: instant, state: .expired, offset: -3600)
        for status in [revoked, upgraded, expired] {
            let presentation = present(value(.lifetime), statuses: [status])
            XCTAssertFalse(presentation.hasRenewalOverlap)
            XCTAssertFalse(presentation.hasBillingIssue)
        }
    }

    func testUnverifiedFlagsNeverShowBillingOrOverlap() {
        let status = commerceTestStatus(now: instant, renews: true, state: .grace, verified: false)
        let presentation = present(value(.lifetime), statuses: [status])
        XCTAssertFalse(presentation.hasRenewalOverlap)
        XCTAssertFalse(presentation.hasBillingIssue)
    }

    func testGraceDateNeverBecomesRenewalDateOrOfflineDeadline() {
        let status = commerceTestStatus(now: instant, state: .grace, offset: -3600)
        let presentation = present(value(.billingGrace), statuses: [status])
        XCTAssertTrue(presentation.hasBillingIssue)
        XCTAssertEqual(presentation.graceEndsAt, status.graceEndsAt)
        XCTAssertNil(presentation.periodEnd)
        XCTAssertNil(presentation.dateKind)
        XCTAssertEqual(presentation.subscriptionPeriodEnd, status.purchase.expiresAt)
    }

    func testTrialScheduledToMonthlyUsesVerifiedNextProductAndPreservedCharge() {
        var status = commerceTestStatus(now: instant, trial: true)
        status.nextRenewalProduct = .monthly
        status.renewalPrice = Decimal(string: "1.2345")
        status.renewalCurrency = "EUR"
        let presentation = present(value(.trial), statuses: [status])
        XCTAssertEqual(presentation.nextRenewalProduct, .monthly)
        XCTAssertEqual(presentation.renewalPrice, Decimal(string: "1.2345"))
        XCTAssertEqual(presentation.renewalCurrency, "EUR")
        XCTAssertEqual(presentation.renewalPriceText(locale: Locale(identifier: "en_US")), "€1.23")
        XCTAssertEqual(presentation.dateKind, .trialEnds)
        XCTAssertEqual(presentation.periodEnd, status.purchase.expiresAt)
    }

    func testPreservedYearlyPriceDoesNotDependOnNewCustomerCatalog() {
        var status = commerceTestStatus(now: instant)
        status.renewalPrice = Decimal(string: "9.99")
        status.renewalCurrency = "USD"
        XCTAssertEqual(present(value(.yearly), statuses: [status]).renewalPriceText(locale: Locale(identifier: "en_US")), "$9.99")
        XCTAssertNotEqual(commerceTestCatalog(yearlyPrice: "$19.99").products[.yearly]?.displayPrice, "$9.99")
        XCTAssertEqual(present(value(.trial), statuses: [status]).renewalPriceText(locale: Locale(identifier: "en_US")), "$9.99")
    }

    func testMissingOrUnverifiedRenewalAmountHasNoCatalogFallback() {
        var status = commerceTestStatus(now: instant)
        status.renewalCurrency = "USD"
        XCTAssertNil(present(value(.yearly), statuses: [status]).renewalPriceText())
        status.renewalPrice = Decimal(string: "9.99")
        status.renewalCurrency = nil
        XCTAssertNil(present(value(.yearly), statuses: [status]).renewalPriceText())
        status.renewalCurrency = "USD"
        XCTAssertNil(present(value(.yearly), statuses: [status], unverified: [.yearly]).renewalPriceText())
        XCTAssertNil(present(value(.yearly), statuses: [status], available: false).renewalPriceText())
    }

    func testVerifiedOffShowsExpiryAndNoNextCharge() {
        var status = commerceTestStatus(now: instant, renews: false)
        status.renewalPrice = 99
        status.renewalCurrency = "USD"
        let presentation = present(value(.yearly), statuses: [status])
        XCTAssertEqual(presentation.dateKind, .expires)
        XCTAssertNil(presentation.renewalPriceText())
        XCTAssertNil(presentation.nextRenewalProduct)
    }

    func testExpiredAndRevokedDescriptionsRemainFree() {
        let expired = present(.free, statuses: [commerceTestStatus(now: instant, state: .expired, offset: -3600)])
        XCTAssertEqual(expired.planTitle, "Free plan")
        XCTAssertTrue(expired.detail.contains("ended on"))
        let revoked = present(.free, statuses: [commerceTestStatus(now: instant, state: .revoked)])
        XCTAssertTrue(revoked.detail.contains("refunded or revoked"))
    }

    private func present(
        _ value: ProEntitlementValue, statuses: [ProSubscriptionEvidence] = [], resolved: Bool = true,
        available: Bool = true, unverified: Set<ProProductID> = []
    ) -> ProCommercePresentation {
        ProCommercePolicy.presentation(
            value: value, hasAccess: value.reason != .none, isResolved: resolved, statuses: statuses,
            statusAvailable: available, unverifiedProducts: unverified, now: instant
        )
    }

    private func value(_ reason: ProEntitlementReason) -> ProEntitlementValue {
        ProEntitlementValue(
            reason: reason, expiresAt: instant.addingTimeInterval(7200),
            proAccessEndsAt: instant.addingTimeInterval(266400), verifiedAt: instant, subscriptionProduct: reason == .trial ? .yearly : nil
        )
    }
}
