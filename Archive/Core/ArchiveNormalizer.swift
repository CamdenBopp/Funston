import Foundation

actor ArchiveNormalizer {
    func search(data: Data, request: SearchRequest) throws -> SearchPage {
        try Task.checkCancellation()
        let dto = try JSONDecoder().decode(ArchiveSearchDTO.self, from: data)
        try Task.checkCancellation()
        var seen = Set<String>()
        let items = dto.documents.compactMap(Self.summary).filter { seen.insert($0.identifier).inserted }
        return SearchPage(items: items, total: dto.total, page: request.page, pageSize: request.pageSize)
    }

    func detail(data: Data, identifier: String) throws -> ArtifactDetail {
        try Task.checkCancellation()
        let dto = try JSONDecoder().decode(ArchiveMetadataDTO.self, from: data)
        try Task.checkCancellation()
        guard !dto.metadata.isEmpty else { throw ArchiveError.missingItem }
        let summary = Self.summary(dto.metadata) ?? ArtifactSummary(identifier: identifier, title: dto.metadata.text("title") ?? identifier)
        let access = Self.access(metadata: dto.metadata, envelope: dto.envelope)
        var seen = Set<String>()
        let files = dto.files.compactMap(Self.file).filter { seen.insert($0.name).inserted }
            .sorted { Self.naturalLess($0.name, $1.name) }
        let rawByName = Dictionary(dto.files.compactMap { fields in fields.text("name").map { ($0, fields) } }, uniquingKeysWith: { first, _ in first })
        try Task.checkCancellation()
        let tracks = access == .available ? Self.tracks(files: files, rawByName: rawByName) : []
        return ArtifactDetail(summary: summary.resolvingArtwork(files: files), description: Self.cleanDescription(dto.metadata.texts("description").joined(separator: "\n\n")),
                              files: files, tracks: tracks, access: access, metadata: dto.metadata.mapValues(\.strings))
    }

    private static func summary(_ fields: ArchiveFields) -> ArtifactSummary? {
        guard let identifier = fields.text("identifier"), !identifier.isEmpty else { return nil }
        var seenCollections = Set<String>()
        return ArtifactSummary(identifier: identifier, title: fields.text("title") ?? identifier,
                               creators: fields.texts("creator"), date: fields.text("date") ?? fields.text("year"),
                               mediaType: fields.text("mediatype") == "etree" ? .audio : MediaType(rawValue: fields.text("mediatype") ?? "") ?? .unknown,
                               collections: fields.texts("collection").filter { seenCollections.insert($0).inserted })
    }

    private static func flag(_ text: String?) -> Bool? {
        guard let text else { return nil }
        switch text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "true", "1", "yes": return true
        case "false", "0", "no", "": return false
        default: return nil
        }
    }

    private static func access(metadata: ArchiveFields, envelope: ArchiveFields) -> ArtifactAccess {
        var unresolved = false
        for key in ["is_dark", "is_restricted", "access-restricted-item"] {
            for fields in [metadata, envelope] where fields[key] != nil {
                if flag(fields.text(key)) == true { return .restricted }
                if flag(fields.text(key)) == nil { unresolved = true }
            }
        }
        return unresolved ? .unresolved : .available
    }

    private static func positiveNumber(_ value: String?) -> Int? {
        guard let first = value?.split(separator: "/").first,
              let number = Int(first.trimmingCharacters(in: .whitespaces)), number > 0 else { return nil }
        return number
    }

    private static func duration(_ text: String?) -> Double? {
        guard let text else { return nil }
        let parts = text.split(separator: ":")
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var result = 0.0
        for part in parts {
            guard let value = Double(part), value.isFinite, value >= 0 else { return nil }
            result = result * 60 + value
        }
        return MediaDuration.validated(result)
    }

    private static func file(_ fields: ArchiveFields) -> ArchiveFile? {
        guard let name = fields.text("name"), !name.isEmpty else { return nil }
        let size = fields.text("size").flatMap(Int64.init).flatMap { $0 >= 0 ? $0 : nil }
        return ArchiveFile(name: name, format: fields.text("format"), source: fields.text("source"),
                           original: fields.text("original"), size: size, duration: duration(fields.text("length")),
                           trackNumber: positiveNumber(fields.text("track")), discNumber: positiveNumber(fields.text("disc")),
                           isPrivate: fields["private"] != nil && flag(fields.text("private")) != false)
    }

    private static func rank(_ file: ArchiveFile) -> Int? {
        guard !file.isPrivate else { return nil }
        let ext = (file.name as NSString).pathExtension.lowercased()
        let format = file.format?.lowercased() ?? ""
        guard ["mp3", "m4a", "aac", "wav", "aiff", "aif"].contains(ext) else { return nil }
        guard !format.contains("metadata"), !format.contains("spectrogram") else { return nil }
        if format.contains("64kb") || format.contains("64k mp3") || format.contains("32kb") { return 3 }
        if ext == "mp3" || ext == "m4a" { return 0 }
        return file.source == "original" ? 1 : 2
    }

    private static func tracks(files: [ArchiveFile], rawByName: [String: ArchiveFields]) -> [PlayableTrack] {
        let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0) })
        var groups: [String: [ArchiveFile]] = [:]
        for file in files where rank(file) != nil {
            // Only trust explicit exact original relationships; never guess from stems.
            let key = file.original ?? file.name
            groups[key, default: []].append(file)
        }
        let ordered = groups.map { key, candidates -> (String, ArchiveFile, [ArchiveFile]) in
            let sorted = candidates.sorted {
                let a = rank($0) ?? Int.max, b = rank($1) ?? Int.max
                return a == b ? naturalLess($0.name, $1.name) : a < b
            }
            return (key, byName[key] ?? sorted[0], sorted)
        }.sorted { lhs, rhs in
            let a = lhs.1, b = rhs.1
            if a.discNumber != b.discNumber { return (a.discNumber ?? Int.max) < (b.discNumber ?? Int.max) }
            if a.trackNumber != b.trackNumber { return (a.trackNumber ?? Int.max) < (b.trackNumber ?? Int.max) }
            return naturalLess(lhs.0, rhs.0)
        }
        return ordered.map { key, original, candidates in
            let title = rawByName[key]?.text("title") ?? rawByName[candidates[0].name]?.text("title") ?? (key as NSString).lastPathComponent
            return PlayableTrack(id: key, title: title, candidates: candidates,
                                 duration: original.duration ?? candidates.first(where: { $0.duration != nil })?.duration)
        }
    }

    /// Fixed locale and an exact scalar tie-breaker give stable order across device locales.
    static func naturalLess(_ lhs: String, _ rhs: String) -> Bool {
        let comparison = lhs.compare(rhs, options: [.numeric, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return comparison == .orderedSame ? lhs.utf8.lexicographicallyPrecedes(rhs.utf8) : comparison == .orderedAscending
    }

    private static func cleanDescription(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        var result = text.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1>", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?i)<(?:br\\s*/?|/p|/div|/li)>", with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        for (entity, replacement) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

/// Selects only explicit, bounded cover assets; arbitrary images may be scans or audio analysis.
enum ArtifactArtworkResolver {
    static func fileName(identifier: String, files: [ArchiveFile]) -> String? {
        var bestRank = Int.max
        var best: String?
        var ambiguous = false
        let expectedStem = identifier.lowercased()
        for file in files {
            guard !file.isPrivate, let size = file.size, size > 0, size <= 8 * 1_024 * 1_024 else { continue }
            let name = file.name.lowercased()
            let format = file.format?.lowercased() ?? ""
            guard !name.contains("thumb"), !name.contains("spectrogram"), !format.contains("thumbnail"), !format.contains("spectrogram"),
                  ["jpg", "jpeg", "png"].contains((name as NSString).pathExtension) else { continue }
            let stem = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
            let rank: Int
            if format == "item image" { rank = 0 }
            else if stem == expectedStem { rank = 1 }
            else if stem == "cover" || stem == "folder" { rank = 2 }
            else { continue }
            if rank < bestRank { bestRank = rank; best = file.name; ambiguous = false }
            else if rank == bestRank, best != file.name { ambiguous = true }
        }
        return ambiguous ? nil : best
    }
}
