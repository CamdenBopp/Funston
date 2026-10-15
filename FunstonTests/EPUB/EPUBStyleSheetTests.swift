import XCTest
@testable import Funston

final class EPUBStyleSheetTests: XCTestCase {
    private func sheet(_ css: String, media: EPUBMediaContext = .default, files: [String: String] = [:]) -> EPUBStyleSheet {
        EPUBStyleSheet.parse(css, path: "OEBPS/style.css", media: media, loader: { files[$0] }, resolve: { reference, _ in "OEBPS/" + reference })
    }

    func testRulesDeclarationsImportanceAndComments() throws {
        let parsed = sheet("/* c */ p { color: red; margin: 1em 0 !important } .x, h1 > em { font-size: 120% } @charset \"UTF-8\"; @page { margin: 1in } @supports (x: y) { p { color: blue } }")
        XCTAssertEqual(parsed.rules.count, 2)
        XCTAssertEqual(parsed.rules[0].declarations, [EPUBDeclaration(property: "color", value: "red", important: false), EPUBDeclaration(property: "margin", value: "1em 0", important: true)])
        XCTAssertEqual(parsed.rules[1].selectors.map(\.text), [".x", "h1 > em"])
        XCTAssertEqual(parsed.rules.map(\.order), [0, 1])
        XCTAssertTrue(parsed.diagnostics.contains(code: "css.ignoredAtRule"))
        XCTAssertEqual(EPUBStyleSheet.parseDeclarations("background: url(data:image/png;base64,AAA=) no-repeat; color: 'a;b'").map(\.property), ["background", "color"])
    }

    func testSpecificityIsAThreeTupleAndElevenClassesDoNotBeatAnID() {
        let id = EPUBSelector.parse("#a")
        let classes = EPUBSelector.parse(".b.c.d.e.f.g.h.i.j.k.l")
        XCTAssertEqual(id.specificity, EPUBSelector.Specificity(ids: 1, classes: 0, types: 0))
        XCTAssertEqual(classes.specificity, EPUBSelector.Specificity(ids: 0, classes: 11, types: 0))
        XCTAssertTrue(classes.specificity < id.specificity)
        XCTAssertEqual(EPUBSelector.parse("div p.x:first-child[a]").specificity, EPUBSelector.Specificity(ids: 0, classes: 3, types: 2))
        XCTAssertEqual(EPUBSelector.parse("*").specificity, EPUBSelector.Specificity(ids: 0, classes: 0, types: 0))
    }

    func testSelectorMatchingIncludingNamespacedAttributes() throws {
        let source = """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
          <section id="s" class="chapter main"><p class="first">a</p><p>b<em class="x">c</em></p><blockquote epub:type="z3998:verse"><p><span>line</span></p></blockquote></section>
        </body></html>
        """
        let tree = try EPUBXMLDocument.parse(Data(source.utf8))
        let namespaces = ["epub": EPUBNamespace.ops]
        let paragraphs = tree.elements(named: "p")
        let em = try XCTUnwrap(tree.elements(named: "em").first)
        let span = try XCTUnwrap(tree.elements(named: "span").first)
        func matches(_ selector: String, _ node: EPUBXMLDocument.NodeID) -> Bool { EPUBSelector.parse(selector).matches(node, in: tree, namespaces: namespaces) }
        XCTAssertTrue(matches("p", paragraphs[0])); XCTAssertFalse(matches("p", em))
        XCTAssertTrue(matches("#s p", paragraphs[0])); XCTAssertTrue(matches("section > p", paragraphs[1])); XCTAssertFalse(matches("section > span", span))
        XCTAssertTrue(matches("section span", span)); XCTAssertTrue(matches(".chapter .first", paragraphs[0])); XCTAssertFalse(matches(".first", paragraphs[1]))
        XCTAssertTrue(matches("p:first-child", paragraphs[0])); XCTAssertFalse(matches("p:first-child", paragraphs[1])); XCTAssertTrue(matches("p:last-child", paragraphs[2]))
        XCTAssertTrue(matches("[epub|type~=\"z3998:verse\"] p > span", span))
        XCTAssertFalse(matches("[epub|type~=\"verse\"] span", span))
        XCTAssertTrue(matches("[epub|type]", try XCTUnwrap(tree.elements(named: "blockquote").first)))
        XCTAssertFalse(matches("[class|=\"chapter\"]", try XCTUnwrap(tree.element(withID: "s"))), "A dash match needs the whole value or a hyphenated prefix")
        XCTAssertTrue(matches("[id|=\"s\"]", try XCTUnwrap(tree.element(withID: "s"))))
        XCTAssertTrue(matches("[id=s]", try XCTUnwrap(tree.element(withID: "s"))))
        XCTAssertTrue(matches("*", em)); XCTAssertTrue(matches("em.x", em))
        for form in ["p:not(.x)", "p::first-letter", "h2 ~ p", "p + p", "p:nth-child(2)", "a:hover"] {
            let selector = EPUBSelector.parse(form)
            XCTAssertFalse(selector.isSupported, form)
            XCTAssertFalse(selector.matches(paragraphs[1], in: tree, namespaces: namespaces), form)
        }
        let counted = sheet("p:not(.x) { color: red } p + p { color: red }")
        XCTAssertEqual(counted.diagnostics.count(code: "css.unsupportedSelector"), 2)
        let escaped = EPUBSelector.parse("[epub\\:type~=\"noteref\"]")
        XCTAssertTrue(escaped.isSupported)
        let literalDocument = try EPUBXMLDocument.parse(Data("<html><body><a epub:type=\"noteref\" xmlns:epub=\"http://www.idpf.org/2007/ops\">x</a></body></html>".utf8))
        XCTAssertTrue(escaped.matches(try XCTUnwrap(literalDocument.elements(named: "a").first), in: literalDocument, namespaces: [:]))
    }

