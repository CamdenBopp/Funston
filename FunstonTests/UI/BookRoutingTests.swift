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
