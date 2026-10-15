import Foundation

/// Where a navigation entry points: a spine position and an optional fragment.
struct EPUBTarget: Sendable, Hashable {
    let spineIndex: Int
    let fragment: String?
}

/// One row of the table of contents, the page list or the landmarks.
struct EPUBContentsEntry: Sendable, Hashable {
    enum Source: Sendable, Hashable { case navigationDocument, ncx, guide, synthetic }
    static let untitledLabel = "Untitled section"

    let label: String
    /// The href as written, when there was one.
    let href: String?
    /// Resolved at parse time; nil for a heading without a target or an unresolvable href.
    let target: EPUBTarget?
    /// True when the entry had an href that matches no spine item.
    let isUnresolved: Bool
    let isHidden: Bool
    let source: Source
    /// Expanded `epub:type` terms for landmarks, raw type for guide references.
    let semanticTerms: Set<String>
    /// The NCX page target `value` or type, when any.
    let pageValue: String?
    var children: [EPUBContentsEntry]

    init(label: String, href: String? = nil, target: EPUBTarget?, isUnresolved: Bool = false, isHidden: Bool = false, source: Source,
         semanticTerms: Set<String> = [], pageValue: String? = nil, children: [EPUBContentsEntry] = []) {
        self.label = label; self.href = href; self.target = target; self.isUnresolved = isUnresolved; self.isHidden = isHidden
        self.source = source; self.semanticTerms = semanticTerms; self.pageValue = pageValue; self.children = children
    }

    /// Depth-first with the depth of each entry, as the contents list shows it.
    func flattened(depth: Int = 0) -> [(entry: EPUBContentsEntry, depth: Int)] {
        [(self, depth)] + children.flatMap { $0.flattened(depth: depth + 1) }
    }
}

/// The merged navigation tables of a book (Spec section 7).
struct EPUBNavigationTables: Sendable, Hashable {
    let contents: [EPUBContentsEntry]
    let contentsSource: EPUBContentsEntry.Source
    let pageList: [EPUBContentsEntry]
    let landmarks: [EPUBContentsEntry]
    /// Other typed navs and NCX navLists, keyed by their type term or title.
    let otherLists: [String: [EPUBContentsEntry]]
    let diagnostics: EPUBDiagnosticList

    var isSynthetic: Bool { contentsSource == .synthetic }
    var flattenedContents: [(entry: EPUBContentsEntry, depth: Int)] { contents.flatMap { $0.flattened() } }

    static let bodymatterTerm = EPUBPropertyVocabulary.structuralSemantics + "bodymatter"
    static let tocTerm = EPUBPropertyVocabulary.structuralSemantics + "toc"
    static let pageListTerm = EPUBPropertyVocabulary.structuralSemantics + "page-list"
    static let landmarksTerm = EPUBPropertyVocabulary.structuralSemantics + "landmarks"
    /// Fewer entries than this into the body means the authored table is useless.
    static let minimumBodyEntries = 2
}

/// Builds the navigation tables from the navigation document, the NCX and the
/// guide, then applies the synthetic rule when the result does not cover the body.
enum EPUBNavigationBuilder {
    struct SpineText: Sendable {
        /// The first h1 to h3 heading of each document spine item, when the caller read it.
        let headings: [Int: String]
        let titles: [Int: String]
    }

