import Foundation
import XCTest
@testable import CodexBarIOS

final class AntigravityQuotaParserTests: XCTestCase, @unchecked Sendable {
    private let now = AntigravityFixtures.now
    private let account = AntigravityFixtures.configuration()

    private func result(_ quotaBody: String, profile: String? = nil) throws -> ProviderUsageResult {
        try AntigravityQuotaParser.result(
            from: AntigravityPageCapture(quotaBody: quotaBody, profileBody: profile), configuration: account, fetchedAt: now
        )
    }

    private func bar(_ key: String, in result: ProviderUsageResult) -> UsageBar? {
        result.bars.first { $0.stableKey == key }
    }

    func testFourMetersShowWholePercentUsedInGooglesOrderWithResetTimes() throws {
        let result = try result(AntigravityFixtures.screenshotQuotaBody, profile: AntigravityFixtures.profileBody)

        XCTAssertEqual(result.bars.map(\.stableKey), ["gemini-weekly", "gemini-5h", "3p-weekly", "3p-5h"])
        XCTAssertEqual(result.bars.map(\.label), [
            "Gemini Models weekly", "Gemini Models five-hour", "Claude and GPT Models weekly", "Claude and GPT Models five-hour",
        ])
        // Google's page shows 97%, 91%, 100% and 100% remaining for these fractions.
        XCTAssertEqual(result.bars.map(\.used), [3, 9, 0, 0])
        XCTAssertEqual(result.bars.map(\.limit), [100, 100, 100, 100])
        XCTAssertEqual(bar("gemini-weekly", in: result)?.resetsAt, AntigravityFixtures.weeklyReset)
        XCTAssertEqual(bar("gemini-5h", in: result)?.resetsAt, AntigravityFixtures.fiveHourReset)
        XCTAssertNil(bar("3p-weekly", in: result)?.resetsAt, "an untouched pool has no refresh time")
        XCTAssertTrue(result.unavailableUsageMetrics.isEmpty)
        XCTAssertNil(result.failureMessage)
        for bar in result.bars {
            XCTAssertNil(bar.projectionDescriptionParts(at: now), "no pace forecast: Google doesn't report when a window began")
        }
        XCTAssertEqual(result.highestSeverity(at: now), .normal)
        XCTAssertEqual(result.providerID, .antigravityWeb)
        XCTAssertEqual(result.title, "Work Google")
        XCTAssertEqual(result.fetchedAt, now)
    }

    func testResponseCapturedOnTheOwnersPhoneReadsAsGooglesPageShowedIt() throws {
        // Google's page showed 93%, 100%, 100% and 100% remaining, and a refresh time for the used pool only.
        let result = try AntigravityQuotaParser.result(
            from: AntigravityPageCapture(quotaBody: AntigravityFixtures.liveQuotaBody), configuration: account,
            fetchedAt: AntigravityFixtures.liveCaptureDate
        )
        XCTAssertEqual(result.bars.map(\.stableKey), ["gemini-weekly", "gemini-5h", "3p-weekly", "3p-5h"])
        XCTAssertEqual(result.bars.map(\.used), [7, 0, 0, 0])
        XCTAssertEqual(bar("gemini-weekly", in: result)?.resetsAt, Date(timeIntervalSince1970: 1_796_073_749))
        for key in ["gemini-5h", "3p-weekly", "3p-5h"] {
            XCTAssertNil(bar(key, in: result)?.resetsAt, "\(key): Google sends a reset time for an untouched pool but its page shows none")
        }
        XCTAssertTrue(result.unavailableUsageMetrics.isEmpty)
        XCTAssertTrue(result.usageMessages.isEmpty)
        XCTAssertNil(result.failureMessage)
        XCTAssertTrue(AntigravityCaptureProgress.isReadable(AntigravityFixtures.liveQuotaBody))

        let buckets = try AntigravityQuotaParser.buckets(fromQuotaBody: AntigravityFixtures.liveQuotaBody)
        XCTAssertEqual(buckets.map(\.groupName), ["Gemini Models", "Gemini Models", "Claude and GPT models", "Claude and GPT models"])
        XCTAssertEqual(buckets.map(\.hasDescription), [true, false, false, false])
        XCTAssertFalse(buckets.contains { $0.isMalformed || $0.isDisabled })
    }

