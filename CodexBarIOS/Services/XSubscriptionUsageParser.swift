import Foundation

/// Customer-facing copy shared by the X Subscription parser and cached-plan retention.
enum XSubscriptionCopy {
    static let poolStableKey = "weekly-pool"
    static let poolMetricID = "\(ProviderID.xSubscription.rawValue).\(poolStableKey)"
    static let productSectionID = "xSubscription.product-usage"
    static let unavailableReason = "xAI did not report weekly pool usage."
    static let inferredSubtitle = "No pool usage reported by xAI."
    static let inferredMessage = "Inferred zero from xAI's CLI convention, not a reported measurement."
    static let creditsUnavailable = "xAI did not report Extra Usage Credits."
}

extension GrokUsageProvider {
    /// Unified plan names from grok.com's `UNIFIED_PLAN_NAMES`. Legacy X tiers such as "X Premium+" are not
    /// X Subscription plans and stay unrecognized. A tier is never inferred from usage, balance or sign-in.
    static func unifiedPlan(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let prefix = "X Subscription "
        if value.count > prefix.count, value.prefix(prefix.count).caseInsensitiveCompare(prefix) == .orderedSame {
            value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return ["Plus", "Premium", "Super", "Ultra"].first { $0.caseInsensitiveCompare(value) == .orderedSame }
    }

    /// Reads one shared weekly pool from the Grok CLI billing proxy. See X-SUBSCRIPTION-CONTRACT.md.
    /// Unlike Grok, the pool does not require `isUnifiedBillingUser`, which marks an older shared Grok pool.
    static func parseXSubscription(
        _ data: Data, configuration: ProviderAccountConfiguration, subject: String, now: Date,
        verifiedPlanName: String? = nil, planLookupFailed: Bool = false
    ) throws -> ProviderUsageResult {
        guard let response = try? JSONDecoder().decode(XSubscriptionCreditsResponse.self, from: data),
              let config = response.config else { throw GrokAuthError.invalidResponse }
        let cacheIdentity = identityHash(subject)
        // grok.com relabels legacy tiers (SuperGrok → Premium) client-side, so a unified account may still
        // report a SuperGrok tier. Such a tier only leaves the plan pill unavailable; it never blocks the pool.
        let plan = unifiedPlan(verifiedPlanName)
        let window = activeWeeklyWindow(config.currentPeriod, now: now)
        let percent = reportedPercent(config.creditUsagePercent)
        // Same first-party CLI convention as Grok, restricted to a verified unified plan.
        let inferredZero = percent == nil && plan != nil && window != nil && omitsUsage(data)
        let bar = window.flatMap { window in
            (percent ?? (inferredZero ? 0 : nil)).map { poolBar($0, window: window, inferred: inferredZero) }
        }
        let reason = unavailableReason(config.currentPeriod, window: window)
        let balance = money(config.prepaidBalance, kind: .balance, label: "Extra Usage Credits")
        let products = bar == nil ? [] : productItems(config.productUsage?.entries ?? [])
        return ProviderUsageResult(
            accountID: configuration.id, providerID: .xSubscription, title: configuration.displayName,
            verifiedGrokPlanName: plan, grokPlanLookupFailed: planLookupFailed,
            grokInferredZeroCandidate: percent == nil && omitsUsage(data)
                ? window.map { poolBar(0, window: $0, inferred: true) } : nil,
            subtitle: bar == nil ? reason : inferredZero ? XSubscriptionCopy.inferredSubtitle : "X Subscription weekly pool",
            bars: bar.map { [$0] } ?? [],
            monetaryMetrics: [balance].compactMap { $0 },
            usageMessages: (bar == nil ? [reason] : inferredZero ? [XSubscriptionCopy.inferredMessage] : [])
                + (balance == nil ? [XSubscriptionCopy.creditsUnavailable] : []),
            cardInformationSections: (products.isEmpty ? [] : [
                ProviderCardInformationSection(
                    id: XSubscriptionCopy.productSectionID, title: "Weekly pool by product", items: products
                ),
            ]) + [billingSource],
            cacheIdentity: cacheIdentity, cacheScope: "consumer.\(cacheIdentity)", fetchedAt: now
        )
    }

    private static func activeWeeklyWindow(_ period: GrokCreditsPeriod?, now: Date) -> (start: Date, end: Date)? {
        guard period?.type == "USAGE_PERIOD_TYPE_WEEKLY",
              let start = period?.start.flatMap(date), let end = period?.end.flatMap(date),
              start <= now, end > now else { return nil }
        return (start, end)
    }

    private static func poolBar(_ used: Double, window: (start: Date, end: Date), inferred: Bool) -> UsageBar {
        UsageBar(
            stableKey: XSubscriptionCopy.poolStableKey,
            label: inferred ? "Weekly pool inferred" : "Weekly shared pool",
            used: used, limit: 100, resetsAt: window.end, resetDisplayStyle: .relativeWithLocalTime,
            projectionCurrent: used, projectionLimit: 100,
            projectionPeriodStart: window.start, projectionPeriodEnd: window.end
        )
    }

    private static func unavailableReason(_ period: GrokCreditsPeriod?, window: (start: Date, end: Date)?) -> String {
        if period?.type != "USAGE_PERIOD_TYPE_WEEKLY" { return "xAI did not report a weekly pool period." }
        if window == nil { return "xAI did not report an active weekly pool period." }
        return XSubscriptionCopy.unavailableReason
    }

    /// Detail rows that describe how the one pool was used. They are never summed or turned into meters.
    private static func productItems(_ entries: [XSubscriptionProductUsage]) -> [ProviderCardInformationItem] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard let product = entry.product, let name = productNames[product], seen.insert(product).inserted,
                  let percent = reportedPercent(entry.usagePercent), percent > 0 else { return nil }
            let displayed = percent < 1 ? 1 : percent
            return ProviderCardInformationItem(
                id: "\(XSubscriptionCopy.productSectionID).\(product.lowercased())",
                label: name, detail: "\(Int(displayed.rounded()))%"
            )
        }
    }

    private static let productNames = [
        "PRODUCT_API": "API", "PRODUCT_GROK_BUILD": "Grok Build", "PRODUCT_GROK_PLUGINS": "Grok plugins",
        "PRODUCT_GROK_CHAT": "Grok chat", "PRODUCT_GROK_IMAGINE": "Grok Imagine", "PRODUCT_GROK_VOICE": "Grok voice",
        "PRODUCT_GROK_APP_BUILDER": "Grok app builder", "PRODUCT_GROK_TASKS": "Grok tasks", "PRODUCT_GROK_BOT": "Grok Bot",
        "PRODUCT_CURSOR": "Cursor", "PRODUCT_BUGBOT": "Bugbot",
    ]

    private static var billingSource: ProviderCardInformationSection {
        ProviderCardInformationSection(
            id: "xSubscription.billing-source", title: "Billing source",
            items: [
                ProviderCardInformationItem(
                    id: "xSubscription.billing-source.pool", label: "X Subscription weekly pool",
                    detail: "One pool shared by Grok, Grok Bot and Cursor. Extra Usage Credits are prepaid and separate. "
                        + "Third-party model spending in Cursor isn't reported separately."
                ),
            ]
        )
    }
}

