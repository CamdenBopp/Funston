import Foundation

/// The structural semantics vocabulary terms the reader acts on, expanded.
enum EPUBSemantics {
    static let structure = EPUBPropertyVocabulary.structuralSemantics
    static let noteReferenceTerms: Set<String> = ["noteref", "biblioref", "glossref"].map { structure + $0 }.reduce(into: []) { $0.insert($1) }
    static let noteBodyTerms: Set<String> = ["footnote", "endnote", "rearnote", "note"].map { structure + $0 }.reduce(into: []) { $0.insert($1) }
    static let notesSectionTerms: Set<String> = ["footnotes", "endnotes", "rearnotes"].map { structure + $0 }.reduce(into: []) { $0.insert($1) }
    static let backlinkTerm = structure + "backlink"
    static let pageBreakTerm = structure + "pagebreak"
    static let titleTerm = structure + "title"
    static let bodymatterTerm = structure + "bodymatter"
    static let frontmatterTerm = structure + "frontmatter"
    static let backmatterTerm = structure + "backmatter"
    static let chapterTerm = structure + "chapter"
    static let partTerm = structure + "part"
    static let tocTerm = structure + "toc"
    static let landmarksTerm = structure + "landmarks"
    static let pageListTerm = structure + "page-list"
    static let z3998 = EPUBPropertyVocabulary.z3998

    /// DPUB-ARIA roles mapped to the structural terms they mean.
    static let roleTerms: [String: String] = [
        "doc-noteref": structure + "noteref", "doc-biblioref": structure + "biblioref", "doc-glossref": structure + "glossref",
        "doc-footnote": structure + "footnote", "doc-endnote": structure + "endnote", "doc-endnotes": structure + "endnotes",
        "doc-footnotes": structure + "footnotes", "doc-backlink": backlinkTerm, "doc-pagebreak": pageBreakTerm,
        "doc-toc": tocTerm, "doc-pagelist": pageListTerm, "doc-chapter": chapterTerm, "doc-part": partTerm,
        "doc-subtitle": structure + "subtitle", "doc-epigraph": structure + "epigraph", "doc-glossary": structure + "glossary",
        "doc-index": structure + "index", "doc-bibliography": structure + "bibliography", "doc-cover": structure + "cover",
        "doc-dedication": structure + "dedication", "doc-colophon": structure + "colophon", "doc-prologue": structure + "prologue",
        "doc-epilogue": structure + "epilogue", "doc-preface": structure + "preface", "doc-foreword": structure + "foreword",
        "doc-introduction": structure + "introduction", "doc-afterword": structure + "afterword", "doc-appendix": structure + "appendix",
        "doc-abstract": structure + "abstract", "doc-acknowledgments": structure + "acknowledgments", "doc-credit": structure + "credit",
        "doc-notice": structure + "notice", "doc-pullquote": structure + "pullquote", "doc-qna": structure + "qna",
        "doc-tip": structure + "tip", "doc-example": structure + "example", "doc-errata": structure + "errata"
    ]
}

/// A parsed chapter: the raw tree plus, per node, the inherited language and
/// direction, the expanded structural semantics and whether the subtree is
/// hidden. CFI steps count over `tree`; the text model walks it; the
/// accessibility layer reads the semantics.
struct EPUBContentDocument: Sendable {
    enum ParserPath: String, Sendable { case xml, htmlRecovered, textOnly, unreadable }
    enum Direction: String, Sendable { case leftToRight = "ltr", rightToLeft = "rtl", auto }

    static let tagSoupDiagnostic = "xml.tagsoup"
    static let textOnlyDiagnostic = "chapter.parse.textOnly"
    static let undecodableDiagnostic = "chapter.decode.undecodable"
    static let unknownEntityDiagnostic = "chapter.parse.unknownEntity"
    static let neverRenderedElements: Set<String> = ["script", "style", "link", "meta", "template", "head", "title", "base"]
    static let pageNumberClasses = ["pageno", "pagenum"]
    static let pageAnchorPrefix = "Page_"

