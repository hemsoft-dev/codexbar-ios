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

    @MainActor
    func testGreptilePreferenceSurvivesQuotaAvailabilityChanges() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let accountID = "greptile.team"
        let completedID = GreptileUsageIdentity.completedReviewsMetricID
        let quotaID = GreptileUsageIdentity.reviewQuotaMetricID
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: EmptySecretStore()
        )
        _ = store.reconcileMetricLayout(accountID: accountID, availableMetricIDs: [completedID])
        store.updateMetricVisibility(false, accountID: accountID, metricID: completedID)
        store.updateVisualizationStyle(.circularRing, accountID: accountID, metricID: completedID)
        store.updateMetricWidth(.half, accountID: accountID, metricID: completedID)
        store.updateWatchMetricVisibility(.show, accountID: accountID, metricID: completedID)

        let quotaLayout = store.reconcileMetricLayout(
            accountID: accountID,
            availableMetricIDs: [quotaID]
        )
        let quotaPreference = try XCTUnwrap(quotaLayout.preferences[quotaID])
        XCTAssertEqual(quotaLayout.orderedMetricIDs, [quotaID])
        XCTAssertNil(quotaLayout.preferences[completedID])
        XCTAssertFalse(quotaPreference.isVisible)
        XCTAssertEqual(quotaPreference.visualizationStyle, .circularRing)
        XCTAssertEqual(quotaPreference.width, .half)
        XCTAssertEqual(quotaPreference.watchVisibility, .show)
        XCTAssertFalse(quotaPreference.isNewlyDiscovered)

        let completedLayout = store.reconcileMetricLayout(
            accountID: accountID,
            availableMetricIDs: [completedID]
        )
        XCTAssertEqual(completedLayout.orderedMetricIDs, [completedID])
        XCTAssertEqual(completedLayout.preferences[completedID], quotaPreference)
        XCTAssertNil(completedLayout.preferences[quotaID])
    }

    @MainActor
    func testGreptilePreferenceMigrationDoesNotTreatViewingDestinationAsCustomization() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let accountID = "greptile.team"
        let completedID = GreptileUsageIdentity.completedReviewsMetricID
        let quotaID = GreptileUsageIdentity.reviewQuotaMetricID
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: EmptySecretStore()
        )
        _ = store.reconcileMetricLayout(
            accountID: accountID,
            availableMetricIDs: [completedID, quotaID]
        )
        store.updateMetricVisibility(false, accountID: accountID, metricID: completedID)
        store.updateVisualizationStyle(.circularRing, accountID: accountID, metricID: completedID)
        store.updateMetricWidth(.half, accountID: accountID, metricID: completedID)
        store.updateWatchMetricVisibility(.show, accountID: accountID, metricID: completedID)
        store.markMetricsSeen([quotaID], accountID: accountID)

        let migrated = store.reconcileMetricLayout(
            accountID: accountID,
            availableMetricIDs: [quotaID]
        )
        let preference = try XCTUnwrap(migrated.preferences[quotaID])

        XCTAssertNil(migrated.preferences[completedID])
        XCTAssertFalse(preference.isVisible)
        XCTAssertEqual(preference.visualizationStyle, .circularRing)
        XCTAssertEqual(preference.width, .half)
        XCTAssertEqual(preference.watchVisibility, .show)
    }

    @MainActor
    func testGreptilePreferenceMigrationPreservesSeenDestinationState() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let accountID = "greptile.team"
        let completedID = GreptileUsageIdentity.completedReviewsMetricID
        let quotaID = GreptileUsageIdentity.reviewQuotaMetricID
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: EmptySecretStore()
        )
        _ = store.reconcileMetricLayout(
            accountID: accountID,
            availableMetricIDs: [completedID, quotaID]
        )
        store.markMetricsSeen([quotaID], accountID: accountID)

        let migrated = store.reconcileMetricLayout(
            accountID: accountID,
            availableMetricIDs: [quotaID]
        )

        XCTAssertFalse(try XCTUnwrap(migrated.preferences[quotaID]).isNewlyDiscovered)
    }

    @MainActor
    func testGreptilePreferenceMigrationPreservesSourceWhenDestinationIsCustomized() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let accountID = "greptile.team"
        let completedID = GreptileUsageIdentity.completedReviewsMetricID
        let quotaID = GreptileUsageIdentity.reviewQuotaMetricID
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: EmptySecretStore()
        )
        _ = store.reconcileMetricLayout(
            accountID: accountID,
            availableMetricIDs: [completedID, quotaID]
        )
        store.updateMetricVisibility(false, accountID: accountID, metricID: completedID)
        store.updateMetricWidth(.half, accountID: accountID, metricID: quotaID)

        let migrated = store.reconcileMetricLayout(
            accountID: accountID,
            availableMetricIDs: [quotaID]
        )

        XCTAssertFalse(try XCTUnwrap(migrated.preferences[completedID]).isVisible)
        XCTAssertEqual(try XCTUnwrap(migrated.preferences[quotaID]).width, .half)
    }

    @MainActor
    func testCopyMetricLayoutMapsGreptileIdentityAcrossQuotaModes() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: EmptySecretStore())
        let metricPairs = [
            (
                GreptileUsageIdentity.completedReviewsMetricID,
                GreptileUsageIdentity.reviewQuotaMetricID
            ),
            (
                GreptileUsageIdentity.reviewQuotaMetricID,
                GreptileUsageIdentity.completedReviewsMetricID
            ),
        ]

        for (index, metricPair) in metricPairs.enumerated() {
            let sourceAccountID = "greptile.source.\(index)"
            let destinationAccountID = "greptile.destination.\(index)"
            _ = store.reconcileMetricLayout(
                accountID: sourceAccountID,
                availableMetricIDs: [metricPair.0]
            )
            store.updateMetricVisibility(false, accountID: sourceAccountID, metricID: metricPair.0)
            store.updateVisualizationStyle(.circularRing, accountID: sourceAccountID, metricID: metricPair.0)
            store.updateMetricWidth(.half, accountID: sourceAccountID, metricID: metricPair.0)
            store.updateWatchMetricVisibility(.show, accountID: sourceAccountID, metricID: metricPair.0)
            _ = store.reconcileMetricLayout(
                accountID: destinationAccountID,
                availableMetricIDs: [metricPair.0, metricPair.1]
            )
            store.updateMetricWidth(.full, accountID: destinationAccountID, metricID: metricPair.1)
            let retainedDestination = store.reconcileMetricLayout(
                accountID: destinationAccountID,
                availableMetricIDs: [metricPair.1]
            )
            XCTAssertNotNil(retainedDestination.preferences[metricPair.0])

            store.copyMetricLayout(
                from: sourceAccountID,
                to: destinationAccountID,
                destinationAvailableMetricIDs: [metricPair.1]
            )

            let copied = try XCTUnwrap(store.metricLayouts[destinationAccountID])
            XCTAssertEqual(copied.orderedMetricIDs, [metricPair.1])
            let preference = try XCTUnwrap(copied.preferences[metricPair.1])
            XCTAssertFalse(preference.isVisible)
            XCTAssertEqual(preference.visualizationStyle, .circularRing)
            XCTAssertEqual(preference.width, .half)
            XCTAssertEqual(preference.watchVisibility, .show)
            XCTAssertFalse(preference.isNewlyDiscovered)
        }
    }
}
