import Foundation
import XCTest
@testable import CodexBarIOS

@MainActor
final class ProEntitlementBoundaryTests: XCTestCase {
    func testSignedExpiryRechecksStoreKitBeforeOfflineAllowanceEnds() async throws {
        let source = TestProSource()
        let cache = TestProCache()
        let expiry = Date().addingTimeInterval(0.15)
        try cache.save(ProEntitlementValue(
            reason: .monthly, expiresAt: expiry, proAccessEndsAt: expiry.addingTimeInterval(259_200),
            verifiedAt: expiry.addingTimeInterval(-3_600)
        ))
        let service = ProEntitlement(source: source, cache: cache)
        await service.start()
        let rechecked = expectation(description: "StoreKit rechecked at signed expiry")
        source.beforeSnapshot = { rechecked.fulfill() }
        await fulfillment(of: [rechecked], timeout: 2)
        XCTAssertEqual(source.calls.filter { $0 == "snapshot" }.count, 2)
        XCTAssertTrue(service.hasAccess, "An unavailable source preserves the fixed offline allowance")
        source.finishStreams()
    }

    func testFailedCacheWriteCannotKeepRevokedLifetimeOverWeakerSubscription() async {
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let source = TestProSource()
        let cache = TestProCache()
        let service = ProEntitlement(source: source, cache: cache, now: { instant })
        let yearly = ProPurchaseEvidence(
            product: .yearly, transactionID: 1, purchasedAt: instant, signedAt: instant,
            expiresAt: instant.addingTimeInterval(3_600)
        )
        let lifetime = ProPurchaseEvidence(product: .lifetime, transactionID: 2, purchasedAt: instant, signedAt: instant)
        for purchase in [yearly, lifetime] {
            await service.receive(ProTransactionDelivery(product: purchase.product, evidence: .verified(purchase), finish: {}))
        }
        XCTAssertEqual(service.value.reason, .lifetime)
        cache.shouldFail = true
        let refund = ProPurchaseEvidence(
            product: .lifetime, transactionID: 2, purchasedAt: instant,
            signedAt: instant.addingTimeInterval(1), revoked: true
        )
        var finished = false
        await service.receive(ProTransactionDelivery(product: .lifetime, evidence: .verified(refund), finish: { finished = true }))
        XCTAssertFalse(service.hasAccess, "A denied permanent grant must not survive a storage failure")
        XCTAssertFalse(finished)
        XCTAssertNotNil(service.statusMessage)
        cache.shouldFail = false
        await service.refresh()
        XCTAssertEqual(service.value.reason, .yearly)
        XCTAssertEqual(cache.saved, service.value)
    }
}
