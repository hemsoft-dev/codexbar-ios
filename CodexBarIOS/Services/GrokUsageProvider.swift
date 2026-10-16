import CryptoKit
import Foundation

public final class GrokUsageProvider: UsageProvider {
    private static let refreshCoordinator = CredentialRefreshCoordinator<ProviderCredentialRefreshResult<GrokCredential>>()
    private static let creditsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!

    private enum CredentialState {
        case ready(GrokCredential)
        case retry
        case reconnect
    }

    /// Grok and X Subscription accounts share this xAI transport; each result follows its account's provider.
    public let providerID: ProviderID
    private let secretStore: SecretStore
    private let session: URLSession
    private let auth: GrokDeviceAuthService

    public init(
        providerID: ProviderID = .grok,
        secretStore: SecretStore = KeychainService(),
        session: URLSession? = nil
    ) {
        let session = session ?? GrokDeviceAuthService.makeSession()
        self.providerID = providerID
        self.secretStore = secretStore
        self.session = session
        self.auth = GrokDeviceAuthService(session: session)
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        let account = ProviderConfigurationStore.keychainAccount(for: configuration)
        guard let stored = try secretStore.readSecret(account: account),
              let candidate = GrokCredential.parse(stored) else {
            let message = configuration.providerID == .xSubscription
                ? "Sign in with xAI to see X Subscription usage." : "Sign in with Grok to see consumer usage."
            return failure(message, configuration: configuration)
        }
        let state = await currentCredential(candidate, keychainAccount: account)
        guard case .ready(let credential) = state else { return credentialFailure(state, configuration: configuration, subject: candidate.subject) }
        do {
            var result = try await fetchCandidate(credential, for: configuration)
            // SuperGrok commerce billing never describes an X Subscription; its parser rejects X-derived plans.
            if configuration.providerID == .grok,
               let usageSecret = try? secretStore.readSecret(account: account), GrokCredential.parse(usageSecret) == credential {
                result.subscriptionRenewal = try await SubscriptionBillingClient(session: session).fetch(
                    configuration: configuration, usageSecret: usageSecret, secretStore: secretStore, at: Date()
                )
            }
            return try GrokCredentialLock.withLock {
                guard let saved = try secretStore.readSecret(account: account),
                      GrokCredential.parse(saved) == credential else { throw GrokAuthError.unauthorized }
                return result
            }
        } catch {
            return usageFailure(error, configuration: configuration, subject: credential.subject)
        }
    }

    /// Names used in failure copy: the product whose usage is read and the identity provider that signs in.
    private static func names(_ providerID: ProviderID) -> (usage: String, auth: String) {
        providerID == .xSubscription ? ("X Subscription", "xAI") : ("Grok", "Grok")
    }

    private func credentialFailure(
        _ state: CredentialState, configuration: ProviderAccountConfiguration, subject: String
    ) -> ProviderUsageResult {
        let names = Self.names(configuration.providerID)
        switch state {
        case .ready: return failure("\(names.usage) usage could not be verified.", configuration: configuration)
        case .retry: return failure(
            "\(names.usage) usage is temporarily unavailable. Try refreshing again.",
            configuration: configuration, recoveryAction: .retryRefresh, cacheIdentity: Self.identityHash(subject)
        )
        case .reconnect: return failure(
            "\(names.auth) authorization expired or was removed. Reconnect in account settings.",
            configuration: configuration
        )
        }
    }

    private func usageFailure(_ error: Error, configuration: ProviderAccountConfiguration, subject: String) -> ProviderUsageResult {
        let names = Self.names(configuration.providerID)
        if error as? GrokAuthError == .unauthorized {
            return failure("\(names.auth) authorization was rejected. Reconnect in account settings.", configuration: configuration)
        }
        if error as? GrokAuthError == .unsupportedAccount {
            return failure(
                configuration.providerID == .xSubscription
                    ? "X Subscription usage is not available for this account."
                    : "Grok subscription usage is not available for this account.",
                configuration: configuration, recoveryAction: .retryRefresh, allowsUnscopedCacheReuse: false
            )
        }
        return failure(
            "\(names.usage) usage could not be verified. Try refreshing again.",
            configuration: configuration, recoveryAction: .retryRefresh, cacheIdentity: Self.identityHash(subject)
        )
    }

