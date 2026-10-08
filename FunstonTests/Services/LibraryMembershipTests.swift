import XCTest
import SQLite3
import UIKit
@testable import Funston

final class LibraryMembershipTests: XCTestCase {
    private func resources() throws -> (SQLiteStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.sqlite")
        return (try SQLiteStore(url: url), url)
    }
    private func record(_ name: String, identifier: String = "item", state: DownloadState = .completed) -> DownloadRecord {
        DownloadRecord(key: identifier + name, identifier: identifier, fileName: name, title: "Archive item", expectedBytes: 100,
                       localPath: "/tmp/" + name, state: state, receivedBytes: 50, totalBytes: 100, errorMessage: nil, updatedAt: .now)
    }
    func testMultipleFilesShareOneMembershipAndKeepExplicitIntent() async throws {
        let (store, _) = try resources()
        try await store.upsertDownload(record("one.mp3"))
        let initial = try await store.librarySaveReason(identifier: "item")
        XCTAssertEqual(initial, .viaDownload)
        let artifact = ArtifactSummary(identifier: "item", title: "Full metadata", mediaType: .audio)
        try await store.saveArtifact(identifier: "item", snapshot: JSONEncoder().encode(artifact))
        try await store.upsertDownload(record("two.mp3"))
        let reason = try await store.librarySaveReason(identifier: "item")
        let saved = try await store.savedArtifacts()
        XCTAssertEqual(reason, .explicit)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(ArtifactSummary.self, from: saved[0]), artifact)
    }
    func testRemovingMembershipDoesNotHideOrReAddExistingTransfers() async throws {
        let (store, _) = try resources()
        var download = record("one.mp3", state: .downloading)
        try await store.upsertDownload(download)
        try await store.removeSavedArtifact(identifier: "item")
        download.state = .completed
        try await store.upsertDownload(download)
        let saved = try await store.savedArtifacts()
        let downloads = try await store.downloads()
        XCTAssertTrue(saved.isEmpty)
        XCTAssertEqual(downloads.count, 1)
        XCTAssertEqual(LibraryItem.project(saved: [], downloads: downloads, filter: .all).count, 1)
        XCTAssertEqual(LibraryItem.project(saved: [], downloads: downloads, filter: .downloads).count, 1)
        XCTAssertTrue(LibraryItem.project(saved: [], downloads: downloads, filter: .saved).isEmpty)
    }
    func testItemProjectionGroupsEveryExistingDownloadState() {
        let downloads = [record("one.mp3"), record("two.mp3", state: .downloading), record("three.mp3", state: .queued),
                         record("four.mp3", state: .failed), record("five.mp3", state: .cancelled), record("six.mp3", state: .missing)]
        let items = LibraryItem.project(saved: [], downloads: downloads, filter: .downloads)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.downloads.count, 6)
        XCTAssertEqual(items.first?.downloadSummary, "1 downloaded, 1 downloading, 1 queued, 1 failed, 1 cancelled, 1 missing")
        XCTAssertTrue(items.first?.accessibilityProgress?.contains("50%") == true)
    }
    func testInterruptedMigrationRollsBackAndRetryPreservesExplicitSaves() async throws {
        let (store, url) = try resources()
        let explicit = ArtifactSummary(identifier: "explicit", title: "Explicit save")
        try await store.saveArtifact(identifier: explicit.identifier, snapshot: JSONEncoder().encode(explicit))
        try await store.upsertDownload(record("one.mp3", identifier: "explicit"))
        try await store.upsertDownload(record("two.mp3", identifier: "download"))
        try await store.removeSavedArtifact(identifier: "download")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let prepare = """
        ALTER TABLE saved_artifacts DROP COLUMN save_reason;
        ALTER TABLE playback_positions DROP COLUMN explicitly_stopped;
        PRAGMA user_version=5;
        CREATE TRIGGER interrupt_import BEFORE INSERT ON saved_artifacts WHEN NEW.identifier='download'
        BEGIN SELECT RAISE(ABORT, 'simulated interruption'); END;
        """
        XCTAssertEqual(sqlite3_exec(handle, prepare, nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try SQLiteStore(url: url))
        XCTAssertEqual(try SQLiteStore.userVersion(handle), 5)
        XCTAssertEqual(sqlite3_exec(handle, "DROP TRIGGER interrupt_import", nil, nil, nil), SQLITE_OK)
        let retried = try SQLiteStore(url: url)
        let explicitReason = try await retried.librarySaveReason(identifier: "explicit")
        let downloadReason = try await retried.librarySaveReason(identifier: "download")
        let imported = try await retried.savedArtifacts()
        XCTAssertEqual(explicitReason, .explicit)
        XCTAssertEqual(downloadReason, .viaDownload)
        XCTAssertEqual(imported.count, 2)
        XCTAssertTrue(try imported.map { try JSONDecoder().decode(ArtifactSummary.self, from: $0) }.contains(explicit))
        let reopened = try SQLiteStore(url: url)
        let repeated = try await reopened.savedArtifacts()
        XCTAssertEqual(repeated.count, 2)
    }
    @MainActor
    func testLibraryFilterIsFirstContentAndSettingsHasLabel() async throws {
        let (store, url) = try resources()
        let environment = AppEnvironment(store: store, mediaDirectory: url.deletingLastPathComponent(), downloadSession: .ephemeral)
        await environment.downloads.waitUntilReady()
        try await environment.setSaved(ArtifactSummary(identifier: "saved", title: "Saved item"), saved: true)
        let controller = LibraryController(environment: environment, open: { _ in })
        let navigation = UINavigationController(rootViewController: controller)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        navigation.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        controller.collectionView.layoutIfNeeded()
        let headers = controller.collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader)
        let filter = try XCTUnwrap(headers.flatMap { $0.subviews }.compactMap { $0 as? UISegmentedControl }.first)
        XCTAssertEqual(filter.numberOfSegments, 3)
        XCTAssertEqual(filter.titleForSegment(at: 2), "Downloads")
        XCTAssertEqual(filter.accessibilityIdentifier, "libraryFilter")
        XCTAssertEqual(controller.navigationItem.rightBarButtonItem?.accessibilityLabel, "Settings")
        let row = try XCTUnwrap(controller.collectionView.cellForItem(at: IndexPath(item: 0, section: 0)))
        XCTAssertLessThan(filter.convert(filter.bounds, to: window).maxY, row.convert(row.bounds, to: window).maxY)
        XCTAssertTrue(row.accessibilityCustomActions?.contains { $0.name == "Remove from Library" } == true)
    }
    func testClearCachePreservesMembershipDownloadsAndPosition() async throws {
        let (store, _) = try resources()
        try await store.upsertDownload(record("one.mp3"))
        try await store.setPlaybackPosition(identifier: "item", fileName: "one.mp3", seconds: 42)
        try await store.storeCache(key: "search", kind: "search", response: Data(), snapshot: nil, maxAge: 3600)
        try await store.clearCache()
        let cached = try await store.cacheEntry(key: "search")
        let saved = try await store.savedArtifacts()
        let downloads = try await store.downloads()
        let position = try await store.playbackPosition(identifier: "item", fileName: "one.mp3")
        XCTAssertNil(cached)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(downloads.count, 1)
        XCTAssertEqual(position, 42)
    }
}
