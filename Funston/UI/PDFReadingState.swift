import PDFKit
import UIKit
import Vision
import VisionKit

enum PDFReadingLayout: String, CaseIterable {
    case pages, continuous

    static var saved: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: "pdf.readingLayout") ?? "") ?? .continuous
    }

    var title: String { self == .pages ? "Page by Page" : "Continuous Scroll" }
    var previousSymbol: String { self == .pages ? "chevron.backward" : "chevron.up" }
    var nextSymbol: String { self == .pages ? "chevron.forward" : "chevron.down" }

    func save() { UserDefaults.standard.set(rawValue, forKey: "pdf.readingLayout") }

    @MainActor
    func apply(to view: PDFView) {
        let page = view.currentPage
        view.usePageViewController(false)
        view.displayDirection = self == .pages ? .horizontal : .vertical
        view.displayMode = self == .pages ? .singlePage : .singlePageContinuous
        if self == .pages { view.usePageViewController(true) }
        view.autoScales = true
        view.layoutIfNeeded()
        if let page { view.go(to: page) }
        // PDFKit's destination point depends on the old viewport. Carrying that
        // point across fit-page/fit-width layouts can land on the following page.
    }
}

/// Coalesces fast page changes into one preference write. Lifecycle exits flush
/// immediately, so debouncing never discards the last page when leaving a book.
@MainActor
final class PDFReadingProgress {
    private let key: String
    private let defaults: UserDefaults
    private let delay: Duration
    private var pendingPage: Int?
    private var savedPage: Int
    private var pendingWrite: Task<Void, Never>?

    init(key: String, defaults: UserDefaults = .standard, delay: Duration = .milliseconds(750)) {
        self.key = key
        self.defaults = defaults
        self.delay = delay
        savedPage = defaults.integer(forKey: key)
    }

    deinit { pendingWrite?.cancel() }

    func record(page: Int) {
        guard page >= 0, page != pendingPage else { return }
        pendingPage = page
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self, delay] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.flush()
        }
    }

    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        guard let page = pendingPage else { return }
        pendingPage = nil
        guard page != savedPage else { return }
        defaults.set(page, forKey: key)
        savedPage = page
    }
}

struct PDFPageTextResult: Codable, Equatable, Sendable {
    let text: String
    /// A stable, open-ended identifier rather than a closed enum so another
    /// OCR implementation can be registered without changing cached results.
    let engineID: String?
}

enum PDFTextEngineID {
    static let automatic = "automatic"
    static let embedded = "pdf.embedded-text"
    static let appleLiveText = "apple.live-text"
    static let appleVision = "apple.vision"
}

struct PDFTextEngineDescriptor: Hashable, Sendable {
    let id: String
    let title: String
    let isAvailable: Bool
    var subtitle: String? = nil
}

/// OCR engines expose a stable identifier and one recognition operation. The
/// reader depends on this protocol and registry, not Apple-specific branching.
protocol PDFPageOCREngine: Sendable {
    var descriptor: PDFTextEngineDescriptor { get }
    func recognize(_ image: CGImage) async -> String
}

private struct PDFLiveTextEngine: PDFPageOCREngine {
    var descriptor: PDFTextEngineDescriptor {
        PDFTextEngineDescriptor(
            id: PDFTextEngineID.appleLiveText,
            title: "Apple Live Text",
            isAvailable: ImageAnalyzer.isSupported
        )
    }

    func recognize(_ image: CGImage) async -> String {
        guard ImageAnalyzer.isSupported else { return "" }
        var configuration = ImageAnalyzer.Configuration([.text])
        configuration.locales = []
        guard let analysis = try? await ImageAnalyzer().analyze(
            image,
            orientation: .up,
            configuration: configuration
        ) else { return "" }
        return analysis.transcript
    }
}

private struct PDFVisionTextEngine: PDFPageOCREngine {
    let descriptor = PDFTextEngineDescriptor(
        id: PDFTextEngineID.appleVision,
        title: "Apple Vision",
        isAvailable: true
    )

