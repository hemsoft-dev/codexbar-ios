import StoreKit
import SwiftUI
import UIKit

struct SettingsHomeLayout: Equatable {
    let attentionDestination: SettingsDestination?
    let routineDestinations: [SettingsDestination]

    init(requiresAttention: Bool) {
        attentionDestination = requiresAttention ? .dataAndRecovery : nil
        routineDestinations = SettingsDestination.allCases.filter {
            !requiresAttention || $0 != .dataAndRecovery
        }
    }
}

struct SettingsRecoveryState: Equatable {
    let hasError: Bool
    let isPersistenceRecoveryRequired: Bool
    let accountCount: Int
    let hasIncompleteAccountReset: Bool

    var requiresAttention: Bool {
        hasError || isPersistenceRecoveryRequired || hasIncompleteAccountReset
    }

    var resetAccountsDisabled: Bool {
        isPersistenceRecoveryRequired
            || (accountCount == 0 && !hasIncompleteAccountReset)
    }

    var summary: String {
        if isPersistenceRecoveryRequired || hasIncompleteAccountReset {
            return "Action required"
        }
        if hasError {
            return "Review settings error"
        }
        return accountCount == 0 ? "No account data" : "Reset and recovery options"
    }
}

enum SettingsGroupValidationTarget: Equatable {
    case existingGroup(String)
    case newGroup
}

struct SettingsGroupValidationState: Equatable {
    private(set) var message: String?
    private(set) var target: SettingsGroupValidationTarget?

    mutating func recordFailure(
        storeError: String?,
        target: SettingsGroupValidationTarget
    ) {
        message = storeError ?? "Could not save the group name."
        self.target = target
    }

    mutating func clear() {
        message = nil
        target = nil
    }
}

struct SettingsPendingGroupChanges: Equatable {
    let draftGroupIDs: [String]
    let newGroupName: String

    static func changedDraftGroupIDs(
        draftNames: [String: String],
        persistedName: (String) -> String?
    ) -> [String] {
        draftNames.compactMap { groupID, draftName in
            guard let savedName = persistedName(groupID) else {
                return nil
            }
            return draftName.trimmingCharacters(in: .whitespacesAndNewlines) == savedName
                ? nil
                : groupID
        }
        .sorted()
    }

    var hasChanges: Bool {
        !draftGroupIDs.isEmpty || !normalizedNewGroupName.isEmpty
    }

    func commitAll(
        commitDraft: (String) -> Bool,
        commitNewGroup: () -> Bool
    ) -> Bool {
        for groupID in draftGroupIDs where !commitDraft(groupID) {
            return false
        }
        return normalizedNewGroupName.isEmpty || commitNewGroup()
    }

