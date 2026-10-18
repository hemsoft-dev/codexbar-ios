import Foundation
import StoreKit
import XCTest
@testable import CodexBarIOS

@MainActor
final class StoreKitProStoreSourceTests: XCTestCase {
    func testCatalogMapsLivePricesPeriodsOfferAndEligibility() async throws {
        let context = try await storeKitContext()
        try await storeKitAwaitInitialTrialEligibility()
        try storeKitEvent("catalog-before-native-lookup")
        let native = try await storeKitProducts()
        try storeKitEvent("catalog-after-native-lookup")
        try storeKitEvent("catalog-before-adapter-lookup")
        let catalog = try await context.source.catalog()
        try storeKitEvent("catalog-after-adapter-lookup")
        XCTAssertEqual(Set(catalog.products.keys), Set(ProProductID.allCases))
        for product in ProProductID.allCases {
            let original = try XCTUnwrap(native[product])
            let mapped = try XCTUnwrap(catalog.products[product])
            XCTAssertEqual(mapped.displayName, original.displayName)
            XCTAssertEqual(mapped.displayPrice, original.displayPrice)
            XCTAssertFalse(mapped.displayPrice.isEmpty)
            XCTAssertTrue(mapped.hasExpectedShape)
            XCTAssertEqual(mapped.subscriptionGroupID, original.subscription?.subscriptionGroupID)
        }
        XCTAssertEqual(native[.monthly]?.price, Decimal(string: "1.99"))
        XCTAssertEqual(native[.yearly]?.price, Decimal(string: "14.99"))
        XCTAssertEqual(native[.lifetime]?.price, Decimal(string: "29.99"))
        XCTAssertEqual(native[.lifetime]?.type, .nonConsumable)
        XCTAssertEqual(native[.monthly]?.subscription?.subscriptionPeriod.unit, .month)
        XCTAssertEqual(native[.yearly]?.subscription?.subscriptionPeriod.unit, .year)
        let offer = try XCTUnwrap(native[.yearly]?.subscription?.introductoryOffer)
        XCTAssertEqual(offer.paymentMode, .freeTrial)
        XCTAssertEqual(offer.period.unit, .week)
        XCTAssertEqual(offer.period.value, 1)
        XCTAssertEqual(offer.periodCount, 1)
        XCTAssertEqual(catalog.products[.yearly]?.introEligibility, .eligible)
        XCTAssertEqual(catalog.products[.yearly]?.offersSevenDayTrial, true)
        XCTAssertEqual(catalog.products[.monthly]?.offersSevenDayTrial, false)
        XCTAssertEqual(catalog.products[.lifetime]?.offersSevenDayTrial, false)
        try storeKitEvent("catalog-us", [
            "monthly": try XCTUnwrap(catalog.products[.monthly]?.displayPrice),
            "yearly": try XCTUnwrap(catalog.products[.yearly]?.displayPrice),
            "lifetime": try XCTUnwrap(catalog.products[.lifetime]?.displayPrice),
            "yearlyTrialEligible": "true",
        ])
    }

    func testMonthlyPurchaseCommitsXcodeAccessAndFinishes() async throws {
        let context = try await storeKitContext()
        try storeKitEvent("monthly-before-start")
        let service = await context.makeService()
        try storeKitEvent("monthly-after-start")
        try storeKitEvent("monthly-before-catalog")
        await service.loadCatalog()
        try storeKitEvent("monthly-after-catalog")
        let product = try XCTUnwrap(service.catalog.loadedCatalog?.products[.monthly])
        try storeKitEvent("monthly-before-purchase")
        let result = try await service.purchase(.monthly, expectedProduct: product)
        try storeKitEvent("monthly-after-purchase")
        XCTAssertEqual(result, .purchased)
        XCTAssertTrue(service.hasAccess)
        XCTAssertEqual(service.value.reason, .monthly)
        XCTAssertEqual(service.value.environment, .xcode)
        XCTAssertEqual(context.cache.load(environment: .xcode), service.value)
        XCTAssertNil(context.cache.load(environment: .production))
        let purchaseSnapshot = await context.source.snapshot()
        let purchased = try XCTUnwrap(purchaseSnapshot.purchases.first { $0.product == .monthly })
        try storeKitEvent("monthly-transaction-readback", await storeKitState(
            context, service: service, purchasedTransactionID: purchased.transactionID
        ))
        do {
            try await storeKitEventually("The committed monthly purchase remained unfinished.") {
                await self.storeKitUnfinishedProducts().isEmpty
            }
        } catch {
            try storeKitEvent("monthly-unfinished-timeout", await storeKitState(
                context, service: service, purchasedTransactionID: purchased.transactionID
            ))
            throw error
        }
        let snapshot = await context.source.snapshot()
        XCTAssertTrue(snapshot.purchases.contains { $0.product == .monthly && !$0.isFreeTrial })
        try storeKitEvent("monthly-committed", ["access": "monthly", "environment": "xcode", "unfinished": "0"])
    }

