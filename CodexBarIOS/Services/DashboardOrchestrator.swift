import Combine
import Foundation

struct CodexBankedResetRedemptionFeedback: Equatable, Sendable {
    let message: String
    let isSuccess: Bool
    let hidesAction: Bool
    let requiresSameResetForRetry: Bool

    init(
        message: String,
        isSuccess: Bool,
        hidesAction: Bool = false,
        requiresSameResetForRetry: Bool = false
    ) {
        self.message = message
        self.isSuccess = isSuccess
        self.hidesAction = hidesAction
        self.requiresSameResetForRetry = requiresSameResetForRetry
    }
}

@MainActor
final class DashboardOrchestrator: ObservableObject {
    @Published private(set) var autoRefreshSchedule: AutoRefreshSchedule?
    @Published private(set) var autoRefreshResetID = UUID()

    private let refreshService: UsageRefreshService
    private let configurationStore: ProviderConfigurationStore
    private let historyStore: UsageHistoryStore
    private let usageAlertNotifier: any UsageAlertNotifying
    private let appReviewPromptPolicy: AppReviewPromptPolicy
    private let widgetSnapshotCoordinator: WidgetSnapshotCoordinator
    private let watchSnapshotCoordinator: WatchSnapshotCoordinator
    private var lastSystemDateTimeRefresh: ContinuousClock.Instant?
    private var cancellables: Set<AnyCancellable> = []

    init(
        refreshService: UsageRefreshService,
        configurationStore: ProviderConfigurationStore,
        historyStore: UsageHistoryStore,
        usageAlertNotifier: any UsageAlertNotifying,
        appReviewPromptPolicy: AppReviewPromptPolicy,
        widgetSnapshotCoordinator: WidgetSnapshotCoordinator? = nil,
        watchSnapshotCoordinator: WatchSnapshotCoordinator? = nil
    ) {
        self.refreshService = refreshService
        self.configurationStore = configurationStore
        self.historyStore = historyStore
        self.usageAlertNotifier = usageAlertNotifier
        self.appReviewPromptPolicy = appReviewPromptPolicy
        self.widgetSnapshotCoordinator = widgetSnapshotCoordinator ?? WidgetSnapshotCoordinator(
            refreshService: refreshService,
            configurationStore: configurationStore
        )
        self.watchSnapshotCoordinator = watchSnapshotCoordinator ?? WatchSnapshotCoordinator(
            refreshService: refreshService,
            configurationStore: configurationStore
        )

        configurationStore.credentialChanges.sink { [weak refreshService] accountID in
            refreshService?.invalidateCredentials(accountID: accountID)
        }.store(in: &cancellables)
        configurationStore.cursorSameIdentityReconnects.sink { [weak refreshService] accountID in
            refreshService?.invalidateCredentials(accountID: accountID, preserveCachedResult: true)
        }.store(in: &cancellables)
        configurationStore.cursorHistoryInvalidations.sink { [weak historyStore] accountID in
            historyStore?.removeSnapshots(for: accountID)
        }.store(in: &cancellables)
        configurationStore.greptileCredentialUpdates.sink { [weak refreshService, weak historyStore] update in
            if update.identityChanged { historyStore?.removeSnapshots(for: update.accountID) }
            refreshService?.invalidateCredentials(accountID: update.accountID, preserveCachedResult: !update.identityChanged)
        }.store(in: &cancellables)
        configurationStore.grokHistoryInvalidations.sink { [weak historyStore] accountID in
            historyStore?.removeSnapshots(for: accountID)
        }.store(in: &cancellables)
        historyStore.migrateGoogleAccounts(
            links: configurationStore.confirmedGoogleAccountLinks,
            configurations: configurationStore.visibleConfigurations
        )
        configurationStore.$confirmedGoogleAccountLinks.dropFirst().sink { [weak historyStore, weak configurationStore] links in
            historyStore?.migrateGoogleAccounts(
                links: links,
                configurations: configurationStore?.visibleConfigurations ?? []
            )
        }.store(in: &cancellables)
        refreshService.updateCurrentConfigurations(configurationStore.visibleConfigurations)
        refreshService.updateAccountAccess(configurationStore.accountAccess)
        configurationStore.$accountAccess.dropFirst().sink { [weak self] access in
            self?.reconcileAccountAccess(access)
        }.store(in: &cancellables)
        configurationStore.$configurations.dropFirst().sink { [weak refreshService, weak historyStore] in
            let configurations = $0
            refreshService?.updateCurrentConfigurations(configurations)
            historyStore?.removeSnapshotsForMissingAccounts(
                validAccountIDs: Set(configurations.map(\.id))
            )
        }.store(in: &cancellables)
    }

