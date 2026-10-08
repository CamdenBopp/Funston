import Foundation
import XCTest
@testable import Funston

private actor PolicyTransport: ArchiveTransport {
    var requests: [URLRequest] = []
    var responses: [ArchiveHTTPResponse]
    var timeouts: Int
    init(_ responses: [ArchiveHTTPResponse] = [], timeouts: Int = 0) { self.responses = responses; self.timeouts = timeouts }
    func send(_ request: URLRequest) throws -> ArchiveHTTPResponse {
        requests.append(request)
        if timeouts > 0 { timeouts -= 1; throw URLError(.timedOut) }
        return responses.count > 1 ? responses.removeFirst() : responses.first ?? ArchiveHTTPResponse(data: Data())
    }
}
private actor RetrySleeps {
    var values: [Double] = []
    func record(_ value: Double) { values.append(value) }
}

private actor ConcurrentPolicyTransport: ArchiveTransport {
    private var active = 0
    private(set) var peak = 0
    func send(_ request: URLRequest) async throws -> ArchiveHTTPResponse {
        active += 1; peak = max(peak, active)
        try await Task.sleep(for: .milliseconds(30))
        active -= 1
        return ArchiveHTTPResponse(data: Data())
    }
}

final class ArchiveNetworkPolicyTests: XCTestCase {
    @MainActor
    func testDeviceDownloadsUseIdentifiedBackgroundConfiguration() {
        let configuration = DownloadManager.backgroundConfiguration()
        XCTAssertEqual(configuration.identifier, "com.camden.Funston.background-downloads")
        XCTAssertTrue(configuration.sessionSendsLaunchEvents)
        XCTAssertFalse(configuration.isDiscretionary)
        XCTAssertTrue(configuration.waitsForConnectivity)
        XCTAssertEqual(configuration.httpMaximumConnectionsPerHost, 2)
        XCTAssertEqual(configuration.httpAdditionalHeaders?["User-Agent"] as? String, ArchiveNetworkPolicy.userAgent)
    }

