import Foundation
import StoreKit
import StoreKitTest
import XCTest
@testable import CodexBarIOS

@MainActor
final class StoreKitProSubscriptionTests: XCTestCase {
    func testVerifiedRenewalMetadataMatchesApplePayloadExactly() async throws {
        let context = try await storeKitContext()
        let service = await context.makeService()
        await service.loadCatalog()
        let product = try XCTUnwrap(service.catalog.loadedCatalog?.products[.yearly])
        let result = try await service.purchase(.yearly, expectedProduct: product)
        XCTAssertEqual(result, .purchased)
        let products = try await storeKitProducts()
        let subscription = try XCTUnwrap(products[.yearly]?.subscription)
        let statuses = try await subscription.status
        let native = try XCTUnwrap(statuses.first)
        guard case let .verified(transaction) = native.transaction, case let .verified(renewal) = native.renewalInfo else {
            throw StoreKitProTestFailure.assertion("Native subscription status did not contain verified transaction and renewal payloads.")
        }
        // Compare the production mapper with this exact verified payload. A
        // separate status query may return newly signed renewal information.
        let mapped = try XCTUnwrap(StoreKitProStoreSource.subscription(native))
        XCTAssertTrue(mapped.renewalVerified)
        XCTAssertEqual(mapped.purchase.environment, .xcode)
        XCTAssertEqual(mapped.purchase.expiresAt, transaction.expirationDate)
        XCTAssertEqual(mapped.signedAt, renewal.signedDate)
        XCTAssertEqual(mapped.willAutoRenew, renewal.willAutoRenew)
        XCTAssertEqual(mapped.nextRenewalProduct, renewal.autoRenewPreference.flatMap(ProProductID.init(rawValue:)))
        XCTAssertEqual(mapped.renewalPrice, renewal.renewalPrice)
        XCTAssertEqual(mapped.renewalCurrency, renewal.currency?.identifier)
        XCTAssertEqual(mapped.graceEndsAt, renewal.gracePeriodExpirationDate)
        XCTAssertEqual(mapped.isInBillingRetry, renewal.isInBillingRetry)
        let snapshot = await context.source.snapshot()
        let separateRead = try XCTUnwrap(snapshot.subscriptions.first { $0.purchase.transactionID == transaction.id })
        XCTAssertTrue(separateRead.renewalVerified)
        XCTAssertEqual(separateRead.purchase.environment, .xcode)
        // This real-time yearly fixture cannot renew between the two reads.
        // Only the signature date belongs to the individual signed payload.
        XCTAssertEqual(separateRead.purchase.transactionID, mapped.purchase.transactionID)
        XCTAssertEqual(separateRead.state, mapped.state)
        XCTAssertEqual(separateRead.purchase.expiresAt, mapped.purchase.expiresAt)
        XCTAssertEqual(separateRead.willAutoRenew, mapped.willAutoRenew)
        XCTAssertEqual(separateRead.nextRenewalProduct, mapped.nextRenewalProduct)
        XCTAssertEqual(separateRead.renewalPrice, mapped.renewalPrice)
        XCTAssertEqual(separateRead.renewalCurrency, mapped.renewalCurrency)
        XCTAssertEqual(separateRead.graceEndsAt, mapped.graceEndsAt)
        XCTAssertEqual(separateRead.isInBillingRetry, mapped.isInBillingRetry)
        let matchesVerifiedPayload = [
            mapped.renewalVerified, mapped.purchase.environment == .xcode,
            mapped.purchase.transactionID == transaction.id,
            mapped.purchase.expiresAt == transaction.expirationDate,
            mapped.signedAt == renewal.signedDate, mapped.willAutoRenew == renewal.willAutoRenew,
            mapped.nextRenewalProduct == renewal.autoRenewPreference.flatMap(ProProductID.init(rawValue:)),
            mapped.renewalPrice == renewal.renewalPrice, mapped.renewalCurrency == renewal.currency?.identifier,
            mapped.graceEndsAt == renewal.gracePeriodExpirationDate,
            mapped.isInBillingRetry == renewal.isInBillingRetry,
        ].allSatisfy { $0 }
        try storeKitEvent("verified-renewal-mapping", [
            "renewalPricePresent": String(mapped.renewalPrice != nil),
            "renewalCurrencyPresent": String(mapped.renewalCurrency != nil),
            "matchesVerifiedApplePayload": String(matchesVerifiedPayload),
            "oracleSignedDateEpoch": String(renewal.signedDate.timeIntervalSince1970),
            "mappedSignedDateEpoch": String(mapped.signedAt.timeIntervalSince1970),
            "separateReadSignedDateEpoch": String(separateRead.signedAt.timeIntervalSince1970),
        ])
    }

