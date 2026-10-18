import Darwin
import XCTest
#if os(watchOS)
@testable import CodexBarWatch
#else
@testable import CodexBarIOS
#endif

/// Exercises the shared-memory continuity marker shared by the app, widgets and watch.
/// Test hosts have no App Group container, so production sampling never reaches this path.
final class ProEntitlementClockContinuityTests: XCTestCase {
    private var directory: URL!
    private var names: [String] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        names.forEach { _ = shm_unlink($0) }
        try? FileManager.default.removeItem(at: directory)
    }

    func testFirstSampleCreatesAMarkerThatLaterSamplesReuse() throws {
        let name = uniqueName()
        let first = try XCTUnwrap(continuityID(name))
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(continuityID(name), first)
        XCTAssertNotEqual(continuityID(uniqueName()), first)
    }

    func testInvalidNamesAndUnusableDirectoriesHaveNoMarker() {
        XCTAssertNil(continuityID(""))
        XCTAssertNil(continuityID("/" + String(repeating: "x", count: 31)), "Darwin limits names to 31 bytes")
        XCTAssertNil(continuityID(uniqueName(), directory: directory.appendingPathComponent("missing")))
        XCTAssertNil(ProEntitlementSystemClock.sample(at: Date(), sharedMemoryName: uniqueName(), directory: nil).continuityID)
    }

    func testCorruptMarkerIsReplacedWithAFreshNonce() throws {
        let name = uniqueName()
        let descriptor = ProEntitlementSystemClock.openSharedMemory(name, flags: O_CREAT | O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(ftruncate(descriptor, 40), 0)
        XCTAssertNil(ProEntitlementSystemClock.mappedNonce(descriptor: descriptor, initializing: false), "Zeroed storage is not a marker")
        let replaced = try XCTUnwrap(continuityID(name))
        XCTAssertEqual(ProEntitlementSystemClock.mappedNonce(descriptor: descriptor, initializing: false), replaced)
    }

    func testUnallocatedStorageIsNeverMappedAndIsInitializedOnNextSample() throws {
        let name = uniqueName()
        let descriptor = ProEntitlementSystemClock.openSharedMemory(name, flags: O_CREAT | O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertNil(ProEntitlementSystemClock.mappedNonce(descriptor: descriptor, initializing: true))
        let created = try XCTUnwrap(continuityID(name))
        XCTAssertEqual(ProEntitlementSystemClock.mappedNonce(descriptor: descriptor, initializing: false), created)
    }

    /// Short unique names stay within Darwin's 31-byte limit and are unlinked after each test.
    private func uniqueName() -> String {
        let name = "/cbt" + UUID().uuidString.prefix(8)
        names.append(name)
        return name
    }

    private func continuityID(_ name: String, directory: URL? = nil) -> String? {
        ProEntitlementSystemClock.sample(at: Date(), sharedMemoryName: name, directory: directory ?? self.directory).continuityID
    }
}
