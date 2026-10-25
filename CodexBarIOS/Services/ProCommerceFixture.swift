#if DEBUG
import Foundation
#if targetEnvironment(simulator)
import OSLog

/// Observations only: never supplies readiness or changes a StoreKit operation.
@MainActor
enum ProNativeReadinessTrace {
    enum Stage: String {
        case snapshotBegin, snapshotEnd, appTransactionBegin, appTransactionReturn, appTransactionError
        case entitlementsBegin, entitlementsEnd, latestBegin, latestReturn
        case snapshotProductsBegin, snapshotProductsReturn, statusBegin, statusReturn, snapshotError
        case catalogBegin, catalogEnd, catalogError, storefrontBegin, storefrontReturn
        case productsBegin, productsReturn, modelsBegin, modelsEnd, finalStorefrontBegin, finalStorefrontReturn
        case viewRefreshBegin, viewRefreshEnd, viewReadiness
    }

    private static let logger = Logger(subsystem: "com.hemsoft.CodexBarIOS.native-readiness", category: "fixture")
    private static let launch = UUID().uuidString
    private static var sequence = 0
    private static var previousReadiness: String?

    static func runID(environment: [String: String]) -> UUID? {
        guard environment["CODEXBAR_UI_TESTS"] == "1",
              environment["CODEXBAR_UI_TEST_SCENARIO"] == "commerce-native-storekit",
              let raw = environment["CODEXBAR_UI_TEST_RUN_ID"] else { return nil }
        return UUID(uuidString: raw)
    }

    static func emit(_ stage: Stage, count: Int = 0, operation: UUID? = nil) {
        guard let run = runID(environment: ProcessInfo.processInfo.environment) else { return }
        let wallBefore = Date().timeIntervalSince1970
        let uptime = ProcessInfo.processInfo.systemUptime
        let wallAfter = Date().timeIntervalSince1970
        sequence += 1
        let record: [String: Any] = [
            "schema": 1, "stage": stage.rawValue, "run": run.uuidString, "launch": launch,
            "sequence": sequence, "pid": ProcessInfo.processInfo.processIdentifier, "count": count,
            "operation": operation?.uuidString ?? "none",
            "wallBefore": wallBefore, "uptime": uptime, "wallAfter": wallAfter,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let message = String(data: data, encoding: .utf8) else { return }
        logger.notice("CB517NATIVE \(message, privacy: .public)")
    }

    static func readiness(_ ready: Bool, resolved: Bool, refreshing: Bool, catalog: Int) {
        guard runID(environment: ProcessInfo.processInfo.environment) != nil else { return }
        // Non-observed storage cannot invalidate SwiftUI or schedule more refreshes.
        let state = "\(ready)-\(resolved)-\(refreshing)-\(catalog)"
        guard previousReadiness != state else { return }
        previousReadiness = state
        // Fixed bit fields: ready=1, resolved=2, refreshing=4; catalog enum occupies bits 3+.
        emit(.viewReadiness, count: (ready ? 1 : 0) | (resolved ? 2 : 0) | (refreshing ? 4 : 0) | (catalog << 3))
    }
}
#endif

/// Explicit simulator fixtures share the production reducer but never its stores or listeners.
@MainActor
final class ProCommerceFixture {
    static let instant = Date(timeIntervalSince1970: 1_794_312_000)
    let entitlement: ProEntitlement
    let isSynthetic: Bool
    let scenario: String
    let entry: ProPresentationOrigin?
    private let source: ProCommerceFixtureSource?

    static let scenarios: Set<String> = [
        "commerce-free-trial", "commerce-free-no-trial", "commerce-free-no-offer", "commerce-free-unknown-trial", "commerce-free-eur",
        "commerce-trial", "commerce-trial-monthly", "commerce-trial-no-price", "commerce-trial-off",
        "commerce-monthly-on", "commerce-monthly-off", "commerce-monthly-unknown",
        "commerce-yearly-on", "commerce-yearly-off", "commerce-yearly-unknown", "commerce-lifetime", "commerce-original",
        "commerce-overlap-lifetime", "commerce-overlap-original", "commerce-grace", "commerce-retry", "commerce-lifetime-billing",
        "commerce-cached", "commerce-expired", "commerce-revoked", "commerce-loading", "commerce-catalog-error", "commerce-partial",
        "commerce-checking", "commerce-pending", "commerce-cancelled", "commerce-purchase-error", "commerce-storage-error",
        "commerce-restore-error", "commerce-restore-cancelled", "commerce-native-storekit",
    ]

