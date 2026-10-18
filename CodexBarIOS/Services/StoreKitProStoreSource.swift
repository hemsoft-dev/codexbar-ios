import Foundation
import StoreKit

@MainActor
final class StoreKitProStoreSource: ProStoreSource {
    func snapshot() async -> ProStoreSnapshot {
        var snapshot = ProStoreSnapshot()
        snapshot.appPurchase = await appPurchase()
        for await result in Transaction.currentEntitlements { append(result, to: &snapshot) }
        // Latest signed records also expose revocations omitted by currentEntitlements, including after relaunch.
        for product in ProProductID.allCases {
            if let result = await Transaction.latest(for: product.rawValue) { append(result, to: &snapshot) }
        }
        do {
            let products = try await Product.products(for: ProProductID.allCases.map(\.rawValue))
            if let subscription = products.first(where: { $0.subscription != nil })?.subscription {
                let statuses = try await subscription.status
                for status in statuses {
                    if let evidence = Self.subscription(status) {
                        snapshot.subscriptions.append(evidence)
                        snapshot.purchases.append(evidence.purchase)
                    } else if case let .unverified(transaction, _) = status.transaction,
                              let product = ProProductID(rawValue: transaction.productID) {
                        snapshot.unverifiedProducts.insert(product)
                    }
                }
                snapshot.subscriptionStatusAvailable = true
            }
        } catch {
            // StoreKit can be unavailable offline. Only a previous verified decision may supply the allowance.
        }
        return snapshot
    }

    func transactionUpdates() -> AsyncStream<ProTransactionDelivery> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    guard !Task.isCancelled else { break }
                    if let delivery = Self.delivery(result) { continuation.yield(delivery) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func subscriptionUpdates() -> AsyncStream<ProSubscriptionEvidence> {
        AsyncStream { continuation in
            let task = Task {
                for await status in Product.SubscriptionInfo.Status.updates {
                    guard !Task.isCancelled else { break }
                    if let evidence = Self.subscription(status) { continuation.yield(evidence) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func purchase(_ product: ProProductID) async throws -> ProPurchaseOutcome {
        guard let storeProduct = try await Product.products(for: [product.rawValue]).first else {
            throw PurchaseError.productUnavailable
        }
        switch try await storeProduct.purchase() {
        case let .success(result):
            guard let delivery = Self.delivery(result) else { throw PurchaseError.productUnavailable }
            return .purchased(delivery)
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            throw PurchaseError.productUnavailable
        }
    }

    func restore(refreshAppTransaction: Bool) async throws {
        try await AppStore.sync()
        if refreshAppTransaction { _ = try await AppTransaction.refresh() }
    }

    private func appPurchase() async -> ProVerification<ProAppPurchase> {
        do {
            guard case let .verified(transaction) = try await AppTransaction.shared,
                  let environment = Self.environment(transaction.environment) else { return .unverified }
            return .verified(ProAppPurchase(
                originalVersion: transaction.originalAppVersion,
                originalPurchaseDate: transaction.originalPurchaseDate,
                environment: environment,
                revoked: transaction.revocationDate != nil
            ))
        } catch {
            return .unavailable
        }
    }

    private func append(_ result: VerificationResult<Transaction>, to snapshot: inout ProStoreSnapshot) {
        switch result {
        case let .verified(transaction):
            if let purchase = Self.purchase(transaction) { snapshot.purchases.append(purchase) }
        case let .unverified(transaction, _):
            if let product = ProProductID(rawValue: transaction.productID) { snapshot.unverifiedProducts.insert(product) }
        }
    }

    private static func delivery(_ result: VerificationResult<Transaction>) -> ProTransactionDelivery? {
        switch result {
        case let .verified(transaction):
            guard let purchase = purchase(transaction) else { return nil }
            return ProTransactionDelivery(product: purchase.product, evidence: .verified(purchase)) {
                await transaction.finish()
            }
        case let .unverified(transaction, _):
            guard let product = ProProductID(rawValue: transaction.productID) else { return nil }
            return ProTransactionDelivery(product: product, evidence: .unverified, finish: {})
        }
    }

    private static func purchase(_ transaction: Transaction) -> ProPurchaseEvidence? {
        guard let product = ProProductID(rawValue: transaction.productID),
              let environment = environment(transaction.environment) else { return nil }
        let trial: Bool
        if #available(iOS 17.2, macOS 14.2, *) {
            trial = transaction.offer?.type == .introductory && transaction.offer?.paymentMode == .freeTrial
        } else {
            trial = transaction.offerType == .introductory && transaction.offerPaymentModeStringRepresentation == "FREE_TRIAL"
        }
        return ProPurchaseEvidence(
            product: product, transactionID: transaction.id, purchasedAt: transaction.purchaseDate,
            signedAt: transaction.signedDate, expiresAt: transaction.expirationDate,
            revoked: transaction.revocationDate != nil, upgraded: transaction.isUpgraded,
            isFreeTrial: trial, environment: environment
        )
    }

    private static func environment(_ environment: AppStore.Environment) -> ProStoreEnvironment? {
        switch environment {
        case .production: .production
        case .sandbox: .sandbox
        case .xcode: .xcode
        default: nil
        }
    }

    private static func subscription(_ status: Product.SubscriptionInfo.Status) -> ProSubscriptionEvidence? {
        guard case let .verified(transaction) = status.transaction,
              let purchase = purchase(transaction), purchase.product != .lifetime else { return nil }
        guard case let .verified(renewal) = status.renewalInfo else {
            return ProSubscriptionEvidence(
                purchase: purchase, signedAt: transaction.signedDate, state: .subscribed, renewalVerified: false,
                willAutoRenew: nil, isInBillingRetry: false, graceEndsAt: nil
            )
        }
        let state: ProRenewalState
        switch status.state {
        case .subscribed: state = .subscribed
        case .inGracePeriod: state = .grace
        case .inBillingRetryPeriod: state = .billingRetry
        case .revoked: state = .revoked
        default: state = .expired
        }
        return ProSubscriptionEvidence(
            purchase: purchase, signedAt: renewal.signedDate, state: state, renewalVerified: true,
            willAutoRenew: renewal.willAutoRenew, isInBillingRetry: renewal.isInBillingRetry,
            graceEndsAt: renewal.gracePeriodExpirationDate
        )
    }

    private enum PurchaseError: Error { case productUnavailable }
}