    var dashboardCardItems: [DashboardProviderCardItem] {
        let configurations = configurationStore.visibleConfigurations.filter {
            configurationStore.shouldDisplayOnDashboard($0)
                || ($0.isEnabled && $0.providerID != .codex && !GoogleUsageMetricCatalog.definitions(for: $0.providerID).isEmpty)
        } + GoogleUsageMetricCatalog.missingSourceConfigurations(in: configurationStore.configurations)
        return DashboardProviderCardItem.items(
            configurations: configurations,
            results: displayedResults,
            refreshingAccountIDs: refreshService.refreshingAccountIDs,
            errorsByAccountID: refreshService.refreshErrorsByAccountID,
            orderingMode: configurationStore.dashboardOrderingMode,
            manualOrder: configurationStore.dashboardCardOrder,
            severityThresholds: configurationStore.usageAlertSettings.severityThresholds,
            setupRequiredAccountIDs: Set(configurations.filter { !configurationStore.isConfigured($0) }.map(\.id))
        )
    }

    var dashboardSections: [DashboardSection] {
        var sections: [DashboardSection] = []
        var sectionIndexes: [String: Int] = [:]
        let configurationsByAccountID = Dictionary(
            uniqueKeysWithValues: configurationStore.configurations.map { ($0.id, $0) }
        )
        let groupsByID = Dictionary(
            uniqueKeysWithValues: configurationStore.groups.map { ($0.id, $0) }
        )

        for (offset, item) in dashboardCardItems.enumerated() {
            let configuration = configurationsByAccountID[item.id]
            let groupID = configuration?.groupID ?? DashboardSection.ungroupedID
            let title = configuration?.groupID.flatMap { groupsByID[$0]?.name }
                ?? ProviderAccountGroup.ungroupedDisplayName

            if configurationStore.dashboardOrderingMode == .smart {
                if sections.indices.last.map({ sections[$0].groupID }) == groupID {
                    sections[sections.count - 1].items.append(item)
                } else {
                    sections.append(
                        DashboardSection(
                            id: "\(groupID).\(offset)",
                            groupID: groupID,
                            title: title,
                            items: [item]
                        )
                    )
                }
                continue
            }

            if let sectionIndex = sectionIndexes[groupID] {
                sections[sectionIndex].items.append(item)
            } else {
                sectionIndexes[groupID] = sections.count
                sections.append(DashboardSection(id: groupID, groupID: groupID, title: title, items: [item]))
            }
        }

        return sections
    }

    var currentUsageAlertsByAccountID: [String: [UsageAlertDetail]] {
        guard configurationStore.accountAccess.hasProAccess else { return [:] }
        let evaluation = UsageAlertEvaluator.evaluate(
            results: refreshService.results.filter { result in
                configurationStore.configuration(accountID: result.accountID).map(refreshService.canRefresh) == true
            },
            settings: configurationStore.usageAlertSettings,
            activeAlertIDs: configurationStore.usageAlertActiveIDs
        )
        return Dictionary(grouping: evaluation.activeAlerts, by: \.accountID)
    }

    var isManualDashboardOrdering: Bool {
        configurationStore.dashboardOrderingMode == .manual
    }

    func shouldShowGroupHeaders(for sections: [DashboardSection]) -> Bool {
        !configurationStore.groups.isEmpty && sections.contains { section in
            section.groupID != DashboardSection.ungroupedID || sections.count > 1
        }
    }

    func dashboardStatusText(for result: ProviderUsageResult) -> String {
        if let error = refreshService.refreshErrorsByAccountID[result.accountID] {
            return "Refresh failed - \(error)"
        }

        guard let configuration = configurationStore.configuration(accountID: result.accountID) else {
            return result.subtitle
        }

        if configurationStore.isConfigured(configuration),
           !result.subtitle.localizedCaseInsensitiveContains("not configured") {
            return result.subtitle
        }
        return configurationStore.statusText(for: configuration)
    }

