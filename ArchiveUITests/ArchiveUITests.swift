import XCTest
import UIKit

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
        let toggle = app.buttons["player.toggle"]
        XCTAssertTrue(waitForValue("Playing", of: toggle))
        app.buttons["Next recording"].tap()
        XCTAssertEqual(toggle.label, "Pause", "Track preparation must not masquerade as a pause.")
        XCTAssertTrue(waitForValue("Playing", of: toggle), "Next must continue playing without another Play tap.")
        app.buttons["Previous recording"].tap()
        XCTAssertEqual(toggle.label, "Pause")
        XCTAssertTrue(waitForValue("Playing", of: toggle), "Previous must continue playing without another Play tap.")
        toggle.tap()
        XCTAssertTrue(waitForValue("Paused", of: toggle))
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
    func testVideoViewingJourneyAndNativeControls() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-playback-restoration"]
        app.launch()
        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields["Search the Internet Archive"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("DuckandC1951\n")
        let film = app.collectionViews.cells["artifact:DuckandC1951"]
        XCTAssertTrue(film.waitForExistence(timeout: 30))
        film.tap()
        let watch = app.buttons["artifact.watch"]
        XCTAssertTrue(watch.waitForExistence(timeout: 30))
        watch.tap()
        let file = app.collectionViews.cells["file:0"]
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        file.tap()
        let canvas = app.descendants(matching: .any)["video.player"].firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: canvas)], timeout: 45), .completed)
        let transport = app.buttons["Play/Pause"].firstMatch
        // Full-screen AVKit auto-hides every control. Tap the image, not the
        // letterboxed area, to reveal its native overlay.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(transport.waitForExistence(timeout: 5), app.debugDescription)
        if transport.label == "Play" { transport.tap() }
        XCTAssertEqual(transport.label, "Pause", "The native control should reflect playback")
        let speed = app.buttons["AVPlaybackSpeedControl"]
        if !speed.exists { canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(speed.waitForExistence(timeout: 3), "AVKit, not a custom menu, owns playback speed")
        XCTAssertFalse(app.buttons["video.done"].exists, "Preparation toolbar must not overlay the film")
        capture(app, name: "08 Native video player")
        if transport.label == "Play" { transport.tap() }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: speed)], timeout: 12), .completed,
                       "The native playback toolbar should auto-hide while playing")
        assertFourByThreeFilmIsCenteredIn(app.screenshot().image)
        capture(app, name: "09 Fullscreen video without toolbar")
        if !transport.exists { canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        if transport.label == "Pause" { transport.tap() }
        XCTAssertEqual(transport.label, "Play")
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done' OR label == 'Close'")).firstMatch
        if !done.exists { canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(done.waitForExistence(timeout: 5), app.debugDescription)
        done.tap()
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        file.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: canvas)], timeout: 45), .completed)
        if !transport.exists || !transport.isHittable { canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(transport.waitForExistence(timeout: 5))
        done.tap()
    }

    @MainActor
    private func waitForValue(_ value: String, of element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)], timeout: 30) == .completed
    }

    /// Measure a tiny center strip of the controls-hidden screenshot. This
    /// tests the rendered film edge without depending on AVKit's private AX tree.
    private func assertFourByThreeFilmIsCenteredIn(_ screenshot: UIImage, file: StaticString = #filePath, line: UInt = #line) {
        guard let source = screenshot.cgImage,
              let strip = source.cropping(to: CGRect(x: source.width / 2 - 2, y: 0, width: 4, height: source.height)) else {
            XCTFail("Could not inspect the video screenshot", file: file, line: line)
            return
        }
        let height = strip.height
        var pixels = [UInt8](repeating: 0, count: height * 16)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 4, height: height,
                                          bitsPerComponent: 8, bytesPerRow: 16,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(strip, in: CGRect(x: 0, y: 0, width: 4, height: height))
            return true
        }
        guard rendered else { XCTFail("Could not decode the video screenshot", file: file, line: line); return }
        // Ignore status/safe-area glyphs outside the central playback region.
        let visible = (height / 5..<height * 4 / 5).filter { row in
            let offset = row * 16 + 8
            return max(pixels[offset], pixels[offset + 1], pixels[offset + 2]) > 24
        }
        guard let top = visible.first, let bottom = visible.last else {
            XCTFail("The film image was not visible", file: file, line: line)
            return
        }
        let filmHeight = bottom - top + 1
        XCTAssertEqual(Double(source.width) / Double(filmHeight), 4.0 / 3.0, accuracy: 0.07,
                       "The full 4:3 source image should fit rather than fill-crop", file: file, line: line)
        XCTAssertEqual(Double(top + bottom) / 2, Double(height) / 2, accuracy: Double(height) * 0.035,
                       "The video should have balanced bars above and below", file: file, line: line)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
