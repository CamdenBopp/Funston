import XCTest
import UIKit
@testable import Funston

/// Real payload: page 40 of 73 Magazine, August 1976 (Internet Archive item
/// 73-magazine-1976-08), rendered the way the reader renders it. Four columns,
/// bullet lists, a mid-column heading and a schematic across three columns. The
/// ground truth is the opening lines of each column, transcribed from the scan.
@MainActor
final class PDFTextLayoutTests: XCTestCase {
    private static let minimumContinuity = 0.95
    private static let minimumRecall = 0.95

    func testVisionEngineReadsMagazineColumnsInOrder() async throws {
        let text = try await recognize(with: PDFTextEngineID.appleVision)
        let score = try Self.score(text)
        XCTAssertGreaterThanOrEqual(score.continuity, Self.minimumContinuity, "Lines out of order: \(score.broken.prefix(5))")
        XCTAssertGreaterThanOrEqual(score.recall, Self.minimumRecall)
    }

    func testDocumentReaderReadsMagazineColumnsInOrder() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("The document reader needs iOS 26") }
        let text = try await recognize(with: PDFTextEngineID.appleDocuments)
        let score = try Self.score(text)
        XCTAssertGreaterThanOrEqual(score.continuity, Self.minimumContinuity, "Lines out of order: \(score.broken.prefix(5))")
        XCTAssertGreaterThanOrEqual(score.recall, Self.minimumRecall)
        let paragraphs = text.components(separatedBy: "\n\n")
        let fragments = paragraphs.filter { $0.split(separator: " ").count <= 2 }
        XCTAssertLessThan(Double(fragments.count), Double(paragraphs.count) * 0.1, "Justified lines were left in pieces")
    }

    func testTwoColumnsUnderAHeadlineReadColumnByColumn() {
        func box(_ text: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 0.4) -> PDFTextBox {
            PDFTextBox(text: text, rect: CGRect(x: x, y: y, width: w, height: 0.02))
        }
        let lines = [box("Headline across the page", 0.05, 0.05, 0.9),
                     box("left one", 0.05, 0.12), box("right one", 0.55, 0.12),
                     box("left two", 0.05, 0.15), box("right two", 0.55, 0.15)]
        let order = PDFTextLayout.blocks(lines).flatMap { $0.map(\.text) }
        XCTAssertEqual(order, ["Headline across the page", "left one", "left two", "right one", "right two"])
    }

    func testStitchingJoinsPiecesOfOneLineButNotSentences() {
        let line = CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.02)
        let stitched = PDFTextLayout.stitch([
            ("in the best", line, line),
            ("commercial", line.offsetBy(dx: 0.12, dy: 0), line.offsetBy(dx: 0.12, dy: 0)),
            ("keyers, but com-", line.offsetBy(dx: 0, dy: 0.025), line.offsetBy(dx: 0, dy: 0.025)),
            ("plementary MOS.", line.offsetBy(dx: 0, dy: 0.05), line.offsetBy(dx: 0, dy: 0.05)),
            ("New paragraph", line.offsetBy(dx: 0, dy: 0.075), line.offsetBy(dx: 0, dy: 0.075))
        ], isWord: { $0 == "complementary" })
        XCTAssertEqual(stitched, ["in the best commercial keyers, but complementary MOS.", "New paragraph"])
    }

    func testLineBreakHyphenStaysWhenTheJoinedWordIsNotAWord() {
        let line = CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.02)
        let stitched = PDFTextLayout.stitch([("provide an on-", line, line), ("off switch.", line.offsetBy(dx: 0, dy: 0.025), line.offsetBy(dx: 0, dy: 0.025))],
                                            isWord: { _ in false })
        XCTAssertEqual(stitched, ["provide an on-off switch."])
    }

    func testSystemDictionaryClosesUpARealWordOnly() {
        XCTAssertTrue(SpellingDictionary.isWord("complementary"))
        XCTAssertFalse(SpellingDictionary.isWord("onoff"))
    }

    // MARK: - Harness

    private func recognize(with engineID: String) async throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "73-magazine-1976-08-page40", withExtension: "jpg"))
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
        let engine = try XCTUnwrap(PDFPageTextEngineRegistry.builtIn.engine(id: engineID))
        return await engine.recognize(image)
    }

    private static func words(_ text: String) -> [String] {
        let joined = text.replacingOccurrences(of: "-\\s*\\n\\s*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[“”]", with: "\"", options: .regularExpression)
        return joined.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// recall: share of ground-truth words recognized, in any order. continuity:
    /// share of consecutive ground-truth lines where the second follows the first
    /// (allowing one word of slack where a line-break hyphen was rejoined).
    private static func score(_ text: String) throws -> (recall: Double, continuity: Double, broken: [String]) {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "73-magazine-1976-08-page40-columns", withExtension: "txt"))
        var columns: [[String]] = []
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            if line.hasPrefix("#") { columns.append([]) } else if !line.isEmpty { columns[columns.count - 1].append(String(line)) }
        }
        let tokens = words(text)
        func match(_ expected: [String], at start: Int) -> Double {
            guard !expected.isEmpty, start >= 0 else { return 0 }
            let hits = zip(tokens.dropFirst(start), expected).filter { $0 == $1 }.count
            return Double(hits) / Double(expected.count)
        }
        func locate(_ expected: [String]) -> (start: Int, score: Double) {
            (0..<max(1, tokens.count)).map { ($0, match(expected, at: $0)) }.max { $0.1 < $1.1 } ?? (0, 0)
        }
        var available = Dictionary(tokens.map { ($0, 1) }, uniquingKeysWith: +)
        var needed = 0, found = 0, pairs = 0, ordered = 0
        var broken: [String] = []
        for column in columns {
            for word in column.flatMap(words) {
                needed += 1
                if let count = available[word], count > 0 { found += 1; available[word] = count - 1 }
            }
            for (first, second) in zip(column, column.dropFirst()) {
                pairs += 1
                let a = words(first), b = words(second)
                let located = locate(a)
                guard located.score >= 0.5 else { broken.append(first); continue }
                let end = located.start + a.count
                if (end - 2...end + 1).contains(where: { match(b, at: $0) >= 0.5 }) { ordered += 1 } else { broken.append("\(first) -> \(second)") }
            }
        }
        return (Double(found) / Double(needed), Double(ordered) / Double(pairs), broken)
    }
}
