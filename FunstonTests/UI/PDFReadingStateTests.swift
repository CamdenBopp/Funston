import XCTest
import PDFKit
import UIKit
@testable import Funston

@MainActor
final class PDFReadingStateTests: XCTestCase {
    func testReaderControlsRequireExplicitActionWithVoiceOverAndResetOnExit() {
        let reader = UIViewController()
        let controls = ReaderControls(reader: reader, pageView: reader.view)
        controls.tapped(voiceOverRunning: true)
        XCTAssertFalse(controls.isHidden)
        controls.tapped(voiceOverRunning: false)
        XCTAssertTrue(controls.isHidden)
        XCTAssertEqual(controls.page.accessibilityCustomActions?.first?.name, "Show controls")
        XCTAssertTrue(controls.page.accessibilityPerformMagicTap())
        XCTAssertFalse(controls.isHidden)
        controls.toggle()
        var page = 1
        controls.page.adjust = { page += $0 }
        controls.page.accessibilityIncrement()
        XCTAssertEqual(page, 2)
        controls.restore()
        XCTAssertFalse(controls.isHidden)
        XCTAssertEqual(controls.page.accessibilityCustomActions?.first?.name, "Hide controls")
    }

    func testRecognitionPreferenceIsRememberedPerBook() throws {
        let suite = "BookEngineTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        PDFTextEnginePreference(defaults: defaults, bookKey: "a").select(PDFTextEngineID.appleVision)
        XCTAssertEqual(PDFTextEnginePreference(defaults: defaults, bookKey: "a").selectedID, PDFTextEngineID.appleVision)
        XCTAssertEqual(PDFTextEnginePreference(defaults: defaults, bookKey: "b").selectedID, PDFTextEngineID.automatic)
    }

    func testPageIndicatorIsOneAdjustableElement() {
        let label = AdjustablePageLabel()
        label.isAccessibilityElement = true
        label.accessibilityTraits = .adjustable
        var page = 2
        label.adjustPage = { page += $0 }
        label.accessibilityIncrement()
        XCTAssertEqual(page, 3)
        label.accessibilityDecrement()
        XCTAssertEqual(page, 2)
        XCTAssertTrue(label.accessibilityTraits.contains(.adjustable))
    }

    func testRapidNavigationFlushesOnlyTheFinalPage() throws {
        let suite = "PDFReadingStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let progress = PDFReadingProgress(key: "page", defaults: defaults, delay: .seconds(60))
        for page in 1...300 { progress.record(page: page) }
        XCTAssertEqual(defaults.integer(forKey: "page"), 0)
        progress.flush()
        XCTAssertEqual(defaults.integer(forKey: "page"), 300)
        progress.record(page: 12)
        progress.flush()
        XCTAssertEqual(defaults.integer(forKey: "page"), 12, "Leaving the reader must save immediately")
    }

    func testDebounceSavesTheLatestPageAfterNavigationSettles() async throws {
        let suite = "PDFReadingStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let progress = PDFReadingProgress(key: "page", defaults: defaults, delay: .milliseconds(20))
        progress.record(page: 10)
        progress.record(page: 20)
        try await Task.sleep(for: .milliseconds(80))
        withExtendedLifetime(progress) {}
        XCTAssertEqual(defaults.integer(forKey: "page"), 20)
    }