    static func build(package: EPUBPackageDocument, zip: EPUBZipReader, spineText: (EPUBSpineItem) -> (heading: String?, title: String?)) -> EPUBNavigationTables {
        var diagnostics = EPUBDiagnosticList()
        var contents: [EPUBContentsEntry] = []
        var contentsSource: EPUBContentsEntry.Source = .navigationDocument
        var pageList: [EPUBContentsEntry] = []
        var landmarks: [EPUBContentsEntry] = []
        var other: [String: [EPUBContentsEntry]] = [:]

        var navigationFailed = true
        if let item = package.navigationItem, let path = item.entry {
            if let bytes = try? zip.contents(named: path), let document = try? EPUBXMLDocument.parse(bytes) {
                navigationFailed = false
                let prefixes = document.documentElement.flatMap { EPUBPropertyVocabulary.declaredPrefixes(document.attribute("prefix", namespace: EPUBNamespace.ops, of: $0) ?? document.attribute(qualified: "epub:prefix", of: $0)) } ?? [:]
                for nav in document.elements(named: "nav") {
                    let terms = EPUBPropertyVocabulary.expandedTerms(document.epubType(of: nav), context: .epubType, declared: prefixes)
                    let hidden = document.attribute("hidden", of: nav) != nil
                    let entries = list(in: nav, document: document, basePath: path, package: package, zip: zip, hidden: hidden, prefixes: prefixes, diagnostics: &diagnostics)
                    if terms.contains(EPUBNavigationTables.tocTerm) {
                        if contents.isEmpty { contents = entries }
                    } else if terms.contains(EPUBNavigationTables.pageListTerm) {
                        if pageList.isEmpty { pageList = entries.flatMap { $0.flattened().map(\.entry) } }
                    } else if terms.contains(EPUBNavigationTables.landmarksTerm) {
                        if landmarks.isEmpty { landmarks = entries.flatMap { $0.flattened().map(\.entry) } }
                    } else if let term = terms.first ?? document.epubType(of: nav) {
                        other[term, default: []].append(contentsOf: entries)
                    }
                }
                if contents.isEmpty {
                    diagnostics.record(.navigation, "nav.tocEmpty", path: path, "The navigation document has no table of contents entries.")
                }
            } else {
                diagnostics.record(.navigation, "nav.unparsable", path: path, "The navigation document could not be parsed.")
            }
        } else if package.navigationItem != nil {
            diagnostics.record(.navigation, "nav.missing", path: package.navigationItem?.rawHref, "The navigation document named in the manifest is not in the archive.")
        }

        // NCX fills what the navigation document lacks.
        if let ncx = ncxItem(package), let path = ncx.entry {
            if let bytes = try? zip.contents(named: path), let document = try? EPUBXMLDocument.parse(bytes) {
                let parsed = parseNCX(document, basePath: path, package: package, zip: zip, diagnostics: &diagnostics)
                if contents.isEmpty, !parsed.contents.isEmpty {
                    contents = parsed.contents
                    contentsSource = .ncx
                    if !navigationFailed || package.navigationItem != nil {
                        diagnostics.record(.navigation, "nav.fallbackNCX", path: path, "The table of contents comes from the NCX.")
                    }
                }
                if pageList.isEmpty { pageList = parsed.pageList }
                for (name, list) in parsed.otherLists where other[name] == nil { other[name] = list }
            } else {
                diagnostics.record(.navigation, "ncx.unparsable", path: path, "The NCX could not be parsed.")
            }
        }
        if landmarks.isEmpty {
            landmarks = package.guide.compactMap { reference in
                let target = reference.path.flatMap { package.spineIndex(forPath: $0) }.map { EPUBTarget(spineIndex: $0, fragment: reference.fragment) }
                return EPUBContentsEntry(label: reference.title ?? reference.type, href: reference.href, target: target,
                                         isUnresolved: target == nil, source: .guide, semanticTerms: [guideTerm(reference.type)])
            }
        }

        // The synthetic rule.
        if needsSyntheticContents(contents, package: package, zip: zip) {
            let authored = contents
            contents = syntheticContents(package: package, spineText: spineText)
            contentsSource = .synthetic
            diagnostics.record(.navigation, "nav.synthetic", path: package.path, authored.isEmpty ? "The book has no usable table of contents; one was generated from its headings." : "The table of contents does not cover the body; one was generated from headings.")
        }
        return EPUBNavigationTables(contents: contents, contentsSource: contentsSource, pageList: pageList, landmarks: landmarks, otherLists: other, diagnostics: diagnostics)
    }

    static func ncxItem(_ package: EPUBPackageDocument) -> EPUBManifestItem? {
        if let id = package.tocItemID, let item = package.item(withID: id) { return item }
        return package.manifest.first { $0.mediaType?.isNCX ?? false } ?? package.manifest.first { $0.path?.lowercased().hasSuffix(".ncx") ?? false }
    }

    static func guideTerm(_ type: String) -> String {
        switch type {
        case "text": return EPUBNavigationTables.bodymatterTerm
        case "toc": return EPUBNavigationTables.tocTerm
        default: return EPUBPropertyVocabulary.structuralSemantics + type
        }
    }

    // MARK: Navigation document

    private static func list(in container: EPUBXMLDocument.NodeID, document: EPUBXMLDocument, basePath: String, package: EPUBPackageDocument, zip: EPUBZipReader, hidden: Bool, prefixes: [String: String], diagnostics: inout EPUBDiagnosticList) -> [EPUBContentsEntry] {
        guard let list = document.firstChildElement(named: "ol", of: container) ?? document.descendantElements(named: "ol", of: container).first else { return [] }
        return entries(of: list, document: document, basePath: basePath, package: package, zip: zip, hidden: hidden || document.attribute("hidden", of: list) != nil, prefixes: prefixes, diagnostics: &diagnostics)
    }

