import Darwin
import XCTest
@testable import CodexBarIOS

final class WidgetAccessGuardTests: XCTestCase {
    func testFutureProjectionDoesNotExpireActualGrantAndHeldEntryUsesActualTime() throws {
        let fixture = try WidgetAccessFixture()
        fixture.publish()
        let configuration = CodexBarWidgetConfigurationIntent()
        let plan = fixture.loader.timelinePlan(configuration: configuration)
        let held = plan.entry
        XCTAssertFalse(held.isProLocked)
        XCTAssertEqual(plan.expirationEntry?.date, Date(timeIntervalSince1970: 1_100))
        XCTAssertTrue(try XCTUnwrap(plan.expirationEntry).isProLocked)
        XCTAssertFalse(held.isProLocked, "Prerendering a future entry must not observe its future date")
        XCTAssertFalse(fixture.loader.timelinePlan(configuration: configuration).entry.isProLocked)
        let bytes = fixture.defaults.data(forKey: "widgetUsageSnapshot")
        fixture.advance(wall: 1_100, continuous: 600)
        XCTAssertTrue(held.isProLocked)
        fixture.advance(wall: 1_050, continuous: 610)
        XCTAssertTrue(held.isProLocked)
        XCTAssertTrue(fixture.loader.timelinePlan(configuration: configuration).entry.isProLocked)
        XCTAssertEqual(fixture.defaults.data(forKey: "widgetUsageSnapshot"), bytes)
    }

    func testContinuousElapsedTimeExpiresWithoutAnyReadAtBoundaryAndMapsTimelineAfterRollback() throws {
        let fixture = try WidgetAccessFixture()
        fixture.publish()
        let held = fixture.loader.timelinePlan(configuration: CodexBarWidgetConfigurationIntent()).entry
        fixture.advance(wall: 950, continuous: 550)
        let plan = fixture.loader.timelinePlan(configuration: CodexBarWidgetConfigurationIntent())
        XCTAssertFalse(plan.entry.isProLocked)
        XCTAssertEqual(plan.expirationEntry?.date, Date(timeIntervalSince1970: 1_000), "Only 50 elapsed seconds remain")
        fixture.advance(wall: 960, continuous: 601)
        XCTAssertTrue(held.isProLocked)
        XCTAssertTrue(plan.entry.isProLocked)
    }

    func testColdReloadAndOrdinaryRepublishAfterRebootCannotUndoObservedExpiry() throws {
        let fixture = try WidgetAccessFixture()
        let first = fixture.publish()
        fixture.advance(wall: 1_100, continuous: 600)
        XCTAssertNil(fixture.context.effectiveDate(for: first))
        fixture.advance(wall: 1_050, continuous: 10, boot: "boot-B")
        let cold = WidgetAccessGuard(directory: fixture.directory)
        XCTAssertNil(cold.effectiveDate(for: try XCTUnwrap(first.accessPublication), sample: fixture.sample))
        let repeated = fixture.publish(generation: first.accessPublication?.verificationGeneration)
        XCTAssertNotEqual(repeated.accessPublication?.id, first.accessPublication?.id)
        XCTAssertNil(fixture.context.effectiveDate(for: repeated), "Same signed grant stays expired even if phone's older cache grants it")
        XCTAssertEqual(repeated.results, first.results)
    }

    func testHealthyCrossBootReadMatchesCanonicalClockPolicyAndKeepsItsFloor() throws {
        let fixture = try WidgetAccessFixture()
        let first = fixture.publish()
        fixture.advance(wall: 1_050, continuous: 10, boot: "boot-B")
        let canonical = fixture.anchor.effectiveDate(at: fixture.sample)
        XCTAssertEqual(canonical, Date(timeIntervalSince1970: 1_050))
        XCTAssertEqual(fixture.context.effectiveDate(for: first), canonical)
        fixture.advance(wall: 1_040, continuous: 2, boot: "boot-C")
        XCTAssertNil(fixture.context.effectiveDate(for: first), "A different boot cannot go below the durable observed floor")
    }

