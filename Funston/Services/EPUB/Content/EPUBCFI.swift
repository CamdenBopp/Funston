import Foundation

/// An EPUB Canonical Fragment Identifier (CFI 1.1): the full grammar parsed
/// into a value, serialised canonically so parse then serialise is the
/// identity, and compared by the specification's sorting rules.
struct EPUBCFI: Sendable, Hashable, CustomStringConvertible {
    enum SideBias: String, Sendable, Hashable { case before = "b", after = "a" }

    struct Parameter: Sendable, Hashable {
        let name: String
        let values: [String]
    }

    struct TextAssertion: Sendable, Hashable {
        /// Up to 32 characters before the point; nil when the assertion is trailing-only.
        let before: String?
        let after: String?
    }

    struct SpatialPoint: Sendable, Hashable {
        let x: Double
        let y: Double
    }

    /// One `/n[assertion]` step.
    struct Step: Sendable, Hashable {
        var index: Int
        var id: String?
        var sideBias: SideBias?
        var parameters: [Parameter]

        init(index: Int, id: String? = nil, sideBias: SideBias? = nil, parameters: [Parameter] = []) {
            self.index = index; self.id = id; self.sideBias = sideBias; self.parameters = parameters
        }

        var isElementStep: Bool { index % 2 == 0 }
        var isChunkStep: Bool { index % 2 == 1 }
    }

    /// The terminal `:n`, `~t`, `@x:y` and the bracket after it.
    struct Offset: Sendable, Hashable {
        var character: Int?
        var temporal: Double?
        var spatial: SpatialPoint?
        var textAssertion: TextAssertion?
        var sideBias: SideBias?
        var parameters: [Parameter]

        init(character: Int? = nil, temporal: Double? = nil, spatial: SpatialPoint? = nil, textAssertion: TextAssertion? = nil, sideBias: SideBias? = nil, parameters: [Parameter] = []) {
            self.character = character; self.temporal = temporal; self.spatial = spatial
            self.textAssertion = textAssertion; self.sideBias = sideBias; self.parameters = parameters
        }

        var isEmpty: Bool { character == nil && temporal == nil && spatial == nil && textAssertion == nil && sideBias == nil && parameters.isEmpty }
        var hasPosition: Bool { character != nil || temporal != nil || spatial != nil }
    }

    /// Steps within one document, up to an indirection.
    struct Level: Sendable, Hashable {
        var steps: [Step]
        init(steps: [Step]) { self.steps = steps }
    }

    /// A path: levels separated by `!`, with an optional offset at the end.
    struct Path: Sendable, Hashable {
        var levels: [Level]
        var offset: Offset?

        init(levels: [Level], offset: Offset? = nil) { self.levels = levels; self.offset = offset }

        var isEmpty: Bool { levels.allSatisfy { $0.steps.isEmpty } && offset == nil }
        var lastStep: Step? { levels.last?.steps.last }

        /// The path with `local` appended: its first level joins this path's last.
        func appending(_ local: Path) -> Path {
            var levels = self.levels
            var remaining = local.levels
            if let first = remaining.first, !levels.isEmpty {
                levels[levels.count - 1].steps.append(contentsOf: first.steps)
                remaining.removeFirst()
            }
            levels.append(contentsOf: remaining)
            return Path(levels: levels, offset: local.offset ?? (remaining.isEmpty && local.levels.isEmpty ? offset : nil))
        }
    }

    /// The point path, or the parent path of a range.
    let path: Path
    let rangeStart: Path?
    let rangeEnd: Path?

    init(path: Path) { self.path = path; rangeStart = nil; rangeEnd = nil }
    init(parent: Path, start: Path, end: Path) { path = parent; rangeStart = start; rangeEnd = end }

    var isRange: Bool { rangeStart != nil }

    /// The start of a range, or the point itself.
    var startPath: Path { rangeStart.map { path.appending($0) } ?? path }
    var endPath: Path { rangeEnd.map { path.appending($0) } ?? path }

    /// The package level (before the first `!`) and the document levels after it.
    var packageLevel: Level? { path.levels.first }
    var documentPath: Path? {
        guard path.levels.count > 1 else { return nil }
        return Path(levels: Array(path.levels.dropFirst()), offset: path.offset)
    }

    var description: String { serialized }

    // MARK: Parsing

    struct ParseFailure: Error, Hashable {
        enum Reason: String, Sendable {
            case missingWrapper, unexpectedCharacter, leadingZero, trailingZero, emptyInteger, unterminatedAssertion, doubleIndirection,
                 badRangeShape, rangeParentHasOffset, sideBiasInRange, spatialOutOfRange, characterOffsetOnElementStep, missingStep, badNumber, badParameter
        }
        let reason: Reason
        /// The offset of the first bad character in the input.
        let offset: Int
    }

