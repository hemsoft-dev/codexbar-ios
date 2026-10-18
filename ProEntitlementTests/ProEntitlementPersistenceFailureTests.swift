import Foundation
import XCTest
@testable import CodexBarIOS

@MainActor
final class ProEntitlementPersistenceFailureTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    func testRevocationOverwritesExistingGrantWhenAtomicReplacementIsForbidden() async throws {
        let folder = try makeFolder()
        defer { cleanUp(folder) }
        let url = folder.appendingPathComponent("decision.json")
        let cache = ProEntitlementCache(fileURL: url)
        let first = service(source: TestProSource(), url: url)
        await first.receive(delivery(lifetime()))
        XCTAssertTrue(first.hasAccess)
        let original = try Data(contentsOf: url)
        try permissions(0o555, at: folder)
        XCTAssertThrowsError(try cache.save(.free), "The real atomic replacement must fail before testing its fallback")
        XCTAssertEqual(try Data(contentsOf: url), original)
        var finished = false

        await first.receive(delivery(lifetime(revoked: true)) { finished = true })

        XCTAssertFalse(first.hasAccess)
        XCTAssertFalse(finished)
        XCTAssertNotNil(first.statusMessage)
        let saved = try XCTUnwrap(ProEntitlementCache(fileURL: url).load())
        XCTAssertEqual(saved.reason, .none)
        XCTAssertEqual(saved.purchaseDenials.first?.product, .lifetime)
        XCTAssertEqual(saved.purchaseDenials.first?.signedAt, instant.addingTimeInterval(1))
        XCTAssertNotEqual(try Data(contentsOf: url), original)
        let source = TestProSource()
        let restarted = service(source: source, url: url)
        await restarted.start()
        defer { source.finishStreams() }
        XCTAssertFalse(restarted.hasAccess, "A fresh reader must not resurrect the old on-disk permanent grant")
        await restarted.receive(delivery(lifetime()))
        XCTAssertFalse(restarted.hasAccess, "The fallback must retain signed denial ordering across an older verified replay")
        XCTAssertEqual(ProEntitlementCache(fileURL: url).load()?.reason, ProEntitlementReason.none)
    }

    func testUnrelatedSubscriptionSaveFailureKeepsValidLifetimeFile() async throws {
        let folder = try makeFolder()
        defer { cleanUp(folder) }
        let url = folder.appendingPathComponent("decision.json")
        let first = service(source: TestProSource(), url: url)
        await first.receive(delivery(lifetime()))
        let original = try Data(contentsOf: url)
        try permissions(0o555, at: folder)
        XCTAssertThrowsError(try ProEntitlementCache(fileURL: url).save(.free))
        let refund = ProPurchaseEvidence(
            product: .monthly, transactionID: 2, purchasedAt: instant,
            signedAt: instant.addingTimeInterval(1), expiresAt: instant.addingTimeInterval(3600), revoked: true
        )
        var finished = false

        await first.receive(delivery(refund) { finished = true })

        XCTAssertTrue(first.hasAccess, "An unrelated refund does not invalidate the existing lifetime entitlement")
        XCTAssertEqual(first.value.reason, .lifetime)
        XCTAssertFalse(finished)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let restarted = service(source: TestProSource(), url: url)
        XCTAssertTrue(restarted.hasAccess)
        XCTAssertEqual(restarted.value.reason, .lifetime)
    }

    func testFullyUnwritableCacheReportsDurabilityFailureWithoutFinishing() async throws {
        let folder = try makeFolder()
        defer { cleanUp(folder) }
        let url = folder.appendingPathComponent("decision.json")
        let first = service(source: TestProSource(), url: url)
        await first.receive(delivery(lifetime()))
        let original = try Data(contentsOf: url)
        try permissions(0o444, at: url)
        try permissions(0o555, at: folder)
        XCTAssertThrowsError(try ProEntitlementCache(fileURL: url).save(.free))
        XCTAssertThrowsError(try Data().write(to: url), "Direct truncation must independently fail")
        XCTAssertThrowsError(try FileManager.default.removeItem(at: url), "Removal must independently fail")
        var finished = false

        await first.receive(delivery(lifetime(revoked: true)) { finished = true })

        XCTAssertFalse(first.hasAccess)
        XCTAssertFalse(finished)
        XCTAssertEqual(first.statusMessage, "Purchase storage could not be updated or cleared. Try Restore Purchases.")
        XCTAssertEqual(try Data(contentsOf: url), original, "A fully unwritable filesystem cannot promise durable invalidation")
        XCTAssertEqual(ProEntitlementCache(fileURL: url).load()?.reason, .lifetime)

        try permissions(0o755, at: folder)
        try permissions(0o644, at: url)
        await first.refresh()
        XCTAssertEqual(ProEntitlementCache(fileURL: url).load()?.reason, ProEntitlementReason.none)
        XCTAssertFalse(service(source: TestProSource(), url: url).hasAccess)
        await first.receive(delivery(lifetime(revoked: true)) { finished = true })
        XCTAssertTrue(finished, "The pending delivery can finish after durable denial succeeds")
    }

    func testInvalidationRemovesReadOnlyGrantWhenDirectoryAllowsRemoval() async throws {
        let folder = try makeFolder()
        defer { cleanUp(folder) }
        let url = folder.appendingPathComponent("decision.json")
        let first = service(source: TestProSource(), url: url)
        await first.receive(delivery(lifetime()))
        try permissions(0o444, at: url)
        XCTAssertThrowsError(try Data().write(to: url))

        try ProEntitlementCache(fileURL: url).invalidate(with: .free)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(ProEntitlementCache(fileURL: url).load())
        XCTAssertFalse(service(source: TestProSource(), url: url).hasAccess)
    }

    func testInvalidationRejectsGrantAndMalformedDecisionThenRepairsCorruptFile() async throws {
        let folder = try makeFolder()
        defer { cleanUp(folder) }
        let url = folder.appendingPathComponent("decision.json")
        let first = service(source: TestProSource(), url: url)
        await first.receive(delivery(lifetime()))
        let original = try Data(contentsOf: url)
        let cache = ProEntitlementCache(fileURL: url)
        XCTAssertThrowsError(try cache.invalidate(with: first.value))
        let invalid = ProEntitlementValue(reason: .none, expiresAt: instant, proAccessEndsAt: nil, verifiedAt: nil)
        XCTAssertThrowsError(try cache.invalidate(with: invalid))
        XCTAssertEqual(try Data(contentsOf: url), original)
        try Data("malformed cache".utf8).write(to: url)
        XCTAssertNil(ProEntitlementCache(fileURL: url).load())

        try cache.invalidate(with: .free)

        XCTAssertEqual(ProEntitlementCache(fileURL: url).load(), ProEntitlementValue.free)
        XCTAssertFalse(service(source: TestProSource(), url: url).hasAccess)
    }

    private func lifetime(revoked: Bool = false) -> ProPurchaseEvidence {
        ProPurchaseEvidence(
            product: .lifetime, transactionID: 1, purchasedAt: instant.addingTimeInterval(-100),
            signedAt: instant.addingTimeInterval(revoked ? 1 : 0), revoked: revoked
        )
    }

    private func delivery(
        _ purchase: ProPurchaseEvidence, finish: @escaping @MainActor () async -> Void = {}
    ) -> ProTransactionDelivery {
        ProTransactionDelivery(product: purchase.product, evidence: .verified(purchase), finish: finish)
    }

    private func service(source: TestProSource, url: URL) -> ProEntitlement {
        ProEntitlement(
            source: source, cache: ProEntitlementCache(fileURL: url),
            now: { self.instant.addingTimeInterval(10) }, clock: testProClock
        )
    }

    private func permissions(_ mode: Int, at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func cleanUp(_ folder: URL) {
        do {
            try permissions(0o755, at: folder)
            let file = folder.appendingPathComponent("decision.json")
            if FileManager.default.fileExists(atPath: file.path) { try permissions(0o644, at: file) }
            try FileManager.default.removeItem(at: folder)
        } catch {
            XCTFail("Could not restore permissions and remove the isolated persistence fixture: \(error)")
        }
    }
}
