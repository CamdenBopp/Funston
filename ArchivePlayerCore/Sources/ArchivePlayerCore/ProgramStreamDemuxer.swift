import Foundation
import CoreMedia
import AudioToolbox

/// Incremental MPEG-1/2 program-stream PES demultiplexer. Packets are PES fragments,
/// not decoded samples or complete codec access units. Callers must serialize operations.
public actor ProgramStreamDemuxer: Demuxer {
    private let source: any ByteSource
    private var buffer = [UInt8]()
    private var cursor = 0
    private var offset: UInt64 = 0
    private var eof = false
    private var ended = false
    private var mpeg1 = false
    private var discovered = [UInt32: MediaTrack]()
    private var pending = [DemuxedPacket]()
    private var pendingAudioOffsets = [Int?]()
    /// For the most recently returned PES: byte offset of its first timestamped
    /// audio access unit in `data`, after removing the DVD private-stream header.
    public private(set) var firstAudioAccessUnitOffset: Int?
    private var clocks = [UInt32: Int64]()
    private let probeBytes: UInt64
    private let dvdMetadata: ProgramStreamDVDMetadata?

    public init(source: any ByteSource, probeBytes: UInt64 = 2 * 1024 * 1024,
                dvdMetadata: ProgramStreamDVDMetadata? = nil) {
        self.source = source
        self.probeBytes = min(probeBytes, 16 * 1024 * 1024)
        self.dvdMetadata = dvdMetadata
    }

    /// Bounded discovery; later packets can expose additional tracks. Does not lose probe packets.
    public func tracks() async throws -> [MediaTrack] {
        if discovered.isEmpty {
            while offset < probeBytes && !ended {
                if let packet = try await parseNext(scanLimit: probeBytes) {
                    pending.append(packet); pendingAudioOffsets.append(firstAudioAccessUnitOffset)
                }
            }
        }
        return discovered.values.sorted { $0.id < $1.id }
    }

    public func nextPacket() async throws -> DemuxedPacket? {
        if !pending.isEmpty {
            firstAudioAccessUnitOffset = pendingAudioOffsets.removeFirst()
            return pending.removeFirst()
        }
        return try await parseNext()
    }

    /// Coarse seek to the preceding IFO time-map VOBU. Decoder preroll is required.
    /// Rejects requests beyond the verified map or sources with unknown length.
    public func seek(to time: CMTime) async throws {
        guard time.isNumeric, time.seconds >= 0 else { throw DemuxError.seekUnavailable }
        var target: UInt64 = 0
        if time.value != 0 {
            guard let points = dvdMetadata?.seekPoints, let last = points.last,
                  time.seconds <= Double(last.seconds),
                  let point = points.last(where: { Double($0.seconds) <= time.seconds }),
                  let length = try await source.length, point.byteOffset < length else { throw DemuxError.seekUnavailable }
            target = point.byteOffset
            // Validate the indexed boundary before changing parser state.
            var prefix = Data()
            while prefix.count < 4 {
                let bytes = try await source.read(offset: target + UInt64(prefix.count), length: 4 - prefix.count)
                guard !bytes.isEmpty, bytes.count <= 4 - prefix.count else { throw DemuxError.truncated }
                prefix.append(bytes)
            }
            guard prefix == Data([0, 0, 1, 0xBA]) else { throw DemuxError.invalidFormat("IFO time map does not point to a pack") }
        }
        buffer.removeAll(); cursor = 0; offset = target; eof = false; ended = false; mpeg1 = false
        pending.removeAll(); pendingAudioOffsets.removeAll(); firstAudioAccessUnitOffset = nil; clocks.removeAll()
    }

    private func ensure(_ count: Int) async throws -> Bool {
        while buffer.count - cursor < count && !eof {
            try Task.checkCancellation()
            if cursor > 0 { buffer.removeFirst(cursor); cursor = 0 }
            let wanted = max(4096, count - buffer.count)
            let request: Int
            if let total = try await source.length {
                guard offset <= total else { throw DemuxError.outOfBounds }
                if offset == total { eof = true; break }
                request = Int(min(UInt64(wanted), total - offset))
            } else {
                request = wanted
            }
            let bytes = try await source.read(offset: offset, length: request)
            guard bytes.count <= request else { throw DemuxError.invalidFormat("Byte source exceeded requested length") }
            if bytes.isEmpty { eof = true; break }
            let (next, overflow) = offset.addingReportingOverflow(UInt64(bytes.count))
            guard !overflow else { throw DemuxError.outOfBounds }
            offset = next
            buffer.append(contentsOf: bytes)
        }
        return buffer.count - cursor >= count
    }

    private func take(_ count: Int) async throws -> [UInt8] {
        guard try await ensure(count) else { throw DemuxError.truncated }
        let result = Array(buffer[cursor..<(cursor + count)])
        cursor += count
        return result
    }

    private func parseNext(scanLimit: UInt64? = nil) async throws -> DemuxedPacket? {
        while !ended {
            if let scanLimit, offset >= scanLimit { return nil }
            guard try await ensure(4) else {
                guard buffer.count == cursor else { throw DemuxError.truncated }
                ended = true; return nil
            }
            let prefix = try await take(4)
            guard prefix[0...2].elementsEqual([0, 0, 1]) else {
                throw DemuxError.invalidFormat("Missing program-stream start code")
            }
            let stream = prefix[3]
            if stream == 0xB9 { ended = true; return nil }
            if stream == 0xBA {
                let first = try await take(1)[0]
                if first & 0xC0 == 0x40 {
                    mpeg1 = false
                    let rest = try await take(9)
                    guard first & 4 != 0, rest[1] & 4 != 0, rest[3] & 4 != 0,
                          rest[4] & 1 != 0, rest[7] & 3 == 3 else {
                        throw DemuxError.invalidFormat("Invalid MPEG-2 pack markers")
                    }
                    let stuffing = try await take(Int(rest[8] & 7))
                    guard stuffing.allSatisfy({ $0 == 0xFF }) else { throw DemuxError.invalidFormat("Invalid pack stuffing") }
                } else if first & 0xF0 == 0x20 {
                    mpeg1 = true
                    let rest = try await take(7)
                    guard first & 1 != 0, rest[1] & 1 != 0, rest[3] & 1 != 0,
                          rest[4] & 0x80 != 0, rest[6] & 1 != 0 else {
                        throw DemuxError.invalidFormat("Invalid MPEG-1 pack markers")
                    }
                } else { throw DemuxError.invalidFormat("Unknown pack header") }
                continue
            }
            guard stream >= 0xBB else { throw DemuxError.invalidFormat("Unexpected elementary start code outside PES") }
            let size = try await take(2)
            let length = Int(size[0]) << 8 | Int(size[1])
            guard length != 0 else { throw DemuxError.unsupported("Unbounded PES in program stream") }
            let body = try await take(length)
            // System headers, padding, NAV/private_stream_2 and program maps have no media payload here.
            guard stream == 0xBD || (0xC0...0xEF).contains(stream) else { continue }
            let decoded = try decodePES(body)
            var payload = Array(body[decoded.start...])
            var id = UInt32(stream)
            var codec = stream >= 0xE0 ? (mpeg1 ? "mpeg1video" : "mpeg2video") : "mp2"
            var kind: MediaKind = stream >= 0xE0 ? .video : .audio
            var channels: Int?
            var privateData: Data?
            firstAudioAccessUnitOffset = nil
            if stream == 0xBD {
                guard let sub = payload.first else { throw DemuxError.truncated }
                id = 0xBD00 | UInt32(sub)
                let skip: Int
                switch sub {
                case 0x20...0x3F: codec = "dvd_subtitle"; kind = .subtitle; skip = 1
                case 0x80...0x87: codec = "ac3"; skip = 4
                case 0x88...0x8F: codec = "dts"; skip = 4
                case 0xA0...0xA7: codec = "pcm_dvd"; skip = 7
                default: throw DemuxError.unsupported("DVD private substream \(sub)")
                }
                guard payload.count >= skip else { throw DemuxError.truncated }
                if codec == "ac3" || codec == "dts", payload[1] > 0 {
                    let pointer = Int(payload[2]) << 8 | Int(payload[3])
                    guard pointer > 0, pointer - 1 < payload.count - skip else {
                        throw DemuxError.invalidFormat("DVD audio first-access-unit pointer exceeds PES")
                    }
                    firstAudioAccessUnitOffset = pointer - 1
                }
                if codec == "pcm_dvd" {
                    channels = Int(payload[5] & 7) + 1
                    privateData = Data(payload[4...6])
                }
                payload.removeFirst(skip)
            }
            if discovered[id] == nil {
                discovered[id] = MediaTrack(id: id, kind: kind, codec: codec, channels: channels, codecPrivate: privateData)
                if let metadata = dvdMetadata?.audioTracks.first(where: { $0.id == id && $0.codec == codec }) {
                    discovered[id]?.language = metadata.language
                    discovered[id]?.roles = metadata.roles
                    discovered[id]?.channels = channels ?? metadata.channels
                }
            }
            // Share an epoch across PTS/DTS for a track; decode order can differ from presentation order.
            let reference = clocks[id] ?? clocks.values.first
            let pts = decoded.pts.map { unwrap($0, near: reference) }
            let dts = decoded.dts.map { unwrap($0, near: pts ?? reference) }
            if let clock = dts ?? pts { clocks[id] = clock }
            return DemuxedPacket(trackID: id, data: Data(payload),
                pts: pts.map { CMTime(value: $0, timescale: 90_000) } ?? .invalid,
                dts: dts.map { CMTime(value: $0, timescale: 90_000) } ?? .invalid)
        }
        return nil
    }

    private func unwrap(_ raw: Int64, near reference: Int64?) -> Int64 {
        guard let reference else { return raw }
        let modulus: Int64 = 1 << 33
        var value = raw + (reference / modulus) * modulus
        if value - reference > modulus / 2 { value -= modulus }
        if reference - value > modulus / 2 { value += modulus }
        return value
    }

    private func decodePES(_ b: [UInt8]) throws -> (start: Int, pts: Int64?, dts: Int64?) {
        guard !b.isEmpty else { throw DemuxError.truncated }
        var start = 0
        var pts: Int64?
        var dts: Int64?
        if b[0] & 0xC0 == 0x80 {
            guard b.count >= 3 else { throw DemuxError.truncated }
            guard b[0] & 0x30 == 0 else { throw DemuxError.unsupported("Scrambled PES") }
            start = 3 + Int(b[2])
            guard start <= b.count else { throw DemuxError.truncated }
            let flags = b[1] >> 6
            guard flags != 1 else { throw DemuxError.invalidFormat("Forbidden PTS/DTS flags") }
            if flags == 2 || flags == 3 {
                guard Int(b[2]) >= (flags == 3 ? 10 : 5) else { throw DemuxError.truncated }
                pts = try timestamp(b, at: 3, prefix: flags == 3 ? 3 : 2)
                if flags == 3 { dts = try timestamp(b, at: 8, prefix: 1) }
            }
        } else {
            while start < b.count && b[start] == 0xFF { start += 1 }
            guard start < b.count else { throw DemuxError.truncated }
            if b[start] & 0xC0 == 0x40 { start += 2 }
            guard start < b.count else { throw DemuxError.truncated }
            let flags = b[start] >> 4
            if flags == 2 || flags == 3 {
                pts = try timestamp(b, at: start, prefix: flags); start += 5
                if flags == 3 { dts = try timestamp(b, at: start, prefix: 1); start += 5 }
            } else if b[start] == 0x0F { start += 1 }
            else { throw DemuxError.invalidFormat("Invalid MPEG-1 PES header") }
        }
        return (start, pts, dts)
    }

    private func timestamp(_ b: [UInt8], at i: Int, prefix: UInt8) throws -> Int64 {
        guard i + 5 <= b.count else { throw DemuxError.truncated }
        guard b[i] >> 4 == prefix, b[i] & 1 == 1, b[i+2] & 1 == 1, b[i+4] & 1 == 1 else {
            throw DemuxError.invalidFormat("Invalid PES timestamp markers")
        }
        return Int64(b[i] & 14) << 29 | Int64(b[i+1]) << 22 |
            Int64(b[i+2] & 254) << 14 | Int64(b[i+3]) << 7 | Int64(b[i+4] >> 1)
    }
}

