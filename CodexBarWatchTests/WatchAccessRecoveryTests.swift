import Combine
import Darwin
import XCTest
import WidgetKit
@testable import CodexBarWatch

final class WatchAccessRecoveryTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 2_000_000_000)

    @MainActor
    func testPreExpiryProcessRestartAfterRollbackKeepsOriginalContinuousBoundary() async throws {
        let initialSleep = expectation(description: "Initial continuous boundary scheduled")
        let restartedSleep = expectation(description: "Cold store restored the continuous boundary")
        let locked = expectation(description: "Cold store locked at the original continuous boundary")
        let probe = WatchSleepProbe(onSleep: { initialSleep.fulfill() }, onRequest: { count in
            if count == 2 { restartedSleep.fulfill() }
        })
        let clock = WatchControlledClock(probe: probe)
        let origin = clock.now
        var wallDate = base
        let defaults = isolatedDefaults()
        let shared = WatchComplicationSnapshotStore(testDefaults: isolatedDefaults())
        let timing = WatchAccessTiming.live(clock: clock, now: { wallDate }, sample: {
            let elapsed = origin.duration(to: clock.now).components
            return ProEntitlementClockSample(
                wallDate: wallDate, continuousSeconds: 500 + Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                continuityID: "watch-test-boot"
            )
        })
        var first: WatchDashboardStore? = WatchDashboardStore(
            defaults: defaults, complicationStore: shared, reloadComplications: {}, session: nil, accessTiming: timing
        )
        weak let releasedFirst = first
        XCTAssertTrue(try XCTUnwrap(first).receive(snapshot(deadline: base.addingTimeInterval(10), sequence: 1).applicationContext()))
        await fulfillment(of: [initialSleep], timeout: 1)
        probe.advance(by: .seconds(4))
        wallDate = base.addingTimeInterval(-100)
        first = nil
        XCTAssertNil(releasedFirst, "The regression must create a genuinely cold dashboard store")
        let restarted = WatchDashboardStore(
            defaults: defaults, complicationStore: shared, reloadComplications: {}, session: nil, accessTiming: timing
        )
        let observation = restarted.$snapshot.compactMap { $0 }.filter(\.isProLocked).sink { _ in locked.fulfill() }
        defer { observation.cancel() }
        await fulfillment(of: [restartedSleep], timeout: 1)
        XCTAssertEqual(probe.requests.last?.deadline, origin.advanced(by: .seconds(10)))
        probe.advance(by: .seconds(6))
        await fulfillment(of: [locked], timeout: 1)
        XCTAssertTrue(restarted.state(at: base).isProLocked)
    }

    @MainActor
    func testTemporaryPhoneDenialDoesNotPoisonNewerSameDeadlineRecoveryAcrossReaders() async throws {
        let suite = "WatchAccessRecoveryTests.\(UUID().uuidString)"
        let shared = WatchComplicationSnapshotStore(testDefaults: isolatedDefaults(suite: suite))
        let date = base
        let deadline = base.addingTimeInterval(10)
        let store = WatchDashboardStore(
            defaults: isolatedDefaults(), complicationStore: shared, reloadComplications: {}, session: nil,
            accessTiming: WatchAccessTiming(now: { date }, schedule: { _, _ in AnyCancellable {} }, sample: {
                ProEntitlementClockSample(wallDate: date, continuousSeconds: 0, continuityID: "watch-test-boot")
            })
        )
        XCTAssertTrue(try store.receive(snapshot(deadline: deadline, sequence: 1).applicationContext()))
        XCTAssertTrue(try store.receive(snapshot(locked: true, deadline: deadline, sequence: 2).applicationContext()))
        XCTAssertTrue(try XCTUnwrap(shared.loadForAccess(now: date)).isProLocked)
        XCTAssertTrue(try store.receive(snapshot(deadline: deadline, sequence: 3).applicationContext()))
        XCTAssertFalse(try XCTUnwrap(store.snapshot).isProLocked)
        XCTAssertFalse(try XCTUnwrap(shared.loadForAccess(now: date)).isProLocked)
        let loader = WatchComplicationTimelineLoader(now: { date }, loadSnapshot: { shared.loadForAccess(now: date) })
        XCTAssertEqual(loader.entry(configuration: WatchComplicationConfigurationIntent()).sample.availability, .value)
        let accounts = WatchComplicationAccountQuery(loadSnapshot: {
            WatchComplicationSnapshotStore(testDefaults: UserDefaults(suiteName: suite)!).loadForAccess(now: date)
        }, now: { date })
        let metrics = WatchComplicationMetricQuery(loadSnapshot: {
            WatchComplicationSnapshotStore(testDefaults: UserDefaults(suiteName: suite)!).loadForAccess(now: date)
        }, now: { date })
        let accountSuggestions = try await accounts.suggestedEntities()
        let metricSuggestions = try await metrics.suggestedEntities()
        XCTAssertFalse(accountSuggestions.isEmpty)
        XCTAssertFalse(metricSuggestions.isEmpty)
    }

    func testClockWriteFailureAllowsFreshPhoneAuthorityAndPreservesOldDeadlineDenial() throws {
        let directory = try temporaryDirectory()
        let fault = WatchClockWriteFault()
        let guardStore = WatchAccessClockStore(directory: directory, write: { try fault.write($0, to: $1) })
        let initial = snapshot(deadline: base.addingTimeInterval(10), sequence: 1)
        let sample = ProEntitlementClockSample(wallDate: base, continuousSeconds: 500, continuityID: "boot-A")
        XCTAssertTrue(guardStore.accept(initial, sample: sample))
        fault.fail = true
        XCTAssertTrue(guardStore.decision(for: initial, sample: sample).isLocked)
        fault.fail = false
        let later = ProEntitlementClockSample(wallDate: base.addingTimeInterval(-100), continuousSeconds: 504, continuityID: "boot-A")
        XCTAssertEqual(guardStore.decision(for: initial, sample: later).remaining, 6, "A healthy write retry retains the original anchor")
        let permanent = WatchDashboardSnapshot(generatedAt: base, refreshIntervalSeconds: 300, accounts: initial.accounts,
                                              isProLocked: false, proAccessEndsAt: nil, publicationSequence: 2)
        XCTAssertTrue(guardStore.accept(permanent, sample: sample))
        XCTAssertFalse(guardStore.decision(for: permanent, sample: sample).isLocked)
        let renewal = snapshot(deadline: base.addingTimeInterval(100), sequence: 3)
        XCTAssertTrue(guardStore.accept(renewal, sample: sample))
        XCTAssertFalse(guardStore.decision(for: renewal, sample: sample).isLocked)
    }

    func testFirstClockWriteFailureAndLockContentionCanRetryWithoutReanchoring() throws {
        let directory = try temporaryDirectory()
        let fault = WatchClockWriteFault()
        fault.fail = true
        let guardStore = WatchAccessClockStore(directory: directory, write: { try fault.write($0, to: $1) })
        let initial = snapshot(deadline: base.addingTimeInterval(10), sequence: 1)
        let sample = ProEntitlementClockSample(wallDate: base, continuousSeconds: 500, continuityID: "boot-A")
        XCTAssertFalse(guardStore.accept(initial, sample: sample))
        fault.fail = false
        XCTAssertTrue(guardStore.accept(initial, sample: sample))
        XCTAssertEqual(guardStore.decision(for: initial, sample: sample).remaining, 10)
        let descriptor = open(directory.appendingPathComponent("watch-access-clock.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let later = ProEntitlementClockSample(wallDate: base.addingTimeInterval(-100), continuousSeconds: 504, continuityID: "boot-A")
        XCTAssertFalse(guardStore.accept(initial, sample: later))
        XCTAssertTrue(guardStore.decision(for: initial, sample: later).isLocked)
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        XCTAssertTrue(guardStore.accept(initial, sample: later))
        XCTAssertEqual(guardStore.decision(for: initial, sample: later).remaining, 6)
    }

    func testActualExpiryReceiptSurvivesCheckpointOrFirstInstallationWriteFailure() throws {
        for firstInstallation in [false, true] {
            let fault = WatchClockWriteFault()
            let guardStore = WatchAccessClockStore(directory: try temporaryDirectory(), write: { try fault.write($0, to: $1) })
            let store = WatchComplicationSnapshotStore(defaults: isolatedDefaults(), accessClock: guardStore)
            let initial = snapshot(deadline: base.addingTimeInterval(10), sequence: 1)
            let start = ProEntitlementClockSample(wallDate: base, continuousSeconds: 500, continuityID: "boot-A")
            if !firstInstallation { try store.saveIfChanged(initial, sample: start) }
            fault.fail = true
            let expired = ProEntitlementClockSample(
                wallDate: base.addingTimeInterval(firstInstallation ? 11 : -100), continuousSeconds: 511, continuityID: "boot-A"
            )
            if firstInstallation { try store.saveIfChanged(initial, sample: expired) }
            XCTAssertTrue(try XCTUnwrap(store.loadAccess(sample: expired)).hasExpired)
            fault.fail = false
            let rebooted = ProEntitlementClockSample(wallDate: base.addingTimeInterval(1), continuousSeconds: 1, continuityID: "boot-B")
            try store.saveIfChanged(snapshot(deadline: base.addingTimeInterval(10), sequence: 2), sample: rebooted)
            XCTAssertTrue(try XCTUnwrap(store.loadAccess(sample: rebooted)).isLocked)
            try store.saveIfChanged(snapshot(deadline: base.addingTimeInterval(100), sequence: 3), sample: rebooted)
            XCTAssertFalse(try XCTUnwrap(store.loadAccess(sample: rebooted)).isLocked)
        }
    }

    @MainActor
    func testForegroundRetriesAcceptedPhonePayloadAfterLockOrInitialWriteFailure() async throws {
        for firstWriteFailure in [false, true] {
            let directory = try temporaryDirectory()
            let fault = WatchClockWriteFault()
            let clock = WatchReaderClock()
            let suite = "WatchAccessRecoveryTests.\(UUID().uuidString)"
            let shared = WatchComplicationSnapshotStore(
                defaults: isolatedDefaults(suite: suite), accessClock: WatchAccessClockStore(directory: directory, write: { try fault.write($0, to: $1) }),
                clockSample: { _ in clock.sample }
            )
            let loader = WatchComplicationTimelineLoader(now: { clock.sample.wallDate }, loadAccess: { shared.loadAccess() })
            weak var visibleStore: WatchDashboardStore?
            var recovering = false
            var recoveredReloads = 0
            var capturedEntry: WatchComplicationEntry?
            let store = WatchDashboardStore(
                defaults: isolatedDefaults(), complicationStore: shared, reloadComplications: {
                    if recovering {
                        recoveredReloads += 1
                        XCTAssertFalse(visibleStore?.snapshot?.isProLocked ?? true, "The observable commit precedes recovery reload")
                        XCTAssertFalse(shared.loadForAccess()?.isProLocked ?? true)
                        XCTAssertEqual(visibleStore?.state(at: clock.sample.wallDate).samples.first?.exactValue, "37%")
                    }
                    capturedEntry = loader.entry(configuration: WatchComplicationConfigurationIntent())
                }, session: nil,
                accessTiming: WatchAccessTiming(now: { clock.sample.wallDate }, schedule: { _, _ in AnyCancellable {} }, sample: { clock.sample })
            )
            visibleStore = store
            if !firstWriteFailure { XCTAssertTrue(try store.receive(snapshot(deadline: base.addingTimeInterval(10), sequence: 1).applicationContext())) }
            let descriptor = open(directory.appendingPathComponent("watch-access-clock.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { close(descriptor) }
            if firstWriteFailure { fault.fail = true } else { XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0) }
            let incoming = snapshot(deadline: base.addingTimeInterval(10), sequence: 2)
            XCTAssertTrue(try store.receive(incoming.applicationContext()))
            XCTAssertEqual(shared.load(), incoming, "Accepted raw phone bytes are already stored")
            XCTAssertTrue(try XCTUnwrap(store.snapshot).isProLocked)
            clock.move(wallOffset: -100, elapsed: 2)
            XCTAssertTrue(try store.receive(snapshot(deadline: base.addingTimeInterval(10), sequence: 3).applicationContext()))
            let lockedEntry = try XCTUnwrap(capturedEntry)
            XCTAssertEqual(lockedEntry.sample.availability, .locked)
            fault.fail = false
            if !firstWriteFailure { XCTAssertEqual(flock(descriptor, LOCK_UN), 0) }
            clock.move(wallOffset: -100, elapsed: 4)
            recovering = true
            fault.failRecordWrite(after: 1)
            store.reevaluateAccess()
            XCTAssertTrue(try XCTUnwrap(store.snapshot).isProLocked, "Installation succeeds but the following checkpoint can still fail")
            XCTAssertEqual(recoveredReloads, 0)
            store.reevaluateAccess()
            XCTAssertEqual(recoveredReloads, 1)
            XCTAssertEqual(capturedEntry?.sample.availability, .value, "Recovery must request a fresh readable timeline")
            XCTAssertEqual(lockedEntry.sample.availability, .locked, "An old locked projection intentionally stays locked")
            store.reevaluateAccess()
            XCTAssertEqual(recoveredReloads, 1, "A later healthy reevaluation needs no duplicate reload")
            XCTAssertFalse(try XCTUnwrap(store.snapshot).isProLocked, "Foreground must recover without another delivery or process restart")
            XCTAssertEqual(store.state(at: base).samples.first?.exactValue, "37%")
            XCTAssertFalse(try XCTUnwrap(shared.loadForAccess()).isProLocked)
            XCTAssertEqual(try XCTUnwrap(shared.loadAccess()).remaining, 6)
            let query = WatchComplicationAccountQuery(loadSnapshot: {
                WatchComplicationSnapshotStore(
                    defaults: UserDefaults(suiteName: suite)!, accessClock: WatchAccessClockStore(directory: directory),
                    clockSample: { _ in clock.sample }
                ).loadForAccess()
            }, now: { clock.sample.wallDate })
            let suggestions = try await query.suggestedEntities()
            XCTAssertEqual(suggestions.first?.providerName, "Codex")
        }
    }

    func testMarkerOnlyWriteFailureCannotGrantBeforeHistoryIsRecoverable() throws {
        let directory = try temporaryDirectory()
        let fault = WatchClockWriteFault()
        let guardStore = WatchAccessClockStore(directory: directory, write: { try fault.write($0, to: $1) })
        let initial = snapshot(deadline: base.addingTimeInterval(10), sequence: 1)
        let renewed = snapshot(deadline: base.addingTimeInterval(100), sequence: 2)
        let start = ProEntitlementClockSample(wallDate: base, continuousSeconds: 500, continuityID: "boot-A")
        XCTAssertTrue(guardStore.accept(initial, sample: start))
        fault.failMarker = true
        XCTAssertFalse(guardStore.accept(renewed, sample: start))
        XCTAssertTrue(guardStore.decision(for: renewed, sample: start).isLocked, "A durable record alone cannot grant with incomplete recovery history")
        fault.failMarker = false
        XCTAssertFalse(guardStore.decision(for: renewed, sample: start).isLocked, "A healthy read can commit history from the complete durable record")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("watch-access-clock.json"))
        let rollback = ProEntitlementClockSample(wallDate: base.addingTimeInterval(-100), continuousSeconds: 1, continuityID: "boot-B")
        XCTAssertFalse(guardStore.accept(renewed, sample: rollback), "Recovered history must recognize B as an old deadline")
        XCTAssertTrue(guardStore.decision(for: renewed, sample: rollback).isLocked)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WatchAccessRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func snapshot(locked: Bool = false, deadline: Date, sequence: UInt64) -> WatchDashboardSnapshot {
        WatchDashboardSnapshot(
            generatedAt: base, refreshIntervalSeconds: 300,
            accounts: locked ? [] : [WatchAccountSnapshot(
                id: "account", providerName: "Codex", accountLabel: "Personal", fetchedAt: base,
                metrics: [WatchMetricSnapshot(id: "usage", label: "5-hour limit", usedFraction: 0.37, exactValue: "37%")]
            ),
            ], isProLocked: locked, proAccessEndsAt: deadline, publicationSequence: sequence
        )
    }

    private func isolatedDefaults(suite: String = "WatchAccessRecoveryTests.\(UUID().uuidString)") -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }
}

private final class WatchClockWriteFault: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    private var markerFailing = false
    private var recordWritesBeforeFailure: Int?

    func failRecordWrite(after successfulWrites: Int) {
        lock.withLock { recordWritesBeforeFailure = successfulWrites }
    }
    var failMarker: Bool {
        get { lock.withLock { markerFailing } }
        set { lock.withLock { markerFailing = newValue } }
    }
    var fail: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    func write(_ data: Data, to url: URL) throws {
        let shouldFail = lock.withLock {
            if failing || (markerFailing && url.pathExtension == "initialized") { return true }
            guard url.pathExtension == "json", let remaining = recordWritesBeforeFailure else { return false }
            if remaining == 0 {
                recordWritesBeforeFailure = nil
                return true
            }
            recordWritesBeforeFailure = remaining - 1
            return false
        }
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
    }
}
