import XCTest
import CoreMedia
@testable import ArchivePlayerCore

private struct MatroskaMemorySource: ByteSource {
    let bytes: Data
    var length: UInt64? { get async throws { UInt64(bytes.count) } }
    func read(offset: UInt64, length: Int) async throws -> Data {
        guard offset < bytes.count else { return Data() }
        return bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + min(length, 3)))
    }
}

final class MatroskaTests: XCTestCase {
    func testInternetArchiveMultiAudioRangeFixture() async throws {
        guard ProcessInfo.processInfo.environment["IA_NETWORK_TESTS"] == "1" else { throw XCTSkip("Set IA_NETWORK_TESTS=1 to validate live IA Range fixture") }
        let base = URL(string: "https://archive.org/download/the-ancient-magus-bride-s-01-e-03-720p-hd-blu-ray-multi-audio-esub/")!
        let url = base.appendingPathComponent("The Ancient Magus' Bride S01E03 720p HD BluRay Multi Audio ESub.mkv")
        let source = HTTPRangeByteSource(url: url, windowSize: 4096)
        let demux = MatroskaDemuxer(source: source)
        let tracks = try await demux.tracks()
        let audio = tracks.filter { $0.kind == .audio }
        let videoPrivate = try XCTUnwrap(tracks.first(where: { $0.kind == .video })?.codecPrivate)
        let aacPrivate = try XCTUnwrap(audio.first?.codecPrivate)
        let videoFormat = try FormatDescriptionFactory.h264(avcC: videoPrivate)
        let audioFormat = try FormatDescriptionFactory.aac(audioSpecificConfig: aacPrivate)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(videoFormat), kCMVideoCodecType_H264)
        XCTAssertEqual(CMFormatDescriptionGetMediaType(audioFormat), kCMMediaType_Audio)
        XCTAssertEqual(audio.map(\.language), ["hin", "eng", "jpn"])
        XCTAssertEqual(audio.map(\.codec), ["A_AAC", "A_OPUS", "A_OPUS"])
        XCTAssertEqual(tracks.filter { $0.kind == .subtitle }.map(\.codec), ["S_HDMV/PGS", "S_HDMV/PGS"])
        let transferred = await source.transferredBytes
        XCTAssertLessThan(transferred, 128 * 1024)
        print("IA Matroska tracks=\(tracks.count), metadata bytes=\(transferred)")
        for _ in 0..<32 {
            let packet = try await demux.nextPacket()
            XCTAssertNotNil(packet)
            XCTAssertTrue(tracks.contains { $0.id == packet?.trackID })
        }
        let beforeSeek = await source.transferredBytes
        let start = Date()
        try await demux.seek(to: CMTime(seconds: 300, preferredTimescale: 1_000))
        let afterSeek = await source.transferredBytes
        let seekPacket = try await demux.nextPacket()
        XCTAssertNotNil(seekPacket)
        XCTAssertLessThanOrEqual(seekPacket!.pts.seconds, 301)
        print("IA Matroska seek 300s: \(Date().timeIntervalSince(start))s, index bytes=\(afterSeek - beforeSeek), first PTS=\(seekPacket!.pts.seconds)")
    }
    private func element(_ id: [UInt8], _ body: [UInt8]) -> [UInt8] {
        precondition(body.count < 127)
        return id + [0x80 | UInt8(body.count)] + body
    }
    private func fixture(_ blocks: [UInt8], unknown: Bool = false, delay: UInt8 = 0) -> Data {
        let header = element([0x1a, 0x45, 0xdf, 0xa3], element([0x42, 0x82], Array("webm".utf8)))
        let track = element([0xae], element([0xd7], [1]) + element([0x83], [2]) + element([0x86], Array("A_OPUS".utf8)) + element([0x23, 0xe3, 0x83], [0x98, 0x96, 0x80]) + element([0x56, 0xaa], [delay]))
        let tracks = element([0x16, 0x54, 0xae, 0x6b], track)
        let clusterBody = element([0xe7], [10]) + blocks
        let cluster = unknown ? [0x1f, 0x43, 0xb6, 0x75, 0xff] + clusterBody : element([0x1f, 0x43, 0xb6, 0x75], clusterBody)
        return Data(header + [0x18, 0x53, 0x80, 0x67, 0xff] + tracks + cluster)
    }
    func testTracksSignedTimestampAndRewind() async throws {
        let demux = MatroskaDemuxer(source: MatroskaMemorySource(bytes: fixture(element([0xa3], [0x81, 0xff, 0xfe, 0x80, 42]))))
        let tracks = try await demux.tracks()
        XCTAssertEqual(tracks.first?.codec, "A_OPUS")
        let packet = try await demux.nextPacket()
        XCTAssertEqual(packet?.data, Data([42])); XCTAssertEqual(packet?.pts.value, 8_000_000)
        XCTAssertEqual(packet?.isKeyframe, true)
        try await demux.seek(to: .zero)
        let again = try await demux.nextPacket()
        XCTAssertEqual(again?.data, Data([42]))
    }
    func testAllLacingModesAndUnknownCluster() async throws {
        for (flags, lace) in [(UInt8(0x82), [UInt8(2), 1, 2]), (0x84, [2]), (0x86, [2, 0x82, 0xbf])] {
            let body: [UInt8] = flags == 0x82 ? [1, 2, 3, 4, 5, 6] : [1, 2, 3, 4, 5, 6]
            let demux = MatroskaDemuxer(source: MatroskaMemorySource(bytes: fixture(element([0xa3], [0x81, 0, 0, flags] + lace + body), unknown: true)))
            var packets: [DemuxedPacket] = []
            while let packet = try await demux.nextPacket() { packets.append(packet) }
            XCTAssertEqual(packets.count, 3)
            XCTAssertEqual(packets.map { $0.data.count }, flags == 0x82 ? [1, 2, 3] : [2, 2, 2])
            XCTAssertEqual(packets.map { $0.pts.value }, [10_000_000, 20_000_000, 30_000_000])
        }
    }
    func testBlockGroupReferenceAndDuration() async throws {
        let group = element([0xa0], element([0xa1], [0x81, 0, 0, 0, 7]) + element([0xfb], [0xff]) + element([0x9b], [20]))
        let demux = MatroskaDemuxer(source: MatroskaMemorySource(bytes: fixture(group)))
        let packet = try await demux.nextPacket()
        XCTAssertEqual(packet?.isKeyframe, false); XCTAssertEqual(packet?.duration.value, 20_000_000)
    }
    func testMalformedLaceThrows() async throws {
        let demux = MatroskaDemuxer(source: MatroskaMemorySource(bytes: fixture(element([0xa3], [0x81, 0, 0, 0x84, 2, 1]))))
        do { _ = try await demux.nextPacket(); XCTFail("Accepted malformed fixed lacing") }
        catch { XCTAssertEqual(error as? DemuxError, .invalidFormat("Unequal fixed lace sizes")) }
    }
    func testCodecDelayIsSubtracted() async throws {
        let demux = MatroskaDemuxer(source: MatroskaMemorySource(bytes: fixture(element([0xa3], [0x81, 0, 0, 0x80, 42]), delay: 100)))
        let packet = try await demux.nextPacket()
        XCTAssertEqual(packet?.pts.value, 9_999_900)
    }
    func testUnknownClusterEndsAtNextCluster() async throws {
        var bytes = fixture(element([0xa3], [0x81, 0, 0, 0x80, 42]), unknown: true)
        bytes.append(contentsOf: element([0x1f, 0x43, 0xb6, 0x75], element([0xe7], [30]) + element([0xa3], [0x81, 0, 0, 0x80, 43])))
        let demux = MatroskaDemuxer(source: MatroskaMemorySource(bytes: bytes))
        _ = try await demux.nextPacket()
        let second = try await demux.nextPacket()
        XCTAssertEqual(second?.data, Data([43])); XCTAssertEqual(second?.pts.value, 30_000_000)
    }
    func testNonzeroSeekSparseIndex() async throws {
        var bytes = fixture(element([0xa3], [0x81, 0, 0, 0x80, 42]), unknown: true)
        bytes.append(contentsOf: element([0x1f, 0x43, 0xb6, 0x75], element([0xe7], [30]) + element([0xa3], [0x81, 0, 0, 0x80, 43])))
        let demux = MatroskaDemuxer(source: MatroskaMemorySource(bytes: bytes))
        try await demux.seek(to: CMTime(value: 35, timescale: 1000))
        let packet = try await demux.nextPacket()
        XCTAssertEqual(packet?.data, Data([43]))
        XCTAssertEqual(packet?.pts.value, 30_000_000)
    }
    func testNonzeroSeekCues() async throws {
        var bytes = fixture(element([0xa3], [0x81, 0, 0, 0x80, 42]))
        // Header is 12 bytes; Segment header is five bytes. CueClusterPosition is
        // relative to byte 17 (the beginning of Segment data), not the file start.
        let segmentStart = 17
        let offset = bytes.count - segmentStart
        bytes.append(contentsOf: element([0x1f, 0x43, 0xb6, 0x75], element([0xe7], [30]) + element([0xa3], [0x81, 0, 0, 0x80, 43])))
        let cue = element([0xbb], element([0xb3], [25]) + element([0xb7], element([0xf7], [1]) + element([0xf1], [UInt8(offset)])))
        let cuePosition = bytes.count - segmentStart + 19
        let seek = element([0x4d, 0xbb], element([0x53, 0xab], [0x1c, 0x53, 0xbb, 0x6b]) + element([0x53, 0xac], [UInt8(cuePosition)]))
        bytes.append(contentsOf: element([0x11, 0x4d, 0x9b, 0x74], seek))
        bytes.append(contentsOf: element([0x1c, 0x53, 0xbb, 0x6b], cue))
        let demux = MatroskaDemuxer(source: MatroskaMemorySource(bytes: bytes))
        // CueTime deliberately precedes Cluster timestamp, proving Cues are chosen.
        try await demux.seek(to: CMTime(value: 26, timescale: 1000))
        let packet = try await demux.nextPacket()
        XCTAssertEqual(packet?.data, Data([43]))
    }
    func testTruncatedPayloadThrows() async throws {
        var bytes = fixture(element([0xa3], [0x81, 0, 0, 0x80, 42])); bytes.removeLast()
        let demux = MatroskaDemuxer(source: MatroskaMemorySource(bytes: bytes))
        do { _ = try await demux.nextPacket(); XCTFail("Accepted truncation") } catch { XCTAssertTrue(error is DemuxError) }
    }
}