    func moveCard(_ draggedID: String, to targetID: String) {
        guard isManualDashboardOrdering else {
            return
        }

        var orderedIDs = visibleDashboardOrder
        guard
            dashboardGroupID(for: draggedID) == dashboardGroupID(for: targetID),
            let sourceIndex = orderedIDs.firstIndex(of: draggedID),
            let targetIndex = orderedIDs.firstIndex(of: targetID),
            sourceIndex != targetIndex
        else {
            return
        }

        let movedID = orderedIDs.remove(at: sourceIndex)
        orderedIDs.insert(movedID, at: targetIndex)
        persistVisibleCardOrder(orderedIDs)
    }

    func finishCardDrag() {
        guard isManualDashboardOrdering else {
            return
        }
        persistVisibleCardOrder(visibleDashboardOrder)
    }

    func refreshAfterSettingsDismissed() async {
        configurationStore.refreshSecretAvailability()
        _ = await refreshNow()
    }

    func handleSystemDateTimeChange() async {
        let now = ContinuousClock.now
        if let lastSystemDateTimeRefresh,
           lastSystemDateTimeRefresh.duration(to: now) < .seconds(1) {
            return
        }
        lastSystemDateTimeRefresh = now
        _ = await refreshNow()
    }

    func initialRefresh() async {
        watchSnapshotCoordinator.start()
        _ = await refreshNow()
    }

    @discardableResult
    func refreshNow(considerReviewPrompt: Bool = false) async -> Bool {
        await refreshService.refresh(configurations: configurationStore.configurations)
        let processableResults = refreshService.successfulRefreshResults
        await finishRefresh(
            results: processableResults,
            preserving: refreshService.incompleteRefreshAccountIDs
                .subtracting(processableResults.map(\.accountID))
        )

        if configurationStore.autoRefreshInterval.seconds != nil {
            autoRefreshResetID = UUID()
        }

        return considerReviewPrompt && shouldRequestReviewAfterSuccessfulRefresh()
    }

    @discardableResult
    func refreshAccount(_ configuration: ProviderAccountConfiguration) async -> ProviderUsageResult? {
        guard
            let currentConfiguration = configurationStore.configuration(accountID: configuration.id),
            refreshService.canRefresh(currentConfiguration),
            refreshService.hasSameRefreshInputs(configuration, currentConfiguration)
        else {
            return nil
        }
        guard let result = await refreshService.refresh(configuration: currentConfiguration) else {
            return nil
        }
        let successfulResults = refreshService.successfulRefreshResults.filter {
            $0.accountID == currentConfiguration.id
        }
        let preservedAccountIDs = Set(configurationStore.configurations.map(\.id))
            .subtracting(successfulResults.map(\.accountID))
        await finishRefresh(results: successfulResults, preserving: preservedAccountIDs)
        return result
    }

    func loadAccountMetrics(_ configuration: ProviderAccountConfiguration) async -> ProviderUsageResult? {
        guard
            let currentConfiguration = configurationStore.configuration(accountID: configuration.id),
            refreshService.canRefresh(currentConfiguration),
            refreshService.hasSameRefreshInputs(configuration, currentConfiguration)
        else {
            return nil
        }
        if refreshService.refreshingAccountIDs.contains(currentConfiguration.id) {
            return await refreshService.resultAfterCurrentRefresh(configuration: currentConfiguration)
        }
        return await refreshAccount(currentConfiguration)
    }

