import Foundation
import StoreKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    @ObservedObject var refreshService: UsageRefreshService
    @ObservedObject var configurationStore: ProviderConfigurationStore
    @ObservedObject var historyStore: UsageHistoryStore
    @ObservedObject var appUpdateController: AppUpdateController
    @ObservedObject var githubStatusPreferences: GitHubStatusPreferences
    @ObservedObject var githubStatusMonitor: GitHubStatusMonitor
    @StateObject private var orchestrator: DashboardOrchestrator
    @StateObject private var claudeAuthenticationController: DashboardClaudeAuthenticationController
    private let performsLifecycleWork: Bool
    @Environment(\.originalPurchaserNotice) private var originalPurchaserNotice

    @Environment(\.requestReview) private var requestReview
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isShowingSettings = false
    @State private var addAccountFlowRequest: AddAccountFlowRequest?
    @State private var addAccountRefreshState = AddAccountRefreshState()
    @State private var selectedHistoryResult: ProviderUsageResult?
    @State private var accountConfigurationNavigation =
        DashboardAccountConfigurationNavigationState()
    @State private var draggedCardID: String?
    @State private var deepLinkNavigation = DashboardDeepLinkNavigationState()
    @State private var hasCompletedInitialRefresh = false
    @State private var settingsRefreshCompletionID = UUID()
    @State private var settingsDismissalRefreshState = SettingsDismissalRefreshState()
    @State private var dashboardSettingsChangedAccountIDs: Set<String> = []
    @State private var isConfirmingHistoryReset = false
    @State private var problemReportPresentation: PrivacySafeDiagnosticContext?

    init(
        refreshService: UsageRefreshService,
        configurationStore: ProviderConfigurationStore,
        historyStore: UsageHistoryStore,
        appUpdateController: AppUpdateController,
        githubStatusPreferences: GitHubStatusPreferences,
        githubStatusMonitor: GitHubStatusMonitor,
        usageAlertNotifier: (any UsageAlertNotifying)? = nil,
        appReviewPromptPolicy: AppReviewPromptPolicy = AppReviewPromptPolicy(),
        performsLifecycleWork: Bool = true,
        entitlement: ProEntitlement? = nil,
        widgetSnapshotCoordinator: WidgetSnapshotCoordinator? = nil,
        watchSnapshotCoordinator: WatchSnapshotCoordinator? = nil
    ) {
        self.refreshService = refreshService
        self.configurationStore = configurationStore
        self.historyStore = historyStore
        self.appUpdateController = appUpdateController
        self.githubStatusPreferences = githubStatusPreferences
        self.githubStatusMonitor = githubStatusMonitor
        self.performsLifecycleWork = performsLifecycleWork
        let orchestrator = DashboardOrchestrator(
            refreshService: refreshService,
            configurationStore: configurationStore,
            historyStore: historyStore,
            usageAlertNotifier: usageAlertNotifier ?? LocalUsageAlertNotifier.shared,
            appReviewPromptPolicy: appReviewPromptPolicy,
            entitlement: entitlement,
            widgetSnapshotCoordinator: widgetSnapshotCoordinator,
            watchSnapshotCoordinator: watchSnapshotCoordinator
        )
        self._orchestrator = StateObject(
            wrappedValue: orchestrator
        )
        self._claudeAuthenticationController = StateObject(
            wrappedValue: DashboardClaudeAuthenticationController(
                configurationStore: configurationStore,
                refreshAccount: { [weak orchestrator] configuration in
                    await orchestrator?.refreshAccount(configuration)
                }
            )
        )
    }

    private var usesLazyDashboard: Bool {
        DashboardCardGridLayout.usesLazyLayout(idiom: UIDevice.current.userInterfaceIdiom)
    }

    var body: some View {
        let cardItems = orchestrator.dashboardCardItems
        let sections = orchestrator.dashboardSections
        let showGroupHeaders = orchestrator.shouldShowGroupHeaders(for: sections)
        let usageAlertsByAccountID = orchestrator.currentUsageAlertsByAccountID
        let emptyState = DashboardEmptyState.resolve(
            hasAccounts: !configurationStore.visibleConfigurations.isEmpty,
            hasEnabledAccounts: configurationStore.visibleConfigurations.contains(where: \.isEnabled),
            needsSetupAccountID: configurationStore.visibleConfigurations.first(where: {
                $0.isEnabled && !configurationStore.isConfigured($0)
            })?.id,
            cardsAreEmpty: cardItems.isEmpty,
            hasCompletedInitialRefresh: hasCompletedInitialRefresh,
            performsLifecycleWork: performsLifecycleWork,
            isPersistenceRecoveryRequired: configurationStore.isPersistenceRecoveryRequired,
            hasIncompleteAccountReset: configurationStore.hasIncompleteAccountReset
        )

        NavigationStack {
            GeometryReader { geometry in
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        DashboardStack(isLazy: usesLazyDashboard) {
                            if emptyState == .hidden, let originalPurchaserNotice {
                                OriginalPurchaserNoticeView(notice: originalPurchaserNotice)
                            }
                            if let historyError = historyStore.lastError {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(historyError, systemImage: "exclamationmark.triangle.fill")
                                        .font(.footnote)
                                        .foregroundStyle(.red)
                                        .accessibilityIdentifier("usage-history-persistence-error")

                                    if historyStore.requiresRecovery {
                                        Button("Reset History", role: .destructive) {
                                            isConfirmingHistoryReset = true
                                        }
                                        .buttonStyle(.bordered)
                                        .accessibilityIdentifier("reset-corrupted-usage-history")
                                    }
                                }
                            }

                            if let snapshot = visibleGitHubStatusSnapshot {
                                TimelineView(.periodic(
                                    from: snapshot.checkedAt,
                                    by: GitHubStatusFreshness.timelineRefreshInterval
                                )) { context in
                                    GitHubStatusBanner(
                                        snapshot: snapshot,
                                        isStale: GitHubStatusFreshness.isStale(
                                            snapshot,
                                            interval: githubStatusPreferences.settings.pollingInterval,
                                            now: context.date
                                        ),
                                        statusCheckFailed: githubStatusPreferences.lastError != nil,
                                        onDismiss: githubStatusPreferences.dismissCurrentBanner
                                    )
                                }
                            }

                            if !cardItems.isEmpty,
                               let release = appUpdateController.dashboardRelease {
                                AppUpdateNotice(
                                    release: release,
                                    onDismiss: appUpdateController.dismissDashboardNotice
                                )
                            }

                            if !cardItems.isEmpty {
                                TimelineView(.periodic(from: .now, by: 60)) { context in
                                    let entries = cardItems.filter { $0.configuration.isEnabled }.compactMap {
                                        $0.result.flatMap { SubscriptionUtilizationFleet.entry(for: $0, at: context.date) }
                                    }
                                    HStack {
                                        SubscriptionUtilizationBadge(score: SubscriptionUtilizationFleet.score(entries: entries), title: "Fleet SUS")
                                        Spacer()
                                        Text("Weekly utilization").font(.caption).foregroundStyle(.secondary)
                                    }
                                    .accessibilityIdentifier("fleet-sus")
                                    .accessibilityHint("Price-weighted mean of weekly subscription scores. Equal weights when any monthly price is unknown.")
                                    .padding(.horizontal, 4)
                                }
                            }

                            ForEach(sections) { section in
                                let hasCollapsedCard = section.items.contains { item in
                                    guard let accountID = item.result?.accountID else {
                                        return false
                                    }
                                    return configurationStore.isDashboardCardCollapsed(
                                        accountID: accountID
                                    )
                                }
                                let columnCount = DashboardCardGridLayout.columnCount(
                                    containerWidth: geometry.size.width,
                                    idiom: UIDevice.current.userInterfaceIdiom,
                                    dynamicTypeSize: dynamicTypeSize,
                                    hasCollapsedCard: hasCollapsedCard
                                )

                                VStack(alignment: .leading, spacing: 8) {
                                    if showGroupHeaders {
                                        Text(section.title)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .textCase(.uppercase)
                                            .padding(.horizontal, 4)
                                    }

                                    DashboardCardGrid(isLazy: usesLazyDashboard, columnCount: columnCount) {
                                        ForEach(section.items) { item in
                                            let card = dashboardCard(
                                                for: item,
                                                alerts: usageAlertsByAccountID[item.id] ?? []
                                            )

                                            if orchestrator.isManualDashboardOrdering {
                                                card
                                                    .frame(
                                                        maxWidth: .infinity,
                                                        alignment: .topLeading
                                                    )
                                                    .id(item.id)
                                                    .onDrag {
                                                        draggedCardID = item.id
                                                        return NSItemProvider(
                                                            object: item.id as NSString
                                                        )
                                                    }
                                                    .onDrop(
                                                        of: [UTType.text],
                                                        delegate: ProviderUsageCardDropDelegate(
                                                            targetID: item.id,
                                                            draggedCardID: $draggedCardID,
                                                            moveCard: moveCard,
                                                            finishDrag: finishCardDrag
                                                        )
                                                    )
                                                    .modifier(
                                                        DashboardCardReorderActions(
                                                            canMoveEarlier:
                                                                section.items.first?.id != item.id,
                                                            canMoveLater:
                                                                section.items.last?.id != item.id,
                                                            moveEarlier: {
                                                                moveCard(
                                                                    item.id,
                                                                    within: section.items,
                                                                    offset: -1
                                                                )
                                                            },
                                                            moveLater: {
                                                                moveCard(
                                                                    item.id,
                                                                    within: section.items,
                                                                    offset: 1
                                                                )
                                                            }
                                                        )
                                                    )
                                            } else {
                                                card
                                                    .frame(
                                                        maxWidth: .infinity,
                                                        alignment: .topLeading
                                                    )
                                                    .id(item.id)
                                                    .accessibilityHint(
                                                        Text("Smart ordering is active.")
                                                    )
                                            }
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding()
                    }
                    .background(Color(.systemGroupedBackground))
                    .onOpenURL { url in
                        if CodexBarDeepLink.isProURL(url) {
                            configurationStore.requestProPresentation()
                            return
                        }
                        handleDeepLink(
                            url,
                            scrollProxy: scrollProxy,
                            availableAccountIDs: cardItems.map(\.id)
                        )
                    }
                    .onChange(of: cardItems.map(\.id)) { _, accountIDs in
                        configurationStore.updateAccountAccessOrder(accountIDs)
                        scrollToPendingDeepLink(
                            scrollProxy: scrollProxy,
                            availableAccountIDs: accountIDs,
                            completesNavigation: false
                        )
                    }
                    .onChange(of: refreshService.isRefreshing) { _, isRefreshing in
                        guard !isRefreshing, deepLinkNavigation.waitsForRefresh else {
                            return
                        }
                        scrollToPendingDeepLink(
                            scrollProxy: scrollProxy,
                            availableAccountIDs: cardItems.map(\.id),
                            completesNavigation: true
                        )
                    }
                    .onChange(of: hasCompletedInitialRefresh) { _, hasCompletedInitialRefresh in
                        guard
                            hasCompletedInitialRefresh,
                            !refreshService.isRefreshing,
                            deepLinkNavigation.waitsForRefresh
                        else {
                            return
                        }
                        scrollToPendingDeepLink(
                            scrollProxy: scrollProxy,
                            availableAccountIDs: cardItems.map(\.id),
                            completesNavigation: true
                        )
                    }
                    .onChange(of: settingsRefreshCompletionID) { _, _ in
                        guard deepLinkNavigation.waitsForRefresh else {
                            return
                        }
                        scrollToPendingDeepLink(
                            scrollProxy: scrollProxy,
                            availableAccountIDs: cardItems.map(\.id),
                            completesNavigation: true
                        )
                    }
                }
            }
            .navigationTitle("CodexBar")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Open settings")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            if await orchestrator.refreshNow(considerReviewPrompt: true) {
                                requestReview()
                            }
                        }
                    } label: {
                        RefreshButtonLabel(
                            isRefreshing: refreshService.isRefreshing,
                            schedule: orchestrator.autoRefreshSchedule
                        )
                    }
                    .disabled(refreshService.isRefreshing)
                    .accessibilityLabel(refreshAccessibilityLabel)
                }
            }
            .overlay {
                if emptyState != .hidden {
                    GeometryReader { geometry in
                        ScrollView {
                            VStack(spacing: 16) {
                                if let originalPurchaserNotice {
                                    OriginalPurchaserNoticeView(notice: originalPurchaserNotice)
                                }
                                if let release = appUpdateController.dashboardRelease {
                                    AppUpdateNotice(
                                        release: release,
                                        onDismiss: appUpdateController.dismissDashboardNotice
                                    )
                                }

                                dashboardEmptyStateView(emptyState)
                            }
                            .padding()
                            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                        }
                    }
                }
            }
        }
        .accountPlanPresentation(
            configurationStore: configurationStore,
            usageResultForAccount: lastKnownResult,
            isActive: !isShowingSettings && addAccountFlowRequest == nil
                && accountConfigurationNavigation.presentation == nil && selectedHistoryResult == nil
                && problemReportPresentation == nil && claudeAuthenticationController.authURL == nil
        )
        .sheet(
            isPresented: $isShowingSettings,
            onDismiss: {
                let refreshAction = settingsDismissalRefreshState.finishDismissal()
                Task {
                    switch refreshAction {
                    case .allAccounts:
                        await orchestrator.refreshAfterSettingsDismissed()
                    case .accounts(let accountIDs):
                        configurationStore.refreshSecretAvailability()
                        for accountID in accountIDs.sorted() {
                            guard let configuration = configurationStore.configuration(accountID: accountID) else {
                                continue
                            }
                            _ = await orchestrator.refreshAccount(configuration)
                        }
                    case .none:
                        configurationStore.refreshSecretAvailability()
                    }
                    settingsRefreshCompletionID = UUID()
                }
            },
            content: {
                SettingsView(
                    configurationStore: configurationStore,
                    appUpdateController: appUpdateController,
                    githubStatusPreferences: githubStatusPreferences,
                    onAccountsChanged: {
                        Task {
                            _ = await orchestrator.refreshNow()
                        }
                    },
                    onCredentialsChanged: { accountID in
                        settingsDismissalRefreshState.credentialsChanged(accountID: accountID)
                    },
                    onRefreshInputsChanged: { accountID in
                        settingsDismissalRefreshState.refreshInputsChanged(accountID: accountID)
                    },
                    onAccountIdentityChanged: { accountID in
                        historyStore.removeSnapshots(for: accountID)
                    },
                    usageResultForAccount: lastKnownResult,
                    onAccountRefresh: { configuration in
                        await orchestrator.loadAccountMetrics(configuration)
                    },
                    onCredentialRefresh: { configuration in
                        await orchestrator.refreshAccount(configuration)
                    },
                    onAlertAuthorizationRequest: {
                        await orchestrator.requestAlertAuthorization()
                    },
                    onGitHubStatusRefresh: {
                        await githubStatusMonitor.refreshIfDue(force: true)
                    }
                )
            }
        )
        .sheet(
            item: $addAccountFlowRequest,
            onDismiss: {
                guard let accountID = addAccountRefreshState.finishDismissal() else {
                    return
                }
                Task {
                    await refreshAccount(accountID: accountID)
                }
            },
            content: { _ in
            AddAccountSetupFlow(
                configurationStore: configurationStore,
                onAccountCreated: { accountID in
                    addAccountRefreshState.accountCreated(accountID)
                },
                onCredentialsChanged: { _ in
                    _ = addAccountRefreshState.credentialsChanged()
                },
                onRefreshInputsChanged: { _ in
                    addAccountRefreshState.refreshInputsChanged()
                },
                onAccountRefresh: { configuration in
                    await orchestrator.loadAccountMetrics(configuration)
                },
                onCredentialRefresh: { configuration in
                    await orchestrator.refreshAccount(configuration)
                }
                )
            }
        )
        .sheet(
            item: accountConfigurationPresentation,
            onDismiss: {
                finishDashboardAccountSettings()
            },
            content: { presentation in
            NavigationStack {
                ProviderSettingsView(
                    configurationStore: configurationStore,
                    accountID: presentation.accountID,
                    initialUsageResult: orchestrator.dashboardCardItems.first {
                        $0.id == presentation.accountID
                    }?.result,
                    startsCursorSignIn: presentation.startsCursorSignIn,
                    onCredentialsChanged: { accountID in
                        dashboardSettingsChangedAccountIDs.insert(accountID)
                        if accountID == presentation.accountID { accountConfigurationNavigation.credentialsChanged() }
                    },
                    onRefreshInputsChanged: { accountID in
                        dashboardSettingsChangedAccountIDs.insert(accountID)
                        if accountID == presentation.accountID { accountConfigurationNavigation.refreshInputsChanged() }
                    },
                    onAccountIdentityChanged: { accountID in
                        historyStore.removeSnapshots(for: accountID)
                    },
                    onAccountRefresh: { configuration in
                        await orchestrator.loadAccountMetrics(configuration)
                    },
                    onCredentialRefresh: { configuration in
                        await orchestrator.refreshAccount(configuration)
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            accountConfigurationNavigation.clearPresentation()
                        }
                    }
                }
                }
            }
        )
        .sheet(item: $selectedHistoryResult) { result in
            LiveProviderUsageHistoryDetailView(
                result: result,
                historyStore: historyStore,
                configurationStore: configurationStore
            )
        }
        .sheet(item: $problemReportPresentation) { context in
            DiagnosticReportView(context: context)
        }
        .sheet(
            item: $claudeAuthenticationController.authURL,
            onDismiss: claudeAuthenticationController.cancelAuthentication
        ) { authURL in
            SafariAuthSheet(url: authURL.url)
        }
        .confirmationDialog(
            "Reset unreadable usage history?",
            isPresented: $isConfirmingHistoryReset,
            titleVisibility: .visible
        ) {
            Button("Reset History", role: .destructive) {
                historyStore.discardCorruptedHistory()
            }
        } message: {
            Text("This permanently discards the unreadable history so new usage can be recorded.")
        }
        .task {
            guard performsLifecycleWork else {
                return
            }
            await appUpdateController.checkForUpdates()
        }
        .task {
            guard performsLifecycleWork else {
                return
            }
            await orchestrator.initialRefresh()
            hasCompletedInitialRefresh = true
        }
        .task(id: AutoRefreshTaskID(
            interval: configurationStore.autoRefreshInterval,
            resetID: orchestrator.autoRefreshResetID
        )) {
            guard performsLifecycleWork else {
                return
            }
            await orchestrator.runAutoRefreshLoop()
        }
        .task(id: githubStatusPreferences.settings) {
            guard performsLifecycleWork else { return }
            await githubStatusMonitor.runForegroundLoop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            guard performsLifecycleWork else { return }
            Task { await orchestrator.handleSystemDateTimeChange() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            guard performsLifecycleWork else { return }
            Task { await orchestrator.handleSystemDateTimeChange() }
        }
        .environment(
            \.usageSeverityThresholds,
            configurationStore.usageAlertSettings.severityThresholds
        )
        .environment(\.accountLastResultProvider, lastKnownResult)
    }

    private func lastKnownResult(accountID: String) -> ProviderUsageResult? {
        refreshService.results.first { $0.accountID == accountID }
            ?? configurationStore.configuration(accountID: accountID).flatMap {
                historyStore.lastStoredResult(for: $0)
            }
    }

    private var visibleGitHubStatusSnapshot: GitHubServiceStatusSnapshot? {
        guard githubStatusPreferences.settings.isEnabled,
              githubStatusPreferences.settings.showsInAppBanner,
              let snapshot = githubStatusPreferences.snapshot,
              snapshot.isActive,
              snapshot.bannerIdentity != githubStatusPreferences.dismissedBannerIdentity
        else {
            return nil
        }
        return snapshot
    }

    @ViewBuilder
    private func dashboardEmptyStateView(_ state: DashboardEmptyState) -> some View {
        switch state {
        case .hidden:
            EmptyView()
        case .loading:
            ProgressView("Loading accounts…")
                .accessibilityIdentifier("dashboard-account-loading")
        case .recovery:
            ContentUnavailableView {
                Label("Account Data Needs Attention", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Open Settings to recover your saved account or group data.")
            } actions: {
                Button("Open Settings") {
                    isShowingSettings = true
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Opens account data recovery options.")
            }
        case .accountResetRecovery:
            ContentUnavailableView {
                Label("Account Reset Needs Attention", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Open Settings to retry credential cleanup before adding another account.")
            } actions: {
                Button("Open Settings") {
                    isShowingSettings = true
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Opens account reset recovery options.")
            }
        case .firstAccount:
            ContentUnavailableView {
                Label("Connect your first account", systemImage: "person.crop.circle.badge.plus")
            } description: {
                Text("Add an AI provider to see usage, reset times, and balances in one place.")
            } actions: {
                Button {
                    addAccountFlowRequest = AddAccountFlowRequest()
                } label: {
                    Label("Add Account", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Opens the list of supported AI providers.")
                .accessibilityIdentifier("dashboard-add-account")
            }
        case let .needsSetup(accountID):
            ContentUnavailableView {
                Label("Account Needs Setup", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text("Finish connecting your account to start seeing live usage.")
            } actions: {
                Button("Continue Setup") {
                    accountConfigurationNavigation.present(accountID: accountID)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Opens setup for the account that needs attention.")
            }
        case .accountsDisabled:
            ContentUnavailableView {
                Label("Accounts Are Disabled", systemImage: "pause.circle")
            } description: {
                Text("Enable an account in Settings to resume usage tracking.")
            } actions: {
                Button("Open Settings") {
                    isShowingSettings = true
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Opens Settings where accounts can be enabled.")
            }
        case .noUsageData:
            ContentUnavailableView(
                "No Usage Data",
                systemImage: "gauge.with.dots.needle.50percent",
                description: Text("Refresh your accounts to load current usage.")
            )
        }
    }

    static func metricLayoutCopyDestination(
        _ destination: DashboardProviderCardItem,
        from source: ProviderUsageResult,
        configurationStore: ProviderConfigurationStore
    ) -> MetricLayoutCopyDestination? {
        guard destination.id != source.accountID, destination.configuration.providerID == source.providerID else { return nil }
        let metricIDs = GoogleUsageMetricCatalog.layoutCopyMetricIDs(
            for: destination.configuration.providerID, result: destination.result
        )
        guard !metricIDs.isEmpty else { return nil }
        return MetricLayoutCopyDestination(
            id: destination.id, title: destination.configuration.displayName, availableMetricIDs: metricIDs,
            hasCustomLayout: configurationStore.isMetricLayoutCustomized(accountID: destination.id, availableMetricIDs: metricIDs)
        )
    }

    @ViewBuilder
    private func dashboardCard(
        for item: DashboardProviderCardItem,
        alerts: [UsageAlertDetail]
    ) -> some View {
        let authenticationState = claudeAuthenticationController.state(for: item.id)
        let reportContext = problemReportContext(for: item)
        let onReportProblem = reportContext.map { context in
            {
                problemReportPresentation = context
            }
        }

        if let result = item.result {
            ProviderUsageCard(
                result: result,
                statusText: orchestrator.dashboardStatusText(for: result),
                showsSubscriptionRenewals: configurationStore.showsSubscriptionRenewals,
                history: historyStore.historySeries(
                    for: result,
                    severityThresholds:
                        configurationStore.usageAlertSettings.severityThresholds
                ),
                historyAccessPolicy: historyStore.accessPolicy,
                alerts: alerts,
                isHistoryEnabled: item.configuration.showsHistory,
                isRefreshing: item.isRefreshing,
                isPausedByPlan: configurationStore.accountAccess.isPaused(accountID: item.id),
                onMakeActive: configurationStore.requestActiveAccountChoice,
                isExpanded: !configurationStore.isDashboardCardCollapsed(accountID: result.accountID),
                refreshErrorMessage: item.errorMessage,
                recoveryAction: item.recoveryAction,
                isPerformingRecovery: authenticationState.isSigningIn,
                recoveryStatusMessage: authenticationState.statusMessage,
                recoveryErrorMessage: authenticationState.errorMessage,
                onReportProblem: onReportProblem,
                onShowHistory: { selectedHistoryResult = result },
                onToggleExpansion: { toggleDashboardCardExpansion(result.accountID) },
                onConfigureAccount: {
                    configureDashboardAccount(item.configuration)
                },
                onRetry: {
                    performRecovery(for: item)
                },
                retainedCodexResetAttempt: orchestrator.retainedCodexResetAttempt(
                    for: item.configuration
                ),
                onUseClaudeReset: { grant, binding in
                    await orchestrator.consumeClaudeReset(for: item.configuration, grantID: grant.id, confirmedGrant: grant, credentialBinding: binding)
                },
                onUseCodexReset: { creditID in
                    await orchestrator.consumeCodexBankedReset(
                        for: item.configuration,
                        creditID: creditID
                    )
                },
                isMetricVisible: { metricID in
                    configurationStore.isMetricVisible(
                        accountID: result.accountID,
                        metricID: metricID
                    )
                },
                onUpdateMetricVisibility: { metricID, isVisible in
                    configurationStore.updateMetricVisibility(
                        isVisible,
                        accountID: result.accountID,
                        metricID: metricID
                    )
                },
                watchVisibilityForMetric: { metricID in
                    configurationStore.watchVisibilityPolicy(
                        accountID: result.accountID,
                        metricID: metricID
                    )
                },
                onUpdateWatchVisibility: { metricID, policy in
                    configurationStore.updateWatchMetricVisibility(
                        policy,
                        accountID: result.accountID,
                        metricID: metricID
                    )
                },
                visualizationStyleForMetric: { metricID in
                    configurationStore.visualizationStyle(
                        accountID: result.accountID,
                        metricID: metricID
                    )
                },
                onUpdateVisualizationStyle: { metricID, style in
                    configurationStore.updateVisualizationStyle(
                        style,
                        accountID: result.accountID,
                        metricID: metricID
                    )
                },
                onApplyVisualizationStyleToAll: { style, metricIDs in
                    configurationStore.applyVisualizationStyle(
                        style,
                        accountID: result.accountID,
                        metricIDs: metricIDs
                    )
                },
                onResetVisualizationStyles: { metricIDs in
                    configurationStore.resetVisualizationStyles(
                        accountID: result.accountID,
                        metricIDs: metricIDs
                    )
                },
                metricOrder: configurationStore.metricLayouts[result.accountID]?.orderedMetricIDs ?? [],
                metricWidthForMetric: { metricID in
                    configurationStore.metricWidth(
                        accountID: result.accountID,
                        metricID: metricID
                    )
                },
                onUpdateMetricWidth: { metricID, width in
                    configurationStore.updateMetricWidth(
                        width,
                        accountID: result.accountID,
                        metricID: metricID
                    )
                },
                metricLayout: {
                    configurationStore.metricLayouts[result.accountID]
                        ?? AccountMetricLayout(orderedMetricIDs: result.availableMetrics.map(\.id))
                },
                isMetricNewlyDiscovered: { metricID in
                    configurationStore.isMetricNewlyDiscovered(
                        accountID: result.accountID,
                        metricID: metricID
                    )
                },
                onUpdateMetricOrder: { metricIDs in
                    configurationStore.updateMetricOrder(
                        metricIDs,
                        accountID: result.accountID
                    )
                },
                onReplaceMetricLayout: { layout in
                    configurationStore.replaceMetricLayout(
                        layout,
                        accountID: result.accountID
                    )
                },
                onResetMetricLayout: { metricIDs in
                    configurationStore.resetMetricLayout(
                        accountID: result.accountID,
                        availableMetricIDs: metricIDs
                    )
                },
                copyLayoutDestinations: {
                    orchestrator.dashboardCardItems.compactMap { destination in
                        Self.metricLayoutCopyDestination(
                            destination, from: result, configurationStore: configurationStore
                        )
                    }
                },
                onCopyMetricLayout: { destination in
                    configurationStore.copyMetricLayout(
                        from: result.accountID,
                        to: destination.id,
                        destinationAvailableMetricIDs: destination.availableMetricIDs
                    )
                },
                onMarkMetricsSeen: { metricIDs in
                    configurationStore.markMetricsSeen(
                        metricIDs,
                        accountID: result.accountID
                    )
                },
                historySeriesOptions: {
                    historyStore.historySeriesOptions(
                        for: result,
                        severityThresholds:
                            configurationStore.usageAlertSettings.severityThresholds
                    )
                },
                onMetricsDiscovered: { metricIDs in
                    configurationStore.reconcileMetricLayout(
                        accountID: result.accountID,
                        availableMetricIDs: metricIDs
                    )
                }
            )
        } else if configurationStore.accountAccess.isPaused(accountID: item.id) {
            PausedAccountPlaceholder(
                configuration: item.configuration,
                onMakeActive: configurationStore.requestActiveAccountChoice,
                onConfigure: { configureDashboardAccount(item.configuration) }
            )
        } else {
            ProviderUsagePlaceholderCard(
                configuration: item.configuration,
                errorMessage: item.errorMessage,
                recoveryAction: item.recoveryAction,
                isPerformingRecovery: authenticationState.isSigningIn,
                recoveryStatusMessage: authenticationState.statusMessage,
                recoveryErrorMessage: authenticationState.errorMessage,
                onReportProblem: onReportProblem,
                onRetry: {
                    performRecovery(for: item)
                }
            )
        }
    }

    private func performRecovery(for item: DashboardProviderCardItem) {
        guard !configurationStore.accountAccess.isPaused(accountID: item.id) else {
            configurationStore.requestActiveAccountChoice()
            return
        }
        switch DashboardRecoveryRoute.resolve(
            action: item.recoveryAction,
            providerID: item.configuration.providerID
        ) {
        case .retryRefresh:
            Task {
                await orchestrator.refreshAccount(item.configuration)
            }
        case .claudeSignIn:
            claudeAuthenticationController.startSignIn(for: item.configuration)
        case .accountSettings:
            configureDashboardAccount(item.configuration, startsCursorSignIn: item.configuration.providerID == .cursor)
        }
    }

    private func configureDashboardAccount(
        _ configuration: ProviderAccountConfiguration, startsCursorSignIn: Bool = false
    ) {
        guard let saved = configurationStore.prepareDashboardAccountForSetup(configuration) else { return }
        let needsGoogleSetup = [.gemini, .antigravity].contains(saved.providerID)
            && !configurationStore.isConfigured(saved)
        accountConfigurationNavigation.present(
            accountID: saved.id, refreshOnDismiss: !needsGoogleSetup, startsCursorSignIn: startsCursorSignIn
        )
    }

    private func toggleDashboardCardExpansion(_ accountID: String) {
        let isCollapsed = configurationStore.isDashboardCardCollapsed(accountID: accountID)
        configurationStore.updateDashboardCardCollapsed(!isCollapsed, accountID: accountID)
    }

    private func problemReportContext(
        for item: DashboardProviderCardItem
    ) -> PrivacySafeDiagnosticContext? {
        guard let errorMessage = item.errorMessage else {
            return nil
        }
        return PrivacySafeDiagnosticContext(
            system: .current(installedVersion: appUpdateController.installedVersion),
            surface: .dashboard,
            providerID: item.configuration.providerID,
            technicalDetails: .providerRefreshFailure(
                configuration: item.configuration,
                isConfigured: configurationStore.isConfigured(item.configuration),
                isSecretPresent: configurationStore.hasSecret(for: item.configuration),
                userVisibleMessage: errorMessage,
                result: item.result
            )
        )
    }

    private var accountConfigurationPresentation:
        Binding<DashboardAccountConfigurationPresentation?> {
        Binding(
            get: {
                accountConfigurationNavigation.presentation
            },
            set: { presentation in
                if let presentation {
                    accountConfigurationNavigation.present(accountID: presentation.accountID)
                } else {
                    accountConfigurationNavigation.clearPresentation()
                }
            }
        )
    }

    private func refreshAccount(accountID: String) async {
        guard let configuration = configurationStore.configuration(accountID: accountID) else {
            return
        }
        await orchestrator.refreshAccount(configuration)
    }

    private func finishDashboardAccountSettings() {
        var accountIDs = dashboardSettingsChangedAccountIDs
        dashboardSettingsChangedAccountIDs.removeAll()
        if let accountID = accountConfigurationNavigation.finishDismissal() { accountIDs.insert(accountID) }
        Task {
            for accountID in accountIDs.sorted() { await refreshAccount(accountID: accountID) }
        }
    }

    private func moveCard(_ draggedID: String, to targetID: String) {
        withAnimation(.snappy(duration: 0.18)) {
            orchestrator.moveCard(draggedID, to: targetID)
        }
    }

    private func moveCard(
        _ cardID: String,
        within items: [DashboardProviderCardItem],
        offset: Int
    ) {
        guard
            let sourceIndex = items.firstIndex(where: { $0.id == cardID }),
            items.indices.contains(sourceIndex + offset)
        else {
            return
        }

        moveCard(cardID, to: items[sourceIndex + offset].id)
    }

    private func finishCardDrag() {
        orchestrator.finishCardDrag()
        draggedCardID = nil
    }

    private func handleDeepLink(
        _ url: URL,
        scrollProxy: ScrollViewProxy,
        availableAccountIDs: [String]
    ) {
        guard let accountID = CodexBarDeepLink.providerAccountID(from: url) else {
            return
        }

        let expectsSettingsRefresh = isShowingSettings
        isShowingSettings = false
        selectedHistoryResult = nil
        deepLinkNavigation.begin(
            accountID: accountID,
            waitsForRefresh: refreshService.isRefreshing
                || expectsSettingsRefresh
                || (performsLifecycleWork && !hasCompletedInitialRefresh)
        )
        scrollToPendingDeepLink(
            scrollProxy: scrollProxy,
            availableAccountIDs: availableAccountIDs,
            completesNavigation: deepLinkNavigation.shouldFinishAfterInitialScroll
        )
    }

    private func scrollToPendingDeepLink(
        scrollProxy: ScrollViewProxy,
        availableAccountIDs: [String],
        completesNavigation: Bool
    ) {
        guard let accountID = deepLinkNavigation.accountID else {
            return
        }
        guard availableAccountIDs.contains(accountID) else {
            if completesNavigation {
                deepLinkNavigation.finish(accountID: accountID)
            }
            return
        }

        Task { @MainActor in
            await Task.yield()
            guard deepLinkNavigation.accountID == accountID else {
                return
            }

            withAnimation(.snappy(duration: 0.25)) {
                scrollProxy.scrollTo(accountID, anchor: .center)
            }
            if completesNavigation {
                deepLinkNavigation.finish(accountID: accountID)
            }
        }
    }

    private var refreshAccessibilityLabel: String {
        guard let schedule = orchestrator.autoRefreshSchedule else {
            return "Refresh usage"
        }
        return "Refresh usage. \(schedule.accessibilityDescription(at: Date()))"
    }
}

private struct GitHubStatusBanner: View {
    let snapshot: GitHubServiceStatusSnapshot
    let isStale: Bool
    let statusCheckFailed: Bool
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(snapshot.severity.displayName, systemImage: snapshot.severity.systemImage)
                    .font(.headline)
                    .foregroundStyle(severityColor)
                Spacer(minLength: 8)
                Button("Dismiss", systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .accessibilityHint("Hides this update. A new incident update can appear later.")
            }

            Text(snapshot.summary)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            Text(freshnessText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Link(destination: snapshot.detailsURL) {
                Label("Open GitHub Status", systemImage: "arrow.up.right.square")
            }
            .font(.footnote.weight(.semibold))
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(severityColor, lineWidth: 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("github-service-status-banner")
    }

    private var freshnessText: String {
        let updated = UserFacingDateTimeFormatter.current.dateAndTime(snapshot.updatedAt)
        return GitHubStatusBannerMessage.freshness(
            updatedAt: updated,
            isStale: isStale,
            statusCheckFailed: statusCheckFailed
        )
    }

    private var severityColor: Color {
        switch snapshot.severity {
        case .operational: .green
        case .minor: .orange
        case .major, .critical: .red
        }
    }
}

enum GitHubStatusBannerMessage {
    static func freshness(updatedAt: String, isStale: Bool, statusCheckFailed: Bool) -> String {
        if statusCheckFailed {
            return "Last known status, updated \(updatedAt). A recent status check was unavailable; this is not a newly confirmed outage."
        }
        if isStale {
            return "Last known status, updated \(updatedAt). This status is stale because a newer check has not completed."
        }
        return "GitHub updated this status \(updatedAt)."
    }
}

struct DashboardDeepLinkNavigationState: Equatable {
    private(set) var accountID: String?
    private(set) var waitsForRefresh = false

    var shouldFinishAfterInitialScroll: Bool {
        !waitsForRefresh
    }

    mutating func begin(accountID: String, waitsForRefresh: Bool) {
        self.accountID = accountID
        self.waitsForRefresh = waitsForRefresh
    }

    mutating func finish(accountID: String) {
        guard self.accountID == accountID else {
            return
        }
        self.accountID = nil
        waitsForRefresh = false
    }
}

struct DashboardAccountConfigurationPresentation: Identifiable, Equatable {
    let accountID: String
    var startsCursorSignIn = false

    var id: String {
        accountID
    }
}

enum SettingsDismissalRefreshAction: Equatable {
    case allAccounts
    case accounts(Set<String>)
    case none
}

struct SettingsDismissalRefreshState: Equatable {
    private var consumedCredentialRefresh = false
    private var accountIDsNeedingRefresh: Set<String> = []

    mutating func credentialsChanged(accountID: String) {
        consumedCredentialRefresh = true
        accountIDsNeedingRefresh.remove(accountID)
    }

    mutating func refreshInputsChanged(accountID: String) {
        accountIDsNeedingRefresh.insert(accountID)
    }

    mutating func finishDismissal() -> SettingsDismissalRefreshAction {
        defer {
            consumedCredentialRefresh = false
            accountIDsNeedingRefresh.removeAll()
        }
        if !consumedCredentialRefresh {
            return .allAccounts
        }
        if accountIDsNeedingRefresh.isEmpty {
            return .none
        }
        return .accounts(accountIDsNeedingRefresh)
    }
}

struct DashboardAccountConfigurationNavigationState: Equatable {
    private(set) var presentation: DashboardAccountConfigurationPresentation?
    private var accountIDAwaitingDismissalRefresh: String?

    mutating func present(accountID: String, refreshOnDismiss: Bool = true, startsCursorSignIn: Bool = false) {
        guard presentation?.accountID != accountID else { return }
        presentation = DashboardAccountConfigurationPresentation(accountID: accountID, startsCursorSignIn: startsCursorSignIn)
        accountIDAwaitingDismissalRefresh = refreshOnDismiss ? accountID : nil
    }

    mutating func clearPresentation() {
        presentation = nil
    }

    mutating func credentialsChanged() {
        accountIDAwaitingDismissalRefresh = nil
    }

    mutating func refreshInputsChanged() {
        accountIDAwaitingDismissalRefresh = presentation?.accountID
    }

    mutating func finishDismissal() -> String? {
        defer {
            presentation = nil
            accountIDAwaitingDismissalRefresh = nil
        }
        return accountIDAwaitingDismissalRefresh
    }
}

enum DashboardRecoveryRoute: Equatable {
    case retryRefresh
    case claudeSignIn
    case accountSettings

    static func resolve(
        action: ProviderUsageRecoveryAction,
        providerID: ProviderID
    ) -> Self {
        switch action {
        case .retryRefresh:
            .retryRefresh
        case .signIn, .reauthenticate:
            providerID == .claude ? .claudeSignIn : .accountSettings
        }
    }
}

enum DashboardEmptyState: Equatable {
    case hidden
    case loading
    case recovery
    case accountResetRecovery
    case firstAccount
    case needsSetup(accountID: String)
    case accountsDisabled
    case noUsageData

    static func resolve(
        hasAccounts: Bool,
        hasEnabledAccounts: Bool,
        needsSetupAccountID: String?,
        cardsAreEmpty: Bool,
        hasCompletedInitialRefresh: Bool,
        performsLifecycleWork: Bool,
        isPersistenceRecoveryRequired: Bool,
        hasIncompleteAccountReset: Bool = false
    ) -> DashboardEmptyState {
        guard cardsAreEmpty else {
            return .hidden
        }
        guard hasCompletedInitialRefresh || !performsLifecycleWork else {
            return .loading
        }
        if isPersistenceRecoveryRequired {
            return .recovery
        }
        if hasIncompleteAccountReset {
            return .accountResetRecovery
        }
        if !hasAccounts {
            return .firstAccount
        }
        if !hasEnabledAccounts {
            return .accountsDisabled
        }
        if let accountID = needsSetupAccountID {
            return .needsSetup(accountID: accountID)
        }
        return .noUsageData
    }
}

private struct ProviderUsageCardDropDelegate: DropDelegate {
    let targetID: String
    @Binding var draggedCardID: String?
    let moveCard: (String, String) -> Void
    let finishDrag: () -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedCardID, draggedCardID != targetID else {
            return
        }

        moveCard(draggedCardID, targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        finishDrag()
        return true
    }
}

private struct DashboardCardReorderActions: ViewModifier {
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    let moveEarlier: () -> Void
    let moveLater: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if canMoveEarlier, canMoveLater {
            content
                .accessibilityAction(named: Text("Move Earlier"), moveEarlier)
                .accessibilityAction(named: Text("Move Later"), moveLater)
        } else if canMoveEarlier {
            content
                .accessibilityAction(named: Text("Move Earlier"), moveEarlier)
        } else if canMoveLater {
            content
                .accessibilityAction(named: Text("Move Later"), moveLater)
        } else {
            content
        }
    }
}

struct DashboardCardGridLayout {
    static let cardSpacing: CGFloat = 14
    static let horizontalPadding: CGFloat = 32
    static let minimumReadableCardWidth: CGFloat = 340

    static func columnCount(
        containerWidth: CGFloat,
        idiom: UIUserInterfaceIdiom,
        dynamicTypeSize: DynamicTypeSize,
        hasCollapsedCard: Bool = false
    ) -> Int {
        // A two-column dashboard sizes each row to its tallest card, so a short
        // collapsed card beside an expanded card would not reclaim any height.
        // Keep that section in source-order single-column flow while collapsed
        // instead of introducing masonry placement and a changed reading order.
        guard
            !hasCollapsedCard,
            idiom == .pad,
            !dynamicTypeSize.isAccessibilitySize
        else {
            return 1
        }

        let usableWidth = max(0, containerWidth - horizontalPadding)
        let requiredWidth = (minimumReadableCardWidth * 2) + cardSpacing
        return usableWidth >= requiredWidth ? 2 : 1
    }

    /// iPhone keeps lazy loading, which defers offscreen cards and stays stable
    /// in its single column. Lazy grid placement kept re-anchoring the
    /// scrolling two-column iPad dashboard on iOS 26 and stopped the app from
    /// responding, so iPad measures its cards eagerly in every column count.
    static func usesLazyLayout(idiom: UIUserInterfaceIdiom) -> Bool {
        idiom != .pad
    }

    /// Equal-width columns with each row as tall as its tallest card, matching
    /// flexible, top-aligned grid columns.
    static func cardFrames(
        heights: [CGFloat],
        containerWidth: CGFloat,
        columnCount: Int,
        spacing: CGFloat
    ) -> [CGRect] {
        let columns = max(1, columnCount)
        let width = columnWidth(containerWidth: containerWidth, columnCount: columns, spacing: spacing)
        var frames: [CGRect] = []
        var rowMinY: CGFloat = 0
        for rowStart in stride(from: 0, to: heights.count, by: columns) {
            let row = heights[rowStart..<min(rowStart + columns, heights.count)]
            for (column, height) in row.enumerated() {
                let minX = CGFloat(column) * (width + spacing)
                frames.append(CGRect(x: minX, y: rowMinY, width: width, height: height))
            }
            rowMinY += (row.max() ?? 0) + spacing
        }
        return frames
    }

    static func columnWidth(containerWidth: CGFloat, columnCount: Int, spacing: CGFloat) -> CGFloat {
        let columns = CGFloat(max(1, columnCount))
        return max(0, (containerWidth - spacing * (columns - 1)) / columns)
    }
}

/// The dashboard's vertical stack, lazy only where that is stable.
private struct DashboardStack<Content: View>: View {
    let isLazy: Bool
    @ViewBuilder let content: Content

    var body: some View {
        if isLazy {
            LazyVStack(alignment: .leading, spacing: 14) { content }
        } else {
            VStack(alignment: .leading, spacing: 14) { content }
        }
    }
}

/// A section's cards in flexible, top-aligned columns.
private struct DashboardCardGrid<Content: View>: View {
    let isLazy: Bool
    let columnCount: Int
    @ViewBuilder let content: Content

    var body: some View {
        let spacing = DashboardCardGridLayout.cardSpacing
        if isLazy {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
                    count: max(1, columnCount)
                ),
                alignment: .leading,
                spacing: spacing
            ) { content }
        } else {
            DashboardCardColumnsLayout(columnCount: columnCount, spacing: spacing) { content }
        }
    }
}

/// Places dashboard cards like a flexible grid, but measures every card once
/// instead of placing them lazily.
struct DashboardCardColumnsLayout: Layout {
    let columnCount: Int
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? idealWidth(of: subviews)
        let height = frames(containerWidth: width, subviews: subviews).map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(containerWidth: bounds.width, subviews: subviews)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: nil)
            )
        }
    }

    private func frames(containerWidth: CGFloat, subviews: Subviews) -> [CGRect] {
        let width = DashboardCardGridLayout.columnWidth(
            containerWidth: containerWidth, columnCount: columnCount, spacing: spacing
        )
        return DashboardCardGridLayout.cardFrames(
            heights: subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height },
            containerWidth: containerWidth,
            columnCount: columnCount,
            spacing: spacing
        )
    }

    private func idealWidth(of subviews: Subviews) -> CGFloat {
        let columns = CGFloat(max(1, min(columnCount, subviews.count)))
        let cellWidth = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return cellWidth * columns + spacing * (columns - 1)
    }
}

private struct AutoRefreshTaskID: Equatable {
    let interval: AutoRefreshInterval
    let resetID: UUID
}

private struct AppUpdateNotice: View {
    let release: AppStoreRelease
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.app.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Version \(release.version) available")
                    .font(.subheadline.weight(.semibold))
                Text("A newer CodexBar release is on the App Store.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Link("Update", destination: release.productURL)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss version \(release.version) update notice")
            .help("Dismiss update notice")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

private struct RefreshButtonLabel: View {
    let isRefreshing: Bool
    let schedule: AutoRefreshSchedule?

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { timeline in
            ZStack {
                if let schedule {
                    AutoRefreshRing(
                        progress: schedule.progress(at: timeline.date),
                        remainingSeconds: schedule.remainingSeconds(at: timeline.date)
                    )
                }

                if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .frame(width: 34, height: 34)
            .contentShape(Circle())
        }
    }
}

private struct AutoRefreshRing: View {
    let progress: Double
    let remainingSeconds: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.tertiarySystemFill), lineWidth: 3)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.25), value: progress)
        }
        .accessibilityHidden(true)
    }

    private var tint: Color {
        switch progress {
        case ..<0.55:
            .green
        case ..<0.82:
            .orange
        default:
            .red
        }
    }
}