    func testUsedPoolWithoutGooglesDescriptionStillShowsItsReset() throws {
        let body = #"[[[null,[[[["gemini-weekly","Weekly Limit Remaining","weekly",0.5,null,["1796073749"]]],"Gemini Models"]]]]]"#
        let result = try AntigravityQuotaParser.result(
            from: AntigravityPageCapture(quotaBody: body), configuration: account, fetchedAt: AntigravityFixtures.liveCaptureDate
        )
        XCTAssertEqual(bar("gemini-weekly", in: result)?.resetsAt, Date(timeIntervalSince1970: 1_796_073_749))
    }

    func testPercentUsedIsOneHundredMinusThePagesRoundedRemaining() {
        // The page computes Math.round(fraction * 100), which rounds a half up.
        let cases: [(Double, Double)] = [(1, 0), (0.9725, 3), (0.7612, 24), (0.975, 2), (0.985, 1), (0.004, 100), (0.005, 99), (0, 100)]
        for (remaining, used) in cases {
            XCTAssertEqual(AntigravityQuotaParser.percentUsed(remainingFraction: remaining), used, "remaining \(remaining)")
        }
    }

    func testDisabledFiveHourPoolSaysTheWeeklyLimitWasReachedInsteadOfAValue() throws {
        let body = AntigravityFixtures.quotaBody(groups: [
            AntigravityFixtures.group("Gemini Models", [
                AntigravityFixtures.bucket("gemini-weekly", name: "Weekly Limit Remaining", window: "weekly", remaining: 0,
                                           reset: AntigravityFixtures.weeklyReset),
                AntigravityFixtures.bucket("gemini-5h", name: "Five Hour Limit Remaining", window: "5h", remaining: 1,
                                           description: "You have hit your weekly limit", disabled: true),
            ]),
            AntigravityFixtures.group("Claude and GPT models", [
                AntigravityFixtures.bucket("3p-weekly", name: "Weekly Limit Remaining", window: "weekly", remaining: 1),
                AntigravityFixtures.bucket("3p-5h", name: "Five Hour Limit Remaining", window: "5h", remaining: 1),
            ]),
        ])
        let result = try result(body)

        XCTAssertNil(bar("gemini-5h", in: result), "a disabled pool is neither 0% nor 100% used")
        XCTAssertEqual(result.unavailableUsageMetrics["antigravityWeb.gemini-5h"], "Weekly limit reached")
        XCTAssertEqual(bar("gemini-weekly", in: result)?.used, 100)
        let metric = result.configurableMetrics.first { $0.id == "antigravityWeb.gemini-5h" }
        XCTAssertEqual(metric?.kind, .unavailableUsage("Weekly limit reached"))
        XCTAssertNil(result.failureMessage)
    }

    func testDisabledFlagInATrailingFieldObjectIsRead() throws {
        // Google's encoding may carry high field numbers in a trailing object keyed by number.
        let body = #"[[[[],[[[["gemini-5h","Five Hour Limit Remaining","5h",1,{"8":true}],"#
            + #"["gemini-weekly","Weekly Limit Remaining","weekly",0.5]],"Gemini Models"]]]]]"#
        let result = try result(body)
        XCTAssertEqual(result.unavailableUsageMetrics["antigravityWeb.gemini-5h"], "Weekly limit reached")
        XCTAssertEqual(bar("gemini-weekly", in: result)?.used, 50)
    }

