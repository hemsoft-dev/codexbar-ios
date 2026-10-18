import Foundation

struct ProCommercePresentation: Equatable, Sendable {
    let planTitle: String
    let detail: String
    let periodEnd: Date?
    let subscriptionPeriodEnd: Date?
    let dateKind: ProPlanDateKind?
    let nextRenewalProduct: ProProductID?
    let renewalPrice: Decimal?
    let renewalCurrency: String?
    let hasBillingIssue: Bool
    let graceEndsAt: Date?
    let hasRenewalOverlap: Bool
    let hasSubscription: Bool
    let lifetimeAction: ProLifetimeAction
    let showsPurchaseOptions: Bool

    func renewalPriceText(locale: Locale = .current) -> String? {
        guard let renewalPrice, let renewalCurrency, renewalCurrency.count == 3 else { return nil }
        return renewalPrice.formatted(.currency(code: renewalCurrency).locale(locale))
    }
}

enum ProCommercePolicy {
    static func presentation(
        value: ProEntitlementValue, hasAccess: Bool, isResolved: Bool, statuses: [ProSubscriptionEvidence],
        statusAvailable: Bool, unverifiedProducts: Set<ProProductID> = [], renewalMetadataProducts: Set<ProProductID> = [],
        currentStatusProducts: Set<ProProductID>? = nil, now: Date
    ) -> ProCommercePresentation {
        let currentStatuses = statuses.filter { currentStatusProducts?.contains($0.purchase.product) ?? true }
        let relevant = currentStatuses.filter { isRelevant($0, at: now) }
        let missingStatuses = currentStatusProducts?.subtracting(Set(currentStatuses.map(\.purchase.product))) ?? []
        let unknown = unverifiedProducts.union(missingStatuses).subtracting([.lifetime])
            .filter { currentStatusProducts?.contains($0) ?? true }
        let permanent = hasAccess && value.reason.isPermanent
        let hasSubscription = value.subscriptionProduct != nil || !relevant.isEmpty || !unknown.isEmpty
        let trusted = relevant.filter { $0.renewalVerified && !unverifiedProducts.contains($0.purchase.product) }
        let billing = trusted.filter { $0.isInBillingRetry || $0.state == .billingRetry || $0.state == .grace }
        let current = currentStatuses.filter {
            $0.purchase.product == value.subscriptionProduct && !$0.purchase.revoked && !$0.purchase.upgraded
        }.max { $0.purchase.purchasedAt < $1.purchase.purchasedAt }
        let renewalKnown = (statusAvailable || current.map { renewalMetadataProducts.contains($0.purchase.product) } == true)
            && current?.renewalVerified == true
            && current.map { !unverifiedProducts.contains($0.purchase.product) } == true
            && current.map { isRelevant($0, at: now) && $0.state == .subscribed && !$0.isInBillingRetry } == true
        let renews = renewalKnown && current?.willAutoRenew == true
        let dateKind = dateKind(value: value, hasAccess: hasAccess, current: current, renewalKnown: renewalKnown)
        return ProCommercePresentation(
            planTitle: title(value: value, hasAccess: hasAccess, isResolved: isResolved),
            detail: detail(
                value: value, hasAccess: hasAccess, isResolved: isResolved, current: current,
                renewalKnown: renewalKnown, historical: statuses.max { $0.purchase.purchasedAt < $1.purchase.purchasedAt }
            ),
            periodEnd: dateKind == nil ? nil : current?.purchase.expiresAt,
            subscriptionPeriodEnd: (current ?? relevant.max { $0.purchase.purchasedAt < $1.purchase.purchasedAt })?.purchase.expiresAt,
            dateKind: dateKind,
            nextRenewalProduct: renews && !permanent ? current?.nextRenewalProduct : nil,
            renewalPrice: renews && !permanent ? current?.renewalPrice : nil,
            renewalCurrency: renews && !permanent ? current?.renewalCurrency : nil,
            hasBillingIssue: !billing.isEmpty,
            graceEndsAt: billing.compactMap(\.graceEndsAt).filter { $0 > now }.max(),
            hasRenewalOverlap: permanent && trusted.contains { $0.willAutoRenew == true },
            hasSubscription: hasSubscription,
            lifetimeAction: lifetimeAction(
                permanent: permanent, hasSubscription: hasSubscription, relevant: relevant,
                statusAvailable: statusAvailable, unverifiedProducts: Set(unknown)
            ),
            showsPurchaseOptions: isResolved && !hasAccess
        )
    }

