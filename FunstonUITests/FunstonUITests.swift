import XCTest
import UIKit

final class FunstonUITests: XCTestCase {
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
        let sleep = app.buttons["player.sleepTimer"]
        XCTAssertTrue(sleep.waitForExistence(timeout: 3))
        XCTAssertEqual(sleep.label, "Sleep timer")
        XCTAssertEqual(sleep.value as? String, "Off")
        sleep.tap()
        app.buttons["15 minutes"].tap()
        XCTAssertEqual(sleep.value as? String, "15 minutes left")
        capture(app, name: "04b Sleep timer")
        sleep.tap()
        app.buttons["Turn Off Sleep Timer"].tap()
        XCTAssertEqual(sleep.value as? String, "Off")
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

    /// Listen past the short-listen threshold, relaunch, and pick the recording
    /// back up from Explore. The tile is one element whose value is time left,
    /// and the player resumes where the listener paused.
    @MainActor
    func testContinueListeningShelfResumesARecording() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-playback-restoration"]
        app.launch()
        XCTAssertTrue(app.buttons["oldtimeradio"].waitForExistence(timeout: 10))
        app.buttons["oldtimeradio"].tap()
        let recording = app.collectionViews.cells["artifact:OTRR_Gunsmoke_Singles"]
        XCTAssertTrue(recording.waitForExistence(timeout: 30))
        recording.tap()
        let play = app.buttons["artifact.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        play.tap()
        let popup = app.descendants(matching: .any)["compactPlayer.open"].firstMatch
        XCTAssertTrue(popup.waitForExistence(timeout: 15))
        popup.tap()
        let toggle = app.buttons["player.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForValue("Playing", of: toggle))
        // Well past ResumePolicy.minimumResumeSeconds.
        Thread.sleep(forTimeInterval: 12)
        toggle.tap()
        XCTAssertTrue(waitForValue("Paused", of: toggle))
        // Pausing writes the position asynchronously; give it a moment before quitting.
        Thread.sleep(forTimeInterval: 1)

        app.terminate()
        app.launch()
        let tile = app.buttons["explore.continue.OTRR_Gunsmoke_Singles"]
        XCTAssertTrue(tile.waitForExistence(timeout: 30))
        let tileValue = tile.value as? String ?? ""
        print("Continue listening tile label: \(tile.label)")
        print("Continue listening tile value: \(tileValue)")
        XCTAssertTrue(tile.label.hasPrefix("Gunsmoke"), tile.label)
        XCTAssertTrue(tileValue.hasSuffix(" left"), tileValue)
        XCTAssertEqual(app.staticTexts["Continue listening"].firstMatch.exists, true)
        capture(app, name: "10 Continue listening")

        tile.tap()
        XCTAssertTrue(popup.waitForExistence(timeout: 15))
        popup.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForValue("Playing", of: toggle))
        let position = app.sliders["Playback position"]
        XCTAssertTrue(position.waitForExistence(timeout: 8))
        let positionValue = position.value as? String ?? ""
        print("Resumed position: \(positionValue)")
        XCTAssertFalse(positionValue.hasPrefix("0 seconds"), positionValue)
        XCTAssertFalse(positionValue.hasPrefix("1 second"), positionValue)
    }

