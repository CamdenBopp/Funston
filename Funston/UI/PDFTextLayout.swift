import CoreGraphics
import UIKit

/// A recognized line or paragraph fragment and where it sits on the page,
/// normalized to 0...1 with the origin at the top left.
struct PDFTextBox: Sendable, Equatable {
    var text: String
    var rect: CGRect
    /// A whole table row, its cells joined: read as it is, never re-recognized.
    var isTableRow = false
}

/// Puts recognized text back into reading order on multi-column pages, without
/// machine learning: it reads where the lines sit.
///
/// Lines chain into blocks from the top down: a line continues the one directly
/// above it when the two share columns. A line two lines could continue from (a
/// headline over two columns) belongs to neither, so columns under it stay
/// apart. Blocks are then read in Breuel's order ("High Performance Document
/// Layout Analysis", 2003).
///
/// Lines in order, measured on 73 Magazine with each block re-recognized on its
/// own: December 1981 page 6 (a headline over three columns, a prize box across
/// three others) 14% with the old top-down page cuts, 99% with blocks. August
/// 1976 pages 30 and 40 stayed at 100% and 99%.
enum PDFTextLayout {
    static func blocks(_ lines: [PDFTextBox]) -> [[PDFTextBox]] {
        let lines = mergingRows(withoutEchoes(lines)).sorted { $0.rect.minY < $1.rect.minY }
        let predecessor = lines.map { line in
            lines.indices
                .filter { continues(line, after: lines[$0]) }
                .min { line.rect.minY - lines[$0].rect.maxY < line.rect.minY - lines[$1].rect.maxY }
        }
        var successors = [Int](repeating: 0, count: lines.count)
        for case let index? in predecessor { successors[index] += 1 }
        var blockOf = [Int?](repeating: nil, count: lines.count)
        var blocks: [[PDFTextBox]] = []
        for index in lines.indices {
            if let previous = predecessor[index], successors[previous] == 1, let block = blockOf[previous] {
                blocks[block].append(lines[index])
                blockOf[index] = block
            } else {
                blocks.append([lines[index]])
                blockOf[index] = blocks.count - 1
            }
        }
        return tables(readingOrder(absorbingNested(blocks)))
    }

    /// Consecutive blocks stacked in one column, to recognize as one crop: fewer
    /// requests, same order. A run ends where its region would take in text
    /// from any other block. On 73 Magazine page 40 this took 27 crops to 12.
    static func runs(_ blocks: [[PDFTextBox]]) -> [[PDFTextBox]] {
        let regions = blocks.map { region(of: $0, padding: 0) }
        var runs: [(lines: [PDFTextBox], members: Set<Int>, region: CGRect)] = []
        for (index, block) in blocks.enumerated() {
            if let run = runs.last {
                let a = run.region, b = regions[index]
                let union = a.union(b)
                let stacked = b.minY >= a.maxY - stackTolerance
                    && sharedWidth(a, b) >= minimumColumnOverlap * min(a.width, b.width)
                let clear = !regions.indices.contains { $0 != index && !run.members.contains($0) && regions[$0].intersects(union) }
                let table = block[0].isTableRow || run.lines[0].isTableRow
                if stacked, clear, !table {
                    runs[runs.count - 1] = (run.lines + block, run.members.union([index]), union)
                    continue
                }
            }
            runs.append((block, [index], regions[index]))
        }
        return runs.map(\.lines)
    }

    /// Blocks side by side whose lines are short cells, not prose, are a table:
    /// it reads row by row, "Grand Prize; Carl F. Bogart WA7JWW/WA7OTR Reno NV;
    /// FT-901DM, MLA-2500, System 33, rotator", instead of all the prizes, then
    /// all the names, then all the gear. The leftmost column's lines start the
    /// rows; every other cell joins the row it is level with.
    static func tables(_ blocks: [[PDFTextBox]]) -> [[PDFTextBox]] {
        var result: [[PDFTextBox]] = []
        var index = 0
        while index < blocks.count {
            var group = [blocks[index]]
            var end = index + 1
            while end < blocks.count, level(blocks[end], with: group) {
                group.append(blocks[end])
                end += 1
            }
            if let rows = rows(of: group) {
                result.append(rows)
                index = end
            } else {
                result.append(blocks[index])
                index += 1
            }
        }
        return result
    }

