import UIKit

/// What the continuous strip asks of its owner.
@MainActor
protocol EPUBContinuousStripDelegate: AnyObject {
    /// Scrolling settled, or VoiceOver moved: the first visible character.
    func continuousStrip(_ strip: EPUBContinuousStripView, didSettleAt offset: Int, spineIndex: Int)
    func continuousStrip(_ strip: EPUBContinuousStripView, activateLinkAt offset: Int, spineIndex: Int) -> Bool
    /// What a three-finger scroll announces ("Location n of m").
    func continuousStrip(_ strip: EPUBContinuousStripView, describeOffset offset: Int, spineIndex: Int) -> String
}

/// The continuous reading surface (Spec 11.4) on the same footing as the page
/// strip and PDFKit's continuous mode: the reading window's chapters stacked in
/// one vertical scroll view, every paragraph a persistent text element (WWDC26
/// session 219) that is never rebuilt while reading. VoiceOver's list starts at
/// the first visible paragraph; focus brings its paragraph into view; a
/// three-finger scroll moves one screen and lands on the first paragraph there.
/// Lines are drawn by screen-sized tiles reused as the view scrolls.
@MainActor
final class EPUBContinuousStripView: UIScrollView, UIScrollViewDelegate {
    struct Chapter {
        let spineIndex: Int
        let layout: EPUBLayoutSession
        let text: EPUBChapterText
        let title: String?
    }

    static let margin: CGFloat = EPUBPageView.margin
    /// Tiles drawn above and below the visible one.
    static let tileRadius = 1
    /// How far a paragraph may sit from the top before focusing it scrolls it there.
    static let focusTopInset: CGFloat = EPUBPageView.margin
    /// A paragraph counts as visible when more than this much of it is below the top edge:
    /// after a jump the paragraph before the target ends inside the top inset, a sliver
    /// VoiceOver should not land on.
    static let visibleThreshold: CGFloat = focusTopInset

    weak var stripDelegate: EPUBContinuousStripDelegate?
    /// Posts to VoiceOver; tests substitute a recorder.
    var postAccessibilityNotification: (UIAccessibility.Notification, Any?) -> Void = { UIAccessibility.post(notification: $0, argument: $1) }
    private(set) var chapters: [Chapter] = []
    private var columns: [Int: EPUBChapterColumn] = [:]
    private var elementCache: [Key: UIView] = [:]
    private var orderedElements: [UIView] = []
    private var tiles: [Int: EPUBLineTileView] = [:]
    private var reusableTiles: [EPUBLineTileView] = []
    private var listStart = -1

    struct Key: Hashable {
        let spineIndex: Int
        let blockIndex: Int
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        alwaysBounceVertical = true
        contentInsetAdjustmentBehavior = .never
        delegate = self
        isAccessibilityElement = false
        accessibilityIdentifier = "reader.epub.continuous"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func chapterHeight(_ chapter: Chapter) -> CGFloat { chapter.layout.contentHeight + 2 * Self.margin }

    private func top(ofChapterAt index: Int) -> CGFloat {
        chapters.prefix(index).reduce(0) { $0 + chapterHeight($1) }
    }

    // MARK: Loading

    /// Shows the window's chapters with an offset of one chapter at the top of the view.
    /// Paragraph elements already present keep their objects.
    func load(_ newChapters: [Chapter], showing offset: Int, in spineIndex: Int) {
        chapters = newChapters
        var newColumns: [Int: EPUBChapterColumn] = [:]
        for (index, chapter) in newChapters.enumerated() {
            let column = columns[chapter.spineIndex].flatMap { $0.source.layout === chapter.layout ? $0 : nil } ?? EPUBChapterColumn(strip: self, chapter: chapter)
            column.origin = CGPoint(x: Self.margin, y: top(ofChapterAt: index) + Self.margin)
            newColumns[chapter.spineIndex] = column
        }
        columns = newColumns
        contentSize = CGSize(width: bounds.width, height: max(bounds.height, newChapters.reduce(0) { $0 + chapterHeight($1) }))
        rebuildElements()
        scroll(toOffset: offset, in: spineIndex)
        resetTiles()
    }

