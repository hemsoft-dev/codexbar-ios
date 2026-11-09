import Foundation

final class AntigravityUsageProvider: UsageProvider {
    let providerID = ProviderID.antigravity
    private let secretStore: SecretStore
    private let session: URLSession
    /// Production returns the Gemini and Argon pools; the daily backend can answer with only other-model pools.
    static let quotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    static let dailyQuotaURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private enum FetchError: Error {
        case credential, response, changedCredential
        case http(Int)
        case unusableProduction(AntigravityQuotaParser.ProductionIssue)
    }

    /// A summary and, when the daily backend answered, the fixed reason production was not used.
    private struct Summary {
        let data: Data
        let productionNote: String?
    }

    /// One refresh's latest `loadCodeAssist` answer and the saved credential string it was read with.
    /// It outlives a failed quota read, so the optional subscription still shows when quotas don't.
    private final class CodeAssistLookup {
        var data: Data?
        var credential: String

        init(credential: String) { self.credential = credential }
    }

    /// Coding quotas plus the subscription read from the same `loadCodeAssist` answer that named the project.
    struct CodingUsage {
        let result: ProviderUsageResult
        let plan: ProviderPlanDescriptor?
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    convenience init(secretStore: SecretStore = KeychainService()) {
        self.init(secretStore: secretStore, sessionConfiguration: .ephemeral)
    }

    init(secretStore: SecretStore, sessionConfiguration: URLSessionConfiguration) {
        self.secretStore = secretStore
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: sessionConfiguration, delegate: RedirectDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        try await fetchUsage(for: configuration, keychainAccount: ProviderConfigurationStore.keychainAccount(for: configuration))
    }

    /// Gemini supplies its isolated coding credential account; the adapter also reads retained legacy credentials.
    func fetchUsage(
        for configuration: ProviderAccountConfiguration,
        keychainAccount: String
    ) async throws -> ProviderUsageResult {
        try await fetchCodingUsage(for: configuration, keychainAccount: keychainAccount).result
    }

    /// Coding quotas and the optional subscription from one `loadCodeAssist` lookup.
    /// Generic Code Assist tiers do not establish a Google One subscription, and the plan is dropped
    /// when this account's saved coding credential changed while the lookup ran.
    func fetchCodingUsage(
        for configuration: ProviderAccountConfiguration,
        keychainAccount: String
    ) async throws -> CodingUsage {
        var lookup: CodeAssistLookup?
        do {
            guard let stored = try secretStore.readSecret(account: keychainAccount) else { throw FetchError.credential }
            let credentials = try AntigravityCredentials.parse(stored)
            let current = CodeAssistLookup(credential: stored)
            lookup = current
            let summary = try await quotaData(credentials, account: keychainAccount, original: stored, lookup: current)
            try Task.checkCancellation()
            let result = try AntigravityQuotaParser.result(
                from: summary.data, configuration: configuration, productionNote: summary.productionNote
            )
            return CodingUsage(result: result, plan: plan(from: lookup, keychainAccount: keychainAccount))
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            return CodingUsage(
                result: failure(error, configuration: configuration),
                plan: plan(from: lookup, keychainAccount: keychainAccount)
            )
        }
    }

    private func plan(from lookup: CodeAssistLookup?, keychainAccount: String) -> ProviderPlanDescriptor? {
        guard let lookup, let data = lookup.data,
              (try? secretStore.readSecret(account: keychainAccount)) == lookup.credential else { return nil }
        return GoogleAIPlanParser.parse(data)
    }

    static let planURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!

