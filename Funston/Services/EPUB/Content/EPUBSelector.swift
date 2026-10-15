import Foundation

/// The selector subset of Spec section 9.1: type, class, id, universal,
/// descendant and child combinators, attribute selectors with `@namespace`
/// prefixes, and `:first-child` and `:last-child`. Anything else parses into a
/// selector that never matches and is counted by form.
struct EPUBSelector: Sendable, Hashable {
    /// CSS specificity as the three-tuple, never a summed integer.
    struct Specificity: Sendable, Hashable, Comparable {
        var ids: Int
        var classes: Int
        var types: Int

        static func < (lhs: Specificity, rhs: Specificity) -> Bool {
            (lhs.ids, lhs.classes, lhs.types) < (rhs.ids, rhs.classes, rhs.types)
        }
    }

    enum AttributeOperator: String, Sendable, Hashable {
        case present = "", equals = "=", includes = "~=", dashMatch = "|="
    }

    struct AttributeTest: Sendable, Hashable {
        let namespacePrefix: String?
        let name: String
        let `operator`: AttributeOperator
        let value: String
    }

    enum PseudoClass: String, Sendable, Hashable { case firstChild = "first-child", lastChild = "last-child" }

    enum Combinator: Sendable, Hashable { case descendant, child }

    struct Compound: Sendable, Hashable {
        var namespacePrefix: String?
        var type: String?
        var id: String?
        var classes: [String] = []
        var attributes: [AttributeTest] = []
        var pseudoClasses: [PseudoClass] = []
    }

    /// Compounds from left to right with the combinator before each (nil for the first).
    let compounds: [Compound]
    let combinators: [Combinator?]
    let specificity: Specificity
    /// The form of the unsupported construct, when the selector never matches.
    let unsupportedForm: String?
    let text: String

    var isSupported: Bool { unsupportedForm == nil }

    // MARK: Parsing

