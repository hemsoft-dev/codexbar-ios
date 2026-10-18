import Foundation

private enum UsageHistoryFormatting {
    static func formatCurrency(_ value: Double, currencyCode: String = "USD", decimalPlaces: Int = 2) -> String {
        value.formatted(
            .currency(code: currencyCode)
                .precision(.fractionLength(decimalPlaces))
        )
    }
}

public struct UsageHistoryBarSnapshot: Equatable, Codable, Sendable {
    public let stableKey: String?
    public let label: String
    public let fractionUsed: Double
    public let used: Double
    public let limit: Double
    public let effectiveFractionUsed: Double
    public let effectiveSeverity: UsageSeverity
    let usesLegacySeverityFallback: Bool

    private enum CodingKeys: String, CodingKey {
        case stableKey
        case label
        case fractionUsed
        case used
        case limit
        case effectiveFractionUsed
        case effectiveSeverity
        case usesLegacySeverityFallback
    }

    public init(
        bar: UsageBar,
        capturedAt: Date,
        severityThresholds: UsageSeverityThresholds = .default
    ) {
        self.stableKey = bar.stableKey
        self.label = bar.label
        self.fractionUsed = bar.fractionUsed
        self.used = bar.used
        self.limit = bar.limit
        self.effectiveFractionUsed = max(
            bar.fractionUsed,
            bar.projectedFraction(at: capturedAt) ?? bar.fractionUsed
        )
        self.effectiveSeverity = UsageSeverity(
            fractionUsed: effectiveFractionUsed,
            thresholds: severityThresholds
        )
        self.usesLegacySeverityFallback = false
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.stableKey = try container.decodeIfPresent(String.self, forKey: .stableKey)
        self.label = try container.decode(String.self, forKey: .label)
        self.fractionUsed = try container.decode(Double.self, forKey: .fractionUsed)
        self.used = try container.decode(Double.self, forKey: .used)
        self.limit = try container.decode(Double.self, forKey: .limit)
        let decodedSeverity = try container.decodeIfPresent(
            UsageSeverity.self,
            forKey: .effectiveSeverity
        ) ?? UsageSeverity(fractionUsed: fractionUsed)
        let decodedEffectiveFraction = try container.decodeIfPresent(
            Double.self,
            forKey: .effectiveFractionUsed
        )
        self.effectiveFractionUsed =
            decodedEffectiveFraction ?? max(fractionUsed, decodedSeverity.minimumFraction)
        self.effectiveSeverity = decodedSeverity
        self.usesLegacySeverityFallback = try container.decodeIfPresent(
            Bool.self,
            forKey: .usesLegacySeverityFallback
        ) ?? (decodedEffectiveFraction == nil)
    }

    public func effectiveSeverity(
        using thresholds: UsageSeverityThresholds
    ) -> UsageSeverity {
        UsageSeverity(
            fractionUsed: effectiveFractionUsed,
            thresholds: thresholds
        )
    }

    fileprivate var historyFractionUsed: Double {
        guard limit > 0 else {
            return fractionUsed
        }

        let rawFraction = used / limit
        return rawFraction.isFinite ? max(rawFraction, 0) : fractionUsed
    }
}

public struct UsageHistoryMonetaryMetricSnapshot: Equatable, Codable, Sendable {
    public let kind: ProviderMonetaryMetricKind
    public let label: String
    public let minorUnits: Decimal
    public let currencyCode: String
    public let decimalPlaces: Int

    public init(metric: ProviderMonetaryMetric) {
        self.kind = metric.kind
        self.label = metric.label
        self.minorUnits = metric.minorUnits
        self.currencyCode = metric.currencyCode
        self.decimalPlaces = metric.decimalPlaces
    }
}

private protocol MonetaryMetricSnapshot {
    var metricKind: ProviderMonetaryMetricKind { get }
    var minorUnits: Decimal { get }
    var currencyCode: String { get }
    var decimalPlaces: Int { get }
}

private extension MonetaryMetricSnapshot {
    var clampedDecimalPlaces: Int {
        min(max(decimalPlaces, 0), 6)
    }

    var doubleValue: Double {
        var divisor = Decimal(1)
        for _ in 0..<clampedDecimalPlaces {
            divisor *= 10
        }
        return NSDecimalNumber(decimal: minorUnits / divisor).doubleValue
    }
}

extension ProviderMonetaryMetric: MonetaryMetricSnapshot {
    fileprivate var metricKind: ProviderMonetaryMetricKind { kind }
}

extension UsageHistoryMonetaryMetricSnapshot: MonetaryMetricSnapshot {
    fileprivate var metricKind: ProviderMonetaryMetricKind { kind }
}

