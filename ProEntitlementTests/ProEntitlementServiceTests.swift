import Combine
import Foundation
import XCTest
@testable import CodexBarIOS

@MainActor
final class ProEntitlementServiceTests: XCTestCase {
    let instant = Date(timeIntervalSince1970: 1_800_000_000)

    func testPurchaseSavesAndPublishesBeforeFinishing() async throws {
        let source = TestProSource()
        let cache = TestProCache()
        let service = service(source, cache)
        var events: [String] = []
        cache.onSave = { _ in events.append("save") }
        let publication = service.$value.dropFirst().sink { _ in events.append("publish") }
        source.purchaseOutcome = .purchased(delivery { events.append("finish") })
        _ = try await service.purchase(.yearly)
        XCTAssertEqual(events, ["save", "publish", "finish"])
        XCTAssertEqual(service.value.reason, .yearly)
        XCTAssertEqual(cache.saved, service.value)
        withExtendedLifetime(publication) {}
    }

    func testSaveFailureAndUnverifiedDeliveryNeverFinish() async {
        let source = TestProSource()
        let cache = TestProCache()
        let service = service(source, cache)
        var finished = 0
        cache.shouldFail = true
        await service.receive(delivery { finished += 1 })
        XCTAssertEqual(finished, 0)
        XCTAssertFalse(service.hasAccess)
        XCTAssertNotNil(service.statusMessage)
        cache.shouldFail = false
        await service.receive(ProTransactionDelivery(product: .yearly, evidence: .unverified, environment: .production) { finished += 1 })
        XCTAssertEqual(finished, 0)
        XCTAssertEqual(service.value.reason, .none)
    }

    func testPendingAndCancelledPurchaseDoNotWriteOrGrant() async throws {
        let source = TestProSource()
        let cache = TestProCache()
        let service = service(source, cache)
        for result: ProPurchaseOutcome in [.pending, .cancelled] {
            source.purchaseOutcome = result
            _ = try await service.purchase(.yearly)
            XCTAssertNil(cache.saved)
            XCTAssertFalse(service.hasAccess)
        }
    }

    func testListenersAreAttachedBeforeFirstSnapshotAndStartIsIdempotent() async {
        let source = TestProSource()
        let service = service(source, TestProCache())
        await service.start()
        await service.start()
        XCTAssertEqual(source.calls, ["transactions", "statuses", "snapshot"])
        source.finishStreams()
    }

    func testTransactionStreamAppliesDeliveryAndFinishes() async {
        let source = TestProSource()
        let service = service(source, TestProCache())
        await service.start()
        let finished = expectation(description: "Verified update finished after delivery")
        source.transactions.continuation.yield(delivery { finished.fulfill() })
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(service.value.reason, .yearly)
        source.finishStreams()
    }

    func testOpenAppDropsExpiredOfflineCacheAtBoundary() async {
        let source = TestProSource()
        let cache = TestProCache()
        let boundary = Date().addingTimeInterval(0.1)
        cache.saved = ProEntitlementValue(
            reason: .monthly, expiresAt: boundary.addingTimeInterval(-259200),
            proAccessEndsAt: boundary, verifiedAt: boundary.addingTimeInterval(-300000)
        )
        let service = ProEntitlement(source: source, cache: cache)
        XCTAssertTrue(service.hasAccess)
        let expired = expectation(description: "Published free state at the offline boundary")
        let publication = service.$value.dropFirst().filter { $0.reason == .none }.prefix(1).sink { _ in expired.fulfill() }
        await service.start()
        await fulfillment(of: [expired], timeout: 2)
        XCTAssertEqual(service.value.reason, .none)
        source.finishStreams()
        withExtendedLifetime(publication) {}
    }

