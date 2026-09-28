import CoreGraphics
import UIKit

/// A recognized line or paragraph fragment and where it sits on the page,
/// normalized to 0...1 with the origin at the top left.
struct PDFTextBox: Sendable, Equatable {
    var text: String
    var rect: CGRect
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
        return readingOrder(absorbingNested(blocks))
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
                if stacked, clear {
                    runs[runs.count - 1] = (run.lines + block, run.members.union([index]), union)
                    continue
                }
            }
            runs.append((block, [index], regions[index]))
        }
        return runs.map(\.lines)
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

    /// Adds the next column's paragraphs, continuing the last one when it
    /// stopped mid-sentence and the next starts in lower case ("local govern-" /
    /// "ment cooperation"). Without a hyphen to go on, a short fragment (a stray
    /// word read off a photo) doesn't count as the continuation.
    static func appending(_ next: [String], to paragraphs: inout [String], isWord: (String) -> Bool) {
        guard let previous = paragraphs.last, let end = previous.last, let first = next.first,
              first.first?.isLowercase == true,
              end == "-" || ((end == "," || end.isLowercase) && first.split(separator: " ").count >= minimumContinuationWords)
        else { paragraphs += next; return }
        paragraphs[paragraphs.count - 1] = joiningLine(previous, first, isWord: isWord)
        paragraphs += next.dropFirst()
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