    init?(scenario: String?, runID: UUID, environment: [String: String]) {
        guard let scenario, scenario.hasPrefix("commerce-") else { return nil }
        precondition(Self.scenarios.contains(scenario), "Unknown isolated commerce scenario: \(scenario)")
        self.scenario = scenario
        switch environment["CODEXBAR_COMMERCE_ENTRY"] {
        case "settings": entry = .settings
        case "limit": entry = .limit
        default: entry = nil
        }
        isSynthetic = scenario != "commerce-native-storekit"
        if !isSynthetic {
            source = nil
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("codexbar-commerce-\(runID.uuidString)", isDirectory: true)
            if environment["CODEXBAR_UI_TEST_RESET"] == "1" {
                try? FileManager.default.removeItem(at: directory)
            }
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch {
                preconditionFailure("Cannot create isolated commerce cache: \(error)")
            }
            entitlement = ProEntitlement(
                source: StoreKitProStoreSource(),
                cache: ProEntitlementCache(fileURL: directory.appendingPathComponent("entitlement.json")),
                clock: {
                    ProEntitlementClockSample(wallDate: $0, continuousSeconds: ProcessInfo.processInfo.systemUptime,
                                              continuityID: runID.uuidString)
                }
            )
        } else {
            let source = ProCommerceFixtureSource(scenario: scenario)
            self.source = source
            let cache = ProCommerceFixtureCache(failsPurchases: scenario == "commerce-storage-error")
            if scenario == "commerce-cached" { cache.seedCachedSubscription() }
            entitlement = ProEntitlement(
                source: source, cache: cache, now: { Self.instant },
                clock: {
                    ProEntitlementClockSample(wallDate: $0, continuousSeconds: $0.timeIntervalSince1970,
                                              continuityID: "commerce-fixture")
                }
            )
        }
    }

    func setAutoRenew(_ enabled: Bool) async {
        guard let source else { return }
        source.setAutoRenew(enabled)
        await entitlement.refreshCommerce()
    }

    func seedAccounts(in store: ProviderConfigurationStore) {
        PlanTierFixture.seedAccounts(in: store, multiple: false)
    }
}

@MainActor
private final class ProCommerceFixtureSource: ProStoreSource {
    let scenario: String
    private var next: ProStoreSnapshot
    private var sequence: UInt64 = 10
    private var storefrontID: String { scenario == "commerce-free-eur" ? "fixture-DEU" : "fixture-USA" }

    init(scenario: String) {
        self.scenario = scenario
        next = ProCommerceFixtureEvidence.snapshot(scenario: scenario)
    }

    func snapshot() async -> ProStoreSnapshot {
        if scenario == "commerce-checking" { try? await Task.sleep(for: .seconds(120)) }
        return next
    }

    func transactionUpdates() -> AsyncStream<ProTransactionDelivery> { AsyncStream { $0.finish() } }
    func subscriptionUpdates() -> AsyncStream<ProSubscriptionUpdate> { AsyncStream { $0.finish() } }

    func catalog() async throws -> ProCatalog {
        if scenario == "commerce-loading" { try await Task.sleep(for: .seconds(120)) }
        if scenario == "commerce-catalog-error" { throw ProCommerceFixtureError.catalog }
        let locale = Locale(identifier: scenario == "commerce-free-eur" ? "de_DE" : "en_US")
        let currency = scenario == "commerce-free-eur" ? "EUR" : "USD"
        let offer = ProIntroductoryOffer(isFreeTrial: true, period: .init(value: 1, unit: .week), numberOfPeriods: 1)
        var products: [ProProductID: ProCatalogProduct] = [:]
        for product in ProProductID.allCases {
            if scenario == "commerce-partial" && product == .yearly { continue }
            let amount = ProCommerceFixtureEvidence.price(for: product)
            let eligibility: ProIntroEligibility = scenario == "commerce-free-unknown-trial" ? .unknown
                : scenario == "commerce-free-no-trial" || !next.purchases.isEmpty ? .ineligible : .eligible
            products[product] = ProCatalogProduct(
                id: product, displayName: "CodexBar Pro \(ProCommerceFixtureEvidence.title(for: product))",
                displayPrice: amount.formatted(.currency(code: currency).locale(locale)),
                type: product == .lifetime ? .nonConsumable : .subscription,
                period: product == .lifetime ? nil : .init(value: 1, unit: product == .monthly ? .month : .year),
                subscriptionGroupID: product == .lifetime ? nil : "fixture-codexbar-pro",
                introductoryOffer: product == .yearly && scenario != "commerce-free-no-offer" ? offer : nil,
                introEligibility: eligibility, storefrontID: storefrontID
            )
        }
        return ProCatalog(products: products, storefrontID: storefrontID)
    }

