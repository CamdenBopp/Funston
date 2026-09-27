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
    private let fetchLimiter = ArtworkWorkLimiter(limit: 4)
    private let decodeLimiter = ArtworkWorkLimiter(limit: 2)
    private var inFlight: [String: Flight] = [:]

    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.default
            configuration.requestCachePolicy = .returnCacheDataElseLoad
            configuration.urlCache = URLCache(memoryCapacity: 16 * 1_024 * 1_024, diskCapacity: 150 * 1_024 * 1_024)
            configuration.httpMaximumConnectionsPerHost = 4
            configuration.httpAdditionalHeaders = ["User-Agent": "Archive-iOS/0.1"]
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
        let task = Task.detached(priority: .utility) { [weak self] in
            let result: Result<SendableImage, Error>
            do {
                try await fetchLimiter.acquire()
                let data: Data
                do {
                    try Task.checkCancellation()
                    let (received, response) = try await session.data(from: url)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
                    data = received
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
