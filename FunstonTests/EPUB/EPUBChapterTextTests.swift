import UIKit
import XCTest
@testable import Funston

/// The text model of Spec section 10: one attributed string per chapter, the
/// run table and the block list.
final class EPUBChapterTextTests: XCTestCase {
    private let geometry = EPUBTextGeometry(columnWidth: 360, maximumImageHeight: 600)

    private func chapter(_ body: String, css: String = "", settings: EPUBReadingSettings = EPUBReadingSettings(), extraFiles: [(String, Data)] = [], head: String = "") throws -> EPUBLoadedChapter {
        let markup = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>Chapter One</title><style>\(css)</style>\(head)</head><body>\(body)</body></html>"
        var fixture = ZipFixture([ZipFixture.Entry("mimetype", text: "application/epub+zip", deflate: false)])
        fixture.entries.append(ZipFixture.Entry("META-INF/container.xml", text: EPUBFixture.container))
        fixture.entries.append(ZipFixture.Entry("OEBPS/content.opf", text: EPUBFixture.package(extraManifest: "<item id=\"ch2\" href=\"ch2.xhtml\" media-type=\"application/xhtml+xml\"/>", spineExtra: "<itemref idref=\"ch2\"/>")))
        fixture.entries.append(ZipFixture.Entry("OEBPS/nav.xhtml", text: EPUBFixture.nav))
        fixture.entries.append(ZipFixture.Entry("OEBPS/ch1.xhtml", text: markup))
        fixture.entries.append(ZipFixture.Entry("OEBPS/ch2.xhtml", text: EPUBFixture.chapter("<p id=\"n1\">Note one</p>")))
        for (name, data) in extraFiles { fixture.entries.append(ZipFixture.Entry(name, data)) }
        let publication = try EPUBPublication.open(data: fixture.build())
        let loader = EPUBChapterLoader(resources: EPUBBookResources(publication: publication), settings: settings, geometry: geometry, mediaContext: .default)
        return try XCTUnwrap(loader.load(spineIndex: 0))
    }

    private func paragraphStyle(_ text: EPUBChapterText, at offset: Int) -> NSParagraphStyle? {
        text.string.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle
    }

    func testWhitespaceCollapsesLikeCSSAndBlocksEndInOneSeparator() throws {
        let loaded = try chapter("<p>\n   The\n   quick\n</p> <p>a&nbsp;b<b> c</b>d</p>\n<pre>\nline one\n  line two\n</pre><p>x<br/>y</p><p>&#x3000;z</p>")
        let text = loaded.text
        XCTAssertEqual(text.plainText, "The quick\na\u{A0}b cd\nline one\u{2028}  line two\nx\u{2028}y\n\u{3000}z\n")
        XCTAssertEqual(text.blocks.count, 5)
        XCTAssertEqual(text.blocks.map(\.kind), [.paragraph, .paragraph, .preformatted, .paragraph, .paragraph])
        XCTAssertEqual(text.blocks[0].range, NSRange(location: 0, length: 9))
        XCTAssertEqual(text.text(in: text.blocks[2].range), "line one\u{2028}  line two")
        XCTAssertEqual(text.title, "Chapter One")
    }

