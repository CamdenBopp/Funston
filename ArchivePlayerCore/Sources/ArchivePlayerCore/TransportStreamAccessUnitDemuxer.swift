import Foundation
import CoreMedia

/// Strict TS playback subset: AUD-delimited H.264 access units (including cross-PES
/// continuation) and AAC-LC ADTS frames. Unsupported framing fails explicitly.
public actor TransportStreamAccessUnitDemuxer: Demuxer {
    private let raw: TransportStreamDemuxer
    private var mediaTracks: [UInt32: MediaTrack] = [:]
    private var queue: [DemuxedPacket] = []
    private var pendingVideo: [UInt32: DemuxedPacket] = [:]
    private var sps: [UInt32: [UInt8]] = [:]
    private var pps: [UInt32: [UInt8]] = [:]
    private var audioBytes: [UInt32: [UInt8]] = [:]
    private var audioTime: [UInt32: CMTime] = [:]
    private var loaded = false
    private var ended = false
    private var videoBytes: [UInt32: [UInt8]] = [:]
    private var videoMarkers: [UInt32: [(offset: Int, pts: CMTime, dts: CMTime)]] = [:]
    private let maximumBufferedBytes: Int

    public init(source: any ByteSource, maximumBufferedBytes: Int = 16 * 1024 * 1024) {
        raw = TransportStreamDemuxer(source: source)
        self.maximumBufferedBytes = max(1, min(maximumBufferedBytes, 64 * 1024 * 1024))
    }

    public func tracks() async throws -> [MediaTrack] {
        if !loaded {
            for track in try await raw.tracks() where track.codec == "h264" || track.codec == "aac" {
                mediaTracks[track.id] = track
            }
            guard !mediaTracks.isEmpty else { throw DemuxError.unsupported("TS adapter requires AVC or AAC ADTS") }
            for _ in 0..<512 {
                if mediaTracks.values.allSatisfy({ $0.codecPrivate != nil }) { loaded = true; break }
                guard try await consumeNext() else { break }
                guard queue.reduce(0, { $0 + $1.data.count }) <= 8 * 1024 * 1024 else {
                    throw DemuxError.unsupported("TS configuration discovery exceeded 8 MiB")
                }
            }
            guard loaded else { throw DemuxError.unsupported("TS parameter sets or ADTS configuration missing") }
        }
        return mediaTracks.values.sorted { $0.id < $1.id }
    }

    public func seek(to time: CMTime) async throws { throw DemuxError.seekUnavailable }

    public func nextPacket() async throws -> DemuxedPacket? {
        _ = try await tracks()
        while queue.isEmpty { if try await !consumeNext() { return nil } }
        return queue.removeFirst()
    }

    private func consumeNext() async throws -> Bool {
        guard !ended else { return false }
        guard let packet = try await raw.nextPacket() else {
            ended = true
            guard audioBytes.values.allSatisfy(\.isEmpty) else { throw DemuxError.truncated }
            for id in videoBytes.keys.sorted() {
                if let bytes = videoBytes[id], !bytes.isEmpty {
                    guard let mark = videoMarkers[id]?.last(where: { $0.offset <= 0 }) else {
                        throw DemuxError.invalidFormat("AVC AU timestamp missing")
                    }
                    try video(DemuxedPacket(trackID: id, data: Data(bytes), pts: mark.pts, dts: mark.dts))
                }
            }
            queue.append(contentsOf: pendingVideo.values.sorted { $0.trackID < $1.trackID })
            pendingVideo = [:]
            videoBytes = [:]; videoMarkers = [:]
            try checkBufferLimit()
            return !queue.isEmpty
        }
        guard let track = mediaTracks[packet.trackID] else { return true }
        try checkBufferLimit(adding: packet.data.count)
        if track.codec == "h264" { try assembleVideo(packet) }
        else { try audio(packet) }
        try checkBufferLimit()
        return true
    }

    private func checkBufferLimit(adding incoming: Int = 0) throws {
        var total = incoming + queue.reduce(0, { $0 + $1.data.count })
        total += pendingVideo.values.reduce(0, { $0 + $1.data.count })
        total += videoBytes.values.reduce(0, { $0 + $1.count })
        total += audioBytes.values.reduce(0, { $0 + $1.count })
        total += sps.values.reduce(0, { $0 + $1.count }) + pps.values.reduce(0, { $0 + $1.count })
        total += mediaTracks.values.reduce(0, { $0 + ($1.codecPrivate?.count ?? 0) })
        total += videoMarkers.values.reduce(0, { $0 + $1.count * 40 })
        guard total <= maximumBufferedBytes else { throw DemuxError.unsupported("TS access-unit aggregate buffer limit") }
    }

    private func assembleVideo(_ packet: DemuxedPacket) throws {
        let id = packet.trackID
        var bytes = videoBytes[id, default: []]
        var marks = videoMarkers[id, default: []]
        if packet.pts.isNumeric { marks.append((bytes.count, packet.pts, packet.dts)) }
        bytes.append(contentsOf: packet.data)
        guard bytes.count <= 8 * 1024 * 1024, marks.count <= 4096 else { throw DemuxError.unsupported("AVC assembly limit") }
        var delimiters: [Int] = []
        var i = 0
        while i + 4 <= bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                var n = 0
                if bytes[i + 2] == 1 { n = 3 }
                else if i + 5 <= bytes.count && bytes[i + 2] == 0 && bytes[i + 3] == 1 { n = 4 }
                if n > 0 {
                    if bytes[i + n] & 31 == 9 { delimiters.append(i) }
                    i += n + 1; continue
                }
            }
            i += 1
        }
        guard delimiters.count <= 256 else { throw DemuxError.unsupported("Too many AVC access units in PES") }
        if delimiters.count >= 2 {
            for index in 0..<(delimiters.count - 1) {
                let start = delimiters[index], end = delimiters[index + 1]
                guard let markerIndex = marks.lastIndex(where: { $0.offset <= start }) else {
                    throw DemuxError.invalidFormat("AVC AU timestamp missing")
                }
                let mark = marks[markerIndex]
                // A PES timestamp belongs to one AU beginning at or after that
                // PES offset. Consume it; rebasing carry must never resurrect it
                // as a timestamp for the next AUD region.
                marks.removeFirst(markerIndex + 1)
                try video(DemuxedPacket(trackID: id, data: Data(bytes[start..<end]), pts: mark.pts, dts: mark.dts))
            }
            let consumed = delimiters.last!
            let anchor = marks.last(where: { $0.offset <= consumed })
            marks = marks.filter { $0.offset > consumed }.map { ($0.offset - consumed, $0.pts, $0.dts) }
            if let anchor { marks.insert((0, anchor.pts, anchor.dts), at: 0) }
            bytes.removeFirst(consumed)
        }
        videoBytes[id] = bytes; videoMarkers[id] = marks
    }

    private func video(_ packet: DemuxedPacket) throws {
        let b = Array(packet.data)
        guard b.count >= 4, b[0] == 0, b[1] == 0, b[2] == 1 || (b[2] == 0 && b[3] == 1) else {
            throw DemuxError.unsupported("AVC NAL spans PES boundary: \(Array(b.prefix(12))) pts=\(packet.pts.seconds) size=\(b.count)")
        }
        let units = TransportStreamDemuxer.annexBNALUnits(b)
        guard units.count < 4096 else { throw DemuxError.unsupported("Too many AVC NAL units") }
        var firstSlices = 0
        var hasSlice = false
        var data = Data()
        var keyframe = false
        for nal in units {
            guard let first = nal.first, first & 0x80 == 0 else { throw DemuxError.invalidFormat("AVC NAL header") }
            let type = first & 31
            if type == 7 { sps[packet.trackID] = nal }
            if type == 8 { pps[packet.trackID] = nal }
            if type == 1 || type == 5 {
                guard nal.count > 1 else { throw DemuxError.truncated }
                hasSlice = true
                // first_mb_in_slice is unsigned Exp-Golomb; code '1' means zero.
                if nal[1] & 0x80 != 0 { firstSlices += 1 }
                if type == 5 { keyframe = true }
            }
            let n = UInt32(nal.count)
            data.append(contentsOf: [UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)])
            data.append(contentsOf: nal)
        }
        if let s = sps[packet.trackID], let p = pps[packet.trackID] {
            guard s.count >= 4, s.count <= 65535, p.count <= 65535 else { throw DemuxError.invalidFormat("AVC parameter set length") }
            var config: [UInt8] = [1, s[1], s[2], s[3], 0xff, 0xe1, UInt8(s.count >> 8), UInt8(s.count & 255)]
            config += s; config += [1, UInt8(p.count >> 8), UInt8(p.count & 255)]; config += p
            if let old = mediaTracks[packet.trackID]?.codecPrivate, old != Data(config) {
                throw DemuxError.unsupported("Midstream AVC configuration change")
            }
            mediaTracks[packet.trackID]?.codecPrivate = Data(config)
        }
        guard hasSlice else { return }
        guard firstSlices == 1 else { throw DemuxError.unsupported("AVC PES is not exactly one complete access unit") }
        if let previous = pendingVideo[packet.trackID] { queue.append(previous) }
        pendingVideo[packet.trackID] = DemuxedPacket(trackID: packet.trackID, data: data, pts: packet.pts,
                                                    dts: packet.dts, duration: .invalid, isKeyframe: keyframe)
    }

    private func audio(_ packet: DemuxedPacket) throws {
        let id = packet.trackID
        if audioBytes[id, default: []].isEmpty, packet.pts.isNumeric { audioTime[id] = packet.pts }
        audioBytes[id, default: []].append(contentsOf: packet.data)
        guard audioBytes[id]!.count <= 1024 * 1024 else { throw DemuxError.unsupported("ADTS carry exceeded 1 MiB") }
        let rates: [Int32] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        var b = audioBytes[id]!
        while b.count >= 7 {
            guard b[0] == 255, b[1] & 0xf6 == 0xf0 else { throw DemuxError.invalidFormat("ADTS sync/header") }
            let object = (b[2] >> 6) + 1, rateIndex = Int((b[2] >> 2) & 15)
            let channels = Int(b[2] & 1) << 2 | Int(b[3] >> 6)
            guard object == 2, rateIndex < rates.count, channels > 0, b[6] & 3 == 0 else {
                throw DemuxError.unsupported("ADTS requires AAC-LC with one raw block and explicit channels")
            }
            let header = b[1] & 1 == 1 ? 7 : 9
            let length = Int(b[3] & 3) << 11 | Int(b[4]) << 3 | Int(b[5] >> 5)
            guard length > header else { throw DemuxError.invalidFormat("ADTS frame length") }
            guard b.count >= length else { break }
            let config = Data([object << 3 | UInt8(rateIndex >> 1), UInt8((rateIndex & 1) << 7 | channels << 3)])
            if let old = mediaTracks[id]?.codecPrivate, old != config { throw DemuxError.unsupported("Midstream AAC configuration change") }
            mediaTracks[id]?.codecPrivate = config; mediaTracks[id]?.channels = channels
            let duration = CMTime(value: 1024, timescale: rates[rateIndex])
            let pts = audioTime[id] ?? .invalid
            queue.append(DemuxedPacket(trackID: id, data: Data(b[header..<length]), pts: pts, duration: duration, isKeyframe: true))
            audioTime[id] = CMTimeAdd(pts, duration)
            b.removeFirst(length)
        }
        audioBytes[id] = b
    }
}
