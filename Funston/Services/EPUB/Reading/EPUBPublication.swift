import Foundation

/// Why a book could not be opened, with the one sentence the user sees.
enum EPUBOpenFailure: Error, Equatable {
    case notABook
    case damaged(String)
    case protected

    var message: String {
        switch self {
        case .notABook: return "The file isn't a book this app can read."
        case .damaged: return "The book's file looks damaged. Try downloading it again."
        case .protected: return "This book is protected and can't be opened here."
        }
    }
}

/// Everything the reader knows about a book before any chapter is parsed:
/// the archive, the package, the navigation tables, the progress weights and
/// the diagnostics of opening. A value, built once, shared by every screen.
struct EPUBPublication: Sendable {
    static let fontDeobfuscationDiagnostic = "font.deobfuscationFailed"

    let zip: EPUBZipReader
    let container: EPUBContainerFile
    let package: EPUBPackageDocument
    let navigation: EPUBNavigationTables
    /// The uncompressed byte size of each spine item: the progress weight.
    /// Zero for non-linear items and placeholders.
    let weights: [UInt64]
    let diagnostics: EPUBDiagnosticList

    var title: String { package.mainTitle?.text ?? "" }
    var uniqueIdentifier: String { package.uniqueIdentifier }
    var releaseIdentifier: String { package.releaseIdentifier }
    var isFixedLayout: Bool { package.isFixedLayout || (package.rendition.layout == nil && container.displayOptionsFixedLayout == true) }
    var hasMediaOverlays: Bool { package.hasMediaOverlays }
    var totalWeight: UInt64 { weights.reduce(0, +) }

    /// Where a first open starts: the guide's `text` reference or the
    /// `bodymatter` landmark, else the first linear renderable spine item.
    var startTarget: EPUBTarget {
        if let landmark = navigation.landmarks.first(where: { $0.semanticTerms.contains(EPUBNavigationTables.bodymatterTerm) }), let target = landmark.target {
            return target
        }
        if let reference = package.guide.first(where: { $0.type == "text" }), let path = reference.path, let index = package.spineIndex(forPath: path) {
            return EPUBTarget(spineIndex: index, fragment: reference.fragment)
        }
        let first = package.spine.first { $0.isLinear && $0.kind != .placeholder(reason: "missing manifest item") && $0.path != nil }
        return EPUBTarget(spineIndex: first?.index ?? 0, fragment: nil)
    }

    // MARK: Opening

    static func open(url: URL) throws(EPUBOpenFailure) -> EPUBPublication {
        let zip: EPUBZipReader
        do { zip = try EPUBZipReader(contentsOf: url) } catch { throw .notABook }
        return try open(zip: zip)
    }

    static func open(data: Data) throws(EPUBOpenFailure) -> EPUBPublication {
        let zip: EPUBZipReader
        do { zip = try EPUBZipReader(data: data) } catch { throw .notABook }
        return try open(zip: zip)
    }

    static func open(zip: EPUBZipReader) throws(EPUBOpenFailure) -> EPUBPublication {
        let container: EPUBContainerFile
        do { container = try EPUBContainerFile.read(from: zip) } catch EPUBContainerFile.Refusal.notABook { throw .notABook } catch { throw .protected }
        guard let packageBytes = try? zip.contents(named: container.packagePath) else {
            throw .damaged("The package document could not be read.")
        }
        let package: EPUBPackageDocument
        do {
            package = try EPUBPackageDocument.parse(packageBytes, at: container.packagePath, in: zip, archiveData: zip.data)
        } catch EPUBPackageDocument.Failure.unreadable(let message) {
            throw .damaged(message)
        } catch {
            throw .damaged("The book has no readable chapters.")
        }
        if let protectedSpineItem = package.spine.first(where: { $0.path.map { container.protectedPaths.contains($0) } ?? false }) {
            _ = protectedSpineItem
            throw .protected
        }
        let navigation = EPUBNavigationBuilder.build(package: package, zip: zip) { item in
            guard let path = item.path, let bytes = try? zip.contents(named: path) else { return (nil, nil) }
            return EPUBNavigationBuilder.headingAndTitle(in: bytes)
        }
        let weights = package.spine.map { item -> UInt64 in
            guard item.isLinear, item.kind == .document, let path = item.path, let entry = zip.entry(named: path) else { return 0 }
            return entry.uncompressedSize
        }
        var diagnostics = EPUBDiagnosticList()
        diagnostics.merge(container.diagnostics)
        diagnostics.merge(package.diagnostics)
        diagnostics.merge(navigation.diagnostics)
        if package.isFixedLayout || container.displayOptionsFixedLayout == true {
            diagnostics.record(.package, "rendition.fixedLayout", path: package.path, "The book is fixed layout; its text is flowed instead.")
        }
        if package.hasMediaOverlays {
            diagnostics.record(.package, "mediaOverlay.detected", path: package.path, "The book has narration this reader does not play.")
        }
        return EPUBPublication(zip: zip, container: container, package: package, navigation: navigation, weights: weights, diagnostics: diagnostics)
    }

    // MARK: Resources

    enum ResourceFailure: Error, Equatable {
        case missing
        case protected
        case unreadable
    }

    /// The bytes of a container entry, deobfuscating fonts the encryption
    /// manifest lists. A font that fails the header check is reported, not served.
    func resource(at path: String, diagnostics: inout EPUBDiagnosticList) throws(ResourceFailure) -> Data {
        guard let entry = zip.entry(named: path) else { throw .missing }
        if container.protectedPaths.contains(path) { throw .protected }
        let bytes: Data
        do { bytes = try zip.contents(of: entry) } catch { throw .unreadable }
        guard let algorithm = container.encryption[path] else { return bytes }
        switch EPUBFontObfuscation.decode(bytes, algorithm: algorithm, uniqueIdentifier: package.uniqueIdentifier) {
        case .success(let decoded):
            return decoded
        case .failure(let failure):
            diagnostics.record(.font, Self.fontDeobfuscationDiagnostic, path: path, "The font could not be deobfuscated (\(failure)); system fonts are used.")
            throw .unreadable
        }
    }

    func resource(at path: String) throws(ResourceFailure) -> Data {
        var scratch = EPUBDiagnosticList()
        return try resource(at: path, diagnostics: &scratch)
    }
}
