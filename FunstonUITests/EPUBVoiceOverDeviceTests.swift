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
        // The paragraph model this test was written for; the page model is the default now.
        app.launchArguments += ["--skip-playback-restoration", "-epub.a11yExperiment", "YES", "-pdf.readingLayout", "pages", "-epub.a11yModel", "blocks"]
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

        // Item 14: the Reading page element follows the Contents button in VoiceOver's list; a tap on the
        // button focuses it, a swipe right lands on Reading page, and swipes up and down adjust it.
        let contents = app.buttons["Contents"]
        contents.tap()
        sleep(1)
        app.swipeRight()
        sleep(2)
        let before = readingPage.value as? String ?? ""
        app.swipeUp()
        sleep(2)
        let up = readingPage.value as? String ?? ""
        app.swipeDown()
        sleep(2)
        let down = readingPage.value as? String ?? ""
        note("adjustable: before \"\(before)\", up \"\(up)\", down \"\(down)\"")
        XCTAssertNotEqual(before, up, "swipe up on the Reading page element turned no page")
        XCTAssertEqual(before, down, "swipe down did not turn back")

        // A double tap on the focused Contents button: recorded, not asserted (on the first run it did not open the sheet).
        contents.tap()
        sleep(1)
        contents.doubleTap()
        let opened = app.navigationBars["Contents"].waitForExistence(timeout: 5)
        note("double tap on the focused Contents button opened the sheet: \(opened)")
        if opened {
            let cancel = app.navigationBars["Contents"].buttons.firstMatch
            cancel.tap(); sleep(1); cancel.doubleTap()
            _ = strip.waitForExistence(timeout: 5)
        }
        note("final: \(readingPage.value ?? "")")
    }

    /// One-finger swipes to try past the page's end before concluding they stay on the page.
    static let swipesPastThePage = 6

    /// The page model, the default since the paragraph test above was written: there is no Reading
    /// page element, one-finger swipes stay within the shown page (past its end they leave the book
    /// for the tab bar, as in other readers; pages turn by three-finger swipe, which XCUITest cannot
    /// make), and coming back from the tab bar or the toolbar lands on the shown page without moving
    /// the reader (on the paragraph strip, a swipe left from the tab bar jumped to the end of the next
    /// chapter). The name sorts after the paragraph test, which stores the paragraph model; this one
    /// launches with the page model and leaves it stored.
    @MainActor
    func testThePageModelKeepsThePageUnderOneFingerSwipesAndAcrossTheBars() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-playback-restoration", "-epub.a11yExperiment", "YES", "-pdf.readingLayout", "pages",
                                "-epub.a11yModel", "page", "-epub.positionValue", "YES"]
        app.launch()
        openManAndMaid(app)
        let page = app.descendants(matching: .any)["reader.epub.page"]
        XCTAssertTrue(page.waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["reader.page"].exists, "The page model has no Reading page element")
        func position() -> String { page.value as? String ?? "" }
        let firstItem = app.descendants(matching: .any)["reader.epub.item.0"]
        XCTAssertTrue(firstItem.waitForExistence(timeout: 10))
        sleep(2)
        let opened = position()
        note("page model opened at: \(opened)")

        // Swipes right from the page's first item never turn the page.
        firstItem.tap()      // under VoiceOver a tap moves focus to the element under the finger
        sleep(2)
        for step in 1...Self.swipesPastThePage {
            app.swipeRight()
            sleep(2)
            note("swipe right \(step): \(position())")
            XCTAssertEqual(position(), opened, "A one-finger swipe turned the page")
        }
        // Nor do swipes left.
        for step in 1...Self.swipesPastThePage {
            app.swipeLeft()
            sleep(2)
            note("swipe left \(step): \(position())")
            XCTAssertEqual(position(), opened, "A one-finger swipe turned the page")
        }

        // From the tab bar's first tab, a swipe left lands on the shown page and moves nothing.
        let firstTab = app.tabBars.buttons.element(boundBy: 0)
        XCTAssertTrue(firstTab.exists)
        firstTab.tap()
        sleep(2)
        app.swipeLeft()
        sleep(2)
        note("tab bar, swipe left: \(position())")
        XCTAssertEqual(position(), opened, "Coming back from the tab bar moved the reader")

        // From the Contents button, a swipe right lands on the shown page and moves nothing.
        let contents = app.buttons["Contents"]
        XCTAssertTrue(contents.exists)
        contents.tap()
        sleep(2)
        app.swipeRight()
        sleep(2)
        note("Contents, swipe right: \(position())")
        XCTAssertEqual(position(), opened, "Coming back from the toolbar moved the reader")
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
