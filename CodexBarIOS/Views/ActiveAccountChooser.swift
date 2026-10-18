import SwiftUI

struct ActiveAccountChooser: View {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    let usageResultForAccount: @MainActor (String) -> ProviderUsageResult?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose the account that keeps refreshing. Other accounts keep their last values, credentials, settings, and history.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("Accounts") {
                    ForEach(accounts) { account in
                        Button {
                            _ = configurationStore.chooseActiveAccount(account.id)
                        } label: {
                            accountRow(account)
                        }
                        .buttonStyle(.plain)
                        .disabled(!account.isEnabled)
                        .accessibilityIdentifier("active-account-choice-\(account.id)")
                    }
                }
                if configurationStore.activeAccountCandidates.isEmpty {
                    Text("Enable an account in Settings to choose which one refreshes.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Change active account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        configurationStore.dismissActiveAccountChoice()
                        dismiss()
                    }
                }
            }
        }
        .accessibilityIdentifier("active-account-chooser")
    }

    private var accounts: [ProviderAccountConfiguration] {
        configurationStore.activeAccountCandidates
            + configurationStore.visibleConfigurations.filter { !$0.isEnabled }
    }

    private func accountRow(_ account: ProviderAccountConfiguration) -> some View {
        let isActive = configurationStore.accountAccess.activeAccountID == account.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                CodexBarProviderLogo(
                    providerID: account.providerID.rawValue,
                    size: 24,
                    background: Color(.secondarySystemGroupedBackground),
                    border: Color(.separator).opacity(0.3),
                    imagePadding: 4
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.displayName)
                        .font(.headline)
                    Text(!account.isEnabled ? "Disabled in account settings" : isActive ? "Active account" : "Paused: CodexBar Pro")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            if let result = usageResultForAccount(account.id) {
                lastResult(result)
            } else {
                Text("No saved usage result. Values will appear after this account refreshes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityHint(account.isEnabled && !isActive ? "Makes this the account that refreshes." : "")
    }

    private func lastResult(_ result: ProviderUsageResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(result.bars) { bar in
                Text("\(bar.label): \(bar.usageText)")
            }
            if let credits = result.creditsRemaining {
                Text("Credits remaining: \(credits.formatted())")
            }
            ForEach(result.monetaryMetrics) { metric in
                Text("\(metric.label): \(metric.formattedAmount())")
            }
            Text("Last result: \(UserFacingDateTimeFormatter.current.dateAndTime(result.fetchedAt))")
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
    }
}

struct PausedAccountNotice: View {
    let accountID: String
    let onMakeActive: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Paused: CodexBar Pro", systemImage: "lock.fill")
                .font(.subheadline.weight(.semibold))
            Button("Make active", action: onMakeActive)
                .buttonStyle(.bordered)
                .accessibilityHint("Choose the account that keeps refreshing.")
                .accessibilityIdentifier("make-account-active-\(accountID)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PausedAccountPlaceholder: View {
    let configuration: ProviderAccountConfiguration
    let onMakeActive: () -> Void
    let onConfigure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(configuration.displayName, systemImage: "person.crop.circle")
                .font(.headline)
            Text("No saved usage result. Make this account active to refresh its values.")
                .foregroundStyle(.secondary)
            PausedAccountNotice(accountID: configuration.id, onMakeActive: onMakeActive)
            Button("Account settings", action: onConfigure)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}
