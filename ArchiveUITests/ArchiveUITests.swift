import XCTest

final class ArchiveUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPrimaryNavigationAndInitialAccessibility() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-playback-restoration"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Explore"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Explore"].exists)
        XCTAssertTrue(app.tabBars.buttons["Search"].exists)
        XCTAssertTrue(app.tabBars.buttons["Library"].exists)
        XCTAssertTrue(app.tabBars.buttons["Downloads"].exists)

        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.searchFields["Search the Internet Archive"].exists)

        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 2))

        app.tabBars.buttons["Downloads"].tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 2))

        app.tabBars.buttons["Explore"].tap()
        try app.performAccessibilityAudit { issue in
            // Retain the full diagnostic even when the audit cannot identify an element.
            // Every reported issue fails this test; there are no exclusions.
            XCTContext.runActivity(named: issue.compactDescription) { activity in
                let details = XCTAttachment(string: issue.detailedDescription + "\n" + (issue.element?.debugDescription ?? "No element supplied by audit"))
                details.lifetime = .keepAlways
                activity.add(details)
            }
            return false
        }
    }

    @MainActor
    func testLiveCollectionCanOpen() throws {
        let app = XCUIApplication()
        app.launch()
        let collection = app.buttons["oldtimeradio"]
        XCTAssertTrue(collection.waitForExistence(timeout: 5))
        collection.tap()
        XCTAssertTrue(app.navigationBars["Old Time Radio"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.collectionViews.cells.element(boundBy: 0).waitForExistence(timeout: 20))
    }

    @MainActor
    func testArtifactListeningJourneyAndScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-playback-restoration"]
        app.launch()
        XCTAssertTrue(app.buttons["oldtimeradio"].waitForExistence(timeout: 10))
        let cover = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "explore.artifact.")).firstMatch
        XCTAssertTrue(cover.waitForExistence(timeout: 30))
        XCTAssertFalse(app.descendants(matching: .any)["compactPlayer.open"].firstMatch.exists, "This journey must exercise the first nil-to-recording presentation.")
        capture(app, name: "01 Explore")
        app.buttons["oldtimeradio"].tap()
        let recording = app.collectionViews.cells["artifact:OTRR_Gunsmoke_Singles"]
        XCTAssertTrue(recording.waitForExistence(timeout: 30))
        capture(app, name: "02 Collection")
        recording.tap()
        let play = app.buttons["artifact.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        capture(app, name: "03 Artifact")
        let save = app.buttons["artifact.save"]
        if save.label == "Save to Library" { save.tap() }
        play.tap()
        let popup = app.descendants(matching: .any)["compactPlayer.open"].firstMatch
        XCTAssertTrue(popup.waitForExistence(timeout: 15))
        try app.performAccessibilityAudit(for: .dynamicType)
        popup.tap()
        XCTAssertTrue(app.buttons["player.toggle"].waitForExistence(timeout: 8))
        capture(app, name: "04 Player")
        app.buttons["player.toggle"].tap()
    }

    @MainActor
    func testLargeTextExploreScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["oldtimeradio"].waitForExistence(timeout: 10))
        let cover = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "explore.artifact.")).firstMatch
        XCTAssertTrue(cover.waitForExistence(timeout: 30))
        capture(app, name: "05 Explore accessibility text")
    }

    @MainActor
    func testPDFReaderAndPageRestoration() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields["Search the Internet Archive"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("flatlandromanceo00abbouoft\n")
        let book = app.collectionViews.cells["artifact:flatlandromanceo00abbouoft"]
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        book.tap()
        let read = app.buttons["artifact.read"]
        XCTAssertTrue(read.waitForExistence(timeout: 30))
        capture(app, name: "06 Book")
        read.tap()
        let page = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Page ")).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 60))
        app.buttons["Next page"].tap()
        let savedPage = page.label
        capture(app, name: "07 Reader")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(read.waitForExistence(timeout: 5))
        read.tap()
        XCTAssertTrue(app.staticTexts[savedPage].waitForExistence(timeout: 10))
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
