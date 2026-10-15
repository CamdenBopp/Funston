import CoreGraphics
import Foundation

/// A CSS length after the cascade: absolute points, a percentage of the
/// containing measure, or `auto`.
enum EPUBLength: Sendable, Hashable {
    case points(CGFloat)
    case percent(CGFloat)
    case auto

    /// CSS points are 4/3 of a CSS pixel; an iOS point is a CSS pixel.
    static let pointsPerCSSPoint: CGFloat = 96.0 / 72.0
    static let pointsPerInch: CGFloat = 96
    static let pointsPerCentimetre: CGFloat = 96 / 2.54
    static let pointsPerMillimetre: CGFloat = 96 / 25.4
    static let pointsPerPica: CGFloat = 16
    /// An `ex` is taken as half an em and a `ch` as half an em.
    static let exPerEm: CGFloat = 0.5

    /// Parses one length token; em and rem resolve against the sizes given.
    static func parse(_ text: String, em: CGFloat, rem: CGFloat) -> EPUBLength? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "auto" { return .auto }
        if value == "0" { return .points(0) }
        guard let unitStart = value.firstIndex(where: { !($0.isNumber || $0 == "." || $0 == "-" || $0 == "+") }) else {
            // A unitless number: px for lengths (quirks), which real books rely on.
            return Double(value).map { .points(CGFloat($0)) }
        }
        guard let number = Double(value[..<unitStart]) else { return nil }
        let amount = CGFloat(number)
        switch value[unitStart...] {
        case "px": return .points(amount)
        case "pt": return .points(amount * pointsPerCSSPoint)
        case "em": return .points(amount * em)
        case "rem": return .points(amount * rem)
        case "ex", "ch": return .points(amount * em * exPerEm)
        case "%": return .percent(amount)
        case "in": return .points(amount * pointsPerInch)
        case "cm": return .points(amount * pointsPerCentimetre)
        case "mm": return .points(amount * pointsPerMillimetre)
        case "pc": return .points(amount * pointsPerPica)
        default: return nil
        }
    }

    func resolved(against measure: CGFloat) -> CGFloat? {
        switch self {
        case .points(let value): return value
        case .percent(let value): return measure * value / 100
        case .auto: return nil
        }
    }
}

struct EPUBColor: Sendable, Hashable {
    let red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat

    static let named: [String: (CGFloat, CGFloat, CGFloat)] = [
        "black": (0, 0, 0), "white": (1, 1, 1), "red": (1, 0, 0), "green": (0, 0.5, 0), "blue": (0, 0, 1), "gray": (0.5, 0.5, 0.5), "grey": (0.5, 0.5, 0.5),
        "yellow": (1, 1, 0), "orange": (1, 0.647, 0), "purple": (0.5, 0, 0.5), "cyan": (0, 1, 1), "magenta": (1, 0, 1), "silver": (0.75, 0.75, 0.75),
        "maroon": (0.5, 0, 0), "navy": (0, 0, 0.5), "olive": (0.5, 0.5, 0), "teal": (0, 0.5, 0.5), "lime": (0, 1, 0), "aqua": (0, 1, 1), "fuchsia": (1, 0, 1),
        "brown": (0.647, 0.165, 0.165), "darkred": (0.545, 0, 0), "darkblue": (0, 0, 0.545), "darkgreen": (0, 0.392, 0), "crimson": (0.863, 0.078, 0.235),
        "gold": (1, 0.843, 0), "beige": (0.961, 0.961, 0.863), "ivory": (1, 1, 0.941), "transparent": (0, 0, 0)
    ]

    static func parse(_ text: String) -> EPUBColor? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "transparent" { return EPUBColor(red: 0, green: 0, blue: 0, alpha: 0) }
        if let named = named[value] { return EPUBColor(red: named.0, green: named.1, blue: named.2, alpha: 1) }
        if value.hasPrefix("#") {
            let hex = Array(value.dropFirst())
            func component(_ a: Character, _ b: Character) -> CGFloat? { UInt8(String([a, b]), radix: 16).map { CGFloat($0) / 255 } }
            switch hex.count {
            case 3, 4:
                guard let r = component(hex[0], hex[0]), let g = component(hex[1], hex[1]), let b = component(hex[2], hex[2]) else { return nil }
                let a = hex.count == 4 ? (component(hex[3], hex[3]) ?? 1) : 1
                return EPUBColor(red: r, green: g, blue: b, alpha: a)
            case 6, 8:
                guard let r = component(hex[0], hex[1]), let g = component(hex[2], hex[3]), let b = component(hex[4], hex[5]) else { return nil }
                let a = hex.count == 8 ? (component(hex[6], hex[7]) ?? 1) : 1
                return EPUBColor(red: r, green: g, blue: b, alpha: a)
            default: return nil
            }
        }
        if value.hasPrefix("rgb"), let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")") {
            let parts = value[value.index(after: open)..<close].replacingOccurrences(of: "/", with: ",").split(whereSeparator: { $0 == "," || $0 == " " }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard parts.count >= 3 else { return nil }
            func channel(_ part: String) -> CGFloat? {
                if part.hasSuffix("%") { return Double(part.dropLast()).map { CGFloat($0) / 100 } }
                return Double(part).map { CGFloat($0) / 255 }
            }
            guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
            var a: CGFloat = 1
            if parts.count > 3 { a = parts[3].hasSuffix("%") ? (Double(parts[3].dropLast()).map { CGFloat($0) / 100 } ?? 1) : (Double(parts[3]).map { CGFloat($0) } ?? 1) }
            return EPUBColor(red: min(1, max(0, r)), green: min(1, max(0, g)), blue: min(1, max(0, b)), alpha: min(1, max(0, a)))
        }
        return nil
    }
}

