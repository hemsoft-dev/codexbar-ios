import Foundation

/// What Google's Models & Usage page fetched, as text. CodexBar never requests these itself (ANTIGRAVITY-USAGE.md).
public struct AntigravityPageCapture: Equatable, Sendable {
    /// Body of the page's own `GetUserQuotaSummary` response.
    public var quotaBody: String
    /// Body of the page's own `GetUserProfile` response, when the page fetched one.
    public var profileBody: String?
    /// Path of the page when it reported quota. Never a query, fragment or host.
    public var pagePath: String?

    public init(quotaBody: String, profileBody: String? = nil, pagePath: String? = nil) {
        self.quotaBody = quotaBody
        self.profileBody = profileBody
        self.pagePath = pagePath
    }
}

/// Decodes the responses Google's page received. Field numbers come from the page's public code:
/// the page asks for `application/json+protobuf`, where a message is an array indexed by field number.
public enum AntigravityQuotaParser {
    public static let providerID = ProviderID.antigravityWeb
    static let weeklyLimitReachedReason = "Weekly limit reached"
    static let unavailableReason = "Unavailable"

    public struct Bucket: Equatable, Sendable {
        public var bucketID: String
        public var groupName: String
        public var displayName: String
        public var window: String
        /// Nil when Google sent no fraction, or one outside 0...1.
        public var remainingFraction: Double?
        public var resetTime: Date?
        /// Google's sentence about the pool. Its page shows a refresh time only for pools that have one.
        public var hasDescription = false
        public var isDisabled: Bool
        public var isMalformed: Bool
    }

    public struct Plan: Equatable, Sendable {
        public var identifier: String
        public var displayName: String
    }

    public enum ParseError: Error, Equatable {
        /// The body isn't the message this parser knows.
        case unreadable
    }

    // MARK: Quota

    public static func buckets(fromQuotaBody body: String) throws -> [Bucket] {
        guard let root = jsonRoot(body) else { throw ParseError.unreadable }
        if let object = root as? [String: Any] {
            return try buckets(fromObject: object)
        }
        guard let response = JSPBMessage(root), let summary = response.message(1), let inner = summary.message(1) else {
            throw ParseError.unreadable
        }
        var result = (inner.repeated(1) ?? []).map { bucket($0, groupName: "") }
        for group in inner.repeated(2) ?? [] {
            guard let message = JSPBMessage(group) else { continue }
            let name = message.string(2) ?? ""
            result += (message.repeated(1) ?? []).map { bucket($0, groupName: name) }
        }
        return result
    }

