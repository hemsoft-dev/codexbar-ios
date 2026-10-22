import Foundation
import StoreKit
import StoreKitTest
import XCTest
@testable import CodexBarIOS

/// Owns the only StoreKit listeners and cache used by one serial native test.
@MainActor
final class StoreKitProTestContext {
    let session: SKTestSession
    let source = StoreKitProStoreSource()
    let directory: URL
    let cacheDirectory: URL
    let cache: ProEntitlementCache
    private let clockID = UUID().uuidString
    private var services: [ProEntitlement] = []
    private var listeners: [Task<Void, Never>] = []

    init(storefront: String = "USA", locale: Locale = Locale(identifier: "en_US")) throws {
        try Self.requireIsolatedHost()
        session = try Self.configuredSession(storefront: storefront, locale: locale)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreKitPro-" + UUID().uuidString, isDirectory: true)
        cacheDirectory = directory.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        cache = ProEntitlementCache(fileURL: cacheDirectory.appendingPathComponent("entitlement.json"))
    }

    static func requireIsolatedHost() throws {
        try require(
            ProcessInfo.processInfo.environment["CODEXBAR_NATIVE_STOREKIT_TEST_HOST"] == "1"
                && UITestFixtures.current?.isNativeTestHost == true,
            "Native StoreKit tests require the explicit isolated host; the production listener must never run."
        )
    }

    static func configuredSession(storefront: String = "USA", locale: Locale = Locale(identifier: "en_US")) throws -> SKTestSession {
        let url = try XCTUnwrap(Bundle(for: StoreKitProPreparationTests.self)
            .url(forResource: "CodexBarPro", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.storefront = storefront
        session.locale = locale
        session.timeRate = .realTime
        try require(session.allTransactions().isEmpty, "StoreKit session was not empty after reset.")
        return session
    }

    func makeService(start: Bool = true, source: (any ProStoreSource)? = nil) async -> ProEntitlement {
        let marker = clockID
        let service = ProEntitlement(source: source ?? self.source, cache: cache, clock: { date in
            ProEntitlementClockSample(
                wallDate: date, continuousSeconds: ProcessInfo.processInfo.systemUptime, continuityID: marker
            )
        })
        services.append(service)
        if start { await service.start() }
        return service
    }

    func retainListener(_ listener: Task<Void, Never>) { listeners.append(listener) }

    func observeTransactionsWithoutFinishing() async {
        let updates = source.transactionUpdates()
        retainListener(Task {
            for await _ in updates {
                guard !Task.isCancelled else { return }
            }
        })
        await Task.yield()
    }

    func close() async throws {
        // Stop accelerated renewal production before waiting for consumers or clearing
        // their transactions. A queued renewal can otherwise land after the last clear.
        session.timeRate = .realTime
        session.shouldEnterBillingRetryOnRenewal = false
        for transaction in session.allTransactions() where transaction.autoRenewingEnabled {
            try session.disableAutoRenewForTransaction(identifier: transaction.identifier)
        }
        for service in services { await service.stopAndWait() }
        services.removeAll()
        listeners.forEach { $0.cancel() }
        for listener in listeners { await listener.value }
        listeners.removeAll()
        session.clearTransactions()
        session.resetToDefaultState()
        // An accelerated renewal can land between the clear and the reset that stops it.
        session.clearTransactions()
        try await session.setSimulatedError(nil, forAPI: .loadProducts)
        try await session.setSimulatedError(nil, forAPI: .purchase)
        try await session.setSimulatedError(nil, forAPI: .verification)
        try await session.setSimulatedError(nil, forAPI: .subscriptionStatus)
        try await session.setSimulatedError(nil, forAPI: .appStoreSync)
        try await session.setSimulatedError(nil, forAPI: .appTransaction)
        try Self.require(session.allTransactions().isEmpty, "Owned StoreKit transactions survived teardown.")
        try await Self.requireEmptyTransactions("teardown")
        try FileManager.default.removeItem(at: directory)
    }

    static func requireEmptyTransactions(_ phase: String) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        repeat {
            if await !hasStoreKitTransactions() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw StoreKitProTestFailure.assertion("StoreKit retained current, latest or unfinished transactions during \(phase).")
    }

    private static func hasStoreKitTransactions() async -> Bool {
        // An unverified result is still a leaked transaction. Do not inspect only
        // verified entitlements after a case that simulated verification failure.
        for await _ in StoreKit.Transaction.currentEntitlements { return true }
        for await _ in StoreKit.Transaction.unfinished { return true }
        for product in ProProductID.allCases where await StoreKit.Transaction.latest(for: product.rawValue) != nil {
            return true
        }
        return false
    }

    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw StoreKitProTestFailure.assertion(message) }
    }
}

