import UIKit

/// The page a paragraph element belongs to: its layout and text, geometry in
/// `coordinateView`'s coordinates, selection, and what VoiceOver gestures do.
@MainActor
protocol EPUBTextPage: AnyObject {
    var layout: EPUBLayoutSession? { get }
    var chapter: EPUBChapterText? { get }
    var pageIndex: Int { get }
    var spineIndex: Int { get }
    var coordinateView: UIView { get }
    var selection: NSRange? { get set }
    func rectangles(for range: NSRange) -> [CGRect]
    func characterIndex(at point: CGPoint) -> Int?
    func lineFrames() -> [(line: Int, frame: CGRect)]
    func attributedText(for range: NSRange) -> NSAttributedString
    func activateLink(at offset: Int) -> Bool
    func scroll(_ direction: UIAccessibilityScrollDirection) -> Bool
    /// VoiceOver moved onto one of this page's paragraphs.
    func paragraphDidBecomeFocused(_ paragraph: UIView)
}

/// One block's lines on one page as a text element, the per-paragraph model of
/// WWDC26 session 219 ("Enhance the accessibility of your reading app"): a
/// transparent view over the block's lines that adopts UITextInput over the
/// block's rendered range, linked to its neighbours with the text navigation
/// links. The page's last block carries causesPageTurn; the page view turns the
/// page in accessibilityScroll. The page view draws the text.
@MainActor
final class EPUBParagraphView: UIView, UITextInput {
    weak var page: (any EPUBTextPage)?
    let blockIndex: Int
    /// The block's rendered range on this page.
    let range: NSRange
    weak var previousParagraph: EPUBParagraphView?
    weak var nextParagraph: EPUBParagraphView?
    /// True for the page's last block: VoiceOver turns the page after reading it.
    var turnsPage = false { didSet { refreshTraits() } }
    private let baseTraits: UIAccessibilityTraits
    private lazy var textInteraction = UITextInteraction(for: .nonEditable)

    init(page: any EPUBTextPage, blockIndex: Int, range: NSRange, block: EPUBBlock) {
        self.page = page
        self.blockIndex = blockIndex
        self.range = range
        var traits: UIAccessibilityTraits = .staticText
        if case .heading = block.kind { traits.insert(.header) }
        if let link = block.links.first, link.range == block.range { traits.insert(.link) }
        baseTraits = traits
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = true
        accessibilityIdentifier = "reader.epub.paragraph.\(blockIndex)"
        accessibilityTextualContext = .narrative
        accessibilityAttributedValue = page.attributedText(for: range)
        refreshTraits()
        var actions: [UIAccessibilityCustomAction] = []
        for link in block.links where NSIntersectionRange(link.range, range).length > 0 {
            let text = page.chapter?.text(in: link.range) ?? ""
            let isNote = block.noteReferences.contains { $0.linkIndex == link.linkIndex }
            actions.append(UIAccessibilityCustomAction(name: isNote ? "Show note \(text)" : "Open link: \(text)") { [weak page] _ in
                page?.activateLink(at: link.range.location) ?? false
            })
        }
        accessibilityCustomActions = actions.isEmpty ? nil : actions
        textInteraction.textInput = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refreshTraits() {
        accessibilityTraits = turnsPage ? baseTraits.union(.causesPageTurn) : baseTraits
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        page?.scroll(direction) ?? false
    }

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        page?.paragraphDidBecomeFocused(self)
    }

    /// Whether the selection handles and menus are attached (only near the shown page).
    var isInteractive: Bool {
        get { textInteraction.view === self }
        set {
            if newValue, textInteraction.view !== self { addInteraction(textInteraction) }
            if !newValue, textInteraction.view === self { removeInteraction(textInteraction) }
        }
    }

    override var accessibilityNextTextNavigationElement: Any? {
        get { nextParagraph }
        set {}
    }

    override var accessibilityPreviousTextNavigationElement: Any? {
        get { previousParagraph }
        set {}
    }

    // MARK: Geometry, in this view's coordinates

    private func rectangles(for range: NSRange) -> [CGRect] {
        guard let page else { return [] }
        return page.rectangles(for: NSIntersectionRange(range, self.range)).map { page.coordinateView.convert($0, to: self) }
    }

    /// The page's lines that hold this block's text, clipped to the block, in reading order.
    private var lines: [(range: NSRange, frame: CGRect)] {
        guard let page, let layout = page.layout else { return [] }
        return page.lineFrames().compactMap { line, frame in
            let clipped = NSIntersectionRange(layout.table.lines[line].range, range)
            return clipped.length > 0 ? (clipped, page.coordinateView.convert(frame, to: self)) : nil
        }
    }

    /// The block's line containing an offset, for the tokenizer.
    func lineRange(containing offset: Int) -> NSRange? {
        lines.first { NSLocationInRange(offset, $0.range) || offset == $0.range.location + $0.range.length }?.range
    }

    // MARK: UITextInput over the block's rendered range

    func text(in range: UITextRange) -> String? {
        guard let range = range as? EPUBTextRange, let chapter = page?.chapter else { return nil }
        return chapter.text(in: NSIntersectionRange(range.range, self.range))
    }

    func replace(_ range: UITextRange, withText text: String) {}

    var selectedTextRange: UITextRange? {
        get { page?.selection.flatMap { NSIntersectionRange($0, range).length > 0 ? EPUBTextRange(NSIntersectionRange($0, range)) : nil } }
        set {
            inputDelegate?.selectionWillChange(self)
            page?.selection = (newValue as? EPUBTextRange).map { NSIntersectionRange($0.range, range) }
            inputDelegate?.selectionDidChange(self)
        }
    }

