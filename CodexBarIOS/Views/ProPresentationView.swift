import StoreKit
import SwiftUI

/// One user-initiated destination observes the app's canonical entitlement service.
struct ProPresentationView: View {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    var origin: ProPresentationOrigin = .limit
    @EnvironmentObject private var entitlement: ProEntitlement
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var feedback: ProCommerceFeedback?
    @State private var pendingProduct: ProProductID?
    @State private var isRefreshing = false
    @State private var showsManagement = false
    @State private var managementGroupID: String?
    @State private var showsLifetimeConfirmation = false
    @State private var lifetimeProduct: ProCatalogProduct?
    @State private var lifetimeSettingsContext = false
    #if DEBUG
    @State private var showsFixtureManagement = false
    #endif

    var body: some View {
        NavigationStack {
            List {
                currentPlan
                warnings
                commandStatus
                if entitlement.commerce.showsPurchaseOptions { purchaseOptions }
                if showsLifetimeSwitch { lifetimeSwitch }
                management
                ProBenefitsView()
                ProPolicyLinksView()
            }
            .accessibilityIdentifier("pro-content-list")
            .navigationTitle("CodexBar Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(entitlement.command != nil)
                        .accessibilityIdentifier("pro-done")
                }
            }
        }
        .accessibilityIdentifier("codexbar-pro-presentation")
        .accessibilityValue(isReady ? "ready" : "loading")
        .interactiveDismissDisabled(entitlement.command != nil)
        .background {
            ProSubscriptionSheetPresenter(isPresented: $showsManagement, groupID: managementGroupID)
        }
        .sheet(isPresented: $showsLifetimeConfirmation) {
            if let product = lifetimeProduct {
                ProLifetimeConfirmationView(
                    product: product,
                    subscriptionEndsAt: entitlement.commerce.subscriptionPeriodEnd,
                    canPurchase: !isBusy && entitlement.commerce.lifetimeAction == .available
                        && products[.lifetime] == product,
                    onPurchase: {
                        showsLifetimeConfirmation = false
                        purchase(product, isLifetimeSwitch: lifetimeSettingsContext)
                    }
                )
                .dynamicTypeSize(dynamicTypeSize)
            }
        }
        .task { await refreshCommerce() }
        .onChange(of: showsManagement) { wasPresented, isPresented in
            if wasPresented && !isPresented { Task { await refreshCommerce() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshCommerce() } }
        }
        .onChange(of: entitlement.value) { _, value in
            guard let pendingProduct, entitlement.hasAccess else { return }
            let wasGranted = pendingProduct == .lifetime
                ? value.reason == .lifetime : value.subscriptionProduct == pendingProduct
            if wasGranted {
                self.pendingProduct = nil
                feedback = purchaseSuccess(for: pendingProduct)
            }
        }
        #if DEBUG
        .sheet(isPresented: $showsFixtureManagement, onDismiss: {
            Task { await refreshCommerce() }
        }, content: {
            if let fixture = UITestFixtures.current?.commerceFixture {
                ProCommerceFixtureManagementView(fixture: fixture)
                    .dynamicTypeSize(dynamicTypeSize)
            }
        })
        #endif
    }

    private var currentPlan: some View {
        Section("Current plan") {
            if entitlement.isResolved {
                ProCurrentPlanView(presentation: entitlement.commerce)
            } else {
                ProgressView("Checking your purchases…")
                    .accessibilityIdentifier("pro-checking-purchases")
                Text("Your current plan will appear when purchase verification finishes.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var warnings: some View {
        if entitlement.commerce.hasRenewalOverlap {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("A subscription is still renewing", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("pro-renewal-overlap")
                    Text("You have lifetime Pro. This subscription is no longer needed, but Apple will keep charging until you cancel it.")
                    Button("Manage Subscription", action: showManagement)
                        .disabled(isBusy)
                        .accessibilityIdentifier("pro-overlap-manage")
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        if entitlement.commerce.hasBillingIssue {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Check your payment details", systemImage: "creditcard.trianglebadge.exclamationmark")
                        .font(.headline)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("pro-billing-issue")
                    Text("Apple could not renew a CodexBar Pro subscription. Update your payment method to resolve the billing problem.")
                    if let end = entitlement.commerce.graceEndsAt {
                        Text("Billing grace period ends \(end.formatted(date: .long, time: .omitted)).")
                    }
                    Link("Manage Payment Method", destination: ProCommerceLinks.billing)
                        .accessibilityIdentifier("pro-payment-management")
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var commandStatus: some View {
        if let command = entitlement.command {
            Section {
                ProgressView(commandLabel(command))
                    .accessibilityIdentifier("pro-command-busy")
            }
        } else if let feedback {
            Section { ProCommerceFeedbackView(feedback: feedback) }
        }
        if let message = entitlement.statusMessage {
            Section {
                Label(message, systemImage: "exclamationmark.circle")
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pro-verification-message")
            }
        }
    }

    private var purchaseOptions: some View {
        Section("Choose your plan") {
            switch entitlement.catalog {
            case .idle, .loading:
                ProgressView("Loading App Store prices…")
                    .accessibilityIdentifier("pro-catalog-loading")
            case let .failed(message):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Prices are unavailable")
                        .font(.headline)
                        .accessibilityIdentifier("pro-catalog-error")
                    Text(message)
                        .foregroundStyle(.secondary)
                    Button("Try Again") { Task { await refreshCommerce() } }
                        .disabled(isBusy)
                        .accessibilityIdentifier("pro-catalog-retry")
                }
            case .loaded:
                ForEach(ProProductID.allCases, id: \.self) { productID in
                    if let product = products[productID] {
                        ProProductOptionView(
                            product: product, isBusy: isBusy,
                            actionTitle: purchaseActionTitle(product),
                            onPurchase: { select(product) }
                        )
                        if productID == .lifetime, needsLifetimeGate {
                            lifetimeGate
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(productID.proPlanName).font(.headline)
                            Text("Currently unavailable from the App Store. Try refreshing.")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("pro-unavailable-\(productID.proIdentifier)")
                    }
                }
            }
        }
    }

    private var lifetimeSwitch: some View {
        Section("Switch to lifetime") {
            lifetimeGate
            if let product = products[.lifetime] {
                Text("\(product.displayPrice) once")
                    .font(.title2.weight(.semibold))
                Button(lifetimeActionTitle) { prepareLifetimeSwitch(isSettingsSwitch: true) }
                    .disabled(isBusy)
                    .accessibilityIdentifier("pro-switch-lifetime")
            } else {
                Text("Lifetime pricing is unavailable. Refresh to try again.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var lifetimeGate: some View {
        Text(lifetimeGateMessage)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("pro-lifetime-gate")
    }

    private var management: some View {
        Section("Purchases") {
            Button("Manage Subscription", action: showManagement)
                .disabled(isBusy)
                .accessibilityIdentifier("pro-manage-subscription")
            Button("Restore Purchases", action: restore)
                .disabled(isBusy)
                .accessibilityIdentifier("pro-restore-purchases")
            Button("Refresh Purchase Information") { Task { await refreshCommerce() } }
                .disabled(isBusy)
                .accessibilityIdentifier("pro-refresh")
            if isReady {
                Text(readinessMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("pro-content-ready")
            }
        }
    }

    private var products: [ProProductID: ProCatalogProduct] {
        if case let .loaded(catalog) = entitlement.catalog { return catalog.products }
        return [:]
    }

    private var isBusy: Bool { entitlement.command != nil || isRefreshing || !entitlement.isResolved }

    private var isReady: Bool {
        guard entitlement.isResolved, !isRefreshing else { return false }
        switch entitlement.catalog {
        case .idle, .loading: return false
        case .loaded, .failed: return true
        }
    }

    private var readinessMessage: String {
        if case .failed = entitlement.catalog {
            return "Purchase information is unavailable. Restore and management are still available."
        }
        return "Purchase information loaded."
    }

    private var showsLifetimeSwitch: Bool {
        origin == .settings && entitlement.isResolved && entitlement.hasAccess
            && entitlement.commerce.hasSubscription && !entitlement.value.reason.isPermanent
    }

    private var needsLifetimeGate: Bool {
        entitlement.commerce.hasSubscription || entitlement.commerce.lifetimeAction != .available
    }

    private var lifetimeActionTitle: String {
        entitlement.commerce.lifetimeAction == .available ? "Switch to lifetime" : "Manage Subscription"
    }

    private var lifetimeGateMessage: String {
        switch entitlement.commerce.lifetimeAction {
        case .available:
            "Auto-renew is off. Buying lifetime does not refund the remaining paid subscription period."
        case .manageSubscription:
            "Turn off auto-renew first in Manage Subscription, then return here to switch to lifetime."
        case .unavailable:
            "Renewal status is unavailable. Refresh or check Manage Subscription before buying lifetime."
        case .alreadyPermanent:
            "You already have lifetime Pro."
        }
    }

    private func purchaseActionTitle(_ product: ProCatalogProduct) -> String {
        if product.id == .lifetime,
           entitlement.commerce.lifetimeAction != .available { return "Manage Subscription" }
        if product.offersSevenDayTrial { return "Start 7-day free trial" }
        return product.id == .lifetime ? "Buy lifetime" : "Choose \(product.id.proIdentifier)"
    }

    private func select(_ product: ProCatalogProduct) {
        if product.id == .lifetime, needsLifetimeGate {
            prepareLifetimeSwitch(isSettingsSwitch: false)
        } else {
            purchase(product, isLifetimeSwitch: false)
        }
    }

    private func prepareLifetimeSwitch(isSettingsSwitch: Bool) {
        guard !isBusy else { return }
        isRefreshing = true
        Task {
            await entitlement.refreshCommerce()
            isRefreshing = false
            guard entitlement.commerce.lifetimeAction == .available else {
                showManagement()
                return
            }
            guard let product = products[.lifetime] else {
                feedback = ProCommerceFeedback(
                    title: "Lifetime is unavailable", detail: "Refresh purchase information and try again.", isError: true
                )
                return
            }
            lifetimeProduct = product
            lifetimeSettingsContext = isSettingsSwitch
            showsLifetimeConfirmation = true
        }
    }

    private func showManagement() {
        guard !isBusy else { return }
        #if DEBUG
        if UITestFixtures.current?.commerceFixture?.isSynthetic == true {
            showsFixtureManagement = true
            return
        }
        #endif
        if case let .loaded(catalog) = entitlement.catalog {
            managementGroupID = catalog.subscriptionGroupID
        } else { managementGroupID = nil }
        showsManagement = true
    }

    private func refreshCommerce() async {
        guard !isRefreshing, entitlement.command == nil else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await entitlement.refreshCommerce()
    }

    private func purchase(_ product: ProCatalogProduct, isLifetimeSwitch: Bool) {
        guard !isBusy else { return }
        feedback = nil
        Task {
            do {
                let result = try await entitlement.purchase(
                    product.id, context: isLifetimeSwitch ? .settingsLifetime : .standard, expectedProduct: product
                )
                switch result {
                case .purchased:
                    feedback = purchaseSuccess(for: product.id)
                case .pending:
                    pendingProduct = product.id
                    feedback = ProCommerceFeedback(
                        title: "Waiting for approval", detail: "Pro will update automatically if this purchase is approved."
                    )
                case .cancelled:
                    feedback = ProCommerceFeedback(title: "Purchase canceled", detail: "No purchase was completed.")
                }
            } catch is CancellationError {
                feedback = ProCommerceFeedback(title: "Purchase canceled", detail: "Check your current plan before trying again.")
            } catch {
                feedback = ProCommerceFeedback(title: "Purchase could not be completed", detail: error.localizedDescription, isError: true)
            }
        }
    }

    private func restore() {
        guard !isBusy else { return }
        feedback = nil
        Task {
            do {
                switch try await entitlement.restore() {
                case .restored:
                    feedback = ProCommerceFeedback(title: "Purchases restored", detail: "Your CodexBar Pro access is available.")
                case .noPurchases:
                    feedback = ProCommerceFeedback(title: "No Pro purchase found", detail: "No qualifying purchase was found for this Apple Account.")
                }
            } catch is CancellationError {
                feedback = ProCommerceFeedback(title: "Restore canceled", detail: "You can try Restore Purchases again whenever you are ready.")
            } catch {
                feedback = ProCommerceFeedback(title: "Restore could not be completed", detail: error.localizedDescription, isError: true)
            }
        }
    }

    private func purchaseSuccess(for product: ProProductID) -> ProCommerceFeedback {
        ProCommerceFeedback(
            title: product == .lifetime ? "Lifetime Pro is ready" : "CodexBar Pro is ready",
            detail: "Your purchase is saved and Pro access is available."
        )
    }

    private func commandLabel(_ command: ProCommerceCommand) -> String {
        switch command {
        case .purchase: "Completing your purchase…"
        case .restore: "Restoring purchases…"
        }
    }
}

private struct ProSubscriptionSheetPresenter: View {
    @Binding var isPresented: Bool
    let groupID: String?

    var body: some View {
        Group {
            if let groupID {
                Color.clear.manageSubscriptionsSheet(isPresented: $isPresented, subscriptionGroupID: groupID)
            } else {
                Color.clear.manageSubscriptionsSheet(isPresented: $isPresented)
            }
        }
        .frame(width: 0, height: 0)
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let usageResultForAccount: @MainActor (String) -> ProviderUsageResult?
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { isActive && configurationStore.requestedProPresentation },
                set: { if !$0 && isActive { configurationStore.dismissProPresentation() } }
            )) {
                ProPresentationView(
                    configurationStore: configurationStore, origin: configurationStore.requestedProPresentationOrigin
                )
                    .dynamicTypeSize(dynamicTypeSize)
            }
            .sheet(isPresented: Binding(
                get: {
                    isActive && !configurationStore.requestedProPresentation
                        && configurationStore.accountAccess.needsActiveAccountChoice
                },
                set: {
                    if !$0 && isActive && !configurationStore.requestedProPresentation {
                        configurationStore.dismissActiveAccountChoice()
                    }
                }
            )) {
                ActiveAccountChooser(
                    configurationStore: configurationStore,
                    usageResultForAccount: { accountID in
                        usageResultForAccount(accountID) ?? lastResultProvider(accountID)
                    }
                )
                .dynamicTypeSize(dynamicTypeSize)
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
