import Foundation
import PDFKit
import CoreGraphics

/// Test-only experiment; NOT shipped. It did not reliably eliminate blank pages.
/// PDFKit still owns text, selection, links, Find, zooming and page layout.
/// The delegate only substitutes the immutable page drawing implementation.
final class PDFScreenRendering: NSObject, PDFDocumentDelegate, @unchecked Sendable {
    let cache = PDFScreenRasterCache()
    // PDFKit can instantiate PDFPage subclasses without Swift initializers.
    // Keep all state in this normally initialized delegate, not in the page.
    private let renderLocks = (0..<4).map { _ in NSLock() }
    func renderLock(page: Int) -> NSLock { renderLocks[page % renderLocks.count] }
    func classForPage() -> AnyClass { PDFScreenPage.self }
}

/// PDFKit calls page drawing on its tile workers as well as on the main thread.
/// No UIKit state or main-actor callback is touched by this implementation.
final class PDFScreenPage: PDFPage {
    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        let bounds = bounds(for: box)
        let transform = context.ctm
        let requestedScale = max(hypot(transform.a, transform.b), hypot(transform.c, transform.d))
        // Zoomed, rotated, annotated, and unusually shaped pages retain PDFKit's
        // original renderer. A screen raster must never limit zoom quality or
        // freeze editable forms/annotations.
        guard let rendering = document?.delegate as? PDFScreenRendering,
              let sourcePage = pageRef, sourcePage.pageNumber > 0,
              rotation % 360 == 0, annotations.isEmpty,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0,
              bounds.minX == 0, bounds.minY == 0,
              requestedScale.isFinite, bounds.width * requestedScale <= 1536,
              bounds.height / bounds.width <= 2.5 else {
            super.draw(with: box, to: context)
            return
        }
        let pageNumber = sourcePage.pageNumber
        let key = PDFScreenRasterCache.Key(page: pageNumber, box: box.rawValue, bounds: bounds)
        if let image = rendering.cache.image(for: key) {
            context.draw(image, in: bounds)
            return
        }
        // Never wait for a tile worker or perform a full-page decode on the UI
        // thread. PDFKit's native path can schedule the missing tiles instead.
        guard !Thread.isMainThread else {
            super.draw(with: box, to: context)
            return
        }
        // Native preview and tile jobs can request the same scan simultaneously.
        // One decode supplies all those requests; unrelated pages remain parallel.
        let renderLock = rendering.renderLock(page: pageNumber)
        renderLock.lock()
        defer { renderLock.unlock() }
        if let image = rendering.cache.image(for: key) {
            context.draw(image, in: bounds)
            return
        }
        let width = 1536
        let scaledHeight = (CGFloat(width) * (bounds.height / bounds.width)).rounded(.up)
        guard scaledHeight.isFinite, scaledHeight >= 1, scaledHeight <= 3840 else {
            super.draw(with: box, to: context)
            return
        }
        let height = Int(scaledHeight)
        guard
              let raster = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            super.draw(with: box, to: context)
            return
        }
        // PDFPage.draw does not clear its destination; preserve transparency so
        // PDFKit (or a print/export context) supplies the appropriate background.
        raster.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
        raster.translateBy(x: -bounds.minX, y: -bounds.minY)
        raster.interpolationQuality = .low
        raster.drawPDFPage(sourcePage)
        guard let image = raster.makeImage() else {
            super.draw(with: box, to: context)
            return
        }
        rendering.cache.insert(image, for: key)
        context.draw(image, in: bounds)
    }
}

/// Hard byte ceiling per open document; neither page count nor fling distance
/// grows retained bitmap memory. No compressed PDF copy or disk derivative.
final class PDFScreenRasterCache: @unchecked Sendable {
    struct Key: Hashable {
        let page: Int
        let box: Int
        let x, y, width, height: CGFloat
        init(page: Int, box: Int, bounds: CGRect) {
            self.page = page; self.box = box
            x = bounds.minX; y = bounds.minY; width = bounds.width; height = bounds.height
        }
    }
    private struct Entry { let image: CGImage; let cost: Int; var accessed: UInt64 }
    private let lock = NSLock()
    private let limit: Int
    private var entries: [Key: Entry] = [:]
    private var retainedBytes = 0
    private var sequence: UInt64 = 0
    private var renders = 0
    private var hits = 0

    init(limit: Int = 48 * 1024 * 1024) { self.limit = max(0, limit) }

    func image(for key: Key) -> CGImage? {
        lock.withLock {
            guard var entry = entries[key] else { return nil }
            sequence &+= 1
            entry.accessed = sequence
            entries[key] = entry
            hits += 1
            return entry.image
        }
    }

    func insert(_ image: CGImage, for key: Key) {
        let cost = image.bytesPerRow * image.height
        lock.withLock {
            renders += 1
            guard cost <= limit else { return }
            if let previous = entries.removeValue(forKey: key) { retainedBytes -= previous.cost }
            while retainedBytes + cost > limit, let oldest = entries.min(by: { $0.value.accessed < $1.value.accessed }) {
                retainedBytes -= oldest.value.cost
                entries.removeValue(forKey: oldest.key)
            }
            sequence &+= 1
            entries[key] = Entry(image: image, cost: cost, accessed: sequence)
            retainedBytes += cost
        }
    }

    func removeAll() { lock.withLock { entries.removeAll(); retainedBytes = 0 } }
    var statistics: (renders: Int, hits: Int, bytes: Int) { lock.withLock { (renders, hits, retainedBytes) } }
}
