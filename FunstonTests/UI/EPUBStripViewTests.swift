import XCTest
@testable import Funston

/// Spec 14.1 and 14.3 on the two strips, without VoiceOver running: the
/// paragraph elements VoiceOver holds survive a window reload, the element
/// list starts at the shown page (or the first visible paragraph), focusing a
/// paragraph elsewhere brings its page into view, and a three-finger scroll
/// moves one page or screen, announces it and puts focus on the first
/// paragraph there.
@MainActor
final class EPUBStripViewTests: XCTestCase {
    private static let stripSize = CGSize(width: 360, height: 520)
    private var contentSize: CGSize {
        CGSize(width: Self.stripSize.width - 2 * EPUBPageView.margin, height: Self.stripSize.height - 2 * EPUBPageView.margin)
    }

    // MARK: Fixtures

    private func paragraphs(_ count: Int, seed: String) -> String {
        (0..<count).map { "<p id=\"\(seed)\($0)\">" + String(repeating: "\(seed) paragraph \($0) keeps going so pages fill up. ", count: 5) + "</p>" }.joined()
    }

    /// Three chapters, each several pages long at the strip's size.
    private func session() throws -> EPUBReaderSession {
        let package = EPUBFixture.package(extraManifest: "<item id=\"ch2\" href=\"ch2.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"ch3\" href=\"ch3.xhtml\" media-type=\"application/xhtml+xml\"/>",
                                          spineExtra: "<itemref idref=\"ch2\"/><itemref idref=\"ch3\"/>")
        let publication = try EPUBPublication.open(data: EPUBFixture.archive([
            ("META-INF/container.xml", EPUBFixture.container), ("OEBPS/content.opf", package), ("OEBPS/nav.xhtml", EPUBFixture.nav),
            ("OEBPS/ch1.xhtml", EPUBFixture.chapter(paragraphs(24, seed: "a"), title: "One")),
            ("OEBPS/ch2.xhtml", EPUBFixture.chapter(paragraphs(18, seed: "b"), title: "Two")),
            ("OEBPS/ch3.xhtml", EPUBFixture.chapter(paragraphs(12, seed: "c"), title: "Three"))
        ]))
        return EPUBReaderSession(publication: publication, settings: EPUBReadingSettings(), contentSize: contentSize, allowsTwoColumns: false, mediaContext: .default)
    }

    private func pageEntries(_ session: EPUBReaderSession, spines: [Int]) throws -> [EPUBPageStripView.Entry] {
        var entries: [EPUBPageStripView.Entry] = []
        for spine in spines {
            let layout = try XCTUnwrap(session.layout(spine))
            let chapter = try XCTUnwrap(session.chapter(spine)).text
            XCTAssertGreaterThan(layout.pageCount, 2, "Each fixture chapter spans several pages")
            for page in 0..<layout.pageCount {
                entries.append(EPUBPageStripView.Entry(placement: EPUBPlacement(spineIndex: spine, pageIndex: page), layout: layout, chapter: chapter, title: chapter.title))
            }
        }
        return entries
    }

    private func chapters(_ session: EPUBReaderSession, spines: [Int]) throws -> [EPUBContinuousStripView.Chapter] {
        try spines.map { spine in
            let layout = try XCTUnwrap(session.layout(spine))
            let chapter = try XCTUnwrap(session.chapter(spine)).text
            return EPUBContinuousStripView.Chapter(spineIndex: spine, layout: layout, text: chapter, title: chapter.title)
        }
    }

    private func pageStrip() -> EPUBPageStripView { EPUBPageStripView(frame: CGRect(origin: .zero, size: Self.stripSize)) }
    private func continuousStrip() -> EPUBContinuousStripView { EPUBContinuousStripView(frame: CGRect(origin: .zero, size: Self.stripSize)) }

    private func placement(of element: Any?) -> EPUBPlacement? {
        ((element as? EPUBParagraphView)?.page as? EPUBStripPage)?.placement
    }

    private func column(of element: Any?) -> EPUBChapterColumn? {
        (element as? EPUBParagraphView)?.page as? EPUBChapterColumn
    }

