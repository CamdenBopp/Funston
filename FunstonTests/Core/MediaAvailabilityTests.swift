import XCTest
@testable import Funston

final class MediaAvailabilityTests: XCTestCase {
    func testSupportedFilesRequireAvailablePublicMedia() {
        let audio = ArtifactSummary(identifier: "a", title: "Audio", mediaType: .audio)
        XCTAssertFalse(MediaAvailability.hasSupportedMedia(ArtifactDetail(summary: audio)))
        XCTAssertFalse(MediaAvailability.hasSupportedMedia(ArtifactDetail(summary: audio, files: [ArchiveFile(name: "track.mp3", isPrivate: true)])))
        XCTAssertFalse(MediaAvailability.hasSupportedMedia(ArtifactDetail(summary: audio, files: [ArchiveFile(name: "track.mp3")], access: .restricted)))
        XCTAssertTrue(MediaAvailability.hasSupportedMedia(ArtifactDetail(summary: audio, files: [ArchiveFile(name: "track.mp3")])))
        for suffix in ["mp4", "m4v", "mov", "mkv"] {
            XCTAssertTrue(MediaAvailability.hasSupportedMedia(ArtifactDetail(summary: ArtifactSummary(identifier: "v", title: "Video", mediaType: .movies), files: [ArchiveFile(name: "film." + suffix)])))
        }
        let book = ArtifactSummary(identifier: "b", title: "Book", mediaType: .texts)
        XCTAssertTrue(MediaAvailability.hasSupportedMedia(ArtifactDetail(summary: book, files: [ArchiveFile(name: "book.pdf")])))
        XCTAssertTrue(MediaAvailability.hasSupportedMedia(ArtifactDetail(summary: book, files: [ArchiveFile(name: "book.epub", source: "original")])))
        XCTAssertFalse(MediaAvailability.hasSupportedMedia(ArtifactDetail(summary: book, files: [ArchiveFile(name: "book.epub", source: "derivative")])))
    }

    func testUnknownLookupFailureKeepsItemAndPaginationInOrder() async {
        let page = SearchPage(items: [
            ArtifactSummary(identifier: "empty", title: "Empty", mediaType: .audio),
            ArtifactSummary(identifier: "unknown", title: "Unknown", mediaType: .texts),
            ArtifactSummary(identifier: "collection", title: "Collection", mediaType: .collection),
            ArtifactSummary(identifier: "playable", title: "Playable", mediaType: .audio)
        ], total: 100, page: 2, pageSize: 4)
        let result = await MediaAvailability.filter(page) { identifier in
            if identifier == "unknown" { throw URLError(.notConnectedToInternet) }
            let summary = page.items.first { $0.identifier == identifier }!
            return ArtifactDetail(summary: summary, files: identifier == "playable" ? [ArchiveFile(name: "track.mp3")] : [])
        }
        XCTAssertTrue(result.lookupFailed)
        XCTAssertEqual(result.page.items.map(\.identifier), ["unknown", "collection", "playable"])
        XCTAssertEqual(result.page.total, 100)
        XCTAssertEqual(result.page.page, 2)
        XCTAssertEqual(result.page.pageSize, 4)
        XCTAssertTrue(result.page.hasMore)
    }
}
