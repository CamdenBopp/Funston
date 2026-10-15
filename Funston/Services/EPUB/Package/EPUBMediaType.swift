import Foundation

/// A parsed media type (RFC 6838): type and subtype lowercased, parameter
/// names lowercased, `charset` values uppercased, parameters sorted on output.
struct EPUBMediaType: Sendable, Hashable, CustomStringConvertible {
    let type: String
    let subtype: String
    let parameters: [String: String]

    static let xhtml = EPUBMediaType(type: "application", subtype: "xhtml+xml")
    static let html = EPUBMediaType(type: "text", subtype: "html")
    static let svg = EPUBMediaType(type: "image", subtype: "svg+xml")
    static let ncx = EPUBMediaType(type: "application", subtype: "x-dtbncx+xml")
    static let css = EPUBMediaType(type: "text", subtype: "css")
    static let smil = EPUBMediaType(type: "application", subtype: "smil+xml")
    static let pls = EPUBMediaType(type: "application", subtype: "pls+xml")
    static let bitmapSubtypes: Set<String> = ["avif", "bmp", "gif", "jpeg", "jxl", "png", "tiff", "webp"]
    static let fontTypes: Set<String> = ["application/font-sfnt", "application/vnd.ms-opentype", "application/x-font-ttf", "application/x-font-truetype",
                                         "application/x-font-opentype", "application/font-woff", "application/font-woff2",
                                         "font/ttf", "font/otf", "font/sfnt", "font/woff", "font/woff2", "application/x-font-woff"]

    init(type: String, subtype: String, parameters: [String: String] = [:]) {
        self.type = type; self.subtype = subtype; self.parameters = parameters
    }

    init?(_ string: String) {
        let parts = string.split(separator: ";", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first else { return nil }
        let halves = first.split(separator: "/", omittingEmptySubsequences: false)
        guard halves.count == 2, !halves[0].isEmpty, !halves[1].isEmpty else { return nil }
        type = halves[0].lowercased()
        subtype = halves[1].lowercased()
        var parameters: [String: String] = [:]
        for parameter in parts.dropFirst() {
            guard let equals = parameter.firstIndex(of: "=") else { continue }
            let name = parameter[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var value = parameter[parameter.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            parameters[name] = name == "charset" ? value.uppercased() : value
        }
        self.parameters = parameters
    }

    var essence: String { "\(type)/\(subtype)" }

    var description: String {
        let sorted = parameters.sorted { $0.key < $1.key }.map { ";\($0.key)=\($0.value)" }.joined()
        return essence + sorted
    }

    /// True when the types match (with `*` wildcards) and every parameter of
    /// `self` appears in `other`.
    func contains(_ other: EPUBMediaType) -> Bool {
        guard type == "*" || type == other.type, subtype == "*" || subtype == other.subtype else { return false }
        return parameters.allSatisfy { other.parameters[$0.key] == $0.value }
    }

    func matches(_ other: EPUBMediaType) -> Bool { contains(other) || other.contains(self) }

    var isXHTML: Bool { essence == Self.xhtml.essence }
    var isHTML: Bool { isXHTML || essence == Self.html.essence }
    var isSVG: Bool { essence == Self.svg.essence }
    var isBitmap: Bool { type == "image" && Self.bitmapSubtypes.contains(subtype) }
    var isImage: Bool { isBitmap || isSVG }
    var isNCX: Bool { essence == Self.ncx.essence }
    var isCSS: Bool { essence == Self.css.essence }
    var isSMIL: Bool { essence == Self.smil.essence }
    var isFont: Bool { Self.fontTypes.contains(essence) || type == "font" }
    /// A content document the reader can show: XHTML or SVG.
    var isContentDocument: Bool { isXHTML || isSVG }
}
