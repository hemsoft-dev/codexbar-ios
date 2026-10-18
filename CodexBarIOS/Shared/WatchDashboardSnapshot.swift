import Foundation

public enum WatchDashboardPayloadError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case invalidPublicationSequence
}

enum WatchDashboardApplicationContext: Equatable, Sendable {
    case empty
    case snapshot(Data)
    case malformed

    init(_ applicationContext: [String: Any]) {
        if applicationContext.isEmpty {
            self = .empty
        } else if let data = applicationContext[WatchDashboardSnapshot.applicationContextDataKey]
            as? Data {
            self = .snapshot(data)
        } else {
            self = .malformed
        }
    }

    var isEmpty: Bool {
        self == .empty
    }

    func decode() throws -> WatchDashboardSnapshot {
        guard case let .snapshot(data) = self else {
            throw CocoaError(.coderReadCorrupt)
        }
        return try WatchDashboardSnapshot.decode(data)
    }
}

enum WatchDashboardSnapshotResponse: Equatable, Sendable {
    case snapshot(Data)
    case unavailable
    case malformed

    init(_ reply: [String: Any]) {
        if let data = reply[WatchDashboardSnapshot.applicationContextDataKey] as? Data {
            self = .snapshot(data)
        } else if reply[WatchDashboardSnapshot.snapshotUnavailableKey] as? Bool == true {
            self = .unavailable
        } else {
            self = .malformed
        }
    }

    func decode() throws -> WatchDashboardSnapshot {
        guard case let .snapshot(data) = self else {
            throw CocoaError(.coderReadCorrupt)
        }
        return try WatchDashboardSnapshot.decode(data)
    }
}

public enum WatchMetricVisualizationStyle: String, CaseIterable, Equatable, Sendable {
    case automatic
    case linearBar
    case segmentedBar
    case circularRing
    case semicircularDial
    case largeNumeric
    case statusText

    public func resolvedForWatch(allowsGauge: Bool) -> WatchMetricVisualizationStyle {
        if self == .automatic {
            return .linearBar
        }
        if !allowsGauge && (self == .circularRing || self == .semicircularDial) {
            return .linearBar
        }
        return self
    }

    public func showsHeaderExactValueOnWatch(allowsGauge: Bool) -> Bool {
        switch resolvedForWatch(allowsGauge: allowsGauge) {
        case .automatic, .linearBar, .segmentedBar:
            true
        case .circularRing, .semicircularDial, .largeNumeric, .statusText:
            false
        }
    }
}

extension WatchMetricVisualizationStyle: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .automatic
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum WatchMetricSeverity: String, Equatable, Sendable {
    case normal
    case warning
    case critical
}

extension WatchMetricSeverity: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .normal
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct WatchMetricSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let scope: String?
    public let usedFraction: Double?
    public let remainingFraction: Double?
    public let exactValue: String
    public let severity: WatchMetricSeverity
    public let resetText: String?
    public let resetsAt: Date?
    public let resetDisplayStyle: UsageResetDisplayStyle?
    public let fetchedAt: Date?
    public let visualizationStyle: WatchMetricVisualizationStyle

    public init(
        id: String,
        label: String,
        scope: String? = nil,
        usedFraction: Double? = nil,
        remainingFraction: Double? = nil,
        exactValue: String,
        severity: WatchMetricSeverity = .normal,
        resetText: String? = nil,
        resetsAt: Date? = nil,
        resetDisplayStyle: UsageResetDisplayStyle? = nil,
        fetchedAt: Date? = nil,
        visualizationStyle: WatchMetricVisualizationStyle = .automatic
    ) {
        self.id = id
        self.label = label
        self.scope = scope
        self.usedFraction = usedFraction.map { max($0, 0) }
        self.remainingFraction = remainingFraction.map { min(max($0, 0), 1) }
        self.exactValue = exactValue
        self.severity = severity
        self.resetText = resetText
        self.resetsAt = resetsAt
        self.resetDisplayStyle = resetDisplayStyle
        self.fetchedAt = fetchedAt
        self.visualizationStyle = visualizationStyle
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case scope
        case usedFraction
        case remainingFraction
        case exactValue
        case severity
        case resetText
        case resetsAt
        case resetDisplayStyle
        case fetchedAt
        case visualizationStyle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            label: try container.decode(String.self, forKey: .label),
            scope: try container.decodeIfPresent(String.self, forKey: .scope),
            usedFraction: try container.decodeIfPresent(Double.self, forKey: .usedFraction),
            remainingFraction: try container.decodeIfPresent(Double.self, forKey: .remainingFraction),
            exactValue: try container.decode(String.self, forKey: .exactValue),
            severity: try container.decodeIfPresent(WatchMetricSeverity.self, forKey: .severity) ?? .normal,
            resetText: try container.decodeIfPresent(String.self, forKey: .resetText),
            resetsAt: try container.decodeIfPresent(Date.self, forKey: .resetsAt),
            resetDisplayStyle: try container.decodeIfPresent(
                UsageResetDisplayStyle.self,
                forKey: .resetDisplayStyle
            ),
            fetchedAt: try container.decodeIfPresent(Date.self, forKey: .fetchedAt),
            visualizationStyle: try container.decodeIfPresent(
                WatchMetricVisualizationStyle.self,
                forKey: .visualizationStyle
            ) ?? .automatic
        )
    }
}

