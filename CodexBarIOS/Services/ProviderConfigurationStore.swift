import Combine
import CryptoKit
import Foundation

public struct MetricCustomizationPreference: Codable, Equatable, Sendable {
    public var visualizationStyle: MetricVisualizationStyle?
    public var isVisible: Bool

    public init(
        visualizationStyle: MetricVisualizationStyle? = nil,
        isVisible: Bool = true
    ) {
        self.visualizationStyle = visualizationStyle
        self.isVisible = isVisible
    }

    private enum CodingKeys: String, CodingKey {
        case visualizationStyle
        case isVisible
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        visualizationStyle = try container.decodeIfPresent(
            MetricVisualizationStyle.self,
            forKey: .visualizationStyle
        )
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
    }
}

public enum MetricTileWidthPreference: String, CaseIterable, Codable, Equatable, Sendable {
    case automatic
    case half
    case full

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = (try? container.decode(String.self))
            .flatMap(Self.init(rawValue:))
            ?? .automatic
    }
}

public enum WatchMetricVisibilityPolicy: String, CaseIterable, Codable, Equatable, Sendable {
    case inherit
    case show
    case hide

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = (try? container.decode(String.self))
            .flatMap(Self.init(rawValue:))
            ?? .inherit
    }

    public func resolves(isVisibleOnIPhone: Bool) -> Bool {
        switch self {
        case .inherit:
            isVisibleOnIPhone
        case .show:
            true
        case .hide:
            false
        }
    }
}

public struct MetricTilePreference: Codable, Equatable, Sendable {
    public var isVisible: Bool
    public var visualizationStyle: MetricVisualizationStyle?
    public var width: MetricTileWidthPreference
    public var watchVisibility: WatchMetricVisibilityPolicy
    public var isNewlyDiscovered: Bool

    public init(
        isVisible: Bool = true,
        visualizationStyle: MetricVisualizationStyle? = nil,
        width: MetricTileWidthPreference = .automatic,
        watchVisibility: WatchMetricVisibilityPolicy = .inherit,
        isNewlyDiscovered: Bool = true
    ) {
        self.isVisible = isVisible
        self.visualizationStyle = visualizationStyle
        self.width = width
        self.watchVisibility = watchVisibility
        self.isNewlyDiscovered = isNewlyDiscovered
    }

    private enum CodingKeys: String, CodingKey {
        case isVisible
        case visualizationStyle
        case width
        case watchVisibility
        case isNewlyDiscovered
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        visualizationStyle = try container.decodeIfPresent(
            MetricVisualizationStyle.self,
            forKey: .visualizationStyle
        )
        width = try container.decodeIfPresent(
            MetricTileWidthPreference.self,
            forKey: .width
        ) ?? .automatic
        watchVisibility = try container.decodeIfPresent(
            WatchMetricVisibilityPolicy.self,
            forKey: .watchVisibility
        ) ?? .inherit
        isNewlyDiscovered = try container.decodeIfPresent(
            Bool.self,
            forKey: .isNewlyDiscovered
        ) ?? false
    }
}

public struct AccountMetricLayout: Codable, Equatable, Sendable {
    public static let currentVersion = 4

    public var version: Int
    public var orderedMetricIDs: [String]
    public var preferences: [String: MetricTilePreference]
    public var usesLegacyFullWidthDefaults: Bool
    public var hasAppliedGitHubActionsMetricGrouping: Bool
    /// Set by an explicit drag/reorder, not by metric discovery or presentation edits.
    public var hasCustomMetricOrder: Bool

    public init(
        version: Int = AccountMetricLayout.currentVersion,
        orderedMetricIDs: [String] = [],
        preferences: [String: MetricTilePreference] = [:],
        usesLegacyFullWidthDefaults: Bool = false,
        hasAppliedGitHubActionsMetricGrouping: Bool = false,
        hasCustomMetricOrder: Bool = false
    ) {
        self.version = version
        self.orderedMetricIDs = orderedMetricIDs
        self.preferences = preferences
        self.usesLegacyFullWidthDefaults = usesLegacyFullWidthDefaults
        self.hasAppliedGitHubActionsMetricGrouping = hasAppliedGitHubActionsMetricGrouping
        self.hasCustomMetricOrder = hasCustomMetricOrder
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case orderedMetricIDs
        case preferences
        case usesLegacyFullWidthDefaults
        case hasAppliedGitHubActionsMetricGrouping
        case hasCustomMetricOrder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The required version is also the discriminator from the legacy
        // account -> metric -> preference dictionary stored under the same key.
        version = try container.decode(Int.self, forKey: .version)
        orderedMetricIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .orderedMetricIDs
        ) ?? []
        preferences = try container.decodeIfPresent(
            [String: MetricTilePreference].self,
            forKey: .preferences
        ) ?? [:]
        usesLegacyFullWidthDefaults = try container.decodeIfPresent(
            Bool.self,
            forKey: .usesLegacyFullWidthDefaults
        ) ?? false
        hasAppliedGitHubActionsMetricGrouping = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasAppliedGitHubActionsMetricGrouping
        ) ?? false
        hasCustomMetricOrder = try container.decodeIfPresent(Bool.self, forKey: .hasCustomMetricOrder) ?? false
    }
}

struct MetricLayoutUndoHistory {
    private(set) var layouts: [AccountMetricLayout] = []

    var canUndo: Bool {
        !layouts.isEmpty
    }

    mutating func record(_ layout: AccountMetricLayout) {
        guard layouts.last != layout else {
            return
        }
        layouts.append(layout)
    }

    @discardableResult
    mutating func record(
        _ layout: AccountMetricLayout,
        ifChangedTo updatedLayout: AccountMetricLayout
    ) -> Bool {
        guard layout != updatedLayout else {
            return false
        }
        record(layout)
        return true
    }

    mutating func undo() -> AccountMetricLayout? {
        layouts.popLast()
    }
}

private enum GreptileMetricPreferenceCompatibility {
    static func matchingMetrics(
        _ sourceMetricIDs: [String],
        destinationAvailableMetricIDs: [String],
        destinationLayout: AccountMetricLayout
    ) -> [(sourceMetricID: String, destinationMetricID: String)] {
        let availableMetricIDs = Set(destinationAvailableMetricIDs)
        let destinationMetricIDs = Set(destinationLayout.orderedMetricIDs)
            .union(destinationLayout.preferences.keys)
        var seenSourceMetricIDs = Set<String>()
        var seenDestinationMetricIDs = Set<String>()
        return sourceMetricIDs.compactMap { sourceMetricID in
            guard
                !sourceMetricID.isEmpty,
                seenSourceMetricIDs.insert(sourceMetricID).inserted,
                let destinationMetricID = matchingDestinationMetricID(
                    for: sourceMetricID,
                    destinationAvailableMetricIDs: availableMetricIDs,
                    destinationMetricIDs: destinationMetricIDs
                ),
                seenDestinationMetricIDs.insert(destinationMetricID).inserted
            else {
                return nil
            }
            return (sourceMetricID, destinationMetricID)
        }
    }

    static func matchingDestinationMetricID(
        for sourceMetricID: String,
        destinationAvailableMetricIDs: Set<String>,
        destinationMetricIDs: Set<String>
    ) -> String? {
        matchingDestinationMetricID(
            for: sourceMetricID,
            destinationMetricIDs: destinationAvailableMetricIDs
        ) ?? matchingDestinationMetricID(
            for: sourceMetricID,
            destinationMetricIDs: destinationMetricIDs
        )
    }

    private static func matchingDestinationMetricID(
        for sourceMetricID: String,
        destinationMetricIDs: Set<String>
    ) -> String? {
        if destinationMetricIDs.contains(sourceMetricID) {
            return sourceMetricID
        }
        if sourceMetricID == GreptileUsageIdentity.completedReviewsMetricID,
           destinationMetricIDs.contains(GreptileUsageIdentity.reviewQuotaMetricID) {
            return GreptileUsageIdentity.reviewQuotaMetricID
        }
        if sourceMetricID == GreptileUsageIdentity.reviewQuotaMetricID,
           destinationMetricIDs.contains(GreptileUsageIdentity.completedReviewsMetricID) {
            return GreptileUsageIdentity.completedReviewsMetricID
        }
        return nil
    }

    static func migrate(
        layout: inout AccountMetricLayout,
        availableMetricIDs: [String]
    ) {
        let availableMetricIDSet = Set(availableMetricIDs)
        let sourceMetricID: String
        let destinationMetricID: String
        if availableMetricIDSet.contains(GreptileUsageIdentity.reviewQuotaMetricID),
           !availableMetricIDSet.contains(GreptileUsageIdentity.completedReviewsMetricID) {
            sourceMetricID = GreptileUsageIdentity.completedReviewsMetricID
            destinationMetricID = GreptileUsageIdentity.reviewQuotaMetricID
        } else if availableMetricIDSet.contains(GreptileUsageIdentity.completedReviewsMetricID),
                  !availableMetricIDSet.contains(GreptileUsageIdentity.reviewQuotaMetricID) {
            sourceMetricID = GreptileUsageIdentity.reviewQuotaMetricID
            destinationMetricID = GreptileUsageIdentity.completedReviewsMetricID
        } else {
            return
        }

        let destinationPreference = layout.preferences[destinationMetricID]
        if !hasCustomPresentation(destinationPreference),
           var sourcePreference = layout.preferences.removeValue(forKey: sourceMetricID) {
            if let destinationPreference {
                sourcePreference.isNewlyDiscovered = sourcePreference.isNewlyDiscovered
                    && destinationPreference.isNewlyDiscovered
            }
            layout.preferences[destinationMetricID] = sourcePreference
        }
        var seenMetricIDs = Set<String>()
        layout.orderedMetricIDs = layout.orderedMetricIDs
            .map { $0 == sourceMetricID ? destinationMetricID : $0 }
            .filter { !$0.isEmpty && seenMetricIDs.insert($0).inserted }
    }

    private static func hasCustomPresentation(_ preference: MetricTilePreference?) -> Bool {
        guard let preference else { return false }
        return !preference.isVisible
            || preference.visualizationStyle != nil
            || preference.width != .automatic
            || preference.watchVisibility != .inherit
    }
}

private enum CursorMetricPreferenceCompatibility {
    private static let replacements = [
        (
            CursorUsageIdentity.legacyCursorModelsMetricID,
            CursorUsageIdentity.cursorModelsMetricID
        ),
        (
            CursorUsageIdentity.legacyOtherModelsMetricID,
            CursorUsageIdentity.otherModelsMetricID
        ),
    ]

    static func migrate(
        layout: inout AccountMetricLayout,
        availableMetricIDs: [String]
    ) {
        let availableMetricIDs = Set(availableMetricIDs)
        for (sourceMetricID, destinationMetricID) in replacements
        where availableMetricIDs.contains(destinationMetricID)
            && !availableMetricIDs.contains(sourceMetricID) {
            let destinationPreference = layout.preferences[destinationMetricID]
            if !hasCustomPresentation(destinationPreference),
               var sourcePreference = layout.preferences.removeValue(forKey: sourceMetricID) {
                if let destinationPreference {
                    sourcePreference.isNewlyDiscovered = sourcePreference.isNewlyDiscovered
                        && destinationPreference.isNewlyDiscovered
                }
                layout.preferences[destinationMetricID] = sourcePreference
            }
            layout.orderedMetricIDs = layout.orderedMetricIDs.map {
                $0 == sourceMetricID ? destinationMetricID : $0
            }
        }

        layout.preferences.removeValue(forKey: CursorUsageIdentity.legacyTotalMetricID)
        layout.orderedMetricIDs.removeAll {
            $0 == CursorUsageIdentity.legacyTotalMetricID
        }
        var seenMetricIDs = Set<String>()
        layout.orderedMetricIDs = layout.orderedMetricIDs.filter {
            !$0.isEmpty && seenMetricIDs.insert($0).inserted
        }
    }

    private static func hasCustomPresentation(_ preference: MetricTilePreference?) -> Bool {
        guard let preference else { return false }
        return !preference.isVisible
            || preference.visualizationStyle != nil
            || preference.width != .automatic
            || preference.watchVisibility != .inherit
    }
}

private enum GitHubBillingMetricPreferenceCompatibility {
    private static let actionsMinutesID = "githubBilling.actions-allowance-minutes"
    private static let actionsStorageID = "githubBilling.actions-storage"

    static func groupActionsMetrics(
        layout: inout AccountMetricLayout,
        availableMetricIDs: [String]
    ) {
        guard !layout.hasAppliedGitHubActionsMetricGrouping else {
            return
        }
        let availableMetricIDs = Set(availableMetricIDs)
        guard
            availableMetricIDs.contains(actionsMinutesID),
            availableMetricIDs.contains(actionsStorageID),
            let minutesIndex = layout.orderedMetricIDs.firstIndex(of: actionsMinutesID),
            let storageIndex = layout.orderedMetricIDs.firstIndex(of: actionsStorageID)
        else {
            return
        }

        let insertionIndex = min(minutesIndex, storageIndex)
        layout.orderedMetricIDs.removeAll {
            $0 == actionsMinutesID || $0 == actionsStorageID
        }
        layout.orderedMetricIDs.insert(
            contentsOf: [actionsMinutesID, actionsStorageID],
            at: min(insertionIndex, layout.orderedMetricIDs.endIndex)
        )
        layout.hasAppliedGitHubActionsMetricGrouping = true
    }
}

private enum GrokMetricPreferenceCompatibility {
    private static let weeklyID = "grok.included-usage"
    private static let creditsID = "grok.monetary.balance.usd"

    static func groupWeeklyBeforeCredits(
        layout: inout AccountMetricLayout,
        availableMetricIDs: [String]
    ) {
        guard !layout.hasCustomMetricOrder,
              availableMetricIDs.contains(weeklyID),
              availableMetricIDs.contains(creditsID),
              let weeklyIndex = layout.orderedMetricIDs.firstIndex(of: weeklyID),
              let creditsIndex = layout.orderedMetricIDs.firstIndex(of: creditsID),
              creditsIndex < weeklyIndex else { return }
        layout.orderedMetricIDs.remove(at: weeklyIndex)
        layout.orderedMetricIDs.insert(weeklyID, at: creditsIndex)
    }
}