    func testMediaQueriesEvaluateOnlyTheSupportedFeatures() {
        let dark = EPUBMediaContext(isDark: true, isLandscape: false)
        XCTAssertTrue(EPUBStyleSheet.evaluateMedia("all", .default))
        XCTAssertTrue(EPUBStyleSheet.evaluateMedia("screen", .default))
        XCTAssertFalse(EPUBStyleSheet.evaluateMedia("print", .default))
        XCTAssertTrue(EPUBStyleSheet.evaluateMedia("not print", .default))
        XCTAssertTrue(EPUBStyleSheet.evaluateMedia("all and (prefers-color-scheme: dark)", dark))
        XCTAssertFalse(EPUBStyleSheet.evaluateMedia("all and (prefers-color-scheme: dark)", .default))
        XCTAssertTrue(EPUBStyleSheet.evaluateMedia("(orientation: portrait)", .default))
        XCTAssertFalse(EPUBStyleSheet.evaluateMedia("(orientation: landscape)", .default))
        XCTAssertFalse(EPUBStyleSheet.evaluateMedia("screen and (max-width: 600px)", .default))
        XCTAssertTrue(EPUBStyleSheet.evaluateMedia("print, screen", .default))
        let parsed = sheet("@media screen { p { margin: 0 } } @media print { p { color: red } } @media (prefers-color-scheme: dark) { p { color: white } }")
        XCTAssertEqual(parsed.rules.count, 1)
        XCTAssertEqual(sheet("@media (prefers-color-scheme: dark) { p { color: white } }", media: dark).rules.count, 1)
    }

    func testImportsAreInlinedFromTheContainerWithCyclesAndMissingSheetsDiagnosed() {
        let files = ["OEBPS/a.css": "@import url(b.css); p { color: red }", "OEBPS/b.css": "@import \"a.css\"; em { color: blue }", "OEBPS/print.css": "p { display: none }"]
        let parsed = sheet("@import url('a.css'); @import url(print.css) print; @import url(missing.css); h1 { color: green }", files: files)
        XCTAssertEqual(parsed.rules.map { $0.selectors[0].text }, ["em", "p", "h1"])
        XCTAssertTrue(parsed.diagnostics.contains(code: "css.importCycle"))
        XCTAssertTrue(parsed.diagnostics.contains(code: "css.importMissing"))
        XCTAssertEqual(parsed.rules.map(\.order), [0, 1, 2], "Order is global so later sheets win ties")
    }

    func testNamespaceAndFontFaceAreLifted() {
        let parsed = sheet("@namespace epub \"http://www.idpf.org/2007/ops\"; @namespace url(http://www.w3.org/1999/xhtml); @font-face { font-family: \"Lobster\"; src: local(Lobster), url(fonts/Lobster.ttf) format(\"truetype\"), url(fonts/Lobster.woff); font-weight: bold; font-style: italic } p { x: y }")
        XCTAssertEqual(parsed.namespaces["epub"], EPUBNamespace.ops)
        XCTAssertEqual(parsed.namespaces[""], EPUBNamespace.xhtml)
        XCTAssertEqual(parsed.fontFaces, [EPUBFontFace(family: "Lobster", sources: ["OEBPS/fonts/Lobster.ttf", "OEBPS/fonts/Lobster.woff"], weight: 700, italic: true)])
        XCTAssertEqual(parsed.rules.count, 1)
    }

