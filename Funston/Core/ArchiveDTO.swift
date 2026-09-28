import Foundation

/// IA fields are not schema-stable. Preserve usable scalar values without allowing one
/// unexpected object to invalidate an entire artifact or result page.
enum ArchiveValue: Decodable, Sendable {
    case string(String), number(String), bool(Bool), array([ArchiveValue]), object([String: ArchiveValue]), null

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .number(String(v)) }
        else if let v = try? c.decode(UInt64.self) { self = .number(String(v)) }
        else if let v = try? c.decode(Double.self) { self = .number(String(v)) }
        else if let v = try? c.decode([ArchiveValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: ArchiveValue].self)) }
    }

    var strings: [String] {
        switch self {
        case let .string(v): v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [v]
        case let .number(v): [v]
        case let .bool(v): [v ? "true" : "false"]
        case let .array(v): v.flatMap(\.strings)
        case .object, .null: []
        }
    }
    var first: String? { strings.first }
    var object: [String: ArchiveValue]? { if case let .object(v) = self { v } else { nil } }
    var array: [ArchiveValue]? { if case let .array(v) = self { v } else { nil } }
}

typealias ArchiveFields = [String: ArchiveValue]

extension Dictionary where Key == String, Value == ArchiveValue {
    func text(_ key: String) -> String? { self[key]?.first }
    func texts(_ key: String) -> [String] { self[key]?.strings ?? [] }
    func integer(_ key: String) -> Int? { text(key).flatMap(Int.init) }
}

struct ArchiveMetadataDTO: Decodable, Sendable {
    let metadata: ArchiveFields
    let files: [ArchiveFields]
    let envelope: ArchiveFields

    init(from decoder: any Decoder) throws {
        envelope = try ArchiveFields(from: decoder)
        metadata = envelope["metadata"]?.object ?? [:]
        files = envelope["files"]?.array?.compactMap(\.object) ?? []
    }
}

struct ArchiveSearchDTO: Decodable, Sendable {
    let documents: [ArchiveFields]
    let total: Int
    init(from decoder: any Decoder) throws {
        let root = try ArchiveFields(from: decoder)
        guard let response = root["response"]?.object,
              let documents = response["docs"]?.array,
              let total = response.integer("numFound"), total >= 0 else { throw ArchiveError.malformedData }
        self.documents = documents.compactMap(\.object)
        self.total = total
    }
}
