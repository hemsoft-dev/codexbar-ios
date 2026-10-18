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
        ).withClockAnchor(anchor).withPurchaseDenials(
            denials(snapshot, cached: cached, now: effectiveDate ?? now),
            appPurchaseDeniedAt: appDenial(snapshot.appPurchase, cached: cached)
        )
        return value.reason == .none ? value.withoutAccess(at: sample) : value
    }

    private static func updatedAnchor(
        _ previous: ProEntitlementClockAnchor?, snapshot: ProStoreSnapshot, sample: ProEntitlementClockSample
    ) -> ProEntitlementClockAnchor? {
        let previous = previous?.checkpoint(at: sample)
        guard let signedAt = snapshot.latestSignedAt, signedAt > (previous?.latestSignedAt ?? .distantPast),
              sample.wallDate.timeIntervalSinceReferenceDate.isFinite else { return previous }
        let validCounter = sample.continuousSeconds.isFinite && sample.continuousSeconds >= 0
        let continuityID = validCounter ? sample.continuityID.flatMap { $0.isEmpty ? nil : $0 } : nil
        let explicitReset = snapshot.freshClockEvidence.map {
            $0.signedAt > (previous?.latestSignedAt ?? .distantPast)
        } == true
        let knownDate = explicitReset ? Date.distantPast : max(
            previous?.knownDate ?? .distantPast, previous?.effectiveDate(at: sample) ?? .distantPast
        )
        return ProEntitlementClockAnchor(
            anchorDate: max(sample.wallDate, max(signedAt, knownDate)),
            continuousSeconds: validCounter ? sample.continuousSeconds : 0,
            continuityID: continuityID ?? "unavailable", latestSignedAt: signedAt
        )
    }

    private static func denials(
        _ snapshot: ProStoreSnapshot, cached: ProEntitlementValue, now: Date
    ) -> [ProPurchaseDenial] {
        var result = Dictionary(uniqueKeysWithValues: cached.purchaseDenials.map { ($0.product, $0) })
        var incoming = snapshot.purchases.filter { $0.revoked || $0.upgraded }.map {
            ProPurchaseDenial(product: $0.product, purchasedAt: $0.purchasedAt, signedAt: $0.signedAt)
        }
        incoming += snapshot.subscriptions.filter { $0.deniesAccess(at: now) }.map {
            ProPurchaseDenial(
                product: $0.purchase.product, purchasedAt: $0.purchase.purchasedAt,
                signedAt: $0.renewalVerified ? max($0.signedAt, $0.purchase.signedAt) : $0.purchase.signedAt
            )
        }
        for denial in incoming where denial.isValid {
            if let existing = result[denial.product],
               !existing.allows(purchasedAt: denial.purchasedAt, signedAt: denial.signedAt) { continue }
            result[denial.product] = denial
        }
        return result.values.sorted { $0.product.rawValue < $1.product.rawValue }
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
        // Temporary timing uncertainty denies access through hasAccess, without destroying a verified purchase.
        if !timedAccess, cached.isValidCacheValue, cached.reason != .none,
           canUseOfflineSubscription(cached, snapshot: snapshot, now: now) { return cached }
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
            if let denial = cached.appPurchaseDeniedAt, (purchase.signedAt ?? .distantPast) <= denial { return false }
            return purchase.isProduction && !purchase.revoked && policy.qualifies(purchase)
        case .unverified:
            return false
        case .unavailable:
            return cached.reason == .originalPurchaser && cached.hasAccess(at: now)
        }
    }

    private static func appDenial(_ evidence: ProVerification<ProAppPurchase>, cached: ProEntitlementValue) -> Date? {
        guard case let .verified(purchase) = evidence, purchase.revoked, let signedAt = purchase.signedAt,
              signedAt.timeIntervalSinceReferenceDate.isFinite else { return cached.appPurchaseDeniedAt }
        return max(cached.appPurchaseDeniedAt ?? .distantPast, signedAt)
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
