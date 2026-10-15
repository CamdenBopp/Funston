import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image metadata and decoding for a book (Spec section 9.5): intrinsic sizes
/// from ImageIO properties without decoding, and decoding on demand at the
/// drawn size with the EXIF transform applied. SVG is never decoded here.
final class EPUBImageCatalog: @unchecked Sendable {
    struct Metadata: Sendable, Hashable {
        /// The pixel size after orientation.
        let pixelSize: CGSize
        let isAnimated: Bool
        let isSVG: Bool
    }

    static let placeholderDiagnostic = "image.placeholder"

    private let lock = NSLock()
    private let read: @Sendable (String) -> Data?
    private var metadata: [String: Metadata?] = [:]
    private var decoded: [DecodeKey: CGImage] = [:]
    private var decodedBytes = 0
    /// Decoded pixels are shed beyond this budget.
    static let decodedByteBudget = 48 * 1024 * 1024

    private struct DecodeKey: Hashable {
        let path: String
        let maximumPixelSize: Int
    }

    init(read: @escaping @Sendable (String) -> Data?) {
        self.read = read
    }

    /// Reads the pixel size without decoding. Nil when the bytes are not an
    /// image ImageIO knows, including every SVG.
    func metadata(for path: String) -> Metadata? {
        lock.lock()
        if let cached = metadata[path] { lock.unlock(); return cached }
        lock.unlock()
        let result = Self.readMetadata(read(path))
        lock.lock(); metadata[path] = result; lock.unlock()
        return result
    }

    static func readMetadata(_ data: Data?) -> Metadata? {
        guard let data, !data.isEmpty else { return nil }
        if Self.looksLikeSVG(data) { return Metadata(pixelSize: .zero, isAnimated: false, isSVG: true) }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options), CGImageSourceGetStatus(source) == .statusComplete || CGImageSourceGetStatus(source) == .statusIncomplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat, let height = properties[kCGImagePropertyPixelHeight] as? CGFloat, width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let rotated = (5...8).contains(orientation)
        return Metadata(pixelSize: rotated ? CGSize(width: height, height: width) : CGSize(width: width, height: height),
                        isAnimated: CGImageSourceGetCount(source) > 1, isSVG: false)
    }

    static func looksLikeSVG(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
        return head.contains("<svg") || (head.contains("<?xml") && head.contains("svg"))
    }

    /// Decodes at most `maximumPixelSize` on the longer side, oriented.
    func image(for path: String, maximumPixelSize: Int) -> CGImage? {
        let key = DecodeKey(path: path, maximumPixelSize: maximumPixelSize)
        lock.lock()
        if let cached = decoded[key] { lock.unlock(); return cached }
        lock.unlock()
        guard let data = read(path), !Self.looksLikeSVG(data) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        lock.lock()
        let bytes = image.bytesPerRow * image.height
        if decodedBytes + bytes > Self.decodedByteBudget { decoded.removeAll(); decodedBytes = 0 }
        decoded[key] = image
        decodedBytes += bytes
        lock.unlock()
        return image
    }

    /// Drops every decoded image; metadata stays.
    func shedDecodedImages() {
        lock.lock(); decoded.removeAll(); decodedBytes = 0; lock.unlock()
    }
}
