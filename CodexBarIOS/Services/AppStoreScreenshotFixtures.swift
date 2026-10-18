#if DEBUG
import Foundation

enum AppStoreScreenshotScene: String {
    case dashboardOverview = "dashboard-overview"
    case dashboardDark = "dashboard-dark"
    case gemini
    case grok
    case githubBilling = "github-billing"
    case widgetBuilder = "widget-builder"
    case accounts
    case providerCopilot = "provider-copilot"
    case history
}

enum AppStoreScreenshotFixtureID {
    static let usageGroup = "app-store-screenshots.usage"
    static let balanceGroup = "app-store-screenshots.balances"
    static let codexAccount = "app-store-screenshots.codex"
    static let copilotAccount = "app-store-screenshots.copilot"
    static let githubBillingAccount = "app-store-screenshots.github-billing"
    static let claudeAccount = "app-store-screenshots.claude"
    static let grokAccount = "app-store-screenshots.grok"
    static let xSubscriptionAccount = "app-store-screenshots.x-subscription"
    static let cursorAccount = "app-store-screenshots.cursor"
    static let openRouterAccount = "app-store-screenshots.openrouter"
    static let openCodeZenAccount = "app-store-screenshots.opencodzen"
    static let moonshotAccount = "app-store-screenshots.moonshot"
    static let greptileAccount = "app-store-screenshots.greptile"
    static let geminiAccount = "app-store-screenshots.gemini"
    static let antigravityAccount = "app-store-screenshots.antigravity"
}

struct AppStoreScreenshotConfiguration {
    static let readyFileName = "app-store-screenshot-ready"

    let scene: AppStoreScreenshotScene
    let appearance: AppAppearance
    let settleDelay: TimeInterval

    static var current: AppStoreScreenshotConfiguration? {
        parse(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        )
    }

    static func parse(
        arguments: [String],
        environment: [String: String] = [:]
    ) -> AppStoreScreenshotConfiguration? {
        guard arguments.contains("--app-store-screenshots")
            || environment["CODEXBAR_APP_STORE_SCREENSHOTS"] == "1"
        else {
            return nil
        }

        let scene = value(after: "--app-store-scene", in: arguments)
            .flatMap(AppStoreScreenshotScene.init(rawValue:))
            ?? .dashboardOverview
        let appearance = value(after: "--app-store-appearance", in: arguments)
            .flatMap(AppAppearance.init(rawValue:))
            ?? .light
        let settleDelay = value(after: "--app-store-settle-seconds", in: arguments)
            .flatMap(TimeInterval.init)
            ?? environment["CODEXBAR_APP_STORE_SETTLE_SECONDS"].flatMap(TimeInterval.init)
            ?? 2

        return AppStoreScreenshotConfiguration(
            scene: scene,
            appearance: appearance,
            settleDelay: min(max(settleDelay, 0), 30)
        )
    }

    private static func value(after argument: String, in arguments: [String]) -> String? {
        guard
            let index = arguments.firstIndex(of: argument),
            arguments.indices.contains(index + 1)
        else {
            return nil
        }

        return arguments[index + 1]
    }
}

@MainActor
enum AppStoreScreenshotFixtures {
    private static let captureDate = Date()
    static let widgetDefaults = isolatedDefaults()
    private static let widgetAccessGuard: WidgetAccessGuard = {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot-widget-access-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return WidgetAccessGuard(directory: directory)
    }()

