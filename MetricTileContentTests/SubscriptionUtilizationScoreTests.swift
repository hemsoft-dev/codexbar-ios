import Foundation
import XCTest
@testable import CodexBarIOS

final class SubscriptionUtilizationScoreTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testReferenceFormulaUnderAndOverLimit() {
        // Halfway through a weekly window: 50% lands at 100; 100% locks out half the week.
        for (used, expected) in [(0.0, 0), (40, 80), (50, 100), (75, 67), (100, 50), (120, 50)] {
            XCTAssertEqual(score(used: used, elapsedHours: 84)?.value, expected)
        }
        XCTAssertEqual(score(used: 25, elapsedHours: 84)?.band, .red)
        XCTAssertEqual(score(used: 40, elapsedHours: 84)?.band, .yellow)
        XCTAssertEqual(score(used: 47.5, elapsedHours: 84)?.band, .green)
    }

    func testEarlyResetAndUnsupportedOrExpiredWindowsHaveNoScore() {
        XCTAssertNil(score(used: 80, elapsedHours: 11.99))
        XCTAssertNotNil(score(used: 10, elapsedHours: 12))
        XCTAssertNil(score(used: 20, elapsedHours: 168))
        XCTAssertNil(SubscriptionUtilizationScore(bar: bar(used: 20, hours: 5), at: start.addingTimeInterval(4 * 3_600)))
        XCTAssertNil(SubscriptionUtilizationScore(bar: UsageBar(label: "Weekly", used: 20, limit: 100), at: start))
        XCTAssertNil(score(used: 20, elapsedHours: -1))
        for invalid in [Double.nan, .infinity, -1] { XCTAssertNil(score(used: invalid, elapsedHours: 84)) }
    }

    func testPythonCompatibleRoundingAndBandEdges() {
        XCTAssertEqual(score(used: 40.25, elapsedHours: 84)?.value, 80)
        XCTAssertEqual(score(used: 40.75, elapsedHours: 84)?.value, 82)
        XCTAssertEqual(SubscriptionUtilizationScore(value: 89).band, .yellow)
        XCTAssertEqual(SubscriptionUtilizationScore(value: 90).band, .green)
        XCTAssertEqual(SubscriptionUtilizationScore(value: 74).band, .red)
        XCTAssertEqual(SubscriptionUtilizationScore(value: 75).band, .yellow)
    }

    func testFleetWeightsAndUnknownPriceFallbackMatchReference() {
        func entry(_ score: Int, _ price: Double?) -> SubscriptionUtilizationFleet.Entry {
            .init(score: .init(value: score), monthlyPrice: price)
        }
        XCTAssertNil(SubscriptionUtilizationFleet.score(entries: []))
        XCTAssertEqual(SubscriptionUtilizationFleet.score(entries: [entry(76, 200), entry(48, 200)])?.value, 62)
        XCTAssertEqual(SubscriptionUtilizationFleet.score(entries: [entry(76, 100), entry(48, 300)])?.value, 55)
        XCTAssertEqual(SubscriptionUtilizationFleet.score(entries: [entry(100, 200), entry(0, 19.99)])?.value, 91)
        XCTAssertEqual(SubscriptionUtilizationFleet.score(entries: [entry(100, 200), entry(0, nil)])?.value, 50)
    }

    func testMultiplePoolsChargeSubscriptionOnceAndLiveCodexPlanControlsPrice() throws {
        let instant = start.addingTimeInterval(84 * 3_600)
        let result = ProviderUsageResult(providerID: .antigravity, title: "AG", subtitle: "", bars: [bar(used: 40), bar(used: 50)], fetchedAt: instant)
        let entry = try XCTUnwrap(SubscriptionUtilizationFleet.entry(for: result, at: instant))
        XCTAssertEqual(entry.score.value, 90)
        XCTAssertEqual(entry.monthlyPrice, 19.99)
        let unified = ProviderUsageResult(providerID: .gemini, title: "Gemini", subtitle: "", bars: [bar(used: 40)], fetchedAt: instant)
        XCTAssertEqual(SubscriptionUtilizationFleet.entry(for: unified, at: instant)?.monthlyPrice, 19.99)
        for (plan, price) in [("pro", 200.0), ("prolite", 100.0)] {
            let codex = ProviderUsageResult(providerID: .codex, title: "Codex", plan: .init(identifier: "codex.\(plan)", displayLabel: plan, accessibilityLabel: plan), subtitle: "", bars: [], fetchedAt: instant)
            XCTAssertEqual(SubscriptionUtilizationFleet.monthlyPrice(for: codex), price)
        }
    }

    func testUnavailableStaleAndShortWindowsAreExcludedFromFleet() {
        let instant = start.addingTimeInterval(84 * 3_600)
        let stale = ProviderUsageResult(providerID: .claude, title: "Claude", subtitle: "", bars: [bar(used: 40)],
                                        barsFetchedAt: start, fetchedAt: instant)
        XCTAssertNil(SubscriptionUtilizationFleet.entry(for: stale, at: instant))
        let failed = ProviderUsageResult(providerID: .claude, title: "Claude", subtitle: "", bars: [bar(used: 40)],
                                         failureMessage: "Unavailable", fetchedAt: instant)
        XCTAssertNil(SubscriptionUtilizationFleet.entry(for: failed, at: instant))
        let disabled = ProviderUsageResult(providerID: .claude, title: "Claude", subtitle: "", bars: [bar(used: 40)],
                                           unavailableUsageMetrics: ["claude.weekly": "Disabled"], fetchedAt: instant)
        XCTAssertNil(SubscriptionUtilizationFleet.entry(for: disabled, at: instant))
        XCTAssertFalse(SubscriptionUtilizationScore.applies(to: bar(used: 20, hours: 5)))
        XCTAssertTrue(SubscriptionUtilizationScore.applies(to: UsageBar(stableKey: "weekly", label: "Weekly", used: 20, limit: 100)))
    }

    private func bar(used: Double, hours: Double = 168) -> UsageBar {
        UsageBar(stableKey: "weekly", label: "Weekly", used: used, limit: 100,
                 projectionCurrent: used, projectionLimit: 100, projectionPeriodStart: start,
                 projectionPeriodEnd: start.addingTimeInterval(hours * 3_600))
    }
    private func score(used: Double, elapsedHours: Double) -> SubscriptionUtilizationScore? {
        SubscriptionUtilizationScore(bar: bar(used: used), at: start.addingTimeInterval(elapsedHours * 3_600))
    }
}
