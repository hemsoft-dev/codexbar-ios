import Foundation

/// Presentation access only. Recording and retention remain independent of the plan.
public struct HistoryAccessPolicy: Equatable, Sendable {
    public static let free = HistoryAccessPolicy(hasProAccess: false)
    public static let pro = HistoryAccessPolicy(hasProAccess: true)

    public let hasProAccess: Bool

    public init(hasProAccess: Bool) {
        self.hasProAccess = hasProAccess
    }

    public func allows(range: UsageHistoryRange) -> Bool {
        hasProAccess || (range != .month && range != .threeMonths)
    }

    public func cutoff(
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date? {
        hasProAccess ? nil : UsageHistoryRange.sevenDays.startDate(now: now, calendar: calendar)
    }

    public func effectiveStart(
        since requestedStart: Date?,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date? {
        guard let cutoff = cutoff(now: now, calendar: calendar) else { return requestedStart }
        return max(requestedStart ?? cutoff, cutoff)
    }
}
