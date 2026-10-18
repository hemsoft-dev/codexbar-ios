import WidgetKit
import XCTest
@testable import CodexBarIOS

final class WidgetProAccessTests: XCTestCase {
    func testPersistedFiniteGrantLocksAtDecodedDeadlineAndKeepsEarlierReload() throws {
        let suiteName = "WidgetProAccessTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_800_000_000.125)
        let deadline = now.addingTimeInterval(3_600)
        WidgetSnapshotStore.saveSnapshot(Self.snapshot(at: now, deadline: deadline), defaults: defaults)
        WidgetSnapshotStore.saveRefreshInterval(.fifteenMinutes, defaults: defaults)

        let data = try XCTUnwrap(defaults.data(forKey: "widgetUsageSnapshot"))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(encoded["isProLocked"] as? Bool, false)
        XCTAssertNotNil(encoded["proAccessEndsAt"])
        let persisted = WidgetSnapshotStore.loadSnapshot(defaults: UserDefaults(suiteName: suiteName))
        let decodedDeadline = try XCTUnwrap(persisted.proAccessEndsAt)
        XCTAssertEqual(decodedDeadline, deadline)
        XCTAssertFalse(persisted.isLocked(at: decodedDeadline.addingTimeInterval(-0.001)))
        XCTAssertTrue(persisted.isLocked(at: decodedDeadline))
        XCTAssertTrue(persisted.isLocked(at: decodedDeadline.addingTimeInterval(0.001)))

        let loader = Self.loader(suiteName: suiteName, date: now)
        let plan = loader.timelinePlan(configuration: CodexBarWidgetConfigurationIntent())
        XCTAssertEqual(plan.entries.map(\.date), [now, deadline])
        XCTAssertEqual(plan.nextRefreshDate, now.addingTimeInterval(900))
        XCTAssertFalse(plan.entry.isProLocked)
        let boundaryEntry = try XCTUnwrap(plan.timeline.entries.last)
        XCTAssertTrue(boundaryEntry.isProLocked)
        XCTAssertTrue(boundaryEntry.snapshot.isProLocked)
        XCTAssertTrue(boundaryEntry.snapshot.results.isEmpty)
        XCTAssertEqual(boundaryEntry.snapshot.proAccessEndsAt, deadline)
        XCTAssertEqual(boundaryEntry.snapshot.generatedAt, now)

        for offset in [-0.001, 0, 0.001] {
            let date = decodedDeadline.addingTimeInterval(offset)
            let boundaryPlan = Self.loader(suiteName: suiteName, date: date)
                .timelinePlan(configuration: CodexBarWidgetConfigurationIntent())
            XCTAssertEqual(boundaryPlan.entry.isProLocked, offset >= 0)
            XCTAssertEqual(boundaryPlan.entries.count, offset < 0 ? 2 : 1)
            if offset < 0 {
                XCTAssertEqual(boundaryPlan.nextRefreshDate, deadline)
            }
        }
    }

    func testRepeatedPublicationDoesNotMoveDeadlineAndEqualReloadDoesNotDuplicateEntry() throws {
        let suiteName = "WidgetProAccessTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let deadline = now.addingTimeInterval(900)
        let configuration = CodexBarWidgetConfigurationIntent()
        configuration.refreshPolicy = .fifteenMinutes
        WidgetSnapshotStore.saveSnapshot(Self.snapshot(at: now, deadline: deadline), defaults: defaults)
        let initialPlan = Self.loader(suiteName: suiteName, date: now).timelinePlan(configuration: configuration)
        XCTAssertEqual(initialPlan.entries.map(\.date), [now, deadline])
        XCTAssertEqual(initialPlan.nextRefreshDate, deadline)

        let later = now.addingTimeInterval(100)
        WidgetSnapshotStore.saveSnapshot(Self.snapshot(at: later, deadline: deadline), defaults: defaults)
        let freshStorePlan = Self.loader(suiteName: suiteName, date: later).timelinePlan(configuration: configuration)
        XCTAssertEqual(freshStorePlan.entries.map(\.date), [later, deadline])
        XCTAssertEqual(freshStorePlan.entries.last?.snapshot.proAccessEndsAt, deadline)
        XCTAssertTrue(try XCTUnwrap(freshStorePlan.entries.last).isProLocked)
    }

