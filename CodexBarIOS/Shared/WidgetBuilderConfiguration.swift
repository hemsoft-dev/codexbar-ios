import Foundation

public enum CodexBarWidgetBuilderLayout: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case oneTile
    case twoTiles
    case fourTiles

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .automatic:
            "Auto"
        case .oneTile:
            "1"
        case .twoTiles:
            "2"
        case .fourTiles:
            "4"
        }
    }

    public func tileCount(maximum: Int, automaticCount: Int) -> Int {
        switch self {
        case .automatic:
            min(maximum, automaticCount)
        case .oneTile:
            min(maximum, 1)
        case .twoTiles:
            min(maximum, 2)
        case .fourTiles:
            min(maximum, 4)
        }
    }

    public var previewTileCount: Int {
        switch self {
        case .automatic:
            4
        case .oneTile:
            1
        case .twoTiles:
            2
        case .fourTiles:
            4
        }
    }
}

public enum CodexBarWidgetBuilderDisplayMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case compactPercent
    case fullBar
    case balanceOnly
    case urgentStatus

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .automatic:
            "Automatic"
        case .compactPercent:
            "Compact Percent"
        case .fullBar:
            "Full Bar"
        case .balanceOnly:
            "Balance Only"
        case .urgentStatus:
            "Urgent Status"
        }
    }
}

public struct CodexBarWidgetBuilderConfiguration: Codable, Equatable, Sendable {
    public static let maximumSlots = 4
    public static let `default` = CodexBarWidgetBuilderConfiguration()

    public var layout: CodexBarWidgetBuilderLayout
    public var selectedTileIDs: [String?]
    public var displayModes: [CodexBarWidgetBuilderDisplayMode]

    public init(
        layout: CodexBarWidgetBuilderLayout = .automatic,
        selectedTileIDs: [String?] = [],
        displayModes: [CodexBarWidgetBuilderDisplayMode] = []
    ) {
        self.layout = layout
        self.selectedTileIDs = Array(selectedTileIDs.prefix(Self.maximumSlots))
        self.displayModes = Array(displayModes.prefix(Self.maximumSlots))
    }

    public var hasSelectedTiles: Bool {
        selectedTileIDs.contains { $0 != nil }
    }

    public var hasCustomizations: Bool {
        layout != .automatic
            || hasSelectedTiles
            || displayModes.contains { $0 != .automatic }
    }

    public func tileID(at index: Int) -> String? {
        selectedTileIDs.indices.contains(index) ? selectedTileIDs[index] : nil
    }

    public func displayMode(at index: Int) -> CodexBarWidgetBuilderDisplayMode {
        displayModes.indices.contains(index) ? displayModes[index] : .automatic
    }

    public mutating func setTileID(_ tileID: String?, at index: Int) {
        guard index >= 0, index < Self.maximumSlots else {
            return
        }

        growSelectedTiles(toInclude: index)
        selectedTileIDs[index] = tileID
        trimTrailingEmptySlots()
    }

    public mutating func setDisplayMode(_ displayMode: CodexBarWidgetBuilderDisplayMode, at index: Int) {
        guard index >= 0, index < Self.maximumSlots else {
            return
        }

        while displayModes.count <= index {
            displayModes.append(.automatic)
        }
        displayModes[index] = displayMode
        trimTrailingAutomaticModes()
    }

    private mutating func growSelectedTiles(toInclude index: Int) {
        while selectedTileIDs.count <= index {
            selectedTileIDs.append(nil)
        }
    }

    private mutating func trimTrailingEmptySlots() {
        while selectedTileIDs.last == .some(nil) {
            selectedTileIDs.removeLast()
        }
    }

    private mutating func trimTrailingAutomaticModes() {
        while displayModes.last == .automatic {
            displayModes.removeLast()
        }
    }
}

public struct CodexBarWidgetBuilderTile: Equatable, Identifiable, Sendable {
    public let id: String
    public let providerID: String
    public let providerTitle: String
    public let title: String
    public let subtitle: String
    public let value: String
    public let fractionUsed: Double?
    public let creditsRemaining: Double?
    public let severity: CodexBarWidgetSeverity