    func testBlockListFollowsTheFoliateBlockVectorAndHeadingsCarryLevels() throws {
        let loaded = try chapter("<h1 id=\"t\">Title</h1><p>One</p><p>Two</p><ul><li>A</li><li>B</li></ul><div><p>Inner</p></div><div><br/></div>")
        let text = loaded.text
        XCTAssertEqual(text.blocks.map(\.kind), [.heading(level: 1), .paragraph, .paragraph, .listItem(ordinal: 1), .listItem(ordinal: 2), .paragraph])
        XCTAssertEqual(text.blocks.map { text.text(in: $0.range) }, ["Title", "One", "Two", "\u{2022} A", "\u{2022} B", "Inner"])
        XCTAssertEqual(text.string.attribute(.epubHeadingLevel, at: 0, effectiveRange: nil) as? Int, 1)
        XCTAssertEqual(text.string.attribute(.epubElementID, at: 0, effectiveRange: nil) as? String, "t")
        XCTAssertEqual(text.anchors["t"], 0)
        XCTAssertEqual(text.containers.count, 1)
        XCTAssertEqual(text.containers[0].kind, .list(itemCount: 2, ordered: false))
        XCTAssertEqual(text.containers[0].range, NSUnionRange(text.blocks[3].range, text.blocks[4].range).extended(by: 1))
        XCTAssertEqual(text.blocks[3].containers, [0])
        XCTAssertEqual(text.blocks[5].containers, [])
    }

    func testOrderedListsHonourStartValueReversedAndTypeAndWrapLinesIndentPastTheMarker() throws {
        let loaded = try chapter("<ol start=\"3\"><li>a</li><li value=\"7\">b</li><li>c</li></ol><ol reversed=\"\"><li>x</li><li>y</li></ol><ol type=\"i\"><li>r</li><li>s</li><li>t</li></ol><ul style=\"list-style-type: none\"><li>plain</li></ul><ol><li><p>first</p><p>second</p></li></ol>")
        let text = loaded.text
        let items = text.blocks.map { text.text(in: $0.range) }
        XCTAssertEqual(items, ["3. a", "7. b", "8. c", "2. x", "1. y", "i. r", "ii. s", "iii. t", "plain", "1. first", "second"])
        XCTAssertEqual(text.blocks[0].kind, .listItem(ordinal: 3))
        XCTAssertEqual(text.blocks[8].kind, .listItem(ordinal: nil))
        let first = try XCTUnwrap(paragraphStyle(text, at: text.blocks[0].range.location))
        XCTAssertGreaterThan(first.headIndent, first.firstLineHeadIndent, "Continuation lines sit past the marker")
        XCTAssertEqual(first.firstLineHeadIndent, 40, accuracy: 0.01)
        let second = try XCTUnwrap(paragraphStyle(text, at: text.blocks[10].range.location))
        XCTAssertEqual(second.firstLineHeadIndent, 40, accuracy: 0.01)
    }

    func testRunTableMapsRenderedOffsetsToSourceAndBackAcrossCollapsedWhitespaceAndMarkers() throws {
        let loaded = try chapter("<p>Hello,   <i>world</i></p><ul><li>Item   text</li></ul>")
        let text = loaded.text
        let tree = loaded.document.tree
        let helloNode = tree.children(of: tree.elements(named: "p")[0])[0]
        let worldNode = tree.children(of: tree.elements(named: "i")[0])[0]
        XCTAssertEqual(text.plainText, "Hello, world\n\u{2022} Item text\n")
        XCTAssertEqual(text.runTable.sourcePosition(forRendered: 3), .text(node: helloNode, offset: 3))
        XCTAssertEqual(text.runTable.sourcePosition(forRendered: 6), .text(node: helloNode, offset: 6), "The collapsed space maps to the first source space")
        XCTAssertEqual(text.runTable.sourcePosition(forRendered: 7), .text(node: worldNode, offset: 0))
        XCTAssertEqual(text.runTable.sourcePosition(forRendered: 12), .text(node: worldNode, offset: 5), "An end offset maps to the end of the earlier run")
        XCTAssertEqual(text.runTable.renderedOffset(for: .text(node: helloNode, offset: 8), in: tree), 7, "An offset in dropped whitespace lands on the next rendered character")
        XCTAssertEqual(text.runTable.renderedOffset(for: .text(node: worldNode, offset: 2), in: tree), 9)
        XCTAssertEqual(text.runTable.renderedOffset(for: .element(tree.elements(named: "i")[0]), in: tree), 7)
        XCTAssertEqual(text.runTable.renderedOffset(for: .element(tree.elements(named: "li")[0]), in: tree), 15, "The marker is synthesised; the element starts at its first source character")
        let itemNode = tree.children(of: tree.elements(named: "li")[0])[0]
        XCTAssertEqual(text.runTable.sourcePosition(forRendered: 13), .text(node: itemNode, offset: 0), "A marker character maps forward to the next run")
        XCTAssertEqual(text.runTable.sourcePosition(forRendered: 16), .text(node: itemNode, offset: 1))
        XCTAssertEqual(text.runTable.sourcePosition(forRendered: 19), .text(node: itemNode, offset: 4))
        XCTAssertEqual(text.runTable.sourcePosition(forRendered: 20), .text(node: itemNode, offset: 7))
        XCTAssertEqual(text.runTable.renderedOffset(for: .boundary(parent: tree.elements(named: "p")[0], childIndex: 2), in: tree), 12)
    }

