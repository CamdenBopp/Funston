import CryptoKit
import Foundation

/// One Dublin Core or `meta` statement, kept in document order with its
/// refinements attached by id. Every derived field below is a query over this list.
struct EPUBMetadataEntry: Sendable, Hashable {
    /// The expanded property URI; EPUB 2 `meta name` values stay as written.
    let property: String
    let value: String
    let id: String?
    let refines: String?
    let scheme: String?
    let language: String?
    let direction: String?
    /// EPUB 2 attributes on Dublin Core elements, keyed by local name (`role`, `file-as`, `scheme`, `event`).
    let legacyAttributes: [String: String]
}

struct EPUBTitle: Sendable, Hashable {
    enum Kind: String, Sendable { case main, subtitle, short, collection, edition, expanded, other }
    let text: String
    let kind: Kind
    let displaySequence: Int?
    let language: String?
    let direction: String?
    let fileAs: String?
    let alternateScripts: [String: String]
}

struct EPUBContributor: Sendable, Hashable {
    let name: String
    let fileAs: String?
    /// MARC relator codes or whatever role string the book gave.
    let roles: [String]
    let displaySequence: Int?
    let language: String?
    let alternateScripts: [String: String]
    let isCreator: Bool
}

struct EPUBSubject: Sendable, Hashable {
    let name: String
    let authority: String?
    let term: String?
}

struct EPUBAccessibilityMetadata: Sendable, Hashable {
    var accessModes: [String] = []
    var accessModesSufficient: [[String]] = []
    var features: [String] = []
    var hazards: [String] = []
    var summary: String?
    var conformsTo: [String] = []
    var certifiedBy: String?
    var certifierCredential: String?
    var certifierReport: String?
    var isEmpty: Bool {
        accessModes.isEmpty && accessModesSufficient.isEmpty && features.isEmpty && hazards.isEmpty && summary == nil && conformsTo.isEmpty && certifiedBy == nil
    }
}

struct EPUBCollectionMembership: Sendable, Hashable {
    let name: String
    let type: String?
    let position: Double?
    let identifier: String?
    let fileAs: String?
}

struct EPUBRenditionProperties: Sendable, Hashable {
    enum Layout: String, Sendable { case reflowable, prePaginated = "pre-paginated" }
    enum Flow: String, Sendable { case paginated, scrolledContinuous = "scrolled-continuous", scrolledDoc = "scrolled-doc", auto }
    var layout: Layout?
    var flow: Flow?
    var orientation: String?
    var spread: String?
}

struct EPUBMediaOverlayMetadata: Sendable, Hashable {
    var totalDuration: Double?
    var itemDurations: [String: Double] = [:]
    var narrator: String?
    var activeClass: String?
    var playbackActiveClass: String?
}

struct EPUBManifestItem: Sendable, Hashable {
    let id: String
    let rawHref: String
    /// The resolved container path; set even when the entry is missing.
    let path: String?
    /// The archive entry that satisfied the href, nil when missing.
    let entry: String?
    let mediaType: EPUBMediaType?
    let rawMediaType: String?
    /// Raw `properties` tokens.
    let properties: Set<String>
    /// Expanded property URIs.
    let propertyTerms: Set<String>
    let fallback: String?
    let mediaOverlay: String?

    var existsInArchive: Bool { entry != nil }
    var isNavigationDocument: Bool { properties.contains("nav") && (mediaType?.isXHTML ?? true) }
    var isCoverImage: Bool { properties.contains("cover-image") }
}

struct EPUBSpineItem: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        /// An XHTML content document at `path`.
        case document
        /// An image or SVG item drawn as a page image.
        case image
        /// Nothing renderable; the slot stays so indices and CFIs stay stable.
        case placeholder(reason: String)
    }
    enum PageSpread: String, Sendable { case left, right, center }

    let index: Int
    let idref: String
    let id: String?
    let isLinear: Bool
    let properties: Set<String>
    let kind: Kind
    /// The item that renders (after any fallback walk), nil for a placeholder.
    let itemID: String?
    /// The container path that renders, nil for a placeholder.
    let path: String?
    let renditionOverride: EPUBRenditionProperties
    let pageSpread: PageSpread?
    /// The CFI step for this itemref inside the spine element.
    var cfiStep: Int { 2 * (index + 1) }
}

struct EPUBGuideReference: Sendable, Hashable {
    let type: String
    let title: String?
    let href: String
    let path: String?
    let fragment: String?
}

