import Foundation
import XCTest
@testable import CodexBarIOS

final class MetricTileContentRegressionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000)

    func testOverLimitUsageAndResetProjectionFieldsAreNotTransformed() {
        let bar = UsageBar(
            label: "Synthetic usage", used: 150, limit: 100,
            resetDescription: "Resets in 2 hours",
            projectionDescriptionOverride: "Projected to reach 180%"
        )
        let input = result(bars: [bar])
        for full in [false, true] {
            XCTAssertEqual(resolve(.usageBar(index: 0), input, full: full), .usageBar(bar))
        }
    }

    func testInvalidUsageIndicesAndMissingBarsStayEmpty() {
        for index in [-1, 0, 1] {
            XCTAssertEqual(resolve(.usageBar(index: index), result()), .empty)
        }
        let input = result(bars: [UsageBar(label: "One", used: 1, limit: 10)])
        for index in [-1, 1] {
            XCTAssertEqual(resolve(.usageBar(index: index), input), .empty)
        }
    }

    func testSelectedUsageIndexKeepsItsActualIdentityAndData() {
        let first = UsageBar(label: "First", used: 5, limit: 100)
        let second = UsageBar(label: "Second", used: 85, limit: 100)
        XCTAssertEqual(resolve(.usageBar(index: 1), result(bars: [first, second])), .usageBar(second))
    }

    func testUnavailableReasonRemainsDistinctFromReportedValues() {
        for reason in ["Unavailable", "Setup required", "Synthetic custom unavailable reason", ""] {
            let input = result(bars: [UsageBar(label: "Known", used: 0, limit: 100)], credits: 0)
            XCTAssertEqual(resolve(.unavailableUsage(reason), input), .unavailableUsage(reason))
        }
    }

    func testMissingCreditsNeverBecomeZeroAndReportedZeroOrNegativeRemainValues() {
        XCTAssertEqual(resolve(.creditsRemaining, result()), .empty)
        for value in [0.0, -2.5, 12.75] {
            XCTAssertEqual(
                resolve(.creditsRemaining, result(credits: value)),
                .creditsRemaining(value: value, supportingDetail: nil)
            )
        }
    }

    func testFreshCreditSupportingDetailRequiresFullWidth() {
        let input = result(credits: 12.75)
        XCTAssertEqual(resolve(.creditsRemaining, input), .creditsRemaining(value: 12.75, supportingDetail: nil))
        XCTAssertEqual(
            resolve(.creditsRemaining, input, full: true),
            .creditsRemaining(value: 12.75, supportingDetail: "Current balance")
        )
    }

    func testStaleCreditsKeepTheLastKnownLabelAndAmountOnlyAtFullWidth() {
        let input = result(credits: 12.75, creditsDate: now.addingTimeInterval(-60))
        XCTAssertFalse(input.hasCurrentCredits)
        XCTAssertEqual(
            resolve(.creditsRemaining, input, full: true),
            .creditsRemaining(value: 12.75, supportingDetail: "Last known balance")
        )
        XCTAssertEqual(resolve(.creditsRemaining, input), .creditsRemaining(value: 12.75, supportingDetail: nil))
    }

    func testCreditFreshnessUsesTheExistingPartialFailurePolicy() {
        let current = result(credits: 12.75, failure: "Synthetic bars failure", preserveBars: true)
        XCTAssertTrue(current.hasCurrentCredits)
        XCTAssertEqual(
            resolve(.creditsRemaining, current, full: true),
            .creditsRemaining(value: 12.75, supportingDetail: "Current balance")
        )
        let stale = result(credits: 12.75, failure: "Synthetic credit failure")
        XCTAssertFalse(stale.hasCurrentCredits)
        XCTAssertEqual(
            resolve(.creditsRemaining, stale, full: true),
            .creditsRemaining(value: 12.75, supportingDetail: "Last known balance")
        )
    }

    func testEveryMonetaryKindKeepsCurrencyPrecisionLabelAndAmount() {
        let kinds: [ProviderMonetaryMetricKind] = [
            .balance, .grossSpend, .discounts, .spent, .projectedSpend, .spendLimit, .remainingHeadroom,
        ]
        for kind in kinds {
            let metric = money(kind: kind, detail: "Reported monthly detail")
            let input = result(money: [metric])
            XCTAssertEqual(resolve(.monetary(index: 0), input), .monetary(metric, supportingDetail: nil))
            XCTAssertEqual(
                resolve(.monetary(index: 0), input, full: true),
                .monetary(metric, supportingDetail: "Reported monthly detail")
            )
        }
    }

    func testMonetarySelectionUsesTheActualIndexedMetricAndFullWidthDetail() {
        let first = money(kind: .balance, detail: "First detail")
        let second = money(kind: .spent, detail: "Second detail")
        let input = result(money: [first, second])
        XCTAssertEqual(
            resolve(.monetary(index: 1), input, full: true),
            .monetary(second, supportingDetail: "Second detail")
        )
    }

    func testMissingAndEmptyMonetaryDetailsAreNotInventedOrDropped() {
        for detail in [nil, ""] as [String?] {
            let metric = money(kind: .spent, detail: detail)
            XCTAssertEqual(
                resolve(.monetary(index: 0), result(money: [metric]), full: true),
                .monetary(metric, supportingDetail: detail)
            )
        }
    }

    func testInvalidMonetaryIndicesStayEmpty() {
        for index in [-1, 0, 1] {
            XCTAssertEqual(resolve(.monetary(index: index), result()), .empty)
        }
        let input = result(money: [money(kind: .balance)])
        for index in [-1, 1] {
            XCTAssertEqual(resolve(.monetary(index: index), input), .empty)
        }
    }

    func testSelectionsDoNotMutateProviderOrAccountIdentityOrShareValues() {
        let first = result(credits: 90, accountID: "synthetic.first", providerID: .openRouter)
        let second = result(accountID: "synthetic.second", providerID: .openCodeZen)
        XCTAssertEqual(resolve(.creditsRemaining, first), .creditsRemaining(value: 90, supportingDetail: nil))
        XCTAssertEqual(resolve(.creditsRemaining, second), .empty)
        XCTAssertEqual(first.accountID, "synthetic.first")
        XCTAssertEqual(first.providerID, .openRouter)
        XCTAssertEqual(second.accountID, "synthetic.second")
        XCTAssertEqual(second.providerID, .openCodeZen)
    }

    private func resolve(
        _ kind: ProviderUsageMetricKind,
        _ result: ProviderUsageResult,
        full: Bool = false
    ) -> ProviderMetricTileContent {
        ProviderMetricTileContent.resolve(
            metric: ProviderUsageMetric(id: "synthetic.metric", label: "Synthetic metric", kind: kind),
            result: result, isFullWidth: full
        )
    }

    private func money(kind: ProviderMonetaryMetricKind, detail: String? = nil) -> ProviderMonetaryMetric {
        ProviderMonetaryMetric(
            kind: kind, label: "Synthetic \(kind.rawValue)", minorUnits: Decimal(123456),
            currencyCode: "usd", decimalPlaces: 2, detail: detail
        )
    }

    private func result(
        bars: [UsageBar] = [], credits: Double? = nil, money: [ProviderMonetaryMetric] = [],
        creditsDate: Date? = nil, failure: String? = nil, preserveBars: Bool = false,
        accountID: String = "synthetic.account", providerID: ProviderID = .codex
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: accountID, providerID: providerID, title: "Synthetic account", subtitle: "Synthetic data",
            bars: bars, creditsRemaining: credits, creditsFetchedAt: creditsDate,
            monetaryMetrics: money, failureMessage: failure, preserveCachedBarsOnFailure: preserveBars,
            fetchedAt: now
        )
    }
}
