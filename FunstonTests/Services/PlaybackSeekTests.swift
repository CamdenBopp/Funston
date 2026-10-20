import AVFoundation
import XCTest
@testable import Funston

/// A player whose seeks stay pending until the test lands them, the way a
/// streamed recording does on a phone. Until then currentTime reports the old
/// position, and the test fires the periodic time observer by hand.
private final class StalledSeekPlayer: AVPlayer {
    var reportedTime: CMTime?
    private(set) var tick: ((CMTime) -> Void)?
    private var pendingCompletion: ((Bool) -> Void)?
    private var pendingTarget: CMTime?

    override func currentTime() -> CMTime { reportedTime ?? super.currentTime() }

    override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) {
        seek(to: time, toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter) { _ in }
    }
    override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
                       completionHandler: @escaping @Sendable (Bool) -> Void) {
        pendingTarget = time
        pendingCompletion = completionHandler
    }
    func landSeek() {
        reportedTime = pendingTarget
        pendingCompletion?(true)
        pendingCompletion = nil
    }

    override func addPeriodicTimeObserver(forInterval interval: CMTime, queue: dispatch_queue_t?,
                                          using block: @escaping @Sendable (CMTime) -> Void) -> Any {
        tick = block
        return super.addPeriodicTimeObserver(forInterval: interval, queue: queue, using: block)
    }
}

@MainActor
final class PlaybackSeekTests: XCTestCase {
    private func fixture() async throws -> (SQLiteStore, DownloadManager, DownloadRecord) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "audio-seek-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "fixture--track.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(8_000 * 30)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        buffer.floatChannelData?[0].initialize(repeating: 0, count: Int(frames))
        try file.write(from: buffer)
        let store = try SQLiteStore(url: URL(string: "file::memory:")!)
        let record = DownloadRecord(key: DownloadManager.key(identifier: "seek", fileName: "track.wav"),
            identifier: "seek", fileName: "track.wav", title: "Seek", expectedBytes: nil,
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
        XCTAssertTrue(condition(), "Playback did not settle", file: file, line: line)
    }

    /// The recording on Camden's iPhone: let go of the scrubber at 16:20 and
    /// the bar flashed back to 1:47 for two frames before it showed 16:20.
    func testTimeTickWhileSeekIsPendingKeepsTheSeekTarget() async throws {
        let (store, downloads, record) = try await fixture()
        let player = StalledSeekPlayer()
        let playback = PlaybackController(store: store, downloads: downloads, player: player,
            audioSessionActivator: {}, audioSessionDeactivator: {}, artworkLoader: { _ in throw URLError(.cancelled) })
        playback.playDownloaded(record, autoplay: false)
        try await until { playback.phase == .paused }
        playback.beginVisibleProgress()
        defer { playback.endVisibleProgress() }
        let tick = try XCTUnwrap(player.tick)
        player.reportedTime = CMTime(seconds: 2, preferredTimescale: 600)

        playback.seek(to: 20)
        tick(player.currentTime())
        XCTAssertEqual(playback.elapsed, 20, accuracy: 0.01, "A tick before the seek lands must not show the old time")

        player.landSeek()
        try await Task.sleep(for: .milliseconds(50))
        player.reportedTime = CMTime(seconds: 21, preferredTimescale: 600)
        tick(player.currentTime())
        XCTAssertEqual(playback.elapsed, 21, accuracy: 0.01, "Once the seek lands, ticks follow the player again")
    }
}
