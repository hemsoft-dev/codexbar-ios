import Foundation

/// What CodexBar tells Claude about itself (#589). Every request the app sends to a Claude host
/// carries this user agent. No request's user agent may name another client, and none is re-sent
/// under a different identity when Claude refuses it. Sign-in and renewal still carry the public
/// Claude Code client identifier below.
enum ClaudeClientIdentity {
    static let userAgent = "CodexBarIOS"

    /// The public client that guided sign-in goes through. CodexBar has no client registration of
    /// its own; whether this use is permitted is the open question in #548. Sign-in and token
    /// renewal must use the same value, or saved refresh tokens stop working.
    static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// Only the scopes the app's own requests need. `user:profile` reads usage, the saved-reset
    /// inventory and the profile. `user:inference` is reported to be required to use a saved reset;
    /// the app sends no inference request. See CLAUDE-USAGE.md.
    static let requestedScope = "user:profile user:inference"

    static func apply(to request: inout URLRequest) {
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    }
}

public struct ClaudeWebAuthResult: Equatable, Sendable {
    public let credentials: ClaudeCredentials

    public var storedCredential: String {
        ClaudeCredentialsParser.storedCredential(from: credentials)
    }
}

public final class ClaudeWebAuthService: Sendable {
    public enum AuthError: LocalizedError, Equatable, Sendable {
        case couldNotStartCallbackServer
        case missingAuthorizationCode
        case stateMismatch
        case callbackTimedOut
        case secureRandomUnavailable
        case tokenExchangeFailed(String)
        case invalidTokenResponse

        public var errorDescription: String? {
            switch self {
            case .couldNotStartCallbackServer:
                "Could not start the local Claude login callback server."
            case .missingAuthorizationCode:
                "Claude sign-in did not return an authorization code."
            case .stateMismatch:
                "Claude sign-in returned an unexpected state value."
            case .callbackTimedOut:
                "Claude sign-in did not return to the app. If Claude showed an error instead of an approval screen, "
                    + "it did not accept CodexBar's sign-in request. Otherwise try again and continue all the way "
                    + "through Claude in the browser. Any saved sign-in was not changed."
            case .secureRandomUnavailable:
                "Claude sign-in could not start securely. Try again."
            case .tokenExchangeFailed(let message):
                "Claude token exchange failed: \(message)"
            case .invalidTokenResponse:
                "Claude token exchange returned an invalid response."
            }
        }
    }

