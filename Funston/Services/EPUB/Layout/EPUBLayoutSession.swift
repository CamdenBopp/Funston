import Foundation
import OSLog
import UIKit

/// The settings tuple that identifies a pagination (Spec section 11.6).
struct EPUBLayoutKey: Sendable, Hashable {
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    let baseFontSize: CGFloat
    let alignment: EPUBReadingSettings.Alignment
    let hyphenation: Bool
    let publisherStyles: Bool
    let twoColumns: Bool
    let osVersion: String
    let parserVersion: Int
    let embeddedFontHash: Int

    /// Sizes round to half points so sub-pixel bounds changes share a key.
    static func rounded(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }

    init(contentSize: CGSize, settings: EPUBReadingSettings, twoColumns: Bool, embeddedFontHash: Int = 0) {
        contentWidth = Self.rounded(contentSize.width)
        contentHeight = Self.rounded(contentSize.height)
        baseFontSize = settings.baseFontSize
        alignment = settings.alignment
        hyphenation = settings.hyphenates
        publisherStyles = settings.publisherStyles
        self.twoColumns = twoColumns
        let version = ProcessInfo.processInfo.operatingSystemVersion
        osVersion = "\(version.majorVersion).\(version.minorVersion)"
        parserVersion = EPUBChapterText.parserVersion
        self.embeddedFontHash = embeddedFontHash
    }
}

/// How much of a chapter a layout session measures (Spec 11.2, YUE-32).
enum EPUBLayoutExtent: Sendable, Hashable {
    /// Enough lines for the first page, installed while the whole chapter lays out.
    case firstPage
    case whole
}

/// One chapter laid out under one key: TextKit 2 layouts whose line and
/// page tables were collected on the layout queue (Spec sections 11.2 and
/// 11.3). After `init` returns the object is immutable; the reader hands it
/// to the main actor.
final class EPUBLayoutSession: @unchecked Sendable {
    /// Chapters longer than this lay out in two passes, first page first.
    static let twoPassThreshold = 20_000
    /// Rendered text per layout section; longer chapters split at paragraph boundaries (APL-46).
    static let sectionLimit = 300_000
    /// The partial pass measures this many page heights so the first cut sees its lookahead.
    static let partialPageHeights: CGFloat = 3
    /// Recorded when the styled layout ran past its budget and the chapter was laid out plain (Spec 19.3).
    static let budgetDiagnostic = "layout.timeBudget"

    /// One TextKit 2 stack over a slice of the chapter string.
    private struct Section {
        let startOffset: Int
        let yOffset: CGFloat
        let contentStorage: NSTextContentStorage
        let layoutManager: NSTextLayoutManager
        let container: NSTextContainer
        let lineFragments: [NSTextLineFragment]
        let height: CGFloat
    }

    let key: EPUBLayoutKey
    let geometry: EPUBPageGeometry
    let text: EPUBChapterText
    let string: NSAttributedString
    let extent: EPUBLayoutExtent
    let diagnostics: EPUBDiagnosticList
    private(set) var table: EPUBPageTable
    /// The first rendered offset no page covers: the string length for a whole layout.
    private(set) var measuredEndOffset: Int
    private var sections: [Section] = []
    /// For each line, the section it belongs to and its index in that section's fragments.
    private var lineSources: [(section: Int, fragment: Int)] = []

    var pageCount: Int { table.pages.count }
    var isPartial: Bool { extent == .firstPage && measuredEndOffset < string.length }

