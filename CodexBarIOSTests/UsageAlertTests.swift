import XCTest
@testable import CodexBarIOS

final class UsageAlertTests: XCTestCase {
    @MainActor
    func testUsageAlertSettingsPersistAndValidateThresholdRelationship() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: EmptySecretStore()
        )
        XCTAssertFalse(store.usageAlertSettings.isEnabled)
        XCTAssertEqual(store.usageAlertSettings.warningThreshold, 0.75)
        XCTAssertEqual(store.usageAlertSettings.criticalThreshold, 0.90)
        XCTAssertEqual(store.usageAlertSettings.balanceThreshold, 5.00)

        store.updateUsageAlertsEnabled(true)
        store.updateUsageAlertWarningThreshold(0.60)
        store.updateUsageAlertCriticalThreshold(0.80)
        store.updateUsageAlertBalanceThreshold(-5)
        store.updateUsageAlertActiveIDs([
            "severity.warning.codex.personal",
            "balance.openRouter",
        ])

        let reloadedStore = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: EmptySecretStore()
        )
        XCTAssertTrue(reloadedStore.usageAlertSettings.isEnabled)
        XCTAssertEqual(reloadedStore.usageAlertSettings.warningThreshold, 0.60)
        XCTAssertEqual(reloadedStore.usageAlertSettings.criticalThreshold, 0.80)
        XCTAssertEqual(reloadedStore.usageAlertSettings.balanceThreshold, 0)
        XCTAssertEqual(
            reloadedStore.usageAlertActiveIDs,
            ["severity.warning.codex.personal", "balance.openRouter"]
        )

        reloadedStore.updateUsageAlertWarningThreshold(1)
        XCTAssertEqual(reloadedStore.usageAlertSettings.warningThreshold, 0.79)
        reloadedStore.updateUsageAlertCriticalThreshold(0.50)
        XCTAssertEqual(reloadedStore.usageAlertSettings.criticalThreshold, 0.80)
    }

    func testUsageAlertThresholdsNormalizeNonFiniteInputs() {
        let thresholds = UsageSeverityThresholds(
            warning: .nan,
            critical: .nan
        )
        XCTAssertEqual(thresholds, .default)

        var settings = UsageAlertSettings(
            warningThreshold: .nan,
            criticalThreshold: .nan
        )
        XCTAssertEqual(settings.warningThreshold, 0.75)
        XCTAssertEqual(settings.criticalThreshold, 0.90)

        settings.updateWarningThreshold(.nan)
        settings.updateCriticalThreshold(.nan)
        XCTAssertEqual(settings.warningThreshold, 0.75)
        XCTAssertEqual(settings.criticalThreshold, 0.90)
    }

    @MainActor
    func testLegacySettingsMigrateToSeverityDefaults() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyData = try JSONSerialization.data(withJSONObject: [
            "isEnabled": true,
            "usageThreshold": 0.55,
            "balanceThreshold": 7.0,
            "includesSeverityAlerts": false,
        ])
        defaults.set(legacyData, forKey: "usageAlertSettings")

        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: EmptySecretStore()
        )

        XCTAssertTrue(store.usageAlertSettings.isEnabled)
        XCTAssertEqual(store.usageAlertSettings.warningThreshold, 0.75)
        XCTAssertEqual(store.usageAlertSettings.criticalThreshold, 0.90)
        XCTAssertEqual(store.usageAlertSettings.balanceThreshold, 7)

        let migratedData = try XCTUnwrap(defaults.data(forKey: "usageAlertSettings"))
        let migratedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
        )
        XCTAssertEqual(migratedObject["warningThreshold"] as? Double, 0.75)
        XCTAssertEqual(migratedObject["criticalThreshold"] as? Double, 0.90)
        XCTAssertNil(migratedObject["usageThreshold"])
        XCTAssertNil(migratedObject["includesSeverityAlerts"])
    }

    @MainActor
    func testLegacySettingsMigrationPreservesCredentialReadError() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = ProviderAccountConfiguration(
            providerID: .claude,
            authMethod: .browserSession
        )
        defaults.set(
            try JSONEncoder().encode([configuration]),
            forKey: "providerConfigurations"
        )
        defaults.set(
            try JSONSerialization.data(withJSONObject: [
                "isEnabled": true,
                "usageThreshold": 0.80,
                "balanceThreshold": 5.0,
                "includesSeverityAlerts": true,
            ]),
            forKey: "usageAlertSettings"
        )

        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: FailingReadSecretStore()
        )

        XCTAssertEqual(
            store.lastError,
            "Could not read the saved credential for Claude: Keychain unavailable"
        )
        XCTAssertEqual(store.usageAlertSettings.warningThreshold, 0.75)
        XCTAssertEqual(store.usageAlertSettings.criticalThreshold, 0.90)
    }

    @MainActor
    func testUnknownFutureSettingsPayloadIsNotRewrittenAsLegacy() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let futureData = try JSONSerialization.data(withJSONObject: [
            "isEnabled": true,
            "futureWarningThreshold": 0.65,
            "futureCriticalThreshold": 0.85,
            "balanceThreshold": 8.0,
        ])
        defaults.set(futureData, forKey: "usageAlertSettings")

        _ = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: EmptySecretStore()
        )

        XCTAssertEqual(defaults.data(forKey: "usageAlertSettings"), futureData)
    }

    @MainActor
    func testThresholdChangesInvalidateOnlyAffectedSuppressionState() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: EmptySecretStore()
        )
        let warningID = "severity.warning.codex.personal"
        let criticalID = "severity.critical.codex.personal"
        let balanceID = "balance.openRouter"
        store.updateUsageAlertActiveIDs([warningID, criticalID, balanceID])

        store.updateUsageAlertCriticalThreshold(0.95)
        XCTAssertEqual(store.usageAlertActiveIDs, [warningID, balanceID])

        store.updateUsageAlertActiveIDs([warningID, criticalID, balanceID])
        store.updateUsageAlertWarningThreshold(0.70)
        XCTAssertEqual(store.usageAlertActiveIDs, [criticalID, balanceID])

        store.updateUsageAlertActiveIDs([warningID, criticalID, balanceID])
        store.updateUsageAlertBalanceThreshold(10)
        XCTAssertEqual(store.usageAlertActiveIDs, [warningID, criticalID])

        store.updateUsageAlertsEnabled(true)
        XCTAssertTrue(store.usageAlertActiveIDs.isEmpty)
    }

    func testCurrentUsageUsesConfiguredWarningAndCriticalThresholds() {
        let settings = UsageAlertSettings(
            isEnabled: true,
            warningThreshold: 0.60,
            criticalThreshold: 0.85
        )
        let warning = result(used: 60)
        let critical = result(used: 85)

        let warningEvaluation = UsageAlertEvaluator.evaluate(
            results: [warning],
            settings: settings,
            activeAlertIDs: []
        )
        XCTAssertEqual(warningEvaluation.notifications.count, 1)
        XCTAssertEqual(warningEvaluation.notifications.first?.kind, .severity)
        XCTAssertEqual(warningEvaluation.notifications.first?.title, "Codex Warning")
        XCTAssertEqual(
            warningEvaluation.notifications.first?.body,
            "Codex (ChatGPT / Codex): Warning status. Weekly current usage is 60% (Warning at 60%)."
        )
        XCTAssertEqual(warningEvaluation.activeAlerts.first?.severity, .warning)
        XCTAssertEqual(
            warningEvaluation.activeAlertIDs,
            ["severity.warning.codex.personal"]
        )

        let criticalEvaluation = UsageAlertEvaluator.evaluate(
            results: [critical],
            settings: settings,
            activeAlertIDs: []
        )
        XCTAssertEqual(criticalEvaluation.notifications.count, 1)
        XCTAssertEqual(
            criticalEvaluation.notifications.first?.title,
            "Codex Critical Alert"
        )
        XCTAssertEqual(
            criticalEvaluation.notifications.first?.body,
            "Codex (ChatGPT / Codex): Critical status. Weekly current usage is 85% (Critical Alert at 85%)."
        )
        XCTAssertEqual(criticalEvaluation.activeAlerts.first?.severity, .critical)
        XCTAssertEqual(
            criticalEvaluation.activeAlertIDs,
            [
                "severity.warning.codex.personal",
                "severity.critical.codex.personal",
            ]
        )
    }

    func testNotificationsIdentifyCustomAndFallbackLabelsForSameProvider() {
        let evaluations = [
            result(accountID: "codex.first-private-id", title: "Work Codex", used: 80),
            result(
                accountID: "codex.second-private-id",
                title: "ChatGPT / Codex",
                used: 80
            ),
            result(
                accountID: "codex.third-private-id",
                title: "ChatGPT / Codex 2",
                used: 80
            ),
        ].map {
            UsageAlertEvaluator.evaluate(
                results: [$0],
                settings: UsageAlertSettings(isEnabled: true),
                activeAlertIDs: []
            )
        }

        XCTAssertEqual(
            evaluations.compactMap { $0.notifications.first?.title },
            [
                "Work Codex Warning",
                "ChatGPT / Codex Warning",
                "ChatGPT / Codex 2 Warning",
            ]
        )
        XCTAssertEqual(
            evaluations.compactMap { $0.notifications.first?.body },
            [
                "Work Codex (ChatGPT / Codex): Warning status. Weekly current usage is 80% (Warning at 75%).",
                "ChatGPT / Codex: Warning status. Weekly current usage is 80% (Warning at 75%).",
                "ChatGPT / Codex 2 (ChatGPT / Codex): Warning status. Weekly current usage is 80% (Warning at 75%).",
            ]
        )
        let notificationText = evaluations.flatMap(\.notifications).map {
            "\($0.title) \($0.body)"
        }.joined(separator: " ")
        XCTAssertFalse(notificationText.contains("first-private-id"))
        XCTAssertFalse(notificationText.contains("second-private-id"))
        XCTAssertFalse(notificationText.contains("third-private-id"))
    }

    func testLegacySuppressionIDsMigrateWithoutDuplicateNotifications() throws {
        let settings = UsageAlertSettings(isEnabled: true)

        let warning = UsageAlertEvaluator.evaluate(
            results: [result(used: 80)],
            settings: settings,
            activeAlertIDs: ["usage.codex.personal.weekly"]
        )
        XCTAssertTrue(warning.notifications.isEmpty)
        XCTAssertEqual(
            warning.activeAlertIDs,
            ["severity.warning.codex.personal"]
        )

        let critical = UsageAlertEvaluator.evaluate(
            results: [result(used: 95)],
            settings: settings,
            activeAlertIDs: ["severity.codex.personal"]
        )
        XCTAssertEqual(
            critical.notifications.map(\.title),
            ["Codex Critical Alert"]
        )
        XCTAssertEqual(
            critical.activeAlertIDs,
            [
                "severity.warning.codex.personal",
                "severity.critical.codex.personal",
            ]
        )

        let criticalNotification = try XCTUnwrap(critical.notifications.first)
        var activeAlertIDs = critical.activeAlertIDs
        UsageAlertEvaluator.removeActiveAlertIDs(
            forFailedDelivery: criticalNotification,
            from: &activeAlertIDs,
            previouslyActiveAlertIDs: ["severity.codex.personal"],
            knownAccountIDs: ["codex.personal"]
        )
        XCTAssertEqual(activeAlertIDs, ["severity.warning.codex.personal"])

        let recoveredToWarning = UsageAlertEvaluator.evaluate(
            results: [result(used: 80)],
            settings: settings,
            activeAlertIDs: activeAlertIDs
        )
        XCTAssertTrue(recoveredToWarning.notifications.isEmpty)
    }

    func testLegacySuppressionIDsUseExactAccountIdentity() throws {
        let defaultResult = result(accountID: "codex", used: 95)
        let legacySecondaryAlertID = "usage.codex.secondary.weekly"
        let settings = UsageAlertSettings(isEnabled: true)

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [defaultResult],
            settings: settings,
            activeAlertIDs: [legacySecondaryAlertID],
            knownAccountIDs: ["codex", "codex.secondary"]
        )

        XCTAssertEqual(
            evaluation.notifications.map(\.title),
            ["Codex Critical Alert"]
        )
        let notification = try XCTUnwrap(evaluation.notifications.first)
        var activeAlertIDs = evaluation.activeAlertIDs
        UsageAlertEvaluator.removeActiveAlertIDs(
            forFailedDelivery: notification,
            from: &activeAlertIDs,
            previouslyActiveAlertIDs: [legacySecondaryAlertID],
            knownAccountIDs: ["codex", "codex.secondary"]
        )
        XCTAssertTrue(activeAlertIDs.isEmpty)
    }

    func testProjectedUsageUsesConfiguredThresholds() {
        let now = Date(timeIntervalSince1970: 1_783_667_520)
        let projectedResult = result(
            title: "Personal Codex",
            used: 40,
            projectionCurrent: 40,
            projectionPeriodStart: now.addingTimeInterval(-4 * 24 * 60 * 60),
            projectionPeriodEnd: now.addingTimeInterval(6 * 24 * 60 * 60),
            fetchedAt: now
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            warningThreshold: 0.70,
            criticalThreshold: 0.95
        )

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [projectedResult],
            settings: settings,
            activeAlertIDs: [],
            now: now
        )

        XCTAssertEqual(evaluation.notifications.count, 1)
        XCTAssertEqual(evaluation.activeAlerts.first?.severity, .critical)
        XCTAssertEqual(
            evaluation.activeAlerts.first?.message,
            "Weekly projected usage is 100% (Critical Alert at 95%)."
        )
        XCTAssertEqual(
            evaluation.notifications.first?.body,
            "Personal Codex (ChatGPT / Codex): Critical status. Weekly projected usage is 100% (Critical Alert at 95%)."
        )
    }

    func testEscalationRecoveryAndRearmingProduceOnlyUsefulNotifications() {
        let settings = UsageAlertSettings(isEnabled: true)

        let warning = UsageAlertEvaluator.evaluate(
            results: [result(used: 80)],
            settings: settings,
            activeAlertIDs: []
        )
        XCTAssertEqual(warning.notifications.map(\.title), ["Codex Warning"])

        let critical = UsageAlertEvaluator.evaluate(
            results: [result(used: 95)],
            settings: settings,
            activeAlertIDs: warning.activeAlertIDs
        )
        XCTAssertEqual(critical.notifications.map(\.title), ["Codex Critical Alert"])

        let recoveredToWarning = UsageAlertEvaluator.evaluate(
            results: [result(used: 80)],
            settings: settings,
            activeAlertIDs: critical.activeAlertIDs
        )
        XCTAssertTrue(recoveredToWarning.notifications.isEmpty)
        XCTAssertEqual(
            recoveredToWarning.activeAlertIDs,
            ["severity.warning.codex.personal"]
        )

        let recoveredToNormal = UsageAlertEvaluator.evaluate(
            results: [result(used: 50)],
            settings: settings,
            activeAlertIDs: recoveredToWarning.activeAlertIDs
        )
        XCTAssertTrue(recoveredToNormal.activeAlertIDs.isEmpty)

        let rearmed = UsageAlertEvaluator.evaluate(
            results: [result(used: 80)],
            settings: settings,
            activeAlertIDs: recoveredToNormal.activeAlertIDs
        )
        XCTAssertEqual(rearmed.notifications.map(\.title), ["Codex Warning"])
    }

    func testMultipleMetricsChooseTheLargestCrossingRegardlessOfArrayOrder() {
        let bars = [
            UsageBar(stableKey: "five-hour", label: "5-hour", used: 105, limit: 100),
            UsageBar(stableKey: "weekly", label: "Weekly", used: 112, limit: 100),
        ]
        func makeResult(bars: [UsageBar]) -> ProviderUsageResult {
            ProviderUsageResult(
                accountID: "codex.personal",
                providerID: .codex,
                title: "Codex",
                subtitle: "Live usage",
                bars: bars,
                fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
            )
        }

        let evaluations = [bars, Array(bars.reversed())].map { bars in
            UsageAlertEvaluator.evaluate(
                results: [makeResult(bars: Array(bars))],
                settings: UsageAlertSettings(isEnabled: true),
                activeAlertIDs: []
            )
        }

        XCTAssertTrue(evaluations.allSatisfy { $0.notifications.count == 1 })
        XCTAssertEqual(
            evaluations.compactMap { $0.notifications.first?.body },
            [
                "Codex (ChatGPT / Codex): Critical status. Weekly current usage is 112% (Critical Alert at 90%).",
                "Codex (ChatGPT / Codex): Critical status. Weekly current usage is 112% (Critical Alert at 90%).",
            ]
        )
        XCTAssertTrue(evaluations.allSatisfy { evaluation in
            evaluation.activeAlerts.count == 1
                && !evaluation.activeAlertIDs.contains { $0.hasPrefix("usage.") }
        })
    }

    func testFailedCriticalDeliveryClearsCompanionWarningLatch() throws {
        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result(used: 95)],
            settings: UsageAlertSettings(isEnabled: true),
            activeAlertIDs: []
        )
        let notification = try XCTUnwrap(evaluation.notifications.first)
        var activeAlertIDs = evaluation.activeAlertIDs

        UsageAlertEvaluator.removeActiveAlertIDs(
            forFailedDelivery: notification,
            from: &activeAlertIDs,
            previouslyActiveAlertIDs: [],
            knownAccountIDs: ["codex.personal"]
        )

        XCTAssertTrue(activeAlertIDs.isEmpty)
        let warningEvaluation = UsageAlertEvaluator.evaluate(
            results: [result(used: 80)],
            settings: UsageAlertSettings(isEnabled: true),
            activeAlertIDs: activeAlertIDs
        )
        XCTAssertEqual(warningEvaluation.notifications.map(\.title), ["Codex Warning"])
    }

    func testFailedCriticalDeliveryRetainsPreviouslyDeliveredWarningLatch() throws {
        let settings = UsageAlertSettings(isEnabled: true)
        let warningEvaluation = UsageAlertEvaluator.evaluate(
            results: [result(used: 80)],
            settings: settings,
            activeAlertIDs: []
        )
        let criticalEvaluation = UsageAlertEvaluator.evaluate(
            results: [result(used: 95)],
            settings: settings,
            activeAlertIDs: warningEvaluation.activeAlertIDs
        )
        let criticalNotification = try XCTUnwrap(
            criticalEvaluation.notifications.first
        )
        var activeAlertIDs = criticalEvaluation.activeAlertIDs

        UsageAlertEvaluator.removeActiveAlertIDs(
            forFailedDelivery: criticalNotification,
            from: &activeAlertIDs,
            previouslyActiveAlertIDs: warningEvaluation.activeAlertIDs,
            knownAccountIDs: ["codex.personal"]
        )

        XCTAssertEqual(activeAlertIDs, ["severity.warning.codex.personal"])
        let recoveredWarning = UsageAlertEvaluator.evaluate(
            results: [result(used: 80)],
            settings: settings,
            activeAlertIDs: activeAlertIDs
        )
        XCTAssertTrue(recoveredWarning.notifications.isEmpty)
    }

    func testSpendLimitRemainsCriticalRegardlessOfPercentageThresholds() {
        let result = ProviderUsageResult(
            accountID: "claude.capped",
            providerID: .claude,
            title: "Work Claude",
            subtitle: "Live usage",
            bars: [],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .spent,
                    label: "Usage credits spent",
                    minorUnits: 5000,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
                ProviderMonetaryMetric(
                    kind: .spendLimit,
                    label: "Monthly spend limit",
                    minorUnits: 5000,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: UsageAlertSettings(
                isEnabled: true,
                warningThreshold: 0.98,
                criticalThreshold: 0.99
            ),
            activeAlertIDs: []
        )

        XCTAssertEqual(evaluation.notifications.map(\.kind), [.severity])
        XCTAssertEqual(evaluation.notifications.first?.title, "Work Claude Critical Alert")
        XCTAssertEqual(evaluation.activeAlerts.first?.severity, .critical)
        XCTAssertEqual(
            evaluation.activeAlerts.first?.message,
            "Work Claude reached its monthly usage-credit spend limit."
        )
        XCTAssertEqual(
            evaluation.notifications.first?.body,
            "Work Claude (Claude): Critical status. Work Claude reached its monthly usage-credit spend limit."
        )
    }

    @MainActor
    func testLocalNotifierDeliversEvaluatorTitleAndAccountSpecificBody() throws {
        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result(title: "Personal Codex", used: 95)],
            settings: UsageAlertSettings(isEnabled: true),
            activeAlertIDs: []
        )
        let notification = try XCTUnwrap(evaluation.notifications.first)

        let content = LocalUsageAlertNotifier.content(for: notification)

        XCTAssertEqual(content.title, "Personal Codex Critical Alert")
        XCTAssertEqual(
            content.body,
            "Personal Codex (ChatGPT / Codex): Critical status. Weekly current usage is 95% (Critical Alert at 90%)."
        )
    }

    func testLowBalanceAlertBehaviorRemainsIndependent() {
        let result = ProviderUsageResult(
            accountID: "openRouter.main",
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Credit balance",
            bars: [],
            creditsRemaining: 4.50,
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: UsageAlertSettings(isEnabled: true, balanceThreshold: 5),
            activeAlertIDs: []
        )

        XCTAssertEqual(evaluation.notifications.map(\.kind), [.balance])
        XCTAssertEqual(evaluation.notifications.first?.title, "OpenRouter balance alert")
        XCTAssertEqual(evaluation.activeAlerts.first?.title, "Balance below $5.00")
    }

    func testStaleBarsPreserveSuppressionWithoutSendingNewAlert() {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let settings = UsageAlertSettings(isEnabled: true)
        let freshResult = result(used: 80, fetchedAt: fetchedAt)
        let first = UsageAlertEvaluator.evaluate(
            results: [freshResult],
            settings: settings,
            activeAlertIDs: []
        )
        let staleResult = ProviderUsageResult(
            accountID: freshResult.accountID,
            providerID: freshResult.providerID,
            title: freshResult.title,
            subtitle: "Cached usage",
            bars: freshResult.bars,
            barsFetchedAt: fetchedAt,
            fetchedAt: fetchedAt.addingTimeInterval(60)
        )

        let stale = UsageAlertEvaluator.evaluate(
            results: [staleResult],
            settings: settings,
            activeAlertIDs: first.activeAlertIDs
        )

        XCTAssertTrue(stale.notifications.isEmpty)
        XCTAssertTrue(stale.activeAlerts.isEmpty)
        XCTAssertEqual(stale.activeAlertIDs, first.activeAlertIDs)
    }

    func testSuppressionPreservationUsesExactAccountIdentity() {
        let activeAlertIDs: Set<String> = [
            "severity.warning.codex",
            "severity.warning.codex.secondary",
            "balance.openrouter.failed",
        ]

        let preserved = UsageAlertEvaluator.activeAlertIDs(
            activeAlertIDs,
            belongingTo: ["codex.secondary", "openrouter.failed"],
            knownAccountIDs: ["codex", "codex.secondary", "openrouter.failed"]
        )

        XCTAssertEqual(
            preserved,
            [
                "severity.warning.codex.secondary",
                "balance.openrouter.failed",
            ]
        )
    }

    func testDisabledAlertsClearSuppressionAndDetails() {
        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result(used: 95)],
            settings: UsageAlertSettings(isEnabled: false),
            activeAlertIDs: [
                "severity.warning.codex.personal",
                "severity.critical.codex.personal",
            ]
        )

        XCTAssertTrue(evaluation.notifications.isEmpty)
        XCTAssertTrue(evaluation.activeAlertIDs.isEmpty)
        XCTAssertTrue(evaluation.activeAlerts.isEmpty)
    }

    func testUsageBarCurrentAndProjectedSeverityAcceptConfiguredThresholds() {
        let now = Date(timeIntervalSince1970: 1_783_667_520)
        let thresholds = UsageSeverityThresholds(warning: 0.50, critical: 0.80)
        let bar = UsageBar(
            label: "Weekly",
            used: 40,
            limit: 100,
            projectionCurrent: 40,
            projectionLimit: 100,
            projectionPeriodStart: now.addingTimeInterval(-4 * 24 * 60 * 60),
            projectionPeriodEnd: now.addingTimeInterval(6 * 24 * 60 * 60)
        )

        XCTAssertEqual(bar.severity(using: thresholds), .normal)
        XCTAssertEqual(
            bar.projectedSeverity(at: now, thresholds: thresholds),
            .critical
        )
        XCTAssertEqual(
            bar.effectiveSeverity(at: now, thresholds: thresholds),
            .critical
        )
    }

    func testHistorySnapshotsCaptureConfiguredSeverity() {
        let snapshot = UsageHistorySnapshot(
            result: result(used: 60),
            severityThresholds: UsageSeverityThresholds(
                warning: 0.50,
                critical: 0.80
            )
        )

        XCTAssertEqual(snapshot.bars.first?.effectiveSeverity, .warning)
        XCTAssertEqual(snapshot.highestSeverity, .warning)
    }

    @MainActor
    func testHistorySeriesRecomputesProjectedSeverityUsingActiveThresholds() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let capturedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let projectedResult = result(
            used: 60,
            projectionCurrent: 60,
            projectionPeriodStart: capturedAt.addingTimeInterval(-75),
            projectionPeriodEnd: capturedAt.addingTimeInterval(25),
            fetchedAt: capturedAt
        )
        let historyStore = UsageHistoryStore(defaults: defaults)

        historyStore.record(results: [projectedResult], now: capturedAt)

        let reloadedStore = UsageHistoryStore(defaults: defaults)
        XCTAssertEqual(
            reloadedStore.historySeries(
                for: projectedResult,
                severityThresholds: UsageSeverityThresholds(
                    warning: 0.75,
                    critical: 0.90
                )
            ).points.map(\.severity),
            [.warning]
        )
        XCTAssertEqual(
            reloadedStore.historySeries(
                for: projectedResult,
                severityThresholds: UsageSeverityThresholds(
                    warning: 0.85,
                    critical: 0.95
                )
            ).points.map(\.severity),
            [.normal]
        )
    }

    @MainActor
    func testWidgetAndWatchSnapshotsUseConfiguredThresholds() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: MemorySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .codex))
        XCTAssertTrue(store.saveSecret("test-token", for: configuration))
        store.updateUsageAlertWarningThreshold(0.50)
        store.updateUsageAlertCriticalThreshold(0.80)
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(stableKey: "weekly", label: "Weekly", used: 60, limit: 100),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )

        WidgetSnapshotPublisher.publish(
            results: [result],
            configurationStore: store,
            snapshotDefaults: defaults
        )
        let widgetProvider = try XCTUnwrap(
            WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first
        )
        XCTAssertEqual(widgetProvider.bars.first?.severity, .warning)
        XCTAssertEqual(widgetProvider.severity, .warning)

        let watchSnapshot = WatchSnapshotPublisher.makeSnapshot(
            results: [result],
            configurationStore: store
        )
        XCTAssertEqual(watchSnapshot.accounts.first?.metrics.first?.severity, .warning)
    }

    private func result(
        accountID: String = "codex.personal",
        title: String = "Codex",
        used: Double,
        projectionCurrent: Double? = nil,
        projectionPeriodStart: Date? = nil,
        projectionPeriodEnd: Date? = nil,
        fetchedAt: Date = Date(timeIntervalSince1970: 1_783_667_520)
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: accountID,
            providerID: .codex,
            title: title,
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    stableKey: "weekly",
                    label: "Weekly",
                    used: used,
                    limit: 100,
                    projectionCurrent: projectionCurrent,
                    projectionLimit: projectionCurrent == nil ? nil : 100,
                    projectionPeriodStart: projectionPeriodStart,
                    projectionPeriodEnd: projectionPeriodEnd
                ),
            ],
            fetchedAt: fetchedAt
        )
    }
}