    private static func level(_ block: [PDFTextBox], with group: [[PDFTextBox]]) -> Bool {
        let rect = region(of: block, padding: 0)
        let span = group.map { region(of: $0, padding: 0) }.reduce(CGRect.null) { $0.union($1) }
        return min(rect.maxY, span.maxY) - max(rect.minY, span.minY) >= minimumRowOverlap * rect.height
    }

    private static func rows(of group: [[PDFTextBox]]) -> [PDFTextBox]? {
        let lines = group.flatMap { $0 }
        let words = lines.reduce(0) { $0 + $1.text.split(separator: " ").count }
        guard group.count > 1, Double(words) <= maximumCellWords * Double(lines.count) else { return nil }
        let columns = group.sorted { region(of: $0, padding: 0).minX < region(of: $1, padding: 0).minX }
        let anchors = columns[0].sorted { $0.rect.minY < $1.rect.minY }
        guard anchors.count >= minimumTableRows else { return nil }
        var cells = [[[String]]](repeating: [[String]](repeating: [], count: columns.count), count: anchors.count)
        var rects = anchors.map(\.rect)
        for (column, blockLines) in columns.enumerated() {
            for line in blockLines.sorted(by: { $0.rect.minY < $1.rect.minY }) {
                let row = anchors.lastIndex { $0.rect.minY <= line.rect.midY } ?? 0
                cells[row][column].append(line.text)
                rects[row] = rects[row].union(line.rect)
            }
        }
        return zip(cells, rects).map { row, rect in
            let text = row.filter { !$0.isEmpty }.map { $0.joined(separator: " ") }.joined(separator: "; ")
            return PDFTextBox(text: text, rect: rect, isTableRow: true)
        }
    }

    /// The region a block covers, grown slightly so crops don't clip ascenders.
    static func region(of block: [PDFTextBox], padding: CGFloat = 0.004) -> CGRect {
        guard let first = block.first else { return .null }
        return block.dropFirst().reduce(first.rect) { $0.union($1.rect) }
            .insetBy(dx: -padding, dy: -padding)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Whether `line` can continue `candidate`: directly below it (allowing a
    /// line Vision missed in between) and sharing most of the narrower width.
    private static func continues(_ line: PDFTextBox, after candidate: PDFTextBox) -> Bool {
        let a = candidate.rect, b = line.rect
        let height = max(a.height, b.height)
        let drop = b.minY - a.maxY
        return drop >= -maximumLineOverlap * height && drop <= maximumLineDrop * height
            && sharedWidth(a, b) >= minimumColumnOverlap * min(a.width, b.width)
    }

    private static func sharedWidth(_ a: CGRect, _ b: CGRect) -> CGFloat {
        min(a.maxX, b.maxX) - max(a.minX, b.minX)
    }

    /// Letter-spaced type makes Vision report a word or two again on top of the
    /// whole line ("best" inside "in the best commercial"). A box mostly inside a
    /// larger one is that kind of echo.
    private static func withoutEchoes(_ lines: [PDFTextBox]) -> [PDFTextBox] {
        func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
        return lines.filter { line in
            !lines.contains { other in
                area(other.rect) > area(line.rect) && area(other.rect.intersection(line.rect)) > echoShare * area(line.rect)
            }
        }
    }

    /// Vision sometimes splits one printed line at a wide space. Pieces on the
    /// same baseline and nearly touching are one line.
    private static func mergingRows(_ lines: [PDFTextBox]) -> [PDFTextBox] {
        var merged: [PDFTextBox] = []
        for line in lines.sorted(by: { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }) {
            if let index = merged.firstIndex(where: { sameRow($0.rect, line.rect) }) {
                let (left, right) = merged[index].rect.minX <= line.rect.minX ? (merged[index], line) : (line, merged[index])
                merged[index] = PDFTextBox(text: left.text + " " + right.text, rect: left.rect.union(right.rect))
            } else {
                merged.append(line)
            }
        }
        return merged
    }

    private static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let height = min(a.height, b.height)
        let sharedHeight = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let gap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
        return sharedHeight > sameLineOverlap * height && gap < maximumWordGap * height
    }

    /// A block that sits inside another block's region (a word the chain
    /// skipped) is read as part of it.
    private static func absorbingNested(_ blocks: [[PDFTextBox]]) -> [[PDFTextBox]] {
        var blocks = blocks.sorted { $0.count > $1.count }
        for index in blocks.indices.dropFirst().reversed() {
            let inner = region(of: blocks[index], padding: 0)
            let center = CGPoint(x: inner.midX, y: inner.midY)
            guard let host = blocks[..<index].firstIndex(where: { region(of: $0, padding: 0).contains(center) }) else { continue }
            blocks[host] = (blocks[host] + blocks[index]).sorted { $0.rect.minY < $1.rect.minY }
            blocks.remove(at: index)
        }
        return blocks
    }

    /// Breuel's rules: a comes before b when they share columns and a is higher,
    /// or when a is wholly left of b and nothing spanning both lies between them.
    /// Of the blocks that are free to come next, the one continuing the column
    /// just read wins, then the highest.
    private static func readingOrder(_ blocks: [[PDFTextBox]]) -> [[PDFTextBox]] {
        let rects = blocks.map { region(of: $0, padding: 0) }
        func before(_ i: Int, _ j: Int) -> Bool {
            let a = rects[i], b = rects[j]
            if sharedWidth(a, b) > 0 { return a.midY < b.midY }
            guard a.maxX <= b.minX else { return false }
            let (upper, lower) = a.minY < b.minY ? (a, b) : (b, a)
            return !rects.indices.contains { k in
                k != i && k != j && rects[k].minY >= upper.maxY && rects[k].maxY <= lower.minY
                    && rects[k].minX < a.maxX && rects[k].maxX > b.minX
            }
        }
        var incoming = [Int](repeating: 0, count: blocks.count)
        var edges = [[Int]](repeating: [], count: blocks.count)
        for i in blocks.indices {
            for j in blocks.indices where i != j && before(i, j) {
                edges[i].append(j)
                incoming[j] += 1
            }
        }
        func higher(_ i: Int, _ j: Int) -> Bool { (rects[i].minY, rects[i].minX) < (rects[j].minY, rects[j].minX) }
        var remaining = Set(blocks.indices)
        var order: [Int] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { incoming[$0] == 0 }
            // Boxes that overlap can make a cycle; the highest block breaks it.
            let pool = ready.isEmpty ? remaining : ready
            let sameColumn = order.last.map { last in pool.filter { sharedWidth(rects[$0], rects[last]) > 0 } } ?? []
            guard let next = (sameColumn.isEmpty ? pool : Set(sameColumn)).min(by: higher) else { break }
            remaining.remove(next)
            order.append(next)
            for j in edges[next] { incoming[j] -= 1 }
        }
        return order.map { blocks[$0] }
    }

