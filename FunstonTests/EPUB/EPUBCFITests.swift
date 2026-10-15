import XCTest
@testable import Funston

/// The CFI vectors of three studies: standards 9.6 (parse, rejection,
/// ordering, round trip), foliate section 9 (parse, document A, package B,
/// comparison) and epub.js section 9 (generation and comparison tables).
final class EPUBCFITests: XCTestCase {
    // MARK: Standards 9.6

    private let standardsVectors: [Int: String] = [
        1: "epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/3:10)",
        2: "epubcfi(/6/4[chap01ref]!/4[body01]/16[svgimg])",
        3: "epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/1:0)",
        4: "epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/2/1:0)",
        5: "epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/2/1:3)",
        6: "epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/2/1:3[yyy;s=b])",
        7: "epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/1:3[xx,y])",
        8: "epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/2/1:3[,y])",
        9: "epubcfi(/6/4[chap01ref]!/4[body01]/10[para05],/2/1:1,/3:4)",
        10: "epubcfi(/6/14[chap05ref]!/4[body01]/10/2/1:3[2^[1^]])",
        11: "epubcfi(/6/4!/4/10/2/1:3[Ф-\"spa ce\"-99%-aa^[bb^]^^])",
        12: "epubcfi(/6/2[titleref]!/4/2/1:0)",
        13: "epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/3:0)",
        14: "epubcfi(/6/4[chap01ref]!/4[body01]/10[para05])",
        15: "epubcfi(/6/4[chap01ref]!/4[body01]/16[svgimg]@50:30)",
        16: "epubcfi(/6/4[chap01ref]!/4[body01]/16[svgimg]@20:60)",
        17: "epubcfi(/6/6[chap02ref]!/4/2~23.5@12.3:97.6)",
        18: "epubcfi(/6/6[chap02ref]!/4/2~23.5)",
        19: "epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/1)",
        20: "epubcfi(/6/4[chap01ref]!/4[body01]/0)",
        21: "epubcfi(/6/4[chap01ref]!/4[body01]/22)",
        22: "epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/2[;s=b])",
        23: "epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/2/1:3[yyy;s=b;vnd.funston.lineid=12,13])",
        24: "epubcfi(/6/4[chap01ref])",
        25: "epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/1:0[;s=a])"
    ]

    private func vector(_ number: Int) throws -> EPUBCFI { try EPUBCFI.parse(try XCTUnwrap(standardsVectors[number])) }

    func testStandardsVectorsParseAndRoundTripExactly() throws {
        for (number, text) in standardsVectors.sorted(by: { $0.key < $1.key }) {
            let cfi = try EPUBCFI.parse(text)
            XCTAssertEqual(cfi.serialized, text, "vector \(number)")
        }
        let one = try vector(1)
        XCTAssertEqual(one.packageLevel?.steps.map(\.index), [6, 4])
        XCTAssertEqual(one.packageLevel?.steps[1].id, "chap01ref")
        XCTAssertEqual(one.documentPath?.levels.first?.steps.map(\.index), [4, 10, 3])
        XCTAssertEqual(one.path.offset?.character, 10)
        let six = try vector(6)
        XCTAssertEqual(six.path.offset?.textAssertion, EPUBCFI.TextAssertion(before: "yyy", after: nil))
        XCTAssertEqual(six.path.offset?.sideBias, .before)
        let seven = try vector(7)
        XCTAssertEqual(seven.path.offset?.textAssertion, EPUBCFI.TextAssertion(before: "xx", after: "y"))
        let eight = try vector(8)
        XCTAssertEqual(eight.path.offset?.textAssertion, EPUBCFI.TextAssertion(before: nil, after: "y"))
        let nine = try vector(9)
        XCTAssertTrue(nine.isRange)
        XCTAssertEqual(nine.rangeStart?.levels.first?.steps.map(\.index), [2, 1]); XCTAssertEqual(nine.rangeStart?.offset?.character, 1)
        XCTAssertEqual(nine.rangeEnd?.levels.first?.steps.map(\.index), [3]); XCTAssertEqual(nine.rangeEnd?.offset?.character, 4)
        XCTAssertEqual(try vector(10).path.offset?.textAssertion?.before, "2[1]")
        XCTAssertEqual(try vector(11).path.offset?.textAssertion?.before, "Ф-\"spa ce\"-99%-aa[bb]^")
        XCTAssertEqual(try vector(15).path.offset?.spatial, EPUBCFI.SpatialPoint(x: 50, y: 30))
        XCTAssertEqual(try vector(17).path.offset?.temporal, 23.5)
        XCTAssertEqual(try vector(17).path.offset?.spatial, EPUBCFI.SpatialPoint(x: 12.3, y: 97.6))
        XCTAssertNil(try vector(19).path.offset)
        let twentyTwo = try vector(22)
        XCTAssertNil(twentyTwo.path.lastStep?.id); XCTAssertEqual(twentyTwo.path.lastStep?.sideBias, .before)
        let twentyThree = try vector(23)
        XCTAssertEqual(twentyThree.path.offset?.parameters, [EPUBCFI.Parameter(name: "vnd.funston.lineid", values: ["12", "13"])])
        XCTAssertNil(try vector(24).documentPath)
        XCTAssertEqual(try vector(25).path.offset?.sideBias, .after)
    }