final class GitHubStatusTests: XCTestCase {
    func testStatuspageIncidentParsingUsesLatestUpdateAndWorstSeverity() throws {
        let checkedAt = Date(timeIntervalSince1970: 2_000)
        let data = Data(
            """
            {
              "components": [],
              "incidents": [{
                "id": "incident-1",
                "name": "Actions is unavailable",
                "status": "investigating",
                "impact": "critical",
                "updated_at": "2026-08-17T15:00:00Z",
                "shortlink": "https://www.githubstatus.com/incidents/abc",
                "incident_updates": [
                  {"id": "update-1", "updated_at": "2026-08-17T15:00:00Z"},
                  {"id": "update-2", "updated_at": "2026-08-17T15:10:00Z"}
                ]
              }],
              "status": {"indicator": "critical", "description": "Major outage"}
            }
            """.utf8
        )

        let snapshot = try GitHubStatusParser.parse(data, checkedAt: checkedAt)

        XCTAssertEqual(snapshot.severity, .critical)
        XCTAssertEqual(snapshot.summary, "Actions is unavailable")
        XCTAssertEqual(snapshot.incidentIDs, ["incident-1"])
        XCTAssertEqual(snapshot.updateIdentity, "update-2")
        XCTAssertEqual(snapshot.checkedAt, checkedAt)
        XCTAssertEqual(snapshot.detailsURL.absoluteString, "https://www.githubstatus.com/incidents/abc")
    }

