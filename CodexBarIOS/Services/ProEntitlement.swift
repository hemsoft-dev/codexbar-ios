import Combine
import Foundation

@MainActor
public final class ProEntitlement: ObservableObject {
    @Published public private(set) var value: ProEntitlementValue {
        didSet { accessChanges.send(accessState) }
    }
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var isResolved = false {
        didSet { accessChanges.send(accessState) }
    }
    /// Unlike @Published, this delivers after the evidence and resolution flag are committed.
    let accessChanges = PassthroughSubject<ProAccessState, Never>()
    @Published private(set) var subscription: ProSubscriptionEvidence?
    private(set) var appPurchase: ProVerification<ProAppPurchase> = .unavailable

    private let source: any ProStoreSource
    private let cache: any ProEntitlementCaching
    private let originalPolicy: ProOriginalPurchaserPolicy
    private let now: @MainActor () -> Date
    private let clock: @MainActor (Date) -> ProEntitlementClockSample
    private var purchases: [ProProductID: ProPurchaseEvidence] = [:]
    private var statuses: [ProProductID: ProSubscriptionEvidence] = [:]
    private var transactionTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var boundaryTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var refreshRequest = 0
    private var unverifiedProducts: Set<ProProductID> = []
    private var started = false
    // Only a newly accepted verification can restore missing widget clock storage.
    private var widgetVerificationGenerations: [ProStoreEnvironment: UUID] = [:]
    var widgetVerificationGeneration: UUID? { widgetVerificationGenerations[value.environment] }
    private var currentEnvironment: ProStoreEnvironment?
    private var appVerificationEnvironment: ProStoreEnvironment?
    #if DEBUG
    private var debugOverride: ProEntitlementValue?
    #endif

    init(
        source: any ProStoreSource,
        cache: any ProEntitlementCaching,
        originalPolicy: ProOriginalPurchaserPolicy = ProOriginalPurchaserPolicy(),
        now: @escaping @MainActor () -> Date = Date.init,
        clock: @escaping @MainActor (Date) -> ProEntitlementClockSample = { ProEntitlementSystemClock.sample(at: $0) }
    ) {
        self.source = source
        self.cache = cache
        self.originalPolicy = originalPolicy
        self.now = now
        self.clock = clock
        // Keep the signed-time watermark even when its grant has expired or boot continuity was lost.
        value = cache.load() ?? .free
    }

    static func live() -> ProEntitlement {
        ProEntitlement(source: StoreKitProStoreSource(), cache: ProEntitlementCache.appGroup)
    }

    deinit {
        transactionTask?.cancel()
        statusTask?.cancel()
        boundaryTask?.cancel()
    }

    public var hasAccess: Bool { value.hasAccess(at: clock(now())) }

    var accessState: ProAccessState { ProAccessState(hasAccess: hasAccess, isResolved: isResolved) }

    func snapshotAccess() -> SnapshotProAccess {
        let sample = clock(now())
        return SnapshotProAccess(
            isProLocked: !value.hasAccess(at: sample), proAccessEndsAt: value.proAccessEndsAt,
            proAccessEffectiveAt: value.proAccessEndsAt == nil ? nil : value.clockAnchor?.effectiveDate(at: sample),
            clockAnchor: value.clockAnchor, verificationGeneration: widgetVerificationGeneration,
            environment: value.environment
        )
    }

    /// Attach both listeners before the first snapshot so launch cannot miss a delivery.
    public func start() async {
        guard !started else { return }
        started = true
        scheduleBoundary()
        let transactions = source.transactionUpdates()
        let subscriptions = source.subscriptionUpdates()
        transactionTask = Task { [weak self] in
            for await delivery in transactions {
                guard !Task.isCancelled else { return }
                await self?.receive(delivery)
            }
        }
        statusTask = Task { [weak self] in
            for await status in subscriptions {
                guard !Task.isCancelled else { return }
                await self?.receive(status)
            }
        }
        await refresh()
    }

