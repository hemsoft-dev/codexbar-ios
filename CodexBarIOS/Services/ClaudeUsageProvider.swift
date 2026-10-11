import Foundation

public final class ClaudeUsageProvider: UsageProvider, ClaudeUsageResetConsuming {
    private static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let tokenRefreshEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private let secretStore: SecretStore
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let resetClient: ClaudeUsageResetClient
    private let planClient: ClaudePlanProfileClient
    private let snapshotCache = ClaudeUsageSnapshotCache()

    public let providerID = ProviderID.claude

    public init(
        secretStore: SecretStore = KeychainService(),
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.secretStore = secretStore
        self.session = session
        self.now = now
        self.resetClient = ClaudeUsageResetClient(session: session, secretStore: secretStore, now: now)
        self.planClient = ClaudePlanProfileClient(session: session)
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        guard
            let storedSecret = try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration)),
            let parsedCredentials = ClaudeCredentialsParser.parse(storedSecret),
            let accessToken = parsedCredentials.accessToken,
            !accessToken.isEmpty
        else {
            await snapshotCache.clear(accountID: configuration.id)
            await planClient.clear(accountID: configuration.id)
            return failureResult(
                "Not configured - sign in with Claude.",
                configuration: configuration,
                recoveryAction: .signIn
            )
        }

        await snapshotCache.prepare(accountID: configuration.id, credential: accessToken)
        let refreshOutcome = try await refreshedCredentialsIfNeeded(parsedCredentials, configuration: configuration)
        let credentials = refreshOutcome.credentials
        guard let token = credentials.accessToken, !token.isEmpty else {
            return failureResult(
                "Claude credential is missing an access token.",
                configuration: configuration,
                recoveryAction: .reauthenticate
            )
        }
        if let rotatedCredential = refreshOutcome.rotatedCredentialFrom {
            await snapshotCache.rotateCredential(
                accountID: configuration.id,
                from: rotatedCredential,
                to: token
            )
        } else {
            await snapshotCache.prepare(accountID: configuration.id, credential: token)
        }

        async let planResolution = planClient.resolve(accountID: configuration.id, accessToken: token, at: now(),
                                                      isCurrent: { (try? self.currentToken(for: configuration)) == token })
        let oauthOutcome = try await fetchOAuthUsage(
            configuration: configuration,
            credentials: credentials,
            accessToken: token
        )
        let resolution = await planResolution
        guard try currentToken(for: configuration) == token else {
            return failureResult("Claude account changed during refresh. Refresh again.", configuration: configuration)
        }
        let usageResult: ProviderUsageResult
        if let result = oauthOutcome.result {
            usageResult = result
        } else {
            usageResult = await staleOrFailureResult("Claude usage did not include rate-limit windows.", configuration: configuration)
        }
        var resolved = applyAccountMetadata(
            to: usageResult, configuration: configuration, resetInventory: usageResult.claudeUsageResetInventory,
            planResolution: resolution
        )
        if oauthOutcome.isSuccessfulSnapshot {
            let usageSecret: String?
            do {
                usageSecret = try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration))
            } catch {
                try Task.checkCancellation()
                usageSecret = nil
                resolved.subscriptionBillingProblem = SubscriptionBillingProblem(accountID: configuration.id, reason: .credentialsUnavailable)
            }
            if let usageSecret, ClaudeCredentialsParser.parse(usageSecret)?.accessToken == token {
                let billing = try await SubscriptionBillingClient(session: session).fetchClaudeObservation(
                    configuration: configuration, usageSecret: usageSecret, secretStore: secretStore, at: now()
                )
                resolved.subscriptionRenewal = billing.renewal
                resolved.subscriptionBillingProblem = billing.problem
            }
            try Task.checkCancellation()
            guard try currentToken(for: configuration) == token else {
                return failureResult("Claude account changed during refresh. Refresh again.", configuration: configuration)
            }
            return await snapshotCache.storePreservingBars(resolved, accountID: configuration.id, credential: token)
                ?? failureResult("Claude account changed during refresh. Refresh again.", configuration: configuration)
        }
        return resolved
    }

    private func currentToken(for configuration: ProviderAccountConfiguration) throws -> String? {
        guard let secret = try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration)) else { return nil }
        return ClaudeCredentialsParser.parse(secret)?.accessToken
    }

    public func consumeClaudeReset(
        for configuration: ProviderAccountConfiguration, grantID: String, confirmedGrant: ClaudeUsageResetGrant, credentialBinding: String
    ) async throws -> ClaudeUsageResetOutcome {
        guard configuration.providerID == .claude,
              let saved = try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration)),
              let parsed = ClaudeCredentialsParser.parse(saved)
        else { throw ClaudeUsageResetError.unavailable }
        let refreshed = try await refreshedCredentialsIfNeeded(parsed, configuration: configuration)
        guard let token = refreshed.credentials.accessToken, !token.isEmpty else { throw ClaudeUsageResetError.unavailable }
        guard let inventory = await snapshotCache.result(accountID: configuration.id)?.claudeUsageResetInventory,
              inventory.credentialBinding == credentialBinding,
              confirmedGrant.id == grantID, inventory.matchesConfirmation(grant: confirmedGrant, binding: credentialBinding, at: now())
        else { throw ClaudeUsageResetError.unavailable }
        return try await resetClient.consume(for: configuration, accessToken: token, grantID: grantID,
                                             credentialBinding: credentialBinding, confirmedGrant: confirmedGrant)
    }

    private func fetchOAuthUsage(
        configuration: ProviderAccountConfiguration,
        credentials: ClaudeCredentials,
        accessToken: String
    ) async throws -> OAuthUsageOutcome {
        let fetchedAt = now()
        if let retryAt = await snapshotCache.retryAt(accountID: configuration.id), retryAt > fetchedAt {
            return OAuthUsageOutcome(
                result: await staleOrFailureResult(
                    "Claude usage is rate-limited until \(Self.formatRetryDate(retryAt)).",
                    configuration: configuration
                )
            )
        }

        let (data, response) = try await session.data(for: makeOAuthUsageRequest(accessToken: accessToken))
        guard try currentToken(for: configuration) == accessToken else {
            return OAuthUsageOutcome(result: failureResult("Claude account changed during refresh. Refresh again.", configuration: configuration))
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            return OAuthUsageOutcome(
                result: failureResult("Claude usage returned an invalid response.", configuration: configuration)
            )
        }

        switch httpResponse.statusCode {
        case 200..<300:
            guard let parsed = ClaudeUsageParser.parse(
                data,
                subscriptionType: credentials.subscriptionType,
                rateLimitTier: credentials.rateLimitTier,
                fetchedAt: fetchedAt
            ) else {
                return OAuthUsageOutcome(result: nil)
            }
            let inventory = ClaudeUsageResetInventoryParser.parse(data)?.bound(toAccessToken: accessToken)
            let result = applyAccountMetadata(to: parsed, configuration: configuration, resetInventory: inventory)
            return OAuthUsageOutcome(
                result: result,
                isSuccessfulSnapshot: true
            )
        case 401:
            return OAuthUsageOutcome(
                result: failureResult(
                    "Claude credential was rejected. Sign in again.",
                    configuration: configuration,
                    recoveryAction: .reauthenticate
                )
            )
        case 403:
            return OAuthUsageOutcome(
                result: failureResult("Claude credential lacks permission to read subscription usage.", configuration: configuration)
            )
        case 404:
            return OAuthUsageOutcome(
                result: await staleOrFailureResult(
                    "Claude subscription usage is unavailable for this account.",
                    configuration: configuration
                )
            )
        case 429:
            let retryAt = retryDate(httpResponse, now: fetchedAt)
                ?? fetchedAt.addingTimeInterval(60)
            await snapshotCache.setRetryAt(retryAt, accountID: configuration.id, credential: accessToken)
            return OAuthUsageOutcome(
                result: await staleOrFailureResult(
                    "Claude usage is rate-limited until \(Self.formatRetryDate(retryAt)).",
                    configuration: configuration
                )
            )
        case 500..<600:
            return OAuthUsageOutcome(
                result: await staleOrFailureResult(
                    "Claude usage is temporarily unavailable (server error \(httpResponse.statusCode)).",
                    configuration: configuration
                )
            )
        default:
            return OAuthUsageOutcome(result: nil)
        }
    }

    private func refreshedCredentialsIfNeeded(
        _ credentials: ClaudeCredentials,
        configuration: ProviderAccountConfiguration
    ) async throws -> (credentials: ClaudeCredentials, rotatedCredentialFrom: String?) {
        guard credentials.expiresAt > 0 else {
            return (credentials, nil)
        }

        let expiresAt = Date(timeIntervalSince1970: TimeInterval(normalizeEpochToSeconds(credentials.expiresAt)))
        guard expiresAt <= now() else {
            return (credentials, nil)
        }

        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            return (credentials, nil)
        }

        let keychainAccount = ProviderConfigurationStore.keychainAccount(for: configuration)
        guard
            let storedSecret = try secretStore.readSecret(account: keychainAccount),
            let latestCredentials = ClaudeCredentialsParser.parse(storedSecret)
        else {
            return (credentials, nil)
        }
        if latestCredentials != credentials {
            return (latestCredentials, nil)
        }

        var request = URLRequest(url: Self.tokenRefreshEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ])

        let (data, response) = try await session.data(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            let refreshed = try? JSONDecoder().decode(TokenRefreshResponse.self, from: data),
            let accessToken = refreshed.accessToken,
            !accessToken.isEmpty
        else {
            return (credentials, nil)
        }

        let refreshedAt = now()
        let updated = ClaudeCredentials(
            subscriptionType: credentials.subscriptionType,
            rateLimitTier: credentials.rateLimitTier,
            expiresAt: refreshed.expiresAt ?? refreshed.expiresIn.map {
                refreshedAt.addingTimeInterval(TimeInterval($0)).claudeUsageUnixTimeMilliseconds
            } ?? 0,
            accessToken: accessToken,
            refreshToken: refreshed.refreshToken ?? credentials.refreshToken
        )

        guard
            let storedSecret = try secretStore.readSecret(account: keychainAccount),
            let latestCredentials = ClaudeCredentialsParser.parse(storedSecret)
        else {
            return (credentials, nil)
        }
        if latestCredentials != credentials {
            return (latestCredentials, nil)
        }

        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: updated),
            account: keychainAccount
        )
        return (updated, credentials.accessToken)
    }

    private func makeOAuthUsageRequest(accessToken: String) -> URLRequest {
        var components = URLComponents(url: Self.usageEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "cedar_ember", value: "1")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func failureResult(
        _ message: String,
        configuration: ProviderAccountConfiguration,
        recoveryAction: ProviderUsageRecoveryAction = .retryRefresh
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .claude,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            failureMessage: message,
            recoveryAction: recoveryAction,
            fetchedAt: Date()
        )
    }

    private func staleOrFailureResult(
        _ message: String,
        configuration: ProviderAccountConfiguration
    ) async -> ProviderUsageResult {
        guard let cached = await snapshotCache.result(accountID: configuration.id) else {
            return failureResult(message, configuration: configuration)
        }

        return ProviderUsageResult(
            accountID: cached.accountID,
            providerID: cached.providerID,
            title: configuration.displayName,
            plan: cached.plan,
            subtitle: "\(message) Showing last known data.",
            bars: cached.bars,
            barsFetchedAt: cached.barsFetchedAt,
            creditsRemaining: cached.creditsRemaining,
            creditsFetchedAt: cached.creditsFetchedAt,
            monetaryMetrics: cached.monetaryMetrics,
            usageMessages: cached.usageMessages,
            dashboardUsageMessages: cached.dashboardUsageMessages,
            cardInformationSections: cached.cardInformationSections,
            failureMessage: message,
            recoveryAction: .retryRefresh,
            hasSuccessfulRefreshHistory: cached.hasSuccessfulRefreshHistory,
            fetchedAt: cached.fetchedAt
        )
    }

    private func retryDate(_ response: HTTPURLResponse, now: Date) -> Date? {
        guard let retryAfter = response.value(forHTTPHeaderField: "Retry-After") else {
            return nil
        }
        if let seconds = TimeInterval(retryAfter), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        return Self.httpDateFormatter.date(from: retryAfter)
    }

    private static func formatRetryDate(_ date: Date) -> String {
        UserFacingDateTimeFormatter.current.dateAndTime(date)
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()

    private func applyAccountMetadata(
        to result: ProviderUsageResult,
        configuration: ProviderAccountConfiguration,
        resetInventory: ClaudeUsageResetInventory? = nil,
        planResolution: ClaudePlanResolution = .unavailable
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: result.providerID,
            title: configuration.displayName,
            plan: planResolution.plan(fallback: result.plan),
            subtitle: result.subtitle,
            bars: result.bars,
            barsFetchedAt: result.barsFetchedAt,
            creditsRemaining: result.creditsRemaining,
            creditsFetchedAt: result.creditsFetchedAt,
            monetaryMetrics: result.monetaryMetrics,
            usageMessages: result.usageMessages,
            dashboardUsageMessages: result.dashboardUsageMessages,
            cardInformationSections: result.cardInformationSections,
            claudeUsageResetInventory: resetInventory,
            failureMessage: result.failureMessage,
            recoveryAction: result.recoveryAction,
            hasSuccessfulRefreshHistory: result.hasSuccessfulRefreshHistory,
            fetchedAt: result.fetchedAt
        )
    }

    private func normalizeEpochToSeconds(_ value: Int64) -> Int64 {
        value >= 1_000_000_000_000 ? value / 1000 : value
    }
}