    func testComponentDegradationMapsWithoutInventingIncident() throws {
        let data = Data(
            """
            {
              "components": [
                {"id": "api", "name": "API Requests", "status": "partial_outage",
                 "updated_at": "2026-08-17T15:10:00Z", "group": false},
                {"id": "web", "name": "Git Operations", "status": "operational",
                 "updated_at": "2026-08-17T15:10:00Z", "group": false}
              ],
              "incidents": [],
              "status": {"indicator": "major", "description": "Partial outage"}
            }
            """.utf8
        )

        let snapshot = try GitHubStatusParser.parse(data)

        XCTAssertEqual(snapshot.severity, .major)
        XCTAssertEqual(snapshot.summary, "Affected components: API Requests")
        XCTAssertEqual(snapshot.incidentIDs, ["component:api"])
    }

    func testNoImpactIncidentDoesNotCreateOutage() throws {
        let data = Data(
            """
            {
              "components": [],
              "incidents": [{
                "id": "informational",
                "name": "Informational update",
                "status": "monitoring",
                "impact": "none",
                "updated_at": "2026-08-17T15:00:00Z",
                "shortlink": null,
                "incident_updates": []
              }],
              "status": {"indicator": "none", "description": "All Systems Operational"}
            }
            """.utf8
        )

        let snapshot = try GitHubStatusParser.parse(data)

        XCTAssertEqual(snapshot.severity, .operational)
        XCTAssertFalse(snapshot.isActive)
        XCTAssertTrue(snapshot.incidentIDs.isEmpty)
    }

