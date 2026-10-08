import Foundation
import ImageIO
import UIKit

final class SendableImage: @unchecked Sendable {
    let value: UIImage
    init(_ value: UIImage) { self.value = value }
}

/// Cancellation removes queued work; a permit is transferred directly to the next waiter.
actor ArtworkWorkLimiter {
    private var available: Int
    private var order: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    init(limit: Int) { available = max(1, limit) }

    func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 { available -= 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                order.append(id); waiters[id] = continuation
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func release() {
        while !order.isEmpty {
            let id = order.removeFirst()
            if let waiter = waiters.removeValue(forKey: id) { waiter.resume(); return }
        }
        available += 1
    }
    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        order.removeAll { $0 == id }
    }
}

actor ArtworkPipeline {
    static let shared = ArtworkPipeline()
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var consumers: [UUID: CheckedContinuation<SendableImage, Error>]
    }
    private let cache = NSCache<NSString, SendableImage>()
    private let session: URLSession
    private let maximumResponseBytes: Int
    private let fetchLimiter = ArtworkWorkLimiter(limit: 4)
    private let decodeLimiter = ArtworkWorkLimiter(limit: 2)
    private var inFlight: [String: Flight] = [:]

    init(session: URLSession? = nil, maximumResponseBytes: Int = 8 * 1_024 * 1_024) {
        self.maximumResponseBytes = max(1, min(maximumResponseBytes, 16 * 1_024 * 1_024))
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.default
            configuration.requestCachePolicy = .useProtocolCachePolicy
            configuration.urlCache = URLCache(memoryCapacity: 16 * 1_024 * 1_024, diskCapacity: 150 * 1_024 * 1_024)
            configuration.httpMaximumConnectionsPerHost = 4
            configuration.httpAdditionalHeaders = ["User-Agent": ArchiveNetworkPolicy.userAgent]
            self.session = URLSession(configuration: configuration)
        }
        cache.totalCostLimit = 48 * 1_024 * 1_024
        cache.countLimit = 240
    }

    func image(url: URL, pointSize: CGSize, scale: CGFloat) async throws -> SendableImage {
        try Task.checkCancellation()
        let requested = max(pointSize.width, pointSize.height) * scale
        let pixels = requested.isFinite ? min(4096, max(1, requested)) : 64
        let bucket = ((Int(pixels.rounded(.up)) + 63) / 64) * 64
        let key = "\(url.absoluteString)#\(bucket)"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        let consumer = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                subscribe(key: key, consumer: consumer, url: url, bucket: bucket, continuation: continuation)
            }
        } onCancel: { Task { await self.cancel(key: key, consumer: consumer) } }
    }

    private func subscribe(key: String, consumer: UUID, url: URL, bucket: Int, continuation: CheckedContinuation<SendableImage, Error>) {
        if inFlight[key] != nil { inFlight[key]?.consumers[consumer] = continuation; return }
        let flightID = UUID()
        let session = session, fetchLimiter = fetchLimiter, decodeLimiter = decodeLimiter
        let maximumResponseBytes = maximumResponseBytes
        let task = Task.detached(priority: .utility) { [weak self] in
            let result: Result<SendableImage, Error>
            do {
                try await fetchLimiter.acquire()
                let data: Data
                do {
                    try Task.checkCancellation()
                    data = try await ArchiveRetryPolicy.perform {
                        try await ArchiveNetworkPolicy.requestLimiter.acquire()
                        do {
                            let data = try await ArtworkResponseLoader(maximumBytes: maximumResponseBytes).load(url, session: session)
                            await ArchiveNetworkPolicy.requestLimiter.release()
                            return data
                        } catch { await ArchiveNetworkPolicy.requestLimiter.release(); throw error }
                    }
                    // Keep the fetch permit until decode has capacity. This bounds
                    // compressed responses waiting in memory as well as network work.
                    try await decodeLimiter.acquire()
                    await fetchLimiter.release()
                } catch { await fetchLimiter.release(); throw error }
                do {
                    try Task.checkCancellation()
                    guard let image = Self.downsample(data: data, maxPixelSize: bucket) else { throw URLError(.cannotDecodeContentData) }
                    try Task.checkCancellation()
                    result = .success(SendableImage(image))
                    await decodeLimiter.release()
                } catch { await decodeLimiter.release(); throw error }
            } catch { result = .failure(error) }
            await self?.complete(key: key, flightID: flightID, result: result)
        }
        inFlight[key] = Flight(id: flightID, task: task, consumers: [consumer: continuation])
    }

    private func cancel(key: String, consumer: UUID) {
        guard var flight = inFlight[key], let continuation = flight.consumers.removeValue(forKey: consumer) else { return }
        continuation.resume(throwing: CancellationError())
        if flight.consumers.isEmpty { inFlight[key] = nil; flight.task.cancel() }
        else { inFlight[key] = flight }
    }

    private func complete(key: String, flightID: UUID, result: Result<SendableImage, Error>) {
        guard let flight = inFlight[key], flight.id == flightID else { return }
        inFlight[key] = nil
        if case .success(let image) = result {
            let pixels = (image.value.cgImage?.width ?? 1) * (image.value.cgImage?.height ?? 1)
            cache.setObject(image, forKey: key as NSString, cost: pixels * 4)
        }
        for continuation in flight.consumers.values { continuation.resume(with: result) }
    }

    func removeAll() { cache.removeAllObjects() }

    private nonisolated static func downsample(data: Data, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceShouldCacheImmediately: true,
                                      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// One request, with all mutable state protected by the lock. Data arrives in
/// URLSession chunks, not per-byte async iteration. The existing session retains
/// its cache/protocol configuration and shared-connection behavior.
final class ArtworkResponseLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var task: URLSessionDataTask?
    private var outcome: Result<Data, Error>?
    private var acceptedResponse = false
    private var body = Data()

    init(maximumBytes: Int) { self.maximumBytes = max(1, maximumBytes) }

    func load(_ url: URL, session: URLSession) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let outcome {
                    lock.unlock(); continuation.resume(with: outcome); return
                }
                self.continuation = continuation
                let task = session.dataTask(with: ArchiveNetworkPolicy.request(url))
                task.delegate = self
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.finish(.failure(CancellationError()), cancel: true) }
    }

    private func finish(_ result: Result<Data, Error>, cancel: Bool) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let continuation = self.continuation; self.continuation = nil
        let task = self.task; self.task = nil
        body = Data()
        lock.unlock()
        if cancel { task?.cancel() }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let error: (any Error)?
        if let http = response as? HTTPURLResponse, http.statusCode == 200 {
            if response.expectedContentLength > Int64(maximumBytes) { error = URLError(.dataLengthExceedsMaximum) }
            else if response.mimeType?.lowercased().hasPrefix("image/") != true { error = URLError(.cannotDecodeContentData) }
            else { error = nil }
        } else if let http = response as? HTTPURLResponse {
            error = ArchiveError.http(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        } else { error = URLError(.badServerResponse) }
        if let error {
            finish(.failure(error), cancel: true)
            completionHandler(.cancel)
            return
        }
        lock.lock()
        let active = outcome == nil
        if active { acceptedResponse = true }
        lock.unlock()
        completionHandler(active ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        guard acceptedResponse, data.count <= maximumBytes - body.count else {
            lock.unlock()
            finish(.failure(URLError(.dataLengthExceedsMaximum)), cancel: true)
            return
        }
        body.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        let result: Result<Data, Error>
        if let error { result = .failure(error) }
        else if acceptedResponse, !body.isEmpty { result = .success(body) }
        else { result = .failure(URLError(.cannotDecodeContentData)) }
        lock.unlock()
        finish(result, cancel: false)
    }
}
