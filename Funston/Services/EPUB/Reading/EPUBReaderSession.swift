import Foundation
import UIKit

/// Where the reader is: a chapter and a page of its current layout.
struct EPUBPlacement: Sendable, Hashable {
    let spineIndex: Int
    let pageIndex: Int
}

/// A navigation target (Spec 13.1).
enum EPUBGoTarget: Sendable, Hashable {
    case spine(Int)
    case target(EPUBTarget)
    case offset(spineIndex: Int, offset: Int)
    case restored(EPUBRestoredPosition)
    case fraction(Double)
    case location(Int)
}

/// The reading state behind the views: the open book, settings, loaded
/// chapters, resident layouts, the current placement, navigation and
/// relocation reports (Spec sections 11.6, 12.4, 13). Views draw what it
/// hands them; it never touches a view.
@MainActor
final class EPUBReaderSession {
    /// Chapters whose text is kept alongside the layout window.
    static let chapterWindowRadius = 1
    /// The next chapter lays out ahead when the reader is within this many pages of a boundary.
    static let prefetchPageDistance = 2

    let publication: EPUBPublication
    let resources: EPUBBookResources
    let cache = EPUBLayoutCache()
    private(set) var settings: EPUBReadingSettings
    private(set) var contentSize: CGSize
    private(set) var allowsTwoColumns: Bool
    private(set) var mediaContext: EPUBMediaContext
    private(set) var placement: EPUBPlacement?
    /// The first visible rendered offset of the current page, kept across relayouts (Spec 11.5).
    private(set) var anchor: EPUBLayoutAnchor?
    private var chapters: [Int: EPUBLoadedChapter] = [:]
    private var lastReport: EPUBRelocation?
    /// Serialised navigation: the newest request wins (RDN-25).
    private var navigationGeneration = 0
    /// The departure locators of links and contents taps (RDN-29).
    private(set) var backStack: [EPUBLocator] = []
    static let backStackLimit = 32

    var diagnostics = EPUBDiagnosticList()

    init(publication: EPUBPublication, settings: EPUBReadingSettings, contentSize: CGSize, allowsTwoColumns: Bool, mediaContext: EPUBMediaContext) {
        self.publication = publication
        resources = EPUBBookResources(publication: publication)
        self.settings = settings
        self.contentSize = contentSize
        self.allowsTwoColumns = allowsTwoColumns
        self.mediaContext = mediaContext
        diagnostics.merge(publication.diagnostics)
    }

    var scale: EPUBProgressScale { EPUBProgressScale(weights: publication.weights) }
    var geometry: EPUBPageGeometry { EPUBPageGeometry(contentSize: contentSize, baseFontSize: settings.baseFontSize, allowsTwoColumns: allowsTwoColumns) }
    var layoutKey: EPUBLayoutKey { EPUBLayoutKey(contentSize: contentSize, settings: settings, twoColumns: geometry.columnCount == 2) }
    private var textGeometry: EPUBTextGeometry { EPUBTextGeometry(columnWidth: geometry.columnWidth, maximumImageHeight: contentSize.height) }

    // MARK: Chapters and layouts

    /// The spine indices the reader can show, in order.
    var readableSpine: [Int] {
        publication.package.spine.indices.filter { index in
            let item = publication.package.spine[index]
            if case .placeholder = item.kind { return false }
            return item.isLinear
        }
    }

    func chapter(_ spineIndex: Int) -> EPUBLoadedChapter? {
        if let loaded = chapters[spineIndex] { return loaded }
        let loader = EPUBChapterLoader(resources: resources, settings: settings, geometry: textGeometry, mediaContext: mediaContext)
        guard let loaded = loader.load(spineIndex: spineIndex) else { return nil }
        chapters[spineIndex] = loaded
        diagnostics.merge(loaded.diagnostics)
        return loaded
    }

