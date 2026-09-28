import XCTest
import Foundation
import Darwin
@testable import ArchivePlayerCore

private struct ConformanceBytes: ByteSource {
    let data: Data
    var length: UInt64? { get async throws { UInt64(data.count) } }
    func read(offset: UInt64, length: Int) async throws -> Data {
        guard offset <= data.count, length >= 0 else { throw DemuxError.outOfBounds }
        let start = Int(offset)
        return data.subdata(in: start..<min(data.count, start + length))
    }
}

/// Opt-in development diagnostics: no ffprobe process or dependency ships with the app.
final class CorpusConformanceTests: XCTestCase, @unchecked Sendable {
    private struct Sample {
        let wall = ProcessInfo.processInfo.systemUptime
        let cpu = Double(clock()) / Double(CLOCKS_PER_SEC)
        let peakRSS: Int64
        init() {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            peakRSS = Int64(usage.ru_maxrss) // Darwin reports bytes, not Linux KiB.
        }
    }

    private func report(_ label: String, since start: Sample, bytes: UInt64, requests: UInt64) {
        let end = Sample()
        print(String(format: "CONFORMANCE %@ wall=%.6fs processCPU=%.6fs transferred=%llu requests=%llu processPeakRSS=%lldB peakGrowth=%lldB",
                     label, end.wall - start.wall, end.cpu - start.cpu, bytes, requests,
                     end.peakRSS, max(0, end.peakRSS - start.peakRSS)))
    }

    func testLiveCorpusStartupMetrics() async throws {
        guard ProcessInfo.processInfo.environment["IA_CONFORMANCE_NETWORK"] == "1" else {
            throw XCTSkip("Set IA_CONFORMANCE_NETWORK=1 for bounded real IA startup measurements")
        }
        let cases: [(String, String, String)] = [
            ("MKV", "the-ancient-magus-bride-s-01-e-03-720p-hd-blu-ray-multi-audio-esub", "The Ancient Magus' Bride S01E03 720p HD BluRay Multi Audio ESub.mkv"),
            ("VOB", "vts-01-1_20250820_1408", "VTS_01_1.VOB"),
            ("TS", "twitch-videos-2179756722", "2179756722.ts")
        ]
        for (kind, item, filename) in cases {
            let base = URL(string: "https://archive.org/download/\(item)/")!
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 90
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let source = HTTPRangeByteSource(url: base.appendingPathComponent(filename), session: session, windowSize: 256 * 1024)
            let demux: any Demuxer
            switch kind {
            case "MKV": demux = MatroskaDemuxer(source: source)
            case "VOB": demux = ProgramStreamDemuxer(source: source)
            default: demux = TransportStreamDemuxer(source: source)
            }
            let begin = Sample()
            let tracks = try await demux.tracks()
            let metadataBytes = await source.transferredBytes
            let metadataRequests = await source.requestCount
            report("\(kind) metadata", since: begin, bytes: metadataBytes, requests: metadataRequests)
            XCTAssertFalse(tracks.isEmpty)
            let mediaCodecs = tracks.map { normalize($0.codec) }.sorted()
            switch kind {
            case "MKV": XCTAssertEqual(mediaCodecs, ["aac", "h264", "hdmv_pgs_subtitle", "hdmv_pgs_subtitle", "opus", "opus"])
            case "VOB": XCTAssertEqual(mediaCodecs, ["ac3", "ac3", "mpeg2video"])
            default: XCTAssertEqual(mediaCodecs, ["aac", "h264"])
            }
            print("CONFORMANCE \(kind) tracks=\(tracks.map { "\($0.id):\($0.codec):\($0.language ?? "unknown"):channels=\($0.channels.map(String.init) ?? "unknown")" })")
            let packetStart = Sample()
            for _ in 0..<32 {
                let packet = try await demux.nextPacket()
                XCTAssertNotNil(packet)
                XCTAssertFalse(packet?.data.isEmpty ?? true)
                XCTAssertTrue(tracks.contains { $0.id == packet?.trackID })
            }
            let endBytes = await source.transferredBytes
            let endRequests = await source.requestCount
            report("\(kind) next32", since: packetStart, bytes: endBytes - metadataBytes, requests: endRequests - metadataRequests)
            XCTAssertLessThan(endBytes, 8 * 1024 * 1024, "Startup transfer regression")
        }
    }