    func testFoliateTextWalkerBoundaryVector() throws {
        let loaded = try chapter("<p>Hello, <b>world</b></p>")
        let text = loaded.text
        let tree = loaded.document.tree
        let first = tree.children(of: tree.elements(named: "p")[0])[0]
        let second = tree.children(of: tree.elements(named: "b")[0])[0]
        XCTAssertEqual(text.runTable.sourcePosition(forRendered: 3), .text(node: first, offset: 3))
        XCTAssertEqual(text.runTable.sourcePosition(forRendered: 8), .text(node: second, offset: 1))
        XCTAssertEqual(text.runTable.sourcePosition(forRendered: 5), .text(node: first, offset: 5), "The word Hello ends in the first node, not at the start of the next")
        XCTAssertEqual(text.runTable.sourcePosition(forRendered: 7), .text(node: second, offset: 0), "A start offset at the boundary belongs to the later node")
        XCTAssertEqual(text.runTable.sourcePosition(forRendered: 6), .text(node: first, offset: 6), "The collapsed space is the first node's")
    }

    func testStringContentIsIndependentOfSettingsAndGeometry() throws {
        let body = "<h2>Title</h2><p class=\"smcap\">Small caps and <sup>1</sup> and <b>bold</b></p><ul><li>x</li></ul>"
        let css = ".smcap { font-variant: small-caps } p { text-transform: uppercase }"
        let first = try chapter(body, css: css)
        var large = EPUBReadingSettings(); large.baseFontSize = 34; large.publisherStyles = true; large.alignment = .justify
        let second = try chapter(body, css: css, settings: large)
        XCTAssertEqual(first.text.plainText, second.text.plainText)
        XCTAssertEqual(first.text.runTable, second.text.runTable)
        XCTAssertEqual(first.text.blocks.map(\.range), second.text.blocks.map(\.range))
        XCTAssertTrue(first.text.plainText.contains("SMALL CAPS"), "Small caps are synthesised by uppercasing regardless of the font")
        let firstFont = first.text.string.attribute(.font, at: first.text.blocks[1].range.location, effectiveRange: nil) as? UIFont
        let secondFont = second.text.string.attribute(.font, at: second.text.blocks[1].range.location, effectiveRange: nil) as? UIFont
        XCTAssertEqual(firstFont?.pointSize ?? 0, 17 * 0.8, accuracy: 0.01)
        XCTAssertEqual(secondFont?.pointSize ?? 0, 34 * 0.8, accuracy: 0.01)
        let heading = first.text.string.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertEqual(heading?.pointSize ?? 0, 17 * 1.44, accuracy: 0.01)
        XCTAssertTrue(heading?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false)
    }