    // MARK: Cascade

    private func styles(_ body: String, css: String = "", settings: EPUBReadingSettings = EPUBReadingSettings()) throws -> (EPUBContentDocument, [EPUBComputedStyle], EPUBDiagnosticList) {
        let document = EPUBContentDocument.parse(Data("<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><style>\(css)</style></head><body>\(body)</body></html>".utf8), path: "OEBPS/c.xhtml", publicationLanguage: "en")
        let parsed = EPUBStyleSheet.parse(css, path: "OEBPS/c.xhtml", media: .default, loader: { _ in nil }, resolve: { r, _ in r })
        var diagnostics = EPUBDiagnosticList()
        let resolved = EPUBStyleResolver(settings: settings, sheets: [parsed]).resolve(document, diagnostics: &diagnostics)
        return (document, resolved, diagnostics)
    }

    func testCascadeOrderOriginsAndImportance() throws {
        var settings = EPUBReadingSettings(); settings.publisherStyles = true
        let (document, resolved, _) = try styles("<p class=\"x\" style=\"color: black\">t</p><p class=\"x\" id=\"i\">u</p>", css: "p { color: red } .x { color: blue } p.x { color: green } #i { color: purple !important } p.x { color: orange }", settings: settings)
        let paragraphs = document.tree.elements(named: "p")
        XCTAssertEqual(resolved[paragraphs[0]].color, EPUBColor.parse("black"), "Inline beats every author rule")
        XCTAssertEqual(resolved[paragraphs[1]].color, EPUBColor.parse("purple"), "Important beats specificity")
        let (document2, resolved2, _) = try styles("<p class=\"x\" style=\"color: black\">t</p>", css: "p { color: red !important } .x { color: blue }", settings: settings)
        XCTAssertEqual(resolved2[try XCTUnwrap(document2.tree.elements(named: "p").first)].color, EPUBColor.parse("red"), "Author important beats inline normal")
        let (document3, resolved3, _) = try styles("<p class=\"x\">t</p>", css: ".a .b { color: red } .b { color: blue } p.x { color: green } .x { color: black }", settings: settings)
        XCTAssertEqual(resolved3[try XCTUnwrap(document3.tree.elements(named: "p").first)].color, EPUBColor.parse("green"))
    }

    func testUserAgentDefaultsAndSizeNormalisationWithPublisherStylesOff() throws {
        let (document, resolved, _) = try styles("<h1>a</h1><h2>b</h2><h3>c</h3><h4>d</h4><p>e<sup>1</sup><small>s</small><code>k</code></p><pre>p</pre><blockquote><p>q</p></blockquote><ul><li>i</li></ul><dd>d</dd><center>c</center><figcaption>f</figcaption>", css: "p { font-size: 30pt; font-family: Papyrus; color: red; margin: 15%; text-align: right } h1 { font-size: 10px }")
        let tree = document.tree
        func style(_ name: String) -> EPUBComputedStyle { resolved[tree.elements(named: name).first!] }
        let base = EPUBReadingSettings.bodyPointSize
        XCTAssertEqual(style("h1").fontSize, base * pow(1.2, 3), accuracy: 0.01)
        XCTAssertEqual(style("h2").fontSize, base * pow(1.2, 2), accuracy: 0.01)
        XCTAssertEqual(style("h3").fontSize, base * 1.2, accuracy: 0.01)
        XCTAssertEqual(style("h4").fontSize, base, accuracy: 0.01)
        XCTAssertEqual(style("h1").fontWeight, 700)
        XCTAssertEqual(style("p").fontSize, base, "Author sizes are dropped with publisher styles off")
        XCTAssertTrue(style("p").fontFamilies.isEmpty); XCTAssertNil(style("p").color); XCTAssertEqual(style("p").marginLeft, .points(0)); XCTAssertNil(style("p").textAlign)
        XCTAssertEqual(style("sup").fontSize, base * 0.675, accuracy: 0.01); XCTAssertEqual(style("sup").verticalAlign, .superscript)
        XCTAssertEqual(style("small").fontSize, base * 0.833, accuracy: 0.01)
        XCTAssertEqual(style("code").fontFamilies, ["monospace"])
        XCTAssertEqual(style("pre").whiteSpace, .pre); XCTAssertEqual(style("pre").fontFamilies, ["monospace"]); XCTAssertEqual(style("pre").display, .block)
        XCTAssertEqual(style("blockquote").marginLeft, .points(40))
        XCTAssertEqual(style("ul").paddingLeft, .points(40)); XCTAssertEqual(style("li").display, .listItem); XCTAssertEqual(style("ul").listStyleType, .disc)
        XCTAssertEqual(style("dd").marginLeft, .points(40))
        XCTAssertEqual(style("center").textAlign, .center)
        XCTAssertEqual(style("figcaption").textAlign, .center); XCTAssertEqual(style("figcaption").fontSize, base * 0.9, accuracy: 0.01)
        XCTAssertEqual(style("p").marginTop, .points(base), "The UA paragraph margin of 1em stays")
    }

