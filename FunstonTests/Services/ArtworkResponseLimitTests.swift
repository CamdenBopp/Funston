import XCTest
import Foundation
@testable import Funston

private final class BoundedArtworkProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "bounded-artwork.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let scenario = url.lastPathComponent
        var headers = ["Content-Type": "image/png"]
        if scenario == "declared-large" { headers["Content-Length"] = "1048576" }
        if scenario == "html" { headers["Content-Type"] = "text/html" }
        if scenario == "missing-type" { headers.removeValue(forKey: "Content-Type") }
        let status = scenario == "partial" ? 206 : scenario == "error" ? 503 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // CFNetwork can defer a URLProtocol's response callback until the first
        // body event (or EOF). Send a small prefix to release that delivery, then hold
        // the rest indefinitely. The delegate must still reject at headers,
        // without waiting for the remaining body or EOF. A separate direct
        // delegate test verifies rejection with no body callback at all.
        guard scenario == "chunks" || scenario == "exact" || scenario == "empty" else {
            client?.urlProtocol(self, didLoad: Data(repeating: 0, count: 512))
            return
        }
        if scenario == "chunks" {
            for _ in 0..<3 { client?.urlProtocol(self, didLoad: Data(repeating: 0x7f, count: 400)) }
            return // No EOF: cumulative body overflow itself must complete the request.
        }
        if scenario == "exact" {
            client?.urlProtocol(self, didLoad: Data(repeating: 0x7f, count: 512))
            client?.urlProtocol(self, didLoad: Data(repeating: 0x7f, count: 512))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ArtworkDispositionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var disposition: URLSession.ResponseDisposition?
    func record(_ value: URLSession.ResponseDisposition) { lock.withLock { disposition = value } }
    var cancelled: Bool { lock.withLock { disposition == .cancel } }
}

@MainActor
final class ArtworkResponseLimitTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedArtworkProtocol.self]
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 2
        return URLSession(configuration: configuration)
    }

    private func assertFailure(_ scenario: String, code: URLError.Code, file: StaticString = #filePath, line: UInt = #line) async {
        let session = session()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await ArtworkResponseLoader(maximumBytes: 1024).load(
                URL(string: "https://bounded-artwork.invalid/\(scenario)")!, session: session)
            XCTFail("Expected early rejection for \(scenario)", file: file, line: line)
        } catch {
            if scenario == "error" { XCTAssertEqual(error as? ArchiveError, .http(status: 503, retryAfter: nil), file: file, line: line) }
            else { XCTAssertEqual((error as? URLError)?.code, code, file: file, line: line) }
        }
    }

    func testOversizedContentLengthIsRejectedWithoutWaitingForBodyCompletion() async {
        await assertFailure("declared-large", code: .dataLengthExceedsMaximum)
    }

    func testUnknownLengthBodyIsBoundedAcrossChunksBeforeEOF() async {
        await assertFailure("chunks", code: .dataLengthExceedsMaximum)
    }

    func testStatusAndMIMEAreRejectedWithoutWaitingForBodyCompletion() async {
        await assertFailure("partial", code: .badServerResponse)
        await assertFailure("error", code: .badServerResponse)
        await assertFailure("html", code: .cannotDecodeContentData)
        await assertFailure("missing-type", code: .cannotDecodeContentData)
    }

    func testResponseDelegateRejectsHeadersBeforeAnyBodyCallback() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://bounded-artwork.invalid/unused")!
        let cases: [(Int, [String: String], URLError.Code)] = [
            (200, ["Content-Type": "image/png", "Content-Length": "1048576"], .dataLengthExceedsMaximum),
            (206, ["Content-Type": "image/png"], .badServerResponse),
            (503, ["Content-Type": "image/png"], .badServerResponse),
            (200, ["Content-Type": "text/html"], .cannotDecodeContentData),
            (200, [:], .cannotDecodeContentData)
        ]
        for (status, headers, code) in cases {
            let loader = ArtworkResponseLoader(maximumBytes: 1024)
            let task = session.dataTask(with: url) // Never resumed: no network/body delivery.
            defer { task.cancel() }
            let probe = ArtworkDispositionProbe()
            loader.urlSession(session, dataTask: task,
                didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!) {
                probe.record($0)
            }
            XCTAssertTrue(probe.cancelled, "Reject the response before allowing body delivery")
            do {
                _ = try await loader.load(url, session: session)
                XCTFail("Header rejection must complete the continuation")
            } catch {
                if status == 503 { XCTAssertEqual(error as? ArchiveError, .http(status: 503, retryAfter: nil)) }
                else { XCTAssertEqual((error as? URLError)?.code, code) }
            }
        }
    }

    func testExactByteLimitSucceedsAcrossChunks() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let data = try await ArtworkResponseLoader(maximumBytes: 1024).load(
            URL(string: "https://bounded-artwork.invalid/exact")!, session: session)
        XCTAssertEqual(data, Data(repeating: 0x7f, count: 1024))
    }

    func testEmptyImageBodyIsRejected() async {
        await assertFailure("empty", code: .cannotDecodeContentData)
    }

    func testCancellationBeforeContinuationInstallationCompletesOnce() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        let request = Task {
            try await ArtworkResponseLoader(maximumBytes: 1024).load(
                URL(string: "https://bounded-artwork.invalid/held")!, session: session)
        }
        request.cancel()
        do { _ = try await request.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
