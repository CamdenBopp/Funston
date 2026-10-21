import Foundation

/// Settles a content document's encoding before any text pass: BOM, then the
/// XML declaration, then a meta charset in the first kilobyte, then UTF-8;
/// bytes that decode under none of those re-decode as Windows-1252 with a
/// diagnostic. C0 controls other than tab, line feed and carriage return are
/// stripped, because the XML parser aborts on them.
enum EPUBContentDecoder {
    struct Decoded: Sendable {
        let text: String
        let encodingName: String
        let diagnostics: EPUBDiagnosticList
    }

    enum Failure: Error, Equatable { case undecodable }

    static let sniffLength = 1024
    static let fallbackEncodingName = "windows-1252"

    static func decode(_ data: Data, path: String) throws(Failure) -> Decoded {
        var diagnostics = EPUBDiagnosticList()
        var candidates: [(String, String.Encoding)] = []
        if let bom = byteOrderMark(data) {
            candidates.append(bom)
        } else {
            let head = String(decoding: data.prefix(sniffLength), as: UTF8.self)
            if let declared = declaredEncoding(in: head), let encoding = encoding(named: declared) {
                candidates.append((declared.lowercased(), encoding))
            } else if let declared = declaredEncoding(in: head) {
                diagnostics.record(.chapterDecode, "chapter.decode.unknownEncoding", path: path, "The declared encoding \(declared) is not known; UTF-8 is tried.")
            }
            candidates.append(("utf-8", .utf8))
        }
        var decoded: (String, String)?
        for (name, encoding) in candidates {
            if let text = String(data: data, encoding: encoding) { decoded = (text, name); break }
        }
        if decoded == nil {
            if let text = String(data: data, encoding: .windowsCP1252) {
                decoded = (text, fallbackEncodingName)
                diagnostics.record(.chapterDecode, "chapter.decode.fallback", path: path, "The bytes were not valid \(candidates.first?.0 ?? "UTF-8"); they were decoded as Windows-1252.")
            }
        }
        guard var (text, name) = decoded else { throw .undecodable }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = declaringUTF8(text)
        var stripped = 0
        if text.unicodeScalars.contains(where: isForbiddenControl) {
            var scalars = String.UnicodeScalarView()
            for scalar in text.unicodeScalars {
                if isForbiddenControl(scalar) { stripped += 1 } else { scalars.append(scalar) }
            }
            text = String(scalars)
            diagnostics.record(EPUBDiagnostic(stage: .chapterDecode, code: "chapter.decode.controlsStripped", path: path, message: "Control characters were removed before parsing.", count: stripped))
        }
        return Decoded(text: text, encodingName: name, diagnostics: diagnostics)
    }

    /// The decoded text is handed on as UTF-8, so an XML declaration naming
    /// another encoding would make the parser decode it wrongly.
    static func declaringUTF8(_ text: String) -> String {
        guard text.hasPrefix("<?xml") || text.hasPrefix("\n<?xml") || text.hasPrefix(" <?xml") else { return text }
        guard let regex = try? NSRegularExpression(pattern: "^(\\s*<\\?xml[^>]*?)\\s+encoding\\s*=\\s*[\"'][^\"']*[\"']", options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1 encoding=\"UTF-8\"")
    }

    private static func isForbiddenControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r"
    }

    static func byteOrderMark(_ data: Data) -> (String, String.Encoding)? {
        let bytes = Array(data.prefix(3))
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { return ("utf-8", .utf8) }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE { return ("utf-16le", .utf16LittleEndian) }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF { return ("utf-16be", .utf16BigEndian) }
        return nil
    }

    /// The XML declaration's encoding, else a meta charset or http-equiv charset.
    static func declaredEncoding(in head: String) -> String? {
        if let match = firstMatch("<\\?xml[^>]*?encoding\\s*=\\s*[\"']([A-Za-z0-9._-]+)[\"']", in: head) { return match }
        if let match = firstMatch("<meta[^>]*?charset\\s*=\\s*[\"']?\\s*([A-Za-z0-9._-]+)", in: head) { return match }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func encoding(named name: String) -> String.Encoding? {
        switch name.lowercased() {
        case "utf-8", "utf8": return .utf8
        case "utf-16", "utf16": return .utf16
        case "utf-16le": return .utf16LittleEndian
        case "utf-16be": return .utf16BigEndian
        case "iso-8859-1", "iso8859-1", "latin1", "latin-1", "l1": return .isoLatin1
        case "windows-1252", "cp1252", "win-1252", "cp-1252": return .windowsCP1252
        case "us-ascii", "ascii": return .utf8
        case "macintosh", "mac-roman", "x-mac-roman": return .macOSRoman
        default:
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        }
    }
}
