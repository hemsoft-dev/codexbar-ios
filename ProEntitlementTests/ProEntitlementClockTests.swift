import Darwin
import Foundation
import XCTest
@testable import CodexBarIOS

final class ProEntitlementClockTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testElapsedTimeIncludesSleepAndDefeatsRollbackAfterVerification() throws {
        let anchor = makeAnchor()
        let afterSleep = ProEntitlementClockSample(
            wallDate: date.addingTimeInterval(30), continuousSeconds: 100 + 4 * 86_400, continuityID: "test-boot"
        )
        XCTAssertEqual(anchor.effectiveDate(at: afterSleep), date.addingTimeInterval(4 * 86_400))
        let reloaded = try JSONDecoder().decode(ProEntitlementClockAnchor.self, from: JSONEncoder().encode(anchor))
        XCTAssertEqual(reloaded, anchor)
        XCTAssertEqual(reloaded.effectiveDate(at: afterSleep), anchor.effectiveDate(at: afterSleep))
        let laterRollback = ProEntitlementClockSample(
            wallDate: date.addingTimeInterval(20), continuousSeconds: 100 + 5 * 86_400, continuityID: "test-boot"
        )
        XCTAssertEqual(reloaded.effectiveDate(at: laterRollback), date.addingTimeInterval(5 * 86_400))
    }

    func testForwardWallClockCanExpireEarlierThanContinuousClock() {
        let sample = ProEntitlementClockSample(
            wallDate: date.addingTimeInterval(1000), continuousSeconds: 110, continuityID: "test-boot"
        )
        XCTAssertEqual(makeAnchor().effectiveDate(at: sample), sample.wallDate)
    }

    func testUnknownOrDifferentContinuityRejectsBothLowerAndHigherUptime() {
        for nonce: String? in [nil, "", "new-boot"] {
            for continuous: TimeInterval in [1, 100, 100_000] {
                XCTAssertNil(makeAnchor().effectiveDate(at: ProEntitlementClockSample(
                    wallDate: date, continuousSeconds: continuous, continuityID: nonce
                )))
            }
        }
        XCTAssertNil(makeAnchor().effectiveDate(at: ProEntitlementClockSample(
            wallDate: date, continuousSeconds: 99, continuityID: "test-boot"
        )))
    }

    func testMalformedSamplesAndSerializedAnchorsFailClosed() {
        for invalid: TimeInterval in [.nan, .infinity, -.infinity] {
            XCTAssertNil(makeAnchor().effectiveDate(at: ProEntitlementClockSample(
                wallDate: Date(timeIntervalSinceReferenceDate: invalid), continuousSeconds: 100, continuityID: "test-boot"
            )))
            XCTAssertNil(makeAnchor().effectiveDate(at: ProEntitlementClockSample(
                wallDate: date, continuousSeconds: invalid, continuityID: "test-boot"
            )))
            XCTAssertFalse(makeAnchor(continuous: invalid).isValid)
            XCTAssertFalse(ProEntitlementClockAnchor(
                anchorDate: date, continuousSeconds: 100, continuityID: "test-boot",
                latestSignedAt: Date(timeIntervalSinceReferenceDate: invalid)
            ).isValid)
            XCTAssertFalse(ProEntitlementClockAnchor(
                anchorDate: Date(timeIntervalSinceReferenceDate: invalid), continuousSeconds: 100,
                continuityID: "test-boot", latestSignedAt: date
            ).isValid)
        }
        XCTAssertFalse(makeAnchor(continuous: -1).isValid)
        XCTAssertFalse(makeAnchor(nonce: "").isValid)
        XCTAssertFalse(ProEntitlementClockAnchor(
            anchorDate: date, continuousSeconds: 100, continuityID: "test-boot", latestSignedAt: date.addingTimeInterval(1)
        ).isValid)
    }

    func testElapsedDateOverflowFailsClosed() {
        let anchor = ProEntitlementClockAnchor(
            anchorDate: Date(timeIntervalSinceReferenceDate: .greatestFiniteMagnitude),
            continuousSeconds: 0, continuityID: "test-boot", latestSignedAt: date
        )
        XCTAssertTrue(anchor.isValid)
        XCTAssertNil(anchor.effectiveDate(at: ProEntitlementClockSample(
            wallDate: date, continuousSeconds: .greatestFiniteMagnitude, continuityID: "test-boot"
        )))
    }

    func testSystemMarkerSurvivesClosedDescriptorsAndChangesAfterSimulatedReboot() throws {
        let fixture = try makeSystemFixture()
        defer { remove(fixture) }
        let first = ProEntitlementSystemClock.sample(at: date, sharedMemoryName: fixture.name, directory: fixture.directory)
        let nonce = try XCTUnwrap(first.continuityID)
        XCTAssertNotNil(UUID(uuidString: nonce))
        XCTAssertEqual(first.wallDate, date)
        XCTAssertTrue(first.continuousSeconds.isFinite)
        XCTAssertGreaterThanOrEqual(first.continuousSeconds, 0)
        let reopened = ProEntitlementSystemClock.sample(at: date, sharedMemoryName: fixture.name, directory: fixture.directory)
        XCTAssertEqual(reopened.continuityID, nonce)
        XCTAssertGreaterThanOrEqual(reopened.continuousSeconds, first.continuousSeconds)

        // Only this test's random namespace is removed. Reboot removes kernel markers the same way.
        XCTAssertEqual(shm_unlink(fixture.name), 0)
        let nextBoot = ProEntitlementSystemClock.sample(at: date, sharedMemoryName: fixture.name, directory: fixture.directory)
        XCTAssertNotNil(nextBoot.continuityID)
        XCTAssertNotEqual(nextBoot.continuityID, nonce)
        let anchor = ProEntitlementClockAnchor(
            anchorDate: date, continuousSeconds: first.continuousSeconds, continuityID: nonce, latestSignedAt: date
        )
        XCTAssertNil(anchor.effectiveDate(at: nextBoot))
    }

    func testUninitializedAndMalformedSharedMemoryAreRepairedAndThenStable() throws {
        for allocated in [false, true] {
            let fixture = try makeSystemFixture()
            defer { remove(fixture) }
            let descriptor = ProEntitlementSystemClock.openSharedMemory(fixture.name, flags: O_CREAT | O_EXCL | O_RDWR)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            // Both a zero-size object and allocated zero bytes can remain after a crashed initializer.
            if allocated { XCTAssertEqual(ftruncate(descriptor, 40), 0) }
            let repaired = ProEntitlementSystemClock.sample(at: date, sharedMemoryName: fixture.name, directory: fixture.directory)
            XCTAssertNotNil(repaired.continuityID)
            let reopened = ProEntitlementSystemClock.sample(at: date, sharedMemoryName: fixture.name, directory: fixture.directory)
            XCTAssertEqual(repaired.continuityID, reopened.continuityID)
        }
    }

    func testRepairCannotRestoreAnAnchorThatUsedTheCorruptMarker() throws {
        let fixture = try makeSystemFixture()
        defer { remove(fixture) }
        let original = ProEntitlementSystemClock.sample(at: date, sharedMemoryName: fixture.name, directory: fixture.directory)
        let nonce = try XCTUnwrap(original.continuityID)
        let anchor = ProEntitlementClockAnchor(
            anchorDate: date, continuousSeconds: original.continuousSeconds, continuityID: nonce, latestSignedAt: date
        )
        let descriptor = ProEntitlementSystemClock.openSharedMemory(fixture.name, flags: O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let memory = try XCTUnwrap(mmap(nil, 40, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0))
        XCTAssertNotEqual(memory, MAP_FAILED)
        guard memory != MAP_FAILED else { return }
        memory.storeBytes(of: UInt8(0), as: UInt8.self)
        XCTAssertEqual(munmap(memory, 40), 0)
        let repaired = ProEntitlementSystemClock.sample(at: date, sharedMemoryName: fixture.name, directory: fixture.directory)
        XCTAssertNotNil(repaired.continuityID)
        XCTAssertNotEqual(repaired.continuityID, nonce)
        XCTAssertNil(anchor.effectiveDate(at: repaired))
    }

    func testMissingContainerAndBusyInitializerFailClosedWithoutBlocking() throws {
        let fixture = try makeSystemFixture()
        defer { remove(fixture) }
        XCTAssertNil(ProEntitlementSystemClock.sample(at: date, sharedMemoryName: fixture.name, directory: nil).continuityID)
        XCTAssertNil(ProEntitlementSystemClock.sample(
            at: date, sharedMemoryName: fixture.name, directory: fixture.directory.appendingPathComponent("missing")
        ).continuityID)
        let lockPath = fixture.directory.appendingPathComponent("pro-entitlement-clock.lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        defer { flock(descriptor, LOCK_UN) }
        XCTAssertNil(ProEntitlementSystemClock.sample(at: date, sharedMemoryName: fixture.name, directory: fixture.directory).continuityID)
    }

    private func makeAnchor(continuous: TimeInterval = 100, nonce: String = "test-boot") -> ProEntitlementClockAnchor {
        ProEntitlementClockAnchor(anchorDate: date, continuousSeconds: continuous, continuityID: nonce, latestSignedAt: date)
    }

    private func makeSystemFixture() throws -> (name: String, directory: URL) {
        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(identifier, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ("/cbp-" + identifier.prefix(24), directory)
    }

    private func remove(_ fixture: (name: String, directory: URL)) {
        shm_unlink(fixture.name)
        try? FileManager.default.removeItem(at: fixture.directory)
    }
}
