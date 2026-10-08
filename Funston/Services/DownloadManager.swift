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
    func downloadResumeData(key: String) async throws -> Data?
    func setDownloadResumeData(_ data: Data?, key: String) async throws
}
extension SQLiteStore: DownloadPersistence {}

/// A serial delegate queue plus an explicit task chain preserves callback order
/// across actor hops, including the durable commit before background completion.
private final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.camden.Funston", category: "Downloads")
    nonisolated(unsafe) weak var owner: DownloadManager?
    let mediaDirectory: URL
    private var eventTail: Task<Void, Never>?
    private var lastProgress: [Int: ContinuousClock.Instant] = [:]
    private let permitLock = NSLock()
    private var requestPermits = Set<Int>()
    func holdRequestPermit(_ taskID: Int) {
        permitLock.lock(); requestPermits.insert(taskID); permitLock.unlock()
    }
    private func releaseRequestPermit(_ taskID: Int) {
        permitLock.lock(); let held = requestPermits.remove(taskID) != nil; permitLock.unlock()
        if held { Task { await ArchiveNetworkPolicy.requestLimiter.release() } }
    }
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
        if let response = downloadTask.response as? HTTPURLResponse,
           response.statusCode == 429 || response.statusCode == 503 {
            let error = ArchiveError.http(status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
            append { await $0.transientFailure(identity: identity, error: error, resumeData: nil) }
            return
        }
        let result: Result<URL, TransferFailure>
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw TransferFailure(message: "Internet Archive did not return this file.")
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
        let taskID = task.taskIdentifier
        releaseRequestPermit(taskID)
        guard let identity = DownloadTaskIdentity(taskDescription: task.taskDescription) else { return }
        lastProgress[taskID] = nil
        guard let error else { return }
        let diagnostic = error as NSError
        Self.logger.error("Download failed: \(diagnostic.domain, privacy: .public) code \(diagnostic.code)")
        let message = DownloadFailurePresentation.message(for: error)
        let resumeData = DownloadManager.resumeData(from: error)
        if (error as? URLError)?.code == .timedOut {
            append { await $0.transientFailure(identity: identity, error: URLError(.timedOut), resumeData: resumeData) }
        } else { append { await $0.failed(identity: identity, message: message, resumeData: resumeData) } }
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
    /// Set when the saved download list can't be read. Without it the Downloads
    /// tab would look empty, as if every download had been removed.
    @Published private(set) var loadError: String?
    private static let logger = Logger(subsystem: "com.camden.Funston", category: "Downloads")
    private let store: any DownloadPersistence
    private let mediaDirectory: URL
    private let delegate: DownloadSessionDelegate
    private let session: URLSession
    private var networkAttempts: [String: Int] = [:]
    private let accessRepository: any ArchiveRepository
    private var operationTail: Task<Void, Never>?
    private var backgroundCompletionHandler: (() -> Void)?
    private var backgroundEventsDrained = false
    private var pendingRemovals = Set<String>()
    private var leases: [String: Int] = [:]

    init(store: any DownloadPersistence, mediaDirectory: URL, sessionConfiguration: URLSessionConfiguration? = nil, accessRepository: any ArchiveRepository = NetworkArchiveRepository()) {
        self.store = store; self.mediaDirectory = mediaDirectory
        self.accessRepository = accessRepository
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
            configuration = .background(withIdentifier: "com.camden.Funston.background-downloads")
            #endif
        }
        if configuration.identifier != nil { configuration.sessionSendsLaunchEvents = true }
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.httpAdditionalHeaders = ["User-Agent": ArchiveNetworkPolicy.userAgent]
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "Funston download delegate"
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
    private func startSerialized(identifier: String, artifactTitle: String, file: ArchiveFile, attempt: Int = 1) async {
        let key = Self.key(identifier: identifier, fileName: file.name)
        if records.contains(where: { $0.key == key && ([.queued, .downloading].contains($0.state) || ($0.state == .completed && FileManager.default.fileExists(atPath: $0.localPath))) }) { return }
        networkAttempts[key] = attempt
        let identity = DownloadTaskIdentity(key: key, identifier: identifier, fileName: file.name, expectedBytes: file.size)
        var record = DownloadRecord(key: key, identifier: identifier, fileName: file.name, title: artifactTitle,
                                    expectedBytes: file.size, localPath: identity.destination(in: mediaDirectory).path,
                                    state: .queued, receivedBytes: 0, totalBytes: file.size, errorMessage: nil, updatedAt: .now)
        var task: URLSessionDownloadTask?
        do {
            let detail = try await accessRepository.detail(identifier: identifier)
            guard detail.access == .available, !detail.summary.isAccessRestricted,
                  detail.files.contains(where: { $0.name == file.name && !$0.isPrivate }) else { throw ArchiveError.missingItem }
            // Retry continues from the bytes a failed attempt left behind. The blob is
            // used once: if it's stale, that attempt fails and a fresh one starts next time.
            let resumeData = await consumeResumeData(key: key)
            try await store.upsertDownload(record)
            upsertInMemory(record)
            let created = resumeData.map { session.downloadTask(withResumeData: $0) }
                ?? session.downloadTask(with: ArchiveNetworkPolicy.request(ArchiveURLs.download(identifier: identifier, fileName: file.name)))
            task = created
            created.taskDescription = identity.taskDescription
            record.state = .downloading
            try await store.upsertDownload(record)
            upsertInMemory(record)
            try await ArchiveNetworkPolicy.requestLimiter.acquire()
            delegate.holdRequestPermit(created.taskIdentifier)
            created.resume()
        } catch {
            task?.cancel()
            record.state = .failed; record.errorMessage = error.localizedDescription
            await persistRecoverably(record)
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
    fileprivate func failed(identity: DownloadTaskIdentity, message: String, resumeData: Data?) async {
        await serialize { [self] in
            guard var record = records.first(where: { identity.matches($0, directory: mediaDirectory) }), [.queued, .downloading].contains(record.state) else { return }
            record.state = .failed; record.errorMessage = message; record.updatedAt = .now
            await persistRecoverably(record)
            if let resumeData {
                do { try await store.setDownloadResumeData(resumeData, key: record.key) }
                catch { Self.logger.error("Resume data not saved: \(error.localizedDescription, privacy: .public)") }
            }
            upsertInMemory(record)
        }
    }
    fileprivate func transientFailure(identity: DownloadTaskIdentity, error: any Error, resumeData: Data?) async {
        let attempt = networkAttempts[identity.key] ?? 1
        await failed(identity: identity, message: archiveMessage(error), resumeData: resumeData)
        guard attempt < ArchiveRetryPolicy.maximumAttempts,
              let delay = ArchiveRetryPolicy.delay(after: error, attempt: attempt) else { return }
        Task { [weak self] in
            try? await ArchiveRetryPolicy.sleep(delay)
            guard let self else { return }
            await serialize { [self] in
                guard let record = records.first(where: { identity.matches($0, directory: mediaDirectory) }), record.state == .failed else { return }
                await startSerialized(identifier: record.identifier, artifactTitle: record.title,
                                      file: ArchiveFile(name: record.fileName, size: record.expectedBytes), attempt: attempt + 1)
            }
        }
    }

    fileprivate func finishedBackgroundEvents() async {
        await serialize { [self] in
            if let completion = backgroundCompletionHandler { backgroundCompletionHandler = nil; completion() }
            else { backgroundEventsDrained = true }
        }
    }
    private func consumeResumeData(key: String) async -> Data? {
        do {
            guard let data = try await store.downloadResumeData(key: key) else { return nil }
            try await store.setDownloadResumeData(nil, key: key)
            return data
        } catch {
            Self.logger.error("Resume data unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    func reloadAfterFailure() async {
        await serialize { [self] in await loadAndReconcile() }
    }
    /// For writes whose loss launch reconciliation repairs: a failed or reconciled
    /// state that isn't saved is re-derived from the file system on next launch.
    /// The failure is still logged rather than dropped.
    private func persistRecoverably(_ record: DownloadRecord) async {
        do { try await store.upsertDownload(record) }
        catch {
            Self.logger.error("Download record not saved (state \(record.state.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }
    private func loadAndReconcile() async {
        let stored: [DownloadRecord]
        do {
            stored = try await store.downloads()
            loadError = nil
        } catch {
            Self.logger.error("Download list not loaded: \(error.localizedDescription, privacy: .public)")
            // Leave files and tasks untouched: an unreadable list is not evidence
            // that anything on disk is orphaned.
            loadError = error.localizedDescription
            return
        }
        let tasks = await session.allTasks
        var reconciled: [DownloadRecord] = []
        for var record in stored {
            // App container roots can change across reinstalls/restores/updates.
            // Persisted absolute paths are not durable identities: recover only
            // the exact managed filename for this record in today's Media folder.
            let relocated = relocatedManagedURL(for: record)
            if let relocated {
                record.localPath = relocated.path
            }
            let active = tasks.filter { DownloadTaskIdentity(taskDescription: $0.taskDescription)?.matches(record, directory: mediaDirectory) == true }
            let safePath = record.localPath.hasPrefix("/")
                && !record.localPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
            let attributes = safePath ? regularMediaFileAttributes(URL(fileURLWithPath: record.localPath)) : nil
            let bytes = (attributes?[.size] as? NSNumber)?.int64Value
            let validFile = bytes != nil && (record.expectedBytes == nil || bytes == record.expectedBytes)
            if ([.completed, .queued, .downloading].contains(record.state)
                || (record.state == .missing && relocated != nil)), validFile {
                record.state = .completed; record.errorMessage = nil; active.forEach { $0.cancel() }
            } else if [.queued, .downloading].contains(record.state), !active.isEmpty {
                record.state = .downloading; active.dropFirst().forEach { $0.cancel() }; active.first?.resume()
            } else if [.queued, .downloading, .completed].contains(record.state) {
                record.state = record.state == .completed ? .missing : .failed
                record.errorMessage = "The download is unavailable on this device. Try again."
            } else { active.forEach { $0.cancel() } }
            await persistRecoverably(record)
            reconciled.append(record)
        }
        let knownPaths = Set(reconciled.map(\.localPath))
        // An invalid or unrecognized record is not permission to delete a file
        // with the same basename. Leave ambiguous data for explicit user action.
        let referencedNames = Set(stored.map { URL(fileURLWithPath: $0.localPath).lastPathComponent })
        for task in tasks {
            if let identity = DownloadTaskIdentity(taskDescription: task.taskDescription),
               !reconciled.contains(where: { identity.matches($0, directory: mediaDirectory) }) { task.cancel() }
        }
        if let contents = try? FileManager.default.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: nil) {
            for url in contents where !knownPaths.contains(url.path)
                && !referencedNames.contains(url.lastPathComponent)
                && Self.isManagedFileName(url.lastPathComponent)
                && regularMediaFileAttributes(url) != nil {
                try? FileManager.default.removeItem(at: url)
            }
        }
        records = reconciled.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func regularMediaFileAttributes(_ url: URL) -> [FileAttributeKey: Any]? {
        guard url.deletingLastPathComponent().standardizedFileURL == mediaDirectory.standardizedFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return attributes
    }

    private func relocatedManagedURL(for record: DownloadRecord) -> URL? {
        guard record.localPath.hasPrefix("/"),
              !record.localPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              record.key == Self.key(identifier: record.identifier, fileName: record.fileName) else { return nil }
        let previous = URL(fileURLWithPath: record.localPath)
        guard previous.deletingLastPathComponent().lastPathComponent == mediaDirectory.lastPathComponent else { return nil }
        let name = previous.lastPathComponent
        guard Self.isManagedFileName(name) else { return nil }
        let legacyName = Self.localURL(key: record.key, fileName: record.fileName, directory: mediaDirectory).lastPathComponent
        let suffix = String(legacyName.dropFirst(record.key.count))
        let stem = suffix.isEmpty ? name : String(name.dropLast(suffix.count))
        guard name.hasSuffix(suffix),
              stem == record.key || (stem.hasPrefix(record.key + "-")
                && UUID(uuidString: String(stem.dropFirst(record.key.count + 1))) != nil) else { return nil }
        let candidate = mediaDirectory.appendingPathComponent(name)
        guard candidate.path != record.localPath,
              let attributes = regularMediaFileAttributes(candidate),
              let bytes = (attributes[.size] as? NSNumber)?.int64Value,
              record.expectedBytes == nil || bytes == record.expectedBytes else { return nil }
        return candidate
    }

    nonisolated private static func isManagedFileName(_ name: String) -> Bool {
        name.range(of: "^[a-f0-9]{64}(?:-[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12})?(?:\\.[a-z0-9]{1,8})?$",
                   options: .regularExpression) != nil
    }
    private func upsertInMemory(_ record: DownloadRecord) {
        if let index = records.firstIndex(where: { $0.key == record.key }) { records[index] = record }
        else { records.insert(record, at: 0) }
    }
    /// A download that fails partway (lost connection, timeout) usually carries the
    /// state URLSession needs to continue it. Explicit cancels don't produce it.
    nonisolated static func resumeData(from error: any Error) -> Data? {
        (error as? URLError)?.downloadTaskResumeData
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
