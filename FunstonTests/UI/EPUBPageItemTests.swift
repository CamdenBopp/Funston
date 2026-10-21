import Accessibility
import XCTest
@testable import Funston

/// The page model VoiceOver reads in the EPUB reader: only the shown page's
/// items, text read line by line, headings, links and images apart, the last
/// item turning the page, and the element VoiceOver holds kept across a turn.
@MainActor
final class EPUBPageItemTests: XCTestCase {
    private static let pageSize = CGSize(width: 360, height: 520)
    private static let onePixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="

    private func paragraphs(_ count: Int, seed: String) -> String {
        (0..<count).map { "<p>" + String(repeating: "\(seed) paragraph \($0) keeps going so pages fill up. ", count: 5) + "</p>" }.joined()
    }

    /// Chapter one opens with a heading, a paragraph with a link inside, an image and more
    /// text, then runs on over several pages; chapter two follows.
    private func session() throws -> EPUBReaderSession {
        let opening = "<h1>Opening</h1><p>Before the link <a href=\"ch2.xhtml\">go to two</a> and after the link.</p>"
            + "<p><img src=\"data:image/png;base64,\(Self.onePixelPNG)\" alt=\"one dot\"/></p><p>After the image.</p>"
        let package = EPUBFixture.package(extraManifest: "<item id=\"ch2\" href=\"ch2.xhtml\" media-type=\"application/xhtml+xml\"/>", spineExtra: "<itemref idref=\"ch2\"/>")
        let publication = try EPUBPublication.open(data: EPUBFixture.archive([
            ("META-INF/container.xml", EPUBFixture.container), ("OEBPS/content.opf", package), ("OEBPS/nav.xhtml", EPUBFixture.nav),
            ("OEBPS/ch1.xhtml", EPUBFixture.chapter(opening + paragraphs(16, seed: "a"), title: "One")),
            ("OEBPS/ch2.xhtml", EPUBFixture.chapter("<h1>Second</h1>" + paragraphs(10, seed: "b"), title: "Two"))
        ]))
        let size = CGSize(width: Self.pageSize.width - 2 * EPUBPageView.margin, height: Self.pageSize.height - 2 * EPUBPageView.margin)
        let session = EPUBReaderSession(publication: publication, settings: EPUBReadingSettings(), contentSize: size, allowsTwoColumns: false, mediaContext: .default)
        session.go(to: .spine(0))
        return session
    }

    /// Stands in for the reader controller: turns the session's page and shows it in the view.
    private final class Reader: EPUBPageViewDelegate {
        let session: EPUBReaderSession
        let view = EPUBPageView(frame: CGRect(origin: .zero, size: EPUBPageItemTests.pageSize))
        var controlsHidden = false
        var activated: [Int] = []
        var posted: [(notification: UIAccessibility.Notification, argument: Any?)] = []

        init(session: EPUBReaderSession) {
            self.session = session
            view.delegate = self
            view.focusedElement = { nil }
            view.postAccessibilityNotification = { [unowned self] in posted.append(($0, $1)) }
            show()
        }

        func show() {
            guard let placement = session.placement else { return }
            view.show(session.layout(placement.spineIndex), page: placement.pageIndex, spineIndex: placement.spineIndex, chapter: session.chapter(placement.spineIndex)?.text, title: "Title")
        }

        var pageCount: Int { session.placement.flatMap { session.layout($0.spineIndex)?.pageCount } ?? 0 }

        func pageView(_ view: EPUBPageView, turnPage forward: Bool) -> Bool {
            guard forward ? session.forward() : session.backward() else { return false }
            show()
            return true
        }
        func pageViewPageDescription(_ view: EPUBPageView) -> String { "Page \((session.placement?.pageIndex ?? 0) + 1) of \(pageCount)" }
        func pageView(_ view: EPUBPageView, activateLinkAt offset: Int) -> Bool { activated.append(offset); return true }
        func pageViewPageStatus(_ view: EPUBPageView) -> String { "\((session.placement?.pageIndex ?? 0) + 1) of \(pageCount)" }
        func pageViewControlsHidden(_ view: EPUBPageView) -> Bool { controlsHidden }
        func pageViewToggleControls(_ view: EPUBPageView) { controlsHidden.toggle() }
        func pageView(_ view: EPUBPageView, headingBeyondPage forward: Bool) -> EPUBPageItemElement? { nil }
    }

