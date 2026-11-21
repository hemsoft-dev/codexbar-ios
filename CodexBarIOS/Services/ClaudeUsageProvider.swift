import Foundation

public final class ClaudeUsageProvider: UsageProvider, ClaudeUsageResetConsuming {
    private static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let tokenRefreshEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!

    private let secretStore: SecretStore
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let resetClient: ClaudeUsageResetClient
    private let planClient: ClaudePlanProfileClient
    private let billingClient: SubscriptionBillingClient
    private let snapshotCache = ClaudeUsageSnapshotCache()

    public let providerID = ProviderID.claude

    public convenience init(
        secretStore: SecretStore = KeychainService(),
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(secretStore: secretStore, session: session, now: now, billingClient: SubscriptionBillingClient(session: session))
    }

    init(secretStore: SecretStore, session: URLSession, now: @escaping @Sendable () -> Date = { Date() },
         billingClient: SubscriptionBillingClient) {
        self.secretStore = secretStore
        self.session = session
        self.now = now
        self.resetClient = ClaudeUsageResetClient(session: session, secretStore: secretStore, now: now)
        self.planClient = ClaudePlanProfileClient(session: session)
        self.billingClient = billingClient
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
            await snapshotCache.markRenewed(accountID: configuration.id, credential: token)
        } else {
            await snapshotCache.prepare(accountID: configuration.id, credential: token)
        }

        async let planResolution = planClient.resolve(accountID: configuration.id, accessToken: token, at: now(),
                                                      isCurrent: { (try? self.currentToken(for: configuration)) == token })
        let oauthOutcome = try await fetchOAuthUsage(
            configuration: configuration,
            credentials: credentials,
            accessToken: token,
            renewal: refreshOutcome.renewal
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
                let billing = try await billingClient.fetchClaudeObservation(
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
        accessToken: String,
        renewal: ClaudeRenewalOutcome
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
            await snapshotCache.clearRenewal(accountID: configuration.id)
            let inventory = ClaudeUsageResetInventoryParser.parse(data)?.bound(toAccessToken: accessToken)
            let result = applyAccountMetadata(to: parsed, configuration: configuration, resetInventory: inventory)
            return OAuthUsageOutcome(
                result: result,
                isSuccessfulSnapshot: true
            )
        case 401, 403:
            let renewedToken = await snapshotCache.isRenewed(accountID: configuration.id, credential: accessToken)
            return OAuthUsageOutcome(result: await refusedResult(
                status: httpResponse.statusCode, body: data, renewal: renewedToken ? .renewed : renewal, configuration: configuration
            ))
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
            return OAuthUsageOutcome(result: await staleOrFailureResult(
                ClaudeUsageFailureCopy.requestDeclined(status: httpResponse.statusCode), configuration: configuration
            ))
        }
    }

    /// A 401 or 403 on the usage read. Sign-in is offered only where a new sign-in can help: a
    /// missing permission, a refresh token Claude no longer accepts, or a plainly rejected saved
    /// token. A token Claude itself renewed and has refused ever since is a refusal of the request, so
    /// signing in again would only replace the saved sign-in for nothing. That holds for later
    /// refreshes too, until the token reads usage once or the app restarts.
    private func refusedResult(
        status: Int, body: Data, renewal: ClaudeRenewalOutcome, configuration: ProviderAccountConfiguration
    ) async -> ProviderUsageResult {
        if ClaudeUsageFailureCopy.isScopeRequirement(body) {
            return failureResult(ClaudeUsageFailureCopy.permissionMissing, configuration: configuration, recoveryAction: .reauthenticate)
        }
        let declined = ClaudeUsageFailureCopy.requestDeclined(status: status)
        guard status == 401 else { return await staleOrFailureResult(declined, configuration: configuration) }
        switch renewal {
        case .signInExpired(let detail):
            return failureResult(ClaudeUsageFailureCopy.renewalDeclined(detail), configuration: configuration, recoveryAction: .reauthenticate)
        case .unavailable(let detail):
            return await staleOrFailureResult(ClaudeUsageFailureCopy.renewalUnavailable(detail), configuration: configuration)
        case .renewed:
            return await staleOrFailureResult(declined, configuration: configuration)
        case .notNeeded:
            return failureResult("Claude credential was rejected. Sign in again.", configuration: configuration, recoveryAction: .reauthenticate)
        }
    }

