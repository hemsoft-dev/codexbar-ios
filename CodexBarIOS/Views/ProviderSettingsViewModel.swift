import Foundation
import SwiftUI

struct ProviderCredentialPresentation: Equatable {
    let sectionTitle: String
    let unsavedPlaceholder: String
    let savedPlaceholder: String
    let saveButtonTitle: String
    let setupMessage: String?
    let setupLinkTitle: String?
    let setupURL: URL?
    let securityMessage: String?
}

enum GrokFixtureStage: String, Identifiable {
    case approval
    case connected
    var id: String { "grok-fixture-approval" }
}

@MainActor
final class ProviderSettingsViewModel: ObservableObject {
    private struct CredentialValidationFeedback {
        let validatingMessage: String
        let disabledMessage: String
        let incompleteMessage: String
        let authenticationFailurePrefix: String
        let transientFailurePrefix: String
        let validatedMessage: String
    }

    enum PersistenceBehavior {
        case immediate
        case debounced
    }

    @Published private(set) var configuration: ProviderAccountConfiguration
    @Published var secret = ""
    @Published var geminiCodingSecret = ""
    @Published private(set) var isSigningInWithGoogleCoding = false
    @Published private(set) var needsGoogleCodingAccountConfirmation = false
    private var pendingGoogleCodingCredential: AntigravityCredentials?
    private let googleCodingSignIn = GoogleCodingSignIn()
    var googleCodingUsageProvider = AntigravityUsageProvider()
    private var googleCodingTask: Task<Void, Never>?
    @Published private(set) var geminiCodingMessage: String?
    @Published private(set) var isSigningInWithCodex = false
    @Published private(set) var isSigningInWithCopilot = false
    @Published private(set) var isSigningInWithGitHubBilling = false
    @Published private(set) var githubBillingAccountOptions: [GitHubBillingAccountOption] = []
    @Published var selectedGitHubBillingAccountID = ""
    @Published private(set) var githubBillingMessage: String?
    @Published private(set) var githubBillingAuthError: String?
    @Published private(set) var isSigningInWithClaude = false
    @Published private(set) var isSigningInWithGrok = false
    @Published private(set) var grokMessage: String?
    @Published var grokFixtureStage: GrokFixtureStage?
    @Published private(set) var isSigningInWithCursor = false
    @Published var subscriptionBillingSession: SubscriptionBillingSignInSession?
    @Published private(set) var subscriptionBillingMessage: String?
    @Published var geminiBrowserSession: GeminiBrowserSignInSession?
    @Published var greptileBrowserSession: GreptileBrowserSignInSession?
    @Published private(set) var isSigningInWithGreptile = false
    private var greptileAttemptID: UUID?
    @Published private(set) var isSigningInWithGemini = false
    var geminiSessionValidator: any GeminiSessionValidating = GeminiSessionValidator()
    @Published private(set) var needsGeminiAccountConfirmation = false
    private var pendingGeminiCredential: String?
    private var geminiAttemptID: UUID?
    private var geminiValidationTask: Task<Void, Never>?
    @Published private(set) var codexAuthError: String?
    @Published private(set) var copilotAuthError: String?
    @Published private(set) var claudeAuthError: String?
    @Published private(set) var claudeAuthDiagnostic: String?
    @Published private(set) var cursorAuthError: String?
    @Published private(set) var credentialError: String?
    @Published private(set) var credentialMessage: String?
    @Published var authURL: PresentedAuthURL?
    @Published private(set) var copilotTotalAllotmentText = ""
    @Published var openCodeBrowserSession: OpenCodeBrowserSignInSession?
    @Published private(set) var isSigningInWithOpenCode = false
    var openCodeSessionValidator: any OpenCodeSessionValidating = OpenCodeSessionValidator()
    private var openCodeAttemptID: UUID?
    private var openCodeValidationTask: Task<Void, Never>?
    @Published private(set) var openCodeCredentialMessage: String?
    @Published private(set) var isRefreshingOpenCode = false
    @Published private(set) var usageResult: ProviderUsageResult?
    @Published private(set) var isLoadingMetrics = false

    private let configurationStore: ProviderConfigurationStore
    private let accountID: String
    private let onCredentialsChanged: @MainActor () -> Void
    private let onRefreshInputsChanged: @MainActor () -> Void
    private let onAccountIdentityChanged: @MainActor () -> Void
    private let onAccountRefresh: @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult?
    private let onCredentialRefresh: @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult?
    private let codexAuthService: any CodexWebAuthenticating
    private let copilotAuthService: any CopilotWebAuthenticating
    private let githubBillingAuthService: any GitHubBillingWebAuthenticating
    private let githubBillingUsageProvider: GitHubBillingUsageProvider
    private var pendingGitHubBillingAuthResult: GitHubBillingWebAuthResult?
    private var githubBillingSignInTask: Task<Void, Never>?
    private var githubBillingConnectionTask: Task<Void, Never>?
    private var githubBillingSignInAttemptID: UUID?
    private var githubBillingConnectionAttemptID: UUID?
    private var ignoresNextGitHubBillingAuthDismissal = false
    private let claudeAuthService: ClaudeWebAuthService
    private let grokAuthService: GrokDeviceAuthService
    private let grokUsageProvider: GrokUsageProvider
    private var grokAuthPresenter = PrivateWebAuthenticationPresenter()
    private var grokSignInTask: Task<Void, Never>?
    private var grokAttemptID: UUID?
    private let cursorAuthService: any CursorWebAuthenticating
    private let copilotUsageProvider: CopilotUsageProvider
    private var codexSignInTask: Task<Void, Never>?
    private let codexAuthPresenter: any CodexBrowserPresenting
    private var cursorSignInTask: Task<Void, Never>?
    private var cursorAuthPresenter: any CodexBrowserPresenting = PrivateWebAuthenticationPresenter()
    #if DEBUG
    @Published var cursorFixtureStage: GrokFixtureStage?
    private var cursorFixtureFlow: UITestCursorAuthFlow?
    func approveSyntheticCursorSignIn() { cursorFixtureFlow?.approve() }
    func cancelSyntheticCursorSignIn() { cursorSignInTask?.cancel(); cursorFixtureFlow?.finish() }
    #endif
    private var debugAutostartedCopilotAuth = false
    private var pendingPersistenceTask: Task<Void, Never>?
    private var pendingConfiguration: ProviderAccountConfiguration?
    private var needsCredentialMetricsRefresh = false
    private var metricsCredentialRevision = 0
    private var isCredentialRefreshPending = false
    private var validationFeedbackProviderID: ProviderID?

    var credentialMessageSystemImage: String {
        credentialMessage == credentialValidationFeedback?.validatedMessage
            ? "checkmark.circle"
            : "clock"
    }

    init(
        configurationStore: ProviderConfigurationStore,
        accountID: String,
        initialUsageResult: ProviderUsageResult? = nil,
        onCredentialsChanged: @escaping @MainActor () -> Void = {},
        onRefreshInputsChanged: @escaping @MainActor () -> Void = {},
        onAccountIdentityChanged: @escaping @MainActor () -> Void = {},
        onAccountRefresh: @escaping @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult? = { _ in nil },
        onCredentialRefresh: (@MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult?)? = nil,
        codexAuthService: any CodexWebAuthenticating = CodexWebAuthService(),
        codexAuthPresenter: (any CodexBrowserPresenting)? = nil,
        copilotAuthService: any CopilotWebAuthenticating = CopilotWebAuthService(),
        githubBillingAuthService: any GitHubBillingWebAuthenticating = GitHubBillingWebAuthService(),
        githubBillingUsageProvider: GitHubBillingUsageProvider = GitHubBillingUsageProvider(),
        claudeAuthService: ClaudeWebAuthService = ClaudeWebAuthService(),
        grokAuthService: GrokDeviceAuthService = GrokDeviceAuthService(),
        grokUsageProvider: GrokUsageProvider = GrokUsageProvider(),
        cursorAuthService: any CursorWebAuthenticating = CursorWebAuthService(),
        copilotUsageProvider: CopilotUsageProvider = CopilotUsageProvider()
    ) {
        self.configurationStore = configurationStore
        self.accountID = accountID
        self.usageResult = initialUsageResult?.accountID == accountID
            ? initialUsageResult
            : nil
        self.onCredentialsChanged = onCredentialsChanged
        self.onRefreshInputsChanged = onRefreshInputsChanged
        self.onAccountIdentityChanged = onAccountIdentityChanged
        self.onAccountRefresh = onAccountRefresh
        self.onCredentialRefresh = onCredentialRefresh ?? onAccountRefresh
        self.codexAuthService = codexAuthService
        self.codexAuthPresenter = codexAuthPresenter ?? PrivateWebAuthenticationPresenter()
        self.copilotAuthService = copilotAuthService
        self.githubBillingAuthService = githubBillingAuthService
        self.githubBillingUsageProvider = githubBillingUsageProvider
        self.claudeAuthService = claudeAuthService
        self.grokAuthService = grokAuthService
        self.grokUsageProvider = grokUsageProvider
        #if DEBUG
        if UITestFixtures.current != nil,
           ProcessInfo.processInfo.environment["CODEXBAR_UI_TEST_SCENARIO"]?.hasPrefix("grok-cursor-session") == true {
            let fixture = UITestCursorAuthFlow()
            self.cursorFixtureFlow = fixture
            self.cursorAuthService = fixture
            self.cursorAuthPresenter = fixture
        } else { self.cursorAuthService = cursorAuthService }
        #else
        self.cursorAuthService = cursorAuthService
        #endif
        self.copilotUsageProvider = copilotUsageProvider
        self.configuration = configurationStore.configuration(accountID: accountID)
            ?? ProviderID(rawValue: accountID).map(ProviderAccountConfiguration.defaultConfiguration)
            ?? .defaultConfiguration(for: .codex)
        #if DEBUG
        cursorFixtureFlow?.stageChanged = { [weak self] in self?.cursorFixtureStage = $0 }
        #endif
    }

