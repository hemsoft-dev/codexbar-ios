import Foundation
import XCTest
@testable import CodexBarIOS

final class ClaudeWindowLabelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_893_448_800)
    private let sessionReset = Date(timeIntervalSince1970: 1_893_456_000)
    private let weeklyReset = Date(timeIntervalSince1970: 1_894_060_800)

    func testLegacyAndStructuredWindowsIgnorePlanPrice() throws {
        let payloads = [
            #"{"five_hour":{"utilization":42,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":64,"resets_at":"2030-01-08T00:00:00Z"}}"#,
            #"""
            {"five_hour":{"utilization":42,"resets_at":"2030-01-01T00:00:00Z"},
            "seven_day_oauth_apps":{"utilization":64,"resets_at":"2030-01-08T00:00:00Z"}}
            """#,
            #"""
            {"limits":[{"kind":"session","percent":42,"resets_at":"2030-01-01T00:00:00Z"},
            {"kind":"weekly_all","group":"weekly","percent":64,"resets_at":"2030-01-08T00:00:00Z"}]}
            """#,
        ]
        for plan in ["pro", "max_20x", "max", "unknown"] {
            for payload in payloads {
                try assertWindows(XCTUnwrap(ClaudeUsageParser.parse(
                    Data(payload.utf8), subscriptionType: plan, fetchedAt: now
                )))
            }
        }
    }

    func testHeaderWindowsPreserveResetsAndValuesForProAndMax() throws {
        for plan in ["pro", "max_20x"] {
            try assertWindows(XCTUnwrap(ClaudeUsageParser.parseRateLimitHeaders(
                [
                    "anthropic-ratelimit-unified-5h-utilization": "0.42",
                    "anthropic-ratelimit-unified-5h-reset": "1893456000",
                    "anthropic-ratelimit-unified-7d-utilization": "0.64",
                    "anthropic-ratelimit-unified-7d-reset": "1894060800",
                ], subscriptionType: plan, fetchedAt: now
            )))
        }
    }

    func testIdleAndScopedWindowsKeepTheirMeaning() throws {
        for plan in ["pro", "max_20x"] {
            let idle = try XCTUnwrap(ClaudeUsageParser.parse(
                Data(#"{"limits":[{"kind":"session","percent":0,"resets_at":null,"is_active":false}]}"#.utf8),
                subscriptionType: plan, fetchedAt: now
            ))
            XCTAssertEqual(idle.bars.first?.label, "5-hour")
            XCTAssertEqual(idle.bars.first?.stableKey, "session")
            XCTAssertEqual(idle.bars.first?.used, 0)
            XCTAssertNil(idle.bars.first?.resetsAt)
            XCTAssertEqual(idle.bars.first?.projectionDescriptionOverride, "Starts when a message is sent")
        }
        let scoped = try XCTUnwrap(ClaudeUsageParser.parse(Data(#"""
            {"limits":[{"kind":"session","percent":42},
            {"kind":"session","percent":12,"scope":{"model":{"display_name":"Fable"}}},
            {"kind":"weekly_all","percent":64},
            {"kind":"weekly_scoped","percent":21,"scope":{"model":{"display_name":"Sonnet"}}}]}
            """#.utf8), subscriptionType: "max_20x", fetchedAt: now))
        XCTAssertEqual(scoped.bars.map(\.label), [
            "Other models 5-hour", "Fable current session", "Weekly", "Sonnet weekly usage limit",
        ])
        XCTAssertEqual(scoped.bars.map(\.stableKey), [
            "session", "session-scoped-fable", "weekly-all", "sonnet-weekly-limit",
        ])
    }

    @MainActor
    func testSavedLayoutHistoryAlertsWidgetAndWatchKeepIdentity() throws {
        let suite = "ClaudeWindowLabelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: ClaudeFixtureSecretStore())
        let account = try XCTUnwrap(store.addAccount(for: .claude))
        XCTAssertTrue(store.saveSecret("synthetic", for: account))
        let parsed = try XCTUnwrap(ClaudeUsageParser.parse(Data(#"""
            {"five_hour":{"utilization":42,"resets_at":"2030-01-01T00:00:00Z"},
            "seven_day":{"utilization":64,"resets_at":"2030-01-08T00:00:00Z"}}
            """#.utf8), subscriptionType: "pro", fetchedAt: now))
        let current = ProviderUsageResult(
            accountID: account.id, providerID: .claude, title: parsed.title,
            subtitle: parsed.subtitle, bars: parsed.bars, fetchedAt: now
        )
        let old = ProviderUsageResult(
            accountID: account.id, providerID: .claude, title: parsed.title,
            subtitle: parsed.subtitle, bars: [
                UsageBar(stableKey: "session", label: "Current session", used: 42, limit: 100, resetsAt: sessionReset),
                UsageBar(stableKey: "weekly-all", label: "All models", used: 64, limit: 100, resetsAt: weeklyReset),
            ], fetchedAt: now.addingTimeInterval(-60)
        )
        let metricIDs = old.availableMetrics.map(\.id)
        _ = store.reconcileMetricLayout(accountID: account.id, availableMetricIDs: metricIDs)
        store.updateMetricOrder(metricIDs.reversed(), accountID: account.id)
        store.updateMetricWidth(.full, accountID: account.id, metricID: "claude.session")
        store.updateVisualizationStyle(.circularRing, accountID: account.id, metricID: "claude.session")
        let layout = store.metricLayouts[account.id]
        _ = store.reconcileMetricLayout(accountID: account.id, availableMetricIDs: current.availableMetrics.map(\.id))
        XCTAssertEqual(store.metricLayouts[account.id], layout)
        XCTAssertEqual(current.configurableMetrics.map(\.label), ["5-hour", "Weekly"])
        let history = UsageHistoryStore(defaults: defaults)
        history.record(results: [old], now: now)
        history.record(results: [current], now: now)
        XCTAssertEqual(history.snapshots.count, 2)
        for snapshot in history.snapshots {
            XCTAssertEqual(snapshot.bars.map(\.stableKey), ["session", "weekly-all"])
            XCTAssertEqual(snapshot.bars.map(\.used), [42, 64])
            XCTAssertEqual(snapshot.bars.map(\.fractionUsed), [0.42, 0.64])
        }
        let settings = UsageAlertSettings(isEnabled: true, warningThreshold: 0.20, criticalThreshold: 0.99)
        XCTAssertEqual(
            UsageAlertEvaluator.evaluate(results: [old], settings: settings, activeAlertIDs: []).activeAlertIDs,
            UsageAlertEvaluator.evaluate(results: [current], settings: settings, activeAlertIDs: []).activeAlertIDs
        )
        WidgetSnapshotPublisher.publish(results: [old], configurationStore: store,
            access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil), now: now)
        let oldTiles = try XCTUnwrap(WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first)
        WidgetSnapshotPublisher.publish(results: [current], configurationStore: store,
            access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil), now: now)
        let snapshot = WidgetSnapshotStore.loadSnapshot(defaults: defaults)
        let tiles = try XCTUnwrap(snapshot.results.first)
        XCTAssertEqual(tiles.bars.map(\.id), oldTiles.bars.map(\.id))
        XCTAssertEqual(tiles.bars.map(\.id), ["\(account.id).0.5-hour-usage-limit", "\(account.id).weekly-usage-limit"])
        XCTAssertEqual(tiles.bars.map(\.metricID), metricIDs)
        XCTAssertEqual(tiles.bars.map(\.label), ["5-hour", "Weekly"])
        XCTAssertEqual(tiles.bars.map(\.fractionUsed), [0.42, 0.64])
        for tile in oldTiles.bars { XCTAssertNotNil(snapshot.builderTile(resolvingSavedID: "bar.\(tile.id)")) }
        let watch = WatchSnapshotPublisher.makeSnapshot(results: [current], configurationStore: store,
            access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil), now: now)
        let watchMetrics = try XCTUnwrap(watch.accounts.first).metrics
        XCTAssertEqual(watchMetrics.map(\.id), Array(metricIDs.reversed()))
        XCTAssertEqual(watchMetrics.map(\.label), ["Weekly", "5-hour"])
        XCTAssertEqual(watchMetrics.map(\.exactValue), ["64%", "42%"])
        XCTAssertEqual(watchMetrics.map(\.resetsAt), [weeklyReset, sessionReset])
        XCTAssertEqual(watchMetrics.last?.visualizationStyle, .circularRing)
    }

    @MainActor
    func testSharedSessionWidgetIDUsesExplicitKeyInsteadOfDisplayWording() throws {
        let suite = "ClaudeWindowLabelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: ClaudeFixtureSecretStore())
        let account = try XCTUnwrap(store.addAccount(for: .claude))
        XCTAssertTrue(store.saveSecret("synthetic", for: account))
        for scoped in [false, true] {
            for label in ["5-hour", "Other models 5-hour", "Localized shared window"] {
                var bars = [
                    UsageBar(
                        stableKey: "session", label: label, used: 42, limit: 100,
                        legacyWidgetKey: scoped ? "other-models-5-hour-usage-limit" : nil
                    ),
                ]
                if scoped {
                    bars.append(UsageBar(stableKey: "session-scoped-fable", label: "Fable current session", used: 12, limit: 100))
                }
                let result = ProviderUsageResult(
                    accountID: account.id, providerID: .claude, title: "Synthetic Claude",
                    subtitle: "Synthetic", bars: bars, fetchedAt: now
                )
                WidgetSnapshotPublisher.publish(results: [result], configurationStore: store,
                    access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
                    snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil), now: now)
                let tile = try XCTUnwrap(WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first?.bars.first)
                let suffix = scoped ? "other-models-5-hour-usage-limit" : "5-hour-usage-limit"
                XCTAssertEqual(tile.id, "\(account.id).0.\(suffix)")
                XCTAssertEqual(tile.label, label)
            }
        }
    }

    @MainActor
    func testMixedLegacySessionKeepsSavedTileWhenScopedSessionIsHidden() throws {
        let suite = "ClaudeWindowLabelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: ClaudeFixtureSecretStore())
        let account = try XCTUnwrap(store.addAccount(for: .claude))
        XCTAssertTrue(store.saveSecret("synthetic", for: account))
        let parsed = try XCTUnwrap(ClaudeUsageParser.parse(Data(#"""
            {"five_hour":{"utilization":42},"seven_day":{"utilization":64},
            "limits":[{"kind":"session","percent":12,"scope":{"model":{"display_name":"Fable"}}}]}
            """#.utf8), subscriptionType: "max_20x", fetchedAt: now))
        XCTAssertEqual(parsed.bars.map(\.stableKey), ["session-scoped-fable", "session", "weekly-all"])
        let all = ProviderUsageResult(
            accountID: account.id, providerID: .claude, title: "Synthetic Claude",
            subtitle: "Synthetic", bars: parsed.bars, fetchedAt: now
        )
        WidgetSnapshotPublisher.publish(results: [all], configurationStore: store,
            access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil), now: now)
        let before = try XCTUnwrap(WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first)
        XCTAssertEqual(before.bars[1].id, "\(account.id).1.5-hour-usage-limit")
        let filtered = ProviderUsageResult(
            accountID: account.id, providerID: .claude, title: all.title,
            subtitle: all.subtitle, bars: Array(parsed.bars.dropFirst()), fetchedAt: now
        )
        WidgetSnapshotPublisher.publish(results: [filtered], configurationStore: store,
            access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil), now: now)
        let snapshot = WidgetSnapshotStore.loadSnapshot(defaults: defaults)
        let saved = try XCTUnwrap(snapshot.builderTile(resolvingSavedID: "bar.\(account.id).1.5-hour-usage-limit"))
        XCTAssertEqual(saved.title, "5-hour")
        XCTAssertEqual(saved.value, "42%")
        XCTAssertEqual(saved.fractionUsed, 0.42)
    }

    private func assertWindows(_ result: ProviderUsageResult) throws {
        XCTAssertEqual(result.bars.map(\.label), ["5-hour", "Weekly"])
        XCTAssertEqual(result.bars.map(\.stableKey), ["session", "weekly-all"])
        XCTAssertEqual(result.bars.map(\.used), [42, 64])
        XCTAssertEqual(result.bars.map(\.limit), [100, 100])
        XCTAssertEqual(result.bars.map(\.resetsAt), [sessionReset, weeklyReset])
        XCTAssertEqual(result.bars.map(\.projectionPeriodStart), [
            sessionReset.addingTimeInterval(-18_000), weeklyReset.addingTimeInterval(-604_800),
        ])
        XCTAssertEqual(result.availableMetrics.map(\.id), ["claude.session", "claude.weekly-all"])
    }
}

private struct ClaudeFixtureSecretStore: SecretStore {
    func readSecret(account: String) throws -> String? { "synthetic" }
    func saveSecret(_ secret: String, account: String) throws {}
    func deleteSecret(account: String) throws {}
}
