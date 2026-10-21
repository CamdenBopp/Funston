import Foundation

/// Where a reference inside the container points.
struct EPUBReference: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        /// A container entry, found (`entry` set) or missing.
        case internalResource
        /// `http`, `https`, `mailto`, `tel`: never fetched without consent.
        case external
        /// `data:` content, allowed for images only.
        case data
        /// `file:`, `javascript:` and every other scheme.
        case refused
    }

    let kind: Kind
    /// The normalised container-root-relative path the reference names, when internal.
    let path: String?
    /// The archive entry name that satisfied the lookup, when one did.
    let entry: String?
    let fragment: String?
    /// The reference as written.
    let original: String

    var exists: Bool { entry != nil }
}

/// URL resolution over the container root (EPUB 3.3 section 4.2.5): leading
/// slashes and excess `..` clamp to the root, the fragment is kept aside, the
/// query dropped, and the entry lookup falls back through NFC, NFD, case and
/// separator differences, each with a diagnostic.
enum EPUBHref {
    static let externalSchemes: Set<String> = ["http", "https", "mailto", "tel"]
    static let metaInfPrefix = "META-INF/"

    static func scheme(of reference: String) -> String? {
        guard let colon = reference.firstIndex(of: ":") else { return nil }
        let candidate = reference[..<colon]
        guard let first = candidate.first, first.isLetter else { return nil }
        guard candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) else { return nil }
        return candidate.lowercased()
    }

    /// Splits `path#fragment` keeping the fragment verbatim.
    static func splitFragment(_ reference: String) -> (String, String?) {
        guard let hash = reference.firstIndex(of: "#") else { return (reference, nil) }
        return (String(reference[..<hash]), String(reference[reference.index(after: hash)...]))
    }

    /// Resolves `reference` found in the document at `base` (a container
    /// path; the root is the empty string).
    static func resolve(_ reference: String, from base: String, in zip: EPUBZipReader?, diagnostics: inout EPUBDiagnosticList) -> EPUBReference {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = scheme(of: trimmed) {
            if scheme == "data" { return EPUBReference(kind: .data, path: nil, entry: nil, fragment: nil, original: reference) }
            if externalSchemes.contains(scheme) {
                diagnostics.record(.package, "resource.remote", path: reference, "A remote reference is not fetched.")
                return EPUBReference(kind: .external, path: nil, entry: nil, fragment: nil, original: reference)
            }
            diagnostics.record(.package, "resource.forbiddenScheme", path: reference, "References with the \(scheme) scheme are refused.")
            return EPUBReference(kind: .refused, path: nil, entry: nil, fragment: nil, original: reference)
        }
        var (rest, fragment) = splitFragment(trimmed)
        if let question = rest.firstIndex(of: "?") {
            rest = String(rest[..<question])
            diagnostics.record(.package, "href.queryDropped", path: reference, "A query string has no meaning inside the container and was dropped.")
        }
        if rest.contains(" ") {
            diagnostics.record(.package, "href.rawSpace", path: reference, "The reference contains an unencoded space.")
        }
        let decodedPath = rest.removingPercentEncoding ?? rest
        if decodedPath.isEmpty {
            // A fragment-only reference names the base document itself.
            let entry = zip?.entry(named: base)?.name
            return EPUBReference(kind: .internalResource, path: base, entry: entry, fragment: fragment, original: reference)
        }
        var components: [String]
        if decodedPath.hasPrefix("/") {
            diagnostics.record(.package, "href.pathAbsolute", path: reference, "A root-relative reference began with a slash; it was clamped to the container root.")
            components = []
        } else {
            components = base.split(separator: "/", omittingEmptySubsequences: true).dropLast().map(String.init)
        }
        var leaked = false
        for segment in decodedPath.split(separator: "/", omittingEmptySubsequences: true) {
            switch segment {
            case ".": continue
            case "..": if components.isEmpty { leaked = true } else { components.removeLast() }
            default: components.append(String(segment))
            }
        }
        if leaked {
            diagnostics.record(.package, "href.leakingRelative", path: reference, "The reference climbs above the container root; it was clamped.")
        }
        let path = components.joined(separator: "/")
        let entry = lookup(path, in: zip, reference: reference, diagnostics: &diagnostics)
        if path.hasPrefix(metaInfPrefix), entry != nil {
            diagnostics.record(.package, "href.metaInf", path: reference, "Content references a reserved META-INF file.")
        }
        if entry == nil, zip != nil {
            diagnostics.record(.package, "resource.missing", path: reference, "The referenced resource is not in the archive.")
        }
        return EPUBReference(kind: .internalResource, path: path, entry: entry, fragment: fragment, original: reference)
    }

    /// Exact, then NFC, then NFD, then case-insensitive, then with the path
    /// separators swapped.
    static func lookup(_ path: String, in zip: EPUBZipReader?, reference: String, diagnostics: inout EPUBDiagnosticList) -> String? {
        guard let zip else { return nil }
        // Swift compares strings by canonical equivalence, so an NFC href finds
        // an NFD entry on its own; the bytes decide whether that was a fallback.
        if let exact = zip.entry(named: path) {
            if !exact.name.utf8.elementsEqual(path.utf8) {
                diagnostics.record(.package, "href.normalizationFallback", path: reference, "The entry was found only after Unicode normalisation.")
            }
            return exact.name
        }
        let folded = path.lowercased()
        let foldedNFC = path.precomposedStringWithCanonicalMapping.lowercased()
        let foldedNFD = path.decomposedStringWithCanonicalMapping.lowercased()
        if let hit = zip.entries.first(where: { let name = $0.name.lowercased(); return name == folded || name == foldedNFC || name == foldedNFD }) {
            diagnostics.record(.package, "href.caseFallback", path: reference, "The entry was found only by a case-insensitive match.")
            return hit.name
        }
        let swapped = path.replacingOccurrences(of: "\\", with: "/")
        if swapped != path, let hit = zip.entry(named: swapped) {
            diagnostics.record(.package, "href.backslash", path: reference, "The entry was found only after replacing backslashes.")
            return hit.name
        }
        if let hit = zip.entries.first(where: { $0.name.replacingOccurrences(of: "\\", with: "/") == path }) {
            diagnostics.record(.package, "href.backslash", path: reference, "The entry was found only after replacing backslashes.")
            return hit.name
        }
        return nil
    }

    /// Turns an href that is not a valid URL into one: the fragment is split
    /// first, then the query, and only the path is percent-encoded, so `#` and
    /// `?` keep their meaning (Readium streamer study vectors V-01 to V-03).
    static func repaired(_ href: String) -> String {
        let (beforeFragment, fragment) = splitFragment(href)
        var path = beforeFragment
        var query: String?
        if let question = path.firstIndex(of: "?") {
            query = String(path[path.index(after: question)...])
            path = String(path[..<question])
        }
        var encoded = ""
        let bytes = Array(path.utf8)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "%"), index + 2 < bytes.count, isHex(bytes[index + 1]), isHex(bytes[index + 2]) {
                encoded += String(decoding: bytes[index...index + 2], as: UTF8.self)
                index += 3
                continue
            }
            if isPathAllowed(byte) { encoded.unicodeScalars.append(Unicode.Scalar(byte)) }
            else { encoded += String(format: "%%%02X", byte) }
            index += 1
        }
        if let query { encoded += "?" + query }
        if let fragment { encoded += "#" + fragment }
        return encoded
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }

    /// RFC 3986 pchar plus `/`: unreserved, sub-delims, `:` and `@`.
    private static func isPathAllowed(_ byte: UInt8) -> Bool {
        if (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) { return true }
        return "-._~!$&'()*+,;=:@/".utf8.contains(byte)
    }

    /// The directory of a container path, with a trailing slash, or the root.
    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[...slash])
    }
}

extension EPUBHref {
    /// The bytes of a `data:` URL: base64 when the header says so, else percent-decoded.
    static func dataURLBytes(_ reference: String) -> Data? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("data:"), let comma = trimmed.firstIndex(of: ",") else { return nil }
        let header = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 5)..<comma].lowercased()
        let payload = String(trimmed[trimmed.index(after: comma)...])
        if header.split(separator: ";").contains("base64") {
            return Data(base64Encoded: payload.filter { !$0.isWhitespace }, options: [.ignoreUnknownCharacters])
        }
        return payload.removingPercentEncoding.map { Data($0.utf8) }
    }
}