    func testAutoRenewStreamGuardsLifetimeThenTracksExternalOverlap() async throws {
        let context = try await storeKitContext()
        var observedRenewals: [Bool] = []
        let updates = context.source.subscriptionUpdates()
        context.retainListener(Task {
            for await update in updates {
                guard !Task.isCancelled else { return }
                if case let .verified(evidence) = update, let willRenew = evidence.willAutoRenew {
                    observedRenewals.append(willRenew)
                }
            }
        })
        let service = await context.makeService()
        await service.loadCatalog()
        let monthly = try XCTUnwrap(service.catalog.loadedCatalog?.products[.monthly])
        let purchased = try await service.purchase(.monthly, expectedProduct: monthly)
        XCTAssertEqual(purchased, .purchased)
        await service.refreshCommerce()
        let lifetime = try XCTUnwrap(service.catalog.loadedCatalog?.products[.lifetime])
        XCTAssertEqual(service.commerce.lifetimeAction, .manageSubscription)
        let existingCount = context.session.allTransactions().count
        do {
            _ = try await service.purchase(.lifetime, context: .settingsLifetime, expectedProduct: lifetime)
            XCTFail("Lifetime was sold while the actual subscription still renewed.")
        } catch ProCommerceError.autoRenewEnabled {
            XCTAssertEqual(context.session.allTransactions().count, existingCount)
        }
        let transaction = try XCTUnwrap(context.session.allTransactions().first { $0.productIdentifier == ProProductID.monthly.rawValue })
        try context.session.disableAutoRenewForTransaction(identifier: transaction.identifier)
        try await storeKitEventually("Verified auto-renew-off did not unlock the Settings lifetime policy.") {
            service.commerce.lifetimeAction == .available && observedRenewals.contains(false)
        }
        let switched = try await service.purchase(.lifetime, context: .settingsLifetime, expectedProduct: lifetime)
        XCTAssertEqual(switched, .purchased)
        XCTAssertEqual(service.value.reason, .lifetime)
        XCTAssertEqual(context.cache.load(environment: .xcode)?.reason, .lifetime)
        XCTAssertFalse(service.commerce.hasRenewalOverlap)
        try context.session.enableAutoRenewForTransaction(identifier: transaction.identifier)
        try await storeKitEventually("External auto-renew reactivation did not show the independent lifetime overlap warning.") {
            service.commerce.hasRenewalOverlap && observedRenewals.contains(true)
        }
        XCTAssertEqual(service.value.reason, .lifetime)
        try context.session.disableAutoRenewForTransaction(identifier: transaction.identifier)
        try await storeKitEventually("Verified auto-renew-off did not remove the overlap warning.") {
            !service.commerce.hasRenewalOverlap
        }
        try storeKitEvent("lifetime-renewal-gate-and-overlap", [
            "renewingPurchaseBlocked": "true",
            "verifiedOffSwitchCommitted": "true",
            "externalReactivationWarned": "true",
            "verifiedOffClearedWarning": "true",
        ])
    }

