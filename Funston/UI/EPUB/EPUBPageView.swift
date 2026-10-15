import UIKit

/// Which accessibility element model the page view exposes (Spec 14.1, D4).
enum EPUBAccessibilityModel: String, Sendable {
    /// The page is one element: reading content line by line, UITextInput, rotors.
    case page
    /// One element per block with text navigation links; the trait on the last block.
    case blocks

    @MainActor static var preferred: EPUBAccessibilityModel {
        EPUBAccessibilityModel(rawValue: UserDefaults.standard.string(forKey: EPUBAccessibilityLog.modelKey) ?? "") ?? .page
    }
}

/// What a page view asks its owner to do under VoiceOver.
@MainActor
protocol EPUBPageViewDelegate: AnyObject {
    /// A VoiceOver scroll: true when a page was turned. The view posts pageScrolled itself.
    func pageView(_ view: EPUBPageView, turnPage forward: Bool) -> Bool
    /// "Page p of q" for the chapter, after a turn.
    func pageViewPageDescription(_ view: EPUBPageView) -> String
    func pageView(_ view: EPUBPageView, activateLinkAt offset: Int) -> Bool
    /// The link under an offset, for custom actions: its text, target and whether it is a note.
    func pageView(_ view: EPUBPageView, linkAt offset: Int) -> (label: String, isNote: Bool)?
    /// A link activated from a block of the continuous surface.
    func surface(_ view: EPUBContinuousView, activateLinkAt offset: Int) -> Bool
}

/// Draws one page of a chapter layout (Spec 11.3) and is its accessibility
/// surface (Spec 14): under the page model the view is one element that
/// implements UIAccessibilityReadingContent over the line table and
/// UITextInput over rendered offsets; under the block model it exposes one
/// element per block.
@MainActor
final class EPUBPageView: UIView {
    /// The text block sits this far inside the view on every side.
    static let margin: CGFloat = 20

    private(set) var layout: EPUBLayoutSession?
    private(set) var pageIndex = 0
    private(set) var spineIndex = 0
    private(set) var chapter: EPUBChapterText?
    weak var delegate: EPUBPageViewDelegate?
    var accessibilityModel: EPUBAccessibilityModel = .preferred { didSet { if oldValue != accessibilityModel { blockElements = nil; refreshAccessibility() } } }
    var chapterTitle: String?
    var isRightToLeft = false
    private var blockElements: [EPUBBlockElement]?
    /// The reading-content and text-input element under the page model (UIKit treats
    /// any UITextInput view as one text element, so it cannot be the page view itself).
    let textSurface = EPUBPageTextSurface()
    var selection: NSRange? { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .systemBackground
        contentMode = .redraw
        textSurface.page = self
        textSurface.frame = bounds
        textSurface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(textSurface)
        refreshAccessibility()
    }

