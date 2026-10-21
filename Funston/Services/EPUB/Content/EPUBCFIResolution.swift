import Foundation

/// A point in the raw tree, as CFI generation and resolution see it.
enum EPUBSourcePosition: Sendable, Hashable {
    /// The element itself, an even step with no offset.
    case element(EPUBXMLDocument.NodeID)
    /// Inside character data, a UTF-16 offset within that node.
    case text(node: EPUBXMLDocument.NodeID, offset: Int)
    /// Between the children of `parent`: before the child at `childIndex`,
    /// or after the last child when `childIndex` equals the child count.
    case boundary(parent: EPUBXMLDocument.NodeID, childIndex: Int)
}

/// The CFI child indexing of one element (CFI 1.1 section 3.1.1): the virtual
/// position 0, then character-data chunks at odd indices and element children
/// at even indices from 2, with an empty chunk between adjacent elements and
/// always one before the first and after the last, then the virtual position
/// after everything. Adjacent text and CDATA nodes form one chunk; comments
/// and processing instructions were never in the tree.
struct EPUBCFIChildList: Sendable {
    enum Entry: Sendable, Hashable {
        case virtualBefore
        case chunk([EPUBXMLDocument.NodeID])
        case element(EPUBXMLDocument.NodeID)
        case virtualAfter
    }

    let entries: [Entry]

    init(of element: EPUBXMLDocument.NodeID, in tree: EPUBXMLDocument) {
        var entries: [Entry] = [.virtualBefore]
        var pendingChunk: [EPUBXMLDocument.NodeID]?
        for child in tree.children(of: element) {
            let node = tree[child]
            if node.isCharacterData {
                pendingChunk = (pendingChunk ?? []) + [child]
            } else {
                entries.append(.chunk(pendingChunk ?? []))
                pendingChunk = nil
                entries.append(.element(child))
            }
        }
        entries.append(.chunk(pendingChunk ?? []))
        entries.append(.virtualAfter)
        self.entries = entries
    }

    var lastIndex: Int { entries.count - 1 }

    /// The step index of an element child.
    func index(ofElement child: EPUBXMLDocument.NodeID) -> Int? {
        entries.firstIndex { if case .element(let id) = $0 { return id == child } else { return false } }
    }

    /// The step index of the chunk containing a character-data child, with
    /// the UTF-16 length of the members before it.
    func chunk(containing child: EPUBXMLDocument.NodeID, in tree: EPUBXMLDocument) -> (index: Int, precedingLength: Int)? {
        for (index, entry) in entries.enumerated() {
            guard case .chunk(let members) = entry, let position = members.firstIndex(of: child) else { continue }
            return (index, members[..<position].reduce(0) { $0 + tree[$1].utf16Length })
        }
        return nil
    }

    func chunkLength(_ members: [EPUBXMLDocument.NodeID], in tree: EPUBXMLDocument) -> Int {
        members.reduce(0) { $0 + tree[$1].utf16Length }
    }
}

/// Builds CFIs over the raw tree and the real package document.
enum EPUBCFIGenerator {
    /// The package level: the spine element's step and the itemref's step with its id.
    static func packageLevel(package: EPUBPackageDocument, spineIndex: Int) -> EPUBCFI.Level? {
        guard package.spine.indices.contains(spineIndex) else { return nil }
        let item = package.spine[spineIndex]
        return EPUBCFI.Level(steps: [EPUBCFI.Step(index: package.spineCFIStep), EPUBCFI.Step(index: item.cfiStep, id: item.id)])
    }

    /// The document path to a position, with id assertions on every element
    /// that has one and a text assertion at a character offset.
    static func documentPath(to position: EPUBSourcePosition, in tree: EPUBXMLDocument, withTextAssertion: Bool = true) -> EPUBCFI.Path? {
        var steps: [EPUBCFI.Step] = []
        var offset: EPUBCFI.Offset?
        var node: EPUBXMLDocument.NodeID
        switch normalised(position, in: tree) {
        case .element(let element):
            node = element
        case .text(let textNode, let textOffset):
            guard let parent = tree.parent(of: textNode) else { return nil }
            let list = EPUBCFIChildList(of: parent, in: tree)
            guard let chunk = list.chunk(containing: textNode, in: tree) else { return nil }
            steps.append(EPUBCFI.Step(index: chunk.index))
            offset = EPUBCFI.Offset(character: chunk.precedingLength + textOffset,
                                    textAssertion: withTextAssertion ? textAssertion(at: .text(node: textNode, offset: textOffset), in: tree) : nil)
            node = parent
        case .boundary(let parent, let childIndex):
            let list = EPUBCFIChildList(of: parent, in: tree)
            let children = tree.children(of: parent)
            // Normalisation failed to find an element or text here: an empty chunk.
            var chunkIndex = list.lastIndex - 1
            if childIndex < children.count, let elementIndex = list.index(ofElement: children[childIndex]) { chunkIndex = elementIndex - 1 }
            steps.append(EPUBCFI.Step(index: chunkIndex))
            offset = EPUBCFI.Offset(character: 0)
            node = parent
        }
        while let parent = tree.parent(of: node) {
            let list = EPUBCFIChildList(of: parent, in: tree)
            guard let index = list.index(ofElement: node) else { return nil }
            steps.insert(EPUBCFI.Step(index: index, id: tree.id(of: node)), at: 0)
            node = parent
        }
        return EPUBCFI.Path(levels: [EPUBCFI.Level(steps: steps)], offset: offset)
    }

