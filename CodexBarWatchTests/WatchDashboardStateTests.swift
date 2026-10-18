import XCTest
import WatchConnectivity
@testable import CodexBarWatch

final class WatchDashboardStateTests: XCTestCase {
    func testProductionStartsWithoutDemoUsage() {
        XCTAssertTrue(WatchDashboardState.empty.samples.isEmpty)
        XCTAssertEqual(WatchDashboardState.empty.statusText, "Open CodexBar on iPhone")
    }

    func testBuiltWatchDeclaresLocalSnapshotPreferenceAccess() throws {
        let bundle = Bundle(for: WatchDashboardStore.self)
        let manifestURL = try XCTUnwrap(
            bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
        )
        let data = try Data(contentsOf: manifestURL)
        let manifest = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let accessedAPITypes = try XCTUnwrap(
            manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
        )
        let defaultsEntry = try XCTUnwrap(
            accessedAPITypes.first {
                $0["NSPrivacyAccessedAPIType"] as? String
                    == "NSPrivacyAccessedAPICategoryUserDefaults"
            }
        )
        XCTAssertEqual(
            Set(defaultsEntry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []),
            ["1C8F.1", "CA92.1"]
        )
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertTrue((manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])?.isEmpty == true)
    }

    func testSnapshotPreservesAccountAndMetricOrder() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [
                account(
                    id: "copilot",
                    provider: "Copilot",
                    metricID: "low",
                    fraction: 0.2,
                    generatedAt: now
                ),
                account(
                    id: "codex",
                    provider: "Codex",
                    metricID: "high",
                    fraction: 0.9,
                    generatedAt: now
                ),
            ]
        )

        let state = WatchDashboardState(
            snapshot: snapshot,
            now: now,
            isPhoneReachable: true,
            decodingError: nil
        )

        XCTAssertEqual(state.samples.map(\.id), ["copilot.low", "codex.high"])
        XCTAssertEqual(state.samples.map(\.clampedUsedFraction), [0.2, 0.9])
        XCTAssertEqual(state.statusText, "Updated just now")
    }

    func testRepeatedMetricsShowAccountContextOnceButRemainCoherentForVoiceOver() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [
                WatchAccountSnapshot(
                    id: "claude",
                    providerName: "Claude",
                    accountLabel: "Work",
                    fetchedAt: now,
                    metrics: [
                        WatchMetricSnapshot(
                            id: "session",
                            label: "Current session",
                            usedFraction: 0.2,
                            exactValue: "20%"
                        ),
                        WatchMetricSnapshot(
                            id: "weekly",
                            label: "Weekly",
                            usedFraction: 0.4,
                            exactValue: "40%"
                        ),
                    ]
                ),
            ]
        )

        let state = WatchDashboardState(
            snapshot: snapshot,
            now: now,
            isPhoneReachable: true,
            decodingError: nil
        )

        XCTAssertEqual(state.samples.map(\.showsAccountContext), [true, false])
        XCTAssertTrue(state.samples[0].accessibilitySummary.contains("Claude, Work"))
        XCTAssertTrue(state.samples[1].accessibilitySummary.contains("Claude, Work"))
    }

    func testAccessibilitySummaryIncludesMeaningWithoutColorOrGeometry() {
        let sample = WatchUsageSample(
            id: "codex",
            providerName: "Codex",
            accountLabel: "Primary",
            metricLabel: "5-hour limit",
            exactValue: "137%",
            usedFraction: 1.374,
            severity: .warning,
            resetText: "Resets in 2h",
            visualizationStyle: .semicircularDial,
            freshnessText: "Updated 3m ago"
        )

        XCTAssertEqual(sample.percentageText, "137%")
        XCTAssertEqual(sample.clampedUsedFraction, 1)
        XCTAssertEqual(
            sample.accessibilitySummary,
            "Codex, Primary, 5-hour limit, 137%, Warning, Resets in 2h, Updated 3m ago"
        )
    }

    func testSelfRenderingVisualizationsHideDuplicateHeaderValue() {
        XCTAssertTrue(WatchMetricVisualizationStyle.linearBar.showsHeaderExactValueOnWatch(allowsGauge: true))
        XCTAssertTrue(WatchMetricVisualizationStyle.segmentedBar.showsHeaderExactValueOnWatch(allowsGauge: true))
        XCTAssertTrue(WatchMetricVisualizationStyle.automatic.showsHeaderExactValueOnWatch(allowsGauge: true))
        XCTAssertFalse(WatchMetricVisualizationStyle.circularRing.showsHeaderExactValueOnWatch(allowsGauge: true))
        XCTAssertFalse(WatchMetricVisualizationStyle.semicircularDial.showsHeaderExactValueOnWatch(allowsGauge: true))
        XCTAssertFalse(WatchMetricVisualizationStyle.largeNumeric.showsHeaderExactValueOnWatch(allowsGauge: true))
        XCTAssertTrue(WatchMetricVisualizationStyle.circularRing.showsHeaderExactValueOnWatch(allowsGauge: false))
    }

    func testPayloadRoundTripAndUnknownStyleFallback() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [
                account(
                    id: "codex",
                    provider: "Codex",
                    metricID: "window",
                    fraction: 0.72,
                    generatedAt: now,
                    style: .circularRing,
                    planIdentifier: "codex.pro",
                    planDisplayLabel: "PRO",
                    planAccessibilityLabel: "Pro"
                ),
            ]
        )

        let roundTripped = try WatchDashboardSnapshot.decode(snapshot.encoded())
        XCTAssertEqual(roundTripped, snapshot)
        XCTAssertEqual(roundTripped.accounts[0].planIdentifier, "codex.pro")
        XCTAssertEqual(roundTripped.accounts[0].planDisplayLabel, "PRO")
        XCTAssertEqual(roundTripped.accounts[0].planAccessibilityLabel, "Pro")

        let encoded = try XCTUnwrap(String(data: snapshot.encoded(), encoding: .utf8))
        let futureStyle = encoded.replacingOccurrences(of: "circularRing", with: "futureStyle")
        let decoded = try WatchDashboardSnapshot.decode(Data(futureStyle.utf8))
        XCTAssertEqual(decoded.accounts[0].metrics[0].visualizationStyle, .automatic)
    }

    func testUnsupportedVersionAndMalformedMetricDoNotCrashDecoder() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let unsupported = WatchDashboardSnapshot(
            schemaVersion: 99,
            generatedAt: now,
            refreshIntervalSeconds: nil,
            accounts: []
        )
        XCTAssertThrowsError(try WatchDashboardSnapshot.decode(unsupported.encoded())) { error in
            XCTAssertEqual(error as? WatchDashboardPayloadError, .unsupportedSchemaVersion(99))
        }

        let partialJSON = """
        {
          "schemaVersion": 1,
          "generatedAt": 2000000000000,
          "futureDashboardLayout": "constellation",
          "accounts": [{
            "id": "codex",
            "providerName": "Codex",
            "accountLabel": "Primary",
            "fetchedAt": 2000000000000,
            "metrics": [
              {
                "id":"valid",
                "label":"Usage",
                "exactValue":"42%",
                "usedFraction":0.42,
                "futureTileWidth":"quarter"
              },
              {"label":"Missing required identity"}
            ]
          }]
        }
        """
        let decoded = try WatchDashboardSnapshot.decode(Data(partialJSON.utf8))
        XCTAssertEqual(decoded.accounts[0].metrics.map(\.id), ["valid"])
        XCTAssertEqual(decoded.accounts[0].metrics[0].visualizationStyle, .automatic)
        XCTAssertNil(decoded.accounts[0].metrics[0].fetchedAt)
        XCTAssertNil(decoded.accounts[0].metrics[0].resetsAt)
        XCTAssertNil(decoded.accounts[0].metrics[0].resetDisplayStyle)
    }

    func testStaleAndDisconnectedStatesKeepLastSnapshotVisible() {
        let generatedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: generatedAt,
            refreshIntervalSeconds: 60,
            accounts: [
                account(
                    id: "codex",
                    provider: "Codex",
                    metricID: "window",
                    fraction: 0.5,
                    generatedAt: generatedAt
                ),
            ]
        )

        let disconnected = WatchDashboardState(
            snapshot: snapshot,
            now: generatedAt.addingTimeInterval(120),
            isPhoneReachable: false,
            decodingError: nil
        )
        XCTAssertEqual(disconnected.samples.count, 1)
        XCTAssertTrue(disconnected.statusText.contains("iPhone unavailable"))

        let stale = WatchDashboardState(
            snapshot: snapshot,
            now: generatedAt.addingTimeInterval(901),
            isPhoneReachable: true,
            decodingError: nil
        )
        XCTAssertEqual(stale.samples.count, 1)
        XCTAssertTrue(stale.statusText.contains("Stale"))
    }

    func testFreshnessUsesOldestDisplayedProviderFetchInsteadOfDeliveryTime() {
        let generatedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let oldFetch = generatedAt.addingTimeInterval(-1_800)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: generatedAt,
            refreshIntervalSeconds: 60,
            accounts: [
                account(
                    id: "codex",
                    provider: "Codex",
                    metricID: "window",
                    fraction: 0.5,
                    generatedAt: oldFetch
                ),
            ]
        )

        let state = WatchDashboardState(
            snapshot: snapshot,
            now: generatedAt,
            isPhoneReachable: true,
            decodingError: nil
        )

        XCTAssertEqual(state.statusText, "Updated 30m ago • Stale")
        XCTAssertTrue(state.samples[0].accessibilitySummary.contains("Updated 30m ago"))
    }

    func testEmptyDashboardPreservesProviderStatusText() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [
                WatchAccountSnapshot(
                    id: "claude",
                    providerName: "Claude",
                    accountLabel: "Primary",
                    statusText: "Refresh failed; showing no cached usage",
                    fetchedAt: now,
                    metrics: []
                ),
            ]
        )

        let state = WatchDashboardState(
            snapshot: snapshot,
            now: now,
            isPhoneReachable: true,
            decodingError: nil
        )

        XCTAssertTrue(state.samples.isEmpty)
        XCTAssertEqual(state.statusText, "Claude: Refresh failed; showing no cached usage")
    }

    @MainActor
    func testMalformedUpdatePreservesPersistedLastGoodSnapshot() throws {
        let suiteName = "WatchDashboardStateTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = WatchDashboardStore(
            defaults: defaults,
            complicationStore: WatchComplicationSnapshotStore(testDefaults: defaults),
            reloadComplications: {},
            session: nil
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [
                account(
                    id: "codex",
                    provider: "Codex",
                    metricID: "window",
                    fraction: 0.5,
                    generatedAt: now
                ),
            ]
        )

        store.receive(try snapshot.applicationContext())
        store.receive([WatchDashboardSnapshot.applicationContextDataKey: Data("bad".utf8)])

        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertNotNil(store.decodingError)
        let reloaded = WatchDashboardStore(
            defaults: defaults,
            complicationStore: WatchComplicationSnapshotStore(testDefaults: defaults),
            reloadComplications: {},
            session: nil
        )
        XCTAssertEqual(reloaded.snapshot, snapshot)
    }

    @MainActor
    func testActivationConsumesContextDeliveredBeforeFirstWatchLaunch() throws {
        let suiteName = "WatchDashboardStateTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = WatchDashboardStore(
            defaults: defaults,
            complicationStore: WatchComplicationSnapshotStore(testDefaults: defaults),
            reloadComplications: {},
            session: nil
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [
                account(
                    id: "codex",
                    provider: "Codex",
                    metricID: "window",
                    fraction: 0.5,
                    generatedAt: now
                ),
            ]
        )

        store.activationCompleted(
            activationState: .activated,
            applicationContext: WatchDashboardApplicationContext(
                try snapshot.applicationContext()
            ),
            isPhoneReachable: false,
            hadError: false
        )

        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertFalse(store.isPhoneReachable)
        XCTAssertNil(store.decodingError)
    }

    @MainActor
    func testActivationAndNewReachabilityCoalesceCurrentIPhoneSnapshotRequests() async throws {
        let suiteName = "WatchDashboardStateTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        var requestCount = 0
        let store = WatchDashboardStore(
            defaults: defaults,
            complicationStore: WatchComplicationSnapshotStore(testDefaults: defaults),
            reloadComplications: {},
            session: nil,
            requestSnapshot: { _, _ in
                requestCount += 1
            },
            requestCoalescingDelay: .milliseconds(5)
        )

        store.activationCompleted(
            activationState: .activated,
            applicationContext: .empty,
            isPhoneReachable: false,
            hadError: false
        )
        store.updateReachability(true)
        store.updateReachability(true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(requestCount, 1)

        store.updateReachability(false)
        store.updateReachability(true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(requestCount, 2)
    }

    func testApplicationContextHandoffCopiesOnlySendableSnapshotData() throws {
        let snapshot = WatchDashboardSnapshot(
            generatedAt: Date(timeIntervalSince1970: 2_000_000_000),
            refreshIntervalSeconds: 300,
            accounts: []
        )

        let valid = WatchDashboardApplicationContext(try snapshot.applicationContext())
        XCTAssertEqual(try valid.decode(), snapshot)
        XCTAssertFalse(valid.isEmpty)

        let malformed = WatchDashboardApplicationContext(["unexpected": NSObject()])
        XCTAssertThrowsError(try malformed.decode())
        XCTAssertFalse(malformed.isEmpty)

        let empty = WatchDashboardApplicationContext([:])
        XCTAssertThrowsError(try empty.decode())
        XCTAssertTrue(empty.isEmpty)
    }

    func testSnapshotResponseDistinguishesValidUnavailableAndMalformedReplies() throws {
        let snapshot = WatchDashboardSnapshot(
            generatedAt: Date(timeIntervalSince1970: 2_000_000_000),
            refreshIntervalSeconds: 300,
            accounts: []
        )

        let valid = WatchDashboardSnapshotResponse(try snapshot.applicationContext())
        XCTAssertEqual(try valid.decode(), snapshot)
        XCTAssertEqual(
            WatchDashboardSnapshotResponse(
                WatchDashboardSnapshot.snapshotUnavailableReply
            ),
            .unavailable
        )
        XCTAssertEqual(WatchDashboardSnapshotResponse([:]), .malformed)
        XCTAssertThrowsError(
            try WatchDashboardSnapshotResponse.unavailable.decode()
        )
    }

    @MainActor
    func testInactiveActivationWaitsAndShowsRecoveryUntilSessionActivates() async throws {
        let suiteName = "WatchDashboardStateTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        var requestCount = 0
        let store = WatchDashboardStore(
            defaults: defaults,
            complicationStore: WatchComplicationSnapshotStore(testDefaults: defaults),
            reloadComplications: {},
            session: nil,
            requestSnapshot: { _, _ in requestCount += 1 },
            queueSnapshotRequest: {},
            initialActivationState: .notActivated,
            requestCoalescingDelay: .milliseconds(5)
        )

        store.activationCompleted(
            activationState: .notActivated,
            applicationContext: .empty,
            isPhoneReachable: false,
            hadError: true
        )
        store.requestCurrentSnapshot()
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(
            store.decodingError,
            "Connecting to iPhone. Keep CodexBar open on both devices"
        )

        store.activationCompleted(
            activationState: .activated,
            applicationContext: .empty,
            isPhoneReachable: true,
            hadError: false
        )
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testImmediateSnapshotReplyPersistsAndReloadsComplication() throws {
        let suiteName = "WatchDashboardStateTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [
                account(
                    id: "codex",
                    provider: "Codex",
                    metricID: "window",
                    fraction: 0.5,
                    generatedAt: now
                ),
            ]
        )
        let response = WatchDashboardSnapshotResponse.snapshot(try snapshot.encoded())
        var reloadCount = 0
        let store = WatchDashboardStore(
            defaults: defaults,
            complicationStore: WatchComplicationSnapshotStore(testDefaults: defaults),
            reloadComplications: { reloadCount += 1 },
            session: nil,
            requestSnapshot: { replyHandler, _ in replyHandler(response) },
            queueSnapshotRequest: {}
        )
        store.updateReachability(true)

        store.requestCurrentSnapshot()

        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertNil(store.decodingError)
        XCTAssertEqual(reloadCount, 1)
    }

    @MainActor
    func testOlderImmediateReplyCannotReplaceNewerApplicationContext() throws {
        let suiteName = "WatchDashboardStateTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let complicationStore = WatchComplicationSnapshotStore(testDefaults: defaults)
        let older = WatchDashboardSnapshot(
            generatedAt: Date(timeIntervalSince1970: 2_000_000_000),
            refreshIntervalSeconds: 300,
            accounts: []
        )
        let newer = WatchDashboardSnapshot(
            generatedAt: Date(timeIntervalSince1970: 2_000_000_100),
            refreshIntervalSeconds: 300,
            accounts: []
        )
        var replyHandler: (@MainActor (WatchDashboardSnapshotResponse) -> Void)?
        var reloadCount = 0
        let store = WatchDashboardStore(
            defaults: defaults,
            complicationStore: complicationStore,
            reloadComplications: { reloadCount += 1 },
            session: nil,
            requestSnapshot: { handler, _ in replyHandler = handler },
            queueSnapshotRequest: {}
        )
        store.updateReachability(true)
        store.requestCurrentSnapshot()

        store.receive(try newer.applicationContext())
        replyHandler?(.snapshot(try older.encoded()))

        XCTAssertEqual(store.snapshot, newer)
        XCTAssertEqual(complicationStore.load(), newer)
        XCTAssertEqual(reloadCount, 1)
        XCTAssertNil(store.decodingError)
    }

    @MainActor
    func testNewerContextInvalidatesPendingFailureAndUnavailableCallbacks() throws {
        let suiteName = "WatchDashboardStateTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let newer = WatchDashboardSnapshot(
            generatedAt: Date(timeIntervalSince1970: 2_000_000_100),
            refreshIntervalSeconds: 300,
            accounts: []
        )
        var replyHandler: (@MainActor (WatchDashboardSnapshotResponse) -> Void)?
        var errorHandler: (@MainActor (WatchSnapshotRequestFailure) -> Void)?
        var queuedRequestCount = 0
        let store = WatchDashboardStore(
            defaults: defaults,
            complicationStore: WatchComplicationSnapshotStore(testDefaults: defaults),
            reloadComplications: {},
            session: nil,
            requestSnapshot: { reply, failure in
                replyHandler = reply
                errorHandler = failure
            },
            queueSnapshotRequest: { queuedRequestCount += 1 }
        )
        store.updateReachability(true)
        store.requestCurrentSnapshot()

        store.receive(try newer.applicationContext())
        errorHandler?(.timedOut)
        replyHandler?(.unavailable)

        XCTAssertEqual(store.snapshot, newer)
        XCTAssertNil(store.decodingError)
        XCTAssertEqual(queuedRequestCount, 0)
    }

    @MainActor
    func testLaterSuccessfulRequestInvalidatesEarlierFailure() throws {
        let suiteName = "WatchDashboardStateTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let latest = WatchDashboardSnapshot(
            generatedAt: Date(timeIntervalSince1970: 2_000_000_100),
            refreshIntervalSeconds: 300,
            accounts: []
        )
        var replyHandlers: [(@MainActor (WatchDashboardSnapshotResponse) -> Void)] = []
        var errorHandlers: [(@MainActor (WatchSnapshotRequestFailure) -> Void)] = []
        var queuedRequestCount = 0
        let store = WatchDashboardStore(
            defaults: defaults,
            complicationStore: WatchComplicationSnapshotStore(testDefaults: defaults),
            reloadComplications: {},
            session: nil,
            requestSnapshot: { reply, failure in
                replyHandlers.append(reply)
                errorHandlers.append(failure)
            },
            queueSnapshotRequest: { queuedRequestCount += 1 }
        )
        store.updateReachability(true)

        store.requestCurrentSnapshot()
        store.requestCurrentSnapshot()
        replyHandlers[1](.snapshot(try latest.encoded()))
        errorHandlers[0](.deliveryFailed)

        XCTAssertEqual(store.snapshot, latest)
        XCTAssertNil(store.decodingError)
        XCTAssertEqual(queuedRequestCount, 0)
    }

    @MainActor
    func testUnreachablePhoneQueuesRequestWithActionableRecovery() throws {
        let suiteName = "WatchDashboardStateTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        var immediateRequestCount = 0
        var queuedRequestCount = 0
        let store = WatchDashboardStore(
            defaults: defaults,
            complicationStore: WatchComplicationSnapshotStore(testDefaults: defaults),
            reloadComplications: {},
            session: nil,
            requestSnapshot: { _, _ in immediateRequestCount += 1 },
            queueSnapshotRequest: { queuedRequestCount += 1 }
        )

        store.requestCurrentSnapshot()
        store.requestCurrentSnapshot()

        XCTAssertEqual(immediateRequestCount, 0)
        XCTAssertEqual(queuedRequestCount, 1)
        XCTAssertEqual(
            store.decodingError,
            "iPhone unavailable. Open CodexBar there; update queued"
        )
    }

    @MainActor
    func testFailedQueuedTransferAllowsLaterRetry() throws {
        let suiteName = "WatchDashboardStateTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        var queuedRequestCount = 0
        let store = WatchDashboardStore(
            defaults: defaults,
            complicationStore: WatchComplicationSnapshotStore(testDefaults: defaults),
            reloadComplications: {},
            session: nil,
            requestSnapshot: { _, _ in },
            queueSnapshotRequest: { queuedRequestCount += 1 }
        )

        store.requestCurrentSnapshot()
        XCTAssertEqual(queuedRequestCount, 1)

        store.receiveDelegateEvent(
            .userInfoTransferFinished(
                sequence: 0,
                wasSnapshotRequest: true,
                failed: true,
                hasOtherOutstandingSnapshotRequest: false
            )
        )
        store.requestCurrentSnapshot()

        XCTAssertEqual(queuedRequestCount, 2)
    }

    @MainActor
    func testSuccessfulQueuedTransferWithoutResponseAllowsLaterRetry() throws {
        let suiteName = "WatchDashboardStateTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        var queuedRequestCount = 0
        let store = WatchDashboardStore(
            defaults: defaults,
            complicationStore: WatchComplicationSnapshotStore(testDefaults: defaults),
            reloadComplications: {},
            session: nil,
            requestSnapshot: { _, _ in },
            queueSnapshotRequest: { queuedRequestCount += 1 }
        )

        store.requestCurrentSnapshot()
        XCTAssertEqual(queuedRequestCount, 1)

        store.receiveDelegateEvent(
            .userInfoTransferFinished(
                sequence: 0,
                wasSnapshotRequest: true,
                failed: false,
                hasOtherOutstandingSnapshotRequest: false
            )
        )
        store.requestCurrentSnapshot()

        XCTAssertEqual(queuedRequestCount, 2)
    }

    @MainActor
    func testCachedContextPreservesOutstandingQueuedRequestAcrossRelaunch() throws {
        let suiteName = "WatchDashboardStateTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: Date(timeIntervalSince1970: 2_000_000_000),
            refreshIntervalSeconds: 300,
            accounts: []
        )
        var queuedRequestCount = 0
        var transferIsOutstanding = true
        let store = WatchDashboardStore(
            defaults: defaults,
            complicationStore: WatchComplicationSnapshotStore(testDefaults: defaults),
            reloadComplications: {},
            session: nil,
            requestSnapshot: { _, _ in },
            queueSnapshotRequest: { queuedRequestCount += 1 },
            hasOutstandingSnapshotRequest: { transferIsOutstanding }
        )

        store.receive(try snapshot.applicationContext())
        store.requestCurrentSnapshot()
        XCTAssertEqual(queuedRequestCount, 0)

        transferIsOutstanding = false
        store.receive(try snapshot.applicationContext())
        store.requestCurrentSnapshot()
        XCTAssertEqual(queuedRequestCount, 1)
    }

    @MainActor
    func testUnavailableAndMalformedImmediateRepliesExplainRecovery() throws {
        let suiteName = "WatchDashboardStateTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        var replyHandler: (@MainActor (WatchDashboardSnapshotResponse) -> Void)?
        let store = WatchDashboardStore(
            defaults: defaults,
            complicationStore: WatchComplicationSnapshotStore(testDefaults: defaults),
            reloadComplications: {},
            session: nil,
            requestSnapshot: { handler, _ in replyHandler = handler },
            queueSnapshotRequest: {}
        )
        store.updateReachability(true)

        store.requestCurrentSnapshot()
        replyHandler?(.unavailable)
        XCTAssertEqual(
            store.decodingError,
            "No dashboard update is available yet. Refresh CodexBar on iPhone"
        )

        store.requestCurrentSnapshot()
        replyHandler?(.malformed)
        XCTAssertEqual(
            store.decodingError,
            "Couldn’t read the iPhone update. Refresh CodexBar on iPhone"
        )
    }

    func testWatchConnectivityErrorsMapToSpecificRecoveryReasons() {
        func error(_ code: WCError.Code) -> NSError {
            NSError(domain: WCErrorDomain, code: code.rawValue)
        }

        XCTAssertEqual(
            WatchSnapshotRequestFailure(error(.sessionNotActivated)),
            .sessionInactive
        )
        XCTAssertEqual(
            WatchSnapshotRequestFailure(error(.notReachable)),
            .phoneUnreachable
        )
        XCTAssertEqual(
            WatchSnapshotRequestFailure(error(.messageReplyTimedOut)),
            .timedOut
        )
        XCTAssertEqual(
            WatchSnapshotRequestFailure(error(.deviceNotPaired)),
            .pairingUnavailable
        )
        XCTAssertEqual(
            WatchSnapshotRequestFailure(error(.companionAppNotInstalled)),
            .pairingUnavailable
        )
        XCTAssertEqual(
            WatchSnapshotRequestFailure(error(.watchAppNotInstalled)),
            .pairingUnavailable
        )
        XCTAssertEqual(
            WatchSnapshotRequestFailure(
                NSError(domain: NSCocoaErrorDomain, code: 1)
            ),
            .deliveryFailed
        )
    }

    @MainActor
    func testPairingFailureExplainsRecoveryWithoutQueueingImpossibleTransfer() throws {
        let suiteName = "WatchDashboardStateTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        var queuedRequestCount = 0
        let store = WatchDashboardStore(
            defaults: defaults,
            complicationStore: WatchComplicationSnapshotStore(testDefaults: defaults),
            reloadComplications: {},
            session: nil,
            requestSnapshot: { _, errorHandler in
                errorHandler(.pairingUnavailable)
            },
            queueSnapshotRequest: { queuedRequestCount += 1 }
        )
        store.updateReachability(true)

        store.requestCurrentSnapshot()

        XCTAssertEqual(queuedRequestCount, 0)
        XCTAssertEqual(
            store.decodingError,
            "Install and open CodexBar on the paired iPhone"
        )
    }

    @MainActor
    func testDelegateCallbacksEnqueueTypedApplicationContext() async throws {
        let suiteName = "WatchDashboardStateTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let latestSnapshot = WatchDashboardSnapshot(
            generatedAt: Date(timeIntervalSince1970: 2_000_000_000),
            refreshIntervalSeconds: 300,
            accounts: []
        )
        let store = WatchDashboardStore(
            defaults: defaults,
            complicationStore: WatchComplicationSnapshotStore(testDefaults: defaults),
            reloadComplications: {},
            session: nil
        )

        let callbackSession = WCSession.default
        store.session(
            callbackSession,
            activationDidCompleteWith: .activated,
            error: nil
        )
        store.session(
            callbackSession,
            didReceiveApplicationContext: try latestSnapshot.applicationContext()
        )
        store.sessionReachabilityDidChange(callbackSession)
        await Task.yield()

        XCTAssertEqual(store.snapshot, latestSnapshot)
        XCTAssertEqual(store.isPhoneReachable, callbackSession.isReachable)
    }

    @MainActor
    func testOutOfOrderHandoffsPreserveRapidReconnectTransition() async throws {
        let suiteName = "WatchDashboardStateTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        var requestCount = 0
        let store = WatchDashboardStore(
            defaults: defaults,
            complicationStore: WatchComplicationSnapshotStore(testDefaults: defaults),
            reloadComplications: {},
            session: nil,
            requestSnapshot: { _, _ in
                requestCount += 1
            },
            requestCoalescingDelay: .milliseconds(5)
        )
        store.activationCompleted(
            activationState: .activated,
            applicationContext: .empty,
            isPhoneReachable: true,
            hadError: false
        )
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(requestCount, 1)

        store.receiveDelegateEvent(.reachability(sequence: 1, isPhoneReachable: true))
        XCTAssertTrue(store.isPhoneReachable)
        store.receiveDelegateEvent(.reachability(sequence: 0, isPhoneReachable: false))
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertTrue(store.isPhoneReachable)
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor
    func testPendingSnapshotRequestDoesNotRetainReleasedStore() async throws {
        let suiteName = "WatchDashboardStateTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        var requestCount = 0
        var store: WatchDashboardStore? = WatchDashboardStore(
            defaults: defaults,
            complicationStore: WatchComplicationSnapshotStore(testDefaults: defaults),
            reloadComplications: {},
            session: nil,
            requestSnapshot: { _, _ in
                requestCount += 1
            },
            requestCoalescingDelay: .milliseconds(5)
        )
        weak let releasedStore = store

        store?.scheduleCurrentSnapshotRequest()
        store = nil

        XCTAssertNil(releasedStore)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(requestCount, 0)
    }

    @MainActor
    func testSnapshotRequestFailurePreservesLastGoodDataAndAlwaysExplainsQueuedRecovery() async throws {
        let suiteName = "WatchDashboardStateTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        var requestErrorHandler: ((WatchSnapshotRequestFailure) -> Void)?
        let store = WatchDashboardStore(
            defaults: defaults,
            complicationStore: WatchComplicationSnapshotStore(testDefaults: defaults),
            reloadComplications: {},
            session: nil,
            requestSnapshot: { _, errorHandler in
                requestErrorHandler = errorHandler
            },
            queueSnapshotRequest: {}
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [
                account(
                    id: "codex",
                    provider: "Codex",
                    metricID: "window",
                    fraction: 0.5,
                    generatedAt: now
                ),
            ]
        )
        store.receive(try snapshot.applicationContext())
        store.updateReachability(true)
        store.requestCurrentSnapshot()
        requestErrorHandler?(.deliveryFailed)
        await Task.yield()

        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertEqual(
            store.decodingError,
            "Update queued. Open CodexBar on iPhone to finish"
        )

        let emptyDefaults = try XCTUnwrap(UserDefaults(suiteName: "\(suiteName).empty"))
        emptyDefaults.removePersistentDomain(forName: "\(suiteName).empty")
        var emptyRequestErrorHandler: ((WatchSnapshotRequestFailure) -> Void)?
        let emptyStore = WatchDashboardStore(
            defaults: emptyDefaults,
            complicationStore: WatchComplicationSnapshotStore(testDefaults: emptyDefaults),
            reloadComplications: {},
            session: nil,
            requestSnapshot: { _, errorHandler in
                emptyRequestErrorHandler = errorHandler
            },
            queueSnapshotRequest: {}
        )
        emptyStore.updateReachability(true)
        emptyStore.requestCurrentSnapshot()
        emptyRequestErrorHandler?(.deliveryFailed)
        await Task.yield()

        XCTAssertNil(emptyStore.snapshot)
        XCTAssertEqual(
            emptyStore.decodingError,
            "Update queued. Open CodexBar on iPhone to finish"
        )
    }

    @MainActor
    func testLegacySnapshotMigrationReloadsComplicationTimeline() throws {
        let suiteName = "WatchDashboardStateTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let complicationStore = WatchComplicationSnapshotStore(testDefaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [
                account(
                    id: "codex",
                    provider: "Codex",
                    metricID: "window",
                    fraction: 0.5,
                    generatedAt: now
                ),
            ]
        )
        defaults.set(try snapshot.encoded(), forKey: "watch.dashboard.last-good-snapshot")
        var reloadCount = 0

        let store = WatchDashboardStore(
            defaults: defaults,
            complicationStore: complicationStore,
            reloadComplications: { reloadCount += 1 },
            session: nil
        )

        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertEqual(complicationStore.load(), snapshot)
        XCTAssertEqual(reloadCount, 1)
    }

    @MainActor
    func testNewerSharedSnapshotIsNotRolledBackByLegacyDefaults() throws {
        let suiteName = "WatchDashboardStateTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let complicationStore = WatchComplicationSnapshotStore(testDefaults: defaults)
        let oldDate = Date(timeIntervalSince1970: 2_000_000_000)
        let oldSnapshot = WatchDashboardSnapshot(
            generatedAt: oldDate,
            refreshIntervalSeconds: 300,
            accounts: [
                account(
                    id: "codex",
                    provider: "Codex",
                    metricID: "window",
                    fraction: 0.25,
                    generatedAt: oldDate
                ),
            ]
        )
        let newDate = oldDate.addingTimeInterval(60)
        let newSnapshot = WatchDashboardSnapshot(
            generatedAt: newDate,
            refreshIntervalSeconds: 300,
            accounts: [
                account(
                    id: "codex",
                    provider: "Codex",
                    metricID: "window",
                    fraction: 0.75,
                    generatedAt: newDate
                ),
            ]
        )
        defaults.set(try oldSnapshot.encoded(), forKey: "watch.dashboard.last-good-snapshot")
        try complicationStore.saveIfChanged(newSnapshot)
        var reloadCount = 0

        let store = WatchDashboardStore(
            defaults: defaults,
            complicationStore: complicationStore,
            reloadComplications: { reloadCount += 1 },
            session: nil
        )

        XCTAssertEqual(store.snapshot, newSnapshot)
        XCTAssertEqual(complicationStore.load(), newSnapshot)
        XCTAssertEqual(reloadCount, 0)
        let reconciledData = try XCTUnwrap(
            defaults.data(forKey: "watch.dashboard.last-good-snapshot")
        )
        XCTAssertEqual(try WatchDashboardSnapshot.decode(reconciledData), newSnapshot)
    }

    @MainActor
    func testChangedConnectivityPayloadPersistsForComplicationAndReloadsOnce() throws {
        let suiteName = "WatchDashboardStateTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let complicationStore = WatchComplicationSnapshotStore(testDefaults: defaults)
        var reloadCount = 0
        let store = WatchDashboardStore(
            defaults: defaults,
            complicationStore: complicationStore,
            reloadComplications: { reloadCount += 1 },
            session: nil
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [
                account(
                    id: "codex",
                    provider: "Codex",
                    metricID: "window",
                    fraction: 0.5,
                    generatedAt: now
                ),
            ]
        )

        store.receive(try snapshot.applicationContext())
        store.receive(try snapshot.applicationContext())

        XCTAssertEqual(complicationStore.load(), snapshot)
        XCTAssertEqual(reloadCount, 1)

        let changed = WatchDashboardSnapshot(
            generatedAt: now.addingTimeInterval(60),
            refreshIntervalSeconds: 300,
            accounts: [
                account(
                    id: "codex",
                    provider: "Codex",
                    metricID: "window",
                    fraction: 0.75,
                    generatedAt: now.addingTimeInterval(60)
                ),
            ]
        )
        store.receive(try changed.applicationContext())

        XCTAssertEqual(complicationStore.load(), changed)
        XCTAssertEqual(reloadCount, 2)
    }

    func testComplicationResolverHonorsAccountAndMetricConfiguration() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [
                account(
                    id: "codex",
                    provider: "Codex",
                    metricID: "window",
                    fraction: 0.25,
                    generatedAt: now
                ),
                account(
                    id: "copilot",
                    provider: "Copilot",
                    metricID: "requests",
                    fraction: 0.8,
                    generatedAt: now
                ),
            ]
        )
        let resolver = WatchComplicationResolver()

        let configured = resolver.resolve(
            snapshot: snapshot,
            selection: WatchComplicationSelection(
                accountID: "copilot",
                metricID: "requests"
            ),
            at: now
        )
        let missing = resolver.resolve(
            snapshot: snapshot,
            selection: WatchComplicationSelection(
                accountID: "copilot",
                metricID: "missing"
            ),
            at: now
        )

        XCTAssertEqual(configured.availability, .value)
        XCTAssertEqual(configured.providerName, "Copilot")
        XCTAssertEqual(configured.exactValue, "80%")
        XCTAssertEqual(missing, .unavailable)
        XCTAssertEqual(missing.cornerContextLabel, "Selection unavailable")
        XCTAssertNil(missing.stateLabel)
        XCTAssertFalse(missing.accessibilityLabel.contains("Warning"))
    }

    func testMetricOnlyComplicationConfigurationPreservesItsAccount() {
        XCTAssertEqual(
            WatchComplicationSelection.resolving(
                accountID: nil,
                metricAccountID: "copilot",
                metricID: "requests"
            ),
            WatchComplicationSelection(accountID: "copilot", metricID: "requests")
        )
        XCTAssertEqual(
            WatchComplicationSelection.resolving(
                accountID: "codex",
                metricAccountID: "copilot",
                metricID: "requests"
            ),
            WatchComplicationSelection(accountID: "codex", metricID: nil)
        )
    }

    func testSavedComplicationChoicesSurviveTransientSnapshotChanges() {
        let accountID = "codex.stable"
        let metricID = "codex.window"
        let savedMetricID = WatchComplicationChoiceCatalog.metricChoiceID(
            accountID: accountID,
            metricID: metricID
        )
        let emptyCatalog = WatchComplicationChoiceCatalog(snapshot: nil)

        let savedAccount = emptyCatalog.accounts(for: [accountID])[0]
        let savedMetric = emptyCatalog.metrics(for: [savedMetricID])[0]

        XCTAssertEqual(savedAccount.id, accountID)
        XCTAssertEqual(savedMetric.id, savedMetricID)
        XCTAssertEqual(savedMetric.accountID, accountID)
        XCTAssertEqual(savedMetric.metricID, metricID)
    }

    func testMetricChoicesIncludeAccountContext() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [
                WatchAccountSnapshot(
                    id: "codex.work",
                    providerName: "ChatGPT / Codex",
                    accountLabel: "Work",
                    fetchedAt: now,
                    metrics: [
                        WatchMetricSnapshot(
                            id: "window",
                            label: "5-hour limit",
                            usedFraction: 0.5,
                            exactValue: "50%"
                        ),
                    ]
                ),
            ]
        )

        let choice = WatchComplicationChoiceCatalog(snapshot: snapshot).metrics[0]

        XCTAssertEqual(choice.subtitle, "ChatGPT / Codex • Work")
    }

    func testComplicationResolutionDistinguishesEmptyStaleWarningAndCriticalStates() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let resolver = WatchComplicationResolver()
        XCTAssertEqual(
            resolver.resolve(snapshot: nil, selection: .automatic, at: now).availability,
            .empty
        )

        for severity in [WatchMetricSeverity.warning, .critical] {
            let account = WatchAccountSnapshot(
                id: severity.rawValue,
                providerName: "Codex",
                accountLabel: "Primary",
                fetchedAt: now.addingTimeInterval(-901),
                metrics: [
                    WatchMetricSnapshot(
                        id: "usage",
                        label: "Usage",
                        usedFraction: 0.9,
                        exactValue: "90%",
                        severity: severity
                    ),
                ]
            )
            let sample = resolver.resolve(
                snapshot: WatchDashboardSnapshot(
                    generatedAt: now,
                    refreshIntervalSeconds: 60,
                    accounts: [account]
                ),
                selection: .automatic,
                at: now
            )

            XCTAssertTrue(sample.isStale)
            XCTAssertTrue(sample.stateLabel?.contains("Stale") == true)
            XCTAssertTrue(sample.stateLabel?.contains(
                severity == .warning ? "Warning" : "Critical"
            ) == true)
            XCTAssertTrue(sample.accessibilityLabel.contains("Stale"))
        }
    }

    func testExplicitSelectionRemainsUnavailableWhenAllAccountsAreEmpty() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [
                WatchAccountSnapshot(
                    id: "codex",
                    providerName: "Codex",
                    accountLabel: "Primary",
                    fetchedAt: now,
                    metrics: []
                ),
            ]
        )
        let resolver = WatchComplicationResolver()

        XCTAssertEqual(
            resolver.resolve(snapshot: snapshot, selection: .automatic, at: now),
            .empty
        )
        XCTAssertEqual(
            resolver.resolve(
                snapshot: snapshot,
                selection: WatchComplicationSelection(
                    accountID: "codex",
                    metricID: "usage"
                ),
                at: now
            ),
            .unavailable
        )
    }

    func testComplicationTimelineRefreshesAtStaleBoundaryThenConservatively() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [
                account(
                    id: "codex",
                    provider: "Codex",
                    metricID: "window",
                    fraction: 0.5,
                    generatedAt: now
                ),
            ]
        )
        let resolver = WatchComplicationResolver()

        XCTAssertEqual(
            resolver.nextReloadDate(snapshot: snapshot, selection: .automatic, now: now),
            now.addingTimeInterval(901)
        )
        XCTAssertEqual(
            resolver.timelineEntryDates(
                snapshot: snapshot,
                selection: .automatic,
                now: now
            ),
            [now]
                + (1...15).map { now.addingTimeInterval(TimeInterval($0 * 60)) }
                + [now.addingTimeInterval(901)]
        )
        XCTAssertEqual(
            resolver.nextReloadDate(
                snapshot: snapshot,
                selection: .automatic,
                now: now.addingTimeInterval(902)
            ),
            now.addingTimeInterval(1_802)
        )
    }

    func testComplicationTimelineUsesDisplayedNonemptyAccount() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let populatedFetchedAt = now.addingTimeInterval(-300)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [
                WatchAccountSnapshot(
                    id: "empty",
                    providerName: "Empty",
                    accountLabel: "Primary",
                    fetchedAt: now,
                    metrics: []
                ),
                account(
                    id: "codex",
                    provider: "Codex",
                    metricID: "window",
                    fraction: 0.5,
                    generatedAt: populatedFetchedAt
                ),
            ]
        )

        XCTAssertEqual(
            WatchComplicationResolver().nextReloadDate(
                snapshot: snapshot,
                selection: .automatic,
                now: now
            ),
            now.addingTimeInterval(601)
        )
    }

    func testComplicationFreshnessTracksSelectedMetric() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let staleFetchedAt = now.addingTimeInterval(-3_600)
        let account = WatchAccountSnapshot(
            id: "claude",
            providerName: "Claude",
            accountLabel: "Primary",
            fetchedAt: staleFetchedAt,
            metrics: [
                WatchMetricSnapshot(
                    id: "usage",
                    label: "Usage",
                    usedFraction: 0.5,
                    exactValue: "50%",
                    fetchedAt: staleFetchedAt
                ),
                WatchMetricSnapshot(
                    id: "balance",
                    label: "Balance",
                    exactValue: "$20.00",
                    fetchedAt: now,
                    visualizationStyle: .largeNumeric
                ),
            ]
        )
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [account]
        )
        let resolver = WatchComplicationResolver()
        let usage = resolver.resolve(
            snapshot: snapshot,
            selection: WatchComplicationSelection(accountID: "claude", metricID: "usage"),
            at: now
        )
        let balanceSelection = WatchComplicationSelection(
            accountID: "claude",
            metricID: "balance"
        )
        let balance = resolver.resolve(
            snapshot: snapshot,
            selection: balanceSelection,
            at: now
        )

        XCTAssertTrue(usage.isStale)
        XCTAssertEqual(usage.freshnessText, "Updated 1h ago")
        XCTAssertFalse(balance.isStale)
        XCTAssertEqual(balance.freshnessText, "Updated now")
        XCTAssertEqual(
            resolver.nextReloadDate(
                snapshot: snapshot,
                selection: balanceSelection,
                now: now
            ),
            now.addingTimeInterval(901)
        )
    }

    func testComplicationResetTextRecomputesForTimelineDate() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let metric = WatchMetricSnapshot(
            id: "usage",
            label: "Usage",
            usedFraction: 0.5,
            exactValue: "50%",
            resetText: "Original reset text",
            resetsAt: now.addingTimeInterval(60 * 60),
            resetDisplayStyle: .relativeWithLocalTime,
            fetchedAt: now
        )
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [
                WatchAccountSnapshot(
                    id: "codex",
                    providerName: "Codex",
                    accountLabel: "Primary",
                    fetchedAt: now,
                    metrics: [metric]
                ),
            ]
        )
        let resolver = WatchComplicationResolver()
        let initial = try XCTUnwrap(
            resolver.resolve(snapshot: snapshot, selection: .automatic, at: now).resetText
        )
        let later = try XCTUnwrap(
            resolver.resolve(
                snapshot: snapshot,
                selection: .automatic,
                at: now.addingTimeInterval(30 * 60)
            ).resetText
        )

        XCTAssertTrue(initial.hasPrefix("Resets 1h"))
        XCTAssertTrue(later.hasPrefix("Resets 30m"))
        XCTAssertNotEqual(initial, later)
    }

    func testComplicationExpiresAtKnownMetricResetBoundary() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let resetsAt = now.addingTimeInterval(5 * 60)
        let metric = WatchMetricSnapshot(
            id: "usage",
            label: "Usage",
            usedFraction: 0.5,
            exactValue: "50%",
            resetText: "Resets 5m",
            resetsAt: resetsAt,
            resetDisplayStyle: .relativeWithLocalTime,
            fetchedAt: now
        )
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 3_600,
            accounts: [
                WatchAccountSnapshot(
                    id: "codex",
                    providerName: "Codex",
                    accountLabel: "Primary",
                    fetchedAt: now,
                    metrics: [metric]
                ),
            ]
        )
        let resolver = WatchComplicationResolver()

        XCTAssertEqual(
            resolver.nextReloadDate(snapshot: snapshot, selection: .automatic, now: now),
            resetsAt
        )
        XCTAssertEqual(
            resolver.timelineEntryDates(
                snapshot: snapshot,
                selection: .automatic,
                now: now
            ),
            [now] + (1...5).map {
                now.addingTimeInterval(TimeInterval($0 * 60))
            }
        )
        XCTAssertFalse(
            resolver.resolve(
                snapshot: snapshot,
                selection: .automatic,
                at: resetsAt.addingTimeInterval(-1)
            ).isStale
        )
        XCTAssertTrue(
            resolver.resolve(
                snapshot: snapshot,
                selection: .automatic,
                at: resetsAt
            ).isStale
        )
    }

    func testComplicationTimelineRefreshesEachMinuteDuringFinalResetHour() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let resetsAt = now.addingTimeInterval(3 * 60 * 60)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 2 * 60 * 60,
            accounts: [
                WatchAccountSnapshot(
                    id: "codex",
                    providerName: "Codex",
                    accountLabel: "Primary",
                    fetchedAt: now,
                    metrics: [
                        WatchMetricSnapshot(
                            id: "usage",
                            label: "Usage",
                            usedFraction: 0.5,
                            exactValue: "50%",
                            resetText: "Resets 3h 0m",
                            resetsAt: resetsAt,
                            resetDisplayStyle: .relativeWithLocalTime,
                            fetchedAt: now
                        ),
                    ]
                ),
            ]
        )
        let dates = WatchComplicationResolver().timelineEntryDates(
            snapshot: snapshot,
            selection: .automatic,
            now: now
        )

        for minutesBeforeReset in 0...60 {
            XCTAssertTrue(
                dates.contains(
                    resetsAt.addingTimeInterval(-TimeInterval(minutesBeforeReset * 60))
                )
            )
        }
    }

    func testRelativeResetTimelineAlignsHourlyAndFinalMinutePrecision() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let resetsAt = now.addingTimeInterval(3.5 * 60 * 60)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 2 * 60 * 60,
            accounts: [
                WatchAccountSnapshot(
                    id: "codex",
                    providerName: "Codex",
                    accountLabel: "Primary",
                    fetchedAt: now,
                    metrics: [
                        WatchMetricSnapshot(
                            id: "usage",
                            label: "Usage",
                            usedFraction: 0.5,
                            exactValue: "50%",
                            resetText: "Resets later",
                            resetsAt: resetsAt,
                            resetDisplayStyle: .relativeWithLocalTime,
                            fetchedAt: now
                        ),
                    ]
                ),
            ]
        )
        let resolver = WatchComplicationResolver()
        let dates = resolver.timelineEntryDates(
            snapshot: snapshot,
            selection: .automatic,
            now: now
        )

        for hoursBeforeReset in 1...3 {
            XCTAssertTrue(
                dates.contains(
                    resetsAt.addingTimeInterval(-TimeInterval(hoursBeforeReset * 60 * 60))
                )
            )
        }
        XCTAssertFalse(
            dates.contains(resetsAt.addingTimeInterval(-(2 * 60 * 60) + 60))
        )
        XCTAssertTrue(
            try XCTUnwrap(
                resolver.resolve(snapshot: snapshot, selection: .automatic, at: now).resetText
            ).hasPrefix("Resets 4h")
        )
        XCTAssertTrue(
            try XCTUnwrap(
                resolver.resolve(
                    snapshot: snapshot,
                    selection: .automatic,
                    at: resetsAt.addingTimeInterval(-3 * 60 * 60)
                ).resetText
            ).hasPrefix("Resets 3h")
        )
        XCTAssertTrue(
            try XCTUnwrap(
                resolver.resolve(
                    snapshot: snapshot,
                    selection: .automatic,
                    at: resetsAt.addingTimeInterval(-59 * 60)
                ).resetText
            ).hasPrefix("Resets 59m")
        )
    }

    func testRelativeResetTimelineRoundsAndAlignsBeyondOneDay() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let resetsAt = now.addingTimeInterval(27.5 * 60 * 60)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 2 * 60 * 60,
            accounts: [
                WatchAccountSnapshot(
                    id: "codex",
                    providerName: "Codex",
                    accountLabel: "Primary",
                    fetchedAt: now,
                    metrics: [
                        WatchMetricSnapshot(
                            id: "usage",
                            label: "Usage",
                            usedFraction: 0.5,
                            exactValue: "50%",
                            resetText: "Resets later",
                            resetsAt: resetsAt,
                            resetDisplayStyle: .relativeWithLocalTime,
                            fetchedAt: now
                        ),
                    ]
                ),
            ]
        )
        let resolver = WatchComplicationResolver()
        let dates = resolver.timelineEntryDates(
            snapshot: snapshot,
            selection: .automatic,
            now: now
        )
        let twentySevenHoursBeforeReset = resetsAt.addingTimeInterval(-27 * 60 * 60)

        XCTAssertTrue(dates.contains(twentySevenHoursBeforeReset))
        XCTAssertFalse(
            dates.contains(resetsAt.addingTimeInterval(-(26 * 60 * 60) + 60))
        )
        XCTAssertTrue(
            try XCTUnwrap(
                resolver.resolve(snapshot: snapshot, selection: .automatic, at: now).resetText
            ).hasPrefix("Resets 28h")
        )
        XCTAssertTrue(
            try XCTUnwrap(
                resolver.resolve(
                    snapshot: snapshot,
                    selection: .automatic,
                    at: twentySevenHoursBeforeReset
                ).resetText
            ).hasPrefix("Resets 27h")
        )
    }

    func testRelativeResetTimelineUsesMinutesUntilMidHourStaleness() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let fetchedAt = now.addingTimeInterval(-60 * 60)
        let resetsAt = now.addingTimeInterval(80 * 60)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 45 * 60,
            accounts: [
                WatchAccountSnapshot(
                    id: "codex",
                    providerName: "Codex",
                    accountLabel: "Primary",
                    fetchedAt: fetchedAt,
                    metrics: [
                        WatchMetricSnapshot(
                            id: "usage",
                            label: "Usage",
                            usedFraction: 0.5,
                            exactValue: "50%",
                            resetText: "Resets later",
                            resetsAt: resetsAt,
                            resetDisplayStyle: .relativeWithLocalTime,
                            fetchedAt: fetchedAt
                        ),
                    ]
                ),
            ]
        )
        let resolver = WatchComplicationResolver()
        let dates = resolver.timelineEntryDates(
            snapshot: snapshot,
            selection: .automatic,
            now: now
        )

        XCTAssertTrue(dates.contains(resetsAt.addingTimeInterval(-60 * 60)))
        XCTAssertTrue(dates.contains(resetsAt.addingTimeInterval(-59 * 60)))
        XCTAssertTrue(dates.contains(resetsAt.addingTimeInterval(-50 * 60)))
        XCTAssertFalse(dates.contains(resetsAt.addingTimeInterval(-49 * 60)))
        XCTAssertTrue(
            try XCTUnwrap(
                resolver.resolve(
                    snapshot: snapshot,
                    selection: .automatic,
                    at: resetsAt.addingTimeInterval(-59 * 60)
                ).resetText
            ).hasPrefix("Resets 59m")
        )
    }

    func testNonRelativeResetStylesAvoidFinalHourCountdownEntries() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let resetsAt = now.addingTimeInterval(3 * 60 * 60)

        for style in [UsageResetDisplayStyle.verbatim, .shortLocalDate] {
            let snapshot = WatchDashboardSnapshot(
                generatedAt: now,
                refreshIntervalSeconds: 2 * 60 * 60,
                accounts: [
                    WatchAccountSnapshot(
                        id: "codex",
                        providerName: "Codex",
                        accountLabel: "Primary",
                        fetchedAt: now,
                        metrics: [
                            WatchMetricSnapshot(
                                id: "usage",
                                label: "Usage",
                                usedFraction: 0.5,
                                exactValue: "50%",
                                resetText: "Resets later",
                                resetsAt: resetsAt,
                                resetDisplayStyle: style,
                                fetchedAt: now
                            ),
                        ]
                    ),
                ]
            )
            let dates = WatchComplicationResolver().timelineEntryDates(
                snapshot: snapshot,
                selection: .automatic,
                now: now
            )

            XCTAssertTrue(dates.contains(resetsAt))
            XCTAssertFalse(dates.contains(resetsAt.addingTimeInterval(-30 * 60)))
        }
    }

    func testAllWatchComplicationFamiliesHavePurposefulLayouts() {
        XCTAssertEqual(Set(WatchComplicationFamilyLayout.allCases), [
            .inline,
            .circular,
            .rectangular,
            .corner,
        ])
        XCTAssertTrue(WatchComplicationFamilyLayout.rectangular.showsResetContext)
        XCTAssertFalse(WatchComplicationFamilyLayout.inline.showsResetContext)
        XCTAssertTrue(WatchComplicationFamilyLayout.circular.usesGauge)
        XCTAssertTrue(WatchComplicationFamilyLayout.corner.usesGauge)
        XCTAssertFalse(WatchComplicationFamilyLayout.inline.usesGauge)
    }

    func testFractionlessMetricsUseNumericComplicationLayouts() {
        let sample = WatchComplicationSample(
            availability: .value,
            providerName: "Codex",
            accountLabel: "Primary",
            metricLabel: "Credits",
            exactValue: "$12.34",
            usedFraction: nil,
            severity: .normal,
            resetText: nil,
            freshnessText: "Updated now",
            isStale: true
        )

        XCTAssertFalse(sample.supportsGauge)
        XCTAssertFalse(WatchComplicationFamilyLayout.circular.usesGauge(for: sample))
        XCTAssertFalse(WatchComplicationFamilyLayout.corner.usesGauge(for: sample))
        XCTAssertEqual(sample.exactValue, "$12.34")
        XCTAssertEqual(sample.cornerContextLabel, "Stale • Credits")
        XCTAssertEqual(sample.accountContextLabel, "Codex • Primary")
    }

    private func account(
        id: String,
        provider: String,
        metricID: String,
        fraction: Double,
        generatedAt: Date,
        style: WatchMetricVisualizationStyle = .linearBar,
        planIdentifier: String? = nil,
        planDisplayLabel: String? = nil,
        planAccessibilityLabel: String? = nil
    ) -> WatchAccountSnapshot {
        WatchAccountSnapshot(
            id: id,
            providerName: provider,
            accountLabel: "Primary",
            planIdentifier: planIdentifier,
            planDisplayLabel: planDisplayLabel,
            planAccessibilityLabel: planAccessibilityLabel,
            fetchedAt: generatedAt,
            metrics: [
                WatchMetricSnapshot(
                    id: metricID,
                    label: "Usage",
                    usedFraction: fraction,
                    remainingFraction: 1 - fraction,
                    exactValue: "\(Int((fraction * 100).rounded()))%",
                    visualizationStyle: style
                ),
            ]
        )
    }
}

