import Accessibility
import UIKit

/// One thing VoiceOver can land on in a page: a run of text read line by
/// line, or a heading, link or image that stands on its own between the runs.
struct EPUBPageItem: Equatable {
    enum Kind: Equatable {
        case text
        case heading(level: Int)
        case link(isNote: Bool)
        case image(label: String)
    }

    /// One laid-out line of the item: the part of the line's range inside the
    /// item, and its frame in page coordinates (the text block's origin at zero).
    struct Line: Equatable {
        let range: NSRange
        let frame: CGRect
    }

    let kind: Kind
    let range: NSRange
    let lines: [Line]

    var frame: CGRect { lines.reduce(CGRect.null) { $0.union($1.frame) } }
}

/// The VoiceOver items of one page, in reading order. Only the page on screen
/// is exposed, so wherever focus enters the book it lands on that page's text.
/// Plain text between headings, links and images is one item that reads line
/// by line; the others are their own items so they can be activated and found
/// by the headings and links rotors.
@MainActor
enum EPUBPageItems {
    static let imageFallbackLabel = "Image"

    static func items(layout: EPUBLayoutSession, chapter: EPUBChapterText, page: Int) -> [EPUBPageItem] {
        guard layout.table.pages.indices.contains(page) else { return [] }
        let pageRange = layout.table.pages[page].range
        let lines = layout.table.lineFrames(onPage: page).map { (range: layout.table.lines[$0.line].range, frame: $0.frame) }

        // Headings, links and images on the page, and decorative images to leave out.
        var standalone: [(range: NSRange, kind: EPUBPageItem.Kind?)] = []
        for block in chapter.blocks where NSIntersectionRange(block.range, pageRange).length > 0 {
            let visible = NSIntersectionRange(block.range, pageRange)
            if let level = block.headingLevel {
                standalone.append((visible, .heading(level: level)))
                continue
            }
            if block.kind == .image {
                standalone.append((visible, block.isAccessible ? .image(label: label(block.alternativeText)) : nil))
                continue
            }
            for link in block.links {
                let part = NSIntersectionRange(link.range, pageRange)
                guard part.length > 0 else { continue }
                standalone.append((part, .link(isNote: block.noteReferences.contains { $0.linkIndex == link.linkIndex })))
            }
        }
        for image in chapter.images where !image.isBlock && NSLocationInRange(image.renderedOffset, pageRange) {
            let range = NSRange(location: image.renderedOffset, length: 1)
            guard !standalone.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { continue }
            standalone.append((range, image.isDecorative ? nil : .image(label: label(image.alternativeText))))
        }
        standalone.sort { $0.range.location < $1.range.location }

        var items: [EPUBPageItem] = []
        var cursor = pageRange.location
        func addText(upTo end: Int) {
            guard end > cursor, let item = item(.text, NSRange(location: cursor, length: end - cursor), lines: lines, layout: layout, page: page) else { return }
            items.append(item)
        }
        for piece in standalone where piece.range.location >= cursor {
            addText(upTo: piece.range.location)
            if let kind = piece.kind, let item = item(kind, piece.range, lines: lines, layout: layout, page: page) { items.append(item) }
            cursor = piece.range.location + piece.range.length
        }
        addText(upTo: pageRange.location + pageRange.length)
        return items
    }

    private static func label(_ alternative: String?) -> String {
        alternative.flatMap { $0.isEmpty ? nil : $0 } ?? imageFallbackLabel
    }

    /// An item over a range: the page's lines clipped to it, lines holding only
    /// white space dropped; nil when nothing readable is left (images always stay).
    private static func item(_ kind: EPUBPageItem.Kind, _ range: NSRange, lines: [(range: NSRange, frame: CGRect)], layout: EPUBLayoutSession, page: Int) -> EPUBPageItem? {
        var result: [EPUBPageItem.Line] = []
        for line in lines {
            let part = NSIntersectionRange(line.range, range)
            guard part.length > 0 else { continue }
            if case .image = kind {} else if isBlank(part, in: layout.string) { continue }
            if part == line.range {
                result.append(.init(range: part, frame: line.frame))
            } else {
                // Part of a line: its own glyphs across, the whole line's height, so touch finds it.
                let glyphs = layout.rectangles(for: part, onPage: page).reduce(CGRect.null) { $0.union($1) }
                let frame = glyphs.isNull ? line.frame : CGRect(x: glyphs.minX, y: line.frame.minY, width: glyphs.width, height: line.frame.height)
                result.append(.init(range: part, frame: frame))
            }
        }
        guard let first = result.first, let last = result.last else { return nil }
        let covered = NSRange(location: first.range.location, length: last.range.location + last.range.length - first.range.location)
        return EPUBPageItem(kind: kind, range: covered, lines: result)
    }

    private static func isBlank(_ range: NSRange, in string: NSAttributedString) -> Bool {
        let clipped = NSIntersectionRange(range, NSRange(location: 0, length: string.length))
        return (string.string as NSString).substring(with: clipped).allSatisfy { $0.isWhitespace || $0 == "\u{FFFC}" }
    }
}