    static let wrapperPrefix = "epubcfi("
    static let escapeCharacter: Character = "^"
    static let escapedCharacters: Set<Character> = ["^", "[", "]", "(", ")", ",", ";", "="]
    static let spatialRange: ClosedRange<Double> = 0...100
    static let textAssertionLength = 32

    static func parse(_ string: String, allowingElementCharacterOffsets: Bool = false) throws(ParseFailure) -> EPUBCFI {
        var parser = Parser(Array(string.trimmingCharacters(in: .whitespacesAndNewlines)))
        let cfi = try parser.parseFragment()
        try cfi.validate(allowingElementCharacterOffsets: allowingElementCharacterOffsets)
        return cfi
    }

    private func validate(allowingElementCharacterOffsets: Bool) throws(ParseFailure) {
        if isRange {
            if path.offset != nil { throw ParseFailure(reason: .rangeParentHasOffset, offset: 0) }
            for local in [rangeStart, rangeEnd].compactMap({ $0 }) {
                if local.offset?.sideBias != nil || local.levels.contains(where: { $0.steps.contains { $0.sideBias != nil } }) {
                    throw ParseFailure(reason: .sideBiasInRange, offset: 0)
                }
            }
        }
        for candidate in [path, rangeStart, rangeEnd].compactMap({ $0 }) {
            if let spatial = candidate.offset?.spatial, !Self.spatialRange.contains(spatial.x) || !Self.spatialRange.contains(spatial.y) {
                throw ParseFailure(reason: .spatialOutOfRange, offset: 0)
            }
            if !allowingElementCharacterOffsets, candidate.offset?.character != nil, let last = candidate.lastStep, last.isElementStep {
                throw ParseFailure(reason: .characterOffsetOnElementStep, offset: 0)
            }
            if candidate.offset?.character != nil, candidate.lastStep == nil {
                throw ParseFailure(reason: .missingStep, offset: 0)
            }
        }
    }

    private struct Parser {
        let characters: [Character]
        var position = 0

        init(_ characters: [Character]) { self.characters = characters }

        var current: Character? { position < characters.count ? characters[position] : nil }

        mutating func parseFragment() throws(ParseFailure) -> EPUBCFI {
            let prefix = Array(EPUBCFI.wrapperPrefix)
            var wrapped = false
            if characters.count >= prefix.count, Array(characters[0..<prefix.count]) == prefix {
                wrapped = true
                position = prefix.count
            }
            let first = try parsePath()
            var ranges: [Path] = []
            while current == "," {
                position += 1
                ranges.append(try parsePath())
            }
            if wrapped {
                guard current == ")" else { throw ParseFailure(reason: ranges.isEmpty ? .unexpectedCharacter : .badRangeShape, offset: position) }
                position += 1
            }
            guard position == characters.count else { throw ParseFailure(reason: .unexpectedCharacter, offset: position) }
            switch ranges.count {
            case 0: return EPUBCFI(path: first)
            case 2: return EPUBCFI(parent: first, start: ranges[0], end: ranges[1])
            default: throw ParseFailure(reason: .badRangeShape, offset: position)
            }
        }

        /// `{ step } ( "!" path | offset )?` as levels.
        mutating func parsePath() throws(ParseFailure) -> Path {
            var levels: [Level] = [Level(steps: [])]
            var offset: Offset?
            loop: while let character = current {
                switch character {
                case "/":
                    levels[levels.count - 1].steps.append(try parseStep())
                case "!":
                    position += 1
                    guard current == "/" else { throw ParseFailure(reason: .doubleIndirection, offset: position) }
                    levels.append(Level(steps: []))
                case ":", "~", "@":
                    offset = try parseOffset()
                    break loop
                default:
                    break loop
                }
            }
            if levels.count == 1, levels[0].steps.isEmpty, offset == nil, current != nil, current != "," && current != ")" {
                throw ParseFailure(reason: .unexpectedCharacter, offset: position)
            }
            if levels.count == 1, levels[0].steps.isEmpty, offset == nil {
                throw ParseFailure(reason: .missingStep, offset: position)
            }
            return Path(levels: levels, offset: offset)
        }

        mutating func parseStep() throws(ParseFailure) -> Step {
            position += 1 // "/"
            let index = try parseInteger()
            var step = Step(index: index)
            if current == "[" {
                let bracket = try parseBracket()
                if bracket.values.count > 1 { throw ParseFailure(reason: .unexpectedCharacter, offset: position) }
                if let value = bracket.values.first, !value.isEmpty { step.id = value }
                if bracket.leadingComma { throw ParseFailure(reason: .unexpectedCharacter, offset: position) }
                step.sideBias = bracket.sideBias
                step.parameters = bracket.parameters
            }
            return step
        }