    /// A boundary before an element becomes that element's step; before
    /// character data, the chunk at that node's start (EJS-06).
    static func normalised(_ position: EPUBSourcePosition, in tree: EPUBXMLDocument) -> EPUBSourcePosition {
        guard case .boundary(let parent, let childIndex) = position else { return position }
        let children = tree.children(of: parent)
        if childIndex < children.count {
            let child = children[childIndex]
            return tree[child].isElement ? .element(child) : .text(node: child, offset: 0)
        }
        if let last = children.last, tree[last].isCharacterData {
            return .text(node: last, offset: tree[last].utf16Length)
        }
        return position
    }

    /// The full CFI for a position in a spine item.
    static func cfi(for position: EPUBSourcePosition, in tree: EPUBXMLDocument, package: EPUBPackageDocument, spineIndex: Int) -> EPUBCFI? {
        guard let level = packageLevel(package: package, spineIndex: spineIndex), let document = documentPath(to: position, in: tree) else { return nil }
        return EPUBCFI(path: EPUBCFI.Path(levels: [level] + document.levels, offset: document.offset))
    }

    /// A range: the longest common step prefix is the parent path.
    static func range(from start: EPUBSourcePosition, to end: EPUBSourcePosition, in tree: EPUBXMLDocument, packageLevel: EPUBCFI.Level?) -> EPUBCFI? {
        guard let startPath = documentPath(to: start, in: tree, withTextAssertion: false),
              let endPath = documentPath(to: end, in: tree, withTextAssertion: false),
              let startSteps = startPath.levels.first?.steps, let endSteps = endPath.levels.first?.steps else { return nil }
        if startPath == endPath {
            let levels = (packageLevel.map { [$0] } ?? []) + startPath.levels
            return EPUBCFI(path: EPUBCFI.Path(levels: levels, offset: startPath.offset))
        }
        var common = 0
        while common < startSteps.count, common < endSteps.count, startSteps[common].index == endSteps[common].index, startSteps[common].id == endSteps[common].id {
            common += 1
        }
        let parentSteps = Array(startSteps[..<common])
        let parent = EPUBCFI.Path(levels: (packageLevel.map { [$0] } ?? []) + [EPUBCFI.Level(steps: parentSteps)])
        let startLocal = EPUBCFI.Path(levels: [EPUBCFI.Level(steps: Array(startSteps[common...]))], offset: startPath.offset)
        let endLocal = EPUBCFI.Path(levels: [EPUBCFI.Level(steps: Array(endSteps[common...]))], offset: endPath.offset)
        return EPUBCFI(parent: parent, start: startLocal, end: endLocal)
    }

    /// Up to 32 collapsed characters each side of the point, element
    /// boundaries ignored.
    static func textAssertion(at position: EPUBSourcePosition, in tree: EPUBXMLDocument) -> EPUBCFI.TextAssertion? {
        guard let (before, after) = context(around: position, in: tree, length: EPUBCFI.textAssertionLength) else { return nil }
        if before.isEmpty && after.isEmpty { return nil }
        return EPUBCFI.TextAssertion(before: before.isEmpty ? nil : before, after: after)
    }