#if DEBUG
@MainActor
private enum ContentPreview {
    static func makeView() -> some View {
        let defaults = UserDefaults(suiteName: "CodexBar.ContentPreview.\(UUID().uuidString)")!
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: ContentPreviewSecretStore(), widgetSnapshotDefaults: nil
        )
        let samples = DemoUsageProvider.samples.filter { [.codex, .claude, .openRouter].contains($0.providerID) }
        for sample in samples { _ = store.update(.defaultConfiguration(for: sample.providerID)) }
        let results = samples.map { sample in
            ProviderUsageResult(
                accountID: sample.providerID.rawValue, providerID: sample.providerID,
                title: sample.providerID.displayName, plan: sample.plan, subtitle: "Preview",
                bars: sample.bars, creditsRemaining: sample.creditsRemaining, fetchedAt: Date()
            )
        }
        let refreshService = UsageRefreshService(providers: samples, initialResults: results)
        let statusPreferences = GitHubStatusPreferences(defaults: defaults)
        let effects = ContentPreviewEffects()
        return ContentView(
            refreshService: refreshService,
            configurationStore: store,
            historyStore: UsageHistoryStore(defaults: defaults, accessPolicy: .pro),
            appUpdateController: AppUpdateController(defaults: defaults, releaseFetcher: ContentPreviewNetwork()),
            githubStatusPreferences: statusPreferences,
            githubStatusMonitor: GitHubStatusMonitor(
                preferences: statusPreferences, fetcher: ContentPreviewNetwork(), notifier: effects
            ),
            usageAlertNotifier: effects,
            appReviewPromptPolicy: AppReviewPromptPolicy(defaults: defaults),
            performsLifecycleWork: false,
            widgetSnapshotCoordinator: WidgetSnapshotCoordinator(
                refreshService: refreshService, configurationStore: store,
                publishSnapshot: { _, _ in }, publishSettings: { _ in }
            ),
            watchSnapshotCoordinator: WatchSnapshotCoordinator(
                refreshService: refreshService, configurationStore: store,
                sender: effects, publishSnapshot: { _, _, _ in }
            )
        )
    }
}

private struct ContentPreviewSecretStore: SecretStore {
    func readSecret(account: String) throws -> String? { "preview-credential" }
    func saveSecret(_ secret: String, account: String) throws {}
    func deleteSecret(account: String) throws {}
}

private struct ContentPreviewNetwork: AppStoreReleaseFetching, GitHubStatusFetching {
    func fetchRelease() async throws -> AppStoreRelease { throw URLError(.notConnectedToInternet) }
    func fetchStatus(checkedAt: Date) async throws -> GitHubServiceStatusSnapshot { throw URLError(.notConnectedToInternet) }
}

@MainActor
private final class ContentPreviewEffects: UsageAlertNotifying, GitHubStatusNotifying, WatchSnapshotSending {
    func requestAuthorization() async -> Bool { false }
    func deliver(_ notification: UsageAlertNotification) async throws {}
    func deliverGitHubStatus(_ notification: GitHubStatusNotification) async throws {}
    func activate(onSnapshotNeeded: @escaping @MainActor (Bool) -> Void) {}
    func publish(_ snapshot: WatchDashboardSnapshot, force: Bool) -> Bool { false }
}

#Preview {
    ContentPreview.makeView()
}
#endif