        mutating func parseOffset() throws(ParseFailure) -> Offset {
            // The grammar offers the three forms as alternatives; the foliate
            // study's vectors combine them, so each part is read in order.
            var offset = Offset()
            if current == ":" {
                position += 1
                offset.character = try parseInteger()
            }
            if current == "~" {
                position += 1
                offset.temporal = try parseNumber()
            }
            if current == "@" {
                position += 1
                let x = try parseNumber()
                guard current == ":" else { throw ParseFailure(reason: .unexpectedCharacter, offset: position) }
                position += 1
                let y = try parseNumber()
                offset.spatial = SpatialPoint(x: x, y: y)
            }
            if current == "[" {
                let bracket = try parseBracket()
                if bracket.values.count > 2 { throw ParseFailure(reason: .unexpectedCharacter, offset: position) }
                if !bracket.values.isEmpty || bracket.leadingComma {
                    if bracket.leadingComma {
                        offset.textAssertion = TextAssertion(before: nil, after: bracket.values.first ?? "")
                    } else {
                        offset.textAssertion = TextAssertion(before: bracket.values[0], after: bracket.values.count > 1 ? bracket.values[1] : nil)
                    }
                }
                offset.sideBias = bracket.sideBias
                offset.parameters = bracket.parameters
            }
            return offset
        }

        struct Bracket {
            var values: [String] = []
            var leadingComma = false
            var sideBias: SideBias?
            var parameters: [Parameter] = []
        }

        /// `[` value ("," value)? | "," value | (";" name "=" csv)* `]`
        mutating func parseBracket() throws(ParseFailure) -> Bracket {
            let start = position
            position += 1 // "["
            var bracket = Bracket()
            if current == "," {
                bracket.leadingComma = true
                position += 1
                bracket.values.append(try parseValue())
            } else if current != ";" && current != "]" {
                bracket.values.append(try parseValue())
                if current == "," {
                    position += 1
                    bracket.values.append(try parseValue())
                }
            } else if current == "]" {
                // An empty bracket is not an assertion.
            }
            while current == ";" {
                position += 1
                let name = try parseValue(stoppingAtEquals: true)
                guard current == "=", !name.isEmpty, !name.contains(" ") else { throw ParseFailure(reason: .badParameter, offset: position) }
                position += 1
                var values = [try parseValue()]
                while current == "," { position += 1; values.append(try parseValue()) }
                if name == "s" {
                    guard values.count == 1, let bias = SideBias(rawValue: values[0]) else { throw ParseFailure(reason: .badParameter, offset: position) }
                    bracket.sideBias = bias
                } else {
                    bracket.parameters.append(Parameter(name: name, values: values))
                }
            }
            guard current == "]" else { throw ParseFailure(reason: .unterminatedAssertion, offset: max(start, position)) }
            position += 1
            return bracket
        }

        /// Characters up to an unescaped delimiter; `^` escapes the next character.
        mutating func parseValue(stoppingAtEquals: Bool = false) throws(ParseFailure) -> String {
            var value = ""
            while let character = current {
                if character == EPUBCFI.escapeCharacter {
                    position += 1
                    guard let escaped = current else { throw ParseFailure(reason: .unterminatedAssertion, offset: position) }
                    value.append(escaped)
                    position += 1
                    continue
                }
                if character == "]" || character == "," || character == ";" || (stoppingAtEquals && character == "=") { break }
                if character == "[" || character == "(" || character == ")" || character == "=" {
                    throw ParseFailure(reason: .unexpectedCharacter, offset: position)
                }
                value.append(character)
                position += 1
            }
            return value
        }

        mutating func parseInteger() throws(ParseFailure) -> Int {
            let start = position
            while let character = current, character.isASCIIDigit { position += 1 }
            guard position > start else { throw ParseFailure(reason: .emptyInteger, offset: start) }
            let digits = String(characters[start..<position])
            if digits.count > 1, digits.hasPrefix("0") { throw ParseFailure(reason: .leadingZero, offset: start) }
            guard let value = Int(digits) else { throw ParseFailure(reason: .badNumber, offset: start) }
            return value
        }

        /// `integer [ "." digits ]` with no trailing zeros in the fraction.
        mutating func parseNumber() throws(ParseFailure) -> Double {
            let start = position
            _ = try parseInteger()
            if current == "." {
                position += 1
                let fractionStart = position
                while let character = current, character.isASCIIDigit { position += 1 }
                guard position > fractionStart else { throw ParseFailure(reason: .badNumber, offset: fractionStart) }
                if characters[position - 1] == "0" { throw ParseFailure(reason: .trailingZero, offset: position - 1) }
            }
            guard let value = Double(String(characters[start..<position])) else { throw ParseFailure(reason: .badNumber, offset: start) }
            return value
        }
    }

