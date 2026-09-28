import XCTest
import PDFKit
import UIKit
@testable import Archive

@MainActor
final class PDFScreenRenderingTests: XCTestCase {
    private func fixture() throws -> (PDFDocument, PDFScreenRendering) {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800)).pdfData { context in
            context.beginPage()
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
            UIColor.blue.setFill()
            context.cgContext.fill(CGRect(x: 300, y: 400, width: 300, height: 400))
            ("Searchable archival text" as NSString).draw(at: CGPoint(x: 30, y: 450), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let rendering = PDFScreenRendering()
        document.delegate = rendering
        return (document, rendering)
    }

    private func draw(_ page: PDFPage, width: Int = 600) throws -> CGImage {
        try PDFTestDrawResult.draw(page, width: width).image
    }

    func testMainThreadCacheMissDoesNotCreateRaster() throws {
        let (document, rendering) = try fixture()
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertTrue(page is PDFScreenPage)
        _ = try draw(page)
        XCTAssertEqual(rendering.cache.statistics.renders, 0)
        XCTAssertEqual(rendering.cache.statistics.bytes, 0)
    }

    func testRepeatedScreenDrawsReuseRasterWithoutReplacingSearchableText() async throws {
        let (document, rendering) = try fixture()
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertTrue(page is PDFScreenPage)
        let owner = PDFTestDrawOwner(document: document, page: page, rendering: rendering)
        let firstResult = try await Task.detached { try owner.draw() }.value
        let secondResult = try await Task.detached { try owner.draw() }.value
        XCTAssertFalse(firstResult.onMainThread)
        XCTAssertFalse(secondResult.onMainThread)
        let first = firstResult.image
        XCTAssertEqual(rendering.cache.statistics.renders, 1)
        XCTAssertGreaterThan(rendering.cache.statistics.hits, 0)
        XCTAssertTrue(try XCTUnwrap(page.string).contains("Searchable archival text"))
        XCTAssertEqual(document.findString("archival", withOptions: []).count, 1)
        let zoomed = try await Task.detached { try owner.draw(width: 2000) }.value
        XCTAssertFalse(zoomed.onMainThread)
        XCTAssertEqual(rendering.cache.statistics.renders, 1, "Zoom beyond cache resolution uses native drawing")
        // Compare colored quadrants to an unmodified PDFPage, catching image flips.
        let original = try XCTUnwrap(PDFDocument(data: document.dataRepresentation()!))
        let reference = try draw(try XCTUnwrap(original.page(at: 0)))
        let a = try XCTUnwrap(first.dataProvider?.data) as Data
        let b = try XCTUnwrap(reference.dataProvider?.data) as Data
        for (x, y) in [(100, 100), (500, 100), (100, 700), (500, 700)] {
            for channel in 0..<3 {
                XCTAssertEqual(Int(a[y * first.bytesPerRow + x * 4 + channel]),
                    Int(b[y * reference.bytesPerRow + x * 4 + channel]), accuracy: 2)
            }
        }
    }

    func testAnnotatedPagesKeepTheNativeDrawingPath() async throws {
        let (document, rendering) = try fixture()
        let page = try XCTUnwrap(document.page(at: 0))
        page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 30, height: 30), forType: .square, withProperties: nil))
        let owner = PDFTestDrawOwner(document: document, page: page, rendering: rendering)
        let result = try await Task.detached { try owner.draw() }.value
        XCTAssertFalse(result.onMainThread)
        XCTAssertEqual(rendering.cache.statistics.renders, 0)
    }

    func testConcurrentBackgroundRequestsShareOneRaster() async throws {
        let (document, rendering) = try fixture()
        let page = try XCTUnwrap(document.page(at: 0))
        let owner = PDFTestDrawOwner(document: document, page: page, rendering: rendering)
        // Detached tasks cannot inline the synchronous body onto the main actor.
        // Each job has its own CGContext; the immutable PDF page is shared just
        // as PDFKit shares it between tile workers. Do not mutate it until joined.
        let jobs = (0..<4).map { _ in Task.detached { try owner.draw() } }
        for job in jobs {
            let result = try await job.value
            XCTAssertFalse(result.onMainThread)
        }
        XCTAssertEqual(rendering.cache.statistics.renders, 1)
        XCTAssertGreaterThanOrEqual(rendering.cache.statistics.hits, 3)
    }

    func testDistinctPagesKeepTheirOwnRasterAcrossCacheHits() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            context.cgContext.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.cgContext.fill(bounds)
            context.beginPage()
            context.cgContext.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.cgContext.fill(bounds)
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let rendering = PDFScreenRendering()
        document.delegate = rendering
        let redPage = try XCTUnwrap(document.page(at: 0))
        let bluePage = try XCTUnwrap(document.page(at: 1))
        let nativeDocument = try XCTUnwrap(PDFDocument(data: data))
        let nativeRed = try draw(try XCTUnwrap(nativeDocument.page(at: 0)))
        let nativeBlue = try draw(try XCTUnwrap(nativeDocument.page(at: 1)))
        let nativeRedPixels = try XCTUnwrap(nativeRed.dataProvider?.data) as Data
        let nativeBluePixels = try XCTUnwrap(nativeBlue.dataProvider?.data) as Data
        let redOffset = 400 * nativeRed.bytesPerRow + 300 * 4
        let blueOffset = 400 * nativeBlue.bytesPerRow + 300 * 4
        let redChannels = (0..<3).map { Int(nativeRedPixels[redOffset + $0]) }
        let blueChannels = (0..<3).map { Int(nativeBluePixels[blueOffset + $0]) }
        XCTAssertNotEqual(redChannels, blueChannels, "Fixture pages must be visibly distinct")
        XCTAssertTrue(redPage is PDFScreenPage)
        XCTAssertTrue(bluePage is PDFScreenPage)
        let red = PDFTestDrawOwner(document: document, page: redPage, rendering: rendering)
        let blue = PDFTestDrawOwner(document: document, page: bluePage, rendering: rendering)
        // Same dimensions/display box and shared document cache deliberately
        // leave page identity as the distinguishing key. Revisit both pages.
        // Compare native pixels in the same bitmap format instead of assuming
        // an RGB byte order for Core Graphics' default byte-order option.
        for (owner, expected) in [(red, redChannels), (blue, blueChannels),
                                  (red, redChannels), (blue, blueChannels)] {
            let result = try await Task.detached { try owner.draw() }.value
            XCTAssertFalse(result.onMainThread)
            let pixels = try XCTUnwrap(result.image.dataProvider?.data) as Data
            let offset = 400 * result.image.bytesPerRow + 300 * 4
            for channel in 0..<3 {
                XCTAssertEqual(Int(pixels[offset + channel]), expected[channel], accuracy: 2)
            }
        }
        XCTAssertEqual(rendering.cache.statistics.renders, 2)
        XCTAssertGreaterThanOrEqual(rendering.cache.statistics.hits, 2)
    }

    func testTransparentPagePreservesNonwhiteDestinationBackground() async throws {
        let (document, rendering) = try fixture()
        let page = try XCTUnwrap(document.page(at: 0))
        let original = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(document.dataRepresentation())))
        let originalPage = try XCTUnwrap(original.page(at: 0))
        let owner = PDFTestDrawOwner(document: document, page: page, rendering: rendering)
        let cached = try await Task.detached { try owner.draw(nonwhiteBackground: true) }.value
        let reference = try PDFTestDrawResult.draw(originalPage, width: 600, nonwhiteBackground: true)
        XCTAssertFalse(cached.onMainThread)
        XCTAssertEqual(rendering.cache.statistics.renders, 1)
        let a = try XCTUnwrap(cached.image.dataProvider?.data) as Data
        let b = try XCTUnwrap(reference.image.dataProvider?.data) as Data
        // The fixture paints only two quadrants; the other two must retain the
        // destination's green, not become an opaque white raster background.
        for (x, y) in [(100, 100), (500, 100), (100, 700), (500, 700)] {
            for channel in 0..<3 {
                XCTAssertEqual(Int(a[y * cached.image.bytesPerRow + x * 4 + channel]),
                    Int(b[y * reference.image.bytesPerRow + x * 4 + channel]), accuracy: 2)
            }
        }
    }

    func testRasterCacheHasAHardMemoryCeilingAndEvictsLeastRecentlyUsed() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let cost = image.bytesPerRow * image.height
        let cache = PDFScreenRasterCache(limit: cost * 2)
        let keys = (1...3).map { PDFScreenRasterCache.Key(page: $0, box: 0, bounds: CGRect(x: 0, y: 0, width: 32, height: 32)) }
        cache.insert(image, for: keys[0]); cache.insert(image, for: keys[1])
        XCTAssertNotNil(cache.image(for: keys[0]))
        cache.insert(image, for: keys[2])
        XCTAssertNil(cache.image(for: keys[1]))
        XCTAssertEqual(cache.statistics.bytes, cost * 2)
        cache.removeAll()
        XCTAssertEqual(cache.statistics.bytes, 0)
    }
}