enum StoreKitProTestFailure: Error {
    case assertion(String)
}

/// Diagnostic forwarding only. The update stream adds one task/stream hop, so
/// this recorder cannot replace the unwrapped service regression test.
@MainActor
final class StoreKitProFinishRecordingSource: ProStoreSource {
    private enum Origin: String { case purchase, update }
    private enum Phase: String { case delivered, enter, returned }
    private struct Event {
        let phase: Phase
        let origin: Origin
        let cancelled: Bool
    }
    private struct Record {
        var purchaseDeliveries = 0
        var updateDeliveries = 0
        var entered = 0
        var returned = 0
        var active = 0
        var peak = 0
        var cancelledAtEntry = 0
        var cancelledAtReturn = 0
        var events: [Event] = []
    }

    private let source: StoreKitProStoreSource
    private weak var context: StoreKitProTestContext?
    private var records: [UInt64: Record] = [:]
    private(set) var purchasedTransactionID: UInt64?

    init(context: StoreKitProTestContext) {
        source = context.source
        self.context = context
    }

    func snapshot() async -> ProStoreSnapshot { await source.snapshot() }
    func catalog() async throws -> ProCatalog { try await source.catalog() }
    func storefrontUpdates() -> AsyncStream<String> { source.storefrontUpdates() }
    func subscriptionUpdates() -> AsyncStream<ProSubscriptionUpdate> { source.subscriptionUpdates() }
    func restore(refreshAppTransaction: Bool) async throws { try await source.restore(refreshAppTransaction: refreshAppTransaction) }

    func purchase(_ product: ProProductID) async throws -> ProPurchaseOutcome {
        wrap(try await source.purchase(product))
    }

    func purchase(
        _ product: ProProductID, expectedProduct: ProCatalogProduct, authorize: @MainActor () throws -> Void
    ) async throws -> ProPurchaseOutcome {
        wrap(try await source.purchase(product, expectedProduct: expectedProduct, authorize: authorize))
    }

