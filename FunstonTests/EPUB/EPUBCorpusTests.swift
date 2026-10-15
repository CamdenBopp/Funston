import XCTest
@testable import Funston

/// Spec 21.4: every book of the standards study's corpus (section 9.4) opens,
/// lists its contents, renders every chapter with no lost text, restores a
/// saved position exactly after a text size change, and produces the expected
/// diagnostics. Opt in with IA_EPUB_CORPUS=1; the books download once into
/// the fixture cache. The run also records the open question of Spec 24.5
/// (whether TextKit's suspicious-contents guard moves any page break) and
/// writes a report next to the cache.
@MainActor
final class EPUBCorpusTests: XCTestCase {
    static let gate = "IA_EPUB_CORPUS"
    static let contentSize = CGSize(width: 350, height: 720)
    static let largerTextSize: CGFloat = 23

    struct Book {
        let file: String
        let url: URL
        /// Diagnostic codes the study predicts for this file.
        let expectedCodes: [String]
        /// The cover discovery rule the study predicts.
        let coverRule: String?
        let pageListCount: Int?
        let minimumContents: Int
    }

    static let gutenbergURL = "https://archive.org/download/"
    static let standardEbooksURL = "https://standardebooks.org/ebooks/"

    static let books: [Book] = [
        Book(file: "pg20512-images.epub", url: URL(string: gutenbergURL + "manandmaid20512gut/pg20512-images.epub")!, expectedCodes: ["nav.fallbackNCX"], coverRule: nil, pageListCount: nil, minimumContents: 25),
        Book(file: "pg20512.epub", url: URL(string: gutenbergURL + "manandmaid20512gut/pg20512.epub")!, expectedCodes: ["nav.fallbackNCX"], coverRule: nil, pageListCount: nil, minimumContents: 25),
        Book(file: "pg890.epub", url: URL(string: gutenbergURL + "historyofthedecl00890gut/pg890.epub")!, expectedCodes: ["nav.fallbackNCX"], coverRule: "guide.image", pageListCount: nil, minimumContents: 50),
        Book(file: "pg30155-images.epub", url: URL(string: gutenbergURL + "relativitythespe30155gut/pg30155-images.epub")!, expectedCodes: ["nav.fallbackNCX", "nav.synthetic"], coverRule: nil, pageListCount: nil, minimumContents: 1),
        Book(file: "pg30155.epub", url: URL(string: gutenbergURL + "relativitythespe30155gut/pg30155.epub")!, expectedCodes: ["nav.fallbackNCX", "nav.synthetic"], coverRule: nil, pageListCount: nil, minimumContents: 1),
        Book(file: "pg24226.epub", url: URL(string: gutenbergURL + "pgcommunitytexts24226gut/pg24226.epub")!, expectedCodes: ["nav.fallbackNCX", "nav.synthetic"], coverRule: "guide.image", pageListCount: nil, minimumContents: 6),
        Book(file: "pg17995.epub", url: URL(string: gutenbergURL + "pgcommunitytexts17995gut/pg17995.epub")!, expectedCodes: ["nav.fallbackNCX"], coverRule: "guide.image", pageListCount: nil, minimumContents: 2),
        Book(file: "pg27348.epub", url: URL(string: gutenbergURL + "theciaworldfactb27348gut/pg27348.epub")!, expectedCodes: ["nav.fallbackNCX"], coverRule: "guide.image", pageListCount: nil, minimumContents: 30),
        Book(file: "pg33681-images.epub", url: URL(string: gutenbergURL + "poemsofthegreatw33681gut/pg33681-images.epub")!, expectedCodes: ["nav.fallbackNCX"], coverRule: nil, pageListCount: 36, minimumContents: 23),
        Book(file: "pg48734-images.epub", url: URL(string: gutenbergURL + "lesmisrablesvthe48734gut/pg48734-images.epub")!, expectedCodes: ["nav.fallbackNCX"], coverRule: nil, pageListCount: nil, minimumContents: 100),
        Book(file: "pg48734.epub", url: URL(string: gutenbergURL + "lesmisrablesvthe48734gut/pg48734.epub")!, expectedCodes: ["nav.fallbackNCX"], coverRule: nil, pageListCount: nil, minimumContents: 100),
        Book(file: "herman-melville_moby-dick.epub", url: URL(string: standardEbooksURL + "herman-melville/moby-dick/downloads/herman-melville_moby-dick.epub?source=download")!, expectedCodes: [], coverRule: "cover-image", pageListCount: nil, minimumContents: 140),
        Book(file: "herman-melville_moby-dick_advanced.epub", url: URL(string: standardEbooksURL + "herman-melville/moby-dick/downloads/herman-melville_moby-dick_advanced.epub?source=download")!, expectedCodes: [], coverRule: "cover-image", pageListCount: nil, minimumContents: 140),
        Book(file: "lewis-carroll_alices-adventures-in-wonderland_john-tenniel.epub", url: URL(string: standardEbooksURL + "lewis-carroll/alices-adventures-in-wonderland/john-tenniel/downloads/lewis-carroll_alices-adventures-in-wonderland_john-tenniel.epub?source=download")!, expectedCodes: [], coverRule: "cover-image", pageListCount: nil, minimumContents: 12)
    ]

