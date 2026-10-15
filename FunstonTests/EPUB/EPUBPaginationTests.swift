import UIKit
import XCTest
@testable import Funston

/// Spec section 11: the cut rules over a line table, and the TextKit 2
/// layout session against the Apple study's fixtures (section 9.3).
final class EPUBPaginationTests: XCTestCase {
    private let lineHeight: CGFloat = 20

    /// Lines of equal height, `paragraphs` giving the line count of each paragraph.
    private func lines(paragraphs: [Int], forcedBefore: Set<Int> = [], keep: Set<Int> = []) -> [EPUBLineRecord] {
        var result: [EPUBLineRecord] = []
        var offset = 0
        for (paragraph, count) in paragraphs.enumerated() {
            for lineInParagraph in 0..<count {
                let index = result.count
                result.append(EPUBLineRecord(range: NSRange(location: offset, length: 10), frame: CGRect(x: 0, y: CGFloat(index) * lineHeight, width: 300, height: lineHeight),
                                             fragmentIndex: paragraph, forcesBreakBefore: forcedBefore.contains(paragraph) && lineInParagraph == 0,
                                             keepsTogether: keep.contains(paragraph)))
                offset += 10
            }
        }
        return result
    }

    private func geometry(height: CGFloat, width: CGFloat = 360, base: CGFloat = 17, twoColumns: Bool = false) -> EPUBPageGeometry {
        EPUBPageGeometry(contentSize: CGSize(width: width, height: height), baseFontSize: base, allowsTwoColumns: twoColumns)
    }

    func testEveryLineBelongsToExactlyOnePageAndCutsFallWhereALineWouldCross() {
        let table = EPUBPageTable.paginate(lines: lines(paragraphs: [12]), geometry: geometry(height: 5 * lineHeight))
        XCTAssertEqual(table.pages.count, 3)
        XCTAssertEqual(table.pages.map { $0.columns[0].firstLine }, [0, 5, 10])
        XCTAssertEqual(table.pages.map { $0.columns[0].lastLine }, [4, 9, 11])
        XCTAssertEqual(table.pages.map(\.firstOffset), [0, 50, 100])
        XCTAssertEqual(table.pages.last?.endOffset, 120)
        XCTAssertEqual(table.pageIndex(containing: 0), 0); XCTAssertEqual(table.pageIndex(containing: 49), 0); XCTAssertEqual(table.pageIndex(containing: 50), 1); XCTAssertEqual(table.pageIndex(containing: 119), 2)
        XCTAssertEqual(table.pages[1].columns[0].top, 5 * lineHeight)
        let covered = table.pages.flatMap { $0.columns.flatMap { Array($0.lineRange) } }
        XCTAssertEqual(covered, Array(0..<12))
    }

    func testWidowAndOrphanControlMovesTheCutUpByAtMostTwoLines() {
        // Page holds 5 lines; paragraph of 4 lines starts at line 4: line 4 alone at the bottom is an orphan.
        let orphan = EPUBPageTable.paginate(lines: lines(paragraphs: [4, 4]), geometry: geometry(height: 5 * lineHeight))
        XCTAssertEqual(orphan.pages[0].columns[0].lastLine, 3, "The cut moves up so the paragraph starts on the next page")
        // Page holds 5 lines; a 2-line paragraph then a 4-line paragraph: line 5 (last line of paragraph 2) would be a widow.
        let widow = EPUBPageTable.paginate(lines: lines(paragraphs: [2, 4]), geometry: geometry(height: 5 * lineHeight))
        XCTAssertEqual(widow.pages[0].columns[0].lastLine, 3, "Two lines of the paragraph move together")
        // A 3-line paragraph can never split two and two, so it moves whole: the cut moves up two lines and no further.
        let threes = EPUBPageTable.paginate(lines: lines(paragraphs: [3, 3, 3, 3]), geometry: geometry(height: 5 * lineHeight))
        XCTAssertEqual(threes.pages.map { $0.columns[0].firstLine }, [0, 3, 6, 9])
        // A paragraph that would split two and two stays split.
        let even = EPUBPageTable.paginate(lines: lines(paragraphs: [3, 4]), geometry: geometry(height: 5 * lineHeight))
        XCTAssertEqual(even.pages[0].columns[0].lastLine, 4)
        // A long paragraph straddling the page needs no adjustment.
        let long = EPUBPageTable.paginate(lines: lines(paragraphs: [12]), geometry: geometry(height: 5 * lineHeight))
        XCTAssertEqual(long.pages.map { $0.columns[0].firstLine }, [0, 5, 10])
    }

