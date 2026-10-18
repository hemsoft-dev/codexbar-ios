import Foundation

enum ProEntitlementResolver {
    static func resolve(
        _ snapshot: ProStoreSnapshot,
        cached: ProEntitlementValue,
        originalPolicy: ProOriginalPurchaserPolicy,
        now: Date,
        clock: ProEntitlementClockSample? = nil
    ) -> ProEntitlementValue {
        let sample = clock ?? ProEntitlementSystemClock.sample(at: now)
        let anchor = updatedAnchor(cached.clockAnchor, snapshot: snapshot, sample: sample)
        let effectiveDate = anchor?.effectiveDate(at: sample)
        let cached = cached.withClockAnchor(anchor)
        let value = resolveAtTime(
            snapshot, cached: cached, originalPolicy: originalPolicy, now: effectiveDate ?? now,
            timedAccess: effectiveDate != nil, cachedAccess: cached.hasAccess(at: sample)
        ).withClockAnchor(anchor)
        return value.reason == .none ? value.withoutAccess(at: sample) : value
    }

    private static func updatedAnchor(
        _ previous: ProEntitlementClockAnchor?, snapshot: ProStoreSnapshot, sample: ProEntitlementClockSample
    ) -> ProEntitlementClockAnchor? {
        guard let signedAt = snapshot.latestSignedAt, signedAt > (previous?.latestSignedAt ?? .distantPast),
              let continuityID = sample.continuityID, !continuityID.isEmpty,
              sample.continuousSeconds.isFinite, sample.continuousSeconds >= 0,
              sample.wallDate.timeIntervalSinceReferenceDate.isFinite else { return previous }
        let knownDate = max(previous?.anchorDate ?? .distantPast, previous?.effectiveDate(at: sample) ?? .distantPast)
        return ProEntitlementClockAnchor(
            anchorDate: max(sample.wallDate, max(signedAt, knownDate)),
            continuousSeconds: sample.continuousSeconds, continuityID: continuityID, latestSignedAt: signedAt
        )
    }

    private static func resolveAtTime(
        _ snapshot: ProStoreSnapshot, cached: ProEntitlementValue, originalPolicy: ProOriginalPurchaserPolicy,
        now: Date, timedAccess: Bool, cachedAccess: Bool
    ) -> ProEntitlementValue {
        if originalAccess(snapshot.appPurchase, cached: cached, policy: originalPolicy, now: now) {
            if case .unavailable = snapshot.appPurchase { return cached }
            return permanent(.originalPurchaser, now: now)
        }
        if lifetimeAccess(snapshot, cached: cached, now: now) {
            if !snapshot.purchases.contains(where: { $0.product == .lifetime }) { return cached }
            let purchase = snapshot.purchases.first { $0.product == .lifetime }
            return permanent(.lifetime, now: now, purchase: purchase)
        }
        let candidates = timedAccess ? snapshot.purchases.compactMap { subscription($0, snapshot: snapshot, now: now) } : []
        let offline = cachedAccess && canUseOfflineSubscription(cached, snapshot: snapshot, now: now)
        if let best = candidates.max(by: { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) }) {
            if offline, (cached.expiresAt ?? .distantPast) > (best.expiresAt ?? .distantPast) { return cached }
            return best
        }
        if offline { return cached }
        return ProEntitlementValue(
            reason: .none, expiresAt: nil, proAccessEndsAt: nil, verifiedAt: now, environment: cached.environment
        )
    }

    private static func originalAccess(
        _ evidence: ProVerification<ProAppPurchase>,
        cached: ProEntitlementValue,
        policy: ProOriginalPurchaserPolicy,
        now: Date
    ) -> Bool {
        switch evidence {
        case let .verified(purchase):
            return purchase.isProduction && !purchase.revoked && policy.qualifies(purchase)
        case .unverified:
            return false
        case .unavailable:
            return cached.reason == .originalPurchaser && cached.hasAccess(at: now)
        }
    }

    private static func lifetimeAccess(_ snapshot: ProStoreSnapshot, cached: ProEntitlementValue, now: Date) -> Bool {
        guard !snapshot.unverifiedProducts.contains(.lifetime) else { return false }
        if let purchase = snapshot.purchases.first(where: { $0.product == .lifetime }) {
            return !purchase.revoked && !purchase.upgraded
        }
        // An empty, nonthrowing currentEntitlements sequence is not a verified revocation.
        return cached.reason == .lifetime && cached.hasAccess(at: now)
    }

    private static func subscription(
        _ purchase: ProPurchaseEvidence,
        snapshot: ProStoreSnapshot,
        now: Date
    ) -> ProEntitlementValue? {
        guard purchase.product != .lifetime, !purchase.revoked, !purchase.upgraded,
              !snapshot.unverifiedProducts.contains(purchase.product), let signedExpiry = purchase.expiresAt else { return nil }
        let status = snapshot.subscriptions.first { $0.purchase.transactionID == purchase.transactionID }
        if status?.deniesAccess(at: now) == true { return nil }
        let grace = status.flatMap { $0.renewalVerified ? $0.graceEndsAt : nil }
        let expiry = max(signedExpiry, grace ?? signedExpiry)
        guard expiry > now else { return nil }
        let reason: ProEntitlementReason
        if let status, status.renewalVerified,
           status.state == .grace || grace.map({ $0 > now }) == true {
            reason = .billingGrace
        } else if purchase.product == .yearly && purchase.isFreeTrial {
            reason = .trial
        } else {
            reason = purchase.product == .yearly ? .yearly : .monthly
        }
        return ProEntitlementValue(
            reason: reason, expiresAt: expiry,
            proAccessEndsAt: expiry.addingTimeInterval(ProEntitlementValue.offlineAllowance), verifiedAt: now,
            subscriptionProduct: purchase.product, environment: purchase.environment, purchasedAt: purchase.purchasedAt
        )
    }

    private static func canUseOfflineSubscription(
        _ cached: ProEntitlementValue, snapshot: ProStoreSnapshot, now: Date
    ) -> Bool {
        guard !cached.reason.isPermanent, let product = cached.subscriptionProduct,
              !snapshot.unverifiedProducts.contains(product) else { return false }
        let denied = snapshot.subscriptions.contains { $0.purchase.product == product && $0.deniesAccess(at: now) }
        let revoked = snapshot.purchases.contains { $0.product == product && ($0.revoked || $0.upgraded) }
        return !denied && !revoked
    }

    private static func permanent(
        _ reason: ProEntitlementReason, now: Date, purchase: ProPurchaseEvidence? = nil
    ) -> ProEntitlementValue {
        ProEntitlementValue(
            reason: reason, expiresAt: nil, proAccessEndsAt: nil, verifiedAt: now,
            environment: purchase?.environment ?? .production, purchasedAt: purchase?.purchasedAt
        )
    }
}