    public func refresh() async {
        reevaluateLocalAccess()
        refreshRequest += 1
        let request = refreshRequest
        while !Task.isCancelled {
            let generation = refreshGeneration
            let snapshot = await source.snapshot()
            guard request == refreshRequest else { return }
            // A concurrent delivery may concern a different product. Re-read the complete
            // snapshot instead of losing independent entitlements during launch.
            guard generation == refreshGeneration else { continue }
            _ = publish(snapshot)
            isResolved = true
            return
        }
    }

    func purchase(_ product: ProProductID) async throws -> ProPurchaseOutcome {
        let outcome = try await source.purchase(product)
        if case let .purchased(delivery) = outcome { await receive(delivery) }
        return outcome
    }

    /// Called by an explicit Restore action, never by startup or foreground refresh.
    public func restore() async throws {
        let refreshAppTransaction: Bool
        if case let .verified(purchase) = appPurchase {
            let sample = clock(now())
            let deniedAppPurchase = purchase.revoked || value.appPurchaseDeniedAt.map {
                (purchase.signedAt ?? .distantPast) <= $0
            } == true
            refreshAppTransaction = deniedAppPurchase || value.clockAnchor.map {
                $0.effectiveDate(at: sample) == nil || $0.knownDate > sample.wallDate
            } ?? false
        } else { refreshAppTransaction = true }
        try await source.restore(refreshAppTransaction: refreshAppTransaction)
        await refresh()
    }

    func receive(_ delivery: ProTransactionDelivery) async {
        refreshGeneration += 1
        var snapshot = ProStoreSnapshot(appPurchase: appPurchase, appVerificationEnvironment: appVerificationEnvironment)
        switch delivery.evidence {
        case let .verified(purchase):
            snapshot.purchases.append(purchase)
        case .unverified:
            // A failed verification cannot establish a new environment or overwrite another environment's cache.
            guard let environment = delivery.environment, environment == (currentEnvironment ?? value.environment) else { return }
            snapshot.unverifiedPurchases.insert(ProUnverifiedPurchase(product: delivery.product, environment: environment))
        case .unavailable:
            return
        }
        let saved = publish(snapshot)
        if saved, case .verified = delivery.evidence { await delivery.finish() }
    }

    func receive(_ update: ProSubscriptionUpdate) async {
        switch update {
        case let .verified(status):
            await receive(status)
        case let .unverified(product, environment):
            await receive(ProTransactionDelivery(
                product: product, evidence: .unverified, environment: environment, finish: {}
            ))
        }
    }

    func receive(_ status: ProSubscriptionEvidence) async {
        refreshGeneration += 1
        _ = publish(ProStoreSnapshot(
            appPurchase: appPurchase, appVerificationEnvironment: appVerificationEnvironment,
            purchases: [status.purchase], subscriptions: [status]
        ))
    }