    func testForcedBreaksAlwaysCutAndKeepTogetherMovesTheBlockWhole() {
        let forced = EPUBPageTable.paginate(lines: lines(paragraphs: [2, 2, 2], forcedBefore: [1, 2]), geometry: geometry(height: 10 * lineHeight))
        XCTAssertEqual(forced.pages.count, 3)
        XCTAssertEqual(forced.pages.map { $0.columns[0].firstLine }, [0, 2, 4])
        let kept = EPUBPageTable.paginate(lines: lines(paragraphs: [3, 4], keep: [1]), geometry: geometry(height: 5 * lineHeight))
        XCTAssertEqual(kept.pages[0].columns[0].lastLine, 2, "The kept block moves whole to the next page")
        XCTAssertEqual(kept.pages[1].columns[0].firstLine, 3)
        let tooLong = EPUBPageTable.paginate(lines: lines(paragraphs: [2, 9], keep: [1]), geometry: geometry(height: 5 * lineHeight))
        XCTAssertEqual(tooLong.pages[0].columns[0].lastLine, 4, "A block longer than a page breaks naturally")
    }

    func testALineTallerThanThePageGetsAPageOfItsOwn() {
        var records = lines(paragraphs: [1, 1, 1])
        records[1] = EPUBLineRecord(range: records[1].range, frame: CGRect(x: 0, y: lineHeight, width: 300, height: 8 * lineHeight), fragmentIndex: 1, forcesBreakBefore: false, keepsTogether: false)
        records[2] = EPUBLineRecord(range: records[2].range, frame: CGRect(x: 0, y: 9 * lineHeight, width: 300, height: lineHeight), fragmentIndex: 2, forcesBreakBefore: false, keepsTogether: false)
        let table = EPUBPageTable.paginate(lines: records, geometry: geometry(height: 5 * lineHeight))
        XCTAssertEqual(table.pages.map { $0.columns[0].firstLine }, [0, 1, 2])
    }

    func testTwoColumnGeometryAndPagesOfTwoCuts() {
        let wide = geometry(height: 5 * lineHeight, width: 1500, base: 17, twoColumns: true)
        XCTAssertEqual(wide.columnCount, 2)
        XCTAssertEqual(wide.columnWidth, 40 * 17, "Line length is capped at 40 base sizes")
        XCTAssertEqual(wide.columnGap, 34)
        XCTAssertEqual(wide.columnOrigin(0), (1500 - (680 * 2 + 34)) / 2, accuracy: 0.01)
        let tight = geometry(height: 5 * lineHeight, width: 1100, base: 17, twoColumns: true)
        XCTAssertEqual(tight.columnCount, 2)
        XCTAssertEqual(tight.columnWidth, (1100 - 34) / 2, accuracy: 0.01, "Narrower surfaces share the width")
        XCTAssertEqual(wide.columnOrigin(1), wide.columnOrigin(0) + 680 + 34, accuracy: 0.01)
        let narrow = geometry(height: 600, width: 360, twoColumns: true)
        XCTAssertEqual(narrow.columnCount, 1); XCTAssertEqual(narrow.columnWidth, 360)
        let table = EPUBPageTable.paginate(lines: lines(paragraphs: [15]), geometry: wide)
        XCTAssertEqual(table.pages.count, 2)
        XCTAssertEqual(table.pages[0].columns.count, 2)
        XCTAssertEqual(table.pages[0].firstOffset, 0); XCTAssertEqual(table.pages[0].endOffset, 100)
        XCTAssertEqual(table.pages[1].columns.map(\.firstLine), [10])
        let frames = table.lineFrames(onPage: 0)
        XCTAssertEqual(frames.count, 10)
        XCTAssertEqual(frames[5].frame.minX, wide.columnOrigin(1), accuracy: 0.01)
        XCTAssertEqual(frames[5].frame.minY, 0, accuracy: 0.01, "The second column starts at the top")
    }