    public static func unavailable(id: String) -> CodexBarWidgetBuilderTile {
        CodexBarWidgetBuilderTile(
            id: id,
            providerID: "unavailable",
            providerTitle: "Saved Tile",
            title: "Saved Tile",
            subtitle: "Open CodexBar to refresh this tile.",
            value: "--",
            fractionUsed: nil,
            creditsRemaining: nil,
            severity: .warning
        )
    }
}

public extension CodexBarWidgetSnapshot {
    var builderTiles: [CodexBarWidgetBuilderTile] {
        results.flatMap { provider in
            [provider.builderSummaryTile]
                + provider.bars.map { provider.builderBarTile($0) }
                + provider.standaloneMonetaryMetrics.map { provider.builderMonetaryTile($0) }
        }
    }

    func builderTile(resolvingSavedID tileID: String, fallbackToFirstAvailable: Bool = false) -> CodexBarWidgetBuilderTile? {
        if let exactMatch = builderTiles.first(where: { $0.id == tileID }) {
            return exactMatch
        }

        if let linked = results.first(where: { provider in
            (provider.legacyAccountIDs ?? []).contains { tileID == "provider.\($0)" }
        }) { return linked.builderSummaryTile }

        for provider in results.sorted(by: { $0.accountID.count > $1.accountID.count }) {
            let identityMatches = provider.bars.filter {
                $0.matchesSavedBuilderTileID(tileID, accountID: provider.accountID, legacyAccountIDs: provider.legacyAccountIDs ?? [])
            }
            if identityMatches.count == 1, let identityMatch = identityMatches.first {
                return provider.builderBarTile(identityMatch)
            }
            if let indexedBar = provider.bars.enumerated().first(where: {
                $0.element.matchesSavedBuilderTileID(
                    tileID,
                    accountID: provider.accountID,
                    legacyAccountIDs: provider.legacyAccountIDs ?? [],
                    currentIndex: $0.offset
                )
            }) {
                return provider.builderBarTile(indexedBar.element)
            }
        }

        return fallbackToFirstAvailable ? builderTiles.first : nil
    }
}

public extension CodexBarWidgetUsageBarSnapshot {
    func matchesSavedBuilderTileID(
        _ tileID: String,
        accountID: String,
        legacyAccountIDs: [String] = [],
        currentIndex: Int? = nil
    ) -> Bool {
        let savedBarID = tileID.hasPrefix("bar.")
            ? String(tileID.dropFirst("bar.".count))
            : tileID
        let matchesLegacyAccount = legacyAccountIDs.contains { savedBarID.hasPrefix("\($0).") }
        if matchesLegacyAccount { return false }
        if savedBarID == id
            || savedBarID == "\(accountID).\(id)" {
            return true
        }

        guard
            let savedIdentity = ([accountID] + legacyAccountIDs).compactMap({ Self.identity(in: savedBarID, accountID: $0) }).first,
            let currentIdentity = Self.identity(in: id, accountID: accountID)
        else {
            return false
        }
        if let savedIndex = savedIdentity.legacyIndex {
            if currentIndex == nil {
                let canonicalSavedSuffix = Self.canonicalIdentitySuffix(savedIdentity.suffix)
                return canonicalSavedSuffix == Self.canonicalIdentitySuffix(currentIdentity.suffix)
                    || canonicalSavedSuffix == Self.canonicalIdentitySuffix(
                        Self.normalizedBarLabel(label)
                    )
            }
            guard !ClaudeFableUsageIdentity.requiresWidgetIdentityMatch(savedIdentity.suffix) else { return false }
            return !matchesLegacyAccount && savedIndex == currentIndex
        }
        return Self.canonicalIdentitySuffix(savedIdentity.suffix)
            == Self.canonicalIdentitySuffix(currentIdentity.suffix)
    }

    private static func identity(
        in barID: String,
        accountID: String
    ) -> (suffix: String, legacyIndex: Int?)? {
        let accountPrefix = "\(accountID)."
        guard barID.hasPrefix(accountPrefix) else {
            return nil
        }

        let accountSuffix = String(barID.dropFirst(accountPrefix.count))
        let components = accountSuffix.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        if components.count == 2, let legacyIndex = Int(components[0]) {
            return (String(components[1]), legacyIndex)
        }
        return (accountSuffix, nil)
    }