    func testLinksNoteReferencesAndAnchors() throws {
        let body = """
        <p id="p">See <a href="ch2.xhtml#n1">chapter two</a>, <a href="https://example.org/x">the web</a>, <a href="javascript:alert(1)">no</a>.<a href="#fn1" id="r1" epub:type="noteref">1</a><a href="#fn2"><sup>2</sup></a><a href="#Footnote_3" class="fnanchor">[3]</a><a href="#fn4">4</a><a id="empty"/></p>
        <div class="footnote"><p id="Footnote_3">Three</p></div>
        <aside epub:type="footnote" id="fn1"><p>One <a href="#r1" epub:type="backlink">back</a></p></aside>
        <p id="fn2">Two</p><p id="fn4">Four</p>
        """
        let loaded = try chapter(body)
        let text = loaded.text
        XCTAssertEqual(text.links.count, 8)
        XCTAssertEqual(text.links[0], .internalLink(path: "OEBPS/ch2.xhtml", fragment: "n1", spineIndex: 1))
        XCTAssertEqual(text.links[1], .external(URL(string: "https://example.org/x")!))
        XCTAssertEqual(text.links[2], .refused("javascript:alert(1)"))
        let first = text.blocks[0]
        XCTAssertEqual(first.links.count, 7)
        XCTAssertEqual(text.text(in: first.links[0].range), "chapter two")
        XCTAssertEqual(first.noteReferences.map { text.text(in: $0.range) }, ["1", "2", "[3]"], "Vocabulary, superscript and Gutenberg conventions; the plain link to a paragraph is not a note")
        XCTAssertEqual(text.string.attribute(.epubLinkIndex, at: first.links[0].range.location, effectiveRange: nil) as? Int, 0)
        XCTAssertNotNil(text.string.attribute(.link, at: first.links[0].range.location, effectiveRange: nil))
        XCTAssertNotNil(text.string.attribute(.epubNoteReference, at: first.noteReferences[0].range.location, effectiveRange: nil))
        XCTAssertEqual(text.anchors["empty"], first.range.location + first.range.length, "An empty anchor records where it sits")
        XCTAssertEqual(text.anchors["fn1"], text.blocks[2].range.location)
        XCTAssertEqual(text.containers.first { if case .note = $0.kind { return true } else { return false } }?.kind, .note(label: "note back"))
        let backlinkBlock = text.blocks[2]
        XCTAssertTrue(backlinkBlock.noteReferences.isEmpty, "A backlink is never a note reference")
        XCTAssertEqual(backlinkBlock.kind, .noteBody)
    }