    /// `loadCodeAssist` with this account's coding grant. It names the account's Cloud Code project and,
    /// optionally, its subscription.
    func codeAssistRequest(token: String) -> URLRequest {
        var request = quotaRequest(token: token, url: Self.planURL)
        request.timeoutInterval = 8
        request.httpBody = Data(#"{"metadata":{"ideType":"IDE_UNSPECIFIED","ideName":"CodexBar iOS","pluginType":"GEMINI"}}"#.utf8)
        return request
    }

    /// The account's Cloud Code project from a `loadCodeAssist` answer: a string, or an object with a string `id`.
    /// Anything else means no project, and the quota request stays `{}`.
    static func companionProject(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let value = root["cloudaicompanionProject"]
        guard let id = (value as? String) ?? ((value as? [String: Any])?["id"] as? String),
              (1...256).contains(id.count),
              !id.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        return id
    }

    /// Validate a newly issued token without reading or replacing the saved session.
    func validateCandidate(
        _ credentials: AntigravityCredentials,
        for configuration: ProviderAccountConfiguration
    ) async throws {
        let data = try await summaryData(token: credentials.accessToken, lookup: CodeAssistLookup(credential: "")).data
        try Task.checkCancellation()
        let result = try AntigravityQuotaParser.result(from: data, configuration: configuration)
        guard result.failureMessage == nil, !result.bars.isEmpty else { throw FetchError.response }
    }

    private func quotaData(
        _ credentials: AntigravityCredentials,
        account: String,
        original: String,
        lookup: CodeAssistLookup
    ) async throws -> Summary {
        if credentials.expiry.map({ $0 <= Date().addingTimeInterval(60) }) == true {
            let renewed = try await refresh(credentials, account: account, original: original)
            lookup.credential = renewed.encoded
            return try await summaryData(token: renewed.credentials.accessToken, lookup: lookup)
        }
        do {
            return try await summaryData(token: credentials.accessToken, lookup: lookup)
        } catch FetchError.http(401) where credentials.canRefresh {
            let renewed = try await refresh(credentials, account: account, original: original)
            lookup.credential = renewed.encoded
            return try await summaryData(token: renewed.credentials.accessToken, lookup: lookup)
        }
    }

    /// Ask the daily backend only when production is unreachable, errors for a reason other than sign-in,
    /// or answers without a usable metric or with the all-full placeholder.
    /// A usable production response is never mixed with daily pools.
    /// Both backends are asked for the account's own project when `loadCodeAssist` names one. If production
    /// rejects that project with 400 or 403, it is asked once more with `{}`, the request used before #519's fix.
    private func summaryData(token: String, lookup: CodeAssistLookup) async throws -> Summary {
        lookup.data = try await codeAssistData(token: token)
        var project = lookup.data.flatMap(Self.companionProject)
        do {
            let data: Data
            do {
                data = try await responseData(for: quotaRequest(token: token, project: project))
            } catch FetchError.http(let status) where project != nil && [400, 403].contains(status) {
                // A project Google refuses must not turn the project-less read into a reconnect prompt.
                try Task.checkCancellation()
                project = nil
                data = try await responseData(for: quotaRequest(token: token))
            }
            if let issue = AntigravityQuotaParser.productionIssue(data) { throw FetchError.unusableProduction(issue) }
            return Summary(data: data, productionNote: nil)
        } catch let error where Self.allowsDailyFallback(after: error) {
            try Task.checkCancellation()
            let data = try await responseData(for: quotaRequest(token: token, url: Self.dailyQuotaURL, project: project))
            return Summary(data: data, productionNote: Self.productionNote(after: error, namedProject: project != nil))
        }
    }

    /// A failed or unreadable lookup only leaves the project out; cancellation still stops the refresh.
    private func codeAssistData(token: String) async throws -> Data? {
        do {
            return try await responseData(for: codeAssistRequest(token: token))
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            return nil
        }
    }

    private static func allowsDailyFallback(after error: Error) -> Bool {
        switch error {
        case FetchError.http(let status): return ![400, 401, 403].contains(status)
        case FetchError.response, FetchError.unusableProduction: return true
        case let error as URLError: return error.code != .cancelled
        default: return false
        }
    }

    /// Fixed, content-free wording that tells which production branch sent the request to the daily backend
    /// and whether that request named the account's project. It never includes the project ID.
    static func productionNote(after error: Error, namedProject: Bool) -> String {
        let scope = namedProject ? "When asked for this account's project" : "When asked without a project"
        let reason: String
        switch error {
        case FetchError.http(let status): reason = "returned HTTP \(status)"
        case FetchError.unusableProduction(.noCurrentPool): reason = "reported no current pool"
        case FetchError.unusableProduction(.allFullPlaceholder): reason = "reported every pool full, which CodexBar ignores"
        case is URLError: reason = "couldn't be reached"
        default: reason = "sent a response CodexBar couldn't read"
        }
        return "\(scope), Google's main quota service \(reason). These quotas come from its backup service, "
            + "which can leave out Gemini Models and Argon."
    }

    /// `{"project": "<id>"}` when the account's project is known, otherwise `{}` as before.
    func quotaRequest(token: String, url: URL = quotaURL, project: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        let body = project.map { ["project": $0] } ?? [:]
        request.httpBody = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        return request
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.response }
        guard http.statusCode == 200 else { throw FetchError.http(http.statusCode) }
        guard data.count <= 1_048_576 else { throw FetchError.response }
        return data
    }

