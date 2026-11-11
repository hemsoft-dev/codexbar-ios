import XCTest

@MainActor
final class ClaudeUsageUITests: XCTestCase {
    private func exerciseSavedResetSelection() {
        continueAfterFailure = false
        let app = launch(scenario: "claude-resets-selection", runID: UUID().uuidString)
        tap(app.buttons["claude-view-resets-ui-claude"], in: app)
        XCTAssertTrue(app.navigationBars["Claude resets"].waitForExistence(timeout: 5))
        let explanation = app.staticTexts["CodexBar can currently use only the reset selected by Claude."]
        reveal(explanation, in: app)
        XCTAssertTrue(app.staticTexts["Other saved reset"].exists, app.debugDescription)
        XCTAssertTrue(explanation.isHittable, app.debugDescription)
        XCTAssertEqual(app.buttons.matching(identifier: "claude-use-reset").count, 1)
        XCTAssertFalse(app.staticTexts["Claude has not enabled this reset for use now."].exists)
        keep("claude-reset-selection-copy", app: app)
        tap(app.buttons["claude-use-reset"], in: app)
        let confirmation = app.alerts["Use one Claude reset?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmation.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "This cannot be undone.")).firstMatch.exists)
        keep("claude-reset-selection-confirmation", app: app)
        confirmation.buttons["Cancel"].tap()
        XCTAssertFalse(confirmation.exists)
        app.terminate()
    }

    private func exerciseSelectedUnusableReset() {
        continueAfterFailure = false
        for scenario in ["claude-resets-unusable-limit", "claude-resets-unusable-no-limit"] {
            let app = launch(scenario: scenario, runID: UUID().uuidString)
            tap(app.buttons["claude-view-resets-ui-claude"], in: app)
            let expected = scenario.hasSuffix("no-limit") ? "Claude has not enabled this reset for use now."
                : "Claude may require a usage limit to be reached before this reset can be used."
            XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(app.staticTexts["CodexBar can currently use only the reset selected by Claude."].exists)
            XCTAssertFalse(app.buttons["claude-use-reset"].exists)
            keep(scenario, app: app)
            app.terminate()
        }
    }

    func testWindowLabelsAndSavedCustomizationForProAndMax() {
        continueAfterFailure = false
        exerciseSavedResetSelection()
        exerciseSelectedUnusableReset()
        for scenario in ["claude-pro", "claude-max"] {
            let runID = UUID().uuidString
            let app = launch(scenario: scenario, runID: runID)
            let session = app.buttons["dashboard-metric-claude.session"]
            let weekly = app.buttons["dashboard-metric-claude.weekly-all"]
            XCTAssertTrue(session.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(weekly.exists, app.debugDescription)
            XCTAssertTrue(session.label.contains("5-hour"), session.label)
            XCTAssertTrue(session.label.contains("42%"), session.label)
            XCTAssertTrue(weekly.label.contains("Weekly"), weekly.label)
            XCTAssertTrue(weekly.label.contains("64%"), weekly.label)
            XCTAssertTrue(session.label.contains("Resets"), session.label)
            XCTAssertTrue(weekly.label.contains("Resets"), weekly.label)
            keep("\(scenario) dashboard", app: app)

            tap(app.buttons["More options for Synthetic Claude"], in: app)
            tap(app.buttons["Customize Card…"], in: app)
            XCTAssertTrue(app.navigationBars["Customize Card"].waitForExistence(timeout: 5))
            let sessionChoice = app.buttons["customize-metric-claude.session"]
            let weeklyChoice = app.buttons["customize-metric-claude.weekly-all"]
            XCTAssertTrue(sessionChoice.exists, app.debugDescription)
            XCTAssertTrue(weeklyChoice.exists, app.debugDescription)
            XCTAssertTrue(sessionChoice.label.contains("5-hour"), sessionChoice.label)
            XCTAssertTrue(weeklyChoice.label.contains("Weekly"), weeklyChoice.label)
            keep("\(scenario) Customize Card", app: app)
            tap(weeklyChoice, in: app)
            tap(app.buttons["Hide"], in: app)
            XCTAssertTrue(app.buttons["Show Weekly"].exists, app.debugDescription)
            tap(app.buttons["Done"], in: app)
            XCTAssertTrue(app.navigationBars["Customize Card"].waitForNonExistence(timeout: 5))
            XCTAssertTrue(weekly.waitForNonExistence(timeout: 5), app.debugDescription)
            app.terminate()

            let restored = launch(scenario: scenario, runID: runID, reset: false)
            XCTAssertTrue(restored.buttons["dashboard-metric-claude.session"].waitForExistence(timeout: 10))
            XCTAssertTrue(restored.buttons["dashboard-metric-claude.weekly-all"].waitForNonExistence(timeout: 5))
            restored.terminate()
        }
        for defaultText in [true, false] {
            for dark in [false, true] {
                exerciseSavedReset(defaultText: defaultText, dark: dark)
                exerciseFableAllowance(defaultText: defaultText, dark: dark)
            }
        }
        exerciseAmbiguousReset()
        exerciseUnavailableResets()
        exerciseResetTimeBoundary()
        exerciseResetDashboardBoundaries()
        exerciseResetCooldown()
    }

    private func exerciseFableAllowance(defaultText: Bool, dark: Bool) {
        let runID = UUID().uuidString
        let variant = "\(defaultText ? "default" : "accessibility2")-\(dark ? "dark" : "light")"
        var app = launch(scenario: "claude-fable-two-accounts", runID: runID, defaultText: defaultText, dark: dark)
        let first = fableMetric(percent: 21, in: app)
        let second = fableMetric(percent: 7, in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(first.label.contains("Fable") && first.label.contains("Resets"), first.label)
        XCTAssertTrue(app.buttons.matching(identifier: "dashboard-metric-claude.session").firstMatch.label.contains("42%"))
        XCTAssertTrue(app.buttons.matching(identifier: "dashboard-metric-claude.weekly-all").firstMatch.label.contains("64%"))
        reveal(first, in: app)
        keep("claude-fable-eligible-\(variant)", app: app)
        reveal(second, in: app)
        XCTAssertTrue(second.exists, app.debugDescription)
        keep("claude-fable-second-account-\(variant)", app: app)

        openFableCustomizer(in: app)
        let choice = app.buttons["customize-metric-claude.weekly-scoped-fable"]
        XCTAssertTrue(choice.exists, app.debugDescription)
        XCTAssertTrue(app.buttons["customize-metric-claude.session"].exists)
        XCTAssertTrue(app.buttons["customize-metric-claude.weekly-all"].exists)
        keep("claude-fable-customize-\(variant)", app: app)
        tap(choice, in: app)
        fableMenuChoice("Tile Width", in: app)
        fableMenuChoice("Half", in: app)
        tap(choice, in: app)
        fableMenuChoice("Visualization", in: app)
        fableMenuChoice("Circular ring", in: app)
        tap(choice, in: app)
        fableMenuChoice("Hide", in: app)
        XCTAssertTrue(app.buttons["Show Fable weekly usage limit"].exists, app.debugDescription)
        tap(app.buttons["Done"], in: app)
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))
        reveal(second, in: app)
        XCTAssertTrue(second.exists, "Hiding the first account must leave the second account's Fable visible")
        app.terminate()

        // The payload changes its model display name on relaunch while the
        // UUID-isolated account and saved metric choices stay the same.
        app = launch(scenario: "claude-fable-renamed", runID: runID, reset: false, defaultText: defaultText, dark: dark)
        XCTAssertTrue(app.buttons.matching(identifier: "dashboard-metric-claude.session").firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(fableMetric(percent: 21, in: app).exists)
        reveal(fableMetric(percent: 7, in: app), in: app)
        XCTAssertTrue(fableMetric(percent: 7, in: app).exists)
        keep("claude-fable-hidden-relaunch-\(variant)", app: app)
        openFableCustomizer(in: app)
        tap(app.buttons["Show Fable weekly usage limit"], in: app)
        tap(app.buttons["Done"], in: app)
        let restored = fableMetric(percent: 21, in: app)
        XCTAssertTrue(restored.waitForExistence(timeout: 5), app.debugDescription)
        reveal(restored, in: app)
        keep("claude-fable-restored-\(variant)", app: app)
        reveal(fableMetric(percent: 7, in: app), in: app)
        XCTAssertTrue(fableMetric(percent: 7, in: app).exists)
        openFableCustomizer(in: app)
        tap(app.buttons["customize-metric-claude.weekly-scoped-fable"], in: app)
        fableMenuChoice("Visualization", in: app)
        XCTAssertTrue(app.buttons["Circular ring"].isSelected, "Saved visualization must survive model rename and relaunch")
        fableMenuChoice("Circular ring", in: app)
        tap(app.buttons["customize-metric-claude.weekly-scoped-fable"], in: app)
        fableMenuChoice("Tile Width", in: app)
        XCTAssertTrue(app.buttons["Half"].isSelected, "Saved width must survive model rename and relaunch")
        fableMenuChoice("Half", in: app)
        tap(app.buttons["Done"], in: app)
        app.terminate()

        for scenario in ["claude-fable-absent", "claude-fable-credits"] {
            let missing = launch(scenario: scenario, runID: UUID().uuidString, defaultText: defaultText, dark: dark)
            XCTAssertTrue(missing.buttons["dashboard-metric-claude.session"].waitForExistence(timeout: 10))
            XCTAssertTrue(missing.buttons["dashboard-metric-claude.weekly-all"].exists)
            XCTAssertFalse(missing.buttons["dashboard-metric-claude.weekly-scoped-fable"].exists,
                           "Neither the plan label nor usage credits establish a Fable quota")
            if scenario == "claude-fable-credits" {
                let credits = missing.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Usage credits spent")).firstMatch
                XCTAssertTrue(credits.exists, missing.debugDescription)
                reveal(credits, in: missing)
            }
            keep("\(scenario)-\(variant)", app: missing)
            missing.terminate()
        }
    }

    private func fableMetric(percent: Int, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@",
            "dashboard-metric-claude.weekly-scoped-fable", "\(percent)%"
        )).firstMatch
    }