    func fetchCandidate(
        _ credential: GrokCredential,
        for configuration: ProviderAccountConfiguration
    ) async throws -> ProviderUsageResult {
        let identity = try await auth.userInfo(accessToken: credential.accessToken)
        guard identity.sub == credential.subject else { throw GrokAuthError.unauthorized }
        var request = URLRequest(url: Self.creditsURL)
        request.timeoutInterval = 20
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.url == request.url else {
            throw GrokAuthError.invalidResponse
        }
        guard response.statusCode == 200 else { throw Self.billingError(for: response.statusCode) }
        // Do not read settings for a malformed billing response; retry billing first.
        let now = Date()
        let isXSubscription = configuration.providerID == .xSubscription
        if isXSubscription {
            _ = try Self.parseXSubscription(data, configuration: configuration, subject: identity.sub, now: now)
        } else {
            _ = try Self.parseCredits(data, configuration: configuration, subject: identity.sub, now: now)
        }
        // Settings are optional. The CLI reads the tier here, not from the credits response.
        // A failed settings read must never turn a real usage response into a guessed plan.
        let tier = await fetchPlanName(accessToken: credential.accessToken)
        if isXSubscription {
            return try Self.parseXSubscription(
                data, configuration: configuration, subject: identity.sub, now: now,
                verifiedPlanName: tier.unifiedName, planLookupFailed: tier.isUnavailable
            )
        }
        return try Self.parseCredits(
            data, configuration: configuration, subject: identity.sub, now: now, verifiedPlanName: tier.name,
            planLookupFailed: tier.isUnavailable, unifiedPlanName: tier.unifiedName
        )
    }

    private static func billingError(for status: Int) -> GrokAuthError {
        switch status {
        case 401, 403: .unauthorized
        case 402, 404, 410: .unsupportedAccount
        case 408, 425, 429, 500...599: .temporarilyUnavailable
        default: .invalidResponse
        }
    }

    private struct PlanLookup {
        /// A recognized SuperGrok tier.
        let name: String?
        /// A recognized unified X Subscription tier.
        var unifiedName: String?
        let isUnavailable: Bool
    }

    private func fetchPlanName(accessToken: String) async -> PlanLookup {
        var request = URLRequest(url: Self.settingsURL)
        request.timeoutInterval = 8
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, reply) = try? await session.data(for: request),
              let response = reply as? HTTPURLResponse, response.url == request.url else {
            return PlanLookup(name: nil, isUnavailable: true)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard response.statusCode == 200,
              let settings = try? decoder.decode(GrokRemoteSettings.self, from: data) else {
            return PlanLookup(name: nil, isUnavailable: true)
        }
        return PlanLookup(
            name: Self.knownPlan(settings.subscriptionTierDisplay) ?? Self.knownPlan(settings.subscriptionTier),
            unifiedName: Self.unifiedPlan(settings.subscriptionTierDisplay) ?? Self.unifiedPlan(settings.subscriptionTier),
            isUnavailable: false
        )
    }

    static func knownPlan(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return ["SuperGrok Lite", "SuperGrok", "SuperGrok Plus", "SuperGrok Heavy"].first {
            $0.caseInsensitiveCompare(value) == .orderedSame
        }
    }

