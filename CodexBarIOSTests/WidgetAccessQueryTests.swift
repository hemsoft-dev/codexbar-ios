import Darwin
import XCTest
@testable import CodexBarIOS

final class WidgetAccessQueryTests: XCTestCase {
    func testActualQueriesBeforeAtAfterExpiryRollbackAndRecoveryPreserveSavedIDsAndBytes() async throws {
        let fixture = try WidgetAccessFixture()
        let original = fixture.publish()
        WidgetSnapshotStore.saveBuilderConfiguration(
            .init(layout: .fourTiles, selectedTileIDs: ["provider.codex.saved", "bar.codex.work.0.weekly"]),
            defaults: fixture.defaults
        )
        let builderBytes = fixture.defaults.data(forKey: "widgetBuilderConfiguration")
        let usageBytes = fixture.defaults.data(forKey: "widgetUsageSnapshot")
        fixture.advance(wall: 1_099.999, continuous: 599.999)
        try await checkQueries(fixture, locked: false)
        fixture.advance(wall: 1_100, continuous: 600)
        try await checkQueries(fixture, locked: true)
        fixture.advance(wall: 1_100.001, continuous: 600.001)
        try await checkQueries(fixture, locked: true)
        fixture.advance(wall: 1_050, continuous: 10, boot: "boot-B")
        try await checkQueries(fixture, locked: true)
        XCTAssertEqual(fixture.defaults.data(forKey: "widgetUsageSnapshot"), usageBytes)
        fixture.publish(anchor: fixture.recoveredAnchor())
        try await checkQueries(fixture, locked: false)
        XCTAssertEqual(fixture.defaults.data(forKey: "widgetBuilderConfiguration"), builderBytes)
        XCTAssertEqual(fixture.snapshot.results, original.results)
    }

    @MainActor
    func testPublisherRetriesNewVerifiedGrantAfterTemporaryLockFailure() throws {
        let fixture = try WidgetAccessFixture()
        fixture.publish()
        fixture.advance(wall: 1_050, continuous: 10, boot: "boot-B")
        let access = SnapshotProAccess(
            isProLocked: false, proAccessEndsAt: Date(timeIntervalSince1970: 1_100),
            clockAnchor: fixture.recoveredAnchor(), verificationGeneration: UUID()
        )
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: fixture.defaults, secretStore: MemorySecretStore())
        let descriptor = open(fixture.directory.appendingPathComponent("widget-pro-access.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        WidgetSnapshotPublisher.publish(
            results: [], configurationStore: store, access: access, snapshotDefaults: fixture.defaults,
            accessGuard: fixture.store, now: fixture.sample.wallDate, accessSample: fixture.sample
        )
        XCTAssertNotEqual(fixture.snapshot.accessPublication?.verificationGeneration, access.verificationGeneration)
        XCTAssertNil(fixture.context.effectiveDate(for: fixture.snapshot))
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        WidgetSnapshotPublisher.publish(
            results: [], configurationStore: store, access: access, snapshotDefaults: fixture.defaults,
            accessGuard: fixture.store, now: fixture.sample.wallDate, accessSample: fixture.sample
        )
        XCTAssertEqual(fixture.snapshot.accessPublication?.verificationGeneration, access.verificationGeneration)
        XCTAssertNotNil(fixture.context.effectiveDate(for: fixture.snapshot))
    }

    @MainActor
    func testPublisherCannotReinstallItsConsumedGenerationAfterExpiryStorageInvalidation() throws {
        let fixture = try WidgetAccessFixture()
        let access = SnapshotProAccess(
            isProLocked: false, proAccessEndsAt: Date(timeIntervalSince1970: 1_100),
            clockAnchor: fixture.anchor, verificationGeneration: UUID()
        )
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: fixture.defaults, secretStore: MemorySecretStore())
        WidgetSnapshotPublisher.publish(
            results: [], configurationStore: store, access: access, snapshotDefaults: fixture.defaults,
            accessGuard: fixture.store, now: fixture.sample.wallDate, accessSample: fixture.sample
        )
        let publication = try XCTUnwrap(fixture.snapshot.accessPublication)
        fixture.advance(wall: 1_100, continuous: 600)
        let failed = WidgetAccessGuard(directory: fixture.directory, write: { _, _ in throw CocoaError(.fileWriteUnknown) })
        XCTAssertNil(failed.effectiveDate(for: publication, sample: fixture.sample))
        fixture.advance(wall: 1_050, continuous: 10, boot: "boot-B")
        WidgetSnapshotPublisher.publish(
            results: [], configurationStore: store, access: access, snapshotDefaults: fixture.defaults,
            accessGuard: fixture.store, now: fixture.sample.wallDate, accessSample: fixture.sample
        )
        XCTAssertNil(fixture.context.effectiveDate(for: fixture.snapshot))
        // A repeated ordinary publication must remain denied too.
        WidgetSnapshotPublisher.publish(
            results: [], configurationStore: store, access: access, snapshotDefaults: fixture.defaults,
            accessGuard: fixture.store, now: fixture.sample.wallDate, accessSample: fixture.sample
        )
        XCTAssertNil(fixture.context.effectiveDate(for: fixture.snapshot))
    }

    private func checkQueries(_ fixture: WidgetAccessFixture, locked: Bool) async throws {
        let groups = CodexBarWidgetGroupChoiceQuery(loadSnapshot: { fixture.snapshot }, accessContext: fixture.context)
        let tiles = CodexBarWidgetTileChoiceQuery(loadSnapshot: { fixture.snapshot }, accessContext: fixture.context)
        let groupSuggestions = try await groups.suggestedEntities()
        let tileSuggestions = try await tiles.suggestedEntities()
        XCTAssertEqual(groupSuggestions.isEmpty, locked)
        XCTAssertEqual(tileSuggestions.isEmpty, locked)
        for search in ["", "Work"] {
            let found = try await groups.entities(matching: search)
            XCTAssertEqual(found.isEmpty, locked)
        }
        for search in ["", "37", "12.34"] {
            let found = try await tiles.entities(matching: search)
            if locked { XCTAssertTrue(found.isEmpty) }
        }
        let groupIDs = ["work", "saved.group"]
        let tileIDs = ["provider.codex.work", "provider.codex.saved", "bar.codex.work.0.weekly", "saved.tile"]
        let savedGroups = try await groups.entities(for: groupIDs)
        let savedTiles = try await tiles.entities(for: tileIDs)
        XCTAssertEqual(savedGroups.map(\.id), groupIDs)
        if locked {
            XCTAssertEqual(savedTiles.map(\.id), tileIDs)
            XCTAssertTrue(savedGroups.allSatisfy { $0.title == "Saved Group" })
            XCTAssertTrue(savedTiles.allSatisfy { $0.title == "Saved Tile" && $0.subtitle == "Open CodexBar to refresh" })
        } else {
            XCTAssertEqual(savedGroups.first?.title, "Work")
            XCTAssertEqual(savedTiles[1].id, "provider.codex.work")
            XCTAssertEqual(savedTiles[2].id, "bar.codex.work.weekly")
        }
    }
}
