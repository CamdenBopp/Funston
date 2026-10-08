import Foundation

enum MediaDuration {
    // Leave headroom for CMTime's 600-unit timescale and integer clock formatting.
    static let maximumSeconds = Double(Int64.max / 1_000)
    static func validated(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= maximumSeconds else { return nil }
        return value
    }
}

enum MediaType: String, Codable, CaseIterable, Hashable, Sendable {
    case all, audio, movies, texts, image, software, collection, unknown

    var title: String {
        switch self {
        case .all: "All"
        case .audio: "Audio"
        case .movies: "Movies"
        case .texts: "Texts"
        case .image: "Images"
        case .software: "Software"
        case .collection: "Collections"
        case .unknown: "Other"
        }
    }
}

struct ArtifactSummary: Identifiable, Codable, Hashable, Sendable {
    let identifier: String
    let title: String
    let creators: [String]
    let date: String?
    let mediaType: MediaType
    let collections: [String]
    let artworkFileName: String?
    let accessRestricted: Bool?
    var isAccessRestricted: Bool { accessRestricted == true || collections.contains("access-restricted-item") }
    var id: String { identifier }
    var artworkURL: URL {
        artworkFileName.map { ArchiveURLs.download(identifier: identifier, fileName: $0) } ?? ArchiveURLs.thumbnail(identifier: identifier)
    }

    init(identifier: String, title: String, creators: [String] = [], date: String? = nil,
         mediaType: MediaType = .unknown, collections: [String] = [], artworkFileName: String? = nil, accessRestricted: Bool? = nil) {
        self.identifier = identifier
        self.title = title
        self.creators = creators
        self.date = date
        self.mediaType = mediaType
        self.collections = collections
        self.artworkFileName = artworkFileName
        self.accessRestricted = accessRestricted
    }

    func resolvingArtwork(files: [ArchiveFile]) -> ArtifactSummary {
        ArtifactSummary(identifier: identifier, title: title, creators: creators, date: date,
                        mediaType: mediaType, collections: collections,
                        artworkFileName: ArtifactArtworkResolver.fileName(identifier: identifier, files: files), accessRestricted: accessRestricted)
    }
}

enum ArtifactAccess: String, Codable, Hashable, Sendable {
    case available, restricted, unresolved
}

struct ArchiveFile: Identifiable, Codable, Hashable, Sendable {
    let name: String
    let format: String?
    let source: String?
    let original: String?
    let size: Int64?
    let duration: Double?
    let trackNumber: Int?
    let discNumber: Int?
    let isPrivate: Bool
    var id: String { name }

    init(name: String, format: String? = nil, source: String? = nil, original: String? = nil,
         size: Int64? = nil, duration: Double? = nil, trackNumber: Int? = nil,
         discNumber: Int? = nil, isPrivate: Bool = false) {
        self.name = name; self.format = format; self.source = source; self.original = original
        self.size = size; self.duration = MediaDuration.validated(duration); self.trackNumber = trackNumber
        self.discNumber = discNumber; self.isPrivate = isPrivate
    }
}

struct PlayableTrack: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let candidates: [ArchiveFile]
    let duration: Double?
    var preferredFile: ArchiveFile? { candidates.first }

    init(id: String, title: String, candidates: [ArchiveFile], duration: Double? = nil) {
        self.id = id; self.title = title; self.candidates = candidates; self.duration = MediaDuration.validated(duration)
    }
}

struct ArtifactDetail: Codable, Hashable, Sendable {
    let summary: ArtifactSummary
    let description: String?
    let files: [ArchiveFile]
    let tracks: [PlayableTrack]
    let access: ArtifactAccess
    let metadata: [String: [String]]

    init(summary: ArtifactSummary, description: String? = nil, files: [ArchiveFile] = [],
         tracks: [PlayableTrack] = [], access: ArtifactAccess = .available,
         metadata: [String: [String]] = [:]) {
        self.summary = summary; self.description = description; self.files = files
        self.tracks = tracks; self.access = access; self.metadata = metadata
    }

    /// Old cached snapshots have all files but predate the optional cover field.
    func resolvingArtwork() -> ArtifactDetail {
        ArtifactDetail(summary: summary.resolvingArtwork(files: files), description: description,
                       files: files, tracks: tracks, access: access, metadata: metadata)
    }
}

struct SearchRequest: Codable, Hashable, Sendable {
    let text: String
    let scope: MediaType
    let page: Int
    let pageSize: Int
    let collection: String?

    init(text: String = "", scope: MediaType = .all, page: Int = 1, pageSize: Int = 40,
         collection: String? = nil) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scope = scope; self.page = max(1, page)
        self.pageSize = min(100, max(1, pageSize)); self.collection = collection
    }
    var cacheKey: String {
        // Length prefixes prevent user input from colliding with separators.
        [text, scope.rawValue, collection ?? "", String(page), String(pageSize)]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }
}

struct SearchPage: Codable, Hashable, Sendable {
    let items: [ArtifactSummary]
    let total: Int
    let page: Int
    let pageSize: Int
    var hasMore: Bool { page <= Int.max / pageSize && page * pageSize < total }
}

struct ArchiveCollection: Identifiable, Codable, Hashable, Sendable {
    let identifier: String
    let title: String
    var id: String { identifier }
    static let curated: [ArchiveCollection] = [
        .init(identifier: "oldtimeradio", title: "Old Time Radio"),
        .init(identifier: "texts", title: "Books & Texts"),
        .init(identifier: "prelinger", title: "Prelinger Archives"),
        .init(identifier: "etree", title: "Live Music Archive")
    ]
}

enum ArchiveError: Error, Sendable, Equatable {
    case invalidResponse
    case http(status: Int, retryAfter: String?)
    case missingItem
    case malformedData

    var userMessage: String {
        switch self {
        case .http(429, _): "Internet Archive is limiting requests right now. Try again shortly."
        case .http(401, _), .http(403, _): "This item is not available for public access."
        case .http(404, _), .missingItem: "This item is no longer available at Internet Archive."
        case .http: "Internet Archive could not complete this request. Try again."
        case .invalidResponse, .malformedData: "Internet Archive returned information that could not be read. Try again."
        }
    }
}

/// Preserve names and numbers while removing path, extension and filename separators.
enum ArchiveMediaTitle {
    static func readable(_ filename: String) -> String {
        let stem = ((filename as NSString).lastPathComponent as NSString).deletingPathExtension
        let words = stem.replacingOccurrences(of: "[_.-]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(?<=[a-z])(?=[A-Z])", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? filename : words
    }
}
