import UIKit

/// Which accessibility element model the page view exposes (Spec 14.1, D4).
enum EPUBAccessibilityModel: String, Sendable {
    /// The shown page's text read line by line, headings, links and images apart (the default).
    case page
    /// The shown page with one item per paragraph, the part of it on this page;
    /// headings, links and images apart. Chosen in Settings, Accessibility.
    case paragraphs
    /// The older paragraph strip: one element per paragraph across the chapter
    /// window. Kept only for its device test; not offered in Settings.
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
    /// "p of q" within the chapter, for the page status VoiceOver offers as more content.
    func pageViewPageStatus(_ view: EPUBPageView) -> String
    func pageViewControlsHidden(_ view: EPUBPageView) -> Bool
    func pageViewToggleControls(_ view: EPUBPageView)
    /// The headings rotor ran off the shown page: show the page with the next (or previous)
    /// heading and return its element, or nil when there is none within reach.
    func pageView(_ view: EPUBPageView, headingBeyondPage forward: Bool) -> EPUBPageItemElement?
}

/// Draws one page of a chapter layout (Spec 11.3). In the pager it is the
/// page model's accessibility container: the shown page's items and nothing
/// else (EPUBPageItems), with a text surface for sighted selection that VoiceOver
/// never sees. In the strips it only draws; the strip owns the paragraph elements.
@MainActor
final class EPUBPageView: UIView {
    /// The text block sits this far inside the view on every side.
    static let margin: CGFloat = 20

    private(set) var layout: EPUBLayoutSession?
    private(set) var pageIndex = 0
    private(set) var spineIndex = 0
    private(set) var chapter: EPUBChapterText?
    weak var delegate: EPUBPageViewDelegate?
    var chapterTitle: String?
    var isRightToLeft = false
    static let caretWidth: CGFloat = 2
    /// Text selection for sighted readers. UIKit treats any UITextInput view as one
    /// text element, so it is a child kept out of the accessibility tree.
    let textSurface = EPUBPageTextSurface()
    /// The page's items as VoiceOver sees them, and every element made so far for reuse.
    private(set) var items: [EPUBPageItemElement] = []
    /// The container VoiceOver knows as the page, labelled with the chapter: the shown page's
    /// items and nothing else. One-finger swipes stop at its edges, as they do in other readers;
    /// pages turn by three-finger swipe, the page actions, double-tap-and-hold and Read All.
    let itemGroup = UIView()
    private var itemPool: [EPUBPageItemElement] = []
    private var itemsPlacement: EPUBPlacement?
    /// Posts to VoiceOver; tests substitute a recorder.
    var postAccessibilityNotification: (UIAccessibility.Notification, Any?) -> Void = { UIAccessibility.post(notification: $0, argument: $1) }
    /// VoiceOver's focused element; tests substitute their own.
    var focusedElement: () -> Any? = { UIAccessibility.focusedElement(using: .notificationVoiceOver) }
    var selection: NSRange? { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .systemBackground
        contentMode = .redraw
        accessibilityIdentifier = "reader.epub.page"
        textSurface.page = self
        textSurface.frame = bounds
        textSurface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(textSurface)
        itemGroup.frame = bounds
        itemGroup.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        itemGroup.isUserInteractionEnabled = false
        itemGroup.isAccessibilityElement = false
        itemGroup.accessibilityContainerType = .semanticGroup
        addSubview(itemGroup)
        refreshAccessibility()
    }