    /// Prose averages 6 to 7 words a line in a magazine column; cells, 2 or 3.
    private static let maximumCellWords = 4.0
    private static let minimumTableRows = 2
    private static let minimumRowOverlap: CGFloat = 0.5
    /// A line may continue one this far below, in line heights: one missed line.
    private static let maximumLineDrop: CGFloat = 2
    private static let maximumLineOverlap: CGFloat = 0.5
    private static let minimumColumnOverlap: CGFloat = 0.5
    private static let sameLineOverlap: CGFloat = 0.5
    /// Wider than a word space, narrower than any gutter measured.
    private static let maximumWordGap: CGFloat = 0.3
    private static let echoShare: CGFloat = 0.6
    private static let stackTolerance: CGFloat = 0.002

    /// Joins one column's lines, top to bottom, into paragraphs. A paragraph
    /// starts after extra space, at an indented or bulleted line, or after a
    /// line that stops short: in justified type any short line, in ragged type
    /// one that ends a sentence. Lines centered over the column are one heading.
    /// `aspectRatio` is the width over the height of the image the boxes are
    /// normalized to, so an indent (across) is measured in line pitches (down).
    ///
    /// On 73 Magazine, December 1981 page 6, this reads Wayne Green's first
    /// paragraph as one paragraph instead of 15 lines, "regu-" / "lated" closed
    /// up.
    static func paragraphs(_ lines: [PDFTextBox], aspectRatio: CGFloat, isWord: (String) -> Bool) -> [String] {
        let lines = withoutEchoes(lines).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = lines.first else { return [] }
        let pitches = zip(lines, lines.dropFirst()).map { $1.rect.minY - $0.rect.minY }.filter { $0 > 0 }.sorted()
        let verticalPitch = pitches.isEmpty ? first.rect.height : pitches[pitches.count / 2]
        let pitch = verticalPitch / max(aspectRatio, .ulpOfOne)
        let left = mostCommon(lines.map(\.rect.minX), tolerance: pitch * leftEdgeTolerance)
        let rights = lines.map(\.rect.maxX).sorted()
        let right = rights[min(rights.count - 1, Int(Double(rights.count) * rightEdgePercentile))]
        let width = max(right - left, .ulpOfOne)
        let fullLines = lines.filter { $0.rect.maxX >= right - fullLineSlack * width }.count
        let justified = Double(fullLines) >= justifiedShare * Double(lines.count)
        let centered = { (line: PDFTextBox) in
            line.rect.minX - left > indentInPitches * pitch && line.rect.maxX < right - indentInPitches * pitch
        }
        var paragraphs = [first.text]
        for (a, b) in zip(lines, lines.dropFirst()) {
            let spaced = b.rect.minY - a.rect.minY > paragraphSpacing * verticalPitch
            let indented = b.rect.minX - left > indentInPitches * pitch
            let bulleted = b.text.first.map { bullets.contains($0) } ?? false
            let short = a.rect.maxX < right - (justified ? justifiedShortSlack : raggedShortSlack) * width
            let endsSentence = a.text.last.map { sentenceEnds.contains($0) } ?? false
            if !spaced, centered(a), centered(b) {
                paragraphs[paragraphs.count - 1] += " " + b.text
            } else if spaced || indented || bulleted || (short && (justified || endsSentence)) {
                paragraphs.append(b.text)
            } else {
                paragraphs[paragraphs.count - 1] = joiningLine(paragraphs[paragraphs.count - 1], b.text, isWord: isWord)
            }
        }
        return paragraphs
    }

