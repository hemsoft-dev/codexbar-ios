import Combine
import XCTest
import WidgetKit
@testable import CodexBarWatch

final class WatchAccessReaderTests: XCTestCase {
    func testColdElapsedExpiryLocksTimelineAndActualQueriesWithoutChangingSavedChoices() async throws {
        let fixture = try fixture()
        try fixture.publish()
        let raw = fixture.defaults.data(forKey: WatchComplicationConstants.snapshotDefaultsKey)
        fixture.defaults.set("alias", forKey: "saved-account")
        fixture.defaults.set("alias::usage", forKey: "saved-metric")
        fixture.clock.move(wallOffset: -100, elapsed: 11)
        let cold = fixture.coldStore()
        XCTAssertTrue(try XCTUnwrap(cold.loadForAccess()).isProLocked)
        let loader = WatchComplicationTimelineLoader(now: { fixture.clock.sample.wallDate }, loadAccess: { cold.loadAccess() })
        XCTAssertEqual(loader.entry(configuration: WatchComplicationConfigurationIntent()).sample.availability, .locked)
        let accounts = WatchComplicationAccountQuery(loadSnapshot: { fixture.coldStore().loadForAccess() }, now: { fixture.clock.sample.wallDate })
        let metrics = WatchComplicationMetricQuery(loadSnapshot: { fixture.coldStore().loadForAccess() }, now: { fixture.clock.sample.wallDate })
        let accountSuggestions = try await accounts.suggestedEntities()
        let metricSuggestions = try await metrics.suggestedEntities()
        let savedAccount = try await accounts.entities(for: ["alias"])
        let savedMetric = try await metrics.entities(for: ["alias::usage"])
        XCTAssertTrue(accountSuggestions.isEmpty)
        XCTAssertTrue(metricSuggestions.isEmpty)
        XCTAssertEqual(savedAccount.first?.id, "alias")
        XCTAssertEqual(savedAccount.first?.providerName, "Saved Account")
        XCTAssertEqual(savedMetric.first?.id, "alias::usage")
        XCTAssertEqual(fixture.defaults.data(forKey: WatchComplicationConstants.snapshotDefaultsKey), raw)
        XCTAssertEqual(fixture.defaults.string(forKey: "saved-account"), "alias")
        XCTAssertEqual(fixture.defaults.string(forKey: "saved-metric"), "alias::usage")
        fixture.clock.move(wallOffset: -50, elapsed: 1, boot: "boot-B")
        try fixture.publish(sequence: 2)
        XCTAssertTrue(try XCTUnwrap(fixture.store.loadForAccess()).isProLocked, "A newer queued delivery cannot erase actual expiry")
        try fixture.publish(deadlineOffset: 100, sequence: 3)
        XCTAssertFalse(try XCTUnwrap(fixture.store.loadForAccess()).isProLocked)
        let restored = try await accounts.entities(for: ["alias"])
        XCTAssertEqual(restored.first?.id, "alias")
        XCTAssertEqual(restored.first?.providerName, "Codex")
    }

    func testRollbackTimelineUsesRemainingElapsedTimeAndFutureProjectionDoesNotExpireCurrentGrant() throws {
        let fixture = try fixture()
        try fixture.publish()
        fixture.clock.move(wallOffset: -100, elapsed: 4)
        let loader = fixture.loader()
        let timeline = loader.timeline(configuration: WatchComplicationConfigurationIntent())
        let held = try XCTUnwrap(timeline.entries.first)
        XCTAssertEqual(held.sample.exactValue, "37%")
        XCTAssertEqual(timeline.entries.last?.date, fixture.clock.sample.wallDate.addingTimeInterval(6))
        XCTAssertEqual(timeline.entries.last?.sample.availability, .locked)
        XCTAssertFalse(try XCTUnwrap(fixture.store.loadForAccess()).isProLocked)
        XCTAssertEqual(fixture.store.load()?.proAccessEndsAt, fixture.base.addingTimeInterval(10))
        fixture.clock.move(wallOffset: -100, elapsed: 10)
        XCTAssertEqual(held.sample.availability, .locked, "Retained entries re-check actual access without a new timeline")
        XCTAssertTrue(try XCTUnwrap(fixture.coldStore().loadForAccess()).isProLocked)
    }