/// Concatenates caller-ordered VOB title segments, including reads spanning a boundary.
/// This is byte continuity only: it does not execute DVD navigation, cells, or angles.
public struct ProgramStreamSegmentSource: ByteSource {
    public struct Segment: Sendable {
        public let source: any ByteSource
        public let length: UInt64
        public init(source: any ByteSource, length: UInt64) { self.source = source; self.length = length }
    }
    private let segments: [Segment]
    private let total: UInt64
    public init(segments: [Segment]) throws {
        var sum: UInt64 = 0
        for segment in segments {
            let (next, overflow) = sum.addingReportingOverflow(segment.length)
            guard !overflow else { throw DemuxError.outOfBounds }
            sum = next
        }
        self.segments = segments; total = sum
    }
    public var length: UInt64? { get async throws { total } }
    public func read(offset: UInt64, length: Int) async throws -> Data {
        guard length >= 0, offset <= total else { throw DemuxError.outOfBounds }
        var remaining = min(UInt64(length), total - offset)
        var local = offset
        var result = Data()
        for segment in segments {
            if local >= segment.length { local -= segment.length; continue }
            while remaining > 0 && local < segment.length {
                let wanted = Int(min(remaining, segment.length - local))
                let bytes = try await segment.source.read(offset: local, length: wanted)
                guard !bytes.isEmpty else { throw DemuxError.truncated }
                guard bytes.count <= wanted else { throw DemuxError.invalidFormat("Segment exceeded requested length") }
                result.append(bytes); local += UInt64(bytes.count); remaining -= UInt64(bytes.count)
            }
            if remaining == 0 { break }
            local = 0
        }
        return result
    }
}