    /// The element VoiceOver should land on for this page.
    var focusElement: Any { accessibilityModel == .blocks ? (accessibilityElements?.first ?? self) : textSurface }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ layout: EPUBLayoutSession?, page: Int, spineIndex: Int, chapter: EPUBChapterText?, title: String?) {
        self.layout = layout
        pageIndex = page
        self.spineIndex = spineIndex
        self.chapter = chapter
        chapterTitle = title
        blockElements = nil
        selection = nil
        setNeedsDisplay()
        refreshAccessibility()
    }

    var contentOrigin: CGPoint { CGPoint(x: Self.margin, y: Self.margin) }

    /// The page's rendered range, or nil when nothing is shown.
    var pageRange: NSRange? {
        guard let layout, layout.table.pages.indices.contains(pageIndex) else { return nil }
        return layout.table.pages[pageIndex].range
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let layout else { return }
        if let selection, selection.length > 0 {
            UIColor.tintColor.withAlphaComponent(Self.selectionAlpha).setFill()
            for rectangle in rectangles(for: selection) { context.fill(rectangle) }
        }
        layout.draw(page: pageIndex, in: context, origin: contentOrigin)
    }
    static let selectionAlpha: CGFloat = 0.25

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

    // MARK: - Accessibility: the element model

    private func refreshAccessibility() {
        EPUBAccessibilityLog.shared.record("page view model=\(accessibilityModel.rawValue) page=\(pageIndex) chapterLoaded=\(chapter != nil)")
        isAccessibilityElement = false
        accessibilityContainerType = .semanticGroup
        accessibilityLabel = chapterTitle
        switch accessibilityModel {
        case .page:
            textSurface.isHidden = false
            textSurface.refresh(title: chapterTitle)
            accessibilityElements = [textSurface]
        case .blocks:
            textSurface.isHidden = true
            accessibilityElements = makeBlockElements()
        }
    }

    override var accessibilityElements: [Any]? {
        get { accessibilityModel == .blocks ? (blockElements ?? makeBlockElements()) : [textSurface] }
        set { super.accessibilityElements = newValue }
    }

    /// The blocks with lines on this page, one element each; empty blocks never appear.
    private func makeBlockElements() -> [EPUBBlockElement] {
        guard let layout, let chapter, let pageRange else { blockElements = []; return [] }
        var elements: [EPUBBlockElement] = []
        for (index, block) in chapter.blocks.enumerated() {
            let visible = NSIntersectionRange(block.range, pageRange)
            guard visible.length > 0, !chapter.text(in: visible).allSatisfy(\.isWhitespace) else { continue }
            elements.append(EPUBBlockElement(container: self, blockIndex: index, visibleRange: visible))
        }
        for (position, element) in elements.enumerated() {
            element.previousElement = position > 0 ? elements[position - 1] : nil
            element.nextElement = position + 1 < elements.count ? elements[position + 1] : nil
            element.isLastOnPage = position == elements.count - 1
        }
        _ = layout
        blockElements = elements
        EPUBAccessibilityLog.shared.record("block elements built: \(elements.count) for page \(pageIndex)")
        return elements
    }

    /// The attributed label of a block's visible part: heading level and speech
    /// languages, with attachment characters replaced by their alternatives.
    func attributedText(for range: NSRange) -> NSAttributedString {
        guard let layout else { return NSAttributedString() }
        let source = layout.string.attributedSubstring(from: range)
        let result = NSMutableAttributedString(string: source.string)
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, subrange, _ in
            if let level = attributes[.epubHeadingLevel] as? NSNumber { result.addAttribute(.accessibilityTextHeadingLevel, value: level, range: subrange) }
            if let language = attributes[.languageIdentifier] as? String { result.addAttribute(.accessibilitySpeechLanguage, value: language, range: subrange) }
        }
        var replacements: [(NSRange, String)] = []
        source.enumerateAttribute(.attachment, in: NSRange(location: 0, length: source.length)) { value, subrange, _ in
            guard value != nil else { return }
            let alternative = (source.attribute(.epubAlternativeText, at: subrange.location, effectiveRange: nil) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Image"
            replacements.append((subrange, alternative))
        }
        for (subrange, alternative) in replacements.reversed() { result.replaceCharacters(in: subrange, with: alternative) }
        return result
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let forward: Bool
        switch direction {
        case .next, .down: forward = true
        case .previous, .up: forward = false
        case .left: forward = !isRightToLeft
        case .right: forward = isRightToLeft
        @unknown default: return super.accessibilityScroll(direction)
        }
        EPUBAccessibilityLog.shared.record("accessibilityScroll direction=\(direction.rawValue) forward=\(forward) page=\(pageIndex) spine=\(spineIndex)")
        guard let delegate, delegate.pageView(self, turnPage: forward) else {
            EPUBAccessibilityLog.shared.record("accessibilityScroll refused at the book's end")
            return false
        }
        let description = delegate.pageViewPageDescription(self)
        EPUBAccessibilityLog.shared.record("post pageScrolled \"\(description)\"")
        UIAccessibility.post(notification: .pageScrolled, argument: description)
        EPUBAccessibilityLog.shared.recordFocusLater(context: "scroll")
        return true
    }

    /// The line containing an offset, for the tokenizer.
    func lineRange(containing offset: Int) -> NSRange? {
        guard let layout else { return nil }
        for (line, _) in lineFrames() {
            let range = layout.table.lines[line].range
            if NSLocationInRange(offset, range) || offset == range.location + range.length { return range }
        }
        return nil
    }
}


