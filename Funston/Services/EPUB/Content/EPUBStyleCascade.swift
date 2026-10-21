import CoreGraphics
import Foundation

/// The built-in defaults of Spec section 9.2: the HTML rendering section's
/// for the elements of 8.3, plus the Gutenberg additions (pre, code, dl,
/// center, small, big) the Yuedu study found missing.
enum EPUBUserAgentStyles {
    static let monospaceFamily = "monospace"
    static let defaultListIndent: CGFloat = 40
    static let blockquoteIndent: CGFloat = 40
    static let figureIndent: CGFloat = 40
    static let definitionIndent: CGFloat = 40
    static let captionScale: CGFloat = 0.9
    static let smallScale: CGFloat = 0.833
    static let bigScale: CGFloat = 1.2
    static let headingScales: [CGFloat] = [2, 1.5, 1.17, 1, 0.83, 0.67]
    static let headingMarginsEm: [CGFloat] = [0.67, 0.83, 1, 1.33, 1.67, 2.33]
    static let hiddenElements: Set<String> = ["head", "script", "style", "title", "meta", "link", "template", "base", "area", "datalist", "param"]
    static let blockElements: Set<String> = ["html", "body", "div", "section", "article", "aside", "nav", "header", "footer", "main", "address", "form", "fieldset",
                                             "details", "summary", "dialog", "noscript", "center", "object", "iframe", "embed", "audio", "video", "hgroup", "svg", "math"]

    /// Declarations for a tag as if written in a sheet, applied before author rules.
    static func declarations(for element: EPUBXMLDocument.NodeID, in tree: EPUBXMLDocument) -> [EPUBDeclaration] {
        let name = tree.localName(of: element)
        func make(_ pairs: [(String, String)]) -> [EPUBDeclaration] { pairs.map { EPUBDeclaration(property: $0.0, value: $0.1, important: false) } }
        if hiddenElements.contains(name) { return make([("display", "none")]) }
        if blockElements.contains(name) { return make([("display", "block")] + (name == "center" ? [("text-align", "center")] : [])) }
        switch name {
        case "p": return make([("display", "block"), ("margin", "1em 0")])
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(name.dropFirst())) ?? 1
            return make([("display", "block"), ("font-size", "\(headingScales[level - 1])em"), ("font-weight", "bold"), ("margin", "\(headingMarginsEm[level - 1])em 0")])
        case "blockquote": return make([("display", "block"), ("margin", "1em \(blockquoteIndent)px")])
        case "pre": return make([("display", "block"), ("white-space", "pre"), ("font-family", monospaceFamily), ("margin", "1em 0")])
        case "ul", "ol": return make([("display", "block"), ("margin", "1em 0"), ("padding-left", "\(defaultListIndent)px")] + (name == "ul" ? [("list-style-type", "disc")] : [("list-style-type", "decimal")]))
        case "li": return make([("display", "list-item")])
        case "dl": return make([("display", "block"), ("margin", "1em 0")])
        case "dt": return make([("display", "block")])
        case "dd": return make([("display", "block"), ("margin-left", "\(definitionIndent)px")])
        case "figure": return make([("display", "block"), ("margin", "1em \(figureIndent)px")])
        case "figcaption": return make([("display", "block"), ("text-align", "center"), ("font-size", "\(captionScale)em")])
        case "hr": return make([("display", "block"), ("margin", "0.5em auto"), ("border-top", "1px solid")])
        case "table": return make([("display", "table"), ("margin", "1em 0")])
        case "caption": return make([("display", "table-caption"), ("text-align", "center")])
        case "thead", "tbody", "tfoot": return make([("display", "table-row-group")])
        case "tr": return make([("display", "table-row")])
        case "td": return make([("display", "table-cell")])
        case "th": return make([("display", "table-cell"), ("font-weight", "bold"), ("text-align", "center")])
        case "b", "strong": return make([("font-weight", "bold")])
        case "i", "em", "cite", "var", "dfn", "address": return make([("font-style", "italic")])
        case "u", "ins": return make([("text-decoration", "underline")])
        case "s", "strike", "del": return make([("text-decoration", "line-through")])
        case "code", "kbd", "samp", "tt": return make([("font-family", monospaceFamily)])
        case "small": return make([("font-size", "smaller")])
        case "big": return make([("font-size", "larger")])
        case "sub": return make([("vertical-align", "sub"), ("font-size", "smaller")])
        case "sup": return make([("vertical-align", "super"), ("font-size", "smaller")])
        case "mark": return make([("background-color", "yellow")])
        case "img", "picture": return make([("display", "inline")])
        default: return []
        }
    }

    /// Presentational attributes, applied after the defaults and before author rules.
    static func presentationalDeclarations(for element: EPUBXMLDocument.NodeID, in tree: EPUBXMLDocument) -> [EPUBDeclaration] {
        var result: [EPUBDeclaration] = []
        let name = tree.localName(of: element)
        if let align = tree.attribute("align", of: element)?.lowercased(), ["left", "right", "center", "justify"].contains(align) {
            result.append(EPUBDeclaration(property: "text-align", value: align, important: false))
        }
        if name == "img" || name == "table" {
            if let width = tree.attribute("width", of: element), let length = numericAttribute(width) { result.append(EPUBDeclaration(property: "width", value: length, important: false)) }
            if let height = tree.attribute("height", of: element), let length = numericAttribute(height) { result.append(EPUBDeclaration(property: "height", value: length, important: false)) }
        }
        if name == "font" {
            if let face = tree.attribute("face", of: element) { result.append(EPUBDeclaration(property: "font-family", value: face, important: false)) }
            if let color = tree.attribute("color", of: element) { result.append(EPUBDeclaration(property: "color", value: color, important: false)) }
        }
        if name == "ol", let type = tree.attribute("type", of: element) {
            let style: String? = ["1": "decimal", "a": "lower-alpha", "A": "upper-alpha", "i": "lower-roman", "I": "upper-roman"][type]
            if let style { result.append(EPUBDeclaration(property: "list-style-type", value: style, important: false)) }
        }
        return result
    }

    private static func numericAttribute(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("%") { return trimmed }
        if let number = Double(trimmed) { return "\(number)px" }
        return nil
    }
}

