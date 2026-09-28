import XCTest
import AVFoundation
import UIKit
import MediaPlayer
@testable import Funston

final class SQLiteStoreTests: XCTestCase {
    private func makeStore() throws -> (SQLiteStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (try SQLiteStore(url: directory.appending(path: "test.sqlite3")), directory)
    }

    func testSavedArtifactRoundTripAndRemoval() async throws {
        let (store, _) = try makeStore()
        let artifact = ArtifactSummary(
            identifier: "otr-sample",
            title: "A very old broadcast",
            creators: ["Archive Test"],
            date: "1938",
            mediaType: .audio
        )
        let data = try JSONEncoder().encode(artifact)

        try await store.saveArtifact(identifier: artifact.identifier, snapshot: data)
        let saved = try await store.savedArtifacts()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(ArtifactSummary.self, from: saved[0]), artifact)

        let removed = try await store.removeSavedArtifact(identifier: artifact.identifier)
        XCTAssertEqual(removed, data)
        let remaining = try await store.savedArtifacts()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testPlaybackPositionsAreIndependentByFile() async throws {
        let (store, _) = try makeStore()

        try await store.setPlaybackPosition(identifier: "item", fileName: "one.mp3", seconds: 12)
        try await store.setPlaybackPosition(identifier: "item", fileName: "two.mp3", seconds: 54)

        let first = try await store.playbackPosition(identifier: "item", fileName: "one.mp3")
        let second = try await store.playbackPosition(identifier: "item", fileName: "two.mp3")
        XCTAssertEqual(first, 12)
        XCTAssertEqual(second, 54)
    }

    func testCachedEmptyResponseIsNotACacheMiss() async throws {
        let (store, _) = try makeStore()

        try await store.storeCache(
            key: "empty-search",
            kind: "search",
            response: Data("{\"response\":{\"numFound\":0,\"docs\":[]}}".utf8),
            snapshot: Data(),
            maxAge: 900
        )
        let entry = try await store.cacheEntry(key: "empty-search")
        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.isFresh == true)
        XCTAssertEqual(entry?.snapshot, Data())
    }

    func testDownloadRecordRoundTrip() async throws {
        let (store, _) = try makeStore()
        let record = DownloadRecord(
            key: "key",
            identifier: "item",
            fileName: "episode.mp3",
            title: "Episode",
            expectedBytes: 1_024,
            localPath: "/tmp/episode.mp3",
            state: .downloading,
            receivedBytes: 512,
            totalBytes: 1_024,
            errorMessage: nil,
            updatedAt: Date(timeIntervalSince1970: 123)
        )

        try await store.upsertDownload(record)
        let saved = try await store.downloads()
        XCTAssertEqual(saved, [record])
        try await store.deleteDownload(key: record.key)
        let remaining = try await store.downloads()
        XCTAssertTrue(remaining.isEmpty)
    }
}

