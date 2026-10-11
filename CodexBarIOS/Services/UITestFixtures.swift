#if DEBUG
import Foundation
import SwiftUI
import WebKit

/// An explicit simulator-only launch contract. Never accepts a production defaults domain.
@MainActor
final class UITestFixtures {
    static let current: UITestFixtures? = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CODEXBAR_UI_TESTS"] == "1" else { return nil }
        #if targetEnvironment(simulator)
        guard let rawID = environment["CODEXBAR_UI_TEST_RUN_ID"],
              let runID = UUID(uuidString: rawID) else {
            preconditionFailure("UI tests require a UUID storage namespace")
        }
        return UITestFixtures(runID: runID, environment: environment)
        #else
        preconditionFailure("UI fixtures are available only on simulators")
        #endif
    }()

    let defaults: UserDefaults
    let configurationStore: ProviderConfigurationStore
    let refreshService: UsageRefreshService
    let historyStore: UsageHistoryStore
    let notifier = UITestNotifier()
    let statusPreferences: GitHubStatusPreferences
    let statusMonitor: GitHubStatusMonitor
    let appUpdateController: AppUpdateController
    private let usesDefaultText: Bool

    private lazy var widgetSnapshotCoordinator = WidgetSnapshotCoordinator(
        refreshService: refreshService,
        configurationStore: configurationStore,
        publishSnapshot: { _, _ in },
        publishSettings: { _ in }
    )
    private lazy var watchSnapshotCoordinator = WatchSnapshotCoordinator(
        refreshService: refreshService,
        configurationStore: configurationStore,
        sender: UITestWatchSender(),
        publishSnapshot: { _, _, _ in }
    )

    private init(runID: UUID, environment: [String: String]) {
        let suite = "com.hemsoft.CodexBarIOS.ui-tests.\(runID.uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("Cannot create UI test storage")
        }
        if environment["CODEXBAR_UI_TEST_RESET"] == "1" {
            defaults.removePersistentDomain(forName: suite)
        }
        self.defaults = defaults
        usesDefaultText = environment["CODEXBAR_UI_TEST_DEFAULT_TEXT"] == "1"
        URLProtocol.registerClass(UITestNetworkBlocker.self)
        configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: UITestSecretStore(suite: suite),
            widgetSnapshotDefaults: defaults
        )
        if let dark = environment["CODEXBAR_UI_TEST_DARK"] {
            configurationStore.updateAppAppearance(dark == "1" ? .dark : .light)
        }
        historyStore = UsageHistoryStore(defaults: defaults)
        statusPreferences = GitHubStatusPreferences(defaults: defaults)
        statusMonitor = GitHubStatusMonitor(preferences: statusPreferences, notifier: notifier)
        appUpdateController = AppUpdateController(defaults: defaults)

        let scenario = environment["CODEXBAR_UI_TEST_SCENARIO"]
        let recovery = scenario == "recovery"
        let metricEvidence = scenario?.hasPrefix("metric-evidence-") == true
        if metricEvidence && configurationStore.configurations.isEmpty {
            Self.seedMetricEvidenceAccount(in: configurationStore)
        }
        let githubBilling = scenario?.hasPrefix("github-billing") == true
        let grok = scenario?.hasPrefix("grok") == true
        UITestOpenCodeRenewalProvider.seed(in: configurationStore, scenario: scenario)
        Self.seedRenewalAccounts(in: configurationStore, scenario: scenario)
        Self.seedGooglePlanAccounts(in: configurationStore, scenario: scenario)
        Self.seedPlanPillAccounts(in: configurationStore, scenario: scenario)
        let codex = scenario?.hasPrefix("codex-") == true
        let claude = scenario?.hasPrefix("claude-") == true
        let greptile = scenario?.hasPrefix("greptile-") == true
        if greptile && configurationStore.configurations.isEmpty {
            Self.seedGreptileAccount(in: configurationStore, scenario: scenario ?? "")
        }
        if claude && configurationStore.configurations.isEmpty {
            Self.seedClaudeAccount(in: configurationStore, scenario: scenario)
            Self.seedSecondClaudeAccount(in: configurationStore, scenario: scenario)
        }
        let googleSources = Self.googleSources(for: scenario)
        let google = !googleSources.isEmpty
        if google && configurationStore.configurations.isEmpty {
            Self.seedGoogleAccounts(in: configurationStore, sources: googleSources)
        }
        if codex && configurationStore.configurations.isEmpty {
            Self.seedCodexAccounts(in: configurationStore)
        }
        if recovery && configurationStore.configurations.isEmpty {
            Self.seedRecoveryAccount(in: configurationStore)
        }
        if githubBilling && configurationStore.configurations.isEmpty {
            Self.seedGitHubBillingAccounts(in: configurationStore, scenario: scenario)
        }
        if grok && configurationStore.configurations.isEmpty {
            Self.seedGrokAccounts(in: configurationStore, scenario: scenario)
            if scenario?.hasPrefix("grok-existing") == true || scenario == "grok-custom-order" {
                Self.seedSavedGrokLayout(in: configurationStore, scenario: scenario)
            }
        }
        let results = Self.initialResults(in: configurationStore, scenario: scenario, googleSources: googleSources, defaults: defaults)
        let providers: [any UsageProvider]
        if google {
            providers = [UITestGoogleProvider(sources: googleSources)]
        } else if greptile {
            providers = [UITestGreptileProvider(secretStore: UITestSecretStore(suite: suite))]
        } else if codex {
            providers = [UITestCodexProvider(scenario: scenario)]
        } else if claude {
            providers = Self.claudeProviders(scenario: scenario, suiteName: suite)
        } else if githubBilling {
            providers = [UITestGitHubBillingProvider()]
        } else if grok {
            providers = [
                UITestGrokProvider(scenario: scenario),
                UITestCursorProvider(scenario: scenario, secretStore: UITestSecretStore(suite: suite)),
            ]
        } else {
            providers = [UITestUsageProvider(failsFirstRefresh: recovery), UITestGrokProvider(scenario: scenario)]
        }
        refreshService = UsageRefreshService(providers: Self.providersForPlanPills(providers, scenario: scenario, suiteName: suite), initialResults: results)
        if scenario?.hasPrefix("opencode-renewal-") == true || scenario == "plan-pills" || scenario?.hasPrefix("claude-plan-") == true
            || (greptile && environment["CODEXBAR_UI_TEST_MORE_INFORMATION"] == "1")
            || scenario?.hasPrefix("grok-cursor-parity") == true
            || Self.isCursorSessionScenario(scenario) {
            // These routes must load the real provider before evidence is captured.
            let service = refreshService
            let accounts = configurationStore.configurations
            Task { await service.refresh(configurations: accounts) }
        }
        if recovery && historyStore.snapshots.isEmpty {
            seedHistory()
        }
    }

    private static func initialResults(
        in store: ProviderConfigurationStore, scenario: String?, googleSources: [ProviderID], defaults: UserDefaults
    ) -> [ProviderUsageResult] {
        store.configurations.filter(store.isConfigured).map { account in
            if let scenario, scenario.hasPrefix("claude-resets-") {
                let requests = defaults.dictionary(forKey: "fixtureClaudeResetRequests") as? [String: Int] ?? [:]
                let remaining = defaults.dictionary(forKey: "fixtureClaudeResetRemaining") as? [String: Int] ?? [:]
                return UITestClaudeResetProvider.result(for: account, scenario: scenario,
                                                       requests: requests[account.id, default: 0], remaining: remaining[account.id])
            }
            return initialResult(for: account, scenario: scenario, googleSources: googleSources)
        }
    }

    private static func seedSecondClaudeAccount(in store: ProviderConfigurationStore, scenario: String?) {
        guard ["claude-resets-two-accounts", "claude-fable-two-accounts", "claude-fable-renamed"].contains(scenario ?? "") else { return }
        let second = ProviderAccountConfiguration(id: "ui-claude-second", providerID: .claude,
                                                  accountLabel: "Second Claude", authMethod: .browserSession)
        _ = store.update(second)
        _ = store.saveSecret("ui-test-credential", for: second)
    }

    private static func claudeProviders(scenario: String?, suiteName: String) -> [any UsageProvider] {
        if scenario?.hasPrefix("claude-plan-") == true {
            return [UITestClaudeProfileProvider(suiteName: suiteName)]
        }
        if let scenario, scenario.hasPrefix("claude-resets-") {
            return [UITestClaudeResetProvider(scenario: scenario, suiteName: suiteName)]
        }
        return [UITestClaudeProvider(scenario: scenario)]
    }

    nonisolated static func isCursorSessionScenario(_ scenario: String?) -> Bool {
        switch scenario {
        case "grok-cursor-session-stale", "grok-cursor-session-stale-dark-large",
             "grok-cursor-session-no-prior", "grok-cursor-session-zero-dark-large": true
        default: false
        }
    }

    nonisolated private static func cachedGreptileRenewal(scenario: String?) -> GreptileAllowanceRenewal? {
        switch scenario {
        case "greptile-renewal-stale", "greptile-renewal-expired":
            GreptileAllowanceRenewal(renewsAt: Date().addingTimeInterval(604_800),
                                    observedAt: Date().addingTimeInterval(-90_000), isStale: true)
        case "greptile-renewal-paid-expired":
            GreptileAllowanceRenewal(renewsAt: nil, observedAt: Date().addingTimeInterval(-90_000), isApplicable: false)
        default: nil
        }
    }

    nonisolated private static func initialResult(
        for configuration: ProviderAccountConfiguration, scenario: String?, googleSources: [ProviderID]
    ) -> ProviderUsageResult {
        if scenario?.hasPrefix("opencode-renewal-") == true {
            return ProviderUsageResult(accountID: configuration.id, providerID: .openCodeZen, title: configuration.displayName,
                                       subtitle: "Waiting for synthetic Console response", bars: [], fetchedAt: Date())
        }
        if scenario?.hasPrefix("subscription-renewals") == true { return renewalResult(for: configuration, scenario: scenario) }
        if scenario?.hasPrefix("google-plan-") == true {
            return googlePlanResult(for: configuration)
        }
        if scenario == "plan-pills" {
            if configuration.providerID == .codex {
                return ProviderUsageResult(accountID: configuration.id, providerID: .codex, title: configuration.displayName,
                                           subtitle: "Loading synthetic plan fixture", bars: [], fetchedAt: Date())
            }
            return planPillResult(for: configuration)
        }
        if scenario?.hasPrefix("metric-evidence-") == true {
            return metricEvidenceResult(for: configuration, scenario: scenario ?? "")
        }
        if !googleSources.isEmpty {
            return googleResult(for: configuration, sources: googleSources, stage: 0)
        }
        if scenario?.hasPrefix("greptile-") == true {
            return ProviderUsageResult(
                accountID: configuration.id, providerID: .greptile, title: configuration.displayName,
                subtitle: "Waiting for synthetic Greptile response", bars: [],
                greptileAllowanceRenewal: cachedGreptileRenewal(scenario: scenario),
                cacheIdentity: cachedGreptileRenewal(scenario: scenario) == nil ? nil : "synthetic-user:synthetic-org",
                fetchedAt: Date()
            )
        }
        if scenario?.hasPrefix("codex-") == true { return codexResult(for: configuration, scenario: scenario) }
        if scenario?.hasPrefix("claude-plan-") == true {
            return ProviderUsageResult(accountID: configuration.id, providerID: .claude, title: configuration.displayName,
                                       subtitle: "Loading synthetic Claude profile", bars: [], fetchedAt: Date())
        }
        if scenario?.hasPrefix("claude-") == true { return claudeResult(for: configuration, scenario: scenario) }
        if scenario?.hasPrefix("github-billing") == true { return githubBillingResult(for: configuration) }
        if scenario?.hasPrefix("grok-cursor-parity") == true || Self.isCursorSessionScenario(scenario) {
            return ProviderUsageResult(
                accountID: configuration.id, providerID: .cursor, title: configuration.displayName,
                subtitle: "Waiting for synthetic Cursor response", bars: [], fetchedAt: Date()
            )
        }
        if scenario?.hasPrefix("grok") == true {
            return configuration.providerID == .grok
                ? grokResult(for: configuration, scenario: scenario)
                : cursorResult(for: configuration, scenario: scenario)
        }
        return result(for: configuration, balance: configuration.id.hasPrefix("ui-navigation-") ? 90 : 25)
    }

    func contentView() -> some View {
        ContentView(
            refreshService: refreshService,
            configurationStore: configurationStore,
            historyStore: historyStore,
            appUpdateController: appUpdateController,
            githubStatusPreferences: statusPreferences,
            githubStatusMonitor: statusMonitor,
            usageAlertNotifier: notifier,
            appReviewPromptPolicy: AppReviewPromptPolicy(defaults: defaults),
            performsLifecycleWork: false,
            widgetSnapshotCoordinator: widgetSnapshotCoordinator,
            watchSnapshotCoordinator: watchSnapshotCoordinator
        )
        .dynamicTypeSize(usesDefaultText ? .large : .accessibility2)
    }

    nonisolated static func codexCredential(for identity: String) -> String {
        let payload = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"\#(identity)"}}"#.utf8)
            .base64EncodedString()
        return CodexCredentialsParser.storedCredential(from: CodexCredentials(
            accessToken: "header.\(payload).signature"
        ))
    }

    private static func providersForPlanPills(
        _ providers: [any UsageProvider], scenario: String?, suiteName: String
    ) -> [any UsageProvider] {
        if scenario?.hasPrefix("opencode-renewal-") == true {
            return [UITestOpenCodeRenewalProvider(secretStore: UITestSecretStore(suite: suiteName))]
        }
        if scenario?.hasPrefix("subscription-renewals") == true {
            return [ProviderID.codex, .claude, .grok, .gemini, .openCodeZen].map { UITestRenewalProvider(providerID: $0, scenario: scenario) }
        }
        if scenario?.hasPrefix("google-plan-") == true {
            return [UITestGooglePlanProvider(providerID: .gemini), UITestGooglePlanProvider(providerID: .openCodeZen)]
        }
        guard scenario == "plan-pills" else { return providers }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UITestCodexPlanURLProtocol.self]
        config.httpAdditionalHeaders = ["X-CodexBar-Fixture-Suite": suiteName]
        let codex = CodexUsageProvider(
            secretStore: UITestSecretStore(suite: suiteName), session: URLSession(configuration: config),
            usageEndpoint: URL(string: "https://codex-plan-fixture.invalid/usage")!,
            resetCreditsEndpoint: URL(string: "https://codex-plan-fixture.invalid/inventory")!
        )
        return [codex] + [ProviderID.claude, .grok, .gemini, .openRouter].map { UITestPlanPillProvider(providerID: $0) }
    }

    private static func seedRenewalAccounts(in store: ProviderConfigurationStore, scenario: String?) {
        guard scenario?.hasPrefix("subscription-renewals") == true, store.configurations.isEmpty else { return }
        for (id, provider, title) in [("monthly", ProviderID.codex, "Personal Codex"), ("annual", .codex, "Work Codex"),
                                      ("google", .gemini, "Personal Google"), ("go", .openCodeZen, "OpenCode Go + Zen"),
                                      ("claude", .claude, "Personal Claude"), ("grok", .grok, "Personal Grok"),
        ] {
            var account = ProviderAccountConfiguration(id: id, providerID: provider, accountLabel: title, authMethod: .browserSession)
            if provider == .openCodeZen { account.openCodeWorkspaceId = "fixture-workspace" }
            _ = store.update(account)
            let secret = provider == .grok ? (try? Self.planPillGrokCredential.encoded()) ?? "invalid-synthetic-credential" : "ui-test-credential"
            precondition(store.saveSecret(secret, for: account))
        }
    }

    nonisolated static func renewalResult(for account: ProviderAccountConfiguration, scenario: String?) -> ProviderUsageResult {
        let now = Date()
        let plan = account.providerID == .claude ? ClaudeUsageParser.planDescriptor(subscriptionType: "max", rateLimitTier: "default_claude_max_20x")
            : account.providerID == .gemini ? GoogleAIPlanParser.parse(Data(#"{"paidTier":{"name":"Google AI Pro (5 TB)"}}"#.utf8))
            : account.providerID == .codex ? ProviderPlanDescriptor.make(providerPrefix: "codex", identifier: "pro", label: "ChatGPT Pro 200",
                                                                        displayLabel: "ChatGPT Pro 200") : nil
        let state: SubscriptionRenewal.State = scenario == "subscription-renewals-canceled" ? .nonRenewing : .renewing
        let offset: Double = account.id == "annual" ? 31_536_000 : account.id == "google" ? 7_200 : 259_200
        var renewal = scenario == "subscription-renewals-unknown" ? nil : SubscriptionRenewal(
            accountID: account.id, providerID: account.providerID, state: state,
            date: now.addingTimeInterval(scenario == "subscription-renewals-past" ? -60 : offset),
            observedAt: now.addingTimeInterval(scenario == "subscription-renewals-stale" ? -90_000 : 0)
        )
        if [.claude, .grok].contains(account.providerID), scenario != "subscription-renewals-unknown" {
            let date = ISO8601DateFormatter().string(from: now.addingTimeInterval(scenario == "subscription-renewals-past" ? -60 : offset))
            let observed = now.addingTimeInterval(scenario == "subscription-renewals-stale" ? -90_000 : 0)
            if account.providerID == .claude {
                let data = Data("{\"status\":\"active\",\"next_charge_at\":\"\(date)\",\"plan_ending_at\":\(state == .nonRenewing ? "\"\(date)\"" : "null")}".utf8)
                renewal = SubscriptionBillingParser.claude(data, configuration: account, at: observed)
            } else {
                let data = Data("{\"subscriptions\":[{\"xaiUserId\":\"synthetic-user\",\"tier\":\"SUBSCRIPTION_TIER_GROK_PRO\",\"status\":\"SUBSCRIPTION_STATUS_ACTIVE\",\"stripe\":{\"currentPeriodEnd\":\"\(date)\",\"cancelAtPeriodEnd\":\(state == .nonRenewing ? "true" : "false")}}]}".utf8)
                renewal = SubscriptionBillingParser.grok(data, configuration: account, owner: "synthetic-user", at: observed)
            }
        }
        return ProviderUsageResult(accountID: account.id, providerID: account.providerID, title: account.displayName,
                                   plan: plan, verifiedGrokPlanName: account.providerID == .grok ? "SuperGrok" : nil,
                                   subtitle: "Synthetic billing fixture. No live account.",
                                   bars: [UsageBar(stableKey: "fixture", label: "Usage", used: 12, limit: 100)],
                                   subscriptionRenewal: renewal, fetchedAt: now)
    }

    private static func seedGooglePlanAccounts(in store: ProviderConfigurationStore, scenario: String?) {
        guard let scenario, scenario.hasPrefix("google-plan-"), store.configurations.isEmpty else { return }
        let variant = String(scenario.dropFirst("google-plan-".count))
        let google = ProviderAccountConfiguration(id: variant, providerID: .gemini, accountLabel: "Personal Google", authMethod: .browserSession)
        _ = store.update(google)
        precondition(store.saveSecret("ui-test-credential", for: google))
        var openCode = ProviderAccountConfiguration(id: "opencode", providerID: .openCodeZen, accountLabel: "OpenCode Go + Zen", authMethod: .browserSession)
        openCode.openCodeWorkspaceId = "fixture-workspace"
        _ = store.update(openCode)
        precondition(store.saveSecret("ui-test-credential", for: openCode))
    }

    nonisolated static func googlePlanResult(for account: ProviderAccountConfiguration) -> ProviderUsageResult {
        let names = ["free": "Google AI Free", "plus": "Google AI Plus (400 GB)", "pro": "Google AI Pro (5 TB)",
                     "ultra": "Google AI Ultra", "ultra5": "Google AI Ultra 5x", "ultra20": "Google AI Ultra 20x",
        ]
        let plan = names[account.id].flatMap { GoogleAIPlanParser.parse(Data("{\"paidTier\":{\"name\":\"\($0)\"}}".utf8)) }
        return ProviderUsageResult(accountID: account.id, providerID: account.providerID, title: account.displayName,
                                   plan: plan, subtitle: "Synthetic subscription fixture",
                                   bars: [UsageBar(stableKey: "fixture", label: "Usage", used: 12, limit: 100)], fetchedAt: Date())
    }

    private static func seedPlanPillAccounts(in store: ProviderConfigurationStore, scenario: String?) {
        guard scenario == "plan-pills", store.configurations.isEmpty else { return }
        for (id, provider, title) in [
            ("pro", ProviderID.codex, "Codex Pro fixture"),
            ("prolite", .codex, "Codex Pro lower tier fixture"),
            ("promax", .codex, "Codex Pro highest tier fixture"),
            ("future-plan", .codex, "Codex unavailable fixture"),
            ("plus", .codex, "Codex Plus fixture"),
            ("free", .codex, "Codex Free fixture"),
            ("max5", .claude, "Claude Max fixture"),
            ("grok-plan", .grok, "SuperGrok Lite"),
            ("google", .gemini, "Long Google AI Ultra account name is not proof of a subscription"),
            ("api", .openRouter, "OpenRouter fixture"),
        ] {
            let account = ProviderAccountConfiguration(
                id: id, providerID: provider, accountLabel: title,
                grokGeneratedLabel: provider == .grok ? title : nil, authMethod: provider == .grok ? .browserSession : .apiKey
            )
            _ = store.update(account)
            precondition(store.saveSecret(provider == .codex ? Self.codexCredential(for: id) : "ui-test-credential", for: account),
                         "Synthetic plan fixture credentials must be saved")
            if provider == .grok {
                let credential = Self.planPillGrokCredential
                _ = store.saveSecret((try? credential.encoded()) ?? "", for: account)
                precondition(store.applyVerifiedGrokPlan(grokResult(for: account, scenario: "grok-default")),
                             "Synthetic verified Grok naming must normalize")
            }
            if provider == .gemini {
                _ = store.saveSecret(#"{"__Secure-1PSID":"synthetic"}"#, for: account)
            }
        }
    }

    nonisolated static var planPillGrokCredential: GrokCredential {
        GrokCredential(
            kind: "grok-oauth-v1", accessToken: "synthetic-token", refreshToken: "synthetic-refresh",
            expiresAt: Date(timeIntervalSince1970: 2_524_608_000), subject: "synthetic-user", email: nil
        )
    }

    nonisolated static func planPillResult(for account: ProviderAccountConfiguration) -> ProviderUsageResult {
        let parsed: ProviderUsageResult?
        switch account.providerID {
        case .grok:
            return grokResult(for: account, scenario: "grok-default")
        case .codex:
            let data = Data("{\"plan_type\":\"\(account.id)\",\"rate_limit\":{\"primary_window\":{\"used_percent\":42,\"reset_at\":1893542400,\"limit_window_seconds\":18000}}}".utf8)
            parsed = CodexUsageParser.parse(data)
        case .claude:
            parsed = ClaudeUsageParser.parse(Data(#"{"five_hour":{"utilization":42}}"#.utf8), subscriptionType: "max_5x")
        default:
            parsed = nil
        }
        return ProviderUsageResult(
            accountID: account.id, providerID: account.providerID, title: account.displayName, plan: parsed?.plan,
            subtitle: "Synthetic plan fixture. No live account.",
            bars: parsed?.bars ?? [UsageBar(stableKey: "fixture", label: "Usage", used: 42, limit: 100)], fetchedAt: Date()
        )
    }

    private static func seedCodexAccounts(in store: ProviderConfigurationStore) {
        for (identity, label) in [("personal", "Personal Codex"), ("work", "Work Codex")] {
            let account = ProviderAccountConfiguration(
                id: "ui-codex-\(identity)", providerID: .codex,
                accountLabel: label, authMethod: .browserSession
            )
            _ = store.update(account)
            _ = store.saveSecret(codexCredential(for: identity), for: account)
        }
    }

    private static func seedGreptileAccount(in store: ProviderConfigurationStore, scenario: String) {
        let account = ProviderAccountConfiguration(
            id: "ui-greptile-free", providerID: .greptile,
            accountLabel: "Greptile Free Fixture", authMethod: scenario.hasPrefix("greptile-renewal-") ? .browserSession : .apiKey
        )
        _ = store.update(account)
        _ = store.saveSecret(account.authMethod == .browserSession ? (try? greptileCredential.encoded()) ?? "" : "ui-test-credential", for: account)
        if ProcessInfo.processInfo.environment["CODEXBAR_UI_TEST_FULL_WIDTH"] == "1" {
            store.updateMetricWidth(.full, accountID: account.id, metricID: GreptileUsageIdentity.completedReviewsMetricID)
        }
    }

    nonisolated static var greptileCredential: GreptileSessionCredentials {
        return GreptileSessionCredentials(
            version: 1, subject: "synthetic-user",
            organization: GreptileOrganization(tenantExternalId: "synthetic-org", name: "Synthetic organization"),
            cookies: [GreptileSessionCookie(name: "__Secure-authjs.session-token", value: "synthetic-cookie", expiresAt: nil)]
        )
    }

    nonisolated static func greptilePayload(scenario: String) -> Data {
        let reviews = #"[{"id":"synthetic-first","status":"COMPLETED"},"#
            + #"{"id":"synthetic-second","status":"COMPLETED"},{"id":"synthetic-skipped","status":"SKIPPED"}]"#
        let payload: String
        switch scenario {
        case "greptile-empty":
            payload = #"{"result":{"codeReviews":[],"total":0}}"#
        case "greptile-returned-quota":
            // Compatibility case only: these optional quota fields are not in the published response schema.
            payload = #"{"result":{"codeReviews":\#(reviews),"total":3,"billingUsage":{"reviewsUsed":3,"includedReviews":17,"billingPeriodStart":"2030-01-01T00:00:00Z","billingPeriodEnd":"2030-01-31T00:00:00Z","plan":"Starter"}}}"#
        default:
            // Hypothetical credit fields must not become a quota without a supported unit contract.
            payload = #"{"result":{"codeReviews":\#(reviews),"total":3,"#
                + #""billingUsage":{"creditsUsed":12,"includedCredits":50,"plan":"Starter"}}}"#
        }
        return Data(payload.utf8)
    }

    nonisolated static func codexResult(
        for account: ProviderAccountConfiguration, scenario: String? = nil
    ) -> ProviderUsageResult {
        let used = account.id == "ui-codex-personal" ? 12.0 : 62.0
        if scenario == "codex-free-thirty-day" {
            return codexThirtyDayResult(for: account, used: used)
        }
        if scenario?.hasPrefix("codex-credits") == true {
            return codexCreditsResult(for: account, scenario: scenario ?? "", used: used)
        }
        return ProviderUsageResult(
            accountID: account.id, providerID: .codex, title: account.displayName,
            subtitle: "Synthetic Codex usage",
            bars: [
                UsageBar(
                    stableKey: "five-hour", label: "Five-hour usage", used: used, limit: 100,
                    resetsAt: Date().addingTimeInterval(18_000), resetDisplayStyle: .relativeWithLocalTime
                ),
            ], fetchedAt: Date()
        )
    }

    nonisolated private static func codexThirtyDayResult(
        for account: ProviderAccountConfiguration, used: Double
    ) -> ProviderUsageResult {
        let now = Date()
        let payload = #"{"plan_type":"free","rate_limit":{"primary_window":{"used_percent":\#(used),"reset_at":\#(Int(now.timeIntervalSince1970) + 864000),"limit_window_seconds":2592000}}}"#
        guard let parsed = CodexUsageParser.parse(Data(payload.utf8), fetchedAt: now) else {
            preconditionFailure("Invalid synthetic Codex thirty-day fixture")
        }
        return ProviderUsageResult(
            accountID: account.id, providerID: .codex, title: account.displayName, plan: parsed.plan,
            subtitle: "Synthetic Codex Free usage. No live account.", bars: parsed.bars, fetchedAt: parsed.fetchedAt
        )
    }

    nonisolated private static func codexCreditsResult(
        for account: ProviderAccountConfiguration, scenario: String, used: Double
    ) -> ProviderUsageResult {
        let credits: String
        switch scenario {
        case "codex-credits-round-up":
            credits = #"{"has_credits":true,"unlimited":false,"balance":"62500.75"}"#
        case "codex-credits-zero":
            credits = #"{"has_credits":false,"unlimited":false,"balance":"0"}"#
        case "codex-credits-unlimited":
            credits = #"{"has_credits":true,"unlimited":true,"balance":null}"#
        case "codex-credits-unavailable":
            credits = #"{"has_credits":true,"unlimited":false,"balance":null}"#
        default:
            let balance = account.id == "ui-codex-personal" ? "62500.125" : "770"
            credits = #"{"has_credits":true,"unlimited":false,"balance":"\#(balance)"}"#
        }
        let now = Date()
        let payload = #"""
        {"credits":\#(credits),"rate_limit":{
        "primary_window":{"used_percent":\#(used),"reset_at":\#(Int(now.timeIntervalSince1970) + 7200),"limit_window_seconds":18000},
        "secondary_window":{"used_percent":34,"reset_at":\#(Int(now.timeIntervalSince1970) + 259200),"limit_window_seconds":604800}}}
        """#
        guard let parsed = CodexUsageParser.parse(Data(payload.utf8), fetchedAt: now, locale: Locale(identifier: "en_US")) else {
            preconditionFailure("Invalid synthetic Codex credits fixture")
        }
        return ProviderUsageResult(
            accountID: account.id, providerID: .codex, title: account.displayName,
            subtitle: "Synthetic Codex usage", bars: parsed.bars,
            unavailableUsageMetrics: parsed.unavailableUsageMetrics,
            cacheIdentity: "ui-codex-credits:\(account.id)", fetchedAt: parsed.fetchedAt
        )
    }

    nonisolated static var claudeProfileCredential: String {
        ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(subscriptionType: "subscription", accessToken: "ui-claude-profile"))
    }

    private static func seedClaudeAccount(in store: ProviderConfigurationStore, scenario: String?) {
        let account = ProviderAccountConfiguration(
            id: "ui-claude", providerID: .claude,
            accountLabel: "Synthetic Claude", authMethod: .browserSession
        )
        _ = store.update(account)
        let credential = scenario?.hasPrefix("claude-plan-") == true ? claudeProfileCredential : "ui-test-credential"
        _ = store.saveSecret(credential, for: account)
    }

    nonisolated static func claudeResult(
        for account: ProviderAccountConfiguration, scenario: String?
    ) -> ProviderUsageResult {
        let now = Date()
        let sessionReset = ISO8601DateFormatter().string(from: now.addingTimeInterval(7_200))
        let weeklyReset = ISO8601DateFormatter().string(from: now.addingTimeInterval(3 * 86_400))
        let legacyData = Data("""
            {"five_hour":{"utilization":42,"resets_at":"\(sessionReset)"},
            "seven_day":{"utilization":64,"resets_at":"\(weeklyReset)"}}
            """.utf8)
        let fableScenario = scenario?.hasPrefix("claude-fable-") == true
        let data = fableScenario ? fableFixtureData(for: account, scenario: scenario ?? "", now: now) : legacyData
        let maxPlan = scenario == "claude-max" || (fableScenario && scenario != "claude-fable-credits")
        guard let parsed = ClaudeUsageParser.parse(data, subscriptionType: maxPlan ? "max_20x" : "pro", fetchedAt: now) else {
            preconditionFailure("Synthetic Claude windows must parse")
        }
        return ProviderUsageResult(
            accountID: account.id, providerID: .claude, title: account.displayName,
            plan: parsed.plan, subtitle: "Synthetic Claude usage. No live account.",
            bars: parsed.bars, monetaryMetrics: parsed.monetaryMetrics,
            usageMessages: parsed.usageMessages, dashboardUsageMessages: parsed.dashboardUsageMessages,
            cardInformationSections: parsed.cardInformationSections, fetchedAt: now
        )
    }

    nonisolated private static func fableFixtureData(
        for account: ProviderAccountConfiguration, scenario: String, now: Date
    ) -> Data {
        let formatter = ISO8601DateFormatter()
        let session = formatter.string(from: now.addingTimeInterval(7_200))
        let weekly = formatter.string(from: now.addingTimeInterval(3 * 86_400))
        let second = account.id == "ui-claude-second"
        let model = scenario == "claude-fable-renamed" ? "Claude Fable 5.1" : "Fable 5"
        var payload: [String: Any] = [
            "five_hour": ["utilization": 42, "resets_at": session],
            "seven_day": ["utilization": 64, "resets_at": weekly],
        ]
        if scenario == "claude-fable-two-accounts" || scenario == "claude-fable-renamed" {
            payload["limits"] = [[
                "kind": "weekly_scoped", "percent": second ? 7 : 21,
                "resets_at": weekly, "is_active": true,
                "scope": ["model": ["display_name": model]],
            ], ]
        } else if scenario == "claude-fable-credits" {
            payload["extra_usage"] = [
                "is_enabled": true, "monthly_limit": 1_000,
                "used_credits": 350, "utilization": 35,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            preconditionFailure("Synthetic Fable fixture must serialize")
        }
        return data
    }

    /// Existing UUID-isolated, network-blocked UI infrastructure only. No live account data.
    private static func seedMetricEvidenceAccount(in store: ProviderConfigurationStore) {
        let account = ProviderAccountConfiguration(
            id: "ui-metric-evidence", providerID: .openRouter,
            accountLabel: "Synthetic Metrics", authMethod: .apiKey
        )
        _ = store.update(account)
        _ = store.saveSecret("ui-test-credential", for: account)
    }

    nonisolated private static func metricEvidenceResult(
        for account: ProviderAccountConfiguration, scenario: String
    ) -> ProviderUsageResult {
        let now = Date()
        let stale = scenario.hasSuffix("-stale")
        let bars: [UsageBar] = scenario.hasSuffix("-money") || scenario.hasSuffix("-balance") ? [] : [
            UsageBar(
                stableKey: "synthetic-over-limit", label: "Synthetic included usage", used: 125, limit: 100,
                resetDescription: "Resets in 2 hours", showProjectionOnCurrentBar: true,
                projectionDescriptionOverride: "Projected to reach 180%", projectionSignificanceOverride: .warning
            ),
        ]
        let money: [ProviderMonetaryMetric] = scenario.hasSuffix("-balance") ? [] : [
            ProviderMonetaryMetric(
                kind: .grossSpend, label: "Synthetic gross spend", minorUnits: Decimal(1248),
                currencyCode: "USD", decimalPlaces: 2, detail: "Reported gross amount before discounts"
            ),
            ProviderMonetaryMetric(
                kind: .spent, label: "Synthetic net spend", minorUnits: Decimal(1199),
                currencyCode: "USD", decimalPlaces: 2, detail: "Reported net amount after discounts"
            ),
        ]
        return ProviderUsageResult(
            accountID: account.id, providerID: account.providerID, title: account.displayName,
            subtitle: "Synthetic metric-rendering evidence. No live provider access.",
            bars: bars, barsFetchedAt: stale ? now.addingTimeInterval(-300) : now,
            creditsRemaining: scenario.hasSuffix("-money") ? nil : 53.25,
            creditsFetchedAt: stale ? now.addingTimeInterval(-300) : now,
            monetaryMetrics: money,
            failureMessage: stale ? "Synthetic provider failure. Showing cached observations." : nil,
            fetchedAt: now
        )
    }

    private static func seedRecoveryAccount(in configurationStore: ProviderConfigurationStore) {
        let group = configurationStore.addGroup(named: "Fixture Team")
        let account = ProviderAccountConfiguration(
            id: "ui-recovery-account",
            providerID: .openRouter,
            accountLabel: "Recovery Account",
            groupID: group?.id,
            authMethod: .apiKey
        )
        _ = configurationStore.update(account)
        _ = configurationStore.saveSecret("ui-test-credential", for: account)
        // Place a distinct URL destination beyond the viewport on either device family.
        for index in 1...5 {
            let navigationAccount = ProviderAccountConfiguration(
                id: "ui-navigation-\(index)",
                providerID: .openRouter,
                accountLabel: index == 5 ? "Target Account" : "Scroll Account \(index)",
                groupID: group?.id,
                authMethod: .apiKey
            )
            _ = configurationStore.update(navigationAccount)
            _ = configurationStore.saveSecret("ui-test-credential", for: navigationAccount)
        }
    }

    private static func seedGrokAccounts(in store: ProviderConfigurationStore, scenario: String?) {
        if scenario?.hasPrefix("grok-cursor-parity-plans") == true {
            for (id, label) in [("pro", "Personal Cursor"), ("pro_plus", "Work Cursor"), ("unknown", "Unknown Cursor")] {
                let account = ProviderAccountConfiguration(id: "ui-cursor-\(id)", providerID: .cursor,
                                                           accountLabel: label, authMethod: .browserSession)
                _ = store.update(account)
                _ = store.saveSecret("cursor-plan-\(id)", for: account)
            }
            return
        }
        let cursorOnly = scenario?.hasPrefix("grok-cursor-parity") == true || Self.isCursorSessionScenario(scenario)
        let grok = ProviderAccountConfiguration(
            id: "ui-grok-connected", providerID: .grok, accountLabel: "SuperGrok Lite",
            grokGeneratedLabel: "SuperGrok Lite", authMethod: .browserSession
        )
        let cursor = ProviderAccountConfiguration(
            id: "ui-cursor-linked", providerID: .cursor, accountLabel: cursorOnly ? "Synthetic Cursor" : "Sample Cursor",
            authMethod: .browserSession
        )
        for account in cursorOnly ? [cursor] : [grok, cursor] {
            _ = store.update(account)
            let secret = Self.isCursorSessionScenario(scenario)
                ? cursorSessionCredential(expired: scenario == "grok-cursor-session-no-prior") : "ui-test-credential"
            _ = store.saveSecret(secret, for: account)
        }
    }

    private static func seedSavedGrokLayout(in store: ProviderConfigurationStore, scenario: String?) {
        let accountID = "ui-grok-connected"
        let weekly = "grok.included-usage"
        let credits = "grok.monetary.balance.usd"
        _ = store.reconcileMetricLayout(accountID: accountID, availableMetricIDs: [credits])
        store.updateMetricWidth(.full, accountID: accountID, metricID: credits)
        guard scenario != "grok-existing-credits-only" else { return }
        store.updateVisualizationStyle(.circularRing, accountID: accountID, metricID: weekly)
        // Simulate the pre-fix saved order after a previous release appended weekly usage.
        store.replaceMetricLayout(
            AccountMetricLayout(
                orderedMetricIDs: [credits, weekly],
                preferences: store.metricLayouts[accountID]?.preferences ?? [:]
            ),
            accountID: accountID
        )
        if scenario == "grok-custom-order" {
            store.updateMetricOrder([credits, weekly], accountID: accountID)
        }
    }

    nonisolated static func grokResult(
        for account: ProviderAccountConfiguration, scenario: String? = nil
    ) -> ProviderUsageResult {
        let now = Date()
        let start = ISO8601DateFormatter().string(from: now.addingTimeInterval(-2 * 86_400))
        let end = ISO8601DateFormatter().string(from: now.addingTimeInterval(5 * 86_400))
        let noAllowance = scenario == "grok-no-allowance"
        let percentField = switch scenario {
        case "grok-zero", "grok-existing-zero", "grok-spending-zero": ""
        case "grok-spending-reported-zero": "\"creditUsagePercent\":0,"
        case "grok-no-allowance", "grok-percent-unavailable", "grok-existing-percent-unavailable",
             "grok-spending-unavailable":
            "\"creditUsagePercent\":null,"
        default: "\"creditUsagePercent\":31,"
        }
        let balance = scenario == "grok-spending" ? "{}" : #"{"val":500}"#
        let data = Data("""
            {"config":{"isUnifiedBillingUser":\(!noAllowance),
            \(percentField)
            "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"\(start)","end":"\(end)"},
            "prepaidBalance":\(balance)}}
            """.utf8)
        return (try? GrokUsageProvider.parseCredits(
            data, configuration: account, subject: "synthetic-user", now: now, verifiedPlanName: "SuperGrok Lite"
        ))
            ?? ProviderUsageResult(
                accountID: account.id, providerID: .grok, title: account.displayName,
                subtitle: "Synthetic Grok usage unavailable", bars: [], fetchedAt: now
            )
    }

    nonisolated static func cursorSessionToken(expired: Bool) -> String {
        let payload = Data("{\"exp\":\(expired ? 1 : 2_524_608_000)}".utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return "eyJhbGciOiJIUzI1NiJ9.\(payload).synthetic-signature"
    }

    nonisolated static func cursorSessionCredential(expired: Bool) -> String {
        CursorWebAuthResult(
            accessToken: cursorSessionToken(expired: expired), refreshToken: nil, authID: "ui-cursor-owner", userID: nil
        ).storedCredential
    }

    nonisolated static func cursorResult(
        for account: ProviderAccountConfiguration, scenario: String? = nil
    ) -> ProviderUsageResult {
        if scenario?.hasPrefix("grok-spending") == true {
            return cursorSpendingResult(for: account, unavailable: scenario == "grok-spending-unavailable")
        }
        return ProviderUsageResult(
            accountID: account.id, providerID: .cursor, title: account.displayName,
            subtitle: "Synthetic Cursor usage", bars: [
                UsageBar(stableKey: "cursor-models", label: "Cursor Models", used: 21, limit: 100),
                UsageBar(stableKey: "grok-bot-weekly", label: "Grok Bot weekly", used: 42, limit: 100),
            ], fetchedAt: Date()
        )
    }

    private nonisolated static func cursorSpendingResult(
        for account: ProviderAccountConfiguration, unavailable: Bool
    ) -> ProviderUsageResult {
        let now = Date()
        let reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(86_400))
        let spending = unavailable ? "" : #","spendLimitUsage":{"individualLimit":2000,"individualUsed":2003}"#
        let primary = Data(#"{"planUsage":{"autoPercentUsed":0,"apiPercentUsed":0}\#(spending)}"#.utf8)
        let weekly = unavailable ? nil : Data(#"""
            {"hasNonZeroIncludedLimit":true,"usagePercent":100,"nextResetTimestampUtc":"\#(reset)"}
            """#.utf8)
        return CursorUsageProvider.parseUsage(
            primary, grokBotUsageData: weekly, configuration: account, fetchedAt: now
        ) ?? ProviderUsageResult(
            accountID: account.id, providerID: .cursor, title: account.displayName,
            subtitle: "Synthetic replay unavailable", bars: [], fetchedAt: now
        )
    }

    private static func seedGitHubBillingAccounts(
        in store: ProviderConfigurationStore,
        scenario: String?
    ) {
        let group = store.addGroup(named: "GitHub Billing")
        let personalID = switch scenario {
        case "github-billing-no-personal-budget": "ui-github-billing-personal-no-budget"
        case "github-billing-incomplete": "ui-github-billing-personal-incomplete"
        case "github-billing-overage": "ui-github-billing-personal-overage"
        default: "ui-github-billing-personal"
        }
        let personal = ProviderAccountConfiguration(
            id: personalID,
            providerID: .githubBilling,
            accountLabel: "Sample Personal",
            groupID: group?.id,
            authMethod: .browserSession,
            githubBillingAccountScope: .personal,
            githubBillingOwner: "sample-personal"
        )
        let organization = ProviderAccountConfiguration(
            id: "ui-github-billing-organization",
            providerID: .githubBilling,
            accountLabel: "Sample Organization",
            groupID: group?.id,
            authMethod: .browserSession,
            githubBillingAccountScope: .organization,
            githubBillingOwner: "sample-organization"
        )
        let accounts: [ProviderAccountConfiguration] = switch scenario {
        case "github-billing-personal",
             "github-billing-no-personal-budget",
             "github-billing-incomplete",
             "github-billing-overage": [personal]
        case "github-billing-organization": [organization]
        default: [personal, organization]
        }
        for account in accounts {
            _ = store.update(account)
            _ = store.saveSecret("ui-test-credential", for: account)
        }
    }

    nonisolated static func githubBillingResult(
        for account: ProviderAccountConfiguration
    ) -> ProviderUsageResult {
        let periodStart = Date().addingTimeInterval(-20 * 24 * 60 * 60)
        let periodEnd = periodStart.addingTimeInterval(30 * 24 * 60 * 60)
        if account.githubBillingAccountScope == .personal {
            if account.id.hasSuffix("no-budget") {
                return noBudgetPersonalBillingResult(account: account)
            }
            if account.id.hasSuffix("incomplete") {
                return incompletePersonalBillingResult(
                    account: account,
                    periodStart: periodStart,
                    periodEnd: periodEnd
                )
            }
            if account.id.hasSuffix("overage") {
                return overagePersonalBillingResult(
                    account: account,
                    periodStart: periodStart,
                    periodEnd: periodEnd
                )
            }
            return healthyPersonalBillingResult(
                account: account,
                periodStart: periodStart,
                periodEnd: periodEnd
            )
        }
        return organizationBillingResult(account: account, periodStart: periodStart, periodEnd: periodEnd)
    }

    nonisolated private static func noBudgetPersonalBillingResult(
        account: ProviderAccountConfiguration
    ) -> ProviderUsageResult {
        return ProviderUsageResult(
                    accountID: account.id,
                    providerID: .githubBilling,
                    title: account.displayName,
                    plan: ProviderPlanDescriptor.make(
                        providerPrefix: ProviderID.githubBilling.rawValue,
                        identifier: "free",
                        label: "Free"
                    ),
                    subtitle: "GitHub personal billing",
                    bars: [
                        UsageBar(
                            stableKey: "actions-allowance-minutes",
                            label: "Actions minutes",
                            used: 0,
                            limit: 2_000,
                            resetsAt: Date().addingTimeInterval(16 * 24 * 60 * 60),
                            resetDisplayStyle: .relativeWithLocalTime
                        ),
                        UsageBar(
                            stableKey: "actions-storage",
                            label: "Actions storage",
                            used: 0,
                            limit: 0.5,
                            resetsAt: Date().addingTimeInterval(16 * 24 * 60 * 60),
                            resetDisplayStyle: .relativeWithLocalTime
                        ),
                    ],
                    usageMessages: [],
                    cardInformationSections: [
                        ProviderCardInformationSection(
                            id: "github-billing.amounts-and-currency",
                            title: "Amounts and currency",
                            items: [
                                ProviderCardInformationItem(
                                    id: "currency",
                                    label: "Currency",
                                    detail: "USD. GitHub's billing API does not report a currency code, "
                                        + "so CodexBar shows the USD amounts GitHub lists. Amounts are not "
                                        + "converted to the device locale."
                                ),
                                ProviderCardInformationItem(
                                    id: "personal-budgets",
                                    label: "Personal budgets",
                                    detail: "GitHub does not expose personal budgets through its public API. "
                                        + "Included allowances and current charges are shown separately."
                                ),
                            ]
                        ),
                    ],
                    fetchedAt: Date()
                )
    }

    nonisolated private static func incompletePersonalBillingResult(
        account: ProviderAccountConfiguration,
        periodStart: Date,
        periodEnd: Date
    ) -> ProviderUsageResult {
        return ProviderUsageResult(
                    accountID: account.id,
                    providerID: .githubBilling,
                    title: account.displayName,
                    plan: ProviderPlanDescriptor.make(
                        providerPrefix: ProviderID.githubBilling.rawValue,
                        identifier: "free",
                        label: "Free"
                    ),
                    subtitle: "GitHub personal billing",
                    bars: [
                        UsageBar(
                            stableKey: "actions-allowance-minutes",
                            label: "Actions minutes",
                            used: 720,
                            limit: 2_000,
                            resetsAt: periodEnd,
                            resetDisplayStyle: .relativeWithLocalTime,
                            projectionCurrent: 720,
                            projectionLimit: 2_000,
                            projectionPeriodStart: periodStart,
                            projectionPeriodEnd: periodEnd,
                            showProjectionOnCurrentBar: true
                        ),
                    ],
                    monetaryMetrics: [
                        ProviderMonetaryMetric(
                            kind: .grossSpend, label: "Gross usage", minorUnits: 1_248,
                            currencyCode: "USD", decimalPlaces: 2
                        ),
                        ProviderMonetaryMetric(
                            kind: .discounts, label: "Discounts", minorUnits: 0,
                            currencyCode: "USD", decimalPlaces: 2
                        ),
                        ProviderMonetaryMetric(
                            kind: .spent,
                            label: "Net spend",
                            minorUnits: 1_248,
                            currencyCode: "USD",
                            decimalPlaces: 2,
                            detail: "Current metered charge"
                        ),
                    ],
                    usageMessages: [
                        "GitHub returned Actions storage without the recognized storage SKU, "
                            + "so the monthly storage allowance is unavailable.",
                    ],
                    cardInformationSections: [
                        ProviderCardInformationSection(
                            id: "github-billing.product.actions",
                            title: "Actions",
                            items: [
                                ProviderCardInformationItem(
                                    id: "consumed",
                                    label: "Consumed usage",
                                    detail: "$12.48 · 720 minutes"
                                ),
                                ProviderCardInformationItem(
                                    id: "discount",
                                    label: "Discount usage",
                                    detail: "$0.00 · Quantity unavailable"
                                ),
                                ProviderCardInformationItem(
                                    id: "billable",
                                    label: "Billable usage",
                                    detail: "$12.48 · Quantity unavailable"
                                ),
                                ProviderCardInformationItem(
                                    id: "included-minutes",
                                    label: "Included usage · Minutes",
                                    detail: "720 of 2,000 minutes used (private standard runners) · "
                                        + "1,280 minutes remaining"
                                ),
                                ProviderCardInformationItem(
                                    id: "included-storage",
                                    label: "Included usage · Storage",
                                    detail: "GitHub returned Actions storage without the recognized storage SKU, "
                                    + "so the monthly storage allowance is unavailable."
                                ),
                            ]
                        ),
                    ],
                    fetchedAt: Date()
                )
    }

    nonisolated private static func healthyPersonalBillingResult(
        account: ProviderAccountConfiguration,
        periodStart: Date,
        periodEnd: Date
    ) -> ProviderUsageResult {
        return ProviderUsageResult(
                accountID: account.id,
                providerID: .githubBilling,
                title: account.displayName,
                plan: ProviderPlanDescriptor.make(
                    providerPrefix: ProviderID.githubBilling.rawValue,
                    identifier: "pro",
                    label: "Pro"
                ),
                subtitle: "GitHub personal billing",
                bars: [
                    UsageBar(
                        stableKey: "actions-allowance-minutes",
                        label: "Actions minutes",
                        used: 1_600,
                        limit: 3_000,
                        resetsAt: periodEnd,
                        resetDisplayStyle: .relativeWithLocalTime,
                        projectionCurrent: 1_600,
                        projectionLimit: 3_000,
                        projectionPeriodStart: periodStart,
                        projectionPeriodEnd: periodEnd,
                        showProjectionOnCurrentBar: true
                    ),
                    UsageBar(
                        stableKey: "actions-storage",
                        label: "Actions storage",
                        used: 0.6,
                        limit: 2,
                        resetsAt: periodEnd,
                        resetDisplayStyle: .relativeWithLocalTime
                    ),
                ],
                monetaryMetrics: [
                    ProviderMonetaryMetric(
                        kind: .grossSpend, label: "Gross usage", minorUnits: 2_520,
                        currencyCode: "USD", decimalPlaces: 2
                    ),
                    ProviderMonetaryMetric(
                        kind: .discounts, label: "Discounts", minorUnits: 1_248,
                        currencyCode: "USD", decimalPlaces: 2
                    ),
                    ProviderMonetaryMetric(
                        kind: .spent,
                        label: "Net spend",
                        minorUnits: 1_272,
                        currencyCode: "USD",
                        decimalPlaces: 2,
                        detail: "Current metered charge"
                    ),
                ],
                usageMessages: [],
                cardInformationSections: [
                    ProviderCardInformationSection(
                        id: "github-billing.product.actions",
                        title: "Actions",
                        items: [
                            ProviderCardInformationItem(
                                id: "actions.consumed",
                                label: "Consumed usage",
                                detail: "$24.80 · 720 minutes · 118 GB-hours"
                            ),
                            ProviderCardInformationItem(
                                id: "actions.discount",
                                label: "Discount usage",
                                detail: "$12.48 · 720 minutes · 60 GB-hours"
                            ),
                            ProviderCardInformationItem(
                                id: "actions.billable",
                                label: "Billable usage",
                                detail: "$12.32 · 0 minutes · 58 GB-hours"
                            ),
                            ProviderCardInformationItem(
                                id: "actions.included.minutes",
                                label: "Included usage · Minutes",
                                detail: "1,600 of 3,000 minutes used (private standard runners) · "
                                    + "1,400 minutes remaining"
                            ),
                            ProviderCardInformationItem(
                                id: "actions.included.storage",
                                label: "Included usage · Storage",
                                detail: "0.6 of 2 GB used (private Actions storage) · 1.4 GB remaining"
                            ),
                        ]
                    ),
                    ProviderCardInformationSection(
                        id: "github-billing.product.copilot",
                        title: "Copilot",
                        items: [
                            ProviderCardInformationItem(
                                id: "copilot.consumed",
                                label: "Consumed usage",
                                detail: "$0.40 · 40 requests"
                            ),
                            ProviderCardInformationItem(
                                id: "copilot.discount",
                                label: "Discount usage",
                                detail: "$0.00"
                            ),
                            ProviderCardInformationItem(
                                id: "copilot.billable",
                                label: "Billable usage",
                                detail: "$0.40"
                            ),
                        ]
                    ),
                    ProviderCardInformationSection(
                        id: "github-billing.amounts-and-currency",
                        title: "Amounts and currency",
                        items: [
                            ProviderCardInformationItem(
                                id: "currency",
                                label: "Currency",
                                detail: "USD. GitHub's billing API does not report a currency code, "
                                    + "so CodexBar shows the USD amounts GitHub lists. Amounts are not "
                                    + "converted to the device locale."
                            ),
                            ProviderCardInformationItem(
                                id: "personal-budgets",
                                label: "Personal budgets",
                                detail: "GitHub does not expose personal budgets through its public API. "
                                    + "Included allowances and current charges are shown separately."
                            ),
                        ]
                    ),
                ],
                fetchedAt: Date()
            )
    }

    nonisolated private static func overagePersonalBillingResult(
        account: ProviderAccountConfiguration,
        periodStart: Date,
        periodEnd: Date
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: account.id,
            providerID: .githubBilling,
            title: account.displayName,
            plan: ProviderPlanDescriptor.make(
                providerPrefix: ProviderID.githubBilling.rawValue,
                identifier: "free",
                label: "Free"
            ),
            subtitle: "GitHub personal billing",
            bars: [
                UsageBar(
                    stableKey: "actions-allowance-minutes",
                    label: "Actions minutes",
                    used: 2_500,
                    limit: 2_000,
                    resetsAt: periodEnd,
                    resetDisplayStyle: .relativeWithLocalTime,
                    projectionCurrent: 2_500,
                    projectionLimit: 2_000,
                    projectionPeriodStart: periodStart,
                    projectionPeriodEnd: periodEnd,
                    showProjectionOnCurrentBar: true
                ),
            ],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .grossSpend, label: "Gross usage", minorUnits: 2_000,
                    currencyCode: "USD", decimalPlaces: 2
                ),
                ProviderMonetaryMetric(
                    kind: .discounts, label: "Discounts", minorUnits: 1_200,
                    currencyCode: "USD", decimalPlaces: 2
                ),
                ProviderMonetaryMetric(
                    kind: .spent, label: "Net spend", minorUnits: 800,
                    currencyCode: "USD", decimalPlaces: 2
                ),
            ],
            cardInformationSections: [
                ProviderCardInformationSection(
                    id: "github-billing.product.actions",
                    title: "Actions",
                    items: [
                        ProviderCardInformationItem(
                            id: "actions.consumed",
                            label: "Consumed usage",
                            detail: "$20.00 · 2,500 minutes"
                        ),
                        ProviderCardInformationItem(
                            id: "actions.discount",
                            label: "Discount usage",
                            detail: "$12.00 · 2,000 minutes"
                        ),
                        ProviderCardInformationItem(
                            id: "actions.billable",
                            label: "Billable usage",
                            detail: "$8.00 · 500 minutes"
                        ),
                        ProviderCardInformationItem(
                            id: "actions.included.minutes",
                            label: "Included usage · Minutes",
                            detail: "2,500 of 2,000 minutes used (private standard runners) · "
                                + "500 minutes over allowance"
                        ),
                    ]
                ),
            ],
            fetchedAt: Date()
        )
    }

    nonisolated private static func organizationBillingResult(
        account: ProviderAccountConfiguration,
        periodStart: Date,
        periodEnd: Date
    ) -> ProviderUsageResult {
        return ProviderUsageResult(
            accountID: account.id,
            providerID: .githubBilling,
            title: account.displayName,
            plan: ProviderPlanDescriptor.make(
                providerPrefix: ProviderID.githubBilling.rawValue,
                identifier: "organization-team",
                label: "Team"
            ),
            subtitle: "GitHub organization billing",
            bars: [
                UsageBar(
                    stableKey: "actions-allowance-minutes",
                    label: "Actions minutes",
                    used: 1_500,
                    limit: 3_000,
                    resetsAt: periodEnd,
                    resetDisplayStyle: .relativeWithLocalTime,
                    projectionCurrent: 1_500,
                    projectionLimit: 3_000,
                    projectionPeriodStart: periodStart,
                    projectionPeriodEnd: periodEnd,
                    showProjectionOnCurrentBar: true
                ),
                UsageBar(
                    stableKey: "actions-storage",
                    label: "Actions storage",
                    used: 0.69,
                    limit: 2,
                    resetsAt: periodEnd,
                    resetDisplayStyle: .relativeWithLocalTime
                ),
                UsageBar(
                    stableKey: "budget-actions",
                    label: "Actions budget",
                    used: 62,
                    limit: 100,
                    resetsAt: periodEnd,
                    projectionCurrent: 62,
                    projectionLimit: 100,
                    projectionPeriodStart: periodStart,
                    projectionPeriodEnd: periodEnd,
                    showProjectionOnCurrentBar: true
                ),
            ],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .grossSpend, label: "Gross usage", minorUnits: 7_000,
                    currencyCode: "USD", decimalPlaces: 2
                ),
                ProviderMonetaryMetric(
                    kind: .discounts, label: "Discounts", minorUnits: 800,
                    currencyCode: "USD", decimalPlaces: 2
                ),
                ProviderMonetaryMetric(
                    kind: .spent, label: "Net spend", minorUnits: 6_200,
                    currencyCode: "USD", decimalPlaces: 2
                ),
            ],
            cardInformationSections: [
                ProviderCardInformationSection(
                    id: "github-billing.product.actions",
                    title: "Actions",
                    items: [
                        ProviderCardInformationItem(
                            id: "actions.included.minutes",
                            label: "Included usage · Minutes",
                            detail: "1,500 of 3,000 minutes used (private standard runners) · "
                                + "1,500 minutes remaining"
                        ),
                        ProviderCardInformationItem(
                            id: "actions.included.storage",
                            label: "Included usage · Storage",
                            detail: "0.69 of 2 GB used (private Actions storage) · 1.31 GB remaining"
                        ),
                    ]
                ),
                ProviderCardInformationSection(
                    id: "github-billing.budget.actions",
                    title: "Actions budget",
                    items: [
                        ProviderCardInformationItem(id: "scope", label: "Product budget", detail: "Actions"),
                        ProviderCardInformationItem(id: "behavior", label: "Behavior", detail: "Hard stop"),
                        ProviderCardInformationItem(id: "spend", label: "Current net spend", detail: "$62.00"),
                        ProviderCardInformationItem(
                            id: "remaining",
                            label: "Remaining headroom",
                            detail: "$38.00 · 62% consumed"
                        ),
                    ]
                ),
            ],
            fetchedAt: Date()
        )
    }

    private static func googleSources(for scenario: String?) -> [ProviderID] {
        switch scenario {
        case "google-six": [.gemini, .antigravity]
        case "google-coding-only": [.antigravity]
        case "google-apps-only": [.gemini]
        default: []
        }
    }

    nonisolated static let codingCredential: String = {
        do {
            return try AntigravityCredentials.parse(
                #"{"access_token":"ui-test-coding-token","expiry":"2030-01-01T00:00:00Z"}"#
            ).encoded()
        } catch {
            preconditionFailure("The fixed synthetic coding credential must be valid")
        }
    }()

    private static func seedGoogleAccounts(in store: ProviderConfigurationStore, sources: [ProviderID]) {
        let account = ProviderAccountConfiguration(
            id: "ui-google-gemini",
            providerID: .gemini,
            accountLabel: "Gemini Fixture",
            authMethod: .browserSession
        )
        _ = store.update(account)
        if sources.contains(.gemini) {
            _ = store.saveSecret("ui-test-credential", for: account)
        }
        if sources.contains(.antigravity) {
            _ = store.saveGeminiCodingSecret(codingCredential, for: account, confirmedSameAccount: true)
        }
    }

    nonisolated static func googleResult(
        for account: ProviderAccountConfiguration,
        sources: [ProviderID],
        stage: Int
    ) -> ProviderUsageResult {
        let definitions = GoogleUsageMetricCatalog.definitions(for: .gemini)
        let used: [String: Double] = [
            "five-hour": 12, "weekly": 45,
            "gemini-5h": stage >= 3 ? 100 : 0, "gemini-weekly": 31,
            "3p-5h": stage >= 3 ? 20 : 0, "3p-weekly": stage >= 3 ? 60 : 0,
        ]
        var unavailable: [String: String] = [:]
        for definition in definitions where !sources.contains(definition.sourceProviderID) {
            unavailable[definition.id] = "Setup required"
        }
        if sources.contains(.antigravity) && stage == 1 {
            unavailable["antigravity.gemini-weekly"] = "Unavailable"
            unavailable["antigravity.3p-5h"] = GoogleUsageMetricCatalog.disabledReason
        }
        let bars = definitions.compactMap { definition -> UsageBar? in
            guard unavailable[definition.id] == nil, let value = used[definition.key] else { return nil }
            return UsageBar(
                stableKey: definition.key, label: definition.label, used: value, limit: 100,
                resetsAt: Date().addingTimeInterval(definition.window == "5h" ? 18_000 : 604_800),
                resetDisplayStyle: .relativeWithLocalTime
            )
        }
        return ProviderUsageResult(
            accountID: account.id, providerID: .gemini, title: account.displayName,
            subtitle: "Gemini Apps and coding usage",
            bars: bars, unavailableUsageMetrics: unavailable, fetchedAt: Date()
        )
    }

    private func seedHistory() {
        let now = Date()
        for hoursAgo in [48.0, 1.0, 0.0] {
            let results = configurationStore.configurations.map {
                Self.result(
                    for: $0,
                    balance: $0.id.hasPrefix("ui-navigation-") ? 90 : 25,
                    fetchedAt: now.addingTimeInterval(-hoursAgo * 3_600)
                )
            }
            historyStore.record(results: results, now: now)
        }
    }

    nonisolated static func result(
        for configuration: ProviderAccountConfiguration,
        balance: Double,
        fetchedAt: Date = Date()
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openRouter,
            title: configuration.displayName,
            subtitle: "Synthetic UI test balance",
            bars: [],
            creditsRemaining: balance,
            fetchedAt: fetchedAt
        )
    }
}

private struct UITestSecretStore: SecretStore {
    let suite: String

    func readSecret(account: String) throws -> String? {
        UserDefaults(suiteName: suite)?.string(forKey: "fixture-secret.\(account)")
    }

    func saveSecret(_ secret: String, account: String) throws {
        let coding = try? AntigravityCredentials.parse(secret)
        let expectedCoding = try AntigravityCredentials.parse(UITestFixtures.codingCredential)
        let codex = ["personal", "work", "pro", "prolite", "promax", "future-plan", "plus", "free"].contains {
            secret == UITestFixtures.codexCredential(for: $0)
        }
        let cursor = [false, true].contains { secret == UITestFixtures.cursorSessionCredential(expired: $0) }
        let greptile = GreptileSessionCredentials.parse(secret) == UITestFixtures.greptileCredential
        let grok = GrokCredential.parse(secret) == UITestFixtures.planPillGrokCredential
        let billing = SubscriptionBillingSession.parse(secret)
        let fixtureBilling = billing.map {
            ($0.providerID == .claude && $0.ownerID == UITestSubscriptionBillingProtocol.claudeOwner
                && $0.organizationID == UITestSubscriptionBillingProtocol.claudeOrganization
                || $0.providerID == .grok && $0.ownerID == "synthetic-user" && $0.organizationID == nil)
                && $0.cookies.count == 1 && $0.cookies[0].value == "matching"
        } ?? false
        let openCode = OpenCodeConsoleCredential.parse(secret).map {
            $0.accessToken == "synthetic-access" && $0.refreshToken == "synthetic-refresh"
                && $0.userID == "user_synthetic" && $0.workspaceID == "org_synthetic"
        } == true
        guard secret.hasPrefix("cursor-plan-") || secret == "ui-test-credential" || coding == expectedCoding || codex || cursor || greptile || grok || openCode
                || secret == UITestFixtures.claudeProfileCredential || fixtureBilling else {
            throw UITestFixtureError.invalidCredential
        }
        UserDefaults(suiteName: suite)?.set(secret, forKey: "fixture-secret.\(account)")
    }

    func deleteSecret(account: String) throws {
        UserDefaults(suiteName: suite)?.removeObject(forKey: "fixture-secret.\(account)")
    }
}

private actor UITestUsageProvider: UsageProvider {
    nonisolated let providerID = ProviderID.openRouter
    private var failsNextRefresh: Bool

    init(failsFirstRefresh: Bool) {
        failsNextRefresh = failsFirstRefresh
    }

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        if configuration.id.hasPrefix("ui-navigation-") {
            return UITestFixtures.result(for: configuration, balance: 90)
        }
        if failsNextRefresh && configuration.id == "ui-recovery-account" {
            failsNextRefresh = false
            throw UITestFixtureError.refreshFailed
        }
        return UITestFixtures.result(for: configuration, balance: 60)
    }
}

private actor UITestCodexProvider: UsageProvider {
    nonisolated let providerID = ProviderID.codex
    private let scenario: String?
    init(scenario: String?) { self.scenario = scenario }
    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        if scenario == "codex-credits-failure" {
            return ProviderUsageResult(
                accountID: configuration.id, providerID: .codex, title: configuration.displayName,
                subtitle: "Synthetic refresh failed", bars: [], failureMessage: "Synthetic refresh failed",
                cacheIdentity: "ui-codex-credits:\(configuration.id)", allowsUnscopedCacheReuse: true, fetchedAt: Date()
            )
        }
        return UITestFixtures.codexResult(for: configuration, scenario: scenario)
    }
}

/// The fixture supplies only HTTP responses; the production client resolves the displayed plan.
private actor UITestClaudeProfileProvider: UsageProvider {
    nonisolated let providerID = ProviderID.claude
    private let clock = UITestClaudeProfileClock()
    private let provider: ClaudeUsageProvider
    private var fetchCount = 0

    init(suiteName: String) {
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [UITestClaudeProfileProtocol.self]
        let clock = self.clock
        provider = ClaudeUsageProvider(secretStore: UITestSecretStore(suite: suiteName),
                                       session: URLSession(configuration: settings), now: { clock.date })
    }

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        if fetchCount > 0 { clock.advance() }
        fetchCount += 1
        return try await provider.fetchUsage(for: configuration)
    }
}

private final class UITestClaudeProfileClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Date()
    var date: Date { lock.withLock { stored } }
    func advance() { lock.withLock { stored = stored.addingTimeInterval(301) } }
}

private final class UITestClaudeProfileProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var profileCount = 0
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let url = request.url, url.host == "api.anthropic.com",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer ui-claude-profile",
              ["/api/oauth/profile", "/api/oauth/usage"].contains(url.path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let body: String
        if url.path == "/api/oauth/profile" {
            let count = Self.lock.withLock { Self.profileCount += 1; return Self.profileCount }
            let scenario = ProcessInfo.processInfo.environment["CODEXBAR_UI_TEST_SCENARIO"] ?? ""
            switch scenario {
            case "claude-plan-pro": body = #"{"organization":{"organization_type":"claude_pro"}}"#
            case "claude-plan-max20":
                body = Self.maxProfile(multiplier: 20)
            case "claude-plan-change": body = Self.maxProfile(multiplier: count == 1 ? 5 : 20)
            default: body = #"{"organization":{"organization_type":"future_plan"}}"#
            }
        } else {
            let reset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(7_200))
            body = #"{"five_hour":{"utilization":42,"resets_at":"\#(reset)"}}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func maxProfile(multiplier: Int) -> String {
        #"{"organization":{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_\#(multiplier)x"}}"#
    }
}

private actor UITestClaudeProvider: UsageProvider {
    nonisolated let providerID = ProviderID.claude
    private let scenario: String?
    init(scenario: String?) { self.scenario = scenario }
    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        UITestFixtures.claudeResult(for: configuration, scenario: scenario)
    }
}

private actor UITestGrokProvider: UsageProvider {
    nonisolated let providerID = ProviderID.grok
    private let scenario: String?
    init(scenario: String?) { self.scenario = scenario }
    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        UITestFixtures.grokResult(for: configuration, scenario: scenario)
    }
}

private actor UITestCursorProvider: UsageProvider {
    nonisolated let providerID = ProviderID.cursor
    private let scenario: String?
    private let secretStore: UITestSecretStore
    private var stage = 0
    private var accountStages: [String: Int] = [:]

    init(scenario: String?, secretStore: UITestSecretStore) {
        self.scenario = scenario
        self.secretStore = secretStore
    }

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        guard let scenario, scenario.hasPrefix("grok-cursor-parity") || UITestFixtures.isCursorSessionScenario(scenario) else {
            return UITestFixtures.cursorResult(for: configuration, scenario: scenario)
        }
        stage += 1
        let plans = scenario.hasPrefix("grok-cursor-parity-plans")
        accountStages[configuration.id, default: 0] += 1
        let accountStage = accountStages[configuration.id, default: 0]
        if stage == 2 && scenario.hasPrefix("grok-cursor-parity") && !plans { throw UITestFixtureError.refreshFailed }
        if stage == 2 && ["grok-cursor-session-stale", "grok-cursor-session-stale-dark-large"].contains(scenario) {
            try secretStore.saveSecret(
                UITestFixtures.cursorSessionCredential(expired: true), account: ProviderConfigurationStore.keychainAccount(for: configuration)
            )
        }
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [UITestCursorParityProtocol.self]
        settings.httpCookieStorage = nil
        settings.httpShouldSetCookies = false
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let base = "https://cursor-parity-fixture.invalid/\(scenario)/\(configuration.id)/\(accountStage)/"
        return try await CursorUsageProvider(
            secretStore: secretStore, session: session,
            usageEndpoint: URL(string: "\(base)GetCurrentPeriodUsage")!,
            grokBotUsageEndpoint: URL(string: "\(base)GetSandUsageStatus")!,
            membershipEndpoint: URL(string: "\(base)full_stripe_profile")!
        ).fetchUsage(for: configuration)
    }
}

private final class UITestCursorParityProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var stopped = false
    private var pending: DispatchWorkItem?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {
        lock.withLock { stopped = true; pending?.cancel(); pending = nil }
    }

    override func startLoading() {
        guard let url = request.url, url.host == "cursor-parity-fixture.invalid" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if url.path.contains("grok-cursor-parity-plans") && url.lastPathComponent == "full_stripe_profile" {
            let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let value = token.replacingOccurrences(of: "Bearer cursor-plan-", with: "")
            complete(status: 200, body: #"{"membershipType":"\#(value)"}"#)
        } else if url.lastPathComponent == "GetCurrentPeriodUsage" {
            if url.path.contains("grok-cursor-parity-plans") && url.pathComponents.contains("2") {
                complete(status: 503, body: "{}")
                return
            }
            let fresh = request.cachePolicy == .reloadIgnoringLocalCacheData
            complete(status: 200, body: fresh
                     ? Self.currentBody(for: url)
                     : #"{"planUsage":{"autoPercentUsed":0,"apiPercentUsed":0}}"#)
        } else if url.lastPathComponent == "GetSandUsageStatus" {
            if url.path.contains("unavailable") || url.pathComponents.contains(where: { UITestFixtures.isCursorSessionScenario($0) }) {
                complete(status: 403, body: "{}")
            } else {
                let reset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(5 * 86_400))
                let body = #"{"hasNonZeroIncludedLimit":true,"usagePercent":41,"nextResetTimestampUtc":"\#(reset)"}"#
                let work = DispatchWorkItem { [weak self] in self?.complete(status: 200, body: body) }
                lock.withLock { pending = work }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2.5, execute: work)
            }
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        }
    }

    private static func currentBody(for url: URL) -> String {
        if url.pathComponents.contains("grok-cursor-session-zero-dark-large") {
            return #"{"planUsage":{"autoPercentUsed":0,"apiPercentUsed":0}}"#
        }
        if url.pathComponents.contains(where: { UITestFixtures.isCursorSessionScenario($0) }) {
            return #"{"planUsage":{"autoPercentUsed":0.1,"apiPercentUsed":13}}"#
        }
        return #"{"planUsage":{"autoPercentUsed":0.1,"apiPercentUsed":3}}"#
    }

    private func complete(status: Int, body: String) {
        lock.withLock {
            guard !stopped, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

@MainActor
final class UITestCursorAuthFlow: CursorWebAuthenticating, CodexBrowserPresenting {
    var stageChanged: ((GrokFixtureStage?) -> Void)?
    private var continuation: CheckedContinuation<CursorWebAuthResult, Error>?

    func present(url: URL, prefersEphemeralSession: Bool, onCancel: @escaping () -> Void) -> Bool {
        stageChanged?(.approval)
        return true
    }

    func signIn(presentAuthorizationURL: @escaping @MainActor (URL) -> Bool) async throws -> CursorWebAuthResult {
        guard presentAuthorizationURL(CursorWebAuthService.authorizationURL(uuid: "synthetic", codeChallenge: "synthetic")) else {
            throw CursorWebAuthService.AuthError.couldNotStartBrowserSession
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: { Task { @MainActor in self.finish() } }
    }

    func approve() {
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: CursorWebAuthResult(
            accessToken: UITestFixtures.cursorSessionToken(expired: false), refreshToken: nil,
            authID: "ui-cursor-owner", userID: nil
        ))
    }

    func finish() {
        let waiting = continuation
        continuation = nil
        waiting?.resume(throwing: CancellationError())
        stageChanged?(nil)
    }
}

private actor UITestGitHubBillingProvider: UsageProvider {
    nonisolated let providerID = ProviderID.githubBilling

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        UITestFixtures.githubBillingResult(for: configuration)
    }
}

private actor UITestGoogleProvider: UsageProvider {
    nonisolated let providerID = ProviderID.gemini
    private let sources: [ProviderID]
    private var stage = 0

    init(sources: [ProviderID]) { self.sources = sources }

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        stage += 1
        if stage == 2 && sources == [.antigravity] { throw UITestFixtureError.refreshFailed }
        return UITestFixtures.googleResult(for: configuration, sources: sources, stage: stage)
    }
}

private enum UITestFixtureError: LocalizedError {
    case invalidCredential
    case refreshFailed

    var errorDescription: String? {
        switch self {
        case .invalidCredential: "Only the synthetic UI test credential is accepted."
        case .refreshFailed: "Fixture refresh failed. Retry to recover."
        }
    }
}

struct UITestOpenCodeSessionValidator: OpenCodeSessionValidating {
    func validate(credential: String, configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        guard credential == "ui-test-credential" else { throw OpenCodeSignInError.validationFailed }
        guard ProcessInfo.processInfo.environment["CODEXBAR_UI_TEST_OPENCODE_FAILURE"] != "1" else {
            throw OpenCodeSignInError.validationFailed
        }
        return ProviderUsageResult(
            accountID: configuration.id, providerID: .openCodeZen, title: configuration.displayName,
            subtitle: "Synthetic OpenCode usage", bars: [], creditsRemaining: 25, fetchedAt: Date()
        )
    }
}

@MainActor
final class UITestNotifier: UsageAlertNotifying, GitHubStatusNotifying {
    func requestAuthorization() async -> Bool {
        ProcessInfo.processInfo.environment["CODEXBAR_UI_TEST_NOTIFICATION_GRANTED"] == "1"
    }
    func deliver(_ notification: UsageAlertNotification) async throws {}
    func deliverGitHubStatus(_ notification: GitHubStatusNotification) async throws {}
}

@MainActor
private final class UITestWatchSender: WatchSnapshotSending {
    func activate(onSnapshotNeeded: @escaping @MainActor (Bool) -> Void) {}
    func publish(_ snapshot: WatchDashboardSnapshot, force: Bool) -> Bool { false }
}

private struct UITestGreptileProvider: UsageProvider {
    let providerID = ProviderID.greptile
    let secretStore: any SecretStore

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [UITestNetworkBlocker.self]
        settings.httpCookieStorage = nil
        settings.urlCredentialStorage = nil
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let provider = GreptileUsageProvider(
            secretStore: secretStore, session: session,
            endpoint: URL(string: "https://greptile-fixture.invalid/mcp")!,
            dashboardBaseURL: URL(string: "https://greptile-fixture.invalid")!
        )
        return try await provider.fetchUsage(for: configuration)
    }
}

/// Defense in depth: unexpected URLSession traffic must never reach a provider.
private final class UITestNetworkBlocker: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let scenario = ProcessInfo.processInfo.environment["CODEXBAR_UI_TEST_SCENARIO"] ?? ""
        guard request.url?.host == "greptile-fixture.invalid",
              scenario.hasPrefix("greptile-") else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if scenario == "greptile-renewal-stale" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let expiredBilling = ["greptile-renewal-expired", "greptile-renewal-paid-expired"].contains(scenario)
            && request.url?.path == "/api/trpc/billing.getState"
        let status = expiredBilling ? 401 : (scenario == "greptile-failure" ? 503 : 200)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload(for: request, scenario: scenario))
        client?.urlProtocolDidFinishLoading(self)
    }
    private static func payload(for request: URLRequest, scenario: String) -> Data {
        switch request.url?.path {
        case "/api/auth/session":
            let payload = #"{"user":{"greptileId":"synthetic-user","greptileToken":"synthetic-token","#
                + #""organizations":[{"tenantExternalId":"synthetic-org","name":"Synthetic organization"}]}}"#
            return Data(payload.utf8)
        case "/api/trpc/billing.getState":
            let end: Any
            switch scenario {
            case "greptile-renewal-missing": end = NSNull()
            case "greptile-renewal-malformed": end = "invalid"
            case "greptile-renewal-passed": end = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
            default: end = ISO8601DateFormatter().string(from: Date().addingTimeInterval(604_800))
            }
            let kind = ["greptile-renewal-paid": "paid", "greptile-renewal-unknown": "unknown"][scenario] ?? "free"
            var state: [String: Any] = ["kind": kind, "currentPeriod": ["end": end]]
            if ["greptile-renewal-available", "greptile-renewal-exhausted", "greptile-renewal-overage"].contains(scenario) {
                state["used"] = ["greptile-renewal-exhausted": 50, "greptile-renewal-overage": 52][scenario] ?? 12
                state["includedCreditsPerPeriod"] = 50
            }
            return (try? JSONSerialization.data(withJSONObject: [["result": ["data": ["json": state]]]])) ?? Data()
        case "/mcp": return UITestFixtures.greptilePayload(scenario: scenario)
        default: return Data()
        }
    }
    override func stopLoading() {}
}

private class UITestCodexPlanURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "codex-plan-fixture.invalid", request.httpMethod == "GET",
              let suite = request.value(forHTTPHeaderField: "X-CodexBar-Fixture-Suite"),
              let defaults = UserDefaults(suiteName: suite),
              let accountID = request.value(forHTTPHeaderField: "ChatGPT-Account-Id"),
              let credential = CodexCredentialsParser.parse(UITestFixtures.codexCredential(for: accountID)),
              request.value(forHTTPHeaderField: "Authorization") == "Bearer \(credential.accessToken)",
              let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let count = Self.lock.withLock {
            let key = "codex-plan-requests-\(accountID)"
            let count = defaults.integer(forKey: key) + 1
            if url.path == "/usage" { defaults.set(count, forKey: key) }
            return count
        }
        // The More-tier fixture upgrades on refresh; other accounts remain independent.
        let plan = accountID == "pro" && count > 1 ? "promax" : accountID
        let body = url.path == "/usage" ? #"""
        {"plan_type":"\#(plan)","rate_limit":{"primary_window":{
        "used_percent":42,"reset_at":1893542400,"limit_window_seconds":18000}}}
        """# : "{}"
        let status = url.path == "/usage" ? 200 : 503
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct UITestRenewalProvider: UsageProvider {
    let providerID: ProviderID
    let scenario: String?
    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        UITestFixtures.renewalResult(for: configuration, scenario: scenario)
    }
}

private struct UITestGooglePlanProvider: UsageProvider {
    let providerID: ProviderID

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        UITestFixtures.googlePlanResult(for: configuration)
    }
}

private struct UITestPlanPillProvider: UsageProvider {
    let providerID: ProviderID

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        UITestFixtures.planPillResult(for: configuration)
    }
}

#endif

#if DEBUG
import Foundation

actor UITestClaudeResetProvider: UsageProvider, ClaudeUsageResetConsuming {
    nonisolated let providerID = ProviderID.claude
    private let scenario: String
    private let defaults: UserDefaults
    private var requestsByAccount: [String: Int]
    private var remainingByAccount: [String: Int]
    private var uncertainAccounts: Set<String>

    init(scenario: String, suiteName: String) {
        self.scenario = scenario
        let defaults = UserDefaults(suiteName: suiteName)!
        self.defaults = defaults
        requestsByAccount = defaults.dictionary(forKey: "fixtureClaudeResetRequests") as? [String: Int] ?? [:]
        remainingByAccount = defaults.dictionary(forKey: "fixtureClaudeResetRemaining") as? [String: Int] ?? [:]
        uncertainAccounts = Set(defaults.stringArray(forKey: "fixtureClaudeResetUncertain") ?? [])
    }

    func fetchUsage(for account: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        Self.result(for: account, scenario: scenario, requests: requestsByAccount[account.id, default: 0],
                    remaining: remainingByAccount[account.id, default: account.id == "ui-claude-second" ? 1 : 2])
    }

    func consumeClaudeReset(
        for account: ProviderAccountConfiguration, grantID: String, confirmedGrant: ClaudeUsageResetGrant, credentialBinding: String
    ) async throws -> ClaudeUsageResetOutcome {
        let remaining = remainingByAccount[account.id, default: account.id == "ui-claude-second" ? 1 : 2]
        guard ["ui-claude", "ui-claude-second"].contains(account.id), grantID == "fixture_grant", remaining > 0,
              confirmedGrant.id == grantID, confirmedGrant.remainingCount == remaining, confirmedGrant.isCurrent(at: Date()),
              credentialBinding == ClaudeUsageResetClient.credentialBinding(for: "ui-test-credential")
        else { throw ClaudeUsageResetError.unavailable }
        guard !uncertainAccounts.contains(account.id) else { throw ClaudeUsageResetError.indeterminate }
        requestsByAccount[account.id, default: 0] += 1
        defaults.set(requestsByAccount, forKey: "fixtureClaudeResetRequests")
        if scenario == "claude-resets-error" {
            uncertainAccounts.insert(account.id)
            defaults.set(Array(uncertainAccounts), forKey: "fixtureClaudeResetUncertain")
            throw ClaudeUsageResetError.indeterminate
        }
        remainingByAccount[account.id] = remaining - 1
        defaults.set(remainingByAccount, forKey: "fixtureClaudeResetRemaining")
        return .reset
    }

    nonisolated static func result(
        for account: ProviderAccountConfiguration, scenario: String, requests: Int = 0, remaining: Int? = nil
    ) -> ProviderUsageResult {
        let remaining = scenario == "claude-resets-zero" ? 0 : remaining ?? (account.id == "ui-claude-second" ? 1 : 2)
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let expiring = ["claude-resets-boundary", "claude-resets-dashboard-expiry"].contains(scenario)
        let endOffset: TimeInterval = scenario == "claude-resets-expired" ? -3600 : expiring ? 30 : 7 * 86400
        let end = formatter.string(from: now.addingTimeInterval(endOffset))
        let startOffset: TimeInterval = scenario == "claude-resets-dashboard-start" ? 30
            : scenario == "claude-resets-inactive" ? 3600 : -7200
        let cooldown = scenario == "claude-resets-cooldown"
            ? ",\"cooldown_until\":\"\(formatter.string(from: now.addingTimeInterval(30)))\"" : ""
        let start = formatter.string(from: now.addingTimeInterval(startOffset))
        let session = formatter.string(from: now.addingTimeInterval(7200))
        let weekly = formatter.string(from: now.addingTimeInterval(3 * 86400))
        let payload = """
        {"five_hour":{"utilization":\(requests > 0 && scenario != "claude-resets-error" ? 0 : 42),"resets_at":"\(session)"},
         "seven_day":{"utilization":\(requests > 0 && scenario != "claude-resets-error" ? 0 : 64),"resets_at":"\(weekly)"},
         "cedar_ember":{"eligible":\(scenario != "claude-resets-ineligible"),"next_grant_id":"fixture_grant"\(cooldown),"grants":[{
           "id":"fixture_grant","label":"Saved Claude reset","resets_left":\(remaining),
           "starts_at":"\(start)","ends_at":"\(end)","clears":["five_hour","seven_day"],
           "paused":\(scenario == "claude-resets-paused"),"usable_now":true
         }]}}
        """
        let data = Data(payload.utf8)
        let parsed = ClaudeUsageParser.parse(data, subscriptionType: "max_20x", fetchedAt: now)!
        let inventoryData = scenario == "claude-resets-malformed"
            ? Data(#"{"cedar_ember":{"eligible":true,"grants":"invalid"}}"#.utf8) : data
        let inventory = scenario == "claude-resets-unknown" ? nil
            : ClaudeUsageResetInventoryParser.parse(inventoryData)?.bound(toAccessToken: "ui-test-credential")
        return ProviderUsageResult(accountID: account.id, providerID: .claude, title: account.displayName,
                                   plan: parsed.plan, subtitle: "Synthetic Claude resets. No live account. Reset requests: \(requests)",
                                   bars: parsed.bars, claudeUsageResetInventory: inventory,
                                   failureMessage: scenario == "claude-resets-failed" ? "Synthetic Claude usage unavailable" : nil,
                                   recoveryAction: .retryRefresh, fetchedAt: now)
    }
}
#endif
