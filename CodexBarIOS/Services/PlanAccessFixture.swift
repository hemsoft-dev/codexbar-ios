#if DEBUG
import Foundation
import SwiftUI

/// Synthetic evidence stays in memory and is reachable only from explicit preview/test routes.
@MainActor
final class PlanAccessFixture: ObservableObject {
    let entitlement: ProEntitlement
    private let source: PlanFixtureSource
    @Published private(set) var hasProAccess: Bool

    init(hasProAccess: Bool = true) {
        self.hasProAccess = hasProAccess
        source = PlanFixtureSource(hasProAccess: hasProAccess)
        entitlement = ProEntitlement(source: source, cache: PlanFixtureCache(hasProAccess: hasProAccess))
    }

    func setProAccess(_ hasAccess: Bool) async {
        hasProAccess = hasAccess
        source.hasProAccess = hasAccess
        // Publish an explicit revocation followed by a later verified repurchase, exercising
        // the same committed entitlement path as production without invoking StoreKit.
        await entitlement.receive(ProTransactionDelivery(
            product: .lifetime, evidence: .verified(source.purchaseEvidence), finish: {}
        ))
        await entitlement.refresh()
    }
}

@MainActor
private final class PlanFixtureSource: ProStoreSource {
    var hasProAccess: Bool
    private var sequence: TimeInterval = 0
    private let epoch = Date().addingTimeInterval(-3_600)

    init(hasProAccess: Bool) { self.hasProAccess = hasProAccess }

    var purchaseEvidence: ProPurchaseEvidence {
        sequence += 1
        return ProPurchaseEvidence(product: .lifetime, transactionID: UInt64(sequence),
                                   purchasedAt: epoch.addingTimeInterval(sequence),
                                   signedAt: epoch.addingTimeInterval(sequence), revoked: !hasProAccess)
    }

    func snapshot() async -> ProStoreSnapshot {
        ProStoreSnapshot(purchases: [purchaseEvidence])
    }
    func transactionUpdates() -> AsyncStream<ProTransactionDelivery> { AsyncStream { $0.finish() } }
    func subscriptionUpdates() -> AsyncStream<ProSubscriptionUpdate> { AsyncStream { $0.finish() } }
    func purchase(_ product: ProProductID) async throws -> ProPurchaseOutcome { .cancelled }
    func restore(refreshAppTransaction: Bool) async throws {}
}

@MainActor
private final class PlanFixtureCache: ProEntitlementCaching {
    private var value: ProEntitlementValue
    init(hasProAccess: Bool) {
        value = hasProAccess ? ProEntitlementValue(reason: .lifetime, expiresAt: nil,
                                                 proAccessEndsAt: nil, verifiedAt: Date()) : .free
    }
    func load(environment: ProStoreEnvironment) -> ProEntitlementValue? { value.environment == environment ? value : nil }
    func save(_ value: ProEntitlementValue) throws { self.value = value }
    func invalidate(with deniedValue: ProEntitlementValue) throws { value = deniedValue }
}

@MainActor
final class IsolatedPlanFixtureEffects: UsageAlertNotifying, WatchSnapshotSending {
    func requestAuthorization() async -> Bool { false }
    func deliver(_ notification: UsageAlertNotification) async throws {}
    func activate(onSnapshotNeeded: @escaping @MainActor (Bool) -> Void) {}
    func publish(_ snapshot: WatchDashboardSnapshot, force: Bool) -> Bool { false }
}

/// Only the simulator's UUID-isolated plan-transition fixture installs this control.
struct PlanTransitionFixtureControls: View {
    @ObservedObject var fixture: PlanAccessFixture
    var body: some View {
        HStack {
            Text(fixture.hasProAccess ? "Fixture: Pro" : "Fixture: Free")
            Spacer()
            Button(fixture.hasProAccess ? "Simulate downgrade" : "Simulate upgrade") {
                Task { await fixture.setProAccess(!fixture.hasProAccess) }
            }
            .accessibilityIdentifier("fixture.plan.transition")
        }
        .font(.caption)
        .padding(10)
        .background(.regularMaterial)
    }
}
@MainActor
enum PlanTierFixture {
    static func isScenario(_ scenario: String?) -> Bool {
        scenario?.hasPrefix("plan-free") == true || scenario == "plan-transition" || scenario == "plan-pro"
    }

    static func initialResults(in store: ProviderConfigurationStore, scenario: String?) -> [ProviderUsageResult]? {
        guard isScenario(scenario) else { return nil }
        return scenario == "plan-free-cold" ? [] : store.visibleConfigurations.map { result(for: $0) }
    }

    static func seedHistoryIfNeeded(in history: UsageHistoryStore, accounts: [ProviderAccountConfiguration], scenario: String?) {
        guard isScenario(scenario), history.snapshots.isEmpty else { return }
        seedHistory(in: history, accounts: accounts)
    }

    static func seedAccountsIfNeeded(in store: ProviderConfigurationStore, scenario: String?) {
        guard isScenario(scenario) else { return }
        seedAccounts(in: store, multiple: scenario != "plan-free")
    }

    static func providers(overriding providers: [any UsageProvider], scenario: String?) -> [any UsageProvider] {
        isScenario(scenario) ? [PlanTierFixtureProvider()] : providers
    }

    static func seedAccounts(in store: ProviderConfigurationStore, multiple: Bool) {
        if store.configurations.isEmpty {
            for (index, label) in (multiple ? ["Personal account", "Work account", "Family account"] : ["Personal account"]).enumerated() {
                let account = ProviderAccountConfiguration(id: "plan-account-\(index)", providerID: .openRouter,
                                                          accountLabel: label, authMethod: .apiKey)
                precondition(store.update(account))
                precondition(store.saveSecret("ui-test-credential", for: account))
            }
        }
        store.updateUsageAlertsEnabled(true)
        store.updateUsageAlertBalanceThreshold(15)
    }

    static func seedHistory(in history: UsageHistoryStore, accounts: [ProviderAccountConfiguration]) {
        let now = Date()
        for daysAgo in [60.0, 20.0, 9.0, 6.0, 2.0, 0.0] {
            let observed = now.addingTimeInterval(-daysAgo * 86_400)
            history.record(results: accounts.map { result(for: $0, fetchedAt: observed) }, now: now)
        }
    }

    nonisolated static func result(for account: ProviderAccountConfiguration, fetchedAt: Date = Date()) -> ProviderUsageResult {
        ProviderUsageResult(accountID: account.id, providerID: .openRouter, title: account.displayName,
                            subtitle: "Isolated plan fixture", bars: [
                                UsageBar(stableKey: "monthly", label: "Monthly usage", used: 92, limit: 100),
                            ], creditsRemaining: account.id == "plan-account-1" ? 8 : 5, fetchedAt: fetchedAt)
    }
}

struct PlanTierFixtureProvider: UsageProvider {
    let providerID = ProviderID.openRouter
    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        PlanTierFixture.result(for: configuration)
    }
}
#endif