/// The properties the cascade produces for one element (Spec section 9.1).
struct EPUBComputedStyle: Sendable, Hashable {
    enum Display: String, Sendable, Hashable { case none, block, inline, listItem = "list-item", table, tableRow = "table-row", tableCell = "table-cell", tableCaption = "table-caption", tableRowGroup = "table-row-group" }
    enum TextAlign: String, Sendable, Hashable { case start, end, left, right, center, justify }
    enum TextTransform: String, Sendable, Hashable { case none, uppercase, lowercase, capitalize }
    enum WhiteSpace: String, Sendable, Hashable { case normal, pre, preWrap = "pre-wrap", preLine = "pre-line", nowrap }
    enum Hyphens: String, Sendable, Hashable { case auto, manual, none }
    enum VerticalAlign: String, Sendable, Hashable { case baseline, sub, superscript = "super", top, textTop = "text-top", middle, bottom, textBottom = "text-bottom" }
    enum Float: String, Sendable, Hashable { case none, left, right }
    enum LineHeight: Sendable, Hashable { case normal, multiple(CGFloat), length(CGFloat) }
    enum ListStyleType: String, Sendable, Hashable { case disc, circle, square, decimal, lowerAlpha = "lower-alpha", upperAlpha = "upper-alpha", lowerRoman = "lower-roman", upperRoman = "upper-roman", none }
    enum WritingMode: String, Sendable, Hashable { case horizontal = "horizontal-tb", verticalRL = "vertical-rl", verticalLR = "vertical-lr" }
    struct Decoration: OptionSet, Sendable, Hashable {
        let rawValue: Int
        static let underline = Decoration(rawValue: 1)
        static let lineThrough = Decoration(rawValue: 2)
    }
    struct Border: Sendable, Hashable {
        var width: CGFloat = 0
        var color: EPUBColor?
        var visible: Bool { width > 0 }
    }

    // Inherited.
    var fontFamilies: [String] = []
    var fontSize: CGFloat
    var fontWeight = 400
    var italic = false
    var smallCaps = false
    var textAlign: TextAlign?
    var textAlignLast: TextAlign?
    var textIndent: EPUBLength = .points(0)
    var lineHeight: LineHeight = .normal
    var textTransform: TextTransform = .none
    var letterSpacing: CGFloat?
    var wordSpacing: CGFloat?
    var whiteSpace: WhiteSpace = .normal
    var hyphens: Hyphens?
    var color: EPUBColor?
    var listStyleType: ListStyleType?
    var visibility = true
    var writingMode: WritingMode = .horizontal
    var decoration: Decoration = []

    // Not inherited.
    var display: Display = .inline
    var marginTop: EPUBLength = .points(0), marginBottom: EPUBLength = .points(0), marginLeft: EPUBLength = .points(0), marginRight: EPUBLength = .points(0)
    var paddingTop: EPUBLength = .points(0), paddingBottom: EPUBLength = .points(0), paddingLeft: EPUBLength = .points(0), paddingRight: EPUBLength = .points(0)
    var backgroundColor: EPUBColor?
    var width: EPUBLength?
    var maxWidth: EPUBLength?
    var height: EPUBLength?
    var verticalAlign: VerticalAlign = .baseline
    var float: Float = .none
    var pageBreakBefore = false
    var pageBreakAfter = false
    var keepTogether = false
    var borderTop = Border(), borderBottom = Border(), borderLeft = Border(), borderRight = Border()

    init(fontSize: CGFloat) { self.fontSize = fontSize }

    var isBlockLevel: Bool { display != .inline && display != .none }
    var hasVisibleBorder: Bool { borderTop.visible || borderBottom.visible || borderLeft.visible || borderRight.visible }

    /// The inherited properties carried into a child.
    func inherited() -> EPUBComputedStyle {
        var child = EPUBComputedStyle(fontSize: fontSize)
        child.fontFamilies = fontFamilies; child.fontWeight = fontWeight; child.italic = italic; child.smallCaps = smallCaps
        child.textAlign = textAlign; child.textAlignLast = textAlignLast; child.textIndent = textIndent; child.lineHeight = lineHeight
        child.textTransform = textTransform; child.letterSpacing = letterSpacing; child.wordSpacing = wordSpacing; child.whiteSpace = whiteSpace
        child.hyphens = hyphens; child.color = color; child.listStyleType = listStyleType; child.visibility = visibility
        child.writingMode = writingMode; child.decoration = decoration
        return child
    }
}