    func testMissingAndMalformedPoolsAreUnavailableAndNeverInvented() throws {
        let body = AntigravityFixtures.quotaBody(groups: [
            AntigravityFixtures.group("Gemini Models", [
                AntigravityFixtures.bucket("gemini-weekly", name: "Weekly", window: "weekly", remaining: "plenty"),
                AntigravityFixtures.bucket("gemini-5h", name: "Five hour", window: "5h", remaining: 1.4),
            ]),
            AntigravityFixtures.group("Claude and GPT models", [
                AntigravityFixtures.bucket("3p-weekly", name: "Weekly", window: "weekly", remaining: 0.25),
                // No fraction at all, and a window that contradicts the identifier.
                AntigravityFixtures.bucket("3p-5h", name: "Five hour", window: "weekly", remaining: 0.5),
            ]),
        ])
        let result = try result(body)

        XCTAssertEqual(result.bars.map(\.stableKey), ["3p-weekly"])
        XCTAssertEqual(result.bars.first?.used, 75)
        for key in ["gemini-weekly", "gemini-5h", "3p-5h"] {
            XCTAssertEqual(result.unavailableUsageMetrics["antigravityWeb.\(key)"], "Unavailable", key)
        }
        XCTAssertEqual(result.usageMessages, [
            "Google's page didn't report: Gemini Models weekly, Gemini Models five-hour, Claude and GPT Models five-hour.",
        ])
        XCTAssertNil(result.failureMessage, "one readable pool is still a reading")
    }

    func testPoolWithoutAFractionIsUnavailable() throws {
        let body = AntigravityFixtures.quotaBody(groups: [
            AntigravityFixtures.group("Gemini Models", [
                AntigravityFixtures.bucket("gemini-weekly", name: "Weekly", window: "weekly"),
                AntigravityFixtures.bucket("gemini-5h", name: "Five hour", window: "5h", remaining: 0.5),
            ]),
        ])
        let result = try result(body)
        XCTAssertEqual(result.unavailableUsageMetrics["antigravityWeb.gemini-weekly"], "Unavailable")
        XCTAssertEqual(bar("gemini-5h", in: result)?.used, 50)
    }

    func testDuplicateIdentifiersShowNeitherValue() throws {
        let body = AntigravityFixtures.quotaBody(groups: [
            AntigravityFixtures.group("Gemini Models", [
                AntigravityFixtures.bucket("gemini-weekly", name: "Weekly", window: "weekly", remaining: 0.2),
                AntigravityFixtures.bucket("gemini-weekly", name: "Weekly", window: "weekly", remaining: 0.9),
                AntigravityFixtures.bucket("gemini-5h", name: "Five hour", window: "5h", remaining: 0.5),
            ]),
        ])
        let result = try result(body)
        XCTAssertNil(bar("gemini-weekly", in: result))
        XCTAssertEqual(result.unavailableUsageMetrics["antigravityWeb.gemini-weekly"], "Unavailable")
    }

    func testExtraPoolIsItsOwnMetricAndUnknownShapesDoNotFailTheRead() throws {
        let body = AntigravityFixtures.quotaBody(
            groups: [
                AntigravityFixtures.group("Gemini Models", [
                    AntigravityFixtures.bucket("gemini-weekly", name: "Weekly Limit Remaining", window: "weekly", remaining: 0.9),
                    AntigravityFixtures.bucket("gemini-5h", name: "Five Hour Limit Remaining", window: "5h", remaining: 0.8),
                    AntigravityFixtures.bucket("gemini-argon-wtu-weekly", name: "Argon Weekly Limit Remaining", window: "weekly",
                                               remaining: 0.4, reset: AntigravityFixtures.weeklyReset),
                    AntigravityFixtures.bucket("Odd ID.gemini", name: "Odd", window: "30d", remaining: 0.1),
                    ["not", "a", "bucket", "shape", 5, 6, 7, 8, 9],
                ]),
                AntigravityFixtures.group("Claude and GPT models", [
                    AntigravityFixtures.bucket("3p-weekly", name: "Weekly Limit Remaining", window: "weekly", remaining: 1),
                    AntigravityFixtures.bucket("3p-5h", name: "Five Hour Limit Remaining", window: "5h", remaining: 1),
                ]),
                ["a group that is not a group"],
            ],
            looseBuckets: [AntigravityFixtures.bucket("credits-1d", name: "Daily pool", window: "1d", remaining: 0.3)]
        )
        let result = try result(body)

        XCTAssertEqual(result.bars.map(\.stableKey), [
            "gemini-weekly", "gemini-5h", "3p-weekly", "3p-5h", "extra-credits-1d", "extra-gemini-argon-wtu-weekly",
        ])
        XCTAssertEqual(bar("extra-gemini-argon-wtu-weekly", in: result)?.label, "Gemini Models Argon Weekly Limit")
        XCTAssertEqual(bar("extra-gemini-argon-wtu-weekly", in: result)?.used, 60)
        XCTAssertEqual(bar("extra-credits-1d", in: result)?.label, "Daily pool")
        XCTAssertEqual(bar("gemini-weekly", in: result)?.used, 10, "an extra pool never replaces one of the four")
        XCTAssertEqual(result.configurableMetrics.map(\.id).prefix(4), [
            "antigravityWeb.gemini-weekly", "antigravityWeb.gemini-5h", "antigravityWeb.3p-weekly", "antigravityWeb.3p-5h",
        ])
        for metric in result.configurableMetrics {
            XCTAssertFalse(RetiredProviderMigration.isRetiredIdentifier(metric.id), metric.id)
        }
    }

