import Foundation
import XCTest
@testable import CodexBarIOS

@MainActor
final class ProEntitlementCacheTests: XCTestCase {
    func testFreshInstanceReadsSavedDecisionWithoutAccountIdentifiers() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("decision.json")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let value = ProEntitlementValue(
            reason: .yearly, expiresAt: now.addingTimeInterval(3600),
            proAccessEndsAt: now.addingTimeInterval(3600 + 259200), verifiedAt: now, clockAnchor: testProAnchor(now)
        )
        try ProEntitlementCache(fileURL: url).save(value)
        XCTAssertEqual(ProEntitlementCache(fileURL: url).load(), value)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(saved.keys), ["version", "value"])
        let decision = try XCTUnwrap(saved["value"] as? [String: Any])
        XCTAssertEqual(Set(decision.keys), [
            "reason", "expiresAt", "proAccessEndsAt", "verifiedAt", "subscriptionProduct", "environment", "clockAnchor", "purchaseDenials",
        ])
        XCTAssertEqual((decision["purchaseDenials"] as? [Any])?.count, 0)
        XCTAssertEqual(decision["subscriptionProduct"] as? String, ProProductID.yearly.rawValue)
    }

    func testCorruptUnknownVersionAndMalformedSubscriptionCacheAreRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        for json in [
            "not JSON", "null", #"{"version":2,"value":{"reason":"lifetime","verifiedAt":800000000}}"#,
            #"{"version":1,"value":{"reason":"yearly","verifiedAt":800000000}}"#,
        ] {
            try Data(json.utf8).write(to: url)
            XCTAssertNil(ProEntitlementCache(fileURL: url).load())
        }
    }

    func testTestPurchasesCannotOverwriteProductionFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("decision.json")
        let cache = ProEntitlementCache(fileURL: url)
        let production = ProEntitlementValue(reason: .lifetime, expiresAt: nil, proAccessEndsAt: nil, verifiedAt: Date())
        try cache.save(production)
        let originalBytes = try Data(contentsOf: url)
        for environment: ProStoreEnvironment in [.sandbox, .xcode] {
            let testValue = ProEntitlementValue(
                reason: .none, expiresAt: nil, proAccessEndsAt: nil, verifiedAt: Date(), environment: environment
            )
            try cache.save(testValue)
            XCTAssertEqual(ProEntitlementCache(fileURL: url).load(environment: environment), testValue)
            XCTAssertEqual(try Data(contentsOf: url), originalBytes)
        }
        XCTAssertEqual(ProEntitlementCache(fileURL: url).load(), production)
    }

    func testStoreKitConfigurationMatchesProductsPricesAndYearlyOnlyTrial() throws {
        #if SWIFT_PACKAGE
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let configURL = root.appendingPathComponent("StoreKit/CodexBarPro.storekit")
        #else
        let configURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CodexBarPro", withExtension: "storekit"))
        #endif
        let config = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: configURL)
        ) as? [String: Any])
        let groups = try XCTUnwrap(config["subscriptionGroups"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0]["name"] as? String, "CodexBar Pro")
        let subscriptions = try XCTUnwrap(groups[0]["subscriptions"] as? [[String: Any]])
        XCTAssertEqual(subscriptions.count, 2)
        for product in subscriptions {
            XCTAssertEqual(product["groupNumber"] as? Int, 1)
            XCTAssertEqual(product["familyShareable"] as? Bool, false)
            if product["productID"] as? String == ProProductID.yearly.rawValue {
                XCTAssertEqual(product["displayPrice"] as? String, "14.99")
                XCTAssertEqual(product["recurringSubscriptionPeriod"] as? String, "P1Y")
                let offer = try XCTUnwrap(product["introductoryOffer"] as? [String: Any])
                XCTAssertEqual(offer["paymentMode"] as? String, "free")
                XCTAssertEqual(offer["subscriptionPeriod"] as? String, "P1W")
                XCTAssertEqual(offer["numberOfPeriods"] as? Int, 1)
            } else {
                XCTAssertEqual(product["productID"] as? String, ProProductID.monthly.rawValue)
                XCTAssertEqual(product["displayPrice"] as? String, "1.99")
                XCTAssertEqual(product["recurringSubscriptionPeriod"] as? String, "P1M")
                XCTAssertNil(product["introductoryOffer"])
            }
        }
        let lifetime = try XCTUnwrap((config["products"] as? [[String: Any]])?.first)
        XCTAssertEqual(lifetime["productID"] as? String, ProProductID.lifetime.rawValue)
        XCTAssertEqual(lifetime["type"] as? String, "NonConsumable")
        XCTAssertEqual(lifetime["displayPrice"] as? String, "29.99")
        XCTAssertEqual(lifetime["familyShareable"] as? Bool, false)
    }
}
