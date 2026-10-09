import Foundation
import AVFoundation

/// Edit this one constant to change the contact sent to the Archive.
enum ArchiveNetworkPolicy {
    static let contact = "https://github.com/CamdenBopp/Funston/issues"
    static let userAgent = "Funston/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0") (iOS; +\(contact))"
    static let requestLimiter = ArtworkWorkLimiter(limit: 4)
    // Long transfers use at most two slots, leaving room for metadata and artwork.
    static let downloadLimiter = ArtworkWorkLimiter(limit: 2)
    static let cache = URLCache(memoryCapacity: 32 * 1_024 * 1_024, diskCapacity: 200 * 1_024 * 1_024)
    static let session = URLSession(configuration: configuration())

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = cache
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        return configuration
    }

    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    static func asset(_ url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [AVURLAssetHTTPUserAgentKey: userAgent])
    }
}

enum ArchiveRetryPolicy {
    static let maximumAttempts = 3
    // Archive media redirects sometimes reach a server returning a transient 5xx.
    static func isRetryableHTTPStatus(_ status: Int) -> Bool {
        [429, 500, 502, 503, 504].contains(status)
    }
    static func delay(after error: any Error, attempt: Int, jitter: Double = Double.random(in: 0.75...1.25), now: Date = .now) -> Double? {
        let retryAfter: String?
        if let error = error as? ArchiveError, case .http(let status, let header) = error,
           isRetryableHTTPStatus(status) { retryAfter = header }
        else if (error as? URLError)?.code == .timedOut { retryAfter = nil }
        else { return nil }
        let backoff = pow(2, Double(attempt - 1)) * jitter
        guard let retryAfter else { return backoff }
        if let seconds = Double(retryAfter.trimmingCharacters(in: .whitespaces)), seconds.isFinite {
            return max(backoff, max(0, seconds))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return max(backoff, formatter.date(from: retryAfter)?.timeIntervalSince(now) ?? 0)
    }

    static func sleep(_ seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }

    static func perform<Value: Sendable>(sleep: @Sendable (Double) async throws -> Void = Self.sleep,
                                        operation: @Sendable () async throws -> Value) async throws -> Value {
        for attempt in 1...maximumAttempts {
            try Task.checkCancellation()
            do { return try await operation() }
            catch {
                guard attempt < maximumAttempts, let delay = delay(after: error, attempt: attempt) else { throw error }
                try await sleep(delay)
            }
        }
        throw ArchiveError.invalidResponse
    }
}

struct ArchiveHTTPClient: Sendable {
    let transport: any ArchiveTransport
    var retrySleep: @Sendable (Double) async throws -> Void = ArchiveRetryPolicy.sleep

    func send(_ request: URLRequest) async throws -> ArchiveHTTPResponse {
        var identified = request
        identified.setValue(ArchiveNetworkPolicy.userAgent, forHTTPHeaderField: "User-Agent")
        let prepared = identified
        return try await ArchiveRetryPolicy.perform(sleep: retrySleep) {
            try await ArchiveNetworkPolicy.requestLimiter.acquire()
            let response: ArchiveHTTPResponse
            do {
                try Task.checkCancellation()
                response = try await transport.send(prepared)
            } catch {
                await ArchiveNetworkPolicy.requestLimiter.release()
                throw error
            }
            await ArchiveNetworkPolicy.requestLimiter.release()
            guard (200..<300).contains(response.statusCode) else {
                throw ArchiveError.http(status: response.statusCode, retryAfter: response.headers.first { $0.key.lowercased() == "retry-after" }?.value)
            }
            return response
        }
    }
}

extension ArchiveHTTPResponse {
    func cacheLifetime(defaultLifetime: Double, now: Date = .now) -> Double? {
        let control = headers.first { $0.key.lowercased() == "cache-control" }?.value.lowercased() ?? ""
        let directives = control.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if directives.contains("no-store") { return nil }
        if directives.contains(where: { $0.hasPrefix("no-cache") }) { return nil }
        let age = max(0, Double(headers.first { $0.key.lowercased() == "age" }?.value ?? "0") ?? 0)
        for directive in directives where directive.hasPrefix("max-age=") {
            if let seconds = Double(directive.dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: "\""))), seconds.isFinite { return max(0, seconds - age) }
        }
        if let expires = headers.first(where: { $0.key.lowercased() == "expires" })?.value {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: expires) { return max(0, date.timeIntervalSince(now)) }
        }
        return defaultLifetime
    }
}
