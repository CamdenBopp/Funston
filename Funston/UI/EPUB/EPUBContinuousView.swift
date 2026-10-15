import UIKit

/// The continuous surface of one chapter (Spec 11.4): a vertical scroll view
/// whose content draws the line table in tiles. Crossing to the neighbouring
/// chapter is the owner's decision, reported through `crossingRequested`.
@MainActor
final class EPUBContinuousView: UIScrollView, UIScrollViewDelegate {
    /// Dragging past the end by this much asks for the next chapter.
    static let crossingOverscroll: CGFloat = 48
    static let margin: CGFloat = EPUBPageView.margin

    private(set) var layout: EPUBLayoutSession?
    private(set) var spineIndex = 0
    private(set) var chapter: EPUBChapterText?
    weak var pageDelegate: EPUBPageViewDelegate?
    /// Block elements are rebuilt when the visible rect moves by more than this.
    static let elementRefreshDistance: CGFloat = 40
    private var elementsOrigin: CGFloat = -1
    private var elements: [EPUBSurfaceBlockElement] = []
    private let surface = EPUBSurfaceView()
    /// Called with +1 at the end and -1 at the start when the reader drags past them.
    var crossingRequested: ((Int) -> Void)?
    /// Called when scrolling settles so the owner can report the position.
    var settled: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        alwaysBounceVertical = true
        delegate = self
        addSubview(surface)
        surface.isAccessibilityElement = false
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ layout: EPUBLayoutSession?, spineIndex: Int, chapter: EPUBChapterText? = nil, title: String? = nil, atOffset offset: Int?) {
        self.layout = layout
        self.spineIndex = spineIndex
        self.chapter = chapter
        accessibilityLabel = title
        accessibilityContainerType = .semanticGroup
        elementsOrigin = -1
        surface.layout = layout
        let height = (layout?.contentHeight ?? 0) + 2 * Self.margin
        surface.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        contentSize = CGSize(width: bounds.width, height: max(height, bounds.height))
        if let offset, let line = layout?.table.lines.first(where: { $0.range.location + $0.range.length > offset }) {
            contentOffset = CGPoint(x: 0, y: max(0, min(line.frame.minY, contentSize.height - bounds.height)))
        } else {
            contentOffset = .zero
        }
        surface.setNeedsDisplay()
        // The element window follows the restored offset, and VoiceOver is told to fetch it again.
        elementsOrigin = -1
        elements = []
        if UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .layoutChanged, argument: nil) }
    }

    /// Scrolls so the line containing an offset is at the top.
    func scroll(toOffset offset: Int, animated: Bool) {
        guard let line = layout?.table.lines.first(where: { $0.range.location + $0.range.length > offset }) else { return }
        setContentOffset(CGPoint(x: 0, y: max(0, min(line.frame.minY, contentSize.height - bounds.height))), animated: animated)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if surface.frame.width != bounds.width {
            surface.frame.size.width = bounds.width
            contentSize.width = bounds.width
            surface.setNeedsDisplay()
        }
    }

    /// The first rendered offset whose line is at or below the top of the viewport.
    var firstVisibleOffset: Int? {
        guard let layout else { return nil }
        let top = contentOffset.y + adjustedContentInset.top - Self.margin
        guard let index = layout.table.lines.firstIndex(where: { $0.frame.maxY > top }) else { return layout.table.lines.last.map { $0.range.location + $0.range.length } }
        return layout.table.lines[index].range.location
    }

    /// The last rendered offset whose line starts above the bottom of the viewport.
    var lastVisibleOffset: Int? {
        guard let layout else { return nil }
        let bottom = contentOffset.y + bounds.height - adjustedContentInset.bottom - Self.margin
        guard let line = layout.table.lines.last(where: { $0.frame.minY < bottom }) else { return nil }
        return line.range.location + line.range.length
    }

    var isAtEnd: Bool { contentOffset.y + bounds.height >= contentSize.height - 1 }
    var isAtStart: Bool { contentOffset.y <= 0.5 }

    /// Moves one visible height; false at the chapter's ends.
    @discardableResult
    func page(forward: Bool, animated: Bool) -> Bool {
        let height = bounds.height - adjustedContentInset.top - adjustedContentInset.bottom
        if forward {
            guard !isAtEnd else { return false }
            setContentOffset(CGPoint(x: 0, y: min(contentOffset.y + height, contentSize.height - bounds.height)), animated: animated)
        } else {
            guard !isAtStart else { return false }
            setContentOffset(CGPoint(x: 0, y: max(0, contentOffset.y - height)), animated: animated)
        }
        return true
    }

    func characterIndex(at point: CGPoint) -> Int? {
        layout?.characterIndex(atSurfacePoint: CGPoint(x: point.x - Self.margin, y: point.y - Self.margin))
    }

    /// Rectangles of a rendered range in the scroll view's content coordinates.
    func rectangles(for range: NSRange) -> [CGRect] {
        layout?.surfaceRectangles(for: range).map { $0.offsetBy(dx: Self.margin, dy: Self.margin) } ?? []
    }

    // MARK: Accessibility (Spec 11.4, 14.1): the visible blocks plus one screen of lookahead

    override var accessibilityElements: [Any]? {
        get {
            guard let chapter, layout != nil else { return nil }
            if abs(contentOffset.y - elementsOrigin) > Self.elementRefreshDistance || elements.isEmpty {
                elementsOrigin = contentOffset.y
                let bottom = contentOffset.y + 2 * bounds.height - Self.margin
                guard let first = firstVisibleOffset, let lastLine = layout?.table.lines.last(where: { $0.frame.minY < bottom }) else { return nil }
                let window = NSRange(location: first, length: max(0, lastLine.range.location + lastLine.range.length - first))
                // Blocks keep their element objects across rebuilds, so VoiceOver's current
                // element stays in the list and its place is not lost when the window moves.
                let existing = Dictionary(elements.map { ($0.blockIndex, $0) }, uniquingKeysWith: { first, _ in first })
                var built: [EPUBSurfaceBlockElement] = []
                for (index, block) in chapter.blocks.enumerated() {
                    guard NSIntersectionRange(block.range, window).length > 0, !chapter.text(in: block.range).allSatisfy(\.isWhitespace) else { continue }
                    built.append(existing[index] ?? EPUBSurfaceBlockElement(container: self, blockIndex: index, visibleRange: block.range))
                }
                for (position, element) in built.enumerated() {
                    element.previousElement = position > 0 ? built[position - 1] : nil
                    element.nextElement = position + 1 < built.count ? built[position + 1] : nil
                }
                elements = built
            }
            return elements
        }
        set { super.accessibilityElements = newValue }
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let forward: Bool
        switch direction {
        case .next, .down, .left: forward = true
        case .previous, .up, .right: forward = false
        @unknown default: return super.accessibilityScroll(direction)
        }
        EPUBAccessibilityLog.shared.record("continuous accessibilityScroll forward=\(forward) spine=\(spineIndex) offset=\(contentOffset.y)")
        if page(forward: forward, animated: false) {
            elementsOrigin = -1
            settled?()
            UIAccessibility.post(notification: .pageScrolled, argument: nil)
            EPUBAccessibilityLog.shared.recordFocusLater(context: "continuous scroll")
            return true
        }
        crossingRequested?(forward ? 1 : -1)
        return true
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let overscrollBottom = contentOffset.y + bounds.height - contentSize.height
        if overscrollBottom > Self.crossingOverscroll { crossingRequested?(1) }
        else if contentOffset.y < -Self.crossingOverscroll - adjustedContentInset.top { crossingRequested?(-1) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settled?() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { settled?() } }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settled?() }
}