    func testSameSeverityIncidentsChooseLeadDeterministically() throws {
        let data = Data(
            """
            {
              "components": [],
              "incidents": [
                {"id": "z-incident", "name": "Zulu", "status": "investigating",
                 "impact": "major", "updated_at": "2026-08-17T15:00:00Z",
                 "shortlink": null, "incident_updates": []},
                {"id": "a-incident", "name": "Alpha", "status": "investigating",
                 "impact": "major", "updated_at": "2026-08-17T15:00:00Z",
                 "shortlink": null, "incident_updates": []}
              ],
              "status": {"indicator": "major", "description": "Partial outage"}
            }
            """.utf8
        )

        let snapshot = try GitHubStatusParser.parse(data)

        XCTAssertEqual(snapshot.summary, "Alpha and 1 more incident")
        XCTAssertEqual(snapshot.updateIdentity, "a-incident")
    }

    func testSecondaryIncidentLatestUpdateChangesBannerIdentity() throws {
        let data = Data(
            """
            {
              "components": [],
              "incidents": [
                {"id": "a-incident", "name": "Alpha", "status": "investigating",
                 "impact": "major", "updated_at": "2026-08-17T15:00:00Z",
                 "shortlink": null, "incident_updates": [
                   {"id": "alpha-update", "updated_at": "2026-08-17T15:00:00Z"}
                 ]},
                {"id": "b-incident", "name": "Beta", "status": "monitoring",
                 "impact": "minor", "updated_at": "2026-08-17T15:05:00Z",
                 "shortlink": null, "incident_updates": [
                   {"id": "beta-update", "updated_at": "2026-08-17T15:05:00Z"}
                 ]}
              ],
              "status": {"indicator": "major", "description": "Partial outage"}
            }
            """.utf8
        )

        let snapshot = try GitHubStatusParser.parse(data)

        XCTAssertEqual(snapshot.summary, "Alpha and 1 more incident")
        XCTAssertEqual(snapshot.updateIdentity, "beta-update")
    }

