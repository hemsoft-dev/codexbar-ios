import CryptoKit
import Foundation

struct GeminiSessionCredentials: Codable, Equatable, Sendable {
    let securePSID: String
    let securePSIDTS: String?

    enum CodingKeys: String, CodingKey {
        case securePSID = "__Secure-1PSID"
        case securePSIDTS = "__Secure-1PSIDTS"
    }

    var cookieHeader: String {
        var parts = ["__Secure-1PSID=\(securePSID)"]
        if let securePSIDTS, !securePSIDTS.isEmpty {
            parts.append("__Secure-1PSIDTS=\(securePSIDTS)")
        }
        return parts.joined(separator: "; ")
    }
}

enum GeminiSessionCredentialsParser {
    enum ParseError: LocalizedError {
        case missingSecurePSID
        case invalidValue
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .missingSecurePSID:
                "Sign in with Google to connect Gemini."
            case .invalidValue:
                "The Gemini session credential contains an invalid cookie value."
            case .encodingFailed:
                "CodexBar could not prepare the Gemini session credential for Keychain."
            }
        }
    }

    static func parse(_ input: String) throws -> GeminiSessionCredentials {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = jsonValues(from: trimmed) ?? cookieValues(from: trimmed)
        guard let securePSID = values["__Secure-1PSID"], !securePSID.isEmpty else {
            throw ParseError.missingSecurePSID
        }
        let securePSIDTS = values["__Secure-1PSIDTS"]
        guard isSafeCookieValue(securePSID), securePSIDTS.map(isSafeCookieValue) ?? true else {
            throw ParseError.invalidValue
        }
        return GeminiSessionCredentials(
            securePSID: securePSID,
            securePSIDTS: securePSIDTS?.isEmpty == false ? securePSIDTS : nil
        )
    }

    static func storedCredential(from input: String) throws -> String {
        let credentials = try parse(input)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(credentials), let result = String(data: encoded, encoding: .utf8) else {
            throw ParseError.encodingFailed
        }
        return result
    }

    private static func jsonValues(from input: String) -> [String: String]? {
        guard
            let data = input.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        var result: [String: String] = [:]
        for key in ["__Secure-1PSID", "__Secure-1PSIDTS"] {
            if let value = object[key] as? String {
                result[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }

    private static func cookieValues(from input: String) -> [String: String] {
        var normalized = input
        if normalized.lowercased().hasPrefix("cookie:") {
            normalized.removeFirst("cookie:".count)
        }

        var result: [String: String] = [:]
        for component in normalized.components(separatedBy: CharacterSet(charactersIn: ";\n\r")) {
            let pair = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "=") else { continue }
            let key = pair[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == "__Secure-1PSID" || key == "__Secure-1PSIDTS" else { continue }
            var value = pair[pair.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value.removeFirst()
                value.removeLast()
            }
            result[key] = value
        }
        return result
    }

    private static func isSafeCookieValue(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 8_192
            && !value.contains(";")
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

public final class GeminiUsageProvider: UsageProvider {
    struct UsageMetric: Equatable {
        let period: Int
        let fractionUsed: Double
        let resetsAt: Date
    }

    struct UsagePayload: Equatable {
        let fiveHour: UsageMetric?
        let weekly: UsageMetric?
    }

    private struct BootstrapTokens {
        let antiCSRFToken: String
        let buildLabel: String?
        let sessionID: String?
    }

    private final class GeminiRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard
                request.url?.scheme?.lowercased() == "https",
                request.url?.host?.lowercased() == "gemini.google.com",
                request.url?.port == nil || request.url?.port == 443
            else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    private let secretStore: SecretStore
    private let session: URLSession
    private let ownsSession: Bool
    private let usageURL: URL
    private let codingProvider: AntigravityUsageProvider

    private static let rpcID = "jSf9Qc"

    public let providerID = ProviderID.gemini

    public convenience init(
        secretStore: SecretStore = KeychainService(),
        session: URLSession? = nil,
        usageURL: URL = URL(string: "https://gemini.google.com/usage")!
    ) {
        self.init(secretStore: secretStore, session: session, sessionConfiguration: .ephemeral, usageURL: usageURL)
    }

    init(
        secretStore: SecretStore,
        session: URLSession? = nil,
        sessionConfiguration: URLSessionConfiguration,
        usageURL: URL
    ) {
        self.secretStore = secretStore
        self.codingProvider = AntigravityUsageProvider(
            secretStore: secretStore,
            sessionConfiguration: session?.configuration ?? sessionConfiguration
        )
        self.session = session ?? Self.makeSession(configuration: sessionConfiguration)
        self.ownsSession = session == nil
        self.usageURL = usageURL
    }

    deinit {
        // Delegated sessions retain their delegate until explicitly invalidated.
        if ownsSession {
            session.invalidateAndCancel()
        }
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        let initialIdentity = credentialIdentity(for: configuration)
        async let apps = fetchAppsUsage(for: configuration)
        // The coding fetch's loadCodeAssist lookup names the quota project and supplies the optional subscription.
        async let coding = codingProvider.fetchCodingUsage(
            for: configuration,
            keychainAccount: ProviderConfigurationStore.geminiCodingKeychainAccount(accountID: configuration.id)
        )
        let sources = try await (apps, coding)
        try Task.checkCancellation()
        let unchanged = initialIdentity != nil && initialIdentity == credentialIdentity(for: configuration)
        return Self.combinedResult(
            apps: sources.0, coding: sources.1.result, configuration: configuration,
            plan: unchanged ? sources.1.plan : nil
        )
    }

    private static func combinedResult(
        apps: ProviderUsageResult,
        coding: ProviderUsageResult,
        configuration: ProviderAccountConfiguration,
        plan: ProviderPlanDescriptor?
    ) -> ProviderUsageResult {
        let bars = apps.bars + coding.bars
        let failedSources = [apps, coding].filter { $0.failureMessage != nil }
        let recoverySource = failedSources.first { $0.recoveryAction != .retryRefresh } ?? failedSources.first
        let failure = bars.isEmpty ? recoverySource?.failureMessage : nil
        let unavailable = sourceAvailability(apps, definitions: GoogleUsageMetricCatalog.appsDefinitions)
            .merging(sourceAvailability(coding, definitions: GoogleUsageMetricCatalog.codingDefinitions)) { _, latest in latest }
        var messages = apps.usageMessages + coding.usageMessages
        for message in [apps.failureMessage, coding.failureMessage].compactMap({ $0 }) where !messages.contains(message) {
            messages.append(message)
        }
        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: .gemini,
            title: configuration.displayName,
            plan: plan,
            subtitle: failure ?? "Gemini Apps and coding usage",
            bars: bars,
            unavailableUsageMetrics: unavailable,
            usageMessages: messages,
            failureMessage: failure,
            recoveryAction: recoverySource?.recoveryAction ?? .retryRefresh,
            preserveCachedBarsOnFailure: failure != nil,
            fetchedAt: Date()
        )
    }

    private func credentialIdentity(for configuration: ProviderAccountConfiguration) -> String? {
        do {
            let apps = try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration)) ?? ""
            let coding = try secretStore.readSecret(
                account: ProviderConfigurationStore.geminiCodingKeychainAccount(accountID: configuration.id)
            )
            let credential = coding.flatMap { try? AntigravityCredentials.parse($0) }
            // Renewal changes the access token, not the renewable account identity.
            let codingIdentity = credential.map { [$0.refreshToken ?? $0.accessToken, $0.clientID ?? ""].joined(separator: "\0") } ?? ""
            let value = [configuration.id, apps, codingIdentity].joined(separator: "\0")
            return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        } catch { return nil }
    }

    private static func sourceAvailability(
        _ result: ProviderUsageResult,
        definitions: [GoogleUsageMetricCatalog.Definition]
    ) -> [String: String] {
        Dictionary(uniqueKeysWithValues: definitions.compactMap { definition in
            guard !result.bars.contains(where: { $0.stableKey == definition.key }) else { return nil }
            return (definition.id, result.unavailableUsageMetrics[definition.id] ?? result.failureMessage ?? "Unavailable")
        })
    }

    private func fetchAppsUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        let storedSecret: String?
        do {
            storedSecret = try secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: configuration)
            )
        } catch {
            return failureResult(
                "Gemini session credentials could not be read from Keychain.",
                configuration: configuration
            )
        }

        guard let storedSecret, !storedSecret.isEmpty else {
            return failureResult(
                "Not configured - sign in with Google.",
                configuration: configuration,
                recoveryAction: .signIn
            )
        }

        let credentials: GeminiSessionCredentials
        do {
            credentials = try GeminiSessionCredentialsParser.parse(storedSecret)
        } catch {
            return failureResult(
                "Saved Gemini session credentials are invalid. Sign in again with Google.",
                configuration: configuration,
                recoveryAction: .reauthenticate
            )
        }

        let bootstrapData: Data
        let bootstrapResponse: HTTPURLResponse
        do {
            let response = try await session.data(for: makeBootstrapRequest(credentials: credentials))
            bootstrapData = response.0
            guard let httpResponse = response.1 as? HTTPURLResponse else {
                return failureResult("Gemini returned an invalid response.", configuration: configuration)
            }
            bootstrapResponse = httpResponse
        } catch {
            try Self.rethrowCancellation(error)
            return failureResult(
                "Could not reach Gemini. Check the connection and try again.",
                configuration: configuration
            )
        }

        if let failure = httpFailureResult(response: bootstrapResponse, configuration: configuration) {
            return failure
        }
        guard
            let html = String(data: bootstrapData, encoding: .utf8),
            let tokens = Self.parseBootstrapTokens(html)
        else {
            return failureResult(
                "Gemini did not accept this session or its Usage page changed. Sign in again with Google.",
                configuration: configuration,
                recoveryAction: .reauthenticate
            )
        }

        let responseData: Data
        let usageResponse: HTTPURLResponse
        do {
            let response = try await session.data(
                for: makeUsageRequest(credentials: credentials, tokens: tokens)
            )
            responseData = response.0
            guard let httpResponse = response.1 as? HTTPURLResponse else {
                return failureResult("Gemini returned an invalid usage response.", configuration: configuration)
            }
            usageResponse = httpResponse
        } catch {
            try Self.rethrowCancellation(error)
            return failureResult(
                "Could not refresh Gemini usage. Check the connection and try again.",
                configuration: configuration
            )
        }

        if let failure = httpFailureResult(response: usageResponse, configuration: configuration) {
            return failure
        }
        let rows = Self.batchRows(from: responseData)
        if Self.hasAuthenticationRejection(in: rows) {
            return failureResult(
                "Gemini rejected these session credentials. Sign in again with Google.",
                configuration: configuration,
                recoveryAction: .reauthenticate
            )
        }
        guard let payload = Self.parseUsageResponse(rows) else {
            return failureResult(
                "Gemini's usage response format changed. No limit values were saved.",
                configuration: configuration
            )
        }

        let fetchedAt = Date()
        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: .gemini,
            title: configuration.displayName,
            subtitle: "Gemini Apps usage",
            bars: Self.bars(from: payload),
            fetchedAt: fetchedAt
        )
    }

    func makeBootstrapRequest(credentials: GeminiSessionCredentials) -> URLRequest {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(credentials.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("CodexBarIOS/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func makeUsageRequest(credentials: GeminiSessionCredentials, tokens: BootstrapTokens) -> URLRequest {
        var components = URLComponents(url: usageURL, resolvingAgainstBaseURL: false)!
        components.path = "/_/BardChatUi/data/batchexecute"
        components.queryItems = [
            URLQueryItem(name: "rpcids", value: Self.rpcID),
            URLQueryItem(name: "source-path", value: "/usage"),
            URLQueryItem(name: "bl", value: tokens.buildLabel ?? ""),
            URLQueryItem(name: "f.sid", value: tokens.sessionID ?? ""),
            URLQueryItem(name: "hl", value: "en"),
            URLQueryItem(name: "_reqid", value: String(Self.requestID())),
            URLQueryItem(name: "rt", value: "c"),
        ]

        let rpcRequest: [Any] = [[[Self.rpcID, "[]", NSNull(), "generic"]]]
        let serialized = try? JSONSerialization.data(withJSONObject: rpcRequest)
        let requestJSON = serialized.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "f.req", value: requestJSON),
            URLQueryItem(name: "at", value: tokens.antiCSRFToken),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue(credentials.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(
            "application/x-www-form-urlencoded;charset=UTF-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("text/plain,*/*", forHTTPHeaderField: "Accept")
        request.setValue("CodexBarIOS/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        return request
    }

    static func parseUsageResponse(_ data: Data) -> UsagePayload? {
        parseUsageResponse(batchRows(from: data))
    }

    private static func parseUsageResponse(_ rows: [[Any]]) -> UsagePayload? {
        for (rpcID, payload) in batchPayloads(from: rows) where rpcID == Self.rpcID {
            guard let metrics = usageMetrics(in: payload) else { continue }
            let fiveHour = metrics.first { $0.period == 1 }
            let weekly = metrics.first { $0.period == 2 }
            if fiveHour != nil || weekly != nil {
                return UsagePayload(fiveHour: fiveHour, weekly: weekly)
            }
        }
        return nil
    }

    static func bars(from payload: UsagePayload) -> [UsageBar] {
        var bars: [UsageBar] = []
        if let fiveHour = payload.fiveHour {
            bars.append(
                UsageBar(
                    stableKey: "five-hour",
                    label: "Gemini Apps five-hour",
                    used: fiveHour.fractionUsed * 100,
                    limit: 100,
                    resetsAt: fiveHour.resetsAt,
                    resetDisplayStyle: .relativeWithLocalTime,
                    projectionCurrent: fiveHour.fractionUsed,
                    projectionLimit: 1,
                    projectionPeriodStart: fiveHour.resetsAt.addingTimeInterval(-5 * 60 * 60),
                    projectionPeriodEnd: fiveHour.resetsAt,
                    showProjectionOnCurrentBar: true
                )
            )
        }
        if let weekly = payload.weekly {
            bars.append(
                UsageBar(
                    stableKey: "weekly",
                    label: "Gemini Apps weekly",
                    used: weekly.fractionUsed * 100,
                    limit: 100,
                    resetsAt: weekly.resetsAt,
                    resetDisplayStyle: .relativeWithLocalTime,
                    projectionCurrent: weekly.fractionUsed,
                    projectionLimit: 1,
                    projectionPeriodStart: weekly.resetsAt.addingTimeInterval(-7 * 24 * 60 * 60),
                    projectionPeriodEnd: weekly.resetsAt,
                    showProjectionOnCurrentBar: true
                )
            )
        }
        return bars
    }

    private static func usageMetrics(in payload: Any) -> [UsageMetric]? {
        guard let root = payload as? [Any] else { return nil }
        for value in root {
            guard let candidates = value as? [Any] else { continue }
            let metrics = candidates.compactMap(parseMetric)
            if !metrics.isEmpty {
                return metrics
            }
        }
        return nil
    }

    private static func parseMetric(_ value: Any) -> UsageMetric? {
        guard
            let tuple = value as? [Any], tuple.count >= 4,
            number(tuple[0]).map({ $0 > 0 }) == true,
            let fraction = number(tuple[1]), (0...1.5).contains(fraction),
            let periodValue = number(tuple[2]),
            periodValue.isFinite,
            periodValue == periodValue.rounded(),
            (1...2).contains(periodValue),
            let resetWrapper = tuple[3] as? [Any],
            let reset = resetWrapper.first as? [Any],
            let epoch = reset.first.flatMap(number), epoch.isFinite, epoch >= 1_600_000_000
        else {
            return nil
        }
        return UsageMetric(
            period: Int(periodValue),
            fractionUsed: fraction,
            resetsAt: Date(timeIntervalSince1970: epoch)
        )
    }

    private static func batchPayloads(from rows: [[Any]]) -> [(String, Any)] {
        rows.compactMap { row in
            guard
                let rpcID = row[1] as? String,
                let payloadText = row[2] as? String,
                let payloadData = payloadText.data(using: .utf8),
                let payload = try? JSONSerialization.jsonObject(with: payloadData)
            else {
                return nil
            }
            return (rpcID, payload)
        }
    }

    private static func hasAuthenticationRejection(in rows: [[Any]]) -> Bool {
        rows.contains { row in
            guard
                row[1] as? String == Self.rpcID,
                row.count > 5,
                let rejection = row[5] as? [Any],
                let code = rejection.first as? Int
            else {
                return false
            }
            return code == 7
        }
    }

    private static func batchRows(from data: Data) -> [[Any]] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let bytes = Array(text.utf8)
        let anchor = Array("[[\"wrb.fr\"".utf8)
        var results: [[Any]] = []
        var searchIndex = 0

        while let start = index(of: anchor, in: bytes, from: searchIndex) {
            guard let end = matchingBracket(in: bytes, from: start) else { break }
            let chunk = Data(bytes[start...end])
            if let rows = try? JSONSerialization.jsonObject(with: chunk) as? [Any] {
                for case let row as [Any] in rows where row.count >= 3 {
                    guard row[0] as? String == "wrb.fr" else { continue }
                    results.append(row)
                }
            }
            searchIndex = end + 1
        }
        return results
    }

    private static func index(of needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, start >= 0, haystack.count >= needle.count else { return nil }
        let lastStart = haystack.count - needle.count
        guard start <= lastStart else { return nil }
        for index in start...lastStart where haystack[index..<(index + needle.count)].elementsEqual(needle) {
            return index
        }
        return nil
    }

    private static func matchingBracket(in bytes: [UInt8], from start: Int) -> Int? {
        var depth = 0
        var isInsideString = false
        var isEscaped = false

        for index in start..<bytes.count {
            let byte = bytes[index]
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if byte == 0x5C {
                    isEscaped = true
                } else if byte == 0x22 {
                    isInsideString = false
                }
            } else if byte == 0x22 {
                isInsideString = true
            } else if byte == 0x5B {
                depth += 1
            } else if byte == 0x5D {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
        }
        return nil
    }

    private static func parseBootstrapTokens(_ html: String) -> BootstrapTokens? {
        guard let antiCSRFToken = jsonString(named: "SNlM0e", in: html), !antiCSRFToken.isEmpty else {
            return nil
        }
        return BootstrapTokens(
            antiCSRFToken: antiCSRFToken,
            buildLabel: jsonString(named: "cfb2h", in: html),
            sessionID: jsonString(named: "FdrFJe", in: html)
        )
    }

    private static func jsonString(named name: String, in text: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = "\"\(escapedName)\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\""
        guard
            let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        let captured = String(text[range])
        let encoded = Data("\"\(captured)\"".utf8)
        guard
            let decoded = try? JSONSerialization.jsonObject(
                with: encoded,
                options: .fragmentsAllowed
            ) as? String
        else {
            return nil
        }
        return decoded
    }

    private static func number(_ value: Any) -> Double? {
        switch value {
        case let number as NSNumber:
            number.doubleValue
        case let string as String:
            Double(string)
        default:
            nil
        }
    }

    private static func requestID() -> Int {
        100_000 + Int(Date().timeIntervalSince1970 * 1_000) % 800_000
    }

    private static func rethrowCancellation(_ error: Error) throws {
        if error is CancellationError
            || Task.isCancelled
            || (error as? URLError)?.code == .cancelled {
            throw CancellationError()
        }
    }

    private static func makeSession(configuration: URLSessionConfiguration) -> URLSession {
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return URLSession(
            configuration: configuration,
            delegate: GeminiRedirectDelegate(),
            delegateQueue: nil
        )
    }

    private func httpFailureResult(
        response: HTTPURLResponse,
        configuration: ProviderAccountConfiguration
    ) -> ProviderUsageResult? {
        switch response.statusCode {
        case 200..<300:
            nil
        case 300..<400:
            failureResult(
                "Gemini redirected this session to sign in. Sign in again with Google.",
                configuration: configuration,
                recoveryAction: .reauthenticate
            )
        case 401, 403:
            failureResult(
                "Gemini rejected these session credentials. Sign in again with Google.",
                configuration: configuration,
                recoveryAction: .reauthenticate
            )
        case 429:
            failureResult("Gemini rate limit reached. Wait before refreshing again.", configuration: configuration)
        case 500..<600:
            failureResult("Gemini could not complete the usage request. Try again later.", configuration: configuration)
        default:
            failureResult("Gemini usage returned HTTP \(response.statusCode).", configuration: configuration)
        }
    }

    private func failureResult(
        _ message: String,
        configuration: ProviderAccountConfiguration,
        recoveryAction: ProviderUsageRecoveryAction = .retryRefresh
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .gemini,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            failureMessage: message,
            recoveryAction: recoveryAction,
            preserveCachedBarsOnFailure: true,
            fetchedAt: Date()
        )
    }
}

/// Accept only named Google AI subscriptions, not generic coding tiers or quota sizes.
enum GoogleAIPlanParser {
    static func parse(_ data: Data) -> ProviderPlanDescriptor? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let paid = root["paidTier"]
        let tier = paid is NSNull ? root["currentTier"] : (paid ?? root["currentTier"])
        guard let object = tier as? [String: Any], let name = object["name"] as? String else { return nil }
        return namedPlan(name)
    }

    static func namedPlan(_ name: String) -> ProviderPlanDescriptor? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:Gemini Code Assist in )?Google (?:One )?AI (Free|Plus|Pro|Ultra)(?: (5x|20x))?(?: \((5x|20x|[0-9]+(?:\.[0-9]+)? (?:TB|GB))\))?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized))
        else { return nil }
        let value = normalized as NSString
        let tier = value.substring(with: match.range(at: 1)).capitalized
        let multiplier = match.range(at: 2).location == NSNotFound ? nil : value.substring(with: match.range(at: 2)).lowercased()
        let suffix = match.range(at: 3).location == NSNotFound ? nil : value.substring(with: match.range(at: 3))
        guard multiplier == nil || tier == "Ultra",
              suffix?.lowercased().hasSuffix("x") != true || (tier == "Ultra" && multiplier == nil) else { return nil }
        var label = "Google AI \(tier)"
        if let multiplier { label += " \(multiplier)" }
        if let suffix { label += " (\(suffix.lowercased().hasSuffix("x") ? suffix.lowercased() : suffix.uppercased()))" }
        return .make(providerPrefix: "google-ai", identifier: label.lowercased(), label: label, displayLabel: label)
    }
}