    func testRebootAboveSavedFloorRetainsHealthyOfflineAccessAndBelowFloorCanRecover() throws {
        let fixture = try fixture()
        try fixture.publish()
        fixture.clock.move(wallOffset: 4, elapsed: 4)
        XCTAssertFalse(try XCTUnwrap(fixture.store.loadForAccess()).isProLocked)
        fixture.clock.move(wallOffset: -100, elapsed: 1, boot: "boot-B")
        XCTAssertTrue(try XCTUnwrap(fixture.coldStore().loadForAccess()).isProLocked)
        XCTAssertFalse(try XCTUnwrap(fixture.store.load()).isProLocked, "Uncertainty must not rewrite the phone payload")
        fixture.clock.move(wallOffset: 4, elapsed: 2, boot: "boot-B")
        XCTAssertFalse(try XCTUnwrap(fixture.coldStore().loadForAccess()).isProLocked)
        XCTAssertEqual(try XCTUnwrap(fixture.store.loadAccess()).remaining, 6)
        fixture.clock.move(wallOffset: 5, elapsed: 1, boot: "boot-C")
        XCTAssertFalse(try XCTUnwrap(fixture.coldStore().loadForAccess()).isProLocked)
        XCTAssertEqual(try XCTUnwrap(fixture.store.loadAccess()).remaining, 5)
    }

    @MainActor
    func testColdMigrationDoesNotPersistTemporaryClockDenialInEitherSnapshotStore() throws {
        for legacyWins in [false, true] {
            let fixture = try fixture()
            try fixture.publish(sequence: legacyWins ? 1 : 2)
            let legacy = UserDefaults(suiteName: fixture.suite + ".legacy")!
            addTeardownBlock { UserDefaults(suiteName: fixture.suite + ".legacy")?.removePersistentDomain(forName: fixture.suite + ".legacy") }
            let winner = fixture.snapshot(sequence: 2)
            legacy.set(try fixture.snapshot(sequence: legacyWins ? 2 : 1).encoded(), forKey: "watch.dashboard.last-good-snapshot")
            fixture.clock.move(wallOffset: -100, elapsed: 1, boot: "boot-B")
            let store = WatchDashboardStore(
                defaults: legacy, complicationStore: fixture.store, reloadComplications: {}, session: nil,
                accessTiming: WatchAccessTiming(now: { fixture.clock.sample.wallDate }, schedule: { _, _ in AnyCancellable {} },
                                               sample: { fixture.clock.sample })
            )
            XCTAssertTrue(try XCTUnwrap(store.snapshot).isProLocked)
            XCTAssertEqual(fixture.store.load(), winner)
            XCTAssertEqual(try WatchDashboardSnapshot.decode(XCTUnwrap(legacy.data(forKey: "watch.dashboard.last-good-snapshot"))), winner)
            fixture.clock.move(wallOffset: 1, elapsed: 2, boot: "boot-B")
            store.reevaluateAccess()
            XCTAssertFalse(try XCTUnwrap(store.snapshot).isProLocked)
            XCTAssertEqual(store.state(at: fixture.base).samples.first?.exactValue, "37%")
        }
    }

    func testLostClockRecordDeniesCachedDeadlineButFreshAuthorityRecoversWithoutErasingHistory() throws {
        for corrupt in [false, true] {
            let fixture = try fixture()
            try fixture.publish()
            if corrupt { try Data("corrupt".utf8).write(to: fixture.clockURL) } else { try FileManager.default.removeItem(at: fixture.clockURL) }
            XCTAssertTrue(try XCTUnwrap(fixture.coldStore().loadForAccess()).isProLocked)
            try fixture.publish(sequence: 2)
            XCTAssertTrue(try XCTUnwrap(fixture.store.loadForAccess()).isProLocked)
            try fixture.publish(deadlineOffset: nil, sequence: 3)
            XCTAssertFalse(try XCTUnwrap(fixture.store.loadForAccess()).isProLocked)
            try fixture.publish(sequence: 4)
            XCTAssertTrue(try XCTUnwrap(fixture.store.loadForAccess()).isProLocked)
            try fixture.publish(deadlineOffset: 100, sequence: 5)
            XCTAssertFalse(try XCTUnwrap(fixture.store.loadForAccess()).isProLocked)
        }
    }

    func testRetainedEntrySurvivesUsageRefreshButCannotCrossDenialAndRestoration() throws {
        let fixture = try fixture()
        try fixture.publish()
        let held = fixture.loader().entry(configuration: WatchComplicationConfigurationIntent())
        fixture.clock.move(wallOffset: -100, elapsed: 4)
        try fixture.publish(sequence: 2)
        XCTAssertEqual(held.sample.availability, .value)
        XCTAssertEqual(try XCTUnwrap(fixture.store.loadAccess()).remaining, 6)
        try fixture.publish(locked: true, sequence: 3)
        XCTAssertEqual(held.sample.availability, .locked)
        try fixture.publish(sequence: 4)
        XCTAssertFalse(try XCTUnwrap(fixture.store.loadForAccess()).isProLocked)
        XCTAssertEqual(held.sample.availability, .locked)
        XCTAssertEqual(fixture.loader().entry(configuration: WatchComplicationConfigurationIntent()).sample.availability, .value)
        XCTAssertEqual(try XCTUnwrap(fixture.store.loadAccess()).remaining, 6)
    }

