import XCTest
import AVFoundation
import AVKit
import UIKit
@testable import Funston

@MainActor
final class VideoPlaybackTests: XCTestCase {
    private func fixture() async throws -> (SQLiteStore, URL, DownloadManager) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "video-" + UUID().uuidString)
        let media = directory.appending(path: "Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        // Session persistence tasks may outlive the test's last statement. An
        // in-memory store avoids unlinking an open SQLite database at teardown.
        let store = try SQLiteStore(url: URL(string: "file::memory:")!)
        let downloads = DownloadManager(store: store, mediaDirectory: media, sessionConfiguration: .ephemeral)
        await downloads.waitUntilReady()
        return (store, media, downloads)
    }

    private func movie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        if let base = CVPixelBufferGetBaseAddress(pixel) { memset(base, 0, CVPixelBufferGetDataSize(pixel)) }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        for second in [0, 30] {
            try await until { input.isReadyForMoreMediaData }
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(seconds: Double(second), preferredTimescale: 600)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    private func record(_ url: URL) -> DownloadRecord {
        DownloadRecord(key: DownloadManager.key(identifier: "film", fileName: "movie.mp4"), identifier: "film",
            fileName: "movie.mp4", title: "Film", expectedBytes: nil, localPath: url.path, state: .completed,
            receivedBytes: 0, totalBytes: nil, errorMessage: nil, updatedAt: .now)
    }

    private func session(_ store: SQLiteStore, _ downloads: DownloadManager,
                         acquire: @escaping @MainActor () async throws -> UInt64? = { 1 },
                         release: @escaping @MainActor (UInt64) -> Void = { _ in }) -> VideoPlaybackSession {
        VideoPlaybackSession(summary: ArtifactSummary(identifier: "film", title: "Film", mediaType: .movies),
            file: ArchiveFile(name: "movie.mp4"), source: .downloadedOnly, store: store, downloads: downloads,
            acquireAudio: acquire, releaseAudio: release)
    }

    private func until(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), "Video did not reach expected state", file: file, line: line)
    }

    func testOfflineVideoRestoresPositionAndLeasesFileUntilStopped() async throws {
        let (store, directory, _) = try await fixture()
        let url = directory.appending(path: "movie.mp4")
        try await movie(at: url)
        let record = record(url)
        try await store.upsertDownload(record)
        try await store.setPlaybackPosition(identifier: "film", fileName: "movie.mp4", seconds: 8)
        let downloads = DownloadManager(store: store, mediaDirectory: directory, sessionConfiguration: .ephemeral)
        let video = session(store, downloads)
        defer { video.stop() }
        video.start()
        try await until { video.state == .ready && video.player.rate > 0 }
        XCTAssertEqual((video.player.currentItem?.asset as? AVURLAsset)?.url, url)
        XCTAssertGreaterThanOrEqual(video.player.currentTime().seconds, 8)
        XCTAssertLessThan(video.player.currentTime().seconds, 10)
        try await downloads.remove(record, deferPhysicalRemoval: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        video.stop()
        XCTAssertNil(video.player.currentItem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let lastAudio = try await store.lastPlayback()
        XCTAssertNil(lastAudio, "Video must not corrupt audio-only startup restoration.")
    }

    func testCloseDuringActivationDoesNotStartOrEraseBookmark() async throws {
        let (store, _, downloads) = try await fixture()
        try await store.setPlaybackPosition(identifier: "film", fileName: "movie.mp4", seconds: 12)
        var pending: CheckedContinuation<UInt64?, Never>?
        var released: [UInt64] = []
        let video = session(store, downloads, acquire: { await withCheckedContinuation { pending = $0 } }, release: { released.append($0) })
        video.start()
        try await until { pending != nil }
        video.stop()
        pending?.resume(returning: 7)
        try await until { released == [7] }
        XCTAssertEqual(video.state, .idle)
        XCTAssertNil(video.player.currentItem)
        let saved = try await store.playbackPosition(identifier: "film", fileName: "movie.mp4")
        XCTAssertEqual(saved, 12)
    }

    func testMissingDownloadFailsWithoutStreamingAndReleasesAudio() async throws {
        let (store, _, downloads) = try await fixture()
        var released = 0
        let video = session(store, downloads, release: { _ in released += 1 })
        video.start()
        try await until { if case .failed = video.state { return true }; return false }
        XCTAssertNil(video.player.currentItem)
        XCTAssertEqual(released, 1)
        video.stop()
        XCTAssertEqual(released, 1)
    }

    func testNonanimatedDismissalCancelsPendingVideoPreparation() async throws {
        let (store, _, downloads) = try await fixture()
        var pending: CheckedContinuation<UInt64?, Never>?
        var released = false
        let video = session(store, downloads, acquire: { await withCheckedContinuation { pending = $0 } }, release: { _ in released = true })
        let window = UIWindow(frame: UIScreen.main.bounds)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { video.stop(); window.isHidden = true }
        let modal = UINavigationController(rootViewController: ArtifactVideoController(session: video))
        modal.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in
            root.present(modal, animated: false) { continuation.resume() }
        }
        try await until { pending != nil }
        await withCheckedContinuation { continuation in
            modal.dismiss(animated: false) { continuation.resume() }
        }
        try await until { video.state == .idle }
        pending?.resume(returning: 1)
        try await until { released }
        XCTAssertNil(video.player.currentItem)
    }

    func testCorruptVideoCanRetryAfterFileIsReplaced() async throws {
        let (store, directory, _) = try await fixture()
        let url = directory.appending(path: "movie.mp4")
        try Data("Not a video".utf8).write(to: url)
        try await store.upsertDownload(record(url))
        let downloads = DownloadManager(store: store, mediaDirectory: directory, sessionConfiguration: .ephemeral)
        let video = session(store, downloads)
        defer { video.stop() }
        video.start()
        try await until { if case .failed = video.state { return true }; return false }
        try FileManager.default.removeItem(at: url)
        try await movie(at: url)
        video.start()
        try await until { video.state == .ready && video.player.rate > 0 }
    }

    func testNativePlayerConfigurationAndLatePiPCallbacks() async throws {
        let (store, _, downloads) = try await fixture()
        let session = session(store, downloads)
        let host = ArtifactVideoController(session: session)
        host.loadViewIfNeeded()
        XCTAssertNil(host.video.parent, "AVKit must not sit beneath a permanent app toolbar")
        XCTAssertEqual(host.video.modalPresentationStyle, .fullScreen)
        XCTAssertEqual(host.video.videoGravity, .resizeAspect)
        XCTAssertTrue(host.video.allowsPictureInPicturePlayback)
        XCTAssertEqual(host.video.speeds.map(\.rate), AVPlaybackSpeed.systemDefaultSpeeds.map(\.rate))
        session.stop()
        host.playerViewControllerWillStartPictureInPicture(host.video)
        host.playerViewController(host.video, failedToStartPictureInPictureWithError: NSError(domain: "test", code: 1))
        host.playerViewControllerDidStopPictureInPicture(host.video)
        XCTAssertEqual(session.state, .idle, "A late PiP callback cannot resurrect a stopped session")
    }
}