private actor ClaudeUsageSnapshotCache {
    private var results: [String: ProviderUsageResult] = [:]
    private var retryDates: [String: Date] = [:]
    private var credentials: [String: String] = [:]

    func clear(accountID: String) {
        credentials[accountID] = nil
        results[accountID] = nil
        retryDates[accountID] = nil
    }

    func prepare(accountID: String, credential: String) {
        guard credentials[accountID] != credential else {
            return
        }
        if credentials[accountID] != nil {
            results[accountID] = nil
            retryDates[accountID] = nil
        }
        credentials[accountID] = credential
    }

    func rotateCredential(accountID: String, from oldCredential: String, to newCredential: String) {
        guard credentials[accountID] == oldCredential else {
            prepare(accountID: accountID, credential: newCredential)
            return
        }
        credentials[accountID] = newCredential
        retryDates[accountID] = nil
    }

    func store(_ result: ProviderUsageResult, accountID: String) {
        results[accountID] = result
        retryDates[accountID] = nil
    }

    func storePreservingBars(_ result: ProviderUsageResult, accountID: String, credential: String) -> ProviderUsageResult? {
        guard credentials[accountID] == credential else { return nil }
        guard result.bars.isEmpty, let cached = results[accountID], !cached.bars.isEmpty else {
            store(result, accountID: accountID)
            return result
        }
        let preserved = ProviderUsageResult(
            accountID: result.accountID,
            providerID: result.providerID,
            title: result.title,
            plan: result.plan,
            subtitle: "\(result.subtitle) • Cached rate-limit windows",
            bars: cached.bars,
            barsFetchedAt: cached.barsFetchedAt,
            creditsRemaining: result.creditsRemaining,
            creditsFetchedAt: result.creditsFetchedAt,
            monetaryMetrics: result.monetaryMetrics,
            usageMessages: result.usageMessages,
            dashboardUsageMessages: result.dashboardUsageMessages,
            cardInformationSections: result.cardInformationSections,
            subscriptionRenewal: result.subscriptionRenewal,
            subscriptionBillingProblem: result.subscriptionBillingProblem,
            claudeUsageResetInventory: result.claudeUsageResetInventory,
            failureMessage: result.failureMessage,
            hasSuccessfulRefreshHistory: result.hasSuccessfulRefreshHistory
                || cached.hasSuccessfulRefreshHistory,
            fetchedAt: result.fetchedAt
        )
        results[accountID] = preserved
        retryDates[accountID] = nil
        return preserved
    }

    func result(accountID: String) -> ProviderUsageResult? {
        results[accountID]
    }

    func setRetryAt(_ date: Date?, accountID: String, credential: String) {
        guard credentials[accountID] == credential else { return }
        retryDates[accountID] = date
    }

    func retryAt(accountID: String) -> Date? {
        retryDates[accountID]
    }
}

private struct OAuthUsageOutcome {
    let result: ProviderUsageResult?
    let isSuccessfulSnapshot: Bool

    init(
        result: ProviderUsageResult?,
        isSuccessfulSnapshot: Bool = false
    ) {
        self.result = result
        self.isSuccessfulSnapshot = isSuccessfulSnapshot
    }
}

private struct TokenRefreshResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int64?
    let expiresAt: Int64?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
    }
}

private extension Date {
    var claudeUsageUnixTimeMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }
}
