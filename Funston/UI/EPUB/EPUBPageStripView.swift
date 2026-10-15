import UIKit

/// What the page strip asks of its owner.
@MainActor
protocol EPUBPageStripDelegate: AnyObject {
    /// The strip settled on a page: by a swipe, a VoiceOver move or a scroll.
    func strip(_ strip: EPUBPageStripView, didShow placement: EPUBPlacement)
    func strip(_ strip: EPUBPageStripView, activateLinkAt offset: Int, spineIndex: Int) -> Bool
    /// A turn past the window's last or first page: true when the owner extended the window and turned.
    func strip(_ strip: EPUBPageStripView, turnBeyondWindow forward: Bool) -> Bool
    /// "Page p of q" within the chapter.
    func strip(_ strip: EPUBPageStripView, describe placement: EPUBPlacement) -> String
}

/// The paginated reading surface under the per-paragraph model: the pages of
/// the reading window (the current chapter and its loaded neighbours) side by
/// side in a horizontal paging scroll view. Every page's paragraphs are
/// persistent text elements (WWDC26 session 219), so VoiceOver's own reading
/// order carries Read All, swipes and the Lines rotor across pages and
/// chapters, and the scroll view brings each page into view; no element VoiceOver
/// holds is ever replaced by a page turn. Pages are drawn by a few reused tiles.
@MainActor
final class EPUBPageStripView: UIScrollView, UIScrollViewDelegate {
    struct Entry {
        let placement: EPUBPlacement
        let layout: EPUBLayoutSession
        let chapter: EPUBChapterText
        let title: String?
    }

    /// Pages drawn on each side of the shown one.
    static let tileRadius = 1
    /// Pages on each side of the shown one whose paragraphs accept text interaction.
    static let interactionRadius = 1

    weak var stripDelegate: EPUBPageStripDelegate?
    var isRightToLeft = false
    /// Posts to VoiceOver; tests substitute a recorder.
    var postAccessibilityNotification: (UIAccessibility.Notification, Any?) -> Void = { UIAccessibility.post(notification: $0, argument: $1) }
    private(set) var entries: [Entry] = []
    private(set) var currentIndex = 0
    private var pages: [EPUBPlacement: EPUBStripPage] = [:]
    private var elementCache: [EPUBBlockKey: UIView] = [:]
    private var orderedElements: [UIView] = []
    /// The window index of each element's page, parallel to orderedElements.
    private var elementPageIndex: [Int] = []
    private var tiles: [Int: EPUBPageView] = [:]
    private var reusableTiles: [EPUBPageView] = []
    /// True until VoiceOver's focus enters the strip: the list then starts at the shown
    /// page so entering from the controls lands on its top. Once focus is inside, the list
    /// reaches back through the window so a swipe left, or a previous-heading move, finds
    /// the page before. Focus leaving the strip restores the start.
    private var listStartsAtShownPage = true

