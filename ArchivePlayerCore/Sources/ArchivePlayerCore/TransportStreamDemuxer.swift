import Foundation
import CoreMedia

/// Bounded 188-byte MPEG transport-stream demultiplexing. Output preserves elementary
/// stream framing; one PES is not necessarily one decoded audio/video access unit.
public actor TransportStreamDemuxer: Demuxer {
    /// Callers must perform codec-specific access-unit splitting before decoding.
    public nonisolated let packetFraming = "raw-pes-payload"
    private let source: any ByteSource
    private let maximumPESBytes: Int
    private var offset: UInt64 = 0
    private var input = [UInt8]()
    private var cursor = 0
    private var eof = false
    private var pmtPIDs = Set<UInt16>()
    private var mediaTracks: [UInt16: MediaTrack] = [:]
    private var sections: [UInt16: [UInt8]] = [:]
    private var continuity: [UInt16: UInt8] = [:]
    private var pes: [UInt16: [UInt8]] = [:]
    private var ready: [DemuxedPacket] = []
    private var discovered = false

    public init(source: any ByteSource, maximumPESBytes: Int = 4 * 1024 * 1024) {
        self.source = source
        self.maximumPESBytes = max(1024, min(maximumPESBytes, 16 * 1024 * 1024))
    }

    public func tracks() async throws -> [MediaTrack] {
        if !discovered {
            // A missing PMT must not scan an unbounded network source.
            for _ in 0..<22_311 {
                guard mediaTracks.isEmpty, try await pump() else { break }
            }
            guard !mediaTracks.isEmpty else { throw DemuxError.invalidFormat("No supported PMT within 4 MiB") }
            discovered = true
        }
        return mediaTracks.values.sorted { $0.id < $1.id }
    }

    public func seek(to time: CMTime) async throws {
        throw DemuxError.seekUnavailable
    }

    public func nextPacket() async throws -> DemuxedPacket? {
        _ = try await tracks()
        while ready.isEmpty {
            if try await !pump() { return nil }
        }
        return ready.removeFirst()
    }

    private func pump() async throws -> Bool {
        while input.count - cursor < 188 && !eof {
            if cursor > 0 { input.removeFirst(cursor); cursor = 0 }
            let totalLength = try await source.length
            if let totalLength, offset >= totalLength { eof = true; break }
            let count = totalLength.map { Int(min(UInt64(188 * 256), $0 - offset)) } ?? 188 * 256
            let chunk = try await source.read(offset: offset, length: count)
            if chunk.isEmpty { eof = true; break }
            guard chunk.count <= 188 * 256 else { throw DemuxError.invalidFormat("Byte source exceeded requested read") }
            offset += UInt64(chunk.count)
            input.append(contentsOf: chunk)
        }
        if input.count - cursor < 188 {
            if input.count != cursor { throw DemuxError.truncated }
            for pid in pes.keys.sorted() { try finishPES(pid) }
            return !ready.isEmpty
        }
        guard input[cursor] == 0x47 else {
            // Fail closed rather than interpreting arbitrary bytes as a packet boundary.
            throw DemuxError.invalidFormat("Expected 188-byte TS sync byte")
        }
        let packet = Array(input[cursor..<cursor + 188]); cursor += 188
        try consume(packet)
        return true
    }

    private func consume(_ b: [UInt8]) throws {
        let pid = UInt16(b[1] & 0x1f) << 8 | UInt16(b[2])
        if pid == 0x1fff { return }
        guard pid == 0 || pmtPIDs.contains(pid) || mediaTracks[pid] != nil else { return }
        let start = b[1] & 0x40 != 0
        let control = (b[3] >> 4) & 3
        guard control != 0 else { throw DemuxError.invalidFormat("Reserved adaptation control") }
        if b[1] & 0x80 != 0 || b[3] & 0xc0 != 0 {
            pes[pid] = nil; sections[pid] = nil; continuity[pid] = nil
            return
        }
        var index = 4
        if control & 2 != 0 {
            let length = Int(b[4])
            guard length <= 183, 5 + length <= 188 else { throw DemuxError.invalidFormat("Adaptation field length") }
            if length > 0 && b[5] & 0x80 != 0 {
                continuity[pid] = nil; pes[pid] = nil; sections[pid] = nil
            }
            index = 5 + length
        }
        guard control & 1 != 0, index < 188 else { return }
        let counter = b[3] & 15
        if let previous = continuity[pid] {
            if previous == counter { return } // retransmitted packet
            if counter != ((previous + 1) & 15) { pes[pid] = nil; sections[pid] = nil }
        }
        continuity[pid] = counter
        let payload = Array(b[index...])
        if pid == 0 || pmtPIDs.contains(pid) {
            try consumePSI(payload, pid: pid, start: start)
        } else {
            if start {
                try finishPES(pid)
                pes[pid] = []
            }
            guard pes[pid] != nil else { return }
            guard pes[pid]!.count + payload.count <= maximumPESBytes,
                  pes.values.reduce(0, { $0 + $1.count }) + payload.count <= 16 * 1024 * 1024 else {
                pes[pid] = nil
                throw DemuxError.invalidFormat("PES buffer limit exceeded")
            }
            pes[pid]!.append(contentsOf: payload)
            if let bytes = pes[pid], bytes.count >= 6 {
                let size = Int(bytes[4]) << 8 | Int(bytes[5])
                if size > 0 && bytes.count >= size + 6 { try finishPES(pid) }
            }
        }
    }

    private func consumePSI(_ b: [UInt8], pid: UInt16, start: Bool) throws {
        var index = 0
        if start {
            guard let pointer = b.first, Int(pointer) + 1 <= b.count else { throw DemuxError.truncated }
            index = Int(pointer) + 1
            if sections[pid] != nil && pointer > 0 {
                sections[pid]!.append(contentsOf: b[1..<index])
                try drainSections(pid)
            }
            sections[pid] = []
        }
        guard sections[pid] != nil else { return }
        sections[pid]!.append(contentsOf: b[index...])
        try drainSections(pid)
    }

    private func drainSections(_ pid: UInt16) throws {
        while var bytes = sections[pid], bytes.count >= 3 {
            if bytes[0] == 0xff { sections[pid] = nil; return }
            let size = 3 + (Int(bytes[1] & 15) << 8 | Int(bytes[2]))
            guard size >= 12, size <= 1024 else { throw DemuxError.invalidFormat("PSI section length") }
            guard bytes.count >= size else { return }
            let section = Array(bytes.prefix(size))
            bytes.removeFirst(size); sections[pid] = bytes
            guard Self.crc32(section) == 0 else { continue }
            guard section[5] & 1 != 0 else { continue }
            if pid == 0 && section[0] == 0 {
                for i in stride(from: 8, to: size - 4, by: 4) {
                    guard i + 3 < size - 4 else { throw DemuxError.truncated }
                    if section[i] != 0 || section[i + 1] != 0 {
                        let pmt = UInt16(section[i + 2] & 31) << 8 | UInt16(section[i + 3])
                        guard pmtPIDs.contains(pmt) || pmtPIDs.count < 64 else { throw DemuxError.unsupported("Too many TS programs") }
                        pmtPIDs.insert(pmt)
                    }
                }
            } else if pmtPIDs.contains(pid) && section[0] == 2 {
                try parsePMT(section)
            }
        }
    }

    private func parsePMT(_ b: [UInt8]) throws {
        guard b.count >= 16 else { throw DemuxError.truncated }
        var i = 12 + (Int(b[10] & 15) << 8 | Int(b[11]))
        guard i <= b.count - 4 else { throw DemuxError.truncated }
        while i < b.count - 4 {
            guard i + 5 <= b.count - 4 else { throw DemuxError.truncated }
            let type = b[i]
            let pid = UInt16(b[i + 1] & 31) << 8 | UInt16(b[i + 2])
            let end = i + 5 + (Int(b[i + 3] & 15) << 8 | Int(b[i + 4]))
            guard end <= b.count - 4 else { throw DemuxError.truncated }
            var codec: String?
            var kind = MediaKind.audio
            switch type {
            case 0x1b: codec = "h264"; kind = .video
            case 0x24: codec = "hevc"; kind = .video
            case 0x0f: codec = "aac"
            case 0x11: codec = "aac-latm"
            case 0x03, 0x04: codec = "mpeg-audio"
            case 0x81: codec = "ac3"
            case 0x87: codec = "eac3"
            default: break
            }
            var language: String?
            var roles = Set<TrackRole>()
            var d = i + 5
            while d < end {
                guard d + 2 <= end else { throw DemuxError.truncated }
                let tag = b[d], count = Int(b[d + 1]); d += 2
                guard d + count <= end else { throw DemuxError.truncated }
                if tag == 0x0a && count >= 4 {
                    language = String(bytes: b[d..<d + 3], encoding: .ascii)
                    if b[d + 3] == 2 { roles.insert(.hearingImpaired) }
                    if b[d + 3] == 3 { roles.insert(.visualImpaired) }
                }
                if type == 6 {
                    if tag == 0x6a { codec = "ac3" }
                    if tag == 0x7a { codec = "eac3" }
                    if tag == 5 && count >= 4 {
                        let registration = String(bytes: b[d..<d + 4], encoding: .ascii)
                        if registration == "AC-3" { codec = "ac3" }
                        if registration == "EAC3" { codec = "eac3" }
                    }
                }
                d += count
            }
            if let codec {
                guard mediaTracks[pid] != nil || mediaTracks.count < 64 else { throw DemuxError.unsupported("Too many TS tracks") }
                mediaTracks[pid] = MediaTrack(id: UInt32(pid), kind: kind, codec: codec, language: language, roles: roles)
            }
            i = end
        }
    }

    private func finishPES(_ pid: UInt16) throws {
        guard let b = pes.removeValue(forKey: pid), !b.isEmpty else { return }
        guard b.count >= 9, b[0...2].elementsEqual([0, 0, 1]), b[6] & 0xc0 == 0x80 else {
            throw DemuxError.invalidFormat("Malformed PES header")
        }
        let declared = Int(b[4]) << 8 | Int(b[5])
        let end = declared == 0 ? b.count : declared + 6
        let start = 9 + Int(b[8])
        guard start <= end, end <= b.count else { throw DemuxError.truncated }
        let flags = b[7] >> 6
        guard flags != 1 else { throw DemuxError.invalidFormat("Invalid PES timestamp flags") }
        var pts = CMTime.invalid, dts = CMTime.invalid
        if flags >= 2 {
            guard start >= 14 else { throw DemuxError.truncated }
            pts = try Self.timestamp(b, at: 9, prefix: flags)
        }
        if flags == 3 {
            guard start >= 19 else { throw DemuxError.truncated }
            dts = try Self.timestamp(b, at: 14, prefix: 1)
        }
        let payload = Array(b[start..<end])
        if mediaTracks[pid]?.codec == "mpeg-audio", payload.count >= 4,
           payload[0] == 0xff, payload[1] & 0xe0 == 0xe0 {
            switch (payload[1] >> 1) & 3 {
            case 1: mediaTracks[pid]?.codec = "mp3"
            case 2: mediaTracks[pid]?.codec = "mp2"
            default: break
            }
        }
        let codec = mediaTracks[pid]?.codec
        let keyframe = Self.annexBNALUnits(payload).contains {
            guard let first = $0.first else { return false }
            if codec == "h264" { return first & 31 == 5 }
            if codec == "hevc" { return (16...21).contains(Int((first >> 1) & 63)) }
            return false
        }
        ready.append(DemuxedPacket(trackID: UInt32(pid), data: Data(payload), pts: pts, dts: dts, isKeyframe: keyframe))
    }

    private static func timestamp(_ b: [UInt8], at i: Int, prefix: UInt8) throws -> CMTime {
        guard b[i] >> 4 == prefix, b[i] & 1 == 1, b[i + 2] & 1 == 1, b[i + 4] & 1 == 1 else {
            throw DemuxError.invalidFormat("PES timestamp marker bits")
        }
        let value = (Int64(b[i] & 14) << 29) | (Int64(b[i + 1]) << 22)
            | (Int64(b[i + 2] & 254) << 14) | (Int64(b[i + 3]) << 7) | Int64(b[i + 4] >> 1)
        return CMTime(value: value, timescale: 90_000)
    }

    /// CRC-32/MPEG-2, including the transmitted CRC yields zero.
    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc = UInt32.max
        for byte in bytes {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = crc & 0x80000000 != 0 ? (crc << 1) ^ 0x04c11db7 : crc << 1 }
        }
        return crc
    }

    /// Extract at most 4096 NAL units from this buffer (does not assemble across PES).
    public static func annexBNALUnits(_ bytes: [UInt8]) -> [[UInt8]] {
        var starts: [(Int, Int)] = []
        var i = 0
        while i + 3 <= bytes.count && starts.count <= 4096 {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 { starts.append((i, i + 3)); i += 3; continue }
                if i + 4 <= bytes.count && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                    starts.append((i, i + 4)); i += 4; continue
                }
            }
            i += 1
        }
        return starts.prefix(4096).enumerated().map { index, start in
            Array(bytes[start.1..<(index + 1 < starts.count ? starts[index + 1].0 : bytes.count)])
        }
    }
}