/// Computes one style per element: user-agent defaults, presentational
/// attributes, author rules by specificity and order, inline style, author
/// `!important`, inline `!important`, then the user overrides of Spec 9.3.
struct EPUBStyleCascade: Sendable {
    static let fontSizeKeywords: [String: CGFloat] = ["xx-small": 0.5625, "x-small": 0.625, "small": 0.8125, "medium": 1, "large": 1.125, "x-large": 1.5, "xx-large": 2, "xxx-large": 3]
    static let smallerScale: CGFloat = 0.833
    static let largerScale: CGFloat = 1.2
    /// Properties whose author declarations are dropped with publisher styles off.
    static let publisherOnlyProperties: Set<String> = ["font-family", "font-size", "font", "color", "background", "background-color", "margin", "margin-top", "margin-bottom",
                                                       "margin-left", "margin-right", "padding", "padding-top", "padding-bottom", "padding-left", "padding-right",
                                                       "text-align", "text-align-last", "line-height", "letter-spacing", "word-spacing"]
    /// Properties a user alignment setting leaves alone (RDN-13).
    static let alignmentExemptElements: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6", "figcaption", "caption", "blockquote", "th", "td", "pre"]
    /// CSS forbids these in author sheets; they are ignored.
    static let ignoredByRule: Set<String> = ["direction", "unicode-bidi"]

    let settings: EPUBReadingSettings
    let sheets: [EPUBStyleSheet]

    /// Rules bucketed by the rightmost compound's type, for fast matching.
    private let rulesByType: [String: [(rule: EPUBStyleRule, selector: EPUBSelector, sheet: Int)]]
    private let namespacesBySheet: [[String: String]]

