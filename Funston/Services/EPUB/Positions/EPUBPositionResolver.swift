import Foundation

/// Where a stored position lands after restoring (Spec 12.2).
struct EPUBRestoredPosition: Sendable, Hashable {
    enum Method: String, Sendable, Hashable {
        case offset, cfi, text, approximateText, fragment, selector, progression, totalProgression, start
    }

    let spineIndex: Int
    /// The rendered offset in the chapter when one was found; nil means "the chapter's fraction".
    let offset: Int?
    let progression: Double
    let method: Method
    /// Every fallback taken before the one that worked.
    let fallbacks: [Method]

    /// True when the reader had to fall past the CFI and should say "approximate position" once.
    var isApproximate: Bool {
        switch method {
        case .offset, .cfi, .fragment, .selector, .start: return false
        case .text, .approximateText, .progression, .totalProgression: return true
        }
    }
}

/// Finds a stored text context in rendered text (RDN-52 scoring).
enum EPUBTextAnchor {
    static let matchWeight = 0.5
    static let beforeWeight = 0.2
    static let afterWeight = 0.2
    static let proximityWeight = 0.02
    /// The best approximate candidate needs at least this score.
    static let acceptanceThreshold = 0.6
    /// Candidates are seeded by this many leading characters of the stored text.
    static let seedLength = 12

    /// The rendered offset where `after` begins, preceded by `before`.
    static func find(before: String?, after: String?, highlight: String? = nil, in rendered: String, hint: Int?) -> (offset: Int, exact: Bool)? {
        let needle = (after?.isEmpty == false ? after : highlight?.isEmpty == false ? highlight : nil).map(EPUBXMLDocument.collapseWhitespace)
        let beforeText = before.map(EPUBXMLDocument.collapseWhitespace)
        let haystack = rendered as NSString
        /// The collapsed text just before an offset, as long as the stored before.
        func preceding(_ offset: Int) -> String {
            guard let beforeText else { return "" }
            // Collapsing can shorten the stored text, so read a little more than its length.
            let length = min(offset, beforeText.utf16.count * 2 + 8)
            let collapsed = EPUBXMLDocument.collapseWhitespace(haystack.substring(with: NSRange(location: offset - length, length: length)))
            return String(collapsed.suffix(beforeText.count))
        }
        if let needle, !needle.isEmpty {
            // Exact: every occurrence, preferring one whose preceding text ends with `before`, then the one nearest the hint.
            var exact: [Int] = []
            var search = NSRange(location: 0, length: haystack.length)
            while search.length > 0 {
                let found = haystack.range(of: needle, options: [], range: search)
                guard found.location != NSNotFound else { break }
                exact.append(found.location)
                search = NSRange(location: found.location + 1, length: haystack.length - found.location - 1)
            }
            if !exact.isEmpty {
                let preferred = exact.filter { offset in
                    guard let beforeText, !beforeText.isEmpty else { return true }
                    return preceding(offset).hasSuffix(beforeText)
                }
                let pool = preferred.isEmpty ? exact : preferred
                let hinted = hint ?? 0
                return (pool.min { abs($0 - hinted) < abs($1 - hinted) } ?? pool[0], true)
            }
            // Approximate: candidates where any seed-length slice of the needle occurs, scored 50/20/20 plus proximity.
            var candidates = Set<Int>()
            let needleLength = needle.utf16.count
            for seedStart in stride(from: 0, to: needleLength, by: seedLength) {
                let seed = (needle as NSString).substring(with: NSRange(location: seedStart, length: min(seedLength, needleLength - seedStart)))
                guard seed.utf16.count >= seedLength / 2 else { continue }
                var search = NSRange(location: 0, length: haystack.length)
                while search.length > 0 {
                    let found = haystack.range(of: seed, options: [.caseInsensitive], range: search)
                    guard found.location != NSNotFound else { break }
                    if found.location - seedStart >= 0 { candidates.insert(found.location - seedStart) }
                    search = NSRange(location: found.location + 1, length: haystack.length - found.location - 1)
                }
            }
            var best: (offset: Int, score: Double)?
            for candidate in candidates {
                let window = haystack.substring(with: NSRange(location: candidate, length: min(needleLength, haystack.length - candidate)))
                let match = similarity(window, needle)
                var score = matchWeight * match + afterWeight * match
                if let beforeText, !beforeText.isEmpty { score += beforeWeight * similarity(preceding(candidate), beforeText) } else { score += beforeWeight }
                if let hint, haystack.length > 0 { score += proximityWeight * (1 - Double(abs(candidate - hint)) / Double(haystack.length)) }
                if best == nil || score > best!.score { best = (candidate, score) }
            }
            if let best, best.score >= acceptanceThreshold { return (best.offset, false) }
        }
        if let beforeText, !beforeText.isEmpty {
            let found = haystack.range(of: beforeText)
            if found.location != NSNotFound {
                // Land on the first character after the before text, past any whitespace.
                var offset = found.location + found.length
                while offset < haystack.length, let scalar = Unicode.Scalar(haystack.character(at: offset)), CharacterSet.whitespacesAndNewlines.contains(scalar) { offset += 1 }
                return (offset, true)
            }
        }
        return nil
    }