    private final class PageDelegate: EPUBPageStripDelegate {
        var shown: [EPUBPlacement] = []
        func strip(_ strip: EPUBPageStripView, didShow placement: EPUBPlacement) { shown.append(placement) }
        func strip(_ strip: EPUBPageStripView, activateLinkAt offset: Int, spineIndex: Int) -> Bool { false }
        func strip(_ strip: EPUBPageStripView, turnBeyondWindow forward: Bool) -> Bool { false }
        func strip(_ strip: EPUBPageStripView, describe placement: EPUBPlacement) -> String {
            "Page \(placement.pageIndex + 1) of \(strip.entries.filter { $0.placement.spineIndex == placement.spineIndex }.count)"
        }
    }

    private final class ContinuousDelegate: EPUBContinuousStripDelegate {
        var settled: [(spineIndex: Int, offset: Int)] = []
        func continuousStrip(_ strip: EPUBContinuousStripView, didSettleAt offset: Int, spineIndex: Int) { settled.append((spineIndex, offset)) }
        func continuousStrip(_ strip: EPUBContinuousStripView, activateLinkAt offset: Int, spineIndex: Int) -> Bool { false }
        func continuousStrip(_ strip: EPUBContinuousStripView, extendWindow forward: Bool) -> Bool { false }
        func continuousStrip(_ strip: EPUBContinuousStripView, describeOffset offset: Int, spineIndex: Int) -> String { "Location \(offset) in \(spineIndex)" }
    }

    /// Records what the strip posts instead of handing it to VoiceOver.
    private final class Recorder {
        var posted: [(notification: UIAccessibility.Notification, argument: Any?)] = []
        func post(_ notification: UIAccessibility.Notification, _ argument: Any?) { posted.append((notification, argument)) }
    }

    // MARK: Page strip

    func testPageStripKeepsParagraphElementObjectsAcrossWindowReloads() throws {
        let session = try session()
        let strip = pageStrip()
        let shown = EPUBPlacement(spineIndex: 1, pageIndex: 0)
        strip.load(try pageEntries(session, spines: [0, 1]), showing: shown)
        let before = try XCTUnwrap(strip.accessibilityElements?.first as? EPUBParagraphView)
        XCTAssertEqual(placement(of: before), shown)
        let countBefore = strip.accessibilityElements?.count ?? 0
        // Reading moved on: the window now holds the next chapter too.
        strip.load(try pageEntries(session, spines: [0, 1, 2]), showing: shown)
        let after = try XCTUnwrap(strip.accessibilityElements?.first as? EPUBParagraphView)
        XCTAssertTrue(before === after, "The element VoiceOver holds is the same object after the reload")
        XCTAssertTrue(after.superview === strip)
        XCTAssertGreaterThan(strip.accessibilityElements?.count ?? 0, countBefore, "The new chapter's paragraphs joined the list")
    }

    func testPageStripListStartsAtTheShownPagesFirstParagraphAndRunsOn() throws {
        let session = try session()
        let strip = pageStrip()
        let shown = EPUBPlacement(spineIndex: 0, pageIndex: 2)
        strip.load(try pageEntries(session, spines: [0, 1]), showing: shown)
        let elements = try XCTUnwrap(strip.accessibilityElements as? [UIView])
        let first = try XCTUnwrap(elements.first as? EPUBParagraphView)
        XCTAssertEqual(placement(of: first), shown)
        let layout = try XCTUnwrap(session.layout(0))
        XCTAssertEqual(first.range.location, layout.table.pages[2].firstOffset, "The list opens with the shown page's first text")
        XCTAssertFalse(elements.contains { placement(of: $0)?.pageIndex == 1 && placement(of: $0)?.spineIndex == 0 }, "Pages before the shown one are not in the list")
        XCTAssertTrue(elements.contains { placement(of: $0)?.spineIndex == 1 }, "The following chapter is in the list, so Read All runs on")
        strip.show(EPUBPlacement(spineIndex: 1, pageIndex: 0), animated: false)
        XCTAssertEqual(placement(of: strip.accessibilityElements?.first), EPUBPlacement(spineIndex: 1, pageIndex: 0), "Showing another page restarts the list there")
    }

