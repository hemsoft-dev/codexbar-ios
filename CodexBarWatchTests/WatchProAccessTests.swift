import Combine
import XCTest
import WidgetKit
@testable import CodexBarWatch

final class WatchProAccessTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 2_000_000_000)
    private let legacyKey = "watch.dashboard.last-good-snapshot"

    @MainActor
    func testLiveAdapterKeepsOriginalContinuousDeadlineWhenTaskStartsLate() async throws {
        let slept = expectation(description: "Live adapter reached injected clock sleep")
        let fired = expectation(description: "Already elapsed deadline publishes immediately")
        let probe = WatchSleepProbe(onSleep: { slept.fulfill() })
        let clock = WatchControlledClock(probe: probe)
        let origin = clock.now
        let timing = WatchAccessTiming.live(clock: clock, now: { self.base })
        let cancellation = timing.schedule(base.addingTimeInterval(10)) { fired.fulfill() }
        defer { cancellation.cancel() }
        // The MainActor task cannot start until this test yields. Time already passed.
        probe.advance(by: .seconds(30))
        await fulfillment(of: [slept], timeout: 1)
        let sleep = try XCTUnwrap(probe.requests.first)
        XCTAssertEqual(sleep.deadline, origin.advanced(by: .seconds(10)))
        XCTAssertEqual(sleep.tolerance, .zero)
        await fulfillment(of: [fired], timeout: 1)
    }

    @MainActor
    func testForegroundRollbackDoesNotPostponeLiveContinuousDeadlineForSameSnapshot() async throws {
        let slept = expectation(description: "Initial live sleep started")
        let locked = expectation(description: "Original continuous boundary committed lock")
        let probe = WatchSleepProbe(onSleep: { slept.fulfill() })
        let clock = WatchControlledClock(probe: probe)
        var wallDate = base
        let store = WatchDashboardStore(
            defaults: isolatedDefaults(), complicationStore: .init(testDefaults: isolatedDefaults()),
            reloadComplications: {}, session: nil,
            accessTiming: .live(clock: clock, now: { wallDate })
        )
        let observation = store.$snapshot.compactMap { $0 }.filter(\.isProLocked).sink { _ in locked.fulfill() }
        defer { observation.cancel() }
        XCTAssertTrue(try store.receive(snapshot(deadline: base.addingTimeInterval(10), sequence: 80).applicationContext()))
        await fulfillment(of: [slept], timeout: 1)
        probe.advance(by: .seconds(4))
        wallDate = base.addingTimeInterval(-100)
        store.reevaluateAccess()
        probe.advance(by: .seconds(6))
        await fulfillment(of: [locked], timeout: 1)
        XCTAssertTrue(store.state(at: base).isProLocked, "A stale TimelineView date cannot hide an unpublished lock")
        XCTAssertEqual(probe.requests.count, 1, "The same grant retains its original continuous sleep")
    }

    @MainActor
    func testEqualSequenceHarmlessRefreshKeepsOriginalLiveBoundaryAfterRollback() async throws {
        try await checkRefreshKeepsOriginalBoundary(refreshedSequence: 80)
    }

    @MainActor
    func testNewerUsagePublicationWithSameDeadlineKeepsOriginalLiveBoundaryAfterRollback() async throws {
        try await checkRefreshKeepsOriginalBoundary(refreshedSequence: 81)
    }

    @MainActor
    private func checkRefreshKeepsOriginalBoundary(refreshedSequence: UInt64) async throws {
        let slept = expectation(description: "Initial live sleep started")
        let locked = expectation(description: "Current snapshot locked at original continuous boundary")
        let probe = WatchSleepProbe(onSleep: { slept.fulfill() })
        var wallDate = base
        let store = WatchDashboardStore(
            defaults: isolatedDefaults(), complicationStore: .init(testDefaults: isolatedDefaults()),
            reloadComplications: {}, session: nil,
            accessTiming: .live(clock: WatchControlledClock(probe: probe), now: { wallDate })
        )
        let observation = store.$snapshot.compactMap { $0 }.filter(\.isProLocked).sink { _ in locked.fulfill() }
        defer { observation.cancel() }
        let deadline = base.addingTimeInterval(10)
        XCTAssertTrue(try store.receive(snapshot(deadline: deadline, sequence: 80).applicationContext()))
        await fulfillment(of: [slept], timeout: 1)
        probe.advance(by: .seconds(4))
        wallDate = base.addingTimeInterval(-100)
        let refreshed = snapshot(date: base.addingTimeInterval(4), deadline: deadline, sequence: refreshedSequence)
        XCTAssertTrue(try store.receive(refreshed.applicationContext()))
        probe.advance(by: .seconds(6))
        await fulfillment(of: [locked], timeout: 1)
        XCTAssertEqual(probe.requests.count, 1, "Harmless usage refresh must not move the access boundary")
        XCTAssertTrue(store.state(at: base).isProLocked)
        XCTAssertEqual(store.snapshot?.publicationSequence, refreshedSequence)
        XCTAssertEqual(store.snapshot?.generatedAt, refreshed.generatedAt)
    }

    @MainActor
    func testExpiryIsPublishedBeforeComplicationReloadEvenWithOldTimelineDate() throws {
        let clock = WatchAccessTestClock(now: base)
        var store: WatchDashboardStore?
        var checksExpiryReload = false
        var publishedLock = false
        var checkedReload = false
        store = makeStore(defaults: isolatedDefaults(), shared: .init(testDefaults: isolatedDefaults()), clock: clock) {
            guard checksExpiryReload else { return }
            checkedReload = true
            XCTAssertTrue(publishedLock)
            XCTAssertTrue(store?.snapshot?.isProLocked == true)
            XCTAssertTrue(store?.state(at: self.base).samples.isEmpty == true)
        }
        let dashboard = try XCTUnwrap(store)
        let observation = dashboard.$snapshot.sink { publishedLock = $0?.isProLocked == true }
        defer { observation.cancel() }
        let deadline = base.addingTimeInterval(10)
        XCTAssertTrue(try dashboard.receive(snapshot(deadline: deadline, sequence: 81).applicationContext()))
        checksExpiryReload = true
        clock.advance(to: deadline)
        XCTAssertTrue(checkedReload)
    }

    func testFiniteExpiredRetainedAccountsAreHiddenFromActualComplicationQueries() async throws {
        let suite = "WatchProAccessTests.\(UUID().uuidString)"
        let defaults = isolatedDefaults(suite: suite)
        let shared = WatchComplicationSnapshotStore(testDefaults: defaults)
        try shared.saveIfChanged(snapshot(deadline: Date().addingTimeInterval(-1), sequence: 82))
        let accounts = WatchComplicationAccountQuery(loadSnapshot: {
            WatchComplicationSnapshotStore(testDefaults: UserDefaults(suiteName: suite)!).load()
        })
        let metrics = WatchComplicationMetricQuery(loadSnapshot: {
            WatchComplicationSnapshotStore(testDefaults: UserDefaults(suiteName: suite)!).load()
        })
        let suggestions = try await accounts.suggestedEntities()
        let metricSuggestions = try await metrics.suggestedEntities()
        let savedAccount = try await accounts.entities(for: ["codex.work"])
        let savedMetric = try await metrics.entities(for: ["codex.work::weekly"])
        XCTAssertTrue(suggestions.isEmpty)
        XCTAssertTrue(metricSuggestions.isEmpty)
        XCTAssertEqual(savedAccount.first?.providerName, "Saved Account")
        XCTAssertEqual(savedAccount.first?.id, "codex.work")
        XCTAssertEqual(savedMetric.first?.metricLabel, "Saved Metric")
        XCTAssertEqual(savedMetric.first?.id, "codex.work::weekly")
        XCTAssertFalse(try XCTUnwrap(shared.load()).accounts.isEmpty)
    }

    func testActualComplicationQueriesAtBoundaryColdRollbackAndNewPhoneRecoveryPreserveRawBytes() async throws {
        let suite = "WatchProAccessTests.\(UUID().uuidString)"
        let defaults = isolatedDefaults(suite: suite)
        let shared = WatchComplicationSnapshotStore(testDefaults: defaults)
        let deadline = base.addingTimeInterval(10)
        try shared.saveIfChanged(snapshot(deadline: deadline, sequence: 83))
        let originalBytes = defaults.data(forKey: WatchComplicationConstants.snapshotDefaultsKey)
        for offset in [-0.001, 0, 0.001, -5] {
            let date = deadline.addingTimeInterval(offset)
            let accounts = WatchComplicationAccountQuery(loadSnapshot: {
                WatchComplicationSnapshotStore(testDefaults: UserDefaults(suiteName: suite)!).loadForAccess(now: date)
            }, now: { date })
            let metrics = WatchComplicationMetricQuery(loadSnapshot: {
                WatchComplicationSnapshotStore(testDefaults: UserDefaults(suiteName: suite)!).loadForAccess(now: date)
            }, now: { date })
            let suggestions = try await accounts.suggestedEntities()
            let metricSuggestions = try await metrics.suggestedEntities()
            let savedAccounts = try await accounts.entities(for: ["account"])
            let savedMetrics = try await metrics.entities(for: ["account::usage"])
            let locked = offset != -0.001
            XCTAssertEqual(suggestions.isEmpty, locked)
            XCTAssertEqual(metricSuggestions.isEmpty, locked)
            XCTAssertEqual(savedAccounts.first?.providerName, locked ? "Saved Account" : "Codex")
            XCTAssertEqual(savedMetrics.first?.metricLabel, locked ? "Saved Metric" : "5-hour limit")
            XCTAssertEqual(savedAccounts.first?.id, "account")
            XCTAssertEqual(savedMetrics.first?.id, "account::usage")
        }
        XCTAssertEqual(defaults.data(forKey: WatchComplicationConstants.snapshotDefaultsKey), originalBytes)
        try shared.saveIfChanged(snapshot(deadline: deadline.addingTimeInterval(100), sequence: 84))
        let recovered = WatchComplicationAccountQuery(loadSnapshot: {
            WatchComplicationSnapshotStore(testDefaults: UserDefaults(suiteName: suite)!).loadForAccess(now: deadline.addingTimeInterval(-5))
        }, now: { deadline.addingTimeInterval(-5) })
        let suggestions = try await recovered.suggestedEntities()
        XCTAssertFalse(suggestions.isEmpty)
    }

    func testAccessMetadataRoundTripsAndLegacyPayloadFailsClosed() throws {
        let defaults = isolatedDefaults()
        let store = WatchComplicationSnapshotStore(testDefaults: defaults)
        let deadline = base.addingTimeInterval(137.125)
        try store.saveIfChanged(snapshot(deadline: deadline, sequence: 8))
        let decoded = try XCTUnwrap(WatchComplicationSnapshotStore(testDefaults: defaults).load())
        XCTAssertEqual(decoded.proAccessEndsAt, deadline)
        XCTAssertEqual(decoded.publicationSequence, 8)
        for (offset, expected) in [(-0.001, false), (0.0, true), (0.001, true)] {
            let state = WatchDashboardState(
                snapshot: decoded, now: deadline.addingTimeInterval(offset),
                isPhoneReachable: false, decodingError: "Offline"
            )
            XCTAssertEqual(state.isProLocked, expected)
            XCTAssertEqual(state.samples.isEmpty, expected)
            if expected { XCTAssertEqual(state.statusText, WatchDashboardState.lockedMessage) }
        }
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: decoded.encoded()) as? [String: Any])
        legacy.removeValue(forKey: "isProLocked")
        legacy.removeValue(forKey: "proAccessEndsAt")
        legacy.removeValue(forKey: "publicationSequence")
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: WatchComplicationConstants.snapshotDefaultsKey)
        let legacyDecoded = try XCTUnwrap(WatchComplicationSnapshotStore(testDefaults: defaults).load())
        XCTAssertTrue(legacyDecoded.isProLocked)
        XCTAssertEqual(WatchComplicationResolver().resolve(snapshot: legacyDecoded, selection: .automatic, at: base).availability, .locked)
        defaults.set(Data("invalid".utf8), forKey: WatchComplicationConstants.snapshotDefaultsKey)
        XCTAssertNil(WatchComplicationSnapshotStore(testDefaults: defaults).load())
    }

    func testSemanticPayloadIncludesAccessButNotSequenceOrGenerationDate() throws {
        let original = snapshot(deadline: base.addingTimeInterval(200), sequence: 1)
        let same = snapshot(date: base.addingTimeInterval(30), deadline: base.addingTimeInterval(200), sequence: 2)
        XCTAssertEqual(try original.semanticData(), try same.semanticData())
        XCTAssertNotEqual(try original.semanticData(), try snapshot(locked: true, sequence: 3).semanticData())
        XCTAssertNotEqual(try original.semanticData(), try snapshot(deadline: base.addingTimeInterval(300), sequence: 3).semanticData())
        XCTAssertNotEqual(try original.semanticData(), try snapshot(sequence: 3).semanticData())
    }

    @MainActor
    func testLiveOrderingRejectsDelayedGrantAndLockAcrossClockRollbackAndRestart() throws {
        let defaults = isolatedDefaults()
        let shared = WatchComplicationSnapshotStore(testDefaults: isolatedDefaults())
        let clock = WatchAccessTestClock(now: base)
        let store = makeStore(defaults: defaults, shared: shared, clock: clock)
        let oldGrant = snapshot(date: base.addingTimeInterval(10_000), sequence: 10)
        let denial = snapshot(date: base.addingTimeInterval(-10_000), locked: true, sequence: 11)
        let upgrade = snapshot(date: base.addingTimeInterval(-20_000), sequence: 12)
        XCTAssertTrue(try store.receive(oldGrant.applicationContext()))
        XCTAssertTrue(try store.receive(denial.applicationContext()))
        XCTAssertTrue(store.state(at: base).isProLocked)
        XCTAssertFalse(try store.receive(oldGrant.applicationContext()))
        XCTAssertTrue(try store.receive(upgrade.applicationContext()))
        XCTAssertFalse(try store.receive(denial.applicationContext()))
        XCTAssertEqual(store.state(at: base).samples.first?.exactValue, "37%")
        let relaunched = makeStore(defaults: defaults, shared: shared, clock: clock)
        XCTAssertEqual(relaunched.snapshot, upgrade)
        XCTAssertFalse(try relaunched.receive(denial.applicationContext()))
        XCTAssertEqual(try WatchDashboardSnapshot.decode(XCTUnwrap(defaults.data(forKey: legacyKey))), upgrade)
        XCTAssertEqual(shared.load(), upgrade)
    }

    @MainActor
    func testSameSequenceDenialDominatesBothDeliveryOrdersAndHarmlessRefreshIsAccepted() throws {
        for denialFirst in [true, false] {
            let clock = WatchAccessTestClock(now: base)
            let store = makeStore(defaults: isolatedDefaults(), shared: .init(testDefaults: isolatedDefaults()), clock: clock)
            let grant = snapshot(sequence: 20)
            let denial = snapshot(locked: true, sequence: 20)
            XCTAssertTrue(try store.receive((denialFirst ? denial : grant).applicationContext()))
            XCTAssertEqual(try store.receive((denialFirst ? grant : denial).applicationContext()), !denialFirst)
            XCTAssertTrue(store.state(at: base).isProLocked)
            let upgrade = snapshot(sequence: 21)
            XCTAssertTrue(try store.receive(upgrade.applicationContext()))
            let refresh = snapshot(date: base.addingTimeInterval(100), sequence: 21)
            XCTAssertTrue(try store.receive(refresh.applicationContext()))
            XCTAssertEqual(store.snapshot?.generatedAt, refresh.generatedAt)
        }
    }

    @MainActor
    func testLowerPhoneSequenceRequestsPersistedWatermarkAndAcceptsRecoveredPublication() async throws {
        let defaults = isolatedDefaults()
        let shared = WatchComplicationSnapshotStore(testDefaults: isolatedDefaults())
        try shared.saveIfChanged(snapshot(locked: true, sequence: 100))
        let initialRequest = expectation(description: "Initial reachability request completed")
        let requested = expectation(description: "Rejected lower revision independently requests recovery")
        requested.assertForOverFulfill = true
        var watermarks: [UInt64?] = []
        let recovered = try snapshot(sequence: 101).encoded()
        let clock = WatchAccessTestClock(now: base)
        let store = WatchDashboardStore(
            defaults: defaults, complicationStore: shared, reloadComplications: {}, session: nil,
            requestCoalescingDelay: .zero,
            accessTiming: WatchAccessTiming(now: { clock.now }, schedule: { clock.schedule($0, action: $1) }, sample: {
                ProEntitlementClockSample(wallDate: clock.now, continuousSeconds: 0, continuityID: "watch-test-boot")
            }),
            requestSnapshotAfterSequence: { sequence, reply, _ in
                watermarks.append(sequence)
                if watermarks.count == 1 {
                    reply(.unavailable)
                    initialRequest.fulfill()
                } else {
                    reply(.snapshot(recovered))
                    requested.fulfill()
                }
            }
        )
        store.updateReachability(true)
        await fulfillment(of: [initialRequest], timeout: 1)
        XCTAssertEqual(watermarks, [100])
        XCTAssertEqual(store.snapshot?.publicationSequence, 100)
        let restartedPhone = snapshot(sequence: 1)
        XCTAssertFalse(try store.receive(restartedPhone.applicationContext()))
        XCTAssertFalse(try store.receive(restartedPhone.applicationContext()))
        XCTAssertTrue(store.state(at: base).isProLocked)
        await fulfillment(of: [requested], timeout: 1)
        XCTAssertEqual(watermarks, [100, 100])
        XCTAssertEqual(store.snapshot?.publicationSequence, 101)
        XCTAssertEqual(store.state(at: base).samples.first?.exactValue, "37%")
        let request = WatchDashboardSnapshot.snapshotRequestMessage(after: 100)
        XCTAssertTrue(WatchDashboardSnapshot.isSnapshotRequest(request))
        XCTAssertEqual((request[WatchDashboardSnapshot.snapshotAfterSequenceKey] as? NSNumber)?.uint64Value, 100)
        XCTAssertNil(WatchDashboardSnapshot.snapshotRequestMessage[WatchDashboardSnapshot.snapshotAfterSequenceKey])
    }

    @MainActor
    func testEqualSequencePhoneResetRecoversDenialAndConflictingUsageWithoutReplayLoop() async throws {
        for retainedLock in [true, false] {
            let shared = WatchComplicationSnapshotStore(testDefaults: isolatedDefaults())
            try shared.saveIfChanged(snapshot(locked: retainedLock, sequence: 1))
            let changedAccounts = [WatchAccountSnapshot(
                id: "account", providerName: "Codex", accountLabel: "Personal", fetchedAt: base,
                metrics: [WatchMetricSnapshot(id: "usage", label: "5-hour limit", exactValue: "9%")]
            ),
            ]
            let incoming = snapshot(sequence: 1, accounts: changedAccounts)
            let recovered = snapshot(sequence: 2, accounts: changedAccounts)
            let initialRequest = expectation(description: "Initial reachability request completed")
            let requested = expectation(description: "Rejected equal revision independently requests recovery")
            let duplicateRequest = expectation(description: "Stale replay never requests recovery twice")
            duplicateRequest.isInverted = true
            var watermarks: [UInt64?] = []
            var replyHandler: (@MainActor (WatchDashboardSnapshotResponse) -> Void)?
            let clock = WatchAccessTestClock(now: base)
            let store = WatchDashboardStore(
                defaults: isolatedDefaults(), complicationStore: shared, reloadComplications: {}, session: nil,
                requestCoalescingDelay: .zero,
                accessTiming: WatchAccessTiming(now: { clock.now }, schedule: { clock.schedule($0, action: $1) }, sample: {
                ProEntitlementClockSample(wallDate: clock.now, continuousSeconds: 0, continuityID: "watch-test-boot")
            }),
                requestSnapshotAfterSequence: { sequence, reply, _ in
                    watermarks.append(sequence)
                    switch watermarks.count {
                    case 1:
                        reply(.unavailable)
                        initialRequest.fulfill()
                    case 2:
                        replyHandler = reply
                        requested.fulfill()
                    default:
                        duplicateRequest.fulfill()
                    }
                }
            )
            store.updateReachability(true)
            await fulfillment(of: [initialRequest], timeout: 1)
            XCTAssertEqual(watermarks, [1])
            XCTAssertEqual(store.snapshot?.publicationSequence, 1)
            XCTAssertFalse(try store.receive(incoming.applicationContext()))
            XCTAssertFalse(try store.receive(incoming.applicationContext()))
            XCTAssertEqual(store.state(at: base).isProLocked, retainedLock)
            if !retainedLock { XCTAssertEqual(store.state(at: base).samples.first?.exactValue, "37%") }
            await fulfillment(of: [requested], timeout: 1)
            XCTAssertEqual(watermarks, [1, 1])
            try XCTUnwrap(replyHandler)(.snapshot(recovered.encoded()))
            XCTAssertEqual(store.snapshot?.publicationSequence, 2)
            XCTAssertEqual(store.state(at: base).samples.first?.exactValue, "9%")
            for offset in [0.0, 100, -100] {
                let replay = snapshot(date: base.addingTimeInterval(offset), sequence: 1, accounts: changedAccounts)
                XCTAssertFalse(try store.receive(replay.applicationContext()))
                try XCTUnwrap(replyHandler)(.snapshot(replay.encoded()))
            }
            await fulfillment(of: [duplicateRequest], timeout: 0.05)
            XCTAssertEqual(watermarks, [1, 1])
            XCTAssertEqual(shared.load()?.publicationSequence, 2)
            XCTAssertEqual(store.state(at: base).samples.first?.exactValue, "9%")
        }
    }

    @MainActor
    func testNewConflictingPayloadRecoversWhilePreviouslyRejectedPayloadsRemainBounded() async throws {
        let shared = WatchComplicationSnapshotStore(testDefaults: isolatedDefaults())
        try shared.saveIfChanged(snapshot(locked: true, sequence: 1))
        let initialRequest = expectation(description: "Initial reachability request completed")
        let firstRequest = expectation(description: "First conflict independently requests recovery")
        let secondRequest = expectation(description: "Different conflict recovery")
        let replayRequest = expectation(description: "Previously rejected signatures stay suppressed")
        replayRequest.isInverted = true
        var replies: [@MainActor (WatchDashboardSnapshotResponse) -> Void] = []
        var watermarks: [UInt64?] = []
        let clock = WatchAccessTestClock(now: base)
        let store = WatchDashboardStore(
            defaults: isolatedDefaults(), complicationStore: shared, reloadComplications: {}, session: nil,
            requestCoalescingDelay: .zero,
            accessTiming: WatchAccessTiming(now: { clock.now }, schedule: { clock.schedule($0, action: $1) }, sample: {
                ProEntitlementClockSample(wallDate: clock.now, continuousSeconds: 0, continuityID: "watch-test-boot")
            }),
            requestSnapshotAfterSequence: { sequence, reply, _ in
                watermarks.append(sequence)
                switch watermarks.count {
                case 1:
                    reply(.unavailable)
                    initialRequest.fulfill()
                case 2:
                    replies.append(reply)
                    firstRequest.fulfill()
                case 3:
                    replies.append(reply)
                    secondRequest.fulfill()
                default:
                    replayRequest.fulfill()
                }
            }
        )
        store.updateReachability(true)
        await fulfillment(of: [initialRequest], timeout: 1)
        XCTAssertEqual(watermarks, [1])
        XCTAssertEqual(store.snapshot?.publicationSequence, 1)
        let firstConflict = snapshot(sequence: 1)
        XCTAssertFalse(try store.receive(firstConflict.applicationContext()))
        await fulfillment(of: [firstRequest], timeout: 1)
        XCTAssertEqual(watermarks, [1, 1])
        let firstReply = try XCTUnwrap(replies.first)
        firstReply(.snapshot(try snapshot(sequence: 2).encoded()))
        let secondConflict = snapshot(deadline: base.addingTimeInterval(100), sequence: 1)
        XCTAssertFalse(try store.receive(secondConflict.applicationContext()))
        await fulfillment(of: [secondRequest], timeout: 1)
        let secondReply = try XCTUnwrap(replies.dropFirst().first)
        secondReply(.snapshot(try snapshot(sequence: 3).encoded()))
        XCTAssertEqual(watermarks, [1, 1, 2])
        for stale in [firstConflict, secondConflict, firstConflict, secondConflict] {
            XCTAssertFalse(try store.receive(stale.applicationContext()))
        }
        firstReply(.snapshot(try snapshot(locked: true, sequence: 2).encoded()))
        secondReply(.snapshot(try snapshot(locked: true, sequence: 3).encoded()))
        await fulfillment(of: [replayRequest], timeout: 0.05)
        XCTAssertEqual(watermarks, [1, 1, 2])
        XCTAssertEqual(store.snapshot?.publicationSequence, 3)
        XCTAssertFalse(store.state(at: base).isProLocked)
        XCTAssertEqual(store.state(at: base).samples.first?.exactValue, "37%")
    }

    @MainActor
    func testEqualSequenceCannotExtendDeadlineButHigherSequenceCanRenew() throws {
        let clock = WatchAccessTestClock(now: base)
        let store = makeStore(defaults: isolatedDefaults(), shared: .init(testDefaults: isolatedDefaults()), clock: clock)
        let short = base.addingTimeInterval(30)
        let long = base.addingTimeInterval(90)
        XCTAssertTrue(try store.receive(snapshot(deadline: long, sequence: 25).applicationContext()))
        XCTAssertTrue(try store.receive(snapshot(deadline: short, sequence: 25).applicationContext()))
        XCTAssertFalse(try store.receive(snapshot(deadline: long, sequence: 25).applicationContext()))
        XCTAssertFalse(try store.receive(snapshot(sequence: 25).applicationContext()))
        XCTAssertTrue(try store.receive(snapshot(deadline: long, sequence: 26).applicationContext()))
        XCTAssertEqual(store.snapshot?.proAccessEndsAt, long)
    }

    @MainActor
    func testMigrationUsesPublicationOrderAndDenialTieBreakInBothDirections() throws {
        let olderGrant = snapshot(date: base.addingTimeInterval(50_000), sequence: 30)
        let currentDenial = snapshot(date: base.addingTimeInterval(-50_000), locked: true, sequence: 31)
        let equalGrant = snapshot(date: currentDenial.generatedAt, sequence: 31)
        let legacyGrant = snapshot(date: base.addingTimeInterval(100_000))
        let upgraded = snapshot(date: base.addingTimeInterval(-100_000), sequence: 32)
        let pairs = [(olderGrant, currentDenial), (equalGrant, currentDenial), (legacyGrant, currentDenial), (currentDenial, upgraded)]
        for (loser, winner) in pairs {
            for legacyWins in [true, false] {
                let defaults = isolatedDefaults()
                let shared = WatchComplicationSnapshotStore(testDefaults: isolatedDefaults())
                defaults.set(try (legacyWins ? winner : loser).encoded(), forKey: legacyKey)
                try shared.saveIfChanged(legacyWins ? loser : winner)
                let clock = WatchAccessTestClock(now: base)
                let store = makeStore(defaults: defaults, shared: shared, clock: clock)
                XCTAssertEqual(store.snapshot, winner)
                XCTAssertEqual(shared.load(), winner)
                XCTAssertEqual(try WatchDashboardSnapshot.decode(XCTUnwrap(defaults.data(forKey: legacyKey))), winner)
                XCTAssertEqual(makeStore(defaults: defaults, shared: shared, clock: clock).snapshot, winner)
            }
        }
    }

    @MainActor
    func testUnsequencedLegacyTimestampFallbackAndEqualTimestampDenial() throws {
        let older = snapshot(date: base.addingTimeInterval(-10))
        let locked = snapshot(locked: true)
        let newer = snapshot(date: base.addingTimeInterval(10))
        for legacyWins in [true, false] {
            let defaults = isolatedDefaults()
            let shared = WatchComplicationSnapshotStore(testDefaults: isolatedDefaults())
            defaults.set(try (legacyWins ? locked : older).encoded(), forKey: legacyKey)
            try shared.saveIfChanged(legacyWins ? older : locked)
            let store = makeStore(defaults: defaults, shared: shared, clock: WatchAccessTestClock(now: base))
            XCTAssertTrue(store.state(at: base).isProLocked)
            XCTAssertFalse(try store.receive(snapshot().applicationContext()))
            XCTAssertTrue(try store.receive(newer.applicationContext()))
            XCTAssertFalse(store.state(at: base).isProLocked)
        }
    }

    @MainActor
    func testVisibleOfflineStorePublishesAndPersistsLockAtScheduledDeadline() throws {
        let defaults = isolatedDefaults()
        let shared = WatchComplicationSnapshotStore(testDefaults: isolatedDefaults())
        let clock = WatchAccessTestClock(now: base)
        var reloads = 0
        let store = makeStore(defaults: defaults, shared: shared, clock: clock, reload: { reloads += 1 })
        let deadline = base.addingTimeInterval(37.125)
        let grant = snapshot(deadline: deadline, sequence: 40)
        XCTAssertTrue(try store.receive(grant.applicationContext()))
        XCTAssertEqual(clock.scheduled.map(\.deadline), [deadline])
        var publishedLocks: [Bool] = []
        let observation = store.$snapshot.dropFirst().sink { publishedLocks.append($0?.isProLocked == true) }
        defer { observation.cancel() }
        clock.advance(to: deadline.addingTimeInterval(-0.001))
        XCTAssertEqual(store.state(at: clock.now).samples.first?.exactValue, "37%")
        XCTAssertTrue(publishedLocks.isEmpty)
        clock.advance(to: deadline)
        XCTAssertEqual(publishedLocks, [true])
        XCTAssertTrue(store.state(at: clock.now).samples.isEmpty)
        XCTAssertEqual(store.state(at: clock.now).statusText, WatchDashboardState.lockedMessage)
        XCTAssertEqual(reloads, 2)
        let persisted = try WatchDashboardSnapshot.decode(XCTUnwrap(defaults.data(forKey: legacyKey)))
        XCTAssertTrue(persisted.isProLocked)
        XCTAssertEqual(persisted.proAccessEndsAt, deadline)
        XCTAssertTrue(try XCTUnwrap(shared.load()).isProLocked)
        XCTAssertFalse(try store.receive(grant.applicationContext()))
        XCTAssertTrue(try store.receive(snapshot(sequence: 41).applicationContext()))
        XCTAssertEqual(store.state(at: clock.now).samples.first?.exactValue, "37%")
    }

    @MainActor
    func testQueuedNewerUsageCannotReviveAlreadyExpiredDeadlineAfterRollback() throws {
        let shared = WatchComplicationSnapshotStore(testDefaults: isolatedDefaults())
        let clock = WatchAccessTestClock(now: base)
        let store = makeStore(defaults: isolatedDefaults(), shared: shared, clock: clock)
        let deadline = base.addingTimeInterval(10)
        XCTAssertTrue(try store.receive(snapshot(deadline: deadline, sequence: 80).applicationContext()))
        clock.advance(to: deadline)
        XCTAssertTrue(store.state(at: base).isProLocked)
        clock.now = base.addingTimeInterval(-100)
        XCTAssertTrue(try store.receive(snapshot(date: base.addingTimeInterval(4), deadline: deadline, sequence: 81).applicationContext()))
        XCTAssertTrue(store.state(at: base).isProLocked, "Queued usage cannot reopen an already observed access deadline")
        XCTAssertEqual(store.snapshot?.publicationSequence, 81)
        XCTAssertEqual(clock.scheduled.count, 1)
        let renewal = deadline.addingTimeInterval(100)
        XCTAssertTrue(try store.receive(snapshot(deadline: renewal, sequence: 82).applicationContext()))
        XCTAssertFalse(store.state(at: base).isProLocked)
        clock.advance(to: renewal)
        XCTAssertTrue(store.state(at: base).isProLocked)
        XCTAssertTrue(try store.receive(snapshot(sequence: 83).applicationContext()))
        XCTAssertFalse(store.state(at: base).isProLocked)
    }

    @MainActor
    func testRenewalCancelsOldDeadlineAndPermanentGrantCancelsAllDeadlines() throws {
        let clock = WatchAccessTestClock(now: base)
        let store = makeStore(defaults: isolatedDefaults(), shared: .init(testDefaults: isolatedDefaults()), clock: clock)
        let firstDeadline = base.addingTimeInterval(10)
        let nextDeadline = base.addingTimeInterval(25)
        XCTAssertTrue(try store.receive(snapshot(deadline: firstDeadline, sequence: 50).applicationContext()))
        XCTAssertTrue(try store.receive(snapshot(deadline: nextDeadline, sequence: 51).applicationContext()))
        XCTAssertTrue(clock.scheduled[0].isCancelled)
        clock.advance(to: firstDeadline)
        XCTAssertFalse(store.state(at: clock.now).isProLocked)
        clock.scheduled[0].action()
        XCTAssertFalse(store.state(at: clock.now).isProLocked)
        XCTAssertTrue(try store.receive(snapshot(sequence: 52).applicationContext()))
        XCTAssertTrue(clock.scheduled[1].isCancelled)
        clock.advance(to: nextDeadline)
        XCTAssertFalse(store.state(at: clock.now).isProLocked)
        XCTAssertEqual(clock.scheduled.count, 2)
    }

    @MainActor
    func testForegroundExpirySurvivesDecodeFailureRelaunchAndLocalClockRollback() throws {
        let defaults = isolatedDefaults()
        let shared = WatchComplicationSnapshotStore(testDefaults: isolatedDefaults())
        let clock = WatchAccessTestClock(now: base)
        let store = makeStore(defaults: defaults, shared: shared, clock: clock)
        let deadline = base.addingTimeInterval(10)
        XCTAssertTrue(try store.receive(snapshot(deadline: deadline, sequence: 60).applicationContext()))
        clock.now = deadline.addingTimeInterval(1)
        store.reevaluateAccess()
        XCTAssertTrue(clock.scheduled[0].isCancelled)
        XCTAssertTrue(store.state(at: clock.now).isProLocked)
        XCTAssertFalse(store.receive(.malformed))
        XCTAssertTrue(store.state(at: clock.now).samples.isEmpty)
        clock.now = base.addingTimeInterval(-1_000)
        let relaunched = makeStore(defaults: defaults, shared: shared, clock: clock)
        XCTAssertTrue(relaunched.state(at: clock.now).isProLocked)
        XCTAssertEqual(relaunched.snapshot?.proAccessEndsAt, deadline)
        XCTAssertFalse(try relaunched.receive(snapshot(deadline: deadline, sequence: 60).applicationContext()))
    }

    func testComplicationTimelineHasExactLockForEveryUsagePathAndNoPostLockEntry() throws {
        let deadline = base.addingTimeInterval(121.125)
        let variants = [
            snapshot(deadline: deadline),
            snapshot(deadline: deadline, fetchedAt: base.addingTimeInterval(-7_200)),
            snapshot(deadline: deadline, accounts: []),
            snapshot(deadline: deadline, resetsAt: base.addingTimeInterval(30)),
            snapshot(deadline: deadline, resetsAt: deadline),
        ]
        for candidate in variants {
            for missingSelection in [false, true] {
                let defaults = isolatedDefaults()
                try WatchComplicationSnapshotStore(testDefaults: defaults).saveIfChanged(candidate)
                let persisted = WatchComplicationSnapshotStore(testDefaults: defaults)
                let configuration = WatchComplicationConfigurationIntent()
                if missingSelection {
                    configuration.account = WatchComplicationAccountEntity(id: "missing", providerName: "Saved", accountLabel: "Saved")
                }
                let loader = WatchComplicationTimelineLoader(now: { self.base }, loadSnapshot: { persisted.load() })
                let timeline = loader.timeline(configuration: configuration)
                XCTAssertEqual(timeline.entries.last?.date, deadline)
                XCTAssertEqual(timeline.entries.last?.sample.availability, .locked)
                XCTAssertEqual(timeline.entries.filter { $0.date == deadline }.count, 1)
                XCTAssertEqual(timeline.entries.map(\.date), Array(Set(timeline.entries.map(\.date))).sorted())
                XCTAssertTrue(timeline.entries.allSatisfy { $0.date <= deadline })
                for offset in [-0.001, 0, 0.001] {
                    let entry = loader.entry(configuration: configuration, date: deadline.addingTimeInterval(offset))
                    XCTAssertEqual(entry.sample.availability == .locked, offset >= 0)
                }
            }
        }
    }

    func testPermanentAndAlreadyLockedComplicationTimelinesDoNotInventDeadlines() throws {
        for candidate in [snapshot(), snapshot(locked: true), snapshot(deadline: base)] {
            let shared = WatchComplicationSnapshotStore(testDefaults: isolatedDefaults())
            try shared.saveIfChanged(candidate)
            let loader = WatchComplicationTimelineLoader(now: { self.base }, loadSnapshot: { shared.load() })
            let timeline = loader.timeline(configuration: WatchComplicationConfigurationIntent())
            if candidate.isLocked(at: base) {
                XCTAssertEqual(timeline.entries.count, 1)
                XCTAssertEqual(timeline.entries[0].sample.availability, .locked)
            } else {
                XCTAssertTrue(timeline.entries.allSatisfy { $0.sample.availability == .value })
            }
        }
    }

    func testSavedAppIntentAccountAndMetricSurvivePersistedLockAndUnlockWithAliases() async throws {
        let suite = "WatchProAccessTests.\(UUID().uuidString)"
        let defaults = isolatedDefaults(suite: suite)
        let savedAccount = "legacy-account"
        let savedMetric = "legacy-account::claude.weekly-scoped-fable5"
        defaults.set(savedAccount, forKey: "fixture.saved-account")
        defaults.set(savedMetric, forKey: "fixture.saved-metric")
        let shared = WatchComplicationSnapshotStore(testDefaults: defaults)
        let accounts = [WatchAccountSnapshot(
            id: "canonical-account", legacyAccountIDs: [savedAccount], providerName: "Claude", accountLabel: "Personal", fetchedAt: base,
            metrics: [WatchMetricSnapshot(id: "claude.weekly-scoped-fable", label: "Fable weekly usage limit", exactValue: "37%")]
        ),
        ]
        for locked in [false, true, false] {
            try shared.saveIfChanged(snapshot(locked: locked, accounts: locked ? [] : accounts))
            let accountQuery = WatchComplicationAccountQuery(loadSnapshot: {
                WatchComplicationSnapshotStore(testDefaults: UserDefaults(suiteName: suite)!).load()
            })
            let metricQuery = WatchComplicationMetricQuery(loadSnapshot: {
                WatchComplicationSnapshotStore(testDefaults: UserDefaults(suiteName: suite)!).load()
            })
            let accountEntities = try await accountQuery.entities(for: [XCTUnwrap(defaults.string(forKey: "fixture.saved-account"))])
            let metricEntities = try await metricQuery.entities(for: [XCTUnwrap(defaults.string(forKey: "fixture.saved-metric"))])
            let account = try XCTUnwrap(accountEntities.first)
            let metric = try XCTUnwrap(metricEntities.first)
            XCTAssertEqual(account.id, savedAccount)
            XCTAssertEqual(metric.id, savedMetric)
            XCTAssertEqual(metric.accountID, savedAccount)
            XCTAssertEqual(metric.metricID, locked ? "claude.weekly-scoped-fable5" : "claude.weekly-scoped-fable")
            XCTAssertEqual(account.providerName, locked ? "Saved Account" : "Claude")
            let intent = WatchComplicationConfigurationIntent()
            intent.account = account
            intent.metric = metric
            let entry = WatchComplicationTimelineLoader(now: { self.base }, loadSnapshot: { shared.load() }).entry(configuration: intent)
            XCTAssertEqual(entry.sample.availability, locked ? .locked : .value)
            if !locked { XCTAssertEqual(entry.sample.exactValue, "37%") }
            XCTAssertEqual(defaults.string(forKey: "fixture.saved-account"), savedAccount)
            XCTAssertEqual(defaults.string(forKey: "fixture.saved-metric"), savedMetric)
        }
    }

    private func snapshot(
        date: Date? = nil,
        locked: Bool = false,
        deadline: Date? = nil,
        sequence: UInt64? = nil,
        fetchedAt: Date? = nil,
        resetsAt: Date? = nil,
        accounts: [WatchAccountSnapshot]? = nil
    ) -> WatchDashboardSnapshot {
        WatchDashboardSnapshot(
            generatedAt: date ?? base, refreshIntervalSeconds: 300,
            accounts: accounts ?? [WatchAccountSnapshot(
                id: "account", providerName: "Codex", accountLabel: "Personal", fetchedAt: fetchedAt ?? base,
                metrics: [WatchMetricSnapshot(id: "usage", label: "5-hour limit", usedFraction: 0.37, exactValue: "37%", resetsAt: resetsAt)]
            ),
            ],
            isProLocked: locked, proAccessEndsAt: deadline, publicationSequence: sequence
        )
    }

    private func isolatedDefaults(suite: String = "WatchProAccessTests.\(UUID().uuidString)") -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    @MainActor
    private func makeStore(
        defaults: UserDefaults,
        shared: WatchComplicationSnapshotStore,
        clock: WatchAccessTestClock,
        reload: @escaping () -> Void = {}
    ) -> WatchDashboardStore {
        WatchDashboardStore(
            defaults: defaults, complicationStore: shared, reloadComplications: reload, session: nil,
            accessTiming: WatchAccessTiming(now: { clock.now }, schedule: { clock.schedule($0, action: $1) }, sample: {
                ProEntitlementClockSample(wallDate: clock.now, continuousSeconds: 0, continuityID: "watch-test-boot")
            })
        )
    }
}