    private func openFableCustomizer(in app: XCUIApplication) {
        let menu = app.buttons["More options for Synthetic Claude"]
        reveal(menu, in: app, towardTop: true)
        XCTAssertTrue(menu.isEnabled, app.debugDescription)
        menu.tap()
        fableMenuChoice("Customize Card…", in: app)
        XCTAssertTrue(app.navigationBars["Customize Card"].waitForExistence(timeout: 5))
    }

    private func fableMenuChoice(_ label: String, in app: XCUIApplication) {
        // Popups live outside the scroll surface; do not scroll underneath them.
        let choice = app.buttons[label]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(choice.wait(for: \.isHittable, toEqual: true, timeout: 5))
        choice.tap()
    }

    private func exerciseSavedReset(defaultText: Bool, dark: Bool) {
        let runID = UUID().uuidString
        let scenario = "claude-resets-two-accounts"
        var app = launch(scenario: scenario, runID: runID, defaultText: defaultText, dark: dark)
        let variant = "\(defaultText ? "default" : "accessibility2")-\(dark ? "dark" : "light")"
        assertResetAvailability(2, account: "ui-claude", in: app)
        assertResetAvailability(1, account: "ui-claude-second", in: app)
        assertRequests(0, title: "Synthetic Claude", in: app)
        keep("claude-resets-available-\(variant)", app: app)
        tap(app.buttons["claude-view-resets-ui-claude"], in: app)
        let summary = app.staticTexts["claude-reset-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("2 resets available"), summary.label)
        tap(app.buttons["claude-use-reset"], in: app)
        let confirmation = app.alerts["Use one Claude reset?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), app.debugDescription)
        let message = confirmation.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "cannot be undone")).firstMatch
        XCTAssertTrue(message.exists, app.debugDescription)
        XCTAssertTrue(message.label.contains("Synthetic Claude"))
        XCTAssertTrue(message.label.contains("five-hour usage") && message.label.contains("weekly usage"))
        keep("claude-resets-confirmation-\(variant)", app: app)
        tap(confirmation.buttons["Cancel"], in: app)
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
        tap(app.buttons["Done"], in: app)
        assertRequests(0, title: "Synthetic Claude", in: app)
        assertResetAvailability(2, account: "ui-claude", in: app)
        tap(app.buttons["claude-view-resets-ui-claude"], in: app)
        tap(app.buttons["claude-use-reset"], in: app)
        tap(confirmation.buttons["Use reset"], in: app)
        let feedback = app.staticTexts["claude-reset-feedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(feedback.label.contains("Claude confirmed the reset"), feedback.label)
        XCTAssertTrue(summary.label.contains("1 reset available"), summary.label)
        keep("claude-resets-refreshed-\(variant)", app: app)
        tap(app.buttons["Done"], in: app)
        assertRequests(1, title: "Synthetic Claude", in: app)
        assertRequests(0, title: "Second Claude", in: app)
        assertResetAvailability(1, account: "ui-claude", in: app)
        assertResetAvailability(1, account: "ui-claude-second", in: app)
        for id in ["dashboard-metric-claude.session", "dashboard-metric-claude.weekly-all"] {
            let title = id.hasSuffix("session") ? "5-hour" : "Weekly"
            let value = id.hasSuffix("session") ? "42" : "64"
            let zero = app.buttons.matching(NSPredicate(
                format: "identifier == %@ AND label BEGINSWITH %@", id, "\(title), 0%, 0 of 100 used,"
            )).firstMatch
            let unchanged = app.buttons.matching(NSPredicate(
                format: "identifier == %@ AND label BEGINSWITH %@", id, "\(title), \(value)%, \(value) of 100 used,"
            )).firstMatch
            reveal(zero, in: app)
            XCTAssertTrue(zero.exists, app.debugDescription)
            reveal(unchanged, in: app)
            XCTAssertTrue(unchanged.exists, app.debugDescription)
        }
        keep("claude-resets-account-isolation-\(variant)", app: app)
        app.terminate()
        app = launch(scenario: scenario, runID: runID, reset: false, defaultText: defaultText, dark: dark)
        assertRequests(1, title: "Synthetic Claude", in: app)
        assertRequests(0, title: "Second Claude", in: app)
        assertResetAvailability(1, account: "ui-claude", in: app)
        app.terminate()
    }

    private func exerciseAmbiguousReset() {
        let runID = UUID().uuidString
        var app = launch(scenario: "claude-resets-error", runID: runID)
        for _ in 0..<2 {
            tap(app.buttons["claude-view-resets-ui-claude"], in: app)
            tap(app.buttons["claude-use-reset"], in: app)
            tap(app.alerts["Use one Claude reset?"].buttons["Use reset"], in: app)
            let feedback = app.staticTexts["claude-reset-feedback"]
            XCTAssertTrue(feedback.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(feedback.label.contains("has not confirmed"), feedback.label)
            keep("claude-resets-unconfirmed", app: app)
            tap(app.buttons["Done"], in: app)
            assertRequests(1, title: "Synthetic Claude", in: app)
            assertResetAvailability(2, account: "ui-claude", in: app)
        }
        app.terminate()
        app = launch(scenario: "claude-resets-error", runID: runID, reset: false)
        assertRequests(1, title: "Synthetic Claude", in: app)
        assertResetAvailability(2, account: "ui-claude", in: app)
        app.terminate()
    }

    private func exerciseUnavailableResets() {
        for scenario in ["zero", "ineligible", "paused", "inactive", "expired", "unknown", "malformed", "failed"] {
            let app = launch(scenario: "claude-resets-\(scenario)", runID: UUID().uuidString)
            let known = !["unknown", "malformed", "failed"].contains(scenario)
            let availability = app.staticTexts["claude-reset-availability-ui-claude"]
            reveal(availability, in: app)
            XCTAssertTrue(availability.label.contains(known ? "0 saved resets available" : "Saved resets unavailable"), availability.label)
            if known {
                tap(app.buttons["claude-view-resets-ui-claude"], in: app)
                XCTAssertTrue(app.navigationBars["Claude resets"].waitForExistence(timeout: 5))
                XCTAssertFalse(app.buttons["claude-use-reset"].exists, "Unavailable grant must have no consumption action")
                keep("claude-resets-\(scenario)", app: app)
                tap(app.buttons["Done"], in: app)
            } else {
                XCTAssertFalse(app.buttons["claude-view-resets-ui-claude"].exists)
                keep("claude-resets-\(scenario)", app: app)
            }
            if scenario != "failed" { assertRequests(0, title: "Synthetic Claude", in: app) }
            app.terminate()
        }
    }

    private func assertRequests(_ count: Int, title: String, in app: XCUIApplication) {
        let header = app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@ AND label CONTAINS %@", title + ", ", "Reset requests: \(count)"
        )).firstMatch
        reveal(header, in: app)
        XCTAssertTrue(header.exists, app.debugDescription)
    }

