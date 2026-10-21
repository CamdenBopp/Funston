import AVFoundation
import MediaPlayer
import XCTest
import UIKit
@testable import Funston

@MainActor
final class SettingsStoreTests: XCTestCase {
    private func settings() -> SettingsStore {
        let name = "FunstonSettingsTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return SettingsStore(defaults: defaults)
    }

    func testDefaultsAndLegacyPreferences() {
        let name = "FunstonSettingsLegacy." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.defaultPlaybackSpeed, 1)
        XCTAssertEqual(store.skipBackSeconds, 15)
        XCTAssertEqual(store.skipForwardSeconds, 15)
        XCTAssertTrue(store.autoPlayNext)
        XCTAssertTrue(store.allowCellularDownloads)
        XCTAssertFalse(store.autoDeletePlayedDownloads)
        XCTAssertFalse(store.hideUnsupportedMedia)
        defaults.set(1.25, forKey: "playback.speed")
        defaults.set("pages", forKey: "pdf.readingLayout")
        defaults.set(PDFTextEngineID.appleVision, forKey: PDFTextEnginePreference.key)
        XCTAssertEqual(store.defaultPlaybackSpeed, 1.25)
        XCTAssertEqual(store.readingLayout, .pages)
        XCTAssertEqual(PDFTextEnginePreference(defaults: defaults).selectedID, PDFTextEngineID.appleVision)
        PDFTextEnginePreference(defaults: defaults, bookKey: "book").select(PDFTextEngineID.embedded)
        store.textRecognitionEngine = PDFTextEngineID.automatic
        XCTAssertEqual(PDFTextEnginePreference(defaults: defaults, bookKey: "book").selectedID, PDFTextEngineID.embedded)
    }

    /// Settings, Accessibility: books read page by page until the reader picks paragraphs, and the
    /// choice is stored under the key the reader and the device tests read.
    func testBookVoiceOverModelDefaultsToPageAndPersistsTheChoice() {
        let store = settings()
        XCTAssertEqual(store.bookVoiceOverModel, .page)
        var changes = 0
        let observer = NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: nil, queue: nil) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        store.bookVoiceOverModel = .paragraphs
        XCTAssertEqual(store.bookVoiceOverModel, .paragraphs)
        XCTAssertEqual(changes, 1, "An open book listens for this to rebuild its page")
        store.bookVoiceOverModel = .page
        XCTAssertEqual(store.bookVoiceOverModel, .page)
    }

    func testDefaultsDriveLivePlaybackAndRemoteIntervals() async throws {
        let store = try SQLiteStore(url: URL(string: "file::memory:")!)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let settings = settings()
        settings.defaultPlaybackSpeed = 1.5
        let downloads = DownloadManager(store: store, mediaDirectory: directory, sessionConfiguration: .ephemeral, settings: settings)
        settings.allowCellularDownloads = false
        let request = downloads.downloadRequest(identifier: "fixture", fileName: "track.mp3")
        XCTAssertFalse(request.allowsCellularAccess)
        XCTAssertFalse(request.allowsExpensiveNetworkAccess)
        settings.allowCellularDownloads = true
        XCTAssertTrue(downloads.downloadRequest(identifier: "fixture", fileName: "track.mp3").allowsCellularAccess)
        let player = AVPlayer()
        let playback = PlaybackController(store: store, downloads: downloads, player: player, settings: settings)
        XCTAssertEqual(playback.playbackRate, 1.5)
        settings.defaultPlaybackSpeed = 2
        settings.skipBackSeconds = 30
        settings.skipForwardSeconds = 60
        XCTAssertEqual(playback.playbackRate, 2)
        XCTAssertEqual(player.defaultRate, 2)
        XCTAssertEqual(playback.skipBackInterval, 30)
        XCTAssertEqual(playback.skipForwardInterval, 60)
        XCTAssertEqual(MPRemoteCommandCenter.shared().skipBackwardCommand.preferredIntervals, [30])
        XCTAssertEqual(MPRemoteCommandCenter.shared().skipForwardCommand.preferredIntervals, [60])
        settings.defaultPlaybackSpeed = .infinity
        XCTAssertEqual(playback.playbackRate, 1)
        await downloads.waitUntilReady()
    }

    func testBulkRemovalPreservesLibraryAndDefersLeasedFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(url: directory.appending(path: "test.sqlite"))
        let artifact = ArtifactSummary(identifier: "saved", title: "Saved", mediaType: .audio)
        try await store.saveArtifact(identifier: artifact.identifier, snapshot: JSONEncoder().encode(artifact))
        for name in ["one.mp3", "two.mp3"] {
            let identity = DownloadTaskIdentity(key: DownloadManager.key(identifier: "saved", fileName: name), identifier: "saved", fileName: name, expectedBytes: 3)
            let url = identity.destination(in: directory)
            try Data([1, 2, 3]).write(to: url)
            try await store.upsertDownload(DownloadRecord(key: identity.key, identifier: "saved", fileName: name, title: "Saved", expectedBytes: 3, localPath: url.path, state: .completed, receivedBytes: 3, totalBytes: 3, errorMessage: nil, updatedAt: .now))
        }
        let downloads = DownloadManager(store: store, mediaDirectory: directory, sessionConfiguration: .ephemeral, settings: settings())
        await downloads.waitUntilReady()
        XCTAssertEqual(downloads.storageUsedBytes, 6)
        let lease = try XCTUnwrap(downloads.acquireLocalURL(identifier: "saved", fileName: "one.mp3"))
        try await downloads.removeAllDownloads()
        XCTAssertTrue(downloads.records.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.path))
        downloads.releaseLocalURL(lease)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.path))
        let saved = try await store.savedArtifacts()
        XCTAssertEqual(saved.count, 1)
    }

    func testSleepDefaultAndAutoPlayNextAffectTransport() async throws {
        let store = try SQLiteStore(url: URL(string: "file::memory:")!)
        let settings = settings()
        settings.autoPlayNext = false
        settings.sleepTimerMinutes = -1
        let downloads = DownloadManager(store: store, mediaDirectory: FileManager.default.temporaryDirectory, sessionConfiguration: .ephemeral, settings: settings)
        let player = AVPlayer()
        let playback = PlaybackController(store: store, downloads: downloads, player: player, settings: settings)
        let tracks = ["one.mp3", "two.mp3"].map { PlayableTrack(id: $0, title: $0, candidates: [ArchiveFile(name: $0)]) }
        playback.load(artifact: ArtifactSummary(identifier: "test", title: "Test", mediaType: .audio), tracks: tracks, trackIndex: 0)
        XCTAssertEqual(playback.sleepTimer.setting, .endOfRecording)
        playback.sleepTimer.turnOff()
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: player.currentItem)
        XCTAssertEqual(playback.context?.trackIndex, 0)
        XCTAssertEqual(playback.phase, .ended)
        XCTAssertFalse(playback.wantsToPlay)
        await downloads.waitUntilReady()
    }

    func testOriginalVideoCompletionRunsOnlyAfterFinishedBookmark() async throws {
        let store = try SQLiteStore(url: URL(string: "file::memory:")!)
        var completions = 0
        let bookmark = OriginalVideoBookmark(store: store, identifier: "original", fileName: "film.mkv") { completions += 1 }
        try await bookmark.restore(duration: 60) { _ in }
        bookmark.save(seconds: 20, ended: false)
        await bookmark.flush()
        XCTAssertEqual(completions, 0)
        bookmark.save(seconds: 60, ended: true)
        await bookmark.flush()
        XCTAssertEqual(completions, 1)
        let position = try await store.playbackPosition(identifier: "original", fileName: "film.mkv")
        XCTAssertEqual(position, 0)
        let progress = try await store.recordingProgress(identifier: "original")
        XCTAssertTrue(progress["film.mkv"]?.isPlayed == true)
    }

    func testOriginalVideoRemoteSkipUsesConfiguredIntervals() {
        let remote = OriginalVideoRemoteControl(skipBack: 30, skipForward: 60) { _ in true }
        remote.activate()
        defer { remote.deactivate() }
        XCTAssertEqual(MPRemoteCommandCenter.shared().skipBackwardCommand.preferredIntervals, [30])
        XCTAssertEqual(MPRemoteCommandCenter.shared().skipForwardCommand.preferredIntervals, [60])
    }

    func testContentVisibilityReloadsLoadedSearchAndExploreButKeepsLibrary() async throws {
        let store = try SQLiteStore(url: URL(string: "file::memory:")!)
        let settings = settings()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let environment = AppEnvironment(store: store, mediaDirectory: directory, downloadSession: .ephemeral, settings: settings)
        let searchData = Data(#"{"response":{"numFound":2,"docs":[{"identifier":"playable","title":"Playable","mediatype":"audio"},{"identifier":"unsupported","title":"Unsupported","mediatype":"audio"}]}}"#.utf8)
        for scope in [MediaType.all, .audio] {
            let request = SearchRequest(scope: scope, pageSize: scope == .all ? 40 : 6, collection: "oldtimeradio")
            try await store.storeCache(key: CachingArchiveRepository.searchCacheKey(request), kind: "search", response: searchData, snapshot: nil, maxAge: 3600)
        }
        for (id, files) in [("playable", #"[{"name":"track.mp3"}]"#), ("unsupported", "[]")] {
            let metadata = Data("{\"metadata\":{\"identifier\":\"\(id)\",\"title\":\"\(id)\",\"mediatype\":\"audio\"},\"files\":\(files)}".utf8)
            try await store.storeCache(key: "metadata:" + id, kind: "metadata", response: metadata, snapshot: nil, maxAge: 3600)
        }
        let saved = ArtifactSummary(identifier: "unsupported", title: "Unsupported", mediaType: .audio)
        try await environment.setSaved(saved, saved: true)
        let search = SearchController(environment: environment, collection: ArchiveCollection.curated[0], open: { _ in })
        search.loadViewIfNeeded()
        let explore = ExploreController(environment: environment, openCollection: { _ in }, openArtifact: { _ in })
        explore.loadViewIfNeeded()
        explore.collectionView(explore.collectionView, willDisplay: UICollectionViewCell(), forItemAt: IndexPath(item: 0, section: 0))
        let source = try XCTUnwrap(explore.collectionView.dataSource as? UICollectionViewDiffableDataSource<String, String>)
        try await until {
            search.rows.contains { $0.id == "artifact:unsupported" } && source.snapshot().itemIdentifiers.contains("oldtimeradio:unsupported")
        }
        settings.hideUnsupportedMedia = true
        search.viewWillAppear(false)
        explore.viewWillAppear(false)
        try await until {
            search.rows.contains { $0.id == "artifact:playable" } && !search.rows.contains { $0.id == "artifact:unsupported" } &&
                source.snapshot().itemIdentifiers.contains("oldtimeradio:playable") && !source.snapshot().itemIdentifiers.contains("oldtimeradio:unsupported")
        }
        let library = LibraryController(environment: environment, open: { _ in })
        library.loadViewIfNeeded()
        library.viewWillAppear(false)
        try await until { library.rows.contains { $0.title == "Unsupported" } }
        settings.defaultPlaybackSpeed = 1.25
        search.viewWillAppear(false)
        explore.viewWillAppear(false)
        XCTAssertTrue(search.rows.contains { $0.id == "artifact:playable" }, "Other settings must not reset results")
        settings.hideUnsupportedMedia = false
        search.viewWillAppear(false)
        explore.viewWillAppear(false)
        try await until {
            search.rows.contains { $0.id == "artifact:unsupported" } && source.snapshot().itemIdentifiers.contains("oldtimeradio:unsupported")
        }
    }

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}
