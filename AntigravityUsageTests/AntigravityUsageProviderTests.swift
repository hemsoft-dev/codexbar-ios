import Foundation
import XCTest
@testable import CodexBarIOS

final class AntigravityUsageProviderTests: XCTestCase, @unchecked Sendable {
    private let start = AntigravityFixtures.now
    private let capture = AntigravityPageCapture(
        quotaBody: AntigravityFixtures.screenshotQuotaBody, profileBody: AntigravityFixtures.profileBody, pagePath: "/remote/settings"
    )

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) {
            self.value = value
        }

        var now: Date { lock.withLock { value } }

        func advance(_ seconds: TimeInterval) {
            lock.withLock { value = value.addingTimeInterval(seconds) }
        }
    }

    private func provider(
        account: ProviderAccountConfiguration, marker: AntigravityWebSessionMarker?, reader: AntigravityFixtureReader,
        cache: AntigravityReadCache = AntigravityReadCache(), clock: Clock
    ) -> AntigravityUsageProvider {
        var secrets: [String: String] = [:]
        if let marker { secrets[ProviderConfigurationStore.keychainAccount(for: account)] = marker.storedValue }
        return AntigravityUsageProvider(
            secretStore: AntigravityFixtureSecretStore(secrets), reader: reader, cache: cache, now: { clock.now }
        )
    }

    func testAccountWithoutASavedSignInAsksForSignInAndLoadsNothing() async throws {
        let reader = AntigravityFixtureReader([.success(capture)])
        let account = AntigravityFixtures.configuration()
        let result = try await provider(account: account, marker: nil, reader: reader, clock: Clock(start)).fetchUsage(for: account)

        XCTAssertEqual(result.failureMessage, "Not configured - sign in with Google")
        XCTAssertEqual(result.recoveryAction, .signIn)
        XCTAssertTrue(result.bars.isEmpty)
        let reads = await reader.markers
        XCTAssertTrue(reads.isEmpty)
    }

    func testReadingBecomesTheFourMetersAndPlan() async throws {
        let reader = AntigravityFixtureReader([.success(capture)])
        let account = AntigravityFixtures.configuration()
        let marker = AntigravityWebSessionMarker(websiteDataStoreID: UUID(), pagePath: "/u/1/remote/settings")
        let result = try await provider(account: account, marker: marker, reader: reader, clock: Clock(start)).fetchUsage(for: account)

        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(result.bars.map(\.used), [3, 9, 0, 0])
        XCTAssertEqual(result.plan?.displayLabel, "Google AI Ultra")
        XCTAssertEqual(result.fetchedAt, start)
        XCTAssertTrue(result.hasCurrentBars)
        let reads = await reader.markers
        XCTAssertEqual(reads, [marker])
    }

    func testOneAccountLoadsGooglesPageAtMostOnceEveryFiveMinutes() async throws {
        let reader = AntigravityFixtureReader([.success(capture)])
        let account = AntigravityFixtures.configuration()
        let clock = Clock(start)
        let provider = provider(
            account: account, marker: AntigravityWebSessionMarker(websiteDataStoreID: UUID()), reader: reader, clock: clock
        )

        let first = try await provider.fetchUsage(for: account)
        clock.advance(4 * 60 + 59)
        let second = try await provider.fetchUsage(for: account)
        var reads = await reader.markers
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(second.fetchedAt, first.fetchedAt, "the earlier reading keeps the time it was read")
        XCTAssertEqual(second.bars.map(\.used), first.bars.map(\.used))

        clock.advance(1)
        let third = try await provider.fetchUsage(for: account)
        reads = await reader.markers
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(third.fetchedAt, start.addingTimeInterval(5 * 60))
    }

    func testSimultaneousRefreshesShareOnePageLoad() async throws {
        let reader = AntigravityFixtureReader([.success(capture)])
        let account = AntigravityFixtures.configuration()
        let provider = provider(
            account: account, marker: AntigravityWebSessionMarker(websiteDataStoreID: UUID()), reader: reader, clock: Clock(start)
        )
        async let first = provider.fetchUsage(for: account)
        async let second = provider.fetchUsage(for: account)
        let results = try await [first, second]
        XCTAssertEqual(results.map(\.bars.count), [4, 4])
        let reads = await reader.markers
        XCTAssertEqual(reads.count, 1)
    }

    func testSignInHandsItsReadingToTheFirstRefresh() async throws {
        let reader = AntigravityFixtureReader([.failure(.pageFailed)])
        let account = AntigravityFixtures.configuration()
        let marker = AntigravityWebSessionMarker(websiteDataStoreID: UUID())
        let cache = AntigravityReadCache()
        await cache.prime(storeID: marker.websiteDataStoreID, capture: capture, at: start)
        let clock = Clock(start.addingTimeInterval(20))

        let result = try await provider(account: account, marker: marker, reader: reader, cache: cache, clock: clock)
            .fetchUsage(for: account)
        XCTAssertEqual(result.bars.count, 4)
        XCTAssertEqual(result.fetchedAt, start)
        let reads = await reader.markers
        XCTAssertTrue(reads.isEmpty, "sign-in already saw the page report usage")
    }

    func testTwoAccountsNeverShareASignInOrAReading() async throws {
        let reader = AntigravityFixtureReader([.success(capture)])
        let cache = AntigravityReadCache()
        let clock = Clock(start)
        let first = AntigravityFixtures.configuration(id: "first")
        let second = AntigravityFixtures.configuration(id: "second")
        let firstMarker = AntigravityWebSessionMarker(websiteDataStoreID: UUID())
        let secondMarker = AntigravityWebSessionMarker(websiteDataStoreID: UUID())
        let secrets = AntigravityFixtureSecretStore([
            ProviderConfigurationStore.keychainAccount(for: first): firstMarker.storedValue,
            ProviderConfigurationStore.keychainAccount(for: second): secondMarker.storedValue,
        ])
        let provider = AntigravityUsageProvider(secretStore: secrets, reader: reader, cache: cache, now: { clock.now })

        let firstResult = try await provider.fetchUsage(for: first)
        let secondResult = try await provider.fetchUsage(for: second)

        let reads = await reader.markers
        XCTAssertEqual(reads.map(\.websiteDataStoreID), [firstMarker.websiteDataStoreID, secondMarker.websiteDataStoreID])
        XCTAssertNotEqual(firstResult.cacheIdentity, secondResult.cacheIdentity)
        XCTAssertEqual(firstResult.accountID, "first")
        XCTAssertEqual(secondResult.accountID, "second")
    }

    func testExpiredGoogleSessionAsksForSignInAgainAndShowsNoValues() async throws {
        let reader = AntigravityFixtureReader([.success(capture), .failure(.signInRequired)])
        let account = AntigravityFixtures.configuration()
        let clock = Clock(start)
        let provider = provider(
            account: account, marker: AntigravityWebSessionMarker(websiteDataStoreID: UUID()), reader: reader, clock: clock
        )
        let reading = try await provider.fetchUsage(for: account)
        clock.advance(5 * 60)
        let expired = try await provider.fetchUsage(for: account)

        XCTAssertEqual(expired.recoveryAction, .reauthenticate)
        XCTAssertEqual(expired.failureMessage, "Google asked you to sign in again. Sign in to read Antigravity usage.")
        XCTAssertTrue(expired.bars.isEmpty)
        XCTAssertFalse(expired.preserveCachedBarsOnFailure)
        XCTAssertNotEqual(expired.cacheIdentity, reading.cacheIdentity, "the refresh service must not reuse the earlier reading")
    }

    func testPageThatLoadsWithoutReportingUsageExplainsItselfAndKeepsTheLastReading() async throws {
        // On the owner's phone the hidden page loaded signed in and reported nothing in time. That must not blank
        // a card that had values, and an account that needs a computer still gets its explanation.
        let reader = AntigravityFixtureReader([.success(capture), .failure(.noUsageReported)])
        let account = AntigravityFixtures.configuration()
        let clock = Clock(start)
        let provider = provider(
            account: account, marker: AntigravityWebSessionMarker(websiteDataStoreID: UUID()), reader: reader, clock: clock
        )
        let reading = try await provider.fetchUsage(for: account)
        clock.advance(5 * 60)
        let result = try await provider.fetchUsage(for: account)

        XCTAssertEqual(result.failureMessage?.contains("didn't report usage this time"), true)
        XCTAssertEqual(result.failureMessage?.contains("connected computer"), true)
        XCTAssertTrue(result.bars.isEmpty, "the failure itself carries no values")
        XCTAssertTrue(result.preserveCachedBarsOnFailure, "the refresh service keeps the last reading and marks it stale")
        XCTAssertEqual(result.cacheIdentity, reading.cacheIdentity)
        XCTAssertFalse(result.hasCurrentBars)
        XCTAssertEqual(result.recoveryAction, .retryRefresh)
    }

    func testRefreshWhileTheAppIsOffScreenLoadsNothingAndDoesNotCountAgainstTheLimit() async throws {
        let reader = AntigravityFixtureReader([.success(capture), .failure(.appNotActive), .success(capture)])
        let account = AntigravityFixtures.configuration()
        let clock = Clock(start)
        let provider = provider(
            account: account, marker: AntigravityWebSessionMarker(websiteDataStoreID: UUID()), reader: reader, clock: clock
        )
        _ = try await provider.fetchUsage(for: account)
        clock.advance(5 * 60)
        let skipped = try await provider.fetchUsage(for: account)
        XCTAssertEqual(skipped.failureMessage, "Antigravity refreshes while CodexBar is open.")
        XCTAssertTrue(skipped.preserveCachedBarsOnFailure)

        // Back on screen a moment later, the refresh runs at once.
        clock.advance(2)
        let refreshed = try await provider.fetchUsage(for: account)
        XCTAssertNil(refreshed.failureMessage)
        XCTAssertEqual(refreshed.fetchedAt, start.addingTimeInterval(5 * 60 + 2))
        let reads = await reader.markers
        XCTAssertEqual(reads.count, 3)
        for error in [AntigravityReadError.noUsageReported, .pageFailed, .unreadableResponse, .appNotActive] {
            XCTAssertTrue(error.keepsLastReading, "\(error)")
        }
        XCTAssertFalse(AntigravityReadError.signInRequired.keepsLastReading, "an ended sign-in shows no values")
        XCTAssertFalse(AntigravityReadError.notConfigured.keepsLastReading)
    }

    func testPageThatDidNotLoadKeepsTheLastReadingStaleAndRetriesAfterAMinute() async throws {
        let reader = AntigravityFixtureReader([.success(capture), .failure(.pageFailed), .success(capture)])
        let account = AntigravityFixtures.configuration()
        let clock = Clock(start)
        let provider = provider(
            account: account, marker: AntigravityWebSessionMarker(websiteDataStoreID: UUID()), reader: reader, clock: clock
        )
        let reading = try await provider.fetchUsage(for: account)
        clock.advance(5 * 60)
        let failed = try await provider.fetchUsage(for: account)

        XCTAssertTrue(failed.preserveCachedBarsOnFailure, "the refresh service keeps the last reading and marks it stale")
        XCTAssertEqual(failed.cacheIdentity, reading.cacheIdentity)
        XCTAssertTrue(failed.bars.isEmpty)
        XCTAssertFalse(failed.hasCurrentBars)
        XCTAssertEqual(failed.fetchedAt, start.addingTimeInterval(5 * 60))

        clock.advance(59)
        _ = try await provider.fetchUsage(for: account)
        var reads = await reader.markers
        XCTAssertEqual(reads.count, 2)
        clock.advance(1)
        let recovered = try await provider.fetchUsage(for: account)
        reads = await reader.markers
        XCTAssertEqual(reads.count, 3)
        XCTAssertNil(recovered.failureMessage)
    }

    func testUnrecognizedResponseIsAFailureNotUsage() async throws {
        let reader = AntigravityFixtureReader([.success(AntigravityPageCapture(quotaBody: "<html></html>"))])
        let account = AntigravityFixtures.configuration()
        let result = try await provider(
            account: account, marker: AntigravityWebSessionMarker(websiteDataStoreID: UUID()), reader: reader, clock: Clock(start)
        ).fetchUsage(for: account)
        XCTAssertEqual(result.failureMessage, AntigravityReadError.unreadableResponse.localizedDescription)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testRefreshSendsNothingThroughCodexBarsOwnNetworkSessions() async throws {
        AntigravityRequestRecorder.reset()
        XCTAssertTrue(URLProtocol.registerClass(AntigravityRequestRecorder.self))
        defer { URLProtocol.unregisterClass(AntigravityRequestRecorder.self) }

        let reader = AntigravityFixtureReader([.success(capture)])
        let account = AntigravityFixtures.configuration()
        let result = try await provider(
            account: account, marker: AntigravityWebSessionMarker(websiteDataStoreID: UUID()), reader: reader, clock: Clock(start)
        ).fetchUsage(for: account)

        XCTAssertEqual(result.bars.count, 4)
        XCTAssertEqual(AntigravityRequestRecorder.hosts, [], "the provider must not open a URL of its own")

        // The recorder does see CodexBar's sessions, so an empty list above is meaningful.
        _ = try? await URLSession.shared.data(from: URL(string: "https://recorder-self-check.invalid/")!)
        XCTAssertEqual(AntigravityRequestRecorder.hosts, ["recorder-self-check.invalid"])
    }
}

final class AntigravityRequestRecorder: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [String] = []

    static var hosts: [String] { lock.withLock { recorded } }

    static func reset() {
        lock.withLock { recorded = [] }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        lock.withLock { recorded.append(request.url?.host ?? "") }
        return true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