    func consumeClaudeReset(
        for configuration: ProviderAccountConfiguration,
        grantID: String,
        confirmedGrant: ClaudeUsageResetGrant,
        credentialBinding: String
    ) async -> ClaudeUsageResetFeedback {
        guard let current = configurationStore.configuration(accountID: configuration.id), current.isEnabled,
              refreshService.hasSameRefreshInputs(configuration, current)
        else { return ClaudeUsageResetFeedback(message: "The Claude account changed. Refresh usage before using a reset.", isSuccess: false) }
        let outcome: ClaudeUsageResetOutcome?
        let failure: String?
        do {
            outcome = try await refreshService.consumeClaudeReset(
                for: current, grantID: grantID, confirmedGrant: confirmedGrant, credentialBinding: credentialBinding
            )
            failure = nil
        } catch {
            outcome = nil
            failure = (error as? LocalizedError)?.errorDescription ?? "Claude did not confirm this reset. Refresh usage to check again."
        }
        let refreshed = await refreshAccount(current)
        guard let latest = configurationStore.configuration(accountID: configuration.id), latest.isEnabled,
              refreshService.hasSameRefreshInputs(current, latest)
        else { return ClaudeUsageResetFeedback(message: "The Claude account changed. Refresh usage to check its current state.", isSuccess: false) }
        if let refreshedBinding = refreshed?.claudeUsageResetInventory?.credentialBinding, refreshedBinding != credentialBinding {
            return ClaudeUsageResetFeedback(message: "Claude authorization changed. Check the refreshed account before using another reset.", isSuccess: false)
        }
        let refreshSucceeded = refreshed.map { $0.failureMessage == nil } ?? false
        switch outcome {
        case .reset, .alreadyRedeemed:
            return ClaudeUsageResetFeedback(message: refreshSucceeded
                ? "Claude confirmed the reset. Current usage and saved resets are refreshed."
                : "Claude confirmed the reset, but usage could not be refreshed. Refresh usage to check again.", isSuccess: true)
        case .nothingToReset:
            return ClaudeUsageResetFeedback(message: "Claude reported no applicable usage limit to reset.", isSuccess: false)
        case .noCredit:
            return ClaudeUsageResetFeedback(message: "Claude reported no saved reset available for this account.", isSuccess: false)
        case .stateChanged:
            return ClaudeUsageResetFeedback(
                message: "The saved reset inventory changed. Review the refreshed details before confirming again.",
                isSuccess: false
            )
        case nil:
            return ClaudeUsageResetFeedback(message: failure ?? "Claude did not confirm this reset.", isSuccess: false)
        }
    }

    func consumeCodexBankedReset(
        for configuration: ProviderAccountConfiguration,
        creditID: String?
    ) async -> CodexBankedResetRedemptionFeedback {
        guard let current = configurationStore.configuration(accountID: configuration.id),
              refreshService.canRefresh(current), refreshService.hasSameRefreshInputs(configuration, current) else {
            return CodexBankedResetRedemptionFeedback(message: "Make this account active before using a reset.", isSuccess: false)
        }
        do {
            let outcome = try await refreshService.consumeCodexBankedReset(
                for: configuration,
                creditID: creditID
            )
            let refreshed = await refreshAccount(configuration)
            let refreshSucceeded = refreshed.map { $0.failureMessage == nil } ?? false

            switch outcome {
            case .reset, .alreadyRedeemed:
                return CodexBankedResetRedemptionFeedback(
                    message: refreshSucceeded
                        ? "Reset used. Current usage limits are refreshed."
                        : "Reset used, but current usage could not be refreshed. Try refreshing again.",
                    isSuccess: true
                )
            case .nothingToReset:
                return CodexBankedResetRedemptionFeedback(
                    message: "There is no applicable usage window to reset right now.",
                    isSuccess: false
                )
            case .noCredit:
                return CodexBankedResetRedemptionFeedback(
                    message: "No banked reset remains for this account.",
                    isSuccess: false,
                    hidesAction: true
                )
            }
        } catch {
            let hidesAction = (error as? CodexBankedResetConsumptionError) == .unsupported
            return CodexBankedResetRedemptionFeedback(
                message: (error as? LocalizedError)?.errorDescription
                    ?? "Could not use the reset. Try again.",
                isSuccess: false,
                hidesAction: hidesAction,
                requiresSameResetForRetry: refreshService.hasRetainedCodexResetAttempt(
                    for: configuration.id
                )
            )
        }
    }

    func retainedCodexResetAttempt(
        for configuration: ProviderAccountConfiguration
    ) -> CodexRetainedResetAttempt? {
        guard configuration.providerID == .codex else {
            return nil
        }
        return refreshService.retainedCodexResetAttempt(for: configuration.id)
    }

    func requestAlertAuthorization() async -> Bool {
        guard configurationStore.accountAccess.hasProAccess else { return false }
        return await usageAlertNotifier.requestAuthorization()
    }

