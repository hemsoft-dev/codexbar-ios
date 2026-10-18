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

    func testNewBootOrUnavailableMarkerUsesAdvancingWallDate() {
        let later = date.addingTimeInterval(120)
        for nonce: String? in [nil, "", "new-boot"] {
            for continuous: TimeInterval in [1, 100, 100_000] {
                XCTAssertEqual(makeAnchor().effectiveDate(at: ProEntitlementClockSample(
                    wallDate: later, continuousSeconds: continuous, continuityID: nonce
                )), later)
            }
        }
    }

    func testNewBootOrUnavailableMarkerRejectsObservedCalendarRollback() {
        for nonce: String? in [nil, "", "new-boot"] {
            XCTAssertNil(makeAnchor().effectiveDate(at: ProEntitlementClockSample(
                wallDate: date.addingTimeInterval(-1), continuousSeconds: 100_000, continuityID: nonce
            )))
            XCTAssertEqual(makeAnchor().effectiveDate(at: ProEntitlementClockSample(
                wallDate: date, continuousSeconds: 1, continuityID: nonce
            )), date)
        }
    }

    func testSameBootRejectsRegressedCounter() {
        XCTAssertNil(makeAnchor().effectiveDate(at: ProEntitlementClockSample(
            wallDate: date, continuousSeconds: 99, continuityID: "test-boot"
        )))
    }

    func testTemporaryMarkerLossDoesNotResetOriginalElapsedAnchor() {
        let anchor = makeAnchor()
        let missingMarker = ProEntitlementClockSample(
            wallDate: date.addingTimeInterval(10), continuousSeconds: 110, continuityID: nil
        )
        XCTAssertEqual(anchor.effectiveDate(at: missingMarker), date.addingTimeInterval(10))
        let recoveredMarker = ProEntitlementClockSample(
            wallDate: date.addingTimeInterval(10), continuousSeconds: 200, continuityID: "test-boot"
        )
        XCTAssertEqual(anchor.effectiveDate(at: recoveredMarker), date.addingTimeInterval(100))
    }

    func testMissingMarkerCheckpointPreservesElapsedOriginWithoutDoubleCounting() throws {
        let anchor = makeAnchor()
        let checkpoint = anchor.checkpoint(at: ProEntitlementClockSample(
            wallDate: date.addingTimeInterval(10), continuousSeconds: 100_000, continuityID: nil
        ))
        XCTAssertEqual(checkpoint.anchorDate, date)
        XCTAssertEqual(checkpoint.continuousSeconds, 100)
        XCTAssertEqual(checkpoint.continuityID, "test-boot")
        XCTAssertEqual(checkpoint.calendarFloor, date.addingTimeInterval(10))
        let reloaded = try JSONDecoder().decode(ProEntitlementClockAnchor.self, from: JSONEncoder().encode(checkpoint))
        XCTAssertEqual(reloaded, checkpoint)
        XCTAssertEqual(reloaded.effectiveDate(at: ProEntitlementClockSample(
            wallDate: date.addingTimeInterval(10), continuousSeconds: 120, continuityID: "test-boot"
        )), date.addingTimeInterval(20))
        XCTAssertNil(reloaded.effectiveDate(at: ProEntitlementClockSample(
            wallDate: date.addingTimeInterval(9), continuousSeconds: 1, continuityID: "new-boot"
        )))
        XCTAssertEqual(reloaded.effectiveDate(at: ProEntitlementClockSample(
            wallDate: date.addingTimeInterval(5), continuousSeconds: 105, continuityID: "test-boot"
        )), date.addingTimeInterval(10))
    }

    func testNewBootCheckpointKeepsSignedWatermarkAndStartsNewElapsedOrigin() {
        let checkpoint = makeAnchor().checkpoint(at: ProEntitlementClockSample(
            wallDate: date.addingTimeInterval(30), continuousSeconds: 2, continuityID: "new-boot"
        ))
        XCTAssertEqual(checkpoint.anchorDate, date.addingTimeInterval(30))
        XCTAssertEqual(checkpoint.continuousSeconds, 2)
        XCTAssertEqual(checkpoint.continuityID, "new-boot")
        XCTAssertEqual(checkpoint.latestSignedAt, date)
        XCTAssertNil(checkpoint.calendarFloor)
        XCTAssertEqual(checkpoint.effectiveDate(at: ProEntitlementClockSample(
            wallDate: date.addingTimeInterval(10), continuousSeconds: 12, continuityID: "new-boot"
        )), date.addingTimeInterval(40))
    }

    func testCheckpointWithUnavailableCounterRetainsValidAnchorAndCalendarFloor() {
        for counter: TimeInterval in [.nan, .infinity, -.infinity, -1] {
            let checkpoint = makeAnchor().checkpoint(at: ProEntitlementClockSample(
                wallDate: date.addingTimeInterval(10), continuousSeconds: counter, continuityID: "new-boot"
            ))
            XCTAssertTrue(checkpoint.isValid)
            XCTAssertEqual(checkpoint.anchorDate, date)
            XCTAssertEqual(checkpoint.continuousSeconds, 100)
            XCTAssertEqual(checkpoint.continuityID, "test-boot")
            XCTAssertEqual(checkpoint.knownDate, date.addingTimeInterval(10))
        }
    }

    func testCheckpointWithoutValidTimePreservesOriginalEvidence() {
        let anchor = makeAnchor()
        for sample in [
            ProEntitlementClockSample(wallDate: date.addingTimeInterval(-1), continuousSeconds: 1, continuityID: "new-boot"),
            ProEntitlementClockSample(wallDate: date, continuousSeconds: 99, continuityID: "test-boot"),
        ] {
            XCTAssertEqual(anchor.checkpoint(at: sample), anchor)
        }
    }

    func testLegacySerializedAnchorWithoutCalendarFloorRemainsReadable() throws {
        let data = try JSONEncoder().encode(makeAnchor())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["calendarFloor"])
        let reloaded = try JSONDecoder().decode(ProEntitlementClockAnchor.self, from: data)
        XCTAssertTrue(reloaded.isValid)
        XCTAssertNil(reloaded.calendarFloor)
        XCTAssertEqual(reloaded.knownDate, date)
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
            XCTAssertFalse(ProEntitlementClockAnchor(
                anchorDate: date, continuousSeconds: 100, continuityID: "test-boot", latestSignedAt: date,
                calendarFloor: Date(timeIntervalSinceReferenceDate: invalid)
            ).isValid)
        }
        XCTAssertFalse(makeAnchor(continuous: -1).isValid)
        XCTAssertFalse(makeAnchor(nonce: "").isValid)
        XCTAssertFalse(ProEntitlementClockAnchor(
            anchorDate: date, continuousSeconds: 100, continuityID: "test-boot", latestSignedAt: date.addingTimeInterval(1)
        ).isValid)
        XCTAssertFalse(ProEntitlementClockAnchor(
            anchorDate: date, continuousSeconds: 100, continuityID: "test-boot", latestSignedAt: date,
            calendarFloor: date.addingTimeInterval(-1)
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
        XCTAssertEqual(anchor.effectiveDate(at: nextBoot), date)
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
            var metadata = stat()
            XCTAssertEqual(fstat(descriptor, &metadata), 0)
            if allocated { XCTAssertGreaterThanOrEqual(metadata.st_size, 40) } else { XCTAssertEqual(metadata.st_size, 0) }
            let repaired = ProEntitlementSystemClock.sample(at: date, sharedMemoryName: fixture.name, directory: fixture.directory)
            XCTAssertNotNil(repaired.continuityID)
            let reopened = ProEntitlementSystemClock.sample(at: date, sharedMemoryName: fixture.name, directory: fixture.directory)
            XCTAssertEqual(repaired.continuityID, reopened.continuityID)
        }
    }

    func testMappingRejectsActualZeroAndUndersizedDescriptors() throws {
        let fixture = try makeSystemFixture()
        defer { remove(fixture) }
        for size: off_t in [0, 1, 39] {
            let path = fixture.directory.appendingPathComponent("short-marker-\(size)").path
            let descriptor = open(path, O_CREAT | O_EXCL | O_RDWR, S_IRUSR | S_IWUSR)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            // Regular descriptors retain the exact requested length. Darwin shared
            // memory rounds any positive allocation up to a full page instead.
            XCTAssertEqual(ftruncate(descriptor, size), 0)
            var metadata = stat()
            XCTAssertEqual(fstat(descriptor, &metadata), 0)
            XCTAssertEqual(metadata.st_size, size)
            XCTAssertNil(ProEntitlementSystemClock.mappedNonce(descriptor: descriptor, initializing: false))
            XCTAssertNil(ProEntitlementSystemClock.mappedNonce(descriptor: descriptor, initializing: true))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data(repeating: 0, count: Int(size)))
        }
    }

    func testMappingAcceptsDescriptorWithCompleteMarkerCapacity() throws {
        let fixture = try makeSystemFixture()
        defer { remove(fixture) }
        let path = fixture.directory.appendingPathComponent("complete-marker").path
        let descriptor = open(path, O_CREAT | O_EXCL | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        XCTAssertEqual(ftruncate(descriptor, 40), 0)
        let nonce = try XCTUnwrap(ProEntitlementSystemClock.mappedNonce(descriptor: descriptor, initializing: true))
        XCTAssertEqual(ProEntitlementSystemClock.mappedNonce(descriptor: descriptor, initializing: false), nonce)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data(("CBP1" + nonce).utf8))
    }

    func testAppGroupStyleNameIsAcceptedByDarwinSharedMemory() throws {
        let fixture = try makeSystemFixture(appGroupStyle: true)
        defer { remove(fixture) }
        XCTAssertFalse(fixture.name.hasPrefix("/"))
        XCTAssertTrue(fixture.name.hasSuffix("/p"))
        let first = ProEntitlementSystemClock.sample(at: date, sharedMemoryName: fixture.name, directory: fixture.directory)
        let nonce = try XCTUnwrap(first.continuityID)
        let reopened = ProEntitlementSystemClock.sample(at: date, sharedMemoryName: fixture.name, directory: fixture.directory)
        XCTAssertEqual(reopened.continuityID, nonce)
    }

    func testRepairedMarkerRequiresWallDateAtOrAfterSavedFloor() throws {
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
        let repaired = ProEntitlementSystemClock.sample(
            at: date.addingTimeInterval(-1), sharedMemoryName: fixture.name, directory: fixture.directory
        )
        XCTAssertNotNil(repaired.continuityID)
        XCTAssertNotEqual(repaired.continuityID, nonce)
        XCTAssertNil(anchor.effectiveDate(at: repaired))
        let later = ProEntitlementSystemClock.sample(
            at: date.addingTimeInterval(10), sharedMemoryName: fixture.name, directory: fixture.directory
        )
        XCTAssertEqual(anchor.effectiveDate(at: later), date.addingTimeInterval(10))
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

    private func makeSystemFixture(appGroupStyle: Bool = false) throws -> (name: String, directory: URL) {
        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(identifier, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = appGroupStyle ? "group.cbp." + identifier.prefix(16) + "/p" : "/cbp-" + identifier.prefix(24)
        return (name, directory)
    }

    private func remove(_ fixture: (name: String, directory: URL)) {
        shm_unlink(fixture.name)
        try? FileManager.default.removeItem(at: fixture.directory)
    }
}