    /// Joins columns of paragraphs in reading order, continuing a paragraph a
    /// column break cut mid-sentence. When the next column doesn't carry on the
    /// sentence but one of the few after it does, and that one starts back up
    /// the page (the top of the next column), it is read first: a sidebar box
    /// beside the article waits until the sentence is finished. On 73 Magazine,
    /// December 1981 page 6, the schedule box sat between "we would have" and
    /// "reached our present amateur population". `region` is where each column
    /// sits on the page.
    static func threading(_ columns: [(paragraphs: [String], region: CGRect)], isWord: (String) -> Bool) -> [String] {
        var remaining = columns.filter { !$0.paragraphs.isEmpty }
        var paragraphs: [String] = []
        var lastRegion: CGRect?
        while !remaining.isEmpty {
            var index = 0
            if let previous = paragraphs.last, let lastRegion, !continues(previous, with: remaining[0].paragraphs[0]) {
                index = remaining.indices.dropFirst().prefix(sidebarLookahead).first { candidate in
                    remaining[candidate].region.minY < lastRegion.midY
                        && continues(previous, with: remaining[candidate].paragraphs[0])
                } ?? 0
            }
            let next = remaining.remove(at: index)
            if let previous = paragraphs.last, continues(previous, with: next.paragraphs[0]) {
                paragraphs[paragraphs.count - 1] = joiningLine(previous, next.paragraphs[0], isWord: isWord)
                paragraphs += next.paragraphs.dropFirst()
            } else {
                paragraphs += next.paragraphs
            }
            lastRegion = next.region
        }
        return paragraphs
    }

    /// Whether `next` carries on a paragraph that stopped mid-sentence ("local
    /// govern-" / "ment cooperation"). Without a hyphen to go on, a short
    /// fragment (a stray word read off a photo) doesn't count.
    static func continues(_ previous: String, with next: String) -> Bool {
        guard let end = previous.last, next.first?.isLowercase == true else { return false }
        return end == "-" || ((end == "," || end.isLowercase) && next.split(separator: " ").count >= minimumContinuationWords)
    }

    /// "com-" + "plementary" closes up when the joined word is a word; "on-" +
    /// "off" keeps its hyphen. A hyphen the scan lost ("transmis" / "sions")
    /// closes up when neither half is a word and the whole is.
    static func joiningLine(_ text: String, _ next: String, isWord: (String) -> Bool) -> String {
        let head = text.split(separator: " ").last.map(String.init) ?? ""
        let tail = next.split(separator: " ").first.map(String.init) ?? ""
        let trim = { (word: String) in word.trimmingCharacters(in: .punctuationCharacters) }
        if text.hasSuffix("-") {
            return isWord(trim(String(head.dropLast()) + tail)) ? String(text.dropLast()) + next : text + next
        }
        let lostHyphen = head.last?.isLetter == true && !isWord(trim(head)) && !isWord(trim(tail)) && isWord(trim(head + tail))
        return lostHyphen ? text + next : text + " " + next
    }