public struct UsageHistorySnapshot: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let accountID: String
    public let providerID: ProviderID
    public let title: String
    public let subtitle: String
    public let capturedAt: Date
    public let bars: [UsageHistoryBarSnapshot]
    public let creditsRemaining: Double?
    public let monetaryMetrics: [UsageHistoryMonetaryMetricSnapshot]?
    public let highestSeverity: UsageSeverity
    public let hasReachedSpendLimit: Bool?

    public init(
        result: ProviderUsageResult,
        capturedAt: Date? = nil,
        severityThresholds: UsageSeverityThresholds = .default
    ) {
        self.init(
            result: result,
            capturedAt: capturedAt ?? result.fetchedAt,
            severityThresholds: severityThresholds,
            includesBars: result.hasFreshBars,
            includesCredits: result.hasFreshCredits,
            includesMonetaryMetrics: true
        )
    }

    fileprivate init(migrating snapshot: UsageHistorySnapshot, to configuration: ProviderAccountConfiguration) {
        // Keep the source snapshot identity. Apps and coding can have equal capture timestamps.
        self.id = snapshot.id
        self.accountID = configuration.id
        self.providerID = .gemini
        self.title = configuration.displayName
        self.subtitle = snapshot.subtitle
        self.capturedAt = snapshot.capturedAt
        self.bars = snapshot.bars
        self.creditsRemaining = snapshot.creditsRemaining
        self.monetaryMetrics = snapshot.monetaryMetrics
        self.highestSeverity = snapshot.highestSeverity
        self.hasReachedSpendLimit = snapshot.hasReachedSpendLimit
    }

    fileprivate init(
        presenting result: ProviderUsageResult,
        severityThresholds: UsageSeverityThresholds
    ) {
        self.init(
            result: result,
            capturedAt: result.fetchedAt,
            severityThresholds: severityThresholds,
            includesBars: result.hasCurrentBars,
            includesCredits: result.hasCurrentCredits,
            includesMonetaryMetrics: result.failureMessage == nil
        )
    }

    private init(
        result: ProviderUsageResult,
        capturedAt: Date,
        severityThresholds: UsageSeverityThresholds,
        includesBars: Bool,
        includesCredits: Bool,
        includesMonetaryMetrics: Bool
    ) {
        let recordableBars = includesBars ? result.usageHistoryBars() : []
        let monetaryMetrics = includesMonetaryMetrics ? result.monetaryMetrics : []
        self.id = "\(result.accountID).\(capturedAt.timeIntervalSince1970)"
        self.accountID = result.accountID
        self.providerID = result.providerID
        self.title = result.title
        self.subtitle = result.subtitle
        self.capturedAt = capturedAt
        self.bars = recordableBars.map {
            UsageHistoryBarSnapshot(
                bar: $0,
                capturedAt: capturedAt,
                severityThresholds: severityThresholds
            )
        }
        self.creditsRemaining = includesCredits ? result.creditsRemaining : nil
        self.monetaryMetrics = monetaryMetrics.map(UsageHistoryMonetaryMetricSnapshot.init)
        self.hasReachedSpendLimit = includesMonetaryMetrics ? result.hasReachedSpendLimit : nil
        self.highestSeverity = max(
            recordableBars.map {
                $0.effectiveSeverity(
                    at: capturedAt,
                    thresholds: severityThresholds
                )
            }.max() ?? .normal,
            includesMonetaryMetrics && result.hasReachedSpendLimit ? .critical : .normal
        )
    }

    fileprivate init(
        presenting current: UsageHistorySnapshot,
        preservingMissingValuesFrom stored: UsageHistorySnapshot
    ) {
        let bars = current.bars.isEmpty ? stored.bars : current.bars
        let currentMonetaryMetrics = current.monetaryMetrics ?? []
        var mergedMonetaryMetrics = stored.monetaryMetrics ?? []
        for metric in currentMonetaryMetrics {
            if let matchingIndex = mergedMonetaryMetrics.firstIndex(where: {
                $0.kind == metric.kind
                    && $0.currencyCode == metric.currencyCode
            }) {
                mergedMonetaryMetrics[matchingIndex] = metric
            } else {
                mergedMonetaryMetrics.append(metric)
            }
        }
        let monetaryMetrics = mergedMonetaryMetrics.isEmpty ? nil : mergedMonetaryMetrics
        let currentDeterminesSpendLimit = currentMonetaryMetrics.contains { metric in
            guard metric.kind == .spent else {
                return false
            }
            return currentMonetaryMetrics.contains {
                $0.kind == .spendLimit
                    && $0.currencyCode == metric.currencyCode
                    && $0.decimalPlaces == metric.decimalPlaces
            }
        }
        let hasReachedSpendLimit = currentDeterminesSpendLimit
            ? current.hasReachedSpendLimit
            : stored.hasReachedSpendLimit

        self.id = current.id
        self.accountID = current.accountID
        self.providerID = current.providerID
        self.title = current.title
        self.subtitle = current.subtitle
        self.capturedAt = current.capturedAt
        self.bars = bars
        self.creditsRemaining = current.creditsRemaining ?? stored.creditsRemaining
        self.monetaryMetrics = monetaryMetrics
        self.highestSeverity = max(
            bars.map(\.effectiveSeverity).max() ?? .normal,
            hasReachedSpendLimit == true ? .critical : .normal
        )
        self.hasReachedSpendLimit = hasReachedSpendLimit
    }

    fileprivate init(
        dailyComponentOf snapshot: UsageHistorySnapshot,
        component: DailyUsageHistoryComponent
    ) {
        self.id = "\(snapshot.id).daily.\(component.id)"
        self.accountID = snapshot.accountID
        self.providerID = snapshot.providerID
        self.title = snapshot.title
        self.subtitle = snapshot.subtitle
        self.capturedAt = snapshot.capturedAt
        switch component {
        case let .bar(bar, _):
            self.bars = [bar]
            self.creditsRemaining = nil
            self.monetaryMetrics = nil
        case .credits:
            self.bars = []
            self.creditsRemaining = snapshot.creditsRemaining
            self.monetaryMetrics = nil
        case let .monetaryMetric(metric):
            self.bars = []
            self.creditsRemaining = nil
            self.monetaryMetrics = [metric]
        }
        self.highestSeverity = snapshot.highestSeverity
        self.hasReachedSpendLimit = snapshot.hasReachedSpendLimit
    }

    public func highestSeverity(
        using thresholds: UsageSeverityThresholds
    ) -> UsageSeverity {
        let storedUsageSeverity = bars.map(\.effectiveSeverity).max() ?? .normal
        let activeUsageSeverity = bars.map {
            $0.effectiveSeverity(using: thresholds)
        }.max() ?? .normal
        let legacyReachedSpendLimit: Bool
        if hasReachedSpendLimit == nil,
           let spent = monetaryMetrics?.first(where: { $0.kind == .spent }),
           let limit = monetaryMetrics?.first(where: { $0.kind == .spendLimit }),
           spent.currencyCode == limit.currencyCode,
           spent.decimalPlaces == limit.decimalPlaces {
            legacyReachedSpendLimit =
                limit.minorUnits > 0 && spent.minorUnits >= limit.minorUnits
        } else {
            legacyReachedSpendLimit = false
        }
        let legacyExternalSeverity =
            hasReachedSpendLimit == nil && highestSeverity > storedUsageSeverity
                ? highestSeverity
                : .normal

        return max(
            activeUsageSeverity,
            hasReachedSpendLimit == true || legacyReachedSpendLimit
                ? .critical
                : legacyExternalSeverity
        )
    }

    fileprivate func effectiveSeverity(
        for bar: UsageHistoryBarSnapshot,
        using thresholds: UsageSeverityThresholds
    ) -> UsageSeverity {
        if bar.usesLegacySeverityFallback {
            return highestSeverity(using: thresholds)
        }
        return bar.effectiveSeverity(using: thresholds)
    }

    public var primaryValue: Double? {
        if let creditsRemaining {
            return creditsRemaining
        }

        if providerID == .cursor,
           let total = bars.first(where: {
                $0.stableKey == "total"
                    || ($0.stableKey == nil
                        && $0.label.caseInsensitiveCompare("Total") == .orderedSame)
           }) {
            return total.historyFractionUsed
        }

        if providerID == .greptile,
           let reviews = bars.first(where: {
               $0.stableKey == GreptileUsageIdentity.reviewQuotaStableKey
           }) ?? bars.first(where: {
               $0.stableKey == GreptileUsageIdentity.completedReviewsStableKey
           }) {
            return reviews.used
        }

        if let usage = bars.map(\.historyFractionUsed).max() {
            return usage
        }

        let metric = monetaryMetrics?.first(where: { $0.kind == .balance })
            ?? monetaryMetrics?.first(where: { $0.kind == .remainingHeadroom })
            ?? monetaryMetrics?.first
        return metric?.doubleValue
    }

    fileprivate var monetaryPrimaryValue: Double? {
        if let creditsRemaining {
            return creditsRemaining
        }
        let metric = monetaryMetrics?.first(where: { $0.kind == .balance })
            ?? monetaryMetrics?.first(where: { $0.kind == .remainingHeadroom })
            ?? monetaryMetrics?.first
        return metric?.doubleValue
    }
}

public struct UsageTrendSummary: Equatable, Sendable {
    public enum Direction: Equatable, Sendable {
        case up
        case down
        case flat
    }

    public let accountID: String
    public let points: [Double]
    public let valueDescription: String
    public let windowDescription: String
    public let isBalance: Bool
    public let direction: Direction
}

public struct UsageHistoryPoint: Identifiable, Equatable, Sendable {
    public let id: String
    public let capturedAt: Date
    public let value: Double
    public let severity: UsageSeverity

