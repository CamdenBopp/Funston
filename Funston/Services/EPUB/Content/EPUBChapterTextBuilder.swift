import Foundation
import UIKit

/// The geometry a text build needs: the column width for indents and image
/// clamping, and the tallest image a page can hold.
struct EPUBTextGeometry: Sendable, Hashable {
    var columnWidth: CGFloat
    var maximumImageHeight: CGFloat
}

/// Turns a parsed, styled chapter into one attributed string with its run
/// table and block list (Spec section 10). The string's characters depend only
/// on the content and the parser version; settings and geometry change
/// attributes alone, so offsets stay valid across every layout.
struct EPUBChapterTextBuilder {
    static let lineSeparator: Character = "\u{2028}"
    static let lineSeparatorUnit: unichar = 0x2028
    static let paragraphSeparator = "\n"
    static let attachmentCharacter = "\u{FFFC}"
    static let thoughtBreakText = "\u{00A0}"
    static let noBreakSpace: Unicode.Scalar = "\u{00A0}"
    static let ideographicSpace: Unicode.Scalar = "\u{3000}"
    /// Horizontal margins are clamped so at least this fraction of the column remains.
    static let minimumMeasureFraction: CGFloat = 0.6
    static let superscriptBaselineFactor: CGFloat = 0.33
    static let subscriptBaselineFactor: CGFloat = -0.2
    static let listMarkerGap = " "
    static let bulletMarkers: [EPUBComputedStyle.ListStyleType: String] = [.disc: "\u{2022}", .circle: "\u{25E6}", .square: "\u{25AA}"]
    static let rightToLeftLanguages: Set<String> = ["ar", "arc", "ckb", "dv", "fa", "ha", "he", "iw", "khw", "ks", "ku", "nqo", "prs", "ps", "sd", "syr", "ug", "ur", "yi"]
    static let noteReferenceClasses = ["fnanchor", "noteref"]
    static let noteTargetPrefixes = ["Footnote_", "fn", "note"]
    static let noteContainerClassFragments = ["footnote", "note"]
    static let monospaceFamilies: Set<String> = ["monospace", "courier", "courier new", "menlo", "consolas", "monaco", "lucida console", "ui-monospace"]
    static let mediaElements: Set<String> = ["audio", "video", "object", "iframe", "embed", "canvas"]

    let document: EPUBContentDocument
    let styles: [EPUBComputedStyle]
    let settings: EPUBReadingSettings
    let geometry: EPUBTextGeometry
    let fonts: EPUBFontRegistry
    let images: EPUBImageCatalog?
    let resolveLink: (String) -> EPUBLinkTarget?
    let resolveImagePath: (String) -> String?

    // MARK: State

    private final class Frame {
        let node: EPUBXMLDocument.NodeID
        let style: EPUBComputedStyle
        var headIndent: CGFloat
        var tailIndent: CGFloat
        var containerIndices: [Int]
        var listCounter: Int
        var listReversed = false
        var listStyle: EPUBComputedStyle.ListStyleType?
        var listOrdinal: Int?
        var listMarker: String?
        var tableRow = -1
        var tableColumn = -1
        var tableMaxColumns = 0
        var tableHasHeader = false
        var forcedBreakBefore: Bool
        var keepTogether: Bool
        var kind: EPUBBlock.Kind
        var pendingSpaceBefore: CGFloat
        var spaceAfter: CGFloat
        var openedParagraph = false

        init(node: EPUBXMLDocument.NodeID, style: EPUBComputedStyle, headIndent: CGFloat, tailIndent: CGFloat, containerIndices: [Int], listCounter: Int, forcedBreakBefore: Bool, keepTogether: Bool, kind: EPUBBlock.Kind, pendingSpaceBefore: CGFloat, spaceAfter: CGFloat) {
            self.node = node; self.style = style; self.headIndent = headIndent; self.tailIndent = tailIndent; self.containerIndices = containerIndices
            self.listCounter = listCounter; self.forcedBreakBefore = forcedBreakBefore; self.keepTogether = keepTogether; self.kind = kind
            self.pendingSpaceBefore = pendingSpaceBefore; self.spaceAfter = spaceAfter
        }
    }

    private struct OpenParagraph {
        let start: Int
        let frame: Frame
        let node: EPUBXMLDocument.NodeID
        var elementID: String?
        var kind: EPUBBlock.Kind
        var alternativeText: String?
        var links: [EPUBLinkRange] = []
        var noteReferences: [EPUBLinkRange] = []
        var isAccessible = true
        var hasText = false
        var hasImage = false
        var spaceBefore: CGFloat
        var forcedBreakBefore: Bool
        var direction: EPUBContentDocument.Direction?
        var language: String?
        var pendingElementIDs: [String] = []
        /// The synthesised list marker and gap this paragraph opens with.
        var markerText: String?

        var isHeading: Bool {
            if case .heading = kind { return true }
            return false
        }
    }

    private final class State {
        let text = NSMutableAttributedString()
        var buffer = ""
        var bufferAttributes: [NSAttributedString.Key: Any] = [:]
        var runs: [EPUBTextRun] = []
        var currentRun: (node: EPUBXMLDocument.NodeID, sourceOffset: Int, renderedStart: Int, length: Int)?
        var blocks: [EPUBBlock] = []
        var containers: [EPUBContainer] = []
        var links: [EPUBLinkTarget] = []
        var images: [EPUBImagePlacement] = []
        var pageBreaks: [EPUBPageBreak] = []
        var anchors: [String: Int] = [:]
        var diagnostics = EPUBDiagnosticList()
        var paragraph: OpenParagraph?
        var frames: [Frame] = []
        var pendingSpace = false
        var pendingSpaceInline: InlineContext?
        var atParagraphStart = true
        var lastSpaceAfter: CGFloat = 0
        var pendingForcedBreak = false
        var pendingElementIDs: [String] = []
        var imageCount = 0
        var textCharacterCount = 0

        var renderedLength: Int { text.length + buffer.utf16.count }
    }

    // MARK: Build

