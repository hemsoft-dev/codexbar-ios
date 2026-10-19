import XCTest

/// Bounded implementation checks. These fixtures never open Apple Account settings or charge an account.
/// Run this class explicitly; it is separate from the release screenshot matrix.
@MainActor
final class ProCommerceJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testOnlyQualifiedYearlyOfferShowsTrialTerms() {
        for scenario in ["commerce-free-trial", "commerce-free-no-trial", "commerce-free-no-offer", "commerce-free-unknown-trial"] {
            let journey = ProCommerceJourneyDriver(scenario: scenario)
            defer { journey.app.terminate() }
            journey.ready()
            journey.plan("Free plan")
            journey.reveal(journey.element("pro-product-yearly"))
            let trial = journey.element("pro-yearly-trial")
            let isEligible = scenario == "commerce-free-trial"
            XCTAssertEqual(trial.exists, isEligible, scenario)
            XCTAssertEqual(journey.app.buttons["pro-purchase-yearly"].label,
                           isEligible ? "Start 7-day free trial" : "Choose yearly")
            if isEligible {
                XCTAssertEqual(trial.label, "7 days free, then $14.99 per year")
                for (product, price) in [("monthly", "$1.99"), ("yearly", "$14.99"), ("lifetime", "$29.99")] {
                    let row = journey.element("pro-product-\(product)")
                    journey.reveal(row)
                    XCTAssertTrue(row.descendants(matching: .any).matching(
                        NSPredicate(format: "label CONTAINS %@", price)
                    ).firstMatch.exists, "The fixture's billed \(product) amount must be displayed.")
                }
                journey.reveal(journey.element("pro-privacy-policy"))
                journey.reveal(journey.element("pro-terms-of-use"))
                XCTAssertTrue(journey.element("pro-terms-of-use").isHittable)
            }
        }
    }

    func testPurchasePendingCancellationAndFailuresDoNotClaimAccess() {
        let cases = [
            ("commerce-pending", "Waiting for approval"),
            ("commerce-cancelled", "Purchase canceled"),
            ("commerce-purchase-error", "Purchase could not be completed"),
            ("commerce-storage-error", "Purchase could not be completed"),
        ]
        for (scenario, message) in cases {
            let journey = ProCommerceJourneyDriver(scenario: scenario)
            defer { journey.app.terminate() }
            journey.ready()
            journey.tap("pro-purchase-lifetime")
            journey.feedback(containing: message)
            journey.plan("Free plan")
            if scenario == "commerce-storage-error" {
                for product in ["monthly", "yearly", "lifetime"] {
                    journey.reveal(journey.element("pro-product-\(product)"))
                    let action = journey.app.buttons["pro-purchase-\(product)"]
                    let opensManagement = product == "lifetime" && action.label == "Manage Subscription"
                    XCTAssertEqual(action.isEnabled, opensManagement,
                                   "Verification recovery must disable payment while keeping subscription management available.")
                }
            }
            journey.reveal(journey.app.buttons["pro-restore-purchases"])
            XCTAssertTrue(journey.app.buttons["pro-restore-purchases"].isEnabled)
            if scenario == "commerce-storage-error" {
                journey.reveal(journey.app.buttons["pro-refresh"])
                XCTAssertTrue(journey.app.buttons["pro-refresh"].isEnabled)
            }
            XCTAssertFalse(journey.element("pro-command-busy").exists)
        }
    }

    func testRestoreNoPurchaseCancellationAndErrorsStayDistinct() {
        let cases = [
            ("commerce-free-trial", "No Pro purchase found"),
            ("commerce-restore-cancelled", "Restore canceled"),
            ("commerce-restore-error", "Restore could not be completed"),
        ]
        for (scenario, message) in cases {
            let journey = ProCommerceJourneyDriver(scenario: scenario, entry: "settings")
            defer { journey.app.terminate() }
            journey.ready()
            journey.tap("pro-restore-purchases")
            journey.feedback(containing: message)
            journey.plan("Free plan")
            journey.reveal(journey.app.buttons["pro-restore-purchases"])
            XCTAssertTrue(journey.app.buttons["pro-restore-purchases"].isEnabled)
            XCTAssertFalse(journey.element("pro-command-busy").exists)
        }
    }

    func testSettingsRequiresRenewalOffBeforeCommittingLifetimeAtLargeTextSize() {
        let journey = ProCommerceJourneyDriver(scenario: "commerce-monthly-on", entry: "settings", largeText: true)
        defer { journey.app.terminate() }
        journey.ready()
        journey.plan("Monthly Pro")
        XCTAssertGreaterThanOrEqual(journey.element("pro-current-plan").frame.height, 30)
        journey.reveal(journey.element("pro-lifetime-gate"))
        XCTAssertTrue(journey.element("pro-lifetime-gate").label.contains("Turn off auto-renew first"))
        XCTAssertEqual(journey.app.buttons["pro-switch-lifetime"].label, "Manage Subscription")
        journey.tap("pro-switch-lifetime")
        XCTAssertTrue(journey.app.navigationBars["Manage Subscription"].waitForExistence(timeout: 5))
        XCTAssertFalse(journey.element("pro-lifetime-confirmation").exists)
        journey.tap("fixture-commerce-renewal-off")
        XCTAssertTrue(journey.app.navigationBars["Manage Subscription"].waitForNonExistence(timeout: 10))
        journey.ready()
        journey.reveal(journey.element("pro-period-end"))
        let endDate = journey.element("pro-period-end").label.replacingOccurrences(of: "Subscription ends ", with: "")
        XCTAssertFalse(endDate.isEmpty)
        journey.tap("pro-switch-lifetime")
        XCTAssertTrue(journey.app.navigationBars["Switch to lifetime"].waitForExistence(timeout: 10))
        let expiry = journey.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Your current subscription period ends ")).firstMatch
        journey.reveal(expiry)
        XCTAssertTrue(expiry.label.contains(endDate), "The confirmation must retain the verified subscription expiry.")
        let nonrefund = journey.app.staticTexts["Buying lifetime does not refund the remaining paid subscription period."]
        journey.reveal(nonrefund)
        XCTAssertTrue(nonrefund.isHittable)
        let warning = journey.element("pro-lifetime-restart-warning")
        journey.reveal(warning)
        XCTAssertTrue(warning.label.contains("Apple will charge for it even though you have lifetime Pro."))
        let confirm = journey.app.buttons["pro-confirm-lifetime"]
        journey.reveal(confirm)
        XCTAssertTrue(confirm.label.contains("$29.99"))
        journey.tap("pro-confirm-lifetime")
        journey.feedback(containing: "Lifetime Pro is ready")
        journey.plan("Lifetime Pro")
        journey.assertNoPurchaseControls()
        XCTAssertFalse(journey.element("pro-switch-lifetime").exists)
        journey.tap("pro-restore-purchases")
        journey.feedback(containing: "Purchases restored")
        journey.plan("Lifetime Pro")
    }

    func testUnknownRenewalOpensManagementWithoutOfferingLifetimeConfirmation() {
        let journey = ProCommerceJourneyDriver(scenario: "commerce-monthly-unknown", entry: "settings")
        defer { journey.app.terminate() }
        journey.ready()
        journey.reveal(journey.element("pro-lifetime-gate"))
        XCTAssertTrue(journey.element("pro-lifetime-gate").label.contains("Renewal status is unavailable"))
        journey.tap("pro-switch-lifetime")
        XCTAssertTrue(journey.app.navigationBars["Manage Subscription"].waitForExistence(timeout: 5))
        XCTAssertFalse(journey.element("pro-lifetime-confirmation").exists)
        journey.app.navigationBars["Manage Subscription"].buttons["Done"].tap()
        journey.ready()
        XCTAssertFalse(journey.element("pro-confirm-lifetime").exists)
    }

    func testExistingPaidAccessAtLimitNeverOffersASecondProduct() {
        for (scenario, plan) in [("commerce-monthly-on", "Monthly Pro"), ("commerce-lifetime", "Lifetime Pro"), ("commerce-original", "Lifetime Pro")] {
            let journey = ProCommerceJourneyDriver(scenario: scenario)
            defer { journey.app.terminate() }
            journey.ready()
            journey.plan(plan)
            journey.assertNoPurchaseControls()
            journey.reveal(journey.element("pro-terms-of-use"))
            XCTAssertFalse(journey.element("pro-switch-lifetime").exists, "The lifetime exception belongs only to Settings.")
            journey.assertNoPurchaseControls()
        }
    }

    func testScheduledRenewalUsesVerifiedPriceAndOmitsUnavailableAmount() {
        for (scenario, plan, price) in [
            ("commerce-trial-monthly", "Monthly Pro", "$1.49"),
            ("commerce-yearly-on", "Yearly Pro", "$9.99"),
            ("commerce-trial-no-price", "Yearly Pro", ""),
        ] {
            let journey = ProCommerceJourneyDriver(scenario: scenario, entry: "settings")
            defer { journey.app.terminate() }
            journey.ready()
            journey.reveal(journey.element("pro-next-renewal-product"))
            XCTAssertEqual(journey.element("pro-next-renewal-product").label, "Next plan: \(plan)")
            if price.isEmpty {
                XCTAssertFalse(journey.element("pro-next-renewal-price").exists)
            } else {
                XCTAssertEqual(journey.element("pro-next-renewal-price").label, "Next charge: \(price)")
            }
            journey.reveal(journey.app.buttons["pro-manage-subscription"])
            XCTAssertTrue(journey.app.buttons["pro-manage-subscription"].isEnabled)
        }
    }

    func testPermanentAccessOverlapWarningDisappearsAfterVerifiedRenewalOff() {
        for scenario in ["commerce-overlap-lifetime", "commerce-overlap-original"] {
            let journey = ProCommerceJourneyDriver(scenario: scenario, entry: "settings")
            defer { journey.app.terminate() }
            journey.ready()
            journey.plan("Lifetime Pro")
            journey.reveal(journey.element("pro-renewal-overlap"))
            XCTAssertTrue(journey.element("pro-renewal-overlap").label.contains("A subscription is still renewing"))
            journey.tap("pro-overlap-manage")
            journey.tap("fixture-commerce-renewal-off")
            XCTAssertTrue(journey.app.navigationBars["Manage Subscription"].waitForNonExistence(timeout: 10))
            journey.ready()
            XCTAssertFalse(journey.element("pro-renewal-overlap").exists)
            journey.plan("Lifetime Pro")
            journey.assertNoPurchaseControls()
        }
    }

    func testGraceRetryAndPermanentBillingShowPaymentRecovery() {
        for (scenario, plan) in [("commerce-grace", "CodexBar Pro"), ("commerce-retry", "Free plan"), ("commerce-lifetime-billing", "Lifetime Pro")] {
            let journey = ProCommerceJourneyDriver(scenario: scenario, entry: "settings")
            defer { journey.app.terminate() }
            journey.ready()
            journey.plan(plan)
            journey.reveal(journey.element("pro-billing-issue"))
            XCTAssertTrue(journey.element("pro-billing-issue").label.contains("Check your payment details"))
            XCTAssertTrue(journey.element("pro-payment-management").exists)
            let grace = journey.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Billing grace period ends ")).firstMatch
            XCTAssertEqual(grace.exists, scenario == "commerce-grace")
            if scenario == "commerce-retry" {
                journey.reveal(journey.app.buttons["pro-purchase-lifetime"])
                XCTAssertEqual(journey.app.buttons["pro-purchase-lifetime"].label, "Manage Subscription")
            }
        }
    }

    func testUnavailableAndPartialCatalogRetainRestoreAndPolicyLinks() {
        for scenario in ["commerce-catalog-error", "commerce-partial"] {
            let journey = ProCommerceJourneyDriver(scenario: scenario)
            defer { journey.app.terminate() }
            journey.ready()
            if scenario == "commerce-catalog-error" {
                journey.reveal(journey.element("pro-catalog-error"))
                XCTAssertTrue(journey.app.buttons["pro-catalog-retry"].isEnabled)
                journey.assertNoPurchaseControls()
            } else {
                journey.reveal(journey.element("pro-unavailable-yearly"))
                XCTAssertFalse(journey.app.buttons["pro-purchase-yearly"].exists)
                XCTAssertTrue(journey.app.buttons["pro-purchase-monthly"].exists)
                XCTAssertTrue(journey.app.buttons["pro-purchase-lifetime"].exists)
            }
            journey.reveal(journey.app.buttons["pro-restore-purchases"])
            XCTAssertTrue(journey.app.buttons["pro-restore-purchases"].isEnabled)
            journey.reveal(journey.element("pro-privacy-policy"))
            journey.reveal(journey.element("pro-terms-of-use"))
            XCTAssertTrue(journey.element("pro-terms-of-use").isHittable)
        }
    }

    func testNoLaunchInterstitialAndSettingsAccountAndAlertActionsOpenPro() {
        let journey = ProCommerceJourneyDriver(scenario: "commerce-free-trial", entry: nil)
        defer { journey.app.terminate() }
        XCTAssertTrue(journey.app.buttons["Open settings"].waitForExistence(timeout: 10))
        XCTAssertFalse(journey.app.navigationBars["CodexBar Pro"].exists)
        journey.openSettings()
        journey.tap("settings-codexbar-pro")
        journey.ready()
        journey.dismissPro()
        XCTAssertTrue(journey.app.navigationBars["Settings"].exists)
        journey.settingsCategory("accountsAndGroups")
        journey.tap(journey.app.buttons["Add Account"].firstMatch)
        journey.ready()
        journey.dismissPro()
        journey.settingsCategory("alerts")
        let alerts = journey.app.switches["usage-alerts-toggle"].firstMatch
        journey.reveal(alerts)
        XCTAssertEqual(alerts.value as? String, "0")
        journey.tapSwitch(alerts)
        journey.ready()
        journey.dismissPro()
        XCTAssertEqual(alerts.value as? String, "0", "Opening Pro must not enable a locked usage alert.")
    }

    func testColdWarmAndRepeatedProLinksPresentOneDestination() {
        let journey = ProCommerceJourneyDriver(scenario: "commerce-free-trial", entry: nil, launch: false)
        defer { journey.app.terminate() }
        journey.app.open(ProCommerceJourneyDriver.proURL)
        journey.ready()
        journey.openWarmProLink()
        journey.openWarmProLink()
        journey.assertSinglePro()
        XCTAssertFalse(journey.element("pro-command-status").exists, "A link must not purchase or Restore automatically.")
        journey.dismissPro()
        XCTAssertTrue(journey.app.buttons["Open settings"].waitForExistence(timeout: 5))
        journey.openWarmProLink()
        journey.ready()
        journey.assertSinglePro()
    }

    func testProLinksRespectExistingSettingsAndHistorySheets() {
        let journey = ProCommerceJourneyDriver(scenario: "plan-free", entry: nil)
        defer { journey.app.terminate() }
        journey.openSettings()
        journey.openWarmProLink()
        journey.ready()
        journey.dismissPro()
        XCTAssertTrue(journey.app.navigationBars["Settings"].waitForExistence(timeout: 5))
        journey.tap(journey.app.navigationBars["Settings"].buttons["Done"])
        let history = journey.app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Usage history.")).firstMatch
        journey.tap(history)
        XCTAssertTrue(journey.app.navigationBars["History"].waitForExistence(timeout: 5))
        XCTAssertTrue(journey.app.buttons["history-range-sevenDays"].isSelected)
        journey.tap("history-range-month")
        journey.ready()
        journey.dismissPro()
        XCTAssertTrue(journey.app.navigationBars["History"].exists)
        XCTAssertTrue(journey.app.buttons["history-range-sevenDays"].isSelected)
        journey.openWarmProLink()
        journey.ready()
        journey.dismissPro()
        XCTAssertTrue(journey.app.buttons["history-range-sevenDays"].isSelected)
    }

    func testProPreemptionPreservesPendingActiveAccountChoiceAtLargeTextSize() {
        let journey = ProCommerceJourneyDriver(scenario: "plan-free-cold", entry: nil, largeText: true)
        defer { journey.app.terminate() }
        let chooser = journey.app.navigationBars["Change active account"]
        XCTAssertTrue(chooser.waitForExistence(timeout: 10))
        journey.openWarmProLink()
        journey.ready()
        journey.assertSinglePro()
        journey.dismissPro()
        XCTAssertTrue(chooser.waitForExistence(timeout: 5), "Closing Pro must restore the pending active-account choice.")
        journey.tap("active-account-choice-plan-account-1")
        XCTAssertTrue(chooser.waitForNonExistence(timeout: 5))
        journey.reveal(journey.app.buttons["make-account-active-plan-account-0"])
        XCTAssertTrue(journey.app.buttons["make-account-active-plan-account-0"].exists)
    }
}