    public init(id: String, capturedAt: Date, value: Double, severity: UsageSeverity) {
        self.id = id
        self.capturedAt = capturedAt
        self.value = value
        self.severity = severity
    }

    public init(
        snapshot: UsageHistorySnapshot,
        value: Double,
        severityThresholds: UsageSeverityThresholds = .default
    ) {
        self.init(
            id: snapshot.id,
            capturedAt: snapshot.capturedAt,
            value: value,
            severity: snapshot.highestSeverity(using: severityThresholds)
        )
    }
}

enum DailyUsageHistoryComponent {
    case bar(UsageHistoryBarSnapshot, providerID: ProviderID)
    case credits
    case monetaryMetric(UsageHistoryMonetaryMetricSnapshot)

    var id: String {
        switch self {
        case let .bar(bar, providerID):
            "bar.\(Self.barIdentity(bar, providerID: providerID))"
        case .credits:
            "credits"
        case let .monetaryMetric(metric):
            "money.\(metric.kind.rawValue).\(metric.currencyCode)"
        }
    }

    static func barIdentity(
        _ bar: UsageHistoryBarSnapshot,
        providerID: ProviderID
    ) -> String {
        guard let stableKey = bar.stableKey else {
            return "legacy.\(bar.label.lowercased())"
        }
        switch providerID {
        case .cursor: return CursorUsageIdentity.canonicalStableKey(stableKey)
        case .claude: return ClaudeUsageIdentity.canonicalFableStableKey(stableKey)
        default: return stableKey
        }
    }
}

private extension UsageSeverity {
    var minimumFraction: Double {
        switch self {
        case .normal:
            0
        case .warning:
            UsageSeverityThresholds.default.warning
        case .critical:
            UsageSeverityThresholds.default.critical
        }
    }
}

public struct UsageHistorySeries: Equatable, Sendable {
    public let accountID: String
    public let points: [UsageHistoryPoint]
    public let isBalance: Bool
    public let isCount: Bool
    public let currencyCode: String?
    public let decimalPlaces: Int

    public init(
        accountID: String,
        points: [UsageHistoryPoint],
        isBalance: Bool,
        isCount: Bool = false,
        currencyCode: String? = nil,
        decimalPlaces: Int = 2
    ) {
        self.accountID = accountID
        var pointsByTimestamp: [Date: UsageHistoryPoint] = [:]
        for point in points {
            pointsByTimestamp[point.capturedAt] = point
        }
        self.points = pointsByTimestamp.values.sorted { $0.capturedAt < $1.capturedAt }
        self.isBalance = isBalance
        self.isCount = isCount
        self.currencyCode = currencyCode
        self.decimalPlaces = decimalPlaces
    }

    public var latestValueDescription: String {
        points.last.map { valueDescription(for: $0.value) } ?? "No data"
    }

    public var minimumValueDescription: String {
        points.map(\.value).min().map(valueDescription(for:)) ?? "--"
    }

    public var maximumValueDescription: String {
        points.map(\.value).max().map(valueDescription(for:)) ?? "--"
    }

    public var rangeDescription: String {
        guard
            let minimum = points.map(\.value).min(),
            let maximum = points.map(\.value).max()
        else {
            return "No range yet"
        }

        if abs(maximum - minimum) < Self.flatDeltaThreshold {
            return "Flat at \(valueDescription(for: maximum))"
        }

        return "Range \(valueDescription(for: minimum)) to \(valueDescription(for: maximum))"
    }

    public var changeDescription: String {
        guard let latestDelta else {
            return points.isEmpty ? "No history yet" : "Collecting history"
        }

        guard direction != .flat else {
            return "No change"
        }

        let directionDescription = direction == .up ? "Up" : "Down"
        return "\(directionDescription) \(deltaMagnitudeDescription(latestDelta))"
    }

    public var sampleWindowDescription: String {
        guard let first = points.first, let last = points.last else {
            return "No samples"
        }

        let count = points.count
        let sampleText = "\(count) sample\(count == 1 ? "" : "s")"
        if Calendar.autoupdatingCurrent.isDate(first.capturedAt, inSameDayAs: last.capturedAt) {
            return "\(sampleText) - \(UserFacingDateTimeFormatter.current.shortDate(last.capturedAt))"
        }

        let formatter = UserFacingDateTimeFormatter.current
        return "\(sampleText) - \(formatter.shortDate(first.capturedAt)) - \(formatter.shortDate(last.capturedAt))"
    }

    public var direction: UsageTrendSummary.Direction {
        guard let latestDelta else {
            return .flat
        }

        if abs(latestDelta) < Self.flatDeltaThreshold {
            return .flat
        }

        return latestDelta > 0 ? .up : .down
    }

    public var chartDomain: ClosedRange<Double> {
        guard isBalance || isCount else {
            guard let maximum = points.map(\.value).max(), maximum > 1 else {
                return 0...1
            }

            let padding = max(maximum * 0.08, 0.05)
            return 0...(maximum + padding)
        }

        guard
            let minimum = points.map(\.value).min(),
            let maximum = points.map(\.value).max()
        else {
            return 0...1
        }

        let span = maximum - minimum
        let padding = span > 0
            ? max(span * 0.15, 0.25)
            : max(abs(maximum) * 0.08, 1)
        let lowerBound = minimum < 0 ? minimum - padding : max(0, minimum - padding)
        let upperBound = max(maximum + padding, lowerBound + 1)
        return lowerBound...upperBound
    }

    public var showsQuotaLimitRule: Bool {
        !isBalance && !isCount
    }

    public func valueDescription(for value: Double) -> String {
        if isCount {
            return value.formatted(.number.precision(.fractionLength(0...2)))
        }
        if isBalance {
            return UsageHistoryFormatting.formatCurrency(
                value,
                currencyCode: currencyCode ?? "USD",
                decimalPlaces: decimalPlaces
            )
        }

        return "\(Int((value * 100).rounded()))%"
    }

    func deltaMagnitudeDescription(_ delta: Double) -> String {
        if isCount {
            return abs(delta).formatted(.number.precision(.fractionLength(0...2)))
        }
        if isBalance {
            return UsageHistoryFormatting.formatCurrency(
                abs(delta),
                currencyCode: currencyCode ?? "USD",
                decimalPlaces: decimalPlaces
            )
        }
        return "\(Int((abs(delta) * 100).rounded())) pts"
    }

    fileprivate var latestDelta: Double? {
        guard points.count >= 2 else {
            return nil
        }

        return points[points.count - 1].value - points[points.count - 2].value
    }

    private static let flatDeltaThreshold = 0.0001

