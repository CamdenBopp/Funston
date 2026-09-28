import XCTest
@testable import Archive

@MainActor
final class DownloadRelocationTests: XCTestCase {
    private func fixture() throws -> (SQLiteStore, URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadRelocation-" + UUID().uuidString)
        let old = root.appendingPathComponent("old-container/Library/Application Support/Archive/Media")
        let current = root.appendingPathComponent("new-container/Library/Application Support/Archive/Media")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        return (try SQLiteStore(url: URL(string: "file::memory:")!), root, old, current)
    }

    private func record(path: URL, identifier: String = "catalog", state: DownloadState = .completed) -> DownloadRecord {
        DownloadRecord(key: DownloadManager.key(identifier: identifier, fileName: "catalog.pdf"),
            identifier: identifier, fileName: "catalog.pdf", title: "Catalog", expectedBytes: 4,
            localPath: path.path, state: state, receivedBytes: 4, totalBytes: 4,
            errorMessage: state == .missing ? "Previously missing" : nil, updatedAt: .now)
    }

    func testContainerRelocationPreservesCompletedAndPreviouslyMissingDownloads() async throws {
        let (store, root, old, current) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([1, 2, 3, 4])
        // Cover both legacy hash.ext and current hash-attemptUUID.ext names.
        for (identifier, state) in [("legacy", DownloadState.completed), ("attempt", .missing)] {
            let key = DownloadManager.key(identifier: identifier, fileName: "catalog.pdf")
            let nameKey = identifier == "legacy" ? key : key + "-" + UUID().uuidString
            let previous = DownloadManager.localURL(key: nameKey, fileName: "catalog.pdf", directory: old)
            let relocated = current.appendingPathComponent(previous.lastPathComponent)
            try bytes.write(to: relocated)
            try await store.upsertDownload(record(path: previous, identifier: identifier, state: state))
        }
        let manager = DownloadManager(store: store, mediaDirectory: current, sessionConfiguration: .ephemeral)
        await manager.waitUntilReady()
        let saved = try await store.downloads()
        XCTAssertEqual(saved.count, 2)
        for item in saved {
            XCTAssertEqual(item.state, .completed)
            XCTAssertNil(item.errorMessage)
            let url = try XCTUnwrap(manager.completedLocalURL(identifier: item.identifier, fileName: item.fileName))
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, current.standardizedFileURL)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertEqual(item.localPath, url.path)
        }
    }

    func testUntrustedPathsCannotAdoptOrDeleteFiles() async throws {
        let (store, root, old, current) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([1, 2, 3, 4])
        var protectedFiles: [URL] = []
        for (identifier, name) in [
            ("plain", "notes.pdf"),
            ("wronghash", String(repeating: "a", count: 64) + ".pdf"),
            ("wrongextension", DownloadManager.key(identifier: "wrongextension", fileName: "catalog.pdf") + ".mp3")
        ] {
            let candidate = current.appendingPathComponent(name)
            try bytes.write(to: candidate)
            protectedFiles.append(candidate)
            try await store.upsertDownload(record(path: old.appendingPathComponent(name), identifier: identifier))
        }
        // A syntactically managed basename must not authorize following a symlink.
        let key = DownloadManager.key(identifier: "link", fileName: "catalog.pdf")
        let external = root.appendingPathComponent("outside.pdf")
        try bytes.write(to: external)
        let link = current.appendingPathComponent(key + ".pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        protectedFiles += [link, external]
        try await store.upsertDownload(record(path: old.appendingPathComponent(link.lastPathComponent), identifier: "link"))
        let traversalKey = DownloadManager.key(identifier: "traversal", fileName: "catalog.pdf")
        let traversalCandidate = current.appendingPathComponent(traversalKey + ".pdf")
        try bytes.write(to: traversalCandidate)
        protectedFiles.append(traversalCandidate)
        var traversal = record(path: old.appendingPathComponent(traversalCandidate.lastPathComponent), identifier: "traversal")
        traversal.localPath = old.path + "/../Media/" + traversalCandidate.lastPathComponent
        try await store.upsertDownload(traversal)
        try await store.upsertDownload(record(path: external, identifier: "outside"))
        // Unrecognized files/directories with no database record are not ours to delete.
        let unknown = current.appendingPathComponent("personal-notes.txt")
        try bytes.write(to: unknown)
        protectedFiles.append(unknown)
        let manager = DownloadManager(store: store, mediaDirectory: current, sessionConfiguration: .ephemeral)
        await manager.waitUntilReady()
        XCTAssertTrue(manager.records.allSatisfy { $0.state == .missing })
        for url in protectedFiles { XCTAssertEqual(try Data(contentsOf: url), bytes) }
    }

    func testRelocatedWrongSizeIsPreservedButNotCompleted() async throws {
        let (store, root, old, current) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = DownloadManager.key(identifier: "catalog", fileName: "catalog.pdf")
        let previous = old.appendingPathComponent(key + ".pdf")
        let candidate = current.appendingPathComponent(previous.lastPathComponent)
        try Data([1, 2]).write(to: candidate)
        try await store.upsertDownload(record(path: previous))
        let manager = DownloadManager(store: store, mediaDirectory: current, sessionConfiguration: .ephemeral)
        await manager.waitUntilReady()
        XCTAssertEqual(manager.records.first?.state, .missing)
        XCTAssertEqual(try Data(contentsOf: candidate), Data([1, 2]))
    }
}