    func build() -> EPUBChapterText {
        let state = State()
        let chapterLanguage = document.body.flatMap { document.languages[$0] } ?? document.languages.first ?? nil
        if let body = document.body {
            let bodyStyle = styles[body]
            let root = Frame(node: body, style: bodyStyle, headIndent: 0, tailIndent: 0, containerIndices: [], listCounter: 0,
                             forcedBreakBefore: false, keepTogether: false, kind: .paragraph, pendingSpaceBefore: 0, spaceAfter: 0)
            state.frames.append(root)
            for child in document.tree.children(of: body) { walk(child, state: state, inline: InlineContext(style: bodyStyle, language: chapterLanguage)) }
            closeParagraph(state)
        }
        flushRun(state)
        flushBuffer(state)
        let isImagePage = state.textCharacterCount == 0 && state.imageCount == 1
        return EPUBChapterText(string: NSAttributedString(attributedString: state.text), runTable: EPUBRunTable(runs: state.runs), blocks: state.blocks,
                               containers: state.containers, links: state.links, images: state.images, pageBreaks: state.pageBreaks, anchors: state.anchors,
                               language: chapterLanguage, title: document.titleText, diagnostics: state.diagnostics, isImagePage: isImagePage)
    }

    private struct InlineContext {
        var style: EPUBComputedStyle
        var language: String?
        var linkIndex: Int?
        var isNoteReference = false
        var verticalAlign: EPUBComputedStyle.VerticalAlign = .baseline
        var inRuby = false
    }

    private func walk(_ id: EPUBXMLDocument.NodeID, state: State, inline: InlineContext) {
        let tree = document.tree
        let node = tree[id]
        if node.isCharacterData {
            emitText(node.text, node: id, state: state, inline: inline)
            return
        }
        let style = styles[id]
        if document.hidden[id] || style.display == .none || document.isNeverRendered(id) { return }
        let name = node.name
        var context = inline
        context.style = style
        context.language = document.languages[id] ?? inline.language
        if style.verticalAlign == .sub || style.verticalAlign == .superscript { context.verticalAlign = style.verticalAlign }
        if let elementID = tree.id(of: id) {
            if state.paragraph != nil, !style.isBlockLevel { state.anchors[elementID] = state.renderedLength } else { state.pendingElementIDs.append(elementID) }
        }
        if let label = document.pageBreakLabel(of: id) {
            state.pageBreaks.append(EPUBPageBreak(label: label, renderedOffset: state.renderedLength))
            if tree.collapsedText(of: id).isEmpty { return }
        }
        switch name {
        case "br":
            emitLineBreak(state: state, inline: context); return
        case "wbr":
            return
        case "img", "image":
            emitImage(id, state: state, inline: context); return
        case "picture":
            if let image = tree.childElements(of: id).first(where: { tree.localName(of: $0) == "img" }) { emitImage(image, state: state, inline: context) }
            return
        case "svg":
            emitSVGPlaceholder(id, state: state, inline: context); return
        case "math":
            emitMath(id, state: state, inline: context); return
        case "hr":
            emitThoughtBreak(id, state: state); return
        case "rt":
            emitSynthetic(" (", state: state, inline: context)
            for child in tree.children(of: id) { walk(child, state: state, inline: context) }
            emitSynthetic(")", state: state, inline: context)
            return
        case "rp":
            return
        case "a":
            if let href = tree.attribute("href", of: id), let target = resolveLink(href) {
                state.links.append(target)
                context.linkIndex = state.links.count - 1
                context.isNoteReference = isNoteReference(id, href: href)
                if case .refused = target { state.diagnostics.record(.chapterParse, "link.refused", path: document.path, "A link with a forbidden scheme was kept as text.") }
            }
        default:
            break
        }
        if Self.mediaElements.contains(name) {
            emitMediaFallback(id, state: state, inline: context); return
        }
        if style.isBlockLevel {
            openFrame(id, style: style, state: state, inline: context)
            for child in tree.children(of: id) { walk(child, state: state, inline: context) }
            closeFrame(id, state: state)
        } else {
            for child in tree.children(of: id) { walk(child, state: state, inline: context) }
        }
    }

    // MARK: Frames and paragraphs

