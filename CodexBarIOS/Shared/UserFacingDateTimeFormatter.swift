import Foundation

public enum UsageResetDisplayStyle: String, Codable, Sendable {
    case verbatim
    case relativeWithLocalTime
    case shortLocalDate
}

public struct UserFacingDateTimeFormatter {
    public static var current: UserFacingDateTimeFormatter {
        UserFacingDateTimeFormatter(
            timeZoneProvider: { .autoupdatingCurrent },
            localeProvider: { .autoupdatingCurrent }
        )
    }

    private let timeZoneProvider: () -> TimeZone
    private let localeProvider: () -> Locale

    public init(timeZone: TimeZone, locale: Locale) {
        self.init(timeZoneProvider: { timeZone }, localeProvider: { locale })
    }

    init(
        timeZoneProvider: @escaping () -> TimeZone,
        localeProvider: @escaping () -> Locale
    ) {
        self.timeZoneProvider = timeZoneProvider
        self.localeProvider = localeProvider
    }

    public func timeWithZone(_ date: Date, includesWeekday: Bool) -> String {
        let timeZone = timeZoneProvider()
        let value = format(
            date,
            template: includesWeekday ? "Ejm" : "jm",
            timeZone: timeZone
        )
        return "\(value) \(zoneLabel(for: date, timeZone: timeZone))"
    }

    /// A US dollar amount in this formatter's locale, so text that joins an amount and a date agrees.
    public func usDollars(_ amount: Decimal) -> String {
        amount.formatted(.currency(code: "USD").precision(.fractionLength(2)).locale(localeProvider()))
    }

    public func shortDate(_ date: Date) -> String {
        format(date, template: "MMMd", timeZone: timeZoneProvider())
    }

    public func dateAndTime(_ date: Date) -> String {
        format(date, template: "yMMMdjm", timeZone: timeZoneProvider())
    }

    public func time(_ date: Date) -> String {
        format(date, template: "jm", timeZone: timeZoneProvider())
    }

    public func resetDescription(
        resetAt: Date?,
        now: Date,
        style: UsageResetDisplayStyle,
        fallback: String?,
        includesMinutesBeyondFinalHour: Bool = true
    ) -> String? {
        guard let resetAt else {
            return fallback
        }

        switch style {
        case .verbatim:
            return fallback
        case .shortLocalDate:
            return "Resets \(shortDate(resetAt))"
        case .relativeWithLocalTime:
            let remaining = resetAt.timeIntervalSince(now)
            let localTime = timeWithZone(resetAt, includesWeekday: remaining >= 86_400)
            let relativeDescription = relativeResetDescription(
                remaining: remaining,
                includesMinutesBeyondFinalHour: includesMinutesBeyondFinalHour
            )
            return "\(relativeDescription) (\(localTime))"
        }
    }

    private func format(_ date: Date, template: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = localeProvider()
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    private func zoneLabel(for date: Date, timeZone: TimeZone) -> String {
        if let abbreviation = timeZone.abbreviation(for: date), !abbreviation.isEmpty {
            return abbreviation
        }

        let seconds = timeZone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let absoluteMinutes = abs(seconds) / 60
        let hours = absoluteMinutes / 60
        let minutes = absoluteMinutes % 60
        return minutes == 0
            ? "GMT\(sign)\(hours)"
            : String(format: "GMT%@%d:%02d", sign, hours, minutes)
    }

    private func relativeResetDescription(
        remaining: TimeInterval,
        includesMinutesBeyondFinalHour: Bool
    ) -> String {
        if remaining <= 0 {
            return "Resets now"
        }

        if !includesMinutesBeyondFinalHour, remaining >= 3_600 {
            return "Resets \(Int(ceil(remaining / 3_600)))h"
        }

        if remaining >= 86_400 {
            let days = Int(remaining / 86_400)
            let hours = Int(remaining.truncatingRemainder(dividingBy: 86_400) / 3_600)
            return "Resets \(days)d \(hours)h"
        }

        if remaining >= 3_600 {
            let hours = Int(remaining / 3_600)
            let minutes = Int(remaining.truncatingRemainder(dividingBy: 3_600) / 60)
            return "Resets \(hours)h \(minutes)m"
        }

        return "Resets \(max(1, Int(remaining / 60)))m"
    }
}
