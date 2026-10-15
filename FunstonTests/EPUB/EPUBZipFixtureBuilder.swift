import Compression
import Foundation
import zlib

/// Writes ZIP archives in memory so tests control every field: the mimetype
/// order, compression, data descriptors, ZIP64 records, name flags and
/// directory entries. Nothing a test needs comes from a file on disk.
struct ZipFixture {
    struct Entry {
        var name: String
        var data: Data
        var deflate = true
        /// Write zero sizes and CRC in the local header and a descriptor after the data, as Finder does.
        var dataDescriptor = false
        var utf8Flag = false
        /// Write 0xFFFFFFFF sizes and offset with a ZIP64 extra field, as `zip -fz` and Python's streaming writer do.
        var forceZip64 = false
        var encryptedFlag = false
        var localExtra = Data()
        /// A compression method the reader does not support, written as-is with the data stored.
        var methodOverride: UInt16? = nil
        /// Raw name bytes, for names that are not UTF-8.
        var nameBytes: [UInt8]? = nil

        init(_ name: String, _ data: Data, deflate: Bool = true) { self.name = name; self.data = data; self.deflate = deflate }
        init(_ name: String, text: String, deflate: Bool = true) { self.init(name, Data(text.utf8), deflate: deflate) }
        static func directory(_ name: String) -> Entry { Entry(name.hasSuffix("/") ? name : name + "/", Data(), deflate: false) }
    }

    var entries: [Entry]
    var comment = Data()
    /// Write the ZIP64 end record and locator and all-ones fields in the end record.
    var zip64EndRecord = false
    /// Write all-ones fields in the end record without any ZIP64 record (a broken archive).
    var fakeZip64Markers = false

    init(_ entries: [Entry]) { self.entries = entries }

    func build() -> Data {
        var output = Data()
        var central = Data()
        var count = 0
        for entry in entries {
            let isDirectory = entry.name.hasSuffix("/")
            let payload: Data
            let method: UInt16
            if let override = entry.methodOverride { payload = entry.data; method = override }
            else if entry.deflate && !isDirectory && !entry.data.isEmpty { payload = Self.deflate(entry.data); method = 8 }
            else { payload = entry.data; method = 0 }
            let crc = Self.crc32(entry.data)
            var flags: UInt16 = 0
            if entry.dataDescriptor { flags |= 0x0008 }
            if entry.utf8Flag { flags |= 0x0800 }
            if entry.encryptedFlag { flags |= 0x0001 }
            let nameBytes = entry.nameBytes ?? Array(entry.name.utf8)
            let localOffset = output.count
            var localExtra = entry.localExtra
            if entry.forceZip64 {
                localExtra.append(Self.zip64Extra(uncompressed: UInt64(entry.data.count), compressed: UInt64(payload.count), offset: nil))
            }
            output.append(Self.u32(0x0403_4b50))
            output.append(Self.u16(entry.forceZip64 ? 45 : 20))
            output.append(Self.u16(flags))
            output.append(Self.u16(method))
            output.append(Self.u16(0)); output.append(Self.u16(0x21))
            output.append(Self.u32(entry.dataDescriptor ? 0 : crc))
            if entry.forceZip64 {
                output.append(Self.u32(0xFFFF_FFFF)); output.append(Self.u32(0xFFFF_FFFF))
            } else {
                output.append(Self.u32(entry.dataDescriptor ? 0 : UInt32(payload.count)))
                output.append(Self.u32(entry.dataDescriptor ? 0 : UInt32(entry.data.count)))
            }
            output.append(Self.u16(UInt16(nameBytes.count)))
            output.append(Self.u16(UInt16(localExtra.count)))
            output.append(contentsOf: nameBytes)
            output.append(localExtra)
            output.append(payload)
            if entry.dataDescriptor {
                output.append(Self.u32(0x0807_4b50))
                output.append(Self.u32(crc))
                if entry.forceZip64 {
                    output.append(Self.u64(UInt64(payload.count))); output.append(Self.u64(UInt64(entry.data.count)))
                } else {
                    output.append(Self.u32(UInt32(payload.count))); output.append(Self.u32(UInt32(entry.data.count)))
                }
            }
            var centralExtra = Data()
            if entry.forceZip64 {
                centralExtra.append(Self.zip64Extra(uncompressed: UInt64(entry.data.count), compressed: UInt64(payload.count), offset: UInt64(localOffset)))
            }
            central.append(Self.u32(0x0201_4b50))
            central.append(Self.u16(0x031E))
            central.append(Self.u16(entry.forceZip64 ? 45 : 20))
            central.append(Self.u16(flags))
            central.append(Self.u16(method))
            central.append(Self.u16(0)); central.append(Self.u16(0x21))
            central.append(Self.u32(crc))
            if entry.forceZip64 {
                central.append(Self.u32(0xFFFF_FFFF)); central.append(Self.u32(0xFFFF_FFFF))
            } else {
                central.append(Self.u32(UInt32(payload.count))); central.append(Self.u32(UInt32(entry.data.count)))
            }
            central.append(Self.u16(UInt16(nameBytes.count)))
            central.append(Self.u16(UInt16(centralExtra.count)))
            central.append(Self.u16(0))
            central.append(Self.u16(0)); central.append(Self.u16(0))
            central.append(Self.u32(isDirectory ? 0x10 : 0))
            central.append(Self.u32(entry.forceZip64 ? 0xFFFF_FFFF : UInt32(localOffset)))
            central.append(contentsOf: nameBytes)
            central.append(centralExtra)
            count += 1
        }
        let directoryOffset = output.count
        output.append(central)
        if zip64EndRecord {
            let recordOffset = output.count
            output.append(Self.u32(0x0606_4b50))
            output.append(Self.u64(44))
            output.append(Self.u16(45)); output.append(Self.u16(45))
            output.append(Self.u32(0)); output.append(Self.u32(0))
            output.append(Self.u64(UInt64(count))); output.append(Self.u64(UInt64(count)))
            output.append(Self.u64(UInt64(central.count)))
            output.append(Self.u64(UInt64(directoryOffset)))
            output.append(Self.u32(0x0706_4b50))
            output.append(Self.u32(0))
            output.append(Self.u64(UInt64(recordOffset)))
            output.append(Self.u32(1))
        }
        let allOnes = zip64EndRecord || fakeZip64Markers
        output.append(Self.u32(0x0605_4b50))
        output.append(Self.u16(0)); output.append(Self.u16(0))
        output.append(Self.u16(allOnes ? 0xFFFF : UInt16(count)))
        output.append(Self.u16(allOnes ? 0xFFFF : UInt16(count)))
        output.append(Self.u32(allOnes ? 0xFFFF_FFFF : UInt32(central.count)))
        output.append(Self.u32(allOnes ? 0xFFFF_FFFF : UInt32(directoryOffset)))
        output.append(Self.u16(UInt16(comment.count)))
        output.append(comment)
        return output
    }