/// Explicit native-only selector. First run the repository's native StoreKit preparation test
/// in a separate process on the same disposable simulator, with clean local transactions and
/// dialogs disabled. This test never configures StoreKit, skips failed setup, or signs in.
@MainActor
final class ProCommerceNativeJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// Run only after testPrepareLocalStoreKitPurchaseFailure in a separate native process.
    func testPurchaseErrorLeavesFreePlanAndUsableControls() {
        let journey = ProCommerceJourneyDriver(scenario: "commerce-native-storekit")
        defer { journey.app.terminate() }
        journey.ready(timeout: 30)
        journey.plan("Free plan")
        journey.tap("pro-purchase-lifetime")
        // iOS 27.0 may display this error even when SKTestSession.disableDialogs is true.
        // A UI test can acknowledge Apple's dialog without changing production purchase behavior.
        let appAlert = journey.app.alerts["Unable to Complete Purchase"]
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let systemAlert = springboard.alerts["Unable to Complete Purchase"]
        if appAlert.waitForExistence(timeout: 4) {
            appAlert.buttons["OK"].tap()
        } else if systemAlert.waitForExistence(timeout: 2) {
            systemAlert.buttons["OK"].tap()
        }
        journey.feedback(containing: "Purchase could not be completed", timeout: 30)
        journey.plan("Free plan")
        XCTAssertFalse(journey.element("pro-command-busy").exists)
        journey.reveal(journey.app.buttons["pro-restore-purchases"])
        XCTAssertTrue(journey.app.buttons["pro-restore-purchases"].isEnabled)
        journey.reveal(journey.app.buttons["pro-purchase-lifetime"])
        XCTAssertTrue(journey.app.buttons["pro-purchase-lifetime"].isEnabled)
        let attachment = XCTAttachment(screenshot: journey.app.screenshot())
        attachment.name = "Native purchase error leaves free plan"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPurchaseAndRestore() {
        let journey = ProCommerceJourneyDriver(scenario: "commerce-native-storekit")
        defer { journey.app.terminate() }
        journey.ready(timeout: 30)
        journey.plan("Free plan")
        journey.tap("pro-purchase-lifetime")
        journey.feedback(containing: "Lifetime Pro is ready", timeout: 30)
        XCTAssertTrue(journey.element("pro-command-status").label.contains("Your purchase is saved and Pro access is available."))
        journey.plan("Lifetime Pro")
        journey.assertNoPurchaseControls()
        journey.tap("pro-restore-purchases")
        journey.feedback(containing: "Purchases restored", timeout: 30)
        journey.plan("Lifetime Pro")
        XCTAssertFalse(journey.element("pro-verification-message").exists)
    }
}

