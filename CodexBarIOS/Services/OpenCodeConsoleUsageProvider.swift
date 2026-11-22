import CryptoKit
import Foundation

struct OpenCodeConsoleUsageProvider {
    private static let refreshCoordinator = CredentialRefreshCoordinator<ProviderCredentialRefreshResult<OpenCodeConsoleCredential>>()
    let secretStore: SecretStore
    var makeSession: @Sendable () -> URLSession = { OpenCodeDeviceAuthService.makeSession() }
    /// The instant a fetch observes usage and billing at. Tests pin it so fixture billing periods never expire.
    var now: @Sendable () -> Date = { Date() }

    func fetchUsage(
        credential: OpenCodeConsoleCredential, configuration: ProviderAccountConfiguration
    ) async -> ProviderUsageResult {
        let service = OpenCodeDeviceAuthService(session: makeSession())
        defer { service.session.invalidateAndCancel() }
        guard credential.workspaceID == configuration.openCodeWorkspaceId,
              let current = await currentCredential(credential, configuration: configuration, service: service) else {
            return ProviderUsageResult(
                accountID: configuration.id, providerID: .openCodeZen, title: "OpenCode",
                subtitle: "Reconnect in account settings.", bars: [],
                failureMessage: "OpenCode authorization is unavailable. Reconnect in account settings.",
                fetchedAt: now()
            )
        }
        let fetchedAt = now()
        async let balance = fetchBalance(current, service: service)
        async let goUsage = fetchGo(current, configuration: configuration, service: service, now: fetchedAt)
        let identity = Data(SHA256.hash(data: Data("\(current.workspaceID)\u{0}\(current.userID)".utf8)))
            .base64EncodedString()
        let (balanceValue, goValue) = await (balance, goUsage)
        var result = OpenCodeZenUsageProvider.buildCombinedResult(
            balance: balanceValue, goUsage: goValue.usage, configuration: configuration,
            cacheIdentity: identity, cacheScope: "console.\(current.workspaceID).\(current.userID)", fetchedAt: fetchedAt
        )
        if credentialIsSaved(current, configuration: configuration), !Task.isCancelled {
            result.subscriptionRenewal = goValue.renewal
        }
        return result
    }

    private func currentCredential(
        _ credential: OpenCodeConsoleCredential, configuration: ProviderAccountConfiguration, service: OpenCodeDeviceAuthService
    ) async -> OpenCodeConsoleCredential? {
        guard credential.expiresAt <= Date().addingTimeInterval(60) else { return credential }
        let account = ProviderConfigurationStore.keychainAccount(for: configuration)
        let result = await Self.refreshCoordinator.run(for: account) {
            await performProviderCredentialRefresh(
                credentials: credential, keychainAccount: account, secretStore: secretStore,
                session: service.session, now: { Date() }, parse: { OpenCodeConsoleCredential.parse($0) },
                storedCredential: { (try? $0.encoded()) ?? "" },
                prepare: { _ in
                    var request = URLRequest(url: OpenCodeDeviceAuthService.baseURL.appending(path: "auth/device/token"))
                    request.httpMethod = "POST"
                    request.timeoutInterval = 20
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try? JSONSerialization.data(withJSONObject: [
                        "grant_type": "refresh_token", "refresh_token": credential.refreshToken,
                        "client_id": OpenCodeDeviceAuthService.clientID,
                    ])
                    return .request(request)
                },
                decode: { data, now in
                    guard let token = try? JSONDecoder().decode(OpenCodeDeviceToken.self, from: data),
                          let refreshed = try? token.credential(
                            workspaceID: credential.workspaceID, userID: credential.userID, now: now
                          ) else { return .rejected }
                    return .success(refreshed)
                }
            )
        }
        if case .temporarilyUnavailable = result,
           credential.expiresAt > Date(),
           let saved = try? secretStore.readSecret(account: account),
           OpenCodeConsoleCredential.parse(saved) == credential {
            return credential
        }
        guard case .success(let refreshed) = result,
              refreshed.workspaceID == credential.workspaceID, refreshed.userID == credential.userID else { return nil }
        return refreshed
    }

    private func fetchBalance(
        _ credential: OpenCodeConsoleCredential, service: OpenCodeDeviceAuthService
    ) async -> OpenCodeBalanceFetchOutcome {
        do {
            let data = try await service.get(
                path: "api/billing/status", accessToken: credential.accessToken, workspaceID: credential.workspaceID
            )
            guard let value = Self.balance(data) else { return .failure("OpenCode returned an unreadable Zen balance.") }
            return .value(value)
        } catch {
            return .failure("OpenCode Zen balance could not be verified. Try refreshing or reconnecting.")
        }
    }

