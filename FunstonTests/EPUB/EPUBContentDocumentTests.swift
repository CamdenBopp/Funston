import XCTest
@testable import Funston

/// The Apple text stack study's XHTML cases (section 9.2) and the semantics of Spec section 8.
final class EPUBContentDocumentTests: XCTestCase {
    private func parse(_ text: String, language: String? = "en") -> EPUBContentDocument {
        EPUBContentDocument.parse(Data(text.utf8), path: "OEBPS/ch.xhtml", publicationLanguage: language)
    }
    private func parse(_ data: Data) -> EPUBContentDocument {
        EPUBContentDocument.parse(data, path: "OEBPS/ch.xhtml", publicationLanguage: "en")
    }
    private func bodyText(_ document: EPUBContentDocument) -> String {
        document.body.map { document.tree.textContent(of: $0) } ?? ""
    }
    private let xhtmlDoctype = "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">"

    func testUndeclaredNamedEntitiesParseThroughPreExpansion() {
        let a = parse("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>a&nbsp;b<i>c</i>d&mdash;e</p></body></html>")
        XCTAssertEqual(a.parserPath, .xml)
        XCTAssertEqual(bodyText(a), "a\u{A0}bcd\u{2014}e")
        let e = parse("<!DOCTYPE html><html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>a&nbsp;b</p></body></html>")
        XCTAssertEqual(e.parserPath, .xml); XCTAssertEqual(bodyText(e), "a\u{A0}b")
        let b = parse(xhtmlDoctype + "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>a&nbsp;b&mdash;c &copy;</p></body></html>")
        XCTAssertEqual(b.parserPath, .xml); XCTAssertEqual(bodyText(b), "a\u{A0}b\u{2014}c \u{A9}", "The external DTD is never fetched; the table supplies the characters")
        XCTAssertTrue(b.diagnostics.isEmpty, "\(b.diagnostics.items)")
    }

    func testInternalSubsetEntitiesAreLeftToTheParser() {
        let d = parse("<!DOCTYPE html [<!ENTITY nbsp \"&#160;\"><!ENTITY mine \"MINE\">]><html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>a&nbsp;b&mine;&mdash;</p></body></html>")
        XCTAssertEqual(d.parserPath, .xml)
        XCTAssertEqual(bodyText(d), "a\u{A0}bMINE\u{2014}")
        XCTAssertEqual(EPUBEntityExpansion.internalSubsetEntityNames(in: "<!DOCTYPE x [ <!ENTITY a \"1\"> <!ENTITY b.c '2'> <!ENTITY % p \"x\"> ]><html/>"), ["a", "b.c"])
        let nested = parse("<!DOCTYPE html [<!ENTITY a \"A\"><!ENTITY b \"&a;&a;\">]><html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>&b;</p></body></html>")
        XCTAssertEqual(bodyText(nested), "AA")
        var bomb = "<!DOCTYPE html [<!ENTITY l0 \"ha\">"
        for level in 1...12 { bomb += "<!ENTITY l\(level) \"" + String(repeating: "&l\(level - 1);", count: 10) + "\">" }
        bomb += "]><html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>&l12;</p></body></html>"
        let limited = parse(bomb)
        XCTAssertEqual(limited.parserPath, .xml)
        XCTAssertEqual(bodyText(limited), "\u{FFFD}")
        XCTAssertTrue(limited.diagnostics.contains(code: "chapter.parse.entityExpansionLimit"))
    }

    func testUnknownEntitiesBecomeReplacementCharactersAndAreCounted() {
        let t = parse("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>&bogus;x&bogus;y&nbsp;&amp;&lt;<![CDATA[&bogus;]]><!-- &bogus; --></p></body></html>")
        XCTAssertEqual(t.parserPath, .xml)
        XCTAssertEqual(bodyText(t), "\u{FFFD}x\u{FFFD}y\u{A0}&<&bogus;")
        XCTAssertEqual(t.diagnostics.count(code: EPUBContentDocument.unknownEntityDiagnostic), 2)
        let expanded = EPUBEntityExpansion.expand("&amp;&nbsp;&NotEqualTilde;<![CDATA[&nbsp;]]>&lt;")
        XCTAssertEqual(expanded.text, "&amp;&#160;&#8770;&#824;<![CDATA[&nbsp;]]>&lt;")
        XCTAssertEqual(expanded.unknownCount, 0)
    }

