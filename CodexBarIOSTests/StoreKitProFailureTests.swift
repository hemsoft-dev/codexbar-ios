import Foundation
import StoreKit
import StoreKitTest
import XCTest
@testable import CodexBarIOS

@MainActor
final class StoreKitProFailureTests: XCTestCase {
    func testRealDeliveryRemainsUnfinishedUntilDiskPersistenceSucceeds() async throws {
        let context = try await storeKitContext()
        await context.observeTransactionsWithoutFinishing()
        let service = await context.makeService(start: false)
        await service.refresh()
        let delivery = try storeKitDelivery(try await context.source.purchase(.lifetime), product: .lifetime)
        let before = await storeKitUnfinishedProducts()
        XCTAssertTrue(before.contains(ProProductID.lifetime.rawValue))
        try FileManager.default.removeItem(at: context.cacheDirectory)
        let rejected = await service.receive(delivery)
        XCTAssertFalse(rejected)
        XCTAssertFalse(service.hasAccess)
        XCTAssertNotNil(service.statusMessage)
        XCTAssertNil(context.cache.load(environment: .xcode))
        let afterFailure = await storeKitUnfinishedProducts()
        XCTAssertTrue(afterFailure.contains(ProProductID.lifetime.rawValue))
        try FileManager.default.createDirectory(at: context.cacheDirectory, withIntermediateDirectories: true)
        let committed = await service.receive(delivery)
        XCTAssertTrue(committed)
        XCTAssertTrue(service.hasAccess)
        XCTAssertEqual(service.value.reason, .lifetime)
        XCTAssertEqual(context.cache.load(environment: .xcode), service.value)
        let afterCommit = await storeKitUnfinishedProducts()
        XCTAssertTrue(afterCommit.isEmpty)
        try storeKitEvent("persistence-before-finish", [
            "failure": "actual missing cache parent directory",
            "unfinishedAfterFailure": "true",
            "committedAfterRepair": "true",
            "unfinishedAfterCommit": "0",
        ])
    }

    func testProductLookupFailurePropagatesAndDoesNotManufactureAccess() async throws {
        let context = try await storeKitContext()
        try await context.session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
        do {
            _ = try await context.source.catalog()
            XCTFail("An API-specific product lookup failure unexpectedly returned a catalog.")
        } catch {
            try storeKitEvent("catalog-error", ["result": "thrown", "error": String(describing: type(of: error))])
        }
        do {
            _ = try await context.source.purchase(.lifetime)
            XCTFail("A failed product lookup unexpectedly reached a purchase result.")
        } catch {
            XCTAssertTrue(context.session.allTransactions().isEmpty)
        }
        let snapshot = await context.source.snapshot()
        XCTAssertFalse(snapshot.subscriptionStatusAvailable)
        XCTAssertTrue(snapshot.purchases.isEmpty)
        try await context.session.setSimulatedError(nil, forAPI: .loadProducts)
        let recovered = try await context.source.catalog()
        XCTAssertEqual(recovered.products.count, 3)
    }

    func testCancellationSimulationRecordsActualBoundaryWithoutGrant() async throws {
        let context = try await storeKitContext()
        await context.observeTransactionsWithoutFinishing()
        try await context.session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
        let configured = await context.session.simulatedError(forAPI: .purchase)
        XCTAssertEqual(configured, .generic(.userCancelled))
        let observed: String
        do {
            switch try await context.source.purchase(.lifetime) {
            case .cancelled:
                observed = "Product.PurchaseResult.userCancelled"
            case .pending, .purchased:
                throw StoreKitProTestFailure.assertion("Cancellation simulation returned a non-cancellation purchase outcome.")
            }
        } catch StoreKitError.userCancelled {
            // Some StoreKitTest runtimes inject a thrown error instead of the result case.
            // This proves that boundary only; injected pure tests cover .cancelled separately.
            observed = "thrown StoreKitError.userCancelled; result-case coverage unavailable"
        } catch StoreKitError.unknown {
            // iOS 27.0 can map this supported simulation to ASDServerErrorDomain 907
            // and then StoreKitError.unknown. Record the limitation, never cancellation success.
            observed = "thrown StoreKitError.unknown; requested cancellation not represented by runtime"
        }
        XCTAssertTrue(context.session.allTransactions().isEmpty)
        let current = await storeKitCurrentProducts()
        XCTAssertTrue(current.isEmpty)
        try storeKitEvent("cancellation-observed", ["actualBoundary": observed, "committed": "false"])
    }

    func testVerificationFailureNeverCommitsOrFinishesRealTransaction() async throws {
        let context = try await storeKitContext()
        await context.observeTransactionsWithoutFinishing()
        let service = await context.makeService(start: false)
        await service.refresh()
        try await context.session.setSimulatedError(.verification(.invalidSignature), forAPI: .verification)
        let outcome = try await context.source.purchase(.lifetime)
        guard case let .purchased(delivery) = outcome, case .unverified = delivery.evidence else {
            throw StoreKitProTestFailure.assertion("The verification simulation did not produce an unverified adapter delivery.")
        }
        XCTAssertEqual(delivery.environment, .xcode)
        let accepted = await service.receive(delivery)
        XCTAssertFalse(accepted)
        XCTAssertFalse(service.hasAccess)
        XCTAssertNotNil(service.statusMessage)
        let unfinished = await storeKitUnfinishedProducts()
        XCTAssertTrue(unfinished.contains(ProProductID.lifetime.rawValue))
        XCTAssertNotEqual(context.cache.load(environment: .xcode)?.reason, .lifetime)
        try storeKitEvent("verification-rejected", ["evidence": "unverified", "unfinished": "true", "committed": "false"])
    }

