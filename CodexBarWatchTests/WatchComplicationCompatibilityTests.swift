import XCTest
@testable import CodexBarWatch

final class WatchComplicationCompatibilityTests: XCTestCase {
    func testSavedGreptileMetricSurvivesQuotaModeChanges() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let resolver = WatchComplicationResolver()

        let quotaForSavedCompletedSelection = resolver.resolve(
            snapshot: snapshot(metricID: "greptile.review-quota", fraction: 1, at: now),
            selection: WatchComplicationSelection(
                accountID: "greptile.team",
                metricID: "greptile.completed-reviews"
            ),
            at: now
        )
        let completedForSavedQuotaSelection = resolver.resolve(
            snapshot: snapshot(metricID: "greptile.completed-reviews", fraction: 0.5, at: now),
            selection: WatchComplicationSelection(
                accountID: "greptile.team",
                metricID: "greptile.review-quota"
            ),
            at: now
        )

        XCTAssertEqual(quotaForSavedCompletedSelection.availability, .value)
        XCTAssertEqual(quotaForSavedCompletedSelection.exactValue, "100%")
        XCTAssertEqual(completedForSavedQuotaSelection.availability, .value)
        XCTAssertEqual(completedForSavedQuotaSelection.exactValue, "50%")
    }

    func testSavedCursorMetricsSurviveSemanticIdentityUpgrade() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let resolver = WatchComplicationResolver()

        let cursorModels = resolver.resolve(
            snapshot: snapshot(
                accountID: "cursor.personal",
                providerName: "Cursor",
                metricID: "cursor.cursor-models",
                fraction: 1.374,
                at: now
            ),
            selection: WatchComplicationSelection(
                accountID: "cursor.personal",
                metricID: "cursor.auto"
            ),
            at: now
        )
        let otherModels = resolver.resolve(
            snapshot: snapshot(
                accountID: "cursor.personal",
                providerName: "Cursor",
                metricID: "cursor.other-models",
                fraction: 1.18,
                at: now
            ),
            selection: WatchComplicationSelection(
                accountID: "cursor.personal",
                metricID: "cursor.api"
            ),
            at: now
        )

        XCTAssertEqual(cursorModels.availability, .value)
        XCTAssertEqual(cursorModels.exactValue, "137%")
        XCTAssertEqual(cursorModels.usedFraction, 1.374)
        XCTAssertEqual(cursorModels.clampedUsedFraction, 1)
        XCTAssertEqual(otherModels.availability, .value)
        XCTAssertEqual(otherModels.exactValue, "118%")
        XCTAssertEqual(otherModels.usedFraction, 1.18)
        XCTAssertEqual(otherModels.clampedUsedFraction, 1)
    }

    func testSavedFableSelectionsKeepTheirAccountAndAllowanceIdentity() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let id = "claude.weekly-scoped-fable"
        let first = WatchAccountSnapshot(id: "claude.first", providerName: "Claude", accountLabel: "First", fetchedAt: now,
                                        metrics: [WatchMetricSnapshot(id: id, label: "Fable weekly usage limit", exactValue: "21%")])
        let second = WatchAccountSnapshot(id: "claude.second", providerName: "Claude", accountLabel: "Second", fetchedAt: now,
                                         metrics: [WatchMetricSnapshot(id: id, label: "Fable weekly usage limit", exactValue: "7%")])
        let snapshot = WatchDashboardSnapshot(generatedAt: now, refreshIntervalSeconds: 300, accounts: [first, second])
        let resolver = WatchComplicationResolver()
        for (account, expected) in [(first.id, "21%"), (second.id, "7%")] {
            for alias in ["fable5", "fable51", "claudefable", "claudefable5", "claudefable51"] {
                let legacy = "claude.weekly-scoped-\(alias)"
                let selected = resolver.resolve(snapshot: snapshot,
                                                selection: WatchComplicationSelection(accountID: account, metricID: legacy), at: now)
                XCTAssertEqual(selected.exactValue, expected)
                XCTAssertEqual(selected.metricLabel, "Fable weekly usage limit")
                let choice = try XCTUnwrap(WatchComplicationChoiceCatalog(snapshot: snapshot).metrics(for: ["\(account)::\(legacy)"]).first)
                XCTAssertEqual(choice.accountID, account)
                XCTAssertEqual(choice.metricID, id)
            }
        }
        let missing = WatchAccountSnapshot(id: first.id, providerName: "Claude", accountLabel: "First", fetchedAt: now,
                                          metrics: [WatchMetricSnapshot(id: "claude.session", label: "5-hour", exactValue: "42%")])
        let absent = WatchDashboardSnapshot(generatedAt: now, refreshIntervalSeconds: 300, accounts: [missing, second])
        let legacy = WatchComplicationSelection(accountID: first.id, metricID: "claude.weekly-scoped-fable5")
        XCTAssertEqual(resolver.resolve(snapshot: absent, selection: legacy, at: now).availability, .unavailable)
        let future = WatchComplicationSelection(accountID: second.id, metricID: "claude.weekly-scoped-fableexperimental")
        XCTAssertEqual(resolver.resolve(snapshot: snapshot, selection: future, at: now).availability, .unavailable)
    }

    func testWatchGaugeTextNormalizesNegativeFractions() {
        let sample = WatchUsageSample(
            id: "negative",
            providerName: "Provider",
            accountLabel: "Account",
            metricLabel: "Usage",
            exactValue: "-5%",
            usedFraction: -0.05,
            severity: .normal,
            resetText: nil,
            visualizationStyle: .circularRing,
            freshnessText: "Updated just now"
        )

        XCTAssertEqual(sample.percentageText, "0%")
        XCTAssertEqual(sample.clampedUsedFraction, 0)
    }

    func testLinkedAccountAndMetricEntitiesResolveAcrossCanonicalAndLegacyIDs() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now, refreshIntervalSeconds: 300,
            accounts: [WatchAccountSnapshot(
                id: "claude.account", legacyAccountIDs: ["legacy-coding", "second-legacy"], providerName: "Claude",
                accountLabel: "Personal", fetchedAt: now,
                metrics: [
                    WatchMetricSnapshot(id: "claude.weekly", label: "Apps weekly", exactValue: "10%"),
                    WatchMetricSnapshot(id: "claude.five-hour", label: "Models 5h", exactValue: "20%"),
                    WatchMetricSnapshot(id: "claude.weekly", label: "Models weekly", exactValue: "31%"),
                ]
            ),
            ]
        )
        for (accountID, metricAccountID) in [
            ("legacy-coding", "claude.account"),
            ("claude.account", "legacy-coding"),
            ("legacy-coding", "second-legacy"),
        ] {
            let selection = WatchComplicationSelection.resolving(
                accountID: accountID, metricAccountID: metricAccountID,
                metricID: "claude.weekly", snapshot: snapshot
            )
            XCTAssertEqual(selection.metricID, "claude.weekly")
            XCTAssertEqual(WatchComplicationResolver().resolve(snapshot: snapshot, selection: selection, at: now).exactValue, "31%")
        }
        let appsSelection = WatchComplicationSelection.resolving(
            accountID: "legacy-coding", metricAccountID: "claude.account", metricID: "claude.weekly", snapshot: snapshot
        )
        XCTAssertEqual(WatchComplicationResolver().resolve(snapshot: snapshot, selection: appsSelection, at: now).exactValue, "10%")
        XCTAssertNil(WatchComplicationSelection.resolving(
            accountID: "legacy-coding", metricAccountID: "unrelated", metricID: "claude.weekly", snapshot: snapshot
        ).metricID)
        XCTAssertNil(WatchComplicationSelection.resolving(
            accountID: "legacy-coding", metricAccountID: "claude.account", metricID: "claude.weekly"
        ).metricID)
    }

    private func snapshot(
        accountID: String = "greptile.team",
        providerName: String = "Greptile",
        metricID: String,
        fraction: Double,
        at now: Date
    ) -> WatchDashboardSnapshot {
        WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [
                WatchAccountSnapshot(
                    id: accountID,
                    providerName: providerName,
                    accountLabel: "Team",
                    fetchedAt: now,
                    metrics: [
                        WatchMetricSnapshot(
                            id: metricID,
                            label: "Reviews",
                            usedFraction: fraction,
                            remainingFraction: 1 - fraction,
                            exactValue: "\(Int(fraction * 100))%"
                        ),
                    ]
                ),
            ]
        )
    }
}