/// Strong ownership across detached draws; the test does not mutate/read PDF
/// metadata while jobs run. The rendering delegate's cache is internally locked.
private final class PDFTestDrawOwner: @unchecked Sendable {
    let document: PDFDocument
    let page: PDFPage
    let rendering: PDFScreenRendering
    init(document: PDFDocument, page: PDFPage, rendering: PDFScreenRendering) {
        self.document = document
        self.page = page
        self.rendering = rendering
    }
    func draw(width: Int = 600, nonwhiteBackground: Bool = false) throws -> PDFTestDrawResult {
        try PDFTestDrawResult.draw(page, width: width, nonwhiteBackground: nonwhiteBackground)
    }
}

/// CGImage is immutable after creation; no CGContext crosses thread boundaries.
private struct PDFTestDrawResult: @unchecked Sendable {
    let image: CGImage
    let onMainThread: Bool

    static func draw(_ page: PDFPage, width: Int, nonwhiteBackground: Bool = false) throws -> Self {
        let bounds = page.bounds(for: .mediaBox)
        let height = Int(CGFloat(width) * bounds.height / bounds.width)
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw NSError(domain: "PDFScreenRenderingTests", code: 1)
        }
        if nonwhiteBackground {
            context.setFillColor(red: 0, green: 0.65, blue: 0.2, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else {
            throw NSError(domain: "PDFScreenRenderingTests", code: 2)
        }
        return Self(image: image, onMainThread: Thread.isMainThread)
    }
}
