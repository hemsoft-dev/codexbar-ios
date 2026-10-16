import Foundation

public final class CursorUsageProvider: UsageProvider {
    private let secretStore: SecretStore
    private let session: URLSession
    private let usageEndpoint: URL
    private let grokBotUsageEndpoint: URL
    private let membershipEndpoint: URL
    private let membershipRequestTimeout: Duration
    private let grokBotRequestTimeout: Duration
    private let waitForGrokBotTimeout: @Sendable (Duration) async throws -> Void

    public let providerID = ProviderID.cursor

    public convenience init(
        secretStore: SecretStore = KeychainService(),
        session: URLSession? = nil,
        usageEndpoint: URL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!,
        grokBotUsageEndpoint: URL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!,
        grokBotRequestTimeout: Duration = .seconds(5),
        membershipEndpoint: URL? = nil,
        membershipRequestTimeout: Duration = .seconds(5)
    ) {
        self.init(
            secretStore: secretStore,
            session: session ?? Self.isolatedSession(),
            usageEndpoint: usageEndpoint,
            grokBotUsageEndpoint: grokBotUsageEndpoint,
            grokBotRequestTimeout: grokBotRequestTimeout,
            membershipEndpoint: membershipEndpoint,
            membershipRequestTimeout: membershipRequestTimeout,
            waitForGrokBotTimeout: { try await Task.sleep(for: $0) }
        )
    }

    init(
        secretStore: SecretStore,
        session: URLSession,
        usageEndpoint: URL,
        grokBotUsageEndpoint: URL,
        grokBotRequestTimeout: Duration,
        membershipEndpoint: URL? = nil,
        membershipRequestTimeout: Duration = .seconds(5),
        waitForGrokBotTimeout: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.secretStore = secretStore
        self.session = session
        self.usageEndpoint = usageEndpoint
        self.grokBotUsageEndpoint = grokBotUsageEndpoint
        self.grokBotRequestTimeout = grokBotRequestTimeout
        self.membershipEndpoint = membershipEndpoint
            ?? URL(string: "/auth/full_stripe_profile", relativeTo: usageEndpoint)!.absoluteURL
        self.membershipRequestTimeout = membershipRequestTimeout
        self.waitForGrokBotTimeout = waitForGrokBotTimeout
    }

