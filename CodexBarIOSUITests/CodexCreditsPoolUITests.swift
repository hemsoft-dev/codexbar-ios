import XCTest

@MainActor
final class CodexCreditsPoolUITests: XCTestCase {
    func testOptInBalanceStatesAndSavedAccountChoices() {
        continueAfterFailure = false
        let states = [
            ("codex-credits", "62,500 credits"),
            ("codex-credits-round-up", "62,501 credits"),
            ("codex-credits-zero", "0 credits"),
            ("codex-credits-unavailable", "Credits unavailable"),
            ("codex-credits-unlimited", "Unlimited credits"),
            ("codex-credits-failure", "62,500 credits"),
        ]
        for (scenario, expected) in states {
            let runID = UUID().uuidString
            var app = launch(scenario: scenario, runID: runID)
            let poolID = "dashboard-metric-codex.credits-pool"
            let quota = app.buttons.matching(NSPredicate(
                format: "identifier == %@ AND label CONTAINS %@", "dashboard-metric-codex.window-18000", "12%"
            )).firstMatch
            XCTAssertTrue(quota.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertFalse(app.buttons[poolID].exists, "Credit pool must be off by default")
            if scenario == "codex-credits" { keep("credits-default-dashboard", app: app) }
            openAccount("Personal Codex", in: app)
            let toggle = app.switches["account-metric-visibility-codex.credits-pool"]
            reveal(toggle, in: app)
            XCTAssertEqual(toggle.value as? String, "0", app.debugDescription)
            if scenario == "codex-credits" { keep("credits-settings-off", app: app) }
            // The labeled SwiftUI row also has a switch role; tap its native child switch.
            toggle.switches.firstMatch.tap()
            XCTAssertEqual(toggle.value as? String, "1", app.debugDescription)
            if scenario == "codex-credits" { keep("credits-settings-on", app: app) }
            app.terminate()
            app = launch(scenario: scenario, runID: runID, reset: false)
            let pool = app.buttons[poolID]
            XCTAssertTrue(pool.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(pool.label.contains(expected), pool.label)
            XCTAssertFalse(pool.label.contains("$"), pool.label)
            reveal(pool, in: app)
            keep("\(scenario)-dashboard", app: app)
            if scenario == "codex-credits" {
                tap(pool, in: app)
                XCTAssertTrue(app.navigationBars["Metric Details"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts[expected].exists, app.debugDescription)
                keep("credits-whole-count-details", app: app)
                tap(app.buttons["Done"], in: app)
                tap(app.buttons["Refresh usage"], in: app)
                XCTAssertTrue(pool.label.contains(expected), pool.label)
                keep("credits-whole-count-refreshed", app: app)
                openAccount("Work Codex", in: app)
                let workToggle = app.switches["account-metric-visibility-codex.credits-pool"]
                reveal(workToggle, in: app)
                XCTAssertEqual(workToggle.value as? String, "0", "The other account must remain off")
                app.terminate()
                app = launch(scenario: scenario, runID: runID, reset: false)
                tap(app.buttons["More options for Personal Codex"], in: app)
                tap(app.buttons["Customize Card…"], in: app)
                XCTAssertTrue(app.navigationBars["Customize Card"].waitForExistence(timeout: 5))
                let choice = app.buttons["customize-metric-codex.credits-pool"]
                reveal(choice, in: app)
                XCTAssertTrue(app.staticTexts["62,500"].exists, app.debugDescription)
                XCTAssertFalse(app.staticTexts["62,500 credits"].exists, app.debugDescription)
                keep("credits-customize-on", app: app)
                tap(choice, in: app)
                tap(app.buttons["Hide"], in: app)
                reveal(app.buttons["Show Credits pool"], in: app)
                tap(app.buttons["Done"], in: app)
                XCTAssertTrue(app.buttons[poolID].waitForNonExistence(timeout: 5), app.debugDescription)
                openAccount("Personal Codex", in: app)
                let restoredToggle = app.switches["account-metric-visibility-codex.credits-pool"]
                reveal(restoredToggle, in: app)
                XCTAssertEqual(restoredToggle.value as? String, "0")
                restoredToggle.switches.firstMatch.tap()
                app.terminate()
                app = launch(scenario: scenario, runID: runID, reset: false)
                XCTAssertTrue(app.buttons[poolID].waitForExistence(timeout: 10))
                XCTAssertTrue(app.buttons[poolID].label.contains("62,500 credits"))
            }
            if scenario == "codex-credits-failure" {
                let refresh = app.buttons["Refresh usage"]
                tap(refresh, in: app)
                let failureText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Synthetic refresh failed")).firstMatch
                XCTAssertTrue(failureText.waitForExistence(timeout: 10), app.debugDescription)
                XCTAssertTrue(app.buttons[poolID].label.contains("62,500 credits"), app.buttons[poolID].label)
                XCTAssertTrue(app.buttons[poolID].label.contains("stale"), app.buttons[poolID].label)
                reveal(app.buttons[poolID], in: app)
                keep("credits-stale-dashboard", app: app)
            }
            app.terminate()
        }
    }

    func testThirtyDayWindowLabelAndSavedVisibility() {
        continueAfterFailure = false
        let scenario = "codex-free-thirty-day"
        let runID = UUID().uuidString
        var app = launch(scenario: scenario, runID: runID)
        let metricID = "codex.window-2592000"
        let dashboardID = "dashboard-metric-\(metricID)"
        let quotaPredicate = NSPredicate(format: "identifier == %@ AND label CONTAINS %@", dashboardID, "12%")
        let quota = app.buttons.matching(quotaPredicate).firstMatch
        XCTAssertTrue(quota.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(quota.label.contains("30-day usage limit"), quota.label)
        XCTAssertTrue(quota.label.contains("12%"), quota.label)
        XCTAssertFalse(quota.label.contains("720 hour"), quota.label)
        reveal(quota, in: app)
        keep("codex-free-thirty-day-dashboard", app: app)
        openAccount("Personal Codex", in: app)
        let toggle = app.switches["account-metric-visibility-\(metricID)"]
        reveal(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(app.staticTexts["30-day usage limit"].exists, app.debugDescription)
        keep("codex-free-thirty-day-settings", app: app)
        app.terminate()
        app = launch(scenario: scenario, runID: runID, reset: false)
        tap(app.buttons["More options for Personal Codex"], in: app)
        tap(app.buttons["Customize Card…"], in: app)
        XCTAssertTrue(app.navigationBars["Customize Card"].waitForExistence(timeout: 5))
        let choice = app.buttons["customize-metric-\(metricID)"]
        reveal(choice, in: app)
        XCTAssertTrue(app.staticTexts["30-day usage limit"].exists, app.debugDescription)
        keep("codex-free-thirty-day-customize", app: app)
        tap(choice, in: app)
        tap(app.buttons["Hide"], in: app)
        tap(app.buttons["Done"], in: app)
        XCTAssertTrue(app.buttons.matching(quotaPredicate).firstMatch.waitForNonExistence(timeout: 5), app.debugDescription)
        app.terminate()
        app = launch(scenario: scenario, runID: runID, reset: false)
        let refreshedCard = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@",
            "Personal Codex", "Synthetic Codex Free usage. No live account."
        )).firstMatch
        XCTAssertTrue(refreshedCard.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons.matching(quotaPredicate).firstMatch.waitForNonExistence(timeout: 5), app.debugDescription)
        openAccount("Personal Codex", in: app)
        let savedToggle = app.switches["account-metric-visibility-\(metricID)"]
        reveal(savedToggle, in: app)
        XCTAssertEqual(savedToggle.value as? String, "0", "The saved thirty-day choice must survive relaunch")
        app.terminate()
    }

    func testPreciseSubscriptionPillsOnExpandedAndCollapsedCards() {
        continueAfterFailure = false
        for defaultText in [true, false] {
            for dark in [false, true] {
                let app = launchSpacingFixture(defaultText: defaultText, dark: dark, scenario: "plan-pills")
                // Follow provider/name order so lazy offscreen cards are reached from above.
                for (title, plan) in [
                    ("Codex Free fixture", "ChatGPT Free"),
                    ("Codex Plus fixture", "ChatGPT 20"),
                    ("Codex Pro fixture", "ChatGPT Pro 200"),
                    ("Codex Pro highest tier fixture", "ChatGPT Pro 500"),
                    ("Codex Pro lower tier fixture", "ChatGPT Pro 100"),
                    ("Codex unavailable fixture", "Plan unavailable"),
                    ("Claude Max fixture", "Max 5x"),
                    ("Long Google AI Ultra account name is not proof of a subscription", "Plan unavailable"),
                    ("Grok", "SuperGrok Lite"),
                    ("OpenRouter fixture", "API credits"),
                ] {
                    let header = app.descendants(matching: .any).matching(NSPredicate(
                        format: "label BEGINSWITH %@", title + ", " + plan
                    )).firstMatch
                    reveal(header, in: app)
                    XCTAssertEqual(header.value as? String, "Expanded", app.debugDescription)
                    keep("pill-\(title)-\(defaultText ? "default" : "accessibility2")-\(dark ? "dark" : "light")", app: app)
                    header.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.4)).tap()
                    XCTAssertEqual(header.value as? String, "Collapsed", app.debugDescription)
                    XCTAssertTrue(header.label.contains(plan))
                    keep("pill-collapsed-\(title)-\(defaultText ? "default" : "accessibility2")-\(dark ? "dark" : "light")", app: app)
                }
                tap(app.buttons["Refresh usage"], in: app)
                let sameAccount = app.descendants(matching: .any).matching(NSPredicate(
                    format: "label BEGINSWITH %@", "Codex Pro fixture, "
                )).firstMatch
                reveal(sameAccount, in: app, towardTop: true)
                let upgraded = app.descendants(matching: .any).matching(NSPredicate(
                    format: "label BEGINSWITH %@", "Codex Pro fixture, ChatGPT Pro 500"
                )).firstMatch
                XCTAssertTrue(upgraded.waitForExistence(timeout: 10), app.debugDescription)
                XCTAssertEqual(upgraded.value as? String, "Collapsed")
                keep("pill-upgraded-\(defaultText ? "default" : "accessibility2")-\(dark ? "dark" : "light")", app: app)
                app.terminate()
            }
        }
    }

    private func exerciseSubscriptionRenewals() {
        for dark in [false, true] {
            let app = launchSpacingFixture(defaultText: !dark, dark: dark, scenario: "subscription-renewals")
            let header = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Personal Codex, ChatGPT Pro 200")).firstMatch
            XCTAssertTrue(header.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(header.label.contains("Renews in"), header.label)
            keep("renewals-\(dark ? "dark-large" : "light-default")-expanded", app: app)
            header.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4)).tap()
            XCTAssertEqual(header.value as? String, "Collapsed")
            XCTAssertTrue(header.label.contains("Renews in"))
            keep("renewals-\(dark ? "dark-large" : "light-default")-collapsed", app: app)
            tap(app.buttons["More options for Personal Codex"], in: app)
            tap(app.buttons["More information for Personal Codex"], in: app)
            XCTAssertTrue(app.staticTexts["Next subscription renewal"].waitForExistence(timeout: 5), app.debugDescription)
            keep("renewals-\(dark ? "dark-large" : "light-default")-exact-date", app: app)
            tap(app.buttons["Done"], in: app)
            tap(app.buttons["Open settings"].firstMatch, in: app)
            tap(app.descendants(matching: .any)["settings-dashboard"], in: app)
            let toggle = app.switches["settings-show-subscription-renewals"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(toggle.value as? String, "1")
            keep("renewals-\(dark ? "dark-large" : "light-default")-setting-on", app: app)
            toggle.switches.firstMatch.tap()
            XCTAssertEqual(toggle.value as? String, "0")
            keep("renewals-\(dark ? "dark-large" : "light-default")-setting-off", app: app)
            tap(app.navigationBars.buttons["Done"].firstMatch, in: app)
            XCTAssertFalse(header.label.contains("Renews in"), header.label)
            keep("renewals-\(dark ? "dark-large" : "light-default")-off-immediate", app: app)
            let hiddenClaude = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Personal Claude, ")).firstMatch
            reveal(hiddenClaude, in: app)
            XCTAssertFalse(hiddenClaude.label.contains("Renews in"))
            keep("renewals-Claude-\(dark ? "dark-large" : "light-default")-hidden", app: app)
            var environment = app.launchEnvironment
            environment["CODEXBAR_UI_TEST_RESET"] = "0"
            app.terminate()
            app.launchEnvironment = environment
            app.launch()
            XCTAssertTrue(header.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertFalse(header.label.contains("Renews in"), header.label)
            keep("renewals-\(dark ? "dark-large" : "light-default")-off-persisted", app: app)
            tap(app.buttons["Open settings"].firstMatch, in: app)
            tap(app.descendants(matching: .any)["settings-dashboard"], in: app)
            XCTAssertEqual(toggle.value as? String, "0")
            toggle.switches.firstMatch.tap()
            tap(app.navigationBars.buttons["Done"].firstMatch, in: app)
            XCTAssertTrue(header.label.contains("Renews in"), header.label)
            keep("renewals-\(dark ? "dark-large" : "light-default")-on-restored", app: app)
            for title in ["Work Codex", "Personal Claude", "Personal Google", "Personal Grok", "OpenCode Go + Zen"] {
                let other = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + ", ")).firstMatch
                reveal(other, in: app)
                XCTAssertTrue(other.label.contains("Renews in"), other.label)
                if title == "OpenCode Go + Zen" { XCTAssertFalse(other.label.contains("Plan unavailable")) }
                keep("renewals-\(title)-\(dark ? "dark-large" : "light-default")", app: app)
                if title == "Personal Claude" {
                    tap(app.buttons["More options for \(title)"], in: app)
                    tap(app.buttons["More information for \(title)"], in: app)
                    XCTAssertTrue(app.staticTexts["Next subscription renewal"].waitForExistence(timeout: 5))
                    keep("renewals-Claude-\(dark ? "dark-large" : "light-default")-exact", app: app)
                    tap(app.navigationBars.buttons["Done"].firstMatch, in: app)
                }
                if ["Personal Claude", "Personal Grok"].contains(title) {
                    other.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4)).tap()
                    XCTAssertEqual(other.value as? String, "Collapsed")
                    XCTAssertTrue(other.label.contains("Renews in"))
                    keep("renewals-\(title)-\(dark ? "dark-large" : "light-default")-collapsed", app: app)
                    other.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4)).tap()
                }
            }
            app.terminate()
        }
        for state in ["unknown", "canceled", "stale", "past"] {
            let app = launchSpacingFixture(defaultText: true, dark: false, scenario: "subscription-renewals-\(state)")
            let header = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Personal Codex, ChatGPT Pro 200")).firstMatch
            XCTAssertTrue(header.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertFalse(header.label.contains("Renews in"), header.label)
            tap(app.buttons["More options for Personal Codex"], in: app)
            tap(app.buttons["More information for Personal Codex"], in: app)
            let expected = state == "unknown" ? "Renewal date unavailable" : state == "canceled" ? "Does not renew"
                : state == "stale" ? "Last known billing date" : "Billing date passed"
            XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 5), app.debugDescription)
            keep("renewals-\(state)-details", app: app)
            tap(app.navigationBars.buttons["Done"].firstMatch, in: app)
            for title in ["Personal Claude", "Personal Grok"] {
                let providerHeader = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + ", ")).firstMatch
                reveal(providerHeader, in: app)
                XCTAssertFalse(providerHeader.label.contains("Renews in"), providerHeader.label)
                tap(app.buttons["More options for \(title)"], in: app)
                tap(app.buttons["More information for \(title)"], in: app)
                XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 5), app.debugDescription)
                keep("renewals-\(title)-\(state)-details", app: app)
                tap(app.navigationBars.buttons["Done"].firstMatch, in: app)
            }
            app.terminate()
        }
        for dark in [false, true] {
            let app = launchSpacingFixture(defaultText: !dark, dark: dark, scenario: "google-plan-free")
            let header = app.descendants(matching: .any).matching(NSPredicate(
                format: "label BEGINSWITH %@", "Personal Google, Google AI Free"
            )).firstMatch
            XCTAssertTrue(header.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertFalse(header.label.contains("Renews"), header.label)
            tap(app.buttons["More options for Personal Google"], in: app)
            XCTAssertFalse(app.buttons["More information for Personal Google"].exists, app.debugDescription)
            keep("renewals-google-free-\(dark ? "dark-large" : "light-default")", app: app)
            app.terminate()
        }
        for state in ["unknown", "canceled"] {
            let app = launchSpacingFixture(defaultText: false, dark: true, scenario: "subscription-renewals-\(state)")
            let header = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Personal Claude, ")).firstMatch
            reveal(header, in: app)
            XCTAssertFalse(header.label.contains("Renews in"))
            XCTAssertTrue(header.label.contains("Max 20x"), header.label)
            tap(app.buttons["More options for Personal Claude"], in: app)
            tap(app.buttons["More information for Personal Claude"], in: app)
            XCTAssertTrue(app.staticTexts[state == "unknown" ? "Renewal date unavailable" : "Does not renew"].waitForExistence(timeout: 5))
            keep("renewals-Claude-dark-large-\(state)", app: app)
            tap(app.navigationBars.buttons["Done"].firstMatch, in: app)
            app.terminate()
        }
        exerciseSubscriptionBillingConnections()
    }

    private func exerciseCursorRenewals() {
        for dark in [false, true] {
            let appearance = dark ? "dark-large" : "light-default"
            let app = launchSpacingFixture(defaultText: !dark, dark: dark, scenario: "subscription-renewals", cursorOnly: true)
            for title in ["Personal Cursor", "Annual Cursor"] {
                let header = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + ", Pro")).firstMatch
                reveal(header, in: app)
                XCTAssertTrue(header.label.contains("Renews in"), header.label)
                keep("cursor-\(title)-\(appearance)-expanded", app: app)
                header.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4)).tap()
                XCTAssertEqual(header.value as? String, "Collapsed")
                XCTAssertTrue(header.label.contains("Renews in"), header.label)
                keep("cursor-\(title)-\(appearance)-collapsed", app: app)
                tap(app.buttons["More options for \(title)"], in: app)
                tap(app.buttons["More information for \(title)"], in: app)
                XCTAssertTrue(app.staticTexts["Next subscription renewal"].waitForExistence(timeout: 5), app.debugDescription)
                keep("cursor-\(title)-\(appearance)-exact", app: app)
                tap(app.navigationBars.buttons["Done"].firstMatch, in: app)
            }
            tap(app.buttons["Open settings"].firstMatch, in: app)
            tap(app.descendants(matching: .any)["settings-dashboard"], in: app)
            let toggle = app.switches["settings-show-subscription-renewals"]
            XCTAssertEqual(toggle.value as? String, "1")
            toggle.switches.firstMatch.tap()
            keep("cursor-\(appearance)-setting-off", app: app)
            tap(app.navigationBars.buttons["Done"].firstMatch, in: app)
            let cursor = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Personal Cursor, Pro")).firstMatch
            reveal(cursor, in: app)
            XCTAssertFalse(cursor.label.contains("Renews in"))
            keep("cursor-\(appearance)-hidden", app: app)
            app.terminate()
            app.launchEnvironment["CODEXBAR_UI_TEST_RESET"] = "0"
            app.launch()
            reveal(cursor, in: app)
            XCTAssertFalse(cursor.label.contains("Renews in"))
            keep("cursor-\(appearance)-hidden-persisted", app: app)
            app.terminate()
            for state in ["canceled", "unknown", "stale", "past"] {
                let stateApp = launchSpacingFixture(defaultText: !dark, dark: dark, scenario: "subscription-renewals-\(state)", cursorOnly: true)
                let header = stateApp.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Personal Cursor, Pro")).firstMatch
                reveal(header, in: stateApp)
                XCTAssertFalse(header.label.contains("Renews in"), header.label)
                tap(stateApp.buttons["More options for Personal Cursor"], in: stateApp)
                tap(stateApp.buttons["More information for Personal Cursor"], in: stateApp)
                let expected = state == "canceled" ? "Does not renew" : state == "unknown" ? "Renewal date unavailable"
                    : state == "stale" ? "Last known billing date" : "Billing date passed"
                XCTAssertTrue(stateApp.staticTexts[expected].waitForExistence(timeout: 5), stateApp.debugDescription)
                keep("cursor-\(appearance)-\(state)", app: stateApp)
                stateApp.terminate()
            }
        }
    }

    private func exerciseSubscriptionBillingConnections() {
        let app = launchSpacingFixture(defaultText: true, dark: false, scenario: "subscription-renewals")
        for title in ["Personal Claude", "Personal Grok"] {
            if title == "Personal Claude" {
                app.terminate()
                app.launchEnvironment["CODEXBAR_UI_TEST_SCENARIO"] = "subscription-renewals-unknown"
                app.launch()
                tap(app.buttons["More options for \(title)"], in: app)
                tap(app.buttons["More information for \(title)"], in: app)
                XCTAssertTrue(app.staticTexts["Renewal date unavailable"].waitForExistence(timeout: 5))
                keep("billing-Claude-recovery", app: app)
                tap(app.buttons["subscription-billing-settings"], in: app)
            } else {
                tap(app.buttons["More options for \(title)"], in: app)
                tap(app.buttons["Configure account \(title)"], in: app)
            }
            XCTAssertTrue(app.collectionViews["provider-account-settings-form"].waitForExistence(timeout: 5), app.debugDescription)
            keep("billing-\(title)-disconnected", app: app)
            tap(app.buttons["subscription-billing-connect"], in: app)
            tap(app.buttons["subscription-billing-synthetic-wrong"], in: app)
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "different account")).firstMatch
                .waitForExistence(timeout: 10), app.debugDescription)
            keep("billing-\(title)-wrong-account", app: app)
            tap(app.buttons["Reload Sign-In"], in: app)
            XCTAssertTrue(app.buttons["subscription-billing-synthetic-match"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "different account")).firstMatch.exists)
            keep("billing-\(title)-reloaded", app: app)
            tap(app.buttons["subscription-billing-synthetic-match"], in: app)
            XCTAssertTrue(app.buttons["subscription-billing-disconnect"].waitForExistence(timeout: 10), app.debugDescription)
            keep("billing-\(title)-connected", app: app)
            tap(app.buttons["subscription-billing-disconnect"], in: app)
            XCTAssertFalse(app.buttons["subscription-billing-disconnect"].exists)
            tap(app.buttons["subscription-billing-connect"], in: app)
            XCTAssertTrue(app.buttons["subscription-billing-synthetic-match"].waitForExistence(timeout: 5))
            tap(app.navigationBars.buttons["Cancel"].firstMatch, in: app)
            XCTAssertTrue(app.collectionViews["provider-account-settings-form"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["subscription-billing-disconnect"].exists)
            keep("billing-\(title)-canceled", app: app)
            tap(app.navigationBars.buttons["Done"].firstMatch, in: app)
        }
        app.terminate()
    }

    private func exerciseGoogleAndOpenCodePlanPills() {
        continueAfterFailure = false
        let variants = [("free", "Google AI Free"), ("plus", "Google AI Plus (400 GB)"),
                        ("pro", "Google AI Pro (5 TB)"), ("ultra", "Google AI Ultra"),
                        ("ultra5", "Google AI Ultra 5x"), ("ultra20", "Google AI Ultra 20x"),
                        ("unknown", "Plan unavailable"),
        ]
        for (variant, label) in variants {
            for dark in [false, true] {
                let app = launchSpacingFixture(defaultText: !dark, dark: dark, scenario: "google-plan-\(variant)")
                let header = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Personal Google, \(label)")).firstMatch
                XCTAssertTrue(header.waitForExistence(timeout: 10), app.debugDescription)
                reveal(header, in: app, towardTop: true)
                keep("google-\(variant)-\(dark ? "dark-large" : "light-default")-expanded", app: app)
                header.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
                XCTAssertEqual(header.value as? String, "Collapsed", app.debugDescription)
                let openCode = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "OpenCode Go + Zen, Synthetic")).firstMatch
                reveal(openCode, in: app)
                XCTAssertTrue(openCode.exists, app.debugDescription)
                XCTAssertFalse(openCode.label.contains("Plan unavailable"))
                XCTAssertFalse(openCode.label.contains("Google AI"))
                keep("google-\(variant)-\(dark ? "dark-large" : "light-default")-collapsed-opencode", app: app)
                openCode.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
                XCTAssertEqual(openCode.value as? String, "Collapsed", app.debugDescription)
                keep("google-\(variant)-\(dark ? "dark-large" : "light-default")-both-collapsed", app: app)
                app.terminate()
            }
        }
    }

    func testCompactCardHeadersAndIndependentControls() {
        continueAfterFailure = false
        if ProcessInfo.processInfo.environment["CODEXBAR_UI_TEST_SUBJOURNEY"] == "cursor-renewals" {
            exerciseCursorRenewals()
            return
        }
        if ProcessInfo.processInfo.environment["CODEXBAR_UI_TEST_SUBJOURNEY"] == "billing" {
            exerciseSubscriptionBillingConnections()
            return
        }
        exerciseSubscriptionRenewals()
        exerciseCursorRenewals()
        // Routine issue validation may select this subjourney; release runs keep every scenario.
        if ProcessInfo.processInfo.environment["CODEXBAR_UI_TEST_SUBJOURNEY"] == "renewals" { return }
        exerciseGoogleAndOpenCodePlanPills()
        exerciseClaudeProfilePills()
        for defaultText in [true, false] {
            for dark in [false, true] {
                let app = launchSpacingFixture(defaultText: defaultText, dark: dark)
                let quota = personalQuota(in: app)
                XCTAssertTrue(quota.waitForExistence(timeout: 10), app.debugDescription)
                let menu = app.buttons["More options for Personal Codex"]
                XCTAssertGreaterThanOrEqual(menu.frame.width, 44)
                XCTAssertGreaterThanOrEqual(menu.frame.height, 44)
                keep("spacing-\(defaultText ? "default" : "accessibility2")-\(dark ? "dark" : "light")", app: app)
                let disclosure = app.descendants(matching: .any)["Personal Codex, Plan unavailable, Synthetic Codex usage, Normal status"]
                XCTAssertTrue(disclosure.exists, app.debugDescription)
                XCTAssertEqual(disclosure.value as? String, "Expanded", app.debugDescription)
                disclosure.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.4)).tap()
                XCTAssertTrue(quota.waitForNonExistence(timeout: 5))
                XCTAssertEqual(disclosure.value as? String, "Collapsed")
                keep("spacing-collapsed-\(defaultText ? "default" : "accessibility2")-\(dark ? "dark" : "light")", app: app)
                disclosure.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.4)).tap()
                XCTAssertTrue(quota.waitForExistence(timeout: 5))
                if defaultText && !dark { exerciseSpacingNavigation(in: app) }
                app.terminate()

                let badge = launchSpacingFixture(defaultText: defaultText, dark: dark, scenario: "codex-free-thirty-day")
                let thirtyDay = badge.buttons.matching(NSPredicate(
                    format: "identifier == %@ AND label CONTAINS %@", "dashboard-metric-codex.window-2592000", "12%"
                )).firstMatch
                XCTAssertTrue(thirtyDay.waitForExistence(timeout: 10), badge.debugDescription)
                let badgeMenu = badge.buttons["More options for Personal Codex"]
                XCTAssertGreaterThanOrEqual(badgeMenu.frame.height, 44)
                keep("spacing-badge-\(defaultText ? "default" : "accessibility2")-\(dark ? "dark" : "light")", app: badge)
                badge.terminate()
            }
        }
        let stale = launchSpacingFixture(defaultText: true, dark: false, scenario: "codex-credits-failure")
        XCTAssertTrue(personalQuota(in: stale).waitForExistence(timeout: 10))
        tap(stale.buttons["Refresh usage"], in: stale)
        let failure = stale.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Synthetic refresh failed")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 10), stale.debugDescription)
        XCTAssertTrue(personalQuota(in: stale).label.contains("stale"))
        keep("spacing-stale", app: stale)
        stale.terminate()
    }

    private func exerciseClaudeProfilePills() {
        for (scenario, plan, defaultText, dark) in [
            ("claude-plan-pro", "Pro", true, false),
            ("claude-plan-max20", "Max 20x", true, false),
            ("claude-plan-unknown", "Plan unavailable", true, false),
            ("claude-plan-change", "Max 5x", false, true),
        ] {
            let app = launchSpacingFixture(defaultText: defaultText, dark: dark, scenario: scenario)
            let header = claudeProfileHeader(plan: plan, in: app)
            XCTAssertTrue(header.waitForExistence(timeout: 10), app.debugDescription)
            reveal(header, in: app)
            XCTAssertEqual(header.value as? String, "Expanded")
            XCTAssertTrue(app.buttons["dashboard-metric-claude.session"].label.contains("42%"))
            keep("\(scenario)-expanded", app: app)
            header.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.4)).tap()
            XCTAssertEqual(header.value as? String, "Collapsed")
            keep("\(scenario)-collapsed", app: app)
            if scenario == "claude-plan-change" {
                tap(app.buttons["Refresh usage"], in: app)
                let changed = claudeProfileHeader(plan: "Max 20x", in: app)
                XCTAssertTrue(changed.waitForExistence(timeout: 10), app.debugDescription)
                reveal(changed, in: app)
                XCTAssertEqual(changed.value as? String, "Collapsed")
                keep("claude-plan-changed-collapsed-dark-large", app: app)
                changed.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.4)).tap()
                XCTAssertTrue(app.buttons["dashboard-metric-claude.session"].label.contains("42%"))
                keep("claude-plan-changed-expanded-dark-large", app: app)
            }
            app.terminate()
        }
    }

    private func claudeProfileHeader(plan: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@", "Synthetic Claude, " + plan
        )).firstMatch
    }

    private func launchSpacingFixture(defaultText: Bool, dark: Bool, scenario: String = "codex-credits", cursorOnly: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CODEXBAR_UI_TESTS": "1", "CODEXBAR_UI_TEST_RUN_ID": UUID().uuidString,
            "CODEXBAR_UI_TEST_RESET": "1", "CODEXBAR_UI_TEST_SCENARIO": scenario,
            "CODEXBAR_UI_TEST_DEFAULT_TEXT": defaultText ? "1" : "0",
            "CODEXBAR_UI_TEST_DARK": dark ? "1" : "0",
            "CODEXBAR_UI_TEST_CURSOR_ONLY": cursorOnly ? "1" : "0",
        ]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleInterfaceStyle", dark ? "Dark" : "Light"]
        app.launch()
        return app
    }

    private func personalQuota(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@", "dashboard-metric-codex.window-18000", "12%"
        )).firstMatch
    }

    private func exerciseSpacingNavigation(in app: XCUIApplication) {
        let quota = personalQuota(in: app)
        tap(quota, in: app)
        XCTAssertTrue(app.navigationBars["Metric Details"].waitForExistence(timeout: 5), app.debugDescription)
        keep("spacing-metric-details", app: app)
        tap(app.buttons["Done"], in: app)
        tap(app.buttons["More options for Personal Codex"], in: app)
        tap(app.buttons["Customize Card…"], in: app)
        XCTAssertTrue(app.navigationBars["Customize Card"].waitForExistence(timeout: 5))
        tap(app.buttons["customize-metric-codex.window-18000"], in: app)
        tapMenuChoice("Tile Width", in: app)
        tapMenuChoice("Half", in: app)
        tap(app.buttons["customize-metric-codex.window-18000"], in: app)
        tapMenuChoice("Visualization", in: app)
        tapMenuChoice("Circular ring", in: app)
        tap(app.buttons["customize-metric-codex.window-604800"], in: app)
        tapMenuChoice("Tile Width", in: app)
        tapMenuChoice("Half", in: app)
        keep("spacing-customize-half-ring", app: app)
        tap(app.buttons["Done"], in: app)
        XCTAssertTrue(quota.waitForExistence(timeout: 5))
        XCTAssertTrue(quota.label.contains("12%"))
        let weekly = app.buttons.matching(identifier: "dashboard-metric-codex.window-604800").firstMatch
        XCTAssertLessThan(quota.frame.width, app.frame.width * 0.6)
        XCTAssertEqual(quota.frame.minY, weekly.frame.minY, accuracy: 1)
        XCTAssertEqual(quota.frame.height, weekly.frame.height, accuracy: 1)
        let savedWidth = quota.frame.width
        keep("spacing-half-ring-dashboard", app: app)
        openAccount("Personal Codex", in: app)
        let title = "Personal Codex with a deliberately long account heading"
        let field = app.textFields["account-label"]
        tap(field, in: app)
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { field.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText(" with a deliberately long account heading")
        tap(app.navigationBars.buttons["Accounts & Groups"], in: app)
        XCTAssertTrue(app.navigationBars["Accounts & Groups"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchEnvironment["CODEXBAR_UI_TEST_RESET"] = "0"
        app.launch()
        XCTAssertTrue(quota.waitForExistence(timeout: 10), app.debugDescription)
        let renamedMenu = app.buttons["More options for \(title)"]
        XCTAssertTrue(renamedMenu.exists, app.debugDescription)
        XCTAssertGreaterThanOrEqual(renamedMenu.frame.height, 44)
        XCTAssertTrue(quota.label.contains("12%"))
        XCTAssertEqual(quota.frame.width, savedWidth, accuracy: 1)
        XCTAssertEqual(quota.frame.minY, weekly.frame.minY, accuracy: 1)
        keep("spacing-long-heading-saved-layout", app: app)
    }

    private func tapMenuChoice(_ label: String, in app: XCUIApplication) {
        let choice = app.buttons[label]
        // Popup choices are outside the customizer's scroll subtree. Scrolling
        // that underlying view can dismiss a submenu before it finishes opening.
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(choice.wait(for: \.isHittable, toEqual: true, timeout: 5), app.debugDescription)
        choice.tap()
    }

    private func launch(scenario: String, runID: String, reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CODEXBAR_UI_TESTS": "1", "CODEXBAR_UI_TEST_RUN_ID": runID,
            "CODEXBAR_UI_TEST_RESET": reset ? "1" : "0", "CODEXBAR_UI_TEST_SCENARIO": scenario,
            "CODEXBAR_UI_TEST_DEFAULT_TEXT": ["codex-credits", "codex-credits-zero"].contains(scenario) ? "1" : "0",
            "CODEXBAR_UI_TEST_DARK": scenario == "codex-credits-round-up" || scenario == "codex-credits-failure" ? "1" : "0",
        ]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    private func openAccount(_ label: String, in app: XCUIApplication) {
        tap(app.buttons["Open settings"].firstMatch, in: app)
        tap(app.descendants(matching: .any)["settings-accountsAndGroups"].firstMatch, in: app)
        XCTAssertTrue(app.navigationBars["Accounts & Groups"].waitForExistence(timeout: 10))
        tap(app.otherElements[label], in: app)
        XCTAssertTrue(app.navigationBars[label].waitForExistence(timeout: 10), app.debugDescription)
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        XCTAssertTrue(element.isEnabled, app.debugDescription)
        element.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        _ = element.waitForExistence(timeout: 1)
        if element.exists && element.isHittable && app.navigationBars.buttons.matching(
            NSPredicate(format: "label == %@", element.label)
        ).firstMatch.exists { return }
        let customizer = app.scrollViews["metric-customization-scroll"]
        let settings = app.collectionViews["provider-account-settings-form"]
        var container = customizer.exists ? customizer : (settings.exists ? settings : app.scrollViews.firstMatch)
        if element.exists && element.identifier.hasPrefix("settings-") {
            let containingCollection = app.collectionViews.containing(.button, identifier: element.identifier).firstMatch
            if containingCollection.exists { container = containingCollection }
        }
        for _ in 0..<12 {
            let bars = app.navigationBars.allElementsBoundByIndex.map(\.frame).filter {
                $0.width <= container.frame.width + 1 && $0.intersects(container.frame)
            }
            let top = max(container.frame.minY, bars.map(\.maxY).max() ?? container.frame.minY)
            let viewport = CGRect(x: container.frame.minX, y: top, width: container.frame.width,
                                  height: max(0, container.frame.maxY - top)).insetBy(dx: 4, dy: 0)
            if element.exists && element.isHittable && viewport.contains(element.frame) { return }
            let upward = element.exists ? element.frame.midY > viewport.midY : !towardTop
            let start = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.65 : 0.35))
            let end = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.4 : 0.6))
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