    init(settings: EPUBReadingSettings, sheets: [EPUBStyleSheet]) {
        self.settings = settings
        self.sheets = sheets
        var buckets: [String: [(EPUBStyleRule, EPUBSelector, Int)]] = [:]
        for (sheetIndex, sheet) in sheets.enumerated() {
            for rule in sheet.rules {
                for selector in rule.selectors where selector.isSupported {
                    let key = selector.compounds.last?.type ?? "*"
                    buckets[key, default: []].append((rule, selector, sheetIndex))
                }
            }
        }
        rulesByType = buckets
        namespacesBySheet = sheets.map(\.namespaces)
    }

    /// Styles for every node in document order (character data inherits its parent's).
    func resolve(_ document: EPUBContentDocument, diagnostics: inout EPUBDiagnosticList) -> [EPUBComputedStyle] {
        let tree = document.tree
        var styles: [EPUBComputedStyle] = []
        styles.reserveCapacity(tree.nodes.count)
        var ignoredProperties: [String: Int] = [:]
        for id in 0..<tree.nodes.count {
            let node = tree.nodes[id]
            let parentStyle = node.parent.map { styles[$0] }
            guard node.isElement else {
                styles.append(parentStyle ?? EPUBComputedStyle(fontSize: settings.baseFontSize))
                continue
            }
            var style = parentStyle?.inherited() ?? EPUBComputedStyle(fontSize: settings.baseFontSize)
            let parentSize = parentStyle?.fontSize ?? settings.baseFontSize
            let name = node.name
            var declarations: [(EPUBDeclaration, Int)] = []
            for declaration in EPUBUserAgentStyles.declarations(for: id, in: tree) { declarations.append((declaration, 0)) }
            for declaration in EPUBUserAgentStyles.presentationalDeclarations(for: id, in: tree) { declarations.append((declaration, 1)) }
            // Author rules sorted by specificity then order.
            var matched: [(EPUBSelector.Specificity, Int, Int, EPUBStyleRule)] = []
            for key in [name, "*"] {
                for candidate in rulesByType[key] ?? [] where candidate.selector.matches(id, in: tree, namespaces: namespacesBySheet[candidate.sheet]) {
                    matched.append((candidate.selector.specificity, candidate.sheet, candidate.rule.order, candidate.rule))
                }
            }
            matched.sort { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }
            var important: [EPUBDeclaration] = []
            for (_, _, _, rule) in matched {
                for declaration in rule.declarations {
                    if declaration.important { important.append(declaration) } else { declarations.append((declaration, 2)) }
                }
            }
            var inlineImportant: [EPUBDeclaration] = []
            if let inline = tree.attribute("style", of: id) {
                for declaration in EPUBStyleSheet.parseDeclarations(inline) {
                    if declaration.important { inlineImportant.append(declaration) } else { declarations.append((declaration, 3)) }
                }
            }
            for declaration in important { declarations.append((declaration, 4)) }
            for declaration in inlineImportant { declarations.append((declaration, 5)) }

            // Font size first, so em lengths resolve against the element's own size.
            let effective = declarations.filter { settings.publisherStyles || $0.1 < 2 || !Self.publisherOnlyProperties.contains($0.0.property) }
            if let sizeDeclaration = effective.last(where: { $0.0.property == "font-size" || $0.0.property == "font" }) {
                if sizeDeclaration.0.property == "font" { Self.applyFontShorthand(sizeDeclaration.0.value, to: &style, parentSize: parentSize, settings: settings, sizeOnly: true) }
                else { style.fontSize = Self.fontSize(sizeDeclaration.0.value, parentSize: parentSize, settings: settings) ?? style.fontSize }
            }
            if !settings.publisherStyles {
                style.fontSize = Self.normalisedSize(for: name, parentSize: parentSize, inherited: style.fontSize, settings: settings, tree: tree, id: id)
            }
            style.fontSize = min(max(style.fontSize, settings.baseFontSize * EPUBReadingSettings.minimumSizeFactor), settings.baseFontSize * EPUBReadingSettings.maximumSizeFactor)
            for (declaration, _) in effective where declaration.property != "font-size" {
                if Self.ignoredByRule.contains(declaration.property) { continue }
                if !Self.apply(declaration, to: &style, parentSize: parentSize, settings: settings) {
                    ignoredProperties[declaration.property, default: 0] += 1
                }
            }
            // User overrides.
            if settings.alignment == .justify, style.isBlockLevel, !Self.alignmentExemptElements.contains(name) {
                style.textAlign = .justify
            } else if !settings.publisherStyles, style.isBlockLevel, !Self.alignmentExemptElements.contains(name), name != "center", tree.attribute("align", of: id) == nil {
                style.textAlign = style.textAlign == .center ? .center : nil
            }
            if let hyphenation = settings.hyphenation { style.hyphens = hyphenation ? .auto : .none }
            if document.hidden[id] { style.display = .none }
            styles.append(style)
        }
        for (property, count) in ignoredProperties.sorted(by: { $0.key < $1.key }) {
            diagnostics.record(EPUBDiagnostic(stage: .css, code: "css.ignoredProperty", path: document.path, message: "The property \(property) is not honoured.", count: count))
        }
        return styles
    }

