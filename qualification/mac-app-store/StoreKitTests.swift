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