/// The page element under the page model: one accessibility element that
/// reads line by line through UIAccessibilityReadingContent and adopts
/// UITextInput over rendered offsets. It draws nothing; the page view does.
@MainActor
final class EPUBPageTextSurface: UIView, UIAccessibilityReadingContent, UITextInput {
    weak var page: EPUBPageView?
    private lazy var textInteraction = UITextInteraction(for: .nonEditable)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = true
        accessibilityTraits = [.staticText, .causesPageTurn]
        accessibilityTextualContext = .narrative
        accessibilityIdentifier = "reader.epub.page"
        addInteraction(textInteraction)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh(title: String?) {
        accessibilityLabel = title
        isAccessibilityElement = true
        accessibilityTraits = [.staticText, .causesPageTurn]
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        page?.accessibilityScroll(direction) ?? false
    }

    // MARK: - Accessibility: reading content (Spec 14.2)

    private var lineRecords: [(line: Int, frame: CGRect)] { page?.lineFrames() ?? [] }

    func accessibilityLineNumber(for point: CGPoint) -> Int {
        // Reading content points arrive in screen coordinates.
        let local = convert(point, from: window?.screen.coordinateSpace ?? UIScreen.main.coordinateSpace)
        let lines = lineRecords
        EPUBAccessibilityLog.shared.record("readingContent lineNumber(for:) point=\(point)")
        guard let index = lines.firstIndex(where: { $0.frame.minY <= local.y && local.y <= $0.frame.maxY && $0.frame.minX - 1 <= local.x && local.x <= $0.frame.maxX + 1 }) else { return NSNotFound }
        return index
    }

    func accessibilityContent(forLineNumber line: Int) -> String? {
        accessibilityAttributedContent(forLineNumber: line)?.string
    }

    func accessibilityAttributedContent(forLineNumber line: Int) -> NSAttributedString? {
        guard let layout = page?.layout else { return nil }
        let lines = lineRecords
        guard lines.indices.contains(line) else { return nil }
        EPUBAccessibilityLog.shared.record("readingContent content(forLineNumber: \(line))")
        return page?.attributedText(for: layout.table.lines[lines[line].line].range)
    }

    func accessibilityFrame(forLineNumber line: Int) -> CGRect {
        let lines = lineRecords
        guard lines.indices.contains(line) else { return .zero }
        return UIAccessibility.convertToScreenCoordinates(lines[line].frame, in: self)
    }

    func accessibilityPageContent() -> String? {
        accessibilityAttributedPageContent()?.string
    }