    func testBillingGraceMapsVerifiedStatusAndKeepsAccess() async throws {
        let context = try await storeKitContext()
        configureBillingRenewal(context, grace: true)
        XCTAssertTrue(context.session.shouldEnterBillingRetryOnRenewal)
        XCTAssertTrue(context.session.billingGracePeriodIsEnabled)
        XCTAssertEqual(context.session.timeRate, .oneRenewalEveryThirtySeconds)
        let nativeStarted = ProcessInfo.processInfo.systemUptime
        var nativeStatusTrace = [String]()
        let nativeUpdates = Product.SubscriptionInfo.Status.updates
        context.retainListener(Task {
            for await status in nativeUpdates {
                guard !Task.isCancelled else { return }
                guard case let .verified(transaction) = status.transaction,
                      transaction.productID == ProProductID.monthly.rawValue else { continue }
                if nativeStatusTrace.count < 16 {
                    nativeStatusTrace.append(Self.nativeStatusDescription(status, since: nativeStarted))
                }
            }
        })
        let service = try await purchaseMonthly(context)
        XCTAssertTrue(context.session.shouldEnterBillingRetryOnRenewal)
        XCTAssertTrue(context.session.billingGracePeriodIsEnabled)
        XCTAssertEqual(context.session.timeRate, .oneRenewalEveryThirtySeconds)
        let started = ProcessInfo.processInfo.systemUptime
        var receivedStatuses: [String] = []
        var receivedVerifiedGrace = false
        service.debugSubscriptionObservation = { status in
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            receivedStatuses.append("elapsed=\(elapsed),state=\(status.state),signed=\(status.signedAt),graceEnd=\(String(describing: status.graceEndsAt))")
            if status.state == .grace && status.renewalVerified && status.graceEndsAt != nil {
                receivedVerifiedGrace = true
            }
        }
        do {
            try await storeKitEventually("Real StoreKit billing grace did not reach the entitlement service.", timeout: 75) {
                service.value.reason == .billingGrace && service.commerce.hasBillingIssue
            }
        } catch let primaryError {
            do {
                var details = await storeKitState(context, service: service)
                details["receivedStatusTrace"] = receivedStatuses.joined(separator: ";")
                details["nativeStatusTrace"] = nativeStatusTrace.joined(separator: ";")
                details["fixtureRetryEnabled"] = String(context.session.shouldEnterBillingRetryOnRenewal)
                details["fixtureGraceEnabled"] = String(context.session.billingGracePeriodIsEnabled)
                details["fixtureTimeRate"] = String(describing: context.session.timeRate)
                let products = try await storeKitProducts()
                let subscription = try XCTUnwrap(products[.monthly]?.subscription)
                details["nativeStatusesAtTimeout"] = try await subscription.status.prefix(3).map {
                    Self.nativeStatusDescription($0, since: nativeStarted)
                }.joined(separator: ";")
                try storeKitEvent("billing-grace-timeout", details)
            } catch {
                print("Unable to preserve billing-grace diagnostics; retaining the primary failure.")
            }
            throw primaryError
        }
        let snapshot = await context.source.snapshot()
        let status = try XCTUnwrap(snapshot.subscriptions.first { $0.state == .grace })
        XCTAssertTrue(status.renewalVerified)
        XCTAssertTrue(status.isInBillingRetry)
        XCTAssertNotNil(status.graceEndsAt)
        XCTAssertTrue(service.hasAccess)
        XCTAssertEqual(service.commerce.graceEndsAt, status.graceEndsAt)
        XCTAssertNil(service.commerce.dateKind)
        XCTAssertNil(service.commerce.periodEnd, "A grace date must never be displayed as the next subscription renewal.")
        try storeKitEvent("billing-grace", [
            "access": "true", "billingIssue": "true", "verifiedGraceDate": "true",
            "receivedStatusTrace": receivedStatuses.joined(separator: ";"),
            "verifiedGraceReceiverObserved": String(receivedVerifiedGrace),
            "nativeStatusTrace": nativeStatusTrace.joined(separator: ";"),
        ])
    }