    func testStandardsGrammarRejections() {
        let malformed = ["epubcfi(/06/4!/4/1:3)", "epubcfi(/6/4!/4/1:3[unclosed)", "epubcfi(/6/4!!/4/2)", "epubcfi(6/4)", "epubcfi(/6/4!/4/1:3.5)",
                         "epubcfi(/6/4!/4/10[a]b]/1:0)", "epubcfi(/6/4!/4/16@1.50:20)", "epubcfi(/6/4!/4/10/x)", "epubcfi(/6/4", "", "epubcfi()", "epubcfi(/6/4!/4/16@.5:20)"]
        for text in malformed {
            XCTAssertThrowsError(try EPUBCFI.parse(text), text)
        }
        XCTAssertThrowsError(try EPUBCFI.parse("epubcfi(/6/4!/4/1:3,/2,/4)")) { XCTAssertEqual(($0 as? EPUBCFI.ParseFailure)?.reason, .rangeParentHasOffset) }
        XCTAssertThrowsError(try EPUBCFI.parse("epubcfi(/6/4!/4/1:3[a;s=b],/2,/4)")) { error in
            let reason = (error as? EPUBCFI.ParseFailure)?.reason
            XCTAssertTrue(reason == .sideBiasInRange || reason == .rangeParentHasOffset)
        }
        XCTAssertThrowsError(try EPUBCFI.parse("epubcfi(/6/4!/4/10,/2[;s=b],/4)")) { XCTAssertEqual(($0 as? EPUBCFI.ParseFailure)?.reason, .sideBiasInRange) }
        XCTAssertThrowsError(try EPUBCFI.parse("epubcfi(/6/4!/4/16@150:20)")) { XCTAssertEqual(($0 as? EPUBCFI.ParseFailure)?.reason, .spatialOutOfRange) }
        XCTAssertThrowsError(try EPUBCFI.parse("epubcfi(/6/4[chap01ref]!/4/16:3)")) { XCTAssertEqual(($0 as? EPUBCFI.ParseFailure)?.reason, .characterOffsetOnElementStep) }
        XCTAssertNoThrow(try EPUBCFI.parse("epubcfi(/6/4[chap01ref]!/4/16:3)", allowingElementCharacterOffsets: true))
        XCTAssertThrowsError(try EPUBCFI.parse("epubcfi(/6/4!/4/10/x)")) { XCTAssertEqual(($0 as? EPUBCFI.ParseFailure)?.offset, 19) }
    }

