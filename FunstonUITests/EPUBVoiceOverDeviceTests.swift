import XCTest

/// Drives the EPUB reader on a physical iPhone with VoiceOver on. The touches
/// XCUITest synthesises reach VoiceOver like a finger's, so a one-finger swipe
/// moves VoiceOver's focus and a double tap activates the focused element.
/// What VoiceOver speaks is not observable from here: the run records what the
/// app saw (the experiment log in its Documents folder) and what the elements
/// report, and prints both for the report. Opt in with IA_EPUB_DEVICE_VO=1 on a
/// device whose VoiceOver is on.
final class EPUBVoiceOverDeviceTests: XCTestCase {
    static let gate = "IA_EPUB_DEVICE_VO"

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment[Self.gate] == "1" else { throw XCTSkip("Set \(Self.gate)=1 on a device with VoiceOver on") }
        continueAfterFailure = true
    }

    @MainActor
    func testParagraphSwipesFollowThePageAndTheAdjustableElementTurnsIt() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-playback-restoration", "-epub.a11yExperiment", "YES", "-pdf.readingLayout", "pages"]
        app.launch()
        openManAndMaid(app)
        let strip = app.descendants(matching: .any)["reader.epub.strip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 60), app.debugDescription)
        let readingPage = app.descendants(matching: .any)["reader.page"]
        XCTAssertTrue(readingPage.waitForExistence(timeout: 10))
        note("opened at: \(readingPage.value ?? "")")
        sleep(2)

        // Item 2 and 15: one-finger swipes move through the paragraphs in order; the page follows.
        let paragraphs = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'reader.epub.paragraph.'"))
        let first = paragraphs.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        note("first paragraph: \(first.identifier) \(String((first.value as? String ?? "").prefix(60)))")
        first.tap()          // under VoiceOver a single tap moves focus to the element under the finger
        sleep(2)
        for step in 1...8 {
            app.swipeRight()
            sleep(2)
            note("after swipe right \(step): \(readingPage.value ?? "")")
        }
        // The swipe-left fix: from a page's first paragraph, left goes to the previous page's last paragraph.
        for step in 1...3 {
            app.swipeLeft()
            sleep(2)
            note("after swipe left \(step): \(readingPage.value ?? "")")
        }

        // Item 14: the Reading page element is adjustable; swipe up and down change its value.
        readingPage.tap()
        sleep(2)
        let before = readingPage.value as? String ?? ""
        app.swipeUp()
        sleep(2)
        let up = readingPage.value as? String ?? ""
        app.swipeDown()
        sleep(2)
        let down = readingPage.value as? String ?? ""
        note("adjustable: before \"\(before)\", up \"\(up)\", down \"\(down)\"")
        XCTAssertNotEqual(before, up, "swipe up on the adjustable element turned no page")

        // Item 7: a double tap activates; on the Reading page it only speaks, so activate the Contents button instead and come back.
        let contents = app.buttons["Contents"]
        contents.tap()
        sleep(1)
        contents.doubleTap()
        XCTAssertTrue(app.navigationBars["Contents"].waitForExistence(timeout: 5), "double tap under VoiceOver activates the focused button")
        let cancel = app.navigationBars["Contents"].buttons.firstMatch
        cancel.tap(); sleep(1); cancel.doubleTap()
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        note("final: \(readingPage.value ?? "")")
    }

    // MARK: - Harness

    @MainActor
    private func openManAndMaid(_ app: XCUIApplication) {
        // Under VoiceOver a tap focuses and a double tap activates; without it the first tap already activates.
        func activate(_ element: XCUIElement) {
            element.tap()
            usleep(600_000)
            if element.exists { element.doubleTap() }
        }
        let library = app.tabBars.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        activate(library)
        let book = app.cells.matching(NSPredicate(format: "label CONTAINS[c] 'Man and Maid'")).firstMatch
        if book.waitForExistence(timeout: 10) {
            activate(book)
        } else {
            let search = app.tabBars.buttons["Search"]
            activate(search)
            let field = app.searchFields["Search the Internet Archive"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            activate(field)
            field.typeText("manandmaid20512gut\n")
            let result = app.collectionViews.cells["artifact:manandmaid20512gut"]
            XCTAssertTrue(result.waitForExistence(timeout: 30))
            activate(result)
        }
        let read = app.buttons["artifact.read"]
        if !read.waitForExistence(timeout: 8) {
            // A saved item opens on its files screen first; "Open Item" leads to the item screen with Read Book.
            let openItem = app.cells["openItem"]
            XCTAssertTrue(openItem.waitForExistence(timeout: 5), app.debugDescription)
            activate(openItem)
        }
        XCTAssertTrue(read.waitForExistence(timeout: 30), app.debugDescription)
        activate(read)
    }

    @MainActor
    private func note(_ line: String) {
        print("VO_DEVICE", line)
        XCTContext.runActivity(named: line) { _ in }
    }
}
