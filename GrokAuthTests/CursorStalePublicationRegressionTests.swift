import Combine
import Foundation
import XCTest
@testable import CodexBarIOS

@MainActor
final class CursorStalePublicationRegressionTests: XCTestCase {
    func testRejectedSessionRetainsMeasuredTimestampButCannotEnterHistoryOrFreshPublication() async throws {
        let fixture = try makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let account = fixture.account
        let secret = CursorWebAuthResult(accessToken: "synthetic-token", refreshToken: nil, authID: "owner-a", userID: nil)
        XCTAssertTrue(fixture.store.saveSecret(secret.storedCredential, for: account))
        let credential = try XCTUnwrap(CursorSessionCredential(storedSecret: secret.storedCredential))
        let measuredAt = Date(timeIntervalSince1970: 1_790_000_000)
        let good = try XCTUnwrap(CursorUsageProvider.parseUsage(
            Data(#"{"planUsage":{"autoPercentUsed":0.1,"apiPercentUsed":13}}"#.utf8),
            configuration: account, fetchedAt: measuredAt, cacheIdentity: credential.cacheIdentity
        ))
        let failed = ProviderUsageResult(
            accountID: account.id, providerID: .cursor, title: account.displayName,
            subtitle: "Cursor sign-in needs renewal.", bars: [], failureMessage: "Reconnect Cursor",
            recoveryAction: .reauthenticate, cacheIdentity: credential.cacheIdentity, fetchedAt: Date()
        )
        let service = UsageRefreshService(providers: [CursorFixedFailure(result: failed)], initialResults: [good])
        await service.refresh(configurations: [account])
        let retained = try XCTUnwrap(service.results.first)
        XCTAssertEqual(retained.bars.map(\.used), [0.1, 13])
        XCTAssertEqual(retained.fetchedAt, measuredAt)
        XCTAssertEqual(retained.barsFetchedAt, measuredAt)
        XCTAssertNotNil(retained.failureMessage)
        XCTAssertEqual(retained.recoveryAction, .reauthenticate)
        XCTAssertTrue(service.successfulRefreshResults.isEmpty)
        WidgetSnapshotPublisher.publish(results: service.results, configurationStore: fixture.store,
            access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: fixture.defaults, accessGuard: WidgetAccessGuard(directory: nil))
        let widget = try XCTUnwrap(WidgetSnapshotStore.loadSnapshot(defaults: fixture.defaults).results.first)
        XCTAssertTrue(widget.subtitle.contains("last known data"))
        XCTAssertEqual(widget.fetchedAt, measuredAt)
        let watch = WatchSnapshotPublisher.makeSnapshot(results: service.results, configurationStore: fixture.store,
            access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil))
        XCTAssertTrue(watch.accounts.first?.statusText?.contains("last known data") == true)
        XCTAssertEqual(watch.accounts.first?.fetchedAt, measuredAt)
    }

    func testReconnectInvalidatesOldRefreshAndClearsOnlyDifferentIdentityHistory() throws {
        let fixture = try makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let account = fixture.account
        var changes = 0
        var histories = 0
        let credentials = fixture.store.credentialChanges.sink { _ in changes += 1 }
        let sameIdentity = fixture.store.cursorSameIdentityReconnects.sink { _ in changes += 1 }
        let history = fixture.store.cursorHistoryInvalidations.sink { _ in histories += 1 }
        defer { credentials.cancel(); sameIdentity.cancel(); history.cancel() }
        let first = CursorWebAuthResult(accessToken: "synthetic-a", refreshToken: nil, authID: "owner-a", userID: nil)
        let renewal = CursorWebAuthResult(accessToken: "synthetic-a-renewed", refreshToken: nil, authID: "owner-a", userID: nil)
        let other = CursorWebAuthResult(accessToken: "synthetic-b", refreshToken: nil, authID: "owner-b", userID: nil)
        XCTAssertNotNil(fixture.store.connectCursorAccount(account, credential: first.storedCredential))
        XCTAssertNotNil(fixture.store.connectCursorAccount(account, credential: renewal.storedCredential))
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(histories, 1, "Missing previous credential is an unknown identity")
        XCTAssertNotNil(fixture.store.connectCursorAccount(account, credential: other.storedCredential))
        XCTAssertEqual(changes, 3)
        XCTAssertEqual(histories, 2)
        XCTAssertNotNil(fixture.store.disconnectCursorAccount(account))
        XCTAssertEqual(changes, 4)
        XCTAssertEqual(histories, 3)
    }

