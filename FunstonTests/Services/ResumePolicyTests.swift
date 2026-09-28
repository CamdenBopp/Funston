import AVFoundation
import XCTest
@testable import Funston

@MainActor
final class ResumePolicyTests: XCTestCase {
    private let hour = 3_600.0

    func testShortListensStartOver() {
        XCTAssertEqual(PlaybackController.restoredPosition(4.9, duration: hour), 0)
        XCTAssertEqual(PlaybackController.restoredPosition(0, duration: hour), 0)
        XCTAssertEqual(PlaybackController.restoredPosition(5, duration: hour), 5)
        XCTAssertEqual(PlaybackController.restoredPosition(4.9, duration: .nan), 0,
                       "The short-listen rule doesn't need a duration.")
    }

    func testNinetyFivePercentCountsAsFinished() {
        // An hour's last 10 s would be 3,590 s; 95% arrives much earlier.
        XCTAssertEqual(PlaybackController.restoredPosition(3_419, duration: hour), 3_419)
        XCTAssertEqual(PlaybackController.restoredPosition(3_420, duration: hour), 0)
        XCTAssertTrue(ResumePolicy.isFinished(3_420, duration: hour))
        XCTAssertFalse(ResumePolicy.isFinished(3_419, duration: hour))
    }

    func testLastTenSecondsCountAsFinishedInShortRecordings() {
        // 95% of 60 s is 57 s; the 10 s tail is the earlier line here.
        XCTAssertEqual(PlaybackController.restoredPosition(49.9, duration: 60), 49.9)
        XCTAssertEqual(PlaybackController.restoredPosition(50, duration: 60), 0)
        XCTAssertEqual(PlaybackController.restoredPosition(75, duration: 60), 0)
    }

    func testUnknownDurationStillResumes() {
        XCTAssertEqual(PlaybackController.restoredPosition(600, duration: .nan), 600)
        XCTAssertEqual(PlaybackController.restoredPosition(600, duration: .infinity), 600)
        XCTAssertEqual(PlaybackController.restoredPosition(600, duration: 0), 600)
        XCTAssertFalse(ResumePolicy.isFinished(600, duration: .nan))
    }

    func testInvalidPositionsStartOver() {
        XCTAssertEqual(PlaybackController.restoredPosition(.nan, duration: hour), 0)
        XCTAssertEqual(PlaybackController.restoredPosition(-30, duration: hour), 0)
        XCTAssertEqual(PlaybackController.restoredPosition(.infinity, duration: hour), 0)
    }

    /// Replacing the player's item jumps time to zero, which fires the periodic
    /// save. If that save lands while the bookmark is being restored, the restore
    /// reads zero and the listener loses their place. Switching from one
    /// recording to another, as Continue listening does, takes that path.
    func testSaveDuringRestoreKeepsTheSavedPosition() async throws {
        let (store, downloads, records) = try await audioFixture(seconds: 60, names: ["first.wav", "second.wav"])
        let (first, second) = (records[0], records[1])
        try await store.setPlaybackPosition(identifier: second.identifier, fileName: second.fileName, seconds: 30)
        let player = AVPlayer()
        let playback = PlaybackController(store: store, downloads: downloads, player: player,
            audioSessionActivator: {}, audioSessionDeactivator: {},
            artworkLoader: { _ in throw URLError(.cancelled) })
        playback.playDownloaded(first, autoplay: false)
        try await until { playback.phase == .paused }
        let sought = await player.seek(to: CMTime(seconds: 12, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(sought)

        playback.playDownloaded(second, autoplay: false)
        try await until { playback.phase == .paused && playback.context?.file.name == second.fileName }
        XCTAssertEqual(player.currentTime().seconds, 30, accuracy: 0.05)

        // The first save after the resume seek must write the resumed position.
        playback.appDidEnterBackground()
        var saved: Double?
        let deadline = Date().addingTimeInterval(2)
        repeat {
            try await Task.sleep(for: .milliseconds(20))
            saved = try await store.playbackPosition(identifier: second.identifier, fileName: second.fileName)
        } while Date() < deadline && saved.map({ abs($0 - 30) > 0.05 }) ?? true
        XCTAssertEqual(try XCTUnwrap(saved), 30, accuracy: 0.05)
        let firstSaved = try await store.playbackPosition(identifier: first.identifier, fileName: first.fileName)
        XCTAssertEqual(try XCTUnwrap(firstSaved), 12, accuracy: 0.05, "Leaving a recording keeps its place.")
    }

    private func until(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Playback did not settle", file: file, line: line)
    }

    private func audioFixture(seconds: Int, names: [String]) async throws -> (SQLiteStore, DownloadManager, [DownloadRecord]) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "resume-policy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let sampleRate = 8_000
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        buffer.floatChannelData?[0].initialize(repeating: 0, count: Int(frames))
        let store = try SQLiteStore(url: try XCTUnwrap(URL(string: "file::memory:")))
        var records: [DownloadRecord] = []
        for name in names {
            let url = directory.appending(path: name)
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            let record = DownloadRecord(key: DownloadManager.key(identifier: "resume", fileName: name),
                identifier: "resume", fileName: name, title: "Resume", expectedBytes: nil,
                localPath: url.path, state: .completed, receivedBytes: 0, totalBytes: nil,
                errorMessage: nil, updatedAt: .now)
            try await store.upsertDownload(record)
            records.append(record)
        }
        let downloads = DownloadManager(store: store, mediaDirectory: directory, sessionConfiguration: .ephemeral)
        await downloads.waitUntilReady()
        return (store, downloads, records)
    }
}