    private static func isolatedDefaults() -> UserDefaults {
        let suite = "com.hemsoft.CodexBarIOS.screenshot.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("Cannot create isolated screenshot storage")
        }
        return defaults
    }

    static func featureAccount(for scene: AppStoreScreenshotScene, in store: ProviderConfigurationStore) {
        switch scene {
        case .gemini:
            store.updateDashboardCardOrder([AppStoreScreenshotFixtureID.geminiAccount])
            for definition in GoogleUsageMetricCatalog.definitions(for: .gemini) {
                store.updateMetricWidth(.half, accountID: AppStoreScreenshotFixtureID.geminiAccount, metricID: definition.id)
            }
        case .grok: store.updateDashboardCardOrder([AppStoreScreenshotFixtureID.grokAccount])
        case .githubBilling: store.updateDashboardCardOrder([AppStoreScreenshotFixtureID.githubBillingAccount])
        default: break
        }
    }

    static func results(for configurationStore: ProviderConfigurationStore) -> [ProviderUsageResult] {
        let samples = Dictionary(uniqueKeysWithValues: DemoUsageProvider.samples.map { ($0.providerID, $0) })
        let capturedAt = captureDate

        return configurationStore.visibleConfigurations.compactMap { configuration in
            guard let sample = samples[configuration.providerID] else {
                return nil
            }

            return ProviderUsageResult(
                accountID: configuration.id,
                providerID: sample.providerID,
                title: sample.providerID == .openCodeZen
                    ? configuration.openCodeDisplayName(
                        hasGoUsage: !sample.bars.isEmpty,
                        hasZenBalance: sample.creditsRemaining != nil
                    )
                    : configuration.displayName,
                plan: sample.plan,
                subtitle: sample.subtitle,
                bars: captureBars(sample.bars, providerID: sample.providerID),
                creditsRemaining: sample.creditsRemaining,
                monetaryMetrics: sample.monetaryMetrics,
                usageMessages: sample.usageMessages,
                dashboardUsageMessages: sample.dashboardUsageMessages,
                cardInformationSections: sample.cardInformationSections,
                fetchedAt: capturedAt
            )
        }
    }

    private static func captureBars(_ bars: [UsageBar], providerID: ProviderID) -> [UsageBar] {
        let monthlyProvider = [ProviderID.cursor, .githubBilling].contains(providerID)
        return bars.map { bar in
            guard monthlyProvider || bar.label.localizedCaseInsensitiveContains("monthly") else { return bar }
            return UsageBar(
                id: bar.id, stableKey: bar.stableKey, label: bar.label,
                used: bar.used, limit: bar.limit,
                resetDescription: "Resets next month",
                resetDisplayStyle: .verbatim,
                fractionlessUsageText: bar.fractionlessUsageText,
                projectionCurrent: bar.projectionCurrent,
                projectionLimit: bar.projectionLimit,
                projectionPeriodStart: bar.projectionPeriodStart,
                projectionPeriodEnd: bar.projectionPeriodEnd,
                showProjectionOnCurrentBar: bar.showProjectionOnCurrentBar,
                projectionDescriptionOverride: bar.projectionDescriptionOverride,
                projectionSignificanceOverride: bar.projectionSignificanceOverride,
                usesMinimumPositivePercent: bar.usesMinimumPositivePercent
            )
        }
    }

    static func historyStore(
        for results: [ProviderUsageResult],
        extendedRange: Bool = false
    ) -> UsageHistoryStore {
        let store = UsageHistoryStore(defaults: isolatedDefaults())
        guard let result = results.first(where: { $0.providerID == .codex }) else {
            return store
        }

        let fractions = extendedRange
            ? (0..<90).map { 0.22 + Double($0) / 89 * 0.38 }
            : [0.22, 0.29, 0.35, 0.41, 0.48, 0.52, 0.56, 0.60]
        let latestDate = captureDate
        for (index, fraction) in fractions.enumerated() {
            let capturedAt = latestDate.addingTimeInterval(TimeInterval(index - fractions.count + 1) * 24 * 60 * 60)
            let bars = result.bars.enumerated().map { barIndex, bar in
                let adjustedFraction = min(fraction + (barIndex == 0 ? 0 : 0.08), 0.92)
                return UsageBar(
                    label: bar.label,
                    used: bar.limit * adjustedFraction,
                    limit: bar.limit,
                    resetDescription: bar.resetDescription,
                    projectionDescriptionOverride: bar.projectionDescriptionOverride,
                    projectionSignificanceOverride: bar.projectionSignificanceOverride
                )
            }
            let historicalResult = ProviderUsageResult(
                accountID: result.accountID,
                providerID: result.providerID,
                title: result.title,
                plan: result.plan,
                subtitle: result.subtitle,
                bars: bars,
                fetchedAt: capturedAt
            )
            store.record(results: [historicalResult], now: latestDate)
        }

        return store
    }

    static func seedWidgetPreview(
        results: [ProviderUsageResult],
        configurationStore: ProviderConfigurationStore
    ) {
        let defaults = widgetDefaults
        WidgetSnapshotPublisher.publish(
            results: results,
            configurationStore: configurationStore, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults, accessGuard: widgetAccessGuard
        )
        WidgetSnapshotStore.saveBuilderConfiguration(
            CodexBarWidgetBuilderConfiguration(
                layout: .fourTiles,
                selectedTileIDs: [
                    "provider.\(AppStoreScreenshotFixtureID.codexAccount)",
                    "provider.\(AppStoreScreenshotFixtureID.copilotAccount)",
                    "provider.\(AppStoreScreenshotFixtureID.openRouterAccount)",
                    "provider.\(AppStoreScreenshotFixtureID.openCodeZenAccount)",
                ],
                displayModes: [.fullBar, .compactPercent, .balanceOnly, .balanceOnly]
            ),
            defaults: defaults
        )
    }

    static func markReady(scene: AppStoreScreenshotScene) {
        guard let cachesDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            return
        }

        let readyFile = cachesDirectory.appendingPathComponent(
            AppStoreScreenshotConfiguration.readyFileName
        )
        try? Data(scene.rawValue.utf8).write(to: readyFile, options: .atomic)
    }
}
#endif
