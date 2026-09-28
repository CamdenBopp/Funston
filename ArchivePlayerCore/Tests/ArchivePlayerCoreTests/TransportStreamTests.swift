import XCTest
import CoreMedia
import AVFoundation
import Darwin
@testable import ArchivePlayerCore

private struct TransportStreamMemorySource: ByteSource {
    let data: Data
    var length: UInt64? { get async throws { UInt64(data.count) } }
    func read(offset: UInt64, length: Int) async throws -> Data {
        guard offset < data.count else { return Data() }
        return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + length))
    }
}

final class TransportStreamTests: XCTestCase {
    private func section(_ bytes: [UInt8]) -> [UInt8] {
        let crc = TransportStreamDemuxer.crc32(bytes)
        return bytes + [UInt8(truncatingIfNeeded: crc >> 24), UInt8(truncatingIfNeeded: crc >> 16),
                        UInt8(truncatingIfNeeded: crc >> 8), UInt8(truncatingIfNeeded: crc)]
    }

    private func packet(pid: UInt16, start: Bool = true, counter: UInt8 = 0,
                        discontinuity: Bool = false, payload: [UInt8]) -> [UInt8] {
        precondition(payload.count <= 182)
        let length = 183 - payload.count
        return [0x47, UInt8(pid >> 8) | (start ? 0x40 : 0), UInt8(truncatingIfNeeded: pid), 0x30 | counter,
                UInt8(length), discontinuity ? 0x80 : 0]
            + [UInt8](repeating: 0xff, count: length - 1) + payload
    }

    private func tables(type: UInt8 = 0x1b, descriptors: [UInt8] = []) -> [UInt8] {
        let pat = section([0, 0xb0, 13, 0, 1, 0xc1, 0, 0, 0, 1, 0xe1, 0])
        let pmt = section([2, 0xb0, UInt8(18 + descriptors.count), 0, 1, 0xc1, 0, 0, 0xe1, 1, 0xf0, 0,
                           type, 0xe1, 1, 0xf0, UInt8(descriptors.count)] + descriptors)
        return packet(pid: 0, payload: [0] + pat) + packet(pid: 256, payload: [0] + pmt)
    }

    private func pes(_ payload: [UInt8], pts: Int64 = 90_000, bounded: Bool = true) -> [UInt8] {
        let size = bounded ? payload.count + 8 : 0
        let stamp: [UInt8] = [0x21 | UInt8((pts >> 29) & 14), UInt8((pts >> 22) & 255),
                              UInt8((pts >> 14) & 254) | 1, UInt8((pts >> 7) & 255), UInt8((pts << 1) & 254) | 1]
        return [0, 0, 1, 0xe0, UInt8(size >> 8), UInt8(size & 255), 0x80, 0x80, 5] + stamp + payload
    }

    func testPATPMTAndPESExtraction() async throws {
        let elementary: [UInt8] = [0, 0, 0, 1, 0x65, 0xab, 0xcd]
        let bytes = tables() + packet(pid: 257, payload: pes(elementary))
        let demuxer = TransportStreamDemuxer(source: TransportStreamMemorySource(data: Data(bytes)))
        let tracks = try await demuxer.tracks()
        XCTAssertEqual(tracks.map(\.codec), ["h264"])
        let result = try await demuxer.nextPacket()
        XCTAssertEqual(result?.data, Data(elementary))
        XCTAssertEqual(result?.pts, CMTime(value: 90_000, timescale: 90_000))
        XCTAssertEqual(result?.isKeyframe, true)
        let end = try await demuxer.nextPacket()
        XCTAssertNil(end)
    }

    func testLanguageAndAudioRole() async throws {
        let bytes = tables(type: 6, descriptors: [0x0a, 4, 0x65, 0x6e, 0x67, 3, 0x7a, 0])
        let demuxer = TransportStreamDemuxer(source: TransportStreamMemorySource(data: Data(bytes)))
        let tracks = try await demuxer.tracks()
        XCTAssertEqual(tracks.first?.codec, "eac3")
        XCTAssertEqual(tracks.first?.language, "eng")
        XCTAssertEqual(tracks.first?.roles, [.visualImpaired])
    }

    func testDuplicateAndContinuityGapDropDamagedPES() async throws {
        let first = packet(pid: 257, payload: pes([0, 0, 1, 0x41], bounded: false))
        let gap = packet(pid: 257, start: false, counter: 2, payload: [0xaa])
        let valid = packet(pid: 257, counter: 3, payload: pes([0, 0, 1, 0x65]))
        let demuxer = TransportStreamDemuxer(source: TransportStreamMemorySource(data: Data(tables() + first + first + gap + valid)))
        let result = try await demuxer.nextPacket()
        XCTAssertEqual(result?.data, Data([0, 0, 1, 0x65]))
        let end = try await demuxer.nextPacket()
        XCTAssertNil(end)
    }