    private func normalize(_ codec: String) -> String {
        switch codec {
        case "V_MPEG4/ISO/AVC": return "h264"
        case "A_AAC": return "aac"
        case "A_OPUS": return "opus"
        case "S_HDMV/PGS": return "hdmv_pgs_subtitle"
        default: return codec
        }
    }

    func testCorruptAndTruncatedInputsReturnTypedErrors() async throws {
        let inputs: [(String, Data)] = [
            ("MKV", Data([0])), ("MKV", Data([0x1A, 0x45, 0xDF])),
            ("VOB", Data([0, 0, 2, 0xBA])), ("VOB", Data([0, 0, 1, 0xBD, 0, 20, 0x80])),
            ("TS", Data(repeating: 0, count: 188)), ("TS", Data([0x47, 0x40, 0]))
        ]
        for (kind, data) in inputs {
            let source = ConformanceBytes(data: data)
            let demux: any Demuxer
            switch kind {
            case "MKV": demux = MatroskaDemuxer(source: source)
            case "VOB": demux = ProgramStreamDemuxer(source: source)
            default: demux = TransportStreamDemuxer(source: source)
            }
            do { _ = try await demux.nextPacket(); XCTFail("\(kind) must reject malformed fixture") }
            catch { XCTAssertNotNil(error as? DemuxError, "\(kind) untyped error: \(error)") }
        }
    }

    #if os(macOS)
    /// Existing local prefix paths permit oracle comparison without another download.
    /// MKV compares ffprobe against its known corpus manifest because a prefix's length
    /// is insufficient to validate the full declared EBML Segment size locally.
    func testDevelopmentFFprobeOracleIfProvided() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let executable = env["IA_FFPROBE"] else { throw XCTSkip("Set IA_FFPROBE and IA_CONFORMANCE_{MKV,VOB,TS}_PATH") }
        var tested = 0
        for kind in ["MKV", "VOB", "TS"] {
            guard let path = env["IA_CONFORMANCE_\(kind)_PATH"] else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-v", "error", "-show_entries", "stream=id,codec_name,codec_type,channels:stream_tags=language", "-of", "json", path]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try process.run()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
            let streams = try XCTUnwrap(object["streams"] as? [[String: Any]])
            let media = streams.filter { ["video", "audio", "subtitle"].contains($0["codec_type"] as? String ?? "") }
            let oracleCodecs = media.compactMap { $0["codec_name"] as? String }.sorted()
            if kind == "MKV" {
                XCTAssertEqual(oracleCodecs, ["aac", "h264", "hdmv_pgs_subtitle", "hdmv_pgs_subtitle", "opus", "opus"])
                let languages = media.filter { ($0["codec_type"] as? String) == "audio" }.map { ($0["tags"] as? [String: String])?["language"] }
                XCTAssertEqual(languages, ["hin", "eng", "jpn"])
            } else {
                let source = ConformanceBytes(data: try Data(contentsOf: URL(fileURLWithPath: path)))
                let demux: any Demuxer = kind == "VOB" ? ProgramStreamDemuxer(source: source, probeBytes: 512 * 1024) : TransportStreamDemuxer(source: source)
                let tracks = try await demux.tracks()
                XCTAssertEqual(tracks.map { normalize($0.codec) }.sorted(), oracleCodecs)
                let ids = media.compactMap { entry -> UInt32? in
                    guard let text = entry["id"] as? String, let id = UInt32(text.dropFirst(2), radix: 16) else { return nil }
                    if kind == "VOB" { return id < 0x100 ? 0xBD00 | id : id & 0xFF }
                    return id
                }
                XCTAssertEqual(Set(tracks.map(\.id)), Set(ids))
            }
            print("CONFORMANCE ffprobe \(kind) media=\(media)")
            tested += 1
        }
        XCTAssertGreaterThan(tested, 0, "Provide at least one local corpus path")
    }
    #endif
}
