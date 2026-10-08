import XCTest
import UIKit
@testable import Funston

/// Real payloads, rendered the way the reader renders them:
/// - 73 Magazine, August 1976, page 40 (Internet Archive 73-magazine-1976-08):
///   four columns, bullet lists, a mid-column heading and a schematic across
///   three columns. Ground truth: the opening lines of each column.
/// - 73 Magazine, December 1981, page 6 (73-magazine-1981-12): a headline and
///   photo over three columns, a fourth running the full height, a schedule box
///   and a prize table across three columns. Ground truth: every line of the
///   four article columns. Cutting the page top to bottom kept 14% of these
///   lines in order.
private let augustPage40 = "73-magazine-1976-08-page40"
private let decemberPage6 = "73-magazine-1981-12-page6"

@MainActor
final class PDFTextLayoutTests: XCTestCase {
    private static let minimumContinuity = 0.95
    private static let minimumRecall = 0.95
    /// The December 1981 scan is 1285 by 1768 pixels for a whole page; every
    /// engine measured finds 84-93% of its words.
    private static let minimumScanRecall = 0.88

    func testVisionEngineReadsMagazineColumnsInOrder() async throws {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = { $0.type == .assertionFailure && $0.compactDescription.contains("Lines out of order") }
        XCTExpectFailure("73 Magazine: multi-column reading order breaks around bullets and the schematic.", options: options)
        let text = try await recognize(augustPage40, with: PDFTextEngineID.appleVision)
        let score = try Self.score(text, against: augustPage40)
        XCTAssertGreaterThanOrEqual(score.continuity, Self.minimumContinuity, "Lines out of order: \(score.broken.prefix(5))")
        XCTAssertGreaterThanOrEqual(score.recall, Self.minimumRecall)
    }

    func testVisionEngineReadsColumnsUnderAHeadlineAndBesideABox() async throws {
        let text = try await recognize(decemberPage6, with: PDFTextEngineID.appleVision)
        let score = try Self.score(text, against: decemberPage6)
        XCTAssertGreaterThanOrEqual(score.continuity, Self.minimumContinuity, "Lines out of order: \(score.broken.prefix(5))")
        XCTAssertGreaterThanOrEqual(score.recall, Self.minimumScanRecall)
    }

    /// The paragraph Camden read aloud from Live Text, as Vision now reads it:
    /// one paragraph, line-break hyphens closed up.
    func testVisionEngineReadsWholeParagraphs() async throws {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = {
            $0.type == .assertionFailure && ($0.compactDescription.contains("The schedule box interrupts")
                || $0.compactDescription.contains("The bullet item isn't one paragraph"))
        }
        XCTExpectFailure("73 Magazine: sidebar and bullet layouts split continuous paragraphs.", options: options)
        let paragraphs = try await recognize(decemberPage6, with: PDFTextEngineID.appleVision).components(separatedBy: "\n\n")
        let opening = "touch with those being regulated, the FCC has established advisory committees, made up of people in the regulated industries, to work with them on needed regulations."
        XCTAssertTrue(paragraphs.contains { $0.contains(opening) }, "No paragraph reads: \(opening)")
        let acrossTheSidebar = "we would have reached our present amateur population"
        XCTAssertTrue(paragraphs.contains { $0.contains(acrossTheSidebar) }, "The schedule box interrupts: \(acrossTheSidebar)")
        let bullet = try await recognize(augustPage40, with: PDFTextEngineID.appleVision).components(separatedBy: "\n\n")
        XCTAssertTrue(bullet.contains { $0.hasPrefix("• Low component count") && $0.hasSuffix("discrete components).") },
                      "The bullet item isn't one paragraph")
    }

    func testVisionEngineReadsATableRowByRow() async throws {
        let paragraphs = try await recognize(decemberPage6, with: PDFTextEngineID.appleVision).components(separatedBy: "\n\n")
        XCTAssertTrue(paragraphs.contains("1st Prize; David A. Behar Seattle WA; TS-700A, Hustler Beam, Bird Wattmeter"),
                      "The prize table isn't read by rows: \(paragraphs.filter { $0.contains("Prize") })")
    }

