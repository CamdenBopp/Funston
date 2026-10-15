import XCTest
@testable import Funston

final class EPUBContainerFileTests: XCTestCase {
    private func open(_ data: Data) throws -> EPUBContainerFile {
        try EPUBContainerFile.read(from: try EPUBZipReader(data: data))
    }

    private let packageFiles: [(String, String)] = [
        ("META-INF/container.xml", EPUBFixture.container),
        ("OEBPS/content.opf", EPUBFixture.package()),
        ("OEBPS/nav.xhtml", EPUBFixture.nav),
        ("OEBPS/ch1.xhtml", EPUBFixture.chapter("<p>x</p>"))
    ]

    func testCanonicalBookOpensWithoutDiagnostics() throws {
        let container = try open(EPUBFixture.archive(packageFiles))
        XCTAssertEqual(container.packagePath, "OEBPS/content.opf")
        XCTAssertEqual(container.rootfiles.count, 1)
        XCTAssertTrue(container.diagnostics.isEmpty, "\(container.diagnostics.items)")
        XCTAssertNil(container.displayOptionsFixedLayout)
    }

    func testMimetypeDeviationsAreDiagnosticsNeverRefusals() throws {
        let cases: [(String, Data)] = [
            ("mimetype.missing", EPUBFixture.archive(packageFiles, mimetype: nil)),
            ("mimetype.notFirst", EPUBFixture.archive(packageFiles, mimetypeFirst: false)),
            ("mimetype.compressed", EPUBFixture.archive(packageFiles, mimetypeDeflated: true)),
            ("mimetype.padded", EPUBFixture.archive(packageFiles, mimetype: "application/epub+zip\n")),
            ("mimetype.padded", EPUBFixture.archive(packageFiles, mimetype: "\u{FEFF}application/epub+zip")),
            ("mimetype.content", EPUBFixture.archive(packageFiles, mimetype: "text/plain"))
        ]
        for (code, data) in cases {
            let container = try open(data)
            XCTAssertEqual(container.packagePath, "OEBPS/content.opf", code)
            XCTAssertTrue(container.diagnostics.contains(code: code), "expected \(code), got \(container.diagnostics.items.map(\.code))")
        }
        var withExtra = ZipFixture(packageFiles.map { ZipFixture.Entry($0.0, text: $0.1) })
        var mimetype = ZipFixture.Entry("mimetype", text: "application/epub+zip", deflate: false)
        mimetype.localExtra = Data([0x55, 0x54, 0x05, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        withExtra.entries.insert(mimetype, at: 0)
        XCTAssertTrue(try open(withExtra.build()).diagnostics.contains(code: "mimetype.extraField"))
    }

    func testFilesThatAreNotZipsAreRefused() {
        XCTAssertThrowsError(try EPUBZipReader(data: Data("<!DOCTYPE html><html><body>Your download has started</body></html>".utf8)))
        var prefixed = Data("junk".utf8)
        prefixed.append(EPUBFixture.archive(packageFiles))
        XCTAssertThrowsError(try open(prefixed))
    }

    func testRootfileSelectionPrefersThePackageMediaTypeThenTheOpfSuffix() throws {
        let twoRenditions = EPUBFixture.container(rootfiles: [
            (path: "OEBPS/other.xml", mediaType: "application/other+xml"),
            (path: "OEBPS/content.opf", mediaType: "application/oebps-package+xml")
        ])
        let container = try open(EPUBFixture.archive([("META-INF/container.xml", twoRenditions)] + packageFiles.dropFirst() + [("OEBPS/other.xml", "<x/>")]))
        XCTAssertEqual(container.packagePath, "OEBPS/content.opf")
        XCTAssertTrue(container.diagnostics.contains(code: "container.rootfile.multiple"))

        let untyped = EPUBFixture.container(rootfiles: [(path: "OEBPS/notes.txt", mediaType: nil), (path: "OEBPS/content.opf", mediaType: nil)])
        let byExtension = try open(EPUBFixture.archive([("META-INF/container.xml", untyped)] + packageFiles.dropFirst() + [("OEBPS/notes.txt", "n")]))
        XCTAssertEqual(byExtension.packagePath, "OEBPS/content.opf")
    }

    func testMissingContainerFallsBackToExactlyOnePackageDocument() throws {
        let fallback = try open(EPUBFixture.archive(Array(packageFiles.dropFirst())))
        XCTAssertEqual(fallback.packagePath, "OEBPS/content.opf")
        XCTAssertTrue(fallback.diagnostics.contains(code: "container.missing"))
        XCTAssertTrue(fallback.diagnostics.contains(code: "container.rootfile.fallback"))

        let unparsable = try open(EPUBFixture.archive([("META-INF/container.xml", "<container><rootfiles>")] + packageFiles.dropFirst()))
        XCTAssertTrue(unparsable.diagnostics.contains(code: "container.unparsable"))
        XCTAssertEqual(unparsable.packagePath, "OEBPS/content.opf")

        XCTAssertThrowsError(try open(EPUBFixture.archive(Array(packageFiles.dropFirst()) + [("OEBPS/second.opf", "<package/>")]))) {
            XCTAssertEqual($0 as? EPUBContainerFile.Refusal, .notABook)
        }
        XCTAssertThrowsError(try open(EPUBFixture.archive([("OEBPS/ch1.xhtml", "<html/>")]))) {
            XCTAssertEqual($0 as? EPUBContainerFile.Refusal, .notABook)
        }
        let emptyRootfiles = EPUBFixture.container(rootfiles: [])
        let noRootfile = try open(EPUBFixture.archive([("META-INF/container.xml", emptyRootfiles)] + packageFiles.dropFirst()))
        XCTAssertTrue(noRootfile.diagnostics.contains(code: "container.noRootfile"))
        XCTAssertEqual(noRootfile.packagePath, "OEBPS/content.opf")
    }

    func testNestedBookOpensThroughTheFallbackWithADiagnosticNamingTheNestedContainer() throws {
        let nested = try open(EPUBFixture.archive(packageFiles.map { ("book/" + $0.0, $0.1) }, mimetype: nil))
        XCTAssertEqual(nested.packagePath, "book/OEBPS/content.opf")
        XCTAssertTrue(nested.diagnostics.contains(code: "container.rootfile.fallback"))
        XCTAssertEqual(nested.diagnostics[code: "container.nested"]?.path, "book/META-INF/container.xml")
    }

    func testRootfilePathsWithLeadingSlashesAndWrongCaseStillResolve() throws {
        let slashed = EPUBFixture.container(rootfiles: [(path: "/OEBPS/content.opf", mediaType: "application/oebps-package+xml")])
        let container = try open(EPUBFixture.archive([("META-INF/container.xml", slashed)] + packageFiles.dropFirst()))
        XCTAssertEqual(container.packagePath, "OEBPS/content.opf")
        XCTAssertTrue(container.diagnostics.contains(code: "href.pathAbsolute"))

        let wrongCase = EPUBFixture.container(rootfiles: [(path: "oebps/Content.opf", mediaType: "application/oebps-package+xml")])
        let folded = try open(EPUBFixture.archive([("META-INF/container.xml", wrongCase)] + packageFiles.dropFirst()))
        XCTAssertEqual(folded.packagePath, "OEBPS/content.opf")
        XCTAssertTrue(folded.diagnostics.contains(code: "href.caseFallback"))

        let missing = EPUBFixture.container(rootfiles: [(path: "OEBPS/gone.opf", mediaType: "application/oebps-package+xml")])
        let recovered = try open(EPUBFixture.archive([("META-INF/container.xml", missing)] + packageFiles.dropFirst()))
        XCTAssertTrue(recovered.diagnostics.contains(code: "container.rootfile.missing"))
        XCTAssertEqual(recovered.packagePath, "OEBPS/content.opf")
    }

    func testEncryptionManifestMapsPathsAndKeepsUnknownAlgorithmsAsProtectedResources() throws {
        let encryption = """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
            <enc:CipherData><enc:CipherReference URI="OEBPS/fonts/Lob%20ster.ttf"/></enc:CipherData></enc:EncryptedData>
          <enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes256-cbc"/>
            <enc:CipherData><enc:CipherReference URI="/OEBPS/secret.xhtml"/></enc:CipherData></enc:EncryptedData>
          <enc:EncryptedData><enc:CipherData><enc:CipherReference URI="OEBPS/x"/></enc:CipherData></enc:EncryptedData>
        </encryption>
        """
        let container = try open(EPUBFixture.archive(packageFiles + [("META-INF/encryption.xml", encryption)]))
        XCTAssertEqual(container.encryption["OEBPS/fonts/Lob ster.ttf"], EPUBFontObfuscation.idpfAlgorithm)
        XCTAssertEqual(container.encryption["OEBPS/secret.xhtml"], "http://www.w3.org/2001/04/xmlenc#aes256-cbc")
        XCTAssertEqual(container.protectedPaths, ["OEBPS/secret.xhtml"])
        XCTAssertTrue(container.diagnostics.contains(code: "encryption.entrySkipped"))

        let broken = try open(EPUBFixture.archive(packageFiles + [("META-INF/encryption.xml", "<encryption><EncryptedData>")]))
        XCTAssertTrue(broken.encryption.isEmpty)
        XCTAssertTrue(broken.diagnostics.contains(code: "encryption.unparsable"))
    }

    func testLCPAndADEPTProtectionRefuseTheBookBeforeParsing() throws {
        XCTAssertThrowsError(try open(EPUBFixture.archive(packageFiles + [("META-INF/license.lcpl", "{}")]))) {
            XCTAssertEqual($0 as? EPUBContainerFile.Refusal, .protected(.lcp))
        }
        let lcp = """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#" xmlns:ds="http://www.w3.org/2000/09/xmldsig#">
          <enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes256-cbc"/>
            <ds:KeyInfo><ds:RetrievalMethod URI="license.lcpl#/encryption/content_key" Type="http://readium.org/2014/01/lcp#EncryptedContentKey"/></ds:KeyInfo>
            <enc:CipherData><enc:CipherReference URI="OEBPS/ch1.xhtml"/></enc:CipherData></enc:EncryptedData>
        </encryption>
        """
        XCTAssertThrowsError(try open(EPUBFixture.archive(packageFiles + [("META-INF/encryption.xml", lcp)]))) {
            XCTAssertEqual($0 as? EPUBContainerFile.Refusal, .protected(.lcp))
        }
        let adept = """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#" xmlns:ds="http://www.w3.org/2000/09/xmldsig#" xmlns:adept="http://ns.adobe.com/adept">
          <enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
            <ds:KeyInfo><adept:resource>urn:uuid:1</adept:resource></ds:KeyInfo>
            <enc:CipherData><enc:CipherReference URI="OEBPS/ch1.xhtml"/></enc:CipherData></enc:EncryptedData>
        </encryption>
        """
        XCTAssertThrowsError(try open(EPUBFixture.archive(packageFiles + [("META-INF/encryption.xml", adept)]))) {
            XCTAssertEqual($0 as? EPUBContainerFile.Refusal, .protected(.adept))
        }
    }

    func testVendorDisplayOptionsDeclareFixedLayout() throws {
        let apple = """
        <display_options><platform name="*"><option name="fixed-layout">true</option></platform></display_options>
        """
        let container = try open(EPUBFixture.archive(packageFiles + [("META-INF/com.apple.ibooks.display-options.xml", apple)]))
        XCTAssertEqual(container.displayOptionsFixedLayout, true)
        let kobo = """
        <display_options><platform name="iphone"><option name="fixed-layout">false</option></platform></display_options>
        """
        let koboOnly = try open(EPUBFixture.archive(packageFiles + [("META-INF/com.kobobooks.display-options.xml", kobo)]))
        XCTAssertEqual(koboOnly.displayOptionsFixedLayout, false)
    }
}
