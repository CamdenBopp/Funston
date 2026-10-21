import Foundation
import UIKit

extension NSAttributedString.Key {
    /// NSNumber 1 to 6 on every character of a heading block.
    static let epubHeadingLevel = NSAttributedString.Key("funston.epub.headingLevel")
    /// NSString: the element id, on the element's first rendered character.
    static let epubElementID = NSAttributedString.Key("funston.epub.elementID")
    /// NSArray of NSString: expanded structural semantics of the element.
    static let epubSemantics = NSAttributedString.Key("funston.epub.semantics")
    /// NSString: alternative text on an image attachment character.
    static let epubAlternativeText = NSAttributedString.Key("funston.epub.alternativeText")
    /// NSNumber: an index into the chapter's links, on a note reference's characters.
    static let epubNoteReference = NSAttributedString.Key("funston.epub.noteReference")
    /// NSNumber: an index into the chapter's links, on a link's characters.
    static let epubLinkIndex = NSAttributedString.Key("funston.epub.linkIndex")
    /// NSNumber true on a block's first character when a page break is forced before it.
    static let epubForcedBreakBefore = NSAttributedString.Key("funston.epub.forcedBreakBefore")
    /// NSNumber true on every character of a keep-together block.
    static let epubKeepTogether = NSAttributedString.Key("funston.epub.keepTogether")
    /// NSNumber: the index into the chapter's blocks, on every rendered character.
    static let epubBlockIndex = NSAttributedString.Key("funston.epub.blockIndex")
    /// NSNumber true on a thought-break paragraph, drawn as a rule.
    static let epubThoughtBreak = NSAttributedString.Key("funston.epub.thoughtBreak")
}

/// One contiguous stretch where rendered and source offsets advance
/// together: `length` UTF-16 units starting at `sourceOffset` in `node` landed
/// at `renderedStart`. Dropped or merged whitespace ends a run.
struct EPUBTextRun: Sendable, Hashable {
    let node: EPUBXMLDocument.NodeID
    let sourceOffset: Int
    let renderedStart: Int
    let length: Int
    var renderedEnd: Int { renderedStart + length }
}

/// Rendered UTF-16 ranges to source positions and back (Spec section 10.2).
struct EPUBRunTable: Sendable, Hashable {
    let runs: [EPUBTextRun]

    /// The source position of a rendered offset. An offset at a run boundary
    /// maps to the end of the earlier run; an offset in a synthesised stretch
    /// (a list marker, a placeholder) maps to the start of the next run.
    func sourcePosition(forRendered offset: Int) -> EPUBSourcePosition? {
        guard !runs.isEmpty else { return nil }
        var low = 0, high = runs.count - 1
        var candidate: Int?
        while low <= high {
            let middle = (low + high) / 2
            if runs[middle].renderedStart <= offset { candidate = middle; low = middle + 1 } else { high = middle - 1 }
        }
        if let index = candidate {
            let run = runs[index]
            if offset <= run.renderedEnd { return .text(node: run.node, offset: run.sourceOffset + (offset - run.renderedStart)) }
            if index + 1 < runs.count { let next = runs[index + 1]; return .text(node: next.node, offset: next.sourceOffset) }
            return .text(node: run.node, offset: run.sourceOffset + run.length)
        }
        let first = runs[0]
        return .text(node: first.node, offset: first.sourceOffset)
    }

    /// The rendered offset of a source position, or of the first rendered
    /// character after it when it fell in dropped whitespace.
    func renderedOffset(for position: EPUBSourcePosition, in tree: EPUBXMLDocument) -> Int? {
        switch position {
        case .text(let node, let offset):
            var following: Int?
            for run in runs where run.node == node {
                if offset >= run.sourceOffset, offset <= run.sourceOffset + run.length { return run.renderedStart + (offset - run.sourceOffset) }
                if run.sourceOffset > offset, following == nil { following = run.renderedStart }
            }
            if let following { return following }
            // No run in this node: the first run of a later node in document order.
            let order = EPUBCFIFollower.characterDataNodes(in: tree)
            guard let index = order.firstIndex(of: node) else { return nil }
            for later in order[(index + 1)...] {
                if let run = runs.first(where: { $0.node == later }) { return run.renderedStart }
            }
            return runs.last.map(\.renderedEnd)
        case .element(let element):
            let descendants = Set(EPUBCFIFollower.characterDataNodes(in: tree, under: element))
            if let run = runs.first(where: { descendants.contains($0.node) }) { return run.renderedStart }
            let order = EPUBCFIFollower.characterDataNodes(in: tree)
            let after = order.drop { !descendants.contains($0) }.dropFirst()
            for later in after where !descendants.contains(later) {
                if let run = runs.first(where: { $0.node == later }) { return run.renderedStart }
            }
            // Walk forward in document order from the element itself.
            var ancestorsAndSelf = tree.ancestors(of: element); ancestorsAndSelf.insert(element, at: 0)
            for later in order {
                let ancestors = tree.ancestors(of: later)
                if ancestors.contains(element) { continue }
                if later > element, let run = runs.first(where: { $0.node == later }) { return run.renderedStart }
            }
            return runs.last.map(\.renderedEnd)
        case .boundary(let parent, let childIndex):
            let children = tree.children(of: parent)
            if childIndex < children.count {
                let child = children[childIndex]
                return renderedOffset(for: tree[child].isElement ? .element(child) : .text(node: child, offset: 0), in: tree)
            }
            let descendants = Set(EPUBCFIFollower.characterDataNodes(in: tree, under: parent))
            if let last = runs.last(where: { descendants.contains($0.node) }) { return last.renderedEnd }
            return renderedOffset(for: .element(parent), in: tree)
        }
    }
}

