import Foundation

/// Uses the existing Cursor sign-in. Portal capabilities stay in memory and never become saved credentials.
final class CursorSubscriptionBillingClient: @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = session.configuration.protocolClasses
        #if DEBUG
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
        self.session = URLSession(configuration: configuration, delegate: CursorBillingRedirectGuard(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    private struct Context {
        let credential: CursorSessionCredential
        let owner: CursorSubscriptionBilling.Owner
        let keychainAccount: String
        let secretStore: SecretStore
        let deadline: TimeInterval

        func validate() throws {
            try Task.checkCancellation()
            guard try secretStore.readSecret(account: keychainAccount) == credential.storedSecret else { throw CursorSessionFailure.changed }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
        }
    }

    func fetch(configuration: ProviderAccountConfiguration, credential: CursorSessionCredential,
               secretStore: SecretStore, at now: Date) async throws -> SubscriptionRenewal? {
        try Task.checkCancellation()
        guard configuration.providerID == .cursor, let owner = CursorSubscriptionBilling.Owner(credential) else { return nil }
        let context = Context(credential: credential, owner: owner, keychainAccount: ProviderConfigurationStore.keychainAccount(for: configuration),
                              secretStore: secretStore, deadline: ProcessInfo.processInfo.systemUptime + 10)
        do {
            let result = try await observe(configuration: configuration, context: context, at: now)
            try context.validate()
            return result
        } catch {
            try Task.checkCancellation()
            // Billing is optional. A rejected portal must never invalidate valid usage credentials.
            return nil
        }
    }

    private func observe(configuration: ProviderAccountConfiguration, context: Context, at now: Date) async throws -> SubscriptionRenewal? {
        try await verifyOwner(context)
        guard let profile = try await profile(context) else { return nil }
        // This POST creates access to the read-only portal session, not a purchase or subscription update.
        let portalReply = try await cursor("/api/stripeSession", method: "POST", context: context)
        guard let url = CursorSubscriptionBilling.portalURL(portalReply),
              let portal = try CursorSubscriptionBilling.Portal(await read(URLRequest(url: url), context: context)) else { return nil }
        let sessionData = try await stripe(portal, path: "", context: context)
        guard portal.owns(sessionData, customer: profile.customerID) else { return nil }
        let subscriptions = try await stripe(portal, path: "/subscriptions", context: context)
        try await verifyOwner(context)
        guard try await self.profile(context) == profile else { return nil }
        return CursorSubscriptionBilling.observation(subscriptions, profile: profile, configuration: configuration, at: now)
    }

    private func verifyOwner(_ context: Context) async throws {
        let data = try await cursor("/api/auth/me", context: context)
        let root = SubscriptionBillingParser.object(data)
        guard root?["sub"] as? String == context.owner.canonicalID else { throw CursorSessionFailure.changed }
        if let saved = context.credential.userID {
            let numericID = (root?["id"] as? NSNumber)?.stringValue
            guard saved == context.owner.canonicalID || saved == context.owner.subject || saved == numericID else { throw CursorSessionFailure.changed }
        }
    }

    private func profile(_ context: Context) async throws -> CursorSubscriptionBilling.Profile? {
        try await CursorSubscriptionBilling.Profile(cursor("/api/auth/stripe", context: context))
    }

    private func cursor(_ path: String, method: String = "GET", context: Context) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://cursor.com\(path)")!)
        request.httpMethod = method
        request.setValue(context.owner.cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/dashboard", forHTTPHeaderField: "Referer")
        return try await read(request, context: context)
    }

    private func stripe(_ portal: CursorSubscriptionBilling.Portal, path: String, context: Context) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.stripe.com/v1/billing_portal/sessions/\(portal.sessionID)\(path)")!)
        request.setValue("Bearer \(portal.key)", forHTTPHeaderField: "Authorization")
        request.setValue(portal.version, forHTTPHeaderField: "Stripe-Version")
        request.setValue(portal.merchant, forHTTPHeaderField: "Stripe-Account")
        return try await read(request, context: context)
    }

    private func read(_ original: URLRequest, context: Context) async throws -> Data {
        try context.validate()
        var request = original
        request.timeoutInterval = min(3, context.deadline - ProcessInfo.processInfo.systemUptime)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json, text/html", forHTTPHeaderField: "Accept")
        request.setValue("CodexBarIOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try context.validate()
        guard let response = response as? HTTPURLResponse, response.url == request.url, response.statusCode == 200,
              data.count <= 2_097_152 else { throw URLError(.badServerResponse) }
        return data
    }
}

private final class CursorBillingRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
