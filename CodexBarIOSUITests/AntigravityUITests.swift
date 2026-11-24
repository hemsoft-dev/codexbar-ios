import XCTest

/// Experimental Antigravity (#601). Every screen uses simulator fixtures: no Google page or account is opened.
@MainActor
final class AntigravityUITests: XCTestCase {
    private let meters = [
        "antigravityWeb.gemini-weekly", "antigravityWeb.gemini-5h", "antigravityWeb.3p-weekly", "antigravityWeb.3p-5h",
    ]

    func testNoticeComesFirstAndTheAccountExistsOnlyAfterGooglesPageReportsUsage() {
        let runID = UUID().uuidString
        var app = launch(scenario: "antigravity-add", runID: runID)
        let provider = openProviderList(in: app)
        XCTAssertTrue(provider.label.contains("Antigravity"), provider.label)
        XCTAssertTrue(provider.label.contains("Experimental"), provider.label)
        keep("Antigravity Add Account with Experimental label", app: app)

        // The notice comes before any sign-in, and canceling leaves no account.
        provider.tap()
        let accept = app.buttons["antigravity-notice-accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 10), app.debugDescription)
        for phrase in [
            "Google doesn't officially support third-party tools reading this page",
            "suspend an account",
            "keeps a Google web sign-in on this device",
        ] {
            XCTAssertTrue(text(containing: phrase, in: app).exists, phrase)
        }
        keep("Antigravity notice before sign-in", app: app)
        app.buttons["antigravity-sign-in-cancel"].tap()
        XCTAssertTrue(provider.waitForExistence(timeout: 10))
        XCTAssertTrue(text(containing: "Google sign-in canceled. No account was changed.", in: app).waitForExistence(timeout: 5))

        // A page that fails after the notice leaves no account either.
        provider.tap()
        XCTAssertTrue(accept.waitForExistence(timeout: 10))
        accept.tap()
        let fail = app.buttons["antigravity-synthetic-fail"]
        XCTAssertTrue(fail.waitForExistence(timeout: 10), app.debugDescription)
        fail.tap()
        XCTAssertTrue(text(containing: "Google sign-in could not load", in: app).waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["dashboard-add-account"].waitForExistence(timeout: 10))
        XCTAssertFalse(metric(meters[0], in: app).exists, "a failed sign-in must not leave a card")

        // The account appears once the page reports usage.
        _ = openProviderList(in: app)
        provider.tap()
        XCTAssertTrue(accept.waitForExistence(timeout: 10))
        accept.tap()
        let approve = app.buttons["antigravity-synthetic-approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 10))
        approve.tap()
        let signInAgain = app.buttons["antigravity-sign-in"]
        XCTAssertTrue(signInAgain.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(signInAgain.label, "Sign in Again")
        XCTAssertTrue(app.buttons["antigravity-sign-out"].exists)
        XCTAssertEqual(app.secureTextFields.count, 0, "setup never asks for a pasted credential")
        keep("Antigravity account settings after sign-in", app: app)
        app.buttons["Done"].tap()
        assertFourMeters(in: app)
        XCTAssertTrue(text(containing: "Google AI Ultra", in: app).exists)
        keep("Antigravity card with four meters", app: app)

        // The account, its sign-in marker and its card survive a relaunch.
        app.terminate()
        app = launch(scenario: "antigravity-add", runID: runID, reset: false)
        assertFourMeters(in: app)
    }

    /// Data saved by version 2.0's Gemini and Antigravity providers is removed at launch; the new account is not.
    ///
    /// By default the old on-disk records are seeded by the fixture. To run it over data that a real 2.0.0 build
    /// wrote, install that build, launch it once with a Google fixture account and a known run identifier, then pass
    /// `TEST_RUNNER_CODEXBAR_UPGRADE_RUN_ID` and `TEST_RUNNER_CODEXBAR_UPGRADE_KEPT_ACCOUNT` (see UI-TESTING.md).
    func testUpgradeFromRetiredGoogleAccountsKeepsANewAntigravityAccountAcrossRelaunches() {
        let environment = ProcessInfo.processInfo.environment
        let installedRunID = environment["CODEXBAR_UPGRADE_RUN_ID"]
        let runID = installedRunID ?? UUID().uuidString
        let keptAccount = "More options for \(environment["CODEXBAR_UPGRADE_KEPT_ACCOUNT"] ?? "Personal Codex")"
        var app = launch(scenario: "retired-google-upgrade", runID: runID, reset: installedRunID == nil)
        XCTAssertTrue(app.buttons[keptAccount].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(text(containing: "Google", in: app).exists, "the retired Google accounts were removed by the upgrade")
        XCTAssertFalse(text(containing: "Google Gemini", in: app).exists)
        XCTAssertFalse(text(containing: "Antigravity", in: app).exists, "the retired accounts were removed by the upgrade")

        app.buttons["Open settings"].firstMatch.tap()
        let accounts = app.descendants(matching: .any)["settings-accountsAndGroups"].firstMatch
        XCTAssertTrue(accounts.waitForExistence(timeout: 10))
        accounts.tap()
        let add = app.buttons["Add Account"].firstMatch
        for _ in 0..<6 where !(add.exists && add.isHittable) { app.swipeUp(velocity: .slow) }
        add.tap()
        let provider = app.buttons["add-account.provider.antigravityWeb"]
        for _ in 0..<4 where !(provider.exists && provider.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(provider.waitForExistence(timeout: 10), app.debugDescription)
        provider.tap()
        let accept = app.buttons["antigravity-notice-accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 10))
        accept.tap()
        let approve = app.buttons["antigravity-synthetic-approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 10))
        approve.tap()
        XCTAssertTrue(app.buttons["antigravity-sign-out"].waitForExistence(timeout: 10), app.debugDescription)
        keep("Antigravity added after the retired Google upgrade", app: app)

        for relaunch in 1...2 {
            app.terminate()
            app = launch(scenario: "retired-google-upgrade", runID: runID, reset: false)
            XCTAssertTrue(app.buttons[keptAccount].waitForExistence(timeout: 15), app.debugDescription)
            let card = app.buttons["More options for Antigravity 1"]
            reveal(card, in: app)
            XCTAssertTrue(card.exists, "relaunch \(relaunch): the new account must survive the launch cleanup")
            XCTAssertFalse(text(containing: "Google Gemini", in: app).exists)
            if relaunch == 2 { keep("Antigravity account after two relaunches", app: app) }
        }
        for _ in 0..<12 { app.swipeDown() }
        app.buttons["Preview synthetic widgets"].tap()
        XCTAssertTrue(app.navigationBars["Widget Builder"].waitForExistence(timeout: 5))
        XCTAssertTrue(text(containing: "Antigravity 1", in: app).waitForExistence(timeout: 5), "its widget tile is offered")
        keep("Antigravity widget tile after the upgrade", app: app)
    }

    func testCardStatesShowOnlyWhatGooglesPageReported() {
        for dark in [false, true] {
            let app = launch(scenario: "antigravity-states", runID: UUID().uuidString, dark: dark)
            let suffix = dark ? "dark" : "light"
            XCTAssertTrue(text(containing: "Fixture: four meters", in: app).waitForExistence(timeout: 15), app.debugDescription)

            reveal(text(containing: "Fixture: four meters", in: app), in: app)
            keep("Antigravity four meters \(suffix)", app: app)

            let needsComputer = text(containing: "connected computer", in: app)
            reveal(needsComputer, in: app)
            XCTAssertTrue(needsComputer.exists)
            keep("Antigravity unavailable without a computer \(suffix)", app: app)

            let signInAgain = text(containing: "Google asked you to sign in again", in: app)
            reveal(signInAgain, in: app)
            XCTAssertTrue(signInAgain.exists)
            keep("Antigravity sign in again \(suffix)", app: app)

            let stale = text(containing: "Google's Antigravity page didn't load", in: app)
            reveal(stale, in: app)
            XCTAssertTrue(stale.exists)
            keep("Antigravity stale reading \(suffix)", app: app)

            let weeklyLimit = text(containing: "Gemini Models five-hour, Weekly limit reached", in: app)
            reveal(weeklyLimit, in: app)
            XCTAssertTrue(weeklyLimit.exists, "a disabled five-hour pool says the weekly limit was reached")
            keep("Antigravity weekly limit reached \(suffix)", app: app)
            app.terminate()
        }
    }

    // MARK: Helpers

    private func openProviderList(in app: XCUIApplication) -> XCUIElement {
        let add = app.buttons["dashboard-add-account"]
        XCTAssertTrue(add.waitForExistence(timeout: 15), app.debugDescription)
        add.tap()
        let provider = app.buttons["add-account.provider.antigravityWeb"]
        for _ in 0..<4 where !provider.exists { app.swipeUp() }
        XCTAssertTrue(provider.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<4 where !provider.isHittable { app.swipeUp() }
        return provider
    }

    private func assertFourMeters(in app: XCUIApplication) {
        XCTAssertTrue(metric(meters[0], in: app).waitForExistence(timeout: 15), app.debugDescription)
        for meter in meters {
            reveal(metric(meter, in: app), in: app)
            XCTAssertTrue(metric(meter, in: app).exists, meter)
        }
        for _ in 0..<3 { app.swipeDown() }
    }

    private func metric(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["dashboard-metric-\(id)"].firstMatch
    }

    private func text(containing phrase: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", phrase)).firstMatch
    }

    /// Cards are ordered by the dashboard, not by this test, so look below first and then above.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<24 where !(element.exists && element.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        for _ in 0..<24 where !(element.exists && element.isHittable) {
            app.swipeDown(velocity: .slow)
        }
    }

    private func launch(scenario: String, runID: String, reset: Bool = true, dark: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CODEXBAR_UI_TESTS": "1",
            "CODEXBAR_UI_TEST_RUN_ID": runID,
            "CODEXBAR_UI_TEST_RESET": reset ? "1" : "0",
            "CODEXBAR_UI_TEST_SCENARIO": scenario,
            "CODEXBAR_UI_TEST_DEFAULT_TEXT": "1",
            "CODEXBAR_UI_TEST_DARK": dark ? "1" : "0",
        ]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleInterfaceStyle", dark ? "Dark" : "Light"]
        app.launch()
        return app
    }

    private func keep(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
