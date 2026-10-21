import XCTest
@testable import Funston

/// The standards study's href resolution table (section 9.8), the Readium
/// streamer vectors V-01 to V-03 and V-06 to V-08, and the Swift parsers' V3.
final class EPUBHrefTests: XCTestCase {
    private func container() throws -> EPUBZipReader {
        try EPUBZipReader(data: ZipFixture([
            ZipFixture.Entry("mimetype", text: "application/epub+zip", deflate: false),
            ZipFixture.Entry("META-INF/container.xml", text: "<c/>"),
            ZipFixture.Entry("EPUB/package.opf", text: "<p/>"),
            ZipFixture.Entry("EPUB/text/ch1.xhtml", text: "<h/>"),
            ZipFixture.Entry("EPUB/images/Cafe\u{301}.png", text: "nfd"),
            ZipFixture.Entry("EPUB/images/Cover.png", text: "cover"),
            ZipFixture.Entry("EPUB/images/plate 1.jpg", text: "plate"),
            ZipFixture.Entry("EPUB/css/style.css", text: "css"),
            ZipFixture.Entry("EPUB/text/ch 2+.xhtml", text: "space"),
            ZipFixture.Entry("EPUB/text/東京.xhtml", text: "tokyo")
        ]).build())
    }

    private func resolve(_ reference: String, from base: String) throws -> (EPUBReference, [String]) {
        var diagnostics = EPUBDiagnosticList()
        let result = EPUBHref.resolve(reference, from: base, in: try container(), diagnostics: &diagnostics)
        return (result, diagnostics.items.map(\.code))
    }

    func testStandardsResolutionTable() throws {
        var (reference, codes) = try resolve("text/ch1.xhtml", from: "EPUB/package.opf")
        XCTAssertEqual(reference.entry, "EPUB/text/ch1.xhtml"); XCTAssertEqual(codes, [])

        (reference, codes) = try resolve("../images/Caf%C3%A9.png", from: "EPUB/text/ch1.xhtml")
        XCTAssertEqual(reference.entry, "EPUB/images/Cafe\u{301}.png"); XCTAssertEqual(codes, ["href.normalizationFallback"])

        (reference, codes) = try resolve("../images/plate%201.jpg", from: "EPUB/text/ch1.xhtml")
        XCTAssertEqual(reference.entry, "EPUB/images/plate 1.jpg"); XCTAssertEqual(codes, [])

        (reference, codes) = try resolve("../images/plate 1.jpg", from: "EPUB/text/ch1.xhtml")
        XCTAssertEqual(reference.entry, "EPUB/images/plate 1.jpg"); XCTAssertEqual(codes, ["href.rawSpace"])

        (reference, codes) = try resolve("/EPUB/css/style.css", from: "EPUB/text/ch1.xhtml")
        XCTAssertEqual(reference.entry, "EPUB/css/style.css"); XCTAssertEqual(codes, ["href.pathAbsolute"])

        (reference, codes) = try resolve("../../../../EPUB/css/style.css", from: "EPUB/text/ch1.xhtml")
        XCTAssertEqual(reference.entry, "EPUB/css/style.css"); XCTAssertEqual(codes, ["href.leakingRelative"])

        (reference, codes) = try resolve("ch1.xhtml#note-3", from: "EPUB/text/ch1.xhtml")
        XCTAssertEqual(reference.entry, "EPUB/text/ch1.xhtml"); XCTAssertEqual(reference.fragment, "note-3"); XCTAssertEqual(codes, [])

        (reference, codes) = try resolve("images/cover.png", from: "EPUB/package.opf")
        XCTAssertEqual(reference.entry, "EPUB/images/Cover.png"); XCTAssertEqual(codes, ["href.caseFallback"])

        (reference, codes) = try resolve("images/COVER.PNG", from: "EPUB/package.opf")
        XCTAssertEqual(reference.entry, "EPUB/images/Cover.png"); XCTAssertEqual(codes, ["href.caseFallback"])

        (reference, codes) = try resolve("images/missing.png", from: "EPUB/package.opf")
        XCTAssertNil(reference.entry); XCTAssertEqual(reference.path, "EPUB/images/missing.png"); XCTAssertEqual(codes, ["resource.missing"])

        (reference, codes) = try resolve("https://example.org/x.png", from: "EPUB/text/ch1.xhtml")
        XCTAssertEqual(reference.kind, .external); XCTAssertEqual(codes, ["resource.remote"])

        (reference, codes) = try resolve("file:///etc/passwd", from: "EPUB/text/ch1.xhtml")
        XCTAssertEqual(reference.kind, .refused); XCTAssertEqual(codes, ["resource.forbiddenScheme"])

        (reference, codes) = try resolve("javascript:alert(1)", from: "EPUB/text/ch1.xhtml")
        XCTAssertEqual(reference.kind, .refused)

        (reference, codes) = try resolve("../../META-INF/container.xml", from: "EPUB/text/ch1.xhtml")
        XCTAssertEqual(reference.entry, "META-INF/container.xml"); XCTAssertEqual(codes, ["href.metaInf"])

        (reference, codes) = try resolve("text/ch1.xhtml?x=1", from: "EPUB/package.opf")
        XCTAssertEqual(reference.entry, "EPUB/text/ch1.xhtml"); XCTAssertEqual(codes, ["href.queryDropped"])

        (reference, codes) = try resolve("data:image/png;base64,AAAA", from: "EPUB/text/ch1.xhtml")
        XCTAssertEqual(reference.kind, .data)

        (reference, codes) = try resolve("#top", from: "EPUB/text/ch1.xhtml")
        XCTAssertEqual(reference.entry, "EPUB/text/ch1.xhtml"); XCTAssertEqual(reference.fragment, "top")

        (reference, codes) = try resolve("mailto:someone@example.org", from: "EPUB/text/ch1.xhtml")
        XCTAssertEqual(reference.kind, .external)
    }