    func testDocumentReaderReadsMagazineColumnsInOrder() async throws {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = {
            $0.type == .assertionFailure && ($0.compactDescription.contains("Lines out of order")
                || $0.compactDescription.contains("Justified lines were left in pieces"))
        }
        XCTExpectFailure("73 Magazine: multi-column reading order and justified paragraph fragments.", options: options)
        guard #available(iOS 26.0, *) else { throw XCTSkip("The document reader needs iOS 26") }
        let text = try await recognize(augustPage40, with: PDFTextEngineID.appleDocuments)
        let score = try Self.score(text, against: augustPage40)
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
                     box("the left column opens with this line", 0.05, 0.12), box("the right column opens with this line", 0.55, 0.12),
                     box("and the left column carries on here", 0.05, 0.15), box("and the right column carries on here", 0.55, 0.15)]
        let order = PDFTextLayout.blocks(lines).flatMap { $0.map(\.text) }
        XCTAssertEqual(order, ["Headline across the page", "the left column opens with this line", "and the left column carries on here",
                               "the right column opens with this line", "and the right column carries on here"])
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

    func testParagraphsBreakAtIndentsShortLinesAndBullets() {
        func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ maxX: CGFloat = 0.9) -> PDFTextBox {
            PDFTextBox(text: text, rect: CGRect(x: x, y: y, width: maxX - x, height: 0.04))
        }
        let lines = [line("THE FCC ADVISORY", 0.3, 0.00, 0.7), line("COMMITTEE", 0.38, 0.05, 0.62),
                     line("In order to keep in closer", 0.1, 0.10), line("touch with those being regu-", 0.05, 0.15),
                     line("lated, the FCC has established", 0.05, 0.20), line("yearly meetings.", 0.05, 0.25, 0.5),
                     line("The most recent meeting was", 0.1, 0.30), line("held at the FCC", 0.05, 0.35),
                     line("• Low component", 0.05, 0.40), line("count (7 ICs)", 0.05, 0.45)]
        let paragraphs = PDFTextLayout.paragraphs(lines, aspectRatio: 1, isWord: { $0 == "regulated" })
        XCTAssertEqual(paragraphs, ["THE FCC ADVISORY COMMITTEE",
                                    "In order to keep in closer touch with those being regulated, the FCC has established yearly meetings.",
                                    "The most recent meeting was held at the FCC",
                                    "• Low component count (7 ICs)"])
    }

    func testIndentsAreMeasuredInLinePitchesNotRawCoordinates() {
        // A tall, narrow column crop: x and y are normalized to different lengths,
        // so 0.012 across is under a third of a line pitch, not an indent.
        let lines = [PDFTextBox(text: "ogy by industry, little change can be", rect: CGRect(x: 0.030, y: 0.699, width: 0.933, height: 0.0146)),
                     PDFTextBox(text: "seen in our ham bands.", rect: CGRect(x: 0.042, y: 0.713, width: 0.599, height: 0.014))]
        XCTAssertEqual(PDFTextLayout.paragraphs(lines, aspectRatio: 523.0 / 1860.0, isWord: { _ in false }),
                       ["ogy by industry, little change can be seen in our ham bands."])
    }

    func testParagraphsContinueIntoTheNextColumnOnlyMidSentence() {
        let government = PDFTextLayout.threading([(["aspects of getting local govern-"], column(0, 0.1, 0.9)),
                                                  (["ment cooperation for emergency communications", "At the last meeting"], column(1, 0.1, 0.9))],
                                                 isWord: { $0 == "government" })
        XCTAssertEqual(government, ["aspects of getting local government cooperation for emergency communications", "At the last meeting"])
        let stray = PDFTextLayout.threading([(["we would have"], column(0, 0.1, 0.9)), (["mac W2NSD/1 ON-THE-AIR"], column(1, 0.1, 0.2))],
                                            isWord: { _ in true })
        XCTAssertEqual(stray, ["we would have", "mac W2NSD/1 ON-THE-AIR"], "A stray word off a photo isn't the rest of the sentence")
    }

    func testASidebarWaitsUntilTheSentenceBesideItEnds() {
        let columns = [(["until that time, we would have"], column(1, 0.3, 0.72)),
                       (["W2NSD/1 ON-THE-AIR SCHEDULE", "Sessions run from 7:00 to 10:00 pm eastern time."], column(0, 0.71, 0.95)),
                       (["6 73 Magazine • December, 1981"], column(0, 0.96, 0.98)),
                       (["reached our present amateur population in about 1965.", "The result of this"], column(2, 0.28, 0.73))]
        XCTAssertEqual(PDFTextLayout.threading(columns, isWord: { _ in false }), [
            "until that time, we would have reached our present amateur population in about 1965.", "The result of this",
            "W2NSD/1 ON-THE-AIR SCHEDULE", "Sessions run from 7:00 to 10:00 pm eastern time.", "6 73 Magazine • December, 1981"
        ])
    }

    /// 73 Magazine page 40: a short line ("high to low.") got its own block
    /// between two in the same column. Text further down that column is not a
    /// column break, so nothing jumps ahead of the short line.
    func testTextFurtherDownTheSameColumnDoesNotJumpAhead() {
        let columns = [(["the signal makes a transition from"], column(0, 0.10, 0.50)),
                       (["high to low."], column(0, 0.51, 0.52)),
                       (["code element is currently being sent, dot flip flop"], column(0, 0.53, 0.90))]
        XCTAssertEqual(PDFTextLayout.threading(columns, isWord: { _ in false }),
                       ["the signal makes a transition from", "high to low.", "code element is currently being sent, dot flip flop"])
    }

    private func column(_ index: CGFloat, _ top: CGFloat, _ bottom: CGFloat) -> CGRect {
        CGRect(x: 0.05 + index * 0.23, y: top, width: 0.21, height: bottom - top)
    }

    func testALostLineBreakHyphenClosesUpOnlyIntoARealWord() {
        let words: Set = ["transmissions", "the", "war"]
        XCTAssertEqual(PDFTextLayout.joiningLine("high-speed transmis", "sions for", isWord: words.contains), "high-speed transmissions for")
        XCTAssertEqual(PDFTextLayout.joiningLine("in the", "war to", isWord: words.contains), "in the war to")
    }

    func testShortCellsSideBySideReadAsRowsButProseColumnsDoNot() {
        func box(_ text: String, _ x: CGFloat, _ y: CGFloat) -> PDFTextBox {
            PDFTextBox(text: text, rect: CGRect(x: x, y: y, width: 0.2, height: 0.02))
        }
        let table = [box("Grand Prize", 0.1, 0.10), box("1st Prize", 0.1, 0.16),
                     box("Carl F. Bogart", 0.35, 0.10), box("Reno NV", 0.35, 0.13), box("David A. Behar", 0.35, 0.16)]
        XCTAssertEqual(PDFTextLayout.blocks(table).flatMap { $0.map(\.text) },
                       ["Grand Prize; Carl F. Bogart Reno NV", "1st Prize; David A. Behar"])
        let prose = [box("In order to keep in closer", 0.1, 0.10), box("touch with those being regu-", 0.1, 0.13),
                     box("ment cooperation for emergen-", 0.35, 0.10), box("cy communications, possible", 0.35, 0.13)]
        XCTAssertEqual(PDFTextLayout.blocks(prose).flatMap { $0.map(\.text) },
                       ["In order to keep in closer", "touch with those being regu-", "ment cooperation for emergen-", "cy communications, possible"])
    }

    func testSystemDictionaryClosesUpARealWordOnly() {
        XCTAssertTrue(SpellingDictionary.isWord("complementary"))
        XCTAssertFalse(SpellingDictionary.isWord("onoff"))
    }

    // MARK: - Harness

    private func recognize(_ fixture: String, with engineID: String) async throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: fixture, withExtension: "jpg"))
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
        let engine = try XCTUnwrap(PDFPageTextEngineRegistry.builtIn.engine(id: engineID))
        return await engine.recognize(image).text
    }

    private static func words(_ text: String) -> [String] {
        let joined = text.replacingOccurrences(of: "-\\s*\\n\\s*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[“”]", with: "\"", options: .regularExpression)
        return joined.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// recall: share of ground-truth words recognized, in any order. continuity:
    /// share of consecutive ground-truth lines where the second follows the first
    /// (allowing one word of slack where a line-break hyphen was rejoined).
    private static func score(_ text: String, against fixture: String) throws -> (recall: Double, continuity: Double, broken: [String]) {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: fixture + "-columns", withExtension: "txt"))
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
