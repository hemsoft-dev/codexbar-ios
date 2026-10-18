import Combine
import Foundation
import XCTest
@testable import CodexBarIOS

@MainActor
final class ProCommerceRefreshTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    func testOldStorefrontResponseCannotReplaceNewPricesOrEligibility() async {
        let source = ProCommerceTestSource()
        let service = service(source)
        await service.loadCatalog()
        let waiting = expectation(description: "Old storefront catalog suspended")
        var resume: CheckedContinuation<Void, Never>?
        source.beforeCatalog = {
            await withCheckedContinuation { continuation in
                resume = continuation
                waiting.fulfill()
            }
        }
        let stale = Task { await service.loadCatalog() }
        await fulfillment(of: [waiting], timeout: 2)
        let replacement = commerceTestCatalog(storefront: "DEU", yearlyPrice: "19,99 €", eligibility: .ineligible)
        source.catalogValue = replacement
        source.beforeCatalog = nil
        let fresh = expectation(description: "New storefront catalog published")
        let observation = service.$catalog.filter { $0.loadedCatalog == replacement }.prefix(1).sink { _ in fresh.fulfill() }
        source.storefronts.continuation.yield("DEU")
        await fulfillment(of: [fresh], timeout: 2)
        resume?.resume()
        await stale.value
        XCTAssertEqual(service.catalog.loadedCatalog, replacement)
        XCTAssertFalse(service.catalog.loadedCatalog?.products[.yearly]?.offersSevenDayTrial ?? true)
        await service.stopAndWait()
        withExtendedLifetime(observation) {}
    }

    func testCatalogErrorAndPartialAvailabilityDoNotInventPrices() async throws {
        let source = ProCommerceTestSource()
        let service = service(source)
        source.catalogError = ProCommerceError.catalogUnavailable
        await service.loadCatalog()
        guard case .failed = service.catalog else { return XCTFail("A catalog failure must be visible") }
        source.catalogError = nil
        source.catalogValue = ProCatalog(products: [.monthly: try XCTUnwrap(source.catalogValue.products[.monthly])], storefrontID: "USA")
        await service.loadCatalog()
        XCTAssertEqual(service.catalog.loadedCatalog?.products.count, 1)
        XCTAssertNil(service.catalog.loadedCatalog?.products[.yearly])
        XCTAssertNil(service.catalog.loadedCatalog?.products[.lifetime])
        await service.stopAndWait()
    }

    func testMissingProductCannotStartPayment() async {
        let source = ProCommerceTestSource()
        let service = service(source)
        source.catalogValue = ProCatalog(products: [:], storefrontID: "USA")
        await service.refreshCommerce()
        do { _ = try await service.purchase(.yearly); XCTFail("Unavailable product must not be purchased") } catch {
            XCTAssertEqual(error as? ProCommerceError, .productUnavailable)
        }
        XCTAssertTrue(source.purchaseCalls.isEmpty)
        XCTAssertNil(service.command)
        await service.stopAndWait()
    }

    func testTransactionUpdateRefreshesCompleteCatalogWhenScreenIsOpen() async {
        let source = ProCommerceTestSource()
        let service = service(source)
        await service.loadCatalog()
        let replacement = commerceTestCatalog(yearlyPrice: "$19.99", eligibility: .ineligible)
        source.catalogValue = replacement
        let refreshed = expectation(description: "Transaction reloads catalog and eligibility")
        let observation = service.$catalog.filter { $0.loadedCatalog == replacement }.prefix(1).sink { _ in refreshed.fulfill() }
        await service.receive(ProTransactionDelivery(product: .monthly, evidence: .verified(commerceTestStatus(.monthly, now: instant).purchase), finish: {}))
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(service.catalog.loadedCatalog?.products[.yearly]?.displayPrice, "$19.99")
        XCTAssertFalse(service.catalog.loadedCatalog?.products[.yearly]?.offersSevenDayTrial ?? true)
        await service.stopAndWait()
        withExtendedLifetime(observation) {}
    }

    func testIndividualStatusAfterFailedGroupReadCannotAuthorizeLifetime() async {
        let source = ProCommerceTestSource()
        let off = commerceTestStatus(now: instant, renews: false)
        source.next = ProStoreSnapshot(purchases: [off.purchase], subscriptions: [off], subscriptionStatusAvailable: true)
        let service = service(source)
        await service.refreshCommerce()
        XCTAssertEqual(service.commerce.lifetimeAction, .available)
        source.beforeCatalog = {
            source.next.subscriptions = []
            source.next.subscriptionStatusAvailable = false
            await service.refresh()
            await service.receive(ProSubscriptionEvidence(
                purchase: off.purchase, signedAt: self.instant.addingTimeInterval(2), state: .subscribed,
                renewalVerified: true, willAutoRenew: false, isInBillingRetry: false, graceEndsAt: nil
            ))
        }
        do { _ = try await service.purchase(.lifetime, context: .settingsLifetime); XCTFail("A single status is not a complete group read") } catch {
            XCTAssertEqual(error as? ProCommerceError, .renewalUnknown)
        }
        XCTAssertFalse(service.subscriptionStatusAvailable)
        XCTAssertTrue(service.commerce.detail.contains("Auto-renew is off"), "Fresh per-product metadata remains useful for display")
        XCTAssertTrue(source.purchaseCalls.isEmpty)
        source.beforeCatalog = nil
        await service.stopAndWait()
    }

    func testStaleStatusCannotReverseNewerRenewalPreferenceOrPrice() async {
        let source = ProCommerceTestSource()
        let original = commerceTestStatus(now: instant)
        source.next = ProStoreSnapshot(purchases: [original.purchase], subscriptions: [original], subscriptionStatusAvailable: true)
        let service = service(source)
        await service.refresh()
        await service.receive(ProSubscriptionEvidence(
            purchase: original.purchase, signedAt: instant.addingTimeInterval(2), state: .subscribed,
            renewalVerified: true, willAutoRenew: false, isInBillingRetry: false, graceEndsAt: nil,
            nextRenewalProduct: .monthly, renewalPrice: 1, renewalCurrency: "USD"
        ))
        await service.receive(ProSubscriptionEvidence(
            purchase: original.purchase, signedAt: instant.addingTimeInterval(1), state: .subscribed,
            renewalVerified: true, willAutoRenew: true, isInBillingRetry: false, graceEndsAt: nil,
            nextRenewalProduct: .yearly, renewalPrice: 99, renewalCurrency: "EUR"
        ))
        XCTAssertEqual(service.commerce.lifetimeAction, .available)
        XCTAssertEqual(service.commerce.dateKind, .expires)
        XCTAssertNil(service.commerce.renewalPrice)
        XCTAssertTrue(service.hasAccess)
        await service.stopAndWait()
    }

    func testNewRevocationUpdatesRetainedStatusPurchaseBeforeOverlapProjection() async {
        let source = ProCommerceTestSource()
        let subscription = commerceTestStatus(now: instant)
        let lifetime = ProPurchaseEvidence(product: .lifetime, transactionID: 12, purchasedAt: instant, signedAt: instant)
        source.next = ProStoreSnapshot(
            purchases: [subscription.purchase, lifetime], subscriptions: [subscription], subscriptionStatusAvailable: true
        )
        let service = service(source)
        await service.refresh()
        XCTAssertTrue(service.commerce.hasRenewalOverlap)
        let revoked = ProPurchaseEvidence(
            product: .yearly, transactionID: subscription.purchase.transactionID,
            purchasedAt: subscription.purchase.purchasedAt, signedAt: instant.addingTimeInterval(1),
            expiresAt: subscription.purchase.expiresAt, revoked: true
        )
        await service.receive(ProTransactionDelivery(product: .yearly, evidence: .verified(revoked), finish: {}))
        XCTAssertFalse(service.commerce.hasRenewalOverlap)
        XCTAssertTrue(service.hasAccess)
        XCTAssertEqual(service.value.reason, .lifetime)
        await service.stopAndWait()
    }

    func testStopWaitsForOwnedFinishBeforeReturningAndRejectsFurtherUpdates() async {
        let source = ProCommerceTestSource()
        let service = service(source)
        await service.start()
        let waiting = expectation(description: "Finish began")
        var resume: CheckedContinuation<Void, Never>?
        source.transactions.continuation.yield(ProTransactionDelivery(
            product: .yearly, evidence: .verified(commerceTestStatus(now: instant).purchase)
        ) {
            await withCheckedContinuation { continuation in
                resume = continuation
                waiting.fulfill()
            }
        })
        await fulfillment(of: [waiting], timeout: 2)
        var stopped = false
        let cleanup = Task { await service.stopAndWait(); stopped = true }
        await Task.yield()
        XCTAssertFalse(stopped)
        resume?.resume()
        await cleanup.value
        XCTAssertTrue(stopped)
        source.transactions.continuation.yield(ProTransactionDelivery(
            product: .lifetime,
            evidence: .verified(ProPurchaseEvidence(product: .lifetime, transactionID: 20, purchasedAt: instant, signedAt: instant)), finish: {}
        ))
        await Task.yield()
        XCTAssertEqual(service.value.reason, .yearly)
    }

    func testCompleteGroupReadRetiresReplacedStatusOnlyForCommerce() async {
        let source = ProCommerceTestSource()
        let old = commerceTestStatus(.monthly, now: instant, renews: nil, verified: false, offset: -3600)
        let current = commerceTestStatus(now: instant, renews: false)
        source.next = ProStoreSnapshot(
            purchases: [old.purchase, current.purchase], subscriptions: [old, current], subscriptionStatusAvailable: true
        )
        let service = service(source)
        await service.refresh()
        XCTAssertEqual(service.commerce.lifetimeAction, .unavailable)
        source.next = ProStoreSnapshot(
            purchases: [old.purchase, current.purchase],
            unverifiedPurchases: [ProUnverifiedPurchase(product: .monthly, environment: .production)],
            subscriptions: [current], subscriptionStatusAvailable: true, subscriptionStatusProducts: [.yearly]
        )
        await service.refresh()
        XCTAssertEqual(service.commerce.lifetimeAction, .available)
        XCTAssertEqual(service.currentStatusProducts, [.yearly])
        XCTAssertEqual(service.subscriptionStatuses.count, 2, "Resolver history remains available; current inventory drives commerce")
        XCTAssertEqual(service.value.reason, .yearly)
        await service.stopAndWait()
    }

    func testCompleteEmptyInventoryRemovesObsoletePermanentOverlap() async {
        let source = ProCommerceTestSource()
        let subscription = commerceTestStatus(now: instant)
        let lifetime = ProPurchaseEvidence(product: .lifetime, transactionID: 20, purchasedAt: instant, signedAt: instant)
        source.next = ProStoreSnapshot(
            purchases: [subscription.purchase, lifetime], subscriptions: [subscription], subscriptionStatusAvailable: true
        )
        let service = service(source)
        await service.refresh()
        XCTAssertTrue(service.commerce.hasRenewalOverlap)
        source.next = ProStoreSnapshot(purchases: [lifetime], subscriptionStatusAvailable: true, subscriptionStatusProducts: [])
        await service.refresh()
        XCTAssertFalse(service.commerce.hasRenewalOverlap)
        XCTAssertFalse(service.commerce.hasSubscription)
        XCTAssertEqual(service.value.reason, .lifetime)
        await service.stopAndWait()
    }

    func testIncompleteReadCannotRetireUnknownCompetingStatus() async {
        let source = ProCommerceTestSource()
        let unknown = commerceTestStatus(.monthly, now: instant, renews: nil, verified: false)
        let current = commerceTestStatus(now: instant, renews: false)
        source.next = ProStoreSnapshot(
            purchases: [unknown.purchase, current.purchase], subscriptions: [unknown, current], subscriptionStatusAvailable: true
        )
        let service = service(source)
        await service.refresh()
        source.next = ProStoreSnapshot(purchases: [current.purchase], subscriptions: [current], subscriptionStatusAvailable: false)
        await service.refresh()
        await service.receive(current)
        XCTAssertEqual(service.currentStatusProducts, [.monthly, .yearly])
        XCTAssertEqual(service.commerce.lifetimeAction, .unavailable)
        await service.stopAndWait()
    }

    func testRetiredInventoryRejectsOlderAndDuplicateStatusEvents() async {
        let (service, _, subscription) = await serviceWithRetiredSubscription()
        let stale = ProSubscriptionEvidence(
            purchase: subscription.purchase, signedAt: instant.addingTimeInterval(-1), state: .subscribed,
            renewalVerified: true, willAutoRenew: true, isInBillingRetry: false, graceEndsAt: nil
        )
        await service.receive(stale)
        XCTAssertEqual(service.currentStatusProducts, [])
        XCTAssertFalse(service.commerce.hasRenewalOverlap)
        await service.receive(subscription)
        XCTAssertEqual(service.currentStatusProducts, [])
        XCTAssertFalse(service.commerce.hasRenewalOverlap)
        XCTAssertFalse(service.commerce.hasSubscription)
        await service.stopAndWait()
    }

    func testNewerReactivationCanReturnToCurrentInventory() async {
        let (service, _, subscription) = await serviceWithRetiredSubscription()
        let reactivated = ProSubscriptionEvidence(
            purchase: subscription.purchase, signedAt: instant.addingTimeInterval(1), state: .subscribed,
            renewalVerified: true, willAutoRenew: true, isInBillingRetry: false, graceEndsAt: nil
        )
        await service.receive(reactivated)
        XCTAssertEqual(service.currentStatusProducts, [.yearly])
        XCTAssertTrue(service.commerce.hasRenewalOverlap)
        XCTAssertTrue(service.commerce.hasSubscription)
        await service.stopAndWait()
    }

    func testRetiredDuplicateTransactionCannotRestoreHistoricalRenewalWarning() async {
        let (service, _, subscription) = await serviceWithRetiredSubscription()
        await service.receive(ProTransactionDelivery(product: .yearly, evidence: .verified(subscription.purchase), finish: {}))
        XCTAssertEqual(service.currentStatusProducts, [])
        XCTAssertFalse(service.commerce.hasRenewalOverlap)
        let rejected = ProPurchaseEvidence(
            product: .yearly, transactionID: 98, purchasedAt: subscription.purchase.purchasedAt,
            signedAt: subscription.purchase.signedAt.addingTimeInterval(-1), expiresAt: subscription.purchase.expiresAt
        )
        await service.receive(ProTransactionDelivery(product: .yearly, evidence: .verified(rejected), finish: {}))
        XCTAssertEqual(service.currentStatusProducts, [])
        XCTAssertFalse(service.commerce.hasRenewalOverlap)
        await service.stopAndWait()
    }

    private func serviceWithRetiredSubscription() async -> (ProEntitlement, ProCommerceTestSource, ProSubscriptionEvidence) {
        let source = ProCommerceTestSource()
        let subscription = commerceTestStatus(now: instant)
        let lifetime = ProPurchaseEvidence(product: .lifetime, transactionID: 20, purchasedAt: instant, signedAt: instant)
        source.next = ProStoreSnapshot(
            purchases: [subscription.purchase, lifetime], subscriptions: [subscription], subscriptionStatusAvailable: true
        )
        let service = service(source)
        await service.refresh()
        source.next = ProStoreSnapshot(purchases: [lifetime], subscriptionStatusAvailable: true, subscriptionStatusProducts: [])
        await service.refresh()
        return (service, source, subscription)
    }

    private func service(_ source: ProCommerceTestSource) -> ProEntitlement {
        ProEntitlement(source: source, cache: TestProCache(), now: { self.instant }, clock: testProClock)
    }
}
