import Foundation

/// Optional, bounded reads with an explicit cookie on provider web requests only.
final class SubscriptionBillingClient: @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = session.configuration.protocolClasses
        #if DEBUG
        // Route isolated URLProtocol fixtures without inheriting any credential headers.
        configuration.httpAdditionalHeaders = session.configuration.httpAdditionalHeaders?.filter {
            String(describing: $0.key).lowercased().hasPrefix("x-codexbar-test-")
        }
        #endif
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        self.session = URLSession(configuration: configuration, delegate: SubscriptionBillingRedirectGuard(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func connect(configuration: ProviderAccountConfiguration, usageSecret: String,
                 cookies: [SubscriptionBillingSession.Cookie]) async throws -> SubscriptionBillingSession {
        switch configuration.providerID {
        case .claude:
            let owner = try await claudeOwner(usageSecret)
            let session = SubscriptionBillingSession(providerID: .claude, ownerID: owner.account, organizationID: owner.organization, cookies: cookies)
            _ = try await claude(session, configuration: configuration, usageSecret: usageSecret, at: Date())
            return session
        case .grok:
            guard let credential = GrokCredential.parse(usageSecret) else { throw SubscriptionBillingError.unavailable }
            let session = SubscriptionBillingSession(providerID: .grok, ownerID: credential.subject, organizationID: nil, cookies: cookies)
            guard try await grok(session, configuration: configuration, at: Date()) != nil else {
                throw SubscriptionBillingError.unsupportedSubscription
            }
            return session
        default: throw SubscriptionBillingError.unavailable
        }
    }

    func fetch(configuration: ProviderAccountConfiguration, usageSecret: String,
               secretStore: SecretStore, at now: Date) async throws -> SubscriptionRenewal? {
        try Task.checkCancellation()
        let key = SubscriptionBillingSession.keychainAccount(configuration)
        guard let saved = try? secretStore.readSecret(account: key), let billing = SubscriptionBillingSession.parse(saved),
              billing.providerID == configuration.providerID,
              (try? secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration))) == usageSecret else { return nil }
        let result: SubscriptionRenewal?
        do {
            switch configuration.providerID {
            case .claude: result = try await claude(billing, configuration: configuration, usageSecret: usageSecret, at: now)
            case .grok:
                guard GrokCredential.parse(usageSecret)?.subject == billing.ownerID else { return nil }
                result = try await grok(billing, configuration: configuration, at: now)
            default: return nil
            }
        } catch {
            try Task.checkCancellation()
            return nil
        }
        try Task.checkCancellation()
        guard (try? secretStore.readSecret(account: key)) == saved,
              (try? secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration))) == usageSecret else { return nil }
        return result
    }

    struct ClaudeObservation {
        let renewal: SubscriptionRenewal?
        let problem: SubscriptionBillingProblem?
    }

    func fetchClaudeObservation(configuration: ProviderAccountConfiguration, usageSecret: String,
                                secretStore: SecretStore, at now: Date) async throws -> ClaudeObservation {
        try Task.checkCancellation()
        func unavailable(_ reason: SubscriptionBillingProblem.Reason) -> ClaudeObservation {
            ClaudeObservation(renewal: nil, problem: SubscriptionBillingProblem(accountID: configuration.id, reason: reason))
        }
        guard configuration.providerID == .claude else { return unavailable(.unsupportedSubscription) }
        let key = SubscriptionBillingSession.keychainAccount(configuration)
        let usageKey = ProviderConfigurationStore.keychainAccount(for: configuration)
        let saved: String
        do {
            guard try secretStore.readSecret(account: usageKey) == usageSecret else { return unavailable(.accountMismatch) }
            guard let value = try secretStore.readSecret(account: key) else { return unavailable(.notConnected) }
            saved = value
        } catch { return unavailable(.credentialsUnavailable) }
        guard let billing = SubscriptionBillingSession.parse(saved, allowExpired: true), billing.providerID == .claude else {
            return unavailable(.rejectedResponse)
        }
        guard SubscriptionBillingSession.header(billing.cookies, at: Date()) != nil else { return unavailable(.expiredSession) }
        let observation: ClaudeObservation
        do {
            observation = ClaudeObservation(renewal: try await claude(billing, configuration: configuration, usageSecret: usageSecret, at: now),
                                            problem: nil)
        } catch {
            try Task.checkCancellation()
            let reason: SubscriptionBillingProblem.Reason
            switch error as? SubscriptionBillingError {
            case .expiredSession: reason = .expiredSession
            case .accountMismatch: reason = .accountMismatch
            case .accessDenied: reason = .accessDenied
            case .unsupportedSubscription: reason = .unsupportedSubscription
            case .rejectedResponse, .unavailable: reason = .rejectedResponse
            default: reason = .transportFailure
            }
            observation = unavailable(reason)
        }
        try Task.checkCancellation()
        do {
            guard try secretStore.readSecret(account: key) == saved,
                  try secretStore.readSecret(account: usageKey) == usageSecret else { return unavailable(.accountMismatch) }
        } catch { return unavailable(.credentialsUnavailable) }
        return observation
    }

    private struct ClaudeOwner: Equatable {
        let account: String
        let organization: String
    }

    private func claudeOwner(_ secret: String) async throws -> ClaudeOwner {
        guard let token = ClaudeCredentialsParser.parse(secret)?.accessToken, !token.isEmpty else { throw SubscriptionBillingError.unavailable }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let root = try SubscriptionBillingParser.object(await get(request))
        guard let account = (root?["account"] as? [String: Any])?["uuid"] as? String, UUID(uuidString: account) != nil,
              let organization = root?["organization"] as? [String: Any],
              let organizationID = organization["uuid"] as? String, UUID(uuidString: organizationID) != nil else { throw SubscriptionBillingError.unavailable }
        guard ["claude_pro", "claude_max"].contains(organization["organization_type"] as? String ?? "") else {
            throw SubscriptionBillingError.unsupportedSubscription
        }
        return ClaudeOwner(account: account, organization: organizationID)
    }

    private func claude(_ billing: SubscriptionBillingSession, configuration: ProviderAccountConfiguration,
                        usageSecret: String, at now: Date) async throws -> SubscriptionRenewal? {
        let owner = try await claudeOwner(usageSecret)
        guard owner.account == billing.ownerID, owner.organization == billing.organizationID else { throw SubscriptionBillingError.accountMismatch }
        try await verifyClaudeWebOwner(billing)
        let data = try await webGet("/api/organizations/\(owner.organization)/subscription_details", billing: billing)
        guard let result = SubscriptionBillingParser.claude(data, configuration: configuration, at: now) else {
            if SubscriptionBillingParser.object(data)?["status"] is NSNull { throw SubscriptionBillingError.unsupportedSubscription }
            throw SubscriptionBillingError.rejectedResponse
        }
        try await verifyClaudeWebOwner(billing)
        guard try await claudeOwner(usageSecret) == owner else { throw SubscriptionBillingError.accountMismatch }
        return result
    }

    private func verifyClaudeWebOwner(_ billing: SubscriptionBillingSession) async throws {
        let root = try SubscriptionBillingParser.object(await webGet("/api/account", billing: billing))
        guard let account = root?["uuid"] as? String, let memberships = root?["memberships"] as? [[String: Any]] else {
            throw SubscriptionBillingError.unavailable
        }
        let organizations = memberships.compactMap { ($0["organization"] as? [String: Any])?["uuid"] as? String }
        guard account == billing.ownerID, organizations.filter({ $0 == billing.organizationID }).count == 1 else {
            throw SubscriptionBillingError.accountMismatch
        }
        let organization = memberships.compactMap { $0["organization"] as? [String: Any] }
            .first { $0["uuid"] as? String == billing.organizationID }
        if let type = organization?["billing_type"] as? String,
           ["apple_subscription", "google_play_subscription", "aws_marketplace", "external_subscription_contracted"].contains(type) {
            throw SubscriptionBillingError.unsupportedSubscription
        }
    }

    private func grok(_ billing: SubscriptionBillingSession, configuration: ProviderAccountConfiguration, at now: Date) async throws -> SubscriptionRenewal? {
        let data = try await webGet("/rest/subscriptions", billing: billing)
        _ = try SubscriptionBillingParser.grokOwner(data, expectedOwner: billing.ownerID)
        // A second authenticated observation rejects an account switch while billing is being read.
        let final = try await webGet("/rest/subscriptions", billing: billing)
        _ = try SubscriptionBillingParser.grokOwner(final, expectedOwner: billing.ownerID)
        return SubscriptionBillingParser.grok(final, configuration: configuration, owner: billing.ownerID, at: now)
    }

    private func webGet(_ path: String, billing: SubscriptionBillingSession) async throws -> Data {
        guard let host = SubscriptionBillingSession.host(billing.providerID),
              let url = URL(string: "https://\(host)\(path)") else { throw SubscriptionBillingError.unavailable }
        guard let header = SubscriptionBillingSession.header(billing.cookies, at: Date()) else { throw SubscriptionBillingError.expiredSession }
        var request = URLRequest(url: url)
        request.setValue(header, forHTTPHeaderField: "Cookie")
        request.setValue("https://\(host)", forHTTPHeaderField: "Origin")
        request.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        return try await get(request)
    }

    private func get(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBarIOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.url == request.url else { throw SubscriptionBillingError.transportFailure }
        if response.statusCode == 401, request.value(forHTTPHeaderField: "Cookie") != nil { throw SubscriptionBillingError.expiredSession }
        if response.statusCode == 403 { throw SubscriptionBillingError.accessDenied }
        guard response.statusCode == 200 else { throw SubscriptionBillingError.transportFailure }
        guard data.count <= 65_536 else { throw SubscriptionBillingError.rejectedResponse }
        return data
    }
}

private final class SubscriptionBillingRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