@MainActor
private struct ProCommerceJourneyDriver {
    static let proURL = URL(string: "codexbar://pro")!
    let app: XCUIApplication

    init(scenario: String, entry: String? = "limit", largeText: Bool = false, launch: Bool = true) {
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = [
            "CODEXBAR_UI_TESTS": "1",
            "CODEXBAR_UI_TEST_RUN_ID": UUID().uuidString,
            "CODEXBAR_UI_TEST_RESET": "1",
            "CODEXBAR_UI_TEST_SCENARIO": scenario,
            "CODEXBAR_UI_TEST_DEFAULT_TEXT": largeText ? "0" : "1",
            "CODEXBAR_UI_TEST_DARK": "0",
            "CODEXBAR_NATIVE_STOREKIT_TEST_HOST": "0",
        ]
        if let entry { app.launchEnvironment["CODEXBAR_COMMERCE_ENTRY"] = entry }
        if launch { app.launch() }
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func ready(timeout: TimeInterval = 15) {
        assertSinglePro(timeout: timeout)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "ready"), object: element("codexbar-pro-presentation")
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "Purchase information did not resolve. \(app.debugDescription)")
    }

    func assertSinglePro(timeout: TimeInterval = 5) {
        XCTAssertTrue(app.navigationBars["CodexBar Pro"].waitForExistence(timeout: timeout))
        XCTAssertEqual(app.navigationBars.matching(identifier: "CodexBar Pro").count, 1)
    }

    func plan(_ title: String) {
        scrollToPlan()
        let current = element("pro-current-plan")
        reveal(current)
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", title), object: current)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, current.label)
    }

    func feedback(containing message: String, timeout: TimeInterval = 15) {
        scrollToPlan()
        let status = element("pro-command-status")
        XCTAssertTrue(status.waitForExistence(timeout: timeout), app.debugDescription)
        reveal(status)
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", message), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, status.label)
    }

    func assertNoPurchaseControls() {
        for product in ["monthly", "yearly", "lifetime"] {
            XCTAssertFalse(app.buttons["pro-purchase-\(product)"].exists)
        }
    }

    func dismissPro() {
        tap("pro-done")
        XCTAssertTrue(app.navigationBars["CodexBar Pro"].waitForNonExistence(timeout: 5))
    }

    func openSettings() {
        tap(app.buttons["Open settings"].firstMatch)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    func settingsCategory(_ category: String) {
        let destination = element("settings-\(category)")
        if !destination.isHittable {
            let back = app.navigationBars.buttons["Settings"].firstMatch
            if back.exists { tap(back) }
        }
        tap(destination)
    }

    func openWarmProLink() {
        // The system URL API preserves the current process and any active sheet.
        XCUIDevice.shared.system.open(Self.proURL)
    }

    func tap(_ identifier: String) { tap(element(identifier)) }

    func tap(_ target: XCUIElement) {
        reveal(target)
        target.tap()
    }

    func tapSwitch(_ target: XCUIElement) {
        reveal(target)
        let control = target.switches.firstMatch
        if control.exists { control.tap() } else {
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
    }

    private func scrollToPlan() {
        let current = element("pro-current-plan")
        for _ in 0..<10 {
            if current.exists && current.isHittable { return }
            app.swipeDown()
        }
    }

    func reveal(_ target: XCUIElement) {
        for _ in 0..<12 {
            if target.exists && target.isHittable { return }
            let navigationBottom = app.navigationBars.allElementsBoundByIndex.map { $0.frame.maxY }.max() ?? 0
            if target.exists && target.frame.midY < navigationBottom { app.swipeDown() } else { app.swipeUp() }
        }
        XCTFail("Unreachable commerce control: \(target). UI: \(app.debugDescription)")
    }
}
