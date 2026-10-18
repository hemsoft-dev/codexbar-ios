import XCTest
@testable import CodexBarIOS

final class HistoryAccessPolicyTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 15))!
    }

    private var cutoff: Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: 4))!
    }

    func testFreeCutoffUsesSevenInclusiveLocalDaysAcrossDaylightSavingTime() {
        XCTAssertEqual(HistoryAccessPolicy.free.cutoff(now: now, calendar: calendar), cutoff)
        XCTAssertEqual(UsageHistoryRange.sevenDays.startDate(now: now, calendar: calendar), cutoff)
        XCTAssertNil(HistoryAccessPolicy.pro.cutoff(now: now, calendar: calendar))
        for range in UsageHistoryRange.allCases {
            XCTAssertEqual(HistoryAccessPolicy.free.allows(range: range), range != .month && range != .threeMonths)
            XCTAssertTrue(HistoryAccessPolicy.pro.allows(range: range))
        }
    }

    func testFilteredSeriesRevalidatesCurrentPolicyWithoutMutatingPresentedSource() {
        let dates = [cutoff.addingTimeInterval(-1), cutoff, cutoff.addingTimeInterval(1), now]
        let original = UsageHistorySeries(
            accountID: "cursor.personal",
            points: dates.enumerated().map {
                UsageHistoryPoint(id: "sample-\($0.offset)", capturedAt: $0.element, value: Double($0.offset), severity: .normal)
            },
            isBalance: false
        )

        for range in [UsageHistoryRange.sevenDays, .month, .threeMonths] {
            XCTAssertEqual(
                original.filtered(to: range, accessPolicy: .free, now: now, calendar: calendar).points.map(\.capturedAt),
                Array(dates.dropFirst())
            )
        }
        XCTAssertEqual(
            original.filtered(to: .today, accessPolicy: .free, now: now, calendar: calendar).points.map(\.capturedAt),
            [now]
        )
        XCTAssertEqual(
            original.filtered(to: .threeMonths, accessPolicy: .pro, now: now, calendar: calendar).points,
            original.points
        )
        XCTAssertEqual(original.points.count, dates.count)
    }

    @MainActor
    func testEveryStorePresentationSurfaceSharesCutoffAndUpgradeRestoresStoredHistory() throws {
        let suiteName = "HistoryAccessPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UsageHistoryStore(defaults: defaults, retentionDays: 90)
        let dates = [now.addingTimeInterval(-50 * 86_400), cutoff.addingTimeInterval(-1), cutoff, cutoff.addingTimeInterval(1), now]
        let results = dates.enumerated().map { makeResult(at: $0.element, used: Double($0.offset + 1) * 10) }
        let current = try XCTUnwrap(results.last)
        store.record(results: results, now: now)
        let savedSnapshots = store.snapshots
        let savedDailySnapshots = store.dailySnapshots
        let savedRawData = defaults.data(forKey: "usageHistorySnapshots")
        let savedDailyData = defaults.data(forKey: "usageHistoryDailySnapshots")
        let fullSeries = store.historySeries(for: current, now: now, calendar: calendar)
        let fullOptions = store.historySeriesOptions(for: current, now: now, calendar: calendar)

        store.applyHistoryAccess(hasProAccess: false)
        let visibleDates = Array(dates.suffix(3))
        XCTAssertEqual(store.accessPolicy, .free)
        XCTAssertEqual(store.snapshots(for: current.accountID, now: now, calendar: calendar).map(\.capturedAt), visibleDates)
        XCTAssertEqual(store.historySeries(for: current, now: now, calendar: calendar).points.map(\.capturedAt), visibleDates)
        XCTAssertEqual(store.trendSummary(for: current, now: now, calendar: calendar)?.points, [0.3, 0.4, 0.5])
        let options = store.historySeriesOptions(for: current, now: now, calendar: calendar)
        XCTAssertEqual(options.count, 4)
        for option in options {
            XCTAssertEqual(option.series.points.map(\.capturedAt), visibleDates, option.id)
        }
        XCTAssertEqual(
            store.historySeries(for: current, since: now, now: now, calendar: calendar).points.map(\.capturedAt),
            [now]
        )
        XCTAssertEqual(store.snapshots, savedSnapshots)
        XCTAssertEqual(store.dailySnapshots, savedDailySnapshots)
        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), savedRawData)
        XCTAssertEqual(defaults.data(forKey: "usageHistoryDailySnapshots"), savedDailyData)

        store.applyHistoryAccess(hasProAccess: true)
        let restoredSeries = store.historySeries(for: current, now: now, calendar: calendar)
        XCTAssertEqual(restoredSeries.points.map(\.capturedAt), fullSeries.points.map(\.capturedAt))
        XCTAssertEqual(restoredSeries.points.map(\.value), fullSeries.points.map(\.value))
        let restoredOptions = store.historySeriesOptions(for: current, now: now, calendar: calendar)
        XCTAssertEqual(restoredOptions.map(\.id), fullOptions.map(\.id))
        for (restored, original) in zip(restoredOptions, fullOptions) {
            XCTAssertEqual(restored.series.points.map(\.capturedAt), original.series.points.map(\.capturedAt), original.id)
            XCTAssertEqual(restored.series.points.map(\.value), original.series.points.map(\.value), original.id)
        }
        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), savedRawData)
        XCTAssertEqual(defaults.data(forKey: "usageHistoryDailySnapshots"), savedDailyData)
    }

    @MainActor
    func testDailyOnlySamplesFollowSameCutoffAndRemainAvailableAfterUpgrade() throws {
        let suiteName = "HistoryAccessPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UsageHistoryStore(defaults: defaults, retentionDays: 1)
        let dates = [cutoff.addingTimeInterval(-1), cutoff, now]
        let results = dates.enumerated().map { makeResult(at: $0.element, used: Double($0.offset + 1) * 10) }
        let current = try XCTUnwrap(results.last)
        store.record(results: results, now: now)
        XCTAssertEqual(store.snapshots.count, 1)
        let dailySnapshots = store.dailySnapshots

        store.applyHistoryAccess(hasProAccess: false)
        XCTAssertEqual(store.historySeries(for: current, now: now, calendar: calendar).points.map(\.capturedAt), [cutoff, now])
        for option in store.historySeriesOptions(for: current, now: now, calendar: calendar) {
            XCTAssertEqual(option.series.points.map(\.capturedAt), [cutoff, now], option.id)
        }
        store.applyHistoryAccess(hasProAccess: true)
        XCTAssertEqual(store.historySeries(for: current, now: now, calendar: calendar).points.map(\.capturedAt), dates)
        XCTAssertEqual(store.dailySnapshots, dailySnapshots)
    }

    @MainActor
    func testHistoricalCurrentResultCannotBypassFreeCutoff() throws {
        let suiteName = "HistoryAccessPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UsageHistoryStore(defaults: defaults, accessPolicy: .free)
        let oldResult = makeResult(at: cutoff.addingTimeInterval(-1), used: 95)

        XCTAssertTrue(store.historySeries(for: oldResult, now: now, calendar: calendar).points.isEmpty)
        for option in store.historySeriesOptions(for: oldResult, now: now, calendar: calendar) {
            XCTAssertTrue(option.series.points.isEmpty, option.id)
        }
        XCTAssertNil(store.trendSummary(for: oldResult, now: now, calendar: calendar))
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(store.dailySnapshots.isEmpty)
    }

    @MainActor
    func testMetricDetailChartsClampPreviouslyPresentedProOptions() throws {
        let suiteName = "HistoryAccessPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let displayDate = Date()
        let store = UsageHistoryStore(defaults: defaults)
        let old = makeResult(at: displayDate.addingTimeInterval(-10 * 86_400), used: 15)
        let current = makeResult(at: displayDate, used: 55)
        store.record(results: [old, current], now: displayDate)
        let originalSeries = store.historySeries(for: current)
        let originalOptions = store.historySeriesOptions(for: current)
        let freeCard = ProviderUsageCard(
            result: current,
            statusText: "Paused: CodexBar Pro",
            history: originalSeries,
            historyAccessPolicy: .free,
            historySeriesOptions: { originalOptions }
        )
        let proCard = ProviderUsageCard(
            result: current,
            statusText: "Updated",
            history: originalSeries,
            historyAccessPolicy: .pro,
            historySeriesOptions: { originalOptions }
        )

        XCTAssertEqual(current.availableMetrics.count, 4)
        for metric in current.availableMetrics {
            let freeSeries = try XCTUnwrap(freeCard.metricDetailHistorySeries(for: metric), metric.id)
            let proSeries = try XCTUnwrap(proCard.metricDetailHistorySeries(for: metric), metric.id)
            XCTAssertEqual(freeSeries.points.map(\.capturedAt), [displayDate], metric.id)
            XCTAssertEqual(proSeries.points.map(\.capturedAt), [old.fetchedAt, displayDate], metric.id)
        }
    }

    @MainActor
    func testColdStartFallbackUsesOriginalObservationEvenOutsideHistoryWindow() throws {
        let suiteName = "HistoryAccessPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let original = makeResult(at: cutoff.addingTimeInterval(-1), used: 47)
        let writer = UsageHistoryStore(defaults: defaults, retentionDays: 1)
        writer.record(results: [original], now: now)
        XCTAssertTrue(writer.snapshots.isEmpty)
        let reloaded = UsageHistoryStore(defaults: defaults, accessPolicy: .free)
        let configuration = ProviderAccountConfiguration(
            id: original.accountID, providerID: .cursor, accountLabel: "My Cursor", authMethod: .browserSession
        )
        let savedDailyData = defaults.data(forKey: "usageHistoryDailySnapshots")

        let fallback = try XCTUnwrap(reloaded.lastStoredResult(for: configuration))
        XCTAssertEqual(fallback.accountID, original.accountID)
        XCTAssertEqual(fallback.title, "My Cursor")
        XCTAssertEqual(fallback.fetchedAt, original.fetchedAt)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: fallback.bars.map { ($0.stableKey, $0.used) }),
            Dictionary(uniqueKeysWithValues: original.bars.map { ($0.stableKey, $0.used) })
        )
        XCTAssertEqual(fallback.creditsRemaining, original.creditsRemaining)
        XCTAssertEqual(fallback.monetaryMetrics, original.monetaryMetrics)
        XCTAssertNil(fallback.plan)
        XCTAssertTrue(fallback.bars.allSatisfy { $0.resetsAt == nil })
        XCTAssertTrue(reloaded.historySeries(for: fallback, now: now, calendar: calendar).points.isEmpty)
        XCTAssertTrue(reloaded.snapshots.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "usageHistoryDailySnapshots"), savedDailyData)
        XCTAssertNil(reloaded.lastStoredResult(for: ProviderAccountConfiguration(
            id: original.accountID, providerID: .claude, authMethod: .browserSession
        )))
        XCTAssertNil(reloaded.lastStoredResult(for: ProviderAccountConfiguration(
            id: "cursor.another", providerID: .cursor, authMethod: .browserSession
        )))
    }

    private func makeResult(at date: Date, used: Double) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: "cursor.personal",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Personal account",
            bars: [
                UsageBar(stableKey: "total", label: "Total", used: used, limit: 100),
                UsageBar(stableKey: CursorUsageIdentity.cursorModelsStableKey, label: "Cursor Models", used: used / 2, limit: 100),
            ],
            creditsRemaining: 100 - used,
            monetaryMetrics: [
                ProviderMonetaryMetric(kind: .spent, label: "Spent", minorUnits: Decimal(used * 100), currencyCode: "USD", decimalPlaces: 2),
            ],
            fetchedAt: date
        )
    }
}