    func testRefundThenRepurchaseAndStaleRefundOrdering() async {
        let source = TestProSource()
        let service = service(source, TestProCache())
        let first = purchase(id: 1)
        await service.receive(delivery(first))
        let refund = ProPurchaseEvidence(
            product: .yearly, transactionID: 1, purchasedAt: first.purchasedAt,
            signedAt: instant.addingTimeInterval(10), expiresAt: first.expiresAt, revoked: true
        )
        await service.receive(delivery(refund))
        XCTAssertFalse(service.hasAccess)
        let repurchase = purchase(id: 2, offset: 20)
        await service.receive(delivery(repurchase))
        XCTAssertTrue(service.hasAccess)
        await service.receive(delivery(refund))
        XCTAssertTrue(service.hasAccess, "An older transaction refund must not revoke the new purchase")
    }

    func testDelayedSnapshotCannotOverwriteQueuedRevocation() async {
        let source = TestProSource()
        let service = service(source, TestProCache())
        let purchase = purchase(id: 1)
        source.next = ProStoreSnapshot(purchases: [purchase])
        var resumeSnapshot: CheckedContinuation<Void, Never>?
        source.beforeSnapshot = {
            await withCheckedContinuation { resumeSnapshot = $0 }
        }
        let refresh = Task { await service.refresh() }
        while resumeSnapshot == nil { await Task.yield() }
        let refund = ProPurchaseEvidence(
            product: .yearly, transactionID: 1, purchasedAt: purchase.purchasedAt,
            signedAt: instant.addingTimeInterval(10), expiresAt: purchase.expiresAt, revoked: true
        )
        await service.receive(delivery(refund))
        XCTAssertFalse(service.hasAccess, "Revocation must commit while the older network snapshot is still suspended")
        source.beforeSnapshot = nil
        resumeSnapshot?.resume()
        await refresh.value
        XCTAssertFalse(service.hasAccess)
        await service.refresh()
        XCTAssertFalse(service.hasAccess, "A stale later snapshot must not resurrect the refunded purchase")
    }

    func testRestoreUsesExplicitSyncAndRefreshOnlyForMissingAppTransaction() async throws {
        let source = TestProSource()
        let service = service(source, TestProCache())
        await service.refresh()
        XCTAssertEqual(source.restoreRequests, [])
        try await service.restore()
        XCTAssertEqual(source.restoreRequests, [true])
        source.next.appPurchase = .verified(ProAppPurchase(
            originalVersion: "5", originalPurchaseDate: instant, environment: .production, revoked: false
        ))
        await service.refresh()
        try await service.restore()
        XCTAssertEqual(source.restoreRequests, [true, false])
    }

    func testLaunchRechecksIndependentLifetimeAfterConcurrentSubscriptionEvent() async {
        let source = TestProSource()
        let service = service(source, TestProCache())
        let lifetime = ProPurchaseEvidence(
            product: .lifetime, transactionID: 100, purchasedAt: instant, signedAt: instant
        )
        source.next = ProStoreSnapshot(purchases: [lifetime])
        var resumeSnapshot: CheckedContinuation<Void, Never>?
        source.beforeSnapshot = { await withCheckedContinuation { resumeSnapshot = $0 } }
        let startup = Task { await service.start() }
        while resumeSnapshot == nil { await Task.yield() }
        var refund = purchase()
        refund.revoked = true
        await service.receive(delivery(refund))
        XCTAssertFalse(service.hasAccess)
        source.beforeSnapshot = nil
        resumeSnapshot?.resume()
        await startup.value
        XCTAssertEqual(service.value.reason, .lifetime)
        XCTAssertEqual(source.calls.filter { $0 == "snapshot" }.count, 2)
        source.finishStreams()
    }

    func testDebugOverrideNeverWritesVerifiedCache() async {
        #if DEBUG
        let source = TestProSource()
        let cache = TestProCache()
        let service = service(source, cache)
        let override = ProEntitlementValue(reason: .lifetime, expiresAt: nil, proAccessEndsAt: nil, verifiedAt: instant)
        service.setDebugOverride(override)
        await service.refresh()
        XCTAssertTrue(service.hasAccess)
        XCTAssertNil(cache.saved)
        service.setDebugOverride(nil)
        XCTAssertFalse(service.hasAccess)
        #endif
    }

