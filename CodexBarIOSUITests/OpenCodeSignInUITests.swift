import XCTest

@MainActor
final class OpenCodeSignInUITests: XCTestCase {
    func testDisconnectedAccountOffersGuidedSignIn() throws {
        let app = launchAccountSettings()
        let signIn = app.buttons["Sign in with OpenCode"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Workspace ID"].exists)
        XCTAssertEqual(app.secureTextFields.count, 0)
        capture("OpenCode disconnected account", app: app)
        signIn.tap()
        XCTAssertTrue(app.buttons["Use browser sign-in"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Use private sign-in"].exists)
        capture("OpenCode browser choices", app: app)
        app.buttons["Use browser sign-in"].tap()
        XCTAssertTrue(app.staticTexts["Synthetic saved-session browser approval."].waitForExistence(timeout: 10))
        capture("Saved-session browser approval", app: app)
        app.buttons["Back to browser choices"].tap()
        XCTAssertTrue(app.buttons["Use private sign-in"].waitForExistence(timeout: 5))
        app.buttons["Use private sign-in"].tap()
        XCTAssertTrue(app.staticTexts["Synthetic private browser approval."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Choose Sample workspace"].exists)
        capture("Private browser retry", app: app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Remove Saved Credential"].exists)
        chooseWorkspace(in: app)
        app.buttons["Connect this workspace"].tap()
        XCTAssertTrue(app.staticTexts["Checking OpenCode approval"].waitForExistence(timeout: 5))
        capture("Approval check can be canceled", app: app)
        app.buttons["Approval not available"].tap()
        XCTAssertTrue(app.buttons["Use browser sign-in"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[
            "OpenCode approval is not available. Try signing in again. Your saved account was not changed."
        ].exists)
        capture("Unapproved browser return offers retry", app: app)
        app.buttons["Use browser sign-in"].tap()
        app.buttons["Choose Sample workspace"].tap()
        app.buttons["Connect this workspace"].tap()
        XCTAssertTrue(app.staticTexts["Checking OpenCode approval"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Remove Saved Credential"].exists)
        connect(in: app)
        capture("OpenCode connected", app: app)
        connect(in: app, signInButton: "Reconnect OpenCode")
        capture("OpenCode reconnected", app: app)
        app.buttons["Remove Saved Credential"].tap()
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Remove Saved Credential"].exists)
        XCTAssertFalse(app.textFields["Workspace ID"].exists)
        XCTAssertEqual(app.secureTextFields.count, 0)
        capture("Removed auth retains guided sign-in", app: app)
        connect(in: app)
        app.terminate()
        app.launchEnvironment["CODEXBAR_UI_TEST_RESET"] = "0"
        app.launch()
        assertConnectedAfterRelaunch(in: app)
    }

    /// The dashboard titles a generated OpenCode label by the products the account reports.
    /// The synthetic account reports only a Zen balance, so "OpenCode Go + Zen 1" shows as OpenCode Zen.
    private func assertConnectedAfterRelaunch(in app: XCUIApplication) {
        let menu = app.buttons["More options for OpenCode Zen"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["$25.00"].exists)
        capture("OpenCode connected after relaunch", app: app)
        menu.tap()
        let configure = app.buttons["Configure account OpenCode Zen"]
        XCTAssertTrue(configure.waitForExistence(timeout: 5), app.debugDescription)
        configure.tap()
        XCTAssertTrue(app.buttons["Reconnect OpenCode"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.navigationBars["OpenCode Go + Zen 1"].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["Remove Saved Credential"].exists)
        XCTAssertFalse(app.buttons["Sign in with OpenCode"].exists)
        capture("OpenCode saved credential after relaunch", app: app)
    }

    func testVerificationFailureKeepsAccountDisconnectedAndAllowsRetry() {
        let app = launchAccountSettings(failsVerification: true)
        chooseWorkspace(in: app, browserButton: "Use private sign-in")
        finishApproval(in: app)
        let message = app.staticTexts[
            "OpenCode usage could not be verified. Check your workspace and try again. Your saved account was not changed."
        ]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Remove Saved Credential"].exists)
        XCTAssertTrue(app.buttons["Sign in with OpenCode"].isEnabled)
        capture("Verification failure with retry", app: app)
        chooseWorkspace(in: app)
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.buttons["Remove Saved Credential"].exists)
        app.terminate()
        exerciseRenewalBillingStates()
    }

    private func exerciseRenewalBillingStates() {
        for dark in [false, true] {
            for state in ["renewing", "canceled", "payment", "mismatch", "balance-failure"] {
                let app = XCUIApplication()
                app.launchEnvironment = [
                    "CODEXBAR_UI_TESTS": "1", "CODEXBAR_UI_TEST_RUN_ID": UUID().uuidString,
                    "CODEXBAR_UI_TEST_RESET": "1", "CODEXBAR_UI_TEST_SCENARIO": "opencode-renewal-\(state)",
                    "CODEXBAR_UI_TEST_DEFAULT_TEXT": dark ? "0" : "1", "CODEXBAR_UI_TEST_DARK": dark ? "1" : "0",
                ]
                app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                app.launch()
                let title = state == "mismatch" ? "OpenCode Zen" : state == "balance-failure" ? "OpenCode Go" : "OpenCode Go + Zen"
                let header = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + ", ")).firstMatch
                XCTAssertTrue(header.waitForExistence(timeout: 10), app.debugDescription)
                let balance = app.staticTexts["$25.00"]
                if state != "balance-failure" { XCTAssertTrue(balance.waitForExistence(timeout: 10), app.debugDescription) }
                if state == "renewing" || state == "balance-failure" {
                    let renewal = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Renews in"), object: header)
                    XCTAssertEqual(XCTWaiter.wait(for: [renewal], timeout: 10), .completed)
                } else { XCTAssertFalse(header.label.contains("Renews in"), header.label) }
                XCTAssertFalse(header.label.contains("Plan unavailable"))
                capture("opencode-\(state)-\(dark ? "dark-large" : "light-default")-dashboard", app: app)
                if state == "renewing" {
                    app.buttons["Open settings"].firstMatch.tap()
                    let dashboard = app.descendants(matching: .any)["settings-dashboard"]
                    XCTAssertTrue(dashboard.waitForExistence(timeout: 5))
                    dashboard.tap()
                    let toggle = app.switches["settings-show-subscription-renewals"]
                    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
                    XCTAssertEqual(toggle.value as? String, "1")
                    toggle.switches.firstMatch.tap()
                    app.navigationBars.buttons["Done"].firstMatch.tap()
                    XCTAssertFalse(header.label.contains("Renews in"))
                    capture("opencode-hidden-\(dark ? "dark-large" : "light-default")-dashboard", app: app)
                    app.terminate()
                    app.launchEnvironment["CODEXBAR_UI_TEST_RESET"] = "0"
                    app.launch()
                    XCTAssertTrue(balance.waitForExistence(timeout: 10))
                    XCTAssertFalse(header.label.contains("Renews in"))
                    capture("opencode-hidden-persisted-\(dark ? "dark-large" : "light-default")", app: app)
                }
                app.terminate()
                app.launchEnvironment["CODEXBAR_UI_TEST_RESET"] = "0"
                app.launchEnvironment["CODEXBAR_UI_TEST_MORE_INFORMATION"] = "1"
                app.launchEnvironment["CODEXBAR_UI_TEST_MORE_INFORMATION_ACCOUNT"] = "ui-opencode-renewal"
                app.launch()
                let label = state == "renewing" || state == "balance-failure"
                    ? "Next subscription renewal" : state == "canceled" ? "Does not renew" : "Renewal date unavailable"
                XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 15), app.debugDescription)
                capture("opencode-\(state)-\(dark ? "dark-large" : "light-default")-details", app: app)
                app.terminate()
            }
        }
    }

    private func launchAccountSettings(failsVerification: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CODEXBAR_UI_TESTS": "1",
            "CODEXBAR_UI_TEST_RUN_ID": UUID().uuidString,
            "CODEXBAR_UI_TEST_RESET": "1",
            "CODEXBAR_UI_TEST_SCENARIO": "empty",
            "CODEXBAR_UI_TEST_OPENCODE_FAILURE": failsVerification ? "1" : "0",
        ]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["dashboard-add-account"].waitForExistence(timeout: 10))
        app.buttons["dashboard-add-account"].tap()
        let provider = app.buttons["OpenCode Go + Zen"]
        XCTAssertTrue(provider.waitForExistence(timeout: 5))
        provider.tap()
        return app
    }

    private func chooseWorkspace(
        in app: XCUIApplication, browserButton: String = "Use browser sign-in", signInButton: String = "Sign in with OpenCode"
    ) {
        app.buttons[signInButton].tap()
        XCTAssertTrue(app.buttons[browserButton].waitForExistence(timeout: 5))
        app.buttons[browserButton].tap()
        XCTAssertTrue(app.buttons["Choose Sample workspace"].waitForExistence(timeout: 10))
        app.buttons["Choose Sample workspace"].tap()
        XCTAssertTrue(app.buttons["Connect this workspace"].wait(for: \.isEnabled, toEqual: true, timeout: 10))
    }

    private func connect(in app: XCUIApplication, signInButton: String = "Sign in with OpenCode") {
        chooseWorkspace(in: app, signInButton: signInButton)
        capture("Selected workspace", app: app)
        finishApproval(in: app)
        XCTAssertTrue(app.buttons["Remove Saved Credential"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Reconnect OpenCode"].exists)
    }

    private func finishApproval(in app: XCUIApplication) {
        app.buttons["Connect this workspace"].tap()
        XCTAssertTrue(app.staticTexts["Checking OpenCode approval"].waitForExistence(timeout: 5))
        capture("Checking approval after browser return", app: app)
        app.buttons["Receive synthetic token"].tap()
        XCTAssertTrue(app.staticTexts["Verifying OpenCode account"].waitForExistence(timeout: 5))
        capture("Token received with verification pending", app: app)
        app.buttons["Finish synthetic verification"].tap()
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
