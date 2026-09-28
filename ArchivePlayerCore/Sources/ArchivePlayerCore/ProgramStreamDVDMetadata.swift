import Foundation

/// Attributes and coarse VOBU seek points for one explicitly selected DVD program chain.
/// Does not execute DVD navigation or choose a title/angle on the caller's behalf.
public struct ProgramStreamDVDMetadata: Sendable {
    public struct SeekPoint: Sendable, Equatable {
        public let seconds: Int
        public let byteOffset: UInt64
    }
    public let audioTracks: [MediaTrack]
    public let seekPoints: [SeekPoint]

    /// Parses a VTS IFO, using its PGC audio controls to map logical attribute slots
    /// to physical PES IDs. VMG and unavailable PGCs are rejected, never guessed.
    public init(ifo data: Data, programChain: Int = 1) throws {
        let b = Array(data)
        func require(_ at: Int, _ count: Int) throws {
            guard at >= 0, count >= 0, at <= b.count, count <= b.count - at else { throw DemuxError.truncated }
        }
        func u16(_ at: Int) throws -> Int {
            try require(at, 2); return Int(b[at]) << 8 | Int(b[at+1])
        }
        func u32(_ at: Int) throws -> Int {
            try require(at, 4)
            return Int(b[at]) << 24 | Int(b[at+1]) << 16 | Int(b[at+2]) << 8 | Int(b[at+3])
        }
        try require(0, 0x204)
        guard String(bytes: b.prefix(12), encoding: .ascii) == "DVDVIDEO-VTS" else {
            throw DemuxError.invalidFormat("Expected a DVD title-set IFO")
        }
        let count = try u16(0x202)
        guard count <= 8 else { throw DemuxError.invalidFormat("Too many DVD audio attributes") }
        try require(0x204, count * 8)
        let table = try u32(0xCC) * 2048
        guard table > 0, programChain > 0 else { throw DemuxError.unsupported("IFO has no selected program chain") }
        let chains = try u16(table)
        guard programChain <= chains else { throw DemuxError.outOfBounds }
        let tableEnd = table + (try u32(table + 4)) + 1
        try require(table, tableEnd - table)
        let entry = table + 8 + (programChain - 1) * 8
        guard entry + 8 <= tableEnd else { throw DemuxError.truncated }
        let pgc = table + (try u32(entry + 4))
        guard pgc >= table + 8 + chains * 8, pgc + 0xEC <= tableEnd else { throw DemuxError.invalidFormat("Invalid PGC offset") }
        var tracks = [MediaTrack]()
        for index in 0..<count {
            let at = 0x204 + index * 8
            let control = b[pgc + 0xC + index * 2]
            guard control & 0x80 != 0 else { continue }
            let stream = UInt32(control & 7)
            let codec: String
            let id: UInt32
            switch b[at] >> 5 {
            case 0: codec = "ac3"; id = 0xBD80 + stream
            case 2, 3: codec = "mp2"; id = 0xC0 + stream
            case 4: codec = "pcm_dvd"; id = 0xBDA0 + stream
            case 6: codec = "dts"; id = 0xBD88 + stream
            default: continue // Preserve supported entries without inventing unknown codecs.
            }
            let languageBytes = Array(b[(at + 2)...(at + 3)])
            let language = (b[at] >> 2) & 3 == 1 && languageBytes.allSatisfy({ (97...122).contains($0) })
                ? String(bytes: languageBytes, encoding: .ascii) : nil
            var roles = Set<TrackRole>()
            if b[at + 5] == 2 { roles.insert(.visualImpaired) }
            if b[at + 5] == 3 || b[at + 5] == 4 { roles.insert(.commentary) }
            guard !tracks.contains(where: { $0.id == id }) else { throw DemuxError.invalidFormat("Duplicate IFO physical audio mapping") }
            tracks.append(MediaTrack(id: id, kind: .audio, codec: codec, language: language,
                                     roles: roles, channels: Int(b[at + 1] & 7) + 1))
        }
        audioTracks = tracks
        var points = [SeekPoint]()
        let timeTable = try u32(0xD4) * 2048
        if timeTable > 0 {
            let timeChains = try u16(timeTable)
            let end = timeTable + (try u32(timeTable + 4)) + 1
            try require(timeTable, end - timeTable)
            if programChain <= timeChains {
                let pointer = timeTable + 8 + (programChain - 1) * 4
                guard pointer + 4 <= end else { throw DemuxError.truncated }
                let map = timeTable + (try u32(pointer))
                guard map >= timeTable + 8 + timeChains * 4, map + 4 <= end else { throw DemuxError.invalidFormat("Invalid IFO time map") }
                let unit = Int(b[map])
                let entries = try u16(map + 2)
                guard map + 4 + entries * 4 <= end else { throw DemuxError.truncated }
                if unit > 0 {
                    var previous: UInt64 = 0
                    for index in 0..<entries {
                        let sector = try u32(map + 4 + index * 4)
                        // A discontinuity or backwards sector requires DVD navigation semantics.
                        guard sector & 0x80000000 == 0 else { points.removeAll(); break }
                        let offset = UInt64(sector) * 2048
                        guard offset >= previous else { points.removeAll(); break }
                        previous = offset
                        points.append(SeekPoint(seconds: (index + 1) * unit, byteOffset: offset))
                    }
                }
            }
        }
        seekPoints = points
    }
}
