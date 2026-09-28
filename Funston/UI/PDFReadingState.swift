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
    static let appleDocuments = "apple.documents"
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

    /// Recognizes the page once to find where the text is, then recognizes each
    /// column run on its own, in reading order, and joins its lines into
    /// paragraphs. Sorting a whole page's lines top to bottom interleaves
    /// columns, and a whole-page pass misses lines a crop finds (82% of the
    /// words on 73 Magazine, December 1981 page 6, against 90%).
    func recognize(_ image: CGImage) async -> String {
        let pageAspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        let lines = await Self.lines(in: image)
        var columns: [(lines: [PDFTextBox], aspectRatio: CGFloat)] = []
        for run in PDFTextLayout.runs(PDFTextLayout.blocks(lines)) {
            guard !Task.isCancelled else { return "" }
            // One line has nothing a second pass would put in order.
            guard run.count > 1 else { columns.append((run, pageAspect)); continue }
            let region = PDFTextLayout.region(of: run)
            let pixels = CGRect(x: region.minX * CGFloat(image.width), y: region.minY * CGFloat(image.height),
                                width: region.width * CGFloat(image.width), height: region.height * CGFloat(image.height)).integral
            // A crop that can't be made falls back to the lines already found for it.
            if let crop = image.cropping(to: pixels), case let cropped = await Self.lines(in: crop), !cropped.isEmpty {
                columns.append((cropped.sorted { $0.rect.minY < $1.rect.minY }, pixels.width / max(pixels.height, 1)))
            } else {
                columns.append((run, pageAspect))
            }
        }
        let normalized = columns.map { column in
            (column.lines.map { PDFTextBox(text: PDFPageTextPolicy.normalize($0.text), rect: $0.rect) }, column.aspectRatio)
        }
        return await MainActor.run {
            var paragraphs: [String] = []
            for (lines, aspectRatio) in normalized {
                let next = PDFTextLayout.paragraphs(lines, aspectRatio: aspectRatio, isWord: SpellingDictionary.isWord)
                PDFTextLayout.appending(next, to: &paragraphs, isWord: SpellingDictionary.isWord)
            }
            return paragraphs.joined(separator: "\n\n")
        }
    }

    private static func lines(in image: CGImage) async -> [PDFTextBox] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        guard let observations = try? await request.perform(on: image, orientation: .up) else { return [] }
        return observations.compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox.cgRect
            return PDFTextBox(text: text, rect: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
        }
    }
}

/// Apple's document recognizer (iOS 26 and later) finds columns, paragraphs and
/// lists itself. On 73 Magazine it is about twice as fast as column-by-column
/// Vision, but on the December 1981 scan it kept 75% of lines in order and
/// dropped some altogether.
private struct PDFDocumentTextEngine: PDFPageOCREngine {
    var descriptor: PDFTextEngineDescriptor {
        let available: Bool
        if #available(iOS 26.0, *) { available = true } else { available = false }
        return PDFTextEngineDescriptor(id: PDFTextEngineID.appleDocuments, title: "Apple Document Reader",
                                       isAvailable: available, subtitle: "Faster, but can skip lines on rough scans")
    }

    func recognize(_ image: CGImage) async -> String {
        guard #available(iOS 26.0, *) else { return "" }
        guard let observations = try? await RecognizeDocumentsRequest().perform(on: image, orientation: .up) else { return "" }
        func topLeft(_ rect: NormalizedRect) -> CGRect {
            let box = rect.cgRect
            return CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        }
        let fragments = observations.flatMap { observation in
            observation.document.paragraphs.compactMap { paragraph -> (text: String, firstLine: CGRect, lastLine: CGRect)? in
                guard let first = paragraph.lines.first, let last = paragraph.lines.last else { return nil }
                return (paragraph.transcript.replacingOccurrences(of: "\n", with: " "),
                        topLeft(first.boundingBox), topLeft(last.boundingBox))
            }
        }
        return await MainActor.run { PDFTextLayout.stitch(fragments, isWord: SpellingDictionary.isWord) }.joined(separator: "\n\n")
    }
}

struct PDFPageTextEngineRegistry: Sendable {
    let engines: [any PDFPageOCREngine]

    init(engines: [any PDFPageOCREngine]) {
        self.engines = engines
    }

    static var builtIn: Self {
        // Automatic tries these in order. Lines kept in order on 73 Magazine
        // (August 1976 pages 30 and 40, December 1981 page 6): column-by-column
        // Vision 100/99/99%, the document reader 100/99/75% (it also drops lines
        // on the December scan), Live Text 100/52/99%.
        Self(engines: [PDFVisionTextEngine(), PDFDocumentTextEngine(), PDFLiveTextEngine()])
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
    // 4: Vision reads column by column; the document reader was added.
    // 5: Vision finds columns under headlines and beside boxes; Automatic tries it first.
    // 6: Vision joins lines into paragraphs.
    private static let cacheVersion = 6
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
