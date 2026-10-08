import XCTest
@testable import Funston

@MainActor
final class DownloadPermitCancellationTests: XCTestCase {
    private enum Mutation { case remove, cancel, removeAll }

    func testRemoveQueuedTransferDoesNotWaitForArchiveCapacityOrResurrect() async throws {
        try await verifyCancellation(.remove)
    }
    func testCancelQueuedTransferDoesNotWaitForArchiveCapacityOrLeakPermit() async throws {
        try await verifyCancellation(.cancel)
    }
    func testRemoveAllQueuedTransfersDoesNotWaitForArchiveCapacityOrResurrect() async throws {
        try await verifyCancellation(.removeAll)
    }

    func testLateMetadataCannotRestoreRemovedDownloadOrLibraryMembership() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(url: directory.appending(path: "test.sqlite"))
        let repository = HeldPermitMetadataRepository()
        defer { Task { await repository.complete() } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PermitProbeProtocol.self]
        let manager = DownloadManager(store: store, mediaDirectory: directory, sessionConfiguration: configuration, accessRepository: repository)
        await manager.waitUntilReady()
        let limiter = ArchiveNetworkPolicy.requestLimiter
        for _ in 0..<4 { try await limiter.acquire() }
        var held = 4
        defer { let count = held; Task { for _ in 0..<count { await limiter.release() } } }
        let startsBefore = PermitProbeProtocol.starts.value
        await manager.start(identifier: "permit-item", artifactTitle: "Queued recording", file: ArchiveFile(name: "queued.mp3", size: 3))
        let deadline = ContinuousClock.now + .seconds(1)
        while !(await repository.requested), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let didRequest = await repository.requested
        XCTAssertTrue(didRequest)
        let record = try XCTUnwrap(manager.records.first)
        XCTAssertEqual(record.state, .queued)
        // Combined removal invalidates the intent even if the lookup ignores Task cancellation.
        let removed = expectation(description: "Bulk removal completes during metadata validation")
        let removal = Task {
            try await manager.removeAllDownloads()
            try await store.removeSavedArtifact(identifier: record.identifier)
            removed.fulfill()
        }
        await fulfillment(of: [removed], timeout: 1)
        await repository.complete()
        for _ in 0..<held { await limiter.release() }
        held = 0
        try await removal.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(manager.records.isEmpty)
        let downloads = try await store.downloads()
        let membership = try await store.savedArtifact(identifier: record.identifier)
        XCTAssertTrue(downloads.isEmpty)
        XCTAssertNil(membership)
        XCTAssertEqual(PermitProbeProtocol.starts.value, startsBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.localPath))
    }

    func testRestrictedItemAndPrivateFileAreRejectedBeforeTransferResume() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let limiter = ArchiveNetworkPolicy.requestLimiter
        for _ in 0..<4 { try await limiter.acquire() }
        defer { Task { for _ in 0..<4 { await limiter.release() } } }
        let startsBefore = PermitProbeProtocol.starts.value
        for restricted in [true, false] {
            let store = try SQLiteStore(url: directory.appending(path: UUID().uuidString + ".sqlite"))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PermitProbeProtocol.self]
            let manager = DownloadManager(store: store, mediaDirectory: directory, sessionConfiguration: configuration,
                accessRepository: DeniedPermitFixtureRepository(restricted: restricted))
            await manager.waitUntilReady()
            await manager.start(identifier: "denied", artifactTitle: "Unavailable recording", file: ArchiveFile(name: "queued.mp3", size: 3))
            let deadline = ContinuousClock.now + .seconds(1)
            while manager.records.first?.state == .queued && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(manager.records.first?.state, .failed)
            XCTAssertNotNil(manager.records.first?.errorMessage)
        }
        XCTAssertEqual(PermitProbeProtocol.starts.value, startsBefore)
    }

    private func verifyCancellation(_ mutation: Mutation) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(url: directory.appending(path: "test.sqlite"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PermitProbeProtocol.self]
        let manager = DownloadManager(store: store, mediaDirectory: directory, sessionConfiguration: configuration,
                                      accessRepository: PermitFixtureRepository())
        await manager.waitUntilReady()
        let limiter = ArchiveNetworkPolicy.requestLimiter
        for _ in 0..<4 { try await limiter.acquire() }
        var heldPermits = 4
        defer {
            let count = heldPermits
            Task { for _ in 0..<count { await limiter.release() } }
        }
        let startsBefore = PermitProbeProtocol.starts.value
        let prepared = expectation(description: "Preparation returns while capacity is full")
        let start = Task {
            await manager.start(identifier: "permit-item", artifactTitle: "Queued recording", file: ArchiveFile(name: "queued.mp3", size: 3))
            prepared.fulfill()
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while manager.records.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let record = try XCTUnwrap(manager.records.first)
        // Reconciliation must not resume a suspended transfer that is waiting for capacity.
        let reconciled = expectation(description: "Availability refresh remains responsive")
        let refresh = Task { await manager.refreshAvailability(); reconciled.fulfill() }
        let removed = expectation(description: "Cancellation finishes while all four slots remain held")
        let removal = Task {
            switch mutation {
            case .remove: try await manager.remove(record)
            case .cancel: try await manager.cancel(record)
            case .removeAll: try await manager.removeAllDownloads()
            }
            removed.fulfill()
        }
        await fulfillment(of: [prepared, reconciled, removed], timeout: 1)
        XCTAssertEqual(PermitProbeProtocol.starts.value, startsBefore, "A queued or refreshed task must not resume before acquiring capacity")
        for _ in 0..<heldPermits { await limiter.release() }
        heldPermits = 0
        await start.value
        await refresh.value
        try await removal.value
        // Probe every slot: a cancellation racing permit acquisition must return it.
        let capacity = expectation(description: "All four permits remain available")
        let probe = Task {
            var acquired = 0
            do {
                for _ in 0..<4 { try await limiter.acquire(); acquired += 1 }
                capacity.fulfill()
            } catch {}
            for _ in 0..<acquired { await limiter.release() }
        }
        await fulfillment(of: [capacity], timeout: 1)
        probe.cancel()
        await probe.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(PermitProbeProtocol.starts.value, startsBefore, "Removed attempts must never resume after capacity becomes available")
        let persisted = try await store.downloads()
        if mutation == .cancel {
            XCTAssertEqual(manager.records.first?.state, .cancelled)
            XCTAssertEqual(persisted.first?.state, .cancelled)
        } else {
            XCTAssertTrue(manager.records.isEmpty)
            XCTAssertTrue(persisted.isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.localPath))
    }
}

