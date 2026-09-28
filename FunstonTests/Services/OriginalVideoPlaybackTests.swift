import XCTest
import AVFoundation
import AVKit
import UIKit
import MediaPlayer
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
    /// A second item holding the same film, for choices that carry across items.
    static let otherIdentifier = "mkv-fixture-other"

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
        // Player tasks can outlive a test's last statement. An in-memory store
        // avoids unlinking an open SQLite database at teardown.
        let store = try SQLiteStore(url: URL(string: "file::memory:")!)
        for identifier in [Self.identifier, Self.otherIdentifier] {
            let local = media.appending(path: identifier + ".mkv")
            try FileManager.default.copyItem(at: fixture, to: local)
            try await store.upsertDownload(DownloadRecord(
                key: DownloadManager.key(identifier: identifier, fileName: Self.fileName), identifier: identifier,
                fileName: Self.fileName, title: "Fixture", expectedBytes: nil, localPath: local.path, state: .completed,
                receivedBytes: 0, totalBytes: nil, errorMessage: nil, updatedAt: .now))
        }
        let environment = AppEnvironment(store: store, mediaDirectory: media, downloadSession: .ephemeral)
        await environment.downloads.waitUntilReady()
        return environment
    }

    func present(_ environment: AppEnvironment, identifier: String = identifier) async -> ArtifactOriginalVideoController {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        windows.append(window)
        let player = ArtifactOriginalVideoController(
            summary: ArtifactSummary(identifier: identifier, title: "Fixture film", mediaType: .movies),
            file: ArchiveFile(name: Self.fileName, duration: Self.fixtureDuration),
            environment: environment, downloadedOnly: true)
        let modal = UINavigationController(rootViewController: player)
        modal.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in root.present(modal, animated: false) { continuation.resume() } }
        return player
    }

    /// Dismisses like Done and waits until the film has handed audio back, as a
    /// person reopening a film seconds later would find it.
    func close(_ player: ArtifactOriginalVideoController) async {
        guard let modal = player.navigationController else { return }
        await withCheckedContinuation { continuation in modal.dismiss(animated: false) { continuation.resume() } }
        let deadline = Date().addingTimeInterval(5)
        while player.holdsPlayback, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(player.holdsPlayback, "The film did not release playback after closing")
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

    // MARK: Now Playing and remote commands

    func nowPlaying(_ key: String) -> Any? { MPNowPlayingInfoCenter.default().nowPlayingInfo?[key] }

    func testNowPlayingAndRemoteCommandsControlTheFilm() async throws {
        let environment = try await makeEnvironment()
        let player = await present(environment)
        try await until { self.playing(player) }
        let engine = try XCTUnwrap(player.playbackEngine)
        try await until { self.nowPlaying(MPNowPlayingInfoPropertyPlaybackRate) as? Float == 1 }
        XCTAssertEqual(nowPlaying(MPMediaItemPropertyTitle) as? String, "Fixture film")
        XCTAssertEqual(nowPlaying(MPNowPlayingInfoPropertyMediaType) as? UInt, MPNowPlayingInfoMediaType.video.rawValue)
        XCTAssertEqual(nowPlaying(MPMediaItemPropertyPlaybackDuration) as? Double, Self.fixtureDuration)
        let center = MPRemoteCommandCenter.shared()
        XCTAssertTrue(center.skipForwardCommand.isEnabled)
        XCTAssertEqual(center.skipForwardCommand.preferredIntervals, [15])

        let remote = try XCTUnwrap(player.remoteControl)
        XCTAssertEqual(remote.perform(.pause), .success)
        try await until { engine.state == .paused && self.nowPlaying(MPNowPlayingInfoPropertyPlaybackRate) as? Float == 0 }
        let pausedAt = engine.currentTime.seconds
        remote.perform(.skip(by: OriginalVideoRemoteControl.skipInterval))
        try await until { abs(engine.currentTime.seconds - (pausedAt + 15)) < 0.1 }
        try await until { (self.nowPlaying(MPNowPlayingInfoPropertyElapsedPlaybackTime) as? Double).map { $0 >= pausedAt + 14.9 } ?? false }
        remote.perform(.seek(to: 5))
        try await until { abs(engine.currentTime.seconds - 5) < 0.1 }
        remote.perform(.skip(by: -OriginalVideoRemoteControl.skipInterval))
        try await until { engine.currentTime.seconds < 0.1 }
        remote.perform(.toggle)
        try await until { self.playing(player) && self.nowPlaying(MPNowPlayingInfoPropertyPlaybackRate) as? Float == 1 }
        remote.perform(.toggle)
        try await until { engine.state == .paused }
        remote.perform(.play)
        try await until { self.playing(player) }
        await close(player)
        try await until { !remote.isActive }
        XCTAssertEqual(remote.perform(.play), .noActionableNowPlayingItem, "A closed film must not answer remote commands")
    }

    /// PlaybackController takes its commands back in releaseVideoPlayback and
    /// republishes the listening Now Playing. The film must not clear it afterwards.
    func testClosingTheFilmLeavesTheAudioPlayersNowPlaying() async throws {
        let environment = try await makeEnvironment()
        let audioURL = FileManager.default.temporaryDirectory.appending(path: "mkv-audio-" + UUID().uuidString + ".wav")
        addTeardownBlock { try? FileManager.default.removeItem(at: audioURL) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        try AVAudioFile(forWriting: audioURL, settings: format.settings).write(from: buffer)
        let media = try XCTUnwrap(environment.downloads.completedLocalURL(identifier: Self.identifier, fileName: Self.fileName))
            .deletingLastPathComponent()
        let local = media.appending(path: "track.wav")
        try FileManager.default.copyItem(at: audioURL, to: local)
        try await environment.store.upsertDownload(DownloadRecord(
            key: DownloadManager.key(identifier: "album", fileName: "track.wav"), identifier: "album",
            fileName: "track.wav", title: "Album", expectedBytes: nil, localPath: local.path, state: .completed,
            receivedBytes: 0, totalBytes: nil, errorMessage: nil, updatedAt: .now))
        let audioEnvironment = AppEnvironment(store: environment.store, mediaDirectory: media, downloadSession: .ephemeral)
        await audioEnvironment.downloads.waitUntilReady()
        let track = PlayableTrack(id: "track.wav", title: "Recording", candidates: [ArchiveFile(name: "track.wav")])
        audioEnvironment.playback.load(artifact: ArtifactSummary(identifier: "album", title: "Album", mediaType: .audio),
                                       tracks: [track], trackIndex: 0, autoplay: false)
        try await until { self.nowPlaying(MPMediaItemPropertyAlbumTitle) as? String == "Album" }

        let player = await present(audioEnvironment)
        try await until { self.playing(player) && self.nowPlaying(MPMediaItemPropertyTitle) as? String == "Fixture film" }
        XCTAssertNil(nowPlaying(MPMediaItemPropertyAlbumTitle))
        await close(player)
        try await until { self.nowPlaying(MPMediaItemPropertyAlbumTitle) as? String == "Album" }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(nowPlaying(MPMediaItemPropertyTitle) as? String, "Recording",
                       "Closing the film cleared the audio player's Now Playing")
        // The audio player owns these again, including the headset's toggle and
        // its own choice of skip buttons for this short track.
        let center = MPRemoteCommandCenter.shared()
        let audioCommands = audioEnvironment.playback.registeredRemoteCommands
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.skipForwardCommand, center.skipBackwardCommand, center.changePlaybackPositionCommand] {
            XCTAssertTrue(audioCommands.contains { $0 === command }, "The audio player lost \(command)")
        }
        XCTAssertTrue(center.togglePlayPauseCommand.isEnabled, "Closing the film disabled the headset's play and pause")
        XCTAssertTrue(center.changePlaybackPositionCommand.isEnabled)
        XCTAssertEqual(center.skipForwardCommand.isEnabled, PlaybackController.prefersSkipButtons(duration: 1))
        XCTAssertEqual(center.skipForwardCommand.preferredIntervals, [NSNumber(value: PlaybackController.remoteSkipInterval)])
    }

    // MARK: Remembered tracks

    func track(_ player: ArtifactOriginalVideoController, _ kind: MediaKind, _ language: String) throws -> MediaTrack {
        try XCTUnwrap(player.playbackEngine?.tracks.first { $0.kind == kind && $0.language == language })
    }

    func testChosenTracksAreRememberedPerFileAndLanguageCarriesAcrossItems() async throws {
        let environment = try await makeEnvironment()
        var player = await present(environment)
        try await until { self.playing(player) }
        let japaneseAudio = try track(player, .audio, "jpn")
        let japaneseCaptions = try track(player, .subtitle, "jpn")
        XCTAssertNotEqual(player.playbackEngine?.selectedAudioTrackID, japaneseAudio.id, "The fixture must start in English")
        // Let the first frames present; a switch before that is a separate, known edge.
        try await until { (player.playbackEngine?.currentTime.seconds ?? 0) > 0.5 }
        player.chooseAudio(japaneseAudio.id)
        try await until { player.playbackEngine?.selectedAudioTrackID == japaneseAudio.id && self.playing(player) }
        player.chooseCaption(japaneseCaptions.id)
        await close(player)

        player = await present(environment)
        try await until { self.playing(player) }
        XCTAssertEqual(player.playbackEngine?.selectedAudioTrackID, japaneseAudio.id, "This file's audio choice was forgotten")
        XCTAssertEqual(player.selectedCaptionTrackID, japaneseCaptions.id, "This file's caption choice was forgotten")
        await close(player)

        player = await present(environment, identifier: Self.otherIdentifier)
        try await until { self.playing(player) }
        XCTAssertEqual(player.playbackEngine?.selectedAudioTrackID, japaneseAudio.id, "The preferred audio language did not carry over")
        XCTAssertEqual(player.selectedCaptionTrackID, japaneseCaptions.id, "The preferred caption language did not carry over")
        player.chooseCaption(nil)
        await close(player)

        player = await present(environment)
        try await until { self.playing(player) }
        XCTAssertEqual(player.selectedCaptionTrackID, japaneseCaptions.id,
                       "Turning captions off elsewhere must not override this file's own choice")
        await close(player)
        player = await present(environment, identifier: Self.otherIdentifier)
        try await until { self.playing(player) }
        XCTAssertNil(player.selectedCaptionTrackID)
        await close(player)
    }

    func testTrackMemoryResolution() {
        let tracks = [
            MediaTrack(id: 1, kind: .video, codec: "V_MPEG4/ISO/AVC"),
            MediaTrack(id: 2, kind: .audio, codec: "A_AAC", language: "eng"),
            MediaTrack(id: 3, kind: .audio, codec: "A_AAC", language: "ger", roles: [.commentary]),
            MediaTrack(id: 4, kind: .audio, codec: "A_AAC", language: "ger"),
            MediaTrack(id: 5, kind: .audio, codec: "A_DTS", language: "jpn"),
            MediaTrack(id: 6, kind: .subtitle, codec: "S_TEXT/UTF8", language: "und")
        ]
        let playable: (MediaTrack) -> Bool = { $0.codec != "A_DTS" }
        func audio(_ remembered: TrackChoice?, _ preferred: LanguagePreference?) -> TrackChoice? {
            TrackMemory.resolve(kind: .audio, tracks: tracks, isPlayable: playable, remembered: remembered, preferred: preferred)
        }
        XCTAssertEqual(audio(.track(2), .language("de")), .track(2), "This file's choice beats the language")
        XCTAssertEqual(audio(nil, .language("de")), .track(4), "German matches ger and skips the commentary")
        XCTAssertEqual(audio(.track(9), .language("deu")), .track(4), "A track the file no longer has falls back to language")
        XCTAssertNil(audio(nil, .language("ja")), "An unplayable match keeps the default")
        XCTAssertNil(audio(nil, nil))
        XCTAssertEqual(audio(.off, .language("en")), .off)
        XCTAssertNil(TrackMemory.resolve(kind: .subtitle, tracks: tracks, isPlayable: { _ in true }, remembered: nil,
                                         preferred: .language("und")), "Undetermined is never a preference")
        XCTAssertEqual(TrackMemory.resolve(kind: .subtitle, tracks: tracks, isPlayable: { _ in true }, remembered: nil,
                                           preferred: .off), .off)
        XCTAssertEqual(TrackMemory.normalizedLanguage("jpn"), "ja")
        XCTAssertEqual(TrackMemory.normalizedLanguage("ja-JP"), "ja")
        XCTAssertEqual(TrackMemory.normalizedLanguage("fre"), "fr")
        XCTAssertEqual(TrackMemory.normalizedLanguage("fra"), "fr")
        XCTAssertNil(TrackMemory.normalizedLanguage("und"))
    }

    // MARK: Picture in Picture

    func testPictureInPictureAnswersFromTheFilm() async throws {
        let environment = try await makeEnvironment()
        let player = await present(environment)
        try await until { self.playing(player) && (player.playbackEngine?.currentTime.seconds ?? 0) > 0.5 }
        if AVPictureInPictureController.isPictureInPictureSupported() {
            XCTAssertNotNil(player.pictureInPictureSupport)
            XCTAssertEqual(player.navigationItem.leftBarButtonItem?.accessibilityLabel, "Picture in Picture")
        } else {
            XCTAssertNil(player.pictureInPictureSupport)
            XCTAssertNil(player.navigationItem.leftBarButtonItem, "Never offer Picture in Picture where it can't start")
        }
        // The same answers the system gets through the sample-buffer playback delegate.
        let transport = player.pictureInPictureTransport
        let engine = try XCTUnwrap(player.playbackEngine)
        XCTAssertEqual(transport.duration(), Self.fixtureDuration)
        XCTAssertFalse(transport.isPaused())
        transport.setPlaying(false)
        try await until { engine.state == .paused }
        XCTAssertTrue(transport.isPaused())
        let before = engine.currentTime.seconds
        var skipped = 0
        transport.skip(5) { skipped += 1 }
        // A second skip while the first is still seeking must still be answered,
        // or the system's skip button waits forever.
        transport.skip(5) { skipped += 1 }
        try await until { skipped == 2 }
        XCTAssertEqual(engine.currentTime.seconds, before + 5, accuracy: 0.1)
        transport.skip(-15) { skipped += 1 }
        try await until { skipped == 3 }
        XCTAssertEqual(engine.currentTime.seconds, 0, accuracy: 0.1, "Skipping back past the start lands on the start")
        transport.setPlaying(true)
        try await until { self.playing(player) && !transport.isPaused() }

        await close(player)
        XCTAssertNil(player.pictureInPictureSupport)
        XCTAssertNil(player.navigationItem.leftBarButtonItem)
        var afterClose = false
        transport.skip(5) { afterClose = true }
        XCTAssertTrue(afterClose, "A skip after close must still be answered")
    }

    func testPictureInPictureRange() {
        XCTAssertEqual(OriginalVideoPictureInPicture.timeRange(duration: 20),
                       CMTimeRange(start: .zero, duration: CMTime(seconds: 20, preferredTimescale: 600)))
        for unknown in [nil, 0, -1, Double.nan, .infinity] as [Double?] {
            let range = OriginalVideoPictureInPicture.timeRange(duration: unknown)
            XCTAssertEqual(range.start, .negativeInfinity)
            XCTAssertEqual(range.duration, .positiveInfinity)
        }
    }

    // MARK: VoiceOver

    func testShowPlaybackControlsActionOnTheVideo() async throws {
        let environment = try await makeEnvironment()
        let player = await present(environment)
        try await until { self.playing(player) && player.controlsShown }
        let surface = player.videoSurface
        XCTAssertTrue(surface.isAccessibilityElement)
        XCTAssertEqual(surface.accessibilityLabel, "Video")
        let action = try XCTUnwrap(surface.accessibilityCustomActions?.first { $0.name == "Show playback controls" })
        // Without VoiceOver the controls fade after a few seconds of playback.
        try await until(timeout: 10) { !player.controlsShown }
        XCTAssertEqual(action.actionHandler?(action), true)
        XCTAssertTrue(player.controlsShown, "The action must bring the controls back for VoiceOver")
        await close(player)
    }

    /// VoiceOver says "selected" for a menu item whose state is .on. Exactly one
    /// item per menu may carry it, and it must follow the viewer's choice.
    func testTrackAndSpeedMenusMarkTheSelectedOption() async throws {
        let environment = try await makeEnvironment()
        let player = await present(environment)
        try await until { self.playing(player) && (player.playbackEngine?.currentTime.seconds ?? 0) > 0.5 }
        func selected(_ menu: UIMenu?) -> [Int] {
            (menu?.children ?? []).enumerated().compactMap { ($0.element as? UIAction)?.state == .on ? $0.offset : nil }
        }
        let engine = try XCTUnwrap(player.playbackEngine)
        let audio = engine.tracks.filter { $0.kind == .audio }
        let captions = engine.tracks.filter { $0.kind == .subtitle }
        let japaneseAudio = try XCTUnwrap(audio.firstIndex { $0.language == "jpn" })
        let japaneseCaptions = try XCTUnwrap(captions.firstIndex { $0.language == "jpn" })
        // Each menu lists Off first, then the file's tracks in order.
        XCTAssertEqual(selected(player.trackMenus.audio), [1 + (audio.firstIndex { $0.id == engine.selectedAudioTrackID } ?? -2)])
        XCTAssertEqual(selected(player.trackMenus.captions), [0])
        XCTAssertEqual((player.trackMenus.speed?.children ?? []).compactMap { ($0 as? UIAction)?.state == .on ? $0.title : nil }, ["1×"])

        player.chooseAudio(audio[japaneseAudio].id)
        try await until { engine.selectedAudioTrackID == audio[japaneseAudio].id && self.selected(player.trackMenus.audio) == [1 + japaneseAudio] }
        player.chooseCaption(captions[japaneseCaptions].id)
        XCTAssertEqual(selected(player.trackMenus.captions), [1 + japaneseCaptions])
        player.chooseCaption(nil)
        XCTAssertEqual(selected(player.trackMenus.captions), [0])
        await close(player)
    }

    func selected(_ menu: UIMenu?) -> [Int] {
        (menu?.children ?? []).enumerated().compactMap { ($0.element as? UIAction)?.state == .on ? $0.offset : nil }
    }
}
