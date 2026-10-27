import Foundation

struct FeedbackSupportContext: Equatable, Sendable {
    let appVersion: String
    let buildNumber: String
    let operatingSystemName: String
    let operatingSystemVersion: String
    let deviceCategory: String

    var systemDetails: String {
        PrivacySafeDiagnosticBuilder.systemDetails(self)
    }
}

enum DiagnosticSurface: String, CaseIterable, Equatable, Sendable {
    case providerSetup
    case dashboard
    case history
    case alerts
    case widget
    case appleWatch
    case authentication
    case settings
    case other

    var displayName: String {
        switch self {
        case .providerSetup:
            "Provider or account setup"
        case .dashboard:
            "Dashboard"
        case .history:
            "History"
        case .alerts:
            "Alerts"
        case .widget:
            "Widget"
        case .appleWatch:
            "Apple Watch"
        case .authentication:
            "Authentication"
        case .settings:
            "Settings"
        case .other:
            "Other"
        }
    }
}

enum DiagnosticAuthenticationMethod: String, Equatable, Sendable {
    case apiKey
    case browserSession
    case cliToken

    init(_ method: ProviderAuthMethod) {
        switch method {
        case .apiKey:
            self = .apiKey
        case .browserSession:
            self = .browserSession
        case .cliToken:
            self = .cliToken
        }
    }

    var displayName: String {
        switch self {
        case .apiKey:
            "API key"
        case .browserSession:
            "Browser session"
        case .cliToken:
            "CLI token"
        }
    }
}

enum DiagnosticFailureCategory: String, CaseIterable, Equatable, Sendable {
    case authentication
    case authorization
    case connectivity
    case timeout
    case rateLimited
    case clientRequest
    case server
    case invalidResponse
    case localStorage
    case unavailable
    case cancelled
    case unknown

    var displayName: String {
        switch self {
        case .authentication:
            "Authentication"
        case .authorization:
            "Authorization"
        case .connectivity:
            "Connectivity"
        case .timeout:
            "Timeout"
        case .rateLimited:
            "Rate limited"
        case .clientRequest:
            "Client request"
        case .server:
            "Provider server"
        case .invalidResponse:
            "Invalid response"
        case .localStorage:
            "Local storage"
        case .unavailable:
            "Temporarily unavailable"
        case .cancelled:
            "Cancelled"
        case .unknown:
            "Unknown"
        }
    }

    static func normalized(error: Error, httpStatusCode: Int? = nil) -> Self {
        if let httpStatusCode {
            return normalized(httpStatusCode: httpStatusCode)
        }
        if error is DecodingError {
            return .invalidResponse
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timeout
            case .cancelled:
                return .cancelled
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed:
                return .connectivity
            default:
                return .unavailable
            }
        }
        return .unknown
    }

    static func normalized(httpStatusCode: Int) -> Self {
        switch httpStatusCode {
        case 401:
            .authentication
        case 403:
            .authorization
        case 408:
            .timeout
        case 429:
            .rateLimited
        case 400..<500:
            .clientRequest
        case 500..<600:
            .server
        default:
            .unknown
        }
    }

    /// Maps existing presentation text to a fixed category. The input is never retained or emitted.
    static func normalized(userVisibleMessage: String) -> Self {
        let value = userVisibleMessage.lowercased()
        if value.contains("timed out") || value.contains("timeout") {
            return .timeout
        }
        if value.contains("rate limit") || value.contains("too many requests") {
            return .rateLimited
        }
        if value.contains("sign in") || value.contains("credential") || value.contains("token") {
            return .authentication
        }
        if value.contains("permission") || value.contains("forbidden") {
            return .authorization
        }
        if value.contains("offline") || value.contains("network") || value.contains("connect") {
            return .connectivity
        }
        if value.contains("decode") || value.contains("parse") || value.contains("invalid response") {
            return .invalidResponse
        }
        if value.contains("keychain") || value.contains("save") || value.contains("storage") {
            return .localStorage
        }
        if value.contains("unavailable") {
            return .unavailable
        }
        return .unknown
    }

    static func safeHTTPStatusCode(userVisibleMessage: String) -> Int? {
        guard let range = userVisibleMessage.range(
            of: "HTTP ",
            options: [.caseInsensitive, .literal]
        ) else {
            return nil
        }
        let suffix = userVisibleMessage[range.upperBound...]
        let digits = suffix.prefix(3)
        guard
            digits.count == 3,
            digits.allSatisfy(\.isNumber),
            suffix.dropFirst(3).first?.isNumber != true,
            let code = Int(digits),
            (100...599).contains(code)
        else {
            return nil
        }
        return code
    }
}

