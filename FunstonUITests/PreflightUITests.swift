import XCTest

@MainActor
final class PreflightUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testMiniPlayerDismissUndoAndNewItem() throws {
        for category in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryXXXL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            let app = XCUIApplication()
            app.launchArguments = ["--skip-playback-restoration", "-UIPreferredContentSizeCategoryName", category]
            app.launchEnvironment["FUNSTON_TEST_APPEARANCE"] = "Dark"
            app.launch()
            let radio = app.buttons["oldtimeradio"]
            for _ in 0..<16 where !radio.isHittable { app.swipeUp() }
            XCTAssertTrue(radio.isHittable)
            radio.tap()
            let recording = app.cells["artifact:OTRR_Gunsmoke_Singles"]
            for _ in 0..<16 where !recording.waitForExistence(timeout: 1) { app.collectionViews.firstMatch.swipeUp() }
            XCTAssertTrue(recording.waitForExistence(timeout: 40))
            recording.tap()
            let play = app.buttons["artifact.play"]
            XCTAssertTrue(play.waitForExistence(timeout: 40))
            for _ in 0..<8 where !play.isHittable { app.swipeUp() }
            play.tap()
            let mini = app.descendants(matching: .any)["compactPlayer.open"].firstMatch
            XCTAssertTrue(mini.waitForExistence(timeout: 15))
            let start = mini.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 65)))
            let undo = app.buttons["compactPlayer.undo"]
            XCTAssertTrue(undo.waitForExistence(timeout: 3))
            XCTAssertTrue(mini.waitForNonExistence(timeout: 3))
            capture(app, "Stopped toast \(category)")
            undo.tap()
            XCTAssertTrue(mini.waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons["compactPlayer.toggle"].label, "Play")
            capture(app, "Undo paused \(category)")
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 65)))
            XCTAssertTrue(undo.waitForExistence(timeout: 3))
            let another = app.buttons["recording.play.1"]
            let collection = app.collectionViews.firstMatch
            for _ in 0..<12 {
                if another.exists && another.frame.midY > app.navigationBars.firstMatch.frame.maxY + 30 && another.frame.midY < app.frame.height * 0.6 { break }
                let delta = another.exists ? min(150, max(-150, another.frame.midY - app.frame.height * 0.4)) : 150
                let origin = collection.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
                origin.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -delta)), withVelocity: .slow, thenHoldForDuration: 0.2)
            }
            XCTAssertTrue(another.exists)
            XCTAssertLessThan(another.frame.midY, app.frame.height * 0.6)
            XCTAssertGreaterThan(another.frame.midY, app.navigationBars.firstMatch.frame.maxY + 30)
            another.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(mini.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["compactPlayer.title"].label.contains("Ben Thompson"))
            XCTAssertTrue(undo.waitForNonExistence(timeout: 3))
            app.terminate()
        }
    }
    func testPDFReaderFullScreenAtAllTextSizes() throws {
        for category in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryXXXL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            let app = XCUIApplication()
            app.launchArguments = ["--skip-playback-restoration", "-UIPreferredContentSizeCategoryName", category]
            app.launchEnvironment["FUNSTON_TEST_APPEARANCE"] = "Dark"
            app.launch()
            app.tabBars.buttons["Search"].tap()
            let field = app.searchFields["Search the Internet Archive"]
            field.tap()
            field.typeText("flatlandromanceo00abbouoft\n")
            let book = app.cells["artifact:flatlandromanceo00abbouoft"]
            for _ in 0..<12 where !book.waitForExistence(timeout: 3) { app.collectionViews.firstMatch.swipeUp() }
            XCTAssertTrue(book.waitForExistence(timeout: 10))
            book.tap()
            let read = app.buttons["artifact.read"]
            XCTAssertTrue(read.waitForExistence(timeout: 40))
            for _ in 0..<8 where !read.isHittable { app.swipeUp() }
            capture(app, "Primary action \(category)")
            read.tap()
            let page = app.descendants(matching: .any)["reader.page"].firstMatch
            XCTAssertTrue(page.waitForExistence(timeout: 90))
            let next = app.buttons["Next page"]
            XCTAssertTrue(next.waitForExistence(timeout: 10))
            XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: next)], timeout: 90) == .completed)
            let document = app.descendants(matching: .any)["reader.document"].firstMatch
            let center = document.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            center.tap()
            XCTAssertTrue(app.tabBars.firstMatch.waitForNonExistence(timeout: 5))
            XCTAssertFalse(next.isHittable)
            capture(app, "Reader hidden \(category)")
            center.tap()
            XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(next.isHittable)
            capture(app, "Reader visible \(category)")
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(read.waitForExistence(timeout: 5))
            XCTAssertTrue(app.tabBars.firstMatch.isHittable)
            app.terminate()
        }
    }

    func testExploreLayoutAtAllTextSizes() throws {
        for category in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryXXXL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            for style in ["Light", "Dark"] {
                let app = XCUIApplication()
                app.launchArguments = ["--skip-playback-restoration", "-UIPreferredContentSizeCategoryName", category]
                app.launchEnvironment["FUNSTON_TEST_APPEARANCE"] = style
                app.launch()
                let cover = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "explore.artifact.")).firstMatch
                for _ in 0..<8 where !cover.waitForExistence(timeout: 3) { app.swipeUp() }
                XCTAssertTrue(cover.waitForExistence(timeout: 30))
                XCTAssertGreaterThanOrEqual(cover.frame.minX, 16)
                XCTAssertLessThanOrEqual(cover.frame.maxX, app.frame.maxX - 16)
                capture(app, "Explore \(style) \(category)")
                for _ in 0..<12 { app.swipeUp() }
                capture(app, "Explore bottom \(style) \(category)")
                app.terminate()
            }
        }
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