    /// Lays the chapter out synchronously on the calling queue.
    init(text: EPUBChapterText, geometry: EPUBPageGeometry, key: EPUBLayoutKey, settings: EPUBReadingSettings, margins: CGFloat,
         extent: EPUBLayoutExtent = .whole, sectionLimit: Int = EPUBLayoutSession.sectionLimit, limits: EPUBWorkLimits = .standard) {
        self.key = key
        self.geometry = geometry
        self.text = text
        self.extent = extent
        diagnostics = EPUBDiagnosticList()
        let prepared = Self.prepared(text, columnWidth: geometry.columnWidth, maximumImageHeight: geometry.contentSize.height - 2 * margins)
        string = prepared
        let signpost = OSSignposterHolder.shared.beginInterval("layout", id: OSSignposterHolder.shared.makeSignpostID())
        defer { OSSignposterHolder.shared.endInterval("layout", signpost) }
        var lines: [EPUBLineRecord] = []
        var sources: [(Int, Int)] = []
        var sections: [Section] = []
        var y: CGFloat = 0
        let heightBudget = extent == .firstPage ? geometry.contentSize.height * Self.partialPageHeights : .infinity
        var measuredEnd = 0
        for slice in Self.sectionRanges(of: prepared, limit: sectionLimit) {
            let sectionString = prepared.attributedSubstring(from: slice)
            let contentStorage = NSTextContentStorage()
            contentStorage.textStorage = NSTextStorage(attributedString: sectionString)
            let layoutManager = NSTextLayoutManager()
            layoutManager.usesHyphenation = settings.hyphenates
            layoutManager.limitsLayoutForSuspiciousContents = limits.limitsSuspiciousLayout
            contentStorage.addTextLayoutManager(layoutManager)
            let container = NSTextContainer(size: CGSize(width: geometry.columnWidth, height: 0))
            container.lineFragmentPadding = 0
            layoutManager.textContainer = container
            var fragments: [NSTextLineFragment] = []
            var sectionHeight: CGFloat = 0
            var stopped = false
            let sectionIndex = sections.count
            let documentStart = layoutManager.documentRange.location
            guard let storage = contentStorage.textStorage else { continue }
            layoutManager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
                guard let element = fragment.textElement, let elementRange = element.elementRange else { return true }
                let elementStart = slice.location + layoutManager.offset(from: documentStart, to: elementRange.location)
                let fragmentIndex = fragments.count
                let frame = fragment.layoutFragmentFrame
                for (lineIndex, line) in fragment.textLineFragments.enumerated() where line.characterRange.length > 0 {
                    let location = elementStart + line.characterRange.location
                    let range = NSRange(location: location, length: line.characterRange.length)
                    let bounds = line.typographicBounds
                    let lineFrame = CGRect(x: frame.minX + bounds.minX, y: y + frame.minY + bounds.minY, width: bounds.width, height: bounds.height)
                    let forced = lineIndex == 0 && Self.flag(.epubForcedBreakBefore, in: storage, at: location - slice.location)
                    let keep = Self.flag(.epubKeepTogether, in: storage, at: location - slice.location)
                    lines.append(EPUBLineRecord(range: range, frame: lineFrame, fragmentIndex: fragmentIndex, forcesBreakBefore: forced, keepsTogether: keep))
                    sources.append((sectionIndex, fragments.count))
                    fragments.append(line)
                    measuredEnd = max(measuredEnd, range.location + range.length)
                }
                sectionHeight = max(sectionHeight, frame.maxY)
                if sectionHeight > heightBudget { stopped = true; return false }
                return true
            }
            sections.append(Section(startOffset: slice.location, yOffset: y, contentStorage: contentStorage, layoutManager: layoutManager, container: container, lineFragments: fragments, height: sectionHeight))
            y += sectionHeight
            if stopped { break }
        }
        self.sections = sections
        lineSources = sources
        var table = EPUBPageTable.paginate(lines: lines, geometry: geometry)
        if extent == .firstPage, table.pages.count > 1 {
            table = EPUBPageTable(lines: table.lines, pages: [table.pages[0]], geometry: geometry)
        }
        if table.pages.isEmpty {
            // A chapter with no text still owns one page.
            table = EPUBPageTable(lines: [], pages: [EPUBPageRecord(columns: [EPUBColumnCut(firstLine: 0, lastLine: 0, top: 0)], firstOffset: 0, endOffset: 0)], geometry: geometry)
        }
        self.table = table
        measuredEndOffset = extent == .firstPage ? (table.pages.first?.endOffset ?? 0) : prepared.length
        if extent == .whole || measuredEndOffset >= prepared.length { measuredEndOffset = prepared.length }
    }

    /// Slices of the string no longer than the limit, cut at paragraph separators.
    static func sectionRanges(of string: NSAttributedString, limit: Int) -> [NSRange] {
        let length = string.length
        guard length > limit, limit > 0 else { return [NSRange(location: 0, length: length)] }
        let text = string.string as NSString
        var ranges: [NSRange] = []
        var start = 0
        while start < length {
            let remaining = length - start
            if remaining <= limit { ranges.append(NSRange(location: start, length: remaining)); break }
            let window = NSRange(location: start, length: limit)
            let newline = text.range(of: "\n", options: .backwards, range: window)
            let end = newline.location == NSNotFound || newline.location <= start ? start + limit : newline.location + 1
            ranges.append(NSRange(location: start, length: end - start))
            start = end
        }
        return ranges
    }

    private static func flag(_ key: NSAttributedString.Key, in storage: NSTextStorage, at location: Int) -> Bool {
        guard location >= 0, location < storage.length else { return false }
        return (storage.attribute(key, at: location, effectiveRange: nil) as? NSNumber)?.boolValue ?? false
    }

    /// A copy of the chapter string with fresh attachments sized for this layout.
    static func prepared(_ text: EPUBChapterText, columnWidth: CGFloat, maximumImageHeight: CGFloat) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text.string)
        copy.enumerateAttribute(.attachment, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
            guard let attachment = value as? EPUBImageAttachment else { return }
            let indent = (copy.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle).map { $0.headIndent - $0.tailIndent } ?? 0
            let replacement = EPUBImageAttachment(placement: attachment.placement, catalog: nil, sharing: attachment)
            replacement.bounds = EPUBChapterTextBuilder.initialBounds(for: attachment.placement, columnWidth: max(1, columnWidth - max(0, indent)), maximumHeight: max(1, maximumImageHeight))
            copy.addAttribute(.attachment, value: replacement, range: range)
        }
        return copy
    }

    // MARK: Drawing and geometry

    /// Draws the lines of a page into a top-left context, at the page's origin.
    func draw(page index: Int, in context: CGContext, origin: CGPoint = .zero) {
        guard table.pages.indices.contains(index) else { return }
        for (column, cut) in table.pages[index].columns.enumerated() {
            let x = geometry.columnOrigin(column) + origin.x
            for line in cut.lineRange where line < lineSources.count {
                let record = table.lines[line]
                let source = lineSources[line]
                sections[source.section].lineFragments[source.fragment].draw(at: CGPoint(x: x + record.frame.minX, y: origin.y + record.frame.minY - cut.top), in: context)
            }
        }
    }

    /// The height of the whole chapter as one column: the continuous surface's content height.
    var contentHeight: CGFloat { table.lines.last?.frame.maxY ?? 0 }

    /// Draws the lines whose frames intersect a rect of the continuous surface (Spec 11.4), at an origin.
    func drawLines(intersecting rect: CGRect, in context: CGContext, origin: CGPoint = .zero) {
        let lines = table.lines
        guard !lines.isEmpty else { return }
        var low = 0, high = lines.count - 1
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].frame.maxY < rect.minY { low = middle + 1 } else { high = middle }
        }
        var index = low
        let x = geometry.columnOrigin(0) + origin.x
        while index < lines.count, lines[index].frame.minY <= rect.maxY {
            let record = lines[index]
            if index < lineSources.count {
                let source = lineSources[index]
                sections[source.section].lineFragments[source.fragment].draw(at: CGPoint(x: x + record.frame.minX, y: origin.y + record.frame.minY), in: context)
            }
            index += 1
        }
    }

    /// The line at a y of the continuous surface, by binary search; nil in gaps.
    func lineIndex(atSurfaceY y: CGFloat) -> Int? {
        let lines = table.lines
        var low = 0, high = lines.count - 1
        while low <= high {
            let middle = (low + high) / 2
            if y < lines[middle].frame.minY { high = middle - 1 } else if y > lines[middle].frame.maxY { low = middle + 1 } else { return middle }
        }
        return nil
    }

    /// The character index at a point of the continuous surface.
    func characterIndex(atSurfacePoint point: CGPoint) -> Int? {
        guard let line = lineIndex(atSurfaceY: point.y), line < lineSources.count else { return nil }
        let record = table.lines[line]
        let frame = record.frame.offsetBy(dx: geometry.columnOrigin(0), dy: 0)
        guard point.x >= frame.minX - 1, point.x <= frame.maxX + 1 else { return nil }
        let source = lineSources[line]
        let fragment = sections[source.section].lineFragments[source.fragment]
        let elementIndex = fragment.characterIndex(for: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY))
        let elementStart = record.range.location - fragment.characterRange.location
        return min(record.range.location + record.range.length, max(record.range.location, elementStart + elementIndex))
    }

    /// Rectangles for a rendered range on the continuous surface.
    func surfaceRectangles(for range: NSRange) -> [CGRect] {
        var result: [CGRect] = []
        for section in sections {
            let sectionLength = section.contentStorage.textStorage?.length ?? 0
            let local = NSIntersectionRange(range, NSRange(location: section.startOffset, length: sectionLength))
            guard local.length > 0 else { continue }
            let manager = section.layoutManager
            let documentStart = manager.documentRange.location
            guard let start = manager.location(documentStart, offsetBy: local.location - section.startOffset),
                  let end = manager.location(start, offsetBy: local.length), let textRange = NSTextRange(location: start, end: end) else { continue }
            manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
                result.append(frame.offsetBy(dx: geometry.columnOrigin(0), dy: section.yOffset))
                return true
            }
        }
        return result
    }

    /// Rectangles for a rendered range on a page, in page coordinates, clipped to the page's columns.
    func rectangles(for range: NSRange, onPage index: Int) -> [CGRect] {
        guard table.pages.indices.contains(index), range.length >= 0 else { return [] }
        var result: [CGRect] = []
        let page = table.pages[index]
        for section in sections {
            let sectionLength = section.contentStorage.textStorage?.length ?? 0
            let local = NSIntersectionRange(range, NSRange(location: section.startOffset, length: sectionLength))
            guard local.length > 0 || (range.length == 0 && NSLocationInRange(range.location, NSRange(location: section.startOffset, length: sectionLength + 1))) else { continue }
            let manager = section.layoutManager
            let documentStart = manager.documentRange.location
            guard let start = manager.location(documentStart, offsetBy: max(0, range.location - section.startOffset)),
                  let end = manager.location(start, offsetBy: local.length), let textRange = NSTextRange(location: start, end: end) else { continue }
            manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
                let absolute = frame.offsetBy(dx: 0, dy: section.yOffset)
                for (column, cut) in page.columns.enumerated() where table.lines.indices.contains(cut.lastLine) {
                    let columnBottom = table.lines[cut.lastLine].frame.maxY
                    guard absolute.maxY > cut.top, absolute.minY < columnBottom + EPUBPageGeometry.cutTolerance else { continue }
                    result.append(absolute.offsetBy(dx: geometry.columnOrigin(column), dy: -cut.top))
                }
                return true
            }
        }
        return result
    }

    /// The character index at a point on a page, by the line table then the line fragment.
    func characterIndex(at point: CGPoint, onPage index: Int) -> Int? {
        guard table.pages.indices.contains(index) else { return nil }
        for (column, cut) in table.pages[index].columns.enumerated() {
            let x = geometry.columnOrigin(column)
            guard let line = table.lineIndex(in: cut, atY: point.y) else { continue }
            let record = table.lines[line]
            let frame = record.frame.offsetBy(dx: x, dy: -cut.top)
            guard point.x >= frame.minX - 1, point.x <= frame.maxX + 1, line < lineSources.count else { continue }
            let source = lineSources[line]
            let fragment = sections[source.section].lineFragments[source.fragment]
            let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
            let elementIndex = fragment.characterIndex(for: local)
            let elementStart = record.range.location - fragment.characterRange.location
            return min(record.range.location + record.range.length, max(record.range.location, elementStart + elementIndex))
        }
        return nil
    }
}

