import XCTest
@testable import Funston

/// Spec section 12.2 to 12.4: the version 2 locator, Readium rows, the
/// progress scale and the restore ladder.
final class EPUBPositionTests: XCTestCase {
    private let chapterOne = "<p id=\"p1\">The first paragraph of the first chapter has enough text to anchor a position in.</p><p id=\"p2\">The second paragraph goes on for a while so that offsets differ from the start.</p><p class=\"last\">A third paragraph ends the chapter.</p>"
    private let chapterTwo = "<p id=\"n1\">Note one</p><p>Second chapter text.</p>"
    private let chapterThree = "<p>Third chapter text that is a little longer than the second one.</p>"

    private func book() throws -> (EPUBPublication, EPUBPositionResolver, [Int: EPUBLoadedChapter]) {
        let package = EPUBFixture.package(extraManifest: "<item id=\"ch2\" href=\"ch2.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"ch3\" href=\"sub/ch3.xhtml\" media-type=\"application/xhtml+xml\"/>",
                                          spineExtra: "<itemref idref=\"ch2\"/><itemref idref=\"ch3\"/>")
        let publication = try EPUBPublication.open(data: EPUBFixture.archive([
            ("META-INF/container.xml", EPUBFixture.container), ("OEBPS/content.opf", package), ("OEBPS/nav.xhtml", EPUBFixture.nav),
            ("OEBPS/ch1.xhtml", EPUBFixture.chapter(chapterOne)), ("OEBPS/ch2.xhtml", EPUBFixture.chapter(chapterTwo)), ("OEBPS/sub/ch3.xhtml", EPUBFixture.chapter(chapterThree))
        ]))
        let loader = EPUBChapterLoader(resources: EPUBBookResources(publication: publication), settings: EPUBReadingSettings(), geometry: EPUBTextGeometry(columnWidth: 360, maximumImageHeight: 600), mediaContext: .default)
        var chapters: [Int: EPUBLoadedChapter] = [:]
        for index in 0..<3 { chapters[index] = loader.load(spineIndex: index) }
        let resolver = EPUBPositionResolver(publication: publication) { chapters[$0] }
        return (publication, resolver, chapters)
    }

    // MARK: Scale

