import Foundation
import XCTest
@testable import Funston

final class ArchiveCoreTests: XCTestCase {
    func testBookAuthorMetadataIsAvailableToTheDetailHeader() async throws {
        let raw = Data(#"{"metadata":{"identifier":"book","title":"Book","mediatype":"texts","author":"An Author"},"files":[]}"#.utf8)
        let detail = try await ArchiveNormalizer().detail(data: raw, identifier: "book")
        XCTAssertEqual(detail.summary.creators, ["An Author"])
    }

    func testReadableMediaTitlePreservesNamesAndNumbers() {
        XCTAssertEqual(ArchiveMediaTitle.readable("folder/Ben_Slade's_Saloon_004.mp4"), "Ben Slade's Saloon 004")
        XCTAssertEqual(ArchiveMediaTitle.readable("DuckAndCover1951.mpeg"), "Duck And Cover1951")
        XCTAssertEqual(ArchiveMediaTitle.readable("already readable.m4v"), "already readable")
        XCTAssertEqual(ArchiveMediaTitle.readable("part-one.second_edition.mp4"), "part one second edition")
    }

    func testControlledLendingIsExcludedFromSearchAndDetail() async throws {
        let data = Data(#"{"response":{"numFound":3,"docs":[{"identifier":"public"},{"identifier":"flagged","access-restricted-item":"true"},{"identifier":"collection","collection":["texts","access-restricted-item"]}]}}"#.utf8)
        let page = try await ArchiveNormalizer().search(data: data, request: SearchRequest())
        XCTAssertEqual(page.items.map(\.identifier), ["public"])
        for marker in [#""access-restricted-item":"true""#, #""collection":["access-restricted-item"]"#] {
            let metadata = Data("{\"metadata\":{\"identifier\":\"book\",\(marker)},\"files\":[{\"name\":\"book.pdf\"}]}".utf8)
            do { _ = try await ArchiveNormalizer().detail(data: metadata, identifier: "book"); XCTFail("Restricted detail exposed") }
            catch { XCTAssertEqual(error as? ArchiveError, .missingItem) }
        }
    }

    func testLegacySearchCacheWithoutRestrictionFieldsIsNotPublished() async throws {
        let store = try SQLiteStore(url: URL(string: "file::memory:")!)
        let request = SearchRequest(text: "book")
        let old = Data(#"{"response":{"numFound":1,"docs":[{"identifier":"unverified"}]}}"#.utf8)
        try await store.storeCache(key: "search:" + request.cacheKey, kind: "search", response: old, snapshot: nil, maxAge: 86400)
        let fresh = Data(#"{"response":{"numFound":0,"docs":[]}}"#.utf8)
        let repository = CachingArchiveRepository(store: store, transport: StubTransport(response: ArchiveHTTPResponse(data: fresh)))
        let result = try await repository.search(request)
        XCTAssertTrue(result.items.isEmpty)
    }

    func testCachedRestrictedSnapshotCannotBypassRawMetadata() async throws {
        let store = try SQLiteStore(url: URL(string: "file::memory:")!)
        let raw = Data(#"{"metadata":{"identifier":"restricted","collection":["access-restricted-item"]},"files":[{"name":"book.pdf"}]}"#.utf8)
        let unsafe = ArtifactDetail(summary: ArtifactSummary(identifier: "restricted", title: "Old snapshot"), files: [ArchiveFile(name: "book.pdf")])
        try await store.storeCache(key: "metadata:restricted", kind: "metadata", response: raw, snapshot: JSONEncoder().encode(unsafe), maxAge: 86400)
        let repository = CachingArchiveRepository(store: store, transport: StubTransport(response: ArchiveHTTPResponse(data: raw)))
        do { _ = try await repository.detail(identifier: "restricted"); XCTFail("Restricted cache exposed") }
        catch { XCTAssertEqual(error as? ArchiveError, .missingItem) }
    }

    @MainActor func testRestrictedDownloadDoesNotCreateATransfer() async throws {
        let store = try SQLiteStore(url: URL(string: "file::memory:")!)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = Data(#"{"metadata":{"identifier":"restricted","access-restricted-item":"true"},"files":[{"name":"book.pdf"}]}"#.utf8)
        let repository = NetworkArchiveRepository(transport: StubTransport(response: ArchiveHTTPResponse(data: raw)))
        let manager = DownloadManager(store: store, mediaDirectory: directory, sessionConfiguration: .ephemeral, accessRepository: repository)
        await manager.start(identifier: "restricted", artifactTitle: "Book", file: ArchiveFile(name: "book.pdf"))
        XCTAssertEqual(manager.records.first?.state, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.records.first?.localPath ?? ""))
    }

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

    /// The real file list of Joan Avoids a Cold (JoanAvoi1947): its identifier-named
    /// PNG is the audio waveform, derived from the MP3. The item page used to wait
    /// 2.5 s for it and show a squiggle instead of the film's thumbnail.
    func testArtworkResolverIgnoresWaveformsDerivedFromSoundOrFilm() {
        let files = [
            ArchiveFile(name: "JoanAvoi1947.gif", format: "Animated GIF", source: "derivative", original: "JoanAvoi1947.mpeg", size: 291_763),
            ArchiveFile(name: "JoanAvoi1947.png", format: "PNG", source: "derivative", original: "JoanAvoi1947.mp3", size: 11_959),
            ArchiveFile(name: "__ia_thumb.jpg", format: "Item Tile", source: "original", size: 7_026)
        ]
        XCTAssertNil(ArtifactArtworkResolver.fileName(identifier: "JoanAvoi1947", files: files))
        // An image derived from a scan is still a real cover.
        let fromScan = ArchiveFile(name: "JoanAvoi1947.jpg", format: "JPEG", source: "derivative", original: "JoanAvoi1947.tif", size: 90_000)
        XCTAssertEqual(ArtifactArtworkResolver.fileName(identifier: "JoanAvoi1947", files: files + [fromScan]), "JoanAvoi1947.jpg")
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
        XCTAssertEqual(query, #"("radio\" OR mediatype:movies" AND mediatype:(audio OR etree) AND collection:"oldtimeradio") AND -collection:access-restricted-item AND -access-restricted-item:true"#)
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
            let data = Data("{\"metadata\":{\"identifier\":\"a\",\"is_restricted\":\"\(flag)\"},\"files\":[{\"name\":\"a.mp3\"}]}".utf8)
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
        let repository = NetworkArchiveRepository(transport: StubTransport(response: ArchiveHTTPResponse(data: Data(), statusCode: 429, headers: ["Retry-After": "30"])), retrySleep: { _ in })
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
