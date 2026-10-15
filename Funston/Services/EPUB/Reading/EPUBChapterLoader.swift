import CoreGraphics
import Foundation

/// Per-book caches shared by every chapter: parsed sheets, embedded fonts,
/// image metadata and decoded images.
final class EPUBBookResources: @unchecked Sendable {
    let publication: EPUBPublication
    let fonts = EPUBFontRegistry()
    let images: EPUBImageCatalog
    private let lock = NSLock()
    private var sheets: [String: EPUBStyleSheet] = [:]
    private var registeredFaces: Set<String> = []

    init(publication: EPUBPublication) {
        self.publication = publication
        images = EPUBImageCatalog { path in try? publication.resource(at: path) }
    }

    /// A linked sheet, parsed once per media context.
    func sheet(at path: String, media: EPUBMediaContext, diagnostics: inout EPUBDiagnosticList) -> EPUBStyleSheet? {
        let key = path + "|" + (media.isDark ? "dark" : "light") + (media.isLandscape ? "|landscape" : "")
        lock.lock()
        if let cached = sheets[key] { lock.unlock(); return cached }
        lock.unlock()
        guard let data = try? publication.resource(at: path) else {
            diagnostics.record(.css, "css.sheetMissing", path: path, "A linked style sheet is missing.")
            return nil
        }
        let text = EPUBContentDecoder.cssText(data)
        let sheet = EPUBStyleSheet.parse(text, path: path, media: media, loader: { [publication] in (try? publication.resource(at: $0)).map(EPUBContentDecoder.cssText) },
                                         resolve: { [publication] reference, base in Self.resourcePath(reference, from: base, in: publication) })
        lock.lock(); sheets[key] = sheet; lock.unlock()
        return sheet
    }

    /// The archive path a sheet reference names: the matched entry, or the
    /// normalised path when nothing matches so the miss is reported later.
    static func resourcePath(_ reference: String, from base: String, in publication: EPUBPublication) -> String? {
        var scratch = EPUBDiagnosticList()
        let resolved = EPUBHref.resolve(reference, from: base, in: publication.zip, diagnostics: &scratch)
        guard resolved.kind == .internalResource else { return nil }
        return resolved.entry ?? resolved.path
    }

    /// Loads the faces a sheet declares, once per source, deobfuscating as needed.
    func registerFonts(from sheet: EPUBStyleSheet, diagnostics: inout EPUBDiagnosticList) {
        for face in sheet.fontFaces {
            for source in face.sources {
                lock.lock()
                let seen = registeredFaces.contains(source)
                registeredFaces.insert(source)
                lock.unlock()
                guard !seen else { continue }
                var resourceDiagnostics = EPUBDiagnosticList()
                guard let data = try? publication.resource(at: source, diagnostics: &resourceDiagnostics) else {
                    diagnostics.merge(resourceDiagnostics)
                    diagnostics.record(.font, "font.missing", path: source, "An embedded font is missing or unreadable; system fonts are used.")
                    continue
                }
                if fonts.register(face, data: data, source: source, diagnostics: &diagnostics) > 0 { break }
            }
        }
    }
}

extension EPUBContentDecoder {
    /// CSS is UTF-8 or UTF-16; a BOM wins, then UTF-8, then Windows-1252.
    static func cssText(_ data: Data) -> String {
        if let (_, encoding) = byteOrderMark(data), let text = String(data: data, encoding: encoding) { return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }
}

/// A parsed, styled and rendered chapter.
struct EPUBLoadedChapter: Sendable {
    let spineIndex: Int
    let document: EPUBContentDocument
    let text: EPUBChapterText
    let diagnostics: EPUBDiagnosticList
}

/// Reads a spine item, settles its encoding, parses it, collects and
/// cascades its style sheets, and builds its text (Spec section 4.2, step 2).
struct EPUBChapterLoader: Sendable {
    static let acceptedMediaAttributes: Set<String> = ["", "all", "screen"]

    let resources: EPUBBookResources
    let settings: EPUBReadingSettings
    let geometry: EPUBTextGeometry
    let mediaContext: EPUBMediaContext

    var publication: EPUBPublication { resources.publication }

    func load(spineIndex: Int) -> EPUBLoadedChapter? {
        guard publication.package.spine.indices.contains(spineIndex) else { return nil }
        let item = publication.package.spine[spineIndex]
        guard let path = item.path else { return nil }
        var diagnostics = EPUBDiagnosticList()
        let data: Data
        do { data = try publication.resource(at: path, diagnostics: &diagnostics) } catch {
            diagnostics.record(.chapterDecode, "chapter.unreadable", path: path, spineIndex: spineIndex, "The chapter could not be read from the archive.")
            let empty = EPUBContentDocument(path: path, tree: EPUBXMLDocument(nodes: [], documentElement: nil), parserPath: .unreadable, encodingName: "", diagnostics: diagnostics, publicationLanguage: publication.package.primaryLanguage)
            return EPUBLoadedChapter(spineIndex: spineIndex, document: empty, text: Self.emptyText(diagnostics), diagnostics: diagnostics)
        }
        if item.kind == .image {
            let document = EPUBContentDocument.parse(Data(Self.imagePageMarkup(path: path).utf8), path: path, publicationLanguage: publication.package.primaryLanguage)
            return build(document, spineIndex: spineIndex, sheets: [], diagnostics: diagnostics)
        }
        let document = EPUBContentDocument.parse(data, path: path, publicationLanguage: publication.package.primaryLanguage)
        diagnostics.merge(document.diagnostics)
        let sheets = collectSheets(document, diagnostics: &diagnostics)
        return build(document, spineIndex: spineIndex, sheets: sheets, diagnostics: diagnostics)
    }