    func verifyCandidate(
        _ credential: GrokCredential, for configuration: ProviderAccountConfiguration,
        retryUntil deadline: Date,
        sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async throws -> ProviderUsageResult {
        var interval: TimeInterval = 5
        while true {
            try Task.checkCancellation()
            do {
                return try await fetchCandidate(credential, for: configuration)
            } catch {
                guard Self.isRetryableCandidateFailure(error), Date() < deadline else { throw error }
                try await sleep(min(interval, max(0, deadline.timeIntervalSinceNow)))
                interval = min(20, interval + 5)
            }
        }
    }

    private static func isRetryableCandidateFailure(_ error: Error) -> Bool {
        if let authError = error as? GrokAuthError {
            return authError == .temporarilyUnavailable || authError == .invalidResponse
        }
        if let networkError = error as? URLError {
            return GrokDeviceAuthService.isTransientNetworkError(networkError)
        }
        return false
    }

    private func currentCredential(_ credential: GrokCredential, keychainAccount: String) async -> CredentialState {
        guard credential.expiresAt <= Date().addingTimeInterval(60) else { return .ready(credential) }
        let outcome = await Self.refreshCoordinator.run(for: keychainAccount) { [self] in
            await self.refresh(credential, keychainAccount: keychainAccount)
        }
        if case .success(let updated) = outcome, updated.subject == credential.subject { return .ready(updated) }
        if case .temporarilyUnavailable = outcome { return .retry }
        return .reconnect
    }

    private func refresh(
        _ credential: GrokCredential, keychainAccount: String
    ) async -> ProviderCredentialRefreshResult<GrokCredential> {
        do {
            guard let latest = try GrokCredentialLock.withLock({
                GrokCredential.parse(try secretStore.readSecret(account: keychainAccount))
            }) else { return .rejected }
            if latest != credential { return .success(latest) }
            let renewed = try await renewedCredential(for: credential)
            guard case .success(let updated) = renewed else { return renewed }
            return try saveRenewedCredential(updated, replacing: credential, account: keychainAccount)
        } catch {
            return .temporarilyUnavailable
        }
    }

    private func renewedCredential(
        for credential: GrokCredential
    ) async throws -> ProviderCredentialRefreshResult<GrokCredential> {
        let (data, status) = try await auth.post("oauth2/token", values: [
            ("grant_type", "refresh_token"), ("refresh_token", credential.refreshToken),
            ("client_id", GrokDeviceAuthService.clientID),
        ])
        guard status == 200 else {
            return Self.isRejectedRenewal(data, status: status) ? .rejected : .temporarilyUnavailable
        }
        guard let token = try? GrokDeviceAuthService.token(data) else { return .temporarilyUnavailable }
        let expiresAt = Date().addingTimeInterval(token.expiresIn)
        let identity: GrokIdentity
        do {
            identity = try await auth.verifiedIdentity(
                accessToken: token.accessToken,
                deadline: min(expiresAt, Date().addingTimeInterval(90))
            )
        } catch GrokAuthError.unauthorized {
            return .rejected
        }
        guard identity.sub == credential.subject else { return .rejected }
        return .success(GrokCredential(
            kind: credential.kind, accessToken: token.accessToken,
            refreshToken: token.refreshToken.flatMap { $0.isEmpty ? nil : $0 } ?? credential.refreshToken,
            expiresAt: expiresAt, subject: credential.subject,
            email: identity.email ?? credential.email
        ))
    }

    private static func isRejectedRenewal(_ data: Data, status: Int) -> Bool {
        guard [400, 401, 403].contains(status),
              let reply = try? JSONDecoder().decode(GrokRenewalError.self, from: data) else { return false }
        return reply.error == "invalid_grant" || reply.error == "invalid_token"
    }

    private func saveRenewedCredential(
        _ updated: GrokCredential, replacing credential: GrokCredential, account: String
    ) throws -> ProviderCredentialRefreshResult<GrokCredential> {
        try GrokCredentialLock.withLock {
            guard let saved = try secretStore.readSecret(account: account),
                  let current = GrokCredential.parse(saved) else { return .rejected }
            if current != credential { return .success(current) }
            try secretStore.saveSecret(try updated.encoded(), account: account)
            return .success(updated)
        }
    }

    private func failure(
        _ message: String, configuration: ProviderAccountConfiguration,
        recoveryAction: ProviderUsageRecoveryAction = .reauthenticate, allowsUnscopedCacheReuse: Bool = true,
        cacheIdentity: String? = nil
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id, providerID: configuration.providerID, title: configuration.displayName,
            subtitle: message, bars: [], failureMessage: message, recoveryAction: recoveryAction,
            cacheIdentity: cacheIdentity, allowsUnscopedCacheReuse: allowsUnscopedCacheReuse,
            fetchedAt: Date()
        )
    }

