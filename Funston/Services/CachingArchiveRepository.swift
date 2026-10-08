import Foundation

enum CacheFreshness: Sendable, Equatable { case fresh, stale }

struct RepositoryUpdate<Value: Sendable>: Sendable {
    let value: Value
    let freshness: CacheFreshness
    let isRefreshing: Bool
    let refreshError: String?
}

actor CachingArchiveRepository: ArchiveRepository {
    private let store: SQLiteStore
    private let transport: any ArchiveTransport
    private let normalizer: ArchiveNormalizer
    private let encoder = JSONEncoder()

    init(store: SQLiteStore, transport: any ArchiveTransport = URLSessionArchiveTransport(), normalizer: ArchiveNormalizer = ArchiveNormalizer()) {
        self.store = store; self.transport = transport; self.normalizer = normalizer
    }

    nonisolated func searchUpdates(_ request: SearchRequest) -> AsyncThrowingStream<RepositoryUpdate<SearchPage>, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.produceSearch(request, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated func detailUpdates(identifier: String) -> AsyncThrowingStream<RepositoryUpdate<ArtifactDetail>, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.produceDetail(identifier, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func search(_ request: SearchRequest) async throws -> SearchPage {
        // Single-value clients get the first usable snapshot; screens consume updates.
        for try await update in searchUpdates(request) { return update.value }
        throw ArchiveError.invalidResponse
    }

    func detail(identifier: String) async throws -> ArtifactDetail {
        for try await update in detailUpdates(identifier: identifier) { return update.value }
        throw ArchiveError.invalidResponse
    }

    // Earlier search responses did not request the lending restriction field.
    nonisolated static func searchCacheKey(_ request: SearchRequest) -> String {
        "search:v2:\(request.cacheKey)"
    }

    private func produceSearch(_ request: SearchRequest, continuation: AsyncThrowingStream<RepositoryUpdate<SearchPage>, Error>.Continuation) async {
        var cachedValue: SearchPage?
        do {
            try Task.checkCancellation()
            let key = Self.searchCacheKey(request)
            let cached = try? await store.cacheEntry(key: key)
            if let cached, let value = try? await decodeSearch(cached, request: request) {
                cachedValue = value
                continuation.yield(RepositoryUpdate(value: value, freshness: cached.isFresh ? .fresh : .stale, isRefreshing: !cached.isFresh, refreshError: nil))
                if cached.isFresh { continuation.finish(); return }
            }
            try Task.checkCancellation()
            let data = try await fetch(ArchiveURLs.search(request))
            let page = try await normalizer.search(data: data, request: request)
            try Task.checkCancellation()
            try? await store.storeCache(key: key, kind: "search", response: data, snapshot: try? encoder.encode(page), maxAge: 900)
            continuation.yield(RepositoryUpdate(value: page, freshness: .fresh, isRefreshing: false, refreshError: nil))
            continuation.finish()
        } catch {
            finish(error: error, cached: cachedValue, continuation: continuation)
        }
    }

    private func produceDetail(_ identifier: String, continuation: AsyncThrowingStream<RepositoryUpdate<ArtifactDetail>, Error>.Continuation) async {
        var cachedValue: ArtifactDetail?
        do {
            try Task.checkCancellation()
            let key = "metadata:\(identifier)"
            let cached = try? await store.cacheEntry(key: key)
            if let cached, let value = try? await decodeDetail(cached, identifier: identifier) {
                cachedValue = value
                continuation.yield(RepositoryUpdate(value: value, freshness: cached.isFresh ? .fresh : .stale, isRefreshing: !cached.isFresh, refreshError: nil))
                if cached.isFresh { continuation.finish(); return }
            }
            try Task.checkCancellation()
            let data = try await fetch(ArchiveURLs.metadata(identifier: identifier))
            let detail = try await normalizer.detail(data: data, identifier: identifier)
            try Task.checkCancellation()
            try? await store.storeCache(key: key, kind: "metadata", response: data, snapshot: try? encoder.encode(detail), maxAge: 86_400)
            continuation.yield(RepositoryUpdate(value: detail, freshness: .fresh, isRefreshing: false, refreshError: nil))
            continuation.finish()
        } catch {
            finish(error: error, cached: cachedValue, continuation: continuation)
        }
    }

    private func finish<Value: Sendable>(error: any Error, cached: Value?, continuation: AsyncThrowingStream<RepositoryUpdate<Value>, Error>.Continuation) {
        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
            continuation.finish(throwing: CancellationError())
        } else if let cached {
            continuation.yield(RepositoryUpdate(value: cached, freshness: .stale, isRefreshing: false,
                                               refreshError: (error as? ArchiveError)?.userMessage ?? error.localizedDescription))
            continuation.finish()
        } else { continuation.finish(throwing: error) }
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await transport.send(request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            throw ArchiveError.http(status: response.statusCode, retryAfter: response.headers.first { $0.key.lowercased() == "retry-after" }?.value)
        }
        return response.data
    }

    private func decodeSearch(_ entry: StoredCacheEntry, request: SearchRequest) async throws -> SearchPage {
        return try await normalizer.search(data: entry.response, request: request)
    }
    private func decodeDetail(_ entry: StoredCacheEntry, identifier: String) async throws -> ArtifactDetail {
        return try await normalizer.detail(data: entry.response, identifier: identifier)
    }
}