    private func build(_ document: EPUBContentDocument, spineIndex: Int, sheets: [EPUBStyleSheet], diagnostics: EPUBDiagnosticList) -> EPUBLoadedChapter {
        var diagnostics = diagnostics
        let resolver = EPUBStyleResolver(settings: settings, sheets: sheets)
        let styles = resolver.resolve(document, diagnostics: &diagnostics)
        let publication = publication
        let builder = EPUBChapterTextBuilder(document: document, styles: styles, settings: settings, geometry: geometry, fonts: resources.fonts, images: resources.images,
                                             resolveLink: { Self.resolveLink($0, from: document.path, publication: publication) },
                                             resolveImagePath: { reference in
                                                 var scratch = EPUBDiagnosticList()
                                                 let resolved = EPUBHref.resolve(reference, from: document.path, in: publication.zip, diagnostics: &scratch)
                                                 return resolved.kind == .internalResource ? resolved.entry : nil
                                             })
        let text = builder.build()
        diagnostics.merge(text.diagnostics)
        return EPUBLoadedChapter(spineIndex: spineIndex, document: document, text: text, diagnostics: diagnostics)
    }

    static func resolveLink(_ href: String, from base: String, publication: EPUBPublication) -> EPUBLinkTarget? {
        var scratch = EPUBDiagnosticList()
        let reference = EPUBHref.resolve(href, from: base, in: publication.zip, diagnostics: &scratch)
        switch reference.kind {
        case .external: return URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines)).map { .external($0) }
        case .refused: return .refused(href)
        case .data: return nil
        case .internalResource:
            let path = reference.entry ?? reference.path ?? base
            return .internalLink(path: path, fragment: reference.fragment, spineIndex: publication.package.spineIndex(forPath: path))
        }
    }

    /// Author CSS in document order: `style` elements and `link rel="stylesheet"`
    /// whose media is all or screen, parsed once per book.
    private func collectSheets(_ document: EPUBContentDocument, diagnostics: inout EPUBDiagnosticList) -> [EPUBStyleSheet] {
        let tree = document.tree
        var sheets: [EPUBStyleSheet] = []
        guard let root = tree.documentElement else { return [] }
        for node in [root] + tree.descendantElements(of: root) {
            switch tree.localName(of: node) {
            case "style":
                guard Self.acceptedMediaAttributes.contains((tree.attribute("media", of: node) ?? "").lowercased()) || EPUBStyleSheet.evaluateMedia(tree.attribute("media", of: node) ?? "", mediaContext) else { continue }
                let publication = publication
                let sheet = EPUBStyleSheet.parse(tree.textContent(of: node), path: document.path, media: mediaContext,
                                                 loader: { (try? publication.resource(at: $0)).map(EPUBContentDecoder.cssText) },
                                                 resolve: { reference, base in EPUBBookResources.resourcePath(reference, from: base, in: publication) })
                diagnostics.merge(sheet.diagnostics)
                resources.registerFonts(from: sheet, diagnostics: &diagnostics)
                sheets.append(sheet)
            case "link":
                let relation = EPUBPropertyVocabulary.tokens(tree.attribute("rel", of: node)?.lowercased())
                guard relation.contains("stylesheet"), !relation.contains("alternate"), let href = tree.attribute("href", of: node) else { continue }
                let media = (tree.attribute("media", of: node) ?? "").lowercased()
                guard Self.acceptedMediaAttributes.contains(media) || EPUBStyleSheet.evaluateMedia(media, mediaContext) else { continue }
                var resolveDiagnostics = EPUBDiagnosticList()
                let reference = EPUBHref.resolve(href, from: document.path, in: publication.zip, diagnostics: &resolveDiagnostics)
                guard let path = reference.entry else {
                    diagnostics.record(.css, "css.sheetMissing", path: href, "A linked style sheet is missing.")
                    continue
                }
                if let sheet = resources.sheet(at: path, media: mediaContext, diagnostics: &diagnostics) {
                    diagnostics.merge(sheet.diagnostics)
                    resources.registerFonts(from: sheet, diagnostics: &diagnostics)
                    sheets.append(sheet)
                }
            default:
                continue
            }
        }
        return sheets
    }

    static func imagePageMarkup(path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><img src=\"\(name)\" alt=\"\(name)\"/></body></html>"
    }

    static func emptyText(_ diagnostics: EPUBDiagnosticList) -> EPUBChapterText {
        EPUBChapterText(string: NSAttributedString(), runTable: EPUBRunTable(runs: []), blocks: [], containers: [], links: [], images: [], pageBreaks: [], anchors: [:],
                        language: nil, title: nil, diagnostics: diagnostics, isImagePage: false)
    }
}
