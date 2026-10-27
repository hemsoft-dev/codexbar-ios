import Foundation

/// Uses the same elapsed-window projection as UsageBar. Scores describe utilization, not quota remaining.
public struct SubscriptionUtilizationScore: Equatable, Sendable {
    public enum Band: String, Sendable {
        case green, yellow, red
    }

    public let value: Int
    public var band: Band { value >= 90 ? .green : value >= 75 ? .yellow : .red }
    public var accessibilityText: String { "SUS \(value) of 100, \(band.rawValue) band" }

    public init?(bar: UsageBar, at now: Date = Date()) {
        guard let start = bar.projectionPeriodStart, let end = bar.projectionPeriodEnd,
              Self.isWeekly(start: start, end: end), now < end,
              now.timeIntervalSince(start) >= 12 * 3_600,
              let current = bar.projectionCurrent, current.isFinite, current >= 0,
              let limit = bar.projectionLimit, limit.isFinite, limit > 0 else { return nil }
        let elapsed = now.timeIntervalSince(start)
        let duration = end.timeIntervalSince(start)
        let projected = UsageBar.projectedUsage(current: current, periodStart: start, periodEnd: end, now: now) / limit * 100
        guard projected.isFinite else { return nil }
        let untilReset = end.timeIntervalSince(now)
        let untilLimit = current > 0 ? max((limit - current) / (current / elapsed), 0) : untilReset
        let score = projected <= 100 ? projected : 100 - 100 * max(untilReset - untilLimit, 0) / duration
        value = Int(min(max(score, 0), 100).rounded(.toNearestOrEven))
    }

    public init(value: Int) { self.value = min(max(value, 0), 100) }

    public static func isWeekly(start: Date, end: Date) -> Bool {
        let duration = end.timeIntervalSince(start)
        return duration.isFinite && abs(duration - 7 * 86_400) <= 60
    }

    /// Providers whose weekly windows never get a score: Muse Code has no verified price or scoring scope (MUSE-CODE.md).
    public static let unscoredProviders: Set<ProviderID> = [.museCode]

    public static func applies(to bar: UsageBar, providerID: ProviderID) -> Bool {
        !unscoredProviders.contains(providerID) && applies(to: bar)
    }

    public static func applies(to bar: UsageBar) -> Bool {
        if let start = bar.projectionPeriodStart, let end = bar.projectionPeriodEnd {
            return isWeekly(start: start, end: end)
        }
        return bar.stableKey?.lowercased().contains("weekly") == true
    }
}

public enum SubscriptionUtilizationFleet {
    // Reference monthly USD weights. Gemini owns the unified Apps/Antigravity subscription.
    // Editable independently of scoring; no scheduled date is assumed.
    public static let referenceMonthlyPrices: [ProviderID: Double] = [.claude: 200, .codex: 200, .gemini: 19.99, .antigravity: 19.99]

    public struct Entry: Equatable, Sendable {
        public let score: SubscriptionUtilizationScore
        public let monthlyPrice: Double?
        public init(score: SubscriptionUtilizationScore, monthlyPrice: Double?) {
            self.score = score
            self.monthlyPrice = monthlyPrice
        }
    }

    public static func monthlyPrice(for result: ProviderUsageResult) -> Double? {
        if result.providerID == .codex {
            switch result.plan?.identifier {
            case "codex.pro": return 200
            case "codex.prolite": return 100
            default: break
            }
        }
        return referenceMonthlyPrices[result.providerID]
    }

    /// Average weekly pools once per account, then apply its subscription price once.
    public static func entry(for result: ProviderUsageResult, at now: Date = Date()) -> Entry? {
        guard result.hasCurrentBars, !SubscriptionUtilizationScore.unscoredProviders.contains(result.providerID) else { return nil }
        let scores = result.enabledBarIndices.compactMap { SubscriptionUtilizationScore(bar: result.bars[$0], at: now)?.value }
        guard !scores.isEmpty else { return nil }
        let mean = Double(scores.reduce(0, +)) / Double(scores.count)
        return Entry(score: SubscriptionUtilizationScore(value: Int(mean.rounded(.toNearestOrEven))), monthlyPrice: monthlyPrice(for: result))
    }

    public static func score(entries: [Entry]) -> SubscriptionUtilizationScore? {
        guard !entries.isEmpty else { return nil }
        let equalWeights = entries.contains { !($0.monthlyPrice?.isFinite == true && ($0.monthlyPrice ?? 0) > 0) }
        let weights = entries.map { equalWeights ? 1 : $0.monthlyPrice! }
        let weighted = zip(entries, weights).reduce(0.0) { $0 + Double($1.0.score.value) * $1.1 } / weights.reduce(0, +)
        guard weighted.isFinite else { return nil }
        return SubscriptionUtilizationScore(value: Int(weighted.rounded(.toNearestOrEven)))
    }
}
