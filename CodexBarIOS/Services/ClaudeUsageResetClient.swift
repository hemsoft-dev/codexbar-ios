import CryptoKit
import Foundation

public protocol ClaudeUsageResetConsuming: Sendable {
    func consumeClaudeReset(
        for configuration: ProviderAccountConfiguration,
        grantID: String,
        confirmedGrant: ClaudeUsageResetGrant,
        credentialBinding: String
    ) async throws -> ClaudeUsageResetOutcome
}

public struct ClaudeUsageResetFeedback: Equatable, Sendable {
    public let message: String
    public let isSuccess: Bool

    public init(message: String, isSuccess: Bool) {
        self.message = message
        self.isSuccess = isSuccess
    }
}

public enum ClaudeUsageResetOutcome: Equatable, Sendable {
    case reset
    case alreadyRedeemed
    case nothingToReset
    case noCredit
    case stateChanged
    /// Claude declined the confirmed reset because it wants another saved reset used first.
    case notNextGrant
}

public enum ClaudeUsageResetError: LocalizedError, Equatable, Sendable {
    case unavailable
    case credentialChanged
    case inProgress
    case indeterminate
    case storageUnavailable
    case httpStatus(Int)
    /// Claude refused the reset request itself although it had just accepted the same sign-in for
    /// the profile and inventory reads. Signing in again would not obviously help.
    case notPermitted(Int)

    public var errorDescription: String? {
        switch self {
        case .unavailable: "This Claude reset is not currently available. Refresh usage to check again."
        case .credentialChanged: "The Claude account changed. Refresh usage before using a reset."
        case .inProgress: "A Claude reset request is already in progress."
        case .indeterminate: "Claude has not confirmed the previous reset request. Refresh usage before trying again."
        case .storageUnavailable: "CodexBar could not prepare this reset. No request was sent. Try again."
        case .httpStatus(let status): "Claude could not use the reset (HTTP \(status)). Refresh usage to check again."
        case .notPermitted(let status): "Claude did not allow CodexBar to use this reset (HTTP \(status)). No reset was used."
        }
    }
}