/// Where a link goes.
enum EPUBLinkTarget: Sendable, Hashable {
    case internalLink(path: String, fragment: String?, spineIndex: Int?)
    case external(URL)
    case refused(String)
}

struct EPUBLinkRange: Sendable, Hashable {
    let range: NSRange
    let linkIndex: Int
}

/// One entry of the block list: the accessibility and read-aloud unit.
struct EPUBBlock: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case paragraph
        case heading(level: Int)
        case listItem(ordinal: Int?)
        case tableCell(row: Int, column: Int, isHeader: Bool)
        case caption
        case image
        case preformatted
        case quotation
        case noteBody
        case thoughtBreak
    }

    let range: NSRange
    let kind: Kind
    let node: EPUBXMLDocument.NodeID
    let elementID: String?
    let language: String?
    let alternativeText: String?
    let links: [EPUBLinkRange]
    let noteReferences: [EPUBLinkRange]
    /// Indices into the chapter's containers, outermost first.
    let containers: [Int]
    let semantics: Set<String>
    /// False for decorative images and thought breaks.
    let isAccessible: Bool

    var headingLevel: Int? { if case .heading(let level) = kind { return level } else { return nil } }
}

/// A list, table, note body, aside or figure spanning several blocks.
struct EPUBContainer: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case list(itemCount: Int, ordered: Bool)
        case table(rows: Int, columns: Int, isLayout: Bool)
        case note(label: String)
        case aside
        case figure
    }
    var range: NSRange
    let node: EPUBXMLDocument.NodeID
    var kind: Kind
    let label: String?
}

/// What an image needs at layout time: its intrinsic size and the author's
/// declared size, clamped to the column by the layout session.
struct EPUBImagePlacement: Sendable, Hashable {
    let path: String
    let alternativeText: String?
    let intrinsicSize: CGSize
    let declaredWidth: EPUBLength?
    let declaredHeight: EPUBLength?
    let declaredMaxWidth: EPUBLength?
    let isBlock: Bool
    let isDecorative: Bool
    /// The offset of the attachment character.
    let renderedOffset: Int
    /// Inline images scale with the text; block images keep their size.
    let textScale: CGFloat
}

struct EPUBPageBreak: Sendable, Hashable {
    let label: String
    let renderedOffset: Int
}

/// The attachment character of an image, drawn from the catalog at the
/// requested size. Attachments are shared between layout copies of the string.
final class EPUBImageAttachment: NSTextAttachment, @unchecked Sendable {
    let placement: EPUBImagePlacement
    private let catalog: EPUBImageCatalog?

    init(placement: EPUBImagePlacement, catalog: EPUBImageCatalog?) {
        self.placement = placement
        self.catalog = catalog
        super.init(data: nil, ofType: nil)
    }

    /// A fresh attachment for a layout copy, drawing from the same catalog.
    convenience init(placement: EPUBImagePlacement, catalog: EPUBImageCatalog?, sharing other: EPUBImageAttachment) {
        self.init(placement: placement, catalog: catalog ?? other.catalog)
    }

    required init?(coder: NSCoder) { nil }

    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> UIImage? {
        let scale = UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale : 2
        let pixels = Int((max(imageBounds.width, imageBounds.height) * scale).rounded(.up))
        guard pixels > 0, let decoded = catalog?.image(for: placement.path, maximumPixelSize: pixels) else { return nil }
        return UIImage(cgImage: decoded)
    }
}

/// One chapter's rendered text with the two tables beside it (Spec section 10).
/// The string is immutable after the build; the class wrapper only shares it.
struct EPUBChapterText: @unchecked Sendable {
    static let parserVersion = 1

    let string: NSAttributedString
    let runTable: EPUBRunTable
    let blocks: [EPUBBlock]
    let containers: [EPUBContainer]
    let links: [EPUBLinkTarget]
    let images: [EPUBImagePlacement]
    let pageBreaks: [EPUBPageBreak]
    /// Element id to the rendered offset of its first character (or where it would be).
    let anchors: [String: Int]
    let language: String?
    let title: String?
    let diagnostics: EPUBDiagnosticList
    /// True when the body renders no text and exactly one image.
    let isImagePage: Bool

    var length: Int { string.length }
    var plainText: String { string.string }

    /// The block containing a rendered offset, by binary search.
    func blockIndex(containing offset: Int) -> Int? {
        var low = 0, high = blocks.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let range = blocks[middle].range
            if offset < range.location { high = middle - 1 }
            else if offset >= range.location + range.length && !(offset == range.location + range.length && middle == blocks.count - 1) { low = middle + 1 }
            else { return middle }
        }
        return blocks.isEmpty ? nil : min(max(low, 0), blocks.count - 1)
    }

    func text(in range: NSRange) -> String {
        guard range.location >= 0, range.location + range.length <= string.length else { return "" }
        return string.attributedSubstring(from: range).string
    }
}