    struct EPUBBlockKey: Hashable {
        let placement: EPUBPlacement
        let blockIndex: Int
        let range: NSRange
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isPagingEnabled = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        alwaysBounceVertical = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .systemBackground
        delegate = self
        isAccessibilityElement = false
        accessibilityContainerType = .semanticGroup
        accessibilityIdentifier = "reader.epub.strip"
        NotificationCenter.default.addObserver(self, selector: #selector(accessibilityFocusChanged(_:)), name: UIAccessibility.elementFocusedNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var currentPlacement: EPUBPlacement? { entries.indices.contains(currentIndex) ? entries[currentIndex].placement : nil }
    var pageWidth: CGFloat { max(1, bounds.width) }

    private func x(for index: Int) -> CGFloat {
        CGFloat(isRightToLeft ? entries.count - 1 - index : index) * pageWidth
    }

    private func index(forX x: CGFloat) -> Int {
        guard !entries.isEmpty else { return 0 }
        let slot = min(max(0, Int((x / pageWidth).rounded())), entries.count - 1)
        return isRightToLeft ? entries.count - 1 - slot : slot
    }

    func textOrigin(for index: Int) -> CGPoint {
        CGPoint(x: x(for: index) + EPUBPageView.margin, y: EPUBPageView.margin)
    }

    // MARK: Loading

    /// Shows a window of pages. Pages and paragraph elements already present keep
    /// their objects; the content offset follows the shown page so nothing moves under the reader.
    func load(_ newEntries: [Entry], showing placement: EPUBPlacement) {
        entries = newEntries
        currentIndex = newEntries.firstIndex { $0.placement == placement } ?? 0
        contentSize = CGSize(width: pageWidth * CGFloat(newEntries.count), height: bounds.height)
        contentOffset = CGPoint(x: x(for: currentIndex), y: 0)
        rebuildElements()
        updateTiles()
        updateLabel()
    }

    /// Shows a page of the loaded window.
    func show(_ placement: EPUBPlacement, animated: Bool) {
        guard let index = entries.firstIndex(where: { $0.placement == placement }) else { return }
        setCurrent(index)
        setContentOffset(CGPoint(x: x(for: index), y: 0), animated: animated && !UIAccessibility.isReduceMotionEnabled)
        updateTiles()
    }

    /// The page after or before the shown one; false at the window's end.
    @discardableResult
    func turn(forward: Bool, animated: Bool) -> Bool {
        let next = currentIndex + (forward ? 1 : -1)
        guard entries.indices.contains(next) else { return false }
        show(entries[next].placement, animated: animated)
        stripDelegate?.strip(self, didShow: entries[next].placement)
        return true
    }

    private func setCurrent(_ index: Int) {
        guard index != currentIndex else { return }
        currentIndex = index
        updateInteraction()
        updateElementList()
        updateLabel()
    }

    private func updateLabel() {
        accessibilityLabel = entries.indices.contains(currentIndex) ? entries[currentIndex].title : nil
    }

    // MARK: Accessibility elements

    private func rebuildElements() {
        var newPages: [EPUBPlacement: EPUBStripPage] = [:]
        var newCache: [EPUBBlockKey: UIView] = [:]
        var ordered: [UIView] = []
        var pageIndices: [Int] = []
        for (index, entry) in entries.enumerated() {
            let page = pages[entry.placement] ?? EPUBStripPage(strip: self, entry: entry)
            page.origin = textOrigin(for: index)
            newPages[entry.placement] = page
            guard let range = page.pageRange else { continue }
            for (blockIndex, block) in entry.chapter.blocks.enumerated() {
                let visible = NSIntersectionRange(block.range, range)
                guard visible.length > 0, !entry.chapter.text(in: visible).allSatisfy(\.isWhitespace) else { continue }
                let key = EPUBBlockKey(placement: entry.placement, blockIndex: blockIndex, range: visible)
                let view = elementCache[key] ?? (block.kind == .image ? EPUBFigureView(page: page, blockIndex: blockIndex, range: visible, block: block)
                                                                       : EPUBParagraphView(page: page, blockIndex: blockIndex, range: visible, block: block))
                newCache[key] = view
                ordered.append(view)
                pageIndices.append(index)
            }
        }
        for (key, view) in elementCache where newCache[key] == nil { view.removeFromSuperview() }
        let paragraphs = ordered.compactMap { $0 as? EPUBParagraphView }
        for (position, paragraph) in paragraphs.enumerated() {
            paragraph.previousParagraph = position > 0 ? paragraphs[position - 1] : nil
            paragraph.nextParagraph = position + 1 < paragraphs.count ? paragraphs[position + 1] : nil
        }
        for view in ordered where view.superview !== self { addSubview(view) }
        pages = newPages
        elementCache = newCache
        orderedElements = ordered
        elementPageIndex = pageIndices
        layoutElements()
        updateInteraction()
        updateElementList()
        EPUBAccessibilityLog.shared.record("strip loaded \(entries.count) pages, \(ordered.count) paragraph elements, showing index \(currentIndex)")
    }

    /// VoiceOver's list starts at the shown page's first paragraph, so entering the
    /// page from the controls lands on its top; it runs on through the window, so Read All
    /// and swipes continue into the following pages and the next chapter. With focus
    /// inside the strip it is the whole window, so swipes also lead back.
    private func updateElementList() {
        let start = listStartsAtShownPage ? (elementPageIndex.firstIndex { $0 >= currentIndex } ?? orderedElements.count) : 0
        accessibilityElements = Array(orderedElements[start...])
    }

    @objc private func accessibilityFocusChanged(_ notification: Notification) {
        focusDidMove(to: notification.userInfo?[UIAccessibility.focusedElementUserInfoKey])
    }

    /// VoiceOver's focus moved to an element: inside the strip the list reaches back
    /// through the window; outside it, the list starts at the shown page again.
    func focusDidMove(to element: Any?) {
        guard let element else { return }
        let inside = (element as? UIView).map { $0.isDescendant(of: self) } ?? false
        EPUBAccessibilityLog.shared.record("focus \(inside ? "inside" : "outside") the page strip: \(type(of: element))")
        if listStartsAtShownPage == inside {
            listStartsAtShownPage = !inside
            updateElementList()
        }
        // The focus callback on the paragraph views does not arrive on iOS 26 (VoiceOver
        // report, 2026-10-15), so the notification also brings the focused page into view.
        if let page = ((element as? EPUBParagraphView)?.page ?? (element as? EPUBFigureView)?.page) as? EPUBStripPage { pageDidReceiveFocus(page) }
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

    private func updateInteraction() {
        guard entries.indices.contains(currentIndex) else { return }
        let near = Set((max(0, currentIndex - Self.interactionRadius)...min(entries.count - 1, currentIndex + Self.interactionRadius)).map { entries[$0].placement })
        for view in orderedElements {
            guard let paragraph = view as? EPUBParagraphView, let page = paragraph.page as? EPUBStripPage else { continue }
            paragraph.isInteractive = near.contains(page.placement)
        }
    }

    /// VoiceOver moved onto a paragraph: show its page, aligned, if it is not the shown one.
    func pageDidReceiveFocus(_ page: EPUBStripPage) {
        if listStartsAtShownPage { listStartsAtShownPage = false; updateElementList() }
        guard let index = entries.firstIndex(where: { $0.placement == page.placement }), index != currentIndex else { return }
        EPUBAccessibilityLog.shared.record("focus moved to spine \(page.placement.spineIndex) page \(page.placement.pageIndex): showing it")
        setCurrent(index)
        contentOffset = CGPoint(x: x(for: index), y: 0)
        updateTiles()
        stripDelegate?.strip(self, didShow: page.placement)
    }

    /// A three-finger swipe: one page, announced within the chapter.
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let forward: Bool
        switch direction {
        case .next, .down: forward = true
        case .previous, .up: forward = false
        case .left: forward = !isRightToLeft
        case .right: forward = isRightToLeft
        @unknown default: return false
        }
        EPUBAccessibilityLog.shared.record("strip accessibilityScroll direction=\(direction.rawValue) forward=\(forward) from index \(currentIndex)")
        guard turn(forward: forward, animated: false) || stripDelegate?.strip(self, turnBeyondWindow: forward) == true, let placement = currentPlacement else { return false }
        postAccessibilityNotification(.pageScrolled, stripDelegate?.strip(self, describe: placement) ?? "")
        if let first = firstElementOnShownPage { postAccessibilityNotification(.layoutChanged, first) }
        EPUBAccessibilityLog.shared.recordFocusLater(context: "strip scroll")
        return true
    }

    // MARK: Tiles

    private func updateTiles() {
        guard !entries.isEmpty else { return }
        let wanted = Set(max(0, currentIndex - Self.tileRadius)...min(entries.count - 1, currentIndex + Self.tileRadius))
        for (index, tile) in tiles where !wanted.contains(index) {
            tile.removeFromSuperview()
            reusableTiles.append(tile)
            tiles[index] = nil
        }
        for index in wanted where tiles[index] == nil {
            let tile = reusableTiles.popLast() ?? {
                let view = EPUBPageView()
                view.isTile = true
                view.isUserInteractionEnabled = false
                return view
            }()
            let entry = entries[index]
            tile.frame = CGRect(x: x(for: index), y: 0, width: pageWidth, height: bounds.height)
            tile.show(entry.layout, page: entry.placement.pageIndex, spineIndex: entry.placement.spineIndex, chapter: entry.chapter, title: entry.title)
            tile.selection = pages[entry.placement]?.selection
            insertSubview(tile, at: 0)
            tiles[index] = tile
        }
    }

    func redrawSelection(for placement: EPUBPlacement) {
        guard let index = entries.firstIndex(where: { $0.placement == placement }), let tile = tiles[index] else { return }
        tile.selection = pages[placement]?.selection
    }

    // MARK: Hit testing for the reader's taps

    /// The page and character under a point in the strip's coordinates.
    func characterIndex(at point: CGPoint) -> (placement: EPUBPlacement, offset: Int)? {
        let index = index(forX: point.x)
        guard entries.indices.contains(index), let page = pages[entries[index].placement], let offset = page.characterIndex(at: point) else { return nil }
        return (entries[index].placement, offset)
    }

    /// The first element of the shown page, for focus after a jump.
    var firstElementOnShownPage: UIView? {
        guard let start = elementPageIndex.firstIndex(of: currentIndex) else { return nil }
        return orderedElements[start]
    }

    // MARK: Scrolling

    override func layoutSubviews() {
        super.layoutSubviews()
        if contentSize.height != bounds.height { contentSize.height = bounds.height }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let index = index(forX: contentOffset.x)
        if index != currentIndex, !isDragging, !isDecelerating { return }
        updateTilesNear(index)
    }

    private func updateTilesNear(_ index: Int) {
        let saved = currentIndex
        currentIndex = index
        updateTiles()
        currentIndex = saved
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { settle() } }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settle() }

