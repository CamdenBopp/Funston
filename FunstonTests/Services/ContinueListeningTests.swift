import XCTest
import SQLite3
@testable import Funston

final class ContinueListeningTests: XCTestCase {
    private func store() throws -> SQLiteStore {
        try SQLiteStore(url: try XCTUnwrap(URL(string: "file::memory:")))
    }

    private static func detail(_ identifier: String, tracks: [(String, Double?)], creator: String = "CBS Radio") -> ArtifactDetail {
        ArtifactDetail(
            summary: ArtifactSummary(identifier: identifier, title: "Title \(identifier)", creators: [creator], mediaType: .audio),
            tracks: tracks.map { PlayableTrack(id: $0.0, title: "Track \($0.0)", candidates: [ArchiveFile(name: $0.0)], duration: $0.1) })
    }

    private static func record(_ identifier: String, _ fileName: String) -> DownloadRecord {
        DownloadRecord(key: DownloadManager.key(identifier: identifier, fileName: fileName), identifier: identifier,
                       fileName: fileName, title: "Downloaded \(identifier)", expectedBytes: nil, localPath: "/tmp/\(fileName)",
                       state: .completed, receivedBytes: 0, totalBytes: nil, errorMessage: nil, updatedAt: .now)
    }

    func testRecentPositionsAreNewestFirstAndLimited() async throws {
        let store = try store()
        try await store.setPlaybackPosition(identifier: "a", fileName: "1.mp3", seconds: 10)
        try await store.setPlaybackPosition(identifier: "b", fileName: "1.mp3", seconds: 20)
        try await store.setPlaybackPosition(identifier: "c", fileName: "1.mp3", seconds: 30)
        try await store.setPlaybackPosition(identifier: "a", fileName: "1.mp3", seconds: 40)
        let recent = try await store.recentPlaybackPositions(limit: 2)
        XCTAssertEqual(recent.map(\.identifier), ["a", "c"])
        XCTAssertEqual(recent.first?.seconds, 40)
    }

    func testShelfSkipsFinishedShortAndVideoPositionsAndKeepsNewestPerItem() async {
        let details = [
            "show": Self.detail("show", tracks: [("ep1.mp3", 1_800), ("ep2.mp3", 1_800)]),
            "done": Self.detail("done", tracks: [("final.mp3", 1_800)]),
            "film": Self.detail("film", tracks: [("score.mp3", 600)]),
            "short": Self.detail("short", tracks: [("start.mp3", 1_800)])
        ]
        let bookmarks = [
            PlaybackBookmark(identifier: "show", fileName: "ep2.mp3", seconds: 1_080),
            PlaybackBookmark(identifier: "done", fileName: "final.mp3", seconds: 1_750), // 97%
            PlaybackBookmark(identifier: "film", fileName: "film.mp4", seconds: 300),    // not a track
            PlaybackBookmark(identifier: "short", fileName: "start.mp3", seconds: 3),
            PlaybackBookmark(identifier: "show", fileName: "ep1.mp3", seconds: 600)      // older
        ]
        let items = await ContinueListening.items(bookmarks: bookmarks, detail: { identifier in
            guard let detail = details[identifier] else { throw ArchiveError.missingItem }
            return detail
        }, download: { _, _ in nil })
        XCTAssertEqual(items.map(\.summary.identifier), ["show"])
        let show = try? XCTUnwrap(items.first)
        XCTAssertEqual(show?.trackIndex, 1)
        XCTAssertEqual(show?.fileName, "ep2.mp3")
        XCTAssertEqual(show?.trackTitle, "Track ep2.mp3")
        XCTAssertEqual(show?.progressDescription, "12 minutes left")
        XCTAssertEqual(show?.fractionPlayed ?? 0, 0.6, accuracy: 0.001)
    }