    @MainActor
    func testPreferencesAreOffByDefaultAndPersistIndependentChoices() throws {
        let suiteName = "GitHubStatusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GitHubStatusPreferences(defaults: defaults)
        XCTAssertFalse(preferences.settings.isEnabled)

        preferences.updateSettings(
            GitHubStatusSettings(
                isEnabled: true,
                pollingInterval: .oneHour,
                showsInAppBanner: false,
                sendsIncidentNotifications: true,
                sendsRecoveryNotifications: false
            )
        )
        let reloaded = GitHubStatusPreferences(defaults: defaults)

        XCTAssertEqual(reloaded.settings.pollingInterval, .oneHour)
        XCTAssertFalse(reloaded.settings.showsInAppBanner)
        XCTAssertTrue(reloaded.settings.sendsIncidentNotifications)
        XCTAssertFalse(reloaded.settings.sendsRecoveryNotifications)
    }

    @MainActor
    func testDisablingMonitorClearsIncidentTransitionBaseline() async throws {
        let suiteName = "GitHubStatusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GitHubStatusPreferences(defaults: defaults)
        let enabledSettings = GitHubStatusSettings(
            isEnabled: true,
            sendsRecoveryNotifications: true
        )
        preferences.updateSettings(enabledSettings)
        preferences.recordSuccess(
            Self.snapshot(
                severity: .major,
                incidentIDs: ["incident-1"],
                updateIdentity: "update-1"
            )
        )

        var disabledSettings = enabledSettings
        disabledSettings.isEnabled = false
        preferences.updateSettings(disabledSettings)

        let reloadedPreferences = GitHubStatusPreferences(defaults: defaults)
        XCTAssertNil(reloadedPreferences.snapshot)
        reloadedPreferences.updateSettings(enabledSettings)
        let notifier = RecordingGitHubStatusNotifier()
        let recovered = Self.snapshot(
            severity: .operational,
            incidentIDs: [],
            updateIdentity: "none"
        )
        let monitor = GitHubStatusMonitor(
            preferences: reloadedPreferences,
            fetcher: StubGitHubStatusFetcher(results: [.success(recovered)]),
            notifier: notifier
        )

        await monitor.refreshIfDue(force: true, now: recovered.checkedAt)

        XCTAssertTrue(notifier.notifications.isEmpty)
    }

