import Foundation

/// The "Report a bug" link: a new GitHub issue with a short form and the
/// details that help reproduce a bug. GitHub issues are public, so the body
/// never carries the device name, Archive account, history or identifiers.
struct BugReport: Equatable {
    static let repository = URL(string: "https://github.com/CamdenBopp/Funston")

    var appVersion: String
    var build: String
    var systemVersion: String
    var model: String
    var voiceOverRunning: Bool
    var textSize: String

    var body: String {
        """
        Issues on GitHub are public. Remove anything you don't want to share.

        What happened:


        What you expected:


        Steps to reproduce:
        1.

        Funston \(appVersion) (\(build))
        iOS \(systemVersion), \(model)
        VoiceOver \(voiceOverRunning ? "on" : "off"), text size \(textSize)
        """
    }

    var url: URL? {
        guard let repository = Self.repository,
              var components = URLComponents(url: repository.appending(path: "issues/new"), resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [URLQueryItem(name: "body", value: body)]
        return components.url
    }
}