private struct XSubscriptionCreditsResponse: Decodable {
    let config: XSubscriptionCreditsConfig?
}

private struct XSubscriptionCreditsConfig: Decodable {
    let creditUsagePercent: Double?
    let currentPeriod: GrokCreditsPeriod?
    let prepaidBalance: GrokCreditsAmount?
    let productUsage: XSubscriptionProductUsageList?
}

/// Optional detail rows must not invalidate the pool, so malformed lists and entries are skipped.
private struct XSubscriptionProductUsageList: Decodable {
    let entries: [XSubscriptionProductUsage]

    init(from decoder: Decoder) throws {
        guard var container = try? decoder.unkeyedContainer() else {
            entries = []
            return
        }
        var entries: [XSubscriptionProductUsage] = []
        while !container.isAtEnd {
            if (try? container.decodeNil()) == true { continue }
            if let entry = try? container.decode(XSubscriptionProductUsage.self) {
                entries.append(entry)
            } else if (try? container.decode(XSubscriptionSkippedValue.self)) == nil {
                break
            }
        }
        self.entries = entries
    }
}

private struct XSubscriptionSkippedValue: Decodable {
    init(from decoder: Decoder) throws {}
}

private struct XSubscriptionProductUsage: Decodable {
    /// Proto JSON enum name such as `PRODUCT_CURSOR`; integer enum values are mapped to the same names.
    let product: String?
    let usagePercent: Double?

    private enum CodingKeys: String, CodingKey {
        case product, usagePercent
    }

    private static let productsByNumber = [
        1: "PRODUCT_API", 2: "PRODUCT_GROK_BUILD", 3: "PRODUCT_GROK_PLUGINS", 4: "PRODUCT_GROK_CHAT",
        5: "PRODUCT_GROK_IMAGINE", 6: "PRODUCT_GROK_VOICE", 7: "PRODUCT_GROK_APP_BUILDER", 8: "PRODUCT_GROK_TASKS",
        9: "PRODUCT_GROK_BOT", 10: "PRODUCT_CURSOR", 11: "PRODUCT_BUGBOT",
    ]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let name = try? container.decode(String.self, forKey: .product) {
            product = name
        } else if let number = try? container.decode(Int.self, forKey: .product) {
            product = Self.productsByNumber[number]
        } else {
            product = nil
        }
        usagePercent = try? container.decode(Double.self, forKey: .usagePercent)
    }
}