/// The anchor captured before a relayout (Spec 11.5): the first visible
/// line's rendered offset and block. The locator fallback lives with positions.
struct EPUBLayoutAnchor: Sendable, Hashable {
    let spineIndex: Int
    let renderedOffset: Int
    let blockIndex: Int?

    /// The page of a new table that contains the anchored offset.
    func page(in table: EPUBPageTable) -> Int? { table.pageIndex(containing: renderedOffset) }
}

/// The resident layouts (Spec 11.6): at most three chapters, the current and
/// its neighbours, plus page-start offsets kept per key after a layout is dropped.
@MainActor
final class EPUBLayoutCache {
    static let residentLimit = 3

    struct Slot {
        let spineIndex: Int
        let session: EPUBLayoutSession
    }

    private struct PageStartKey: Hashable {
        let spineIndex: Int
        let key: EPUBLayoutKey
    }

    private(set) var resident: [Slot] = []
    private var pageStarts: [PageStartKey: [Int]] = [:]

    func session(spineIndex: Int, key: EPUBLayoutKey) -> EPUBLayoutSession? {
        resident.first { $0.spineIndex == spineIndex && $0.session.key == key && !$0.session.isPartial }?.session
            ?? resident.first { $0.spineIndex == spineIndex && $0.session.key == key }?.session
    }

