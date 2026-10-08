import AVFoundation
import MediaPlayer
import XCTest
@testable import Funston

@MainActor
final class PlaybackLifecyclePolishTests: XCTestCase {
    private func fixture(corrupt: Bool = false, seconds: Int = 10) async throws -> (SQLiteStore, DownloadManager, DownloadRecord) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "audio-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "fixture--track.wav")
        if corrupt { try Data("Invalid audio fixture".utf8).write(to: url) }
        else {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let frames = AVAudioFrameCount(8_000 * seconds)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            buffer.floatChannelData?[0].initialize(repeating: 0, count: Int(frames))
            try file.write(from: buffer)
        }
        let store = try SQLiteStore(url: URL(string: "file::memory:")!)
        let record = DownloadRecord(key: DownloadManager.key(identifier: "lifecycle", fileName: "track.wav"),
            identifier: "lifecycle", fileName: "track.wav", title: "Lifecycle", expectedBytes: nil,
            localPath: url.path, state: .completed, receivedBytes: 0, totalBytes: nil,
            errorMessage: nil, updatedAt: .now)
        try await store.upsertDownload(record)
        let downloads = DownloadManager(store: store, mediaDirectory: directory, sessionConfiguration: .ephemeral)
        await downloads.waitUntilReady()
        return (store, downloads, record)
    }

    private func until(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Audio lifecycle did not settle", file: file, line: line)
    }

    func testPlaybackSpeedUpdatesPlayerAndNowPlayingWhilePaused() async throws {
        let (store, downloads, record) = try await fixture()
        let player = AVPlayer()
        let playback = PlaybackController(store: store, downloads: downloads, player: player,
            audioSessionActivator: {}, audioSessionDeactivator: {}, artworkLoader: { _ in throw URLError(.cancelled) })
        let original = playback.playbackRate
        defer { playback.setPlaybackSpeed(original) }
        playback.playDownloaded(record, autoplay: false)
        try await until { playback.phase == .paused }
        playback.setPlaybackSpeed(1.5)
        XCTAssertEqual(player.defaultRate, 1.5)
        XCTAssertEqual(player.rate, 0, "Setting speed must keep paused playback paused")
        XCTAssertEqual(player.currentItem?.audioTimePitchAlgorithm, .timeDomain)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double, 1.5)
    }

    func testLastTrackCompletionReleasesSessionAndKeepsEndedState() async throws {
        let (store, downloads, record) = try await fixture()
        let player = AVPlayer()
        var deactivations = 0
        let playback = PlaybackController(store: store, downloads: downloads, player: player,
            audioSessionActivator: {}, audioSessionDeactivator: { deactivations += 1 },
            artworkLoader: { _ in throw URLError(.cancelled) })
        playback.playDownloaded(record, autoplay: false)
        try await until { playback.phase == .paused }
        let item = try XCTUnwrap(player.currentItem)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        try await until { deactivations == 1 }
        XCTAssertEqual(playback.phase, .ended)
        XCTAssertFalse(playback.wantsToPlay)
        XCTAssertTrue(player.currentItem === item, "Completion keeps the selected track available for replay.")
        XCTAssertEqual(player.rate, 0)
        let history = try await playback.savedRecordingProgress(identifier: record.identifier)
        XCTAssertEqual(history[record.fileName]?.isPlayed, true, "Completion must remain visible after its resume position resets.")
        let position = try await store.playbackPosition(identifier: record.identifier, fileName: record.fileName)
        XCTAssertEqual(position, 0)
    }

    func testTerminalItemFailureReleasesSessionWithoutBecomingPaused() async throws {
        let (store, downloads, record) = try await fixture(corrupt: true)
        var deactivations = 0
        let playback = PlaybackController(store: store, downloads: downloads,
            audioSessionActivator: {}, audioSessionDeactivator: { deactivations += 1 },
            artworkLoader: { _ in throw URLError(.cancelled) })
        playback.playDownloaded(record)
        try await until { deactivations == 1 }
        guard case .failed = playback.phase else { return XCTFail("Failure must remain visible after releasing audio.") }
        XCTAssertFalse(playback.wantsToPlay)
        XCTAssertEqual(playback.context?.file.name, record.fileName)
    }

    func testImmediateReloadRestoresPositionQueuedByPause() async throws {
        // Long enough that 20 s is neither a short listen nor finished.
        let (store, downloads, record) = try await fixture(seconds: 60)
        let player = AVPlayer()
        let playback = PlaybackController(store: store, downloads: downloads, player: player,
            audioSessionActivator: {}, audioSessionDeactivator: {},
            artworkLoader: { _ in throw URLError(.cancelled) })
        playback.playDownloaded(record, autoplay: false)
        try await until { playback.phase == .paused }
        let sought = await player.seek(to: CMTime(seconds: 20, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(sought)
        playback.pause()
        playback.playDownloaded(record, autoplay: false)
        try await until { playback.phase == .paused }
        XCTAssertEqual(player.currentTime().seconds, 20, accuracy: 0.05)
        XCTAssertFalse(playback.wantsToPlay)
    }
}