    var providerID: ProviderID {
        configuration.providerID
    }

    private var credentialValidationFeedback: CredentialValidationFeedback? {
        switch providerID {
        case .greptile:
            CredentialValidationFeedback(
                validatingMessage: "API key saved in Keychain. Validating with Greptile...",
                disabledMessage: "API key saved in Keychain. Enable this account to validate it with Greptile.",
                incompleteMessage: "API key saved in Keychain. "
                    + "Greptile validation did not complete; refresh to try again.",
                authenticationFailurePrefix: "API key saved in Keychain, but Greptile validation failed. ",
                transientFailurePrefix: "API key saved in Keychain. "
                    + "Greptile could not validate it right now. ",
                validatedMessage: "API key saved in Keychain and validated by Greptile."
            )
        case .antigravity:
            CredentialValidationFeedback(
                validatingMessage: "Session saved in Keychain. Validating Antigravity quotas...",
                disabledMessage: "Session saved in Keychain. Enable this account to validate it.",
                incompleteMessage: "Session saved in Keychain. Refresh to finish validation.",
                authenticationFailurePrefix: "Antigravity session validation failed. ",
                transientFailurePrefix: "Antigravity quotas could not be validated. ",
                validatedMessage: "Antigravity session saved and quotas verified."
            )
        case .gemini:
            CredentialValidationFeedback(
                validatingMessage: "Session credentials saved in Keychain. Validating with Gemini...",
                disabledMessage: "Session credentials saved in Keychain. "
                    + "Enable this account to validate them with Gemini.",
                incompleteMessage: "Session credentials saved in Keychain. "
                    + "Validation did not complete; refresh to try again.",
                authenticationFailurePrefix: "Session credentials saved in Keychain, "
                    + "but Gemini validation failed. ",
                transientFailurePrefix: "Session credentials saved in Keychain. "
                    + "Gemini could not validate them right now. ",
                validatedMessage: "Google session saved in Keychain and Gemini usage verified."
            )
        default:
            nil
        }
    }

    private var showsCredentialValidationFeedback: Bool {
        validationFeedbackProviderID == providerID
    }

    var availableAuthMethods: [ProviderAuthMethod] {
        switch providerID {
        case .greptile:
            configuration.authMethod == .apiKey && configurationStore.hasSecret(for: configuration) ? [.apiKey] : [.browserSession]
        case .codex, .claude, .grok, .xSubscription, .cursor, .gemini, .githubBilling, .openCodeZen:
            [.browserSession]
        case .antigravity:
            [.cliToken]
        case .copilot:
            [.browserSession, .cliToken]
        case .openRouter, .moonshot:
            [.apiKey]
        case .museCode:
            []
        }
    }

    var credentialPresentation: ProviderCredentialPresentation {
        if providerID == .antigravity {
            return ProviderCredentialPresentation(
                sectionTitle: "Saved Coding Connection",
                unsavedPlaceholder: "Coding session",
                savedPlaceholder: "Antigravity session saved",
                saveButtonTitle: "Save and Validate Session",
                setupMessage: "Manage saved coding connections in Gemini settings. "
                    + "New coding setup is not available in this build.",
                setupLinkTitle: nil,
                setupURL: nil,
                securityMessage: "Session tokens may grant broader Google account access. "
                    + "They stay in this account's Keychain entry. This integration uses an unofficial quota API."
            )
        }

        if providerID == .openRouter {
            return ProviderCredentialPresentation(
                sectionTitle: "OpenRouter Management API Key",
                unsavedPlaceholder: "Paste OpenRouter Management API Key",
                savedPlaceholder: "OpenRouter Management API Key saved",
                saveButtonTitle: "Save Management API Key",
                setupMessage: "OpenRouter credit balances require a Management API Key, not a regular inference key.",
                setupLinkTitle: "Create a Management API Key in OpenRouter",
                setupURL: URL(string: "https://openrouter.ai/settings/management-keys"),
                securityMessage: "Management keys can administer API keys and are more sensitive than inference "
                    + "keys. CodexBar stores this credential only in Keychain."
            )
        }

        if providerID == .greptile {
            return ProviderCredentialPresentation(
                sectionTitle: "Greptile Connection",
                unsavedPlaceholder: "Sign in to Greptile",
                savedPlaceholder: "Greptile session saved",
                saveButtonTitle: "Sign in to Greptile",
                setupMessage: nil,
                setupLinkTitle: nil,
                setupURL: nil,
                securityMessage: "Your Greptile session stays in this account's Keychain entry. "
                    + "CodexBar reads the selected organization's billing period and review activity."
            )
        }

        if providerID == .gemini {
            return ProviderCredentialPresentation(
                sectionTitle: "Gemini Apps Sign-In",
                unsavedPlaceholder: "Sign in with Google",
                savedPlaceholder: "Google session saved",
                saveButtonTitle: "Sign in with Google",
                setupMessage: nil,
                setupLinkTitle: nil,
                setupURL: nil,
                securityMessage: nil
            )
        }

        return ProviderCredentialPresentation(
            sectionTitle: providerID == .githubBilling ? "GitHub Billing Authorization" : "Credential",
            unsavedPlaceholder: providerID == .githubBilling ? "Sign in with GitHub" : "Paste credential",
            savedPlaceholder: providerID == .githubBilling
                ? "GitHub Billing authorization saved"
                : "Credential saved",
            saveButtonTitle: providerID == .githubBilling ? "Sign in with GitHub" : "Save Credential",
            setupMessage: nil,
            setupLinkTitle: nil,
            setupURL: nil,
            securityMessage: nil
        )
    }

    func binding<Value>(
        for keyPath: WritableKeyPath<ProviderAccountConfiguration, Value>,
        persistence: PersistenceBehavior = .immediate
    ) -> Binding<Value> {
        Binding(
            get: { self.configuration[keyPath: keyPath] },
            set: { value in
                var updated = self.configuration
                updated[keyPath: keyPath] = value
                self.updateConfiguration(updated, persistence: persistence)
            }
        )
    }

    var copilotAllotmentBinding: Binding<String> {
        Binding(
            get: { self.copilotTotalAllotmentText },
            set: { value in
                self.copilotTotalAllotmentText = value
                var updated = self.configuration
                updated.copilotTotalAllotment = self.parsedAllotment(value)
                self.updateConfiguration(updated, persistence: .debounced)
            }
        )
    }

    var hasOtherCodexAccounts: Bool {
        configurationStore.configurations(for: .codex).contains { $0.id != configuration.id }
    }

    var codexSignInButtonTitle: String {
        if configurationStore.hasSecret(for: configuration) {
            return "Sign in Again"
        }
        return hasOtherCodexAccounts
            ? "Connect a Different ChatGPT Account"
            : "Sign in with ChatGPT"
    }

    var availableMetrics: [ProviderUsageMetric] {
        let hasCatalog = providerID == .cursor
            || (providerID != .codex && !GoogleUsageMetricCatalog.definitions(for: providerID).isEmpty)
        return GoogleUsageMetricCatalog.metrics(
            for: providerID,
            result: hasCatalog && !canRefreshMetrics ? nil : usageResult,
            missingReason: configuration.isEnabled
                ? (canRefreshMetrics ? "Unavailable" : "Setup required") : "Account disabled"
        )
    }

