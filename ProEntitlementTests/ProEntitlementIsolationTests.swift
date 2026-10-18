import Combine
import Foundation
import XCTest
@testable import CodexBarIOS

@MainActor
final class ProEntitlementIsolationTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    func testNonproductionLifetimeCacheCannotBootstrapProductionAccess() async throws {
        for environment: ProStoreEnvironment in [.sandbox, .xcode] {
            let cache = TestProCache()
            let cached = ProEntitlementValue(
                reason: .lifetime, expiresAt: nil, proAccessEndsAt: nil, verifiedAt: instant,
                environment: environment, purchasedAt: instant.addingTimeInterval(-100)
            )
            try cache.save(cached)
            let source = TestProSource()
            source.next.appPurchase = appPurchase(.production)
            let service = service(source, cache)
            XCTAssertFalse(service.hasAccess, "A test-environment cache must not grant access before verification")
            await service.start()
            XCTAssertFalse(service.hasAccess)
            XCTAssertEqual(service.value.environment, .production)
            XCTAssertEqual(cache.load(environment: environment), cached)
            source.finishStreams()
        }
    }

    func testProductionPermanentCacheSurvivesUnavailableStoreKit() async throws {
        for reason: ProEntitlementReason in [.lifetime, .originalPurchaser] {
            let cache = TestProCache()
            let cached = ProEntitlementValue(
                reason: reason, expiresAt: nil, proAccessEndsAt: nil,
                verifiedAt: instant.addingTimeInterval(-31_536_000), environment: .production
            )
            try cache.save(cached)
            let source = TestProSource()
            let service = service(source, cache)
            XCTAssertTrue(service.hasAccess)
            await service.start()
            XCTAssertTrue(service.hasAccess)
            XCTAssertEqual(service.value, cached)
            XCTAssertEqual(cache.load(environment: .production), cached)
            source.finishStreams()
        }
    }

    func testEnvironmentSwitchClearsRememberedPurchasesAndPreservesSeparateCaches() async {
        let source = TestProSource()
        let cache = TestProCache()
        source.next = ProStoreSnapshot(appPurchase: appPurchase(.production), purchases: [purchase()])
        let service = service(source, cache)
        await service.start()
        let production = service.value
        XCTAssertEqual(production.reason, .yearly)

        source.next = ProStoreSnapshot(appPurchase: appPurchase(.sandbox))
        await service.refresh()
        XCTAssertFalse(service.hasAccess, "Remembered production purchases must not grant sandbox access")
        XCTAssertEqual(service.value.environment, .sandbox)
        let sandboxLifetime = ProPurchaseEvidence(
            product: .lifetime, transactionID: 99, purchasedAt: instant, signedAt: instant, environment: .sandbox
        )
        await service.receive(delivery(sandboxLifetime))
        XCTAssertEqual(service.value.reason, .lifetime)
        XCTAssertEqual(service.value.environment, .sandbox)
        XCTAssertEqual(cache.load(environment: .production), production)

        source.next = ProStoreSnapshot(appPurchase: appPurchase(.production))
        await service.refresh()
        XCTAssertEqual(service.value, production, "Returning to production must restore only production access")
        XCTAssertEqual(cache.load(environment: .sandbox)?.reason, .lifetime)
        source.finishStreams()
    }

    func testCachedDeadlinePublishesWhileInitialSnapshotIsSuspended() async throws {
        let source = TestProSource()
        let cache = TestProCache()
        let boundary = Date().addingTimeInterval(0.2)
        try cache.save(ProEntitlementValue(
            reason: .monthly, expiresAt: boundary.addingTimeInterval(-ProEntitlementValue.offlineAllowance),
            proAccessEndsAt: boundary, verifiedAt: boundary.addingTimeInterval(-300_000)
        ))
        let service = ProEntitlement(source: source, cache: cache)
        XCTAssertTrue(service.hasAccess)
        let snapshotStarted = expectation(description: "Initial StoreKit snapshot suspended")
        let expired = expectation(description: "Published expiration without waiting for StoreKit")
        var snapshots: [CheckedContinuation<Void, Never>] = []
        source.beforeSnapshot = {
            await withCheckedContinuation { continuation in
                snapshots.append(continuation)
                if snapshots.count == 1 { snapshotStarted.fulfill() }
            }
        }
        let publication = service.$value.dropFirst().filter { $0.reason == .none }.prefix(1).sink { _ in expired.fulfill() }
        let startup = Task { await service.start() }
        await fulfillment(of: [snapshotStarted, expired], timeout: 2)
        XCTAssertEqual(service.value.reason, .none)
        XCTAssertEqual(cache.load(environment: .production)?.reason, ProEntitlementReason.none)
        source.beforeSnapshot = nil
        for snapshot in snapshots { snapshot.resume() }
        await startup.value
        source.finishStreams()
        withExtendedLifetime(publication) {}
    }

    func testOldRefundCannotRevokeNewerCachedRepurchaseAfterRestart() async {
        let cache = TestProCache()
        let repurchase = purchase()
        let previousService = service(TestProSource(), cache)
        await previousService.receive(delivery(repurchase))
        let restored = service(TestProSource(), cache)
        XCTAssertTrue(restored.hasAccess)
        var oldRefund = purchase(id: 1, offset: -1_000)
        oldRefund.revoked = true
        var finished = 0
        await restored.receive(ProTransactionDelivery(
            product: .yearly, evidence: .verified(oldRefund), finish: { finished += 1 }
        ))
        XCTAssertTrue(restored.hasAccess, "An older refund must not clear a persisted newer purchase")
        XCTAssertEqual(restored.value.purchasedAt, repurchase.purchasedAt)
        XCTAssertEqual(cache.load(environment: .production)?.purchasedAt, repurchase.purchasedAt)
        XCTAssertEqual(finished, 1, "A verified stale delivery still needs to finish after state is saved")
        var currentRefund = repurchase
        currentRefund.revoked = true
        await restored.receive(delivery(currentRefund))
        XCTAssertFalse(restored.hasAccess, "A refund for the granted purchase must still revoke access")
    }

    func testOldSubscriptionStatusCannotRevokeNewerCachedRepurchaseAfterRestart() async {
        let cache = TestProCache()
        let repurchase = purchase()
        let previousService = service(TestProSource(), cache)
        await previousService.receive(delivery(repurchase))
        let restored = service(TestProSource(), cache)
        await restored.receive(ProSubscriptionEvidence(
            purchase: purchase(id: 1, offset: -1_000), signedAt: instant.addingTimeInterval(10),
            state: .expired, renewalVerified: true, willAutoRenew: false, isInBillingRetry: false, graceEndsAt: nil
        ))
        XCTAssertTrue(restored.hasAccess, "An old renewal status must not clear a newer persisted purchase")
        XCTAssertEqual(restored.value.purchasedAt, repurchase.purchasedAt)
        await restored.receive(ProSubscriptionEvidence(
            purchase: repurchase, signedAt: instant.addingTimeInterval(20),
            state: .revoked, renewalVerified: true, willAutoRenew: false, isInBillingRetry: false, graceEndsAt: nil
        ))
        XCTAssertFalse(restored.hasAccess, "Current verified renewal revocation must still take effect")
    }

    func testUnverifiedForeignOrUnknownTransactionCannotClearProductionBeforeFirstSnapshot() async throws {
        for environment: ProStoreEnvironment? in [.sandbox, .xcode, nil] {
            let cache = TestProCache()
            let previousService = service(TestProSource(), cache)
            await previousService.receive(delivery(purchase()))
            let production = try XCTUnwrap(cache.load(environment: .production))
            let restored = service(TestProSource(), cache)
            var finished = false
            await restored.receive(ProTransactionDelivery(
                product: .yearly, evidence: .unverified, environment: environment, finish: { finished = true }
            ))
            XCTAssertTrue(restored.hasAccess)
            XCTAssertEqual(restored.value, production)
            XCTAssertEqual(cache.load(environment: .production), production)
            if let environment { XCTAssertNil(cache.load(environment: environment)) }
            XCTAssertNil(restored.statusMessage)
            XCTAssertFalse(finished)
        }
    }

    func testUnverifiedTestEnvironmentStatusCannotClearProductionBeforeFirstSnapshot() async throws {
        for environment: ProStoreEnvironment in [.sandbox, .xcode] {
            let cache = TestProCache()
            let previousService = service(TestProSource(), cache)
            await previousService.receive(delivery(purchase()))
            let production = try XCTUnwrap(cache.load(environment: .production))
            let restored = service(TestProSource(), cache)
            await restored.receive(ProSubscriptionUpdate.unverified(product: .yearly, environment: environment))
            XCTAssertTrue(restored.hasAccess)
            XCTAssertEqual(restored.value, production)
            XCTAssertEqual(cache.load(environment: .production), production)
            XCTAssertNil(cache.load(environment: environment))
        }
    }

    func testUnverifiedSnapshotFailuresAreScopedToTheirEnvironment() async {
        let source = TestProSource()
        let cache = TestProCache()
        source.next = ProStoreSnapshot(appPurchase: appPurchase(.production), purchases: [purchase()])
        let service = service(source, cache)
        await service.start()
        let production = service.value
        for environment: ProStoreEnvironment in [.sandbox, .xcode] {
            source.next = ProStoreSnapshot(unverifiedPurchases: [ProUnverifiedPurchase(product: .yearly, environment: environment)])
            await service.refresh()
            XCTAssertEqual(service.value, production)
            XCTAssertEqual(cache.load(environment: .production), production)
            XCTAssertNil(service.statusMessage)
        }
        source.next = ProStoreSnapshot(unverifiedPurchases: [ProUnverifiedPurchase(product: .yearly, environment: .production)])
        await service.refresh()
        XCTAssertFalse(service.hasAccess)
        XCTAssertNotNil(service.statusMessage)
        source.finishStreams()
    }

    func testUnverifiedAppPurchaseCannotRevokeAnotherEnvironmentOrUnknownPartition() async throws {
        let cache = TestProCache()
        let production = ProEntitlementValue(
            reason: .originalPurchaser, expiresAt: nil, proAccessEndsAt: nil, verifiedAt: instant
        )
        try cache.save(production)
        let source = TestProSource()
        let service = service(source, cache)
        for environment: ProStoreEnvironment? in [.sandbox, .xcode, nil] {
            source.next = ProStoreSnapshot(appPurchase: .unverified, appVerificationEnvironment: environment)
            await service.refresh()
            XCTAssertEqual(service.value, production)
            XCTAssertEqual(cache.load(environment: .production), production)
            XCTAssertNil(service.statusMessage)
        }
        source.next = ProStoreSnapshot(appPurchase: .unverified, appVerificationEnvironment: .production)
        await service.refresh()
        XCTAssertFalse(service.hasAccess)
        XCTAssertNotNil(service.statusMessage)
    }

    func testFailedSaveRetainsAppDenialAcrossUnrelatedVerifiedDelivery() async {
        let revoked = ProVerification.verified(ProAppPurchase(
            originalVersion: "1", originalPurchaseDate: instant, environment: .production, revoked: true
        ))
        for evidence: ProVerification<ProAppPurchase> in [.unverified, revoked] {
            let source = TestProSource()
            let cache = TestProCache()
            source.next = ProStoreSnapshot(appPurchase: appPurchase(.production))
            let service = ProEntitlement(
                source: source, cache: cache, originalPolicy: ProOriginalPurchaserPolicy(qualifies: { _ in true }),
                now: { self.instant }
            )
            await service.refresh()
            XCTAssertEqual(service.value.reason, .originalPurchaser)
            cache.shouldFail = true
            source.next = ProStoreSnapshot(appPurchase: evidence, appVerificationEnvironment: .production)
            await service.refresh()
            XCTAssertFalse(service.hasAccess)
            cache.shouldFail = false
            await service.receive(delivery(purchase()))
            XCTAssertEqual(service.value.reason, .yearly, "An unrelated verified IAP must not restore denied original-purchaser access")
            XCTAssertEqual(cache.load(environment: .production)?.reason, .yearly)
        }
    }

    func testUnverifiedSubscriptionStreamImmediatelyDeniesAndWarns() async {
        let source = TestProSource()
        source.next = ProStoreSnapshot(purchases: [purchase()])
        let cache = TestProCache()
        let service = service(source, cache)
        await service.start()
        XCTAssertTrue(service.hasAccess)
        let warning = expectation(description: "Unverified subscription update publishes a warning")
        let observation = service.$statusMessage.compactMap { $0 }.prefix(1).sink { _ in warning.fulfill() }
        source.statuses.continuation.yield(.unverified(product: .yearly, environment: .production))
        await fulfillment(of: [warning], timeout: 2)
        XCTAssertFalse(service.hasAccess)
        XCTAssertEqual(cache.load(environment: .production)?.reason, ProEntitlementReason.none)
        XCTAssertEqual(source.calls.filter { $0 == "snapshot" }.count, 1, "The update must apply without another refresh")
        source.finishStreams()
        withExtendedLifetime(observation) {}
    }

    private func service(_ source: TestProSource, _ cache: TestProCache) -> ProEntitlement {
        ProEntitlement(source: source, cache: cache, now: { self.instant })
    }

    private func appPurchase(_ environment: ProStoreEnvironment) -> ProVerification<ProAppPurchase> {
        .verified(ProAppPurchase(originalVersion: "500", originalPurchaseDate: instant, environment: environment, revoked: false))
    }

    private func purchase(id: UInt64 = 2, offset: TimeInterval = 0) -> ProPurchaseEvidence {
        ProPurchaseEvidence(
            product: .yearly, transactionID: id, purchasedAt: instant.addingTimeInterval(-100 + offset),
            signedAt: instant, expiresAt: instant.addingTimeInterval(3_600)
        )
    }

    private func delivery(_ purchase: ProPurchaseEvidence) -> ProTransactionDelivery {
        ProTransactionDelivery(product: purchase.product, evidence: .verified(purchase), finish: {})
    }
}