    // MARK: Checks

    /// The non-whitespace scalars of every text node the renderer should show, in document order.
    static func sourceScalars(of document: EPUBContentDocument) -> [Unicode.Scalar] {
        guard let body = document.body else { return [] }
        var result: [Unicode.Scalar] = []
        let tree = document.tree
        func walk(_ id: EPUBXMLDocument.NodeID) {
            let node = tree[id]
            if node.isCharacterData { result.append(contentsOf: node.text.unicodeScalars.filter { !$0.properties.isWhitespace }); return }
            if document.hidden[id] || document.isNeverRendered(id) || node.name == "rp" || node.name == "svg" { return }
            for child in node.children { walk(child) }
        }
        walk(body)
        return result
    }

    /// Whether every source scalar appears in the rendered text in order; the first miss when not.
    static func lostText(source: [Unicode.Scalar], rendered: String) -> String? {
        let shown = Array(rendered.unicodeScalars.filter { !$0.properties.isWhitespace })
        var cursor = 0
        for (index, scalar) in source.enumerated() {
            while cursor < shown.count, shown[cursor] != scalar { cursor += 1 }
            guard cursor < shown.count else {
                let context = String(String.UnicodeScalarView(source[max(0, index - 20)..<min(source.count, index + 20)]))
                return "source scalar \(index) of \(source.count) (\(scalar)) not rendered near \"\(context)\""
            }
            cursor += 1
        }
        return nil
    }

    private struct ChapterReport {
        var parserPaths: [String: Int] = [:]
        var lost: [String] = []
        var pagesMoved: [Int] = []
        var pagesLaidOut = 0
        var chapters = 0
    }

