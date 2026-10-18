import Foundation
import XCTest
@testable import CodexBarIOS

final class ProEntitlementResolverTests: XCTestCase {
    let instant = Date(timeIntervalSince1970: 1_800_000_000)

    func testColdStartUnavailableOrUnverifiedNeverGrantsAccess() {
        for evidence: ProVerification<ProAppPurchase> in [.unavailable, .unverified] {
            let value = resolve(ProStoreSnapshot(appPurchase: evidence))
            XCTAssertEqual(value.reason, .none)
            XCTAssertFalse(value.hasAccess(at: instant))
        }
    }

    func testMonthlyYearlyTrialAndLifetime() {
        for (product, trial, reason): (ProProductID, Bool, ProEntitlementReason) in [
            (.monthly, false, .monthly), (.yearly, false, .yearly),
            (.yearly, true, .trial), (.monthly, true, .monthly), (.lifetime, false, .lifetime),
        ] {
            var purchase = purchase(product)
            purchase.isFreeTrial = trial
            let value = resolve(ProStoreSnapshot(purchases: [purchase]))
            XCTAssertEqual(value.reason, reason)
            XCTAssertTrue(value.hasAccess(at: instant))
            if product == .lifetime {
                XCTAssertNil(value.proAccessEndsAt)
            } else {
                XCTAssertEqual(value.proAccessEndsAt, instant.addingTimeInterval(3600 + 259200))
            }
        }
    }

    func testOriginalPolicyAcceptsOnlyVerifiedUnrevokedProduction() {
        for (production, revoked, expected) in [(true, false, true), (false, false, false), (true, true, false)] {
            let app = ProAppPurchase(
                originalVersion: "4", originalPurchaseDate: instant,
                environment: production ? .production : .sandbox, revoked: revoked
            )
            let snapshot = ProStoreSnapshot(appPurchase: .verified(app))
            let value = resolve(snapshot, policy: ProOriginalPurchaserPolicy(qualifies: { _ in true }))
            XCTAssertEqual(value.hasAccess(at: instant), expected)
        }
        let app = ProAppPurchase(originalVersion: "4", originalPurchaseDate: instant, environment: .production, revoked: false)
        XCTAssertEqual(resolve(ProStoreSnapshot(appPurchase: .verified(app))).reason, .none)
    }

    func testPermanentCacheSurvivesUnavailableEvidenceButNotExplicitRevocation() {
        for reason: ProEntitlementReason in [.lifetime, .originalPurchaser] {
            let cached = permanent(reason)
            XCTAssertTrue(resolve(ProStoreSnapshot(), cached: cached).hasAccess(at: instant))
        }
        var revoked = purchase(.lifetime)
        revoked.revoked = true
        XCTAssertEqual(resolve(ProStoreSnapshot(purchases: [revoked]), cached: permanent(.lifetime)).reason, .none)
        let app = ProAppPurchase(originalVersion: "4", originalPurchaseDate: instant, environment: .production, revoked: true)
        XCTAssertEqual(resolve(ProStoreSnapshot(appPurchase: .verified(app)), cached: permanent(.originalPurchaser)).reason, .none)
        XCTAssertEqual(resolve(ProStoreSnapshot(appPurchase: .unverified), cached: permanent(.originalPurchaser)).reason, .none)
    }

    func testOfflineAllowanceEndsExactlyAtFixedBoundary() {
        let cached = resolve(ProStoreSnapshot(purchases: [purchase(.yearly)]))
        let boundary = instant.addingTimeInterval(3600 + 259200)
        let before = ProEntitlementResolver.resolve(
            ProStoreSnapshot(), cached: cached, originalPolicy: ProOriginalPurchaserPolicy(), now: boundary.addingTimeInterval(-0.001)
        )
        XCTAssertEqual(before, cached)
        XCTAssertTrue(before.hasAccess(at: boundary.addingTimeInterval(-0.001)))
        XCTAssertFalse(before.hasAccess(at: boundary))
        let atBoundary = ProEntitlementResolver.resolve(
            ProStoreSnapshot(), cached: cached, originalPolicy: ProOriginalPurchaserPolicy(), now: boundary
        )
        XCTAssertEqual(atBoundary.reason, .none)
    }

    func testGraceAddsAllowanceToSignedGraceEnd() {
        var purchase = purchase(.yearly)
        purchase.expiresAt = instant.addingTimeInterval(-1)
        for state: ProRenewalState in [.grace, .billingRetry] {
            let status = status(purchase, state: state, grace: instant.addingTimeInterval(7200))
            let value = resolve(ProStoreSnapshot(purchases: [purchase], subscriptions: [status], subscriptionStatusAvailable: true))
            XCTAssertEqual(value.reason, .billingGrace)
            XCTAssertEqual(value.proAccessEndsAt, instant.addingTimeInterval(7200 + 259200))
        }
    }

    func testVerifiedNegativeStatusesOverrideOfflineAllowance() {
        let purchase = purchase(.monthly)
        let cached = resolve(ProStoreSnapshot(purchases: [purchase]))
        for state: ProRenewalState in [.expired, .billingRetry, .revoked, .grace] {
            let denied = status(purchase, state: state)
            let value = resolve(ProStoreSnapshot(purchases: [purchase], subscriptions: [denied]), cached: cached)
            XCTAssertEqual(value.reason, .none, "\(state)")
        }
    }

