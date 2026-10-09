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

        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.searchFields["Search the Internet Archive"].exists)

        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 2))

        let filters = app.segmentedControls["libraryFilter"]
        XCTAssertTrue(filters.waitForExistence(timeout: 2))
        filters.buttons["Downloads"].tap()
        XCTAssertTrue(app.navigationBars["Library"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)

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
        XCTAssertTrue(revealRecordingCell(recording, in: app))
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

    @MainActor
    func testFullPlayerLayoutRemainsStableWhenTogglingPlayback() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-playback-restoration"]
        app.launch()
        XCTAssertTrue(app.buttons["oldtimeradio"].waitForExistence(timeout: 10))
        app.buttons["oldtimeradio"].tap()
        let recording = app.collectionViews.cells["artifact:OTRR_Gunsmoke_Singles"]
        XCTAssertTrue(revealRecordingCell(recording, in: app))
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
        let title = app.staticTexts["player.trackTitle"]
        let position = app.sliders["Playback position"]
        let toggleFrame = toggle.frame
        let titleFrame = title.frame
        let positionFrame = position.frame
        for _ in 0..<3 {
            toggle.tap()
            XCTAssertTrue(waitForValue("Paused", of: toggle))
            XCTAssertEqual(toggle.frame.minY, toggleFrame.minY, accuracy: 1)
            XCTAssertEqual(title.frame.minY, titleFrame.minY, accuracy: 1)
            XCTAssertEqual(position.frame.minY, positionFrame.minY, accuracy: 1)
            toggle.tap()
            XCTAssertTrue(waitForValue("Playing", of: toggle))
            XCTAssertEqual(toggle.frame.minY, toggleFrame.minY, accuracy: 1)
            XCTAssertEqual(title.frame.minY, titleFrame.minY, accuracy: 1)
            XCTAssertEqual(position.frame.minY, positionFrame.minY, accuracy: 1)
        }
        toggle.tap()
        XCTAssertTrue(waitForValue("Paused", of: toggle))
        let download = app.buttons["player.download"]
        let output = app.descendants(matching: .any)["player.audioOutput"].firstMatch
        XCTAssertTrue(download.exists)
        XCTAssertTrue(output.exists)
        let sleep = app.buttons["player.sleepTimer"]
        XCTAssertEqual(sleep.frame.minY, download.frame.minY, accuracy: 2)
        XCTAssertEqual(sleep.frame.minY, output.frame.minY, accuracy: 2)
        capture(app, name: "04c Stable player controls")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Recordings,")).firstMatch.tap()
        let currentRow = app.buttons["queue.recording.0"]
        XCTAssertTrue(currentRow.waitForExistence(timeout: 8))
        XCTAssertTrue(currentRow.label.contains("Current recording."))
        let search = app.searchFields["Find a recording"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("zzzz-no-such-recording")
        XCTAssertFalse(currentRow.exists)
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        app.buttons["queue.current"].tap()
        XCTAssertTrue(currentRow.waitForExistence(timeout: 5))
        capture(app, name: "04d Searchable recording list")
        app.buttons["queue.done"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
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
        XCTAssertTrue(revealRecordingCell(recording, in: app))
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
        for _ in 0..<20 where !app.buttons["oldtimeradio"].waitForExistence(timeout: 1) { app.swipeUp() }
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

    @MainActor func testVideoViewingJourneyAndNativeControls() throws { try videoJourney(category: "UICTContentSizeCategoryL") }
    @MainActor func testVideoViewingAtXXXLType() throws { try videoJourney(category: "UICTContentSizeCategoryXXXL") }
    @MainActor func testVideoViewingAtAX5Type() throws { try videoJourney(category: "UICTContentSizeCategoryAccessibilityXXXL") }

    @MainActor
    private func videoJourney(category: String) throws {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-playback-restoration", "-UIPreferredContentSizeCategoryName", category]
        app.launch()
        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields["Search the Internet Archive"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("DuckandC1951\n")
        let film = app.collectionViews.cells["artifact:DuckandC1951"]
        XCTAssertTrue(app.collectionViews.cells.firstMatch.waitForExistence(timeout: 30))
        for _ in 0..<16 where !film.exists { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(film.waitForExistence(timeout: 5), app.debugDescription)
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
        if UIAccessibility.isVoiceOverRunning {
            XCTAssertTrue(transport.isHittable, "Native playback controls must remain reachable with VoiceOver")
            capture(app, name: "09 Video with VoiceOver controls")
        } else {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: speed)], timeout: 12), .completed,
                           "The native playback toolbar should auto-hide while playing")
            assertFourByThreeFilmIsCenteredIn(app.screenshot().image)
            capture(app, name: "09 Fullscreen video without toolbar")
        }
        if !transport.exists { canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        if transport.label == "Pause" { transport.tap() }
        XCTAssertEqual(transport.label, "Play")
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done' OR label == 'Close' OR identifier == 'Close Button'")).firstMatch
        if !done.exists { canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(done.waitForExistence(timeout: 5), app.debugDescription)
        let closePoint = done.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        closePoint.tap()
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        file.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: canvas)], timeout: 45), .completed)
        if !transport.exists || !transport.isHittable { canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(transport.waitForExistence(timeout: 5))
        if transport.label == "Pause" { transport.tap() }
        if !done.exists && !transport.exists { canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
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
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done' OR label == 'Close' OR identifier == 'Close Button'")).firstMatch
        // The controls fade while the film plays; a tap on the film brings them back.
        if !done.waitForExistence(timeout: 1) { app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap() }
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(original.waitForExistence(timeout: 5), "Closing the player should return to file selection")
    }

    @MainActor func testCleanupScreensAtDefaultType() throws { try cleanupScreens(category: "UICTContentSizeCategoryL", name: "Default") }
    @MainActor func testCleanupScreensAtXXXLType() throws { try cleanupScreens(category: "UICTContentSizeCategoryXXXL", name: "XXXL") }
    @MainActor func testCleanupScreensAtAX5Type() throws { try cleanupScreens(category: "UICTContentSizeCategoryAccessibilityXXXL", name: "AX5") }

    @MainActor private func cleanupScreens(category: String, name: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--skip-playback-restoration", "-UIPreferredContentSizeCategoryName", category]
        app.launch()
        app.tabBars.buttons["Search"].tap()
        let search = app.searchFields["Search the Internet Archive"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("OTRR_Gunsmoke_Singles\n")
        let item = app.collectionViews.cells["artifact:OTRR_Gunsmoke_Singles"]
        XCTAssertTrue(app.collectionViews.cells.firstMatch.waitForExistence(timeout: 30))
        for _ in 0..<24 where !item.exists { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        let play = app.buttons["artifact.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        for _ in 0..<5 where !play.isHittable { app.swipeUp() }
        capture(app, name: name + " Recording detail")
        play.tap()
        let compact = app.descendants(matching: .any)["compactPlayer.open"].firstMatch
        XCTAssertTrue(compact.waitForExistence(timeout: 10))
        compact.tap()
        XCTAssertTrue(app.buttons["player.toggle"].waitForExistence(timeout: 8))
        let speed = app.buttons["player.speed"]
        if name == "AX5" {
            for _ in 0..<8 where !speed.isHittable { app.swipeUp() }
        } else {
            XCTAssertEqual(app.scrollViews.count, 0, "Standard Dynamic Type must fit without scrolling")
            XCTAssertTrue(app.buttons["player.toggle"].isHittable)
            XCTAssertTrue(app.buttons["player.sleepTimer"].isHittable)
            XCTAssertTrue(speed.isHittable)
            XCTAssertTrue(app.buttons["Close player"].isHittable)
            XCTAssertGreaterThanOrEqual(app.buttons["Close player"].frame.minY, app.frame.minY)
            XCTAssertLessThanOrEqual(speed.frame.maxY, app.frame.maxY)
            XCTAssertTrue(app.buttons["player.download"].isHittable || app.descendants(matching: .any)["player.downloaded"].firstMatch.isHittable)
        }
        capture(app, name: name + " Player")
        speed.tap()
        let stepper = app.descendants(matching: .any)["player.speed.adjustable"].firstMatch
        XCTAssertTrue(stepper.waitForExistence(timeout: 5))
        XCTAssertEqual(stepper.label, "Playback speed")
        XCTAssertTrue((stepper.value as? String ?? "").hasSuffix(" times"))
        app.buttons["1.5 times"].tap()
        XCTAssertEqual(stepper.value as? String, "1.5 times")
        capture(app, name: name + " Speed")
        app.buttons["1 times"].tap()
        app.buttons["Done"].tap()
        let recordings = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Recordings,")).firstMatch
        if name == "AX5" { for _ in 0..<8 where !recordings.isHittable { app.swipeDown() } }
        recordings.tap()
        let current = app.buttons["queue.recording.0"]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["queue.current"].isEnabled)
        XCTAssertEqual(app.buttons["queue.current"].label, "Jump to now playing")
        capture(app, name: name + " Recordings")
        app.buttons["queue.done"].tap()
        app.buttons["Close player"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        search.tap()
        search.buttons["Clear text"].tap()
        search.typeText("flatlandromanceo00abbouoft\n")
        let book = app.collectionViews.cells["artifact:flatlandromanceo00abbouoft"]
        if !book.waitForExistence(timeout: 5) {
            for _ in 0..<12 where !book.exists { app.collectionViews.firstMatch.swipeDown() }
            for _ in 0..<12 where !book.exists { app.collectionViews.firstMatch.swipeUp() }
        }
        XCTAssertTrue(book.waitForExistence(timeout: 5), app.debugDescription)
        book.tap()
        XCTAssertTrue(app.navigationBars["Book"].waitForExistence(timeout: 5))
        let read = app.buttons["artifact.read"]
        XCTAssertTrue(read.waitForExistence(timeout: 30))
        for _ in 0..<8 where !read.isHittable { app.swipeUp() }
        capture(app, name: name + " Book detail")
        read.tap()
        let page = app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES %@", "Page [0-9]+ of [0-9]+")).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 60))
        app.buttons["Next page"].tap()
        let label = page.label
        if !(app.buttons["Reading options"].value as? String ?? "").contains("Continuous Scroll") {
            app.buttons["Reading options"].tap()
            let continuous = app.buttons["Continuous Scroll"]
            for _ in 0..<4 where !continuous.isHittable {
                let menuPoint = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.65))
                menuPoint.press(forDuration: 0.05, thenDragTo: menuPoint.withOffset(CGVector(dx: 0, dy: -160)), withVelocity: .slow, thenHoldForDuration: 0.2)
            }
            XCTAssertTrue(continuous.waitForExistence(timeout: 3))
            continuous.tap()
        }
        XCTAssertEqual(page.label, label)
        capture(app, name: name + " Continuous reader")
        app.buttons["Reading options"].tap()
        app.buttons["Page by Page"].tap()
        XCTAssertEqual(page.label, label)
        capture(app, name: name + " Page reader")
        app.terminate()
    }

    @MainActor
    private func revealRecordingCell(_ recording: XCUIElement, in app: XCUIApplication) -> Bool {
        if recording.waitForExistence(timeout: 3) { return true }
        let collection = app.collectionViews.firstMatch
        guard collection.cells.firstMatch.waitForExistence(timeout: 40) else { return false }
        for _ in 0..<12 where !recording.exists { collection.swipeUp(velocity: .slow) }
        return recording.waitForExistence(timeout: 5)
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

extension FunstonUITests {
    @MainActor
    func testPlaybackSpeedSheetLayoutMatrix() throws {
        let originalAppearance = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = originalAppearance }
        for category in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            for appearance in ["Light", "Dark"] {
                XCUIDevice.shared.appearance = appearance == "Dark" ? .dark : .light
                let app = XCUIApplication()
                app.launchArguments = ["--skip-playback-restoration", "-UIPreferredContentSizeCategoryName", category]
                app.launchEnvironment["FUNSTON_TEST_APPEARANCE"] = appearance
                app.launch()
                let continuing = app.buttons["explore.continue.OTRR_Gunsmoke_Singles"]
                if continuing.exists {
                    continuing.tap()
                } else {
                    let radio = app.buttons["oldtimeradio"]
                    for _ in 0..<12 where !radio.isHittable { app.swipeUp() }
                    XCTAssertTrue(radio.isHittable)
                    radio.tap()
                    let recording = app.cells["artifact:OTRR_Gunsmoke_Singles"]
                    for _ in 0..<12 where !recording.waitForExistence(timeout: 3) { app.swipeUp() }
                    XCTAssertTrue(recording.waitForExistence(timeout: 10))
                    recording.tap()
                    let play = app.buttons["artifact.play"]
                    XCTAssertTrue(play.waitForExistence(timeout: 40))
                    for _ in 0..<8 where !play.isHittable { app.swipeUp() }
                    play.tap()
                }
                let mini = app.descendants(matching: .any)["compactPlayer.open"].firstMatch
                XCTAssertTrue(mini.waitForExistence(timeout: 15))
                mini.tap()
                let speed = app.buttons["player.speed"]
                XCTAssertTrue(speed.waitForExistence(timeout: 8))
                for _ in 0..<8 where !speed.isHittable { app.swipeUp() }
                speed.tap()
                let stepper = app.descendants(matching: .any)["player.speed.adjustable"].firstMatch
                XCTAssertTrue(stepper.waitForExistence(timeout: 5))
                let presets = ["1 times", "1.25 times", "1.5 times", "2 times"].map { app.buttons[$0] }
                for preset in presets {
                    XCTAssertTrue(preset.isHittable)
                    XCTAssertGreaterThanOrEqual(preset.frame.height, 44)
                    XCTAssertEqual(preset.frame.width, presets[0].frame.width, accuracy: 1)
                }
                if category == "UICTContentSizeCategoryL" {
                    for preset in presets { XCTAssertEqual(preset.frame.minY, presets[0].frame.minY, accuracy: 1) }
                } else {
                    XCTAssertEqual(presets[0].frame.minY, presets[1].frame.minY, accuracy: 1)
                    XCTAssertEqual(presets[2].frame.minY, presets[3].frame.minY, accuracy: 1)
                    XCTAssertGreaterThan(presets[2].frame.minY, presets[0].frame.maxY)
                }
                presets[2].tap()
                XCTAssertTrue(presets[2].isSelected)
                XCTAssertFalse(presets[0].isSelected)
                XCTAssertEqual(stepper.label, "Playback speed")
                XCTAssertEqual(stepper.value as? String, "1.5 times")
                XCTAssertGreaterThanOrEqual(stepper.frame.height, 44)
                XCTAssertTrue(app.buttons["Done"].isHittable)
                capture(app, name: "Playback Speed \(appearance) \(category == "UICTContentSizeCategoryL" ? "Default" : "AX5")")
                presets[0].tap()
                app.buttons["Done"].tap()
                app.terminate()
            }
        }
    }
}

final class GunsmokePlaybackRegressionUITests: XCTestCase {
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
