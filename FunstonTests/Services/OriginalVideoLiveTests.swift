import XCTest
import MediaPlayer
import UIKit
import ArchivePlayerCore
@testable import Funston

/// Drives the MKV player against a real Internet Archive film over HTTP ranges:
/// H.264, Hindi AAC, English and Japanese Opus, PGS captions. Opt in with
/// TEST_RUNNER_IA_RENDER_TESTS=1; it streams a few megabytes.
@MainActor
final class OriginalVideoLiveTests: XCTestCase {
    static let identifier = "the-ancient-magus-bride-s-01-e-03-720p-hd-blu-ray-multi-audio-esub"
    static let fileName = "The Ancient Magus' Bride S01E03 720p HD BluRay Multi Audio ESub.mkv"
    static let resumeSeconds = 300.0

    private var window: UIWindow?

    func open(_ environment: AppEnvironment) async -> ArtifactOriginalVideoController {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        let player = ArtifactOriginalVideoController(
            summary: ArtifactSummary(identifier: Self.identifier, title: "The Ancient Magus' Bride", mediaType: .movies),
            file: ArchiveFile(name: Self.fileName), environment: environment, downloadedOnly: false)
        let modal = UINavigationController(rootViewController: player)
        modal.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in window.rootViewController?.present(modal, animated: false) { continuation.resume() } }
        return player
    }

    func close(_ player: ArtifactOriginalVideoController) async throws {
        guard let modal = player.navigationController else { return }
        await withCheckedContinuation { continuation in modal.dismiss(animated: false) { continuation.resume() } }
        try await until(30) { !player.holdsPlayback }
        window?.isHidden = true
    }

    func until(_ timeout: TimeInterval, file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(predicate(), "The live film did not reach the expected state", file: file, line: line)
    }

    func playing(_ player: ArtifactOriginalVideoController) -> Bool {
        guard let engine = player.playbackEngine else { return false }
        return (engine.state == .playing || engine.state == .finishedEnqueuing) && engine.currentTime.seconds > 0
    }

    func testRealFilmResumesRemembersAudioAndPublishesNowPlaying() async throws {
        guard ProcessInfo.processInfo.environment["IA_RENDER_TESTS"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_IA_RENDER_TESTS=1 to stream the real film")
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "mkv-live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(url: URL(string: "file::memory:")!)
        let environment = AppEnvironment(store: store, mediaDirectory: directory, downloadSession: .ephemeral)
        await environment.downloads.waitUntilReady()
        try await store.setPlaybackPosition(identifier: Self.identifier, fileName: Self.fileName, seconds: Self.resumeSeconds)

        var player = await open(environment)
        try await until(60) { self.playing(player) }
        let engine = try XCTUnwrap(player.playbackEngine)
        print("MKV_LIVE tracks: \(engine.tracks.map { "\($0.id) \($0.kind) \($0.codec) \($0.language ?? "-")" })")
        print("MKV_LIVE resumed at \(engine.currentTime.seconds) audio \(engine.selectedAudioTrackID.map(String.init) ?? "none")")
        XCTAssertGreaterThanOrEqual(engine.currentTime.seconds, Self.resumeSeconds - 1)
        XCTAssertLessThan(engine.currentTime.seconds, Self.resumeSeconds + 30)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "The Ancient Magus' Bride")

        let playable = Set(engine.tracks.map(\.id)).subtracting(engine.unsupportedTracks.map(\.id))
        let other = try XCTUnwrap(engine.tracks.first { $0.kind == .audio && playable.contains($0.id) && $0.id != engine.selectedAudioTrackID },
                                  "The film should offer a second playable audio track")
        try await Task.sleep(for: .seconds(2))
        player.chooseAudio(other.id)
        try await until(60) { engine.selectedAudioTrackID == other.id && self.playing(player) }
        try await Task.sleep(for: .seconds(2))
        let leftAt = engine.currentTime.seconds
        print("MKV_LIVE switched to \(other.id) \(other.language ?? "-"), closing at \(leftAt)")
        try await close(player)
        let saved = try await store.playbackPosition(identifier: Self.identifier, fileName: Self.fileName)
        print("MKV_LIVE saved \(saved ?? -1)")
        XCTAssertEqual(saved ?? 0, leftAt, accuracy: 2)

        player = await open(environment)
        try await until(60) { self.playing(player) }
        let reopened = try XCTUnwrap(player.playbackEngine)
        print("MKV_LIVE reopened at \(reopened.currentTime.seconds) audio \(reopened.selectedAudioTrackID.map(String.init) ?? "none")")
        XCTAssertEqual(reopened.selectedAudioTrackID, other.id, "The chosen audio track was not remembered")
        XCTAssertGreaterThanOrEqual(reopened.currentTime.seconds, leftAt - 1)
        try await close(player)
    }
}