    func runAutoRefreshLoop() async {
        guard let interval = configurationStore.autoRefreshInterval.seconds else {
            autoRefreshSchedule = nil
            return
        }

        while !Task.isCancelled {
            let start = Date()
            autoRefreshSchedule = AutoRefreshSchedule(
                start: start,
                end: start.addingTimeInterval(interval)
            )

            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }

            await refreshService.refresh(configurations: configurationStore.configurations)
            let processableResults = refreshService.successfulRefreshResults
            await finishRefresh(
                results: processableResults,
                preserving: refreshService.incompleteRefreshAccountIDs
                    .subtracting(processableResults.map(\.accountID))
            )
        }
    }

    private var displayedResults: [ProviderUsageResult] {
        let cachedIDs = Set(refreshService.results.map(\.accountID))
        // History is a display-only cold-start fallback. Its original observation time is retained,
        // and it never enters successfulRefreshResults, alert evaluation or history recording.
        let pausedFallbacks = configurationStore.visibleConfigurations.compactMap { configuration -> ProviderUsageResult? in
            guard configurationStore.accountAccess.pausedAccountIDs.contains(configuration.id),
                  !cachedIDs.contains(configuration.id) else { return nil }
            return historyStore.lastStoredResult(for: configuration)
        }
        return (refreshService.results + pausedFallbacks).filter { result in
            configurationStore.configuration(accountID: result.accountID)
                .map(configurationStore.shouldDisplayOnDashboard) ?? false
        }
    }

    private var visibleDashboardOrder: [String] {
        dashboardSections.flatMap(\.items).map(\.id)
    }

    private func dashboardGroupID(for accountID: String) -> String {
        configurationStore.configuration(accountID: accountID)?.groupID
            ?? DashboardSection.ungroupedID
    }

    private func persistVisibleCardOrder(_ orderedVisibleIDs: [String]) {
        let visibleIDs = Set(dashboardCardItems.map(\.id))
        let hiddenOrderedIDs = configurationStore.dashboardCardOrder.filter { !visibleIDs.contains($0) }
        configurationStore.updateDashboardCardOrder(orderedVisibleIDs + hiddenOrderedIDs)
    }

    private func finishRefresh(
        results: [ProviderUsageResult],
        preserving preservedAccountIDs: Set<String>
    ) async {
        let titledResults = results.map { result in
            guard result.providerID.usesXAIConsumerAuth else { return result }
            configurationStore.applyVerifiedGrokPlan(result)
            var titled = result
            titled.title = configurationStore.configuration(accountID: result.accountID)?.displayName ?? result.title
            refreshService.updateGrokResultTitle(titled.title, accountID: result.accountID)
            return titled
        }
        historyStore.record(
            results: titledResults,
            severityThresholds: configurationStore.usageAlertSettings.severityThresholds,
            samplingInterval: configurationStore.historySamplingInterval.seconds
        )
        await processUsageAlerts(results: titledResults, preserving: preservedAccountIDs)
    }

    private func shouldRequestReviewAfterSuccessfulRefresh() -> Bool {
        AppReviewPromptEligibility.hasSuccessfulUsage(
            lastRefreshError: refreshService.lastRefreshError,
            results: refreshService.results
        ) && appReviewPromptPolicy.registerSuccessfulRefresh()
    }

    private func reconcileAccountAccess(_ access: AccountPlanAccess) {
        let previouslyEligible = Set(configurationStore.configurations.filter(refreshService.canRefresh).map(\.id))
        refreshService.updateAccountAccess(access)
        let nowEligible = Set(configurationStore.configurations.filter(refreshService.canRefresh).map(\.id))
        guard !nowEligible.subtracting(previouslyEligible).isEmpty else { return }
        // The current batch owns any queued refresh. Canceling its task would also
        // cancel the queued provider work; generations already reject obsolete results.
        Task { [weak self] in
            _ = await self?.refreshNow()
        }
    }

    private func processUsageAlerts(
        results: [ProviderUsageResult],
        preserving preservedAccountIDs: Set<String>
    ) async {
        guard configurationStore.accountAccess.hasProAccess else { return }
        let existingActiveAlertIDs = configurationStore.usageAlertActiveIDs
        let preservedActiveAlertIDs = configurationStore.usageAlertSettings.isEnabled
            ? UsageAlertEvaluator.activeAlertIDs(
                existingActiveAlertIDs,
                belongingTo: preservedAccountIDs,
                knownAccountIDs: Set(configurationStore.configurations.map(\.id))
            )
            : []
        let evaluation = UsageAlertEvaluator.evaluate(
            results: results,
            settings: configurationStore.usageAlertSettings,
            activeAlertIDs: existingActiveAlertIDs,
            knownAccountIDs: Set(configurationStore.configurations.map(\.id))
        )

        var deliveredActiveAlertIDs = preservedActiveAlertIDs.union(evaluation.activeAlertIDs)
        for notification in evaluation.notifications {
            // Recheck after every suspension: an expiry during one delivery stops later notices.
            guard configurationStore.accountAccess.hasProAccess else { return }
            do {
                try await usageAlertNotifier.deliver(notification)
            } catch {
                UsageAlertEvaluator.removeActiveAlertIDs(
                    forFailedDelivery: notification,
                    from: &deliveredActiveAlertIDs,
                    previouslyActiveAlertIDs: existingActiveAlertIDs,
                    knownAccountIDs: Set(configurationStore.configurations.map(\.id))
                )
            }
        }
        guard configurationStore.accountAccess.hasProAccess else { return }
        configurationStore.updateUsageAlertActiveIDs(deliveredActiveAlertIDs)
    }
}