    func testUnavailableClockEvidenceDeniesWithoutGrantingReaderInitialization() throws {
        let fixture = try fixture()
        fixture.defaults.set(try fixture.snapshot().encoded(), forKey: WatchComplicationConstants.snapshotDefaultsKey)
        XCTAssertTrue(try XCTUnwrap(fixture.store.loadForAccess()).isProLocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.clockURL.path))
        try fixture.publish()
        for elapsed in [-1.0, .nan] {
            fixture.clock.move(wallOffset: 0, elapsed: elapsed - 500)
            XCTAssertTrue(try XCTUnwrap(fixture.store.loadForAccess()).isProLocked)
        }
        fixture.clock.move(wallOffset: 1, elapsed: 1)
        XCTAssertFalse(try XCTUnwrap(fixture.store.loadForAccess()).isProLocked)
        try Data("corrupt".utf8).write(to: fixture.clockURL)
        try Data("corrupt".utf8).write(to: fixture.clockURL.appendingPathExtension("initialized"))
        try fixture.publish(deadlineOffset: nil, sequence: 2)
        XCTAssertFalse(try XCTUnwrap(fixture.store.loadForAccess()).isProLocked)
        try fixture.publish(deadlineOffset: 100, sequence: 3)
        XCTAssertTrue(try XCTUnwrap(fixture.store.loadForAccess()).isProLocked, "Lost finite history cannot be reconstructed from cached payloads")
    }

    private func fixture() throws -> WatchReaderFixture {
        let fixture = try WatchReaderFixture()
        addTeardownBlock {
            UserDefaults(suiteName: fixture.suite)?.removePersistentDomain(forName: fixture.suite)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        return fixture
    }
}

final class WatchReaderClock: @unchecked Sendable {
    private let lock = NSLock()
    let base = Date(timeIntervalSince1970: 2_000_000_000)
    private var value = ProEntitlementClockSample(wallDate: Date(timeIntervalSince1970: 2_000_000_000),
                                                continuousSeconds: 500, continuityID: "boot-A")
    var sample: ProEntitlementClockSample { lock.withLock { value } }
    func move(wallOffset: TimeInterval, elapsed: TimeInterval, boot: String = "boot-A") {
        lock.withLock {
            value = ProEntitlementClockSample(wallDate: base.addingTimeInterval(wallOffset), continuousSeconds: 500 + elapsed, continuityID: boot)
        }
    }
}

private final class WatchReaderFixture: @unchecked Sendable {
    let suite = "WatchAccessReaderTests.\(UUID().uuidString)"
    let directory: URL
    let defaults: UserDefaults
    let clock = WatchReaderClock()
    var base: Date { clock.base }
    var clockURL: URL { directory.appendingPathComponent("watch-access-clock.json") }
    var store: WatchComplicationSnapshotStore { coldStore() }

    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func coldStore() -> WatchComplicationSnapshotStore {
        WatchComplicationSnapshotStore(
            defaults: defaults, accessClock: WatchAccessClockStore(directory: directory), clockSample: { [clock] _ in clock.sample }
        )
    }

    func loader() -> WatchComplicationTimelineLoader {
        WatchComplicationTimelineLoader(now: { self.clock.sample.wallDate }, loadAccess: { self.store.loadAccess() })
    }

    func publish(deadlineOffset: TimeInterval? = 10, locked: Bool = false, sequence: UInt64 = 1) throws {
        try store.saveIfChanged(snapshot(deadlineOffset: deadlineOffset, locked: locked, sequence: sequence))
    }

    func snapshot(deadlineOffset: TimeInterval? = 10, locked: Bool = false, sequence: UInt64 = 1) -> WatchDashboardSnapshot {
        WatchDashboardSnapshot(
            generatedAt: base, refreshIntervalSeconds: 300,
            accounts: [WatchAccountSnapshot(
                id: "account", legacyAccountIDs: ["alias"], providerName: "Codex", accountLabel: "Personal", fetchedAt: base,
                metrics: [WatchMetricSnapshot(id: "usage", label: "5-hour limit", usedFraction: 0.37, exactValue: "37%")]
            ),
            ],
            isProLocked: locked, proAccessEndsAt: deadlineOffset.map { base.addingTimeInterval($0) }, publicationSequence: sequence
        )
    }
}