/// Uses fresh account-scoped grants and never retries a mutating request automatically.
public actor ClaudeUsageResetClient {
    private let session: URLSession
    private let redirectDelegate = ResetRedirectDelegate()
    private let secretStore: SecretStore
    private let receiptDirectory: URL
    private let baseURL: URL
    private let now: @Sendable () -> Date
    private var activeAccounts: Set<String> = []
    private var activeScopes: Set<String> = []

    public init(
        session: URLSession = .shared,
        secretStore: SecretStore = KeychainService(),
        receiptDirectory: URL? = nil,
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.secretStore = secretStore
        self.receiptDirectory = receiptDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                                           in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeResetReceipts", isDirectory: true)
        self.baseURL = baseURL
        self.now = now
    }

    public func consume(
        for configuration: ProviderAccountConfiguration,
        accessToken: String,
        grantID: String,
        credentialBinding: String,
        confirmedGrant: ClaudeUsageResetGrant
    ) async throws -> ClaudeUsageResetOutcome {
        guard configuration.providerID == .claude, !accessToken.isEmpty else { throw ClaudeUsageResetError.unavailable }
        if Self.credentialBinding(for: accessToken) != credentialBinding {
            throw ClaudeUsageResetError.credentialChanged
        }
        guard activeAccounts.insert(configuration.id).inserted else { throw ClaudeUsageResetError.inProgress }
        defer { activeAccounts.remove(configuration.id) }
        let identity = try await verifiedIdentity(accessToken: accessToken)
        let scope = digest(identity.account + ":" + identity.organization)
        guard activeScopes.insert(scope).inserted else { throw ClaudeUsageResetError.inProgress }
        defer { activeScopes.remove(scope) }
        let receiptURL = receiptDirectory.appendingPathComponent(scope + ".json")
        guard let grant = try await verifiedGrant(for: configuration, accessToken: accessToken, identity: identity,
                                                  scope: scope, receiptURL: receiptURL, grantID: grantID, confirmedGrant: confirmedGrant)
        else { return .stateChanged }
        return try await recordAndSend(accessToken: accessToken, organization: identity.organization, grant: grant,
                                      scope: scope, receiptURL: receiptURL)
    }

    private func verifiedGrant(
        for configuration: ProviderAccountConfiguration, accessToken: String, identity: Identity,
        scope: String, receiptURL: URL, grantID: String, confirmedGrant: ClaudeUsageResetGrant
    ) async throws -> ClaudeUsageResetGrant? {
        let inventory = try await inventory(accessToken: accessToken)
        if try reconcilePendingReceipt(inventory: inventory, scope: scope, url: receiptURL) { return nil }
        guard let grant = inventory.redeemableGrants(at: now()).first(where: { $0.id == grantID }) else { throw ClaudeUsageResetError.unavailable }
        if grant != confirmedGrant { return nil }
        guard try await verifiedIdentity(accessToken: accessToken) == identity else { throw ClaudeUsageResetError.credentialChanged }
        try verifyCredential(accessToken, configuration: configuration)
        return grant
    }

    private func recordAndSend(
        accessToken: String, organization: String, grant: ClaudeUsageResetGrant, scope: String, receiptURL: URL
    ) async throws -> ClaudeUsageResetOutcome {
        let requestID = UUID().uuidString
        let receipt = Receipt(scope: scope, grantHash: digest(grant.id), remainingCount: grant.remainingCount,
                              expiresAt: grant.expiresAt)
        do {
            try storeReceipt(receipt, at: receiptURL)
        } catch {
            throw ClaudeUsageResetError.storageUnavailable
        }
        return try await sendRecordedReset(accessToken: accessToken, organization: organization, grant: grant,
                                           requestID: requestID, receiptURL: receiptURL)
    }

    private func sendRecordedReset(
        accessToken: String, organization: String, grant: ClaudeUsageResetGrant, requestID: String, receiptURL: URL
    ) async throws -> ClaudeUsageResetOutcome {
        do {
            let outcome = try await postReset(accessToken: accessToken, organization: organization, grant: grant, requestID: requestID)
            try? FileManager.default.removeItem(at: receiptURL)
            return outcome
        } catch let error as ClaudeUsageResetError {
            if case .httpStatus(let status) = error {
                guard (400..<500).contains(status), status != 408 else { throw ClaudeUsageResetError.indeterminate }
                try? FileManager.default.removeItem(at: receiptURL)
            }
            if case .notPermitted = error { try? FileManager.default.removeItem(at: receiptURL) }
            throw error
        } catch {
            throw ClaudeUsageResetError.indeterminate
        }
    }

    private func storeReceipt(_ receipt: Receipt, at url: URL) throws {
        try FileManager.default.createDirectory(at: receiptDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var directory = receiptDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let data = try JSONEncoder().encode(receipt)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    private func reconcilePendingReceipt(inventory: ClaudeUsageResetInventory, scope: String, url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let data = try? Data(contentsOf: url),
              let old = try? JSONDecoder().decode(Receipt.self, from: data), old.scope == scope
        else { throw ClaudeUsageResetError.indeterminate }
        let current = inventory.grants.first { digest($0.id) == old.grantHash }
        let expired = old.expiresAt.map { $0 <= now() } ?? false
        guard expired || (current != nil && current?.remainingCount != old.remainingCount)
        else { throw ClaudeUsageResetError.indeterminate }
        try FileManager.default.removeItem(at: url)
        return true
    }

    public func inventory(accessToken: String) async throws -> ClaudeUsageResetInventory {
        let data = try await read(path: "api/oauth/usage", query: [URLQueryItem(name: "cedar_ember", value: "1")], accessToken: accessToken)
        guard let inventory = ClaudeUsageResetInventoryParser.parse(data) else { throw ClaudeUsageResetError.unavailable }
        return inventory
    }

    private func verifiedIdentity(accessToken: String) async throws -> Identity {
        let data = try await read(path: "api/oauth/profile", accessToken: accessToken)
        guard let profile = try? JSONDecoder().decode(Profile.self, from: data),
              let rawOrganization = profile.organization?.uuid ?? profile.organizationUUID,
              let organization = UUID(uuidString: rawOrganization),
              let account = UUID(uuidString: profile.account.uuid)
        else { throw ClaudeUsageResetError.unavailable }
        return Identity(account: account.uuidString.lowercased(), organization: organization.uuidString.lowercased())
    }

    private func verifyCredential(_ token: String, configuration: ProviderAccountConfiguration) throws {
        let saved = try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration))
        guard let saved, ClaudeCredentialsParser.parse(saved)?.accessToken == token else { throw ClaudeUsageResetError.credentialChanged }
    }

    private func postReset(
        accessToken: String, organization: String, grant: ClaudeUsageResetGrant, requestID: String
    ) async throws -> ClaudeUsageResetOutcome {
        var request = request(path: "api/organizations/\(organization)/reset_rate_limits", accessToken: accessToken)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ResetRequest(program: "cedar_ember", grantID: grant.id, requestID: requestID))
        let (data, response) = try await session.data(for: request, delegate: redirectDelegate)
        let http = try checkedResponse(response, request: request)
        if http.statusCode == 401 || http.statusCode == 403 { throw ClaudeUsageResetError.notPermitted(http.statusCode) }
        guard (200..<300).contains(http.statusCode) else { throw ClaudeUsageResetError.httpStatus(http.statusCode) }
        guard data.count <= 1_048_576, let result = try? JSONDecoder().decode(ResetResponse.self, from: data) else { throw ClaudeUsageResetError.indeterminate }
        if result.result == "not_next_grant" || (result.result == "unavailable" && result.reason == "not_next_grant") {
            return .notNextGrant
        }
        switch result.result {
        case "reset": return .reset
        case "already_redeemed", "already_used": return .alreadyRedeemed
        case "nothing_to_reset", "not_limited": return .nothingToReset
        case "no_credit": return .noCredit
        default: throw ClaudeUsageResetError.indeterminate
        }
    }

    private func read(path: String, query: [URLQueryItem] = [], accessToken: String) async throws -> Data {
        var request = request(path: path, accessToken: accessToken)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        request.url = components.url
        let (data, response) = try await session.data(for: request, delegate: redirectDelegate)
        let http = try checkedResponse(response, request: request)
        guard (200..<300).contains(http.statusCode) else { throw ClaudeUsageResetError.httpStatus(http.statusCode) }
        guard data.count <= 1_048_576 else { throw ClaudeUsageResetError.unavailable }
        return data
    }

    private func request(path: String, accessToken: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 15)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        ClaudeClientIdentity.apply(to: &request)
        return request
    }

    private func checkedResponse(_ response: URLResponse, request: URLRequest) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse, http.url == request.url else { throw ClaudeUsageResetError.indeterminate }
        return http
    }

    public static func credentialBinding(for accessToken: String) -> String {
        Data(SHA256.hash(data: Data(accessToken.utf8))).base64EncodedString()
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private struct Receipt: Codable {
        let scope: String
        let grantHash: String
        let remainingCount: Int
        let expiresAt: Date?
    }

    private struct Identity: Equatable, Sendable {
        let account: String
        let organization: String
    }

    private struct Profile: Decodable {
        let account: Organization
        let organization: Organization?
        let organizationUUID: String?
        enum CodingKeys: String, CodingKey {
            case account, organization
            case organizationUUID = "organization_uuid"
        }
        struct Organization: Decodable { let uuid: String }
    }

    private struct ResetRequest: Encodable {
        let program: String
        let grantID: String
        let requestID: String
        enum CodingKeys: String, CodingKey {
            case program
            case grantID = "grant_id"
            case requestID = "request_id"
        }
    }

    private struct ResetResponse: Decodable {
        let result: String
        let reason: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            result = try container.decode(String.self, forKey: .result)
            reason = try? container.decodeIfPresent(String.self, forKey: .reason)
        }

        enum CodingKeys: String, CodingKey { case result, reason }
    }
}

/// A redirect must never replay the mutating request or send grant data elsewhere.
private final class ResetRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