@MainActor
final class WidgetSnapshotCoordinator {
    typealias SnapshotPublisher = @MainActor ([ProviderUsageResult], ProviderConfigurationStore) -> Void
    typealias SettingsPublisher = @MainActor (ProviderConfigurationStore) -> Void

    private let refreshService: UsageRefreshService
    private let configurationStore: ProviderConfigurationStore
    private let publishSnapshot: SnapshotPublisher
    private let publishSettings: SettingsPublisher
    private var cancellables: Set<AnyCancellable> = []
    private var snapshotPublishTask: Task<Void, Never>?
    private var settingsPublishTask: Task<Void, Never>?

    init(
        refreshService: UsageRefreshService,
        configurationStore: ProviderConfigurationStore,
        publishSnapshot: @escaping SnapshotPublisher = { results, store in
            WidgetSnapshotPublisher.publish(results: results, configurationStore: store)
        },
        publishSettings: @escaping SettingsPublisher = { store in
            WidgetSnapshotPublisher.publishSettings(configurationStore: store)
        }
    ) {
        self.refreshService = refreshService
        self.configurationStore = configurationStore
        self.publishSnapshot = publishSnapshot
        self.publishSettings = publishSettings

        refreshService.$results.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)

        configurationStore.$accountAccess.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$configurations.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$dashboardCardOrder.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$dashboardOrderingMode.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$groups.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$metricLayouts.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$usageAlertSettings.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$widgetRefreshInterval.dropFirst().sink { [weak self] _ in
            self?.scheduleSettingsPublish()
        }.store(in: &cancellables)
    }

    func publishCurrentSnapshot() {
        publishSnapshot(refreshService.results, configurationStore)
    }

    private func scheduleSnapshotPublish() {
        snapshotPublishTask?.cancel()
        snapshotPublishTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            self?.publishCurrentSnapshot()
        }
    }

    private func scheduleSettingsPublish() {
        settingsPublishTask?.cancel()
        settingsPublishTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.publishSettings(self.configurationStore)
        }
    }
}

struct AutoRefreshSchedule: Equatable {
    let start: Date
    let end: Date

    func progress(at date: Date) -> Double {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return 1 }
        return min(max(date.timeIntervalSince(start) / duration, 0), 1)
    }

    func remainingSeconds(at date: Date) -> Int {
        max(0, Int(ceil(end.timeIntervalSince(date))))
    }

    func accessibilityDescription(at date: Date) -> String {
        "Next auto refresh in \(formatDuration(remainingSeconds(at: date)))."
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds >= 3_600 {
            let hours = seconds / 3_600
            let minutes = (seconds % 3_600) / 60
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if seconds >= 60 {
            let minutes = seconds / 60
            let remainingSeconds = seconds % 60
            return remainingSeconds > 0 ? "\(minutes)m \(remainingSeconds)s" : "\(minutes)m"
        }
        return "\(seconds)s"
    }
}

struct DashboardSection: Identifiable {
    static let ungroupedID = "__ungrouped"

    let id: String
    let groupID: String
    let title: String
    var items: [DashboardProviderCardItem]
}

struct DashboardProviderCardItem: Identifiable, Equatable {
    let configuration: ProviderAccountConfiguration
    let result: ProviderUsageResult?
    let isRefreshing: Bool
    let errorMessage: String?