    func testFocusingAParagraphOnAnotherPageShowsThatPage() throws {
        let session = try session()
        let strip = pageStrip()
        let delegate = PageDelegate()
        strip.stripDelegate = delegate
        strip.load(try pageEntries(session, spines: [0, 1]), showing: EPUBPlacement(spineIndex: 0, pageIndex: 0))
        let target = EPUBPlacement(spineIndex: 0, pageIndex: 1)
        let elements = try XCTUnwrap(strip.accessibilityElements as? [UIView])
        let paragraph = try XCTUnwrap(elements.first { placement(of: $0) == target } as? EPUBParagraphView)
        paragraph.accessibilityElementDidBecomeFocused()
        XCTAssertEqual(strip.currentPlacement, target)
        XCTAssertEqual(strip.contentOffset.x, strip.pageWidth, accuracy: 0.5, "The strip scrolled to the focused paragraph's page")
        XCTAssertEqual(delegate.shown, [target])
    }

    func testThreeFingerScrollTurnsOnePageAnnouncesItAndFocusesItsFirstParagraph() throws {
        let session = try session()
        let strip = pageStrip()
        let delegate = PageDelegate()
        let recorder = Recorder()
        strip.stripDelegate = delegate
        strip.postAccessibilityNotification = { recorder.post($0, $1) }
        strip.load(try pageEntries(session, spines: [0, 1]), showing: EPUBPlacement(spineIndex: 0, pageIndex: 0))
        XCTAssertTrue(strip.accessibilityScroll(.next))
        let turned = EPUBPlacement(spineIndex: 0, pageIndex: 1)
        XCTAssertEqual(strip.currentPlacement, turned)
        XCTAssertEqual(delegate.shown, [turned])
        XCTAssertEqual(recorder.posted.map(\.notification.rawValue), [UIAccessibility.Notification.pageScrolled.rawValue, UIAccessibility.Notification.layoutChanged.rawValue])
        XCTAssertEqual(recorder.posted.first?.argument as? String, "Page 2 of \(try XCTUnwrap(session.layout(0)).pageCount)")
        let focused = try XCTUnwrap(recorder.posted.last?.argument as? EPUBParagraphView)
        XCTAssertTrue(focused === strip.firstElementOnShownPage)
        XCTAssertEqual(placement(of: focused), turned)
        // Backward from the window's first page: nothing moves and nothing is announced.
        strip.show(EPUBPlacement(spineIndex: 0, pageIndex: 0), animated: false)
        recorder.posted.removeAll()
        XCTAssertFalse(strip.accessibilityScroll(.previous))
        XCTAssertTrue(recorder.posted.isEmpty)
    }

    // MARK: Continuous strip

    func testContinuousStripKeepsParagraphElementObjectsAcrossWindowReloads() throws {
        let session = try session()
        let strip = continuousStrip()
        strip.load(try chapters(session, spines: [0, 1]), showing: 0, in: 0)
        let elements = try XCTUnwrap(strip.accessibilityElements as? [UIView])
        let before = try XCTUnwrap(elements.first { column(of: $0)?.spineIndex == 1 } as? EPUBParagraphView)
        XCTAssertEqual(before.blockIndex, 0)
        // Reading crossed into chapter two: the window moves on.
        strip.load(try chapters(session, spines: [0, 1, 2]), showing: before.range.location, in: 1)
        let reloaded = try XCTUnwrap(strip.accessibilityElements as? [UIView])
        let after = try XCTUnwrap(reloaded.first { column(of: $0)?.spineIndex == 1 && ($0 as? EPUBParagraphView)?.blockIndex == 0 } as? EPUBParagraphView)
        XCTAssertTrue(before === after, "The element VoiceOver holds is the same object after the reload")
        XCTAssertTrue(after.superview === strip)
        XCTAssertTrue(reloaded.contains { column(of: $0)?.spineIndex == 2 }, "The new chapter's paragraphs joined the list")
    }

