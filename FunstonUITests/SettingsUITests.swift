import XCTest

@MainActor
final class SettingsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSettingsAtAllTextSizesAndAppearances() {
        for category in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryXXXL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            for style in ["Light", "Dark"] {
                let app = XCUIApplication()
                app.launchArguments = ["--skip-playback-restoration", "-UIPreferredContentSizeCategoryName", category, "-UIUserInterfaceStyle", style]
                app.launchEnvironment["FUNSTON_TEST_APPEARANCE"] = style
                app.launch()
                XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 10))
                app.tabBars.buttons["Library"].tap()
                app.navigationBars.buttons["Settings"].tap()
                XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["Done"].isHittable)
                XCTAssertFalse(app.tabBars.firstMatch.isHittable)
                XCTAssertTrue(app.staticTexts["Default speed"].exists)
                capture(app, "Settings \(style) \(category)")
                let remove = app.buttons["Remove All Downloads"]
                for _ in 0..<8 where !remove.isHittable { app.swipeUp() }
                XCTAssertTrue(remove.isHittable)
                remove.tap()
                XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 3))
                app.buttons["Cancel"].tap()
                let help = app.buttons["Shortcuts help"]
                for _ in 0..<12 where !help.isHittable { app.swipeUp() }
                XCTAssertTrue(help.isHittable)
                capture(app, "Settings About \(style) \(category)")
                help.tap()
                XCTAssertTrue(app.staticTexts["Resume listening in Funston"].waitForExistence(timeout: 5))
                capture(app, "Shortcuts help \(style) \(category)")
                app.navigationBars.buttons["Settings"].tap()
                app.buttons["Done"].tap()
                XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
                app.terminate()
            }
        }
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        XCTContext.runActivity(named: name) { activity in
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }
}
