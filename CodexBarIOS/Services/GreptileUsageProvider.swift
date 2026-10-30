import Foundation

public final class GreptileUsageProvider: UsageProvider {
    struct ReviewQuota: Equatable {
        let reviewsUsed: Double
        let reviewAllowance: Double
        let periodStart: Date?
        let resetsAt: Date?
        let plan: String?
    }

    struct ReviewPage: Equatable {
        struct Review: Equatable {
            let id: String
            let status: String
        }

        let reviews: [Review]
        let total: Int?
        let quota: ReviewQuota?
        let isTruncated: Bool
    }

    private enum PageResponse {
        case page(ReviewPage)
        case authenticationFailure
        case permissionFailure
        case rateLimited
        case serverFailure
        case malformed
    }

    private struct StatusCounts {
        var completed = 0
        var pending = 0
        var inProgress = 0
        var failed = 0
        var skipped = 0
        var other = 0

        mutating func record(_ rawStatus: String) {
            switch rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
            case "COMPLETED":
                completed += 1
            case "PENDING":
                pending += 1
            case "REVIEWING_FILES", "GENERATING_SUMMARY", "IN_PROGRESS", "IN-PROGRESS":
                inProgress += 1
            case "FAILED":
                failed += 1
            case "SKIPPED":
                skipped += 1
            default:
                other += 1
            }
        }
    }

    private let secretStore: SecretStore
    private let session: URLSession
    private let endpoint: URL
    private let dashboardBaseURL: URL
    private let pageSize: Int
    private let maximumPageCount: Int

    private static let maximumReviewOffset = 1_000

    public let providerID = ProviderID.greptile

    public init(
        secretStore: SecretStore = KeychainService(),
        session: URLSession? = nil,
        endpoint: URL = URL(string: "https://api.greptile.com/mcp")!,
        dashboardBaseURL: URL = URL(string: "https://app.greptile.com")!,
        pageSize: Int = 100,
        maximumPageCount: Int = 100
    ) {
        self.secretStore = secretStore
        self.session = session ?? GreptileDashboardClient.isolatedSession()
        self.endpoint = endpoint
        self.dashboardBaseURL = dashboardBaseURL
        self.pageSize = min(max(pageSize, 1), 100)
        self.maximumPageCount = max(maximumPageCount, 1)
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        let storedSecret: String?
        do {
            storedSecret = try secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: configuration)
            )
        } catch {
            try Self.rethrowCancellation(error)
            return failureResult(
                "Greptile credential could not be read from Keychain.",
                configuration: configuration
            )
        }

        if configuration.authMethod == .browserSession || GreptileSessionCredentials.parse(storedSecret) != nil {
            guard let credential = GreptileSessionCredentials.parse(storedSecret) else {
                return failureResult(
                    "Sign in to Greptile to read your allowance renewal date.",
                    configuration: configuration, recoveryAction: .signIn
                )
            }
            return try await fetchBrowserUsage(credential: credential, configuration: configuration)
        }

        guard
            let apiKey = Self.normalizedAPIKey(from: storedSecret),
            !apiKey.isEmpty
        else {
            return failureResult(
                "Not configured - enter a Greptile organization API key.",
                configuration: configuration,
                recoveryAction: .signIn
            )
        }

        var result = try await fetchReviewActivity(apiKey: apiKey, configuration: configuration)
        result.greptileAllowanceRenewal = GreptileAllowanceRenewal(
            renewsAt: nil, observedAt: result.fetchedAt,
            unavailableReason: "Sign in to Greptile in account settings to read your allowance renewal date.",
            isApplicable: nil, requiresNewAccount: true
        )
        return result
    }

    private static func rethrowCancellation(_ error: Error) throws {
        if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
            throw CancellationError()
        }
    }

    private func fetchBrowserUsage(
        credential: GreptileSessionCredentials,
        configuration: ProviderAccountConfiguration
    ) async throws -> ProviderUsageResult {
        let client = GreptileDashboardClient(session: session, baseURL: dashboardBaseURL)
        let identity: GreptileDashboardIdentity
        do {
            identity = try await client.verifiedIdentity(for: credential)
        } catch {
            try Self.rethrowCancellation(error)
            let failure = error as? GreptileSignInError ?? .unavailable
            let cacheIdentity: String
            if case .wrongAccount = failure {
                cacheIdentity = "unverified-greptile-session"
            } else {
                cacheIdentity = credential.cacheIdentity
            }
            var result = failureResult(
                failure.localizedDescription, configuration: configuration,
                recoveryAction: failure.requiresAuthentication ? .reauthenticate : .retryRefresh, cacheIdentity: cacheIdentity
            )
            result.greptileAllowanceRenewal = GreptileAllowanceRenewal(
                renewsAt: nil, observedAt: result.fetchedAt, unavailableReason: failure.localizedDescription,
                requiresAuthentication: failure.requiresAuthentication, lookupFailed: true, isApplicable: nil
            )
            return result
        }
        let renewal: GreptileAllowanceRenewal
        var allowance: GreptileCreditAllowance?
        do {
            let state = try await client.billingState(for: credential)
            allowance = state.creditAllowance
            renewal = GreptileAllowanceRenewal(renewsAt: state.renewalDate, observedAt: Date(), isApplicable: state.isFreeAllowance)
        } catch {
            try Self.rethrowCancellation(error)
            renewal = GreptileAllowanceRenewal(
                renewsAt: nil, observedAt: Date(),
                unavailableReason: (error as? GreptileSignInError ?? .unavailable).localizedDescription,
                requiresAuthentication: (error as? GreptileSignInError)?.requiresAuthentication == true,
                lookupFailed: (error as? GreptileSignInError) != .invalidBillingResponse, isApplicable: nil
            )
        }
        let activity = try await fetchReviewActivity(
            apiKey: identity.greptileToken, organization: credential.organization.id, configuration: configuration
        )
        return browserResult(activity: activity, allowance: allowance, renewal: renewal, cacheIdentity: credential.cacheIdentity)
    }

    private func browserResult(
        activity: ProviderUsageResult, allowance: GreptileCreditAllowance?, renewal: GreptileAllowanceRenewal, cacheIdentity: String
    ) -> ProviderUsageResult {
        let bar = allowance?.usageBar(at: activity.fetchedAt)
        let unavailable = renewal.isApplicable == false || bar != nil ? [:] : [
            GreptileUsageIdentity.creditAllowanceMetricID: "Credit usage unavailable",
        ]
        let creditInformation = bar.flatMap { _ in allowance }.map { allowance in
            ProviderCardInformationSection(id: "greptile.credit-allowance", title: "Free credit allowance", items: [
                ProviderCardInformationItem(id: "credits.used", label: "Credits used", detail: allowance.used.formatted()),
                ProviderCardInformationItem(id: "credits.included", label: "Included credits", detail: allowance.included.formatted()),
                ProviderCardInformationItem(id: "credits.remaining", label: "Credits remaining", detail: allowance.remaining.formatted()),
            ])
        }
        return ProviderUsageResult(
            accountID: activity.accountID, providerID: .greptile, title: activity.title, plan: activity.plan, subtitle: activity.subtitle,
            bars: (bar.map { [$0] } ?? []) + activity.bars,
            unavailableUsageMetrics: unavailable, usageMessages: activity.usageMessages,
            cardInformationSections: (creditInformation.map { [$0] } ?? []) + activity.cardInformationSections,
            greptileAllowanceRenewal: renewal,
            greptileReviewActivityUnavailableReason: bar == nil ? nil : activity.failureMessage,
            failureMessage: activity.failureMessage, recoveryAction: activity.recoveryAction,
            preserveCachedBarsOnFailure: activity.preserveCachedBarsOnFailure, cacheIdentity: cacheIdentity,
            fetchedAt: activity.fetchedAt
        )
    }

    private func fetchReviewActivity(
        apiKey: String,
        organization: String? = nil,
        configuration: ProviderAccountConfiguration
    ) async throws -> ProviderUsageResult {
        var offset = 0
        var pageCount = 0
        var expectedTotal: Int?
        var quota: ReviewQuota?
        var seenReviewIDs = Set<String>()
        var counts = StatusCounts()

        while pageCount < pageLimit(expectedTotal: expectedTotal) {
            let request = makeReviewsRequest(apiKey: apiKey, offset: offset, organization: organization)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                try Self.rethrowCancellation(error)
                return failureResult(
                    "Could not reach Greptile. Check the connection and try again.",
                    configuration: configuration
                )
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                return failureResult(
                    "Greptile returned an invalid network response.",
                    configuration: configuration
                )
            }

            if let httpFailure = httpFailureResult(
                response: httpResponse,
                configuration: configuration
            ) {
                return httpFailure
            }

            switch Self.parseReviewPage(data) {
            case .page(let page):
                guard !page.isTruncated else {
                    return incompletePaginationFailure(configuration: configuration)
                }
                pageCount += 1
                expectedTotal = Self.updatedExpectedTotal(expectedTotal, pageTotal: page.total)
                quota = quota ?? page.quota

                for review in page.reviews {
                    guard seenReviewIDs.insert(review.id).inserted else {
                        continue
                    }
                    counts.record(review.status)
                }

                let nextOffset = offset + page.reviews.count
                if let expectedTotal, nextOffset >= expectedTotal {
                    return completedPaginationResult(
                        expectedTotal: expectedTotal,
                        uniqueReviewCount: seenReviewIDs.count,
                        counts: counts,
                        quota: quota,
                        configuration: configuration
                    )
                }
                // Empty pages are short pages too. A known total reached by
                // this offset has already taken the complete-scan path above.
                if page.reviews.count < pageSize {
                    if expectedTotal == nil {
                        return successResult(
                            counts: counts,
                            quota: quota,
                            configuration: configuration
                        )
                    }
                    return incompletePaginationFailure(configuration: configuration)
                }
                offset = nextOffset
            case .authenticationFailure:
                return failureResult(
                    "Greptile rejected this organization API key.",
                    configuration: configuration,
                    recoveryAction: .reauthenticate
                )
            case .permissionFailure:
                return failureResult(
                    "This Greptile API key lacks permission to read organization review activity.",
                    configuration: configuration,
                    recoveryAction: .reauthenticate
                )
            case .rateLimited:
                return failureResult(
                    "Greptile rate limit reached. Wait before refreshing again.",
                    configuration: configuration
                )
            case .serverFailure:
                return failureResult(
                    "Greptile could not complete the read-only review request. Try again later.",
                    configuration: configuration
                )
            case .malformed:
                return failureResult(
                    "Could not parse Greptile review activity.",
                    configuration: configuration
                )
            }
        }

        return incompletePaginationFailure(configuration: configuration)
    }

    func makeReviewsRequest(apiKey: String, offset: Int, organization: String? = nil) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("CodexBarIOS/1.0", forHTTPHeaderField: "User-Agent")
        var arguments: [String: Any] = ["limit": pageSize, "offset": offset]
        if let organization { arguments["organization"] = organization }
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": "codexbar.greptile.reviews.\(offset)",
            "method": "tools/call",
            "params": [
                "name": "list_code_reviews",
                "arguments": arguments,
            ],
        ])
        return request
    }

    static func normalizedAPIKey(from storedSecret: String?) -> String? {
        ProviderSecretNormalizer.normalizedSecret(from: storedSecret)
    }

    private static func parseReviewPage(_ data: Data) -> PageResponse {
        for root in responseObjects(in: data) {
            let response = parseReviewPage(root)
            if case .malformed = response {
                continue
            }
            return response
        }
        return .malformed
    }

    private static func parseReviewPage(_ root: [String: Any]) -> PageResponse {

        if let error = root["error"] as? [String: Any] {
            return pageResponse(for: error)
        }

        guard
            let payload = reviewPayload(in: root),
            let rawReviews = payload["codeReviews"] as? [[String: Any]]
        else {
            return .malformed
        }

        var reviews: [ReviewPage.Review] = []
        for review in rawReviews {
            guard
                let id = stringValue(review["id"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                !id.isEmpty
            else {
                return .malformed
            }
            reviews.append(
                ReviewPage.Review(
                    id: id,
                    status: stringValue(review["status"]) ?? "UNKNOWN"
                )
            )
        }
        let total = integerValue(payload["total"])
        guard total.map({ $0 >= 0 }) != false else {
            return .malformed
        }
        let isTruncated: Bool
        if payload.keys.contains("truncated") {
            guard let truncated = booleanValue(payload["truncated"]) else {
                return .malformed
            }
            isTruncated = truncated
        } else {
            isTruncated = false
        }
        return .page(
            ReviewPage(
                reviews: reviews,
                total: total,
                quota: reviewQuota(in: payload),
                isTruncated: isTruncated
            )
        )
    }

    private static func responseObjects(in data: Data) -> [[String: Any]] {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return [object]
        }

        guard let eventStream = String(data: data, encoding: .utf8) else {
            return []
        }

        var objects: [[String: Any]] = []
        var dataLines: [String] = []

        func appendEvent() {
            guard !dataLines.isEmpty else {
                return
            }
            defer { dataLines.removeAll(keepingCapacity: true) }
            let payload = dataLines.joined(separator: "\n")
            guard
                payload != "[DONE]",
                let payloadData = payload.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
            else {
                return
            }
            objects.append(object)
        }

        for rawLine in eventStream.components(separatedBy: .newlines) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty {
                appendEvent()
            } else if line.hasPrefix("data:") {
                dataLines.append(
                    String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                )
            }
        }
        appendEvent()
        return objects
    }

    private static func reviewPayload(in root: [String: Any]) -> [String: Any]? {
        if root["codeReviews"] is [[String: Any]] {
            return root
        }

        guard let result = root["result"] as? [String: Any] else {
            return nil
        }
        if result["codeReviews"] is [[String: Any]] {
            return result
        }
        if
            let structured = result["structuredContent"] as? [String: Any],
            structured["codeReviews"] is [[String: Any]] {
            return structured
        }

        guard let content = result["content"] as? [[String: Any]] else {
            return nil
        }
        for item in content {
            guard
                stringValue(item["type"]) == "text",
                let text = stringValue(item["text"]),
                let textData = text.data(using: .utf8),
                let payload = try? JSONSerialization.jsonObject(with: textData) as? [String: Any],
                payload["codeReviews"] is [[String: Any]]
            else {
                continue
            }
            return payload
        }
        return nil
    }

    private static func pageResponse(for error: [String: Any]) -> PageResponse {
        let message = stringValue(error["message"])?.lowercased() ?? ""
        if message.contains("auth") || message.contains("api key") || message.contains("unauthorized") {
            return .authenticationFailure
        }
        if message.contains("permission") || message.contains("forbidden") || message.contains("organization") {
            return .permissionFailure
        }
        if message.contains("rate") || message.contains("too many") {
            return .rateLimited
        }
        return .serverFailure
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private static func integerValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            number.intValue
        case let string as String:
            Int(string)
        default:
            nil
        }
    }

    private static func booleanValue(_ value: Any?) -> Bool? {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) == CFBooleanGetTypeID()
        else {
            return nil
        }
        return number.boolValue
    }

    private static func updatedExpectedTotal(_ current: Int?, pageTotal: Int?) -> Int? {
        guard let pageTotal else {
            return current
        }
        return max(current ?? 0, pageTotal)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            guard
                CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.doubleValue.isFinite
            else {
                return nil
            }
            return number.doubleValue
        case let string as String:
            guard let parsed = Double(string), parsed.isFinite else {
                return nil
            }
            return parsed
        default:
            return nil
        }
    }

    private static func reviewQuota(in payload: [String: Any]) -> ReviewQuota? {
        // Billing fields are not part of Greptile's published MCP response schema. Only accept
        // explicit used-and-allowance pairs so unrelated response metadata cannot become a gauge.
        let containers = [
            payload["reviewUsage"],
            payload["billingUsage"],
            payload["usage"],
            payload["quota"],
        ].compactMap { $0 as? [String: Any] }

        for container in containers {
            let values = normalizedValues(in: container)
            guard
                let reviewsUsed = firstDouble(
                    in: values,
                    keys: ["reviewsused", "usedreviews", "completedreviewsused"]
                ),
                let reviewAllowance = firstDouble(
                    in: values,
                    keys: ["includedreviews", "reviewallowance", "reviewlimit", "reviewslimit"]
                ),
                reviewsUsed >= 0,
                reviewAllowance > 0
            else {
                continue
            }

            return ReviewQuota(
                reviewsUsed: reviewsUsed,
                reviewAllowance: reviewAllowance,
                periodStart: firstDate(
                    in: values,
                    keys: ["billingperiodstart", "periodstart"]
                ),
                resetsAt: firstDate(
                    in: values,
                    keys: ["billingperiodend", "periodend", "resetat", "resetsat"]
                ),
                plan: firstString(in: values, keys: ["plan", "planname", "tier"])
            )
        }

        return nil
    }

    private static func normalizedValues(in dictionary: [String: Any]) -> [String: Any] {
        dictionary.reduce(into: [:]) { values, entry in
            let normalizedKey = entry.key.lowercased().filter(\.isLetter)
            guard !normalizedKey.isEmpty else {
                return
            }
            if values[normalizedKey] == nil {
                values[normalizedKey] = entry.value
            }
        }
    }

    private static func firstDouble(in values: [String: Any], keys: [String]) -> Double? {
        keys.lazy.compactMap { doubleValue(values[$0]) }.first
    }

    private static func firstString(in values: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { key in
            stringValue(values[key])?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.first(where: { !$0.isEmpty })
    }

    private static func firstDate(in values: [String: Any], keys: [String]) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standardFormatter = ISO8601DateFormatter()

        return keys.lazy.compactMap { key in
            if let timestamp = doubleValue(values[key]) {
                guard timestamp > 0 else {
                    return nil
                }
                let seconds = abs(timestamp) >= 100_000_000_000 ? timestamp / 1_000 : timestamp
                return Date(timeIntervalSince1970: seconds)
            }
            guard let value = stringValue(values[key]) else {
                return nil
            }
            return fractionalFormatter.date(from: value) ?? standardFormatter.date(from: value)
        }.first
    }

    private static func rateLimitMessage(response: HTTPURLResponse) -> String {
        guard
            let rawValue = response.value(forHTTPHeaderField: "Retry-After"),
            let seconds = Int(rawValue),
            seconds > 0
        else {
            return "Greptile rate limit reached. Wait before refreshing again."
        }
        return "Greptile rate limit reached. Try again in about \(seconds) seconds."
    }

    private func httpFailureResult(
        response: HTTPURLResponse,
        configuration: ProviderAccountConfiguration
    ) -> ProviderUsageResult? {
        switch response.statusCode {
        case 200..<300:
            nil
        case 401:
            failureResult(
                "Greptile rejected this organization API key.",
                configuration: configuration,
                recoveryAction: .reauthenticate
            )
        case 403:
            failureResult(
                "This Greptile API key lacks permission to read organization review activity.",
                configuration: configuration,
                recoveryAction: .reauthenticate
            )
        case 429:
            failureResult(
                Self.rateLimitMessage(response: response),
                configuration: configuration
            )
        case 500..<600:
            failureResult(
                "Greptile is temporarily unavailable (HTTP \(response.statusCode)). Try again later.",
                configuration: configuration
            )
        default:
            failureResult(
                "Greptile review activity returned HTTP \(response.statusCode).",
                configuration: configuration
            )
        }
    }

    private func successResult(
        counts: StatusCounts,
        quota: ReviewQuota?,
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date = Date()
    ) -> ProviderUsageResult {
        let statusItems = [
            ("completed", "Completed", counts.completed),
            ("pending", "Pending", counts.pending),
            ("in-progress", "In progress", counts.inProgress),
            ("failed", "Failed", counts.failed),
            ("skipped", "Skipped", counts.skipped),
            ("other", "Other statuses", counts.other),
        ].compactMap { identifier, label, count -> ProviderCardInformationItem? in
            guard count > 0 || identifier == "completed" else {
                return nil
            }
            return ProviderCardInformationItem(
                id: "greptile.status.\(identifier)",
                label: label,
                detail: count.formatted()
            )
        }

        let bar = quota.map { quota in
            UsageBar(
                stableKey: GreptileUsageIdentity.reviewQuotaStableKey,
                label: "Reviews used",
                used: quota.reviewsUsed,
                limit: quota.reviewAllowance,
                resetsAt: quota.resetsAt,
                projectionCurrent: quota.reviewsUsed,
                projectionLimit: quota.reviewAllowance,
                projectionPeriodStart: quota.periodStart,
                projectionPeriodEnd: quota.resetsAt,
                showProjectionOnCurrentBar: quota.periodStart != nil && quota.resetsAt != nil
            )
        } ?? (counts.completed > 0
            ? UsageBar(
                stableKey: GreptileUsageIdentity.completedReviewsStableKey,
                label: "Completed reviews",
                used: Double(counts.completed),
                limit: 0,
                fractionlessUsageText: counts.completed.formatted()
            )
            : nil)

        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: .greptile,
            title: configuration.displayName,
            plan: quota?.plan.flatMap(Self.planDescriptor),
            subtitle: "",
            bars: bar.map { [$0] } ?? [],
            usageMessages: [],
            cardInformationSections: [
                ProviderCardInformationSection(
                    id: "greptile.review-statuses",
                    title: "Review statuses",
                    items: statusItems
                ),
            ],
            fetchedAt: fetchedAt
        )
    }

    private func incompletePaginationFailure(
        configuration: ProviderAccountConfiguration
    ) -> ProviderUsageResult {
        failureResult(
            "Greptile returned incomplete paginated review activity. Try again later.",
            configuration: configuration
        )
    }

    private func completedPaginationResult(
        expectedTotal: Int,
        uniqueReviewCount: Int,
        counts: StatusCounts,
        quota: ReviewQuota?,
        configuration: ProviderAccountConfiguration
    ) -> ProviderUsageResult {
        guard uniqueReviewCount >= expectedTotal else {
            return incompletePaginationFailure(configuration: configuration)
        }
        return successResult(
            counts: counts,
            quota: quota,
            configuration: configuration
        )
    }

    private static func planDescriptor(_ plan: String) -> ProviderPlanDescriptor? {
        let trimmed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let identifier = trimmed.lowercased().map { character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return ProviderPlanDescriptor.make(
            providerPrefix: "greptile",
            identifier: String(identifier),
            label: trimmed
        )
    }

    private func pageLimit(expectedTotal: Int?) -> Int {
        let offsetPageLimit = Self.maximumReviewOffset / pageSize + 1
        guard let expectedTotal else {
            return min(maximumPageCount, offsetPageLimit)
        }
        let completePageCount = expectedTotal / pageSize
        let requiredPageCount = completePageCount + (expectedTotal.isMultiple(of: pageSize) ? 0 : 1)
        return min(maximumPageCount, offsetPageLimit, requiredPageCount)
    }

    private func failureResult(
        _ message: String,
        configuration: ProviderAccountConfiguration,
        recoveryAction: ProviderUsageRecoveryAction = .retryRefresh,
        cacheIdentity: String? = nil
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .greptile,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            failureMessage: message,
            recoveryAction: recoveryAction,
            cacheIdentity: cacheIdentity,
            fetchedAt: Date()
        )
    }
}