    func testChangingNativeLayoutKeepsTheCurrentPageAndText() async throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800))
        let data = renderer.pdfData { context in
            for page in 1...12 {
                context.beginPage()
                ("Searchable page \(page)" as NSString).draw(at: CGPoint(x: 50, y: 50), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            }
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        view.document = document
        view.isFindInteractionEnabled = true
        PDFReadingLayout.continuous.apply(to: view)
        view.go(to: try XCTUnwrap(document.page(at: 5)))
        PDFReadingLayout.pages.apply(to: view)
        XCTAssertTrue(view.isUsingPageViewController)
        XCTAssertEqual(document.index(for: try XCTUnwrap(view.currentPage)), 5)
        PDFReadingLayout.continuous.apply(to: view)
        XCTAssertFalse(view.isUsingPageViewController)
        XCTAssertEqual(document.index(for: try XCTUnwrap(view.currentPage)), 5)
        XCTAssertNotNil(view.findInteraction)
        XCTAssertTrue(try XCTUnwrap(view.currentPage?.string).contains("Searchable page 6"))
    }

    /// A page smaller than the OCR canvas must fill it. getDrawingTransform never
    /// scales up, so the page used to sit at 1x in the middle of a white canvas:
    /// Vision read 11 lines of 73 Magazine page 40 that way, 214 at full size.
    func testOCRRenderFillsTheCanvasForSmallPages() throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800))
        let data = renderer.pdfData { context in
            context.beginPage()
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        }
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        let image = try XCTUnwrap(PDFPageRenderSource(page: page)?.image(maxDimension: 3_000))
        XCTAssertEqual(image.width, 1_800, "Scale is capped at 3x")
        XCTAssertEqual(image.height, 2_400)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let probe = UIGraphicsImageRenderer(size: CGSize(width: image.width, height: image.height), format: format).image { context in
            context.cgContext.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let pixels = try XCTUnwrap(probe.cgImage?.dataProvider?.data as Data?)
        let bytesPerRow = try XCTUnwrap(probe.cgImage?.bytesPerRow)
        for (x, y) in [(10, 10), (image.width - 10, 10), (10, image.height - 10), (image.width - 10, image.height - 10)] {
            let brightness = pixels[y * bytesPerRow + x * 4]
            XCTAssertLessThan(brightness, 40, "Corner (\(x), \(y)) is blank: the page didn't fill the canvas")
        }
    }

    func testAutomaticTextPolicyUsesLocalRecognitionForArchiveDerivatives() {
        let textPDF = ArchiveFile(
            name: "book_text.pdf",
            format: "Text PDF",
            source: "derivative",
            original: "book.pdf"
        )
        let genericDerivative = ArchiveFile(
            name: "scan.pdf",
            format: "PDF",
            source: "derivative",
            original: "scan_jp2.zip"
        )
        let bornDigital = ArchiveFile(name: "report.pdf", format: "PDF", source: "original")

        XCTAssertTrue(PDFPageTextPolicy.prefersLocalRecognition(for: textPDF))
        XCTAssertTrue(PDFPageTextPolicy.prefersLocalRecognition(for: genericDerivative))
        XCTAssertFalse(PDFPageTextPolicy.prefersLocalRecognition(for: bornDigital))
    }

    func testAutomaticTextPolicyKeepsUsefulBornDigitalTextAndRejectsNoise() {
        XCTAssertTrue(PDFPageTextPolicy.hasUsableEmbeddedText("A complete sentence from a born-digital PDF."))
        XCTAssertFalse(PDFPageTextPolicy.hasUsableEmbeddedText("  1 |  "))
        XCTAssertTrue(PDFPageTextPolicy.hasMeaningfulRecognition("Title"))
        XCTAssertFalse(PDFPageTextPolicy.hasMeaningfulRecognition("-- 1 --"))
    }

    func testTextEnginePreferenceDefaultsToAutomaticAndPersistsOneChoice() throws {
        let suite = "PDFReadingStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = PDFTextEnginePreference(defaults: defaults)

        XCTAssertEqual(preference.selectedID, PDFTextEngineID.automatic)
        preference.select(PDFTextEngineID.appleLiveText)
        XCTAssertEqual(PDFTextEnginePreference(defaults: defaults).selectedID, PDFTextEngineID.appleLiveText)
    }

    func testTextEngineRegistryAcceptsAnAdditionalEngineWithoutChangingTheReader() {
        struct AdditionalEngine: PDFPageOCREngine {
            let descriptor = PDFTextEngineDescriptor(id: "example.custom-ocr", title: "Example OCR", isAvailable: true)
            func recognize(_ image: CGImage) async -> PDFRecognizedPage { PDFRecognizedPage(text: "Example") }
        }

        let registry = PDFPageTextEngineRegistry(engines: [AdditionalEngine()])
        XCTAssertEqual(registry.descriptors, [
            PDFTextEngineDescriptor(id: "example.custom-ocr", title: "Example OCR", isAvailable: true)
        ])
    }

    func testAutomaticPrefersAppleDocumentReader() {
        XCTAssertEqual(PDFPageTextEngineRegistry.builtIn.descriptors.first?.id, PDFTextEngineID.appleDocuments)
    }

    func testExplicitEngineIsRememberedWithoutBecomingARepeatedPrompt() {
        let available = [PDFTextEngineID.appleLiveText, PDFTextEngineID.appleVision]
        XCTAssertEqual(
            PDFPageTextPolicy.recognitionOrder(
                selectedEngineID: PDFTextEngineID.appleVision,
                availableEngineIDs: available
            ),
            [PDFTextEngineID.appleVision]
        )
        XCTAssertEqual(
            PDFPageTextPolicy.recognitionOrder(
                selectedEngineID: "extension.not-installed",
                availableEngineIDs: available
            ),
            [PDFTextEngineID.appleVision],
            "An unavailable extension uses Automatic, whose engines provide geometry"
        )
    }

    func testRecognizedTextNormalizationPreservesParagraphsWithoutLayoutNoise() {
        XCTAssertEqual(
            PDFPageTextPolicy.normalize("First line  \r\n\r\n\r\nSecond\t line\n"),
            "First line\n\nSecond\t line"
        )
    }
}
