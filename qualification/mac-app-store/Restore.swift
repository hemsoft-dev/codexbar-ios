import Foundation
import StoreKit
import StoreKitTest

/// Local Xcode transaction session only. No AppStore.sync or production purchase API.
@MainActor
final class NativeStoreKitRestore {
    static let lifetimeID = "com.hemsoft.CodexBarIOS.pro.lifetime"
    private var session: SKTestSession?

    func prepare(configurationURL: URL? = nil) throws {
        guard session == nil else { return }
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            throw NSError(domain: "Qualification", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "StoreKitTest requires the isolated Xcode test host. Run test.sh; no store request was made.",
            ])
        }
        guard let url = configurationURL ?? Bundle.main.url(forResource: "Qualification", withExtension: "storekit") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let testSession = try SKTestSession(contentsOf: url)
        testSession.disableDialogs = true
        testSession.clearTransactions()
        session = testSession
    }

    func seedLifetime() async throws {
        try prepare()
        _ = try await session?.buyProduct(identifier: Self.lifetimeID)
    }

    func restore() async -> Bool {
        guard session != nil else { return false }
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.lifetimeID, transaction.revocationDate == nil {
                return true
            }
        }
        return false
    }

    func revoke() throws {
        guard let session else { throw CocoaError(.coderInvalidValue) }
        for transaction in session.allTransactions() where transaction.productIdentifier == Self.lifetimeID {
            try session.refundTransaction(identifier: transaction.identifier)
        }
    }

    func reset() {
        session?.clearTransactions()
    }
}

/// UI rehearsal only. This cannot read or unlock any real purchase.
@MainActor
final class SyntheticRestore {
    struct Receipt {
        let productID: String
        let verified: Bool
        var revoked: Bool
    }

    private(set) var receipt: Receipt?

    func prepare() throws {
        guard let url = Bundle.main.url(forResource: "Qualification", withExtension: "storekit"),
              let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let products = catalog["products"] as? [[String: Any]],
              products.contains(where: { $0["productID"] as? String == NativeStoreKitRestore.lifetimeID }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    func seedLifetime() async throws {
        try prepare()
        receipt = Receipt(productID: NativeStoreKitRestore.lifetimeID, verified: true, revoked: false)
    }

    func restore() async -> Bool {
        Self.grants(receipt)
    }

    static func grants(_ receipt: Receipt?) -> Bool {
        guard let receipt else { return false }
        return receipt.verified && !receipt.revoked && receipt.productID == NativeStoreKitRestore.lifetimeID
    }

    func revoke() throws { receipt?.revoked = true }
    func reset() { receipt = nil }
}