    var id: String { configuration.id }
    var recoveryAction: ProviderUsageRecoveryAction {
        result?.recoveryAction ?? .retryRefresh
    }

    static func items(
        configurations: [ProviderAccountConfiguration],
        results: [ProviderUsageResult],
        refreshingAccountIDs: Set<String>,
        errorsByAccountID: [String: String],
        orderingMode: DashboardOrderingMode,
        manualOrder: [String],
        severityThresholds: UsageSeverityThresholds = .default,
        setupRequiredAccountIDs: Set<String> = []
    ) -> [DashboardProviderCardItem] {
        let resultsByAccountID = Dictionary(uniqueKeysWithValues: results.map { ($0.accountID, $0) })
        let items = configurations.map { configuration in
            DashboardProviderCardItem(
                configuration: configuration,
                result: dashboardResult(
                    for: configuration,
                    observed: resultsByAccountID[configuration.id],
                    requiresSetup: setupRequiredAccountIDs.contains(configuration.id),
                    isRefreshing: refreshingAccountIDs.contains(configuration.id),
                    errorMessage: errorsByAccountID[configuration.id]
                ),
                isRefreshing: refreshingAccountIDs.contains(configuration.id),
                errorMessage: errorsByAccountID[configuration.id]
            )
        }
        let itemsByAccountID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let orderingResults = items.map { item in
            item.result ?? ProviderUsageResult(
                accountID: item.id,
                providerID: item.configuration.providerID,
                title: item.configuration.displayName,
                subtitle: "Loading current usage",
                bars: [],
                fetchedAt: .distantPast
            )
        }

        return DashboardUsageSorter.orderedResults(
            orderingResults,
            mode: orderingMode,
            manualOrder: manualOrder,
            severityThresholds: severityThresholds
        ).compactMap { itemsByAccountID[$0.accountID] }
    }

    private static func dashboardResult(
        for configuration: ProviderAccountConfiguration,
        observed: ProviderUsageResult?,
        requiresSetup: Bool,
        isRefreshing: Bool,
        errorMessage: String?
    ) -> ProviderUsageResult? {
        let definitions = GoogleUsageMetricCatalog.definitions(for: configuration.providerID)
        if configuration.providerID.usesXAIConsumerAuth, var observed {
            observed.title = configuration.displayName
            return observed
        }
        guard configuration.providerID != .codex, !definitions.isEmpty, observed == nil || requiresSetup else { return observed }
        let status = requiresSetup ? "Setup required" : (isRefreshing ? "Loading" : "Unavailable")
        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: configuration.providerID,
            title: configuration.displayName,
            subtitle: requiresSetup ? "\(configuration.providerID.displayName) setup required" : (errorMessage ?? status),
            bars: [],
            unavailableUsageMetrics: Dictionary(uniqueKeysWithValues: definitions.map {
                ($0.id, status)
            }),
            failureMessage: requiresSetup ? status : errorMessage,
            recoveryAction: requiresSetup ? .signIn : .retryRefresh,
            hasSuccessfulRefreshHistory: false,
            fetchedAt: .distantPast
        )
    }
}

struct DashboardClaudeAuthenticationState: Equatable {
    var isSigningIn = false
    var statusMessage: String?
    var errorMessage: String?
}

struct DashboardPresentedAuthURL: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
final class DashboardClaudeAuthenticationController: ObservableObject {
    typealias Authenticate = @MainActor (
        _ presentAuthorizationURL: @escaping @MainActor (URL) -> Void,
        _ reportStage: @escaping @MainActor (String) -> Void,
        _ didReceiveCallback: @escaping @MainActor () -> Void
    ) async throws -> ClaudeWebAuthResult
    typealias RefreshAccount = @MainActor (
        _ configuration: ProviderAccountConfiguration
    ) async -> ProviderUsageResult?

    @Published var authURL: DashboardPresentedAuthURL?
    @Published private(set) var statesByAccountID: [String: DashboardClaudeAuthenticationState] = [:]

    private let configurationStore: ProviderConfigurationStore
    private let authenticate: Authenticate
    private let refreshAccount: RefreshAccount
    private var activeAccountID: String?
    private var authenticationTask: Task<Void, Never>?
    private var isAwaitingBrowserCallback = false