    func testTransitionDeduplicatesUpdatesAndNotifiesEscalationAndRecovery() {
        let settings = GitHubStatusSettings(
            isEnabled: true,
            sendsIncidentNotifications: true,
            sendsRecoveryNotifications: true
        )
        let incident = snapshot(
            severity: .minor,
            incidentIDs: ["incident-1"],
            updateIdentity: "update-1"
        )
        let repeatedPoll = snapshot(
            severity: .minor,
            incidentIDs: ["incident-1"],
            updateIdentity: "update-2"
        )
        let escalated = snapshot(
            severity: .critical,
            incidentIDs: ["incident-1"],
            updateIdentity: "update-3"
        )
        let recovered = snapshot(severity: .operational, incidentIDs: [], updateIdentity: "none")

        XCTAssertEqual(
            GitHubStatusTransitionEvaluator.notification(
                previous: nil,
                current: incident,
                settings: settings
            )?.kind,
            .incident
        )
        XCTAssertNil(
            GitHubStatusTransitionEvaluator.notification(
                previous: incident,
                current: repeatedPoll,
                settings: settings
            )
        )
        XCTAssertEqual(
            GitHubStatusTransitionEvaluator.notification(
                previous: repeatedPoll,
                current: escalated,
                settings: settings
            )?.kind,
            .escalation
        )
        XCTAssertEqual(
            GitHubStatusTransitionEvaluator.notification(
                previous: escalated,
                current: recovered,
                settings: settings
            )?.kind,
            .recovery
        )

        let disabledSettings = GitHubStatusSettings(isEnabled: true)
        XCTAssertNil(
            GitHubStatusTransitionEvaluator.notification(
                previous: nil,
                current: incident,
                settings: disabledSettings
            )
        )
        XCTAssertNil(
            GitHubStatusTransitionEvaluator.notification(
                previous: escalated,
                current: recovered,
                settings: disabledSettings
            )
        )
    }

