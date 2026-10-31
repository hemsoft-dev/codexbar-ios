import Foundation

enum ClaudeUsageIdentity {
    static let fableWeeklyStableKey = ClaudeFableUsageIdentity.stableKey
    static let fableWeeklyMetricID = ClaudeFableUsageIdentity.metricID
    static let fableModelNames = ClaudeFableUsageIdentity.modelNames
    static let legacyFableStableKeys = ClaudeFableUsageIdentity.legacyStableKeys

    static func canonicalFableStableKey(_ key: String) -> String {
        ClaudeFableUsageIdentity.canonicalStableKey(key)
    }

    static let allModelsWeeklyStableKey = "weekly-all"
    static let allModelsWeeklyLegacyKey = "weekly-usage-limit"
    static let sonnetWeeklyLegacyKey = "sonnet-weekly-limit"
    static let opusWeeklyLegacyKey = "opus-weekly-limit"

    static func legacyScopedWeeklyKey(for stableKey: String?) -> String? {
        switch stableKey {
        case sonnetWeeklyLegacyKey:
            return sonnetWeeklyLegacyKey
        case opusWeeklyLegacyKey:
            return opusWeeklyLegacyKey
        default:
            return nil
        }
    }
}

public enum ClaudeUsageParser {
    private enum SpendMessageKind {
        case routine
        case enabledStatusUnreported
        case monetaryDetailsUnavailable
        case actionable
    }

    private struct SpendMessage {
        let kind: SpendMessageKind
        let text: String
        let informationItem: ProviderCardInformationItem?

        static func routine(
            id: String,
            text: String,
            label: String,
            detail: String
        ) -> SpendMessage {
            SpendMessage(
                kind: .routine,
                text: text,
                informationItem: ProviderCardInformationItem(
                    id: id,
                    label: label,
                    detail: detail
                )
            )
        }

        static func dashboard(_ text: String) -> SpendMessage {
            SpendMessage(kind: .actionable, text: text, informationItem: nil)
        }

        static func dashboard(_ kind: SpendMessageKind, _ text: String) -> SpendMessage {
            SpendMessage(kind: kind, text: text, informationItem: nil)
        }
    }

    private struct SpendPresentation {
        let metrics: [ProviderMonetaryMetric]
        let messages: [SpendMessage]
    }