    func testBillingRetryDeniesAccessThenVerifiedRecoveryRestoresIt() async throws {
        let context = try await storeKitContext()
        configureBillingRenewal(context, grace: false)
        let service = try await purchaseMonthly(context)
        try await storeKitEventually("Real billing retry without grace did not deny subscription access.", timeout: 75) {
            !service.hasAccess && service.commerce.hasBillingIssue
        }
        let snapshot = await context.source.snapshot()
        let status = try XCTUnwrap(snapshot.subscriptions.first { $0.state == .billingRetry })
        XCTAssertTrue(status.renewalVerified)
        XCTAssertTrue(status.isInBillingRetry)
        XCTAssertNil(status.graceEndsAt)
        XCTAssertEqual(service.commerce.lifetimeAction, .manageSubscription)
        // hasPurchaseIssue can lag the verified billing-retry status by more than 30 seconds;
        // resolve the monthly renewal that the status listener already reported.
        let issue = try XCTUnwrap(context.session.allTransactions().last { $0.productIdentifier == ProProductID.monthly.rawValue })
        context.session.shouldEnterBillingRetryOnRenewal = false
        try context.session.resolveIssueForTransaction(identifier: issue.identifier)
        do {
            try await storeKitEventually("Verified billing recovery did not restore monthly access through the listeners.", timeout: 30) {
                service.hasAccess && service.value.reason == .monthly && !service.commerce.hasBillingIssue
            }
        } catch let primaryError {
            do {
                try storeKitEvent("billing-retry-recovery-timeout", await storeKitState(context, service: service))
            } catch {
                print("Unable to preserve billing-retry diagnostics; retaining the primary failure.")
            }
            throw primaryError
        }
        try storeKitEvent("billing-retry-recovered", ["retryAccess": "false", "recoveredAccess": "monthly", "newPurchaseRequested": "false"])
    }

    func testPermanentAccessSurvivesSeparateSubscriptionBillingProblem() async throws {
        let context = try await storeKitContext()
        configureBillingRenewal(context, grace: false)
        let service = try await purchaseMonthly(context)
        _ = try await context.session.buyProduct(identifier: ProProductID.lifetime.rawValue)
        try await storeKitEventually("Externally purchased lifetime did not arrive through transaction updates.") {
            service.value.reason == .lifetime
        }
        try await storeKitEventually("Independent subscription billing problem did not appear for lifetime owner.", timeout: 75) {
            service.commerce.hasBillingIssue
        }
        XCTAssertTrue(service.hasAccess)
        XCTAssertEqual(service.value.reason, .lifetime)
        XCTAssertTrue(service.commerce.hasRenewalOverlap)
        try storeKitEvent("lifetime-billing-retry", ["permanentAccess": "true", "billingIssue": "true", "renewalOverlap": "true"])
    }