    func testStandardsOrderings() throws {
        func order(_ left: Int, _ right: Int) throws -> Int { try vector(left).compare(to: try vector(right)) }
        XCTAssertEqual(try order(12, 3), -1)
        XCTAssertEqual(try order(3, 4), -1)
        XCTAssertEqual(try order(4, 5), -1)
        XCTAssertEqual(try order(5, 6), 0)
        XCTAssertEqual(try order(13, 1), -1)
        XCTAssertEqual(try order(14, 3), -1)
        XCTAssertEqual(try order(3, 2), -1)
        XCTAssertEqual(try order(2, 15), -1)
        XCTAssertEqual(try order(15, 16), -1)
        XCTAssertEqual(try order(18, 17), -1)
        XCTAssertEqual(try order(19, 3), 0)
        XCTAssertEqual(try order(20, 3), -1)
        XCTAssertEqual(try order(2, 21), -1)
        XCTAssertEqual(try order(3, 10), -1)
        XCTAssertEqual(try order(5, 9), 1)
        XCTAssertEqual(try order(9, 1), -1)
        XCTAssertEqual(try order(22, 4), -1)
        XCTAssertEqual(try order(6, 23), 0)
        XCTAssertEqual(try order(24, 12), 1)
        XCTAssertEqual(try order(3, 25), 0)
        XCTAssertEqual(try order(7, 3), 1)
    }

    // MARK: foliate section 9

    func testFoliateParseAndSerialiseVectors() throws {
        let one = try EPUBCFI.parse("epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/3:10)")
        XCTAssertEqual(one.path.levels.count, 2)
        XCTAssertEqual(one.serialized, "epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/3:10)")
        let two = try EPUBCFI.parse("/6/4!/4/10,/2/1:1,/3:4")
        XCTAssertEqual(two.serialized, "epubcfi(/6/4!/4/10,/2/1:1,/3:4)")
        let three = try EPUBCFI.parse("epubcfi(/6/4[chap0^]!/1ref^^]!/4)")
        XCTAssertEqual(three.packageLevel?.steps[1].id, "chap0]!/1ref^")
        XCTAssertEqual(three.serialized, "epubcfi(/6/4[chap0^]!/1ref^^]!/4)")
        XCTAssertEqual(try EPUBCFI.parse("epubcfi(/6/4!/4/2~3.5@50:30)").serialized, "epubcfi(/6/4!/4/2~3.5@50:30)")
        XCTAssertEqual(try EPUBCFI.parse("epubcfi(/6/4!/4/10/3:10[xxx,yyy])").path.offset?.textAssertion, EPUBCFI.TextAssertion(before: "xxx", after: "yyy"))
        let six = try EPUBCFI.parse("epubcfi(/6/4!/4/10/3:10[,yyy;s=a])")
        XCTAssertEqual(six.path.offset?.textAssertion, EPUBCFI.TextAssertion(before: nil, after: "yyy")); XCTAssertEqual(six.path.offset?.sideBias, .after)
        XCTAssertEqual(six.serialized, "epubcfi(/6/4!/4/10/3:10[,yyy;s=a])")
        let seven = try EPUBCFI.parse("epubcfi(/6/4!/4/10[para05;s=b])")
        XCTAssertEqual(seven.path.lastStep?.id, "para05"); XCTAssertEqual(seven.path.lastStep?.sideBias, .before)
        XCTAssertEqual(seven.serialized, "epubcfi(/6/4!/4/10[para05;s=b])")
        XCTAssertEqual(try EPUBCFI.parse("epubcfi(/6/4!/4/10/3:0)").serialized, "epubcfi(/6/4!/4/10/3:0)")
        XCTAssertEqual(try EPUBCFI.parse("epubcfi(/6/4!/4/10/3:0~0)").serialized, "epubcfi(/6/4!/4/10/3:0~0)")
        XCTAssertThrowsError(try EPUBCFI.parse("epubcfi(/6/4!/4/10/x)"))
        XCTAssertEqual(try EPUBCFI.parse("  epubcfi(/6/4)  ").serialized, "epubcfi(/6/4)")
    }

