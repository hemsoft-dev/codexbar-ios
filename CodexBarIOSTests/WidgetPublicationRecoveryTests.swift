import Darwin
import XCTest
@testable import CodexBarIOS

@MainActor
final class WidgetPublicationRecoveryTests: XCTestCase {
    func testFirstCachedFiniteGrantRecoversFromTemporaryClockUncertaintyWithoutNewEvidence() throws {
        let fixture = try WidgetAccessFixture()
        let store = configurationStore(fixture)
        fixture.advance(wall: 950, continuous: 10, boot: "boot-B")
        publish(SnapshotProAccess(
            isProLocked: true, proAccessEndsAt: Date(timeIntervalSince1970: 1_100), clockAnchor: fixture.anchor
        ), fixture: fixture, store: store)
        XCTAssertNil(fixture.context.effectiveDate(for: fixture.snapshot))
        fixture.advance(wall: 1_050, continuous: 20, boot: "boot-B")
        publish(grant(fixture, generation: nil), fixture: fixture, store: store)
        XCTAssertNotNil(fixture.context.effectiveDate(for: fixture.snapshot))
    }

    func testConsumedVerificationCannotReturnAfterReceiptInvalidationAndRawSnapshotLoss() throws {
        for corrupt in [false, true] {
            let fixture = try WidgetAccessFixture()
            let store = configurationStore(fixture)
            let access = grant(fixture, generation: UUID())
            publish(access, fixture: fixture, store: store)
            let publication = try XCTUnwrap(fixture.snapshot.accessPublication)
            let failed = WidgetAccessGuard(directory: fixture.directory, write: { _, _ in throw CocoaError(.fileWriteUnknown) })
            fixture.advance(wall: 1_100, continuous: 600)
            XCTAssertNil(failed.effectiveDate(for: publication, sample: fixture.sample))
            if corrupt {
                fixture.defaults.set(Data("corrupt".utf8), forKey: "widgetUsageSnapshot")
            } else {
                fixture.defaults.removeObject(forKey: "widgetUsageSnapshot")
            }
            XCTAssertNil(fixture.snapshot.accessPublication)
            fixture.advance(wall: 1_050, continuous: 10, boot: "boot-B")
            publish(access, fixture: fixture, store: store)
            XCTAssertNil(fixture.context.effectiveDate(for: fixture.snapshot))
            publish(SnapshotProAccess(
                isProLocked: false, proAccessEndsAt: Date(timeIntervalSince1970: 1_100),
                clockAnchor: fixture.recoveredAnchor(), verificationGeneration: UUID()
            ), fixture: fixture, store: store)
            XCTAssertNotNil(fixture.context.effectiveDate(for: fixture.snapshot))
        }
    }

    func testHealthyHeldEntrySurvivesOrdinaryPublisherRefreshButNotDenialAndRestoration() throws {
        let fixture = try WidgetAccessFixture()
        let store = configurationStore(fixture)
        let access = grant(fixture, generation: UUID())
        publish(access, fixture: fixture, store: store)
        let held = fixture.loader.timelinePlan(configuration: CodexBarWidgetConfigurationIntent()).entry
        let publicationID = held.snapshot.accessPublication?.id
        XCTAssertFalse(held.isProLocked)
        fixture.advance(wall: 1_001, continuous: 501)
        publish(access, fixture: fixture, store: store)
        XCTAssertEqual(fixture.snapshot.accessPublication?.id, publicationID)
        XCTAssertFalse(held.isProLocked, "A delayed WidgetKit reload must not lock unchanged valid access")
        publish(.locked, fixture: fixture, store: store)
        XCTAssertTrue(held.isProLocked)
        publish(access, fixture: fixture, store: store)
        XCTAssertNotNil(fixture.context.effectiveDate(for: fixture.snapshot))
        XCTAssertTrue(held.isProLocked, "A pre-denial entry cannot adopt the restored publication")
    }