    private static func mostCommon(_ values: [CGFloat], tolerance: CGFloat) -> CGFloat {
        values.max { a, b in
            values.filter { abs($0 - a) <= tolerance }.count < values.filter { abs($0 - b) <= tolerance }.count
        } ?? 0
    }

    private static let bullets: Set<Character> = ["•", "●", "▪", "■", "◦"]
    private static let sentenceEnds: Set<Character> = [".", ":", "?", "!", "\"", "”", ")"]
    /// More than this many pitches from one line's top to the next is a break.
    private static let paragraphSpacing: CGFloat = 1.6
    /// A first-line indent is about an em, a line pitch is a bit more.
    private static let indentInPitches: CGFloat = 0.5
    private static let leftEdgeTolerance: CGFloat = 0.25
    private static let rightEdgePercentile = 0.9
    private static let fullLineSlack: CGFloat = 0.05
    /// Share of lines reaching the right edge for a column to count as justified.
    private static let justifiedShare = 0.6
    private static let justifiedShortSlack: CGFloat = 0.08
    private static let raggedShortSlack: CGFloat = 0.3
    private static let minimumContinuationWords = 5
    /// How many columns ahead a sentence's continuation is looked for.
    private static let sidebarLookahead = 4

    /// Justified, letter-spaced type makes Apple's document recognizer split one
    /// printed line into several paragraphs ("in the best" / "commercial"). A
    /// fragment on the previous one's baseline is the same line; one starting
    /// directly below it in the same column continues the paragraph unless the
    /// previous one ended a sentence. On 73 Magazine page 40 this turned 87
    /// paragraphs (37 of one or two words) into 22 (one short).
    ///
    /// A paragraph that continues after a line-break hyphen is closed up
    /// ("com-" + "plementary") when `isWord` accepts the joined word; otherwise
    /// the hyphen stays ("on-" + "off").
    static func stitch(_ fragments: [(text: String, firstLine: CGRect, lastLine: CGRect)],
                       isWord: (String) -> Bool = { _ in false }) -> [String] {
        var merged: [(text: String, lastLine: CGRect)] = []
        for fragment in fragments {
            guard let previous = merged.last else { merged.append((fragment.text, fragment.lastLine)); continue }
            let a = previous.lastLine, b = fragment.firstLine
            let lineHeight = max(a.height, b.height)
            let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
            let sameLine = overlap > sameLineOverlap * min(a.height, b.height) && b.minX >= a.minX
            let drop = b.minY - a.maxY
            let sameColumn = b.minX < a.maxX && b.maxX > a.minX - lineHeight * columnSlackInLines
            let endsSentence = previous.text.last.map { ".:?!".contains($0) } ?? false
            let continues = drop >= -continuationOverlap * lineHeight && drop < continuationDrop * lineHeight
                && sameColumn && !endsSentence
            if sameLine || continues {
                let joined: String
                if continues, previous.text.hasSuffix("-") {
                    let head = previous.text.split(separator: " ").last.map { String($0.dropLast()) } ?? ""
                    let tail = fragment.text.split(separator: " ").first.map(String.init) ?? ""
                    let word = (head + tail).trimmingCharacters(in: .punctuationCharacters)
                    joined = isWord(word) ? String(previous.text.dropLast()) + fragment.text : previous.text + fragment.text
                } else {
                    joined = previous.text + " " + fragment.text
                }
                merged[merged.count - 1] = (joined, fragment.lastLine)
            } else {
                merged.append((fragment.text, fragment.lastLine))
            }
        }
        return merged.map(\.text)
    }

    private static let continuationOverlap: CGFloat = 0.2
    private static let continuationDrop: CGFloat = 0.8
    private static let columnSlackInLines: CGFloat = 4
}

/// Whether a word is in the system dictionary, for closing up line-break hyphens.
@MainActor
enum SpellingDictionary {
    private static let checker = UITextChecker()
    private static let language: String = {
        let preferred = Locale.preferredLanguages.first ?? "en_US"
        let available = UITextChecker.availableLanguages
        return available.first { preferred.hasPrefix($0) || $0.hasPrefix(preferred) } ?? "en_US"
    }()

    static func isWord(_ word: String) -> Bool {
        guard word.count > 1, word.allSatisfy(\.isLetter) else { return false }
        let range = NSRange(word.startIndex..., in: word)
        return checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: language).location == NSNotFound
    }
}