    func recognize(_ image: CGImage) async -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        guard let observations = try? await request.perform(on: image, orientation: .up) else { return "" }
        return observations.sorted { lhs, rhs in
            let verticalDifference = abs(lhs.topLeft.y - rhs.topLeft.y)
            if verticalDifference > 0.015 { return lhs.topLeft.y > rhs.topLeft.y }
            return lhs.topLeft.x < rhs.topLeft.x
        }.compactMap { $0.topCandidates(1).first?.string }
            .map(PDFPageTextPolicy.normalize)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

struct PDFPageTextEngineRegistry: Sendable {
    let engines: [any PDFPageOCREngine]

    init(engines: [any PDFPageOCREngine]) {
        self.engines = engines
    }

    static var builtIn: Self {
        Self(engines: [PDFLiveTextEngine(), PDFVisionTextEngine()])
    }

    var descriptors: [PDFTextEngineDescriptor] {
        engines.map(\.descriptor)
    }

    func engine(id: String) -> (any PDFPageOCREngine)? {
        engines.first { $0.descriptor.id == id }
    }
}

/// The preference is global and durable. Opening recognized text never prompts;
/// a reader who wants a different engine chooses it once in Reading Options.
@MainActor
struct PDFTextEnginePreference {
    static let key = "pdf.textRecognitionEngine"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedID: String {
        defaults.string(forKey: Self.key) ?? PDFTextEngineID.automatic
    }

    func select(_ engineID: String) {
        defaults.set(engineID, forKey: Self.key)
    }

    func options(ocrEngines: [PDFTextEngineDescriptor]) -> [PDFTextEngineDescriptor] {
        [
            PDFTextEngineDescriptor(id: PDFTextEngineID.automatic, title: "Automatic", isAvailable: true,
                                    subtitle: "Recognizes scanned pages on this device"),
            PDFTextEngineDescriptor(id: PDFTextEngineID.embedded, title: "Text in the PDF", isAvailable: true,
                                    subtitle: "On scanned books, this is Internet Archive's OCR")
        ] + ocrEngines
    }

    func title(ocrEngines: [PDFTextEngineDescriptor]) -> String {
        options(ocrEngines: ocrEngines).first { $0.id == selectedID }?.title ?? "Automatic"
    }
}

/// Keeps OCR implementation details out of the reader. Internet Archive's
/// generated Text PDFs deliberately prefer Apple's on-device recognition,
/// while born-digital originals retain their exact embedded text.
enum PDFPageTextPolicy {
    static func prefersLocalRecognition(for file: ArchiveFile) -> Bool {
        let format = file.format?.lowercased() ?? ""
        if format.contains("text pdf") || format.contains("searchable pdf") { return true }
        return file.source?.lowercased() == "derivative" && file.original != nil
    }

    static func hasUsableEmbeddedText(_ text: String) -> Bool {
        let normalized = normalize(text)
        let alphanumeric = normalized.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.alphanumerics.contains(scalar) { count += 1 }
        }
        return alphanumeric >= 12
    }

    static func hasMeaningfulRecognition(_ text: String) -> Bool {
        let normalized = normalize(text)
        let alphanumeric = normalized.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.alphanumerics.contains(scalar) { count += 1 }
        }
        return alphanumeric >= 4
    }

    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n?", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "[\t ]+\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An explicit available engine is exclusive, which makes the preference
    /// meaningful. Missing or unavailable saved engines degrade to Automatic
    /// without nagging the reader or erasing a future extension's identifier.
    static func recognitionOrder(
        selectedEngineID: String,
        availableEngineIDs: [String]
    ) -> [String] {
        if selectedEngineID == PDFTextEngineID.embedded { return [] }
        if selectedEngineID == PDFTextEngineID.automatic { return availableEngineIDs }
        if availableEngineIDs.contains(selectedEngineID) { return [selectedEngineID] }
        return availableEngineIDs
    }
}

/// An immutable page handoff. PDFKit and Core Graphics do not annotate their
/// page objects Sendable, but CGPDFPage is immutable and is only rendered here.
final class PDFPageRenderSource: @unchecked Sendable {
    let page: CGPDFPage
    let embeddedText: String

    @MainActor
    init?(page: PDFPage) {
        guard let pageRef = page.pageRef else { return nil }
        self.page = pageRef
        embeddedText = page.string ?? ""
    }