    func testSameIdentityReconnectRetainsMeasuredCacheUntilQuotaIsVerified() async throws {
        let fixture = try makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let first = CursorWebAuthResult(accessToken: "synthetic-a", refreshToken: nil, authID: "owner-a", userID: nil)
        XCTAssertTrue(fixture.store.saveSecret(first.storedCredential, for: fixture.account))
        let credential = try XCTUnwrap(CursorSessionCredential(storedSecret: first.storedCredential))
        let measuredAt = Date(timeIntervalSince1970: 1_790_000_000)
        var good = try XCTUnwrap(CursorUsageProvider.parseUsage(
            Data(#"{"planUsage":{"autoPercentUsed":0.1,"apiPercentUsed":13}}"#.utf8),
            configuration: fixture.account, fetchedAt: measuredAt, cacheIdentity: credential.cacheIdentity
        ))
        good.subscriptionRenewal = SubscriptionRenewal(accountID: fixture.account.id, providerID: .cursor, state: .renewing,
                                                       date: Date().addingTimeInterval(259_200), observedAt: Date())
        let failed = ProviderUsageResult(accountID: fixture.account.id, providerID: .cursor,
            title: "Synthetic", subtitle: "Unavailable", bars: [], failureMessage: "Unavailable",
            cacheIdentity: credential.cacheIdentity, fetchedAt: Date())
        let service = UsageRefreshService(providers: [CursorFixedFailure(result: failed)], initialResults: [good])
        let changed = fixture.store.credentialChanges.sink { service.invalidateCredentials(accountID: $0) }
        let sameIdentity = fixture.store.cursorSameIdentityReconnects.sink {
            service.invalidateCredentials(accountID: $0, preserveCachedResult: true)
        }
        defer { changed.cancel(); sameIdentity.cancel() }
        let renewed = CursorWebAuthResult(accessToken: "synthetic-b", refreshToken: nil, authID: "owner-a", userID: nil)
        XCTAssertNotNil(fixture.store.connectCursorAccount(fixture.account, credential: renewed.storedCredential))
        XCTAssertNil(service.results.first?.subscriptionRenewal, "Reconnect retains usage, never an unverified billing observation")
        await service.refresh(configurations: [fixture.account])
        XCTAssertEqual(service.results.first?.bars.map(\.used), [0.1, 13])
        XCTAssertEqual(service.results.first?.fetchedAt, measuredAt)
        XCTAssertFalse(service.results.first?.hasCurrentBars == true)
        XCTAssertNil(service.results.first?.subscriptionRenewal)
    }

    func testSameIdentityReconnectDiscardsInflightOldQuotaWithoutPurgingCache() async throws {
        let fixture = try makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let original = CursorWebAuthResult(accessToken: "synthetic-a", refreshToken: nil, authID: "owner-a", userID: nil)
        XCTAssertTrue(fixture.store.saveSecret(original.storedCredential, for: fixture.account))
        let identity = try XCTUnwrap(CursorSessionCredential(storedSecret: original.storedCredential)).cacheIdentity
        let good = try XCTUnwrap(CursorUsageProvider.parseUsage(
            Data(#"{"planUsage":{"autoPercentUsed":0.1,"apiPercentUsed":13}}"#.utf8),
            configuration: fixture.account, cacheIdentity: identity
        ))
        let oldZero = try XCTUnwrap(CursorUsageProvider.parseUsage(
            Data(#"{"planUsage":{"autoPercentUsed":0,"apiPercentUsed":0}}"#.utf8),
            configuration: fixture.account, cacheIdentity: identity
        ))
        let gate = CursorSuspendedQuota()
        let service = UsageRefreshService(providers: [gate], initialResults: [good])
        let changed = fixture.store.credentialChanges.sink { service.invalidateCredentials(accountID: $0) }
        let same = fixture.store.cursorSameIdentityReconnects.sink {
            service.invalidateCredentials(accountID: $0, preserveCachedResult: true)
        }
        defer { changed.cancel(); same.cancel() }
        let refresh = Task { await service.refresh(configurations: [fixture.account]) }
        for await _ in gate.started.stream { break }
        let replacement = CursorWebAuthResult(accessToken: "synthetic-b", refreshToken: nil, authID: "owner-a", userID: nil)
        XCTAssertNotNil(fixture.store.connectCursorAccount(fixture.account, credential: replacement.storedCredential))
        await gate.finish(oldZero)
        await refresh.value
        XCTAssertEqual(service.results.first?.bars.map(\.used), [0.1, 13])
        XCTAssertEqual(service.results.first?.fetchedAt, good.fetchedAt)
        XCTAssertTrue(service.successfulRefreshResults.isEmpty, "Reconnect cache is not verified current usage")
        XCTAssertTrue(service.incompleteRefreshAccountIDs.contains(fixture.account.id))
        XCTAssertNotNil(service.results.first?.failureMessage)
        XCTAssertNotNil(service.lastRefreshError)
    }

    private func makeStore() throws -> (
        store: ProviderConfigurationStore, defaults: UserDefaults, suite: String, account: ProviderAccountConfiguration
    ) {
        let suite = "CursorSession.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults, secretStore: GrokTestSecrets(), widgetSnapshotDefaults: defaults)
        let account = ProviderAccountConfiguration(
            id: "cursor-stale-publication", providerID: .cursor, accountLabel: "Synthetic Cursor", authMethod: .browserSession
        )
        XCTAssertTrue(store.update(account))
        return (store, defaults, suite, account)
    }
}

private actor CursorSuspendedQuota: UsageProvider {
    nonisolated let providerID = ProviderID.cursor
    nonisolated let started = AsyncStream.makeStream(of: Void.self)
    private var pending: CheckedContinuation<ProviderUsageResult, Never>?
    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        await withCheckedContinuation { continuation in
            pending = continuation
            started.continuation.yield(())
            started.continuation.finish()
        }
    }
    func finish(_ result: ProviderUsageResult) { pending?.resume(returning: result); pending = nil }
}

private struct CursorFixedFailure: UsageProvider {
    let result: ProviderUsageResult
    let providerID = ProviderID.cursor
    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult { result }
}