    func testLineLookupByY() {
        let table = EPUBPageTable.paginate(lines: lines(paragraphs: [3, 3]), geometry: geometry(height: 4 * lineHeight))
        let cut = table.pages[0].columns[0]
        XCTAssertEqual(table.lineIndex(in: cut, atY: 5), 0)
        XCTAssertEqual(table.lineIndex(in: cut, atY: 45), 2)
        XCTAssertNil(table.lineIndex(in: cut, atY: 300))
        let second = table.pages[1].columns[0]
        XCTAssertEqual(second.firstLine, 3, "The orphan rule moved the cut up one line")
        XCTAssertEqual(table.lineIndex(in: second, atY: 5), 3)
    }

    // MARK: TextKit 2

    private func loadedChapter(_ body: String, settings: EPUBReadingSettings = EPUBReadingSettings()) throws -> EPUBLoadedChapter {
        let markup = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body>\(body)</body></html>"
        let publication = try EPUBPublication.open(data: EPUBFixture.archive([
            ("META-INF/container.xml", EPUBFixture.container), ("OEBPS/content.opf", EPUBFixture.package()), ("OEBPS/nav.xhtml", EPUBFixture.nav), ("OEBPS/ch1.xhtml", markup)
        ]))
        let loader = EPUBChapterLoader(resources: EPUBBookResources(publication: publication), settings: settings, geometry: EPUBTextGeometry(columnWidth: 360, maximumImageHeight: 600), mediaContext: .default)
        return try XCTUnwrap(loader.load(spineIndex: 0))
    }

    private func session(_ chapter: EPUBLoadedChapter, size: CGSize = CGSize(width: 360, height: 640), settings: EPUBReadingSettings = EPUBReadingSettings()) -> EPUBLayoutSession {
        let geometry = EPUBPageGeometry(contentSize: size, baseFontSize: settings.baseFontSize, allowsTwoColumns: false)
        return EPUBLayoutSession(text: chapter.text, geometry: geometry, key: EPUBLayoutKey(contentSize: size, settings: settings, twoColumns: false), settings: settings, margins: 20)
    }

