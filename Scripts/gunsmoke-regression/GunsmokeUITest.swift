import XCTest

final class REGRESSION_CLASS: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor func testGunsmokeSustainedPlayback() throws { try verifyEpisode(index: 1) }
    @MainActor func testGunsmokeAuditionPlayback() throws { try verifyEpisode(index: 0) }
    @MainActor func testOriginalGunsmokeCollectionPlayback() throws { try verifyEpisode(index: 0, identifier: "OTRR_Gunsmoke_Singles") }
    @MainActor func testReportedDragnetProduction2Playback() throws { try verifyEpisode(index: 0, identifier: "OTRR_Dragnet_Singles") }
    @MainActor private func verifyEpisode(index: Int, identifier: String = "GUNSMOKE01") throws {
        let app = XCUIApplication()
        app.launchArguments = ["--skip-playback-restoration", "--gunsmoke-regression"]
        app.launch()
        defer {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Gunsmoke final accessibility tree"; tree.lifetime = .keepAlways
            add(tree)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Gunsmoke final screen"; shot.lifetime = .keepAlways; add(shot)
        }
        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields["Search the Internet Archive"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        let clear = field.buttons["Clear text"]
        if clear.exists { clear.tap() }
        field.typeText(identifier + "\n")
        let item = app.cells["artifact:" + identifier]
        XCTAssertTrue(app.collectionViews.cells.firstMatch.waitForExistence(timeout: 60))
        for _ in 0..<24 where !item.exists { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(item.waitForExistence(timeout: 10), app.debugDescription)
        item.tap()
        let play = app.buttons["artifact.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 60), app.debugDescription)
        for _ in 0..<8 where !play.isHittable { app.swipeUp() }
        let episode = app.buttons["recording.play.\(index)"]
        for _ in 0..<8 where !episode.isHittable { app.swipeUp() }
        XCTAssertTrue(episode.waitForExistence(timeout: 10), app.debugDescription)
        if index == 0 && identifier == "GUNSMOKE01" { XCTAssertTrue(episode.label.contains("49-07-13"), "Verify the actual audition selected: " + episode.label) }
        if identifier == "OTRR_Dragnet_Singles" { XCTAssertTrue(episode.label.contains("Production 2"), episode.label) }
        let selection = XCTAttachment(string: episode.label); selection.name = "Selected Gunsmoke episode"; selection.lifetime = .keepAlways; add(selection)
        episode.tap()
        let mini = app.descendants(matching: .any)["compactPlayer.open"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 20), app.debugDescription)
        let transport = app.buttons["player.toggle"]
        for _ in 0..<3 {
            mini.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
            if transport.waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(transport.waitForExistence(timeout: 10))
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Playing"), object: transport)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 100), .completed, app.debugDescription)
        let position = app.sliders["Playback position"]
        let before = String(describing: position.value)
        let start = XCTAttachment(string: app.debugDescription); start.name = "Gunsmoke playback started"; start.lifetime = .keepAlways; add(start)
        // Observe real transport for twelve seconds; merely presenting Pause is insufficient.
        let sustained = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            transport.value as? String != "Playing"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [sustained], timeout: 12), .timedOut, "Playback stopped during the sustained interval")
        XCTAssertEqual(transport.value as? String, "Playing")
        XCTAssertNotEqual(String(describing: position.value), before, "The playback position must advance")
        transport.tap()
    }
}