    func testRawMonthlyDeliveryFinishesThroughAdapter() async throws {
        let context = try await storeKitContext()
        await context.observeTransactionsWithoutFinishing()
        try await requireRawMonthlyFinish(context, phase: "raw-monthly")
    }

    func testRawMonthlyDeliveryWithStorefrontObserverFinishes() async throws {
        let context = try await storeKitContext()
        await context.observeTransactionsWithoutFinishing()
        await observeRawStorefront(context)
        try await requireRawMonthlyFinish(context, phase: "raw-monthly-with-storefront")
    }

    func testRawMonthlyDeliveryAfterInitialSnapshotFinishes() async throws {
        let context = try await storeKitContext()
        await context.observeTransactionsWithoutFinishing()
        await observeRawStorefront(context)
        let initial = await context.source.snapshot()
        XCTAssertTrue(initial.purchases.isEmpty)
        XCTAssertTrue(initial.unverifiedPurchases.isEmpty)
        XCTAssertTrue(initial.subscriptionStatusAvailable)
        try await requireRawMonthlyFinish(context, phase: "raw-monthly-with-prior-snapshot")
    }

    func testRawMonthlyDeliveryFinishesBeforeAnyQueueReadback() async throws {
        let context = try await storeKitContext()
        await context.observeTransactionsWithoutFinishing()
        await observeRawStorefront(context)
        let initial = await context.source.snapshot()
        XCTAssertTrue(initial.purchases.isEmpty)
        XCTAssertTrue(initial.unverifiedPurchases.isEmpty)
        XCTAssertTrue(initial.subscriptionStatusAvailable)
        let catalog = try await context.source.catalog()
        let monthly = try XCTUnwrap(catalog.products[.monthly])
        let outcome = try await context.source.purchase(.monthly, expectedProduct: monthly, authorize: {})
        guard case let .purchased(delivery) = outcome, case let .verified(purchased) = delivery.evidence else {
            throw StoreKitProTestFailure.assertion("The immediate-finish purchase did not return a verified actual delivery.")
        }
        await delivery.finish()
        _ = try storeKitDelivery(outcome, product: .monthly)
        try storeKitEvent("raw-monthly-immediate-finish-returned", await storeKitUnfinishedReadback(
            matchingPurchasedTransactionID: purchased.transactionID
        ))
        _ = try await context.source.catalog()
        let snapshot = await context.source.snapshot()
        XCTAssertTrue(snapshot.purchases.contains { $0.product == .monthly && $0.transactionID == purchased.transactionID })
        try storeKitEvent("raw-monthly-immediate-after-catalog-and-snapshot", await storeKitUnfinishedReadback(
            matchingPurchasedTransactionID: purchased.transactionID
        ))
        do {
            try await storeKitEventually("The actual monthly adapter delivery remained unfinished after immediate finish without prior queue readback.") {
                await self.storeKitUnfinishedProducts().isEmpty
            }
        } catch {
            try storeKitEvent("raw-monthly-immediate-unfinished-timeout", await storeKitUnfinishedReadback(
                matchingPurchasedTransactionID: purchased.transactionID
            ))
            throw error
        }
    }

