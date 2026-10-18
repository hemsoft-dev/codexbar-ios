import Foundation
import WidgetKit

@MainActor
enum WidgetSnapshotPublisher {
    static func publish(
        results: [ProviderUsageResult],
        configurationStore: ProviderConfigurationStore,
        access: SnapshotProAccess = .locked,
        now: Date = Date(),
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) {
        publish(
            results: results, configurationStore: configurationStore, access: access,
            snapshotDefaults: WidgetSnapshotStore.userDefaults(), accessGuard: .live,
            now: now, dateTimeFormatter: dateTimeFormatter
        )
    }

    // Injecting snapshot storage also requires an explicit guard. Fixture suites
    // can never silently write the live App Group observation file.
    static func publish(
        results: [ProviderUsageResult],
        configurationStore: ProviderConfigurationStore,
        access: SnapshotProAccess = .locked,
        snapshotDefaults: UserDefaults?,
        accessGuard: WidgetAccessGuard,
        now: Date = Date(),
        dateTimeFormatter: UserFacingDateTimeFormatter = .current,
        accessSample: ProEntitlementClockSample? = nil
    ) {
        let displayable = access.isProLocked ? [] : orderedDisplayableResults(
            results: results,
            configurationStore: configurationStore,
            now: now
        )

        let previousSnapshot = WidgetSnapshotStore.loadSnapshot(defaults: snapshotDefaults)
        let previousPublication = previousSnapshot.accessPublication
        let grant = access.proAccessEndsAt.flatMap { deadline in
            access.clockAnchor.map { WidgetFiniteGrant(deadline: deadline, signedAt: $0.latestSignedAt, environment: access.environment) }
        }
        var acceptedVerifications = previousPublication?.acceptedVerifications ?? [:]
        var observedPartitions = previousPublication?.observedPartitions ?? []
        if let generation = access.verificationGeneration { acceptedVerifications[access.environment.rawValue] = generation }
        if access.proAccessEndsAt != nil { observedPartitions.insert(access.environment.rawValue) }
        let sameAccess = previousSnapshot.isProLocked == access.isProLocked
            && previousSnapshot.proAccessEndsAt == access.proAccessEndsAt
            && previousPublication?.finiteGrant == grant && previousPublication?.environment == access.environment
        let proposedPublication = WidgetAccessPublication(
            id: sameAccess ? (previousPublication?.id ?? UUID()) : UUID(), finiteGrant: grant,
            verificationGeneration: access.verificationGeneration ?? acceptedVerifications[access.environment.rawValue],
            acceptedVerifications: acceptedVerifications, observedPartitions: observedPartitions, environment: access.environment
        )
        let sample = accessSample ?? ProEntitlementSystemClock.sample(at: now)
        let installed = accessGuard.publish(
            proposedPublication, locked: access.isProLocked, anchor: access.clockAnchor,
            replacing: previousPublication, sample: sample
        )
        var failedObservedPartitions = previousPublication?.observedPartitions ?? []
        if let deadline = access.proAccessEndsAt,
           access.clockAnchor?.effectiveDate(at: sample).map({ $0 < deadline }) != true {
            failedObservedPartitions.insert(access.environment.rawValue)
        }
        // Failed initial installation remains retryable, but previously observed
        // partitions and consumed verification generations survive every failure.
        let publication = installed ? proposedPublication : WidgetAccessPublication(
            id: proposedPublication.id, finiteGrant: grant,
            verificationGeneration: previousPublication?.acceptedVerifications[access.environment.rawValue],
            acceptedVerifications: previousPublication?.acceptedVerifications ?? [:],
            observedPartitions: failedObservedPartitions, environment: access.environment
        )
        let snapshot = CodexBarWidgetSnapshot(
            generatedAt: now,
            results: displayable.map { result in
                let configuration = configurationStore.configuration(accountID: result.accountID)
                let barsAreFresh = result.hasFreshBars
                let severityThresholds = configurationStore.usageAlertSettings.severityThresholds
                let plan = result.providerID.supportsPlanBadge ? result.plan : nil
                return CodexBarWidgetProviderSnapshot(
                    accountID: result.accountID,
                    providerID: result.providerID.rawValue,
                    legacyAccountIDs: configurationStore.linkedGoogleAccountIDs(for: result.accountID),
                    title: result.providerID.usesXAIConsumerAuth ? (configuration?.displayName ?? result.title) : result.title,
                    subtitle: statusText(for: result, configurationStore: configurationStore),
                    planIdentifier: plan?.identifier,
                    planDisplayLabel: plan?.displayLabel,
                    planAccessibilityLabel: plan?.accessibilityLabel,
                    groupID: configuration?.groupID,
                    groupName: configurationStore.group(for: configuration?.groupID)?.name,
                    bars: result.enabledBarIndices.map { index in
                        let bar = result.bars[index]
                        let metricID = bar.metricIdentifier(
                            providerID: result.providerID,
                            index: index
                        )
                        let projectedFraction = barsAreFresh ? bar.projectedFraction(at: now) : nil
                        let projectedSeverity = barsAreFresh
                            ? bar.projectedSeverity(at: now, thresholds: severityThresholds)
                            : nil
                        var projectionParts = barsAreFresh ? bar.projectionDescriptionParts(at: now) : nil
                        if projectionParts?.significance == .benign,
                           GoogleUsageMetricCatalog.codingDefinitions.contains(where: { $0.id == metricID }) {
                            projectionParts = nil
                        }
                        return CodexBarWidgetUsageBarSnapshot(
                            id: stableBarID(
                                accountID: result.accountID,
                                providerID: result.providerID,
                                bar: bar,
                                index: index,
                                metricID: metricID
                            ),
                            metricID: metricID,
                            label: bar.label,
                            fractionUsed: bar.fractionUsed,
                            usageText: bar.usageText,
                            resetDescription: bar.localizedResetDescription(
                                at: now,
                                dateTimeFormatter: dateTimeFormatter
                            ),
                            resetsAt: bar.resetsAt,
                            resetDisplayStyle: bar.resetDisplayStyle,
                            severity: barsAreFresh
                                ? CodexBarWidgetSeverity(
                                    bar.severity(using: severityThresholds)
                                )
                                : .normal,
                            projectedFraction: projectedFraction,
                            projectionDescription: projectionParts?.formatted(using: dateTimeFormatter),
                            projectionLeadingText: projectionParts?.leadingText,
                            projectionTimestamp: projectionParts?.timestamp,
                            projectionTrailingText: projectionParts?.trailingText,
                            projectedSeverity: projectedSeverity.map(CodexBarWidgetSeverity.init),
                            visualizationStyle: configurationStore.visualizationStyle(
                                accountID: result.accountID,
                                metricID: bar.metricIdentifier(
                                    providerID: result.providerID,
                                    index: index
                                )
                            ),
                            allowsGauge: !bar.isUnboundedNumeric
                        )
                    },
                    creditsRemaining: result.freshCreditsRemaining,
                    monetaryMetrics: result.monetaryMetrics.map { metric in
                        CodexBarWidgetMonetaryMetricSnapshot(
                            kind: metric.kind.rawValue,
                            label: metric.label,
                            minorUnits: metric.minorUnits,
                            currencyCode: metric.currencyCode,
                            decimalPlaces: metric.decimalPlaces,
                            detail: metric.detail
                        )
                    },
                    usageMessages: result.usageMessages,
                    barsFetchedAt: result.barsFetchedAt,
                    creditsFetchedAt: result.creditsFetchedAt,
                    monetaryMetricsFetchedAt: result.monetaryMetrics.isEmpty ? nil : result.fetchedAt,
                    fetchedAt: result.fetchedAt,
                    severity: CodexBarWidgetSeverity(
                        result.highestSeverity(
                            at: now,
                            thresholds: severityThresholds
                        )
                    )
                )
            },
            isProLocked: access.isProLocked,
            proAccessEndsAt: access.proAccessEndsAt,
            accessPublication: publication
        )

        WidgetSnapshotStore.saveSnapshot(snapshot, defaults: snapshotDefaults)
        WidgetSnapshotStore.saveRefreshInterval(configurationStore.widgetRefreshInterval, defaults: snapshotDefaults)
        WidgetCenter.shared.reloadTimelines(ofKind: CodexBarWidgetConstants.widgetKind)
    }