    private struct UsageResponse: Decodable {
        let fiveHour: UsageWindow?
        let sevenDay: UsageWindow?
        let sevenDayOAuthApps: UsageWindow?
        let sevenDayOpus: UsageWindow?
        let sevenDaySonnet: UsageWindow?
        let limits: [StructuredLimit]?
        let extraUsage: ExtraUsage?
        let spend: Spend?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOAuthApps = "seven_day_oauth_apps"
            case sevenDayOpus = "seven_day_opus"
            case sevenDaySonnet = "seven_day_sonnet"
            case limits
            case extraUsage = "extra_usage"
            case spend
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = try? container.decodeIfPresent(UsageWindow.self, forKey: .fiveHour)
            sevenDay = try? container.decodeIfPresent(UsageWindow.self, forKey: .sevenDay)
            sevenDayOAuthApps = try? container.decodeIfPresent(
                UsageWindow.self,
                forKey: .sevenDayOAuthApps
            )
            sevenDayOpus = try? container.decodeIfPresent(UsageWindow.self, forKey: .sevenDayOpus)
            sevenDaySonnet = try? container.decodeIfPresent(
                UsageWindow.self,
                forKey: .sevenDaySonnet
            )
            limits = (try? container.decodeIfPresent(
                [LossyElement<StructuredLimit>].self,
                forKey: .limits
            ))?.compactMap(\.value)
            extraUsage = try? container.decodeIfPresent(ExtraUsage.self, forKey: .extraUsage)
            spend = try? container.decodeIfPresent(Spend.self, forKey: .spend)
        }
    }

    private struct LossyElement<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    private struct UsageWindow: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            utilization = try? container.decodeIfPresent(Double.self, forKey: .utilization)
            resetsAt = try? container.decodeIfPresent(String.self, forKey: .resetsAt)
        }
    }

    private struct StructuredLimit: Decodable {
        let kind: String?
        let group: String?
        let percent: Double?
        let resetsAt: String?
        let scope: LimitScope?
        let isActive: Bool?

        enum CodingKeys: String, CodingKey {
            case kind
            case group
            case percent
            case resetsAt = "resets_at"
            case scope
            case isActive = "is_active"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try? container.decodeIfPresent(String.self, forKey: .kind)
            group = try? container.decodeIfPresent(String.self, forKey: .group)
            percent = try? container.decodeIfPresent(Double.self, forKey: .percent)
            resetsAt = try? container.decodeIfPresent(String.self, forKey: .resetsAt)
            scope = try? container.decodeIfPresent(LimitScope.self, forKey: .scope)
            isActive = try? container.decodeIfPresent(Bool.self, forKey: .isActive)
        }
    }

    private struct StructuredLimitDefinition {
        let key: String
        let stableBarKey: String?
        let label: String
        let duration: TimeInterval
        let legacyFallbackKey: String?
        let legacySemanticKey: String?
        let usageMessage: String?
        let informationItem: ProviderCardInformationItem?
    }

    private struct LimitScope: Decodable {
        let model: LimitModel?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            model = try? container.decodeIfPresent(LimitModel.self, forKey: .model)
        }

        private enum CodingKeys: String, CodingKey {
            case model
        }
    }

    private struct LimitModel: Decodable {
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            displayName = try? container.decodeIfPresent(String.self, forKey: .displayName)
        }
    }

    private struct ExtraUsage: Decodable {
        let isEnabled: Bool?
        let monthlyLimit: Decimal?
        let usedCredits: Decimal?
        let currency: String?
        let decimalPlaces: Int?
        let disabledReason: String?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case monthlyLimit = "monthly_limit"
            case usedCredits = "used_credits"
            case currency
            case decimalPlaces = "decimal_places"
            case disabledReason = "disabled_reason"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isEnabled = try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)
            monthlyLimit = try? container.decodeIfPresent(Decimal.self, forKey: .monthlyLimit)
            usedCredits = try? container.decodeIfPresent(Decimal.self, forKey: .usedCredits)
            currency = try? container.decodeIfPresent(String.self, forKey: .currency)
            decimalPlaces = try? container.decodeIfPresent(Int.self, forKey: .decimalPlaces)
            disabledReason = try? container.decodeIfPresent(String.self, forKey: .disabledReason)
        }
    }

    private struct Spend: Decodable {
        let used: Money?
        let limit: Money?
        let balance: Money?
        let percent: Double?
        let enabled: Bool?
        let disabledReason: String?
        let autoReload: Bool?
        let reportsAutoReload: Bool

        enum CodingKeys: String, CodingKey {
            case used
            case limit
            case balance
            case percent
            case enabled
            case disabledReason = "disabled_reason"
            case autoReload = "auto_reload"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            used = try? container.decodeIfPresent(Money.self, forKey: .used)
            limit = try? container.decodeIfPresent(Money.self, forKey: .limit)
            balance = try? container.decodeIfPresent(Money.self, forKey: .balance)
            percent = try? container.decodeIfPresent(Double.self, forKey: .percent)
            enabled = try? container.decodeIfPresent(Bool.self, forKey: .enabled)
            disabledReason = try? container.decodeIfPresent(String.self, forKey: .disabledReason)
            reportsAutoReload = container.contains(.autoReload)
            let autoReloadIsNull = reportsAutoReload
                ? (try? container.decodeNil(forKey: .autoReload)) == true
                : false
            if !reportsAutoReload || autoReloadIsNull {
                autoReload = reportsAutoReload ? false : nil
            } else {
                autoReload = try? container.decodeIfPresent(
                    AutoReload.self,
                    forKey: .autoReload
                )?.isEnabled
            }
        }
    }

    private struct Money: Decodable {
        let amountMinor: Decimal
        let currency: String
        let exponent: Int

        enum CodingKeys: String, CodingKey {
            case amountMinor = "amount_minor"
            case currency
            case exponent
        }
    }

    private struct AutoReload: Decodable {
        let isEnabled: Bool

        private enum CodingKeys: String, CodingKey {
            case enabled
            case isEnabled = "is_enabled"
        }

        init(from decoder: Decoder) throws {
            if let bool = try? decoder.singleValueContainer().decode(Bool.self) {
                isEnabled = bool
                return
            }

            if let container = try? decoder.container(keyedBy: CodingKeys.self) {
                if let enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) {
                    isEnabled = enabled
                    return
                }
                if let enabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) {
                    isEnabled = enabled
                    return
                }
            }

            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected an auto-reload Boolean."
                )
            )
        }
    }

    public static func parse(
        _ data: Data,
        subscriptionType: String?,
        rateLimitTier: String? = nil,
        fetchedAt: Date = Date(),
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) -> ProviderUsageResult? {
        guard let usage = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
            return nil
        }

        var bars: [UsageBar] = []
        var semanticKeys = Set<String>()
        var usageMessages: [String] = []
        var limitInformationItems: [ProviderCardInformationItem] = []

        let structuredLimits = usage.limits ?? []
        let hasScopedSessionLimit = structuredLimits.contains { limit in
            limit.kind == "session"
                && limit.isActive != false
                && limit.percent != nil
                && sanitizedModelName(limit.scope?.model?.displayName) != nil
        }
        let hasScopedWeeklyLimit = structuredLimits.contains { limit in
            limit.kind == "weekly_scoped"
                && (limit.group == nil || limit.group == "weekly")
                && limit.percent != nil
                && sanitizedModelName(limit.scope?.model?.displayName) != nil
        }
        let legacyCompatibleModelKeys = legacyCompatibleScopedWeeklyModelKeys(
            in: structuredLimits
        )

        for limit in structuredLimits where shouldIncludeStructuredLimit(limit) {
            guard let percent = limit.percent else {
                continue
            }

            guard
                let definition = structuredLimitDefinition(
                    for: limit,
                    hasScopedSessionLimit: hasScopedSessionLimit,
                    hasScopedWeeklyLimit: hasScopedWeeklyLimit,
                    legacyCompatibleScopedWeeklyModelKeys: legacyCompatibleModelKeys
                )
            else {
                continue
            }
            if limit.isActive == false,
               structuredLimits.contains(where: { candidate in
                   guard candidate.isActive != false, candidate.percent != nil else {
                       return false
                   }
                   return structuredLimitDefinition(
                       for: candidate,
                       hasScopedSessionLimit: hasScopedSessionLimit,
                       hasScopedWeeklyLimit: hasScopedWeeklyLimit,
                       legacyCompatibleScopedWeeklyModelKeys: legacyCompatibleModelKeys
                   )?.key == definition.key
               }) {
                continue
            }
            guard semanticKeys.insert(definition.key).inserted else {
                continue
            }
            let reset = parseReset(limit.resetsAt)
                ?? definition.legacyFallbackKey.flatMap { legacyReset(for: $0, usage: usage) }
            bars.append(usageBar(
                stableKey: definition.stableBarKey,
                label: definition.label,
                usedPercent: sanitizedPercent(percent),
                reset: reset,
                durationSeconds: definition.duration,
                fetchedAt: fetchedAt,
                dateTimeFormatter: dateTimeFormatter,
                projectionDescriptionOverride: sessionIdleDescription(
                    stableKey: definition.stableBarKey,
                    percent: percent,
                    reset: reset
                ),
                legacyWidgetKey: definition.stableBarKey == "session" && hasScopedSessionLimit
                    ? "other-models-5-hour-usage-limit" : nil
            ))
            if let legacySemanticKey = definition.legacySemanticKey {
                semanticKeys.insert(legacySemanticKey)
            }
            if let usageMessage = definition.usageMessage {
                usageMessages.append(usageMessage)
            }
            if let informationItem = definition.informationItem {
                limitInformationItems.append(informationItem)
            }
        }

        appendLegacyBar(
            key: "session",
            stableBarKey: "session",
            label: "5-hour",
            window: usage.fiveHour,
            durationSeconds: 18_000,
            semanticKeys: &semanticKeys,
            bars: &bars,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        )
        appendLegacyBar(
            key: ClaudeUsageIdentity.allModelsWeeklyStableKey,
            stableBarKey: ClaudeUsageIdentity.allModelsWeeklyStableKey,
            label: "Weekly",
            window: usage.sevenDay ?? usage.sevenDayOAuthApps,
            durationSeconds: 604_800,
            semanticKeys: &semanticKeys,
            bars: &bars,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        )
        appendLegacyBar(
            key: "weekly-scoped-sonnet",
            stableBarKey: ClaudeUsageIdentity.sonnetWeeklyLegacyKey,
            label: "Sonnet weekly usage limit",
            window: usage.sevenDaySonnet,
            durationSeconds: 604_800,
            semanticKeys: &semanticKeys,
            bars: &bars,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        )
        appendLegacyBar(
            key: "weekly-scoped-opus",
            stableBarKey: ClaudeUsageIdentity.opusWeeklyLegacyKey,
            label: "Opus weekly usage limit",
            window: usage.sevenDayOpus,
            durationSeconds: 604_800,
            semanticKeys: &semanticKeys,
            bars: &bars,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        )

        let extraUsage = spendMetrics(from: usage.spend, fallback: usage.extraUsage)
        let dashboardUsageMessages = uniqueMessages(
            extraUsage.messages
                .filter { $0.kind != .routine }
                .map(\.text)
        )
        usageMessages.append(contentsOf: extraUsage.messages.map(\.text))
        let accountInformationItems = extraUsage.messages.compactMap(\.informationItem)
        var cardInformationSections: [ProviderCardInformationSection] = []
        if !limitInformationItems.isEmpty {
            cardInformationSections.append(ProviderCardInformationSection(
                id: "claude.limit-details",
                title: "Limit details",
                items: limitInformationItems
            ))
        }
        if !accountInformationItems.isEmpty {
            cardInformationSections.append(ProviderCardInformationSection(
                id: "claude.account-details",
                title: "Account details",
                items: accountInformationItems
            ))
        }

        guard !bars.isEmpty || !extraUsage.metrics.isEmpty || !usageMessages.isEmpty else {
            return nil
        }

        return ProviderUsageResult(
            providerID: .claude,
            title: ProviderID.claude.displayName,
            plan: planDescriptor(
                subscriptionType: subscriptionType,
                rateLimitTier: rateLimitTier
            ),
            subtitle: "Live Claude usage",
            bars: bars,
            monetaryMetrics: extraUsage.metrics,
            usageMessages: uniqueMessages(usageMessages),
            dashboardUsageMessages: dashboardUsageMessages,
            cardInformationSections: cardInformationSections,
            fetchedAt: fetchedAt
        )
    }

    public static func parseRateLimitHeaders(
        _ fields: [AnyHashable: Any],
        subscriptionType: String?,
        rateLimitTier: String? = nil,
        fetchedAt: Date = Date(),
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) -> ProviderUsageResult? {
        var bars: [UsageBar] = []
        if let bar = usageBarFromHeaders(
            stableKey: "session",
            label: "5-hour",
            utilizationKey: "anthropic-ratelimit-unified-5h-utilization",
            resetKey: "anthropic-ratelimit-unified-5h-reset",
            durationSeconds: 18_000,
            fields: fields,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        ) {
            bars.append(bar)
        }

        if let bar = usageBarFromHeaders(
            stableKey: ClaudeUsageIdentity.allModelsWeeklyStableKey,
            label: "Weekly",
            utilizationKey: "anthropic-ratelimit-unified-7d-utilization",
            resetKey: "anthropic-ratelimit-unified-7d-reset",
            durationSeconds: 604_800,
            fields: fields,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        ) {
            bars.append(bar)
        }

        guard !bars.isEmpty else {
            return nil
        }

        return ProviderUsageResult(
            providerID: .claude,
            title: ProviderID.claude.displayName,
            plan: planDescriptor(
                subscriptionType: subscriptionType,
                rateLimitTier: rateLimitTier
            ),
            subtitle: "Live Claude usage",
            bars: bars,
            fetchedAt: fetchedAt
        )
    }

    private static func usageBar(
        stableKey: String? = nil,
        label: String,
        window: UsageWindow?,
        durationSeconds: TimeInterval,
        fetchedAt: Date,
        dateTimeFormatter: UserFacingDateTimeFormatter
    ) -> UsageBar? {
        guard let utilization = window?.utilization else {
            return nil
        }

        return usageBar(
            stableKey: stableKey,
            label: label,
            usedPercent: normalizedOAuthPercent(utilization),
            reset: parseReset(window?.resetsAt),
            durationSeconds: durationSeconds,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter,
            projectionDescriptionOverride: sessionIdleDescription(
                stableKey: stableKey,
                percent: normalizedOAuthPercent(utilization),
                reset: parseReset(window?.resetsAt)
            )
        )
    }

    private static func usageBarFromHeaders(
        stableKey: String? = nil,
        label: String,
        utilizationKey: String,
        resetKey: String,
        durationSeconds: TimeInterval,
        fields: [AnyHashable: Any],
        fetchedAt: Date,
        dateTimeFormatter: UserFacingDateTimeFormatter
    ) -> UsageBar? {
        guard
            let utilization = doubleHeader(fields[utilizationKey]),
            let reset = epochHeader(fields[resetKey])
        else {
            return nil
        }

        return usageBar(
            stableKey: stableKey,
            label: label,
            usedPercent: normalizedHeaderPercent(utilization),
            reset: reset,
            durationSeconds: durationSeconds,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        )
    }

    private static func usageBar(
        stableKey: String? = nil,
        label: String,
        usedPercent: Double,
        reset: Date?,
        durationSeconds: TimeInterval,
        fetchedAt: Date,
        dateTimeFormatter: UserFacingDateTimeFormatter,
        projectionDescriptionOverride: String? = nil,
        legacyWidgetKey: String? = nil
    ) -> UsageBar {
        return UsageBar(
            stableKey: stableKey,
            label: label,
            used: usedPercent,
            limit: 100,
            resetDescription: reset.map { formatReset(
                $0,
                now: fetchedAt,
                dateTimeFormatter: dateTimeFormatter
            ) },
            resetsAt: reset,
            resetDisplayStyle: .relativeWithLocalTime,
            projectionCurrent: reset == nil ? nil : usedPercent / 100,
            projectionLimit: reset == nil ? nil : 1,
            projectionPeriodStart: reset?.addingTimeInterval(-durationSeconds),
            projectionPeriodEnd: reset,
            showProjectionOnCurrentBar: reset != nil,
            projectionDescriptionOverride: projectionDescriptionOverride,
            legacyWidgetKey: legacyWidgetKey
        )
    }

    private static func appendLegacyBar(
        key: String,
        stableBarKey: String? = nil,
        label: String,
        window: UsageWindow?,
        durationSeconds: TimeInterval,
        semanticKeys: inout Set<String>,
        bars: inout [UsageBar],
        fetchedAt: Date,
        dateTimeFormatter: UserFacingDateTimeFormatter
    ) {
        guard
            !semanticKeys.contains(key),
            let bar = usageBar(
                stableKey: stableBarKey,
                label: label,
                window: window,
                durationSeconds: durationSeconds,
                fetchedAt: fetchedAt,
                dateTimeFormatter: dateTimeFormatter
            )
        else {
            return
        }
        semanticKeys.insert(key)
        bars.append(bar)
    }

    private static func spendMetrics(
        from spend: Spend?,
        fallback extraUsage: ExtraUsage?
    ) -> SpendPresentation {
        guard let spend else {
            return legacyExtraUsageMetrics(from: extraUsage)
        }

        let provider = providerSpendMetrics(from: spend)
        guard spend.enabled != false else {
            return provider
        }
        if spend.enabled == nil, extraUsage?.isEnabled == false {
            return legacyExtraUsageMetrics(from: extraUsage)
        }

        let legacy = legacyExtraUsageMetrics(from: extraUsage)
        let providerByKind = Dictionary(
            uniqueKeysWithValues: provider.metrics.map { ($0.kind, $0) }
        )
        let legacyByKind = Dictionary(
            uniqueKeysWithValues: legacy.metrics.map { ($0.kind, $0) }
        )
        let spent = providerByKind[.spent] ?? legacyByKind[.spent]
        let limit = providerByKind[.spendLimit] ?? legacyByKind[.spendLimit]
        let balance = providerByKind[.balance]
        var metrics = [spent, limit, balance].compactMap { $0 }
        if
            let spent,
            let limit,
            spent.currencyCode == limit.currencyCode,
            spent.decimalPlaces == limit.decimalPlaces {
            metrics.append(ProviderMonetaryMetric(
                kind: .remainingHeadroom,
                label: "Remaining spend headroom",
                minorUnits: max(limit.minorUnits - spent.minorUnits, 0),
                currencyCode: limit.currencyCode,
                decimalPlaces: limit.decimalPlaces,
                detail: "Derived from spend limit; not a prepaid balance"
            ))
        }

        var messages = provider.messages
        if spend.enabled == nil, extraUsage?.isEnabled == true {
            messages.removeAll { $0.kind == .enabledStatusUnreported }
            messages.insert(
                .routine(
                    id: "claude.usage-credits",
                    text: "Usage credits are enabled.",
                    label: "Usage credits",
                    detail: "Enabled"
                ),
                at: 0
            )
        }
        if metrics.isEmpty {
            messages.append(.dashboard(
                .monetaryDetailsUnavailable,
                "Usage-credit monetary details are temporarily unavailable."
            ))
        } else {
            messages.removeAll { $0.kind == .monetaryDetailsUnavailable }
        }
        return SpendPresentation(metrics: metrics, messages: uniqueSpendMessages(messages))
    }

    private static func providerSpendMetrics(
        from spend: Spend
    ) -> SpendPresentation {
        if spend.enabled == false {
            let reason = spend.disabledReason?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let reason, !reason.isEmpty {
                return SpendPresentation(
                    metrics: [],
                    messages: [.dashboard("Usage credits are disabled: \(reason).")]
                )
            }
            return SpendPresentation(
                metrics: [],
                messages: [.dashboard("Usage credits are disabled.")]
            )
        }

        var metrics: [ProviderMonetaryMetric] = []
        var messages: [SpendMessage] = spend.enabled == true
            ? [
                .routine(
                    id: "claude.usage-credits",
                    text: "Usage credits are enabled.",
                    label: "Usage credits",
                    detail: "Enabled"
                ),
            ]
            : [
                .dashboard(
                    .enabledStatusUnreported,
                    "Usage-credit enabled status was not reported."
                ),
            ]

        let spentMetric = monetaryMetric(
            spend.used,
            kind: .spent,
            label: "Usage credits spent",
            detail: spendPercentDetail(spend.percent)
                ?? "Month to date"
        )
        let limitMetric = monetaryMetric(
            spend.limit,
            kind: .spendLimit,
            label: "Monthly spend limit",
            detail: "Usage-credit policy cap"
        )
        if let spentMetric { metrics.append(spentMetric) }
        if let limitMetric { metrics.append(limitMetric) }
        if let balance = monetaryMetric(
            spend.balance,
            kind: .balance,
            label: "Current balance",
            detail: "Provider-reported prepaid balance"
        ) {
            metrics.append(balance)
        }

        if
            let spentMetric,
            let limitMetric,
            spentMetric.currencyCode == limitMetric.currencyCode,
            spentMetric.decimalPlaces == limitMetric.decimalPlaces {
            metrics.append(ProviderMonetaryMetric(
                kind: .remainingHeadroom,
                label: "Remaining spend headroom",
                minorUnits: max(limitMetric.minorUnits - spentMetric.minorUnits, 0),
                currencyCode: limitMetric.currencyCode,
                decimalPlaces: limitMetric.decimalPlaces,
                detail: "Derived from spend limit; not a prepaid balance"
            ))
        }

        if spend.reportsAutoReload, let autoReload = spend.autoReload {
            messages.append(.routine(
                id: "claude.auto-reload",
                text: "Auto-reload is \(autoReload ? "on" : "off").",
                label: "Auto-reload",
                detail: autoReload ? "On" : "Off"
            ))
        }
        if metrics.isEmpty {
            messages.append(.dashboard(
                .monetaryDetailsUnavailable,
                "Usage-credit monetary details are temporarily unavailable."
            ))
        }
        return SpendPresentation(metrics: metrics, messages: messages)
    }

    private static func monetaryMetric(
        _ money: Money?,
        kind: ProviderMonetaryMetricKind,
        label: String,
        detail: String?
    ) -> ProviderMonetaryMetric? {
        guard
            let money,
            let currency = normalizedCurrency(money.currency),
            (0...6).contains(money.exponent)
        else {
            return nil
        }
        return ProviderMonetaryMetric(
            kind: kind,
            label: label,
            minorUnits: max(money.amountMinor, 0),
            currencyCode: currency,
            decimalPlaces: money.exponent,
            detail: detail
        )
    }

    private static func normalizedCurrency(_ value: String) -> String? {
        let currency = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return currency.count == 3 ? currency : nil
    }

    private static func spendPercentDetail(_ value: Double?) -> String? {
        guard let value, value.isFinite else {
            return nil
        }
        let rounded = max(value, 0).rounded()
        guard rounded < Double(Int.max) else {
            return nil
        }
        return "\(Int(rounded))% used"
    }

    private static func legacyExtraUsageMetrics(
        from extraUsage: ExtraUsage?
    ) -> SpendPresentation {
        guard let extraUsage else {
            return SpendPresentation(metrics: [], messages: [])
        }
        if extraUsage.isEnabled == false {
            let reason = extraUsage.disabledReason?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let reason, !reason.isEmpty {
                return SpendPresentation(
                    metrics: [],
                    messages: [.dashboard("Usage credits are disabled: \(reason).")]
                )
            }
            return SpendPresentation(
                metrics: [],
                messages: [.dashboard("Usage credits are disabled.")]
            )
        }
        let reportedCurrency = extraUsage.currency?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currency = reportedCurrency.flatMap { $0.isEmpty ? nil : $0 } ?? "USD"
        guard currency.count == 3, let usedCredits = extraUsage.usedCredits else {
            return SpendPresentation(
                metrics: [],
                messages: [
                    .dashboard("Usage credits are enabled, but monetary details are temporarily unavailable."),
                ]
            )
        }
        let decimalPlaces = extraUsage.decimalPlaces ?? currencyDecimalPlaces(currency)

        let spent = max(usedCredits, 0)
        var metrics = [
            ProviderMonetaryMetric(
                kind: .spent,
                label: "Usage credits spent",
                minorUnits: spent,
                currencyCode: currency,
                decimalPlaces: decimalPlaces,
                detail: "Month to date"
            ),
        ]
        var messages: [SpendMessage] = extraUsage.isEnabled == nil
            ? [
                .dashboard(
                    .enabledStatusUnreported,
                    "Usage-credit enabled status was not reported."
                ),
            ]
            : []

        if let monthlyLimit = extraUsage.monthlyLimit {
            let limit = max(monthlyLimit, 0)
            metrics.append(ProviderMonetaryMetric(
                kind: .spendLimit,
                label: "Monthly spend limit",
                minorUnits: limit,
                currencyCode: currency,
                decimalPlaces: decimalPlaces,
                detail: "Usage-credit policy cap"
            ))
            metrics.append(ProviderMonetaryMetric(
                kind: .remainingHeadroom,
                label: "Remaining spend headroom",
                minorUnits: max(limit - spent, 0),
                currencyCode: currency,
                decimalPlaces: decimalPlaces,
                detail: "Not a prepaid balance"
            ))
            if limit > 0, spent >= limit {
                messages.append(.dashboard(
                    "The monthly usage-credit spend limit has been reached."
                ))
            }
        } else {
            messages.append(.dashboard(
                "Usage credits are enabled with no monthly spend limit reported."
            ))
        }
        return SpendPresentation(metrics: metrics, messages: messages)
    }

    private static func uniqueMessages(_ messages: [String]) -> [String] {
        var seen = Set<String>()
        return messages.filter { seen.insert($0).inserted }
    }

    private static func uniqueSpendMessages(_ messages: [SpendMessage]) -> [SpendMessage] {
        var seen = Set<String>()
        return messages.filter { seen.insert($0.text).inserted }
    }

    private static func sessionIdleDescription(
        stableKey: String?,
        percent: Double,
        reset: Date?
    ) -> String? {
        guard stableKey == "session", sanitizedPercent(percent) == 0, reset == nil else {
            return nil
        }
        return "Starts when a message is sent"
    }

    // Current OAuth windows use percentages; values below 1 retain legacy fraction compatibility.
    private static func normalizedOAuthPercent(_ value: Double) -> Double {
        sanitizedPercent(value < 1 ? value * 100 : value)
    }

    private static func normalizedHeaderPercent(_ value: Double) -> Double {
        sanitizedPercent(min(value, 1) * 100)
    }

    private static func currencyDecimalPlaces(_ currencyCode: String) -> Int {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode.uppercased()
        return formatter.maximumFractionDigits
    }

    private static func sanitizedPercent(_ value: Double) -> Double {
        value.isFinite ? max(value, 0) : 0
    }

    private static func structuredLimitDefinition(
        for limit: StructuredLimit,
        hasScopedSessionLimit: Bool,
        hasScopedWeeklyLimit: Bool,
        legacyCompatibleScopedWeeklyModelKeys: Set<String>
    ) -> StructuredLimitDefinition? {
        switch limit.kind {
        case "session":
            if let modelName = sanitizedModelName(limit.scope?.model?.displayName) {
                let key = "session-scoped-\(normalizedKey(modelName))"
                return StructuredLimitDefinition(
                    key: key,
                    stableBarKey: key,
                    label: "\(modelName) current session",
                    duration: 18_000,
                    legacyFallbackKey: nil,
                    legacySemanticKey: nil,
                    usageMessage: nil,
                    informationItem: nil
                )
            }
            return StructuredLimitDefinition(
                key: "session",
                stableBarKey: "session",
                label: hasScopedSessionLimit
                    ? "Other models 5-hour"
                    : "5-hour",
                duration: 18_000,
                legacyFallbackKey: "session",
                legacySemanticKey: nil,
                usageMessage: nil,
                informationItem: nil
            )
        case "weekly_all":
            guard limit.group == nil || limit.group == "weekly" else {
                return nil
            }
            return StructuredLimitDefinition(
                key: ClaudeUsageIdentity.allModelsWeeklyStableKey,
                stableBarKey: ClaudeUsageIdentity.allModelsWeeklyStableKey,
                label: "Weekly",
                duration: 604_800,
                legacyFallbackKey: ClaudeUsageIdentity.allModelsWeeklyStableKey,
                legacySemanticKey: nil,
                usageMessage: nil,
                informationItem: nil
            )
        case "weekly_scoped":
            guard
                limit.group == nil || limit.group == "weekly",
                let modelName = scopedWeeklyModelName(limit.scope?.model?.displayName)
            else {
                return nil
            }
            let modelKey = normalizedKey(modelName)
            let legacyFamilyIdentity = legacyScopedIdentity(for: modelName)
            let stableLegacyIdentity = legacyCompatibleScopedWeeklyModelKeys.contains(modelKey)
                ? legacyFamilyIdentity
                : nil
            let key = "weekly-scoped-\(modelKey)"
            return StructuredLimitDefinition(
                key: key,
                stableBarKey: stableLegacyIdentity?.stableBarKey ?? key,
                label: "\(modelName) weekly usage limit",
                duration: 604_800,
                legacyFallbackKey: legacyFamilyIdentity?.semanticKey,
                legacySemanticKey: legacyFamilyIdentity?.semanticKey,
                usageMessage: "\(modelName) usage is capped within the all-model weekly allowance.",
                informationItem: ProviderCardInformationItem(
                    id: "claude.limit.\(key)",
                    label: "\(modelName) weekly limit",
                    detail: "Counts toward the all-model weekly allowance"
                )
            )
        default:
            return nil
        }
    }

    private static func shouldIncludeStructuredLimit(_ limit: StructuredLimit) -> Bool {
        switch limit.kind {
        case "session":
            // The idle first-party state is an inactive zero-percent session
            // without a reset because its window has not started yet.
            return limit.isActive != false
                || (
                    limit.percent == 0
                        && limit.resetsAt == nil
                        && sanitizedModelName(limit.scope?.model?.displayName) == nil
                )
        case "weekly_all", "weekly_scoped":
            // Anthropic reports enforceable weekly limits with is_active false.
            return true
        default:
            return limit.isActive != false
        }
    }

    private static func sanitizedModelName(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func scopedWeeklyModelName(_ value: String?) -> String? {
        guard let name = sanitizedModelName(value) else { return nil }
        // These documented models share one Fable cap. Keep saved choices when
        // its display name changes; unrelated or future model names stay distinct.
        let knownNames = Set(ClaudeUsageIdentity.fableModelNames)
        let normalized = name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return knownNames.contains(normalized) ? "Fable" : name
    }

    private static func normalizedKey(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func legacyScopedIdentity(
        for modelName: String
    ) -> (semanticKey: String, stableBarKey: String)? {
        let key = normalizedKey(modelName)
        if key.contains("sonnet") {
            return ("weekly-scoped-sonnet", ClaudeUsageIdentity.sonnetWeeklyLegacyKey)
        }
        if key.contains("opus") {
            return ("weekly-scoped-opus", ClaudeUsageIdentity.opusWeeklyLegacyKey)
        }
        return nil
    }

    private static func legacyCompatibleScopedWeeklyModelKeys(
        in limits: [StructuredLimit]
    ) -> Set<String> {
        var modelKeysByLegacySemanticKey: [String: Set<String>] = [:]
        for limit in limits where limit.kind == "weekly_scoped" {
            guard
                limit.group == nil || limit.group == "weekly",
                limit.percent != nil,
                let modelName = sanitizedModelName(limit.scope?.model?.displayName),
                let legacyIdentity = legacyScopedIdentity(for: modelName)
            else {
                continue
            }
            modelKeysByLegacySemanticKey[legacyIdentity.semanticKey, default: []]
                .insert(normalizedKey(modelName))
        }

        return Set(modelKeysByLegacySemanticKey.values.compactMap { modelKeys in
            modelKeys.count == 1 ? modelKeys.first : nil
        })
    }

    private static func legacyReset(for key: String, usage: UsageResponse) -> Date? {
        let window: UsageWindow?
        switch key {
        case "session":
            window = usage.fiveHour
        case "weekly-all":
            window = usage.sevenDay ?? usage.sevenDayOAuthApps
        case "weekly-scoped-sonnet":
            window = usage.sevenDaySonnet
        case "weekly-scoped-opus":
            window = usage.sevenDayOpus
        default:
            window = nil
        }
        return parseReset(window?.resetsAt)
    }

    private static func parseReset(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }

        if let epoch = Double(value) {
            let seconds = epoch >= 1_000_000_000_000 ? epoch / 1000 : epoch
            return Date(timeIntervalSince1970: seconds)
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func doubleHeader(_ value: Any?) -> Double? {
        if let value = value as? String {
            return Double(value)
        }

        if let value = value as? NSNumber {
            return value.doubleValue
        }

        return nil
    }

    private static func epochHeader(_ value: Any?) -> Date? {
        guard let rawValue = doubleHeader(value) else {
            return nil
        }

        let seconds = rawValue >= 1_000_000_000_000 ? rawValue / 1000 : rawValue
        return Date(timeIntervalSince1970: seconds)
    }

    private static func formatReset(
        _ resetAt: Date,
        now: Date,
        dateTimeFormatter: UserFacingDateTimeFormatter
    ) -> String {
        dateTimeFormatter.resetDescription(
            resetAt: resetAt,
            now: now,
            style: .relativeWithLocalTime,
            fallback: nil
        ) ?? "Resets now"
    }

    static func planDescriptor(
        subscriptionType: String?,
        rateLimitTier: String?
    ) -> ProviderPlanDescriptor? {
        let subscription = ProviderPlanDescriptor.normalizedPlanValue(subscriptionType)
        let tier = ProviderPlanDescriptor.normalizedPlanValue(rateLimitTier)
        // Existing metadata only. Plan names never establish a verification state or quota.
        let legacyTiers = [
            "max_20x": "ultra", "default_claude_max_20x": "ultra",
            "max_5x": "max", "default_claude_max_5x": "max",
        ]
        guard let subscription else { return nil }
        let family = legacyTiers[subscription] ?? subscription
        let tierFamily = legacyTiers[tier ?? ""]
        if let tierFamily {
            guard ["max", "ultra"].contains(family) else { return nil }
            if family == "ultra", tierFamily != "ultra" { return nil }
            if let legacyFamily = legacyTiers[subscription], legacyFamily != tierFamily { return nil }
        }
        if ["max", "ultra"].contains(family), tier == "default_claude_pro" { return nil }
        let resolved = tierFamily ?? family
        // Retain legacy descriptor IDs for existing consumers while updating public names.
        let hasLegacyTier = tierFamily != nil || legacyTiers[subscription] != nil
        if resolved == "ultra" || resolved == "max" && hasLegacyTier {
            let ultra = resolved == "ultra"
            return .make(providerPrefix: "claude", identifier: ultra ? "max20" : "max5",
                         label: ultra ? "Ultra" : "Max")
        }
        let labels = [
            "free": "Free", "pro": "Pro", "max": "Max", "team": "Team",
            "team_premium": "Team Premium", "enterprise": "Enterprise",
        ]
        guard let label = labels[subscription] else { return nil }
        return .make(
            providerPrefix: "claude", identifier: subscription.replacingOccurrences(of: "_", with: "-"), label: label
        )
    }
}