    func testRecordedServiceMonthlyFinishUsesOriginalAdapterClosure() async throws {
        let context = try await storeKitContext()
        let recording = StoreKitProFinishRecordingSource(context: context)
        let service = await context.makeService(source: recording)
        await service.loadCatalog()
        let product = try XCTUnwrap(service.catalog.loadedCatalog?.products[.monthly])
        let result = try await service.purchase(.monthly, expectedProduct: product)
        XCTAssertEqual(result, .purchased)
        XCTAssertEqual(service.value.reason, .monthly)
        XCTAssertEqual(context.cache.load(environment: .xcode), service.value)
        let transactionID = try XCTUnwrap(recording.purchasedTransactionID)
        var details = recording.readback(matching: transactionID)
        details.merge(await storeKitUnfinishedReadback(matchingPurchasedTransactionID: transactionID)) { _, fresh in fresh }
        try storeKitEvent("recorded-service-monthly-returned", details)
        XCTAssertTrue(recording.completedFinish(matching: transactionID))
        do {
            try await storeKitEventually("The recorded service monthly purchase remained unfinished.") {
                await self.storeKitUnfinishedProducts().isEmpty
            }
        } catch {
            var failed = recording.readback(matching: transactionID)
            failed.merge(await storeKitUnfinishedReadback(matchingPurchasedTransactionID: transactionID)) { _, fresh in fresh }
            try storeKitEvent("recorded-service-monthly-timeout", failed)
            throw error
        }
    }

    func testRecordedMonthlyPurchaseWithoutServiceConsumersFinishes() async throws {
        let context = try await storeKitContext()
        await context.observeTransactionsWithoutFinishing()
        let recording = StoreKitProFinishRecordingSource(context: context)
        let service = await context.makeService(start: false, source: recording)
        await service.refresh()
        await service.loadCatalog()
        let product = try XCTUnwrap(service.catalog.loadedCatalog?.products[.monthly])
        let result = try await service.purchase(.monthly, expectedProduct: product)
        XCTAssertEqual(result, .purchased)
        XCTAssertEqual(service.value.reason, .monthly)
        XCTAssertEqual(context.cache.load(environment: .xcode), service.value)
        let transactionID = try XCTUnwrap(recording.purchasedTransactionID)
        var details = recording.readback(matching: transactionID)
        details["schedulingCaveat"] = "passive native transaction observer; no service transaction or status consumers; storefront observer remains"
        details.merge(await storeKitUnfinishedReadback(matchingPurchasedTransactionID: transactionID)) { _, fresh in fresh }
        try storeKitEvent("recorded-monthly-without-service-consumers-returned", details)
        XCTAssertTrue(recording.completedFinish(matching: transactionID))
        do {
            try await storeKitEventually("The recorded monthly purchase without service transaction or status consumers remained unfinished.") {
                await self.storeKitUnfinishedProducts().isEmpty
            }
        } catch {
            var failed = recording.readback(matching: transactionID)
            failed["schedulingCaveat"] = "passive native transaction observer; no service transaction or status consumers; storefront observer remains"
            failed.merge(await storeKitUnfinishedReadback(matchingPurchasedTransactionID: transactionID)) { _, fresh in fresh }
            try storeKitEvent("recorded-monthly-without-service-consumers-timeout", failed)
            throw error
        }
    }

    func testYearlyPurchaseMapsTrialThenOrdinaryRenewalAndEligibility() async throws {
        let context = try await storeKitContext()
        try await storeKitAwaitInitialTrialEligibility()
        let service = await context.makeService()
        await service.loadCatalog()
        let product = try XCTUnwrap(service.catalog.loadedCatalog?.products[.yearly])
        XCTAssertTrue(product.offersSevenDayTrial)
        let result = try await service.purchase(.yearly, expectedProduct: product)
        XCTAssertEqual(result, .purchased)
        XCTAssertEqual(service.value.reason, .trial)
        XCTAssertTrue(service.hasAccess)
        XCTAssertEqual(context.cache.load(environment: .xcode), service.value)
        let trialSnapshot = await context.source.snapshot()
        let trial = try XCTUnwrap(trialSnapshot.purchases.first { $0.product == .yearly })
        XCTAssertTrue(trial.isFreeTrial)
        XCTAssertNotNil(trial.expiresAt)
        let afterPurchase = try await context.source.catalog()
        XCTAssertEqual(afterPurchase.products[.yearly]?.introEligibility, .ineligible)
        XCTAssertEqual(afterPurchase.products[.yearly]?.offersSevenDayTrial, false)
        try context.session.forceRenewalOfSubscription(productIdentifier: ProProductID.yearly.rawValue)
        try await storeKitEventually("The real post-trial renewal did not arrive through the service listeners.") {
            service.value.reason == .yearly
        }
        let renewed = await context.source.snapshot()
        XCTAssertTrue(renewed.purchases.contains { $0.product == .yearly && !$0.isFreeTrial })
        XCTAssertEqual(service.value.reason, .yearly)
        try await storeKitEventually("The post-trial renewal remained unfinished.") {
            await self.storeKitUnfinishedProducts().isEmpty
        }
        try storeKitEvent("yearly-trial-renewed", ["initialAccess": "trial", "renewedAccess": "yearly", "eligibleAfterPurchase": "false"])
    }

