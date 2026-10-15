import XCTest
@testable import Funston

/// Spec 19.1 and 19.3: the problems screen shows every diagnostic, the
/// book cap refuses declared-size bombs, and the chapter build and layout
/// budgets degrade to plain text with a diagnostic instead of hanging.
@MainActor
final class EPUBLimitsTests: XCTestCase {
    private let contentSize = CGSize(width: 320, height: 480)

    func testProblemsScreenListsEveryDiagnosticWithItsPlaceAndCount() {
        var list = EPUBDiagnosticList()
        XCTAssertEqual(EPUBProblemsController.rows(for: list).map(\.title), [EPUBProblemsController.emptyTitle])
        list.record(.container, "mimetype.missing", path: "mimetype", "The archive has no mimetype entry.")
        list.record(EPUBDiagnostic(stage: .css, code: "css.ignoredProperty", path: "OEBPS/style.css", spineIndex: nil, message: "The property float is not honoured.", count: 63))
        list.record(.chapterRecover, "xml.tagsoup", path: "OEBPS/ch2.xhtml", spineIndex: 1, "Not well-formed XML; recovered as HTML.")
        let rows = EPUBProblemsController.rows(for: list)
        XCTAssertEqual(rows.map(\.title), ["The archive has no mimetype entry.", "The property float is not honoured.", "Not well-formed XML; recovered as HTML."])
        XCTAssertEqual(rows[0].subtitle, "container mimetype.missing, mimetype")
        XCTAssertEqual(rows[1].subtitle, "css css.ignoredProperty, OEBPS/style.css, 63 times")
        XCTAssertEqual(rows[2].subtitle, "chapter.recover xml.tagsoup, OEBPS/ch2.xhtml, spine item 2")
        XCTAssertTrue(rows.allSatisfy { !$0.navigates })
    }

    func testStandardLimitsDeriveTheBookCapFromAvailableMemoryWithAFloor() {
        let small = EPUBWorkLimits.derived(availableMemory: 1024)
        XCTAssertEqual(small.bookBytes, EPUBWorkLimits.minimumBookBytes, "Tiny or unknown memory keeps the floor")
        let phone = EPUBWorkLimits.derived(availableMemory: 3 * 1024 * 1024 * 1024)
        XCTAssertEqual(phone.bookBytes, 3 * 1024 * 1024 * 1024 * EPUBWorkLimits.bookBytesPerAvailableByte)
        XCTAssertEqual(EPUBWorkLimits.derived(availableMemory: .max).bookBytes, .max, "An overflow never wraps to a small cap")
        XCTAssertGreaterThanOrEqual(EPUBWorkLimits.standard.bookBytes, EPUBWorkLimits.minimumBookBytes)
    }

    func testABookWhoseDeclaredSizesExceedTheCapIsRefusedBeforeAnyEntryIsInflated() throws {
        let data = EPUBFixture.minimalBook()
        var limits = EPUBWorkLimits()
        limits.bookBytes = 64
        XCTAssertThrowsError(try EPUBZipReader(data: data, limits: limits)) { XCTAssertEqual($0 as? EPUBZipError, .bookTooLarge) }
        XCTAssertNoThrow(try EPUBZipReader(data: data), "The same archive is fine under the standard cap")
        XCTAssertThrowsError(try EPUBPublication.open(data: data, limits: limits)) { XCTAssertEqual($0 as? EPUBOpenFailure, .tooLarge) }
        XCTAssertEqual(EPUBOpenFailure.tooLarge.message, "This book is too large to open on this device.")
    }

    func testAnEntryOverTheEntryCapIsRefusedOnRead() throws {
        let publication = try EPUBPublication.open(data: EPUBFixture.minimalBook())
        var limits = EPUBWorkLimits()
        limits.entryBytes = 8
        let reader = try EPUBZipReader(data: EPUBFixture.minimalBook(), limits: limits)
        XCTAssertThrowsError(try reader.contents(named: "OEBPS/ch1.xhtml")) { XCTAssertEqual($0 as? EPUBZipError, .entryTooLarge) }
        XCTAssertEqual(try publication.zip.contents(named: "mimetype").map { String(decoding: $0, as: UTF8.self) }, "application/epub+zip")
    }

}