    func testContinuousStripListStartsAtTheFirstVisibleParagraph() throws {
        let session = try session()
        let strip = continuousStrip()
        strip.load(try chapters(session, spines: [0, 1, 2]), showing: 0, in: 0)
        let chapter = try XCTUnwrap(session.chapter(0)).text
        let block = 10
        strip.scroll(toOffset: chapter.blocks[block].range.location, in: 0)
        let elements = try XCTUnwrap(strip.accessibilityElements as? [UIView])
        let first = try XCTUnwrap(elements.first as? EPUBParagraphView)
        XCTAssertEqual(column(of: first)?.spineIndex, 0)
        let edge = strip.contentOffset.y + EPUBContinuousStripView.visibleThreshold
        XCTAssertGreaterThan(first.frame.maxY, edge, "The first listed paragraph reaches below the top edge")
        let before = try XCTUnwrap(first.previousParagraph)
        XCTAssertLessThanOrEqual(before.frame.maxY, edge, "The paragraph before it ends at or above the top edge")
        XCTAssertTrue(elements.allSatisfy { $0.frame.maxY > edge }, "Nothing above the top edge is in the list")
        XCTAssertTrue(elements.contains { column(of: $0)?.spineIndex == 2 }, "The list runs on into the following chapters")
    }

    func testContinuousStripListSkipsAParagraphOnlyASliverOfWhichIsVisible() throws {
        let session = try session()
        let strip = continuousStrip()
        strip.load(try chapters(session, spines: [0, 1, 2]), showing: 0, in: 0)
        let chapter = try XCTUnwrap(session.chapter(0)).text
        let block = 10
        // A jump puts the target's first line one top inset below the edge; the paragraph
        // before it ends inside that inset, with a few points still showing.
        strip.scroll(toOffset: chapter.blocks[block].range.location, in: 0)
        let first = try XCTUnwrap(strip.accessibilityElements?.first as? EPUBParagraphView)
        let before = try XCTUnwrap(first.previousParagraph)
        XCTAssertGreaterThan(before.frame.maxY, strip.contentOffset.y, "The previous paragraph's tail is still on screen")
        XCTAssertLessThanOrEqual(before.frame.maxY, strip.contentOffset.y + EPUBContinuousStripView.visibleThreshold)
        XCTAssertEqual(first.blockIndex, block, "Entering from the controls lands on the paragraph jumped to, not the tail above it")
        XCTAssertTrue(strip.firstVisibleElement === first)
    }

    func testFocusingAParagraphReportsItsOwnPositionNotTheScrollOffset() throws {
        let session = try session()
        let strip = continuousStrip()
        let delegate = ContinuousDelegate()
        strip.stripDelegate = delegate
        strip.load(try chapters(session, spines: [0, 1, 2]), showing: 0, in: 0)
        let elements = try XCTUnwrap(strip.accessibilityElements as? [UIView])
        // A paragraph already on screen: nothing scrolls, and it is still the position.
        let second = try XCTUnwrap(elements[1] as? EPUBParagraphView)
        let offsetBefore = strip.contentOffset.y
        second.accessibilityElementDidBecomeFocused()
        XCTAssertEqual(strip.contentOffset.y, offsetBefore, accuracy: 0.5)
        XCTAssertEqual(delegate.settled.last?.spineIndex, 0)
        XCTAssertEqual(delegate.settled.last?.offset, second.range.location)
        // The next chapter's first paragraph: the strip scrolls, and the position is that
        // paragraph, not the previous chapter's end that the scroll offset happens to touch.
        let next = try XCTUnwrap(elements.first { column(of: $0)?.spineIndex == 1 } as? EPUBParagraphView)
        next.accessibilityElementDidBecomeFocused()
        XCTAssertEqual(delegate.settled.last?.spineIndex, 1)
        XCTAssertEqual(delegate.settled.last?.offset, next.range.location)
    }

