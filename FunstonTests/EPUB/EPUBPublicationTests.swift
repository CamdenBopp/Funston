import XCTest
@testable import Funston

final class EPUBPublicationTests: XCTestCase {
    func testMinimalEPUB3WithNavOnlyOpens() throws {
        let publication = try EPUBPublication.open(data: EPUBFixture.minimalBook())
        XCTAssertEqual(publication.title, "Fixture")
        XCTAssertEqual(publication.package.spine.count, 1)
        XCTAssertEqual(publication.navigation.contents.first?.label, "Chapter 1")
        XCTAssertEqual(publication.startTarget, EPUBTarget(spineIndex: 0, fragment: nil))
        XCTAssertFalse(publication.isFixedLayout)
        XCTAssertFalse(publication.hasMediaOverlays)
        XCTAssertEqual(publication.weights.count, 1)
        XCTAssertGreaterThan(publication.totalWeight, 0)
        XCTAssertEqual(publication.releaseIdentifier, "urn:uuid:12345678-1234-1234-1234-123456789abc@2026-10-15T00:00:00Z")
    }

    func testRefusalsCarryTheUserFacingSentence() throws {
        XCTAssertThrowsError(try EPUBPublication.open(data: Data("nope".utf8))) { XCTAssertEqual($0 as? EPUBOpenFailure, .notABook) }
        let noContainer = EPUBFixture.archive([("OEBPS/ch1.xhtml", "<x/>"), ("OEBPS/a.opf", "<p/>"), ("OEBPS/b.opf", "<p/>")])
        XCTAssertThrowsError(try EPUBPublication.open(data: noContainer)) { XCTAssertEqual($0 as? EPUBOpenFailure, .notABook) }
        let badPackage = EPUBFixture.archive([("META-INF/container.xml", EPUBFixture.container), ("OEBPS/content.opf", "<package><metadata>")])
        XCTAssertThrowsError(try EPUBPublication.open(data: badPackage)) { error in
            guard case .damaged = error as? EPUBOpenFailure else { return XCTFail("\(error)") }
            XCTAssertEqual((error as? EPUBOpenFailure)?.message, "The book's file looks damaged. Try downloading it again.")
        }
        let missingPackage = EPUBFixture.archive([("META-INF/container.xml", EPUBFixture.container), ("OEBPS/other.opf", "<package/>")])
        XCTAssertThrowsError(try EPUBPublication.open(data: missingPackage)) { error in
            // container.xml names a missing package; the single other .opf is used and is empty.
            guard case .damaged = error as? EPUBOpenFailure else { return XCTFail("\(error)") }
        }
        let emptySpine = EPUBFixture.archive([("META-INF/container.xml", EPUBFixture.container), ("OEBPS/content.opf", EPUBFixture.package().replacingOccurrences(of: "<itemref idref=\"ch1\"/>", with: ""))])
        XCTAssertThrowsError(try EPUBPublication.open(data: emptySpine)) { error in
            guard case .damaged = error as? EPUBOpenFailure else { return XCTFail("\(error)") }
        }
        let locked = EPUBFixture.archive([("META-INF/container.xml", EPUBFixture.container), ("META-INF/license.lcpl", "{}"), ("OEBPS/content.opf", EPUBFixture.package())])
        XCTAssertThrowsError(try EPUBPublication.open(data: locked)) { XCTAssertEqual($0 as? EPUBOpenFailure, .protected) }
        XCTAssertEqual(EPUBOpenFailure.protected.message, "This book is protected and can't be opened here.")
        XCTAssertEqual(EPUBOpenFailure.notABook.message, "The file isn't a book this app can read.")
    }

    func testEncryptedSpineItemIsProtectedButAnEncryptedImageIsNot() throws {
        func encryption(_ path: String) -> String {
            """
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
              <enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes256-cbc"/>
                <enc:CipherData><enc:CipherReference URI="\(path)"/></enc:CipherData></enc:EncryptedData></encryption>
            """
        }
        let base: [(String, String)] = [("META-INF/container.xml", EPUBFixture.container), ("OEBPS/content.opf", EPUBFixture.package(extraManifest: "<item id=\"img\" href=\"a.png\" media-type=\"image/png\"/>")), ("OEBPS/nav.xhtml", EPUBFixture.nav), ("OEBPS/ch1.xhtml", EPUBFixture.chapter("<p>x</p>")), ("OEBPS/a.png", "png")]
        XCTAssertThrowsError(try EPUBPublication.open(data: EPUBFixture.archive(base + [("META-INF/encryption.xml", encryption("OEBPS/ch1.xhtml"))]))) { XCTAssertEqual($0 as? EPUBOpenFailure, .protected) }
        let publication = try EPUBPublication.open(data: EPUBFixture.archive(base + [("META-INF/encryption.xml", encryption("OEBPS/a.png"))]))
        XCTAssertThrowsError(try publication.resource(at: "OEBPS/a.png")) { XCTAssertEqual($0 as? EPUBPublication.ResourceFailure, .protected) }
        XCTAssertEqual(try publication.resource(at: "OEBPS/ch1.xhtml").count, EPUBFixture.chapter("<p>x</p>").utf8.count)
        XCTAssertThrowsError(try publication.resource(at: "OEBPS/none")) { XCTAssertEqual($0 as? EPUBPublication.ResourceFailure, .missing) }
    }