    func testProgressScaleFollowsTheReadiumVectorsReinterpretedForUncompressedSizes() {
        let scale = EPUBProgressScale(weights: [2048, 1000, 5000])
        XCTAssertEqual(scale.totalLocations, 8)
        XCTAssertEqual(scale.location(spineIndex: 0, progression: 0), 1)
        XCTAssertEqual(scale.location(spineIndex: 2, progression: 1), 8)
        XCTAssertEqual(scale.fraction(spineIndex: 1, progression: 0), 2048.0 / 8048.0, accuracy: 1e-9)
        XCTAssertEqual(scale.fraction(spineIndex: 1, progression: 0.4), 2448.0 / 8048.0, accuracy: 1e-9, "V-10: forty percent into resource two")
        XCTAssertEqual(scale.fraction(spineIndex: 2, progression: 0.4), 5048.0 / 8048.0, accuracy: 1e-9)
        let back = scale.position(forFraction: 2448.0 / 8048.0)
        XCTAssertEqual(back?.spineIndex, 1); XCTAssertEqual(back?.progression ?? 0, 0.4, accuracy: 1e-6, "V-11: the inverse map lands in resource two at 0.4")
        let end = scale.position(forFraction: 1)
        XCTAssertEqual(end?.spineIndex, 2); XCTAssertEqual(end?.progression ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(EPUBProgressScale(weights: [0, 1024, 1025]).totalLocations, 3, "Lengths 0, 1024 and 1025 make three locations")
        XCTAssertEqual(EPUBProgressScale(weights: [0, 1024, 1025]).position(forFraction: 0)?.spineIndex, 1, "Zero-weight items are never chosen")
        XCTAssertEqual(EPUBProgressScale(weights: []).totalLocations, 1)
        XCTAssertNil(EPUBProgressScale(weights: []).position(forFraction: 0.5))
    }

    // MARK: Locator JSON

    func testLocatorSerialisesWithSortedKeysNoEscapedSlashesAndNoNulls() throws {
        let (publication, _, chapters) = try book()
        let chapter = try XCTUnwrap(chapters[0])
        let offset = chapter.text.blocks[1].range.location
        let locator = try XCTUnwrap(EPUBLocator.make(publication: publication, spineIndex: 0, chapter: chapter, offset: offset, title: "Chapter", date: Date(timeIntervalSince1970: 1_760_536_931)))
        let json = try locator.jsonString()
        XCTAssertTrue(json.hasPrefix("{\"cfi\":\"epubcfi(/6/2!/4/4[p2]/1:0"), json)
        XCTAssertTrue(json.contains("\"href\":\"OEBPS/ch1.xhtml\""))
        XCTAssertFalse(json.contains("\\/"), "Slashes are never escaped")
        XCTAssertFalse(json.contains("null"), "Nulls are dropped")
        XCTAssertTrue(json.contains("\"savedAt\":\"2025-10-15T14:02:11Z\""))
        XCTAssertTrue(json.contains("\"v\":2"))
        XCTAssertEqual(locator.text?.after?.hasPrefix("The second paragraph"), true)
        XCTAssertEqual(locator.text?.before?.hasSuffix("anchor a position in."), true)
        XCTAssertLessThanOrEqual(locator.text?.before?.count ?? 0, EPUBLocator.contextLength)
        XCTAssertEqual(locator.chapterLength, chapter.text.length)
        XCTAssertEqual(locator.parser, EPUBChapterText.parserVersion)
        XCTAssertEqual(locator.progression, Double(offset) / Double(chapter.text.length), accuracy: 1e-9)
        XCTAssertEqual(locator.release.identifier, publication.package.uniqueIdentifier)
        XCTAssertEqual(locator.release.modified, "2026-10-15T00:00:00Z")
        guard case .current(let decoded) = EPUBStoredPosition.parse(json) else { return XCTFail("A version 2 row reads back") }
        XCTAssertEqual(decoded, locator)
    }

    func testReadiumRowsParseLeniently() {
        let json = "{\"href\":\"/OEBPS/ch2.xhtml\",\"locations\":{\"fragment\":\"n1\",\"progression\":0.25,\"totalProgression\":-1,\"cssSelector\":\"p.x\",\"position\":3},\"text\":{\"before\":\"a\",\"highlight\":\"b\"},\"title\":\"Two\",\"type\":\"application/xhtml+xml\"}"
        guard case .legacy(let legacy) = EPUBStoredPosition.parse(json) else { return XCTFail("A Readium row is legacy") }
        XCTAssertEqual(legacy.href, "OEBPS/ch2.xhtml", "The leading slash is stripped")
        XCTAssertEqual(legacy.fragments, ["n1"], "A singular fragment joins the list")
        XCTAssertEqual(legacy.progression, 0.25)
        XCTAssertNil(legacy.totalProgression, "Negative values are absent")
        XCTAssertEqual(legacy.cssSelector, "p.x"); XCTAssertEqual(legacy.textBefore, "a"); XCTAssertEqual(legacy.textHighlight, "b"); XCTAssertEqual(legacy.title, "Two")
        XCTAssertEqual(EPUBStoredPosition.parse("{\"href\":\"ch1.xhtml\",\"type\":\"application/xhtml+xml\"}"), .legacy(EPUBLegacyPosition(href: "ch1.xhtml", title: nil, fragments: [], cssSelector: nil, progression: nil, totalProgression: nil, textBefore: nil, textHighlight: nil, textAfter: nil)))
        XCTAssertEqual(EPUBStoredPosition.parse("not json"), .unreadable)
        XCTAssertEqual(EPUBStoredPosition.parse("{\"v\":2}"), .unreadable, "A damaged version 2 row is unreadable, not legacy")
    }

    // MARK: Restore ladder

    func testRestoreUsesTheOffsetWhenReleaseParserAndLengthMatch() throws {
        let (publication, resolver, chapters) = try book()
        let chapter = try XCTUnwrap(chapters[0])
        let offset = chapter.text.blocks[2].range.location
        let locator = try XCTUnwrap(EPUBLocator.make(publication: publication, spineIndex: 0, chapter: chapter, offset: offset, title: nil))
        let restored = resolver.resolve(.current(locator))
        XCTAssertEqual(restored.spineIndex, 0); XCTAssertEqual(restored.offset, offset); XCTAssertEqual(restored.method, .offset); XCTAssertTrue(restored.fallbacks.isEmpty); XCTAssertFalse(restored.isApproximate)
    }

    func testRestoreFallsToTheCFIThenTextThenProgressionThenTotalProgression() throws {
        let (publication, resolver, chapters) = try book()
        let chapter = try XCTUnwrap(chapters[0])
        let offset = chapter.text.blocks[1].range.location + 4
        var locator = try XCTUnwrap(EPUBLocator.make(publication: publication, spineIndex: 0, chapter: chapter, offset: offset, title: nil))
        locator.chapterLength += 10
        let viaCFI = resolver.resolve(.current(locator))
        XCTAssertEqual(viaCFI.method, .cfi); XCTAssertEqual(viaCFI.offset, offset); XCTAssertEqual(viaCFI.fallbacks, [.offset]); XCTAssertFalse(viaCFI.isApproximate)
        locator.cfi = "epubcfi(/6/2[ch1]!/4/40/1:0)"
        let viaText = resolver.resolve(.current(locator))
        XCTAssertEqual(viaText.method, .text); XCTAssertEqual(viaText.offset, offset); XCTAssertEqual(viaText.fallbacks, [.offset, .cfi]); XCTAssertTrue(viaText.isApproximate)
        locator.text = EPUBLocator.TextContext(before: "paragraph of the first chapter has enough text to anchor a position in. The", after: "secnod paragraph goes on for a while so that offsets differ from the start.")
        let approximate = resolver.resolve(.current(locator))
        XCTAssertEqual(approximate.method, .approximateText); XCTAssertEqual(approximate.offset, offset, "One transposition still anchors"); XCTAssertEqual(approximate.fallbacks, [.offset, .cfi, .text])
        locator.text = EPUBLocator.TextContext(before: nil, after: "Text that appears nowhere in this book at all, honestly.")
        let viaProgression = resolver.resolve(.current(locator))
        XCTAssertEqual(viaProgression.method, .progression); XCTAssertEqual(viaProgression.fallbacks, [.offset, .cfi, .text])
        XCTAssertEqual(viaProgression.offset, Int((locator.progression * Double(chapter.text.length)).rounded()))
        locator.href = "OEBPS/gone.xhtml"; locator.spineIndex = 7
        let viaTotal = resolver.resolve(.current(locator))
        XCTAssertEqual(viaTotal.method, .totalProgression); XCTAssertEqual(viaTotal.spineIndex, 0); XCTAssertNil(viaTotal.offset)
        XCTAssertEqual(viaTotal.progression, locator.progression, accuracy: 0.01)
    }

    func testReadiumRowsResolveFragmentThenSelectorThenTextThenProgressions() throws {
        let (_, resolver, chapters) = try book()
        let one = try XCTUnwrap(chapters[0])
        func legacy(_ json: String) -> EPUBRestoredPosition { resolver.resolve(EPUBStoredPosition.parse(json)) }
        let fragment = legacy("{\"href\":\"/OEBPS/ch1.xhtml\",\"type\":\"application/xhtml+xml\",\"locations\":{\"fragments\":[\"p2\"],\"progression\":0.9}}")
        XCTAssertEqual(fragment.method, .fragment); XCTAssertEqual(fragment.offset, one.text.anchors["p2"])
        let selector = legacy("{\"href\":\"OEBPS/ch1.xhtml#p9\",\"type\":\"application/xhtml+xml\",\"locations\":{\"fragments\":[\"p9\"],\"cssSelector\":\"p.last\",\"progression\":0.1}}")
        XCTAssertEqual(selector.method, .selector); XCTAssertEqual(selector.offset, one.text.blocks[2].range.location); XCTAssertEqual(selector.fallbacks, [.fragment])
        let text = legacy("{\"href\":\"OEBPS/ch1.xhtml\",\"type\":\"application/xhtml+xml\",\"locations\":{\"cssSelector\":\"p:nth-child(3)\",\"progression\":0.1},\"text\":{\"highlight\":\"A third paragraph\"}}")
        XCTAssertEqual(text.method, .text); XCTAssertEqual(text.offset, one.text.blocks[2].range.location); XCTAssertEqual(text.fallbacks, [.selector])
        let progression = legacy("{\"href\":\"OEBPS/ch1.xhtml\",\"type\":\"application/xhtml+xml\",\"locations\":{\"progression\":0.5}}")
        XCTAssertEqual(progression.method, .progression); XCTAssertEqual(progression.offset, Int((0.5 * Double(one.text.length)).rounded()))
        let total = legacy("{\"href\":\"OEBPS/missing.xhtml\",\"type\":\"application/xhtml+xml\",\"locations\":{\"totalProgression\":0.99}}")
        XCTAssertEqual(total.method, .totalProgression); XCTAssertEqual(total.spineIndex, 2)
        let start = legacy("{\"href\":\"OEBPS/missing.xhtml\",\"type\":\"application/xhtml+xml\"}")
        XCTAssertEqual(start.method, .start); XCTAssertEqual(start.spineIndex, 0)
        XCTAssertEqual(legacy("garbage").method, .start)
    }

    func testTextAnchorScoring() {
        XCTAssertEqual(EPUBTextAnchor.similarity("kitten", "sitting"), 1 - 3.0 / 7.0, accuracy: 1e-9)
        XCTAssertEqual(EPUBTextAnchor.similarity("", ""), 1)
        let text = "Alpha beta gamma. Alpha beta delta. Alpha beta gamma again."
        XCTAssertEqual(EPUBTextAnchor.find(before: "delta. ", after: "Alpha beta gamma", in: text, hint: nil)?.offset, 36, "The occurrence whose preceding text matches wins")
        XCTAssertEqual(EPUBTextAnchor.find(before: nil, after: "Alpha beta gamma", in: text, hint: 40)?.offset, 36, "Without a before, the nearest to the hint wins")
        XCTAssertEqual(EPUBTextAnchor.find(before: nil, after: "Alpha beta gamma", in: text, hint: 0)?.offset, 0)
        XCTAssertNil(EPUBTextAnchor.find(before: nil, after: "zzzz qqqq", in: text, hint: nil))
        XCTAssertEqual(EPUBTextAnchor.find(before: "gamma. ", after: nil, in: text, hint: nil)?.offset, 18, "A before alone lands after it")
    }
}