    /// VoiceOver's order through the page view: the item group opened up, neighbours around it.
    private func exposed(_ view: EPUBPageView) -> [EPUBPageItemElement] {
        (view.accessibilityElements ?? []).flatMap { element -> [EPUBPageItemElement] in
            if let group = element as? UIView, group === view.itemGroup { return (group.accessibilityElements ?? []).compactMap { $0 as? EPUBPageItemElement } }
            return (element as? EPUBPageItemElement).map { [$0] } ?? []
        }
    }

    // MARK: The items of a page

    func testAPageSplitsItsTextAtHeadingsLinksAndImagesAndLeavesNoReadableTextOut() throws {
        let session = try session()
        let layout = try XCTUnwrap(session.layout(0))
        let chapter = try XCTUnwrap(session.chapter(0)).text
        let items = EPUBPageItems.items(layout: layout, chapter: chapter, page: 0)
        let kinds = items.prefix(6).map(\.kind)
        XCTAssertEqual(kinds, [.heading(level: 1), .text, .link(isNote: false), .text, .image(label: "one dot"), .text])
        XCTAssertEqual(chapter.text(in: items[0].range), "Opening")
        XCTAssertEqual(chapter.text(in: items[2].range), "go to two")
        XCTAssertTrue(chapter.text(in: items[1].range).hasPrefix("Before the link"))
        XCTAssertTrue(chapter.text(in: items[3].range).hasPrefix(" and after the link") || chapter.text(in: items[3].range).hasPrefix("and after the link"))
        // Every readable character of the page belongs to exactly one item, in order.
        let page = layout.table.pages[0].range
        var covered = IndexSet()
        var previousEnd = page.location
        for item in items {
            XCTAssertGreaterThanOrEqual(item.range.location, previousEnd, "Items are in reading order and do not overlap")
            previousEnd = item.range.location + item.range.length
            covered.insert(integersIn: item.range.location..<previousEnd)
        }
        let text = chapter.text(in: page) as NSString
        for index in 0..<text.length where !(text.substring(with: NSRange(location: index, length: 1)).allSatisfy { $0.isWhitespace || $0 == "\u{FFFC}" }) {
            XCTAssertTrue(covered.contains(page.location + index), "Readable character at \(page.location + index) is in an item")
        }
    }

    /// Settings, Accessibility, Paragraph by Paragraph: each paragraph's part of the page is its own
    /// item, and together they read exactly the text the Page by Page items read.
    func testParagraphByParagraphMakesEachParagraphOnThePageItsOwnItem() throws {
        let session = try session()
        let layout = try XCTUnwrap(session.layout(0))
        let chapter = try XCTUnwrap(session.chapter(0)).text
        let byPage = EPUBPageItems.items(layout: layout, chapter: chapter, page: 0)
        let byParagraph = EPUBPageItems.items(layout: layout, chapter: chapter, page: 0, byParagraph: true)
        func blocks(touchedBy item: EPUBPageItem) -> Int {
            chapter.blocks.filter { NSIntersectionRange($0.range, item.range).length > 0 }.count
        }
        let pageRun = try XCTUnwrap(byPage.last { $0.kind == .text })
        XCTAssertGreaterThan(blocks(touchedBy: pageRun), 1, "Page by Page reads the text after the image as one item over several paragraphs")
        let texts = byParagraph.filter { $0.kind == .text }
        XCTAssertGreaterThan(texts.count, byPage.filter { $0.kind == .text }.count)
        for item in texts {
            XCTAssertEqual(blocks(touchedBy: item), 1, "\"\(chapter.text(in: item.range).prefix(40))\" stays inside one paragraph")
        }
        XCTAssertTrue(chapter.text(in: try XCTUnwrap(texts.last { chapter.text(in: $0.range).hasPrefix("After the image") }).range).hasPrefix("After the image"))
        func covered(_ items: [EPUBPageItem]) -> IndexSet {
            items.reduce(into: IndexSet()) { set, item in
                for line in item.lines { set.insert(integersIn: line.range.location..<(line.range.location + line.range.length)) }
            }
        }
        // The breaks between paragraphs belong to no paragraph, so only white space may go missing.
        let string = layout.string.string as NSString
        let missing = covered(byPage).subtracting(covered(byParagraph))
        let added = covered(byParagraph).subtracting(covered(byPage))
        XCTAssertTrue(added.isEmpty, "Splitting by paragraph adds no text")
        let missingText = missing.map { string.substring(with: NSRange(location: $0, length: 1)) }
        XCTAssertTrue(missingText.allSatisfy { $0.allSatisfy(\.isWhitespace) },
                      "Splitting by paragraph drops only white space, not \(missingText.map { $0.debugDescription })")
        XCTAssertEqual(byParagraph.filter { $0.kind != .text }.map(\.kind), byPage.filter { $0.kind != .text }.map(\.kind),
                       "Headings, links and images are the same items either way")
    }