    func accessibilityAttributedPageContent() -> NSAttributedString? {
        guard let pageRange = page?.pageRange else { return nil }
        EPUBAccessibilityLog.shared.record("readingContent pageContent page=\((page?.pageIndex ?? 0))")
        return page?.attributedText(for: pageRange)
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            guard let pageRange = page?.pageRange, let chapter = page?.chapter else { return nil }
            var actions: [UIAccessibilityCustomAction] = []
            for block in chapter.blocks where NSIntersectionRange(block.range, pageRange).length > 0 {
                for link in block.links where NSIntersectionRange(link.range, pageRange).length > 0 {
                    let text = chapter.text(in: link.range)
                    let isNote = block.noteReferences.contains { $0.linkIndex == link.linkIndex }
                    actions.append(UIAccessibilityCustomAction(name: isNote ? "Show note \(text)" : "Open link: \(text)") { [weak self] _ in
                        guard let self, let page else { return false }
                        return page.delegate?.pageView(page, activateLinkAt: link.range.location) ?? false
                    })
                }
            }
            return actions.isEmpty ? nil : actions
        }
        set { super.accessibilityCustomActions = newValue }
    }

    // MARK: - Accessibility: rotors (Spec 14.2)

    override var accessibilityCustomRotors: [UIAccessibilityCustomRotor]? {
        get {
            guard let chapter = page?.chapter, let pageRange = page?.pageRange else { return nil }
            var rotors: [UIAccessibilityCustomRotor] = []
            let headings = chapter.blocks.filter { if case .heading = $0.kind { return NSIntersectionRange($0.range, pageRange).length > 0 } else { return false } }
            if !headings.isEmpty { rotors.append(rotor(named: "Headings", ranges: headings.map(\.range))) }
            let levels = Set(headings.compactMap { if case .heading(let level) = $0.kind { return level } else { return nil } })
            if levels.count > 1 {
                for level in levels.sorted() {
                    rotors.append(rotor(named: "Heading level \(level)", ranges: headings.filter { if case .heading(let l) = $0.kind { return l == level } else { return false } }.map(\.range)))
                }
            }
            let links = chapter.blocks.flatMap(\.links).map(\.range).filter { NSIntersectionRange($0, pageRange).length > 0 }
            if !links.isEmpty { rotors.append(rotor(named: "Links", ranges: links)) }
            let images = chapter.images.map { NSRange(location: $0.renderedOffset, length: 1) }.filter { NSLocationInRange($0.location, pageRange) }
            if !images.isEmpty { rotors.append(rotor(named: "Images", ranges: images)) }
            let paragraphs = chapter.blocks.map(\.range).filter { NSIntersectionRange($0, pageRange).length > 0 }
            if !paragraphs.isEmpty { rotors.append(rotor(named: "Paragraphs", ranges: paragraphs)) }
            return rotors
        }
        set { super.accessibilityCustomRotors = newValue }
    }

    private func rotor(named name: String, ranges: [NSRange]) -> UIAccessibilityCustomRotor {
        UIAccessibilityCustomRotor(name: name) { [weak self] predicate in
            guard let self, let pageRange = page?.pageRange else { return nil }
            let clipped = ranges.map { NSIntersectionRange($0, pageRange) }.filter { $0.length > 0 }
            let current = (predicate.currentItem.targetRange as? EPUBTextRange)?.range.location
            let forward = predicate.searchDirection == .next
            let candidate: NSRange?
            if let current {
                candidate = forward ? clipped.first { $0.location > current } : clipped.last { $0.location < current }
            } else {
                candidate = forward ? clipped.first : clipped.last
            }
            guard let found = candidate else { return nil }
            return UIAccessibilityCustomRotorItemResult(targetElement: self, targetRange: EPUBTextRange(found))
        }
    }

    // MARK: - UITextInput over rendered offsets (APL-30)

    private var documentRange: NSRange { page?.pageRange ?? NSRange(location: 0, length: 0) }

    func text(in range: UITextRange) -> String? {
        guard let range = range as? EPUBTextRange, let chapter = page?.chapter else { return nil }
        return chapter.text(in: NSIntersectionRange(range.range, NSRange(location: 0, length: chapter.length)))
    }

    func replace(_ range: UITextRange, withText text: String) {}

    var selectedTextRange: UITextRange? {
        get { page?.selection.map(EPUBTextRange.init) }
        set { page?.selection = (newValue as? EPUBTextRange)?.range }
    }

    var markedTextRange: UITextRange? { nil }
    var markedTextStyle: [NSAttributedString.Key: Any]? { get { nil } set {} }
    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {}
    func unmarkText() {}

    var beginningOfDocument: UITextPosition { EPUBTextPosition(documentRange.location) }
    var endOfDocument: UITextPosition { EPUBTextPosition(documentRange.location + documentRange.length) }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? EPUBTextPosition, let to = toPosition as? EPUBTextPosition else { return nil }
        return EPUBTextRange(NSRange(location: min(from.offset, to.offset), length: abs(to.offset - from.offset)))
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? EPUBTextPosition else { return nil }
        let target = position.offset + offset
        let range = documentRange
        guard target >= range.location, target <= range.location + range.length else { return nil }
        return EPUBTextPosition(target)
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        switch direction {
        case .right: return self.position(from: position, offset: offset)
        case .left: return self.position(from: position, offset: -offset)
        case .down, .up:
            guard let position = position as? EPUBTextPosition, let layout = page?.layout else { return nil }
            let lines = page?.lineFrames() ?? []
            guard let index = lines.firstIndex(where: { NSLocationInRange(position.offset, layout.table.lines[$0.line].range) || position.offset == layout.table.lines[$0.line].range.location + layout.table.lines[$0.line].range.length }) else { return nil }
            let target = index + (direction == .down ? offset : -offset)
            guard lines.indices.contains(target) else { return nil }
            return EPUBTextPosition(layout.table.lines[lines[target].line].range.location)
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
        case .left, .up: return EPUBTextRange(NSRange(location: documentRange.location, length: position.offset - documentRange.location))
        case .right, .down: return EPUBTextRange(NSRange(location: position.offset, length: documentRange.location + documentRange.length - position.offset))
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
        return page?.rectangles(for: range.range).first ?? .null
    }

    func caretRect(for position: UITextPosition) -> CGRect {
        guard let position = position as? EPUBTextPosition else { return .null }
        let rects = page?.rectangles(for: NSRange(location: position.offset, length: 1)) ?? []
        guard let first = rects.first else { return .null }
        return CGRect(x: first.minX, y: first.minY, width: 2, height: first.height)
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard let range = range as? EPUBTextRange else { return [] }
        let rects = page?.rectangles(for: range.range) ?? []
        return rects.enumerated().map { index, rect in EPUBSelectionRect(rect: rect, isFirst: index == 0, isLast: index == rects.count - 1) }
    }

    func closestPosition(to point: CGPoint) -> UITextPosition? {
        if let index = page?.characterIndex(at: point) { return EPUBTextPosition(index) }
        guard let layout = page?.layout else { return nil }
        let lines = page?.lineFrames() ?? []
        guard let nearest = lines.min(by: { abs($0.frame.midY - point.y) < abs($1.frame.midY - point.y) }) else { return nil }
        let record = layout.table.lines[nearest.line]
        return EPUBTextPosition(point.x < nearest.frame.midX ? record.range.location : record.range.location + record.range.length)
    }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        guard let range = range as? EPUBTextRange, let position = closestPosition(to: point) as? EPUBTextPosition else { return nil }
        return EPUBTextPosition(min(max(position.offset, range.range.location), range.range.location + range.range.length))
    }

    func characterRange(at point: CGPoint) -> UITextRange? {
        guard let index = page?.characterIndex(at: point), let pageRange = page?.pageRange, index < pageRange.location + pageRange.length else { return nil }
        return EPUBTextRange(NSRange(location: index, length: 1))
    }

    var hasText: Bool { (page?.pageRange?.length ?? 0) > 0 }
    func insertText(_ text: String) {}
    func deleteBackward() {}

}

