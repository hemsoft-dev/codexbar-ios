import CodexBarIOS
import Foundation
import Darwin

private struct RetainedState: Encodable {
    let snapshots: Int
    let dailySnapshots: Int
    let serializedBytes: Int
}

private struct Scenario: Encodable {
    let accounts: Int
    let recordMilliseconds: [Double]
    let seriesMilliseconds: [Double]
    let seriesPointCount: Int
    let retainedStates: [RetainedState]
}

private struct Report: Encodable {
    let fixtureVersion = 1
    let qosClass: UInt32
    let configuration: String
    let timeZone: String
    let warmupBatches = 2
    let measuredBatches = 5
    let seriesIterationsPerBatch = 5
    let scenarios: [Scenario]
}

private enum BenchmarkError: Error {
    case invalidFixture(String)
}

@main
private struct UsageHistoryBenchmark {
    // Noon UTC keeps all timed/steady-state samples within one calendar day.
    static let anchor = Date(timeIntervalSince1970: 1_788_696_000)
    static let day: TimeInterval = 86_400
    static let metricKeys = ["fiveHour", "weekly"]

    @MainActor
    static func main() throws {
        let schedulingStatus = pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
        guard schedulingStatus == 0 else {
            throw BenchmarkError.invalidFixture("Cannot request user-initiated QoS: \(schedulingStatus)")
        }
        try requireBenchmarkQoS()
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        guard TimeZone.current.secondsFromGMT(for: anchor) == 0 else {
            throw BenchmarkError.invalidFixture("Run with TZ=UTC")
        }
        let report = Report(
            qosClass: qos_class_self().rawValue,
            configuration: configuration,
            timeZone: "UTC",
            scenarios: try [1, 10, 25].map(run)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    static func result(account: Int, at date: Date, metric: Int? = nil) -> ProviderUsageResult {
        let metrics = metric.map { [$0] } ?? [0, 1]
        return ProviderUsageResult(
            accountID: String(format: "benchmark.account.%02d", Int32(account)),
            providerID: .codex,
            title: "Benchmark",
            subtitle: "Synthetic history",
            bars: metrics.map { index in
                UsageBar(
                    stableKey: metricKeys[index],
                    label: index == 0 ? "Five hours" : "Weekly",
                    used: index == 0 ? 37 : 62,
                    limit: 100
                )
            },
            fetchedAt: date
        )
    }

    static func fixtures(accounts: Int) throws -> (frequent: Data, daily: Data) {
        var frequent: [UsageHistorySnapshot] = []
        var daily: [[String: Any]] = []
        let encoder = JSONEncoder()
        for account in 0..<accounts {
            for sample in 0..<240 {
                let date = anchor.addingTimeInterval(-Double(240 - sample) * 7_200)
                frequent.append(UsageHistorySnapshot(result: result(account: account, at: date)))
            }
            for daysBack in 0..<90 {
                let date = anchor.addingTimeInterval(-Double(daysBack) * day - 3_600)
                for metric in 0..<2 {
                    let snapshot = UsageHistorySnapshot(result: result(account: account, at: date, metric: metric))
                    guard var object = try JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as? [String: Any] else {
                        throw BenchmarkError.invalidFixture("Snapshot did not encode as an object")
                    }
                    // Daily components at a shared timestamp need distinct persisted identities.
                    object["id"] = "\(snapshot.id).daily.bar.\(metricKeys[metric])"
                    object.removeValue(forKey: "monetaryMetrics")
                    daily.append(object)
                }
            }
        }
        return (try encoder.encode(frequent), try JSONSerialization.data(withJSONObject: daily, options: [.sortedKeys]))
    }

    @MainActor
    static func run(accounts: Int) throws -> Scenario {
        try requireBenchmarkQoS()
        let suiteName = "UsageHistoryBenchmark.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw BenchmarkError.invalidFixture("Cannot create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = try fixtures(accounts: accounts)
        defaults.set(fixture.frequent, forKey: "usageHistorySnapshots")
        defaults.set(fixture.daily, forKey: "usageHistoryDailySnapshots")
        let store = UsageHistoryStore(defaults: defaults)
        var retained = [try state(store: store, defaults: defaults, accounts: accounts)]
        var recordSamples: [Double] = []
        var seriesSamples: [Double] = []
        var pointCount = 0
        for batch in 0..<7 {
            try requireBenchmarkQoS()
            let date = anchor.addingTimeInterval(Double(batch) * 600)
            let results = (0..<accounts).map { result(account: $0, at: date) }
            recordSamples.append(milliseconds {
                store.record(results: results, now: date)
            })
            try requireBenchmarkQoS()
            for result in results {
                let options = store.historySeriesOptions(for: result)
                guard options.map(\.id) == ["usage"], options[0].series.points.count == 329,
                      options[0].series.points.allSatisfy({ $0.value == 0.62 }) else {
                    throw BenchmarkError.invalidFixture("Expected 329 merged timestamps in the two-metric usage series")
                }
            }
            seriesSamples.append(milliseconds {
                for _ in 0..<5 {
                    for result in results {
                        let options = store.historySeriesOptions(
                            for: result,
                            since: anchor.addingTimeInterval(-89 * day - 43_200)
                        )
                        pointCount += options.reduce(0) { $0 + $1.series.points.count }
                    }
                }
            } / 5)
            try requireBenchmarkQoS()
            retained.append(try state(store: store, defaults: defaults, accounts: accounts))
        }
        guard pointCount == accounts * 329 * 5 * 7 else {
            throw BenchmarkError.invalidFixture("Timed series workload changed")
        }
        // Fresh captures replace the oldest frequent samples. Then cross seven daily
        // cutoffs so daily retention is exercised, rather than merely replacing today.
        for iteration in 7..<39 {
            let date = anchor.addingTimeInterval(Double(iteration) * 600)
            store.record(results: (0..<accounts).map { result(account: $0, at: date) }, now: date)
            retained.append(try state(store: store, defaults: defaults, accounts: accounts))
        }
        for daysForward in 1...7 {
            let date = anchor.addingTimeInterval(Double(daysForward) * day)
            store.record(results: (0..<accounts).map { result(account: $0, at: date) }, now: date)
            retained.append(try state(store: store, defaults: defaults, accounts: accounts))
        }
        return Scenario(
            accounts: accounts,
            recordMilliseconds: recordSamples,
            seriesMilliseconds: seriesSamples,
            seriesPointCount: pointCount,
            retainedStates: retained
        )
    }

    @MainActor
    static func state(store: UsageHistoryStore, defaults: UserDefaults, accounts: Int) throws -> RetainedState {
        guard !store.requiresRecovery, store.lastError == nil,
              store.snapshots.count == accounts * 240,
              store.dailySnapshots.count == accounts * 180 else {
            throw BenchmarkError.invalidFixture("History failed to retain 240 frequent / 180 daily entries per account")
        }
        try validateShape(store.snapshots, daily: false, accounts: accounts)
        try validateShape(store.dailySnapshots, daily: true, accounts: accounts)
        let decoder = JSONDecoder()
        for (key, daily) in [("usageHistorySnapshots", false), ("usageHistoryDailySnapshots", true)] {
            guard let data = defaults.data(forKey: key) else {
                throw BenchmarkError.invalidFixture("Missing persisted history")
            }
            try validateShape(decoder.decode([UsageHistorySnapshot].self, from: data), daily: daily, accounts: accounts)
        }
        let size = ["usageHistorySnapshots", "usageHistoryDailySnapshots"].reduce(0) {
            $0 + (defaults.data(forKey: $1)?.count ?? 0)
        }
        guard size > 0 else { throw BenchmarkError.invalidFixture("History did not persist") }
        return RetainedState(snapshots: store.snapshots.count, dailySnapshots: store.dailySnapshots.count, serializedBytes: size)
    }

    static func validateShape(_ snapshots: [UsageHistorySnapshot], daily: Bool, accounts: Int) throws {
        let grouped = Dictionary(grouping: snapshots, by: \.accountID)
        let expectedAccounts = Set((0..<accounts).map { String(format: "benchmark.account.%02d", Int32($0)) })
        guard Set(grouped.keys) == expectedAccounts, Set(snapshots.map(\.id)).count == snapshots.count else {
            throw BenchmarkError.invalidFixture("Lost an account or duplicated an identity")
        }
        for accountSnapshots in grouped.values {
            guard accountSnapshots.count == (daily ? 180 : 240),
                  accountSnapshots.allSatisfy({ $0.bars.count == (daily ? 1 : 2) }) else {
                throw BenchmarkError.invalidFixture("Per-account history shape changed")
            }
            if daily {
                let days = Dictionary(grouping: accountSnapshots) { Calendar.current.startOfDay(for: $0.capturedAt) }
                guard days.count == 90, days.values.allSatisfy({ entries in
                    entries.count == 2 && Set(entries.flatMap(\.bars).compactMap(\.stableKey)) == Set(metricKeys)
                }) else {
                    throw BenchmarkError.invalidFixture("Expected 90 distinct UTC days with both metrics")
                }
            } else if !accountSnapshots.allSatisfy({ Set($0.bars.compactMap(\.stableKey)) == Set(metricKeys) }) {
                throw BenchmarkError.invalidFixture("Frequent sample lost a metric")
            }
        }
    }

    static func requireBenchmarkQoS() throws {
        guard Thread.isMainThread, qos_class_self() == QOS_CLASS_USER_INITIATED else {
            throw BenchmarkError.invalidFixture("Benchmark must run on the user-initiated main thread")
        }
    }

    @MainActor
    static func milliseconds(_ operation: () -> Void) -> Double {
        let duration = ContinuousClock().measure(operation)
        return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
