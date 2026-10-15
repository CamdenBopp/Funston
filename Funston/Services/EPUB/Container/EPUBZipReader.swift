import Foundation
import zlib

/// One file in the archive, as the central directory describes it. Sizes, the
/// CRC and the method always come from here; the local header is read only to
/// find where the data starts, because Finder and streaming writers leave the
/// local sizes at zero or all-ones.
struct EPUBZipEntry: Sendable, Hashable {
    let name: String
    let method: UInt16
    let flags: UInt16
    let crc32: UInt32
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64
    let usedZip64: Bool

    var isEncrypted: Bool { flags & 0x0001 != 0 }
    var hasDataDescriptor: Bool { flags & 0x0008 != 0 }
    var isNamedAsUTF8: Bool { flags & 0x0800 != 0 }
    var isStored: Bool { method == EPUBZipReader.storedMethod }
    var isDeflated: Bool { method == EPUBZipReader.deflatedMethod }
}

enum EPUBZipError: Error, Equatable {
    /// No end-of-central-directory record: not a ZIP at all, or shorter than one.
    case notAZip
    /// The central directory or an entry's data lies beyond the end of the file.
    case truncated
    /// Sizes or offsets say ZIP64 but the ZIP64 records are missing or short.
    case zip64RecordMissing
    case centralDirectoryCorrupt
    case tooManyEntries
    case unsupportedMethod(UInt16)
    case encryptedEntry
    case entryTooLarge
    case crcMismatch
    case corruptEntry
}

/// A memory-mapped ZIP reader over the central directory. Entries are inflated
/// on demand and never written to disk. The format is PKWARE's APPNOTE; the
/// numbers below are its field offsets.
final class EPUBZipReader: Sendable {
    static let storedMethod: UInt16 = 0
    static let deflatedMethod: UInt16 = 8
    static let localHeaderSignature: UInt32 = 0x0403_4b50
    static let centralHeaderSignature: UInt32 = 0x0201_4b50
    static let endRecordSignature: UInt32 = 0x0605_4b50
    static let zip64LocatorSignature: UInt32 = 0x0706_4b50
    static let zip64EndRecordSignature: UInt32 = 0x0606_4b50
    static let endRecordLength = 22
    static let maximumCommentLength = 65_535
    static let zip64LocatorLength = 20
    static let centralHeaderLength = 46
    static let localHeaderLength = 30
    static let zip64ExtraFieldID: UInt16 = 0x0001
    static let allOnes16: UInt16 = 0xFFFF
    static let allOnes32: UInt32 = 0xFFFF_FFFF
    /// A hostile archive can declare millions of entries; nothing Funston opens needs more.
    static let maximumEntryCount = 100_000
    /// The largest single entry the reader will hold in memory.
    static let maximumEntryBytes: UInt64 = 256 * 1024 * 1024
    static let resourceForkDirectory = "__MACOSX/"

    let data: Data
    /// Every readable entry in central directory order: directories and
    /// resource forks are dropped, a duplicate name keeps its last record.
    let entries: [EPUBZipEntry]
    /// The name of the first central directory record before any filtering,
    /// which is what the mimetype rule asks about.
    let firstEntryName: String?
    let diagnostics: EPUBDiagnosticList
    private let indexByName: [String: Int]