    func testExplicitStopMarkerSurvivesReopenAndClearsWhenListeningResumes() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "test.sqlite")
        let first = try SQLiteStore(url: url)
        try await first.setPlaybackPosition(identifier: "item", fileName: "track.mp3", seconds: 3, explicitlyStopped: true)
        let reopened = try SQLiteStore(url: url)
        let bookmark = try await reopened.playbackBookmark(identifier: "item", fileName: "track.mp3")
        XCTAssertTrue(bookmark?.isExplicitlyStopped == true)
        try await reopened.setPlaybackPosition(identifier: "item", fileName: "track.mp3", seconds: 3)
        let paused = try await reopened.recentPlaybackPositions(limit: 1)
        XCTAssertTrue(paused.first?.isExplicitlyStopped == true)
        try await reopened.setPlaybackPosition(identifier: "item", fileName: "track.mp3", seconds: 4, explicitlyStopped: false)
        let resumed = try await reopened.recentPlaybackPositions(limit: 1)
        XCTAssertFalse(resumed.first?.isExplicitlyStopped == true)
    }

    func testSchemaSixMigrationRetainsNormalBookmarks() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "test.sqlite")
        let current = try SQLiteStore(url: url)
        try await current.setPlaybackPosition(identifier: "existing", fileName: "track.mp3", seconds: 30)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, "ALTER TABLE playback_positions DROP COLUMN explicitly_stopped; PRAGMA user_version=6;", nil, nil, nil), SQLITE_OK)
        let migrated = try SQLiteStore(url: url)
        let bookmark = try await migrated.playbackBookmark(identifier: "existing", fileName: "track.mp3")
        XCTAssertEqual(bookmark?.seconds, 30)
        XCTAssertFalse(bookmark?.isExplicitlyStopped == true)
        XCTAssertEqual(try SQLiteStore.userVersion(handle), SQLiteStore.schemaVersion)
    }

    func testShelfShowsAtMostTenItems() async {
        let bookmarks = (0..<15).map { PlaybackBookmark(identifier: "item\($0)", fileName: "a.mp3", seconds: 60) }
        let items = await ContinueListening.items(bookmarks: bookmarks, detail: {
            Self.detail($0, tracks: [("a.mp3", 600)])
        }, download: { _, _ in nil })
        XCTAssertEqual(items.count, ContinueListening.maximumItems)
        XCTAssertEqual(items.first?.summary.identifier, "item0")
    }

    func testUnavailableDetailsFallBackToADownloadedRecording() async {
        let bookmarks = [
            PlaybackBookmark(identifier: "offline", fileName: "show.mp3", seconds: 720),
            PlaybackBookmark(identifier: "gone", fileName: "show.mp3", seconds: 720),
            PlaybackBookmark(identifier: "movie", fileName: "movie.mp4", seconds: 720)
        ]
        let items = await ContinueListening.items(bookmarks: bookmarks, detail: { _ in
            throw URLError(.notConnectedToInternet)
        }, download: { identifier, fileName in
            identifier == "gone" ? nil : Self.record(identifier, fileName)
        })
        XCTAssertEqual(items.map(\.summary.identifier), ["offline"])
        XCTAssertEqual(items.first?.download?.fileName, "show.mp3")
        XCTAssertNil(items.first?.fractionPlayed)
        XCTAssertEqual(items.first?.progressDescription, "12 minutes played")
    }

    func testRemainingTimeIsSpokenInWholeMinutes() {
        XCTAssertEqual(PlayerTimePresentation.spokenRemaining(24 * 60 + 10), "24 minutes left")
        XCTAssertEqual(PlayerTimePresentation.spokenRemaining(65 * 60), "1 hour, 5 minutes left")
        XCTAssertEqual(PlayerTimePresentation.spokenRemaining(60), "1 minute left")
        XCTAssertEqual(PlayerTimePresentation.spokenRemaining(20), "Less than a minute left")
        XCTAssertEqual(PlayerTimePresentation.spokenRemaining(.nan), "Time unavailable")
    }
}
