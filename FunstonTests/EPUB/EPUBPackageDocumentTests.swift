import XCTest
@testable import Funston

final class EPUBPackageDocumentTests: XCTestCase {
    /// Parses a package with the given files present in the archive.
    private func parse(_ opf: String, files: [(String, String)] = [], path: String = "OEBPS/content.opf") throws -> EPUBPackageDocument {
        let zip = try EPUBZipReader(data: EPUBFixture.archive([("META-INF/container.xml", EPUBFixture.container), (path, opf)] + files))
        return try EPUBPackageDocument.parse(Data(opf.utf8), at: path, in: zip, archiveData: zip.data)
    }

    private let chapterFiles: [(String, String)] = [("OEBPS/ch1.xhtml", EPUBFixture.chapter("<p>a</p>")), ("OEBPS/ch2.xhtml", EPUBFixture.chapter("<p>b</p>")), ("OEBPS/nav.xhtml", EPUBFixture.nav)]

    func testEPUB2AndEPUB3MetadataFormsProduceTheSameRecord() throws {
        let epub3 = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" prefix="foaf: http://xmlns.com/foaf/spec/">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="isbn">978-1</dc:identifier>
            <dc:identifier id="uid">urn:uuid:9f1c6a0e-2b7d-4c3e-8a5f-0123456789ab</dc:identifier>
            <dc:title id="t1">Man and Maid</dc:title><meta refines="#t1" property="title-type">main</meta><meta refines="#t1" property="display-seq">1</meta>
            <dc:title id="t2">A Novel</dc:title><meta refines="t2" property="title-type">subtitle</meta>
            <dc:creator id="c1">Glyn, Elinor</dc:creator><meta refines="#c1" property="role" scheme="marc:relators">aut</meta><meta refines="#c1" property="file-as">Glyn, Elinor</meta>
            <meta refines="#c1" property="alternate-script" xml:lang="ru">Глин</meta>
            <dc:contributor id="c2">Milman</dc:contributor><meta refines="#c2" property="role">cmm</meta>
            <dc:language>en</dc:language><dc:language>fr</dc:language>
            <dc:date>2007-01-20</dc:date>
            <meta property="dcterms:modified">2026-10-15T00:00:00Z</meta>
            <dc:subject id="s1">Man-woman relationships -- Fiction</dc:subject><meta refines="#s1" property="authority">LCSH</meta><meta refines="#s1" property="term">sh85</meta>
            <dc:subject>Romance</dc:subject>
            <meta property="foaf:depiction">x.png</meta>
            <meta property="schema:accessMode">textual</meta><meta property="schema:accessMode">visual</meta>
            <meta property="schema:accessModeSufficient">textual, visual</meta>
            <meta property="schema:accessibilityFeature">alternativeText</meta>
            <meta property="schema:accessibilityHazard">none</meta>
            <meta property="dcterms:conformsTo">EPUB Accessibility 1.1 - WCAG 2.2 Level AA</meta>
            <meta property="a11y:certifiedBy" id="cert">Standard Ebooks</meta><meta refines="#cert" property="a11y:certifierCredential">cred</meta>
            <meta property="belongs-to-collection" id="col">Classics</meta><meta refines="#col" property="collection-type">series</meta><meta refines="#col" property="group-position">3</meta>
            <meta property="rendition:layout">reflowable</meta><meta property="rendition:flow">scrolled-doc</meta>
            <meta property="media:duration">0:01:30.5</meta><meta property="media:duration" refines="#ch1">90s</meta><meta property="media:narrator">Reader</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav scripted"/>
            <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml" media-overlay="smil1"/>
            <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="smil1" href="ch1.smil" media-type="application/smil+xml"/>
          </manifest>
          <spine page-progression-direction="rtl"><itemref idref="ch1"/><itemref idref="ch2" linear="no"/></spine>
        </package>
        """
        let package = try parse(epub3, files: chapterFiles)
        XCTAssertEqual(package.uniqueIdentifier, "urn:uuid:9f1c6a0e-2b7d-4c3e-8a5f-0123456789ab")
        XCTAssertEqual(package.releaseIdentifier, "urn:uuid:9f1c6a0e-2b7d-4c3e-8a5f-0123456789ab@2026-10-15T00:00:00Z")
        XCTAssertEqual(package.mainTitle?.text, "Man and Maid")
        XCTAssertEqual(package.titles.map(\.kind), [.main, .subtitle])
        XCTAssertEqual(package.titles[1].kind, .subtitle, "A refines value without # is the id itself")
        let creator = try XCTUnwrap(package.creators.first)
        XCTAssertEqual(creator.roles, ["aut"]); XCTAssertEqual(creator.fileAs, "Glyn, Elinor"); XCTAssertEqual(creator.alternateScripts["ru"], "Глин")
        XCTAssertEqual(package.contributors.filter { !$0.isCreator }.first?.roles, ["cmm"])
        XCTAssertEqual(package.languages, ["en", "fr"]); XCTAssertEqual(package.primaryLanguage, "en")
        XCTAssertEqual(package.publishedDate, "2007-01-20"); XCTAssertEqual(package.modified, "2026-10-15T00:00:00Z")
        XCTAssertEqual(package.subjects.first, EPUBSubject(name: "Man-woman relationships -- Fiction", authority: "LCSH", term: "sh85"))
        XCTAssertEqual(package.subjects.count, 2)
        XCTAssertEqual(package.otherMetadata["http://xmlns.com/foaf/spec/depiction"], ["x.png"])
        XCTAssertEqual(package.accessibility.accessModes, ["textual", "visual"])
        XCTAssertEqual(package.accessibility.accessModesSufficient, [["textual", "visual"]])
        XCTAssertEqual(package.accessibility.conformsTo, ["EPUB Accessibility 1.1 - WCAG 2.2 Level AA"])
        XCTAssertEqual(package.accessibility.certifiedBy, "Standard Ebooks"); XCTAssertEqual(package.accessibility.certifierCredential, "cred")
        XCTAssertEqual(package.collections.first, EPUBCollectionMembership(name: "Classics", type: "series", position: 3, identifier: nil, fileAs: nil))
        XCTAssertEqual(package.rendition.layout, .reflowable); XCTAssertEqual(package.rendition.flow, .scrolledDoc)
        XCTAssertEqual(package.mediaOverlay.totalDuration ?? 0, 90.5, accuracy: 0.001)
        XCTAssertEqual(package.mediaOverlay.itemDurations["ch1"] ?? 0, 90, accuracy: 0.001)
        XCTAssertEqual(package.mediaOverlay.narrator, "Reader")
        XCTAssertTrue(package.hasMediaOverlays)
        XCTAssertEqual(package.navigationItem?.id, "nav", "The nav token is found whether first or last")
        XCTAssertEqual(package.pageProgression, .rightToLeft)
        XCTAssertEqual(package.spine.map(\.isLinear), [true, false])
        XCTAssertEqual(package.spineCFIStep, 6)
        XCTAssertFalse(package.diagnostics.contains(code: "package.language.missing"))

        let epub2 = """
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
            <dc-metadata>
              <dc:identifier id="uid" opf:scheme="URI">http://www.gutenberg.org/ebooks/20512</dc:identifier>
              <dc:title>Man and Maid</dc:title>
              <dc:creator opf:role="aut" opf:file-as="Glyn, Elinor">Elinor Glyn</dc:creator>
              <dc:contributor opf:role="cmm">Milman</dc:contributor>
              <dc:language xsi:type="dcterms:RFC4646" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">en</dc:language>
              <dc:date opf:event="publication">2007-01-20</dc:date><dc:date opf:event="modification">2011-07-18</dc:date>
              <dc:subject>Fiction, Romance; Classics</dc:subject>
            </dc-metadata>
            <x-metadata><meta name="cover" content="item1"/></x-metadata>
          </metadata>
          <manifest>
            <item id="item1" href="cover.jpg" media-type="image/jpeg"/>
            <item id="ncx" href="toc.ncx" media-type="text/xml"/>
            <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine toc="ncx"><itemref idref="ch1"/></spine>
          <guide><reference type="cover" title="Cover" href="cover.jpg"/><reference type="text" href="ch1.xhtml#start"/></guide>
        </package>
        """
        let legacy = try parse(epub2, files: chapterFiles + [("OEBPS/cover.jpg", "jpeg"), ("OEBPS/toc.ncx", "<ncx/>")])
        XCTAssertEqual(legacy.uniqueIdentifier, "http://www.gutenberg.org/ebooks/20512")
        XCTAssertEqual(legacy.mainTitle?.text, "Man and Maid")
        XCTAssertEqual(legacy.creators.first?.roles, ["aut"]); XCTAssertEqual(legacy.creators.first?.fileAs, "Glyn, Elinor")
        XCTAssertEqual(legacy.contributors.filter { !$0.isCreator }.first?.roles, ["cmm"])
        XCTAssertEqual(legacy.publishedDate, "2007-01-20"); XCTAssertEqual(legacy.modified, "2011-07-18")
        XCTAssertEqual(legacy.subjects.map(\.name), ["Fiction", "Romance", "Classics"])
        XCTAssertEqual(legacy.coverItemID, "item1"); XCTAssertEqual(legacy.coverRule, "meta.id")
        XCTAssertEqual(legacy.tocItemID, "ncx")
        XCTAssertEqual(legacy.guide.map(\.type), ["cover", "text"])
        XCTAssertEqual(legacy.guide[1].fragment, "start"); XCTAssertEqual(legacy.guide[1].path, "OEBPS/ch1.xhtml")
        XCTAssertEqual(legacy.pageProgression, .default)
    }

    func testUniqueIdentifierFallbacks() throws {
        let dangling = try parse(EPUBFixture.package().replacingOccurrences(of: "unique-identifier=\"pub-id\"", with: "unique-identifier=\"nope\""), files: chapterFiles)
        XCTAssertEqual(dangling.uniqueIdentifier, "urn:uuid:12345678-1234-1234-1234-123456789abc")
        XCTAssertTrue(dangling.diagnostics.contains(code: "package.uniqueIdentifier.fallback"))
        let missing = try parse(EPUBFixture.package().replacingOccurrences(of: " unique-identifier=\"pub-id\"", with: ""), files: chapterFiles)
        XCTAssertTrue(missing.diagnostics.contains(code: "package.uniqueIdentifier.fallback"))
        let none = try parse(EPUBFixture.package().replacingOccurrences(of: "<dc:identifier id=\"pub-id\">urn:uuid:12345678-1234-1234-1234-123456789abc</dc:identifier>", with: ""), files: chapterFiles)
        XCTAssertTrue(none.uniqueIdentifier.hasPrefix("urn:funston:sha256:"))
        XCTAssertTrue(none.uniqueIdentifierIsSynthetic)
        XCTAssertTrue(none.diagnostics.contains(code: "package.uniqueIdentifier.synthetic"))
        let noLanguage = try parse(EPUBFixture.package().replacingOccurrences(of: "<dc:language>en</dc:language>", with: ""), files: chapterFiles)
        XCTAssertEqual(noLanguage.primaryLanguage, "und")
        XCTAssertTrue(noLanguage.diagnostics.contains(code: "package.language.missing"))
        let oddLanguage = try parse(EPUBFixture.package().replacingOccurrences(of: "<dc:language>en</dc:language>", with: "<dc:language>EN-US</dc:language><dc:language>gem</dc:language><dc:language>not a tag!</dc:language>"), files: chapterFiles)
        XCTAssertEqual(oddLanguage.languages, ["EN-US", "gem", "not a tag!"])
        XCTAssertEqual(oddLanguage.diagnostics.count(code: "package.language.invalid"), 1)
    }

    func testManifestKeepsFirstDuplicateSkipsItemsWithoutIDOrHrefAndTolerantlyTypesItems() throws {
        let opf = EPUBFixture.package(extraManifest: """
            <item id="ch1" href="other.xhtml" media-type="application/xhtml+xml"/>
            <item href="orphan.xhtml" media-type="application/xhtml+xml"/>
            <item id="untyped" href="untyped.xhtml"/>
            <item id="weird" href="weird.bin" media-type="application/x-weird"/>
            <item id="multi" href="ch2.xhtml" media-type="application/xhtml+xml" properties="scripted nav"/>
            <item id="frag" href="ch2.xhtml#x" media-type="application/xhtml+xml"/>
            <item id="gone" href="gone.xhtml" media-type="application/xhtml+xml"/>
        """)
        let package = try parse(opf, files: chapterFiles + [("OEBPS/untyped.xhtml", "<x/>"), ("OEBPS/weird.bin", "?")])
        XCTAssertEqual(package.item(withID: "ch1")?.rawHref, "ch1.xhtml")
        XCTAssertTrue(package.diagnostics.contains(code: "manifest.duplicateID"))
        XCTAssertTrue(package.diagnostics.contains(code: "manifest.itemSkipped"))
        XCTAssertNil(package.item(withID: "untyped")?.mediaType)
        XCTAssertTrue(package.diagnostics.contains(code: "manifest.mediaTypeMissing"))
        XCTAssertEqual(package.item(withID: "weird")?.mediaType?.essence, "application/x-weird")
        XCTAssertEqual(package.item(withID: "multi")?.properties, ["scripted", "nav"])
        XCTAssertEqual(package.navigationItem?.id, "nav", "The first nav item in document order wins")
        XCTAssertEqual(package.item(withID: "frag")?.path, "OEBPS/ch2.xhtml")
        XCTAssertTrue(package.diagnostics.contains(code: "manifest.hrefFragment"))
        XCTAssertFalse(try XCTUnwrap(package.item(withID: "gone")).existsInArchive)
        XCTAssertTrue(package.diagnostics.contains(code: "resource.missing"))
    }

    func testSpineKeepsPlaceholdersWalksFallbackChainsAndRequiresOneUsableItem() throws {
        let opf = EPUBFixture.package(extraManifest: """
            <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="pic" href="pic.png" media-type="image/png"/>
            <item id="foreign" href="data.json" media-type="application/json" fallback="foreign2"/>
            <item id="foreign2" href="data2.xml" media-type="application/x-foo" fallback="ch2"/>
            <item id="loopA" href="a.bin" media-type="application/x-a" fallback="loopB"/>
            <item id="loopB" href="b.bin" media-type="application/x-b" fallback="loopA"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        """, spineExtra: """
            <itemref idref="missing"/>
            <itemref idref="pic"/>
            <itemref idref="foreign"/>
            <itemref idref="loopA"/>
            <itemref idref="ncx"/>
            <itemref idref="ch1" linear="NO" id="again" properties="page-spread-right rendition:layout-pre-paginated"/>
        """)
        let package = try parse(opf, files: chapterFiles + [("OEBPS/pic.png", "png"), ("OEBPS/data.json", "{}"), ("OEBPS/data2.xml", "<x/>"), ("OEBPS/a.bin", "a"), ("OEBPS/b.bin", "b"), ("OEBPS/toc.ncx", "<ncx/>")])
        XCTAssertEqual(package.spine.count, 7)
        XCTAssertEqual(package.spine[0].kind, .document)
        XCTAssertEqual(package.spine[1].kind, .placeholder(reason: "missing manifest item"))
        XCTAssertEqual(package.spine[2].kind, .image); XCTAssertEqual(package.spine[2].path, "OEBPS/pic.png")
        XCTAssertEqual(package.spine[3].kind, .document); XCTAssertEqual(package.spine[3].path, "OEBPS/ch2.xhtml", "The fallback chain is walked to its end")
        XCTAssertEqual(package.spine[4].kind, .placeholder(reason: "unrenderable media type"))
        XCTAssertEqual(package.spine[5].kind, .placeholder(reason: "unrenderable media type"))
        XCTAssertTrue(package.diagnostics.contains(code: "spine.ncxInSpine"))
        XCTAssertEqual(package.spine[6].isLinear, false); XCTAssertEqual(package.spine[6].id, "again")
        XCTAssertEqual(package.spine[6].pageSpread, .right)
        XCTAssertEqual(package.spine[6].renditionOverride.layout, .prePaginated)
        XCTAssertTrue(package.diagnostics.contains(code: "rendition.itemrefOverride"))
        XCTAssertEqual(package.spine[6].cfiStep, 14)
        XCTAssertEqual(package.diagnostics[code: "spine.itemMissing"]?.spineIndex, 1)
        XCTAssertEqual(package.spineIndex(forPath: "OEBPS/ch1.xhtml"), 0, "A duplicate itemref resolves to its first position")

        let empty = EPUBFixture.package().replacingOccurrences(of: "<itemref idref=\"ch1\"/>", with: "")
        XCTAssertThrowsError(try parse(empty, files: chapterFiles)) { XCTAssertEqual($0 as? EPUBPackageDocument.Failure, .emptySpine) }
        let allMissing = EPUBFixture.package().replacingOccurrences(of: "<itemref idref=\"ch1\"/>", with: "<itemref idref=\"nope\"/>")
        XCTAssertThrowsError(try parse(allMissing, files: chapterFiles)) { XCTAssertEqual($0 as? EPUBPackageDocument.Failure, .emptySpine) }
        XCTAssertThrowsError(try parse("<package><metadata/><manifest/>", files: chapterFiles)) { error in
            guard case .unreadable = error as? EPUBPackageDocument.Failure else { return XCTFail("\(error)") }
        }
    }

    func testPagesRunRightToLeftWhenDeclaredOrWhenTheLanguageIsRightToLeftAndNothingIsDeclared() throws {
        let arabic = EPUBFixture.package().replacingOccurrences(of: "<dc:language>en</dc:language>", with: "<dc:language>ar</dc:language>")
        XCTAssertTrue(try parse(arabic, files: chapterFiles).pagesRightToLeft, "An undeclared progression follows a right-to-left language")
        XCTAssertFalse(try parse(arabic.replacingOccurrences(of: "<spine>", with: "<spine page-progression-direction=\"ltr\">"), files: chapterFiles).pagesRightToLeft, "A declared ltr wins over the language")
        XCTAssertFalse(try parse(EPUBFixture.package(), files: chapterFiles).pagesRightToLeft)
        XCTAssertTrue(try parse(EPUBFixture.package().replacingOccurrences(of: "<spine>", with: "<spine page-progression-direction=\"rtl\">"), files: chapterFiles).pagesRightToLeft)
    }

    func testPageProgressionAndSpineElementPosition() throws {
        let withGuide = EPUBFixture.package().replacingOccurrences(of: "<spine>", with: "<guide/><spine page-progression-direction=\"default\">")
        let package = try parse(withGuide, files: chapterFiles)
        XCTAssertEqual(package.pageProgression, .default)
        XCTAssertEqual(package.spineCFIStep, 8, "The spine is the fourth element child here")
        let sideways = try parse(EPUBFixture.package().replacingOccurrences(of: "<spine>", with: "<spine page-progression-direction=\"sideways\">"), files: chapterFiles)
        XCTAssertEqual(sideways.pageProgression, .default)
        XCTAssertTrue(sideways.diagnostics.contains(code: "spine.progressionInvalid"))
    }

    func testCoverDiscoveryRulesInOrder() throws {
        func cover(_ manifest: String, metadata: String = "", guide: String = "", files: [(String, String)] = []) throws -> (String?, String?) {
            let opf = EPUBFixture.package(extraMetadata: metadata, extraManifest: manifest).replacingOccurrences(of: "</spine>", with: "</spine>\(guide)")
            let package = try parse(opf, files: chapterFiles + files)
            return (package.coverItemID, package.coverRule)
        }
        XCTAssertEqual(try cover("<item id=\"c\" href=\"a.jpg\" media-type=\"image/jpeg\" properties=\"cover-image\"/>", files: [("OEBPS/a.jpg", "j")]).1, "cover-image")
        XCTAssertEqual(try cover("<item id=\"c\" href=\"a.jpg\" media-type=\"image/jpeg\"/>", metadata: "<meta name=\"cover\" content=\"c\"/>", files: [("OEBPS/a.jpg", "j")]).1, "meta.id")
        XCTAssertEqual(try cover("<item id=\"i1\" href=\"images/front.jpg\" media-type=\"image/jpeg\"/>", metadata: "<meta name=\"cover\" content=\"front.jpg\"/>", files: [("OEBPS/images/front.jpg", "j")]).1, "meta.href")
        XCTAssertEqual(try cover("<item id=\"i1\" href=\"front.jpg\" media-type=\"image/jpeg\"/>", guide: "<guide><reference type=\"cover\" href=\"front.jpg\"/></guide>", files: [("OEBPS/front.jpg", "j")]).1, "guide.image")
        let wrapper = EPUBFixture.chapter("<img src=\"images/wrap.png\" alt=\"Cover\"/>")
        let page = try cover("<item id=\"wrap\" href=\"wrap.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"img\" href=\"images/wrap.png\" media-type=\"image/png\"/>",
                             guide: "<guide><reference type=\"cover\" href=\"wrap.xhtml\"/></guide>", files: [("OEBPS/wrap.xhtml", wrapper), ("OEBPS/images/wrap.png", "p")])
        XCTAssertEqual(page.0, "img"); XCTAssertEqual(page.1, "guide.page")
        XCTAssertEqual(try cover("<item id=\"x\" href=\"images/Cover_art.png\" media-type=\"image/png\"/>", files: [("OEBPS/images/Cover_art.png", "p")]).1, "name")
        XCTAssertNil(try cover("").0)
    }

    func testNamespacelessPackageStillParsesWithADiagnostic() throws {
        let opf = EPUBFixture.package().replacingOccurrences(of: " xmlns=\"http://www.idpf.org/2007/opf\"", with: "")
        let package = try parse(opf, files: chapterFiles)
        XCTAssertEqual(package.spine.count, 1)
        XCTAssertEqual(package.mainTitle?.text, "Fixture")
        XCTAssertTrue(package.diagnostics.contains(code: "package.namespaceMissing"))
    }

    func testTitleWhitespaceIsCollapsedAndDescriptionKept() throws {
        let opf = EPUBFixture.package().replacingOccurrences(of: "<dc:title>Fixture</dc:title>", with: "<dc:title>  Poems of\n   the Great   War </dc:title><dc:description>Desc</dc:description><dc:publisher>Pub</dc:publisher>")
        let package = try parse(opf, files: chapterFiles)
        XCTAssertEqual(package.mainTitle?.text, "Poems of the Great War")
        XCTAssertEqual(package.description, "Desc"); XCTAssertEqual(package.publisher, "Pub")
    }
}