    private static func entries(of list: EPUBXMLDocument.NodeID, document: EPUBXMLDocument, basePath: String, package: EPUBPackageDocument, zip: EPUBZipReader, hidden: Bool, prefixes: [String: String], diagnostics: inout EPUBDiagnosticList) -> [EPUBContentsEntry] {
        var result: [EPUBContentsEntry] = []
        for item in document.childElements(of: list) where document.isElement(item, "li") {
            let children = document.childElements(of: item)
            let link = children.first { document.isElement($0, "a") || document.isElement($0, "span") }
            let nested = children.first { document.isElement($0, "ol") }
            var label = link.map { labelText(of: $0, document: document) } ?? ""
            if label.isEmpty, link == nil {
                // Text directly in the li, excluding the nested list.
                label = EPUBXMLDocument.collapseWhitespace(children.filter { !document.isElement($0, "ol") }.map { document.textContent(of: $0) }.joined() + directText(of: item, document: document))
            }
            if label.isEmpty, let link, let title = document.attribute("title", of: link) { label = EPUBXMLDocument.collapseWhitespace(title) }
            if label.isEmpty {
                label = EPUBContentsEntry.untitledLabel
                diagnostics.record(.navigation, "nav.emptyLabel", path: basePath, "A table of contents entry has no label.")
            }
            let href = link.flatMap { document.isElement($0, "a") ? document.attribute("href", of: $0) : nil }
            var target: EPUBTarget?
            var unresolved = false
            if let href {
                let reference = EPUBHref.resolve(href, from: basePath, in: zip, diagnostics: &diagnostics)
                if let entry = reference.entry, let spineIndex = package.spineIndex(forPath: entry) {
                    target = EPUBTarget(spineIndex: spineIndex, fragment: reference.fragment)
                } else if let path = reference.path, let spineIndex = package.spineIndex(forPath: path) {
                    target = EPUBTarget(spineIndex: spineIndex, fragment: reference.fragment)
                } else {
                    unresolved = true
                    diagnostics.record(.navigation, "nav.unresolvedTarget", path: href, "A navigation entry points outside the spine.")
                }
            }
            let terms = link.map { EPUBPropertyVocabulary.expandedTerms(document.epubType(of: $0), context: .epubType, declared: prefixes) } ?? []
            let nestedHidden = hidden || (nested.map { document.attribute("hidden", of: $0) != nil } ?? false)
            let childEntries = nested.map { entries(of: $0, document: document, basePath: basePath, package: package, zip: zip, hidden: nestedHidden, prefixes: prefixes, diagnostics: &diagnostics) } ?? []
            result.append(EPUBContentsEntry(label: label, href: href, target: target, isUnresolved: unresolved, isHidden: hidden, source: .navigationDocument, semanticTerms: terms, children: childEntries))
        }
        return result
    }

    private static func directText(of node: EPUBXMLDocument.NodeID, document: EPUBXMLDocument) -> String {
        document.children(of: node).filter { document[$0].isCharacterData }.map { document[$0].text }.joined()
    }

    /// Descendant text with `alt` then `title` for images, whitespace collapsed.
    static func labelText(of node: EPUBXMLDocument.NodeID, document: EPUBXMLDocument) -> String {
        var pieces: [String] = []
        var stack = [node]
        while let next = stack.popLast() {
            let current = document[next]
            if current.isCharacterData { pieces.append(current.text); continue }
            if current.name == "img" {
                if let alternative = document.attribute("alt", of: next) ?? document.attribute("title", of: next) { pieces.append(" " + alternative + " ") }
                continue
            }
            stack.append(contentsOf: current.children.reversed())
        }
        return EPUBXMLDocument.collapseWhitespace(pieces.joined())
    }

    // MARK: NCX

    private struct NCXTables {
        var contents: [EPUBContentsEntry] = []
        var pageList: [EPUBContentsEntry] = []
        var otherLists: [String: [EPUBContentsEntry]] = [:]
    }

