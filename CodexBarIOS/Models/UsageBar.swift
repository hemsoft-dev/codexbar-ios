import Foundation

public enum UsageProjectionSignificance: Equatable, Sendable {
    case benign
    case warning
}

public struct UsageProjectionDescriptionParts: Equatable, Sendable {
    public let leadingText: String
    public let timestamp: Date?
    public let trailingText: String
    public let significance: UsageProjectionSignificance

    public init(
        leadingText: String,
        timestamp: Date? = nil,
        trailingText: String = "",
        significance: UsageProjectionSignificance = .warning
    ) {
        self.leadingText = leadingText
        self.timestamp = timestamp
        self.trailingText = trailingText
        self.significance = significance
    }

    public func formatted(using formatter: UserFacingDateTimeFormatter) -> String {
        guard let timestamp else {
            return leadingText
        }

        return "\(leadingText)\(formatter.timeWithZone(timestamp, includesWeekday: true))\(trailingText)"
    }
}

public struct UsageBar: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let stableKey: String?
    /// Legacy widget suffix when provider semantics distinguish a shared remainder.
    public let legacyWidgetKey: String?
    public let label: String
    public let used: Double
    public let limit: Double
    public let resetDescription: String?
    public let resetsAt: Date?
    public let resetDisplayStyle: UsageResetDisplayStyle
    public let fractionlessUsageText: String?
    /// Presentation only. Measured usage, fractions and forecasts retain their original precision.
    public let usesMinimumPositivePercent: Bool
    public let projectionCurrent: Double?
    public let projectionLimit: Double?
    public let projectionPeriodStart: Date?
    public let projectionPeriodEnd: Date?
    public let showProjectionOnCurrentBar: Bool
    public let projectionDescriptionOverride: String?
    public let projectionSignificanceOverride: UsageProjectionSignificance?

    public init(
        id: UUID = UUID(),
        stableKey: String? = nil,
        label: String,
        used: Double,
        limit: Double,
        resetDescription: String? = nil,
        resetsAt: Date? = nil,
        resetDisplayStyle: UsageResetDisplayStyle = .verbatim,
        fractionlessUsageText: String? = nil,
        projectionCurrent: Double? = nil,
        projectionLimit: Double? = nil,
        projectionPeriodStart: Date? = nil,
        projectionPeriodEnd: Date? = nil,
        showProjectionOnCurrentBar: Bool = false,
        projectionDescriptionOverride: String? = nil,
        projectionSignificanceOverride: UsageProjectionSignificance? = nil,
        legacyWidgetKey: String? = nil,
        usesMinimumPositivePercent: Bool = false
    ) {
        self.id = id
        self.stableKey = stableKey
        self.legacyWidgetKey = legacyWidgetKey
        self.label = label
        self.used = used
        self.limit = limit
        self.resetDescription = resetDescription
        self.resetsAt = resetsAt
        self.resetDisplayStyle = resetDisplayStyle
        self.fractionlessUsageText = fractionlessUsageText
        self.usesMinimumPositivePercent = usesMinimumPositivePercent
        self.projectionCurrent = projectionCurrent
        self.projectionLimit = projectionLimit
        self.projectionPeriodStart = projectionPeriodStart
        self.projectionPeriodEnd = projectionPeriodEnd
        self.showProjectionOnCurrentBar = showProjectionOnCurrentBar
        self.projectionDescriptionOverride = projectionDescriptionOverride
        self.projectionSignificanceOverride = projectionSignificanceOverride
    }

    public var fractionUsed: Double {
        guard limit > 0 else {
            return 0
        }

        return min(max(used / limit, 0), 1)
    }

    public var isUnboundedNumeric: Bool {
        limit <= 0 && fractionlessUsageText != nil
    }

    public var supportedVisualizationStyles: [MetricVisualizationStyle] {
        isUnboundedNumeric ? [.automatic, .largeNumeric] : MetricVisualizationStyle.allCases
    }

    public func resolvedVisualizationStyle(
        _ preferredStyle: MetricVisualizationStyle
    ) -> MetricVisualizationStyle {
        isUnboundedNumeric ? .largeNumeric : preferredStyle
    }

    public var severity: UsageSeverity {
        severity(using: .default)
    }

    public func severity(using thresholds: UsageSeverityThresholds) -> UsageSeverity {
        UsageSeverity(fractionUsed: fractionUsed, thresholds: thresholds)
    }

    public func projectedSeverity(
        at now: Date = Date(),
        thresholds: UsageSeverityThresholds = .default
    ) -> UsageSeverity? {
        guard let projectedFraction = projectedFraction(at: now) else {
            return nil
        }

        return UsageSeverity(fractionUsed: projectedFraction, thresholds: thresholds)
    }

    public func effectiveSeverity(
        at now: Date = Date(),
        thresholds: UsageSeverityThresholds = .default
    ) -> UsageSeverity {
        max(
            severity(using: thresholds),
            projectedSeverity(at: now, thresholds: thresholds) ?? .normal
        )
    }

    public var usageText: String {
        if isUnboundedNumeric, let fractionlessUsageText {
            return fractionlessUsageText
        }
        guard limit > 0 else {
            return "0%"
        }

        let percent = used / limit * 100
        if usesMinimumPositivePercent && used > 0 && percent < 1 {
            return "1%"
        }
        return "\(Int(percent.rounded()))%"
    }

    /// Visible value beneath the metric heading. Standalone and accessibility text retain units.
    public var metricTileValueText: String {
        let text = usageText
        guard isUnboundedNumeric,
              stableKey == CodexUsageParser.creditsPoolStableKey,
              label == "Credits pool",
              let suffix = [" credits", " credit"].first(where: { text.hasSuffix($0) }) else {
            return text
        }
        return String(text.dropLast(suffix.count))
    }

    public func metricIdentifier(providerID: ProviderID, index: Int) -> String {
        if let stableKey, !stableKey.isEmpty {
            if providerID == .gemini,
               let definition = GoogleUsageMetricCatalog.definitions(for: .gemini).first(where: { $0.key == stableKey }) {
                return definition.id
            }
            return "\(providerID.rawValue).\(stableKey)"
        }

        // Production providers supply stable keys. This position fallback keeps older
        // cached/test metrics deterministic without using a localized display label.
        return "\(providerID.rawValue).position-\(index)"
    }

    public func localizedResetDescription(
        at now: Date = Date(),
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) -> String? {
        dateTimeFormatter.resetDescription(
            resetAt: resetsAt,
            now: now,
            style: resetDisplayStyle,
            fallback: resetDescription
        )
    }

    public func projectedFraction(at now: Date = Date()) -> Double? {
        guard
            let projectionCurrent,
            let projectionLimit,
            let projectionPeriodStart,
            let projectionPeriodEnd,
            projectionCurrent > 0,
            projectionLimit > 0
        else {
            return nil
        }

        let projected = Self.projectedUsage(
            current: projectionCurrent,
            periodStart: projectionPeriodStart,
            periodEnd: projectionPeriodEnd,
            now: now
        )

        return min(max(projected / projectionLimit, 0), 1)
    }

    public func projectionDescription(
        at now: Date = Date(),
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) -> String? {
        projectionDescriptionParts(at: now)?.formatted(using: dateTimeFormatter)
    }

    public func dashboardProjectionDescription(
        at now: Date = Date(),
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) -> String? {
        guard let parts = projectionDescriptionParts(at: now), parts.significance != .benign else {
            return nil
        }
        return parts.formatted(using: dateTimeFormatter)
    }

    public func projectionDescriptionParts(at now: Date = Date()) -> UsageProjectionDescriptionParts? {
        if let projectionDescriptionOverride {
            return UsageProjectionDescriptionParts(
                leadingText: projectionDescriptionOverride,
                significance: projectionSignificanceOverride ?? .warning
            )
        }

        guard
            showProjectionOnCurrentBar,
            let projectionCurrent,
            let projectionLimit,
            let projectionPeriodStart,
            let projectionPeriodEnd,
            let projectedFraction = projectedFraction(at: now),
            projectedFraction > fractionUsed
        else {
            return nil
        }

        let limitHit = Self.limitHitDescriptionParts(
            current: projectionCurrent,
            limit: projectionLimit,
            periodStart: projectionPeriodStart,
            periodEnd: projectionPeriodEnd,
            now: now
        )

        guard limitHit.leadingText != Self.limitNotReachedDescription else {
            return UsageProjectionDescriptionParts(
                leadingText: "Projected to stay under limit",
                significance: .benign
            )
        }

        return UsageProjectionDescriptionParts(
            leadingText: "Projected \(Int((projectedFraction * 100).rounded()))% at current pace - \(limitHit.leadingText)",
            timestamp: limitHit.timestamp,
            trailingText: limitHit.trailingText
        )
    }

    private static let limitNotReachedDescription = "Limit not reached"

    static func projectedUsage(current: Double, periodStart: Date, periodEnd: Date, now: Date) -> Double {
        let elapsed = now.timeIntervalSince(periodStart)
        if elapsed <= 0 || now >= periodEnd {
            return current
        }

        let total = periodEnd.timeIntervalSince(periodStart)
        return current * total / elapsed
    }

    public static func formatLimitHit(
        current: Double,
        limit: Double,
        periodStart: Date,
        periodEnd: Date,
        now: Date = Date(),
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) -> String {
        limitHitDescriptionParts(
            current: current,
            limit: limit,
            periodStart: periodStart,
            periodEnd: periodEnd,
            now: now
        ).formatted(using: dateTimeFormatter)
    }

    private static func limitHitDescriptionParts(
        current: Double,
        limit: Double,
        periodStart: Date,
        periodEnd: Date,
        now: Date
    ) -> UsageProjectionDescriptionParts {
        if current >= limit {
            return UsageProjectionDescriptionParts(leadingText: "Limit reached")
        }

        let elapsed = now.timeIntervalSince(periodStart)
        guard elapsed > 0 else {
            return UsageProjectionDescriptionParts(leadingText: "Limit hit unknown")
        }

        let ratePerSecond = current / elapsed
        guard ratePerSecond > 0 else {
            return UsageProjectionDescriptionParts(leadingText: "Limit hit unknown")
        }

        let secondsToLimit = limit / ratePerSecond
        let hitAt = periodStart.addingTimeInterval(secondsToLimit)
        if hitAt > periodEnd {
            return UsageProjectionDescriptionParts(leadingText: limitNotReachedDescription)
        }

        let earlyDescription = hitAt < periodEnd
            ? " - \(formatEarlyDuration(periodEnd.timeIntervalSince(hitAt))) early"
            : ""

        return UsageProjectionDescriptionParts(
            leadingText: "Limit hit ",
            timestamp: hitAt,
            trailingText: earlyDescription
        )
    }

    private static func formatEarlyDuration(_ duration: TimeInterval) -> String {
        let totalMinutes = max(0, Int(duration / 60))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        var parts: [String] = []

        if days > 0 {
            parts.append("\(days)d")
        }

        if hours > 0 {
            parts.append("\(hours)h")
        }

        if minutes > 0 || parts.isEmpty {
            parts.append("\(minutes)m")
        }

        return parts.joined(separator: " ")
    }
}
