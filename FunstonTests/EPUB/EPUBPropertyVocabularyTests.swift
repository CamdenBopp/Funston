import XCTest
@testable import Funston

final class EPUBPropertyVocabularyTests: XCTestCase {
    func testStandardsExpansionTable() {
        let z3998 = EPUBPropertyVocabulary.declaredPrefixes("z3998: http://www.daisy.org/z3998/2012/vocab/structure/#")
        XCTAssertEqual(EPUBPropertyVocabulary.expand("chapter", context: .epubType), "http://idpf.org/epub/vocab/structure/#chapter")
        XCTAssertEqual(EPUBPropertyVocabulary.expand("z3998:verse", context: .epubType, declared: z3998), "http://www.daisy.org/z3998/2012/vocab/structure/#verse")
        XCTAssertEqual(EPUBPropertyVocabulary.expand("dcterms:modified", context: .metaProperty), "http://purl.org/dc/terms/modified")
        XCTAssertEqual(EPUBPropertyVocabulary.expand("rendition:layout", context: .metaProperty), "http://www.idpf.org/vocab/rendition/#layout")
        XCTAssertEqual(EPUBPropertyVocabulary.expand("media:duration", context: .metaProperty), "http://www.idpf.org/epub/vocab/overlays/#duration")
        XCTAssertEqual(EPUBPropertyVocabulary.expand("a11y:certifiedBy", context: .metaProperty), "http://www.idpf.org/epub/vocab/package/a11y/#certifiedBy")
        XCTAssertEqual(EPUBPropertyVocabulary.expand("nav", context: .manifestProperties), "http://idpf.org/epub/vocab/package/item/#nav")
        XCTAssertEqual(EPUBPropertyVocabulary.expand("page-spread-left", context: .spineProperties), "http://idpf.org/epub/vocab/package/itemref/#page-spread-left")
        XCTAssertEqual(EPUBPropertyVocabulary.expand("onix:codelist5", context: .scheme), "http://www.editeur.org/ONIX/book/codelists/current.html#codelist5")
        XCTAssertEqual(EPUBPropertyVocabulary.expand("marc:relators", context: .scheme), "http://id.loc.gov/vocabulary/relators")
        XCTAssertNil(EPUBPropertyVocabulary.expand("foo:bar", context: .epubType))
        XCTAssertNil(EPUBPropertyVocabulary.expand(":bar", context: .epubType))
        XCTAssertNil(EPUBPropertyVocabulary.expand("codelist5", context: .scheme))
        XCTAssertEqual(EPUBPropertyVocabulary.expand("title-type", context: .metaProperty), "http://idpf.org/epub/vocab/package/meta/#title-type")
    }

    func testPrefixDeclarationsOnOneLineBothSurvive() {
        let declared = EPUBPropertyVocabulary.declaredPrefixes("foo: http://example.com/# bar: http://example.org/#")
        XCTAssertEqual(declared["foo"], "http://example.com/#")
        XCTAssertEqual(declared["bar"], "http://example.org/#")
        let overriding = EPUBPropertyVocabulary.declaredPrefixes("schema: http://example.org/schema#")
        XCTAssertEqual(EPUBPropertyVocabulary.expand("schema:x", context: .metaProperty, declared: overriding), "http://example.org/schema#x", "A declaration wins over a reserved prefix")
        XCTAssertEqual(EPUBPropertyVocabulary.expandedTerms("bodymatter z3998:fiction", context: .epubType), ["http://idpf.org/epub/vocab/structure/#bodymatter"])
    }

    func testClockValues() {
        let cases: [(String, Double?)] = [
            ("0:23:23.84", 1403.84), ("23s", 23), ("1.5min", 90), ("500ms", 0.5), ("1:36:20", 5780), ("02:03", 123),
            ("0:00:00", 0), ("7", 7), ("1.5h", 5400), ("23:59.5", 1439.5), ("abc", nil),
            ("0:01:30.5", 90.5), ("1500ms", 1.5), ("2h", 7200), ("90s", 90), ("  12.25  ", 12.25), ("npt=5s", 5),
            ("123:00:00", 442_800), ("3.14159min", 188.4954), ("1.12345s", 1.12345), ("", nil), ("1:2:3:4", nil),
            ("1.", nil), (".5", nil), ("5 s", nil), ("1:61:00", 7260), ("0:00:60", 60), ("12:345", nil)
        ]
        for (text, expected) in cases {
            let actual = EPUBClockValue.seconds(text)
            if let expected { XCTAssertEqual(actual ?? -1, expected, accuracy: 0.0001, text) } else { XCTAssertNil(actual, text) }
        }
    }

    func testDates() throws {
        let formatter = ISO8601DateFormatter()
        XCTAssertEqual(EPUBDateParser.date("2024-03-05T12:34:56Z"), formatter.date(from: "2024-03-05T12:34:56Z"))
        XCTAssertEqual(EPUBDateParser.date("2024-03-05T12:34:56.123Z"), formatter.date(from: "2024-03-05T12:34:56Z"))
        XCTAssertEqual(EPUBDateParser.date("2024-03-05"), formatter.date(from: "2024-03-05T00:00:00Z"))
        XCTAssertEqual(EPUBDateParser.date("2024"), formatter.date(from: "2024-01-01T00:00:00Z"))
        XCTAssertEqual(EPUBDateParser.date("2024-03"), formatter.date(from: "2024-03-01T00:00:00Z"))
        XCTAssertEqual(EPUBDateParser.date("2024-03-05T12:34:56"), formatter.date(from: "2024-03-05T12:34:56Z"))
        XCTAssertEqual(EPUBDateParser.date("2024-03-05T12:34:56+02:00"), formatter.date(from: "2024-03-05T10:34:56Z"))
        XCTAssertNil(EPUBDateParser.date("March 2024"))
        XCTAssertNil(EPUBDateParser.date("2024-13"))
    }

    func testMediaTypes() throws {
        let html = try XCTUnwrap(EPUBMediaType("Text/HTML; Charset=utf-8"))
        XCTAssertEqual(html.description, "text/html;charset=UTF-8")
        XCTAssertTrue(html.matches(EPUBMediaType.html))
        XCTAssertTrue(EPUBMediaType.html.matches(html))
        XCTAssertFalse(try XCTUnwrap(EPUBMediaType("text/html;charset=ascii")).matches(try XCTUnwrap(EPUBMediaType("text/html;charset=utf-8"))))
        XCTAssertTrue(try XCTUnwrap(EPUBMediaType("image/jpeg")).isBitmap)
        XCTAssertTrue(try XCTUnwrap(EPUBMediaType("image/svg+xml")).isSVG)
        XCTAssertTrue(try XCTUnwrap(EPUBMediaType("application/xhtml+xml")).isContentDocument)
        XCTAssertTrue(try XCTUnwrap(EPUBMediaType("application/x-dtbncx+xml")).isNCX)
        XCTAssertTrue(try XCTUnwrap(EPUBMediaType("font/woff2")).isFont)
        XCTAssertTrue(try XCTUnwrap(EPUBMediaType("application/vnd.ms-opentype")).isFont)
        XCTAssertNil(EPUBMediaType(""))
        XCTAssertNil(EPUBMediaType("texthtml"))
        XCTAssertNil(EPUBMediaType("a/b/c"))
    }
}
