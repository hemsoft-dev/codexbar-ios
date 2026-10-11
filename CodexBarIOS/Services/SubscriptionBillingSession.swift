import Foundation

/// A separate, account-bound web session. OAuth usage credentials remain independent.
struct SubscriptionBillingSession: Codable, Equatable, Sendable {
    struct Cookie: Codable, Equatable, Sendable {
        let name: String
        let value: String
        let expiresAt: Date?
    }

    let providerID: ProviderID
    let ownerID: String
    let organizationID: String?
    let cookies: [Cookie]

    static func keychainAccount(_ configuration: ProviderAccountConfiguration) -> String {
        ProviderConfigurationStore.keychainAccount(for: configuration) + ".subscription-billing"
    }

    static func host(_ provider: ProviderID) -> String? {
        switch provider {
        case .claude: "claude.ai"
        case .grok: "grok.com"
        default: nil
        }
    }

    static func capture(_ values: [HTTPCookie], provider: ProviderID, at now: Date = Date()) -> [Cookie] {
        guard let host = host(provider) else { return [] }
        let cookies = values.filter {
            $0.isSecure && $0.path == "/" && [$0.domain, $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))].contains(host)
                && ($0.expiresDate == nil || $0.expiresDate! > now)
                && (provider != .claude || $0.name == "sessionKey")
        }.map { Cookie(name: $0.name, value: $0.value, expiresAt: $0.expiresDate) }
        return header(cookies, at: now) == nil ? [] : cookies
    }

    static func header(_ cookies: [Cookie], at now: Date) -> String? {
        guard !cookies.isEmpty, cookies.count <= 48,
              cookies.allSatisfy({ validName($0.name) && validValue($0.value) }) else { return nil }
        let current = cookies.filter { $0.expiresAt == nil || $0.expiresAt! > now }
        guard !current.isEmpty, Set(current.map(\.name)).count == current.count else { return nil }
        let value = current.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return value.utf8.count <= 16_384 ? value : nil
    }

    private static func validName(_ value: String) -> Bool {
        let separators: [UInt8] = [34, 40, 41, 44, 47, 58, 59, 60, 61, 62, 63, 64, 91, 92, 93, 123, 125]
        return !value.isEmpty && value.utf8.allSatisfy { (33...126).contains($0) && !separators.contains($0) }
    }

    private static func validValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (33...126).contains($0) && ![34, 44, 59, 92].contains($0) }
    }

    func encoded() throws -> String {
        guard let value = String(data: try JSONEncoder().encode(self), encoding: .utf8) else { throw SubscriptionBillingError.unavailable }
        return value
    }

    static func parse(_ value: String?, allowExpired: Bool = false) -> Self? {
        guard let value, value.utf8.count <= 32_768,
              let session = try? JSONDecoder().decode(Self.self, from: Data(value.utf8)),
              host(session.providerID) != nil, !session.ownerID.isEmpty,
              header(allowExpired ? session.cookies.map { Cookie(name: $0.name, value: $0.value, expiresAt: nil) } : session.cookies,
                     at: Date()) != nil else { return nil }
        return session
    }
}

enum SubscriptionBillingError: Equatable, LocalizedError {
    case unavailable
    case expiredSession
    case accessDenied
    case transportFailure
    case rejectedResponse
    case accountMismatch
    case canceled
    case unsupportedSubscription

    var errorDescription: String? {
        switch self {
        case .unavailable: "Billing could not be verified. Finish signing in, then try again. Your usage connection is unchanged."
        case .expiredSession: "Billing sign-in expired. Reconnect billing with the same account. Your usage connection is unchanged."
        case .accessDenied: "The provider denied billing access. Reconnect billing or check your subscription with the provider."
        case .transportFailure: "Billing could not be reached. Refresh when your connection is available. Your usage connection is unchanged."
        case .rejectedResponse: "The provider returned billing details that CodexBar could not verify. Check the provider for the date."
        case .accountMismatch: "Choose the same account you connected for usage. This billing session belongs to a different account."
        case .unsupportedSubscription:
            "This subscription does not provide supported personal billing details. "
                + "Claude Pro/Max and personal SuperGrok commerce subscriptions are supported. Organization, X and API billing are separate."
        case .canceled: "Billing sign-in canceled."
        }
    }
}
