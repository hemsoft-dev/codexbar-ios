import SwiftUI
import SafariServices

struct ProviderSettingsView: View {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    @StateObject private var viewModel: ProviderSettingsViewModel
    private let latestUsageResult: ProviderUsageResult?
    private let greptileAccountDestination: (String) -> ProviderSettingsView
    @State private var newGreptileAccountID: String?
    private let startsCursorSignIn: Bool
    @State private var didAutoStartCursorSignIn = false
    @State private var pendingGeminiConfirmation: GeminiConfirmation?
    @State private var isConfirmingGoogleAccount = false
    @State private var isChoosingCodexBrowser = false

    private enum GeminiConfirmation {
        case codingSignIn
        case legacyLink(ProviderAccountConfiguration)
        case appsReconnect
    }

    init(
        configurationStore: ProviderConfigurationStore,
        accountID: String,
        initialUsageResult: ProviderUsageResult? = nil,
        startsCursorSignIn: Bool = false,
        onCredentialsChanged: @escaping @MainActor (String) -> Void = { _ in },
        onRefreshInputsChanged: @escaping @MainActor (String) -> Void = { _ in },
        onAccountIdentityChanged: @escaping @MainActor (String) -> Void = { _ in },
        onAccountRefresh: @escaping @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult? = { _ in nil },
        onCredentialRefresh: (@MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult?)? = nil
    ) {
        self.configurationStore = configurationStore
        self.latestUsageResult = initialUsageResult
        self.startsCursorSignIn = startsCursorSignIn
        self.greptileAccountDestination = { newID in
            ProviderSettingsView(
                configurationStore: configurationStore, accountID: newID,
                onCredentialsChanged: onCredentialsChanged, onRefreshInputsChanged: onRefreshInputsChanged,
                onAccountIdentityChanged: onAccountIdentityChanged, onAccountRefresh: onAccountRefresh,
                onCredentialRefresh: onCredentialRefresh
            )
        }
        self._viewModel = StateObject(
            wrappedValue: ProviderSettingsViewModel(
                configurationStore: configurationStore,
                accountID: accountID,
                initialUsageResult: initialUsageResult,
                onCredentialsChanged: { onCredentialsChanged(accountID) },
                onRefreshInputsChanged: { onRefreshInputsChanged(accountID) },
                onAccountIdentityChanged: { onAccountIdentityChanged(accountID) },
                onAccountRefresh: onAccountRefresh,
                onCredentialRefresh: onCredentialRefresh
            )
        )
    }

