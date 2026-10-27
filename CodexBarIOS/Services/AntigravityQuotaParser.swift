import Foundation

enum AntigravityQuotaParser {
    static let metrics = GoogleUsageMetricCatalog.definitions(for: .antigravity)

    private struct Summary: Decodable {
        let groups: [Group]
    }

    private struct Group: Decodable {
        let buckets: [Bucket]
    }

    private struct Bucket: Decodable {
        let bucketId: String
        let window: String?
        let remainingFraction: Double?
        let resetTime: String?
        let disabled: Bool?
    }

    static func result(
        from data: Data,
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date = Date()
    ) throws -> ProviderUsageResult {
        let summary = try JSONDecoder().decode(Summary.self, from: data)
        let buckets = summary.groups.flatMap(\.buckets)
        let bars = metrics.compactMap { metric -> UsageBar? in
            let matches = buckets.filter { $0.bucketId == metric.key }
            guard matches.count == 1, let bucket = matches.first else { return nil }
            return bar(for: metric, bucket: bucket, fetchedAt: fetchedAt)
        }
        let missing = metrics.filter { metric in !bars.contains { $0.stableKey == metric.key } }
        let unavailable = Dictionary(uniqueKeysWithValues: missing.map { metric in
            let matches = buckets.filter { $0.bucketId == metric.key }
            let reason = matches.count == 1 && matches.first?.disabled == true
                ? GoogleUsageMetricCatalog.disabledReason : "Unavailable"
            return ("antigravity.\(metric.key)", reason)
        })
        let message = missing.isEmpty ? nil : "Unavailable: " + missing.map(\.label).joined(separator: ", ") + "."
        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: .antigravity,
            title: configuration.displayName,
            subtitle: "Antigravity quota groups",
            bars: bars,
            unavailableUsageMetrics: unavailable,
            usageMessages: message.map { [$0] } ?? [],
            failureMessage: bars.isEmpty ? message : nil,
            fetchedAt: fetchedAt
        )
    }

    /// On September 5, 2026 production answered HTTP 200 with every pool at full remaining while the CLI showed usage.
    /// A response whose supplied canonical pools are all full cannot be told apart from that placeholder.
    static func isAllFullPlaceholder(_ data: Data) -> Bool {
        guard let summary = try? JSONDecoder().decode(Summary.self, from: data) else { return false }
        let keys = Set(metrics.map(\.key))
        let fractions = summary.groups.flatMap(\.buckets)
            .filter { keys.contains($0.bucketId) && $0.disabled != true }
            .compactMap(\.remainingFraction)
        return !fractions.isEmpty && fractions.allSatisfy { $0 >= 1 }
    }

    private static func bar(for metric: GoogleUsageMetricCatalog.Definition, bucket: Bucket, fetchedAt: Date) -> UsageBar? {
        guard bucket.window == metric.window, bucket.disabled != true,
              let remaining = bucket.remainingFraction,
              remaining.isFinite, (0...1).contains(remaining) else { return nil }
        let reset = bucket.resetTime.flatMap(date)
        // A malformed or elapsed supplied reset cannot establish a current allowance.
        if bucket.resetTime != nil && (reset == nil || reset! <= fetchedAt) { return nil }
        return UsageBar(
            stableKey: metric.key,
            label: metric.label,
            used: 100 * (1 - remaining),
            limit: 100,
            resetsAt: reset,
            resetDisplayStyle: .relativeWithLocalTime,
            projectionCurrent: 1 - remaining,
            projectionLimit: 1,
            projectionPeriodStart: reset?.addingTimeInterval(metric.window == "5h" ? -5 * 60 * 60 : -7 * 24 * 60 * 60),
            projectionPeriodEnd: reset,
            showProjectionOnCurrentBar: true
        )
    }

    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