    /// Collapsed text before and after a position across the whole document.
    static func context(around position: EPUBSourcePosition, in tree: EPUBXMLDocument, length: Int) -> (String, String)? {
        let order = EPUBCFIFollower.characterDataNodes(in: tree)
        var before = "", after = ""
        switch position {
        case .text(let node, let offset):
            guard let index = order.firstIndex(of: node) else { return nil }
            let text = tree[node].text
            let split = String.Index(utf16Offset: min(offset, text.utf16.count), in: text)
            before = String(text[..<split]); after = String(text[split...])
            var earlier = index - 1
            while before.count < length * 2, earlier >= 0 { before = tree[order[earlier]].text + before; earlier -= 1 }
            var later = index + 1
            while after.count < length * 2, later < order.count { after += tree[order[later]].text; later += 1 }
        case .element(let element):
            let descendants = EPUBCFIFollower.characterDataNodes(in: tree, under: element)
            let first = descendants.first.flatMap { order.firstIndex(of: $0) } ?? order.firstIndex { tree[$0].parent.map { tree.ancestors(of: $0).contains(element) } ?? false }
            guard let first else { return nil }
            var earlier = first - 1
            while before.count < length * 2, earlier >= 0 { before = tree[order[earlier]].text + before; earlier -= 1 }
            var later = first
            while after.count < length * 2, later < order.count { after += tree[order[later]].text; later += 1 }
        case .boundary:
            return nil
        }
        let collapsedBefore = collapseKeepingEdges(before)
        let collapsedAfter = collapseKeepingEdges(after)
        return (String(collapsedBefore.suffix(length)), String(collapsedAfter.prefix(length)))
    }

    /// Whitespace runs become one space; a space at either edge stays,
    /// because the point may sit at a word boundary.
    static func collapseKeepingEdges(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{0C}" {
                pendingSpace = true
            } else {
                if pendingSpace { result.append(" "); pendingSpace = false }
                result.unicodeScalars.append(scalar)
            }
        }
        if pendingSpace { result.append(" ") }
        return result
    }
}

/// What a resolution produced, with every correction recorded.
struct EPUBCFIResolution: Sendable, Hashable {
    var position: EPUBSourcePosition
    /// An id assertion disagreed with the index and the id won.
    var correctedByID = false
    /// An asserted id was absent and the index was used instead.
    var partial = false
    var textAssertionMismatch = false
    /// The character offset overflowed its chunk and was carried into later text.
    var offsetCarried = false
    var temporal: Double?
    var spatial: EPUBCFI.SpatialPoint?
}

struct EPUBCFIResolveFailure: Error, Hashable {
    /// The index of the failing step within the document level, or nil for the level itself.
    let step: Int?
    let reason: String
}

/// Resolves CFIs against the package document and a chapter's raw tree with
/// intent-preserving correction (CFI 1.1 section 3.5), falling back to the
/// index when an asserted id is absent instead of refusing.
enum EPUBCFIFollower {
    struct SpineResolution: Sendable, Hashable {
        let spineIndex: Int
        let correctedByID: Bool
        let idDropped: Bool
    }

    /// The spine item a CFI's package level names.
    static func spineIndex(of cfi: EPUBCFI, in package: EPUBPackageDocument) -> SpineResolution? {
        guard let level = cfi.packageLevel, level.steps.count >= 2 else { return nil }
        let itemrefStep = level.steps[1]
        var idDropped = false
        if let id = itemrefStep.id {
            if let index = package.spine.firstIndex(where: { $0.id == id }) {
                let corrected = level.steps[0].index != package.spineCFIStep || package.spine[index].cfiStep != itemrefStep.index
                return SpineResolution(spineIndex: index, correctedByID: corrected, idDropped: false)
            }
            idDropped = true
        }
        guard level.steps[0].index == package.spineCFIStep, itemrefStep.index % 2 == 0 else { return nil }
        let index = itemrefStep.index / 2 - 1
        guard package.spine.indices.contains(index) else { return nil }
        return SpineResolution(spineIndex: index, correctedByID: false, idDropped: idDropped)
    }

