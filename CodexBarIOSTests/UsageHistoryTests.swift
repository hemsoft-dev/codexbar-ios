import XCTest
@testable import CodexBarIOS

final class UsageHistoryTests: XCTestCase {
    @MainActor
    func testGreptileHistoryStoresCompletedReviewCountsAsNumbers() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UsageHistoryStore(defaults: defaults)
        let dates = [
            Date(timeIntervalSince1970: 1_788_475_200),
            Date(timeIntervalSince1970: 1_788_561_600),
        ]

        for (index, date) in dates.enumerated() {
            let count = 12 + index * 3
            store.record(
                results: [
                    ProviderUsageResult(
                        accountID: "greptile.team",
                        providerID: .greptile,
                        title: "Greptile",
                        subtitle: "All available review history",
                        bars: [
                            UsageBar(
                                stableKey: GreptileUsageIdentity.completedReviewsStableKey,
                                label: "Completed reviews",
                                used: Double(count),
                                limit: 0,
                                fractionlessUsageText: count.formatted()
                            ),
                        ],
                        fetchedAt: date
                    ),
                ],
                now: dates.last!
            )
        }

        let result = ProviderUsageResult(
            accountID: "greptile.team",
            providerID: .greptile,
            title: "Greptile",
            subtitle: "All available review history",
            bars: [
                UsageBar(
                    stableKey: GreptileUsageIdentity.completedReviewsStableKey,
                    label: "Completed reviews",
                    used: 15,
                    limit: 0,
                    fractionlessUsageText: "15"
                ),
            ],
            fetchedAt: dates.last!
        )
        let option = store.historySeriesOptions(for: result).first

