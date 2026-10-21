import Combine
import Foundation

/// Global defaults live here; collection speed and book OCR choices remain overrides.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    static let didChange = Notification.Name("FunstonSettingsDidChange")
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func write(_ value: Any, key: String) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
    var defaultPlaybackSpeed: Double {
        get { Self.playbackSpeed(defaults: defaults) }
        set { objectWillChange.send(); Self.setPlaybackSpeed(newValue, defaults: defaults) }
    }
    static func playbackSpeed(defaults: UserDefaults = .standard) -> Double {
        PlaybackSpeedPreference.clamped(defaults.object(forKey: "playback.speed") as? Double ?? 1)
    }
    static func setPlaybackSpeed(_ value: Double, defaults: UserDefaults = .standard) {
        defaults.set(PlaybackSpeedPreference.clamped(value), forKey: "playback.speed")
        NotificationCenter.default.post(name: didChange, object: nil)
    }
    var skipBackSeconds: Int {
        get { defaults.object(forKey: "playback.skipBack") as? Int ?? 15 }
        set { write(newValue, key: "playback.skipBack") }
    }
    var skipForwardSeconds: Int {
        get { defaults.object(forKey: "playback.skipForward") as? Int ?? 15 }
        set { write(newValue, key: "playback.skipForward") }
    }
    var autoPlayNext: Bool {
        get { defaults.object(forKey: "playback.autoPlayNext") as? Bool ?? true }
        set { write(newValue, key: "playback.autoPlayNext") }
    }
    /// Zero is off; -1 means the end of the current recording.
    var sleepTimerMinutes: Int {
        get { defaults.integer(forKey: "playback.sleepTimerMinutes") }
        set { write(newValue, key: "playback.sleepTimerMinutes") }
    }
    var allowCellularDownloads: Bool {
        get { defaults.object(forKey: "downloads.allowCellular") as? Bool ?? true }
        set { write(newValue, key: "downloads.allowCellular") }
    }
    var autoDeletePlayedDownloads: Bool {
        get { defaults.bool(forKey: "downloads.autoDeletePlayed") }
        set { write(newValue, key: "downloads.autoDeletePlayed") }
    }
    var textRecognitionEngine: String {
        get { defaults.string(forKey: PDFTextEnginePreference.key) ?? PDFTextEngineID.automatic }
        set { write(newValue, key: PDFTextEnginePreference.key) }
    }
    var readingLayout: PDFReadingLayout {
        get { PDFReadingLayout(rawValue: defaults.string(forKey: "pdf.readingLayout") ?? "") ?? .continuous }
        set { write(newValue.rawValue, key: "pdf.readingLayout") }
    }
    /// How VoiceOver reads books: the page's text line by line, or paragraph by paragraph.
    var bookVoiceOverModel: EPUBAccessibilityModel {
        get { EPUBAccessibilityModel(rawValue: defaults.string(forKey: EPUBAccessibilityLog.modelKey) ?? "") ?? .page }
        set { write(newValue.rawValue, key: EPUBAccessibilityLog.modelKey) }
    }
    var hideUnsupportedMedia: Bool {
        get { defaults.bool(forKey: "content.hideUnsupportedMedia") }
        set { write(newValue, key: "content.hideUnsupportedMedia") }
    }
}