    func testEncodingSettlesFromBOMDeclarationMetaAndFallback() throws {
        let latin1Body = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>caf\u{E9}</p></body></html>"
        var utf8BOM = Data([0xEF, 0xBB, 0xBF]); utf8BOM.append(Data(latin1Body.utf8))
        XCTAssertEqual(bodyText(parse(utf8BOM)), "café")
        XCTAssertEqual(parse(utf8BOM).encodingName, "utf-8")
        var utf16 = Data([0xFF, 0xFE]); utf16.append(try XCTUnwrap(latin1Body.data(using: .utf16LittleEndian)))
        XCTAssertEqual(bodyText(parse(utf16)), "café"); XCTAssertEqual(parse(utf16).encodingName, "utf-16le")
        let declared = try XCTUnwrap(("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>" + latin1Body).data(using: .isoLatin1))
        XCTAssertEqual(bodyText(parse(declared)), "café"); XCTAssertEqual(parse(declared).encodingName, "iso-8859-1")
        XCTAssertEqual(bodyText(parse(Data(latin1Body.utf8))), "café")
        let undeclaredLatin1 = try XCTUnwrap(latin1Body.data(using: .isoLatin1))
        let fallback = parse(undeclaredLatin1)
        XCTAssertEqual(bodyText(fallback), "café")
        XCTAssertEqual(fallback.encodingName, "windows-1252")
        XCTAssertTrue(fallback.diagnostics.contains(code: "chapter.decode.fallback"))
        let lying = try XCTUnwrap(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + latin1Body).data(using: .isoLatin1))
        XCTAssertEqual(bodyText(parse(lying)), "café"); XCTAssertTrue(parse(lying).diagnostics.contains(code: "chapter.decode.fallback"))
        let meta = try XCTUnwrap("<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=windows-1252\"/></head><body><p>caf\u{E9}</p></body></html>".data(using: .windowsCP1252))
        XCTAssertEqual(bodyText(parse(meta)), "café"); XCTAssertEqual(parse(meta).encodingName, "windows-1252")
        XCTAssertTrue(parse(meta).diagnostics.isEmpty)
        XCTAssertEqual(EPUBContentDecoder.declaredEncoding(in: "<meta http-equiv=\"Content-Type\" content=\"text/htmlcharset=utf-8\"/>"), "utf-8")
    }

    func testControlCharactersAndInvalidBytesDoNotStopParsing() {
        let control = parse("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>a\u{01}b\tc</p></body></html>")
        XCTAssertEqual(control.parserPath, .xml)
        XCTAssertEqual(bodyText(control), "ab\tc")
        XCTAssertEqual(control.diagnostics.count(code: "chapter.decode.controlsStripped"), 1)
        var invalid = Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>caf".utf8); invalid.append(0xE9); invalid.append(Data("</p></body></html>".utf8))
        let recovered = parse(invalid)
        XCTAssertEqual(bodyText(recovered), "café"); XCTAssertEqual(recovered.parserPath, .xml)
    }

    func testTagSoupIsRecoveredAsHTMLWithADiagnosticNamingTheError() throws {
        let j = parse("<html><body><p>one<p>two</p><p>three</p></body></html>")
        XCTAssertEqual(j.parserPath, .htmlRecovered)
        let body = try XCTUnwrap(j.body)
        XCTAssertEqual(j.tree.childElements(of: body).map { j.tree.textContent(of: $0) }, ["one", "two", "three"])
        let diagnostic = try XCTUnwrap(j.diagnostics[code: EPUBContentDocument.tagSoupDiagnostic])
        XCTAssertTrue(diagnostic.message.contains("line"), diagnostic.message)
        let j2 = parse("<html><body><p class=x>a & b</p></body></html>")
        XCTAssertEqual(j2.parserPath, .htmlRecovered)
        let paragraph = try XCTUnwrap(j2.tree.elements(named: "p").first)
        XCTAssertEqual(j2.tree.attribute("class", of: paragraph), "x")
        XCTAssertEqual(j2.tree.textContent(of: paragraph), "a & b")
        let j3 = parse("<html><body><p><b>bold</p></b></body></html>")
        XCTAssertEqual(j3.parserPath, .htmlRecovered)
        XCTAssertEqual(bodyText(j3), "bold")
        XCTAssertEqual(j3.tree.namespace(of: try XCTUnwrap(j3.tree.elements(named: "p").first)), EPUBNamespace.xhtml)
        let soupWithEntities = parse("<html><body><p epub:type=\"noteref\" class=\"fnanchor\">a&nbsp;b&mdash;c&copy;<p>")
        XCTAssertEqual(bodyText(soupWithEntities), "a\u{A0}b\u{2014}c\u{A9}")
        let anchor = try XCTUnwrap(soupWithEntities.tree.elements(named: "p").first)
        XCTAssertEqual(soupWithEntities.tree.epubType(of: anchor), "noteref", "epub:type is accepted as a literal name from the recovery parser")
        XCTAssertTrue(soupWithEntities.isNoteReference(anchor))
    }

    func testTextOnlyFallbackStripsTagsAndDecodesReferences() {
        XCTAssertEqual(EPUBHTMLRecovery.strippedText("<html><head><title>T</title><style>p{}</style></head><body><script>x()</script><p>a&nbsp;<b>b</b>&#8212;c&#x2014;</p><p>next</p><!-- no --></body></html>"), "a\u{A0}b\u{2014}c\u{2014} next")
        let tree = EPUBContentDocument.textOnlyTree("plain")
        XCTAssertEqual(tree.textContent(of: 0), "plain")
        let unreadable = EPUBContentDocument.parse(Data([0x81, 0x8D, 0xFF, 0xFE, 0x00]), path: "x", publicationLanguage: nil)
        XCTAssertTrue(unreadable.parserPath == .unreadable || unreadable.parserPath == .textOnly || unreadable.parserPath == .htmlRecovered)
    }

    func testRawTreeKeepsCDATACommentsDroppedAndWhitespaceBetweenBlocks() throws {
        let k = parse("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>\n  <p>x<![CDATA[y]]><!-- c --><?pi z?>w</p>\n  <p title=\"a&amp;b&#8212;c\">x&#x2014;y&#160;z</p>\n</body></html>")
        let body = try XCTUnwrap(k.body)
        XCTAssertEqual(k.tree.children(of: body).map { k.tree[$0].kind }, [.text, .element, .text, .element, .text])
        let first = k.tree.childElements(of: body)[0]
        XCTAssertEqual(k.tree.children(of: first).map { k.tree[$0].kind }, [.text, .cdata, .text])
        XCTAssertEqual(k.tree.textContent(of: first), "xyw")
        let second = k.tree.childElements(of: body)[1]
        XCTAssertEqual(k.tree.attribute("title", of: second), "a&b\u{2014}c")
        XCTAssertEqual(k.tree.textContent(of: second), "x\u{2014}y\u{A0}z")
    }

    func testLanguageAndDirectionInheritAndFallBackToThePublication() throws {
        let document = parse("<html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"en-GB\"><body><p lang=\"fr\"><span>x</span><bdo dir=\"rtl\">y</bdo></p><p dir=\"rtl\"><em>z</em></p><p dir=\"auto\">w</p></body></html>")
        let paragraphs = document.tree.elements(named: "p")
        let span = try XCTUnwrap(document.tree.elements(named: "span").first)
        XCTAssertEqual(document.languages[span], "fr")
        XCTAssertEqual(document.languages[paragraphs[1]], "en-GB")
        XCTAssertNil(document.directions[span])
        XCTAssertEqual(document.directions[try XCTUnwrap(document.tree.elements(named: "bdo").first)], .rightToLeft)
        XCTAssertEqual(document.directions[try XCTUnwrap(document.tree.elements(named: "em").first)], .rightToLeft)
        XCTAssertEqual(document.directions[paragraphs[2]], .auto)
        let noLanguage = parse("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>x</p></body></html>", language: "el")
        XCTAssertEqual(noLanguage.languages[try XCTUnwrap(noLanguage.body)], "el")
    }

    func testHiddenSubtreesAndNeverRenderedElements() throws {
        let document = parse("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>  The  Title </title><style>p{}</style></head><body><div hidden=\"\"><p>a</p></div><p aria-hidden=\"true\"><span>b</span></p><p style=\"display: none\">c</p><p hidden=\"until-found\">d</p><p>e</p></body></html>")
        let paragraphs = document.tree.elements(named: "p")
        XCTAssertEqual(paragraphs.map { document.hidden[$0] }, [true, true, true, false, false])
        XCTAssertTrue(document.hidden[try XCTUnwrap(document.tree.elements(named: "span").first)])
        XCTAssertEqual(document.titleText, "The Title")
        XCTAssertTrue(document.isNeverRendered(try XCTUnwrap(document.tree.elements(named: "style").first)))
        XCTAssertFalse(document.isNeverRendered(paragraphs[4]))
    }

    func testStructuralSemanticsFromEpubTypeAndRoleWithRoleWinning() throws {
        let source = """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" epub:prefix="z3998: http://www.daisy.org/z3998/2012/vocab/structure/">
        <body epub:type="bodymatter z3998:fiction">
          <section epub:type="chapter" role="doc-chapter"><p>Call me.<a href="#n1" epub:type="noteref" id="r1">1</a><a href="#n2" role="doc-biblioref" id="r2">2</a><a href="#n3" epub:type="noteref" role="doc-chapter" id="r3">3</a></p>
          <aside epub:type="footnote" id="n1"><p>Note <a href="#r1" epub:type="backlink">↩</a></p></aside>
          <section epub:type="endnotes" role="doc-endnotes"><ol><li role="doc-endnote" id="n2">x</li></ol></section>
          <blockquote epub:type="z3998:verse"><p>v</p></blockquote>
          </section>
        </body></html>
        """
        let document = parse(source)
        let anchors = document.tree.elements(named: "a")
        XCTAssertTrue(document.isNoteReference(anchors[0]))
        XCTAssertTrue(document.isNoteReference(anchors[1]))
        XCTAssertFalse(document.isNoteReference(anchors[2]), "role wins when it disagrees with epub:type")
        XCTAssertTrue(document.isBacklink(anchors[3]))
        XCTAssertTrue(document.isNoteBody(try XCTUnwrap(document.tree.elements(named: "aside").first)))
        XCTAssertTrue(document.isNoteBody(try XCTUnwrap(document.tree.elements(named: "li").first)))
        XCTAssertTrue(document.isNotesSection(document.tree.elements(named: "section")[1]))
        XCTAssertTrue(document.epubTypeTerms[try XCTUnwrap(document.body)].contains(EPUBSemantics.bodymatterTerm))
        XCTAssertTrue(document.epubTypeTerms[try XCTUnwrap(document.body)].contains(EPUBSemantics.z3998 + "fiction"))
        XCTAssertTrue(document.epubTypeTerms[try XCTUnwrap(document.tree.elements(named: "blockquote").first)].contains(EPUBSemantics.z3998 + "verse"))
    }

    func testPageBreakLabelsFromVocabularyGutenbergAndAnchors() throws {
        let source = """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
          <span epub:type="pagebreak" title="57" id="pb1"/>
          <span role="doc-pagebreak" aria-label="12" id="pb2">12</span>
          <span class="pageno" title="[Pg 4]" id="Page_4"/>
          <a id="Page_12"/>
          <a id="Page_x_iv"/>
          <span class="pagenum">5</span>
          <span epub:type="pagebreak" id="empty"/>
          <a id="Page_1">text</a>
          <p>p</p>
        </body></html>
        """
        let document = parse(source)
        let spans = document.tree.elements(named: "span")
        let anchors = document.tree.elements(named: "a")
        XCTAssertEqual(document.pageBreakLabel(of: spans[0]), "57")
        XCTAssertEqual(document.pageBreakLabel(of: spans[1]), "12")
        XCTAssertEqual(document.pageBreakLabel(of: spans[2]), "[Pg 4]")
        XCTAssertEqual(document.pageBreakLabel(of: anchors[0]), "12")
        XCTAssertEqual(document.pageBreakLabel(of: anchors[1]), "x iv")
        XCTAssertEqual(document.pageBreakLabel(of: spans[3]), "5")
        XCTAssertNil(document.pageBreakLabel(of: spans[4]))
        XCTAssertNil(document.pageBreakLabel(of: anchors[2]), "An anchor with text is a link target, not a page marker")
        XCTAssertNil(document.pageBreakLabel(of: try XCTUnwrap(document.tree.elements(named: "p").first)))
    }

    func testNearestBlockFromAnInlineAnchor() throws {
        let document = parse("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><div class=\"footnote\"><p><a id=\"Footnote_1\"/>Note text</p></div></body></html>")
        let anchor = try XCTUnwrap(document.tree.element(withID: "Footnote_1"))
        XCTAssertEqual(document.nearestBlock(from: anchor).map { document.tree.localName(of: $0) }, "p")
    }
}