extension WatchDashboardStateTests {
    func testAppStoreScreenshotScenesRequireExplicitLaunchFlag() {
        XCTAssertNil(WatchAppStoreScreenshotScene.current(arguments: ["CodexBarWatch"]))
        XCTAssertEqual(
            WatchAppStoreScreenshotScene.current(
                arguments: ["CodexBarWatch", "--app-store-screenshots"]
            ),
            .overview
        )
        XCTAssertEqual(
            WatchAppStoreScreenshotScene.current(
                arguments: [
                    "CodexBarWatch",
                    "--app-store-screenshots",
                    "--app-store-watch-scene",
                    "balances",
                ]
            ),
            .balances
        )
        XCTAssertNil(
            WatchAppStoreScreenshotScene.current(
                arguments: [
                    "CodexBarWatch",
                    "--app-store-screenshots",
                    "--app-store-watch-scene",
                    "unknown",
                ]
            )
        )
    }

    func testAppStoreScreenshotScenesContainOnlyFictionalAccountLabels() {
        let labels = WatchAppStoreScreenshotScene.allCases.flatMap {
            $0.state.samples.map(\.accountLabel)
        }

        XCTAssertEqual(Set(labels), ["Demo Studio", "Demo Workspace"])
        XCTAssertTrue(
            WatchAppStoreScreenshotScene.allCases.allSatisfy {
                $0.state.statusText == "Updated just now"
            }
        )
    }

    func testAppStoreScreenshotReadinessUsesRequestedSceneAndBoundedDelay() throws {
        XCTAssertEqual(
            WatchAppStoreScreenshotScene.settleDelay(
                arguments: ["CodexBarWatch", "--app-store-settle-seconds", "1.5"]
            ),
            1.5
        )
        XCTAssertEqual(
            WatchAppStoreScreenshotScene.settleDelay(
                arguments: ["CodexBarWatch"],
                environment: ["CODEXBAR_APP_STORE_SETTLE_SECONDS": "45"]
            ),
            30
        )
        XCTAssertEqual(
            WatchAppStoreScreenshotScene.settleDelay(
                arguments: ["CodexBarWatch", "--app-store-settle-seconds", "nan"]
            ),
            3
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        WatchAppStoreScreenshotScene.balances.markReady(cachesDirectory: directory)
        let readyFile = directory.appendingPathComponent(WatchAppStoreScreenshotScene.readyFileName)
        XCTAssertEqual(try String(contentsOf: readyFile, encoding: .utf8), "balances")
    }
}
