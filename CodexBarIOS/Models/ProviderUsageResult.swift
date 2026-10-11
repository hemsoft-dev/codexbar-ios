import Foundation

public enum ProviderUsageRecoveryAction: Equatable, Sendable {
    case retryRefresh
    case signIn
    case reauthenticate
}

public struct ProviderCardInformationItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let detail: String

    public init(id: String, label: String, detail: String) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

public struct ProviderCardInformationSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let items: [ProviderCardInformationItem]

    public init(id: String, title: String, items: [ProviderCardInformationItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

public struct ProviderPlanDescriptor: Codable, Equatable, Sendable {
    public let identifier: String
    public let displayLabel: String
    public let accessibilityLabel: String

    public init(
        identifier: String,
        displayLabel: String,
        accessibilityLabel: String
    ) {
        self.identifier = identifier
        self.displayLabel = displayLabel
        self.accessibilityLabel = accessibilityLabel
    }

    static func normalizedPlanValue(_ value: String?) -> String? {
        guard let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !normalized.isEmpty
        else {
            return nil
        }
        return normalized
    }

    static func make(
        providerPrefix: String,
        identifier: String,
        label: String,
        displayLabel: String? = nil
    ) -> ProviderPlanDescriptor {
        ProviderPlanDescriptor(
            identifier: "\(providerPrefix).\(identifier)",
            displayLabel: displayLabel ?? label.uppercased(),
            accessibilityLabel: label
        )
    }
}

public enum ProviderMonetaryMetricKind: String, Codable, Equatable, Sendable {
    case balance
    case grossSpend
    case discounts
    case spent
    case projectedSpend
    case spendLimit
    case remainingHeadroom
}

public struct ProviderMonetaryMetric: Identifiable, Codable, Equatable, Sendable {
    public let kind: ProviderMonetaryMetricKind
    public let label: String
    public let minorUnits: Decimal
    public let currencyCode: String
    public let decimalPlaces: Int
    public let detail: String?

    public init(
        kind: ProviderMonetaryMetricKind,
        label: String,
        minorUnits: Decimal,
        currencyCode: String,
        decimalPlaces: Int,
        detail: String? = nil
    ) {
        self.kind = kind
        self.label = label
        self.minorUnits = max(minorUnits, 0)
        self.currencyCode = currencyCode.uppercased()
        self.decimalPlaces = min(max(decimalPlaces, 0), 6)
        self.detail = detail
    }

    public var id: String {
        "\(kind.rawValue).\(label).\(currencyCode)"
    }

    public func metricIdentifier(providerID: ProviderID) -> String {
        "\(providerID.rawValue).monetary.\(kind.rawValue).\(currencyCode.lowercased())"
    }

    public var amount: Decimal {
        var divisor = Decimal(1)
        for _ in 0..<max(decimalPlaces, 0) {
            divisor *= 10
        }
        return minorUnits / divisor
    }

    public func formattedAmount(locale: Locale = .autoupdatingCurrent) -> String {
        amount.formatted(
            .currency(code: currencyCode)
                .precision(.fractionLength(decimalPlaces))
                .locale(locale)
        )
    }
}

public enum ProviderUsageMetricKind: Equatable, Sendable {
    case usageBar(index: Int)
    case unavailableUsage(String)
    case creditsRemaining
    case monetary(index: Int)
}

public struct ProviderUsageMetric: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let kind: ProviderUsageMetricKind

    public init(id: String, label: String, kind: ProviderUsageMetricKind) {
        self.id = id
        self.label = label
        self.kind = kind
    }
}

public struct CodexBankedRateLimitReset: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String?
    public let description: String?
    public let expiresAt: Date?

    public init(
        id: String,
        title: String? = nil,
        description: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.expiresAt = expiresAt
    }
}

public struct CodexBankedRateLimitResets: Equatable, Sendable {
    public let availableCount: Int
    public let credits: [CodexBankedRateLimitReset]?
    public let canConsume: Bool

    public init(
        availableCount: Int,
        credits: [CodexBankedRateLimitReset]? = nil,
        canConsume: Bool = false
    ) {
        self.availableCount = max(availableCount, 0)
        self.credits = credits
        self.canConsume = canConsume
    }

