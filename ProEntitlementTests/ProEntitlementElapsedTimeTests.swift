import Foundation
import XCTest
@testable import CodexBarIOS

func testProClock(_ date: Date) -> ProEntitlementClockSample {
    ProEntitlementClockSample(wallDate: date, continuousSeconds: date.timeIntervalSince1970, continuityID: "test-boot")
}

func testProAnchor(_ date: Date) -> ProEntitlementClockAnchor {
    ProEntitlementClockAnchor(
        anchorDate: date, continuousSeconds: date.timeIntervalSince1970, continuityID: "test-boot", latestSignedAt: date
    )
}

@MainActor
final class ProEntitlementElapsedTimeTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    func testRepeatedRollbackAfterVerificationCannotExtendAccessAcrossRelaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = ProEntitlementCache(fileURL: folder.appendingPathComponent("entitlement.json"))
        var sample = clock(elapsed: 0)
        let source = TestProSource()
        source.next = snapshot()
        let service = ProEntitlement(source: source, cache: cache, now: { sample.wallDate }, clock: { _ in sample })
        await service.refresh()
        let original = service.value.clockAnchor
        for elapsed: TimeInterval in [100, 100_000, 200_000, 262_799] {
            sample = clock(elapsed: elapsed, wallOffset: 10)
            await service.refresh()
            XCTAssertTrue(service.hasAccess)
            XCTAssertEqual(service.value.clockAnchor, original, "Re-verifying the same JWS must not reset elapsed time")
        }
        let relaunched = ProEntitlement(source: source, cache: cache, now: { sample.wallDate }, clock: { _ in sample })
        XCTAssertTrue(relaunched.hasAccess)
        sample = clock(elapsed: 262_800, wallOffset: 10)
        XCTAssertFalse(relaunched.hasAccess)
        XCTAssertFalse(try XCTUnwrap(cache.load()).hasAccess(at: sample), "The shared reader must enforce the same boundary")
        await relaunched.refresh()
        XCTAssertEqual(relaunched.value.reason, .none)
        XCTAssertEqual(relaunched.value.clockAnchor?.latestSignedAt, original?.latestSignedAt)
        XCTAssertEqual(relaunched.value.clockAnchor?.anchorDate, instant.addingTimeInterval(262_800))
        sample = clock(elapsed: 400_000, wallOffset: 1)
        let thirdLaunch = ProEntitlement(source: source, cache: cache, now: { sample.wallDate }, clock: { _ in sample })
        await thirdLaunch.refresh()
        XCTAssertFalse(thirdLaunch.hasAccess, "Persisted free state must retain the signed-time watermark")
    }

    func testNewBootOrMissingContinuityDeniesReplayRegardlessOfCounterDirection() {
        let initial = resolve(snapshot(), cached: .free, sample: clock(elapsed: 0))
        for counter: TimeInterval in [1, 1_000_000] {
            for boot: String? in ["new-boot", nil] {
                let sample = ProEntitlementClockSample(
                    wallDate: instant.addingTimeInterval(10), continuousSeconds: counter, continuityID: boot
                )
                XCTAssertFalse(initial.hasAccess(at: sample))
                let denied = resolve(snapshot(), cached: initial, sample: sample)
                XCTAssertEqual(denied.reason, .none)
                XCTAssertEqual(denied.clockAnchor, initial.clockAnchor)
                XCTAssertFalse(resolve(snapshot(), cached: denied, sample: sample).hasAccess(at: sample))
            }
        }
    }

    func testNewerSignedEvidenceRestoresClockAfterRebootAndSleepCountsTowardDeadline() {
        let initial = resolve(snapshot(), cached: .free, sample: clock(elapsed: 0))
        let sample = ProEntitlementClockSample(wallDate: instant, continuousSeconds: 10, continuityID: "new-boot")
        let recovered = resolve(snapshot(signedOffset: 100), cached: initial, sample: sample)
        XCTAssertTrue(recovered.hasAccess(at: sample))
        XCTAssertEqual(recovered.clockAnchor?.anchorDate, instant.addingTimeInterval(100))
        let afterSleep = ProEntitlementClockSample(wallDate: instant, continuousSeconds: 10 + 4 * 86_400, continuityID: "new-boot")
        XCTAssertFalse(recovered.hasAccess(at: afterSleep))
    }

    func testNewerEvidenceOnSameBootDoesNotResetElapsedTimeAfterRollback() {
        let initial = resolve(snapshot(), cached: .free, sample: clock(elapsed: 0))
        let sample = clock(elapsed: 200_000, wallOffset: 10)
        let updated = resolve(snapshot(signedOffset: 100), cached: initial, sample: sample)
        XCTAssertEqual(updated.clockAnchor?.anchorDate, instant.addingTimeInterval(200_000))
        XCTAssertFalse(updated.hasAccess(at: clock(elapsed: 262_800, wallOffset: 10)))
    }

    func testExpiredCalendarFloorSurvivesRebootAndDelayedNewerSignature() {
        let initial = resolve(snapshot(), cached: .free, sample: clock(elapsed: 0))
        let expired = resolve(snapshot(), cached: initial, sample: clock(elapsed: 300_000, wallOffset: 10))
        XCTAssertEqual(expired.reason, .none)
        XCTAssertEqual(expired.clockAnchor?.anchorDate, instant.addingTimeInterval(300_000))
        let reboot = ProEntitlementClockSample(wallDate: instant, continuousSeconds: 1, continuityID: "new-boot")
        let replayed = resolve(snapshot(signedOffset: 100), cached: expired, sample: reboot)
        XCTAssertFalse(replayed.hasAccess(at: reboot))
        XCTAssertEqual(replayed.clockAnchor?.anchorDate, expired.clockAnchor?.anchorDate)
    }

    func testPermanentAccessSurvivesClockRollbackAndUnknownBoot() {
        let sample = ProEntitlementClockSample(wallDate: .distantPast, continuousSeconds: 0, continuityID: nil)
        for reason: ProEntitlementReason in [.lifetime, .originalPurchaser] {
            let value = ProEntitlementValue(reason: reason, expiresAt: nil, proAccessEndsAt: nil, verifiedAt: instant)
            XCTAssertTrue(value.hasAccess(at: sample))
        }
    }

    func testRestoreRefreshesVerifiedAppTransactionAfterLostBootContinuity() async throws {
        let source = TestProSource()
        source.next = snapshot()
        source.next.appPurchase = .verified(ProAppPurchase(
            originalVersion: "5", originalPurchaseDate: instant, environment: .production, revoked: false, signedAt: instant
        ))
        let cache = TestProCache()
        var sample = clock(elapsed: 0)
        let first = ProEntitlement(source: source, cache: cache, now: { sample.wallDate }, clock: { _ in sample })
        await first.refresh()
        sample = ProEntitlementClockSample(wallDate: instant, continuousSeconds: 1, continuityID: "new-boot")
        let relaunched = ProEntitlement(source: source, cache: cache, now: { sample.wallDate }, clock: { _ in sample })
        await relaunched.refresh()
        XCTAssertFalse(relaunched.hasAccess)
        XCTAssertEqual(source.restoreRequests, [], "Automatic refresh must never request interactive restore")
        try await relaunched.restore()
        XCTAssertEqual(source.restoreRequests, [true])
        source.next.appPurchase = .verified(ProAppPurchase(
            originalVersion: "5", originalPurchaseDate: instant, environment: .production, revoked: false,
            signedAt: instant.addingTimeInterval(100)
        ))
        await relaunched.refresh()
        XCTAssertTrue(relaunched.hasAccess, "A newer signed app transaction can restore continuity for an existing subscription")
    }

    func testLegacySubscriptionWithoutClockAnchorCannotBootstrapOfflineAccess() {
        let legacy = ProEntitlementValue(
            reason: .yearly, expiresAt: instant.addingTimeInterval(3_600),
            proAccessEndsAt: instant.addingTimeInterval(262_800), verifiedAt: instant
        )
        XCTAssertFalse(legacy.hasAccess(at: clock(elapsed: 0)))
        XCTAssertTrue(resolve(snapshot(), cached: legacy, sample: clock(elapsed: 0)).hasAccess(at: clock(elapsed: 0)))
    }

    private func clock(elapsed: TimeInterval, wallOffset: TimeInterval? = nil) -> ProEntitlementClockSample {
        ProEntitlementClockSample(
            wallDate: instant.addingTimeInterval(wallOffset ?? elapsed), continuousSeconds: 1000 + elapsed, continuityID: "boot-a"
        )
    }

    private func snapshot(signedOffset: TimeInterval = 0) -> ProStoreSnapshot {
        ProStoreSnapshot(purchases: [ProPurchaseEvidence(
            product: .monthly, transactionID: 1, purchasedAt: instant.addingTimeInterval(-100),
            signedAt: instant.addingTimeInterval(signedOffset), expiresAt: instant.addingTimeInterval(3_600)
        ),
        ])
    }

    private func resolve(_ snapshot: ProStoreSnapshot, cached: ProEntitlementValue, sample: ProEntitlementClockSample) -> ProEntitlementValue {
        ProEntitlementResolver.resolve(
            snapshot, cached: cached, originalPolicy: ProOriginalPurchaserPolicy(), now: sample.wallDate, clock: sample
        )
    }
}