    private func check(_ book: Book, at file: URL) throws -> String {
        var lines: [String] = ["## \(book.file)"]
        let publication = try EPUBPublication.open(url: file)
        let session = EPUBReaderSession(publication: publication, settings: EPUBReadingSettings(), contentSize: Self.contentSize, allowsTwoColumns: false, mediaContext: .default)
        let contents = publication.navigation.flattenedContents
        XCTAssertGreaterThanOrEqual(contents.count, book.minimumContents, "\(book.file): contents has \(contents.count) entries")
        lines.append("- Opens: \"\(publication.title)\", \(publication.package.spine.count) spine items, \(contents.count) contents entries (\(publication.navigation.contentsSource)), cover rule \(publication.package.coverRule ?? "none")")
        if let rule = book.coverRule { XCTAssertEqual(publication.package.coverRule, rule, "\(book.file): cover rule") }
        if let count = book.pageListCount {
            XCTAssertEqual(publication.navigation.pageList.count, count, "\(book.file): page list")
            lines.append("- Page list: \(publication.navigation.pageList.count) entries, first \"\(publication.navigation.pageList.first?.label ?? "")\"")
        }
        var report = ChapterReport()
        var codes = Set(publication.diagnostics.items.map(\.code))
        let resources = EPUBBookResources(publication: publication)
        let geometry = EPUBTextGeometry(columnWidth: session.geometry.columnWidth, maximumImageHeight: Self.contentSize.height)
        let loader = EPUBChapterLoader(resources: resources, settings: session.settings, geometry: geometry, mediaContext: .default, limits: .standard)
        var suspicious = EPUBWorkLimits.standard
        suspicious.limitsSuspiciousLayout = true
        for spine in session.readableSpine {
            guard let loaded = loader.load(spineIndex: spine) else { XCTFail("\(book.file): spine \(spine) did not load"); continue }
            report.chapters += 1
            report.parserPaths[loaded.document.parserPath.rawValue, default: 0] += 1
            codes.formUnion(loaded.diagnostics.items.map(\.code))
            XCTAssertNotEqual(loaded.document.parserPath, .unreadable, "\(book.file): spine \(spine) unreadable")
            if let lost = Self.lostText(source: Self.sourceScalars(of: loaded.document), rendered: loaded.text.plainText) {
                report.lost.append("spine \(spine): \(lost)")
            }
            let plain = EPUBLayoutSession(text: loaded.text, geometry: session.geometry, key: session.layoutKey, settings: session.settings, margins: 0)
            XCTAssertEqual(plain.table.pages.last?.endOffset, loaded.text.length, "\(book.file): spine \(spine) pages do not cover the text")
            XCTAssertFalse(plain.diagnostics.contains(code: EPUBLayoutSession.budgetDiagnostic), "\(book.file): spine \(spine) overran the layout budget")
            report.pagesLaidOut += plain.pageCount
            let guarded = EPUBLayoutSession(text: loaded.text, geometry: session.geometry, key: session.layoutKey, settings: session.settings, margins: 0, limits: suspicious)
            if guarded.table.pages.map(\.firstOffset) != plain.table.pages.map(\.firstOffset) { report.pagesMoved.append(spine) }
        }
        XCTAssertTrue(report.lost.isEmpty, "\(book.file): lost text \(report.lost)")
        lines.append("- Chapters: \(report.chapters) loaded, parser paths \(report.parserPaths), \(report.pagesLaidOut) pages at 350x720 pt and 17 pt")
        lines.append("- Lost text: \(report.lost.isEmpty ? "none" : report.lost.joined(separator: "; "))")
        lines.append("- Suspicious-contents guard moved page breaks in: \(report.pagesMoved.isEmpty ? "no chapter" : report.pagesMoved.map(String.init).joined(separator: ", "))")
        for code in book.expectedCodes { XCTAssertTrue(codes.contains(code), "\(book.file): expected diagnostic \(code); got \(codes.sorted())") }
        lines.append("- Diagnostic codes: \(codes.sorted().joined(separator: " "))")
        // Restore after a text size change: the saved offset is found exactly, by the offset path and by the CFI path.
        let order = session.readableSpine
        let middle = order[order.count / 2]
        if let chapter = session.chapter(middle) {
            let offset = chapter.text.blocks[chapter.text.blocks.count / 2].range.location
            let locator = try XCTUnwrap(EPUBLocator.make(publication: publication, spineIndex: middle, chapter: chapter, offset: offset, title: nil))
            var larger = EPUBReadingSettings()
            larger.baseFontSize = Self.largerTextSize
            let reopened = EPUBReaderSession(publication: publication, settings: larger, contentSize: Self.contentSize, allowsTwoColumns: false, mediaContext: .default)
            let resolver = EPUBPositionResolver(publication: publication) { [weak reopened] in reopened?.chapter($0) }
            let byOffset = resolver.resolve(locator)
            XCTAssertEqual(byOffset.offset, offset, "\(book.file): offset path")
            XCTAssertEqual(byOffset.method, .offset, "\(book.file): offset path")
            var stale = locator
            stale.parser = -1
            let byCFI = resolver.resolve(stale)
            XCTAssertEqual(byCFI.offset, offset, "\(book.file): CFI path \(locator.cfi ?? "nil") resolved by \(byCFI.method)")
            lines.append("- Restore at 23 pt: offset path \(byOffset.method) -> \(byOffset.offset ?? -1); CFI path \(byCFI.method) -> \(byCFI.offset ?? -1) (saved \(offset), \(locator.cfi ?? "no cfi"))")
        }
        return lines.joined(separator: "\n")
    }

    func testEveryCorpusBookOpensRendersRestoresAndDiagnoses() async throws {
        guard ProcessInfo.processInfo.environment[Self.gate] == "1" else { throw XCTSkip("Set \(Self.gate)=1 to run the corpus") }
        let directory = try EPUBFixtureCache.directory(named: "corpus")
        let session = EPUBFixtureCache.downloadSession()
        defer { session.invalidateAndCancel() }
        var report = ["# EPUB corpus run, \(Date.ISO8601FormatStyle().format(.now))", "", "Spec 21.4 over the books of the standards study, section 9.4. Content size 350x720 pt, body 17 pt.", ""]
        for book in Self.books {
            let file: URL
            do { file = try await EPUBFixtureCache.file(book.file, from: book.url, in: directory, session: session) } catch {
                report.append("## \(book.file)\n- Not run: \(error)")
                continue
            }
            do { report.append(try check(book, at: file)) } catch {
                XCTFail("\(book.file): \(error)")
                report.append("## \(book.file)\n- Failed: \(error)")
            }
            report.append("")
        }
        let reportURL = directory.appending(path: "corpus.md")
        try report.joined(separator: "\n").write(to: reportURL, atomically: true, encoding: .utf8)
        print("EPUB_CORPUS_REPORT", reportURL.path)
    }
}
