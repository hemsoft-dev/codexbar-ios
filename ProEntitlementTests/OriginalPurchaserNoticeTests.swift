import Foundation
import XCTest
@testable import CodexBarIOS

@MainActor
final class OriginalPurchaserNoticeTests: XCTestCase {
    private let cutover = ProOriginalPurchaserPolicy.cutover

    func testNoticeWaitsForResolutionAndOnlyThanksOriginalPurchasers() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let notice = OriginalPurchaserNotice(defaults: defaults)
        XCTAssertFalse(notice.shouldShow(value: originalValue(), isResolved: false))
        XCTAssertTrue(notice.shouldShow(value: originalValue(), isResolved: true))
        for reason: ProEntitlementReason in [.none, .lifetime, .monthly, .yearly, .trial, .billingGrace] {
            let value = ProEntitlementValue(reason: reason, expiresAt: nil, proAccessEndsAt: nil, verifiedAt: cutover)
            XCTAssertFalse(notice.shouldShow(value: value, isResolved: true))
        }
        XCTAssertFalse(notice.shouldShow(value: .free, isResolved: true), "Revocation must remove the notice")
        for environment: ProStoreEnvironment in [.sandbox, .xcode] {
            let value = ProEntitlementValue(
                reason: .originalPurchaser, expiresAt: nil, proAccessEndsAt: nil, verifiedAt: cutover, environment: environment
            )
            XCTAssertFalse(notice.shouldShow(value: value, isResolved: true))
        }
    }

    func testEligibilityAndInterruptedPresentationDoNotConsumeNotice() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = OriginalPurchaserNotice(defaults: defaults)
        XCTAssertFalse(first.shouldShow(value: originalValue(), isResolved: false))
        XCTAssertTrue(first.shouldShow(value: originalValue(), isResolved: true))
        XCTAssertTrue(first.shouldShow(value: originalValue(), isResolved: true))

        let restartedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let restarted = OriginalPurchaserNotice(defaults: restartedDefaults)
        XCTAssertFalse(restarted.isAcknowledged)
        XCTAssertTrue(restarted.shouldShow(value: originalValue(), isResolved: true))
        XCTAssertNil(defaults.persistentDomain(forName: suite), "Checking eligibility must never write a seen flag")
    }

    func testAcknowledgmentSurvivesRelaunchAndDoesNotChangeEntitlement() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = TestProSource()
        defer { source.finishStreams() }
        let cache = TestProCache()
        cache.saved = originalValue()
        let service = ProEntitlement(source: source, cache: cache)
        let notice = OriginalPurchaserNotice(defaults: defaults)
        notice.acknowledge()
        XCTAssertFalse(notice.shouldShow(value: service.value, isResolved: true))
        XCTAssertTrue(service.hasAccess)
        XCTAssertEqual(cache.saved?.reason, .originalPurchaser)

        let restartedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let restarted = OriginalPurchaserNotice(defaults: restartedDefaults)
        XCTAssertTrue(restarted.isAcknowledged)
        XCTAssertFalse(restarted.shouldShow(value: originalValue(), isResolved: true))
    }

    func testExactThankYouAndFamilyDeadlineStopsAtCutover() throws {
        XCTAssertEqual(OriginalPurchaserNotice.message, "Thanks for buying CodexBar. You have lifetime Pro: nothing to do.")
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var instant = cutover.addingTimeInterval(-0.001)
        let notice = OriginalPurchaserNotice(defaults: defaults, now: { instant })
        XCTAssertNotNil(notice.familyMessage())
        instant = cutover
        XCTAssertNil(notice.familyMessage())
        instant = cutover.addingTimeInterval(0.001)
        XCTAssertNil(notice.familyMessage())
        XCTAssertTrue(notice.shouldShow(value: originalValue(), isResolved: true), "The thanks remains after the family deadline")
    }

    func testDeadlineUsesLocalizedDateTimeAndTimeZoneAtCutover() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let notice = OriginalPurchaserNotice(defaults: defaults, now: { self.cutover.addingTimeInterval(-1) })
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let english = try XCTUnwrap(notice.familyMessage(locale: Locale(identifier: "en_US"), timeZone: newYork))
        for text in ["Thursday", "November 5", "2026", "7:00", "PM", "EST"] {
            XCTAssertTrue(english.contains(text), english)
        }
        let berlin = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let german = try XCTUnwrap(notice.familyMessage(locale: Locale(identifier: "de_DE"), timeZone: berlin))
        for text in ["Freitag", "November", "2026", "01:00", "MEZ"] {
            XCTAssertTrue(german.contains(text), german)
        }
        XCTAssertNotEqual(english, german)
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "original-purchaser-tests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func originalValue() -> ProEntitlementValue {
        ProEntitlementValue(reason: .originalPurchaser, expiresAt: nil, proAccessEndsAt: nil, verifiedAt: cutover)
    }
}