    private let documentA = """
    <html xmlns="http://www.w3.org/1999/xhtml">
      <head><title>t</title></head>
      <body id="b">
        <p id="p1">One</p>
        <p id="p2">ab<em>cd</em><!-- c --><![CDATA[ef]]>gh</p>
        <img id="i1" src="x.png" alt=""/>
        <p id="p3"><span>x</span><span>y</span></p>
      </body>
    </html>
    """

    private func parseDocumentA() throws -> EPUBXMLDocument { try EPUBXMLDocument.parse(Data(documentA.utf8)) }

    private func path(_ text: String) throws -> EPUBCFI.Path {
        let cfi = try EPUBCFI.parse("epubcfi(" + text + ")")
        return cfi.path
    }

    private func resolve(_ text: String, in tree: EPUBXMLDocument) throws -> EPUBCFIResolution {
        switch EPUBCFIResolver.resolve(try path(text), in: tree) {
        case .success(let resolution): return resolution
        case .failure(let failure): throw failure
        }
    }

    func testFoliateDocumentAIndexingRoundTripsAndResolves() throws {
        let tree = try parseDocumentA()
        let body = try XCTUnwrap(tree.element(withID: "b"))
        let p1 = try XCTUnwrap(tree.element(withID: "p1")), p2 = try XCTUnwrap(tree.element(withID: "p2"))
        let img = try XCTUnwrap(tree.element(withID: "i1")), p3 = try XCTUnwrap(tree.element(withID: "p3"))
        func generated(_ position: EPUBSourcePosition) throws -> String {
            EPUBCFI.serialize(try XCTUnwrap(EPUBCFIGenerator.documentPath(to: position, in: tree, withTextAssertion: false)))
        }
        XCTAssertEqual(try generated(.element(body)), "/4[b]")
        XCTAssertEqual(try generated(.element(p1)), "/4[b]/2[p1]")
        XCTAssertEqual(try generated(.element(p2)), "/4[b]/4[p2]")
        XCTAssertEqual(try generated(.element(img)), "/4[b]/6[i1]")
        XCTAssertEqual(try generated(.element(p3)), "/4[b]/8[p3]")

        let p2Children = tree.children(of: p2)
        let em = p2Children[1], cdata = p2Children[2], gh = p2Children[3]
        XCTAssertEqual(tree[cdata].kind, .cdata); XCTAssertEqual(tree[gh].text, "gh")
        XCTAssertEqual(try generated(.text(node: gh, offset: 0)), "/4[b]/4[p2]/3:2", "The merged chunk starts with the CDATA")
        XCTAssertEqual(try resolve("/4[b]/4[p2]/3:2", in: tree).position, .text(node: cdata, offset: 2), "A boundary goes to the earlier member")
        XCTAssertEqual(try resolve("/4[b]/4[p2]/3:1", in: tree).position, .text(node: cdata, offset: 1))
        XCTAssertEqual(try resolve("/4[b]/4[p2]/3:4", in: tree).position, .text(node: gh, offset: 2))
        let carried = try resolve("/4[b]/4[p2]/3:5", in: tree)
        XCTAssertTrue(carried.offsetCarried, "An overflow is carried into the following text rather than refused")
        if case .text(let node, let offset) = carried.position { XCTAssertEqual(tree[node].text.hasPrefix("\n"), true); XCTAssertEqual(offset, 1) } else { XCTFail("\(carried.position)") }

        XCTAssertEqual(try resolve("/4[b]/8[p3]/1", in: tree).position, .boundary(parent: p3, childIndex: 0))
        XCTAssertEqual(try resolve("/4[b]/8[p3]/0", in: tree).position, .boundary(parent: p3, childIndex: 0))
        XCTAssertEqual(try resolve("/4[b]/8[p3]/6", in: tree).position, .boundary(parent: p3, childIndex: 2))
        XCTAssertEqual(try resolve("/4[b]/8[p3]/3", in: tree).position, .boundary(parent: p3, childIndex: 1))

        let cd = tree.children(of: em)[0]
        XCTAssertEqual(try generated(.text(node: cd, offset: 1)), "/4[b]/4[p2]/2/1:1")
        let ab = p2Children[0]
        let range = try XCTUnwrap(EPUBCFIGenerator.range(from: .text(node: ab, offset: 1), to: .text(node: gh, offset: 1), in: tree, packageLevel: nil))
        XCTAssertEqual(range.serialized, "epubcfi(/4[b]/4[p2],/1:1,/3:3)")
        let sameChunk = try XCTUnwrap(EPUBCFIGenerator.range(from: .text(node: gh, offset: 0), to: .text(node: gh, offset: 2), in: tree, packageLevel: nil))
        XCTAssertEqual(sameChunk.compare(to: try EPUBCFI.parse("epubcfi(/4[b]/4[p2],/3:2,/3:4)")), 0, "The factored form compares equal to the study's unfactored one")
        XCTAssertEqual(sameChunk.serialized, "epubcfi(/4[b]/4[p2]/3,:2,:4)")

        // Correction: p2's id moves to another paragraph.
        let moved = try EPUBXMLDocument.parse(Data(documentA.replacingOccurrences(of: "id=\"p1\"", with: "id=\"px\"").replacingOccurrences(of: "id=\"p2\"", with: "id=\"p1\"").replacingOccurrences(of: "id=\"px\"", with: "id=\"p2\"").utf8))
        let corrected = try resolve("/4[b]/4[p2]/1:1", in: moved)
        XCTAssertTrue(corrected.correctedByID)
        if case .text(let node, let offset) = corrected.position { XCTAssertEqual(moved[node].text, "One"); XCTAssertEqual(offset, 1) } else { XCTFail("\(corrected.position)") }
        XCTAssertThrowsError(try resolve("/4[b]/4[p2]/3:2", in: moved), "Correction lands in a paragraph with one chunk; the next step fails rather than guesses")
        let partial = try resolve("/4[b]/4[nope]/3:2", in: tree)
        XCTAssertTrue(partial.partial); XCTAssertFalse(partial.correctedByID)
        XCTAssertThrowsError(try resolve("/4[b]/40[nope]", in: tree))
        XCTAssertThrowsError(try resolve("/4[b]/40", in: tree))
        XCTAssertThrowsError(try resolve("/4[b]/3/2", in: tree), "A chunk step must be last")
    }