/// One page item as VoiceOver sees it. Text, headings and links read through
/// UIAccessibilityReadingContent, so VoiceOver reads the item, steps it line by
/// line and finds a line under the finger. Every item carries the reader's
/// controls (show or hide, next and previous page) as custom actions and the page
/// status as custom content; the last item turns the page when VoiceOver reads
/// past it. Elements are reused from page to page: the one VoiceOver holds when the
/// page turns becomes the new page's first, so reading carries on from its top.
/// Each is a transparent view over its text that takes no touches, so taps reach the page.
@MainActor
final class EPUBPageItemElement: UIView, UIAccessibilityReadingContent, @preconcurrency AXCustomContentProvider {
    private weak var page: EPUBPageView?
    private(set) var item = EPUBPageItem(kind: .text, range: NSRange(location: 0, length: 0), lines: [])
    private(set) var isLastOnPage = false

    init(page: EPUBPageView) {
        self.page = page
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTextualContext = .narrative
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Puts the view over its text.
    func place() {
        frame = item.frame.isNull ? .zero : item.frame.offsetBy(dx: origin.x, dy: origin.y)
    }

    func show(_ item: EPUBPageItem, index: Int, isLastOnPage: Bool) {
        self.item = item
        self.isLastOnPage = isLastOnPage
        accessibilityIdentifier = "reader.epub.item.\(index)"
        var traits: UIAccessibilityTraits = []
        switch item.kind {
        case .text: traits = .staticText
        case .heading: traits = .header
        case .link: traits = .link
        case .image: traits = .image
        }
        if isLastOnPage { traits.insert(.causesPageTurn) }
        accessibilityTraits = traits
        place()
    }

    private var origin: CGPoint { page?.contentOrigin ?? .zero }

    private func spoken(_ range: NSRange) -> NSAttributedString {
        if case .image(let label) = item.kind { return NSAttributedString(string: label) }
        return page?.attributedText(for: range) ?? NSAttributedString()
    }

    // MARK: Reading content

    func accessibilityLineNumber(for point: CGPoint) -> Int {
        guard let page else { return NSNotFound }
        // Reading content points arrive in screen coordinates: undo the conversion the line frames went through.
        let pageOnScreen = UIAccessibility.convertToScreenCoordinates(page.bounds, in: page)
        let probe = CGPoint(x: point.x - pageOnScreen.minX - origin.x, y: point.y - pageOnScreen.minY - origin.y)
        return item.lines.firstIndex { $0.frame.insetBy(dx: -Self.lineHitSlop, dy: 0).contains(probe) } ?? NSNotFound
    }
    /// Touch on a line's first or last letter still finds it.
    static let lineHitSlop: CGFloat = 1

    func accessibilityContent(forLineNumber lineNumber: Int) -> String? {
        accessibilityAttributedContent(forLineNumber: lineNumber)?.string
    }

    func accessibilityAttributedContent(forLineNumber lineNumber: Int) -> NSAttributedString? {
        guard item.lines.indices.contains(lineNumber) else { return nil }
        if case .image = item.kind { return spoken(item.range) }
        return spoken(item.lines[lineNumber].range)
    }

    func accessibilityFrame(forLineNumber lineNumber: Int) -> CGRect {
        guard let page, item.lines.indices.contains(lineNumber) else { return .zero }
        return UIAccessibility.convertToScreenCoordinates(item.lines[lineNumber].frame.offsetBy(dx: origin.x, dy: origin.y), in: page)
    }

    func accessibilityPageContent() -> String? { accessibilityAttributedPageContent()?.string }

    func accessibilityAttributedPageContent() -> NSAttributedString? {
        EPUBAccessibilityLog.shared.record("item pageContent \(accessibilityIdentifier ?? "") range=\(item.range)")
        return spoken(item.range)
    }

    // MARK: Gestures

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        page?.accessibilityScroll(direction) ?? false
    }

    override func accessibilityActivate() -> Bool {
        guard case .link = item.kind, let page else { return true }
        return page.delegate?.pageView(page, activateLinkAt: item.range.location) ?? false
    }

    override func accessibilityPerformMagicTap() -> Bool {
        guard let page, let delegate = page.delegate else { return false }
        delegate.pageViewToggleControls(page)
        return true
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            guard let page, let delegate = page.delegate else { return nil }
            let controls = delegate.pageViewControlsHidden(page) ? "Show controls" : "Hide controls"
            return [
                UIAccessibilityCustomAction(name: controls) { [weak page] _ in
                    guard let page else { return false }
                    page.delegate?.pageViewToggleControls(page)
                    return true
                },
                UIAccessibilityCustomAction(name: "Next page") { [weak page] _ in page?.accessibilityScroll(.next) ?? false },
                UIAccessibilityCustomAction(name: "Previous page") { [weak page] _ in page?.accessibilityScroll(.previous) ?? false }
            ]
        }
        set { super.accessibilityCustomActions = newValue }
    }

    var accessibilityCustomContent: [AXCustomContent]! {
        get {
            guard let page, let delegate = page.delegate else { return [] }
            var content = [AXCustomContent(label: "Page", value: delegate.pageViewPageStatus(page))]
            if let title = page.chapterTitle, !title.isEmpty { content.append(AXCustomContent(label: "Chapter", value: title)) }
            return content
        }
        set {}
    }

    override var accessibilityCustomRotors: [UIAccessibilityCustomRotor]? {
        get { page?.headingsRotor.map { [$0] } }
        set { super.accessibilityCustomRotors = newValue }
    }
}
