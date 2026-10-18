import Foundation
import XCTest
@testable import CodexBarIOS

final class CursorSpendingRegressionTests: XCTestCase, @unchecked Sendable {
    func testPartialCursorResponseKeepsFourCustomizationChoicesWithoutInventingValues() throws {
        // Existing DashboardService response shape. Optional Bot request supplied no response.
        let data = Data(#"{"planUsage":{"autoPercentUsed":0,"apiPercentUsed":0}}"#.utf8)
        let account = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)
        let result = try XCTUnwrap(CursorUsageProvider.parseUsage(data, configuration: account))
        XCTAssertEqual(result.bars.map(\.stableKey), ["cursor-models", "other-models"])
        XCTAssertEqual(Set(result.configurableMetrics.map(\.id)), [
            "cursor.cursor-models", "cursor.other-models", "cursor.grok-bot-weekly", "cursor.on-demand",
        ])
        for id in ["cursor.grok-bot-weekly", "cursor.on-demand"] {
            guard case .unavailableUsage = result.configurableMetrics.first(where: { $0.id == id })?.kind else {
                return XCTFail("Missing metric must have an unavailable state, not disappear: \(id)")
            }
        }
    }

    func testReportedOnDemandSpendWinsOverClampedOrMissingRemaining() throws {
        // Cursor 3.22.7's first-party bundled client reads individualUsed, not limit - remaining.
        for remaining in ["", #","individualRemaining":0"#, #","individualRemaining":-3"#] {
            let data = Data(#"{"planUsage":{"autoPercentUsed":0,"apiPercentUsed":0},"spendLimitUsage":{"individualLimit":2000,"individualUsed":2003\#(remaining)}}"#.utf8)
            let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
                data, configuration: .defaultConfiguration(for: .cursor)
            ))
            let spend = try XCTUnwrap(result.bars.first { $0.stableKey == "on-demand" })
            XCTAssertEqual(spend.used, 2003)
            XCTAssertEqual(spend.limit, 2000)
            XCTAssertTrue(spend.label.contains(try currency(2003)))
        }
    }

    func testGrokInferredZeroIsLabeledAndPresentEmptyCreditsMeanProtoZero() throws {
        let data = Data(#"""
            {"config":{"isUnifiedBillingUser":true,
            "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-09-21T00:00:00Z",
            "end":"2026-09-28T00:00:00Z"},"prepaidBalance":{}}}
            """#.utf8)
        let result = try GrokUsageProvider.parseCredits(
            data, configuration: .defaultConfiguration(for: .grok), subject: "fixture-consumer",
            now: ISO8601DateFormatter().date(from: "2026-09-23T12:00:00Z")!, verifiedPlanName: "SuperGrok Lite"
        )
        XCTAssertEqual(result.bars.first?.used, 0)
        XCTAssertTrue(result.bars.first?.label.localizedCaseInsensitiveContains("inferred") == true)
        XCTAssertEqual(result.monetaryMetrics.first?.minorUnits, 0)
        XCTAssertFalse(result.usageMessages.isEmpty)
    }

    func testMalformedOptionalSpendCannotErasePrimaryUsageOrBecomeZero() throws {
        let cases: [Any] = [
            NSNull(), "malformed",
            ["individualLimit": 2000, "individualUsed": "bad", "individualRemaining": 0],
            ["individualLimit": 2000, "individualUsed": -1, "individualRemaining": 0],
            ["individualLimit": 0, "individualUsed": 120],
            ["individualUsed": 120],
        ]
        for spending in cases {
            let result = try currentResult(spending: spending)
            XCTAssertEqual(result.bars.map(\.stableKey), ["cursor-models", "other-models"])
            XCTAssertEqual(result.configurableMetrics.count, 4)
            XCTAssertEqual(result.bars.map(\.used), [0, 0])
        }
        let noCap = try currentResult(spending: ["individualUsed": 120])
        XCTAssertEqual(noCap.unavailableUsageMetrics["cursor.on-demand"], "Spend \(try currency(120)); cap not reported")
        let noAllowance = try currentResult(spending: ["individualLimit": 0, "individualUsed": 120])
        XCTAssertEqual(noAllowance.unavailableUsageMetrics["cursor.on-demand"], "Spend \(try currency(120)); no spending allowance")
        let disabled = try currentResult(
            spending: ["individualUsed": 120], weekly: #"{"onDemandSettings":{"enabled":false}}"#
        )
        XCTAssertEqual(disabled.unavailableUsageMetrics["cursor.on-demand"], "Spend \(try currency(120)); disabled")
        let disabledCapped = try currentResult(
            spending: ["individualLimit": 2000, "individualUsed": 120],
            weekly: #"{"onDemandSettings":{"enabled":false}}"#
        )
        XCTAssertEqual(disabledCapped.bars.map(\.stableKey), ["cursor-models", "other-models"])
        XCTAssertEqual(disabledCapped.unavailableUsageMetrics["cursor.on-demand"], "Spend \(try currency(120)); disabled")
        let invalidCap = try currentResult(spending: ["individualLimit": -1, "individualUsed": 120])
        XCTAssertEqual(invalidCap.unavailableUsageMetrics["cursor.on-demand"], "Spend \(try currency(120)); invalid spending cap")
        for cap in [nil, -1, 0, 2000] as [Int?] {
            for enabled in [nil, false, true] as [Bool?] {
                var spending = ["individualUsed": 120]
                spending["individualLimit"] = cap
                let weekly = enabled.map { "{\"onDemandSettings\":{\"enabled\":\($0)}}" }
                let spendOnly = try currentResult(spending: spending, weekly: weekly, includesPlan: false)
                if enabled != false && cap == 2000 {
                    XCTAssertEqual(spendOnly.bars.map(\.used), [120])
                } else {
                    XCTAssertTrue(spendOnly.bars.isEmpty)
                    let reason = try XCTUnwrap(spendOnly.unavailableUsageMetrics["cursor.on-demand"])
                    XCTAssertTrue(reason.contains(try currency(120)))
                    XCTAssertFalse(reason.contains("spend not reported"))
                }
                XCTAssertEqual(GoogleUsageMetricCatalog.metrics(for: .cursor, result: spendOnly).count, 4)
            }
        }
        XCTAssertNil(CursorUsageProvider.parseUsage(
            Data(#"{"spendLimitUsage":{"individualLimit":-1,"individualRemaining":-120}}"#.utf8),
            configuration: .defaultConfiguration(for: .cursor)
        ))
        XCTAssertNil(CursorUsageProvider.parseUsage(
            Data(#"{"planUsage":"malformed","spendLimitUsage":{"individualLimit":2000,"individualUsed":120}}"#.utf8),
            configuration: .defaultConfiguration(for: .cursor)
        ))
    }

    func testLegacyRemainingAndExplicitWeeklyEligibilityRetainTheirMeaning() throws {
        let result = try currentResult(spending: ["individualLimit": 2000, "individualRemaining": -3])
        XCTAssertEqual(result.bars.last?.used, 2003)
        for (weekly, reason) in [
            (#"{"hasNonZeroIncludedLimit":false,"usagePercent":0}"#, "No included allowance"),
            (#"{"usesPooledEnterpriseAllowance":true,"usagePercent":0}"#, "Team-managed allowance"),
            ("{malformed", "Invalid optional response"),
        ] {
            let unavailable = try currentResult(weekly: weekly)
            XCTAssertEqual(unavailable.bars.map(\.stableKey), ["cursor-models", "other-models"])
            XCTAssertEqual(unavailable.unavailableUsageMetrics["cursor.grok-bot-weekly"], reason)
        }
        let disabled = try currentResult(weekly: #"{"onDemandSettings":{"enabled":false}}"#)
        XCTAssertEqual(disabled.unavailableUsageMetrics["cursor.on-demand"], "Disabled")
    }

    func testGrokMissingNullAndMalformedMoneyNeverBecomeMeasuredZero() throws {
        for amount in [NSNull(), ["val": NSNull()], ["unexpected": 0], ["val": "bad"], "malformed"] as [Any] {
            let config: [String: Any] = [
                "isUnifiedBillingUser": true, "creditUsagePercent": 31, "prepaidBalance": amount,
                "currentPeriod": [
                    "type": "USAGE_PERIOD_TYPE_WEEKLY", "start": "2026-09-21T00:00:00Z",
                    "end": "2026-09-28T00:00:00Z",
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: ["config": config])
            let result = try GrokUsageProvider.parseCredits(
                data, configuration: .defaultConfiguration(for: .grok), subject: "fixture-consumer",
                now: ISO8601DateFormatter().date(from: "2026-09-23T12:00:00Z")!
            )
            XCTAssertTrue(result.monetaryMetrics.isEmpty)
            XCTAssertEqual(result.bars.first?.used, 31)
            XCTAssertFalse(result.bars.first?.label.localizedCaseInsensitiveContains("inferred") == true)
        }
        let extended = Data(#"{"config":{"isUnifiedBillingUser":true,"prepaidBalance":{"val":125,"futureMetadata":"ignored"}}}"#.utf8)
        let result = try GrokUsageProvider.parseCredits(
            extended, configuration: .defaultConfiguration(for: .grok), subject: "fixture-consumer", now: Date()
        )
        XCTAssertEqual(result.monetaryMetrics.first?.minorUnits, 125)
    }

    private func currency(_ cents: Double) throws -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return try XCTUnwrap(formatter.string(from: NSNumber(value: cents / 100)))
    }

    private func currentResult(
        spending: Any? = nil, weekly: String? = nil, includesPlan: Bool = true
    ) throws -> ProviderUsageResult {
        var response: [String: Any] = [:]
        if includesPlan { response["planUsage"] = ["autoPercentUsed": 0, "apiPercentUsed": 0] }
        response["spendLimitUsage"] = spending
        return try XCTUnwrap(CursorUsageProvider.parseUsage(
            JSONSerialization.data(withJSONObject: response),
            grokBotUsageData: weekly.map { Data($0.utf8) }, configuration: .defaultConfiguration(for: .cursor)
        ))
    }

    @MainActor
    func testNewChoicesDefaultVisibleAndDeliberatePreferencesSurviveReload() throws {
        let suite = "CursorSpendingRegressionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = GrokTestSecrets()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        let first = try XCTUnwrap(store.addAccount(for: .cursor))
        let second = try XCTUnwrap(store.addAccount(for: .cursor))
        _ = store.reconcileMetricLayout(accountID: first.id, availableMetricIDs: ["cursor.cursor-models"])
        store.updateMetricVisibility(false, accountID: first.id, metricID: "cursor.cursor-models")
        store.updateMetricVisibility(false, accountID: first.id, metricID: "cursor.grok-bot-weekly")
        store.updateMetricWidth(.half, accountID: first.id, metricID: "cursor.on-demand")
        let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
            Data(#"{"planUsage":{"autoPercentUsed":0,"apiPercentUsed":0}}"#.utf8), configuration: first
        ))
        _ = store.reconcileMetricLayout(accountID: first.id, availableMetricIDs: result.configurableMetrics.map(\.id))
        let restored = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        XCTAssertFalse(restored.isMetricVisible(accountID: first.id, metricID: "cursor.cursor-models"))
        XCTAssertFalse(restored.isMetricVisible(accountID: first.id, metricID: "cursor.grok-bot-weekly"))
        XCTAssertTrue(restored.isMetricVisible(accountID: first.id, metricID: "cursor.on-demand"))
        XCTAssertEqual(restored.metricWidth(accountID: first.id, metricID: "cursor.on-demand"), .half)
        XCTAssertTrue(restored.isMetricVisible(accountID: second.id, metricID: "cursor.grok-bot-weekly"))
        XCTAssertEqual(restored.metricWidth(accountID: second.id, metricID: "cursor.on-demand"), .automatic)
    }
}
