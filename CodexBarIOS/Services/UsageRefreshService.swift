import Foundation

struct CodexRetainedResetAttempt: Equatable, Sendable {
    let creditID: String?
}

@MainActor
public final class UsageRefreshService: ObservableObject {
    @Published public private(set) var results: [ProviderUsageResult] = []
    @Published public private(set) var refreshingAccountIDs: Set<String> = []
    @Published public private(set) var refreshErrorsByAccountID: [String: String] = [:]
    @Published public private(set) var lastRefreshError: String?

    private let providers: [any UsageProvider]
    private var refreshCompletionWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var isBatchRefreshRunning = false
    private var pendingBatchConfigurations: [ProviderAccountConfiguration]?
    private var batchRefreshCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasCurrentConfigurationSnapshot = false
    private var currentConfigurationsByAccountID: [String: ProviderAccountConfiguration] = [:]
    private var retainedConfigurationsByAccountID: [String: ProviderAccountConfiguration] = [:]
    private var configurationSnapshot: [ProviderAccountConfiguration] = []
    // Standalone provider tests may omit a plan; the app binds its policy before any refresh.
    private var accountAccess: AccountPlanAccess?
    private var refreshGenerationsByAccountID: [String: UUID] = [:]
    private var codexResetAttempts: [String: CodexResetAttempt] = [:]
    private var claudeResetAccounts: Set<String> = []
    private var codexResetTasks: [String: Task<CodexBankedResetConsumptionOutcome, Error>] = [:]

    public init(
        providers: [any UsageProvider],
        initialResults: [ProviderUsageResult] = []
    ) {
        self.providers = providers
        self.results = initialResults
    }

    /// Keep cached xAI observations in step with a newly verified account label.
    func updateGrokResultTitle(_ title: String, accountID: String) {
        guard let index = results.firstIndex(where: { $0.accountID == accountID && $0.providerID.usesXAIConsumerAuth }),
              results[index].title != title else { return }
        results[index].title = title
    }

    public var isRefreshing: Bool {
        !refreshingAccountIDs.isEmpty
    }

    public var successfulRefreshResults: [ProviderUsageResult] {
        results.filter { result in
            guard !refreshingAccountIDs.contains(result.accountID),
                  accountAccess == nil || currentConfigurationsByAccountID[result.accountID].map(canRefresh) == true else {
                return false
            }
            return refreshErrorsByAccountID[result.accountID] == nil
                || result.preserveCachedBarsOnFailure
                || result.preserveCachedCreditsOnFailure
                || (result.providerID == .greptile && result.greptileReviewActivityUnavailableReason != nil && result.hasCurrentBars)
        }
    }

    public var incompleteRefreshAccountIDs: Set<String> {
        Set(refreshErrorsByAccountID.keys).union(refreshingAccountIDs)
    }

    var queuedBatchRefreshCount: Int {
        batchRefreshCompletionWaiters.count
    }

    func refreshWaiterCount(for accountID: String) -> Int {
        refreshCompletionWaiters[accountID]?.count ?? 0
    }

    var trackedRefreshGenerationCount: Int {
        refreshGenerationsByAccountID.count
    }

    func hasSameRefreshInputs(
        _ first: ProviderAccountConfiguration,
        _ second: ProviderAccountConfiguration
    ) -> Bool {
        RefreshInputs(configuration: first) == RefreshInputs(configuration: second)
    }

    /// Invalidate credential-dependent values before a replacement or disconnect can start another refresh.
    public func invalidateCredentials(accountID: String, preserveCachedResult: Bool = false) {
        if currentConfigurationsByAccountID[accountID] != nil || refreshingAccountIDs.contains(accountID) {
            refreshGenerationsByAccountID[accountID] = UUID()
        }
        if preserveCachedResult {
            markCacheAwaitingVerification(accountID: accountID)
            return
        }
        let remainingAccountIDs = Set(results.map(\.accountID))
            .union(refreshErrorsByAccountID.keys)
            .subtracting([accountID])
        pruneCachedState(to: remainingAccountIDs)
        if let lastRefreshError, !refreshErrorsByAccountID.values.contains(lastRefreshError) {
            self.lastRefreshError = refreshErrorsByAccountID.sorted { $0.key < $1.key }.first?.value
        }
    }

