import UIKit

/// Draws one page of a chapter layout (Spec 11.3). The accessibility surface
/// of section 14 is layered on in its own step; this view only paints and
/// answers geometry questions in its own coordinates.
@MainActor
final class EPUBPageView: UIView {
    /// The text block sits this far inside the view on every side.
    static let margin: CGFloat = 20

    private(set) var layout: EPUBLayoutSession?
    private(set) var pageIndex = 0
    private(set) var spineIndex = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .systemBackground
        contentMode = .redraw
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ layout: EPUBLayoutSession?, page: Int, spineIndex: Int) {
        self.layout = layout
        pageIndex = page
        self.spineIndex = spineIndex
        setNeedsDisplay()
    }

    var contentOrigin: CGPoint { CGPoint(x: Self.margin, y: Self.margin) }

    /// The page's rendered range, or nil when nothing is shown.
    var pageRange: NSRange? {
        guard let layout, layout.table.pages.indices.contains(pageIndex) else { return nil }
        return layout.table.pages[pageIndex].range
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let layout else { return }
        layout.draw(page: pageIndex, in: context, origin: contentOrigin)
    }

    /// The character under a point in the view, or nil on the margins and gutters.
    func characterIndex(at point: CGPoint) -> Int? {
        guard let layout else { return nil }
        return layout.characterIndex(at: CGPoint(x: point.x - contentOrigin.x, y: point.y - contentOrigin.y), onPage: pageIndex)
    }

    /// Rectangles of a rendered range in the view's coordinates.
    func rectangles(for range: NSRange) -> [CGRect] {
        guard let layout else { return [] }
        return layout.rectangles(for: range, onPage: pageIndex).map { $0.offsetBy(dx: contentOrigin.x, dy: contentOrigin.y) }
    }

    /// Line frames of the page in the view's coordinates, in reading order.
    func lineFrames() -> [(line: Int, frame: CGRect)] {
        guard let layout else { return [] }
        return layout.table.lineFrames(onPage: pageIndex).map { ($0.line, $0.frame.offsetBy(dx: contentOrigin.x, dy: contentOrigin.y)) }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsDisplay()
    }
}