    var canRefreshMetrics: Bool {
        configuration.isEnabled && configurationStore.isConfigured(configuration)
    }

    var metricsEmptyStateMessage: String {
        configuration.isEnabled
            ? "No metrics discovered yet. Refresh this account to load its dashboard metrics."
            : "Enable this account to discover its dashboard metrics."
    }

    func isMetricVisible(_ metricID: String) -> Bool {
        configurationStore.isMetricVisible(accountID: accountID, metricID: metricID)
    }

    func setMetricVisibility(_ isVisible: Bool, metricID: String) {
        configurationStore.updateMetricVisibility(
            isVisible,
            accountID: accountID,
            metricID: metricID
        )
    }

    func synchronizeUsageResult(_ result: ProviderUsageResult?) {
        guard !isCredentialRefreshPending else { return }
        guard let result else {
            usageResult = nil
            return
        }
        acceptUsageResult(result)
    }

    func refreshMetrics() async {
        await refreshMetrics(allowUnconfiguredAccount: false, requiresFreshRequest: false)
    }

    private func refreshMetrics(
        allowUnconfiguredAccount: Bool,
        requiresFreshRequest: Bool
    ) async {
        if isLoadingMetrics {
            if allowUnconfiguredAccount {
                needsCredentialMetricsRefresh = true
            }
            return
        }

        let credentialRevision = metricsCredentialRevision
        guard
            configuration.isEnabled,
            allowUnconfiguredAccount || canRefreshMetrics
        else {
            if requiresFreshRequest {
                completeCredentialRefresh(revision: credentialRevision)
            }
            return
        }

        flushPendingChanges()
        isLoadingMetrics = true
        let result = requiresFreshRequest
            ? await onCredentialRefresh(configuration)
            : await onAccountRefresh(configuration)
        isLoadingMetrics = false

        if needsCredentialMetricsRefresh {
            needsCredentialMetricsRefresh = false
            await refreshMetrics(allowUnconfiguredAccount: true, requiresFreshRequest: true)
            return
        }

        if requiresFreshRequest {
            completeCredentialRefresh(revision: credentialRevision)
        }
        guard credentialRevision == metricsCredentialRevision else { return }
        guard let result else {
            if requiresFreshRequest,
               showsCredentialValidationFeedback,
               let feedback = credentialValidationFeedback {
                credentialError = nil
                credentialMessage = feedback.incompleteMessage
            }
            return
        }
        acceptUsageResult(result)
        if showsCredentialValidationFeedback {
            updateCredentialValidationFeedback(with: result)
            if result.failureMessage == nil {
                validationFeedbackProviderID = nil
            }
        }
    }

    func prepare() async {
        let stored = configurationStore.configuration(accountID: accountID) ?? configuration
        let normalized = normalizedConfiguration(stored)
        configuration = normalized
        copilotTotalAllotmentText = allotmentText(normalized.copilotTotalAllotment)
        if normalized != stored {
            _ = configurationStore.update(normalized)
        }
        configurationStore.refreshSecretAvailability()
        debugPrepareGitHubBillingSelectionIfNeeded()
        await debugAutostartCopilotAuthIfNeeded()
        await loadMetricsIfNeeded()
    }

    var isClaudeOrganizationBilling: Bool {
        guard configuration.providerID == .claude, let identifier = usageResult?.plan?.identifier.lowercased() else { return false }
        return identifier.contains("team") || identifier.contains("enterprise")
    }

    func startSubscriptionBillingSignIn() {
        cancelSubscriptionBillingSignIn()
        guard [.claude, .grok].contains(configuration.providerID), !isClaudeOrganizationBilling,
              let usageSecret = configurationStore.billingUsageSecret(for: configuration) else { return }
        let account = configuration
        subscriptionBillingMessage = nil
        subscriptionBillingSession = SubscriptionBillingSignInSession(configuration: account, usageSecret: usageSecret) { [weak self] result in
            guard let self else { return }
            self.subscriptionBillingSession = nil
            switch result {
            case .success(let session):
                guard self.configurationStore.saveSubscriptionBillingSession(session, for: account, expectedUsageSecret: usageSecret) else {
                    self.subscriptionBillingMessage = "Account changed or billing could not be saved. Connect billing again."
                    return
                }
                self.subscriptionBillingMessage = "Billing connected. Updating the current renewal date."
                self.credentialsDidChange()
            case .failure(let error):
                if error as? SubscriptionBillingError != .canceled { self.subscriptionBillingMessage = error.localizedDescription }
            }
        }
    }

    func cancelSubscriptionBillingSignIn() {
        subscriptionBillingSession?.invalidate()
        subscriptionBillingSession = nil
    }

    func disconnectSubscriptionBilling() {
        cancelSubscriptionBillingSignIn()
        if configurationStore.removeSubscriptionBillingSession(for: configuration) {
            subscriptionBillingMessage = "Billing disconnected. Your usage connection is unchanged."
            credentialsDidChange()
        }
    }

    func cancelAuthentication() {
        cancelSubscriptionBillingSignIn()
        cancelGrokSignIn()
        cancelOpenCodeSignIn()
        cancelGoogleCodingSignIn()
        cancelGeminiSignIn()
        cancelGreptileSignIn()
        codexSignInTask?.cancel()
        codexAuthPresenter.finish()
        cursorSignInTask?.cancel()
        cursorAuthPresenter.finish()
        githubBillingSignInTask?.cancel()
        githubBillingSignInTask = nil
        githubBillingSignInAttemptID = nil
        githubBillingConnectionTask?.cancel()
        githubBillingConnectionTask = nil
        githubBillingConnectionAttemptID = nil
        pendingGitHubBillingAuthResult = nil
        githubBillingAccountOptions = []
        isSigningInWithGitHubBilling = false
    }

    func authenticationSheetDismissed() {
        if ignoresNextGitHubBillingAuthDismissal {
            ignoresNextGitHubBillingAuthDismissal = false
            return
        }
        guard isSigningInWithGitHubBilling else { return }
        githubBillingSignInTask?.cancel()
        githubBillingSignInTask = nil
        githubBillingSignInAttemptID = nil
        pendingGitHubBillingAuthResult = nil
        githubBillingAccountOptions = []
        isSigningInWithGitHubBilling = false
    }

    func flushPendingChanges() {
        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = nil
        guard let pendingConfiguration else { return }
        self.pendingConfiguration = nil
        _ = persist(pendingConfiguration)
    }

    func saveGenericCredential() {
        credentialError = nil
        credentialMessage = nil
        validationFeedbackProviderID = nil
        guard persist(configuration) else {
            credentialError = configurationStore.lastError
            return
        }
        let credentialToStore: String
        if providerID == .gemini {
            do {
                credentialToStore = try GeminiSessionCredentialsParser.storedCredential(from: secret)
            } catch {
                credentialError = error.localizedDescription
                return
            }
        } else if providerID == .antigravity {
            do {
                credentialToStore = try AntigravityCredentials.parse(secret).encoded()
            } catch {
                credentialError = AntigravityCredentials.CredentialError.invalid.localizedDescription
                return
            }
        } else {
            credentialToStore = secret
        }
        guard persistSecret(credentialToStore) else {
            credentialError = configurationStore.lastError
            return
        }
        secret = ""
        if let feedback = credentialValidationFeedback {
            validationFeedbackProviderID = providerID
            credentialMessage = configuration.isEnabled
                ? feedback.validatingMessage
                : feedback.disabledMessage
        }
        credentialsDidChange()
    }

    func removeSavedCredential(message: String? = nil) {
        if providerID == .greptile { cancelGreptileSignIn() }
        if providerID.usesXAIConsumerAuth { cancelGrokSignIn() }
        if providerID == .openCodeZen { cancelOpenCodeSignIn() }
        if providerID == .gemini { cancelGeminiSignIn() }
        if providerID == .githubBilling { cancelAuthentication() }
        credentialError = nil
        credentialMessage = nil
        validationFeedbackProviderID = nil
        flushPendingChanges()
        guard persistSecret("") else {
            credentialError = configurationStore.lastError
            return
        }
        openCodeCredentialMessage = message
        credentialsDidChange()
    }

