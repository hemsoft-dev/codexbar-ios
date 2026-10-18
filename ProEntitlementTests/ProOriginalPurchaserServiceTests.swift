import Foundation
import XCTest
@testable import CodexBarIOS

@MainActor
final class ProOriginalPurchaserServiceTests: XCTestCase {
    private let instant = ProOriginalPurchaserPolicy.cutover.addingTimeInterval(100)

    func testDefaultServicePolicyPersistsOriginalGrantAndRevocationThroughColdStarts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("entitlement.json")
        let source = TestProSource()
        defer { source.finishStreams() }
        source.next = snapshot()
        let service = ProEntitlement(source: source, cache: ProEntitlementCache(fileURL: url), now: { self.instant })
        await service.refresh()
        XCTAssertTrue(service.isResolved)
        XCTAssertTrue(service.hasAccess)
        XCTAssertEqual(service.value.reason, .originalPurchaser)
        XCTAssertNil(service.value.proAccessEndsAt)

        let offline = TestProSource()
        defer { offline.finishStreams() }
        let restart = ProEntitlement(source: offline, cache: ProEntitlementCache(fileURL: url), now: { self.instant })
        await restart.refresh()
        XCTAssertTrue(restart.hasAccess, "Unavailable evidence preserves the previous verified original purchase")

        offline.next = snapshot(revoked: true, signedOffset: 1)
        await restart.refresh()
        XCTAssertFalse(restart.hasAccess)
        let denied = try XCTUnwrap(ProEntitlementCache(fileURL: url).load())
        XCTAssertEqual(denied.reason, .none)
        XCTAssertEqual(denied.appPurchaseDeniedAt, instant.addingTimeInterval(1))
        let afterRevocation = ProEntitlement(source: source, cache: ProEntitlementCache(fileURL: url), now: { self.instant })
        await afterRevocation.refresh()
        XCTAssertFalse(afterRevocation.hasAccess, "Old signed evidence cannot undo a saved app revocation")
    }

    func testUnverifiedProductionEvidenceRemovesCachedOriginalAccess() async {
        let source = TestProSource()
        defer { source.finishStreams() }
        source.next = snapshot()
        let cache = TestProCache()
        let service = ProEntitlement(source: source, cache: cache, now: { self.instant })
        await service.refresh()
        XCTAssertTrue(service.hasAccess)
        source.next = ProStoreSnapshot(appPurchase: .unverified, appVerificationEnvironment: .production)
        await service.refresh()
        XCTAssertFalse(service.hasAccess)
        XCTAssertEqual(cache.saved?.reason, ProEntitlementReason.none)
        XCTAssertNotNil(service.statusMessage)
    }

    #if DEBUG
    func testScreenshotFixtureAcknowledgmentIsIsolatedAndPersistsOnlyWithinItsNamespace() async throws {
        let suite = "original-purchaser-fixture-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(OriginalPurchaserFixture(scenario: "unknown", defaults: defaults))
        let fixture = try XCTUnwrap(OriginalPurchaserFixture(scenario: "original-purchaser-before", defaults: defaults))
        await fixture.entitlement.start()
        XCTAssertTrue(fixture.entitlement.isResolved)
        XCTAssertEqual(fixture.entitlement.value.reason, .originalPurchaser)
        XCTAssertTrue(fixture.notice.shouldShow(value: fixture.entitlement.value, isResolved: true))
        XCTAssertNotNil(fixture.notice.familyMessage())
        fixture.notice.acknowledge()

        let restarted = try XCTUnwrap(OriginalPurchaserFixture(scenario: "original-purchaser-after", defaults: defaults))
        await restarted.entitlement.start()
        XCTAssertTrue(restarted.entitlement.hasAccess)
        XCTAssertFalse(restarted.notice.shouldShow(value: restarted.entitlement.value, isResolved: true))
        XCTAssertNil(restarted.notice.familyMessage())

        let otherSuite = "original-purchaser-fixture-tests.\(UUID().uuidString)"
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: otherSuite))
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        let independent = try XCTUnwrap(OriginalPurchaserFixture(scenario: "original-purchaser-before", defaults: otherDefaults))
        await independent.entitlement.start()
        XCTAssertTrue(independent.notice.shouldShow(value: independent.entitlement.value, isResolved: true))
    }
    #endif

    private func snapshot(revoked: Bool = false, signedOffset: TimeInterval = 0) -> ProStoreSnapshot {
        ProStoreSnapshot(appPurchase: .verified(ProAppPurchase(
            originalVersion: "4", originalPurchaseDate: instant, environment: .production,
            revoked: revoked, signedAt: instant.addingTimeInterval(signedOffset)
        )))
    }
}