    private func refresh(
        _ credentials: AntigravityCredentials,
        account: String,
        original: String
    ) async throws -> (credentials: AntigravityCredentials, encoded: String) {
        guard credentials.canRefresh else { throw FetchError.credential }
        let data = try await responseData(for: refreshRequest(credentials))
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard token.expiresIn.isFinite, token.expiresIn > 0, token.expiresIn <= 86_400 else { throw FetchError.response }
        var updated = credentials
        updated.accessToken = token.accessToken
        updated.refreshToken = token.refreshToken ?? credentials.refreshToken
        updated.expiry = Date().addingTimeInterval(token.expiresIn)
        let encoded = try updated.encoded()
        _ = try AntigravityCredentials.parse(encoded)
        try Task.checkCancellation()
        try await saveRenewedCredential(encoded, account: account, original: original)
        return (updated, encoded)
    }

    func refreshRequest(_ credentials: AntigravityCredentials) -> URLRequest {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: credentials.refreshToken),
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "client_secret", value: credentials.clientSecret),
        ]
        components.queryItems = components.queryItems?.filter { $0.value != nil }
        request.httpBody = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        return request
    }

    // Account replacement and disconnect run on MainActor in ProviderSettingsViewModel.
    // Keep this synchronous compare-and-save on the same actor so logout cannot
    // interleave between the two Keychain operations. Network I/O stays off actor.
    @MainActor
    private func saveRenewedCredential(_ encoded: String, account: String, original: String) throws {
        guard try secretStore.readSecret(account: account) == original else { throw FetchError.changedCredential }
        try secretStore.saveSecret(encoded, account: account)
    }

    private func failure(_ error: Error, configuration: ProviderAccountConfiguration) -> ProviderUsageResult {
        let message: String
        let recovery: ProviderUsageRecoveryAction
        switch error {
        case FetchError.credential, is AntigravityCredentials.CredentialError,
             FetchError.http(400), FetchError.http(401), FetchError.http(403):
            message = configuration.providerID == .gemini
                ? "Coding connection required. Choose Connect Coding Usage in this Gemini account's settings."
                : "The saved coding connection needs attention. Open Gemini settings."
            recovery = .reauthenticate
        case FetchError.changedCredential:
            message = configuration.providerID == .gemini
                ? "Coding credentials changed during refresh. Refresh this Gemini account again."
                : "Antigravity credentials changed during refresh. Refresh this account again."
            recovery = .retryRefresh
        default:
            message = configuration.providerID == .gemini
                ? "Coding quotas are unavailable. Try refreshing again."
                : "Antigravity quotas are unavailable. Try refreshing again."
            recovery = .retryRefresh
        }
        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: .antigravity,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            failureMessage: message,
            recoveryAction: recovery,
            fetchedAt: Date()
        )
    }
}
