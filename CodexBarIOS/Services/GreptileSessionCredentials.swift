import Foundation

enum GreptileSignInAvailability {
    static let googleNotice = "Google sign-in can't connect Greptile billing to CodexBar yet. Existing saved sessions can still refresh."
    static let googleRecovery = "Greptile hasn't provided the billing access CodexBar needs for Google sign-in yet. "
        + "Return to sign-in only if you already use another method for this Greptile account, or cancel to keep your saved connection."

    static func isGoogleSignIn(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "accounts.google.com" || host.hasSuffix(".accounts.google.com")
    }
}

struct GreptileOrganization: Codable, Equatable, Identifiable, Sendable {
    let tenantExternalId: String
    let name: String
    var id: String { tenantExternalId }
}

struct GreptileSessionCookie: Codable, Equatable, Sendable {
    let name: String
    let value: String
    let expiresAt: Date?

    static func isSessionName(_ name: String) -> Bool {
        let prefix = "__Secure-authjs.session-token"
        if name == prefix { return true }
        guard name.hasPrefix(prefix + ".") else { return false }
        let suffix = name.dropFirst(prefix.count + 1)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }
}

struct GreptileSessionCredentials: Codable, Equatable, Sendable {
    let version: Int
    let subject: String
    let organization: GreptileOrganization
    let cookies: [GreptileSessionCookie]

    var cacheIdentity: String { "\(subject):\(organization.id)" }

    func encoded() throws -> String {
        guard let value = String(data: try JSONEncoder().encode(self), encoding: .utf8) else {
            throw GreptileSignInError.invalidSession
        }
        return value
    }

    static func parse(_ value: String?) -> Self? {
        guard let data = value?.data(using: .utf8),
              let credential = try? JSONDecoder().decode(Self.self, from: data),
              credential.version == 1, !credential.subject.isEmpty,
              !credential.organization.id.isEmpty,
              (try? credential.cookieHeader(now: .distantPast)) != nil else { return nil }
        return credential
    }

    func cookieHeader(now: Date = Date()) throws -> String {
        guard !cookies.isEmpty, Set(cookies.map(\.name)).count == cookies.count,
              cookies.allSatisfy({
                  GreptileSessionCookie.isSessionName($0.name) && !$0.value.isEmpty
                      && !$0.value.contains(where: { $0.isWhitespace || $0 == ";" })
                      && $0.value.rangeOfCharacter(from: .controlCharacters) == nil
                      && ($0.expiresAt.map { $0 > now } ?? true)
              }) else { throw GreptileSignInError.expired }
        let base = "__Secure-authjs.session-token"
        if cookies.contains(where: { $0.name == base }) {
            guard cookies.count == 1 else { throw GreptileSignInError.invalidSession }
        } else {
            let expected = Set(cookies.indices.map { "\(base).\($0)" })
            guard Set(cookies.map(\.name)) == expected else { throw GreptileSignInError.invalidSession }
        }
        return cookies.sorted { $0.name < $1.name }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    static func sessionCookies(from cookies: [HTTPCookie], now: Date = Date()) throws -> [GreptileSessionCookie] {
        let eligible = cookies.filter {
            GreptileSessionCookie.isSessionName($0.name) && $0.isSecure && $0.path == "/"
                && ["app.greptile.com", ".app.greptile.com", ".greptile.com", "greptile.com"].contains($0.domain.lowercased())
                && ($0.expiresDate.map { $0 > now } ?? true)
        }
        guard Set(eligible.map(\.name)).count == eligible.count else { throw GreptileSignInError.invalidSession }
        return eligible.map { GreptileSessionCookie(name: $0.name, value: $0.value, expiresAt: $0.expiresDate) }
    }
}

enum GreptileSignInError: LocalizedError, Equatable {
    case canceled, expired, accessDenied, invalidSession, wrongAccount, unavailable, invalidBillingResponse, invalidIdentityResponse

    var requiresAuthentication: Bool {
        self == .expired || self == .accessDenied || self == .wrongAccount || self == .invalidSession
    }

    var errorDescription: String? {
        switch self {
        case .canceled: "Greptile sign-in canceled. Your saved account was not changed."
        case .expired: "Your Greptile session expired. Sign in again."
        case .accessDenied: "Greptile denied access to this session. Your saved account was not changed. Try another existing sign-in method or cancel."
        case .invalidSession: "Greptile sign-in could not be verified. Your saved account was not changed."
        case .wrongAccount: "This session belongs to another Greptile account or organization. Add a separate account to connect it."
        default: "Greptile could not return valid account data. Check the connection or try refreshing later."
        }
    }
}
