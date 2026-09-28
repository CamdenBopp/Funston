import XCTest
@testable import ArchivePlayerCore

final class ByteSourceTests: XCTestCase {
    private final class RangeProtocol: URLProtocol {
        private static let bytes = Data(0..<64)
        override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "rangetest" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let header = request.value(forHTTPHeaderField: "Range"),
                  header.hasPrefix("bytes="),
                  let dash = header.firstIndex(of: "-"),
                  let start = Int(header[header.index(header.startIndex, offsetBy: 6)..<dash]),
                  let end = Int(header[header.index(after: dash)...]),
                  start >= 0, start < Self.bytes.count else {
                client?.urlProtocol(self, didFailWithError: DemuxError.invalidFormat("range"))
                return
            }
            let upper = min(end, Self.bytes.count - 1)
            let payload = Self.bytes.subdata(in: start..<(upper + 1))
            let response = HTTPURLResponse(url: request.url!, statusCode: 206,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Range": "bytes \(start)-\(upper)/64",
                                                          "ETag": "\"fixture\""])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private final class BadRangeProtocol: URLProtocol {
        final class Signal: @unchecked Sendable {
            private let lock = NSLock()
            private var action: (@Sendable () -> Void)?
            func set(_ action: (@Sendable () -> Void)?) { lock.withLock { self.action = action } }
            func fire() { let action = lock.withLock { self.action }; action?() }
        }
        static let stalled = Signal()
        override class func canInit(with request: URLRequest) -> Bool {
            ["ignorerange", "malformedrange", "hugebody", "oversizedbody", "badtotal", "changetag", "stallbody"].contains(request.url?.scheme ?? "")
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let scheme = request.url?.scheme
            if scheme == "hugebody" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "1099511627776", "Content-Type": "application/octet-stream", "X-Content-Type-Options": "nosniff"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                // URLProtocol forwards its pending response with the first body
                // fragment. The remaining 1-TiB body and EOF never arrive.
                client?.urlProtocol(self, didLoad: Data(repeating: 0, count: 4096))
                return
            }
            if scheme == "stallbody" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: ["Content-Range": "bytes 0-8191/8192", "Content-Type": "application/octet-stream"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(repeating: 0, count: 4096))
                Self.stalled.fire()
                return
            }
            if scheme == "oversizedbody" || scheme == "badtotal" || scheme == "changetag" {
                let secondRead = request.value(forHTTPHeaderField: "If-Range") != nil
                let range = scheme == "badtotal" ? "bytes 0-0/18446744073709551616" : "bytes 0-0/8192"
                let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: ["Content-Range": range, "ETag": secondRead ? "\"changed\"" : "\"first\""])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(repeating: 1, count: scheme == "oversizedbody" ? 8192 : 1))
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let malformed = request.url?.scheme == "malformedrange"
            let response = HTTPURLResponse(url: request.url!, statusCode: malformed ? 206 : 200,
                httpVersion: "HTTP/1.1",
                headerFields: malformed ? ["Content-Range": "bytes 0-18446744073709551615/*"] : nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data([0]))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func testLocalRangeBounds() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3, 4]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try LocalByteSource(url: url)
        let length = await source.length
        XCTAssertEqual(length, 4)
        let data = try await source.read(offset: 1, length: 2)
        XCTAssertEqual(data, Data([2, 3]))
        do {
            _ = try await source.read(offset: 3, length: 2)
            XCTFail("Expected truncation")
        } catch DemuxError.truncated {
        }
    }

    func testHTTPWindowReadsAreZeroBasedAndBounded() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RangeProtocol.self]
        let source = HTTPRangeByteSource(url: URL(string: "rangetest://fixture")!,
                                         session: URLSession(configuration: config),
                                         windowSize: 16)
        let total = try await source.length
        XCTAssertEqual(total, 64)
        let first = try await source.read(offset: 8, length: 4)
        XCTAssertEqual(first.startIndex, 0)
        XCTAssertEqual(first, Data([8, 9, 10, 11]))
        let second = try await source.read(offset: 10, length: 2)
        XCTAssertEqual(second.startIndex, 0)
        XCTAssertEqual(second[0], 10)
        let transferred = await source.transferredBytes
        XCTAssertLessThanOrEqual(transferred, 64)
    }

    func testRangeRejectionAndMalformedUInt64EndAreTypedErrors() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BadRangeProtocol.self]
        let session = URLSession(configuration: config)
        let ignored = HTTPRangeByteSource(url: URL(string: "ignorerange://fixture")!, session: session)
        do {
            _ = try await ignored.read(offset: 0, length: 1)
            XCTFail("Expected Range rejection")
        } catch DemuxError.unsupported {
        }
        let malformed = HTTPRangeByteSource(url: URL(string: "malformedrange://fixture")!, session: session)
        do {
            _ = try await malformed.read(offset: 0, length: 1)
            XCTFail("Expected Content-Range rejection")
        } catch DemuxError.invalidFormat {
        }
    }

    func testHugeNonRangeBodyRejectedAtHeadersWithoutWaitingForEOF() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BadRangeProtocol.self]
        config.timeoutIntervalForResource = 2
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let source = HTTPRangeByteSource(url: URL(string: "hugebody://fixture")!, session: session)
        do {
            _ = try await source.read(offset: 0, length: 1)
            XCTFail("Expected rejection before the advertised 1-TiB body")
        } catch DemuxError.unsupported { }
        let bytes = await source.transferredBytes
        XCTAssertEqual(bytes, 0)
    }

    func testOversized206BodyAndOverflowingTotalAreRejected() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BadRangeProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for scheme in ["oversizedbody", "badtotal"] {
            let source = HTTPRangeByteSource(url: URL(string: "\(scheme)://fixture")!, session: session)
            do {
                _ = try await source.read(offset: 0, length: 1)
                XCTFail("Expected bounded body/header rejection")
            } catch DemuxError.invalidFormat { }
        }
    }

    func testETagChangeIsRejectedWithoutUpdatingCache() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BadRangeProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let source = HTTPRangeByteSource(url: URL(string: "changetag://fixture")!, session: session)
        let length = try await source.length
        XCTAssertEqual(length, 8192)
        do {
            _ = try await source.read(offset: 0, length: 1)
            XCTFail("Expected validator change")
        } catch DemuxError.resourceChanged { }
    }

    func testCancelledStalledBodyCompletesWithoutPolling() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BadRangeProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let source = HTTPRangeByteSource(url: URL(string: "stallbody://fixture")!, session: session)
        let began = expectation(description: "Partial body started")
        BadRangeProtocol.stalled.set { began.fulfill() }
        defer { BadRangeProtocol.stalled.set(nil) }
        let read = Task { try await source.read(offset: 0, length: 1) }
        await fulfillment(of: [began], timeout: 2)
        read.cancel()
        do { _ = try await read.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }
}