    private var normalizedNewGroupName: String {
        newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum SettingsNavigationGuard {
    @discardableResult
    static func perform(
        commitPendingChanges: () -> Bool,
        navigate: () -> Void
    ) -> Bool {
        guard commitPendingChanges() else {
            return false
        }
        navigate()
        return true
    }

    @discardableResult
    static func performCategoryChange(
        from oldDestination: SettingsDestination?,
        to newDestination: SettingsDestination?,
        commitPendingChanges: () -> Bool,
        clearNestedRoute: () -> Void
    ) -> Bool {
        guard oldDestination != newDestination else {
            return true
        }
        if oldDestination == .accountsAndGroups, !commitPendingChanges() {
            return false
        }
        clearNestedRoute()
        return true
    }
}

enum SettingsDoneToolbarLocation {
    case sidebar
    case detail
}

enum SettingsDoneToolbarPolicy {
    static func showsDone(
        in location: SettingsDoneToolbarLocation,
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> Bool {
        location == .detail || horizontalSizeClass == .compact
    }
}

struct SettingsView: View {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    @ObservedObject var appUpdateController: AppUpdateController
    @ObservedObject var githubStatusPreferences: GitHubStatusPreferences
    var onAccountsChanged: @MainActor () -> Void = {}
    var onCredentialsChanged: @MainActor (String) -> Void = { _ in }
    var onRefreshInputsChanged: @MainActor (String) -> Void = { _ in }
    var onAccountIdentityChanged: @MainActor (String) -> Void = { _ in }
    var usageResultForAccount: @MainActor (String) -> ProviderUsageResult? = { _ in nil }
    var onAccountRefresh: @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult? = { _ in nil }
    var onCredentialRefresh: @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult? = { _ in nil }
    var onAlertAuthorizationRequest: @MainActor () async -> Bool = { false }
    var onGitHubStatusRefresh: @MainActor () async -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.requestReview) private var requestReview
    @State private var isConfirmingReset = false
    @State private var isConfirmingConfigurationReplacement = false
    @State private var isConfirmingGroupReplacement = false
    @State private var alertPermissionMessage: String?
    @State private var githubStatusPermissionMessage: String?
    @State private var githubNotificationAuthorization = GitHubStatusNotificationAuthorization()
    @State private var addAccountFlowRequest: AddAccountFlowRequest?
    @State private var addAccountRefreshState = AddAccountRefreshState()
    @State private var newGroupName = ""
    @State private var groupNameDrafts: [String: String] = [:]
    @State private var groupValidationState = SettingsGroupValidationState()
    @State private var selectedAccountID: String?
    @State private var selectedDestination: SettingsDestination?
    @FocusState private var focusedGroupID: String?

    init(
        configurationStore: ProviderConfigurationStore,
        appUpdateController: AppUpdateController,
        githubStatusPreferences: GitHubStatusPreferences,
        initialRoute: SettingsInitialRoute? = nil,
        onAccountsChanged: @escaping @MainActor () -> Void = {},
        onCredentialsChanged: @escaping @MainActor (String) -> Void = { _ in },
        onRefreshInputsChanged: @escaping @MainActor (String) -> Void = { _ in },
        onAccountIdentityChanged: @escaping @MainActor (String) -> Void = { _ in },
        usageResultForAccount: @escaping @MainActor (String) -> ProviderUsageResult? = { _ in nil },
        onAccountRefresh: @escaping @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult? = { _ in nil },
        onCredentialRefresh: (@MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult?)? = nil,
        onAlertAuthorizationRequest: @escaping @MainActor () async -> Bool = { false },
        onGitHubStatusRefresh: @escaping @MainActor () async -> Void = {}
    ) {
        self.configurationStore = configurationStore
        self.appUpdateController = appUpdateController
        self.githubStatusPreferences = githubStatusPreferences
        self.onAccountsChanged = onAccountsChanged
        self.onCredentialsChanged = onCredentialsChanged
        self.onRefreshInputsChanged = onRefreshInputsChanged
        self.onAccountIdentityChanged = onAccountIdentityChanged
        self.usageResultForAccount = usageResultForAccount
        self.onAccountRefresh = onAccountRefresh
        self.onCredentialRefresh = onCredentialRefresh ?? onAccountRefresh
        self.onAlertAuthorizationRequest = onAlertAuthorizationRequest
        self.onGitHubStatusRefresh = onGitHubStatusRefresh
        _selectedDestination = State(initialValue: initialRoute?.destination)
    }

    var body: some View {
        NavigationSplitView {
            settingsHome
                .toolbar {
                    if SettingsDoneToolbarPolicy.showsDone(
                        in: .sidebar,
                        horizontalSizeClass: horizontalSizeClass
                    ) {
                        doneToolbar
                    }
                }
        } detail: {
            NavigationStack {
                selectedSettingsDestination
                    .navigationDestination(item: $selectedAccountID) { accountID in
                        ProviderSettingsView(
                            configurationStore: configurationStore,
                            accountID: accountID,
                            initialUsageResult: usageResultForAccount(accountID),
                            onCredentialsChanged: onCredentialsChanged,
                            onRefreshInputsChanged: onRefreshInputsChanged,
                            onAccountIdentityChanged: onAccountIdentityChanged,
                            onAccountRefresh: onAccountRefresh,
                            onCredentialRefresh: onCredentialRefresh
                        )
                    }
            }
            .toolbar {
                if SettingsDoneToolbarPolicy.showsDone(
                    in: .detail,
                    horizontalSizeClass: horizontalSizeClass
                ) {
                    doneToolbar
                }
            }
        }
        .sheet(
            item: $addAccountFlowRequest,
            onDismiss: {
                guard let accountID = addAccountRefreshState.finishDismissal() else {
                    return
                }
                Task {
                    await refreshAddedAccount(accountID: accountID)
                }
            },
            content: { request in
            AddAccountSetupFlow(
                configurationStore: configurationStore,
                initialProviderID: request.initialProviderID,
                onAccountCreated: { accountID in
                    addAccountRefreshState.accountCreated(accountID)
                },
                onCredentialsChanged: { accountID in
                    _ = addAccountRefreshState.credentialsChanged()
                    onCredentialsChanged(accountID)
                },
                onRefreshInputsChanged: { accountID in
                    addAccountRefreshState.refreshInputsChanged()
                    onRefreshInputsChanged(accountID)
                },
                onAccountRefresh: onAccountRefresh,
                onCredentialRefresh: onCredentialRefresh
                )
            }
        )
        .confirmationDialog(
            "Reset all accounts?",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset Accounts", role: .destructive) {
                let accountIDsBeforeReset = Set(configurationStore.configurations.map(\.id))
                let resetCompleted = configurationStore.resetAccounts()
                let accountIDsAfterReset = Set(configurationStore.configurations.map(\.id))
                if resetCompleted || accountIDsBeforeReset != accountIDsAfterReset {
                    onAccountsChanged()
                }
            }
        } message: {
            Text("This removes account entries and saved provider credentials from this device.")
        }
        .confirmationDialog(
            "Replace unreadable account data?",
            isPresented: $isConfirmingConfigurationReplacement,
            titleVisibility: .visible
        ) {
            Button("Replace Account Data", role: .destructive) {
                if OpenCodeZenBootstrapImporter.replaceCorruptedConfigurationsAndImportIfNeeded(
                    configurationStore: configurationStore
                ) {
                    onAccountsChanged()
                }
            }
        } message: {
            Text(
                "This replaces the damaged account list with an empty list so you can add accounts again. Saved Keychain credentials are not deleted."
            )
        }
        .confirmationDialog(
            "Replace unreadable group data?",
            isPresented: $isConfirmingGroupReplacement,
            titleVisibility: .visible
        ) {
            Button("Replace Group Data", role: .destructive) {
                if OpenCodeZenBootstrapImporter.replaceCorruptedGroupsAndImportIfNeeded(
                    configurationStore: configurationStore
                ) {
                    onAccountsChanged()
                }
            }
        } message: {
            Text(
                "This replaces the damaged group list with an empty list and deliberately ungroups every saved "
                    + "account. Saved accounts and Keychain credentials are not deleted."
            )
        }
        .accountPlanPresentation(
            configurationStore: configurationStore,
            usageResultForAccount: usageResultForAccount,
            isActive: addAccountFlowRequest == nil && selectedAccountID == nil
        )
        .environment(\.accountLastResultProvider, usageResultForAccount)
        .interactiveDismissDisabled(pendingGroupChanges.hasChanges)
        .onChange(of: focusedGroupID) { oldValue, newValue in
            if let oldValue, oldValue != newValue {
                if !commitGroupName(for: oldValue) {
                    focusedGroupID = oldValue
                }
            }
        }
        .onChange(of: selectedDestination) { oldValue, newValue in
            if !SettingsNavigationGuard.performCategoryChange(
                from: oldValue,
                to: newValue,
                commitPendingChanges: commitPendingGroupChanges,
                clearNestedRoute: {
                    selectedAccountID = nil
                }
            ) {
                selectedDestination = oldValue
            }
        }
    }

    @MainActor
    private func refreshAddedAccount(accountID: String) async {
        guard let configuration = configurationStore.configuration(accountID: accountID) else {
            return
        }
        _ = await onAccountRefresh(configuration)
    }

    private var settingsHome: some View {
        let layout = SettingsHomeLayout(requiresAttention: recoveryState.requiresAttention)

        return List(selection: $selectedDestination) {
            Section {
                Button {
                    configurationStore.requestProPresentation(origin: .settings)
                } label: {
                    Label("CodexBar Pro", systemImage: "sparkles")
                }
                .accessibilityIdentifier("settings-codexbar-pro")
            }
            if let attentionDestination = layout.attentionDestination {
                Section("Needs Attention") {
                    settingsCategoryLink(attentionDestination)
                }
            }

            Section {
                ForEach(layout.routineDestinations) { destination in
                    settingsCategoryLink(destination)
                }
            }
        }
        .navigationTitle("Settings")
    }

    @ViewBuilder
    private var selectedSettingsDestination: some View {
        if let selectedDestination {
            settingsDestinationView(selectedDestination)
        } else {
            ContentUnavailableView(
                "Choose a Settings Category",
                systemImage: "gearshape",
                description: Text("Select a category to view and change its settings.")
            )
            .navigationTitle("Settings")
        }
    }

    @ToolbarContentBuilder
    private var doneToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Done") {
                SettingsNavigationGuard.perform(
                    commitPendingChanges: commitPendingGroupChanges,
                    navigate: dismiss.callAsFunction
                )
            }
        }
    }

    private func settingsCategoryLink(_ destination: SettingsDestination) -> some View {
        NavigationLink(value: destination) {
            HStack(spacing: 12) {
                Image(systemName: destination.systemImage)
                    .foregroundStyle(categoryTint(for: destination))
                    .frame(width: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(destination.title)
                    Text(summary(for: destination))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(destination.title)
            .accessibilityValue(summary(for: destination))
            .accessibilityHint("Opens \(destination.title) settings.")
        }
        .tag(destination)
        .accessibilityIdentifier("settings-\(destination.rawValue)")
    }

    private func categoryTint(for destination: SettingsDestination) -> Color {
        if destination == .dataAndRecovery, recoveryState.requiresAttention {
            return .red
        }
        return .accentColor
    }

    private func summary(for destination: SettingsDestination) -> String {
        switch SettingsContentRoute.resolve(destination) {
        case let .data(section):
            dataSummary(for: section)
        case let .preferences(section):
            preferenceSummary(for: section)
        case .helpAndAbout:
            SettingsCategorySummary.help(
                installedVersion: appUpdateController.installedVersion.displayText,
                availableVersion: appUpdateController.availableRelease?.version
            )
        }
    }

    private func dataSummary(for section: SettingsContentRoute.DataSection) -> String {
        switch section {
        case .accountsAndGroups:
            SettingsCategorySummary.accounts(
                accountCount: configurationStore.visibleConfigurations.count,
                groupCount: configurationStore.groups.count
            )
        case .dataAndRecovery:
            recoveryState.summary
        }
    }

    private func preferenceSummary(for section: SettingsContentRoute.PreferenceSection) -> String {
        switch section {
        case .dashboard:
            SettingsCategorySummary.dashboard(
                appearance: configurationStore.appAppearance,
                ordering: configurationStore.dashboardOrderingMode,
                refreshInterval: configurationStore.autoRefreshInterval,
                historySamplingInterval: configurationStore.historySamplingInterval
            )
        case .alerts:
            SettingsCategorySummary.alerts(
                isEnabled: configurationStore.accountAccess.hasProAccess && configurationStore.usageAlertSettings.isEnabled,
                githubStatusEnabled: githubStatusPreferences.settings.isEnabled,
                warningThreshold: configurationStore.usageAlertSettings.warningThreshold,
                criticalThreshold: configurationStore.usageAlertSettings.criticalThreshold
            )
        case .widgets:
            configurationStore.widgetRefreshInterval.displayName
        }
    }

    @ViewBuilder
    private func settingsDestinationView(_ destination: SettingsDestination) -> some View {
        switch SettingsContentRoute.resolve(destination) {
        case let .data(section):
            dataSettingsView(section)
        case let .preferences(section):
            preferenceSettingsView(section)
        case .helpAndAbout:
            helpAndAboutSettings
        }
    }

    @ViewBuilder
    private func dataSettingsView(_ section: SettingsContentRoute.DataSection) -> some View {
        switch section {
        case .accountsAndGroups:
            accountsAndGroupsSettings
        case .dataAndRecovery:
            dataAndRecoverySettings
        }
    }

    @ViewBuilder
    private func preferenceSettingsView(_ section: SettingsContentRoute.PreferenceSection) -> some View {
        switch section {
        case .dashboard:
            dashboardSettings
        case .alerts:
            alertSettings
        case .widgets:
            widgetSettings
        }
    }

    private var accountsAndGroupsSettings: some View {
        List {
            Section("Accounts") {
                ForEach(accountsSectionRows) { row in
                    switch row {
                    case .addAccount:
                        Button {
                            guard configurationStore.canAddAccount(for: .codex) else {
                                configurationStore.requestProPresentation()
                                return
                            }
                            addAccountFlowRequest = AddAccountFlowRequest()
                        } label: {
                            Label("Add Account", systemImage: "plus.circle")
                        }
                        .disabled(configurationStore.isAccountCreationBlocked)
                        .deleteDisabled(true)

                    case .emptyState:
                        Text("No accounts")
                            .foregroundStyle(.secondary)
                            .deleteDisabled(true)

                    case let .account(accountID):
                        if let configuration = configurationStore.configuration(
                            accountID: accountID
                        ) {
                            Button {
                                SettingsNavigationGuard.perform(
                                    commitPendingChanges: commitPendingGroupChanges,
                                    navigate: {
                                        selectedAccountID = configuration.id
                                    }
                                )
                            } label: {
                                HStack {
                                    ProviderSettingsRow(
                                        configuration: configuration,
                                        isConfigured: configurationStore.isConfigured(configuration),
                                        isPausedByPlan: configurationStore.accountAccess.isPaused(accountID: configuration.id),
                                        groupName: configurationStore.group(
                                            for: configuration.groupID
                                        )?.name
                                    )
                                    Spacer()
                                    Image(systemName: "chevron.forward")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                        .accessibilityHidden(true)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(ProviderSettingsRowButtonStyle())
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(configuration.displayName)
                            .accessibilityValue(
                                ProviderSettingsRow.accessibilityValue(
                                    configuration: configuration,
                                    isConfigured: configurationStore.isConfigured(configuration),
                                    isPausedByPlan: configurationStore.accountAccess.isPaused(accountID: configuration.id),
                                    groupName: configurationStore.group(
                                        for: configuration.groupID
                                    )?.name
                                )
                            )
                            .accessibilityHint("Opens account settings.")
                        }
                    }
                }
                .onDelete(perform: deleteAccountRows)
                if !configurationStore.accountAccess.hasProAccess,
                   !configurationStore.visibleConfigurations.isEmpty {
                    Button("Change active account", systemImage: "person.crop.circle.badge.checkmark") {
                        configurationStore.requestActiveAccountChoice()
                    }
                    .accessibilityIdentifier("settings-change-active-account")
                }
            }

            Section("Groups") {
                if configurationStore.groups.isEmpty {
                    Text("No groups")
                        .foregroundStyle(.secondary)
                }

                ForEach(configurationStore.groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            "Group name",
                            text: groupNameBinding(for: group)
                        )
                        .textInputAutocapitalization(.words)
                        .focused($focusedGroupID, equals: group.id)
                        .onSubmit {
                            commitGroupName(for: group.id)
                        }

                        groupValidationMessage(for: .existingGroup(group.id))
                    }
                    .disabled(configurationStore.isPersistenceRecoveryRequired)
                    .deleteDisabled(configurationStore.isPersistenceRecoveryRequired)
                }
                .onDelete(perform: deleteGroups)

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("New group", text: newGroupNameBinding)
                            .textInputAutocapitalization(.words)
                            .onSubmit {
                                addGroup()
                            }

                        groupValidationMessage(for: .newGroup)
                    }

                    Button {
                        addGroup()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Add group")
                }
                .disabled(configurationStore.isPersistenceRecoveryRequired)
            }
        }
        .navigationTitle(SettingsDestination.accountsAndGroups.title)
    }

    @ViewBuilder
    private func groupValidationMessage(
        for target: SettingsGroupValidationTarget
    ) -> some View {
        if groupValidationState.target == target,
           let message = groupValidationState.message {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityLabel("Group validation error: \(message)")
                .accessibilityIdentifier("settings-group-validation-error")
        }
    }

    private var dashboardSettings: some View {
        List {
            Section("Appearance") {
                Picker("Color Scheme", selection: appearanceBinding) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Show subscription renewals", isOn: Binding(
                    get: { configurationStore.showsSubscriptionRenewals },
                    set: { configurationStore.updateShowsSubscriptionRenewals($0) }
                ))
                .accessibilityIdentifier("settings-show-subscription-renewals")
            } header: {
                Text("Subscription billing")
            } footer: {
                Text("Show compact countdowns when a provider supplies a verified billing date. Usage resets stay visible.")
            }

            Section("Auto Refresh") {
                Picker("Refresh", selection: autoRefreshIntervalBinding) {
                    ForEach(AutoRefreshInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
            }

            Section {
                Picker("Store Sample", selection: historySamplingIntervalBinding) {
                    ForEach(HistorySamplingInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
            } header: {
                Text("History")
            } footer: {
                Text(
                    "Usage still refreshes normally. History stores at most one sample "
                        + "per account during this interval."
                )
            }

            Section("Dashboard Ordering") {
                Picker("Ordering", selection: dashboardOrderingModeBinding) {
                    ForEach(DashboardOrderingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle(SettingsDestination.dashboard.title)
    }

    private var alertSettings: some View {
        List {
            Section {
                Toggle("Usage Alerts", isOn: usageAlertsEnabledBinding)
                    .accessibilityIdentifier("usage-alerts-toggle")
                if !configurationStore.accountAccess.hasProAccess {
                    Label("Usage alerts require CodexBar Pro. Your saved alert settings are kept.", systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Stepper(
                    value: usageAlertWarningPercentBinding,
                    in: 1...max(1, usageAlertCriticalPercent - 1),
                    step: 1
                ) {
                    Text("Warning \(Int(usageAlertWarningPercent.rounded()))%")
                }
                .disabled(!usageAlertsEnabledBinding.wrappedValue)
                .accessibilityLabel("Warning threshold")
                .accessibilityValue("\(Int(usageAlertWarningPercent.rounded())) percent")
                .accessibilityHint("Must remain below the Critical Alert threshold.")

                Stepper(
                    value: usageAlertCriticalPercentBinding,
                    in: min(100, usageAlertWarningPercent + 1)...100,
                    step: 1
                ) {
                    Text("Critical Alert \(Int(usageAlertCriticalPercent.rounded()))%")
                }
                .disabled(!usageAlertsEnabledBinding.wrappedValue)
                .accessibilityLabel("Critical Alert threshold")
                .accessibilityValue("\(Int(usageAlertCriticalPercent.rounded())) percent")
                .accessibilityHint("Must remain above the Warning threshold.")

                Stepper(value: usageAlertBalanceBinding, in: 1...100, step: 1) {
                    Text("Balance below \(formattedBalanceThreshold)")
                }
                .disabled(!usageAlertsEnabledBinding.wrappedValue)

                if let alertPermissionMessage {
                    Text(alertPermissionMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Usage Alerts")
            } footer: {
                Text("Warning applies first. Critical Alert must be at least one percentage point higher. Projected usage uses the same thresholds.")
            }

            Section {
                Toggle("Monitor GitHub Service Status", isOn: githubStatusEnabledBinding)

                Picker("Check Interval", selection: githubStatusIntervalBinding) {
                    ForEach(GitHubStatusPollingInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
                .disabled(!githubStatusPreferences.settings.isEnabled)

                Toggle("In-App Status Banner", isOn: githubStatusBannerBinding)
                    .disabled(!githubStatusPreferences.settings.isEnabled)

                Toggle("Incident Notifications", isOn: githubStatusIncidentNotificationsBinding)
                    .disabled(!githubStatusPreferences.settings.isEnabled)

                Toggle("Recovery Notifications", isOn: githubStatusRecoveryNotificationsBinding)
                    .disabled(!githubStatusPreferences.settings.isEnabled)

                LabeledContent("Last Checked", value: githubStatusLastCheckedText)

                Button("Check GitHub Status Now") {
                    Task { await onGitHubStatusRefresh() }
                }
                .disabled(!githubStatusPreferences.settings.isEnabled)

                Link(
                    "Open GitHub Status",
                    destination: URL(string: "https://www.githubstatus.com")!
                )

                if let error = githubStatusPreferences.lastError {
                    Text("\(error) A failed check is not treated as a GitHub outage.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let githubStatusPermissionMessage {
                    Text(githubStatusPermissionMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Open System Notification Settings") {
                        guard let url = URL(string: UIApplication.openNotificationSettingsURLString)
                        else { return }
                        UIApplication.shared.open(url)
                    }
                }
            } header: {
                Text("GitHub Service Status")
            } footer: {
                Text(
                    "Monitoring is off by default. The interval is a target: iOS may defer "
                        + "background checks to preserve battery. Status comes from GitHub's public "
                        + "Statuspage API and does not use an account or token."
                )
            }
        }
        .navigationTitle(SettingsDestination.alerts.title)
    }

    private var widgetSettings: some View {
        List {
            Section("Widget Updates") {
                Picker("Update Preference", selection: widgetRefreshIntervalBinding) {
                    ForEach(WidgetRefreshInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }

                NavigationLink {
                    WidgetBuilderView()
                } label: {
                    Label("Widget Builder", systemImage: "square.grid.2x2")
                }

                Text("Widgets use the latest app snapshot and ask iOS to reload on this cadence. iOS may adjust timing to preserve battery.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(SettingsDestination.widgets.title)
    }

    private var helpAndAboutSettings: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "gauge.with.dots.needle.50percent")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 36, height: 36)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("CodexBar")
                            .font(.headline)
                        Text(appUpdateController.installedVersion.displayText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "CodexBar, \(appUpdateController.installedVersion.displayText)"
                )

                if let release = appUpdateController.availableRelease {
                    LabeledContent {
                        Text("Version \(release.version)")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Update Available", systemImage: "arrow.down.app")
                    }

                    Link(destination: release.productURL) {
                        Label("Update", systemImage: "arrow.up.forward.app")
                    }
                }

                Button {
                    Task {
                        await appUpdateController.checkForUpdates(force: true)
                    }
                } label: {
                    HStack {
                        Label("Check for Updates", systemImage: "arrow.clockwise")
                        Spacer()
                        if appUpdateController.isChecking {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(appUpdateController.isChecking)
            } header: {
                Text("About")
            }

            Section("Support") {
                NavigationLink {
                    FeedbackSupportView(
                        context: .current(
                            installedVersion: appUpdateController.installedVersion
                        )
                    )
                } label: {
                    Label(
                        "Feedback & Support",
                        systemImage: "bubble.left.and.text.bubble.right"
                    )
                }

                #if DEBUG
                if AppStoreScreenshotConfiguration.current == nil {
                    Button {
                        requestReview()
                    } label: {
                        Label("Test Rating Prompt", systemImage: "star.bubble")
                    }
                }
                #endif
            }
        }
        .navigationTitle(SettingsDestination.helpAndAbout.title)
    }

    private var dataAndRecoverySettings: some View {
        List {
            if let lastError = configurationStore.lastError {
                Section("Settings Error") {
                    Text(lastError)
                        .foregroundStyle(.red)
                }
            }

            if configurationStore.isPersistenceRecoveryRequired {
                Section {
                    if configurationStore.isConfigurationRecoveryRequired {
                        Button("Replace Damaged Account List", role: .destructive) {
                            isConfirmingConfigurationReplacement = true
                        }
                    }

                    if configurationStore.isGroupRecoveryRequired {
                        Button("Replace Damaged Group List", role: .destructive) {
                            isConfirmingGroupReplacement = true
                        }
                    }
                } header: {
                    Text("Data Recovery")
                } footer: {
                    Text("Replacement preserves Keychain credentials. Replacing damaged groups ungroups saved accounts.")
                }
            }

            Section {
                Button("Reset Accounts", role: .destructive) {
                    isConfirmingReset = true
                }
                .disabled(recoveryState.resetAccountsDisabled)
            } header: {
                Text("Reset")
            } footer: {
                Text("Reset removes account entries and saved provider credentials from this device after confirmation.")
            }
        }
        .navigationTitle(SettingsDestination.dataAndRecovery.title)
    }

    private var recoveryState: SettingsRecoveryState {
        SettingsRecoveryState(
            hasError: configurationStore.lastError != nil,
            isPersistenceRecoveryRequired: configurationStore.isPersistenceRecoveryRequired,
            accountCount: configurationStore.configurations.count,
            hasIncompleteAccountReset: configurationStore.hasIncompleteAccountReset
        )
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { configurationStore.appAppearance },
            set: { configurationStore.updateAppAppearance($0) }
        )
    }

    private var autoRefreshIntervalBinding: Binding<AutoRefreshInterval> {
        Binding(
            get: { configurationStore.autoRefreshInterval },
            set: { configurationStore.updateAutoRefreshInterval($0) }
        )
    }

    private var historySamplingIntervalBinding: Binding<HistorySamplingInterval> {
        Binding(
            get: { configurationStore.historySamplingInterval },
            set: { configurationStore.updateHistorySamplingInterval($0) }
        )
    }

    private var widgetRefreshIntervalBinding: Binding<WidgetRefreshInterval> {
        Binding(
            get: { configurationStore.widgetRefreshInterval },
            set: { configurationStore.updateWidgetRefreshInterval($0) }
        )
    }

    private var dashboardOrderingModeBinding: Binding<DashboardOrderingMode> {
        Binding(
            get: { configurationStore.dashboardOrderingMode },
            set: { configurationStore.updateDashboardOrderingMode($0) }
        )
    }

    private var usageAlertsEnabledBinding: Binding<Bool> {
        Binding(
            get: { configurationStore.accountAccess.hasProAccess && configurationStore.usageAlertSettings.isEnabled },
            set: { isEnabled in
                guard configurationStore.accountAccess.hasProAccess else {
                    configurationStore.requestProPresentation()
                    return
                }
                if isEnabled {
                    Task {
                        let granted = await onAlertAuthorizationRequest()
                        guard configurationStore.accountAccess.hasProAccess else { return }
                        configurationStore.updateUsageAlertsEnabled(granted)
                        alertPermissionMessage = granted ? nil : "Notifications are disabled for CodexBar."
                    }
                } else {
                    configurationStore.updateUsageAlertsEnabled(false)
                    alertPermissionMessage = nil
                }
            }
        )
    }

    private var githubStatusEnabledBinding: Binding<Bool> {
        Binding(
            get: { githubStatusPreferences.settings.isEnabled },
            set: { isEnabled in
                var settings = githubStatusPreferences.settings
                settings.isEnabled = isEnabled
                githubStatusPreferences.updateSettings(settings)
                if isEnabled {
                    Task { await onGitHubStatusRefresh() }
                } else {
                    githubNotificationAuthorization.cancelAll()
                    githubStatusPermissionMessage = nil
                }
            }
        )
    }

    private var githubStatusIntervalBinding: Binding<GitHubStatusPollingInterval> {
        Binding(
            get: { githubStatusPreferences.settings.pollingInterval },
            set: { interval in
                var settings = githubStatusPreferences.settings
                settings.pollingInterval = interval
                githubStatusPreferences.updateSettings(settings)
            }
        )
    }

    private var githubStatusBannerBinding: Binding<Bool> {
        Binding(
            get: { githubStatusPreferences.settings.showsInAppBanner },
            set: { showsBanner in
                var settings = githubStatusPreferences.settings
                settings.showsInAppBanner = showsBanner
                githubStatusPreferences.updateSettings(settings)
            }
        )
    }

    private var githubStatusIncidentNotificationsBinding: Binding<Bool> {
        Binding(
            get: {
                githubStatusPreferences.settings.sendsIncidentNotifications
                    || githubNotificationAuthorization.isPending(.incident)
            },
            set: { isEnabled in
                updateGitHubStatusNotificationSetting(isEnabled: isEnabled, recovery: false)
            }
        )
    }

    private var githubStatusRecoveryNotificationsBinding: Binding<Bool> {
        Binding(
            get: {
                githubStatusPreferences.settings.sendsRecoveryNotifications
                    || githubNotificationAuthorization.isPending(.recovery)
            },
            set: { isEnabled in
                updateGitHubStatusNotificationSetting(isEnabled: isEnabled, recovery: true)
            }
        )
    }

    private var githubStatusLastCheckedText: String {
        guard let lastChecked = githubStatusPreferences.lastChecked else {
            return "Never"
        }
        return UserFacingDateTimeFormatter.current.dateAndTime(lastChecked)
    }

    private func updateGitHubStatusNotificationSetting(isEnabled: Bool, recovery: Bool) {
        let preference: GitHubStatusNotificationPreference = recovery ? .recovery : .incident
        guard isEnabled else {
            githubNotificationAuthorization.cancel(preference)
            githubStatusPreferences.updateSettings(
                preference.updating(githubStatusPreferences.settings, isEnabled: false)
            )
            githubStatusPermissionMessage = nil
            return
        }

        let request = githubNotificationAuthorization.begin(preference)
        Task {
            let granted = await onAlertAuthorizationRequest()
            guard let currentResult = githubNotificationAuthorization.complete(request, granted: granted) else { return }
            githubStatusPreferences.updateSettings(
                preference.updating(githubStatusPreferences.settings, isEnabled: currentResult)
            )
            githubStatusPermissionMessage = GitHubStatusNotificationAuthorization.permissionMessage(granted: currentResult)
        }
    }

    private var usageAlertWarningPercent: Double {
        configurationStore.usageAlertSettings.warningThreshold * 100
    }

    private var usageAlertCriticalPercent: Double {
        configurationStore.usageAlertSettings.criticalThreshold * 100
    }

    private var usageAlertWarningPercentBinding: Binding<Double> {
        Binding(
            get: { usageAlertWarningPercent },
            set: { configurationStore.updateUsageAlertWarningThreshold($0 / 100) }
        )
    }

    private var usageAlertCriticalPercentBinding: Binding<Double> {
        Binding(
            get: { usageAlertCriticalPercent },
            set: { configurationStore.updateUsageAlertCriticalThreshold($0 / 100) }
        )
    }

    private var usageAlertBalanceBinding: Binding<Double> {
        Binding(
            get: { configurationStore.usageAlertSettings.balanceThreshold },
            set: { configurationStore.updateUsageAlertBalanceThreshold($0) }
        )
    }

    private var formattedBalanceThreshold: String {
        Self.balanceThresholdFormatter.string(
            from: NSNumber(value: configurationStore.usageAlertSettings.balanceThreshold)
        )
            ?? "$\(Int(configurationStore.usageAlertSettings.balanceThreshold.rounded()))"
    }

    private static let balanceThresholdFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private var accountsSectionRows: [SettingsAccountsSectionRow] {
        SettingsAccountsSectionRow.rows(
            accountIDs: configurationStore.visibleConfigurations.map(\.id)
        )
    }

    private func deleteAccountRows(at offsets: IndexSet) {
        let accountsToRemove: [ProviderAccountConfiguration] = offsets.compactMap { index in
            guard accountsSectionRows.indices.contains(index),
                  case let .account(accountID) = accountsSectionRows[index]
            else {
                return nil
            }
            return configurationStore.configuration(accountID: accountID)
        }
        guard !accountsToRemove.isEmpty else {
            return
        }
        if configurationStore.removeAccounts(accountsToRemove) {
            onAccountsChanged()
        }
    }

    @discardableResult
    private func addGroup() -> Bool {
        guard configurationStore.addGroup(named: newGroupName) != nil else {
            groupValidationState.recordFailure(
                storeError: configurationStore.lastError,
                target: .newGroup
            )
            return false
        }

        newGroupName = ""
        clearGroupValidation()
        return true
    }

    private func deleteGroups(at offsets: IndexSet) {
        let groups = configurationStore.groups
        for index in offsets {
            configurationStore.removeGroup(groups[index])
            groupNameDrafts[groups[index].id] = nil
        }
    }

    private func groupNameBinding(for group: ProviderAccountGroup) -> Binding<String> {
        Binding(
            get: {
                groupNameDrafts[group.id]
                    ?? configurationStore.group(for: group.id)?.name
                    ?? group.name
            },
            set: { name in
                groupNameDrafts[group.id] = name
                clearGroupValidation()
            }
        )
    }

    private var newGroupNameBinding: Binding<String> {
        Binding(
            get: { newGroupName },
            set: { name in
                newGroupName = name
                clearGroupValidation()
            }
        )
    }

    private var pendingGroupChanges: SettingsPendingGroupChanges {
        SettingsPendingGroupChanges(
            draftGroupIDs: SettingsPendingGroupChanges.changedDraftGroupIDs(
                draftNames: groupNameDrafts,
                persistedName: { groupID in
                    configurationStore.group(for: groupID)?.name
                }
            ),
            newGroupName: newGroupName
        )
    }

    private func commitPendingGroupChanges() -> Bool {
        pendingGroupChanges.commitAll(
            commitDraft: { groupID in
                let committed = commitGroupName(for: groupID)
                if !committed {
                    focusedGroupID = groupID
                }
                return committed
            },
            commitNewGroup: {
                addGroup()
            }
        )
    }

    private func clearGroupValidation() {
        configurationStore.clearLastError(ifMatching: groupValidationState.message)
        groupValidationState.clear()
    }

    private func recordGroupValidationFailure(
        for groupID: String
    ) {
        groupValidationState.recordFailure(
            storeError: configurationStore.lastError,
            target: .existingGroup(groupID)
        )
    }

    private func clearGroupDraft(for groupID: String) {
        groupNameDrafts[groupID] = nil
        clearGroupValidation()
    }

    private func commitGroupNameChange(
        _ updated: ProviderAccountGroup,
        groupID: String
    ) -> Bool {
        if configurationStore.updateGroup(updated) {
            clearGroupDraft(for: groupID)
            return true
        }
        recordGroupValidationFailure(for: groupID)
        return false
    }

    @discardableResult
    private func commitGroupName(for groupID: String) -> Bool {
        guard
            let group = configurationStore.group(for: groupID),
            let draftName = groupNameDrafts[groupID]
        else {
            return true
        }

        let normalizedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedName != group.name else {
            clearGroupDraft(for: groupID)
            return true
        }

        var updated = group
        updated.name = draftName
        return commitGroupNameChange(updated, groupID: groupID)
    }
}

struct ProviderSettingsRow: View {
    let configuration: ProviderAccountConfiguration
    let isConfigured: Bool
    var isPausedByPlan = false
    let groupName: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusTint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(configuration.displayName)
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let groupName {
                    Text(groupName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusIcon: String {
        if isPausedByPlan { return "lock.fill" }
        if !configuration.isEnabled {
            return "pause.circle"
        }

        return isConfigured ? "checkmark.circle.fill" : "exclamationmark.circle"
    }

    private var statusTint: Color {
        if isPausedByPlan || !configuration.isEnabled {
            return .secondary
        }

        return isConfigured ? .green : .orange
    }

    private var statusText: String {
        isPausedByPlan ? "Paused: CodexBar Pro" : Self.statusText(configuration: configuration, isConfigured: isConfigured)
    }

    static func accessibilityValue(
        configuration: ProviderAccountConfiguration,
        isConfigured: Bool,
        isPausedByPlan: Bool = false,
        groupName: String?
    ) -> String {
        let status = isPausedByPlan ? "Paused: CodexBar Pro" : statusText(configuration: configuration, isConfigured: isConfigured)
        guard let groupName else {
            return status
        }

        return "\(status), \(groupName) group"
    }

    private static func statusText(
        configuration: ProviderAccountConfiguration,
        isConfigured: Bool
    ) -> String {
        if !configuration.isEnabled {
            return "Disabled"
        }

        let provider = configuration.providerID.displayName
        return isConfigured ? "\(provider) configured" : "\(provider) needs setup"
    }
}

private struct ProviderSettingsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

struct AddAccountFlowRequest: Identifiable, Equatable {
    let id = UUID()
    let initialProviderID: ProviderID?

    init(initialProviderID: ProviderID? = nil) {
        self.initialProviderID = initialProviderID
    }
}

struct AddAccountRefreshState: Equatable {
    private(set) var accountID: String?
    private var shouldRefreshOnDismiss = false

    mutating func accountCreated(_ accountID: String) {
        self.accountID = accountID
        shouldRefreshOnDismiss = true
    }

    mutating func credentialsChanged() -> String? {
        guard let accountID else {
            return nil
        }
        shouldRefreshOnDismiss = false
        return accountID
    }

    mutating func refreshInputsChanged() {
        guard accountID != nil else { return }
        shouldRefreshOnDismiss = true
    }

    mutating func finishDismissal() -> String? {
        defer {
            accountID = nil
            shouldRefreshOnDismiss = false
        }
        return shouldRefreshOnDismiss ? accountID : nil
    }
}

enum SettingsAccountsSectionRow: Identifiable, Equatable {
    case addAccount
    case emptyState
    case account(String)

    var id: String {
        switch self {
        case .addAccount:
            "action.add-account"
        case .emptyState:
            "state.empty"
        case let .account(accountID):
            "account.\(accountID)"
        }
    }

    static func rows(accountIDs: [String]) -> [Self] {
        if accountIDs.isEmpty {
            return [.addAccount, .emptyState]
        }
        return [.addAccount] + accountIDs.map(Self.account)
    }
}

struct AddAccountFlowState: Equatable {
    static let providerOptions = ProviderID.allCases.filter { $0 != .antigravity && $0.isAvailableOnIPhone }
    static let unavailableProviders = ProviderID.allCases.filter { !$0.isAvailableOnIPhone }

    private(set) var accountID: String?

    @discardableResult
    @MainActor
    mutating func select(
        _ providerID: ProviderID,
        configurationStore: ProviderConfigurationStore
    ) -> String? {
        if let accountID {
            return accountID
        }
        guard Self.providerOptions.contains(providerID), !configurationStore.isAccountCreationBlocked else {
            return nil
        }

        guard configurationStore.canAddAccount(for: providerID) else {
            configurationStore.requestProPresentation()
            return nil
        }
        guard let configuration = configurationStore.addAccount(for: providerID),
              configurationStore.configuration(accountID: configuration.id) != nil else {
            return nil
        }
        accountID = configuration.id
        return configuration.id
    }
}

struct AddAccountSetupFlow: View {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    let initialProviderID: ProviderID?
    var onAccountCreated: @MainActor (String) -> Void
    var onCredentialsChanged: @MainActor (String) -> Void
    var onRefreshInputsChanged: @MainActor (String) -> Void
    var onAccountRefresh: @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult?
    var onCredentialRefresh: @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult?

    @Environment(\.dismiss) private var dismiss
    @State private var flowState = AddAccountFlowState()

    init(
        configurationStore: ProviderConfigurationStore,
        initialProviderID: ProviderID? = nil,
        onAccountCreated: @escaping @MainActor (String) -> Void = { _ in },
        onCredentialsChanged: @escaping @MainActor (String) -> Void = { _ in },
        onRefreshInputsChanged: @escaping @MainActor (String) -> Void = { _ in },
        onAccountRefresh: @escaping @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult? = { _ in nil },
        onCredentialRefresh: (@MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult?)? = nil
    ) {
        self.configurationStore = configurationStore
        self.initialProviderID = initialProviderID
        self.onAccountCreated = onAccountCreated
        self.onCredentialsChanged = onCredentialsChanged
        self.onRefreshInputsChanged = onRefreshInputsChanged
        self.onAccountRefresh = onAccountRefresh
        self.onCredentialRefresh = onCredentialRefresh ?? onAccountRefresh
    }

    var body: some View {
        NavigationStack {
            if let accountID = flowState.accountID {
                ProviderSettingsView(
                    configurationStore: configurationStore,
                    accountID: accountID,
                    onCredentialsChanged: onCredentialsChanged,
                    onRefreshInputsChanged: onRefreshInputsChanged,
                    onAccountRefresh: onAccountRefresh,
                    onCredentialRefresh: onCredentialRefresh
                )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            } else {
                List {
                    Section {
                        ForEach(AddAccountFlowState.providerOptions) { providerID in
                            Button {
                                select(providerID)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(providerID.displayName, systemImage: providerID.addAccountIconName)
                                    if let description = GoogleUsageMetricCatalog.setupDescription(for: providerID) {
                                        Text(description).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .accessibilityHint("Creates this account and opens its setup screen.")
                        }
                    } footer: {
                        ForEach(AddAccountFlowState.unavailableProviders) { providerID in
                            if let reason = providerID.phoneUnavailableReason {
                                Text("\(providerID.displayName) isn't available on iPhone. \(reason)")
                                    .accessibilityIdentifier("add-account.unavailable.\(providerID.rawValue)")
                            }
                        }
                    }
                }
                .navigationTitle("Choose a Provider")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
            }
        }
        .accountPlanPresentation(configurationStore: configurationStore, isActive: flowState.accountID == nil)
        .task {
            guard let initialProviderID, flowState.accountID == nil else {
                return
            }
            select(initialProviderID)
        }
    }

    private func select(_ providerID: ProviderID) {
        let previousAccountID = flowState.accountID
        guard let accountID = flowState.select(
            providerID,
            configurationStore: configurationStore
        ) else {
            return
        }
        if previousAccountID == nil {
            onAccountCreated(accountID)
        }
    }
}

extension ProviderID {
    var addAccountIconName: String {
        switch self {
        case .codex:
            "sparkles"
        case .copilot:
            "chevron.left.forwardslash.chevron.right"
        case .githubBilling:
            "creditcard"
        case .claude:
            "text.bubble"
        case .grok:
            "sparkle.magnifyingglass"
        case .xSubscription:
            "x.square"
        case .openRouter:
            "network"
        case .openCodeZen:
            "dollarsign.circle"
        case .moonshot:
            "moon.stars"
        case .cursor:
            "cursorarrow"
        case .greptile:
            "checkmark.bubble"
        case .gemini:
            "diamond.fill"
        case .antigravity:
            "arrow.up.circle"
        case .museCode:
            "music.note"
        }
    }
}

#Preview {
    SettingsView(
        configurationStore: ProviderConfigurationStore(),
        appUpdateController: AppUpdateController(),
        githubStatusPreferences: GitHubStatusPreferences()
    )
}

private struct FeedbackSupportView: View {
    let context: FeedbackSupportContext

    @Environment(\.openURL) private var openURL
    @State private var failedDestination: FeedbackSupportDestination?
    @State private var problemReportContext: PrivacySafeDiagnosticContext?
    @State private var emailDetailsDraft: FeedbackEmailDraft?

    var body: some View {
        List {
            Section {
                Label {
                    Text(
                        "Email feedback is private and does not require a GitHub account. Opening a draft does not "
                            + "send it; you review and explicitly send. Do not add credentials, tokens, cookies, "
                            + "account identifiers, or other secrets to either channel. GitHub forms remain public, "
                            + "require an account, and must not include email addresses."
                    )
                } icon: {
                    Image(systemName: "exclamationmark.shield")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            } header: {
                Text("Before You Share")
            }

            Section {
                ForEach(FeedbackSupportDestination.allCases) { destination in
                    Button {
                        open(destination)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: destination.systemImage)
                                .foregroundStyle(.tint)
                                .frame(width: 24)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(destination.title)
                                    .foregroundStyle(.primary)
                                Text(destination.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 8)

                            if destination.presentation == .external {
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(destination.serviceName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "arrow.up.forward")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel(accessibilityLabel(for: destination))
                    .accessibilityHint(destination.detail)
                }
            } footer: {
                Text(
                    "Problem emails preview an allowlisted diagnostic first, and optional technical details can be "
                        + "removed. CodexBar shows copyable recipient, subject, and message fields before offering "
                        + "to open your mail app."
                )
            }

            Section {
                Button {
                    presentProblemReport(
                        surface: .widget,
                        technicalDetails: DiagnosticTechnicalDetails(widgetState: .unknown)
                    )
                } label: {
                    Label("Report a Widget Problem", systemImage: "rectangle.stack.badge.exclamationmark")
                }
                .accessibilityHint("Previews a privacy-safe Widget diagnostic")

                Button {
                    presentProblemReport(
                        surface: .appleWatch,
                        technicalDetails: DiagnosticTechnicalDetails(watchState: .unknown)
                    )
                } label: {
                    Label("Report an Apple Watch Problem", systemImage: "applewatch")
                }
                .accessibilityHint("Previews a privacy-safe Apple Watch diagnostic")
            } header: {
                Text("Contextual Reports")
            } footer: {
                Text("These reports include only presentation-safe freshness or connection categories, never widget selections or stored watch snapshots.")
            }
        }
        .navigationTitle("Feedback & Support")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $problemReportContext) { context in
            DiagnosticReportView(context: context)
        }
        .sheet(item: $emailDetailsDraft) { draft in
            FeedbackEmailDetailsView(draft: draft)
        }
        .alert(
            "Couldn’t Open \(failedDestination?.serviceName ?? "Link")",
            isPresented: Binding(
                get: { failedDestination != nil },
                set: { isPresented in
                    if !isPresented {
                        failedDestination = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The link couldn’t be opened. Please try again later.")
        }
    }

    private func open(_ destination: FeedbackSupportDestination) {
        switch destination {
        case .reportProblem:
            presentProblemReport(surface: .other)
        case .suggestImprovement:
            emailDetailsDraft = improvementEmailDraft
        case .publicBugReport,
             .publicImprovement,
             .knownIssues,
             .supportGuide,
             .rateCodexBar:
            openURL(destination.url(context: context)) { accepted in
                if !accepted {
                    failedDestination = destination
                }
            }
        }
    }

    private func accessibilityLabel(
        for destination: FeedbackSupportDestination
    ) -> String {
        switch destination.presentation {
        case .diagnosticPreview:
            "\(destination.title), opens a diagnostic preview"
        case .emailDetails:
            "\(destination.title), opens copyable email details"
        case .external:
            "\(destination.title), opens \(destination.serviceName)"
        }
    }

    private func presentProblemReport(
        surface: DiagnosticSurface,
        technicalDetails: DiagnosticTechnicalDetails? = nil
    ) {
        problemReportContext = PrivacySafeDiagnosticContext(
            system: context,
            surface: surface,
            providerID: nil,
            technicalDetails: technicalDetails
        )
    }

    private var improvementEmailDraft: FeedbackEmailDraft {
        FeedbackEmailDraft.improvementSuggestion(context: context)
    }
}