    func testUnavailableRefreshKeepsActualVerificationTime() async {
        let source = TestProSource()
        let cache = TestProCache()
        var clock = instant
        let service = ProEntitlement(source: source, cache: cache, now: { clock })
        await service.receive(delivery())
        let verified = service.value
        clock = instant.addingTimeInterval(30)
        await service.refresh()
        XCTAssertEqual(service.value, verified)
        XCTAssertEqual(cache.saved?.verifiedAt, instant)
    }

    func testUnverifiedResultStaysDeniedUntilFreshVerifiedEvidenceArrives() async {
        let source = TestProSource()
        let service = service(source, TestProCache())
        await service.receive(delivery())
        XCTAssertTrue(service.hasAccess)
        await service.receive(ProTransactionDelivery(product: .yearly, evidence: .unverified, environment: .production, finish: {}))
        XCTAssertFalse(service.hasAccess)
        await service.refresh()
        XCTAssertFalse(service.hasAccess, "Remembered evidence must not undo a newer verification failure")
        source.next = ProStoreSnapshot(purchases: [purchase()])
        await service.refresh()
        XCTAssertTrue(service.hasAccess)
    }

    private func service(_ source: TestProSource, _ cache: TestProCache) -> ProEntitlement {
        ProEntitlement(source: source, cache: cache, now: { self.instant })
    }

    private func purchase(id: UInt64 = 1, offset: TimeInterval = 0) -> ProPurchaseEvidence {
        ProPurchaseEvidence(
            product: .yearly, transactionID: id,
            purchasedAt: instant.addingTimeInterval(-3600 + offset), signedAt: instant.addingTimeInterval(offset),
            expiresAt: instant.addingTimeInterval(3600 + offset)
        )
    }

    private func delivery(
        _ purchase: ProPurchaseEvidence? = nil, finish: @escaping @MainActor () async -> Void = {}
    ) -> ProTransactionDelivery {
        ProTransactionDelivery(product: .yearly, evidence: .verified(purchase ?? self.purchase()), finish: finish)
    }
}

@MainActor
final class TestProCache: ProEntitlementCaching {
    var saved: ProEntitlementValue?
    var shouldFail = false
    var onSave: ((ProEntitlementValue) -> Void)?
    var records: [ProStoreEnvironment: ProEntitlementValue] = [:]
    func load(environment: ProStoreEnvironment) -> ProEntitlementValue? {
        records[environment] ?? (saved?.environment == environment ? saved : nil)
    }
    func save(_ value: ProEntitlementValue) throws {
        if shouldFail { throw CocoaError(.fileWriteNoPermission) }
        saved = value
        records[value.environment] = value
        onSave?(value)
    }
}

@MainActor
final class TestProSource: ProStoreSource {
    var next = ProStoreSnapshot()
    var calls: [String] = []
    var beforeSnapshot: (() async -> Void)?
    var purchaseOutcome: ProPurchaseOutcome = .cancelled
    var restoreRequests: [Bool] = []
    let transactions = AsyncStream<ProTransactionDelivery>.makeStream()
    let statuses = AsyncStream<ProSubscriptionUpdate>.makeStream()

    func snapshot() async -> ProStoreSnapshot {
        calls.append("snapshot")
        await beforeSnapshot?()
        return next
    }
    func transactionUpdates() -> AsyncStream<ProTransactionDelivery> {
        calls.append("transactions")
        return transactions.stream
    }
    func subscriptionUpdates() -> AsyncStream<ProSubscriptionUpdate> {
        calls.append("statuses")
        return statuses.stream
    }
    func purchase(_ product: ProProductID) async throws -> ProPurchaseOutcome { purchaseOutcome }
    func restore(refreshAppTransaction: Bool) async throws { restoreRequests.append(refreshAppTransaction) }
    func finishStreams() {
        transactions.continuation.finish()
        statuses.continuation.finish()
    }
}
