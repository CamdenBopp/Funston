import XCTest
import AVFoundation
import UIKit
import ArchivePlayerCore
@testable import Funston

/// Drives the real MKV player (`ArtifactOriginalVideoController`) against a local
/// fixture: 20 s of 96x64 H.264 with a keyframe every second, AAC audio in English
/// then Japanese, and SRT captions in English then Japanese. Regenerate with:
///
///     ffmpeg -f lavfi -i testsrc=size=96x64:rate=10:duration=20 \
///       -f lavfi -i sine=frequency=440:duration=20:sample_rate=22050 \
///       -f lavfi -i sine=frequency=660:duration=20:sample_rate=22050 -i en.srt -i ja.srt \
///       -map 0:v -map 1:a -map 2:a -map 3:s -map 4:s -c:v libx264 -profile:v baseline \
///       -pix_fmt yuv420p -g 10 -b:v 20k -c:a aac -b:a 16k -ac 1 -c:s srt \
///       -metadata:s:a:0 language=eng -metadata:s:a:1 language=jpn \
///       -metadata:s:s:0 language=eng -metadata:s:s:1 language=jpn original-video-fixture.mkv
@MainActor
final class OriginalVideoPlaybackTests: XCTestCase {
    static let identifier = "mkv-fixture"
    static let fileName = "fixture.mkv"
    static let fixtureDuration = 20.0

    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows {
            if let presented = window.rootViewController?.presentedViewController {
                await withCheckedContinuation { continuation in presented.dismiss(animated: false) { continuation.resume() } }
            }
            window.isHidden = true
        }
        windows.removeAll()
        try await super.tearDown()
    }

    func makeEnvironment() async throws -> AppEnvironment {
        let directory = FileManager.default.temporaryDirectory.appending(path: "mkv-" + UUID().uuidString)
        let media = directory.appending(path: "Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "original-video-fixture", withExtension: "mkv"))
        let local = media.appending(path: Self.fileName)
        try FileManager.default.copyItem(at: fixture, to: local)
        // Player tasks can outlive a test's last statement. An in-memory store
        // avoids unlinking an open SQLite database at teardown.
        let store = try SQLiteStore(url: URL(string: "file::memory:")!)
        try await store.upsertDownload(DownloadRecord(
            key: DownloadManager.key(identifier: Self.identifier, fileName: Self.fileName), identifier: Self.identifier,
            fileName: Self.fileName, title: "Fixture", expectedBytes: nil, localPath: local.path, state: .completed,
            receivedBytes: 0, totalBytes: nil, errorMessage: nil, updatedAt: .now))
        let environment = AppEnvironment(store: store, mediaDirectory: media, downloadSession: .ephemeral)
        await environment.downloads.waitUntilReady()
        return environment
    }

    func present(_ environment: AppEnvironment) async -> ArtifactOriginalVideoController {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        windows.append(window)
        let player = ArtifactOriginalVideoController(
            summary: ArtifactSummary(identifier: Self.identifier, title: "Fixture film", mediaType: .movies),
            file: ArchiveFile(name: Self.fileName, duration: Self.fixtureDuration),
            environment: environment, downloadedOnly: true)
        let modal = UINavigationController(rootViewController: player)
        modal.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in root.present(modal, animated: false) { continuation.resume() } }
        return player
    }

    func close(_ player: ArtifactOriginalVideoController) async {
        guard let modal = player.navigationController else { return }
        await withCheckedContinuation { continuation in modal.dismiss(animated: false) { continuation.resume() } }
    }

    func playing(_ player: ArtifactOriginalVideoController) -> Bool {
        guard let engine = player.playbackEngine else { return false }
        return engine.state == .playing || engine.state == .finishedEnqueuing
    }

    func until(timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line,
               _ predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try await !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let reached = try await predicate()
        XCTAssertTrue(reached, "The MKV player did not reach the expected state", file: file, line: line)
    }

    func savedPosition(_ environment: AppEnvironment) async throws -> Double? {
        try await environment.store.playbackPosition(identifier: Self.identifier, fileName: Self.fileName)
    }

    // MARK: Position

    func testMKVResumesFromSavedPosition() async throws {
        let environment = try await makeEnvironment()
        try await environment.store.setPlaybackPosition(identifier: Self.identifier, fileName: Self.fileName, seconds: 8)
        let player = await present(environment)
        try await until { self.playing(player) && (player.playbackEngine?.currentTime.seconds ?? 0) > 8 }
        let time = try XCTUnwrap(player.playbackEngine?.currentTime.seconds)
        XCTAssertGreaterThanOrEqual(time, 8)
        XCTAssertLessThan(time, 12, "Playback must resume at the saved position, not start over")
        await close(player)
    }

    func testPauseCloseAndFinishingSaveThePosition() async throws {
        let environment = try await makeEnvironment()
        var player = await present(environment)
        try await until { self.playing(player) && (player.playbackEngine?.currentTime.seconds ?? 0) > 0.5 }
        var engine = try XCTUnwrap(player.playbackEngine)
        engine.pause()
        let paused = engine.currentTime.seconds
        try await until { try await self.savedPosition(environment).map { abs($0 - paused) < 0.25 } ?? false }

        // ResumePolicy resumes a 20 s film only between 5 s and 10 s before the end.
        try await engine.seek(to: CMTime(seconds: 6, preferredTimescale: 1_000))
        try engine.play()
        try await until { (engine.currentTime.seconds) > 6.2 }
        await close(player)
        try await until { try await self.savedPosition(environment).map { $0 >= 6 && $0 < 9 } ?? false }

        player = await present(environment)
        try await until { self.playing(player) && (player.playbackEngine?.currentTime.seconds ?? 0) >= 6 }
        engine = try XCTUnwrap(player.playbackEngine)
        try await engine.seek(to: CMTime(seconds: 19, preferredTimescale: 1_000))
        try engine.play()
        try await until { engine.state == .ended }
        try await until { try await self.savedPosition(environment) == 0 }
        await close(player)
        try await Task.sleep(for: .milliseconds(100))
        let afterClose = try await savedPosition(environment)
        XCTAssertEqual(afterClose, 0, "Closing a finished film must not save its end as a resume point")
    }

    /// The race Dumpert and Labstream both hit: a pause, tick or background save
    /// that lands while the restore seek is still in flight reads a clock near 0.
    func testSaveDuringRestoreSeekKeepsTheSavedPosition() async throws {
        let store = try SQLiteStore(url: URL(string: "file::memory:")!)
        try await store.setPlaybackPosition(identifier: "item", fileName: "film.mkv", seconds: 40)
        let bookmark = OriginalVideoBookmark(store: store, identifier: "item", fileName: "film.mkv")
        var pendingSeek: CheckedContinuation<Void, Never>?
        var sought: Double?
        let restore = Task { @MainActor in
            try await bookmark.restore(duration: 60) { seconds in
                sought = seconds
                await withCheckedContinuation { pendingSeek = $0 }
            }
        }
        try await until { pendingSeek != nil }
        XCTAssertEqual(sought, 40)
        bookmark.save(seconds: 0.05, ended: false)
        pendingSeek?.resume()
        try await restore.value
        await bookmark.flush()
        let afterRestore = try await store.playbackPosition(identifier: "item", fileName: "film.mkv")
        XCTAssertEqual(afterRestore, 40, "A save during the restore seek overwrote the saved position")

        bookmark.save(seconds: 41, ended: false)
        await bookmark.flush()
        let playing = try await store.playbackPosition(identifier: "item", fileName: "film.mkv")
        XCTAssertEqual(playing, 41)
        bookmark.save(seconds: 60, ended: true)
        await bookmark.flush()
        let finished = try await store.playbackPosition(identifier: "item", fileName: "film.mkv")
        XCTAssertEqual(finished, 0)
    }
}
