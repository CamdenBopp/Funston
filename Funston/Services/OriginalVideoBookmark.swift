import Foundation
import os

/// Saved position for the MKV player, with the rules `VideoPlaybackSession` uses
/// for the AVKit film player: writes are serialized, a finished film is saved as 0,
/// and nothing is written until the saved position has been restored.
@MainActor
final class OriginalVideoBookmark {
    /// Same cadence as VideoPlaybackSession's periodic time observer.
    static let periodicSaveInterval: TimeInterval = 15
    private static let logger = Logger(subsystem: "com.camden.Funston", category: "Video")

    private let store: SQLiteStore
    private let identifier: String
    private let fileName: String
    /// True until `restore` finishes. A pause, tick or background save that fires
    /// while the restore seek is still in flight would read the clock at ~0 and
    /// overwrite the position the viewer is about to resume from.
    private(set) var restoring = true
    private var persistence: Task<Void, Never>?
    private var lastSave: Date?

    init(store: SQLiteStore, identifier: String, fileName: String) {
        self.store = store; self.identifier = identifier; self.fileName = fileName
    }

    /// Reads the saved position once queued writes have landed and seeks there.
    /// If the seek fails, saving stays off so the stored position is kept.
    func restore(duration: Double?, seek: @MainActor (Double) async throws -> Void) async throws {
        restoring = true
        await persistence?.value
        var saved = 0.0
        do { saved = try await store.playbackPosition(identifier: identifier, fileName: fileName) ?? 0 }
        catch { Self.logger.error("Reading the saved film position failed: \(error.localizedDescription, privacy: .public)") }
        let position = PlaybackController.restoredPosition(saved, duration: duration ?? .nan)
        if position > 0 { try await seek(position) }
        restoring = false
        lastSave = Date()
    }

    func save(seconds: Double, ended: Bool) {
        guard !restoring, let seconds = MediaDuration.validated(seconds) else { return }
        lastSave = Date()
        let position = ended ? 0 : seconds
        let previous = persistence
        let store = store, identifier = identifier, fileName = fileName
        persistence = Task {
            await previous?.value
            do { try await store.setPlaybackPosition(identifier: identifier, fileName: fileName, seconds: position) }
            catch { Self.logger.error("Saving the film position failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Called from the player's clock tick; writes at most once per interval.
    func saveIfDue(seconds: Double, ended: Bool, now: Date = Date()) {
        guard let lastSave, now.timeIntervalSince(lastSave) >= Self.periodicSaveInterval else { return }
        save(seconds: seconds, ended: ended)
    }

    /// The engine is going away; its clock no longer describes the film.
    func suspend() { restoring = true }

    func flush() async { await persistence?.value }
}