    public struct PKCEPair: Equatable, Sendable {
        public let codeVerifier: String
        public let codeChallenge: String
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Int64?
        let expiresAt: Int64?
        let subscriptionType: String?
        let rateLimitTier: String?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case expiresAt = "expires_at"
            case subscriptionType = "subscription_type"
            case rateLimitTier = "rate_limit_tier"
            case error
        }
    }

    private static let authorizationBaseURL = URL(string: "https://claude.com/cai/oauth/authorize")!
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let callbackPath = "/callback"
    private let session: URLSession
    private let callbackTimeoutNanoseconds: UInt64
    private let preferredCallbackPorts: [UInt16]
    private let randomBytes: OAuthRandomness.Generator

    public init(
        session: URLSession = .shared,
        callbackTimeoutNanoseconds: UInt64 = 180_000_000_000,
        preferredCallbackPorts: [UInt16] = [1461, 1462, 1463],
        randomBytes: OAuthRandomByteGenerator? = nil
    ) {
        self.session = session
        self.callbackTimeoutNanoseconds = callbackTimeoutNanoseconds
        self.preferredCallbackPorts = preferredCallbackPorts
        self.randomBytes = randomBytes ?? OAuthRandomness.systemGenerator
    }

    @MainActor
    public func signIn(
        presentAuthorizationURL: @escaping @MainActor (URL) -> Void,
        reportStage: @escaping @MainActor (String) -> Void = { _ in },
        didReceiveCallback: @escaping @MainActor () -> Void = {}
    ) async throws -> ClaudeWebAuthResult {
        reportStage("Starting Claude sign-in...")
        let state: String
        let pkce: PKCEPair
        do {
            state = try OAuthRandomness.base64URL(byteCount: 32, using: randomBytes)
            pkce = try Self.makePKCEPair(randomBytes: randomBytes)
        } catch {
            throw AuthError.secureRandomUnavailable
        }
        reportStage("Starting local callback server...")
        let callbackServer = try await LoopbackOAuthCallbackServer<AuthError>.start(
            preferredPorts: preferredCallbackPorts,
            expectedState: state,
            callbackPath: Self.callbackPath,
            bindHost: .localhost,
            queueLabel: "com.hemsoft.CodexBarIOS.claudeOAuthCallback",
            couldNotStartError: .couldNotStartCallbackServer,
            missingCodeError: .missingAuthorizationCode,
            stateMismatchError: .stateMismatch,
            timeoutError: .callbackTimedOut,
            successHeading: "Claude sign-in complete",
            failureHeading: "Claude sign-in failed",
            maximumRequestLength: 16_384
        )
        defer {
            callbackServer.cancel()
        }

        let redirectURI = "http://localhost:\(callbackServer.port)\(Self.callbackPath)"
        reportStage("Opening Claude in the browser. Callback: localhost:\(callbackServer.port).")
        let authorizationURL = Self.authorizationURL(
            redirectURI: redirectURI,
            state: state,
            codeChallenge: pkce.codeChallenge
        )

        presentAuthorizationURL(authorizationURL)
        reportStage("Waiting for Claude to return to the app...")
        let callbackURL: URL
        do {
            callbackURL = try await withTaskCancellationHandler(
                operation: {
                    try await callbackServer.waitForCallback(
                        timeoutNanoseconds: callbackTimeoutNanoseconds
                    )
                },
                onCancel: {
                    callbackServer.cancel()
                }
            )
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        didReceiveCallback()
        reportStage("Claude returned to the app. Exchanging authorization code...")

        let result = try await exchangeCallbackForTokens(
            callbackURL: callbackURL,
            redirectURI: redirectURI,
            state: state,
            pkce: pkce
        )
        reportStage("Claude token exchange succeeded.")
        return result
    }

    public static func authorizationURL(
        redirectURI: String,
        state: String,
        codeChallenge: String
    ) -> URL {
        var components = URLComponents(url: authorizationBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: ClaudeClientIdentity.oauthClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: ClaudeClientIdentity.requestedScope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    public static func makeTokenRequestBody(
        code: String,
        redirectURI: String,
        state: String,
        codeVerifier: String
    ) -> Data {
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": ClaudeClientIdentity.oauthClientID,
            "code_verifier": codeVerifier,
            "state": state,
        ]
        return (try? JSONEncoder().encode(body)) ?? Data()
    }

    public static func makePKCEPair() throws -> PKCEPair {
        try makePKCEPair(randomBytes: OAuthRandomness.systemGenerator)
    }

    static func makePKCEPair(randomBytes: OAuthRandomness.Generator) throws -> PKCEPair {
        let pkce = try OAuthRandomness.pkce(using: randomBytes)
        return PKCEPair(codeVerifier: pkce.verifier, codeChallenge: pkce.challenge)
    }

    private func exchangeCallbackForTokens(
        callbackURL: URL,
        redirectURI: String,
        state: String,
        pkce: PKCEPair
    ) async throws -> ClaudeWebAuthResult {
        guard
            let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            components.claudeQueryItemValue(named: "state") == state
        else {
            throw AuthError.stateMismatch
        }

        guard let code = components.claudeQueryItemValue(named: "code"), !code.isEmpty else {
            throw AuthError.missingAuthorizationCode
        }

        let result = try await exchangeCodeForTokens(
            code: code,
            redirectURI: redirectURI,
            state: state,
            codeVerifier: pkce.codeVerifier
        )
        return result
    }

    private func exchangeCodeForTokens(
        code: String,
        redirectURI: String,
        state: String,
        codeVerifier: String
    ) async throws -> ClaudeWebAuthResult {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        ClaudeClientIdentity.apply(to: &request)
        request.httpBody = Self.makeTokenRequestBody(
            code: code,
            redirectURI: redirectURI,
            state: state,
            codeVerifier: codeVerifier
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidTokenResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AuthError.tokenExchangeFailed(
                TokenEndpointErrorFormatter.message(statusCode: httpResponse.statusCode, body: data)
            )
        }

        guard let tokenResponse = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw AuthError.invalidTokenResponse
        }

        if let error = tokenResponse.error {
            throw AuthError.tokenExchangeFailed(TokenEndpointErrorFormatter.message(errorCode: error))
        }

        guard let accessToken = tokenResponse.accessToken, !accessToken.isEmpty else {
            throw AuthError.invalidTokenResponse
        }

        let expiresAt = tokenResponse.expiresAt
            ?? tokenResponse.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)).claudeUnixTimeMilliseconds }
            ?? 0
        let credentials = ClaudeCredentials(
            subscriptionType: tokenResponse.subscriptionType ?? "subscription",
            rateLimitTier: tokenResponse.rateLimitTier,
            expiresAt: expiresAt,
            accessToken: accessToken,
            refreshToken: tokenResponse.refreshToken
        )

        return ClaudeWebAuthResult(credentials: credentials)
    }

}

private extension URLComponents {
    func claudeQueryItemValue(named name: String) -> String? {
        queryItems?.first { $0.name == name }?.value
    }
}

private extension Date {
    var claudeUnixTimeMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }
}