/// A rendered offset as a text position.
final class EPUBTextPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
}

/// A rendered range as a text range.
final class EPUBTextRange: UITextRange {
    let range: NSRange
    init(_ range: NSRange) { self.range = range }
    override var start: UITextPosition { EPUBTextPosition(range.location) }
    override var end: UITextPosition { EPUBTextPosition(range.location + range.length) }
    override var isEmpty: Bool { range.length == 0 }
}

final class EPUBSelectionRect: UITextSelectionRect {
    private let rectangle: CGRect
    private let first: Bool
    private let last: Bool
    init(rect: CGRect, isFirst: Bool, isLast: Bool) { rectangle = rect; first = isFirst; last = isLast }
    override var rect: CGRect { rectangle }
    override var writingDirection: NSWritingDirection { .natural }
    override var containsStart: Bool { first }
    override var containsEnd: Bool { last }
    override var isVertical: Bool { false }
}

/// Line granularity from the line table; other granularities from the string tokenizer.
@MainActor
final class EPUBLineTokenizer: UITextInputStringTokenizer {
    private weak var pageView: EPUBPageView?

    override init(textInput: any UIResponder & UITextInput) {
        pageView = (textInput as? EPUBPageTextSurface)?.page
        super.init(textInput: textInput)
    }

    override func rangeEnclosingPosition(_ position: UITextPosition, with granularity: UITextGranularity, inDirection direction: UITextDirection) -> UITextRange? {
        guard granularity == .line, let pageView, let position = position as? EPUBTextPosition, let range = pageView.lineRange(containing: position.offset) else {
            return super.rangeEnclosingPosition(position, with: granularity, inDirection: direction)
        }
        return EPUBTextRange(range)
    }

