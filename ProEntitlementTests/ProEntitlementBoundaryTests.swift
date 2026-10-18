import Combine
import Foundation
import XCTest
@testable import CodexBarIOS

@MainActor
final class ProEntitlementBoundaryTests: XCTestCase {
    func testClockJumpPublishesExpirationBeforeAwaitingStoreKit() async throws {
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = instant.addingTimeInterval(3_600)
        var sample = ProEntitlementClockSample(wallDate: instant, continuousSeconds: 1_000, continuityID: "clock-test")
        let source = TestProSource()
        let cache = TestProCache()
        try cache.save(ProEntitlementValue(
            reason: .monthly, expiresAt: expiry, proAccessEndsAt: expiry.addingTimeInterval(ProEntitlementValue.offlineAllowance),
            verifiedAt: instant, clockAnchor: ProEntitlementClockAnchor(
                anchorDate: instant, continuousSeconds: 1_000, continuityID: "clock-test", latestSignedAt: instant
            )
        ))
        let service = ProEntitlement(source: source, cache: cache, now: { sample.wallDate }, clock: { _ in sample })
        await service.start()
        var observed: ProAccessState?
        let subscription = service.accessChanges.sink { observed = $0 }
        defer { subscription.cancel(); source.finishStreams() }
        sample = ProEntitlementClockSample(wallDate: expiry.addingTimeInterval(ProEntitlementValue.offlineAllowance),
                                          continuousSeconds: 1_001, continuityID: "clock-test")
        source.beforeSnapshot = {
            XCTAssertEqual(observed, ProAccessState(hasAccess: false, isResolved: true))
            XCTAssertEqual(service.value.reason, .none)
            XCTAssertEqual(cache.saved, service.value)
        }

        await service.refresh()

        XCTAssertFalse(service.hasAccess)
        sample = ProEntitlementClockSample(wallDate: instant, continuousSeconds: 1_002, continuityID: "clock-test")
        service.reevaluateLocalAccess()
        XCTAssertFalse(service.hasAccess, "Moving the clock back cannot undo the locally recorded expiration")
    }

    func testUncertainClockPublishesDenialWithoutDiscardingRecoverableEvidence() async throws {
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        var sample = testProClock(instant)
        let cache = TestProCache()
        let expiry = instant.addingTimeInterval(3_600)
        let evidence = ProEntitlementValue(
            reason: .monthly, expiresAt: expiry, proAccessEndsAt: expiry.addingTimeInterval(ProEntitlementValue.offlineAllowance),
            verifiedAt: instant, clockAnchor: testProAnchor(instant)
        )
        try cache.save(evidence)
        let service = ProEntitlement(source: TestProSource(), cache: cache, now: { sample.wallDate }, clock: { _ in sample })
        var observed: ProAccessState?
        let subscription = service.accessChanges.sink { observed = $0 }
        defer { subscription.cancel() }

        sample = ProEntitlementClockSample(wallDate: instant.addingTimeInterval(-1), continuousSeconds: 1, continuityID: nil)
        service.reevaluateLocalAccess()

        XCTAssertEqual(observed?.hasAccess, false)
        XCTAssertEqual(service.value, evidence)
        XCTAssertEqual(cache.saved, evidence)
        sample = testProClock(instant.addingTimeInterval(1))
        service.reevaluateLocalAccess()
        XCTAssertEqual(observed?.hasAccess, true)
        XCTAssertEqual(service.value, evidence)
    }

    func testSignedExpiryRechecksStoreKitBeforeOfflineAllowanceEnds() async throws {
        let source = TestProSource()
        let cache = TestProCache()
        let expiry = Date().addingTimeInterval(0.15)
        try cache.save(ProEntitlementValue(
            reason: .monthly, expiresAt: expiry, proAccessEndsAt: expiry.addingTimeInterval(259_200),
            verifiedAt: expiry.addingTimeInterval(-3_600), clockAnchor: testProAnchor(expiry.addingTimeInterval(-3_600))
        ))
        let service = ProEntitlement(source: source, cache: cache, clock: testProClock)
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
        let service = ProEntitlement(source: source, cache: cache, now: { instant }, clock: testProClock)
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
