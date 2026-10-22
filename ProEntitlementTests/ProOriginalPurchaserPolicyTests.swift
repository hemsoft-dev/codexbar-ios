import Foundation
import XCTest
@testable import CodexBarIOS

final class ProOriginalPurchaserPolicyTests: XCTestCase {
    private let cutover = ProOriginalPurchaserPolicy.cutover

    func testCompiledCutoverMatchesProvisionalReleaseDecision() throws {
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
        XCTAssertEqual(cutover, expected, "#470 must reverify both the compiled cutoff and its release regression")
    }

    func testPaidBuildsQualifyNumericallyAfterCutover() {
        for version in ["1", "2", "3", "4", "04"] {
            XCTAssertEqual(resolve(purchase(version)).reason, .originalPurchaser, version)
        }
        for version in ["5", "10", "40", "500", "9999999999999999999999999999"] {
            XCTAssertEqual(resolve(purchase(version)).reason, .none, version)
        }
    }

    func testDateIsIndependentOfVersionAndStrictAtCutover() {
        for version in ["5", "10", "2.0", "unknown"] {
            XCTAssertEqual(resolve(purchase(version, date: cutover.addingTimeInterval(-0.001))).reason, .originalPurchaser, version)
            XCTAssertEqual(resolve(purchase(version, date: cutover)).reason, .none, version)
            XCTAssertEqual(resolve(purchase(version, date: cutover.addingTimeInterval(0.001))).reason, .none, version)
        }
    }

    func testMarketingVersionsValidateEveryComponentBeforeComparison() {
        for version in ["1.0", "1.4.0", "1.10", "1.999.999", "0.9", "01.04.00"] {
            XCTAssertEqual(resolve(purchase(version)).reason, .originalPurchaser, version)
        }
        for version in ["2.0", "2.0.0", "2.0.1", "2.10", "10.0", "4.0"] {
            XCTAssertEqual(resolve(purchase(version)).reason, .none, version)
        }
        for version in [
            "", " ", "+1", "-1", " 1", "1 ", "1\n", "1..0", ".1", "1.", "1.4beta", "v1.4", "1.0-beta",
            "1.0+build", "1e0", "１", "١", "١.٠", "1.４", "1.9999999999999999999999999999",
        ] {
            XCTAssertEqual(resolve(purchase(version)).reason, .none, version)
        }
    }

    func testSandboxTestFlightReviewAndXcodeNeverQualify() throws {
        let sandboxDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2013-08-01T00:00:00Z"))
        for environment: ProStoreEnvironment in [.sandbox, .xcode] {
            for version in ["1", "4", "1.0"] {
                let app = ProAppPurchase(originalVersion: version, originalPurchaseDate: sandboxDate, environment: environment, revoked: false)
                XCTAssertEqual(resolve(app).reason, .none, "\(environment), \(version)")
            }
        }
    }

    func testRevokedAndUnverifiedAppTransactionsNeverGrant() {
        let revoked = ProAppPurchase(
            originalVersion: "4", originalPurchaseDate: cutover.addingTimeInterval(-1), environment: .production, revoked: true
        )
        XCTAssertEqual(resolve(revoked).reason, .none)
        for evidence: ProVerification<ProAppPurchase> in [.unverified, .unavailable] {
            let value = ProEntitlementResolver.resolve(
                ProStoreSnapshot(appPurchase: evidence), cached: .free,
                originalPolicy: ProOriginalPurchaserPolicy(), now: cutover
            )
            XCTAssertEqual(value.reason, .none)
        }
    }

    func testNonfiniteDateCannotGrantThroughDateBranch() {
        for interval in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(resolve(purchase("5", date: Date(timeIntervalSince1970: interval))).reason, .none)
        }
    }

    private func purchase(_ version: String, date: Date? = nil) -> ProAppPurchase {
        ProAppPurchase(
            originalVersion: version, originalPurchaseDate: date ?? cutover.addingTimeInterval(1),
            environment: .production, revoked: false, signedAt: cutover.addingTimeInterval(10)
        )
    }

    private func resolve(_ app: ProAppPurchase) -> ProEntitlementValue {
        ProEntitlementResolver.resolve(
            ProStoreSnapshot(appPurchase: .verified(app)), cached: .free,
            originalPolicy: ProOriginalPurchaserPolicy(), now: cutover.addingTimeInterval(10)
        )
    }
}