    init(
        configurationStore: ProviderConfigurationStore,
        authenticate: @escaping Authenticate = { presentAuthorizationURL, reportStage, didReceiveCallback in
            try await ClaudeWebAuthService().signIn(
                presentAuthorizationURL: presentAuthorizationURL,
                reportStage: reportStage,
                didReceiveCallback: didReceiveCallback
            )
        },
        refreshAccount: @escaping RefreshAccount
    ) {
        self.configurationStore = configurationStore
        self.authenticate = authenticate
        self.refreshAccount = refreshAccount
    }

    @discardableResult
    func startSignIn(for configuration: ProviderAccountConfiguration) -> Bool {
        guard configuration.providerID == .claude, authenticationTask == nil else {
            return false
        }

        activeAccountID = configuration.id
        isAwaitingBrowserCallback = false
        statesByAccountID[configuration.id] = DashboardClaudeAuthenticationState(
            isSigningIn: true,
            statusMessage: "Starting Claude sign-in...",
            errorMessage: nil
        )
        authenticationTask = Task { [weak self] in
            await self?.performSignIn(accountID: configuration.id)
        }
        return true
    }

    func cancelAuthentication() {
        guard
            let activeAccountID,
            statesByAccountID[activeAccountID]?.isSigningIn == true,
            isAwaitingBrowserCallback
        else {
            return
        }
        authenticationTask?.cancel()
        authURL = nil
    }

    func state(for accountID: String) -> DashboardClaudeAuthenticationState {
        statesByAccountID[accountID] ?? DashboardClaudeAuthenticationState()
    }

    func waitForAuthenticationToFinish() async {
        await authenticationTask?.value
    }

    private func performSignIn(accountID: String) async {
        guard configurationStore.configuration(accountID: accountID) != nil else {
            finish(
                accountID: accountID,
                statusMessage: nil,
                errorMessage: "This Claude account is no longer available."
            )
            return
        }

        do {
            let result = try await authenticate(
                { [weak self] url in
                    guard self?.activeAccountID == accountID else { return }
                    self?.isAwaitingBrowserCallback = true
                    self?.authURL = DashboardPresentedAuthURL(url: url)
                },
                { [weak self] message in
                    self?.updateStatus(message, accountID: accountID)
                },
                { [weak self] in
                    guard self?.activeAccountID == accountID else { return }
                    self?.isAwaitingBrowserCallback = false
                    self?.authURL = nil
                }
            )
            try Task.checkCancellation()

            guard var currentConfiguration = configurationStore.configuration(accountID: accountID) else {
                finish(
                    accountID: accountID,
                    statusMessage: nil,
                    errorMessage: "This Claude account is no longer available."
                )
                return
            }
            currentConfiguration.authMethod = .browserSession
            guard configurationStore.replaceCredential(
                result.storedCredential,
                for: currentConfiguration
            ) else {
                finish(
                    accountID: accountID,
                    statusMessage: nil,
                    errorMessage: configurationStore.lastError
                        ?? "Claude sign-in completed, but the replacement credential could not be saved."
                )
                return
            }

            updateStatus("Claude sign-in complete. Refreshing usage...", accountID: accountID)
            let savedConfiguration = configurationStore.configuration(accountID: accountID)
                ?? currentConfiguration
            _ = await refreshAccount(savedConfiguration)
            finish(
                accountID: accountID,
                statusMessage: "Claude sign-in complete.",
                errorMessage: nil
            )
        } catch is CancellationError {
            finish(
                accountID: accountID,
                statusMessage: nil,
                errorMessage: "Claude sign-in canceled. The existing credential was not changed."
            )
        } catch {
            finish(
                accountID: accountID,
                statusMessage: nil,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func updateStatus(_ message: String, accountID: String) {
        guard activeAccountID == accountID else { return }
        statesByAccountID[accountID] = DashboardClaudeAuthenticationState(
            isSigningIn: true,
            statusMessage: message,
            errorMessage: nil
        )
    }

    private func finish(
        accountID: String,
        statusMessage: String?,
        errorMessage: String?
    ) {
        statesByAccountID[accountID] = DashboardClaudeAuthenticationState(
            isSigningIn: false,
            statusMessage: statusMessage,
            errorMessage: errorMessage
        )
        activeAccountID = nil
        authenticationTask = nil
        isAwaitingBrowserCallback = false
        authURL = nil
    }
}