    private func refreshedCredentialsIfNeeded(
        _ credentials: ClaudeCredentials,
        configuration: ProviderAccountConfiguration
    ) async throws -> (credentials: ClaudeCredentials, rotatedCredentialFrom: String?, renewal: ClaudeRenewalOutcome) {
        guard credentials.expiresAt > 0 else {
            return (credentials, nil, .notNeeded)
        }

        let expiresAt = Date(timeIntervalSince1970: TimeInterval(normalizeEpochToSeconds(credentials.expiresAt)))
        guard expiresAt <= now() else {
            return (credentials, nil, .notNeeded)
        }

        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            return (credentials, nil, .notNeeded)
        }

        let keychainAccount = ProviderConfigurationStore.keychainAccount(for: configuration)
        guard
            let storedSecret = try secretStore.readSecret(account: keychainAccount),
            let latestCredentials = ClaudeCredentialsParser.parse(storedSecret)
        else {
            return (credentials, nil, .notNeeded)
        }
        if latestCredentials != credentials {
            return (latestCredentials, nil, .notNeeded)
        }

        var request = URLRequest(url: Self.tokenRefreshEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        ClaudeClientIdentity.apply(to: &request)
        request.httpBody = try JSONEncoder().encode([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": ClaudeClientIdentity.oauthClientID,
        ])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return (credentials, nil, .unavailable("no HTTP response"))
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            return (credentials, nil, ClaudeRenewalOutcome.refused(statusCode: httpResponse.statusCode, body: data))
        }
        guard
            let refreshed = try? JSONDecoder().decode(TokenRefreshResponse.self, from: data),
            let accessToken = refreshed.accessToken,
            !accessToken.isEmpty
        else {
            return (credentials, nil, .unavailable("HTTP \(httpResponse.statusCode) without a usable token"))
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
            return (credentials, nil, .notNeeded)
        }
        if latestCredentials != credentials {
            return (latestCredentials, nil, .notNeeded)
        }

        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: updated),
            account: keychainAccount
        )
        return (updated, credentials.accessToken, .renewed)
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
        ClaudeClientIdentity.apply(to: &request)
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
        // Always Retry: these states leave the saved sign-in as it is.
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
    /// The access token a renewal produced, until it reads usage once. In memory only.
    private var renewedCredentials: [String: String] = [:]

    func clear(accountID: String) {
        credentials[accountID] = nil
        results[accountID] = nil
        retryDates[accountID] = nil
        renewedCredentials[accountID] = nil
    }

    func markRenewed(accountID: String, credential: String) {
        renewedCredentials[accountID] = credential
    }

    func isRenewed(accountID: String, credential: String) -> Bool {
        renewedCredentials[accountID] == credential
    }

    func clearRenewal(accountID: String) {
        renewedCredentials[accountID] = nil
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

/// What happened when this fetch tried to renew an expired access token.
enum ClaudeRenewalOutcome: Equatable {
    case notNeeded
    case renewed
    /// Claude no longer accepts the refresh token. Only a new sign-in can help.
    case signInExpired(String)
    /// Any other refusal or failure. The saved sign-in is unchanged and may still be good.
    case unavailable(String)

    static func refused(statusCode: Int, body: Data) -> Self {
        let detail = TokenEndpointErrorFormatter.message(statusCode: statusCode, body: body)
        return namesInvalidGrant(body) ? .signInExpired(detail) : .unavailable(detail)
    }

    /// `invalid_grant` as the OAuth error code, flat or inside an error object.
    private static func namesInvalidGrant(_ body: Data) -> Bool {
        if TokenEndpointErrorFormatter.oauthErrorCode(from: body) == "invalid_grant" { return true }
        guard body.count <= 65_536, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = object["error"] as? [String: Any]
        else { return false }
        return ["type", "code"].contains { error[$0] as? String == "invalid_grant" }
    }
}

/// Card text for the ways Claude can refuse CodexBar's truthful identity or a sign-in's permissions.
/// "Declined" states offer Retry and say the sign-in was not changed, because a new sign-in cannot
/// fix a refusal of the app itself.
enum ClaudeUsageFailureCopy {
    static let permissionMissing = "Claude says this sign-in does not include permission to read usage. Sign in again to grant it."

    static func requestDeclined(status: Int) -> String {
        "Claude declined CodexBar's usage request (HTTP \(status)). Your sign-in was not changed."
    }

    static func renewalDeclined(_ detail: String) -> String {
        "Claude did not renew this sign-in: \(detail). Sign in again."
    }

    static func renewalUnavailable(_ detail: String) -> String {
        "Claude could not renew this sign-in right now: \(detail). Your sign-in was not changed."
    }

    /// Claude's reported wording for a token without the needed scope, on either status.
    static func isScopeRequirement(_ body: Data) -> Bool {
        guard body.count <= 65_536, let text = String(bytes: body, encoding: .utf8) else { return false }
        return text.localizedCaseInsensitiveContains("scope requirement")
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
