import Foundation
import libxml2

/// The recovery parser for chapters that are not well-formed XML: libxml2's
/// HTML parser in recover mode, no network, no error output, walked into the
/// same tree model. It knows no namespaces, so `epub:type` arrives as a
/// literal attribute name, which the tree model accepts.
enum EPUBHTMLRecovery {
    private static let options = Int32(HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue | HTML_PARSE_NONET.rawValue)
    private static let encoding = "UTF-8"

    /// Parses `text` as HTML. Nil when libxml2 produced no document element.
    static func parse(_ text: String) -> EPUBXMLDocument? {
        xmlInitParser()
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return nil }
        let document: htmlDocPtr? = bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.flatMap { base in
                base.withMemoryRebound(to: CChar.self, capacity: buffer.count) { pointer in
                    htmlReadMemory(pointer, Int32(buffer.count), nil, encoding, options)
                }
            }
        }
        guard let document else { return nil }
        defer { xmlFreeDoc(document) }
        guard let root = xmlDocGetRootElement(document) else { return nil }
        var nodes: [EPUBXMLDocument.Node] = []
        let rootID = append(root, parent: nil, into: &nodes, depth: 0)
        return rootID.map { EPUBXMLDocument(nodes: nodes, documentElement: $0) }
    }

    private static func append(_ node: xmlNodePtr, parent: EPUBXMLDocument.NodeID?, into nodes: inout [EPUBXMLDocument.Node], depth: Int) -> EPUBXMLDocument.NodeID? {
        guard depth < EPUBXMLDocument.maximumDepth else { return nil }
        switch node.pointee.type {
        case XML_ELEMENT_NODE:
            let name = node.pointee.name.map { String(cString: $0) } ?? ""
            var attributes: [EPUBXMLDocument.Attribute] = []
            var attribute = node.pointee.properties
            while let current = attribute {
                let qualified = current.pointee.name.map { String(cString: $0) } ?? ""
                // Read the attribute's text children directly; xmlNodeGetContent
                // would need xmlFree, a global function pointer strict concurrency rejects.
                var value = ""
                var valueNode = current.pointee.children
                while let text = valueNode {
                    if let content = text.pointee.content { value += String(cString: content) }
                    valueNode = text.pointee.next
                }
                if let colon = qualified.firstIndex(of: ":") {
                    let prefix = String(qualified[..<colon])
                    attributes.append(EPUBXMLDocument.Attribute(namespaceURI: prefix == "xml" ? EPUBNamespace.xml : nil,
                                                                localName: String(qualified[qualified.index(after: colon)...]), qualifiedName: qualified, value: value))
                } else {
                    attributes.append(EPUBXMLDocument.Attribute(namespaceURI: nil, localName: qualified, qualifiedName: qualified, value: value))
                }
                attribute = current.pointee.next
            }
            let id = nodes.count
            nodes.append(EPUBXMLDocument.Node(kind: .element, name: name.lowercased(), namespaceURI: EPUBNamespace.xhtml,
                                              attributes: attributes.sorted { $0.qualifiedName < $1.qualifiedName }, text: "", parent: parent, children: [], utf16Length: 0))
            var child = node.pointee.children
            while let current = child {
                if let childID = append(current, parent: id, into: &nodes, depth: depth + 1) { nodes[id].children.append(childID) }
                child = current.pointee.next
            }
            return id
        case XML_TEXT_NODE, XML_CDATA_SECTION_NODE:
            let text = node.pointee.content.map { String(cString: $0) } ?? ""
            let id = nodes.count
            nodes.append(EPUBXMLDocument.Node(kind: node.pointee.type == XML_CDATA_SECTION_NODE ? .cdata : .text, name: "", namespaceURI: nil,
                                              attributes: [], text: text, parent: parent, children: [], utf16Length: text.utf16.count))
            return id
        default:
            return nil
        }
    }

    /// The last resort: every tag stripped, scripts and styles dropped,
    /// numeric and named references decoded, as one paragraph.
    static func strippedText(_ text: String) -> String {
        var body = text
        for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<head[\\s\\S]*?</head>", "<!--[\\s\\S]*?-->"] {
            body = body.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        // Block tags separate words; inline tags vanish.
        body = body.replacingOccurrences(of: "</?(?:p|div|br|li|h[1-6]|tr|td|th|dd|dt|dl|ul|ol|blockquote|section|article|pre|hr|table|figure|figcaption)\\b[^>]*>", with: " ", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: "<[^>]*>", with: "", options: [.regularExpression])
        return EPUBXMLDocument.collapseWhitespace(decodeReferences(body))
    }

    static func decodeReferences(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&", let semicolon = text[index...].firstIndex(of: ";"), text.distance(from: index, to: semicolon) < 40 else {
                output.append(text[index]); index = text.index(after: index); continue
            }
            let body = text[text.index(after: index)..<semicolon]
            var replacement: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") { replacement = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map(String.init) }
            else if body.hasPrefix("#") { replacement = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map(String.init) }
            else { replacement = EPUBNamedCharacterReferences.table[String(body)] ?? ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'"][String(body)] }
            if let replacement { output += replacement; index = text.index(after: semicolon) }
            else { output.append(text[index]); index = text.index(after: index) }
        }
        return output
    }
}
