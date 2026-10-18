import Foundation
import XCTest
@testable import CodexBarIOS

@MainActor
final class ProCommerceVerificationTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    func testUnverifiedCommittedLifetimePreflightBlocksMonthlyPayment() async {
        await assertVerificationDenialBlocksPayment(.monthly, ownership: .lifetime, boundary: .preflight)
    }

    func testUnverifiedCommittedLifetimePreflightBlocksYearlyPayment() async {
        await assertVerificationDenialBlocksPayment(.yearly, ownership: .lifetime, boundary: .preflight)
    }

    func testUnverifiedOriginalPurchaserPreflightBlocksMonthlyPayment() async {
        await assertVerificationDenialBlocksPayment(.monthly, ownership: .originalPurchaser, boundary: .preflight)
    }

    func testUnverifiedOriginalPurchaserPreflightBlocksYearlyPayment() async {
        await assertVerificationDenialBlocksPayment(.yearly, ownership: .originalPurchaser, boundary: .preflight)
    }

    func testLifetimeVerificationDenialDuringCatalogBlocksMonthlyPayment() async {
        await assertVerificationDenialBlocksPayment(.monthly, ownership: .lifetime, boundary: .catalog)
    }

    func testLifetimeVerificationDenialDuringCatalogBlocksYearlyPayment() async {
        await assertVerificationDenialBlocksPayment(.yearly, ownership: .lifetime, boundary: .catalog)
    }

    func testLifetimeVerificationDenialDuringAdapterAuthorizationBlocksMonthlyPayment() async {
        await assertVerificationDenialBlocksPayment(.monthly, ownership: .lifetime, boundary: .adapter)
    }

    func testLifetimeVerificationDenialDuringAdapterAuthorizationBlocksYearlyPayment() async {
        await assertVerificationDenialBlocksPayment(.yearly, ownership: .lifetime, boundary: .adapter)
    }

    func testOriginalPurchaserVerificationDenialDuringCatalogBlocksMonthlyPayment() async {
        await assertVerificationDenialBlocksPayment(.monthly, ownership: .originalPurchaser, boundary: .catalog)
    }

    func testOriginalPurchaserVerificationDenialDuringAdapterAuthorizationBlocksYearlyPayment() async {
        await assertVerificationDenialBlocksPayment(.yearly, ownership: .originalPurchaser, boundary: .adapter)
    }

    func testVerifiedLifetimeRevocationRestoresPaymentAuthorization() async throws {
        try await assertVerifiedRevocationRestoresPaymentAuthorization(.lifetime)
    }

    func testVerifiedOriginalPurchaseRevocationRestoresPaymentAuthorization() async throws {
        try await assertVerifiedRevocationRestoresPaymentAuthorization(.originalPurchaser)
    }

    func testVerifiedSubscriptionExpiryRestoresPaymentAuthorization() async throws {
        let source = ProCommerceTestSource()
        let active = commerceTestStatus(.monthly, now: instant)
        source.next = ProStoreSnapshot(purchases: [active.purchase], subscriptions: [active], subscriptionStatusAvailable: true)
        let service = service(source)
        await service.refreshCommerce()
        XCTAssertTrue(service.hasAccess)
        source.next = ProStoreSnapshot(
            unverifiedPurchases: [ProUnverifiedPurchase(product: .monthly, environment: .production)],
            subscriptionStatusAvailable: true
        )
        await service.refresh()
        XCTAssertFalse(service.hasAccess)
        await expectNotCommitted(service, product: .yearly)
        XCTAssertTrue(source.purchaseCalls.isEmpty)

        let expired = ProPurchaseEvidence(
            product: .monthly, transactionID: active.purchase.transactionID, purchasedAt: active.purchase.purchasedAt,
            signedAt: instant.addingTimeInterval(1), expiresAt: instant.addingTimeInterval(-1)
        )
        let status = ProSubscriptionEvidence(
            purchase: expired, signedAt: expired.signedAt, state: .expired, renewalVerified: true,
            willAutoRenew: false, isInBillingRetry: false, graceEndsAt: nil
        )
        source.next = ProStoreSnapshot(purchases: [expired], subscriptions: [status], subscriptionStatusAvailable: true)
        let restored = try await service.restore()
        XCTAssertEqual(restored, .noPurchases)
        XCTAssertFalse(service.hasAccess)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.purchaseNeedsRecovery)
        let retry = try await service.purchase(.yearly)
        XCTAssertEqual(retry, .cancelled)
        XCTAssertEqual(source.purchaseCalls, [.yearly], "Verified expiry permits a legitimate new subscription.")
        await service.stopAndWait()
    }

    func testUnavailableAppEvidenceCannotResolveOriginalPurchaseVerificationDenial() async throws {
        let source = ProCommerceTestSource()
        source.next = verifiedSnapshot(.originalPurchaser)
        let service = service(source)
        await service.refreshCommerce()
        XCTAssertEqual(service.value.reason, .originalPurchaser)
        source.next = unverifiedSnapshot(.originalPurchaser)
        await service.refresh()
        XCTAssertFalse(service.hasAccess)
        source.next = ProStoreSnapshot(subscriptionStatusAvailable: true)
        await service.refresh()
        XCTAssertFalse(service.hasAccess)
        await expectNotCommitted(service, product: .monthly)
        XCTAssertTrue(source.purchaseCalls.isEmpty, "Unavailable app evidence cannot resolve the prior verification failure.")

        source.next = verifiedSnapshot(.originalPurchaser, revoked: true)
        let restored = try await service.restore()
        XCTAssertEqual(restored, .noPurchases)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.purchaseNeedsRecovery)
        let retry = try await service.purchase(.monthly)
        XCTAssertEqual(retry, .cancelled)
        XCTAssertEqual(source.purchaseCalls, [.monthly])
        await service.stopAndWait()
    }

    func testVerifiedNewAppAccountClearsOriginalPurchaseUncertainty() async throws {
        try await assertVerifiedAccountChangeRestoresPaymentAuthorization(environment: .production)
    }

    func testVerifiedEnvironmentSwitchClearsOriginalPurchaseUncertainty() async throws {
        try await assertVerifiedAccountChangeRestoresPaymentAuthorization(environment: .xcode)
    }

    func testOriginalPurchaseVerificationDenialBlocksPaymentAfterDiskCacheRestart() async throws {
        try await assertDiskCacheRetainsVerificationDenial(.originalPurchaser, product: .monthly)
    }

    func testLifetimeVerificationDenialBlocksPaymentAfterDiskCacheRestart() async throws {
        try await assertDiskCacheRetainsVerificationDenial(.lifetime, product: .yearly)
    }

    private enum Ownership {
        case lifetime, originalPurchaser

        var reason: ProEntitlementReason {
            switch self {
            case .lifetime: .lifetime
            case .originalPurchaser: .originalPurchaser
            }
        }
    }

    private enum DenialBoundary {
        case preflight, catalog, adapter
    }

    private func assertVerificationDenialBlocksPayment(
        _ product: ProProductID, ownership: Ownership, boundary: DenialBoundary
    ) async {
        let source = ProCommerceTestSource()
        let cache = TestProCache()
        let service = service(source, cache)
        if boundary == .preflight { source.next = verifiedSnapshot(ownership) }
        await service.refreshCommerce()
        var denialDelivered = boundary == .preflight
        if boundary == .preflight {
            XCTAssertTrue(service.hasAccess)
            XCTAssertEqual(cache.saved?.reason, ownership.reason)
            source.next = unverifiedSnapshot(ownership)
        } else {
            let denyDuringSuspension = {
                await self.deliverOwnershipThenVerificationDenial(ownership, source: source, service: service)
                denialDelivered = true
            }
            if boundary == .catalog {
                source.beforeCatalog = denyDuringSuspension
            } else {
                source.beforePurchaseAuthorization = denyDuringSuspension
            }
        }

        await expectNotCommitted(service, product: product)
        XCTAssertTrue(denialDelivered)
        XCTAssertFalse(service.hasAccess, "Unverified evidence must continue to deny feature access.")
        XCTAssertEqual(service.value.reason, .none)
        XCTAssertEqual(cache.saved?.reason, ProEntitlementReason.none)
        XCTAssertNotNil(service.statusMessage)
        XCTAssertTrue(service.purchaseNeedsRecovery)
        XCTAssertTrue(source.purchaseCalls.isEmpty, "Verification denial is not permission to charge a known owner again.")
        XCTAssertNil(service.command)
        source.beforeCatalog = nil
        source.beforePurchaseAuthorization = nil
        await service.stopAndWait()
    }

    private func deliverOwnershipThenVerificationDenial(
        _ ownership: Ownership, source: ProCommerceTestSource, service: ProEntitlement
    ) async {
        switch ownership {
        case .lifetime:
            let grant = verifiedSnapshot(.lifetime).purchases[0]
            await service.receive(ProTransactionDelivery(product: .lifetime, evidence: .verified(grant), finish: {}))
            XCTAssertTrue(service.hasAccess)
            XCTAssertEqual(service.value.reason, .lifetime)
            await service.receive(ProTransactionDelivery(
                product: .lifetime, evidence: .unverified, environment: .production, finish: {}
            ))
        case .originalPurchaser:
            source.next = verifiedSnapshot(.originalPurchaser)
            await service.refresh()
            XCTAssertTrue(service.hasAccess)
            XCTAssertEqual(service.value.reason, .originalPurchaser)
            source.next = unverifiedSnapshot(.originalPurchaser)
            await service.refresh()
        }
    }

    private func assertVerifiedRevocationRestoresPaymentAuthorization(_ ownership: Ownership) async throws {
        let source = ProCommerceTestSource()
        source.next = verifiedSnapshot(ownership)
        let service = service(source)
        await service.refreshCommerce()
        XCTAssertTrue(service.hasAccess)
        source.next = unverifiedSnapshot(ownership)
        await service.refresh()
        XCTAssertFalse(service.hasAccess)
        await expectNotCommitted(service, product: .monthly)
        XCTAssertTrue(source.purchaseCalls.isEmpty)

        source.next = verifiedSnapshot(ownership, revoked: true)
        let restored = try await service.restore()
        XCTAssertEqual(restored, .noPurchases)
        XCTAssertFalse(service.hasAccess)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.purchaseNeedsRecovery)
        let retry = try await service.purchase(.monthly)
        XCTAssertEqual(retry, .cancelled)
        XCTAssertEqual(source.purchaseCalls, [.monthly], "Verified revocation permits a legitimate new purchase.")
        await service.stopAndWait()
    }

    private func assertVerifiedAccountChangeRestoresPaymentAuthorization(environment: ProStoreEnvironment) async throws {
        let source = ProCommerceTestSource()
        source.next = verifiedSnapshot(.originalPurchaser)
        let service = service(source)
        await service.refreshCommerce()
        XCTAssertTrue(service.hasAccess)
        source.next = unverifiedSnapshot(.originalPurchaser)
        await service.refresh()
        XCTAssertFalse(service.hasAccess)
        XCTAssertNotNil(service.statusMessage)
        XCTAssertTrue(service.purchaseNeedsRecovery)

        source.next = ProStoreSnapshot(
            appPurchase: .verified(ProAppPurchase(
                originalVersion: "5", originalPurchaseDate: instant, environment: environment,
                revoked: false, signedAt: instant.addingTimeInterval(1)
            )), subscriptionStatusAvailable: true
        )
        let result = try await service.purchase(.monthly)
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(source.purchaseCalls, [.monthly])
        XCTAssertFalse(service.hasAccess)
        XCTAssertEqual(service.value.environment, environment)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.purchaseNeedsRecovery)
        await service.stopAndWait()
    }

    private func assertDiskCacheRetainsVerificationDenial(_ ownership: Ownership, product: ProProductID) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("entitlement.json")
        let source = ProCommerceTestSource()
        source.next = verifiedSnapshot(ownership)
        let original = ProEntitlement(
            source: source, cache: ProEntitlementCache(fileURL: cacheURL), now: { self.instant }, clock: testProClock
        )
        await original.refresh()
        XCTAssertTrue(original.hasAccess)
        source.next = unverifiedSnapshot(ownership)
        await original.refresh()
        XCTAssertFalse(original.hasAccess)
        XCTAssertTrue(original.purchaseNeedsRecovery)
        await original.stopAndWait()
        XCTAssertFalse(try Data(contentsOf: cacheURL).isEmpty)

        let diskCache = ProEntitlementCache(fileURL: cacheURL)
        XCTAssertEqual(try XCTUnwrap(diskCache.load()).reason, .none)
        let emptySource = ProCommerceTestSource()
        let restarted = ProEntitlement(source: emptySource, cache: diskCache, now: { self.instant }, clock: testProClock)
        await restarted.refreshCommerce()
        XCTAssertFalse(restarted.hasAccess)
        await expectNotCommitted(restarted, product: product)
        XCTAssertTrue(emptySource.purchaseCalls.isEmpty, "Relaunch must not convert verification denial into purchase authorization.")

        emptySource.next = verifiedSnapshot(ownership, revoked: true)
        let restored = try await restarted.restore()
        XCTAssertEqual(restored, .noPurchases)
        XCTAssertFalse(restarted.purchaseNeedsRecovery)
        let retry = try await restarted.purchase(product)
        XCTAssertEqual(retry, .cancelled)
        XCTAssertEqual(emptySource.purchaseCalls, [product])
        await restarted.stopAndWait()
    }

    private func verifiedSnapshot(_ ownership: Ownership, revoked: Bool = false) -> ProStoreSnapshot {
        let signedAt = revoked ? instant.addingTimeInterval(1) : instant
        switch ownership {
        case .lifetime:
            var purchase = ProPurchaseEvidence(
                product: .lifetime, transactionID: 41, purchasedAt: instant, signedAt: signedAt, expiresAt: nil
            )
            purchase.revoked = revoked
            return ProStoreSnapshot(purchases: [purchase], subscriptionStatusAvailable: true)
        case .originalPurchaser:
            return ProStoreSnapshot(
                appPurchase: .verified(ProAppPurchase(
                    originalVersion: "4", originalPurchaseDate: instant, environment: .production,
                    revoked: revoked, signedAt: signedAt
                )), subscriptionStatusAvailable: true
            )
        }
    }

    private func unverifiedSnapshot(_ ownership: Ownership) -> ProStoreSnapshot {
        switch ownership {
        case .lifetime:
            ProStoreSnapshot(
                unverifiedPurchases: [ProUnverifiedPurchase(product: .lifetime, environment: .production)],
                subscriptionStatusAvailable: true
            )
        case .originalPurchaser:
            ProStoreSnapshot(appPurchase: .unverified, appVerificationEnvironment: .production, subscriptionStatusAvailable: true)
        }
    }

    private func service(_ source: ProCommerceTestSource, _ cache: TestProCache = TestProCache()) -> ProEntitlement {
        ProEntitlement(source: source, cache: cache, now: { self.instant }, clock: testProClock)
    }

    private func expectNotCommitted(_ service: ProEntitlement, product: ProProductID) async {
        do {
            _ = try await service.purchase(product)
            XCTFail("Unverified ownership must block payment authorization.")
        } catch {
            XCTAssertEqual(error as? ProCommerceError, .notCommitted)
        }
        XCTAssertTrue(service.purchaseNeedsRecovery)
    }
}
