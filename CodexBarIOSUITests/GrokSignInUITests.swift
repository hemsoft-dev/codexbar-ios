import XCTest

@MainActor
final class GrokSignInUITests: XCTestCase {
    func testGuidedSetupCancellationReconnectAndRemoval() {
        let app = launch(scenario: "empty")
        XCTAssertTrue(app.buttons["dashboard-add-account"].waitForExistence(timeout: 10))
        app.buttons["dashboard-add-account"].tap()
        XCTAssertTrue(app.buttons["Grok"].waitForExistence(timeout: 5))
        keep("Grok Add Account", app: app)
        app.buttons["Grok"].tap()
        let signIn = app.buttons["grok-sign-in"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        XCTAssertEqual(app.secureTextFields.count, 0)
        keep("Grok disconnected settings", app: app)
        signIn.tap()
        XCTAssertTrue(app.buttons["Approve sample account"].waitForExistence(timeout: 5))
        keep("Grok sample approval", app: app)
        app.buttons["Decline"].tap()
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Disconnect Grok"].exists)
        keep("Grok canceled authorization", app: app)
        signIn.tap()
        XCTAssertTrue(app.buttons["Approve sample account"].waitForExistence(timeout: 5))
        app.buttons["Approve sample account"].tap()
        XCTAssertTrue(app.buttons["Return to Grok settings"].waitForExistence(timeout: 5))
        keep("Grok sample account connected", app: app)
        app.buttons["Return to Grok settings"].tap()
        XCTAssertTrue(app.buttons["Disconnect Grok"].waitForExistence(timeout: 10))
        keep("Grok connected settings", app: app)
        signIn.tap()
        XCTAssertTrue(app.buttons["Approve sample account"].waitForExistence(timeout: 5))
        app.buttons["Approve sample account"].tap()
        app.buttons["Return to Grok settings"].tap()
        keep("Grok reconnected settings", app: app)
        let disconnect = app.buttons["Disconnect Grok"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 5))
        let form = app.collectionViews["provider-account-settings-form"]
        for _ in 0..<6 where !disconnect.isHittable { form.swipeUp() }
        XCTAssertTrue(disconnect.wait(for: \.isHittable, toEqual: true, timeout: 10), app.debugDescription)
        disconnect.tap()
        XCTAssertFalse(app.buttons["Disconnect Grok"].exists)
        XCTAssertTrue(signIn.exists)
        keep("Grok local removal", app: app)
    }

