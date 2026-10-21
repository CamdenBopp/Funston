import Foundation

/// Rewrites every `&name;` the HTML table knows into a numeric reference
/// before the XML parser sees the document, because XMLParser stops dead at an
/// undeclared entity, and substitutes entities the internal subset declares,
/// because XMLParser (measured on iOS 27 and macOS 27) reports those
/// declarations but drops the references. The five XML entities, CDATA
/// sections and comments are left alone; an unknown name becomes U+FFFD and
/// is counted; a declared entity that expands past the cap is a bomb and is
/// replaced the same way.
enum EPUBEntityExpansion {
    struct Result: Sendable {
        let text: String
        let unknownNames: [String: Int]
        /// True when a declared entity exceeded the expansion cap.
        let expansionLimited: Bool
        var unknownCount: Int { unknownNames.values.reduce(0, +) }
    }

    static let xmlEntities: Set<String> = ["amp", "lt", "gt", "quot", "apos"]
    static let replacementCharacter = "&#65533;"
    /// A declared entity may expand to at most this many bytes, nested at most this deep.
    static let maximumDeclaredExpansion = 65_536
    static let maximumDeclaredDepth = 8

    static func expand(_ text: String) -> Result {
        let declared = internalSubsetEntities(in: text)
        let bytes = Array(text.utf8)
        guard bytes.contains(UInt8(ascii: "&")) else { return Result(text: text, unknownNames: [:], expansionLimited: false) }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + bytes.count / 16)
        var unknown: [String: Int] = [:]
        var limited = false
        var index = 0
        let count = bytes.count
        func matches(_ literal: String, at position: Int) -> Bool {
            let pattern = Array(literal.utf8)
            guard position + pattern.count <= count else { return false }
            return Array(bytes[position..<position + pattern.count]) == pattern
        }
        while index < count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "<") {
                if matches("<![CDATA[", at: index) {
                    let end = find("]]>", in: bytes, from: index) ?? count
                    output.append(contentsOf: bytes[index..<end]); index = end; continue
                }
                if matches("<!--", at: index) {
                    let end = find("-->", in: bytes, from: index) ?? count
                    output.append(contentsOf: bytes[index..<end]); index = end; continue
                }
            }
            if byte == UInt8(ascii: "&"), index + 2 < count, isNameStart(bytes[index + 1]) {
                var end = index + 2
                while end < count, isNameCharacter(bytes[end]) { end += 1 }
                if end < count, bytes[end] == UInt8(ascii: ";") {
                    let name = String(decoding: bytes[(index + 1)..<end], as: UTF8.self)
                    if xmlEntities.contains(name) {
                        output.append(contentsOf: bytes[index...end])
                    } else if declared[name] != nil {
                        if let value = declaredValue(name, declared: declared, depth: 0, budget: maximumDeclaredExpansion) {
                            output.append(contentsOf: Array(value.utf8))
                        } else {
                            limited = true
                            output.append(contentsOf: Array(replacementCharacter.utf8))
                        }
                    } else if let replacement = EPUBNamedCharacterReferences.table[name] {
                        for scalar in replacement.unicodeScalars { output.append(contentsOf: Array("&#\(scalar.value);".utf8)) }
                    } else {
                        unknown[name, default: 0] += 1
                        output.append(contentsOf: Array(replacementCharacter.utf8))
                    }
                    index = end + 1
                    continue
                }
            }
            output.append(byte)
            index += 1
        }
        return Result(text: String(decoding: output, as: UTF8.self), unknownNames: unknown, expansionLimited: limited)
    }

    /// A declared entity's value with nested declared references expanded,
    /// nil when the expansion exceeds the depth or size cap.
    static func declaredValue(_ name: String, declared: [String: String], depth: Int, budget: Int) -> String? {
        guard depth < maximumDeclaredDepth, let value = declared[name], value.utf8.count <= budget else { return nil }
        guard value.contains("&") else { return value }
        var result = ""
        var remaining = budget - value.utf8.count
        var index = value.startIndex
        while index < value.endIndex {
            if value[index] == "&", let semicolon = value[index...].firstIndex(of: ";") {
                let inner = String(value[value.index(after: index)..<semicolon])
                if declared[inner] != nil {
                    guard let expanded = declaredValue(inner, declared: declared, depth: depth + 1, budget: remaining) else { return nil }
                    remaining -= expanded.utf8.count
                    guard remaining >= 0 else { return nil }
                    result += expanded
                    index = value.index(after: semicolon)
                    continue
                }
            }
            result.append(value[index])
            index = value.index(after: index)
        }
        return result
    }

    private static func isNameStart(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private static func isNameCharacter(_ byte: UInt8) -> Bool {
        isNameStart(byte) || (0x30...0x39).contains(byte)
    }

    private static func find(_ literal: String, in bytes: [UInt8], from start: Int) -> Int? {
        let pattern = Array(literal.utf8)
        guard pattern.count <= bytes.count else { return nil }
        var index = start
        while index + pattern.count <= bytes.count {
            if bytes[index] == pattern[0], Array(bytes[index..<index + pattern.count]) == pattern { return index + pattern.count }
            index += 1
        }
        return nil
    }

    /// General entities declared in the DOCTYPE's internal subset, name to
    /// replacement text. Parameter entities and external entities are ignored.
    static func internalSubsetEntities(in text: String) -> [String: String] {
        guard let doctype = text.range(of: "<!DOCTYPE", options: .caseInsensitive),
              let open = text.range(of: "[", range: doctype.upperBound..<text.endIndex) else { return [:] }
        let subsetEnd = text.range(of: "]>", range: open.upperBound..<text.endIndex)?.lowerBound ?? text.endIndex
        let subset = String(text[open.upperBound..<subsetEnd])
        // Only a subset that precedes the root element counts.
        if let firstElement = text.range(of: "<html", options: .caseInsensitive), firstElement.lowerBound < doctype.lowerBound { return [:] }
        guard let regex = try? NSRegularExpression(pattern: "<!ENTITY\\s+([A-Za-z][A-Za-z0-9._-]*)\\s+(?:\"([^\"]*)\"|'([^']*)')\\s*>", options: []) else { return [:] }
        var result: [String: String] = [:]
        for match in regex.matches(in: subset, range: NSRange(subset.startIndex..., in: subset)) {
            guard let nameRange = Range(match.range(at: 1), in: subset) else { continue }
            let value = Range(match.range(at: 2), in: subset).map { String(subset[$0]) } ?? Range(match.range(at: 3), in: subset).map { String(subset[$0]) } ?? ""
            let name = String(subset[nameRange])
            if result[name] == nil { result[name] = value }
        }
        return result
    }

    static func internalSubsetEntityNames(in text: String) -> Set<String> { Set(internalSubsetEntities(in: text).keys) }
}
