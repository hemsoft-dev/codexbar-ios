import XCTest

/// Isolated, manual-only journeys shared by iPhone and iPad test destinations.
@MainActor
final class FreeTierJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testFreeLimitAndAlertsUseTheSharedProDestination() {
        let app = launch("plan-free")
        defer { app.terminate() }
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "usage-alert-summary").firstMatch.exists)
        openSettings(app, destination: "accountsAndGroups")
        tap(app.buttons["Add Account"].firstMatch, in: app)
        assertPro(app)
        capture("free-account-limit")
        dismissPro(app)
        selectSettings("alerts", in: app)
        let alerts = app.switches["usage-alerts-toggle"].firstMatch
        reveal(alerts, in: app)
        XCTAssertEqual(alerts.value as? String, "0")
        capture("free-usage-alerts-off")
        tapSwitch(alerts, in: app)
        assertPro(app)
        dismissPro(app)
        XCTAssertEqual(alerts.value as? String, "0")
        let status = app.switches["Monitor GitHub Service Status"].firstMatch
        reveal(status, in: app)
        XCTAssertTrue(status.isEnabled, "Service-status notices remain available on Free.")
    }

    func testPausedAccountsKeepValuesAndCanSwitchAtLargeTextSize() {
        let app = launch("plan-free-cold", largeText: true)
        defer { app.terminate() }
        let chooser = app.navigationBars["Change active account"]
        XCTAssertTrue(chooser.waitForExistence(timeout: 10))
        let work = app.buttons["active-account-choice-plan-account-1"]
        reveal(work, in: app)
        XCTAssertTrue(work.label.contains("Credits remaining"), "The chooser must show the stored cold-start values.")
        capture("free-active-account-chooser-large-text")
        tap(work, in: app)
        XCTAssertTrue(chooser.waitForNonExistence(timeout: 5))
        let makePersonalActive = app.buttons["make-account-active-plan-account-0"]
        reveal(makePersonalActive, in: app)
        capture("free-paused-card-large-text")
        tap(makePersonalActive, in: app)
        XCTAssertTrue(chooser.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["active-account-choice-plan-account-1"].label.contains("Active account"))
        tap(app.buttons["active-account-choice-plan-account-0"], in: app)
        XCTAssertTrue(chooser.waitForNonExistence(timeout: 5))
        openSettings(app, destination: "accountsAndGroups")
        tap(app.buttons["settings-change-active-account"], in: app)
        XCTAssertTrue(app.buttons["active-account-choice-plan-account-0"].label.contains("Active account"))
        capture("free-active-account-selection-updated")
    }

    func testFreeHistoryRangesAreLockedAndDoNotLeaveTheSevenDayChart() {
        let app = launch("plan-free")
        defer { app.terminate() }
        let history = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Usage history.")).firstMatch
        tap(history, in: app)
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        let month = app.buttons["history-range-month"]
        let quarter = app.buttons["history-range-threeMonths"]
        XCTAssertEqual(month.value as? String, "Locked. CodexBar Pro")
        XCTAssertEqual(quarter.value as? String, "Locked. CodexBar Pro")
        XCTAssertTrue(app.buttons["history-range-sevenDays"].isSelected)
        capture("free-locked-history-ranges")
        tap(month, in: app)
        assertPro(app)
        dismissPro(app)
        XCTAssertTrue(app.buttons["history-range-sevenDays"].isSelected)
        tap(quarter, in: app)
        assertPro(app)
    }

    func testDowngradeAndUpgradeRestoreAccountsAndSavedAlertPreference() {
        let app = launch("plan-transition")
        defer { app.terminate() }
        let transition = app.buttons["fixture.plan.transition"]
        XCTAssertTrue(transition.waitForExistence(timeout: 10))
        XCTAssertEqual(transition.label, "Simulate downgrade")
        capture("plan-before-downgrade")
        tap(transition, in: app)
        XCTAssertTrue(app.navigationBars["Change active account"].waitForExistence(timeout: 5))
        tap(app.buttons["active-account-choice-plan-account-0"], in: app)
        let paused = app.buttons["make-account-active-plan-account-1"]
        reveal(paused, in: app)
        capture("plan-after-downgrade")
        tap(transition, in: app)
        XCTAssertTrue(paused.waitForNonExistence(timeout: 5))
        XCTAssertEqual(transition.label, "Simulate downgrade")
        capture("plan-after-upgrade")
        openSettings(app, destination: "alerts")
        let alerts = app.switches["usage-alerts-toggle"].firstMatch
        reveal(alerts, in: app)
        XCTAssertEqual(alerts.value as? String, "1", "The saved alert preference must return after upgrading.")
    }

    private func launch(_ scenario: String, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = [
            "CODEXBAR_UI_TESTS": "1",
            "CODEXBAR_UI_TEST_RUN_ID": UUID().uuidString,
            "CODEXBAR_UI_TEST_RESET": "1",
            "CODEXBAR_UI_TEST_SCENARIO": scenario,
            "CODEXBAR_UI_TEST_DEFAULT_TEXT": largeText ? "0" : "1",
        ]
        app.launch()
        return app
    }

    private func openSettings(_ app: XCUIApplication, destination: String) {
        tap(app.buttons["Open settings"].firstMatch, in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        selectSettings(destination, in: app)
    }

    private func selectSettings(_ destination: String, in app: XCUIApplication) {
        let category = app.descendants(matching: .any).matching(identifier: "settings-\(destination)").firstMatch
        if !category.isHittable {
            let back = app.navigationBars.buttons["Settings"].firstMatch
            if back.exists { tap(back, in: app) }
        }
        tap(category, in: app)
    }

    private func assertPro(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["CodexBar Pro"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Buy"].exists)
    }

    private func dismissPro(_ app: XCUIApplication) {
        tap(app.navigationBars["CodexBar Pro"].buttons["Done"], in: app)
        XCTAssertTrue(app.navigationBars["CodexBar Pro"].waitForNonExistence(timeout: 5))
    }

    private func tapSwitch(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        let control = element.switches.firstMatch
        if control.exists {
            control.tap()
        } else {
            // SwiftUI may expose the complete row as the switch on iPad.
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        element.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            let navigationBottom = app.navigationBars.allElementsBoundByIndex.map { $0.frame.maxY }.max() ?? 0
            if element.exists && element.frame.midY < navigationBottom { app.swipeDown() } else { app.swipeUp() }
        }
        capture("free-tier-unreachable-control")
        XCTFail("Unreachable control: \(element). UI: \(app.debugDescription)")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