    func testImagesBecomeAttachmentsPlaceholdersOrNothing() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 80, height: 46), format: format).image { context in UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 46)) }.pngData())
        let body = """
        <p>Inline <img src="images/eq.png" alt="" width="80" height="46"/> equation.</p>
        <div class="figcenter"><img src="images/eq.png" alt="A plate"/></div>
        <p><img src="images/missing.png" alt="Lost picture"/></p>
        <p><img src="images/missing.png" alt=""/></p>
        <p><img src="images/vector.svg" alt="A diagram"/></p>
        <p><img src="images/noalt.png"/></p>
        <svg xmlns="http://www.w3.org/2000/svg"><title>Logo</title></svg>
        <p><math alttext="x squared"><mi>x</mi></math></p>
        """
        let loaded = try chapter(body, extraFiles: [("OEBPS/images/eq.png", png), ("OEBPS/images/vector.svg", Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8))])
        let text = loaded.text
        XCTAssertEqual(text.images.count, 2)
        XCTAssertEqual(text.images[0].isBlock, false); XCTAssertEqual(text.images[0].intrinsicSize, CGSize(width: 80, height: 46)); XCTAssertEqual(text.images[0].declaredWidth, .points(80))
        XCTAssertEqual(text.images[1].isBlock, true); XCTAssertEqual(text.images[1].alternativeText, "A plate")
        XCTAssertEqual(text.blocks[1].kind, .image); XCTAssertEqual(text.blocks[1].alternativeText, "A plate"); XCTAssertTrue(text.blocks[1].isAccessible)
        XCTAssertEqual(text.text(in: text.blocks[1].range), "\u{FFFC}")
        XCTAssertEqual(text.string.attribute(.epubAlternativeText, at: text.blocks[1].range.location, effectiveRange: nil) as? String, "A plate")
        XCTAssertTrue(text.string.attribute(.attachment, at: text.images[0].renderedOffset, effectiveRange: nil) is EPUBImageAttachment)
        XCTAssertEqual(text.text(in: text.blocks[0].range), "Inline \u{FFFC} equation.")
        XCTAssertEqual(text.text(in: text.blocks[2].range), "[Lost picture]")
        XCTAssertEqual(text.blocks[2].kind, .image)
        XCTAssertEqual(text.text(in: text.blocks[3].range), "[A diagram]")
        XCTAssertEqual(text.text(in: text.blocks[4].range), "[image noalt]")
        XCTAssertEqual(text.text(in: text.blocks[5].range), "[Logo]")
        XCTAssertEqual(text.text(in: text.blocks[6].range), "x squared")
        XCTAssertEqual(text.blocks.count, 7, "A missing decorative image renders nothing")
        XCTAssertEqual(loaded.diagnostics.count(code: EPUBImageCatalog.placeholderDiagnostic), 4)
        XCTAssertEqual(EPUBChapterTextBuilder.initialBounds(for: text.images[1], columnWidth: 50, maximumHeight: 600).size, CGSize(width: 50, height: 28.75))
        var tall = text.images[1]
        tall = EPUBImagePlacement(path: tall.path, alternativeText: nil, intrinsicSize: CGSize(width: 400, height: 3000), declaredWidth: nil, declaredHeight: nil, declaredMaxWidth: nil, isBlock: true, isDecorative: false, renderedOffset: 0, textScale: 1)
        XCTAssertEqual(EPUBChapterTextBuilder.initialBounds(for: tall, columnWidth: 360, maximumHeight: 600).size.height, 600)
        var large = EPUBReadingSettings(); large.baseFontSize = 34
        let scaled = try chapter("<p>Inline <img src=\"images/eq.png\" alt=\"\"/> x</p>", settings: large, extraFiles: [("OEBPS/images/eq.png", png)])
        XCTAssertEqual(EPUBChapterTextBuilder.initialBounds(for: scaled.text.images[0], columnWidth: 360, maximumHeight: 600).size.width, 160, "Inline images scale with the text")
    }

    func testImageOnlyChapterIsAnImagePage() throws {
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }.pngData())
        let loaded = try chapter("<div><img src=\"cover.png\" alt=\"Cover\"/></div>", extraFiles: [("OEBPS/cover.png", png)])
        XCTAssertTrue(loaded.text.isImagePage)
        XCTAssertEqual(loaded.text.blocks.map(\.kind), [.image])
        XCTAssertFalse(try chapter("<p>Text</p>").text.isImagePage)
    }

    func testTablesFlattenIntoCellsInsideAContainer() throws {
        let loaded = try chapter("<table><caption>Cap</caption><tr><th>H1</th><th>H2</th></tr><tr><td>a</td><td>b</td></tr></table><table><tr><td><p class=\"titleblock\">MAN AND MAID</p></td></tr></table>")
        let text = loaded.text
        XCTAssertEqual(text.blocks.map(\.kind), [.caption, .tableCell(row: 0, column: 0, isHeader: true), .tableCell(row: 0, column: 1, isHeader: true), .tableCell(row: 1, column: 0, isHeader: false), .tableCell(row: 1, column: 1, isHeader: false), .tableCell(row: 0, column: 0, isHeader: false)])
        XCTAssertEqual(text.containers[0].kind, .table(rows: 2, columns: 2, isLayout: false))
        XCTAssertEqual(text.containers[1].kind, .table(rows: 1, columns: 1, isLayout: true))
        XCTAssertEqual(text.blocks.map { text.text(in: $0.range) }, ["Cap", "H1", "H2", "a", "b", "MAN AND MAID"])
    }

    func testDirectionLanguageAndSuperscriptAttributes() throws {
        let loaded = try chapter("<p lang=\"he\">שלום</p><p dir=\"rtl\">abc</p><p>مرحبا بالعالم</p><p>Plain <span lang=\"fr\">bonjour</span> x<sup>2</sup>H<sub>2</sub>O</p>")
        let text = loaded.text
        XCTAssertEqual(paragraphStyle(text, at: text.blocks[0].range.location)?.baseWritingDirection, .rightToLeft)
        XCTAssertEqual(paragraphStyle(text, at: text.blocks[0].range.location)?.alignment, .right)
        XCTAssertEqual(paragraphStyle(text, at: text.blocks[1].range.location)?.baseWritingDirection, .rightToLeft)
        XCTAssertEqual(paragraphStyle(text, at: text.blocks[2].range.location)?.baseWritingDirection, .rightToLeft, "The first strong character decides")
        XCTAssertEqual(paragraphStyle(text, at: text.blocks[3].range.location)?.baseWritingDirection, .leftToRight)
        XCTAssertEqual(paragraphStyle(text, at: text.blocks[3].range.location)?.alignment, .left)
        let french = text.blocks[3].range.location + 6
        XCTAssertEqual(text.string.attribute(.languageIdentifier, at: french, effectiveRange: nil) as? String, "fr")
        XCTAssertNil(text.string.attribute(.languageIdentifier, at: text.blocks[3].range.location, effectiveRange: nil))
        let superscript = text.blocks[3].range.location + 15
        XCTAssertEqual(text.text(in: NSRange(location: superscript, length: 1)), "2")
        XCTAssertGreaterThan((text.string.attribute(.baselineOffset, at: superscript, effectiveRange: nil) as? CGFloat) ?? 0, 0)
        let subscriptOffset = text.blocks[3].range.location + 17
        XCTAssertEqual(text.text(in: NSRange(location: subscriptOffset, length: 1)), "2")
        XCTAssertLessThan((text.string.attribute(.baselineOffset, at: subscriptOffset, effectiveRange: nil) as? CGFloat) ?? 0, 0)
        XCTAssertEqual(text.blocks[0].language, "he")
    }

    func testPageBreaksAreRecordedNotRenderedAndHiddenContentIsSkipped() throws {
        let loaded = try chapter("<p>Before</p><span class=\"pageno\" title=\"57\"/><span epub:type=\"pagebreak\" title=\"58\">58</span><p hidden=\"\">Hidden</p><p style=\"display:none\">Also</p><p>After</p>")
        let text = loaded.text
        XCTAssertEqual(text.blocks.map { text.text(in: $0.range) }, ["Before", "58", "After"])
        XCTAssertEqual(text.pageBreaks.map(\.label), ["57", "58"])
        XCTAssertEqual(text.pageBreaks[0].renderedOffset, 7)
    }

    func testForcedBreaksKeepTogetherThoughtBreaksAndEmptyParagraphsKeepSpacing() throws {
        var settings = EPUBReadingSettings(); settings.publisherStyles = true
        let loaded = try chapter("<p>a</p><p><br/></p><h2 style=\"page-break-before: always\">Chapter</h2><div style=\"break-inside: avoid\"><p>keep</p></div><hr class=\"tb\"/><p style=\"page-break-after: always\">last</p><p>next</p>", css: "h2 { margin-top: 2em }", settings: settings)
        let text = loaded.text
        XCTAssertEqual(text.blocks.map { text.text(in: $0.range) }, ["a", "Chapter", "keep", "\u{A0}", "last", "next"])
        XCTAssertEqual(text.string.attribute(.epubForcedBreakBefore, at: text.blocks[1].range.location, effectiveRange: nil) as? Bool, true)
        XCTAssertNil(text.string.attribute(.epubForcedBreakBefore, at: text.blocks[0].range.location, effectiveRange: nil))
        XCTAssertEqual(text.string.attribute(.epubKeepTogether, at: text.blocks[2].range.location, effectiveRange: nil) as? Bool, true)
        XCTAssertEqual(text.blocks[3].kind, .thoughtBreak); XCTAssertFalse(text.blocks[3].isAccessible)
        XCTAssertEqual(text.string.attribute(.epubThoughtBreak, at: text.blocks[3].range.location, effectiveRange: nil) as? Bool, true)
        XCTAssertEqual(text.string.attribute(.epubForcedBreakBefore, at: text.blocks[5].range.location, effectiveRange: nil) as? Bool, true, "page-break-after moves to the next block")
        let heading = try XCTUnwrap(paragraphStyle(text, at: text.blocks[1].range.location))
        XCTAssertGreaterThanOrEqual(heading.paragraphSpacingBefore, 34, "The dropped br paragraph keeps its spacing and the heading's own 2em")
    }

    func testMarginsBecomeIndentsClampedToKeepSixtyPercentOfTheMeasure() throws {
        var settings = EPUBReadingSettings(); settings.publisherStyles = true
        let loaded = try chapter("<p style=\"margin: 0 15%\">gibbon</p><blockquote><p>q</p></blockquote><p style=\"margin-left: 300px; text-indent: 2em\">wide</p>", settings: settings)
        let text = loaded.text
        let gibbon = try XCTUnwrap(paragraphStyle(text, at: text.blocks[0].range.location))
        XCTAssertEqual(gibbon.headIndent, 54, accuracy: 0.01); XCTAssertEqual(gibbon.tailIndent, -54, accuracy: 0.01)
        let quote = try XCTUnwrap(paragraphStyle(text, at: text.blocks[1].range.location))
        XCTAssertEqual(quote.headIndent, 40 + 0, accuracy: 0.01)
        let wide = try XCTUnwrap(paragraphStyle(text, at: text.blocks[2].range.location))
        XCTAssertEqual(wide.headIndent, 360 * 0.4, accuracy: 0.01, "Clamped so 60 percent of the column remains")
        XCTAssertEqual(wide.firstLineHeadIndent, 360 * 0.4 + 34, accuracy: 0.01)
    }

    func testEmbeddedFontsLoadFromTheContainerAndFailuresFallBack() throws {
        var settings = EPUBReadingSettings(); settings.publisherStyles = true
        let bogus = Data(repeating: 0, count: 100)
        let loaded = try chapter("<p class=\"f\">text</p>", css: "@font-face { font-family: Missing; src: url(fonts/missing.ttf) } @font-face { font-family: Bogus; src: url(fonts/bogus.ttf) } .f { font-family: Bogus, serif }", extraFiles: [("OEBPS/fonts/bogus.ttf", bogus)])
        XCTAssertEqual(loaded.diagnostics.items.filter { $0.stage == .font }.map { $0.code + ":" + ($0.path ?? "") }, ["font.missing:OEBPS/fonts/missing.ttf", "font.undecodable:OEBPS/fonts/bogus.ttf"])
        let font = loaded.text.string.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertEqual(font?.familyName, UIFont.systemFont(ofSize: 17).familyName)
    }

    func testRubyMediaAndNoscriptFallbacks() throws {
        let loaded = try chapter("<p><ruby>漢<rp>(</rp><rt>かん</rt><rp>)</rp>字<rt>じ</rt></ruby></p><audio src=\"a.mp3\"><p>Fallback text</p></audio><video src=\"v.mp4\"/><noscript><p>No script</p></noscript><script>x()</script>")
        let text = loaded.text
        XCTAssertEqual(text.blocks.map { text.text(in: $0.range) }, ["漢 (かん)字 (じ)", "Fallback text", "[video]", "No script"])
    }
}

private extension NSRange {
    func extended(by extra: Int) -> NSRange { NSRange(location: location, length: length + extra) }
}