    func image(maxDimension: Int = 3_000) -> CGImage? {
        let bounds = page.getBoxRect(.cropBox)
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(3, CGFloat(maxDimension) / max(bounds.width, bounds.height))
        let width = max(1, Int((bounds.width * scale).rounded(.up)))
        let height = max(1, Int((bounds.height * scale).rounded(.up)))
        guard width <= maxDimension, height <= maxDimension,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        // getDrawingTransform never scales a page up. Asked to fill a canvas larger
        // than the page, it draws the page at its own size in the middle, so OCR got
        // a 1283-point magazine page at 1x inside a 3000-pixel canvas. Scale the
        // context ourselves and let the transform fit the page at its own size,
        // which keeps its handling of the page's rotation.
        context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: bounds.size), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }
}

struct PDFPageTextRequest: Sendable {
    let page: PDFPageRenderSource
    let documentKey: String
    let pageIndex: Int
    let expectedBytes: Int64?
    let preferLocalRecognition: Bool
    let selectedEngineID: String
}

/// The default path remains automatic, while a remembered engine preference is
/// respected when present. Results live in the existing bounded app cache.
actor PDFPageTextRecognizer {
    // 3: pages were recognized from a render at 1x in the middle of the canvas.
    private static let cacheVersion = 3
    private static let cacheLifetime: TimeInterval = 60 * 60 * 24 * 365 * 10
    private let store: SQLiteStore
    let engineDescriptors: [PDFTextEngineDescriptor]
    private let registry: PDFPageTextEngineRegistry
    private var memory: [String: PDFPageTextResult] = [:]

    init(store: SQLiteStore, registry: PDFPageTextEngineRegistry = .builtIn) {
        self.store = store
        self.registry = registry
        engineDescriptors = registry.descriptors
    }

    func text(for request: PDFPageTextRequest) async -> PDFPageTextResult {
        let embedded = PDFPageTextPolicy.normalize(request.page.embeddedText)
        if request.selectedEngineID == PDFTextEngineID.embedded {
            return embeddedResult(embedded)
        }
        if request.selectedEngineID == PDFTextEngineID.automatic,
           !request.preferLocalRecognition,
           PDFPageTextPolicy.hasUsableEmbeddedText(embedded) {
            return PDFPageTextResult(text: embedded, engineID: PDFTextEngineID.embedded)
        }

        let key = cacheKey(for: request)
        if let result = memory[key] { return result }
        if let entry = try? await store.cacheEntry(key: key), entry.kind == "page-ocr",
           let result = try? JSONDecoder().decode(PDFPageTextResult.self, from: entry.response) {
            memory[key] = result
            return result
        }

        guard !Task.isCancelled,
              let image = await Task.detached(priority: .userInitiated, operation: { request.page.image() }).value else {
            return fallback(embedded)
        }

        let availableIDs = registry.descriptors.filter(\.isAvailable).map(\.id)
        let engineIDs = PDFPageTextPolicy.recognitionOrder(
            selectedEngineID: request.selectedEngineID,
            availableEngineIDs: availableIDs
        )
        var result: PDFPageTextResult?
        for engineID in engineIDs where !Task.isCancelled {
            guard let engine = registry.engine(id: engineID) else { continue }
            let text = PDFPageTextPolicy.normalize(await engine.recognize(image))
            if PDFPageTextPolicy.hasMeaningfulRecognition(text) {
                result = PDFPageTextResult(text: text, engineID: engineID)
                break
            }
        }

        let resolved = result ?? fallback(embedded)
        memory[key] = resolved
        if !Task.isCancelled, let data = try? JSONEncoder().encode(resolved) {
            try? await store.storeCache(
                key: key,
                kind: "page-ocr",
                response: data,
                snapshot: nil,
                maxAge: Self.cacheLifetime
            )
        }
        return resolved
    }

    private func fallback(_ embedded: String) -> PDFPageTextResult {
        embeddedResult(embedded)
    }

    private func embeddedResult(_ embedded: String) -> PDFPageTextResult {
        if !embedded.isEmpty {
            return PDFPageTextResult(text: embedded, engineID: PDFTextEngineID.embedded)
        }
        return PDFPageTextResult(text: "", engineID: nil)
    }

    private func cacheKey(for request: PDFPageTextRequest) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let available = registry.descriptors.filter(\.isAvailable).map(\.id).joined(separator: ",")
        let route = "\(request.selectedEngineID):\(available)"
        return "ocr:\(Self.cacheVersion):\(os):\(route):\(request.documentKey):\(request.expectedBytes ?? -1):\(request.pageIndex)"
    }
}
