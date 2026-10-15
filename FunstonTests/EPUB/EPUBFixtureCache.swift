import Foundation
import XCTest

/// Public-domain books and W3C test publications downloaded by URL into a
/// cache outside the repository (Spec 2.2 rule 5, 21.2). Never committed.
enum EPUBFixtureCache {
    static let directoryOverride = "IA_EPUB_FIXTURE_DIR"
    static let directoryName = "FunstonEPUBFixtures"
    static let zipSignature: [UInt8] = [0x50, 0x4B, 0x03, 0x04]

    /// The cache root: `IA_EPUB_FIXTURE_DIR` when set, else the test process's Caches directory.
    static func directory(named group: String) throws -> URL {
        let root: URL
        if let supplied = ProcessInfo.processInfo.environment[directoryOverride], !supplied.isEmpty {
            root = URL(fileURLWithPath: supplied, isDirectory: true)
        } else {
            root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: directoryName, directoryHint: .isDirectory)
        }
        let directory = root.appending(path: group, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The local copy of a remote file, downloaded once. A response that is not
    /// a ZIP (an HTML interstitial, an error page) is refused and not kept.
    static func file(_ name: String, from url: URL, in directory: URL, session: URLSession, sniffZip: Bool = true) async throws -> URL {
        let destination = directory.appending(path: name)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let (temporary, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temporary)
            throw XCTSkip("Could not download \(url): \(response)")
        }
        let handle = try FileHandle(forReadingFrom: temporary)
        let head = try handle.read(upToCount: 4) ?? Data()
        try handle.close()
        guard !sniffZip || Array(head) == zipSignature else {
            try? FileManager.default.removeItem(at: temporary)
            throw XCTSkip("\(url) did not return a ZIP (first bytes \(Array(head)))")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    static func downloadSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }
}
