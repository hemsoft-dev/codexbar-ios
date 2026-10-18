import StoreKit
import StoreKitTest
import XCTest
@testable import CodexBarIOS

@MainActor
final class StoreKitProPreparationTests: XCTestCase {
    /// Run this test in its own XCTest process, let that process exit normally, then
    /// run the integration classes in a second invocation on the same simulator.
    /// Leaving the configured local store active is deliberate; no purchase is made.
    func testPrepareLocalStoreKitConfiguration() async throws {
        try storeKitEvent("preparation-start", ["scenario": "default"])
        try StoreKitProTestContext.requireIsolatedHost()
        let session = try StoreKitProTestContext.configuredSession()
        let storefront = await Storefront.current
        XCTAssertEqual(try XCTUnwrap(storefront).countryCode, "USA")
        let products = try await storeKitProducts()
        XCTAssertEqual(products.count, 3)
        XCTAssertTrue(session.allTransactions().isEmpty)
        try await StoreKitProTestContext.requireEmptyTransactions("preparation")
        try storeKitEvent("prepared", [
            "purchaseAttempted": "false",
            "productCount": String(products.count),
            "storefront": session.storefront,
            "sessionTransactionCount": String(session.allTransactions().count),
            "hostIsolation": "explicit-native-host",
        ])
    }

    /// Run separately immediately before the native UI purchase-error journey.
    /// StoreKit may present an error alert even with dialogs disabled, so XCTest
    /// UI automation must acknowledge that alert before the purchase can return.
    func testPrepareLocalStoreKitPurchaseFailure() async throws {
        try storeKitEvent("preparation-start", ["scenario": "purchase-failure"])
        try StoreKitProTestContext.requireIsolatedHost()
        let session = try StoreKitProTestContext.configuredSession()
        try await StoreKitProTestContext.requireEmptyTransactions("purchase-failure preparation")
        try await session.setSimulatedError(.purchase(.productUnavailable), forAPI: .purchase)
        let configured = await session.simulatedError(forAPI: .purchase)
        XCTAssertEqual(configured, .purchase(.productUnavailable))
        XCTAssertTrue(session.allTransactions().isEmpty)
        try storeKitEvent("prepared-purchase-failure", [
            "purchaseAttempted": "false",
            "configuredError": "Product.PurchaseError.productUnavailable",
            "sessionTransactionCount": String(session.allTransactions().count),
            "hostIsolation": "explicit-native-host",
        ])
    }

    /// The following host process must start with Germany already configured.
    /// A hot storefront change is not reliable on the local iOS 27.0 runtime.
    func testPrepareLocalStoreKitGermany() async throws {
        try storeKitEvent("preparation-start", ["scenario": "germany"])
        try StoreKitProTestContext.requireIsolatedHost()
        let session = try StoreKitProTestContext.configuredSession(storefront: "DEU", locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(session.storefront, "DEU")
        XCTAssertEqual(session.locale.language.languageCode?.identifier, "de")
        try await StoreKitProTestContext.requireEmptyTransactions("Germany preparation")
        try storeKitEvent("prepared-germany", [
            "purchaseAttempted": "false",
            "sessionStorefront": session.storefront,
            "requestedLocale": "de_DE",
            "sessionNormalizedLocaleIdentifier": session.locale.identifier,
            "nextHostMustVerifyNativeStorefront": "true",
        ])
    }
}
