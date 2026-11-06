import Foundation

enum AntigravityQuotaParser {
    static let metrics = GoogleUsageMetricCatalog.definitions(for: .antigravity)

    /// Pools only the production backend reports; the daily backend can omit them.
    static let productionOnlyKeys: Set<String> = ["gemini-5h", "gemini-weekly", "gemini-argon-wtu-weekly"]

    /// Why a production response was not shown. Fixed categories only; never response content.
    enum ProductionIssue: Equatable {
        case unreadable, noCurrentPool, allFullPlaceholder
    }

    private struct Summary: Decodable {
        let groups: [Group]
    }

    /// A group without buckets contributes none; it never voids the other groups.
    private struct Group: Decodable {
        let buckets: [Bucket]

        private enum CodingKeys: String, CodingKey { case buckets }

        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            buckets = container.flatMap { (try? $0.decodeIfPresent([Bucket].self, forKey: .buckets)) ?? nil } ?? []
        }
    }

    /// One malformed bucket stays unavailable on its own instead of voiding the whole summary.
    /// A wrongly typed field reads as absent, so it can never become zero or full usage.
    private struct Bucket: Decodable {
        let bucketId: String?
        let window: String?
        let remainingFraction: Double?
        let resetTime: String?
        let disabled: Bool?
        let hasMalformedField: Bool

        private enum CodingKeys: String, CodingKey { case bucketId, window, remainingFraction, resetTime, disabled }

        init(from decoder: Decoder) {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            var malformed = container == nil
            func field<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
                do { return try container?.decodeIfPresent(type, forKey: key) } catch {
                    malformed = true
                    return nil
                }
            }
            bucketId = field(String.self, .bucketId)
            window = field(String.self, .window)
            remainingFraction = field(Double.self, .remainingFraction)
            resetTime = field(String.self, .resetTime)
            disabled = field(Bool.self, .disabled)
            hasMalformedField = malformed
        }
    }

    static func result(
        from data: Data,
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date = Date(),
        productionNote: String? = nil
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
        var messages = message.map { [$0] } ?? []
        if let productionNote, missing.contains(where: { productionOnlyKeys.contains($0.key) }) {
            messages.append(productionNote)
        }
        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: .antigravity,
            title: configuration.displayName,
            subtitle: "Antigravity quota groups",
            bars: bars,
            unavailableUsageMetrics: unavailable,
            usageMessages: messages,
            failureMessage: bars.isEmpty ? message : nil,
            fetchedAt: fetchedAt
        )
    }

    /// Production is shown only when it proves at least one current canonical metric and is not the all-full placeholder.
    static func isUsableProductionSummary(_ data: Data, at date: Date = Date()) -> Bool {
        productionIssue(data, at: date) == nil
    }

    static func productionIssue(_ data: Data, at date: Date = Date()) -> ProductionIssue? {
        guard let summary = try? JSONDecoder().decode(Summary.self, from: data) else { return .unreadable }
        let buckets = summary.groups.flatMap(\.buckets)
        let hasMetric = metrics.contains { metric in
            let matches = buckets.filter { $0.bucketId == metric.key }
            return matches.count == 1 && bar(for: metric, bucket: matches[0], fetchedAt: date) != nil
        }
        guard hasMetric else { return .noCurrentPool }
        return isAllFullPlaceholder(data) ? .allFullPlaceholder : nil
    }

    /// On September 5, 2026 production answered HTTP 200 with every pool at full remaining while the CLI showed usage.
    /// A response whose supplied canonical pools are all full cannot be told apart from that placeholder.
    static func isAllFullPlaceholder(_ data: Data) -> Bool {
        guard let summary = try? JSONDecoder().decode(Summary.self, from: data) else { return false }
        let keys = Set(metrics.map(\.key))
        let fractions = summary.groups.flatMap(\.buckets)
            .filter { $0.bucketId.map(keys.contains) == true && $0.disabled != true && !$0.hasMalformedField }
            .compactMap(\.remainingFraction)
        return !fractions.isEmpty && fractions.allSatisfy { $0 >= 1 }
    }

    private static func bar(for metric: GoogleUsageMetricCatalog.Definition, bucket: Bucket, fetchedAt: Date) -> UsageBar? {
        guard !bucket.hasMalformedField, bucket.window == metric.window, bucket.disabled != true,
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