    func transactionUpdates() -> AsyncStream<ProTransactionDelivery> {
        let updates = source.transactionUpdates()
        return AsyncStream { continuation in
            let task = Task { [self] in
                for await delivery in updates {
                    guard !Task.isCancelled else { break }
                    continuation.yield(wrap(delivery, origin: .update))
                }
                continuation.finish()
            }
            context?.retainListener(task)
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func completedFinish(matching transactionID: UInt64) -> Bool {
        guard let record = records[transactionID] else { return false }
        return record.entered > 0 && record.returned == record.entered && record.active == 0
    }

    func readback(matching transactionID: UInt64) -> [String: String] {
        let record = records[transactionID] ?? Record()
        return [
            "recordedTransactionCount": String(records.count),
            "purchaseDeliveryCount": String(record.purchaseDeliveries),
            "updateDeliveryCount": String(record.updateDeliveries),
            "finishEnterCount": String(record.entered),
            "finishReturnCount": String(record.returned),
            "finishActiveCount": String(record.active),
            "finishPeakConcurrentCount": String(record.peak),
            "finishCancelledAtEntryCount": String(record.cancelledAtEntry),
            "finishCancelledAtReturnCount": String(record.cancelledAtReturn),
            "finishEventOrder": record.events.map {
                "\($0.origin.rawValue):\($0.phase.rawValue):cancelled=\($0.cancelled)"
            }.joined(separator: ";"),
            "schedulingCaveat": "transaction updates pass through one additional task and stream",
        ]
    }

    private func wrap(_ outcome: ProPurchaseOutcome) -> ProPurchaseOutcome {
        guard case let .purchased(delivery) = outcome else { return outcome }
        return .purchased(wrap(delivery, origin: .purchase))
    }

    private func wrap(_ delivery: ProTransactionDelivery, origin: Origin) -> ProTransactionDelivery {
        guard case let .verified(purchase) = delivery.evidence else { return delivery }
        let transactionID = purchase.transactionID
        var record = records[transactionID] ?? Record()
        if origin == .purchase {
            purchasedTransactionID = transactionID
            record.purchaseDeliveries += 1
        } else { record.updateDeliveries += 1 }
        record.events.append(Event(phase: .delivered, origin: origin, cancelled: Task.isCancelled))
        records[transactionID] = record
        return ProTransactionDelivery(product: delivery.product, evidence: delivery.evidence, environment: delivery.environment) {
            self.recordFinish(.enter, transactionID: transactionID, origin: origin)
            await delivery.finish()
            self.recordFinish(.returned, transactionID: transactionID, origin: origin)
        }
    }

    private func recordFinish(_ phase: Phase, transactionID: UInt64, origin: Origin) {
        var record = records[transactionID] ?? Record()
        let cancelled = Task.isCancelled
        if phase == .enter {
            record.entered += 1
            record.active += 1
            record.peak = max(record.peak, record.active)
            if cancelled { record.cancelledAtEntry += 1 }
        } else {
            record.returned += 1
            record.active -= 1
            if cancelled { record.cancelledAtReturn += 1 }
        }
        record.events.append(Event(phase: phase, origin: origin, cancelled: cancelled))
        records[transactionID] = record
    }
}

@MainActor
extension XCTestCase {
    func storeKitContext(storefront: String = "USA", locale: Locale = Locale(identifier: "en_US")) async throws -> StoreKitProTestContext {
        let context = try StoreKitProTestContext(storefront: storefront, locale: locale)
        addTeardownBlock { @MainActor in try await context.close() }
        try await StoreKitProTestContext.requireEmptyTransactions("baseline")
        return context
    }

    func storeKitEventually(
        _ message: String,
        timeout: TimeInterval = 10,
        condition: @escaping @MainActor () async throws -> Bool
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw StoreKitProTestFailure.assertion(message)
    }

    func storeKitEvent(_ phase: String, _ details: [String: String] = [:]) throws {
        var event = details
        event["phase"] = phase
        event["runtime"] = ProcessInfo.processInfo.operatingSystemVersionString
        let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        print("STOREKIT_NATIVE_EVENT " + text)
        let attachment = XCTAttachment(string: text)
        attachment.name = "StoreKit-" + phase
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func storeKitProducts() async throws -> [ProProductID: Product] {
        let products = try await Product.products(for: ProProductID.allCases.map(\.rawValue))
        let mapped = Dictionary(uniqueKeysWithValues: products.compactMap { product in
            ProProductID(rawValue: product.id).map { ($0, product) }
        })
        try StoreKitProTestContext.require(
            Set(mapped.keys) == Set(ProProductID.allCases), "Real StoreKit lookup did not return all three fixture products."
        )
        return mapped
    }

    func storeKitAwaitInitialTrialEligibility() async throws {
        let products = try await storeKitProducts()
        let subscription = try XCTUnwrap(products[.yearly]?.subscription)
        try await storeKitEventually("StoreKit did not restore initial yearly trial eligibility after the owned session reset.") {
            await subscription.isEligibleForIntroOffer
        }
    }

    func storeKitCurrentProducts() async -> Set<String> {
        var products: Set<String> = []
        for await result in StoreKit.Transaction.currentEntitlements {
            if case let .verified(transaction) = result { products.insert(transaction.productID) }
        }
        return products
    }

    func storeKitUnfinishedProducts() async -> Set<String> {
        Set(await storeKitUnfinishedTransactions().map(\.transaction.productID))
    }

    func storeKitUnfinishedTransactions() async -> [(transaction: StoreKit.Transaction, verified: Bool)] {
        var transactions: [(transaction: StoreKit.Transaction, verified: Bool)] = []
        for await result in StoreKit.Transaction.unfinished {
            switch result {
            case let .verified(transaction): transactions.append((transaction, true))
            case let .unverified(transaction, _): transactions.append((transaction, false))
            }
        }
        return transactions
    }

    func storeKitUnfinishedReadback(matchingPurchasedTransactionID transactionID: UInt64) async -> [String: String] {
        let transactions = await storeKitUnfinishedTransactions()
        return [
            "unfinishedCount": String(transactions.count),
            "unfinishedVerifiedCount": String(transactions.filter(\.verified).count),
            "unfinishedUnverifiedCount": String(transactions.filter { !$0.verified }.count),
            "unfinishedProducts": Set(transactions.map(\.transaction.productID)).sorted().joined(separator: ","),
            "unfinishedMatchesPurchasedTransaction": String(transactions.contains { $0.transaction.id == transactionID }),
        ]
    }

    func storeKitState(
        _ context: StoreKitProTestContext, service: ProEntitlement, purchasedTransactionID: UInt64? = nil
    ) async -> [String: String] {
        let snapshot = await context.source.snapshot()
        let unfinished = await storeKitUnfinishedProducts()
        let current = await storeKitCurrentProducts()
        let sessions = context.session.allTransactions().map {
            "\($0.productIdentifier):renewing=\($0.autoRenewingEnabled),issue=\($0.hasPurchaseIssue),pending=\($0.pendingAskToBuyConfirmation)"
        }.sorted()
        let statuses = snapshot.subscriptions.map {
            "\($0.purchase.product.rawValue):state=\($0.state),verified=\($0.renewalVerified),renewing=\(String(describing: $0.willAutoRenew)),retry=\($0.isInBillingRetry)"
        }.sorted()
        var details = [
            "serviceReason": service.value.reason.rawValue,
            "serviceAccess": String(service.hasAccess),
            "serviceStatusAvailable": String(service.subscriptionStatusAvailable),
            "sourceStatusAvailable": String(snapshot.subscriptionStatusAvailable),
            "sourceStatuses": statuses.joined(separator: ";"),
            "sessionStates": sessions.joined(separator: ";"),
            "currentProducts": current.sorted().joined(separator: ","),
            "unfinishedProducts": unfinished.sorted().joined(separator: ","),
        ]
        if let purchasedTransactionID {
            details.merge(await storeKitUnfinishedReadback(matchingPurchasedTransactionID: purchasedTransactionID)) { _, fresh in fresh }
        }
        return details
    }

    func storeKitDelivery(_ outcome: ProPurchaseOutcome, product: ProProductID) throws -> ProTransactionDelivery {
        guard case let .purchased(delivery) = outcome, case let .verified(evidence) = delivery.evidence else {
            throw StoreKitProTestFailure.assertion("The adapter did not deliver separately verified purchase evidence.")
        }
        XCTAssertEqual(delivery.product, product)
        XCTAssertEqual(evidence.product, product)
        XCTAssertEqual(delivery.environment, .xcode)
        XCTAssertEqual(evidence.environment, .xcode)
        XCTAssertFalse(evidence.revoked)
        XCTAssertFalse(evidence.upgraded)
        XCTAssertTrue(evidence.signedAt.timeIntervalSinceReferenceDate.isFinite)
        XCTAssertTrue(evidence.purchasedAt.timeIntervalSinceReferenceDate.isFinite)
        return delivery
    }
}