    private func exerciseResetTimeBoundary() {
        let app = launch(scenario: "claude-resets-boundary", runID: UUID().uuidString)
        tap(app.buttons["claude-view-resets-ui-claude"], in: app)
        let summary = app.staticTexts["claude-reset-summary"]
        XCTAssertTrue(summary.label.contains("2 resets available"), summary.label)
        let use = app.buttons["claude-use-reset"]
        XCTAssertTrue(use.exists, app.debugDescription)
        tap(use, in: app)
        let confirmation = app.alerts["Use one Claude reset?"]
        XCTAssertTrue(confirmation.exists)
        keep("claude-resets-before-expiry", app: app)
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 35), "An expiring grant must close its stale confirmation")
        XCTAssertFalse(use.exists, "An open sheet must remove consumption when the grant expires")
        XCTAssertTrue(summary.label.contains("0 resets available"), summary.label)
        XCTAssertTrue(app.staticTexts["Not currently available"].exists)
        keep("claude-resets-after-expiry", app: app)
        tap(app.buttons["Done"], in: app)
        assertRequests(0, title: "Synthetic Claude", in: app)
        app.terminate()
    }

    private func exerciseResetDashboardBoundaries() {
        for (scenario, before, after) in [("expiry", 2, 0), ("start", 0, 2)] {
            let app = launch(scenario: "claude-resets-dashboard-\(scenario)", runID: UUID().uuidString)
            let availability = app.staticTexts["claude-reset-availability-ui-claude"]
            assertResetAvailability(before, account: "ui-claude", in: app)
            keep("claude-resets-dashboard-\(scenario)-before", app: app)
            let updated = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label CONTAINS %@", "\(after) saved resets available"), object: availability
            )
            XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 35), .completed,
                           "The open dashboard must update without a refresh or another interaction")
            let expiry = app.staticTexts["claude-reset-expiration-ui-claude"]
            XCTAssertEqual(expiry.exists, after > 0, app.debugDescription)
            keep("claude-resets-dashboard-\(scenario)-after", app: app)
            assertRequests(0, title: "Synthetic Claude", in: app)
            app.terminate()
        }
    }

    private func exerciseResetCooldown() {
        let app = launch(scenario: "claude-resets-cooldown", runID: UUID().uuidString)
        tap(app.buttons["claude-view-resets-ui-claude"], in: app)
        let cooldown = app.staticTexts["claude-reset-cooldown"]
        XCTAssertTrue(cooldown.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(cooldown.label.contains("Claude reset cooldown ends"), cooldown.label)
        XCTAssertFalse(app.buttons["claude-use-reset"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "may require a usage limit")).firstMatch.exists)
        keep("claude-resets-cooldown-before", app: app)
        XCTAssertTrue(app.buttons["claude-use-reset"].waitForExistence(timeout: 35))
        XCTAssertFalse(cooldown.exists, app.debugDescription)
        keep("claude-resets-cooldown-after", app: app)
        tap(app.buttons["Done"], in: app)
        assertRequests(0, title: "Synthetic Claude", in: app)
        app.terminate()
    }

    private func assertResetAvailability(_ count: Int, account: String, in app: XCUIApplication) {
        let availability = app.staticTexts["claude-reset-availability-\(account)"]
        reveal(availability, in: app)
        XCTAssertTrue(availability.label.contains(count == 1 ? "1 saved reset available" : "\(count) saved resets available"), availability.label)
    }

    private func launch(scenario: String, runID: String, reset: Bool = true, defaultText: Bool = true, dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CODEXBAR_UI_TESTS": "1",
            "CODEXBAR_UI_TEST_RUN_ID": runID,
            "CODEXBAR_UI_TEST_RESET": reset ? "1" : "0",
            "CODEXBAR_UI_TEST_SCENARIO": scenario,
            "CODEXBAR_UI_TEST_DEFAULT_TEXT": defaultText ? "1" : "0",
            "CODEXBAR_UI_TEST_DARK": dark ? "1" : "0",
        ]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleInterfaceStyle", dark ? "Dark" : "Light"]
        app.launch()
        return app
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        XCTAssertTrue(element.isEnabled, app.debugDescription)
        element.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        _ = element.waitForExistence(timeout: 1)
        let navigationButton = app.navigationBars.buttons.matching(
            NSPredicate(format: "label == %@", element.label)
        ).firstMatch
        if element.exists && element.isHittable && navigationButton.exists
            && navigationButton.frame == element.frame { return }
        for alert in app.alerts.allElementsBoundByIndex {
            let button = alert.buttons.matching(NSPredicate(format: "label == %@", element.label)).firstMatch
            if element.exists && element.isHittable && button.exists && button.frame == element.frame
                && alert.frame.intersection(app.frame).contains(element.frame) { return }
        }
        let customizer = app.scrollViews["metric-customization-scroll"]
        let settings = app.collectionViews["provider-account-settings-form"]
        let scrollSurface = customizer.exists ? customizer : (settings.exists ? settings : app.scrollViews.firstMatch)
        let container = scrollSurface.exists ? scrollSurface : app
        for _ in 0..<12 {
            let bars = app.navigationBars.allElementsBoundByIndex.map(\.frame).filter {
                $0.width <= container.frame.width + 1 && $0.intersects(container.frame)
            }
            let top = max(container.frame.minY, bars.map(\.maxY).max() ?? container.frame.minY)
            let viewport = CGRect(x: container.frame.minX, y: top, width: container.frame.width,
                                  height: max(0, container.frame.maxY - top)).insetBy(dx: 4, dy: 0)
            if element.exists && element.isHittable && viewport.contains(element.frame) { return }
            let upward = element.exists ? element.frame.midY > viewport.midY : !towardTop
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.minX + min(8, viewport.width / 2) - app.frame.minX,
                                                  dy: viewport.minY + viewport.height * (upward ? 0.65 : 0.35) - app.frame.minY))
            let end = origin.withOffset(CGVector(dx: viewport.minX + min(8, viewport.width / 2) - app.frame.minX,
                                                dy: viewport.minY + viewport.height * (upward ? 0.4 : 0.6) - app.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Control outside the visible viewport: \(element).\n\(app.debugDescription)")
    }

    private func keep(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