    func testFocusingAParagraphBelowTheViewBringsItIntoView() throws {
        let session = try session()
        let strip = continuousStrip()
        let delegate = ContinuousDelegate()
        strip.stripDelegate = delegate
        strip.load(try chapters(session, spines: [0, 1, 2]), showing: 0, in: 0)
        let elements = try XCTUnwrap(strip.accessibilityElements as? [UIView])
        let paragraph = try XCTUnwrap(elements.first { column(of: $0)?.spineIndex == 1 } as? EPUBParagraphView)
        XCTAssertGreaterThan(paragraph.frame.minY, strip.contentOffset.y + strip.bounds.height, "The target starts below the view")
        paragraph.accessibilityElementDidBecomeFocused()
        XCTAssertEqual(strip.contentOffset.y, paragraph.frame.minY - EPUBContinuousStripView.focusTopInset, accuracy: 0.5)
        XCTAssertFalse(delegate.settled.isEmpty, "The owner hears about the move")
    }

    func testThreeFingerScrollMovesOneScreenAnnouncesItAndFocusesTheFirstParagraphThere() throws {
        let session = try session()
        let strip = continuousStrip()
        let delegate = ContinuousDelegate()
        let recorder = Recorder()
        strip.stripDelegate = delegate
        strip.postAccessibilityNotification = { recorder.post($0, $1) }
        strip.load(try chapters(session, spines: [0, 1, 2]), showing: 0, in: 0)
        XCTAssertTrue(strip.accessibilityScroll(.down))
        XCTAssertEqual(strip.contentOffset.y, Self.stripSize.height - 2 * EPUBContinuousStripView.margin, accuracy: 0.5)
        XCTAssertEqual(recorder.posted.map(\.notification.rawValue), [UIAccessibility.Notification.pageScrolled.rawValue, UIAccessibility.Notification.layoutChanged.rawValue])
        let announced = try XCTUnwrap(recorder.posted.first?.argument as? String)
        XCTAssertTrue(announced.hasPrefix("Location "), announced)
        let focused = try XCTUnwrap(recorder.posted.last?.argument as? UIView)
        XCTAssertTrue(focused === strip.firstVisibleElement)
        XCTAssertTrue(focused === (strip.accessibilityElements as? [UIView])?.first, "Focus lands on the first paragraph of the new screen")
        XCTAssertGreaterThan(focused.frame.maxY, strip.contentOffset.y)
        XCTAssertEqual(delegate.settled.last?.spineIndex, 0)
        // Up from the top: nothing moves and nothing is announced.
        strip.scroll(toOffset: 0, in: 0)
        recorder.posted.removeAll()
        XCTAssertFalse(strip.accessibilityScroll(.up))
        XCTAssertTrue(recorder.posted.isEmpty)
    }

    // MARK: The Reading page element (VoiceOver report: three-finger swipes with focus on it did nothing on the iPhone)

    func testAThreeFingerSwipeWithFocusOnTheReadingPageElementTurnsThePageLikeOneInsideTheStrip() throws {
        let session = try session()
        let strip = pageStrip()
        let delegate = PageDelegate()
        let recorder = Recorder()
        strip.stripDelegate = delegate
        strip.postAccessibilityNotification = { recorder.post($0, $1) }
        strip.load(try pageEntries(session, spines: [0, 1]), showing: EPUBPlacement(spineIndex: 0, pageIndex: 0))
        // The element's container is the reader's view, which scrolls nothing itself.
        let container = UIView()
        container.addSubview(strip)
        let controls = ReaderControls(reader: UIViewController(), pageView: container)
        XCTAssertFalse(controls.page.accessibilityScroll(.next), "With no reader behind it the element turns nothing")
        XCTAssertEqual(strip.currentPlacement, EPUBPlacement(spineIndex: 0, pageIndex: 0))
        controls.page.scroll = { strip.accessibilityScroll($0) }
        XCTAssertTrue(controls.page.accessibilityScroll(.next))
        XCTAssertEqual(strip.currentPlacement, EPUBPlacement(spineIndex: 0, pageIndex: 1))
        XCTAssertEqual(recorder.posted.map(\.notification.rawValue), [UIAccessibility.Notification.pageScrolled.rawValue, UIAccessibility.Notification.layoutChanged.rawValue])
        XCTAssertTrue((recorder.posted.last?.argument as? EPUBParagraphView) === strip.firstElementOnShownPage, "Focus moves into the strip, onto the new page's first paragraph")
    }