    func testPermanentGrantAndExplicitDenialHaveNoFutureExpirationEntry() throws {
        let suiteName = "WidgetProAccessTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for locked in [false, true] {
            let snapshot = Self.snapshot(
                at: now,
                deadline: locked ? now.addingTimeInterval(900) : nil,
                locked: locked
            )
            WidgetSnapshotStore.saveSnapshot(snapshot, defaults: defaults)
            let plan = Self.loader(suiteName: suiteName, date: now)
                .timelinePlan(configuration: CodexBarWidgetConfigurationIntent())
            XCTAssertEqual(plan.entries.count, 1)
            XCTAssertEqual(plan.entry.isProLocked, locked)
            XCTAssertNil(plan.expirationEntry)
        }
    }

    func testSampleLookingLegacyPayloadAndMissingOrCorruptStorageRemainLocked() throws {
        let suiteName = "WidgetProAccessTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let loader = Self.loader(suiteName: suiteName, date: now)
        let configuration = CodexBarWidgetConfigurationIntent()
        XCTAssertTrue(loader.timelinePlan(configuration: configuration).entry.isProLocked)

        let encoded = try JSONEncoder().encode(CodexBarWidgetSnapshot.preview)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "isProLocked")
        legacy.removeValue(forKey: "proAccessEndsAt")
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "widgetUsageSnapshot")
        let legacyEntry = loader.timelinePlan(configuration: configuration).entry
        XCTAssertFalse(legacyEntry.snapshot.results.isEmpty)
        XCTAssertTrue(legacyEntry.snapshot.isProLocked)
        XCTAssertTrue(legacyEntry.isProLocked)

        legacy["isProLocked"] = "false"
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "widgetUsageSnapshot")
        XCTAssertEqual(WidgetSnapshotStore.loadSnapshot(defaults: defaults), .empty)
        XCTAssertTrue(loader.timelinePlan(configuration: configuration).entry.isProLocked)
        defaults.set(Data("not JSON".utf8), forKey: "widgetUsageSnapshot")
        XCTAssertTrue(loader.timelinePlan(configuration: configuration).entry.isProLocked)
    }

    func testGalleryAndPlaceholderIgnoreLockedProductionSnapshotAndBuilderPreferences() throws {
        let suiteName = "WidgetProAccessTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        WidgetSnapshotStore.saveSnapshot(Self.snapshot(at: now, locked: true), defaults: defaults)
        WidgetSnapshotStore.saveBuilderConfiguration(
            CodexBarWidgetBuilderConfiguration(layout: .oneTile, selectedTileIDs: ["private.saved.tile"]),
            defaults: defaults
        )
        let loader = Self.loader(suiteName: suiteName, date: now)
        let configuration = CodexBarWidgetConfigurationIntent()
        let gallery = loader.snapshot(configuration: configuration, isPreview: true)
        let placeholder = loader.placeholder(configuration: configuration)
        XCTAssertEqual(gallery.snapshot, .preview)
        XCTAssertEqual(placeholder.snapshot, .preview)
        XCTAssertFalse(gallery.isProLocked)
        XCTAssertFalse(placeholder.isProLocked)
        XCTAssertTrue(loader.snapshot(configuration: configuration, isPreview: false).isProLocked)
        XCTAssertEqual(WidgetSnapshotStore.loadBuilderConfiguration(forPreview: true, defaults: defaults), .default)
        XCTAssertEqual(
            WidgetSnapshotStore.loadBuilderConfiguration(forPreview: false, defaults: defaults).selectedTileIDs,
            ["private.saved.tile"]
        )
    }

    func testSavedAppIntentGroupTilesAliasesAndDisplayModesSurvivePersistedLockAndUnlock() async throws {
        let suiteName = "WidgetProAccessTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let grant = Self.snapshot(at: now)
        let builder = CodexBarWidgetBuilderConfiguration(
            layout: .fourTiles,
            selectedTileIDs: [
                "provider.codex.work", "bar.codex.work.weekly",
                "provider.codex.saved", "bar.codex.work.0.weekly",
            ],
            displayModes: [.compactPercent, .fullBar, .balanceOnly, .urgentStatus]
        )
        WidgetSnapshotStore.saveBuilderConfiguration(builder, defaults: defaults)
        WidgetSnapshotStore.saveSnapshot(grant, defaults: defaults)
        let savedBuilderBytes = try XCTUnwrap(defaults.data(forKey: "widgetBuilderConfiguration"))
        let groups = CodexBarWidgetGroupChoiceQuery(loadSnapshot: {
            WidgetSnapshotStore.loadSnapshot(defaults: UserDefaults(suiteName: suiteName))
        })
        let originalGroups = try await groups.entities(for: ["work"])
        let originalGroup = try XCTUnwrap(originalGroups.first)
        XCTAssertEqual(originalGroup.title, "Work")
        let tiles = CodexBarWidgetTileChoiceQuery(
            loadSnapshot: { WidgetSnapshotStore.loadSnapshot(defaults: UserDefaults(suiteName: suiteName)) },
            group: originalGroup,
            focus: .codex
        )
        let expectedUnlockedIDs = [
            "provider.codex.work", "bar.codex.work.weekly",
            "provider.codex.work", "bar.codex.work.weekly",
        ]

        for locked in [false, true, false] {
            WidgetSnapshotStore.saveSnapshot(
                locked ? Self.snapshot(at: now, locked: true) : grant,
                defaults: defaults
            )
            let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            let savedBuilder = WidgetSnapshotStore.loadBuilderConfiguration(defaults: reopenedDefaults)
            let requestedIDs = savedBuilder.selectedTileIDs.compactMap { $0 }
            let resolvedGroups = try await groups.entities(for: [originalGroup.id])
            let resolvedTiles = try await tiles.entities(for: requestedIDs)
            XCTAssertEqual(resolvedGroups.map(\.id), ["work"])
            XCTAssertEqual(resolvedGroups.map(\.title), [locked ? "Saved Group" : "Work"])
            XCTAssertEqual(resolvedTiles.map(\.id), locked ? requestedIDs : expectedUnlockedIDs)
            XCTAssertEqual(resolvedTiles.first?.title, locked ? "Saved Tile" : "Codex - Codex")
            XCTAssertEqual(savedBuilder, builder)
            XCTAssertEqual(reopenedDefaults.data(forKey: "widgetBuilderConfiguration"), savedBuilderBytes)
            XCTAssertEqual(savedBuilder.displayModes, [.compactPercent, .fullBar, .balanceOnly, .urgentStatus])
            XCTAssertEqual(
                WidgetSnapshotStore.loadSnapshot(defaults: reopenedDefaults).results,
                locked ? [] : grant.results
            )
        }
    }

    private static func loader(suiteName: String, date: Date) -> CodexBarWidgetTimelineLoader {
        CodexBarWidgetTimelineLoader(
            now: { date },
            loadSnapshot: {
                WidgetSnapshotStore.loadSnapshot(forPreview: $0, defaults: UserDefaults(suiteName: suiteName))
            },
            loadRefreshInterval: {
                WidgetSnapshotStore.loadRefreshInterval(defaults: UserDefaults(suiteName: suiteName))
            }
        )
    }

    private static func snapshot(at date: Date, deadline: Date? = nil, locked: Bool = false) -> CodexBarWidgetSnapshot {
        CodexBarWidgetSnapshot(
            generatedAt: date,
            results: locked ? [] : [
                CodexBarWidgetProviderSnapshot(
                    accountID: "codex.work",
                    providerID: "codex",
                    legacyAccountIDs: ["codex.saved"],
                    title: "Codex",
                    subtitle: "Work account",
                    groupID: "work",
                    groupName: "Work",
                    bars: [
                        CodexBarWidgetUsageBarSnapshot(
                            id: "codex.work.weekly",
                            label: "Weekly usage",
                            fractionUsed: 0.37,
                            usageText: "37%",
                            resetDescription: "Resets Friday",
                            severity: .normal
                        ),
                    ],
                    creditsRemaining: nil,
                    fetchedAt: date.addingTimeInterval(-60),
                    severity: .normal
                ),
            ],
            isProLocked: locked,
            proAccessEndsAt: deadline
        )
    }
}
