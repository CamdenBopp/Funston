import XCTest
import CoreMedia
import Darwin
@testable import ArchivePlayerCore

private struct PSBytes: ByteSource {
    let bytes: Data
    var chunk: Int = 3
    var length: UInt64? { get async throws { UInt64(bytes.count) } }
    func read(offset: UInt64, length: Int) async throws -> Data {
        guard offset <= bytes.count else { throw DemuxError.outOfBounds }
        let start = Int(offset)
        return bytes.subdata(in: start..<min(bytes.count, start + min(chunk, length)))
    }
}

final class ProgramStreamTests: XCTestCase, @unchecked Sendable {
    func testLocalByteSourcePESAtNon4096Tail() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ps-tail-\(UUID().uuidString).mpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = Data(repeating: 0x42, count: 4100)
        try Data(pes(0xE0, Array(expected), pts: 90000)).write(to: url)
        let demux = ProgramStreamDemuxer(source: try LocalByteSource(url: url))
        let packet = try await demux.nextPacket()
        XCTAssertEqual(packet?.data, expected)
        let end = try await demux.nextPacket()
        XCTAssertNil(end)
        // Same exact-read source must still reject a genuinely truncated final PES.
        try Data(pes(0xE0, [1, 2], pts: 90000).dropLast()).write(to: url)
        let broken = ProgramStreamDemuxer(source: try LocalByteSource(url: url))
        do { _ = try await broken.nextPacket(); XCTFail("Expected truncated PES") }
        catch { XCTAssertEqual(error as? DemuxError, .truncated) }
    }

    func testCorpusAccessUnitAdapterIfProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["PROGRAM_STREAM_CORPUS_PREFIX"] else { throw XCTSkip("Set PROGRAM_STREAM_CORPUS_PREFIX") }
        let started = ProcessInfo.processInfo.systemUptime
        let cpu = Double(clock()) / Double(CLOCKS_PER_SEC)
        var before = rusage(); getrusage(RUSAGE_SELF, &before)
        let adapter = ProgramStreamAccessUnitDemuxer(source: try LocalByteSource(url: URL(fileURLWithPath: path)))
        let formats = try await adapter.formatDescriptions()
        XCTAssertEqual(Set(formats.keys), [0xE0, 0xBD80, 0xBD81])
        var counts = [UInt32: Int]()
        for _ in 0..<30 {
            let next = try await adapter.nextPacket()
            let packet = try XCTUnwrap(next)
            XCTAssertTrue(packet.pts.isNumeric)
            XCTAssertTrue(packet.duration.isNumeric)
            counts[packet.trackID, default: 0] += 1
            _ = try SampleBufferFactory.make(packet: packet, format: try XCTUnwrap(formats[packet.trackID]))
        }
        var after = rusage(); getrusage(RUSAGE_SELF, &after)
        print("VOB access units: \(counts) localWall=\(ProcessInfo.processInfo.systemUptime - started) processCPU=\(Double(clock()) / Double(CLOCKS_PER_SEC) - cpu) peakRSS=\(after.ru_maxrss) peakGrowth=\(max(0, after.ru_maxrss - before.ru_maxrss))")
    }

    func testAC3AccessUnitsSpanPESAndHonorFirstAccessPointer() async throws {
        var frame = [UInt8](repeating: 0, count: 128)
        frame.replaceSubrange(0..<7, with: [0x0B, 0x77, 0, 0, 0, 0x40, 0x40])
        let bytes = pes(0xBD, [0x80, 1, 0, 1] + Array(frame.prefix(60)), pts: 90000)
            + pes(0xBD, [0x80, 1, 0, 69] + Array(frame.dropFirst(60)) + frame, pts: 92880)
        let demux = ProgramStreamAccessUnitDemuxer(source: PSBytes(bytes: Data(bytes)))
        let first = try await demux.nextPacket()
        let second = try await demux.nextPacket()
        XCTAssertEqual(first?.data, Data(frame)); XCTAssertEqual(second?.data, Data(frame))
        XCTAssertEqual(first?.pts.seconds, 1)
        XCTAssertEqual(second?.pts.seconds ?? 0, 1.032, accuracy: 0.000001)
        XCTAssertEqual(second?.duration.seconds ?? 0, 0.032, accuracy: 0.000001)
        let end = try await demux.nextPacket()
        XCTAssertNil(end)
    }

    func testAC3MidstreamFormatChangesAreRejected() async throws {
        var initial = [UInt8](repeating: 0, count: 128)
        initial.replaceSubrange(0..<7, with: [0x0B, 0x77, 0, 0, 0, 0x40, 0x40])
        for (rateCode, mode, profile, count) in [(UInt8(0x40), UInt8(0x40), UInt8(0x40), 138), (0, 0xE1, 0x40, 128), (0, 0x40, 0x38, 128)] {
            var changed = [UInt8](repeating: 0, count: count)
            changed.replaceSubrange(0..<7, with: [0x0B, 0x77, 0, 0, rateCode, profile, mode])
            let bytes = pes(0xBD, [0x80, 1, 0, 1] + initial, pts: 90000)
                + pes(0xBD, [0x80, 1, 0, 1] + changed, pts: 92880)
            let demux = ProgramStreamAccessUnitDemuxer(source: PSBytes(bytes: Data(bytes)))
            _ = try await demux.nextPacket()
            do { _ = try await demux.nextPacket(); XCTFail("Expected format-change rejection") }
            catch { XCTAssertEqual(error as? DemuxError, .unsupported("AC-3 format changed during playback")) }
        }
    }

    func testRealCorpusPESBoundaryNon4096TailIfProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["PROGRAM_STREAM_CORPUS_PREFIX"] else { throw XCTSkip("Set PROGRAM_STREAM_CORPUS_PREFIX") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let b = Array(data)
        var offset = 0, cut = 0
        while offset + 6 <= b.count, b[offset...offset+2].elementsEqual([0, 0, 1]) {
            let code = b[offset + 3]
            let length: Int
            if code == 0xBA {
                guard offset + 14 <= b.count else { break }
                length = 14 + Int(b[offset+13] & 7)
            } else { length = 6 + (Int(b[offset+4]) << 8 | Int(b[offset+5])) }
            guard offset + length <= b.count else { break }
            offset += length
            if offset % 4096 != 0 { cut = offset }
        }
        XCTAssertGreaterThan(cut, 4096)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("real-ps-tail-\(UUID().uuidString).vob")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.prefix(cut).write(to: url)
        let demux = ProgramStreamDemuxer(source: try LocalByteSource(url: url))
        var count = 0
        while try await demux.nextPacket() != nil { count += 1 }
        XCTAssertGreaterThan(count, 100)
        print("Real VOB exact-read non4096 tail: bytes=\(cut) PES=\(count)")
    }
    private func ifoFixture(discontinuous: Bool = false) -> Data {
        var b = [UInt8](repeating: 0, count: 6144)
        b.replaceSubrange(0..<12, with: Array("DVDVIDEO-VTS".utf8))
        b[0xCF] = 1 // PGC table sector
        b[0xD7] = 2 // time-map table sector
        b[0x203] = 2
        b.replaceSubrange(0x204..<0x20C, with: [4, 1, 0x72, 0x75, 0, 3, 0, 0])
        b.replaceSubrange(0x20C..<0x214, with: [4, 5, 0x68, 0x69, 0, 1, 0, 0])
        b[2049] = 1; b[2055] = 251; b[2063] = 16
        b[2064 + 12] = 0x81 // Logical Russian entry maps to physical AC3 1.
        b[2064 + 14] = 0x80
        b[4097] = 1; b[4103] = 23; b[4107] = 12
        b[4108] = 10; b[4111] = 2
        b[4115] = 1; b[4119] = 2
        if discontinuous { b[4116] = 0x80 }
        return Data(b)
    }

    func testIFOMetadataAndMappedSeek() async throws {
        let metadata = try ProgramStreamDVDMetadata(ifo: ifoFixture())
        XCTAssertEqual(metadata.audioTracks.map(\.id), [0xBD81, 0xBD80])
        XCTAssertEqual(metadata.audioTracks.map(\.language), ["ru", "hi"])
        XCTAssertEqual(metadata.audioTracks.map(\.channels), [2, 6])
        XCTAssertEqual(metadata.audioTracks[0].roles, [.commentary])
        XCTAssertEqual(metadata.seekPoints.map(\.seconds), [10, 20])
        let pack: [UInt8] = [0, 0, 1, 0xBA, 0x44, 0, 4, 0, 4, 1, 0, 0, 3, 0xF8]
        let bytes = [UInt8](repeating: 0, count: 2048) + pack + pes(0xBD, [0x81, 1, 0, 1, 0x0B, 0x77], pts: 900000)
        let demux = ProgramStreamDemuxer(source: PSBytes(bytes: Data(bytes)), dvdMetadata: metadata)
        try await demux.seek(to: CMTime(seconds: 15, preferredTimescale: 90000))
        let packet = try await demux.nextPacket()
        XCTAssertEqual(packet?.pts.value, 900000)
        let tracks = try await demux.tracks()
        XCTAssertEqual(tracks.first?.language, "ru")
        do { try await demux.seek(to: CMTime(seconds: 30, preferredTimescale: 1)); XCTFail("Unmapped seek should fail") }
        catch { XCTAssertEqual(error as? DemuxError, .seekUnavailable) }
    }

    func testIFORejectsTruncationAndDiscontinuousSeekMap() throws {
        XCTAssertTrue(try ProgramStreamDVDMetadata(ifo: ifoFixture(discontinuous: true)).seekPoints.isEmpty)
        XCTAssertThrowsError(try ProgramStreamDVDMetadata(ifo: Data(ifoFixture().prefix(400))))
        var invalid = ifoFixture()
        invalid[0x203] = 9
        XCTAssertThrowsError(try ProgramStreamDVDMetadata(ifo: invalid))
    }

    func testCorpusIFOIfProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["PROGRAM_STREAM_CORPUS_IFO"] else { throw XCTSkip("Set PROGRAM_STREAM_CORPUS_IFO to VTS_01_0.IFO") }
        let metadata = try ProgramStreamDVDMetadata(ifo: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(Set(metadata.audioTracks.map(\.id)), [0xBD80, 0xBD81])
        print("IA IFO tracks: \(metadata.audioTracks); usable seek points: \(metadata.seekPoints.count)")
    }

    private func stamp(_ value: UInt64, prefix: UInt8 = 2) -> [UInt8] {
        [prefix << 4 | UInt8((value >> 29) & 14) | 1, UInt8((value >> 22) & 255),
         UInt8((value >> 14) & 254) | 1, UInt8((value >> 7) & 255), UInt8((value << 1) & 254) | 1]
    }
    private func pes(_ stream: UInt8, _ payload: [UInt8], pts: UInt64? = nil) -> [UInt8] {
        let header: [UInt8] = pts.map { [0x80, 0x80, 5] + stamp($0) } ?? [0x80, 0, 0]
        let count = header.count + payload.count
        return [0, 0, 1, stream, UInt8(count >> 8), UInt8(count & 255)] + header + payload
    }

    func testPrivateStreamsAndPacketPreservingProbe() async throws {
        let bytes = pes(0xBD, [0x80, 1, 0, 1, 0x0B, 0x77], pts: 90000)
            + pes(0xBD, [0x88, 1, 0, 1, 0x7F, 0xFE])
            + pes(0xBD, [0xA0, 1, 0, 4, 0, 1, 0, 10, 11])
            + pes(0xBD, [0x20, 0, 4, 1, 2]) + [0, 0, 1, 0xB9]
        let demux = ProgramStreamDemuxer(source: PSBytes(bytes: Data(bytes)))
        let tracks = try await demux.tracks()
        XCTAssertEqual(Set(tracks.map(\.codec)), ["ac3", "dts", "pcm_dvd", "dvd_subtitle"])
        XCTAssertEqual(tracks.first(where: { $0.codec == "pcm_dvd" })?.channels, 2)
        let packet = try await demux.nextPacket()
        XCTAssertEqual(packet?.trackID, 0xBD80)
        XCTAssertEqual(packet?.data, Data([0x0B, 0x77]))
        XCTAssertEqual(packet?.pts.value, 90000)
    }

    func testTimestampWrapAndDTS() async throws {
        let before = (UInt64(1) << 33) - 90
        let bytes = pes(0xE0, [1], pts: before) + pes(0xE0, [2], pts: 90)
        let demux = ProgramStreamDemuxer(source: PSBytes(bytes: Data(bytes)))
        _ = try await demux.nextPacket()
        let packet = try await demux.nextPacket()
        XCTAssertEqual(packet?.pts.value, Int64(1) << 33 | 90)
        let header = [UInt8(0x80), 0xC0, 10] + stamp(1000, prefix: 3) + stamp(900, prefix: 1)
        let both = ProgramStreamDemuxer(source: PSBytes(bytes: Data([0, 0, 1, 0xE0, 0, 14] + header + [1])))
        let bothPacket = try await both.nextPacket()
        XCTAssertEqual(bothPacket?.pts.value, 1000)
        XCTAssertEqual(bothPacket?.dts.value, 900)
    }

    func testTruncatedAndMalformedTimestamps() async throws {
        for bytes in [[UInt8(0), 0, 1], [0, 0, 1, 0xBD, 0, 5, 0x80]] {
            do { _ = try await ProgramStreamDemuxer(source: PSBytes(bytes: Data(bytes))).nextPacket(); XCTFail("Expected truncation") }
            catch { XCTAssertEqual(error as? DemuxError, .truncated) }
        }
        var invalid = pes(0xE0, [1], pts: 100)
        invalid[9] &= 0xFE
        do { _ = try await ProgramStreamDemuxer(source: PSBytes(bytes: Data(invalid))).nextPacket(); XCTFail("Expected marker failure") }
        catch { guard case .invalidFormat = error as? DemuxError else { return XCTFail("\(error)") } }
    }

    func testPackAndMPEG1PES() async throws {
        let pack: [UInt8] = [0, 0, 1, 0xBA, 0x44, 0, 4, 0, 4, 1, 0, 0, 3, 0xF8]
        let mpeg1: [UInt8] = [0, 0, 1, 0xC0, 0, 7] + stamp(90000) + [1, 2]
        let demux = ProgramStreamDemuxer(source: PSBytes(bytes: Data(pack + mpeg1)))
        let packet = try await demux.nextPacket()
        XCTAssertEqual(packet?.data, Data([1, 2]))
        XCTAssertEqual(packet?.pts.value, 90000)
        try await demux.seek(to: .zero)
        let replay = try await demux.nextPacket()
        XCTAssertEqual(replay?.data, packet?.data)
    }

    func testSegmentBoundaryAndShortReads() async throws {
        let bytes = pes(0xC0, [1, 2, 3], pts: 7)
        let source = try ProgramStreamSegmentSource(segments: [
            .init(source: PSBytes(bytes: Data(bytes.prefix(5)), chunk: 1), length: 5),
            .init(source: PSBytes(bytes: Data(bytes.dropFirst(5)), chunk: 2), length: UInt64(bytes.count - 5))])
        let demux = ProgramStreamDemuxer(source: source)
        let packet = try await demux.nextPacket()
        XCTAssertEqual(packet?.data, Data([1, 2, 3]))
        let end = try await demux.nextPacket()
        XCTAssertNil(end)
    }

    /// Opt-in local corpus prefix probe; no network dependency in normal unit tests.
    func testCorpusPrefixIfProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["PROGRAM_STREAM_CORPUS_PREFIX"] else { throw XCTSkip("Set PROGRAM_STREAM_CORPUS_PREFIX to a VOB prefix") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let demux = ProgramStreamDemuxer(source: PSBytes(bytes: data, chunk: 4096))
        var packets = 0
        var ids = Set<UInt32>()
        do {
            while let packet = try await demux.nextPacket() { packets += 1; ids.insert(packet.trackID) }
        } catch DemuxError.truncated { /* A bounded prefix can end inside a PES. */ }
        XCTAssertGreaterThan(packets, 100)
        XCTAssertTrue(ids.contains(0xE0))
        XCTAssertTrue(ids.contains(0xBD80))
        print("PS corpus prefix: \(packets) packets, track IDs \(ids.sorted())")
    }

    func testInternetArchiveRangeOptIn() async throws {
        guard ProcessInfo.processInfo.environment["PROGRAM_STREAM_NETWORK_TEST"] == "1" else {
            throw XCTSkip("Set PROGRAM_STREAM_NETWORK_TEST=1 for a 1 MiB Internet Archive range probe")
        }
        let url = URL(string: "https://archive.org/download/vts-01-1_20250820_1408/VTS_01_1.VOB")!
        var request = URLRequest(url: url)
        request.setValue("bytes=0-1048575", forHTTPHeaderField: "Range")
        request.timeoutInterval = 30
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw XCTSkip("Corpus unavailable: \(error)") }
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
            throw XCTSkip("Corpus server did not honor HTTP Range")
        }
        XCTAssertEqual(data.count, 1_048_576)
        let demux = ProgramStreamDemuxer(source: PSBytes(bytes: data, chunk: 4096))
        var ids = Set<UInt32>()
        var count = 0
        do { while let packet = try await demux.nextPacket() { ids.insert(packet.trackID); count += 1 } }
        catch DemuxError.truncated { }
        XCTAssertGreaterThan(count, 100)
        XCTAssertTrue(ids.contains(0xE0))
        XCTAssertTrue(ids.contains(0xBD80))
        print("IA range corpus: \(count) PES packets, track IDs \(ids.sorted())")
    }
}
