import XCTest
@testable import CodexBarIOS

@MainActor
final class FreeTierPresentationTests: XCTestCase {
    func testAddAccountFlowRefusesSecondAccountWithoutAdvancingToCredentialSetup() throws {
        let suiteName = "FreeTierPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProviderConfigurationStore(
            initialPlanAccess: .free,
            defaults: defaults,
            secretStore: EmptySecretStore(),
            widgetSnapshotDefaults: nil
        )
        var firstFlow = AddAccountFlowState()
        let firstID = try XCTUnwrap(firstFlow.select(.codex, configurationStore: store))
        var secondFlow = AddAccountFlowState()

        XCTAssertNil(secondFlow.select(.claude, configurationStore: store))
        XCTAssertNil(secondFlow.accountID)
        XCTAssertEqual(store.configurations.map(\.id), [firstID])
        XCTAssertTrue(store.requestedProPresentation)

        store.dismissProPresentation()
        XCTAssertEqual(firstFlow.select(.codex, configurationStore: store), firstID)
        XCTAssertEqual(store.configurations.count, 1)
        XCTAssertFalse(store.requestedProPresentation)
    }

    func testAddAccountFlowCanContinueAfterUpgradeWithoutReopeningSetup() throws {
        let suiteName = "FreeTierPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProviderConfigurationStore(
            initialPlanAccess: .free,
            defaults: defaults,
            secretStore: EmptySecretStore(),
            widgetSnapshotDefaults: nil
        )
        _ = try XCTUnwrap(store.addAccount(for: .codex))
        var flow = AddAccountFlowState()
        XCTAssertNil(flow.select(.claude, configurationStore: store))

        store.applyPlanAccess(hasProAccess: true, isResolved: true)
        store.dismissProPresentation()
        let accountID = try XCTUnwrap(flow.select(.claude, configurationStore: store))

        XCTAssertEqual(flow.accountID, accountID)
        XCTAssertEqual(store.configuration(accountID: accountID)?.providerID, .claude)
        XCTAssertEqual(store.configurations.count, 2)
        XCTAssertFalse(store.requestedProPresentation)
    }

    func testPausedAccountSettingsAnnouncePlanStateWithoutCallingAccountDisabled() {
        let account = ProviderAccountConfiguration(id: "claude.saved", providerID: .claude, isEnabled: true, authMethod: .browserSession)
        let value = ProviderSettingsRow.accessibilityValue(
            configuration: account,
            isConfigured: true,
            isPausedByPlan: true,
            groupName: "Work"
        )

        XCTAssertEqual(value, "Paused: CodexBar Pro, Work group")
        XCTAssertTrue(account.isEnabled)
    }
}
