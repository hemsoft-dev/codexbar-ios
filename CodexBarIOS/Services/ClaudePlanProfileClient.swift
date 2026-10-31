import Foundation
import CoreFoundation

enum ClaudePlanResolution: Sendable {
    case unavailable
    case resolved(ProviderPlanDescriptor?)

    func plan(fallback: ProviderPlanDescriptor?) -> ProviderPlanDescriptor? {
        switch self {
        case .unavailable: fallback
        case .resolved(let plan): plan
        }
    }
}

/// Reads plan metadata, never inference or billing mutations. Cache ownership follows the access token.
actor ClaudePlanProfileClient {
    private struct Entry {
        let binding: String
        let generation: UUID
        var resolution: ClaudePlanResolution = .unavailable
        var nextAttempt: Date = .distantPast
        var request: Task<ProfileResponse, Never>?
        var requestGeneration = UUID()
    }

    private struct ProfileResponse: Sendable {
        let resolution: ClaudePlanResolution?
        let retryDelay: TimeInterval
    }

    private let session: URLSession
    private var entries: [String: Entry] = [:]

    init(session: URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = session.configuration.protocolClasses
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        self.session = URLSession(configuration: configuration, delegate: ClaudeProfileRedirectGuard(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func clear(accountID: String) {
        entries.removeValue(forKey: accountID)?.request?.cancel()
    }

    func resolve(accountID: String, accessToken: String, at date: Date,
                 isCurrent: @Sendable () -> Bool = { true }) async -> ClaudePlanResolution {
        guard isCurrent() else { return .unavailable }
        let binding = ClaudeUsageResetClient.credentialBinding(for: accessToken)
        if entries[accountID]?.binding != binding {
            clear(accountID: accountID)
            entries[accountID] = Entry(binding: binding, generation: UUID())
        }
        guard var entry = entries[accountID] else { return .unavailable }
        if entry.request == nil, date < entry.nextAttempt { return entry.resolution }
        if entry.request == nil { entry.requestGeneration = UUID() }
        let request = entry.request ?? Task { await Self.fetch(accessToken: accessToken, session: session, at: date) }
        entry.request = request
        entries[accountID] = entry
        let response = await request.value
        guard isCurrent() else {
            if entries[accountID]?.binding == binding { clear(accountID: accountID) }
            return .unavailable
        }
        guard var current = entries[accountID], current.generation == entry.generation else { return .unavailable }
        guard current.requestGeneration == entry.requestGeneration else { return current.resolution }
        // Concurrent callers share one task. Only its first completion advances the throttle.
        if current.request != nil {
            if let resolution = response.resolution { current.resolution = resolution }
            current.nextAttempt = date.addingTimeInterval(response.retryDelay)
            current.request = nil
            entries[accountID] = current
        }
        return current.resolution
    }

    private static func fetch(accessToken: String, session: URLSession, at date: Date) async -> ProfileResponse {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("CodexBarIOS", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return ProfileResponse(resolution: nil, retryDelay: 300) }
            if http.statusCode == 401 || http.statusCode == 403 {
                return ProfileResponse(resolution: .resolved(nil), retryDelay: 300)
            }
            guard http.statusCode == 200 else {
                return ProfileResponse(resolution: nil, retryDelay: retryDelay(http, at: date))
            }
            guard data.count <= 65_536, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ProfileResponse(resolution: nil, retryDelay: 300)
            }
            return ProfileResponse(resolution: .resolved(ClaudeProfilePlanParser.parse(root)), retryDelay: 300)
        } catch {
            return ProfileResponse(resolution: nil, retryDelay: 300)
        }
    }
    private static func retryDelay(_ response: HTTPURLResponse, at date: Date) -> TimeInterval {
        let raw = response.value(forHTTPHeaderField: "Retry-After") ?? ""
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let delay = TimeInterval(raw) ?? formatter.date(from: raw)?.timeIntervalSince(date) ?? 300
        return max(300, min(delay.isFinite ? delay : 300, 86_400))
    }
}

enum ClaudeProfilePlanParser {
    static func parse(_ root: [String: Any]) -> ProviderPlanDescriptor? {
        if root["organization"] != nil, !(root["organization"] is [String: Any]) { return nil }
        if root["account"] != nil, !(root["account"] is [String: Any]) { return nil }
        let organization = root["organization"] as? [String: Any] ?? [:]
        let account = root["account"] as? [String: Any] ?? [:]
        for key in ["has_claude_max", "has_claude_pro"] where account[key] != nil {
            guard boolean(account[key]) != nil else { return nil }
        }
        let rawType = ProviderPlanDescriptor.normalizedPlanValue(organization["organization_type"] as? String)
        if organization["organization_type"] != nil, rawType == nil { return nil }
        let tier = ProviderPlanDescriptor.normalizedPlanValue(organization["rate_limit_tier"] as? String)
        if organization["rate_limit_tier"] != nil, tier == nil { return nil }
        let types = ["claude_pro": "pro", "claude_max": "max", "claude_ultra": "ultra", "claude_team": "team", "claude_enterprise": "enterprise"]
        if boolean(account["has_claude_max"]) == true, boolean(account["has_claude_pro"]) == true { return nil }
        let type: String?
        if let rawType {
            guard let known = types[rawType] else { return nil }
            type = known
        } else {
            let maxPlan = boolean(account["has_claude_max"]) == true
            let proPlan = boolean(account["has_claude_pro"]) == true
            guard maxPlan != proPlan else { return nil }
            type = maxPlan ? "max" : "pro"
        }
        // Personal Pro/Max flags conflict; organization capacity tiers do not rename Team or Enterprise.
        if tier?.contains("max") == true, type == "pro" { return nil }
        if ["max", "ultra"].contains(type), tier == "default_claude_pro" { return nil }
        if let maxFlag = boolean(account["has_claude_max"]), ["max", "ultra"].contains(type), !maxFlag { return nil }
        if let proFlag = boolean(account["has_claude_pro"]), type == "pro", !proFlag { return nil }
        if type == "pro", boolean(account["has_claude_max"]) == true { return nil }
        if ["max", "ultra"].contains(type), boolean(account["has_claude_pro"]) == true { return nil }
        return ClaudeUsageParser.planDescriptor(subscriptionType: type, rateLimitTier: ["max", "ultra"].contains(type) ? tier : nil)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

private final class ClaudeProfileRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