    static func publishSettings(configurationStore: ProviderConfigurationStore) {
        WidgetSnapshotStore.saveRefreshInterval(configurationStore.widgetRefreshInterval)
        WidgetCenter.shared.reloadTimelines(ofKind: CodexBarWidgetConstants.widgetKind)
    }

    private static func orderedDisplayableResults(
        results: [ProviderUsageResult],
        configurationStore: ProviderConfigurationStore,
        now: Date
    ) -> [ProviderUsageResult] {
        let resultsByAccountID = Dictionary(
            uniqueKeysWithValues: results.map { ($0.accountID, $0) }
        )
        let displayable: [ProviderUsageResult] = configurationStore.configurations.compactMap { configuration in
            guard configurationStore.shouldDisplayOnDashboard(configuration),
                  !configurationStore.accountAccess.isPaused(accountID: configuration.id) else {
                return nil
            }
            return resultsByAccountID[configuration.id]
        }

        return DashboardUsageSorter.orderedResults(
            displayable,
            mode: configurationStore.dashboardOrderingMode,
            manualOrder: configurationStore.dashboardCardOrder,
            now: now,
            severityThresholds: configurationStore.usageAlertSettings.severityThresholds
        )
    }

    private static func statusText(
        for result: ProviderUsageResult,
        configurationStore: ProviderConfigurationStore
    ) -> String {
        guard let configuration = configurationStore.configuration(accountID: result.accountID) else {
            return result.subtitle
        }

        if configurationStore.isConfigured(configuration) {
            if result.subtitle.localizedCaseInsensitiveContains("not configured") {
                return configurationStore.statusText(for: configuration)
            }

            return result.subtitle
        }

        return configurationStore.statusText(for: configuration)
    }