    func testDiscontinuityResetsPES() async throws {
        let first = packet(pid: 257, payload: pes([0xaa], bounded: false))
        let valid = packet(pid: 257, counter: 7, discontinuity: true, payload: pes([0xbb]))
        let demuxer = TransportStreamDemuxer(source: TransportStreamMemorySource(data: Data(tables() + first + valid)))
        let result = try await demuxer.nextPacket()
        XCTAssertEqual(result?.data, Data([0xbb]))
    }

    func testMPEGAudioLayerDetectedFromHeader() async throws {
        let demuxer = TransportStreamDemuxer(source: TransportStreamMemorySource(data: Data(tables(type: 3) + packet(pid: 257, payload: pes([0xff, 0xfb, 0x90, 0])))))
        _ = try await demuxer.nextPacket()
        let tracks = try await demuxer.tracks()
        XCTAssertEqual(tracks.first?.codec, "mp3")
    }

    func testPESLimit() async throws {
        var bytes = tables() + packet(pid: 257, payload: pes([UInt8](repeating: 0, count: 160), bounded: false))
        for counter: UInt8 in 1...8 { bytes += packet(pid: 257, start: false, counter: counter, payload: [UInt8](repeating: 0, count: 180)) }
        let demuxer = TransportStreamDemuxer(source: TransportStreamMemorySource(data: Data(bytes)), maximumPESBytes: 1024)
        do { _ = try await demuxer.nextPacket(); XCTFail("Expected bounded buffer failure") }
        catch { XCTAssertEqual(error as? DemuxError, .invalidFormat("PES buffer limit exceeded")) }
    }

    func testTruncatedPacketRejected() async throws {
        let demuxer = TransportStreamDemuxer(source: TransportStreamMemorySource(data: Data(tables() + [0x47])))
        do { _ = try await demuxer.nextPacket(); XCTFail("Expected truncation") }
        catch { XCTAssertEqual(error as? DemuxError, .truncated) }
    }

    func testSplitPSIAndPES() async throws {
        let pat = section([0, 0xb0, 13, 0, 1, 0xc1, 0, 0, 0, 1, 0xe1, 0])
        let pmtPacket = Array(tables().suffix(188))
        let body = pes([0, 0, 1, 0x65, 0xaa, 0xbb])
        let bytes = packet(pid: 0, payload: [0] + Array(pat.prefix(7)))
            + packet(pid: 0, start: false, counter: 1, payload: Array(pat.dropFirst(7)))
            + pmtPacket
            + packet(pid: 257, payload: Array(body.prefix(5)))
            + packet(pid: 257, start: false, counter: 1, payload: Array(body.dropFirst(5)))
        let demuxer = TransportStreamDemuxer(source: TransportStreamMemorySource(data: Data(bytes)))
        let result = try await demuxer.nextPacket()
        XCTAssertEqual(result?.data, Data([0, 0, 1, 0x65, 0xaa, 0xbb]))
    }

    func testCRCRejectsCorruptTable() async throws {
        var bytes = tables()
        bytes[187] ^= 1
        let demuxer = TransportStreamDemuxer(source: TransportStreamMemorySource(data: Data(bytes)))
        do { _ = try await demuxer.tracks(); XCTFail("Expected invalid PAT rejection") }
        catch { XCTAssertEqual(error as? DemuxError, .invalidFormat("No supported PMT within 4 MiB")) }
    }

    func testPTSAndDTS() async throws {
        var body = pes([0xaa])
        var dtsStamp = Array(pes([], pts: 45_000)[9..<14])
        dtsStamp[0] = (dtsStamp[0] & 15) | 0x10
        body[5] += 5; body[7] = 0xc0; body[8] = 10; body[9] |= 0x10
        body.insert(contentsOf: dtsStamp, at: 14)
        let demuxer = TransportStreamDemuxer(source: TransportStreamMemorySource(data: Data(tables() + packet(pid: 257, payload: body))))
        let result = try await demuxer.nextPacket()
        XCTAssertEqual(result?.pts, CMTime(value: 90_000, timescale: 90_000))
        XCTAssertEqual(result?.dts, CMTime(value: 45_000, timescale: 90_000))
    }