    func testObfuscatedFontsAreDecodedOnReadAndAFailureIsADiagnostic() throws {
        let identifier = "urn:uuid:12345678-1234-1234-1234-123456789abc"
        var font = Data("OTTO".utf8); font.append(contentsOf: [0, 9]); font.append(Data(repeating: 7, count: 1500))
        let key = try XCTUnwrap(EPUBFontObfuscation.idpfKey(uniqueIdentifier: identifier))
        let obfuscated = EPUBFontObfuscation.apply(key: key, prefixLength: EPUBFontObfuscation.idpfPrefixLength, to: font)
        let encryption = """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/><enc:CipherData><enc:CipherReference URI="OEBPS/f.otf"/></enc:CipherData></enc:EncryptedData>
          <enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/><enc:CipherData><enc:CipherReference URI="OEBPS/bad.otf"/></enc:CipherData></enc:EncryptedData>
        </encryption>
        """
        var fixture = ZipFixture([ZipFixture.Entry("mimetype", text: "application/epub+zip", deflate: false)])
        fixture.entries.append(ZipFixture.Entry("META-INF/container.xml", text: EPUBFixture.container))
        fixture.entries.append(ZipFixture.Entry("META-INF/encryption.xml", text: encryption))
        fixture.entries.append(ZipFixture.Entry("OEBPS/content.opf", text: EPUBFixture.package(identifier: identifier, extraManifest: "<item id=\"f\" href=\"f.otf\" media-type=\"font/otf\"/><item id=\"bad\" href=\"bad.otf\" media-type=\"font/otf\"/>")))
        fixture.entries.append(ZipFixture.Entry("OEBPS/nav.xhtml", text: EPUBFixture.nav))
        fixture.entries.append(ZipFixture.Entry("OEBPS/ch1.xhtml", text: EPUBFixture.chapter("<p>x</p>")))
        fixture.entries.append(ZipFixture.Entry("OEBPS/f.otf", obfuscated))
        fixture.entries.append(ZipFixture.Entry("OEBPS/bad.otf", Data(repeating: 1, count: 2000)))
        let publication = try EPUBPublication.open(data: fixture.build())
        var diagnostics = EPUBDiagnosticList()
        XCTAssertEqual(try publication.resource(at: "OEBPS/f.otf", diagnostics: &diagnostics), font)
        XCTAssertThrowsError(try publication.resource(at: "OEBPS/bad.otf", diagnostics: &diagnostics)) { XCTAssertEqual($0 as? EPUBPublication.ResourceFailure, .unreadable) }
        XCTAssertEqual(diagnostics.count(code: EPUBPublication.fontDeobfuscationDiagnostic), 1)
    }

    func testStartTargetSkipsANonLinearCoverWrapper() throws {
        let package = """
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="u">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="u">u</dc:identifier><dc:title>T</dc:title><dc:language>en</dc:language></metadata>
          <manifest><item id="wrap" href="wrap0000.html" media-type="application/xhtml+xml"/><item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest>
          <spine toc="ncx"><itemref idref="wrap" linear="no"/><itemref idref="ch1"/></spine>
          <guide><reference type="cover" href="wrap0000.html"/></guide>
        </package>
        """
        let ncx = "<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\"><navMap><navPoint><navLabel><text>One</text></navLabel><content src=\"ch1.xhtml\"/></navPoint><navPoint><navLabel><text>Two</text></navLabel><content src=\"ch1.xhtml#p\"/></navPoint></navMap></ncx>"
        let publication = try EPUBPublication.open(data: EPUBFixture.archive([
            ("META-INF/container.xml", EPUBFixture.container), ("OEBPS/content.opf", package), ("OEBPS/toc.ncx", ncx),
            ("OEBPS/wrap0000.html", "<html><body><img src=\"cover.jpg\" alt=\"Cover\"/></body></html>"), ("OEBPS/ch1.xhtml", EPUBFixture.chapter("<p id=\"p\">x</p>"))
        ]))
        XCTAssertEqual(publication.startTarget, EPUBTarget(spineIndex: 1, fragment: nil))
        XCTAssertEqual(publication.weights[0], 0, "Non-linear items weigh nothing")
        XCTAssertGreaterThan(publication.weights[1], 0)
        XCTAssertEqual(publication.navigation.landmarks.first?.semanticTerms, [EPUBPropertyVocabulary.structuralSemantics + "cover"])
    }

    func testFixedLayoutAndNarrationAreDetectedAndDiagnosed() throws {
        let fixed = EPUBFixture.archive([
            ("META-INF/container.xml", EPUBFixture.container),
            ("OEBPS/content.opf", EPUBFixture.package(extraMetadata: "<meta property=\"rendition:layout\">pre-paginated</meta>", extraManifest: "<item id=\"smil\" href=\"ch1.smil\" media-type=\"application/smil+xml\"/>").replacingOccurrences(of: "<item id=\"ch1\" href=\"ch1.xhtml\" media-type=\"application/xhtml+xml\"/>", with: "<item id=\"ch1\" href=\"ch1.xhtml\" media-type=\"application/xhtml+xml\" media-overlay=\"smil\"/>")),
            ("OEBPS/nav.xhtml", EPUBFixture.nav), ("OEBPS/ch1.xhtml", EPUBFixture.chapter("<p>x</p>")), ("OEBPS/ch1.smil", "<smil/>")
        ])
        let publication = try EPUBPublication.open(data: fixed)
        XCTAssertTrue(publication.isFixedLayout)
        XCTAssertTrue(publication.hasMediaOverlays)
        XCTAssertTrue(publication.diagnostics.contains(code: "rendition.fixedLayout"))
        XCTAssertTrue(publication.diagnostics.contains(code: "mediaOverlay.detected"))
    }
}