    func testLifetimePurchaseCommitsThenRestoreAndFreshServiceRetainIt() async throws {
        let context = try await storeKitContext()
        let service = await context.makeService()
        await service.loadCatalog()
        let product = try XCTUnwrap(service.catalog.loadedCatalog?.products[.lifetime])
        let result = try await service.purchase(.lifetime, expectedProduct: product)
        XCTAssertEqual(result, .purchased)
        XCTAssertEqual(service.value.reason, .lifetime)
        XCTAssertNil(service.value.expiresAt)
        XCTAssertNil(service.value.proAccessEndsAt)
        XCTAssertEqual(context.cache.load(environment: .xcode), service.value)
        let restored = try await service.restore()
        XCTAssertEqual(restored, .restored)
        XCTAssertEqual(service.value.reason, .lifetime)
        await service.stopAndWait()
        let fresh = await context.makeService(source: StoreKitProStoreSource())
        XCTAssertTrue(fresh.hasAccess)
        XCTAssertEqual(fresh.value.reason, .lifetime)
        XCTAssertEqual(fresh.value.environment, .xcode)
        XCTAssertNotEqual(fresh.value.reason, .originalPurchaser)
        try await storeKitEventually("The committed lifetime purchase remained unfinished.") {
            await self.storeKitUnfinishedProducts().isEmpty
        }
        try storeKitEvent("lifetime-restored", ["committed": "true", "freshServiceAccess": "lifetime", "originalPurchaser": "false"])
    }

    func testRefundIsReadFromLatestHistoryByFreshSourceAndRevokesCache() async throws {
        let context = try await storeKitContext()
        let service = await context.makeService()
        await service.loadCatalog()
        let product = try XCTUnwrap(service.catalog.loadedCatalog?.products[.lifetime])
        let result = try await service.purchase(.lifetime, expectedProduct: product)
        XCTAssertEqual(result, .purchased)
        let transaction = try XCTUnwrap(context.session.allTransactions().first)
        await service.stopAndWait()
        try context.session.refundTransaction(identifier: transaction.identifier)
        try await storeKitEventually("Refunded lifetime remained in current entitlements.") {
            await !self.storeKitCurrentProducts().contains(ProProductID.lifetime.rawValue)
        }
        let source = StoreKitProStoreSource()
        let snapshot = await source.snapshot()
        XCTAssertTrue(snapshot.purchases.contains { $0.product == .lifetime && $0.revoked })
        XCTAssertTrue(snapshot.unverifiedPurchases.isEmpty)
        let fresh = await context.makeService(source: source)
        XCTAssertFalse(fresh.hasAccess)
        XCTAssertEqual(fresh.value.reason, .none)
        XCTAssertEqual(context.cache.load(environment: .xcode)?.reason, ProEntitlementReason.none)
        let restored = try await fresh.restore()
        XCTAssertEqual(restored, .noPurchases)
        XCTAssertFalse(fresh.hasAccess)
        try storeKitEvent("refunded-latest-history", ["currentEntitlements": "empty", "latestHistoryRevoked": "true", "cachedAccess": "none"])
    }

    func testAskToBuyApprovalArrivesThroughProductionTransactionStream() async throws {
        let context = try await storeKitContext()
        context.session.askToBuyEnabled = true
        let service = await context.makeService()
        await service.loadCatalog()
        let product = try XCTUnwrap(service.catalog.loadedCatalog?.products[.lifetime])
        let result = try await service.purchase(.lifetime, expectedProduct: product)
        XCTAssertEqual(result, .pending)
        XCTAssertFalse(service.hasAccess)
        let pending = try XCTUnwrap(context.session.allTransactions().first { $0.pendingAskToBuyConfirmation })
        try context.session.approveAskToBuyTransaction(identifier: pending.identifier)
        try await storeKitEventually("Approved Ask to Buy did not reach the production service stream.") {
            service.hasAccess && service.value.reason == .lifetime
        }
        XCTAssertEqual(context.cache.load(environment: .xcode), service.value)
        try await storeKitEventually("Approved Ask to Buy was not finished after persistence.") {
            await self.storeKitUnfinishedProducts().isEmpty
        }
        try storeKitEvent("ask-to-buy-approved", ["purchaseResult": "pending", "approvedAccess": "lifetime", "unfinished": "0"])
    }

