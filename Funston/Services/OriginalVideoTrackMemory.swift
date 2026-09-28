import Foundation
import os
import ArchivePlayerCore

/// Which audio or caption track the viewer picked for one file.
enum TrackChoice: Equatable, Sendable {
    case off
    case track(UInt32)
}

/// A language the viewer prefers across items. Captions can also be "off".
enum LanguagePreference: Equatable, Sendable {
    case off
    case language(String)
}

enum RememberedTrackKind: String, Sendable {
    case audio, caption
}

/// Picks the MKV player's starting audio and caption tracks: the choice made for
/// this file wins, then the viewer's language from other items, then the engine's
/// default. A remembered track that this file no longer offers, or can't play,
/// falls through to the language rule instead of failing.
enum TrackMemory {
    /// ISO 639-2 bibliographic codes (the ones Matroska files use) that
    /// Foundation doesn't map to their two-letter language.
    private static let bibliographicCodes: [String: String] = [
        "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my", "chi": "zh", "cze": "cs", "dut": "nl",
        "fre": "fr", "geo": "ka", "ger": "de", "gre": "el", "ice": "is", "mac": "mk", "mao": "mi",
        "may": "ms", "per": "fa", "rum": "ro", "slo": "sk", "tib": "bo", "wel": "cy"
    ]
    private static let undetermined: Set<String> = ["und", "mul", "zxx", "mis"]

    /// "jpn", "ja" and "ja-JP" all become "ja". Nil for missing or undetermined.
    static func normalizedLanguage(_ tag: String?) -> String? {
        guard let tag = tag?.trimmingCharacters(in: .whitespaces).lowercased(), !tag.isEmpty else { return nil }
        let base = String(tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(tag))
        guard !undetermined.contains(base) else { return nil }
        if let mapped = bibliographicCodes[base] { return mapped }
        return Locale.Language(identifier: base).languageCode?.identifier ?? base
    }

    static func resolve(kind: MediaKind, tracks: [MediaTrack], isPlayable: (MediaTrack) -> Bool,
                        remembered: TrackChoice?, preferred: LanguagePreference?) -> TrackChoice? {
        let candidates = tracks.filter { $0.kind == kind && isPlayable($0) }
        switch remembered {
        case .off: return .off
        case .track(let id) where candidates.contains(where: { $0.id == id }): return .track(id)
        case .track, .none: break
        }
        switch preferred {
        case .off: return .off
        case .language(let language):
            guard let wanted = normalizedLanguage(language) else { return nil }
            let matches = candidates.filter { normalizedLanguage($0.language) == wanted }
            // A commentary or described track in your language is not the film's main track.
            let main = matches.first { $0.roles.isDisjoint(with: [.commentary, .visualImpaired]) }
            return (main ?? matches.first).map { .track($0.id) }
        case .none: return nil
        }
    }
}

/// Reads and writes the MKV player's remembered tracks for one file. Writes are
/// serialized and failures are logged; a failed write leaves the old choice.
@MainActor
final class OriginalVideoTrackMemory {
    private static let logger = Logger(subsystem: "com.camden.Funston", category: "Video")
    private let store: SQLiteStore
    private let identifier: String
    private let fileName: String
    private var persistence: Task<Void, Never>?

    init(store: SQLiteStore, identifier: String, fileName: String) {
        self.store = store; self.identifier = identifier; self.fileName = fileName
    }

    func startingChoices(tracks: [MediaTrack], playableAudio: (MediaTrack) -> Bool,
                         playableCaption: (MediaTrack) -> Bool) async -> (audio: TrackChoice?, caption: TrackChoice?) {
        await persistence?.value
        var audio: (TrackChoice?, LanguagePreference?) = (nil, nil)
        var caption: (TrackChoice?, LanguagePreference?) = (nil, nil)
        do {
            audio = (try await store.trackChoice(.audio, identifier: identifier, fileName: fileName),
                     try await store.preferredLanguage(.audio))
            caption = (try await store.trackChoice(.caption, identifier: identifier, fileName: fileName),
                       try await store.preferredLanguage(.caption))
        } catch {
            Self.logger.error("Reading remembered film tracks failed: \(error.localizedDescription, privacy: .public)")
        }
        return (TrackMemory.resolve(kind: .audio, tracks: tracks, isPlayable: playableAudio, remembered: audio.0, preferred: audio.1),
                TrackMemory.resolve(kind: .subtitle, tracks: tracks, isPlayable: playableCaption, remembered: caption.0, preferred: caption.1))
    }

    /// Records a choice for this file and, when it names a language, for other items too.
    /// Turning audio off is kept for this file only; turning captions off carries over.
    func remember(_ kind: RememberedTrackKind, choice: TrackChoice, language: String?) {
        let preference: LanguagePreference?
        switch (kind, choice) {
        case (.caption, .off): preference = .off
        case (_, .track): preference = TrackMemory.normalizedLanguage(language).map { .language($0) }
        case (.audio, .off): preference = nil
        }
        let previous = persistence
        let store = store, identifier = identifier, fileName = fileName
        persistence = Task {
            await previous?.value
            do {
                try await store.setTrackChoice(choice, kind: kind, identifier: identifier, fileName: fileName)
                if let preference { try await store.setPreferredLanguage(preference, kind: kind) }
            } catch {
                Self.logger.error("Saving the film track choice failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func flush() async { await persistence?.value }
}