    func testLayoutSessionCoversEveryCharacterOnceInOrder() throws {
        let paragraph = "<p>" + String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 40) + "</p>"
        let chapter = try loadedChapter(String(repeating: paragraph, count: 60))
        let layout = session(chapter)
        XCTAssertGreaterThan(layout.table.lines.count, 500)
        XCTAssertGreaterThan(layout.pageCount, 10)
        var expected = 0
        for line in layout.table.lines {
            XCTAssertEqual(line.range.location, expected, "Lines are contiguous")
            expected = line.range.location + line.range.length
        }
        XCTAssertEqual(expected, chapter.text.length, "The trailing synthesised line is skipped and nothing is lost")
        for (index, page) in layout.table.pages.enumerated() {
            let cut = page.columns[0]
            let bottom = layout.table.lines[cut.lastLine].frame.maxY - cut.top
            XCTAssertLessThanOrEqual(bottom, 640.01, "page \(index) overflows")
            if index + 1 < layout.pageCount { XCTAssertEqual(layout.table.pages[index + 1].firstOffset, page.endOffset) }
        }
        XCTAssertEqual(layout.table.pages[0].columns[0].top, layout.table.lines[0].frame.minY)
    }

    func testForcedBreaksAndTallImagesInRealLayout() throws {
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 300, height: 900)).image { _ in }.pngData())
        let markup = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>one</p><h2 style=\"page-break-before: always\">Two</h2><p>text</p><div><img src=\"tall.png\" alt=\"Tall\"/></div><p>after</p></body></html>"
        var settings = EPUBReadingSettings(); settings.publisherStyles = true
        var fixture = ZipFixture([ZipFixture.Entry("mimetype", text: "application/epub+zip", deflate: false)])
        fixture.entries += [ZipFixture.Entry("META-INF/container.xml", text: EPUBFixture.container), ZipFixture.Entry("OEBPS/content.opf", text: EPUBFixture.package()), ZipFixture.Entry("OEBPS/nav.xhtml", text: EPUBFixture.nav), ZipFixture.Entry("OEBPS/ch1.xhtml", text: markup), ZipFixture.Entry("OEBPS/tall.png", png)]
        let publication = try EPUBPublication.open(data: fixture.build())
        let loader = EPUBChapterLoader(resources: EPUBBookResources(publication: publication), settings: settings, geometry: EPUBTextGeometry(columnWidth: 360, maximumImageHeight: 600), mediaContext: .default)
        let chapter = try XCTUnwrap(loader.load(spineIndex: 0))
        let layout = session(chapter, settings: settings)
        XCTAssertGreaterThanOrEqual(layout.pageCount, 3)
        let headingOffset = chapter.text.blocks[1].range.location
        XCTAssertEqual(layout.table.pages[1].firstOffset, headingOffset, "The forced break starts page two at the heading")
        let imageLine = try XCTUnwrap(layout.table.lines.first { line in NSLocationInRange(chapter.text.images[0].renderedOffset, line.range) })
        let attachment = try XCTUnwrap(layout.string.attribute(.attachment, at: chapter.text.images[0].renderedOffset, effectiveRange: nil) as? EPUBImageAttachment)
        XCTAssertEqual(attachment.bounds.size, CGSize(width: 200, height: 600), "The tall image was clamped to the page's image height, keeping its ratio")
        XCTAssertLessThan(imageLine.frame.height, 640, "The line box adds the font's descent and still fits a page")
        let pageWithImage = try XCTUnwrap(layout.table.pageIndex(containing: chapter.text.images[0].renderedOffset))
        XCTAssertEqual(layout.table.pages[pageWithImage].firstOffset, chapter.text.images[0].renderedOffset, "A near-page-high image sits on a page of its own")
    }

    func testDrawingRectanglesAndHitTestingAgreeWithTheLineTable() throws {
        let chapter = try loadedChapter("<p>Hello world of text that wraps across a few lines when the column is narrow enough to need it, yes.</p><p>Second paragraph.</p>")
        let layout = session(chapter, size: CGSize(width: 200, height: 400))
        XCTAssertEqual(layout.pageCount, 1)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 400))
        let image = renderer.image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 400))
            layout.draw(page: 0, in: context.cgContext)
        }
        let pixels = try XCTUnwrap(image.cgImage)
        XCTAssertTrue(hasDarkPixel(pixels), "Drawing a page paints glyphs")
        let secondBlock = chapter.text.blocks[1].range
        let rectangles = layout.rectangles(for: secondBlock, onPage: 0)
        XCTAssertFalse(rectangles.isEmpty)
        let lineOfSecond = try XCTUnwrap(layout.table.lines.first { NSLocationInRange(secondBlock.location, $0.range) })
        XCTAssertEqual(rectangles[0].minY, lineOfSecond.frame.minY - layout.table.pages[0].columns[0].top, accuracy: 1)
        let hit = layout.characterIndex(at: CGPoint(x: 5, y: lineOfSecond.frame.midY), onPage: 0)
        XCTAssertEqual(hit, secondBlock.location)
        XCTAssertNil(layout.characterIndex(at: CGPoint(x: 5, y: 390), onPage: 0), "Empty space below the text hits nothing")
    }

    func testContinuousSurfaceDrawsOnlyTheLinesInTheRectAndHitTestsBySurfacePoint() throws {
        let chapter = try loadedChapter(String(repeating: "<p>Continuous surfaces draw tiles of lines from the same table.</p>", count: 40))
        let layout = session(chapter)
        XCTAssertEqual(layout.contentHeight, layout.table.lines.last?.frame.maxY)
        XCTAssertGreaterThan(layout.contentHeight, 640)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 200))
        let tile = CGRect(x: 0, y: 1000, width: 360, height: 200)
        let image = renderer.image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 360, height: 200))
            layout.drawLines(intersecting: tile, in: context.cgContext, origin: CGPoint(x: 0, y: -1000))
        }
        XCTAssertTrue(hasDarkPixel(try XCTUnwrap(image.cgImage)), "A tile deep in the chapter paints glyphs")
        let line = try XCTUnwrap(layout.lineIndex(atSurfaceY: 1005))
        XCTAssertTrue(layout.table.lines[line].frame.minY <= 1005 && layout.table.lines[line].frame.maxY >= 1005)
        XCTAssertEqual(layout.characterIndex(atSurfacePoint: CGPoint(x: 1, y: layout.table.lines[line].frame.midY)), layout.table.lines[line].range.location)
        let rects = layout.surfaceRectangles(for: chapter.text.blocks[20].range)
        XCTAssertFalse(rects.isEmpty)
        XCTAssertEqual(rects[0].minY, try XCTUnwrap(layout.table.lines.first { NSLocationInRange(chapter.text.blocks[20].range.location, $0.range) }).frame.minY, accuracy: 1)
    }

    func testLayoutIsDeterministicUnderTheSameKey() throws {
        let chapter = try loadedChapter(String(repeating: "<p>Determinism matters for the page table cache.</p>", count: 120))
        let first = session(chapter), second = session(chapter)
        XCTAssertEqual(first.table.pages.map(\.firstOffset), second.table.pages.map(\.firstOffset))
        var larger = EPUBReadingSettings(); larger.baseFontSize = 24
        XCTAssertNotEqual(EPUBLayoutKey(contentSize: CGSize(width: 360, height: 640), settings: EPUBReadingSettings(), twoColumns: false), EPUBLayoutKey(contentSize: CGSize(width: 360, height: 640), settings: larger, twoColumns: false))
    }

    func testFirstPagePassCutsWhereTheWholeLayoutDoes() throws {
        let chapter = try loadedChapter(String(repeating: "<p>" + String(repeating: "Partial layouts hand out the first unmeasured offset. ", count: 12) + "</p>", count: 80))
        XCTAssertGreaterThan(chapter.text.length, EPUBLayoutSession.twoPassThreshold)
        let size = CGSize(width: 360, height: 640)
        let settings = EPUBReadingSettings()
        let geometry = EPUBPageGeometry(contentSize: size, baseFontSize: settings.baseFontSize, allowsTwoColumns: false)
        let key = EPUBLayoutKey(contentSize: size, settings: settings, twoColumns: false)
        let partial = EPUBLayoutSession(text: chapter.text, geometry: geometry, key: key, settings: settings, margins: 20, extent: .firstPage)
        let whole = EPUBLayoutSession(text: chapter.text, geometry: geometry, key: key, settings: settings, margins: 20)
        XCTAssertTrue(partial.isPartial); XCTAssertFalse(whole.isPartial)
        XCTAssertEqual(partial.pageCount, 1)
        XCTAssertEqual(partial.table.pages[0], whole.table.pages[0], "The first page is the same page")
        XCTAssertEqual(partial.measuredEndOffset, whole.table.pages[1].firstOffset)
        XCTAssertLessThan(partial.table.lines.count, whole.table.lines.count, "The partial pass stops early")
        XCTAssertEqual(whole.measuredEndOffset, chapter.text.length)
    }

    func testLongChaptersSplitIntoSectionsAtParagraphBoundariesWithOneContinuousLineTable() throws {
        let chapter = try loadedChapter(String(repeating: "<p>Sections split at paragraph boundaries so the lines never change. Each one is its own TextKit stack.</p>", count: 60))
        let size = CGSize(width: 360, height: 640)
        let settings = EPUBReadingSettings()
        let geometry = EPUBPageGeometry(contentSize: size, baseFontSize: settings.baseFontSize, allowsTwoColumns: false)
        let key = EPUBLayoutKey(contentSize: size, settings: settings, twoColumns: false)
        let ranges = EPUBLayoutSession.sectionRanges(of: chapter.text.string, limit: 1000)
        XCTAssertGreaterThan(ranges.count, 3)
        for (index, range) in ranges.enumerated() {
            XCTAssertLessThanOrEqual(range.length, 1000)
            if index > 0 { XCTAssertEqual(range.location, ranges[index - 1].location + ranges[index - 1].length) }
            if index + 1 < ranges.count { XCTAssertEqual((chapter.text.string.string as NSString).substring(with: NSRange(location: range.location + range.length - 1, length: 1)), "\n", "Cuts fall after a separator") }
        }
        XCTAssertEqual(ranges.last.map { $0.location + $0.length }, chapter.text.length)
        let sectioned = EPUBLayoutSession(text: chapter.text, geometry: geometry, key: key, settings: settings, margins: 20, sectionLimit: 1000)
        let whole = EPUBLayoutSession(text: chapter.text, geometry: geometry, key: key, settings: settings, margins: 20)
        XCTAssertEqual(sectioned.table.lines.map(\.range), whole.table.lines.map(\.range), "Line breaking is per paragraph, so the sections change nothing")
        var previousBottom: CGFloat = 0
        for line in sectioned.table.lines { XCTAssertGreaterThanOrEqual(line.frame.minY, previousBottom - 0.01); previousBottom = line.frame.minY }
        XCTAssertEqual(sectioned.table.pages.map(\.firstOffset), whole.table.pages.map(\.firstOffset))
        let lastPage = sectioned.pageCount - 1
        let lastBlock = chapter.text.blocks[chapter.text.blocks.count - 1].range
        XCTAssertFalse(sectioned.rectangles(for: lastBlock, onPage: lastPage).isEmpty, "Rectangles come from the owning section")
        let lastLine = try XCTUnwrap(sectioned.table.lines.last)
        let hit = sectioned.characterIndex(at: CGPoint(x: 2, y: lastLine.frame.midY - sectioned.table.pages[lastPage].columns[0].top), onPage: lastPage)
        XCTAssertEqual(hit, lastLine.range.location)
    }

    @MainActor
    func testCacheKeepsThreeLayoutsNearestTheCurrentChapterAndRemembersPageStarts() throws {
        let chapter = try loadedChapter(String(repeating: "<p>Cache me.</p>", count: 30))
        let cache = EPUBLayoutCache()
        func make() -> EPUBLayoutSession { session(chapter) }
        for index in 0..<5 { cache.store(make(), spineIndex: index, current: 4) }
        XCTAssertEqual(cache.resident.map(\.spineIndex), [2, 3, 4])
        XCTAssertNotNil(cache.pageStarts(spineIndex: 0, key: make().key), "Page starts outlive the layout")
        XCTAssertEqual(cache.pageStarts(spineIndex: 0, key: make().key), make().table.pages.map(\.firstOffset))
        XCTAssertNil(cache.session(spineIndex: 0, key: make().key))
        XCTAssertNotNil(cache.session(spineIndex: 3, key: make().key))
        var other = EPUBReadingSettings(); other.baseFontSize = 30
        XCTAssertNil(cache.session(spineIndex: 3, key: EPUBLayoutKey(contentSize: CGSize(width: 360, height: 640), settings: other, twoColumns: false)), "A different key is a different layout")
        cache.retain(around: 3)
        XCTAssertEqual(cache.resident.map(\.spineIndex), [2, 3, 4])
        cache.retain(around: 2)
        XCTAssertEqual(cache.resident.map(\.spineIndex), [2, 3])
        cache.shed(keeping: 3)
        XCTAssertEqual(cache.resident.map(\.spineIndex), [3])
        let partial = EPUBLayoutSession(text: chapter.text, geometry: make().geometry, key: make().key, settings: EPUBReadingSettings(), margins: 20, extent: .firstPage)
        cache.store(partial, spineIndex: 3, current: 3)
        XCTAssertFalse(cache.session(spineIndex: 3, key: make().key)?.isPartial ?? true, "A whole layout is never replaced by a partial one")
        cache.store(partial, spineIndex: 5, current: 5)
        cache.store(make(), spineIndex: 5, current: 5)
        XCTAssertEqual(cache.resident.filter { $0.spineIndex == 5 }.count, 1, "The whole layout replaces the partial one")
    }

    private func hasDarkPixel(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else { return false }
        let count = CFDataGetLength(data)
        var index = 0
        while index + 3 < count {
            if pointer[index] < 100 && pointer[index + 1] < 100 && pointer[index + 2] < 100 { return true }
            index += 4 * 97
        }
        return false
    }
}