    func testMissingOrCorruptAuthorityHistoryCannotBeReplacedByAnInMemoryGeneration() throws {
        for corrupt in [false, true] {
            let fixture = try WidgetAccessFixture()
            let store = configurationStore(fixture)
            let access = grant(fixture, generation: UUID())
            publish(access, fixture: fixture, store: store)
            let history = fixture.directory.appendingPathComponent("widget-pro-access.was-published")
            if corrupt {
                try Data("corrupt".utf8).write(to: history)
            } else {
                try FileManager.default.removeItem(at: history)
            }
            publish(access, fixture: fixture, store: store)
            // A failed unchanged publication retains the prior readable observation.
            // Once it is absent, missing history cannot establish a replacement.
            try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("widget-pro-access.json"))
            publish(access, fixture: fixture, store: store)
            XCTAssertNil(fixture.context.effectiveDate(for: fixture.snapshot))
            publish(SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil), fixture: fixture, store: store)
            XCTAssertNotNil(fixture.context.effectiveDate(for: fixture.snapshot))
            publish(access, fixture: fixture, store: store)
            XCTAssertNil(fixture.context.effectiveDate(for: fixture.snapshot))
        }
    }

    func testFailedDurableInstallationConsumesAuthorityButNewVerificationCanRecover() throws {
        let fixture = try WidgetAccessFixture()
        let store = configurationStore(fixture)
        let access = grant(fixture, generation: UUID())
        let failed = WidgetAccessGuard(directory: fixture.directory, write: { _, _ in throw CocoaError(.fileWriteUnknown) })
        WidgetSnapshotPublisher.publish(
            results: [], configurationStore: store, access: access, snapshotDefaults: fixture.defaults,
            accessGuard: failed, now: fixture.sample.wallDate, accessSample: fixture.sample
        )
        publish(access, fixture: fixture, store: store)
        XCTAssertNil(fixture.context.effectiveDate(for: fixture.snapshot))
        publish(SnapshotProAccess(
            isProLocked: false, proAccessEndsAt: Date(timeIntervalSince1970: 1_100),
            clockAnchor: fixture.recoveredAnchor(signedAt: 990), verificationGeneration: UUID()
        ), fixture: fixture, store: store)
        XCTAssertNotNil(fixture.context.effectiveDate(for: fixture.snapshot))
    }

    func testFirstLegacyMigrationCanRetryAfterLockContentionWithoutNewSignedEvidence() throws {
        let fixture = try WidgetAccessFixture()
        let store = configurationStore(fixture)
        let access = grant(fixture, generation: nil)
        let descriptor = open(fixture.directory.appendingPathComponent("widget-pro-access.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        publish(access, fixture: fixture, store: store)
        XCTAssertEqual(fixture.snapshot.accessPublication?.observedPartitions, [])
        XCTAssertNil(fixture.context.effectiveDate(for: fixture.snapshot))
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        publish(access, fixture: fixture, store: store)
        XCTAssertEqual(fixture.snapshot.accessPublication?.observedPartitions, ["production"])
        XCTAssertNil(fixture.snapshot.accessPublication?.verificationGeneration)
        XCTAssertNotNil(fixture.context.effectiveDate(for: fixture.snapshot))
    }

    func testLockedOrPermanentPublicationCannotEraseMissingLegacyMigrationExpiryHistory() throws {
        for replacement in [SnapshotProAccess.locked, SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil)] {
            let fixture = try WidgetAccessFixture()
            let store = configurationStore(fixture)
            let access = grant(fixture, generation: nil)
            publish(access, fixture: fixture, store: store)
            let publication = try XCTUnwrap(fixture.snapshot.accessPublication)
            let failed = WidgetAccessGuard(directory: fixture.directory, write: { _, _ in throw CocoaError(.fileWriteUnknown) })
            fixture.advance(wall: 1_100, continuous: 600)
            XCTAssertNil(failed.effectiveDate(for: publication, sample: fixture.sample))
            fixture.advance(wall: 1_050, continuous: 10, boot: "boot-B")
            publish(replacement, fixture: fixture, store: store)
            publish(access, fixture: fixture, store: store)
            XCTAssertEqual(fixture.snapshot.accessPublication?.observedPartitions, ["production"])
            XCTAssertNil(fixture.context.effectiveDate(for: fixture.snapshot))
            let recovered = SnapshotProAccess(
                isProLocked: false, proAccessEndsAt: Date(timeIntervalSince1970: 1_100),
                clockAnchor: fixture.recoveredAnchor(), verificationGeneration: UUID()
            )
            publish(recovered, fixture: fixture, store: store)
            XCTAssertNotNil(fixture.context.effectiveDate(for: fixture.snapshot))
        }
    }

    private func grant(_ fixture: WidgetAccessFixture, generation: UUID?) -> SnapshotProAccess {
        SnapshotProAccess(
            isProLocked: false, proAccessEndsAt: Date(timeIntervalSince1970: 1_100),
            clockAnchor: fixture.anchor, verificationGeneration: generation
        )
    }

    private func configurationStore(_ fixture: WidgetAccessFixture) -> ProviderConfigurationStore {
        ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: fixture.defaults,
            secretStore: MemorySecretStore(), widgetSnapshotDefaults: fixture.defaults
        )
    }

    private func publish(_ access: SnapshotProAccess, fixture: WidgetAccessFixture, store: ProviderConfigurationStore) {
        WidgetSnapshotPublisher.publish(
            results: [], configurationStore: store, access: access, snapshotDefaults: fixture.defaults,
            accessGuard: fixture.store, now: fixture.sample.wallDate, accessSample: fixture.sample
        )
    }
}