    private static func canonicalIdentitySuffix(_ suffix: String) -> String {
        let suffix = switch suffix {
        case CursorUsageIdentity.legacyCursorModelsStableKey:
            CursorUsageIdentity.cursorModelsMetricID
        case CursorUsageIdentity.legacyOtherModelsStableKey:
            CursorUsageIdentity.otherModelsMetricID
        default:
            CursorUsageIdentity.canonicalMetricID(suffix)
        }
        if suffix == GreptileUsageIdentity.completedReviewsMetricID
            || suffix == GreptileUsageIdentity.reviewQuotaMetricID {
            return GreptileUsageIdentity.canonicalReviewUsageMetricID
        }
        let fableSuffix = ClaudeFableUsageIdentity.canonicalWidgetSuffix(suffix)
        if fableSuffix != suffix { return fableSuffix }
        let oldScopedWeeklySuffix = "-weekly-limit"
        guard suffix.hasSuffix(oldScopedWeeklySuffix) else {
            return suffix
        }
        return String(suffix.dropLast(oldScopedWeeklySuffix.count)) + "-weekly-usage-limit"
    }

    private static func normalizedBarLabel(_ label: String) -> String {
        label
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}

private extension CodexBarWidgetProviderSnapshot {
    var builderSummaryTile: CodexBarWidgetBuilderTile {
        let bar = representativeBar
        let monetaryMetric = summaryMonetaryMetric
        return CodexBarWidgetBuilderTile(
            id: "provider.\(accountID)",
            providerID: providerID,
            providerTitle: title,
            title: monetaryMetric?.label ?? (creditsRemaining == nil ? title : "\(title) Balance"),
            subtitle: monetaryMetric?.detail ?? groupName ?? subtitle,
            value: creditsRemaining.map(Self.formattedCurrency)
                ?? bar?.usageText
                ?? monetaryMetric?.formattedAmount
                ?? "No data",
            fractionUsed: bar?.effectiveFractionUsed,
            creditsRemaining: creditsRemaining,
            severity: severity
        )
    }

    private var representativeBar: CodexBarWidgetUsageBarSnapshot? {
        bars.max { lhs, rhs in
            if lhs.effectiveSeverity == rhs.effectiveSeverity {
                return lhs.effectiveFractionUsed < rhs.effectiveFractionUsed
            }

            return lhs.effectiveSeverity < rhs.effectiveSeverity
        }
    }

    func builderBarTile(_ bar: CodexBarWidgetUsageBarSnapshot) -> CodexBarWidgetBuilderTile {
        CodexBarWidgetBuilderTile(
            id: "bar.\(bar.id)",
            providerID: providerID,
            providerTitle: title,
            title: bar.label,
            subtitle: groupName ?? subtitle,
            value: bar.usageText,
            fractionUsed: bar.effectiveFractionUsed,
            creditsRemaining: nil,
            severity: bar.effectiveSeverity
        )
    }

    func builderMonetaryTile(_ metric: CodexBarWidgetMonetaryMetricSnapshot) -> CodexBarWidgetBuilderTile {
        CodexBarWidgetBuilderTile(
            id: "money.\(accountID).\(metric.id)",
            providerID: providerID,
            providerTitle: title,
            title: metric.label,
            subtitle: metric.detail ?? groupName ?? subtitle,
            value: metric.formattedAmount,
            fractionUsed: nil,
            creditsRemaining: nil,
            severity: severity
        )
    }

    private static func formattedCurrency(_ amount: Double) -> String {
        CodexBarCurrencyText.format(amount)
    }
}

/// Compatibility with provider identifiers saved by versions before Google support was withdrawn.
public enum RetiredGoogleProviderMigration {
    public static func isRetiredIdentifier(_ value: String) -> Bool {
        value.split(separator: ".").contains { $0 == "gemini" || $0 == "antigravity" }
    }

    /// Filter before decoding ProviderID so one retired record cannot invalidate other accounts or history.
    public static func removingRetiredRecords(from data: Data) throws -> Data {
        guard let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return data
        }
        let retained = records.filter { record in
            guard let provider = record["providerID"] as? String else { return true }
            return !["gemini", "antigravity"].contains(provider)
        }
        guard retained.count != records.count else { return data }
        return try JSONSerialization.data(withJSONObject: retained, options: [.sortedKeys])
    }
}
