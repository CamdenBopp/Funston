import Foundation
import os

/// One recording the listener stopped partway through.
struct ContinueListeningItem: Hashable, Sendable {
    let summary: ArtifactSummary
    /// Empty when the item's details couldn't be read and a download stands in.
    let tracks: [PlayableTrack]
    let trackIndex: Int
    let fileName: String
    let position: Double
    let duration: Double?
    /// Set only when the details couldn't be read; plays the downloaded file.
    let download: DownloadRecord?

    var trackTitle: String? {
        tracks.count > 1 && tracks.indices.contains(trackIndex) ? tracks[trackIndex].title : nil
    }

    var remaining: Double? { duration.map { max(0, $0 - position) } }

    /// Share played, for the tile's bar. Nil when the duration is unknown.
    var fractionPlayed: Double? {
        guard let duration, duration > 0 else { return nil }
        return min(1, max(0, position / duration))
    }

    /// Spoken and shown under the tile: time left when the duration is known,
    /// otherwise how far in the listener got.
    var progressDescription: String {
        if let remaining { return PlayerTimePresentation.spokenRemaining(remaining) }
        return PlayerTimePresentation.spokenPlayed(position)
    }
}

enum ContinueListening {
    /// Tiles on the shelf.
    static let maximumItems = 10
    /// Saved positions read per refresh. Finished, video and duplicate rows are
    /// skipped, so this is larger than the shelf.
    static let bookmarkLimit = 40

    private static let logger = Logger(subsystem: "com.camden.Funston", category: "ContinueListening")

    /// Newest bookmark per item, resolved to its audio track, without finished
    /// recordings or ones barely started. Details come from `detail`, which
    /// serves cached metadata first; `download` stands in when details fail.
    static func items(
        bookmarks: [PlaybackBookmark],
        detail: @Sendable (String) async throws -> ArtifactDetail,
        download: @Sendable (String, String) async -> DownloadRecord?
    ) async -> [ContinueListeningItem] {
        var seen = Set<String>()
        var items: [ContinueListeningItem] = []
        for bookmark in bookmarks where items.count < maximumItems {
            // An item's newest position is where the listener left it; older
            // rows for other tracks of the same item are history.
            guard seen.insert(bookmark.identifier).inserted else { continue }
            // Skip before any lookup when no duration could make it resumable.
            guard PlaybackController.restoredPosition(bookmark.seconds, duration: .nan) > 0 else { continue }
            if Task.isCancelled { return items }
            do {
                let detail = try await detail(bookmark.identifier)
                guard let index = detail.tracks.firstIndex(where: { $0.candidates.contains { $0.name == bookmark.fileName } }) else {
                    continue // Video and other non-audio positions share the table.
                }
                let track = detail.tracks[index]
                let file = track.candidates.first { $0.name == bookmark.fileName }
                let duration = MediaDuration.validated(track.duration ?? file?.duration)
                guard PlaybackController.restoredPosition(bookmark.seconds, duration: duration ?? .nan) > 0 else { continue }
                items.append(ContinueListeningItem(summary: detail.summary, tracks: detail.tracks, trackIndex: index,
                                                   fileName: bookmark.fileName, position: bookmark.seconds,
                                                   duration: duration, download: nil))
            } catch is CancellationError {
                return items
            } catch {
                logger.error("Details for \(bookmark.identifier, privacy: .public) unavailable: \(error.localizedDescription, privacy: .public)")
                guard let record = await download(bookmark.identifier, bookmark.fileName),
                      PlaybackController.playsDownloadedAudio(fileName: record.fileName) else { continue }
                items.append(ContinueListeningItem(
                    summary: ArtifactSummary(identifier: record.identifier, title: record.title, mediaType: .audio),
                    tracks: [], trackIndex: 0, fileName: record.fileName, position: bookmark.seconds,
                    duration: nil, download: record))
            }
        }
        return items
    }
}
