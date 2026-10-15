import Foundation
import OSLog
import UIKit

/// The element-model experiment's log (Spec 14.6): every accessibilityScroll
/// call, pageScrolled post, reading content call and the focused element one
/// second after each scroll, to OSLog and to a file in Documents. Enabled by
/// the `epub.a11yExperiment` default; otherwise every call is a no-op.
@MainActor
final class EPUBAccessibilityLog {
    static let shared = EPUBAccessibilityLog()
    static let enabledKey = "epub.a11yExperiment"
    static let modelKey = "epub.a11yModel"
    private static let logger = Logger(subsystem: "com.camden.Funston", category: "EPUB.a11y")
    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private(set) var lines: [String] = []
    private var handle: FileHandle?

    private init() {
        // Launch arguments set the switches for one run; keep them so a launch from the
        // Home screen during a device run reads the same model and keeps logging.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "-" + Self.enabledKey), index + 1 < arguments.count {
            UserDefaults.standard.set(["yes", "true", "1"].contains(arguments[index + 1].lowercased()), forKey: Self.enabledKey)
        }
        if let index = arguments.firstIndex(of: "-" + Self.modelKey), index + 1 < arguments.count {
            UserDefaults.standard.set(arguments[index + 1], forKey: Self.modelKey)
        }
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// The file the run writes, created on the first line.
    private(set) var fileURL: URL?

    func record(_ event: String) {
        guard isEnabled else { return }
        let line = "\(Self.timestamp.string(from: Date())) \(event)"
        lines.append(line)
        Self.logger.info("\(line, privacy: .public)")
        if handle == nil, let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = documents.appendingPathComponent("epub-a11y-\(Int(Date().timeIntervalSince1970)).log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
            fileURL = url
        }
        handle?.write(Data((line + "\n").utf8))
    }

    /// Records the focused element one second after a scroll (Spec 14.6).
    func recordFocusLater(context: String) {
        guard isEnabled else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            let focused = UIAccessibility.focusedElement(using: .notificationVoiceOver)
            let description: String
            if let element = focused as? UIAccessibilityElement { description = "element label=\(element.accessibilityLabel ?? "nil") id=\(element.accessibilityIdentifier ?? "nil")" }
            else if let view = focused as? UIView { description = "view \(type(of: view)) label=\(view.accessibilityLabel ?? "nil")" }
            else if let object = focused { description = "\(type(of: object))" }
            else { description = "nil" }
            self.record("focus+1s after \(context): \(description)")
        }
    }
}