    /// 1 minus the normalised edit distance.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.utf16), y = Array(b.utf16)
        if x.isEmpty && y.isEmpty { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }
}

/// Resolves a stored position against the open book (Spec 12.2).
struct EPUBPositionResolver {
    let publication: EPUBPublication
    /// Loads the chapter text of a spine index; nil when it cannot be rendered.
    let chapter: (Int) -> EPUBLoadedChapter?

    private var scale: EPUBProgressScale { EPUBProgressScale(weights: publication.weights) }

    /// The spine index for an href: normalised, then without its fragment, then nil.
    func spineIndex(forHref href: String) -> Int? {
        var diagnostics = EPUBDiagnosticList()
        let stripped = href.hasPrefix("/") ? String(href.dropFirst()) : href
        let (path, _) = EPUBHref.splitFragment(stripped)
        if let index = publication.package.spineIndex(forPath: path) { return index }
        let resolved = EPUBHref.resolve(path, from: "", in: publication.zip, diagnostics: &diagnostics)
        if let entryPath = resolved.path, let index = publication.package.spineIndex(forPath: entryPath) { return index }
        let decoded = path.removingPercentEncoding ?? path
        return publication.package.spineIndex(forPath: decoded)
    }

    func resolve(_ stored: EPUBStoredPosition) -> EPUBRestoredPosition {
        switch stored {
        case .current(let locator): return resolve(locator)
        case .legacy(let legacy): return resolve(legacy)
        case .unreadable: return startPosition(fallbacks: [])
        }
    }

    func resolve(_ locator: EPUBLocator) -> EPUBRestoredPosition {
        var fallbacks: [EPUBRestoredPosition.Method] = []
        guard let spineIndex = spineIndex(forHref: locator.href) ?? (publication.package.spine.indices.contains(locator.spineIndex) && publication.package.spine[locator.spineIndex].path == locator.href ? locator.spineIndex : nil) else {
            return total(locator.totalProgression, fallbacks: [.offset, .cfi, .text, .progression])
        }
        guard let loaded = chapter(spineIndex) else { return total(locator.totalProgression, fallbacks: [.offset, .cfi, .text, .progression]) }
        let text = loaded.text
        let sameRelease = locator.release.identifier == publication.package.uniqueIdentifier && locator.release.modified == publication.package.modified
        if sameRelease, locator.parser == EPUBChapterText.parserVersion, locator.chapterLength == text.length, locator.offset >= 0, locator.offset <= text.length {
            return EPUBRestoredPosition(spineIndex: spineIndex, offset: locator.offset, progression: progression(of: locator.offset, in: text), method: .offset, fallbacks: [])
        }
        fallbacks.append(.offset)
        if let cfiString = locator.cfi, let cfi = try? EPUBCFI.parse(cfiString), let path = cfi.documentPath,
           case .success(let resolution) = EPUBCFIResolver.resolve(path, in: loaded.document.tree),
           let offset = text.runTable.renderedOffset(for: resolution.position, in: loaded.document.tree) {
            return EPUBRestoredPosition(spineIndex: spineIndex, offset: offset, progression: progression(of: offset, in: text), method: .cfi, fallbacks: fallbacks)
        }
        fallbacks.append(.cfi)
        let hint = Int((locator.progression * Double(text.length)).rounded())
        if let context = locator.text, let found = EPUBTextAnchor.find(before: context.before, after: context.after, in: text.plainText, hint: hint) {
            if !found.exact { fallbacks.append(.text) }
            return EPUBRestoredPosition(spineIndex: spineIndex, offset: found.offset, progression: progression(of: found.offset, in: text), method: found.exact ? .text : .approximateText, fallbacks: fallbacks)
        }
        fallbacks.append(.text)
        return EPUBRestoredPosition(spineIndex: spineIndex, offset: Int((min(1, max(0, locator.progression)) * Double(text.length)).rounded()), progression: locator.progression, method: .progression, fallbacks: fallbacks)
    }

