import SwiftUI

/// Shared destination for every user-initiated Pro entry point. StoreKit commerce
/// content belongs here when products and purchase handling are available.
struct ProPresentationView: View {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("CodexBar Pro", systemImage: "sparkles")
                        .font(.title2.weight(.semibold))
                    Text(configurationStore.accountAccess.hasProAccess
                         ? "You have CodexBar Pro."
                         : "Free includes one active account, the dashboard, and the last 7 days of history.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("With Pro") {
                    Label("Keep every account refreshing", systemImage: "person.2")
                    Label("See your full saved history", systemImage: "chart.xyaxis.line")
                    Label("Receive usage alerts", systemImage: "bell")
                }
                Section {
                    Text(
                        "Your saved accounts, credentials, history, and alert settings stay on this device when Pro ends. "
                            + "Pro restores access without setting up your accounts again."
                    )
                    if !configurationStore.accountAccess.hasProAccess {
                        Text("Purchase options are not available in this version.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("CodexBar Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("codexbar-pro-presentation")
    }
}

extension View {
    func accountPlanPresentation(
        configurationStore: ProviderConfigurationStore,
        usageResultForAccount: @escaping @MainActor (String) -> ProviderUsageResult? = { _ in nil },
        isActive: Bool = true
    ) -> some View {
        modifier(AccountPlanPresentationModifier(
            configurationStore: configurationStore,
            usageResultForAccount: usageResultForAccount,
            isActive: isActive
        ))
    }
}

private struct AccountPlanPresentationModifier: ViewModifier {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    @Environment(\.accountLastResultProvider) private var lastResultProvider
    let usageResultForAccount: @MainActor (String) -> ProviderUsageResult?
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { isActive && configurationStore.requestedProPresentation },
                set: { if !$0 && isActive { configurationStore.dismissProPresentation() } }
            )) {
                ProPresentationView(configurationStore: configurationStore)
            }
            .sheet(isPresented: Binding(
                get: {
                    isActive && !configurationStore.requestedProPresentation
                        && configurationStore.accountAccess.needsActiveAccountChoice
                },
                set: { if !$0 && isActive { configurationStore.dismissActiveAccountChoice() } }
            )) {
                ActiveAccountChooser(
                    configurationStore: configurationStore,
                    usageResultForAccount: { accountID in
                        usageResultForAccount(accountID) ?? lastResultProvider(accountID)
                    }
                )
            }
    }
}

private struct AccountLastResultProviderKey: EnvironmentKey {
    static var defaultValue: @MainActor (String) -> ProviderUsageResult? { { _ in nil } }
}

extension EnvironmentValues {
    var accountLastResultProvider: @MainActor (String) -> ProviderUsageResult? {
        get { self[AccountLastResultProviderKey.self] }
        set { self[AccountLastResultProviderKey.self] = newValue }
    }
}

/// Observes the source of history so an already-presented chart gains or loses
/// older samples as access changes, without retaining a clipped snapshot.
struct LiveProviderUsageHistoryDetailView: View {
    let result: ProviderUsageResult
    @ObservedObject var historyStore: UsageHistoryStore
    @ObservedObject var configurationStore: ProviderConfigurationStore

    var body: some View {
        ProviderUsageHistoryDetailView(
            result: result,
            seriesOptions: historyStore.historySeriesOptions(
                for: result,
                severityThresholds: configurationStore.usageAlertSettings.severityThresholds
            ),
            accessPolicy: historyStore.accessPolicy,
            onRequestPro: configurationStore.requestProPresentation
        )
        .accountPlanPresentation(configurationStore: configurationStore)
    }
}

struct HistoryRangePicker: View {
    @Binding var selection: UsageHistoryRange
    let accessPolicy: HistoryAccessPolicy
    let onRequestPro: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(UsageHistoryRange.allCases) { range in
                let isLocked = !accessPolicy.allows(range: range)
                Button {
                    if isLocked { onRequestPro() } else { selection = range }
                } label: {
                    HStack(spacing: 4) {
                        Text(range.compactTitle)
                        if isLocked {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(selection == range ? Color.accentColor.opacity(0.16) : Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(range.title)
                .accessibilityAddTraits(selection == range && !isLocked ? .isSelected : [])
                .accessibilityValue(isLocked ? "Locked. CodexBar Pro" : selection == range ? "Selected" : "")
                .accessibilityHint(isLocked ? "Opens CodexBar Pro." : "Shows this history range.")
                .accessibilityIdentifier("history-range-\(range.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("History range")
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: dynamicTypeSize.isAccessibilitySize ? 2 : 5)
    }
}