/// Bounded DVD MPEG-2 frame-picture / AC-3 access-unit adapter. It deliberately
/// rejects field pictures, pulldown and extended frame rates instead of guessing
/// sample timing. Supply `formatDescriptions()` to SampleBufferPlaybackEngine;
/// this adapter does not change decoder capability on the current Apple platform.
/// As with the underlying demuxer, callers must serialize read/seek operations.
public actor ProgramStreamAccessUnitDemuxer: Demuxer {
    private struct Marker { var offset: Int; let pts: CMTime; let dts: CMTime }
    private struct Stream {
        var bytes = [UInt8]()
        var markers = [Marker]()
        var frameDuration = CMTime.invalid
        var nextAudioPTS = CMTime.invalid
        var gopAnchor = CMTime.invalid
        var previousDTS = CMTime.invalid
        var synchronized = false
    }
    private let pes: ProgramStreamDemuxer
    private let limit: Int
    private var mediaTracks = [MediaTrack]()
    private var streams = [UInt32: Stream]()
    private var formats = [UInt32: CMFormatDescription]()
    private var audioProfiles = [UInt32: UInt8]()
    private var ready = [DemuxedPacket]()
    private var prepared = false
    private var ended = false

    public init(source: any ByteSource, maximumBufferedBytes: Int = 4 * 1024 * 1024,
                dvdMetadata: ProgramStreamDVDMetadata? = nil) {
        pes = ProgramStreamDemuxer(source: source, probeBytes: 128 * 1024, dvdMetadata: dvdMetadata)
        limit = max(4096, min(maximumBufferedBytes, 16 * 1024 * 1024))
    }

    public func tracks() async throws -> [MediaTrack] {
        try await prepare()
        return mediaTracks
    }

    public func formatDescriptions() async throws -> [UInt32: CMFormatDescription] {
        try await prepare()
        return formats
    }

    private func prepare() async throws {
        guard !prepared else { return }
        mediaTracks = try await pes.tracks().filter { $0.codec == "mpeg2video" || $0.codec == "ac3" }
        guard !mediaTracks.isEmpty else { throw DemuxError.unsupported("No supported MPEG-2/AC-3 tracks") }
        var consumed = 0
        var packets = 0
        while formats.count < mediaTracks.count && !ended {
            consumed += try await pump()
            packets += 1
            guard consumed <= limit, packets <= 4096 else { throw DemuxError.unsupported("Program-stream format probe exceeded limit") }
        }
        guard formats.count == mediaTracks.count else { throw DemuxError.truncated }
        prepared = true
    }

    public func nextPacket() async throws -> DemuxedPacket? {
        try await prepare()
        var consumed = 0, packets = 0
        while ready.isEmpty && !ended {
            consumed += try await pump(); packets += 1
            guard consumed <= limit, packets <= 4096 else { throw DemuxError.unsupported("Access-unit scan exceeded limit") }
        }
        return ready.isEmpty ? nil : ready.removeFirst()
    }

    public func seek(to time: CMTime) async throws {
        try await pes.seek(to: time)
        streams.removeAll(); ready.removeAll(); ended = false
    }

    @discardableResult private func pump() async throws -> Int {
        guard let packet = try await pes.nextPacket() else {
            ended = true
            for track in mediaTracks {
                var state = streams[track.id] ?? Stream()
                if track.kind == .video { try extractVideo(&state, id: track.id, final: true) }
                else if !state.bytes.isEmpty { throw DemuxError.truncated }
                streams[track.id] = state
            }
            return 0
        }
        guard let track = mediaTracks.first(where: { $0.id == packet.trackID }) else { return packet.data.count }
        var state = streams[track.id] ?? Stream()
        var bytes = Array(packet.data)
        var pointer = await pes.firstAudioAccessUnitOffset
        if track.kind == .audio && !state.synchronized {
            guard let first = pointer else { return bytes.count }
            bytes.removeFirst(first); pointer = 0; state.synchronized = true
        }
        if packet.pts.isNumeric, track.kind == .video || pointer != nil {
            state.markers.append(Marker(offset: state.bytes.count + (pointer ?? 0), pts: packet.pts, dts: packet.dts))
        }
        guard state.bytes.count + bytes.count <= limit else { throw DemuxError.unsupported("Access unit exceeds byte limit") }
        state.bytes.append(contentsOf: bytes)
        if track.kind == .video { try extractVideo(&state, id: track.id, final: false) }
        else { try extractAC3(&state, id: track.id) }
        streams[track.id] = state
        let buffered = streams.values.reduce(0) { $0 + $1.bytes.count } + ready.reduce(0) { $0 + $1.data.count }
        guard buffered <= limit else { throw DemuxError.unsupported("Aggregate access-unit buffer exceeded limit") }
        return packet.data.count
    }

    private func consume(_ count: Int, state: inout Stream) {
        state.bytes.removeFirst(count)
        state.markers = state.markers.compactMap { marker in
            guard marker.offset >= count else { return nil }
            return Marker(offset: marker.offset - count, pts: marker.pts, dts: marker.dts)
        }
    }

    private func extractAC3(_ state: inout Stream, id: UInt32) throws {
        let rates: [Int32] = [48000, 44100, 32000]
        let bitrates = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640]
        while state.bytes.count >= 7 {
            let b = state.bytes
            guard b[0] == 0x0B, b[1] == 0x77 else { throw DemuxError.invalidFormat("AC-3 syncword missing") }
            let rateCode = Int(b[4] >> 6), sizeCode = Int(b[4] & 63)
            guard rateCode < 3, sizeCode < 38, b[5] >> 3 <= 8 else { throw DemuxError.unsupported("AC-3 header/profile") }
            let bitrate = bitrates[sizeCode / 2]
            let size = rateCode == 0 ? bitrate * 4 : rateCode == 2 ? bitrate * 6 : 2 * (320 * bitrate / 147 + sizeCode % 2)
            guard b.count >= size else { return }
            let mode = Int(b[6] >> 5)
            var lfeBit = 51
            if mode & 1 != 0 && mode != 1 { lfeBit += 2 }
            if mode & 4 != 0 { lfeBit += 2 }
            if mode == 2 { lfeBit += 2 }
            let lfe = Int((b[lfeBit / 8] >> (7 - lfeBit % 8)) & 1)
            let channels = [2, 1, 2, 3, 3, 4, 4, 5][mode] + lfe
            if let format = formats[id], let existing = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
                guard existing.pointee.mSampleRate == Double(rates[rateCode]),
                      existing.pointee.mChannelsPerFrame == UInt32(channels), audioProfiles[id] == b[5] >> 3 else {
                    throw DemuxError.unsupported("AC-3 format changed during playback")
                }
            }
            if formats[id] == nil {
                var asbd = AudioStreamBasicDescription(mSampleRate: Double(rates[rateCode]), mFormatID: kAudioFormatAC3,
                    mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1536, mBytesPerFrame: 0,
                    mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
                var format: CMAudioFormatDescription?
                let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                    layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
                guard status == noErr, let format else { throw DemuxError.unsupported("AC-3 format description: \(status)") }
                formats[id] = format
                audioProfiles[id] = b[5] >> 3
                if let i = mediaTracks.firstIndex(where: { $0.id == id }) { mediaTracks[i].channels = channels }
            }
            if let marker = state.markers.last(where: { $0.offset == 0 }) { state.nextAudioPTS = marker.pts }
            guard state.nextAudioPTS.isNumeric else { throw DemuxError.unsupported("AC-3 frame has no timestamp anchor") }
            let duration = CMTime(value: 1536, timescale: rates[rateCode])
            ready.append(DemuxedPacket(trackID: id, data: Data(b.prefix(size)), pts: state.nextAudioPTS, duration: duration, isKeyframe: true))
            state.nextAudioPTS = CMTimeAdd(state.nextAudioPTS, duration)
            consume(size, state: &state)
        }
    }

    private func extractVideo(_ state: inout Stream, id: UInt32, final: Bool) throws {
        while true {
            let b = state.bytes
            guard b.count >= 4 else {
                if final && !b.isEmpty { throw DemuxError.truncated }
                return
            }
            var codes = [(Int, UInt8)]()
            for i in 0..<(b.count - 3) where b[i] == 0 && b[i+1] == 0 && b[i+2] == 1 { codes.append((i, b[i+3])) }
            guard let picture = codes.first(where: { $0.1 == 0 })?.0 else {
                if final { throw DemuxError.truncated }
                return
            }
            let boundary = codes.first { $0.0 > picture && ($0.1 == 0 || $0.1 == 0xB3 || $0.1 == 0xB8) }?.0
            guard let end = boundary ?? (final ? b.count : nil) else { return }
            guard picture + 6 <= end else { throw DemuxError.truncated }
            for (position, code) in codes where position < end {
                if code == 0xB3 {
                    guard position + 8 <= end else { throw DemuxError.truncated }
                    let durations: [CMTime] = [.invalid, CMTime(value: 1001, timescale: 24000), CMTime(value: 1, timescale: 24), CMTime(value: 1, timescale: 25), CMTime(value: 1001, timescale: 30000), CMTime(value: 1, timescale: 30), CMTime(value: 1, timescale: 50), CMTime(value: 1001, timescale: 60000), CMTime(value: 1, timescale: 60)]
                    let rateCode = Int(b[position + 7] & 15)
                    guard rateCode > 0, rateCode < durations.count else { throw DemuxError.unsupported("MPEG-2 frame rate") }
                    state.frameDuration = durations[rateCode]
                    if formats[id] == nil { formats[id] = try FormatDescriptionFactory.mpeg2Video(sequenceHeader: Data(b.prefix(end))) }
                }
                if code == 0xB8 { state.gopAnchor = .invalid }
                if code == 0xB5 {
                    guard position + 5 <= end else { throw DemuxError.truncated }
                    if b[position + 4] >> 4 == 8 {
                        guard position + 8 <= end else { throw DemuxError.truncated }
                        guard b[position+6] & 3 == 3, b[position+7] & 2 == 0 else {
                            throw DemuxError.unsupported("MPEG-2 field pictures/pulldown require timing adapter")
                        }
                    } else if b[position + 4] >> 4 == 1 {
                        guard position + 10 <= end else { throw DemuxError.truncated }
                        guard b[position+9] & 127 == 0 else { throw DemuxError.unsupported("MPEG-2 extended frame rate") }
                    }
                }
            }
            guard state.frameDuration.isNumeric, formats[id] != nil else { throw DemuxError.unsupported("MPEG-2 sequence header required before pictures") }
            let temporal = Int32(Int(b[picture+4]) << 2 | Int(b[picture+5] >> 6))
            let type = (b[picture+5] >> 3) & 7
            guard (1...3).contains(type) else { throw DemuxError.unsupported("MPEG-2 picture type") }
            let marker = state.markers.last { $0.offset <= picture }
            let temporalOffset = CMTimeMultiply(state.frameDuration, multiplier: temporal)
            if let marker { state.gopAnchor = CMTimeSubtract(marker.pts, temporalOffset) }
            guard state.gopAnchor.isNumeric else { throw DemuxError.unsupported("MPEG-2 GOP has no timestamp anchor") }
            let pts = marker?.pts ?? CMTimeAdd(state.gopAnchor, temporalOffset)
            let dts: CMTime
            if let marker, marker.dts.isNumeric { dts = marker.dts }
            else if state.previousDTS.isNumeric { dts = CMTimeAdd(state.previousDTS, state.frameDuration) }
            else { dts = .invalid }
            state.previousDTS = dts
            ready.append(DemuxedPacket(trackID: id, data: Data(b.prefix(end)), pts: pts, dts: dts,
                duration: state.frameDuration, isKeyframe: type == 1))
            state.bytes.removeFirst(end)
            state.markers = state.markers.filter { $0.offset > picture }.map {
                Marker(offset: max(0, $0.offset - end), pts: $0.pts, dts: $0.dts)
            }
        }
    }
}
