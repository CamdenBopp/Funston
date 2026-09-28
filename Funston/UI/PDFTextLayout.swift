import CoreGraphics
import UIKit

/// A recognized line or paragraph fragment and where it sits on the page,
/// normalized to 0...1 with the origin at the top left.
struct PDFTextBox: Sendable, Equatable {
    var text: String
    var rect: CGRect
}

/// Puts recognized text back into reading order on multi-column pages, without
/// machine learning: it reads the white space between lines.
///
/// Measured on 73 Magazine (August 1976, pages 30 and 40, four columns): sorting
/// lines top to bottom kept 3-10% of consecutive lines together; splitting at
/// gutters first kept 90-91%; recognizing each detected column on its own kept
/// 99-100%.
enum PDFTextLayout {
    /// Narrowest empty vertical band treated as a gutter between columns.
    static let minimumGutter: CGFloat = 0.008
    /// Shortest empty horizontal band treated as a break between sections.
    static let minimumSectionGap: CGFloat = 0.012

    /// Recursive XY-cut: split at the widest empty band, preferring a gutter
    /// between columns. A horizontal break comes first when the part above or
    /// below it spans the gutter (a headline, a wide caption), so full-width
    /// text isn't split down the middle. Each block is read top to bottom.
    static func blocks(_ lines: [PDFTextBox]) -> [[PDFTextBox]] {
        guard lines.count > 1 else { return lines.isEmpty ? [] : [lines] }
        let gutter = widestGap(lines.map { ($0.rect.minX, $0.rect.maxX) })
        let section = widestGap(lines.map { ($0.rect.minY, $0.rect.maxY) })
        if let gutter, gutter.width >= minimumGutter {
            if let section, section.width >= minimumSectionGap {
                let top = lines.filter { $0.rect.midY < section.at }, bottom = lines.filter { $0.rect.midY >= section.at }
                let spansGutter = { (part: [PDFTextBox]) in part.contains { $0.rect.minX < gutter.at && $0.rect.maxX > gutter.at } }
                if spansGutter(top) || spansGutter(bottom) { return blocks(top) + blocks(bottom) }
            }
            return blocks(lines.filter { $0.rect.midX < gutter.at }) + blocks(lines.filter { $0.rect.midX >= gutter.at })
        }
        if let section, section.width >= minimumSectionGap {
            return blocks(lines.filter { $0.rect.midY < section.at }) + blocks(lines.filter { $0.rect.midY >= section.at })
        }
        return [lines.sorted { $0.rect.minY < $1.rect.minY }]
    }

    /// The region a block covers, grown slightly so crops don't clip ascenders.
    static func region(of block: [PDFTextBox], padding: CGFloat = 0.004) -> CGRect {
        guard let first = block.first else { return .null }
        return block.dropFirst().reduce(first.rect) { $0.union($1.rect) }
            .insetBy(dx: -padding, dy: -padding)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private static func widestGap(_ intervals: [(CGFloat, CGFloat)]) -> (at: CGFloat, width: CGFloat)? {
        let sorted = intervals.sorted { $0.0 < $1.0 }
        guard var reach = sorted.first?.1 else { return nil }
        var best: (at: CGFloat, width: CGFloat)?
        for (start, end) in sorted.dropFirst() {
            if start > reach, start - reach > (best?.width ?? 0) { best = ((start + reach) / 2, start - reach) }
            reach = max(reach, end)
        }
        return best
    }

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

    private static let sameLineOverlap: CGFloat = 0.5
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