    static func authorize(_ product: ProProductID, context: ProPurchaseContext, presentation: ProCommercePresentation, isResolved: Bool) throws {
        guard isResolved else { throw ProCommerceError.checkingPurchases }
        if product == .lifetime {
            switch presentation.lifetimeAction {
            case .alreadyPermanent: throw ProCommerceError.alreadyHasPro
            case .manageSubscription: throw ProCommerceError.autoRenewEnabled
            case .unavailable: throw ProCommerceError.renewalUnknown
            case .available: break
            }
        }
        if !presentation.showsPurchaseOptions {
            guard product == .lifetime, context == .settingsLifetime, presentation.hasSubscription else {
                throw ProCommerceError.alreadyHasPro
            }
        }
    }

    static func isRelevant(_ status: ProSubscriptionEvidence, at date: Date) -> Bool {
        guard !status.purchase.revoked, !status.purchase.upgraded else { return false }
        // An expired transaction alone cannot prove that billing retry is off.
        guard status.renewalVerified else { return true }
        if status.renewalVerified {
            if status.state == .revoked { return false }
            if status.isInBillingRetry || status.state == .billingRetry { return true }
            if let graceEndsAt = status.graceEndsAt, graceEndsAt > date { return true }
            if status.state == .expired { return false }
        }
        return status.purchase.expiresAt.map { $0 > date } ?? true
    }

    private static func lifetimeAction(
        permanent: Bool, hasSubscription: Bool, relevant: [ProSubscriptionEvidence],
        statusAvailable: Bool, unverifiedProducts: Set<ProProductID>
    ) -> ProLifetimeAction {
        if permanent { return .alreadyPermanent }
        guard statusAvailable else { return .unavailable }
        if relevant.contains(where: { $0.renewalVerified && $0.willAutoRenew == true && !unverifiedProducts.contains($0.purchase.product) }) {
            return .manageSubscription
        }
        if relevant.contains(where: { !$0.renewalVerified || $0.willAutoRenew == nil || unverifiedProducts.contains($0.purchase.product) }) {
            return .unavailable
        }
        if !unverifiedProducts.isEmpty { return .unavailable }
        if hasSubscription && relevant.isEmpty { return .unavailable }
        return .available
    }

    private static func title(value: ProEntitlementValue, hasAccess: Bool, isResolved: Bool) -> String {
        guard isResolved else { return "Checking purchases" }
        guard hasAccess else { return "Free plan" }
        switch value.reason {
        case .originalPurchaser, .lifetime: return "Lifetime Pro"
        case .monthly: return "Monthly Pro"
        case .yearly: return "Yearly Pro"
        case .trial: return "Pro free trial"
        case .billingGrace: return "CodexBar Pro"
        case .none: return "Free plan"
        }
    }

    private static func detail(
        value: ProEntitlementValue, hasAccess: Bool, isResolved: Bool,
        current: ProSubscriptionEvidence?, renewalKnown: Bool, historical: ProSubscriptionEvidence?
    ) -> String {
        guard isResolved else { return "Checking your existing purchases before showing purchase options." }
        if hasAccess && value.reason.isPermanent { return "All Pro features, with no expiry." }
        if hasAccess {
            if value.reason == .billingGrace { return "Update your payment details to keep your subscription active." }
            guard renewalKnown, let renews = current?.willAutoRenew else { return "Renewal status unavailable." }
            return renews ? "Your subscription renews automatically." : "Auto-renew is off. Your subscription ends after the current period."
        }
        if let historical {
            if historical.purchase.revoked || historical.renewalVerified && historical.state == .revoked {
                return "Your previous subscription was refunded or revoked."
            }
            if historical.renewalVerified && historical.state == .expired, let end = historical.purchase.expiresAt {
                return "Your previous subscription ended on \(end.formatted(date: .abbreviated, time: .omitted))."
            }
        }
        return "One account and seven days of history."
    }

    private static func dateKind(
        value: ProEntitlementValue, hasAccess: Bool, current: ProSubscriptionEvidence?, renewalKnown: Bool
    ) -> ProPlanDateKind? {
        guard hasAccess, !value.reason.isPermanent, value.reason != .billingGrace, let current else { return nil }
        if value.reason == .trial { return .trialEnds }
        guard renewalKnown, let renews = current.willAutoRenew else { return nil }
        return renews ? .renews : .expires
    }
}
