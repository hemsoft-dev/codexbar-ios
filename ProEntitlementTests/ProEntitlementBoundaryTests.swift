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
        try await Task.sleep(for: .seconds(1.1))
        XCTAssertEqual(source.calls.filter { $0 == "snapshot" }.count, 2)
        XCTAssertTrue(service.hasAccess, "An unavailable source preserves the fixed offline allowance")
        source.finishStreams()
    }

    func testStaleOnlineSnapshotAtExpiryIsRecheckedWithoutAStatusEvent() async throws {
        let source = TestProSource()
        let cache = TestProCache()
        let expiry = Date().addingTimeInterval(0.25)
        let purchase = ProPurchaseEvidence(
            product: .monthly, transactionID: 500, purchasedAt: expiry.addingTimeInterval(-3_600),
            signedAt: expiry.addingTimeInterval(-1), expiresAt: expiry
        )
        let subscribed = ProSubscriptionEvidence(
            purchase: purchase, signedAt: purchase.signedAt, state: .subscribed,
            renewalVerified: true, willAutoRenew: false, isInBillingRetry: false, graceEndsAt: nil
        )
        let expired = ProSubscriptionEvidence(
            purchase: purchase, signedAt: expiry, state: .expired,
            renewalVerified: true, willAutoRenew: false, isInBillingRetry: false, graceEndsAt: nil
        )
        source.next = ProStoreSnapshot(purchases: [purchase], subscriptions: [subscribed], subscriptionStatusAvailable: true)
        var postExpiryReads = 0
        source.beforeSnapshot = {
            if source.calls.filter({ $0 == "snapshot" }).count > 1 {
                postExpiryReads += 1
                if postExpiryReads == 1 { try? await Task.sleep(for: .milliseconds(20)) }
                if postExpiryReads > 1 {
                    source.next = ProStoreSnapshot(purchases: [purchase], subscriptions: [expired], subscriptionStatusAvailable: true)
                }
            }
        }
        let service = ProEntitlement(source: source, cache: cache, clock: testProClock)
        await service.start()
        let denied = expectation(description: "Late verified expiration is read after the initially stale boundary snapshot")
        let observation = service.accessChanges.filter { !$0.hasAccess && $0.isResolved }.prefix(1).sink { _ in denied.fulfill() }
        await fulfillment(of: [denied], timeout: 3)
        XCTAssertGreaterThanOrEqual(postExpiryReads, 2)
        XCTAssertFalse(service.hasAccess)
        await service.stopAndWait()
        source.finishStreams()
        withExtendedLifetime(observation) {}
    }

    func testStopWaitsForTheAlreadyStartedBoundarySnapshot() async throws {
        let source = TestProSource()
        let expiry = Date().addingTimeInterval(0.25)
        let purchase = ProPurchaseEvidence(
            product: .monthly, transactionID: 501, purchasedAt: expiry.addingTimeInterval(-3_600),
            signedAt: expiry.addingTimeInterval(-1), expiresAt: expiry
        )
        source.next = ProStoreSnapshot(purchases: [purchase])
        let reading = expectation(description: "Boundary read started")
        var resumeRead: CheckedContinuation<Void, Never>?
        source.beforeSnapshot = {
            if source.calls.filter({ $0 == "snapshot" }).count > 1 {
                reading.fulfill()
                await withCheckedContinuation { resumeRead = $0 }
            }
        }
        let service = ProEntitlement(source: source, cache: TestProCache(), clock: testProClock)
        await service.start()
        await fulfillment(of: [reading], timeout: 2)
        var stopped = false
        let stopping = Task { await service.stopAndWait(); stopped = true }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(stopped, "Stopping must drain the owned StoreKit read before a test store can be cleared")
        resumeRead?.resume()
        await stopping.value
        source.finishStreams()
    }

    func testStaleVerifiedBoundaryRetriesAreBoundedAndKeepTheOfflineDeadline() async throws {
        let source = TestProSource()
        let cache = TestProCache()
        let expiry = Date().addingTimeInterval(0.25)
        source.next = boundarySnapshot(expiry: expiry)
        let service = ProEntitlement(source: source, cache: cache, clock: testProClock)
        await service.start()
        let originalDeadline = service.value.proAccessEndsAt
        try await Task.sleep(for: .seconds(8.25))
        XCTAssertEqual(source.calls.filter { $0 == "snapshot" }.count, 5, "Initial read, expiry read, and three bounded rechecks")
        XCTAssertEqual(service.value.proAccessEndsAt, originalDeadline)
        XCTAssertTrue(service.hasAccess, "A stale response must preserve the original fixed offline allowance")
        await service.stopAndWait()
        source.finishStreams()
    }

    func testSlowBoundaryRecheckDoesNotOverlapOrDiscardItsResult() async throws {
        let source = TestProSource()
        let expiry = Date().addingTimeInterval(0.25)
        source.next = boundarySnapshot(expiry: expiry)
        let reading = expectation(description: "First stale-boundary recheck started")
        var resumeRead: CheckedContinuation<Void, Never>?
        source.beforeSnapshot = {
            if source.calls.filter({ $0 == "snapshot" }).count == 3 {
                reading.fulfill()
                await withCheckedContinuation { resumeRead = $0 }
                source.next = self.boundarySnapshot(expiry: expiry, state: .expired)
            }
        }
        let service = ProEntitlement(source: source, cache: TestProCache(), clock: testProClock)
        await service.start()
        await fulfillment(of: [reading], timeout: 3)
        try await Task.sleep(for: .seconds(2.25))
        XCTAssertEqual(source.calls.filter { $0 == "snapshot" }.count, 3, "A slow recheck must not be superseded by another timer")
        let held = try XCTUnwrap(resumeRead)
        resumeRead = nil
        held.resume()
        let denied = expectation(description: "The original delayed expiration result commits")
        let observation = service.accessChanges.filter { !$0.hasAccess && $0.isResolved }.prefix(1).sink { _ in denied.fulfill() }
        await fulfillment(of: [denied], timeout: 2)
        XCTAssertFalse(service.hasAccess)
        await service.stopAndWait()
        source.finishStreams()
        withExtendedLifetime(observation) {}
    }

    func testRetiredBoundaryCompletionCannotClearTheRestartedRead() async throws {
        let source = TestProSource()
        let firstExpiry = Date().addingTimeInterval(0.25)
        source.next = boundarySnapshot(expiry: firstExpiry)
        let firstReading = expectation(description: "First boundary read started")
        var resumeFirst: CheckedContinuation<Void, Never>?
        source.beforeSnapshot = {
            if source.calls.filter({ $0 == "snapshot" }).count == 2 {
                firstReading.fulfill()
                await withCheckedContinuation { resumeFirst = $0 }
            }
        }
        let service = ProEntitlement(source: source, cache: TestProCache(), clock: testProClock)
        await service.start()
        await fulfillment(of: [firstReading], timeout: 2)
        service.stop()
        let secondExpiry = Date().addingTimeInterval(0.25)
        source.next = boundarySnapshot(expiry: secondExpiry, identifier: 601)
        let secondReading = expectation(description: "Replacement boundary read started")
        var resumeSecond: CheckedContinuation<Void, Never>?
        source.beforeSnapshot = {
            if source.calls.filter({ $0 == "snapshot" }).count == 4 {
                secondReading.fulfill()
                await withCheckedContinuation { resumeSecond = $0 }
            }
        }
        await service.start()
        await fulfillment(of: [secondReading], timeout: 2)
        let old = try XCTUnwrap(resumeFirst)
        resumeFirst = nil
        old.resume()
        try await Task.sleep(for: .milliseconds(50))
        var stopped = false
        let stopping = Task { await service.stopAndWait(); stopped = true }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(stopped, "An old completion must not detach the new owned read")
        let replacement = try XCTUnwrap(resumeSecond)
        resumeSecond = nil
        replacement.resume()
        await stopping.value
        source.finishStreams()
    }

    private func boundarySnapshot(
        expiry: Date, state: ProRenewalState = .subscribed, identifier: UInt64 = 600
    ) -> ProStoreSnapshot {
        let purchase = ProPurchaseEvidence(
            product: .monthly, transactionID: identifier, purchasedAt: expiry.addingTimeInterval(-3_600),
            signedAt: expiry.addingTimeInterval(-1), expiresAt: expiry
        )
        let status = ProSubscriptionEvidence(
            purchase: purchase, signedAt: state == .expired ? expiry : purchase.signedAt, state: state,
            renewalVerified: true, willAutoRenew: false, isInBillingRetry: false, graceEndsAt: nil
        )
        return ProStoreSnapshot(purchases: [purchase], subscriptions: [status], subscriptionStatusAvailable: true)
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