    /// Resolves the document part of a path. Only the first document level is
    /// followed; an indirection into an embedded document is reported.
    static func resolve(_ path: EPUBCFI.Path, in tree: EPUBXMLDocument) -> Result<EPUBCFIResolution, EPUBCFIResolveFailure> {
        guard let root = tree.documentElement else { return .failure(EPUBCFIResolveFailure(step: nil, reason: "empty document")) }
        guard let level = path.levels.first else { return .failure(EPUBCFIResolveFailure(step: nil, reason: "no steps")) }
        if path.levels.count > 1 { return .failure(EPUBCFIResolveFailure(step: level.steps.count, reason: "indirection into an embedded document is not followed")) }
        var resolution = EPUBCFIResolution(position: .element(root))
        resolution.temporal = path.offset?.temporal
        resolution.spatial = path.offset?.spatial
        var node = root
        for (stepIndex, step) in level.steps.enumerated() {
            let list = EPUBCFIChildList(of: node, in: tree)
            let isLast = stepIndex == level.steps.count - 1
            var entry: EPUBCFIChildList.Entry? = list.entries.indices.contains(step.index) ? list.entries[step.index] : nil
            if let id = step.id {
                if case .element(let candidate) = entry, tree.id(of: candidate) == id {
                    // The index and the id agree.
                } else if let found = tree.element(withID: id) {
                    entry = .element(found)
                    resolution.correctedByID = true
                } else if entry != nil {
                    resolution.partial = true
                } else {
                    return .failure(EPUBCFIResolveFailure(step: stepIndex, reason: "index out of range and id \(id) not found"))
                }
            }
            guard let entry else { return .failure(EPUBCFIResolveFailure(step: stepIndex, reason: "index \(step.index) out of range")) }
            switch entry {
            case .virtualBefore:
                guard isLast else { return .failure(EPUBCFIResolveFailure(step: stepIndex, reason: "virtual position is not last")) }
                resolution.position = .boundary(parent: node, childIndex: 0)
            case .virtualAfter:
                guard isLast else { return .failure(EPUBCFIResolveFailure(step: stepIndex, reason: "virtual position is not last")) }
                resolution.position = .boundary(parent: node, childIndex: tree.children(of: node).count)
            case .element(let child):
                node = child
                resolution.position = .element(child)
            case .chunk(let members):
                guard isLast else { return .failure(EPUBCFIResolveFailure(step: stepIndex, reason: "a chunk step must be last")) }
                let offset = path.offset?.character ?? 0
                resolution.position = position(inChunk: members, at: step.index, of: node, offset: offset, in: tree, carried: &resolution.offsetCarried)
            }
        }
        if let assertion = path.offset?.textAssertion, let (before, after) = EPUBCFIGenerator.context(around: resolution.position, in: tree, length: EPUBCFI.textAssertionLength) {
            if let expectedBefore = assertion.before, !before.hasSuffix(expectedBefore) { resolution.textAssertionMismatch = true }
            if let expectedAfter = assertion.after, !after.hasPrefix(expectedAfter) { resolution.textAssertionMismatch = true }
        }
        return .success(resolution)
    }

    /// The position `offset` code units into a chunk; a boundary goes to the
    /// earlier member; an overflow is carried into the following text.
    private static func position(inChunk members: [EPUBXMLDocument.NodeID], at chunkIndex: Int, of parent: EPUBXMLDocument.NodeID, offset: Int, in tree: EPUBXMLDocument, carried: inout Bool) -> EPUBSourcePosition {
        var remaining = offset
        for member in members {
            let length = tree[member].utf16Length
            if remaining <= length { return .text(node: member, offset: remaining) }
            remaining -= length
        }
        if members.isEmpty, offset == 0 {
            // An empty chunk: the point between its neighbouring elements.
            let list = EPUBCFIChildList(of: parent, in: tree)
            let children = tree.children(of: parent)
            if chunkIndex + 1 < list.entries.count, case .element(let next) = list.entries[chunkIndex + 1], let childIndex = children.firstIndex(of: next) {
                return .boundary(parent: parent, childIndex: childIndex)
            }
            return .boundary(parent: parent, childIndex: children.count)
        }
        // Carry the surplus forward through the document's later text.
        carried = true
        let order = characterDataNodes(in: tree)
        let startIndex: Int
        if let last = members.last, let index = order.firstIndex(of: last) {
            startIndex = index + 1
        } else {
            // An empty chunk with an offset: continue from the next character data after the parent's chunk position.
            let later = tree.children(of: parent).dropFirst(max(0, chunkIndex / 2)).flatMap { characterDataNodes(in: tree, under: $0, includingSelf: true) }
            startIndex = later.first.flatMap { order.firstIndex(of: $0) } ?? order.count
        }
        for index in startIndex..<order.count {
            let length = tree[order[index]].utf16Length
            if remaining <= length { return .text(node: order[index], offset: remaining) }
            remaining -= length
        }
        if let last = order.last { return .text(node: last, offset: tree[last].utf16Length) }
        return .boundary(parent: parent, childIndex: tree.children(of: parent).count)
    }

    /// Every character-data node in document order.
    static func characterDataNodes(in tree: EPUBXMLDocument) -> [EPUBXMLDocument.NodeID] {
        guard let root = tree.documentElement else { return [] }
        return characterDataNodes(in: tree, under: root)
    }

    static func characterDataNodes(in tree: EPUBXMLDocument, under node: EPUBXMLDocument.NodeID, includingSelf: Bool = false) -> [EPUBXMLDocument.NodeID] {
        var result: [EPUBXMLDocument.NodeID] = []
        var stack = includingSelf ? [node] : Array(tree.children(of: node).reversed())
        while let next = stack.popLast() {
            let current = tree[next]
            if current.isCharacterData { result.append(next) } else { stack.append(contentsOf: current.children.reversed()) }
        }
        return result
    }
}