    func resolve(_ legacy: EPUBLegacyPosition) -> EPUBRestoredPosition {
        var fallbacks: [EPUBRestoredPosition.Method] = []
        guard let spineIndex = spineIndex(forHref: legacy.href), let loaded = chapter(spineIndex) else {
            return legacy.totalProgression.map { total($0, fallbacks: [.fragment, .selector, .text, .progression]) } ?? startPosition(fallbacks: [.fragment, .selector, .text, .progression, .totalProgression])
        }
        let text = loaded.text
        if let fragment = legacy.fragments.first {
            if let offset = text.anchors[fragment] {
                return EPUBRestoredPosition(spineIndex: spineIndex, offset: offset, progression: progression(of: offset, in: text), method: .fragment, fallbacks: fallbacks)
            }
            fallbacks.append(.fragment)
        }
        if let selector = legacy.cssSelector {
            let parsed = EPUBSelector.parse(selector)
            let tree = loaded.document.tree
            if parsed.unsupportedForm == nil, let body = loaded.document.body,
               let element = tree.descendantElements(of: body).first(where: { parsed.matches($0, in: tree, namespaces: loaded.document.prefixes) }),
               let offset = text.runTable.renderedOffset(for: .element(element), in: tree) {
                return EPUBRestoredPosition(spineIndex: spineIndex, offset: offset, progression: progression(of: offset, in: text), method: .selector, fallbacks: fallbacks)
            }
            fallbacks.append(.selector)
        }
        let hint = legacy.progression.map { Int(($0 * Double(text.length)).rounded()) }
        if legacy.textHighlight != nil || legacy.textAfter != nil || legacy.textBefore != nil,
           let found = EPUBTextAnchor.find(before: legacy.textBefore, after: legacy.textAfter, highlight: legacy.textHighlight, in: text.plainText, hint: hint) {
            if !found.exact { fallbacks.append(.text) }
            return EPUBRestoredPosition(spineIndex: spineIndex, offset: found.offset, progression: progression(of: found.offset, in: text), method: found.exact ? .text : .approximateText, fallbacks: fallbacks)
        }
        if legacy.textHighlight != nil || legacy.textAfter != nil || legacy.textBefore != nil { fallbacks.append(.text) }
        if let progression = legacy.progression {
            return EPUBRestoredPosition(spineIndex: spineIndex, offset: Int((progression * Double(text.length)).rounded()), progression: progression, method: .progression, fallbacks: fallbacks)
        }
        fallbacks.append(.progression)
        if let total = legacy.totalProgression { return self.total(total, fallbacks: fallbacks) }
        return EPUBRestoredPosition(spineIndex: spineIndex, offset: 0, progression: 0, method: .start, fallbacks: fallbacks + [.totalProgression])
    }

    private func progression(of offset: Int, in text: EPUBChapterText) -> Double {
        text.length > 0 ? Double(min(max(0, offset), text.length)) / Double(text.length) : 0
    }

    private func total(_ fraction: Double, fallbacks: [EPUBRestoredPosition.Method]) -> EPUBRestoredPosition {
        guard let position = scale.position(forFraction: fraction) else { return startPosition(fallbacks: fallbacks + [.totalProgression]) }
        return EPUBRestoredPosition(spineIndex: position.spineIndex, offset: nil, progression: position.progression, method: .totalProgression, fallbacks: fallbacks)
    }

    private func startPosition(fallbacks: [EPUBRestoredPosition.Method]) -> EPUBRestoredPosition {
        EPUBRestoredPosition(spineIndex: publication.startTarget.spineIndex, offset: 0, progression: 0, method: .start, fallbacks: fallbacks)
    }
}

/// The current-location report (Spec 12.4).
struct EPUBRelocation: Sendable, Hashable {
    let locator: EPUBLocator
    let visibleRange: NSRange
    let pageIndex: Int
    let pageCount: Int
    let location: Int
    let totalLocations: Int
    let contentsEntry: EPUBContentsEntry?
    let pageLabel: String?
    let atStart: Bool
    let atEnd: Bool
}
