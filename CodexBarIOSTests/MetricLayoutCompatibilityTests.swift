import XCTest
@testable import CodexBarIOS

final class MetricLayoutCompatibilityTests: XCTestCase {
    @MainActor
    func testCursorModelBucketIdentitiesPreserveLegacyPresentationPreferences() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let accountID = "cursor.personal"
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        _ = store.reconcileMetricLayout(
            accountID: accountID,
            availableMetricIDs: [
                CursorUsageIdentity.legacyTotalMetricID,
                CursorUsageIdentity.legacyCursorModelsMetricID,
                CursorUsageIdentity.legacyOtherModelsMetricID,
            ]
        )
        store.updateMetricVisibility(
            false,
            accountID: accountID,
            metricID: CursorUsageIdentity.legacyCursorModelsMetricID
        )
        store.updateVisualizationStyle(
            .circularRing,
            accountID: accountID,
            metricID: CursorUsageIdentity.legacyOtherModelsMetricID
        )
        store.updateWatchMetricVisibility(
            .show,
            accountID: accountID,
            metricID: CursorUsageIdentity.legacyOtherModelsMetricID
        )

        let migrated = store.reconcileMetricLayout(
            accountID: accountID,
            availableMetricIDs: [
                CursorUsageIdentity.cursorModelsMetricID,
                CursorUsageIdentity.otherModelsMetricID,
            ]
        )

        XCTAssertEqual(
            migrated.orderedMetricIDs,
            [CursorUsageIdentity.cursorModelsMetricID, CursorUsageIdentity.otherModelsMetricID]
        )
        XCTAssertNil(migrated.preferences[CursorUsageIdentity.legacyCursorModelsMetricID])
        XCTAssertNil(migrated.preferences[CursorUsageIdentity.legacyOtherModelsMetricID])
        XCTAssertNil(migrated.preferences[CursorUsageIdentity.legacyTotalMetricID])
        XCTAssertFalse(try XCTUnwrap(
            migrated.preferences[CursorUsageIdentity.cursorModelsMetricID]
        ).isVisible)
        let otherModelsPreference = try XCTUnwrap(
            migrated.preferences[CursorUsageIdentity.otherModelsMetricID]
        )
        XCTAssertEqual(otherModelsPreference.visualizationStyle, .circularRing)
        XCTAssertEqual(otherModelsPreference.watchVisibility, .show)
    }

}