    private func markCacheAwaitingVerification(accountID: String) {
        let message = "Sign-in updated. Refresh to verify current usage."
        refreshErrorsByAccountID[accountID] = message
        lastRefreshError = message
        guard let cached = results.first(where: { $0.accountID == accountID }) else { return }
        replaceResult(ProviderUsageResult(
            accountID: cached.accountID, providerID: cached.providerID, title: cached.title,
            plan: cached.providerID == .gemini ? nil : cached.plan, verifiedGrokPlanName: cached.verifiedGrokPlanName,
            subtitle: "\(message) Showing last known data.",
            bars: cached.bars, barsFetchedAt: cached.barsFetchedAt,
            creditsRemaining: cached.creditsRemaining, creditsFetchedAt: cached.creditsFetchedAt,
            monetaryMetrics: cached.monetaryMetrics, unavailableUsageMetrics: cached.unavailableUsageMetrics,
            usageMessages: cached.usageMessages, dashboardUsageMessages: cached.dashboardUsageMessages,
            cardInformationSections: cached.cardInformationSections,
            greptileAllowanceRenewal: cached.greptileAllowanceRenewal.map { renewal in
                var stale = renewal
                stale.isStale = true
                return stale
            },
            codexBankedRateLimitResets: cached.codexBankedRateLimitResets,
            failureMessage: message, recoveryAction: .retryRefresh,
            cacheIdentity: cached.cacheIdentity, cacheScope: cached.cacheScope,
            allowsUnscopedCacheReuse: cached.allowsUnscopedCacheReuse,
            hasSuccessfulRefreshHistory: cached.hasSuccessfulRefreshHistory, fetchedAt: cached.fetchedAt
        ))
    }

