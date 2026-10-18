import BackgroundTasks
import SwiftUI

@main
struct CodexBarIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var proEntitlement: ProEntitlement
    @StateObject private var planAccessCoordinator: PlanAccessCoordinator
    @StateObject private var bootstrapCoordinator: OpenCodeZenBootstrapCoordinator
    @StateObject private var refreshService: UsageRefreshService
    @StateObject private var configurationStore: ProviderConfigurationStore
    @StateObject private var historyStore: UsageHistoryStore
    @StateObject private var appUpdateController: AppUpdateController
    @StateObject private var githubStatusPreferences: GitHubStatusPreferences
    @StateObject private var githubStatusMonitor: GitHubStatusMonitor
    @StateObject private var originalPurchaserNotice: OriginalPurchaserNotice
    #if DEBUG
    private let screenshotConfiguration = AppStoreScreenshotConfiguration.current
    @State private var debugProviderSettingsProviderID = DebugLaunchRoute.providerSettingsProviderID
    #endif

    init() {
        #if DEBUG
        if let fixtures = UITestFixtures.current {
            _proEntitlement = StateObject(wrappedValue: fixtures.entitlement)
            let coordinator = PlanAccessCoordinator(
                entitlement: fixtures.entitlement, configurationStore: fixtures.configurationStore,
                refreshService: fixtures.refreshService, historyStore: fixtures.historyStore
            )
            _planAccessCoordinator = StateObject(wrappedValue: coordinator)
            _bootstrapCoordinator = StateObject(wrappedValue: OpenCodeZenBootstrapCoordinator(
                configurationStore: fixtures.configurationStore
            ))
            _originalPurchaserNotice = StateObject(wrappedValue: fixtures.originalPurchaserFixture?.notice
                ?? OriginalPurchaserNotice(defaults: fixtures.defaults))
            _refreshService = StateObject(wrappedValue: fixtures.refreshService)
            _configurationStore = StateObject(wrappedValue: fixtures.configurationStore)
            _historyStore = StateObject(wrappedValue: fixtures.historyStore)
            _appUpdateController = StateObject(wrappedValue: fixtures.appUpdateController)
            _githubStatusPreferences = StateObject(wrappedValue: fixtures.statusPreferences)
            _githubStatusMonitor = StateObject(wrappedValue: fixtures.statusMonitor)
            return
        }
        #endif
        #if DEBUG
        let entitlement = screenshotConfiguration != nil ? PlanAccessFixture().entitlement : ProEntitlement.live()
        #else
        let entitlement = ProEntitlement.live()
        #endif
        _proEntitlement = StateObject(wrappedValue: entitlement)
        _originalPurchaserNotice = StateObject(wrappedValue: OriginalPurchaserNotice())
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
            let refreshService = UsageRefreshService(providers: DemoUsageProvider.samples, initialResults: results)
            _refreshService = StateObject(wrappedValue: refreshService)
            let coordinator = PlanAccessCoordinator(
                entitlement: entitlement, configurationStore: configurationStore,
                refreshService: refreshService, historyStore: historyStore
            )
            _planAccessCoordinator = StateObject(wrappedValue: coordinator)
            _bootstrapCoordinator = StateObject(wrappedValue: OpenCodeZenBootstrapCoordinator(
                configurationStore: configurationStore
            ))
            _configurationStore = StateObject(wrappedValue: configurationStore)
            _historyStore = StateObject(wrappedValue: historyStore)
            return
        }
        #endif

        let refreshService = UsageRefreshService.live()
        let configurationStore = ProviderConfigurationStore()
        let historyStore = UsageHistoryStore()
        _refreshService = StateObject(wrappedValue: refreshService)
        _configurationStore = StateObject(wrappedValue: configurationStore)
        _historyStore = StateObject(wrappedValue: historyStore)
        let coordinator = PlanAccessCoordinator(
            entitlement: entitlement, configurationStore: configurationStore,
            refreshService: refreshService, historyStore: historyStore
        )
        _planAccessCoordinator = StateObject(wrappedValue: coordinator)
        _bootstrapCoordinator = StateObject(wrappedValue: OpenCodeZenBootstrapCoordinator(
            configurationStore: configurationStore
        ))
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .environmentObject(proEntitlement)
                .environment(\.originalPurchaserNotice, originalPurchaserNotice)
                .preferredColorScheme(configurationStore.appAppearance.colorScheme)
                .task {
                    #if DEBUG
                    if let fixtures = UITestFixtures.current {
                        guard !fixtures.isNativeTestHost else { return }
                        await fixtures.entitlement.start()
                        return
                    }
                    if screenshotConfiguration != nil { return }
                    #endif
                    await proEntitlement.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    refreshPlanAccess()
                }
                .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                    refreshPlanAccess()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    refreshPlanAccess()
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
                        bootstrapCoordinator.start()
                    }
                    #else
                    bootstrapCoordinator.start()
                    #endif
                }
        }
        .backgroundTask(
            .appRefresh(GitHubStatusMonitor.backgroundTaskIdentifier)
        ) {
            await githubStatusMonitor.performBackgroundRefresh()
        }
    }

    private func refreshPlanAccess() {
        #if DEBUG
        if UITestFixtures.current != nil || screenshotConfiguration != nil { return }
        #endif
        proEntitlement.reevaluateLocalAccess()
        Task { await proEntitlement.refresh() }
    }

    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        if let fixtures = UITestFixtures.current {
            if fixtures.isNativeTestHost {
                Color.clear.accessibilityIdentifier("native-storekit-test-host")
            } else {
                fixtures.contentView()
            }
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
            performsLifecycleWork: performsLifecycleWork,
            entitlement: proEntitlement
        )
    }

    #if DEBUG
    private func isolatedScreenshotContentView() -> some View {
        ContentView(
            refreshService: refreshService, configurationStore: configurationStore, historyStore: historyStore,
            appUpdateController: appUpdateController, githubStatusPreferences: githubStatusPreferences,
            githubStatusMonitor: githubStatusMonitor, usageAlertNotifier: IsolatedPlanFixtureEffects(),
            performsLifecycleWork: false,
            widgetSnapshotCoordinator: WidgetSnapshotCoordinator(
                refreshService: refreshService, configurationStore: configurationStore,
                publishSnapshot: { _, _ in }, publishSettings: { _ in }
            ),
            watchSnapshotCoordinator: WatchSnapshotCoordinator(
                refreshService: refreshService, configurationStore: configurationStore,
                sender: IsolatedPlanFixtureEffects(), publishSnapshot: { _, _, _ in }
            )
        )
    }

    @ViewBuilder
    private func screenshotRootView(for scene: AppStoreScreenshotScene) -> some View {
        switch scene {
        case .dashboardOverview, .dashboardDark, .gemini, .grok, .githubBilling:
            isolatedScreenshotContentView()
        case .widgetBuilder:
            NavigationStack {
                WidgetBuilderView(defaults: AppStoreScreenshotFixtures.widgetDefaults)
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
                LiveProviderUsageHistoryDetailView(
                    result: result, historyStore: historyStore, configurationStore: configurationStore
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