    static func parseList(_ text: String) -> [EPUBSelector] {
        splitTopLevel(text, on: ",").map { parse($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static func parse(_ text: String) -> EPUBSelector {
        var compounds: [Compound] = []
        var combinators: [Combinator?] = []
        var unsupported: String?
        var specificity = Specificity(ids: 0, classes: 0, types: 0)
        let characters = Array(text)
        var index = 0
        var pendingCombinator: Combinator? = nil
        var sawWhitespace = false
        func skipSpaces() { while index < characters.count, characters[index].isWhitespace { index += 1; sawWhitespace = true } }
        while index < characters.count {
            sawWhitespace = false
            skipSpaces()
            guard index < characters.count else { break }
            let character = characters[index]
            if character == ">" {
                pendingCombinator = .child; index += 1; continue
            }
            if character == "+" || character == "~" {
                unsupported = unsupported ?? String(character); index += 1; continue
            }
            if sawWhitespace, !compounds.isEmpty, pendingCombinator == nil { pendingCombinator = .descendant }
            var compound = Compound()
            var consumed = false
            while index < characters.count {
                let current = characters[index]
                if current.isWhitespace || current == ">" || current == "+" || current == "~" { break }
                switch current {
                case "*":
                    index += 1
                    if index < characters.count, characters[index] == "|" { compound.namespacePrefix = "*"; index += 1; continue }
                    consumed = true
                case "#":
                    index += 1
                    compound.id = identifier(characters, &index)
                    specificity.ids += 1; consumed = true
                case ".":
                    index += 1
                    compound.classes.append(identifier(characters, &index))
                    specificity.classes += 1; consumed = true
                case "[":
                    index += 1
                    var inner = ""
                    while index < characters.count, characters[index] != "]" { inner.append(characters[index]); index += 1 }
                    index += 1
                    if let test = attributeTest(inner) { compound.attributes.append(test) } else { unsupported = unsupported ?? "[" + inner + "]" }
                    specificity.classes += 1; consumed = true
                case ":":
                    index += 1
                    var isPseudoElement = false
                    if index < characters.count, characters[index] == ":" { isPseudoElement = true; index += 1 }
                    let name = identifier(characters, &index)
                    var argument = ""
                    if index < characters.count, characters[index] == "(" {
                        var depth = 0
                        repeat {
                            if characters[index] == "(" { depth += 1 } else if characters[index] == ")" { depth -= 1 }
                            argument.append(characters[index]); index += 1
                        } while index < characters.count && depth > 0
                    }
                    if let pseudo = PseudoClass(rawValue: name), !isPseudoElement {
                        compound.pseudoClasses.append(pseudo)
                        specificity.classes += 1
                    } else {
                        unsupported = unsupported ?? ((isPseudoElement ? "::" : ":") + name + argument)
                    }
                    consumed = true
                default:
                    let name = identifier(characters, &index)
                    guard !name.isEmpty else { index += 1; unsupported = unsupported ?? String(current); continue }
                    if index < characters.count, characters[index] == "|", index + 1 < characters.count, characters[index + 1] != "=" {
                        compound.namespacePrefix = name; index += 1
                        let type = identifier(characters, &index)
                        if type == "*" || type.isEmpty { index += type.isEmpty ? 1 : 0 } else { compound.type = type.lowercased(); specificity.types += 1 }
                    } else {
                        compound.type = name.lowercased(); specificity.types += 1
                    }
                    consumed = true
                }
            }
            if consumed {
                combinators.append(compounds.isEmpty ? nil : (pendingCombinator ?? .descendant))
                compounds.append(compound)
                pendingCombinator = nil
            } else if index < characters.count, !characters[index].isWhitespace, characters[index] != ">" {
                index += 1
            }
        }
        if compounds.isEmpty { unsupported = unsupported ?? text }
        return EPUBSelector(compounds: compounds, combinators: combinators, specificity: specificity, unsupportedForm: unsupported, text: text)
    }

    private static func identifier(_ characters: [Character], _ index: inout Int) -> String {
        var name = ""
        while index < characters.count {
            let current = characters[index]
            if current == "\\", index + 1 < characters.count { name.append(characters[index + 1]); index += 2; continue }
            guard current.isLetter || current.isNumber || current == "-" || current == "_" || current.unicodeScalars.first.map({ $0.value > 0x7F }) == true else { break }
            name.append(current); index += 1
        }
        return name
    }

    private static func attributeTest(_ inner: String) -> AttributeTest? {
        let trimmed = inner.trimmingCharacters(in: .whitespaces)
        for op in ["~=", "|=", "^=", "$=", "*=", "="] {
            guard let range = trimmed.range(of: op) else { continue }
            guard let known = AttributeOperator(rawValue: op) else { return nil }
            let name = trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            var value = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(" i") || value.hasSuffix(" s") { value = String(value.dropLast(2)).trimmingCharacters(in: .whitespaces) }
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            let (prefix, local) = splitNamespace(name)
            return AttributeTest(namespacePrefix: prefix, name: local, operator: known, value: value)
        }
        let (prefix, local) = splitNamespace(trimmed)
        return AttributeTest(namespacePrefix: prefix, name: local, operator: .present, value: "")
    }

    private static func splitNamespace(_ name: String) -> (String?, String) {
        guard let bar = name.firstIndex(of: "|") else { return (nil, name.replacingOccurrences(of: "\\:", with: ":")) }
        return (String(name[..<bar]), String(name[name.index(after: bar)...]))
    }

    /// Splits on a delimiter outside brackets, parentheses and quotes.
    static func splitTopLevel(_ text: String, on delimiter: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        for character in text {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character; current.append(character)
            case "[", "(": depth += 1; current.append(character)
            case "]", ")": depth = max(0, depth - 1); current.append(character)
            case delimiter where depth == 0: parts.append(current); current = ""
            default: current.append(character)
            }
        }
        parts.append(current)
        return parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: Matching

    /// True when the selector matches `element`; `namespaces` maps `@namespace`
    /// prefixes to URIs (the empty prefix is the default namespace).
    func matches(_ element: EPUBXMLDocument.NodeID, in tree: EPUBXMLDocument, namespaces: [String: String]) -> Bool {
        guard isSupported, !compounds.isEmpty else { return false }
        return matches(compoundIndex: compounds.count - 1, element: element, in: tree, namespaces: namespaces)
    }

    private func matches(compoundIndex: Int, element: EPUBXMLDocument.NodeID, in tree: EPUBXMLDocument, namespaces: [String: String]) -> Bool {
        guard Self.matches(compounds[compoundIndex], element, in: tree, namespaces: namespaces) else { return false }
        guard compoundIndex > 0 else { return true }
        switch combinators[compoundIndex] {
        case .child:
            guard let parent = tree.parent(of: element), tree[parent].isElement else { return false }
            return matches(compoundIndex: compoundIndex - 1, element: parent, in: tree, namespaces: namespaces)
        case .descendant, nil:
            var ancestor = tree.parent(of: element)
            while let candidate = ancestor {
                if tree[candidate].isElement, matches(compoundIndex: compoundIndex - 1, element: candidate, in: tree, namespaces: namespaces) { return true }
                ancestor = tree.parent(of: candidate)
            }
            return false
        }
    }

    private static func matches(_ compound: Compound, _ element: EPUBXMLDocument.NodeID, in tree: EPUBXMLDocument, namespaces: [String: String]) -> Bool {
        let node = tree[element]
        if let type = compound.type, node.name != type { return false }
        if let prefix = compound.namespacePrefix, prefix != "*", let uri = namespaces[prefix], node.namespaceURI != uri, node.namespaceURI != nil { return false }
        if let id = compound.id, tree.id(of: element) != id { return false }
        if !compound.classes.isEmpty {
            let classes = Set(EPUBPropertyVocabulary.tokens(tree.attribute("class", of: element)))
            for wanted in compound.classes where !classes.contains(wanted) { return false }
        }
        for test in compound.attributes {
            let value: String?
            if let prefix = test.namespacePrefix, prefix != "*", let uri = namespaces[prefix] {
                value = tree.attribute(test.name, namespace: uri, of: element) ?? tree.attribute(qualified: prefix + ":" + test.name, of: element)
            } else if test.namespacePrefix == "*" {
                value = node.attributes.first { $0.localName == test.name }?.value
            } else {
                value = tree.attribute(test.name, of: element) ?? tree.attribute(qualified: test.name, of: element)
            }
            guard let value else { return false }
            switch test.operator {
            case .present: break
            case .equals: if value != test.value { return false }
            case .includes: if !EPUBPropertyVocabulary.tokens(value).contains(test.value) { return false }
            case .dashMatch: if !(value == test.value || value.hasPrefix(test.value + "-")) { return false }
            }
        }
        for pseudo in compound.pseudoClasses {
            guard let parent = tree.parent(of: element) else { return false }
            let siblings = tree.childElements(of: parent)
            switch pseudo {
            case .firstChild: if siblings.first != element { return false }
            case .lastChild: if siblings.last != element { return false }
            }
        }
        return true
    }
}
