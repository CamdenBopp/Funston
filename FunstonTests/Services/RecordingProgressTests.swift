import XCTest
@testable import Funston

final class RecordingProgressTests: XCTestCase {
    func testLiveRowPresentationIgnoresClockTicksButTracksListeningChanges() {
        let file = ArchiveFile(name: "episode.mp3")
        let track = PlayableTrack(id: "episode", title: "Episode", candidates: [file], duration: 1800)
        let context = PlaybackContext(artifact: ArtifactSummary(identifier: "radio", title: "Radio"), tracks: [track], trackIndex: 0, file: file)
        func presentation(_ seconds: Double, phase: PlaybackPhase = .playing, identifier: String = "radio") -> RecordingPlaybackPresentation {
            RecordingPlaybackPresentation(context: context, phase: phase, elapsed: seconds, identifier: identifier)
        }
        XCTAssertEqual(presentation(600), presentation(601))
        XCTAssertNotEqual(presentation(600), presentation(631))
        XCTAssertNotEqual(presentation(4), presentation(5))
        XCTAssertNotEqual(presentation(1709), presentation(1710))
        XCTAssertNotEqual(presentation(600), presentation(600, phase: .ended))
        XCTAssertNotEqual(presentation(600), presentation(600, phase: .preparing))
        XCTAssertEqual(presentation(600, identifier: "other"), presentation(631, identifier: "other"))
    }

    @MainActor
    func testPlaybackSpeedPersistenceAndCollectionOverrides() throws {
        let suite = "SpeedTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = PlaybackSpeedPreference(defaults: defaults)
        XCTAssertEqual(preference.rate(), 1)
        preference.set(1.5)
        preference.set(2, collection: "radio")
        let restored = PlaybackSpeedPreference(defaults: defaults)
        XCTAssertEqual(restored.rate(), 1.5)
        XCTAssertEqual(restored.rate(collection: "radio"), 2)
        XCTAssertEqual(restored.rate(collection: "other"), 1.5)
        restored.removeOverride(collection: "radio")
        XCTAssertEqual(restored.rate(collection: "radio"), 1.5)
        preference.set(9)
        XCTAssertEqual(preference.rate(), 3)
        preference.set(0.1)
        XCTAssertEqual(preference.rate(), 0.5)
        XCTAssertEqual(PlaybackSpeedPreference.clamped(.nan), 1)
    }

    func testMarkUnplayedClearsCompletionAndResumeWithoutChangingOtherItems() async throws {
        let store = try SQLiteStore(url: URL(string: "file::memory:")!)
        for id in ["radio", "other"] {
            try await store.setPlaybackPosition(identifier: id, fileName: "episode.mp3", seconds: 100)
            try await store.markRecordingPlayed(identifier: id, fileName: "episode.mp3")
        }
        try await store.setRecordingPlayed(identifier: "radio", fileName: "episode.mp3", played: false)
        let radio = try await store.recordingProgress(identifier: "radio")
        let other = try await store.recordingProgress(identifier: "other")
        XCTAssertEqual(radio["episode.mp3"], RecordingProgress())
        XCTAssertEqual(other["episode.mp3"], RecordingProgress(seconds: 100, isPlayed: true))
        XCTAssertEqual(RecordingListeningState.partlyPlayed(225).text(duration: 1800), "26 min left")
    }

    func testCompletionHistorySurvivesResumeResetAndIsScopedToItsItem() async throws {
        let store = try SQLiteStore(url: URL(string: "file::memory:")!)
        try await store.setPlaybackPosition(identifier: "radio", fileName: "episode.mp3", seconds: 70)
        try await store.markRecordingPlayed(identifier: "radio", fileName: "episode.mp3")
        try await store.setPlaybackPosition(identifier: "radio", fileName: "episode.mp3", seconds: 0)
        try await store.setPlaybackPosition(identifier: "other", fileName: "episode.mp3", seconds: 20)
        let radio = try await store.recordingProgress(identifier: "radio")
        let other = try await store.recordingProgress(identifier: "other")
        XCTAssertEqual(radio["episode.mp3"], RecordingProgress(seconds: 0, isPlayed: true))
        XCTAssertEqual(other["episode.mp3"], RecordingProgress(seconds: 20, isPlayed: false))
    }

    func testShortStartsUnknownDurationsAndNearlyFinishedPositionsHaveDistinctStates() {
        XCTAssertEqual(RecordingListeningState.state(progress: RecordingProgress(seconds: 4), duration: 60), .unplayed)
        XCTAssertEqual(RecordingListeningState.state(progress: RecordingProgress(seconds: 20), duration: nil), .partlyPlayed(20))
        XCTAssertEqual(RecordingListeningState.state(progress: RecordingProgress(seconds: 57), duration: 60), .played)
        XCTAssertEqual(RecordingListeningState.state(progress: RecordingProgress(isPlayed: true), duration: nil), .played)
    }

    func testRecordingLabelUsesSentencesAndIncludesPositionAndListeningState() {
        let track = PlayableTrack(id: "episode", title: "Billy the Kid", candidates: [], duration: 1800)
        let label = RecordingListeningState.label(track: track, number: 2, count: 487, current: true, progress: RecordingProgress(seconds: 600))
        XCTAssertTrue(label.hasPrefix("Recording 2 of 487. Billy the Kid. Current recording. Partly played."))
        XCTAssertTrue(label.contains("20 minutes left."))
        XCTAssertTrue(label.contains("Length:"))
    }
}
