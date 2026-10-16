import Foundation

public struct DemoUsageProvider: UsageProvider {
    public let providerID: ProviderID
    public let plan: ProviderPlanDescriptor?
    public let bars: [UsageBar]
    public let creditsRemaining: Double?
    public let monetaryMetrics: [ProviderMonetaryMetric]
    public let usageMessages: [String]
    public let dashboardUsageMessages: [String]?
    public let cardInformationSections: [ProviderCardInformationSection]
    public let subtitle: String

    public init(
        providerID: ProviderID,
        plan: ProviderPlanDescriptor? = nil,
        bars: [UsageBar],
        creditsRemaining: Double? = nil,
        monetaryMetrics: [ProviderMonetaryMetric] = [],
        usageMessages: [String] = [],
        dashboardUsageMessages: [String]? = nil,
        cardInformationSections: [ProviderCardInformationSection] = [],
        subtitle: String = "Ready to refresh"
    ) {
        self.providerID = providerID
        self.plan = plan
        self.bars = bars
        self.creditsRemaining = creditsRemaining
        self.monetaryMetrics = monetaryMetrics
        self.usageMessages = usageMessages
        self.dashboardUsageMessages = dashboardUsageMessages
        self.cardInformationSections = cardInformationSections
        self.subtitle = subtitle
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: providerID,
            title: providerID == .openCodeZen
                ? configuration.openCodeDisplayName(
                    hasGoUsage: !bars.isEmpty,
                    hasZenBalance: creditsRemaining != nil
                )
                : configuration.displayName,
            plan: plan,
            subtitle: subtitle,
            bars: bars,
            creditsRemaining: creditsRemaining,
            monetaryMetrics: monetaryMetrics,
            usageMessages: usageMessages,
            dashboardUsageMessages: dashboardUsageMessages,
            cardInformationSections: cardInformationSections,
            fetchedAt: Date()
        )
    }
}

