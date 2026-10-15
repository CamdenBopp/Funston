import Foundation

/// What the OCF layer learns before the package document is parsed: which
/// package to open, which entries are encrypted or obfuscated, and whether the
/// book is protected by a scheme this reader cannot unlock.
struct EPUBContainerFile: Sendable {
    static let mimetypeEntryName = "mimetype"
    static let expectedMimetype = "application/epub+zip"
    static let containerPath = "META-INF/container.xml"
    static let encryptionPath = "META-INF/encryption.xml"
    static let lcpLicensePath = "META-INF/license.lcpl"
    static let appleDisplayOptionsPath = "META-INF/com.apple.ibooks.display-options.xml"
    static let koboDisplayOptionsPath = "META-INF/com.kobobooks.display-options.xml"
    static let packageMediaType = "application/oebps-package+xml"
    static let localHeaderMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]

    struct Rootfile: Sendable, Hashable {
        let fullPath: String
        let mediaType: String?
    }

    enum Protection: Sendable, Hashable { case lcp, adept }

    enum Refusal: Error, Equatable {
        /// Not a ZIP, or a ZIP with neither a container file nor exactly one package document.
        case notABook
        /// LCP or Adobe ADEPT key information: the content cannot be decrypted here.
        case protected(Protection)
    }

    let rootfiles: [Rootfile]
    /// The decoded, root-relative path of the package document to open.
    let packagePath: String
    /// Decoded entry path to the algorithm URI that encrypts or obfuscates it.
    let encryption: [String: String]
    /// `true` when an Apple or Kobo display-options file declares fixed layout.
    let displayOptionsFixedLayout: Bool?
    let diagnostics: EPUBDiagnosticList

    /// Paths of entries encrypted with something other than font obfuscation.
    var protectedPaths: Set<String> {
        Set(encryption.filter { !EPUBFontObfuscation.isObfuscationAlgorithm($0.value) }.keys)
    }

    static func read(from zip: EPUBZipReader) throws(Refusal) -> EPUBContainerFile {
        var diagnostics = EPUBDiagnosticList()
        diagnostics.merge(zip.diagnostics)
        guard zip.data.count >= localHeaderMagic.count, Array(zip.data.prefix(localHeaderMagic.count)) == localHeaderMagic else {
            throw .notABook
        }
        checkMimetype(zip, &diagnostics)
        if zip.entry(named: lcpLicensePath) != nil { throw .protected(.lcp) }
        let encryption = try readEncryption(zip, &diagnostics)
        let (rootfiles, packagePath) = try selectPackage(zip, &diagnostics)
        let fixedLayout = readDisplayOptions(zip, &diagnostics)
        return EPUBContainerFile(rootfiles: rootfiles, packagePath: packagePath, encryption: encryption,
                                 displayOptionsFixedLayout: fixedLayout, diagnostics: diagnostics)
    }

    // MARK: mimetype

    private static func checkMimetype(_ zip: EPUBZipReader, _ diagnostics: inout EPUBDiagnosticList) {
        guard let entry = zip.entry(named: mimetypeEntryName) else {
            diagnostics.record(.container, "mimetype.missing", path: mimetypeEntryName, "The archive has no mimetype entry.")
            return
        }
        if zip.firstEntryName != mimetypeEntryName {
            diagnostics.record(.container, "mimetype.notFirst", path: mimetypeEntryName, "The mimetype entry is not the first entry.")
        }
        if !entry.isStored {
            diagnostics.record(.container, "mimetype.compressed", path: mimetypeEntryName, "The mimetype entry is compressed.")
        }
        if localExtraFieldLength(zip, entry) > 0 {
            diagnostics.record(.container, "mimetype.extraField", path: mimetypeEntryName, "The mimetype entry carries an extra field.")
        }
        guard let bytes = try? zip.contents(of: entry) else {
            diagnostics.record(.container, "mimetype.unreadable", path: mimetypeEntryName, "The mimetype entry could not be read.")
            return
        }
        let text = String(decoding: bytes, as: UTF8.self)
        if text != expectedMimetype {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FEFF}", with: "")
            let code = trimmed == expectedMimetype ? "mimetype.padded" : "mimetype.content"
            diagnostics.record(.container, code, path: mimetypeEntryName, "The mimetype entry does not contain exactly application/epub+zip.")
        }
    }

    private static func localExtraFieldLength(_ zip: EPUBZipReader, _ entry: EPUBZipEntry) -> Int {
        let local = Int(entry.localHeaderOffset)
        guard entry.localHeaderOffset < UInt64(zip.data.count), local + EPUBZipReader.localHeaderLength <= zip.data.count else { return 0 }
        return zip.data.withUnsafeBytes { Int(EPUBZipReader.u16($0, local + 28)) }
    }

    // MARK: container.xml

    private static func selectPackage(_ zip: EPUBZipReader, _ diagnostics: inout EPUBDiagnosticList) throws(Refusal) -> ([Rootfile], String) {
        var rootfiles: [Rootfile] = []
        if let bytes = try? zip.contents(named: containerPath) {
            if let document = try? EPUBXMLDocument.parse(bytes) {
                rootfiles = document.elements(named: "rootfile").compactMap { node in
                    document.attribute("full-path", of: node).map { Rootfile(fullPath: $0, mediaType: document.attribute("media-type", of: node)) }
                }
                if rootfiles.isEmpty {
                    diagnostics.record(.container, "container.noRootfile", path: containerPath, "container.xml names no package document.")
                }
            } else {
                diagnostics.record(.container, "container.unparsable", path: containerPath, "container.xml is not well-formed XML.")
            }
        } else {
            diagnostics.record(.container, "container.missing", path: containerPath, "META-INF/container.xml is missing.")
            if let nested = zip.entries.first(where: { $0.name.hasSuffix("/" + containerPath) }) {
                diagnostics.record(.container, "container.nested", path: nested.name, "The book is nested one folder down inside the archive.")
            }
        }
        if rootfiles.count > 1 {
            diagnostics.record(.container, "container.rootfile.multiple", path: containerPath, "container.xml lists \(rootfiles.count) rootfiles; the first package rendition is used.")
        }
        let chosen = rootfiles.first { $0.mediaType == packageMediaType } ?? rootfiles.first { $0.fullPath.lowercased().hasSuffix(".opf") }
        if let chosen {
            if let resolved = resolve(fullPath: chosen.fullPath, in: zip, &diagnostics) { return (rootfiles, resolved) }
            diagnostics.record(.container, "container.rootfile.missing", path: chosen.fullPath, "The package document named by container.xml is not in the archive.")
        }
        let candidates = zip.entries.filter { $0.name.lowercased().hasSuffix(".opf") && !$0.name.hasPrefix("META-INF/") }
        guard candidates.count == 1, let only = candidates.first else { throw .notABook }
        diagnostics.record(.container, "container.rootfile.fallback", path: only.name, "The package document was found by searching the archive.")
        return (rootfiles, only.name)
    }

    /// Resolves a container-root-relative path: leading slashes clamp to the
    /// root, percent-encoding is decoded, and the lookup falls back to a
    /// case-insensitive match with a diagnostic.
    static func resolve(fullPath: String, in zip: EPUBZipReader, _ diagnostics: inout EPUBDiagnosticList) -> String? {
        var path = fullPath
        if path.hasPrefix("/") {
            while path.hasPrefix("/") { path.removeFirst() }
            diagnostics.record(.container, "href.pathAbsolute", path: fullPath, "A root-relative path began with a slash.")
        }
        path = path.removingPercentEncoding ?? path
        if zip.entry(named: path) != nil { return path }
        if let folded = zip.entry(matchingCaseInsensitively: path) {
            diagnostics.record(.container, "href.caseFallback", path: fullPath, "The entry was found only by a case-insensitive match.")
            return folded.name
        }
        return nil
    }

    // MARK: encryption.xml

    private static func readEncryption(_ zip: EPUBZipReader, _ diagnostics: inout EPUBDiagnosticList) throws(Refusal) -> [String: String] {
        guard let bytes = try? zip.contents(named: encryptionPath) else { return [:] }
        guard let document = try? EPUBXMLDocument.parse(bytes) else {
            diagnostics.record(.container, "encryption.unparsable", path: encryptionPath, "encryption.xml is not well-formed XML; it is treated as absent.")
            return [:]
        }
        var map: [String: String] = [:]
        for entry in document.elements(named: "EncryptedData", namespace: EPUBNamespace.xmlEncryption) {
            if let keyInfo = document.firstChildElement(named: "KeyInfo", namespace: EPUBNamespace.xmlSignature, of: entry) {
                for method in document.descendantElements(named: "RetrievalMethod", namespace: EPUBNamespace.xmlSignature, of: keyInfo) {
                    if document.attribute("URI", of: method)?.contains("license.lcpl") == true { throw .protected(.lcp) }
                }
                if document.descendantElements(of: keyInfo).contains(where: { document.namespace(of: $0) == EPUBNamespace.adept }) {
                    throw .protected(.adept)
                }
            }
            guard let method = document.firstChildElement(named: "EncryptionMethod", namespace: EPUBNamespace.xmlEncryption, of: entry),
                  let algorithm = document.attribute("Algorithm", of: method),
                  let cipherData = document.firstChildElement(named: "CipherData", namespace: EPUBNamespace.xmlEncryption, of: entry),
                  let reference = document.firstChildElement(named: "CipherReference", namespace: EPUBNamespace.xmlEncryption, of: cipherData),
                  let uri = document.attribute("URI", of: reference) else {
                diagnostics.record(.container, "encryption.entrySkipped", path: encryptionPath, "An EncryptedData element lacks an algorithm or a cipher reference.")
                continue
            }
            var path = uri.removingPercentEncoding ?? uri
            while path.hasPrefix("/") { path.removeFirst() }
            map[path] = algorithm
        }
        return map
    }

    // MARK: Display options

    private static func readDisplayOptions(_ zip: EPUBZipReader, _ diagnostics: inout EPUBDiagnosticList) -> Bool? {
        for path in [appleDisplayOptionsPath, koboDisplayOptionsPath] {
            guard let bytes = try? zip.contents(named: path), let document = try? EPUBXMLDocument.parse(bytes) else { continue }
            let options = document.elements(named: "option").filter { document.attribute("name", of: $0) == "fixed-layout" }
            guard !options.isEmpty else { continue }
            let preferredPlatforms = ["*", "ipad", "iphone"]
            func platform(of option: EPUBXMLDocument.NodeID) -> String {
                document.parent(of: option).flatMap { document.attribute("name", of: $0) } ?? ""
            }
            let ordered = preferredPlatforms.compactMap { wanted in options.first { platform(of: $0) == wanted } } + options
            if let first = ordered.first {
                let value = document.collapsedText(of: first).lowercased() == "true"
                diagnostics.record(.container, "container.displayOptions", path: path, "A vendor display-options file declares the layout.")
                return value
            }
        }
        return nil
    }
}
