import Foundation
import XCTest
@testable import CodexBarIOS

final class CodexCreditsPoolTests: XCTestCase {
    private let metricID = CodexUsageParser.creditsPoolMetricID
    private let now = Date(timeIntervalSince1970: 1_893_448_800)

    func testBalancesUseCreditUnitsAndPreserveQuotaIdentity() throws {
        for (balance, expected, tileValue) in [
            ("62500", "62,500 credits", "62,500"), ("0", "0 credits", "0"), ("1", "1 credit", "1"),
            ("12.125", "12 credits", "12"), ("62500.75", "62,501 credits", "62,501"),
            ("0.49", "0 credits", "0"), ("0.5", "1 credit", "1"), ("1.2", "1 credit", "1"),
            ("1.5", "2 credits", "2"), ("999.5", "1,000 credits", "1,000"),
        ] {
            let result = try parse(credits: ["has_credits": balance != "0", "unlimited": false, "balance": balance])
            let pool = try XCTUnwrap(result.bars.last)
            XCTAssertEqual(pool.stableKey, "credits-pool")
            XCTAssertEqual(pool.usageText, expected)
            XCTAssertEqual(pool.metricTileValueText, tileValue)
            let original = try XCTUnwrap(Double(balance))
            XCTAssertEqual(pool.used, original, accuracy: max(original * 1e-12, 1e-112),
                           "Display rounding must preserve the balance")
            XCTAssertTrue(pool.isUnboundedNumeric)
            XCTAssertEqual(pool.supportedVisualizationStyles, [.automatic, .largeNumeric])
            XCTAssertEqual(pool.severity, .normal)
            XCTAssertNil(pool.resetsAt)
            XCTAssertNil(pool.projectedFraction(at: now))
            XCTAssertEqual(result.bars.dropLast().map(\.used), [12, 34])
            XCTAssertEqual(result.bars.dropLast().map(\.metricTileValueText), ["12%", "34%"])
            XCTAssertEqual(result.configurableMetrics.map(\.id), ["codex.window-18000", "codex.window-604800", metricID])
            XCTAssertNil(result.creditsRemaining, "Counts must never enter the money path")
        }
        let numeric = try parse(credits: ["has_credits": true, "unlimited": false, "balance": 62500])
        XCTAssertEqual(numeric.bars.last?.usageText, "62,500 credits")
        let tiny = try parse(credits: ["has_credits": true, "unlimited": false, "balance": "1e-100"])
        XCTAssertEqual(tiny.bars.last?.usageText, "0 credits")
        XCTAssertEqual(try XCTUnwrap(tiny.bars.last).used, 1e-100, accuracy: 1e-112)
    }

    func testInvalidOrMissingBalancesNeverBecomeZero() throws {
        for value: Any in [NSNull(), true, false, -1, "-1", "NaN", "Infinity", "1e999", "1e-999", "62500 credits", "12,500", "", [], ["value": 1]] {
            let result = try parse(credits: ["has_credits": true, "unlimited": false, "balance": value])
            XCTAssertEqual(result.bars.count, 2)
            XCTAssertEqual(result.configurableMetrics.last?.kind, .unavailableUsage("Credits unavailable"))
        }
        let invalidCredits: [Any] = [
            NSNull(), [], 0, ["has_credits": true], ["unlimited": false, "balance": "62500"],
            ["has_credits": 1, "unlimited": false, "balance": "62500"],
            ["has_credits": true, "unlimited": 0, "balance": "62500"],
        ]
        for credits in invalidCredits {
            XCTAssertEqual(try parse(credits: credits).bars.count, 2)
        }
    }