private enum MetricPreferenceCompatibility {
    static func migrate(
        layout: inout AccountMetricLayout,
        availableMetricIDs: [String]
    ) {
        GreptileMetricPreferenceCompatibility.migrate(
            layout: &layout,
            availableMetricIDs: availableMetricIDs
        )
        CursorMetricPreferenceCompatibility.migrate(
            layout: &layout,
            availableMetricIDs: availableMetricIDs
        )
        ClaudeFableMetricPreferenceCompatibility.migrate(
            layout: &layout,
            availableMetricIDs: availableMetricIDs
        )
    }

    static func migrateOrder(
        layout: inout AccountMetricLayout,
        availableMetricIDs: [String]
    ) {
        GitHubBillingMetricPreferenceCompatibility.groupActionsMetrics(
            layout: &layout,
            availableMetricIDs: availableMetricIDs
        )
        GrokMetricPreferenceCompatibility.groupWeeklyBeforeCredits(
            layout: &layout,
            availableMetricIDs: availableMetricIDs
        )
    }
}

enum CodexAccountIdentityValidation: Equatable {
    case available
    case duplicate(accountName: String)
    case unableToVerify
}

@MainActor
public final class ProviderConfigurationStore: ObservableObject {
    let credentialChanges = PassthroughSubject<String, Never>()
    let cursorHistoryInvalidations = PassthroughSubject<String, Never>()
    let cursorSameIdentityReconnects = PassthroughSubject<String, Never>()
    let grokHistoryInvalidations = PassthroughSubject<String, Never>()
    let greptileCredentialUpdates = PassthroughSubject<(accountID: String, identityChanged: Bool), Never>()
    @Published public private(set) var confirmedGoogleAccountLinks: [String: String]
    @Published public private(set) var configurations: [ProviderAccountConfiguration]
    @Published public private(set) var groups: [ProviderAccountGroup]
    @Published public private(set) var secretAvailability: [String: Bool]
    @Published public private(set) var showsSubscriptionRenewals: Bool
    @Published public private(set) var appAppearance: AppAppearance
    @Published public private(set) var autoRefreshInterval: AutoRefreshInterval
    @Published public private(set) var historySamplingInterval: HistorySamplingInterval
    @Published public private(set) var widgetRefreshInterval: WidgetRefreshInterval
    @Published public private(set) var dashboardOrderingMode: DashboardOrderingMode
    @Published public private(set) var dashboardCardOrder: [String]
    @Published public private(set) var collapsedDashboardAccountIDs: Set<String>
    @Published public private(set) var metricLayouts: [String: AccountMetricLayout]
    @Published public private(set) var usageAlertSettings: UsageAlertSettings
    @Published public private(set) var usageAlertActiveIDs: Set<String>
    @Published public private(set) var isConfigurationRecoveryRequired: Bool
    @Published public private(set) var isGroupRecoveryRequired: Bool
    @Published public private(set) var hasIncompleteAccountReset: Bool
    @Published public private(set) var lastError: String?
    @Published public private(set) var accountAccess: AccountPlanAccess
    @Published public var requestedProPresentation = false
    @Published private(set) var requestedProPresentationOrigin: ProPresentationOrigin = .limit

    private let defaults: UserDefaults
    private let secretStore: SecretStore
    private let widgetSnapshotDefaults: UserDefaults?
    private let configurationsKey = DefaultsKey.configurations
    private let groupsKey = DefaultsKey.groups
    private let appAppearanceKey = DefaultsKey.appAppearance
    private let autoRefreshIntervalKey = DefaultsKey.autoRefreshInterval
    private let historySamplingIntervalKey = DefaultsKey.historySamplingInterval
    private let widgetRefreshIntervalKey = DefaultsKey.widgetRefreshInterval
    private let dashboardOrderingModeKey = DefaultsKey.dashboardOrderingMode
    private let dashboardCardOrderKey = DefaultsKey.dashboardCardOrder
    private let collapsedDashboardAccountIDsKey = DefaultsKey.collapsedDashboardAccountIDs
    private let metricCustomizationPreferencesKey = DefaultsKey.metricCustomizationPreferences
    private let usageAlertSettingsKey = DefaultsKey.usageAlertSettings
    private let usageAlertActiveIDsKey = DefaultsKey.usageAlertActiveIDs
    private let incompleteAccountResetKey = DefaultsKey.incompleteAccountReset
    private var secretAvailabilityError: String?
    private var unsupportedMetricLayoutData: [String: Data]
    private var opaqueMetricLayoutData: Data?
    private var accountAccessOrder: [String] = []
    private var explicitActiveAccountChoiceRequested = false

    public init(
        initialPlanAccess: AccountPlanAccess = .unresolved,
        defaults: UserDefaults = .standard,
        secretStore: SecretStore = KeychainService(),
        widgetSnapshotDefaults: UserDefaults? = WidgetSnapshotStore.userDefaults()
    ) {
        let usageAlertSettingsNeedMigration = Self.usageAlertSettingsNeedMigration(
            in: defaults
        )
        let groupLoadResult = Self.loadGroups(from: defaults)
        let configurationLoadResult = Self.loadConfigurations(
            from: defaults,
            validGroupIDs: groupLoadResult.error == nil
                ? Set(groupLoadResult.groups.map(\.id))
                : nil
        )
        let loadedCollapsedDashboardAccountIDs = Self.loadCollapsedDashboardAccountIDs(
            from: defaults
        )
        let collapsedDashboardAccountIDs = configurationLoadResult.error == nil
            ? loadedCollapsedDashboardAccountIDs.intersection(
                Set(configurationLoadResult.configurations.map(\.id))
            )
            : loadedCollapsedDashboardAccountIDs
        self.defaults = defaults
        self.secretStore = secretStore
        self.widgetSnapshotDefaults = widgetSnapshotDefaults
        self.groups = groupLoadResult.groups
        self.confirmedGoogleAccountLinks = defaults.dictionary(forKey: "confirmedGoogleAccountLinks") as? [String: String] ?? [:]
        self.configurations = configurationLoadResult.configurations
        self.secretAvailability = [:]
        self.showsSubscriptionRenewals = defaults.object(forKey: DefaultsKey.showsSubscriptionRenewals) as? Bool ?? true
        self.appAppearance = Self.loadAppAppearance(from: defaults)
        self.autoRefreshInterval = Self.loadAutoRefreshInterval(from: defaults)
        self.historySamplingInterval = Self.loadHistorySamplingInterval(from: defaults)
        self.widgetRefreshInterval = Self.loadWidgetRefreshInterval(
            from: defaults,
            widgetSnapshotDefaults: widgetSnapshotDefaults
        )
        self.dashboardOrderingMode = Self.loadDashboardOrderingMode(from: defaults)
        self.dashboardCardOrder = Self.loadDashboardCardOrder(from: defaults)
        self.collapsedDashboardAccountIDs = collapsedDashboardAccountIDs
        let metricLayoutLoadResult = Self.loadMetricLayouts(from: defaults)
        var loadedMetricLayouts = metricLayoutLoadResult.layouts
        for configuration in configurationLoadResult.configurations
        where loadedMetricLayouts[configuration.id] == nil {
            loadedMetricLayouts[configuration.id] = AccountMetricLayout(
                usesLegacyFullWidthDefaults: !metricLayoutLoadResult.usesVersionedStorage
            )
        }
        self.metricLayouts = loadedMetricLayouts
        self.unsupportedMetricLayoutData = metricLayoutLoadResult.unsupportedLayoutData
        self.opaqueMetricLayoutData = metricLayoutLoadResult.opaqueData
        self.usageAlertSettings = Self.loadUsageAlertSettings(from: defaults)
        self.usageAlertActiveIDs = Self.loadUsageAlertActiveIDs(from: defaults)
        self.isConfigurationRecoveryRequired = configurationLoadResult.error != nil
        self.isGroupRecoveryRequired = groupLoadResult.error != nil
        self.hasIncompleteAccountReset = defaults.bool(forKey: DefaultsKey.incompleteAccountReset)
        self.lastError = configurationLoadResult.error ?? groupLoadResult.error
        self.accountAccess = initialPlanAccess
        if metricLayoutLoadResult.opaqueData == nil,
           metricLayoutLoadResult.needsMigration
            || loadedMetricLayouts.count != metricLayoutLoadResult.layouts.count {
            saveMetricLayouts()
        }
        if collapsedDashboardAccountIDs != loadedCollapsedDashboardAccountIDs {
            saveCollapsedDashboardAccountIDs()
        }
        sortConfigurations()
        if usageAlertSettingsNeedMigration {
            saveUsageAlertSettings()
        }
        migrateGoogleSetupLayouts()
        resumePendingGoogleLinks()
        refreshSecretAvailability()
        applyPlanAccess(hasProAccess: initialPlanAccess.hasProAccess, isResolved: initialPlanAccess.isResolved)
    }

    public var isPersistenceRecoveryRequired: Bool {
        isConfigurationRecoveryRequired || isGroupRecoveryRequired
    }

    public var isAccountCreationBlocked: Bool {
        isPersistenceRecoveryRequired || hasIncompleteAccountReset
    }

    public func configuration(for providerID: ProviderID) -> ProviderAccountConfiguration {
        configurations.first { $0.providerID == providerID }
            ?? .defaultConfiguration(for: providerID)
    }

    public func configuration(accountID: String) -> ProviderAccountConfiguration? {
        configurations.first { $0.id == accountID }
    }

    public func configurations(for providerID: ProviderID) -> [ProviderAccountConfiguration] {
        configurations.filter { $0.providerID == providerID }
    }

    public func group(for groupID: String?) -> ProviderAccountGroup? {
        guard let groupID else {
            return nil
        }

        return groups.first { $0.id == groupID }
    }

    public func groupName(for groupID: String?) -> String {
        group(for: groupID)?.name ?? ProviderAccountGroup.ungroupedDisplayName
    }

    public func clearLastError(ifMatching message: String?) {
        guard
            let message,
            lastError == message,
            !isConfigurationRecoveryRequired,
            !isGroupRecoveryRequired
        else {
            return
        }
        lastError = nil
    }

    @discardableResult
    public func addGroup(named name: String) -> ProviderAccountGroup? {
        guard allowConfigurationMutation() else {
            return nil
        }

        let normalizedName = Self.normalizedGroupName(name)
        guard !normalizedName.isEmpty else {
            lastError = "Group names cannot be empty."
            return nil
        }

        guard isGroupNameUnique(normalizedName) else {
            lastError = "Group names must be unique."
            return nil
        }

        let group = ProviderAccountGroup(name: normalizedName)
        groups.append(group)
        sortGroups()
        saveGroups()
        return group
    }

    @discardableResult
    public func updateGroup(_ group: ProviderAccountGroup) -> Bool {
        guard allowConfigurationMutation() else {
            return false
        }

        let normalizedName = Self.normalizedGroupName(group.name)
        guard !normalizedName.isEmpty else {
            lastError = "Group names cannot be empty."
            return false
        }

        guard isGroupNameUnique(normalizedName, excluding: group.id) else {
            lastError = "Group names must be unique."
            return false
        }

        guard let index = groups.firstIndex(where: { $0.id == group.id }) else {
            lastError = "Group no longer exists."
            return false
        }

        groups[index].name = normalizedName
        sortGroups()
        sortConfigurations()
        saveGroups()
        saveConfigurations()
        return true
    }

    public func removeGroup(_ group: ProviderAccountGroup) {
        guard allowConfigurationMutation() else {
            return
        }

        groups.removeAll { $0.id == group.id }
        configurations = configurations.map { configuration in
            var updated = configuration
            if updated.groupID == group.id {
                updated.groupID = nil
            }
            return updated
        }
        sortGroups()
        sortConfigurations()
        saveGroups()
        saveConfigurations()
    }

    @discardableResult
    public func addAccount(for providerID: ProviderID) -> ProviderAccountConfiguration? {
        addAccount(for: providerID, copilotScope: .personal)
    }

    @discardableResult
    public func addAccount(for providerID: ProviderID, copilotScope: CopilotAccountScope) -> ProviderAccountConfiguration? {
        guard allowConfigurationMutation(), allowAccountInsertion(for: providerID) else { return nil }
        var configuration = ProviderAccountConfiguration
            .defaultConfiguration(for: providerID)
            .withNewAccountID()
        if providerID == .copilot {
            configuration.copilotAccountScope = copilotScope
        }
        configuration.accountLabel = suggestedAccountLabel(for: providerID)
        if providerID.usesXAIConsumerAuth { configuration.grokGeneratedLabel = configuration.accountLabel }
        let previousConfigurations = configurations
        configurations.append(configuration)
        sortConfigurations()
        if !saveConfigurations() {
            configurations = previousConfigurations
            return nil
        } else {
            metricLayouts[configuration.id] = AccountMetricLayout()
            migrateGoogleSetupLayouts()
            saveMetricLayouts()
        }
        refreshSecretAvailability()
        return configuration
    }

    @discardableResult
    public func update(_ configuration: ProviderAccountConfiguration) -> Bool {
        guard allowConfigurationMutation() else {
            return false
        }

        var normalized = Self.normalizedConfiguration(
            configuration,
            validGroupIDs: Set(groups.map(\.id))
        )
        if normalized.providerID.usesXAIConsumerAuth, normalized.grokGeneratedLabel != nil,
           normalized.accountLabel != normalized.grokGeneratedLabel {
            normalized.grokGeneratedLabel = nil
        }
        guard isAccountNameUnique(normalized) else {
            lastError = "Account names must be unique."
            return false
        }

        let previousConfigurations = configurations
        let isNewAccount = !configurations.contains { $0.id == normalized.id }
        guard !isNewAccount || allowAccountInsertion(for: normalized.providerID) else { return false }
        if let index = configurations.firstIndex(where: { $0.id == normalized.id }) {
            configurations[index] = normalized
        } else {
            configurations.append(normalized)
        }

        sortConfigurations()
        guard saveConfigurations() else {
            configurations = previousConfigurations
            return false
        }
        if isNewAccount, metricLayouts[normalized.id] == nil {
            metricLayouts[normalized.id] = AccountMetricLayout()
            saveMetricLayouts()
        }
        return true
    }

