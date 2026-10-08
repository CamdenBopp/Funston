import XCTest
import PDFKit
import UIKit
@testable import Funston

private actor CountingPDFEngine: PDFPageOCREngine {
    nonisolated let descriptor: PDFTextEngineDescriptor
    private let result: PDFRecognizedPage
    private var count = 0
    init(id: String, result: PDFRecognizedPage) {
        descriptor = PDFTextEngineDescriptor(id: id, title: id, isAvailable: true)
        self.result = result
    }
    func recognize(_ image: CGImage) async -> PDFRecognizedPage {
        count += 1
        try? await Task.sleep(for: .milliseconds(80))
        return result
    }
    func invocations() -> Int { count }
}

@MainActor
final class PDFLineAccessibilityTests: XCTestCase {
    func testImageAndTextRequestsShareOneRecognitionAndPersistTheSameLineBoxes() async throws {
        let store = try SQLiteStore(url: URL(string: "file::memory:")!)
        let engine = CountingPDFEngine(id: "test.lines", result: sampleRecognition())
        let registry = PDFPageTextEngineRegistry(engines: [engine])
        let recognizer = PDFPageTextRecognizer(store: store, registry: registry)
        let request = try request(engine: engine.descriptor.id)
        async let image = recognizer.text(for: request.forPageImage)
        async let text = recognizer.text(for: request)
        let (a, b) = await (image, text)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.lines, sampleRecognition().lines)
        let count = await engine.invocations()
        XCTAssertEqual(count, 1)
        let reopened = PDFPageTextRecognizer(store: store, registry: registry)
        let cached = await reopened.text(for: request)
        XCTAssertEqual(cached, a)
        let finalCount = await engine.invocations()
        XCTAssertEqual(finalCount, 1, "Cached geometry must not require a second recognition")
    }

    func testCancelledPrefetchDoesNotCancelTheSharedRecognition() async throws {
        let store = try SQLiteStore(url: URL(string: "file::memory:")!)
        let engine = CountingPDFEngine(id: "test.lines", result: sampleRecognition())
        let recognizer = PDFPageTextRecognizer(store: store, registry: PDFPageTextEngineRegistry(engines: [engine]))
        let request = try request(engine: engine.descriptor.id)
        let prefetch = Task { await recognizer.text(for: request) }
        while await engine.invocations() == 0 { await Task.yield() }
        prefetch.cancel()
        let visible = await recognizer.text(for: request)
        XCTAssertFalse(visible.lines.isEmpty)
        let count = await engine.invocations()
        XCTAssertEqual(count, 1)
    }

    func testLiveTextTranscriptIsNeverMatchedToAutomaticLineBoxes() async throws {
        let store = try SQLiteStore(url: URL(string: "file::memory:")!)
        let live = CountingPDFEngine(id: PDFTextEngineID.appleLiveText, result: PDFRecognizedPage(text: "Live Text has different words."))
        let automatic = CountingPDFEngine(id: PDFTextEngineID.appleVision, result: sampleRecognition())
        let recognizer = PDFPageTextRecognizer(store: store, registry: PDFPageTextEngineRegistry(engines: [automatic, live]))
        let request = try request(engine: PDFTextEngineID.appleLiveText)
        let transcript = await recognizer.text(for: request)
        let image = await recognizer.text(for: request.forPageImage)
        XCTAssertEqual(transcript.engineID, PDFTextEngineID.appleLiveText)
        XCTAssertEqual(transcript.text, "Live Text has different words.")
        XCTAssertTrue(transcript.lines.isEmpty)
        XCTAssertEqual(image.engineID, PDFTextEngineID.appleVision)
        XCTAssertEqual(image.lines, sampleRecognition().lines)
        XCTAssertFalse(image.text.contains("Live Text"))
        let liveCount = await live.invocations(), automaticCount = await automatic.invocations()
        XCTAssertEqual(liveCount, 1); XCTAssertEqual(automaticCount, 1)
        XCTAssertEqual(PDFPageTextEngineRegistry.builtIn.descriptors.first { $0.id == PDFTextEngineID.appleLiveText }?.subtitle,
                       "Text view only; page view uses Automatic")
    }

    func testImageElementsPreserveReadingOrderAndFramesFollowZoom() async throws {
        let document = try document()
        let page = try XCTUnwrap(document.page(at: 0))
        let source = try XCTUnwrap(PDFPageRenderSource(page: page))
        let view = PDFLineAccessibleView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        view.displayMode = .singlePage
        view.document = document
        view.autoScales = false
        view.scaleFactor = 1
        view.layoutIfNeeded()
        view.install(PDFPageTextResult(text: "Text", engineID: "test.lines", lines: sampleRecognition().lines), source: source, page: page, index: 0)
        let elements = try XCTUnwrap(view.accessibilityElements as? [PDFRecognizedLineElement])
        XCTAssertEqual(elements.map(\.accessibilityLabel), ["Left column, first line.", "Left column, last line.", "Right column, first line."])
        view.install(PDFPageTextResult(text: "Text", engineID: "test.lines", lines: sampleRecognition().lines), source: source, page: page, index: 0)
        XCTAssertTrue(view.accessibilityElement(at: 0) as AnyObject === elements[0], "A cache hit must keep VoiceOver focus on the same element")
        XCTAssertEqual(view.accessibilityElementCount(), 3)
        XCTAssertEqual(view.index(ofAccessibilityElement: elements[1]), 1)
        let line = sampleRecognition().lines[0]
        let expectedPageRect = CGRect(x: 60, y: 680, width: 240, height: 40)
        assertRect(source.pageRect(for: line.rect), equals: expectedPageRect)
        assertRect(elements[0].accessibilityFrameInContainerSpace, equals: view.convert(expectedPageRect, from: page))
        let before = elements[0].accessibilityFrameInContainerSpace
        let screenBefore = elements[0].accessibilityFrame
        view.scaleFactor = 2
        view.layoutIfNeeded()
        let after = elements[0].accessibilityFrameInContainerSpace
        XCTAssertEqual(after.width, before.width * 2, accuracy: 0.5)
        XCTAssertEqual(after.height, before.height * 2, accuracy: 0.5)
        XCTAssertEqual(elements[0].accessibilityFrame.width, screenBefore.width * 2, accuracy: 0.5)
        elements[1].accessibilityElementDidBecomeFocused()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(view.scaleFactor, 2, accuracy: 0.01, "Swiping to a line preserves the reader's zoom")
        XCTAssertTrue(view.bounds.intersects(elements[1].accessibilityFrameInContainerSpace), "VoiceOver focus scrolls an offscreen line into view")
        view.clearRecognizedLines()
        XCTAssertFalse((view.accessibilityElements ?? []).contains { $0 is PDFRecognizedLineElement })
    }

    func testEmbeddedLineBoxesRoundTripCropOriginsAndRotation() throws {
        let original = try document()
        let originalPage = try XCTUnwrap(original.page(at: 0))
        originalPage.setBounds(CGRect(x: 20, y: 30, width: 560, height: 740), for: .cropBox)
        originalPage.rotation = 90
        let reopened = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(original.dataRepresentation())))
        let page = try XCTUnwrap(reopened.page(at: 0))
        let source = try XCTUnwrap(PDFPageRenderSource(page: page))
        let native = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: page.numberOfCharacters))?.selectionsByLine().first)
        let line = try XCTUnwrap(source.embeddedLines.first)
        assertRect(source.pageRect(for: line.rect), equals: native.bounds(for: page))
    }

    func testVisionReturnsPageRelativeLineBoxesFromTheSameMagazineRecognition() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "73-magazine-1976-08-page40", withExtension: "jpg"))
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
        let engine = try XCTUnwrap(PDFPageTextEngineRegistry.builtIn.engine(id: PDFTextEngineID.appleVision))
        let result = await engine.recognize(image)
        XCTAssertGreaterThan(result.lines.count, 30)
        XCTAssertFalse(result.text.isEmpty)
        for line in result.lines {
            XCTAssertFalse(line.text.isEmpty)
            XCTAssertGreaterThan(line.rect.width, 0)
            XCTAssertGreaterThan(line.rect.height, 0)
            XCTAssertGreaterThanOrEqual(line.rect.minX, -0.0001)
            XCTAssertGreaterThanOrEqual(line.rect.minY, -0.0001)
            XCTAssertLessThanOrEqual(line.rect.maxX, 1.0001)
            XCTAssertLessThanOrEqual(line.rect.maxY, 1.0001)
        }
    }

    private func sampleRecognition() -> PDFRecognizedPage {
        PDFRecognizedPage(text: "Left column, first line.\nLeft column, last line.\nRight column, first line.", lines: [
            PDFTextBox(text: "Left column, first line.", rect: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.05)),
            PDFTextBox(text: "Left column, last line.", rect: CGRect(x: 0.1, y: 0.7, width: 0.4, height: 0.05)),
            PDFTextBox(text: "Right column, first line.", rect: CGRect(x: 0.55, y: 0.1, width: 0.4, height: 0.05))
        ])
    }
    private func document() throws -> PDFDocument {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800))
        let data = renderer.pdfData { context in
            context.beginPage()
            ("First printed line.\nSecond printed line." as NSString).draw(in: CGRect(x: 60, y: 80, width: 450, height: 100),
                withAttributes: [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.black])
        }
        return try XCTUnwrap(PDFDocument(data: data))
    }
    private func request(engine: String) throws -> PDFPageTextRequest {
        let page = try XCTUnwrap(try document().page(at: 0))
        return PDFPageTextRequest(page: try XCTUnwrap(PDFPageRenderSource(page: page)), documentKey: "fixture", pageIndex: 0,
            expectedBytes: nil, preferLocalRecognition: true, selectedEngineID: engine)
    }
    private func assertRect(_ actual: CGRect, equals expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.01, file: file, line: line)
    }
}