    // MARK: Swiping back out of the shown page (Spec 24, VoiceOver report gap 1)

    func testOnceFocusIsInsideThePageStripTheListReachesBackToEarlierPagesUntilFocusLeaves() throws {
        let session = try session()
        let strip = pageStrip()
        let shown = EPUBPlacement(spineIndex: 0, pageIndex: 2)
        strip.load(try pageEntries(session, spines: [0, 1]), showing: shown)
        let first = try XCTUnwrap(strip.accessibilityElements?.first as? EPUBParagraphView)
        XCTAssertEqual(placement(of: first), shown, "Entering from the controls lands on the shown page")
        first.accessibilityElementDidBecomeFocused()
        let elements = try XCTUnwrap(strip.accessibilityElements as? [UIView])
        let position = try XCTUnwrap(elements.firstIndex { $0 === first })
        XCTAssertGreaterThan(position, 0, "With focus inside, the earlier pages' paragraphs come before it")
        XCTAssertEqual(placement(of: elements[position - 1]), EPUBPlacement(spineIndex: 0, pageIndex: 1), "A swipe left reaches the previous page's last paragraph")
        XCTAssertEqual(placement(of: elements[0]), EPUBPlacement(spineIndex: 0, pageIndex: 0))
        strip.focusDidMove(to: UIView())
        XCTAssertTrue((strip.accessibilityElements?.first as? UIView) === first, "Once focus left the strip the list starts at the shown page again")
    }

    func testOnceFocusIsInsideTheContinuousStripTheListReachesAboveTheTopEdgeUntilFocusLeaves() throws {
        let session = try session()
        let strip = continuousStrip()
        strip.load(try chapters(session, spines: [0, 1, 2]), showing: 0, in: 0)
        let chapter = try XCTUnwrap(session.chapter(0)).text
        strip.scroll(toOffset: chapter.blocks[10].range.location, in: 0)
        let first = try XCTUnwrap(strip.accessibilityElements?.first as? EPUBParagraphView)
        XCTAssertEqual(first.blockIndex, 10)
        first.accessibilityElementDidBecomeFocused()
        let elements = try XCTUnwrap(strip.accessibilityElements as? [UIView])
        XCTAssertEqual((elements.first as? EPUBParagraphView)?.blockIndex, 0, "With focus inside, the paragraphs above the top edge are in the list")
        XCTAssertEqual((elements[9] as? EPUBParagraphView)?.blockIndex, 9)
        strip.focusDidMove(to: UIView())
        XCTAssertTrue((strip.accessibilityElements?.first as? UIView) === first, "Once focus left the strip the list starts at the first visible paragraph again")
    }

    // MARK: Right-to-left books (Spec 13.2, Spec 24 gap 2)

    func testRightToLeftPageStripOrdersPagesFromTheRightAndMapsScrollDirectionsThroughTheProgression() throws {
        let session = try session()
        let strip = pageStrip()
        strip.isRightToLeft = true
        let recorder = Recorder()
        strip.postAccessibilityNotification = { recorder.post($0, $1) }
        let entries = try pageEntries(session, spines: [0, 1])
        strip.load(entries, showing: EPUBPlacement(spineIndex: 0, pageIndex: 0))
        XCTAssertEqual(strip.contentOffset.x, strip.pageWidth * CGFloat(entries.count - 1), accuracy: 0.5, "The first page sits at the right end")
        XCTAssertFalse(strip.accessibilityScroll(.left), "Left is backward in a right-to-left book: nothing before the first page")
        XCTAssertTrue(strip.accessibilityScroll(.right), "Right is forward")
        XCTAssertEqual(strip.currentPlacement, EPUBPlacement(spineIndex: 0, pageIndex: 1))
        XCTAssertEqual(strip.contentOffset.x, strip.pageWidth * CGFloat(entries.count - 2), accuracy: 0.5)
        XCTAssertEqual(recorder.posted.first?.notification.rawValue, UIAccessibility.Notification.pageScrolled.rawValue)
        XCTAssertTrue(strip.accessibilityScroll(.next), "Next is always forward")
        XCTAssertEqual(strip.currentPlacement, EPUBPlacement(spineIndex: 0, pageIndex: 2))
        XCTAssertTrue(strip.accessibilityScroll(.left))
        XCTAssertEqual(strip.currentPlacement, EPUBPlacement(spineIndex: 0, pageIndex: 1))
        let hit = try XCTUnwrap(strip.characterIndex(at: CGPoint(x: strip.contentOffset.x + EPUBPageView.margin + 1, y: EPUBPageView.margin + 1)))
        XCTAssertEqual(hit.placement, EPUBPlacement(spineIndex: 0, pageIndex: 1), "Hit testing follows the reversed slots")
    }