    func testBannerFreshnessDistinguishesDeferredDataFromFailedCheck() {
        XCTAssertEqual(
            GitHubStatusBannerMessage.freshness(
                updatedAt: "Aug 17 at 3:00 PM",
                isStale: true,
                statusCheckFailed: false
            ),
            "Last known status, updated Aug 17 at 3:00 PM. This status is stale because a newer check has not completed."
        )
        XCTAssertEqual(
            GitHubStatusBannerMessage.freshness(
                updatedAt: "Aug 17 at 3:00 PM",
                isStale: true,
                statusCheckFailed: true
            ),
            "Last known status, updated Aug 17 at 3:00 PM. A recent status check was unavailable; this is not a newly confirmed outage."
        )
    }

    func testBannerFreshnessTimelineCrossesAtDeadline() {
        let snapshot = Self.snapshot(
            severity: .major,
            incidentIDs: ["incident-1"],
            updateIdentity: "update-1"
        )
        let staleDate = GitHubStatusFreshness.staleDate(snapshot, interval: .thirtyMinutes)

        XCTAssertEqual(staleDate, snapshot.checkedAt.addingTimeInterval(3_600))
        XCTAssertEqual(GitHubStatusFreshness.timelineRefreshInterval, 60)
        XCTAssertFalse(
            GitHubStatusFreshness.isStale(
                snapshot,
                interval: .thirtyMinutes,
                now: staleDate.addingTimeInterval(-1)
            )
        )
        XCTAssertTrue(
            GitHubStatusFreshness.isStale(
                snapshot,
                interval: .thirtyMinutes,
                now: staleDate
            )
        )
    }

    @MainActor
    func testMonitorDeliversNewIncidentNotification() async throws {
        let suiteName = "GitHubStatusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GitHubStatusPreferences(defaults: defaults)
        preferences.updateSettings(
            GitHubStatusSettings(
                isEnabled: true,
                sendsIncidentNotifications: true
            )
        )
        let incident = Self.snapshot(
            severity: .major,
            incidentIDs: ["incident-1"],
            updateIdentity: "update-1"
        )
        let notifier = RecordingGitHubStatusNotifier()
        let monitor = GitHubStatusMonitor(
            preferences: preferences,
            fetcher: StubGitHubStatusFetcher(results: [.success(incident)]),
            notifier: notifier
        )

        await monitor.refreshIfDue(force: true, now: incident.checkedAt)

        XCTAssertEqual(notifier.notifications.map(\.kind), [.incident])
    }

    @MainActor
    func testMonitorRetriesNotificationBeforeNextFetchSucceeds() async throws {
        let suiteName = "GitHubStatusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GitHubStatusPreferences(defaults: defaults)
        preferences.updateSettings(
            GitHubStatusSettings(
                isEnabled: true,
                sendsIncidentNotifications: true
            )
        )
        let incident = Self.snapshot(
            severity: .major,
            incidentIDs: ["incident-1"],
            updateIdentity: "update-1"
        )
        let notifier = RecordingGitHubStatusNotifier(failuresRemaining: 1)
        let firstMonitor = GitHubStatusMonitor(
            preferences: preferences,
            fetcher: StubGitHubStatusFetcher(results: [.success(incident)]),
            notifier: notifier
        )

        await firstMonitor.refreshIfDue(force: true, now: incident.checkedAt)
        XCTAssertTrue(notifier.notifications.isEmpty)

        let reloadedPreferences = GitHubStatusPreferences(defaults: defaults)
        let retryMonitor = GitHubStatusMonitor(
            preferences: reloadedPreferences,
            fetcher: StubGitHubStatusFetcher(results: [.failure(GitHubStatusParsingError.invalidResponse)]),
            notifier: notifier
        )
        await retryMonitor.refreshIfDue(force: true, now: incident.checkedAt.addingTimeInterval(1))
        XCTAssertEqual(notifier.notifications.map(\.kind), [.incident])
    }

    @MainActor
    func testMonitorIgnoresCancellationWithoutRecordingFailure() async throws {
        let suiteName = "GitHubStatusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GitHubStatusPreferences(defaults: defaults)
        preferences.updateSettings(GitHubStatusSettings(isEnabled: true))
        let monitor = GitHubStatusMonitor(
            preferences: preferences,
            fetcher: StubGitHubStatusFetcher(results: [.failure(CancellationError())]),
            notifier: RecordingGitHubStatusNotifier()
        )

        await monitor.refreshIfDue(force: true)

        XCTAssertNil(preferences.lastChecked)
        XCTAssertNil(preferences.lastError)
    }