    public func refresh(configurations: [ProviderAccountConfiguration]) async {
        updateCurrentConfigurations(configurations)
        if isBatchRefreshRunning {
            pendingBatchConfigurations = configurations
            await withCheckedContinuation { continuation in
                batchRefreshCompletionWaiters.append(continuation)
            }
            return
        }

        isBatchRefreshRunning = true
        var nextConfigurations = configurations
        while true {
            await performRefresh(configurations: nextConfigurations)
            guard let pendingConfigurations = pendingBatchConfigurations else {
                break
            }
            pendingBatchConfigurations = nil
            nextConfigurations = pendingConfigurations
        }

        isBatchRefreshRunning = false
        let waiters = batchRefreshCompletionWaiters
        batchRefreshCompletionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func performRefresh(configurations: [ProviderAccountConfiguration]) async {
        let enabledConfigurations = configurations.filter(canRefresh)
        while let refreshingAccountID = enabledConfigurations.lazy
            .map(\.id)
            .first(where: refreshingAccountIDs.contains) {
            await waitForRefreshToFinish(accountID: refreshingAccountID)
        }

        pruneCachedState(to: Set(retainedConfigurationsByAccountID.keys))

        var requests: [(ProviderAccountConfiguration, any UsageProvider)] = []
        for configuration in enabledConfigurations {
            guard isCurrent(configuration) else {
                continue
            }
            guard let provider = providers.first(where: { $0.providerID == configuration.providerID }) else {
                let message = "This provider is unavailable."
                refreshErrorsByAccountID[configuration.id] = message
                continue
            }
            requests.append((configuration, provider))
        }

        let requestedAccountIDs = Set(requests.map { $0.0.id })
        refreshingAccountIDs.formUnion(requestedAccountIDs)

        await withTaskGroup(of: AccountRefreshOutcome.self) { group in
            for (configuration, provider) in requests {
                guard let generation = refreshGenerationsByAccountID[configuration.id] else {
                    finishRefresh(accountID: configuration.id)
                    continue
                }
                group.addTask {
                    do {
                        let result = await self.preservingGreptileRenewal(try await provider.fetchUsage(for: configuration))
                        if let message = result.failureMessage {
                            return .failure(
                                configuration: configuration,
                                generation: generation,
                                message: message,
                                result: result
                            )
                        }
                        return .success(
                            configuration: configuration,
                            generation: generation,
                            result: result
                        )
                    } catch {
                        if Self.isCancellation(error) { return .canceled(accountID: configuration.id) }
                        let result = Self.failureResult(
                            for: configuration,
                            message: error.localizedDescription
                        )
                        return .failure(
                            configuration: configuration,
                            generation: generation,
                            message: error.localizedDescription,
                            result: result
                        )
                    }
                }
            }

            for await outcome in group {
                switch outcome {
                case .canceled(let accountID):
                    finishRefresh(accountID: accountID)
                case .success(let configuration, let generation, let result):
                    let accountID = configuration.id
                    guard isCurrent(configuration, generation: generation) else {
                        finishRefresh(accountID: accountID)
                        continue
                    }
                    replaceResult(preservingVerifiedGrokPlan(result))
                    refreshErrorsByAccountID.removeValue(forKey: accountID)
                    finishRefresh(accountID: accountID)
                case .failure(let configuration, let generation, let message, let result):
                    let accountID = configuration.id
                    guard isCurrent(configuration, generation: generation) else {
                        finishRefresh(accountID: accountID)
                        continue
                    }
                    preserveFailureResult(result, configuration: configuration)
                    refreshErrorsByAccountID[accountID] = message
                    finishRefresh(accountID: accountID)
                }
            }
        }

        lastRefreshError = enabledConfigurations.filter(canRefresh).lazy
            .compactMap { self.refreshErrorsByAccountID[$0.id] }
            .first
    }

    @discardableResult
    public func refresh(configuration: ProviderAccountConfiguration) async -> ProviderUsageResult? {
        guard
            canRefresh(configuration),
            let provider = providers.first(where: { $0.providerID == configuration.providerID })
        else {
            return nil
        }
        let generation: UUID
        if hasCurrentConfigurationSnapshot {
            guard
                isCurrent(configuration),
                let currentGeneration = refreshGenerationsByAccountID[configuration.id]
            else {
                return nil
            }
            generation = currentGeneration
        } else {
            generation = registerCurrentConfiguration(configuration)
        }
        await waitForRefreshToFinish(accountID: configuration.id)
        guard isCurrent(configuration, generation: generation) else {
            return nil
        }

        refreshingAccountIDs.insert(configuration.id)
        defer {
            finishRefresh(accountID: configuration.id)
        }

        do {
            let result = preservingVerifiedGrokPlan(preservingGreptileRenewal(try await provider.fetchUsage(for: configuration)))
            guard isCurrent(configuration, generation: generation) else {
                return nil
            }
            if let message = result.failureMessage {
                preserveFailureResult(result, configuration: configuration)
                refreshErrorsByAccountID[configuration.id] = message
                lastRefreshError = message
                return result
            }
            replaceResult(result)
            refreshErrorsByAccountID.removeValue(forKey: configuration.id)
            lastRefreshError = nil
            return result
        } catch {
            guard !Self.isCancellation(error), isCurrent(configuration, generation: generation) else {
                return nil
            }
            let message = error.localizedDescription
            let result = Self.failureResult(for: configuration, message: message)
            preserveFailureResult(result, configuration: configuration)
            refreshErrorsByAccountID[configuration.id] = message
            lastRefreshError = message
            return result
        }
    }

    func resultAfterCurrentRefresh(
        configuration: ProviderAccountConfiguration
    ) async -> ProviderUsageResult? {
        guard
            isCurrent(configuration),
            let generation = refreshGenerationsByAccountID[configuration.id]
        else {
            return nil
        }
        await waitForRefreshToFinish(accountID: configuration.id)
        guard isCurrent(configuration, generation: generation) else {
            return nil
        }
        return results.first { $0.accountID == configuration.id }
    }

    public func refresh() async {
        await refresh(configurations: ProviderID.allCases.map(ProviderAccountConfiguration.defaultConfiguration))
    }

    public func consumeClaudeReset(
        for configuration: ProviderAccountConfiguration,
        grantID: String,
        confirmedGrant: ClaudeUsageResetGrant,
        credentialBinding: String
    ) async throws -> ClaudeUsageResetOutcome {
        guard configuration.providerID == .claude, configuration.isEnabled,
              !hasCurrentConfigurationSnapshot || isCurrent(configuration),
              let provider = providers.first(where: { $0.providerID == .claude }) as? any ClaudeUsageResetConsuming,
              let result = results.first(where: { $0.accountID == configuration.id }),
              result.failureMessage == nil, refreshErrorsByAccountID[configuration.id] == nil,
              !refreshingAccountIDs.contains(configuration.id),
              let inventory = result.claudeUsageResetInventory,
              inventory.credentialBinding == credentialBinding,
              confirmedGrant.id == grantID, inventory.matchesConfirmation(grant: confirmedGrant, binding: credentialBinding, at: Date())
        else { throw ClaudeUsageResetError.unavailable }
        guard claudeResetAccounts.insert(configuration.id).inserted else { throw ClaudeUsageResetError.inProgress }
        defer { claudeResetAccounts.remove(configuration.id) }
        let generation = registerCurrentConfiguration(configuration)
        let outcome = try await provider.consumeClaudeReset(
            for: configuration, grantID: grantID, confirmedGrant: confirmedGrant, credentialBinding: credentialBinding
        )
        guard isCurrent(configuration, generation: generation) else { throw ClaudeUsageResetError.credentialChanged }
        return outcome
    }

    public func consumeCodexBankedReset(
        for configuration: ProviderAccountConfiguration,
        creditID: String?
    ) async throws -> CodexBankedResetConsumptionOutcome {
        guard
            configuration.providerID == .codex,
            let provider = providers.first(where: { $0.providerID == .codex }) as? any CodexBankedResetConsuming
        else {
            throw CodexBankedResetConsumptionError.unsupported
        }

        guard canRefresh(configuration), !hasCurrentConfigurationSnapshot || isCurrent(configuration) else {
            throw CodexBankedResetConsumptionError.notConfigured
        }
        let generation = registerCurrentConfiguration(configuration)
        if let activeTask = codexResetTasks[configuration.id] {
            let outcome = try await activeTask.value
            guard isCurrent(configuration, generation: generation) else { throw CodexBankedResetConsumptionError.notConfigured }
            return outcome
        }

        let attempt = codexResetAttempts[configuration.id] ?? CodexResetAttempt(
            idempotencyKey: UUID().uuidString,
            creditID: creditID
        )
        codexResetAttempts[configuration.id] = attempt
        let task = Task {
            try await provider.consumeBankedReset(
                for: configuration,
                creditID: attempt.creditID,
                idempotencyKey: attempt.idempotencyKey
            )
        }
        codexResetTasks[configuration.id] = task

        do {
            let outcome = try await task.value
            codexResetTasks[configuration.id] = nil
            codexResetAttempts[configuration.id] = nil
            guard isCurrent(configuration, generation: generation) else { throw CodexBankedResetConsumptionError.notConfigured }
            return outcome
        } catch {
            codexResetTasks[configuration.id] = nil
            if !shouldRetainCodexResetAttempt(after: error) {
                codexResetAttempts[configuration.id] = nil
            }
            throw error
        }
    }

    private func shouldRetainCodexResetAttempt(after error: Error) -> Bool {
        if let resetError = error as? CodexBankedResetConsumptionError {
            switch resetError {
            case .invalidResponse:
                return true
            case .httpStatus(let status):
                return status == 408 || status == 425 || status == 429 || (500..<600).contains(status)
            case .notConfigured, .credentialUnavailable, .unsupported, .invalidRequest:
                return false
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .badURL, .unsupportedURL:
                return false
            default:
                return true
            }
        }

        return false
    }

    func hasRetainedCodexResetAttempt(for accountID: String) -> Bool {
        retainedCodexResetAttempt(for: accountID) != nil
    }

    func retainedCodexResetAttempt(for accountID: String) -> CodexRetainedResetAttempt? {
        guard let attempt = codexResetAttempts[accountID] else {
            return nil
        }
        return CodexRetainedResetAttempt(creditID: attempt.creditID)
    }

    private nonisolated static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled
    }