    func testRightToLeftContinuousStripMapsLeftAndRightThroughTheProgression() throws {
        let session = try session()
        let strip = continuousStrip()
        strip.isRightToLeft = true
        strip.load(try chapters(session, spines: [0, 1, 2]), showing: 0, in: 0)
        XCTAssertFalse(strip.accessibilityScroll(.left), "Left is backward in a right-to-left book: nothing above the top")
        XCTAssertTrue(strip.accessibilityScroll(.right), "Right is forward")
        XCTAssertEqual(strip.contentOffset.y, Self.stripSize.height - 2 * EPUBContinuousStripView.margin, accuracy: 0.5)
        XCTAssertTrue(strip.accessibilityScroll(.left))
        XCTAssertEqual(strip.contentOffset.y, 0, accuracy: 0.5)
        strip.isRightToLeft = false
        XCTAssertFalse(strip.accessibilityScroll(.right), "Right is backward in a left-to-right book")
        XCTAssertTrue(strip.accessibilityScroll(.left))
    }

    // MARK: The Lines rotor (Spec 14.2; VoiceOver report item 3)

    func testLineGranularityEndsBeforeASoftWrappedLinesTrailingSpaceSoVoiceOverStepsOntoTheNextLine() throws {
        let session = try session()
        let strip = pageStrip()
        strip.load(try pageEntries(session, spines: [0]), showing: EPUBPlacement(spineIndex: 0, pageIndex: 0))
        let paragraph = try XCTUnwrap(strip.accessibilityElements?.first as? EPUBParagraphView)
        let layout = try XCTUnwrap(session.layout(0))
        let chapter = try XCTUnwrap(session.chapter(0)).text
        let lines = layout.table.lineFrames(onPage: 0).map { layout.table.lines[$0.line].range }.filter { NSIntersectionRange($0, paragraph.range).length > 0 }
        XCTAssertGreaterThan(lines.count, 1, "The fixture paragraph wraps")
        let first = lines[0], second = lines[1]
        XCTAssertEqual(chapter.text(in: NSRange(location: first.location + first.length - 1, length: 1)), " ", "A soft wrap keeps its trailing space in the line table")
        let tokenizer = paragraph.tokenizer
        let start = EPUBTextPosition(first.location)
        let enclosing = try XCTUnwrap(tokenizer.rangeEnclosingPosition(start, with: .line, inDirection: UITextDirection.storage(.forward)) as? EPUBTextRange)
        XCTAssertEqual(enclosing.range, NSRange(location: first.location, length: first.length - 1), "The spoken line stops before the trailing space")
        let end = try XCTUnwrap(tokenizer.position(from: start, toBoundary: .line, inDirection: UITextDirection.storage(.forward)) as? EPUBTextPosition)
        XCTAssertEqual(end.offset + 1, second.location, "One past the boundary is the next line's first character, which is where VoiceOver steps")
        XCTAssertTrue(tokenizer.isPosition(end, atBoundary: .line, inDirection: UITextDirection.storage(.forward)))
        let nextLine = try XCTUnwrap(tokenizer.rangeEnclosingPosition(EPUBTextPosition(end.offset + 1), with: .line, inDirection: UITextDirection.storage(.forward)) as? EPUBTextRange)
        XCTAssertEqual(nextLine.range.location, second.location)
    }
}