enum DiagnosticRefreshKind: String, Equatable, Sendable {
    case manual
    case automatic
    case unknown

    var displayName: String {
        switch self {
        case .manual:
            "Manual"
        case .automatic:
            "Automatic"
        case .unknown:
            "Unknown"
        }
    }
}

enum DiagnosticFreshness: String, Equatable, Sendable {
    case current
    case stale
    case noSuccessfulRefresh
    case unknown

    var displayName: String {
        switch self {
        case .current:
            "Current"
        case .stale:
            "Stale"
        case .noSuccessfulRefresh:
            "No successful refresh"
        case .unknown:
            "Unknown"
        }
    }
}

enum DiagnosticWidgetState: String, Equatable, Sendable {
    case current
    case stale
    case noData
    case unknown

    var displayName: String {
        switch self {
        case .current:
            "Current"
        case .stale:
            "Stale"
        case .noData:
            "No data"
        case .unknown:
            "Unknown"
        }
    }
}

enum DiagnosticWatchState: String, Equatable, Sendable {
    case connected
    case phoneUnavailable
    case stale
    case noData
    case unknown

    var displayName: String {
        switch self {
        case .connected:
            "Connected"
        case .phoneUnavailable:
            "iPhone unavailable"
        case .stale:
            "Stale"
        case .noData:
            "No data"
        case .unknown:
            "Unknown"
        }
    }
}

struct DiagnosticTechnicalDetails: Equatable, Sendable {
    let authenticationMethod: DiagnosticAuthenticationMethod?
    let isConfigured: Bool?
    let isSecretPresent: Bool?
    let failureCategory: DiagnosticFailureCategory?
    let httpStatusCode: Int?
    let refreshKind: DiagnosticRefreshKind?
    let freshness: DiagnosticFreshness?
    let widgetState: DiagnosticWidgetState?
    let watchState: DiagnosticWatchState?

    init(
        authenticationMethod: DiagnosticAuthenticationMethod? = nil,
        isConfigured: Bool? = nil,
        isSecretPresent: Bool? = nil,
        failureCategory: DiagnosticFailureCategory? = nil,
        httpStatusCode: Int? = nil,
        refreshKind: DiagnosticRefreshKind? = nil,
        freshness: DiagnosticFreshness? = nil,
        widgetState: DiagnosticWidgetState? = nil,
        watchState: DiagnosticWatchState? = nil
    ) {
        self.authenticationMethod = authenticationMethod
        self.isConfigured = isConfigured
        self.isSecretPresent = isSecretPresent
        self.failureCategory = failureCategory
        self.httpStatusCode = httpStatusCode.flatMap { (100...599).contains($0) ? $0 : nil }
        self.refreshKind = refreshKind
        self.freshness = freshness
        self.widgetState = widgetState
        self.watchState = watchState
    }

    static func providerRefreshFailure(
        configuration: ProviderAccountConfiguration,
        isConfigured: Bool,
        isSecretPresent: Bool,
        userVisibleMessage: String,
        result: ProviderUsageResult?
    ) -> Self {
        let statusCode = DiagnosticFailureCategory.safeHTTPStatusCode(
            userVisibleMessage: userVisibleMessage
        )
        let failureCategory = statusCode.map(DiagnosticFailureCategory.normalized)
            ?? DiagnosticFailureCategory.normalized(userVisibleMessage: userVisibleMessage)
        return Self(
            authenticationMethod: DiagnosticAuthenticationMethod(configuration.authMethod),
            isConfigured: isConfigured,
            isSecretPresent: isSecretPresent,
            failureCategory: failureCategory,
            httpStatusCode: statusCode,
            refreshKind: .unknown,
            freshness: result?.diagnosticFailureFreshness ?? .noSuccessfulRefresh
        )
    }
}