    let path: String
    let tree: EPUBXMLDocument
    let parserPath: ParserPath
    let encodingName: String
    let diagnostics: EPUBDiagnosticList
    let prefixes: [String: String]
    let body: EPUBXMLDocument.NodeID?
    let titleText: String?
    /// Effective language per node.
    let languages: [String?]
    /// Effective base direction per node.
    let directions: [Direction?]
    /// Own `epub:type` terms, expanded.
    let epubTypeTerms: [Set<String>]
    /// Own `role` tokens mapped to structural terms (DPUB-ARIA) or kept raw.
    let roleTerms: [Set<String>]
    /// True when the node or an ancestor hides its subtree.
    let hidden: [Bool]

    var isUnreadable: Bool { parserPath == .unreadable }

    // MARK: Parsing

    static func parse(_ data: Data, path: String, publicationLanguage: String?) -> EPUBContentDocument {
        var diagnostics = EPUBDiagnosticList()
        let decoded: EPUBContentDecoder.Decoded
        do {
            decoded = try EPUBContentDecoder.decode(data, path: path)
        } catch {
            diagnostics.record(.chapterDecode, undecodableDiagnostic, path: path, "The chapter's bytes decode under no known encoding.")
            return EPUBContentDocument(path: path, tree: EPUBXMLDocument(nodes: [], documentElement: nil), parserPath: .unreadable, encodingName: "",
                                       diagnostics: diagnostics, publicationLanguage: publicationLanguage)
        }
        diagnostics.merge(decoded.diagnostics)
        let expanded = EPUBEntityExpansion.expand(decoded.text)
        if expanded.expansionLimited {
            diagnostics.record(.chapterParse, "chapter.parse.entityExpansionLimit", path: path, "A declared entity expands past the cap; it was replaced.")
        }
        if expanded.unknownCount > 0 {
            diagnostics.record(EPUBDiagnostic(stage: .chapterParse, code: unknownEntityDiagnostic, path: path,
                                              message: "Unknown entities (\(expanded.unknownNames.keys.sorted().joined(separator: ", "))) were replaced.", count: expanded.unknownCount))
        }
        var tree: EPUBXMLDocument?
        var parserPath = ParserPath.xml
        do {
            tree = try EPUBXMLDocument.parse(Data(expanded.text.utf8))
        } catch {
            diagnostics.record(.chapterRecover, tagSoupDiagnostic, path: path, "Not well-formed XML (error \(error.code) at line \(error.line), column \(error.column)); recovered as HTML.")
            parserPath = .htmlRecovered
            tree = EPUBHTMLRecovery.parse(expanded.text)
        }
        if tree == nil || tree?.documentElement == nil {
            parserPath = .textOnly
            diagnostics.record(.chapterRecover, textOnlyDiagnostic, path: path, "The chapter could not be parsed; its text is shown as one paragraph.")
            tree = textOnlyTree(EPUBHTMLRecovery.strippedText(expanded.text))
        }
        return EPUBContentDocument(path: path, tree: tree ?? EPUBXMLDocument(nodes: [], documentElement: nil), parserPath: parserPath,
                                   encodingName: decoded.encodingName, diagnostics: diagnostics, publicationLanguage: publicationLanguage)
    }

    static func textOnlyTree(_ text: String) -> EPUBXMLDocument { textOnlyTree(paragraphs: [text]) }

    /// html > body > one `p` per paragraph, each holding one text node.
    static func textOnlyTree(paragraphs: [String]) -> EPUBXMLDocument {
        var nodes: [EPUBXMLDocument.Node] = []
        nodes.append(EPUBXMLDocument.Node(kind: .element, name: "html", namespaceURI: EPUBNamespace.xhtml, attributes: [], text: "", parent: nil, children: [1], utf16Length: 0))
        nodes.append(EPUBXMLDocument.Node(kind: .element, name: "body", namespaceURI: EPUBNamespace.xhtml, attributes: [], text: "", parent: 0, children: [], utf16Length: 0))
        for paragraph in paragraphs {
            let element = nodes.count
            nodes[1].children.append(element)
            nodes.append(EPUBXMLDocument.Node(kind: .element, name: "p", namespaceURI: EPUBNamespace.xhtml, attributes: [], text: "", parent: 1, children: [element + 1], utf16Length: 0))
            nodes.append(EPUBXMLDocument.Node(kind: .text, name: "", namespaceURI: nil, attributes: [], text: paragraph, parent: element, children: [], utf16Length: paragraph.utf16.count))
        }
        return EPUBXMLDocument(nodes: nodes, documentElement: 0)
    }

