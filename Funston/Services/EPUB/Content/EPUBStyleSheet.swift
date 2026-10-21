import Foundation

/// One property declaration as written, with its importance.
struct EPUBDeclaration: Sendable, Hashable {
    let property: String
    let value: String
    let important: Bool
}

/// A rule: selectors, declarations, and the global source order for the cascade.
struct EPUBStyleRule: Sendable, Hashable {
    let selectors: [EPUBSelector]
    let declarations: [EPUBDeclaration]
    let order: Int
}

/// A `@font-face` block lifted out of a sheet.
struct EPUBFontFace: Sendable, Hashable {
    let family: String
    /// Container paths of the sources, in order; `local()` sources are dropped.
    let sources: [String]
    let weight: Int
    let italic: Bool
}

/// What `@media` queries are evaluated against.
struct EPUBMediaContext: Sendable, Hashable {
    var isDark: Bool
    var isLandscape: Bool
    static let `default` = EPUBMediaContext(isDark: false, isLandscape: false)
}

/// A parsed author style sheet: the CSS subset of Spec section 9.1, with
/// `@import` inlined from the container, `@namespace` kept, `@media`
/// evaluated, `@font-face` lifted and everything else dropped and counted.
struct EPUBStyleSheet: Sendable, Hashable {
    /// Sheets nest no deeper than this through `@import`.
    static let maximumImportDepth = 8

    var rules: [EPUBStyleRule] = []
    var namespaces: [String: String] = [:]
    var fontFaces: [EPUBFontFace] = []
    var diagnostics = EPUBDiagnosticList()
    private(set) var nextOrder = 0

    init() {}

    /// Parses `text` found at `path`; `loader` reads imported sheets by container path.
    static func parse(_ text: String, path: String, media: EPUBMediaContext, loader: (String) -> String?, resolve: (String, String) -> String?) -> EPUBStyleSheet {
        var sheet = EPUBStyleSheet()
        sheet.append(text, path: path, media: media, loader: loader, resolve: resolve, visited: [path], depth: 0)
        return sheet
    }

    mutating func append(_ text: String, path: String, media: EPUBMediaContext, loader: (String) -> String?, resolve: (String, String) -> String?, visited: Set<String>, depth: Int) {
        let stripped = Self.stripComments(text)
        var index = stripped.startIndex
        while index < stripped.endIndex {
            while index < stripped.endIndex, stripped[index].isWhitespace { index = stripped.index(after: index) }
            guard index < stripped.endIndex else { break }
            if stripped[index] == "@" {
                guard let (name, prelude, block, next) = Self.readAtRule(stripped, from: index) else { break }
                index = next
                switch name.lowercased() {
                case "import":
                    guard depth < Self.maximumImportDepth else { diagnostics.record(.css, "css.importDepth", path: path, "Imports nest too deeply."); continue }
                    let target = Self.urlArgument(prelude)
                    guard let target, let resolved = resolve(target, path) else { diagnostics.record(.css, "css.importUnresolved", path: path, "An @import could not be resolved."); continue }
                    guard !visited.contains(resolved) else { diagnostics.record(.css, "css.importCycle", path: path, "An @import cycle was broken."); continue }
                    let mediaList = prelude.replacingOccurrences(of: Self.urlPattern(prelude), with: "").trimmingCharacters(in: .whitespaces)
                    guard mediaList.isEmpty || Self.evaluateMedia(mediaList, media) else { continue }
                    guard let imported = loader(resolved) else { diagnostics.record(.css, "css.importMissing", path: resolved, "An imported style sheet is missing."); continue }
                    append(imported, path: resolved, media: media, loader: loader, resolve: resolve, visited: visited.union([resolved]), depth: depth + 1)
                case "namespace":
                    let parts = prelude.split(whereSeparator: \.isWhitespace).map(String.init)
                    if parts.count >= 2, let uri = Self.urlArgument(parts[1]) ?? Self.unquote(parts[1]) { namespaces[parts[0]] = uri }
                    else if parts.count == 1, let uri = Self.urlArgument(parts[0]) ?? Self.unquote(parts[0]) { namespaces[""] = uri }
                case "media":
                    guard let block else { continue }
                    if Self.evaluateMedia(prelude, media) {
                        append(block, path: path, media: media, loader: loader, resolve: resolve, visited: visited, depth: depth)
                    }
                case "font-face":
                    guard let block else { continue }
                    if let face = Self.fontFace(from: Self.parseDeclarations(block), path: path, resolve: resolve) { fontFaces.append(face) }
                case "charset", "page":
                    break
                default:
                    diagnostics.record(.css, "css.ignoredAtRule", path: path, "@\(name) is ignored.")
                }
                continue
            }
            guard let open = stripped[index...].firstIndex(of: "{") else { break }
            let selectorText = String(stripped[index..<open])
            guard let close = Self.matchingBrace(stripped, open) else { break }
            let body = String(stripped[stripped.index(after: open)..<close])
            index = stripped.index(after: close)
            let selectors = EPUBSelector.parseList(selectorText)
            for selector in selectors where !selector.isSupported {
                diagnostics.record(.css, "css.unsupportedSelector", path: path, "Selector form \(selector.unsupportedForm ?? selector.text) is not supported.")
            }
            let declarations = Self.parseDeclarations(body)
            guard !selectors.isEmpty, !declarations.isEmpty else { continue }
            rules.append(EPUBStyleRule(selectors: selectors, declarations: declarations, order: nextOrder))
            nextOrder += 1
        }
    }

