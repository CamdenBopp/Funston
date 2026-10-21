import XCTest
@testable import Funston

final class EPUBNavigationTests: XCTestCase {
    private func open(_ files: [(String, String)]) throws -> EPUBPublication {
        try EPUBPublication.open(data: EPUBFixture.archive(files))
    }

    private func book(package: String, nav: String? = EPUBFixture.nav, ncx: String? = nil, chapters: Int = 3, extra: [(String, String)] = []) throws -> EPUBPublication {
        var files: [(String, String)] = [("META-INF/container.xml", EPUBFixture.container), ("OEBPS/content.opf", package)]
        if let nav { files.append(("OEBPS/nav.xhtml", nav)) }
        if let ncx { files.append(("OEBPS/toc.ncx", ncx)) }
        for index in 1...chapters {
            files.append(("OEBPS/ch\(index).xhtml", EPUBFixture.chapter("<h2 id=\"h\(index)\">Heading \(index)</h2><p id=\"p\(index)\">Text \(index)</p>", title: "Title \(index)")))
        }
        return try open(files + extra)
    }

    private func threeChapterPackage(nav: Bool = true, ncx: Bool = false) -> String {
        let navItem = nav ? "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>" : ""
        let ncxItem = ncx ? "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>" : ""
        return """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="u">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="u">u</dc:identifier><dc:title>T</dc:title><dc:language>en</dc:language></metadata>
          <manifest>\(navItem)\(ncxItem)
            <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch3" href="ch3.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine\(ncx ? " toc=\"ncx\"" : "")><itemref idref="ch1"/><itemref idref="ch2"/><itemref idref="ch3"/></spine>
          <guide><reference type="text" title="Start" href="ch2.xhtml"/><reference type="toc" title="Contents" href="nav.xhtml"/></guide>
        </package>
        """
    }

    func testNavigationDocumentWithLandmarksFirstTocInASectionSpanHeadingsHiddenPageListAndAnUnresolvableEntry() throws {
        let nav = """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Nav</title></head><body>
          <nav epub:type="landmarks" hidden=""><ol><li><a epub:type="bodymatter" href="ch2.xhtml">Start of reading</a></li><li><a epub:type="toc" href="nav.xhtml">Contents</a></li></ol></nav>
          <section><nav epub:type="frontmatter toc" id="toc">
            <h1>Contents</h1>
            <ol>
              <li><a href="ch1.xhtml">  Chapter\n   One </a></li>
              <li><span>Part Two</span><ol><li><a href="ch2.xhtml#h2">Chapter Two</a></li><li><a href="ch3.xhtml">Chapter Three</a></li></ol></li>
              <li><a href="missing.xhtml">Gone</a></li>
              <li><a href="ch3.xhtml#p3"><img src="x.png" alt="Pictured"/></a></li>
              <li><a href="ch3.xhtml"><img src="x.png" title="Titled"/></a></li>
              <li><a href="ch1.xhtml"></a></li>
              <li><a href="ch1.xhtml" title="From title"><img src="y.png"/></a></li>
            </ol>
          </nav></section>
          <nav epub:type="page-list" hidden="hidden"><ol><li><a href="ch1.xhtml#p1">1</a></li><li><a href="ch2.xhtml#p2">ii</a></li></ol></nav>
          <nav epub:type="loi"><ol><li><a href="ch3.xhtml#p3">An illustration</a></li></ol></nav>
        </body></html>
        """
        let publication = try book(package: threeChapterPackage(), nav: nav)
        let tables = publication.navigation
        XCTAssertEqual(tables.contentsSource, .navigationDocument)
        XCTAssertEqual(tables.contents.map(\.label), ["Chapter One", "Part Two", "Gone", "Pictured", "Titled", EPUBContentsEntry.untitledLabel, "From title"])
        XCTAssertEqual(tables.contents[0].target, EPUBTarget(spineIndex: 0, fragment: nil))
        XCTAssertNil(tables.contents[1].target); XCTAssertFalse(tables.contents[1].isUnresolved)
        XCTAssertEqual(tables.contents[1].children.map(\.label), ["Chapter Two", "Chapter Three"])
        XCTAssertEqual(tables.contents[1].children[0].target, EPUBTarget(spineIndex: 1, fragment: "h2"))
        XCTAssertTrue(tables.contents[2].isUnresolved); XCTAssertNil(tables.contents[2].target)
        XCTAssertTrue(tables.diagnostics.contains(code: "nav.emptyLabel"))
        XCTAssertEqual(tables.flattenedContents.map(\.depth), [0, 0, 1, 1, 0, 0, 0, 0, 0])
        XCTAssertEqual(tables.pageList.map(\.label), ["1", "ii"])
        XCTAssertTrue(tables.pageList.allSatisfy(\.isHidden), "Hidden is recorded, never used to drop entries")
        XCTAssertEqual(tables.landmarks.count, 2)
        XCTAssertTrue(tables.landmarks[0].semanticTerms.contains(EPUBNavigationTables.bodymatterTerm))
        XCTAssertEqual(tables.otherLists["http://idpf.org/epub/vocab/structure/#loi"]?.first?.label, "An illustration")
        XCTAssertEqual(publication.startTarget, EPUBTarget(spineIndex: 1, fragment: nil))
        XCTAssertFalse(tables.isSynthetic)
    }