    public var preferredCredit: CodexBankedRateLimitReset? {
        credits?.first
    }

    public var orderedCredits: [CodexBankedRateLimitReset] {
        guard let credits else {
            return []
        }

        return credits.enumerated().sorted { lhs, rhs in
            switch (lhs.element.expiresAt, rhs.element.expiresAt) {
            case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                return lhsDate < rhsDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}

public struct ProviderUsageResult: Identifiable, Equatable, Sendable {
    public let accountID: String
    public let providerID: ProviderID
    public var title: String
    public let plan: ProviderPlanDescriptor?

    public var showsCardPlan: Bool { providerID != .openCodeZen }

    /// Presentation fallback only. Never infers a subscription from usage or account labels.
    public var cardPlan: ProviderPlanDescriptor {
        if let plan { return plan }
        if providerID == .grok, let name = verifiedGrokPlanName {
            return .make(
                providerPrefix: "grok", identifier: name.lowercased().replacingOccurrences(of: " ", with: "-"),
                label: name, displayLabel: name
            )
        }
        if providerID == .greptile, greptileAllowanceRenewal?.isApplicable == true {
            return .make(providerPrefix: "greptile", identifier: "free", label: "Free")
        }
        switch providerID {
        case .openRouter, .moonshot:
            return .make(
                providerPrefix: providerID.rawValue, identifier: "api-credits",
                label: "API credits", displayLabel: "API credits"
            )
        default:
            return .make(
                providerPrefix: providerID.rawValue, identifier: "unavailable",
                label: "Plan unavailable", displayLabel: "Plan unavailable"
            )
        }
    }
    /// Plan verified through the same Grok subject as this usage response; never a usage metric.
    public var verifiedGrokPlanName: String?
    /// The optional Grok tier read failed; a matching verified subject may retain its known tier.
    public let grokPlanLookupFailed: Bool
    /// Fresh active-pool evidence that requires a verified paid tier before becoming visible.
    public let grokInferredZeroCandidate: UsageBar?
    public let subtitle: String
    public let bars: [UsageBar]
    public let barsFetchedAt: Date?
    public let creditsRemaining: Double?
    public let creditsFetchedAt: Date?
    public let monetaryMetrics: [ProviderMonetaryMetric]
    public let unavailableUsageMetrics: [String: String]
    public let usageMessages: [String]
    public let dashboardUsageMessages: [String]
    public let cardInformationSections: [ProviderCardInformationSection]
    /// Review observations retained after a partial Greptile refresh, excluded from fresh history.
    public let greptileReviewActivityUnavailableReason: String?
    public var subscriptionRenewal: SubscriptionRenewal?
    public var subscriptionBillingProblem: SubscriptionBillingProblem?
    public var greptileAllowanceRenewal: GreptileAllowanceRenewal?
    public let codexBankedRateLimitResets: CodexBankedRateLimitResets?
    /// Transient account-bound grants; never persist in usage history or device snapshots.
    public let claudeUsageResetInventory: ClaudeUsageResetInventory?
    public let failureMessage: String?
    public let recoveryAction: ProviderUsageRecoveryAction
    public let preserveCachedBarsOnFailure: Bool
    public let preserveCachedCreditsOnFailure: Bool
    public var cacheIdentity: String?
    public let cacheScope: String?
    public let allowsUnscopedCacheReuse: Bool
    public let hasSuccessfulRefreshHistory: Bool
    public let fetchedAt: Date

    public init(
        accountID: String? = nil,
        providerID: ProviderID,
        title: String,
        plan: ProviderPlanDescriptor? = nil,
        verifiedGrokPlanName: String? = nil,
        grokPlanLookupFailed: Bool = false,
        grokInferredZeroCandidate: UsageBar? = nil,
        subtitle: String,
        bars: [UsageBar],
        barsFetchedAt: Date? = nil,
        creditsRemaining: Double? = nil,
        creditsFetchedAt: Date? = nil,
        monetaryMetrics: [ProviderMonetaryMetric] = [],
        unavailableUsageMetrics: [String: String] = [:],
        usageMessages: [String] = [],
        dashboardUsageMessages: [String]? = nil,
        cardInformationSections: [ProviderCardInformationSection] = [],
        subscriptionRenewal: SubscriptionRenewal? = nil,
        subscriptionBillingProblem: SubscriptionBillingProblem? = nil,
        greptileAllowanceRenewal: GreptileAllowanceRenewal? = nil,
        greptileReviewActivityUnavailableReason: String? = nil,
        codexBankedRateLimitResets: CodexBankedRateLimitResets? = nil,
        claudeUsageResetInventory: ClaudeUsageResetInventory? = nil,
        failureMessage: String? = nil,
        recoveryAction: ProviderUsageRecoveryAction = .retryRefresh,
        preserveCachedBarsOnFailure: Bool = false,
        preserveCachedCreditsOnFailure: Bool = false,
        cacheIdentity: String? = nil,
        cacheScope: String? = nil,
        allowsUnscopedCacheReuse: Bool = false,
        hasSuccessfulRefreshHistory: Bool? = nil,
        fetchedAt: Date
    ) {
        self.accountID = accountID ?? providerID.rawValue
        self.providerID = providerID
        self.title = title
        self.plan = plan
        self.verifiedGrokPlanName = verifiedGrokPlanName
        self.grokPlanLookupFailed = providerID == .grok && grokPlanLookupFailed
        self.grokInferredZeroCandidate = providerID == .grok && grokPlanLookupFailed ? grokInferredZeroCandidate : nil
        self.subtitle = subtitle
        self.bars = bars
        self.barsFetchedAt = bars.isEmpty ? nil : (barsFetchedAt ?? fetchedAt)
        self.creditsRemaining = creditsRemaining
        self.creditsFetchedAt = creditsRemaining == nil ? nil : (creditsFetchedAt ?? fetchedAt)
        self.monetaryMetrics = monetaryMetrics
        self.unavailableUsageMetrics = unavailableUsageMetrics
        self.usageMessages = usageMessages
        self.dashboardUsageMessages = dashboardUsageMessages ?? usageMessages
        self.cardInformationSections = cardInformationSections.filter { section in
            guard !section.items.isEmpty else { return false }
            if providerID == .greptile, section.id == "greptile.credit-allowance" {
                return unavailableUsageMetrics[GreptileUsageIdentity.creditAllowanceMetricID] == nil
                    && greptileAllowanceRenewal?.isApplicable != false && greptileAllowanceRenewal?.isStale != true
            }
            return true
        }
        self.greptileReviewActivityUnavailableReason = greptileReviewActivityUnavailableReason
        // A fresh Go billing observation remains valid if only the independent Zen balance fails.
        self.subscriptionRenewal = failureMessage == nil || providerID == .openCodeZen ? subscriptionRenewal : nil
        self.subscriptionBillingProblem = failureMessage == nil ? subscriptionBillingProblem : nil
        self.greptileAllowanceRenewal = greptileAllowanceRenewal
        self.codexBankedRateLimitResets = codexBankedRateLimitResets.flatMap {
            $0.availableCount > 0 ? $0 : nil
        }
        self.claudeUsageResetInventory = providerID == .claude && failureMessage == nil ? claudeUsageResetInventory : nil
        self.failureMessage = failureMessage
        self.recoveryAction = recoveryAction
        self.preserveCachedBarsOnFailure = preserveCachedBarsOnFailure
        self.preserveCachedCreditsOnFailure = preserveCachedCreditsOnFailure
        self.cacheIdentity = cacheIdentity
        self.cacheScope = cacheScope
        self.allowsUnscopedCacheReuse = allowsUnscopedCacheReuse
        self.hasSuccessfulRefreshHistory = hasSuccessfulRefreshHistory ?? (failureMessage == nil)
        self.fetchedAt = fetchedAt
    }

    public var id: String {
        accountID
    }

    public var hasFreshBars: Bool {
        bars.isEmpty || barsFetchedAt == fetchedAt
    }

    public var hasCurrentBars: Bool {
        if providerID == .greptile, greptileReviewActivityUnavailableReason != nil {
            return hasFreshBars && !usageHistoryBars().isEmpty
        }
        return hasFreshBars
            && (
                failureMessage == nil
                    || (!preserveCachedBarsOnFailure && preserveCachedCreditsOnFailure)
            )
    }

    /// Preserve cached observations in `bars`, but do not publish provider-disabled quotas.
    public var enabledBarIndices: [Int] {
        bars.indices.filter { index in
            let metricID = bars[index].metricIdentifier(providerID: providerID, index: index)
            if providerID == .greptile {
                if bars[index].stableKey == GreptileUsageIdentity.creditAllowanceStableKey,
                   greptileAllowanceRenewal?.isApplicable == false { return false }
                return unavailableUsageMetrics[metricID] == nil
            }
            return unavailableUsageMetrics[metricID] != GoogleUsageMetricCatalog.disabledReason
        }
    }

    public var freshBars: [UsageBar] {
        hasFreshBars ? enabledBarIndices.map { bars[$0] } : []
    }

    public func usageHistoryBars() -> [UsageBar] {
        if providerID == .greptile { return enabledBarIndices.map { bars[$0] } }
        guard providerID == .codex else { return bars }
        return bars.filter { $0.stableKey != CodexUsageParser.creditsPoolStableKey }
    }

    public var hasFreshCredits: Bool {
        creditsRemaining == nil || creditsFetchedAt == fetchedAt
    }

    public var hasCurrentCredits: Bool {
        hasFreshCredits
            && (
                failureMessage == nil
                    || (preserveCachedBarsOnFailure && !preserveCachedCreditsOnFailure)
            )
    }

    public var freshCreditsRemaining: Double? {
        hasFreshCredits ? creditsRemaining : nil
    }

    public var configurableMetrics: [ProviderUsageMetric] {
        GoogleUsageMetricCatalog.metrics(for: providerID, result: self, missingReason: "Unavailable")
    }

    public var availableMetrics: [ProviderUsageMetric] {
        let usageMetrics = enabledBarIndices.map { index in
            let bar = bars[index]
            return ProviderUsageMetric(
                id: bar.metricIdentifier(providerID: providerID, index: index),
                label: bar.label,
                kind: .usageBar(index: index)
            )
        }
        let creditMetrics = creditsRemaining == nil
            ? []
            : [
                ProviderUsageMetric(
                    id: "\(providerID.rawValue).credits-remaining",
                    label: providerID == .openCodeZen ? "Zen credit balance" : "Credit balance",
                    kind: .creditsRemaining
                ),
            ]
        let moneyMetrics = monetaryMetrics.enumerated().map { index, metric in
            ProviderUsageMetric(
                id: metric.metricIdentifier(providerID: providerID),
                label: metric.label,
                kind: .monetary(index: index)
            )
        }
        let greptileUnavailable: [ProviderUsageMetric] = providerID == .greptile
            ? unavailableUsageMetrics.sorted { $0.key < $1.key }.compactMap { id, reason in
                guard let label = GreptileUsageIdentity.label(forMetricID: id),
                      id != GreptileUsageIdentity.creditAllowanceMetricID || greptileAllowanceRenewal?.isApplicable != false
                else { return nil }
                return ProviderUsageMetric(id: id, label: label, kind: .unavailableUsage(reason))
            }
            : []
        return usageMetrics + greptileUnavailable + creditMetrics + moneyMetrics
    }

    public var highestSeverity: UsageSeverity {
        highestSeverity()
    }

    public func highestSeverity(
        at now: Date = Date(),
        thresholds: UsageSeverityThresholds = .default
    ) -> UsageSeverity {
        max(
            freshBars.map {
                $0.effectiveSeverity(at: now, thresholds: thresholds)
            }.max() ?? .normal,
            hasReachedSpendLimit ? .critical : .normal
        )
    }

    public var hasReachedSpendLimit: Bool {
        guard
            let spent = monetaryMetrics.first(where: { $0.kind == .spent }),
            let limit = monetaryMetrics.first(where: { $0.kind == .spendLimit }),
            spent.currencyCode == limit.currencyCode,
            spent.decimalPlaces == limit.decimalPlaces
        else {
            return false
        }
        return limit.minorUnits > 0 && spent.minorUnits >= limit.minorUnits
    }
}
