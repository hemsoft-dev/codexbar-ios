import Foundation
import XCTest
@testable import CodexBarIOS

final class GrokUsageTests: XCTestCase, @unchecked Sendable {
    private let now = ISO8601DateFormatter().date(from: "2026-09-23T12:00:00Z")!
    private let account = ProviderAccountConfiguration.defaultConfiguration(for: .grok)

    func testWeeklyUsageZeroAndFinancialValuesStaySeparate() throws {
        let result = try parse(#"""
            {"config":{"isUnifiedBillingUser":true,"creditUsagePercent":0,
            "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-09-21T00:00:00Z",
            "end":"2026-09-28T00:00:00Z"},"billingPeriodEnd":"2026-10-01T00:00:00Z",
            "prepaidBalance":{"val":0},"onDemandUsed":{"val":210},"onDemandCap":{"val":500},
            "productUsage":[{"product":"GrokBuild","usagePercent":0}]}}
            """#)
        XCTAssertEqual(result.bars.count, 1)
        XCTAssertEqual(result.bars.first?.used, 0)
        XCTAssertEqual(result.bars.first?.stableKey, "included-usage")
        XCTAssertEqual(result.bars.first?.resetsAt, ISO8601DateFormatter().date(from: "2026-09-28T00:00:00Z"))
        XCTAssertEqual(result.monetaryMetrics.map(\.minorUnits), [0])
        XCTAssertEqual(result.cardInformationSections.first?.id, "grok.consumer-source")
        XCTAssertEqual(result.cacheScope?.hasPrefix("consumer."), true)
    }

    func testMonthlyOrUnverifiedBillingIsNotAWeeklySubscriptionMeter() throws {
        let monthly = try parse(payload(percent: 23, period: "USAGE_PERIOD_TYPE_MONTHLY"))
        let unknown = try parse(#"{"config":{"creditUsagePercent":23,"prepaidBalance":{"val":200}}}"#)
        XCTAssertTrue(monthly.bars.isEmpty)
        XCTAssertTrue(unknown.bars.isEmpty)
        XCTAssertTrue(unknown.monetaryMetrics.isEmpty)
    }

    func testPlanNameIsVerifiedMetadataNotAnAdditionalMetric() throws {
        let result = try GrokUsageProvider.parseCredits(
            Data(payload(percent: 0, period: "USAGE_PERIOD_TYPE_WEEKLY").utf8),
            configuration: account, subject: "verified-user", now: now, verifiedPlanName: "SuperGrok Lite"
        )
        XCTAssertEqual(result.verifiedGrokPlanName, "SuperGrok Lite")
        XCTAssertEqual(result.bars.count, 1)
        XCTAssertTrue(result.monetaryMetrics.isEmpty)
    }

    func testOmittedUsageNeverInventsAZeroPercentage() throws {
        let data = Data(#"""
            {"config":{"isUnifiedBillingUser":true,
            "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-09-21T00:00:00Z",
            "end":"2026-09-28T00:00:00Z"},"prepaidBalance":{"val":500}}}
            """#.utf8)
        let result = try GrokUsageProvider.parseCredits(
            data, configuration: account, subject: "verified-user", now: now,
            verifiedPlanName: "SuperGrok Lite"
        )
        XCTAssertEqual(result.verifiedGrokPlanName, "SuperGrok Lite")
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertFalse(result.usageMessages.isEmpty)
        XCTAssertEqual(result.monetaryMetrics.map(\.minorUnits), [500])
        let unknownTier = try GrokUsageProvider.parseCredits(
            data, configuration: account, subject: "verified-user", now: now
        )
        XCTAssertTrue(unknownTier.bars.isEmpty)
        let free = try GrokUsageProvider.parseCredits(
            data, configuration: account, subject: "verified-user", now: now, verifiedPlanName: "Free"
        )
        XCTAssertTrue(free.bars.isEmpty)
        let other = try GrokUsageProvider.parseCredits(
            data, configuration: account, subject: "another-user", now: now, verifiedPlanName: "SuperGrok Lite"
        )
        XCTAssertNotEqual(result.cacheIdentity, other.cacheIdentity)
    }

    func testOmittedPercentWithOtherUsageOrNullStaysUnavailable() throws {
        let extras = [
            #""productUsage":[],"#,
            #""used":{"val":0},"#,
            #""creditUsagePercent":null,"#,
            #""creditUsagePercent":-1,"#,
        ]
        for extra in extras {
            let data = Data(#"""
                {"config":{"isUnifiedBillingUser":true,\#(extra)
                "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-09-21T00:00:00Z",
                "end":"2026-09-28T00:00:00Z"}}}
                """#.utf8)
            let result = try GrokUsageProvider.parseCredits(
                data, configuration: account, subject: "verified-user", now: now,
                verifiedPlanName: "SuperGrok Lite"
            )
            XCTAssertTrue(result.bars.isEmpty, extra)
        }
    }

    func testMissingMalformedOrUnpaidAllowanceNeverBecomesZeroPercent() throws {
        for percent in ["null", "-1", "\"bad\""] {
            let payload = payload(percent: percent, period: "USAGE_PERIOD_TYPE_WEEKLY")
            if let result = try? parse(payload) { XCTAssertTrue(result.bars.isEmpty) }
        }
        let free = try parse(payload(percent: "0", period: "USAGE_PERIOD_TYPE_WEEKLY", unified: false))
        XCTAssertTrue(free.bars.isEmpty)
        let unknown = try parse(payload(percent: "0", period: "USAGE_PERIOD_TYPE_UNSPECIFIED"))
        XCTAssertTrue(unknown.bars.isEmpty)
        XCTAssertThrowsError(try parse(#"{"config":null}"#))
    }

    func testCacheBelongsToVerifiedSubjectNotTokenOrLabel() throws {
        let data = Data(payload(percent: 11, period: "USAGE_PERIOD_TYPE_WEEKLY").utf8)
        let first = try GrokUsageProvider.parseCredits(data, configuration: account, subject: "user-a", now: now)
        let refreshed = try GrokUsageProvider.parseCredits(data, configuration: account, subject: "user-a", now: now)
        let other = try GrokUsageProvider.parseCredits(data, configuration: account, subject: "user-b", now: now)
        XCTAssertEqual(first.cacheIdentity, refreshed.cacheIdentity)
        XCTAssertNotEqual(first.cacheIdentity, other.cacheIdentity)
    }

    func testDeviceApprovalURLRejectsCrossOriginOrDowngrade() {
        XCTAssertNotNil(GrokDeviceAuthService.approvalURL("https://accounts.x.ai/oauth2/device?user_code=TEST"))
        XCTAssertNil(GrokDeviceAuthService.approvalURL("http://accounts.x.ai/oauth2/device"))
        XCTAssertNil(GrokDeviceAuthService.approvalURL("https://accounts.x.ai.evil.invalid/oauth2/device"))
        XCTAssertNil(GrokDeviceAuthService.approvalURL("https://user@accounts.x.ai/oauth2/device"))
    }

    func testTokenRequiresBearerAndAllowsUnrotatedRefresh() throws {
        let nonBearer = Data(#"{"access_token":"abc","refresh_token":"renew","token_type":"Basic","expires_in":3600}"#.utf8)
        XCTAssertThrowsError(try GrokDeviceAuthService.token(nonBearer))
        let token = try GrokDeviceAuthService.token(Data(#"{"access_token":"abc","token_type":"Bearer","expires_in":3600}"#.utf8))
        XCTAssertNil(token.refreshToken)
    }

    private func parse(_ payload: String) throws -> ProviderUsageResult {
        try GrokUsageProvider.parseCredits(Data(payload.utf8), configuration: account, subject: "verified-user", now: now)
    }

    private func payload(percent: Int, period: String) -> String {
        payload(percent: String(percent), period: period)
    }

    private func payload(percent: String, period: String, unified: Bool = true) -> String {
        #"{"config":{"isUnifiedBillingUser":\#(unified),"creditUsagePercent":\#(percent),"currentPeriod":{"type":"\#(period)","start":"2026-09-21T00:00:00Z","end":"2026-09-28T00:00:00Z"}}}"#
    }
}