    private static func bucket(_ value: Any, groupName: String) -> Bucket {
        guard let message = JSPBMessage(value) else {
            return Bucket(
                bucketID: "", groupName: groupName, displayName: "", window: "", remainingFraction: nil,
                resetTime: nil, isDisabled: false, isMalformed: true
            )
        }
        var malformed = false
        func checked<T>(_ field: Int, _ read: (Int) -> T?) -> T? {
            guard message.isPresent(field) else { return nil }
            guard let value = read(field) else {
                malformed = true
                return nil
            }
            return value
        }
        let fraction = checked(4, message.double)
        let reset = checked(6) { field in message.message(field).flatMap(timestamp) }
        let disabled = checked(8, message.bool) ?? false
        let bucketID = checked(1, message.string) ?? ""
        return Bucket(
            bucketID: bucketID,
            groupName: groupName,
            displayName: checked(2, message.string) ?? "",
            window: checked(3, message.string) ?? "",
            remainingFraction: fraction.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil },
            resetTime: reset,
            hasDescription: message.string(7)?.isEmpty == false,
            isDisabled: disabled,
            isMalformed: malformed || bucketID.isEmpty || fraction.map { !$0.isFinite || !(0...1).contains($0) } == true
        )
    }

    /// The same messages in protobuf's named JSON form, in case Google's page switches encoding.
    private static func buckets(fromObject root: [String: Any]) throws -> [Bucket] {
        let summary = root["summary"] as? [String: Any] ?? root
        let inner = summary["response"] as? [String: Any] ?? summary
        guard inner["groups"] != nil || inner["buckets"] != nil else { throw ParseError.unreadable }
        func named(_ value: Any, groupName: String) -> Bucket {
            let object = value as? [String: Any] ?? [:]
            let fraction = (object["remainingFraction"] as? NSNumber).flatMap(number)
            let hasBadFraction = object["remainingFraction"] != nil
                && (fraction == nil || !(fraction!.isFinite && (0...1).contains(fraction!)))
            let resetText = object["resetTime"] as? String
            let reset = resetText.flatMap(isoDate)
            let bucketID = object["bucketId"] as? String ?? ""
            return Bucket(
                bucketID: bucketID,
                groupName: groupName,
                displayName: object["displayName"] as? String ?? "",
                window: object["window"] as? String ?? "",
                remainingFraction: hasBadFraction ? nil : fraction,
                resetTime: reset,
                hasDescription: (object["description"] as? String)?.isEmpty == false,
                isDisabled: object["disabled"] as? Bool ?? false,
                isMalformed: bucketID.isEmpty || hasBadFraction || (resetText != nil && reset == nil)
            )
        }
        var result = (inner["buckets"] as? [Any] ?? []).map { named($0, groupName: "") }
        for group in inner["groups"] as? [Any] ?? [] {
            guard let object = group as? [String: Any] else { continue }
            let name = object["displayName"] as? String ?? ""
            result += (object["buckets"] as? [Any] ?? []).map { named($0, groupName: name) }
        }
        return result
    }

    // MARK: Plan

    /// The plan Google's page shows, or nil when the page reported none.
    public static func plan(fromProfileBody body: String?) -> Plan? {
        guard let body, let root = jsonRoot(body) else { return nil }
        let identifier: String?
        let name: String?
        if let object = root as? [String: Any] {
            let plan = object["plan"] as? [String: Any]
            identifier = plan?["id"] as? String
            name = plan?["displayName"] as? String
        } else {
            let plan = JSPBMessage(root)?.message(2)
            identifier = plan?.string(1)
            name = plan?.string(2)
        }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed.count <= 60 else { return nil }
        return Plan(identifier: identifier?.isEmpty == false ? identifier! : trimmed, displayName: trimmed)
    }

    // MARK: Result

    public static func result(
        from capture: AntigravityPageCapture,
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date = Date()
    ) throws -> ProviderUsageResult {
        let buckets = try buckets(fromQuotaBody: capture.quotaBody)
        let definitions = ProviderMetricCatalog.definitions(for: providerID)
        var bars: [UsageBar] = []
        var unavailable: [String: String] = [:]
        for definition in definitions {
            let matches = buckets.filter { $0.bucketID == definition.key }
            // Two buckets with one identifier can't both be right, so neither is shown.
            guard matches.count == 1, let bucket = matches.first else {
                unavailable[definition.id] = unavailableReason
                continue
            }
            if bucket.isDisabled {
                unavailable[definition.id] = definition.window == "5h" ? weeklyLimitReachedReason : ProviderMetricCatalog.disabledReason
            } else if let bar = bar(for: bucket, key: definition.key, label: definition.label, window: definition.window, fetchedAt: fetchedAt) {
                bars.append(bar)
            } else {
                unavailable[definition.id] = unavailableReason
            }
        }
        let knownKeys = Set(definitions.map(\.key))
        var extraKeys = Set<String>()
        for bucket in buckets where !knownKeys.contains(bucket.bucketID) && !bucket.isDisabled {
            guard let key = extraPoolKey(bucket.bucketID), extraKeys.insert(key).inserted,
                  buckets.filter({ $0.bucketID == bucket.bucketID }).count == 1,
                  let bar = bar(for: bucket, key: key, label: extraPoolLabel(bucket), window: bucket.window, fetchedAt: fetchedAt)
            else { continue }
            bars.append(bar)
        }
        let plan = plan(fromProfileBody: capture.profileBody).map {
            ProviderPlanDescriptor.make(
                providerPrefix: providerID.rawValue, identifier: planSlug($0.identifier), label: $0.displayName,
                displayLabel: $0.displayName
            )
        }
        let hasKnownBar = bars.contains { $0.stableKey.map(knownKeys.contains) == true }
        let missing = definitions.filter { unavailable[$0.id] == unavailableReason }
        let message = missing.isEmpty ? nil : "Google's page didn't report: " + missing.map(\.label).joined(separator: ", ") + "."
        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: providerID,
            title: configuration.displayName,
            plan: plan,
            subtitle: "Experimental · read from Google's Models & Usage page",
            bars: bars,
            unavailableUsageMetrics: unavailable,
            usageMessages: message.map { [$0] } ?? [],
            failureMessage: hasKnownBar || !unavailable.values.allSatisfy { $0 == unavailableReason }
                ? nil : AntigravityReadError.noUsageReported.localizedDescription,
            fetchedAt: fetchedAt
        )
    }

    /// 100 minus the whole percent Google's page shows, which the page computes as `Math.round(fraction * 100)`.
    static func percentUsed(remainingFraction: Double) -> Double {
        100 - (remainingFraction * 100 + 0.5).rounded(.down)
    }

    private static func bar(for bucket: Bucket, key: String, label: String, window: String, fetchedAt: Date) -> UsageBar? {
        guard !bucket.isMalformed, let remaining = bucket.remainingFraction else { return nil }
        if !bucket.window.isEmpty && bucket.window != window { return nil }
        // Google sends a reset time even for an untouched pool, but its page shows a refresh time only for a pool
        // it describes as used. The card follows the page. A reset already past is never shown.
        let showsReset = bucket.hasDescription || remaining < 1
        let reset = bucket.resetTime.flatMap { showsReset && $0 > fetchedAt ? $0 : nil }
        // No pace forecast: Google reports when a limit refreshes, not when its window began.
        return UsageBar(
            stableKey: key,
            label: label,
            used: percentUsed(remainingFraction: remaining),
            limit: 100,
            resetsAt: reset,
            resetDisplayStyle: .relativeWithLocalTime
        )
    }

    /// Extra pools keep Google's identifier, limited to characters that are safe in a metric identifier.
    static func extraPoolKey(_ bucketID: String) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        let key = String(bucketID.lowercased().filter { allowed.contains($0) })
        guard !key.isEmpty, key.count <= 64, key == bucketID.lowercased() else { return nil }
        // A dotted part must never equal a retired identifier, and this key becomes one dotted part.
        return RetiredProviderMigration.isRetiredIdentifier(key) ? nil : "extra-\(key)"
    }

    private static func extraPoolLabel(_ bucket: Bucket) -> String {
        let parts = [bucket.groupName, bucket.displayName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var label = parts.joined(separator: " ")
        // Google names its rows "… Limit Remaining"; the card shows percent used, so that word would mislead.
        if label.hasSuffix(" Remaining") { label = String(label.dropLast(" Remaining".count)) }
        return String((label.isEmpty ? bucket.bucketID : label).prefix(60))
    }

    private static func planSlug(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let slug = String(value.lowercased().map { allowed.contains($0) ? $0 : "-" })
        return slug.isEmpty ? "plan" : slug
    }

    // MARK: Decoding helpers

    /// Google's web responses can start with a guard line that isn't JSON.
    private static func jsonRoot(_ body: String) -> Any? {
        var text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(")]}'") {
            text = String(text.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8), data.count <= 512 * 1024 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func timestamp(_ message: JSPBMessage) -> Date? {
        guard let seconds = message.double(1), seconds.isFinite, seconds > 0, seconds < 32_503_680_000 else { return nil }
        let nanos = message.isPresent(2) ? message.double(2) : 0
        guard let nanos, (0..<1_000_000_000).contains(nanos) else { return nil }
        return Date(timeIntervalSince1970: seconds + nanos / 1_000_000_000)
    }

    private static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    fileprivate static func number(_ value: NSNumber) -> Double? {
        CFGetTypeID(value) == CFBooleanGetTypeID() ? nil : value.doubleValue
    }
}

/// One `application/json+protobuf` message: field `n` sits at index `n - 1`, and a trailing object can hold
/// further fields keyed by their number.
private struct JSPBMessage {
    private let positional: [Any]
    private let sparse: [String: Any]

    init?(_ value: Any) {
        guard var array = value as? [Any] else { return nil }
        if let last = array.last as? [String: Any] {
            sparse = last
            array.removeLast()
        } else {
            sparse = [:]
        }
        positional = array
    }

    private func raw(_ field: Int) -> Any? {
        let value: Any? = field >= 1 && field <= positional.count ? positional[field - 1] : sparse[String(field)]
        return value is NSNull ? nil : value
    }

    func isPresent(_ field: Int) -> Bool {
        raw(field) != nil
    }

    func string(_ field: Int) -> String? {
        raw(field) as? String
    }

    /// 64-bit integers arrive as text, floats as numbers.
    func double(_ field: Int) -> Double? {
        if let number = raw(field) as? NSNumber { return AntigravityQuotaParser.number(number) }
        if let text = raw(field) as? String { return Double(text) }
        return nil
    }

    func bool(_ field: Int) -> Bool? {
        guard let number = raw(field) as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        return number == 1 ? true : (number == 0 ? false : nil)
    }

    func message(_ field: Int) -> JSPBMessage? {
        raw(field).flatMap(JSPBMessage.init)
    }

    func repeated(_ field: Int) -> [Any]? {
        raw(field) as? [Any]
    }
}