public struct WatchAccountSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let legacyAccountIDs: [String]?
    public let providerName: String
    public let accountLabel: String
    public let planIdentifier: String?
    public let planDisplayLabel: String?
    public let planAccessibilityLabel: String?
    public let statusText: String?
    public let fetchedAt: Date
    public let metrics: [WatchMetricSnapshot]

    public init(
        id: String,
        legacyAccountIDs: [String] = [],
        providerName: String,
        accountLabel: String,
        planIdentifier: String? = nil,
        planDisplayLabel: String? = nil,
        planAccessibilityLabel: String? = nil,
        statusText: String? = nil,
        fetchedAt: Date,
        metrics: [WatchMetricSnapshot]
    ) {
        self.id = id
        self.legacyAccountIDs = legacyAccountIDs.isEmpty ? nil : legacyAccountIDs
        self.providerName = providerName
        self.accountLabel = accountLabel
        self.planIdentifier = planIdentifier
        self.planDisplayLabel = planDisplayLabel
        self.planAccessibilityLabel = planAccessibilityLabel
        self.statusText = statusText
        self.fetchedAt = fetchedAt
        self.metrics = metrics
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case legacyAccountIDs
        case providerName
        case accountLabel
        case planIdentifier
        case planDisplayLabel
        case planAccessibilityLabel
        case statusText
        case fetchedAt
        case metrics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedMetrics = try container.decodeIfPresent(
            [LossyDecodable<WatchMetricSnapshot>].self,
            forKey: .metrics
        ) ?? []
        self.init(
            id: try container.decode(String.self, forKey: .id),
            legacyAccountIDs: try container.decodeIfPresent([String].self, forKey: .legacyAccountIDs) ?? [],
            providerName: try container.decode(String.self, forKey: .providerName),
            accountLabel: try container.decode(String.self, forKey: .accountLabel),
            planIdentifier: try container.decodeIfPresent(String.self, forKey: .planIdentifier),
            planDisplayLabel: try container.decodeIfPresent(String.self, forKey: .planDisplayLabel),
            planAccessibilityLabel: try container.decodeIfPresent(String.self, forKey: .planAccessibilityLabel),
            statusText: try container.decodeIfPresent(String.self, forKey: .statusText),
            fetchedAt: try container.decode(Date.self, forKey: .fetchedAt),
            metrics: decodedMetrics.compactMap(\.value)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(legacyAccountIDs, forKey: .legacyAccountIDs)
        try container.encode(providerName, forKey: .providerName)
        try container.encode(accountLabel, forKey: .accountLabel)
        try container.encodeIfPresent(planIdentifier, forKey: .planIdentifier)
        try container.encodeIfPresent(planDisplayLabel, forKey: .planDisplayLabel)
        try container.encodeIfPresent(planAccessibilityLabel, forKey: .planAccessibilityLabel)
        try container.encodeIfPresent(statusText, forKey: .statusText)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(metrics, forKey: .metrics)
    }
}

