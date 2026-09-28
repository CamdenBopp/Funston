import Foundation
import CoreMedia

/// Bounded, pull-based Matroska/WebM reader. Codec bytes are returned without decoding.
public actor MatroskaDemuxer: Demuxer {
    private struct Element { let id: UInt64; let start: UInt64; let end: UInt64? }
    private let source: any ByteSource
    private let maximumPayload: Int
    private var position: UInt64 = 0
    private var segmentEnd: UInt64?
    private var clusterEnd: UInt64?
    private var inCluster = false
    private var clusterTime: Int64 = 0
    private var scale: Int64 = 1_000_000
    private var loaded = false
    private var mediaTracks: [MediaTrack] = []
    private var defaults: [UInt32: Int64] = [:]
    private var codecDelays: [UInt32: Int64] = [:]
    private var pending: [DemuxedPacket] = []
    private var firstCluster: UInt64?
    private var segmentStart: UInt64 = 0
    private var seekPoints: [(nanoseconds: Int64, offset: UInt64)] = []
    private var builtSeekIndex = false

    public init(source: any ByteSource, maximumPayload: Int = 32 * 1024 * 1024) {
        self.source = source
        self.maximumPayload = max(1, maximumPayload)
    }

    private func read(_ offset: UInt64, _ count: Int) async throws -> Data {
        guard count >= 0, count <= maximumPayload else { throw DemuxError.unsupported("Matroska payload exceeds configured limit") }
        var result = Data()
        while result.count < count {
            let (next, overflow) = offset.addingReportingOverflow(UInt64(result.count))
            guard !overflow else { throw DemuxError.outOfBounds }
            try Task.checkCancellation()
            let part = try await source.read(offset: next, length: min(8 * 1024 * 1024, count - result.count))
            guard !part.isEmpty, part.count <= count - result.count else { throw DemuxError.truncated }
            result.append(part)
        }
        return result
    }

    private func header(_ offset: UInt64, limit: UInt64?) async throws -> Element? {
        if let limit, offset >= limit { return nil }
        let first = try await source.read(offset: offset, length: 1)
        if first.isEmpty {
            if limit != nil { throw DemuxError.truncated }
            return nil
        }
        let idLength = try Self.width(first[0], maximum: 4)
        let idBytes = try await read(offset, idLength)
        let id = Self.uint(idBytes)
        let sizeOffset = try Self.add(offset, UInt64(idLength))
        let sizeFirst = try await read(sizeOffset, 1)
        let sizeLength = try Self.width(sizeFirst[0], maximum: 8)
        let sizeBytes = try await read(sizeOffset, sizeLength)
        var cursor = 0
        let (size, _) = try Self.vint(Array(sizeBytes), &cursor)
        let start = try Self.add(sizeOffset, UInt64(sizeLength))
        let unknown = size == (UInt64(1) << (7 * sizeLength)) - 1
        let end = unknown ? nil : try Self.add(start, size)
        if let limit, start > limit || (end.map { $0 > limit } ?? false) { throw DemuxError.outOfBounds }
        return Element(id: id, start: start, end: end)
    }

    private static func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw DemuxError.outOfBounds }; return value
    }
    private static func width(_ byte: UInt8, maximum: Int) throws -> Int {
        guard byte != 0 else { throw DemuxError.invalidFormat("Zero EBML VINT") }
        let length = byte.leadingZeroBitCount + 1
        guard length <= maximum else { throw DemuxError.invalidFormat("EBML VINT width") }; return length
    }
    private static func uint(_ data: Data) -> UInt64 { data.reduce(0) { ($0 << 8) | UInt64($1) } }
    private static func vint(_ bytes: [UInt8], _ cursor: inout Int) throws -> (UInt64, Int) {
        guard cursor < bytes.count else { throw DemuxError.truncated }
        let width = try width(bytes[cursor], maximum: 8)
        guard width <= bytes.count - cursor else { throw DemuxError.truncated }
        var value = UInt64(bytes[cursor] & (0xff >> width))
        for i in 1..<width { value = value << 8 | UInt64(bytes[cursor + i]) }
        cursor += width; return (value, width)
    }
    private func payload(_ e: Element) async throws -> Data {
        guard let end = e.end else { throw DemuxError.unsupported("Unknown size on non-master element") }
        guard end - e.start <= UInt64(maximumPayload) else { throw DemuxError.unsupported("Matroska payload exceeds configured limit") }
        return try await read(e.start, Int(end - e.start))
    }
    private func number(_ e: Element) async throws -> UInt64 {
        guard let end = e.end, end - e.start <= 8 else { throw DemuxError.invalidFormat("Invalid EBML integer size") }
        return Self.uint(try await payload(e))
    }
    private func children(_ e: Element) async throws -> [Element] {
        guard let end = e.end else { throw DemuxError.unsupported("Unknown size metadata") }
        var cursor = e.start; var result: [Element] = []
        while cursor < end {
            guard result.count < 100_000 else { throw DemuxError.unsupported("Excessive metadata elements") }
            guard let child = try await header(cursor, limit: end), let next = child.end else { throw DemuxError.invalidFormat("Unknown size metadata child") }
            result.append(child); cursor = next
        }
        return result
    }

    private func metadata(_ e: Element) async throws {
        if e.id == 0x1549a966 {
            for c in try await children(e) where c.id == 0x2ad7b1 {
                let value = try await number(c)
                guard value > 0, value <= UInt64(Int64.max) else { throw DemuxError.invalidFormat("TimestampScale") }
                scale = Int64(value)
            }
        } else if e.id == 0x1654ae6b {
            for entry in try await children(e) where entry.id == 0xae {
                var id: UInt32 = 0; var type: UInt64 = 0; var codec = ""
                var language: String? = "eng"; var name: String?; var privateData: Data?; var channels: Int?
                var duration: Int64?; var delay: Int64 = 0; var roles: Set<TrackRole> = []
                for c in try await children(entry) {
                    switch c.id {
                    case 0xd7:
                        let value = try await number(c)
                        guard value > 0, value <= UInt32.max else { throw DemuxError.unsupported("TrackNumber outside UInt32") }; id = UInt32(value)
                    case 0x83: type = try await number(c)
                    case 0x86: codec = String(decoding: try await payload(c), as: UTF8.self)
                    case 0x22b59c, 0x22b59d: language = String(decoding: try await payload(c), as: UTF8.self)
                    case 0x536e: name = String(decoding: try await payload(c), as: UTF8.self)
                    case 0x63a2: privateData = try await payload(c)
                    case 0x23e383:
                        let value = try await number(c)
                        guard value <= Int64.max else { throw DemuxError.outOfBounds }; duration = Int64(value)
                    case 0x55aa: if try await number(c) != 0 { roles.insert(.forced) }
                    case 0x55af: if try await number(c) != 0 { roles.insert(.commentary) }
                    case 0x55ab: if try await number(c) != 0 { roles.insert(.hearingImpaired) }
                    case 0x55ac: if try await number(c) != 0 { roles.insert(.visualImpaired) }
                    case 0xe1:
                        channels = 1
                        for a in try await children(c) where a.id == 0x9f {
                            let value = try await number(a)
                            guard value <= Int.max else { throw DemuxError.outOfBounds }; channels = Int(value)
                        }
                    case 0x6d80: throw DemuxError.unsupported("Matroska ContentEncodings")
                    case 0x56aa:
                        let value = try await number(c)
                        guard value <= Int64.max else { throw DemuxError.outOfBounds }; delay = Int64(value)
                    case 0x23314f: throw DemuxError.unsupported("TrackTimestampScale")
                    default: break
                    }
                }
                guard id != 0, !codec.isEmpty, !mediaTracks.contains(where: { $0.id == id }) else { throw DemuxError.invalidFormat("Invalid or duplicate track") }
                let kind: MediaKind
                switch type { case 1: kind = .video; case 2: kind = .audio; case 17: kind = .subtitle; default: throw DemuxError.unsupported("Matroska track type \(type)") }
                mediaTracks.append(MediaTrack(id: id, kind: kind, codec: codec, language: language, name: name, roles: roles, channels: channels, codecPrivate: privateData))
                defaults[id] = duration
                codecDelays[id] = delay
            }
        }
    }

    private func load() async throws {
        if loaded { return }
        let length = try await source.length
        guard let ebml = try await header(0, limit: length), ebml.id == 0x1a45dfa3, let end = ebml.end else { throw DemuxError.invalidFormat("Missing EBML header") }
        var docType = ""
        for c in try await children(ebml) {
            if c.id == 0x4282 { docType = String(decoding: try await payload(c), as: UTF8.self) }
            if c.id == 0x4285, try await number(c) > 4 { throw DemuxError.unsupported("Matroska read version") }
        }
        guard docType == "matroska" || docType == "webm" else { throw DemuxError.invalidFormat("Not Matroska or WebM") }
        guard let segment = try await header(end, limit: length), segment.id == 0x18538067 else { throw DemuxError.invalidFormat("Missing Segment") }
        segmentEnd = segment.end ?? length; segmentStart = segment.start; position = segment.start
        while let e = try await header(position, limit: segmentEnd) {
            if e.id == 0x1f43b675 { firstCluster = position; break }
            try await metadata(e)
            guard let end = e.end else { throw DemuxError.unsupported("Unknown size segment child") }; position = end
        }
        guard !mediaTracks.isEmpty else { throw DemuxError.unsupported("Tracks must precede first Cluster") }
        loaded = true
    }
    public func tracks() async throws -> [MediaTrack] { try await load(); return mediaTracks }
    public func seek(to time: CMTime) async throws {
        try await load()
        guard time.isNumeric, time.seconds >= 0, let first = firstCluster else { throw DemuxError.seekUnavailable }
        var start = first
        if time.seconds > 0 {
            try await buildSeekIndex()
            let target = CMTimeConvertScale(time, timescale: 1_000_000_000, method: .roundTowardZero).value
            if let point = seekPoints.last(where: { $0.nanoseconds <= target }) { start = point.offset }
        }
        guard let selected = try await header(start, limit: segmentEnd), selected.id == 0x1f43b675 else { throw DemuxError.invalidFormat("Cue does not address a Cluster") }
        position = start; inCluster = false; pending = []; clusterTime = 0
    }

    /// A header-only scan reaches trailing Cues by skipping finite Clusters. Without Cues,
    /// Cluster timestamps form a coarse index. Work is bounded to 100,000 element headers.
    private func buildSeekIndex() async throws {
        if builtSeekIndex { return }
        var cursor = segmentStart
        var sparse: [(nanoseconds: Int64, offset: UInt64)] = []
        var cues: [(nanoseconds: Int64, offset: UInt64)] = []
        var budget = 100_000
        var unknownCluster = false
        var followedSeekHead = false
        var retriedWithoutCues = false
        let preferredTrack = mediaTracks.first(where: { $0.kind == .video })?.id ?? mediaTracks.first?.id
        while cursor < (segmentEnd ?? UInt64.max) {
            try Task.checkCancellation()
            budget -= 1
            guard budget >= 0 else { throw DemuxError.unsupported("Matroska seek index scan limit") }
            guard let e = try await header(cursor, limit: segmentEnd) else { break }
            if e.id == 0x114d9b74, !followedSeekHead {
                var cueOffset: UInt64?
                for entry in try await children(e) where entry.id == 0x4dbb {
                    var targetID: UInt64?; var relative: UInt64?
                    for field in try await children(entry) {
                        if field.id == 0x53ab { targetID = try await number(field) }
                        if field.id == 0x53ac { relative = try await number(field) }
                    }
                    if targetID == 0x1c53bb6b, let relative { cueOffset = try Self.add(segmentStart, relative) }
                }
                if let cueOffset {
                    guard cueOffset < (segmentEnd ?? UInt64.max),
                          let target = try await header(cueOffset, limit: segmentEnd), target.id == 0x1c53bb6b else { throw DemuxError.invalidFormat("SeekHead Cues target") }
                    followedSeekHead = true; cursor = cueOffset; continue
                }
            }
            if e.id == 0x1f43b675 {
                var childOffset = e.start
                while let c = try await header(childOffset, limit: e.end ?? segmentEnd) {
                    budget -= 1
                    guard budget >= 0 else { throw DemuxError.unsupported("Matroska seek index scan limit") }
                    if c.id == 0xe7 {
                        let ticks = try await number(c)
                        guard ticks <= UInt64(Int64.max) else { throw DemuxError.outOfBounds }
                        let (ns, overflow) = Int64(ticks).multipliedReportingOverflow(by: scale)
                        guard !overflow else { throw DemuxError.outOfBounds }
                        sparse.append((ns, cursor)); break
                    }
                    if c.id == 0xa3 || c.id == 0xa0 || c.id == 0x1f43b675 { break }
                    guard let end = c.end else { throw DemuxError.unsupported("Unknown Cluster child") }; childOffset = end
                }
                unknownCluster = e.end == nil
                cursor = e.end ?? e.start
                continue
            }
            if e.id == 0x1c53bb6b {
                unknownCluster = false
                for point in try await children(e) where point.id == 0xbb {
                    var ticks: UInt64?; var positions: [(UInt64, UInt64)] = []
                    for field in try await children(point) {
                        if field.id == 0xb3 { ticks = try await number(field) }
                        if field.id == 0xb7 {
                            var track: UInt64?; var offset: UInt64?
                            for value in try await children(field) {
                                if value.id == 0xf7 { track = try await number(value) }
                                if value.id == 0xf1 { offset = try await number(value) }
                            }
                            if let track, let offset { positions.append((track, offset)) }
                        }
                    }
                    if let ticks, let point = positions.first(where: { $0.0 == UInt64(preferredTrack ?? 0) }) {
                        guard ticks <= UInt64(Int64.max) else { throw DemuxError.outOfBounds }
                        let (ns, overflow) = Int64(ticks).multipliedReportingOverflow(by: scale)
                        guard !overflow else { throw DemuxError.outOfBounds }
                        let absolute = try Self.add(segmentStart, point.1)
                        guard absolute >= segmentStart, absolute < (segmentEnd ?? UInt64.max) else { throw DemuxError.outOfBounds }
                        cues.append((ns, absolute))
                    }
                }
                if !cues.isEmpty { break }
                if followedSeekHead, sparse.isEmpty, !retriedWithoutCues {
                    retriedWithoutCues = true; cursor = segmentStart; continue
                }
            }
            guard let end = e.end else { throw DemuxError.unsupported(unknownCluster ? "Unknown Cluster child" : "Unknown Segment child") }
            cursor = end
        }
        let chosen = cues.isEmpty ? sparse : cues
        guard !chosen.isEmpty else { throw DemuxError.seekUnavailable }
        seekPoints = chosen.sorted { $0.nanoseconds < $1.nanoseconds }
        builtSeekIndex = true
        // Validate the selected offset again when seeking; malformed Cues must never be
        // interpreted as arbitrary block bytes or escape the Segment.
    }
    public func nextPacket() async throws -> DemuxedPacket? {
        try await load()
        if !pending.isEmpty { return pending.removeFirst() }
        while let e = try await header(position, limit: segmentEnd) {
            if inCluster, let end = clusterEnd, position >= end { inCluster = false }
            if e.id == 0x1f43b675 {
                inCluster = true; clusterEnd = e.end; clusterTime = 0; position = e.start; continue
            }
            // Segment-level elements also terminate an unknown-size Cluster.
            if [UInt64(0x1549a966), 0x1654ae6b, 0x1c53bb6b, 0x114d9b74, 0x1254c367, 0x1941a469, 0x1043a770].contains(e.id) { inCluster = false }
            guard let end = e.end else { throw DemuxError.unsupported("Unknown size element") }
            if inCluster, let bound = clusterEnd, end > bound { throw DemuxError.outOfBounds }
            position = end
            if inCluster {
                switch e.id {
                case 0xe7:
                    let value = try await number(e); guard value <= Int64.max else { throw DemuxError.outOfBounds }; clusterTime = Int64(value)
                case 0xa3: pending = try packets(try await payload(e), keyframe: nil, duration: nil)
                case 0xa0:
                    var block: Data?; var reference = false; var duration: UInt64?
                    for c in try await children(e) {
                        switch c.id {
                        case 0xa1: guard block == nil else { throw DemuxError.invalidFormat("Multiple Blocks") }; block = try await payload(c)
                        case 0xfb: reference = true
                        case 0x9b: duration = try await number(c)
                        case 0x75a2: throw DemuxError.unsupported("DiscardPadding")
                        default: break
                        }
                    }
                    guard let block else { throw DemuxError.invalidFormat("BlockGroup missing Block") }
                    pending = try packets(block, keyframe: !reference, duration: duration)
                default: break
                }
            }
            if !pending.isEmpty { return pending.removeFirst() }
        }
        return nil
    }

    private func packets(_ data: Data, keyframe: Bool?, duration: UInt64?) throws -> [DemuxedPacket] {
        let bytes = Array(data); var p = 0
        let (track, _) = try Self.vint(bytes, &p)
        guard track <= UInt32.max, mediaTracks.contains(where: { $0.id == UInt32(track) }) else { throw DemuxError.invalidFormat("Unknown block track") }
        guard bytes.count - p >= 3 else { throw DemuxError.truncated }
        let relative = Int64(Int16(bitPattern: UInt16(bytes[p]) << 8 | UInt16(bytes[p + 1])))
        let flags = bytes[p + 2]; p += 3
        let lace = (flags >> 1) & 3
        var sizes: [Int] = []
        if lace != 0 {
            guard p < bytes.count else { throw DemuxError.truncated }
            let count = Int(bytes[p]) + 1; p += 1
            guard count > 1 else { throw DemuxError.invalidFormat("Single-frame lacing") }
            if lace == 2 {
                guard (bytes.count - p) % count == 0 else { throw DemuxError.invalidFormat("Unequal fixed lace sizes") }
                sizes = Array(repeating: (bytes.count - p) / count, count: count)
            } else {
                for index in 0..<(count - 1) {
                    var size = 0
                    if lace == 1 {
                        var byte: UInt8
                        repeat {
                            guard p < bytes.count else { throw DemuxError.truncated }; byte = bytes[p]; p += 1; size += Int(byte)
                        } while byte == 255
                    } else {
                        let (value, width) = try Self.vint(bytes, &p)
                        if index == 0 { size = Int(value) }
                        else {
                            let delta = Int64(value) - Int64((UInt64(1) << (7 * width - 1)) - 1)
                            let (sum, overflow) = Int64(sizes[index - 1]).addingReportingOverflow(delta)
                            guard !overflow, sum >= 0, sum <= bytes.count else { throw DemuxError.invalidFormat("Invalid EBML lace delta") }; size = Int(sum)
                        }
                    }
                    guard size <= bytes.count else { throw DemuxError.invalidFormat("Oversize lace") }; sizes.append(size)
                }
                let remaining = bytes.count - p - sizes.reduce(0, +)
                guard remaining >= 0 else { throw DemuxError.invalidFormat("Lace exceeds block") }; sizes.append(remaining)
            }
        } else { sizes = [bytes.count - p] }
        let (ticks, sumOverflow) = clusterTime.addingReportingOverflow(relative)
        let (timestamp, mulOverflow) = ticks.multipliedReportingOverflow(by: scale)
        guard !sumOverflow, !mulOverflow else { throw DemuxError.outOfBounds }
        var frameDuration = defaults[UInt32(track)]
        if let duration {
            guard duration <= UInt64(Int64.max) else { throw DemuxError.outOfBounds }
            let (total, overflow) = Int64(duration).multipliedReportingOverflow(by: scale)
            guard !overflow else { throw DemuxError.outOfBounds }; frameDuration = total / Int64(sizes.count)
        }
        if sizes.count > 1, frameDuration == nil { throw DemuxError.unsupported("Laced timing requires DefaultDuration or BlockDuration") }
        let (adjusted, delayOverflow) = timestamp.subtractingReportingOverflow(codecDelays[UInt32(track)] ?? 0)
        guard !delayOverflow else { throw DemuxError.outOfBounds }
        var pts = adjusted; var result: [DemuxedPacket] = []
        for size in sizes {
            let packet = DemuxedPacket(trackID: UInt32(track), data: Data(bytes[p..<(p + size)]), pts: CMTime(value: pts, timescale: 1_000_000_000), duration: frameDuration.map { CMTime(value: $0, timescale: 1_000_000_000) } ?? .invalid, isKeyframe: keyframe ?? (flags & 0x80 != 0))
            result.append(packet); p += size
            let (next, overflow) = pts.addingReportingOverflow(frameDuration ?? 0)
            guard !overflow else { throw DemuxError.outOfBounds }; pts = next
        }
        return result
    }
}
