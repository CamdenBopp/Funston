import CoreText
import Foundation
import UIKit

/// The per-book font table (Spec section 9.4): `@font-face` faces loaded
/// from entry bytes into descriptors, never registered with the font manager,
/// keyed by family, weight and style; requests fall back to the user's body
/// font, and a family that only embedded a regular face synthesises bold
/// and italic through symbolic traits.
final class EPUBFontRegistry: @unchecked Sendable {
    /// CSS weights at or above this are bold.
    static let boldThreshold = 600
    static let synthesisedSmallCapsScale: CGFloat = 0.8

    private struct Face {
        let weight: Int
        let italic: Bool
        let descriptor: CTFontDescriptor
    }

    private let lock = NSLock()
    private var faces: [String: [Face]] = [:]
    private var failedSources: Set<String> = []
    private var fontCache: [FontKey: UIFont] = [:]

    private struct FontKey: Hashable {
        let family: String?
        let weight: Int
        let italic: Bool
        let size: CGFloat
        let monospace: Bool
    }

    init() {}

    /// Registers the faces of one `@font-face` block from their bytes.
    /// Returns the number of descriptors loaded; a failed decode is a diagnostic.
    @discardableResult
    func register(_ face: EPUBFontFace, data: Data, source: String, diagnostics: inout EPUBDiagnosticList) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard !failedSources.contains(source) else { return 0 }
        guard EPUBFontObfuscation.looksLikeFont(data), let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor], !descriptors.isEmpty else {
            failedSources.insert(source)
            diagnostics.record(.font, "font.undecodable", path: source, "The embedded font could not be decoded; system fonts are used.")
            return 0
        }
        let key = face.family.lowercased()
        for descriptor in descriptors {
            faces[key, default: []].append(Face(weight: face.weight, italic: face.italic, descriptor: descriptor))
        }
        fontCache.removeAll()
        return descriptors.count
    }

    func hasFamily(_ family: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return faces[family.lowercased()] != nil
    }

    /// The font for a computed style: the first embedded family in the list
    /// when publisher styles are on, else the system body font; monospace for
    /// code; weight and italic from the style.
    func font(families: [String], weight: Int, italic: Bool, size: CGFloat, monospace: Bool, publisherStyles: Bool) -> UIFont {
        let embeddedFamily = publisherStyles ? families.map { $0.lowercased() }.first { faces[$0] != nil } : nil
        let key = FontKey(family: embeddedFamily, weight: weight, italic: italic, size: size, monospace: monospace)
        lock.lock(); defer { lock.unlock() }
        if let cached = fontCache[key] { return cached }
        let font: UIFont
        if let family = embeddedFamily, let candidates = faces[family], let face = Self.bestFace(candidates, weight: weight, italic: italic) {
            font = Self.embeddedFont(face.descriptor, size: size, wantsBold: weight >= Self.boldThreshold && face.weight < Self.boldThreshold, wantsItalic: italic && !face.italic)
        } else {
            font = Self.systemFont(size: size, weight: weight, italic: italic, monospace: monospace)
        }
        fontCache[key] = font
        return font
    }

    private static func bestFace(_ candidates: [Face], weight: Int, italic: Bool) -> Face? {
        candidates.min { a, b in
            let italicA = a.italic == italic ? 0 : 1, italicB = b.italic == italic ? 0 : 1
            if italicA != italicB { return italicA < italicB }
            return abs(a.weight - weight) < abs(b.weight - weight)
        }
    }

    private static func embeddedFont(_ descriptor: CTFontDescriptor, size: CGFloat, wantsBold: Bool, wantsItalic: Bool) -> UIFont {
        let body = UIFont.systemFont(ofSize: size)
        var attributes: [CFString: Any] = [kCTFontCascadeListAttribute: [body.fontDescriptor as CTFontDescriptor]]
        var traits: CTFontSymbolicTraits = []
        if wantsBold { traits.insert(.traitBold) }
        if wantsItalic { traits.insert(.traitItalic) }
        if !traits.isEmpty { attributes[kCTFontTraitsAttribute] = [kCTFontSymbolicTrait: traits.rawValue] }
        let withCascade = CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(withCascade, size, nil)
        if !traits.isEmpty, let adjusted = CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, traits) {
            return adjusted as UIFont
        }
        return font as UIFont
    }

    static func systemFont(size: CGFloat, weight: Int, italic: Bool, monospace: Bool) -> UIFont {
        let uiWeight: UIFont.Weight
        switch weight {
        case ..<200: uiWeight = .ultraLight
        case ..<300: uiWeight = .thin
        case ..<400: uiWeight = .light
        case ..<500: uiWeight = .regular
        case ..<600: uiWeight = .medium
        case ..<700: uiWeight = .semibold
        case ..<800: uiWeight = .bold
        case ..<900: uiWeight = .heavy
        default: uiWeight = .black
        }
        var font = monospace ? UIFont.monospacedSystemFont(ofSize: size, weight: uiWeight) : UIFont.systemFont(ofSize: size, weight: uiWeight)
        if italic, let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
            font = UIFont(descriptor: descriptor, size: size)
        }
        return font
    }
}