    convenience init(contentsOf url: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: url, options: .alwaysMapped) } catch { throw EPUBZipError.notAZip }
        try self.init(data: data)
    }

    init(data: Data) throws {
        self.data = data
        var diagnostics = EPUBDiagnosticList()
        let count = data.count
        guard count >= Self.endRecordLength else { throw EPUBZipError.notAZip }
        let end = try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> Int in
            let lowest = max(0, count - Self.endRecordLength - Self.maximumCommentLength)
            var offset = count - Self.endRecordLength
            while offset >= lowest {
                if Self.u32(raw, offset) == Self.endRecordSignature,
                   Int(Self.u16(raw, offset + 20)) == count - Self.endRecordLength - offset {
                    return offset
                }
                offset -= 1
            }
            throw EPUBZipError.notAZip
        }
        var entryCount = UInt64(data.withUnsafeBytes { Self.u16($0, end + 10) })
        var directorySize = UInt64(data.withUnsafeBytes { Self.u32($0, end + 12) })
        var directoryOffset = UInt64(data.withUnsafeBytes { Self.u32($0, end + 16) })
        let needsZip64 = entryCount == UInt64(Self.allOnes16) || directorySize == UInt64(Self.allOnes32) || directoryOffset == UInt64(Self.allOnes32)
        let hasLocator = end >= Self.zip64LocatorLength && data.withUnsafeBytes { Self.u32($0, end - Self.zip64LocatorLength) == Self.zip64LocatorSignature }
        if hasLocator {
            let recordOffset = data.withUnsafeBytes { Self.u64($0, end - Self.zip64LocatorLength + 8) }
            guard recordOffset < UInt64(count), Int(recordOffset) + 56 <= count,
                  data.withUnsafeBytes({ Self.u32($0, Int(recordOffset)) == Self.zip64EndRecordSignature }) else {
                throw EPUBZipError.zip64RecordMissing
            }
            let record = Int(recordOffset)
            entryCount = data.withUnsafeBytes { Self.u64($0, record + 32) }
            directorySize = data.withUnsafeBytes { Self.u64($0, record + 40) }
            directoryOffset = data.withUnsafeBytes { Self.u64($0, record + 48) }
        } else if needsZip64 {
            throw EPUBZipError.zip64RecordMissing
        }
        guard entryCount <= UInt64(Self.maximumEntryCount) else { throw EPUBZipError.tooManyEntries }
        guard directoryOffset < UInt64(count), directorySize <= UInt64(count), directoryOffset + directorySize <= UInt64(count) else {
            throw EPUBZipError.truncated
        }

        var parsed: [EPUBZipEntry] = []
        var firstName: String?
        var index: [String: Int] = [:]
        var position = Int(directoryOffset)
        let directoryEnd = Int(directoryOffset + directorySize)
        for _ in 0..<Int(entryCount) {
            guard position + Self.centralHeaderLength <= directoryEnd,
                  data.withUnsafeBytes({ Self.u32($0, position) == Self.centralHeaderSignature }) else {
                throw EPUBZipError.centralDirectoryCorrupt
            }
            let (entry, rawName, next) = try data.withUnsafeBytes { raw throws -> (EPUBZipEntry, [UInt8], Int) in
                let flags = Self.u16(raw, position + 8)
                let method = Self.u16(raw, position + 10)
                let crc = Self.u32(raw, position + 16)
                var compressed = UInt64(Self.u32(raw, position + 20))
                var uncompressed = UInt64(Self.u32(raw, position + 24))
                let nameLength = Int(Self.u16(raw, position + 28))
                let extraLength = Int(Self.u16(raw, position + 30))
                let commentLength = Int(Self.u16(raw, position + 32))
                var localOffset = UInt64(Self.u32(raw, position + 42))
                let nameStart = position + Self.centralHeaderLength
                guard nameStart + nameLength + extraLength + commentLength <= directoryEnd else { throw EPUBZipError.centralDirectoryCorrupt }
                let nameBytes = Array(raw[nameStart..<nameStart + nameLength])
                var usedZip64 = false
                var extra = nameStart + nameLength
                let extraEnd = extra + extraLength
                while extra + 4 <= extraEnd {
                    let id = Self.u16(raw, extra), size = Int(Self.u16(raw, extra + 2))
                    guard extra + 4 + size <= extraEnd else { throw EPUBZipError.centralDirectoryCorrupt }
                    if id == Self.zip64ExtraFieldID {
                        var field = extra + 4
                        let fieldEnd = field + size
                        func take() throws -> UInt64 {
                            guard field + 8 <= fieldEnd else { throw EPUBZipError.zip64RecordMissing }
                            defer { field += 8 }
                            return Self.u64(raw, field)
                        }
                        if uncompressed == UInt64(Self.allOnes32) { uncompressed = try take(); usedZip64 = true }
                        if compressed == UInt64(Self.allOnes32) { compressed = try take(); usedZip64 = true }
                        if localOffset == UInt64(Self.allOnes32) { localOffset = try take(); usedZip64 = true }
                    }
                    extra += 4 + size
                }
                let entry = EPUBZipEntry(name: "", method: method, flags: flags, crc32: crc, compressedSize: compressed,
                                         uncompressedSize: uncompressed, localHeaderOffset: localOffset, usedZip64: usedZip64)
                return (entry, nameBytes, extraEnd + commentLength)
            }
            position = next
            let (decoded, nameDiagnostic) = Self.decodeName(rawName, flaggedUTF8: entry.isNamedAsUTF8)
            if let nameDiagnostic { diagnostics.record(.zip, nameDiagnostic, path: decoded, "Entry name was not valid UTF-8; decoded as CP437.") }
            if firstName == nil { firstName = decoded }
            var name = decoded
            while name.hasPrefix("/") { name.removeFirst() }
            if name.isEmpty || name.hasSuffix("/") || name.hasPrefix(Self.resourceForkDirectory) { continue }
            let named = EPUBZipEntry(name: name, method: entry.method, flags: entry.flags, crc32: entry.crc32,
                                     compressedSize: entry.compressedSize, uncompressedSize: entry.uncompressedSize,
                                     localHeaderOffset: entry.localHeaderOffset, usedZip64: entry.usedZip64)
            if let existing = index[name] {
                diagnostics.record(.zip, "zip.duplicateEntry", path: name, "The archive lists this name twice; the last record is used.")
                parsed[existing] = named
            } else {
                index[name] = parsed.count
                parsed.append(named)
            }
        }
        entries = parsed
        firstEntryName = firstName
        indexByName = index
        self.diagnostics = diagnostics
    }

    func entry(named name: String) -> EPUBZipEntry? {
        indexByName[name].map { entries[$0] }
    }

    /// Case-insensitive lookup, for the href fallbacks; exact matches win.
    func entry(matchingCaseInsensitively name: String) -> EPUBZipEntry? {
        if let exact = entry(named: name) { return exact }
        let folded = name.lowercased()
        return entries.first { $0.name.lowercased() == folded }
    }

    func contents(named name: String) throws -> Data? {
        guard let entry = entry(named: name) else { return nil }
        return try contents(of: entry)
    }

    /// The inflated, CRC-checked bytes of an entry.
    func contents(of entry: EPUBZipEntry) throws -> Data {
        guard !entry.isEncrypted else { throw EPUBZipError.encryptedEntry }
        guard entry.uncompressedSize <= Self.maximumEntryBytes, entry.compressedSize <= Self.maximumEntryBytes else {
            throw EPUBZipError.entryTooLarge
        }
        let count = data.count
        let local = Int(entry.localHeaderOffset)
        guard entry.localHeaderOffset < UInt64(count), local + Self.localHeaderLength <= count,
              data.withUnsafeBytes({ Self.u32($0, local) == Self.localHeaderSignature }) else {
            throw EPUBZipError.truncated
        }
        let dataStart = data.withUnsafeBytes { raw in local + Self.localHeaderLength + Int(Self.u16(raw, local + 26)) + Int(Self.u16(raw, local + 28)) }
        let dataEnd = dataStart + Int(entry.compressedSize)
        guard dataEnd <= count else { throw EPUBZipError.truncated }
        let raw = data.subdata(in: (data.startIndex + dataStart)..<(data.startIndex + dataEnd))
        let bytes: Data
        switch entry.method {
        case Self.storedMethod:
            guard entry.compressedSize == entry.uncompressedSize else { throw EPUBZipError.corruptEntry }
            bytes = raw
        case Self.deflatedMethod:
            do { bytes = try EPUBInflate.inflate(raw, declaredSize: Int(entry.uncompressedSize)) }
            catch { throw EPUBZipError.corruptEntry }
        default:
            throw EPUBZipError.unsupportedMethod(entry.method)
        }
        guard Self.crc32(of: bytes) == entry.crc32 else { throw EPUBZipError.crcMismatch }
        return bytes
    }

    static func crc32(of bytes: Data) -> UInt32 {
        bytes.withUnsafeBytes { raw -> UInt32 in
            guard let base = raw.baseAddress, raw.count > 0 else { return 0 }
            return UInt32(zlib.crc32(0, base.assumingMemoryBound(to: Bytef.self), uInt(raw.count)))
        }
    }

    /// Names flagged UTF-8 are UTF-8; unflagged names are UTF-8 when they decode
    /// and CP437 otherwise, because Info-ZIP and Finder write UTF-8 without the flag.
    static func decodeName(_ bytes: [UInt8], flaggedUTF8: Bool) -> (String, String?) {
        if let utf8 = String(bytes: bytes, encoding: .utf8) { return (utf8, nil) }
        let cp437 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue))
        let fallback = String(bytes: bytes, encoding: String.Encoding(rawValue: cp437)) ?? String(decoding: bytes, as: UTF8.self)
        return (fallback, flaggedUTF8 ? "zip.nameNotUTF8" : "zip.nameCP437")
    }

    static func u16(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt16 {
        UInt16(raw[offset]) | UInt16(raw[offset + 1]) << 8
    }
    static func u32(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(u16(raw, offset)) | UInt32(u16(raw, offset + 2)) << 16
    }
    static func u64(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt64 {
        UInt64(u32(raw, offset)) | UInt64(u32(raw, offset + 4)) << 32
    }
}