    @discardableResult
    private func publish(_ incoming: ProStoreSnapshot) -> Bool {
        #if DEBUG
        if debugOverride != nil { return false }
        #endif
        var snapshot = scoped(incoming)
        let incoming = snapshot
        // Keep denial evidence even when saving fails, so unrelated later events cannot resurrect an old grant.
        appPurchase = incoming.appPurchase
        appVerificationEnvironment = incoming.appVerificationEnvironment
        let verifiedProducts = Set(incoming.purchases.map(\.product) + incoming.subscriptions.map(\.purchase.product))
            .subtracting(incoming.unverifiedProducts)
        unverifiedProducts.subtract(verifiedProducts)
        unverifiedProducts.formUnion(incoming.unverifiedProducts)
        snapshot.unverifiedPurchases = Set(unverifiedProducts.map {
            ProUnverifiedPurchase(product: $0, environment: currentEnvironment ?? value.environment)
        })
        for purchase in incoming.purchases { remember(purchase) }
        for status in incoming.subscriptions { remember(status) }
        snapshot.purchases = Array(purchases.values)
        snapshot.subscriptions = Array(statuses.values)
        let instant = now()
        let candidate = ProEntitlementResolver.resolve(
            snapshot, cached: value, originalPolicy: originalPolicy, now: instant, clock: clock(instant)
        )
        let resolved = preservingVerificationDate(candidate, incoming: incoming)
        do {
            try cache.save(resolved)
        } catch {
            statusMessage = "Purchase verification could not be saved. Try Restore Purchases."
            // A rejected grant must also be invalidated on disk before a cold start can read it.
            if !canRetainCurrentValue(snapshot) {
                value = candidate.withoutAccess(at: clock(instant))
                do { try cache.invalidate(with: value) } catch {
                    statusMessage = "Purchase storage could not be updated or cleared. Try Restore Purchases."
                }
            }
            return false
        }
        if resolved.clockAnchor?.latestSignedAt != value.clockAnchor?.latestSignedAt
            || (resolved.proAccessEndsAt != value.proAccessEndsAt && !verifiedProducts.isEmpty) {
            widgetVerificationGenerations[resolved.environment] = UUID()
        }
        value = resolved
        subscription = statuses.values.max {
            ($0.purchase.expiresAt ?? .distantPast) < ($1.purchase.expiresAt ?? .distantPast)
        }
        let appUnverified: Bool
        if case .unverified = incoming.appPurchase { appUnverified = true } else { appUnverified = false }
        statusMessage = unverifiedProducts.isEmpty && !appUnverified ? nil : "A purchase could not be verified. Try Restore Purchases."
        scheduleBoundary()
        return true
    }

    private func preservingVerificationDate(_ candidate: ProEntitlementValue, incoming: ProStoreSnapshot) -> ProEntitlementValue {
        guard candidate.reason == value.reason, candidate.expiresAt == value.expiresAt,
              candidate.proAccessEndsAt == value.proAccessEndsAt, candidate.environment == value.environment,
              candidate.purchasedAt == value.purchasedAt, candidate.purchaseDenials == value.purchaseDenials,
              candidate.appPurchaseDeniedAt == value.appPurchaseDeniedAt else { return candidate }
        let verified: Bool
        if candidate.reason == .originalPurchaser {
            if case .verified = incoming.appPurchase { verified = true } else { verified = false }
        } else {
            let product = candidate.reason == .lifetime ? ProProductID.lifetime : candidate.subscriptionProduct
            verified = incoming.purchases.contains { $0.product == product }
        }
        return verified ? candidate : value.withClockAnchor(candidate.clockAnchor)
    }

    private func scoped(_ incoming: ProStoreSnapshot) -> ProStoreSnapshot {
        var snapshot = incoming
        let environment: ProStoreEnvironment
        if case let .verified(app) = incoming.appPurchase {
            environment = app.environment
        } else if case let .verified(app) = appPurchase {
            environment = app.environment
        } else {
            environment = incoming.purchases.first?.environment ?? currentEnvironment ?? .production
        }
        if environment != (currentEnvironment ?? value.environment) {
            purchases.removeAll()
            statuses.removeAll()
            unverifiedProducts.removeAll()
            value = cache.load(environment: environment) ?? ProEntitlementValue(
                reason: .none, expiresAt: nil, proAccessEndsAt: nil, verifiedAt: nil, environment: environment
            )
        }
        currentEnvironment = environment
        if snapshot.freshClockEvidence?.environment != environment { snapshot.freshClockEvidence = nil }
        if case .unverified = incoming.appPurchase, incoming.appVerificationEnvironment != environment {
            snapshot.appPurchase = .unavailable
        }
        snapshot.purchases = incoming.purchases.filter { accepts($0, environment: environment) }
        snapshot.subscriptions = incoming.subscriptions.filter {
            accepts($0.purchase, environment: environment, statusSignedAt: $0.renewalVerified ? $0.signedAt : nil)
        }
        snapshot.unverifiedPurchases = incoming.unverifiedPurchases.filter { $0.environment == environment }
        return snapshot
    }

