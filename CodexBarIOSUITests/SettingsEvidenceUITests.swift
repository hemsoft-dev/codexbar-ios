import XCTest

/// Manual-only rendered evidence. Automatic PR CI does not execute the UI-test target.
@MainActor
final class SettingsEvidenceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSettingsDismissalSignalRejectsTheBackgroundGear() {
        let app = launch()
        openSettings(app)
        XCTAssertTrue(app.navigationBars["Settings"].exists)
        let backgroundGear = app.buttons["Open settings"].firstMatch
        XCTAssertTrue(backgroundGear.exists, "The background gear must exist to exercise the false dismissal signal.")
        XCTAssertFalse(backgroundGear.isHittable, "The open Settings sheet must occlude the background gear.")
        capture("settings-open-background-gear")
        XCTAssertFalse(
            waitForSettingsDismissal(in: app, timeout: 0.2),
            "The Settings sheet is open; a background gear is not proof of dismissal."
        )
        tap(app.navigationBars.buttons["Done"].firstMatch, in: app)
        XCTAssertTrue(waitForSettingsDismissal(in: app))
        capture("settings-dismissed-dashboard")
        app.terminate()
    }

    func testEverySettingsDestinationAndDoneBack() {
        let app = launch()
        openSettings(app)
        capture("settings-home")
        let destinations = [
            ("accountsAndGroups", "Accounts & Groups", "Add Account"),
            ("dashboard", "Dashboard", "Appearance"),
            ("alerts", "Alerts", "Usage Alerts"),
            ("widgets", "Widgets", "Widget Builder"),
            ("helpAndAbout", "Help & About", "Feedback & Support"),
            ("dataAndRecovery", "Data & Recovery", "Reset Accounts"),
        ]
        for (destination, title, controlLabel) in destinations {
            select(destination, in: app)
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            let control = renderedControl(for: destination, in: app)
            XCTAssertTrue(control.waitForExistence(timeout: 5), "Missing \(controlLabel) in \(title)")
            capture("settings-\(destination)")
            returnToCategories(app)
        }
        tap(app.navigationBars.buttons["Done"].firstMatch, in: app)
        XCTAssertTrue(waitForSettingsDismissal(in: app))
        app.terminate()
    }

    func testPendingDuplicateGroupBlocksDoneUntilCorrected() {
        let app = launch()
        openSettings(app)
        select("accountsAndGroups", in: app)
        let field = app.textFields["New group"].firstMatch
        tap(field, in: app)
        field.typeText("Fixture Group")
        tap(app.buttons["Add group"].firstMatch, in: app)
        tap(field, in: app)
        field.typeText("Fixture Group")
        tap(app.navigationBars.buttons["Done"].firstMatch, in: app)
        let error = app.descendants(matching: .any).matching(identifier: "settings-group-validation-error").firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Accounts & Groups"].exists)
        capture("settings-pending-group-error")
        tap(field, in: app)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Fixture Group".count))
        field.typeText("Corrected Group")
        tap(app.navigationBars.buttons["Done"].firstMatch, in: app)
        XCTAssertTrue(waitForSettingsDismissal(in: app))
        openSettings(app)
        select("accountsAndGroups", in: app)
        XCTAssertTrue(app.textFields.containing(NSPredicate(format: "value == %@", "Corrected Group")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields.containing(NSPredicate(format: "value == %@", "Fixture Group")).firstMatch.waitForExistence(timeout: 5))
        capture("settings-corrected-groups")
        app.terminate()
    }

    func testSyntheticGrantedAndDeniedNotificationFeedback() {
        for granted in [false, true] {
            let app = launch(granted: granted)
            openSettings(app)
            select("alerts", in: app)
            tapSwitch(app.switches["Monitor GitHub Service Status"].firstMatch, in: app)
            let incident = app.switches["Incident Notifications"].firstMatch
            let recovery = app.switches["Recovery Notifications"].firstMatch
            XCTAssertTrue(incident.isEnabled)
            tapSwitch(incident, in: app)
            if granted {
                XCTAssertEqual(incident.value as? String, "1")
                tapSwitch(recovery, in: app)
                XCTAssertEqual(recovery.value as? String, "1")
            } else {
                let message = app.staticTexts["Notifications are disabled for CodexBar."].firstMatch
                reveal(message, in: app)
                XCTAssertTrue(message.waitForExistence(timeout: 5))
                XCTAssertEqual(incident.value as? String, "0")
                tapSwitch(recovery, in: app)
                XCTAssertTrue(message.waitForExistence(timeout: 5))
                XCTAssertEqual(recovery.value as? String, "0")
            }
            capture(granted ? "settings-notifications-granted" : "settings-notifications-denied")
            tap(app.navigationBars.buttons["Done"].firstMatch, in: app)
            XCTAssertTrue(waitForSettingsDismissal(in: app))
            openSettings(app)
            select("alerts", in: app)
            XCTAssertEqual(app.switches["Monitor GitHub Service Status"].firstMatch.value as? String, "1")
            reveal(incident, in: app)
            XCTAssertEqual(incident.value as? String, granted ? "1" : "0")
            reveal(recovery, in: app)
            XCTAssertEqual(recovery.value as? String, granted ? "1" : "0")
            capture("settings-notifications-persisted-\(granted)")
            tap(app.navigationBars.buttons["Done"].firstMatch, in: app)
            XCTAssertTrue(waitForSettingsDismissal(in: app))
            openSettings(app)
            select("alerts", in: app)
            tapSwitch(app.switches["Monitor GitHub Service Status"].firstMatch, in: app)
            reveal(incident, in: app)
            XCTAssertFalse(incident.isEnabled)
            reveal(recovery, in: app)
            XCTAssertFalse(recovery.isEnabled)
            capture("settings-monitor-disabled-\(granted)")
            app.terminate()
        }
    }

    private func renderedControl(for destination: String, in app: XCUIApplication) -> XCUIElement {
        switch destination {
        case "accountsAndGroups": app.buttons["Add Account"].firstMatch
        case "dashboard": app.staticTexts["Appearance"].firstMatch
        case "alerts": app.switches["Usage Alerts"].firstMatch
        case "widgets": app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Widget Builder")).firstMatch
        case "helpAndAbout": app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Feedback & Support")).firstMatch
        case "dataAndRecovery": app.buttons["Reset Accounts"].firstMatch
        default: app.otherElements["Unmapped Settings destination"].firstMatch
        }
    }

    private func launch(granted: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = [
            "CODEXBAR_UI_TESTS": "1",
            "CODEXBAR_UI_TEST_RUN_ID": UUID().uuidString,
            "CODEXBAR_UI_TEST_RESET": "1",
            "CODEXBAR_UI_TEST_SCENARIO": "settings-evidence",
            "CODEXBAR_UI_TEST_NOTIFICATION_GRANTED": granted ? "1" : "0",
        ]
        app.launch()
        return app
    }

    private func waitForSettingsDismissal(in app: XCUIApplication, timeout: TimeInterval = 5) -> Bool {
        let gear = app.buttons["Open settings"].firstMatch
        let accessibleDashboard = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: gear
        )
        return XCTWaiter.wait(for: [accessibleDashboard], timeout: timeout) == .completed
    }

    private func openSettings(_ app: XCUIApplication) {
        tap(app.buttons["Open settings"].firstMatch, in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    private func select(_ destination: String, in app: XCUIApplication) {
        let element = app.descendants(matching: .any).matching(identifier: "settings-\(destination)").firstMatch
        tap(element, in: app)
    }

    private func returnToCategories(_ app: XCUIApplication) {
        let category = app.descendants(matching: .any).matching(identifier: "settings-accountsAndGroups").firstMatch
        if category.exists && category.isHittable { return }
        let back = app.navigationBars.buttons["Settings"].firstMatch
        if back.exists {
            tap(back, in: app)
        } else {
            tap(app.navigationBars.buttons["Show Sidebar"].firstMatch, in: app)
        }
    }

    private func tapSwitch(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        let control = element.switches.firstMatch
        (control.exists ? control : element).tap()
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        element.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            let visibleTop = app.navigationBars.allElementsBoundByIndex.map { $0.frame.maxY }.max() ?? 0
            if element.exists && element.frame.midY < visibleTop {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        capture("settings-unreachable-control")
        XCTFail("Unreachable Settings control: \(element). UI: \(app.debugDescription)")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
final class SubscriptionUtilizationEvidenceUITests: XCTestCase {
    func testMissingGooglePoolShowsUnavailableSUS() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CODEXBAR_UI_TESTS": "1", "CODEXBAR_UI_TEST_RUN_ID": UUID().uuidString,
            "CODEXBAR_UI_TEST_RESET": "1", "CODEXBAR_UI_TEST_SCENARIO": "google-six",
            "CODEXBAR_UI_TEST_DEFAULT_TEXT": "1",
        ]
        app.launch()
        defer { app.terminate() }
        let argon = app.buttons["dashboard-metric-antigravity.gemini-argon-wtu-weekly"]
        XCTAssertTrue(argon.waitForExistence(timeout: 15))
        for _ in 0..<6 {
            if argon.isHittable && argon.frame.maxY <= app.frame.maxY - 16 { break }
            app.swipeUp()
        }
        XCTAssertTrue(argon.isHittable)
        XCTAssertLessThanOrEqual(argon.frame.maxY, app.frame.maxY - 16)
        XCTAssertTrue(argon.label.contains("Unavailable"))
        XCTAssertTrue(argon.label.contains("SUS unavailable"))
        capture("sus-missing-argon")
    }

    func testWeeklyBandsAndFleetScore() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CODEXBAR_UI_TESTS": "1", "CODEXBAR_UI_TEST_RUN_ID": UUID().uuidString,
            "CODEXBAR_UI_TEST_RESET": "1", "CODEXBAR_UI_TEST_SCENARIO": "sus-evidence",
            "CODEXBAR_UI_TEST_DEFAULT_TEXT": "1",
        ]
        app.launch()
        defer { app.terminate() }
        let fleet = app.descendants(matching: .any)["fleet-sus"].firstMatch
        XCTAssertTrue(fleet.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "SUS 95 of 100, green band")).firstMatch.exists)
        capture("sus-dashboard")
        let green = app.buttons["dashboard-metric-claude.weekly-0"]
        green.tap()
        XCTAssertTrue(app.staticTexts["Sub Utilization Score: 100 means full use at reset. Weekly windows need 12 hours of history."]
            .waitForExistence(timeout: 5))
        capture("sus-detail")
        app.buttons["Done"].tap()
        let yellow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "SUS 80 of 100, yellow band")).firstMatch
        let red = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "SUS 50 of 100, red band")).firstMatch
        let missing = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "SUS unavailable")).firstMatch
        for element in [yellow, red, missing] {
            for _ in 0..<5 where !element.isHittable { app.swipeUp() }
            XCTAssertTrue(element.exists)
            capture("sus-\(element == missing ? "unavailable" : element == red ? "red" : "yellow")")
        }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