    func testNewVerifiedSameDeadlineRenewalAndPermanentGrantRecoverWithoutOldEntryInterference() throws {
        let fixture = try WidgetAccessFixture()
        let first = fixture.publish()
        let retained = fixture.loader.timelinePlan(configuration: CodexBarWidgetConfigurationIntent()).entry
        fixture.advance(wall: 1_100, continuous: 600)
        XCTAssertTrue(retained.isProLocked)
        fixture.advance(wall: 1_050, continuous: 10, boot: "boot-B")
        let second = fixture.publish(anchor: fixture.recoveredAnchor())
        XCTAssertNotNil(fixture.context.effectiveDate(for: second))
        XCTAssertNil(fixture.context.effectiveDate(for: first))
        XCTAssertTrue(retained.isProLocked)
        XCTAssertNotNil(fixture.context.effectiveDate(for: second), "Old entries cannot damage the new accepted grant")
        fixture.advance(wall: 1_100, continuous: 60, boot: "boot-B")
        XCTAssertNil(fixture.context.effectiveDate(for: second))
        let renewal = fixture.publish(deadline: 1_200, anchor: fixture.recoveredAnchor(signedAt: 1_090))
        XCTAssertNotNil(fixture.context.effectiveDate(for: renewal))
        let permanent = fixture.publish(deadline: nil)
        XCTAssertNotNil(fixture.context.effectiveDate(for: permanent))
        XCTAssertNil(fixture.context.effectiveDate(for: renewal))
    }

    func testStampedDenialFencesLegacyPermanentHeldEntry() throws {
        let fixture = try WidgetAccessFixture()
        let legacy = CodexBarWidgetSnapshot(generatedAt: fixture.sample.wallDate, results: .init(), isProLocked: false)
        XCTAssertNotNil(fixture.context.effectiveDate(for: legacy))
        fixture.publish(locked: true)
        XCTAssertNil(fixture.context.effectiveDate(for: legacy))
    }