    public func filtered(
        to range: UsageHistoryRange,
        accessPolicy: HistoryAccessPolicy = .pro,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> UsageHistorySeries {
        let requestedStart = range.startDate(now: now, calendar: calendar)
        let start = accessPolicy.effectiveStart(
            since: requestedStart,
            now: now,
            calendar: calendar
        ) ?? requestedStart
        return UsageHistorySeries(
            accountID: accountID,
            points: points.filter { $0.capturedAt >= start },
            isBalance: isBalance,
            isCount: isCount,
            currencyCode: currencyCode,
            decimalPlaces: decimalPlaces
        )
    }

}

public enum UsageHistoryRange: String, CaseIterable, Identifiable, Sendable {
    case today
    case threeDays
    case sevenDays
    case month
    case threeMonths

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .today:
            "Today"
        case .threeDays:
            "3 days"
        case .sevenDays:
            "7 days"
        case .month:
            "A month"
        case .threeMonths:
            "3 months"
        }
    }

    public var compactTitle: String {
        switch self {
        case .today:
            "Today"
        case .threeDays:
            "3D"
        case .sevenDays:
            "7D"
        case .month:
            "1M"
        case .threeMonths:
            "3M"
        }
    }

    public func startDate(
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        let daysBack: Int
        switch self {
        case .today:
            daysBack = 0
        case .threeDays:
            daysBack = 2
        case .sevenDays:
            daysBack = 6
        case .month:
            daysBack = 29
        case .threeMonths:
            daysBack = 89
        }
        return calendar.date(byAdding: .day, value: -daysBack, to: startOfToday)
            ?? startOfToday
    }
}

public struct UsageHistorySeriesOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let series: UsageHistorySeries
}

@MainActor
public final class UsageHistoryStore: ObservableObject {
    @Published public private(set) var snapshots: [UsageHistorySnapshot]
    @Published public private(set) var dailySnapshots: [UsageHistorySnapshot]
    @Published public private(set) var lastError: String?
    @Published public private(set) var requiresRecovery: Bool
    @Published public private(set) var accessPolicy: HistoryAccessPolicy

    private let defaults: UserDefaults
    private let retention: TimeInterval
    private let dailyRetentionDays: Int
    private let maxSnapshotsPerAccount: Int
    private let storageKey = "usageHistorySnapshots"
    private let dailyStorageKey = "usageHistoryDailySnapshots"
    private static let loadErrorMessage =
        "Saved usage history could not be read. Reset history to resume recording."

    public init(
        defaults: UserDefaults = .standard,
        retentionDays: Int = 30,
        dailyRetentionDays: Int = 90,
        maxSnapshotsPerAccount: Int = 240,
        accessPolicy: HistoryAccessPolicy = .pro
    ) {
        self.defaults = defaults
        self.accessPolicy = accessPolicy
        self.retention = TimeInterval(max(retentionDays, 1) * 24 * 60 * 60)
        self.dailyRetentionDays = max(dailyRetentionDays, 90)
        self.maxSnapshotsPerAccount = max(maxSnapshotsPerAccount, 1)
        let loadedSnapshots = Self.loadSnapshots(defaults: defaults, storageKey: storageKey)
        let loadedDailySnapshots = Self.loadSnapshots(defaults: defaults, storageKey: dailyStorageKey)
        switch (loadedSnapshots, loadedDailySnapshots) {
        case let (.success(snapshots), .success(dailySnapshots)):
            self.snapshots = snapshots
            self.dailySnapshots = dailySnapshots
            self.lastError = nil
            self.requiresRecovery = false
        case (.failure, _), (_, .failure):
            self.snapshots = []
            self.dailySnapshots = []
            self.lastError = Self.loadErrorMessage
            self.requiresRecovery = true
        }
    }

    public func applyHistoryAccess(hasProAccess: Bool) {
        let policy = HistoryAccessPolicy(hasProAccess: hasProAccess)
        guard accessPolicy != policy else { return }
        accessPolicy = policy
    }

    public func record(
        results: [ProviderUsageResult],
        now: Date = Date(),
        severityThresholds: UsageSeverityThresholds = .default,
        samplingInterval: TimeInterval = 0
    ) {
        guard !requiresRecovery else {
            return
        }

        let recordableResults = results.filter { result in
            let hasFreshBars = result.hasFreshBars && !result.usageHistoryBars().isEmpty
            return result.freshCreditsRemaining != nil || hasFreshBars || !result.monetaryMetrics.isEmpty
        }
        guard !recordableResults.isEmpty else {
            return
        }

        let previousSnapshots = snapshots
        let previousDailySnapshots = dailySnapshots
        var snapshotsByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        var latestCaptureByAccountID = snapshots.reduce(into: [String: Date]()) { latestCaptureByAccountID, snapshot in
            latestCaptureByAccountID[snapshot.accountID] = max(
                latestCaptureByAccountID[snapshot.accountID] ?? snapshot.capturedAt,
                snapshot.capturedAt
            )
        }
        for snapshot in recordableResults.map({ result in
            UsageHistorySnapshot(
                result: result,
                severityThresholds: severityThresholds
            )
        }) {
            updateDailySnapshots(from: snapshot)
            if samplingInterval > 0,
               let latestCapture = latestCaptureByAccountID[snapshot.accountID],
               snapshot.capturedAt.timeIntervalSince(latestCapture) < samplingInterval {
                continue
            }
            snapshotsByID[snapshot.id] = snapshot
            latestCaptureByAccountID[snapshot.accountID] = max(
                latestCaptureByAccountID[snapshot.accountID] ?? snapshot.capturedAt,
                snapshot.capturedAt
            )
        }
        snapshots = Array(snapshotsByID.values)
        prune(now: now, validAccountIDs: Set(recordableResults.map(\.accountID)), removeMissingAccounts: false)
        save(
            restoringOnFailure: previousSnapshots,
            previousDailySnapshots: previousDailySnapshots
        )
    }

    public func removeSnapshotsForMissingAccounts(validAccountIDs: Set<String>, now: Date = Date()) {
        guard !requiresRecovery else {
            return
        }

        let previousSnapshots = snapshots
        let previousDailySnapshots = dailySnapshots
        prune(now: now, validAccountIDs: validAccountIDs, removeMissingAccounts: true)
        save(
            restoringOnFailure: previousSnapshots,
            previousDailySnapshots: previousDailySnapshots
        )
    }

    public func removeSnapshots(for accountID: String) {
        guard !requiresRecovery else { return }
        let previousSnapshots = snapshots
        let previousDailySnapshots = dailySnapshots
        snapshots.removeAll { $0.accountID == accountID }
        dailySnapshots.removeAll { $0.accountID == accountID }
        save(
            restoringOnFailure: previousSnapshots,
            previousDailySnapshots: previousDailySnapshots
        )
    }

    public func migrateGoogleAccounts(
        links: [String: String],
        configurations: [ProviderAccountConfiguration]
    ) {
        guard !requiresRecovery, !links.isEmpty else { return }
        let targets = Dictionary(uniqueKeysWithValues: configurations.filter { $0.providerID == .gemini }.map { ($0.id, $0) })
        let previousSnapshots = snapshots
        let previousDailySnapshots = dailySnapshots
        func migrate(_ snapshot: UsageHistorySnapshot) -> UsageHistorySnapshot {
            guard snapshot.providerID == .antigravity,
                  let targetID = links[snapshot.accountID], let target = targets[targetID] else { return snapshot }
            return UsageHistorySnapshot(migrating: snapshot, to: target)
        }
        snapshots = snapshots.map(migrate)
        dailySnapshots = dailySnapshots.map(migrate)
        save(restoringOnFailure: previousSnapshots, previousDailySnapshots: previousDailySnapshots)
    }