    // MARK: Serialisation

    static func escape(_ value: String) -> String {
        var result = ""
        for character in value {
            if escapedCharacters.contains(character) { result.append(escapeCharacter) }
            result.append(character)
        }
        return result
    }

    static func format(_ number: Double) -> String {
        if number == number.rounded(), abs(number) < 1e15 { return String(Int(number)) }
        var text = String(format: "%.10f", number)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private static func serialize(_ parameters: [Parameter], sideBias: SideBias?) -> String {
        var result = ""
        if let sideBias { result += ";s=" + sideBias.rawValue }
        for parameter in parameters { result += ";" + escape(parameter.name) + "=" + parameter.values.map(escape).joined(separator: ",") }
        return result
    }

    static func serialize(_ step: Step) -> String {
        var result = "/" + String(step.index)
        let tail = serialize(step.parameters, sideBias: step.sideBias)
        if step.id != nil || !tail.isEmpty {
            result += "[" + escape(step.id ?? "") + tail + "]"
        }
        return result
    }

    static func serialize(_ offset: Offset) -> String {
        var result = ""
        if let character = offset.character { result += ":" + String(character) }
        if let temporal = offset.temporal { result += "~" + format(temporal) }
        if let spatial = offset.spatial { result += "@" + format(spatial.x) + ":" + format(spatial.y) }
        let tail = serialize(offset.parameters, sideBias: offset.sideBias)
        if let assertion = offset.textAssertion {
            result += "[" + (assertion.before.map(escape) ?? "")
            if let after = assertion.after { result += "," + escape(after) }
            result += tail + "]"
        } else if !tail.isEmpty {
            result += "[" + tail + "]"
        }
        return result
    }

    static func serialize(_ path: Path) -> String {
        var result = path.levels.map { $0.steps.map(serialize).joined() }.joined(separator: "!")
        if let offset = path.offset { result += serialize(offset) }
        return result
    }

    var serialized: String {
        var body = Self.serialize(path)
        if let rangeStart, let rangeEnd { body += "," + Self.serialize(rangeStart) + "," + Self.serialize(rangeEnd) }
        return Self.wrapperPrefix + body + ")"
    }

    // MARK: Comparison

    /// One element of the sort key; assertions never appear in it.
    enum KeyElement: Comparable, Sendable, Hashable {
        case character(Int)
        case step(Int)
        case temporalSpatial(Double, Double, Double)
        case indirection

        private var rank: Int {
            switch self {
            case .character: return 1
            case .step: return 2
            case .temporalSpatial: return 3
            case .indirection: return 4
            }
        }

        static func < (lhs: KeyElement, rhs: KeyElement) -> Bool {
            switch (lhs, rhs) {
            case (.character(let a), .character(let b)): return a < b
            case (.step(let a), .step(let b)): return a < b
            case (.temporalSpatial(let t1, let y1, let x1), .temporalSpatial(let t2, let y2, let x2)):
                if t1 != t2 { return t1 < t2 }
                if y1 != y2 { return y1 < y2 }
                return x1 < x2
            case (.indirection, .indirection): return false
            default: return lhs.rank < rhs.rank
            }
        }
    }

    static func key(for path: Path) -> [KeyElement] {
        var key: [KeyElement] = []
        for (levelIndex, level) in path.levels.enumerated() {
            if levelIndex > 0 { key.append(.indirection) }
            for step in level.steps { key.append(.step(step.index)) }
        }
        if let offset = path.offset, offset.hasPosition {
            if let character = offset.character { key.append(.character(character)) }
            if offset.temporal != nil || offset.spatial != nil {
                key.append(.temporalSpatial(offset.temporal ?? -1, offset.spatial?.y ?? -1, offset.spatial?.x ?? -1))
            }
        } else if let last = path.lastStep, last.isChunkStep {
            // A terminal chunk step without an offset means offset 0.
            key.append(.character(0))
        }
        return key
    }

    static func compare(_ lhs: [KeyElement], _ rhs: [KeyElement]) -> Int {
        for (left, right) in zip(lhs, rhs) {
            if left < right { return -1 }
            if right < left { return 1 }
        }
        if lhs.count == rhs.count { return 0 }
        return lhs.count < rhs.count ? -1 : 1
    }

    /// -1 when `self` sorts before `other`, 0 when equal, 1 when after.
    func compare(to other: EPUBCFI) -> Int {
        let start = Self.compare(Self.key(for: startPath), Self.key(for: other.startPath))
        if start != 0 { return start }
        return Self.compare(Self.key(for: endPath), Self.key(for: other.endPath))
    }

    static func < (lhs: EPUBCFI, rhs: EPUBCFI) -> Bool { lhs.compare(to: rhs) < 0 }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
