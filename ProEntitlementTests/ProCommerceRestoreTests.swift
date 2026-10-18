import Foundation
import XCTest
@testable import CodexBarIOS

@MainActor
final class ProCommerceRestoreTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    func testEmptyRestoreDoesNotClaimCachedLifetimeWasRestored() async throws {
        try await assertEmptyRestorePreservesCachedAccess(.lifetime)
    }

    func testEmptyRestoreDoesNotClaimCachedSubscriptionWasRestored() async throws {
        try await assertEmptyRestorePreservesCachedAccess(.yearly)
    }

    func testFreshVerifiedOriginalPurchaseReportsRestored() async throws {
        let snapshot = ProStoreSnapshot(
            appPurchase: .verified(ProAppPurchase(
                originalVersion: "4", originalPurchaseDate: instant, environment: .production,
                revoked: false, signedAt: instant
            )), subscriptionStatusAvailable: true
        )
        try await assertFreshVerifiedPurchaseReportsRestored(snapshot, reason: .originalPurchaser)
    }

    func testFreshVerifiedLifetimeReportsRestored() async throws {
        try await assertFreshVerifiedPurchaseReportsRestored(snapshot(.lifetime), reason: .lifetime)
    }

    func testFreshVerifiedMonthlySubscriptionReportsRestored() async throws {
        try await assertFreshVerifiedPurchaseReportsRestored(snapshot(.monthly), reason: .monthly)
    }

    func testFreshVerifiedYearlySubscriptionReportsRestored() async throws {
        try await assertFreshVerifiedPurchaseReportsRestored(snapshot(.yearly), reason: .yearly)
    }

    private func assertEmptyRestorePreservesCachedAccess(_ product: ProProductID) async throws {
        let cache = TestProCache()
        let verifiedSource = ProCommerceTestSource()
        verifiedSource.next = snapshot(product)
        let previous = service(verifiedSource, cache)
        await previous.refresh()
        XCTAssertTrue(previous.hasAccess)
        let cachedReason = previous.value.reason
        await previous.stopAndWait()

        let emptySource = ProCommerceTestSource()
        let restarted = service(emptySource, cache)
        XCTAssertTrue(restarted.hasAccess, "The cached grant remains valid before this Restore.")
        let restored = try await restarted.restore()
        XCTAssertEqual(restored, .noPurchases, "Restore found no fresh verified qualifying purchase.")
        XCTAssertTrue(restarted.hasAccess, "An empty Restore must preserve allowed offline access.")
        XCTAssertEqual(restarted.value.reason, cachedReason)
        XCTAssertEqual(cache.saved?.reason, cachedReason)
        XCTAssertEqual(emptySource.restoreCalls.count, 1)
        XCTAssertNil(restarted.statusMessage)
        XCTAssertNil(restarted.command)
        await restarted.stopAndWait()
    }

    private func assertFreshVerifiedPurchaseReportsRestored(
        _ snapshot: ProStoreSnapshot, reason: ProEntitlementReason
    ) async throws {
        let source = ProCommerceTestSource()
        let cache = TestProCache()
        let service = service(source, cache)
        await service.refreshCommerce()
        XCTAssertFalse(service.hasAccess)
        source.beforeRestore = { source.next = snapshot }
        let restored = try await service.restore()
        XCTAssertEqual(restored, .restored)
        XCTAssertTrue(service.hasAccess)
        XCTAssertEqual(service.value.reason, reason)
        XCTAssertEqual(cache.saved?.reason, reason)
        XCTAssertEqual(source.restoreCalls.count, 1)
        XCTAssertNil(service.statusMessage)
        XCTAssertNil(service.command)
        await service.stopAndWait()
    }

    private func snapshot(_ product: ProProductID) -> ProStoreSnapshot {
        if product == .lifetime {
            let purchase = ProPurchaseEvidence(
                product: .lifetime, transactionID: 51, purchasedAt: instant, signedAt: instant, expiresAt: nil
            )
            return ProStoreSnapshot(purchases: [purchase], subscriptionStatusAvailable: true)
        }
        let status = commerceTestStatus(product, now: instant)
        return ProStoreSnapshot(purchases: [status.purchase], subscriptions: [status], subscriptionStatusAvailable: true)
    }

    private func service(_ source: ProCommerceTestSource, _ cache: TestProCache = TestProCache()) -> ProEntitlement {
        ProEntitlement(source: source, cache: cache, now: { self.instant }, clock: testProClock)
    }
}