    /// Keeps a layout, replacing any older one for the chapter and dropping the
    /// layout farthest from the current chapter when the window is full.
    func store(_ session: EPUBLayoutSession, spineIndex: Int, current: Int) {
        if session.isPartial, resident.contains(where: { $0.spineIndex == spineIndex && $0.session.key == session.key && !$0.session.isPartial }) { return }
        resident.removeAll { $0.spineIndex == spineIndex && ($0.session.key != session.key || $0.session.isPartial || !session.isPartial) }
        resident.append(Slot(spineIndex: spineIndex, session: session))
        if !session.isPartial { pageStarts[PageStartKey(spineIndex: spineIndex, key: session.key)] = session.table.pages.map(\.firstOffset) }
        while resident.count > Self.residentLimit {
            guard let farthest = resident.enumerated().max(by: { abs($0.element.spineIndex - current) < abs($1.element.spineIndex - current) }) else { break }
            resident.remove(at: farthest.offset)
        }
    }

    /// Page-start offsets remembered for a chapter under a key, after its layout was dropped.
    func pageStarts(spineIndex: Int, key: EPUBLayoutKey) -> [Int]? {
        pageStarts[PageStartKey(spineIndex: spineIndex, key: key)]
    }

    /// Drops layouts outside the window around the current chapter.
    func retain(around current: Int, radius: Int = 1) {
        resident.removeAll { abs($0.spineIndex - current) > radius }
    }

    /// Memory pressure: everything but the current chapter goes.
    func shed(keeping current: Int?) {
        resident.removeAll { $0.spineIndex != current }
    }

    func removeAll() {
        resident.removeAll()
        pageStarts.removeAll()
    }
}

/// One signposter for the whole EPUB pipeline (Spec section 20).
enum OSSignposterHolder {
    static let shared = OSSignposter(subsystem: "com.camden.Funston", category: "EPUB")
}