    /// The element VoiceOver should land on for this page.
    var focusElement: Any { items.first ?? self }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ layout: EPUBLayoutSession?, page: Int, spineIndex: Int, chapter: EPUBChapterText?, title: String?) {
        self.layout = layout
        pageIndex = page
        self.spineIndex = spineIndex
        self.chapter = chapter
        chapterTitle = title
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

    override func layoutSubviews() {
        super.layoutSubviews()
        for item in items { item.place() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsDisplay()
    }

    // MARK: - Accessibility: the page element

    private func refreshAccessibility() {
        if isTile {
            textSurface.isHidden = true
            accessibilityElementsHidden = true
            return
        }
        EPUBAccessibilityLog.shared.record("page view page=\(pageIndex) chapterLoaded=\(chapter != nil)")
        isAccessibilityElement = false
        itemGroup.accessibilityLabel = chapterTitle
        textSurface.isHidden = false
        let placement = EPUBPlacement(spineIndex: spineIndex, pageIndex: pageIndex)
        let specs = layout.flatMap { layout in chapter.map { EPUBPageItems.items(layout: layout, chapter: $0, page: pageIndex,
                                                                                          byParagraph: EPUBAccessibilityModel.preferred == .paragraphs) } } ?? []
        var order = itemPool
        if itemsPlacement != placement, let held = focusedElement() as? EPUBPageItemElement, order.contains(where: { $0 === held }) {
            // A new page: the element VoiceOver holds becomes its first, so reading goes on from the top
            // of the new page instead of VoiceOver guessing from where the old one sat on screen.
            order.removeAll { $0 === held }
            order.insert(held, at: 0)
        }
        while order.count < specs.count { order.append(EPUBPageItemElement(page: self)) }
        for unused in itemPool where !order.prefix(specs.count).contains(where: { $0 === unused }) { unused.removeFromSuperview() }
        itemPool = Array(order.prefix(specs.count))
        items = specs.enumerated().map { index, item in
            order[index].show(item, index: index, isLastOnPage: index == specs.count - 1)
            if order[index].superview !== itemGroup { itemGroup.addSubview(order[index]) }
            return order[index]
        }
        itemsPlacement = placement
        updateElementList()
    }

    private func updateElementList() {
        itemGroup.accessibilityElements = items
        accessibilityElements = [itemGroup]
        EPUBAccessibilityLog.shared.record("page items \(items.count)")
    }

    /// The element of the item holding an offset, or the first one after it.
    func item(containing offset: Int) -> EPUBPageItemElement? {
        items.first { NSLocationInRange(offset, $0.item.range) } ?? items.first { $0.item.range.location >= offset }
    }

    /// Headings on the page first; past the page's edge the delegate turns to the next one.
    var headingsRotor: UIAccessibilityCustomRotor? {
        UIAccessibilityCustomRotor(systemType: .heading) { [weak self] predicate in
            guard let self else { return nil }
            let forward = predicate.searchDirection == .next
            let from = (predicate.currentItem.targetElement as? EPUBPageItemElement).flatMap { items.contains($0) ? $0.item.range.location : nil }
            let headings = items.filter { if case .heading = $0.item.kind { return true } else { return false } }
            let onPage = from.flatMap { from in forward ? headings.first { $0.item.range.location > from } : headings.last { $0.item.range.location < from } }
                ?? (from == nil ? (forward ? headings.first : headings.last) : nil)
            if let onPage { return UIAccessibilityCustomRotorItemResult(targetElement: onPage, targetRange: nil) }
            guard let element = delegate?.pageView(self, headingBeyondPage: forward) else { return nil }
            return UIAccessibilityCustomRotorItemResult(targetElement: element, targetRange: nil)
        }
    }

    /// A page of the strip only draws; the strip owns the accessibility elements.
    var isTile = false { didSet { refreshAccessibility() } }

    /// The attributed label of a block's visible part: heading level and speech
    /// languages, with attachment characters replaced by their alternatives.
    func attributedText(for range: NSRange) -> NSAttributedString {
        guard let layout else { return NSAttributedString() }
        return Self.accessibleText(in: layout.string, range: range)
    }

    static func accessibleText(in string: NSAttributedString, range: NSRange) -> NSAttributedString {
        let source = string.attributedSubstring(from: NSIntersectionRange(range, NSRange(location: 0, length: string.length)))
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
        postAccessibilityNotification(.pageScrolled, description)
        EPUBAccessibilityLog.shared.recordFocusLater(context: "scroll")
        return true
    }

    /// The line containing an offset, for the tokenizer: the line the offset is in, or
    /// the line it ends when it is the page's end.
    func lineRange(containing offset: Int) -> NSRange? {
        guard let layout else { return nil }
        let ranges = lineFrames().map { layout.table.lines[$0.line].range }
        return ranges.first { NSLocationInRange(offset, $0) } ?? ranges.first { offset == $0.location + $0.length }
    }
}


/// Text selection over the page for sighted readers: UITextInput over rendered
/// offsets. It draws nothing (the page view does) and is hidden from VoiceOver,
/// which reads the page through its items.
@MainActor
final class EPUBPageTextSurface: UIView, UITextInput {
    weak var page: EPUBPageView?
    private lazy var textInteraction = UITextInteraction(for: .nonEditable)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        addInteraction(textInteraction)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
///
/// VoiceOver's Lines rotor treats the forward line boundary as the position before a
/// line-ending character and steps to the position after it to reach the next line, as
/// in a text view whose lines end in newlines. A soft-wrapped line in the line table
/// ends with its trailing space (or a line separator), so the boundary VoiceOver sees
/// excludes that one character; otherwise every step lands one character into the next
/// line and the spoken "lines" drift (VoiceOver report, 2026-10-15).
@MainActor
final class EPUBLineTokenizer: UITextInputStringTokenizer {
    private weak var pageView: EPUBPageView?
    private weak var paragraph: EPUBParagraphView?

    private func lineRange(containing offset: Int) -> NSRange? {
        guard let line = paragraph?.lineRange(containing: offset) ?? pageView?.lineRange(containing: offset) else { return nil }
        return Self.spokenRange(of: line, in: paragraph?.page?.chapter ?? pageView?.chapter)
    }

    /// The line without its one trailing break character, when it has one.
    static func spokenRange(of line: NSRange, in chapter: EPUBChapterText?) -> NSRange {
        guard line.length > 1, let chapter, let last = chapter.text(in: NSRange(location: line.location + line.length - 1, length: 1)).unicodeScalars.first,
              last.properties.isWhitespace || last == "\u{2028}" else { return line }
        return NSRange(location: line.location, length: line.length - 1)
    }

    override init(textInput: any UIResponder & UITextInput) {
        pageView = (textInput as? EPUBPageTextSurface)?.page
        paragraph = textInput as? EPUBParagraphView
        super.init(textInput: textInput)
    }

    override func rangeEnclosingPosition(_ position: UITextPosition, with granularity: UITextGranularity, inDirection direction: UITextDirection) -> UITextRange? {
        guard granularity == .line, let position = position as? EPUBTextPosition, let range = lineRange(containing: position.offset) else {
            return super.rangeEnclosingPosition(position, with: granularity, inDirection: direction)
        }
        return EPUBTextRange(range)
    }

    override func isPosition(_ position: UITextPosition, atBoundary granularity: UITextGranularity, inDirection direction: UITextDirection) -> Bool {
        guard granularity == .line, let position = position as? EPUBTextPosition, let range = lineRange(containing: position.offset) else {
            return super.isPosition(position, atBoundary: granularity, inDirection: direction)
        }
        return position.offset == range.location || position.offset == range.location + range.length
    }

    override func position(from position: UITextPosition, toBoundary granularity: UITextGranularity, inDirection direction: UITextDirection) -> UITextPosition? {
        guard granularity == .line, let position = position as? EPUBTextPosition, let range = lineRange(containing: position.offset) else {
            return super.position(from: position, toBoundary: granularity, inDirection: direction)
        }
        let backward = direction.rawValue == UITextStorageDirection.backward.rawValue || direction.rawValue == UITextLayoutDirection.left.rawValue || direction.rawValue == UITextLayoutDirection.up.rawValue
        return EPUBTextPosition(backward ? range.location : range.location + range.length)
    }

    override func isPosition(_ position: UITextPosition, withinTextUnit granularity: UITextGranularity, inDirection direction: UITextDirection) -> Bool {
        guard granularity == .line, let position = position as? EPUBTextPosition else {
            return super.isPosition(position, withinTextUnit: granularity, inDirection: direction)
        }
        return lineRange(containing: position.offset) != nil
    }
}