    private func preservingVerifiedGrokPlan(_ incoming: ProviderUsageResult) -> ProviderUsageResult {
        guard incoming.providerID.usesXAIConsumerAuth, incoming.failureMessage == nil, incoming.grokPlanLookupFailed,
              incoming.verifiedGrokPlanName == nil,
              let identity = incoming.cacheIdentity,
              let cached = results.first(where: { $0.accountID == incoming.accountID && $0.cacheIdentity == identity })
        else { return incoming }
        return GrokUsageProvider.retainingVerifiedPlan(cached.verifiedGrokPlanName, for: incoming)
    }

    private func preservingGreptileRenewal(_ incoming: ProviderUsageResult) -> ProviderUsageResult {
        guard incoming.providerID == .greptile, let failed = incoming.greptileAllowanceRenewal,
              failed.isApplicable == nil, !failed.requiresNewAccount,
              let cached = results.first(where: { $0.accountID == incoming.accountID && Self.canReuseCachedResult($0, for: incoming) }),
              let previous = cached.greptileAllowanceRenewal else { return incoming }
        let renewal = GreptileAllowanceRenewal(
            renewsAt: failed.lookupFailed ? previous.renewsAt : nil, observedAt: previous.observedAt,
            isStale: true, unavailableReason: failed.unavailableReason,
            requiresAuthentication: failed.requiresAuthentication, lookupFailed: failed.lookupFailed,
            isApplicable: previous.isApplicable
        )
        var result = incoming
        result.greptileAllowanceRenewal = renewal
        return result
    }