    func testXSubscriptionGuidedSetupUsesOneXAISignIn() {
        let app = launch(scenario: "empty")
        XCTAssertTrue(app.buttons["dashboard-add-account"].waitForExistence(timeout: 10))
        app.buttons["dashboard-add-account"].tap()
        let provider = app.buttons["X Subscription"]
        XCTAssertTrue(provider.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Grok"].exists, "Grok stays available for legacy plans")
        XCTAssertTrue(app.buttons["Cursor"].exists, "Cursor stays available for legacy plans")
        keep("X Subscription Add Account", app: app)
        provider.tap()
        let signIn = app.buttons["x-subscription-sign-in"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        XCTAssertEqual(signIn.label, "Sign in with xAI")
        XCTAssertEqual(app.secureTextFields.count, 0)
        keep("X Subscription disconnected settings", app: app)
        signIn.tap()
        XCTAssertTrue(app.buttons["Approve sample account"].waitForExistence(timeout: 5))
        keep("X Subscription sample approval", app: app)
        app.buttons["Decline"].tap()
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Disconnect xAI"].exists)
        signIn.tap()
        XCTAssertTrue(app.buttons["Approve sample account"].waitForExistence(timeout: 5))
        app.buttons["Approve sample account"].tap()
        XCTAssertTrue(app.buttons["Return to X Subscription settings"].waitForExistence(timeout: 5))
        keep("X Subscription sample account connected", app: app)
        app.buttons["Return to X Subscription settings"].tap()
        XCTAssertTrue(app.buttons["Disconnect xAI"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["x-subscription-sign-in"].label, "Reconnect xAI")
        keep("X Subscription connected settings", app: app)
    }

    func testGrokAndCursorMetersStaySeparateAndNoAllowanceIsUnavailable() {
        let app = launch(scenario: "grok")
        let grok = app.buttons["dashboard-metric-grok.included-usage"]
        let bot = app.buttons["dashboard-metric-cursor.grok-bot-weekly"]
        XCTAssertTrue(grok.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(bot.exists, app.debugDescription)
        XCTAssertTrue(app.buttons["More options for SuperGrok Lite"].exists)
        XCTAssertTrue(app.staticTexts["Extra Usage Credits"].exists, app.debugDescription)
        let grokMetricIDs = Set(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "dashboard-metric-grok.")
        ).allElementsBoundByIndex.map(\.identifier))
        XCTAssertEqual(grokMetricIDs, [
            "dashboard-metric-grok.included-usage", "dashboard-metric-grok.monetary.balance.usd",
        ])
        keep("SuperGrok Lite beside Cursor", app: app)
        if grok.frame.maxY > app.frame.height * 0.8 { app.swipeUp() }
        keep("SuperGrok Lite weekly usage and credits", app: app)
        app.terminate()

        let zero = launch(scenario: "grok-zero")
        let zeroMeter = zero.buttons["dashboard-metric-grok.included-usage"]
        XCTAssertTrue(zeroMeter.waitForExistence(timeout: 10), zero.debugDescription)
        XCTAssertTrue(zeroMeter.label.contains("0%"), zeroMeter.label)
        XCTAssertTrue(zero.staticTexts["No included usage reported by Grok."].exists)
        XCTAssertTrue(zero.staticTexts["Extra Usage Credits"].exists)
        XCTAssertTrue(zero.buttons["dashboard-metric-cursor.grok-bot-weekly"].exists)
        if zeroMeter.frame.maxY > zero.frame.height * 0.8 { zero.swipeUp() }
        keep("SuperGrok Lite zero weekly usage beside Cursor", app: zero)
        zero.terminate()

        let missing = launch(scenario: "grok-percent-unavailable")
        XCTAssertTrue(missing.staticTexts["Grok did not report included usage."].waitForExistence(timeout: 10))
        XCTAssertFalse(missing.buttons["dashboard-metric-grok.included-usage"].exists)
        missing.swipeUp()
        keep("Grok unavailable percentage stays distinct from zero", app: missing)
        missing.terminate()

        let noAllowance = launch(scenario: "grok-no-allowance")
        XCTAssertTrue(noAllowance.staticTexts["No verified shared paid allowance was reported."].waitForExistence(timeout: 10))
        XCTAssertFalse(noAllowance.buttons["dashboard-metric-grok.included-usage"].exists)
        noAllowance.swipeUp()
        keep("Grok no eligible allowance", app: noAllowance)
    }

    func testSavedGrokLayoutAndWeeklyStates() {
        let runID = UUID().uuidString
        let existing = launch(scenario: "grok-existing", runID: runID)
        assertWeeklyBeforeCredits(in: existing, percent: "31%")
        keepGrok("Existing Grok saved credits-first order migrated", app: existing)
        existing.terminate()

        let restored = launch(scenario: "grok-existing", runID: runID, reset: false)
        assertWeeklyBeforeCredits(in: restored, percent: "31%")
        restored.terminate()

        let creditsOnly = launch(scenario: "grok-existing-credits-only")
        assertWeeklyBeforeCredits(in: creditsOnly, percent: "31%")
        keepGrok("Previously saved Grok credits-only layout", app: creditsOnly)
        creditsOnly.terminate()

        let fresh = launch(scenario: "grok")
        assertWeeklyBeforeCredits(in: fresh, percent: "31%")
        keepGrok("Fresh Grok weekly before credits", app: fresh)
        fresh.terminate()

        let zero = launch(scenario: "grok-existing-zero")
        assertWeeklyBeforeCredits(in: zero, percent: "0%")
        XCTAssertTrue(zero.staticTexts["No included usage reported by Grok."].exists)
        keepGrok("Existing Grok zero weekly before credits", app: zero)
        zero.terminate()

        let unavailable = launch(scenario: "grok-existing-percent-unavailable")
        XCTAssertTrue(unavailable.staticTexts["Grok did not report included usage."].waitForExistence(timeout: 10))
        XCTAssertFalse(unavailable.buttons["dashboard-metric-grok.included-usage"].exists)
        XCTAssertTrue(unavailable.buttons["dashboard-metric-grok.monetary.balance.usd"].exists)
        keepGrok("Existing Grok unavailable weekly with independent credits", app: unavailable)
        unavailable.terminate()

        let custom = launch(scenario: "grok-custom-order")
        let weekly = custom.buttons["dashboard-metric-grok.included-usage"]
        let credits = custom.buttons["dashboard-metric-grok.monetary.balance.usd"]
        XCTAssertTrue(weekly.waitForExistence(timeout: 10))
        XCTAssertTrue(credits.exists)
        XCTAssertLessThan(credits.frame.minY, weekly.frame.minY)
        keepGrok("Deliberate credits-first Grok order retained", app: custom)
    }

    func testCursorStaleSignInReconnectCancellationAndValidZero() {
        for suffix in ["", "-dark-large"] { exerciseCursorReconnect(suffix: suffix) }
        let unavailable = launch(scenario: "grok-cursor-session-no-prior")
        XCTAssertTrue(unavailable.buttons["Reconnect Cursor"].waitForExistence(timeout: 10), unavailable.debugDescription)
        let unavailableModels = unavailable.buttons["dashboard-metric-cursor.cursor-models"]
        XCTAssertTrue(unavailableModels.label.contains("Usage unavailable"), unavailableModels.label)
        XCTAssertFalse(unavailableModels.label.contains("%"), unavailableModels.label)
        keep("Cursor no prior data is unavailable", app: unavailable)
        unavailable.terminate()
        let zero = launch(scenario: "grok-cursor-session-zero-dark-large", darkAccessibility: true)
        let models = zero.buttons["dashboard-metric-cursor.cursor-models"]
        XCTAssertTrue(models.waitForExistence(timeout: 10), zero.debugDescription)
        XCTAssertTrue(models.label.contains("0%"), models.label)
        XCTAssertTrue(zero.buttons["dashboard-metric-cursor.other-models"].label.contains("0%"))
        XCTAssertFalse(zero.buttons["Reconnect Cursor"].exists)
        keep("Cursor valid zero with Bot rejection dark accessibility", app: zero)
    }

    private func exerciseCursorReconnect(suffix: String) {
        let app = launch(scenario: "grok-cursor-session-stale\(suffix)", darkAccessibility: suffix == "-dark-large")
        let fresh = app.buttons.matching(NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@", "dashboard-metric-cursor.cursor-models", "fresh"
        )).firstMatch
        XCTAssertTrue(fresh.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(fresh.label.contains("1%"), fresh.label)
        keep("Cursor before session invalidation\(suffix)", app: app)
        app.buttons["Refresh usage"].tap()
        let reconnect = app.buttons["Reconnect Cursor"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 10), app.debugDescription)
        let models = app.buttons["dashboard-metric-cursor.cursor-models"]
        XCTAssertTrue(models.label.contains("stale"), models.label)
        XCTAssertTrue(models.label.contains("1%"), models.label)
        XCTAssertTrue(app.buttons["dashboard-metric-cursor.other-models"].label.contains("13%"))
        XCTAssertTrue(app.staticTexts["cursor-stale-measurement-time"].exists)
        keep("Cursor retained stale data and reconnect\(suffix)", app: app)
        for _ in 0..<4 where !reconnect.isHittable { app.swipeUp() }
        XCTAssertTrue(reconnect.isHittable, app.debugDescription)
        XCTAssertGreaterThanOrEqual(reconnect.frame.height, 44)
        reconnect.tap()
        XCTAssertTrue(app.navigationBars["Synthetic Cursor sign-in"].waitForExistence(timeout: 10), app.debugDescription)
        keep("Cursor guided synthetic account selection\(suffix)", app: app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Cursor sign-in canceled. The existing account was not changed."]
            .waitForExistence(timeout: 10), app.debugDescription)
        keep("Cursor reconnect canceled without signing out\(suffix)", app: app)
        let form = app.collectionViews["provider-account-settings-form"]
        let settingsReconnect = form.buttons["Reconnect Cursor"]
        for _ in 0..<5 where !settingsReconnect.isHittable { form.swipeUp() }
        XCTAssertTrue(settingsReconnect.isHittable, app.debugDescription)
        settingsReconnect.tap()
        XCTAssertTrue(app.buttons["cursor-synthetic-approve"].waitForExistence(timeout: 5))
        app.buttons["cursor-synthetic-approve"].tap()
        XCTAssertTrue(app.buttons["Switch Cursor Account"].waitForExistence(timeout: 10), app.debugDescription)
        keep("Cursor successful reconnect settings\(suffix)", app: app)
        app.buttons["Done"].tap()
        XCTAssertTrue(fresh.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(fresh.label.contains("1%"), fresh.label)
        XCTAssertFalse(app.buttons["Reconnect Cursor"].exists)
        XCTAssertTrue(app.buttons["dashboard-metric-cursor.other-models"].label.contains("13%"))
        keep("Cursor recovered fresh usage\(suffix)", app: app)
        app.terminate()
    }

    func testCursorFreshPercentagesBotAndSavedChoices() {
        let runID = UUID().uuidString
        let app = launch(scenario: "grok-cursor-parity", runID: runID)
        assertCursor(in: app, botText: "41%")
        keep("Cursor fresh one and three with weekly Bot", app: app)
        let disclosure = app.buttons["Synthetic Cursor, Cursor plan usage"]
        disclosure.tap()
        XCTAssertTrue(app.buttons["dashboard-metric-cursor.cursor-models"].waitForNonExistence(timeout: 5))
        disclosure.tap()
        assertCursor(in: app, botText: "41%")
        app.buttons["dashboard-metric-cursor.cursor-models"].tap()
        XCTAssertTrue(app.navigationBars["Metric Details"].waitForExistence(timeout: 5))
        keep("Cursor fractional percentage detail", app: app)
        app.buttons["Done"].tap()
        openCursorCustomizer(in: app)
        for key in ["cursor-models", "other-models", "grok-bot-weekly", "on-demand"] {
            XCTAssertTrue(app.buttons["customize-metric-cursor.\(key)"].exists, app.debugDescription)
        }
        keep("Cursor all four customization choices", app: app)
        let models = app.buttons["customize-metric-cursor.cursor-models"]
        models.tap()
        tapChoice("Tile Width", in: app)
        tapChoice("Half", in: app)
        models.tap()
        tapChoice("Visualization", in: app)
        tapChoice("Circular ring", in: app)
        app.buttons["customize-metric-cursor.grok-bot-weekly"].tap()
        tapChoice("Hide", in: app)
        keep("Cursor Bot deliberately hidden", app: app)
        app.buttons["Done"].tap()
        XCTAssertFalse(app.buttons["dashboard-metric-cursor.grok-bot-weekly"].exists)
        keep("Cursor saved ring and hidden Bot dashboard", app: app)
        app.terminate()

        let restored = launch(scenario: "grok-cursor-parity", runID: runID, reset: false)
        let modelsRestored = loadedCursorModels(in: restored)
        XCTAssertTrue(modelsRestored.waitForExistence(timeout: 10), restored.debugDescription)
        XCTAssertFalse(restored.buttons["dashboard-metric-cursor.grok-bot-weekly"].exists)
        let otherRestored = restored.buttons["dashboard-metric-cursor.other-models"]
        XCTAssertTrue(otherRestored.wait(for: \.isHittable, toEqual: true, timeout: 5), restored.debugDescription)
        XCTAssertTrue(modelsRestored.wait(for: \.isHittable, toEqual: true, timeout: 5), restored.debugDescription)
        XCTAssertLessThan(modelsRestored.frame.width, otherRestored.frame.width)
        XCTAssertGreaterThan(modelsRestored.frame.height, otherRestored.frame.height)
        openCursorCustomizer(in: restored)
        let show = restored.buttons["Show Grok Bot weekly"]
        for _ in 0..<4 where !show.isHittable { restored.swipeUp() }
        XCTAssertTrue(show.wait(for: \.isHittable, toEqual: true, timeout: 5))
        show.tap()
        keep("Cursor hidden Bot restored from saved customization", app: restored)
        restored.buttons["Done"].tap()
        assertCursor(in: restored, botText: "41%")
        restored.buttons["Refresh usage"].tap()
        XCTAssertTrue(restored.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Fixture refresh failed"))
            .firstMatch.waitForExistence(timeout: 10), restored.debugDescription)
        XCTAssertTrue(modelsRestored.label.contains("1%"), modelsRestored.label)
        XCTAssertTrue(restored.buttons["dashboard-metric-cursor.other-models"].label.contains("3%"))
        XCTAssertTrue(modelsRestored.label.contains("stale"), modelsRestored.label)
        keep("Cursor failed refresh retains measured usage as stale", app: restored)
        restored.buttons["Refresh usage"].tap()
        let recovered = restored.buttons.matching(NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@", "dashboard-metric-cursor.cursor-models", "fresh"
        )).firstMatch
        XCTAssertTrue(recovered.waitForExistence(timeout: 10), restored.debugDescription)
        assertCursor(in: restored, botText: "41%")
        keep("Cursor recovered measured usage and saved layout", app: restored)
        restored.terminate()

        let unavailable = launch(scenario: "grok-cursor-parity-unavailable")
        assertCursor(in: unavailable, botText: "Cursor did not permit Grok Bot usage.")
        keep("Cursor unavailable Bot does not become zero or erase models", app: unavailable)
        openCursorCustomizer(in: unavailable)
        XCTAssertTrue(unavailable.buttons["customize-metric-cursor.grok-bot-weekly"].exists)
        keep("Cursor unavailable Bot remains customizable", app: unavailable)
    }

    func testCursorSubscriptionPillsAreAccountScoped() {
        for darkLarge in [false, true] {
            let runID = UUID().uuidString
            let scenario = "grok-cursor-parity-plans"
            let app = launch(scenario: scenario, runID: runID, darkAccessibility: darkLarge)
            let appearance = darkLarge ? "dark-large" : "light-default"
            for (title, plan) in [("Personal Cursor", "Pro"), ("Work Cursor", "Pro+"), ("Unknown Cursor", "Plan unavailable")] {
                let header = cursorPlanHeader(title, plan: plan, app: app)
                revealCursorPlanHeader(header, app: app)
                XCTAssertTrue(header.waitForExistence(timeout: 10), app.debugDescription)
                XCTAssertEqual(header.value as? String, "Expanded")
                keep("cursor-plan-\(title)-\(appearance)-expanded", app: app)
                header.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.4)).tap()
                XCTAssertEqual(header.value as? String, "Collapsed")
                keep("cursor-plan-\(title)-\(appearance)-collapsed", app: app)
            }
            for _ in 0..<6 { app.swipeDown() }
            app.buttons["Refresh usage"].tap()
            let stale = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "HTTP 503"))
            XCTAssertTrue(stale.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(cursorPlanHeader("Personal Cursor", plan: "Pro", app: app).exists)
            XCTAssertTrue(cursorPlanHeader("Work Cursor", plan: "Pro+", app: app).exists)
            keep("cursor-plans-stale-\(appearance)", app: app)
            app.terminate()
            let restored = launch(scenario: scenario, runID: runID, reset: false, darkAccessibility: darkLarge)
            for (title, plan) in [("Personal Cursor", "Pro"), ("Work Cursor", "Pro+"), ("Unknown Cursor", "Plan unavailable")] {
                let header = cursorPlanHeader(title, plan: plan, app: restored)
                revealCursorPlanHeader(header, app: restored)
                XCTAssertTrue(header.waitForExistence(timeout: 10), restored.debugDescription)
                XCTAssertEqual(header.value as? String, "Collapsed")
            }
            keep("cursor-plans-relaunch-\(appearance)", app: restored)
            restored.terminate()
        }
    }

    private func revealCursorPlanHeader(_ header: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(header.waitForExistence(timeout: 10), app.debugDescription)
        let top = app.buttons["Refresh usage"].frame.maxY + 12
        for _ in 0..<12 {
            if header.frame.minY < top {
                app.swipeDown()
            } else if header.frame.maxY > app.frame.maxY - 20 {
                app.swipeUp()
            } else {
                break
            }
        }
        XCTAssertTrue(header.isHittable, app.debugDescription)
    }

    private func cursorPlanHeader(_ title: String, plan: String, app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + ", " + plan)).firstMatch
    }

    private func assertCursor(in app: XCUIApplication, botText: String) {
        let models = loadedCursorModels(in: app)
        let other = app.buttons["dashboard-metric-cursor.other-models"]
        let bot = app.buttons["dashboard-metric-cursor.grok-bot-weekly"]
        XCTAssertTrue(models.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(other.label.contains("3%"), other.label)
        XCTAssertTrue(bot.label.contains(botText), bot.label)
        XCTAssertTrue(app.buttons["dashboard-metric-cursor.on-demand"].exists)
    }

    private func loadedCursorModels(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@", "dashboard-metric-cursor.cursor-models", "1%"
        )).firstMatch
    }

    private func openCursorCustomizer(in app: XCUIApplication) {
        let menu = app.buttons["More options for Synthetic Cursor"]
        XCTAssertTrue(menu.wait(for: \.isHittable, toEqual: true, timeout: 5), app.debugDescription)
        menu.tap()
        tapChoice("Customize Card…", in: app)
        XCTAssertTrue(app.navigationBars["Customize Card"].waitForExistence(timeout: 5))
    }

    private func tapChoice(_ label: String, in app: XCUIApplication) {
        let choice = app.buttons[label].firstMatch
        XCTAssertTrue(choice.wait(for: \.isHittable, toEqual: true, timeout: 5), app.debugDescription)
        choice.tap()
    }

    private func assertWeeklyBeforeCredits(in app: XCUIApplication, percent: String) {
        let weekly = app.buttons["dashboard-metric-grok.included-usage"]
        let credits = app.buttons["dashboard-metric-grok.monetary.balance.usd"]
        XCTAssertTrue(weekly.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(credits.exists, app.debugDescription)
        XCTAssertTrue(weekly.label.contains(percent), weekly.label)
        XCTAssertTrue(credits.label.contains("$5.00"), credits.label)
        XCTAssertLessThan(weekly.frame.minY, credits.frame.minY)
        XCTAssertTrue(app.buttons["dashboard-metric-cursor.grok-bot-weekly"].exists)
    }

    private func launch(
        scenario: String, runID: String = UUID().uuidString, reset: Bool = true, darkAccessibility: Bool = false
    ) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CODEXBAR_UI_TESTS": "1",
            "CODEXBAR_UI_TEST_RUN_ID": runID,
            "CODEXBAR_UI_TEST_RESET": reset ? "1" : "0",
            "CODEXBAR_UI_TEST_SCENARIO": scenario,
            "CODEXBAR_UI_TEST_DEFAULT_TEXT": scenario.hasPrefix("grok-cursor") && !darkAccessibility ? "1" : "0",
        ]
        if scenario.hasPrefix("grok-cursor") {
            app.launchEnvironment["CODEXBAR_UI_TEST_DARK"] = darkAccessibility ? "1" : "0"
        }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    private func keepGrok(_ name: String, app: XCUIApplication) {
        let credits = app.buttons["dashboard-metric-grok.monetary.balance.usd"]
        for _ in 0..<4 where credits.frame.maxY > app.frame.maxY - 40 { app.swipeUp() }
        XCTAssertLessThan(credits.frame.maxY, app.frame.maxY - 40)
        keep(name, app: app)
    }

    private func keep(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
