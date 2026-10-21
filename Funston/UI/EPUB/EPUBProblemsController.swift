import UIKit

/// The debug problems screen of Spec 19.1: every diagnostic the book has
/// produced so far, one row each, in the order they were recorded. Phase B
/// turns this into the readers' "Problems with this book" list.
@MainActor
final class EPUBProblemsController: FunstonListController {
    static let emptyRowID = "problems:none"
    static let emptyTitle = "No problems found"
    private let diagnostics: EPUBDiagnosticList

    init(diagnostics: EPUBDiagnosticList) {
        self.diagnostics = diagnostics
        super.init(title: "Problems with this book")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        apply(Self.rows(for: diagnostics))
    }

    /// One row per diagnostic: the sentence, then the stage, code, place and repeat count.
    static func rows(for diagnostics: EPUBDiagnosticList) -> [FunstonRow] {
        guard !diagnostics.isEmpty else {
            var row = FunstonRow(id: emptyRowID, title: emptyTitle)
            row.navigates = false
            row.centered = true
            return [row]
        }
        return diagnostics.items.enumerated().map { index, item in
            var row = FunstonRow(id: "problem:\(index)", title: item.message, subtitle: detail(for: item))
            row.navigates = false
            return row
        }
    }

    static func detail(for item: EPUBDiagnostic) -> String {
        var parts = ["\(item.stage.rawValue) \(item.code)"]
        if let path = item.path, !path.isEmpty { parts.append(path) }
        if let spineIndex = item.spineIndex { parts.append("spine item \(spineIndex + 1)") }
        if item.count > 1 { parts.append("\(item.count) times") }
        return parts.joined(separator: ", ")
    }
}