private actor GatedArchiveTransport: ArchiveTransport {
    private var continuation: CheckedContinuation<ArchiveHTTPResponse, Error>?
    private var outcome: Result<ArchiveHTTPResponse, Error>?
    func send(_ request: URLRequest) async throws -> ArchiveHTTPResponse {
        if let outcome { return try outcome.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func resolve(_ result: Result<ArchiveHTTPResponse, Error>) {
        outcome = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

private enum DownloadTestError: Error { case persistence }

// Immutable artwork with a Sendable request handler, exercised on the same kind
// of background queue that MediaPlayer uses rather than only on MainActor.
private final class BackgroundArtworkProbe: @unchecked Sendable {
    let artwork: MPMediaItemArtwork
    init(_ artwork: MPMediaItemArtwork) { self.artwork = artwork }
    func imageSize() -> CGSize? { artwork.image(at: CGSize(width: 24, height: 16))?.size }
}
private actor FaultingDownloadStore: DownloadPersistence {
    var records: [DownloadRecord]
    var rejectWrites = false
    init(records: [DownloadRecord]) { self.records = records }
    func setRejectWrites(_ value: Bool) { rejectWrites = value }
    func downloads() -> [DownloadRecord] { records }
    func upsertDownload(_ record: DownloadRecord) throws {
        if rejectWrites { throw DownloadTestError.persistence }
        records.removeAll { $0.key == record.key }; records.append(record)
    }
    func deleteDownload(key: String) throws {
        if rejectWrites { throw DownloadTestError.persistence }
        records.removeAll { $0.key == key }
    }
}

private final class ArtworkRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLProtocol] = []
    private var starts = 0
    private var stops = 0
    var counts: (started: Int, stopped: Int) { lock.withLock { (starts, stops) } }
    func reset() { lock.withLock { requests = []; starts = 0; stops = 0 } }
    func started(_ request: URLProtocol) { lock.withLock { requests.append(request); starts += 1 } }
    func stopped() { lock.withLock { stops += 1 } }
    func finish(data: Data) {
        let active = lock.withLock { let value = requests; requests = []; return value }
        for request in active {
            guard let url = request.request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"]) else { continue }
            request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
            request.client?.urlProtocol(request, didLoad: data)
            request.client?.urlProtocolDidFinishLoading(request)
        }
    }
}

private final class HeldArtworkProtocol: URLProtocol, @unchecked Sendable {
    static let probe = ArtworkRequestProbe()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "artwork.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.probe.started(self) }
    override func stopLoading() { Self.probe.stopped() }
}

@MainActor
final class ServiceReviewTests: XCTestCase {
    private func fixture() throws -> (SQLiteStore, URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "archive-review-" + UUID().uuidString)
        let media = directory.appending(path: "Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        return (try SQLiteStore(url: URL(string: "file::memory:")!), directory, media)
    }

    func testStaleCachePublishesBeforeNetworkThenRetainsFailure() async throws {
        let (store, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = SearchRequest(text: "radio")
        let page = SearchPage(items: [], total: 0, page: 1, pageSize: 40)
        try await store.storeCache(key: "search:" + request.cacheKey, kind: "search", response: Data(), snapshot: JSONEncoder().encode(page), maxAge: -1)
        let transport = GatedArchiveTransport()
        let repository = CachingArchiveRepository(store: store, transport: transport)
        var iterator = repository.searchUpdates(request).makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.value, page)
        XCTAssertEqual(first?.freshness, .stale)
        XCTAssertEqual(first?.isRefreshing, true)
        await transport.resolve(.failure(URLError(.notConnectedToInternet)))
        let second = try await iterator.next()
        XCTAssertEqual(second?.value, page)
        XCTAssertEqual(second?.isRefreshing, false)
        XCTAssertNotNil(second?.refreshError)
        let end = try await iterator.next()
        XCTAssertNil(end)
    }

    func testStaleDetailPublishesThenReplacesWithFreshMetadata() async throws {
        let (store, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = ArtifactDetail(summary: ArtifactSummary(identifier: "item", title: "Old title"))
        try await store.storeCache(key: "metadata:item", kind: "metadata", response: Data(), snapshot: JSONEncoder().encode(old), maxAge: -1)
        let transport = GatedArchiveTransport()
        let repository = CachingArchiveRepository(store: store, transport: transport)
        var iterator = repository.detailUpdates(identifier: "item").makeAsyncIterator()
        let initial = try await iterator.next()
        XCTAssertEqual(initial?.value.summary.title, "Old title")
        await transport.resolve(.success(ArchiveHTTPResponse(data: Data(#"{"metadata":{"identifier":"item","title":"Fresh title"},"files":[]}"#.utf8))))
        let refreshed = try await iterator.next()
        XCTAssertEqual(refreshed?.value.summary.title, "Fresh title")
        XCTAssertEqual(refreshed?.freshness, .fresh)
        XCTAssertNil(refreshed?.refreshError)
    }

    func testAttemptIdentityCannotMatchRetryGeneration() {
        let directory = URL(filePath: "/tmp/archive-attempt-test")
        let first = DownloadTaskIdentity(key: "key", identifier: "item", fileName: "track.mp3", expectedBytes: 8)
        let retry = DownloadTaskIdentity(key: "key", identifier: "item", fileName: "track.mp3", expectedBytes: 8)
        let record = DownloadRecord(key: "key", identifier: "item", fileName: "track.mp3", title: "Track", expectedBytes: 8,
                                    localPath: retry.destination(in: directory).path, state: .downloading, receivedBytes: 0,
                                    totalBytes: 8, errorMessage: nil, updatedAt: .now)
        XCTAssertFalse(first.matches(record, directory: directory))
        XCTAssertTrue(retry.matches(record, directory: directory))
        XCTAssertEqual(DownloadTaskIdentity(taskDescription: retry.taskDescription), retry)
    }

    func testQueuedCompletionIsIdempotentAfterStartupPromotesMovedFile() async throws {
        let (store, directory, media) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DownloadTaskIdentity(key: DownloadManager.key(identifier: "item", fileName: "track.mp3"), identifier: "item", fileName: "track.mp3", expectedBytes: 3)
        let path = identity.destination(in: media)
        try Data([1, 2, 3]).write(to: path)
        let record = DownloadRecord(key: identity.key, identifier: "item", fileName: "track.mp3", title: "Track", expectedBytes: 3,
                                    localPath: path.path, state: .downloading, receivedBytes: 0, totalBytes: 3, errorMessage: nil, updatedAt: .now)
        try await store.upsertDownload(record)
        let manager = DownloadManager(store: store, mediaDirectory: media, sessionConfiguration: .ephemeral)
        // Intentionally enqueue the callback while startup reconciliation is pending.
        await manager.finished(identity: identity, result: .success(path))
        await manager.finished(identity: identity, result: .success(path))
        XCTAssertEqual(manager.records.first?.state, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        let durable = try await store.downloads()
        XCTAssertEqual(durable.first?.state, .completed)
    }

    func testLateValidatedCompletionRecoversProvisionalStartupFailure() async throws {
        let (store, directory, media) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DownloadTaskIdentity(key: DownloadManager.key(identifier: "item", fileName: "track.mp3"), identifier: "item", fileName: "track.mp3", expectedBytes: 3)
        let path = identity.destination(in: media)
        let record = DownloadRecord(key: identity.key, identifier: "item", fileName: "track.mp3", title: "Track", expectedBytes: 3,
                                    localPath: path.path, state: .downloading, receivedBytes: 0, totalBytes: 3, errorMessage: nil, updatedAt: .now)
        try await store.upsertDownload(record)
        let manager = DownloadManager(store: store, mediaDirectory: media, sessionConfiguration: .ephemeral)
        await manager.waitUntilReady()
        XCTAssertEqual(manager.records.first?.state, .failed)
        // The delegate's validated file move arrives after the provisional launch snapshot.
        try Data([1, 2, 3]).write(to: path)
        await manager.finished(identity: identity, result: .success(path))
        XCTAssertEqual(manager.records.first?.state, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        let durable = try await store.downloads()
        XCTAssertEqual(durable.first?.state, .completed)
        XCTAssertNil(durable.first?.errorMessage)
    }

    func testLateCompletionStillRejectsExplicitCancellation() async throws {
        let (store, directory, media) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DownloadTaskIdentity(key: DownloadManager.key(identifier: "item", fileName: "track.mp3"), identifier: "item", fileName: "track.mp3", expectedBytes: 3)
        let path = identity.destination(in: media)
        let record = DownloadRecord(key: identity.key, identifier: "item", fileName: "track.mp3", title: "Track", expectedBytes: 3,
                                    localPath: path.path, state: .cancelled, receivedBytes: 0, totalBytes: 3, errorMessage: nil, updatedAt: .now)
        try await store.upsertDownload(record)
        let manager = DownloadManager(store: store, mediaDirectory: media, sessionConfiguration: .ephemeral)
        await manager.waitUntilReady()
        try Data([1, 2, 3]).write(to: path)
        await manager.finished(identity: identity, result: .success(path))
        XCTAssertEqual(manager.records.first?.state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        let durable = try await store.downloads()
        XCTAssertEqual(durable.first?.state, .cancelled)
    }

    func testCancelAndRemoveSurfacePersistenceFailureWithoutChangingState() async throws {
        let (_, directory, media) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = media.appending(path: "track.mp3")
        try Data([1, 2, 3]).write(to: path)
        let record = DownloadRecord(key: "key", identifier: "item", fileName: "track.mp3", title: "Track", expectedBytes: 3,
                                    localPath: path.path, state: .completed, receivedBytes: 3, totalBytes: 3, errorMessage: nil, updatedAt: .now)
        let store = FaultingDownloadStore(records: [record])
        let manager = DownloadManager(store: store, mediaDirectory: media, sessionConfiguration: .ephemeral)
        await manager.waitUntilReady()
        await store.setRejectWrites(true)
        do { try await manager.cancel(record); XCTFail("Expected persistence error") } catch DownloadTestError.persistence {}
        XCTAssertEqual(manager.records.first, record)
        do { try await manager.remove(record); XCTFail("Expected persistence error") } catch DownloadTestError.persistence {}
        XCTAssertEqual(manager.records.first, record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        let durable = await store.downloads()
        XCTAssertEqual(durable, [record])
    }

    func testReconciliationRecoversMovedFileButNeverRevivesCancelledAttempt() async throws {
        let (store, directory, media) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, state) in [("complete", DownloadState.downloading), ("cancelled", .cancelled)] {
            let path = media.appending(path: name + ".mp3")
            try Data([1, 2, 3]).write(to: path)
            let record = DownloadRecord(key: name, identifier: name, fileName: name + ".mp3", title: name, expectedBytes: 3,
                                        localPath: path.path, state: state, receivedBytes: 0, totalBytes: 3, errorMessage: nil, updatedAt: .now)
            try await store.upsertDownload(record)
        }
        let manager = DownloadManager(store: store, mediaDirectory: media, sessionConfiguration: .ephemeral)
        await manager.waitUntilReady()
        XCTAssertEqual(manager.records.first { $0.key == "complete" }?.state, .completed)
        XCTAssertEqual(manager.records.first { $0.key == "cancelled" }?.state, .cancelled)
    }

    func testRemovedDownloadLeaseReleasesOnlyItsConcretePath() async throws {
        let (store, directory, media) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = DownloadManager.key(identifier: "item", fileName: "track.mp3")
        let path = media.appending(path: "old-generation.mp3")
        try Data([1, 2, 3]).write(to: path)
        let record = DownloadRecord(key: key, identifier: "item", fileName: "track.mp3", title: "Track", expectedBytes: 3,
                                    localPath: path.path, state: .completed, receivedBytes: 3, totalBytes: 3, errorMessage: nil, updatedAt: .now)
        try await store.upsertDownload(record)
        let manager = DownloadManager(store: store, mediaDirectory: media, sessionConfiguration: .ephemeral)
        await manager.waitUntilReady()
        let lease = try XCTUnwrap(manager.acquireLocalURL(identifier: "item", fileName: "track.mp3"))
        try await manager.remove(record)
        XCTAssertNil(manager.completedLocalURL(identifier: "item", fileName: "track.mp3"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        let replacement = media.appending(path: "new-generation.mp3")
        try Data([4, 5, 6]).write(to: replacement)
        manager.releaseLocalURL(lease)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
    }

    func testCancelledLimiterWaiterDoesNotConsumePermit() async throws {
        let limiter = ArtworkWorkLimiter(limit: 1)
        try await limiter.acquire()
        let waiter = Task { try await limiter.acquire() }
        await Task.yield()
        waiter.cancel()
        do { try await waiter.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        await limiter.release()
        try await limiter.acquire()
        await limiter.release()
    }

    private func waitForArtwork(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate())
    }

    func testArtworkCancellationKeepsOtherConsumerAndCancelsLastConsumer() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldArtworkProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let pipeline = ArtworkPipeline(session: session)
        HeldArtworkProtocol.probe.reset()
        let url = try XCTUnwrap(URL(string: "https://artwork.invalid/shared.png"))
        let first = Task { try await pipeline.image(url: url, pointSize: CGSize(width: 32, height: 32), scale: 2) }
        let second = Task { try await pipeline.image(url: url, pointSize: CGSize(width: 32, height: 32), scale: 2) }
        try await waitForArtwork { HeldArtworkProtocol.probe.counts.started == 1 }
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(HeldArtworkProtocol.probe.counts.stopped, 0)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).pngData { context in
            UIColor.black.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        HeldArtworkProtocol.probe.finish(data: png)
        let image = try await second.value
        XCTAssertEqual(image.value.size.width, 2)
        XCTAssertEqual(HeldArtworkProtocol.probe.counts.started, 1)

        HeldArtworkProtocol.probe.reset()
        let last = Task { try await pipeline.image(url: URL(string: "https://artwork.invalid/cancel.png")!, pointSize: CGSize(width: 32, height: 32), scale: 2) }
        try await waitForArtwork { HeldArtworkProtocol.probe.counts.started == 1 }
        last.cancel()
        do { _ = try await last.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        try await waitForArtwork { HeldArtworkProtocol.probe.counts.stopped == 1 }
    }

    func testTerminalPlaybackPositionRestoresAtStart() {
        XCTAssertEqual(PlaybackController.restoredPosition(59.9, duration: 60), 0)
        XCTAssertEqual(PlaybackController.restoredPosition(61, duration: 60), 0)
        XCTAssertEqual(PlaybackController.restoredPosition(23, duration: 60), 23)
        XCTAssertEqual(PlaybackController.restoredPosition(.nan, duration: 60), 0)
    }

    func testOfflinePausedRestoreAndEndedSeekPreserveChosenPosition() async throws {
        let (store, directory, media) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = media.appending(path: "fixture.wav")
        try writeSilentAudio(to: url)
        let record = DownloadRecord(key: DownloadManager.key(identifier: "restore-test", fileName: "track.wav"), identifier: "restore-test",
                                    fileName: "track.wav", title: "Restore", expectedBytes: nil, localPath: url.path, state: .completed,
                                    receivedBytes: 0, totalBytes: nil, errorMessage: nil, updatedAt: .now)
        try await store.upsertDownload(record)
        let manager = DownloadManager(store: store, mediaDirectory: media, sessionConfiguration: .ephemeral)
        let restoredRecord = await manager.completedRecord(identifier: record.identifier, fileName: record.fileName)
        let exactRecord = try XCTUnwrap(restoredRecord)
        var activations = 0
        let avPlayer = AVPlayer()
        let player = PlaybackController(store: store, downloads: manager, player: avPlayer,
                                        audioSessionActivator: { activations += 1 }, audioSessionDeactivator: {})
        player.playDownloaded(exactRecord, autoplay: false)
        let ready = XCTestExpectation(description: "Local audio ready")
        let observation = avPlayer.currentItem?.observe(\.status, options: [.initial, .new]) { item, _ in
            if item.status == .readyToPlay { ready.fulfill() }
        }
        await fulfillment(of: [ready], timeout: 3)
        observation?.invalidate()
        XCTAssertEqual(activations, 0)
        player.pause()
        XCTAssertEqual(activations, 0)
        XCTAssertEqual((avPlayer.currentItem?.asset as? AVURLAsset)?.url, url)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: avPlayer.currentItem)
        XCTAssertEqual(player.phase, .ended)
        player.seek(to: 0.4)
        XCTAssertEqual(player.phase, .paused)
        let deadline = Date().addingTimeInterval(2)
        while avPlayer.currentTime().seconds < 0.39, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(avPlayer.currentTime().seconds, 0.4, accuracy: 0.02)
        player.play()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertGreaterThanOrEqual(avPlayer.currentTime().seconds, 0.39)
        XCTAssertEqual(activations, 1)
        player.pause()
    }

    func testPausedPlaybackIgnoresLateAudioActivationFailure() async throws {
        let (store, directory, media) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = try await localAudioFixture(store: store, media: media)
        let downloads = DownloadManager(store: store, mediaDirectory: media, sessionConfiguration: .ephemeral)
        await downloads.waitUntilReady()
        let started = expectation(description: "Activation pending")
        let drained = expectation(description: "Deactivation follows activation")
        var finishActivation: CheckedContinuation<Void, any Error>?
        let avPlayer = AVPlayer()
        let playback = PlaybackController(store: store, downloads: downloads, player: avPlayer,
            audioSessionActivator: {
                try await withCheckedThrowingContinuation { continuation in
                    finishActivation = continuation
                    started.fulfill()
                }
            }, audioSessionDeactivator: { drained.fulfill() })
        playback.playDownloaded(record)
        await fulfillment(of: [started], timeout: 3)
        playback.pause()
        finishActivation?.resume(throwing: URLError(.unknown))
        await fulfillment(of: [drained], timeout: 3)
        XCTAssertEqual(playback.phase, .paused, "A superseded activation must not replace Pause with Failed.")
        XCTAssertEqual(avPlayer.rate, 0)
    }

    func testPauseThenPlaySerializesDeactivationBeforeNewestActivation() async throws {
        let (store, directory, media) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = try await localAudioFixture(store: store, media: media)
        let downloads = DownloadManager(store: store, mediaDirectory: media, sessionConfiguration: .ephemeral)
        await downloads.waitUntilReady()
        let started = expectation(description: "First activation pending")
        let resumed = expectation(description: "Newest activation reached")
        var finishActivation: CheckedContinuation<Void, any Error>?
        var events: [String] = []
        var activationCount = 0
        let avPlayer = AVPlayer()
        let playback = PlaybackController(store: store, downloads: downloads, player: avPlayer,
            audioSessionActivator: {
                activationCount += 1
                events.append("activate\(activationCount)")
                if activationCount == 1 {
                    try await withCheckedThrowingContinuation { continuation in
                        finishActivation = continuation
                        started.fulfill()
                    }
                } else { resumed.fulfill() }
            }, audioSessionDeactivator: {
                if events == ["activate1"] {
                    XCTAssertEqual(avPlayer.rate, 0, "The superseded activation must not start playback.")
                }
                events.append("deactivate")
            })
        playback.playDownloaded(record)
        await fulfillment(of: [started], timeout: 3)
        playback.pause()
        playback.play()
        finishActivation?.resume()
        await fulfillment(of: [resumed], timeout: 3)
        XCTAssertEqual(events, ["activate1", "deactivate", "activate2"])
        let stopped = await playback.pauseAndDeactivate()
        XCTAssertTrue(stopped)
        XCTAssertEqual(avPlayer.rate, 0)
        XCTAssertEqual(events, ["activate1", "deactivate", "activate2", "deactivate"])
    }

    func testTrackNavigationContinuesPlayingIncludingRapidChanges() async throws {
        let (store, directory, media) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (playback, avPlayer) = try await navigationFixture(store: store, media: media)
        defer { playback.pause() }
        playback.play()
        try await waitForTransport { playback.phase == .playing && avPlayer.rate > 0 }
        playback.nextTrack()
        XCTAssertEqual(playback.context?.trackIndex, 1)
        try await waitForTransport { playback.phase == .playing && avPlayer.rate > 0 }
        playback.previousTrack()
        XCTAssertEqual(playback.context?.trackIndex, 0)
        try await waitForTransport { playback.phase == .playing && avPlayer.rate > 0 }
        playback.nextTrack()
        playback.nextTrack()
        playback.previousTrack()
        XCTAssertEqual(playback.context?.trackIndex, 1)
        try await waitForTransport { playback.phase == .playing && avPlayer.rate > 0 }
    }

    func testTrackNavigationPreservesPauseAndPauseDuringPreparation() async throws {
        let (store, directory, media) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (playback, avPlayer) = try await navigationFixture(store: store, media: media)
        defer { playback.pause() }
        playback.nextTrack()
        try await waitForTransport { playback.phase != .preparing }
        XCTAssertEqual(playback.phase, .paused)
        XCTAssertEqual(avPlayer.rate, 0)
        playback.previousTrack()
        try await waitForTransport { playback.phase != .preparing }
        XCTAssertEqual(playback.phase, .paused)
        XCTAssertEqual(avPlayer.rate, 0)
        playback.play()
        playback.nextTrack()
        playback.pause()
        playback.nextTrack()
        try await waitForTransport { playback.phase != .preparing }
        XCTAssertEqual(playback.context?.trackIndex, 2)
        XCTAssertEqual(playback.phase, .paused)
        XCTAssertEqual(avPlayer.rate, 0)
    }

    func testRapidTrackChangesDuringActivationKeepLatestPlayIntent() async throws {
        let (store, directory, media) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "Activation pending")
        var releaseActivation: CheckedContinuation<Void, Never>?
        var activationCount = 0
        let (playback, avPlayer) = try await navigationFixture(store: store, media: media, activate: {
            activationCount += 1
            if activationCount == 1 {
                await withCheckedContinuation { releaseActivation = $0; started.fulfill() }
            }
        })
        defer { playback.pause() }
        playback.play()
        await fulfillment(of: [started], timeout: 3)
        playback.nextTrack()
        playback.nextTrack()
        playback.previousTrack()
        XCTAssertTrue(playback.wantsToPlay)
        XCTAssertTrue(playback.phase.showsPauseControl(wantsToPlay: playback.wantsToPlay))
        releaseActivation?.resume()
        try await waitForTransport { playback.phase == .playing && avPlayer.rate > 0 }
        XCTAssertEqual(playback.context?.trackIndex, 1)
    }

    func testTrackBoundariesRestartAndAutomaticAdvancePreservePlayback() async throws {
        let (store, directory, media) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (playback, avPlayer) = try await navigationFixture(store: store, media: media)
        defer { playback.pause() }
        playback.play()
        try await waitForTransport { playback.phase == .playing && avPlayer.rate > 0 }
        playback.seek(to: 8)
        try await waitForTransport { avPlayer.currentTime().seconds >= 8 }
        playback.previousTrack()
        try await waitForTransport { avPlayer.currentTime().seconds < 1 && avPlayer.rate > 0 }
        XCTAssertEqual(playback.context?.trackIndex, 0)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: avPlayer.currentItem)
        try await waitForTransport { playback.context?.trackIndex == 1 && playback.phase == .playing }
        playback.nextTrack()
        try await waitForTransport { playback.context?.trackIndex == 2 && playback.phase == .playing }
        playback.nextTrack()
        XCTAssertEqual(playback.phase, .playing, "Next at the queue boundary must not stop the current recording.")
        XCTAssertGreaterThan(avPlayer.rate, 0)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: avPlayer.currentItem)
        XCTAssertEqual(playback.phase, .ended)
        XCTAssertFalse(playback.wantsToPlay)
        XCTAssertEqual(avPlayer.rate, 0)
    }

    private func navigationFixture(store: SQLiteStore, media: URL,
                                   activate: @escaping @MainActor () async throws -> Void = {},
                                   deactivate: @escaping @MainActor () async -> Void = {}) async throws -> (PlaybackController, AVPlayer) {
        var tracks: [PlayableTrack] = []
        for index in 0..<3 {
            let name = "track-\(index).wav"
            let url = media.appending(path: name)
            try writeSilentAudio(to: url, seconds: 30)
            let record = DownloadRecord(key: DownloadManager.key(identifier: "navigation", fileName: name),
                identifier: "navigation", fileName: name, title: name, expectedBytes: nil,
                localPath: url.path, state: .completed, receivedBytes: 0, totalBytes: nil, errorMessage: nil, updatedAt: .now)
            try await store.upsertDownload(record)
            tracks.append(PlayableTrack(id: name, title: name, candidates: [ArchiveFile(name: name)]))
        }
        let downloads = DownloadManager(store: store, mediaDirectory: media, sessionConfiguration: .ephemeral)
        await downloads.waitUntilReady()
        let avPlayer = AVPlayer()
        let playback = PlaybackController(store: store, downloads: downloads, player: avPlayer,
            audioSessionActivator: activate, audioSessionDeactivator: deactivate, artworkLoader: { _ in throw URLError(.notConnectedToInternet) })
        playback.load(artifact: ArtifactSummary(identifier: "navigation", title: "Album", mediaType: .audio),
                      tracks: tracks, trackIndex: 0, autoplay: false)
        try await waitForTransport { playback.phase == .paused && avPlayer.currentItem?.status == .readyToPlay }
        return (playback, avPlayer)
    }

    private func waitForTransport(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), "Expected transport state was not reached.", file: file, line: line)
    }

    func testVideoOwnershipProtectsSessionAndAudioRecoversAfterInterruption() async throws {
        let (store, directory, media) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var deactivations = 0
        let (playback, avPlayer) = try await navigationFixture(store: store, media: media, deactivate: { deactivations += 1 })
        defer { playback.pause() }
        playback.play()
        try await waitForTransport { playback.phase == .playing }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        let acquired = try await playback.acquireVideoPlayback()
        let token = try XCTUnwrap(acquired)
        let baseline = deactivations
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                       AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        playback.pause(); playback.play(); playback.nextTrack()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(deactivations, baseline)
        XCTAssertEqual(avPlayer.rate, 0)
        XCTAssertEqual(playback.context?.trackIndex, 0)
        playback.releaseVideoPlayback(token)
        playback.play()
        try await waitForTransport { playback.phase == .playing && avPlayer.rate > 0 }
        let acquiredAgain = try await playback.acquireVideoPlayback()
        let newer = try XCTUnwrap(acquiredAgain)
        playback.releaseVideoPlayback(token)
        playback.play()
        XCTAssertEqual(avPlayer.rate, 0, "A stale release cannot surrender the newer video's ownership.")
        playback.releaseVideoPlayback(newer)
        playback.play()
        try await waitForTransport { playback.phase == .playing && avPlayer.rate > 0 }
    }

    private func localAudioFixture(store: SQLiteStore, media: URL) async throws -> DownloadRecord {
        let url = media.appending(path: "session-test.wav")
        try writeSilentAudio(to: url)
        let record = DownloadRecord(key: DownloadManager.key(identifier: "session-test", fileName: "track.wav"),
            identifier: "session-test", fileName: "track.wav", title: "Session test", expectedBytes: nil,
            localPath: url.path, state: .completed, receivedBytes: 0, totalBytes: nil, errorMessage: nil, updatedAt: .now)
        try await store.upsertDownload(record)
        return record
    }

    func testNowPlayingArtworkSurvivesTransportUpdatesAndReusesSameCover() async throws {
        let (store, directory, media) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = try await localAudioFixture(store: store, media: media)
        let downloads = DownloadManager(store: store, mediaDirectory: media, sessionConfiguration: .ephemeral)
        await downloads.waitUntilReady()
        let image = SendableImage(UIGraphicsImageRenderer(size: CGSize(width: 24, height: 16)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        })
        var requests: [URL] = []
        let playback = PlaybackController(store: store, downloads: downloads,
            audioSessionActivator: {}, audioSessionDeactivator: {}, artworkLoader: { url in
                requests.append(url); return image
            })
        let artifact = ArtifactSummary(identifier: record.identifier, title: "Album", mediaType: .audio, artworkFileName: "cover.jpg")
        let track = PlayableTrack(id: record.fileName, title: "Recording", candidates: [ArchiveFile(name: record.fileName)])
        playback.load(artifact: artifact, tracks: [track, track], trackIndex: 0, autoplay: false)
        try await waitForArtwork { MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil }
        let artwork = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
        XCTAssertEqual(artwork.bounds.size, image.value.size)
        XCTAssertEqual(artwork.image(at: image.value.size)?.size, image.value.size)
        let probe = BackgroundArtworkProbe(artwork)
        let backgroundSize = await Task.detached { probe.imageSize() }.value
        XCTAssertEqual(backgroundSize, image.value.size, "MediaPlayer must be able to invoke the handler off-main without an actor-isolation trap.")
        playback.pause()
        playback.seek(to: 0.2)
        playback.load(artifact: artifact, tracks: [track, track], trackIndex: 1, autoplay: false)
        await Task.yield()
        XCTAssertEqual(requests, [artifact.artworkURL])
        XCTAssertTrue((MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork) === artwork)
        playback.pause()
    }

    func testNowPlayingClearsChangedCoverAndRejectsStaleCompletion() async throws {
        let (store, directory, media) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = try await localAudioFixture(store: store, media: media)
        let downloads = DownloadManager(store: store, mediaDirectory: media, sessionConfiguration: .ephemeral)
        await downloads.waitUntilReady()
        var pending: [URL: CheckedContinuation<SendableImage, any Error>] = [:]
        let playback = PlaybackController(store: store, downloads: downloads,
            audioSessionActivator: {}, audioSessionDeactivator: {}, artworkLoader: { url in
                try await withCheckedThrowingContinuation { pending[url] = $0 }
            })
        let first = ArtifactSummary(identifier: record.identifier, title: "First", mediaType: .audio, artworkFileName: "first.jpg")
        let second = ArtifactSummary(identifier: record.identifier, title: "Second", mediaType: .audio, artworkFileName: "second.jpg")
        let third = ArtifactSummary(identifier: record.identifier, title: "Third", mediaType: .audio, artworkFileName: "third.jpg")
        let track = PlayableTrack(id: record.fileName, title: "Recording", candidates: [ArchiveFile(name: record.fileName)])
        let image = SendableImage(UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in })
        playback.load(artifact: first, tracks: [track], trackIndex: 0, autoplay: false)
        try await waitForArtwork { pending[first.artworkURL] != nil }
        playback.load(artifact: second, tracks: [track], trackIndex: 0, autoplay: false)
        try await waitForArtwork { pending[second.artworkURL] != nil }
        pending.removeValue(forKey: second.artworkURL)?.resume(returning: image)
        try await waitForArtwork { MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil }
        playback.load(artifact: third, tracks: [track], trackIndex: 0, autoplay: false)
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork], "Never show the previous artifact's cover while the next loads.")
        try await waitForArtwork { pending[third.artworkURL] != nil }
        pending.removeValue(forKey: first.artworkURL)?.resume(returning: image)
        pending.removeValue(forKey: third.artworkURL)?.resume(throwing: URLError(.notConnectedToInternet))
        // Drain both callbacks, including a loader that deliberately ignored cancellation.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork])
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyAlbumTitle] as? String, "Third")
        playback.pause()
    }

    private func writeSilentAudio(to url: URL, seconds: Int = 1) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 8_000)
        for _ in 0..<seconds { try file.write(from: buffer) }
    }
}
