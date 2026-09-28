import XCTest
import CoreMedia
@testable import ArchivePlayerCore

final class CaptionCEA608Tests: XCTestCase {
    private let time = CMTime(value: 10, timescale: 1)
    private func parity(_ byte: UInt8) -> UInt8 { byte.nonzeroBitCount % 2 == 1 ? byte : byte | 0x80 }
    private func send(_ a: UInt8, _ b: UInt8, to decoder: inout CEA608CaptionDecoder) throws -> CEA608CaptionEvent? {
        try decoder.consume(parity(a), parity(b), at: time)
    }
    func testPopOnSwapsAndDuplicateEOCDoesNotErase() throws {
        var decoder = CEA608CaptionDecoder()
        XCTAssertNil(try send(0x14, 0x20, to: &decoder))
        XCTAssertNil(try send(0x48, 0x49, to: &decoder))
        XCTAssertEqual(decoder.displayedText, "")
        let event = try send(0x14, 0x2f, to: &decoder)
        XCTAssertEqual(event?.text, "HI"); XCTAssertEqual(event?.time, time)
        XCTAssertNil(try send(0x14, 0x2f, to: &decoder))
        XCTAssertEqual(decoder.displayedText, "HI")
        XCTAssertEqual(try send(0x14, 0x2c, to: &decoder)?.text, "")
    }
    func testRollUpWindowAndErase() throws {
        var decoder = CEA608CaptionDecoder()
        _ = try send(0x14, 0x25, to: &decoder)
        _ = try send(0x41, 0x31, to: &decoder)
        _ = try send(0x14, 0x2d, to: &decoder)
        _ = try send(0x42, 0x32, to: &decoder)
        XCTAssertEqual(decoder.displayedText, "A1\nB2")
        _ = try send(0x14, 0x2d, to: &decoder)
        _ = try send(0x43, 0x33, to: &decoder)
        XCTAssertEqual(decoder.displayedText, "B2\nC3")
        decoder.reset(); XCTAssertEqual(decoder.displayedText, "")
    }
    func testPaintOnPACBackspaceAndColumnLimit() throws {
        var decoder = CEA608CaptionDecoder()
        _ = try send(0x14, 0x29, to: &decoder)
        _ = try send(0x14, 0x70, to: &decoder) // Row 15, indent 0.
        _ = try send(0x41, 0x42, to: &decoder)
        _ = try send(0x14, 0x21, to: &decoder)
        XCTAssertEqual(decoder.displayedText, "A")
        for _ in 0..<20 { _ = try send(0x43, 0x44, to: &decoder) }
        XCTAssertEqual(decoder.displayedText.count, 32)
        XCTAssertEqual(decoder.displayedText.last, "D")
    }
    func testParityChannelIsolationAndTransactionalErrors() throws {
        var decoder = CEA608CaptionDecoder()
        XCTAssertThrowsError(try decoder.consume(0, 0, at: time)) { XCTAssertEqual($0 as? CaptionError, .invalidParity) }
        _ = try send(0x1c, 0x29, to: &decoder)
        _ = try send(0x42, 0x42, to: &decoder)
        XCTAssertEqual(decoder.displayedText, "")
        _ = try send(0x14, 0x29, to: &decoder)
        _ = try send(0x41, 0x41, to: &decoder)
        XCTAssertThrowsError(try send(0x12, 0x20, to: &decoder))
        XCTAssertEqual(decoder.displayedText, "AA")
        XCTAssertThrowsError(try send(0x12, 0x20, to: &decoder))
    }
}
