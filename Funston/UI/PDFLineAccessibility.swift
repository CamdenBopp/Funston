import PDFKit
import UIKit

/// PDFKit continues to draw, zoom, select and search the original page. Only
/// its page accessibility container is replaced by the chosen recognition result.
@MainActor
final class PDFLineAccessibleView: PDFView {
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
        get { recognizedElements.map { $0 as [Any] } ?? super.accessibilityElements }
        set { super.accessibilityElements = newValue }
    }
    override func accessibilityElementCount() -> Int {
        recognizedElements?.count ?? super.accessibilityElementCount()
    }
    override func accessibilityElement(at index: Int) -> Any? {
        guard let elements = recognizedElements else { return super.accessibilityElement(at: index) }
        return elements.indices.contains(index) ? elements[index] : nil
    }
    override func index(ofAccessibilityElement element: Any) -> Int {
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
        pageView.go(to: source.pageRect(for: normalizedBounds), on: page)
    }
}