    static func parseCredits(
        _ data: Data, configuration: ProviderAccountConfiguration, subject: String, now: Date,
        verifiedPlanName: String? = nil, planLookupFailed: Bool = false, unifiedPlanName: String? = nil
    ) throws -> ProviderUsageResult {
        guard let response = try? JSONDecoder().decode(GrokCreditsResponse.self, from: data),
              let config = response.config else { throw GrokAuthError.invalidResponse }
        let period = config.currentPeriod
        let start = period?.start.flatMap(date)
        let end = period?.end.flatMap(date)
        let supportedPeriod = period?.type == "USAGE_PERIOD_TYPE_WEEKLY"
        let activePeriod = supportedPeriod && start != nil && end != nil
            && start! <= now && end! > now
        let percent = config.creditUsagePercent
        let hasPercent = reportedPercent(percent) != nil
        // The first-party CLI renders an omitted percent as zero. Restrict that fallback to a
        // verified paid tier and an active shared weekly pool with no other reported usage.
        let inferredZero = !hasPercent && knownPlan(verifiedPlanName) != nil
            && config.isUnifiedBillingUser == true && activePeriod && omitsUsage(data)
        let includedPercent = hasPercent ? percent : inferredZero ? 0 : nil
        let bar: UsageBar? = if activePeriod && includedPercent != nil && config.isUnifiedBillingUser == true {
            UsageBar(
                stableKey: "included-usage",
                label: inferredZero ? "Weekly usage inferred" : "Weekly subscription usage",
                used: includedPercent!, limit: 100, resetsAt: end,
                projectionCurrent: includedPercent!, projectionLimit: 100,
                projectionPeriodStart: start, projectionPeriodEnd: end
            )
        } else {
            nil
        }
        let reason = unavailableReason(config, supportedPeriod: supportedPeriod, activePeriod: activePeriod)
        let balance = config.isUnifiedBillingUser == true
            ? money(config.prepaidBalance, kind: .balance, label: "Extra Usage Credits") : nil
        let cacheIdentity = identityHash(subject)
        return ProviderUsageResult(
            accountID: configuration.id, providerID: .grok, title: configuration.displayName,
            verifiedGrokPlanName: knownPlan(verifiedPlanName), grokPlanLookupFailed: planLookupFailed,
            grokInferredZeroCandidate: inferredZeroCandidate(config, data: data, now: now),
            subtitle: bar == nil ? reason : inferredZero ? "No included usage reported by Grok." : "Direct Grok subscription usage",
            bars: bar.map { [$0] } ?? [],
            monetaryMetrics: [balance].compactMap { $0 },
            usageMessages: (bar == nil ? [reason] : inferredZero
                ? ["Inferred zero from Grok's CLI convention, not a reported measurement."] : [])
                + (unifiedPlan(unifiedPlanName) == nil ? [] : [unifiedAccountPointer]),
            cardInformationSections: [
                ProviderCardInformationSection(
                    id: "grok.consumer-source", title: "Billing source",
                    items: [
                        ProviderCardInformationItem(
                            id: "grok.consumer-source.ledger", label: "Grok consumer connection",
                            detail: "Separate from Cursor Grok Bot and xAI developer API billing."
                        ),
                    ]
                ),
            ],
            cacheIdentity: cacheIdentity, cacheScope: "consumer.\(cacheIdentity)", fetchedAt: now
        )
    }

    /// A saved Grok account keeps its data; CodexBar never moves or deletes it on its own.
    static let unifiedAccountPointer = "This xAI account reports an X Subscription plan. Add an X Subscription account "
        + "to see its shared weekly pool once."