private extension ProviderUsageResult {
    var diagnosticFailureFreshness: DiagnosticFreshness {
        if (!bars.isEmpty && hasCurrentBars)
            || (creditsRemaining != nil && hasCurrentCredits) {
            return .current
        }
        if hasSuccessfulRefreshHistory
            || !bars.isEmpty
            || creditsRemaining != nil
            || !monetaryMetrics.isEmpty
            || codexBankedRateLimitResets != nil {
            return .stale
        }
        return .noSuccessfulRefresh
    }
}

struct PrivacySafeDiagnosticContext: Equatable, Identifiable, Sendable {
    let system: FeedbackSupportContext
    let surface: DiagnosticSurface
    let providerID: ProviderID?
    let technicalDetails: DiagnosticTechnicalDetails?

    var id: String {
        "\(surface.rawValue)-\(providerID?.rawValue ?? "none")"
    }
}

extension ProviderID {
    var problemReportFormValue: String {
        switch self {
        case .codex:
            "ChatGPT / Codex"
        case .copilot:
            "GitHub Copilot"
        case .githubBilling:
            "GitHub Billing"
        case .claude:
            "Claude"
        case .grok:
            "Grok"
        case .xSubscription:
            "X Subscription"
        case .openRouter:
            "OpenRouter"
        case .openCodeZen:
            "OpenCode Go / Zen"
        case .moonshot:
            "Moonshot (Kimi)"
        case .cursor:
            "Cursor"
        case .greptile:
            "Greptile"
        case .gemini:
            "Google Gemini"
        case .antigravity:
            "Antigravity"
        case .museCode:
            "Muse Code"
        }
    }
}

enum PrivacySafeDiagnosticBuilder {
    static func systemDetails(_ context: FeedbackSupportContext) -> String {
        "CodexBar \(safeSystemValue(context.appVersion)) (\(safeSystemValue(context.buildNumber))), \(safeSystemValue(context.operatingSystemName)) \(safeSystemValue(context.operatingSystemVersion)), \(safeSystemValue(context.deviceCategory))"
    }

    static func summary(
        context: PrivacySafeDiagnosticContext,
        includeTechnicalDetails: Bool = true
    ) -> String {
        var lines = [
            "CodexBar privacy-safe diagnostic",
            "App: \(safeSystemValue(context.system.appVersion)) (\(safeSystemValue(context.system.buildNumber)))",
            "Operating system: \(safeSystemValue(context.system.operatingSystemName)) \(safeSystemValue(context.system.operatingSystemVersion))",
            "Device: \(safeSystemValue(context.system.deviceCategory))",
            "Affected surface: \(context.surface.displayName)",
            "Provider: \(context.providerID?.displayName ?? "Not provider-specific")",
        ]

        if includeTechnicalDetails, let details = context.technicalDetails {
            lines.append("Technical details:")
            append(details.authenticationMethod?.displayName, label: "Authentication method", to: &lines)
            append(details.isConfigured.map(yesNo), label: "Configured", to: &lines)
            append(details.isSecretPresent.map(yesNo), label: "Secret present", to: &lines)
            append(details.failureCategory?.displayName, label: "Failure category", to: &lines)
            append(details.httpStatusCode.map(String.init), label: "HTTP status", to: &lines)
            append(details.refreshKind?.displayName, label: "Refresh", to: &lines)
            append(details.freshness?.displayName, label: "Freshness", to: &lines)
            append(details.widgetState?.displayName, label: "Widget state", to: &lines)
            append(details.watchState?.displayName, label: "Apple Watch state", to: &lines)
        }
        return lines.joined(separator: "\n")
    }

