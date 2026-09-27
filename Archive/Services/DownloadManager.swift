import Combine
import CryptoKit
import Foundation
import OSLog

struct DownloadTaskIdentity: Codable, Sendable, Equatable {
    let key: String
    let identifier: String
    let fileName: String
    let expectedBytes: Int64?
    let attemptID: UUID

    var taskDescription: String? { try? JSONEncoder().encode(self).base64EncodedString() }
    init(key: String, identifier: String, fileName: String, expectedBytes: Int64?, attemptID: UUID = UUID()) {
        self.key = key; self.identifier = identifier; self.fileName = fileName
        self.expectedBytes = expectedBytes; self.attemptID = attemptID
    }
    init?(taskDescription: String?) {
        guard let taskDescription, let data = Data(base64Encoded: taskDescription),
              let identity = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = identity
    }
    func destination(in directory: URL) -> URL {
        DownloadManager.localURL(key: key + "-" + attemptID.uuidString, fileName: fileName, directory: directory)
    }
    func matches(_ record: DownloadRecord, directory: URL) -> Bool {
        record.key == key && record.localPath == destination(in: directory).path
    }
}

struct TransferFailure: Error, Sendable { let message: String }

protocol DownloadPersistence: Sendable {
    func downloads() async throws -> [DownloadRecord]
    func upsertDownload(_ record: DownloadRecord) async throws
    func deleteDownload(key: String) async throws
}
extension SQLiteStore: DownloadPersistence {}