    func startGoogleCodingSignIn() {
        guard !isSigningInWithGoogleCoding, providerID == .gemini else { return }
        geminiCodingMessage = nil
        let client: GoogleCodingSignIn.Configuration
        do {
            client = try GoogleCodingSignIn.Configuration(
                clientID: Bundle.main.object(forInfoDictionaryKey: "GoogleCodingOAuthClientID") as? String ?? ""
            )
        } catch {
            geminiCodingMessage = GoogleCodingSignIn.Failure.missingConfiguration.localizedDescription
            return
        }
        isSigningInWithGoogleCoding = true
        googleCodingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isSigningInWithGoogleCoding = false }
            do {
                let credentials = try await self.googleCodingSignIn.signIn(configuration: client)
                try await self.receiveGoogleCodingCredential(credentials)
            } catch is CancellationError {
                self.geminiCodingMessage = "Coding sign-in canceled."
            } catch {
                self.geminiCodingMessage = (error as? GoogleCodingSignIn.Failure)?.localizedDescription
                    ?? "Coding sign-in could not finish. Please try again."
            }
        }
    }

    func receiveGoogleCodingCredential(_ credentials: AntigravityCredentials) async throws {
        if configurationStore.hasSecret(for: configuration)
            || configurationStore.hasGeminiCodingSecret(for: configuration) {
            pendingGoogleCodingCredential = credentials
            needsGoogleCodingAccountConfirmation = true
            return
        }
        try await saveValidatedGoogleCodingCredential(credentials)
    }

    func confirmGoogleCodingAccount() {
        guard needsGoogleCodingAccountConfirmation, let credentials = pendingGoogleCodingCredential else { return }
        pendingGoogleCodingCredential = nil
        needsGoogleCodingAccountConfirmation = false
        isSigningInWithGoogleCoding = true
        googleCodingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isSigningInWithGoogleCoding = false }
            do {
                try await self.saveValidatedGoogleCodingCredential(credentials)
            } catch is CancellationError {
                self.geminiCodingMessage = "Coding sign-in canceled."
            } catch {
                self.geminiCodingMessage = "Coding sign-in could not finish. Please try again."
            }
        }
    }

    func saveValidatedGoogleCodingCredential(_ credentials: AntigravityCredentials) async throws {
        geminiCodingMessage = "Checking coding usage…"
        try await googleCodingUsageProvider.validateCandidate(credentials, for: configuration)
        try Task.checkCancellation()
        flushPendingChanges()
        guard configurationStore.saveGeminiCodingSecret(
            try credentials.encoded(), for: configuration, confirmedSameAccount: true
        ) else {
            geminiCodingMessage = configurationStore.lastError ?? "Coding sign-in could not be saved."
            return
        }
        geminiCodingMessage = "Coding account connected."
        credentialsDidChange()
    }

    func cancelGoogleCodingSignIn() {
        pendingGoogleCodingCredential = nil
        needsGoogleCodingAccountConfirmation = false
        googleCodingTask?.cancel()
        googleCodingSignIn.cancel()
    }

    func saveGeminiCodingCredential(confirmedSameAccount: Bool) {
        geminiCodingMessage = nil
        guard providerID == .gemini else { return }
        guard confirmedSameAccount else {
            geminiCodingMessage = "Confirm that the coding session belongs to this Gemini account before linking it."
            return
        }
        let codingCredential: String
        do {
            codingCredential = try AntigravityCredentials.parse(geminiCodingSecret).encoded()
        } catch {
            geminiCodingMessage = AntigravityCredentials.CredentialError.invalid.localizedDescription
            return
        }
        flushPendingChanges()
        guard configurationStore.saveGeminiCodingSecret(codingCredential, for: configuration, confirmedSameAccount: true) else {
            geminiCodingMessage = configurationStore.lastError ?? "The coding session could not be saved."
            return
        }
        geminiCodingSecret = ""
        geminiCodingMessage = "Coding session saved. Check the four coding limits below for current availability."
        credentialsDidChange()
    }

    func linkGeminiCodingAccount(_ legacy: ProviderAccountConfiguration, confirmedSameAccount: Bool) {
        geminiCodingMessage = nil
        flushPendingChanges()
        guard configurationStore.linkGeminiCodingAccount(legacy, to: configuration, confirmedSameAccount: confirmedSameAccount) else {
            geminiCodingMessage = configurationStore.lastError ?? "The saved coding account could not be linked."
            return
        }
        geminiCodingMessage = "Saved coding account linked. Check its four coding limits below for current availability."
        credentialsDidChange()
    }

    func disconnectGeminiCoding() {
        cancelGoogleCodingSignIn()
        geminiCodingMessage = nil
        flushPendingChanges()
        guard configurationStore.disconnectGeminiCoding(for: configuration) else {
            geminiCodingMessage = configurationStore.lastError ?? "The coding session could not be removed."
            return
        }
        geminiCodingMessage = "Coding session removed. Gemini Apps stays connected."
        credentialsDidChange()
    }

    func startGeminiSignIn() {
        guard !isSigningInWithGemini else { return }
        credentialError = nil
        credentialMessage = nil
        validationFeedbackProviderID = nil
        isSigningInWithGemini = true
        let attemptID = UUID()
        geminiAttemptID = attemptID
        geminiBrowserSession = GeminiBrowserSignInSession { [weak self] result in
            self?.completeGeminiBrowserSignIn(result, attemptID: attemptID)
        }
    }

    func startGreptileSignIn() {
        guard !isSigningInWithGreptile else { return }
        credentialError = nil
        credentialMessage = nil
        isSigningInWithGreptile = true
        let attemptID = UUID()
        greptileAttemptID = attemptID
        greptileBrowserSession = GreptileBrowserSignInSession { [weak self] result in
            guard let self, self.greptileAttemptID == attemptID else { return }
            self.greptileBrowserSession = nil
            self.greptileAttemptID = nil
            self.isSigningInWithGreptile = false
            self.completeGreptileSignIn(result)
        }
    }

    private func completeGreptileSignIn(_ result: Result<GreptileSessionCredentials, Error>) {
        do {
            let credential = try result.get()
            guard configurationStore.canReconnectGreptile(credential, for: configuration) else {
                credentialError = configurationStore.lastError
                return
            }
            var updated = configuration
            updated.authMethod = .browserSession
            if updated.accountLabel.isEmpty { updated.accountLabel = credential.organization.name }
            guard persistCredential(try credential.encoded(), with: updated) else {
                credentialError = "Greptile sign-in completed, but secure storage failed. Your saved account was not changed."
                return
            }
            validationFeedbackProviderID = nil
            credentialMessage = "Greptile connected. Reading your usage…"
            credentialsDidChange(refreshMetrics: false)
            refreshConnectedGreptile()
        } catch {
            credentialError = (error as? GreptileSignInError ?? .invalidSession).localizedDescription
        }
    }

    private func refreshConnectedGreptile() {
        let revision = metricsCredentialRevision
        Task { @MainActor [weak self] in
            guard let self else { return }
            let refreshed = await self.onAccountRefresh(self.configuration)
            guard revision == self.metricsCredentialRevision, let refreshed else { return }
            self.acceptUsageResult(refreshed)
        }
    }

    func cancelGreptileSignIn() {
        greptileAttemptID = nil
        greptileBrowserSession?.invalidate()
        greptileBrowserSession = nil
        isSigningInWithGreptile = false
    }

    func cancelGeminiSignIn() {
        guard geminiAttemptID != nil else { return }
        geminiAttemptID = nil
        pendingGeminiCredential = nil
        needsGeminiAccountConfirmation = false
        geminiValidationTask?.cancel()
        geminiValidationTask = nil
        geminiBrowserSession?.invalidate()
        geminiBrowserSession = nil
        isSigningInWithGemini = false
        credentialMessage = nil
        credentialError = GeminiSignInError.canceled.localizedDescription
    }

    private func completeGeminiBrowserSignIn(_ result: Result<String, Error>, attemptID: UUID) {
        guard geminiAttemptID == attemptID else { return }
        geminiBrowserSession?.invalidate()
        geminiBrowserSession = nil
        switch result {
        case .failure(let error):
            finishGeminiAttempt(attemptID)
            credentialError = (error as? GeminiSignInError ?? .browserFailed).localizedDescription
        case .success(let credential):
            if configurationStore.hasGeminiCodingSecret(for: configuration) {
                pendingGeminiCredential = credential
                needsGeminiAccountConfirmation = true
                return
            }
            credentialMessage = "Verifying your Gemini usage..."
            geminiValidationTask = Task { [weak self] in
                await self?.validateGeminiSession(credential, attemptID: attemptID)
            }
        }
    }

    func confirmGeminiAppsAccount() {
        guard needsGeminiAccountConfirmation, let credential = pendingGeminiCredential,
              let attemptID = geminiAttemptID else { return }
        pendingGeminiCredential = nil
        needsGeminiAccountConfirmation = false
        credentialMessage = "Verifying your Gemini usage..."
        geminiValidationTask = Task { [weak self] in
            await self?.validateGeminiSession(credential, attemptID: attemptID)
        }
    }

    private func validateGeminiSession(_ credential: String, attemptID: UUID) async {
        defer { finishGeminiAttempt(attemptID) }
        do {
            let storedCredential = try GeminiSessionCredentialsParser.storedCredential(from: credential)
            let result = try await geminiSessionValidator.validate(credential: storedCredential, configuration: configuration)
            guard !Task.isCancelled, geminiAttemptID == attemptID else { return }
            guard result.accountID == accountID, result.providerID == .gemini,
                  result.failureMessage == nil,
                  ["five-hour", "weekly"].allSatisfy({ key in
                      result.bars.contains { $0.stableKey == key && $0.resetsAt != nil && $0.used.isFinite && $0.limit > 0 }
                  }) else {
                credentialMessage = nil
                credentialError = result.failureMessage.map { "Gemini usage could not be verified. " + $0 }
                    ?? "Gemini did not return both usage meters and reset times. Your saved account was not changed."
                return
            }
            var updated = configuration
            updated.authMethod = .browserSession
            guard persistCredential(storedCredential, with: updated) else {
                credentialMessage = nil
                credentialError = "Google sign-in completed, but the session could not be saved in Keychain. Try again."
                return
            }
            secret = ""
            credentialError = nil
            credentialMessage = credentialValidationFeedback?.validatedMessage
            credentialsDidChange()
            acceptUsageResult(result)
        } catch {
            guard !Task.isCancelled, geminiAttemptID == attemptID else { return }
            credentialMessage = nil
            credentialError = GeminiSignInError.validationFailed.localizedDescription
        }
    }

    private func finishGeminiAttempt(_ attemptID: UUID) {
        guard geminiAttemptID == attemptID else { return }
        geminiAttemptID = nil
        geminiValidationTask = nil
        isSigningInWithGemini = false
    }

    func startCodexSignIn(mode: CodexBrowserMode) {
        guard codexSignInTask == nil else { return }
        codexSignInTask = Task { @MainActor in
            await self.signInWithCodex(mode: mode)
        }
    }

    func signInWithCodex(mode: CodexBrowserMode = .privateSession) async {
        isSigningInWithCodex = true
        credentialError = nil
        codexAuthError = nil
        defer {
            codexAuthPresenter.finish()
            codexSignInTask = nil
            isSigningInWithCodex = false
        }

        do {
            let result = try await codexAuthService.signIn { url in
                self.codexAuthPresenter.present(
                    url: url,
                    prefersEphemeralSession: mode.prefersEphemeralSession,
                    onCancel: { self.codexSignInTask?.cancel() }
                )
            }

            switch configurationStore.validateCodexAccountIdentity(
                result.accountID,
                for: configuration
            ) {
            case .available:
                break
            case .duplicate(let accountName):
                codexAuthError = "That ChatGPT account is already connected as “\(accountName)”. No saved account was changed. Cancel or try again with a different identity."
                return
            case .unableToVerify:
                codexAuthError = "ChatGPT sign-in completed, but CodexBar could not safely verify it against the "
                    + "other saved ChatGPT accounts. No saved account was changed. Try again."
                return
            }

            var updated = configuration
            updated.authMethod = .browserSession
            guard persistCredential(result.storedCredential, with: updated) else {
                codexAuthError = configurationStore.lastError
                return
            }
            credentialsDidChange()
        } catch {
            codexAuthError = error is CancellationError || Task.isCancelled
                ? "ChatGPT sign-in canceled. Saved accounts were not changed."
                : error.localizedDescription
        }
    }

    func signInWithCopilot() async {
        isSigningInWithCopilot = true
        credentialError = nil
        copilotAuthError = nil
        defer { isSigningInWithCopilot = false }

        do {
            let result = try await copilotAuthService.signIn(configuration: .bundled) { url in
                self.authURL = PresentedAuthURL(url: url)
            }
            let username = try await copilotUsageProvider.fetchUsername(accessToken: result.accessToken)
            guard let username, !username.isEmpty else {
                copilotAuthError = "GitHub sign-in completed, but the token could not be verified for Copilot access."
                authURL = nil
                return
            }

            var updated = configuration
            updateCopilotAccountLabel(&updated, username: username)
            updated.authMethod = .browserSession
            guard persistCredential(
                result.storedCredential(username: username),
                with: updated
            ) else {
                copilotAuthError = configurationStore.lastError
                authURL = nil
                return
            }
            secret = ""
            credentialsDidChange()
            authURL = nil
        } catch {
            copilotAuthError = error.localizedDescription
            authURL = nil
        }
    }

    func startGitHubBillingSignIn() {
        githubBillingSignInTask?.cancel()
        let attemptID = UUID()
        githubBillingSignInAttemptID = attemptID
        githubBillingSignInTask = Task { [weak self] in
            await self?.signInWithGitHubBilling(attemptID: attemptID)
        }
    }

    private func signInWithGitHubBilling(attemptID: UUID) async {
        guard isCurrentGitHubBillingSignInAttempt(attemptID) else { return }
        isSigningInWithGitHubBilling = true
        credentialError = nil
        githubBillingAuthError = nil
        githubBillingMessage = nil
        githubBillingAccountOptions = []
        pendingGitHubBillingAuthResult = nil
        defer { finishGitHubBillingSignIn(attemptID: attemptID) }

        do {
            let result = try await githubBillingAuthService.signIn(configuration: .bundled) { url in
                self.presentGitHubBillingAuthorizationURL(url, attemptID: attemptID)
            }
            guard isCurrentGitHubBillingSignInAttempt(attemptID) else { return }
            let provisionalCredentials = GitHubBillingCredentials(
                accessToken: result.accessToken,
                username: "",
                refreshToken: result.refreshToken,
                expiresAt: result.expiresAt,
                refreshTokenExpiresAt: result.refreshTokenExpiresAt
            )
            let options = try await githubBillingUsageProvider.discoverAccounts(
                credentials: provisionalCredentials
            )
            completeGitHubBillingSignIn(
                result: result,
                options: options,
                attemptID: attemptID
            )
        } catch is CancellationError {
            // An interactive sheet dismissal already cleared the presented URL.
        } catch {
            handleGitHubBillingSignInFailure(error, attemptID: attemptID)
        }
    }

    private func completeGitHubBillingSignIn(
        result: GitHubBillingWebAuthResult,
        options: [GitHubBillingAccountOption],
        attemptID: UUID
    ) {
        guard isCurrentGitHubBillingSignInAttempt(attemptID) else { return }
        guard !options.isEmpty else {
            githubBillingAuthError = "GitHub sign-in returned no personal account or eligible organization."
            closeGitHubBillingAuthSheet()
            return
        }
        pendingGitHubBillingAuthResult = result
        githubBillingAccountOptions = options
        selectedGitHubBillingAccountID = options.first?.id ?? ""
        githubBillingMessage = "Choose the personal account or eligible organization to monitor."
        closeGitHubBillingAuthSheet()
    }

    private func isCurrentGitHubBillingSignInAttempt(_ attemptID: UUID) -> Bool {
        !Task.isCancelled && githubBillingSignInAttemptID == attemptID
    }

    private func presentGitHubBillingAuthorizationURL(_ url: URL, attemptID: UUID) {
        guard githubBillingSignInAttemptID == attemptID else { return }
        authURL = PresentedAuthURL(url: url)
    }

    private func handleGitHubBillingSignInFailure(_ error: Error, attemptID: UUID) {
        guard githubBillingSignInAttemptID == attemptID else { return }
        githubBillingAuthError = error.localizedDescription
        closeGitHubBillingAuthSheet()
    }

    private func finishGitHubBillingSignIn(attemptID: UUID) {
        guard githubBillingSignInAttemptID == attemptID else { return }
        githubBillingSignInAttemptID = nil
        githubBillingSignInTask = nil
        isSigningInWithGitHubBilling = false
    }

    private func closeGitHubBillingAuthSheet() {
        guard authURL != nil else { return }
        ignoresNextGitHubBillingAuthDismissal = true
        authURL = nil
    }

    func startGitHubBillingAccountConnection() {
        githubBillingConnectionTask?.cancel()
        let attemptID = UUID()
        githubBillingConnectionAttemptID = attemptID
        githubBillingConnectionTask = Task { [weak self] in
            await self?.connectSelectedGitHubBillingAccount(attemptID: attemptID)
        }
    }

    private func connectSelectedGitHubBillingAccount(attemptID: UUID) async {
        defer { finishGitHubBillingConnection(attemptID: attemptID) }
        guard githubBillingConnectionAttemptID == attemptID else { return }
        guard let inputs = githubBillingConnectionInputs() else {
            githubBillingAuthError = "Sign in with GitHub and choose an account before connecting."
            return
        }

        isSigningInWithGitHubBilling = true
        githubBillingAuthError = nil
        githubBillingMessage = "Checking GitHub Billing access..."

        let updated = updatedGitHubBillingConfiguration(option: inputs.option)
        let credentials = inputs.authResult.credentials(username: inputs.username)
        do {
            let result = try await githubBillingUsageProvider.validateCandidate(
                credentials,
                for: updated
            )
            try Task.checkCancellation()
            completeGitHubBillingConnection(
                credentials: credentials,
                configuration: updated,
                result: result,
                attemptID: attemptID
            )
        } catch is CancellationError {
            handleGitHubBillingConnectionCancellation(attemptID: attemptID)
        } catch {
            handleGitHubBillingConnectionFailure(error, attemptID: attemptID)
        }
    }

    private func githubBillingConnectionInputs() -> (
        authResult: GitHubBillingWebAuthResult,
        option: GitHubBillingAccountOption,
        username: String
    )? {
        guard
            let authResult = pendingGitHubBillingAuthResult,
            let option = githubBillingAccountOptions.first(where: { $0.id == selectedGitHubBillingAccountID }),
            let username = githubBillingAccountOptions.first(where: { $0.scope == .personal })?.owner
        else {
            return nil
        }
        return (authResult, option, username)
    }

    private func updatedGitHubBillingConfiguration(
        option: GitHubBillingAccountOption
    ) -> ProviderAccountConfiguration {
        var updated = configuration
        updated.authMethod = .browserSession
        let priorOwner = updated.githubBillingOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        let priorLabel = updated.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesGeneratedOwnerLabel = priorLabel.isEmpty
            || (!priorOwner.isEmpty && priorLabel.caseInsensitiveCompare(priorOwner) == .orderedSame)
        updated.githubBillingAccountScope = option.scope
        updated.githubBillingOwner = option.owner
        if usesGeneratedOwnerLabel {
            updated.accountLabel = option.owner
        }
        return updated
    }

    private func completeGitHubBillingConnection(
        credentials: GitHubBillingCredentials,
        configuration: ProviderAccountConfiguration,
        result: ProviderUsageResult,
        attemptID: UUID
    ) {
        guard githubBillingConnectionAttemptID == attemptID else { return }
        let identityChanged = configuration.githubBillingAccountScope != self.configuration.githubBillingAccountScope
            || configuration.githubBillingOwner.caseInsensitiveCompare(self.configuration.githubBillingOwner) != .orderedSame
        guard let storedCredential = GitHubBillingCredentialsParser.storedCredential(from: credentials),
              persistCredential(storedCredential, with: configuration) else {
            githubBillingAuthError = configurationStore.lastError
                ?? "GitHub Billing authorization could not be saved in Keychain."
            return
        }
        pendingGitHubBillingAuthResult = nil
        githubBillingAccountOptions = []
        selectedGitHubBillingAccountID = ""
        githubBillingMessage = "GitHub Billing account connected and verified."
        if identityChanged {
            onAccountIdentityChanged()
        }
        credentialsDidChange()
        acceptUsageResult(result)
    }

    private func handleGitHubBillingConnectionCancellation(attemptID: UUID) {
        guard githubBillingConnectionAttemptID == attemptID else { return }
        githubBillingMessage = nil
    }

    private func handleGitHubBillingConnectionFailure(_ error: Error, attemptID: UUID) {
        guard githubBillingConnectionAttemptID == attemptID else { return }
        githubBillingMessage = nil
        githubBillingAuthError = error.localizedDescription
    }

    private func finishGitHubBillingConnection(attemptID: UUID) {
        guard githubBillingConnectionAttemptID == attemptID else { return }
        githubBillingConnectionAttemptID = nil
        githubBillingConnectionTask = nil
        isSigningInWithGitHubBilling = false
    }

    func signInWithClaude() async {
        isSigningInWithClaude = true
        credentialError = nil
        claudeAuthError = nil
        claudeAuthDiagnostic = nil
        defer { isSigningInWithClaude = false }

        do {
            let result = try await claudeAuthService.signIn(
                presentAuthorizationURL: { url in
                    self.authURL = PresentedAuthURL(url: url)
                },
                reportStage: { message in
                    self.claudeAuthDiagnostic = message
                }
            )
            var updated = configuration
            updated.authMethod = .browserSession
            guard persistCredential(result.storedCredential, with: updated) else {
                claudeAuthError = configurationStore.lastError
                claudeAuthDiagnostic = "Claude sign-in failed."
                authURL = nil
                return
            }
            secret = ""
            credentialsDidChange()
            authURL = nil
            claudeAuthDiagnostic = "Claude sign-in complete."
        } catch {
            claudeAuthError = error.localizedDescription
            authURL = nil
            if claudeAuthDiagnostic == nil {
                claudeAuthDiagnostic = "Claude sign-in failed."
            }
        }
    }

    /// Grok keeps its existing copy; X Subscription signs in to xAI and reads its own pool.
    private var xAISignInName: String { providerID == .xSubscription ? "xAI" : "Grok" }
    private var xAIUsageName: String { providerID == .xSubscription ? "X Subscription" : "Grok" }

    func startGrokSignIn() {
        guard providerID.usesXAIConsumerAuth, grokAttemptID == nil else { return }
        #if DEBUG
        if UITestFixtures.current != nil {
            grokAttemptID = UUID()
            isSigningInWithGrok = true
            grokMessage = "Synthetic browser approval. No live account or credentials."
            grokFixtureStage = .approval
            return
        }
        #endif
        flushPendingChanges()
        grokMessage = "Starting \(xAISignInName) sign-in..."
        isSigningInWithGrok = true
        let attempt = UUID()
        grokAttemptID = attempt
        grokSignInTask = Task { [weak self] in
            await self?.connectGrok(attempt: attempt)
        }
    }

    func cancelGrokSignIn() {
        guard grokAttemptID != nil else { return }
        grokAttemptID = nil
        grokSignInTask?.cancel()
        grokSignInTask = nil
        grokAuthPresenter.finish()
        grokFixtureStage = nil
        isSigningInWithGrok = false
        grokMessage = "\(xAISignInName) sign-in canceled. The saved account was not changed."
    }

    #if DEBUG
    func completeSyntheticGrokSignIn() {
        guard UITestFixtures.current != nil, grokAttemptID != nil, grokFixtureStage == .approval else { return }
        guard persistCredential("ui-test-credential", with: configuration) else {
            grokMessage = "Synthetic credential could not be saved."
            cancelGrokSignIn()
            return
        }
        grokFixtureStage = .connected
        grokMessage = "Synthetic \(xAIUsageName) account connected. No live provider was accessed."
        credentialsDidChange()
        acceptUsageResult(providerID == .xSubscription
            ? UITestFixtures.xSubscriptionResult(for: configuration) : UITestFixtures.grokResult(for: configuration))
    }

    func rejectSyntheticGrokSignIn() {
        cancelGrokSignIn()
        grokMessage = "Synthetic authorization declined. No account was changed."
    }

    func finishSyntheticGrokSignIn() {
        grokFixtureStage = nil
        grokAttemptID = nil
        isSigningInWithGrok = false
    }
    #endif

    private func connectGrok(attempt: UUID) async {
        defer {
            if grokAttemptID == attempt {
                grokAttemptID = nil
                grokSignInTask = nil
                isSigningInWithGrok = false
            }
        }
        do {
            guard let credential = try await authorizeGrok(attempt: attempt) else { return }
            try await verifyAndSaveGrok(credential, attempt: attempt)
        } catch {
            if grokAttemptID == attempt {
                grokMessage = error is CancellationError ? "\(xAISignInName) sign-in canceled." : error.localizedDescription
            }
        }
        if grokAttemptID == attempt { grokAuthPresenter.finish() }
    }

    private func authorizeGrok(attempt: UUID) async throws -> GrokCredential? {
        let challenge = try await grokAuthService.begin()
        guard grokAttemptID == attempt, !Task.isCancelled else { return nil }
        guard grokAuthPresenter.present(
            url: challenge.approvalURL, prefersEphemeralSession: false,
            onCancel: { [weak self] in
                if self?.grokAttemptID == attempt {
                    self?.grokMessage = "Checking \(self?.xAISignInName ?? "Grok") approval. Cancel here if you did not approve."
                }
            }
        ) else { throw GrokAuthError.invalidResponse }
        grokMessage = "Choose your \(xAISignInName) account and approve sign-in in the browser. Waiting for approval..."
        let credential = try await grokAuthService.authorize(challenge)
        guard grokAttemptID == attempt, !Task.isCancelled else { return nil }
        grokAuthPresenter.finish()
        return credential
    }

    private func verifyAndSaveGrok(_ credential: GrokCredential, attempt: UUID) async throws {
        grokMessage = providerID == .xSubscription
            ? "Checking X Subscription usage. Temporary outages may take up to two minutes to retry..."
            : "Checking Grok consumer usage. Temporary outages may take up to two minutes to retry..."
        let result = try await grokUsageProvider.verifyCandidate(
            credential, for: configuration, retryUntil: Date().addingTimeInterval(120)
        )
        guard grokAttemptID == attempt, !Task.isCancelled else { return }
        guard configurationStore.canReconnectGrok(credential, accountID: accountID) else {
            grokMessage = "This entry belongs to another \(xAISignInName) account. Add a separate account to track this identity."
            return
        }
        var updated = configuration
        updated.authMethod = .browserSession
        guard persistCredential(try credential.encoded(), with: updated) else {
            grokMessage = configurationStore.lastError ?? "\(xAISignInName) authorization could not be saved securely."
            return
        }
        configurationStore.applyVerifiedGrokPlan(result)
        configuration = configurationStore.configuration(accountID: accountID) ?? updated
        grokMessage = "\(xAIUsageName) account connected."
        credentialsDidChange()
        var titledResult = result
        titledResult.title = configuration.displayName
        acceptUsageResult(titledResult)
    }

    func startCursorSignIn() {
        guard cursorSignInTask == nil else { return }
        cursorSignInTask = Task { @MainActor in
            await self.signInWithCursor()
        }
    }

    func signOutOfCursor() {
        credentialError = nil
        cursorAuthError = nil
        flushPendingChanges()
        guard let disconnected = configurationStore.disconnectCursorAccount(configuration) else {
            cursorAuthError = configurationStore.lastError
            return
        }
        configuration = disconnected
        credentialsDidChange()
    }

    func startOpenCodeSignIn() {
        guard !isSigningInWithOpenCode else { return }
        flushPendingChanges()
        credentialError = nil
        openCodeCredentialMessage = nil
        isSigningInWithOpenCode = true
        let attemptID = UUID()
        openCodeAttemptID = attemptID
        var isSynthetic = false
        #if DEBUG
        if UITestFixtures.current != nil {
            isSynthetic = true
            openCodeSessionValidator = UITestOpenCodeSessionValidator()
        }
        #endif
        openCodeBrowserSession = OpenCodeBrowserSignInSession(isSynthetic: isSynthetic) { [weak self] result in
            self?.completeOpenCodeSignIn(result, attemptID: attemptID)
        }
    }

    func cancelOpenCodeSignIn() {
        guard openCodeAttemptID != nil else { return }
        openCodeAttemptID = nil
        openCodeValidationTask?.cancel()
        openCodeValidationTask = nil
        openCodeBrowserSession?.invalidate()
        openCodeBrowserSession = nil
        isSigningInWithOpenCode = false
        openCodeCredentialMessage = OpenCodeSignInError.canceled.localizedDescription
    }

    private func completeOpenCodeSignIn(_ result: Result<OpenCodeBrowserCredential, Error>, attemptID: UUID) {
        guard openCodeAttemptID == attemptID else { return }
        openCodeBrowserSession?.invalidate()
        openCodeBrowserSession = nil
        switch result {
        case .failure(let error):
            finishOpenCodeAttempt(attemptID)
            openCodeCredentialMessage = (error as? OpenCodeSignInError ?? .browserFailed).localizedDescription
        case .success(let candidate):
            openCodeCredentialMessage = "Verifying OpenCode workspace access..."
            openCodeValidationTask = Task { [weak self] in
                await self?.validateOpenCodeSession(candidate, attemptID: attemptID)
            }
        }
    }

    private func validateOpenCodeSession(_ candidate: OpenCodeBrowserCredential, attemptID: UUID) async {
        defer { finishOpenCodeAttempt(attemptID) }
        guard configurationStore.canReconnectOpenCodeSession(
            candidate.session, workspaceID: candidate.workspaceID, accountID: accountID
        ) else {
            openCodeCredentialMessage = "Choose the OpenCode user and workspace already linked to this account. "
                + "To track another account, add a separate OpenCode account."
            return
        }
        var updated = configuration
        updated.openCodeWorkspaceId = candidate.workspaceID
        updated.authMethod = .browserSession
        do {
            let result = try await openCodeSessionValidator.validate(credential: candidate.session, configuration: updated)
            guard openCodeAttemptID == attemptID, !Task.isCancelled else { return }
            acceptOpenCodeSession(candidate.session, configuration: updated, result: result)
        } catch {
            guard openCodeAttemptID == attemptID else { return }
            openCodeCredentialMessage = OpenCodeSignInError.validationFailed.localizedDescription
        }
    }

    private func acceptOpenCodeSession(
        _ credential: String,
        configuration updated: ProviderAccountConfiguration,
        result: ProviderUsageResult
    ) {
        guard result.accountID == accountID, result.providerID == .openCodeZen else { return }
        guard OpenCodeSessionValidator.hasVerifiedUsage(result) else {
            openCodeCredentialMessage = OpenCodeSignInError.validationFailed.localizedDescription
            return
        }
        guard saveOpenCodeSession(credential, workspaceID: updated.openCodeWorkspaceId) else { return }
        secret = ""
        openCodeCredentialMessage = "OpenCode connected. Session saved securely on this device."
        credentialsDidChange()
        acceptUsageResult(result)
    }

    private func saveOpenCodeSession(_ credential: String, workspaceID: String) -> Bool {
        flushPendingChanges()
        guard var current = configurationStore.configuration(accountID: accountID) else { return false }
        guard configurationStore.canReconnectOpenCodeSession(credential, workspaceID: workspaceID, accountID: accountID) else {
            openCodeCredentialMessage = "The saved OpenCode user or workspace changed during sign-in. Try again."
            return false
        }
        current.openCodeWorkspaceId = workspaceID
        current.authMethod = .browserSession
        guard persistCredential(credential, with: current) else {
            openCodeCredentialMessage = "OpenCode sign-in completed, but the session could not be saved. Try again."
            return false
        }
        return true
    }

    private func finishOpenCodeAttempt(_ attemptID: UUID) {
        guard openCodeAttemptID == attemptID else { return }
        openCodeAttemptID = nil
        openCodeValidationTask = nil
        isSigningInWithOpenCode = false
    }

    func saveOpenCodeCredential() {
        credentialError = nil
        guard persist(configuration) else {
            openCodeCredentialMessage = configurationStore.lastError
            return
        }
        guard persistSecret(secret) else {
            openCodeCredentialMessage = configurationStore.lastError
            return
        }

        secret = ""
        openCodeCredentialMessage = configuration.openCodeWorkspaceId
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "OpenCode dashboard auth value saved. Enter the workspace ID, then refresh."
            : "OpenCode dashboard auth value saved. Refreshing..."
        credentialsDidChange(refreshMetrics: false)
        Task { await refreshOpenCode(requiresFreshRequest: true) }
    }

    func refreshOpenCode() async {
        await refreshOpenCode(requiresFreshRequest: false)
    }

    private func refreshOpenCode(requiresFreshRequest: Bool) async {
        guard !isRefreshingOpenCode else {
            return
        }
        isRefreshingOpenCode = true
        openCodeCredentialMessage = "Refreshing OpenCode Go + Zen..."
        defer { isRefreshingOpenCode = false }

        flushPendingChanges()
        let credentialRevision = metricsCredentialRevision
        let result = requiresFreshRequest
            ? await onCredentialRefresh(configuration)
            : await onAccountRefresh(configuration)
        if requiresFreshRequest {
            completeCredentialRefresh(revision: credentialRevision)
        }
        guard credentialRevision == metricsCredentialRevision else { return }
        guard let result else {
            openCodeCredentialMessage = "Refresh finished. Check the dashboard."
            return
        }
        acceptUsageResult(result)
        let usageContext = result.usageMessages.isEmpty
            ? ""
            : " \(result.usageMessages.joined(separator: " "))"
        if !result.bars.isEmpty, result.creditsRemaining != nil {
            openCodeCredentialMessage = "OpenCode Go usage and Zen balance refreshed.\(usageContext)"
        } else if !result.bars.isEmpty {
            openCodeCredentialMessage = "OpenCode Go usage refreshed.\(usageContext)"
        } else if let balance = result.creditsRemaining {
            let formatted = Self.openCodeBalanceFormatter.string(from: NSNumber(value: balance)) ?? "$\(balance)"
            openCodeCredentialMessage = "OpenCode Zen balance refreshed: \(formatted)\(usageContext)"
        } else {
            openCodeCredentialMessage = result.subtitle
        }
    }

    private func loadMetricsIfNeeded() async {
        if let usageResult {
            acceptUsageResult(usageResult)
            return
        }
        guard configurationStore.isConfigured(configuration) else {
            return
        }
        await refreshMetrics()
    }

    private func acceptUsageResult(_ result: ProviderUsageResult) {
        guard result.accountID == accountID else {
            return
        }
        usageResult = result
        configurationStore.reconcileMetricLayout(
            accountID: accountID,
            availableMetricIDs: result.configurableMetrics.map(\.id)
        )
    }

    private func updateCredentialValidationFeedback(with result: ProviderUsageResult) {
        guard let feedback = credentialValidationFeedback else { return }
        if let failureMessage = result.failureMessage {
            if result.recoveryAction == .reauthenticate || result.recoveryAction == .signIn {
                credentialMessage = nil
                credentialError = feedback.authenticationFailurePrefix + failureMessage
            } else {
                credentialError = nil
                credentialMessage = feedback.transientFailurePrefix + failureMessage
            }
        } else {
            credentialError = nil
            credentialMessage = feedback.validatedMessage
        }
    }

    func saveCopilotCredential() async {
        isSigningInWithCopilot = true
        credentialError = nil
        copilotAuthError = nil
        defer { isSigningInWithCopilot = false }

        do {
            let token = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            let username = try await copilotUsageProvider.fetchUsername(accessToken: token)
            guard let username, !username.isEmpty else {
                copilotAuthError = "GitHub token could not be verified for Copilot access."
                return
            }

            var updated = configuration
            updateCopilotAccountLabel(&updated, username: username)
            updated.authMethod = .cliToken
            let credentials = CopilotCredentials(accessToken: token, username: username)
            let storedCredential = CopilotCredentialsParser.storedCredential(from: credentials)
            guard persistCredential(storedCredential, with: updated) else {
                copilotAuthError = configurationStore.lastError
                return
            }
            secret = ""
            credentialsDidChange()
        } catch {
            copilotAuthError = error.localizedDescription
        }
    }

    private func signInWithCursor() async {
        isSigningInWithCursor = true
        credentialError = nil
        cursorAuthError = nil
        defer {
            cursorAuthPresenter.finish()
            cursorSignInTask = nil
            isSigningInWithCursor = false
        }

        do {
            let result = try await cursorAuthService.signIn { url in
                self.cursorAuthPresenter.present(url: url, prefersEphemeralSession: true) {
                    self.cursorSignInTask?.cancel()
                }
            }
            try Task.checkCancellation()
            flushPendingChanges()
            guard let connected = configurationStore.connectCursorAccount(
                configuration,
                credential: result.storedCredential
            ) else {
                cursorAuthError = configurationStore.lastError
                return
            }
            configuration = connected
            secret = ""
            credentialsDidChange()
        } catch {
            cursorAuthError = Task.isCancelled
                ? "Cursor sign-in canceled. The existing account was not changed."
                : error.localizedDescription
        }
    }

    private func debugAutostartCopilotAuthIfNeeded() async {
        #if DEBUG
        guard providerID == .copilot,
              !debugAutostartedCopilotAuth,
              ProcessInfo.processInfo.environment["CODEXBAR_DEBUG_AUTOSTART_COPILOT_AUTH"] == "1"
        else { return }

        debugAutostartedCopilotAuth = true
        await Task.yield()
        await signInWithCopilot()
        #endif
    }

    private func credentialsDidChange(refreshMetrics: Bool = true) {
        onCredentialsChanged()
        requestCredentialMetricsRefresh(refreshMetrics: refreshMetrics)
    }

    private func requestCredentialMetricsRefresh(refreshMetrics: Bool = true) {
        usageResult = nil
        metricsCredentialRevision += 1
        isCredentialRefreshPending = refreshMetrics
        guard refreshMetrics else { return }
        if isLoadingMetrics {
            needsCredentialMetricsRefresh = true
            return
        }
        Task { @MainActor [weak self] in
            await self?.refreshMetrics(allowUnconfiguredAccount: true, requiresFreshRequest: true)
        }
    }

    private func completeCredentialRefresh(revision: Int) {
        guard revision == metricsCredentialRevision else { return }
        isCredentialRefreshPending = false
    }

    private func updateConfiguration(
        _ updated: ProviderAccountConfiguration,
        persistence: PersistenceBehavior
    ) {
        let shouldValidateSavedCredential = credentialValidationFeedback != nil
            && !configuration.isEnabled
            && updated.isEnabled
            && showsCredentialValidationFeedback
        let didChangeRefreshInputs = refreshInputsChanged(from: configuration, to: updated)
        configuration = updated
        if didChangeRefreshInputs {
            onRefreshInputsChanged()
        }
        switch persistence {
        case .immediate:
            pendingPersistenceTask?.cancel()
            pendingPersistenceTask = nil
            pendingConfiguration = nil
            _ = configurationStore.update(updated)
        case .debounced:
            pendingConfiguration = updated
            pendingPersistenceTask?.cancel()
            pendingPersistenceTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(350))
                } catch {
                    return
                }
                self?.flushPendingChanges()
            }
        }
        if shouldValidateSavedCredential, let feedback = credentialValidationFeedback {
            onCredentialsChanged()
            credentialError = nil
            credentialMessage = feedback.validatingMessage
            requestCredentialMetricsRefresh()
        }
    }

    @discardableResult
    private func persist(_ updated: ProviderAccountConfiguration) -> Bool {
        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = nil
        pendingConfiguration = nil
        configuration = updated
        return configurationStore.update(updated)
    }

    private func persistSecret(_ secret: String) -> Bool {
        configurationStore.saveSecret(secret, for: configuration)
    }

    private func persistCredential(
        _ credential: String,
        with updated: ProviderAccountConfiguration
    ) -> Bool {
        flushPendingChanges()
        guard configurationStore.replaceCredential(credential, for: updated) else {
            return false
        }
        configuration = configurationStore.configuration(accountID: updated.id) ?? updated
        return true
    }

    private func normalizedConfiguration(_ configuration: ProviderAccountConfiguration) -> ProviderAccountConfiguration {
        var normalized = configuration
        if [.codex, .githubBilling, .claude, .grok, .xSubscription, .cursor, .gemini, .openCodeZen].contains(configuration.providerID) {
            normalized.authMethod = .browserSession
        }
        return normalized
    }

    private func updateCopilotAccountLabel(
        _ configuration: inout ProviderAccountConfiguration,
        username: String
    ) {
        if configuration.copilotAccountScope == .personal {
            configuration.accountLabel = username
        } else if configuration.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            configuration.accountLabel = configuration.githubOrganization.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func allotmentText(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
    }

    private func parsedAllotment(_ value: String) -> Double? {
        let normalized = value.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : Double(normalized)
    }

    private func refreshInputsChanged(
        from current: ProviderAccountConfiguration,
        to updated: ProviderAccountConfiguration
    ) -> Bool {
        current.isEnabled != updated.isEnabled
            || current.authMethod != updated.authMethod
            || current.oauthClientID != updated.oauthClientID
            || current.copilotAccountScope != updated.copilotAccountScope
            || current.githubOrganization != updated.githubOrganization
            || current.githubEnterprise != updated.githubEnterprise
            || current.copilotTotalAllotment != updated.copilotTotalAllotment
            || current.githubBillingAccountScope != updated.githubBillingAccountScope
            || current.githubBillingOwner != updated.githubBillingOwner
            || current.openCodeWorkspaceId != updated.openCodeWorkspaceId
    }

    private func debugPrepareGitHubBillingSelectionIfNeeded() {
        #if DEBUG
        guard providerID == .githubBilling,
              let selection = ProcessInfo.processInfo.environment["CODEXBAR_DEBUG_GITHUB_BILLING_SELECTION"]
        else { return }
        pendingGitHubBillingAuthResult = GitHubBillingWebAuthResult(accessToken: "synthetic-github-billing-token")
        githubBillingAccountOptions = [
            GitHubBillingAccountOption(scope: .personal, owner: "octocat", role: "owner"),
            GitHubBillingAccountOption(scope: .organization, owner: "Example-Engineering", role: "admin"),
        ]
        let selectedScope: GitHubBillingAccountScope = selection == "organization" ? .organization : .personal
        selectedGitHubBillingAccountID = githubBillingAccountOptions.first { $0.scope == selectedScope }?.id ?? ""
        githubBillingMessage = "Choose the personal account or eligible organization to monitor."
        #endif
    }

    private static let openCodeBalanceFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}
