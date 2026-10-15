import CoreGraphics
import Foundation

/// The page content geometry (Spec section 11.1): the content size, and
/// one column or two by the named thresholds.
struct EPUBPageGeometry: Sendable, Hashable {
    /// Two columns when the content width is at least this many base sizes.
    static let twoColumnMeasureFactor: CGFloat = 60
    /// A line is never longer than this many base sizes.
    static let maximumLineLengthFactor: CGFloat = 40
    /// The gap between two columns, in base sizes.
    static let columnGapFactor: CGFloat = 2
    /// Lines whose bottom crosses the page by less than this still fit.
    static let cutTolerance: CGFloat = 0.01

    let contentSize: CGSize
    let columnCount: Int
    let columnWidth: CGFloat
    let columnGap: CGFloat

    init(contentSize: CGSize, baseFontSize: CGFloat, allowsTwoColumns: Bool) {
        self.contentSize = contentSize
        let base = max(1, baseFontSize)
        let twoColumns = allowsTwoColumns && contentSize.width >= Self.twoColumnMeasureFactor * base
        columnCount = twoColumns ? 2 : 1
        columnGap = twoColumns ? Self.columnGapFactor * base : 0
        let available = (contentSize.width - columnGap * CGFloat(columnCount - 1)) / CGFloat(columnCount)
        columnWidth = min(available, Self.maximumLineLengthFactor * base)
    }

    /// The x of a column's leading edge, centring the text block.
    func columnOrigin(_ column: Int) -> CGFloat {
        let block = columnWidth * CGFloat(columnCount) + columnGap * CGFloat(columnCount - 1)
        let inset = max(0, (contentSize.width - block) / 2)
        return inset + CGFloat(column) * (columnWidth + columnGap)
    }
}

/// One laid-out line: its rendered range and frame in container coordinates.
struct EPUBLineRecord: Sendable, Hashable {
    let range: NSRange
    let frame: CGRect
    /// The index of the layout fragment (one per paragraph) the line belongs to.
    let fragmentIndex: Int
    /// True when the block's first character forces a page break before this line.
    let forcesBreakBefore: Bool
    /// True when the line belongs to a keep-together block.
    let keepsTogether: Bool
}

/// One column cut: a contiguous run of lines and the y of its top.
struct EPUBColumnCut: Sendable, Hashable {
    let firstLine: Int
    let lastLine: Int
    let top: CGFloat
    var lineRange: ClosedRange<Int> { firstLine...lastLine }
}

/// A page: one column cut, or two consecutive ones on wide surfaces.
struct EPUBPageRecord: Sendable, Hashable {
    let columns: [EPUBColumnCut]
    let firstOffset: Int
    let endOffset: Int
    var firstLine: Int { columns.first?.firstLine ?? 0 }
    var lastLine: Int { columns.last?.lastLine ?? 0 }
    var range: NSRange { NSRange(location: firstOffset, length: endOffset - firstOffset) }
}

/// The line table and page table of one chapter under one layout key.
struct EPUBPageTable: Sendable, Hashable {
    let lines: [EPUBLineRecord]
    let pages: [EPUBPageRecord]
    let geometry: EPUBPageGeometry

    /// Widow and orphan control: no paragraph leaves fewer than this many lines on either side of a cut.
    static let minimumLinesEachSide = 2

    /// Cuts columns where a line's bottom would cross the page height, then groups them into pages.
    static func paginate(lines: [EPUBLineRecord], geometry: EPUBPageGeometry) -> EPUBPageTable {
        let cuts = columnCuts(lines: lines, height: geometry.contentSize.height)
        var pages: [EPUBPageRecord] = []
        var index = 0
        while index < cuts.count {
            let group = Array(cuts[index..<min(cuts.count, index + geometry.columnCount)])
            let first = lines[group[0].firstLine].range.location
            let last = lines[group[group.count - 1].lastLine].range
            pages.append(EPUBPageRecord(columns: group, firstOffset: first, endOffset: last.location + last.length))
            index += geometry.columnCount
        }
        return EPUBPageTable(lines: lines, pages: pages, geometry: geometry)
    }

