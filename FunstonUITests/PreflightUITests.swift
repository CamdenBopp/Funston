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
}