    private func accepts(_ purchase: ProPurchaseEvidence, environment: ProStoreEnvironment, statusSignedAt: Date? = nil) -> Bool {
        guard purchase.environment == environment else { return false }
        let product = value.reason == .lifetime ? ProProductID.lifetime : value.subscriptionProduct
        if purchase.product == product, let grantedAt = value.purchasedAt, purchase.purchasedAt < grantedAt {
            return false
        }
        if let denial = value.purchaseDenials.first(where: { $0.product == purchase.product }),
           !denial.allows(purchasedAt: purchase.purchasedAt, signedAt: max(purchase.signedAt, statusSignedAt ?? .distantPast)) {
            return (purchase.revoked || purchase.upgraded) && purchase.purchasedAt == denial.purchasedAt
        }
        return true
    }

    private func canRetainCurrentValue(_ snapshot: ProStoreSnapshot) -> Bool {
        let product = value.reason == .lifetime ? ProProductID.lifetime : value.subscriptionProduct
        let current = ProStoreSnapshot(
            appPurchase: value.reason == .originalPurchaser ? snapshot.appPurchase : .unavailable,
            purchases: snapshot.purchases.filter { $0.product == product },
            unverifiedPurchases: snapshot.unverifiedPurchases,
            subscriptions: snapshot.subscriptions.filter { $0.purchase.product == product }
        )
        let instant = now()
        let sample = clock(instant)
        // A verified purchase can remain recoverable while timing is uncertain.
        // Retain its metadata; hasAccess continues to deny until the clock recovers.
        return ProEntitlementResolver.resolve(
            current, cached: value, originalPolicy: originalPolicy, now: instant, clock: sample
        ).reason != .none
    }

    private func remember(_ purchase: ProPurchaseEvidence) {
        if let existing = purchases[purchase.product], !purchase.isNewer(than: existing) { return }
        purchases[purchase.product] = purchase
        if let status = statuses[purchase.product], status.purchase.transactionID != purchase.transactionID {
            statuses.removeValue(forKey: purchase.product)
        }
    }

    private func remember(_ status: ProSubscriptionEvidence) {
        remember(status.purchase)
        guard purchases[status.purchase.product]?.transactionID == status.purchase.transactionID else { return }
        if let existing = statuses[status.purchase.product], status.signedAt < existing.signedAt { return }
        statuses[status.purchase.product] = status
    }

    private func scheduleBoundary() {
        boundaryTask?.cancel()
        guard let instant = value.clockAnchor?.effectiveDate(at: clock(now())) else { return }
        let boundary = [value.expiresAt, value.proAccessEndsAt].compactMap { $0 }.filter { $0 > instant }.min()
        guard started, let boundary else { return }
        let delay = boundary.timeIntervalSince(instant)
        boundaryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.boundaryTask = nil
            self.reevaluateLocalAccess()
            await self.refresh()
        }
    }

    /// Commit clock changes before any StoreKit await so all dependent policies see the same access.
    public func reevaluateLocalAccess() {
        let sample = clock(now())
        if !value.hasAccess(at: sample), value.clockAnchor?.effectiveDate(at: sample) != nil {
            let expired = value.withoutAccess(at: sample)
            if expired != value {
                value = expired
                try? cache.save(expired)
            }
        }
        // Clock uncertainty denies access but preserves evidence for automatic recovery.
        accessChanges.send(accessState)
        scheduleBoundary()
    }

    #if DEBUG
    func setDebugOverride(_ override: ProEntitlementValue?) {
        debugOverride = override
        value = override ?? cache.load() ?? .free
        boundaryTask?.cancel()
    }
    #endif
}

struct ProAccessState: Equatable {
    let hasAccess: Bool
    let isResolved: Bool
}