    /// The layout of a chapter under the current key, laid out now when not resident.
    func layout(_ spineIndex: Int, extent: EPUBLayoutExtent = .whole) -> EPUBLayoutSession? {
        let key = layoutKey
        if let resident = cache.session(spineIndex: spineIndex, key: key), !resident.isPartial || extent == .firstPage { return resident }
        guard let chapter = chapter(spineIndex) else { return nil }
        let wanted: EPUBLayoutExtent = extent == .whole || chapter.text.length <= EPUBLayoutSession.twoPassThreshold ? .whole : .firstPage
        let session = EPUBLayoutSession(text: chapter.text, geometry: geometry, key: key, settings: settings, margins: 0, extent: wanted)
        cache.store(session, spineIndex: spineIndex, current: placement?.spineIndex ?? spineIndex)
        return session
    }

    /// Lays out the whole of a chapter that only has its first page, off the main actor, then installs it.
    func completeLayout(_ spineIndex: Int) async {
        guard let partial = cache.session(spineIndex: spineIndex, key: layoutKey), partial.isPartial else { return }
        let text = partial.text, geometry = geometry, key = layoutKey, settings = settings
        let whole = await Task.detached(priority: .userInitiated) {
            EPUBLayoutSession(text: text, geometry: geometry, key: key, settings: settings, margins: 0, extent: .whole)
        }.value
        guard key == layoutKey else { return }
        cache.store(whole, spineIndex: spineIndex, current: placement?.spineIndex ?? spineIndex)
    }

    /// Drops chapters and layouts outside the window around the current chapter.
    func trimWindow() {
        guard let current = placement?.spineIndex else { return }
        cache.retain(around: current, radius: Self.chapterWindowRadius)
        chapters = chapters.filter { abs($0.key - current) <= Self.chapterWindowRadius }
    }

    /// Memory pressure: everything but the current chapter goes.
    func shed() {
        cache.shed(keeping: placement?.spineIndex)
        chapters = chapters.filter { $0.key == placement?.spineIndex }
        resources.images.shedDecodedImages()
    }

    /// The neighbour to lay out ahead, if the reader is near a boundary (Spec 11.6).
    func neighbourToPrefetch() -> Int? {
        guard let placement, let layout = layout(placement.spineIndex) else { return nil }
        if layout.pageCount - 1 - placement.pageIndex < Self.prefetchPageDistance, let next = neighbour(of: placement.spineIndex, forward: true), cache.session(spineIndex: next, key: layoutKey) == nil { return next }
        if placement.pageIndex < Self.prefetchPageDistance, let previous = neighbour(of: placement.spineIndex, forward: false), cache.session(spineIndex: previous, key: layoutKey) == nil { return previous }
        return nil
    }

    func neighbour(of spineIndex: Int, forward: Bool) -> Int? {
        let order = readableSpine
        guard let position = order.firstIndex(of: spineIndex) else { return forward ? order.first { $0 > spineIndex } : order.last { $0 < spineIndex } }
        let next = forward ? position + 1 : position - 1
        return order.indices.contains(next) ? order[next] : nil
    }

    // MARK: Settings and geometry

    /// Applies new settings or geometry, keeping the reader's text in view (Spec 11.5).
    func update(settings: EPUBReadingSettings? = nil, contentSize: CGSize? = nil, allowsTwoColumns: Bool? = nil, mediaContext: EPUBMediaContext? = nil) {
        let textChanged = (settings != nil && settings != self.settings) || (mediaContext != nil && mediaContext != self.mediaContext)
        if let settings { self.settings = settings }
        if let contentSize { self.contentSize = contentSize }
        if let allowsTwoColumns { self.allowsTwoColumns = allowsTwoColumns }
        if let mediaContext { self.mediaContext = mediaContext }
        if textChanged { chapters.removeAll(); cache.removeAll() }
        guard let anchor else { return }
        if let layout = layout(anchor.spineIndex), let page = anchor.page(in: layout.table) {
            placement = EPUBPlacement(spineIndex: anchor.spineIndex, pageIndex: page)
        }
    }

    // MARK: Navigation

