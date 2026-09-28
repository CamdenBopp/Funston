import Foundation

public actor LocalByteSource: ByteSource {
    private let handle: FileHandle
    public let length: UInt64?

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        length = try handle.seekToEnd()
    }

    public func read(offset: UInt64, length requestedLength: Int) async throws -> Data {
        guard requestedLength >= 0, requestedLength <= 8 * 1024 * 1024 else {
            throw DemuxError.outOfBounds
        }
        guard offset <= (length ?? 0), UInt64(requestedLength) <= (length ?? 0) - offset else {
            throw DemuxError.truncated
        }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: requestedLength) ?? Data()
        guard data.count == requestedLength else { throw DemuxError.truncated }
        return data
    }

    deinit { try? handle.close() }
}

/// One bounded read-ahead window. A Range server must honor the requested range; a 200
/// response is deliberately rejected so an uncooperative origin cannot download a whole VOB.
public actor HTTPRangeByteSource: ByteSource {
    private let url: URL
    private let session: URLSession
    private let windowSize: Int
    private var knownLength: UInt64?
    private var entityTag: String?
    private var windowOffset: UInt64 = 0
    private var window = Data()
    public private(set) var transferredBytes: UInt64 = 0
    public private(set) var requestCount: UInt64 = 0

    public init(url: URL, session: URLSession = .shared, windowSize: Int = 256 * 1024) {
        self.url = url
        self.session = session
        self.windowSize = max(4096, min(windowSize, 8 * 1024 * 1024))
    }

    public var length: UInt64? {
        get async throws {
            if knownLength == nil { _ = try await fetch(offset: 0, count: 1) }
            return knownLength
        }
    }

    public func read(offset: UInt64, length: Int) async throws -> Data {
        try Task.checkCancellation()
        guard length >= 0, length <= 8 * 1024 * 1024,
              UInt64(length) <= UInt64.max - offset else { throw DemuxError.outOfBounds }
        if length == 0 { return Data() }
        if let knownLength, offset >= knownLength || UInt64(length) > knownLength - offset {
            throw DemuxError.truncated
        }
        if offset >= windowOffset,
           offset - windowOffset <= UInt64(window.count),
           UInt64(length) <= UInt64(window.count) - (offset - windowOffset) {
            let start = Int(offset - windowOffset)
            // Data slices retain their original startIndex; all parsers use
            // zero-based byte offsets. Rebase explicitly at this boundary.
            return window.subdata(in: start..<(start + length))
        }
        let fetchLength = max(length, windowSize)
        let boundedLength: Int
        if let knownLength {
            boundedLength = Int(min(UInt64(fetchLength), knownLength - offset))
        } else {
            boundedLength = fetchLength
        }
        window = try await fetch(offset: offset, count: boundedLength)
        windowOffset = offset
        guard window.count >= length else { throw DemuxError.truncated }
        return window.subdata(in: 0..<length)
    }

    private func fetch(offset: UInt64, count: Int) async throws -> Data {
        guard count > 0, UInt64(count - 1) <= UInt64.max - offset else {
            throw DemuxError.outOfBounds
        }
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(offset + UInt64(count) - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let entityTag, !entityTag.hasPrefix("W/") { request.setValue(entityTag, forHTTPHeaderField: "If-Range") }
        // Per-task delegates keep the caller's session/connection pool and validate
        // headers before allowing chunks, without a Swift suspension per byte.
        let reader = BoundedRangeReader(offset: offset, count: count, knownLength: knownLength, entityTag: entityTag)
        let result = try await reader.load(request, session: session)
        try Task.checkCancellation()
        // Recheck against current actor state: another overlapping read may have
        // established validators while this request was suspended.
        if let previous = knownLength, let current = result.total, previous != current {
            throw DemuxError.resourceChanged
        }
        if let previous = knownLength, offset >= previous || UInt64(result.data.count) > previous - offset {
            throw DemuxError.resourceChanged
        }
        if let previous = entityTag, previous != result.entityTag { throw DemuxError.resourceChanged }
        knownLength = result.total ?? knownLength
        entityTag = result.entityTag ?? entityTag
        transferredBytes += UInt64(result.data.count)
        requestCount += 1
        return result.data
    }
}

private struct RangeReadResult: Sendable {
    let data: Data
    let total: UInt64?
    let entityTag: String?
}

/// URLSession owns callback scheduling; all shared state is guarded because task
/// cancellation can arrive from a Swift executor independently of delegate callbacks.
private final class BoundedRangeReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let offset: UInt64
    private let limit: Int
    private let knownLength: UInt64?
    private let entityTag: String?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RangeReadResult, any Error>?
    private var task: URLSessionDataTask?
    private var outcome: Result<RangeReadResult, any Error>?
    private var body = Data()
    private var expectedCount: Int?
    private var total: UInt64?
    private var responseTag: String?

    init(offset: UInt64, count: Int, knownLength: UInt64?, entityTag: String?) {
        self.offset = offset; limit = count; self.knownLength = knownLength; self.entityTag = entityTag
    }

    func load(_ request: URLRequest, session: URLSession) async throws -> RangeReadResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let outcome {
                    lock.unlock(); continuation.resume(with: outcome); return
                }
                self.continuation = continuation
                let task = session.dataTask(with: request)
                task.delegate = self
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.finish(.failure(CancellationError()), cancel: true)
        }
    }

    private func finish(_ result: Result<RangeReadResult, any Error>, cancel: Bool) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let continuation = self.continuation; self.continuation = nil
        let task = self.task; self.task = nil
        lock.unlock()
        if cancel { task?.cancel() }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let response = response as? HTTPURLResponse else { throw DemuxError.unsupported("Origin did not honor HTTP Range") }
            if entityTag != nil, response.statusCode == 200 { throw DemuxError.resourceChanged }
            guard response.statusCode == 206 else { throw DemuxError.unsupported("Origin did not honor HTTP Range") }
            guard let value = response.value(forHTTPHeaderField: "Content-Range"),
                  let range = Self.parseContentRange(value), range.start == offset,
                  range.end - range.start < UInt64(limit) else { throw DemuxError.invalidFormat("Invalid Content-Range") }
            if let knownLength, let total = range.total, knownLength != total { throw DemuxError.resourceChanged }
            if let knownLength, range.end >= knownLength { throw DemuxError.resourceChanged }
            let tag = response.value(forHTTPHeaderField: "ETag")
            if let entityTag, entityTag != tag { throw DemuxError.resourceChanged }
            if let encoding = response.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" {
                throw DemuxError.unsupported("Encoded HTTP Range body")
            }
            let expected = Int(range.end - range.start + 1) // Difference is bounded by limit.
            if let value = response.value(forHTTPHeaderField: "Content-Length"),
               Self.decimal(value[...]) != UInt64(expected) { throw DemuxError.invalidFormat("Content-Length does not match range") }
            lock.lock()
            guard outcome == nil else { lock.unlock(); completionHandler(.cancel); return }
            expectedCount = expected; total = range.total; responseTag = tag
            body.reserveCapacity(expected)
            lock.unlock()
            completionHandler(.allow)
        } catch {
            // Reject at headers, before URLSession is allowed to deliver a body.
            finish(.failure(error), cancel: true)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        guard let expectedCount, data.count <= expectedCount - body.count else {
            lock.unlock()
            finish(.failure(DemuxError.invalidFormat("HTTP Range body exceeds declared size")), cancel: true)
            return
        }
        body.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        let result: Result<RangeReadResult, any Error>
        if let error { result = .failure(error) }
        else if let expectedCount, body.count == expectedCount { result = .success(RangeReadResult(data: body, total: total, entityTag: responseTag)) }
        else { result = .failure(DemuxError.truncated) }
        lock.unlock()
        finish(result, cancel: false)
    }

    private static func decimal(_ value: Substring) -> UInt64? {
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return UInt64(value)
    }
    private static func parseContentRange(_ value: String) -> (start: UInt64, end: UInt64, total: UInt64?)? {
        guard value.hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let positions = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard positions.count == 2,
              let start = decimal(positions[0]), let end = decimal(positions[1]), end >= start else { return nil }
        let total: UInt64?
        if parts[1] == "*" { total = nil }
        else {
            guard let parsed = decimal(parts[1]), parsed > end else { return nil }; total = parsed
        }
        return (start, end, total)
    }
}