    var body: some View {
        let configuration = viewModel.configuration

        Form {
            if [.claude, .grok].contains(providerID), configurationStore.hasSecret(for: configuration) {
                Section("Subscription billing") {
                    Button(configurationStore.hasSubscriptionBillingSession(for: configuration) ? "Reconnect Billing" : "Connect Billing") {
                        viewModel.startSubscriptionBillingSignIn()
                    }
                    .accessibilityIdentifier("subscription-billing-connect")
                    .disabled(viewModel.isClaudeOrganizationBilling)
                    Text(providerID == .claude
                         ? "Personal Claude Pro and Max web billing is supported. Store purchases and Team/Enterprise billing are unavailable. "
                            + "Connect the same account; billing sign-in is separate from usage."
                         : "Connect the same personal SuperGrok commerce account to show its renewal date. X and API billing are separate.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if configurationStore.hasSubscriptionBillingSession(for: configuration) {
                        Button("Disconnect Billing", role: .destructive) { viewModel.disconnectSubscriptionBilling() }
                            .accessibilityIdentifier("subscription-billing-disconnect")
                    }
                    if providerID == .claude, let problem = viewModel.usageResult?.subscriptionBillingProblem,
                       problem.accountID == configuration.id {
                        Text(problem.reason.message).font(.footnote)
                    }
                    if providerID == .claude {
                        Link("View Claude Billing", destination: URL(string: "https://claude.ai/settings/billing")!)
                    }
                    if let message = viewModel.subscriptionBillingMessage {
                        Text(message).font(.footnote).accessibilityIdentifier("subscription-billing-message")
                    }
                }
            }
            Section {
                Toggle("Enabled", isOn: viewModel.binding(for: \.isEnabled))
                Toggle("Show History", isOn: viewModel.binding(for: \.showsHistory))

                TextField(
                    "Account label",
                    text: viewModel.binding(for: \.accountLabel, persistence: .debounced)
                )
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                .accessibilityIdentifier("account-label")

                Picker("Group", selection: viewModel.binding(for: \.groupID)) {
                    Text(ProviderAccountGroup.ungroupedDisplayName).tag(Optional<String>.none)
                    ForEach(configurationStore.groups) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }

                .accessibilityIdentifier("account-group-picker")
                .accessibilityValue(configurationStore.groupName(for: configuration.groupID))

                Picker("Auth method", selection: viewModel.binding(for: \.authMethod)) {
                    ForEach(availableAuthMethods) { method in
                        Text(authMethodDisplayName(method)).tag(method)
                    }
                }

                if providerID == .copilot {
                    Picker("Account type", selection: viewModel.binding(for: \.copilotAccountScope)) {
                        ForEach(CopilotAccountScope.allCases) { scope in
                            Text(scope.displayName).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)

                    if configuration.copilotAccountScope == .organization {
                        TextField(
                            "Organization",
                            text: viewModel.binding(for: \.githubOrganization, persistence: .debounced)
                        )
                            .textContentType(.organizationName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        TextField(
                            "Enterprise (optional)",
                            text: viewModel.binding(for: \.githubEnterprise, persistence: .debounced)
                        )
                            .textContentType(.organizationName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        TextField("Total allotment (optional)", text: viewModel.copilotAllotmentBinding)
                            .keyboardType(.decimalPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
            }

            Section {
                if providerID == .codex {
                    Button {
                        isChoosingCodexBrowser = true
                    } label: {
                        if viewModel.isSigningInWithCodex {
                            ProgressView()
                        } else {
                            Text(viewModel.codexSignInButtonTitle)
                        }
                    }
                    .disabled(viewModel.isSigningInWithCodex)
                    .alert("Choose how to sign in", isPresented: $isChoosingCodexBrowser) {
                        Button("Use browser sign-in") { viewModel.startCodexSignIn(mode: .existingSession) }
                        Button("Use private sign-in") { viewModel.startCodexSignIn(mode: .privateSession) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Choose the intended ChatGPT account. CodexBar checks its identity before saving.")
                    }

                    Text(
                        "Browser sign-in can use accounts already signed in on this device. "
                            + "Private sign-in starts a separate session. If Google does not recognize "
                            + "the private session, try browser sign-in and choose the intended ChatGPT account. "
                            + "Google may still require identity verification."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    if configurationStore.hasSecret(for: configuration) {
                        Button("Sign Out", role: .destructive) {
                            viewModel.removeSavedCredential()
                        }
                    }

                    if let codexAuthError = viewModel.codexAuthError {
                        Text(codexAuthError)
                            .foregroundStyle(.red)
                    }
                } else if providerID == .copilot {
                    Button {
                        Task {
                            await viewModel.signInWithCopilot()
                        }
                    } label: {
                        if viewModel.isSigningInWithCopilot {
                            ProgressView()
                        } else {
                            Text(configurationStore.hasSecret(for: configuration) ? "Sign in Again" : "Sign in with GitHub")
                        }
                    }
                    .disabled(viewModel.isSigningInWithCopilot)

                    if configuration.authMethod == .cliToken {
                        SecureField(copilotSecretPlaceholder, text: $viewModel.secret)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Button {
                            Task {
                                await viewModel.saveCopilotCredential()
                            }
                        } label: {
                            if viewModel.isSigningInWithCopilot {
                                ProgressView()
                            } else {
                                Text(configurationStore.hasSecret(for: configuration) ? "Update Token" : "Save Token")
                            }
                        }
                        .disabled(viewModel.isSigningInWithCopilot || viewModel.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if configurationStore.hasSecret(for: configuration) {
                        Button("Sign Out", role: .destructive) {
                            viewModel.removeSavedCredential()
                        }
                    }

                    if let copilotAuthError = viewModel.copilotAuthError {
                        Text(copilotAuthError)
                            .foregroundStyle(.red)
                    }
                } else if providerID == .githubBilling {
                    Button {
                        viewModel.startGitHubBillingSignIn()
                    } label: {
                        if viewModel.isSigningInWithGitHubBilling && viewModel.githubBillingAccountOptions.isEmpty {
                            ProgressView()
                        } else {
                            Text(configurationStore.hasSecret(for: configuration) ? "Sign in Again with GitHub" : "Sign in with GitHub")
                        }
                    }
                    .disabled(viewModel.isSigningInWithGitHubBilling)
                    .accessibilityIdentifier("github-billing-sign-in")

                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            "Requested GitHub permissions: private repository access (GitHub's classic repo scope), "
                                + "organization administration (classic admin:org), user plan, billing usage, and "
                                + "organization budgets.",
                            systemImage: "lock.shield"
                        )
                        Text(
                            "Personal billing requires GitHub's user scope. It permits profile changes, reading private "
                                + "email addresses, and following or unfollowing users. CodexBar only reads your plan and "
                                + "billing data and never changes your profile or follows."
                        )
                        Text(
                            "The repo scope permits repository changes, and admin:org permits organization and team "
                                + "changes. CodexBar only reads repository visibility and organization plan details; "
                                + "it never changes repositories, organizations, or teams. Billing tokens stay in "
                                + "separate Keychain entries and are never shared with GitHub Copilot."
                        )
                        Text(
                            "If you signed in before these permissions were added, sign in again and approve user "
                                + "and organization administration access before reconnecting a personal or "
                                + "organization account."
                        )
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("github-billing-permission-disclosure")

                    if !viewModel.githubBillingAccountOptions.isEmpty {
                        Picker("Account to monitor", selection: $viewModel.selectedGitHubBillingAccountID) {
                            ForEach(viewModel.githubBillingAccountOptions) { option in
                                Text(option.displayName).tag(option.id)
                            }
                        }
                        .accessibilityIdentifier("github-billing-account-picker")

                        Button("Connect Selected Account") {
                            viewModel.startGitHubBillingAccountConnection()
                        }
                        .disabled(
                            viewModel.isSigningInWithGitHubBilling
                                || viewModel.selectedGitHubBillingAccountID.isEmpty
                        )
                        .accessibilityIdentifier("github-billing-connect-account")
                    }

                    if configurationStore.hasSecret(for: configuration) {
                        Text(
                            configuration.githubBillingAccountScope == .personal
                                ? "Monitoring personal account \(configuration.githubBillingOwner). GitHub does not expose a personal budget through the public API."
                                : "Monitoring organization \(configuration.githubBillingOwner). Budgets are read-only."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                        Button("Disconnect GitHub Billing", role: .destructive) {
                            viewModel.removeSavedCredential()
                        }
                    }

                    if let githubBillingMessage = viewModel.githubBillingMessage {
                        Text(githubBillingMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("github-billing-message")
                    }

                    if let githubBillingAuthError = viewModel.githubBillingAuthError {
                        Text(githubBillingAuthError)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("github-billing-error")
                    }
                } else if providerID == .claude {
                    Button {
                        Task {
                            await viewModel.signInWithClaude()
                        }
                    } label: {
                        if viewModel.isSigningInWithClaude {
                            ProgressView()
                        } else {
                            Text(configurationStore.hasSecret(for: configuration) ? "Sign in Again" : "Sign in with Claude")
                        }
                    }
                    .disabled(viewModel.isSigningInWithClaude)

                    if let claudeAuthDiagnostic = viewModel.claudeAuthDiagnostic {
                        Text(claudeAuthDiagnostic)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if configurationStore.hasSecret(for: configuration) {
                        Button("Sign Out", role: .destructive) {
                            viewModel.removeSavedCredential()
                        }
                    }

                    if let claudeAuthError = viewModel.claudeAuthError {
                        Text(claudeAuthError)
                            .foregroundStyle(.red)
                    }
                } else if providerID == .grok {
                    Button(configurationStore.hasSecret(for: configuration) ? "Reconnect Grok" : "Sign in with Grok") {
                        viewModel.startGrokSignIn()
                    }
                    .disabled(viewModel.isSigningInWithGrok)
                    .accessibilityIdentifier("grok-sign-in")

                    if viewModel.isSigningInWithGrok {
                        ProgressView("Waiting for Grok approval...")
                        Button("Cancel Sign-In") { viewModel.cancelGrokSignIn() }
                    }
                    Text("Choose your Grok account in the browser. CodexBar reads consumer usage only; "
                        + "it never purchases credits or links accounts. Tokens stay on this device in Keychain. "
                        + "Grok Bot usage from Cursor remains separate.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if configurationStore.hasSecret(for: configuration) {
                        Button("Disconnect Grok", role: .destructive) {
                            viewModel.removeSavedCredential()
                        }
                    }
                    if let grokMessage = viewModel.grokMessage {
                        Text(grokMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("grok-sign-in-status")
                    }
                } else if providerID == .cursor {
                    Button {
                        viewModel.startCursorSignIn()
                    } label: {
                        if viewModel.isSigningInWithCursor {
                            ProgressView()
                        } else {
                            Text(viewModel.usageResult?.recoveryAction == .reauthenticate
                                 ? "Reconnect Cursor"
                                 : configurationStore.hasSecret(for: configuration) ? "Switch Cursor Account" : "Sign in with Cursor")
                        }
                    }
                    .disabled(viewModel.isSigningInWithCursor)

                    if configurationStore.hasSecret(for: configuration) {
                        Button("Sign Out", role: .destructive) {
                            viewModel.signOutOfCursor()
                        }
                    }

                    if let cursorAuthError = viewModel.cursorAuthError {
                        Text(cursorAuthError)
                            .foregroundStyle(.red)
                    }
                } else if providerID == .gemini {
                    geminiAppsConnection
                } else if providerID == .greptile {
                    if configuration.authMethod == .apiKey, configurationStore.hasSecret(for: configuration) {
                        Text("Keep this API-key account's review history. Add a separate account to sign in to Greptile.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Add Greptile account") {
                            let account = configurationStore.addAccount(for: .greptile)
                            if configurationStore.configuration(accountID: account.id) != nil { newGreptileAccountID = account.id }
                        }
                    } else {
                        Button(configurationStore.hasSecret(for: configuration) ? "Reconnect Greptile" : "Sign in to Greptile") {
                            viewModel.startGreptileSignIn()
                        }
                        .disabled(viewModel.isSigningInWithGreptile)
                        .accessibilityIdentifier("greptile-account-sign-in")
                    }
                    if viewModel.isSigningInWithGreptile {
                        ProgressView("Connecting to Greptile…")
                        Button("Cancel Sign-In") { viewModel.cancelGreptileSignIn() }
                    }
                    if configurationStore.hasSecret(for: configuration) {
                        Button("Disconnect Greptile", role: .destructive) { viewModel.removeSavedCredential() }
                    }
                    Text("Sign in and choose your organization to connect your Greptile account. Your account session stays in Keychain.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if providerID == .openCodeZen {
                    Button(configurationStore.hasSecret(for: configuration) ? "Reconnect OpenCode" : "Sign in with OpenCode") {
                        viewModel.startOpenCodeSignIn()
                    }
                    .disabled(viewModel.isSigningInWithOpenCode)

                    if viewModel.isSigningInWithOpenCode {
                        ProgressView("Connecting to OpenCode...")
                        Button("Cancel Sign-In") { viewModel.cancelOpenCodeSignIn() }
                    }

                    if configurationStore.hasSecret(for: configuration) {
                        Button {
                            Task {
                                await viewModel.refreshOpenCode()
                            }
                        } label: {
                            if viewModel.isRefreshingOpenCode {
                                ProgressView()
                            } else {
                                Label("Refresh Now", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(viewModel.isRefreshingOpenCode)
                    }

                    if configurationStore.hasSecret(for: configuration) {
                        Button("Remove Saved Credential", role: .destructive) {
                            viewModel.removeSavedCredential(message: "Disconnected on this device. Sign in to reconnect. Provider access was not revoked.")
                        }
                    }

                    Text(
                        "Choose browser or private sign-in, then your OpenCode workspace to track Go usage and Zen balance. "
                            + "Your session stays in this account's Keychain entry. Removing it disconnects only this device."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    if let openCodeCredentialMessage = viewModel.openCodeCredentialMessage {
                        Text(openCodeCredentialMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if configuration.requiresSecret {
                    SecureField(secretPlaceholder, text: $viewModel.secret)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button(viewModel.credentialPresentation.saveButtonTitle) {
                        viewModel.saveGenericCredential()
                    }
                    .disabled(viewModel.secret.isEmpty)

                    if configurationStore.hasSecret(for: configuration) {
                        Button("Remove Saved Credential", role: .destructive) {
                            viewModel.removeSavedCredential()
                        }
                    }

                    if let setupMessage = viewModel.credentialPresentation.setupMessage {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(setupMessage, systemImage: "key")

                            if
                                let setupLinkTitle = viewModel.credentialPresentation.setupLinkTitle,
                                let setupURL = viewModel.credentialPresentation.setupURL {
                                Link(setupLinkTitle, destination: setupURL)
                            }

                            if let securityMessage = viewModel.credentialPresentation.securityMessage {
                                Label(securityMessage, systemImage: "lock.shield")
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text(nonSecretAuthText)
                        .foregroundStyle(.secondary)
                }

                if let credentialError = viewModel.credentialError {
                    Text(credentialError)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("credential-error")
                } else if let credentialMessage = viewModel.credentialMessage {
                    Label(credentialMessage, systemImage: viewModel.credentialMessageSystemImage)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("credential-message")
                }
            } header: {
                Text(viewModel.credentialPresentation.sectionTitle)
            }

            if providerID == .gemini {
                geminiCodingConnection
            }

            Section {
                if let description = GoogleUsageMetricCatalog.setupDescription(for: providerID) {
                    Text(description)
                        .font(.subheadline)
                        .accessibilityIdentifier("google-quota-source-guide")
                }
                if viewModel.isLoadingMetrics {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading discovered metrics…")
                            .foregroundStyle(.secondary)
                    }
                } else if viewModel.availableMetrics.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(viewModel.metricsEmptyStateMessage)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("account-metrics-empty-state")

                        Button {
                            Task {
                                await viewModel.refreshMetrics()
                            }
                        } label: {
                            Label("Refresh Metrics", systemImage: "arrow.clockwise")
                        }
                        .disabled(!viewModel.canRefreshMetrics)
                    }
                } else {
                    ForEach(viewModel.availableMetrics) { metric in
                        let accessibilityStatus = if case let .unavailableUsage(reason) = metric.kind {
                            ". \(reason)"
                        } else {
                            ""
                        }
                        Toggle(isOn: Binding(
                                get: { viewModel.isMetricVisible(metric.id) },
                                set: { viewModel.setMetricVisibility($0, metricID: metric.id) }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(metric.label)
                                if case let .unavailableUsage(reason) = metric.kind {
                                    Text(reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityLabel("Show \(metric.label) on dashboard\(accessibilityStatus)")
                        .accessibilityIdentifier("account-metric-visibility-\(metric.id)")
                    }
                }
            } header: {
                Text("Metrics")
            } footer: {
                if !viewModel.availableMetrics.isEmpty {
                    Text("Changes apply immediately and stay in sync with Customize Card.")
                }
            }

            Section {
                Text(providerID == .cursor && viewModel.usageResult?.recoveryAction == .reauthenticate
                     ? "Cursor sign-in needs reconnection. Last known usage is not current."
                     : configurationStore.statusText(for: configuration))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Current Status")
            }
        }
        .accessibilityIdentifier("provider-account-settings-form")
        .navigationTitle(configuration.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if startsCursorSignIn && !didAutoStartCursorSignIn {
                didAutoStartCursorSignIn = true
                viewModel.startCursorSignIn()
            }
            await viewModel.prepare()
        }
        .onChange(of: latestUsageResult) { _, result in
            viewModel.synchronizeUsageResult(result)
        }
        .onDisappear {
            viewModel.flushPendingChanges()
            viewModel.cancelAuthentication()
        }
        #if DEBUG
        .sheet(item: $viewModel.cursorFixtureStage) { _ in
            NavigationStack {
                Form {
                    Section {
                        Text("Choose the sample Cursor account to reconnect.")
                        Button("Use sample Cursor account") { viewModel.approveSyntheticCursorSignIn() }
                            .accessibilityIdentifier("cursor-synthetic-approve")
                    } footer: {
                        Text("Simulator fixture. No live Cursor account is accessed.")
                    }
                }
                .navigationTitle("Synthetic Cursor sign-in")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { viewModel.cancelSyntheticCursorSignIn() }
                    }
                }
            }
        }
        .sheet(item: $viewModel.grokFixtureStage) { stage in
            GrokSyntheticApprovalView(
                stage: stage,
                approve: { viewModel.completeSyntheticGrokSignIn() },
                reject: { viewModel.rejectSyntheticGrokSignIn() },
                finish: { viewModel.finishSyntheticGrokSignIn() }
            )
        }
        #endif
        .sheet(item: $viewModel.subscriptionBillingSession, onDismiss: { viewModel.cancelSubscriptionBillingSignIn() }, content: { session in
            SubscriptionBillingSignInView(session: session)
        })
        .sheet(item: $viewModel.openCodeBrowserSession) { session in
            OpenCodeBrowserSignInView(session: session)
        }
        .navigationDestination(item: $newGreptileAccountID) { greptileAccountDestination($0) }
        .sheet(item: $viewModel.greptileBrowserSession) { session in
            GreptileBrowserSignInView(session: session)
        }
        .sheet(item: $viewModel.geminiBrowserSession, onDismiss: {
            if viewModel.needsGeminiAccountConfirmation { requestGeminiConfirmation(.appsReconnect) }
        }, content: { session in
            GeminiBrowserSignInView(session: session)
        })
        .sheet(item: $viewModel.authURL, onDismiss: {
            viewModel.authenticationSheetDismissed()
        }, content: { authURL in
            SafariAuthSheet(url: authURL.url)
        })
        .onChange(of: viewModel.needsGoogleCodingAccountConfirmation) { _, needed in
            if needed { requestGeminiConfirmation(.codingSignIn) }
        }
        .alert("Confirm Google Account", isPresented: $isConfirmingGoogleAccount) {
            Button("Same Google Account") { confirmGeminiAction() }
            Button("Cancel", role: .cancel) {
                if case .some(.codingSignIn) = pendingGeminiConfirmation {
                    viewModel.cancelGoogleCodingSignIn()
                }
                if case .some(.appsReconnect) = pendingGeminiConfirmation {
                    viewModel.cancelGeminiSignIn()
                }
                pendingGeminiConfirmation = nil
            }
        } message: {
            Text(geminiConfirmationMessage)
        }
    }

    private var geminiAppsConnection: some View {
        Group {
            Button(configurationStore.hasSecret(for: viewModel.configuration) ? "Sign in Again with Google" : "Sign in with Google") {
                viewModel.startGeminiSignIn()
            }
            .disabled(viewModel.isSigningInWithGemini)
            if viewModel.isSigningInWithGemini {
                ProgressView("Connecting Gemini Apps")
                Button("Cancel Sign-In") { viewModel.cancelGeminiSignIn() }
            }
            Text("Connect Gemini Apps in a private Google sign-in window to read its five-hour and weekly limits.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Google session credentials may grant broader account access. "
                + "CodexBar saves only the session values needed for usage in this account's Keychain entry.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if configurationStore.hasSecret(for: viewModel.configuration) {
                Button("Disconnect Gemini Apps", role: .destructive) {
                    viewModel.removeSavedCredential()
                }
            }
        }
    }

    private var geminiCodingConnection: some View {
        Section("Coding Usage") {
            Text("Connect Gemini Models and Other models, Claude/GPT, to show their four coding limits in this Gemini account.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(configurationStore.hasGeminiCodingSecret(for: viewModel.configuration) ? "Reconnect Coding Usage" : "Connect Coding Usage") {
                viewModel.startGoogleCodingSignIn()
            }
            .disabled(viewModel.isSigningInWithGoogleCoding)
            if viewModel.isSigningInWithGoogleCoding {
                ProgressView("Waiting for Google…")
                Button("Cancel Sign-In") { viewModel.cancelGoogleCodingSignIn() }
            }
            Text("Choose the same Google account to connect your coding limits. You will return here automatically.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if configurationStore.hasGeminiCodingSecret(for: viewModel.configuration) {
                Button("Disconnect Coding Session", role: .destructive) {
                    viewModel.disconnectGeminiCoding()
                }
            }
            if !configurationStore.unlinkedGeminiCodingAccounts.isEmpty {
                Text("Previously saved coding accounts are retained until you confirm which Gemini account they belong to.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(configurationStore.unlinkedGeminiCodingAccounts) { legacy in
                    Button("Link saved coding account: \(legacy.displayName)") {
                        requestGeminiConfirmation(.legacyLink(legacy))
                    }
                    .accessibilityIdentifier("gemini-link-coding-\(legacy.id)")
                }
            }
            if let message = viewModel.geminiCodingMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("gemini-coding-message")
            }
        }
    }

    private var geminiConfirmationMessage: String {
        switch pendingGeminiConfirmation {
        case .appsReconnect:
            "Confirm that the Google account you just selected is the same as the coding session linked to \(viewModel.configuration.displayName). "
                + "To use a different Google identity, add another Gemini account."
        case .legacyLink(let legacy):
            "Confirm that the saved coding account \(legacy.displayName) and \(viewModel.configuration.displayName) "
                + "belong to the same Google account. CodexBar cannot verify this identity automatically."
        case .codingSignIn, nil:
            "Confirm that the Google account you just selected is the same account used for \(viewModel.configuration.displayName). "
                + "CodexBar cannot verify this identity automatically."
        }
    }

    private func requestGeminiConfirmation(_ confirmation: GeminiConfirmation) {
        pendingGeminiConfirmation = confirmation
        isConfirmingGoogleAccount = true
    }

    private func confirmGeminiAction() {
        switch pendingGeminiConfirmation {
        case .codingSignIn:
            viewModel.confirmGoogleCodingAccount()
        case .legacyLink(let legacy):
            viewModel.linkGeminiCodingAccount(legacy, confirmedSameAccount: true)
        case .appsReconnect:
            viewModel.confirmGeminiAppsAccount()
        case nil:
            break
        }
        pendingGeminiConfirmation = nil
    }

    private var secretPlaceholder: String {
        if providerID == .openCodeZen {
            return configurationStore.hasSecret(for: viewModel.configuration)
                ? "OpenCode dashboard auth value saved"
                : "Paste OpenCode dashboard auth value"
        }

        let presentation = viewModel.credentialPresentation
        return configurationStore.hasSecret(for: viewModel.configuration)
            ? presentation.savedPlaceholder
            : presentation.unsavedPlaceholder
    }

    private var copilotSecretPlaceholder: String {
        configurationStore.hasSecret(for: viewModel.configuration)
            ? "GitHub token saved"
            : "Paste GitHub token"
    }

    private var providerID: ProviderID {
        viewModel.providerID
    }

    private var availableAuthMethods: [ProviderAuthMethod] {
        viewModel.availableAuthMethods
    }

    private func authMethodDisplayName(_ method: ProviderAuthMethod) -> String {
        if providerID == .openCodeZen, method == .apiKey {
            return "Dashboard Session"
        }
        return method.displayName
    }

    private var nonSecretAuthText: String {
        switch viewModel.configuration.authMethod {
        case .browserSession:
            "Sign in through the browser to connect this account."
        case .apiKey, .cliToken:
            "Paste a credential to save it in Keychain."
        }
    }

}

enum ProviderSignInAccessibility {
    static func hint(providerID: ProviderID, title: String, reconnecting: Bool) -> String {
        if providerID == .cursor { return "Starts private Cursor sign-in for \(title)" }
        if providerID == .claude {
            return reconnecting ? "Replaces the rejected Claude credential for \(title)" : "Starts Claude sign-in for \(title)"
        }
        return reconnecting ? "Opens account settings to replace credentials for \(title)" : "Opens account settings for \(title)"
    }
}

struct CursorStaleUsageNotice: View {
    let result: ProviderUsageResult
    var body: some View {
        if result.providerID == .cursor && !result.hasCurrentBars && !result.bars.isEmpty {
            Text("Stale usage from \(UserFacingDateTimeFormatter.current.dateAndTime(result.barsFetchedAt ?? result.fetchedAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("cursor-stale-measurement-time")
        }
    }
}

#if DEBUG
private struct GrokSyntheticApprovalView: View {
    let stage: GrokFixtureStage
    let approve: () -> Void
    let reject: () -> Void
    let finish: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "safari").font(.largeTitle)
                Text(stage == .approval ? "Choose a Grok account" : "Grok account connected")
                    .font(.headline)
                Text("Synthetic approval. No live account, browser request, or credentials.")
                    .font(.footnote)
                if stage == .approval {
                    Button("Approve sample account", action: approve)
                        .buttonStyle(.borderedProminent)
                    Button("Decline", action: reject)
                } else {
                    Button("Return to Grok settings", action: finish)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("Grok sign-in")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { reject() }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}
#endif

struct PresentedAuthURL: Identifiable {
    let id = UUID()
    let url: URL

    init(url: URL) {
        self.url = url
    }
}

struct SafariAuthSheet: View {
    let url: URL

    var body: some View {
        SafariAuthView(url: url)
    }
}

struct SafariAuthView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
    }
}

#Preview {
    NavigationStack {
        ProviderSettingsView(configurationStore: ProviderConfigurationStore(), accountID: ProviderID.openRouter.rawValue)
    }
}
