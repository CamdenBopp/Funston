import XCTest
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