    func testAnnexBStartCodes() {
        XCTAssertEqual(TransportStreamDemuxer.annexBNALUnits([0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x68, 2]), [[0x67, 1], [0x68, 2]])
    }

    func testArchiveCorpusPrefixIfProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["TRANSPORT_STREAM_CORPUS_PREFIX"] else {
            throw XCTSkip("Set TRANSPORT_STREAM_CORPUS_PREFIX to a local bounded IA TS prefix")
        }
        let demuxer = TransportStreamDemuxer(source: TransportStreamMemorySource(data: try Data(contentsOf: URL(fileURLWithPath: path))))
        let tracks = try await demuxer.tracks()
        XCTAssertFalse(tracks.isEmpty)
        print("TS CORPUS tracks: \(tracks.map { "\($0.id):\($0.codec)" })")
        for _ in 0..<10 {
            let packet = try await demuxer.nextPacket()
            XCTAssertNotNil(packet)
            XCTAssertFalse(packet?.data.isEmpty ?? true)
        }
    }

    func testADTSAccessUnitSplittingAndConfiguration() async throws {
        let adts: [UInt8] = [0xff, 0xf1, 0x4c, 0x80, 1, 0x3f, 0xfc, 0xaa, 0xbb]
        let bytes = tables(type: 0x0f) + packet(pid: 257, payload: pes(adts + adts))
        let demuxer = TransportStreamAccessUnitDemuxer(source: TransportStreamMemorySource(data: Data(bytes)))
        let tracks = try await demuxer.tracks()
        XCTAssertEqual(tracks.first?.codecPrivate, Data([0x11, 0x90]))
        XCTAssertEqual(tracks.first?.channels, 2)
        let first = try await demuxer.nextPacket()
        let second = try await demuxer.nextPacket()
        XCTAssertEqual(first?.data, Data([0xaa, 0xbb]))
        XCTAssertEqual(first?.duration, CMTime(value: 1024, timescale: 48000))
        XCTAssertEqual(second?.pts, CMTimeAdd(CMTime(value: 90000, timescale: 90000), CMTime(value: 1024, timescale: 48000)))
    }

    func testADTSUntimestampedPESPreservesComputedClock() async throws {
        let adts: [UInt8] = [0xff, 0xf1, 0x4c, 0x80, 1, 0x3f, 0xfc, 0xaa, 0xbb]
        var noPTS = pes(adts); noPTS.removeSubrange(9..<14)
        noPTS[5] -= 5; noPTS[7] = 0; noPTS[8] = 0
        let bytes = tables(type: 0x0f) + packet(pid: 257, payload: pes(adts)) + packet(pid: 257, counter: 1, payload: noPTS)
        let demuxer = TransportStreamAccessUnitDemuxer(source: TransportStreamMemorySource(data: Data(bytes)))
        let first = try await demuxer.nextPacket(), second = try await demuxer.nextPacket()
        XCTAssertEqual(second?.pts, CMTimeAdd(try XCTUnwrap(first?.pts), CMTime(value: 1024, timescale: 48000)))
    }

    func testAccessUnitAggregateBufferLimit() async throws {
        let adts: [UInt8] = [0xff, 0xf1, 0x4c, 0x80, 1, 0x3f, 0xfc, 0xaa, 0xbb]
        let bytes = tables(type: 0x0f) + packet(pid: 257, payload: pes(Array(repeating: adts, count: 18).flatMap { $0 }))
        let demuxer = TransportStreamAccessUnitDemuxer(source: TransportStreamMemorySource(data: Data(bytes)), maximumBufferedBytes: 16)
        do { _ = try await demuxer.tracks(); XCTFail("Expected aggregate cap") }
        catch { XCTAssertEqual(error as? DemuxError, .unsupported("TS access-unit aggregate buffer limit")) }
    }

    func testAVCAccessUnitAcrossPESBoundaryUsesNextAUTimestamp() async throws {
        let first: [UInt8] = [0,0,0,1,9,0xf0, 0,0,0,1,0x67,0x64,0,0x1f, 0,0,0,1,0x68,0x80, 0,0,0,1,0x65,0x80,0xaa,0xbb,0xcc]
        let next: [UInt8] = [0,0,0,1,9,0xf0, 0,0,0,1,0x61,0x80,0xdd]
        let bytes = tables() + packet(pid: 257, payload: pes(Array(first.prefix(27))))
            + packet(pid: 257, counter: 1, payload: pes(Array(first.suffix(2)) + next, pts: 180000))
            + packet(pid: 257, counter: 2, payload: pes(next, pts: 270000))
        let demuxer = TransportStreamAccessUnitDemuxer(source: TransportStreamMemorySource(data: Data(bytes)))
        let a = try await demuxer.nextPacket(), b = try await demuxer.nextPacket()
        XCTAssertEqual(a?.data.suffix(5), Data([0x65,0x80,0xaa,0xbb,0xcc]))
        XCTAssertEqual(a?.pts, CMTime(value: 90000, timescale: 90000))
        XCTAssertEqual(b?.pts, CMTime(value: 180000, timescale: 90000))
        XCTAssertEqual(a?.isKeyframe, true)
    }

    func testAVCTimestampIsNotReusedForCarriedAUDRegion() async throws {
        let first: [UInt8] = [0,0,0,1,9,0xf0, 0,0,0,1,0x67,0x64,0,0x1f, 0,0,0,1,0x68,0x80, 0,0,0,1,0x65,0x80,0xaa]
        let next: [UInt8] = [0,0,0,1,9,0xf0, 0,0,0,1,0x61,0x80,0xbb]
        // A and B share PES1's sole PTS. B must fail both when another PES
        // supplies a later timestamp for C and when B reaches EOF directly.
        for addThirdAU in [true, false] {
            var bytes = tables() + packet(pid: 257, payload: pes(first + next, pts: 90000))
            if addThirdAU { bytes += packet(pid: 257, counter: 1, payload: pes(next, pts: 270000)) }
            let demuxer = TransportStreamAccessUnitDemuxer(source: TransportStreamMemorySource(data: Data(bytes)))
            do { _ = try await demuxer.nextPacket(); XCTFail("Missing B timestamp must not inherit A or C") }
            catch { XCTAssertEqual(error as? DemuxError, .invalidFormat("AVC AU timestamp missing")) }
        }
    }

    @MainActor func testActualIATransportStreamRenderingIfEnabled() async throws {
        guard ProcessInfo.processInfo.environment["IA_TS_RENDER_TESTS"] == "1" else { throw XCTSkip("Set IA_TS_RENDER_TESTS=1 for TS renderer gate") }
        let started = Date()
        var before = rusage(); getrusage(RUSAGE_SELF, &before)
        let source = HTTPRangeByteSource(url: URL(string: "https://archive.org/download/twitch-videos-2179756722/2179756722.ts")!, windowSize: 256 * 1024)
        let demuxer = TransportStreamAccessUnitDemuxer(source: source)
        let renderers = SampleBufferPlaybackRenderers(); renderers.audioRenderer.volume = 0
        let engine = SampleBufferPlaybackEngine(demuxer: demuxer, rendering: renderers)
        try await engine.prepare(); try engine.play()
        var startup: TimeInterval?
        for _ in 0..<200 {
            if engine.lastError != nil { break }
            if renderers.displayLayer.sampleBufferRenderer.status == .rendering && renderers.audioRenderer.status == .rendering {
                startup = Date().timeIntervalSince(started); break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let anchor = engine.currentTime.seconds
        try await Task.sleep(for: .seconds(3))
        let bytes = await source.transferredBytes
        var after = rusage(); getrusage(RUSAGE_SELF, &after)
        let cpu = Double(after.ru_utime.tv_sec + after.ru_stime.tv_sec - before.ru_utime.tv_sec - before.ru_stime.tv_sec) + Double(after.ru_utime.tv_usec + after.ru_stime.tv_usec - before.ru_utime.tv_usec - before.ru_stime.tv_usec) / 1_000_000
        print("ACTUAL IA TS RENDER startup=\(String(describing:startup)) elapsed=\(Date().timeIntervalSince(started)) cpuSeconds=\(cpu) peakRSSBytes=\(after.ru_maxrss) peakRSSBefore=\(before.ru_maxrss) bytes=\(bytes) tracks=\(engine.tracks.map { $0.codec }) samples=\(engine.enqueuedPacketCount) clockAdvance=\(engine.currentTime.seconds-anchor) videoStatus=\(renderers.displayLayer.sampleBufferRenderer.status.rawValue) audioStatus=\(renderers.audioRenderer.status.rawValue) error=\(String(describing:engine.lastError))")
        XCTAssertNotNil(startup)
        XCTAssertNil(engine.lastError)
        XCTAssertEqual(renderers.displayLayer.sampleBufferRenderer.status, .rendering)
        XCTAssertEqual(renderers.audioRenderer.status, .rendering)
        XCTAssertGreaterThan(engine.enqueuedPacketCount, 10)
        XCTAssertGreaterThan(engine.currentTime.seconds - anchor, 2)
        await engine.stop()
    }
}