    func testPublisherStylesOnHonoursTheSubsetAndCountsTheRest() throws {
        var settings = EPUBReadingSettings(); settings.publisherStyles = true
        let (document, resolved, diagnostics) = try styles("<p style=\"font: italic small-caps bold 12pt/1.5 Georgia, serif; text-indent: 2em; margin: 1em 15%; letter-spacing: 0.1em; text-transform: uppercase; white-space: pre-wrap; hyphens: none; text-decoration: underline line-through; page-break-before: always; break-inside: avoid; position: absolute; z-index: 2; float: right; writing-mode: vertical-rl\">t</p><p style=\"font-size: xx-large\">u</p><p style=\"font-size: 0.4em\">v</p><p style=\"font-size: 500%\">w</p><p style=\"line-height: 2; text-align: justify\">x</p>", css: "", settings: settings)
        let paragraphs = document.tree.elements(named: "p")
        let first = resolved[paragraphs[0]]
        XCTAssertEqual(first.fontSize, 16, accuracy: 0.01, "12pt CSS is 16 points")
        XCTAssertTrue(first.italic); XCTAssertTrue(first.smallCaps); XCTAssertEqual(first.fontWeight, 700); XCTAssertEqual(first.fontFamilies, ["Georgia", "serif"])
        XCTAssertEqual(first.lineHeight, .multiple(1.5))
        XCTAssertEqual(first.textIndent, .points(32)); XCTAssertEqual(first.marginLeft, .percent(15)); XCTAssertEqual(first.marginTop, .points(16))
        XCTAssertEqual(first.letterSpacing ?? 0, 1.6, accuracy: 0.01); XCTAssertEqual(first.textTransform, .uppercase); XCTAssertEqual(first.whiteSpace, .preWrap)
        XCTAssertEqual(first.hyphens, EPUBComputedStyle.Hyphens.none); XCTAssertEqual(first.decoration, [.underline, .lineThrough])
        XCTAssertTrue(first.pageBreakBefore); XCTAssertTrue(first.keepTogether); XCTAssertEqual(first.float, .right); XCTAssertEqual(first.writingMode, .verticalRL)
        XCTAssertEqual(diagnostics.count(code: "css.ignoredProperty"), 2, "\(diagnostics.items.map(\.message))")
        XCTAssertEqual(resolved[paragraphs[1]].fontSize, 34, accuracy: 0.01)
        XCTAssertEqual(resolved[paragraphs[2]].fontSize, 8.5, accuracy: 0.01, "Clamped to half the base")
        XCTAssertEqual(resolved[paragraphs[3]].fontSize, 51, accuracy: 0.01, "Clamped to three times the base")
        XCTAssertEqual(resolved[paragraphs[4]].lineHeight, .multiple(2)); XCTAssertEqual(resolved[paragraphs[4]].textAlign, .justify)
    }

    func testUserAlignmentWinsOnBodyCopyButNotHeadingsCaptionsOrQuotations() throws {
        var settings = EPUBReadingSettings(); settings.alignment = .justify; settings.publisherStyles = true
        let (document, resolved, _) = try styles("<p>a</p><h2>b</h2><figcaption>c</figcaption><blockquote>d</blockquote><li>e</li>", css: "p, h2, figcaption, blockquote, li { text-align: center }", settings: settings)
        let tree = document.tree
        XCTAssertEqual(resolved[tree.elements(named: "p")[0]].textAlign, .justify)
        XCTAssertEqual(resolved[tree.elements(named: "li")[0]].textAlign, .justify)
        XCTAssertEqual(resolved[tree.elements(named: "h2")[0]].textAlign, .center)
        XCTAssertEqual(resolved[tree.elements(named: "figcaption")[0]].textAlign, .center)
        XCTAssertEqual(resolved[tree.elements(named: "blockquote")[0]].textAlign, .center)
        var hyphenated = EPUBReadingSettings(); hyphenated.hyphenation = true
        let (document2, resolved2, _) = try styles("<p>a</p>", settings: hyphenated)
        XCTAssertEqual(resolved2[document2.tree.elements(named: "p")[0]].hyphens, .auto)
    }