private struct PermitFixtureRepository: ArchiveRepository {
    func search(_ request: SearchRequest) async throws -> SearchPage { throw URLError(.unsupportedURL) }
    func detail(identifier: String) async throws -> ArtifactDetail {
        ArtifactDetail(summary: ArtifactSummary(identifier: identifier, title: "Queued recording"), files: [ArchiveFile(name: "queued.mp3", size: 3)])
    }
}

private struct DeniedPermitFixtureRepository: ArchiveRepository {
    let restricted: Bool
    func search(_ request: SearchRequest) async throws -> SearchPage { throw URLError(.unsupportedURL) }
    func detail(identifier: String) async throws -> ArtifactDetail {
        ArtifactDetail(summary: ArtifactSummary(identifier: identifier, title: "Unavailable recording"),
            files: [ArchiveFile(name: "queued.mp3", size: 3, isPrivate: !restricted)], access: restricted ? .restricted : .available)
    }
}

/// Intentionally ignores cancellation to exercise stale completion identity guards.
private actor HeldPermitMetadataRepository: ArchiveRepository {
    private(set) var requested = false
    private var continuation: CheckedContinuation<ArtifactDetail, Never>?
    func search(_ request: SearchRequest) async throws -> SearchPage { throw URLError(.unsupportedURL) }
    func detail(identifier: String) async throws -> ArtifactDetail {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            requested = true
        }
    }
    func complete() {
        continuation?.resume(returning: ArtifactDetail(summary: ArtifactSummary(identifier: "permit-item", title: "Queued recording"), files: [ArchiveFile(name: "queued.mp3", size: 3)]))
        continuation = nil
    }
}

private final class PermitStartCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
private final class PermitProbeProtocol: URLProtocol, @unchecked Sendable {
    static let starts = PermitStartCounter()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.starts.increment()
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
    override func stopLoading() {}
}
