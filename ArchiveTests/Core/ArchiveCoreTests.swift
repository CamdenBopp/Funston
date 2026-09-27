import Foundation
import XCTest
@testable import Archive

final class ArchiveCoreTests: XCTestCase {
    func testArtworkResolverPrefersExplicitPublicCoverAndRejectsUnsafeAssets() {
        let rejected = [
            ArchiveFile(name: "cover.jpg", format: "Item Image", size: 50, isPrivate: true),
            ArchiveFile(name: "__ia_thumb.jpg", format: "Item Image", size: 100),
            ArchiveFile(name: "spectrogram.png", format: "Item Image", size: 100),
            ArchiveFile(name: "huge.jpg", format: "Item Image", size: 9 * 1_024 * 1_024),
            ArchiveFile(name: "unknown-size.jpg", format: "Item Image"),
            ArchiveFile(name: "scan0001.jpg", size: 100)
        ]
        XCTAssertNil(ArtifactArtworkResolver.fileName(identifier: "radio", files: rejected))
        let exact = ArchiveFile(name: "radio.jpg", size: 500)
        let explicit = ArchiveFile(name: "poster.png", format: "Item Image", size: 700)
        XCTAssertEqual(ArtifactArtworkResolver.fileName(identifier: "radio", files: rejected + [exact]), "radio.jpg")
        XCTAssertEqual(ArtifactArtworkResolver.fileName(identifier: "radio", files: rejected + [exact, explicit]), "poster.png")
    }

    func testArtworkResolverRefusesAmbiguousCoversAndKeepsLegacySnapshotsDecodable() throws {
        let files = [ArchiveFile(name: "cover.jpg", size: 200), ArchiveFile(name: "folder.png", size: 300)]
        XCTAssertNil(ArtifactArtworkResolver.fileName(identifier: "radio", files: files))
        let legacy = Data(#"{"identifier":"radio","title":"Radio","creators":[],"mediaType":"audio","collections":[]}"#.utf8)
        let summary = try JSONDecoder().decode(ArtifactSummary.self, from: legacy)
        XCTAssertNil(summary.artworkFileName)
        XCTAssertEqual(summary.artworkURL, ArchiveURLs.thumbnail(identifier: "radio"))
        let detail = ArtifactDetail(summary: summary, files: [ArchiveFile(name: "radio.jpg", size: 500)])
        let enriched = detail.resolvingArtwork()
        XCTAssertEqual(enriched.summary.artworkFileName, "radio.jpg")
        XCTAssertEqual(enriched.summary.artworkURL, ArchiveURLs.download(identifier: "radio", fileName: "radio.jpg"))
    }

    func testPlainSearchCannotInjectArchiveOperators() throws {
        let request = SearchRequest(text: #"radio" OR mediatype:movies"#, scope: .audio, collection: "oldtimeradio")
        let url = ArchiveURLs.search(request)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value)
        XCTAssertEqual(query, #""radio\" OR mediatype:movies" AND mediatype:(audio OR etree) AND collection:"oldtimeradio""#)
        XCTAssertEqual(url.host, "archive.org")
    }

    func testFileURLPreservesExactRemotePathWithoutQueryInjection() {
        let url = ArchiveURLs.download(identifier: "identifier", fileName: "disc 1/a#b?c%20.flac")
        XCTAssertEqual(url.absoluteString, "https://archive.org/download/identifier/disc%201/a%23b%3Fc%2520.flac")
        XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.query)
    }

    func testSearchNormalizesLooseFieldsAndDeduplicates() async throws {
        let data = Data(#"{"response":{"numFound":"3","docs":[{"identifier":"a","title":["Title","Other"],"creator":["One","Two"],"year":1938,"mediatype":"audio"},{"identifier":"a","title":"Duplicate"},{"title":"Missing identifier"}]}}"#.utf8)
        let result = try await ArchiveNormalizer().search(data: data, request: SearchRequest(pageSize: 2))
        XCTAssertEqual(result.total, 3)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].date, "1938")
        XCTAssertEqual(result.items[0].creators, ["One", "Two"])
        XCTAssertTrue(result.hasMore)
    }