    func testNaturalExpirationDeniesSubscriptionAndFreshSourceRetainsStatus() async throws {
        let context = try await storeKitContext()
        // A 30-second period leaves time to observe auto-renew-off before expiry, even on slow hosts.
        context.session.timeRate = .oneRenewalEveryThirtySeconds
        let service = try await purchaseMonthly(context)
        let transaction = try XCTUnwrap(context.session.allTransactions().first { $0.productIdentifier == ProProductID.monthly.rawValue })
        try context.session.disableAutoRenewForTransaction(identifier: transaction.identifier)
        let waitStarted = ProcessInfo.processInfo.systemUptime
        var lastSnapshot: ProStoreSnapshot?
        var lastAction: ProLifetimeAction?
        var lastOff = false
        var lastWallDate: Date?
        var lastElapsed: TimeInterval?
        var lastServiceStatusAvailable: Bool?
        do {
            try await storeKitEventually("Verified auto-renew-off did not arrive before natural expiration.", timeout: 25) {
                let snapshot = await context.source.snapshot()
                let off = snapshot.subscriptions.contains { $0.renewalVerified && $0.willAutoRenew == false }
                // Preserve the original short circuit: inspect the lifetime action only after verified off.
                let action: ProLifetimeAction? = off ? service.commerce.lifetimeAction : nil
                lastSnapshot = snapshot
                lastAction = action
                lastOff = off
                lastWallDate = Date()
                lastElapsed = ProcessInfo.processInfo.systemUptime - waitStarted
                lastServiceStatusAvailable = service.subscriptionStatusAvailable
                return off && action == .available
            }
        } catch let primaryError {
            do {
                let statuses = lastSnapshot?.subscriptions ?? []
                let rows = statuses.prefix(3).map {
                    "product=\($0.purchase.product.rawValue),state=\($0.state),verified=\($0.renewalVerified)"
                        + ",renewing=\(String(describing: $0.willAutoRenew)),purchased=\($0.purchase.purchasedAt)"
                        + ",expires=\(String(describing: $0.purchase.expiresAt)),signed=\($0.signedAt)"
                }
                try storeKitEvent("auto-renew-off-timeout-last-observation", [
                    "observationPresent": String(lastSnapshot != nil),
                    "elapsedSinceWaitInvocation": String(describing: lastElapsed),
                    "observedWallDate": String(describing: lastWallDate),
                    "sourceStatusAvailable": String(describing: lastSnapshot?.subscriptionStatusAvailable),
                    "sourceStatuses": rows.joined(separator: ";"),
                    "sourceStatusCount": String(statuses.count),
                    "sourceStatusesCapped": String(statuses.count > 3),
                    "verifiedOffPredicate": String(lastOff),
                    "lifetimeAction": lastAction.map { String(describing: $0) } ?? "not-evaluated",
                    "serviceStatusAvailable": String(describing: lastServiceStatusAvailable),
                ])
            } catch {
                print("Unable to preserve auto-renew-off diagnostics; retaining the primary failure.")
            }
            throw primaryError
        }
        try storeKitEvent("auto-renew-off-before-natural-expiry", await storeKitState(context, service: service))
        do {
            try await storeKitEventually("Natural StoreKit expiration did not produce verified expired status and deny access.", timeout: 60) {
                let snapshot = await context.source.snapshot()
                return snapshot.subscriptions.contains { $0.state == .expired && $0.renewalVerified }
                    && !service.hasAccess
            }
        } catch {
            try storeKitEvent("natural-expiry-timeout", await storeKitState(context, service: service))
            throw error
        }
        let source = StoreKitProStoreSource()
        let snapshot = await source.snapshot()
        XCTAssertTrue(snapshot.subscriptions.contains { $0.state == .expired && $0.renewalVerified })
        await service.stopAndWait()
        let fresh = await context.makeService(source: source)
        XCTAssertFalse(fresh.hasAccess)
        try storeKitEvent("natural-expiry-fresh-source", ["access": "false", "verifiedExpiredStatus": "true"])
    }

    private static func nativeStatusDescription(_ status: Product.SubscriptionInfo.Status, since started: TimeInterval) -> String {
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        guard case let .verified(renewal) = status.renewalInfo else {
            return "elapsed=\(elapsed),state=\(status.state),renewal=unverified"
        }
        return "elapsed=\(elapsed),state=\(status.state),signed=\(renewal.signedDate.timeIntervalSince1970)"
            + ",retry=\(renewal.isInBillingRetry),graceEnd=\(String(describing: renewal.gracePeriodExpirationDate))"
    }

    private func configureBillingRenewal(_ context: StoreKitProTestContext, grace: Bool) {
        // Apple's forceRenewalOfSubscription deliberately leaves billing retry unchanged.
        // Automatic renewal exercises the supported simulated billing failure instead.
        // This rate gives a 30-second grace period and a 60-second retry period. The
        // 10-second rate let grace end before slow hosted runners observed it.
        context.session.timeRate = .oneRenewalEveryThirtySeconds
        context.session.shouldEnterBillingRetryOnRenewal = true
        context.session.billingGracePeriodIsEnabled = grace
    }

    private func purchaseMonthly(_ context: StoreKitProTestContext) async throws -> ProEntitlement {
        let service = await context.makeService()
        await service.loadCatalog()
        let product = try XCTUnwrap(service.catalog.loadedCatalog?.products[.monthly])
        let result = try await service.purchase(.monthly, expectedProduct: product)
        XCTAssertEqual(result, .purchased)
        XCTAssertTrue(service.hasAccess)
        return service
    }
}