    public func discardCorruptedHistory() {
        guard requiresRecovery else {
            return
        }

        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: dailyStorageKey)
        snapshots = []
        dailySnapshots = []
        requiresRecovery = false
        lastError = nil
    }

    public func snapshots(
        for accountID: String,
        since start: Date? = nil,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> [UsageHistorySnapshot] {
        let start = accessPolicy.effectiveStart(since: start, now: now, calendar: calendar)
        return snapshots
            .filter { snapshot in
                snapshot.accountID == accountID && start.map { snapshot.capturedAt >= $0 } != false
            }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    /// A cold-start display fallback, never a refresh completion. Keep it out of
    /// successful-refresh caches, history recording, notifications and device publishing.
    /// The chart cutoff does not hide an account's last known current value.
    public func lastStoredResult(for configuration: ProviderAccountConfiguration) -> ProviderUsageResult? {
        let observations = (snapshots + dailySnapshots).filter {
            $0.accountID == configuration.id && $0.providerID == configuration.providerID
        }
        guard let latest = observations.max(by: { $0.capturedAt < $1.capturedAt }) else { return nil }
        let latestObservations = observations.filter { $0.capturedAt == latest.capturedAt }
        var barIdentities: Set<String> = []
        let bars = latestObservations.flatMap(\.bars).filter {
            barIdentities.insert(DailyUsageHistoryComponent.barIdentity($0, providerID: configuration.providerID)).inserted
        }.map { bar in
            UsageBar(
                stableKey: bar.stableKey,
                label: bar.label,
                used: bar.used,
                limit: bar.limit,
                fractionlessUsageText: bar.limit <= 0 ? bar.used.formatted() : nil
            )
        }
        var monetaryIdentities: Set<String> = []
        let monetaryMetrics = latestObservations.flatMap { $0.monetaryMetrics ?? [] }.filter {
            monetaryIdentities.insert("\($0.kind.rawValue).\($0.currencyCode)").inserted
        }.map { metric in
            ProviderMonetaryMetric(
                kind: metric.kind,
                label: metric.label,
                minorUnits: metric.minorUnits,
                currencyCode: metric.currencyCode,
                decimalPlaces: metric.decimalPlaces
            )
        }
        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: configuration.providerID,
            title: configuration.displayName,
            subtitle: latest.subtitle,
            bars: bars,
            creditsRemaining: latestObservations.compactMap(\.creditsRemaining).first,
            monetaryMetrics: monetaryMetrics,
            hasSuccessfulRefreshHistory: true,
            fetchedAt: latest.capturedAt
        )
    }

    public func historySeries(
        for result: ProviderUsageResult,
        since start: Date? = nil,
        severityThresholds: UsageSeverityThresholds = .default,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> UsageHistorySeries {
        let accountSnapshots = presentationSnapshots(
            for: result,
            since: start,
            severityThresholds: severityThresholds,
            now: now,
            calendar: calendar
        )
        let hasUsageHistory = accountSnapshots.contains { !$0.bars.isEmpty }
        let currentUsageBars = result.usageHistoryBars()
        if (result.hasFreshBars && !currentUsageBars.isEmpty)
            || (!currentUsageBars.isEmpty && hasUsageHistory)
            || ([ProviderID.greptile, .codex].contains(result.providerID) && hasUsageHistory) {
            return usageSeries(
                for: result,
                snapshots: accountSnapshots,
                severityThresholds: severityThresholds
            )
        }

        if result.freshCreditsRemaining != nil
            || accountSnapshots.contains(where: { $0.creditsRemaining != nil }) {
            return balanceSeries(
                accountID: result.accountID,
                snapshots: accountSnapshots,
                severityThresholds: severityThresholds
            )
        }

        let primaryMetricIdentity = primaryMonetaryMetric(in: result.monetaryMetrics).map {
            ($0.metricKind, $0.currencyCode, $0.decimalPlaces)
        } ?? accountSnapshots.reversed().lazy.compactMap { snapshot in
            self.primaryMonetaryMetric(in: snapshot.monetaryMetrics ?? []).map {
                ($0.metricKind, $0.currencyCode, $0.decimalPlaces)
            }
        }.first

        return UsageHistorySeries(
            accountID: result.accountID,
            points: accountSnapshots.compactMap { snapshot in
                guard
                    let primaryMetricIdentity,
                    let storedMetric = snapshot.monetaryMetrics?.first(where: {
                        $0.kind == primaryMetricIdentity.0
                            && $0.currencyCode == primaryMetricIdentity.1
                    })
                else {
                    return nil
                }
                return UsageHistoryPoint(
                    snapshot: snapshot,
                    value: storedMetric.doubleValue,
                    severityThresholds: severityThresholds
                )
            },
            isBalance: true,
            currencyCode: primaryMetricIdentity?.1,
            decimalPlaces: min(max(primaryMetricIdentity?.2 ?? 2, 0), 6)
        )
    }

    private func usageSeries(
        for result: ProviderUsageResult,
        snapshots: [UsageHistorySnapshot],
        severityThresholds: UsageSeverityThresholds
    ) -> UsageHistorySeries {
        if result.providerID == .cursor {
            return cursorPrimaryUsageSeries(
                accountID: result.accountID,
                snapshots: snapshots,
                severityThresholds: severityThresholds
            )
        }

        if result.providerID == .greptile {
            return countUsageSeries(
                accountID: result.accountID,
                snapshots: snapshots,
                stableKey: greptilePrimaryStableKey(snapshots: snapshots),
                severityThresholds: severityThresholds
            )
        }

        return aggregateUsageSeries(
            accountID: result.accountID,
            snapshots: snapshots,
            severityThresholds: severityThresholds
        )
    }

    private func countUsageSeries(
        accountID: String,
        snapshots: [UsageHistorySnapshot],
        stableKey: String,
        severityThresholds: UsageSeverityThresholds
    ) -> UsageHistorySeries {
        UsageHistorySeries(
            accountID: accountID,
            points: snapshots.compactMap { snapshot in
                snapshot.bars.first(where: { $0.stableKey == stableKey }).map {
                    UsageHistoryPoint(
                        id: snapshot.id,
                        capturedAt: snapshot.capturedAt,
                        value: $0.used,
                        severity: snapshot.effectiveSeverity(
                            for: $0,
                            using: severityThresholds
                        )
                    )
                }
            },
            isBalance: false,
            isCount: true
        )
    }

    private func greptilePrimaryStableKey(snapshots: [UsageHistorySnapshot]) -> String {
        if let latestSnapshot = snapshots.reversed().first(where: { snapshot in
            snapshot.bars.contains(where: {
                $0.stableKey == GreptileUsageIdentity.reviewQuotaStableKey
                    || $0.stableKey == GreptileUsageIdentity.completedReviewsStableKey
            })
        }) {
            return latestSnapshot.bars.contains(where: {
                $0.stableKey == GreptileUsageIdentity.reviewQuotaStableKey
            })
                ? GreptileUsageIdentity.reviewQuotaStableKey
                : GreptileUsageIdentity.completedReviewsStableKey
        }
        return snapshots.contains { snapshot in
            snapshot.bars.contains { $0.stableKey == GreptileUsageIdentity.creditAllowanceStableKey }
        } ? GreptileUsageIdentity.creditAllowanceStableKey : GreptileUsageIdentity.completedReviewsStableKey
    }

    private func aggregateUsageSeries(
        accountID: String,
        snapshots: [UsageHistorySnapshot],
        severityThresholds: UsageSeverityThresholds
    ) -> UsageHistorySeries {
        var pointsByTimestamp: [Date: UsageHistoryPoint] = [:]
        for snapshot in snapshots {
            let quotaBars = snapshot.bars.filter {
                snapshot.providerID != .codex || $0.stableKey != CodexUsageParser.creditsPoolStableKey
            }
            guard let value = quotaBars.map(\.historyFractionUsed).max() else {
                continue
            }
            let point = UsageHistoryPoint(
                snapshot: snapshot,
                value: value,
                severityThresholds: severityThresholds
            )
            if let existingPoint = pointsByTimestamp[snapshot.capturedAt],
               existingPoint.value >= value {
                continue
            }
            pointsByTimestamp[snapshot.capturedAt] = point
        }
        return UsageHistorySeries(
            accountID: accountID,
            points: Array(pointsByTimestamp.values),
            isBalance: false
        )
    }

    private func cursorPrimaryUsageSeries(
        accountID: String,
        snapshots: [UsageHistorySnapshot],
        severityThresholds: UsageSeverityThresholds
    ) -> UsageHistorySeries {
        let snapshotsByTimestamp = Dictionary(grouping: snapshots, by: \.capturedAt)
        let points = snapshotsByTimestamp.compactMap { capturedAt, matchingSnapshots in
            // A raw sample and its daily summaries can share a timestamp. Ordering by ID makes
            // every caller select the same point; the raw ID prefixes its summaries' IDs.
            let bars = matchingSnapshots.sorted { $0.id < $1.id }.flatMap { snapshot in
                snapshot.bars.map { (snapshot, $0) }
            }
            let selected = bars.first(where: { _, bar in
                Self.matchesCursorBar(bar, stableKey: "total")
            }) ?? bars.max(by: { lhs, rhs in
                lhs.1.historyFractionUsed < rhs.1.historyFractionUsed
            })
            return selected.map { snapshot, bar in
                UsageHistoryPoint(
                    id: snapshot.id,
                    capturedAt: capturedAt,
                    value: bar.historyFractionUsed,
                    severity: snapshot.effectiveSeverity(
                        for: bar,
                        using: severityThresholds
                    )
                )
            }
        }
        return UsageHistorySeries(
            accountID: accountID,
            points: points,
            isBalance: false
        )
    }

    private func usageSeries(
        accountID: String,
        snapshots: [UsageHistorySnapshot],
        stableKey: String,
        severityThresholds: UsageSeverityThresholds
    ) -> UsageHistorySeries {
        UsageHistorySeries(
            accountID: accountID,
            points: snapshots.compactMap { snapshot in
                snapshot.bars.first(where: {
                    Self.matchesCursorBar($0, stableKey: stableKey)
                }).map {
                    UsageHistoryPoint(
                        id: snapshot.id,
                        capturedAt: snapshot.capturedAt,
                        value: $0.historyFractionUsed,
                        severity: $0.effectiveSeverity(using: severityThresholds)
                    )
                }
            },
            isBalance: false
        )
    }

    private static func matchesLegacyCursorBar(
        _ bar: UsageHistoryBarSnapshot,
        stableKey: String
    ) -> Bool {
        let label = bar.label.trimmingCharacters(in: .whitespacesAndNewlines)
        switch stableKey {
        case "total":
            return label.caseInsensitiveCompare("Total") == .orderedSame
        case CursorUsageIdentity.cursorModelsStableKey:
            return label.caseInsensitiveCompare("Cursor Models") == .orderedSame
                || label.caseInsensitiveCompare("Auto") == .orderedSame
        case CursorUsageIdentity.otherModelsStableKey:
            return label.caseInsensitiveCompare("Other Models") == .orderedSame
                || label.caseInsensitiveCompare("API") == .orderedSame
        case "on-demand":
            return label.lowercased().hasPrefix("on-demand")
        default:
            return false
        }
    }

    private static func matchesCursorBar(
        _ bar: UsageHistoryBarSnapshot,
        stableKey: String
    ) -> Bool {
        let acceptedStableKeys: Set<String>
        switch stableKey {
        case CursorUsageIdentity.cursorModelsStableKey:
            acceptedStableKeys = [
                CursorUsageIdentity.cursorModelsStableKey,
                CursorUsageIdentity.legacyCursorModelsStableKey,
            ]
        case CursorUsageIdentity.otherModelsStableKey:
            acceptedStableKeys = [
                CursorUsageIdentity.otherModelsStableKey,
                CursorUsageIdentity.legacyOtherModelsStableKey,
            ]
        default:
            acceptedStableKeys = [stableKey]
        }

        if let storedStableKey = bar.stableKey {
            return acceptedStableKeys.contains(storedStableKey)
        }
        return matchesLegacyCursorBar(bar, stableKey: stableKey)
    }

    private func cursorUsageSeriesOptions(
        accountID: String,
        snapshots: [UsageHistorySnapshot],
        currentBars: [UsageBar],
        severityThresholds: UsageSeverityThresholds
    ) -> [UsageHistorySeriesOption] {
        let metricOptions: [UsageHistorySeriesOption] = [
            ("total", "Total"),
            (CursorUsageIdentity.cursorModelsStableKey, "Cursor Models"),
            (CursorUsageIdentity.otherModelsStableKey, "Other Models"),
            ("on-demand", "On-demand"),
        ].compactMap { stableKey, label in
            let acceptedCurrentStableKeys: Set<String>
            switch stableKey {
            case CursorUsageIdentity.cursorModelsStableKey:
                acceptedCurrentStableKeys = [
                    CursorUsageIdentity.cursorModelsStableKey,
                    CursorUsageIdentity.legacyCursorModelsStableKey,
                ]
            case CursorUsageIdentity.otherModelsStableKey:
                acceptedCurrentStableKeys = [
                    CursorUsageIdentity.otherModelsStableKey,
                    CursorUsageIdentity.legacyOtherModelsStableKey,
                ]
            default:
                acceptedCurrentStableKeys = [stableKey]
            }
            let isAvailable = currentBars.contains(where: {
                $0.stableKey.map(acceptedCurrentStableKeys.contains) == true
            })
                || snapshots.contains(where: { snapshot in
                    snapshot.bars.contains(where: {
                        Self.matchesCursorBar($0, stableKey: stableKey)
                    })
                })
            guard isAvailable else {
                return nil
            }

            return UsageHistorySeriesOption(
                id: "usage.\(stableKey)",
                label: label,
                series: usageSeries(
                    accountID: accountID,
                    snapshots: snapshots,
                    stableKey: stableKey,
                    severityThresholds: severityThresholds
                )
            )
        }

        guard !metricOptions.contains(where: { $0.id == "usage.total" }) else {
            let snapshotsByTimestamp = Dictionary(grouping: snapshots, by: \.capturedAt)
            let hasFallbackSamples = snapshotsByTimestamp.values.contains(where: { matchingSnapshots in
                let bars = matchingSnapshots.flatMap(\.bars)
                return !bars.isEmpty
                    && !bars.contains(where: {
                        $0.stableKey == "total"
                            || ($0.stableKey == nil
                                && Self.matchesLegacyCursorBar($0, stableKey: "total"))
                    })
            })
            guard hasFallbackSamples else {
                return metricOptions
            }

            return [
                UsageHistorySeriesOption(
                    id: "usage",
                    label: "Total / highest available",
                    series: cursorPrimaryUsageSeries(
                        accountID: accountID,
                        snapshots: snapshots,
                        severityThresholds: severityThresholds
                    )
                ),
            ] + metricOptions
        }

        return [
            UsageHistorySeriesOption(
                id: "usage",
                label: "Highest usage",
                series: cursorPrimaryUsageSeries(
                    accountID: accountID,
                    snapshots: snapshots,
                    severityThresholds: severityThresholds
                )
            ),
        ] + metricOptions
    }

    private func balanceSeries(
        accountID: String,
        snapshots: [UsageHistorySnapshot],
        severityThresholds: UsageSeverityThresholds
    ) -> UsageHistorySeries {
        UsageHistorySeries(
            accountID: accountID,
            points: snapshots.compactMap { snapshot in
                snapshot.creditsRemaining.map {
                    UsageHistoryPoint(
                        snapshot: snapshot,
                        value: $0,
                        severityThresholds: severityThresholds
                    )
                }
            },
            isBalance: true
        )
    }

    private func primaryMonetaryMetric<T>(in metrics: [T]) -> T? where T: MonetaryMetricSnapshot {
        metrics.first(where: { $0.metricKind == .balance })
            ?? metrics.first(where: { $0.metricKind == .remainingHeadroom })
            ?? metrics.first
    }

    public func historySeriesOptions(
        for result: ProviderUsageResult,
        since start: Date? = nil,
        severityThresholds: UsageSeverityThresholds = .default,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> [UsageHistorySeriesOption] {
        let accountSnapshots = presentationSnapshots(
            for: result,
            since: start,
            severityThresholds: severityThresholds,
            now: now,
            calendar: calendar
        )
        var options: [UsageHistorySeriesOption] = []

        if (result.hasFreshBars && !result.usageHistoryBars().isEmpty)
            || accountSnapshots.contains(where: { !$0.bars.isEmpty }) {
            if result.providerID == .cursor {
                options.append(contentsOf: cursorUsageSeriesOptions(
                    accountID: result.accountID,
                    snapshots: accountSnapshots,
                    currentBars: result.bars,
                    severityThresholds: severityThresholds
                ))
            } else if result.providerID == .greptile {
                var seriesIdentities = [
                    (
                        GreptileUsageIdentity.reviewQuotaStableKey,
                        GreptileUsageIdentity.reviewQuotaHistorySeriesID,
                        "Reviews used"
                    ),
                    (
                        GreptileUsageIdentity.completedReviewsStableKey,
                        GreptileUsageIdentity.completedReviewsHistorySeriesID,
                        "Completed reviews"
                    ),
                ]
                seriesIdentities.append((GreptileUsageIdentity.creditAllowanceStableKey, "usage.credit-allowance", "Credits used"))
                let preferredStableKey = greptilePrimaryStableKey(snapshots: accountSnapshots)
                if let preferredIndex = seriesIdentities.firstIndex(where: { $0.0 == preferredStableKey }),
                   preferredIndex != seriesIdentities.startIndex {
                    let preferredIdentity = seriesIdentities.remove(at: preferredIndex)
                    seriesIdentities.insert(preferredIdentity, at: seriesIdentities.startIndex)
                }
                for (stableKey, seriesID, label) in seriesIdentities where
                    (result.hasCurrentBars && result.bars.contains(where: { $0.stableKey == stableKey }))
                        || accountSnapshots.contains(where: { snapshot in
                            snapshot.bars.contains(where: { $0.stableKey == stableKey })
                        }) {
                    options.append(UsageHistorySeriesOption(
                        id: seriesID,
                        label: label,
                        series: countUsageSeries(
                            accountID: result.accountID,
                            snapshots: accountSnapshots,
                            stableKey: stableKey,
                            severityThresholds: severityThresholds
                        )
                    ))
                }
            } else {
                options.append(UsageHistorySeriesOption(
                    id: "usage",
                    label: "Usage",
                    series: aggregateUsageSeries(
                        accountID: result.accountID,
                        snapshots: accountSnapshots,
                        severityThresholds: severityThresholds
                    )
                ))
            }
        }

        if result.freshCreditsRemaining != nil
            || accountSnapshots.contains(where: { $0.creditsRemaining != nil }) {
            options.append(UsageHistorySeriesOption(
                id: "balance",
                label: "Balance",
                series: balanceSeries(
                    accountID: result.accountID,
                    snapshots: accountSnapshots,
                    severityThresholds: severityThresholds
                )
            ))
        }

        for metric in result.monetaryMetrics {
            let points = accountSnapshots.compactMap { snapshot -> UsageHistoryPoint? in
                guard let storedMetric = snapshot.monetaryMetrics?.first(where: {
                    $0.kind == metric.kind
                        && $0.currencyCode == metric.currencyCode
                }) else {
                    return nil
                }
                return UsageHistoryPoint(
                    snapshot: snapshot,
                    value: storedMetric.doubleValue,
                    severityThresholds: severityThresholds
                )
            }
            options.append(UsageHistorySeriesOption(
                id: "money.\(metric.id)",
                label: metric.label,
                series: UsageHistorySeries(
                    accountID: result.accountID,
                    points: points,
                    isBalance: true,
                    currencyCode: metric.currencyCode,
                    decimalPlaces: metric.clampedDecimalPlaces
                )
            ))
        }

        return options.isEmpty && result.providerID != .codex
            ? [
                UsageHistorySeriesOption(
                    id: "primary",
                    label: "Usage",
                    series: historySeries(
                        for: result,
                        since: start,
                        severityThresholds: severityThresholds,
                        now: now,
                        calendar: calendar
                    )
                ),
            ]
            : options
    }

    private func presentationSnapshots(
        for result: ProviderUsageResult,
        since start: Date?,
        severityThresholds: UsageSeverityThresholds,
        now: Date,
        calendar: Calendar
    ) -> [UsageHistorySnapshot] {
        let start = accessPolicy.effectiveStart(since: start, now: now, calendar: calendar)
        var accountSnapshots = storedPresentationSnapshots(
            for: result.accountID,
            since: start
        )
        guard
            start.map({ result.fetchedAt >= $0 }) != false,
            accountSnapshots.last.map({ result.fetchedAt >= $0.capturedAt }) != false
        else {
            return accountSnapshots
        }

        let currentSnapshot = UsageHistorySnapshot(
            presenting: result,
            severityThresholds: severityThresholds
        )
        guard
            !currentSnapshot.bars.isEmpty
                || currentSnapshot.creditsRemaining != nil
                || currentSnapshot.monetaryMetrics?.isEmpty == false
        else {
            return accountSnapshots
        }

        if let matchingIndex = accountSnapshots.lastIndex(where: {
            $0.capturedAt == currentSnapshot.capturedAt
        }) {
            accountSnapshots[matchingIndex] = UsageHistorySnapshot(
                presenting: currentSnapshot,
                preservingMissingValuesFrom: accountSnapshots[matchingIndex]
            )
        } else {
            accountSnapshots.append(currentSnapshot)
        }
        return accountSnapshots
    }

    public func trendSummary(
        for result: ProviderUsageResult,
        now: Date = Date(),
        severityThresholds: UsageSeverityThresholds = .default,
        calendar: Calendar = .autoupdatingCurrent
    ) -> UsageTrendSummary? {
        let series = historySeries(
            for: result,
            since: UsageHistoryRange.sevenDays.startDate(now: now, calendar: calendar),
            severityThresholds: severityThresholds,
            now: now,
            calendar: calendar
        )
        guard
            series.points.count >= 2,
            let previous = series.points.dropLast().last,
            let delta = series.latestDelta
        else {
            return nil
        }

        let direction = series.direction
        let description: String

        if direction == .flat {
            description = "No change"
        } else {
            description = "Changed \(delta > 0 ? "+" : "-")\(series.deltaMagnitudeDescription(delta))"
        }

        return UsageTrendSummary(
            accountID: result.accountID,
            points: series.points.map(\.value),
            valueDescription: description,
            windowDescription: "Since \(Self.formatSnapshotDate(previous.capturedAt))",
            isBalance: series.isBalance,
            direction: direction
        )
    }

    private func prune(
        now: Date,
        validAccountIDs: Set<String>,
        removeMissingAccounts: Bool
    ) {
        let cutoff = now.addingTimeInterval(-retention)
        let sorted = snapshots
            .filter { snapshot in
                snapshot.capturedAt >= cutoff
                    && (!removeMissingAccounts || validAccountIDs.contains(snapshot.accountID))
            }
            .sorted { lhs, rhs in
                if lhs.accountID != rhs.accountID {
                    return lhs.accountID < rhs.accountID
                }

                return lhs.capturedAt > rhs.capturedAt
            }

        var counts: [String: Int] = [:]
        snapshots = sorted
            .filter { snapshot in
                let count = counts[snapshot.accountID, default: 0]
                guard count < maxSnapshotsPerAccount else {
                    return false
                }

                counts[snapshot.accountID] = count + 1
                return true
            }
            .sorted { $0.capturedAt < $1.capturedAt }

        let startOfToday = Calendar.autoupdatingCurrent.startOfDay(for: now)
        let dailyCutoff = Calendar.autoupdatingCurrent.date(
            byAdding: .day,
            value: -(dailyRetentionDays - 1),
            to: startOfToday
        ) ?? now.addingTimeInterval(-TimeInterval(dailyRetentionDays * 24 * 60 * 60))
        let eligibleDailySnapshots = dailySnapshots
            .filter { snapshot in
                snapshot.capturedAt >= dailyCutoff
                    && (!removeMissingAccounts || validAccountIDs.contains(snapshot.accountID))
            }
            .sorted { $0.capturedAt > $1.capturedAt }
        var dailyKeys: Set<String> = []
        dailySnapshots = eligibleDailySnapshots
            .filter { snapshot in
                let day = Calendar.autoupdatingCurrent.startOfDay(for: snapshot.capturedAt)
                let componentID = Self.dailyComponentID(for: snapshot)
                let key = "\(snapshot.accountID)|\(day.timeIntervalSince1970)|\(componentID)"
                return dailyKeys.insert(key).inserted
            }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    private func updateDailySnapshots(from snapshot: UsageHistorySnapshot) {
        var components: [DailyUsageHistoryComponent] = []
        components.append(contentsOf: snapshot.bars.map {
            .bar($0, providerID: snapshot.providerID)
        })
        if snapshot.creditsRemaining != nil {
            components.append(.credits)
        }
        components.append(contentsOf: (snapshot.monetaryMetrics ?? []).map {
            .monetaryMetric($0)
        })

        var updatedComponentIDs: Set<String> = []
        for component in components where updatedComponentIDs.insert(component.id).inserted {
            updateDailySnapshot(
                UsageHistorySnapshot(
                    dailyComponentOf: snapshot,
                    component: component
                ),
                componentID: component.id
            )
        }
    }

    private func updateDailySnapshot(
        _ snapshot: UsageHistorySnapshot,
        componentID: String
    ) {
        let calendar = Calendar.autoupdatingCurrent
        if let index = dailySnapshots.lastIndex(where: {
            $0.accountID == snapshot.accountID
                && calendar.isDate($0.capturedAt, inSameDayAs: snapshot.capturedAt)
                && Self.dailyComponentID(for: $0) == componentID
        }) {
            guard snapshot.capturedAt >= dailySnapshots[index].capturedAt else {
                return
            }
            dailySnapshots[index] = snapshot
        } else {
            dailySnapshots.append(snapshot)
        }
    }

    private static func dailyComponentID(for snapshot: UsageHistorySnapshot) -> String {
        if let bar = snapshot.bars.first {
            let identity = DailyUsageHistoryComponent.barIdentity(
                bar,
                providerID: snapshot.providerID
            )
            return "bar.\(identity)"
        }
        if snapshot.creditsRemaining != nil {
            return "credits"
        }
        guard let metric = snapshot.monetaryMetrics?.first else {
            return "empty"
        }
        return "money.\(metric.kind.rawValue).\(metric.currencyCode)"
    }

    private func storedPresentationSnapshots(
        for accountID: String,
        since start: Date?
    ) -> [UsageHistorySnapshot] {
        var snapshotsByID: [String: UsageHistorySnapshot] = [:]
        for snapshot in snapshots + dailySnapshots where
            snapshot.accountID == accountID
                && start.map({ snapshot.capturedAt >= $0 }) != false {
            snapshotsByID[snapshot.id] = snapshot
        }
        return snapshotsByID.values.sorted { $0.capturedAt < $1.capturedAt }
    }

    private func save(
        restoringOnFailure previousSnapshots: [UsageHistorySnapshot],
        previousDailySnapshots: [UsageHistorySnapshot]
    ) {
        do {
            let data = try JSONEncoder().encode(snapshots)
            let dailyData = try JSONEncoder().encode(dailySnapshots)
            defaults.set(data, forKey: storageKey)
            defaults.set(dailyData, forKey: dailyStorageKey)
            lastError = nil
        } catch {
            snapshots = previousSnapshots
            dailySnapshots = previousDailySnapshots
            lastError = "Could not save usage history: \(error.localizedDescription)"
        }
    }

    private static func loadSnapshots(
        defaults: UserDefaults,
        storageKey: String
    ) -> Result<[UsageHistorySnapshot], Error> {
        guard defaults.object(forKey: storageKey) != nil else {
            return .success([])
        }

        guard let data = defaults.data(forKey: storageKey) else {
            return .failure(UsageHistoryLoadError.invalidStoredValue)
        }

        do {
            let snapshots = try JSONDecoder().decode([UsageHistorySnapshot].self, from: data)
            guard Set(snapshots.map(\.id)).count == snapshots.count else {
                return .failure(UsageHistoryLoadError.duplicateSnapshotID)
            }

            return .success(snapshots.sorted { $0.capturedAt < $1.capturedAt })
        } catch {
            return .failure(error)
        }
    }

    private static func formatSnapshotDate(_ date: Date) -> String {
        UserFacingDateTimeFormatter.current.dateAndTime(date)
    }
}

private enum UsageHistoryLoadError: Error {
    case invalidStoredValue
    case duplicateSnapshotID
}