    private func openFrame(_ id: EPUBXMLDocument.NodeID, style: EPUBComputedStyle, state: State, inline: InlineContext) {
        let tree = document.tree
        closeParagraph(state)
        let parent = state.frames.last
        let em = style.fontSize
        func resolved(_ length: EPUBLength) -> CGFloat { length.resolved(against: geometry.columnWidth) ?? 0 }
        var head = (parent?.headIndent ?? 0) + max(0, resolved(style.marginLeft) + resolved(style.paddingLeft))
        var tail = (parent?.tailIndent ?? 0) + max(0, resolved(style.marginRight) + resolved(style.paddingRight))
        let available = geometry.columnWidth - head - tail
        let minimum = geometry.columnWidth * Self.minimumMeasureFraction
        if available < minimum {
            let excess = minimum - available
            let total = head + tail
            if total > 0 {
                head -= excess * head / total
                tail -= excess * tail / total
            }
        }
        var kind: EPUBBlock.Kind = parent?.kind ?? .paragraph
        switch tree.localName(of: id) {
        case "h1", "h2", "h3", "h4", "h5", "h6": kind = .heading(level: Int(String(tree.localName(of: id).dropFirst())) ?? 1)
        case "pre": kind = .preformatted
        case "blockquote": kind = .quotation
        case "figcaption", "caption": kind = .caption
        case "li": kind = .listItem(ordinal: nil)
        case "td", "th": kind = .tableCell(row: 0, column: 0, isHeader: tree.localName(of: id) == "th")
        case "p", "div", "section", "article", "body", "header", "footer", "main", "nav", "center", "details", "summary", "address", "dt", "dd", "dl", "figure", "aside", "table", "tr", "tbody", "thead", "tfoot", "ul", "ol", "hgroup":
            if case .listItem = kind, ["p", "div"].contains(tree.localName(of: id)) { kind = .listItem(ordinal: nil) } else if ["p", "div", "section", "article", "dt", "dd", "center", "details", "summary", "address", "header", "footer", "main", "nav", "hgroup"].contains(tree.localName(of: id)), kind != .quotation, kind != .noteBody { if case .tableCell = kind {} else { kind = .paragraph } }
        default: break
        }
        if document.isNoteBody(id) { kind = .noteBody }
        let frame = Frame(node: id, style: style, headIndent: head, tailIndent: tail, containerIndices: parent?.containerIndices ?? [], listCounter: parent?.listCounter ?? 0,
                          forcedBreakBefore: style.pageBreakBefore || state.pendingForcedBreak, keepTogether: style.keepTogether || (parent?.keepTogether ?? false),
                          kind: kind, pendingSpaceBefore: max(state.lastSpaceAfter, resolved(style.marginTop) + resolved(style.paddingTop)),
                          spaceAfter: resolved(style.marginBottom) + resolved(style.paddingBottom))
        state.pendingForcedBreak = false
        state.lastSpaceAfter = 0
        let name = tree.localName(of: id)
        if case .listItem = kind, name != "li" { frame.listOrdinal = parent?.listOrdinal }
        switch name {
        case "ul", "ol", "dl":
            let ordered = name == "ol"
            let items = tree.childElements(of: id).filter { ["li", "dt", "dd"].contains(tree.localName(of: $0)) }.count
            state.containers.append(EPUBContainer(range: NSRange(location: state.renderedLength, length: 0), node: id, kind: .list(itemCount: items, ordered: ordered), label: nil))
            frame.containerIndices.append(state.containers.count - 1)
            frame.listStyle = style.listStyleType ?? (ordered ? .decimal : .disc)
            frame.listReversed = tree.attribute("reversed", of: id) != nil
            let start = tree.attribute("start", of: id).flatMap { Int($0) } ?? (frame.listReversed ? items : 1)
            frame.listCounter = start - (frame.listReversed ? -1 : 1)
        case "li":
            if let list = parent, list.listStyle != nil {
                if let value = tree.attribute("value", of: id).flatMap({ Int($0) }) { list.listCounter = value } else { list.listCounter += list.listReversed ? -1 : 1 }
                frame.listOrdinal = list.listStyle == EPUBComputedStyle.ListStyleType.none ? nil : list.listCounter
                frame.listMarker = Self.marker(for: list.listStyle ?? .disc, ordinal: list.listCounter, style: style)
                frame.kind = .listItem(ordinal: frame.listOrdinal)
                frame.listCounter = list.listCounter
            }
        case "table":
            state.containers.append(EPUBContainer(range: NSRange(location: state.renderedLength, length: 0), node: id, kind: .table(rows: 0, columns: 0, isLayout: false), label: tree.attribute("summary", of: id)))
            frame.containerIndices.append(state.containers.count - 1)
        case "tr":
            if let table = state.frames.last(where: { tree.localName(of: $0.node) == "table" }) { table.tableRow += 1; table.tableColumn = -1 }
        case "td", "th":
            if let table = state.frames.last(where: { tree.localName(of: $0.node) == "table" }) {
                table.tableColumn += 1
                table.tableMaxColumns = max(table.tableMaxColumns, table.tableColumn + 1)
                if name == "th" { table.tableHasHeader = true }
                frame.kind = .tableCell(row: max(0, table.tableRow), column: table.tableColumn, isHeader: name == "th")
            }
        case "figure":
            state.containers.append(EPUBContainer(range: NSRange(location: state.renderedLength, length: 0), node: id, kind: .figure, label: nil))
            frame.containerIndices.append(state.containers.count - 1)
        case "aside":
            if !document.isNoteBody(id) {
                state.containers.append(EPUBContainer(range: NSRange(location: state.renderedLength, length: 0), node: id, kind: .aside, label: nil))
                frame.containerIndices.append(state.containers.count - 1)
            }
        default:
            break
        }
        if document.isNoteBody(id) {
            let label = noteLabel(for: id)
            state.containers.append(EPUBContainer(range: NSRange(location: state.renderedLength, length: 0), node: id, kind: .note(label: label), label: label))
            frame.containerIndices.append(state.containers.count - 1)
        }
        state.frames.append(frame)
        state.pendingSpace = false
        state.atParagraphStart = true
    }

    private func closeFrame(_ id: EPUBXMLDocument.NodeID, state: State) {
        closeParagraph(state)
        guard let frame = state.frames.popLast() else { return }
        for index in frame.containerIndices where state.containers[index].node == id {
            let start = state.containers[index].range.location
            state.containers[index].range = NSRange(location: start, length: state.renderedLength - start)
            if case .table = state.containers[index].kind {
                let rows = frame.tableRow + 1, columns = frame.tableMaxColumns
                state.containers[index].kind = .table(rows: rows, columns: columns, isLayout: !frame.tableHasHeader && (rows <= 1 || columns <= 1))
            }
        }
        state.lastSpaceAfter = max(state.lastSpaceAfter, frame.spaceAfter)
        if frame.style.pageBreakAfter { state.pendingForcedBreak = true }
        state.pendingSpace = false
        state.atParagraphStart = true
    }

    /// Opens the paragraph that receives inline content for the innermost frame.
    private func ensureParagraph(_ state: State, inline: InlineContext) {
        guard state.paragraph == nil, let frame = state.frames.last else { return }
        flushBuffer(state)
        var paragraph = OpenParagraph(start: state.renderedLength, frame: frame, node: frame.node, elementID: nil, kind: frame.kind, alternativeText: nil,
                                      spaceBefore: frame.openedParagraph ? state.lastSpaceAfter : frame.pendingSpaceBefore,
                                      forcedBreakBefore: !frame.openedParagraph && frame.forcedBreakBefore, direction: document.directions[frame.node], language: inline.language)
        if !frame.openedParagraph { paragraph.elementID = document.tree.id(of: frame.node) }
        paragraph.pendingElementIDs = state.pendingElementIDs
        state.pendingElementIDs = []
        state.lastSpaceAfter = 0
        frame.openedParagraph = true
        state.paragraph = paragraph
        state.atParagraphStart = true
        state.pendingSpace = false
        if let holder = state.frames.last(where: { $0.listMarker != nil }), let marker = holder.listMarker {
            holder.listMarker = nil
            state.paragraph?.markerText = marker + Self.listMarkerGap
            emitSynthetic(marker + Self.listMarkerGap, state: state, inline: inline)
            state.atParagraphStart = true
            state.pendingSpace = false
        }
    }

