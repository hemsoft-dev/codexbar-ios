import Combine
import Foundation
import XCTest
@testable import CodexBarIOS

@MainActor
final class ProCommerceCommandTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    func testUnresolvedServiceCannotStartPayment() async {
        let source = ProCommerceTestSource()
        let service = service(source)
        await expect(.checkingPurchases) { _ = try await service.purchase(.monthly) }
        XCTAssertTrue(source.purchaseCalls.isEmpty)
        XCTAssertNil(service.command)
    }

    func testPurchaseReturnsOnlyAfterSpecificGrantIsSavedPublishedAndFinished() async throws {
        let source = ProCommerceTestSource()
        let cache = TestProCache()
        let service = service(source, cache)
        await service.refreshCommerce()
        var finished = false
        source.purchaseOutcome = .purchased(delivery(.lifetime) {
            XCTAssertEqual(cache.saved?.reason, .lifetime)
            XCTAssertEqual(service.value.reason, .lifetime)
            finished = true
        })
        let result = try await service.purchase(.lifetime, expectedProduct: source.catalogValue.products[.lifetime])
        XCTAssertEqual(result, .purchased)
        XCTAssertTrue(finished)
        XCTAssertEqual(service.value.reason, .lifetime)
        XCTAssertNil(service.command)
        service.stop()
    }

    func testUnsavedLifetimeCannotReportSuccessFromPreexistingSubscription() async {
        let source = ProCommerceTestSource()
        let status = commerceTestStatus(now: instant, renews: false)
        source.next = ProStoreSnapshot(purchases: [status.purchase], subscriptions: [status], subscriptionStatusAvailable: true)
        let cache = TestProCache()
        let service = service(source, cache)
        await service.refreshCommerce()
        var finished = false
        source.purchaseOutcome = .purchased(delivery(.lifetime) { finished = true })
        source.beforePurchaseAuthorization = { cache.shouldFail = true }
        await expect(.notCommitted) { _ = try await service.purchase(.lifetime, context: .settingsLifetime) }
        XCTAssertTrue(service.hasAccess)
        XCTAssertEqual(service.value.reason, .yearly)
        XCTAssertFalse(finished)
        XCTAssertEqual(cache.saved?.reason, .yearly)
        XCTAssertNotNil(service.statusMessage)
        XCTAssertNil(service.command)
        service.stop()
    }

    func testWrongProductDeliveryCannotSatisfyLifetimeSwitch() async {
        let source = ProCommerceTestSource()
        let status = commerceTestStatus(now: instant, renews: false)
        source.next = ProStoreSnapshot(purchases: [status.purchase], subscriptions: [status], subscriptionStatusAvailable: true)
        let service = service(source)
        await service.refreshCommerce()
        source.purchaseOutcome = .purchased(ProTransactionDelivery(product: .yearly, evidence: .verified(status.purchase), finish: {}))
        await expect(.notCommitted) { _ = try await service.purchase(.lifetime, context: .settingsLifetime) }
        XCTAssertEqual(service.value.reason, .yearly)
        service.stop()
    }

    func testMismatchedDeliveryEnvelopeCannotReportCommittedRequestedProduct() async {
        let source = ProCommerceTestSource()
        let service = service(source)
        await service.refreshCommerce()
        let evidence = purchase(.monthly)
        source.purchaseOutcome = .purchased(ProTransactionDelivery(product: .lifetime, evidence: .verified(evidence), finish: {}))
        await expect(.notCommitted) { _ = try await service.purchase(.lifetime) }
        XCTAssertNotEqual(service.value.reason, .lifetime)
        service.stop()
    }

    func testUnverifiedAndUnavailableDeliveryNeverBecomeSuccess() async {
        for evidence: ProVerification<ProPurchaseEvidence> in [.unverified, .unavailable] {
            let source = ProCommerceTestSource()
            let service = service(source)
            await service.refreshCommerce()
            var finished = false
            source.purchaseOutcome = .purchased(ProTransactionDelivery(product: .yearly, evidence: evidence, environment: .production) {
                finished = true
            })
            await expect(.notCommitted) { _ = try await service.purchase(.yearly) }
            XCTAssertFalse(service.hasAccess)
            XCTAssertFalse(finished)
            XCTAssertNil(service.command)
            service.stop()
        }
    }

    func testRevokedDeliveredPurchaseCannotReportSuccess() async {
        let source = ProCommerceTestSource()
        let service = service(source)
        await service.refreshCommerce()
        var evidence = purchase(.lifetime)
        evidence.revoked = true
        source.purchaseOutcome = .purchased(ProTransactionDelivery(product: .lifetime, evidence: .verified(evidence), finish: {}))
        await expect(.notCommitted) { _ = try await service.purchase(.lifetime) }
        XCTAssertFalse(service.hasAccess)
        service.stop()
    }

    func testPurchaseAndRestoreAreSerializedAcrossAwait() async throws {
        let source = ProCommerceTestSource()
        let service = service(source)
        await service.refreshCommerce()
        let waiting = expectation(description: "Catalog request suspended")
        var resume: CheckedContinuation<Void, Never>?
        source.beforeCatalog = {
            await withCheckedContinuation { continuation in
                resume = continuation
                waiting.fulfill()
            }
        }
        let first = Task { try await service.purchase(.monthly) }
        await fulfillment(of: [waiting], timeout: 2)
        await expect(.busy) { _ = try await service.purchase(.yearly) }
        await expect(.busy) { _ = try await service.restore() }
        XCTAssertTrue(source.restoreCalls.isEmpty)
        source.beforeCatalog = nil
        resume?.resume()
        let result = try await first.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(source.purchaseCalls, [.monthly])
        XCTAssertNil(service.command)
        service.stop()
    }

    func testRestoreBlocksPurchaseAndSecondRestoreUntilCompletion() async throws {
        let source = ProCommerceTestSource()
        let service = service(source)
        await service.refreshCommerce()
        let waiting = expectation(description: "Restore suspended")
        var resume: CheckedContinuation<Void, Never>?
        source.beforeRestore = {
            await withCheckedContinuation { continuation in
                resume = continuation
                waiting.fulfill()
            }
        }
        let first = Task { try await service.restore() }
        await fulfillment(of: [waiting], timeout: 2)
        await expect(.busy) { _ = try await service.purchase(.monthly) }
        await expect(.busy) { _ = try await service.restore() }
        resume?.resume()
        let result = try await first.value
        XCTAssertEqual(result, .noPurchases)
        XCTAssertEqual(source.restoreCalls.count, 1)
        XCTAssertNil(service.command)
        service.stop()
    }

    func testNewPermanentGrantWhileCatalogLoadsBlocksPayment() async {
        let source = ProCommerceTestSource()
        let service = service(source)
        await service.refreshCommerce()
        source.beforeCatalog = { await service.receive(self.delivery(.lifetime)) }
        await expect(.alreadyHasPro) { _ = try await service.purchase(.monthly) }
        XCTAssertTrue(source.purchaseCalls.isEmpty)
        XCTAssertEqual(service.value.reason, .lifetime)
        service.stop()
    }

    func testFinalAuthorizationRejectsEntitlementChangedInsideAdapterAwait() async {
        let source = ProCommerceTestSource()
        let service = service(source)
        await service.refreshCommerce()
        source.beforePurchaseAuthorization = { await service.receive(self.delivery(.lifetime)) }
        await expect(.alreadyHasPro) { _ = try await service.purchase(.yearly) }
        XCTAssertTrue(source.purchaseCalls.isEmpty)
        XCTAssertNil(service.command)
        service.stop()
    }

    func testUncommittedLifetimeDuringCatalogBlocksMonthlyPayment() async {
        await assertUncommittedLifetimeBlocksPayment(.monthly, atAdapterBoundary: false)
    }

    func testUncommittedLifetimeDuringCatalogBlocksYearlyPayment() async {
        await assertUncommittedLifetimeBlocksPayment(.yearly, atAdapterBoundary: false)
    }

    func testUncommittedLifetimeDuringAdapterAuthorizationBlocksMonthlyPayment() async {
        await assertUncommittedLifetimeBlocksPayment(.monthly, atAdapterBoundary: true)
    }

    func testUncommittedLifetimeDuringAdapterAuthorizationBlocksYearlyPayment() async {
        await assertUncommittedLifetimeBlocksPayment(.yearly, atAdapterBoundary: true)
    }

    func testSuccessfulUnrelatedStreamSaveCannotRestorePaymentAuthorization() async throws {
        let source = ProCommerceTestSource()
        let cache = TestProCache()
        let service = service(source, cache)
        await service.refreshCommerce()
        let expiredYearly = commerceTestStatus(.yearly, now: instant, renews: false, state: .expired, offset: -1).purchase
        let expiredMonthly = commerceTestStatus(.monthly, now: instant, renews: false, state: .expired, offset: -1).purchase
        source.beforeCatalog = {
            cache.shouldFail = true
            await service.receive(ProTransactionDelivery(product: .yearly, evidence: .verified(expiredYearly), finish: {}))
            cache.shouldFail = false
            await service.receive(ProTransactionDelivery(product: .monthly, evidence: .verified(expiredMonthly), finish: {}))
            XCTAssertNotNil(cache.saved)
            XCTAssertNil(service.statusMessage, "The unrelated stream delivery was saved successfully.")
            XCTAssertFalse(service.hasAccess)
        }
        await expect(.notCommitted) { _ = try await service.purchase(.monthly) }
        XCTAssertTrue(source.purchaseCalls.isEmpty)
        source.beforeCatalog = nil
        let restored = try await service.restore()
        XCTAssertEqual(restored, .noPurchases)
        let retry = try await service.purchase(.monthly)
        XCTAssertEqual(retry, .cancelled)
        XCTAssertEqual(source.purchaseCalls, [.monthly], "A complete committed refresh must permit a legitimate retry.")
        await service.stopAndWait()
    }

    func testRestoreCommitsUnsavedLifetimeWithoutAllowingAnotherCharge() async throws {
        let source = ProCommerceTestSource()
        let cache = TestProCache()
        let service = service(source, cache)
        await service.refreshCommerce()
        source.beforeCatalog = {
            cache.shouldFail = true
            await service.receive(self.delivery(.lifetime))
            cache.shouldFail = false
        }
        await expect(.notCommitted) { _ = try await service.purchase(.yearly) }
        source.beforeCatalog = nil
        source.next.purchases = [purchase(.lifetime)]
        let restored = try await service.restore()
        XCTAssertEqual(restored, .restored)
        XCTAssertEqual(cache.saved?.reason, .lifetime)
        XCTAssertEqual(service.value.reason, .lifetime)
        XCTAssertNil(service.statusMessage)
        for product in ProProductID.allCases {
            await expect(.alreadyHasPro) { _ = try await service.purchase(product) }
        }
        XCTAssertTrue(source.purchaseCalls.isEmpty)
        await service.stopAndWait()
    }

    func testUnverifiedRefreshCannotClearFailedCommitBeforeOwnershipRecovers() async throws {
        let source = ProCommerceTestSource()
        let cache = TestProCache()
        let service = service(source, cache)
        await service.refreshCommerce()
        source.beforeCatalog = {
            cache.shouldFail = true
            await service.receive(self.delivery(.lifetime))
            cache.shouldFail = false
        }
        await expect(.notCommitted) { _ = try await service.purchase(.monthly) }
        source.beforeCatalog = nil
        source.next.unverifiedPurchases = [ProUnverifiedPurchase(product: .lifetime, environment: .production)]
        await service.refresh()
        XCTAssertFalse(service.hasAccess)
        XCTAssertNotNil(service.statusMessage)
        await expect(.notCommitted) { _ = try await service.purchase(.yearly) }
        XCTAssertTrue(source.purchaseCalls.isEmpty)
        source.next.unverifiedPurchases = []
        source.next.purchases = [purchase(.lifetime)]
        let restored = try await service.restore()
        XCTAssertEqual(restored, .restored)
        XCTAssertEqual(service.value.reason, .lifetime)
        await service.stopAndWait()
    }

    func testRenewalReenabledDuringLifetimeConfirmationBlocksBeforePayment() async {
        let source = ProCommerceTestSource()
        let off = commerceTestStatus(now: instant, renews: false)
        source.next = ProStoreSnapshot(purchases: [off.purchase], subscriptions: [off], subscriptionStatusAvailable: true)
        let service = service(source)
        await service.refreshCommerce()
        XCTAssertEqual(service.commerce.lifetimeAction, .available)
        source.beforePurchaseAuthorization = {
            await service.receive(ProSubscriptionEvidence(
                purchase: off.purchase, signedAt: self.instant.addingTimeInterval(1), state: .subscribed,
                renewalVerified: true, willAutoRenew: true, isInBillingRetry: false, graceEndsAt: nil
            ))
        }
        await expect(.autoRenewEnabled) { _ = try await service.purchase(.lifetime, context: .settingsLifetime) }
        XCTAssertTrue(source.purchaseCalls.isEmpty)
        service.stop()
    }

    func testExpiredTransactionWithoutRenewalStatusDuringCatalogWaitBlocksLifetime() async {
        let source = ProCommerceTestSource()
        let service = service(source)
        await service.refreshCommerce()
        let expired = ProPurchaseEvidence(
            product: .yearly, transactionID: 21, purchasedAt: instant.addingTimeInterval(-86400),
            signedAt: instant, expiresAt: instant.addingTimeInterval(-3600)
        )
        source.beforeCatalog = {
            await service.receive(ProTransactionDelivery(product: .yearly, evidence: .verified(expired), finish: {}))
        }
        await expect(.renewalUnknown) { _ = try await service.purchase(.lifetime) }
        XCTAssertFalse(service.hasAccess)
        XCTAssertEqual(service.currentStatusProducts, [.yearly])
        XCTAssertTrue(service.subscriptionStatuses.isEmpty)
        XCTAssertTrue(source.purchaseCalls.isEmpty)
        source.beforeCatalog = nil
        await service.stopAndWait()
    }

    func testUncommittedRenewalOnCannotAuthorizeFromPublishedOffStatus() async {
        let source = ProCommerceTestSource()
        let off = commerceTestStatus(now: instant, renews: false)
        source.next = ProStoreSnapshot(purchases: [off.purchase], subscriptions: [off], subscriptionStatusAvailable: true)
        let cache = TestProCache()
        let service = service(source, cache)
        await service.refreshCommerce()
        XCTAssertEqual(service.commerce.lifetimeAction, .available)
        source.beforeCatalog = {
            cache.shouldFail = true
            await service.receive(ProSubscriptionEvidence(
                purchase: off.purchase, signedAt: self.instant.addingTimeInterval(1), state: .subscribed,
                renewalVerified: true, willAutoRenew: true, isInBillingRetry: false, graceEndsAt: nil
            ))
            cache.shouldFail = false
        }
        await expect(.notCommitted) { _ = try await service.purchase(.lifetime, context: .settingsLifetime) }
        XCTAssertTrue(service.hasAccess)
        XCTAssertFalse(service.subscriptionStatusAvailable)
        XCTAssertEqual(service.commerce.lifetimeAction, .unavailable)
        XCTAssertNotNil(service.statusMessage)
        XCTAssertTrue(source.purchaseCalls.isEmpty)
        source.beforeCatalog = nil
        await service.stopAndWait()
    }

    func testChangedPriceOrEligibilityRequiresReviewWithoutPayment() async {
        for changed in [commerceTestCatalog(yearlyPrice: "$19.99"), commerceTestCatalog(eligibility: .ineligible)] {
            let source = ProCommerceTestSource()
            let service = service(source)
            await service.refreshCommerce()
            let shown = service.catalog.loadedCatalog?.products[.yearly]
            source.catalogValue = changed
            await expect(.termsChanged) { _ = try await service.purchase(.yearly, expectedProduct: shown) }
            XCTAssertTrue(source.purchaseCalls.isEmpty)
            XCTAssertEqual(service.catalog.loadedCatalog, changed)
            service.stop()
        }
    }

    func testCancelledCommandClearsBusyWithoutPayment() async {
        let source = ProCommerceTestSource()
        let service = service(source)
        await service.refreshCommerce()
        let waiting = expectation(description: "Catalog request suspended")
        var resume: CheckedContinuation<Void, Never>?
        source.beforeCatalog = {
            await withCheckedContinuation { continuation in
                resume = continuation
                waiting.fulfill()
            }
        }
        let command = Task { try await service.purchase(.yearly) }
        await fulfillment(of: [waiting], timeout: 2)
        command.cancel()
        source.beforeCatalog = nil
        resume?.resume()
        do { _ = try await command.value; XCTFail("Canceled work must not start payment") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(source.purchaseCalls.isEmpty)
        XCTAssertNil(service.command)
        service.stop()
    }

    func testPurchasePendingCancellationAndErrorsRemainDistinctAndRetryable() async throws {
        let source = ProCommerceTestSource()
        let service = service(source)
        await service.refreshCommerce()
        source.purchaseOutcome = .pending
        let pending = try await service.purchase(.monthly)
        XCTAssertEqual(pending, .pending)
        source.purchaseOutcome = .cancelled
        let cancelled = try await service.purchase(.monthly)
        XCTAssertEqual(cancelled, .cancelled)
        source.purchaseError = CocoaError(.fileReadUnknown)
        do { _ = try await service.purchase(.monthly); XCTFail("Expected injected purchase error") } catch {
            XCTAssertEqual(error as? CocoaError, CocoaError(.fileReadUnknown))
        }
        XCTAssertNil(service.command)
        XCTAssertFalse(service.hasAccess)
        source.purchaseError = nil
        let retried = try await service.purchase(.monthly)
        XCTAssertEqual(retried, .cancelled)
        service.stop()
    }

    func testRestoreReportsNoPurchaseCommittedAccessErrorAndCancellation() async throws {
        let source = ProCommerceTestSource()
        let service = service(source)
        await service.refreshCommerce()
        let empty = try await service.restore()
        XCTAssertEqual(empty, .noPurchases)
        source.next.purchases = [purchase(.lifetime)]
        let restored = try await service.restore()
        XCTAssertEqual(restored, .restored)
        source.restoreError = CancellationError()
        do { _ = try await service.restore(); XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(service.command)
        source.restoreError = CocoaError(.fileReadUnknown)
        do { _ = try await service.restore(); XCTFail("Expected Restore error") } catch {
            XCTAssertEqual(error as? CocoaError, CocoaError(.fileReadUnknown))
        }
        XCTAssertNil(service.command)
        service.stop()
    }

    func testRestoreStorageFailureCannotClaimPreexistingAccessWasRestored() async {
        let source = ProCommerceTestSource()
        source.next.purchases = [purchase(.lifetime)]
        let cache = TestProCache()
        let service = service(source, cache)
        await service.refreshCommerce()
        cache.shouldFail = true
        await expect(.notCommitted) { _ = try await service.restore() }
        XCTAssertTrue(service.hasAccess)
        XCTAssertNotNil(service.statusMessage)
        XCTAssertNil(service.command)
        service.stop()
    }

    private func assertUncommittedLifetimeBlocksPayment(_ product: ProProductID, atAdapterBoundary: Bool) async {
        let source = ProCommerceTestSource()
        let cache = TestProCache()
        let service = service(source, cache)
        await service.refreshCommerce()
        var delivered = false
        var finished = false
        let receiveUnsavedGrant = {
            cache.shouldFail = true
            let accepted = await service.receive(self.delivery(.lifetime) { finished = true })
            cache.shouldFail = false
            delivered = true
            XCTAssertFalse(accepted)
        }
        if atAdapterBoundary {
            source.beforePurchaseAuthorization = receiveUnsavedGrant
        } else {
            source.beforeCatalog = receiveUnsavedGrant
        }
        await expect(.notCommitted) { _ = try await service.purchase(product) }
        XCTAssertTrue(delivered, "The verified lifetime grant must arrive inside the purchase suspension.")
        XCTAssertFalse(finished, "An unsaved grant must remain unfinished.")
        XCTAssertFalse(service.hasAccess, "Failed persistence still denies feature access.")
        XCTAssertEqual(service.value.reason, .none)
        XCTAssertNotEqual(cache.saved?.reason, .lifetime)
        XCTAssertNotNil(service.statusMessage)
        XCTAssertTrue(source.purchaseCalls.isEmpty, "Known ownership that failed to save must not permit another charge.")
        XCTAssertNil(service.command)
        source.beforeCatalog = nil
        source.beforePurchaseAuthorization = nil
        await service.stopAndWait()
    }

    private func service(_ source: ProCommerceTestSource, _ cache: TestProCache? = nil) -> ProEntitlement {
        ProEntitlement(source: source, cache: cache ?? TestProCache(), now: { self.instant }, clock: testProClock)
    }

    private func purchase(_ product: ProProductID) -> ProPurchaseEvidence {
        ProPurchaseEvidence(
            product: product, transactionID: 11, purchasedAt: instant, signedAt: instant,
            expiresAt: product == .lifetime ? nil : instant.addingTimeInterval(3600)
        )
    }

    private func delivery(_ product: ProProductID, finish: @escaping @MainActor () async -> Void = {}) -> ProTransactionDelivery {
        ProTransactionDelivery(product: product, evidence: .verified(purchase(product)), environment: .production, finish: finish)
    }

    private func expect(_ expected: ProCommerceError, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") } catch {
            XCTAssertEqual(error as? ProCommerceError, expected)
        }
    }
}