    /// Resolves a target to a placement and makes it current. Nil when the target cannot be shown.
    @discardableResult
    func go(to target: EPUBGoTarget, recordingDeparture: Bool = false) -> EPUBPlacement? {
        navigationGeneration += 1
        if recordingDeparture, let departure = currentLocator() {
            backStack.append(departure)
            if backStack.count > Self.backStackLimit { backStack.removeFirst() }
        }
        guard let (spineIndex, offset) = resolve(target) else { return nil }
        guard let layout = layout(spineIndex) else { return nil }
        let page = layout.table.pageIndex(containing: offset) ?? 0
        let placement = EPUBPlacement(spineIndex: spineIndex, pageIndex: page)
        set(placement, layout: layout)
        return placement
    }

    /// The departure of the last link or contents tap, if any.
    func goBack() -> EPUBPlacement? {
        guard let departure = backStack.popLast() else { return nil }
        let resolver = EPUBPositionResolver(publication: publication) { [weak self] in self?.chapter($0) }
        return go(to: .restored(resolver.resolve(departure)))
    }

    /// Moves one page; false at the book's ends without moving (Spec 13.1).
    @discardableResult
    func forward() -> Bool { turn(forward: true) }
    @discardableResult
    func backward() -> Bool { turn(forward: false) }

    private func turn(forward: Bool) -> Bool {
        guard let placement, let next = neighbourPlacement(of: placement, forward: forward), let layout = layout(next.spineIndex) else { return false }
        set(next, layout: layout)
        return true
    }

    /// The page after or before a placement, crossing into the neighbouring
    /// chapter at the ends; nil at the book's ends. Lays out what it needs.
    func neighbourPlacement(of placement: EPUBPlacement, forward: Bool) -> EPUBPlacement? {
        guard let layout = layout(placement.spineIndex) else { return nil }
        let next = placement.pageIndex + (forward ? 1 : -1)
        if next >= 0, next < layout.pageCount { return EPUBPlacement(spineIndex: placement.spineIndex, pageIndex: next) }
        guard let neighbourIndex = neighbour(of: placement.spineIndex, forward: forward), let neighbourLayout = self.layout(neighbourIndex) else { return nil }
        return EPUBPlacement(spineIndex: neighbourIndex, pageIndex: forward ? 0 : max(0, neighbourLayout.pageCount - 1))
    }

    /// Makes a placement current (a page view settled on it).
    func show(_ placement: EPUBPlacement) {
        guard let layout = layout(placement.spineIndex), placement.pageIndex >= 0, placement.pageIndex < layout.pageCount else { return }
        set(placement, layout: layout)
    }

    /// Shows a page of the current layout directly.
    func show(page: Int) {
        guard let placement else { return }
        show(EPUBPlacement(spineIndex: placement.spineIndex, pageIndex: page))
    }

    /// Continuous mode: the first visible character becomes the position (Spec 12.2).
    func show(visibleOffset offset: Int, spineIndex: Int) {
        guard let layout = layout(spineIndex), let chapter = chapter(spineIndex) else { return }
        let clamped = min(max(0, offset), max(0, chapter.text.length - 1))
        placement = EPUBPlacement(spineIndex: spineIndex, pageIndex: layout.table.pageIndex(containing: clamped) ?? 0)
        anchor = EPUBLayoutAnchor(spineIndex: spineIndex, renderedOffset: clamped, blockIndex: chapter.text.blockIndex(containing: clamped))
        trimWindow()
    }

    private func set(_ placement: EPUBPlacement, layout: EPUBLayoutSession) {
        self.placement = placement
        let page = layout.table.pages[min(placement.pageIndex, max(0, layout.pageCount - 1))]
        anchor = EPUBLayoutAnchor(spineIndex: placement.spineIndex, renderedOffset: page.firstOffset, blockIndex: chapter(placement.spineIndex)?.text.blockIndex(containing: page.firstOffset))
        trimWindow()
    }

