import XCTest

/// Manual asset capture only. Run the native StoreKit preparation in a separate
/// process first, then use a clean app/UI build from this source revision.
@MainActor
final class StorefrontReviewCaptureTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testCaptureThreeLocalStoreKitProducts() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = [
            "CODEXBAR_UI_TESTS": "1",
            "CODEXBAR_UI_TEST_RUN_ID": UUID().uuidString,
            "CODEXBAR_UI_TEST_RESET": "1",
            "CODEXBAR_UI_TEST_SCENARIO": "commerce-native-storekit",
            "CODEXBAR_UI_TEST_DEFAULT_TEXT": "1",
            "CODEXBAR_UI_TEST_DARK": "0",
            "CODEXBAR_NATIVE_STOREKIT_TEST_HOST": "0",
            "CODEXBAR_COMMERCE_ENTRY": "settings",
        ]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["CodexBar Pro"].waitForExistence(timeout: 30))
        let presentation = element("codexbar-pro-presentation", in: app)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "ready"), object: presentation)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        XCTAssertEqual(element("pro-current-plan", in: app).label, "Free plan")

        for (product, price) in [("monthly", "$1.99"), ("yearly", "$14.99"), ("lifetime", "$29.99")] {
            let row = element("pro-product-\(product)", in: app)
            reveal(row, in: app)
            XCTAssertTrue(row.exists)
            XCTAssertTrue(row.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", price)).firstMatch.exists,
                          "The native local StoreKit price must be visible for \(product).")
            XCTAssertTrue(app.buttons["pro-purchase-\(product)"].isEnabled)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "review-\(product)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let accessibility = XCTAttachment(string: app.debugDescription)
            accessibility.name = "review-\(product)-accessibility"
            accessibility.lifetime = .keepAlways
            add(accessibility)
        }
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func reveal(_ row: XCUIElement, in app: XCUIApplication) {
        let viewport = app.frame.insetBy(dx: 16, dy: 110)
        for _ in 0..<10 {
            if row.exists && viewport.contains(row.frame) { return }
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            let destination = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.49))
            from.press(forDuration: 0.05, thenDragTo: destination)
        }
        XCTFail("The complete product row must fit in the review screenshot: \(row.debugDescription)")
    }
}
