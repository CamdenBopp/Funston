import Foundation

/// Expands prefixed property values (`epub:type`, `meta property`, `properties`,
/// `rel`, `scheme`) to full URIs so `z3998:verse` is recognised whatever prefix
/// the author chose. EPUB 3.3 appendix D.1 and Reading Systems 3.3 section 11.
enum EPUBPropertyVocabulary {
    /// Where a value was found decides its default vocabulary.
    enum Context: Sendable {
        case epubType, metaProperty, linkRelation, linkProperties, manifestProperties, spineProperties, scheme

        var defaultVocabulary: String? {
            switch self {
            case .epubType: return structuralSemantics
            case .metaProperty: return "http://idpf.org/epub/vocab/package/meta/#"
            case .linkRelation, .linkProperties: return "http://idpf.org/epub/vocab/package/link/#"
            case .manifestProperties: return "http://idpf.org/epub/vocab/package/item/#"
            case .spineProperties: return "http://idpf.org/epub/vocab/package/itemref/#"
            case .scheme: return nil
            }
        }
    }

    static let structuralSemantics = "http://idpf.org/epub/vocab/structure/#"
    static let dublinCoreTerms = "http://purl.org/dc/terms/"
    static let dublinCoreElements = "http://purl.org/dc/elements/1.1/"
    static let rendition = "http://www.idpf.org/vocab/rendition/#"
    static let mediaOverlays = "http://www.idpf.org/epub/vocab/overlays/#"
    static let accessibility = "http://www.idpf.org/epub/vocab/package/a11y/#"
    static let schema = "http://schema.org/"
    static let marc = "http://id.loc.gov/vocabulary/"
    static let z3998 = "http://www.daisy.org/z3998/2012/vocab/structure/"
    static let calibre = "https://calibre-ebook.com"

    static let reservedPrefixes: [String: String] = [
        "a11y": accessibility,
        "dcterms": dublinCoreTerms,
        "marc": marc,
        "media": mediaOverlays,
        "onix": "http://www.editeur.org/ONIX/book/codelists/current.html#",
        "rendition": rendition,
        "schema": schema,
        "xsd": "http://www.w3.org/2001/XMLSchema#",
        "msv": "http://www.idpf.org/epub/vocab/structure/magazine/#",
        "prism": "http://www.prismstandard.org/specifications/3.0/PRISM_CV_Spec_3.0.htm#",
        "calibre": calibre
    ]

    /// Parses a `prefix` attribute: whitespace-separated tokens alternating
    /// `name:` and URI, so two declarations on one line both survive.
    static func declaredPrefixes(_ attribute: String?) -> [String: String] {
        guard let attribute else { return [:] }
        var result: [String: String] = [:]
        let tokens = attribute.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).map(String.init)
        var index = 0
        while index + 1 < tokens.count {
            let name = tokens[index]
            guard name.hasSuffix(":"), name.count > 1 else { index += 1; continue }
            result[String(name.dropLast())] = tokens[index + 1]
            index += 2
        }
        return result
    }

    /// The expanded URI, or nil when the value is invalid (a leading colon, an
    /// undeclared prefix, or no prefix where the context has no default).
    static func expand(_ value: String, context: Context, declared: [String: String] = [:]) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(":") else { return nil }
        if let colon = trimmed.firstIndex(of: ":") {
            let prefix = String(trimmed[..<colon])
            let reference = String(trimmed[trimmed.index(after: colon)...])
            let base = declared[prefix] ?? (prefix == "dc" ? dublinCoreElements : reservedPrefixes[prefix])
            guard let base else { return nil }
            return base + reference
        }
        guard let base = context.defaultVocabulary else { return nil }
        return base + trimmed
    }

    /// Every whitespace-separated token of a `properties` or `epub:type` value, raw.
    static func tokens(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).map(String.init)
    }

    /// Expanded terms for every token, dropping invalid ones.
    static func expandedTerms(_ value: String?, context: Context, declared: [String: String] = [:]) -> Set<String> {
        Set(tokens(value).compactMap { expand($0, context: context, declared: declared) })
    }
}
