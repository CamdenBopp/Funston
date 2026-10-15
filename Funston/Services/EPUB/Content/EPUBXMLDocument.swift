import Foundation

/// The XML and XHTML namespaces the package and content documents use.
enum EPUBNamespace {
    static let xml = "http://www.w3.org/XML/1998/namespace"
    static let xhtml = "http://www.w3.org/1999/xhtml"
    static let svg = "http://www.w3.org/2000/svg"
    static let mathML = "http://www.w3.org/1998/Math/MathML"
    static let opf = "http://www.idpf.org/2007/opf"
    static let dublinCore = "http://purl.org/dc/elements/1.1/"
    static let ops = "http://www.idpf.org/2007/ops"
    static let container = "urn:oasis:names:tc:opendocument:xmlns:container"
    static let ncx = "http://www.daisy.org/z3986/2005/ncx/"
    static let smil = "http://www.w3.org/ns/SMIL"
    static let xmlEncryption = "http://www.w3.org/2001/04/xmlenc#"
    static let xmlSignature = "http://www.w3.org/2000/09/xmldsig#"
    static let adept = "http://ns.adobe.com/adept"
    static let xlink = "http://www.w3.org/1999/xlink"
}

/// A parsed XML document kept as an index-addressed tree so it is a plain
/// `Sendable` value with parent links. The child sequence is exactly what the
/// parser delivered: whitespace-only text stays, CDATA is character data,
/// comments and processing instructions are dropped. CFI steps count over this
/// tree, so nothing here is trimmed, collapsed or merged across elements.
struct EPUBXMLDocument: Sendable, Hashable {
    typealias NodeID = Int

    struct Attribute: Sendable, Hashable {
        let namespaceURI: String?
        let localName: String
        /// The name as written, such as `epub:type`; the HTML recovery parser
        /// delivers only this form, so it is matched too.
        let qualifiedName: String
        let value: String
    }

    enum Kind: Sendable, Hashable { case element, text, cdata }

    struct Node: Sendable, Hashable {
        let kind: Kind
        /// The local name of an element; empty for character data.
        let name: String
        let namespaceURI: String?
        let attributes: [Attribute]
        /// Character data; empty for elements.
        let text: String
        let parent: NodeID?
        var children: [NodeID]
        /// The UTF-16 length of character data, cached because CFI offsets count it.
        let utf16Length: Int

        var isElement: Bool { kind == .element }
        var isCharacterData: Bool { kind != .element }
    }

    struct ParseFailure: Error, Hashable {
        let code: Int
        let line: Int
        let column: Int
        let message: String
    }

    /// A hostile document can nest without end; the parser stops before the stack does.
    static let maximumDepth = 512

    private(set) var nodes: [Node]
    let documentElement: NodeID?
    /// Internal subset entity names the document declared, so a pre-expansion
    /// pass can leave them to the parser.
    let declaredEntities: Set<String>

    init(nodes: [Node], documentElement: NodeID?, declaredEntities: Set<String> = []) {
        self.nodes = nodes; self.documentElement = documentElement; self.declaredEntities = declaredEntities
    }

    // MARK: Parsing

    /// Parses bytes with Foundation's XMLParser: namespaces on, external
    /// entities never resolved, never given a URL.
    static func parse(_ data: Data) throws(ParseFailure) -> EPUBXMLDocument {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        let builder = Builder()
        parser.delegate = builder
        let succeeded = parser.parse()
        if !succeeded || builder.depthExceeded {
            let error = parser.parserError as NSError?
            if builder.depthExceeded {
                throw ParseFailure(code: -1, line: parser.lineNumber, column: parser.columnNumber, message: "The document nests deeper than \(maximumDepth) elements.")
            }
            throw ParseFailure(code: error?.code ?? -1, line: parser.lineNumber, column: parser.columnNumber,
                               message: error?.localizedDescription ?? "The document is not well-formed XML.")
        }
        guard let root = builder.documentElement else {
            throw ParseFailure(code: -1, line: parser.lineNumber, column: parser.columnNumber, message: "The document has no element.")
        }
        return EPUBXMLDocument(nodes: builder.nodes, documentElement: root, declaredEntities: builder.declaredEntities)
    }