@MainActor
private final class WatchAccessTestClock {
    var now: Date
    private(set) var scheduled: [WatchAccessTestBoundary] = []

    init(now: Date) { self.now = now }

    func schedule(_ deadline: Date, action: @escaping @MainActor @Sendable () -> Void) -> AnyCancellable {
        let boundary = WatchAccessTestBoundary(deadline: deadline, action: action)
        scheduled.append(boundary)
        return AnyCancellable { boundary.isCancelled = true }
    }

    func advance(to date: Date) {
        now = date
        for boundary in scheduled where boundary.deadline <= date && !boundary.isCancelled {
            boundary.action()
        }
    }
}

@MainActor
private final class WatchAccessTestBoundary {
    let deadline: Date
    let action: @MainActor @Sendable () -> Void
    var isCancelled = false

    init(deadline: Date, action: @escaping @MainActor @Sendable () -> Void) {
        self.deadline = deadline
        self.action = action
    }
}

struct WatchControlledClock: Clock {
    typealias Instant = ContinuousClock.Instant
    let probe: WatchSleepProbe
    var now: Instant { probe.now }
    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                probe.register(id: id, deadline: deadline, tolerance: tolerance, continuation: continuation)
            }
        } onCancel: {
            probe.cancel(id: id)
        }
    }
}