    /// RDN-12 with publisher styles off: body copy at the base, headings on
    /// the type scale, sub and sup at 67.5 percent, small and big relative.
    private static func normalisedSize(for name: String, parentSize: CGFloat, inherited: CGFloat, settings: EPUBReadingSettings, tree: EPUBXMLDocument, id: EPUBXMLDocument.NodeID) -> CGFloat {
        let base = settings.baseFontSize
        switch name {
        case "h1": return base * pow(EPUBReadingSettings.headingTypeScale, 3)
        case "h2": return base * pow(EPUBReadingSettings.headingTypeScale, 2)
        case "h3": return base * EPUBReadingSettings.headingTypeScale
        case "h4", "h5", "h6": return base
        case "sub", "sup": return parentSize * EPUBReadingSettings.subSuperscriptScale
        case "small": return parentSize * smallerScale
        case "big": return parentSize * largerScale
        case "figcaption", "caption": return base * EPUBUserAgentStyles.captionScale
        case "p", "li", "div", "dd", "dt", "td", "th", "body", "blockquote", "section", "article", "pre", "figure", "aside", "header", "footer", "main", "nav", "html":
            return base
        default:
            return inherited
        }
    }

    static func fontSize(_ value: String, parentSize: CGFloat, settings: EPUBReadingSettings) -> CGFloat? {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        if let keyword = fontSizeKeywords[text] { return settings.baseFontSize * keyword }
        if text == "smaller" { return parentSize * smallerScale }
        if text == "larger" { return parentSize * largerScale }
        guard let length = EPUBLength.parse(text, em: parentSize, rem: settings.baseFontSize) else { return nil }
        switch length {
        case .points(let points): return points
        case .percent(let percent): return parentSize * percent / 100
        case .auto: return nil
        }
    }

    private static func applyFontShorthand(_ value: String, to style: inout EPUBComputedStyle, parentSize: CGFloat, settings: EPUBReadingSettings, sizeOnly: Bool) {
        // [style weight variant] size[/line-height] family
        let withoutFamily: String
        var familyText: String?
        let tokens = value.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if let sizeIndex = tokens.firstIndex(where: { fontSize($0.split(separator: "/").first.map(String.init) ?? "", parentSize: parentSize, settings: settings) != nil && $0.first.map({ $0.isNumber || ["x", "s", "m", "l"].contains($0) }) == true && !["normal", "italic", "oblique", "bold", "bolder", "lighter", "small-caps"].contains($0) }) {
            withoutFamily = tokens[...sizeIndex].joined(separator: " ")
            familyText = tokens[(sizeIndex + 1)...].joined(separator: " ")
        } else {
            withoutFamily = value
        }
        let parts = withoutFamily.split(separator: " ").map(String.init)
        for part in parts {
            let pieces = part.split(separator: "/").map(String.init)
            if let size = fontSize(pieces[0], parentSize: parentSize, settings: settings) {
                style.fontSize = size
                if pieces.count > 1, !sizeOnly { style.lineHeight = lineHeight(pieces[1], fontSize: size, settings: settings) ?? style.lineHeight }
            } else if !sizeOnly {
                switch part.lowercased() {
                case "italic", "oblique": style.italic = true
                case "bold", "bolder": style.fontWeight = 700
                case "small-caps": style.smallCaps = true
                case "normal": break
                default: if let weight = Int(part) { style.fontWeight = weight }
                }
            }
        }
        if !sizeOnly, let familyText, !familyText.isEmpty { style.fontFamilies = families(familyText) }
    }