/// A serial delegate queue plus an explicit task chain preserves callback order
/// across actor hops, including the durable commit before background completion.
private final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.camden.Archive", category: "Downloads")
    nonisolated(unsafe) weak var owner: DownloadManager?
    let mediaDirectory: URL
    private var eventTail: Task<Void, Never>?
    private var lastProgress: [Int: ContinuousClock.Instant] = [:]
    init(mediaDirectory: URL) { self.mediaDirectory = mediaDirectory }

    private func append(_ operation: @escaping @MainActor @Sendable (DownloadManager) async -> Void) {
        let previous = eventTail
        let owner = owner
        eventTail = Task { await previous?.value; if let owner { await operation(owner) } }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = ContinuousClock.now
        if let previous = lastProgress[downloadTask.taskIdentifier], previous.duration(to: now) < .milliseconds(250) { return }
        lastProgress[downloadTask.taskIdentifier] = now
        guard let identity = DownloadTaskIdentity(taskDescription: downloadTask.taskDescription) else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        append { await $0.receivedProgress(identity: identity, received: totalBytesWritten, total: total) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let identity = DownloadTaskIdentity(taskDescription: downloadTask.taskDescription) else { return }
        let result: Result<URL, TransferFailure>
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw TransferFailure(message: "The Archive did not return the requested file.")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            let received = (attributes[.size] as? NSNumber)?.int64Value
            if let expected = identity.expectedBytes, received != expected {
                throw TransferFailure(message: "The downloaded file was incomplete.")
            }
            let destination = identity.destination(in: mediaDirectory)
            try FileManager.default.moveItem(at: location, to: destination)
            result = .success(destination)
        } catch { result = .failure(TransferFailure(message: (error as? TransferFailure)?.message ?? error.localizedDescription)) }
        lastProgress[downloadTask.taskIdentifier] = nil
        append { await $0.finished(identity: identity, result: result) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let identity = DownloadTaskIdentity(taskDescription: task.taskDescription) else { return }
        lastProgress[task.taskIdentifier] = nil
        guard let error else { return }
        let diagnostic = error as NSError
        Self.logger.error("Download failed: \(diagnostic.domain, privacy: .public) code \(diagnostic.code)")
        let message = DownloadFailurePresentation.message(for: error)
        append { await $0.failed(identity: identity, message: message) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        append { await $0.finishedBackgroundEvents() }
    }
}

enum DownloadFailurePresentation {
    static func message(for error: any Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .unknown, .backgroundSessionWasDisconnected:
                return "The download service could not complete this transfer. Try again."
            case .notConnectedToInternet:
                return "You’re offline. Reconnect to download this file."
            case .timedOut:
                return "The download timed out. Try again when your connection is stable."
            default: break
            }
        }
        return error.localizedDescription
    }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    @Published private(set) var records: [DownloadRecord] = []
    private let store: any DownloadPersistence
    private let mediaDirectory: URL
    private let delegate: DownloadSessionDelegate
    private let session: URLSession
    private var operationTail: Task<Void, Never>?
    private var backgroundCompletionHandler: (() -> Void)?
    private var backgroundEventsDrained = false
    private var pendingRemovals = Set<String>()
    private var leases: [String: Int] = [:]

    init(store: any DownloadPersistence, mediaDirectory: URL, sessionConfiguration: URLSessionConfiguration? = nil) {
        self.store = store; self.mediaDirectory = mediaDirectory
        let delegate = DownloadSessionDelegate(mediaDirectory: mediaDirectory)
        self.delegate = delegate
        let configuration: URLSessionConfiguration
        if let sessionConfiguration { configuration = sessionConfiguration }
        else {
            #if targetEnvironment(simulator)
            // Simulator nsurlsessiond can fail XPC setup before sending any bytes.
            // Keep real transfer/validation/persistence paths testable in-process.
            // Background continuation must be verified on a physical device.
            configuration = .default
            #else
            configuration = .background(withIdentifier: "com.camden.Archive.background-downloads")
            #endif
        }
        if configuration.identifier != nil { configuration.sessionSendsLaunchEvents = true }
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.httpAdditionalHeaders = ["User-Agent": "Archive-iOS/0.1"]
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "Archive download delegate"
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        super.init()
        delegate.owner = self
        operationTail = Task { [weak self] in await self?.loadAndReconcile() }
    }

    private func serialize(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = operationTail
        let task = Task { await previous?.value; await operation() }
        operationTail = task
        await task.value
    }
    private func serializeThrowing(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = operationTail
        let task = Task { await previous?.value; try await operation() }
        // A failed operation releases the queue, but its caller receives the error.
        operationTail = Task { _ = try? await task.value }
        try await task.value
    }
    func waitUntilReady() async { await operationTail?.value }

    func start(identifier: String, artifactTitle: String, file: ArchiveFile) async {
        await serialize { [self] in await startSerialized(identifier: identifier, artifactTitle: artifactTitle, file: file) }
    }
    private func startSerialized(identifier: String, artifactTitle: String, file: ArchiveFile) async {
        let key = Self.key(identifier: identifier, fileName: file.name)
        if records.contains(where: { $0.key == key && ([.queued, .downloading].contains($0.state) || ($0.state == .completed && FileManager.default.fileExists(atPath: $0.localPath))) }) { return }
        let identity = DownloadTaskIdentity(key: key, identifier: identifier, fileName: file.name, expectedBytes: file.size)
        var record = DownloadRecord(key: key, identifier: identifier, fileName: file.name, title: artifactTitle,
                                    expectedBytes: file.size, localPath: identity.destination(in: mediaDirectory).path,
                                    state: .queued, receivedBytes: 0, totalBytes: file.size, errorMessage: nil, updatedAt: .now)
        var task: URLSessionDownloadTask?
        do {
            try await store.upsertDownload(record)
            upsertInMemory(record)
            let created = session.downloadTask(with: ArchiveURLs.download(identifier: identifier, fileName: file.name))
            task = created
            created.taskDescription = identity.taskDescription
            record.state = .downloading
            try await store.upsertDownload(record)
            upsertInMemory(record)
            created.resume()
        } catch {
            task?.cancel()
            record.state = .failed; record.errorMessage = error.localizedDescription
            try? await store.upsertDownload(record)
            upsertInMemory(record)
        }
    }
    func retry(_ record: DownloadRecord, file: ArchiveFile) async {
        await start(identifier: record.identifier, artifactTitle: record.title, file: file)
    }
    func cancel(_ record: DownloadRecord) async throws {
        try await serializeThrowing { [self] in
            guard var current = records.first(where: { $0.key == record.key && $0.localPath == record.localPath }) else { return }
            current.state = .cancelled; current.errorMessage = nil; current.updatedAt = .now
            try await store.upsertDownload(current)
            upsertInMemory(current)
            for task in await session.allTasks {
                if DownloadTaskIdentity(taskDescription: task.taskDescription)?.matches(current, directory: mediaDirectory) == true { task.cancel() }
            }
        }
    }
    func remove(_ record: DownloadRecord, deferPhysicalRemoval: Bool = false) async throws {
        try await serializeThrowing { [self] in
            guard let current = records.first(where: { $0.key == record.key && $0.localPath == record.localPath }) else { return }
            try await store.deleteDownload(key: current.key)
            records.removeAll { $0.key == current.key }
            for task in await session.allTasks {
                if DownloadTaskIdentity(taskDescription: task.taskDescription)?.matches(current, directory: mediaDirectory) == true { task.cancel() }
            }
            retire(path: current.localPath)
        }
    }
    private func retire(path: String) {
        if leases[path, default: 0] > 0 { pendingRemovals.insert(path) }
        else { try? FileManager.default.removeItem(atPath: path) }
    }
    func acquireLocalURL(identifier: String, fileName: String) -> URL? {
        guard let url = completedLocalURL(identifier: identifier, fileName: fileName) else { return nil }
        leases[url.path, default: 0] += 1
        return url
    }
    func releaseLocalURL(_ url: URL) {
        guard let count = leases[url.path] else { return }
        if count > 1 { leases[url.path] = count - 1; return }
        leases[url.path] = nil
        if pendingRemovals.remove(url.path) != nil { try? FileManager.default.removeItem(at: url) }
    }
    // Compatibility entry point. Concrete URL leases now own deferred deletion.
    func releaseDeferredRemoval(identifier: String, fileName: String) {}
    func completedLocalURL(identifier: String, fileName: String) -> URL? {
        let key = Self.key(identifier: identifier, fileName: fileName)
        guard let record = records.first(where: { $0.key == key && $0.state == .completed }),
              FileManager.default.fileExists(atPath: record.localPath) else { return nil }
        return URL(filePath: record.localPath)
    }
    func completedRecord(identifier: String, fileName: String) async -> DownloadRecord? {
        await waitUntilReady()
        let key = Self.key(identifier: identifier, fileName: fileName)
        return records.first { $0.key == key && $0.state == .completed && FileManager.default.fileExists(atPath: $0.localPath) }
    }
    func setBackgroundCompletionHandler(_ completion: @escaping () -> Void) {
        if backgroundEventsDrained { backgroundEventsDrained = false; completion() }
        else { backgroundCompletionHandler = completion }
    }
    fileprivate func receivedProgress(identity: DownloadTaskIdentity, received: Int64, total: Int64?) async {
        await serialize { [self] in
            guard var record = records.first(where: { identity.matches($0, directory: mediaDirectory) }), record.state == .downloading else { return }
            record.receivedBytes = received; record.totalBytes = total ?? record.totalBytes; record.updatedAt = .now
            upsertInMemory(record)
        }
    }
    func finished(identity: DownloadTaskIdentity, result: Result<URL, TransferFailure>) async {
        await serialize { [self] in
            guard var record = records.first(where: { identity.matches($0, directory: mediaDirectory) }) else {
                if case .success(let url) = result { retire(path: url.path) }
                return
            }
            // Reconciliation may have already committed the moved file while this
            // delegate event was queued. Completion for that exact attempt is idempotent.
            if record.state == .completed { return }
            // The launch snapshot may precede both the move and its callback. Its
            // provisional failure must not discard a subsequently validated success.
            let recoversProvisionalFailure: Bool
            if case .success = result { recoversProvisionalFailure = record.state == .failed }
            else { recoversProvisionalFailure = false }
            guard [.queued, .downloading].contains(record.state) || recoversProvisionalFailure else {
                if case .success(let url) = result { retire(path: url.path) }
                return
            }
            switch result {
            case .success(let destination):
                record.state = .completed; record.localPath = destination.path
                record.receivedBytes = record.expectedBytes ?? record.receivedBytes; record.errorMessage = nil
            case .failure(let failure): record.state = .failed; record.errorMessage = failure.message
            }
            record.updatedAt = .now
            do { try await store.upsertDownload(record); upsertInMemory(record) }
            catch {
                // The moved file and queued durable record share the attempt path, so
                // launch reconciliation can recover a post-move/pre-commit interruption.
                record.state = .failed; record.errorMessage = "The transfer could not be saved. Try again."
                upsertInMemory(record)
            }
        }
    }
    fileprivate func failed(identity: DownloadTaskIdentity, message: String) async {
        await serialize { [self] in
            guard var record = records.first(where: { identity.matches($0, directory: mediaDirectory) }), [.queued, .downloading].contains(record.state) else { return }
            record.state = .failed; record.errorMessage = message; record.updatedAt = .now
            try? await store.upsertDownload(record)
            upsertInMemory(record)
        }
    }
    fileprivate func finishedBackgroundEvents() async {
        await serialize { [self] in
            if let completion = backgroundCompletionHandler { backgroundCompletionHandler = nil; completion() }
            else { backgroundEventsDrained = true }
        }
    }
    private func loadAndReconcile() async {
        guard let stored = try? await store.downloads() else { return }
        let tasks = await session.allTasks
        var reconciled: [DownloadRecord] = []
        for var record in stored {
            let active = tasks.filter { DownloadTaskIdentity(taskDescription: $0.taskDescription)?.matches(record, directory: mediaDirectory) == true }
            let attributes = try? FileManager.default.attributesOfItem(atPath: record.localPath)
            let bytes = (attributes?[.size] as? NSNumber)?.int64Value
            let validFile = bytes != nil && (record.expectedBytes == nil || bytes == record.expectedBytes)
            if [.completed, .queued, .downloading].contains(record.state), validFile {
                record.state = .completed; record.errorMessage = nil; active.forEach { $0.cancel() }
            } else if [.queued, .downloading].contains(record.state), !active.isEmpty {
                record.state = .downloading; active.dropFirst().forEach { $0.cancel() }; active.first?.resume()
            } else if [.queued, .downloading, .completed].contains(record.state) {
                record.state = record.state == .completed ? .missing : .failed
                record.errorMessage = "The download is unavailable on this device. Try again."
            } else { active.forEach { $0.cancel() } }
            try? await store.upsertDownload(record)
            reconciled.append(record)
        }
        let knownPaths = Set(reconciled.map(\.localPath))
        for task in tasks {
            if let identity = DownloadTaskIdentity(taskDescription: task.taskDescription),
               !reconciled.contains(where: { identity.matches($0, directory: mediaDirectory) }) { task.cancel() }
        }
        if let contents = try? FileManager.default.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: nil) {
            for url in contents where !knownPaths.contains(url.path) { try? FileManager.default.removeItem(at: url) }
        }
        records = reconciled.sorted { $0.updatedAt > $1.updatedAt }
    }
    private func upsertInMemory(_ record: DownloadRecord) {
        if let index = records.firstIndex(where: { $0.key == record.key }) { records[index] = record }
        else { records.insert(record, at: 0) }
    }
    nonisolated static func key(identifier: String, fileName: String) -> String {
        SHA256.hash(data: Data("\(identifier)\u{0}\(fileName)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
    nonisolated static func localURL(key: String, fileName: String, directory: URL) -> URL {
        let candidate = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        let safeExtension = candidate.range(of: "^[a-z0-9]{1,8}$", options: .regularExpression) != nil ? ".\(candidate)" : ""
        return directory.appending(path: key + safeExtension)
    }
}