    func testHiddenAndPresentationalAttributesAndInheritance() throws {
        var settings = EPUBReadingSettings(); settings.publisherStyles = true
        let (document, resolved, _) = try styles("<div hidden=\"\"><p>x</p></div><p align=\"center\" lang=\"fr\"><em>e</em></p><img width=\"80\" height=\"46\" alt=\"\"/><font color=\"red\" face=\"Courier\">f</font><ol type=\"i\"><li>r</li></ol>", css: "p { color: blue; letter-spacing: 1px }", settings: settings)
        let tree = document.tree
        XCTAssertEqual(resolved[tree.elements(named: "p")[0]].display, .none)
        XCTAssertEqual(resolved[tree.elements(named: "p")[1]].textAlign, .center)
        let em = tree.elements(named: "em")[0]
        XCTAssertEqual(resolved[em].color, EPUBColor.parse("blue")); XCTAssertEqual(resolved[em].letterSpacing, 1); XCTAssertTrue(resolved[em].italic)
        XCTAssertEqual(resolved[em].display, .inline); XCTAssertEqual(resolved[em].marginTop, .points(0))
        let image = tree.elements(named: "img")[0]
        XCTAssertEqual(resolved[image].width, .points(80)); XCTAssertEqual(resolved[image].height, .points(46))
        let font = tree.elements(named: "font")[0]
        XCTAssertEqual(resolved[font].color, EPUBColor.parse("red")); XCTAssertEqual(resolved[font].fontFamilies, ["Courier"])
        XCTAssertEqual(resolved[tree.elements(named: "ol")[0]].listStyleType, .lowerRoman)
    }

    func testLengthsColoursAndFontSizeKeywords() {
        XCTAssertEqual(EPUBLength.parse("12px", em: 10, rem: 17), .points(12))
        XCTAssertEqual(EPUBLength.parse("12pt", em: 10, rem: 17), .points(16))
        XCTAssertEqual(EPUBLength.parse("2em", em: 10, rem: 17), .points(20))
        XCTAssertEqual(EPUBLength.parse("2rem", em: 10, rem: 17), .points(34))
        XCTAssertEqual(EPUBLength.parse("50%", em: 10, rem: 17), .percent(50))
        XCTAssertEqual(EPUBLength.parse("1in", em: 10, rem: 17), .points(96))
        XCTAssertEqual(EPUBLength.parse("auto", em: 10, rem: 17), .auto)
        XCTAssertEqual(EPUBLength.parse("0.49cm", em: 10, rem: 17), .points(0.49 * 96 / 2.54))
        XCTAssertNil(EPUBLength.parse("calc(1em + 2px)", em: 10, rem: 17))
        XCTAssertNil(EPUBLength.parse("10vw", em: 10, rem: 17))
        XCTAssertEqual(EPUBColor.parse("#f00"), EPUBColor(red: 1, green: 0, blue: 0, alpha: 1))
        XCTAssertEqual(EPUBColor.parse("#FF0000"), EPUBColor(red: 1, green: 0, blue: 0, alpha: 1))
        XCTAssertEqual(EPUBColor.parse("rgb(255, 0, 0)"), EPUBColor(red: 1, green: 0, blue: 0, alpha: 1))
        XCTAssertEqual(EPUBColor.parse("rgba(0%, 100%, 0%, 0.5)"), EPUBColor(red: 0, green: 1, blue: 0, alpha: 0.5))
        XCTAssertNil(EPUBColor.parse("hsl(0 0% 0%)"))
        let settings = EPUBReadingSettings()
        XCTAssertEqual(EPUBStyleResolver.fontSize("medium", parentSize: 20, settings: settings), 17)
        XCTAssertEqual(EPUBStyleResolver.fontSize("x-large", parentSize: 20, settings: settings), 25.5)
        XCTAssertEqual(EPUBStyleResolver.fontSize("smaller", parentSize: 20, settings: settings) ?? 0, 16.66, accuracy: 0.01)
        XCTAssertEqual(EPUBStyleResolver.fontSize("larger", parentSize: 20, settings: settings), 24)
        XCTAssertEqual(EPUBStyleResolver.fontSize("150%", parentSize: 20, settings: settings), 30)
        XCTAssertEqual(EPUBStyleResolver.fontSize("1.5em", parentSize: 20, settings: settings), 30)
    }
}