    func testUnlimitedRemainsDistinctFromMissingAndZero() throws {
        let result = try parse(credits: ["has_credits": true, "unlimited": true, "balance": NSNull()])
        XCTAssertEqual(result.bars.count, 2)
        XCTAssertEqual(result.configurableMetrics.last?.kind, .unavailableUsage("Unlimited credits"))
        let poolOnly = try XCTUnwrap(CodexUsageParser.parse(Data(#"{"credits":{"has_credits":true,"unlimited":true}}"#.utf8)))
        XCTAssertEqual(poolOnly.configurableMetrics.first?.kind, .unavailableUsage("Unlimited credits"))
    }

    func testCreditOnlyResponseIsUsefulAndLocaleAware() throws {
        let data = Data(#"{"credits":{"has_credits":true,"unlimited":false,"balance":"62500.5"}}"#.utf8)
        let result = try XCTUnwrap(CodexUsageParser.parse(data, fetchedAt: now, locale: Locale(identifier: "de_DE")))
        XCTAssertEqual(result.bars.first?.usageText, "62.501 credits")
        XCTAssertEqual(result.bars.first?.metricTileValueText, "62.501")
        XCTAssertEqual(result.availableMetrics.first?.id, metricID)
        let absent = try XCTUnwrap(CodexUsageParser.parse(Data(#"{"credits":{"has_credits":false,"unlimited":false,"balance":null}}"#.utf8)))
        XCTAssertTrue(absent.bars.isEmpty)
        XCTAssertEqual(absent.configurableMetrics.first?.kind, .unavailableUsage("Credits unavailable"))
    }

    @MainActor
    func testDefaultsPersistenceAbsenceAndAccountIsolation() throws {
        let suite = "CodexCreditsPoolTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: CreditsFixtureSecretStore())
        let ids = ["codex.window-18000", "codex.window-604800", metricID]
        XCTAssertFalse(store.isMetricVisible(accountID: "one", metricID: metricID))
        XCTAssertTrue(store.isMetricVisible(accountID: "one", metricID: ids[0]))
        _ = store.reconcileMetricLayout(accountID: "one", availableMetricIDs: Array(ids.dropLast()))
        store.updateMetricVisibility(false, accountID: "one", metricID: ids[1])
        _ = store.reconcileMetricLayout(accountID: "one", availableMetricIDs: ids)
        XCTAssertFalse(store.isMetricVisible(accountID: "one", metricID: ids[1]), "Preserve an existing quota choice during migration")
        _ = store.reconcileMetricLayout(accountID: "two", availableMetricIDs: ids)
        XCTAssertFalse(store.isMetricVisible(accountID: "one", metricID: metricID))
        store.updateMetricVisibility(true, accountID: "one", metricID: metricID)
        store.updateMetricOrder(Array(ids.reversed()), accountID: "one")
        _ = store.reconcileMetricLayout(accountID: "one", availableMetricIDs: Array(ids.dropLast()))
        _ = store.reconcileMetricLayout(accountID: "one", availableMetricIDs: ids)
        let reloaded = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: CreditsFixtureSecretStore())
        XCTAssertTrue(reloaded.isMetricVisible(accountID: "one", metricID: metricID))
        XCTAssertFalse(reloaded.isMetricVisible(accountID: "two", metricID: metricID))
        XCTAssertEqual(reloaded.metricOrder(accountID: "one", availableMetricIDs: ids), Array(ids.reversed()))
        reloaded.updateMetricVisibility(false, accountID: "one", metricID: metricID)
        _ = reloaded.reconcileMetricLayout(accountID: "one", availableMetricIDs: ids)
        XCTAssertFalse(reloaded.isMetricVisible(accountID: "one", metricID: metricID))
    }

    @MainActor
    func testPreferenceEditingAndResetKeepOptInDefault() throws {
        let suite = "CodexCreditsPoolTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: CreditsFixtureSecretStore())
        _ = store.reconcileMetricLayout(accountID: "one", availableMetricIDs: [metricID])
        XCTAssertFalse(store.isMetricLayoutCustomized(accountID: "one", availableMetricIDs: [metricID]))
        XCTAssertTrue(GoogleUsageMetricCatalog.layoutCopyMetricIDs(for: .codex, result: nil).isEmpty)
        XCTAssertEqual(GoogleUsageMetricCatalog.layoutCopyMetricIDs(for: .codex, result: try parse(credits: NSNull())).count, 3)
        store.updateMetricWidth(.full, accountID: "one", metricID: metricID)
        XCTAssertFalse(store.isMetricVisible(accountID: "one", metricID: metricID))
        store.updateMetricOrder([metricID], accountID: "two")
        XCTAssertFalse(store.isMetricVisible(accountID: "two", metricID: metricID))
        store.copyMetricLayout(from: "two", to: "one", destinationAvailableMetricIDs: [metricID, "codex.window-18000"])
        XCTAssertFalse(store.isMetricVisible(accountID: "one", metricID: metricID))
        store.updateMetricVisibility(true, accountID: "one", metricID: metricID)
        store.copyMetricLayout(from: "one", to: "two", destinationAvailableMetricIDs: [metricID])
        XCTAssertTrue(store.isMetricVisible(accountID: "two", metricID: metricID), "An explicit Copy Layout can copy an opt-in")
        store.resetMetricLayout(accountID: "one", availableMetricIDs: [metricID, "codex.window-18000"])
        XCTAssertFalse(store.isMetricVisible(accountID: "one", metricID: metricID))
        XCTAssertTrue(store.isMetricVisible(accountID: "one", metricID: "codex.window-18000"))
    }

    @MainActor
    func testCountHasNoAlertsAndWidgetSelectionIsIndependentOfWatchVisibility() throws {
        let suite = "CodexCreditsPoolTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: CreditsFixtureSecretStore())
        let account = try XCTUnwrap(store.addAccount(for: .codex))
        XCTAssertTrue(store.saveSecret("synthetic", for: account))
        let parsed = try parse(credits: ["has_credits": true, "unlimited": false, "balance": "62500.75"])
        let result = ProviderUsageResult(accountID: account.id, providerID: .codex, title: account.displayName,
                                         subtitle: parsed.subtitle, bars: parsed.bars, fetchedAt: now)
        let watch = WatchSnapshotPublisher.makeSnapshot(results: [result], configurationStore: store, now: now)
        XCTAssertFalse(try XCTUnwrap(watch.accounts.first).metrics.contains { $0.id == metricID })
        WidgetSnapshotPublisher.publish(results: [result], configurationStore: store, snapshotDefaults: defaults, now: now)
        let snapshot = WidgetSnapshotStore.loadSnapshot(defaults: defaults)
        let tile = try XCTUnwrap(snapshot.results.first?.bars.first { $0.metricID == metricID })
        XCTAssertEqual(tile.usageText, "62,501 credits")
        XCTAssertEqual(tile.allowsGauge, false)
        let savedID = "bar.\(tile.id)"
        XCTAssertNotNil(snapshot.builderTile(resolvingSavedID: savedID))
        store.updateMetricVisibility(true, accountID: account.id, metricID: metricID)
        let shown = WatchSnapshotPublisher.makeSnapshot(results: [result], configurationStore: store, now: now)
        let watchPool = try XCTUnwrap(shown.accounts.first?.metrics.first { $0.id == metricID })
        XCTAssertEqual(watchPool.exactValue, "62,501 credits")
        XCTAssertNil(watchPool.usedFraction)
        XCTAssertEqual(watchPool.visualizationStyle, .largeNumeric)
        let poolOnly = ProviderUsageResult(accountID: account.id, providerID: .codex, title: result.title,
                                           subtitle: result.subtitle, bars: [try XCTUnwrap(parsed.bars.last)], fetchedAt: now)
        XCTAssertTrue(UsageAlertEvaluator.evaluate(results: [poolOnly], settings: UsageAlertSettings(isEnabled: true),
                                                   activeAlertIDs: []).activeAlertIDs.isEmpty)
        store.updateMetricVisibility(false, accountID: account.id, metricID: metricID)
        WidgetSnapshotPublisher.publish(results: [result], configurationStore: store, snapshotDefaults: defaults, now: now)
        XCTAssertNotNil(WidgetSnapshotStore.loadSnapshot(defaults: defaults).builderTile(resolvingSavedID: savedID))
    }

    @MainActor
    func testCreditCountsNeverEnterQuotaHistory() throws {
        let suite = "CodexCreditHistory.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = UsageHistoryStore(defaults: defaults)
        let mixed = try parse(credits: ["has_credits": true, "unlimited": false, "balance": "62500"])
        let countOnly = ProviderUsageResult(providerID: .codex, title: "Synthetic", subtitle: "",
                                           bars: [try XCTUnwrap(mixed.bars.last)], fetchedAt: now)
        history.record(results: [countOnly], now: now)
        XCTAssertTrue(history.snapshots(for: countOnly.accountID).isEmpty)
        XCTAssertTrue(history.historySeries(for: countOnly).points.isEmpty)
        XCTAssertTrue(history.historySeriesOptions(for: countOnly).isEmpty)
        XCTAssertTrue(GoogleUsageMetricCatalog.layoutCopyMetricIDs(for: .codex, result: countOnly).isEmpty)
        let unavailableOnly = ProviderUsageResult(providerID: .codex, title: "Synthetic", subtitle: "", bars: [],
                                                 unavailableUsageMetrics: [metricID: "Credits unavailable"], fetchedAt: now)
        XCTAssertTrue(GoogleUsageMetricCatalog.layoutCopyMetricIDs(for: .codex, result: unavailableOnly).isEmpty)
        history.record(results: [mixed], now: now)
        XCTAssertEqual(history.snapshots(for: mixed.accountID).last?.bars.count, 2)
        XCTAssertEqual(try XCTUnwrap(history.historySeries(for: mixed).points.last).value, 0.34, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(history.historySeries(for: countOnly).points.last).value, 0.34, accuracy: 0.000001)
        XCTAssertFalse(history.historySeriesOptions(for: countOnly).isEmpty, "Existing quota history remains available")
    }

    @MainActor
    func testWatchTextStatesRespectExistingVisibilityPolicy() throws {
        let suite = "CodexCreditsWatch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: CreditsFixtureSecretStore())
        let account = try XCTUnwrap(store.addAccount(for: .codex))
        XCTAssertTrue(store.saveSecret("synthetic", for: account))
        for (unlimited, expected) in [(true, "Unlimited credits"), (false, "Credits unavailable")] {
            let parsed = try parse(credits: ["has_credits": unlimited, "unlimited": unlimited, "balance": NSNull()])
            let result = ProviderUsageResult(accountID: account.id, providerID: .codex, title: "Synthetic", subtitle: "",
                                             bars: parsed.bars, unavailableUsageMetrics: parsed.unavailableUsageMetrics, fetchedAt: now)
            store.updateMetricVisibility(true, accountID: account.id, metricID: metricID)
            let metric = try XCTUnwrap(WatchSnapshotPublisher.makeSnapshot(results: [result], configurationStore: store, now: now)
                .accounts.first?.metrics.first { $0.id == metricID })
            XCTAssertEqual(metric.exactValue, expected)
            XCTAssertNil(metric.usedFraction)
            XCTAssertEqual(metric.visualizationStyle, .statusText)
            XCTAssertEqual(metric.visualizationStyle.resolvedForWatch(allowsGauge: false), .statusText)
            XCTAssertFalse(metric.visualizationStyle.showsHeaderExactValueOnWatch(allowsGauge: false))
            store.updateMetricVisibility(false, accountID: account.id, metricID: metricID)
            XCTAssertFalse(WatchSnapshotPublisher.makeSnapshot(results: [result], configurationStore: store, now: now)
                .accounts.first?.metrics.contains { $0.id == metricID } ?? false)
            store.updateWatchMetricVisibility(.show, accountID: account.id, metricID: metricID)
            XCTAssertTrue(WatchSnapshotPublisher.makeSnapshot(results: [result], configurationStore: store, now: now)
                .accounts.first?.metrics.contains { $0.id == metricID } ?? false)
            store.updateWatchMetricVisibility(.inherit, accountID: account.id, metricID: metricID)
            XCTAssertFalse(WatchSnapshotPublisher.makeSnapshot(results: [result], configurationStore: store, now: now)
                .accounts.first?.metrics.contains { $0.id == metricID } ?? false)
        }
    }

    private func parse(credits: Any) throws -> ProviderUsageResult {
        let root: [String: Any] = [
            "credits": credits,
            "rate_limit": [
                "primary_window": ["used_percent": 12, "reset_at": 1_893_456_000, "limit_window_seconds": 18000],
                "secondary_window": ["used_percent": 34, "reset_at": 1_894_060_800, "limit_window_seconds": 604800],
            ],
        ]
        return try XCTUnwrap(CodexUsageParser.parse(JSONSerialization.data(withJSONObject: root), fetchedAt: now,
                                                  locale: Locale(identifier: "en_US")))
    }
}

private struct CreditsFixtureSecretStore: SecretStore {
    func readSecret(account: String) throws -> String? { "synthetic" }
    func saveSecret(_ secret: String, account: String) throws {}
    func deleteSecret(account: String) throws {}
}
