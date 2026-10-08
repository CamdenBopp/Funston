import AppIntents
import Foundation
import UIKit

/// AudioPlaybackIntent keeps commands in the app process, sharing its live
/// player, sleep timer and background download session.
@MainActor
enum FunstonIntentRuntime {
    static func environment() async throws -> AppEnvironment {
        guard let delegate = UIApplication.shared.delegate as? AppDelegate else {
            throw FunstonIntentError.unavailable
        }
        return try await delegate.prepareEnvironment()
    }

    static func playback(in environment: AppEnvironment) async throws -> PlaybackController {
        await environment.restorePlaybackIfNeeded()
        guard environment.playback.context != nil, environment.playback.acceptsAudioCommands else {
            throw FunstonIntentError.noRecording
        }
        return environment.playback
    }

    static func timerDuration(minutes: Int) throws -> Duration {
        guard (1...1440).contains(minutes) else { throw FunstonIntentError.invalidMinutes }
        return .seconds(minutes * 60)
    }

    static func skipInterval(seconds: Int, direction: FunstonSkipDirection) throws -> Double {
        guard (1...3600).contains(seconds) else { throw FunstonIntentError.invalidSeconds }
        return Double(seconds) * (direction == .backward ? -1 : 1)
    }

    static func resumeIndex(in detail: ArtifactDetail, bookmarks: [PlaybackBookmark]) -> Int {
        guard let bookmark = bookmarks.first(where: { $0.identifier == detail.summary.identifier }),
              let index = detail.tracks.firstIndex(where: { $0.candidates.contains { $0.name == bookmark.fileName } }) else { return 0 }
        return index
    }
}

enum FunstonIntentError: LocalizedError, Equatable {
    case unavailable, noRecording, invalidMinutes, invalidSeconds, invalidSpeed, noNext, notAudio, unavailableSavedItem
    var errorDescription: String? {
        switch self {
        case .unavailable: "Funston could not open its library. Open the app and try again."
        case .noRecording: "Choose an audio recording in Funston first."
        case .invalidMinutes: "Set the sleep timer for between 1 and 1,440 minutes."
        case .invalidSeconds: "Skip between 1 and 3,600 seconds."
        case .invalidSpeed: "Choose a playback speed between 0.5 and 3 times."
        case .noNext: "This is the last recording in the list."
        case .notAudio: "This item has no supported audio recordings."
        case .unavailableSavedItem: "This item is no longer in your saved audio library."
        }
    }
}

enum FunstonSkipDirection: String, AppEnum {
    case forward, backward
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Direction")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .forward: "Forward", .backward: "Backward"
    ]
}

struct SetFunstonSleepTimerIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Set Sleep Timer"
    static let description = IntentDescription("Pause Funston after a chosen number of minutes, using its existing fade-out sleep timer.")
    @Parameter(title: "Minutes", default: 30, inclusiveRange: (1, 1440)) var minutes: Int
    static var parameterSummary: some ParameterSummary { Summary("Set a sleep timer for \(\.$minutes) minutes") }
    @MainActor func perform() async throws -> some IntentResult {
        let duration = try FunstonIntentRuntime.timerDuration(minutes: minutes)
        let environment = try await FunstonIntentRuntime.environment()
        let playback = try await FunstonIntentRuntime.playback(in: environment)
        playback.sleepTimer.start(after: duration)
        return .result()
    }
}

struct StopFunstonAtEndIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Stop at End of Recording"
    static let description = IntentDescription("Stop playback when the current recording finishes instead of advancing to the next.")
    @MainActor func perform() async throws -> some IntentResult {
        let environment = try await FunstonIntentRuntime.environment()
        let playback = try await FunstonIntentRuntime.playback(in: environment)
        playback.sleepTimer.stopAtEndOfRecording()
        return .result()
    }
}

struct CancelFunstonSleepTimerIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Cancel Sleep Timer"
    static let description = IntentDescription("Turn off Funston’s countdown or end-of-recording sleep timer.")
    @MainActor func perform() async throws -> some IntentResult {
        let environment = try await FunstonIntentRuntime.environment()
        environment.playback.sleepTimer.turnOff()
        return .result()
    }
}

struct ResumeFunstonIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Listening"
    static let description = IntentDescription("Resume the current recording, or restore your last recording and listening position when Funston is closed.")
    @MainActor func perform() async throws -> some IntentResult {
        let environment = try await FunstonIntentRuntime.environment()
        let playback = try await FunstonIntentRuntime.playback(in: environment)
        playback.play()
        return .result()
    }
}

struct PauseFunstonIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause Playback"
    static let description = IntentDescription("Pause Funston and keep your listening position.")
    @MainActor func perform() async throws -> some IntentResult {
        let environment = try await FunstonIntentRuntime.environment()
        environment.playback.pause()
        return .result()
    }
}

struct NextFunstonRecordingIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Recording"
    static let description = IntentDescription("Move to the next recording in the current list, preserving whether playback is playing or paused.")
    @MainActor func perform() async throws -> some IntentResult {
        let environment = try await FunstonIntentRuntime.environment()
        let playback = try await FunstonIntentRuntime.playback(in: environment)
        guard let context = playback.context, context.trackIndex + 1 < context.tracks.count else { throw FunstonIntentError.noNext }
        playback.nextTrack()
        return .result()
    }
}

struct PreviousFunstonRecordingIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Recording"
    static let description = IntentDescription("Go to the previous recording, or restart this recording if you have listened for more than five seconds.")
    @MainActor func perform() async throws -> some IntentResult {
        let environment = try await FunstonIntentRuntime.environment()
        let playback = try await FunstonIntentRuntime.playback(in: environment)
        playback.previousTrack()
        return .result()
    }
}