    func testATextItemReadsLineByLineAndFindsTheLineUnderAPoint() throws {
        let reader = Reader(session: try session())
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.pageSize))
        window.addSubview(reader.view)
        window.isHidden = false
        defer { window.isHidden = true }
        let text = try XCTUnwrap(reader.view.items.last { $0.item.kind == .text })
        let chapter = try XCTUnwrap(reader.session.chapter(0)).text
        XCTAssertGreaterThan(text.item.lines.count, 2, "The fixture's last text item wraps over several lines")
        let layout = try XCTUnwrap(reader.session.layout(0))
        let tableLines = layout.table.lineFrames(onPage: 0).map { layout.table.lines[$0.line].range }
        for (number, line) in text.item.lines.enumerated() {
            XCTAssertEqual(text.accessibilityContent(forLineNumber: number), chapter.text(in: line.range), "Line \(number) speaks its own text")
            XCTAssertTrue(tableLines.contains { NSIntersectionRange($0, line.range) == line.range }, "Line \(number) lies within one laid-out line")
            let frame = text.accessibilityFrame(forLineNumber: number)
            XCTAssertFalse(frame.isEmpty)
            XCTAssertEqual(text.accessibilityLineNumber(for: CGPoint(x: frame.midX, y: frame.midY)), number, "Touching line \(number) finds it")
        }
        XCTAssertNil(text.accessibilityContent(forLineNumber: text.item.lines.count))
        XCTAssertEqual(text.accessibilityPageContent(), chapter.text(in: text.item.range))
        XCTAssertEqual(text.accessibilityLineNumber(for: CGPoint(x: -100, y: -100)), NSNotFound)
    }

    func testOnlyTheShownPagesItemsAreExposedAndOnlyTheLastTurnsThePage() throws {
        let reader = Reader(session: try session())
        reader.session.show(EPUBPlacement(spineIndex: 0, pageIndex: 1))
        reader.show()
        let page = try XCTUnwrap(reader.session.layout(0)).table.pages[1].range
        let elements = exposed(reader.view)
        XCTAssertEqual(reader.view.accessibilityElements?.count, 1, "Nothing but the page's group")
        XCTAssertEqual(elements.count, reader.view.itemGroup.accessibilityElements?.count, "Nothing but the page's items in it")
        XCTAssertEqual(reader.view.itemGroup.accessibilityContainerType, .semanticGroup)
        XCTAssertEqual(reader.view.itemGroup.accessibilityLabel, "Title")
        XCTAssertFalse(elements.isEmpty)
        for element in elements {
            XCTAssertEqual(NSIntersectionRange(element.item.range, page), element.item.range, "Every exposed item lies on the shown page")
        }
        XCTAssertTrue(elements.first?.item.range.location ?? -1 >= page.location)
        XCTAssertEqual(elements.filter { $0.accessibilityTraits.contains(.causesPageTurn) }.count, 1)
        XCTAssertTrue(try XCTUnwrap(elements.last).accessibilityTraits.contains(.causesPageTurn))
        XCTAssertTrue(reader.view.focusElement as AnyObject === elements.first, "Focus after a jump goes to the page's first item")
    }

    // MARK: Turning

    func testAPageTurnKeepsTheElementVoiceOverHoldsAsTheNewPagesFirstItem() throws {
        let reader = Reader(session: try session())
        let held = try XCTUnwrap(exposed(reader.view).last)
        reader.view.focusedElement = { held }
        XCTAssertTrue(held.accessibilityScroll(.next), "The last item's page turn reaches the reader")
        XCTAssertEqual(reader.session.placement, EPUBPlacement(spineIndex: 0, pageIndex: 1))
        let first = try XCTUnwrap(exposed(reader.view).first)
        XCTAssertTrue(first === held, "The element VoiceOver holds is the new page's first, so reading goes on from its top")
        let page = try XCTUnwrap(reader.session.layout(0)).table.pages[1]
        XCTAssertEqual(held.item.range.location, try XCTUnwrap(EPUBPageItems.items(layout: try XCTUnwrap(reader.session.layout(0)), chapter: try XCTUnwrap(reader.session.chapter(0)).text, page: 1).first).range.location)
        XCTAssertGreaterThanOrEqual(held.item.range.location, page.firstOffset)
        XCTAssertEqual(reader.posted.last?.notification, .pageScrolled)
        XCTAssertEqual(reader.posted.last?.argument as? String, "Page 2 of \(reader.pageCount)")
    }

    func testThePageTurnRunsOnIntoTheNextChapterAndStopsAtTheBooksEnd() throws {
        let reader = Reader(session: try session())
        let lastPage = try XCTUnwrap(reader.session.layout(0)).pageCount - 1
        reader.session.show(EPUBPlacement(spineIndex: 0, pageIndex: lastPage))
        reader.show()
        XCTAssertTrue(try XCTUnwrap(exposed(reader.view).last).accessibilityScroll(.next))
        XCTAssertEqual(reader.session.placement, EPUBPlacement(spineIndex: 1, pageIndex: 0))
        XCTAssertEqual(exposed(reader.view).first?.item.kind, .heading(level: 1), "The next chapter opens at its heading")
        let end = try XCTUnwrap(reader.session.layout(1)).pageCount - 1
        reader.session.show(EPUBPlacement(spineIndex: 1, pageIndex: end))
        reader.show()
        reader.posted.removeAll()
        XCTAssertFalse(try XCTUnwrap(exposed(reader.view).last).accessibilityScroll(.next), "Nothing to turn to at the book's end")
        XCTAssertTrue(reader.posted.isEmpty)
    }

    // MARK: One-finger swipes stay within the page

    func testOneFingerSwipesStopAtThePagesEdgeWhateverFocusDoes() throws {
        let reader = Reader(session: try session())
        reader.session.show(EPUBPlacement(spineIndex: 0, pageIndex: 1))
        reader.show()
        let inside = try XCTUnwrap(exposed(reader.view).first)
        reader.view.focusedElement = { inside }
        // Focus arriving in the page, and a page turn under it, change nothing about the list's extent.
        XCTAssertEqual(reader.view.accessibilityElements?.count, 1)
        XCTAssertTrue(try XCTUnwrap(exposed(reader.view).last).accessibilityScroll(.next))
        XCTAssertEqual(reader.session.placement?.pageIndex, 2)
        let after = exposed(reader.view)
        XCTAssertEqual(reader.view.accessibilityElements?.count, 1, "Only the page's container is listed, so a swipe past its edge leaves the book")
        XCTAssertEqual(after.count, reader.view.itemGroup.accessibilityElements?.count)
        let page = try XCTUnwrap(reader.session.layout(0)).table.pages[2].range
        for element in after { XCTAssertEqual(NSIntersectionRange(element.item.range, page), element.item.range, "No element stands for another page") }
    }

    // MARK: Controls, status, links and headings

    func testEveryItemCarriesTheControlsAsActionsAndThePageStatusAsContent() throws {
        let reader = Reader(session: try session())
        let item = try XCTUnwrap(exposed(reader.view).first)
        XCTAssertEqual(item.accessibilityCustomActions?.map(\.name), ["Hide controls", "Next page", "Previous page"])
        XCTAssertTrue(item.accessibilityPerformMagicTap())
        XCTAssertTrue(reader.controlsHidden)
        XCTAssertEqual(item.accessibilityCustomActions?.first?.name, "Show controls")
        let next = try XCTUnwrap(item.accessibilityCustomActions?.first { $0.name == "Next page" })
        XCTAssertTrue(next.actionHandler?(next) ?? false)
        XCTAssertEqual(reader.session.placement?.pageIndex, 1)
        let content = try XCTUnwrap(exposed(reader.view).first?.accessibilityCustomContent)
        XCTAssertEqual(content.first?.label, "Page")
        XCTAssertEqual(content.first?.value, "2 of \(reader.pageCount)")
        XCTAssertEqual(content.last?.value, "Title")
    }

    func testALinkItemOpensItsLinkAndTheHeadingsRotorFindsTheHeadingOnThePage() throws {
        let reader = Reader(session: try session())
        let elements = exposed(reader.view)
        let link = try XCTUnwrap(elements.first { $0.item.kind == .link(isNote: false) })
        XCTAssertTrue(link.accessibilityTraits.contains(.link))
        XCTAssertTrue(link.accessibilityActivate())
        XCTAssertEqual(reader.activated, [link.item.range.location])
        let rotor = try XCTUnwrap(link.accessibilityCustomRotors?.first)
        XCTAssertEqual(rotor.systemRotorType, .heading)
        let predicate = UIAccessibilityCustomRotorSearchPredicate()
        predicate.searchDirection = .previous
        predicate.currentItem = UIAccessibilityCustomRotorItemResult(targetElement: link, targetRange: nil)
        let found = try XCTUnwrap(rotor.itemSearchBlock(predicate)?.targetElement as? EPUBPageItemElement)
        XCTAssertEqual(found.item.kind, .heading(level: 1))
        XCTAssertTrue(found.accessibilityTraits.contains(.header))
    }
}