    private static func safeSystemValue(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: ".,()+-_"))
        let scalars = value.unicodeScalars.filter { allowed.contains($0) }
        let normalized = String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(normalized.prefix(80))
    }

    private static func append(_ value: String?, label: String, to lines: inout [String]) {
        guard let value else { return }
        lines.append("- \(label): \(value)")
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }
}

enum ProblemReportLaunch: Equatable, Sendable {
    case url(URL)
    case copyOnly(String)
}

enum FeedbackEmailKind: CaseIterable, Equatable, Sendable {
    case problemReport
    case improvementSuggestion

    var subject: String {
        switch self {
        case .problemReport:
            "[CodexBar Feedback] Problem Report"
        case .improvementSuggestion:
            "[CodexBar Feedback] Improvement Suggestion"
        }
    }
}

struct FeedbackEmailDraft: Equatable, Identifiable, Sendable {
    static let recipient = "fphemmer@gmail.com"
    static let externalComposerPrivacyNotice =
        "Your mail app may display and use its currently selected sending account. Copy the fields below to avoid opening the mail app."

    let kind: FeedbackEmailKind
    let body: String

    var id: String {
        kind.subject
    }

    var subject: String {
        kind.subject
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = Self.recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url!
    }

    var copyableFields: [FeedbackEmailDraftField] {
        [
            FeedbackEmailDraftField(kind: .recipient, value: Self.recipient),
            FeedbackEmailDraftField(kind: .subject, value: subject),
            FeedbackEmailDraftField(kind: .message, value: body),
        ]
    }

    static func problemReport(
        context: PrivacySafeDiagnosticContext,
        includeTechnicalDetails: Bool
    ) -> Self {
        let diagnostic = PrivacySafeDiagnosticBuilder.summary(
            context: context,
            includeTechnicalDetails: includeTechnicalDetails
        )
        return Self(
            kind: .problemReport,
            body: """
            Please describe the problem below. Review and edit this message before sending; opening the email composer does not send it.

            What happened?


            What did you expect?


            Steps to reproduce:


            Privacy-safe diagnostic:
            \(diagnostic)

            CodexBar does not include credentials, tokens, cookies, account labels, account identifiers, balances, \
            usage history, raw provider responses or errors, widget selections, Apple Watch snapshots, logs, or \
            screenshots.
            """
        )
    }

    static func improvementSuggestion(context: FeedbackSupportContext) -> Self {
        Self(
            kind: .improvementSuggestion,
            body: """
            Please describe your suggestion below. Review and edit this message before sending; opening the email composer does not send it.

            What would you like CodexBar to improve?


            How would this help?


            Anything else we should know?


            Privacy-safe app and device context:
            \(context.systemDetails)

            CodexBar does not include credentials, tokens, cookies, account labels, account identifiers, balances, \
            usage history, raw provider responses or errors, widget selections, Apple Watch snapshots, logs, or \
            screenshots.
            """
        )
    }
}

struct FeedbackEmailDraftField: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case recipient
        case subject
        case message
    }

    let kind: Kind
    let value: String

    var id: Kind {
        kind
    }

    var title: String {
        kind.rawValue.capitalized
    }
}

enum FeedbackSupportPresentation: Equatable, Sendable {
    case diagnosticPreview
    case emailDetails
    case external
}