    private func observeRawStorefront(_ context: StoreKitProTestContext) async {
        let storefronts = context.source.storefrontUpdates()
        context.retainListener(Task {
            for await _ in storefronts {
                guard !Task.isCancelled else { return }
            }
        })
        await Task.yield()
    }

    private func requireRawMonthlyFinish(_ context: StoreKitProTestContext, phase: String) async throws {
        let catalog = try await context.source.catalog()
        let monthly = try XCTUnwrap(catalog.products[.monthly])
        let outcome = try await context.source.purchase(.monthly, expectedProduct: monthly, authorize: {})
        let delivery = try storeKitDelivery(outcome, product: .monthly)
        guard case let .verified(purchased) = delivery.evidence else {
            throw StoreKitProTestFailure.assertion("The actual monthly adapter delivery was not verified.")
        }
        let before = await storeKitUnfinishedTransactions()
        XCTAssertTrue(before.contains { $0.transaction.id == purchased.transactionID && $0.verified })
        try storeKitEvent(phase + "-before-finish", await storeKitUnfinishedReadback(
            matchingPurchasedTransactionID: purchased.transactionID
        ))
        await delivery.finish()
        try storeKitEvent(phase + "-finish-returned", await storeKitUnfinishedReadback(
            matchingPurchasedTransactionID: purchased.transactionID
        ))
        _ = try await context.source.catalog()
        let snapshot = await context.source.snapshot()
        XCTAssertTrue(snapshot.purchases.contains { $0.product == .monthly && $0.transactionID == purchased.transactionID })
        try storeKitEvent(phase + "-after-catalog-and-snapshot", await storeKitUnfinishedReadback(
            matchingPurchasedTransactionID: purchased.transactionID
        ))
        do {
            try await storeKitEventually("The actual monthly adapter delivery remained unfinished after its finish closure returned: " + phase) {
                await self.storeKitUnfinishedProducts().isEmpty
            }
        } catch {
            try storeKitEvent(phase + "-unfinished-timeout", await storeKitUnfinishedReadback(
                matchingPurchasedTransactionID: purchased.transactionID
            ))
            throw error
        }
    }
}

/// Run only after the Germany preparation method exits in a separate process.
@MainActor
final class StoreKitProStorefrontTests: XCTestCase {
    func testCatalogUsesPreparedGermanyStorefrontAndLocale() async throws {
        let context = try await storeKitContext(storefront: "DEU", locale: Locale(identifier: "de_DE"))
        let current = await Storefront.current
        let storefront = try XCTUnwrap(current)
        XCTAssertEqual(storefront.countryCode, "DEU")
        XCTAssertEqual(context.session.storefront, storefront.countryCode)
        let native = try await storeKitProducts()
        let catalog = try await context.source.catalog()
        XCTAssertEqual(catalog.storefrontID, storefront.id)
        for product in ProProductID.allCases {
            let original = try XCTUnwrap(native[product])
            let mapped = try XCTUnwrap(catalog.products[product])
            XCTAssertFalse(original.displayPrice.isEmpty)
            XCTAssertEqual(original.priceFormatStyle.currencyCode, "EUR")
            XCTAssertEqual(mapped.displayPrice, original.displayPrice)
            XCTAssertEqual(mapped.storefrontID, storefront.id)
        }
        try storeKitEvent("catalog-germany-prepared", [
            "nativeStorefront": storefront.countryCode,
            "nativeStorefrontID": storefront.id,
            "monthly": try XCTUnwrap(catalog.products[.monthly]?.displayPrice),
            "yearly": try XCTUnwrap(catalog.products[.yearly]?.displayPrice),
            "lifetime": try XCTUnwrap(catalog.products[.lifetime]?.displayPrice),
            "scope": "prepared native storefront and exact local price mapping; hot transition not exercised",
        ])
    }
}