    func testNCXIsUsedWhenThereIsNoNavigationDocumentAndFillsThePageListWhenTheNavLacksOne() throws {
        let ncx = """
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><head/><docTitle><text>T</text></docTitle>
          <navMap>
            <navPoint><navLabel><text>One</text></navLabel><content src="ch1.xhtml"/>
              <navPoint><navLabel><text>One A</text></navLabel><content src="ch1.xhtml#p1"/>
                <navPoint><navLabel><text>One A i</text></navLabel><content src="ch2.xhtml"/>
                  <navPoint><navLabel><text>Deep</text></navLabel><content src="ch2.xhtml#h2"/>
                    <navPoint><navLabel><text>Deeper</text></navLabel><content src="ch3.xhtml"/></navPoint>
                  </navPoint>
                </navPoint>
              </navPoint>
            </navPoint>
            <navPoint id="x" playOrder="9"><navLabel><text>Outside</text></navLabel><content src="license.xhtml"/></navPoint>
            <navPoint><navLabel><text>No content</text></navLabel></navPoint>
          </navMap>
          <pageList><pageTarget type="normal" value="1"><navLabel><text>[Pg 4]</text></navLabel><content src="ch1.xhtml#p1"/></pageTarget></pageList>
          <navList><navLabel><text>Illustrations</text></navLabel><navTarget><navLabel><text>Plate</text></navLabel><content src="ch3.xhtml#p3"/></navTarget></navList>
        </ncx>
        """
        let publication = try book(package: threeChapterPackage(nav: false, ncx: true), nav: nil, ncx: ncx)
        let tables = publication.navigation
        XCTAssertEqual(tables.contentsSource, .ncx)
        XCTAssertEqual(tables.contents.map(\.label), ["One", "Outside", "No content"])
        XCTAssertEqual(tables.flattenedContents.map(\.depth), [0, 1, 2, 3, 4, 0, 0])
        XCTAssertEqual(tables.contents[0].children[0].target, EPUBTarget(spineIndex: 0, fragment: "p1"))
        XCTAssertTrue(tables.contents[1].isUnresolved)
        XCTAssertNil(tables.contents[2].target); XCTAssertTrue(tables.diagnostics.contains(code: "ncx.missingContent"))
        XCTAssertEqual(tables.pageList.first?.label, "[Pg 4]"); XCTAssertEqual(tables.pageList.first?.pageValue, "1")
        XCTAssertEqual(tables.otherLists["Illustrations"]?.first?.label, "Plate")
        XCTAssertEqual(tables.landmarks.map(\.label), ["Start", "Contents"], "The guide stands in for landmarks")
        XCTAssertTrue(tables.landmarks[0].semanticTerms.contains(EPUBNavigationTables.bodymatterTerm))
        XCTAssertFalse(tables.isSynthetic)

        let navWithoutPages = """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
          <nav epub:type="toc"><ol><li><a href="ch1.xhtml">One</a></li><li><a href="ch3.xhtml">Three</a></li></ol></nav></body></html>
        """
        let merged = try book(package: threeChapterPackage(nav: true, ncx: true), nav: navWithoutPages, ncx: ncx)
        XCTAssertEqual(merged.navigation.contentsSource, .navigationDocument)
        XCTAssertEqual(merged.navigation.contents.map(\.label), ["One", "Three"])
        XCTAssertEqual(merged.navigation.pageList.first?.label, "[Pg 4]")
        XCTAssertFalse(merged.navigation.diagnostics.contains(code: "nav.fallbackNCX"))

        let unparsableNav = try book(package: threeChapterPackage(nav: true, ncx: true), nav: "<html><body><nav", ncx: ncx)
        XCTAssertEqual(unparsableNav.navigation.contentsSource, .ncx)
        XCTAssertTrue(unparsableNav.navigation.diagnostics.contains(code: "nav.unparsable"))
        XCTAssertTrue(unparsableNav.navigation.diagnostics.contains(code: "nav.fallbackNCX"))
    }