enum FeedbackSupportDestination: String, CaseIterable, Identifiable, Sendable {
    case reportProblem
    case suggestImprovement
    case publicBugReport
    case publicImprovement
    case knownIssues
    case supportGuide
    case rateCodexBar

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .reportProblem:
            "Report a Problem"
        case .suggestImprovement:
            "Suggest an Improvement"
        case .publicBugReport:
            "Public GitHub Bug Form"
        case .publicImprovement:
            "Public GitHub Improvement Form"
        case .knownIssues:
            "View Known Issues"
        case .supportGuide:
            "Support Guide"
        case .rateCodexBar:
            "Rate CodexBar"
        }
    }

    var detail: String {
        switch self {
        case .reportProblem:
            "Review privacy-safe email details with optional diagnostics."
        case .suggestImprovement:
            "Review or copy a private, structured email message."
        case .publicBugReport:
            "Open the public bug form; a GitHub account is required."
        case .publicImprovement:
            "Open the public feature form; a GitHub account is required."
        case .knownIssues:
            "Search open reports and known limitations."
        case .supportGuide:
            "Read troubleshooting and reporting guidance."
        case .rateCodexBar:
            "Write a review on the App Store."
        }
    }

    var serviceName: String {
        switch self {
        case .reportProblem, .suggestImprovement:
            "Mail"
        case .rateCodexBar:
            "App Store"
        default:
            "GitHub"
        }
    }

    var presentation: FeedbackSupportPresentation {
        switch self {
        case .reportProblem:
            .diagnosticPreview
        case .suggestImprovement:
            .emailDetails
        case .publicBugReport,
             .publicImprovement,
             .knownIssues,
             .supportGuide,
             .rateCodexBar:
            .external
        }
    }

    var systemImage: String {
        switch self {
        case .reportProblem:
            "ladybug"
        case .suggestImprovement:
            "lightbulb"
        case .publicBugReport:
            "ladybug.fill"
        case .publicImprovement:
            "lightbulb.fill"
        case .knownIssues:
            "list.bullet.rectangle"
        case .supportGuide:
            "book.closed"
        case .rateCodexBar:
            "star"
        }
    }

    func url(context: FeedbackSupportContext) -> URL {
        switch self {
        case .reportProblem:
            let diagnosticContext = PrivacySafeDiagnosticContext(
                system: context,
                surface: .other,
                providerID: nil,
                technicalDetails: nil
            )
            return FeedbackEmailDraft.problemReport(
                context: diagnosticContext,
                includeTechnicalDetails: false
            ).url
        case .suggestImprovement:
            return FeedbackEmailDraft.improvementSuggestion(context: context).url
        case .publicBugReport:
            return Self.issueFormURL(
                template: "bug_report.yml",
                systemDetails: context.systemDetails
            )
        case .publicImprovement:
            return Self.issueFormURL(
                template: "feature_request.yml",
                systemDetails: context.systemDetails
            )
        case .knownIssues:
            var components = URLComponents(
                string: "https://github.com/hemsoft-dev/codexbar-ios/issues"
            )!
            components.queryItems = [
                URLQueryItem(name: "q", value: "is:issue is:open"),
            ]
            return components.url!
        case .supportGuide:
            return AppReviewLinks.supportURL
        case .rateCodexBar:
            return AppReviewLinks.writeReviewURL
        }
    }

    static let maximumPrefilledURLLength = 1_800

    static func problemReportLaunch(
        context: PrivacySafeDiagnosticContext,
        includeTechnicalDetails: Bool,
        maximumURLLength: Int = maximumPrefilledURLLength
    ) -> ProblemReportLaunch {
        let summary = PrivacySafeDiagnosticBuilder.summary(
            context: context,
            includeTechnicalDetails: includeTechnicalDetails
        )
        let url = issueFormURL(
            template: "bug_report.yml",
            queryItems: [
                URLQueryItem(name: "system-details", value: context.system.systemDetails),
                URLQueryItem(name: "affected-surface", value: context.surface.displayName),
                URLQueryItem(
                    name: "affected-provider",
                    value: context.providerID?.problemReportFormValue
                        ?? "Not provider-specific"
                ),
                URLQueryItem(name: "privacy-safe-diagnostics", value: summary),
            ]
        )
        guard url.absoluteString.utf8.count <= maximumURLLength else {
            return .copyOnly(summary)
        }
        return .url(url)
    }

    private static func issueFormURL(template: String, systemDetails: String) -> URL {
        issueFormURL(
            template: template,
            queryItems: [URLQueryItem(name: "system-details", value: systemDetails)]
        )
    }

    private static func issueFormURL(
        template: String,
        queryItems: [URLQueryItem]
    ) -> URL {
        var components = URLComponents(
            string: "https://github.com/hemsoft-dev/codexbar-ios/issues/new"
        )!
        components.queryItems = [URLQueryItem(name: "template", value: template)] + queryItems
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}
