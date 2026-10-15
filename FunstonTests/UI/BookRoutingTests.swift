import XCTest
@testable import Funston

@MainActor
final class BookRoutingTests: XCTestCase {
    /// manandmaid20512gut's real EPUB files: Project Gutenberg uploads, both originals.
    func testGutenbergBookOpensTheIllustratedEPUB() {
        let files = [
            ArchiveFile(name: "20512-8.txt", format: "Text", source: "original", size: 452_484),
            ArchiveFile(name: "pg20512-images.epub", format: "EPUB", source: "original", size: 312_819),
            ArchiveFile(name: "pg20512.epub", format: "EPUB", source: "original", size: 211_340),
            ArchiveFile(name: "pg20512.epub_meta.txt", format: "Metadata", source: "original", size: 938)
        ]
        XCTAssertEqual(ArtifactMediaPresentation.bookFile(in: files)?.name, "pg20512-images.epub")
    }

    /// alicesadventures00carr's real files: Internet Archive's EPUB is generated from
    /// the OCR of the scans, so this book stays in the PDF reader.
    func testScannedBookKeepsThePDFReader() {
        let files = [
            ArchiveFile(name: "alicesadventures00carr.epub", format: "EPUB", source: "derivative",
                        original: "alicesadventures00carr_abbyy.gz", size: 34_435_262),
            ArchiveFile(name: "alicesadventures00carr.pdf", format: "Text PDF", source: "derivative",
                        original: "alicesadventures00carr_page_numbers.json", size: 20_579_155)
        ]
        XCTAssertNil(ArtifactMediaPresentation.bookFile(in: files))
        let detail = ArtifactDetail(summary: ArtifactSummary(identifier: "alicesadventures00carr", title: "Alice", mediaType: .texts), files: files)
        XCTAssertEqual(ArtifactMediaPresentation.actionTitle(for: detail), "Read PDF")
    }

    func testBookActionTitle() {
        let files = [ArchiveFile(name: "pg20512.epub", format: "EPUB", source: "original", size: 211_340)]
        let detail = ArtifactDetail(summary: ArtifactSummary(identifier: "manandmaid20512gut", title: "Man and Maid", mediaType: .texts), files: files)
        XCTAssertEqual(ArtifactMediaPresentation.actionTitle(for: detail), "Read Book")
        XCTAssertEqual(ArtifactMediaPresentation.preferredFile(in: detail)?.name, "pg20512.epub")
    }
}

@MainActor
final class SearchHistoryTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "SearchHistoryTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testAutocompleteCompletesPartialWordsAndPreservesFilters() throws {
        let url = try XCTUnwrap(ArchiveURLs.suggestions(SearchRequest(text: "sherlock hol", scope: .audio, collection: "oldtimeradio")))
        let parameters = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = try XCTUnwrap(parameters.first { $0.name == "q" }?.value)
        XCTAssertTrue(query.contains("title:\"sherlock\" AND title:hol*"))
        XCTAssertTrue(query.contains("collection:\"oldtimeradio\""))
        XCTAssertTrue(query.contains("mediatype:(audio OR etree)"))
        XCTAssertTrue(query.contains("-access-restricted-item:true"))
        XCTAssertNil(ArchiveURLs.suggestions(SearchRequest(text: "*")))
    }

    func testHistoryPersistsDeduplicatesAndOrdersByMostRecent() {
        withDefaults { defaults in
            let history = SearchHistory(defaults: defaults, collection: nil)
            history.remember("  Sherlock Holmes  ")
            history.remember("Jazz")
            history.remember("sherlock holmes")
            history.remember(" \n ")
            let restored = SearchHistory(defaults: defaults, collection: nil)
            XCTAssertEqual(restored.queries, ["sherlock holmes", "Jazz"])
            XCTAssertEqual(restored.matching("HOLMES"), ["sherlock holmes"])
        }
    }

    func testHistoryLimitAndCollectionIsolationAndRemoval() {
        withDefaults { defaults in
            let history = SearchHistory(defaults: defaults, collection: "oldtimeradio")
            for number in 0..<40 { history.remember("Episode \(number)") }
            XCTAssertEqual(history.queries.count, 30)
            XCTAssertEqual(history.queries.first, "Episode 39")
            XCTAssertEqual(history.queries.last, "Episode 10")
            let global = SearchHistory(defaults: defaults, collection: nil)
            global.remember("Books")
            history.remove("EPISODE 39")
            XCTAssertFalse(history.queries.contains("Episode 39"))
            history.clear()
            XCTAssertTrue(history.queries.isEmpty)
            XCTAssertEqual(global.queries, ["Books"])
        }
    }
}