    func purchase(_ product: ProProductID) async throws -> ProPurchaseOutcome {
        switch scenario {
        case "commerce-pending": return .pending
        case "commerce-cancelled": return .cancelled
        case "commerce-purchase-error": throw ProCommerceFixtureError.purchase
        default: break
        }
        sequence += 1
        let purchase = ProPurchaseEvidence(
            product: product, transactionID: sequence,
            purchasedAt: ProCommerceFixture.instant, signedAt: ProCommerceFixture.instant,
            expiresAt: product == .lifetime ? nil : ProCommerceFixture.instant.addingTimeInterval(7 * 86_400),
            isFreeTrial: product == .yearly && scenario != "commerce-free-no-trial", environment: .xcode
        )
        next.purchases.append(purchase)
        if product != .lifetime {
            next.subscriptions = [ProCommerceFixtureEvidence.status(purchase: purchase, renews: true)]
        }
        return .purchased(ProTransactionDelivery(product: product, evidence: .verified(purchase), environment: .xcode, finish: {}))
    }

    func restore(refreshAppTransaction: Bool) async throws {
        if scenario == "commerce-restore-error" { throw ProCommerceFixtureError.restore }
        if scenario == "commerce-restore-cancelled" { throw CancellationError() }
    }

    func setAutoRenew(_ enabled: Bool) {
        sequence += 1
        next.subscriptions = next.subscriptions.map {
            ProSubscriptionEvidence(
                purchase: $0.purchase, signedAt: ProCommerceFixture.instant.addingTimeInterval(TimeInterval(sequence)),
                state: $0.state, renewalVerified: true, willAutoRenew: enabled,
                isInBillingRetry: $0.isInBillingRetry, graceEndsAt: $0.graceEndsAt,
                nextRenewalProduct: $0.nextRenewalProduct, renewalPrice: $0.renewalPrice, renewalCurrency: $0.renewalCurrency
            )
        }
        next.subscriptionStatusAvailable = true
    }
}

@MainActor
private final class ProCommerceFixtureCache: ProEntitlementCaching {
    private var values: [ProStoreEnvironment: ProEntitlementValue] = [:]
    private let failsPurchases: Bool
    init(failsPurchases: Bool) { self.failsPurchases = failsPurchases }
    func load(environment: ProStoreEnvironment) -> ProEntitlementValue? { values[environment] }
    func save(_ value: ProEntitlementValue) throws {
        if failsPurchases && value.reason != .none { throw ProCommerceFixtureError.storage }
        values[value.environment] = value
    }
    func invalidate(with value: ProEntitlementValue) throws { values[value.environment] = value }

    func seedCachedSubscription() {
        let instant = ProCommerceFixture.instant
        values[.production] = ProEntitlementValue(
            reason: .yearly, expiresAt: instant.addingTimeInterval(7 * 86_400),
            proAccessEndsAt: instant.addingTimeInterval(10 * 86_400), verifiedAt: instant,
            clockAnchor: ProEntitlementClockAnchor(
                anchorDate: instant, continuousSeconds: instant.timeIntervalSince1970,
                continuityID: "commerce-fixture", latestSignedAt: instant
            )
        )
    }
}

private enum ProCommerceFixtureError: LocalizedError {
    case catalog, purchase, restore, storage
    var errorDescription: String? {
        switch self {
        case .catalog: "The App Store could not load prices. Please try again."
        case .purchase: "The purchase could not be completed. Please try again."
        case .restore: "Purchases could not be restored. Please try again."
        case .storage: "The isolated purchase cache is unavailable."
        }
    }
}
#endif