enum EPUBPageProgression: String, Sendable { case leftToRight = "ltr", rightToLeft = "rtl", `default` }

/// The parsed package document (OPF): metadata, manifest, spine and guide,
/// with every leniency of Spec section 6 recorded as a diagnostic.
struct EPUBPackageDocument: Sendable, Hashable {
    static let undeterminedLanguage = "und"

    let path: String
    let version: String?
    let declaredPrefixes: [String: String]
    let packageLanguage: String?
    let packageDirection: String?
    let metadata: [EPUBMetadataEntry]
    let uniqueIdentifier: String
    let identifiers: [EPUBMetadataEntry]
    let uniqueIdentifierIsSynthetic: Bool
    let modified: String?
    let titles: [EPUBTitle]
    let contributors: [EPUBContributor]
    let languages: [String]
    let publishedDate: String?
    let description: String?
    let publisher: String?
    let rights: String?
    let sources: [String]
    let subjects: [EPUBSubject]
    let accessibility: EPUBAccessibilityMetadata
    let collections: [EPUBCollectionMembership]
    let rendition: EPUBRenditionProperties
    let mediaOverlay: EPUBMediaOverlayMetadata
    /// Everything not consumed above, keyed by expanded URI.
    let otherMetadata: [String: [String]]
    let manifest: [EPUBManifestItem]
    let spine: [EPUBSpineItem]
    let pageProgression: EPUBPageProgression
    let tocItemID: String?
    /// The CFI step of the spine element among the package element's children.
    let spineCFIStep: Int
    let guide: [EPUBGuideReference]
    let coverItemID: String?
    let coverRule: String?
    let diagnostics: EPUBDiagnosticList

    var releaseIdentifier: String { modified.map { uniqueIdentifier + "@" + $0 } ?? uniqueIdentifier }
    var mainTitle: EPUBTitle? { titles.first { $0.kind == .main } ?? titles.first }
    var primaryLanguage: String { languages.first ?? Self.undeterminedLanguage }
    /// Languages whose pages run right to left when the spine declares no progression.
    static let rightToLeftLanguages: Set<String> = ["ar", "arc", "ckb", "dv", "fa", "ha", "he", "iw", "khw", "ks", "ku", "nqo", "prs", "ps", "sd", "syr", "ug", "ur", "yi"]
    /// Pages run right to left: declared on the spine, or defaulted from a right-to-left
    /// primary language when the spine declares nothing (EPUB 3.3 section 6.4; W3C
    /// pkg-spine-progression-default).
    var pagesRightToLeft: Bool {
        switch pageProgression {
        case .rightToLeft: return true
        case .leftToRight: return false
        case .default: return Self.rightToLeftLanguages.contains(String(primaryLanguage.prefix { $0 != "-" }).lowercased())
        }
    }
    var creators: [EPUBContributor] { contributors.filter(\.isCreator) }
    var isFixedLayout: Bool { rendition.layout == .prePaginated }
    var hasMediaOverlays: Bool { manifest.contains { $0.mediaOverlay != nil } }
    var navigationItem: EPUBManifestItem? { manifest.first(where: \.isNavigationDocument) }
    var linearSpine: [EPUBSpineItem] { spine.filter(\.isLinear) }

    func item(withID id: String) -> EPUBManifestItem? { manifest.first { $0.id == id } }
    func item(atPath path: String) -> EPUBManifestItem? { manifest.first { $0.path == path || $0.entry == path } }
    /// The first spine position that renders the entry at `path`.
    func spineIndex(forPath path: String) -> Int? { spine.firstIndex { $0.path == path } }

    enum Failure: Error, Equatable {
        case unreadable(String)
        case emptySpine
    }

    // MARK: Parsing