    /// The chapter and rendered offset a target names, falling through the ladder of Spec 13.1.
    func resolve(_ target: EPUBGoTarget) -> (spineIndex: Int, offset: Int)? {
        switch target {
        case .spine(let index):
            return readableSpine.contains(index) ? (index, 0) : nil
        case .target(let epubTarget):
            guard readableSpine.contains(epubTarget.spineIndex) else { return nil }
            guard let fragment = epubTarget.fragment, !fragment.isEmpty, let chapter = chapter(epubTarget.spineIndex) else { return (epubTarget.spineIndex, 0) }
            if let offset = chapter.text.anchors[fragment] { return (epubTarget.spineIndex, offset) }
            if let named = chapter.document.tree.elements(named: "a").first(where: { chapter.document.tree.attribute("name", of: $0) == fragment }),
               let offset = chapter.text.runTable.renderedOffset(for: .element(named), in: chapter.document.tree) { return (epubTarget.spineIndex, offset) }
            diagnostics.record(.position, "link.fragmentMissing", path: chapter.document.path, spineIndex: epubTarget.spineIndex, "A link fragment was not found; the document start is shown.")
            return (epubTarget.spineIndex, 0)
        case .offset(let spineIndex, let offset):
            guard let chapter = chapter(spineIndex) else { return nil }
            return (spineIndex, min(max(0, offset), max(0, chapter.text.length - 1)))
        case .restored(let restored):
            guard let chapter = chapter(restored.spineIndex) else { return nil }
            let offset = restored.offset ?? Int((restored.progression * Double(chapter.text.length)).rounded())
            return (restored.spineIndex, min(max(0, offset), max(0, chapter.text.length - 1)))
        case .fraction(let fraction):
            guard let position = scale.position(forFraction: fraction) else { return nil }
            return resolve(.restored(EPUBRestoredPosition(spineIndex: position.spineIndex, offset: nil, progression: position.progression, method: .totalProgression, fallbacks: [])))
        case .location(let location):
            let fraction = Double(max(0, location - 1)) / Double(max(1, scale.totalLocations))
            return resolve(.fraction(fraction))
        }
    }

    // MARK: Reports

    /// The locator of the current page's first character.
    func currentLocator() -> EPUBLocator? {
        guard let placement, let layout = layout(placement.spineIndex), let chapter = chapter(placement.spineIndex), layout.table.pages.indices.contains(placement.pageIndex) else { return nil }
        let page = layout.table.pages[placement.pageIndex]
        let offset = anchor?.spineIndex == placement.spineIndex ? (anchor?.renderedOffset ?? page.firstOffset) : page.firstOffset
        return EPUBLocator.make(publication: publication, spineIndex: placement.spineIndex, chapter: chapter, offset: offset, title: contentsEntry(spineIndex: placement.spineIndex, offset: offset)?.label)
    }

    /// The current-location report, or nil when nothing changed since the last one (Spec 12.4).
    func relocationIfChanged() -> EPUBRelocation? {
        guard let report = relocation() else { return nil }
        if let last = lastReport, last.visibleRange == report.visibleRange, last.locator.spineIndex == report.locator.spineIndex, last.pageIndex == report.pageIndex, last.pageCount == report.pageCount { return nil }
        lastReport = report
        return report
    }

    func relocation() -> EPUBRelocation? {
        guard let placement, let layout = layout(placement.spineIndex), let locator = currentLocator(), layout.table.pages.indices.contains(placement.pageIndex) else { return nil }
        let page = layout.table.pages[placement.pageIndex]
        let order = readableSpine
        let atStart = placement.pageIndex == 0 && order.first == placement.spineIndex
        let atEnd = placement.pageIndex == layout.pageCount - 1 && order.last == placement.spineIndex && !layout.isPartial
        return EPUBRelocation(locator: locator, visibleRange: page.range, pageIndex: placement.pageIndex, pageCount: layout.pageCount, location: locator.location,
                              totalLocations: scale.totalLocations, contentsEntry: contentsEntry(spineIndex: placement.spineIndex, offset: page.firstOffset),
                              pageLabel: pageLabel(spineIndex: placement.spineIndex, before: page.endOffset), atStart: atStart, atEnd: atEnd)
    }

