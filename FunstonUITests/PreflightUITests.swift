import XCTest

@MainActor
final class PreflightUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testMiniPlayerDismissUndoAndNewItem() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--skip-playback-restoration"]
        app.launch()
        app.buttons["oldtimeradio"].tap()
        let recording = app.cells["artifact:OTRR_Gunsmoke_Singles"]
        XCTAssertTrue(recording.waitForExistence(timeout: 40))
        recording.tap()
        let play = app.buttons["artifact.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 40))
        play.tap()
        let mini = app.descendants(matching: .any)["compactPlayer.open"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 15))
        let start = mini.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 65)))
        let undo = app.buttons["compactPlayer.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        XCTAssertTrue(mini.waitForNonExistence(timeout: 3))
        undo.tap()
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["compactPlayer.toggle"].label, "Play")
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 65)))
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        play.tap()
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        XCTAssertTrue(undo.waitForNonExistence(timeout: 3))
    }
    func testPDFReaderFullScreenAtAllTextSizes() throws {
        for category in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryXXXL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            let app = XCUIApplication()
            app.launchArguments = ["--skip-playback-restoration", "-UIPreferredContentSizeCategoryName", category]
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

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
