import Foundation
import XCTest
@testable import CodexBarIOS

@MainActor
final class ProEntitlementClockRecoveryTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    func testUnknownMarkerRollbackPreservesPaidCacheUntilOriginalMarkerReturns() async throws {
        try await checkTemporaryClockUncertainty(recoverOriginalMarker: true)
    }

    func testUnknownMarkerRollbackPreservesPaidCacheUntilCalendarAdvances() async throws {
        try await checkTemporaryClockUncertainty(recoverOriginalMarker: false)
    }

    func testFailedAtomicWriteDuringClockUncertaintyKeepsRecoverablePaidCache() async throws {
        let folder = try makeFolder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let url = folder.appendingPathComponent("decision.json")
        let clock = RecoveryClock(sample(0))
        try await persistPaidDecision(at: url, clock: clock)
        let original = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        XCTAssertThrowsError(try ProEntitlementCache(fileURL: url).save(.free))
        clock.sample = ProEntitlementClockSample(wallDate: instant.addingTimeInterval(-60), continuousSeconds: 10, continuityID: nil)
        let restarted = service(source: TestProSource(), cacheURL: url, clock: clock)

        await restarted.refresh()

        XCTAssertFalse(restarted.hasAccess)
        XCTAssertNotNil(restarted.statusMessage)
        XCTAssertEqual(restarted.value.reason, .monthly, "A storage failure is not a verified denial of this purchase")
        XCTAssertEqual(try Data(contentsOf: url), original, "Temporary clock uncertainty must not overwrite the recoverable grant")
        clock.sample = sample(30)
        XCTAssertTrue(restarted.hasAccess)
        XCTAssertTrue(service(source: TestProSource(), cacheURL: url, clock: clock).hasAccess)
    }

    func testFutureClockExpiryRequiresFreshExplicitRestoreToLowerPersistedFloor() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("decision.json")
        let clock = RecoveryClock(sample(0))
        try await persistFutureClockExpiry(at: url, clock: clock)
        clock.sample = correctedSample()
        let source = TestProSource()
        source.next = snapshot(signedOffset: 10)
        let restored = service(source: source, cacheURL: url, clock: clock)
        await restored.refresh()
        XCTAssertFalse(restored.hasAccess)
        XCTAssertEqual(source.restoreRequests, [], "Ordinary refresh must not initiate interactive StoreKit restore")
        let floor = try XCTUnwrap(ProEntitlementCache(fileURL: url).load()?.clockAnchor?.knownDate)
        XCTAssertEqual(floor, instant.addingTimeInterval(400_000))

        try await restored.restore()
        XCTAssertEqual(source.restoreRequests, [true])
        XCTAssertFalse(restored.hasAccess, "Restore without fresh signed evidence must keep the observed time floor")
        XCTAssertEqual(ProEntitlementCache(fileURL: url).load()?.clockAnchor?.knownDate, floor)

        source.next.freshClockEvidence = ProFreshClockEvidence(signedAt: instant.addingTimeInterval(10), environment: .production)
        try await restored.restore()
        XCTAssertEqual(source.restoreRequests, [true, true])
        XCTAssertFalse(restored.hasAccess, "The same signed evidence cannot authorize lowering the floor")
        XCTAssertEqual(ProEntitlementCache(fileURL: url).load()?.clockAnchor?.knownDate, floor)

        source.next = snapshot(signedOffset: 30)
        source.next.freshClockEvidence = ProFreshClockEvidence(signedAt: instant.addingTimeInterval(30), environment: .production)
        try await restored.restore()
        XCTAssertEqual(source.restoreRequests, [true, true, true])
        XCTAssertTrue(restored.hasAccess)
        XCTAssertEqual(restored.value.reason, .monthly)
        XCTAssertEqual(restored.value.expiresAt, instant.addingTimeInterval(3600))
        let saved = try XCTUnwrap(ProEntitlementCache(fileURL: url).load())
        XCTAssertEqual(saved.reason, .monthly)
        XCTAssertEqual(saved.clockAnchor?.knownDate, instant.addingTimeInterval(30))
        XCTAssertEqual(saved.clockAnchor?.latestSignedAt, instant.addingTimeInterval(30))
        XCTAssertFalse(try Data(contentsOf: url).isEmpty)
        let nextLaunch = service(source: TestProSource(), cacheURL: url, clock: clock)
        XCTAssertTrue(nextLaunch.hasAccess, "The corrected verified decision must survive a fresh cache and service")
    }

    func testSandboxFreshClockEvidenceCannotLowerProductionFloor() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("decision.json")
        let clock = RecoveryClock(sample(0))
        try await persistFutureClockExpiry(at: url, clock: clock)
        clock.sample = correctedSample()
        let source = TestProSource()
        source.next = snapshot()
        source.next.freshClockEvidence = ProFreshClockEvidence(signedAt: instant.addingTimeInterval(30), environment: .sandbox)
        let restored = service(source: source, cacheURL: url, clock: clock)

        try await restored.restore()

        XCTAssertEqual(source.restoreRequests, [true])
        XCTAssertFalse(restored.hasAccess)
        XCTAssertEqual(restored.value.environment, .production)
        let production = try XCTUnwrap(ProEntitlementCache(fileURL: url).load())
        XCTAssertEqual(production.reason, .none)
        XCTAssertEqual(production.clockAnchor?.knownDate, instant.addingTimeInterval(400_000))
        XCTAssertEqual(production.clockAnchor?.latestSignedAt, instant)
        let productionBytes = try Data(contentsOf: url)

        source.next = snapshot(signedOffset: 30, environment: .sandbox)
        source.next.freshClockEvidence = ProFreshClockEvidence(signedAt: instant.addingTimeInterval(30), environment: .sandbox)
        try await restored.restore()

        XCTAssertEqual(restored.value.environment, .sandbox)
        XCTAssertTrue(restored.hasAccess, "Sandbox reset must work within its own cache partition")
        XCTAssertEqual(ProEntitlementCache(fileURL: url).load(environment: .sandbox)?.reason, .monthly)
        XCTAssertEqual(try Data(contentsOf: url), productionBytes, "Sandbox activity must not rewrite the production file")
        let nextProductionLaunch = service(source: TestProSource(), cacheURL: url, clock: clock)
        XCTAssertEqual(nextProductionLaunch.value.environment, .production)
        XCTAssertFalse(nextProductionLaunch.hasAccess)
        XCTAssertEqual(nextProductionLaunch.value.clockAnchor?.knownDate, instant.addingTimeInterval(400_000))
    }

    func testNewerVerifiedBillingGraceRestoresPurchaseAfterPersistedDenial() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("decision.json")
        let clock = RecoveryClock(sample(0))
        let purchase = purchase(expiresAfter: 5)
        try await persistBillingRetryDenial(purchase, at: url, clock: clock)
        clock.sample = sample(20)
        let source = TestProSource()
        let restarted = service(source: source, cacheURL: url, clock: clock)
        await restarted.start()
        defer { source.finishStreams() }
        XCTAssertFalse(restarted.hasAccess)
        XCTAssertEqual(restarted.value.reason, .none)
        await restarted.receive(ProTransactionDelivery(product: .monthly, evidence: .unverified, environment: .production, finish: {}))
        XCTAssertFalse(restarted.hasAccess)
        let grace = ProSubscriptionEvidence(
            purchase: purchase, signedAt: instant.addingTimeInterval(20), state: .grace,
            renewalVerified: true, willAutoRenew: true, isInBillingRetry: true,
            graceEndsAt: instant.addingTimeInterval(3600)
        )

        await restarted.receive(grace)

        XCTAssertTrue(restarted.hasAccess, "Newer verified renewal status must supersede the earlier billing retry denial")
        XCTAssertEqual(restarted.value.reason, .billingGrace)
        XCTAssertEqual(restarted.value.purchasedAt, purchase.purchasedAt)
        XCTAssertEqual(restarted.value.expiresAt, grace.graceEndsAt)
        XCTAssertEqual(restarted.value.proAccessEndsAt, instant.addingTimeInterval(3600 + ProEntitlementValue.offlineAllowance))
        let saved = try XCTUnwrap(ProEntitlementCache(fileURL: url).load())
        XCTAssertEqual(saved.reason, .billingGrace)
        XCTAssertEqual(saved.expiresAt, grace.graceEndsAt)
        let nextLaunch = service(source: TestProSource(), cacheURL: url, clock: clock)
        XCTAssertTrue(nextLaunch.hasAccess)
        XCTAssertEqual(nextLaunch.value.reason, .billingGrace)
    }

    private func checkTemporaryClockUncertainty(recoverOriginalMarker: Bool) async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("decision.json")
        let clock = RecoveryClock(sample(0))
        try await persistPaidDecision(at: url, clock: clock)
        let original = try XCTUnwrap(ProEntitlementCache(fileURL: url).load())
        clock.sample = ProEntitlementClockSample(
            wallDate: instant.addingTimeInterval(-60), continuousSeconds: 10, continuityID: nil
        )
        let source = TestProSource()
        let restarted = service(source: source, cacheURL: url, clock: clock)
        XCTAssertFalse(restarted.hasAccess)

        await restarted.start()
        defer { source.finishStreams() }

        XCTAssertFalse(restarted.hasAccess, "Observed backward calendar must not grant access while continuity is unknown")
        XCTAssertEqual(source.calls, ["transactions", "statuses", "snapshot"])
        XCTAssertEqual(restarted.value.reason, .monthly, "Temporary clock uncertainty must not erase verified purchase metadata")
        XCTAssertEqual(try XCTUnwrap(ProEntitlementCache(fileURL: url).load()), original)
        XCTAssertFalse(try Data(contentsOf: url).isEmpty)
        clock.sample = ProEntitlementClockSample(
            wallDate: instant.addingTimeInterval(recoverOriginalMarker ? -60 : 30),
            continuousSeconds: recoverOriginalMarker ? 1030 : 30,
            continuityID: recoverOriginalMarker ? "recovery-boot" : nil
        )

        XCTAssertTrue(restarted.hasAccess, "The preserved purchase should recover when usable time evidence returns")
        await restarted.refresh()
        XCTAssertTrue(restarted.hasAccess)
        let saved = try XCTUnwrap(ProEntitlementCache(fileURL: url).load())
        XCTAssertEqual(saved.reason, .monthly)
        XCTAssertEqual(saved.expiresAt, original.expiresAt)
        XCTAssertEqual(saved.purchasedAt, original.purchasedAt)
        let nextLaunch = service(source: TestProSource(), cacheURL: url, clock: clock)
        XCTAssertTrue(nextLaunch.hasAccess)
    }

    private func persistPaidDecision(at url: URL, clock: RecoveryClock) async throws {
        let source = TestProSource()
        source.next = snapshot()
        let first = service(source: source, cacheURL: url, clock: clock)
        await first.refresh()
        XCTAssertTrue(first.hasAccess)
        XCTAssertEqual(try XCTUnwrap(ProEntitlementCache(fileURL: url).load()).reason, .monthly)
    }

    private func persistFutureClockExpiry(at url: URL, clock: RecoveryClock) async throws {
        let source = TestProSource()
        source.next = snapshot()
        let first = service(source: source, cacheURL: url, clock: clock)
        await first.refresh()
        XCTAssertTrue(first.hasAccess)
        clock.sample = ProEntitlementClockSample(
            wallDate: instant.addingTimeInterval(400_000), continuousSeconds: 1001, continuityID: "recovery-boot"
        )
        XCTAssertFalse(first.hasAccess, "Observed future time must immediately enforce the access deadline")
        source.next = ProStoreSnapshot()
        await first.refresh()
        XCTAssertEqual(first.value.reason, .none)
        let saved = try XCTUnwrap(ProEntitlementCache(fileURL: url).load())
        XCTAssertEqual(saved.reason, .none)
        XCTAssertEqual(saved.clockAnchor?.knownDate, instant.addingTimeInterval(400_000))
        XCTAssertEqual(saved.clockAnchor?.latestSignedAt, instant)
    }

    private func persistBillingRetryDenial(_ purchase: ProPurchaseEvidence, at url: URL, clock: RecoveryClock) async throws {
        let source = TestProSource()
        source.next = ProStoreSnapshot(purchases: [purchase])
        let first = service(source: source, cacheURL: url, clock: clock)
        await first.refresh()
        XCTAssertTrue(first.hasAccess)
        clock.sample = sample(10)
        await first.receive(ProSubscriptionEvidence(
            purchase: purchase, signedAt: instant.addingTimeInterval(10), state: .billingRetry,
            renewalVerified: true, willAutoRenew: true, isInBillingRetry: true, graceEndsAt: nil
        ))
        XCTAssertFalse(first.hasAccess)
        XCTAssertEqual(first.value.reason, .none)
        let saved = try XCTUnwrap(ProEntitlementCache(fileURL: url).load())
        XCTAssertEqual(saved.reason, .none)
        XCTAssertEqual(saved.purchaseDenials.first?.signedAt, instant.addingTimeInterval(10))
    }

    private func snapshot(signedOffset: TimeInterval = 0, environment: ProStoreEnvironment = .production) -> ProStoreSnapshot {
        ProStoreSnapshot(
            appPurchase: .verified(ProAppPurchase(
                originalVersion: "5", originalPurchaseDate: instant.addingTimeInterval(-3600),
                environment: environment, revoked: false, signedAt: instant.addingTimeInterval(signedOffset)
            )),
            purchases: [purchase(environment: environment)]
        )
    }

    private func purchase(expiresAfter: TimeInterval = 3600, environment: ProStoreEnvironment = .production) -> ProPurchaseEvidence {
        ProPurchaseEvidence(
            product: .monthly, transactionID: 1, purchasedAt: instant.addingTimeInterval(-3600),
            signedAt: instant, expiresAt: instant.addingTimeInterval(expiresAfter), environment: environment
        )
    }

    private func sample(_ offset: TimeInterval) -> ProEntitlementClockSample {
        ProEntitlementClockSample(
            wallDate: instant.addingTimeInterval(offset), continuousSeconds: 1000 + offset, continuityID: "recovery-boot"
        )
    }

    private func correctedSample() -> ProEntitlementClockSample {
        ProEntitlementClockSample(
            wallDate: instant.addingTimeInterval(30), continuousSeconds: 1001, continuityID: "recovery-boot"
        )
    }

    private func service(source: TestProSource, cacheURL: URL, clock: RecoveryClock) -> ProEntitlement {
        ProEntitlement(
            source: source, cache: ProEntitlementCache(fileURL: cacheURL),
            now: { clock.sample.wallDate }, clock: { _ in clock.sample }
        )
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

@MainActor
private final class RecoveryClock {
    var sample: ProEntitlementClockSample

    init(_ sample: ProEntitlementClockSample) {
        self.sample = sample
    }
}