    @MainActor
    func testLargeTextExploreScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["oldtimeradio"].waitForExistence(timeout: 10))
        let cover = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "explore.artifact.")).firstMatch
        // With listening history, Continue listening fills the first screen at this size.
        for _ in 0..<4 where !cover.waitForExistence(timeout: 8) { app.swipeUp() }
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
        app.buttons["Reading options"].tap()
        app.buttons["Continuous Scroll"].tap()
        XCTAssertTrue(app.staticTexts[savedPage].waitForExistence(timeout: 5))
        app.buttons["Reading options"].tap()
        app.buttons["Page by Page"].tap()
        XCTAssertTrue(app.staticTexts[savedPage].waitForExistence(timeout: 5))
        capture(app, name: "07 Reader")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(read.waitForExistence(timeout: 5))
        read.tap()
        XCTAssertTrue(app.staticTexts[savedPage].waitForExistence(timeout: 10))
        app.buttons["Find in document"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        capture(app, name: "07b Native PDF Find")
    }

    /// A Project Gutenberg book opens in the EPUB reader, its text reaches
    /// VoiceOver, and Contents jumps to a chapter.
    @MainActor
    func testReadingABornDigitalBook() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-playback-restoration"]
        app.launch()
        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields["Search the Internet Archive"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("manandmaid20512gut\n")
        let book = app.collectionViews.cells["artifact:manandmaid20512gut"]
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        book.tap()
        let read = app.buttons["artifact.read"]
        XCTAssertTrue(read.waitForExistence(timeout: 30))
        XCTAssertEqual(read.label, "Read Book")
        read.tap()
        let text = app.webViews.staticTexts.firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 60), app.debugDescription)
        print("BOOK_TEXT", app.webViews.staticTexts.allElementsBoundByIndex.prefix(6).map(\.label))
        capture(app, name: "10 Book")
        let contents = app.buttons["Contents"]
        XCTAssertTrue(contents.waitForExistence(timeout: 10))
        contents.tap()
        XCTAssertTrue(app.navigationBars["Contents"].waitForExistence(timeout: 5))
        let chapters = app.collectionViews.cells
        XCTAssertGreaterThan(chapters.count, 3)
        print("BOOK_CONTENTS", chapters.allElementsBoundByIndex.prefix(8).map(\.label))
        capture(app, name: "11 Book contents")
        chapters.element(boundBy: min(4, chapters.count - 1)).tap()
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        sleep(2)
        capture(app, name: "12 Book chapter")
        let visible = Set(app.webViews.staticTexts.allElementsBoundByIndex.filter(\.isHittable).map(\.label))
        XCTAssertFalse(visible.isEmpty)
        // Leave and come back: the book reopens where it was left.
        sleep(2)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(read.waitForExistence(timeout: 10))
        read.tap()
        XCTAssertTrue(text.waitForExistence(timeout: 30))
        sleep(2)
        let reopened = Set(app.webViews.staticTexts.allElementsBoundByIndex.filter(\.isHittable).map(\.label))
        print("BOOK_RESUME visible", visible.count, "reopened", reopened.count, "shared", visible.intersection(reopened).count)
        XCTAssertFalse(visible.isDisjoint(with: reopened), "The book should reopen at the chapter it was left on")
        XCTAssertFalse(reopened.contains("The Project Gutenberg EBook of Man and Maid, by Elinor Glyn"), "It reopened at the start")
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
    func testOriginalMKVAudioTrackJourneyIfEnabled() throws {
        guard ProcessInfo.processInfo.environment["IA_MKV_UI_TESTS"] == "1" else {
            throw XCTSkip("Set IA_MKV_UI_TESTS=1 for the live original-file UI journey")
        }
        let app = XCUIApplication()
        app.launchArguments += ["--skip-playback-restoration"]
        app.launch()
        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields["Search the Internet Archive"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("the-ancient-magus-bride-s-01-e-03-720p-hd-blu-ray-multi-audio-esub\n")
        let result = app.collectionViews.cells["artifact:the-ancient-magus-bride-s-01-e-03-720p-hd-blu-ray-multi-audio-esub"]
        XCTAssertTrue(result.waitForExistence(timeout: 40), app.debugDescription)
        result.tap()
        let watch = app.buttons["artifact.watch"]
        XCTAssertTrue(watch.waitForExistence(timeout: 40))
        watch.tap()
        let original = app.collectionViews.cells.matching(NSPredicate(format: "label CONTAINS[c] %@", ".mkv")).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 10), app.debugDescription)
        original.tap()
        // Audio lives under More, as in the system player.
        let more = app.buttons["More"]
        // More stays dimmed until the film is ready, as the other controls do.
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertTrue(more.isEnabled)
        func openAudioMenu() {
            if !more.isHittable { app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap() }
            more.tap()
            let audio = app.buttons["Audio"]
            XCTAssertTrue(audio.waitForExistence(timeout: 5), app.debugDescription)
            audio.tap()
        }
        openAudioMenu()
        // The film opens on the remembered language, so switch to one that isn't selected.
        let japanese = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Japanese")).firstMatch
        let english = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "English")).firstMatch
        XCTAssertTrue(japanese.waitForExistence(timeout: 5), app.debugDescription)
        let target = japanese.isSelected ? english : japanese
        XCTAssertFalse(target.isSelected)
        target.tap()
        sleep(3)
        openAudioMenu()
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        XCTAssertTrue(target.isSelected, "The chosen audio track should read as selected")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done' OR label == 'Close'")).firstMatch
        // The controls fade while the film plays; a tap on the film brings them back.
        if !done.waitForExistence(timeout: 1) { app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap() }
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(original.waitForExistence(timeout: 5), "Closing the player should return to file selection")
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
