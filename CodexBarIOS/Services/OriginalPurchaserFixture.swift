#if DEBUG
import Foundation

/// Reached only through UITestFixtures' simulator-only, UUID-namespaced launch route.
/// Neither synthetic StoreKit evidence nor its cache is reachable from a release build.
@MainActor
struct OriginalPurchaserFixture {
    let entitlement: ProEntitlement
    let notice: OriginalPurchaserNotice

    init?(scenario: String?, defaults: UserDefaults) {
        let offset: TimeInterval
        switch scenario {
        case "original-purchaser-before": offset = -60
        case "original-purchaser-after": offset = 60
        default: return nil
        }
        let instant = ProOriginalPurchaserPolicy.cutover.addingTimeInterval(offset)
        entitlement = ProEntitlement(
            source: OriginalPurchaserFixtureSource(instant: instant),
            cache: OriginalPurchaserFixtureCache(), now: { instant },
            clock: { ProEntitlementClockSample(wallDate: $0, continuousSeconds: $0.timeIntervalSince1970, continuityID: "original-fixture") }
        )
        notice = OriginalPurchaserNotice(defaults: defaults, now: { instant })
    }
}

@MainActor
private final class OriginalPurchaserFixtureSource: ProStoreSource {
    let instant: Date

    init(instant: Date) { self.instant = instant }

    func snapshot() async -> ProStoreSnapshot {
        ProStoreSnapshot(appPurchase: .verified(ProAppPurchase(
            originalVersion: "4", originalPurchaseDate: ProOriginalPurchaserPolicy.cutover.addingTimeInterval(-86_400),
            environment: .production, revoked: false, signedAt: instant
        )))
    }

    func transactionUpdates() -> AsyncStream<ProTransactionDelivery> { AsyncStream { $0.finish() } }
    func subscriptionUpdates() -> AsyncStream<ProSubscriptionUpdate> { AsyncStream { $0.finish() } }
    func purchase(_ product: ProProductID) async throws -> ProPurchaseOutcome { .cancelled }
    func restore(refreshAppTransaction: Bool) async throws {}
}

@MainActor
private final class OriginalPurchaserFixtureCache: ProEntitlementCaching {
    private var value: ProEntitlementValue?
    func load(environment: ProStoreEnvironment) -> ProEntitlementValue? { value?.environment == environment ? value : nil }
    func save(_ value: ProEntitlementValue) throws { self.value = value }
    func invalidate(with deniedValue: ProEntitlementValue) throws { value = deniedValue }
}
#endif
