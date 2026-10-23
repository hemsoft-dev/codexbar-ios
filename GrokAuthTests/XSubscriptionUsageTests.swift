import Foundation
import XCTest
@testable import CodexBarIOS

final class XSubscriptionUsageTests: XCTestCase, @unchecked Sendable {
    private let now = ISO8601DateFormatter().date(from: "2026-10-14T12:00:00Z")!
    private let account = ProviderAccountConfiguration.defaultConfiguration(for: .xSubscription)
    private let weekly = #""currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-10-12T00:00:00Z","end":"2026-10-19T00:00:00Z"}"#

    func testProviderIdentityAndPoolMetricID() throws {
        XCTAssertEqual(ProviderID.xSubscription.rawValue, "xSubscription")
        XCTAssertEqual(ProviderID.xSubscription.displayName, "X Subscription")
        XCTAssertTrue(ProviderID.xSubscription.supportsPlanBadge)
        XCTAssertTrue(ProviderID.xSubscription.usesXAIConsumerAuth)
        XCTAssertTrue(ProviderID.grok.usesXAIConsumerAuth)
        XCTAssertFalse(ProviderID.cursor.usesXAIConsumerAuth)
        XCTAssertEqual(account.authMethod, .browserSession)
        let result = try parse(#"{"config":{"creditUsagePercent":38,\#(weekly)}}"#)
        XCTAssertEqual(result.providerID, .xSubscription)
        XCTAssertEqual(result.availableMetrics.map(\.id), [XSubscriptionCopy.poolMetricID])
        XCTAssertEqual(XSubscriptionCopy.poolMetricID, "xSubscription.weekly-pool")
    }

    func testActiveWeeklyPoolShowsPercentAndExactReset() throws {
        let result = try parse(#"{"config":{"creditUsagePercent":38.5,\#(weekly),"prepaidBalance":{"val":1250}}}"#)
        let bar = try XCTUnwrap(result.bars.first)
        XCTAssertEqual(result.bars.count, 1)
        XCTAssertEqual(bar.stableKey, "weekly-pool")
        XCTAssertEqual(bar.label, "Weekly shared pool")
        XCTAssertEqual(bar.used, 38.5)
        XCTAssertEqual(bar.limit, 100)
        XCTAssertEqual(bar.resetsAt, ISO8601DateFormatter().date(from: "2026-10-19T00:00:00Z"))
        XCTAssertEqual(bar.resetDisplayStyle, .relativeWithLocalTime)
        XCTAssertEqual(bar.projectionPeriodStart, ISO8601DateFormatter().date(from: "2026-10-12T00:00:00Z"))
        XCTAssertEqual(result.monetaryMetrics.map(\.minorUnits), [1250])
        XCTAssertEqual(result.monetaryMetrics.first?.label, "Extra Usage Credits")
        XCTAssertEqual(result.monetaryMetrics.first?.metricIdentifier(providerID: .xSubscription), "xSubscription.monetary.balance.usd")
        XCTAssertTrue(result.usageMessages.isEmpty)
        XCTAssertNil(result.failureMessage)
        XCTAssertNil(result.subscriptionRenewal)
        XCTAssertEqual(result.cardInformationSections.last?.id, "xSubscription.billing-source")
    }

    func testPoolDoesNotRequireTheOlderUnifiedBillingFlag() throws {
        for flag in ["false,", "true,", ""] {
            let result = try parse(#"{"config":{"isUnifiedBillingUser":\#(flag.isEmpty ? "null," : flag)"creditUsagePercent":12,\#(weekly),"prepaidBalance":{"val":5}}}"#)
            XCTAssertEqual(result.bars.first?.used, 12, flag)
            XCTAssertEqual(result.monetaryMetrics.map(\.minorUnits), [5], flag)
        }
    }

    func testMissingNullOrNegativePercentStaysUnavailable() throws {
        for field in [
            "", #""creditUsagePercent":null,"#, #""creditUsagePercent":-1,"#,
            #""creditUsagePercent":1e100,"#, #""creditUsagePercent":10001,"#,
        ] {
            let result = try parse(#"{"config":{\#(field)\#(weekly),"prepaidBalance":{"val":10}}}"#)
            XCTAssertTrue(result.bars.isEmpty, field)
            XCTAssertEqual(result.subtitle, "xAI did not report weekly pool usage.", field)
            XCTAssertEqual(result.monetaryMetrics.map(\.minorUnits), [10], field)
            XCTAssertNil(result.verifiedGrokPlanName)
        }
    }

    func testOversizedGrokPercentStaysUnavailableInsteadOfTrapping() throws {
        // A finite but oversized percent would trap when a bar rounds it to Int.
        let grok = ProviderAccountConfiguration.defaultConfiguration(for: .grok)
        for percent in ["1e100", "10001"] {
            let result = try GrokUsageProvider.parseCredits(
                Data(#"{"config":{"creditUsagePercent":\#(percent),"isUnifiedBillingUser":true,\#(weekly)}}"#.utf8),
                configuration: grok, subject: "verified-user", now: now, verifiedPlanName: "SuperGrok"
            )
            XCTAssertTrue(result.bars.isEmpty, percent)
            XCTAssertEqual(result.subtitle, "Grok did not report included usage.", percent)
        }
        let edge = try parse(#"{"config":{"creditUsagePercent":10000,\#(weekly)}}"#)
        XCTAssertEqual(edge.bars.first?.usageText, "10000%")
    }

    func testInactiveMonthlyOrUnspecifiedPeriodIsNotAWeeklyPool() throws {
        let periods = [
            #""currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY","start":"2026-10-01T00:00:00Z","end":"2026-11-01T00:00:00Z"}"#,
            #""currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-10-01T00:00:00Z","end":"2026-10-08T00:00:00Z"}"#,
            #""currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"bad","end":"2026-10-19T00:00:00Z"}"#,
            #""currentPeriod":{"type":"USAGE_PERIOD_TYPE_UNSPECIFIED"}"#,
            #""currentPeriod":null"#,
        ]
        for period in periods {
            let result = try parse(#"{"config":{"creditUsagePercent":40,\#(period),"productUsage":[{"product":"PRODUCT_CURSOR","usagePercent":20}]}}"#)
            XCTAssertTrue(result.bars.isEmpty, period)
            XCTAssertFalse(result.cardInformationSections.contains { $0.id == XSubscriptionCopy.productSectionID }, period)
            XCTAssertFalse(result.usageMessages.isEmpty, period)
        }
    }

    func testMalformedResponsesAreRejected() {
        for payload in ["", "[]", #"{"config":null}"#, #"{"config":{"creditUsagePercent":"bad"}}"#, "{not json"] {
            XCTAssertThrowsError(try parse(payload), payload)
        }
    }

    func testCreditsAcceptOnlyNonNegativeReportedBalances() throws {
        let cases: [(String, Decimal?)] = [
            (#","prepaidBalance":{"val":0}"#, 0),
            (#","prepaidBalance":{}"#, 0),
            (#","prepaidBalance":{"val":499}"#, 499),
            ("", nil),
            (#","prepaidBalance":null"#, nil),
            (#","prepaidBalance":{"val":-20}"#, nil),
            (#","prepaidBalance":{"val":"bad"}"#, nil),
            (#","prepaidBalance":{"other":1}"#, nil),
        ]
        for (field, expected) in cases {
            let result = try parse(#"{"config":{"creditUsagePercent":7,\#(weekly)\#(field)}}"#)
            XCTAssertEqual(result.monetaryMetrics.first?.minorUnits, expected, field)
            XCTAssertEqual(result.bars.first?.used, 7, "Credits never erase a valid pool: \(field)")
            XCTAssertEqual(result.usageMessages.contains("xAI did not report Extra Usage Credits."), expected == nil, field)
        }
    }

    func testProductUsageIsDetailRowsNeverMetersOrSums() throws {
        let products = #"""
            [{"product":"PRODUCT_CURSOR","usagePercent":21.4},{"product":"PRODUCT_GROK_BOT","usagePercent":0.4},
            {"product":9,"usagePercent":3},{"product":11,"usagePercent":2},{"product":"PRODUCT_GROK_CHAT","usagePercent":0},
            {"product":"PRODUCT_UNSPECIFIED","usagePercent":5},{"product":"PRODUCT_FUTURE","usagePercent":5},
            {"product":42,"usagePercent":5},{"product":"PRODUCT_API","usagePercent":-3},
            {"product":"PRODUCT_GROK_VOICE","usagePercent":"bad"},{"usagePercent":5},null,7,
            {"product":"PRODUCT_GROK_IMAGINE","usagePercent":1e999},{"product":"PRODUCT_GROK_TASKS","usagePercent":1e100}]
            """#
        let result = try parse(#"{"config":{"creditUsagePercent":30,\#(weekly),"productUsage":\#(products)}}"#)
        XCTAssertEqual(result.bars.count, 1)
        XCTAssertEqual(result.bars.first?.used, 30)
        XCTAssertEqual(result.availableMetrics.map(\.id), [XSubscriptionCopy.poolMetricID])
        let section = try XCTUnwrap(result.cardInformationSections.first { $0.id == XSubscriptionCopy.productSectionID })
        XCTAssertEqual(section.title, "Weekly pool by product")
        XCTAssertEqual(section.items.map(\.label), ["Cursor", "Grok Bot", "Bugbot"])
        XCTAssertEqual(section.items.map(\.detail), ["21%", "1%", "2%"])
    }

    func testMalformedProductListDoesNotInvalidateThePool() throws {
        for products in [#"{"product":"PRODUCT_CURSOR"}"#, "null", "12", "[]"] {
            let result = try parse(#"{"config":{"creditUsagePercent":30,\#(weekly),"productUsage":\#(products)}}"#)
            XCTAssertEqual(result.bars.first?.used, 30, products)
            XCTAssertFalse(result.cardInformationSections.contains { $0.id == XSubscriptionCopy.productSectionID }, products)
        }
    }

    func testRecognizedUnifiedTierBecomesThePlanButLegacyXTiersDoNot() throws {
        let data = Data(#"{"config":{"creditUsagePercent":3,\#(weekly)}}"#.utf8)
        for (tier, expected) in [
            ("Premium", "Premium"), ("plus", "Plus"), ("X Subscription Super", "Super"), (" ULTRA ", "Ultra"),
            ("X Premium", nil), ("X Premium+", nil), ("Premium+", nil), ("Free", nil), ("SuperGrok Pro", nil), ("", nil),
        ] as [(String, String?)] {
            XCTAssertEqual(GrokUsageProvider.unifiedPlan(tier), expected, tier)
            let result = try GrokUsageProvider.parseXSubscription(
                data, configuration: account, subject: "verified-user", now: now, verifiedPlanName: tier
            )
            XCTAssertEqual(result.verifiedGrokPlanName, expected, tier)
            XCTAssertEqual(result.cardPlan.displayLabel, expected ?? "Plan unavailable", tier)
            XCTAssertEqual(result.bars.first?.used, 3, "An unrecognized tier never blocks the pool: \(tier)")
        }
    }

    func testLegacySuperGrokTierStillShowsPoolAndCreditsWithoutAPlan() throws {
        // grok.com maps legacy tiers to unified names client-side, so a unified account may report "SuperGrok".
        let data = Data(#"{"config":{"creditUsagePercent":44,\#(weekly),"prepaidBalance":{"val":100}}}"#.utf8)
        for tier in ["SuperGrok", "SuperGrok Lite", "SuperGrok Heavy"] {
            let result = try GrokUsageProvider.parseXSubscription(
                data, configuration: account, subject: "verified-user", now: now,
                verifiedPlanName: GrokUsageProvider.unifiedPlan(tier)
            )
            XCTAssertEqual(result.bars.map(\.used), [44], tier)
            XCTAssertEqual(result.monetaryMetrics.map(\.minorUnits), [100], tier)
            XCTAssertNil(result.verifiedGrokPlanName, tier)
            XCTAssertNil(result.failureMessage, tier)
        }
    }

    func testOmittedUsageRemainsUnavailableEvenForVerifiedUnifiedPlan() throws {
        let omitted = Data(#"{"config":{\#(weekly),"prepaidBalance":{"val":0}}}"#.utf8)
        let missing = try GrokUsageProvider.parseXSubscription(
            omitted, configuration: account, subject: "verified-user", now: now, verifiedPlanName: "Premium"
        )
        XCTAssertTrue(missing.bars.isEmpty)
        XCTAssertTrue(missing.usageMessages.contains(XSubscriptionCopy.unavailableReason))
        for plan in [nil, "SuperGrok", "X Premium+"] as [String?] {
            let result = try GrokUsageProvider.parseXSubscription(
                omitted, configuration: account, subject: "verified-user", now: now, verifiedPlanName: plan
            )
            XCTAssertTrue(result.bars.isEmpty, plan ?? "nil")
        }
        let withProducts = Data(#"{"config":{\#(weekly),"productUsage":[]}}"#.utf8)
        XCTAssertTrue(try GrokUsageProvider.parseXSubscription(
            withProducts, configuration: account, subject: "verified-user", now: now, verifiedPlanName: "Premium"
        ).bars.isEmpty)
    }

    func testFailedTierLookupRetainsOnlyTheSameSubjectsUnifiedPlan() throws {
        let omitted = Data(#"{"config":{\#(weekly)}}"#.utf8)
        let incoming = try GrokUsageProvider.parseXSubscription(
            omitted, configuration: account, subject: "verified-user", now: now, planLookupFailed: true
        )
        XCTAssertTrue(incoming.bars.isEmpty)
        let retained = GrokUsageProvider.retainingVerifiedPlan("Premium", for: incoming)
        XCTAssertEqual(retained.providerID, .xSubscription)
        XCTAssertEqual(retained.verifiedGrokPlanName, "Premium")
        XCTAssertTrue(retained.bars.isEmpty)
        XCTAssertTrue(retained.usageMessages.contains(XSubscriptionCopy.unavailableReason))
        XCTAssertTrue(GrokUsageProvider.retainingVerifiedPlan("SuperGrok", for: incoming).bars.isEmpty)
    }

    func testCacheBelongsToVerifiedSubject() throws {
        let data = Data(#"{"config":{"creditUsagePercent":3,\#(weekly)}}"#.utf8)
        let first = try GrokUsageProvider.parseXSubscription(data, configuration: account, subject: "user-a", now: now)
        let other = try GrokUsageProvider.parseXSubscription(data, configuration: account, subject: "user-b", now: now)
        XCTAssertNotEqual(first.cacheIdentity, other.cacheIdentity)
        XCTAssertEqual(first.cacheScope?.hasPrefix("consumer."), true)
    }

    func testGrokWithUnifiedTierKeepsDataAndAddsPointer() throws {
        let data = Data(#"{"config":{"isUnifiedBillingUser":true,"creditUsagePercent":31,\#(weekly),"prepaidBalance":{"val":500}}}"#.utf8)
        let grok = ProviderAccountConfiguration.defaultConfiguration(for: .grok)
        let legacy = try GrokUsageProvider.parseCredits(
            data, configuration: grok, subject: "verified-user", now: now, verifiedPlanName: "SuperGrok"
        )
        let unified = try GrokUsageProvider.parseCredits(
            data, configuration: grok, subject: "verified-user", now: now, unifiedPlanName: "Premium"
        )
        XCTAssertFalse(legacy.usageMessages.contains(GrokUsageProvider.unifiedAccountPointer))
        XCTAssertEqual(unified.usageMessages, [GrokUsageProvider.unifiedAccountPointer])
        XCTAssertEqual(unified.bars.map(\.used), legacy.bars.map(\.used))
        XCTAssertEqual(unified.bars.map(\.resetsAt), legacy.bars.map(\.resetsAt))
        XCTAssertEqual(unified.monetaryMetrics, legacy.monetaryMetrics)
        XCTAssertEqual(unified.providerID, .grok)
        for tier in ["X Premium+", "SuperGrok", nil] as [String?] {
            let result = try GrokUsageProvider.parseCredits(
                data, configuration: grok, subject: "verified-user", now: now, unifiedPlanName: tier
            )
            XCTAssertTrue(result.usageMessages.isEmpty, tier ?? "nil")
        }
    }

    func testCursorUnifiedFlagAddsPointerAndKeepsEveryMetric() throws {
        let cursor = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)
        let primary = Data(#"{"planUsage":{"autoPercentUsed":21,"apiPercentUsed":4}}"#.utf8)
        let reset = "2026-10-20T00:00:00Z"
        func result(_ unified: String) throws -> ProviderUsageResult {
            let bot = Data(#"{"hasNonZeroIncludedLimit":true,"usagePercent":42,"nextResetTimestampUtc":"\#(reset)"\#(unified)}"#.utf8)
            return try XCTUnwrap(CursorUsageProvider.parseUsage(primary, grokBotUsageData: bot, configuration: cursor, fetchedAt: now))
        }
        let absent = try result("")
        for unified in [#","isUnified":true"#, #","is_unified":true"#] {
            let flagged = try result(unified)
            XCTAssertEqual(flagged.usageMessages, [CursorUsageProvider.unifiedAccountPointer], unified)
            XCTAssertEqual(flagged.bars.map(\.stableKey), absent.bars.map(\.stableKey), unified)
            XCTAssertEqual(flagged.bars.map(\.used), absent.bars.map(\.used), unified)
            XCTAssertEqual(flagged.bars.map(\.resetsAt), absent.bars.map(\.resetsAt), unified)
            XCTAssertTrue(flagged.bars.contains { $0.stableKey == "grok-bot-weekly" }, unified)
            XCTAssertEqual(flagged.unavailableUsageMetrics, absent.unavailableUsageMetrics, unified)
            XCTAssertEqual(flagged.configurableMetrics.map(\.id), absent.configurableMetrics.map(\.id), unified)
        }
        XCTAssertTrue(absent.usageMessages.isEmpty)
        for unified in [#","isUnified":false"#, #","isUnified":"yes""#, #","isUnified":null"#] {
            XCTAssertTrue(try result(unified).usageMessages.isEmpty, unified)
        }
        let failedBot = try XCTUnwrap(CursorUsageProvider.parseUsage(primary, configuration: cursor, fetchedAt: now))
        XCTAssertTrue(failedBot.usageMessages.isEmpty)
    }

    private func parse(_ payload: String) throws -> ProviderUsageResult {
        try GrokUsageProvider.parseXSubscription(Data(payload.utf8), configuration: account, subject: "verified-user", now: now)
    }
}

final class XSubscriptionAccountTests: XCTestCase {
    @MainActor
    func testAccountsShareXAICredentialRulesAndNeutralGeneratedLabels() throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults, secretStore: GrokTestSecrets(), widgetSnapshotDefaults: defaults
        )
        var clearedHistory: [String] = []
        let subscription = store.grokHistoryInvalidations.sink { clearedHistory.append($0) }
        defer { subscription.cancel() }
        let first = try XCTUnwrap(store.addAccount(for: .xSubscription))
        let second = try XCTUnwrap(store.addAccount(for: .xSubscription))
        XCTAssertEqual(first.accountLabel, "X Subscription 1")
        XCTAssertEqual(first.grokGeneratedLabel, first.accountLabel)
        XCTAssertFalse(store.isConfigured(first))
        XCTAssertTrue(store.canReconnectGrok(credential("one"), accountID: first.id))
        XCTAssertTrue(store.replaceCredential(try credential("one").encoded(), for: first))
        XCTAssertTrue(store.replaceCredential(try credential("two").encoded(), for: second))
        XCTAssertTrue(store.isConfigured(first))
        XCTAssertFalse(store.canReconnectGrok(credential("two"), accountID: first.id))
        XCTAssertTrue(clearedHistory.isEmpty)
        func result(_ account: ProviderAccountConfiguration, subject: String, plan: String?) throws -> ProviderUsageResult {
            try GrokUsageProvider.parseXSubscription(
                Data(#"{"config":{}}"#.utf8), configuration: account, subject: subject, now: Date(), verifiedPlanName: plan
            )
        }
        XCTAssertFalse(store.applyVerifiedGrokPlan(try result(first, subject: "two", plan: "Premium")))
        XCTAssertTrue(store.applyVerifiedGrokPlan(try result(first, subject: "one", plan: "Premium")))
        XCTAssertEqual(store.configuration(accountID: first.id)?.accountLabel, "X Subscription")
        XCTAssertTrue(store.applyVerifiedGrokPlan(try result(second, subject: "two", plan: nil)))
        XCTAssertEqual(store.configuration(accountID: second.id)?.accountLabel, "X Subscription 2")
        var custom = try XCTUnwrap(store.configuration(accountID: first.id))
        custom.accountLabel = "Family plan"
        XCTAssertTrue(store.update(custom))
        XCTAssertFalse(store.applyVerifiedGrokPlan(try result(custom, subject: "one", plan: "Ultra")))
        XCTAssertEqual(store.configuration(accountID: first.id)?.accountLabel, "Family plan")
        XCTAssertTrue(store.replaceCredential(try credential("three").encoded(), for: custom))
        XCTAssertEqual(clearedHistory, [first.id])
        XCTAssertTrue(store.removeAccount(second))
        XCTAssertEqual(clearedHistory, [first.id, second.id])
        XCTAssertTrue(store.resetAccounts())
        XCTAssertEqual(clearedHistory, [first.id, second.id, first.id])
    }

    @MainActor
    func testWidgetAndWatchShowThePoolOnceWithoutProductRows() throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults, secretStore: GrokTestSecrets(), widgetSnapshotDefaults: defaults
        )
        let account = try XCTUnwrap(store.addAccount(for: .xSubscription))
        XCTAssertTrue(store.replaceCredential(try credential("one").encoded(), for: account))
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let start = formatter.string(from: now.addingTimeInterval(-86_400))
        let end = formatter.string(from: now.addingTimeInterval(86_400))
        let result = try GrokUsageProvider.parseXSubscription(
            Data("""
                {"config":{"creditUsagePercent":38,"prepaidBalance":{"val":1250},
                "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"\(start)","end":"\(end)"},
                "productUsage":[{"product":"PRODUCT_CURSOR","usagePercent":21},{"product":"PRODUCT_GROK_BOT","usagePercent":5}]}}
                """.utf8),
            configuration: account, subject: "one", now: now, verifiedPlanName: "Premium"
        )
        WidgetSnapshotPublisher.publish(results: [result], configurationStore: store,
            access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil), snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil))
        let widget = try XCTUnwrap(WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first)
        XCTAssertEqual(widget.providerID, ProviderID.xSubscription.rawValue)
        XCTAssertEqual(widget.bars.compactMap(\.metricID), [XSubscriptionCopy.poolMetricID])
        XCTAssertEqual(try XCTUnwrap(widget.bars.first?.fractionUsed), 0.38, accuracy: 0.0001)
        let watch = try XCTUnwrap(WatchSnapshotPublisher.makeSnapshot(results: [result], configurationStore: store,
            access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil)).accounts.first)
        XCTAssertEqual(watch.providerName, "X Subscription")
        XCTAssertEqual(
            watch.metrics.map(\.id), [XSubscriptionCopy.poolMetricID, "xSubscription.monetary.balance.usd"],
            "One pool and the credits; product shares never become Watch metrics"
        )
    }

    @MainActor
    func testGrokPlanResultCannotRenameAnXSubscriptionAccount() throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults, secretStore: GrokTestSecrets(), widgetSnapshotDefaults: defaults
        )
        let account = try XCTUnwrap(store.addAccount(for: .xSubscription))
        XCTAssertTrue(store.replaceCredential(try credential("one").encoded(), for: account))
        let grokResult = try GrokUsageProvider.parseCredits(
            Data(#"{"config":{}}"#.utf8), configuration: account, subject: "one", now: Date()
        )
        XCTAssertFalse(store.applyVerifiedGrokPlan(grokResult))
        XCTAssertFalse(store.hasSubscriptionBillingSession(for: account))
    }

    private func credential(_ subject: String) -> GrokCredential {
        GrokCredential(
            kind: "grok-oauth-v1", accessToken: "fixture-token", refreshToken: "fixture-refresh",
            expiresAt: Date().addingTimeInterval(3600), subject: subject, email: nil
        )
    }
}
