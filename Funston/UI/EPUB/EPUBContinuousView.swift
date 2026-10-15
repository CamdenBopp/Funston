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

    func show(_ layout: EPUBLayoutSession?, spineIndex: Int, atOffset offset: Int?) {
        self.layout = layout
        self.spineIndex = spineIndex
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