    func testAgedSubscribedOrGraceStatusDoesNotEraseOfflineAllowance() {
        var purchase = purchase(.yearly)
        let cached = resolve(ProStoreSnapshot(purchases: [purchase]))
        purchase.expiresAt = instant.addingTimeInterval(-1)
        for state: ProRenewalState in [.subscribed, .grace, .billingRetry] {
            let aged = ProSubscriptionEvidence(
                purchase: purchase, signedAt: instant.addingTimeInterval(-3600), state: state,
                renewalVerified: true, willAutoRenew: true, isInBillingRetry: state == .billingRetry,
                graceEndsAt: state == .subscribed ? nil : instant.addingTimeInterval(-1)
            )
            let value = resolve(
                ProStoreSnapshot(purchases: [purchase], subscriptions: [aged], subscriptionStatusAvailable: true), cached: cached
            )
            XCTAssertEqual(value, cached, "\(state)")
        }
    }

    func testOldRefundOnAnotherPlanDoesNotSuppressCurrentOfflineAllowance() {
        let cached = resolve(ProStoreSnapshot(purchases: [purchase(.yearly)]))
        var monthly = purchase(.monthly)
        monthly.revoked = true
        var yearly = purchase(.yearly)
        yearly.expiresAt = instant.addingTimeInterval(-1)
        let value = resolve(ProStoreSnapshot(
            purchases: [monthly, yearly], subscriptions: [status(monthly, state: .revoked)]
        ), cached: cached)
        XCTAssertEqual(value, cached)
    }

    func testRefundRevocationUpgradeAndUnverifiedResultsCannotGrant() {
        for product in ProProductID.allCases {
            var revoked = purchase(product)
            revoked.revoked = true
            XCTAssertEqual(resolve(ProStoreSnapshot(purchases: [revoked])).reason, .none)
            var upgraded = purchase(product)
            upgraded.upgraded = true
            XCTAssertEqual(resolve(ProStoreSnapshot(purchases: [upgraded])).reason, .none)
            XCTAssertEqual(resolve(ProStoreSnapshot(purchases: [purchase(product)], unverifiedProducts: [product])).reason, .none)
        }
    }

    func testUnverifiedRenewalCannotExtendSignedAccess() {
        var purchase = purchase(.yearly)
        purchase.expiresAt = instant.addingTimeInterval(-1)
        let status = ProSubscriptionEvidence(
            purchase: purchase, signedAt: instant, state: .grace, renewalVerified: false,
            willAutoRenew: nil, isInBillingRetry: true, graceEndsAt: instant.addingTimeInterval(7200)
        )
        XCTAssertEqual(resolve(ProStoreSnapshot(purchases: [purchase], subscriptions: [status])).reason, .none)
        purchase.expiresAt = instant.addingTimeInterval(3600)
        XCTAssertEqual(resolve(ProStoreSnapshot(purchases: [purchase], subscriptions: [status])).reason, .yearly)
    }

    func testSubscriptionLossPreservesPermanentAndLifetimeLossPreservesSubscription() {
        var revokedMonthly = purchase(.monthly)
        revokedMonthly.revoked = true
        XCTAssertEqual(resolve(ProStoreSnapshot(purchases: [purchase(.lifetime), revokedMonthly])).reason, .lifetime)
        let app = ProAppPurchase(originalVersion: "4", originalPurchaseDate: instant, environment: .production, revoked: false)
        let original = resolve(
            ProStoreSnapshot(appPurchase: .verified(app), purchases: [revokedMonthly]),
            policy: ProOriginalPurchaserPolicy(qualifies: { _ in true })
        )
        XCTAssertEqual(original.reason, .originalPurchaser)
        var revokedLifetime = purchase(.lifetime)
        revokedLifetime.revoked = true
        XCTAssertEqual(resolve(ProStoreSnapshot(purchases: [revokedLifetime, purchase(.yearly)])).reason, .yearly)
    }

    func testMalformedCacheNeverBecomesPermanentOrExtendsAllowance() {
        for value in [
            ProEntitlementValue(reason: .yearly, expiresAt: nil, proAccessEndsAt: nil, verifiedAt: instant),
            ProEntitlementValue(reason: .lifetime, expiresAt: nil, proAccessEndsAt: nil, verifiedAt: nil),
            ProEntitlementValue(reason: .monthly, expiresAt: instant, proAccessEndsAt: .distantFuture, verifiedAt: instant),
        ] {
            XCTAssertFalse(value.hasAccess(at: instant))
            XCTAssertEqual(resolve(ProStoreSnapshot(), cached: value).reason, .none)
        }
    }

    private func purchase(_ product: ProProductID) -> ProPurchaseEvidence {
        ProPurchaseEvidence(
            product: product, transactionID: UInt64(ProProductID.allCases.firstIndex(of: product) ?? 0),
            purchasedAt: instant.addingTimeInterval(-3600), signedAt: instant,
            expiresAt: product == .lifetime ? nil : instant.addingTimeInterval(3600)
        )
    }

    private func status(_ purchase: ProPurchaseEvidence, state: ProRenewalState, grace: Date? = nil) -> ProSubscriptionEvidence {
        ProSubscriptionEvidence(
            purchase: purchase, signedAt: instant, state: state, renewalVerified: true,
            willAutoRenew: false, isInBillingRetry: state == .billingRetry, graceEndsAt: grace
        )
    }

    private func permanent(_ reason: ProEntitlementReason) -> ProEntitlementValue {
        ProEntitlementValue(reason: reason, expiresAt: nil, proAccessEndsAt: nil, verifiedAt: instant.addingTimeInterval(-3600))
    }

    private func resolve(
        _ snapshot: ProStoreSnapshot, cached: ProEntitlementValue = .free,
        policy: ProOriginalPurchaserPolicy = ProOriginalPurchaserPolicy()
    ) -> ProEntitlementValue {
        ProEntitlementResolver.resolve(snapshot, cached: cached, originalPolicy: policy, now: instant)
    }
}
