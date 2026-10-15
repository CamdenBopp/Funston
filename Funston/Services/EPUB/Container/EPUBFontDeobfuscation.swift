import CryptoKit
import Foundation

/// The two font obfuscation schemes books use. Both XOR a prefix of the font
/// with a key derived from the publication's unique identifier; both run behind
/// an sfnt header check so a wrong key falls back to system fonts instead of
/// drawing garbage.
enum EPUBFontObfuscation {
    static let idpfAlgorithm = "http://www.idpf.org/2008/embedding"
    static let adobeAlgorithm = "http://ns.adobe.com/pdf/enc#RC"
    static let idpfPrefixLength = 1040
    static let adobePrefixLength = 1024
    static let adobeKeyLength = 16
    static let uuidPrefix = "urn:uuid:"
    /// A real font directory never lists this many tables.
    static let maximumPlausibleTableCount = 64

    enum Failure: Error, Equatable {
        case unknownAlgorithm(String)
        case noKey
        case notAFont
    }

    static func isObfuscationAlgorithm(_ algorithm: String) -> Bool {
        algorithm == idpfAlgorithm || algorithm == adobeAlgorithm
    }

    /// SHA-1 of the identifier with every U+0020, U+0009, U+000D and U+000A
    /// removed, prefix kept. Nil when nothing is left to hash.
    static func idpfKey(uniqueIdentifier: String) -> [UInt8]? {
        let stripped = uniqueIdentifier.unicodeScalars.filter { !($0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n") }
        let text = String(String.UnicodeScalarView(stripped))
        guard !text.isEmpty, text != uuidPrefix else { return nil }
        return Array(Insecure.SHA1.hash(data: Data(text.utf8)))
    }

    /// The 16 bytes of the UUID in the identifier: prefix and hyphens removed,
    /// 32 hexadecimal digits. Nil when the identifier is not a UUID.
    static func adobeKey(uniqueIdentifier: String) -> [UInt8]? {
        var text = uniqueIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = text.lastIndex(of: ":") { text = String(text[text.index(after: colon)...]) }
        let hex = text.replacingOccurrences(of: "-", with: "")
        guard hex.count == adobeKeyLength * 2 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// XOR is its own inverse, so one routine obfuscates and deobfuscates.
    static func apply(key: [UInt8], prefixLength: Int, to data: Data) -> Data {
        guard !key.isEmpty, !data.isEmpty else { return data }
        var output = data
        let limit = min(prefixLength, output.count)
        output.withUnsafeMutableBytes { raw in
            for index in 0..<limit { raw[index] ^= key[index % key.count] }
        }
        return output
    }

    /// True when the bytes begin like an sfnt, WOFF or WOFF2 font with a
    /// plausible table count.
    static func looksLikeFont(_ data: Data) -> Bool {
        guard data.count >= 16 else { return false }
        let bytes = Array(data.prefix(16))
        let tag = String(decoding: bytes[0..<4], as: UTF8.self)
        let sfntTables = Int(bytes[4]) << 8 | Int(bytes[5])
        let woffTables = Int(bytes[12]) << 8 | Int(bytes[13])
        switch tag {
        case "OTTO", "true", "\u{0}\u{1}\u{0}\u{0}":
            return (1..<maximumPlausibleTableCount).contains(sfntTables)
        case "wOFF", "wOF2":
            return (1..<maximumPlausibleTableCount).contains(woffTables)
        default:
            return false
        }
    }

    /// Deobfuscates `data` under `algorithm`, or says why it could not.
    static func decode(_ data: Data, algorithm: String, uniqueIdentifier: String) -> Result<Data, Failure> {
        let key: [UInt8]?, prefix: Int
        switch algorithm {
        case idpfAlgorithm: key = idpfKey(uniqueIdentifier: uniqueIdentifier); prefix = idpfPrefixLength
        case adobeAlgorithm: key = adobeKey(uniqueIdentifier: uniqueIdentifier); prefix = adobePrefixLength
        default: return .failure(.unknownAlgorithm(algorithm))
        }
        guard let key else { return .failure(.noKey) }
        let decoded = apply(key: key, prefixLength: prefix, to: data)
        return looksLikeFont(decoded) ? .success(decoded) : .failure(.notAFont)
    }
}