    /// Puts the line holding an offset at the top of the view.
    func scroll(toOffset offset: Int, in spineIndex: Int, animated: Bool = false) {
        guard let column = columns[spineIndex] else { return }
        let line = column.source.layout.table.lines.first { $0.range.location + $0.range.length > offset }
        let y = (line?.frame.minY ?? 0) + column.origin.y - Self.margin
        setContentOffset(CGPoint(x: 0, y: clampedY(y)), animated: animated && !UIAccessibility.isReduceMotionEnabled)
        updateTiles()
        updateElementList()
    }

    private func clampedY(_ y: CGFloat) -> CGFloat { max(0, min(y, contentSize.height - bounds.height)) }

    // MARK: Position

    /// The first visible character: the chapter and the offset of the first line whose bottom is below the top edge.
    var firstVisible: (spineIndex: Int, offset: Int)? {
        let y = contentOffset.y
        for (index, chapter) in chapters.enumerated() {
            guard let column = columns[chapter.spineIndex] else { continue }
            let top = self.top(ofChapterAt: index)
            guard y < top + chapterHeight(chapter) else { continue }
            let localY = y - column.origin.y
            if let line = chapter.layout.table.lines.first(where: { $0.frame.maxY > localY }) { return (chapter.spineIndex, line.range.location) }
            return (chapter.spineIndex, chapter.text.length)
        }
        return nil
    }

    // MARK: Elements

    private func rebuildElements() {
        var newCache: [Key: UIView] = [:]
        var ordered: [UIView] = []
        for chapter in chapters {
            guard let column = columns[chapter.spineIndex] else { continue }
            for (blockIndex, block) in chapter.text.blocks.enumerated() {
                guard block.range.length > 0, !chapter.text.text(in: block.range).allSatisfy(\.isWhitespace) else { continue }
                let key = Key(spineIndex: chapter.spineIndex, blockIndex: blockIndex)
                let view = elementCache[key].flatMap { ($0 as? EPUBParagraphView)?.page === column || ($0 as? EPUBFigureView)?.page === column ? $0 : nil }
                    ?? (block.kind == .image ? EPUBFigureView(page: column, blockIndex: blockIndex, range: block.range, block: block)
                                             : EPUBParagraphView(page: column, blockIndex: blockIndex, range: block.range, block: block))
                newCache[key] = view
                ordered.append(view)
            }
        }
        for (key, view) in elementCache where newCache[key] !== view { view.removeFromSuperview() }
        let paragraphs = ordered.compactMap { $0 as? EPUBParagraphView }
        for (position, paragraph) in paragraphs.enumerated() {
            paragraph.previousParagraph = position > 0 ? paragraphs[position - 1] : nil
            paragraph.nextParagraph = position + 1 < paragraphs.count ? paragraphs[position + 1] : nil
            paragraph.isInteractive = true
        }
        for view in ordered where view.superview !== self { addSubview(view) }
        elementCache = newCache
        orderedElements = ordered
        layoutElements()
        listStart = -1
        updateElementList()
        EPUBAccessibilityLog.shared.record("continuous strip loaded \(chapters.count) chapters, \(ordered.count) paragraph elements")
    }

    private func layoutElements() {
        for view in orderedElements {
            let range = (view as? EPUBParagraphView)?.range ?? (view as? EPUBFigureView)?.range
            let page = (view as? EPUBParagraphView)?.page ?? (view as? EPUBFigureView)?.page
            guard let range, let page else { continue }
            let union = page.rectangles(for: range).reduce(CGRect.null) { $0.union($1) }
            view.frame = union.isNull ? .zero : union
        }
    }

