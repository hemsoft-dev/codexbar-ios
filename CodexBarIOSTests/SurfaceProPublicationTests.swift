import Combine
import Foundation
import XCTest
@testable import CodexBarIOS

@MainActor
final class SurfaceProPublicationTests: XCTestCase {
    func testInitialFreePublicationClearsBothSurfacesBeforeProviderResults() async throws {
        let fixture = try SurfaceProPublicationFixture(hasResults: false)
        defer { fixture.cleanUp() }
        let oldAccess = SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil)
        fixture.publishSavedResults(access: oldAccess)
        XCTAssertEqual(try fixture.watchSnapshot().accounts.count, 2)
        XCTAssertEqual(fixture.widgetSnapshot.results.count, 2)

        await expectBoth(fixture, locked: true, deadline: nil) {
            fixture.connect()
        }

        XCTAssertTrue(fixture.refreshService.results.isEmpty)
        XCTAssertTrue(fixture.widgetSnapshot.results.isEmpty)
        XCTAssertTrue(try fixture.watchSnapshot().accounts.isEmpty)
        XCTAssertEqual(fixture.configurationStore.configurations.count, 2)
        XCTAssertTrue(fixture.configurationStore.configurations.allSatisfy { fixture.configurationStore.hasSecret(for: $0) })
        fixture.watchCoordinator?.start()
        XCTAssertTrue(try fixture.reply().isProLocked)
    }

    func testRawCommittedChangesPublishRenewedShortenedAndPermanentAccess() async throws {
        let fixture = try SurfaceProPublicationFixture()
        defer { fixture.cleanUp() }
        let initialExpiry = fixture.instant.addingTimeInterval(3_600)
        await fixture.deliver(.monthly, signedOffset: 0, expiry: initialExpiry)
        await fixture.entitlement.refresh()
        let initialState = fixture.entitlement.accessState
        XCTAssertEqual(initialState, ProAccessState(hasAccess: true, isResolved: true))
        await expectBoth(fixture, locked: false, deadline: initialExpiry.addingTimeInterval(259_200)) {
            fixture.connect()
        }
        XCTAssertEqual(Set(fixture.widgetSnapshot.results.compactMap { $0.bars.first?.fractionUsed }), [0.1, 0.2])
        XCTAssertEqual(Set(try fixture.watchSnapshot().accounts.compactMap { $0.metrics.first?.usedFraction }), [0.1, 0.2])
        XCTAssertEqual(try fixture.watchSnapshot().proAccessEffectiveAt, fixture.instant)
        var previousSemanticData = try fixture.watchSnapshot().semanticData()

        let renewedExpiry = fixture.instant.addingTimeInterval(7_200)
        await expectBoth(fixture, locked: false, deadline: renewedExpiry.addingTimeInterval(259_200)) {
            await fixture.deliver(.monthly, signedOffset: 1, expiry: renewedExpiry)
        }
        XCTAssertEqual(fixture.entitlement.accessState, initialState)
        XCTAssertNotEqual(try fixture.watchSnapshot().semanticData(), previousSemanticData)
        previousSemanticData = try fixture.watchSnapshot().semanticData()

        // One verified snapshot retires the longer product while granting the shorter one.
        // The canonical permission booleans never change during this metadata replacement.
        let shorterExpiry = fixture.instant.addingTimeInterval(1_800)
        fixture.source.next = ProStoreSnapshot(purchases: [
            fixture.purchase(.monthly, signedOffset: 2, expiry: renewedExpiry, revoked: true),
            fixture.purchase(.yearly, signedOffset: 2, expiry: shorterExpiry),
        ])
        await expectBoth(fixture, locked: false, deadline: shorterExpiry.addingTimeInterval(259_200)) {
            await fixture.entitlement.refresh()
        }
        XCTAssertEqual(fixture.entitlement.accessState, initialState)
        XCTAssertNotEqual(try fixture.watchSnapshot().semanticData(), previousSemanticData)
        previousSemanticData = try fixture.watchSnapshot().semanticData()

        await expectBoth(fixture, locked: false, deadline: nil) {
            await fixture.deliver(.lifetime, signedOffset: 3, expiry: nil)
        }
        XCTAssertEqual(fixture.entitlement.accessState, initialState)
        XCTAssertNil(try fixture.watchSnapshot().proAccessEffectiveAt)
        XCTAssertNotEqual(try fixture.watchSnapshot().semanticData(), previousSemanticData)

        await expectBoth(fixture, locked: false, deadline: shorterExpiry.addingTimeInterval(259_200)) {
            await fixture.deliver(.lifetime, signedOffset: 4, expiry: nil, revoked: true)
        }
        XCTAssertEqual(fixture.entitlement.accessState, initialState)
        XCTAssertEqual(try fixture.watchSnapshot().accounts.count, 2)
        XCTAssertEqual(fixture.widgetSnapshot.results.count, 2)
    }

    func testClockOnlyDenialAndRecoveryPublishBeforeStoreKitReturnsWithoutChangingEvidenceBytes() async throws {
        let fixture = try SurfaceProPublicationFixture()
        defer { fixture.cleanUp() }
        let expiry = fixture.instant.addingTimeInterval(3_600)
        let deadline = expiry.addingTimeInterval(259_200)
        await fixture.deliver(.monthly, signedOffset: 0, expiry: expiry)
        await expectBoth(fixture, locked: false, deadline: deadline) { fixture.connect() }
        XCTAssertEqual(try fixture.watchSnapshot().proAccessEffectiveAt, fixture.instant)
        let evidenceBytes = try fixture.entitlementBytes()
        let persistedEvidence = try Data(contentsOf: fixture.cacheURL)
        let originalResults = fixture.widgetSnapshot.results
        let originalAccounts = try fixture.watchSnapshot().accounts
        let entered = expectation(description: "StoreKit snapshot is suspended")
        fixture.source.beforeSnapshot = {
            entered.fulfill()
            await withCheckedContinuation { fixture.source.resumeSnapshot = $0 }
        }
        fixture.clock.sample = ProEntitlementClockSample(
            wallDate: fixture.instant.addingTimeInterval(-1), continuousSeconds: 1, continuityID: nil
        )
        var refreshTask: Task<Void, Never>?
        await expectBoth(fixture, locked: true, deadline: deadline) {
            refreshTask = Task { await fixture.entitlement.refresh() }
            await self.fulfillment(of: [entered], timeout: 2)
        }

        XCTAssertNotNil(fixture.source.resumeSnapshot, "Both surfaces must lock while StoreKit is still suspended")
        XCTAssertFalse(fixture.entitlement.hasAccess)
        XCTAssertEqual(try fixture.entitlementBytes(), evidenceBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.cacheURL), persistedEvidence)
        XCTAssertTrue(fixture.widgetSnapshot.results.isEmpty)
        XCTAssertTrue(try fixture.watchSnapshot().accounts.isEmpty)
        XCTAssertNil(try fixture.watchSnapshot().proAccessEffectiveAt)

        fixture.clock.sample = SurfaceProPublicationClock.sample(at: fixture.instant.addingTimeInterval(1))
        await expectBoth(fixture, locked: false, deadline: deadline) {
            fixture.entitlement.reevaluateLocalAccess()
        }
        XCTAssertTrue(fixture.entitlement.hasAccess)
        XCTAssertEqual(try fixture.entitlementBytes(), evidenceBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.cacheURL), persistedEvidence)
        XCTAssertEqual(fixture.widgetSnapshot.results, originalResults)
        XCTAssertEqual(try fixture.watchSnapshot().accounts, originalAccounts)
        XCTAssertEqual(try fixture.watchSnapshot().proAccessEffectiveAt, fixture.instant.addingTimeInterval(1))
        fixture.source.beforeSnapshot = nil
        fixture.source.resumeSnapshot?.resume()
        fixture.source.resumeSnapshot = nil
        await refreshTask?.value
    }

    func testDeadlineMetadataPublishesWithoutResultsAndPreservesRetainedWatchFreshness() async throws {
        let fixture = try SurfaceProPublicationFixture(hasResults: false)
        defer { fixture.cleanUp() }
        let oldDate = fixture.instant.addingTimeInterval(-600)
        let oldDeadline = fixture.instant.addingTimeInterval(900)
        fixture.publishSavedResults(
            access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: oldDeadline, proAccessEffectiveAt: oldDate),
            generatedAt: oldDate
        )
        let oldSnapshot = try fixture.watchSnapshot()
        let expiry = fixture.instant.addingTimeInterval(3_600)
        await fixture.deliver(.monthly, signedOffset: 0, expiry: expiry)
        await expectBoth(fixture, locked: false, deadline: expiry.addingTimeInterval(259_200)) {
            fixture.connect()
        }
        let initial = try fixture.watchSnapshot()
        XCTAssertEqual(initial.accounts, oldSnapshot.accounts)
        XCTAssertEqual(initial.generatedAt, oldDate)
        XCTAssertEqual(initial.proAccessEffectiveAt, fixture.instant)
        XCTAssertTrue(fixture.refreshService.results.isEmpty)

        let renewedExpiry = fixture.instant.addingTimeInterval(7_200)
        await expectBoth(fixture, locked: false, deadline: renewedExpiry.addingTimeInterval(259_200)) {
            await fixture.deliver(.monthly, signedOffset: 1, expiry: renewedExpiry)
        }
        XCTAssertEqual(try fixture.watchSnapshot().accounts, oldSnapshot.accounts)
        XCTAssertEqual(try fixture.watchSnapshot().generatedAt, oldDate)
        XCTAssertEqual(try fixture.watchSnapshot().proAccessEffectiveAt, fixture.instant.addingTimeInterval(1))

        await expectBoth(fixture, locked: true, deadline: nil) {
            await fixture.deliver(.monthly, signedOffset: 2, expiry: renewedExpiry, revoked: true)
        }
        XCTAssertTrue(try fixture.watchSnapshot().accounts.isEmpty)
        XCTAssertTrue(fixture.widgetSnapshot.results.isEmpty)
    }

    func testLockAndUnlockPreservePhonePersistenceAndRestorePublishedUsage() async throws {
        let fixture = try SurfaceProPublicationFixture()
        defer { fixture.cleanUp() }
        await fixture.deliver(.lifetime, signedOffset: 0, expiry: nil)
        await expectBoth(fixture, locked: false, deadline: nil) { fixture.connect() }
        let phoneBytes = try XCTUnwrap(fixture.phoneDefaults.persistentDomain(forName: fixture.phoneSuite)) as NSDictionary
        let historyBytes = try XCTUnwrap(fixture.phoneDefaults.data(forKey: "usageHistorySnapshots"))
        let builderBytes = try XCTUnwrap(fixture.widgetDefaults.data(forKey: "widgetBuilderConfiguration"))
        let savedResults = fixture.refreshService.results
        let unlockedWidget = fixture.widgetSnapshot.results
        let unlockedWatch = try fixture.watchSnapshot().accounts
        let savedConfigurations = fixture.configurationStore.configurations
        let savedTileID = try XCTUnwrap(WidgetSnapshotStore.loadBuilderConfiguration(defaults: fixture.widgetDefaults).tileID(at: 0))
        let initialWidget = fixture.widgetSnapshot
        let originalChoice = try await CodexBarWidgetTileChoiceQuery(loadSnapshot: { initialWidget }, accessContext: fixture.widgetAccessContext()).entities(for: [savedTileID])
        XCTAssertEqual(originalChoice.map(\.id), [savedTileID])
        XCTAssertEqual(originalChoice.map(\.title), ["Codex - Usage"])
        XCTAssertEqual(initialWidget.builderTile(resolvingSavedID: savedTileID)?.fractionUsed, 0.1)

        await expectBoth(fixture, locked: true, deadline: nil) {
            await fixture.deliver(.lifetime, signedOffset: 1, expiry: nil, revoked: true)
        }
        XCTAssertTrue(fixture.widgetSnapshot.results.isEmpty)
        XCTAssertTrue(try fixture.watchSnapshot().accounts.isEmpty)
        XCTAssertEqual(fixture.refreshService.results, savedResults)
        XCTAssertEqual(fixture.phoneDefaults.persistentDomain(forName: fixture.phoneSuite) as NSDictionary?, phoneBytes)
        XCTAssertEqual(fixture.phoneDefaults.data(forKey: "usageHistorySnapshots"), historyBytes)
        XCTAssertEqual(fixture.widgetDefaults.data(forKey: "widgetBuilderConfiguration"), builderBytes)
        let lockedWidget = fixture.widgetSnapshot
        let lockedChoice = try await CodexBarWidgetTileChoiceQuery(loadSnapshot: { lockedWidget }, accessContext: fixture.widgetAccessContext()).entities(for: [savedTileID])
        XCTAssertEqual(lockedChoice.map(\.id), [savedTileID])
        XCTAssertEqual(lockedChoice.map(\.title), ["Saved Tile"])
        let reloadedStore = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: fixture.phoneDefaults,
            secretStore: fixture.secretStore, widgetSnapshotDefaults: fixture.widgetDefaults
        )
        XCTAssertEqual(reloadedStore.configurations, savedConfigurations)
        XCTAssertEqual(reloadedStore.groups, fixture.configurationStore.groups)
        XCTAssertEqual(reloadedStore.metricLayouts, fixture.configurationStore.metricLayouts)
        XCTAssertTrue(reloadedStore.configurations.allSatisfy { reloadedStore.hasSecret(for: $0) })
        XCTAssertEqual(UsageHistoryStore(defaults: fixture.phoneDefaults).snapshots, fixture.historyStore.snapshots)

        await expectBoth(fixture, locked: false, deadline: nil) {
            await fixture.deliver(.lifetime, signedOffset: 2, expiry: nil)
        }
        XCTAssertEqual(fixture.widgetSnapshot.results, unlockedWidget)
        XCTAssertEqual(try fixture.watchSnapshot().accounts, unlockedWatch)
        XCTAssertEqual(WidgetSnapshotStore.loadBuilderConfiguration(defaults: fixture.widgetDefaults), fixture.builder)
        XCTAssertEqual(fixture.widgetDefaults.data(forKey: "widgetBuilderConfiguration"), builderBytes)
        XCTAssertEqual(fixture.phoneDefaults.data(forKey: "usageHistorySnapshots"), historyBytes)
        let restoredWidget = fixture.widgetSnapshot
        let restoredChoice = try await CodexBarWidgetTileChoiceQuery(loadSnapshot: { restoredWidget }, accessContext: fixture.widgetAccessContext()).entities(for: [savedTileID])
        XCTAssertEqual(restoredChoice.map(\.id), [savedTileID])
        XCTAssertEqual(restoredChoice.map(\.title), ["Codex - Usage"])
        XCTAssertEqual(restoredWidget.builderTile(resolvingSavedID: savedTileID)?.fractionUsed, 0.1)
    }

    func testForcedRequestReplacesCachedGrantBeforeCoalescingEvenWhenTransportFails() async throws {
        let fixture = try SurfaceProPublicationFixture(hasResults: false)
        defer { fixture.cleanUp() }
        let expiry = fixture.instant.addingTimeInterval(3_600)
        await fixture.deliver(.monthly, signedOffset: 0, expiry: expiry)
        fixture.publishSavedResults(access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: expiry.addingTimeInterval(259_200)))
        fixture.connect(delay: .seconds(30))
        let grant = try fixture.reply()
        XCTAssertFalse(grant.isProLocked)
        XCTAssertEqual(grant.accounts.count, 2)
        XCTAssertEqual(grant.proAccessEffectiveAt, fixture.instant)
        fixture.transport.fails = true
        // This schedules a pending grant publication before denial invalidates it.
        fixture.configurationStore.updateAutoRefreshInterval(.fiveMinutes)
        let attemptsBeforeRequest = fixture.transport.attempts.count
        fixture.clock.sample = ProEntitlementClockSample(
            wallDate: fixture.instant.addingTimeInterval(-1), continuousSeconds: 1, continuityID: nil
        )
        fixture.entitlement.reevaluateLocalAccess()
        XCTAssertEqual(fixture.transport.attempts.count, attemptsBeforeRequest)

        let locked = try fixture.reply()

        XCTAssertTrue(locked.isProLocked)
        XCTAssertTrue(locked.accounts.isEmpty)
        XCTAssertEqual(locked.proAccessEndsAt, expiry.addingTimeInterval(259_200))
        XCTAssertNil(locked.proAccessEffectiveAt)
        XCTAssertEqual(fixture.transport.attempts.count, attemptsBeforeRequest + 1)
        XCTAssertGreaterThan(try XCTUnwrap(locked.publicationSequence), try XCTUnwrap(grant.publicationSequence))
        XCTAssertTrue(fixture.refreshService.results.isEmpty)
        XCTAssertEqual(try fixture.reply().publicationSequence, locked.publicationSequence)
        XCTAssertTrue(try fixture.reply().isProLocked)

        fixture.clock.sample = ProEntitlementClockSample(
            wallDate: fixture.instant.addingTimeInterval(-100),
            continuousSeconds: fixture.instant.timeIntervalSince1970 + 5, continuityID: "surface-test-boot"
        )
        let recovered = try fixture.reply()
        XCTAssertFalse(recovered.isProLocked)
        XCTAssertEqual(recovered.proAccessEffectiveAt, fixture.instant.addingTimeInterval(5))
        XCTAssertEqual(recovered.proAccessEndsAt, grant.proAccessEndsAt)
        XCTAssertEqual(fixture.sender.retainedSnapshot?.proAccessEffectiveAt, recovered.proAccessEffectiveAt)
        XCTAssertGreaterThan(try XCTUnwrap(recovered.publicationSequence), try XCTUnwrap(locked.publicationSequence))
    }

    func testDeniedActivationReplacesPersistedGrantAndRestartKeepsMonotonicSequenceAcrossRollback() async throws {
        let fixture = try SurfaceProPublicationFixture(hasResults: false)
        defer { fixture.cleanUp() }
        fixture.publishSavedResults(access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil))
        let grant = try fixture.watchSnapshot()
        let firstSequence = try XCTUnwrap(grant.publicationSequence)
        let restarted = PhoneWatchConnectivityCoordinator(
            session: nil, defaults: fixture.transportDefaults, sendApplicationContext: fixture.transport.send
        )
        XCTAssertEqual(restarted.retainedSnapshot?.publicationSequence, firstSequence)
        XCTAssertTrue(restarted.publish(grant, force: false))
        XCTAssertEqual(try fixture.watchSnapshot().publicationSequence, firstSequence,
                       "A repeated send after restart must retain its original semantic order")
        fixture.clock.sample = SurfaceProPublicationClock.sample(at: fixture.instant.addingTimeInterval(-3_600))
        let coordinator = WatchSnapshotCoordinator(
            refreshService: fixture.refreshService, configurationStore: fixture.configurationStore,
            entitlement: fixture.entitlement, sender: restarted,
            accessPublisher: { results, store, access, force in
                WatchSnapshotPublisher.publish(
                    results: results, configurationStore: store, access: access,
                    sender: restarted, now: fixture.clock.sample.wallDate, force: force
                )
            }
        )
        fixture.transport.fails = true
        coordinator.start()
        var reply: [String: Any] = [:]
        XCTAssertTrue(restarted.handleMessage(WatchDashboardSnapshot.snapshotRequestMessage) { reply = $0 })
        let locked = try WatchDashboardSnapshot.decodeApplicationContext(reply)
        XCTAssertTrue(locked.isProLocked)
        XCTAssertTrue(locked.accounts.isEmpty)
        XCTAssertLessThan(locked.generatedAt, grant.generatedAt)
        XCTAssertGreaterThan(try XCTUnwrap(locked.publicationSequence), firstSequence)

        let secondRestart = PhoneWatchConnectivityCoordinator(
            session: nil, defaults: fixture.transportDefaults, sendApplicationContext: fixture.transport.send
        )
        XCTAssertEqual(secondRestart.retainedSnapshot, locked, "A failed transport must still persist the lock and its order")
        fixture.transport.fails = false
        XCTAssertTrue(secondRestart.publish(grant, force: true))
        let restored = try fixture.watchSnapshot()
        XCTAssertGreaterThan(try XCTUnwrap(restored.publicationSequence), try XCTUnwrap(locked.publicationSequence))
        XCTAssertFalse(restored.isProLocked)
        let count = fixture.transport.delivered.count
        XCTAssertFalse(secondRestart.publish(grant, force: false))
        XCTAssertEqual(fixture.transport.delivered.count, count)
        XCTAssertEqual(secondRestart.retainedSnapshot?.publicationSequence, restored.publicationSequence)
        withExtendedLifetime(coordinator) {}
    }

    func testFreshPhoneUsesWatchRequestWatermarkBeforeReplyingAndUpgrading() async throws {
        let fixture = try SurfaceProPublicationFixture(hasResults: false)
        defer { fixture.cleanUp() }
        XCTAssertNil(fixture.sender.retainedSnapshot)
        await expectBoth(fixture, locked: true, deadline: nil) { fixture.connect() }
        var reply: [String: Any] = [:]
        XCTAssertTrue(fixture.sender.handleMessage(WatchDashboardSnapshot.snapshotRequestMessage(after: 100)) { reply = $0 })
        let locked = try WatchDashboardSnapshot.decodeApplicationContext(reply)
        XCTAssertEqual(locked.publicationSequence, 101)
        XCTAssertTrue(locked.isProLocked)
        XCTAssertTrue(locked.accounts.isEmpty)

        await expectBoth(fixture, locked: false, deadline: nil) {
            await fixture.deliver(.lifetime, signedOffset: 0, expiry: nil)
        }
        XCTAssertEqual(try fixture.watchSnapshot().publicationSequence, 102)
        XCTAssertFalse(try fixture.watchSnapshot().isProLocked)
        let restarted = PhoneWatchConnectivityCoordinator(session: nil, defaults: fixture.transportDefaults)
        XCTAssertEqual(restarted.retainedSnapshot?.publicationSequence, 102)
    }

    func testQueuedWatchRequestWatermarkAdvancesBeforeFailedTransportAndPersists() throws {
        let fixture = try SurfaceProPublicationFixture(hasResults: false)
        defer { fixture.cleanUp() }
        fixture.connect()
        fixture.transport.fails = true
        XCTAssertTrue(fixture.sender.handleUserInfo(WatchDashboardSnapshot.snapshotRequestMessage(after: 200)))
        let reply = try fixture.reply()
        XCTAssertEqual(reply.publicationSequence, 201)
        XCTAssertTrue(reply.isProLocked)
        let restarted = PhoneWatchConnectivityCoordinator(session: nil, defaults: fixture.transportDefaults)
        XCTAssertEqual(restarted.retainedSnapshot, reply)
    }

    func testEqualReceiverWatermarkAdvancesOnceForIdenticalAndChangedAccounts() async throws {
        for changesAccounts in [false, true] {
            let fixture = try SurfaceProPublicationFixture()
            defer { fixture.cleanUp() }
            await fixture.deliver(.lifetime, signedOffset: 0, expiry: nil)
            fixture.publishSavedResults(access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil))
            let previous = try fixture.watchSnapshot()
            XCTAssertEqual(previous.publicationSequence, 1)
            XCTAssertEqual(previous.accounts.count, 2)
            fixture.transportDefaults.removePersistentDomain(forName: fixture.transportSuite)
            let newSender = PhoneWatchConnectivityCoordinator(
                session: nil, defaults: fixture.transportDefaults, sendApplicationContext: fixture.transport.send
            )
            let currentResults = changesAccounts ? Array(fixture.savedResults.prefix(1)) : fixture.savedResults
            let service = UsageRefreshService(providers: [], initialResults: currentResults)
            let coordinator = WatchSnapshotCoordinator(
                refreshService: service, configurationStore: fixture.configurationStore,
                entitlement: fixture.entitlement, sender: newSender
            )
            coordinator.start()
            let current = try fixture.watchSnapshot()
            XCTAssertEqual(current.publicationSequence, 1)
            XCTAssertEqual(current.accounts.count, changesAccounts ? 1 : 2)
            let request = WatchDashboardSnapshot.snapshotRequestMessage(after: previous.publicationSequence)
            let sendsBeforeRequest = fixture.transport.delivered.count
            var response: [String: Any] = [:]

            XCTAssertTrue(newSender.handleMessage(request) { response = $0 })

            let newer = try WatchDashboardSnapshot.decodeApplicationContext(response)
            XCTAssertEqual(newer.publicationSequence, 2)
            XCTAssertEqual(newer.accounts, current.accounts)
            XCTAssertFalse(newer.isProLocked)
            XCTAssertEqual(fixture.transport.delivered.count, sendsBeforeRequest + 1)
            XCTAssertTrue(newSender.handleMessage(request) { response = $0 })
            XCTAssertEqual(try WatchDashboardSnapshot.decodeApplicationContext(response).publicationSequence, 2)
            XCTAssertEqual(fixture.transport.delivered.count, sendsBeforeRequest + 2)

            coordinator.publishCurrentSnapshot()

            XCTAssertEqual(newSender.retainedSnapshot?.publicationSequence, 2)
            XCTAssertEqual(fixture.transport.delivered.count, sendsBeforeRequest + 2,
                           "Normal identical publication stays deduplicated after conflict recovery")
            withExtendedLifetime(coordinator) {}
        }
    }

    func testExtremeRequestWatermarksCannotPoisonLockedReplyOrLaterUpgrade() async throws {
        for invalidSequence in [UInt64.max, UInt64.max - 1] {
            let fixture = try SurfaceProPublicationFixture(hasResults: false)
            defer { fixture.cleanUp() }
            await expectBoth(fixture, locked: true, deadline: nil) { fixture.connect() }
            var reply: [String: Any] = [:]
            let request = WatchDashboardSnapshot.snapshotRequestMessage(after: invalidSequence)

            XCTAssertTrue(fixture.sender.handleMessage(request) { reply = $0 })
            let locked = try WatchDashboardSnapshot.decodeApplicationContext(reply)
            XCTAssertTrue(locked.isProLocked)
            XCTAssertEqual(locked.publicationSequence, 1)
            XCTAssertTrue(fixture.sender.handleUserInfo(request))
            XCTAssertEqual(try fixture.reply().publicationSequence, 1)

            await expectBoth(fixture, locked: false, deadline: nil) {
                await fixture.deliver(.lifetime, signedOffset: 0, expiry: nil)
            }
            XCTAssertEqual(try fixture.watchSnapshot().publicationSequence, 2)
            let restarted = PhoneWatchConnectivityCoordinator(session: nil, defaults: fixture.transportDefaults)
            XCTAssertEqual(restarted.retainedSnapshot?.publicationSequence, 2)
            XCTAssertEqual(restarted.retainedSnapshot?.isProLocked, false)
        }
    }

    func testExtremePreviousApplicationContextIsRejectedAndCurrentAccessStillPublishes() async throws {
        for invalidSequence in [UInt64.max, UInt64.max - 1] {
            let fixture = try SurfaceProPublicationFixture(hasResults: false)
            defer { fixture.cleanUp() }
            let invalidSnapshot = WatchDashboardSnapshot(
                generatedAt: fixture.instant, refreshIntervalSeconds: 300,
                accounts: [], isProLocked: false, publicationSequence: invalidSequence
            )
            let context = try invalidSnapshot.applicationContext()
            XCTAssertThrowsError(try WatchDashboardSnapshot.decodeApplicationContext(context))
            let migrated = PhoneWatchConnectivityCoordinator(
                session: nil, defaults: fixture.transportDefaults,
                sendApplicationContext: fixture.transport.send, initialApplicationContext: context
            )
            XCTAssertNil(migrated.retainedSnapshot)
            let coordinator = WatchSnapshotCoordinator(
                refreshService: fixture.refreshService, configurationStore: fixture.configurationStore,
                entitlement: fixture.entitlement, sender: migrated
            )

            coordinator.start()

            XCTAssertTrue(try fixture.watchSnapshot().isProLocked)
            XCTAssertEqual(try fixture.watchSnapshot().publicationSequence, 1)
            await fixture.deliver(.lifetime, signedOffset: 0, expiry: nil)
            coordinator.publishCurrentSnapshot(force: true)
            XCTAssertFalse(try fixture.watchSnapshot().isProLocked)
            XCTAssertEqual(try fixture.watchSnapshot().publicationSequence, 2)
            withExtendedLifetime(coordinator) {}
        }
    }

    func testCorruptPersistedSequenceRecoversFromRetainedSnapshotWithoutLosingNextUpgrade() async throws {
        for invalidSequence in [UInt64.max, UInt64.max - 1] {
            let fixture = try SurfaceProPublicationFixture(hasResults: false)
            defer { fixture.cleanUp() }
            fixture.publishSavedResults(access: .locked)
            XCTAssertEqual(try fixture.watchSnapshot().publicationSequence, 1)
            fixture.transportDefaults.set(NSNumber(value: invalidSequence), forKey: "watch.publicationSequence")
            let restarted = PhoneWatchConnectivityCoordinator(
                session: nil, defaults: fixture.transportDefaults, sendApplicationContext: fixture.transport.send
            )
            let coordinator = WatchSnapshotCoordinator(
                refreshService: fixture.refreshService, configurationStore: fixture.configurationStore,
                entitlement: fixture.entitlement, sender: restarted
            )

            coordinator.start()

            XCTAssertTrue(try fixture.watchSnapshot().isProLocked)
            XCTAssertEqual(try fixture.watchSnapshot().publicationSequence, 1)
            XCTAssertEqual((fixture.transportDefaults.object(forKey: "watch.publicationSequence") as? NSNumber)?.uint64Value, 1)
            await fixture.deliver(.lifetime, signedOffset: 0, expiry: nil)
            coordinator.publishCurrentSnapshot(force: true)
            XCTAssertFalse(try fixture.watchSnapshot().isProLocked)
            XCTAssertEqual(try fixture.watchSnapshot().publicationSequence, 2)
            XCTAssertEqual((fixture.transportDefaults.object(forKey: "watch.publicationSequence") as? NSNumber)?.uint64Value, 2)
            withExtendedLifetime(coordinator) {}
        }
    }

    func testPreviousApplicationContextRestoresUsageBeforeInitialResultsWithNewAccess() async throws {
        let fixture = try SurfaceProPublicationFixture(hasResults: false)
        defer { fixture.cleanUp() }
        let oldDate = fixture.instant.addingTimeInterval(-600)
        let old = WatchSnapshotPublisher.makeSnapshot(
            results: fixture.savedResults, configurationStore: fixture.configurationStore,
            access: SnapshotProAccess(
                isProLocked: false, proAccessEndsAt: fixture.instant.addingTimeInterval(900), proAccessEffectiveAt: oldDate
            ),
            now: oldDate
        )
        let migrated = PhoneWatchConnectivityCoordinator(
            session: nil, defaults: fixture.transportDefaults, sendApplicationContext: fixture.transport.send,
            initialApplicationContext: try old.applicationContext()
        )
        XCTAssertEqual(migrated.retainedSnapshot?.accounts, old.accounts)
        XCTAssertEqual(migrated.retainedSnapshot?.generatedAt, oldDate)
        XCTAssertEqual(migrated.retainedSnapshot?.proAccessEffectiveAt, oldDate)
        let expiry = fixture.instant.addingTimeInterval(3_600)
        await fixture.deliver(.monthly, signedOffset: 0, expiry: expiry)
        let coordinator = WatchSnapshotCoordinator(
            refreshService: fixture.refreshService, configurationStore: fixture.configurationStore,
            entitlement: fixture.entitlement, sender: migrated,
            accessPublisher: { results, store, access, force in
                WatchSnapshotPublisher.publish(
                    results: results, configurationStore: store, access: access,
                    sender: migrated, now: fixture.instant, force: force
                )
            }
        )
        coordinator.start()
        let published = try fixture.watchSnapshot()
        XCTAssertEqual(published.accounts, old.accounts)
        XCTAssertEqual(published.generatedAt, oldDate)
        XCTAssertEqual(published.proAccessEndsAt, expiry.addingTimeInterval(259_200))
        XCTAssertEqual(published.proAccessEffectiveAt, fixture.instant)
        XCTAssertFalse(published.isProLocked)
        XCTAssertTrue(fixture.refreshService.results.isEmpty)
        withExtendedLifetime(coordinator) {}
    }

    func testForcedCallbackWithoutPublicationCannotReplyWithStaleSnapshot() throws {
        let fixture = try SurfaceProPublicationFixture()
        defer { fixture.cleanUp() }
        fixture.sender.activate { _ in }
        fixture.publishSavedResults(access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil))
        XCTAssertFalse(try fixture.watchSnapshot().isProLocked)
        var reply: [String: Any] = [:]

        XCTAssertTrue(fixture.sender.handleMessage(WatchDashboardSnapshot.snapshotRequestMessage) { reply = $0 })

        XCTAssertEqual(WatchDashboardSnapshotResponse(reply), .unavailable)
    }

    func testSnapshotAccessUsesOneCanonicalClockReadForDecisionAndEffectiveDate() async throws {
        let fixture = try SurfaceProPublicationFixture()
        defer { fixture.cleanUp() }
        let expiry = fixture.instant.addingTimeInterval(3_600)
        await fixture.deliver(.monthly, signedOffset: 0, expiry: expiry)
        fixture.clock.sample = ProEntitlementClockSample(
            wallDate: fixture.instant.addingTimeInterval(-100),
            continuousSeconds: fixture.instant.timeIntervalSince1970 + 4, continuityID: "surface-test-boot"
        )
        fixture.clock.sampleAfterRead = ProEntitlementClockSample(
            wallDate: fixture.instant.addingTimeInterval(-100),
            continuousSeconds: fixture.instant.timeIntervalSince1970 + 262_801, continuityID: "surface-test-boot"
        )
        let readsBefore = fixture.clock.readCount

        let access = SnapshotProAccess(entitlement: fixture.entitlement)

        XCTAssertEqual(fixture.clock.readCount, readsBefore + 1)
        XCTAssertFalse(access.isProLocked)
        XCTAssertEqual(access.proAccessEffectiveAt, fixture.instant.addingTimeInterval(4))
        XCTAssertEqual(access.proAccessEndsAt, expiry.addingTimeInterval(259_200))
        XCTAssertFalse(fixture.entitlement.hasAccess, "The next clock sample has already crossed the deadline")
    }

    func testEffectiveDateAloneAdvancesPublicationOrderAndPersistsAcrossRestart() async throws {
        let fixture = try SurfaceProPublicationFixture()
        defer { fixture.cleanUp() }
        await fixture.deliver(.monthly, signedOffset: 0, expiry: fixture.instant.addingTimeInterval(3_600))
        fixture.connect()
        let initial = try fixture.reply()
        fixture.clock.sample = ProEntitlementClockSample(
            wallDate: fixture.instant,
            continuousSeconds: fixture.instant.timeIntervalSince1970 + 4, continuityID: "surface-test-boot"
        )

        fixture.watchCoordinator?.publishCurrentSnapshot()

        let advanced = try fixture.watchSnapshot()
        XCTAssertEqual(advanced.accounts, initial.accounts)
        XCTAssertEqual(advanced.generatedAt, initial.generatedAt)
        XCTAssertEqual(advanced.isProLocked, initial.isProLocked)
        XCTAssertEqual(advanced.proAccessEndsAt, initial.proAccessEndsAt)
        XCTAssertEqual(advanced.proAccessEffectiveAt, fixture.instant.addingTimeInterval(4))
        XCTAssertNotEqual(try advanced.semanticData(), try initial.semanticData())
        XCTAssertGreaterThan(try XCTUnwrap(advanced.publicationSequence), try XCTUnwrap(initial.publicationSequence))
        let attempts = fixture.transport.attempts.count
        fixture.watchCoordinator?.publishCurrentSnapshot()
        XCTAssertEqual(fixture.transport.attempts.count, attempts, "An identical effective date remains deduplicated")
        let restarted = PhoneWatchConnectivityCoordinator(session: nil, defaults: fixture.transportDefaults)
        XCTAssertEqual(restarted.retainedSnapshot, advanced)
    }

    func testFirstWatchGrantAfterBothWallClocksRollbackUsesCanonicalPhoneRemainingTime() async throws {
        let fixture = try SurfaceProPublicationFixture()
        defer { fixture.cleanUp() }
        let expiry = fixture.instant.addingTimeInterval(3_600)
        let deadline = expiry.addingTimeInterval(259_200)
        await fixture.deliver(.monthly, signedOffset: 0, expiry: expiry)
        fixture.clock.sample = ProEntitlementClockSample(
            wallDate: fixture.instant.addingTimeInterval(-100),
            continuousSeconds: fixture.instant.timeIntervalSince1970 + 262_790, continuityID: "surface-test-boot"
        )
        XCTAssertTrue(fixture.entitlement.hasAccess)
        fixture.connect()
        let publication = try fixture.reply()
        XCTAssertEqual(publication.proAccessEndsAt, deadline)
        XCTAssertEqual(publication.proAccessEffectiveAt, deadline.addingTimeInterval(-10))
        XCTAssertFalse(publication.isProLocked)
        let watchClock = SurfaceWatchClock(date: fixture.clock.sample.wallDate)
        let shared = WatchComplicationSnapshotStore(
            defaults: fixture.widgetDefaults, accessClock: WatchAccessClockStore(directory: fixture.directory),
            clockSample: { _ in watchClock.sample }
        )
        try shared.saveIfChanged(publication, sample: watchClock.sample)
        XCTAssertEqual(try XCTUnwrap(shared.loadAccess()).remaining, 10)
        let loader = WatchComplicationTimelineLoader(now: { watchClock.sample.wallDate }, loadAccess: { shared.loadAccess() })
        let held = loader.entry(configuration: WatchComplicationConfigurationIntent())
        XCTAssertEqual(held.sample.availability, .value)
        let suite = fixture.widgetSuite
        let directory = fixture.directory
        let loadSnapshot: @Sendable () -> WatchDashboardSnapshot? = {
            guard let defaults = UserDefaults(suiteName: suite) else { return nil }
            return WatchComplicationSnapshotStore(
                defaults: defaults, accessClock: WatchAccessClockStore(directory: directory),
                clockSample: { _ in watchClock.sample }
            ).loadForAccess()
        }
        let accountQuery = WatchComplicationAccountQuery(loadSnapshot: loadSnapshot, now: { watchClock.sample.wallDate })
        let metricQuery = WatchComplicationMetricQuery(loadSnapshot: loadSnapshot, now: { watchClock.sample.wallDate })
        let initialAccounts = try await accountQuery.suggestedEntities()
        let initialMetrics = try await metricQuery.suggestedEntities()
        XCTAssertFalse(initialAccounts.isEmpty)
        XCTAssertFalse(initialMetrics.isEmpty)
        watchClock.advance(11)
        XCTAssertTrue(try XCTUnwrap(shared.loadForAccess()).isProLocked)
        XCTAssertEqual(held.sample.availability, .locked)
        let accounts = try await accountQuery.suggestedEntities()
        let metrics = try await metricQuery.suggestedEntities()
        XCTAssertTrue(accounts.isEmpty)
        XCTAssertTrue(metrics.isEmpty)
        XCTAssertEqual(shared.load()?.proAccessEndsAt, deadline)
    }

    private func expectBoth(
        _ fixture: SurfaceProPublicationFixture, locked: Bool, deadline: Date?,
        action: () async -> Void
    ) async {
        let widget = expectation(description: "Widget publishes committed access")
        let watch = expectation(description: "Watch publishes committed access")
        var widgetObserved = false
        var watchObserved = false
        fixture.onWidget = { snapshot in
            guard !widgetObserved, snapshot.isProLocked == locked, snapshot.proAccessEndsAt == deadline else { return }
            widgetObserved = true
            widget.fulfill()
        }
        fixture.transport.onSnapshot = { snapshot in
            guard !watchObserved, snapshot.isProLocked == locked, snapshot.proAccessEndsAt == deadline else { return }
            watchObserved = true
            watch.fulfill()
        }
        await action()
        await fulfillment(of: [widget, watch], timeout: 3)
        fixture.onWidget = nil
        fixture.transport.onSnapshot = nil
        XCTAssertEqual(fixture.widgetSnapshot.isProLocked, locked)
        XCTAssertEqual(fixture.widgetSnapshot.proAccessEndsAt, deadline)
        XCTAssertEqual(try fixture.watchSnapshot().isProLocked, locked)
        XCTAssertEqual(try fixture.watchSnapshot().proAccessEndsAt, deadline)
    }
}