    /// The document reduced to plain paragraphs: the collapsed text of every block that
    /// holds text directly, and of every run of text between blocks, in document order,
    /// with no attributes and no links. The fallback when styling runs past its budget.
    static func plainText(of document: EPUBContentDocument) -> EPUBContentDocument {
        let tree = document.tree
        var paragraphs: [String] = []
        var loose = ""
        func flush() {
            let text = EPUBXMLDocument.collapseWhitespace(loose).trimmingCharacters(in: .whitespacesAndNewlines)
            loose = ""
            if !text.isEmpty { paragraphs.append(text) }
        }
        func walk(_ id: EPUBXMLDocument.NodeID) {
            let node = tree[id]
            if node.isCharacterData { loose += node.text; return }
            guard node.isElement, !document.hidden[id], !document.isNeverRendered(id) else { return }
            if blockElements.contains(node.name) || id == document.body {
                flush()
                for child in node.children { walk(child) }
                flush()
            } else {
                for child in node.children { walk(child) }
            }
        }
        if let body = document.body { walk(body) }
        return EPUBContentDocument(path: document.path, tree: textOnlyTree(paragraphs: paragraphs), parserPath: .textOnly, encodingName: document.encodingName,
                                   diagnostics: document.diagnostics, publicationLanguage: document.languages.first ?? nil)
    }

