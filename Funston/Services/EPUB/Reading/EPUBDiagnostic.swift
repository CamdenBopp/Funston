import Foundation
import OSLog

/// One lenient decision, missing resource, recovery or failed resolution. Books
/// from Internet Archive are malformed in small ways constantly, so every such
/// event is a value the reader keeps and can show, never a print and never a crash.
struct EPUBDiagnostic: Sendable, Hashable {
    enum Stage: String, Sendable {
        case zip, container, package, navigation
        case chapterDecode = "chapter.decode"
        case chapterParse = "chapter.parse"
        case chapterRecover = "chapter.recover"
        case css, font, image, layout, position
        case accessibility = "a11y"
        case speech
    }

    let stage: Stage
    /// A stable code tests assert on, such as `mimetype.missing` or `xml.tagsoup`.
    let code: String
    /// The archive path concerned, when there is one.
    let path: String?
    /// The spine index concerned, when there is one.
    let spineIndex: Int?
    let message: String
    var count: Int

    init(stage: Stage, code: String, path: String? = nil, spineIndex: Int? = nil, message: String, count: Int = 1) {
        self.stage = stage; self.code = code; self.path = path; self.spineIndex = spineIndex
        self.message = message; self.count = count
    }
}

/// An ordered list that merges repeats of the same code at the same place by
/// raising the count, so sixty-three ignored properties are one line, not sixty-three.
struct EPUBDiagnosticList: Sendable, Hashable {
    private static let logger = Logger(subsystem: "com.camden.Funston", category: "EPUB")
    private(set) var items: [EPUBDiagnostic] = []

    init() {}
    init(_ items: [EPUBDiagnostic]) { for item in items { record(item) } }

    var isEmpty: Bool { items.isEmpty }

    mutating func record(_ diagnostic: EPUBDiagnostic) {
        if let index = items.firstIndex(where: {
            $0.stage == diagnostic.stage && $0.code == diagnostic.code && $0.path == diagnostic.path && $0.spineIndex == diagnostic.spineIndex
        }) {
            items[index].count += diagnostic.count
        } else {
            items.append(diagnostic)
            Self.logger.info("\(diagnostic.stage.rawValue, privacy: .public) \(diagnostic.code, privacy: .public) \(diagnostic.path ?? "", privacy: .public): \(diagnostic.message, privacy: .public)")
        }
    }

    mutating func record(_ stage: EPUBDiagnostic.Stage, _ code: String, path: String? = nil, spineIndex: Int? = nil, _ message: String) {
        record(EPUBDiagnostic(stage: stage, code: code, path: path, spineIndex: spineIndex, message: message))
    }

    mutating func merge(_ other: EPUBDiagnosticList) {
        for item in other.items { record(item) }
    }

    func contains(code: String) -> Bool { items.contains { $0.code == code } }
    func count(code: String) -> Int { items.filter { $0.code == code }.reduce(0) { $0 + $1.count } }
    subscript(code code: String) -> EPUBDiagnostic? { items.first { $0.code == code } }
}