/// The content view of the continuous surface: draws the lines in the dirty rect.
@MainActor
final class EPUBSurfaceView: UIView {
    var layout: EPUBLayoutSession? { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .systemBackground
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let layout else { return }
        let margin = EPUBContinuousView.margin
        layout.drawLines(intersecting: rect.offsetBy(dx: -margin, dy: -margin), in: context, origin: CGPoint(x: margin, y: margin))
    }
}

/// One block of the continuous surface; its frame follows the scroll position on every read.
@MainActor
final class EPUBSurfaceBlockElement: UIAccessibilityElement {
    private weak var surface: EPUBContinuousView?
    let blockIndex: Int
    let visibleRange: NSRange
    weak var previousElement: EPUBSurfaceBlockElement?
    weak var nextElement: EPUBSurfaceBlockElement?

    init(container: EPUBContinuousView, blockIndex: Int, visibleRange: NSRange) {
        surface = container
        self.blockIndex = blockIndex
        self.visibleRange = visibleRange
        super.init(accessibilityContainer: container)
        accessibilityIdentifier = "reader.epub.surface.block.\(blockIndex)"
        accessibilityTextualContext = .narrative
        guard let chapter = container.chapter, let layout = container.layout, chapter.blocks.indices.contains(blockIndex) else { return }
        let block = chapter.blocks[blockIndex]
        let source = layout.string.attributedSubstring(from: visibleRange)
        let label = NSMutableAttributedString(string: source.string)
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, subrange, _ in
            if let level = attributes[.epubHeadingLevel] as? NSNumber { label.addAttribute(.accessibilityTextHeadingLevel, value: level, range: subrange) }
            if let language = attributes[.languageIdentifier] as? String { label.addAttribute(.accessibilitySpeechLanguage, value: language, range: subrange) }
        }
        accessibilityAttributedLabel = label
        var traits: UIAccessibilityTraits = .staticText
        if case .heading = block.kind { traits.insert(.header) }
        if block.kind == .image {
            traits.insert(.image)
            // An image never has an empty label: its alternative, or "Image" (STD section 7.4).
            accessibilityAttributedLabel = nil
            accessibilityLabel = block.alternativeText.flatMap { $0.isEmpty ? nil : $0 } ?? "Image"
        }
        if let link = block.links.first, link.range == block.range { traits.insert(.link) }
        accessibilityTraits = traits
        var actions: [UIAccessibilityCustomAction] = []
        for link in block.links where NSIntersectionRange(link.range, visibleRange).length > 0 {
            let text = chapter.text(in: link.range)
            let isNote = block.noteReferences.contains { $0.linkIndex == link.linkIndex }
            actions.append(UIAccessibilityCustomAction(name: isNote ? "Show note" : "Open link: \(text)") { [weak container] _ in
                guard let container, let delegate = container.pageDelegate else { return false }
                return delegate.surface(container, activateLinkAt: link.range.location)
            })
        }
        accessibilityCustomActions = actions.isEmpty ? nil : actions
    }

    override var accessibilityFrameInContainerSpace: CGRect {
        get {
            guard let surface else { return .zero }
            let union = surface.rectangles(for: visibleRange).reduce(CGRect.null) { $0.union($1) }
            return union.isNull ? .zero : union.offsetBy(dx: -surface.contentOffset.x, dy: -surface.contentOffset.y)
        }
        set { super.accessibilityFrameInContainerSpace = newValue }
    }

    override var accessibilityFrame: CGRect {
        get {
            guard let surface else { return .zero }
            return UIAccessibility.convertToScreenCoordinates(accessibilityFrameInContainerSpace, in: surface)
        }
        set { super.accessibilityFrame = newValue }
    }

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        guard let surface else { return }
        let frame = accessibilityFrameInContainerSpace
        let visible = CGRect(origin: .zero, size: surface.bounds.size).insetBy(dx: 0, dy: surface.adjustedContentInset.top)
        guard !visible.contains(frame) else { return }
        surface.scrollRectToVisible(frame.offsetBy(dx: surface.contentOffset.x, dy: surface.contentOffset.y), animated: false)
    }

    @available(iOS 18.0, *)
    override var accessibilityNextTextNavigationElement: Any? {
        get { nextElement }
        set {}
    }

    @available(iOS 18.0, *)
    override var accessibilityPreviousTextNavigationElement: Any? {
        get { previousElement }
        set {}
    }
}