    init(path: String, tree: EPUBXMLDocument, parserPath: ParserPath, encodingName: String, diagnostics: EPUBDiagnosticList, publicationLanguage: String?) {
        self.path = path; self.tree = tree; self.parserPath = parserPath; self.encodingName = encodingName; self.diagnostics = diagnostics
        let count = tree.nodes.count
        var languages = [String?](repeating: nil, count: count)
        var directions = [Direction?](repeating: nil, count: count)
        var epubTypes = [Set<String>](repeating: [], count: count)
        var roles = [Set<String>](repeating: [], count: count)
        var hidden = [Bool](repeating: false, count: count)
        var prefixes: [String: String] = [:]
        if let root = tree.documentElement {
            prefixes = EPUBPropertyVocabulary.declaredPrefixes(tree.attribute("prefix", namespace: EPUBNamespace.ops, of: root) ?? tree.attribute(qualified: "epub:prefix", of: root))
        }
        self.prefixes = prefixes
        // Parents precede children in the arena, so one forward pass inherits.
        for id in 0..<count {
            let node = tree.nodes[id]
            let parent = node.parent
            var language = parent.flatMap { languages[$0] } ?? publicationLanguage
            var direction = parent.flatMap { directions[$0] }
            var isHidden = parent.map { hidden[$0] } ?? false
            if node.isElement {
                if let own = tree.language(of: id), !own.isEmpty { language = own }
                if let own = tree.attribute("dir", of: id)?.lowercased(), let parsed = Direction(rawValue: own) { direction = parsed }
                let terms = EPUBPropertyVocabulary.expandedTerms(tree.epubType(of: id), context: .epubType, declared: prefixes)
                epubTypes[id] = terms
                roles[id] = Set(EPUBPropertyVocabulary.tokens(tree.attribute("role", of: id)).map { EPUBSemantics.roleTerms[$0] ?? $0 })
                if Self.hidesSubtree(tree, id) { isHidden = true }
            }
            languages[id] = language
            directions[id] = direction
            hidden[id] = isHidden
        }
        self.languages = languages; self.directions = directions; self.epubTypeTerms = epubTypes; self.roleTerms = roles; self.hidden = hidden
        body = tree.elements(named: "body").first
        titleText = tree.elements(named: "title").first.map { tree.collapsedText(of: $0) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func hidesSubtree(_ tree: EPUBXMLDocument, _ id: EPUBXMLDocument.NodeID) -> Bool {
        if let hidden = tree.attribute("hidden", of: id), hidden.lowercased() != "until-found" { return true }
        if tree.attribute("aria-hidden", of: id)?.lowercased() == "true" { return true }
        if let style = tree.attribute("style", of: id)?.lowercased().replacingOccurrences(of: " ", with: ""),
           style.contains("display:none") || style.contains("visibility:hidden") { return true }
        return false
    }

    // MARK: Semantics

    /// The structural terms that decide behaviour: the role's when it has
    /// any, else the `epub:type` terms (role wins when they disagree).
    func effectiveTerms(of id: EPUBXMLDocument.NodeID) -> Set<String> {
        roleTerms[id].isEmpty ? epubTypeTerms[id] : roleTerms[id]
    }

    func terms(of id: EPUBXMLDocument.NodeID) -> Set<String> { epubTypeTerms[id].union(roleTerms[id]) }

    func isNoteReference(_ id: EPUBXMLDocument.NodeID) -> Bool {
        !effectiveTerms(of: id).isDisjoint(with: EPUBSemantics.noteReferenceTerms)
    }

    func isBacklink(_ id: EPUBXMLDocument.NodeID) -> Bool {
        effectiveTerms(of: id).contains(EPUBSemantics.backlinkTerm)
    }

    func isNoteBody(_ id: EPUBXMLDocument.NodeID) -> Bool {
        !effectiveTerms(of: id).isDisjoint(with: EPUBSemantics.noteBodyTerms)
    }

    func isNotesSection(_ id: EPUBXMLDocument.NodeID) -> Bool {
        !effectiveTerms(of: id).isDisjoint(with: EPUBSemantics.notesSectionTerms)
    }

    /// The page label a page-break marker carries: `aria-label` or `title`
    /// for the vocabulary forms, `title` or text for Gutenberg's `span.pageno`,
    /// and the number after `Page_` for anchors.
    func pageBreakLabel(of id: EPUBXMLDocument.NodeID) -> String? {
        let node = tree[id]
        guard node.isElement else { return nil }
        if effectiveTerms(of: id).contains(EPUBSemantics.pageBreakTerm) {
            let label = tree.attribute("aria-label", of: id) ?? tree.attribute("title", of: id) ?? tree.collapsedText(of: id)
            return label.isEmpty ? nil : label
        }
        let classes = EPUBPropertyVocabulary.tokens(tree.attribute("class", of: id))
        if classes.contains(where: { Self.pageNumberClasses.contains($0) }) {
            let label = tree.attribute("title", of: id) ?? tree.collapsedText(of: id)
            return label.isEmpty ? nil : label
        }
        if node.name == "a", let anchor = tree.id(of: id), anchor.hasPrefix(Self.pageAnchorPrefix), tree.collapsedText(of: id).isEmpty {
            let label = anchor.dropFirst(Self.pageAnchorPrefix.count).replacingOccurrences(of: "_", with: " ")
            return label.isEmpty ? nil : label
        }
        return nil
    }

    /// Elements the renderer never shows, by name.
    func isNeverRendered(_ id: EPUBXMLDocument.NodeID) -> Bool {
        Self.neverRenderedElements.contains(tree[id].name)
    }

    func classes(of id: EPUBXMLDocument.NodeID) -> [String] {
        EPUBPropertyVocabulary.tokens(tree.attribute("class", of: id))
    }

    /// The nearest ancestor-or-self that is a block-level element, for note
    /// bodies whose target is an inline anchor.
    static let blockElements: Set<String> = ["p", "div", "section", "article", "aside", "li", "dd", "dt", "blockquote", "figure", "figcaption", "pre",
                                             "h1", "h2", "h3", "h4", "h5", "h6", "td", "th", "tr", "table", "ul", "ol", "dl", "header", "footer", "main", "nav", "body", "center", "hr"]

    func nearestBlock(from id: EPUBXMLDocument.NodeID) -> EPUBXMLDocument.NodeID? {
        var current: EPUBXMLDocument.NodeID? = id
        while let node = current {
            if tree[node].isElement, Self.blockElements.contains(tree[node].name) { return node }
            current = tree[node].parent
        }
        return nil
    }
}