@MainActor
private final class SurfaceProPublicationFixture {
    let instant = Date(timeIntervalSince1970: 1_800_000_000)
    let phoneSuite = "surface-pro-phone.\(UUID().uuidString)"
    let widgetSuite = "surface-pro-widget.\(UUID().uuidString)"
    let transportSuite = "surface-pro-transport.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let phoneDefaults: UserDefaults
    let widgetDefaults: UserDefaults
    let transportDefaults: UserDefaults
    let secretStore = MemorySecretStore()
    let configurationStore: ProviderConfigurationStore
    let historyStore: UsageHistoryStore
    let refreshService: UsageRefreshService
    let source = SurfaceProPublicationSource()
    let clock: SurfaceProPublicationClock
    let entitlement: ProEntitlement
    let transport = SurfaceProPublicationTransport()
    let sender: PhoneWatchConnectivityCoordinator
    let savedResults: [ProviderUsageResult]
    let builder: CodexBarWidgetBuilderConfiguration
    var widgetCoordinator: WidgetSnapshotCoordinator?
    var watchCoordinator: WatchSnapshotCoordinator?
    var onWidget: ((CodexBarWidgetSnapshot) -> Void)?

    var cacheURL: URL { directory.appendingPathComponent("entitlement.json") }
    var widgetSnapshot: CodexBarWidgetSnapshot { WidgetSnapshotStore.loadSnapshot(defaults: widgetDefaults) }

