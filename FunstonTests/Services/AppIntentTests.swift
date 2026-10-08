import AppIntents
import AVFoundation
import UIKit
import XCTest
@testable import Funston

@MainActor
final class AppIntentTests: XCTestCase {
    func testPlaybackSpeedIntentUsesTheExistingPlayerAndRejectsInvalidValues() async throws {
        try await withEnvironment { environment in
            let original = environment.playback.playbackRate
            defer { environment.playback.setPlaybackSpeed(original) }
            let intent = SetFunstonPlaybackSpeedIntent()
            intent.speed = 1.5
            _ = try await intent.perform()
            XCTAssertEqual(environment.playback.playbackRate, 1.5)
            intent.speed = 4
            do { _ = try await intent.perform(); XCTFail("Invalid speed must fail") }
            catch { XCTAssertEqual(error as? FunstonIntentError, .invalidSpeed) }
            XCTAssertEqual(environment.playback.playbackRate, 1.5)
            let collection = "intent-speed-" + UUID().uuidString
            let context = try XCTUnwrap(environment.playback.context)
            let scoped = ArtifactSummary(identifier: context.artifact.identifier, title: context.artifact.title,
                                         mediaType: .audio, collections: [collection])
            environment.playback.load(artifact: scoped, tracks: context.tracks, trackIndex: 0, autoplay: false)
            environment.playback.setPlaybackSpeed(1.25, forCollection: true)
            defer { environment.playback.useGlobalPlaybackSpeed() }
            intent.speed = 2
            _ = try await intent.perform()
            XCTAssertEqual(environment.playback.playbackRate, 2, "The shortcut must update an active collection override")
            XCTAssertTrue(environment.playback.hasCollectionSpeedOverride)
        }
    }

    func testSleepTimerActionsShareTheAppsTimerAndRejectInvalidDurations() async throws {
        try await withEnvironment { environment in
            var countdown = SetFunstonSleepTimerIntent()
            countdown.minutes = 17
            _ = try await countdown.perform()
            XCTAssertEqual(environment.playback.sleepTimer.minutesRemaining(), 17)
            _ = try await StopFunstonAtEndIntent().perform()
            XCTAssertEqual(environment.playback.sleepTimer.setting, .endOfRecording)
            XCTAssertTrue(environment.playback.stopsAfterCurrentRecording)
            _ = try await CancelFunstonSleepTimerIntent().perform()
            XCTAssertEqual(environment.playback.sleepTimer.setting, .off)
            XCTAssertFalse(environment.playback.stopsAfterCurrentRecording)
            countdown.minutes = 0
            do { _ = try await countdown.perform(); XCTFail("Invalid duration must fail") }
            catch { XCTAssertEqual(error as? FunstonIntentError, .invalidMinutes) }
            XCTAssertEqual(environment.playback.sleepTimer.setting, .off)
        }
    }

    func testSavedAudioQueryExcludesBooksAndPlayResumesTheBookmarkedTrack() async throws {
        try await withEnvironment { environment in
            let summary = ArtifactSummary(identifier: "intent-audio", title: "Saved Radio", mediaType: .audio)
            let book = ArtifactSummary(identifier: "intent-book", title: "Saved Book", mediaType: .texts)
            try await environment.setSaved(summary, saved: true)
            try await environment.setSaved(book, saved: true)
            let query = FunstonSavedAudioQuery()
            let suggested = try await query.suggestedEntities()
            XCTAssertEqual(suggested.map(\.id), [summary.identifier])
            let matching = try await query.entities(matching: "radio")
            XCTAssertEqual(matching.map(\.id), [summary.identifier])
            let tracks = [PlayableTrack(id: "first", title: "First", candidates: [ArchiveFile(name: "first.wav")]),
                          PlayableTrack(id: "second", title: "Second", candidates: [ArchiveFile(name: "second.wav")])]
            let detail = ArtifactDetail(summary: summary, tracks: tracks)
            let raw = Data(#"{"metadata":{"identifier":"intent-audio","title":"Saved Radio","mediatype":"audio"},"files":[{"name":"first.wav","title":"First"},{"name":"second.wav","title":"Second"}]}"#.utf8)
            try await environment.store.storeCache(key: "metadata:intent-audio", kind: "metadata", response: raw,
                snapshot: JSONEncoder().encode(detail), maxAge: 86_400)
            try await environment.store.setPlaybackPosition(identifier: summary.identifier, fileName: "second.wav", seconds: 8)
            var intent = PlayFunstonSavedAudioIntent()
            intent.item = try XCTUnwrap(suggested.first)
            _ = try await intent.perform()
            XCTAssertEqual(environment.playback.context?.trackIndex, 1)
            XCTAssertEqual(environment.playback.context?.tracks.count, 2)
            XCTAssertEqual(environment.playback.context?.track.title, "Second")
            environment.playback.pause()
            try await environment.setSaved(summary, saved: false)
            do { _ = try await intent.perform(); XCTFail("Removed items must fail clearly") }
            catch { XCTAssertEqual(error as? FunstonIntentError, .unavailableSavedItem) }
        }
    }

    func testCurrentRecordingCanBeReadAndSavedAndQueueBoundaryFailsClearly() async throws {
        try await withEnvironment { environment in
            let output = try await GetFunstonCurrentRecordingIntent().perform()
            XCTAssertEqual(output.value, "Fixture recording — Intent fixture")
            _ = try await SaveFunstonCurrentItemIntent().perform()
            XCTAssertEqual(environment.saved.map(\.identifier), ["intent-audio"])
            do { _ = try await NextFunstonRecordingIntent().perform(); XCTFail("Last recording must not silently succeed") }
            catch { XCTAssertEqual(error as? FunstonIntentError, .noNext) }
            var skip = SkipFunstonIntent()
            skip.seconds = -1
            do { _ = try await skip.perform(); XCTFail("Negative interval must fail") }
            catch { XCTAssertEqual(error as? FunstonIntentError, .invalidSeconds) }
            _ = try await PauseFunstonIntent().perform()
            XCTAssertFalse(environment.playback.wantsToPlay)
        }
    }

    private func withEnvironment(_ body: (AppEnvironment) async throws -> Void) async throws {
        let delegate = try XCTUnwrap(UIApplication.shared.delegate as? AppDelegate)
        let original = delegate.environment
        let directory = FileManager.default.temporaryDirectory.appending(path: "intent-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteStore(url: URL(string: "file::memory:")!)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240_000))
        buffer.frameLength = 240_000
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 240_000)
        for name in ["first.wav", "second.wav"] {
            let url = directory.appending(path: name)
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            try await store.upsertDownload(DownloadRecord(key: DownloadManager.key(identifier: "intent-audio", fileName: name),
                identifier: "intent-audio", fileName: name, title: "Intent fixture", expectedBytes: nil,
                localPath: url.path, state: .completed, receivedBytes: 0, totalBytes: nil, errorMessage: nil, updatedAt: .now))
        }
        let environment = AppEnvironment(store: store, mediaDirectory: directory, downloadSession: .ephemeral)
        await environment.downloads.waitUntilReady()
        delegate.environment = environment
        defer {
            environment.playback.pause()
            environment.playback.sleepTimer.turnOff()
            delegate.environment = original
            try? FileManager.default.removeItem(at: directory)
        }
        environment.playback.load(artifact: ArtifactSummary(identifier: "intent-audio", title: "Intent fixture", mediaType: .audio),
            tracks: [PlayableTrack(id: "first", title: "Fixture recording", candidates: [ArchiveFile(name: "first.wav")])],
            trackIndex: 0, autoplay: false)
        try await body(environment)
    }
}