    private func closeParagraph(_ state: State) {
        guard let paragraph = state.paragraph else { return }
        state.paragraph = nil
        flushBuffer(state)
        let start = paragraph.start
        let length = state.renderedLength - start
        let hasContent = paragraph.hasText || paragraph.hasImage
        guard hasContent, length > 0 else {
            // Nothing rendered: drop the paragraph but keep its spacing for the next one.
            if length > 0 { state.text.deleteCharacters(in: NSRange(location: start, length: length)); state.runs.removeAll { $0.renderedStart >= start }; state.currentRun = nil }
            state.lastSpaceAfter = max(state.lastSpaceAfter, paragraph.spaceBefore)
            if paragraph.forcedBreakBefore { state.pendingForcedBreak = true }
            state.pendingElementIDs = paragraph.pendingElementIDs + state.pendingElementIDs
            return
        }
        // Trim trailing collapsible whitespace.
        trimTrailingSpace(state, start: start)
        let range = NSRange(location: start, length: state.renderedLength - start)
        let blockIndex = state.blocks.count
        let paragraphStyle = makeParagraphStyle(paragraph, state: state, range: range)
        state.text.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
        state.text.addAttribute(.epubBlockIndex, value: NSNumber(value: blockIndex), range: range)
        if case .heading(let level) = paragraph.kind { state.text.addAttribute(.epubHeadingLevel, value: NSNumber(value: level), range: range) }
        if paragraph.forcedBreakBefore { state.text.addAttribute(.epubForcedBreakBefore, value: NSNumber(value: true), range: NSRange(location: start, length: 1)) }
        if paragraph.frame.keepTogether { state.text.addAttribute(.epubKeepTogether, value: NSNumber(value: true), range: range) }
        for identifier in paragraph.pendingElementIDs { state.anchors[identifier] = start }
        if let elementID = paragraph.elementID { state.anchors[elementID] = start; state.text.addAttribute(.epubElementID, value: elementID as NSString, range: NSRange(location: start, length: 1)) }
        let semantics = document.terms(of: paragraph.node)
        if !semantics.isEmpty { state.text.addAttribute(.epubSemantics, value: Array(semantics).sorted() as NSArray, range: range) }
        // The separator ends the block and carries its paragraph style.
        state.text.append(NSAttributedString(string: Self.paragraphSeparator, attributes: [.paragraphStyle: paragraphStyle, .epubBlockIndex: NSNumber(value: blockIndex), .font: state.bufferAttributes[.font] ?? UIFont.systemFont(ofSize: settings.baseFontSize)]))
        let kind: EPUBBlock.Kind
        switch paragraph.kind {
        case .tableCell: kind = paragraph.kind
        case .listItem: kind = .listItem(ordinal: paragraph.frame.listOrdinal)
        default: kind = paragraph.kind
        }
        state.blocks.append(EPUBBlock(range: range, kind: kind, node: paragraph.node, elementID: paragraph.elementID, language: paragraph.language,
                                      alternativeText: paragraph.alternativeText, links: paragraph.links, noteReferences: paragraph.noteReferences,
                                      containers: paragraph.frame.containerIndices, semantics: semantics, isAccessible: paragraph.isAccessible))
        state.lastSpaceAfter = 0
        state.pendingSpace = false
        state.atParagraphStart = true
    }

    /// Drops trailing collapsible spaces and one trailing line separator (a
    /// `br` or a newline at the end of a block makes no extra line), shrinking
    /// the runs that covered them, then flushes the open run.
    private func trimTrailingSpace(_ state: State, start: Int) {
        let string = state.text.string as NSString
        var end = state.text.length
        while end > start, string.character(at: end - 1) == 0x20 { end -= 1 }
        if end > start, string.character(at: end - 1) == Self.lineSeparatorUnit { end -= 1 }
        let removed = state.text.length - end
        if removed > 0 {
            state.text.deleteCharacters(in: NSRange(location: end, length: removed))
            if let run = state.currentRun, run.renderedStart + run.length > end {
                state.currentRun = (run.node, run.sourceOffset, run.renderedStart, max(0, end - run.renderedStart))
            }
            state.runs = state.runs.compactMap { run in
                guard run.renderedStart + run.length > end else { return run }
                let length = end - run.renderedStart
                return length > 0 ? EPUBTextRun(node: run.node, sourceOffset: run.sourceOffset, renderedStart: run.renderedStart, length: length) : nil
            }
        }
        flushRun(state)
    }

    private func makeParagraphStyle(_ paragraph: OpenParagraph, state: State, range: NSRange) -> NSParagraphStyle {
        let style = paragraph.frame.style
        let paragraphStyle = NSMutableParagraphStyle()
        let text = (state.text.string as NSString).substring(with: range)
        let direction = Self.baseDirection(declared: paragraph.direction, language: paragraph.language, text: text)
        paragraphStyle.baseWritingDirection = direction == .rightToLeft ? .rightToLeft : .leftToRight
        let alignment = style.textAlign ?? .start
        switch alignment {
        case .start: paragraphStyle.alignment = direction == .rightToLeft ? .right : .left
        case .end: paragraphStyle.alignment = direction == .rightToLeft ? .left : .right
        case .left: paragraphStyle.alignment = .left
        case .right: paragraphStyle.alignment = .right
        case .center: paragraphStyle.alignment = .center
        case .justify: paragraphStyle.alignment = .justified
        }
        var head = paragraph.frame.headIndent
        let indent = style.textIndent.resolved(against: geometry.columnWidth) ?? 0
        if let markerText = paragraph.markerText {
            // Continuation lines of a list item start past the marker.
            let font = fonts.font(families: style.fontFamilies, weight: style.fontWeight, italic: false, size: style.fontSize, monospace: false, publisherStyles: settings.publisherStyles)
            paragraphStyle.firstLineHeadIndent = head
            head += (markerText as NSString).size(withAttributes: [.font: font]).width
            paragraphStyle.headIndent = head
        } else {
            paragraphStyle.firstLineHeadIndent = max(0, head + indent)
            paragraphStyle.headIndent = head
        }
        paragraphStyle.tailIndent = -paragraph.frame.tailIndent
        paragraphStyle.paragraphSpacingBefore = paragraph.spaceBefore
        paragraphStyle.paragraphSpacing = 0
        switch style.lineHeight {
        case .normal: break
        case .multiple(let multiple): paragraphStyle.minimumLineHeight = style.fontSize * multiple
        case .length(let points): paragraphStyle.minimumLineHeight = points
        }
        if style.hyphens == EPUBComputedStyle.Hyphens.none || paragraph.kind == .preformatted || paragraph.isHeading {
            paragraphStyle.hyphenationFactor = 0
        } else if settings.hyphenates {
            paragraphStyle.hyphenationFactor = 1
        }
        if paragraph.kind == .preformatted { paragraphStyle.lineBreakMode = .byWordWrapping }
        return paragraphStyle
    }

