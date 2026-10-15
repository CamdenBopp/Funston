import PDFKit
import UIKit

/// PDFKit continues to draw, zoom, select and search the original page. Only
/// its page accessibility container is replaced by the chosen recognition result.
@MainActor
final class PDFLineAccessibleView: PDFView {
    var readerPageElement: ReaderPageElement?
    var visiblePagesDidChange: (() -> Void)?
    private var linesByPage: [Int: [PDFRecognizedLineElement]] = [:]
    private var resultsByPage: [Int: PDFPageTextResult] = [:]
    private var previousVisiblePages: [Int] = []
    private weak var observedScrollView: UIScrollView?
    private var scrollingObservation: NSKeyValueObservation?

    override func layoutSubviews() {
        super.layoutSubviews()
        observeScrolling()
        reportVisiblePages()
    }

    private func observeScrolling() {
        var ancestor: UIView? = documentView
        while let view = ancestor {
            if let scroll = view as? UIScrollView {
                if scroll !== observedScrollView {
                    observedScrollView = scroll
                    scrollingObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                        Task { @MainActor [weak self] in self?.reportVisiblePages() }
                    }
                }
                return
            }
            ancestor = view.superview
        }
    }

    private func reportVisiblePages() {
        guard let document else { return }
        let pages = visiblePages.map { document.index(for: $0) }.sorted()
        if pages != previousVisiblePages {
            previousVisiblePages = pages
            visiblePagesDidChange?()
        }
    }

    func clearRecognizedLines() {
        linesByPage.removeAll()
        resultsByPage.removeAll()
        previousVisiblePages.removeAll()
    }

    func install(_ result: PDFPageTextResult, source: PDFPageRenderSource, page: PDFPage, index: Int) {
        guard document?.page(at: index) === page, resultsByPage[index] != result else { return }
        resultsByPage[index] = result
        let elements = result.lines.enumerated().compactMap { lineIndex, line -> PDFRecognizedLineElement? in
            let box = line.rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !line.text.isEmpty, !box.isNull, !box.isEmpty,
                  [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite) else { return nil }
            return PDFRecognizedLineElement(view: self, page: page, source: source, line: line.text,
                                            normalizedBounds: box, identifier: "reader.line.\(index).\(lineIndex)")
        }
        linesByPage[index] = elements
        // Keep accessibility objects near the viewport. Recognized text and boxes
        // remain in the shared persistent cache, so returning never needs fresh OCR.
        if linesByPage.count > 8, let document, let currentPage {
            let current = document.index(for: currentPage)
            let visible = Set(visiblePages.map { document.index(for: $0) })
            for old in linesByPage.keys.filter({ !visible.contains($0) }).sorted(by: { abs($0 - current) > abs($1 - current) }) {
                guard linesByPage.count > 8 else { break }
                linesByPage[old] = nil
                resultsByPage[old] = nil
            }
        }
        if UIAccessibility.isVoiceOverRunning, visiblePages.contains(where: { $0 === page }) {
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
    }

    private var recognizedElements: [PDFRecognizedLineElement]? {
        // Leave PDFKit's native Find navigator accessible while it is open.
        guard !isFindInteractionEnabled || !findInteraction.isFindNavigatorVisible, let document else { return nil }
        let elements = visiblePages.sorted { document.index(for: $0) < document.index(for: $1) }
            .flatMap { linesByPage[document.index(for: $0)] ?? [] }
        return elements.isEmpty ? nil : elements
    }

    override var accessibilityElements: [Any]? {
        get {
            let elements = recognizedElements.map { $0 as [Any] } ?? super.accessibilityElements
            guard let readerPageElement else { return elements }
            return [readerPageElement] + (elements ?? subviews)
        }
        set { super.accessibilityElements = newValue }
    }
    override func accessibilityElementCount() -> Int {
        if readerPageElement != nil { return accessibilityElements?.count ?? 0 }
        return recognizedElements?.count ?? super.accessibilityElementCount()
    }
    override func accessibilityElement(at index: Int) -> Any? {
        if readerPageElement != nil, let elements = accessibilityElements {
            return elements.indices.contains(index) ? elements[index] : nil
        }
        guard let elements = recognizedElements else { return super.accessibilityElement(at: index) }
        return elements.indices.contains(index) ? elements[index] : nil
    }
    override func index(ofAccessibilityElement element: Any) -> Int {
        if readerPageElement != nil, let elements = accessibilityElements {
            return elements.firstIndex { $0 as AnyObject === element as AnyObject } ?? NSNotFound
        }
        guard let elements = recognizedElements else { return super.index(ofAccessibilityElement: element) }
        return elements.firstIndex { $0 === element as AnyObject } ?? NSNotFound
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        switch direction {
        case .down, .left:
            guard canGoToNextPage else { return false }
            goToNextPage(nil)
        case .up, .right:
            guard canGoToPreviousPage else { return false }
            goToPreviousPage(nil)
        default: return super.accessibilityScroll(direction)
        }
        if let document, let page = currentPage {
            UIAccessibility.post(notification: .pageScrolled, argument: "Page \(document.index(for: page) + 1) of \(document.pageCount)")
        }
        return true
    }
}