    func testFoliatePackageDocumentB() throws {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="u">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="u">u</dc:identifier><dc:title>T</dc:title><dc:language>en</dc:language></metadata>
          <manifest><item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/><item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/><item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest>
          <guide/>
          <spine id="s" toc="ncx"><itemref idref="cover" linear="no"/><itemref id="c1" idref="ch1"/><itemref idref="ch2"/></spine>
        </package>
        """
        let zip = try EPUBZipReader(data: EPUBFixture.archive([("OEBPS/content.opf", opf), ("OEBPS/cover.xhtml", "<x/>"), ("OEBPS/ch1.xhtml", "<x/>"), ("OEBPS/ch2.xhtml", "<x/>"), ("OEBPS/toc.ncx", "<x/>")]))
        let package = try EPUBPackageDocument.parse(Data(opf.utf8), at: "OEBPS/content.opf", in: zip, archiveData: nil)
        XCTAssertEqual(package.spineCFIStep, 8)
        XCTAssertEqual(try XCTUnwrap(EPUBCFIGenerator.packageLevel(package: package, spineIndex: 0)).steps.map(EPUBCFI.serialize).joined(), "/8/2")
        XCTAssertEqual(try XCTUnwrap(EPUBCFIGenerator.packageLevel(package: package, spineIndex: 1)).steps.map(EPUBCFI.serialize).joined(), "/8/4[c1]")
        XCTAssertEqual(try XCTUnwrap(EPUBCFIGenerator.packageLevel(package: package, spineIndex: 2)).steps.map(EPUBCFI.serialize).joined(), "/8/6")
        let byID = try XCTUnwrap(EPUBCFIResolver.spineIndex(of: try EPUBCFI.parse("epubcfi(/6/4[c1]!/4/2)"), in: package))
        XCTAssertEqual(byID.spineIndex, 1); XCTAssertTrue(byID.correctedByID)
        XCTAssertNil(EPUBCFIResolver.spineIndex(of: try EPUBCFI.parse("epubcfi(/6/4!/4/2)"), in: package), "No id and the wrong spine step: nothing to resolve")
        let dropped = try XCTUnwrap(EPUBCFIResolver.spineIndex(of: try EPUBCFI.parse("epubcfi(/8/6[ch2]!/4/2)"), in: package))
        XCTAssertEqual(dropped.spineIndex, 2); XCTAssertTrue(dropped.idDropped, "An id that names a manifest item, not an itemref, is dropped")
        XCTAssertEqual(EPUBCFIResolver.spineIndex(of: try EPUBCFI.parse("epubcfi(/8/2!/4/2)"), in: package)?.spineIndex, 0)
        XCTAssertNil(EPUBCFIResolver.spineIndex(of: try EPUBCFI.parse("epubcfi(/8/40!/4/2)"), in: package))
    }

    func testFoliateComparisonVectors() throws {
        func compare(_ a: String, _ b: String) throws -> Int { try EPUBCFI.parse(a).compare(to: try EPUBCFI.parse(b)) }
        XCTAssertEqual(try compare("/6/4!/10", "/6/4!/10"), 0)
        XCTAssertEqual(try compare("/6/4!/2/3:0", "/6/4!/2"), 1)
        XCTAssertEqual(try compare("/6/4!/2/4/6/8/10/3:0", "/6/4!/4"), -1)
        XCTAssertEqual(try compare("/6/4[x]!/4/10[y]", "/6/4!/4/10"), 0)
        XCTAssertEqual(try compare("/6/4!/4/10/3:5", "/6/4!/4/10/3:7"), -1)
        XCTAssertEqual(try compare("/6/4!/4/10/3", "/6/4!/4/10/3:0"), 0)
        XCTAssertEqual(try compare("/6/4", "/6/4!/2"), -1)
        XCTAssertEqual(try compare("/6/4!/4/10,/3:1,/3:4", "/6/4!/4/10,/3:1,/3:5"), -1)
        XCTAssertEqual(try compare("/6/4!/4/2~1@0:0", "/6/4!/4/2~2@0:0"), -1)
        XCTAssertEqual(try compare("/6/4!/4/2@10:5", "/6/4!/4/2@0:6"), -1)
    }

    // MARK: epub.js section 9

    private let epubjsDocument = """
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title></head><body><h1>Title</h1><p id="p1">Hello <em>big</em> world</p><p id="p2">Second</p><p id="p3"><em>Lead</em> tail</p><p id="p4">a<!-- c -->b</p><p id="p5">😀x</p></body></html>
    """

    func testEpubJSGenerationTable() throws {
        let tree = try EPUBXMLDocument.parse(Data(epubjsDocument.utf8))
        let package = EPUBCFI.Level(steps: [EPUBCFI.Step(index: 6), EPUBCFI.Step(index: 2, id: "c1")])
        func cfi(_ position: EPUBSourcePosition) throws -> String {
            let document = try XCTUnwrap(EPUBCFIGenerator.documentPath(to: position, in: tree, withTextAssertion: false))
            return EPUBCFI(path: EPUBCFI.Path(levels: [package] + document.levels, offset: document.offset)).serialized
        }
        let body = try XCTUnwrap(tree.elements(named: "body").first)
        let h1 = try XCTUnwrap(tree.elements(named: "h1").first)
        let p1 = try XCTUnwrap(tree.element(withID: "p1")), p2 = try XCTUnwrap(tree.element(withID: "p2"))
        let p3 = try XCTUnwrap(tree.element(withID: "p3")), p4 = try XCTUnwrap(tree.element(withID: "p4")), p5 = try XCTUnwrap(tree.element(withID: "p5"))
        XCTAssertEqual(try cfi(.element(h1)), "epubcfi(/6/2[c1]!/4/2)")
        XCTAssertEqual(try cfi(.element(p1)), "epubcfi(/6/2[c1]!/4/4[p1])")
        let hello = tree.children(of: p1)[0], em = tree.children(of: p1)[1], world = tree.children(of: p1)[2]
        XCTAssertEqual(try cfi(.text(node: hello, offset: 2)), "epubcfi(/6/2[c1]!/4/4[p1]/1:2)")
        XCTAssertEqual(try cfi(.element(em)), "epubcfi(/6/2[c1]!/4/4[p1]/2)")
        XCTAssertEqual(try cfi(.text(node: tree.children(of: em)[0], offset: 0)), "epubcfi(/6/2[c1]!/4/4[p1]/2/1:0)")
        XCTAssertEqual(try cfi(.text(node: world, offset: 1)), "epubcfi(/6/2[c1]!/4/4[p1]/3:1)")
        XCTAssertEqual(try cfi(.text(node: tree.children(of: p2)[0], offset: 0)), "epubcfi(/6/2[c1]!/4/6[p2]/1:0)")
        XCTAssertEqual(try cfi(.text(node: tree.children(of: p3)[1], offset: 0)), "epubcfi(/6/2[c1]!/4/8[p3]/3:0)")
        XCTAssertEqual(tree.children(of: p4).count, 1, "The comment never splits the text")
        XCTAssertEqual(try cfi(.text(node: tree.children(of: p4)[0], offset: 1)), "epubcfi(/6/2[c1]!/4/10[p4]/1:1)")
        XCTAssertEqual(try cfi(.text(node: tree.children(of: p5)[0], offset: 2)), "epubcfi(/6/2[c1]!/4/12[p5]/1:2)")
        _ = body
        let range = try XCTUnwrap(EPUBCFIGenerator.range(from: .text(node: hello, offset: 0), to: .text(node: tree.children(of: p2)[0], offset: 6), in: tree, packageLevel: package))
        XCTAssertEqual(range.serialized, "epubcfi(/6/2[c1]!/4,/4[p1]/1:0,/6[p2]/1:6)")
        let inside = try XCTUnwrap(EPUBCFIGenerator.range(from: .text(node: hello, offset: 1), to: .text(node: hello, offset: 4), in: tree, packageLevel: package))
        XCTAssertEqual(inside.serialized, "epubcfi(/6/2[c1]!/4/4[p1]/1,:1,:4)")
        let unfactored = try EPUBCFI.parse("epubcfi(/6/2[c1]!/4/4[p1],/1:1,/1:4)")
        XCTAssertEqual(inside.compare(to: unfactored), 0)
        XCTAssertEqual(try cfi(.boundary(parent: p1, childIndex: 1)), "epubcfi(/6/2[c1]!/4/4[p1]/2)", "A DOM position before the second child is the em's step")
        XCTAssertEqual(try cfi(.boundary(parent: p1, childIndex: 2)), "epubcfi(/6/2[c1]!/4/4[p1]/3:0)")
        XCTAssertEqual(try cfi(.boundary(parent: p1, childIndex: 3)), "epubcfi(/6/2[c1]!/4/4[p1]/3:6)")
        let commaDocument = try EPUBXMLDocument.parse(Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p id=\"a,b\">x</p></body></html>".utf8))
        let commaParagraph = try XCTUnwrap(commaDocument.elements(named: "p").first)
        let commaPath = try XCTUnwrap(EPUBCFIGenerator.documentPath(to: .element(commaParagraph), in: commaDocument))
        XCTAssertEqual(EPUBCFI.serialize(commaPath), "/2/2[a^,b]")
        XCTAssertEqual(try EPUBCFI.parse("epubcfi(/2/2[a^,b])").path.lastStep?.id, "a,b")
    }

    func testEpubJSComparisonTable() throws {
        func compare(_ a: String, _ b: String) throws -> Int { try EPUBCFI.parse(a, allowingElementCharacterOffsets: true).compare(to: try EPUBCFI.parse(b, allowingElementCharacterOffsets: true)) }
        XCTAssertEqual(try compare("/6/4!/4/2", "/6/2!/4/8"), 1)
        XCTAssertEqual(try compare("/6/2!/4/8/1:273", "/6/2!/4/8/2/1:4"), -1)
        XCTAssertEqual(try compare("/6/2!/4/6", "/6/2!/4/6/8/1:0"), -1)
        XCTAssertEqual(try compare("/6/2!/4/5:1", "/6/2!/4/5:0"), 1)
        XCTAssertEqual(try compare("/6/2[x]!/4/8/1:0", "/6/2[y]!/4/8/1:0"), 0)
        // The spec compares a missing offset as 0, so this pair is equal (the study's own table says earlier).
        XCTAssertEqual(try compare("/6/2!/4/8/1", "/6/2!/4/8/1:0"), 0)
        XCTAssertEqual(try compare("/6/2!/4/10:3", "/6/2!/4/10/2"), -1, "A character offset sorts before a child step at the same position")
    }

    func testTextAssertionsAreGeneratedAndChecked() throws {
        let tree = try EPUBXMLDocument.parse(Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>The   quick brown fox</p><p>jumps over   the lazy dog</p></body></html>".utf8))
        let second = tree.children(of: tree.elements(named: "p")[1])[0]
        let path = try XCTUnwrap(EPUBCFIGenerator.documentPath(to: .text(node: second, offset: 5), in: tree))
        XCTAssertEqual(path.offset?.textAssertion, EPUBCFI.TextAssertion(before: "The quick brown foxjumps", after: " over the lazy dog"))
        XCTAssertEqual(EPUBCFI.serialize(path), "/2/4/1:5[The quick brown foxjumps, over the lazy dog]")
        let matched = try resolve("/2/4/1:5[The quick brown foxjumps, over the lazy dog]", in: tree)
        XCTAssertFalse(matched.textAssertionMismatch)
        let mismatched = try resolve("/2/4/1:5[Something else, nope]", in: tree)
        XCTAssertTrue(mismatched.textAssertionMismatch)
        XCTAssertEqual(mismatched.position, .text(node: second, offset: 5), "A mismatch is recorded, not a failure")
        let long = try EPUBXMLDocument.parse(Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>\(String(repeating: "a", count: 50))X\(String(repeating: "b", count: 50))</p></body></html>".utf8))
        let node = tree.children(of: long.elements(named: "p")[0])[0]
        let assertion = try XCTUnwrap(EPUBCFIGenerator.textAssertion(at: .text(node: node, offset: 50), in: long))
        XCTAssertEqual(assertion.before?.count, 32); XCTAssertEqual(assertion.after?.count, 32)
    }

    func testCarriedOffsetsTemporalAndSpatialAreCarriedNotUsed() throws {
        let tree = try parseDocumentA()
        let img = try XCTUnwrap(tree.element(withID: "i1"))
        let spatial = try resolve("/4[b]/6[i1]@50:30", in: tree)
        XCTAssertEqual(spatial.position, .element(img))
        XCTAssertEqual(spatial.spatial, EPUBCFI.SpatialPoint(x: 50, y: 30))
        let temporal = try resolve("/4[b]/6[i1]~23.5", in: tree)
        XCTAssertEqual(temporal.temporal, 23.5)
        XCTAssertThrowsError(try resolve("/4[b]/6[i1]!/4", in: tree))
    }
}
