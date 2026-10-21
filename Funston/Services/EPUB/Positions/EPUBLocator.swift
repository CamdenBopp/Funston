import Foundation

/// The persisted reading position (Spec 12.2), version 2.
struct EPUBLocator: Sendable, Hashable, Codable {
    static let version = 2
    /// Characters of rendered text kept on each side of the position.
    static let contextLength = 64

    struct TextContext: Sendable, Hashable, Codable {
        var before: String?
        var after: String?
    }

    struct Release: Sendable, Hashable, Codable {
        var identifier: String
        var modified: String?
    }

    var v: Int = EPUBLocator.version
    var href: String
    var spineIndex: Int
    var cfi: String?
    var offset: Int
    var chapterLength: Int
    var parser: Int
    var progression: Double
    var totalProgression: Double
    var location: Int
    var text: TextContext?
    var title: String?
    var release: Release
    var savedAt: String

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// Internet date and time, whole seconds, UTC.
    static func timestamp(_ date: Date) -> String { Date.ISO8601FormatStyle().format(date) }

    /// Sorted keys, no escaped slashes, no nulls.
    func jsonString() throws -> String {
        String(decoding: try Self.encoder.encode(self), as: UTF8.self)
    }

    /// The position built from a chapter and a rendered offset.
    static func make(publication: EPUBPublication, spineIndex: Int, chapter: EPUBLoadedChapter, offset: Int, title: String?, date: Date = .now) -> EPUBLocator? {
        let spine = publication.package.spine
        guard spine.indices.contains(spineIndex) else { return nil }
        let text = chapter.text
        let clamped = min(max(0, offset), text.length)
        let length = text.length
        let progression = length > 0 ? Double(clamped) / Double(length) : 0
        let scale = EPUBProgressScale(weights: publication.weights)
        var cfi: String?
        if let position = text.runTable.sourcePosition(forRendered: clamped) {
            cfi = EPUBCFIGenerator.cfi(for: position, in: chapter.document.tree, package: publication.package, spineIndex: spineIndex)?.serialized
        }
        return EPUBLocator(href: spine[spineIndex].path ?? "", spineIndex: spineIndex, cfi: cfi, offset: clamped, chapterLength: length, parser: EPUBChapterText.parserVersion,
                           progression: progression, totalProgression: scale.fraction(spineIndex: spineIndex, progression: progression),
                           location: scale.location(spineIndex: spineIndex, progression: progression), text: context(in: text, at: clamped), title: title,
                           release: Release(identifier: publication.package.uniqueIdentifier, modified: publication.package.modified), savedAt: Self.timestamp(date))
    }

    /// Up to 64 characters of rendered text on each side, whitespace collapsed.
    static func context(in text: EPUBChapterText, at offset: Int) -> TextContext? {
        let string = text.string.string as NSString
        guard string.length > 0 else { return nil }
        let clamped = min(max(0, offset), string.length)
        let beforeRange = NSRange(location: max(0, clamped - contextLength * 2), length: clamped - max(0, clamped - contextLength * 2))
        let afterRange = NSRange(location: clamped, length: min(contextLength * 2, string.length - clamped))
        let before = EPUBXMLDocument.collapseWhitespace(string.substring(with: beforeRange))
        let after = EPUBXMLDocument.collapseWhitespace(string.substring(with: afterRange))
        let context = TextContext(before: before.isEmpty ? nil : String(before.suffix(contextLength)), after: after.isEmpty ? nil : String(after.prefix(contextLength)))
        return context.before == nil && context.after == nil ? nil : context
    }
}

/// A position written by the previous reader (Spec 12.2, RDS-37, RDS-38, RDS-40).
struct EPUBLegacyPosition: Sendable, Hashable {
    var href: String
    var title: String?
    var fragments: [String]
    var cssSelector: String?
    var progression: Double?
    var totalProgression: Double?
    var textBefore: String?
    var textHighlight: String?
    var textAfter: String?
}

/// What a `book_positions.locator` string turned out to hold.
enum EPUBStoredPosition: Sendable, Hashable {
    case current(EPUBLocator)
    case legacy(EPUBLegacyPosition)
    case unreadable

    static func parse(_ json: String) -> EPUBStoredPosition {
        let data = Data(json.utf8)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unreadable }
        if let version = object["v"] as? Int, version >= EPUBLocator.version {
            guard let locator = try? JSONDecoder().decode(EPUBLocator.self, from: data) else { return .unreadable }
            return .current(locator)
        }
        guard var href = object["href"] as? String else { return .unreadable }
        if href.hasPrefix("/") { href.removeFirst() }
        let locations = object["locations"] as? [String: Any] ?? [:]
        var fragments = locations["fragments"] as? [String] ?? []
        if let single = locations["fragment"] as? String { fragments.append(single) }
        fragments = fragments.filter { !$0.isEmpty }
        func fraction(_ key: String) -> Double? {
            guard let value = locations[key] as? Double, value >= 0, value <= 1 else { return nil }
            return value
        }
        let text = object["text"] as? [String: Any] ?? [:]
        return .legacy(EPUBLegacyPosition(href: href, title: object["title"] as? String, fragments: fragments, cssSelector: locations["cssSelector"] as? String,
                                          progression: fraction("progression"), totalProgression: fraction("totalProgression"),
                                          textBefore: text["before"] as? String, textHighlight: text["highlight"] as? String, textAfter: text["after"] as? String))
    }
}