    @discardableResult
    public func replaceCredential(
        _ credential: String,
        for configuration: ProviderAccountConfiguration
    ) -> Bool {
        guard allowConfigurationMutation() else {
            return false
        }

        let normalized = Self.normalizedConfiguration(
            configuration,
            validGroupIDs: Set(groups.map(\.id))
        )
        guard isAccountNameUnique(normalized) else {
            lastError = "Account names must be unique."
            return false
        }

        var updatedConfigurations = configurations
        let isNewAccount = !configurations.contains { $0.id == normalized.id }
        guard !isNewAccount || allowAccountInsertion(for: normalized.providerID) else { return false }
        if let index = updatedConfigurations.firstIndex(where: { $0.id == normalized.id }) {
            updatedConfigurations[index] = normalized
        } else {
            updatedConfigurations.append(normalized)
        }
        updatedConfigurations = sortedConfigurations(updatedConfigurations)

        do {
            let data = try JSONEncoder().encode(updatedConfigurations)
            let greptileIdentityChanged = try greptileCredentialChangesIdentity(credential, for: normalized)
            try writeAccountSecret(credential, for: normalized)
            if [ProviderID.gemini, .grok, .xSubscription, .claude, .openCodeZen].contains(normalized.providerID) {
                credentialChanges.send(normalized.id)
            }
            defaults.set(data, forKey: configurationsKey)
            configurations = updatedConfigurations
            reconcileAccountAccess()
            if isNewAccount, metricLayouts[normalized.id] == nil {
                metricLayouts[normalized.id] = AccountMetricLayout()
                saveMetricLayouts()
            }
            sendGreptileCredentialUpdate(for: normalized, identityChanged: greptileIdentityChanged)
            lastError = nil
            refreshSecretAvailability()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func removeAccount(_ configuration: ProviderAccountConfiguration) -> Bool {
        removeAccounts([configuration])
    }

    @discardableResult
    public func removeAccounts(_ accounts: [ProviderAccountConfiguration]) -> Bool {
        guard allowConfigurationMutation() else {
            return false
        }

        var removedAnyAccount = false
        var firstDeletionError: String?
        var removedAccountIDs = Set<String>()
        let knownAccountIDs = Set(configurations.map(\.id))

        let linkedIDs = Set(confirmedGoogleAccountLinks.filter { link in accounts.contains { $0.id == link.value } }.keys)
        let accountsToRemove = accounts + configurations.filter { linkedIDs.contains($0.id) }
        for configuration in accountsToRemove {
            if let targetID = confirmedGoogleAccountLinks[configuration.id],
               accounts.contains(where: { $0.id == targetID }), !removedAccountIDs.contains(targetID) { continue }
            do {
                if configuration.providerID == .gemini {
                    try secretStore.deleteSecret(account: Self.geminiCodingKeychainAccount(accountID: configuration.id))
                    credentialChanges.send(configuration.id)
                }
                try writeAccountSecret(nil, for: configuration)
                if [ProviderID.grok, .xSubscription, .claude, .openCodeZen].contains(configuration.providerID) { credentialChanges.send(configuration.id) }
                configurations.removeAll { $0.id == configuration.id }
                removedAccountIDs.insert(configuration.id)
                removedAnyAccount = true
            } catch {
                if firstDeletionError == nil {
                    firstDeletionError = error.localizedDescription
                }
            }
        }

        lastError = nil
        if removedAnyAccount {
            removeGoogleLinks(for: removedAccountIDs)
            sortConfigurations()
            saveConfigurations()
            updateDashboardCardOrder(
                dashboardCardOrder.filter { !removedAccountIDs.contains($0) }
            )
            removeCollapsedDashboardAccountIDs(removedAccountIDs)
            updateUsageAlertActiveIDs(
                UsageAlertEvaluator.activeAlertIDs(
                    usageAlertActiveIDs,
                    belongingTo: Set(configurations.map(\.id)),
                    knownAccountIDs: knownAccountIDs
                )
            )
            for accountID in removedAccountIDs {
                metricLayouts.removeValue(forKey: accountID)
                unsupportedMetricLayoutData.removeValue(forKey: accountID)
            }
            saveMetricLayouts()
            refreshSecretAvailability()
        }
        if let firstDeletionError {
            lastError = firstDeletionError
        }
        return removedAnyAccount
    }

    @discardableResult
    public func replaceCorruptedConfigurations() -> Bool {
        guard isConfigurationRecoveryRequired else {
            return false
        }

        let replacement: [ProviderAccountConfiguration] = []
        do {
            let data = try JSONEncoder().encode(replacement)
            defaults.set(data, forKey: configurationsKey)
            configurations = replacement
            reconcileAccountAccess()
            secretAvailability = [:]
            isConfigurationRecoveryRequired = false
            lastError = isGroupRecoveryRequired ? Self.groupLoadErrorMessage : nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func replaceCorruptedGroups() -> Bool {
        guard isGroupRecoveryRequired else {
            return false
        }

        let replacementGroups: [ProviderAccountGroup] = []
        let replacementConfigurations = configurations.map { configuration in
            var ungrouped = configuration
            ungrouped.groupID = nil
            return ungrouped
        }

        do {
            let groupData = try JSONEncoder().encode(replacementGroups)
            let configurationData = try JSONEncoder().encode(replacementConfigurations)
            defaults.set(groupData, forKey: groupsKey)
            if !isConfigurationRecoveryRequired {
                defaults.set(configurationData, forKey: configurationsKey)
                configurations = replacementConfigurations
                sortConfigurations()
            }
            groups = replacementGroups
            isGroupRecoveryRequired = false
            lastError = isConfigurationRecoveryRequired
                ? Self.configurationLoadErrorMessage
                : nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    public func updateAppAppearance(_ appearance: AppAppearance) {
        appAppearance = appearance
        defaults.set(appearance.rawValue, forKey: appAppearanceKey)
    }

    public func updateAutoRefreshInterval(_ interval: AutoRefreshInterval) {
        autoRefreshInterval = interval
        defaults.set(interval.rawValue, forKey: autoRefreshIntervalKey)
    }

    public func updateHistorySamplingInterval(_ interval: HistorySamplingInterval) {
        historySamplingInterval = interval
        defaults.set(interval.rawValue, forKey: historySamplingIntervalKey)
    }

    public func updateWidgetRefreshInterval(_ interval: WidgetRefreshInterval) {
        widgetRefreshInterval = interval
        defaults.set(interval.rawValue, forKey: widgetRefreshIntervalKey)
        WidgetSnapshotStore.saveRefreshInterval(interval, defaults: widgetSnapshotDefaults)
    }

    public func updateDashboardOrderingMode(_ mode: DashboardOrderingMode) {
        dashboardOrderingMode = mode
        defaults.set(mode.rawValue, forKey: dashboardOrderingModeKey)
    }

    public func updateDashboardCardOrder(_ accountIDs: [String]) {
        var seenAccountIDs = Set<String>()
        dashboardCardOrder = accountIDs.filter { seenAccountIDs.insert($0).inserted }
        defaults.set(dashboardCardOrder, forKey: dashboardCardOrderKey)
        accountAccessOrder = []
        reconcileAccountAccess()
    }

    public func isDashboardCardCollapsed(accountID: String) -> Bool {
        collapsedDashboardAccountIDs.contains(accountID)
    }

    public func updateDashboardCardCollapsed(_ isCollapsed: Bool, accountID: String) {
        let changed: Bool
        if isCollapsed {
            guard configurations.contains(where: { $0.id == accountID }) else {
                return
            }
            changed = collapsedDashboardAccountIDs.insert(accountID).inserted
        } else {
            changed = collapsedDashboardAccountIDs.remove(accountID) != nil
        }
        guard changed else {
            return
        }
        saveCollapsedDashboardAccountIDs()
    }

    public func visualizationStyle(accountID: String, metricID: String) -> MetricVisualizationStyle {
        metricLayouts[accountID]?.preferences[metricID]?.visualizationStyle ?? .linearBar
    }

    public var metricCustomizationPreferences: [String: [String: MetricCustomizationPreference]] {
        metricLayouts.mapValues { layout in
            layout.preferences.mapValues { preference in
                MetricCustomizationPreference(
                    visualizationStyle: preference.visualizationStyle,
                    isVisible: preference.isVisible
                )
            }
        }
    }

    public var metricVisualizationPreferences: [String: [String: MetricVisualizationStyle]] {
        metricLayouts.mapValues { layout in
            layout.preferences.compactMapValues(\.visualizationStyle)
        }
    }

    public func isMetricVisible(accountID: String, metricID: String) -> Bool {
        metricLayouts[accountID]?.preferences[metricID]?.isVisible ?? Self.defaultMetricVisibility(metricID)
    }

    private static func defaultMetricVisibility(_ metricID: String) -> Bool {
        metricID != CodexUsageParser.creditsPoolMetricID
    }

    public func watchVisibilityPolicy(
        accountID: String,
        metricID: String
    ) -> WatchMetricVisibilityPolicy {
        metricLayouts[accountID]?.preferences[metricID]?.watchVisibility ?? .inherit
    }

    public func isMetricVisibleOnWatch(accountID: String, metricID: String) -> Bool {
        watchVisibilityPolicy(accountID: accountID, metricID: metricID).resolves(
            isVisibleOnIPhone: isMetricVisible(accountID: accountID, metricID: metricID)
        )
    }

    public func metricWidth(
        accountID: String,
        metricID: String
    ) -> MetricTileWidthPreference {
        guard let layout = metricLayouts[accountID] else {
            return .automatic
        }
        return layout.preferences[metricID]?.width
            ?? (layout.usesLegacyFullWidthDefaults ? .full : .automatic)
    }

    @discardableResult
    public func reconcileMetricLayout(
        accountID: String,
        availableMetricIDs: [String]
    ) -> AccountMetricLayout {
        guard !accountID.isEmpty else {
            return AccountMetricLayout()
        }
        if opaqueMetricLayoutData != nil || unsupportedMetricLayoutData[accountID] != nil {
            return metricLayouts[accountID] ?? AccountMetricLayout()
        }

        let availableMetricIDs = Self.uniqueNonemptyMetricIDs(availableMetricIDs)
        var layout = metricLayouts[accountID] ?? AccountMetricLayout()
        let originalLayout = layout
        MetricPreferenceCompatibility.migrate(layout: &layout, availableMetricIDs: availableMetricIDs)
        var orderedMetricIDs = Self.uniqueNonemptyMetricIDs(layout.orderedMetricIDs)
        let orderedMetricIDSet = Set(orderedMetricIDs)

        if orderedMetricIDs.isEmpty, !layout.preferences.isEmpty {
            orderedMetricIDs = availableMetricIDs
            let availableMetricIDSet = Set(availableMetricIDs)
            orderedMetricIDs.append(
                contentsOf: layout.preferences.keys
                    .filter { !availableMetricIDSet.contains($0) }
                    .sorted()
            )
        } else {
            orderedMetricIDs.append(
                contentsOf: availableMetricIDs.filter { !orderedMetricIDSet.contains($0) }
            )
        }

        layout.orderedMetricIDs = orderedMetricIDs
        MetricPreferenceCompatibility.migrateOrder(
            layout: &layout,
            availableMetricIDs: availableMetricIDs
        )
        layout.version = AccountMetricLayout.currentVersion
        for metricID in availableMetricIDs where layout.preferences[metricID] == nil {
            layout.preferences[metricID] = MetricTilePreference(
                isVisible: Self.defaultMetricVisibility(metricID),
                width: layout.usesLegacyFullWidthDefaults ? .full : .automatic,
                isNewlyDiscovered: !layout.usesLegacyFullWidthDefaults
            )
        }
        layout.usesLegacyFullWidthDefaults = false

        if layout != originalLayout {
            metricLayouts[accountID] = layout
            saveMetricLayouts()
        }
        return layout
    }

    public func metricOrder(
        accountID: String,
        availableMetricIDs: [String]
    ) -> [String] {
        reconcileMetricLayout(
            accountID: accountID,
            availableMetricIDs: availableMetricIDs
        ).orderedMetricIDs
    }

    public func isMetricNewlyDiscovered(accountID: String, metricID: String) -> Bool {
        metricLayouts[accountID]?.preferences[metricID]?.isNewlyDiscovered == true
    }

    public func isMetricLayoutCustomized(
        accountID: String,
        availableMetricIDs: [String]
    ) -> Bool {
        guard let layout = metricLayouts[accountID] else {
            return false
        }
        let availableMetricIDs = Self.uniqueNonemptyMetricIDs(availableMetricIDs)
        let availableMetricIDSet = Set(availableMetricIDs)
        let storedOrder = Self.uniqueNonemptyMetricIDs(layout.orderedMetricIDs)
        let visibleOrder = storedOrder
            .filter { availableMetricIDSet.contains($0) }
        if visibleOrder != availableMetricIDs {
            return true
        }
        let unavailableOrder = storedOrder.filter { !availableMetricIDSet.contains($0) }
        if storedOrder != availableMetricIDs + unavailableOrder {
            return true
        }
        return layout.preferences.contains { metricID, preference in
            preference.isVisible != Self.defaultMetricVisibility(metricID)
                || preference.visualizationStyle != nil
                || preference.width != .automatic
                || preference.watchVisibility != .inherit
        }
    }

    public func replaceMetricLayout(_ replacement: AccountMetricLayout, accountID: String) {
        guard !accountID.isEmpty else {
            return
        }
        prepareMetricLayoutForEditing(accountID: accountID)
        var replacement = replacement
        replacement.version = AccountMetricLayout.currentVersion
        replacement.orderedMetricIDs = Self.uniqueNonemptyMetricIDs(replacement.orderedMetricIDs)
        replacement.usesLegacyFullWidthDefaults = false
        metricLayouts[accountID] = replacement
        saveMetricLayouts()
    }

    public func resetMetricLayout(accountID: String, availableMetricIDs: [String]) {
        guard !accountID.isEmpty else {
            return
        }
        var metricIDs = Self.uniqueNonemptyMetricIDs(availableMetricIDs)
        var seenMetricIDs = Set(metricIDs)
        metricIDs.append(
            contentsOf: Self.uniqueNonemptyMetricIDs(
                metricLayouts[accountID]?.orderedMetricIDs ?? []
            ).filter { seenMetricIDs.insert($0).inserted }
        )
        let preferences = Dictionary(
            uniqueKeysWithValues: metricIDs.map {
                ($0, MetricTilePreference(isVisible: Self.defaultMetricVisibility($0), isNewlyDiscovered: false))
            }
        )
        replaceMetricLayout(
            AccountMetricLayout(
                orderedMetricIDs: metricIDs,
                preferences: preferences
            ),
            accountID: accountID
        )
    }

    public func copyMetricLayout(
        from sourceAccountID: String,
        to destinationAccountID: String,
        destinationAvailableMetricIDs: [String]
    ) {
        guard
            !sourceAccountID.isEmpty,
            !destinationAccountID.isEmpty,
            sourceAccountID != destinationAccountID,
            let sourceLayout = metricLayouts[sourceAccountID]
        else {
            return
        }

        let destinationMetricIDs = Self.uniqueNonemptyMetricIDs(destinationAvailableMetricIDs)
        guard !destinationMetricIDs.isEmpty else {
            return
        }
        var destinationLayout = reconcileMetricLayout(
            accountID: destinationAccountID,
            availableMetricIDs: destinationMetricIDs
        )
        let copiedMetrics = GreptileMetricPreferenceCompatibility.matchingMetrics(
            sourceLayout.orderedMetricIDs,
            destinationAvailableMetricIDs: destinationMetricIDs,
            destinationLayout: destinationLayout
        )
        var seen = Set(copiedMetrics.map(\.destinationMetricID))
        let destinationOnlyOrder = Self.uniqueNonemptyMetricIDs(destinationLayout.orderedMetricIDs)
            .filter { seen.insert($0).inserted }

        destinationLayout.version = AccountMetricLayout.currentVersion
        destinationLayout.orderedMetricIDs = copiedMetrics.map(\.destinationMetricID) + destinationOnlyOrder
        // Copying an order is an explicit choice, even if the source inherited its order.
        destinationLayout.hasCustomMetricOrder = true
        for metric in copiedMetrics {
            guard var preference = sourceLayout.preferences[metric.sourceMetricID] else {
                continue
            }
            preference.isNewlyDiscovered = false
            destinationLayout.preferences[metric.destinationMetricID] = preference
        }
        for metricID in destinationOnlyOrder where destinationLayout.preferences[metricID] == nil {
            destinationLayout.preferences[metricID] = MetricTilePreference(isVisible: Self.defaultMetricVisibility(metricID))
        }
        replaceMetricLayout(destinationLayout, accountID: destinationAccountID)
    }

    public func updateMetricOrder(_ metricIDs: [String], accountID: String) {
        guard !accountID.isEmpty else {
            return
        }

        let reorderedMetricIDs = Self.uniqueNonemptyMetricIDs(metricIDs)
        guard !reorderedMetricIDs.isEmpty else {
            return
        }

        prepareMetricLayoutForEditing(accountID: accountID)
        var layout = metricLayouts[accountID] ?? AccountMetricLayout()
        let reorderedMetricIDSet = Set(reorderedMetricIDs)
        var replacementIndex = 0
        var mergedOrder = Self.uniqueNonemptyMetricIDs(layout.orderedMetricIDs).map { metricID in
            guard reorderedMetricIDSet.contains(metricID) else {
                return metricID
            }
            defer { replacementIndex += 1 }
            return reorderedMetricIDs[replacementIndex]
        }
        mergedOrder.append(contentsOf: reorderedMetricIDs.dropFirst(replacementIndex))

        layout.version = AccountMetricLayout.currentVersion
        layout.orderedMetricIDs = mergedOrder
        layout.hasCustomMetricOrder = true
        for metricID in reorderedMetricIDs {
            var preference = layout.preferences[metricID] ?? MetricTilePreference(
                isVisible: Self.defaultMetricVisibility(metricID),
                width: layout.usesLegacyFullWidthDefaults ? .full : .automatic,
                isNewlyDiscovered: !layout.usesLegacyFullWidthDefaults
            )
            preference.isNewlyDiscovered = false
            layout.preferences[metricID] = preference
        }
        layout.usesLegacyFullWidthDefaults = false
        metricLayouts[accountID] = layout
        saveMetricLayouts()
    }

    public func updateMetricVisibility(
        _ isVisible: Bool,
        accountID: String,
        metricID: String
    ) {
        guard !accountID.isEmpty, !metricID.isEmpty else {
            return
        }

        var preference = metricPreference(accountID: accountID, metricID: metricID)
        preference.isVisible = isVisible
        preference.isNewlyDiscovered = false
        updateMetricPreference(
            preference,
            accountID: accountID,
            metricID: metricID
        )
    }

    public func updateWatchMetricVisibility(
        _ policy: WatchMetricVisibilityPolicy,
        accountID: String,
        metricID: String
    ) {
        guard !accountID.isEmpty, !metricID.isEmpty else {
            return
        }

        var preference = metricPreference(accountID: accountID, metricID: metricID)
        preference.watchVisibility = policy
        preference.isNewlyDiscovered = false
        updateMetricPreference(
            preference,
            accountID: accountID,
            metricID: metricID
        )
    }

    public func updateVisualizationStyle(
        _ style: MetricVisualizationStyle,
        accountID: String,
        metricID: String
    ) {
        guard !accountID.isEmpty, !metricID.isEmpty else {
            return
        }

        var preference = metricPreference(accountID: accountID, metricID: metricID)
        preference.visualizationStyle = style
        preference.isNewlyDiscovered = false
        updateMetricPreference(
            preference,
            accountID: accountID,
            metricID: metricID
        )
    }

    public func updateMetricWidth(
        _ width: MetricTileWidthPreference,
        accountID: String,
        metricID: String
    ) {
        guard !accountID.isEmpty, !metricID.isEmpty else {
            return
        }

        var preference = metricPreference(accountID: accountID, metricID: metricID)
        preference.width = width
        preference.isNewlyDiscovered = false
        updateMetricPreference(
            preference,
            accountID: accountID,
            metricID: metricID
        )
    }

    public func markMetricsSeen(_ metricIDs: [String], accountID: String) {
        guard
            opaqueMetricLayoutData == nil,
            unsupportedMetricLayoutData[accountID] == nil
        else {
            return
        }
        guard var layout = metricLayouts[accountID] else {
            return
        }

        var changed = false
        for metricID in Self.uniqueNonemptyMetricIDs(metricIDs) {
            guard var preference = layout.preferences[metricID],
                  preference.isNewlyDiscovered
            else {
                continue
            }
            preference.isNewlyDiscovered = false
            layout.preferences[metricID] = preference
            changed = true
        }
        guard changed else {
            return
        }

        metricLayouts[accountID] = layout
        saveMetricLayouts()
    }

    public func applyVisualizationStyle(
        _ style: MetricVisualizationStyle,
        accountID: String,
        metricIDs: [String]
    ) {
        guard !accountID.isEmpty else {
            return
        }

        let uniqueMetricIDs = Self.uniqueNonemptyMetricIDs(metricIDs)
        guard !uniqueMetricIDs.isEmpty else {
            return
        }

        for metricID in uniqueMetricIDs {
            var preference = metricPreference(accountID: accountID, metricID: metricID)
            preference.visualizationStyle = style
            preference.isNewlyDiscovered = false
            setMetricPreference(preference, accountID: accountID, metricID: metricID)
        }
        saveMetricLayouts()
    }

    public func resetVisualizationStyles(accountID: String, metricIDs: [String]) {
        prepareMetricLayoutForEditing(accountID: accountID)
        var layout = metricLayouts[accountID] ?? AccountMetricLayout()

        for metricID in metricIDs {
            guard var preference = layout.preferences[metricID] else {
                continue
            }
            preference.visualizationStyle = nil
            preference.isNewlyDiscovered = false
            layout.preferences[metricID] = preference
        }
        metricLayouts[accountID] = layout
        saveMetricLayouts()
    }

    private func metricPreference(
        accountID: String,
        metricID: String
    ) -> MetricTilePreference {
        if let preference = metricLayouts[accountID]?.preferences[metricID] {
            return preference
        }
        let usesLegacyDefaults = metricLayouts[accountID]?.usesLegacyFullWidthDefaults == true
        return MetricTilePreference(
            isVisible: Self.defaultMetricVisibility(metricID),
            width: usesLegacyDefaults ? .full : .automatic,
            isNewlyDiscovered: !usesLegacyDefaults
        )
    }

    private func setMetricPreference(
        _ preference: MetricTilePreference,
        accountID: String,
        metricID: String
    ) {
        prepareMetricLayoutForEditing(accountID: accountID)
        var layout = metricLayouts[accountID] ?? AccountMetricLayout()
        if !layout.orderedMetricIDs.isEmpty,
           !layout.orderedMetricIDs.contains(metricID) {
            layout.orderedMetricIDs.append(metricID)
        }
        layout.preferences[metricID] = preference
        metricLayouts[accountID] = layout
    }

    private func prepareMetricLayoutForEditing(accountID: String) {
        if opaqueMetricLayoutData != nil {
            opaqueMetricLayoutData = nil
            metricLayouts = [:]
            unsupportedMetricLayoutData = [:]
        }
        guard unsupportedMetricLayoutData.removeValue(forKey: accountID) != nil else {
            return
        }
        // An explicit customization opts this account into the current schema.
        // Passive reconciliation never discards a payload written by a newer app.
        metricLayouts[accountID] = AccountMetricLayout()
    }

    private func updateMetricPreference(
        _ preference: MetricTilePreference,
        accountID: String,
        metricID: String
    ) {
        setMetricPreference(preference, accountID: accountID, metricID: metricID)
        saveMetricLayouts()
    }

    public func updateUsageAlertSettings(_ settings: UsageAlertSettings) {
        let settings = UsageAlertSettings(
            isEnabled: settings.isEnabled,
            warningThreshold: settings.warningThreshold,
            criticalThreshold: settings.criticalThreshold,
            balanceThreshold: settings.balanceThreshold
        )
        let previousSettings = usageAlertSettings
        usageAlertSettings = settings
        saveUsageAlertSettings()

        guard settings != previousSettings else {
            return
        }

        if settings.isEnabled != previousSettings.isEnabled {
            updateUsageAlertActiveIDs([])
            return
        }

        let severityThresholdChanged =
            settings.warningThreshold != previousSettings.warningThreshold
                || settings.criticalThreshold != previousSettings.criticalThreshold
        let retainedActiveIDs = usageAlertActiveIDs.filter { alertID in
            if settings.warningThreshold != previousSettings.warningThreshold,
               alertID.hasPrefix("severity.warning.") {
                return false
            }
            if settings.criticalThreshold != previousSettings.criticalThreshold,
               alertID.hasPrefix("severity.critical.") {
                return false
            }
            if severityThresholdChanged,
               alertID.hasPrefix("severity."),
               !alertID.hasPrefix("severity.warning."),
               !alertID.hasPrefix("severity.critical.") {
                return false
            }
            if severityThresholdChanged, alertID.hasPrefix("usage.") {
                return false
            }
            if settings.balanceThreshold != previousSettings.balanceThreshold,
               alertID.hasPrefix("balance.") {
                return false
            }
            return true
        }
        if retainedActiveIDs != usageAlertActiveIDs {
            updateUsageAlertActiveIDs(retainedActiveIDs)
        }
    }

    public func updateUsageAlertsEnabled(_ isEnabled: Bool) {
        var settings = usageAlertSettings
        settings.isEnabled = isEnabled
        updateUsageAlertSettings(settings)
    }

    public func updateUsageAlertWarningThreshold(_ threshold: Double) {
        var settings = usageAlertSettings
        settings.updateWarningThreshold(threshold)
        updateUsageAlertSettings(settings)
    }

    public func updateUsageAlertCriticalThreshold(_ threshold: Double) {
        var settings = usageAlertSettings
        settings.updateCriticalThreshold(threshold)
        updateUsageAlertSettings(settings)
    }

    public func updateUsageAlertBalanceThreshold(_ threshold: Double) {
        var settings = usageAlertSettings
        settings.balanceThreshold = UsageAlertSettings.normalizedBalanceThreshold(threshold)
        updateUsageAlertSettings(settings)
    }

    public func updateUsageAlertActiveIDs(_ activeIDs: Set<String>) {
        usageAlertActiveIDs = activeIDs
        defaults.set(Array(activeIDs).sorted(), forKey: usageAlertActiveIDsKey)
    }

    @discardableResult
    public func saveSecret(_ secret: String, for providerID: ProviderID) -> Bool {
        saveSecret(secret, for: configuration(for: providerID))
    }

    @discardableResult
    public func saveSecret(_ secret: String, for configuration: ProviderAccountConfiguration) -> Bool {
        guard allowConfigurationMutation() else {
            return false
        }

        do {
            try writeAccountSecret(secret, for: configuration)

            if [ProviderID.gemini, .grok, .xSubscription, .claude, .openCodeZen].contains(configuration.providerID) {
                credentialChanges.send(configuration.id)
            }
            lastError = nil
            refreshSecretAvailability()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func canReconnectOpenCodeSession(_ credential: String, workspaceID: String, accountID: String) -> Bool {
        guard let current = configuration(accountID: accountID), current.providerID == .openCodeZen else { return false }
        do {
            let saved = try secretStore.readSecret(account: Self.keychainAccount(for: current))
            return OpenCodeSessionValidator.canReconnect(
                workspaceID: workspaceID, configuredWorkspace: current.openCodeWorkspaceId,
                credential: credential, savedCredential: saved
            )
        } catch {
            return false
        }
    }

    /// Normalize generated names only after the result's verified subject matches the saved credential.
    /// The generated-label marker prevents a refresh from replacing a user's rename.
    @discardableResult
    func applyVerifiedGrokPlan(_ result: ProviderUsageResult) -> Bool {
        guard result.providerID.usesXAIConsumerAuth, result.failureMessage == nil,
              let current = configuration(accountID: result.accountID), current.providerID == result.providerID,
              let credential = try? GrokCredentialLock.withLock({
                  GrokCredential.parse(try secretStore.readSecret(account: Self.keychainAccount(for: current)))
              }),
              Data(SHA256.hash(data: Data(credential.subject.utf8))).base64EncodedString() == result.cacheIdentity,
              let generated = current.grokGeneratedLabel, current.accountLabel == generated else { return false }
        var candidate = current
        var suffix = 1
        let base = current.providerID.displayName
        repeat {
            candidate.accountLabel = suffix == 1 ? base : "\(base) \(suffix)"
            suffix += 1
        } while !isAccountNameUnique(candidate)
        // A neutral generated name is stable even when an earlier number becomes free.
        let generatedNumber = Int(generated.dropFirst(base.count + 1)) ?? 0
        guard candidate.accountLabel != current.accountLabel, generated != base,
              !(generated.hasPrefix("\(base) ") && generatedNumber >= 2) else { return true }
        candidate.grokGeneratedLabel = candidate.accountLabel
        return update(candidate)
    }

    func canReconnectGrok(_ candidate: GrokCredential, accountID: String) -> Bool {
        guard let current = configuration(accountID: accountID), current.providerID.usesXAIConsumerAuth else { return false }
        do {
            let stored = try secretStore.readSecret(account: Self.keychainAccount(for: current))
            guard let stored else { return true }
            return GrokCredential.parse(stored)?.subject == candidate.subject
        } catch {
            return false
        }
    }

    public func hasSecret(for providerID: ProviderID) -> Bool {
        hasSecret(for: configuration(for: providerID))
    }

    public func hasSecret(for configuration: ProviderAccountConfiguration) -> Bool {
        secretAvailability[configuration.id] ?? false
    }

    func validateCodexAccountIdentity(
        _ accountID: String?,
        for configuration: ProviderAccountConfiguration
    ) -> CodexAccountIdentityValidation {
        guard configuration.providerID == .codex else {
            return .unableToVerify
        }

        let otherConfigurations = configurations(for: .codex).filter { $0.id != configuration.id }
        guard !otherConfigurations.isEmpty else {
            return .available
        }

        guard
            let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !accountID.isEmpty
        else {
            return .unableToVerify
        }

        for existing in otherConfigurations {
            do {
                guard let secret = try secretStore.readSecret(account: keychainAccount(for: existing)) else {
                    continue
                }
                guard
                    let existingAccountID = CodexCredentialsParser.parse(secret)?
                        .accountID?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    !existingAccountID.isEmpty
                else {
                    return .unableToVerify
                }

                if existingAccountID == accountID {
                    return .duplicate(accountName: existing.displayName)
                }
            } catch {
                lastError = "Could not verify the saved ChatGPT accounts: \(error.localizedDescription)"
                return .unableToVerify
            }
        }

        return .available
    }

    public func isConfigured(_ providerID: ProviderID) -> Bool {
        configurations(for: providerID).contains { isConfigured($0) }
    }

    public func isConfigured(_ configuration: ProviderAccountConfiguration) -> Bool {
        guard configurations.contains(where: { $0.id == configuration.id }) else {
            return false
        }

        return isConfigurationReady(configuration)
    }

    public func shouldDisplayOnDashboard(_ configuration: ProviderAccountConfiguration) -> Bool {
        guard configuration.providerID != .antigravity,
              configuration.isEnabled, configurations.contains(where: { $0.id == configuration.id }) else {
            return false
        }

        if isConfigurationReady(configuration) {
            return true
        }

        if configuration.providerID == .openCodeZen {
            return hasSecret(for: configuration)
                || !configuration.openCodeWorkspaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if configuration.providerID == .claude {
            return true
        }

        return false
    }

    private func isConfigurationReady(_ configuration: ProviderAccountConfiguration) -> Bool {
        guard configuration.isEnabled else {
            return false
        }

        if configuration.providerID == .gemini {
            return hasSecret(for: configuration) || hasGeminiCodingSecret(for: configuration)
        }

        if configuration.providerID == .copilot {
            let organization = configuration.githubOrganization.trimmingCharacters(in: .whitespacesAndNewlines)
            return hasSecret(for: configuration)
                && (configuration.copilotAccountScope == .personal || !organization.isEmpty)
        }

        if configuration.providerID == .githubBilling {
            return hasSecret(for: configuration)
                && !configuration.githubBillingOwner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if configuration.providerID == .openCodeZen {
            return hasSecret(for: configuration)
                && !configuration.openCodeWorkspaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if configuration.requiresSecret
            || [.codex, .claude, .cursor, .gemini, .grok, .xSubscription, .greptile].contains(configuration.providerID) {
            return hasSecret(for: configuration)
        }

        return !configuration.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func statusText(for providerID: ProviderID) -> String {
        let configuration = configuration(for: providerID)
        return statusText(for: configuration)
    }

    @discardableResult
    public func connectCursorAccount(
        _ configuration: ProviderAccountConfiguration,
        credential: String
    ) -> ProviderAccountConfiguration? {
        guard allowConfigurationMutation() else {
            return nil
        }

        guard configuration.providerID == .cursor else {
            lastError = "Only Cursor accounts can be connected here."
            return nil
        }

        var connectedConfiguration = configuration
        connectedConfiguration.accountLabel = cursorAccountLabelAfterIdentityChange(for: configuration)
        connectedConfiguration.authMethod = .browserSession
        guard isAccountNameUnique(connectedConfiguration) else {
            lastError = "Account names must be unique."
            return nil
        }
        guard configurations.contains(where: { $0.id == configuration.id })
            || allowAccountInsertion(for: configuration.providerID) else { return nil }

        let identityChanged: Bool
        do {
            let previous = try secretStore.readSecret(account: keychainAccount(for: configuration))
            identityChanged = Self.cursorIdentityChanged(previous: previous, replacement: credential)
            try secretStore.saveSecret(credential, account: keychainAccount(for: configuration))
        } catch {
            lastError = error.localizedDescription
            return nil
        }

        guard update(connectedConfiguration) else {
            refreshSecretAvailability()
            return nil
        }
        if identityChanged {
            cursorHistoryInvalidations.send(configuration.id)
            credentialChanges.send(configuration.id)
        } else {
            cursorSameIdentityReconnects.send(configuration.id)
        }
        lastError = nil
        refreshSecretAvailability()
        return connectedConfiguration
    }

    @discardableResult
    public func disconnectCursorAccount(
        _ configuration: ProviderAccountConfiguration
    ) -> ProviderAccountConfiguration? {
        guard allowConfigurationMutation() else {
            return nil
        }

        guard configuration.providerID == .cursor else {
            lastError = "Only Cursor accounts can be disconnected here."
            return nil
        }
        guard configurations.contains(where: { $0.id == configuration.id })
            || allowAccountInsertion(for: configuration.providerID) else { return nil }

        do {
            try secretStore.deleteSecret(account: keychainAccount(for: configuration))
        } catch {
            lastError = error.localizedDescription
            return nil
        }

        var disconnectedConfiguration = configuration
        disconnectedConfiguration.accountLabel = cursorAccountLabelAfterIdentityChange(for: configuration)
        guard update(disconnectedConfiguration) else {
            refreshSecretAvailability()
            return nil
        }

        cursorHistoryInvalidations.send(configuration.id)
        credentialChanges.send(configuration.id)
        lastError = nil
        refreshSecretAvailability()
        return disconnectedConfiguration
    }

    public func statusText(for configuration: ProviderAccountConfiguration) -> String {
        if !configuration.isEnabled {
            return "Disabled"
        }

        if isConfigurationReady(configuration) {
            let label = configuration.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if [.codex, .copilot, .githubBilling, .claude, .cursor, .gemini].contains(configuration.providerID) {
                return label.isEmpty ? "Configured - live usage enabled" : "\(label) - live usage enabled"
            }

            return label.isEmpty ? "Configured" : label
        }

        if configuration.providerID == .codex {
            return "Not configured - sign in with ChatGPT"
        }

        if configuration.providerID == .copilot {
            if configuration.copilotAccountScope == .organization
                && configuration.githubOrganization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Not configured - enter organization"
            }

            return "Not configured - sign in with GitHub"
        }

        if configuration.providerID == .githubBilling {
            return "Not configured - sign in with GitHub for billing access"
        }

        if configuration.providerID == .claude {
            return "Not configured - sign in with Claude"
        }

        if [.cursor, .gemini, .greptile].contains(configuration.providerID) {
            if configuration.providerID == .greptile { return "Not configured - sign in to Greptile" }
            return configuration.providerID == .gemini
                ? "Not configured - sign in with Google" : "Not configured - sign in with Cursor"
        }

        if configuration.providerID == .openCodeZen {
            if configuration.openCodeWorkspaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Not configured - sign in with OpenCode to choose a workspace"
            }

            return "Disconnected - sign in with OpenCode"
        }

        if configuration.providerID == .openRouter {
            return "Not configured - enter OpenRouter Management API Key"
        }

        return "Not configured"
    }

    @discardableResult
    private func saveConfigurations() -> Bool {
        guard allowConfigurationMutation() else {
            return false
        }

        do {
            let data = try JSONEncoder().encode(configurations)
            defaults.set(data, forKey: configurationsKey)
            lastError = nil
            reconcileAccountAccess()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func allowConfigurationMutation() -> Bool {
        if isConfigurationRecoveryRequired {
            lastError = Self.configurationLoadErrorMessage
            return false
        }

        if isGroupRecoveryRequired {
            lastError = Self.groupLoadErrorMessage
            return false
        }

        return true
    }

    private var persistenceRecoveryErrorMessage: String? {
        if isConfigurationRecoveryRequired {
            return Self.configurationLoadErrorMessage
        }

        if isGroupRecoveryRequired {
            return Self.groupLoadErrorMessage
        }

        return nil
    }

    private func saveGroups() {
        guard allowConfigurationMutation() else {
            return
        }

        do {
            let data = try JSONEncoder().encode(groups)
            defaults.set(data, forKey: groupsKey)
            if !isPersistenceRecoveryRequired {
                lastError = nil
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func saveUsageAlertSettings() {
        do {
            let data = try JSONEncoder().encode(usageAlertSettings)
            defaults.set(data, forKey: usageAlertSettingsKey)
            if !isPersistenceRecoveryRequired {
                lastError = nil
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public nonisolated static func keychainAccount(for providerID: ProviderID) -> String {
        "provider.\(providerID.rawValue).credential"
    }

    public nonisolated static func keychainAccount(for configuration: ProviderAccountConfiguration) -> String {
        if configuration.id == configuration.providerID.rawValue {
            return keychainAccount(for: configuration.providerID)
        }

        return "providerAccount.\(configuration.id).credential"
    }

    private func keychainAccount(for providerID: ProviderID) -> String {
        Self.keychainAccount(for: providerID)
    }

    private func keychainAccount(for configuration: ProviderAccountConfiguration) -> String {
        Self.keychainAccount(for: configuration)
    }

    private enum DefaultsKey {
        static let configurations = "providerConfigurations"
        static let groups = "providerAccountGroups"
        static let showsSubscriptionRenewals = "showsSubscriptionRenewals"
        static let appAppearance = "appAppearance"
        static let autoRefreshInterval = "autoRefreshInterval"
        static let historySamplingInterval = "historySamplingInterval"
        static let widgetRefreshInterval = "widgetRefreshInterval"
        static let dashboardOrderingMode = "dashboardOrderingMode"
        static let dashboardCardOrder = "dashboardCardOrder"
        static let collapsedDashboardAccountIDs = "collapsedDashboardAccountIDs"
        static let metricCustomizationPreferences = "metricVisualizationPreferences"
        static let usageAlertSettings = "usageAlertSettings"
        static let usageAlertActiveIDs = "usageAlertActiveIDs"
        static let incompleteAccountReset = "incompleteAccountReset"
    }

    private struct ConfigurationLoadResult {
        let configurations: [ProviderAccountConfiguration]
        let error: String?
    }

    private struct GroupLoadResult {
        let groups: [ProviderAccountGroup]
        let error: String?
    }

    private struct MetricLayoutLoadResult {
        let layouts: [String: AccountMetricLayout]
        let needsMigration: Bool
        let usesVersionedStorage: Bool
        let unsupportedLayoutData: [String: Data]
        let opaqueData: Data?
    }

    private static let configurationLoadErrorMessage =
        "Saved account data couldn't be read. Replace the damaged account list in Settings to resume saving configurations."
    private static let groupLoadErrorMessage =
        "Saved group data couldn't be read. Replace the damaged group list in Settings to resume saving accounts and groups."

    private static func loadConfigurations(
        from defaults: UserDefaults,
        validGroupIDs: Set<String>? = nil
    ) -> ConfigurationLoadResult {
        guard defaults.object(forKey: DefaultsKey.configurations) != nil else {
            return ConfigurationLoadResult(configurations: [], error: nil)
        }

        guard let data = defaults.data(forKey: DefaultsKey.configurations) else {
            return ConfigurationLoadResult(
                configurations: [],
                error: configurationLoadErrorMessage
            )
        }

        let decoded: [ProviderAccountConfiguration]
        do {
            decoded = try JSONDecoder().decode([ProviderAccountConfiguration].self, from: data)
        } catch {
            return ConfigurationLoadResult(
                configurations: [],
                error: configurationLoadErrorMessage
            )
        }

        guard Set(decoded.map(\.id)).count == decoded.count else {
            return ConfigurationLoadResult(configurations: [], error: configurationLoadErrorMessage)
        }

        return ConfigurationLoadResult(
            configurations: decoded
                .map { normalizedConfiguration($0, validGroupIDs: validGroupIDs) }
                .sorted { configurationSort($0, $1) },
            error: nil
        )
    }

    private static func loadGroups(from defaults: UserDefaults) -> GroupLoadResult {
        guard defaults.object(forKey: DefaultsKey.groups) != nil else {
            return GroupLoadResult(groups: [], error: nil)
        }

        guard let data = defaults.data(forKey: DefaultsKey.groups) else {
            return GroupLoadResult(groups: [], error: groupLoadErrorMessage)
        }

        let decoded: [ProviderAccountGroup]
        do {
            decoded = try JSONDecoder().decode([ProviderAccountGroup].self, from: data)
        } catch {
            return GroupLoadResult(groups: [], error: groupLoadErrorMessage)
        }

        var seenIDs = Set<String>()
        var seenNames = Set<String>()
        let groups = decoded.compactMap { group in
            let name = normalizedGroupName(group.name)
            let nameKey = name.lowercased()
            guard !name.isEmpty,
                  seenIDs.insert(group.id).inserted,
                  seenNames.insert(nameKey).inserted
            else {
                return nil
            }

            return ProviderAccountGroup(id: group.id, name: name)
        }
        .sorted(by: groupSort)

        return GroupLoadResult(groups: groups, error: nil)
    }

    private static func loadAppAppearance(from defaults: UserDefaults) -> AppAppearance {
        guard
            let rawValue = defaults.string(forKey: DefaultsKey.appAppearance),
            let appearance = AppAppearance(rawValue: rawValue)
        else {
            return .system
        }

        return appearance
    }

    private static func loadAutoRefreshInterval(from defaults: UserDefaults) -> AutoRefreshInterval {
        guard
            defaults.object(forKey: DefaultsKey.autoRefreshInterval) != nil,
            let interval = AutoRefreshInterval(rawValue: defaults.integer(forKey: DefaultsKey.autoRefreshInterval))
        else {
            return .off
        }

        return interval
    }

    private static func loadHistorySamplingInterval(
        from defaults: UserDefaults
    ) -> HistorySamplingInterval {
        guard
            defaults.object(forKey: DefaultsKey.historySamplingInterval) != nil,
            let interval = HistorySamplingInterval(
                rawValue: defaults.integer(forKey: DefaultsKey.historySamplingInterval)
            )
        else {
            return .twoHours
        }

        return interval
    }

    private static func loadWidgetRefreshInterval(
        from defaults: UserDefaults,
        widgetSnapshotDefaults: UserDefaults?
    ) -> WidgetRefreshInterval {
        guard
            defaults.object(forKey: DefaultsKey.widgetRefreshInterval) != nil,
            let interval = WidgetRefreshInterval(rawValue: defaults.integer(forKey: DefaultsKey.widgetRefreshInterval))
        else {
            return WidgetSnapshotStore.loadRefreshInterval(defaults: widgetSnapshotDefaults)
        }

        WidgetSnapshotStore.saveRefreshInterval(interval, defaults: widgetSnapshotDefaults)
        return interval
    }

    private static func loadDashboardOrderingMode(from defaults: UserDefaults) -> DashboardOrderingMode {
        guard
            let rawValue = defaults.string(forKey: DefaultsKey.dashboardOrderingMode),
            let mode = DashboardOrderingMode(rawValue: rawValue)
        else {
            return .manual
        }

        return mode
    }

    private static func loadDashboardCardOrder(from defaults: UserDefaults) -> [String] {
        var seenAccountIDs = Set<String>()
        return (defaults.stringArray(forKey: DefaultsKey.dashboardCardOrder) ?? [])
            .filter { seenAccountIDs.insert($0).inserted }
    }

    private static func loadCollapsedDashboardAccountIDs(from defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: DefaultsKey.collapsedDashboardAccountIDs) ?? [])
    }

    private static func loadMetricLayouts(
        from defaults: UserDefaults
    ) -> MetricLayoutLoadResult {
        guard let data = defaults.data(forKey: DefaultsKey.metricCustomizationPreferences) else {
            return MetricLayoutLoadResult(
                layouts: [:],
                needsMigration: false,
                usesVersionedStorage: false,
                unsupportedLayoutData: [:],
                opaqueData: nil
            )
        }

        if let versioned = loadVersionedMetricLayouts(from: data) {
            return versioned
        }

        if let preferences = try? JSONDecoder().decode(
            [String: [String: MetricCustomizationPreference]].self,
            from: data
        ) {
            return MetricLayoutLoadResult(
                layouts: preferences.mapValues(Self.migratedMetricLayout),
                needsMigration: true,
                usesVersionedStorage: false,
                unsupportedLayoutData: [:],
                opaqueData: nil
            )
        }

        guard let legacyStyles = try? JSONDecoder().decode(
            [String: [String: MetricVisualizationStyle]].self,
            from: data
        ) else {
            return MetricLayoutLoadResult(
                layouts: [:],
                needsMigration: false,
                usesVersionedStorage: false,
                unsupportedLayoutData: [:],
                opaqueData: data
            )
        }
        return MetricLayoutLoadResult(
            layouts: legacyStyles.mapValues { accountStyles in
                migratedMetricLayout(
                    from: accountStyles.mapValues {
                        MetricCustomizationPreference(visualizationStyle: $0)
                    }
                )
            },
            needsMigration: true,
            usesVersionedStorage: false,
            unsupportedLayoutData: [:],
            opaqueData: nil
        )
    }

    private static func loadVersionedMetricLayouts(
        from data: Data
    ) -> MetricLayoutLoadResult? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            root.values.contains(where: { value in
                (value as? [String: Any])?["version"] is NSNumber
            })
        else {
            // An empty object is ambiguous with the legacy dictionary's encoded
            // empty state, so it must follow the legacy migration path.
            return nil
        }

        var layouts: [String: AccountMetricLayout] = [:]
        var preservedData: [String: Data] = [:]
        var needsMigration = false

        for (accountID, value) in root {
            guard
                let data = try? JSONSerialization.data(
                    withJSONObject: value,
                    options: [.fragmentsAllowed, .sortedKeys]
                )
            else {
                continue
            }

            guard let object = value as? [String: Any] else {
                preservedData[accountID] = data
                layouts[accountID] = AccountMetricLayout()
                continue
            }

            let version = (object["version"] as? NSNumber)?.intValue
                ?? AccountMetricLayout.currentVersion
            if
                version <= AccountMetricLayout.currentVersion,
                let decoded = try? JSONDecoder().decode(AccountMetricLayout.self, from: data) {
                let normalized = normalizedMetricLayout(decoded)
                layouts[accountID] = normalized
                needsMigration = needsMigration || normalized != decoded
            } else {
                // Preserve unsupported or otherwise undecodable account payloads
                // semantically while allowing known accounts to continue
                // loading and saving.
                preservedData[accountID] = data
                layouts[accountID] = (try? JSONDecoder().decode(
                    AccountMetricLayout.self,
                    from: data
                )) ?? AccountMetricLayout(version: version)
            }
        }

        return MetricLayoutLoadResult(
            layouts: layouts,
            needsMigration: needsMigration,
            usesVersionedStorage: true,
            unsupportedLayoutData: preservedData,
            opaqueData: nil
        )
    }

    private static func migratedMetricLayout(
        from preferences: [String: MetricCustomizationPreference]
    ) -> AccountMetricLayout {
        AccountMetricLayout(
            preferences: preferences.mapValues { preference in
                MetricTilePreference(
                    isVisible: preference.isVisible,
                    visualizationStyle: preference.visualizationStyle,
                    width: .full,
                    isNewlyDiscovered: false
                )
            },
            usesLegacyFullWidthDefaults: true
        )
    }

    private static func normalizedMetricLayout(
        _ layout: AccountMetricLayout
    ) -> AccountMetricLayout {
        guard layout.version <= AccountMetricLayout.currentVersion else {
            return layout
        }

        var normalized = layout
        normalized.version = AccountMetricLayout.currentVersion
        normalized.orderedMetricIDs = uniqueNonemptyMetricIDs(layout.orderedMetricIDs)
        return normalized
    }

    private static func uniqueNonemptyMetricIDs(_ metricIDs: [String]) -> [String] {
        var seenMetricIDs = Set<String>()
        return metricIDs.filter { !$0.isEmpty && seenMetricIDs.insert($0).inserted }
    }

    private func saveMetricLayouts() {
        guard opaqueMetricLayoutData == nil else {
            return
        }
        guard
            let encoded = try? JSONEncoder().encode(metricLayouts),
            var root = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        else {
            return
        }

        for (accountID, data) in unsupportedMetricLayoutData
        where metricLayouts[accountID] != nil {
            guard let preserved = try? JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            ) else {
                continue
            }
            root[accountID] = preserved
        }

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else {
            return
        }
        defaults.set(data, forKey: metricCustomizationPreferencesKey)
    }

    private func removeCollapsedDashboardAccountIDs(_ accountIDs: Set<String>) {
        let priorCount = collapsedDashboardAccountIDs.count
        collapsedDashboardAccountIDs.subtract(accountIDs)
        guard collapsedDashboardAccountIDs.count != priorCount else {
            return
        }
        saveCollapsedDashboardAccountIDs()
    }

    private func saveCollapsedDashboardAccountIDs() {
        defaults.set(collapsedDashboardAccountIDs.sorted(), forKey: collapsedDashboardAccountIDsKey)
    }

    private static func loadUsageAlertSettings(from defaults: UserDefaults) -> UsageAlertSettings {
        guard
            let data = defaults.data(forKey: DefaultsKey.usageAlertSettings),
            let decoded = try? JSONDecoder().decode(UsageAlertSettings.self, from: data)
        else {
            return UsageAlertSettings()
        }

        return UsageAlertSettings(
            isEnabled: decoded.isEnabled,
            warningThreshold: decoded.warningThreshold,
            criticalThreshold: decoded.criticalThreshold,
            balanceThreshold: decoded.balanceThreshold
        )
    }

    private static func usageAlertSettingsNeedMigration(in defaults: UserDefaults) -> Bool {
        guard
            let data = defaults.data(forKey: DefaultsKey.usageAlertSettings),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }

        return object["usageThreshold"] != nil || object["includesSeverityAlerts"] != nil
    }

    private static func loadUsageAlertActiveIDs(from defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: DefaultsKey.usageAlertActiveIDs) ?? [])
    }

    private static func normalizedConfiguration(
        _ configuration: ProviderAccountConfiguration,
        validGroupIDs: Set<String>? = nil
    ) -> ProviderAccountConfiguration {
        var normalized = configuration
        if let validGroupIDs, let groupID = normalized.groupID, !validGroupIDs.contains(groupID) {
            normalized.groupID = nil
        }

        switch configuration.providerID {
        case .codex, .githubBilling, .cursor, .gemini, .grok, .xSubscription:
            normalized.authMethod = .browserSession
        case .antigravity:
            normalized.authMethod = .cliToken
        case .copilot, .claude, .openRouter, .openCodeZen, .moonshot, .greptile:
            break
        }
        return normalized
    }

    private func sortConfigurations() {
        configurations = sortedConfigurations(configurations)
    }

    private func sortedConfigurations(
        _ configurations: [ProviderAccountConfiguration]
    ) -> [ProviderAccountConfiguration] {
        let groupNames = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name) })
        return configurations.sorted {
            Self.configurationSort($0, $1, groupNames: groupNames)
        }
    }

    private func sortGroups() {
        groups.sort(by: Self.groupSort)
    }

    private static func configurationSort(
        _ lhs: ProviderAccountConfiguration,
        _ rhs: ProviderAccountConfiguration,
        groupNames: [String: String] = [:]
    ) -> Bool {
        let lhsGroup = lhs.groupID.flatMap { groupNames[$0] } ?? ""
        let rhsGroup = rhs.groupID.flatMap { groupNames[$0] } ?? ""
        if lhsGroup != rhsGroup {
            return lhsGroup.localizedCaseInsensitiveCompare(rhsGroup) == .orderedAscending
        }

        if lhs.providerID.displayName != rhs.providerID.displayName {
            return lhs.providerID.displayName < rhs.providerID.displayName
        }

        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    private static func groupSort(_ lhs: ProviderAccountGroup, _ rhs: ProviderAccountGroup) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func isAccountNameUnique(_ configuration: ProviderAccountConfiguration) -> Bool {
        let name = configuration.displayName

        return !(visibleConfigurations + unlinkedGeminiCodingAccounts).contains {
            $0.id != configuration.id
                && $0.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func isGroupNameUnique(_ name: String, excluding groupID: String? = nil) -> Bool {
        !groups.contains {
            $0.id != groupID
                && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    private static func normalizedGroupName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeEmailAddress(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else {
            return false
        }
        let domainParts = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return domainParts.count >= 2 && domainParts.allSatisfy { !$0.isEmpty }
    }

    private func suggestedAccountLabel(for providerID: ProviderID) -> String {
        let base = providerID.displayName
        var index = configurations(for: providerID).count + 1
        while true {
            let candidate = "\(base) \(index)"
            let matchesExisting = (visibleConfigurations + unlinkedGeminiCodingAccounts).contains {
                $0.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(candidate) == .orderedSame
            }
            if !matchesExisting {
                return candidate
            }
            index += 1
        }
    }
}

#if DEBUG
public extension ProviderConfigurationStore {
    static func appStoreScreenshotDemo(singleAccount: Bool = false) -> ProviderConfigurationStore {
        let suiteName = "com.hemsoft.CodexBarIOS.appStoreScreenshots.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated screenshot account storage.")
        }

        defaults.removePersistentDomain(forName: suiteName)

        let usageGroup = ProviderAccountGroup(id: AppStoreScreenshotFixtureID.usageGroup, name: "Usage Limits")
        let balanceGroup = ProviderAccountGroup(id: AppStoreScreenshotFixtureID.balanceGroup, name: "API Balances")
        let sampleConfigurations = [
            ProviderAccountConfiguration(
                id: AppStoreScreenshotFixtureID.codexAccount,
                providerID: .codex,
                accountLabel: "Personal Codex",
                groupID: usageGroup.id,
                authMethod: .browserSession
            ),
            ProviderAccountConfiguration(
                id: AppStoreScreenshotFixtureID.copilotAccount,
                providerID: .copilot,
                accountLabel: "GitHub Copilot",
                groupID: usageGroup.id,
                authMethod: .browserSession,
                copilotAccountScope: .organization,
                githubOrganization: "fableton-labs"
            ),
            ProviderAccountConfiguration(
                id: AppStoreScreenshotFixtureID.githubBillingAccount,
                providerID: .githubBilling,
                accountLabel: "GitHub Billing",
                groupID: usageGroup.id,
                authMethod: .browserSession,
                githubBillingAccountScope: .personal,
                githubBillingOwner: "sample-personal"
            ),
            ProviderAccountConfiguration(
                id: AppStoreScreenshotFixtureID.claudeAccount,
                providerID: .claude,
                accountLabel: "Claude Pro",
                groupID: usageGroup.id,
                authMethod: .browserSession
            ),
            ProviderAccountConfiguration(
                id: AppStoreScreenshotFixtureID.grokAccount,
                providerID: .grok,
                accountLabel: "Sample Grok",
                groupID: usageGroup.id,
                authMethod: .browserSession
            ),
            ProviderAccountConfiguration(
                id: AppStoreScreenshotFixtureID.xSubscriptionAccount,
                providerID: .xSubscription,
                accountLabel: "X Subscription",
                groupID: usageGroup.id,
                authMethod: .browserSession
            ),
            ProviderAccountConfiguration(
                id: AppStoreScreenshotFixtureID.cursorAccount,
                providerID: .cursor,
                accountLabel: "Cursor Pro",
                groupID: usageGroup.id,
                authMethod: .browserSession
            ),
            ProviderAccountConfiguration(
                id: AppStoreScreenshotFixtureID.openRouterAccount,
                providerID: .openRouter,
                accountLabel: "OpenRouter",
                groupID: balanceGroup.id,
                authMethod: .apiKey
            ),
            ProviderAccountConfiguration(
                id: AppStoreScreenshotFixtureID.openCodeZenAccount,
                providerID: .openCodeZen,
                groupID: usageGroup.id,
                authMethod: .apiKey,
                openCodeWorkspaceId: "demo-workspace"
            ),
            ProviderAccountConfiguration(
                id: AppStoreScreenshotFixtureID.moonshotAccount,
                providerID: .moonshot,
                accountLabel: "Moonshot (Kimi)",
                groupID: balanceGroup.id,
                authMethod: .apiKey
            ),
            ProviderAccountConfiguration(
                id: AppStoreScreenshotFixtureID.greptileAccount,
                providerID: .greptile,
                accountLabel: "Greptile Reviews",
                groupID: usageGroup.id,
                authMethod: .apiKey
            ),
            ProviderAccountConfiguration(
                id: AppStoreScreenshotFixtureID.geminiAccount,
                providerID: .gemini,
                accountLabel: "Google AI Pro",
                groupID: usageGroup.id,
                authMethod: .apiKey
            ),
        ]

        let configurations = singleAccount ? Array(sampleConfigurations.prefix(1)) : sampleConfigurations
        let encoder = JSONEncoder()
        defaults.set(try? encoder.encode([usageGroup, balanceGroup]), forKey: DefaultsKey.groups)
        defaults.set(try? encoder.encode(configurations), forKey: DefaultsKey.configurations)
        defaults.set(DashboardOrderingMode.manual.rawValue, forKey: DefaultsKey.dashboardOrderingMode)
        defaults.set(configurations.map(\.id), forKey: DefaultsKey.dashboardCardOrder)

        let accounts = Set(configurations.map(Self.keychainAccount(for:))).union([
            Self.geminiCodingKeychainAccount(accountID: AppStoreScreenshotFixtureID.geminiAccount),
        ])
        return ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: AppStoreScreenshotSecretStore(accounts: accounts), widgetSnapshotDefaults: defaults
        )
    }
}

private struct AppStoreScreenshotSecretStore: SecretStore {
    let accounts: Set<String>

    func readSecret(account: String) throws -> String? {
        accounts.contains(account) ? "app-store-screenshot-secret" : nil
    }

    func saveSecret(_ secret: String, account: String) throws {}

    func deleteSecret(account: String) throws {}
}
#endif

public extension ProviderConfigurationStore {
    func cursorAccountLabelAfterIdentityChange(for configuration: ProviderAccountConfiguration) -> String {
        guard configuration.providerID == .cursor else { return configuration.accountLabel }
        let currentLabel = configuration.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentLabel.isEmpty || Self.looksLikeEmailAddress(currentLabel) else { return configuration.accountLabel }
        let base = ProviderID.cursor.displayName
        let otherNames = configurations.filter { $0.id != configuration.id }.map(\.displayName)
        if !otherNames.contains(where: { $0.localizedCaseInsensitiveCompare(base) == .orderedSame }) { return "" }
        var index = 2
        while otherNames.contains(where: { $0.localizedCaseInsensitiveCompare("\(base) \(index)") == .orderedSame }) {
            index += 1
        }
        return "\(base) \(index)"
    }

    private static func cursorIdentityChanged(previous: String?, replacement: String) -> Bool {
        guard let previous else { return true }
        // Account IDs here came from browser authorization, never unsigned token claims.
        guard let previousID = CursorSessionCredential(storedSecret: previous)?.savedAccountIdentity,
              let replacementID = CursorSessionCredential(storedSecret: replacement)?.savedAccountIdentity else { return true }
        return previousID != replacementID
    }

    /// Save a missing Google source only when the user opens its setup controls.
    func prepareDashboardAccountForSetup(
        _ configuration: ProviderAccountConfiguration
    ) -> ProviderAccountConfiguration? {
        if let saved = self.configuration(accountID: configuration.id) {
            return saved
        }
        guard GoogleUsageMetricCatalog.missingSourceConfigurations(in: configurations).contains(configuration) else {
            return nil
        }
        var account = configuration
        if !isAccountNameUnique(account) {
            account.accountLabel = suggestedAccountLabel(for: account.providerID)
        }
        guard update(account) else { return nil }
        return self.configuration(accountID: account.id)
    }
}

public extension ProviderConfigurationStore {
    /// Legacy coding records stay stored until explicitly associated, but are never separate accounts in the UI.
    var visibleConfigurations: [ProviderAccountConfiguration] {
        configurations.filter { $0.providerID != .antigravity }
    }

    var unlinkedGeminiCodingAccounts: [ProviderAccountConfiguration] {
        configurations.filter { $0.providerID == .antigravity && confirmedGoogleAccountLinks[$0.id] == nil }
    }

    nonisolated static func geminiCodingKeychainAccount(accountID: String) -> String {
        "provider.gemini.\(accountID).coding"
    }

    func hasGeminiCodingSecret(for configuration: ProviderAccountConfiguration) -> Bool {
        secretAvailability[Self.geminiCodingKeychainAccount(accountID: configuration.id)] ?? false
    }

    func linkedGoogleAccountIDs(for accountID: String) -> [String] {
        confirmedGoogleAccountLinks.filter { $0.value == accountID }.keys.sorted()
    }

    @discardableResult
    func saveGeminiCodingSecret(
        _ secret: String,
        for configuration: ProviderAccountConfiguration,
        confirmedSameAccount: Bool,
        requireEmptySlot: Bool = false
    ) -> Bool {
        guard allowConfigurationMutation(), confirmedSameAccount,
              configuration.providerID == .gemini,
              self.configuration(accountID: configuration.id)?.providerID == .gemini else { return false }
        do {
            if requireEmptySlot,
               try secretStore.readSecret(account: Self.geminiCodingKeychainAccount(accountID: configuration.id)) != nil {
                return false
            }
            let credential = try AntigravityCredentials.parse(secret).encoded()
            try secretStore.saveSecret(credential, account: Self.geminiCodingKeychainAccount(accountID: configuration.id))
            credentialChanges.send(configuration.id)
            lastError = nil
            refreshSecretAvailability()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func disconnectGeminiCoding(for configuration: ProviderAccountConfiguration) -> Bool {
        guard allowConfigurationMutation(), configuration.providerID == .gemini,
              self.configuration(accountID: configuration.id)?.providerID == .gemini else { return false }
        do {
            var pending = defaults.dictionary(forKey: "pendingGoogleAccountLinks") as? [String: String] ?? [:]
            let sourceIDs = Set(linkedGoogleAccountIDs(for: configuration.id))
                .union(pending.filter { $0.value == configuration.id }.keys)
            for sourceID in sourceIDs {
                if let source = self.configuration(accountID: sourceID) {
                    try secretStore.deleteSecret(account: keychainAccount(for: source))
                }
                pending.removeValue(forKey: sourceID)
            }
            defaults.set(pending, forKey: "pendingGoogleAccountLinks")
            try secretStore.deleteSecret(account: Self.geminiCodingKeychainAccount(accountID: configuration.id))
            credentialChanges.send(configuration.id)
            lastError = nil
            refreshSecretAvailability()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func linkGeminiCodingAccount(
        _ legacy: ProviderAccountConfiguration,
        to gemini: ProviderAccountConfiguration,
        confirmedSameAccount: Bool
    ) -> Bool {
        guard allowConfigurationMutation(),
              let savedLegacy = configuration(accountID: legacy.id), savedLegacy.providerID == .antigravity,
              let savedGemini = configuration(accountID: gemini.id), savedGemini.providerID == .gemini,
              confirmedGoogleAccountLinks[legacy.id] == nil,
              canAssociateGoogleAccounts(savedLegacy, savedGemini, confirmedSameAccount: confirmedSameAccount) else {
            return false
        }
        guard opaqueMetricLayoutData == nil,
              unsupportedMetricLayoutData[legacy.id] == nil, unsupportedMetricLayoutData[gemini.id] == nil else {
            lastError = "Saved metric settings need recovery before this coding session can be linked."
            return false
        }
        do {
            let destination = Self.geminiCodingKeychainAccount(accountID: gemini.id)
            let source = try secretStore.readSecret(account: keychainAccount(for: savedLegacy))
            let normalized = try source.map { try AntigravityCredentials.parse($0).encoded() }
            let existing = try secretStore.readSecret(account: destination)
            var pending = defaults.dictionary(forKey: "pendingGoogleAccountLinks") as? [String: String] ?? [:]
            guard existing == nil || (pending[legacy.id] == gemini.id && existing == normalized) else {
                lastError = "Disconnect this Gemini account's coding session before linking a saved session."
                return false
            }
            pending[legacy.id] = gemini.id
            defaults.set(pending, forKey: "pendingGoogleAccountLinks")
            if let normalized {
                try secretStore.saveSecret(normalized, account: destination)
                credentialChanges.send(gemini.id)
            }
            mergeGoogleMetricLayout(from: legacy.id, into: gemini.id, prefersSource: true)
            saveMetricLayouts()
            var links = confirmedGoogleAccountLinks
            links[legacy.id] = gemini.id
            defaults.set(links, forKey: "confirmedGoogleAccountLinks")
            // Preserve the original configuration and secret as internal migration records.
            // History observers can retry migration safely after a crash or unreadable history file.
            confirmedGoogleAccountLinks = links
            pending.removeValue(forKey: legacy.id)
            defaults.set(pending, forKey: "pendingGoogleAccountLinks")
            lastError = nil
            refreshSecretAvailability()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func canAssociateGoogleAccounts(
        _ legacy: ProviderAccountConfiguration,
        _ gemini: ProviderAccountConfiguration,
        confirmedSameAccount: Bool
    ) -> Bool {
        if let legacySubject = legacy.verifiedGoogleSubject, let geminiSubject = gemini.verifiedGoogleSubject {
            guard legacySubject == geminiSubject, !legacySubject.isEmpty else {
                lastError = "These sessions belong to different verified Google accounts."
                return false
            }
            return true
        }
        guard confirmedSameAccount else {
            lastError = "Confirm that both sessions belong to this Google account before linking."
            return false
        }
        return true
    }

    private func mergeGoogleMetricLayout(from sourceID: String, into targetID: String, prefersSource: Bool = false) {
        guard let source = metricLayouts[sourceID] else { return }
        var target = metricLayouts[targetID] ?? AccountMetricLayout()
        for (metricID, preference) in source.preferences where prefersSource || target.preferences[metricID] == nil {
            target.preferences[metricID] = preference
        }
        let sourceIDs = Set(source.orderedMetricIDs)
        let preservedOrder = prefersSource ? target.orderedMetricIDs.filter { !sourceIDs.contains($0) } : target.orderedMetricIDs
        target.orderedMetricIDs = Self.uniqueNonemptyMetricIDs(preservedOrder + source.orderedMetricIDs)
        metricLayouts[targetID] = target
    }

    private func removeGoogleLinks(for removedAccountIDs: Set<String>) {
        let remaining = confirmedGoogleAccountLinks.filter { !removedAccountIDs.contains($0.key) && !removedAccountIDs.contains($0.value) }
        defaults.set(remaining, forKey: "confirmedGoogleAccountLinks")
        confirmedGoogleAccountLinks = remaining
        let pending = defaults.dictionary(forKey: "pendingGoogleAccountLinks") as? [String: String] ?? [:]
        defaults.set(pending.filter { !removedAccountIDs.contains($0.key) && !removedAccountIDs.contains($0.value) }, forKey: "pendingGoogleAccountLinks")
    }

    private func resumePendingGoogleLinks() {
        let pending = defaults.dictionary(forKey: "pendingGoogleAccountLinks") as? [String: String] ?? [:]
        for (sourceID, targetID) in pending where confirmedGoogleAccountLinks[sourceID] == nil {
            guard let source = configuration(accountID: sourceID), let target = configuration(accountID: targetID) else { continue }
            linkGeminiCodingAccount(source, to: target, confirmedSameAccount: true)
        }
    }

    private func migrateGoogleSetupLayouts() {
        guard opaqueMetricLayoutData == nil else { return }
        for configuration in visibleConfigurations where configuration.providerID == .gemini {
            for sourceID in ["dashboard.setup.gemini", "dashboard.setup.antigravity"]
            where unsupportedMetricLayoutData[sourceID] == nil && unsupportedMetricLayoutData[configuration.id] == nil {
                mergeGoogleMetricLayout(from: sourceID, into: configuration.id)
            }
        }
        saveMetricLayouts()
    }
}

extension ProviderConfigurationStore {
    public func refreshSecretAvailability() {
        var availability: [String: Bool] = [:]
        var firstReadError: String?
        for configuration in configurations {
            var sources = [(configuration.id, keychainAccount(for: configuration))]
            if configuration.providerID == .gemini {
                let codingAccount = Self.geminiCodingKeychainAccount(accountID: configuration.id)
                sources.append((codingAccount, codingAccount))
            }
            for (availabilityID, account) in sources {
                do {
                    availability[availabilityID] = try secretStore.readSecret(account: account) != nil
                } catch {
                    availability[availabilityID] = false
                    if firstReadError == nil {
                        firstReadError = "Could not read the saved credential for \(configuration.displayName): \(error.localizedDescription)"
                    }
                }
            }
        }
        secretAvailability = availability
        let previousSecretAvailabilityError = secretAvailabilityError
        secretAvailabilityError = firstReadError
        if let firstReadError {
            lastError = firstReadError
        } else if lastError == previousSecretAvailabilityError {
            lastError = persistenceRecoveryErrorMessage
        }
    }

}

public extension ProviderConfigurationStore {
    var freeActiveAccountID: String? {
        defaults.string(forKey: "freeActiveAccountID")
    }

    var activeAccountCandidates: [ProviderAccountConfiguration] {
        let candidates = visibleConfigurations.filter(\.isEnabled)
        let order = accountAccessOrder.isEmpty ? dashboardCardOrder : accountAccessOrder
        let indexes = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return candidates.enumerated().sorted {
            let left = indexes[$0.element.id] ?? Int.max
            let right = indexes[$1.element.id] ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    func canAddAccount(for providerID: ProviderID) -> Bool {
        accountAccess.permitsInsertion(for: providerID, configurations: configurations)
    }

    func requestProPresentation() {
        requestProPresentation(origin: .limit)
    }

    func requestProPresentation(origin: ProPresentationOrigin) {
        // Repeated taps preserve the active destination and its purchase context.
        guard !requestedProPresentation else { return }
        requestedProPresentationOrigin = origin
        requestedProPresentation = true
    }

    func dismissProPresentation() {
        requestedProPresentation = false
    }

    func applyPlanAccess(hasProAccess: Bool, isResolved: Bool, dashboardOrder: [String]? = nil) {
        if let dashboardOrder {
            accountAccessOrder = uniqueAccountIDs(dashboardOrder)
        }
        if isResolved {
            let previouslyHadPro = defaults.object(forKey: "lastResolvedPlanHadProAccess") as? Bool
            if hasProAccess {
                explicitActiveAccountChoiceRequested = false
                defaults.set(false, forKey: "freeActiveAccountChoicePending")
            } else if previouslyHadPro == true {
                defaults.set(true, forKey: "freeActiveAccountChoicePending")
            }
            defaults.set(hasProAccess, forKey: "lastResolvedPlanHadProAccess")
        }
        reconcileAccountAccess(hasProAccess: hasProAccess, isResolved: isResolved)
    }

    /// The dashboard supplies its current smart order before an access transition.
    /// A valid saved choice survives later changes in card order.
    func updateAccountAccessOrder(_ accountIDs: [String]) {
        accountAccessOrder = uniqueAccountIDs(accountIDs)
        reconcileAccountAccess()
    }

    func requestActiveAccountChoice() {
        guard accountAccess.isResolved, !accountAccess.hasProAccess, !visibleConfigurations.isEmpty else { return }
        explicitActiveAccountChoiceRequested = true
        reconcileAccountAccess()
    }

    func dismissActiveAccountChoice() {
        explicitActiveAccountChoiceRequested = false
        defaults.set(false, forKey: "freeActiveAccountChoicePending")
        reconcileAccountAccess()
    }

    @discardableResult
    func chooseActiveAccount(_ accountID: String) -> Bool {
        guard accountAccess.isResolved, !accountAccess.hasProAccess,
              activeAccountCandidates.contains(where: { $0.id == accountID }) else { return false }
        defaults.set(accountID, forKey: "freeActiveAccountID")
        explicitActiveAccountChoiceRequested = false
        defaults.set(false, forKey: "freeActiveAccountChoicePending")
        reconcileAccountAccess()
        return true
    }

    private func allowAccountInsertion(for providerID: ProviderID) -> Bool {
        guard canAddAccount(for: providerID) else {
            lastError = "CodexBar Pro is required to add another account."
            requestProPresentation()
            return false
        }
        return true
    }

    private func reconcileAccountAccess(hasProAccess: Bool? = nil, isResolved: Bool? = nil) {
        let hasProAccess = hasProAccess ?? accountAccess.hasProAccess
        let isResolved = isResolved ?? accountAccess.isResolved
        var activeID: String?
        var pausedIDs = Set<String>()
        var needsChoice = false
        if isResolved, hasProAccess, let savedID = freeActiveAccountID {
            let candidates = activeAccountCandidates.map(\.id)
            if !candidates.contains(savedID) {
                defaults.set(candidates.first, forKey: "freeActiveAccountID")
            }
        }
        if isResolved, !hasProAccess {
            let candidateIDs = activeAccountCandidates.map(\.id)
            activeID = freeActiveAccountID
            if activeID == nil || !candidateIDs.contains(activeID ?? "") {
                activeID = candidateIDs.first
                defaults.set(activeID, forKey: "freeActiveAccountID")
                defaults.set(candidateIDs.count > 1, forKey: "freeActiveAccountChoicePending")
            }
            if candidateIDs.count <= 1 {
                defaults.set(false, forKey: "freeActiveAccountChoicePending")
            }
            pausedIDs = Set(candidateIDs.filter { $0 != activeID })
            needsChoice = !visibleConfigurations.isEmpty
                && (explicitActiveAccountChoiceRequested || defaults.bool(forKey: "freeActiveAccountChoicePending"))
        }
        let updated = AccountPlanAccess(
            hasProAccess: hasProAccess,
            isResolved: isResolved,
            activeAccountID: activeID,
            pausedAccountIDs: pausedIDs,
            needsActiveAccountChoice: needsChoice
        )
        if updated != accountAccess { accountAccess = updated }
    }

    private func uniqueAccountIDs(_ accountIDs: [String]) -> [String] {
        var seen = Set<String>()
        return accountIDs.filter { seen.insert($0).inserted }
    }
}

extension ProviderConfigurationStore {
    private func deleteAccountSecret(_ account: String, grokAccounts: Set<String>) throws {
        if grokAccounts.contains(account) {
            try GrokCredentialLock.withLock { try secretStore.deleteSecret(account: account) }
        } else {
            try secretStore.deleteSecret(account: account)
        }
    }

    @discardableResult
    public func resetAccounts() -> Bool {
        guard allowConfigurationMutation() else {
            return false
        }

        let knownAccountIDs = Set(configurations.map(\.id))
        var accountsToDelete: [String] = []
        var seenKeychainAccounts = Set<String>()
        let codingAccounts = configurations.filter { $0.providerID == .gemini }
            .map { Self.geminiCodingKeychainAccount(accountID: $0.id) }
        let grokAccounts = Set(configurations.filter(\.providerID.usesXAIConsumerAuth).map { keychainAccount(for: $0) })
            .union([keychainAccount(for: .grok), keychainAccount(for: .xSubscription)])
        for account in configurations.map({ keychainAccount(for: $0) })
            + ProviderID.allCases.map({ keychainAccount(for: $0) })
            + codingAccounts
            + configurations.filter({ [.claude, .grok].contains($0.providerID) }).map({ SubscriptionBillingSession.keychainAccount($0) })
        where seenKeychainAccounts.insert(account).inserted {
            accountsToDelete.append(account)
        }

        var removedAccountIDs = Set<String>()
        var firstDeletionError: String?
        var failedKeychainAccounts = Set<String>()
        for account in accountsToDelete {
            do {
                try deleteAccountSecret(account, grokAccounts: grokAccounts)
                if let configuration = configurations.first(where: {
                    [ProviderID.gemini, .grok, .xSubscription, .claude, .openCodeZen].contains($0.providerID)
                        && (keychainAccount(for: $0) == account
                            || Self.geminiCodingKeychainAccount(accountID: $0.id) == account
                            || ([.claude, .grok].contains($0.providerID)
                                && SubscriptionBillingSession.keychainAccount($0) == account))
                }) {
                    credentialChanges.send(configuration.id)
                    // Clear history once, when the usage credential itself is deleted.
                    if configuration.providerID.usesXAIConsumerAuth, keychainAccount(for: configuration) == account {
                        grokHistoryInvalidations.send(configuration.id)
                    }
                }
                removedAccountIDs.formUnion(
                    configurations
                        .filter { keychainAccount(for: $0) == account }
                        .map(\.id)
                )
            } catch {
                failedKeychainAccounts.insert(account)
                if firstDeletionError == nil {
                    firstDeletionError = error.localizedDescription
                }
            }
        }

        removedAccountIDs.subtract(configurations.filter { configuration in
            failedKeychainAccounts.contains(keychainAccount(for: configuration))
                || (configuration.providerID == .gemini
                    && failedKeychainAccounts.contains(Self.geminiCodingKeychainAccount(accountID: configuration.id)))
                || ([.claude, .grok].contains(configuration.providerID)
                    && failedKeychainAccounts.contains(SubscriptionBillingSession.keychainAccount(configuration)))
        }.map(\.id))

        if firstDeletionError == nil {
            confirmedGoogleAccountLinks = [:]
            defaults.removeObject(forKey: "confirmedGoogleAccountLinks")
            defaults.removeObject(forKey: "pendingGoogleAccountLinks")
            configurations = []
            groups = []
            secretAvailability = [:]
            dashboardCardOrder = []
            collapsedDashboardAccountIDs = []
            metricLayouts = [:]
            unsupportedMetricLayoutData = [:]
            opaqueMetricLayoutData = nil
            usageAlertActiveIDs = []
            explicitActiveAccountChoiceRequested = false
            defaults.removeObject(forKey: "freeActiveAccountID")
            defaults.removeObject(forKey: "freeActiveAccountChoicePending")
            defaults.removeObject(forKey: configurationsKey)
            defaults.removeObject(forKey: groupsKey)
            defaults.removeObject(forKey: dashboardCardOrderKey)
            defaults.removeObject(forKey: collapsedDashboardAccountIDsKey)
            defaults.removeObject(forKey: metricCustomizationPreferencesKey)
            defaults.removeObject(forKey: usageAlertActiveIDsKey)
            defaults.removeObject(forKey: incompleteAccountResetKey)
            isConfigurationRecoveryRequired = false
            isGroupRecoveryRequired = false
            hasIncompleteAccountReset = false
            lastError = nil
            reconcileAccountAccess()
            return true
        }

        if !removedAccountIDs.isEmpty {
            removeGoogleLinks(for: removedAccountIDs)
            configurations.removeAll { removedAccountIDs.contains($0.id) }
            sortConfigurations()
            saveConfigurations()
            updateDashboardCardOrder(
                dashboardCardOrder.filter { !removedAccountIDs.contains($0) }
            )
            removeCollapsedDashboardAccountIDs(removedAccountIDs)
            updateUsageAlertActiveIDs(
                UsageAlertEvaluator.activeAlertIDs(
                    usageAlertActiveIDs,
                    belongingTo: Set(configurations.map(\.id)),
                    knownAccountIDs: knownAccountIDs
                )
            )
            for accountID in removedAccountIDs {
                metricLayouts.removeValue(forKey: accountID)
                unsupportedMetricLayoutData.removeValue(forKey: accountID)
            }
            saveMetricLayouts()
        }
        refreshSecretAvailability()
        hasIncompleteAccountReset = true
        defaults.set(true, forKey: incompleteAccountResetKey)
        lastError = firstDeletionError
        return false
    }

}

extension ProviderConfigurationStore {
    private func greptileCredentialChangesIdentity(_ credential: String, for configuration: ProviderAccountConfiguration) throws -> Bool {
        guard configuration.providerID == .greptile else { return false }
        let previous = try secretStore.readSecret(account: Self.keychainAccount(for: configuration))
        guard let next = GreptileSessionCredentials.parse(credential) else { return previous != credential }
        return GreptileSessionCredentials.parse(previous)?.cacheIdentity != next.cacheIdentity
    }

    private func sendGreptileCredentialUpdate(for configuration: ProviderAccountConfiguration, identityChanged: Bool) {
        guard configuration.providerID == .greptile else { return }
        greptileCredentialUpdates.send((accountID: configuration.id, identityChanged: identityChanged))
    }

    func canReconnectGreptile(_ credential: GreptileSessionCredentials, for configuration: ProviderAccountConfiguration) -> Bool {
        do {
            let saved = try secretStore.readSecret(account: Self.keychainAccount(for: configuration))
            guard let saved, !saved.isEmpty else { return true }
            guard let previous = GreptileSessionCredentials.parse(saved) else {
                lastError = configuration.authMethod == .apiKey
                    ? "Add a separate Greptile account to sign in. This API-key account's identity cannot be verified."
                    : "The saved Greptile sign-in could not be read. Disconnect and sign in again."
                return false
            }
            guard previous.cacheIdentity == credential.cacheIdentity else {
                lastError = GreptileSignInError.wrongAccount.localizedDescription
                return false
            }
            return true
        } catch {
            lastError = "The saved Greptile identity could not be verified. Your saved account was not changed."
            return false
        }
    }

}

extension ProviderConfigurationStore {
    public func updateShowsSubscriptionRenewals(_ shows: Bool) {
        showsSubscriptionRenewals = shows
        defaults.set(shows, forKey: DefaultsKey.showsSubscriptionRenewals)
    }

}

extension ProviderConfigurationStore {
    private func writeAccountSecret(_ value: String?, for configuration: ProviderAccountConfiguration) throws {
        var changedGrokSubject = false
        let write = {
            let account = self.keychainAccount(for: configuration)
            let hasBilling = [.claude, .grok].contains(configuration.providerID)
            let usesXAI = configuration.providerID.usesXAIConsumerAuth
            let previous = hasBilling || usesXAI ? try self.secretStore.readSecret(account: account) : nil
            if usesXAI {
                let oldSubject = GrokCredential.parse(previous)?.subject
                changedGrokSubject = oldSubject != nil && oldSubject != GrokCredential.parse(value)?.subject
            }
            try self.replaceSecret(value, account: account)
            guard hasBilling else { return }
            do {
                try self.secretStore.deleteSecret(account: SubscriptionBillingSession.keychainAccount(configuration))
            } catch {
                let deletionError = error
                do {
                    try self.replaceSecret(previous, account: account)
                } catch {
                    self.credentialChanges.send(configuration.id)
                    if usesXAI { self.grokHistoryInvalidations.send(configuration.id) }
                    throw error
                }
                throw deletionError
            }
        }
        if configuration.providerID.usesXAIConsumerAuth {
            try GrokCredentialLock.withLock(write)
            if changedGrokSubject { grokHistoryInvalidations.send(configuration.id) }
        } else {
            try write()
        }
    }

    private func replaceSecret(_ value: String?, account: String) throws {
        if let value, !value.isEmpty {
            try secretStore.saveSecret(value, account: account)
        } else {
            try secretStore.deleteSecret(account: account)
        }
    }

    func billingUsageSecret(for configuration: ProviderAccountConfiguration) -> String? {
        guard let current = self.configuration(accountID: configuration.id), current.providerID == configuration.providerID else { return nil }
        return try? secretStore.readSecret(account: Self.keychainAccount(for: current))
    }

    func hasSubscriptionBillingSession(for configuration: ProviderAccountConfiguration) -> Bool {
        SubscriptionBillingSession.parse(try? secretStore.readSecret(account: SubscriptionBillingSession.keychainAccount(configuration))) != nil
    }

    @discardableResult
    func saveSubscriptionBillingSession(_ session: SubscriptionBillingSession, for configuration: ProviderAccountConfiguration,
                                        expectedUsageSecret: String) -> Bool {
        guard allowConfigurationMutation(), let current = self.configuration(accountID: configuration.id),
              current.providerID == session.providerID, SubscriptionBillingSession.host(session.providerID) != nil,
              SubscriptionBillingSession.header(session.cookies, at: Date()) != nil,
              session.providerID != .grok || GrokCredential.parse(expectedUsageSecret)?.subject == session.ownerID,
              billingUsageSecret(for: current) == expectedUsageSecret else { return false }
        do {
            try secretStore.saveSecret(try session.encoded(), account: SubscriptionBillingSession.keychainAccount(current))
            credentialChanges.send(current.id)
            return true
        } catch {
            lastError = "Billing connection could not be saved securely."
            return false
        }
    }

    @discardableResult
    func removeSubscriptionBillingSession(for configuration: ProviderAccountConfiguration) -> Bool {
        guard allowConfigurationMutation() else { return false }
        do {
            try secretStore.deleteSecret(account: SubscriptionBillingSession.keychainAccount(configuration))
            credentialChanges.send(configuration.id)
            return true
        } catch {
            lastError = "Billing connection could not be removed."
            return false
        }
    }
}