    static func parse(_ data: Data, at path: String, in zip: EPUBZipReader, archiveData: Data?) throws(Failure) -> EPUBPackageDocument {
        var diagnostics = EPUBDiagnosticList()
        let document: EPUBXMLDocument
        do { document = try EPUBXMLDocument.parse(data) } catch { throw .unreadable(error.message) }
        guard var root = document.documentElement else { throw .unreadable("The package document is empty.") }
        if !document.isElement(root, "package") {
            // Some tools wrap the package in another element.
            guard let wrapped = document.descendantElements(named: "package", of: root).first else { throw .unreadable("No package element.") }
            root = wrapped
            diagnostics.record(.package, "package.wrapped", path: path, "The package element is not the document element.")
        }
        if document.namespace(of: root) != EPUBNamespace.opf {
            diagnostics.record(.package, "package.namespaceMissing", path: path, "The package document does not use the OPF namespace; elements are matched by name.")
        }
        let version = document.attribute("version", of: root)
        if version == nil { diagnostics.record(.package, "package.versionMissing", path: path, "The package declares no version.") }
        let prefixes = EPUBPropertyVocabulary.declaredPrefixes(document.attribute("prefix", of: root))
        let packageLanguage = document.language(of: root)
        let packageDirection = document.attribute("dir", of: root)
        let children = document.childElements(of: root)
        let metadataNode = children.first { document.isElement($0, "metadata") }
        let manifestNode = children.first { document.isElement($0, "manifest") }
        let spineNode = children.first { document.isElement($0, "spine") }
        let guideNode = children.first { document.isElement($0, "guide") }
        let spineStep = spineNode.flatMap { node in children.firstIndex(of: node).map { 2 * ($0 + 1) } } ?? 6

        let entries = metadataNode.map { collectMetadata(document, $0, prefixes: prefixes) } ?? []
        if metadataNode == nil { diagnostics.record(.package, "package.metadataMissing", path: path, "The package has no metadata element.") }

        // Unique identifier.
        let identifiers = entries.filter { $0.property == EPUBPropertyVocabulary.dublinCoreElements + "identifier" && $0.refines == nil }
        let wanted = document.attribute("unique-identifier", of: root)
        var uniqueIdentifier = identifiers.first { $0.id == wanted && wanted != nil }?.value
        var synthetic = false
        if uniqueIdentifier == nil {
            if let first = identifiers.first {
                uniqueIdentifier = first.value
                diagnostics.record(.package, "package.uniqueIdentifier.fallback", path: path, wanted == nil ? "The package names no unique identifier; the first dc:identifier is used." : "The unique-identifier attribute names no dc:identifier; the first is used.")
            } else {
                synthetic = true
                let digest = SHA256.hash(data: archiveData ?? data).map { String(format: "%02x", $0) }.joined()
                uniqueIdentifier = "urn:funston:sha256:" + digest
                diagnostics.record(.package, "package.uniqueIdentifier.synthetic", path: path, "The package has no dc:identifier; one was derived from the file's SHA-256.")
            }
        }
        let identifier = uniqueIdentifier ?? ""

        func refinements(of id: String?, property: String) -> [EPUBMetadataEntry] {
            guard let id else { return [] }
            return entries.filter { $0.refines == id && $0.property == property }
        }
        func refinement(of id: String?, property: String) -> String? { refinements(of: id, property: property).first?.value }
        let meta = "http://idpf.org/epub/vocab/package/meta/#"

        // Titles.
        var titles: [EPUBTitle] = []
        for entry in entries where entry.property == EPUBPropertyVocabulary.dublinCoreElements + "title" && entry.refines == nil {
            let kind = refinement(of: entry.id, property: meta + "title-type").flatMap { EPUBTitle.Kind(rawValue: $0) } ?? .other
            let sequence = refinement(of: entry.id, property: meta + "display-seq").flatMap { Int($0) }
            let scripts = Dictionary(refinements(of: entry.id, property: meta + "alternate-script").compactMap { script in script.language.map { ($0, script.value) } }, uniquingKeysWith: { first, _ in first })
            titles.append(EPUBTitle(text: entry.value, kind: kind,
                                    displaySequence: sequence, language: entry.language ?? packageLanguage, direction: entry.direction ?? packageDirection,
                                    fileAs: refinement(of: entry.id, property: meta + "file-as") ?? entry.legacyAttributes["file-as"], alternateScripts: scripts))
        }
        if titles.isEmpty {
            diagnostics.record(.package, "package.titleMissing", path: path, "The package has no dc:title.")
        }
        // The main title: the one typed main (lowest display-seq), else the first.
        if let mainIndex = titles.indices.filter({ titles[$0].kind == .main }).min(by: { (titles[$0].displaySequence ?? Int.max) < (titles[$1].displaySequence ?? Int.max) }), mainIndex != 0 {
            titles.swapAt(0, mainIndex)
        }

        // Contributors.
        var contributors: [EPUBContributor] = []
        for entry in entries where entry.refines == nil {
            let isCreator = entry.property == EPUBPropertyVocabulary.dublinCoreElements + "creator"
            guard isCreator || entry.property == EPUBPropertyVocabulary.dublinCoreElements + "contributor" else { continue }
            var roles = refinements(of: entry.id, property: meta + "role").map(\.value)
            if roles.isEmpty, let legacy = entry.legacyAttributes["role"] { roles = [legacy] }
            let scripts = Dictionary(refinements(of: entry.id, property: meta + "alternate-script").compactMap { script in script.language.map { ($0, script.value) } }, uniquingKeysWith: { first, _ in first })
            contributors.append(EPUBContributor(name: entry.value, fileAs: refinement(of: entry.id, property: meta + "file-as") ?? entry.legacyAttributes["file-as"],
                                                roles: roles, displaySequence: refinement(of: entry.id, property: meta + "display-seq").flatMap { Int($0) },
                                                language: entry.language ?? packageLanguage, alternateScripts: scripts, isCreator: isCreator))
        }

        // Languages.
        let languages = entries.filter { $0.property == EPUBPropertyVocabulary.dublinCoreElements + "language" && $0.refines == nil }.map(\.value).filter { !$0.isEmpty }
        if languages.isEmpty { diagnostics.record(.package, "package.language.missing", path: path, "The package declares no dc:language; pronunciation falls back to the system default.") }
        for language in languages where !isPlausibleLanguageTag(language) {
            diagnostics.record(.package, "package.language.invalid", path: path, "The language tag \(language) is not BCP 47.")
        }

        // Dates.
        let modifiedEntry = entries.first { $0.property == EPUBPropertyVocabulary.dublinCoreTerms + "modified" && $0.refines == nil && EPUBDateParser.date($0.value) != nil }
            ?? entries.first { $0.property == EPUBPropertyVocabulary.dublinCoreElements + "date" && $0.legacyAttributes["event"] == "modification" }
        if modifiedEntry == nil { diagnostics.record(.package, "package.modifiedMissing", path: path, "The package has no dcterms:modified.") }
        let published = entries.first { $0.property == EPUBPropertyVocabulary.dublinCoreElements + "date" && ($0.legacyAttributes["event"] == nil || $0.legacyAttributes["event"] == "publication") }?.value

        func dublinCore(_ name: String) -> [String] {
            entries.filter { $0.property == EPUBPropertyVocabulary.dublinCoreElements + name && $0.refines == nil }.map(\.value)
        }
        var subjects: [EPUBSubject] = []
        let subjectEntries = entries.filter { $0.property == EPUBPropertyVocabulary.dublinCoreElements + "subject" && $0.refines == nil }
        if subjectEntries.count == 1, let only = subjectEntries.first, only.value.contains(",") || only.value.contains(";") {
            for part in only.value.split(whereSeparator: { $0 == "," || $0 == ";" }) {
                let name = part.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { subjects.append(EPUBSubject(name: name, authority: nil, term: nil)) }
            }
        } else {
            for entry in subjectEntries {
                subjects.append(EPUBSubject(name: entry.value,
                                            authority: refinement(of: entry.id, property: meta + "authority") ?? entry.legacyAttributes["authority"],
                                            term: refinement(of: entry.id, property: meta + "term") ?? entry.legacyAttributes["term"]))
            }
        }

        // Accessibility.
        var accessibility = EPUBAccessibilityMetadata()
        for entry in entries where entry.refines == nil {
            switch entry.property {
            case EPUBPropertyVocabulary.schema + "accessMode": accessibility.accessModes.append(entry.value)
            case EPUBPropertyVocabulary.schema + "accessModeSufficient": accessibility.accessModesSufficient.append(entry.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            case EPUBPropertyVocabulary.schema + "accessibilityFeature": accessibility.features.append(entry.value)
            case EPUBPropertyVocabulary.schema + "accessibilityHazard": accessibility.hazards.append(entry.value)
            case EPUBPropertyVocabulary.schema + "accessibilitySummary": accessibility.summary = accessibility.summary ?? entry.value
            case EPUBPropertyVocabulary.dublinCoreTerms + "conformsTo": accessibility.conformsTo.append(entry.value)
            case EPUBPropertyVocabulary.accessibility + "certifiedBy":
                accessibility.certifiedBy = accessibility.certifiedBy ?? entry.value
                accessibility.certifierCredential = accessibility.certifierCredential ?? refinement(of: entry.id, property: EPUBPropertyVocabulary.accessibility + "certifierCredential")
                accessibility.certifierReport = accessibility.certifierReport ?? refinement(of: entry.id, property: EPUBPropertyVocabulary.accessibility + "certifierReport")
            case EPUBPropertyVocabulary.accessibility + "certifierCredential": accessibility.certifierCredential = accessibility.certifierCredential ?? entry.value
            case EPUBPropertyVocabulary.accessibility + "certifierReport": accessibility.certifierReport = accessibility.certifierReport ?? entry.value
            default: break
            }
        }

        // Collections and series.
        var collections: [EPUBCollectionMembership] = []
        for entry in entries where entry.property == meta + "belongs-to-collection" && entry.refines == nil {
            collections.append(EPUBCollectionMembership(name: entry.value, type: refinement(of: entry.id, property: meta + "collection-type"),
                                                        position: refinement(of: entry.id, property: meta + "group-position").flatMap { Double($0) },
                                                        identifier: refinement(of: entry.id, property: EPUBPropertyVocabulary.dublinCoreElements + "identifier"),
                                                        fileAs: refinement(of: entry.id, property: meta + "file-as")))
        }
        if let series = entries.first(where: { $0.property == "calibre:series" }) {
            collections.removeAll { $0.type == "series" }
            collections.append(EPUBCollectionMembership(name: series.value, type: "series", position: entries.first { $0.property == "calibre:series_index" }.flatMap { Double($0.value) }, identifier: nil, fileAs: nil))
        }

        // Rendition and media overlays.
        var rendition = EPUBRenditionProperties()
        var overlay = EPUBMediaOverlayMetadata()
        for entry in entries {
            switch entry.property {
            case EPUBPropertyVocabulary.rendition + "layout" where entry.refines == nil:
                if rendition.layout == nil { rendition.layout = EPUBRenditionProperties.Layout(rawValue: entry.value) }
                else { diagnostics.record(.package, "rendition.duplicate", path: path, "rendition:layout is declared more than once; the first wins.") }
            case EPUBPropertyVocabulary.rendition + "flow" where entry.refines == nil:
                if rendition.flow == nil { rendition.flow = EPUBRenditionProperties.Flow(rawValue: entry.value) }
            case EPUBPropertyVocabulary.rendition + "orientation" where entry.refines == nil: rendition.orientation = rendition.orientation ?? entry.value
            case EPUBPropertyVocabulary.rendition + "spread" where entry.refines == nil: rendition.spread = rendition.spread ?? entry.value
            case EPUBPropertyVocabulary.mediaOverlays + "duration":
                if let refines = entry.refines { overlay.itemDurations[refines] = EPUBClockValue.seconds(entry.value) }
                else { overlay.totalDuration = overlay.totalDuration ?? EPUBClockValue.seconds(entry.value) }
            case EPUBPropertyVocabulary.mediaOverlays + "narrator": overlay.narrator = overlay.narrator ?? entry.value
            case EPUBPropertyVocabulary.mediaOverlays + "active-class": overlay.activeClass = overlay.activeClass ?? entry.value
            case EPUBPropertyVocabulary.mediaOverlays + "playback-active-class": overlay.playbackActiveClass = overlay.playbackActiveClass ?? entry.value
            default: break
            }
        }

        // Everything else.
        let consumed: Set<String> = [
            EPUBPropertyVocabulary.dublinCoreElements + "identifier", EPUBPropertyVocabulary.dublinCoreElements + "title",
            EPUBPropertyVocabulary.dublinCoreElements + "creator", EPUBPropertyVocabulary.dublinCoreElements + "contributor",
            EPUBPropertyVocabulary.dublinCoreElements + "language", EPUBPropertyVocabulary.dublinCoreElements + "date",
            EPUBPropertyVocabulary.dublinCoreElements + "subject", EPUBPropertyVocabulary.dublinCoreElements + "description",
            EPUBPropertyVocabulary.dublinCoreElements + "publisher", EPUBPropertyVocabulary.dublinCoreElements + "rights",
            EPUBPropertyVocabulary.dublinCoreElements + "source", EPUBPropertyVocabulary.dublinCoreTerms + "modified",
            meta + "belongs-to-collection", "cover"
        ]
        var other: [String: [String]] = [:]
        for entry in entries where entry.refines == nil && !consumed.contains(entry.property) {
            other[entry.property, default: []].append(entry.value)
        }

        // Manifest.
        var manifest: [EPUBManifestItem] = []
        var seenIDs: Set<String> = []
        for node in manifestNode.map({ document.childElements(of: $0).filter { document.isElement($0, "item") } }) ?? [] {
            guard let id = document.attribute("id", of: node), let href = document.attribute("href", of: node) else {
                diagnostics.record(.package, "manifest.itemSkipped", path: path, "A manifest item lacks an id or an href.")
                continue
            }
            guard seenIDs.insert(id).inserted else {
                diagnostics.record(.package, "manifest.duplicateID", path: path, "The manifest id \(id) is declared twice; the first wins.")
                continue
            }
            let rawType = document.attribute("media-type", of: node)
            let mediaType = rawType.flatMap { EPUBMediaType($0) }
            if rawType == nil {
                diagnostics.record(.package, "manifest.mediaTypeMissing", path: path, "Manifest item \(id) declares no media type.")
            } else if mediaType == nil {
                diagnostics.record(.package, "manifest.mediaTypeInvalid", path: path, "Manifest item \(id) declares an unparsable media type.")
            }
            var hrefForResolution = href
            if let hash = href.firstIndex(of: "#") {
                hrefForResolution = String(href[..<hash])
                diagnostics.record(.package, "manifest.hrefFragment", path: path, "Manifest item \(id) has a fragment in its href; it was ignored.")
            }
            let reference = EPUBHref.resolve(hrefForResolution, from: path, in: zip, diagnostics: &diagnostics)
            let rawProperties = Set(EPUBPropertyVocabulary.tokens(document.attribute("properties", of: node)))
            manifest.append(EPUBManifestItem(id: id, rawHref: href, path: reference.kind == .internalResource ? reference.path : nil, entry: reference.entry,
                                             mediaType: mediaType, rawMediaType: rawType, properties: rawProperties,
                                             propertyTerms: EPUBPropertyVocabulary.expandedTerms(document.attribute("properties", of: node), context: .manifestProperties, declared: prefixes),
                                             fallback: document.attribute("fallback", of: node), mediaOverlay: document.attribute("media-overlay", of: node)))
        }
        if manifestNode == nil { diagnostics.record(.package, "package.manifestMissing", path: path, "The package has no manifest.") }
        let itemsByID = Dictionary(manifest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Spine.
        guard let spineNode else { throw .emptySpine }
        let progressionValue = document.attribute("page-progression-direction", of: spineNode)
        let progression = progressionValue.flatMap { EPUBPageProgression(rawValue: $0) } ?? .default
        if let progressionValue, EPUBPageProgression(rawValue: progressionValue) == nil {
            diagnostics.record(.package, "spine.progressionInvalid", path: path, "page-progression-direction is \(progressionValue); left-to-right is assumed.")
        }
        var spine: [EPUBSpineItem] = []
        for (index, node) in document.childElements(of: spineNode).filter({ document.isElement($0, "itemref") }).enumerated() {
            let idref = document.attribute("idref", of: node) ?? ""
            let linear = document.attribute("linear", of: node)?.lowercased() != "no"
            let rawProperties = document.attribute("properties", of: node)
            let tokens = Set(EPUBPropertyVocabulary.tokens(rawProperties))
            var override = EPUBRenditionProperties()
            for token in tokens {
                if token.hasPrefix("rendition:layout-") { override.layout = EPUBRenditionProperties.Layout(rawValue: String(token.dropFirst("rendition:layout-".count))) }
                else if token.hasPrefix("rendition:flow-") { override.flow = EPUBRenditionProperties.Flow(rawValue: String(token.dropFirst("rendition:flow-".count))) }
                else if token.hasPrefix("rendition:orientation-") { override.orientation = String(token.dropFirst("rendition:orientation-".count)) }
                else if token.hasPrefix("rendition:spread-") { override.spread = String(token.dropFirst("rendition:spread-".count)) }
            }
            if override != EPUBRenditionProperties() {
                diagnostics.record(.package, "rendition.itemrefOverride", path: path, spineIndex: index, "A spine item overrides the rendition properties.")
            }
            let pageSpread: EPUBSpineItem.PageSpread? = tokens.contains("page-spread-left") ? .left : tokens.contains("page-spread-right") ? .right : (tokens.contains("page-spread-center") || tokens.contains("rendition:page-spread-center")) ? .center : nil
            let resolved = renderable(idref: idref, items: itemsByID, index: index, path: path, diagnostics: &diagnostics)
            spine.append(EPUBSpineItem(index: index, idref: idref, id: document.attribute("id", of: node), isLinear: linear, properties: tokens,
                                       kind: resolved.kind, itemID: resolved.itemID, path: resolved.path, renditionOverride: override, pageSpread: pageSpread))
        }
        guard spine.contains(where: { if case .placeholder = $0.kind { return false } else { return true } }) else { throw .emptySpine }

        // Guide.
        var guide: [EPUBGuideReference] = []
        for node in guideNode.map({ document.childElements(of: $0).filter { document.isElement($0, "reference") } }) ?? [] {
            guard let type = document.attribute("type", of: node), let href = document.attribute("href", of: node) else { continue }
            let reference = EPUBHref.resolve(href, from: path, in: zip, diagnostics: &diagnostics)
            guide.append(EPUBGuideReference(type: type, title: document.attribute("title", of: node), href: href,
                                            path: reference.entry ?? reference.path, fragment: reference.fragment))
        }

        // Cover.
        let (coverID, coverRule) = discoverCover(entries: entries, manifest: manifest, guide: guide, zip: zip, path: path, diagnostics: &diagnostics)

        let tocItemID = document.attribute("toc", of: spineNode)
        return EPUBPackageDocument(path: path, version: version, declaredPrefixes: prefixes, packageLanguage: packageLanguage, packageDirection: packageDirection,
                                   metadata: entries, uniqueIdentifier: identifier, identifiers: identifiers, uniqueIdentifierIsSynthetic: synthetic,
                                   modified: modifiedEntry?.value, titles: titles, contributors: contributors, languages: languages,
                                   publishedDate: published, description: dublinCore("description").first, publisher: dublinCore("publisher").first,
                                   rights: dublinCore("rights").first, sources: dublinCore("source"), subjects: subjects, accessibility: accessibility,
                                   collections: collections, rendition: rendition, mediaOverlay: overlay, otherMetadata: other, manifest: manifest,
                                   spine: spine, pageProgression: progression, tocItemID: tocItemID, spineCFIStep: spineStep, guide: guide,
                                   coverItemID: coverID, coverRule: coverRule, diagnostics: diagnostics)
    }

    /// Dublin Core and `meta` children of `metadata`, including the OPF 2
    /// `dc-metadata` and `x-metadata` wrappers, in document order.
    private static func collectMetadata(_ document: EPUBXMLDocument, _ metadataNode: EPUBXMLDocument.NodeID, prefixes: [String: String]) -> [EPUBMetadataEntry] {
        var entries: [EPUBMetadataEntry] = []
        var queue = document.childElements(of: metadataNode)
        var index = 0
        while index < queue.count {
            let node = queue[index]; index += 1
            let name = document.localName(of: node)
            if name == "dc-metadata" || name == "x-metadata" {
                queue.append(contentsOf: document.childElements(of: node))
                continue
            }
            let namespace = document.namespace(of: node)
            let isDublinCore = namespace == EPUBNamespace.dublinCore || (namespace != EPUBNamespace.opf && Self.dublinCoreNames.contains(name))
            if isDublinCore {
                var legacy: [String: String] = [:]
                for attribute in document[node].attributes where attribute.namespaceURI == EPUBNamespace.opf || (attribute.namespaceURI == nil && ["role", "file-as", "scheme", "event", "authority", "term"].contains(attribute.localName)) {
                    legacy[attribute.localName] = attribute.value
                }
                entries.append(EPUBMetadataEntry(property: EPUBPropertyVocabulary.dublinCoreElements + name, value: document.collapsedText(of: node),
                                                 id: document.attribute("id", of: node), refines: nil, scheme: legacy["scheme"],
                                                 language: document.language(of: node), direction: document.attribute("dir", of: node), legacyAttributes: legacy))
            } else if name == "meta" {
                if let property = document.attribute("property", of: node) {
                    guard let expanded = EPUBPropertyVocabulary.expand(property, context: .metaProperty, declared: prefixes) else { continue }
                    var refines = document.attribute("refines", of: node)
                    if let value = refines, value.hasPrefix("#") { refines = String(value.dropFirst()) }
                    let scheme = document.attribute("scheme", of: node).flatMap { EPUBPropertyVocabulary.expand($0, context: .scheme, declared: prefixes) }
                    entries.append(EPUBMetadataEntry(property: expanded, value: document.collapsedText(of: node), id: document.attribute("id", of: node),
                                                     refines: refines, scheme: scheme, language: document.language(of: node),
                                                     direction: document.attribute("dir", of: node), legacyAttributes: [:]))
                } else if let legacyName = document.attribute("name", of: node), let content = document.attribute("content", of: node) {
                    entries.append(EPUBMetadataEntry(property: legacyName, value: EPUBXMLDocument.collapseWhitespace(content), id: document.attribute("id", of: node),
                                                     refines: nil, scheme: nil, language: nil, direction: nil, legacyAttributes: [:]))
                }
            }
        }
        return entries
    }

    private static let dublinCoreNames: Set<String> = ["title", "creator", "subject", "description", "publisher", "contributor", "date", "type", "format", "identifier", "source", "language", "relation", "coverage", "rights"]

    private static func isPlausibleLanguageTag(_ tag: String) -> Bool {
        let parts = tag.split(separator: "-")
        guard let first = parts.first, (2...8).contains(first.count), first.allSatisfy(\.isLetter) else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.count <= 8 && $0.allSatisfy { $0.isLetter || $0.isNumber } }
    }

    /// Walks the fallback chain of a spine item to a renderable item, stopping at a repeat.
    private static func renderable(idref: String, items: [String: EPUBManifestItem], index: Int, path: String, diagnostics: inout EPUBDiagnosticList) -> (kind: EPUBSpineItem.Kind, itemID: String?, path: String?) {
        guard let start = items[idref] else {
            diagnostics.record(.package, "spine.itemMissing", path: path, spineIndex: index, "Spine item \(index) refers to manifest id \(idref), which does not exist.")
            return (.placeholder(reason: "missing manifest item"), nil, nil)
        }
        var visited: Set<String> = []
        var current: EPUBManifestItem? = start
        while let item = current, visited.insert(item.id).inserted {
            if let type = item.mediaType {
                if type.isXHTML { return (.document, item.id, item.entry ?? item.path) }
                if type.isImage { return (.image, item.id, item.entry ?? item.path) }
                if type.isNCX {
                    diagnostics.record(.package, "spine.ncxInSpine", path: path, spineIndex: index, "The spine lists the NCX; it cannot be rendered.")
                }
            } else if let path = item.path?.lowercased(), path.hasSuffix(".xhtml") || path.hasSuffix(".html") || path.hasSuffix(".htm") || path.hasSuffix(".xml") {
                return (.document, item.id, item.entry ?? item.path)
            }
            current = item.fallback.flatMap { items[$0] }
        }
        diagnostics.record(.package, "spine.unrenderable", path: path, spineIndex: index, "Spine item \(index) has no renderable item in its fallback chain.")
        return (.placeholder(reason: "unrenderable media type"), start.id, start.entry ?? start.path)
    }

    private static func discoverCover(entries: [EPUBMetadataEntry], manifest: [EPUBManifestItem], guide: [EPUBGuideReference], zip: EPUBZipReader, path: String, diagnostics: inout EPUBDiagnosticList) -> (String?, String?) {
        if let item = manifest.first(where: { $0.isCoverImage && ($0.mediaType?.isImage ?? false) }) { return (item.id, "cover-image") }
        if let meta = entries.first(where: { $0.property == "cover" })?.value {
            if let item = manifest.first(where: { $0.id == meta && ($0.mediaType?.isImage ?? false) }) { return (item.id, "meta.id") }
            let name = (meta as NSString).lastPathComponent
            if let item = manifest.first(where: { ($0.mediaType?.isImage ?? false) && ($0.rawHref == meta || $0.path == meta || ($0.path as NSString?)?.lastPathComponent == name) }) {
                return (item.id, "meta.href")
            }
        }
        if let reference = guide.first(where: { $0.type == "cover" }), let referencePath = reference.path {
            if let item = manifest.first(where: { $0.path == referencePath && ($0.mediaType?.isImage ?? false) }) { return (item.id, "guide.image") }
            if let item = manifest.first(where: { $0.path == referencePath && ($0.mediaType?.isXHTML ?? false) }),
               let bytes = try? zip.contents(named: referencePath), let page = try? EPUBXMLDocument.parse(bytes),
               let image = page.elements(named: "img").first, let source = page.attribute("src", of: image) {
                var scratch = EPUBDiagnosticList()
                let resolved = EPUBHref.resolve(source, from: referencePath, in: zip, diagnostics: &scratch)
                if let imageItem = manifest.first(where: { $0.entry == resolved.entry && resolved.entry != nil }) { return (imageItem.id, "guide.page") }
            }
        }
        if let item = manifest.first(where: { ($0.mediaType?.isImage ?? false) && ($0.id.lowercased().contains("cover") || $0.rawHref.lowercased().contains("cover")) }) {
            return (item.id, "name")
        }
        return (nil, nil)
    }
}