    func testSubscriptionStatusSimulationMapsActualAPIBoundary() async throws {
        let context = try await storeKitContext()
        await context.observeTransactionsWithoutFinishing()
        let service = await context.makeService(start: false)
        await service.refresh()
        let delivery = try storeKitDelivery(try await context.source.purchase(.monthly), product: .monthly)
        let committed = await service.receive(delivery)
        XCTAssertTrue(committed)
        XCTAssertEqual(service.value.reason, .monthly)
        try await context.session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .subscriptionStatus)
        let configured = await context.session.simulatedError(forAPI: .subscriptionStatus)
        XCTAssertEqual(configured, .generic(.networkError(URLError(.notConnectedToInternet))))
        let products = try await storeKitProducts()
        let subscription = try XCTUnwrap(products[.monthly]?.subscription)
        let nativeStatuses: [Product.SubscriptionInfo.Status]?
        let boundary: String
        do {
            nativeStatuses = try await subscription.status
            boundary = "returned statuses; configured API failure was not thrown"
        } catch {
            nativeStatuses = nil
            boundary = "thrown " + String(describing: type(of: error))
        }
        let snapshot = await context.source.snapshot()
        XCTAssertEqual(snapshot.subscriptionStatusAvailable, nativeStatuses != nil)
        let verifiedTransactionIDs = Set((nativeStatuses ?? []).compactMap { status -> UInt64? in
            if case let .verified(transaction) = status.transaction { return transaction.id }
            return nil
        })
        XCTAssertTrue(Set(snapshot.subscriptions.map(\.purchase.transactionID)) == verifiedTransactionIDs,
                      "The adapter status identities differed from the actual native status response.")
        await service.refresh()
        XCTAssertTrue(service.hasAccess, "The actual verified purchase survives unavailable renewal metadata.")
        if nativeStatuses?.isEmpty != false {
            XCTAssertEqual(service.commerce.lifetimeAction, .unavailable)
        }
        try await context.session.setSimulatedError(nil, forAPI: .subscriptionStatus)
        let recovered = await context.source.snapshot()
        XCTAssertTrue(recovered.subscriptionStatusAvailable)
        try storeKitEvent("status-error-observed", [
            "configuredError": "StoreKitError.networkError",
            "actualBoundary": boundary,
            "nativeStatusCount": String(nativeStatuses?.count ?? 0),
            "nativeVerifiedTransactionCount": String(verifiedTransactionIDs.count),
            "statusAvailableDuringError": String(snapshot.subscriptionStatusAvailable),
            "access": "verified monthly purchase retained",
            "recovered": String(recovered.subscriptionStatusAvailable),
        ])
    }

    func testExplicitAppRefreshAndFailedSyncClearFreshClockEvidence() async throws {
        let context = try await storeKitContext()
        try await context.source.restore(refreshAppTransaction: true)
        let refreshed = await context.source.snapshot()
        let fresh = try XCTUnwrap(refreshed.freshClockEvidence)
        XCTAssertEqual(fresh.environment, .xcode)
        XCTAssertTrue(fresh.signedAt.timeIntervalSinceReferenceDate.isFinite)
        guard case let .verified(app) = refreshed.appPurchase else {
            throw StoreKitProTestFailure.assertion("Real local AppTransaction was not verified after refresh.")
        }
        XCTAssertEqual(app.environment, .xcode)
        XCTAssertFalse(ProOriginalPurchaserPolicy().qualifies(app))
        try await context.session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .appStoreSync)
        do {
            try await context.source.restore(refreshAppTransaction: true)
            XCTFail("Simulated AppStore.sync failure unexpectedly succeeded.")
        } catch {
            let failed = await context.source.snapshot()
            XCTAssertNil(failed.freshClockEvidence)
        }
        try await context.session.setSimulatedError(nil, forAPI: .appStoreSync)
        try await context.source.restore(refreshAppTransaction: false)
        let syncOnly = await context.source.snapshot()
        XCTAssertNil(syncOnly.freshClockEvidence)
        try storeKitEvent("restore-clock-evidence", ["explicitRefresh": "verified-xcode", "failedSyncClearsFreshEvidence": "true"])
    }

    func testAppTransactionFailureCannotGrantOriginalPurchaserOrRestoreSuccess() async throws {
        let context = try await storeKitContext()
        try await context.session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .appTransaction)
        let snapshot = await context.source.snapshot()
        guard case .unavailable = snapshot.appPurchase else {
            throw StoreKitProTestFailure.assertion("The AppTransaction API failure was not represented as unavailable.")
        }
        let service = await context.makeService()
        XCTAssertFalse(service.hasAccess)
        do {
            _ = try await service.restore()
            XCTFail("A failed conditional AppTransaction refresh unexpectedly reported a Restore result.")
        } catch {
            XCTAssertNil(service.command)
            XCTAssertFalse(service.hasAccess)
            let failed = await context.source.snapshot()
            XCTAssertNil(failed.freshClockEvidence)
        }
        try await context.session.setSimulatedError(nil, forAPI: .appTransaction)
        let result = try await service.restore()
        XCTAssertEqual(result, .noPurchases)
        XCTAssertFalse(service.hasAccess)
        try storeKitEvent("app-transaction-error", ["originalPurchaser": "false", "recoveredRestore": "noPurchases"])
    }
}