    private static func zip64Extra(uncompressed: UInt64, compressed: UInt64, offset: UInt64?) -> Data {
        var field = Data()
        field.append(u64(uncompressed)); field.append(u64(compressed))
        if let offset { field.append(u64(offset)) }
        var extra = Data()
        extra.append(u16(0x0001)); extra.append(u16(UInt16(field.count))); extra.append(field)
        return extra
    }

    static func deflate(_ data: Data) -> Data {
        let capacity = max(64, data.count * 2)
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return compression_encode_buffer(destination, capacity, base.assumingMemoryBound(to: UInt8.self), raw.count, nil, COMPRESSION_ZLIB)
        }
        precondition(written > 0, "Fixture deflate failed")
        return Data(bytes: destination, count: written)
    }

    static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw -> UInt32 in
            guard let base = raw.baseAddress, raw.count > 0 else { return 0 }
            return UInt32(zlib.crc32(0, base.assumingMemoryBound(to: Bytef.self), uInt(raw.count)))
        }
    }

    static func u16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
    static func u32(_ value: UInt32) -> Data { u16(UInt16(value & 0xFFFF)) + u16(UInt16(value >> 16)) }
    static func u64(_ value: UInt64) -> Data { u32(UInt32(value & 0xFFFF_FFFF)) + u32(UInt32(value >> 32)) }
}

/// Builds EPUB archives from a dictionary of entry name to bytes: the
/// mimetype first and stored, everything else deflated.
enum EPUBFixture {
    static let mimetype = "application/epub+zip"

    static func archive(_ files: [(String, String)], mimetype: String? = mimetype, mimetypeFirst: Bool = true, mimetypeDeflated: Bool = false) -> Data {
        var entries: [ZipFixture.Entry] = files.map { ZipFixture.Entry($0.0, text: $0.1) }
        if let mimetype {
            let entry = ZipFixture.Entry("mimetype", text: mimetype, deflate: mimetypeDeflated)
            if mimetypeFirst { entries.insert(entry, at: 0) } else { entries.append(entry) }
        }
        return ZipFixture(entries).build()
    }

    static let container = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """

    static func container(rootfiles: [(path: String, mediaType: String?)]) -> String {
        let items = rootfiles.map { file in
            let type = file.mediaType.map { " media-type=\"\($0)\"" } ?? ""
            return "<rootfile full-path=\"\(file.path)\"\(type)/>"
        }.joined()
        return "<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles>\(items)</rootfiles></container>"
    }

    /// A minimal EPUB 3 package with one chapter.
    static func package(identifier: String = "urn:uuid:12345678-1234-1234-1234-123456789abc", extraMetadata: String = "", extraManifest: String = "", spineExtra: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="pub-id">\(identifier)</dc:identifier>
            <dc:title>Fixture</dc:title>
            <dc:language>en</dc:language>
            <meta property="dcterms:modified">2026-10-15T00:00:00Z</meta>
            \(extraMetadata)
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            \(extraManifest)
          </manifest>
          <spine>
            <itemref idref="ch1"/>
            \(spineExtra)
          </spine>
        </package>
        """
    }

    static let nav = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head>
    <body><nav epub:type="toc"><ol><li><a href="ch1.xhtml">Chapter 1</a></li></ol></nav></body></html>
    """

    static func chapter(_ body: String, title: String = "Chapter") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>\(title)</title></head>
        <body>\(body)</body></html>
        """
    }

    /// The canonical minimal book.
    static func minimalBook(chapterBody: String = "<p>Hello, world.</p>") -> Data {
        archive([
            ("META-INF/container.xml", container),
            ("OEBPS/content.opf", package()),
            ("OEBPS/nav.xhtml", nav),
            ("OEBPS/ch1.xhtml", chapter(chapterBody))
        ])
    }
}
