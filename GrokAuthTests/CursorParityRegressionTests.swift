import Foundation
import XCTest
@testable import CodexBarIOS

final class CursorParityRegressionTests: XCTestCase, @unchecked Sendable {
    func testIncludedPercentDisplayMatchesCursorWithoutChangingMeasuredValues() throws {
        let cases: [(Double, String)] = [
            (0, "0%"), (.leastNonzeroMagnitude, "1%"), (0.1, "1%"), (0.49, "1%"),
            (0.5, "1%"), (0.99, "1%"), (1, "1%"), (3, "3%"), (135, "135%"),
        ]
        for (percent, expected) in cases {
            let data = Data("{\"planUsage\":{\"autoPercentUsed\":\(percent),\"apiPercentUsed\":3}}".utf8)
            let result = try XCTUnwrap(CursorUsageProvider.parseUsage(data, configuration: .defaultConfiguration(for: .cursor)))
            let bar = try XCTUnwrap(result.bars.first)
            XCTAssertEqual(bar.used, percent)
            XCTAssertEqual(bar.usageText, expected)
            XCTAssertEqual(result.bars.last?.usageText, "3%")
            XCTAssertEqual(result.cardInformationSections.first?.items.first?.detail, expected)
            XCTAssertEqual(result.usageHistoryBars().first?.used, percent)
        }
        XCTAssertEqual(UsageBar(label: "Another provider", used: 0.1, limit: 100).usageText, "0%")
    }

    func testReloadPolicySelectsFreshOneAndThreeInsteadOfTheCachedZeroResponse() async throws {
        let result = try await replay(optional: "reported")
        XCTAssertEqual(result.bars.prefix(2).map(\.used), [1, 3])
        XCTAssertEqual(result.bars.prefix(2).map(\.usageText), ["1%", "3%"])
        XCTAssertEqual(result.accountID, "cursor-parity-fixture")
    }

    func testDefaultBudgetAcceptsAModeratelyDelayedValidBotResponse() async throws {
        let result = try await replay(optional: "delayed")
        XCTAssertEqual(result.bars.first { $0.stableKey == "grok-bot-weekly" }?.used, 41)
        XCTAssertEqual(result.bars.prefix(2).map(\.used), [1, 3])
        XCTAssertNil(result.failureMessage)
    }

    func testOptionalStatusReasonsPreservePrimaryAndAllChoices() async throws {
        for (mode, fragment) in [
            ("rejected", "session was rejected"), ("forbidden", "did not permit"),
            ("limited", "rate limited"), ("error", "temporarily unavailable"),
            ("timeout", "timed out"),
        ] {
            let result = try await replay(optional: mode)
            XCTAssertEqual(result.bars.map(\.used), [1, 3])
            XCTAssertEqual(result.configurableMetrics.count, 4)
            XCTAssertTrue(result.unavailableUsageMetrics["cursor.grok-bot-weekly"]?.contains(fragment) == true)
            XCTAssertNil(result.failureMessage)
        }
    }

    func testSnakeCaseAndMalformedPrimaryStayDistinctFromReportedZero() throws {
        let snake = Data(#"{"plan_usage":{"auto_percent_used":0.1,"api_percent_used":3}}"#.utf8)
        let result = try XCTUnwrap(CursorUsageProvider.parseUsage(snake, configuration: .defaultConfiguration(for: .cursor)))
        XCTAssertEqual(result.bars.map(\.used), [0.1, 3])
        XCTAssertEqual(result.bars.map(\.usageText), ["1%", "3%"])
        for value in ["null", "true", "\"invalid\"", "1e100"] {
            let data = Data("{\"planUsage\":{\"autoPercentUsed\":\(value),\"apiPercentUsed\":3}}".utf8)
            let missing = try XCTUnwrap(CursorUsageProvider.parseUsage(data, configuration: .defaultConfiguration(for: .cursor)))
            XCTAssertEqual(missing.bars.map(\.used), [3])
            XCTAssertEqual(missing.unavailableUsageMetrics["cursor.cursor-models"], "Not reported")
        }
    }

    private func replay(optional: String) async throws -> ProviderUsageResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CursorParityProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let account = ProviderAccountConfiguration(
            id: "cursor-parity-fixture", providerID: .cursor, accountLabel: "Synthetic Cursor", authMethod: .browserSession
        )
        let secrets = GrokTestSecrets()
        try secrets.saveSecret("synthetic-account-a", account: ProviderConfigurationStore.keychainAccount(for: account))
        let provider = CursorUsageProvider(
            secretStore: secrets, session: session,
            usageEndpoint: URL(string: "https://cursor-parity.invalid/GetCurrentPeriodUsage")!,
            grokBotUsageEndpoint: URL(string: "https://cursor-parity.invalid/\(optional)/GetSandUsageStatus")!
        )
        return try await provider.fetchUsage(for: account)
    }

    @MainActor
    func testWidgetsWatchAndHistoryPreservePrecisionAndDisplayPolicy() throws {
        let suite = "CursorParity.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = GrokTestSecrets()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        let account = ProviderAccountConfiguration(
            id: "cursor-widget-fixture", providerID: .cursor, accountLabel: "Synthetic Cursor", authMethod: .browserSession
        )
        _ = store.update(account)
        XCTAssertTrue(store.saveSecret("synthetic-account-a", for: account))
        let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
            Data(#"{"planUsage":{"autoPercentUsed":0.1,"apiPercentUsed":3}}"#.utf8), configuration: account
        ))
        WidgetSnapshotPublisher.publish(results: [result], configurationStore: store,
            access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil), snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil))
        let widget = try XCTUnwrap(WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first?.bars.first)
        XCTAssertEqual(widget.usageText, "1%")
        XCTAssertEqual(widget.fractionUsed, 0.001, accuracy: 0.000_001)
        let watch = WatchSnapshotPublisher.makeSnapshot(results: [result], configurationStore: store,
            access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil))
        let metric = try XCTUnwrap(watch.accounts.first?.metrics.first)
        XCTAssertEqual(metric.exactValue, "1%")
        XCTAssertEqual(try XCTUnwrap(metric.usedFraction), 0.001, accuracy: 0.000_001)
        XCTAssertEqual(result.usageHistoryBars().first?.used, 0.1)
    }

    func testRequestsCannotReplayCachedZerosOrAttachAnotherAccountCookie() {
        let provider = CursorUsageProvider(secretStore: GrokTestSecrets())
        let request = provider.makeUsageRequest(accessToken: "synthetic-account-a")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-account-a")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }
}