public struct WatchDashboardSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let applicationContextDataKey = "codexbar.dashboard.snapshot"
    public static let applicationContextVersionKey = "codexbar.dashboard.schema"
    public static let snapshotRequestKey = "codexbar.dashboard.request"
    public static let snapshotAfterSequenceKey = "codexbar.dashboard.afterSequence"
    public static let snapshotUnavailableKey = "codexbar.dashboard.unavailable"

    public let schemaVersion: Int
    public let generatedAt: Date
    public let refreshIntervalSeconds: TimeInterval?
    public let accounts: [WatchAccountSnapshot]
    public let isProLocked: Bool
    public let proAccessEndsAt: Date?
    /// Phone-effective calendar time when access was observed; never a phone uptime counter.
    /// At first receipt, deadline minus this floor bounds remaining access. Unknown
    /// transport delay during dual clock rollback cannot be reconstructed from it.
    public let proAccessEffectiveAt: Date?
    public let publicationSequence: UInt64?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        generatedAt: Date,
        refreshIntervalSeconds: TimeInterval?,
        accounts: [WatchAccountSnapshot],
        isProLocked: Bool = false,
        proAccessEndsAt: Date? = nil,
        proAccessEffectiveAt: Date? = nil,
        publicationSequence: UInt64? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.accounts = accounts
        self.isProLocked = isProLocked
        self.proAccessEndsAt = proAccessEndsAt
        self.proAccessEffectiveAt = proAccessEffectiveAt
        self.publicationSequence = publicationSequence
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generatedAt
        case refreshIntervalSeconds
        case accounts
        case isProLocked
        case proAccessEndsAt
        case proAccessEffectiveAt
        case publicationSequence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedAccounts = try container.decodeIfPresent(
            [LossyDecodable<WatchAccountSnapshot>].self,
            forKey: .accounts
        ) ?? []
        self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            generatedAt: try container.decode(Date.self, forKey: .generatedAt),
            refreshIntervalSeconds: try container.decodeIfPresent(
                TimeInterval.self,
                forKey: .refreshIntervalSeconds
            ),
            accounts: decodedAccounts.compactMap(\.value),
            isProLocked: try container.decodeIfPresent(Bool.self, forKey: .isProLocked) ?? true,
            proAccessEndsAt: try container.decodeIfPresent(Date.self, forKey: .proAccessEndsAt),
            proAccessEffectiveAt: try container.decodeIfPresent(Date.self, forKey: .proAccessEffectiveAt),
            publicationSequence: try container.decodeIfPresent(UInt64.self, forKey: .publicationSequence)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encodeIfPresent(refreshIntervalSeconds, forKey: .refreshIntervalSeconds)
        try container.encode(accounts, forKey: .accounts)
        try container.encode(isProLocked, forKey: .isProLocked)
        try container.encodeIfPresent(proAccessEndsAt, forKey: .proAccessEndsAt)
        try container.encodeIfPresent(proAccessEffectiveAt, forKey: .proAccessEffectiveAt)
        try container.encodeIfPresent(publicationSequence, forKey: .publicationSequence)
    }

    public func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> WatchDashboardSnapshot {
        let snapshot = try decoder.decode(Self.self, from: data)
        guard snapshot.schemaVersion == currentSchemaVersion else {
            throw WatchDashboardPayloadError.unsupportedSchemaVersion(snapshot.schemaVersion)
        }
        guard snapshot.publicationSequence.map({ $0 < UInt64.max - 1 }) ?? true else {
            throw WatchDashboardPayloadError.invalidPublicationSequence
        }
        return snapshot
    }

    public static func decodeApplicationContext(
        _ applicationContext: [String: Any]
    ) throws -> WatchDashboardSnapshot {
        try WatchDashboardApplicationContext(applicationContext).decode()
    }

    public func applicationContext() throws -> [String: Any] {
        [
            Self.applicationContextVersionKey: schemaVersion,
            Self.applicationContextDataKey: try encoded(),
        ]
    }

    public static var snapshotRequestMessage: [String: Any] {
        snapshotRequestMessage(after: nil)
    }

    public static func snapshotRequestMessage(after sequence: UInt64?) -> [String: Any] {
        var message: [String: Any] = [snapshotRequestKey: true]
        if let sequence {
            message[snapshotAfterSequenceKey] = NSNumber(value: sequence)
        }
        return message
    }

    public static var snapshotUnavailableReply: [String: Any] {
        [snapshotUnavailableKey: true]
    }

    public static func isSnapshotRequest(_ message: [String: Any]) -> Bool {
        message[snapshotRequestKey] as? Bool == true
    }

    public func semanticData() throws -> Data {
        try Self.encoder.encode(
            Self(
                schemaVersion: schemaVersion,
                generatedAt: .distantPast,
                refreshIntervalSeconds: refreshIntervalSeconds,
                accounts: accounts,
                isProLocked: isProLocked,
                proAccessEndsAt: proAccessEndsAt,
                proAccessEffectiveAt: proAccessEffectiveAt
            )
        )
    }

    public func isLocked(at date: Date) -> Bool {
        isProLocked || proAccessEndsAt.map { date >= $0 } == true
    }

    // Sequence orders publications across phone clock changes. At an equal
    // revision, only a stricter access decision can supersede persisted access.
    public func isNewer(than other: WatchDashboardSnapshot) -> Bool {
        switch (publicationSequence, other.publicationSequence) {
        case let (.some(candidate), .some(current)) where candidate != current:
            return candidate > current
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none) where generatedAt != other.generatedAt:
            return generatedAt > other.generatedAt
        default:
            if isProLocked != other.isProLocked {
                return isProLocked
            }
            if proAccessEndsAt != other.proAccessEndsAt {
                guard let proAccessEndsAt else { return false }
                return other.proAccessEndsAt.map { proAccessEndsAt < $0 } ?? true
            }
            if proAccessEndsAt != nil, proAccessEffectiveAt != other.proAccessEffectiveAt {
                guard let floor = proAccessEffectiveAt, floor.timeIntervalSinceReferenceDate.isFinite else { return false }
                return other.proAccessEffectiveAt.map { floor > $0 } ?? true
            }
            return generatedAt > other.generatedAt
                && schemaVersion == other.schemaVersion
                && refreshIntervalSeconds == other.refreshIntervalSeconds
                && accounts == other.accounts
        }
    }

    public func lockingAccess() -> Self {
        Self(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            refreshIntervalSeconds: refreshIntervalSeconds,
            accounts: accounts,
            isProLocked: true,
            proAccessEndsAt: proAccessEndsAt,
            proAccessEffectiveAt: proAccessEffectiveAt,
            publicationSequence: publicationSequence
        )
    }

    public func isStale(at date: Date) -> Bool {
        isStale(dataDate: generatedAt, at: date)
    }

    public func isStale(dataDate: Date, at date: Date) -> Bool {
        let refreshWindow = refreshIntervalSeconds.map { max($0 * 2, 15 * 60) } ?? 60 * 60
        return date.timeIntervalSince(dataDate) > refreshWindow
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}

private struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
