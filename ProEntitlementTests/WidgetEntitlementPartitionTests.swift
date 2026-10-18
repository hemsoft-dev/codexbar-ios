import Foundation
import XCTest
@testable import CodexBarIOS

@MainActor
final class WidgetEntitlementPartitionTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    func testHealthyLegacyCacheAndIdenticalVerifiedJWSMigrateOnceWithoutInventingGeneration() async throws {
        let fixture = try WidgetEntitlementPartitionFixture(instant: instant)
        defer { fixture.cleanUp() }
        let evidence = fixture.evidence(environment: .production, signedOffset: -100, expiryOffset: 3_600)
        fixture.cache.records[.production] = fixture.resolved(evidence)
        let service = fixture.service()
        XCTAssertTrue(service.hasAccess)
        fixture.source.next = evidence
        await service.refresh()
        XCTAssertTrue(service.hasAccess)
        XCTAssertNil(service.widgetVerificationGeneration, "An identical signed replay is not a new generation")
        fixture.publish(service)
        let first = fixture.snapshot
        XCTAssertNotNil(fixture.effectiveDate(first))
        let deadline = try XCTUnwrap(service.value.proAccessEndsAt)
        fixture.clock.sample = testProClock(deadline)
        XCTAssertNil(fixture.effectiveDate(first))
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("widget-pro-access.json"))
        fixture.clock.sample = .init(wallDate: instant, continuousSeconds: 10, continuityID: "boot-B")
        await service.refresh()
        XCTAssertTrue(service.hasAccess)
        XCTAssertNil(service.widgetVerificationGeneration)
        fixture.publish(service)
        XCTAssertNil(fixture.effectiveDate(fixture.snapshot), "A previously stamped migration cannot be repeated after missing storage")
    }

    func testEnvironmentSwitchAcceptsEarlierSignedPopulatedCacheWithoutReusingOtherPartitionAuthority() async throws {
        try await checkEnvironmentSwitch(sameSignedTimeAndDeadline: false)
    }

    func testEqualDeadlineAndSignedTimeKeepIndependentEnvironmentExpiryAcrossRepeatedToggles() async throws {
        try await checkEnvironmentSwitch(sameSignedTimeAndDeadline: true)
    }

    private func checkEnvironmentSwitch(sameSignedTimeAndDeadline: Bool) async throws {
        let fixture = try WidgetEntitlementPartitionFixture(instant: instant)
        defer { fixture.cleanUp() }
        let sandbox = fixture.evidence(environment: .sandbox, signedOffset: -50, expiryOffset: 3_600)
        let production = fixture.evidence(
            environment: .production, signedOffset: sameSignedTimeAndDeadline ? -50 : -100,
            expiryOffset: sameSignedTimeAndDeadline ? 3_600 : 7_200
        )
        fixture.cache.records[.production] = fixture.resolved(production)
        let service = fixture.service()
        fixture.source.next = sandbox
        await service.refresh()
        XCTAssertTrue(service.hasAccess)
        let sandboxGeneration = try XCTUnwrap(service.widgetVerificationGeneration)
        fixture.publish(service)
        let sandboxSnapshot = fixture.snapshot
        let deadline = try XCTUnwrap(service.value.proAccessEndsAt)
        fixture.clock.sample = testProClock(deadline)
        XCTAssertNil(fixture.effectiveDate(sandboxSnapshot))
        fixture.clock.sample = .init(wallDate: instant, continuousSeconds: 10, continuityID: "boot-B")
        fixture.source.next = production
        await service.refresh()
        XCTAssertTrue(service.hasAccess)
        XCTAssertEqual(service.value.environment, .production)
        XCTAssertNil(service.widgetVerificationGeneration, "Cached destination's identical JWS must not inherit sandbox UUID")
        fixture.publish(service)
        XCTAssertNotNil(fixture.effectiveDate(fixture.snapshot))
        XCTAssertEqual(fixture.snapshot.accessPublication?.finiteGrant?.environment, .production)
        for _ in 0..<2 {
            fixture.source.next = sandbox
            await service.refresh()
            XCTAssertTrue(service.hasAccess, "Phone's older independent cache still grants; widget already observed expiry")
            XCTAssertEqual(service.widgetVerificationGeneration, sandboxGeneration)
            fixture.publish(service)
            XCTAssertNil(fixture.effectiveDate(fixture.snapshot))
            fixture.source.next = production
            await service.refresh()
            fixture.publish(service)
            XCTAssertNotNil(fixture.effectiveDate(fixture.snapshot))
        }
        XCTAssertEqual(fixture.snapshot.accessPublication?.observedPartitions, ["sandbox", "production"])
    }
}

@MainActor
private final class WidgetEntitlementPartitionFixture {
    let instant: Date
    let suite = "WidgetEntitlementPartitionTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = TestProCache()
    let source = TestProSource()
    let clock: WidgetEntitlementPartitionClock
    let configurationStore: ProviderConfigurationStore
    var snapshot: CodexBarWidgetSnapshot { WidgetSnapshotStore.loadSnapshot(defaults: defaults) }

    init(instant: Date) throws {
        self.instant = instant
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        clock = WidgetEntitlementPartitionClock(sample: testProClock(instant))
        configurationStore = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults,
            secretStore: WidgetEntitlementPartitionSecretStore(), widgetSnapshotDefaults: defaults
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func service() -> ProEntitlement {
        let clock = clock
        return ProEntitlement(source: source, cache: cache, now: { clock.sample.wallDate }, clock: { _ in clock.sample })
    }

    func evidence(environment: ProStoreEnvironment, signedOffset: TimeInterval, expiryOffset: TimeInterval) -> ProStoreSnapshot {
        ProStoreSnapshot(
            appPurchase: .verified(ProAppPurchase(
                originalVersion: "500", originalPurchaseDate: instant, environment: environment, revoked: false
            )),
            purchases: [ProPurchaseEvidence(
                product: .monthly, transactionID: 1, purchasedAt: instant.addingTimeInterval(-3_600),
                signedAt: instant.addingTimeInterval(signedOffset),
                expiresAt: instant.addingTimeInterval(expiryOffset), environment: environment
            ),
            ]
        )
    }

    func resolved(_ evidence: ProStoreSnapshot) -> ProEntitlementValue {
        ProEntitlementResolver.resolve(
            evidence, cached: .free, originalPolicy: ProOriginalPurchaserPolicy(), now: instant, clock: testProClock(instant)
        )
    }

    func publish(_ service: ProEntitlement) {
        WidgetSnapshotPublisher.publish(
            results: [], configurationStore: configurationStore, access: SnapshotProAccess(entitlement: service),
            snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: directory),
            now: clock.sample.wallDate, accessSample: clock.sample
        )
    }

    func effectiveDate(_ snapshot: CodexBarWidgetSnapshot) -> Date? {
        guard let publication = snapshot.accessPublication else { return nil }
        return WidgetAccessGuard(directory: directory).effectiveDate(for: publication, sample: clock.sample)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        source.finishStreams()
    }
}

@MainActor
private final class WidgetEntitlementPartitionClock {
    var sample: ProEntitlementClockSample
    init(sample: ProEntitlementClockSample) { self.sample = sample }
}

private struct WidgetEntitlementPartitionSecretStore: SecretStore {
    func readSecret(account: String) throws -> String? { nil }
    func saveSecret(_ secret: String, account: String) throws {}
    func deleteSecret(account: String) throws {}
}