    /// VoiceOver's list starts at the first paragraph that reaches more than a sliver below the top edge.
    private func updateElementList() {
        let edge = contentOffset.y + Self.visibleThreshold
        let start = orderedElements.firstIndex { $0.frame.maxY > edge } ?? max(0, orderedElements.count - 1)
        guard start != listStart, !orderedElements.isEmpty else { return }
        listStart = start
        accessibilityElements = Array(orderedElements[start...])
    }

    var firstVisibleElement: UIView? { orderedElements.first { $0.frame.maxY > contentOffset.y + Self.visibleThreshold } }

    /// VoiceOver moved onto a paragraph: bring it into view if it is not, and make it
    /// the reading position (the scroll offset after a move can still touch the end of
    /// the chapter above, which is not where the reader is).
    func paragraphDidReceiveFocus(_ view: UIView) {
        let visible = CGRect(origin: contentOffset, size: bounds.size)
        if !visible.contains(CGRect(x: view.frame.minX, y: view.frame.minY, width: 1, height: min(view.frame.height, bounds.height / 2))) {
            contentOffset = CGPoint(x: 0, y: clampedY(view.frame.minY - Self.focusTopInset))
            updateTiles()
        }
        guard let range = (view as? EPUBParagraphView)?.range ?? (view as? EPUBFigureView)?.range,
              let page = (view as? EPUBParagraphView)?.page ?? (view as? EPUBFigureView)?.page else { return }
        stripDelegate?.continuousStrip(self, didSettleAt: range.location, spineIndex: page.spineIndex)
    }

    /// A three-finger scroll: one screen, announced as a location, landing on the first paragraph there.
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let forward: Bool
        switch direction {
        case .next, .down, .left: forward = true
        case .previous, .up, .right: forward = false
        @unknown default: return false
        }
        EPUBAccessibilityLog.shared.record("continuous strip accessibilityScroll forward=\(forward) y=\(contentOffset.y)")
        guard page(forward: forward) else { return false }
        if let position = firstVisible {
            postAccessibilityNotification(.pageScrolled, stripDelegate?.continuousStrip(self, describeOffset: position.offset, spineIndex: position.spineIndex) ?? "")
        }
        if let first = firstVisibleElement { postAccessibilityNotification(.layoutChanged, first) }
        EPUBAccessibilityLog.shared.recordFocusLater(context: "continuous strip scroll")
        return true
    }

    /// One screen forward or back; false at the window's ends. Moves no VoiceOver focus.
    @discardableResult
    func page(forward: Bool) -> Bool {
        let step = bounds.height - 2 * Self.margin
        let target = clampedY(contentOffset.y + (forward ? step : -step))
        guard abs(target - contentOffset.y) > 0.5 else { return false }
        contentOffset = CGPoint(x: 0, y: target)
        updateTiles()
        updateElementList()
        report()
        return true
    }

    private func report() {
        guard let position = firstVisible else { return }
        stripDelegate?.continuousStrip(self, didSettleAt: position.offset, spineIndex: position.spineIndex)
    }

    // MARK: Tiles

    private var tileHeight: CGFloat { max(1, bounds.height) }

    private func resetTiles() {
        for (_, tile) in tiles { tile.removeFromSuperview(); reusableTiles.append(tile) }
        tiles = [:]
        updateTiles()
    }

    private func updateTiles() {
        guard contentSize.height > 0 else { return }
        let current = Int(contentOffset.y / tileHeight)
        let last = Int((contentSize.height - 1) / tileHeight)
        let wanted = Set(max(0, current - Self.tileRadius)...max(0, min(last, current + Self.tileRadius + 1)))
        for (index, tile) in tiles where !wanted.contains(index) {
            tile.removeFromSuperview()
            reusableTiles.append(tile)
            tiles[index] = nil
        }
        for index in wanted where tiles[index] == nil {
            let tile = reusableTiles.popLast() ?? EPUBLineTileView()
            tile.frame = CGRect(x: 0, y: CGFloat(index) * tileHeight, width: bounds.width, height: tileHeight)
            tile.strip = self
            tile.setNeedsDisplay()
            insertSubview(tile, at: 0)
            tiles[index] = tile
        }
    }

