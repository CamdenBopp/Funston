import XCTest
@testable import Funston

/// The ZIP shapes real books arrive in: Info-ZIP, Finder, forced ZIP64,
/// Python's streaming writer, and the damaged copies of each.
final class EPUBZipReaderTests: XCTestCase {
    private let big = Data((0..<266_669).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 7)) })

    private func infoZipShape() -> ZipFixture {
        ZipFixture([
            ZipFixture.Entry("mimetype", text: "application/epub+zip", deflate: false),
            ZipFixture.Entry("a.txt", text: String(repeating: "a", count: 99)),
            ZipFixture.Entry("b.txt", big),
            ZipFixture.Entry("sub/ünïcode name.txt", text: "ünïcode")
        ])
    }

    func testInfoZipShapedArchiveListsEntriesAndExtractsWithGoodCRCs() throws {
        let reader = try EPUBZipReader(data: infoZipShape().build())
        XCTAssertEqual(reader.entries.map(\.name), ["mimetype", "a.txt", "b.txt", "sub/ünïcode name.txt"])
        XCTAssertEqual(reader.firstEntryName, "mimetype")
        XCTAssertTrue(try XCTUnwrap(reader.entry(named: "mimetype")).isStored)
        XCTAssertTrue(try XCTUnwrap(reader.entry(named: "b.txt")).isDeflated)
        XCTAssertEqual(reader.entries.map(\.flags), [0, 0, 0, 0])
        XCTAssertEqual(try reader.contents(named: "b.txt"), big)
        XCTAssertEqual(try reader.contents(named: "mimetype"), Data("application/epub+zip".utf8))
        XCTAssertEqual(try reader.contents(named: "sub/ünïcode name.txt"), Data("ünïcode".utf8))
        XCTAssertNil(try reader.contents(named: "missing.txt"))
        XCTAssertTrue(reader.diagnostics.isEmpty)
    }

    func testFinderShapedArchiveSkipsDirectoriesAndResourceForksAndTrustsTheCentralDirectory() throws {
        var fixture = ZipFixture([
            .directory("book"),
            ZipFixture.Entry("book/mimetype", text: "application/epub+zip", deflate: false),
            .directory("__MACOSX"),
            .directory("__MACOSX/book"),
            ZipFixture.Entry("__MACOSX/book/._mimetype", text: "fork"),
            ZipFixture.Entry("book/a.txt", text: "alpha"),
            ZipFixture.Entry("book/b.txt", big)
        ])
        for index in fixture.entries.indices { fixture.entries[index].dataDescriptor = true }
        let reader = try EPUBZipReader(data: fixture.build())
        XCTAssertEqual(reader.entries.map(\.name), ["book/mimetype", "book/a.txt", "book/b.txt"])
        XCTAssertEqual(reader.firstEntryName, "book/")
        XCTAssertTrue(reader.entries.allSatisfy(\.hasDataDescriptor))
        XCTAssertEqual(try reader.contents(named: "book/b.txt"), big, "Sizes and CRC must come from the central directory, not the zeroed local header")
        XCTAssertEqual(try reader.contents(named: "book/a.txt"), Data("alpha".utf8))
    }

    func testZip64ArchiveReadsThroughTheZip64EndRecordAndExtraFields() throws {
        var fixture = infoZipShape()
        for index in fixture.entries.indices { fixture.entries[index].forceZip64 = true }
        fixture.zip64EndRecord = true
        let reader = try EPUBZipReader(data: fixture.build())
        XCTAssertEqual(reader.entries.count, 4)
        XCTAssertTrue(reader.entries.allSatisfy(\.usedZip64))
        XCTAssertEqual(try reader.contents(named: "b.txt"), big)
        XCTAssertEqual(try reader.contents(named: "a.txt"), Data(String(repeating: "a", count: 99).utf8))
    }

    func testZip64MarkersWithoutTheRecordAreRejected() {
        var fixture = infoZipShape()
        fixture.fakeZip64Markers = true
        XCTAssertThrowsError(try EPUBZipReader(data: fixture.build())) { error in
            XCTAssertEqual(error as? EPUBZipError, .zip64RecordMissing)
        }
    }

    func testPythonShapedArchiveWithStreamedZip64EntryAndUTF8Flag() throws {
        var streamed = ZipFixture.Entry("streamed.txt", text: "streamed", deflate: false)
        streamed.forceZip64 = true
        var unicode = ZipFixture.Entry("sub/ünïcode name.txt", text: "ü")
        unicode.utf8Flag = true
        let reader = try EPUBZipReader(data: ZipFixture([
            ZipFixture.Entry("mimetype", text: "application/epub+zip", deflate: false),
            ZipFixture.Entry("a.txt", text: "a"),
            streamed, unicode
        ]).build())
        XCTAssertEqual(try reader.contents(named: "streamed.txt"), Data("streamed".utf8))
        XCTAssertTrue(try XCTUnwrap(reader.entry(named: "sub/ünïcode name.txt")).isNamedAsUTF8)
        XCTAssertEqual(try reader.contents(named: "sub/ünïcode name.txt"), Data("ü".utf8))
    }

    func testTruncatedEmptyAndTinyFilesAreNotZips() {
        let whole = infoZipShape().build()
        for data in [whole.prefix(whole.count - 100), Data(), Data(repeating: 0, count: 23)] {
            XCTAssertThrowsError(try EPUBZipReader(data: Data(data))) { error in
                XCTAssertEqual(error as? EPUBZipError, .notAZip)
            }
        }
    }

    func testCorruptedCompressedByteFailsOnlyThatEntry() throws {
        var bytes = infoZipShape().build()
        let clean = try EPUBZipReader(data: bytes)
        let entry = try XCTUnwrap(clean.entry(named: "b.txt"))
        let dataStart = Int(entry.localHeaderOffset) + 30 + "b.txt".utf8.count
        bytes[dataStart + 1000] ^= 0xFF
        let reader = try EPUBZipReader(data: bytes)
        XCTAssertThrowsError(try reader.contents(named: "b.txt")) { error in
            let failure = error as? EPUBZipError
            XCTAssertTrue(failure == .corruptEntry || failure == .crcMismatch, "\(String(describing: failure))")
        }
        XCTAssertEqual(try reader.contents(named: "a.txt"), Data(String(repeating: "a", count: 99).utf8))
    }

    func testFlippedByteInAStoredEntryIsACRCMismatch() throws {
        var bytes = ZipFixture([ZipFixture.Entry("mimetype", text: "application/epub+zip", deflate: false)]).build()
        bytes[30 + "mimetype".utf8.count + 3] ^= 0x01
        let reader = try EPUBZipReader(data: bytes)
        XCTAssertThrowsError(try reader.contents(named: "mimetype")) { error in
            XCTAssertEqual(error as? EPUBZipError, .crcMismatch)
        }
    }

    func testEndRecordIsFoundBehindACommentContainingTheSignatureBytes() throws {
        var fixture = infoZipShape()
        fixture.comment = Data("comment PK\u{05}\u{06}\u{00}\u{00} with signature bytes".utf8)
        let reader = try EPUBZipReader(data: fixture.build())
        XCTAssertEqual(reader.entries.count, 4)
        XCTAssertEqual(try reader.contents(named: "a.txt"), Data(String(repeating: "a", count: 99).utf8))
    }

    func testDuplicateNamesKeepTheLastRecordWithADiagnostic() throws {
        let reader = try EPUBZipReader(data: ZipFixture([
            ZipFixture.Entry("x.txt", text: "first"),
            ZipFixture.Entry("x.txt", text: "second")
        ]).build())
        XCTAssertEqual(reader.entries.count, 1)
        XCTAssertEqual(try reader.contents(named: "x.txt"), Data("second".utf8))
        XCTAssertEqual(reader.diagnostics.count(code: "zip.duplicateEntry"), 1)
    }

    func testUnsupportedMethodAndEncryptionFailPerEntry() throws {
        var bzip = ZipFixture.Entry("bzip.txt", text: "x", deflate: false)
        bzip.methodOverride = 12
        var locked = ZipFixture.Entry("locked.txt", text: "x", deflate: false)
        locked.encryptedFlag = true
        let reader = try EPUBZipReader(data: ZipFixture([bzip, locked, ZipFixture.Entry("ok.txt", text: "ok")]).build())
        XCTAssertThrowsError(try reader.contents(named: "bzip.txt")) { XCTAssertEqual($0 as? EPUBZipError, .unsupportedMethod(12)) }
        XCTAssertThrowsError(try reader.contents(named: "locked.txt")) { XCTAssertEqual($0 as? EPUBZipError, .encryptedEntry) }
        XCTAssertEqual(try reader.contents(named: "ok.txt"), Data("ok".utf8))
    }

    func testNamesThatAreNotUTF8DecodeAsCP437WithADiagnostic() throws {
        var entry = ZipFixture.Entry("caf\u{E9}.txt", text: "x")
        entry.nameBytes = Array("caf".utf8) + [0x82] + Array(".txt".utf8)
        let reader = try EPUBZipReader(data: ZipFixture([entry]).build())
        XCTAssertEqual(reader.entries.first?.name, "café.txt")
        XCTAssertTrue(reader.diagnostics.contains(code: "zip.nameCP437"))
    }

    func testLeadingSlashesAreStrippedFromNames() throws {
        var entry = ZipFixture.Entry("/OEBPS/ch1.xhtml", text: "x")
        entry.nameBytes = Array("/OEBPS/ch1.xhtml".utf8)
        let reader = try EPUBZipReader(data: ZipFixture([entry]).build())
        XCTAssertNotNil(reader.entry(named: "OEBPS/ch1.xhtml"))
    }

    func testStoredEntryWithDisagreeingSizesIsCorrupt() throws {
        var bytes = ZipFixture([ZipFixture.Entry("a.txt", text: "abcd", deflate: false)]).build()
        // Central directory uncompressed size is at offset 24 of the central header.
        let central = bytes.count - 22 - 46 - "a.txt".utf8.count
        bytes[central + 24] = 9
        let reader = try EPUBZipReader(data: bytes)
        XCTAssertThrowsError(try reader.contents(named: "a.txt")) { XCTAssertEqual($0 as? EPUBZipError, .corruptEntry) }
    }

    func testInflateRejectsTruncatedAndOverlongStreams() throws {
        let compressed = ZipFixture.deflate(big)
        XCTAssertEqual(try EPUBInflate.inflate(compressed, declaredSize: big.count), big)
        XCTAssertThrowsError(try EPUBInflate.inflate(compressed.prefix(compressed.count / 2), declaredSize: big.count))
        XCTAssertThrowsError(try EPUBInflate.inflate(compressed, declaredSize: big.count - 1)) { XCTAssertEqual($0 as? EPUBInflate.Failure, .overlong) }
        XCTAssertThrowsError(try EPUBInflate.inflate(compressed, declaredSize: big.count + 1)) { XCTAssertEqual($0 as? EPUBInflate.Failure, .truncated) }
        XCTAssertEqual(try EPUBInflate.inflate(Data(), declaredSize: 0), Data())
    }
}
