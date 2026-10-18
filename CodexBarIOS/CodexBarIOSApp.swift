import BackgroundTasks
import SwiftUI

@main
struct CodexBarIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var proEntitlement: ProEntitlement
    @StateObject private var refreshService: UsageRefreshService
    @StateObject private var configurationStore: ProviderConfigurationStore
    @StateObject private var historyStore: UsageHistoryStore
    @StateObject private var appUpdateController: AppUpdateController
    @StateObject private var githubStatusPreferences: GitHubStatusPreferences
    @StateObject private var githubStatusMonitor: GitHubStatusMonitor
    #if DEBUG
    private let screenshotConfiguration = AppStoreScreenshotConfiguration.current
    @State private var debugProviderSettingsProviderID = DebugLaunchRoute.providerSettingsProviderID
    #endif

    init() {
        _proEntitlement = StateObject(wrappedValue: ProEntitlement.live())
        #if DEBUG
        if let fixtures = UITestFixtures.current {
            _refreshService = StateObject(wrappedValue: fixtures.refreshService)
            _configurationStore = StateObject(wrappedValue: fixtures.configurationStore)
            _historyStore = StateObject(wrappedValue: fixtures.historyStore)
            _appUpdateController = StateObject(wrappedValue: fixtures.appUpdateController)
            _githubStatusPreferences = StateObject(wrappedValue: fixtures.statusPreferences)
            _githubStatusMonitor = StateObject(wrappedValue: fixtures.statusMonitor)
            return
        }
        #endif
        _appUpdateController = StateObject(wrappedValue: AppUpdateController())
        let statusPreferences = GitHubStatusPreferences()
        _githubStatusPreferences = StateObject(wrappedValue: statusPreferences)
        _githubStatusMonitor = StateObject(
            wrappedValue: GitHubStatusMonitor(
                preferences: statusPreferences,
                notifier: LocalUsageAlertNotifier.shared
            )
        )
        #if DEBUG
        if let screenshotConfiguration {
            let configurationStore = ProviderConfigurationStore.appStoreScreenshotDemo()
            configurationStore.updateAppAppearance(screenshotConfiguration.appearance)
            if screenshotConfiguration.scene == .dashboardDark {
                configurationStore.updateDashboardCardOrder([
                    AppStoreScreenshotFixtureID.openRouterAccount,
                    AppStoreScreenshotFixtureID.openCodeZenAccount,
                    AppStoreScreenshotFixtureID.moonshotAccount,
                    AppStoreScreenshotFixtureID.cursorAccount,
                    AppStoreScreenshotFixtureID.codexAccount,
                    AppStoreScreenshotFixtureID.copilotAccount,
                    AppStoreScreenshotFixtureID.claudeAccount,
                ])
            }
            AppStoreScreenshotFixtures.featureAccount(
                for: screenshotConfiguration.scene,
                in: configurationStore
            )
            if DebugUsageAlertMode.isEnabled {
                configurationStore.updateUsageAlertsEnabled(true)
                configurationStore.updateUsageAlertWarningThreshold(0.65)
                configurationStore.updateUsageAlertBalanceThreshold(15)
            }

            let results = AppStoreScreenshotFixtures.results(for: configurationStore)
            let historyStore = AppStoreScreenshotFixtures.historyStore(
                for: results,
                extendedRange: screenshotConfiguration.scene == .history
            )
            AppStoreScreenshotFixtures.seedWidgetPreview(
                results: results,
                configurationStore: configurationStore
            )
            _refreshService = StateObject(
                wrappedValue: UsageRefreshService(
                    providers: DemoUsageProvider.samples,
                    initialResults: results
                )
            )
            _configurationStore = StateObject(wrappedValue: configurationStore)
            _historyStore = StateObject(wrappedValue: historyStore)
            return
        }
        #endif

        _refreshService = StateObject(wrappedValue: UsageRefreshService.live())
        _configurationStore = StateObject(wrappedValue: ProviderConfigurationStore())
        _historyStore = StateObject(wrappedValue: UsageHistoryStore())
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .environmentObject(proEntitlement)
                .preferredColorScheme(configurationStore.appAppearance.colorScheme)
                .task {
                    #if DEBUG
                    if UITestFixtures.current != nil || screenshotConfiguration != nil { return }
                    #endif
                    await proEntitlement.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    #if DEBUG
                    if UITestFixtures.current != nil || screenshotConfiguration != nil { return }
                    #endif
                    Task { await proEntitlement.refresh() }
                }
                .task {
                    #if DEBUG
                    if UITestFixtures.current != nil { return }
                    if DeveloperGoogleSessionInstaller.installIfRequested(configurationStore: configurationStore) {
                        await refreshService.refresh(configurations: configurationStore.visibleConfigurations)
                    }
                    if let screenshotConfiguration {
                        let settleNanoseconds = UInt64(
                            screenshotConfiguration.settleDelay * 1_000_000_000
                        )
                        try? await Task.sleep(nanoseconds: settleNanoseconds)
                        AppStoreScreenshotFixtures.markReady(scene: screenshotConfiguration.scene)
                    } else {
                        OpenCodeZenBootstrapImporter.importIfNeeded(configurationStore: configurationStore)
                    }
                    #else
                    OpenCodeZenBootstrapImporter.importIfNeeded(configurationStore: configurationStore)
                    #endif
                }
        }
        .backgroundTask(
            .appRefresh(GitHubStatusMonitor.backgroundTaskIdentifier)
        ) {
            await githubStatusMonitor.performBackgroundRefresh()
        }
    }

    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        if let fixtures = UITestFixtures.current {
            fixtures.contentView()
        } else if let screenshotConfiguration {
            screenshotRootView(for: screenshotConfiguration.scene)
        } else if let providerID = debugProviderSettingsProviderID {
            NavigationStack {
                ProviderSettingsView(
                    configurationStore: configurationStore,
                    accountID: configurationStore.configuration(for: providerID).id,
                    onAccountRefresh: { configuration in
                        await refreshService.refresh(configuration: configuration)
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") {
                            debugProviderSettingsProviderID = nil
                        }
                    }
                }
            }
        } else {
            mainContentView()
        }
        #else
        mainContentView()
        #endif
    }

    private func mainContentView(performsLifecycleWork: Bool = true) -> some View {
        ContentView(
            refreshService: refreshService,
            configurationStore: configurationStore,
            historyStore: historyStore,
            appUpdateController: appUpdateController,
            githubStatusPreferences: githubStatusPreferences,
            githubStatusMonitor: githubStatusMonitor,
            performsLifecycleWork: performsLifecycleWork
        )
    }

    #if DEBUG
    @ViewBuilder
    private func screenshotRootView(for scene: AppStoreScreenshotScene) -> some View {
        switch scene {
        case .dashboardOverview, .dashboardDark, .gemini, .grok, .githubBilling:
            mainContentView(performsLifecycleWork: false)
        case .widgetBuilder:
            NavigationStack {
                WidgetBuilderView()
            }
        case .accounts:
            SettingsView(
                configurationStore: configurationStore,
                appUpdateController: appUpdateController,
                githubStatusPreferences: githubStatusPreferences,
                initialRoute: .accounts
            )
        case .providerCopilot:
            NavigationStack {
                ProviderSettingsView(
                    configurationStore: configurationStore,
                    accountID: AppStoreScreenshotFixtureID.copilotAccount,
                    initialUsageResult: refreshService.results.first {
                        $0.accountID == AppStoreScreenshotFixtureID.copilotAccount
                    }
                )
            }
        case .history:
            if let result = refreshService.results.first(where: { $0.providerID == .codex }) {
                ProviderUsageHistoryDetailView(
                    result: result,
                    seriesOptions: historyStore.historySeriesOptions(
                        for: result,
                        severityThresholds:
                            configurationStore.usageAlertSettings.severityThresholds
                    )
                )
            } else {
                ContentUnavailableView("No History", systemImage: "chart.xyaxis.line")
            }
        }
    }
    #endif
}

#if DEBUG
private enum DebugLaunchRoute {
    static var providerSettingsProviderID: ProviderID? {
        if
            let rawValue = ProcessInfo.processInfo.environment["CODEXBAR_DEBUG_PROVIDER_SETTINGS"],
            let providerID = ProviderID(rawValue: rawValue) {
            return providerID
        }

        if
            let rawValue = UserDefaults.standard.string(forKey: "debugProviderSettings"),
            let providerID = ProviderID(rawValue: rawValue) {
            return providerID
        }

        let arguments = ProcessInfo.processInfo.arguments
        guard
            let routeIndex = arguments.firstIndex(of: "--debug-provider-settings"),
            arguments.indices.contains(routeIndex + 1)
        else {
            return nil
        }

        return ProviderID(rawValue: arguments[routeIndex + 1])
    }
}

private enum DebugUsageAlertMode {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--debug-usage-alerts")
            || ProcessInfo.processInfo.environment["CODEXBAR_DEBUG_USAGE_ALERTS"] == "1"
    }
}
#endif