// The probe's state and continuations are accessed only while holding lock.
final class WatchSleepProbe: @unchecked Sendable {
    struct Request {
        let deadline: ContinuousClock.Instant
        let tolerance: Duration?
    }
    private struct Waiter {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
    }
    private let lock = NSLock()
    private var instant = ContinuousClock().now
    private var recorded: [Request] = []
    private var waiters: [UUID: Waiter] = [:]
    private var cancelled: Set<UUID> = []
    private let onSleep: @Sendable () -> Void
    private let onRequest: @Sendable (Int) -> Void

    init(onSleep: @escaping @Sendable () -> Void, onRequest: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.onSleep = onSleep
        self.onRequest = onRequest
    }

    var now: ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func advance(by duration: Duration) {
        lock.lock()
        instant = instant.advanced(by: duration)
        let ready = waiters.filter { $0.value.deadline <= instant }
        for id in ready.keys { waiters.removeValue(forKey: id) }
        lock.unlock()
        for waiter in ready.values { waiter.continuation.resume() }
    }

    func register(
        id: UUID, deadline: ContinuousClock.Instant, tolerance: Duration?,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        lock.lock()
        recorded.append(Request(deadline: deadline, tolerance: tolerance))
        let requestCount = recorded.count
        let wasCancelled = cancelled.remove(id) != nil
        let isReady = deadline <= instant
        if !wasCancelled && !isReady { waiters[id] = Waiter(deadline: deadline, continuation: continuation) }
        lock.unlock()
        if requestCount == 1 { onSleep() }
        onRequest(requestCount)
        if wasCancelled { continuation.resume(throwing: CancellationError()) } else if isReady { continuation.resume() }
    }

    func cancel(id: UUID) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        if waiter == nil { cancelled.insert(id) }
        lock.unlock()
        waiter?.continuation.resume(throwing: CancellationError())
    }
}