    private static func isolatedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: CursorRejectRedirects(), delegateQueue: nil)
    }

    private struct OptionalUsageResponse: Sendable {
        let data: Data?
        let unavailableReason: String?
    }

    private static let botTimeoutReason = "Grok Bot refresh timed out. Refresh to try again."

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        let account = ProviderConfigurationStore.keychainAccount(for: configuration)
        guard let storedSecret = try secretStore.readSecret(account: account),
              let credential = CursorSessionCredential(storedSecret: storedSecret) else {
            return failureResult(
                "Not configured - sign in with Cursor.", configuration: configuration,
                recoveryAction: .signIn, cacheIdentity: "unconfigured"
            )
        }
        do {
            try Task.checkCancellation()
            let prepared = try await prepareSession(credential, account: account)
            if prepared.attemptedRenewal {
                return try await collectUsage(for: configuration, credential: prepared.credential)
            }
            return try await collectWithRenewal(for: configuration, credential: prepared.credential, account: account)
        } catch let failure as CursorSessionFailure {
            return failureResult(
                failure.message, configuration: configuration, recoveryAction: failure.recoveryAction,
                cacheIdentity: failure == .changed ? "superseded" : credential.cacheIdentity
            )
        } catch let failure as CollectionFailure {
            return failureResult(failure.message, configuration: configuration, cacheIdentity: credential.cacheIdentity)
        } catch {
            return failureResult(
                Task.isCancelled ? "Cursor refresh canceled." : "Could not refresh Cursor usage. Try again.",
                configuration: configuration, cacheIdentity: credential.cacheIdentity
            )
        }
    }

    private static let earlyRenewalBackoff = CursorEarlyRenewalBackoff()

    private struct PreparedSession {
        let credential: CursorSessionCredential
        let attemptedRenewal: Bool
    }

    private func prepareSession(_ credential: CursorSessionCredential, account: String) async throws -> PreparedSession {
        if credential.needsRenewal(at: Date()) {
            return PreparedSession(credential: try await renew(credential, account: account), attemptedRenewal: true)
        }
        guard credential.shouldAttemptEarlyRenewal(at: Date()) else {
            return PreparedSession(credential: credential, attemptedRenewal: false)
        }
        return try await prepareEarlyRenewal(credential, account: account)
    }

    private func prepareEarlyRenewal(_ credential: CursorSessionCredential, account: String) async throws -> PreparedSession {
        let key = account + "." + CursorSessionCredential.digest(credential.storedSecret)
        guard await Self.earlyRenewalBackoff.permits(key: key, at: Date()) else {
            return PreparedSession(credential: credential, attemptedRenewal: false)
        }
        do {
            return PreparedSession(credential: try await renew(credential, account: account), attemptedRenewal: true)
        } catch {
            try Self.validateEarlyRenewalFailure(error)
            await Self.earlyRenewalBackoff.deferAttempt(key: key, at: Date())
            // An unavailable early grant is not proof that an unexpired primary session is invalid.
            return PreparedSession(credential: credential, attemptedRenewal: true)
        }
    }

    private static func validateEarlyRenewalFailure(_ error: Error) throws {
        if Task.isCancelled { throw CancellationError() }
        if let failure = error as? CursorSessionFailure, [.changed, .persistenceFailed, .invalidated].contains(failure) { throw failure }
    }

    private func collectWithRenewal(
        for configuration: ProviderAccountConfiguration, credential: CursorSessionCredential, account: String
    ) async throws -> ProviderUsageResult {
        do { return try await collectUsage(for: configuration, credential: credential) } catch let failure as CursorSessionFailure
            where failure == .rejected || failure == .needsRenewal {
            guard credential.refreshToken != nil else { throw failure }
            let updated = try await renew(credential, account: account)
            // Exactly one renewal and one retry. A second rejection requires browser reconnection.
            return try await collectUsage(for: configuration, credential: updated)
        }
    }

    private func renew(_ credential: CursorSessionCredential, account: String) async throws -> CursorSessionCredential {
        do {
            return try await CursorSessionRenewal(secretStore: secretStore, session: session).renew(credential, account: account)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let failure = error as? CursorSessionFailure { throw failure }
            throw CursorSessionFailure.renewalUnavailable
        }
    }

    private func collectUsage(
        for configuration: ProviderAccountConfiguration, credential: CursorSessionCredential
    ) async throws -> ProviderUsageResult {
        try Task.checkCancellation()
        if credential.needsRenewal(at: Date()) { throw CursorSessionFailure.needsRenewal }
        async let grokBotData = fetchGrokBotUsage(accessToken: credential.accessToken)
        async let membershipData = fetchMembership(accessToken: credential.accessToken)
        let (data, response) = try await session.data(for: makeUsageRequest(accessToken: credential.accessToken))
        try Self.validatePrimaryResponse(response)
        let optional = await grokBotData
        let membership = await membershipData
        try Task.checkCancellation()
        if credential.needsRenewal(at: Date()) { throw CursorSessionFailure.needsRenewal }
        guard try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration))
                == credential.storedSecret else { throw CursorSessionFailure.changed }
        guard var result = Self.parseUsage(
            data, grokBotUsageData: optional.data, configuration: configuration,
            membershipData: membership,
            grokBotFailureReason: optional.unavailableReason, cacheIdentity: credential.cacheIdentity
        ) else { throw URLError(.cannotParseResponse) }
        result.subscriptionRenewal = try await CursorSubscriptionBillingClient(session: session).fetch(
            configuration: configuration, credential: credential, secretStore: secretStore, at: Date()
        )
        try Task.checkCancellation()
        guard try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration))
                == credential.storedSecret else { throw CursorSessionFailure.changed }
        return result
    }

    private static func validatePrimaryResponse(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw CollectionFailure.invalidResponse }
        if [401, 403].contains(response.statusCode) { throw CursorSessionFailure.rejected }
        guard (200..<300).contains(response.statusCode) else { throw CollectionFailure.httpStatus(response.statusCode) }
    }

    private enum CollectionFailure: Error {
        case invalidResponse, httpStatus(Int)
        var message: String {
            switch self {
            case .invalidResponse: "Cursor usage returned an invalid response."
            case .httpStatus(429): "Cursor rate limit reached. Try again later."
            case .httpStatus(let status): "Cursor usage returned HTTP \(status)."
            }
        }
    }

    private func fetchGrokBotUsage(accessToken: String) async -> OptionalUsageResponse {
        let session = session
        var request = makeUsageRequest(endpoint: grokBotUsageEndpoint, accessToken: accessToken)
        let timeout = grokBotRequestTimeout
        let parts = timeout.components
        // Let the task deadline own cancellation; transport timeout is a later backstop.
        request.timeoutInterval = max(1, Double(parts.seconds) + Double(parts.attoseconds) / 1e18 + 1)
        let timedRequest = request
        let waitForTimeout = waitForGrokBotTimeout

        return await withTaskGroup(of: OptionalUsageResponse.self) { group in
            group.addTask {
                do {
                    return Self.optionalResponse(try await session.data(for: timedRequest))
                } catch {
                    let timedOut = (error as? URLError)?.code == .timedOut
                    return OptionalUsageResponse(
                        data: nil,
                        unavailableReason: timedOut ? Self.botTimeoutReason : "Could not refresh Grok Bot. Refresh to try again."
                    )
                }
            }
            group.addTask {
                try? await waitForTimeout(timeout)
                return OptionalUsageResponse(data: nil, unavailableReason: Self.botTimeoutReason)
            }

            let response = await group.next() ?? OptionalUsageResponse(data: nil, unavailableReason: Self.botTimeoutReason)
            group.cancelAll()
            return response
        }
    }

    private func fetchMembership(accessToken: String) async -> Data? {
        let session = session
        var request = makeUsageRequest(endpoint: membershipEndpoint, accessToken: accessToken)
        request.httpMethod = "GET"
        request.httpBody = nil
        request.setValue(nil, forHTTPHeaderField: "Connect-Protocol-Version")
        let timedRequest = request
        let timeout = membershipRequestTimeout
        return await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                guard let (data, response) = try? await session.data(for: timedRequest),
                      let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode) else { return nil }
                return data
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let response = await group.next() ?? nil
            group.cancelAll()
            return response
        }
    }

    func makeUsageRequest(accessToken: String) -> URLRequest {
        makeUsageRequest(endpoint: usageEndpoint, accessToken: accessToken)
    }

    private func makeUsageRequest(endpoint: URL, accessToken: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("CodexBarIOS/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func parseUsage(
        _ data: Data,
        grokBotUsageData: Data? = nil,
        configuration: ProviderAccountConfiguration,
        membershipData: Data? = nil,
        fetchedAt: Date = Date(),
        grokBotFailureReason: String? = nil,
        cacheIdentity: String? = nil
    ) -> ProviderUsageResult? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let usage = try? decoder.decode(CursorCurrentPeriodUsage.self, from: data) else {
            return nil
        }

        var bars = buildUsageBars(usage, fetchedAt: fetchedAt, onDemandEnabled: onDemandEnabled(grokBotUsageData))
        if let grokBotUsageData,
           let grokBotBar = buildGrokBotUsageBar(grokBotUsageData, fetchedAt: fetchedAt) {
            bars.append(grokBotBar)
        }
        guard !bars.isEmpty || usage.spendLimitUsage?.used != nil else {
            return nil
        }

        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: .cursor,
            title: configuration.displayName,
            plan: membershipData.flatMap(Self.parseMembership),
            subtitle: "Cursor plan usage",
            bars: bars,
            unavailableUsageMetrics: unavailableMetrics(
                usage, grokBotData: grokBotUsageData, bars: bars, grokBotFailureReason: grokBotFailureReason
            ),
            usageMessages: reportsUnifiedAccount(grokBotUsageData) ? [unifiedAccountPointer] : [],
            cardInformationSections: buildUsageInformationSections(usage.planUsage),
            cacheIdentity: cacheIdentity,
            fetchedAt: fetchedAt
        )
    }

    static func parseMembership(_ data: Data) -> ProviderPlanDescriptor? {
        guard let profile = try? JSONDecoder().decode(CursorMembershipProfile.self, from: data),
              let value = ProviderPlanDescriptor.normalizedPlanValue(profile.membershipType) else { return nil }
        let label: String
        switch value {
        case "pro": label = "Pro"
        case "pro_plus": label = "Pro+"
        case "ultra": label = "Ultra"
        case "free": label = "Hobby"
        case "free_trial": label = "Pro Trial"
        default: return nil
        }
        return .make(providerPrefix: "cursor", identifier: value, label: label, displayLabel: label)
    }

    private static func optionalResponse(_ response: (Data, URLResponse)) -> OptionalUsageResponse {
        let (data, urlResponse) = response
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            return OptionalUsageResponse(data: nil, unavailableReason: "Invalid Grok Bot response")
        }
        if (200..<300).contains(httpResponse.statusCode) {
            return OptionalUsageResponse(data: data, unavailableReason: nil)
        }
        let reason = switch httpResponse.statusCode {
        case 401: "Grok Bot session was rejected. Reconnect Cursor."
        case 403: "Cursor did not permit Grok Bot usage."
        case 429: "Grok Bot refresh was rate limited. Try again later."
        default: "Grok Bot is temporarily unavailable. Refresh to try again."
        }
        return OptionalUsageResponse(data: nil, unavailableReason: reason)
    }

    static func normalizedAccessToken(from storedSecret: String?) -> String? {
        guard var token = storedSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return nil
        }

        if token.hasPrefix("\""), token.hasSuffix("\""), token.count >= 2 {
            token.removeFirst()
            token.removeLast()
        }

        if let data = token.data(using: .utf8),
           let credentials = try? JSONDecoder().decode(CursorCredentials.self, from: data),
           let accessToken = credentials.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accessToken.isEmpty {
            return accessToken
        }

        let authorizationPrefix = "authorization:"
        if token.lowercased().hasPrefix(authorizationPrefix) {
            token = String(token.dropFirst(authorizationPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let bearerPrefix = "bearer "
        if token.lowercased().hasPrefix(bearerPrefix) {
            token = String(token.dropFirst(bearerPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return token.isEmpty ? nil : token
    }

    private static func buildUsageBars(
        _ usage: CursorCurrentPeriodUsage, fetchedAt: Date, onDemandEnabled: Bool?
    ) -> [UsageBar] {
        var bars: [UsageBar] = []
        let reset = parseUnixMilliseconds(usage.billingCycleEnd)
        let resetDescription = reset.map { formatReset($0, now: fetchedAt) }
        let billingPeriod = billingPeriod(for: usage, fetchedAt: fetchedAt)

        if let plan = usage.planUsage {
            bars.append(contentsOf: [
                usageBar(
                    stableKey: CursorUsageIdentity.cursorModelsStableKey,
                    label: "Cursor Models",
                    percent: plan.autoPercentUsed,
                    reset: reset,
                    resetDescription: resetDescription,
                    billingPeriod: billingPeriod
                ),
                usageBar(
                    stableKey: CursorUsageIdentity.otherModelsStableKey,
                    label: "Other Models",
                    percent: plan.apiPercentUsed,
                    reset: reset,
                    resetDescription: resetDescription,
                    billingPeriod: billingPeriod
                ),
            ].compactMap { $0 })
        }

        if
            onDemandEnabled != false,
            let onDemand = usage.spendLimitUsage,
            let limit = onDemand.individualLimit,
            limit > 0,
            let used = onDemand.used {
            bars.append(UsageBar(
                stableKey: CursorUsageIdentity.onDemandStableKey,
                label: "On-demand \(formatCents(used)) / \(formatCents(limit))",
                used: used,
                limit: limit,
                resetDescription: resetDescription,
                resetsAt: reset,
                resetDisplayStyle: .shortLocalDate,
                projectionCurrent: billingPeriod == nil ? nil : used,
                projectionLimit: billingPeriod == nil ? nil : limit,
                projectionPeriodStart: billingPeriod?.start,
                projectionPeriodEnd: billingPeriod?.end,
                showProjectionOnCurrentBar: billingPeriod != nil
            ))
        }

        return bars
    }

    private static func unavailableMetrics(
        _ usage: CursorCurrentPeriodUsage, grokBotData: Data?, bars: [UsageBar], grokBotFailureReason: String?
    ) -> [String: String] {
        let observed = Set(bars.compactMap(\.stableKey))
        var missing = Dictionary(uniqueKeysWithValues: CursorUsageIdentity.spendingChoices
            .filter { !observed.contains($0.key) }
            .map { ("cursor.\($0.key)", "Not reported") })
        if !observed.contains(CursorUsageIdentity.grokBotWeeklyStableKey) {
            missing[CursorUsageIdentity.grokBotWeeklyMetricID] = grokBotFailureReason ?? grokBotUnavailableReason(grokBotData)
        }
        if !observed.contains(CursorUsageIdentity.onDemandStableKey) {
            missing[CursorUsageIdentity.onDemandMetricID] = onDemandUnavailableReason(usage.spendLimitUsage, grokBotData: grokBotData)
        }
        return missing
    }

    private static func onDemandUnavailableReason(_ spending: CursorSpendLimitUsage?, grokBotData: Data?) -> String {
        let reason = onDemandUnavailableState(spending, enabled: onDemandEnabled(grokBotData))
        guard let used = spending?.used else { return reason }
        return "Spend \(formatCents(used)); \(reason.lowercased())"
    }

    private static func onDemandUnavailableState(_ spending: CursorSpendLimitUsage?, enabled: Bool?) -> String {
        if enabled == false { return "Disabled" }
        guard let spending else { return "Not reported" }
        guard let limit = spending.individualLimit else { return "Cap not reported" }
        if limit == 0 { return "No spending allowance" }
        return limit < 0 ? "Invalid spending cap" : "Spend not reported"
    }

    private static func onDemandEnabled(_ data: Data?) -> Bool? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode(CursorSpendingSettings.self, from: data))?.onDemandSettings?.enabled
    }

    /// A pointer only. Every Cursor metric stays as reported; the saved account is never moved or deleted.
    static let unifiedAccountPointer = "Cursor reports this account as part of an X Subscription. Add an X Subscription "
        + "account to see the shared weekly pool and Extra Usage Credits."

    /// `GetSandUsageStatus.is_unified` must be explicitly true; absent, false or malformed keeps today's card.
    private static func reportsUnifiedAccount(_ data: Data?) -> Bool {
        guard let data else { return false }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode(CursorUnifiedStatus.self, from: data))?.isUnified == true
    }

    private static func grokBotUnavailableReason(_ data: Data?) -> String {
        guard let data else { return "Optional refresh unavailable" }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let usage = try? decoder.decode(CursorGrokBotUsage.self, from: data) else {
            return "Invalid optional response"
        }
        if usage.usesPooledEnterpriseAllowance == true { return "Team-managed allowance" }
        if usage.hasNonZeroIncludedLimit == false || usage.includedLimitZero == true {
            return "No included allowance"
        }
        return "Not reported"
    }

    private static func buildGrokBotUsageBar(_ data: Data, fetchedAt: Date) -> UsageBar? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard
            let usage = try? decoder.decode(CursorGrokBotUsage.self, from: data),
            usage.usesPooledEnterpriseAllowance != true,
            usage.hasNonZeroIncludedLimit != false,
            usage.includedLimitZero != true,
            let percent = usage.usagePercent,
            percent.isFinite
        else {
            return nil
        }

        let usedPercent = min(max(percent, 0), 100)
        let periodStart = parseTimestamp(usage.currentPeriodStart)
        let reset = parseTimestamp(usage.nextResetTimestampUtc)
        let hasCurrentPeriod = periodStart.map { $0 < fetchedAt } == true
            && reset.map { fetchedAt < $0 } == true

        return UsageBar(
            stableKey: CursorUsageIdentity.grokBotWeeklyStableKey,
            label: "Grok Bot weekly",
            used: usedPercent,
            limit: 100,
            resetDescription: reset.map { formatReset($0, now: fetchedAt) },
            resetsAt: reset,
            resetDisplayStyle: .shortLocalDate,
            projectionCurrent: hasCurrentPeriod ? usedPercent / 100 : nil,
            projectionLimit: hasCurrentPeriod ? 1 : nil,
            projectionPeriodStart: hasCurrentPeriod ? periodStart : nil,
            projectionPeriodEnd: hasCurrentPeriod ? reset : nil,
            showProjectionOnCurrentBar: hasCurrentPeriod
        )
    }

    private static func usageBar(
        stableKey: String,
        label: String,
        percent: Double?,
        reset: Date?,
        resetDescription: String?,
        billingPeriod: CursorBillingPeriod?
    ) -> UsageBar? {
        guard let percent, percent.isFinite else {
            return nil
        }

        let usedPercent = max(percent, 0)
        return UsageBar(
            stableKey: stableKey,
            label: label,
            used: usedPercent,
            limit: 100,
            resetDescription: resetDescription,
            resetsAt: reset,
            resetDisplayStyle: .shortLocalDate,
            projectionCurrent: billingPeriod == nil ? nil : usedPercent / 100,
            projectionLimit: billingPeriod == nil ? nil : 1,
            projectionPeriodStart: billingPeriod?.start,
            projectionPeriodEnd: billingPeriod?.end,
            showProjectionOnCurrentBar: billingPeriod != nil,
            usesMinimumPositivePercent: true
        )
    }

    private static func billingPeriod(
        for usage: CursorCurrentPeriodUsage,
        fetchedAt: Date
    ) -> CursorBillingPeriod? {
        guard
            let start = parseUnixMilliseconds(usage.billingCycleStart),
            let end = parseUnixMilliseconds(usage.billingCycleEnd),
            start < fetchedAt,
            fetchedAt < end
        else {
            return nil
        }

        return CursorBillingPeriod(start: start, end: end)
    }

    private static func buildUsageInformationSections(
        _ plan: CursorPlanUsage?
    ) -> [ProviderCardInformationSection] {
        guard let plan else {
            return []
        }

        let items = [
            plan.autoPercentUsed.map {
                ProviderCardInformationItem(
                    id: "cursor.included-usage.cursor-models",
                    label: "Cursor Models",
                    detail: formatPercent($0)
                )
            },
            plan.apiPercentUsed.map {
                ProviderCardInformationItem(
                    id: "cursor.included-usage.other-models",
                    label: "Other Models",
                    detail: formatPercent($0)
                )
            },
        ].compactMap { $0 }

        guard !items.isEmpty else {
            return []
        }
        return [
            ProviderCardInformationSection(
                id: "cursor.included-usage",
                title: "Included usage",
                items: items
            ),
        ]
    }

    private static func parseUnixMilliseconds(_ value: String?) -> Date? {
        guard
            let value,
            let milliseconds = Double(value),
            milliseconds.isFinite,
            milliseconds > 0
        else {
            return nil
        }

        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func parseTimestamp(_ value: String?) -> Date? {
        guard let value else {
            return nil
        }
        if let unixTimestamp = parseUnixMilliseconds(value) {
            return unixTimestamp
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func formatReset(_ resetAt: Date, now _: Date) -> String {
        "Resets \(UserFacingDateTimeFormatter.current.shortDate(resetAt))"
    }

    private static func formatPercent(_ value: Double) -> String {
        let displayed = value > 0 && value < 1 ? 1 : max(value, 0)
        return "\(Int(displayed.rounded()))%"
    }

    private static func formatCents(_ cents: Double) -> String {
        let dollars = cents / 100
        return currencyFormatter.string(from: NSNumber(value: dollars)) ?? "$0.00"
    }

    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private func failureResult(
        _ message: String, configuration: ProviderAccountConfiguration,
        recoveryAction: ProviderUsageRecoveryAction = .retryRefresh, cacheIdentity: String? = nil
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id, providerID: .cursor, title: configuration.displayName,
            subtitle: message, bars: [],
            unavailableUsageMetrics: recoveryAction == .reauthenticate ? Dictionary(uniqueKeysWithValues:
                CursorUsageIdentity.spendingChoices.map { ("cursor.\($0.key)", "Usage unavailable. Reconnect Cursor.") }
            ) : [:],
            failureMessage: message, recoveryAction: recoveryAction, cacheIdentity: cacheIdentity, fetchedAt: Date()
        )
    }
}

private struct CursorCredentials: Decodable {
    let accessToken: String?
}

private struct CursorMembershipProfile: Decodable {
    let membershipType: String?
}

private struct CursorCurrentPeriodUsage: Decodable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let planUsage: CursorPlanUsage?
    let spendLimitUsage: CursorSpendLimitUsage?

    private enum CodingKeys: String, CodingKey {
        case billingCycleStart, billingCycleEnd, planUsage, spendLimitUsage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        billingCycleStart = try? container.decode(String.self, forKey: .billingCycleStart)
        billingCycleEnd = try? container.decode(String.self, forKey: .billingCycleEnd)
        planUsage = try container.decodeIfPresent(CursorPlanUsage.self, forKey: .planUsage)
        spendLimitUsage = try? container.decode(CursorSpendLimitUsage.self, forKey: .spendLimitUsage)
    }
}

private struct CursorBillingPeriod {
    let start: Date
    let end: Date
}

private struct CursorPlanUsage: Decodable {
    let autoPercentUsed: Double?
    let apiPercentUsed: Double?

    private enum CodingKeys: String, CodingKey {
        case autoPercentUsed
        case apiPercentUsed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoPercentUsed = Self.decodeFinitePercent(.autoPercentUsed, from: container)
        apiPercentUsed = Self.decodeFinitePercent(.apiPercentUsed, from: container)
    }

    private static func decodeFinitePercent(
        _ key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> Double? {
        guard
            let value = try? container.decode(Double.self, forKey: key),
            value.isFinite,
            Int(exactly: max(value, 0).rounded()) != nil
        else {
            return nil
        }
        return value
    }
}

private struct CursorSpendLimitUsage: Decodable {
    let individualLimit: Double?
    let individualRemaining: Double?
    let individualUsed: Double?
    private let hasReportedUsed: Bool

    var used: Double? {
        if hasReportedUsed { return individualUsed.flatMap { $0 >= 0 ? $0 : nil } }
        guard let individualLimit, let individualRemaining, individualLimit >= 0 else { return nil }
        return max(0, individualLimit - individualRemaining)
    }

    private enum CodingKeys: String, CodingKey {
        case individualLimit, individualRemaining, individualUsed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        individualLimit = Self.cents(.individualLimit, from: container)
        individualRemaining = Self.cents(.individualRemaining, from: container)
        individualUsed = Self.cents(.individualUsed, from: container)
        hasReportedUsed = container.contains(.individualUsed)
    }

    private static func cents(_ key: CodingKeys, from container: KeyedDecodingContainer<CodingKeys>) -> Double? {
        guard let value = try? container.decode(Double.self, forKey: key),
              value.isFinite, Int32(exactly: value) != nil else { return nil }
        return value
    }
}

private struct CursorSpendingSettings: Decodable {
    let onDemandSettings: CursorOnDemandSettings?
}

private struct CursorOnDemandSettings: Decodable {
    let enabled: Bool?
}

private struct CursorUnifiedStatus: Decodable {
    let isUnified: Bool?
}

private struct CursorGrokBotUsage: Decodable {
    let currentPeriodStart: String?
    let hasNonZeroIncludedLimit: Bool?
    let includedLimitZero: Bool?
    let nextResetTimestampUtc: String?
    let usagePercent: Double?
    let usesPooledEnterpriseAllowance: Bool?
}
