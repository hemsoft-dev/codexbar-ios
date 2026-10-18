import Foundation
import XCTest
@testable import CodexBarIOS

@MainActor
final class ProEntitlementDeniedReplayTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private let originalID: UInt64 = 9_001_234_567_890_123_456
    private let repurchaseID: UInt64 = 9_001_234_567_890_123_457

    func testMonthlyRevocationSurvivesColdStartAndOlderVerifiedDelivery() async throws {
        try await checkDeniedReplay(.monthly)
    }

    func testLifetimeRevocationSurvivesColdStartAndOlderVerifiedDelivery() async throws {
        try await checkDeniedReplay(.lifetime)
    }

    func testNewerMonthlyRepurchaseAfterColdStartRestoresAccess() async throws {
        try await checkRepurchase(.monthly, expectedReason: .monthly)
    }

    func testNewerLifetimeRepurchaseAfterColdStartRestoresAccess() async throws {
        try await checkRepurchase(.lifetime, expectedReason: .lifetime)
    }

    private func checkDeniedReplay(_ product: ProProductID) async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("decision.json")
        try await persistRevocation(product, at: url)
        let source = TestProSource()
        let restarted = service(source: source, cacheURL: url)
        XCTAssertEqual(restarted.value.reason, .none)
        XCTAssertFalse(restarted.hasAccess)
        await restarted.start()
        defer { source.finishStreams() }
        XCTAssertEqual(source.calls, ["transactions", "statuses", "snapshot"])
        XCTAssertFalse(restarted.hasAccess, "Unavailable StoreKit must retain the saved denial")

        await restarted.receive(delivery(purchase(product)))

        XCTAssertFalse(restarted.hasAccess, "An older verified copy of the refunded purchase must not restore access after relaunch")
        XCTAssertEqual(restarted.value.reason, .none)
        XCTAssertEqual(try XCTUnwrap(ProEntitlementCache(fileURL: url).load()).reason, .none)
        try assertNoIdentifiers(in: Data(contentsOf: url))
    }

    private func checkRepurchase(_ product: ProProductID, expectedReason: ProEntitlementReason) async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("decision.json")
        try await persistRevocation(product, at: url)
        let source = TestProSource()
        let restarted = service(source: source, cacheURL: url)
        await restarted.start()
        defer { source.finishStreams() }
        XCTAssertFalse(restarted.hasAccess)
        let repurchase = ProPurchaseEvidence(
            product: product, transactionID: repurchaseID, purchasedAt: instant.addingTimeInterval(20),
            signedAt: instant.addingTimeInterval(20),
            expiresAt: product == .lifetime ? nil : instant.addingTimeInterval(7200)
        )

        await restarted.receive(delivery(repurchase))

        XCTAssertTrue(restarted.hasAccess, "A genuinely newer purchase must remain eligible after a saved denial")
        XCTAssertEqual(restarted.value.reason, expectedReason)
        let saved = try XCTUnwrap(ProEntitlementCache(fileURL: url).load())
        XCTAssertEqual(saved.reason, expectedReason)
        XCTAssertEqual(saved.purchasedAt, repurchase.purchasedAt)
        try assertNoIdentifiers(in: Data(contentsOf: url))
        let nextLaunch = service(source: TestProSource(), cacheURL: url)
        XCTAssertTrue(nextLaunch.hasAccess, "The new grant must survive another disk-backed cold start")
    }

    private func persistRevocation(_ product: ProProductID, at url: URL) async throws {
        let first = service(source: TestProSource(), cacheURL: url)
        let initial = purchase(product)
        await first.receive(delivery(initial))
        XCTAssertTrue(first.hasAccess)
        let refund = ProPurchaseEvidence(
            product: product, transactionID: originalID, purchasedAt: initial.purchasedAt,
            signedAt: instant.addingTimeInterval(10), expiresAt: initial.expiresAt, revoked: true
        )
        await first.receive(delivery(refund))
        XCTAssertEqual(first.value.reason, .none)
        XCTAssertFalse(first.hasAccess)
        let bytes = try Data(contentsOf: url)
        let restored = try XCTUnwrap(ProEntitlementCache(fileURL: url).load())
        XCTAssertEqual(restored, first.value, "A fresh cache instance must read the actual saved denial")
        XCTAssertEqual(restored.reason, .none)
        try assertNoIdentifiers(in: bytes)
    }

    private func service(source: TestProSource, cacheURL: URL) -> ProEntitlement {
        ProEntitlement(
            source: source, cache: ProEntitlementCache(fileURL: cacheURL),
            now: { self.instant.addingTimeInterval(30) }, clock: testProClock
        )
    }

    private func purchase(_ product: ProProductID) -> ProPurchaseEvidence {
        ProPurchaseEvidence(
            product: product, transactionID: originalID, purchasedAt: instant.addingTimeInterval(-3600),
            signedAt: instant, expiresAt: product == .lifetime ? nil : instant.addingTimeInterval(3600)
        )
    }

    private func delivery(_ purchase: ProPurchaseEvidence) -> ProTransactionDelivery {
        ProTransactionDelivery(product: purchase.product, evidence: .verified(purchase), finish: {})
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func assertNoIdentifiers(in data: Data) throws {
        let json = try JSONSerialization.jsonObject(with: data)
        let forbidden = Set(["transactionid", "originaltransactionid", "accountid", "appaccounttoken"])
        XCTAssertTrue(allKeys(in: json).isDisjoint(with: forbidden))
        let text = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        XCTAssertFalse(text.contains(String(originalID)))
        XCTAssertFalse(text.contains(String(repurchaseID)))
    }

    private func allKeys(in value: Any) -> Set<String> {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: Set<String>()) { keys, entry in
                keys.insert(entry.key.lowercased())
                keys.formUnion(allKeys(in: entry.value))
            }
        }
        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) { $0.formUnion(allKeys(in: $1)) }
        }
        return []
    }
}