    func testEmptySearchIsAValidPage() async throws {
        let result = try await ArchiveNormalizer().search(data: Data(#"{"response":{"numFound":0,"docs":[]}}"#.utf8), request: SearchRequest())
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.total, 0)
        XCTAssertFalse(result.hasMore)
    }

    func testCollectionRelationshipsDeduplicateWithoutReordering() async throws {
        let data = Data(#"{"metadata":{"identifier":"a","collection":["radio","audio","radio","opensource_audio","audio"]},"files":[]}"#.utf8)
        let detail = try await ArchiveNormalizer().detail(data: data, identifier: "a")
        XCTAssertEqual(detail.summary.collections, ["radio", "audio", "opensource_audio"])
    }

    func testLargeNumericFileSizeRetainsIntegerPrecision() async throws {
        let data = Data(#"{"metadata":{"identifier":"a"},"files":[{"name":"original.bin","size":9007199254740993}]}"#.utf8)
        let detail = try await ArchiveNormalizer().detail(data: data, identifier: "a")
        XCTAssertEqual(detail.files.first?.size, 9_007_199_254_740_993)
    }

    func testFiniteUnrepresentableDurationIsOmitted() async throws {
        let data = Data(#"{"metadata":{"identifier":"a"},"files":[{"name":"a.mp3","length":"1e300"},{"name":"b.mp3","length":"01:02"}]}"#.utf8)
        let detail = try await ArchiveNormalizer().detail(data: data, identifier: "a")
        XCTAssertNil(detail.files.first { $0.name == "a.mp3" }?.duration)
        XCTAssertNil(detail.tracks.first { $0.id == "a.mp3" }?.duration)
        XCTAssertEqual(detail.files.first { $0.name == "b.mp3" }?.duration, 62)
        XCTAssertNil(MediaDuration.validated(Double.greatestFiniteMagnitude))
    }

    func testFileGroupingUsesExactOriginalAndRanksPreferredEncoding() async throws {
        let data = Data(#"{"metadata":{"identifier":"concert","title":"Concert","mediatype":"etree","description":"<p>Live &amp; restored</p><script>bad()</script>"},"files":[{"name":"track10.flac","source":"original","track":"10/12"},{"name":"track10.mp3","original":"track10.flac","format":"VBR MP3","length":"01:02","size":125},{"name":"track2.flac","source":"original","track":2},{"name":"track2_64kb.mp3","original":"track2.flac","format":"64Kbps MP3"},{"name":"track2.mp3","original":"track2.flac","format":"VBR MP3"},{"name":"private.mp3","private":"true"},{"name":"concert_meta.xml","format":"Metadata"},{"name":"other.mp3","format":"VBR MP3","size":"bad"}] }"#.utf8)
        let detail = try await ArchiveNormalizer().detail(data: data, identifier: "concert")
        XCTAssertEqual(detail.summary.mediaType, .audio)
        XCTAssertEqual(detail.description, "Live & restored")
        XCTAssertEqual(detail.tracks.map(\.id), ["track2.flac", "track10.flac", "other.mp3"])
        XCTAssertEqual(detail.tracks[0].preferredFile?.name, "track2.mp3")
        XCTAssertEqual(detail.tracks[0].candidates.count, 2)
        XCTAssertEqual(detail.tracks[1].duration, 62)
        XCTAssertEqual(detail.files.count, 8)
        XCTAssertNil(detail.files.first { $0.name == "other.mp3" }?.size)
    }

    func testExplicitMissingOriginalStillGroupsItsDerivatives() async throws {
        let data = Data(#"{"metadata":{"identifier":"a"},"files":[{"name":"one.mp3","original":"missing.wav"},{"name":"two.m4a","original":"missing.wav"},{"name":"one_other.mp3"}]}"#.utf8)
        let detail = try await ArchiveNormalizer().detail(data: data, identifier: "a")
        XCTAssertEqual(detail.tracks.count, 2)
        XCTAssertEqual(detail.tracks.first { $0.id == "missing.wav" }?.candidates.count, 2)
    }

    func testRestrictionAndUnknownCapabilityNeverExposeTracks() async throws {
        for (flag, expected) in [("true", ArtifactAccess.restricted), ("maybe", .unresolved)] {
            let data = Data("{\"metadata\":{\"identifier\":\"a\",\"access-restricted-item\":\"\(flag)\"},\"files\":[{\"name\":\"a.mp3\"}]}".utf8)
            let detail = try await ArchiveNormalizer().detail(data: data, identifier: "a")
            XCTAssertEqual(detail.access, expected)
            XCTAssertTrue(detail.tracks.isEmpty)
            XCTAssertEqual(detail.files.count, 1)
        }
    }

    func testNaturalOrderingIsNumericWithDeterministicTies() {
        let values = ["track10", "track2", "track01", "track1", "Track1"].sorted(by: ArchiveNormalizer.naturalLess)
        XCTAssertEqual(values, ["Track1", "track01", "track1", "track2", "track10"])
    }

    func testRepositoryPreservesRateLimitRetryAfter() async throws {
        let repository = NetworkArchiveRepository(transport: StubTransport(response: ArchiveHTTPResponse(data: Data(), statusCode: 429, headers: ["Retry-After": "30"])))
        do {
            _ = try await repository.search(SearchRequest(text: "radio"))
            XCTFail("Expected HTTP error")
        } catch let error as ArchiveError {
            XCTAssertEqual(error, .http(status: 429, retryAfter: "30"))
        }
    }

    func testCancellationDoesNotBecomeAnArchiveError() async throws {
        let repository = NetworkArchiveRepository(transport: SuspendedTransport())
        let task = Task { try await repository.search(SearchRequest(text: "radio")) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected; the UI must not present an error for obsolete work.
        }
    }
}

private struct StubTransport: ArchiveTransport {
    let response: ArchiveHTTPResponse
    func send(_ request: URLRequest) async throws -> ArchiveHTTPResponse { response }
}

private struct SuspendedTransport: ArchiveTransport {
    func send(_ request: URLRequest) async throws -> ArchiveHTTPResponse {
        try await Task.sleep(for: .seconds(30))
        return ArchiveHTTPResponse(data: Data())
    }
}