    /// Accepts a usage percentage only within a renderable range. Oversized finite values such as `1e100`
    /// would trap when a bar rounds them to `Int`, so they stay unavailable instead of becoming a meter.
    static func reportedPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= maximumReportedPercent else { return nil }
        return value
    }

    static let maximumReportedPercent: Double = 10_000

    static func identityHash(_ subject: String) -> String {
        Data(SHA256.hash(data: Data(subject.utf8))).base64EncodedString()
    }

    private static func inferredZeroCandidate(_ config: GrokCreditsConfig, data: Data, now: Date) -> UsageBar? {
        guard config.isUnifiedBillingUser == true, config.currentPeriod?.type == "USAGE_PERIOD_TYPE_WEEKLY",
              let start = config.currentPeriod?.start.flatMap(date), let end = config.currentPeriod?.end.flatMap(date),
              start <= now, end > now, omitsUsage(data) else { return nil }
        return UsageBar(
            stableKey: "included-usage", label: "Weekly usage inferred", used: 0, limit: 100, resetsAt: end,
            projectionCurrent: 0, projectionLimit: 100, projectionPeriodStart: start, projectionPeriodEnd: end
        )
    }

    static func retainingVerifiedPlan(_ name: String?, for incoming: ProviderUsageResult) -> ProviderUsageResult {
        var result = incoming
        let isXSubscription = incoming.providerID == .xSubscription
        result.verifiedGrokPlanName = isXSubscription ? unifiedPlan(name) : knownPlan(name)
        guard result.verifiedGrokPlanName != nil, incoming.bars.isEmpty,
              let bar = incoming.grokInferredZeroCandidate else { return result }
        // This candidate comes only from fresh billing; cached bars never supply its period or value.
        return ProviderUsageResult(
            accountID: incoming.accountID, providerID: incoming.providerID, title: incoming.title,
            verifiedGrokPlanName: result.verifiedGrokPlanName, grokPlanLookupFailed: incoming.grokPlanLookupFailed,
            subtitle: isXSubscription ? XSubscriptionCopy.inferredSubtitle : "No included usage reported by Grok.", bars: [bar],
            monetaryMetrics: incoming.monetaryMetrics,
            usageMessages: isXSubscription
                ? incoming.usageMessages.filter { $0 != XSubscriptionCopy.unavailableReason } + [XSubscriptionCopy.inferredMessage]
                : ["Inferred zero from Grok's CLI convention, not a reported measurement."],
            cardInformationSections: incoming.cardInformationSections,
            subscriptionRenewal: incoming.subscriptionRenewal,
            cacheIdentity: incoming.cacheIdentity, cacheScope: incoming.cacheScope, fetchedAt: incoming.fetchedAt
        )
    }

    static func omitsUsage(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let config = object["config"] as? [String: Any] else { return false }
        return ["creditUsagePercent", "productUsage", "used", "totalUsed", "monthlyLimit"]
            .allSatisfy { config[$0] == nil }
    }

    private static func unavailableReason(
        _ config: GrokCreditsConfig, supportedPeriod: Bool, activePeriod: Bool
    ) -> String {
        if config.isUnifiedBillingUser != true { return "No verified shared paid allowance was reported." }
        if !supportedPeriod { return "Grok did not report a weekly subscription period." }
        if !activePeriod { return "Grok did not report an active usage period." }
        return "Grok did not report included usage."
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func money(
        _ amount: GrokCreditsAmount?, kind: ProviderMonetaryMetricKind, label: String
    ) -> ProviderMonetaryMetric? {
        guard let cents = amount?.val, cents >= 0 else { return nil }
        return ProviderMonetaryMetric(kind: kind, label: label, minorUnits: cents, currencyCode: "USD", decimalPlaces: 2)
    }
}

private struct GrokRenewalError: Decodable {
    let error: String
}

private struct GrokCreditsResponse: Decodable {
    let config: GrokCreditsConfig?
}

private struct GrokCreditsConfig: Decodable {
    let creditUsagePercent: Double?
    let currentPeriod: GrokCreditsPeriod?
    let isUnifiedBillingUser: Bool?
    let prepaidBalance: GrokCreditsAmount?
}

struct GrokCreditsPeriod: Decodable {
    let type: String?
    let start: String?
    let end: String?
}

struct GrokCreditsAmount: Decodable {
    let val: Decimal?

    init(from decoder: Decoder) throws {
        // The first-party CLI's Cent wire model documents an empty object as proto3 zero.
        // Missing/null amounts remain absent; malformed/nonempty objects never become zero.
        guard let container = try? decoder.container(keyedBy: GrokCreditsKey.self) else {
            val = nil
            return
        }
        val = container.allKeys.isEmpty ? 0 : try? container.decode(Decimal.self, forKey: GrokCreditsKey("val"))
    }
}

private struct GrokCreditsKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

private struct GrokRemoteSettings: Decodable {
    let subscriptionTier: String?
    let subscriptionTierDisplay: String?
}