    static func families(_ value: String) -> [String] {
        EPUBSelector.splitTopLevel(value, on: ",").map { ($0.trimmingCharacters(in: .whitespaces)).replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "") }
    }

    static func lineHeight(_ value: String, fontSize: CGFloat, settings: EPUBReadingSettings) -> EPUBComputedStyle.LineHeight? {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        if text == "normal" { return .normal }
        if let number = Double(text) { return .multiple(CGFloat(number)) }
        guard let length = EPUBLength.parse(text, em: fontSize, rem: settings.baseFontSize) else { return nil }
        switch length {
        case .points(let points): return .length(points)
        case .percent(let percent): return .multiple(percent / 100)
        case .auto: return nil
        }
    }

    /// Applies one declaration; false when the property is not honoured.
    static func apply(_ declaration: EPUBDeclaration, to style: inout EPUBComputedStyle, parentSize: CGFloat, settings: EPUBReadingSettings) -> Bool {
        let value = declaration.value.trimmingCharacters(in: .whitespaces)
        let lower = value.lowercased()
        func length(_ text: String) -> EPUBLength? { EPUBLength.parse(text, em: style.fontSize, rem: settings.baseFontSize) }
        func sides(_ text: String) -> [EPUBLength]? {
            let parts = text.split(separator: " ").map(String.init).compactMap(length)
            guard !parts.isEmpty, parts.count <= 4 else { return nil }
            switch parts.count {
            case 1: return [parts[0], parts[0], parts[0], parts[0]]
            case 2: return [parts[0], parts[1], parts[0], parts[1]]
            case 3: return [parts[0], parts[1], parts[2], parts[1]]
            default: return parts
            }
        }
        switch declaration.property {
        case "display":
            switch lower {
            case "none": style.display = .none
            case "block", "flex", "grid", "flow-root": style.display = .block
            case "inline", "inline-block", "inline-flex", "inline-grid", "inline-table": style.display = .inline
            case "list-item": style.display = .listItem
            case "table": style.display = .table
            case "table-row": style.display = .tableRow
            case "table-cell": style.display = .tableCell
            case "table-caption": style.display = .tableCaption
            case "table-row-group", "table-header-group", "table-footer-group": style.display = .tableRowGroup
            default: return false
            }
        case "font-family": style.fontFamilies = families(value)
        case "font-weight":
            switch lower {
            case "bold": style.fontWeight = 700
            case "bolder": style.fontWeight = min(900, style.fontWeight + 300)
            case "lighter": style.fontWeight = max(100, style.fontWeight - 300)
            case "normal": style.fontWeight = 400
            default: guard let weight = Int(lower), (1...1000).contains(weight) else { return false }; style.fontWeight = weight
            }
        case "font-style": style.italic = lower.contains("italic") || lower.contains("oblique")
        case "font-variant", "font-variant-caps": style.smallCaps = lower.contains("small-caps")
        case "font": applyFontShorthand(value, to: &style, parentSize: parentSize, settings: settings, sizeOnly: false)
        case "text-align":
            guard let align = EPUBComputedStyle.TextAlign(rawValue: lower) else { return false }
            style.textAlign = align
        case "text-align-last":
            guard let align = EPUBComputedStyle.TextAlign(rawValue: lower) else { return false }
            style.textAlignLast = align
        case "text-indent": guard let indent = length(value) else { return false }; style.textIndent = indent
        case "margin": guard let values = sides(value) else { return false }; (style.marginTop, style.marginRight, style.marginBottom, style.marginLeft) = (values[0], values[1], values[2], values[3])
        case "margin-top": guard let v = length(value) else { return false }; style.marginTop = v
        case "margin-bottom": guard let v = length(value) else { return false }; style.marginBottom = v
        case "margin-left", "margin-inline-start": guard let v = length(value) else { return false }; style.marginLeft = v
        case "margin-right", "margin-inline-end": guard let v = length(value) else { return false }; style.marginRight = v
        case "padding": guard let values = sides(value) else { return false }; (style.paddingTop, style.paddingRight, style.paddingBottom, style.paddingLeft) = (values[0], values[1], values[2], values[3])
        case "padding-top": guard let v = length(value) else { return false }; style.paddingTop = v
        case "padding-bottom": guard let v = length(value) else { return false }; style.paddingBottom = v
        case "padding-left", "padding-inline-start": guard let v = length(value) else { return false }; style.paddingLeft = v
        case "padding-right", "padding-inline-end": guard let v = length(value) else { return false }; style.paddingRight = v
        case "line-height": guard let height = lineHeight(value, fontSize: style.fontSize, settings: settings) else { return false }; style.lineHeight = height
        case "text-decoration", "text-decoration-line":
            var decoration: EPUBComputedStyle.Decoration = []
            if lower.contains("underline") { decoration.insert(.underline) }
            if lower.contains("line-through") { decoration.insert(.lineThrough) }
            style.decoration = decoration
        case "text-transform": guard let transform = EPUBComputedStyle.TextTransform(rawValue: lower) else { return false }; style.textTransform = transform
        case "letter-spacing": if lower == "normal" { style.letterSpacing = nil } else { guard case .points(let v)? = length(value) else { return false }; style.letterSpacing = v }
        case "word-spacing": if lower == "normal" { style.wordSpacing = nil } else { guard case .points(let v)? = length(value) else { return false }; style.wordSpacing = v }
        case "white-space": guard let space = EPUBComputedStyle.WhiteSpace(rawValue: lower) else { return false }; style.whiteSpace = space
        case "hyphens", "-epub-hyphens", "-webkit-hyphens": guard let hyphens = EPUBComputedStyle.Hyphens(rawValue: lower) else { return false }; style.hyphens = hyphens
        case "color": guard let color = EPUBColor.parse(value) else { return false }; style.color = color
        case "background-color": guard let color = EPUBColor.parse(value) else { return false }; style.backgroundColor = color
        case "background":
            if let color = value.split(separator: " ").compactMap({ EPUBColor.parse(String($0)) }).first { style.backgroundColor = color } else { return false }
        case "width": guard let v = length(value) else { return false }; style.width = v
        case "max-width": guard let v = length(value) else { return false }; style.maxWidth = v
        case "height": guard let v = length(value) else { return false }; style.height = v
        case "vertical-align": guard let align = EPUBComputedStyle.VerticalAlign(rawValue: lower) else { return false }; style.verticalAlign = align
        case "float": guard let float = EPUBComputedStyle.Float(rawValue: lower) else { return false }; style.float = float
        case "visibility": style.visibility = lower != "hidden" && lower != "collapse"
        case "page-break-before", "break-before": style.pageBreakBefore = ["always", "page", "left", "right", "recto", "verso"].contains(lower)
        case "page-break-after", "break-after": style.pageBreakAfter = ["always", "page", "left", "right", "recto", "verso"].contains(lower)
        case "page-break-inside", "break-inside": style.keepTogether = lower == "avoid" || lower == "avoid-page"
        case "list-style-type": guard let type = EPUBComputedStyle.ListStyleType(rawValue: lower) else { return lower == "none" ? { style.listStyleType = EPUBComputedStyle.ListStyleType.none; return true }() : false }; style.listStyleType = type
        case "list-style":
            if lower.contains("none") { style.listStyleType = EPUBComputedStyle.ListStyleType.none }
            else if let type = lower.split(separator: " ").compactMap({ EPUBComputedStyle.ListStyleType(rawValue: String($0)) }).first { style.listStyleType = type }
        case "writing-mode", "-epub-writing-mode", "-webkit-writing-mode":
            guard let mode = EPUBComputedStyle.WritingMode(rawValue: lower) ?? (lower == "tb-rl" ? .verticalRL : nil) else { return false }
            style.writingMode = mode
        case "border", "border-top", "border-bottom", "border-left", "border-right":
            let border = parseBorder(value, fontSize: style.fontSize, settings: settings)
            switch declaration.property {
            case "border": style.borderTop = border; style.borderBottom = border; style.borderLeft = border; style.borderRight = border
            case "border-top": style.borderTop = border
            case "border-bottom": style.borderBottom = border
            case "border-left": style.borderLeft = border
            default: style.borderRight = border
            }
        case "border-width":
            guard let values = sides(value) else { return false }
            style.borderTop.width = values[0].resolved(against: 0) ?? 0; style.borderRight.width = values[1].resolved(against: 0) ?? 0
            style.borderBottom.width = values[2].resolved(against: 0) ?? 0; style.borderLeft.width = values[3].resolved(against: 0) ?? 0
        case "border-style":
            if lower == "none" || lower == "hidden" { style.borderTop.width = 0; style.borderBottom.width = 0; style.borderLeft.width = 0; style.borderRight.width = 0 }
        case "border-color":
            if let color = EPUBColor.parse(value) { style.borderTop.color = color; style.borderBottom.color = color; style.borderLeft.color = color; style.borderRight.color = color }
        case "position", "top", "left", "right", "bottom", "z-index", "overflow", "clear", "opacity", "text-shadow", "box-shadow", "columns", "column-count", "outline", "cursor",
             "border-radius", "box-sizing", "orphans", "widows", "min-height", "min-width", "max-height", "quotes", "content", "counter-reset", "counter-increment",
             "text-wrap", "font-variant-numeric", "font-feature-settings", "font-kerning", "hanging-punctuation", "word-break", "overflow-wrap", "word-wrap",
             "-epub-line-break", "-epub-word-break", "-epub-text-transform", "line-break", "tab-size", "background-image", "background-size", "background-position",
             "background-repeat", "adobe-hyphenate", "-moz-hyphens", "-ms-hyphens", "text-rendering", "speak", "list-style-position", "list-style-image", "table-layout",
             "border-collapse", "border-spacing", "empty-cells", "vertical-align-last", "text-emphasis", "-epub-text-emphasis", "text-underline-position",
             "-epub-text-underline-position", "text-orientation", "-epub-text-orientation", "text-combine-upright", "-epub-text-combine-horizontal", "font-stretch",
             "font-display", "src", "unicode-range", "filter", "transform", "transition", "animation", "will-change", "page", "size", "float-offset", "clip", "resize":
            return false
        default:
            return false
        }
        return true
    }

    static func parseBorder(_ value: String, fontSize: CGFloat, settings: EPUBReadingSettings) -> EPUBComputedStyle.Border {
        var border = EPUBComputedStyle.Border(width: 1, color: nil)
        var sawWidth = false
        for token in value.split(separator: " ").map(String.init) {
            let lower = token.lowercased()
            if lower == "none" || lower == "hidden" { return EPUBComputedStyle.Border() }
            if ["solid", "dashed", "dotted", "double", "groove", "ridge", "inset", "outset"].contains(lower) { continue }
            if lower == "thin" { border.width = 1; sawWidth = true; continue }
            if lower == "medium" { border.width = 3; sawWidth = true; continue }
            if lower == "thick" { border.width = 5; sawWidth = true; continue }
            if case .points(let points)? = EPUBLength.parse(token, em: fontSize, rem: settings.baseFontSize) { border.width = points; sawWidth = true; continue }
            if let color = EPUBColor.parse(token) { border.color = color }
        }
        _ = sawWidth
        return border
    }
}