    static func baseDirection(declared: EPUBContentDocument.Direction?, language: String?, text: String) -> EPUBContentDocument.Direction {
        if let declared, declared != .auto { return declared }
        if declared == nil, let language {
            let primary = language.split(separator: "-").first.map { $0.lowercased() } ?? ""
            if rightToLeftLanguages.contains(primary) { return .rightToLeft }
        }
        for scalar in text.unicodeScalars {
            if isRightToLeftScalar(scalar) { return .rightToLeft }
            if isLeftToRightScalar(scalar) { return .leftToRight }
        }
        return .leftToRight
    }

    static func isRightToLeftScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x05FF, 0x0600...0x06FF, 0x0700...0x074F, 0x0750...0x077F, 0x0780...0x07BF, 0x07C0...0x07FF, 0x08A0...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: return true
        default: return false
        }
    }

    static func isLeftToRightScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter, .modifierLetter: return !isRightToLeftScalar(scalar)
        default: return false
        }
    }

    static func marker(for type: EPUBComputedStyle.ListStyleType, ordinal: Int, style: EPUBComputedStyle) -> String? {
        switch type {
        case .none: return nil
        case .disc, .circle, .square: return bulletMarkers[type]
        case .decimal: return "\(ordinal)."
        case .lowerAlpha: return alphabetic(ordinal).lowercased() + "."
        case .upperAlpha: return alphabetic(ordinal) + "."
        case .lowerRoman: return roman(ordinal).lowercased() + "."
        case .upperRoman: return roman(ordinal) + "."
        }
    }

    static func alphabetic(_ ordinal: Int) -> String {
        guard ordinal > 0 else { return "\(ordinal)" }
        var value = ordinal
        var result = ""
        while value > 0 {
            let remainder = (value - 1) % 26
            result = String(UnicodeScalar(UInt8(65 + remainder))) + result
            value = (value - 1) / 26
        }
        return result
    }

    static func roman(_ ordinal: Int) -> String {
        guard ordinal > 0, ordinal < 4000 else { return "\(ordinal)" }
        let numerals = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var value = ordinal
        var result = ""
        for (amount, numeral) in numerals {
            while value >= amount { result += numeral; value -= amount }
        }
        return result
    }

    // MARK: Text emission

    private func emitText(_ text: String, node: EPUBXMLDocument.NodeID, state: State, inline: InlineContext) {
        guard !text.isEmpty else { return }
        let mode = inline.style.whiteSpace
        let preserveAll = mode == .pre || mode == .preWrap
        let preserveNewlines = preserveAll || mode == .preLine
        // Whitespace-only text between blocks never opens a paragraph.
        if state.paragraph == nil, !preserveAll, text.unicodeScalars.allSatisfy(Self.isCollapsible) { return }
        var sourceOffset = 0
        var skipLeadingNewline = preserveAll && state.paragraph == nil
        for scalar in text.unicodeScalars {
            let width = scalar.utf16.count
            defer { sourceOffset += width }
            if Self.isCollapsible(scalar), !preserveAll {
                if preserveNewlines, scalar == "\n" {
                    ensureParagraph(state, inline: inline)
                    emitScalar(Self.lineSeparator, node: node, sourceOffset: sourceOffset, state: state, inline: inline)
                    state.pendingSpace = false; state.atParagraphStart = true
                    continue
                }
                if !state.atParagraphStart { state.pendingSpace = true; state.pendingSpaceInline = inline }
                continue
            }
            if preserveAll {
                if scalar == "\r" { continue }
                if scalar == "\n" {
                    if skipLeadingNewline { skipLeadingNewline = false; continue }
                    ensureParagraph(state, inline: inline)
                    emitScalar(Self.lineSeparator, node: node, sourceOffset: sourceOffset, state: state, inline: inline)
                    continue
                }
                skipLeadingNewline = false
            }
            ensureParagraph(state, inline: inline)
            if state.pendingSpace { emitPendingSpace(state, inline: inline) }
            let transformed = Self.transform(scalar, style: inline.style, atWordStart: state.atParagraphStart || state.text.string.last?.isWhitespace == true || state.buffer.last?.isWhitespace == true)
            emitTransformed(transformed, original: scalar, node: node, sourceOffset: sourceOffset, state: state, inline: inline)
            state.atParagraphStart = false
        }
    }

    static func isCollapsible(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{0C}"
    }

    private static func transform(_ scalar: Unicode.Scalar, style: EPUBComputedStyle, atWordStart: Bool) -> String {
        let text = String(scalar)
        if style.smallCaps { return text.uppercased() }
        switch style.textTransform {
        case .none: return text
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        case .capitalize: return atWordStart ? text.uppercased() : text
        }
    }

    private func emitTransformed(_ transformed: String, original: Unicode.Scalar, node: EPUBXMLDocument.NodeID, sourceOffset: Int, state: State, inline: InlineContext) {
        if transformed.utf16.count == original.utf16.count {
            for character in transformed { emitScalar(character, node: node, sourceOffset: sourceOffset, state: state, inline: inline) }
            return
        }
        // A transform changed the length: map the whole result to the one source unit.
        flushRun(state)
        appendToBuffer(transformed, state: state, inline: inline)
        state.runs.append(EPUBTextRun(node: node, sourceOffset: sourceOffset, renderedStart: state.renderedLength - transformed.utf16.count, length: 1))
        state.textCharacterCount += 1
        state.paragraph?.hasText = true
    }

    /// Emits one source character, extending the current run when contiguous.
    private func emitScalar(_ character: Character, node: EPUBXMLDocument.NodeID, sourceOffset: Int, state: State, inline: InlineContext) {
        let renderedStart = state.renderedLength
        let text = String(character)
        appendToBuffer(text, state: state, inline: inline)
        let width = text.utf16.count
        if var run = state.currentRun, run.node == node, run.sourceOffset + run.length == sourceOffset, run.renderedStart + run.length == renderedStart {
            run.length += width
            state.currentRun = run
        } else {
            flushRun(state)
            state.currentRun = (node, sourceOffset, renderedStart, width)
        }
        if character != Self.lineSeparator { state.textCharacterCount += 1; state.paragraph?.hasText = true }
    }

    /// The one space that stands for a collapsed whitespace run, in the
    /// context of the node the whitespace came from; the run breaks here.
    private func emitPendingSpace(_ state: State, inline: InlineContext) {
        emitSynthetic(" ", state: state, inline: state.pendingSpaceInline ?? inline)
        state.pendingSpace = false
        state.pendingSpaceInline = nil
    }

    /// Text with no source: list markers, collapsed spaces, placeholders.
    private func emitSynthetic(_ text: String, state: State, inline: InlineContext) {
        ensureParagraph(state, inline: inline)
        flushRun(state)
        appendToBuffer(text, state: state, inline: inline)
    }

    private func emitLineBreak(state: State, inline: InlineContext) {
        guard state.frames.last != nil else { return }
        ensureParagraph(state, inline: inline)
        flushRun(state)
        appendToBuffer(String(Self.lineSeparator), state: state, inline: inline)
        state.pendingSpace = false
        state.atParagraphStart = true
    }

    private func flushRun(_ state: State) {
        if let run = state.currentRun, run.length > 0 {
            state.runs.append(EPUBTextRun(node: run.node, sourceOffset: run.sourceOffset, renderedStart: run.renderedStart, length: run.length))
        }
        state.currentRun = nil
    }

    private func appendToBuffer(_ text: String, state: State, inline: InlineContext) {
        let attributes = attributes(for: inline, state: state)
        if !state.buffer.isEmpty, !Self.sameAttributes(attributes, state.bufferAttributes) { flushBuffer(state) }
        if state.buffer.isEmpty { state.bufferAttributes = attributes }
        state.buffer += text
        if let linkIndex = inline.linkIndex, var paragraph = state.paragraph {
            let location = state.renderedLength - text.utf16.count
            let range = NSRange(location: location, length: text.utf16.count)
            if let last = paragraph.links.last, last.linkIndex == linkIndex, last.range.location + last.range.length == location {
                paragraph.links[paragraph.links.count - 1] = EPUBLinkRange(range: NSUnionRange(last.range, range), linkIndex: linkIndex)
            } else {
                paragraph.links.append(EPUBLinkRange(range: range, linkIndex: linkIndex))
            }
            if inline.isNoteReference {
                if let last = paragraph.noteReferences.last, last.linkIndex == linkIndex, last.range.location + last.range.length == location {
                    paragraph.noteReferences[paragraph.noteReferences.count - 1] = EPUBLinkRange(range: NSUnionRange(last.range, range), linkIndex: linkIndex)
                } else {
                    paragraph.noteReferences.append(EPUBLinkRange(range: range, linkIndex: linkIndex))
                }
            }
            state.paragraph = paragraph
        }
    }

    private func flushBuffer(_ state: State) {
        guard !state.buffer.isEmpty else { return }
        state.text.append(NSAttributedString(string: state.buffer, attributes: state.bufferAttributes))
        state.buffer = ""
    }

    private static func sameAttributes(_ a: [NSAttributedString.Key: Any], _ b: [NSAttributedString.Key: Any]) -> Bool {
        guard a.count == b.count else { return false }
        for (key, value) in a {
            guard let other = b[key] else { return false }
            if let font = value as? UIFont, let otherFont = other as? UIFont { if font != otherFont { return false }; continue }
            if let number = value as? NSNumber, let otherNumber = other as? NSNumber { if number != otherNumber { return false }; continue }
            if let string = value as? String, let otherString = other as? String { if string != otherString { return false }; continue }
            if let url = value as? URL, let otherURL = other as? URL { if url != otherURL { return false }; continue }
            if let color = value as? UIColor, let otherColor = other as? UIColor { if color != otherColor { return false }; continue }
            if let array = value as? [String], let otherArray = other as? [String] { if array != otherArray { return false }; continue }
            return false
        }
        return true
    }

    private func attributes(for inline: InlineContext, state: State) -> [NSAttributedString.Key: Any] {
        let style = inline.style
        let isMonospace = style.fontFamilies.contains { Self.monospaceFamilies.contains($0.lowercased()) }
        let size = style.smallCaps ? style.fontSize * EPUBFontRegistry.synthesisedSmallCapsScale : style.fontSize
        let font = fonts.font(families: style.fontFamilies, weight: style.fontWeight, italic: style.italic, size: size, monospace: isMonospace, publisherStyles: settings.publisherStyles)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: inline.linkIndex != nil ? UIColor.link : UIColor.label]
        if style.decoration.contains(.underline) { attributes[.underlineStyle] = NSNumber(value: NSUnderlineStyle.single.rawValue) }
        if style.decoration.contains(.lineThrough) { attributes[.strikethroughStyle] = NSNumber(value: NSUnderlineStyle.single.rawValue) }
        if let kern = style.letterSpacing { attributes[.kern] = NSNumber(value: Double(kern)) }
        switch inline.verticalAlign {
        case .superscript, .top, .textTop: attributes[.baselineOffset] = NSNumber(value: Double(style.fontSize * Self.superscriptBaselineFactor))
        case .sub, .bottom, .textBottom: attributes[.baselineOffset] = NSNumber(value: Double(style.fontSize * Self.subscriptBaselineFactor))
        default: break
        }
        if let language = inline.language, language != (state.paragraph?.language ?? language) || language != (document.body.flatMap { document.languages[$0] } ?? language) {
            attributes[.languageIdentifier] = language
        }
        if let linkIndex = inline.linkIndex {
            attributes[.epubLinkIndex] = NSNumber(value: linkIndex)
            attributes[.link] = URL(string: "funston-epub://link/\(linkIndex)") ?? URL(fileURLWithPath: "/")
            if inline.isNoteReference { attributes[.epubNoteReference] = NSNumber(value: linkIndex) }
        }
        return attributes
    }

    // MARK: Images, placeholders, breaks

    private func emitImage(_ id: EPUBXMLDocument.NodeID, state: State, inline: InlineContext) {
        let tree = document.tree
        let style = styles[id]
        let alternative = tree.attribute("alt", of: id) ?? tree.attribute("title", of: id)
        let isDecorative = tree.attribute("alt", of: id) == ""
        guard let source = chosenSource(id) else {
            emitImagePlaceholder(alternative, name: nil, id: id, state: state, inline: inline, decorative: isDecorative, reason: "missing src")
            return
        }
        let path = resolveImagePath(source)
        let metadata = path.flatMap { images?.metadata(for: $0) }
        guard let path, let metadata, !metadata.isSVG else {
            let name = (source as NSString).lastPathComponent
            let reason = path == nil ? "missing" : (metadata?.isSVG == true ? "svg" : "undecodable")
            emitImagePlaceholder(alternative, name: name, id: id, state: state, inline: inline, decorative: isDecorative, reason: reason)
            return
        }
        let parentBlock = state.frames.last
        let isBlock = style.display == .block || style.float != .none || isOnlyContentOfBlock(id)
        if isBlock { closeParagraph(state) }
        ensureParagraph(state, inline: inline)
        if isBlock { state.paragraph?.kind = .image; state.paragraph?.alternativeText = alternative; state.paragraph?.isAccessible = !isDecorative }
        else if state.pendingSpace { emitPendingSpace(state, inline: inline) }
        flushRun(state)
        let placement = EPUBImagePlacement(path: path, alternativeText: alternative, intrinsicSize: metadata.pixelSize, declaredWidth: style.width, declaredHeight: style.height,
                                           declaredMaxWidth: style.maxWidth, isBlock: isBlock, isDecorative: isDecorative, renderedOffset: state.renderedLength, textScale: settings.textScale)
        let attachment = EPUBImageAttachment(placement: placement, catalog: images)
        attachment.bounds = Self.initialBounds(for: placement, columnWidth: geometry.columnWidth - (parentBlock?.headIndent ?? 0) - (parentBlock?.tailIndent ?? 0), maximumHeight: geometry.maximumImageHeight)
        flushBuffer(state)
        var attributes = attributes(for: inline, state: state)
        attributes[.attachment] = attachment
        if let alternative { attributes[.epubAlternativeText] = alternative as NSString }
        state.text.append(NSAttributedString(string: Self.attachmentCharacter, attributes: attributes))
        state.images.append(placement)
        state.imageCount += 1
        state.paragraph?.hasImage = true
        state.atParagraphStart = false
        state.pendingSpace = false
        if isBlock { state.paragraph?.frame.style.textAlign == .center ? () : (); closeParagraphCentered(state) }
    }

    private func closeParagraphCentered(_ state: State) {
        guard var paragraph = state.paragraph else { return }
        paragraph.kind = .image
        state.paragraph = paragraph
        closeParagraph(state)
    }

    /// CSS or attribute size, else intrinsic pixels as points, clamped to the
    /// column and the page, keeping the aspect ratio. Inline images scale with the text.
    static func initialBounds(for placement: EPUBImagePlacement, columnWidth: CGFloat, maximumHeight: CGFloat) -> CGRect {
        let intrinsic = placement.intrinsicSize
        guard intrinsic.width > 0, intrinsic.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        var width = placement.declaredWidth?.resolved(against: columnWidth)
        var height = placement.declaredHeight?.resolved(against: maximumHeight)
        if width == nil, height == nil {
            let scale = placement.isBlock ? 1 : placement.textScale
            width = intrinsic.width * scale; height = intrinsic.height * scale
        } else if width == nil, let h = height { width = h * intrinsic.width / intrinsic.height }
        else if height == nil, let w = width { height = w * intrinsic.height / intrinsic.width }
        var size = CGSize(width: max(1, width ?? 1), height: max(1, height ?? 1))
        if let maximum = placement.declaredMaxWidth?.resolved(against: columnWidth), size.width > maximum {
            size = CGSize(width: maximum, height: size.height * maximum / size.width)
        }
        if size.width > columnWidth { size = CGSize(width: columnWidth, height: size.height * columnWidth / size.width) }
        if size.height > maximumHeight { size = CGSize(width: size.width * maximumHeight / size.height, height: maximumHeight) }
        return CGRect(origin: .zero, size: size)
    }

    private func chosenSource(_ id: EPUBXMLDocument.NodeID) -> String? {
        let tree = document.tree
        if let srcset = tree.attribute("srcset", of: id) {
            var best: (String, Double)?
            for candidate in srcset.split(separator: ",") {
                let parts = candidate.trimmingCharacters(in: .whitespaces).split(separator: " ")
                guard let url = parts.first else { continue }
                let density = parts.count > 1 ? Double(parts[1].dropLast()) ?? 1 : 1
                let screenScale = Double(UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale : 2)
                let distance = abs(density - screenScale)
                if best == nil || distance < best!.1 { best = (String(url), distance) }
            }
            if let best { return best.0 }
        }
        return tree.attribute("src", of: id) ?? tree.attribute("href", namespace: EPUBNamespace.xlink, of: id) ?? tree.attribute(qualified: "xlink:href", of: id) ?? tree.attribute("href", of: id)
    }

    private func isOnlyContentOfBlock(_ id: EPUBXMLDocument.NodeID) -> Bool {
        let tree = document.tree
        guard let parent = tree.parent(of: id) else { return true }
        var current = parent
        while !styles[current].isBlockLevel, let next = tree.parent(of: current) { current = next }
        let text = EPUBCFIFollower.characterDataNodes(in: tree, under: current).map { tree[$0].text }.joined()
        guard EPUBXMLDocument.collapseWhitespace(text).isEmpty else { return false }
        return tree.descendantElements(of: current).filter { ["img", "image", "svg"].contains(tree.localName(of: $0)) }.count == 1
    }

    private func emitImagePlaceholder(_ alternative: String?, name: String?, id: EPUBXMLDocument.NodeID, state: State, inline: InlineContext, decorative: Bool, reason: String) {
        if decorative {
            state.diagnostics.record(.image, "image.decorativeDropped", path: document.path, "A decorative image could not be shown (\(reason)); nothing stands in for it.")
            return
        }
        state.diagnostics.record(.image, EPUBImageCatalog.placeholderDiagnostic, path: document.path, "An image could not be shown (\(reason)); its description is shown instead.")
        let label = alternative.flatMap { $0.isEmpty ? nil : $0 } ?? "image" + (name.map { " " + ($0 as NSString).deletingPathExtension } ?? "")
        var context = inline
        context.style.italic = true
        let isBlock = isOnlyContentOfBlock(id)
        if isBlock { closeParagraph(state) }
        ensureParagraph(state, inline: context)
        if isBlock { state.paragraph?.kind = .image; state.paragraph?.alternativeText = label }
        emitSynthetic("[" + label + "]", state: state, inline: context)
        state.textCharacterCount += label.utf16.count
        state.paragraph?.hasText = true
        state.atParagraphStart = false
        if isBlock { closeParagraph(state) }
    }

    private func emitSVGPlaceholder(_ id: EPUBXMLDocument.NodeID, state: State, inline: InlineContext) {
        let tree = document.tree
        let title = tree.descendantElements(named: "title", of: id).first.map { tree.collapsedText(of: $0) }
        let description = tree.descendantElements(named: "desc", of: id).first.map { tree.collapsedText(of: $0) }
        let label = [title, description].compactMap { $0 }.filter { !$0.isEmpty }.first ?? "graphic"
        state.diagnostics.record(.image, EPUBImageCatalog.placeholderDiagnostic, path: document.path, "Inline SVG is shown as its description.")
        var context = inline
        context.style.italic = true
        let isBlock = isOnlyContentOfBlock(id) || styles[id].display == .block
        if isBlock { closeParagraph(state) }
        ensureParagraph(state, inline: context)
        if isBlock { state.paragraph?.kind = .image; state.paragraph?.alternativeText = label }
        emitSynthetic("[" + label + "]", state: state, inline: context)
        state.textCharacterCount += label.utf16.count
        state.paragraph?.hasText = true
        state.atParagraphStart = false
        if isBlock { closeParagraph(state) }
    }

    private func emitMath(_ id: EPUBXMLDocument.NodeID, state: State, inline: InlineContext) {
        let tree = document.tree
        var text = tree.attribute("alttext", of: id)
        if text == nil, let annotation = tree.descendantElements(named: "annotation", of: id).first { text = tree.collapsedText(of: annotation) }
        if text == nil || text?.isEmpty == true {
            text = tree.collapsedText(of: id)
        }
        guard let label = text, !label.isEmpty else { return }
        state.diagnostics.record(.chapterParse, "math.textFallback", path: document.path, "MathML is shown as its text.")
        ensureParagraph(state, inline: inline)
        emitSynthetic(label, state: state, inline: inline)
        state.textCharacterCount += label.utf16.count
        state.paragraph?.hasText = true
        state.atParagraphStart = false
    }

    private func emitMediaFallback(_ id: EPUBXMLDocument.NodeID, state: State, inline: InlineContext) {
        let tree = document.tree
        let fallbackText = EPUBXMLDocument.collapseWhitespace(tree.textContent(of: id))
        if !fallbackText.isEmpty {
            for child in tree.children(of: id) where !["source", "track", "param"].contains(tree.localName(of: child)) { walk(child, state: state, inline: inline) }
            return
        }
        let name = tree.localName(of: id)
        state.diagnostics.record(.chapterParse, "media.placeholder", path: document.path, "A \(name) element is shown as a placeholder.")
        let label = "[" + name + "]"
        closeParagraph(state)
        ensureParagraph(state, inline: inline)
        emitSynthetic(label, state: state, inline: inline)
        state.textCharacterCount += label.utf16.count
        state.paragraph?.hasText = true
        closeParagraph(state)
    }

    private func emitThoughtBreak(_ id: EPUBXMLDocument.NodeID, state: State) {
        closeParagraph(state)
        guard let frame = state.frames.last else { return }
        let style = styles[id]
        let context = InlineContext(style: style, language: document.languages[id])
        openFrame(id, style: style, state: state, inline: context)
        ensureParagraph(state, inline: context)
        state.paragraph?.kind = .thoughtBreak
        state.paragraph?.isAccessible = false
        emitSynthetic(Self.thoughtBreakText, state: state, inline: context)
        state.paragraph?.hasText = true
        flushBuffer(state)
        let start = state.paragraph?.start ?? state.renderedLength - 1
        state.text.addAttribute(.epubThoughtBreak, value: NSNumber(value: true), range: NSRange(location: start, length: state.renderedLength - start))
        closeFrame(id, state: state)
        _ = frame
    }

    // MARK: Notes

    /// Spec 13.4: the vocabulary, the superscript heuristic and the Gutenberg conventions.
    private func isNoteReference(_ id: EPUBXMLDocument.NodeID, href: String) -> Bool {
        let tree = document.tree
        if document.isBacklink(id) { return false }
        if document.isNoteReference(id) { return true }
        let classes = document.classes(of: id).map { $0.lowercased() }
        if classes.contains(where: { candidate in Self.noteReferenceClasses.contains { candidate.contains($0) } }) { return true }
        // Superscript: is, contains only, or sits inside a superscript.
        if styles[id].verticalAlign == .superscript || styles[id].verticalAlign == .top || styles[id].verticalAlign == .textTop { return true }
        let children = tree.childElements(of: id)
        if children.count == 1, tree.localName(of: children[0]) == "sup", EPUBXMLDocument.collapseWhitespace(tree.children(of: id).filter { tree[$0].isCharacterData }.map { tree[$0].text }.joined()).isEmpty { return true }
        if tree.ancestors(of: id).contains(where: { tree.localName(of: $0) == "sup" || styles[$0].verticalAlign == .superscript }) { return true }
        // Gutenberg: a target id that begins with Footnote_, fn or note inside a note container.
        let (_, fragment) = EPUBHref.splitFragment(href)
        if let fragment, Self.noteTargetPrefixes.contains(where: { fragment.hasPrefix($0) }), let target = tree.element(withID: fragment) {
            let ancestors = [target] + tree.ancestors(of: target)
            if ancestors.contains(where: { ancestor in document.classes(of: ancestor).contains { cls in Self.noteContainerClassFragments.contains { cls.lowercased().contains($0) } } }) { return true }
        }
        return false
    }

    private func noteLabel(for id: EPUBXMLDocument.NodeID) -> String {
        let tree = document.tree
        if let backlink = tree.descendantElements(named: "a", of: id).first(where: { document.isBacklink($0) }) {
            let text = tree.collapsedText(of: backlink).trimmingCharacters(in: CharacterSet(charactersIn: "[]↩︎ "))
            if !text.isEmpty, text.count <= 8 { return "note " + text }
        }
        if let elementID = tree.id(of: id), let digits = elementID.split(whereSeparator: { !$0.isNumber }).last { return "note " + digits }
        return "note"
    }
}
