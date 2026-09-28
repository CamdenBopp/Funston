import XCTest
@testable import ArchivePlayerCore

final class ByteSourceIntegrationTests: XCTestCase {
    func testSmallValidProgramStreamEndsWithoutOverreadingLocalSource() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0, 0, 1, 0xB9]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = ProgramStreamDemuxer(source: try LocalByteSource(url: url))
        let packet = try await demuxer.nextPacket()
        XCTAssertNil(packet)
    }
}
