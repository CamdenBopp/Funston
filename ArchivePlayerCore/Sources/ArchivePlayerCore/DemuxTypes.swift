import Foundation
import CoreMedia

public enum MediaKind: String, Sendable, Equatable {
    case video, audio, subtitle
}

public enum TrackRole: String, Sendable, Hashable {
    case original, commentary, visualImpaired, hearingImpaired, forced
}

public struct MediaTrack: Sendable, Equatable {
    public var id: UInt32
    public var kind: MediaKind
    public var codec: String
    public var language: String?
    public var name: String?
    public var roles: Set<TrackRole>
    public var channels: Int?
    public var codecPrivate: Data?

    public init(id: UInt32, kind: MediaKind, codec: String, language: String? = nil,
                name: String? = nil, roles: Set<TrackRole> = [], channels: Int? = nil,
                codecPrivate: Data? = nil) {
        self.id = id
        self.kind = kind
        self.codec = codec
        self.language = language
        self.name = name
        self.roles = roles
        self.channels = channels
        self.codecPrivate = codecPrivate
    }
}

public struct DemuxedPacket: Sendable {
    public var trackID: UInt32
    public var data: Data
    public var pts: CMTime
    public var dts: CMTime
    public var duration: CMTime
    public var isKeyframe: Bool

    public init(trackID: UInt32, data: Data, pts: CMTime, dts: CMTime = .invalid,
                duration: CMTime = .invalid, isKeyframe: Bool = false) {
        self.trackID = trackID
        self.data = data
        self.pts = pts
        self.dts = dts
        self.duration = duration
        self.isKeyframe = isKeyframe
    }
}

public enum DemuxError: Error, Sendable, Equatable {
    case truncated
    case invalidFormat(String)
    case unsupported(String)
    case seekUnavailable
    case resourceChanged
    case outOfBounds
}

public protocol ByteSource: Sendable {
    var length: UInt64? { get async throws }
    func read(offset: UInt64, length: Int) async throws -> Data
}

public protocol Demuxer: Sendable {
    func tracks() async throws -> [MediaTrack]
    func seek(to time: CMTime) async throws
    func nextPacket() async throws -> DemuxedPacket?
}