    func testReadiumStreamerResolutionVectors() throws {
        var diagnostics = EPUBDiagnosticList()
        XCTAssertEqual(EPUBHref.resolve("text/ch1.xhtml", from: "OEBPS/content.opf", in: nil, diagnostics: &diagnostics).path, "OEBPS/text/ch1.xhtml")
        XCTAssertEqual(EPUBHref.resolve("../images/a.png", from: "OEBPS/content.opf", in: nil, diagnostics: &diagnostics).path, "images/a.png")
        let fragmentOnly = EPUBHref.resolve("#toc", from: "OEBPS/nav.xhtml", in: nil, diagnostics: &diagnostics)
        XCTAssertEqual(fragmentOnly.path, "OEBPS/nav.xhtml"); XCTAssertEqual(fragmentOnly.fragment, "toc")
        XCTAssertEqual(EPUBHref.resolve("a/./b/../c.xhtml", from: "x.opf", in: nil, diagnostics: &diagnostics).path, "a/c.xhtml")
        XCTAssertEqual(EPUBHref.resolve("ch1.xhtml", from: "", in: nil, diagnostics: &diagnostics).path, "ch1.xhtml")
    }

    func testHrefRepairKeepsFragmentAndQuerySeparators() {
        XCTAssertEqual(EPUBHref.repaired("text/ch 1.xhtml"), "text/ch%201.xhtml")
        XCTAssertEqual(EPUBHref.repaired("text/ch 1.xhtml#p3"), "text/ch%201.xhtml#p3")
        XCTAssertEqual(EPUBHref.repaired("a b.xhtml?x=1#f?g"), "a%20b.xhtml?x=1#f?g")
        XCTAssertEqual(EPUBHref.repaired("text/ch%201.xhtml"), "text/ch%201.xhtml", "Existing encoding is not doubled")
        XCTAssertEqual(EPUBHref.repaired("100%.xhtml"), "100%25.xhtml")
        XCTAssertEqual(EPUBHref.repaired("caf\u{E9}.xhtml"), "caf%C3%A9.xhtml")
    }

    func testPathsWithSpacesAccentsPlusSignsAndNonLatinScriptsResolve() throws {
        var (reference, _) = try resolve("ch%202%2B.xhtml", from: "EPUB/text/ch1.xhtml")
        XCTAssertEqual(reference.entry, "EPUB/text/ch 2+.xhtml")
        (reference, _) = try resolve("ch 2+.xhtml", from: "EPUB/text/ch1.xhtml")
        XCTAssertEqual(reference.entry, "EPUB/text/ch 2+.xhtml", "A plus sign is never decoded as a space")
        (reference, _) = try resolve("%E6%9D%B1%E4%BA%AC.xhtml", from: "EPUB/text/ch1.xhtml")
        XCTAssertEqual(reference.entry, "EPUB/text/東京.xhtml")
        (reference, _) = try resolve("東京.xhtml", from: "EPUB/text/ch1.xhtml")
        XCTAssertEqual(reference.entry, "EPUB/text/東京.xhtml")
        (reference, _) = try resolve("../images/Caf\u{E9}.png", from: "EPUB/text/ch1.xhtml")
        XCTAssertEqual(reference.entry, "EPUB/images/Cafe\u{301}.png")
    }

    func testBackslashSeparatorsFallBackWithADiagnostic() throws {
        let zip = try EPUBZipReader(data: ZipFixture([ZipFixture.Entry("OEBPS\\ch1.xhtml", text: "x")]).build())
        var diagnostics = EPUBDiagnosticList()
        let reference = EPUBHref.resolve("OEBPS/ch1.xhtml", from: "", in: zip, diagnostics: &diagnostics)
        XCTAssertEqual(reference.entry, "OEBPS\\ch1.xhtml")
        XCTAssertTrue(diagnostics.contains(code: "href.backslash"))
    }
}