        XCTAssertEqual(option?.id, GreptileUsageIdentity.completedReviewsHistorySeriesID)
        XCTAssertEqual(option?.label, "Completed reviews")
        XCTAssertEqual(option?.series.points.map(\.value), [12, 15])
        XCTAssertEqual(option?.series.latestValueDescription, "15")
        XCTAssertEqual(option?.series.changeDescription, "Up 3")
        XCTAssertTrue(option?.series.isCount == true)
        XCTAssertFalse(option?.series.showsQuotaLimitRule == true)
        XCTAssertEqual(
            store.trendSummary(for: result, now: dates.last!)?.valueDescription,
            "Changed +3"
        )

    }

    @MainActor
    func testGreptileQuotaHistoryDoesNotMixWithCompletedReviewHistory() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UsageHistoryStore(defaults: defaults)
        let dates = [
            Date(timeIntervalSince1970: 1_788_475_200),
            Date(timeIntervalSince1970: 1_788_561_600),
            Date(timeIntervalSince1970: 1_788_648_000),
            Date(timeIntervalSince1970: 1_788_734_400),
        ]

        let completedResult = ProviderUsageResult(
            accountID: "greptile.team",
            providerID: .greptile,
            title: "Greptile",
            subtitle: "All available review history",
            bars: [
                UsageBar(
                    stableKey: GreptileUsageIdentity.completedReviewsStableKey,
                    label: "Completed reviews",
                    used: 50,
                    limit: 0,
                    fractionlessUsageText: "50"
                ),
            ],
            fetchedAt: dates[0]
        )
        store.record(results: [completedResult], now: dates.last!)

        var quotaResult = ProviderUsageResult(
            accountID: "greptile.team",
            providerID: .greptile,
            title: "Greptile",
            subtitle: "Current billing period",
            bars: [
                UsageBar(
                    stableKey: GreptileUsageIdentity.reviewQuotaStableKey,
                    label: "Reviews used",
                    used: 1,
                    limit: 50
                ),
            ],
            fetchedAt: dates[1]
        )
        store.record(results: [quotaResult], now: dates.last!)
        quotaResult = ProviderUsageResult(
            accountID: "greptile.team",
            providerID: .greptile,
            title: "Greptile",
            subtitle: "Current billing period",
            bars: [
                UsageBar(
                    stableKey: GreptileUsageIdentity.reviewQuotaStableKey,
                    label: "Reviews used",
                    used: 2,
                    limit: 50
                ),
            ],
            fetchedAt: dates[2]
        )
        store.record(results: [quotaResult], now: dates.last!)

        let options = store.historySeriesOptions(for: quotaResult)
        XCTAssertEqual(options.map(\.id), [
            GreptileUsageIdentity.reviewQuotaHistorySeriesID,
            GreptileUsageIdentity.completedReviewsHistorySeriesID,
        ])
        XCTAssertEqual(options[0].series.points.map(\.value), [1, 2])
        XCTAssertEqual(options[1].series.points.map(\.value), [50])
        XCTAssertEqual(
            store.trendSummary(for: quotaResult, now: dates.last!)?.valueDescription,
            "Changed +1"
        )

        let combinedResult = ProviderUsageResult(
            accountID: quotaResult.accountID,
            providerID: .greptile,
            title: "Greptile",
            subtitle: "Current billing period",
            bars: completedResult.bars + quotaResult.bars,
            fetchedAt: dates[2]
        )
        XCTAssertEqual(UsageHistorySnapshot(result: combinedResult).primaryValue, 2)
        XCTAssertEqual(
            store.historySeriesOptions(for: combinedResult).first?.id,
            GreptileUsageIdentity.reviewQuotaHistorySeriesID
        )
        XCTAssertEqual(store.historySeries(for: combinedResult).points.map(\.value), [1, 2])

        let currentCompletedResult = ProviderUsageResult(
            accountID: completedResult.accountID,
            providerID: .greptile,
            title: "Greptile",
            subtitle: "All available review history",
            bars: completedResult.bars,
            fetchedAt: dates[3]
        )
        XCTAssertEqual(
            store.historySeriesOptions(for: currentCompletedResult).map(\.id),
            [
                GreptileUsageIdentity.completedReviewsHistorySeriesID,
                GreptileUsageIdentity.reviewQuotaHistorySeriesID,
            ]
        )
        store.record(results: [currentCompletedResult], now: dates[3])

        let staleQuotaResult = ProviderUsageResult(
            accountID: quotaResult.accountID,
            providerID: .greptile,
            title: "Greptile",
            subtitle: "Current billing period",
            bars: quotaResult.bars,
            fetchedAt: dates[2]
        )
        XCTAssertEqual(store.historySeries(for: staleQuotaResult).points.map(\.value), [50, 50])
        XCTAssertEqual(
            store.historySeriesOptions(for: staleQuotaResult).first?.id,
            GreptileUsageIdentity.completedReviewsHistorySeriesID
        )

        let failedResult = ProviderUsageResult(
            accountID: "greptile.team",
            providerID: .greptile,
            title: "Greptile",
            subtitle: "Greptile rate limit reached.",
            bars: completedResult.bars,
            barsFetchedAt: dates[0],
            failureMessage: "Greptile rate limit reached.",
            preserveCachedBarsOnFailure: true,
            fetchedAt: dates[3]
        )
        XCTAssertFalse(failedResult.hasCurrentBars)
        XCTAssertEqual(store.historySeries(for: failedResult).points.map(\.value), [50, 50])
        XCTAssertEqual(
            store.historySeriesOptions(for: failedResult).map(\.id),
            [
                GreptileUsageIdentity.completedReviewsHistorySeriesID,
                GreptileUsageIdentity.reviewQuotaHistorySeriesID,
            ]
        )

        let emptyResult = ProviderUsageResult(
            accountID: quotaResult.accountID,
            providerID: .greptile,
            title: "Greptile",
            subtitle: "No review history returned",
            bars: [],
            fetchedAt: dates[3]
        )
        XCTAssertEqual(store.historySeries(for: emptyResult).points.map(\.value), [50, 50])
        XCTAssertEqual(
            store.historySeriesOptions(for: emptyResult).first?.id,
            GreptileUsageIdentity.completedReviewsHistorySeriesID
        )
    }

    @MainActor
    func testMissingUsageHistoryInitializesWithoutAnError() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = UsageHistoryStore(defaults: defaults)

        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.requiresRecovery)
    }

    @MainActor
    func testCorruptedUsageHistoryIsPreservedUntilExplicitlyReset() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let corruptedData = Data("not valid usage history".utf8)
        defaults.set(corruptedData, forKey: "usageHistorySnapshots")
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let result = makeHistoryResult(
            accountID: "codex.recovered-history",
            fetchedAt: fetchedAt,
            used: 42
        )

        let store = UsageHistoryStore(defaults: defaults)

        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertEqual(
            store.lastError,
            "Saved usage history could not be read. Reset history to resume recording."
        )
        XCTAssertTrue(store.requiresRecovery)

        store.record(results: [result], now: fetchedAt)
        store.removeSnapshotsForMissingAccounts(
            validAccountIDs: [result.accountID],
            now: fetchedAt
        )

        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), corruptedData)
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertNotNil(store.lastError)

        store.discardCorruptedHistory()

        XCTAssertNil(defaults.data(forKey: "usageHistorySnapshots"))
        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.requiresRecovery)

        store.record(results: [result], now: fetchedAt)

        XCTAssertEqual(store.snapshots.map(\.accountID), [result.accountID])
        XCTAssertNotNil(defaults.data(forKey: "usageHistorySnapshots"))
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testIdenticalDuplicateUsageHistorySnapshotsRequireRecovery() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let snapshot = UsageHistorySnapshot(
            result: makeHistoryResult(
                accountID: "codex.duplicate-history",
                fetchedAt: fetchedAt,
                used: 42
            )
        )
        let damagedData = try JSONEncoder().encode([snapshot, snapshot])
        defaults.set(damagedData, forKey: "usageHistorySnapshots")

        let store = UsageHistoryStore(defaults: defaults)

        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertEqual(
            store.lastError,
            "Saved usage history could not be read. Reset history to resume recording."
        )
        XCTAssertTrue(store.requiresRecovery)
        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), damagedData)
    }

    @MainActor
    func testConflictingDuplicateUsageHistorySnapshotsPreserveDataUntilReset() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let accountID = "codex.conflicting-history"
        let firstSnapshot = UsageHistorySnapshot(
            result: makeHistoryResult(
                accountID: accountID,
                fetchedAt: fetchedAt,
                used: 20
            )
        )
        let conflictingSnapshot = UsageHistorySnapshot(
            result: makeHistoryResult(
                accountID: accountID,
                fetchedAt: fetchedAt,
                used: 80
            )
        )
        XCTAssertEqual(firstSnapshot.id, conflictingSnapshot.id)
        XCTAssertNotEqual(firstSnapshot, conflictingSnapshot)
        let damagedData = try JSONEncoder().encode([firstSnapshot, conflictingSnapshot])
        defaults.set(damagedData, forKey: "usageHistorySnapshots")
        let store = UsageHistoryStore(defaults: defaults)

        store.record(
            results: [
                makeHistoryResult(
                    accountID: accountID,
                    fetchedAt: fetchedAt.addingTimeInterval(60),
                    used: 60
                ),
            ],
            now: fetchedAt.addingTimeInterval(60)
        )
        store.removeSnapshotsForMissingAccounts(validAccountIDs: [], now: fetchedAt)

        XCTAssertTrue(store.requiresRecovery)
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), damagedData)

        store.discardCorruptedHistory()

        XCTAssertFalse(store.requiresRecovery)
        XCTAssertNil(store.lastError)
        XCTAssertNil(defaults.object(forKey: "usageHistorySnapshots"))

        let recoveredResult = makeHistoryResult(
            accountID: accountID,
            fetchedAt: fetchedAt.addingTimeInterval(120),
            used: 65
        )
        store.record(results: [recoveredResult], now: recoveredResult.fetchedAt)

        XCTAssertEqual(store.snapshots.map(\.accountID), [accountID])
        XCTAssertEqual(store.snapshots.first?.bars.first?.used, 65)
        XCTAssertNotNil(defaults.data(forKey: "usageHistorySnapshots"))
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testNonDataUsageHistoryIsPreservedUntilExplicitlyReset() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let corruptedValue = "not stored as data"
        defaults.set(corruptedValue, forKey: "usageHistorySnapshots")

        let store = UsageHistoryStore(defaults: defaults)

        XCTAssertTrue(store.requiresRecovery)
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(
            defaults.string(forKey: "usageHistorySnapshots"),
            corruptedValue
        )

        store.discardCorruptedHistory()

        XCTAssertFalse(store.requiresRecovery)
        XCTAssertNil(store.lastError)
        XCTAssertNil(defaults.object(forKey: "usageHistorySnapshots"))
    }

    @MainActor
    func testUsageHistoryStoreRecordsAndPersistsSnapshots() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let result = makeHistoryResult(accountID: "codex.personal", fetchedAt: fetchedAt, used: 42)

        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [result], now: fetchedAt)

        let reloadedStore = UsageHistoryStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.snapshots.count, 1)
        XCTAssertEqual(reloadedStore.snapshots.first?.accountID, "codex.personal")
        XCTAssertEqual(reloadedStore.snapshots.first?.bars.first?.fractionUsed, 0.42)
        XCTAssertNil(reloadedStore.snapshots.first?.creditsRemaining)
    }

    @MainActor
    func testUsageHistoryStoreEnforcesSamplingIntervalPerAccount() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstFetch = Date(timeIntervalSince1970: 1_788_475_200)
        let store = UsageHistoryStore(defaults: defaults)

        store.record(
            results: [
                makeHistoryResult(
                    accountID: "codex.personal",
                    fetchedAt: firstFetch,
                    used: 20
                ),
            ],
            now: firstFetch,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )
        store.record(
            results: [
                makeHistoryResult(
                    accountID: "codex.personal",
                    fetchedAt: firstFetch.addingTimeInterval(60 * 60),
                    used: 30
                ),
                makeHistoryResult(
                    accountID: "codex.work",
                    fetchedAt: firstFetch.addingTimeInterval(60 * 60),
                    used: 40
                ),
            ],
            now: firstFetch.addingTimeInterval(60 * 60),
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )
        store.record(
            results: [
                makeHistoryResult(
                    accountID: "codex.personal",
                    fetchedAt: firstFetch.addingTimeInterval(2 * 60 * 60),
                    used: 50
                ),
            ],
            now: firstFetch.addingTimeInterval(2 * 60 * 60),
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )

        XCTAssertEqual(
            store.snapshots(for: "codex.personal").compactMap { $0.bars.first?.used },
            [20, 50]
        )
        XCTAssertEqual(
            store.snapshots(for: "codex.work").compactMap { $0.bars.first?.used },
            [40]
        )
    }

    @MainActor
    func testUsageHistoryPresentsFreshResultInsideSamplingIntervalWithoutPersistingIt() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstFetch = Date(timeIntervalSince1970: 1_788_475_200)
        let storedResult = makeHistoryResult(
            accountID: "codex.personal",
            fetchedAt: firstFetch,
            used: 8
        )
        let freshResult = makeHistoryResult(
            accountID: storedResult.accountID,
            fetchedAt: firstFetch.addingTimeInterval(101 * 60),
            used: 43
        )
        let store = UsageHistoryStore(defaults: defaults)

        store.record(
            results: [storedResult],
            now: storedResult.fetchedAt,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )
        store.record(
            results: [freshResult],
            now: freshResult.fetchedAt,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )

        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertEqual(store.snapshots.first?.bars.first?.used, 8)
        XCTAssertEqual(store.historySeries(for: freshResult).points.map(\.value), [0.08, 0.43])
        XCTAssertEqual(
            store.historySeriesOptions(for: freshResult).first?.series.points.map(\.value),
            [0.08, 0.43]
        )
        XCTAssertEqual(store.snapshots.count, 1)
    }

    @MainActor
    func testUsageHistoryReplacesMatchingCurrentTimestampWithoutDuplicate() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let storedResult = makeHistoryResult(
            accountID: "codex.personal",
            fetchedAt: fetchedAt,
            used: 8
        )
        let currentResult = makeHistoryResult(
            accountID: storedResult.accountID,
            fetchedAt: fetchedAt,
            used: 43
        )
        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [storedResult], now: fetchedAt)

        XCTAssertEqual(store.historySeries(for: currentResult).points.map(\.value), [0.43])
        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertEqual(store.snapshots.first?.bars.first?.used, 8)
    }

    @MainActor
    func testUsageHistorySameTimestampPreservesStoredComponentsMissingFromCurrentResult() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let storedResult = ProviderUsageResult(
            accountID: "opencode.personal",
            providerID: .openCodeZen,
            title: "OpenCode",
            subtitle: "Usage and balance",
            bars: [UsageBar(stableKey: "go.weekly", label: "Weekly usage", used: 8, limit: 100)],
            creditsRemaining: 12,
            fetchedAt: fetchedAt
        )
        let currentResult = ProviderUsageResult(
            accountID: storedResult.accountID,
            providerID: storedResult.providerID,
            title: storedResult.title,
            subtitle: "Fresh usage with cached balance",
            bars: [UsageBar(stableKey: "go.weekly", label: "Weekly usage", used: 43, limit: 100)],
            creditsRemaining: 12,
            creditsFetchedAt: fetchedAt.addingTimeInterval(-60),
            fetchedAt: fetchedAt
        )
        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [storedResult], now: fetchedAt)

        let options = store.historySeriesOptions(for: currentResult)

        XCTAssertEqual(options.first(where: { $0.id == "usage" })?.series.points.map(\.value), [0.43])
        XCTAssertEqual(options.first(where: { $0.id == "balance" })?.series.points.map(\.value), [12])
        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertEqual(store.snapshots.first?.bars.first?.used, 8)
        XCTAssertEqual(store.snapshots.first?.creditsRemaining, 12)
    }

    @MainActor
    func testUsageHistorySameTimestampPreservesSpendLimitStateForPartialMetrics() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let spent = ProviderMonetaryMetric(
            kind: .spent,
            label: "Usage credits spent",
            minorUnits: 1_500,
            currencyCode: "USD",
            decimalPlaces: 2
        )
        let spendLimit = ProviderMonetaryMetric(
            kind: .spendLimit,
            label: "Spend limit",
            minorUnits: 1_000,
            currencyCode: "USD",
            decimalPlaces: 2
        )
        let storedResult = ProviderUsageResult(
            accountID: "claude.personal",
            providerID: .claude,
            title: "Claude",
            subtitle: "Spend",
            bars: [],
            monetaryMetrics: [spent, spendLimit],
            fetchedAt: fetchedAt
        )
        let partialResult = ProviderUsageResult(
            accountID: storedResult.accountID,
            providerID: storedResult.providerID,
            title: storedResult.title,
            subtitle: "Partial spend",
            bars: [],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .spent,
                    label: spent.label,
                    minorUnits: 5_000,
                    currencyCode: spent.currencyCode,
                    decimalPlaces: 3
                ),
            ],
            fetchedAt: fetchedAt
        )
        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [storedResult], now: fetchedAt)

        let options = store.historySeriesOptions(for: partialResult)
        let spentSeries = options.first(where: { $0.label == spent.label })?.series

        XCTAssertEqual(spentSeries?.points.map(\.value), [5])
        XCTAssertEqual(spentSeries?.decimalPlaces, 3)
        XCTAssertEqual(spentSeries?.points.first?.severity, .critical)
        XCTAssertEqual(store.snapshots.count, 1)
    }

    @MainActor
    func testUsageHistoryUsesStableMetricForEphemeralMultiBarResult() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstFetch = Date(timeIntervalSince1970: 1_788_475_200)
        let storedResult = ProviderUsageResult(
            accountID: "cursor.personal",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Stored usage",
            bars: [
                UsageBar(stableKey: "total", label: "Total", used: 8, limit: 100),
                UsageBar(stableKey: "api", label: "API", used: 90, limit: 100),
            ],
            fetchedAt: firstFetch
        )
        let currentResult = ProviderUsageResult(
            accountID: storedResult.accountID,
            providerID: storedResult.providerID,
            title: storedResult.title,
            subtitle: "Fresh usage",
            bars: [
                UsageBar(stableKey: "api", label: "API requests", used: 100, limit: 100),
                UsageBar(stableKey: "total", label: "Overall plan", used: 43, limit: 100),
            ],
            fetchedAt: firstFetch.addingTimeInterval(101 * 60)
        )
        let store = UsageHistoryStore(defaults: defaults)
        store.record(
            results: [storedResult],
            now: firstFetch,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )
        store.record(
            results: [currentResult],
            now: currentResult.fetchedAt,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )

        XCTAssertEqual(store.historySeries(for: currentResult).points.map(\.value), [0.08, 0.43])
        XCTAssertEqual(
            store.historySeriesOptions(for: currentResult)
                .first(where: { $0.id == "usage.total" })?
                .series.points.map(\.value),
            [0.08, 0.43]
        )
        XCTAssertEqual(
            store.historySeriesOptions(for: currentResult)
                .first(where: { $0.id == "usage.other-models" })?
                .series.points.map(\.value),
            [0.9, 1]
        )
        XCTAssertEqual(store.snapshots.count, 1)
    }

    @MainActor
    func testUsageHistoryDoesNotPresentStaleOrFailedCurrentBars() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstFetch = Date(timeIntervalSince1970: 1_788_475_200)
        let storedResult = makeHistoryResult(
            accountID: "codex.personal",
            fetchedAt: firstFetch,
            used: 8
        )
        let currentFetch = firstFetch.addingTimeInterval(101 * 60)
        let staleResult = ProviderUsageResult(
            accountID: storedResult.accountID,
            providerID: storedResult.providerID,
            title: storedResult.title,
            subtitle: "Cached usage",
            bars: [UsageBar(label: "Weekly usage", used: 43, limit: 100)],
            barsFetchedAt: firstFetch,
            fetchedAt: currentFetch
        )
        let failedResult = ProviderUsageResult(
            accountID: storedResult.accountID,
            providerID: storedResult.providerID,
            title: storedResult.title,
            subtitle: "Refresh failed",
            bars: [UsageBar(label: "Weekly usage", used: 43, limit: 100)],
            failureMessage: "Refresh failed",
            fetchedAt: currentFetch
        )
        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [storedResult], now: firstFetch)

        XCTAssertEqual(store.historySeries(for: staleResult).points.map(\.value), [0.08])
        XCTAssertEqual(store.historySeries(for: failedResult).points.map(\.value), [0.08])
    }

    @MainActor
    func testUsageHistoryPresentsCurrentComponentFromPartialOpenCodeRefresh() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstFetch = Date(timeIntervalSince1970: 1_788_475_200)
        let storedResult = ProviderUsageResult(
            accountID: "opencode.personal",
            providerID: .openCodeZen,
            title: "OpenCode",
            subtitle: "Usage and balance",
            bars: [UsageBar(stableKey: "go.weekly", label: "Weekly usage", used: 8, limit: 100)],
            creditsRemaining: 12,
            fetchedAt: firstFetch
        )
        let partialResult = ProviderUsageResult(
            accountID: storedResult.accountID,
            providerID: storedResult.providerID,
            title: storedResult.title,
            subtitle: "Fresh usage with unavailable balance",
            bars: [UsageBar(stableKey: "go.weekly", label: "Weekly usage", used: 43, limit: 100)],
            creditsRemaining: 12,
            creditsFetchedAt: firstFetch,
            failureMessage: "Zen balance refresh failed",
            preserveCachedCreditsOnFailure: true,
            fetchedAt: firstFetch.addingTimeInterval(101 * 60)
        )
        let store = UsageHistoryStore(defaults: defaults)
        store.record(
            results: [storedResult],
            now: firstFetch,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )
        store.record(
            results: [partialResult],
            now: partialResult.fetchedAt,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )

        let options = store.historySeriesOptions(for: partialResult)

        XCTAssertTrue(partialResult.hasCurrentBars)
        XCTAssertFalse(partialResult.hasCurrentCredits)
        XCTAssertEqual(options.first(where: { $0.id == "usage" })?.series.points.map(\.value), [0.08, 0.43])
        XCTAssertEqual(options.first(where: { $0.id == "balance" })?.series.points.map(\.value), [12])
        XCTAssertEqual(store.snapshots.count, 1)
    }

    @MainActor
    func testUsageHistoryStoreAppliesChangedIntervalOnlyToFutureSamples() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstFetch = Date(timeIntervalSince1970: 1_788_475_200)
        let changedFetch = firstFetch.addingTimeInterval(3 * 60 * 60)
        let store = UsageHistoryStore(defaults: defaults)

        store.record(
            results: [
                makeHistoryResult(
                    accountID: "codex.personal",
                    fetchedAt: firstFetch,
                    used: 20
                ),
            ],
            now: firstFetch,
            samplingInterval: HistorySamplingInterval.fourHours.seconds
        )
        store.record(
            results: [
                makeHistoryResult(
                    accountID: "codex.personal",
                    fetchedAt: changedFetch,
                    used: 30
                ),
            ],
            now: changedFetch,
            samplingInterval: HistorySamplingInterval.fourHours.seconds
        )
        XCTAssertEqual(store.snapshots(for: "codex.personal").count, 1)

        store.record(
            results: [
                makeHistoryResult(
                    accountID: "codex.personal",
                    fetchedAt: changedFetch,
                    used: 30
                ),
            ],
            now: changedFetch,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )

        XCTAssertEqual(
            store.snapshots(for: "codex.personal").compactMap { $0.bars.first?.used },
            [20, 30]
        )
    }

    func testUsageHistoryBarSnapshotDecodesLegacyLabelOnlyData() throws {
        let data = Data(
            #"{"label":"Total","fractionUsed":0.38,"used":38,"limit":100}"#.utf8
        )

        let snapshot = try JSONDecoder().decode(UsageHistoryBarSnapshot.self, from: data)

        XCTAssertNil(snapshot.stableKey)
        XCTAssertEqual(snapshot.label, "Total")
        XCTAssertEqual(snapshot.fractionUsed, 0.38)
        XCTAssertEqual(snapshot.effectiveSeverity, .normal)
    }

    @MainActor
    func testLegacyCursorHistoryFallsBackToSnapshotSeverity() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let legacyData = Data(
            """
            [{
              "id":"cursor.legacy.0",
              "accountID":"cursor.legacy",
              "providerID":"cursor",
              "title":"Cursor",
              "subtitle":"Legacy projected usage",
              "capturedAt":0,
              "bars":[
                {
                  "stableKey":"total",
                  "label":"Total",
                  "fractionUsed":0.4,
                  "used":40,
                  "limit":100,
                  "effectiveSeverity":0
                },
                {
                  "stableKey":"auto",
                  "label":"Auto",
                  "fractionUsed":0.5,
                  "used":50,
                  "limit":100,
                  "effectiveSeverity":2
                }
              ],
              "highestSeverity":2
            }]
            """.utf8
        )
        defaults.set(legacyData, forKey: "usageHistorySnapshots")
        let result = ProviderUsageResult(
            accountID: "cursor.legacy",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Current",
            bars: [UsageBar(stableKey: "total", label: "Total", used: 40, limit: 100)],
            failureMessage: "Current usage unavailable",
            fetchedAt: Date()
        )

        let store = UsageHistoryStore(defaults: defaults)

        XCTAssertEqual(
            store.historySeries(for: result).points.map(\.severity),
            [.critical]
        )
        XCTAssertEqual(
            store.historySeriesOptions(for: result)
                .first(where: { $0.id == "usage.total" })?
                .series.points.map(\.severity),
            [.normal]
        )
        XCTAssertEqual(
            store.historySeriesOptions(for: result)
                .first(where: { $0.id == "usage.cursor-models" })?
                .series.points.map(\.severity),
            [.critical]
        )

        defaults.set(
            try JSONEncoder().encode(store.snapshots),
            forKey: "usageHistorySnapshots"
        )
        let reloadedStore = UsageHistoryStore(defaults: defaults)
        XCTAssertEqual(
            reloadedStore.historySeries(for: result).points.map(\.severity),
            [.critical]
        )
        XCTAssertEqual(
            reloadedStore.historySeriesOptions(for: result)
                .first(where: { $0.id == "usage.total" })?
                .series.points.map(\.severity),
            [.normal]
        )
    }

    func testLegacyHistoryInfersReachedSpendLimitFromMetrics() throws {
        let data = Data(
            """
            {
              "id":"claude.legacy.0",
              "accountID":"claude.legacy",
              "providerID":"claude",
              "title":"Claude",
              "subtitle":"Legacy spend",
              "capturedAt":0,
              "bars":[{
                "label":"Weekly",
                "fractionUsed":0.95,
                "used":95,
                "limit":100,
                "effectiveSeverity":2
              }],
              "monetaryMetrics":[
                {
                  "kind":"spent",
                  "label":"Spent",
                  "minorUnits":1000,
                  "currencyCode":"USD",
                  "decimalPlaces":2
                },
                {
                  "kind":"spendLimit",
                  "label":"Limit",
                  "minorUnits":1000,
                  "currencyCode":"USD",
                  "decimalPlaces":2
                }
              ],
              "highestSeverity":2
            }
            """.utf8
        )
        let snapshot = try JSONDecoder().decode(UsageHistorySnapshot.self, from: data)
        let thresholds = UsageSeverityThresholds(warning: 0.97, critical: 0.99)

        XCTAssertEqual(snapshot.highestSeverity(using: thresholds), .critical)
    }

    @MainActor
    func testCursorHistoryPersistsProjectedSeverityForSelectedMetric() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let capturedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let result = ProviderUsageResult(
            accountID: "cursor.projected",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Projected",
            bars: [
                UsageBar(
                    stableKey: "total",
                    label: "Total",
                    used: 63,
                    limit: 100,
                    projectionCurrent: 63,
                    projectionLimit: 100,
                    projectionPeriodStart: capturedAt.addingTimeInterval(-50),
                    projectionPeriodEnd: capturedAt.addingTimeInterval(50)
                ),
            ],
            fetchedAt: capturedAt
        )
        let store = UsageHistoryStore(defaults: defaults)

        store.record(results: [result], now: capturedAt)

        let reloadedStore = UsageHistoryStore(defaults: defaults)
        let snapshot = try XCTUnwrap(reloadedStore.snapshots.first)
        XCTAssertEqual(snapshot.bars.first?.fractionUsed, 0.63)
        XCTAssertEqual(snapshot.bars.first?.effectiveSeverity, .critical)
        XCTAssertEqual(
            reloadedStore.historySeries(for: result).points.map(\.severity),
            [.critical]
        )
        XCTAssertEqual(
            reloadedStore.historySeriesOptions(for: result)
                .first(where: { $0.id == "usage.total" })?
                .series.points.map(\.severity),
            [.critical]
        )
    }

    @MainActor
    func testCursorHistoryPreservesLegacySeriesUnderCurrentModelBucketIdentities() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let fetchedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let result = ProviderUsageResult(
            accountID: "cursor.personal",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Current",
            bars: [
                UsageBar(stableKey: "total", label: "Total", used: 38, limit: 100),
                UsageBar(stableKey: "auto", label: "Auto", used: 29, limit: 100),
                UsageBar(stableKey: "api", label: "API", used: 100, limit: 100),
                UsageBar(
                    stableKey: "on-demand",
                    label: "On-demand $0.00 / $20.00",
                    used: 0,
                    limit: 2_000
                ),
            ],
            fetchedAt: fetchedAt
        )
        let store = UsageHistoryStore(defaults: defaults)

        store.record(results: [result], now: fetchedAt)

        let snapshot = try XCTUnwrap(store.snapshots.first)
        XCTAssertEqual(snapshot.bars.map(\.stableKey), ["total", "auto", "api", "on-demand"])
        XCTAssertEqual(snapshot.primaryValue, 0.38)
        XCTAssertEqual(store.historySeries(for: result).points.map(\.value), [0.38])

        let options = store.historySeriesOptions(for: result)
        XCTAssertEqual(options.map(\.id), [
            "usage.total",
            "usage.cursor-models",
            "usage.other-models",
            "usage.on-demand",
        ])
        XCTAssertEqual(
            options.map(\.label),
            ["Total", "Cursor Models", "Other Models", "On-demand"]
        )
        XCTAssertEqual(options.map { $0.series.points.map(\.value) }, [
            [0.38],
            [0.29],
            [1],
            [0],
        ])
        XCTAssertEqual(options.map { $0.series.points.map(\.severity) }, [
            [.normal],
            [.normal],
            [.critical],
            [.normal],
        ])

        let reorderedAndRelabeledResult = ProviderUsageResult(
            accountID: result.accountID,
            providerID: result.providerID,
            title: result.title,
            subtitle: result.subtitle,
            bars: [
                UsageBar(
                    stableKey: CursorUsageIdentity.otherModelsStableKey,
                    label: "Other Models",
                    used: 100,
                    limit: 100
                ),
                UsageBar(stableKey: "on-demand", label: "On-demand spend", used: 0, limit: 2_000),
                UsageBar(
                    stableKey: CursorUsageIdentity.cursorModelsStableKey,
                    label: "Cursor Models",
                    used: 29,
                    limit: 100
                ),
                UsageBar(stableKey: "total", label: "Overall plan", used: 38, limit: 100),
            ],
            fetchedAt: fetchedAt.addingTimeInterval(60)
        )

        XCTAssertEqual(
            store.historySeries(for: reorderedAndRelabeledResult).points.map(\.value),
            [0.38, 0.38]
        )
        XCTAssertEqual(
            store.historySeriesOptions(for: reorderedAndRelabeledResult).map(\.id),
            options.map(\.id)
        )

        let resultWithoutTotal = ProviderUsageResult(
            accountID: "cursor.partial",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Current without Total",
            bars: [
                UsageBar(
                    stableKey: CursorUsageIdentity.cursorModelsStableKey,
                    label: "Cursor Models",
                    used: 29,
                    limit: 100
                ),
                UsageBar(
                    stableKey: CursorUsageIdentity.otherModelsStableKey,
                    label: "Other Models",
                    used: 100,
                    limit: 100
                ),
            ],
            fetchedAt: fetchedAt
        )
        store.record(results: [resultWithoutTotal], now: fetchedAt)

        let partialSnapshot = try XCTUnwrap(store.snapshots(for: resultWithoutTotal.accountID).first)
        XCTAssertEqual(partialSnapshot.primaryValue, 1)
        XCTAssertEqual(store.historySeries(for: resultWithoutTotal).points.map(\.value), [1])
        let partialOptions = store.historySeriesOptions(for: resultWithoutTotal)
        XCTAssertEqual(
            partialOptions.map(\.id),
            ["usage", "usage.cursor-models", "usage.other-models"]
        )
        XCTAssertEqual(
            partialOptions.map(\.label),
            ["Highest usage", "Cursor Models", "Other Models"]
        )
        XCTAssertEqual(partialOptions.first?.series.points.map(\.value), [1])
        XCTAssertEqual(partialOptions.first?.series, store.historySeries(for: resultWithoutTotal))
        XCTAssertEqual(
            store.historySeries(for: resultWithoutTotal).points.map(\.id),
            [partialSnapshot.id],
            "A raw sample and its daily summary share a timestamp; every caller selects the raw sample"
        )

        let laterResultWithoutTotal = ProviderUsageResult(
            accountID: result.accountID,
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Current without Total",
            bars: [
                UsageBar(
                    stableKey: CursorUsageIdentity.cursorModelsStableKey,
                    label: "Cursor Models",
                    used: 45,
                    limit: 100
                ),
                UsageBar(
                    stableKey: CursorUsageIdentity.otherModelsStableKey,
                    label: "Other Models",
                    used: 90,
                    limit: 100
                ),
            ],
            fetchedAt: fetchedAt.addingTimeInterval(120)
        )
        store.record(results: [laterResultWithoutTotal], now: laterResultWithoutTotal.fetchedAt)

        XCTAssertEqual(store.historySeries(for: laterResultWithoutTotal).points.map(\.value), [
            0.38,
            0.9,
        ])
        let mixedOptions = store.historySeriesOptions(for: laterResultWithoutTotal)
        XCTAssertEqual(mixedOptions.first?.id, "usage")
        XCTAssertEqual(mixedOptions.first?.label, "Total / highest available")
        XCTAssertEqual(mixedOptions.first?.series.points.map(\.value), [0.38, 0.9])
        XCTAssertEqual(
            mixedOptions.first(where: { $0.id == "usage.total" })?.series.points.map(\.value),
            [0.38]
        )
    }

    @MainActor
    func testUsageHistoryStoreSurfacesEncodingFailures() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let invalidResult = makeHistoryResult(
            accountID: "codex.invalid-history",
            fetchedAt: fetchedAt,
            used: .nan
        )
        let store = UsageHistoryStore(defaults: defaults)

        store.record(results: [invalidResult], now: fetchedAt)

        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(store.lastError?.hasPrefix("Could not save usage history:") == true)
        XCTAssertNil(defaults.data(forKey: "usageHistorySnapshots"))

        let validResult = makeHistoryResult(
            accountID: "codex.valid-history",
            fetchedAt: fetchedAt,
            used: 42
        )
        store.record(results: [validResult], now: fetchedAt)

        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.snapshots.map(\.accountID), ["codex.valid-history"])
        XCTAssertNotNil(defaults.data(forKey: "usageHistorySnapshots"))
    }

    @MainActor
    func testUsageHistoryStorePersistsAllMonetaryMetricsAlongsideBars() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let result = ProviderUsageResult(
            accountID: "claude.personal",
            providerID: .claude,
            title: "Claude",
            subtitle: "Live Claude usage",
            bars: [UsageBar(label: "Weekly usage limit", used: 40, limit: 100)],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .spent,
                    label: "Usage credits spent",
                    minorUnits: 1250,
                    currencyCode: "EUR",
                    decimalPlaces: 2
                ),
                ProviderMonetaryMetric(
                    kind: .remainingHeadroom,
                    label: "Remaining spend headroom",
                    minorUnits: 3750,
                    currencyCode: "EUR",
                    decimalPlaces: 2
                ),
            ],
            fetchedAt: fetchedAt
        )

        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [result], now: fetchedAt)

        let snapshot = try XCTUnwrap(UsageHistoryStore(defaults: defaults).snapshots.first)
        XCTAssertEqual(snapshot.monetaryMetrics?.map(\.kind), [.spent, .remainingHeadroom])
        XCTAssertEqual(snapshot.monetaryMetrics?.map(\.currencyCode), ["EUR", "EUR"])
        XCTAssertEqual(snapshot.primaryValue, 0.4)

        let options = store.historySeriesOptions(for: result)
        XCTAssertEqual(options.map(\.label), [
            "Usage",
            "Usage credits spent",
            "Remaining spend headroom",
        ])
        XCTAssertEqual(options[1].series.points.map(\.value), [12.5])
        XCTAssertEqual(options[1].series.currencyCode, "EUR")
        XCTAssertEqual(options[2].series.points.map(\.value), [37.5])

        let relabeledResult = ProviderUsageResult(
            accountID: result.accountID,
            providerID: result.providerID,
            title: result.title,
            subtitle: result.subtitle,
            bars: result.bars,
            monetaryMetrics: result.monetaryMetrics.map { metric in
                ProviderMonetaryMetric(
                    kind: metric.kind,
                    label: "Updated \(metric.label)",
                    minorUnits: metric.minorUnits,
                    currencyCode: metric.currencyCode,
                    decimalPlaces: metric.decimalPlaces,
                    detail: metric.detail
                )
            },
            fetchedAt: result.fetchedAt
        )
        let relabeledOptions = store.historySeriesOptions(for: relabeledResult)
        XCTAssertEqual(relabeledOptions[1].series.points.map(\.value), [12.5])
        XCTAssertEqual(relabeledOptions[2].series.points.map(\.value), [37.5])

        let monetaryOnlyResult = ProviderUsageResult(
            accountID: "claude.monetary-only",
            providerID: .claude,
            title: "Claude",
            subtitle: "Live Claude usage",
            bars: [],
            monetaryMetrics: result.monetaryMetrics,
            fetchedAt: fetchedAt
        )
        store.record(results: [monetaryOnlyResult], now: fetchedAt)
        let compactSeries = store.historySeries(for: monetaryOnlyResult)
        XCTAssertEqual(compactSeries.currencyCode, "EUR")
        XCTAssertEqual(compactSeries.decimalPlaces, 2)
        XCTAssertTrue(compactSeries.latestValueDescription.contains("37.50"))
        XCTAssertFalse(compactSeries.latestValueDescription.contains("$"))

        let transientMonetaryOnly = ProviderUsageResult(
            accountID: result.accountID,
            providerID: .claude,
            title: "Claude",
            subtitle: "Partial Claude usage",
            bars: [],
            monetaryMetrics: result.monetaryMetrics,
            fetchedAt: fetchedAt.addingTimeInterval(60)
        )
        store.record(results: [transientMonetaryOnly], now: fetchedAt.addingTimeInterval(60))
        let usageSeries = store.historySeries(for: result)
        XCTAssertEqual(usageSeries.points.count, 1)
        XCTAssertEqual(usageSeries.points.first?.value, 0.4)
        let mixedCurrencySeries = store.historySeries(for: transientMonetaryOnly)
        XCTAssertEqual(mixedCurrencySeries.points.map(\.value), [37.5, 37.5])
    }

    @MainActor
    func testUsageHistoryStoreDoesNotMixHeadroomIntoBalanceSeries() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let firstDate = Date(timeIntervalSince1970: 1_788_475_200)
        let store = UsageHistoryStore(defaults: defaults)
        let oldHeadroom = ProviderUsageResult(
            accountID: "claude.personal",
            providerID: .claude,
            title: "Claude",
            subtitle: "Live Claude usage",
            bars: [],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .remainingHeadroom,
                    label: "Remaining spend headroom",
                    minorUnits: 3750,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
            ],
            fetchedAt: firstDate
        )
        let currentBalance = ProviderUsageResult(
            accountID: oldHeadroom.accountID,
            providerID: .claude,
            title: "Claude",
            subtitle: "Live Claude usage",
            bars: [],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .balance,
                    label: "Current balance",
                    minorUnits: 10000,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
                oldHeadroom.monetaryMetrics[0],
            ],
            fetchedAt: firstDate.addingTimeInterval(60)
        )

        store.record(results: [oldHeadroom], now: oldHeadroom.fetchedAt)
        store.record(results: [currentBalance], now: currentBalance.fetchedAt)

        let series = store.historySeries(for: currentBalance)
        XCTAssertEqual(series.points.map(\.value), [100])
        XCTAssertEqual(series.currencyCode, "USD")
    }

    @MainActor
    func testUsageHistoryStorePrunesRetentionAndPerAccountLimit() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let store = UsageHistoryStore(defaults: defaults, retentionDays: 7, maxSnapshotsPerAccount: 2)

        store.record(results: [
            makeHistoryResult(accountID: "codex.personal", fetchedAt: now.addingTimeInterval(-8 * 24 * 60 * 60), used: 10),
        ], now: now)
        store.record(results: [
            makeHistoryResult(accountID: "codex.personal", fetchedAt: now.addingTimeInterval(-3 * 24 * 60 * 60), used: 20),
        ], now: now)
        store.record(results: [
            makeHistoryResult(accountID: "codex.personal", fetchedAt: now.addingTimeInterval(-2 * 24 * 60 * 60), used: 30),
        ], now: now)
        store.record(results: [
            makeHistoryResult(accountID: "codex.personal", fetchedAt: now.addingTimeInterval(-24 * 60 * 60), used: 40),
        ], now: now)

        let snapshots = store.snapshots(for: "codex.personal")
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots.compactMap { $0.bars.first?.used }, [30, 40])
    }

    @MainActor
    func testUsageHistoryStoreUpdatesDailyPointInsideDenseSamplingInterval() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let firstFetch = Date(timeIntervalSince1970: 1_788_475_200)
        let latestFetch = firstFetch.addingTimeInterval(60 * 60)
        let firstResult = makeHistoryResult(
            accountID: "codex.personal",
            fetchedAt: firstFetch,
            used: 20
        )
        let latestResult = makeHistoryResult(
            accountID: "codex.personal",
            fetchedAt: latestFetch,
            used: 35
        )
        let store = UsageHistoryStore(defaults: defaults)

        store.record(
            results: [firstResult],
            now: firstFetch,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )
        store.record(
            results: [latestResult],
            now: latestFetch,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )

        XCTAssertEqual(store.snapshots.compactMap { $0.bars.first?.used }, [20])
        XCTAssertEqual(store.dailySnapshots.compactMap { $0.bars.first?.used }, [35])
        XCTAssertEqual(
            store.historySeries(for: latestResult).points.map(\.value),
            [0.2, 0.35]
        )

        let reloadedStore = UsageHistoryStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.dailySnapshots.count, 1)
        XCTAssertEqual(reloadedStore.dailySnapshots.first?.capturedAt, latestFetch)
    }

    @MainActor
    func testDailyHistoryReplacesLegacyCursorBucketsWithSemanticBuckets() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let firstFetch = Date(timeIntervalSince1970: 1_788_475_200)
        let legacyResult = ProviderUsageResult(
            accountID: "cursor.personal",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Legacy model buckets",
            bars: [
                UsageBar(stableKey: "auto", label: "Auto", used: 20, limit: 100),
                UsageBar(stableKey: "api", label: "API", used: 40, limit: 100),
            ],
            fetchedAt: firstFetch
        )
        let semanticResult = ProviderUsageResult(
            accountID: legacyResult.accountID,
            providerID: legacyResult.providerID,
            title: legacyResult.title,
            subtitle: "Semantic model buckets",
            bars: [
                UsageBar(
                    stableKey: CursorUsageIdentity.cursorModelsStableKey,
                    label: "Cursor Models",
                    used: 35,
                    limit: 100
                ),
                UsageBar(
                    stableKey: CursorUsageIdentity.otherModelsStableKey,
                    label: "Other Models",
                    used: 65,
                    limit: 100
                ),
            ],
            fetchedAt: firstFetch.addingTimeInterval(60 * 60)
        )
        let store = UsageHistoryStore(defaults: defaults)

        store.record(
            results: [legacyResult],
            now: firstFetch,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )
        store.record(
            results: [semanticResult],
            now: semanticResult.fetchedAt,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )

        XCTAssertEqual(store.dailySnapshots.count, 2)
        XCTAssertEqual(
            store.dailySnapshots.compactMap { $0.bars.first?.stableKey },
            [
                CursorUsageIdentity.cursorModelsStableKey,
                CursorUsageIdentity.otherModelsStableKey,
            ]
        )
        XCTAssertEqual(store.dailySnapshots.compactMap { $0.bars.first?.used }, [35, 65])
    }

    @MainActor
    func testDailyHistoryKeepsComponentsFromPartialRefreshes() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let firstFetch = Date(timeIntervalSince1970: 1_788_475_200)
        let fullResult = ProviderUsageResult(
            accountID: "opencode.personal",
            providerID: .openCodeZen,
            title: "OpenCode",
            subtitle: "Usage and balance",
            bars: [UsageBar(stableKey: "go.weekly", label: "Weekly usage", used: 20, limit: 100)],
            creditsRemaining: 12,
            fetchedAt: firstFetch
        )
        let partialResult = ProviderUsageResult(
            accountID: fullResult.accountID,
            providerID: fullResult.providerID,
            title: fullResult.title,
            subtitle: "Fresh usage with cached balance",
            bars: [UsageBar(stableKey: "go.weekly", label: "Weekly usage", used: 40, limit: 100)],
            creditsRemaining: 12,
            creditsFetchedAt: firstFetch,
            fetchedAt: firstFetch.addingTimeInterval(60 * 60)
        )
        let store = UsageHistoryStore(defaults: defaults)

        store.record(
            results: [fullResult],
            now: firstFetch,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )
        store.record(
            results: [partialResult],
            now: partialResult.fetchedAt,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )
        store.removeSnapshotsForMissingAccounts(
            validAccountIDs: [fullResult.accountID],
            now: firstFetch.addingTimeInterval(31 * 24 * 60 * 60)
        )

        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertEqual(store.dailySnapshots.count, 2)
        let options = store.historySeriesOptions(for: partialResult)
        XCTAssertEqual(
            options.first(where: { $0.id == "usage" })?.series.points.map(\.value),
            [0.4]
        )
        XCTAssertEqual(
            options.first(where: { $0.id == "balance" })?.series.points.map(\.value),
            [12]
        )
    }

    @MainActor
    func testDailyHistoryKeepsSeparateBarIdentitiesFromSameDay() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let firstFetch = Date(timeIntervalSince1970: 1_788_475_200)
        let completedResult = ProviderUsageResult(
            accountID: "greptile.personal",
            providerID: .greptile,
            title: "Greptile",
            subtitle: "Completed reviews",
            bars: [
                UsageBar(
                    stableKey: GreptileUsageIdentity.completedReviewsStableKey,
                    label: "Completed reviews",
                    used: 4,
                    limit: 4
                ),
            ],
            fetchedAt: firstFetch
        )
        let quotaResult = ProviderUsageResult(
            accountID: completedResult.accountID,
            providerID: completedResult.providerID,
            title: completedResult.title,
            subtitle: "Review quota",
            bars: [
                UsageBar(
                    stableKey: GreptileUsageIdentity.reviewQuotaStableKey,
                    label: "Reviews used",
                    used: 1,
                    limit: 10
                ),
            ],
            fetchedAt: firstFetch.addingTimeInterval(60 * 60)
        )
        let store = UsageHistoryStore(defaults: defaults)

        store.record(
            results: [completedResult],
            now: firstFetch,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )
        store.record(
            results: [quotaResult],
            now: quotaResult.fetchedAt,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )
        store.removeSnapshotsForMissingAccounts(
            validAccountIDs: [completedResult.accountID],
            now: firstFetch.addingTimeInterval(31 * 24 * 60 * 60)
        )

        let emptyCurrentResult = ProviderUsageResult(
            accountID: completedResult.accountID,
            providerID: completedResult.providerID,
            title: completedResult.title,
            subtitle: "No current usage",
            bars: [],
            fetchedAt: quotaResult.fetchedAt
        )
        let options = store.historySeriesOptions(for: emptyCurrentResult)

        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertEqual(store.dailySnapshots.count, 2)
        XCTAssertEqual(
            options.first(where: {
                $0.id == GreptileUsageIdentity.reviewQuotaHistorySeriesID
            })?.series.points.map(\.value),
            [1]
        )
        XCTAssertEqual(
            options.first(where: {
                $0.id == GreptileUsageIdentity.completedReviewsHistorySeriesID
            })?.series.points.map(\.value),
            [4]
        )
    }

    @MainActor
    func testUsageHistoryStoreKeepsNinetyDailyPointsBeyondDenseRetention() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 29, hour: 12))
        )
        let store = UsageHistoryStore(defaults: defaults)

        for daysAgo in (0..<95).reversed() {
            let fetchedAt = try XCTUnwrap(
                calendar.date(byAdding: .day, value: -daysAgo, to: now)
            )
            store.record(
                results: [
                    makeHistoryResult(
                        accountID: "codex.personal",
                        fetchedAt: fetchedAt,
                        used: Double(daysAgo)
                    ),
                ],
                now: now,
                samplingInterval: HistorySamplingInterval.twoHours.seconds
            )
        }

        XCTAssertEqual(store.dailySnapshots.count, 90)
        XCTAssertEqual(store.snapshots.count, 31)

        let currentResult = makeHistoryResult(
            accountID: "codex.personal",
            fetchedAt: now,
            used: 0
        )
        let series = UsageHistoryStore(defaults: defaults).historySeries(for: currentResult)
        XCTAssertEqual(series.points.count, 90)
        XCTAssertEqual(
            series.points.first?.capturedAt,
            calendar.date(byAdding: .day, value: -89, to: now)
        )
    }

    func testUsageHistoryRangesUseInclusiveLocalCalendarDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 29, hour: 20))
        )
        let offsets = [0, -2, -3, -6, -7, -29, -30, -89, -90]
        let points = try offsets.enumerated().map { index, offset in
            UsageHistoryPoint(
                id: "point-\(index)",
                capturedAt: try XCTUnwrap(
                    calendar.date(byAdding: .day, value: offset, to: now)
                ),
                value: Double(index),
                severity: .normal
            )
        }
        let series = UsageHistorySeries(
            accountID: "codex.personal",
            points: points.sorted { $0.capturedAt < $1.capturedAt },
            isBalance: false
        )

        XCTAssertEqual(series.filtered(to: .today, now: now, calendar: calendar).points.count, 1)
        XCTAssertEqual(series.filtered(to: .threeDays, now: now, calendar: calendar).points.count, 2)
        XCTAssertEqual(series.filtered(to: .sevenDays, now: now, calendar: calendar).points.count, 4)
        XCTAssertEqual(series.filtered(to: .month, now: now, calendar: calendar).points.count, 6)
        XCTAssertEqual(series.filtered(to: .threeMonths, now: now, calendar: calendar).points.count, 8)
    }

    @MainActor
    func testUsageHistoryStoreRemovesDeletedAccounts() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let store = UsageHistoryStore(defaults: defaults)

        store.record(results: [
            makeHistoryResult(accountID: "codex.personal", fetchedAt: now, used: 42),
            makeHistoryResult(accountID: "openrouter.work", providerID: .openRouter, fetchedAt: now, creditsRemaining: 19.25),
        ], now: now)
        store.removeSnapshotsForMissingAccounts(validAccountIDs: ["codex.personal"], now: now)

        XCTAssertEqual(store.snapshots.map(\.accountID), ["codex.personal"])
    }

    @MainActor
    func testUsageHistoryStoreSkipsEmptyProviderStates() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Not configured",
            bars: [],
            fetchedAt: now
        )

        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [result], now: now)

        XCTAssertTrue(store.snapshots.isEmpty)
    }

    @MainActor
    func testUsageHistoryStoreSkipsStaleBarsWithoutFreshValues() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let barsFetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let result = ProviderUsageResult(
            accountID: "claude.personal",
            providerID: .claude,
            title: "Claude",
            subtitle: "Cached Claude usage",
            bars: [UsageBar(label: "Weekly usage limit", used: 40, limit: 100)],
            barsFetchedAt: barsFetchedAt,
            fetchedAt: barsFetchedAt.addingTimeInterval(60)
        )

        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [result], now: result.fetchedAt)

        XCTAssertTrue(store.snapshots.isEmpty)

        let resultWithFreshMoney = ProviderUsageResult(
            accountID: result.accountID,
            providerID: result.providerID,
            title: result.title,
            subtitle: result.subtitle,
            bars: result.bars,
            barsFetchedAt: barsFetchedAt,
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .remainingHeadroom,
                    label: "Remaining spend headroom",
                    minorUnits: 3750,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
            ],
            fetchedAt: result.fetchedAt.addingTimeInterval(60)
        )
        store.record(results: [resultWithFreshMoney], now: resultWithFreshMoney.fetchedAt)

        let series = store.historySeries(for: resultWithFreshMoney)
        XCTAssertTrue(series.isBalance)
        XCTAssertEqual(series.points.map(\.value), [37.5])
        XCTAssertEqual(
            store.historySeriesOptions(for: resultWithFreshMoney).map(\.label),
            ["Remaining spend headroom"]
        )
    }

    @MainActor
    func testUsageHistoryStoreRecordsFreshBarsWithoutCachedCredits() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_260)
        let result = ProviderUsageResult(
            accountID: "opencode.partial",
            providerID: .openCodeZen,
            title: "OpenCode",
            subtitle: "Fresh Go usage with cached Zen balance",
            bars: [UsageBar(stableKey: "go.weekly", label: "Weekly usage limit", used: 40, limit: 100)],
            creditsRemaining: 3,
            creditsFetchedAt: fetchedAt.addingTimeInterval(-60),
            fetchedAt: fetchedAt
        )

        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [result], now: fetchedAt)

        let snapshot = store.snapshots(for: result.accountID).first
        XCTAssertEqual(snapshot?.bars.map(\.used), [40])
        XCTAssertNil(snapshot?.creditsRemaining)
    }

    @MainActor
    func testOpenCodeHistoryKeepsDistinctUsageAndBalanceSeriesAcrossPartialRefresh() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let firstFetch = Date(timeIntervalSince1970: 1_788_475_200)
        let fullResult = ProviderUsageResult(
            accountID: "opencode.mixed",
            providerID: .openCodeZen,
            title: "OpenCode",
            subtitle: "Go usage and Zen credit balance",
            bars: [UsageBar(stableKey: "go.weekly", label: "Weekly usage limit", used: 20, limit: 100)],
            creditsRemaining: 10,
            fetchedAt: firstFetch
        )
        let partialResult = ProviderUsageResult(
            accountID: fullResult.accountID,
            providerID: fullResult.providerID,
            title: fullResult.title,
            subtitle: "OpenCode Go usage",
            bars: [UsageBar(stableKey: "go.weekly", label: "Weekly usage limit", used: 40, limit: 100)],
            creditsRemaining: 10,
            creditsFetchedAt: firstFetch,
            fetchedAt: firstFetch.addingTimeInterval(60)
        )
        let store = UsageHistoryStore(defaults: defaults)

        store.record(results: [fullResult], now: fullResult.fetchedAt)
        let fullOptions = store.historySeriesOptions(for: fullResult)
        store.record(results: [partialResult], now: partialResult.fetchedAt)
        let partialOptions = store.historySeriesOptions(for: partialResult)

        XCTAssertEqual(fullOptions.map(\.id), ["usage", "balance"])
        XCTAssertEqual(partialOptions.map(\.id), ["usage", "balance"])
        XCTAssertEqual(partialOptions.map(\.label), ["Usage", "Balance"])
        XCTAssertEqual(partialOptions[0].series.points.map(\.value), [0.2, 0.4])
        XCTAssertEqual(partialOptions[1].series.points.map(\.value), [10])
        XCTAssertFalse(store.historySeries(for: fullResult).isBalance)
        XCTAssertFalse(store.historySeries(for: partialResult).isBalance)
    }

    @MainActor
    func testUsageHistoryTrendSummaryReportsUsageMovement() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let store = UsageHistoryStore(defaults: defaults)
        let first = makeHistoryResult(accountID: "codex.personal", fetchedAt: now.addingTimeInterval(-60), used: 25)
        let second = makeHistoryResult(accountID: "codex.personal", fetchedAt: now, used: 40)

        store.record(results: [first], now: now)
        store.record(results: [second], now: now)

        let summary = try XCTUnwrap(store.trendSummary(for: second, now: now))
        XCTAssertEqual(summary.points, [0.25, 0.4])
        XCTAssertEqual(summary.direction, .up)
        XCTAssertFalse(summary.isBalance)
        XCTAssertEqual(summary.valueDescription, "Changed +15 pts")
        XCTAssertTrue(summary.windowDescription.hasPrefix("Since "))
        XCTAssertTrue(summary.windowDescription.contains(" at "))
    }

    @MainActor
    func testUsageHistoryTrendSummaryReportsBalanceMovement() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let store = UsageHistoryStore(defaults: defaults)
        let first = makeHistoryResult(
            accountID: "openrouter.work",
            providerID: .openRouter,
            fetchedAt: now.addingTimeInterval(-60),
            creditsRemaining: 22
        )
        let second = makeHistoryResult(
            accountID: "openrouter.work",
            providerID: .openRouter,
            fetchedAt: now,
            creditsRemaining: 19.25
        )

        store.record(results: [first], now: now)
        store.record(results: [second], now: now)

        let summary = try XCTUnwrap(store.trendSummary(for: second, now: now))
        XCTAssertEqual(summary.points, [22, 19.25])
        XCTAssertEqual(summary.direction, .down)
        XCTAssertTrue(summary.isBalance)
        XCTAssertEqual(summary.valueDescription, "Changed -$2.75")
        XCTAssertTrue(summary.windowDescription.hasPrefix("Since "))
        XCTAssertTrue(summary.windowDescription.contains(" at "))
    }

    @MainActor
    func testUsageHistorySeriesHandlesEmptyAndSingleSampleStates() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let result = makeHistoryResult(accountID: "codex.personal", fetchedAt: now, used: 42)
        let emptyResult = ProviderUsageResult(
            accountID: result.accountID,
            providerID: result.providerID,
            title: result.title,
            subtitle: "No usage",
            bars: [],
            fetchedAt: now
        )
        let store = UsageHistoryStore(defaults: defaults)

        let emptySeries = store.historySeries(for: emptyResult)
        XCTAssertTrue(emptySeries.points.isEmpty)
        XCTAssertEqual(emptySeries.latestValueDescription, "No data")
        XCTAssertEqual(emptySeries.rangeDescription, "No range yet")
        XCTAssertEqual(emptySeries.changeDescription, "No history yet")
        XCTAssertEqual(emptySeries.sampleWindowDescription, "No samples")
        XCTAssertEqual(emptySeries.chartDomain, 0...1)

        store.record(results: [result], now: now)

        let singleSampleSeries = store.historySeries(for: result)
        XCTAssertEqual(singleSampleSeries.points.count, 1)
        XCTAssertEqual(singleSampleSeries.latestValueDescription, "42%")
        XCTAssertEqual(singleSampleSeries.minimumValueDescription, "42%")
        XCTAssertEqual(singleSampleSeries.maximumValueDescription, "42%")
        XCTAssertEqual(singleSampleSeries.rangeDescription, "Flat at 42%")
        XCTAssertEqual(singleSampleSeries.changeDescription, "Collecting history")
        XCTAssertTrue(singleSampleSeries.sampleWindowDescription.hasPrefix("1 sample - "))
    }

    @MainActor
    func testUsageHistorySeriesReportsFlatValuesSpikesAndTimestampOrder() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let store = UsageHistoryStore(defaults: defaults)
        let samples = [
            makeHistoryResult(
                accountID: "codex.personal",
                fetchedAt: now.addingTimeInterval(-2 * 24 * 60 * 60),
                used: 20
            ),
            makeHistoryResult(
                accountID: "codex.personal",
                fetchedAt: now.addingTimeInterval(-24 * 60 * 60),
                used: 95
            ),
            makeHistoryResult(accountID: "codex.personal", fetchedAt: now, used: 40),
        ]

        for sample in samples.reversed() {
            store.record(results: [sample], now: now)
        }

        let series = store.historySeries(for: samples[2])
        XCTAssertEqual(series.points.map(\.capturedAt), samples.map(\.fetchedAt))
        XCTAssertEqual(series.points.map(\.value), [0.2, 0.95, 0.4])
        XCTAssertEqual(series.latestValueDescription, "40%")
        XCTAssertEqual(series.minimumValueDescription, "20%")
        XCTAssertEqual(series.maximumValueDescription, "95%")
        XCTAssertEqual(series.rangeDescription, "Range 20% to 95%")
        XCTAssertEqual(series.changeDescription, "Down 55 pts")
        XCTAssertEqual(series.direction, .down)
        XCTAssertEqual(series.sampleWindowDescription.components(separatedBy: " - ").count, 3)
        XCTAssertEqual(series.chartDomain, 0...1)

        let flatResult = makeHistoryResult(
            accountID: "flat.usage",
            fetchedAt: now.addingTimeInterval(-60),
            used: 40
        )
        store.record(results: [flatResult], now: now)
        store.record(
            results: [makeHistoryResult(accountID: "flat.usage", fetchedAt: now, used: 40)],
            now: now
        )

        let flatSeries = store.historySeries(for: flatResult)
        XCTAssertEqual(flatSeries.rangeDescription, "Flat at 40%")
        XCTAssertEqual(flatSeries.changeDescription, "No change")
        XCTAssertEqual(flatSeries.direction, .flat)
    }

    @MainActor
    func testPercentageChartDomainExpandsPastHighestOverLimitValue() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let store = UsageHistoryStore(defaults: defaults)
        let samples = [
            makeHistoryResult(
                accountID: "copilot.organization",
                providerID: .copilot,
                fetchedAt: now.addingTimeInterval(-60),
                used: 80
            ),
            makeHistoryResult(
                accountID: "copilot.organization",
                providerID: .copilot,
                fetchedAt: now,
                used: 125
            ),
        ]

        for sample in samples {
            store.record(results: [sample], now: now)
        }

        let series = store.historySeries(for: samples[1])

        XCTAssertEqual(series.points.map(\.value), [0.8, 1.25])
        XCTAssertEqual(series.chartDomain.lowerBound, 0)
        XCTAssertGreaterThan(series.chartDomain.upperBound, 1.25)
        XCTAssertEqual(series.latestValueDescription, "125%")
        XCTAssertEqual(series.maximumValueDescription, "125%")
        XCTAssertEqual(series.rangeDescription, "Range 80% to 125%")
        XCTAssertTrue(series.showsQuotaLimitRule)
    }

    @MainActor
    func testPercentageChartDomainStaysAtOneHundredPercentAtOrBelowLimit() {
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let series = UsageHistorySeries(
            accountID: "copilot.organization",
            points: [
                UsageHistoryPoint(id: "under", capturedAt: now.addingTimeInterval(-60), value: 0.8, severity: .normal),
                UsageHistoryPoint(id: "limit", capturedAt: now, value: 1, severity: .critical),
            ],
            isBalance: false
        )

        XCTAssertEqual(series.chartDomain, 0...1)
        XCTAssertEqual(series.latestValueDescription, "100%")
        XCTAssertTrue(series.showsQuotaLimitRule)
    }

    @MainActor
    func testUsageHistorySeriesPadsFlatBalanceChartDomain() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let result = makeHistoryResult(
            accountID: "openrouter.work",
            providerID: .openRouter,
            fetchedAt: now,
            creditsRemaining: 19.25
        )
        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [result], now: now)

        let series = store.historySeries(for: result)
        XCTAssertTrue(series.isBalance)
        XCTAssertEqual(series.latestValueDescription, "$19.25")
        XCTAssertEqual(series.rangeDescription, "Flat at $19.25")
        XCTAssertLessThan(series.chartDomain.lowerBound, 19.25)
        XCTAssertGreaterThan(series.chartDomain.upperBound, 19.25)

        let overdrawnResult = makeHistoryResult(
            accountID: "openrouter.overdrawn",
            providerID: .openRouter,
            fetchedAt: now,
            creditsRemaining: -3
        )
        store.record(results: [overdrawnResult], now: now)

        let overdrawnSeries = store.historySeries(for: overdrawnResult)
        XCTAssertLessThan(overdrawnSeries.chartDomain.lowerBound, -3)
        XCTAssertGreaterThan(overdrawnSeries.chartDomain.upperBound, -3)
    }

    @MainActor
    func testProviderUsageCardHistoryVisibilityDoesNotDiscardStoredHistory() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let priorResult = makeHistoryResult(
            accountID: "openrouter.personal",
            providerID: .openRouter,
            fetchedAt: now.addingTimeInterval(-60),
            creditsRemaining: 19.25
        )
        let failedResult = ProviderUsageResult(
            accountID: priorResult.accountID,
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Session expired",
            bars: [],
            fetchedAt: now
        )
        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [priorResult], now: now)
        let history = store.historySeries(for: failedResult)

        let hiddenCard = ProviderUsageCard(
            result: failedResult,
            statusText: failedResult.subtitle,
            history: history,
            isHistoryEnabled: false
        )
        let visibleCard = ProviderUsageCard(
            result: failedResult,
            statusText: failedResult.subtitle,
            history: history,
            isHistoryEnabled: true
        )

        XCTAssertFalse(hiddenCard.showsHistory)
        XCTAssertTrue(visibleCard.showsHistory)
        XCTAssertFalse(history.points.isEmpty)
        XCTAssertTrue(history.isBalance)
        XCTAssertEqual(history.latestValueDescription, "$19.25")
    }

    func testProviderUsageCardOffersRetryForCachedRefreshFailure() {
        let result = makeHistoryResult(
            accountID: "codex.cached",
            providerID: .codex,
            fetchedAt: Date(),
            used: 25
        )
        let failedCard = ProviderUsageCard(
            result: result,
            statusText: "Refresh failed - Session expired",
            history: UsageHistorySeries(accountID: result.accountID, points: [], isBalance: false),
            refreshErrorMessage: "Session expired"
        )
        let refreshingCard = ProviderUsageCard(
            result: result,
            statusText: "Refreshing",
            history: UsageHistorySeries(accountID: result.accountID, points: [], isBalance: false),
            isRefreshing: true,
            refreshErrorMessage: "Session expired"
        )

        XCTAssertTrue(failedCard.showsRetryAction)
        XCTAssertFalse(refreshingCard.showsRetryAction)
    }

    func testProviderUsageCardHeaderAccessibilityIncludesNaturalPlanName() {
        let result = ProviderUsageResult(
            accountID: "claude.work",
            providerID: .claude,
            title: "Work Claude",
            plan: ProviderPlanDescriptor(
                identifier: "claude.max20",
                displayLabel: "MAX 20×",
                accessibilityLabel: "Max 20x"
            ),
            subtitle: "Live Claude usage",
            bars: [],
            fetchedAt: Date()
        )

        XCTAssertEqual(
            ProviderUsageCard.headerAccessibilityLabel(for: result),
            "Work Claude, Max 20x"
        )
        let resultWithVerifiedGrokPlan = ProviderUsageResult(
            accountID: "grok.personal", providerID: .grok, title: "Grok",
            verifiedGrokPlanName: "SuperGrok Lite", subtitle: "Live Grok usage", bars: [], fetchedAt: Date()
        )
        XCTAssertEqual(
            ProviderUsageCard.headerAccessibilityLabel(for: resultWithVerifiedGrokPlan),
            "Grok, SuperGrok Lite"
        )
    }

    func testProviderUsageCardCarriesDisclosureStateAndActionIndependently() {
        let result = makeHistoryResult(
            accountID: "codex.collapsed",
            providerID: .codex,
            fetchedAt: Date(),
            used: 25
        )
        var toggleCount = 0
        let collapsedCard = ProviderUsageCard(
            result: result,
            statusText: "Current",
            history: UsageHistorySeries(accountID: result.accountID, points: [], isBalance: false),
            isExpanded: false,
            onToggleExpansion: {
                toggleCount += 1
            }
        )
        let expandedCard = ProviderUsageCard(
            result: result,
            statusText: "Current",
            history: UsageHistorySeries(accountID: result.accountID, points: [], isBalance: false)
        )

        XCTAssertFalse(collapsedCard.isExpanded)
        XCTAssertTrue(expandedCard.isExpanded)
        collapsedCard.onToggleExpansion()
        XCTAssertEqual(toggleCount, 1)
        XCTAssertEqual(
            ProviderUsageCard.disclosureAccessibilityHint(isExpanded: false, title: result.title),
            "Expand \(result.title)"
        )
        XCTAssertEqual(
            ProviderUsageCard.disclosureAccessibilityHint(isExpanded: true, title: result.title),
            "Collapse \(result.title)"
        )
        XCTAssertEqual(
            ProviderUsageCard.disclosureAccessibilityLabel(
                for: result,
                statusText: "Current",
                isRefreshing: true,
                isPerformingRecovery: false,
                severity: .warning
            ),
            "\(result.title), Plan unavailable, Current, Refreshing, Warning status"
        )
        XCTAssertEqual(
            ProviderUsageCard.disclosureAccessibilityLabel(
                for: result,
                statusText: "Session expired",
                isRefreshing: true,
                isPerformingRecovery: true,
                severity: .critical
            ),
            "\(result.title), Plan unavailable, Session expired, Signing in, Critical status"
        )
    }

    func testProviderUsageCardDistinguishesRetryAndClaudeSignInActions() {
        let result = makeHistoryResult(
            accountID: "claude.work",
            providerID: .claude,
            fetchedAt: Date(),
            used: 25
        )
        let reauthenticationCard = ProviderUsageCard(
            result: result,
            statusText: "Claude credential was rejected.",
            history: UsageHistorySeries(accountID: result.accountID, points: [], isBalance: false),
            refreshErrorMessage: "Claude credential was rejected.",
            recoveryAction: .reauthenticate
        )
        let signingInCard = ProviderUsageCard(
            result: result,
            statusText: "Signing in",
            history: UsageHistorySeries(accountID: result.accountID, points: [], isBalance: false),
            refreshErrorMessage: "Claude credential was rejected.",
            recoveryAction: .reauthenticate,
            isPerformingRecovery: true
        )
        let retryCard = ProviderUsageCard(
            result: result,
            statusText: "Offline",
            history: UsageHistorySeries(accountID: result.accountID, points: [], isBalance: false),
            refreshErrorMessage: "The Internet connection appears to be offline."
        )

        XCTAssertTrue(reauthenticationCard.showsRecoveryAction)
        XCTAssertFalse(reauthenticationCard.showsRetryAction)
        XCTAssertEqual(reauthenticationCard.recoveryActionTitle, "Sign in again")
        XCTAssertEqual(
            reauthenticationCard.recoveryAccessibilityHint,
            "Replaces the rejected Claude credential for \(result.title)"
        )
        XCTAssertFalse(signingInCard.showsRecoveryAction)
        XCTAssertTrue(retryCard.showsRetryAction)
        XCTAssertEqual(retryCard.recoveryActionTitle, "Retry")
        XCTAssertEqual(
            retryCard.recoveryAccessibilityHint,
            "Retries refreshing usage for \(result.title)"
        )

        let greptileResult = ProviderUsageResult(
            accountID: "greptile.team",
            providerID: .greptile,
            title: "Greptile",
            subtitle: "API key required",
            bars: [],
            fetchedAt: Date()
        )
        let greptileCard = ProviderUsageCard(
            result: greptileResult,
            statusText: "API key required",
            history: UsageHistorySeries(accountID: greptileResult.accountID, points: [], isBalance: false),
            refreshErrorMessage: "Greptile needs an organization API key.",
            recoveryAction: .signIn
        )
        XCTAssertEqual(greptileCard.recoveryActionTitle, "Open account settings")
        XCTAssertEqual(
            greptileCard.recoveryAccessibilityHint,
            "Opens account settings for Greptile"
        )
    }

    @MainActor
    func testProviderUsageCardOpensBankedResetInventoryWithoutChangingSeverity() {
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "ChatGPT / Codex",
            subtitle: "Live ChatGPT usage",
            bars: [UsageBar(label: "5 hour usage limit", used: 25, limit: 100)],
            codexBankedRateLimitResets: CodexBankedRateLimitResets(
                availableCount: 1,
                credits: [
                    CodexBankedRateLimitReset(
                        id: "credit-1",
                        title: "Full reset (Weekly + 5 hr)",
                        expiresAt: Date(timeIntervalSince1970: 1_893_456_000)
                    ),
                ],
                canConsume: true
            ),
            fetchedAt: fetchedAt
        )
        var redemptionCount = 0
        let card = ProviderUsageCard(
            result: result,
            statusText: result.subtitle,
            history: UsageHistorySeries(accountID: result.accountID, points: [], isBalance: false),
            onUseCodexReset: { _ in
                redemptionCount += 1
                return CodexBankedResetRedemptionFeedback(message: "Reset used.", isSuccess: true)
            }
        )

        XCTAssertEqual(card.bankedResetAvailabilityText, "1 reset available")
        XCTAssertTrue(card.showsCodexResetInventoryAction)
        XCTAssertEqual(card.resetInventoryActionTitle, "View Resets")
        XCTAssertTrue(card.showsCodexResetRedemptionActions)
        XCTAssertEqual(result.highestSeverity, .normal)
        XCTAssertEqual(redemptionCount, 0)

        let readOnlyResult = ProviderUsageResult(
            accountID: result.accountID,
            providerID: .codex,
            title: result.title,
            subtitle: result.subtitle,
            bars: result.bars,
            codexBankedRateLimitResets: CodexBankedRateLimitResets(
                availableCount: 3,
                canConsume: false
            ),
            fetchedAt: fetchedAt
        )
        let readOnlyCard = ProviderUsageCard(
            result: readOnlyResult,
            statusText: readOnlyResult.subtitle,
            history: UsageHistorySeries(accountID: result.accountID, points: [], isBalance: false)
        )
        XCTAssertEqual(readOnlyCard.bankedResetAvailabilityText, "3 resets available")
        XCTAssertTrue(readOnlyCard.showsCodexResetInventoryAction)
        XCTAssertFalse(readOnlyCard.showsCodexResetRedemptionActions)

        let zeroResult = ProviderUsageResult(
            accountID: result.accountID,
            providerID: .codex,
            title: result.title,
            subtitle: result.subtitle,
            bars: result.bars,
            codexBankedRateLimitResets: CodexBankedRateLimitResets(availableCount: 0),
            fetchedAt: fetchedAt
        )
        let zeroCard = ProviderUsageCard(
            result: zeroResult,
            statusText: zeroResult.subtitle,
            history: UsageHistorySeries(accountID: result.accountID, points: [], isBalance: false)
        )
        XCTAssertNil(zeroCard.bankedResets)
    }

    @MainActor
    func testResetInventoryOrdersDetailedCreditsAndFormatsMissingMetadata() throws {
        let formatter = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)),
            locale: Locale(identifier: "en_US")
        )
        let later = Date(timeIntervalSince1970: 1_893_456_000)
        let sooner = later.addingTimeInterval(-3_600)
        let resets = CodexBankedRateLimitResets(
            availableCount: 4,
            credits: [
                CodexBankedRateLimitReset(id: "missing"),
                CodexBankedRateLimitReset(
                    id: "later",
                    title: "Weekly reset",
                    description: "Restores weekly usage",
                    expiresAt: later
                ),
                CodexBankedRateLimitReset(
                    id: "sooner",
                    title: "5-hour reset",
                    expiresAt: sooner
                ),
                CodexBankedRateLimitReset(id: "missing-second", title: " "),
            ],
            canConsume: true
        )

        XCTAssertEqual(resets.orderedCredits.map(\.id), [
            "sooner",
            "later",
            "missing",
            "missing-second",
        ])

        let soonerItem = CodexBankedResetInventoryItem(
            credit: try XCTUnwrap(resets.orderedCredits.first),
            dateTimeFormatter: formatter
        )
        XCTAssertEqual(soonerItem.creditID, "sooner")
        XCTAssertEqual(soonerItem.title, "5-hour reset")
        XCTAssertEqual(soonerItem.detail, "No description provided.")
        XCTAssertEqual(soonerItem.expiration, "Expires \(formatter.dateAndTime(sooner))")
        XCTAssertTrue(soonerItem.accessibilityLabel.contains("available"))

        let missingItem = CodexBankedResetInventoryItem(
            credit: try XCTUnwrap(resets.orderedCredits.last),
            dateTimeFormatter: formatter
        )
        XCTAssertEqual(missingItem.title, "Banked reset")
        XCTAssertEqual(missingItem.detail, "No description provided.")
        XCTAssertEqual(missingItem.expiration, "Expiration unavailable")
    }

    @MainActor
    func testResetInventoryUsesConservativeCountOnlyFallback() {
        let countOnly = CodexBankedRateLimitResets(
            availableCount: 3,
            canConsume: true
        )
        let actionableInventory = CodexBankedResetInventoryView(
            resets: countOnly,
            canRedeem: true,
            onUseReset: { _ in
                CodexBankedResetRedemptionFeedback(message: "Reset used.", isSuccess: true)
            },
            onFeedback: { _ in },
            redemptionController: CodexBankedResetRedemptionController()
        )
        let genericItem = actionableInventory.inventoryItems.first
        XCTAssertEqual(actionableInventory.inventoryItems.count, 1)
        XCTAssertEqual(genericItem?.title, "Use one banked reset")
        XCTAssertNil(genericItem?.creditID)
        XCTAssertEqual(genericItem?.expiration, "Expiration unavailable")

        let mixedInventory = CodexBankedResetInventoryView(
            resets: CodexBankedRateLimitResets(
                availableCount: 3,
                credits: [
                    CodexBankedRateLimitReset(id: "credit-first", title: "First"),
                    CodexBankedRateLimitReset(id: "credit-second", title: "Second"),
                ],
                canConsume: true
            ),
            canRedeem: true,
            onUseReset: { _ in
                CodexBankedResetRedemptionFeedback(message: "Reset used.", isSuccess: true)
            },
            onFeedback: { _ in },
            redemptionController: CodexBankedResetRedemptionController()
        )
        XCTAssertEqual(
            mixedInventory.inventoryItems.map(\.id),
            ["credit-first", "credit-second", "generic-banked-reset"]
        )

        let readOnlyInventory = CodexBankedResetInventoryView(
            resets: countOnly,
            canRedeem: false,
            onUseReset: nil,
            onFeedback: { _ in },
            redemptionController: CodexBankedResetRedemptionController()
        )
        XCTAssertTrue(readOnlyInventory.inventoryItems.isEmpty)
        XCTAssertEqual(readOnlyInventory.unavailableDetailCount, 3)
    }

    @MainActor
    func testResetInventorySelectionSupportsNonFirstCreditCancellationAndDuplicateTapGuard() throws {
        let first = CodexBankedResetInventoryItem(
            credit: CodexBankedRateLimitReset(id: "credit-first", title: "First")
        )
        let second = CodexBankedResetInventoryItem(
            credit: CodexBankedRateLimitReset(id: "credit-second", title: "Second")
        )
        let controller = CodexBankedResetRedemptionController()

        controller.requestConfirmation(for: first)
        controller.cancelConfirmation()
        XCTAssertNil(controller.beginRedemption())

        controller.requestConfirmation(for: second)
        let alertPresentedItem = try XCTUnwrap(controller.selectedItem)
        controller.cancelConfirmation()
        let selected = controller.beginRedemption(for: alertPresentedItem)
        XCTAssertEqual(selected?.creditID, "credit-second")
        XCTAssertEqual(controller.pendingItemID, second.id)
        XCTAssertNil(controller.beginRedemption())

        controller.requestConfirmation(for: first)
        XCTAssertNil(controller.selectedItem)
        controller.finishRedemption(for: second, requiresSameResetForRetry: true)
        XCTAssertNil(controller.pendingItemID)
        XCTAssertEqual(controller.retryItemID, second.id)
        XCTAssertFalse(controller.canRequestConfirmation(for: first))
        XCTAssertTrue(controller.canRequestConfirmation(for: second))

        controller.requestConfirmation(for: second)
        XCTAssertEqual(controller.beginRedemption()?.creditID, "credit-second")
        controller.finishRedemption(for: second, requiresSameResetForRetry: true)

        let reopenedInventory = CodexBankedResetInventoryView(
            resets: CodexBankedRateLimitResets(
                availableCount: 2,
                credits: [
                    CodexBankedRateLimitReset(id: "credit-first", title: "First"),
                    CodexBankedRateLimitReset(id: "credit-second", title: "Second"),
                ],
                canConsume: true
            ),
            canRedeem: true,
            onUseReset: { _ in
                CodexBankedResetRedemptionFeedback(message: "Reset used.", isSuccess: true)
            },
            onFeedback: { _ in },
            redemptionController: controller
        )
        XCTAssertEqual(reopenedInventory.redemptionController.retryItemID, second.id)
        XCTAssertFalse(reopenedInventory.redemptionController.canRequestConfirmation(for: first))
        XCTAssertTrue(reopenedInventory.redemptionController.canRequestConfirmation(for: second))

        controller.requestConfirmation(for: second)
        XCTAssertEqual(controller.beginRedemption()?.creditID, "credit-second")
        controller.finishRedemption(for: second)
        XCTAssertNil(controller.retryItemID)
    }

    @MainActor
    func testResetInventoryPreservesCountOnlyRetryWhenDetailedMetadataArrives() {
        let genericItem = CodexBankedResetInventoryItem.generic()
        let controller = CodexBankedResetRedemptionController()

        controller.requestConfirmation(for: genericItem)
        XCTAssertNil(controller.beginRedemption()?.creditID)
        controller.finishRedemption(for: genericItem, requiresSameResetForRetry: true)

        let detailedInventory = CodexBankedResetInventoryView(
            resets: CodexBankedRateLimitResets(
                availableCount: 2,
                credits: [
                    CodexBankedRateLimitReset(id: "credit-first", title: "First"),
                    CodexBankedRateLimitReset(id: "credit-second", title: "Second"),
                ],
                canConsume: true
            ),
            canRedeem: true,
            onUseReset: { _ in
                CodexBankedResetRedemptionFeedback(message: "Reset used.", isSuccess: true)
            },
            onFeedback: { _ in },
            redemptionController: controller
        )

        XCTAssertEqual(
            detailedInventory.inventoryItems.map(\.id),
            ["generic-banked-reset", "credit-first", "credit-second"]
        )
        XCTAssertTrue(controller.canRequestConfirmation(for: genericItem))
        XCTAssertFalse(
            controller.canRequestConfirmation(for: detailedInventory.inventoryItems[1])
        )
    }

    @MainActor
    func testResetInventoryControllerRestoresRetainedAttemptAfterCardRecreation() {
        let resets = CodexBankedRateLimitResets(
            availableCount: 2,
            credits: [
                CodexBankedRateLimitReset(id: "credit-first", title: "First"),
                CodexBankedRateLimitReset(id: "credit-original", title: "Original"),
            ],
            canConsume: true
        )
        let controller = CodexBankedResetRedemptionController(
            retainedAttempt: CodexRetainedResetAttempt(creditID: "credit-original"),
            resets: resets
        )
        let items = resets.orderedCredits.map {
            CodexBankedResetInventoryItem(credit: $0)
        }

        XCTAssertEqual(controller.retryItemID, "credit-original")
        XCTAssertFalse(controller.canRequestConfirmation(for: items[0]))
        XCTAssertTrue(controller.canRequestConfirmation(for: items[1]))

        let genericController = CodexBankedResetRedemptionController(
            retainedAttempt: CodexRetainedResetAttempt(creditID: nil),
            resets: resets
        )
        XCTAssertEqual(genericController.retryItemID, "generic-banked-reset")
    }

    @MainActor
    func testProviderUsageCardKeepsResetFeedbackAfterFinalCreditDisappears() {
        let feedback = CodexBankedResetRedemptionFeedback(
            message: "Reset used. Current usage limits are refreshed.",
            isSuccess: true
        )

        XCTAssertEqual(
            ProviderUsageCard.resetPresentationFeedback(feedback, availableResets: nil),
            feedback
        )
    }

    @MainActor
    func testResetInventoryPresentationRetainsPayloadAndCapabilityWhenCardChanges() throws {
        let initialResets = CodexBankedRateLimitResets(
            availableCount: 1,
            credits: [CodexBankedRateLimitReset(id: "credit-first", title: "First")],
            canConsume: true
        )
        let presentation = ProviderUsageCard.reconciledResetInventoryPresentation(
            current: nil,
            requestedResets: initialResets,
            canRedeem: false,
            requestsPresentation: true
        )
        let refreshedResets = CodexBankedRateLimitResets(
            availableCount: 2,
            credits: [
                CodexBankedRateLimitReset(id: "credit-second", title: "Second"),
                CodexBankedRateLimitReset(id: "credit-third", title: "Third"),
            ],
            canConsume: true
        )
        let reconciled = ProviderUsageCard.reconciledResetInventoryPresentation(
            current: presentation,
            requestedResets: refreshedResets,
            canRedeem: true,
            requestsPresentation: false
        )

        XCTAssertEqual(reconciled, presentation)
        XCTAssertEqual(reconciled?.resets, initialResets)
        XCTAssertFalse(try XCTUnwrap(reconciled).canRedeem)
    }

}