    override func isPosition(_ position: UITextPosition, atBoundary granularity: UITextGranularity, inDirection direction: UITextDirection) -> Bool {
        guard granularity == .line, let pageView, let position = position as? EPUBTextPosition, let range = pageView.lineRange(containing: position.offset) else {
            return super.isPosition(position, atBoundary: granularity, inDirection: direction)
        }
        return position.offset == range.location || position.offset == range.location + range.length
    }

    override func position(from position: UITextPosition, toBoundary granularity: UITextGranularity, inDirection direction: UITextDirection) -> UITextPosition? {
        guard granularity == .line, let pageView, let position = position as? EPUBTextPosition, let range = pageView.lineRange(containing: position.offset) else {
            return super.position(from: position, toBoundary: granularity, inDirection: direction)
        }
        let backward = direction.rawValue == UITextStorageDirection.backward.rawValue || direction.rawValue == UITextLayoutDirection.left.rawValue || direction.rawValue == UITextLayoutDirection.up.rawValue
        return EPUBTextPosition(backward ? range.location : range.location + range.length)
    }

    override func isPosition(_ position: UITextPosition, withinTextUnit granularity: UITextGranularity, inDirection direction: UITextDirection) -> Bool {
        guard granularity == .line, let pageView, let position = position as? EPUBTextPosition else {
            return super.isPosition(position, withinTextUnit: granularity, inDirection: direction)
        }
        return pageView.lineRange(containing: position.offset) != nil
    }
}

/// One block on the page under the per-block model (Spec 14.1 alternative).
@MainActor
final class EPUBBlockElement: UIAccessibilityElement {
    private weak var pageView: EPUBPageView?
    let blockIndex: Int
    let visibleRange: NSRange
    weak var previousElement: EPUBBlockElement?
    weak var nextElement: EPUBBlockElement?
    var isLastOnPage = false

    init(container: EPUBPageView, blockIndex: Int, visibleRange: NSRange) {
        pageView = container
        self.blockIndex = blockIndex
        self.visibleRange = visibleRange
        super.init(accessibilityContainer: container)
        accessibilityIdentifier = "reader.epub.block.\(blockIndex)"
        accessibilityTextualContext = .narrative
        guard let chapter = container.chapter, chapter.blocks.indices.contains(blockIndex) else { return }
        let block = chapter.blocks[blockIndex]
        accessibilityAttributedLabel = container.attributedText(for: visibleRange)
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
                guard let container else { return false }
                return container.delegate?.pageView(container, activateLinkAt: link.range.location) ?? false
            })
        }
        accessibilityCustomActions = actions.isEmpty ? nil : actions
    }

    override var accessibilityTraits: UIAccessibilityTraits {
        get { isLastOnPage ? super.accessibilityTraits.union(.causesPageTurn) : super.accessibilityTraits }
        set { super.accessibilityTraits = newValue }
    }

    // Computed on every read from the line table, never cached as screen coordinates.
    override var accessibilityFrameInContainerSpace: CGRect {
        get {
            guard let pageView else { return .zero }
            let rects = pageView.rectangles(for: visibleRange)
            return rects.reduce(CGRect.null) { $0.union($1) }
        }
        set { super.accessibilityFrameInContainerSpace = newValue }
    }

    override var accessibilityFrame: CGRect {
        get {
            guard let pageView else { return .zero }
            return UIAccessibility.convertToScreenCoordinates(accessibilityFrameInContainerSpace, in: pageView)
        }
        set { super.accessibilityFrame = newValue }
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard let pageView else { return false }
        return pageView.accessibilityScroll(direction)
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