    var markedTextRange: UITextRange? { nil }
    var markedTextStyle: [NSAttributedString.Key: Any]? { get { nil } set {} }
    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {}
    func unmarkText() {}

    var beginningOfDocument: UITextPosition { EPUBTextPosition(range.location) }
    var endOfDocument: UITextPosition { EPUBTextPosition(range.location + range.length) }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? EPUBTextPosition, let to = toPosition as? EPUBTextPosition else { return nil }
        return EPUBTextRange(NSRange(location: min(from.offset, to.offset), length: abs(to.offset - from.offset)))
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? EPUBTextPosition else { return nil }
        let target = position.offset + offset
        guard target >= range.location, target <= range.location + range.length else { return nil }
        return EPUBTextPosition(target)
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        switch direction {
        case .right: return self.position(from: position, offset: offset)
        case .left: return self.position(from: position, offset: -offset)
        case .down, .up:
            guard let position = position as? EPUBTextPosition else { return nil }
            let lines = lines
            guard let index = lines.firstIndex(where: { NSLocationInRange(position.offset, $0.range) || position.offset == $0.range.location + $0.range.length }) else { return nil }
            let target = index + (direction == .down ? offset : -offset)
            guard lines.indices.contains(target) else { return nil }
            return EPUBTextPosition(lines[target].range.location)
        @unknown default: return nil
        }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let a = position as? EPUBTextPosition, let b = other as? EPUBTextPosition else { return .orderedSame }
        return a.offset < b.offset ? .orderedAscending : a.offset > b.offset ? .orderedDescending : .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let a = from as? EPUBTextPosition, let b = toPosition as? EPUBTextPosition else { return 0 }
        return b.offset - a.offset
    }

    weak var inputDelegate: (any UITextInputDelegate)?

    var tokenizer: any UITextInputTokenizer { EPUBLineTokenizer(textInput: self) }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard let range = range as? EPUBTextRange else { return nil }
        switch direction {
        case .left, .up: return EPUBTextPosition(range.range.location)
        case .right, .down: return EPUBTextPosition(range.range.location + range.range.length)
        @unknown default: return nil
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let position = position as? EPUBTextPosition else { return nil }
        switch direction {
        case .left, .up: return EPUBTextRange(NSRange(location: range.location, length: position.offset - range.location))
        case .right, .down: return EPUBTextRange(NSRange(location: position.offset, length: range.location + range.length - position.offset))
        @unknown default: return nil
        }
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        guard let position = position as? EPUBTextPosition, let layout = page?.layout, position.offset < layout.string.length,
              let style = layout.string.attribute(.paragraphStyle, at: position.offset, effectiveRange: nil) as? NSParagraphStyle else { return .natural }
        return style.baseWritingDirection
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    func firstRect(for range: UITextRange) -> CGRect {
        guard let range = range as? EPUBTextRange else { return .null }
        return rectangles(for: range.range).first ?? .null
    }

    func caretRect(for position: UITextPosition) -> CGRect {
        guard let position = position as? EPUBTextPosition, let first = rectangles(for: NSRange(location: position.offset, length: 1)).first else { return .null }
        return CGRect(x: first.minX, y: first.minY, width: EPUBPageView.caretWidth, height: first.height)
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard let range = range as? EPUBTextRange else { return [] }
        let rects = rectangles(for: range.range)
        return rects.enumerated().map { index, rect in EPUBSelectionRect(rect: rect, isFirst: index == 0, isLast: index == rects.count - 1) }
    }

    func closestPosition(to point: CGPoint) -> UITextPosition? {
        guard let page else { return nil }
        if let index = page.characterIndex(at: convert(point, to: page.coordinateView)), NSLocationInRange(index, range) || index == range.location + range.length {
            return EPUBTextPosition(index)
        }
        guard let nearest = lines.min(by: { abs($0.frame.midY - point.y) < abs($1.frame.midY - point.y) }) else { return nil }
        return EPUBTextPosition(point.x < nearest.frame.midX ? nearest.range.location : nearest.range.location + nearest.range.length)
    }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        guard let range = range as? EPUBTextRange, let position = closestPosition(to: point) as? EPUBTextPosition else { return nil }
        return EPUBTextPosition(min(max(position.offset, range.range.location), range.range.location + range.range.length))
    }

    func characterRange(at point: CGPoint) -> UITextRange? {
        guard let page, let index = page.characterIndex(at: convert(point, to: page.coordinateView)), NSLocationInRange(index, range) else { return nil }
        return EPUBTextRange(NSRange(location: index, length: 1))
    }

    var hasText: Bool { range.length > 0 }
    func insertText(_ text: String) {}
    func deleteBackward() {}
}

/// An image block under the per-paragraph model: one image element over the
/// picture, labelled with its alternative, or "Image".
@MainActor
final class EPUBFigureView: UIView {
    let blockIndex: Int
    let range: NSRange
    var turnsPage = false { didSet { accessibilityTraits = turnsPage ? [.image, .causesPageTurn] : .image } }
    weak var page: (any EPUBTextPage)?

    init(page: any EPUBTextPage, blockIndex: Int, range: NSRange, block: EPUBBlock) {
        self.page = page
        self.blockIndex = blockIndex
        self.range = range
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "reader.epub.figure.\(blockIndex)"
        accessibilityTraits = .image
        accessibilityLabel = block.alternativeText.flatMap { $0.isEmpty ? nil : $0 } ?? "Image"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        page?.scroll(direction) ?? false
    }

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        page?.paragraphDidBecomeFocused(self)
    }
}