    private func replaceResult(_ result: ProviderUsageResult) {
        var nextResults = results.filter { $0.accountID != result.accountID }
        nextResults.append(result)
        results = nextResults
    }

    private func preserveFailureResult(
        _ failureResult: ProviderUsageResult,
        configuration: ProviderAccountConfiguration
    ) {
        let accountID = configuration.id
        let cachedResult = results.first {
            $0.accountID == accountID
                && Self.canReuseCachedResult($0, for: failureResult)
        }
        let failureHasUsageData = failureResult.creditsRemaining != nil
            || !failureResult.bars.isEmpty
            || !failureResult.monetaryMetrics.isEmpty
            || failureResult.codexBankedRateLimitResets != nil
            || failureResult.preserveCachedBarsOnFailure
            || failureResult.preserveCachedCreditsOnFailure
        let dataResult: ProviderUsageResult
        if failureHasUsageData {
            dataResult = failureResult
        } else if let cachedResult {
            dataResult = cachedResult
        } else {
            replaceResult(failureResult)
            return
        }

        let freshGreptileCredits = failureResult.greptileReviewActivityUnavailableReason != nil
            ? failureResult.bars.filter { $0.stableKey == GreptileUsageIdentity.creditAllowanceStableKey }
            : []
        let cachedGreptileReviews = freshGreptileCredits.isEmpty ? [] : (cachedResult?.bars ?? []).filter {
            $0.stableKey == GreptileUsageIdentity.completedReviewsStableKey || $0.stableKey == GreptileUsageIdentity.reviewQuotaStableKey
        }
        var unavailableMetrics = dataResult.unavailableUsageMetrics.merging(failureResult.unavailableUsageMetrics) { _, latest in latest }
        for (index, bar) in cachedGreptileReviews.enumerated() {
            unavailableMetrics[bar.metricIdentifier(providerID: .greptile, index: index)] =
                "Review activity unavailable. Last known: \(bar.used.formatted())."
        }
        let preserveGreptileHistory = failureResult.providerID == .greptile && failureResult.bars.isEmpty
        let barsResult = failureResult.preserveCachedBarsOnFailure || preserveGreptileHistory
            ? cachedResult ?? failureResult
            : dataResult
        let creditsResult = failureResult.preserveCachedCreditsOnFailure
            ? cachedResult ?? failureResult
            : dataResult
        let subtitle = failureHasUsageData
            || failureResult.subtitle.localizedCaseInsensitiveContains("last known data")
            ? failureResult.subtitle
            : "\(failureResult.subtitle) Showing last known data."
        let title = failureResult.providerID == .openCodeZen
            ? configuration.openCodeDisplayName(
                hasGoUsage: !barsResult.bars.isEmpty,
                hasZenBalance: creditsResult.creditsRemaining != nil
            )
            : failureResult.title
        var renewal = failureResult.greptileAllowanceRenewal ?? cachedResult?.greptileAllowanceRenewal
        if failureResult.greptileAllowanceRenewal == nil { renewal?.isStale = true }
        replaceResult(ProviderUsageResult(
            accountID: accountID,
            providerID: failureResult.providerID,
            title: title,
            plan: failureResult.providerID == .gemini ? failureResult.plan : (failureResult.plan ?? cachedResult?.plan),
            verifiedGrokPlanName: failureResult.verifiedGrokPlanName ?? cachedResult?.verifiedGrokPlanName,
            subtitle: subtitle,
            bars: freshGreptileCredits.isEmpty ? barsResult.bars : freshGreptileCredits + cachedGreptileReviews,
            barsFetchedAt: freshGreptileCredits.isEmpty ? barsResult.barsFetchedAt : failureResult.fetchedAt,
            creditsRemaining: creditsResult.creditsRemaining,
            creditsFetchedAt: creditsResult.creditsFetchedAt,
            monetaryMetrics: dataResult.monetaryMetrics,
            unavailableUsageMetrics: unavailableMetrics,
            usageMessages: dataResult.usageMessages,
            dashboardUsageMessages: dataResult.dashboardUsageMessages,
            cardInformationSections: dataResult.cardInformationSections,
            subscriptionRenewal: failureResult.providerID == .openCodeZen ? failureResult.boundSubscriptionRenewal : nil,
            greptileAllowanceRenewal: renewal,
            greptileReviewActivityUnavailableReason: failureResult.greptileReviewActivityUnavailableReason,
            codexBankedRateLimitResets: dataResult.codexBankedRateLimitResets,
            failureMessage: failureResult.failureMessage,
            recoveryAction: failureResult.recoveryAction,
            preserveCachedBarsOnFailure: failureResult.preserveCachedBarsOnFailure,
            preserveCachedCreditsOnFailure: failureResult.preserveCachedCreditsOnFailure,
            cacheIdentity: failureResult.cacheIdentity
                ?? (failureResult.providerID.usesXAIConsumerAuth ? cachedResult?.cacheIdentity : nil),
            cacheScope: failureResult.cacheScope ?? (failureResult.providerID.usesXAIConsumerAuth ? cachedResult?.cacheScope : nil),
            allowsUnscopedCacheReuse: failureResult.allowsUnscopedCacheReuse,
            hasSuccessfulRefreshHistory: failureResult.hasSuccessfulRefreshHistory
                || cachedResult?.hasSuccessfulRefreshHistory == true,
            fetchedAt: dataResult.fetchedAt
        ))
    }