    func testLegacyPermanentEntryCannotReopenWhenCurrentSnapshotIsMissingOrCorruptAfterDenial() throws {
        let fixture = try WidgetAccessFixture()
        let legacy = CodexBarWidgetSnapshot(generatedAt: fixture.sample.wallDate, results: [], isProLocked: false)
        XCTAssertNotNil(fixture.context.effectiveDate(for: legacy))
        fixture.publish(locked: true)
        fixture.defaults.removeObject(forKey: "widgetUsageSnapshot")
        XCTAssertNil(fixture.context.effectiveDate(for: legacy))
        fixture.defaults.set(Data("corrupt".utf8), forKey: "widgetUsageSnapshot")
        XCTAssertNil(fixture.context.effectiveDate(for: legacy))
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("widget-pro-access.json"))
        XCTAssertNil(fixture.context.effectiveDate(for: legacy), "The durable publication marker survives observation invalidation")
    }

    func testEveryPersistenceOperationFailingDeniesSameBootButCannotPromiseUnrecordedExpiryAfterReboot() throws {
        let fixture = try WidgetAccessFixture()
        let snapshot = fixture.publish()
        let publication = try XCTUnwrap(snapshot.accessPublication)
        func unavailableStorage() -> WidgetAccessGuard {
            WidgetAccessGuard(
                directory: fixture.directory, write: { _, _ in throw CocoaError(.fileWriteNoPermission) },
                invalidate: { _ in throw CocoaError(.fileWriteNoPermission) }
            )
        }
        fixture.advance(wall: 1_100, continuous: 600)
        XCTAssertNil(unavailableStorage().effectiveDate(for: publication, sample: fixture.sample))
        fixture.advance(wall: 1_050, continuous: 610)
        XCTAssertNil(unavailableStorage().effectiveDate(for: publication, sample: fixture.sample))
        // No expiry or newer floor reached disk. A later healthy boot cannot recover
        // that lost evidence; canonical offline policy still permits its saved floor.
        fixture.advance(wall: 1_050, continuous: 10, boot: "boot-B")
        XCTAssertEqual(fixture.store.effectiveDate(for: publication, sample: fixture.sample), Date(timeIntervalSince1970: 1_050))
    }

    func testMalformedOrMissingObservationCannotBeInitializedByCachedSnapshot() throws {
        let fixture = try WidgetAccessFixture()
        let snapshot = fixture.publish()
        let publication = try XCTUnwrap(snapshot.accessPublication)
        let url = fixture.directory.appendingPathComponent("widget-pro-access.json")
        try Data("broken record".utf8).write(to: url)
        XCTAssertNil(fixture.context.effectiveDate(for: snapshot))
        XCTAssertFalse(fixture.store.publish(publication, locked: false, anchor: fixture.anchor, replacing: publication, sample: fixture.sample))
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(fixture.context.effectiveDate(for: snapshot))
        XCTAssertFalse(fixture.store.publish(publication, locked: false, anchor: fixture.anchor, replacing: publication, sample: fixture.sample))
        XCTAssertNil(WidgetAccessGuard(directory: nil).effectiveDate(for: publication, sample: fixture.sample))
    }

    func testFailedExpiryWriteInvalidatesAndColdRollbackCannotReinstallCachedGrant() throws {
        let fixture = try WidgetAccessFixture()
        let snapshot = fixture.publish()
        let publication = try XCTUnwrap(snapshot.accessPublication)
        let failing = WidgetAccessGuard(directory: fixture.directory, write: { _, _ in throw CocoaError(.fileWriteUnknown) })
        fixture.advance(wall: 1_100, continuous: 600)
        XCTAssertNil(failing.effectiveDate(for: publication, sample: fixture.sample))
        fixture.advance(wall: 1_050, continuous: 10, boot: "boot-B")
        let cold = WidgetAccessGuard(directory: fixture.directory)
        XCTAssertNil(cold.effectiveDate(for: publication, sample: fixture.sample))
        XCTAssertFalse(cold.publish(publication, locked: false, anchor: fixture.anchor, replacing: publication, sample: fixture.sample))
        let recovered = fixture.publish(anchor: fixture.recoveredAnchor())
        XCTAssertNotNil(fixture.context.effectiveDate(for: recovered))
    }

    func testInterprocessLockPreventsOlderObserverOverwritingExpiryOrReplacement() async throws {
        let fixture = try WidgetAccessFixture()
        let snapshot = fixture.publish()
        let publication = try XCTUnwrap(snapshot.accessPublication)
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let blockedWriter = WidgetAccessGuard(directory: fixture.directory, write: { data, url in
            entered.signal()
            guard resume.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
        })
        let oldSample = fixture.sample
        let pending = Task.detached { blockedWriter.effectiveDate(for: publication, sample: oldSample) }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        fixture.advance(wall: 1_100, continuous: 600)
        XCTAssertNil(fixture.store.effectiveDate(for: publication, sample: fixture.sample), "Concurrent read-modify-write fails closed while lock is held")
        resume.signal()
        _ = await pending.value
        XCTAssertNil(fixture.store.effectiveDate(for: publication, sample: fixture.sample))
        XCTAssertNil(fixture.store.effectiveDate(for: publication, sample: oldSample), "Older samples cannot erase the committed expiry")
        fixture.advance(wall: 1_050, continuous: 10, boot: "boot-B")
        let replacement = fixture.publish(anchor: fixture.recoveredAnchor())
        XCTAssertNil(fixture.store.effectiveDate(for: publication, sample: oldSample))
        XCTAssertNotNil(fixture.context.effectiveDate(for: replacement))
    }

    func testInvalidAnchorAndNonfiniteClockCannotEstablishFiniteAccess() throws {
        let fixture = try WidgetAccessFixture()
        let snapshot = fixture.publish()
        let publication = try XCTUnwrap(snapshot.accessPublication)
        for counter in [-1, .nan, .infinity] {
            let sample = ProEntitlementClockSample(wallDate: fixture.sample.wallDate, continuousSeconds: counter, continuityID: "boot-A")
            XCTAssertNil(fixture.store.effectiveDate(for: publication, sample: sample))
        }
        let invalidAnchor = ProEntitlementClockAnchor(
            anchorDate: Date(timeIntervalSince1970: 1_000), continuousSeconds: .nan, continuityID: "boot-A", latestSignedAt: Date(timeIntervalSince1970: 950)
        )
        let invalid = fixture.publish(anchor: invalidAnchor)
        XCTAssertNil(fixture.context.effectiveDate(for: invalid))
    }
}