    /// Draws the lines of every chapter that intersect a rect of the strip, into a
    /// context whose origin sits at `contextOrigin` in the strip.
    func drawLines(in rect: CGRect, contextOrigin: CGPoint, context: CGContext) {
        for chapter in chapters {
            guard let column = columns[chapter.spineIndex] else { continue }
            let local = rect.offsetBy(dx: -column.origin.x, dy: -column.origin.y)
            guard local.maxY > 0, local.minY < chapter.layout.contentHeight else { continue }
            chapter.layout.drawLines(intersecting: local, in: context, origin: CGPoint(x: column.origin.x - contextOrigin.x, y: column.origin.y - contextOrigin.y))
        }
    }

    // MARK: Hit testing for taps

    func characterIndex(at point: CGPoint) -> (spineIndex: Int, offset: Int)? {
        for chapter in chapters {
            guard let column = columns[chapter.spineIndex], let offset = column.characterIndex(at: point) else { continue }
            return (chapter.spineIndex, offset)
        }
        return nil
    }

    // MARK: Scrolling

    override func layoutSubviews() {
        super.layoutSubviews()
        if contentSize.width != bounds.width { contentSize.width = bounds.width }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateTiles()
        if isDragging || isDecelerating { updateElementList() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settled() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { settled() } }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settled() }

    private func settled() {
        updateElementList()
        report()
    }
}

/// One chapter of the continuous strip as a text page: geometry in the strip's coordinates.
@MainActor
final class EPUBChapterColumn: EPUBTextPage {
    private weak var strip: EPUBContinuousStripView?
    let source: EPUBContinuousStripView.Chapter
    /// The chapter's text origin in the strip.
    var origin: CGPoint = .zero
    var selection: NSRange?

    init(strip: EPUBContinuousStripView, chapter: EPUBContinuousStripView.Chapter) {
        self.strip = strip
        source = chapter
    }

    var layout: EPUBLayoutSession? { source.layout }
    var chapter: EPUBChapterText? { source.text }
    var pageIndex: Int { 0 }
    var spineIndex: Int { source.spineIndex }
    var coordinateView: UIView { strip ?? UIView() }

    func rectangles(for range: NSRange) -> [CGRect] {
        source.layout.surfaceRectangles(for: range).map { $0.offsetBy(dx: origin.x, dy: origin.y) }
    }

    func characterIndex(at point: CGPoint) -> Int? {
        source.layout.characterIndex(atSurfacePoint: CGPoint(x: point.x - origin.x, y: point.y - origin.y))
    }

    func lineFrames() -> [(line: Int, frame: CGRect)] {
        let x = source.layout.geometry.columnOrigin(0)
        return source.layout.table.lines.enumerated().map { ($0.offset, $0.element.frame.offsetBy(dx: origin.x + x, dy: origin.y)) }
    }

    func attributedText(for range: NSRange) -> NSAttributedString {
        EPUBPageView.accessibleText(in: source.layout.string, range: range)
    }

    func activateLink(at offset: Int) -> Bool {
        guard let strip else { return false }
        return strip.stripDelegate?.continuousStrip(strip, activateLinkAt: offset, spineIndex: spineIndex) ?? false
    }

    func scroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        strip?.accessibilityScroll(direction) ?? false
    }

    func paragraphDidBecomeFocused(_ paragraph: UIView) {
        strip?.paragraphDidReceiveFocus(paragraph)
    }
}

/// A screen-sized tile of the continuous strip: draws the lines in its frame.
@MainActor
final class EPUBLineTileView: UIView {
    weak var strip: EPUBContinuousStripView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .systemBackground
        contentMode = .redraw
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let strip else { return }
        strip.drawLines(in: rect.offsetBy(dx: frame.minX, dy: frame.minY), contextOrigin: frame.origin, context: context)
    }
}