    func testNavigationDocumentInASubdirectoryResolvesAgainstItself() throws {
        let package = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="u">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="u">u</dc:identifier><dc:title>T</dc:title><dc:language>en</dc:language></metadata>
          <manifest>
            <item id="nav" href="nav/toc.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="a" href="text/a.xhtml" media-type="application/xhtml+xml"/>
            <item id="b" href="text/b.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine toc="ncx"><itemref idref="a"/><itemref idref="b"/></spine>
        </package>
        """
        let nav = "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><nav epub:type=\"toc\"><ol><li><a href=\"../text/a.xhtml\">A</a></li><li><a href=\"../text/b.xhtml#x\">B</a></li></ol></nav></body></html>"
        let ncx = "<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\"><navMap><navPoint><navLabel><text>A</text></navLabel><content src=\"text/a.xhtml\"/></navPoint><navPoint><navLabel><text>B</text></navLabel><content src=\"text/b.xhtml\"/></navPoint></navMap><pageList><pageTarget><navLabel><text>3</text></navLabel><content src=\"text/b.xhtml#x\"/></pageTarget></pageList></ncx>"
        let publication = try open([
            ("META-INF/container.xml", EPUBFixture.container), ("OEBPS/content.opf", package), ("OEBPS/nav/toc.xhtml", nav), ("OEBPS/toc.ncx", ncx),
            ("OEBPS/text/a.xhtml", EPUBFixture.chapter("<p>a</p>")), ("OEBPS/text/b.xhtml", EPUBFixture.chapter("<p id=\"x\">b</p>"))
        ])
        XCTAssertEqual(publication.navigation.contents.map(\.target), [EPUBTarget(spineIndex: 0, fragment: nil), EPUBTarget(spineIndex: 1, fragment: "x")])
        XCTAssertEqual(publication.navigation.pageList.first?.target, EPUBTarget(spineIndex: 1, fragment: "x"))
        XCTAssertFalse(publication.navigation.isSynthetic)
    }

    func testSyntheticContentsWhenTheAuthoredTableDoesNotReachTheBody() throws {
        // Relativity: one entry, "Start".
        let oneEntry = "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><nav epub:type=\"toc\"><ol><li><a href=\"ch1.xhtml\">Start</a></li></ol></nav></body></html>"
        let relativity = try book(package: threeChapterPackage(), nav: oneEntry)
        XCTAssertTrue(relativity.navigation.isSynthetic)
        XCTAssertEqual(relativity.navigation.contents.map(\.label), ["Heading 1", "Heading 2", "Heading 3"])
        XCTAssertEqual(relativity.navigation.contents.map(\.target?.spineIndex), [0, 1, 2])
        XCTAssertTrue(relativity.navigation.diagnostics.contains(code: "nav.synthetic"))

        // Shiji: six entries, all in the last, shortest file.
        let licenseOnly = "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><nav epub:type=\"toc\"><ol><li><a href=\"ch3.xhtml#a\">A</a></li><li><a href=\"ch3.xhtml#b\">B</a></li><li><a href=\"ch3.xhtml#c\">C</a></li></ol></nav></body></html>"
        var files: [(String, String)] = [("META-INF/container.xml", EPUBFixture.container), ("OEBPS/content.opf", threeChapterPackage()), ("OEBPS/nav.xhtml", licenseOnly)]
        files.append(("OEBPS/ch1.xhtml", EPUBFixture.chapter("<p>" + String(repeating: "long ", count: 2000) + "</p>", title: "Untitled chapter")))
        files.append(("OEBPS/ch2.xhtml", EPUBFixture.chapter("<p>" + String(repeating: "long ", count: 2000) + "</p>", title: " ")))
        files.append(("OEBPS/ch3.xhtml", EPUBFixture.chapter("<h3 id=\"a\">License</h3>", title: "License")))
        let shiji = try open(files)
        XCTAssertTrue(shiji.navigation.isSynthetic)
        XCTAssertEqual(shiji.navigation.contents.map(\.label), ["Untitled chapter", "Section 2 of 3", "License"])

        // Two entries into two different files: no synthesis.
        let twoEntries = "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><nav epub:type=\"toc\"><ol><li><a href=\"ch1.xhtml\">One</a></li><li><a href=\"ch2.xhtml\">Two</a></li></ol></nav></body></html>"
        XCTAssertFalse(try book(package: threeChapterPackage(), nav: twoEntries).navigation.isSynthetic)

        // Three entries all into the longest file: no synthesis.
        let longest = "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><nav epub:type=\"toc\"><ol><li><a href=\"ch1.xhtml#a\">A</a></li><li><a href=\"ch1.xhtml#b\">B</a></li></ol></nav></body></html>"
        var longFirst: [(String, String)] = [("META-INF/container.xml", EPUBFixture.container), ("OEBPS/content.opf", threeChapterPackage()), ("OEBPS/nav.xhtml", longest)]
        longFirst.append(("OEBPS/ch1.xhtml", EPUBFixture.chapter("<p>" + String(repeating: "long ", count: 3000) + "</p>")))
        longFirst.append(("OEBPS/ch2.xhtml", EPUBFixture.chapter("<p>short</p>")))
        longFirst.append(("OEBPS/ch3.xhtml", EPUBFixture.chapter("<p>short</p>")))
        XCTAssertFalse(try open(longFirst).navigation.isSynthetic)
    }

    func testBookWithNoNavigationAtAllGetsSyntheticContentsAndNoTableIsEverEmpty() throws {
        let publication = try book(package: threeChapterPackage(nav: false), nav: nil)
        XCTAssertTrue(publication.navigation.isSynthetic)
        XCTAssertEqual(publication.navigation.contents.count, 3)
        XCTAssertEqual(publication.navigation.landmarks.map(\.label), ["Start", "Contents"])
    }

    func testHeadingAndTitleScanSurvivesEntitiesTheXMLParserRejects() {
        let soup = Data("<html><head><title>Les &nbsp; Mis</title></head><body><h2 class=\"c\">Chapter <i>One</i>&mdash;Dawn</h2></body></html>".utf8)
        let result = EPUBNavigationBuilder.headingAndTitle(in: soup)
        XCTAssertEqual(result.heading, "Chapter One &mdash;Dawn")
        XCTAssertEqual(result.title, "Les &nbsp; Mis")
    }
}
