import Foundation

/// The user's reading settings as a value snapshot, taken once per build and
/// never read from a global at draw time (Spec section 9.3).
struct EPUBReadingSettings: Sendable, Hashable {
    enum Alignment: String, Sendable, Hashable { case start, justify }
    enum Theme: Sendable, Hashable { case light, dark }
    enum Layout: String, Sendable, Hashable { case pages, continuous }

    /// The Dynamic Type body size at the default content size category.
    static let bodyPointSize: CGFloat = 17
    /// RDN-12: the heading type scale when publisher styles are off.
    static let headingTypeScale: CGFloat = 1.2
    /// RDN-12: sub and sup with publisher styles off.
    static let subSuperscriptScale: CGFloat = 0.675
    /// The computed font size is clamped to this range of the base size.
    static let minimumSizeFactor: CGFloat = 0.5
    static let maximumSizeFactor: CGFloat = 3

    /// The body text size in points after Dynamic Type.
    var baseFontSize: CGFloat = bodyPointSize
    var layout: Layout = .continuous
    var publisherStyles = false
    var alignment: Alignment = .start
    /// Nil follows the alignment (justified text hyphenates); set explicitly otherwise.
    var hyphenation: Bool? = nil
    var theme: Theme = .light
    var skipNotesAndPageNumbers = true

    var hyphenates: Bool { hyphenation ?? (alignment == .justify) }
    var textScale: CGFloat { baseFontSize / Self.bodyPointSize }
    var contentSizeCategoryToken: String { String(format: "%.2f", baseFontSize) }
}
