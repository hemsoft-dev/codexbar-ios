import Foundation

/// Muse Code subscription allowance from schema 1 of `muse usage --json` (Muse Code 1.4.13-R6996.1).
///
/// Meta publishes no sign-in or usage endpoint that an iPhone app can use, so nothing in the app calls
/// this yet and Muse Code can't be added as an account. The parser and states exist so a future supported
/// source maps through tested, truthful results. Field mapping, limits and fixtures: MUSE-CODE.md.
enum MuseCodeAllowance {
    static let supportedSchemaVersion = 1
    /// An observation older than this is shown as last known, never as current.
    static let freshnessInterval: TimeInterval = 7 * 60
    static let futureObservationTolerance: TimeInterval = 60
    static let phoneAcquisitionUnavailableReason =
        "Meta doesn't offer a sign-in or usage service that iPhone apps can use for Muse Code subscriptions. "
        + "CodexBar won't estimate your allowance from token activity."

    enum Window: String, CaseIterable, Equatable, Sendable {
        case window
        case weekly

        var duration: TimeInterval {
            switch self {
            case .window: 5 * 60 * 60
            case .weekly: 7 * 24 * 60 * 60
            }
        }

        var label: String {
            switch self {
            case .window: "5-hour"
            case .weekly: "Weekly"
            }
        }

        var metricID: String {
            "\(ProviderID.museCode.rawValue).\(rawValue)"
        }
    }

    struct WindowReading: Equatable, Sendable {
        let window: Window
        /// Percentage of the allowance used, as reported. May exceed 100.
        let usedPercent: Double
        let resetsAt: Date
    }

    struct Reading: Equatable, Sendable {
        let observedAt: Date
        let tier: String?
        let source: String?
        let windows: [WindowReading]
        let invalidWindows: [Window]
        let undocumentedWindowNames: [String]
        let unnamedUndocumentedWindowCount: Int
    }

    /// Every reason the app cannot show a current allowance. None of them is zero, unlimited or healthy.
    enum Unavailable: String, CaseIterable, Equatable, Sendable {
        case phoneAcquisitionUnsupported
        case allowanceNotReported
        case unsupportedSchema
        case malformed
        case observationMissing
        case observationInFuture
        case noValidWindows
        case authorizationExpired
        case entitlementDenied
        case payAsYouGoBilling
        case rateLimited
        case timedOut
        case transportFailure

        var message: String {
            switch self {
            case .phoneAcquisitionUnsupported:
                "Muse Code isn't available on iPhone. " + MuseCodeAllowance.phoneAcquisitionUnavailableReason
            case .allowanceNotReported:
                "Muse Code didn't report a subscription allowance."
            case .unsupportedSchema:
                "Muse Code sent an allowance format this version of CodexBar doesn't support."
            case .malformed:
                "Muse Code sent an allowance CodexBar couldn't read."
            case .observationMissing:
                "Muse Code didn't say when the allowance was measured."
            case .observationInFuture:
                "Muse Code reported an allowance measured in the future."
            case .noValidWindows:
                "Muse Code reported no valid allowance windows."
            case .authorizationExpired:
                "Muse Code sign-in expired. Sign in again to read the allowance."
            case .entitlementDenied:
                "This Meta account has no Muse Code subscription allowance."
            case .payAsYouGoBilling:
                "This connection uses pay-as-you-go billing, which has no subscription allowance."
            case .rateLimited:
                "Muse Code is limiting requests. Try again later."
            case .timedOut:
                "Muse Code didn't respond in time."
            case .transportFailure:
                "Couldn't reach Muse Code."
            }
        }

        var recoveryAction: ProviderUsageRecoveryAction {
            self == .authorizationExpired ? .reauthenticate : .retryRefresh
        }
    }

    enum Outcome: Equatable, Sendable {
        case reading(Reading)
        case unavailable(Unavailable)
    }

    // MARK: - Parsing

    /// Parses one payload. `reason` and `hint` are free-form and may carry identity; they are never read.
    static func parse(_ data: Data, now: Date) -> Outcome {
        guard case let .object(root)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .unavailable(.malformed)
        }
        guard case let .number(version)? = root["schemaVersion"], version == Double(supportedSchemaVersion) else {
            return .unavailable(.unsupportedSchema)
        }
        let allowance: [String: JSONValue]
        switch root["allowance"] {
        case .null?:
            return .unavailable(.allowanceNotReported)
        case let .object(object)?:
            allowance = object
        default:
            return .unavailable(.malformed)
        }
        guard let observedAt = allowance["asOfMs"].flatMap(date) else {
            return .unavailable(.observationMissing)
        }
        guard observedAt <= now.addingTimeInterval(futureObservationTolerance) else {
            return .unavailable(.observationInFuture)
        }

        var windows: [WindowReading] = []
        var invalid: [Window] = []
        for window in Window.allCases {
            guard let value = allowance[window.rawValue] else { continue }
            if let reading = windowReading(window, value: value, observedAt: observedAt, now: now) {
                windows.append(reading)
            } else {
                invalid.append(window)
            }
        }
        guard !windows.isEmpty else {
            return .unavailable(.noValidWindows)
        }

