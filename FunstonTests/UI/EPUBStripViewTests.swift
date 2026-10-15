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
        func strip(_ strip: EPUBPageStripView, describe placement: EPUBPlacement) -> String {
            "Page \(placement.pageIndex + 1) of \(strip.entries.filter { $0.placement.spineIndex == placement.spineIndex }.count)"
        }
    }

    private final class ContinuousDelegate: EPUBContinuousStripDelegate {
        var settled: [(spineIndex: Int, offset: Int)] = []
        func continuousStrip(_ strip: EPUBContinuousStripView, didSettleAt offset: Int, spineIndex: Int) { settled.append((spineIndex, offset)) }
        func continuousStrip(_ strip: EPUBContinuousStripView, activateLinkAt offset: Int, spineIndex: Int) -> Bool { false }
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
        XCTAssertGreaterThan(first.frame.maxY, strip.contentOffset.y, "The first listed paragraph reaches below the top edge")
        let before = try XCTUnwrap(first.previousParagraph)
        XCTAssertLessThanOrEqual(before.frame.maxY, strip.contentOffset.y, "The paragraph before it ends above the top edge")
        XCTAssertTrue(elements.allSatisfy { $0.frame.maxY > strip.contentOffset.y }, "Nothing above the top edge is in the list")
        XCTAssertTrue(elements.contains { column(of: $0)?.spineIndex == 2 }, "The list runs on into the following chapters")
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
}
