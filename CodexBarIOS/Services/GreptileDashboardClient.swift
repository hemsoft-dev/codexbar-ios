import Foundation
import CoreFoundation

struct GreptileDashboardIdentity: Decodable, Sendable {
    let greptileId: String
    let greptileToken: String
    let organizations: [GreptileOrganization]
}

struct GreptileDashboardState: Equatable, Sendable {
    let renewalDate: Date?
    var isFreeAllowance = true
    var creditAllowance: GreptileCreditAllowance?
}

struct GreptileCreditAllowance: Equatable, Sendable {
    let used: Double
    let included: Double
    let periodStart: Date?
    let periodEnd: Date

    var remaining: Double { max(included - used, 0) }

    func usageBar(at now: Date) -> UsageBar? {
        guard periodEnd > now, periodStart.map({ $0 <= now }) ?? true else { return nil }
        return UsageBar(
            stableKey: GreptileUsageIdentity.creditAllowanceStableKey, label: "Credits used", used: used, limit: included,
            resetDescription: "\(used.formatted()) of \(included.formatted()) credits used. \(remaining.formatted()) remaining.",
            resetsAt: periodEnd
        )
    }
}

struct GreptileDashboardClient: Sendable {
    let session: URLSession
    var baseURL = URL(string: "https://app.greptile.com")!

    static func isolatedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: GreptileRedirectBlocker(), delegateQueue: nil)
    }

    func identity(cookies: [GreptileSessionCookie]) async throws -> GreptileDashboardIdentity {
        struct Response: Decodable { let user: GreptileDashboardIdentity? }
        let cookieCredential = GreptileSessionCredentials(
            version: 1, subject: "verification", organization: GreptileOrganization(tenantExternalId: "verification", name: ""),
            cookies: cookies
        )
        let data = try await read(
            url: baseURL.appendingPathComponent("api/auth/session"),
            credential: cookieCredential
        )
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], root["user"] != nil,
              let response = try? JSONDecoder().decode(Response.self, from: data) else { throw GreptileSignInError.invalidIdentityResponse }
        guard let identity = response.user else { throw GreptileSignInError.expired }
        let subject = identity.greptileId.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = identity.greptileToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty, !token.isEmpty,
              identity.organizations.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw GreptileSignInError.invalidIdentityResponse
        }
        return GreptileDashboardIdentity(greptileId: subject, greptileToken: token, organizations: identity.organizations)
    }

    func verifiedIdentity(for credential: GreptileSessionCredentials) async throws -> GreptileDashboardIdentity {
        let identity = try await identity(cookies: credential.cookies)
        guard identity.greptileId == credential.subject,
              identity.organizations.contains(where: { $0.id == credential.organization.id }) else {
            throw GreptileSignInError.wrongAccount
        }
        return identity
    }

    func billingState(for credential: GreptileSessionCredentials, timeout: TimeInterval = 15) async throws -> GreptileDashboardState {
        let input = try JSONSerialization.data(withJSONObject: [
            "0": ["json": ["tenantExternalId": credential.organization.id]],
        ])
        var components = URLComponents(url: baseURL.appendingPathComponent("api/trpc/billing.getState"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "batch", value: "1"),
            URLQueryItem(name: "input", value: String(data: input, encoding: .utf8)),
        ]
        guard let url = components.url else { throw GreptileSignInError.invalidSession }
        return try Self.parseBillingState(try await read(url: url, credential: credential, timeout: timeout))
    }

    func verifyConnection(for credential: GreptileSessionCredentials) async throws {
        _ = try await verifiedIdentity(for: credential)
        do {
            _ = try await billingState(for: credential, timeout: 5)
        } catch let error as GreptileSignInError where error.requiresAuthentication {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            try Task.checkCancellation()
        }
    }

    private func read(url: URL, credential: GreptileSessionCredentials, timeout: TimeInterval = 15) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        request.setValue(try credential.cookieHeader(), forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw GreptileSignInError.unavailable }
        if response.statusCode == 401 { throw GreptileSignInError.expired }
        if response.statusCode == 403 { throw GreptileSignInError.accessDenied }
        guard response.statusCode == 200 else { throw GreptileSignInError.unavailable }
        return data
    }

    static func parseBillingState(_ data: Data) throws -> GreptileDashboardState {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              array.count == 1,
              let result = array[0]["result"] as? [String: Any],
              let data = result["data"] as? [String: Any],
              let state = data["json"] as? [String: Any],
              let kind = state["kind"] as? String else { throw GreptileSignInError.invalidBillingResponse }
        guard try isFreeAllowance(kind: kind) else { return GreptileDashboardState(renewalDate: nil, isFreeAllowance: false) }
        guard let period = state["currentPeriod"] as? [String: Any],
              let end = isoDate(period["end"]) else { return GreptileDashboardState(renewalDate: nil) }
        if period["start"] != nil {
            guard let start = isoDate(period["start"]), start < end else {
                return GreptileDashboardState(renewalDate: nil)
            }
        }
        let allowance: GreptileCreditAllowance?
        if let used = creditCount(state["used"]), let included = creditCount(state["includedCreditsPerPeriod"]), included > 0,
           used / included <= Double(Int.max) / 200 {
            allowance = GreptileCreditAllowance(used: used, included: included, periodStart: isoDate(period["start"]), periodEnd: end)
        } else {
            allowance = nil
        }
        return GreptileDashboardState(renewalDate: end, creditAllowance: allowance)
    }

    private static func creditCount(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let count = number.doubleValue
        return count.isFinite && count >= 0 ? count : nil
    }

    private static func isFreeAllowance(kind: String) throws -> Bool {
        switch kind {
        case "free": true
        case "paid": false
        default: throw GreptileSignInError.invalidBillingResponse
        }
    }

    private static func isoDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

private final class GreptileRedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
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
