import XCTest
@testable import Funston

/// The vectors of the standards study (section 9.7), the foliate study
/// (section 9) and the Readium streamer study (V-04, V-05).
final class EPUBFontDeobfuscationTests: XCTestCase {
    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }

    func testIDPFKeyIsSHA1OfTheIdentifierWithAllXMLWhitespaceRemoved() {
        XCTAssertEqual(hex(EPUBFontObfuscation.idpfKey(uniqueIdentifier: "ocf-font_obfuscation") ?? []), "b562e83e1606579a9c6c70a75f4a14d2ea36b09e")
        XCTAssertEqual(hex(EPUBFontObfuscation.idpfKey(uniqueIdentifier: "ocf-font_obfuscation-bis") ?? []), "67f12bb4154d714fbc8c681bbaae422116fbd137")
        let uuid = "urn:uuid:12345678-1234-1234-1234-123456789abc"
        XCTAssertEqual(hex(EPUBFontObfuscation.idpfKey(uniqueIdentifier: uuid) ?? []), "c12d11495401cf12256a830ecde8a78b17879cc3")
        XCTAssertEqual(hex(EPUBFontObfuscation.idpfKey(uniqueIdentifier: "  urn:uuid:1234 5678-1234-1234-1234-\t123456789abc\r\n") ?? []), "c12d11495401cf12256a830ecde8a78b17879cc3",
                       "Whitespace is removed everywhere, not only trimmed")
        XCTAssertEqual(hex(EPUBFontObfuscation.idpfKey(uniqueIdentifier: "urn:uuid:9f1c6a0e-2b7d-4c3e-8a5f-0123456789ab") ?? []), "0487e4aa817aef03a962b981bc8a63e7ce43d47b")
        XCTAssertNil(EPUBFontObfuscation.idpfKey(uniqueIdentifier: ""))
        XCTAssertNil(EPUBFontObfuscation.idpfKey(uniqueIdentifier: " \n"))
        XCTAssertNil(EPUBFontObfuscation.idpfKey(uniqueIdentifier: "urn:uuid:"))
    }

    func testAdobeKeyIsTheSixteenUUIDBytes() {
        XCTAssertEqual(hex(EPUBFontObfuscation.adobeKey(uniqueIdentifier: "urn:uuid:12345678-1234-1234-1234-123456789abc") ?? []), "12345678123412341234123456789abc")
        XCTAssertEqual(hex(EPUBFontObfuscation.adobeKey(uniqueIdentifier: "urn:uuid:9f1c6a0e-2b7d-4c3e-8a5f-0123456789ab") ?? []), "9f1c6a0e2b7d4c3e8a5f0123456789ab")
        XCTAssertEqual(hex(EPUBFontObfuscation.adobeKey(uniqueIdentifier: "9F1C6A0E-2B7D-4C3E-8A5F-0123456789AB") ?? []), "9f1c6a0e2b7d4c3e8a5f0123456789ab")
        XCTAssertNil(EPUBFontObfuscation.adobeKey(uniqueIdentifier: "http://www.gutenberg.org/ebooks/20512"))
        XCTAssertNil(EPUBFontObfuscation.adobeKey(uniqueIdentifier: "urn:uuid:"))
    }

    func testXORCoversTheDocumentedPrefixAndIsItsOwnInverse() {
        let key = bytes("c12d11495401cf12256a830ecde8a78b17879cc3")
        let header = Data(bytes("4f54544f00010000"))
        let obfuscated = EPUBFontObfuscation.apply(key: key, prefixLength: EPUBFontObfuscation.idpfPrefixLength, to: header)
        XCTAssertEqual(hex(Array(obfuscated)), "8e7945065400cf12")
        XCTAssertEqual(EPUBFontObfuscation.apply(key: key, prefixLength: EPUBFontObfuscation.idpfPrefixLength, to: obfuscated), header)
        let adobe = EPUBFontObfuscation.apply(key: bytes("12345678123412341234123412345678"), prefixLength: EPUBFontObfuscation.adobePrefixLength, to: header)
        XCTAssertEqual(hex(Array(adobe)), "5d60023712351234")

        var font = Data(repeating: 0x5A, count: 2000)
        let cycled = EPUBFontObfuscation.apply(key: key, prefixLength: 1040, to: font)
        XCTAssertEqual(cycled[1039], 0x5A ^ key[1039 % 20])
        XCTAssertEqual(cycled[1040], 0x5A, "Bytes after the prefix are untouched")
        font = Data(repeating: 0x5A, count: 10)
        XCTAssertEqual(EPUBFontObfuscation.apply(key: key, prefixLength: 1040, to: font).count, 10, "A short resource is XORed whole")
    }

    func testW3CTestFontDecodesWithTheRightKeyAndFailsTheHeaderCheckWithTheWrongOne() {
        var obfuscated = Data(bytes("b563e83e1617569a9c6870b7180e5194ea39b084"))
        obfuscated.append(Data(repeating: 0, count: 1100))
        switch EPUBFontObfuscation.decode(obfuscated, algorithm: EPUBFontObfuscation.idpfAlgorithm, uniqueIdentifier: "ocf-font_obfuscation") {
        case .success(let decoded):
            XCTAssertEqual(hex(Array(decoded.prefix(20))), "00010000001101000004001047444546000f001a")
            XCTAssertEqual(Int(decoded[4]) << 8 | Int(decoded[5]), 17, "Seventeen tables starting with GDEF")
        case .failure(let failure): XCTFail("\(failure)")
        }
        switch EPUBFontObfuscation.decode(obfuscated, algorithm: EPUBFontObfuscation.idpfAlgorithm, uniqueIdentifier: "ocf-font_obfuscation-bis") {
        case .success: XCTFail("The wrong key yields d292c38a..., which is not a font")
        case .failure(let failure): XCTAssertEqual(failure, .notAFont)
        }
        XCTAssertEqual(EPUBFontObfuscation.decode(obfuscated, algorithm: "urn:other", uniqueIdentifier: "x"), .failure(.unknownAlgorithm("urn:other")))
        XCTAssertEqual(EPUBFontObfuscation.decode(obfuscated, algorithm: EPUBFontObfuscation.idpfAlgorithm, uniqueIdentifier: ""), .failure(.noKey))
    }

    func testHeaderCheckAcceptsEverySfntFlavourAndRejectsImplausibleTableCounts() {
        func font(_ tag: String, tables: Int, woff: Bool = false) -> Data {
            var data = Data(tag.utf8)
            if woff {
                data.append(contentsOf: [0, 1, 0, 0, 0, 0, 0, 0, UInt8(tables >> 8), UInt8(tables & 0xFF), 0, 0])
            } else {
                data.append(contentsOf: [UInt8(tables >> 8), UInt8(tables & 0xFF)])
            }
            data.append(Data(repeating: 0, count: 32))
            return data
        }
        XCTAssertTrue(EPUBFontObfuscation.looksLikeFont(font("\u{0}\u{1}\u{0}\u{0}", tables: 17)))
        XCTAssertTrue(EPUBFontObfuscation.looksLikeFont(font("OTTO", tables: 9)))
        XCTAssertTrue(EPUBFontObfuscation.looksLikeFont(font("true", tables: 12)))
        XCTAssertTrue(EPUBFontObfuscation.looksLikeFont(font("wOFF", tables: 12, woff: true)))
        XCTAssertTrue(EPUBFontObfuscation.looksLikeFont(font("wOF2", tables: 12, woff: true)))
        XCTAssertFalse(EPUBFontObfuscation.looksLikeFont(font("OTTO", tables: 858)))
        XCTAssertFalse(EPUBFontObfuscation.looksLikeFont(font("OTTO", tables: 0)))
        XCTAssertFalse(EPUBFontObfuscation.looksLikeFont(Data("not a font at all".utf8)))
        XCTAssertFalse(EPUBFontObfuscation.looksLikeFont(Data()))
    }
}