    /// The cut rules of Spec 11.2 over a line table.
    static func columnCuts(lines: [EPUBLineRecord], height: CGFloat) -> [EPUBColumnCut] {
        guard !lines.isEmpty else { return [] }
        var cuts: [EPUBColumnCut] = []
        var start = 0
        var top = lines[0].frame.minY
        var index = 1
        func close(before cutIndex: Int) {
            cuts.append(EPUBColumnCut(firstLine: start, lastLine: cutIndex - 1, top: top))
            start = cutIndex
            top = lines[cutIndex].frame.minY
        }
        while index < lines.count {
            let line = lines[index]
            if line.forcesBreakBefore && index > start {
                close(before: index); index += 1; continue
            }
            let overflows = line.frame.maxY - top > height + EPUBPageGeometry.cutTolerance
            guard overflows else { index += 1; continue }
            var cutAt = index
            // Keep-together: a block that would straddle the cut moves whole, unless longer than a page.
            if line.keepsTogether {
                var blockStart = index
                while blockStart > start, lines[blockStart - 1].keepsTogether { blockStart -= 1 }
                var blockEnd = index
                while blockEnd + 1 < lines.count, lines[blockEnd + 1].keepsTogether { blockEnd += 1 }
                let blockHeight = lines[blockEnd].frame.maxY - lines[blockStart].frame.minY
                if blockStart > start, blockHeight <= height { cutAt = blockStart }
            }
            // Widows and orphans: move the cut up by at most two lines.
            cutAt = adjustedForWidowsAndOrphans(lines: lines, cut: cutAt, start: start)
            if cutAt <= start { cutAt = index }
            close(before: cutAt)
            index = cutAt + 1
        }
        cuts.append(EPUBColumnCut(firstLine: start, lastLine: lines.count - 1, top: top))
        return cuts
    }

    private static func adjustedForWidowsAndOrphans(lines: [EPUBLineRecord], cut: Int, start: Int) -> Int {
        var cut = cut
        for _ in 0..<minimumLinesEachSide {
            guard cut > start + 1, cut < lines.count else { break }
            let fragment = lines[cut].fragmentIndex
            let previousInSameParagraph = lines[cut - 1].fragmentIndex == fragment
            let nextInSameParagraph = cut + 1 < lines.count && lines[cut + 1].fragmentIndex == fragment
            let paragraphStartsAbove = cut - 2 >= start ? lines[cut - 2].fragmentIndex == fragment : false
            // A single line left on the next page (widow) or a single line left behind (orphan).
            let widow = previousInSameParagraph && !nextInSameParagraph
            let orphan = previousInSameParagraph && !paragraphStartsAbove && (cut - 1 == start || lines[cut - 1].fragmentIndex != lines[max(start, cut - 2)].fragmentIndex)
            if widow || orphan { cut -= 1 } else { break }
        }
        return cut
    }

    /// The page containing a rendered offset, by binary search on first offsets.
    func pageIndex(containing offset: Int) -> Int? {
        guard !pages.isEmpty else { return nil }
        var low = 0, high = pages.count - 1
        var result = 0
        while low <= high {
            let middle = (low + high) / 2
            if pages[middle].firstOffset <= offset { result = middle; low = middle + 1 } else { high = middle - 1 }
        }
        return result
    }

    /// The line within a column at a y, by binary search; nil in the gaps.
    func lineIndex(in cut: EPUBColumnCut, atY y: CGFloat) -> Int? {
        guard lines.indices.contains(cut.firstLine), lines.indices.contains(cut.lastLine) else { return nil }
        var low = cut.firstLine, high = cut.lastLine
        while low <= high {
            let middle = (low + high) / 2
            let frame = lines[middle].frame.offsetBy(dx: 0, dy: -cut.top)
            if y < frame.minY { high = middle - 1 } else if y > frame.maxY { low = middle + 1 } else { return middle }
        }
        return nil
    }

    /// Line frames of a page, in page coordinates, with the column origin applied.
    func lineFrames(onPage page: Int) -> [(line: Int, frame: CGRect)] {
        guard pages.indices.contains(page) else { return [] }
        var result: [(Int, CGRect)] = []
        for (column, cut) in pages[page].columns.enumerated() {
            let x = geometry.columnOrigin(column)
            for index in cut.lineRange where lines.indices.contains(index) {
                result.append((index, lines[index].frame.offsetBy(dx: x, dy: -cut.top)))
            }
        }
        return result
    }
}
