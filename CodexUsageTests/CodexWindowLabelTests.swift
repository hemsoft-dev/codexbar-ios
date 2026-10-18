import Foundation
import XCTest
@testable import CodexBarIOS

final class CodexWindowLabelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_893_456_000)
    private let metricID = "codex.window-2592000"

    func testThirtyDayLabelPreservesValuesAndDurationIdentity() throws {
        let result = try parse(plan: "free")
        XCTAssertEqual(result.bars.map(\.label), ["Weekly usage limit", "30-day usage limit"])
        let bar = try XCTUnwrap(result.bars.last)
        XCTAssertEqual(bar.stableKey, "window-2592000")
        XCTAssertTrue(result.configurableMetrics.contains { $0.id == metricID })
        XCTAssertEqual(bar.used, 12)
        XCTAssertEqual(bar.limit, 100)
        XCTAssertEqual(bar.resetsAt, now.addingTimeInterval(86_400))
        XCTAssertEqual(bar.projectionPeriodStart, now.addingTimeInterval(86_400 - 2_592_000))
        XCTAssertEqual(bar.projectionPeriodEnd, bar.resetsAt)
    }

    func testScopedAndOtherPlanWindowsUseTheSameDurationWording() throws {
        for plan in ["free", "plus"] {
            let payload = #"{"plan_type":"\#(plan)","code_review_rate_limit":{"primary_window":{"used_percent":12,"reset_at":1893542400,"limit_window_seconds":2592000}}}"#
            let result = try XCTUnwrap(CodexUsageParser.parse(Data(payload.utf8), fetchedAt: now))
            XCTAssertEqual(result.bars.first?.label, "Code review · 30-day usage limit")
            XCTAssertEqual(result.bars.first?.stableKey, "bucket-code_5Freview.window-2592000")
        }
        for (duration, label) in [
            (18_000, "5 hour usage limit"), (604_800, "Weekly usage limit"),
            (7_200, "2 hour usage limit"), (900, "15 minute usage limit"),
        ] {
            let payload = #"{"rate_limit":{"primary_window":{"used_percent":12,"reset_at":1893542400,"limit_window_seconds":\#(duration)}}}"#
            let result = try XCTUnwrap(CodexUsageParser.parse(Data(payload.utf8), fetchedAt: now))
            XCTAssertEqual(result.bars.first?.label, label)
        }
    }

    @MainActor
    func testSavedChoicesAndWidgetIdentitySurviveTheLabelChange() throws {
        let suite = "CodexWindowLabelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: WindowLabelSecretStore())
        let account = try XCTUnwrap(store.addAccount(for: .codex))
        XCTAssertTrue(store.saveSecret("synthetic", for: account))
        let parsed = try parse(plan: "free")
        let bar = try XCTUnwrap(parsed.bars.last)
        let oldBar = UsageBar(stableKey: bar.stableKey, label: "720 hour usage limit", used: bar.used, limit: bar.limit,
                              resetsAt: bar.resetsAt, resetDisplayStyle: bar.resetDisplayStyle)
        let old = ProviderUsageResult(accountID: account.id, providerID: .codex, title: account.displayName,
                                      subtitle: "Synthetic", bars: [oldBar], fetchedAt: now)
        let current = ProviderUsageResult(accountID: account.id, providerID: .codex, title: account.displayName,
                                          subtitle: "Synthetic", bars: [bar], fetchedAt: now)
        WidgetSnapshotPublisher.publish(results: [old], configurationStore: store, snapshotDefaults: defaults, now: now)
        let oldTile = try XCTUnwrap(WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first?.bars.first)
        let savedID = "bar.\(oldTile.id)"
        store.updateMetricWidth(.full, accountID: account.id, metricID: metricID)
        store.updateMetricVisibility(false, accountID: account.id, metricID: metricID)
        _ = store.reconcileMetricLayout(accountID: account.id, availableMetricIDs: [metricID])
        XCTAssertFalse(store.isMetricVisible(accountID: account.id, metricID: metricID))
        let reloaded = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: WindowLabelSecretStore())
        XCTAssertFalse(reloaded.isMetricVisible(accountID: account.id, metricID: metricID))
        WidgetSnapshotPublisher.publish(results: [current], configurationStore: reloaded, snapshotDefaults: defaults, now: now)
        let snapshot = WidgetSnapshotStore.loadSnapshot(defaults: defaults)
        let tile = try XCTUnwrap(snapshot.results.first?.bars.first)
        XCTAssertEqual(tile.id, oldTile.id)
        XCTAssertEqual(tile.metricID, metricID)
        XCTAssertEqual(tile.label, "30-day usage limit")
        XCTAssertNotNil(snapshot.builderTile(resolvingSavedID: savedID))
        reloaded.updateMetricVisibility(true, accountID: account.id, metricID: metricID)
        let watch = WatchSnapshotPublisher.makeSnapshot(results: [current], configurationStore: reloaded, now: now)
        let metric = try XCTUnwrap(watch.accounts.first?.metrics.first)
        XCTAssertEqual(metric.id, metricID)
        XCTAssertEqual(metric.label, "30-day usage limit")
        XCTAssertEqual(metric.resetsAt, bar.resetsAt)
    }

    private func parse(plan: String) throws -> ProviderUsageResult {
        let root: [String: Any] = [
            "plan_type": plan,
            "rate_limit": [
                "primary_window": ["used_percent": 12, "reset_at": 1_893_542_400, "limit_window_seconds": 2_592_000],
                "secondary_window": ["used_percent": 34, "reset_at": 1_893_542_400, "limit_window_seconds": 604_800],
            ],
        ]
        return try XCTUnwrap(CodexUsageParser.parse(JSONSerialization.data(withJSONObject: root), fetchedAt: now))
    }
}

private struct WindowLabelSecretStore: SecretStore {
    func readSecret(account: String) throws -> String? { "synthetic" }
    func saveSecret(_ secret: String, account: String) throws {}
    func deleteSecret(account: String) throws {}
}