    private static func parseNCX(_ document: EPUBXMLDocument, basePath: String, package: EPUBPackageDocument, zip: EPUBZipReader, diagnostics: inout EPUBDiagnosticList) -> NCXTables {
        var tables = NCXTables()
        func resolve(_ src: String?) -> (EPUBTarget?, Bool) {
            guard let src else { return (nil, false) }
            let reference = EPUBHref.resolve(src, from: basePath, in: zip, diagnostics: &diagnostics)
            if let entry = reference.entry ?? reference.path, let index = package.spineIndex(forPath: entry) {
                return (EPUBTarget(spineIndex: index, fragment: reference.fragment), false)
            }
            diagnostics.record(.navigation, "ncx.unresolvedTarget", path: src, "An NCX entry points outside the spine.")
            return (nil, true)
        }
        func label(_ node: EPUBXMLDocument.NodeID) -> String {
            let text = document.firstChildElement(named: "navLabel", of: node).flatMap { document.firstChildElement(named: "text", of: $0) }.map { document.collapsedText(of: $0) } ?? ""
            if text.isEmpty { diagnostics.record(.navigation, "ncx.emptyLabel", path: basePath, "An NCX entry has no label.") }
            return text.isEmpty ? EPUBContentsEntry.untitledLabel : text
        }
        func point(_ node: EPUBXMLDocument.NodeID) -> EPUBContentsEntry {
            let src = document.firstChildElement(named: "content", of: node).flatMap { document.attribute("src", of: $0) }
            if src == nil { diagnostics.record(.navigation, "ncx.missingContent", path: basePath, "An NCX entry has no content element.") }
            let (target, unresolved) = resolve(src)
            let children = document.childElements(of: node).filter { document.isElement($0, "navPoint") }.map(point)
            return EPUBContentsEntry(label: label(node), href: src, target: target, isUnresolved: unresolved, source: .ncx, children: children)
        }
        if let map = document.elements(named: "navMap").first {
            tables.contents = document.childElements(of: map).filter { document.isElement($0, "navPoint") }.map(point)
        }
        if let pageList = document.elements(named: "pageList").first {
            tables.pageList = document.childElements(of: pageList).filter { document.isElement($0, "pageTarget") }.map { node in
                let src = document.firstChildElement(named: "content", of: node).flatMap { document.attribute("src", of: $0) }
                let (target, unresolved) = resolve(src)
                return EPUBContentsEntry(label: label(node), href: src, target: target, isUnresolved: unresolved, source: .ncx,
                                         semanticTerms: document.attribute("type", of: node).map { [$0] } ?? [], pageValue: document.attribute("value", of: node))
            }
        }
        for list in document.elements(named: "navList") {
            let name = document.firstChildElement(named: "navLabel", of: list).flatMap { document.firstChildElement(named: "text", of: $0) }.map { document.collapsedText(of: $0) } ?? "list"
            tables.otherLists[name] = document.childElements(of: list).filter { document.isElement($0, "navTarget") }.map { node in
                let src = document.firstChildElement(named: "content", of: node).flatMap { document.attribute("src", of: $0) }
                let (target, unresolved) = resolve(src)
                return EPUBContentsEntry(label: label(node), href: src, target: target, isUnresolved: unresolved, source: .ncx)
            }
        }
        return tables
    }

    // MARK: Synthetic contents

    /// True when fewer than two entries reach the body (a one-chapter book
    /// needs only one), or every entry sits in one spine item that is not the longest.
    static func needsSyntheticContents(_ contents: [EPUBContentsEntry], package: EPUBPackageDocument, zip: EPUBZipReader) -> Bool {
        let resolvedIndices = contents.flatMap { $0.flattened().compactMap(\.entry.target) }
            .filter { package.spine.indices.contains($0.spineIndex) && package.spine[$0.spineIndex].isLinear }
            .map(\.spineIndex)
        let chapterCount = package.spine.filter { $0.isLinear && $0.kind == .document }.count
        if resolvedIndices.count < min(EPUBNavigationTables.minimumBodyEntries, chapterCount) { return true }
        let distinct = Set(resolvedIndices)
        guard distinct.count == 1, let only = distinct.first else { return false }
        func size(_ item: EPUBSpineItem) -> UInt64 { item.path.flatMap { zip.entry(named: $0)?.uncompressedSize } ?? 0 }
        let longest = package.spine.filter(\.isLinear).max { size($0) < size($1) }
        return longest?.index != only
    }

    static func syntheticContents(package: EPUBPackageDocument, spineText: (EPUBSpineItem) -> (heading: String?, title: String?)) -> [EPUBContentsEntry] {
        let candidates = package.spine.filter { $0.isLinear && $0.kind == .document }
        return candidates.enumerated().map { ordinal, item in
            let text = spineText(item)
            let heading = text.heading.map(EPUBXMLDocument.collapseWhitespace).flatMap { $0.isEmpty ? nil : $0 }
            let title = text.title.map(EPUBXMLDocument.collapseWhitespace).flatMap { $0.isEmpty ? nil : $0 }
            let label = heading ?? title ?? "Section \(ordinal + 1) of \(candidates.count)"
            return EPUBContentsEntry(label: label, target: EPUBTarget(spineIndex: item.index, fragment: nil), source: .synthetic)
        }
    }

    /// The first h1 to h3 and the title of a content document, found with a
    /// lenient scan so a document the XML parser rejects still yields a label.
    static func headingAndTitle(in data: Data) -> (heading: String?, title: String?) {
        if let document = try? EPUBXMLDocument.parse(data), let root = document.documentElement {
            let heading = document.descendantElements(of: root).first { ["h1", "h2", "h3"].contains(document.localName(of: $0)) }.map { document.collapsedText(of: $0) }
            let title = document.elements(named: "title").first.map { document.collapsedText(of: $0) }
            return (heading, title)
        }
        let text = String(decoding: data, as: UTF8.self)
        func capture(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            let stripped = text[range].replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            return EPUBXMLDocument.collapseWhitespace(stripped)
        }
        return (capture("<h[1-3][^>]*>(.*?)</h[1-3]>"), capture("<title[^>]*>(.*?)</title>"))
    }
}