    func testResetAlreadyPastIsNotShown() throws {
        let body = AntigravityFixtures.quotaBody(groups: [
            AntigravityFixtures.group("Gemini Models", [
                AntigravityFixtures.bucket("gemini-weekly", name: "Weekly", window: "weekly", remaining: 0.5,
                                           reset: now.addingTimeInterval(-30)),
            ]),
        ])
        let result = try result(body)
        XCTAssertEqual(bar("gemini-weekly", in: result)?.used, 50)
        XCTAssertNil(bar("gemini-weekly", in: result)?.resetsAt)
    }

    func testResponseGuardPrefixAndNamedJSONAreRead() throws {
        let guarded = ")]}'\n" + AntigravityFixtures.screenshotQuotaBody
        XCTAssertEqual(try result(guarded).bars.map(\.used), [3, 9, 0, 0])

        let named = #"""
            {"summary":{"response":{"groups":[{"displayName":"Gemini Models","buckets":[
            {"bucketId":"gemini-weekly","displayName":"Weekly","window":"weekly","remainingFraction":0.7612,
             "resetTime":"2026-11-30T00:00:00Z"},
            {"bucketId":"gemini-5h","displayName":"Five hour","window":"5h","disabled":true}]}]}}}
            """#
        let result = try result(named)
        XCTAssertEqual(bar("gemini-weekly", in: result)?.used, 24)
        XCTAssertEqual(result.unavailableUsageMetrics["antigravityWeb.gemini-5h"], "Weekly limit reached")
    }

    func testUnrecognizedBodiesThrowInsteadOfReportingUsage() {
        for body in ["", "<html>Sign in</html>", "{}", "[]", "[[]]", #"{"error":{"code":401}}"#, "[1,2,3]"] {
            XCTAssertThrowsError(try result(body), body)
        }
    }

    func testResponseWithNoUsablePoolIsAFailureWithoutValues() throws {
        let body = AntigravityFixtures.quotaBody(groups: [AntigravityFixtures.group("Gemini Models", [])])
        let result = try result(body)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(result.failureMessage, AntigravityReadError.noUsageReported.localizedDescription)
    }

    func testPlanPillShowsOnlyThePlanGooglesPageReported() throws {
        let withPlan = try result(AntigravityFixtures.screenshotQuotaBody, profile: AntigravityFixtures.profileBody)
        XCTAssertEqual(withPlan.plan?.displayLabel, "Google AI Ultra")
        XCTAssertEqual(withPlan.plan?.identifier, "antigravityWeb.g1-ultra-tier")
        XCTAssertTrue(withPlan.showsCardPlan)

        for profile in [nil, AntigravityFixtures.profileWithoutPlanBody, "not json", #"["a@example.com",["id",""]]"#] {
            let withoutPlan = try result(AntigravityFixtures.screenshotQuotaBody, profile: profile)
            XCTAssertNil(withoutPlan.plan)
            XCTAssertFalse(withoutPlan.showsCardPlan, "no pill instead of a placeholder")
        }
        XCTAssertTrue(ProviderID.antigravityWeb.supportsPlanBadge)
    }

    func testProfileEmailNeverReachesTheResult() throws {
        let result = try result(AntigravityFixtures.screenshotQuotaBody, profile: AntigravityFixtures.profileBody)
        let text = String(describing: result)
        XCTAssertFalse(text.contains("person@example.com"))
    }
}