    init(hasResults: Bool = true) throws {
        let instant = instant
        phoneDefaults = try XCTUnwrap(UserDefaults(suiteName: phoneSuite))
        widgetDefaults = try XCTUnwrap(UserDefaults(suiteName: widgetSuite))
        transportDefaults = try XCTUnwrap(UserDefaults(suiteName: transportSuite))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        clock = SurfaceProPublicationClock(instant)
        let clock = clock
        entitlement = ProEntitlement(
            source: source, cache: ProEntitlementCache(fileURL: directory.appendingPathComponent("entitlement.json")),
            now: { clock.sample.wallDate }, clock: { _ in clock.read() }
        )
        configurationStore = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: phoneDefaults,
            secretStore: secretStore, widgetSnapshotDefaults: widgetDefaults
        )
        let store = configurationStore
        let group = try XCTUnwrap(store.addGroup(named: "Saved work"))
        let accounts = try (0..<2).map { _ in try XCTUnwrap(store.addAccount(for: .codex)) }
        for var account in accounts {
            account.groupID = group.id
            XCTAssertTrue(configurationStore.update(account))
            XCTAssertTrue(configurationStore.saveSecret("isolated-fixture-secret", for: account))
        }
        savedResults = accounts.enumerated().map { index, account in
            ProviderUsageResult(
                accountID: account.id, providerID: .codex, title: "Codex", subtitle: "Saved account \(index)",
                bars: [UsageBar(stableKey: "window", label: "Usage", used: Double(index + 1), limit: 10)],
                fetchedAt: instant
            )
        }
        let metricID = savedResults[0].bars[0].metricIdentifier(providerID: .codex, index: 0)
        configurationStore.updateVisualizationStyle(.circularRing, accountID: accounts[0].id, metricID: metricID)
        configurationStore.updateDashboardCardOrder(accounts.reversed().map(\.id))
        builder = CodexBarWidgetBuilderConfiguration(
            layout: .twoTiles, selectedTileIDs: ["bar.\(accounts[0].id).\(metricID)"], displayModes: [.compactPercent]
        )
        WidgetSnapshotStore.saveBuilderConfiguration(builder, defaults: widgetDefaults)
        historyStore = UsageHistoryStore(defaults: phoneDefaults)
        historyStore.record(results: savedResults, now: instant)
        refreshService = UsageRefreshService(providers: [], initialResults: hasResults ? savedResults : [])
        sender = PhoneWatchConnectivityCoordinator(
            session: nil, defaults: transportDefaults, sendApplicationContext: transport.send
        )
    }

    func widgetAccessContext() -> WidgetAccessContext {
        let sample = clock.sample
        let suite = widgetSuite
        return WidgetAccessContext(
            guardStore: WidgetAccessGuard(directory: directory), sample: { sample },
            currentPublication: { WidgetSnapshotStore.loadSnapshot(defaults: UserDefaults(suiteName: suite)).accessPublication }
        )
    }

    func connect(delay: Duration = .zero) {
        widgetCoordinator = WidgetSnapshotCoordinator(
            refreshService: refreshService, configurationStore: configurationStore, entitlement: entitlement,
            accessPublisher: { [weak self] results, store, access in
                guard let self else { return }
                WidgetSnapshotPublisher.publish(
                    results: results, configurationStore: store, access: access,
                    snapshotDefaults: widgetDefaults, accessGuard: WidgetAccessGuard(directory: directory), now: clock.sample.wallDate, accessSample: clock.sample
                )
                onWidget?(WidgetSnapshotStore.loadSnapshot(defaults: widgetDefaults))
            }, publishSettings: { _ in }
        )
        watchCoordinator = WatchSnapshotCoordinator(
            refreshService: refreshService, configurationStore: configurationStore, entitlement: entitlement,
            sender: sender, coalescingDelay: delay,
            accessPublisher: { [weak self] results, store, access, force in
                guard let self else { return }
                WatchSnapshotPublisher.publish(
                    results: results, configurationStore: store, access: access,
                    sender: sender, now: clock.sample.wallDate, force: force
                )
            }
        )
        watchCoordinator?.start()
    }

    func publishSavedResults(access: SnapshotProAccess, generatedAt: Date? = nil) {
        WidgetSnapshotPublisher.publish(
            results: savedResults, configurationStore: configurationStore, access: access,
            snapshotDefaults: widgetDefaults, accessGuard: WidgetAccessGuard(directory: directory), now: generatedAt ?? instant, accessSample: clock.sample
        )
        WatchSnapshotPublisher.publish(
            results: savedResults, configurationStore: configurationStore, access: access,
            sender: sender, now: generatedAt ?? instant, force: true
        )
    }

    func purchase(_ product: ProProductID, signedOffset: TimeInterval, expiry: Date?, revoked: Bool = false) -> ProPurchaseEvidence {
        ProPurchaseEvidence(
            product: product, transactionID: product == .monthly ? 1 : product == .yearly ? 2 : 3,
            purchasedAt: instant.addingTimeInterval(-3_600), signedAt: instant.addingTimeInterval(signedOffset),
            expiresAt: expiry, revoked: revoked
        )
    }

    func deliver(_ product: ProProductID, signedOffset: TimeInterval, expiry: Date?, revoked: Bool = false) async {
        await entitlement.receive(ProTransactionDelivery(
            product: product, evidence: .verified(purchase(product, signedOffset: signedOffset, expiry: expiry, revoked: revoked)),
            finish: {}
        ))
    }

    func watchSnapshot() throws -> WatchDashboardSnapshot {
        try WatchDashboardSnapshot.decode(XCTUnwrap(transport.delivered.last))
    }

    func reply() throws -> WatchDashboardSnapshot {
        var response: [String: Any] = [:]
        XCTAssertTrue(sender.handleMessage(WatchDashboardSnapshot.snapshotRequestMessage) { response = $0 })
        return try WatchDashboardSnapshot.decodeApplicationContext(response)
    }

    func entitlementBytes() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(entitlement.value)
    }

    func cleanUp() {
        widgetCoordinator = nil
        watchCoordinator = nil
        source.beforeSnapshot = nil
        source.resumeSnapshot?.resume()
        source.resumeSnapshot = nil
        phoneDefaults.removePersistentDomain(forName: phoneSuite)
        widgetDefaults.removePersistentDomain(forName: widgetSuite)
        transportDefaults.removePersistentDomain(forName: transportSuite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class SurfaceProPublicationClock {
    var sample: ProEntitlementClockSample
    var sampleAfterRead: ProEntitlementClockSample?
    private(set) var readCount = 0

    init(_ instant: Date) { sample = Self.sample(at: instant) }

    func read() -> ProEntitlementClockSample {
        readCount += 1
        let current = sample
        if let sampleAfterRead {
            sample = sampleAfterRead
            self.sampleAfterRead = nil
        }
        return current
    }

    static func sample(at instant: Date) -> ProEntitlementClockSample {
        ProEntitlementClockSample(wallDate: instant, continuousSeconds: instant.timeIntervalSince1970, continuityID: "surface-test-boot")
    }
}

@MainActor
private final class SurfaceProPublicationSource: ProStoreSource {
    var next = ProStoreSnapshot()
    var beforeSnapshot: (() async -> Void)?
    var resumeSnapshot: CheckedContinuation<Void, Never>?

    func snapshot() async -> ProStoreSnapshot { await beforeSnapshot?(); return next }
    func transactionUpdates() -> AsyncStream<ProTransactionDelivery> { AsyncStream { $0.finish() } }
    func subscriptionUpdates() -> AsyncStream<ProSubscriptionUpdate> { AsyncStream { $0.finish() } }
    func purchase(_ product: ProProductID) async throws -> ProPurchaseOutcome { .cancelled }
    func restore(refreshAppTransaction: Bool) async throws {}
}

@MainActor
private final class SurfaceProPublicationTransport {
    var fails = false
    var attempts: [Data] = []
    var delivered: [Data] = []
    var onSnapshot: ((WatchDashboardSnapshot) -> Void)?

    func send(_ context: [String: Any]) throws {
        let data = try XCTUnwrap(context[WatchDashboardSnapshot.applicationContextDataKey] as? Data)
        attempts.append(data)
        if fails { throw CocoaError(.fileWriteNoPermission) }
        delivered.append(data)
        onSnapshot?(try WatchDashboardSnapshot.decode(data))
    }
}

private final class SurfaceWatchClock: @unchecked Sendable {
    private let lock = NSLock()
    private let date: Date
    private var elapsed: TimeInterval = 0
    init(date: Date) { self.date = date }
    var sample: ProEntitlementClockSample {
        lock.withLock { ProEntitlementClockSample(wallDate: date, continuousSeconds: 500 + elapsed, continuityID: "independent-watch-boot") }
    }
    func advance(_ seconds: TimeInterval) { lock.withLock { elapsed += seconds } }
}