    // MARK: Pieces

    static func stripComments(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "/", text.index(after: index) < text.endIndex, text[text.index(after: index)] == "*" {
                if let end = text.range(of: "*/", range: text.index(index, offsetBy: 2)..<text.endIndex) { index = end.upperBound } else { break }
                continue
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    /// Declarations split on semicolons outside parentheses and quotes.
    static func parseDeclarations(_ body: String) -> [EPUBDeclaration] {
        EPUBSelector.splitTopLevel(body, on: ";").compactMap { item in
            guard let colon = item.firstIndex(of: ":") else { return nil }
            let property = item[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = item[item.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            var important = false
            if let bang = value.range(of: "!important", options: .caseInsensitive) {
                important = true
                value = value[..<bang.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !property.isEmpty, !value.isEmpty else { return nil }
            return EPUBDeclaration(property: property, value: value, important: important)
        }
    }

    private static func readAtRule(_ text: String, from start: String.Index) -> (String, String, String?, String.Index)? {
        var index = text.index(after: start)
        var name = ""
        while index < text.endIndex, text[index].isLetter || text[index] == "-" { name.append(text[index]); index = text.index(after: index) }
        var prelude = ""
        while index < text.endIndex, text[index] != "{", text[index] != ";" { prelude.append(text[index]); index = text.index(after: index) }
        guard index < text.endIndex else { return (name, prelude.trimmingCharacters(in: .whitespaces), nil, text.endIndex) }
        if text[index] == ";" { return (name, prelude.trimmingCharacters(in: .whitespaces), nil, text.index(after: index)) }
        guard let close = matchingBrace(text, index) else { return nil }
        let block = String(text[text.index(after: index)..<close])
        return (name, prelude.trimmingCharacters(in: .whitespaces), block, text.index(after: close))
    }

    private static func matchingBrace(_ text: String, _ open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 } else if text[index] == "}" { depth -= 1; if depth == 0 { return index } }
            index = text.index(after: index)
        }
        return nil
    }

    static func urlPattern(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "url\\(\\s*([\"']?)(.*?)\\1\\s*\\)|^\\s*([\"'])(.*?)\\3", options: []),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range, in: text) else { return "" }
        return String(text[range])
    }

    static func urlArgument(_ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "url\\(\\s*([\"']?)(.*?)\\1\\s*\\)", options: []),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 2), in: text) else {
            return unquote(text.trimmingCharacters(in: .whitespaces))
        }
        return String(text[range])
    }

    static func unquote(_ text: String) -> String? {
        guard text.count >= 2, let first = text.first, first == "\"" || first == "'", text.last == first else { return nil }
        return String(text.dropFirst().dropLast())
    }

    /// `all`, `screen`, `prefers-color-scheme` and `orientation`; anything
    /// else in a query makes it false.
    static func evaluateMedia(_ query: String, _ context: EPUBMediaContext) -> Bool {
        for alternative in query.split(separator: ",") {
            var result = true
            var negate = false
            var tokens = alternative.lowercased().replacingOccurrences(of: " and ", with: " & ").split(separator: "&").map { $0.trimmingCharacters(in: .whitespaces) }
            if let first = tokens.first, first.hasPrefix("not ") { negate = true; tokens[0] = String(first.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
            if let first = tokens.first, first.hasPrefix("only ") { tokens[0] = String(first.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            for token in tokens where !token.isEmpty {
                switch token {
                case "all", "screen": continue
                case "print", "speech", "aural", "braille", "tty", "tv", "projection", "handheld", "embossed": result = false
                default:
                    let inner = token.trimmingCharacters(in: CharacterSet(charactersIn: "()")).replacingOccurrences(of: " ", with: "")
                    if inner == "prefers-color-scheme:dark" { result = result && context.isDark }
                    else if inner == "prefers-color-scheme:light" { result = result && !context.isDark }
                    else if inner == "orientation:landscape" { result = result && context.isLandscape }
                    else if inner == "orientation:portrait" { result = result && !context.isLandscape }
                    else { result = false }
                }
            }
            if negate ? !result : result { return true }
        }
        return false
    }

    static func fontFace(from declarations: [EPUBDeclaration], path: String, resolve: (String, String) -> String?) -> EPUBFontFace? {
        guard let family = declarations.first(where: { $0.property == "font-family" }).flatMap({ unquote($0.value) ?? $0.value }) else { return nil }
        var sources: [String] = []
        if let src = declarations.first(where: { $0.property == "src" })?.value {
            for candidate in EPUBSelector.splitTopLevel(src, on: ",") {
                guard let url = urlArgument(candidate), !candidate.trimmingCharacters(in: .whitespaces).hasPrefix("local("), let resolved = resolve(url, path) else { continue }
                sources.append(resolved)
            }
        }
        let weightText = declarations.first { $0.property == "font-weight" }?.value.lowercased() ?? "normal"
        let weight = weightText == "bold" || weightText == "bolder" ? 700 : Int(weightText.split(separator: " ").first ?? "") ?? 400
        let italic = (declarations.first { $0.property == "font-style" }?.value.lowercased() ?? "normal").contains("italic") || (declarations.first { $0.property == "font-style" }?.value.lowercased() ?? "").contains("oblique")
        return EPUBFontFace(family: family, sources: sources, weight: weight, italic: italic)
    }
}
