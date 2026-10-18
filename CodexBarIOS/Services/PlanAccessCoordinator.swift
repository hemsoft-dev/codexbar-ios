import Combine

/// Binds the app's single entitlement to its account, fetch and history policies before rendering.
@MainActor
final class PlanAccessCoordinator: ObservableObject {
    private var subscription: AnyCancellable?

    init(entitlement: ProEntitlement, configurationStore: ProviderConfigurationStore,
         refreshService: UsageRefreshService, historyStore: UsageHistoryStore) {
        let apply: (ProAccessState) -> Void = { state in
            let observedIDs = Set(refreshService.results.map(\.accountID))
            let savedResults = configurationStore.visibleConfigurations.filter { !observedIDs.contains($0.id) }
                .compactMap { historyStore.lastStoredResult(for: $0) }
            let order = DashboardProviderCardItem.items(
                configurations: configurationStore.visibleConfigurations,
                results: refreshService.results + savedResults,
                refreshingAccountIDs: refreshService.refreshingAccountIDs,
                errorsByAccountID: refreshService.refreshErrorsByAccountID,
                orderingMode: configurationStore.dashboardOrderingMode,
                manualOrder: configurationStore.dashboardCardOrder,
                severityThresholds: configurationStore.usageAlertSettings.severityThresholds
            ).map(\.id)
            configurationStore.applyPlanAccess(hasProAccess: state.hasAccess, isResolved: state.isResolved, dashboardOrder: order)
            refreshService.updateCurrentConfigurations(configurationStore.configurations)
            refreshService.updateAccountAccess(configurationStore.accountAccess)
            historyStore.applyHistoryAccess(hasProAccess: state.hasAccess)
        }
        apply(entitlement.accessState)
        subscription = entitlement.accessChanges.removeDuplicates().sink(receiveValue: apply)
    }
}