    private nonisolated static func canReuseCachedResult(
        _ cachedResult: ProviderUsageResult,
        for failureResult: ProviderUsageResult
    ) -> Bool {
        if failureResult.providerID == .greptile {
            return cachedResult.cacheIdentity == failureResult.cacheIdentity
        }
        if [.grok, .xSubscription, .codex].contains(failureResult.providerID)
            && (failureResult.recoveryAction == .reauthenticate || !failureResult.allowsUnscopedCacheReuse) {
            return false
        }
        if let failureIdentity = failureResult.cacheIdentity {
            return cachedResult.cacheIdentity == failureIdentity
        }
        if failureResult.providerID == .codex { return cachedResult.cacheIdentity == nil }
        guard failureResult.providerID == .openCodeZen else {
            return true
        }
        guard
            failureResult.allowsUnscopedCacheReuse,
            let failureScope = failureResult.cacheScope
        else {
            return false
        }
        return cachedResult.cacheScope == failureScope
    }

    private nonisolated static func failureResult(
        for configuration: ProviderAccountConfiguration,
        message: String
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: configuration.providerID,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            failureMessage: message,
            cacheScope: configuration.providerID == .openCodeZen
                ? OpenCodeZenUsageProvider.normalizedWorkspaceId(
                    from: configuration.openCodeWorkspaceId
                )
                : nil,
            allowsUnscopedCacheReuse: true,
            fetchedAt: Date()
        )
    }

    private func waitForRefreshToFinish(accountID: String) async {
        while refreshingAccountIDs.contains(accountID) {
            await withCheckedContinuation { continuation in
                refreshCompletionWaiters[accountID, default: []].append(continuation)
            }
        }
    }

    /// The same predicate protects batch work, individual requests and reconciliation.
    func canRefresh(_ configuration: ProviderAccountConfiguration) -> Bool {
        configuration.isEnabled && configuration.providerID != .antigravity
            && (accountAccess?.permitsRefresh(configuration) ?? true)
    }

    func updateAccountAccess(_ access: AccountPlanAccess) {
        guard accountAccess != access else { return }
        accountAccess = access
        updateCurrentConfigurations(configurationSnapshot)
    }

    func updateCurrentConfigurations(_ configurations: [ProviderAccountConfiguration]) {
        let hadSnapshot = hasCurrentConfigurationSnapshot
        hasCurrentConfigurationSnapshot = true
        configurationSnapshot = configurations
        let retained = Dictionary(uniqueKeysWithValues: configurations.filter {
            $0.isEnabled && $0.providerID != .antigravity
        }.map { ($0.id, $0) })
        let eligible = Dictionary(uniqueKeysWithValues: configurations.filter(canRefresh).map { ($0.id, $0) })
        let accountIDs = Set(currentConfigurationsByAccountID.keys).union(eligible.keys)
        for accountID in accountIDs {
            let previous = currentConfigurationsByAccountID[accountID]
            let next = eligible[accountID]
            guard refreshInputsChanged(from: previous, to: next) else { continue }
            if next == nil && !refreshingAccountIDs.contains(accountID) {
                refreshGenerationsByAccountID.removeValue(forKey: accountID)
            } else {
                refreshGenerationsByAccountID[accountID] = UUID()
            }
        }
        // A plan pause invalidates requests but retains observations. Credential/configuration
        // changes and disabling still discard results through their existing invalidation path.
        let changedInputs = Set(retained.keys.filter { accountID in
            guard let previous = retainedConfigurationsByAccountID[accountID] else { return false }
            return refreshInputsChanged(from: previous, to: retained[accountID])
        })
        currentConfigurationsByAccountID = eligible
        retainedConfigurationsByAccountID = retained
        pruneCachedState(to: Set(retained.keys).subtracting(hadSnapshot ? changedInputs : []))
        let nextError = configurations.filter(canRefresh).lazy.compactMap { self.refreshErrorsByAccountID[$0.id] }.first
        if nextError != lastRefreshError { lastRefreshError = nextError }
    }

    private func pruneCachedState(to enabledAccountIDs: Set<String>) {
        let nextResults = results.filter { enabledAccountIDs.contains($0.accountID) }
        if nextResults != results {
            results = nextResults
        }
        let nextErrors = refreshErrorsByAccountID.filter { enabledAccountIDs.contains($0.key) }
        if nextErrors != refreshErrorsByAccountID {
            refreshErrorsByAccountID = nextErrors
        }
    }

    private func refreshInputsChanged(
        from currentConfiguration: ProviderAccountConfiguration?,
        to nextConfiguration: ProviderAccountConfiguration?
    ) -> Bool {
        guard let currentConfiguration, let nextConfiguration else {
            return true
        }
        return !hasSameRefreshInputs(currentConfiguration, nextConfiguration)
    }

    private func registerCurrentConfiguration(
        _ configuration: ProviderAccountConfiguration
    ) -> UUID {
        if currentConfigurationsByAccountID[configuration.id] != configuration {
            currentConfigurationsByAccountID[configuration.id] = configuration
            refreshGenerationsByAccountID[configuration.id] = UUID()
        }
        let generation = refreshGenerationsByAccountID[configuration.id] ?? UUID()
        refreshGenerationsByAccountID[configuration.id] = generation
        return generation
    }

    private func isCurrent(_ configuration: ProviderAccountConfiguration) -> Bool {
        canRefresh(configuration) && currentConfigurationsByAccountID[configuration.id] == configuration
    }

    private func isCurrent(
        _ configuration: ProviderAccountConfiguration,
        generation: UUID
    ) -> Bool {
        guard canRefresh(configuration), let currentConfiguration = currentConfigurationsByAccountID[configuration.id] else {
            return false
        }
        return !refreshInputsChanged(from: configuration, to: currentConfiguration)
            && refreshGenerationsByAccountID[configuration.id] == generation
    }

    private func finishRefresh(accountID: String) {
        refreshingAccountIDs.remove(accountID)
        if currentConfigurationsByAccountID[accountID] == nil {
            refreshGenerationsByAccountID.removeValue(forKey: accountID)
        }
        let waiters = refreshCompletionWaiters.removeValue(forKey: accountID) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private struct RefreshInputs: Equatable {
    let providerID: ProviderID
    let authMethod: ProviderAuthMethod
    let oauthClientID: String?
    let copilotAccountScope: CopilotAccountScope
    let githubOrganization: String
    let githubEnterprise: String
    let copilotTotalAllotment: Double?
    let githubBillingAccountScope: GitHubBillingAccountScope
    let githubBillingOwner: String
    let openCodeWorkspaceId: String

    init(configuration: ProviderAccountConfiguration) {
        self.providerID = configuration.providerID
        self.authMethod = configuration.authMethod
        self.oauthClientID = configuration.oauthClientID
        self.copilotAccountScope = configuration.copilotAccountScope
        self.githubOrganization = configuration.githubOrganization
        self.githubEnterprise = configuration.githubEnterprise
        self.copilotTotalAllotment = configuration.copilotTotalAllotment
        self.githubBillingAccountScope = configuration.githubBillingAccountScope
        self.githubBillingOwner = configuration.githubBillingOwner
        self.openCodeWorkspaceId = configuration.openCodeWorkspaceId
    }
}

private struct CodexResetAttempt {
    let idempotencyKey: String
    let creditID: String?
}

private enum AccountRefreshOutcome: Sendable {
    case canceled(accountID: String)
    case success(
        configuration: ProviderAccountConfiguration,
        generation: UUID,
        result: ProviderUsageResult
    )
    case failure(
        configuration: ProviderAccountConfiguration,
        generation: UUID,
        message: String,
        result: ProviderUsageResult
    )
}

public extension UsageRefreshService {
    static func demo() -> UsageRefreshService {
        UsageRefreshService(providers: DemoUsageProvider.samples)
    }

    static func live() -> UsageRefreshService {
        UsageRefreshService(
            providers: [
                CodexUsageProvider(),
                CopilotUsageProvider(),
                GitHubBillingUsageProvider(),
                ClaudeUsageProvider(),
                GrokUsageProvider(),
                GrokUsageProvider(providerID: .xSubscription),
                OpenRouterUsageProvider(),
                OpenCodeZenUsageProvider(),
                MoonshotUsageProvider(),
                CursorUsageProvider(),
                GreptileUsageProvider(),
                GeminiUsageProvider(),
            ]
        )
    }
}
