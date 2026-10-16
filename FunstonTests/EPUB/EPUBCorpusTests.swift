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
        /// The cover discovery rule the study predicts (Gutenberg's `meta name="cover"` names the item: meta.id).
        let coverRule: String?
        let pageListCount: Int?
        let minimumContents: Int
        /// The contents entries the reader names on the first page of the first readable spine items,
        /// when the study knows them; nil inside means no entry (the controller then says "Chapter n").
        var chapterStartLabels: [String?] = []
    }

    static let gutenbergURL = "https://archive.org/download/"
    static let standardEbooksURL = "https://standardebooks.org/ebooks/"

    static let books: [Book] = [
        Book(file: "pg20512-images.epub", url: URL(string: gutenbergURL + "manandmaid20512gut/pg20512-images.epub")!, expectedCodes: [], coverRule: "meta.id", pageListCount: nil, minimumContents: 25, chapterStartLabels: [nil, "IV"]),
        Book(file: "pg20512.epub", url: URL(string: gutenbergURL + "manandmaid20512gut/pg20512.epub")!, expectedCodes: [], coverRule: "meta.id", pageListCount: nil, minimumContents: 25, chapterStartLabels: [nil, "IV"]),
        Book(file: "pg890.epub", url: URL(string: gutenbergURL + "historyofthedecl00890gut/pg890.epub")!, expectedCodes: [], coverRule: "meta.id", pageListCount: nil, minimumContents: 50),
        Book(file: "pg30155-images.epub", url: URL(string: gutenbergURL + "relativitythespe30155gut/pg30155-images.epub")!, expectedCodes: ["nav.synthetic"], coverRule: "meta.id", pageListCount: nil, minimumContents: 1),
        Book(file: "pg30155.epub", url: URL(string: gutenbergURL + "relativitythespe30155gut/pg30155.epub")!, expectedCodes: ["nav.synthetic"], coverRule: "meta.id", pageListCount: nil, minimumContents: 1),
        Book(file: "pg24226.epub", url: URL(string: gutenbergURL + "pgcommunitytexts24226gut/pg24226.epub")!, expectedCodes: ["nav.synthetic"], coverRule: "meta.id", pageListCount: nil, minimumContents: 6),
        Book(file: "pg17995.epub", url: URL(string: gutenbergURL + "pgcommunitytexts17995gut/pg17995.epub")!, expectedCodes: [], coverRule: "meta.id", pageListCount: nil, minimumContents: 2),
        Book(file: "pg27348.epub", url: URL(string: gutenbergURL + "theciaworldfactb27348gut/pg27348.epub")!, expectedCodes: [], coverRule: "meta.id", pageListCount: nil, minimumContents: 30),
        Book(file: "pg33681-images.epub", url: URL(string: gutenbergURL + "poemsofthegreatw33681gut/pg33681-images.epub")!, expectedCodes: [], coverRule: "meta.id", pageListCount: 36, minimumContents: 23),
        Book(file: "pg48734-images.epub", url: URL(string: gutenbergURL + "lesmisrablesvthe48734gut/pg48734-images.epub")!, expectedCodes: [], coverRule: "meta.id", pageListCount: nil, minimumContents: 100),
        Book(file: "pg48734.epub", url: URL(string: gutenbergURL + "lesmisrablesvthe48734gut/pg48734.epub")!, expectedCodes: [], coverRule: "meta.id", pageListCount: nil, minimumContents: 100),
        Book(file: "herman-melville_moby-dick.epub", url: URL(string: standardEbooksURL + "herman-melville/moby-dick/downloads/herman-melville_moby-dick.epub?source=download")!, expectedCodes: [], coverRule: "cover-image", pageListCount: nil, minimumContents: 140),
        Book(file: "herman-melville_moby-dick_advanced.epub", url: URL(string: standardEbooksURL + "herman-melville/moby-dick/downloads/herman-melville_moby-dick_advanced.epub?source=download")!, expectedCodes: [], coverRule: "cover-image", pageListCount: nil, minimumContents: 140),
        Book(file: "lewis-carroll_alices-adventures-in-wonderland_john-tenniel.epub", url: URL(string: standardEbooksURL + "lewis-carroll/alices-adventures-in-wonderland/john-tenniel/downloads/lewis-carroll_alices-adventures-in-wonderland_john-tenniel.epub?source=download")!, expectedCodes: [], coverRule: "cover-image", pageListCount: nil, minimumContents: 12)
    ]

    // MARK: Checks

    /// The non-whitespace scalars, uppercased, of every text node the renderer should show, in
    /// document order: hidden subtrees, CSS display none, never-rendered elements, `rp` and
    /// SVG internals are left out, as the builder leaves them out. Uppercased because
    /// small-caps and text-transform change the case of what is rendered.
    static func sourceScalars(of document: EPUBContentDocument, styles: [EPUBComputedStyle]) -> [Unicode.Scalar] {
        guard let body = document.body else { return [] }
        var result: [Unicode.Scalar] = []
        let tree = document.tree
        func walk(_ id: EPUBXMLDocument.NodeID) {
            let node = tree[id]
            if node.isCharacterData { result.append(contentsOf: node.text.uppercased().unicodeScalars.filter { !$0.properties.isWhitespace }); return }
            if document.hidden[id] || document.isNeverRendered(id) || node.name == "rp" || node.name == "svg" { return }
            if styles.indices.contains(id), styles[id].display == .none { return }
            for child in node.children { walk(child) }
        }
        walk(body)
        return result
    }

    /// Whether every source scalar appears in the rendered text in order; the first miss when not,
    /// with the source and the rendered text around it.
    static func lostText(source: [Unicode.Scalar], rendered: String) -> String? {
        let shown = Array(rendered.uppercased().unicodeScalars.filter { !$0.properties.isWhitespace })
        var cursor = 0
        var lastMatch = 0
        for (index, scalar) in source.enumerated() {
            var probe = cursor
            while probe < shown.count, shown[probe] != scalar { probe += 1 }
            guard probe < shown.count else {
                let around = String(String.UnicodeScalarView(source[max(0, index - 24)..<min(source.count, index + 24)]))
                let renderedAround = String(String.UnicodeScalarView(shown[max(0, lastMatch - 24)..<min(shown.count, lastMatch + 24)]))
                return "source scalar \(index) of \(source.count) (\(scalar)) not rendered; source \"\(around)\", rendered \"\(renderedAround)\""
            }
            cursor = probe + 1
            lastMatch = probe
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
        if book.file.hasPrefix("pg") { XCTAssertEqual(publication.navigation.contentsSource, book.expectedCodes.contains("nav.synthetic") ? .synthetic : .ncx, "\(book.file): an EPUB 2 file's contents come from its NCX") }
        if let rule = book.coverRule { XCTAssertEqual(publication.package.coverRule, rule, "\(book.file): cover rule") }
        // The Reading page value on each chapter file's first page: the deepest entry at or before the page's
        // first character (FOL-34), which is the previous file's last entry when text precedes the first heading.
        var starts: [String] = []
        for (ordinal, spine) in session.readableSpine.prefix(4).enumerated() {
            session.go(to: .spine(spine))
            guard let start = session.relocationIfChanged(), let chapter = session.chapter(spine) else { starts.append("spine \(spine): no report"); continue }
            let opening = chapter.text.plainText.prefix(40).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\u{2029}", with: " ")
            starts.append("spine \(spine): \"\(start.contentsEntry?.label ?? "no entry")\", \(start.pageCount) pages, first page \(start.visibleRange.length) characters from \(start.visibleRange.location), opens \"\(opening)\"")
            XCTAssertGreaterThan(start.visibleRange.length, 0, "\(book.file): spine \(spine) opens on an empty page")
            if ordinal < book.chapterStartLabels.count { XCTAssertEqual(start.contentsEntry?.label, book.chapterStartLabels[ordinal], "\(book.file): spine \(spine) first page label") }
        }
        lines.append("- Chapter starts: " + starts.joined(separator: "; "))
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
        var foreignRuns = 0
        for spine in session.readableSpine {
            guard let (loaded, styles) = loader.loadWithStyles(spineIndex: spine) else { XCTFail("\(book.file): spine \(spine) did not load"); continue }
            report.chapters += 1
            report.parserPaths[loaded.document.parserPath.rawValue, default: 0] += 1
            codes.formUnion(loaded.diagnostics.items.map(\.code))
            XCTAssertNotEqual(loaded.document.parserPath, .unreadable, "\(book.file): spine \(spine) unreadable")
            if let lost = Self.lostText(source: Self.sourceScalars(of: loaded.document, styles: styles), rendered: loaded.text.plainText) {
                report.lost.append("spine \(spine): \(lost)")
            }
            // Checklist item 13 at the attribute level: runs in another language carry the speech language.
            let accessible = EPUBPageView.accessibleText(in: loaded.text.string, range: NSRange(location: 0, length: loaded.text.length))
            accessible.enumerateAttribute(.accessibilitySpeechLanguage, in: NSRange(location: 0, length: accessible.length)) { value, _, _ in if value != nil { foreignRuns += 1 } }
            let plain = EPUBLayoutSession(text: loaded.text, geometry: session.geometry, key: session.layoutKey, settings: session.settings, margins: 0)
            XCTAssertEqual(plain.table.pages.last?.endOffset, loaded.text.length, "\(book.file): spine \(spine) pages do not cover the text")
            XCTAssertFalse(plain.diagnostics.contains(code: EPUBLayoutSession.budgetDiagnostic), "\(book.file): spine \(spine) overran the layout budget")
            report.pagesLaidOut += plain.pageCount
            let guarded = EPUBLayoutSession(text: loaded.text, geometry: session.geometry, key: session.layoutKey, settings: session.settings, margins: 0, limits: suspicious)
            if guarded.table.pages.map(\.firstOffset) != plain.table.pages.map(\.firstOffset) { report.pagesMoved.append(spine) }
        }
        XCTAssertTrue(report.lost.isEmpty, "\(book.file): lost text \(report.lost)")
        let skipped = publication.package.spine.count - session.readableSpine.count
        lines.append("- Chapters: \(report.chapters) of \(session.readableSpine.count) readable spine items loaded (\(skipped) non-linear or placeholder skipped), parser paths \(report.parserPaths), \(report.pagesLaidOut) pages at 350x720 pt and 17 pt")
        lines.append("- Lost text: \(report.lost.isEmpty ? "none" : report.lost.joined(separator: "; "))")
        lines.append("- Runs carrying a VoiceOver speech language (text in another language than the chapter): \(foreignRuns)")
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