        let documented = Set(Window.allCases.map(\.rawValue) + ["asOfMs", "tier", "source"])
        let undocumented = allowance.keys.sorted().filter { key in
            guard !documented.contains(key), case let .object(object)? = allowance[key] else { return false }
            return object["usedPercent"]?.numberValue != nil && object["resetsAtMs"]?.numberValue != nil
        }
        let named = undocumented.filter { matches($0, pattern: "^[A-Za-z0-9_-]{1,40}$") }
        return .reading(Reading(
            observedAt: observedAt,
            tier: allowance["tier"]?.stringValue.flatMap { matches($0, pattern: "^[A-Za-z0-9 ._()+-]{1,64}$") ? $0 : nil },
            source: allowance["source"]?.stringValue.flatMap { matches($0, pattern: "^[a-z0-9_-]{1,32}$") ? $0 : nil },
            windows: windows,
            invalidWindows: invalid,
            undocumentedWindowNames: named,
            unnamedUndocumentedWindowCount: undocumented.count - named.count
        ))
    }

    private static func windowReading(_ window: Window, value: JSONValue, observedAt: Date, now: Date) -> WindowReading? {
        guard case let .object(object) = value,
              let used = object["usedPercent"]?.numberValue, used.isFinite, used >= 0,
              let resetsAt = object["resetsAtMs"].flatMap(date),
              resetsAt > observedAt, resetsAt > now,
              resetsAt.timeIntervalSince(observedAt) <= window.duration
        else {
            return nil
        }
        return WindowReading(window: window, usedPercent: used, resetsAt: resetsAt)
    }

    private static func date(_ value: JSONValue) -> Date? {
        guard let milliseconds = value.numberValue, milliseconds.isFinite, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Results

    static func result(
        for outcome: Outcome,
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date,
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) -> ProviderUsageResult {
        switch outcome {
        case let .unavailable(reason):
            ProviderUsageResult(
                accountID: configuration.id,
                providerID: .museCode,
                title: configuration.displayName,
                subtitle: "Muse Code subscription allowance",
                bars: [],
                unavailableUsageMetrics: Dictionary(uniqueKeysWithValues: Window.allCases.map { ($0.metricID, "Unavailable") }),
                failureMessage: reason.message,
                recoveryAction: reason.recoveryAction,
                preserveCachedBarsOnFailure: reason != .phoneAcquisitionUnsupported,
                fetchedAt: fetchedAt
            )
        case let .reading(reading):
            readingResult(reading, configuration: configuration, fetchedAt: fetchedAt, dateTimeFormatter: dateTimeFormatter)
        }
    }

    private static func readingResult(
        _ reading: Reading,
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date,
        dateTimeFormatter: UserFacingDateTimeFormatter
    ) -> ProviderUsageResult {
        let age = fetchedAt.timeIntervalSince(reading.observedAt)
        let isStale = age > freshnessInterval
        let bars = reading.windows.map { window in
            UsageBar(
                stableKey: window.window.rawValue,
                label: window.window.label,
                used: min(window.usedPercent, 100),
                limit: 100,
                resetsAt: window.resetsAt,
                resetDisplayStyle: .relativeWithLocalTime,
                // A stale observation cannot anchor a current forecast.
                projectionCurrent: isStale ? nil : window.usedPercent / 100,
                projectionLimit: isStale ? nil : 1,
                projectionPeriodStart: isStale ? nil : window.resetsAt.addingTimeInterval(-window.window.duration),
                projectionPeriodEnd: isStale ? nil : window.resetsAt,
                showProjectionOnCurrentBar: !isStale
            )
        }
        var messages = reading.invalidWindows.map { "\($0.label) allowance unavailable: Muse Code sent an invalid value." }
        let undocumentedCount = reading.undocumentedWindowNames.count + reading.unnamedUndocumentedWindowCount
        if undocumentedCount > 0 {
            let names = reading.undocumentedWindowNames.joined(separator: ", ")
            let unnamed = reading.unnamedUndocumentedWindowCount
            let detail = names.isEmpty ? "\(unnamed)" : (unnamed > 0 ? "\(names) and \(unnamed) more" : names)
            messages.append("Muse Code reported other allowance windows that CodexBar doesn't track (\(detail)).")
        }
        if isStale {
            messages.append("Last known value, measured \(Int(age / 60)) minutes before this refresh.")
        }
        var items = [
            ProviderCardInformationItem(
                id: "museCode.observed-at",
                label: "Measured",
                detail: dateTimeFormatter.dateAndTime(reading.observedAt)
            ),
        ]
        if let source = reading.source {
            items.append(ProviderCardInformationItem(id: "museCode.source", label: "Source", detail: source))
        }
        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: .museCode,
            title: configuration.displayName,
            plan: reading.tier.map {
                ProviderPlanDescriptor.make(
                    providerPrefix: ProviderID.museCode.rawValue,
                    identifier: $0.lowercased().replacingOccurrences(of: " ", with: "-"),
                    label: $0,
                    displayLabel: $0
                )
            },
            subtitle: "Muse Code subscription allowance",
            bars: bars,
            barsFetchedAt: isStale ? reading.observedAt : fetchedAt,
            unavailableUsageMetrics: Dictionary(uniqueKeysWithValues: reading.invalidWindows.map { ($0.metricID, "Unavailable") }),
            usageMessages: messages,
            cardInformationSections: [
                ProviderCardInformationSection(id: "museCode.observation", title: "Allowance reading", items: items),
            ],
            fetchedAt: fetchedAt
        )
    }
}

/// Untyped JSON that keeps numbers, strings and booleans distinct, so `"15"` or `true` never becomes a number.
private enum JSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    var numberValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }
}