    private static func stableBarID(
        accountID: String,
        providerID: ProviderID,
        bar: UsageBar,
        index: Int,
        metricID: String
    ) -> String {
        // Visible Claude window labels must not change saved widget tile IDs.
        if providerID == .claude,
            bar.stableKey == "session"
                || bar.stableKey?.hasPrefix("session-scoped-") == true {
            let legacyLabel: String
            if bar.stableKey == "session" {
                legacyLabel = bar.legacyWidgetKey ?? "5-hour usage limit"
            } else {
                legacyLabel = bar.label.replacingOccurrences(
                    of: "current session",
                    with: "5-hour usage limit",
                    options: .caseInsensitive
                )
            }
            let suffix = normalizedBarLabel(legacyLabel)
            return "\(accountID).\(index).\(suffix)"
        }
        // Keep existing saved Claude weekly tiles resolvable when the visible label becomes more specific.
        if providerID == .claude,
           bar.stableKey == ClaudeUsageIdentity.allModelsWeeklyStableKey {
            return "\(accountID).\(ClaudeUsageIdentity.allModelsWeeklyLegacyKey)"
        }
        if providerID == .claude,
           let legacyKey = ClaudeUsageIdentity.legacyScopedWeeklyKey(for: bar.stableKey) {
            return "\(accountID).\(legacyKey)"
        }
        if providerID == .claude,
           bar.stableKey?.hasPrefix("weekly-scoped-") == true {
            return "\(accountID).\(index).\(normalizedBarLabel(bar.label))"
        }

        return "\(accountID).\(metricID)"
    }

    private static func normalizedBarLabel(_ label: String) -> String {
        label
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}

private extension CodexBarWidgetSeverity {
    init(_ severity: UsageSeverity) {
        switch severity {
        case .normal:
            self = .normal
        case .warning:
            self = .warning
        case .critical:
            self = .critical
        }
    }
}
