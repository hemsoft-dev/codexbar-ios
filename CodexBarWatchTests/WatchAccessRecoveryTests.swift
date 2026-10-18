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

    @MainActor
    func testFirstPhoneFloorBoundsRolledBackWatchAcrossLiveTimerAndReaders() async throws {
        let sleeping = expectation(description: "First finite phone floor scheduled")
        let locked = expectation(description: "First phone floor reached its continuous boundary")
        let probe = WatchSleepProbe(onSleep: { sleeping.fulfill() })
        let origin = probe.now
        let clock = WatchReaderClock()
        clock.move(wallOffset: -100, elapsed: 0)
        let directory = try temporaryDirectory()
        let suite = "WatchAccessRecoveryTests.\(UUID().uuidString)"
        let defaults = isolatedDefaults(suite: suite)
        let shared = WatchComplicationSnapshotStore(
            defaults: defaults, accessClock: WatchAccessClockStore(directory: directory), clockSample: { _ in clock.sample }
        )
        let store = WatchDashboardStore(
            defaults: isolatedDefaults(), complicationStore: shared, reloadComplications: {}, session: nil,
            accessTiming: .live(clock: WatchControlledClock(probe: probe), now: { clock.sample.wallDate }, sample: { clock.sample })
        )
        let incoming = floorSnapshot(floorOffset: 100)
        XCTAssertTrue(try store.receive(incoming.applicationContext()))
        await fulfillment(of: [sleeping], timeout: 1)
        XCTAssertEqual(probe.requests.first?.deadline, origin.advanced(by: .seconds(100)))
        XCTAssertEqual(try XCTUnwrap(shared.loadAccess()).effectiveDate, base.addingTimeInterval(100))
        XCTAssertEqual(try XCTUnwrap(shared.loadAccess()).remaining, 100)
        XCTAssertEqual(store.state(at: clock.sample.wallDate).samples.first?.exactValue, "37%")
        XCTAssertEqual(shared.load(), incoming)
        let loader = WatchComplicationTimelineLoader(now: { clock.sample.wallDate }, loadAccess: { shared.loadAccess() })
        let held = loader.entry(configuration: WatchComplicationConfigurationIntent())
        XCTAssertEqual(held.sample.availability, .value)
        let readAccess: @Sendable () -> WatchDashboardSnapshot? = {
            WatchComplicationSnapshotStore(
                defaults: UserDefaults(suiteName: suite)!, accessClock: WatchAccessClockStore(directory: directory),
                clockSample: { _ in clock.sample }
            ).loadForAccess()
        }
        let accounts = WatchComplicationAccountQuery(loadSnapshot: readAccess, now: { clock.sample.wallDate })
        let metrics = WatchComplicationMetricQuery(loadSnapshot: readAccess, now: { clock.sample.wallDate })
        let allowedAccounts = try await accounts.suggestedEntities()
        let allowedMetrics = try await metrics.suggestedEntities()
        XCTAssertEqual(allowedAccounts.count, 1)
        XCTAssertEqual(allowedMetrics.count, 1)
        clock.move(wallOffset: -100, elapsed: 99)
        probe.advance(by: .seconds(99))
        XCTAssertEqual(try XCTUnwrap(shared.loadAccess()).remaining, 1)
        XCTAssertEqual(held.sample.availability, .value)
        let observation = store.$snapshot.compactMap { $0 }.filter(\.isProLocked).sink { _ in locked.fulfill() }
        defer { observation.cancel() }
        clock.move(wallOffset: -100, elapsed: 100)
        probe.advance(by: .seconds(1))
        await fulfillment(of: [locked], timeout: 1)
        XCTAssertTrue(store.state(at: base).isProLocked)
        XCTAssertEqual(held.sample.availability, .locked)
        let cold = WatchComplicationSnapshotStore(
            defaults: defaults, accessClock: WatchAccessClockStore(directory: directory), clockSample: { _ in clock.sample }
        )
        XCTAssertTrue(try XCTUnwrap(cold.loadAccess()).hasExpired)
        let deniedAccounts = try await accounts.suggestedEntities()
        let deniedMetrics = try await metrics.suggestedEntities()
        XCTAssertTrue(deniedAccounts.isEmpty)
        XCTAssertTrue(deniedMetrics.isEmpty)
        let persisted = try XCTUnwrap(shared.load())
        XCTAssertEqual(persisted, incoming.lockingAccess())
        XCTAssertEqual(persisted.accounts, incoming.accounts)
        XCTAssertEqual(persisted.proAccessEndsAt, incoming.proAccessEndsAt)
        XCTAssertEqual(persisted.proAccessEffectiveAt, incoming.proAccessEffectiveAt)
    }

    @MainActor
    func testPendingPhoneFloorsStayCoherentThroughFailedWritesAndDelayedLowerFloor() async throws {
        let sleeping = expectation(description: "Recovered pending publication scheduled")
        let locked = expectation(description: "Recovered pending publication reached the original boundary")
        let probe = WatchSleepProbe(onSleep: { sleeping.fulfill() })
        let origin = probe.now
        let clock = WatchReaderClock()
        clock.move(wallOffset: -100, elapsed: 0)
        let fault = WatchClockWriteFault()
        fault.fail = true
        let directory = try temporaryDirectory()
        let suite = "WatchAccessRecoveryTests.\(UUID().uuidString)"
        let defaults = isolatedDefaults(suite: suite)
        let shared = WatchComplicationSnapshotStore(
            defaults: defaults, accessClock: WatchAccessClockStore(directory: directory, write: { try fault.write($0, to: $1) }),
            clockSample: { _ in clock.sample }
        )
        let store = WatchDashboardStore(
            defaults: isolatedDefaults(), complicationStore: shared, reloadComplications: {}, session: nil,
            accessTiming: .live(clock: WatchControlledClock(probe: probe), now: { clock.sample.wallDate }, sample: { clock.sample })
        )
        XCTAssertTrue(try store.receive(floorSnapshot(floorOffset: 100).applicationContext()))
        XCTAssertTrue(try XCTUnwrap(store.snapshot).isProLocked)
        clock.move(wallOffset: -100, elapsed: 10)
        probe.advance(by: .seconds(10))
        XCTAssertTrue(try store.receive(floorSnapshot(floorOffset: 110, sequence: 2).applicationContext()))
        XCTAssertTrue(try store.receive(floorSnapshot(floorOffset: 105, sequence: 3).applicationContext()))
        XCTAssertTrue(try XCTUnwrap(store.snapshot).isProLocked)
        XCTAssertTrue(probe.requests.isEmpty)
        clock.move(wallOffset: -100, elapsed: 15)
        probe.advance(by: .seconds(5))
        fault.fail = false
        store.reevaluateAccess()
        await fulfillment(of: [sleeping], timeout: 1)
        XCTAssertFalse(try XCTUnwrap(store.snapshot).isProLocked)
        XCTAssertEqual(try XCTUnwrap(shared.loadAccess()).effectiveDate, base.addingTimeInterval(115))
        XCTAssertEqual(try XCTUnwrap(shared.loadAccess()).remaining, 85)
        XCTAssertEqual(probe.requests.first?.deadline, origin.advanced(by: .seconds(100)))
        store.reevaluateAccess()
        XCTAssertEqual(try XCTUnwrap(shared.loadAccess()).effectiveDate, base.addingTimeInterval(115), "Repeated reads must not reapply a phone floor")
        let cold = WatchComplicationSnapshotStore(
            defaults: defaults, accessClock: WatchAccessClockStore(directory: directory), clockSample: { _ in clock.sample }
        )
        XCTAssertEqual(try XCTUnwrap(cold.loadAccess()).remaining, 85)
        let loader = WatchComplicationTimelineLoader(now: { clock.sample.wallDate }, loadAccess: { cold.loadAccess() })
        let timeline = loader.timeline(configuration: WatchComplicationConfigurationIntent())
        let held = try XCTUnwrap(timeline.entries.first)
        XCTAssertEqual(held.sample.exactValue, "37%")
        XCTAssertEqual(timeline.entries.last?.date, clock.sample.wallDate.addingTimeInterval(85))
        let accounts = WatchComplicationAccountQuery(loadSnapshot: {
            WatchComplicationSnapshotStore(
                defaults: UserDefaults(suiteName: suite)!, accessClock: WatchAccessClockStore(directory: directory),
                clockSample: { _ in clock.sample }
            ).loadForAccess()
        }, now: { clock.sample.wallDate })
        let suggestions = try await accounts.suggestedEntities()
        XCTAssertEqual(suggestions.first?.providerName, "Codex")
        clock.move(wallOffset: -100, elapsed: 99)
        probe.advance(by: .seconds(84))
        XCTAssertEqual(try XCTUnwrap(cold.loadAccess()).remaining, 1)
        let observation = store.$snapshot.compactMap { $0 }.filter(\.isProLocked).sink { _ in locked.fulfill() }
        defer { observation.cancel() }
        clock.move(wallOffset: -100, elapsed: 100)
        probe.advance(by: .seconds(1))
        await fulfillment(of: [locked], timeout: 1)
        XCTAssertTrue(store.state(at: base).isProLocked)
        XCTAssertEqual(held.sample.availability, .locked)
        XCTAssertEqual(shared.load()?.proAccessEndsAt, base.addingTimeInterval(200))
        XCTAssertEqual(shared.load()?.proAccessEffectiveAt, base.addingTimeInterval(105))
        XCTAssertEqual(probe.requests.count, 1)
    }

    @MainActor
    func testNewerPhoneFloorShortensTheActiveTimerForTheSameDeadline() async throws {
        let sleeping = expectation(description: "Initial finite timer scheduled")
        let rescheduled = expectation(description: "Higher phone floor shortened the timer")
        let locked = expectation(description: "Shortened timer published lock")
        let probe = WatchSleepProbe(onSleep: { sleeping.fulfill() }, onRequest: { count in
            if count == 2 { rescheduled.fulfill() }
        })
        let origin = probe.now
        let clock = WatchReaderClock()
        clock.move(wallOffset: -100, elapsed: 0)
        let shared = WatchComplicationSnapshotStore(
            defaults: isolatedDefaults(), accessClock: WatchAccessClockStore(directory: try temporaryDirectory()), clockSample: { _ in clock.sample }
        )
        let store = WatchDashboardStore(
            defaults: isolatedDefaults(), complicationStore: shared, reloadComplications: {}, session: nil,
            accessTiming: .live(clock: WatchControlledClock(probe: probe), now: { clock.sample.wallDate }, sample: { clock.sample })
        )
        XCTAssertTrue(try store.receive(floorSnapshot(floorOffset: 100).applicationContext()))
        await fulfillment(of: [sleeping], timeout: 1)
        XCTAssertEqual(probe.requests.first?.deadline, origin.advanced(by: .seconds(100)))
        clock.move(wallOffset: -100, elapsed: 10)
        probe.advance(by: .seconds(10))
        XCTAssertTrue(try store.receive(floorSnapshot(floorOffset: 120, sequence: 2).applicationContext()))
        await fulfillment(of: [rescheduled], timeout: 1)
        XCTAssertEqual(try XCTUnwrap(shared.loadAccess()).effectiveDate, base.addingTimeInterval(120))
        XCTAssertEqual(try XCTUnwrap(shared.loadAccess()).remaining, 80)
        XCTAssertEqual(probe.requests.last?.deadline, origin.advanced(by: .seconds(90)))
        clock.move(wallOffset: -100, elapsed: 89)
        probe.advance(by: .seconds(79))
        XCTAssertEqual(try XCTUnwrap(shared.loadAccess()).remaining, 1)
        XCTAssertFalse(try XCTUnwrap(store.snapshot).isProLocked)
        let observation = store.$snapshot.compactMap { $0 }.filter(\.isProLocked).sink { _ in locked.fulfill() }
        defer { observation.cancel() }
        clock.move(wallOffset: -100, elapsed: 90)
        probe.advance(by: .seconds(1))
        await fulfillment(of: [locked], timeout: 1)
        XCTAssertTrue(store.state(at: base).isProLocked)
        XCTAssertEqual(probe.requests.count, 2)
    }

    @MainActor
    func testMissingFirstPhoneFloorDeniesWithoutPoisoningSameDeadlineRecovery() throws {
        let clock = WatchReaderClock()
        clock.move(wallOffset: -100, elapsed: 0)
        let shared = WatchComplicationSnapshotStore(
            defaults: isolatedDefaults(), accessClock: WatchAccessClockStore(directory: try temporaryDirectory()), clockSample: { _ in clock.sample }
        )
        let store = WatchDashboardStore(
            defaults: isolatedDefaults(), complicationStore: shared, reloadComplications: {}, session: nil,
            accessTiming: WatchAccessTiming(now: { clock.sample.wallDate }, schedule: { _, _ in AnyCancellable {} }, sample: { clock.sample })
        )
        let legacy = floorSnapshot(floorOffset: nil)
        XCTAssertNil(try WatchDashboardSnapshot.decode(legacy.encoded()).proAccessEffectiveAt)
        XCTAssertTrue(try store.receive(legacy.applicationContext()))
        XCTAssertTrue(try XCTUnwrap(store.snapshot).isProLocked)
        XCTAssertFalse(try XCTUnwrap(shared.loadAccess()).hasExpired)
        clock.move(wallOffset: -100, elapsed: 15)
        XCTAssertTrue(try store.receive(floorSnapshot(floorOffset: 100, sequence: 2).applicationContext()))
        XCTAssertFalse(try XCTUnwrap(store.snapshot).isProLocked)
        XCTAssertEqual(try XCTUnwrap(shared.loadAccess()).remaining, 100, "The missing floor must not create deadline history or an expiry receipt")
        XCTAssertTrue(try store.receive(floorSnapshot(floorOffset: nil, sequence: 3, deadlineOffset: nil).applicationContext()))
        XCTAssertFalse(try XCTUnwrap(store.snapshot).isProLocked)
        XCTAssertNil(try XCTUnwrap(shared.loadAccess()).remaining)
        XCTAssertTrue(try store.receive(floorSnapshot(floorOffset: nil, sequence: 4).applicationContext()))
        XCTAssertFalse(try XCTUnwrap(store.snapshot).isProLocked, "An existing valid Watch anchor survives a later missing phone floor")
        XCTAssertEqual(try XCTUnwrap(shared.loadAccess()).remaining, 100)
    }

    func testNonfiniteFirstPhoneFloorCannotInstallOrPoisonAValidReplacement() throws {
        for floor in [Double.nan, .infinity, -.infinity] {
            let guardStore = WatchAccessClockStore(directory: try temporaryDirectory())
            let sample = ProEntitlementClockSample(wallDate: base.addingTimeInterval(-100), continuousSeconds: 500, continuityID: "boot-A")
            let invalid = floorSnapshot(floorOffset: floor)
            XCTAssertThrowsError(try invalid.encoded())
            XCTAssertFalse(guardStore.accept(invalid, sample: sample))
            XCTAssertTrue(guardStore.decision(for: invalid, sample: sample).isLocked)
            XCTAssertFalse(guardStore.decision(for: invalid, sample: sample).hasExpired)
            let healthy = floorSnapshot(floorOffset: 100, sequence: 2)
            XCTAssertTrue(guardStore.accept(healthy, sample: sample))
            XCTAssertEqual(guardStore.decision(for: healthy, sample: sample).remaining, 100)
            let permanent = floorSnapshot(floorOffset: nil, sequence: 3, deadlineOffset: nil)
            XCTAssertTrue(guardStore.accept(permanent, sample: sample))
            XCTAssertFalse(guardStore.decision(for: permanent, sample: sample).isLocked)
        }
    }

    @MainActor
    func testExpiredFirstPhoneFloorSurvivesFailedInstallationAndDelayedLowerFloor() throws {
        let clock = WatchReaderClock()
        clock.move(wallOffset: -100, elapsed: 0)
        let fault = WatchClockWriteFault()
        fault.fail = true
        let shared = WatchComplicationSnapshotStore(
            defaults: isolatedDefaults(),
            accessClock: WatchAccessClockStore(directory: try temporaryDirectory(), write: { try fault.write($0, to: $1) }),
            clockSample: { _ in clock.sample }
        )
        let store = WatchDashboardStore(
            defaults: isolatedDefaults(), complicationStore: shared, reloadComplications: {}, session: nil,
            accessTiming: WatchAccessTiming(now: { clock.sample.wallDate }, schedule: { _, _ in AnyCancellable {} }, sample: { clock.sample })
        )
        XCTAssertTrue(try store.receive(floorSnapshot(floorOffset: 200).applicationContext()))
        XCTAssertTrue(try XCTUnwrap(store.snapshot).isProLocked)
        XCTAssertTrue(try XCTUnwrap(shared.loadAccess()).hasExpired, "The phone floor is actual expiry evidence despite a failed clock write")
        fault.fail = false
        clock.move(wallOffset: -200, elapsed: 1, boot: "boot-B")
        XCTAssertTrue(try store.receive(floorSnapshot(floorOffset: 100, sequence: 2).applicationContext()))
        XCTAssertTrue(try XCTUnwrap(store.snapshot).isProLocked)
        XCTAssertTrue(try XCTUnwrap(shared.loadAccess()).hasExpired)
        XCTAssertTrue(try store.receive(floorSnapshot(floorOffset: 100, sequence: 3, deadlineOffset: 400).applicationContext()))
        XCTAssertFalse(try XCTUnwrap(store.snapshot).isProLocked)
        XCTAssertEqual(try XCTUnwrap(shared.loadAccess()).remaining, 300)
        XCTAssertTrue(try store.receive(floorSnapshot(floorOffset: 100, sequence: 4).applicationContext()))
        XCTAssertTrue(try XCTUnwrap(store.snapshot).isProLocked, "A new deadline must not erase the old deadline's expiry receipt")
    }

    @MainActor
    func testPendingFloorExpirySurvivesForegroundWriteFailureAndReboot() throws {
        let clock = WatchReaderClock()
        clock.move(wallOffset: -100, elapsed: 0)
        let fault = WatchClockWriteFault()
        fault.fail = true
        let directory = try temporaryDirectory()
        let shared = WatchComplicationSnapshotStore(
            defaults: isolatedDefaults(), accessClock: WatchAccessClockStore(directory: directory, write: { try fault.write($0, to: $1) }),
            clockSample: { _ in clock.sample }
        )
        let store = WatchDashboardStore(
            defaults: isolatedDefaults(), complicationStore: shared, reloadComplications: {}, session: nil,
            accessTiming: WatchAccessTiming(now: { clock.sample.wallDate }, schedule: { _, _ in AnyCancellable {} }, sample: { clock.sample })
        )
        XCTAssertTrue(try store.receive(floorSnapshot(floorOffset: 100).applicationContext()))
        XCTAssertTrue(try XCTUnwrap(store.snapshot).isProLocked)
        XCTAssertFalse(try XCTUnwrap(shared.loadAccess()).hasExpired)
        clock.move(wallOffset: -100, elapsed: 100)
        store.reevaluateAccess()
        XCTAssertTrue(try XCTUnwrap(shared.loadAccess()).hasExpired, "Elapsed pending evidence must persist expiry even while every clock-record write fails")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("watch-access-clock.json").path))
        fault.fail = false
        clock.move(wallOffset: -200, elapsed: 1, boot: "boot-B")
        XCTAssertTrue(try store.receive(floorSnapshot(floorOffset: 100, sequence: 2).applicationContext()))
        XCTAssertTrue(try XCTUnwrap(store.snapshot).isProLocked)
        XCTAssertTrue(try XCTUnwrap(shared.loadAccess()).hasExpired)
        store.reevaluateAccess()
        XCTAssertTrue(store.state(at: base).isProLocked)
        XCTAssertTrue(try store.receive(floorSnapshot(floorOffset: 100, sequence: 3, deadlineOffset: 400).applicationContext()))
        XCTAssertFalse(try XCTUnwrap(store.snapshot).isProLocked)
        XCTAssertEqual(try XCTUnwrap(shared.loadAccess()).remaining, 300)
    }

    @MainActor
    func testPhoneFloorRoundTripsChangesSemanticsAndMakesEqualRevisionStricter() throws {
        let first = floorSnapshot(floorOffset: 100)
        let higher = floorSnapshot(floorOffset: 120)
        let lower = floorSnapshot(floorOffset: 105)
        let decoded = try WatchDashboardSnapshot.decode(higher.encoded())
        XCTAssertEqual(decoded, higher)
        XCTAssertEqual(decoded.proAccessEffectiveAt, base.addingTimeInterval(120))
        XCTAssertEqual(decoded.proAccessEndsAt, base.addingTimeInterval(200))
        XCTAssertNotEqual(try first.semanticData(), try higher.semanticData())
        XCTAssertTrue(higher.isNewer(than: first))
        XCTAssertFalse(lower.isNewer(than: higher))
        let clock = WatchReaderClock()
        clock.move(wallOffset: -100, elapsed: 0)
        let shared = WatchComplicationSnapshotStore(
            defaults: isolatedDefaults(), accessClock: WatchAccessClockStore(directory: try temporaryDirectory()), clockSample: { _ in clock.sample }
        )
        let store = WatchDashboardStore(
            defaults: isolatedDefaults(), complicationStore: shared, reloadComplications: {}, session: nil,
            accessTiming: WatchAccessTiming(now: { clock.sample.wallDate }, schedule: { _, _ in AnyCancellable {} }, sample: { clock.sample })
        )
        XCTAssertTrue(try store.receive(first.applicationContext()))
        clock.move(wallOffset: -100, elapsed: 10)
        XCTAssertTrue(try store.receive(higher.applicationContext()))
        XCTAssertEqual(try XCTUnwrap(shared.loadAccess()).remaining, 80)
        XCTAssertFalse(try store.receive(lower.applicationContext()))
        XCTAssertEqual(shared.load(), higher)
        clock.move(wallOffset: -100, elapsed: 15)
        XCTAssertEqual(try XCTUnwrap(shared.loadAccess()).effectiveDate, base.addingTimeInterval(125))
        XCTAssertEqual(try XCTUnwrap(shared.loadAccess()).remaining, 75)
    }

    private func floorSnapshot(
        floorOffset: TimeInterval?, sequence: UInt64 = 1, deadlineOffset: TimeInterval? = 200
    ) -> WatchDashboardSnapshot {
        WatchDashboardSnapshot(
            generatedAt: base.addingTimeInterval(-100), refreshIntervalSeconds: 300,
            accounts: snapshot(deadline: base.addingTimeInterval(200), sequence: sequence).accounts,
            isProLocked: false, proAccessEndsAt: deadlineOffset.map { base.addingTimeInterval($0) },
            proAccessEffectiveAt: floorOffset.map { base.addingTimeInterval($0) }, publicationSequence: sequence
        )
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
            ], isProLocked: locked, proAccessEndsAt: deadline, proAccessEffectiveAt: base, publicationSequence: sequence
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