@MainActor
final class PDFRecognizedLineElement: UIAccessibilityElement {
    private weak var pageView: PDFView?
    private weak var page: PDFPage?
    private let source: PDFPageRenderSource
    private let normalizedBounds: CGRect

    init(view: PDFView, page: PDFPage, source: PDFPageRenderSource, line: String, normalizedBounds: CGRect, identifier: String) {
        pageView = view; self.page = page; self.source = source; self.normalizedBounds = normalizedBounds
        super.init(accessibilityContainer: view)
        accessibilityLabel = line
        accessibilityTraits = .staticText
        accessibilityIdentifier = identifier
    }

    // Compute rather than snapshot: pinch zoom, scroll, rotation and layout changes
    // must update touch-exploration targets without re-running recognition.
    override var accessibilityFrameInContainerSpace: CGRect {
        get {
            guard let pageView, let page else { return .zero }
            return pageView.convert(source.pageRect(for: normalizedBounds), from: page)
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

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        guard let pageView, let page, !pageView.bounds.contains(accessibilityFrameInContainerSpace) else { return }
        let rect = source.pageRect(for: normalizedBounds)
        // PDFKit's go(to:) can fit the page again on iOS 27. Move only the
        // scroll position when VoiceOver reveals a line at the reader's zoom.
        var ancestor = pageView.documentView?.superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView {
                let rectInView = pageView.convert(rect, from: page)
                scroll.scrollRectToVisible(pageView.convert(rectInView, to: scroll), animated: false)
                return
            }
            ancestor = view.superview
        }
        pageView.go(to: rect, on: page)
    }
}

/// Session-only reader chrome state, shared by PDF and EPUB readers.
@MainActor
final class ReaderControls: NSObject {
    private weak var reader: UIViewController?
    private(set) var isHidden = false
    var changed: ((Bool) -> Void)?
    let page: ReaderPageElement

    init(reader: UIViewController, pageView: UIView) {
        self.reader = reader
        page = ReaderPageElement(accessibilityContainer: pageView)
        super.init()
        page.accessibilityLabel = "Reading page"
        page.accessibilityIdentifier = "reader.page"
        page.accessibilityTraits = .adjustable
        page.toggle = { [weak self] in self?.toggle(); return true }
        updateAction()
    }

    func tapped(voiceOverRunning: Bool = UIAccessibility.isVoiceOverRunning) {
        guard !voiceOverRunning else { return }
        toggle()
    }

    func toggle() { setHidden(!isHidden) }
    func restore() { setHidden(false) }

    private func setHidden(_ hidden: Bool) {
        guard hidden != isHidden, let reader else { return }
        isHidden = hidden
        reader.navigationController?.setNavigationBarHidden(hidden, animated: !UIAccessibility.isReduceMotionEnabled)
        var ancestor: UIViewController? = reader
        while let current = ancestor {
            if let root = current as? FunstonRootController { root.setReaderControlsHidden(hidden); break }
            ancestor = current.parent
        }
        changed?(hidden)
        updateAction()
        UIAccessibility.post(notification: .layoutChanged, argument: page)
    }

    /// A reader that reports a position ("Chapter 3, page 4 of 12") keeps it as the
    /// element's value; the controls state then lives only in the custom action.
    var positionValue: String? { didSet { updateAction() } }

    private func updateAction() {
        page.accessibilityValue = positionValue ?? (isHidden ? "Controls hidden" : "Controls visible")
        page.accessibilityCustomActions = [UIAccessibilityCustomAction(name: isHidden ? "Show controls" : "Hide controls") { [weak self] _ in
            self?.toggle(); return true
        }]
    }
}

@MainActor
final class ReaderPageElement: UIAccessibilityElement {
    var toggle: (() -> Bool)?
    var adjust: ((Int) -> Void)?
    override func accessibilityIncrement() { adjust?(1) }
    override func accessibilityDecrement() { adjust?(-1) }
    override func accessibilityPerformMagicTap() -> Bool { toggle?() ?? false }
    override var accessibilityFrameInContainerSpace: CGRect {
        get { (accessibilityContainer as? UIView)?.bounds ?? .zero }
        set { super.accessibilityFrameInContainerSpace = newValue }
    }
}
