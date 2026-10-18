import XCTest
@testable import CodexBarIOS

final class StorefrontFixtureTests: XCTestCase {
    @MainActor
    func testStorefrontFreeSceneResolvesOneAccountAndSevenDayHistory() async throws {
        let scene = try XCTUnwrap(AppStoreScreenshotConfiguration.parse(arguments: [
            "CodexBarIOS", "--app-store-screenshots", "--app-store-scene", "free-overview",
        ])).scene
        let fixture = PlanAccessFixture(hasProAccess: scene.hasProAccess)
        let store = ProviderConfigurationStore.appStoreScreenshotDemo(singleAccount: !scene.hasProAccess)
        let results = AppStoreScreenshotFixtures.results(for: store)
        let history = AppStoreScreenshotFixtures.historyStore(for: results, extendedRange: true)
        let refresh = UsageRefreshService(providers: DemoUsageProvider.samples, initialResults: results)
        let coordinator = PlanAccessCoordinator(entitlement: fixture.entitlement, configurationStore: store,
                                               refreshService: refresh, historyStore: history)
        await fixture.entitlement.refresh()
        withExtendedLifetime(coordinator) {
            XCTAssertTrue(fixture.entitlement.isResolved)
            XCTAssertFalse(fixture.entitlement.hasAccess)
            XCTAssertEqual(store.visibleConfigurations.count, 1)
            XCTAssertTrue(store.accountAccess.isResolved)
            XCTAssertFalse(store.accountAccess.hasProAccess)
            XCTAssertEqual(history.accessPolicy, .free)
            XCTAssertFalse(history.accessPolicy.allows(range: .threeMonths))
            XCTAssertLessThanOrEqual(history.historySeries(for: results[0]).points.count, 8)
        }
    }

    @MainActor
    func testStorefrontProSceneResolvesMultipleAccountsAndNinetyDayHistory() async throws {
        let fixture = PlanAccessFixture(hasProAccess: AppStoreScreenshotScene.history.hasProAccess)
        let store = ProviderConfigurationStore.appStoreScreenshotDemo()
        let results = AppStoreScreenshotFixtures.results(for: store)
        let codex = try XCTUnwrap(results.first { $0.providerID == .codex })
        let history = AppStoreScreenshotFixtures.historyStore(for: results, extendedRange: true)
        let refresh = UsageRefreshService(providers: DemoUsageProvider.samples, initialResults: results)
        let coordinator = PlanAccessCoordinator(entitlement: fixture.entitlement, configurationStore: store,
                                               refreshService: refresh, historyStore: history)
        await fixture.entitlement.refresh()
        withExtendedLifetime(coordinator) {
            XCTAssertTrue(fixture.entitlement.isResolved)
            XCTAssertTrue(fixture.entitlement.hasAccess)
            XCTAssertGreaterThan(store.visibleConfigurations.count, 1)
            XCTAssertEqual(history.accessPolicy, .pro)
            XCTAssertTrue(history.accessPolicy.allows(range: .threeMonths))
            XCTAssertEqual(history.historySeries(for: codex).points.count, 90)
        }
    }

}