    private func settle() {
        let index = index(forX: contentOffset.x)
        guard entries.indices.contains(index) else { return }
        let changed = index != currentIndex
        setCurrent(index)
        updateTiles()
        if changed { stripDelegate?.strip(self, didShow: entries[index].placement) }
    }
}

/// One page of the strip as a text page: geometry in the strip's coordinates.
@MainActor
final class EPUBStripPage: EPUBTextPage {
    private weak var strip: EPUBPageStripView?
    let entry: EPUBPageStripView.Entry
    var origin: CGPoint = .zero
    var selection: NSRange? { didSet { strip?.redrawSelection(for: entry.placement) } }

    init(strip: EPUBPageStripView, entry: EPUBPageStripView.Entry) {
        self.strip = strip
        self.entry = entry
    }

    var placement: EPUBPlacement { entry.placement }
    var layout: EPUBLayoutSession? { entry.layout }
    var chapter: EPUBChapterText? { entry.chapter }
    var pageIndex: Int { entry.placement.pageIndex }
    var spineIndex: Int { entry.placement.spineIndex }
    var coordinateView: UIView { strip ?? UIView() }

    var pageRange: NSRange? {
        entry.layout.table.pages.indices.contains(pageIndex) ? entry.layout.table.pages[pageIndex].range : nil
    }

    func rectangles(for range: NSRange) -> [CGRect] {
        entry.layout.rectangles(for: range, onPage: pageIndex).map { $0.offsetBy(dx: origin.x, dy: origin.y) }
    }

    func characterIndex(at point: CGPoint) -> Int? {
        entry.layout.characterIndex(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y), onPage: pageIndex)
    }

    func lineFrames() -> [(line: Int, frame: CGRect)] {
        entry.layout.table.lineFrames(onPage: pageIndex).map { ($0.line, $0.frame.offsetBy(dx: origin.x, dy: origin.y)) }
    }

    func attributedText(for range: NSRange) -> NSAttributedString {
        EPUBPageView.accessibleText(in: entry.layout.string, range: range)
    }

    func activateLink(at offset: Int) -> Bool {
        guard let strip else { return false }
        return strip.stripDelegate?.strip(strip, activateLinkAt: offset, spineIndex: spineIndex) ?? false
    }

    func scroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        strip?.accessibilityScroll(direction) ?? false
    }

    func paragraphDidBecomeFocused(_ paragraph: UIView) {
        strip?.pageDidReceiveFocus(self)
    }
}
