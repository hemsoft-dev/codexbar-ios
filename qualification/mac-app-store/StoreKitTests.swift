import StoreKit
import StoreKitTest
import XCTest

@MainActor
final class StoreKitQualificationTests: XCTestCase {
    func testLocalLifetimeRestoreAndRefund() async throws {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.hemsoft.qualification.mac476.storekithost")
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Qualification", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }

        try await assertLifetimeEntitlement(present: false)
        let purchase = try await session.buyProduct(identifier: NativeStoreKitRestore.lifetimeID)
        XCTAssertEqual(purchase.productID, NativeStoreKitRestore.lifetimeID)
        XCTAssertEqual(purchase.environment, .xcode, "Only local Xcode transactions qualify")
        XCTAssertNil(purchase.revocationDate)
        XCTAssertEqual(session.allTransactions().count, 1)
        try await assertLifetimeEntitlement(present: true)

        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.refundTransaction(identifier: transaction.identifier)
        try await assertLifetimeEntitlement(present: false)
        let refunded = await Transaction.latest(for: NativeStoreKitRestore.lifetimeID)
        guard case .verified(let receipt) = refunded else {
            return XCTFail("Refund must retain a verified native transaction")
        }
        XCTAssertEqual(receipt.id, purchase.id)
        XCTAssertNotNil(receipt.revocationDate)
        XCTAssertEqual(receipt.environment, .xcode)
    }

    func testAdapterDefaultCatalogRestoreAndRefund() async throws {
        let adapter = NativeStoreKitRestore()
        try adapter.prepare()
        defer { adapter.reset() }
        try await assertAdapter(adapter, present: false)
        try await adapter.seedLifetime()
        try await assertAdapter(adapter, present: true)
        try adapter.revoke()
        try await assertAdapter(adapter, present: false)
    }

    // test.sh runs these methods in distinct xcodebuild invocations, in this order.
    private var relaunchMarker: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mac476-native-relaunch.json")
    }

    func testPrepareLifetimeForRelaunch() async throws {
        try? FileManager.default.removeItem(at: relaunchMarker)
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Qualification", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        let purchase = try await session.buyProduct(identifier: NativeStoreKitRestore.lifetimeID)
        XCTAssertEqual(purchase.environment, .xcode)
        try await assertLifetimeEntitlement(present: true)
        let marker = ["pid": String(ProcessInfo.processInfo.processIdentifier), "transaction": String(purchase.id)]
        try JSONEncoder().encode(marker).write(to: relaunchMarker, options: .atomic)
        // Intentionally retain only this local Xcode transaction for the next process.
    }

    func testRestoreLifetimeAfterRelaunch() async throws {
        let marker = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: relaunchMarker))
        defer { try? FileManager.default.removeItem(at: relaunchMarker) }
        XCTAssertNotEqual(marker["pid"], String(ProcessInfo.processInfo.processIdentifier))
        // Read before creating a new SKTestSession or buying any product.
        try await assertLifetimeEntitlement(present: true)
        guard case .verified(let restored) = await Transaction.latest(for: NativeStoreKitRestore.lifetimeID) else {
            return XCTFail("Fresh process must rediscover the verified lifetime transaction")
        }
        XCTAssertEqual(String(restored.id), marker["transaction"])
        XCTAssertEqual(restored.environment, .xcode)
        XCTAssertNil(restored.revocationDate)
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Qualification", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        defer { session.clearTransactions() }
        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.refundTransaction(identifier: transaction.identifier)
        try await assertLifetimeEntitlement(present: false)
    }

    private func assertAdapter(_ adapter: NativeStoreKitRestore, present: Bool) async throws {
        for _ in 0..<50 {
            if await adapter.restore() == present { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Native adapter did not reach lifetime present=\(present)")
    }

    private func assertLifetimeEntitlement(present: Bool) async throws {
        // StoreKit's transaction database converges asynchronously after purchase/refund.
        for _ in 0..<50 {
            var found = false
            for await result in Transaction.currentEntitlements {
                guard case .verified(let transaction) = result else {
                    return XCTFail("Unverified native entitlement: \(result)")
                }
                if transaction.productID == NativeStoreKitRestore.lifetimeID {
                    XCTAssertEqual(transaction.environment, .xcode)
                    XCTAssertNil(transaction.revocationDate)
                    found = true
                }
            }
            if found == present { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Native currentEntitlements did not reach lifetime present=\(present) within five seconds")
    }
}