    /// Collects nodes from the SAX stream. Consecutive text deliveries of one
    /// run are joined into one node (the parser splits long runs at buffer
    /// boundaries and at entity references, which no CFI rule distinguishes);
    /// CDATA stays its own node.
    private final class Builder: NSObject, XMLParserDelegate {
        var nodes: [Node] = []
        var documentElement: NodeID?
        var declaredEntities: Set<String> = []
        var depthExceeded = false
        private var stack: [NodeID] = []
        private var pendingText = ""
        private var pendingIsCDATA = false
        private var hasPending = false
        private var prefixScopes: [[String: String]] = [[:]]
        private var pendingPrefixes: [String: String] = [:]

        private func flushText() {
            guard hasPending, let parent = stack.last else { hasPending = false; pendingText = ""; return }
            let id = nodes.count
            nodes.append(Node(kind: pendingIsCDATA ? .cdata : .text, name: "", namespaceURI: nil, attributes: [], text: pendingText,
                              parent: parent, children: [], utf16Length: pendingText.utf16.count))
            nodes[parent].children.append(id)
            hasPending = false; pendingText = ""; pendingIsCDATA = false
        }

        private func appendCharacters(_ string: String, cdata: Bool) {
            guard !stack.isEmpty else { return }
            if hasPending, pendingIsCDATA != cdata { flushText() }
            if cdata, hasPending { flushText() }
            pendingText += string
            pendingIsCDATA = cdata
            hasPending = true
            if cdata { flushText() }
        }

        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
            pendingPrefixes[prefix] = namespaceURI
        }

        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {}

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            guard !depthExceeded else { return }
            flushText()
            if stack.count >= maximumDepth {
                depthExceeded = true
                parser.abortParsing()
                return
            }
            var scope = prefixScopes.last ?? [:]
            for (prefix, uri) in pendingPrefixes { scope[prefix] = uri }
            pendingPrefixes = [:]
            prefixScopes.append(scope)
            let attributes = attributeDict.map { qualified, value -> Attribute in
                if let colon = qualified.firstIndex(of: ":") {
                    let prefix = String(qualified[..<colon]), local = String(qualified[qualified.index(after: colon)...])
                    let uri = prefix == "xml" ? EPUBNamespace.xml : scope[prefix]
                    return Attribute(namespaceURI: uri, localName: local, qualifiedName: qualified, value: value)
                }
                return Attribute(namespaceURI: nil, localName: qualified, qualifiedName: qualified, value: value)
            }.sorted { $0.qualifiedName < $1.qualifiedName }
            let id = nodes.count
            let parent = stack.last
            nodes.append(Node(kind: .element, name: elementName, namespaceURI: namespaceURI.flatMap { $0.isEmpty ? nil : $0 },
                              attributes: attributes, text: "", parent: parent, children: [], utf16Length: 0))
            if let parent { nodes[parent].children.append(id) } else if documentElement == nil { documentElement = id }
            stack.append(id)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            flushText()
            if !stack.isEmpty { stack.removeLast() }
            if prefixScopes.count > 1 { prefixScopes.removeLast() }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { appendCharacters(string, cdata: false) }
        func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) { appendCharacters(whitespaceString, cdata: false) }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            appendCharacters(String(decoding: CDATABlock, as: UTF8.self), cdata: true)
        }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            declaredEntities.insert(name)
        }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
    }

    // MARK: Access

    subscript(_ id: NodeID) -> Node { nodes[id] }

    func parent(of id: NodeID) -> NodeID? { nodes[id].parent }
    func children(of id: NodeID) -> [NodeID] { nodes[id].children }
    func childElements(of id: NodeID) -> [NodeID] { nodes[id].children.filter { nodes[$0].isElement } }
    func localName(of id: NodeID) -> String { nodes[id].name }
    func namespace(of id: NodeID) -> String? { nodes[id].namespaceURI }

    func isElement(_ id: NodeID, _ local: String, namespace: String? = nil) -> Bool {
        let node = nodes[id]
        guard node.isElement, node.name == local else { return false }
        return namespace == nil || node.namespaceURI == namespace
    }

    /// The attribute with the given local name in the given namespace (`nil`
    /// means no namespace). When `namespace` is `nil` and nothing matches, an
    /// attribute with that local name in any namespace is accepted, which is
    /// how `opf:role` written without its prefix still reads.
    func attribute(_ local: String, namespace: String? = nil, of id: NodeID) -> String? {
        let attributes = nodes[id].attributes
        if let exact = attributes.first(where: { $0.localName == local && $0.namespaceURI == namespace }) { return exact.value }
        guard namespace == nil else { return nil }
        return attributes.first { $0.localName == local }?.value
    }

    func attribute(qualified name: String, of id: NodeID) -> String? {
        nodes[id].attributes.first { $0.qualifiedName == name }?.value
    }

    /// `epub:type`, accepted by namespace or by its literal qualified name,
    /// because the HTML recovery parser knows no namespaces.
    func epubType(of id: NodeID) -> String? {
        attribute("type", namespace: EPUBNamespace.ops, of: id) ?? attribute(qualified: "epub:type", of: id)
    }

    func id(of node: NodeID) -> String? {
        attribute("id", of: node)
    }

    /// `xml:lang` then `lang`.
    func language(of id: NodeID) -> String? {
        attribute("lang", namespace: EPUBNamespace.xml, of: id) ?? attribute(qualified: "xml:lang", of: id) ?? attribute("lang", of: id)
    }

    /// Descendant elements in document order, the subtree root excluded.
    func descendantElements(of id: NodeID) -> [NodeID] {
        var result: [NodeID] = []
        var stack = Array(nodes[id].children.reversed())
        while let next = stack.popLast() {
            let node = nodes[next]
            guard node.isElement else { continue }
            result.append(next)
            stack.append(contentsOf: node.children.reversed())
        }
        return result
    }

    func descendantElements(named local: String, namespace: String? = nil, of id: NodeID) -> [NodeID] {
        descendantElements(of: id).filter { isElement($0, local, namespace: namespace) }
    }

    func firstChildElement(named local: String, namespace: String? = nil, of id: NodeID) -> NodeID? {
        childElements(of: id).first { isElement($0, local, namespace: namespace) }
    }

    func elements(named local: String, namespace: String? = nil) -> [NodeID] {
        guard let root = documentElement else { return [] }
        var all = descendantElements(named: local, namespace: namespace, of: root)
        if isElement(root, local, namespace: namespace) { all.insert(root, at: 0) }
        return all
    }

    func element(withID wanted: String) -> NodeID? {
        guard let root = documentElement else { return nil }
        if id(of: root) == wanted { return root }
        return descendantElements(of: root).first { id(of: $0) == wanted }
    }

    /// The concatenated character data under a node, exactly as written.
    func textContent(of id: NodeID) -> String {
        var result = ""
        var stack = [id]
        while let next = stack.popLast() {
            let node = nodes[next]
            if node.isCharacterData { result += node.text } else { stack.append(contentsOf: node.children.reversed()) }
        }
        return result
    }

    /// Text with ASCII whitespace runs collapsed to one space and the ends trimmed.
    func collapsedText(of id: NodeID) -> String {
        Self.collapseWhitespace(textContent(of: id))
    }

    static func collapseWhitespace(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{0C}" {
                pendingSpace = !result.isEmpty
            } else {
                if pendingSpace { result.append(" "); pendingSpace = false }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Ancestors from the parent up to the document element.
    func ancestors(of id: NodeID) -> [NodeID] {
        var result: [NodeID] = []
        var current = nodes[id].parent
        while let next = current { result.append(next); current = nodes[next].parent }
        return result
    }
}
