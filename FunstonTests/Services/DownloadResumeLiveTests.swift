import XCTest
@testable import Funston

/// Live check that Retry continues a real interrupted Internet Archive transfer
/// instead of starting over. The unit tests prove the bookkeeping; only a real
/// server proves archive.org honours the range request behind resume data.
@MainActor final class DownloadResumeLiveTests: XCTestCase {
    private let identifier = "the-ancient-magus-bride-s-01-e-03-720p-hd-blu-ray-multi-audio-esub"
    private let fileName = "The Ancient Magus' Bride S01E03 720p HD BluRay Multi Audio ESub.mkv"
    private let fileSize: Int64 = 169_641_007
    private let interruptAfter: Int64 = 4 * 1_024 * 1_024

    func testRetryContinuesFromTheInterruptedByte() async throws {
        guard ProcessInfo.processInfo.environment["IA_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set IA_NETWORK_TESTS=1 to run the live resume check")
        }
        let blob = try await interruptedResumeData()

        let media = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: media) }
        let key = DownloadManager.key(identifier: identifier, fileName: fileName)
        let failed = DownloadRecord(key: key, identifier: identifier, fileName: fileName, title: "Live resume", expectedBytes: fileSize,
                                    localPath: media.appending(path: "old").path, state: .failed, receivedBytes: interruptAfter,
                                    totalBytes: fileSize, errorMessage: "Interrupted", updatedAt: .now)
        let store = ResumeStore(record: failed, resumeData: blob)
        let manager = DownloadManager(store: store, mediaDirectory: media, sessionConfiguration: .ephemeral)
        await manager.waitUntilReady()
        await manager.retry(failed, file: ArchiveFile(name: fileName, size: fileSize))

        var firstProgress: Int64 = 0
        let deadline = ContinuousClock.now + .seconds(20)
        while firstProgress == 0, ContinuousClock.now < deadline {
            firstProgress = manager.records.first { $0.key == key }?.receivedBytes ?? 0
            if firstProgress == 0 { try await Task.sleep(for: .milliseconds(50)) }
        }
        if let current = manager.records.first(where: { $0.key == key }) { try? await manager.cancel(current) }
        XCTAssertGreaterThanOrEqual(firstProgress, interruptAfter,
                                    "The first progress after Retry should already include the bytes from before the interruption")
    }

    private func interruptedResumeData() async throws -> Data {
        let url = ArchiveURLs.download(identifier: identifier, fileName: fileName)
        let probe = ProgressProbe(threshold: interruptAfter)
        let session = URLSession(configuration: .ephemeral, delegate: probe, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: url)
        task.resume()
        try await probe.reachedThreshold()
        let data = await task.cancelByProducingResumeData()
        return try XCTUnwrap(data, "archive.org returned no resume data; it may not support ranged resumes for this file")
    }
}

private final class ProgressProbe: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let threshold: Int64
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var reached = false
    init(threshold: Int64) { self.threshold = threshold }

    func reachedThreshold() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); defer { lock.unlock() }
            if reached { continuation.resume() } else { self.continuation = continuation }
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        guard totalBytesWritten >= threshold else { return }
        lock.lock(); defer { lock.unlock() }
        guard !reached else { return }
        reached = true
        continuation?.resume(); continuation = nil
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock(); defer { lock.unlock() }
        guard !reached, let error else { return }
        continuation?.resume(throwing: error); continuation = nil
    }
}

private actor ResumeStore: DownloadPersistence {
    private var records: [DownloadRecord]
    private var resume: [String: Data]
    init(record: DownloadRecord, resumeData: Data) {
        records = [record]; resume = [record.key: resumeData]
    }
    func downloads() -> [DownloadRecord] { records }
    func upsertDownload(_ record: DownloadRecord) { records.removeAll { $0.key == record.key }; records.append(record) }
    func deleteDownload(key: String) { records.removeAll { $0.key == key }; resume[key] = nil }
    func downloadResumeData(key: String) -> Data? { resume[key] }
    func setDownloadResumeData(_ data: Data?, key: String) { resume[key] = data }
}