public extension DemoUsageProvider {
    static var samples: [DemoUsageProvider] {
        [
            DemoUsageProvider(
                providerID: .codex,
                plan: ProviderPlanDescriptor(
                    identifier: "codex.pro",
                    displayLabel: "PRO",
                    accessibilityLabel: "Pro"
                ),
                bars: [
                    UsageBar(
                        stableKey: "window-18000",
                        label: "5-hour usage limit",
                        used: 42,
                        limit: 100,
                        resetDescription: "Resets in 2h 15m",
                        projectionDescriptionOverride: "Projected to stay under limit",
                        projectionSignificanceOverride: .benign
                    ),
                    UsageBar(
                        stableKey: "window-604800",
                        label: "Weekly usage limit",
                        used: 68,
                        limit: 100,
                        resetDescription: "Resets Monday at 12:00 AM"
                    ),
                ],
                subtitle: "Personal account - live usage enabled"
            ),
            DemoUsageProvider(
                providerID: .copilot,
                plan: ProviderPlanDescriptor(
                    identifier: "copilot.business",
                    displayLabel: "BUSINESS",
                    accessibilityLabel: "Business"
                ),
                bars: [
                    UsageBar(
                        stableKey: "premium-interactions",
                        label: "Premium requests",
                        used: 73,
                        limit: 100,
                        resetDescription: "Resets in 9 days",
                        projectionDescriptionOverride: "Projected to stay under limit",
                        projectionSignificanceOverride: .benign
                    ),
                ],
                subtitle: "Engineering organization"
            ),
            DemoUsageProvider(
                providerID: .githubBilling,
                plan: ProviderPlanDescriptor.make(
                    providerPrefix: ProviderID.githubBilling.rawValue,
                    identifier: "pro",
                    label: "Pro"
                ),
                bars: [
                    UsageBar(
                        stableKey: "actions-allowance-minutes",
                        label: "Actions minutes",
                        used: 1_600,
                        limit: 3_000,
                        resetDescription: "Resets Oct 1"
                    ),
                    UsageBar(
                        stableKey: "actions-storage",
                        label: "Actions storage",
                        used: 0.6,
                        limit: 2,
                        resetDescription: "Resets Oct 1"
                    ),
                ],
                monetaryMetrics: [
                    ProviderMonetaryMetric(
                        kind: .grossSpend,
                        label: "Gross usage",
                        minorUnits: 1248,
                        currencyCode: "USD",
                        decimalPlaces: 2
                    ),
                    ProviderMonetaryMetric(
                        kind: .discounts,
                        label: "Discounts",
                        minorUnits: 1248,
                        currencyCode: "USD",
                        decimalPlaces: 2
                    ),
                    ProviderMonetaryMetric(
                        kind: .spent,
                        label: "Net spend",
                        minorUnits: 0,
                        currencyCode: "USD",
                        decimalPlaces: 2,
                        detail: "No current charge after discounts"
                    ),
                ],
                usageMessages: [],
                cardInformationSections: [
                    ProviderCardInformationSection(
                        id: "github-billing.product.actions",
                        title: "Actions",
                        items: [
                            ProviderCardInformationItem(
                                id: "actions.consumed",
                                label: "Consumed usage",
                                detail: "$12.48 · 720 minutes"
                            ),
                            ProviderCardInformationItem(
                                id: "actions.discount",
                                label: "Discount usage",
                                detail: "$12.48"
                            ),
                            ProviderCardInformationItem(
                                id: "actions.billable",
                                label: "Billable usage",
                                detail: "$0.00"
                            ),
                            ProviderCardInformationItem(
                                id: "actions.included.minutes",
                                label: "Included usage · Minutes",
                                detail: "1,600 of 3,000 minutes used · 1,400 minutes remaining"
                            ),
                            ProviderCardInformationItem(
                                id: "actions.included.storage",
                                label: "Included usage · Storage",
                                detail: "0.6 of 2 GB used (private Actions storage) · 1.4 GB remaining"
                            ),
                        ]
                    ),
                    ProviderCardInformationSection(
                        id: "github-billing.amounts-and-currency",
                        title: "Amounts and currency",
                        items: [
                            ProviderCardInformationItem(
                                id: "currency",
                                label: "Currency",
                                detail: "USD. GitHub's billing API does not report a currency code, "
                                    + "so CodexBar shows the USD amounts GitHub lists. Amounts are not "
                                    + "converted to the device locale."
                            ),
                            ProviderCardInformationItem(
                                id: "personal-budgets",
                                label: "Personal budgets",
                                detail: "GitHub does not expose personal budgets through its public API. "
                                    + "Included allowances and current charges are shown separately."
                            ),
                        ]
                    ),
                ],
                subtitle: "GitHub personal billing"
            ),
            DemoUsageProvider(
                providerID: .claude,
                plan: ProviderPlanDescriptor(
                    identifier: "claude.max20",
                    displayLabel: "MAX 20×",
                    accessibilityLabel: "Max 20x"
                ),
                bars: [
                    UsageBar(
                        stableKey: "session",
                        label: "5-hour",
                        used: 36,
                        limit: 100,
                        resetDescription: "Resets in 1h 40m"
                    ),
                    UsageBar(
                        stableKey: ClaudeUsageIdentity.allModelsWeeklyStableKey,
                        label: "Weekly",
                        used: 58,
                        limit: 100,
                        resetDescription: "Resets Monday"
                    ),
                    UsageBar(
                        stableKey: "weekly-scoped-fable",
                        label: "Fable weekly usage limit",
                        used: 71,
                        limit: 100,
                        resetDescription: "Resets Monday"
                    ),
                ],
                monetaryMetrics: [
                    ProviderMonetaryMetric(
                        kind: .spent,
                        label: "Usage credits spent",
                        minorUnits: 1250,
                        currencyCode: "USD",
                        decimalPlaces: 2,
                        detail: "Month to date"
                    ),
                    ProviderMonetaryMetric(
                        kind: .remainingHeadroom,
                        label: "Remaining spend headroom",
                        minorUnits: 3750,
                        currencyCode: "USD",
                        decimalPlaces: 2,
                        detail: "Not a prepaid balance"
                    ),
                ],
                usageMessages: ["Fable usage is capped within the all-model weekly allowance."],
                dashboardUsageMessages: [],
                cardInformationSections: [
                    ProviderCardInformationSection(
                        id: "claude.limit-details",
                        title: "Limit details",
                        items: [
                            ProviderCardInformationItem(
                                id: "claude.limit.weekly-scoped-fable",
                                label: "Fable weekly limit",
                                detail: "Counts toward the all-model weekly allowance"
                            ),
                        ]
                    ),
                    ProviderCardInformationSection(
                        id: "claude.account-details",
                        title: "Account details",
                        items: [
                            ProviderCardInformationItem(
                                id: "claude.usage-credits",
                                label: "Usage credits",
                                detail: "Enabled"
                            ),
                            ProviderCardInformationItem(
                                id: "claude.auto-reload",
                                label: "Auto-reload",
                                detail: "Off"
                            ),
                        ]
                    ),
                ],
                subtitle: "Browser session connected"
            ),
            DemoUsageProvider(
                providerID: .grok,
                bars: [
                    UsageBar(
                        stableKey: "included-usage", label: "Weekly subscription usage",
                        used: 31, limit: 100, resetDescription: "Resets Monday"
                    ),
                ],
                monetaryMetrics: [
                    ProviderMonetaryMetric(
                        kind: .balance, label: "Extra Usage Credits", minorUnits: 500,
                        currencyCode: "USD", decimalPlaces: 2
                    ),
                ],
                subtitle: "Synthetic Grok subscription usage"
            ),
            DemoUsageProvider(
                providerID: .xSubscription,
                plan: .make(providerPrefix: "xSubscription", identifier: "premium", label: "Premium", displayLabel: "Premium"),
                bars: [
                    UsageBar(
                        stableKey: "weekly-pool", label: "Weekly shared pool",
                        used: 38, limit: 100, resetDescription: "Resets Thursday"
                    ),
                ],
                monetaryMetrics: [
                    ProviderMonetaryMetric(
                        kind: .balance, label: "Extra Usage Credits", minorUnits: 1_250,
                        currencyCode: "USD", decimalPlaces: 2
                    ),
                ],
                cardInformationSections: [
                    ProviderCardInformationSection(
                        id: "xSubscription.product-usage", title: "Weekly pool by product",
                        items: [
                            ProviderCardInformationItem(id: "xSubscription.product-usage.product_cursor", label: "Cursor", detail: "21%"),
                            ProviderCardInformationItem(id: "xSubscription.product-usage.product_grok_chat", label: "Grok chat", detail: "12%"),
                            ProviderCardInformationItem(id: "xSubscription.product-usage.product_grok_bot", label: "Grok Bot", detail: "5%"),
                        ]
                    ),
                ],
                subtitle: "Synthetic X Subscription weekly pool"
            ),
            DemoUsageProvider(
                providerID: .openRouter,
                bars: [],
                creditsRemaining: 18.72,
                subtitle: "API balance"
            ),
            DemoUsageProvider(
                providerID: .openCodeZen,
                bars: [
                    UsageBar(
                        stableKey: "go.rolling-5-hour",
                        label: "5-hour usage limit",
                        used: 44,
                        limit: 100,
                        resetDescription: "Resets in 2h 10m",
                        projectionDescriptionOverride: "Projected to stay under limit",
                        projectionSignificanceOverride: .benign
                    ),
                    UsageBar(
                        stableKey: "go.weekly",
                        label: "Weekly usage limit",
                        used: 31,
                        limit: 100,
                        resetDescription: "Resets Monday"
                    ),
                    UsageBar(
                        stableKey: "go.monthly",
                        label: "Monthly usage limit",
                        used: 24,
                        limit: 100,
                        resetDescription: "Resets Aug 1"
                    ),
                ],
                creditsRemaining: 12.48,
                subtitle: "Go usage and Zen credit balance"
            ),
            DemoUsageProvider(
                providerID: .moonshot,
                bars: [],
                creditsRemaining: 24.15,
                subtitle: "API balance"
            ),
            DemoUsageProvider(
                providerID: .cursor,
                bars: [
                    UsageBar(
                        stableKey: CursorUsageIdentity.cursorModelsStableKey,
                        label: "Cursor Models",
                        used: 34,
                        limit: 100,
                        resetDescription: "Resets Aug 1",
                        projectionDescriptionOverride: "Projected to stay under limit",
                        projectionSignificanceOverride: .benign
                    ),
                    UsageBar(
                        stableKey: CursorUsageIdentity.otherModelsStableKey,
                        label: "Other Models",
                        used: 17,
                        limit: 100,
                        resetDescription: "Resets Aug 1"
                    ),
                ],
                cardInformationSections: [
                    ProviderCardInformationSection(
                        id: "cursor.included-usage",
                        title: "Included usage",
                        items: [
                            ProviderCardInformationItem(
                                id: "cursor.included-usage.cursor-models",
                                label: "Cursor Models",
                                detail: "34%"
                            ),
                            ProviderCardInformationItem(
                                id: "cursor.included-usage.other-models",
                                label: "Other Models",
                                detail: "17%"
                            ),
                        ]
                    ),
                ],
                subtitle: "Cursor plan usage"
            ),
            DemoUsageProvider(
                providerID: .greptile,
                bars: [
                    UsageBar(
                        stableKey: GreptileUsageIdentity.completedReviewsStableKey,
                        label: "Completed reviews",
                        used: 84,
                        limit: 0,
                        fractionlessUsageText: "84"
                    ),
                ],
                usageMessages: [],
                cardInformationSections: [
                    ProviderCardInformationSection(
                        id: "greptile.review-statuses",
                        title: "Review statuses",
                        items: [
                            ProviderCardInformationItem(
                                id: "greptile.status.completed",
                                label: "Completed",
                                detail: "84"
                            ),
                            ProviderCardInformationItem(
                                id: "greptile.status.skipped",
                                label: "Skipped",
                                detail: "3"
                            ),
                        ]
                    ),
                ],
                subtitle: ""
            ),
            DemoUsageProvider(
                providerID: .gemini,
                bars: [
                    UsageBar(
                        stableKey: "five-hour",
                        label: "Gemini Apps five-hour",
                        used: 27,
                        limit: 100,
                        resetDescription: "Resets in 3h 40m"
                    ),
                    UsageBar(
                        stableKey: "weekly",
                        label: "Gemini Apps weekly",
                        used: 54,
                        limit: 100,
                        resetDescription: "Resets Monday"
                    ),
                    UsageBar(stableKey: "gemini-5h", label: "Gemini Models five-hour", used: 100, limit: 100),
                    UsageBar(stableKey: "gemini-weekly", label: "Gemini Models weekly", used: 31, limit: 100),
                    UsageBar(stableKey: "3p-5h", label: "Other models five-hour", used: 20, limit: 100),
                    UsageBar(stableKey: "3p-weekly", label: "Other models weekly", used: 60, limit: 100),
                ],
                subtitle: "Gemini Apps and coding usage"
            ),
        ]
    }
}
