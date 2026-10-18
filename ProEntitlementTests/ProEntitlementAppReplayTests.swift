import Foundation
import XCTest
@testable import CodexBarIOS

@MainActor
final class ProEntitlementAppReplayTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    func testAppRevocationSurvivesColdStartAndStaleReplayUntilNewerVerifiedRestore() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("decision.json")
        let source = TestProSource()
        defer { source.finishStreams() }
        source.next = snapshot(signedOffset: 0)
        let first = service(source, cacheURL: url)
        await first.refresh()
        XCTAssertTrue(first.hasAccess)
        XCTAssertEqual(first.value.reason, .originalPurchaser)

        source.next = snapshot(signedOffset: 10, revoked: true)
        await first.refresh()
        XCTAssertFalse(first.hasAccess)
        let savedDenial = try XCTUnwrap(ProEntitlementCache(fileURL: url).load())
        XCTAssertEqual(savedDenial.reason, .none)
        XCTAssertEqual(savedDenial.appPurchaseDeniedAt, instant.addingTimeInterval(10))

        let coldSource = TestProSource()
        defer { coldSource.finishStreams() }
        let restarted = service(coldSource, cacheURL: url)
        XCTAssertFalse(restarted.hasAccess)
        await restarted.refresh()
        XCTAssertEqual(restarted.value.appPurchaseDeniedAt, savedDenial.appPurchaseDeniedAt)

        for offset: TimeInterval in [0, 10] {
            coldSource.next = snapshot(signedOffset: offset)
            await restarted.refresh()
            XCTAssertFalse(restarted.hasAccess, "An app purchase signed at or before the saved revocation must stay denied")
            let saved = try XCTUnwrap(ProEntitlementCache(fileURL: url).load())
            XCTAssertEqual(saved.reason, .none)
            XCTAssertEqual(saved.appPurchaseDeniedAt, savedDenial.appPurchaseDeniedAt)
        }

        prepareFreshAppRestore(coldSource)
        try await restarted.restore()
        XCTAssertEqual(coldSource.restoreRequests, [true])
        XCTAssertTrue(restarted.hasAccess)
        XCTAssertEqual(restarted.value.reason, .originalPurchaser)
        let savedGrant = try XCTUnwrap(ProEntitlementCache(fileURL: url).load())
        XCTAssertEqual(savedGrant.reason, .originalPurchaser)
        XCTAssertEqual(savedGrant.appPurchaseDeniedAt, savedDenial.appPurchaseDeniedAt)
        XCTAssertEqual(savedGrant, restarted.value)
        XCTAssertTrue(service(TestProSource(), cacheURL: url).hasAccess, "The restored grant must survive another disk-backed cold start")

        try await restarted.restore()
        XCTAssertEqual(coldSource.restoreRequests, [true, false], "Newer positive app evidence must no longer force an app refresh")
        XCTAssertTrue(restarted.hasAccess)
    }

    func testRestoreRefreshesVerifiedRevokedAppPurchaseWithHealthyClock() async throws {
        let source = TestProSource()
        defer { source.finishStreams() }
        source.next = snapshot(signedOffset: 10, revoked: true)
        let service = ProEntitlement(
            source: source, cache: TestProCache(),
            originalPolicy: ProOriginalPurchaserPolicy(qualifies: { _ in true }),
            now: { self.instant.addingTimeInterval(30) }, clock: testProClock
        )
        await service.refresh()
        XCTAssertFalse(service.hasAccess)
        prepareFreshAppRestore(source)

        try await service.restore()

        XCTAssertEqual(source.restoreRequests, [true])
        XCTAssertTrue(service.hasAccess)
        XCTAssertEqual(service.value.reason, .originalPurchaser)
    }

    private func prepareFreshAppRestore(_ source: TestProSource) {
        source.beforeRestore = { [weak source] refreshAppTransaction in
            guard refreshAppTransaction, let source else { return }
            source.next = self.snapshot(signedOffset: 20)
            source.next.freshClockEvidence = ProFreshClockEvidence(
                signedAt: self.instant.addingTimeInterval(20), environment: .production
            )
        }
    }

    private func service(_ source: TestProSource, cacheURL: URL) -> ProEntitlement {
        ProEntitlement(
            source: source, cache: ProEntitlementCache(fileURL: cacheURL),
            originalPolicy: ProOriginalPurchaserPolicy(qualifies: { _ in true }),
            now: { self.instant.addingTimeInterval(30) }, clock: testProClock
        )
    }

    private func snapshot(signedOffset: TimeInterval, revoked: Bool = false) -> ProStoreSnapshot {
        ProStoreSnapshot(appPurchase: .verified(ProAppPurchase(
            originalVersion: "1", originalPurchaseDate: instant.addingTimeInterval(-86_400),
            environment: .production, revoked: revoked, signedAt: instant.addingTimeInterval(signedOffset)
        )))
    }
}