    private func fetchGo(
        _ credential: OpenCodeConsoleCredential, configuration: ProviderAccountConfiguration,
        service: OpenCodeDeviceAuthService, now: Date
    ) async -> (usage: OpenCodeGoPageOutcome, renewal: SubscriptionRenewal?) {
        let verifiedBefore = await verifyBillingIdentity(credential, configuration: configuration, service: service)
        do {
            let data = try await service.get(
                path: "api/go/status", accessToken: credential.accessToken, workspaceID: credential.workspaceID
            )
            let usage = Self.goUsage(data, userID: credential.userID, now: now)
            let candidate = OpenCodeSubscriptionBilling.observation(data, credential: credential, configuration: configuration, at: now)
            guard verifiedBefore, let candidate,
                  await verifyBillingIdentity(credential, configuration: configuration, service: service) else { return (usage, nil) }
            return (usage, candidate)
        } catch {
            return (.failure("OpenCode Go usage could not be verified. Try refreshing or reconnecting."), nil)
        }
    }

    private func credentialIsSaved(_ credential: OpenCodeConsoleCredential, configuration: ProviderAccountConfiguration) -> Bool {
        guard let saved = try? secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration)) else { return false }
        return configuration.openCodeWorkspaceId == credential.workspaceID && OpenCodeConsoleCredential.parse(saved) == credential
    }

    private func verifyBillingIdentity(
        _ credential: OpenCodeConsoleCredential, configuration: ProviderAccountConfiguration, service: OpenCodeDeviceAuthService
    ) async -> Bool {
        guard !Task.isCancelled, credentialIsSaved(credential, configuration: configuration) else { return false }
        do {
            let data = try await service.get(path: "auth/session", accessToken: credential.accessToken, timeout: 3)
            return !Task.isCancelled && credentialIsSaved(credential, configuration: configuration)
                && OpenCodeSubscriptionBilling.matchesIdentity(data, credential: credential)
        } catch { return false }
    }

    static func balance(_ data: Data) -> Double? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = microcents(object["balanceMicroCents"]) else { return nil }
        return NSDecimalNumber(decimal: value / 100_000_000).doubleValue
    }

    static func goUsage(_ data: Data, userID: String, now: Date) -> OpenCodeGoPageOutcome {
        let failure = OpenCodeGoPageOutcome.failure("OpenCode returned unreadable Go allowance windows.")
        guard let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return failure }
        if value is NSNull { return .notSubscribed }
        guard let object = value as? [String: Any] else { return failure }
        return goUsage(object, userID: userID, now: now)
    }

    private static func goUsage(_ object: [String: Any], userID: String, now: Date) -> OpenCodeGoPageOutcome {
        let failure = OpenCodeGoPageOutcome.failure("OpenCode returned unreadable Go allowance windows.")
        guard let subscriber = object["subscriberUserId"] as? String else { return failure }
        guard subscriber == userID else { return .otherWorkspaceMember }
        if object["access"] is NSNull { return .notSubscribed }
        guard let access = object["access"] as? [String: Any],
              let windows = windows(access: access, now: now) else { return failure }
        return .subscribed(windows)
    }

    private static func windows(access: [String: Any], now: Date) -> [OpenCodeGoWindow]? {
        guard let meters = access["meters"] as? [String: Any] else { return nil }
        let descriptors = [
            ("fiveHour", "go.rolling-5-hour", "5-hour usage limit"),
            ("week", "go.weekly", "Weekly usage limit"),
            ("month", "go.monthly", "Monthly usage limit"),
        ]
        var windows: [OpenCodeGoWindow] = []
        for (key, stableKey, label) in descriptors {
            guard let meter = meters[key] as? [String: Any] else { return nil }
            let rawReset = key == "month" ? access["endsAt"] : meter["resetsAt"]
            guard let window = window(
                meter: meter, stableKey: stableKey, label: label, rawReset: rawReset, now: now
            ) else { return nil }
            windows.append(window)
        }
        return windows
    }

    private static func window(
        meter: [String: Any], stableKey: String, label: String, rawReset: Any?, now: Date
    ) -> OpenCodeGoWindow? {
        guard let used = microcents(meter["usedMicroCents"]), used >= 0,
              let limit = microcents(meter["limitMicroCents"]), limit > 0 else { return nil }
        let reset = date(rawReset)
        let inactive = stableKey == "go.rolling-5-hour" && rawReset is NSNull && meter["startsAt"] is NSNull && used == 0
        guard reset != nil || inactive else { return nil }
        let percent = NSDecimalNumber(decimal: used / limit * 100).doubleValue
        guard percent.isFinite else { return nil }
        return OpenCodeGoWindow(
            stableKey: stableKey, label: label, usagePercent: percent,
            resetInSeconds: reset?.timeIntervalSince(now) ?? 0,
            hasExactResetBoundary: reset != nil, hasReset: reset != nil
        )
    }

    private static func microcents(_ value: Any?) -> Decimal? {
        guard let string = value as? String, string.count <= 38,
              string.range(of: "^-?[0-9]+$", options: .regularExpression) != nil,
              let decimal = Decimal(string: string), !decimal.isNaN else { return nil }
        return decimal
    }

    private static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