    @MainActor
    func testMonitorDiscardsInFlightResultsAcrossDisableAndReenable() async throws {
        let suiteName = "GitHubStatusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GitHubStatusPreferences(defaults: defaults)
        let enabledSettings = GitHubStatusSettings(
            isEnabled: true,
            sendsIncidentNotifications: true
        )
        preferences.updateSettings(enabledSettings)
        let fetcher = SuspendedGitHubStatusFetcher()
        let notifier = RecordingGitHubStatusNotifier()
        let monitor = GitHubStatusMonitor(
            preferences: preferences,
            fetcher: fetcher,
            notifier: notifier
        )
        let incident = Self.snapshot(
            severity: .major,
            incidentIDs: ["incident-1"],
            updateIdentity: "update-1"
        )

        let refresh = Task { await monitor.refreshIfDue(force: true, now: incident.checkedAt) }
        await fetcher.waitUntilStarted()
        var disabledSettings = enabledSettings
        disabledSettings.isEnabled = false
        preferences.updateSettings(disabledSettings)
        preferences.updateSettings(enabledSettings)
        let queuedRefresh = Task {
            await monitor.refreshIfDue(force: true, now: incident.checkedAt.addingTimeInterval(1))
        }
        await Task.yield()
        await fetcher.complete(with: incident)
        await refresh.value
        await fetcher.waitUntilStarted()

        XCTAssertNil(preferences.snapshot)
        XCTAssertTrue(notifier.notifications.isEmpty)

        let currentSnapshot = Self.snapshot(
            severity: .operational,
            incidentIDs: [],
            updateIdentity: "current"
        )
        await fetcher.complete(with: currentSnapshot)
        var waitAttempts = 0
        while monitor.isRefreshing, waitAttempts < 100 {
            waitAttempts += 1
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(monitor.isRefreshing, "Queued refresh did not finish within one second")
        await queuedRefresh.value
        XCTAssertEqual(preferences.snapshot, currentSnapshot)
        XCTAssertTrue(notifier.notifications.isEmpty)

        let failedRefresh = Task {
            await monitor.refreshIfDue(force: true, now: incident.checkedAt.addingTimeInterval(1))
        }
        await fetcher.waitUntilStarted()
        preferences.updateSettings(disabledSettings)
        preferences.updateSettings(enabledSettings)
        await fetcher.fail(with: GitHubStatusParsingError.invalidResponse)
        await failedRefresh.value

        XCTAssertEqual(preferences.lastChecked, currentSnapshot.checkedAt)
        XCTAssertNil(preferences.lastError)
    }

    @MainActor
    func testBackgroundRefreshWaitsForCoalescedFetch() async throws {
        let suiteName = "GitHubStatusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GitHubStatusPreferences(defaults: defaults)
        preferences.updateSettings(GitHubStatusSettings(isEnabled: true))
        let fetcher = SuspendedGitHubStatusFetcher()
        let monitor = GitHubStatusMonitor(
            preferences: preferences,
            fetcher: fetcher,
            notifier: RecordingGitHubStatusNotifier()
        )
        let completion = AsyncCompletionFlag()
        let firstSnapshot = Self.snapshot(
            severity: .operational,
            incidentIDs: [],
            updateIdentity: "first"
        )
        let secondSnapshot = Self.snapshot(
            severity: .operational,
            incidentIDs: [],
            updateIdentity: "second"
        )

        let foregroundRefresh = Task { await monitor.refreshIfDue(force: true) }
        await fetcher.waitUntilStarted()
        let backgroundRefresh = Task {
            await monitor.performBackgroundRefresh()
            await completion.markComplete()
        }
        for _ in 0..<10 {
            await Task.yield()
        }

        await fetcher.complete(with: firstSnapshot)
        await foregroundRefresh.value
        await fetcher.waitUntilStarted()

        let completedBeforeCoalescedFetch = await completion.isComplete
        XCTAssertFalse(completedBeforeCoalescedFetch)

        await fetcher.complete(with: secondSnapshot)
        await backgroundRefresh.value

        XCTAssertEqual(preferences.snapshot, secondSnapshot)
        let completedAfterCoalescedFetch = await completion.isComplete
        XCTAssertTrue(completedAfterCoalescedFetch)
    }

    @MainActor
    func testFetchFailurePreservesLastKnownIncidentAndMarksItStale() async throws {
        let suiteName = "GitHubStatusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GitHubStatusPreferences(defaults: defaults)
        preferences.updateSettings(GitHubStatusSettings(isEnabled: true))
        let active = Self.snapshot(
            severity: .major,
            incidentIDs: ["incident-1"],
            updateIdentity: "update-1",
            checkedAt: Date(timeIntervalSince1970: 1_000)
        )
        let fetcher = StubGitHubStatusFetcher(results: [
            .success(active),
            .failure(GitHubStatusParsingError.invalidResponse),
        ])
        let monitor = GitHubStatusMonitor(
            preferences: preferences,
            fetcher: fetcher,
            notifier: RecordingGitHubStatusNotifier()
        )

        await monitor.refreshIfDue(force: true, now: active.checkedAt)
        await monitor.refreshIfDue(force: true, now: Date(timeIntervalSince1970: 10_000))

        XCTAssertEqual(preferences.snapshot, active)
        XCTAssertNotNil(preferences.lastError)
        XCTAssertTrue(
            GitHubStatusFreshness.isStale(
                active,
                interval: .thirtyMinutes,
                now: Date(timeIntervalSince1970: 10_000)
            )
        )
    }

    private static func snapshot(
        severity: GitHubServiceSeverity,
        incidentIDs: [String],
        updateIdentity: String,
        checkedAt: Date = Date(timeIntervalSince1970: 2_000)
    ) -> GitHubServiceStatusSnapshot {
        GitHubServiceStatusSnapshot(
            severity: severity,
            summary: severity.displayName,
            incidentIDs: incidentIDs,
            updateIdentity: updateIdentity,
            updatedAt: checkedAt,
            checkedAt: checkedAt,
            detailsURL: URL(string: "https://www.githubstatus.com")!
        )
    }

    private func snapshot(
        severity: GitHubServiceSeverity,
        incidentIDs: [String],
        updateIdentity: String
    ) -> GitHubServiceStatusSnapshot {
        Self.snapshot(
            severity: severity,
            incidentIDs: incidentIDs,
            updateIdentity: updateIdentity
        )
    }
}

private actor StubGitHubStatusFetcher: GitHubStatusFetching {
    private var results: [Result<GitHubServiceStatusSnapshot, Error>]

    init(results: [Result<GitHubServiceStatusSnapshot, Error>]) {
        self.results = results
    }

    func fetchStatus(checkedAt: Date) async throws -> GitHubServiceStatusSnapshot {
        guard !results.isEmpty else {
            throw GitHubStatusParsingError.invalidResponse
        }
        return try results.removeFirst().get()
    }
}

private actor SuspendedGitHubStatusFetcher: GitHubStatusFetching {
    private var fetchContinuation: CheckedContinuation<GitHubServiceStatusSnapshot, any Error>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []

    func fetchStatus(checkedAt: Date) async throws -> GitHubServiceStatusSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            fetchContinuation = continuation
            startContinuations.forEach { $0.resume() }
            startContinuations.removeAll()
        }
    }

    func waitUntilStarted() async {
        guard fetchContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func complete(with snapshot: GitHubServiceStatusSnapshot) {
        fetchContinuation?.resume(returning: snapshot)
        fetchContinuation = nil
    }

    func fail(with error: any Error) {
        fetchContinuation?.resume(throwing: error)
        fetchContinuation = nil
    }
}

private actor AsyncCompletionFlag {
    private(set) var isComplete = false

    func markComplete() {
        isComplete = true
    }
}

@MainActor
private final class RecordingGitHubStatusNotifier: GitHubStatusNotifying {
    private(set) var notifications: [GitHubStatusNotification] = []
    private var failuresRemaining: Int

    init(failuresRemaining: Int = 0) {
        self.failuresRemaining = failuresRemaining
    }

    func deliverGitHubStatus(_ notification: GitHubStatusNotification) async throws {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw GitHubStatusParsingError.invalidResponse
        }
        notifications.append(notification)
    }
}