    /// The deepest contents entry at or before a position (FOL-34).
    func contentsEntry(spineIndex: Int, offset: Int) -> EPUBContentsEntry? {
        var best: (entry: EPUBContentsEntry, spine: Int, offset: Int)?
        let chapterAnchors = chapter(spineIndex)?.text.anchors ?? [:]
        for (entry, _) in publication.navigation.flattenedContents {
            guard let target = entry.target, target.spineIndex <= spineIndex else { continue }
            let entryOffset: Int
            if target.spineIndex == spineIndex {
                entryOffset = target.fragment.flatMap { chapterAnchors[$0] } ?? 0
                guard entryOffset <= offset else { continue }
            } else {
                entryOffset = 0
            }
            if let current = best, (current.spine, current.offset) > (target.spineIndex, entryOffset) { continue }
            best = (entry, target.spineIndex, entryOffset)
        }
        return best?.entry
    }

    /// The last print page label before an offset in the chapter, when the book has page breaks.
    func pageLabel(spineIndex: Int, before offset: Int) -> String? {
        guard let loaded = chapter(spineIndex) else { return nil }
        if let last = loaded.text.pageBreaks.last(where: { $0.renderedOffset < offset }) { return last.label }
        var index = spineIndex
        while let previous = neighbour(of: index, forward: false) {
            if let label = chapter(previous)?.text.pageBreaks.last?.label { return label }
            index = previous
        }
        return nil
    }

    // MARK: Links and notes

    /// The link under a rendered offset in a chapter, if any.
    func link(at offset: Int, spineIndex: Int) -> (target: EPUBLinkTarget, range: EPUBLinkRange, isNoteReference: Bool)? {
        guard let chapter = chapter(spineIndex), let blockIndex = chapter.text.blockIndex(containing: offset) else { return nil }
        let block = chapter.text.blocks[blockIndex]
        guard let range = block.links.first(where: { NSLocationInRange(offset, $0.range) }), chapter.text.links.indices.contains(range.linkIndex) else { return nil }
        let isNote = block.noteReferences.contains { $0.linkIndex == range.linkIndex }
        return (chapter.text.links[range.linkIndex], range, isNote)
    }

    /// The note body a reference points at: its blocks' text and the chapter range (Spec 13.4).
    func noteBody(for target: EPUBLinkTarget) -> EPUBNoteBody? {
        guard case .internalLink(_, let fragment, let spineIndex?) = target, let fragment, let loaded = chapter(spineIndex), let anchor = loaded.text.anchors[fragment] else { return nil }
        let text = loaded.text
        var blockIndex: Int
        if let index = text.blockIndex(containing: anchor) { blockIndex = index }
        else if let index = text.blocks.firstIndex(where: { $0.range.location >= anchor }) { blockIndex = index }
        else { return nil }
        let block = text.blocks[blockIndex]
        var range = block.range
        // The whole note container when the target sits in one.
        if let container = block.containers.compactMap({ text.containers.indices.contains($0) ? text.containers[$0] : nil }).first(where: { if case .note = $0.kind { return true } else { return false } }) {
            range = container.range
            blockIndex = text.blockIndex(containing: range.location) ?? blockIndex
        }
        let blocks = text.blocks.filter { NSIntersectionRange($0.range, range).length > 0 || ($0.range.length == 0 && NSLocationInRange($0.range.location, range)) }
        let backlink = blocks.flatMap { $0.links }.compactMap { link -> EPUBLinkTarget? in
            guard text.links.indices.contains(link.linkIndex), case .internalLink = text.links[link.linkIndex] else { return nil }
            return text.links[link.linkIndex]
        }.first
        return EPUBNoteBody(spineIndex: spineIndex, range: range, blocks: blocks, text: text.text(in: range), backlink: backlink, firstBlockIndex: blockIndex)
    }

    /// Whether a block carries one of the note-related semantics so it can be skipped in reading.
    static func isNoteOrPageNumber(_ block: EPUBBlock) -> Bool {
        block.kind == .noteBody || !block.semantics.isDisjoint(with: EPUBSemantics.noteBodyTerms)
    }
}

/// The blocks of a note body (Spec 13.4).
struct EPUBNoteBody: Sendable, Hashable {
    let spineIndex: Int
    let range: NSRange
    let blocks: [EPUBBlock]
    let text: String
    let backlink: EPUBLinkTarget?
    let firstBlockIndex: Int
}
