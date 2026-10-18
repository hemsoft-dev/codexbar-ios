import Foundation
import StoreKit
import XCTest
@testable import CodexBarIOS

@MainActor
final class StoreKitProPurchaseOutcomeTests: XCTestCase {
    func testThrownStoreKitUserCancellationReturnsCancelled() async throws {
        let source = StoreKitProStoreSource()
        var calls = 0
        let outcome = try await source.performPurchase {
            calls += 1
            throw StoreKitError.userCancelled
        }
        XCTAssertEqual(calls, 1)
        guard case .cancelled = outcome else {
            return XCTFail("A thrown StoreKit user cancellation must reach the UI as a cancelled purchase.")
        }
    }

    func testReturnedStoreKitUserCancellationReturnsCancelled() async throws {
        let source = StoreKitProStoreSource()
        let outcome = try await source.performPurchase { .userCancelled }
        guard case .cancelled = outcome else {
            return XCTFail("StoreKit's returned user cancellation must remain a cancelled purchase.")
        }
    }

    func testPendingPurchaseRemainsPending() async throws {
        let source = StoreKitProStoreSource()
        let outcome = try await source.performPurchase { .pending }
        guard case .pending = outcome else {
            return XCTFail("A purchase awaiting approval must remain pending.")
        }
    }

    func testNetworkErrorIsRethrownUnchanged() async throws {
        let source = StoreKitProStoreSource()
        let failure = URLError(.notConnectedToInternet)
        var calls = 0
        do {
            _ = try await source.performPurchase {
                calls += 1
                throw StoreKitError.networkError(failure)
            }
            XCTFail("A failed purchase must preserve its network error.")
        } catch let StoreKitError.networkError(error) {
            XCTAssertEqual(error, failure)
        }
        XCTAssertEqual(calls, 1)
    }

    func testTaskCancellationIsRethrown() async throws {
        let source = StoreKitProStoreSource()
        var calls = 0
        do {
            _ = try await source.performPurchase {
                calls += 1
                throw CancellationError()
            }
            XCTFail("Task cancellation must remain a thrown cancellation.")
        } catch is CancellationError { }
        XCTAssertEqual(calls, 1)
    }
}