    @MainActor
    func testLongDownloadsLeaveCapacityForMetadataAndQueuedRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(url: directory.appending(path: "test.sqlite"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuditHeldDownloadProtocol.self]
        let manager = DownloadManager(store: store, mediaDirectory: directory, sessionConfiguration: configuration,
                                      accessRepository: AuditDownloadRepository())
        await manager.waitUntilReady()
        let startsBefore = AuditHeldDownloadProtocol.starts.value
        for index in 0..<5 {
            await manager.start(identifier: "capacity-\(index)", artifactTitle: "Capacity", file: ArchiveFile(name: "held.mp3"))
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while AuditHeldDownloadProtocol.starts.value < startsBefore + 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(AuditHeldDownloadProtocol.starts.value - startsBefore, 2)
        XCTAssertEqual(manager.records.filter { $0.state == .queued }.count, 3)
        let metadata = expectation(description: "Metadata completes while long downloads remain in flight")
        let probe = Task {
            _ = try await ArchiveHTTPClient(transport: PolicyTransport()).send(ArchiveNetworkPolicy.request(ArchiveURLs.metadata(identifier: "capacity")))
            metadata.fulfill()
        }
        await fulfillment(of: [metadata], timeout: 1)
        let queued = try XCTUnwrap(manager.records.first { $0.state == .queued })
        try await manager.remove(queued)
        try await manager.removeAllDownloads()
        try await probe.value
        let slots = expectation(description: "Download slots are returned after bulk cancellation")
        let capacity = Task {
            var acquired = 0
            do {
                for _ in 0..<2 { try await ArchiveNetworkPolicy.downloadLimiter.acquire(); acquired += 1 }
                slots.fulfill()
            } catch {}
            for _ in 0..<acquired { await ArchiveNetworkPolicy.downloadLimiter.release() }
        }
        await fulfillment(of: [slots], timeout: 2)
        capacity.cancel(); await capacity.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(AuditHeldDownloadProtocol.starts.value - startsBefore, 2, "Cancelled queued attempts must never start")
        let persisted = try await store.downloads()
        XCTAssertTrue(persisted.isEmpty)
    }

    func testUserAgentIsPresentOnRequestsAndSessionConfiguration() async throws {
        let transport = PolicyTransport()
        _ = try await ArchiveHTTPClient(transport: transport).send(ArchiveNetworkPolicy.request(ArchiveURLs.metadata(identifier: "flatlandromanceo00abbouoft")))
        let request = await transport.requests.first
        XCTAssertEqual(request?.value(forHTTPHeaderField: "User-Agent"), ArchiveNetworkPolicy.userAgent)
        XCTAssertTrue(ArchiveNetworkPolicy.userAgent.hasPrefix("Funston/"))
        XCTAssertTrue(ArchiveNetworkPolicy.userAgent.contains("(iOS; +\(ArchiveNetworkPolicy.contact))"))
        XCTAssertEqual(ArchiveNetworkPolicy.configuration().httpAdditionalHeaders?["User-Agent"] as? String, ArchiveNetworkPolicy.userAgent)
    }

    func testExponentialBackoffWithJitterAndThreeAttempts() async throws {
        XCTAssertEqual(ArchiveRetryPolicy.delay(after: URLError(.timedOut), attempt: 1, jitter: 1), 1)
        XCTAssertEqual(ArchiveRetryPolicy.delay(after: URLError(.timedOut), attempt: 2, jitter: 1), 2)
        let transport = PolicyTransport(timeouts: 2), sleeps = RetrySleeps()
        _ = try await ArchiveHTTPClient(transport: transport, retrySleep: { await sleeps.record($0) }).send(ArchiveNetworkPolicy.request(ArchiveURLs.metadata(identifier: "test")))
        let delays = await sleeps.values
        XCTAssertEqual(delays.count, 2)
        XCTAssertTrue((0.75...1.25).contains(delays[0]))
        XCTAssertTrue((1.5...2.5).contains(delays[1]))
        let count = await transport.requests.count
        XCTAssertEqual(count, 3)
    }

    func testRetryAfterSecondsAndDateAreHonored() async throws {
        let transport = PolicyTransport([ArchiveHTTPResponse(data: Data(), statusCode: 503, headers: ["Retry-After": "7"]), ArchiveHTTPResponse(data: Data())])
        let sleeps = RetrySleeps()
        _ = try await ArchiveHTTPClient(transport: transport, retrySleep: { await sleeps.record($0) }).send(ArchiveNetworkPolicy.request(ArchiveURLs.metadata(identifier: "test")))
        let delays = await sleeps.values
        XCTAssertEqual(delays, [7])
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(ArchiveRetryPolicy.delay(after: ArchiveError.http(status: 429, retryAfter: "Thu, 01 Jan 1970 00:00:10 GMT"), attempt: 1, jitter: 1, now: now), 10)
    }

    func test404IsNeverRetriedAnd503StopsAfterThreeAttempts() async throws {
        for status in [404, 503] {
            let transport = PolicyTransport([ArchiveHTTPResponse(data: Data(), statusCode: status)])
            let sleeps = RetrySleeps()
            do {
                _ = try await ArchiveHTTPClient(transport: transport, retrySleep: { await sleeps.record($0) }).send(ArchiveNetworkPolicy.request(ArchiveURLs.metadata(identifier: "test")))
                XCTFail("Expected HTTP failure")
            } catch { XCTAssertEqual(error as? ArchiveError, .http(status: status, retryAfter: nil)) }
            let count = await transport.requests.count
            XCTAssertEqual(count, status == 404 ? 1 : 3)
        }
    }

    func testConcurrentArchiveRequestsAreLimitedToFour() async throws {
        let transport = ConcurrentPolicyTransport()
        let client = ArchiveHTTPClient(transport: transport)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask { _ = try await client.send(ArchiveNetworkPolicy.request(ArchiveURLs.metadata(identifier: String(index)))) }
            }
            try await group.waitForAll()
        }
        let peak = await transport.peak
        XCTAssertGreaterThan(peak, 0)
        XCTAssertLessThanOrEqual(peak, 4)
    }

    func testCachePolicyHonorsServerDirectivesAndCollectionDefault() {
        XCTAssertNil(ArchiveHTTPResponse(data: Data(), headers: ["Cache-Control": "no-store"]).cacheLifetime(defaultLifetime: 3600))
        XCTAssertNil(ArchiveHTTPResponse(data: Data(), headers: ["Cache-Control": "no-cache"]).cacheLifetime(defaultLifetime: 3600))
        XCTAssertEqual(ArchiveHTTPResponse(data: Data(), headers: ["Cache-Control": "public, max-age=7200"]).cacheLifetime(defaultLifetime: 3600), 7200)
        XCTAssertEqual(ArchiveHTTPResponse(data: Data(), headers: ["Cache-Control": "max-age=3600", "Age": "600"]).cacheLifetime(defaultLifetime: 3600), 3000)
        XCTAssertEqual(ArchiveHTTPResponse(data: Data(), headers: ["Expires": "Thu, 01 Jan 1970 00:00:10 GMT"]).cacheLifetime(defaultLifetime: 3600, now: Date(timeIntervalSince1970: 0)), 10)
        XCTAssertEqual(ArchiveHTTPResponse(data: Data()).cacheLifetime(defaultLifetime: 3600), 3600)
    }
}

private struct AuditDownloadRepository: ArchiveRepository {
    func search(_ request: SearchRequest) async throws -> SearchPage { throw URLError(.unsupportedURL) }
    func detail(identifier: String) async throws -> ArtifactDetail {
        ArtifactDetail(summary: ArtifactSummary(identifier: identifier, title: "Capacity"), files: [ArchiveFile(name: "held.mp3")])
    }
}
private final class AuditDownloadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
private final class AuditHeldDownloadProtocol: URLProtocol, @unchecked Sendable {
    static let starts = AuditDownloadCounter()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.starts.increment() }
    override func stopLoading() {}
}