struct SkipFunstonIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip in Recording"
    static let description = IntentDescription("Skip forward or backward by a chosen number of seconds.")
    @Parameter(title: "Direction", default: .forward) var direction: FunstonSkipDirection
    @Parameter(title: "Seconds", default: 15, inclusiveRange: (1, 3600)) var seconds: Int
    static var parameterSummary: some ParameterSummary { Summary("Skip \(\.$direction) \(\.$seconds) seconds") }
    @MainActor func perform() async throws -> some IntentResult {
        let interval = try FunstonIntentRuntime.skipInterval(seconds: seconds, direction: direction)
        let environment = try await FunstonIntentRuntime.environment()
        let playback = try await FunstonIntentRuntime.playback(in: environment)
        playback.skip(by: interval)
        return .result()
    }
}

struct FunstonSavedAudio: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Saved Audio Item")
    static let defaultQuery = FunstonSavedAudioQuery()
    let id: String
    let title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct FunstonSavedAudioQuery: EntityStringQuery {
    @MainActor private func all() async throws -> [FunstonSavedAudio] {
        let environment = try await FunstonIntentRuntime.environment()
        // Read persistence directly so query failures aren't mistaken for an empty library.
        return try await LibraryPersistence(store: environment.store).all()
            .filter { $0.mediaType == .audio }
            .map { FunstonSavedAudio(id: $0.identifier, title: $0.title) }
    }
    func entities(for identifiers: [String]) async throws -> [FunstonSavedAudio] {
        let saved = try await all()
        return identifiers.compactMap { id in saved.first { $0.id == id } }
    }
    func suggestedEntities() async throws -> [FunstonSavedAudio] { try await all() }
    func entities(matching string: String) async throws -> [FunstonSavedAudio] {
        try await all().filter { $0.title.localizedCaseInsensitiveContains(string) || $0.id.localizedCaseInsensitiveContains(string) }
    }
}

struct PlayFunstonSavedAudioIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Saved Audio"
    static let description = IntentDescription("Choose an audio item from your Funston library and resume its last recording and saved position. Available downloads play locally.")
    @Parameter(title: "Item") var item: FunstonSavedAudio
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$item)") }
    @MainActor func perform() async throws -> some IntentResult {
        let environment = try await FunstonIntentRuntime.environment()
        guard environment.playback.acceptsAudioCommands else { throw FunstonIntentError.noRecording }
        guard try await LibraryPersistence(store: environment.store).all().contains(where: { $0.identifier == item.id && $0.mediaType == .audio }) else {
            throw FunstonIntentError.unavailableSavedItem
        }
        let detail = try await environment.repository.detail(identifier: item.id)
        guard !detail.tracks.isEmpty else { throw FunstonIntentError.notAudio }
        let bookmarks = try await environment.store.recentPlaybackPositions(limit: ContinueListening.bookmarkLimit)
        let index = FunstonIntentRuntime.resumeIndex(in: detail, bookmarks: bookmarks)
        environment.playback.load(artifact: detail.summary, tracks: detail.tracks, trackIndex: index)
        return .result()
    }
}

struct SaveFunstonCurrentItemIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Save Current Item to Library"
    static let description = IntentDescription("Save the archive item containing the current audio recording to your Funston library.")
    @MainActor func perform() async throws -> some IntentResult {
        let environment = try await FunstonIntentRuntime.environment()
        let playback = try await FunstonIntentRuntime.playback(in: environment)
        guard let context = playback.context else { throw FunstonIntentError.noRecording }
        try await environment.setSaved(context.artifact, saved: true)
        return .result()
    }
}

struct GetFunstonCurrentRecordingIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Get Current Recording"
    static let description = IntentDescription("Return the current recording’s title and archive item as text for use in other shortcut steps.")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let environment = try await FunstonIntentRuntime.environment()
        let playback = try await FunstonIntentRuntime.playback(in: environment)
        guard let context = playback.context else { throw FunstonIntentError.noRecording }
        return .result(value: "\(context.track.title) — \(context.artifact.title)")
    }
}

struct FunstonShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ResumeFunstonIntent(), phrases: ["Resume listening in \(.applicationName)"], shortTitle: "Resume Listening", systemImageName: "play.fill")
        AppShortcut(intent: PauseFunstonIntent(), phrases: ["Pause \(.applicationName)"], shortTitle: "Pause Playback", systemImageName: "pause.fill")
        AppShortcut(intent: SetFunstonSleepTimerIntent(), phrases: ["Set a sleep timer in \(.applicationName)"], shortTitle: "Set Sleep Timer", systemImageName: "moon.zzz")
        AppShortcut(intent: StopFunstonAtEndIntent(), phrases: ["Stop at the end of the recording in \(.applicationName)"], shortTitle: "Stop at End", systemImageName: "moon.zzz.fill")
        AppShortcut(intent: PlayFunstonSavedAudioIntent(), phrases: ["Play \(\.$item) in \(.applicationName)"], shortTitle: "Play Saved Audio", systemImageName: "books.vertical")
    }
}

struct SetFunstonPlaybackSpeedIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Set Playback Speed"
    static let description = IntentDescription("Set Funston’s global listening speed, preserving pitch.")
    @Parameter(title: "Speed", default: 1, inclusiveRange: (0.5, 3)) var speed: Double
    static var parameterSummary: some ParameterSummary { Summary("Set playback speed to \(\.$speed) times") }
    @MainActor func perform() async throws -> some IntentResult {
        let environment = try await FunstonIntentRuntime.environment()
        guard speed.isFinite, (0.5...3).contains(speed) else { throw FunstonIntentError.invalidSpeed }
        environment.playback.setPlaybackSpeed(speed)
        return .result()
    }
}
