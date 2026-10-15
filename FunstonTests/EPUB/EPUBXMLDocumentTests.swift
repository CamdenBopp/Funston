import XCTest
@testable import Funston

final class EPUBXMLDocumentTests: XCTestCase {
    func testKeepsTheExactChildSequenceIncludingWhitespaceAndCDATA() throws {
        let document = try EPUBXMLDocument.parse(Data("<a> <b/>x<![CDATA[y]]>z<!-- c --><?pi x?>w</a>".utf8))
        let root = try XCTUnwrap(document.documentElement)
        let kinds = document.children(of: root).map { document[$0].kind }
        XCTAssertEqual(kinds, [.text, .element, .text, .cdata, .text])
        XCTAssertEqual(document.children(of: root).map { document[$0].text }, [" ", "", "x", "y", "zw"])
        XCTAssertEqual(document.textContent(of: root), " xyzw")
        XCTAssertEqual(document[document.children(of: root)[0]].utf16Length, 1)
    }

    func testNamespacedElementsAndAttributesResolveThroughPrefixes() throws {
        let source = """
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" unique-identifier="u">
          <metadata><dc:creator opf:role="aut" xmlns:opf="http://www.idpf.org/2007/opf" xml:lang="en">Glyn,&#160;Elinor &amp; Co</dc:creator>
          <meta property="dcterms:modified">2026</meta></metadata>
        </package>
        """
        let document = try EPUBXMLDocument.parse(Data(source.utf8))
        let root = try XCTUnwrap(document.documentElement)
        XCTAssertTrue(document.isElement(root, "package", namespace: EPUBNamespace.opf))
        XCTAssertEqual(document.attribute("unique-identifier", of: root), "u")
        let creator = try XCTUnwrap(document.elements(named: "creator", namespace: EPUBNamespace.dublinCore).first)
        XCTAssertEqual(document.attribute("role", namespace: EPUBNamespace.opf, of: creator), "aut")
        XCTAssertEqual(document.attribute("role", of: creator), "aut", "An unqualified lookup accepts any namespace as a fallback")
        XCTAssertNil(document.attribute("role", namespace: EPUBNamespace.dublinCore, of: creator))
        XCTAssertEqual(document.language(of: creator), "en")
        XCTAssertEqual(document.textContent(of: creator), "Glyn,\u{A0}Elinor & Co")
        XCTAssertEqual(document.collapsedText(of: creator), "Glyn,\u{A0}Elinor & Co")
        XCTAssertEqual(document.elements(named: "meta").count, 1)
    }

    func testEpubTypeIsAcceptedByNamespaceAndByLiteralName() throws {
        let namespaced = try EPUBXMLDocument.parse(Data("<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><body epub:type=\"bodymatter chapter\"/></html>".utf8))
        let body = try XCTUnwrap(namespaced.elements(named: "body").first)
        XCTAssertEqual(namespaced.epubType(of: body), "bodymatter chapter")
        let literal = EPUBXMLDocument(nodes: [
            EPUBXMLDocument.Node(kind: .element, name: "body", namespaceURI: nil,
                                 attributes: [EPUBXMLDocument.Attribute(namespaceURI: nil, localName: "epub:type", qualifiedName: "epub:type", value: "chapter")],
                                 text: "", parent: nil, children: [], utf16Length: 0)
        ], documentElement: 0)
        XCTAssertEqual(literal.epubType(of: 0), "chapter")
    }

    func testMalformedDocumentsReportCodeLineAndColumn() {
        XCTAssertThrowsError(try EPUBXMLDocument.parse(Data("<a><b></a>".utf8))) { error in
            let failure = error as? EPUBXMLDocument.ParseFailure
            XCTAssertNotNil(failure)
            XCTAssertGreaterThan(failure?.line ?? 0, 0)
        }
        XCTAssertThrowsError(try EPUBXMLDocument.parse(Data("<p>a&nbsp;b</p>".utf8)))
        XCTAssertThrowsError(try EPUBXMLDocument.parse(Data()))
    }

    func testHostileNestingStopsAtTheDepthCap() {
        let depth = EPUBXMLDocument.maximumDepth + 50
        let source = String(repeating: "<d>", count: depth) + String(repeating: "</d>", count: depth)
        XCTAssertThrowsError(try EPUBXMLDocument.parse(Data(source.utf8)))
        let allowed = String(repeating: "<d>", count: 100) + String(repeating: "</d>", count: 100)
        XCTAssertNoThrow(try EPUBXMLDocument.parse(Data(allowed.utf8)))
    }

    func testWhitespaceCollapsingAndIDLookup() throws {
        let document = try EPUBXMLDocument.parse(Data("<r><a id=\"x\">  Chapter\n   One </a><b id=\"y\"/></r>".utf8))
        let a = try XCTUnwrap(document.element(withID: "x"))
        XCTAssertEqual(document.collapsedText(of: a), "Chapter One")
        XCTAssertNotNil(document.element(withID: "y"))
        XCTAssertNil(document.element(withID: "z"))
        XCTAssertEqual(document.ancestors(of: a).count, 1)
    }
}
