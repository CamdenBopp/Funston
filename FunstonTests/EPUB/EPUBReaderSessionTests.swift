import XCTest
@testable import Funston

/// Spec section 13 without views: navigation, page turns across chapters,
/// links and notes, relocation reports, relayout anchoring, the window.
@MainActor
final class EPUBReaderSessionTests: XCTestCase {
    private func longParagraphs(_ count: Int, seed: String) -> String {
        (0..<count).map { "<p id=\"\(seed)\($0)\">" + String(repeating: "\(seed) paragraph \($0) keeps going so pages fill up. ", count: 6) + "</p>" }.joined()
    }

    private func book() throws -> EPUBReaderSession {
        let nav = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head>
        <body><nav epub:type="toc"><ol><li><a href="ch1.xhtml">One</a><ol><li><a href="ch1.xhtml#a12">One, later</a></li></ol></li><li><a href="ch2.xhtml">Two</a></li><li><a href="sub/ch3.xhtml">Three</a></li></ol></nav>
        <nav epub:type="landmarks"><ol><li><a epub:type="bodymatter" href="ch1.xhtml">Start</a></li></ol></nav></body></html>
        """
        let one = EPUBFixture.chapter(longParagraphs(30, seed: "a") + "<p>See <a href=\"ch2.xhtml#n1\">chapter two</a> and <a href=\"#fn1\" epub:type=\"noteref\" id=\"r1\">1</a> and <a href=\"https://example.org/\">outside</a> and <a href=\"#nowhere\">nowhere</a>.</p><aside epub:type=\"footnote\" id=\"fn1\"><p>The note text.</p><p><a href=\"#r1\" epub:type=\"backlink\">Back</a></p></aside>", title: "One")
        let two = EPUBFixture.chapter("<p id=\"n1\">Two starts.</p>" + longParagraphs(8, seed: "b"), title: "Two")
        let three = EPUBFixture.chapter(longParagraphs(5, seed: "c"), title: "Three")
        let package = EPUBFixture.package(extraManifest: "<item id=\"ch2\" href=\"ch2.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"extra\" href=\"extra.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"ch3\" href=\"sub/ch3.xhtml\" media-type=\"application/xhtml+xml\"/>",
                                          spineExtra: "<itemref idref=\"ch2\"/><itemref idref=\"extra\" linear=\"no\"/><itemref idref=\"ch3\"/>")
        let publication = try EPUBPublication.open(data: EPUBFixture.archive([
            ("META-INF/container.xml", EPUBFixture.container), ("OEBPS/content.opf", package), ("OEBPS/nav.xhtml", nav),
            ("OEBPS/ch1.xhtml", one), ("OEBPS/ch2.xhtml", two), ("OEBPS/extra.xhtml", EPUBFixture.chapter("<p>Extra</p>")), ("OEBPS/sub/ch3.xhtml", three)
        ]))
        return EPUBReaderSession(publication: publication, settings: EPUBReadingSettings(), contentSize: CGSize(width: 320, height: 480), allowsTwoColumns: false, mediaContext: .default)
    }

    func testReadableSpineSkipsNonLinearItemsAndTurnsCrossChaptersAndStopAtTheEnds() throws {
        let session = try book()
        XCTAssertEqual(session.readableSpine, [0, 1, 3])
        XCTAssertNotNil(session.go(to: .spine(0)))
        XCTAssertFalse(session.backward(), "The book's start does not move")
        XCTAssertEqual(session.placement, EPUBPlacement(spineIndex: 0, pageIndex: 0))
        let pages = try XCTUnwrap(session.layout(0)).pageCount
        XCTAssertGreaterThan(pages, 2)
        for _ in 0..<pages { XCTAssertTrue(session.forward()) }
        XCTAssertEqual(session.placement, EPUBPlacement(spineIndex: 1, pageIndex: 0), "Past the last page the next linear chapter begins")
        XCTAssertTrue(session.backward())
        XCTAssertEqual(session.placement, EPUBPlacement(spineIndex: 0, pageIndex: pages - 1))
        XCTAssertNotNil(session.go(to: .spine(3)))
        let last = try XCTUnwrap(session.layout(3)).pageCount
        for _ in 1..<last { XCTAssertTrue(session.forward()) }
        XCTAssertFalse(session.forward(), "The book's end does not move")
        XCTAssertEqual(session.relocation()?.atEnd, true)
        XCTAssertNil(session.go(to: .spine(2)), "A non-linear item is not a destination")
    }

    func testGoToTargetsFragmentsOffsetsFractionsAndLocations() throws {
        let session = try book()
        let chapter = try XCTUnwrap(session.chapter(0))
        let anchor = try XCTUnwrap(chapter.text.anchors["a12"])
        let placement = try XCTUnwrap(session.go(to: .target(EPUBTarget(spineIndex: 0, fragment: "a12"))))
        let layout = try XCTUnwrap(session.layout(0))
        XCTAssertEqual(placement.pageIndex, layout.table.pageIndex(containing: anchor))
        XCTAssertGreaterThan(placement.pageIndex, 0)
        XCTAssertEqual(session.go(to: .target(EPUBTarget(spineIndex: 0, fragment: "nowhere")))?.pageIndex, 0, "A missing fragment lands at the start")
        XCTAssertTrue(session.diagnostics.contains(code: "link.fragmentMissing"))
        XCTAssertEqual(session.go(to: .offset(spineIndex: 0, offset: anchor)), placement)
        XCTAssertEqual(session.go(to: .fraction(0))?.spineIndex, 0)
        XCTAssertEqual(session.go(to: .fraction(1))?.spineIndex, 3)
        XCTAssertEqual(session.go(to: .location(1)), EPUBPlacement(spineIndex: 0, pageIndex: 0))
        XCTAssertEqual(session.go(to: .location(session.scale.totalLocations))?.spineIndex, 3)
    }

    func testRelocationReportsCarryContentsEntryPageCountsAndChangeOnlyWhenTheViewMoves() throws {
        let session = try book()
        session.go(to: .spine(0))
        let first = try XCTUnwrap(session.relocationIfChanged())
        XCTAssertEqual(first.pageIndex, 0); XCTAssertGreaterThan(first.pageCount, 1); XCTAssertTrue(first.atStart); XCTAssertFalse(first.atEnd)
        XCTAssertEqual(first.contentsEntry?.label, "One")
        XCTAssertEqual(first.location, 1); XCTAssertEqual(first.totalLocations, session.scale.totalLocations)
        XCTAssertEqual(first.locator.href, "OEBPS/ch1.xhtml"); XCTAssertEqual(first.locator.title, "One")
        XCTAssertNil(session.relocationIfChanged(), "The same view reports once")
        session.go(to: .target(EPUBTarget(spineIndex: 0, fragment: "a12")))
        let later = try XCTUnwrap(session.relocationIfChanged())
        XCTAssertEqual(later.contentsEntry?.label, "One, later", "The deepest entry at or before the page wins")
        XCTAssertEqual(later.visibleRange.location, later.locator.offset)
        session.go(to: .spine(3))
        XCTAssertEqual(session.relocationIfChanged()?.contentsEntry?.label, "Three")
    }

    func testContinuousMovesWithinOnePageStillReportTheNewPosition() throws {
        let session = try book()
        session.go(to: .spine(0))
        XCTAssertNotNil(session.relocationIfChanged())
        let page = try XCTUnwrap(session.layout(0)).table.pages[0]
        session.show(visibleOffset: page.firstOffset + page.range.length / 2, spineIndex: 0)
        let moved = try XCTUnwrap(session.relocationIfChanged(), "Reading on within a page is a new position")
        XCTAssertEqual(moved.pageIndex, 0)
        XCTAssertEqual(moved.locator.offset, page.firstOffset + page.range.length / 2)
        XCTAssertNil(session.relocationIfChanged(), "The same position reports once")
    }

    func testLinksNotesAndTheBackStack() throws {
        let session = try book()
        let chapter = try XCTUnwrap(session.chapter(0))
        let linkBlock = try XCTUnwrap(chapter.text.blocks.first { !$0.links.isEmpty })
        let internalLink = try XCTUnwrap(session.link(at: linkBlock.links[0].range.location, spineIndex: 0))
        XCTAssertEqual(internalLink.target, .internalLink(path: "OEBPS/ch2.xhtml", fragment: "n1", spineIndex: 1)); XCTAssertFalse(internalLink.isNoteReference)
        let note = try XCTUnwrap(session.link(at: linkBlock.links[1].range.location, spineIndex: 0))
        XCTAssertTrue(note.isNoteReference)
        let body = try XCTUnwrap(session.noteBody(for: note.target))
        XCTAssertTrue(body.text.hasPrefix("The note text."))
        XCTAssertEqual(body.blocks.count, 2)
        XCTAssertEqual(body.backlink, .internalLink(path: "OEBPS/ch1.xhtml", fragment: "r1", spineIndex: 0))
        XCTAssertEqual(session.link(at: linkBlock.links[2].range.location, spineIndex: 0)?.target, .external(URL(string: "https://example.org/")!))
        XCTAssertNil(session.link(at: linkBlock.range.location, spineIndex: 0), "Plain text is not a link")
        session.go(to: .spine(0))
        guard case .internalLink(_, let fragment, let spineIndex?) = internalLink.target else { return XCTFail("internal") }
        let arrived = try XCTUnwrap(session.go(to: .target(EPUBTarget(spineIndex: spineIndex, fragment: fragment)), recordingDeparture: true))
        XCTAssertEqual(arrived.spineIndex, 1)
        XCTAssertEqual(session.backStack.count, 1)
        XCTAssertEqual(session.goBack(), EPUBPlacement(spineIndex: 0, pageIndex: 0))
        XCTAssertTrue(session.backStack.isEmpty)
        XCTAssertNil(session.goBack())
    }

    func testRelayoutKeepsTheAnchoredOffsetInView() throws {
        let session = try book()
        let chapter = try XCTUnwrap(session.chapter(0))
        let anchor = try XCTUnwrap(chapter.text.anchors["a12"])
        session.go(to: .target(EPUBTarget(spineIndex: 0, fragment: "a12")))
        let before = try XCTUnwrap(session.placement)
        var larger = EPUBReadingSettings(); larger.baseFontSize = 26
        session.update(settings: larger)
        let after = try XCTUnwrap(session.placement)
        XCTAssertEqual(after.spineIndex, 0)
        XCTAssertNotEqual(after.pageIndex, before.pageIndex, "Bigger text means more pages before the anchor")
        let layout = try XCTUnwrap(session.layout(0))
        XCTAssertTrue(NSLocationInRange(anchor, layout.table.pages[after.pageIndex].range), "The page shown contains the anchored offset")
        session.update(contentSize: CGSize(width: 600, height: 900))
        let rotated = try XCTUnwrap(session.placement)
        XCTAssertTrue(NSLocationInRange(anchor, try XCTUnwrap(session.layout(0)).table.pages[rotated.pageIndex].range))
    }

    func testTheWindowHoldsThreeChaptersAndPrefetchesTheNeighbourNearABoundary() throws {
        let session = try book()
        session.go(to: .spine(0))
        XCTAssertNil(session.neighbourToPrefetch(), "Far from the boundary nothing is prefetched")
        let pages = try XCTUnwrap(session.layout(0)).pageCount
        session.show(page: pages - 1)
        XCTAssertEqual(session.neighbourToPrefetch(), 1)
        _ = session.layout(1)
        XCTAssertNil(session.neighbourToPrefetch(), "Once resident it is not asked for again")
        session.go(to: .spine(3))
        XCTAssertLessThanOrEqual(session.cache.resident.count, EPUBLayoutCache.residentLimit)
        XCTAssertNil(session.cache.session(spineIndex: 0, key: session.layoutKey), "Chapter one left the window")
        session.shed()
        XCTAssertEqual(session.cache.resident.map(\.spineIndex), [3])
    }

    func testPartialLayoutsCompleteInTheBackground() async throws {
        let session = try book()
        let long = EPUBFixture.chapter(longParagraphs(400, seed: "z"), title: "Long")
        let publication = try EPUBPublication.open(data: EPUBFixture.archive([
            ("META-INF/container.xml", EPUBFixture.container), ("OEBPS/content.opf", EPUBFixture.package()), ("OEBPS/nav.xhtml", EPUBFixture.nav), ("OEBPS/ch1.xhtml", long)
        ]))
        let longSession = EPUBReaderSession(publication: publication, settings: EPUBReadingSettings(), contentSize: CGSize(width: 320, height: 480), allowsTwoColumns: false, mediaContext: .default)
        let text = try XCTUnwrap(longSession.chapter(0)).text
        XCTAssertGreaterThan(text.length, EPUBLayoutSession.twoPassThreshold)
        let first = try XCTUnwrap(longSession.layout(0, extent: .firstPage))
        XCTAssertTrue(first.isPartial); XCTAssertEqual(first.pageCount, 1)
        await longSession.completeLayout(0)
        let whole = try XCTUnwrap(longSession.cache.session(spineIndex: 0, key: longSession.layoutKey))
        XCTAssertFalse(whole.isPartial); XCTAssertGreaterThan(whole.pageCount, 10)
        XCTAssertEqual(whole.table.pages[0], first.table.pages[0])
        _ = session
    }
}
